local Instance = require("@Instance")
local signal = require("@Kinemium.signal")

local PlaytestService = Instance.new("PlaytestService")
PlaytestService.ExplorerHidden = true

local task = zune.task
local serverProcess = nil
local clientProcess = nil
local logTasks = {}
local currentFile = nil

local function stopLogTasks()
	for _, logger in ipairs(logTasks) do
		pcall(task.cancel, logger)
	end
	table.clear(logTasks)
end

local function pumpStream(prefix, stream, event)
	if not stream then
		return
	end
	local logger = task.spawn(function()
		local buffer = ""
		while true do
			local ok, chunk = pcall(function()
				return stream:read(1024)
			end)
			if not ok or not chunk then
				break
			end
			if #chunk == 0 then
				task.wait(0.01)
				continue
			end
			buffer ..= chunk
			while true do
				local lineEnd = string.find(buffer, "\n", 1, true)
				if not lineEnd then
					break
				end
				local line = string.sub(buffer, 1, lineEnd - 1):gsub("\r$", "")
				buffer = string.sub(buffer, lineEnd + 1)
				if #line > 0 then
					event:Fire(line)
					print(prefix, line)
				end
			end
		end
		if #buffer > 0 then
			event:Fire(buffer)
			print(prefix, buffer)
		end
	end)
	table.insert(logTasks, logger)
end

local function killProcess(process)
	if process then
		task.spawn(function()
			pcall(function()
				process:kill()
			end)
		end)
	end
end

PlaytestService.InitRenderer = function(renderer, rendererSignal, datamodel)
	PlaytestService:SetProperties({
		OnClientLog = signal.new(),
		OnServerLog = signal.new(),
		OnPlaytestStarted = signal.new(),
		OnPlaytestFinished = signal.new(),
		IsPlaytesting = false,
	})

	local function stopCurrentPlaytest(gameName)
		if not PlaytestService.IsPlaytesting and not serverProcess and not clientProcess then
			return false
		end
		stopLogTasks()
		killProcess(clientProcess)
		killProcess(serverProcess)
		clientProcess = nil
		serverProcess = nil
		PlaytestService.IsPlaytesting = false
		PlaytestService.OnPlaytestFinished:Fire()
		local path = currentFile or ("./.temp/" .. tostring(gameName or "game") .. ".kine")
		currentFile = nil
		pcall(zune.fs.deleteFile, path)
		return true
	end

	local function createPlaytest(gameName)
		gameName = tostring(gameName or "game")
		if PlaytestService.IsPlaytesting then
			stopCurrentPlaytest(gameName)
		end

		zune.fs.makeDir("./.temp", true)
		currentFile = "./.temp/" .. gameName .. ".kine"
		pcall(zune.fs.deleteFile, currentFile)

		local KineFileService = datamodel:GetService("KineFileService")
		local serialized = KineFileService.ExportGameAsFile("./.temp", gameName)
		if not serialized then
			currentFile = nil
			return nil, "failed to export the playtest place"
		end

		local username = GetFlagValue("username")
			or zune.process.env["USERNAME"]
			or zune.process.env["USER"]
			or "Player"
		local port = tonumber(GetFlagValue("port")) or 1234
		local Process = datamodel:GetService("Process")
		local ioOptions = { stdout = "piped", stderr = "piped" }

		serverProcess = Process.RunProcessZune({
			"run", "game", "--server", "--kilang", "--headless",
			"--blob", currentFile, "--address", "127.0.0.1", "--port", tostring(port),
		}, ioOptions)
		if not serverProcess then
			return nil, "failed to launch the playtest server"
		end

		PlaytestService.IsPlaytesting = true
		PlaytestService.OnPlaytestStarted:Fire()
		pumpStream("[SERVER]", serverProcess.stdout, PlaytestService.OnServerLog)
		pumpStream("[SERVER]", serverProcess.stderr, PlaytestService.OnServerLog)

		task.spawn(function()
			task.wait(0.75)
			if not PlaytestService.IsPlaytesting then
				return
			end
			clientProcess = Process.RunProcessZune({
				"run", "game", "--client", "--username", tostring(username),
				"--blob", currentFile, "--address", "127.0.0.1", "--port", tostring(port),
				"--max3dpixels", "144000", "--perfoverlay",
			}, ioOptions)
			if clientProcess then
				pumpStream("[CLIENT]", clientProcess.stdout, PlaytestService.OnClientLog)
				pumpStream("[CLIENT]", clientProcess.stderr, PlaytestService.OnClientLog)
			else
				warn("Failed to launch the playtest client")
				stopCurrentPlaytest(gameName)
			end
		end)

		return true
	end

	PlaytestService:SetProperties({
		CreatePlaytestAsync = function(first, second)
			return createPlaytest(first == PlaytestService and second or first)
		end,
		StopCurrentPlaytest = function(first, second)
			return stopCurrentPlaytest(first == PlaytestService and second or first)
		end,
	})
end

return PlaytestService
