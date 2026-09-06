local Instance = require("@Instance")
local Vector3 = require("@Vector3")
local Lighting = Instance.new("Lighting")
local Color3 = require("@Color3")
local argon = require("@Argon")
local Stars = {}
local Enum = require("@EnumMap")

local STAR_COUNT = 3000
local STAR_RADIUS = 1000

for i = 1, STAR_COUNT do
	local z = math.random() * 2 - 1
	local theta = math.random() * math.pi * 2
	local r = math.sqrt(1 - z * z)

	table.insert(Stars, {
		pos = Vector3.new(r * math.cos(theta) * STAR_RADIUS, z * STAR_RADIUS, r * math.sin(theta) * STAR_RADIUS),
		size = math.random(),
	})
end

local function calculateSunDirection(time, latitude)
	local solarAngle = ((time % 24) - 6) / 24 * math.pi * 2
	local latitudeAngle = math.rad(math.clamp(latitude, -90, 90))
	return Vector3.new(
		-math.cos(solarAngle),
		math.sin(solarAngle) * math.cos(latitudeAngle),
		math.sin(solarAngle) * math.sin(latitudeAngle)
	):Unit()
end

function Lighting:GetSunDirection()
	return calculateSunDirection(self.ClockTime, self.GeographicLatitude)
end

function Lighting:GetDaylight()
	local elevation = self:GetSunDirection().Y
	return math.clamp((elevation + 0.12) / 0.3, 0, 1)
end

Lighting.InitRenderer = function(renderer, renderer_signal, datamodel)
	if _G.IsHeadless then
		return
	end

	Lighting:SetProperties({
		Ambient = Color3.fromRGB(105, 120, 145),
		Brightness = 2.0,

		ColorShift_Top = Color3.fromRGB(16, 48, 150),
		ColorShift_Bottom = Color3.fromRGB(75, 160, 235),

		OutdoorAmbient = Color3.fromRGB(125, 140, 165),

		GlobalShadows = true,
		ClockTime = 14.0,
		GeographicLatitude = 0.0,
		EnableDayCycle = false,
		DayCycleSpeed = 1.0,
		GraphicsPreset = Enum.KinemiumGraphicsPreset.Medium,
	})
	Lighting._Intents = Enum.PluginIntents.Graphics

	local lightingProperties = {
		Ambient = true,
		Brightness = true,
		ColorShift_Top = true,
		ColorShift_Bottom = true,
		OutdoorAmbient = true,
		ClockTime = true,
		GeographicLatitude = true,
	}

	local updateLighting
	Lighting.Changed:Connect(function(property)
		if property == "GraphicsPreset" then
			local val = Lighting.GraphicsPreset.Value
			argon:SetPostProcessingPreset(renderer.Window, val)
		elseif property == "GlobalShadows" then
			argon:SetShadowOptions(renderer.Window, Lighting.GlobalShadows == true, "pcf")
		elseif lightingProperties[property] and updateLighting then
			updateLighting()
		end
	end)
	argon:SetPostProcessingPreset(renderer.Window, "medium")
	argon:SetShadowOptions(renderer.Window, Lighting.GlobalShadows == true, "pcf")

	updateLighting = function()
		local ambient = Lighting.Ambient
		local outdoor = Lighting.OutdoorAmbient
		local top = Lighting.ColorShift_Top
		local bottom = Lighting.ColorShift_Bottom
		local daylight = Lighting:GetDaylight()
		local sunset = math.clamp(1 - math.abs(Lighting:GetSunDirection().Y) * 5, 0, 1) * (1 - daylight * 0.35)
		local nightTop = Color3.fromRGB(4, 7, 20)
		local nightHorizon = Color3.fromRGB(12, 18, 38)
		local sky = nightTop:Lerp(top, daylight)
		local horizon = nightHorizon:Lerp(bottom, daylight)
		horizon = Color3.new(
			math.clamp(horizon.R + sunset * 0.32, 0, 1),
			math.clamp(horizon.G + sunset * 0.11, 0, 1),
			horizon.B
		)
		local ground = ambient:Lerp(outdoor, daylight * 0.35)

		local sunDirection = Lighting:GetSunDirection()
		argon:SetSkyAtmosphere(
			renderer.Window,
			argon:Vector3(sunDirection.X, sunDirection.Y, sunDirection.Z),
			argon:RGBA(sky.R * 255, sky.G * 255, sky.B * 255),
			argon:RGBA(horizon.R * 255, horizon.G * 255, horizon.B * 255),
			argon:RGBA(ground.R * 255, ground.G * 255, ground.B * 255),
			math.max(0, Lighting.Brightness) * 50000
		)
	end

	updateLighting()

	argon:SetSunRays(renderer.Window, true, {
		Distance = 0.3,
		CutOffDistance = 1000,
		MaximumOpacity = 0.2,
		HeightFalloff = 0.018,
		Density = 0.014,
		InScatteringSize = 3,
		Color = argon:RGBA(55, 55, 55),
	})

	argon:SetScreenSpaceReflections(renderer.Window, true)

	local cycleAccumulator = 0
	renderer.Hook.new("Renderstep", function(deltaTime)
		if Lighting.EnableDayCycle ~= true then
			cycleAccumulator = 0
			return
		end
		cycleAccumulator += math.max(0, tonumber(deltaTime) or 0)
		if cycleAccumulator < 0.1 then
			return
		end
		local elapsed = cycleAccumulator
		cycleAccumulator = 0
		Lighting.ClockTime = (Lighting.ClockTime + elapsed * (tonumber(Lighting.DayCycleSpeed) or 1) / 60) % 24
	end)
end

return Lighting
