local AudioEffectBridge = {}

function AudioEffectBridge.Define(className, properties)
	return {
		class = className,
		callback = function(instance)
			instance:SetProperties(properties)
			local function apply()
				local sound = instance.Parent
				if sound and sound.ClassName == "Sound" and sound._ApplyAudioEffects then
					sound:_ApplyAudioEffects()
				end
			end
			instance.Changed:Connect(apply)
			instance.AncestryChanged:Connect(apply)
			return instance
		end,
		inherit = function(target)
			for property, value in pairs(properties) do
				target[property] = value
			end
		end,
	}
end

return AudioEffectBridge
