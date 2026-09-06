-- description: "A local 2D transform used as a Box2D joint anchor."
local Vector2 = require("@Vector2")

local propTable = {
	Name = "Attachment2D",
	BaseClass = "Attachment2D",
	Position = Vector2.new(0, 0),
	Rotation = 0,
	WorldPosition = Vector2.new(0, 0),
	WorldRotation = 0,
	Visible = true,
}

local function rotate(point, degrees)
	local angle = math.rad(degrees)
	local c, s = math.cos(angle), math.sin(angle)
	return Vector2.new(point.X * c - point.Y * s, point.X * s + point.Y * c)
end

local function isBody2D(value)
	return value ~= nil and (value.ClassName == "Body2D" or value.BaseClass == "Body2D")
end

return {
	class = "Attachment2D",
	callback = function(instance)
		instance:SetProperties(propTable)
		local parentConnection
		local syncing = false

		local function worldPosition()
			local parent = instance.Parent
			if not isBody2D(parent) then
				return instance.Position
			end
			return parent.Position + rotate(instance.Position, parent.Rotation or 0)
		end

		local function worldRotation()
			local parent = instance.Parent
			return (isBody2D(parent) and (parent.Rotation or 0) or 0) + instance.Rotation
		end

		local function syncWorldTransform()
			if syncing then
				return
			end
			syncing = true
			instance.WorldPosition = worldPosition()
			instance.WorldRotation = worldRotation()
			syncing = false
		end

		local function bindParent()
			if parentConnection then
				parentConnection:Disconnect()
				parentConnection = nil
			end
			local parent = instance.Parent
			if isBody2D(parent) then
				parentConnection = parent.Changed:Connect(function(property)
					if property == "Position" or property == "Rotation" then
						syncWorldTransform()
					end
				end)
			end
			syncWorldTransform()
		end

		instance:SetBarrier("Parent", function(parent)
			if parent ~= nil and not isBody2D(parent) then
				warn("Attachment2D.Parent must be a Body2D")
				return false
			end
			return true
		end)

		instance.GetBody = function(self)
			return isBody2D(self.Parent) and self.Parent or nil
		end
		instance.GetWorldPosition = function()
			return worldPosition()
		end
		instance.GetWorldRotation = function()
			return worldRotation()
		end
		instance.SetWorldPosition = function(self, position)
			assert(type(position) == "table" and position.X and position.Y, "position must be a Vector2")
			local parent = self.Parent
			if isBody2D(parent) then
				self.Position = rotate(position - parent.Position, -(parent.Rotation or 0))
			else
				self.Position = position
			end
		end
		instance.SetWorldRotation = function(self, rotation)
			assert(type(rotation) == "number", "rotation must be a number")
			local parent = self.Parent
			self.Rotation = rotation - (isBody2D(parent) and (parent.Rotation or 0) or 0)
		end

		instance.Changed:Connect(function(property)
			if syncing then
				return
			end
			if property == "Parent" then
				bindParent()
			elseif property == "Position" or property == "Rotation" then
				syncWorldTransform()
			end
		end)
		instance.Destroying:Connect(function()
			if parentConnection then
				parentConnection:Disconnect()
			end
		end)
		syncWorldTransform()
		return instance
	end,
	inherit = function(target)
		for key, value in pairs(propTable) do
			target[key] = value
		end
	end,
}
