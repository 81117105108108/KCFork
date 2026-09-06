local Instance = require("@Instance")
local Enum = require("@EnumMap")
local MiniAudio = require("@MiniAudio")

local audio = MiniAudio.lib
local SoundService = Instance.new("SoundService")
SoundService.ExplorerHidden = true
SoundService._Intents = Enum.PluginIntents.Audio
SoundService.GlobalVolume = 1

SoundService.InitRenderer = function(renderer, rendererSignal, datamodel)
	if audio.Kine_Audio_Init() == 0 then
		warn("[MiniAudio] Failed to initialize the playback engine")
		return
	end
	audio.Kine_Audio_SetMasterVolume(SoundService.GlobalVolume)

	SoundService.Changed:Connect(function(property)
		if property == "GlobalVolume" then
			audio.Kine_Audio_SetMasterVolume(SoundService.GlobalVolume)
		end
	end)

	local previousCameraPosition = nil
	local previousUpdate = os.clock()
	renderer.Pool.new("3d", function()
		local workspace = datamodel:GetService("Workspace")
		local camera = workspace and workspace.CurrentCamera
		local now = os.clock()
		local elapsed = math.max(1 / 240, now - previousUpdate)
		previousUpdate = now
		if camera and camera.CFrame then
			local cframe = camera.CFrame
			local position = cframe.Position
			local velocity = previousCameraPosition and (position - previousCameraPosition) / elapsed or position * 0
			local forward, up = cframe:GetLookVector(), cframe:GetUpVector()
			audio.Kine_Audio_SetListener(
				position.X,
				position.Y,
				position.Z,
				forward.X,
				forward.Y,
				forward.Z,
				up.X,
				up.Y,
				up.Z,
				velocity.X,
				velocity.Y,
				velocity.Z
			)
			previousCameraPosition = position
		end

		for _, object in ipairs(datamodel:GetDescendants()) do
			if object.ClassName == "Sound" and object.IsLoaded and object._SyncAudio then
				local position = object.Position
				if object.Parent and object.Parent:IsA("BasePart") then
					position = object.Parent.CFrame and object.Parent.CFrame.Position or object.Parent.Position
				elseif object.Parent and object.Parent.ClassName == "Attachment" then
					position = object.Parent.WorldPosition
				end
				object:_SyncAudio(position)
			end
		end
	end)
end

return SoundService
