local StudioThemeService = game:GetService("StudioThemeService")
local Selection = game:GetService("Selection")
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
local status = "Select or create a shader."
local selectedShader = nil

local function isShaderInstance(object)
	return object and (object.ClassName == "MaterialShader" or object.ClassName == "PostProcessShader")
end

local function shaderClasses()
	local result = {}
	for className in pairs(Instance.getClasses()) do
		if className == "MaterialShader" or className == "PostProcessShader" then
			result[#result + 1] = className
		end
	end
	table.sort(result)
	return result
end

local function shaderInstances()
	local result = {}
	for _, object in pairs(Instance.GetActiveInstances()) do
		if isShaderInstance(object) and rawget(object, "_props") then
			result[#result + 1] = object
		end
	end
	table.sort(result, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return result
end

local function selectShader(shader)
	selectedShader = shader
	if shader then
		Selection:Set({ shader })
		status = `Editing {shader:GetFullName()}`
	end
end

local function createShader(className)
	local shader = Instance.new(className)
	if className == "PostProcessShader" then
		shader.Parent = game:GetService("Lighting")
	else
		local selected = Selection:Get()
		local parent = selected and selected[1]
		if parent and parent:IsA("BasePart") then
			shader.Parent = parent
		else
			status = "MaterialShader created unparented; select a BasePart first to bind it immediately."
		end
	end
	selectShader(shader)
end

local function button(rect, label, callback, dt, active)
	Immco.TextButton({
		x = rect.x,
		y = rect.y,
		width = rect.width,
		height = rect.height,
		text = label,
		Color = active and theme.ThirdColor
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

local function valuesFromText(text, length)
	local result = {}
	for token in tostring(text):gmatch("[^,%s]+") do
		local value = tonumber(token)
		if value == nil then
			return nil
		end
		result[#result + 1] = value
	end
	if #result ~= length then
		return nil
	end
	return length == 1 and result[1] or result
end

local function valueComponents(value)
	if type(value) == "number" then
		return { value }
	end
	if type(value) == "vector" then
		return { value.X, value.Y, value.Z }
	end
	if type(value) ~= "table" then
		return {}
	elseif value.X ~= nil and value.Y ~= nil then
		return value.W ~= nil and { value.X, value.Y, value.Z, value.W }
			or (value.Z ~= nil and { value.X, value.Y, value.Z } or { value.X, value.Y })
	elseif value.R ~= nil and value.G ~= nil and value.B ~= nil then
		return value.A ~= nil and { value.R, value.G, value.B, value.A } or { value.R, value.G, value.B }
	end
	return value
end

local function valueText(value, length)
	local components, text = valueComponents(value), {}
	for index = 1, length do
		text[index] = tostring(components[index] or 0)
	end
	return table.concat(text, ", ")
end

local function valuesEqual(a, b, length)
	local aa, bb = valueComponents(a), valueComponents(b)
	for index = 1, length do
		if tonumber(aa[index]) ~= tonumber(bb[index]) then
			return false
		end
	end
	return true
end

ishared.StudioSystem:Connect(function(route)
	if route == "toggle_shader_maker" then
		visible = not visible
		if visible then
			local selected = Selection:Get()
			if selected and isShaderInstance(selected[1]) then
				selectedShader = selected[1]
			end
		end
	end
end)

renderer.Pool.new("2da", function(lib)
	if not visible then
		return
	end
	local windowWidth, windowHeight = Argon:GetWindowPixelSize(renderer.Window)
	if not windowWidth or not windowHeight then
		return
	end
	local dt = lib.dt
	local width = math.min(1220, windowWidth - 30)
	local topInset = math.min(178, math.max(36, windowHeight - 360))
	local height = math.min(680, windowHeight - topInset - 16)
	local x = math.floor((windowWidth - width) / 2)
	local y = topInset

	Immco.Widget({
		x = x,
		y = y,
		width = width,
		height = height,
		title = "Filament Shader Studio",
		theme = theme,
		engine_window = renderer.Window,
		renderer = renderer,
		Draggable = true,
		RetainedStorage = retained,
		id = "shader-instance-studio",
		callback = function(params)
			local x = params.x
			local y = params.y

			local sidebarX = x + 14
			local sidebarWidth = 224
			local contentTop = y + 48
			local contentBottom = y + height - 48
			local contentHeight = contentBottom - contentTop

			------------------------------------------------------------------------
			-- Sidebar
			------------------------------------------------------------------------

			Immco.Text({
				x = sidebarX,
				y = contentTop,
				text = "Available shader classes",
				Color = theme.TextColor,
				TextSize = 14,
				theme = theme,
				engine_window = renderer.Window,
			}, dt)

			local classItems = {}

			for _, className in ipairs(shaderClasses()) do
				table.insert(classItems, {
					Text = `+ {className}`,
					Width = sidebarWidth,
					Height = 28,

					OnClick = function()
						createShader(className)
					end,
				})
			end

			local _, classGroupHeight = Immco.ButtonGroup({
				x = sidebarX,
				y = contentTop + 22,

				width = sidebarWidth,

				Orientation = "vertical",
				ItemHeight = 28,
				PaddingX = 10,

				BackgroundColor = theme.SecondaryColor,
				ButtonColor = theme.SecondaryColor,
				HoverColor = theme.ThirdColor,
				PressedColor = theme.ThirdColor,

				BorderColor = theme.ThirdColor,
				DividerColor = theme.ThirdColor,

				ShowBorder = true,
				ShowDividers = true,

				Items = classItems,

				renderer = renderer,
				engine_window = renderer.Window,
				theme = theme,
			}, dt)

			local instancesTitleY = contentTop + 22 + classGroupHeight + 16

			Immco.Text({
				x = sidebarX,
				y = instancesTitleY,
				text = "Shader instances",
				Color = theme.TextColor,
				TextSize = 14,
				theme = theme,
				engine_window = renderer.Window,
			}, dt)

			local instanceItems = {}
			local instances = shaderInstances()

			for _, shader in ipairs(instances) do
				local currentShader = shader
				local parentName = currentShader.Parent and currentShader.Parent.Name or "unparented"
				local active = currentShader == selectedShader

				table.insert(instanceItems, {
					Text = `{currentShader.Name}  [{parentName}]`,
					Width = sidebarWidth,
					Height = 30,

					Color = active and theme.ThirdColor or theme.SecondaryColor,
					HoverColor = theme.ThirdColor,

					OnClick = function()
						selectShader(currentShader)
					end,
				})
			end

			local instanceListY = instancesTitleY + 22
			local instanceViewHeight = math.max(0, contentBottom - instanceListY)

			if #instanceItems > 0 then
				Immco.Scroller({
					id = "shader-instance-list",

					x = sidebarX,
					y = instanceListY,

					width = sidebarWidth,
					height = instanceViewHeight,

					ViewHeight = instanceViewHeight,
					ContentHeight = #instanceItems * 30,

					ScrollSpeed = 40,
					ScrollLerpSpeed = 20,

					renderer = renderer,
					window = renderer.Window,
					theme = theme,

					RetainedStorage = retained,

					callback = function(scroll)
						Immco.ButtonGroup({
							x = scroll.x,
							y = scroll.y,

							width = sidebarWidth,

							Orientation = "vertical",
							ItemHeight = 30,
							PaddingX = 8,

							BackgroundColor = theme.SecondaryColor,
							ButtonColor = theme.SecondaryColor,
							HoverColor = theme.ThirdColor,
							PressedColor = theme.ThirdColor,

							BorderColor = theme.ThirdColor,
							DividerColor = theme.ThirdColor,

							ShowBorder = true,
							ShowDividers = true,

							Items = instanceItems,

							renderer = renderer,
							engine_window = renderer.Window,
							theme = theme,
						}, dt)
					end,
				}, dt)
			else
				Immco.Text({
					x = sidebarX,
					y = instanceListY + 6,
					text = "No shader instances.",
					Color = theme.SecondaryTextColor,
					TextSize = 13,
					theme = theme,
					engine_window = renderer.Window,
				}, dt)
			end

			------------------------------------------------------------------------
			-- Empty selection
			------------------------------------------------------------------------

			if not isShaderInstance(selectedShader) or not rawget(selectedShader, "_props") then
				selectedShader = nil

				Immco.Text({
					x = x + 264,
					y = y + 72,
					text = "Create a shader class or select an existing shader instance.",
					Color = theme.SecondaryTextColor,
					TextSize = 15,
					theme = theme,
					engine_window = renderer.Window,
				}, dt)
			else
				--------------------------------------------------------------------
				-- Shader editor
				--------------------------------------------------------------------

				local editorX = x + 252
				local uniformWidth = 285
				local editorWidth = width - 280 - uniformWidth

				Immco.Text({
					x = editorX,
					y = contentTop,
					text = `{selectedShader.ClassName}: {selectedShader.Name}`,
					Color = theme.TextColor,
					TextSize = 15,
					theme = theme,
					engine_window = renderer.Window,
				}, dt)

				local source = Immco.TextInput({
					x = editorX,
					y = contentTop + 24,

					width = editorWidth,
					height = height - 168,

					text = selectedShader.Source,

					MultiLine = true,
					CodeEditor = true,
					AllowTab = true,
					ShowLineNumbers = true,

					RetainedStorage = retained,
					id = "shader-source-" .. tostring(selectedShader),

					renderer = renderer,
					engine_window = renderer.Window,
					theme = theme,

					Color = theme.BgColor,
					TextColor = theme.TextColor,
				}, dt)

				--------------------------------------------------------------------
				-- Editor actions
				--------------------------------------------------------------------

				Immco.ButtonGroup({
					x = editorX,
					y = y + height - 82,

					height = 34,

					ItemHeight = 34,
					PaddingX = 14,

					BackgroundColor = theme.SecondaryColor,
					ButtonColor = theme.SecondaryColor,
					HoverColor = theme.ThirdColor,
					PressedColor = theme.ThirdColor,

					BorderColor = theme.ThirdColor,
					DividerColor = theme.ThirdColor,

					ShowBorder = true,
					ShowDividers = true,

					Items = {
						{
							Text = "Compile Source",
							Width = 142,

							OnClick = function()
								selectedShader.Source = source

								local compileError = selectedShader:GetCompileError()

								status = compileError and ("Compile error: " .. compileError)
									or "Shader compiled and rebound."
							end,
						},

						{
							Text = selectedShader.Enabled and "Disable" or "Enable",
							Width = 112,

							OnClick = function()
								selectedShader.Enabled = not selectedShader.Enabled

								status = selectedShader.Enabled and "Shader enabled." or "Shader disabled."
							end,
						},
					},

					renderer = renderer,
					engine_window = renderer.Window,
					theme = theme,
				}, dt)

				--------------------------------------------------------------------
				-- Uniforms
				--------------------------------------------------------------------

				local uniformsX = editorX + editorWidth + 16
				local uniformsY = contentTop + 28
				local uniformsHeight = height - 120

				Immco.Text({
					x = uniformsX,
					y = contentTop,
					text = "Live uniforms",
					Color = theme.TextColor,
					TextSize = 15,
					theme = theme,
					engine_window = renderer.Window,
				}, dt)

				local definitions = selectedShader:GetUniformDefinitions()

				if #definitions == 0 then
					Immco.Text({
						x = uniformsX,
						y = uniformsY,
						text = "No editable float uniforms in source.",
						Color = theme.SecondaryTextColor,
						TextSize = 13,
						theme = theme,
						engine_window = renderer.Window,
					}, dt)
				else
					local uniformRowHeight = 64
					local uniformContentHeight = 8 + #definitions * uniformRowHeight

					Immco.Scroller({
						id = "shader-uniform-list-" .. tostring(selectedShader),

						x = uniformsX,
						y = uniformsY,

						width = uniformWidth,
						height = uniformsHeight,

						ViewHeight = uniformsHeight,
						ContentHeight = uniformContentHeight,

						ScrollSpeed = 40,
						ScrollLerpSpeed = 20,

						renderer = renderer,
						window = renderer.Window,
						theme = theme,

						RetainedStorage = retained,

						callback = function(scroll)
							-- Scroller clips exactly at its top edge; leave room for the
							-- font ascenders instead of losing the first uniform label.
							local uniformY = scroll.y + 8

							for _, definition in ipairs(definitions) do
								Immco.Text({
									x = scroll.x,
									y = uniformY,

									text = `{definition.Name} ({definition.Type})`,

									Color = theme.SecondaryTextColor,
									TextSize = 13,

									theme = theme,
									engine_window = renderer.Window,
								}, dt)

								local current = selectedShader:GetUniform(definition.Name)

								local edited = Immco.TextInput({
									x = scroll.x,
									y = uniformY + 20,

									width = uniformWidth - 12,
									height = 30,

									text = valueText(current, definition.Length),

									RetainedStorage = retained,
									id = `shader-uniform-{tostring(selectedShader)}-{definition.Name}`,

									renderer = renderer,
									engine_window = renderer.Window,
									theme = theme,

									Color = theme.BgColor,
									TextColor = theme.TextColor,
								}, dt)

								local parsed = valuesFromText(edited, definition.Length)

								if parsed ~= nil and not valuesEqual(parsed, current, definition.Length) then
									local ok, reason = selectedShader:SetUniform(definition.Name, parsed)

									status = ok and `Updated {definition.Name} in real time.` or tostring(reason)
								end

								uniformY += uniformRowHeight
							end
						end,
					}, dt)
				end
			end

			------------------------------------------------------------------------
			-- Footer
			------------------------------------------------------------------------

			Immco.Text({
				x = x + 14,
				y = y + height - 30,

				text = status,

				Color = theme.SecondaryTextColor,
				TextSize = 13,

				theme = theme,
				engine_window = renderer.Window,
			}, dt)

			local closeRect = {
				x = x + width - 106,
				y = y + 8,
				width = 92,
				height = 28,
			}

			Immco.TextButton({
				x = closeRect.x,
				y = closeRect.y,
				width = closeRect.width,
				height = closeRect.height,

				text = "Close",

				Color = renderer:isMouseInRect(closeRect) and theme.ThirdColor or theme.SecondaryColor,

				TextColor = theme.TextColor,

				theme = theme,
				engine_window = renderer.Window,
			}, dt)

			if renderer:HasClicked(closeRect) then
				visible = false
			end
		end,
	}, dt)
end)
