-- description: "Plays positional or non-positional audio through miniaudio."
local Signal = require("@Kinemium.signal")
local Enum = require("@EnumMap")
local Vector3 = require("@Vector3")
local MiniAudio = require("@MiniAudio")
local zembed = require("@zembed")
local task = zune.task

local audio = MiniAudio.lib

local propTable = {
	SoundId = "",
	Volume = 1,
	Pitch = 1,
	Looped = false,
	Playing = false,
	TimePosition = 0,
	TimeLength = 0,
	PlayOnRemove = false,
	IsLoaded = false,
	Name = "Sound",
	AudioBackend = Enum.AudioBackend.MiniAudio,
	IsStream = false,
	SoundGroup = nil,
	_effectiveVolume = 1,
	_fadeVolume = 1,
	Position = Vector3.new(0, 0, 0),
	Velocity = Vector3.new(0, 0, 0),
	Direction = Vector3.new(0, 0, -1),
	Up = Vector3.new(0, 1, 0),
	MinDistance = 10,
	MaxDistance = 1000,
	RollOffMode = 1,
	Is3D = false,
}

local function dbToLinear(db)
	if db <= -80 then
		return 0
	end
	return 10 ^ (db / 20)
end

local function childOfClass(instance, className)
	for _, child in ipairs(instance:GetChildren()) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

return {
	class = "Sound",
	callback = function(instance)
		instance:SetProperties(propTable)
		instance.Played = Signal.new()
		instance.Ended = Signal.new()
		local sound = nil
		local fadeGeneration = 0

		local function updateVolume()
			if not sound then return end
			local groupVolume = instance.SoundGroup and instance.SoundGroup.Volume or 1
			instance._effectiveVolume = instance.Volume * groupVolume * instance._fadeVolume
			audio.Kine_Audio_SetVolume(sound, instance._effectiveVolume)
		end

		local function updatePlaybackProperties()
			if not sound then return end
			audio.Kine_Audio_SetPitch(sound, instance.Pitch)
			audio.Kine_Audio_SetLooping(sound, instance.Looped and 1 or 0)
			audio.Kine_Audio_SetSpatial(sound, instance.Is3D and 1 or 0)
			audio.Kine_Audio_SetDistance(sound, instance.MinDistance, instance.MaxDistance, instance.RollOffMode)
			audio.Kine_Audio_SetPosition(sound, instance.Position.X, instance.Position.Y, instance.Position.Z)
			audio.Kine_Audio_SetVelocity(sound, instance.Velocity.X, instance.Velocity.Y, instance.Velocity.Z)
			audio.Kine_Audio_SetDirection(sound, instance.Direction.X, instance.Direction.Y, instance.Direction.Z)
	end

		function instance:_ApplyAudioEffects()
			if not sound then return end
			local effect = childOfClass(self, "ReverbSoundEffect")
			audio.Kine_Audio_SetEffect(sound, 0, effect and effect.Enabled and 1 or 0,
				effect and math.clamp(effect.DecayTime / 20, 0, 1) or 0.075,
				effect and 1 - math.clamp(effect.Diffusion, 0, 1) or 0,
				effect and dbToLinear(effect.WetLevel) or 0,
				effect and dbToLinear(effect.DryLevel) or 1,
				effect and math.clamp(effect.Density, 0, 1) or 1)

			effect = childOfClass(self, "EchoSoundEffect")
			audio.Kine_Audio_SetEffect(sound, 1, effect and effect.Enabled and 1 or 0,
				effect and effect.Delay or 0.25,
				effect and effect.Feedback or 0.25,
				effect and dbToLinear(effect.WetLevel) or 0,
				effect and dbToLinear(effect.DryLevel) or 1, 0)

			effect = childOfClass(self, "EqualizerSoundEffect")
			audio.Kine_Audio_SetEffect(sound, 2, effect and effect.Enabled and 1 or 0,
				effect and effect.LowGain or 0,
				effect and effect.MidGain or 0,
				effect and effect.HighGain or 0, 0, 0)

			effect = childOfClass(self, "LowPassSoundEffect")
			audio.Kine_Audio_SetEffect(sound, 3, effect and effect.Enabled and 1 or 0,
				effect and effect.CutoffFrequency or 5000, 0, 0, 0, 0)

			effect = childOfClass(self, "HighPassSoundEffect")
			audio.Kine_Audio_SetEffect(sound, 4, effect and effect.Enabled and 1 or 0,
				effect and effect.CutoffFrequency or 100, 0, 0, 0, 0)
		end

		local function unloadAudio(preservePlaying)
			if sound then
				audio.Kine_Audio_DestroySound(sound)
				sound = nil
				instance._audioSound = nil
			end
			instance.IsLoaded = false
			if not preservePlaying then
				instance.Playing = false
			end
		end

		local function loadAudio()
			local shouldPlay = instance.Playing
			unloadAudio(true)
			if instance.SoundId == "" then
				instance.Playing = false
				return
			end
			local path = zembed.AssetPath(instance.SoundId)
			sound = MiniAudio.LoadSound(path, instance.IsStream)
			if MiniAudio.IsNull(sound) then
				sound = nil
				warn("[MiniAudio] Failed to load " .. tostring(instance.SoundId))
				return
			end
			instance._audioSound = sound
			instance.IsLoaded = true
			instance.TimeLength = audio.Kine_Audio_GetDuration(sound)
			updateVolume()
			updatePlaybackProperties()
			instance:_ApplyAudioEffects()
			if shouldPlay then
				audio.Kine_Audio_Play(sound)
			end
		end

		local function fadeTo(target, duration, completed)
			fadeGeneration += 1
			local generation = fadeGeneration
			if not duration or duration <= 0 then
				instance._fadeVolume = target
				updateVolume()
				if completed then completed() end
				return
			end
			local start, startedAt = instance._fadeVolume, os.clock()
			task.spawn(function()
				while generation == fadeGeneration and sound do
					local alpha = math.min(1, (os.clock() - startedAt) / duration)
					instance._fadeVolume = start + (target - start) * alpha
					updateVolume()
					if alpha >= 1 then
						if completed then completed() end
						break
					end
					task.wait()
				end
			end)
		end

		function instance:Play(fadeDuration)
			if not sound then return false end
			if audio.Kine_Audio_IsAtEnd(sound) ~= 0 then audio.Kine_Audio_Seek(sound, 0) end
			fadeTo(1, fadeDuration)
			local played = audio.Kine_Audio_Play(sound) ~= 0
			self.Playing = played
			self._endedFired = false
			if played then self.Played:Fire() end
			return played
		end

		function instance:Stop(fadeDuration)
			if not sound then return end
			fadeTo(0, fadeDuration, function()
				audio.Kine_Audio_Stop(sound)
				self.Playing = false
				rawget(self, "_props").TimePosition = 0
			end)
		end

		function instance:Pause(fadeDuration)
			if not sound then return end
			fadeTo(0, fadeDuration, function()
				audio.Kine_Audio_Pause(sound)
				self.Playing = false
			end)
		end

		function instance:Resume(fadeDuration)
			if not sound then return false end
			local played = audio.Kine_Audio_Play(sound) ~= 0
			self.Playing = played
			fadeTo(1, fadeDuration)
			return played
		end

		function instance:_SyncAudio(position)
			if not sound then return end
			if position then
				audio.Kine_Audio_SetPosition(sound, position.X, position.Y, position.Z)
			end
			rawget(self, "_props").TimePosition = audio.Kine_Audio_GetTime(sound)
			if self.Playing and not self.Looped and audio.Kine_Audio_IsAtEnd(sound) ~= 0 then
				self.Playing = false
				if not self._endedFired then
					self._endedFired = true
					self.Ended:Fire()
				end
			end
		end

		instance.Changed:Connect(function(property)
			if property == "Volume" or property == "SoundGroup" then
				updateVolume()
			elseif property == "Playing" and sound then
				if instance.Playing then
					audio.Kine_Audio_Play(sound)
				else
					audio.Kine_Audio_Pause(sound)
				end
			elseif property == "Pitch" or property == "Looped" or property == "Is3D"
				or property == "Position" or property == "Velocity" or property == "Direction"
				or property == "MinDistance" or property == "MaxDistance" or property == "RollOffMode"
			then
				updatePlaybackProperties()
			elseif property == "TimePosition" and sound then
				audio.Kine_Audio_Seek(sound, instance.TimePosition)
			elseif property == "SoundId" or property == "IsStream" then
				loadAudio()
			end
		end)
		instance.ChildAdded:Connect(function() instance:_ApplyAudioEffects() end)
		instance.ChildRemoved:Connect(function() instance:_ApplyAudioEffects() end)
		instance.Destroying:Connect(function() unloadAudio(false) end)
		loadAudio()
		return instance
	end,
	inherit = function(target)
		for property, value in pairs(propTable) do target[property] = value end
	end,
}
