-- description: "A Filament material shader parented under a BasePart."
local ShaderInstance = require("@ShaderInstance")

local propTable = {
	Name = "MaterialShader",
	BaseClass = "ShaderInstance",
}

return {
	class = "MaterialShader",
	callback = function(instance, renderer)
		instance:SetProperties(propTable)
		return ShaderInstance.Attach(instance, renderer, "surface", ShaderInstance.DefaultMaterialSource, {
			tint = { 0.12, 0.55, 1.0, 1.0 },
			roughness = 0.22,
		})
	end,
	inherit = function(target)
		for name, value in pairs(propTable) do
			target[name] = value
		end
	end,
}
