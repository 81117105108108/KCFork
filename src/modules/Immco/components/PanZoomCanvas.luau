local typedefs = require("../typedefs")
local argon = require("@Argon")

local SPACE_KEY = if argon.Key and argon.Key.Space then argon.Key.Space else 44

local function withAlpha(color: typedefs.RGBA, alpha: number): typedefs.RGBA
	return {
		R = color.R,
		G = color.G,
		B = color.B,
		A = (color.A or 1) * alpha,
	}
end

local function pointInRect(point, rect): boolean
	return point.X >= rect.x
		and point.X <= rect.x + rect.width
		and point.Y >= rect.y
		and point.Y <= rect.y + rect.height
end

local function roundNearest(value: number): number
	if value >= 0 then
		return math.floor(value + 0.5)
	end
	return math.ceil(value - 0.5)
end

local function formatAxisValue(value: number, step: number): string
	if math.abs(value) < 0.00001 then
		value = 0
	end

	if step >= 1 then
		return tostring(roundNearest(value))
	elseif step >= 0.1 then
		return string.format("%.1f", value)
	end

	return string.format("%.2f", value)
end

local function chooseGridStep(baseStep: number, zoom: number, minPixels: number, maxPixels: number): number
	local step = math.max(baseStep, 0.0001)

	while step * zoom < minPixels do
		step *= 2
	end

	while step * zoom > maxPixels and step > baseStep / 16 do
		step /= 2
	end

	return step
end

return function(params: typedefs.PanZoomCanvasParams, dt: number): any
	local storage = params.RetainedStorage
	local id = params.id
	local renderer = params.renderer
	local window = params.engine_window or params.window
	local theme = params.theme

	assert(storage, "PanZoomCanvas requires RetainedStorage")
	assert(id, "PanZoomCanvas requires id")
	assert(renderer, "PanZoomCanvas requires renderer")
	assert(window, "PanZoomCanvas requires engine_window or window")

	local field = storage[id]
	if not field then
		field = {
			cameraX = params.InitialCameraX or 0,
			cameraY = params.InitialCameraY or 0,
			zoom = params.InitialZoom or 1,
			dragging = false,
			dragButton = nil,
			dragMouseX = 0,
			dragMouseY = 0,
			dragCameraX = 0,
			dragCameraY = 0,
		}
		storage[id] = field
	end

	local minZoom = math.max(params.MinZoom or 0.05, 0.0001)
	local maxZoom = math.max(params.MaxZoom or 16, minZoom)
	field.zoom = math.clamp(field.zoom or 1, minZoom, maxZoom)
	field.cameraX = field.cameraX or 0
	field.cameraY = field.cameraY or 0

	local showRulers = params.ShowRulers ~= false
	local rulerSize = if showRulers then math.max(params.RulerSize or 20, 0) else 0

	local canvasRect = {
		x = params.x + rulerSize,
		y = params.y + rulerSize,
		width = math.max(1, params.width - rulerSize),
		height = math.max(1, params.height - rulerSize),
	}

	local centerScreenX = canvasRect.x + canvasRect.width * 0.5
	local centerScreenY = canvasRect.y + canvasRect.height * 0.5

	local function worldToScreen(x: number, y: number)
		return {
			X = centerScreenX + (x - field.cameraX) * field.zoom,
			Y = centerScreenY + (y - field.cameraY) * field.zoom,
		}
	end

	local function screenToWorld(x: number, y: number)
		return {
			X = field.cameraX + (x - centerScreenX) / field.zoom,
			Y = field.cameraY + (y - centerScreenY) / field.zoom,
		}
	end

	local changed = false

	local function setZoomAround(newZoom: number, screenX: number, screenY: number)
		newZoom = math.clamp(newZoom, minZoom, maxZoom)
		if math.abs(newZoom - field.zoom) < 0.000001 then
			return
		end

		local worldBefore = screenToWorld(screenX, screenY)
		field.zoom = newZoom
		field.cameraX = worldBefore.X - (screenX - centerScreenX) / field.zoom
		field.cameraY = worldBefore.Y - (screenY - centerScreenY) / field.zoom
		changed = true
	end

	local mouse = argon:GetMousePosition()
	local hovered = pointInRect(mouse, canvasRect)
	local leftButton = argon.MouseButton.Left
	local panButton = params.PanButton or argon.MouseButton.Middle
	local showZoomControls = params.ShowZoomControls ~= false
	local zoomStep = math.max(params.ZoomStep or 1.15, 1.001)

	local zoomControlRect = nil
	local minusRect = nil
	local labelRect = nil
	local plusRect = nil
	local overZoomControls = false

	if showZoomControls then
		local controlHeight = params.ZoomControlHeight or 24
		local buttonWidth = controlHeight
		local labelWidth = params.ZoomLabelWidth or 54
		zoomControlRect = {
			x = canvasRect.x + (params.ZoomControlOffsetX or 8),
			y = canvasRect.y + (params.ZoomControlOffsetY or 8),
			width = buttonWidth * 2 + labelWidth,
			height = controlHeight,
		}
		minusRect = {
			x = zoomControlRect.x,
			y = zoomControlRect.y,
			width = buttonWidth,
			height = controlHeight,
		}
		labelRect = {
			x = minusRect.x + minusRect.width,
			y = zoomControlRect.y,
			width = labelWidth,
			height = controlHeight,
		}
		plusRect = {
			x = labelRect.x + labelRect.width,
			y = zoomControlRect.y,
			width = buttonWidth,
			height = controlHeight,
		}
		overZoomControls = pointInRect(mouse, zoomControlRect)
	end

	if showZoomControls and argon:IsMouseButtonPressed(leftButton) then
		if minusRect and pointInRect(mouse, minusRect) then
			setZoomAround(field.zoom / zoomStep, centerScreenX, centerScreenY)
		elseif plusRect and pointInRect(mouse, plusRect) then
			setZoomAround(field.zoom * zoomStep, centerScreenX, centerScreenY)
		elseif labelRect and pointInRect(mouse, labelRect) then
			setZoomAround(params.ResetZoom or 1, centerScreenX, centerScreenY)
		end
	end

	local spacePan = params.EnableSpacePan ~= false and argon:IsKeyDown(SPACE_KEY)
	local leftDragPan = params.EnableLeftDragPan == true
	local requestedDragButton = nil

	if hovered and not overZoomControls then
		if argon:IsMouseButtonPressed(panButton) then
			requestedDragButton = panButton
		elseif (spacePan or leftDragPan) and argon:IsMouseButtonPressed(leftButton) then
			requestedDragButton = leftButton
		end
	end

	if requestedDragButton and not field.dragging then
		field.dragging = true
		field.dragButton = requestedDragButton
		field.dragMouseX = mouse.X
		field.dragMouseY = mouse.Y
		field.dragCameraX = field.cameraX
		field.dragCameraY = field.cameraY
	end

	if field.dragging then
		if not field.dragButton or not argon:IsMouseButtonDown(field.dragButton) then
			field.dragging = false
			field.dragButton = nil
		else
			local dx = mouse.X - field.dragMouseX
			local dy = mouse.Y - field.dragMouseY
			local newCameraX = field.dragCameraX - dx / field.zoom
			local newCameraY = field.dragCameraY - dy / field.zoom

			if newCameraX ~= field.cameraX or newCameraY ~= field.cameraY then
				field.cameraX = newCameraX
				field.cameraY = newCameraY
				changed = true
			end
		end
	end

	if hovered and not field.dragging and not overZoomControls then
		local wheel = argon:GetMouseWheelMove()
		if wheel ~= 0 then
			if params.WheelAction == "pan" then
				field.cameraY -= wheel * (params.WheelPanSpeed or 48) / field.zoom
				changed = true
			else
				setZoomAround(field.zoom * (zoomStep ^ wheel), mouse.X, mouse.Y)
			end
		end
	end

	local backgroundColor = params.BackgroundColor or theme.ThirdColor or theme.BgColor
	local textColor = params.TextColor or theme.SecondaryTextColor or theme.TextColor or argon:RGBA(210, 210, 210)
	local gridColor = params.GridColor or withAlpha(textColor, 0.10)
	local majorGridColor = params.MajorGridColor or withAlpha(textColor, 0.20)
	local rulerColor = params.RulerColor or theme.SecondaryColor or withAlpha(backgroundColor, 0.95)
	local rulerBorderColor = params.RulerBorderColor or withAlpha(textColor, 0.18)
	local axisXColor = params.AxisXColor or withAlpha(argon:RGBA(220, 78, 92), 0.9)
	local axisYColor = params.AxisYColor or withAlpha(argon:RGBA(82, 190, 105), 0.9)
	local font = argon:CreateFont(params.Font or theme.Font)
	local textSize = params.RulerTextSize or 9

	argon:DrawRectangle(window, {
		x = canvasRect.x,
		y = canvasRect.y,
		width = canvasRect.width,
		height = canvasRect.height,
		Color = backgroundColor,
	})

	argon:Save(window)
	argon:ClipRoundRect(window, canvasRect, params.CornerRadius or 0, params.CornerRadius or 0)

	local visibleMin = screenToWorld(canvasRect.x, canvasRect.y)
	local visibleMax = screenToWorld(canvasRect.x + canvasRect.width, canvasRect.y + canvasRect.height)

	local gridStep =
		chooseGridStep(params.GridSize or 32, field.zoom, params.MinGridPixels or 18, params.MaxGridPixels or 64)
	local majorEvery = math.max(1, math.floor(params.MajorGridEvery or 4))
	local majorStep = gridStep * majorEvery

	if params.ShowGrid ~= false then
		local firstX = math.floor(visibleMin.X / gridStep) * gridStep
		local firstY = math.floor(visibleMin.Y / gridStep) * gridStep
		local maxLines = params.MaxGridLines or 512
		local count = 0
		local worldX = firstX

		while worldX <= visibleMax.X and count < maxLines do
			local index = roundNearest(worldX / gridStep)
			local screen = worldToScreen(worldX, 0)
			local major = index % majorEvery == 0
			argon:DrawLine(
				window,
				{ X = screen.X, Y = canvasRect.y },
				{ X = screen.X, Y = canvasRect.y + canvasRect.height },
				if major then 1.25 else 1,
				if major then majorGridColor else gridColor
			)
			worldX += gridStep
			count += 1
		end

		count = 0
		local worldY = firstY
		while worldY <= visibleMax.Y and count < maxLines do
			local index = roundNearest(worldY / gridStep)
			local screen = worldToScreen(0, worldY)
			local major = index % majorEvery == 0
			argon:DrawLine(
				window,
				{ X = canvasRect.x, Y = screen.Y },
				{ X = canvasRect.x + canvasRect.width, Y = screen.Y },
				if major then 1.25 else 1,
				if major then majorGridColor else gridColor
			)
			worldY += gridStep
			count += 1
		end
	end

	if params.ShowAxes ~= false then
		if visibleMin.Y <= 0 and visibleMax.Y >= 0 then
			local axis = worldToScreen(0, 0)
			argon:DrawLine(
				window,
				{ X = canvasRect.x, Y = axis.Y },
				{ X = canvasRect.x + canvasRect.width, Y = axis.Y },
				params.AxisThickness or 1.5,
				axisXColor
			)
		end

		if visibleMin.X <= 0 and visibleMax.X >= 0 then
			local axis = worldToScreen(0, 0)
			argon:DrawLine(
				window,
				{ X = axis.X, Y = canvasRect.y },
				{ X = axis.X, Y = canvasRect.y + canvasRect.height },
				params.AxisThickness or 1.5,
				axisYColor
			)
		end
	end

	if params.callback then
		params.callback({
			x = canvasRect.x,
			y = canvasRect.y,
			width = canvasRect.width,
			height = canvasRect.height,
			cameraX = field.cameraX,
			cameraY = field.cameraY,
			zoom = field.zoom,
			dragging = field.dragging,
			hovered = hovered,
			worldMinX = visibleMin.X,
			worldMinY = visibleMin.Y,
			worldMaxX = visibleMax.X,
			worldMaxY = visibleMax.Y,
			gridStep = gridStep,
			worldToScreen = worldToScreen,
			screenToWorld = screenToWorld,
			state = field,
			window = window,
			renderer = renderer,
			theme = theme,
			RetainedStorage = storage,
		}, dt)
	end

	argon:Restore(window)

	if showRulers then
		local topRulerRect = {
			x = canvasRect.x,
			y = params.y,
			width = canvasRect.width,
			height = rulerSize,
		}
		local leftRulerRect = {
			x = params.x,
			y = canvasRect.y,
			width = rulerSize,
			height = canvasRect.height,
		}

		argon:DrawRectangle(window, {
			x = params.x,
			y = params.y,
			width = rulerSize,
			height = rulerSize,
			Color = rulerColor,
		})
		argon:DrawRectangle(window, {
			x = topRulerRect.x,
			y = topRulerRect.y,
			width = topRulerRect.width,
			height = topRulerRect.height,
			Color = rulerColor,
		})
		argon:DrawRectangle(window, {
			x = leftRulerRect.x,
			y = leftRulerRect.y,
			width = leftRulerRect.width,
			height = leftRulerRect.height,
			Color = rulerColor,
		})

		argon:Save(window)
		argon:ClipRoundRect(window, topRulerRect, 0, 0)
		local rulerX = math.floor(visibleMin.X / majorStep) * majorStep
		local rulerCount = 0
		while rulerX <= visibleMax.X and rulerCount < 128 do
			local screen = worldToScreen(rulerX, 0)
			argon:DrawLine(
				window,
				{ X = screen.X, Y = topRulerRect.y + rulerSize - 5 },
				{ X = screen.X, Y = topRulerRect.y + rulerSize },
				1,
				rulerBorderColor
			)
			argon:DrawText(window, formatAxisValue(rulerX, majorStep), {
				X = screen.X + 3,
				Y = topRulerRect.y + rulerSize - 6,
				TextSize = textSize,
				Font = font,
				Color = textColor,
			})
			rulerX += majorStep
			rulerCount += 1
		end
		argon:Restore(window)

		argon:Save(window)
		argon:ClipRoundRect(window, leftRulerRect, 0, 0)
		local rulerY = math.floor(visibleMin.Y / majorStep) * majorStep
		rulerCount = 0
		while rulerY <= visibleMax.Y and rulerCount < 128 do
			local screen = worldToScreen(0, rulerY)
			argon:DrawLine(
				window,
				{ X = leftRulerRect.x + rulerSize - 5, Y = screen.Y },
				{ X = leftRulerRect.x + rulerSize, Y = screen.Y },
				1,
				rulerBorderColor
			)
			argon:DrawText(window, formatAxisValue(rulerY, majorStep), {
				X = leftRulerRect.x + 2,
				Y = screen.Y - 2,
				TextSize = textSize,
				Font = font,
				Color = textColor,
			})
			rulerY += majorStep
			rulerCount += 1
		end
		argon:Restore(window)

		argon:DrawLine(
			window,
			{ X = canvasRect.x, Y = canvasRect.y },
			{ X = canvasRect.x + canvasRect.width, Y = canvasRect.y },
			1,
			rulerBorderColor
		)
		argon:DrawLine(
			window,
			{ X = canvasRect.x, Y = canvasRect.y },
			{ X = canvasRect.x, Y = canvasRect.y + canvasRect.height },
			1,
			rulerBorderColor
		)
	end

	if showZoomControls and zoomControlRect and minusRect and labelRect and plusRect then
		local controlColor = params.ZoomControlColor or theme.SecondaryColor or withAlpha(backgroundColor, 0.95)
		local controlHoverColor = params.ZoomControlHoverColor or withAlpha(textColor, 0.12)
		local controlBorderColor = params.ZoomControlBorderColor or withAlpha(textColor, 0.18)

		argon:DrawRectangle(window, {
			x = zoomControlRect.x,
			y = zoomControlRect.y,
			width = zoomControlRect.width,
			height = zoomControlRect.height,
			Color = controlColor,
		})

		for _, rect in ipairs({ minusRect, labelRect, plusRect }) do
			if pointInRect(mouse, rect) then
				argon:DrawRectangle(window, {
					x = rect.x,
					y = rect.y,
					width = rect.width,
					height = rect.height,
					Color = controlHoverColor,
				})
			end
		end

		argon:DrawLine(
			window,
			{ X = labelRect.x, Y = labelRect.y },
			{ X = labelRect.x, Y = labelRect.y + labelRect.height },
			1,
			controlBorderColor
		)
		argon:DrawLine(
			window,
			{ X = plusRect.x, Y = plusRect.y },
			{ X = plusRect.x, Y = plusRect.y + plusRect.height },
			1,
			controlBorderColor
		)

		local minusText = "-"
		local plusText = "+"
		local zoomText = string.format("%.1f%%", field.zoom * 100)
		local controlTextSize = params.ZoomControlTextSize or 11
		local textAscent = argon:GetFontAscent(controlTextSize, font)
		local baselineY = zoomControlRect.y
			+ (zoomControlRect.height - argon:GetFontLineHeight(controlTextSize, font)) * 0.5
			+ textAscent

		local function drawCentered(text: string, rect)
			local width = argon:MeasureText(window, text, controlTextSize, font)
			argon:DrawText(window, text, {
				X = rect.x + (rect.width - width) * 0.5,
				Y = baselineY,
				TextSize = controlTextSize,
				Font = font,
				Color = textColor,
			})
		end

		drawCentered(minusText, minusRect)
		drawCentered(zoomText, labelRect)
		drawCentered(plusText, plusRect)
	end

	if changed and params.OnViewChanged then
		params.OnViewChanged(field.cameraX, field.cameraY, field.zoom)
	end

	return field
end
