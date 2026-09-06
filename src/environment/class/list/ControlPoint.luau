-- description: "An ordered position and pair of tangents used by Path3D."
local CFrame = require("@CFrame")
local Vector3 = require("@Vector3")

local propTable = {
	Name = "ControlPoint",
	BaseClass = "Instance",
	Position = Vector3.new(0, 0, 0),
	CFrame = CFrame.new(0, 0, 0),
	TangentIn = Vector3.new(0, 0, 0),
	TangentOut = Vector3.new(0, 0, 0),
	Order = 0,
}

return {
	class = "ControlPoint",

	callback = function(instance)
		instance:SetProperties(propTable)

		local synchronizing = false
		instance.Changed:Connect(function(property, value)
			if synchronizing then
				return
			end

			if property == "Position" then
				synchronizing = true
				local props = rawget(instance, "_props")
				props.CFrame = props.CFrame:WithPosition(value)
				synchronizing = false
			elseif property == "CFrame" and value and value.Position then
				synchronizing = true
				rawget(instance, "_props").Position = value.Position
				synchronizing = false
			end
		end)

		return instance
	end,

	inherit = function()
		return propTable
	end,
}
