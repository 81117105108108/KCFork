-- description: "A focused light emitted from one face of a part."
local LightBridge = require("@LightBridge")
local Enum = require("@EnumMap")

return LightBridge.Define("SurfaceLight", "Surface", {
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
	Name = "SurfaceLight",
	BaseClass = "Kinemium.light",
})
