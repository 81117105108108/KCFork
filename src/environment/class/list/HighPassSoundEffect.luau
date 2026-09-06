-- description: "Removes frequencies below the configured cutoff."
local AudioEffectBridge = require("../AudioEffectBridge")

return AudioEffectBridge.Define("HighPassSoundEffect", {
	Enabled = true,
	CutoffFrequency = 100,
	Name = "HighPassSoundEffect",
	BaseClass = "AudioEffect",
})
