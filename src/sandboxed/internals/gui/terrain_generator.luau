local StudioThemeService = game:GetService("StudioThemeService")
local Immco = require("@Immco")
local Argon = require("@Argon")

if IsServer or IsClient then
	return
end

repeat
	task.wait()
until game.CoreGui:FindFirstChild("Studio") and ishared.StudioSystem

local theme = StudioThemeService.SelectedTheme
local retained = {}
local visible = false
local status = "Ready"

local terrainType = "mountains"
local terrainMaterial = "auto"
local caves = true

local TERRAIN_TYPES = {
	{ Text = "Flat", Value = "flat" },
	{ Text = "Hills", Value = "hills" },
	{ Text = "Mountains", Value = "mountains" },
}

local TERRAIN_MATERIALS = {
	{ Text = "Auto (Layered)", Value = "auto" },
	{ Text = "Grass", Value = "grass" },
	{ Text = "Sand", Value = "sand" },
	{ Text = "Slate", Value = "slate" },
	{ Text = "Concrete", Value = "concrete" },
	{ Text = "Smooth Plastic", Value = "smoothplastic" },
	{ Text = "Wood", Value = "wood" },
}

ishared.StudioSystem:Connect(function(route)
	if route == "toggle_terrain_generator" then
		visible = not visible
	end
end)

local function field(id, value, x, y, width, dt)
	return Immco.TextInput({
		x = x,
		y = y,
		width = width,
		height = 36,
		text = value,
		RetainedStorage = retained,
		id = id,
		renderer = renderer,
		engine_window = renderer.Window,
		theme = theme,
		Color = theme.BgColor,
		TextColor = theme.TextColor,
	}, dt)
end

local function button(rect, label, callback, dt, selected)
	Immco.TextButton({
		x = rect.x,
		y = rect.y,
		width = rect.width,
		height = rect.height,
		text = label,
		Color = selected and theme.AccentColor
			or (renderer:isMouseInRect(rect) and theme.ThirdColor or theme.SecondaryColor),
		TextColor = theme.TextColor,
		BgVisible = true,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)
	if renderer:HasClicked(rect) then
		callback()
	end
end

local function dropdown(id, options, initialSelected, x, y, width, dt, onChanged)
	return Immco.Dropdown({
		RetainedStorage = retained,
		id = id,
		renderer = renderer,
		window = renderer.Window,
		theme = theme,

		x = x,
		y = y,
		width = width,
		height = 36,

		Options = options,
		InitialSelected = initialSelected,

		OptionHeight = 22,
		MaxVisibleOptions = 4,

		OnChanged = onChanged,
	}, dt)
end

renderer.Pool.new("2da", function(lib)
	if not visible then
		return
	end
	local windowWidth, windowHeight = Argon:GetWindowPixelSize(renderer.Window)
	if not windowWidth or not windowHeight then
		return
	end
	local dt = lib.dt
	local width, height = 560, 580
	local x = math.floor((windowWidth - width) / 2)
	local y = math.floor((windowHeight - height) / 2)
	theme = StudioThemeService.SelectedTheme
	Immco.Widget({
		x = x,
		y = y,
		width = width,
		height = height,
		title = "Terrain Generator",
		theme = theme,
		engine_window = renderer.Window,
		renderer = renderer,
		Draggable = true,
		RetainedStorage = retained,
		id = "terrain-generator-widget",
		OnMoved = function(nextX, nextY)
			x, y = nextX, nextY
		end,
		callback = function() end,
	}, dt)

	Immco.Text({
		x = x + 18,
		y = y + 60,
		text = "Origin X / Y / Z",
		Color = theme.SecondaryTextColor,
		TextSize = 14,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	local originX = field("terrain-x", "0", x + 18, y + 76, 166, dt)
	local originY = field("terrain-y", "0", x + 197, y + 76, 166, dt)
	local originZ = field("terrain-z", "0", x + 376, y + 76, 166, dt)

	Immco.Text({
		x = x + 18,
		y = y + 126,
		text = "Radius / Height",
		Color = theme.SecondaryTextColor,
		TextSize = 14,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	local terrainRadius = field("terrain-radius", "32", x + 18, y + 142, 254, dt)
	local terrainHeight = field("terrain-height", "14", x + 288, y + 142, 254, dt)

	Immco.Text({
		x = x + 18,
		y = y + 192,
		text = "Terrain Type / Material",
		Color = theme.SecondaryTextColor,
		TextSize = 14,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	Immco.Text({
		x = x + 18,
		y = y + 330,
		text = "Seed / Noise Scale / Roughness",
		Color = theme.SecondaryTextColor,
		TextSize = 14,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	local seedValue = field("terrain-seed", "49297", x + 18, y + 346, 166, dt)
	local noiseScaleValue = field("terrain-noise-scale", "1", x + 197, y + 346, 166, dt)
	local roughnessValue = field("terrain-roughness", "1", x + 376, y + 346, 166, dt)

	Immco.Text({
		x = x + 18,
		y = y + 396,
		text = "Caves / Cave Density / Cave Size",
		Color = theme.SecondaryTextColor,
		TextSize = 14,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	button(
		{
			x = x + 18,
			y = y + 412,
			width = 166,
			height = 36,
		},
		caves and "Caves: On" or "Caves: Off",
		function()
			caves = not caves
		end,
		dt,
		caves
	)

	local caveDensityValue = field("terrain-cave-density", "1", x + 197, y + 412, 166, dt)
	local caveSizeValue = field("terrain-cave-size", "1", x + 376, y + 412, 166, dt)

	button(
		{
			x = x + 18,
			y = y + 464,
			width = 524,
			height = 36,
		},
		"Generate",
		function()
			local px = tonumber(originX) or 0
			local py = tonumber(originY) or 0
			local pz = tonumber(originZ) or 0

			local radius = math.clamp(math.floor(tonumber(terrainRadius) or 32), 4, 64)
			local h = math.clamp(math.floor(tonumber(terrainHeight) or 14), 1, 64)

			local seed = math.floor(tonumber(seedValue) or 49297)
			local noiseScale = math.clamp(tonumber(noiseScaleValue) or 1, 0.1, 4)
			local roughness = math.clamp(tonumber(roughnessValue) or 1, 0, 3)

			local caveDensity = math.clamp(tonumber(caveDensityValue) or 1, 0, 4)
			local caveSize = math.clamp(tonumber(caveSizeValue) or 1, 0.25, 3)

			status = "Generating..."

			task.spawn(function()
				local success, err = pcall(function()
					workspace.Terrain:Fill(px, py, pz, radius, h, {
						terrainType = terrainType,

						-- Keeps compatibility with the old Fill implementation.
						mountains = terrainType == "mountains",

						material = terrainMaterial,

						caves = caves,
						seed = seed,

						noiseScale = noiseScale,
						roughness = roughness,

						caveDensity = caveDensity,
						caveSize = caveSize,
					})
				end)

				if success then
					local diameter = radius * 2 + 1

					status = `Generated {diameter} x {diameter} {terrainType} terrain ({terrainMaterial})`
				else
					status = `Generation failed: {err}`
				end
			end)
		end,
		dt
	)

	button(
		{
			x = x + 18,
			y = y + 516,
			width = 254,
			height = 36,
		},
		"Clear Terrain",
		function()
			workspace.Terrain:ResetReplicationData()
			workspace.Terrain:GenerateMesh()
			status = "Terrain cleared"
		end,
		dt
	)

	button(
		{
			x = x + 288,
			y = y + 516,
			width = 254,
			height = 36,
		},
		"Close",
		function()
			visible = false
		end,
		dt
	)

	Immco.Text({
		x = x + 18,
		y = y + 570,
		text = status,
		Color = theme.SecondaryTextColor,
		TextSize = 13,
		theme = theme,
		engine_window = renderer.Window,
	}, dt)

	-- Draw dropdowns last so their option lists appear above the rest of the UI.
	dropdown("terrain-type", TERRAIN_TYPES, 3, x + 18, y + 208, 254, dt, function(_, value)
		terrainType = value
	end)

	dropdown("terrain-material", TERRAIN_MATERIALS, 1, x + 288, y + 208, 254, dt, function(_, value)
		terrainMaterial = value
	end)
end)
