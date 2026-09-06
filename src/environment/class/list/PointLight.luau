-- description: "Emits light uniformly in all directions from a single point."
local LightBridge = require("@LightBridge")

return LightBridge.Define("PointLight", "Point", {
	Color = LightBridge.DefaultColor,
	Brightness = 15,
	Range = 12,
	CastShadow = false,
	Enabled = true,
	Transparency = 0,
	Position = LightBridge.DefaultPosition,
	DebugShape = false,
	Name = "PointLight",
	BaseClass = "Kinemium.light",
})
