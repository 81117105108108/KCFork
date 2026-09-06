local typedefs = require("../typedefs")
local Titlebar = require("./Titlebar")
local Rectangle = require("./Rectangle")
local argon = require("@Argon")
local Vector2 = require("@Vector2")
local dragStates = {}

local function withTransparency(color, transparency: number?)
	if not color or transparency == nil then
		return color
	end

	return {
		R = color.R,
		G = color.G,
		B = color.B,
		A = (color.A or 1) * math.clamp(1 - transparency, 0, 1),
	}
end

local function isVisibleColor(color): boolean
	return color ~= nil and (color.A == nil or color.A > 0)
end

return function(params: typedefs.WidgetParams, dt: number)
	local window = params.engine_window
	local theme = params.theme
	local retained = params.RetainedStorage or params.retained
	local renderer = params.renderer or (typeof(renderer) ~= "nil" and renderer or nil)

	local titleBarHeight = 32
	local cornerRadius = theme.CornerRadius or 12
	local x, y = params.x, params.y

	if params.Draggable and renderer then
		local stateKey = params.id or params.title or tostring(params)
		local stateStore = retained or dragStates
		stateStore[stateKey] = stateStore[stateKey] or { x = x, y = y }
		local state = stateStore[stateKey]
		local mouse = argon:GetMousePosition()
		local titleRect = { x = state.x, y = state.y, width = params.width, height = titleBarHeight }
		if not state.dragging and argon:IsMouseButtonPressed(1) and renderer:isMouseInRect(titleRect) then
			state.dragging = true
			state.offsetX = mouse.X - state.x
			state.offsetY = mouse.Y - state.y
		end
		if state.dragging then
			if argon:IsMouseButtonDown(1) then
				local windowWidth, windowHeight = argon:GetWindowPixelSize(window)
				state.x = mouse.X - (state.offsetX or 0)
				state.y = mouse.Y - (state.offsetY or 0)
				if windowWidth and windowHeight then
					state.x = math.clamp(state.x, 0, math.max(0, windowWidth - params.width))
					state.y = math.clamp(state.y, 0, math.max(0, windowHeight - titleBarHeight))
				end
			elseif argon:IsMouseButtonReleased(1) then
				state.dragging = false
			end
		end
		x, y = state.x, state.y
		if params.OnMoved then
			params.OnMoved(x, y)
		end
	end

	argon:DrawUIShadow(window, {
		x = x,
		y = y,
		width = params.width,
		height = params.height,
		Color = argon:RGBA(0, 0, 0),
	}, 4, 4, Vector2.new(0, 0), 8, 0)

	argon:Save(window)

	argon:ClipRoundRect(window, {
		x = x,
		y = y,
		width = params.width,
		height = params.height,
	}, cornerRadius, cornerRadius)

	local backgroundColor = withTransparency(params.Color or theme.ThirdColor, params.BackgroundTransparency)
	if isVisibleColor(backgroundColor) then
		Rectangle({
			x = x,
			y = y,
			width = params.width,
			height = params.height,
			Color = backgroundColor,
			theme = theme,
			engine_window = window,
		}, dt)
	end

	local outlineColor = withTransparency(params.OutlineColor or theme.SecondaryColor, params.OutlineTransparency)
	if isVisibleColor(outlineColor) then
		Rectangle({
			x = x,
			y = y,
			width = params.width,
			height = params.height,
			Color = outlineColor,
			theme = theme,
			engine_window = window,
			isOutline = true,
		}, dt)
	end

	if params.EnableTitlebar or params.title then
		Titlebar({
			engine_window = window,

			x = x,
			y = y,
			width = params.width,
			height = titleBarHeight,
			Color = theme.SecondaryColor,

			title = params.title,
			tabs = params.tabs,
			activeTab = params.activeTab,
			OnTabChanged = params.OnTabChanged,
			renderer = renderer,
			theme = theme,
		}, dt)
	end

	if params.callback then
		params.callback({
			x = x,
			y = y + titleBarHeight,
			width = params.width,
			height = params.height,
			window = window,
			theme = theme,
		})
	end
	argon:Restore(window)
end
