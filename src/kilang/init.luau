--!strict
-- kilang.lua
-- Runtime execution module for the Kinemium/Zune engine

local kilang = {}

local preprocessor = require("./kilang/Transpiler")
local SandboxEnvironment = require("./kilang/SandboxEnvironment")
local luau = zune.luau
local task = zune.task

--  State

kilang.renderer = nil
kilang.env = {}
kilang.threads = {}

--  Internal: diagnostics + bytecode compile + load + exec

local function normalizeDiagnostic(chunk: string, err: unknown): string
	local msg = tostring(err)
	if msg:match("^[^:]+:%d+:%d+:") then
		return msg
	end
	local line, rest = msg:match("^.-:(%d+):%s*(.*)$")
	if line then
		return (`{chunk}:{line}:1: {rest}`)
	end
	return (`{chunk}:1:1: {msg}`)
end

local function run_code(code: string, env: SandboxEnvironment.Environment, chunk: string, native_code_gen: boolean): (unknown, boolean, unknown)
	local compiled, bytecode = pcall(luau.compile, code, {
		optimization_level = 2,
	})
	if not compiled then
		return nil, false, normalizeDiagnostic(chunk, bytecode)
	end

	local trusted = env.SecurityCapabilities == 2
	if trusted then
		env = setmetatable(env, { __index = getfenv(1) })
	else
		env = SandboxEnvironment.create(env)
	end
	local loaded, thread = pcall(luau.load, bytecode, {
		env = env,
		chunk_name = chunk,
		native_code_gen = trusted and native_code_gen or false,
	})
	if not loaded then
		return nil, false, tostring(thread)
	end
	setfenv(thread, env)

	local ok, result = pcall(thread)
	return (ok and result or nil), ok, result
end

--  kilang:init

--- Initialise the runtime against a camera and renderer.
--- Returns the C-side environment handle.
---@param cam any
---@return any CEnv
function kilang:init(cam, Kinemium_env)
	local luaEnv, CEnv = Kinemium_env(self.renderer, cam)
	self.env = luaEnv
	return CEnv
end

--  kilang:execute

--- Transpile and execute a kilang script in an isolated environment.
---
---@param code      string   Source code to run
---@param opts      table?   Options: superset, SecurityCapabilities, StackId
---@param env_other table?   Additional environment bindings to inject
---@return string?  id       Stack ID for the spawned thread (nil on failure)
---@return boolean  success  Whether execution succeeded
---@return any      result   Return value or error message
---@return thread?  thread   The coroutine handle (if spawned)
function kilang:registerThread(id, thread)
	if type(thread) == "thread" then
		self.threads[tostring(id)] = thread
	end
end

function kilang:getThreads()
	local active = {}
	for id, thread in pairs(self.threads) do
		local status = "unavailable"
		if type(thread) == "thread" then
			local ok, s = pcall(coroutine.status, thread)
			status = ok and s or "unavailable"
		end
		active[id] = { thread = thread, status = status }
	end
	return active
end

function kilang:execute(code, opts, env_other)
	opts = opts or {}

	local superset = opts.superset or "kilang"
	local SecurityCapabilities = opts.SecurityCapabilities

	-- bandaid fix, is a large number so different stacks don't clash
	local id = opts.StackId or ("stack" .. math.random(0, 9999999))

	-- Don't allow duplicate stacks for the same ID unless the previous thread is dead
	if self.threads[id] and pcall(coroutine.status, self.threads[id]) and coroutine.status(self.threads[id]) ~= "dead" then
		return id, false, "Stack ID already running"
	end

	-- Build sandboxed environment: base env → caller overrides
	local environment = {}
	for k, v in pairs(self.env) do
		environment[k] = v
	end
	if env_other then
		for k, v in pairs(env_other) do
			environment[k] = v
		end
	end
	environment.SecurityCapabilities = SecurityCapabilities
	-- Engine classes/services execute with the Internals capability and need the
	-- native runtime for FFI-backed systems such as Box2D. User scripts retain
	-- the deliberately restricted `zune = 0` value supplied by environment/get.
	if SecurityCapabilities == 2 then
		environment.zune = zune
	end

	local taskCount = 0
	local baseTask = environment.task or zune.task
	if baseTask then
		environment.task = {
			cancel = baseTask.cancel or zune.task.cancel,
			wait = baseTask.wait or zune.task.wait,
			spawn = function(fn, ...)
				local th = baseTask.spawn(fn, ...)
				if type(th) == "thread" and pcall(coroutine.status, th) and coroutine.status(th) ~= "dead" then
					taskCount += 1
					self.threads[`{id} (task.spawn #{taskCount})`] = th
				end
				return th
			end,
			defer = function(fn, ...)
				local th = baseTask.defer(fn, ...)
				if type(th) == "thread" and pcall(coroutine.status, th) and coroutine.status(th) ~= "dead" then
					taskCount += 1
					self.threads[`{id} (task.defer #{taskCount})`] = th
				end
				return th
			end,
			delay = function(dt, fn, ...)
				local th = baseTask.delay(dt, fn, ...)
				if type(th) == "thread" and pcall(coroutine.status, th) and coroutine.status(th) ~= "dead" then
					taskCount += 1
					self.threads[`{id} (task.delay #{taskCount})`] = th
				end
				return th
			end,
			desynchronize = baseTask.desynchronize,
			synchronize = baseTask.synchronize,
		}
	end

	-- Execute on a task thread; capture success/result via upvalue
	local success, result
	local isFinished = false
	local thread = task.spawn(function()
		-- Hot path: Kilang source -> Parser/AST/Compiler -> standard Luau.
		local transpileOk, transpiled = pcall(preprocessor.runLang, code, superset)
		if not transpileOk then
			success = false
			result = normalizeDiagnostic(id, transpiled)
			isFinished = true
			print(`[Kilang Error] {id}: {tostring(result)}`)
			return
		end
		local _, s, r = run_code(transpiled :: string, environment, id, true)
		success = s
		result = r
		isFinished = true
		if not s and r ~= nil then
			print(`[Kilang Error] {id}: {tostring(r)}`)
		end
	end)

	-- Always register the thread so it can be cleaned up
	self.threads[id] = thread

	local function getResult()
		while not isFinished do
			task.wait()
		end
		return success, result
	end

	return id, success, result, thread, getResult
end

--  kilang:remove

--- Remove a tracked stack thread by ID.
---@param id string
function kilang:remove(id)
	self.threads[id] = nil
end

return kilang
