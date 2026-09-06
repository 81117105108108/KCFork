-- description: "A light source that emits light in a cone shape."
local LightBridge = require("@LightBridge")
local Enum = require("@EnumMap")

return LightBridge.Define("SpotLight", "Spot", {
	Angle = 90,
	Face = Enum.NormalId.Front,
	Color = LightBridge.DefaultColor,
	Brightness = 15,
	Range = 12,
	CastShadow = false,
	Enabled = true,
	Transparency = 0,
	Position = LightBridge.DefaultPosition,
	DebugShape = false,
	Name = "SpotLight",
	BaseClass = "Kinemium.light",
})
