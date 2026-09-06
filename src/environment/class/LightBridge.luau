local Argon = require("@Argon")
local Color3 = require("@Color3")
local Vector3 = require("@Vector3")
local Enum = require("@EnumMap")

local LightBridge = {}

local function faceDirection(cframe, face)
	if not cframe then
		return Vector3.new(0, 0, -1)
	elseif face == Enum.NormalId.Top then
		return cframe:GetUpVector()
	elseif face == Enum.NormalId.Bottom then
		return -cframe:GetUpVector()
	elseif face == Enum.NormalId.Right then
		return cframe:GetRightVector()
	elseif face == Enum.NormalId.Left then
		return -cframe:GetRightVector()
	elseif face == Enum.NormalId.Back then
		return -cframe:GetLookVector()
	end
	return cframe:GetLookVector()
end

local function resolveTransform(instance, lightType)
	local parent = instance.Parent
	local cframe, size
	if parent and parent.ClassName == "Attachment" then
		local base = parent.Parent and parent.Parent.CFrame
		cframe = base and parent.CFrame and base * parent.CFrame or parent.WorldCFrame or parent.CFrame
	elseif parent and parent.CFrame then
		cframe = parent.CFrame
		size = parent.Size
	end

	local position = cframe and cframe.Position or instance.Position or Vector3.new(0, 0, 0)
	local direction = faceDirection(cframe, instance.Face)
	if lightType == "Surface" and size then
		local halfExtent = size.Z * 0.5
		if instance.Face == Enum.NormalId.Top or instance.Face == Enum.NormalId.Bottom then
			halfExtent = size.Y * 0.5
		elseif instance.Face == Enum.NormalId.Left or instance.Face == Enum.NormalId.Right then
			halfExtent = size.X * 0.5
		end
		position += direction * halfExtent
	end
	return position, direction
end

local function sameVector(a, b)
	return a and b and math.abs(a.X - b.X) < 1e-5 and math.abs(a.Y - b.Y) < 1e-5 and math.abs(a.Z - b.Z) < 1e-5
end

function LightBridge.Define(className, lightType, properties)
	return {
		class = className,
		callback = function(instance, renderer)
			instance:SetProperties(properties)
			if _G.IsHeadless or not renderer or not renderer.Window or not Argon.CreateLight then
				return instance
			end

			local position, direction = resolveTransform(instance, lightType)
			local light = Argon:CreateLight(renderer.Window, lightType, {
				Position = position,
				Direction = direction,
				Color = instance.Color,
				Brightness = instance.Brightness * (1 - math.clamp(instance.Transparency or 0, 0, 1)),
				Range = instance.Range,
				Angle = instance.Angle,
				CastShadow = instance.CastShadow,
				Enabled = instance.Enabled,
			})
			if not light then
				return instance
			end
			instance:SetMetadata("LightObject", light)

			local function applyProperties()
				if not light then
					return
				end
				Argon:UpdateLight(renderer.Window, light, {
					Color = instance.Color,
					Brightness = instance.Brightness * (1 - math.clamp(instance.Transparency or 0, 0, 1)),
					Range = instance.Range,
					Angle = instance.Angle,
					CastShadow = instance.CastShadow,
					Enabled = instance.Enabled,
				})
			end

			instance.Changed:Connect(applyProperties)
			if renderer.Hook then
				renderer.Hook.new("Renderstep", function()
					if not light or instance.Destroyed then
						return
					end
					local nextPosition, nextDirection = resolveTransform(instance, lightType)
					if not sameVector(nextPosition, position) or not sameVector(nextDirection, direction) then
						position, direction = nextPosition, nextDirection
						Argon:UpdateLight(renderer.Window, light, {
							Position = position,
							Direction = direction,
						})
					end
				end)
			end

			instance.Destroying:Connect(function()
				if light then
					Argon:RemoveLight(renderer.Window, light)
					light = nil
					instance:SetMetadata("LightObject", nil)
				end
			end)
			return instance
		end,
		inherit = function(target)
			for property, value in pairs(properties) do
				target[property] = value
			end
		end,
	}
end

LightBridge.DefaultColor = Color3.new(1, 1, 1)
LightBridge.DefaultPosition = Vector3.new(0, 0, 0)

return LightBridge
