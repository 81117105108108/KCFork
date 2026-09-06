local argon = require("@Argon")
local GuiObject = require("@GuiObject")
local UDim2 = require("@UDim2")

local LEFT_MOUSE_BUTTON = argon.MouseButton.Left
local DEFAULT_SNAP = 8
local GUI_HANDLE_SIZE = 8
local GUI_MIN_SIZE = 8
local snap

local guiHandles = {
	{ x = 0, y = 0, left = true, top = true },
	{ x = 0.5, y = 0, top = true },
	{ x = 1, y = 0, right = true, top = true },
	{ x = 0, y = 0.5, left = true },
	{ x = 1, y = 0.5, right = true },
	{ x = 0, y = 1, left = true, bottom = true },
	{ x = 0.5, y = 1, bottom = true },
	{ x = 1, y = 1, right = true, bottom = true },
}

local function rgba(r, g, b, a)
	return argon:RGBA(r, g, b, (a or 255) / 255)
end

local function pointInRect(point, rect)
	return point.X >= rect.x
		and point.X <= rect.x + rect.width
		and point.Y >= rect.y
		and point.Y <= rect.y + rect.height
end

local function isScreenGuiObject(object)
	if not object or object.BaseClass ~= "GuiObject" then
		return false
	end
	local ancestor = object.Parent
	while ancestor do
		if ancestor.ClassName == "ScreenGui" then
			return ancestor.Enabled ~= false
		end
		if ancestor.BaseClass == "UIContainer" then
			return false
		end
		ancestor = ancestor.Parent
	end
	return false
end

local function guiIsVisible(object)
	local current = object
	while current and current.BaseClass == "GuiObject" do
		if current.Visible == false then
			return false
		end
		current = current.Parent
	end
	return isScreenGuiObject(object)
end

local function guiRect(object, view, dt, renderer)
	local position, size = GuiObject.calculatePositions(view.window, object, dt, renderer)
	if not position or not size then
		return nil
	end
	return { x = position.X, y = position.Y, width = size.X, height = size.Y }
end

local function collectGui(guiRoot, view, dt, renderer)
	local entries = {}
	if not guiRoot then
		return entries
	end
	for order, object in ipairs(guiRoot:GetDescendants()) do
		if guiIsVisible(object) then
			local rect = guiRect(object, view, dt, renderer)
			if rect and rect.width > 0 and rect.height > 0 then
				table.insert(entries, { object = object, rect = rect, order = order })
			end
		end
	end
	table.sort(entries, function(a, b)
		local az, bz = a.object.ZIndex or 1, b.object.ZIndex or 1
		return az == bz and a.order < b.order or az < bz
	end)
	return entries
end

local function hitTestGui(mouse, entries)
	for index = #entries, 1, -1 do
		if pointInRect(mouse, entries[index].rect) then
			return entries[index].object, entries[index].rect
		end
	end
	return nil
end

local function guiParentMetrics(object)
	local parent = object.Parent
	local position = parent and (parent.AbsolutePosition or parent.RenderOffset)
	local size = parent and parent.AbsoluteSize
	if not size and parent and parent.Size then
		size = { X = parent.Size.X.Offset, Y = parent.Size.Y.Offset }
	end
	return position or { X = 0, Y = 0 }, size or { X = 0, Y = 0 }
end

local function guiHandleAt(mouse, rect)
	for _, handle in ipairs(guiHandles) do
		local x, y = rect.x + rect.width * handle.x, rect.y + rect.height * handle.y
		if math.abs(mouse.X - x) <= GUI_HANDLE_SIZE and math.abs(mouse.Y - y) <= GUI_HANDLE_SIZE then
			return handle
		end
	end
	return nil
end

local function drawGuiSelection(view, rect, tool)
	local accent = rgba(66, 160, 255, 255)
	argon:DrawRectangle(view.window, {
		x = rect.x,
		y = rect.y,
		width = rect.width,
		height = rect.height,
		Color = accent,
		isOutline = true,
	})
	if tool == "Size" or tool == "Select" then
		for _, handle in ipairs(guiHandles) do
			local x, y = rect.x + rect.width * handle.x, rect.y + rect.height * handle.y
			argon:DrawRectangle(view.window, {
				x = x - GUI_HANDLE_SIZE * 0.5,
				y = y - GUI_HANDLE_SIZE * 0.5,
				width = GUI_HANDLE_SIZE,
				height = GUI_HANDLE_SIZE,
				Color = accent,
			})
		end
	end
end

local function beginGuiDrag(field, object, tool, mouse, rect, handle)
	if tool == "Rotate" then
		field.drag = nil
		return
	end
	field.drag = {
		kind = "gui",
		object = object,
		mode = if tool == "Size" or handle then "resize" else "move",
		handle = handle or (tool == "Size" and guiHandles[#guiHandles] or nil),
		startMouse = { X = mouse.X, Y = mouse.Y },
		left = rect.x,
		top = rect.y,
		width = rect.width,
		height = rect.height,
	}
	object._LayoutControlled = false
end

local function updateGuiDrag(field, mouse, snapEnabled, moveSnap)
	local drag = field.drag
	local object = drag.object
	local dx, dy = mouse.X - drag.startMouse.X, mouse.Y - drag.startMouse.Y
	local left, top = drag.left, drag.top
	local right, bottom = left + drag.width, top + drag.height
	if drag.mode == "move" then
		left, right = left + dx, right + dx
		top, bottom = top + dy, bottom + dy
	else
		local handle = drag.handle
		if handle.left then left = math.min(left + dx, right - GUI_MIN_SIZE) end
		if handle.right then right = math.max(right + dx, left + GUI_MIN_SIZE) end
		if handle.top then top = math.min(top + dy, bottom - GUI_MIN_SIZE) end
		if handle.bottom then bottom = math.max(bottom + dy, top + GUI_MIN_SIZE) end
	end
	if snapEnabled then
		if drag.mode == "move" then
			local width, height = right - left, bottom - top
			left, top = snap(left, moveSnap), snap(top, moveSnap)
			right, bottom = left + width, top + height
		else
			if drag.handle.left then left = snap(left, moveSnap) end
			if drag.handle.right then right = snap(right, moveSnap) end
			if drag.handle.top then top = snap(top, moveSnap) end
			if drag.handle.bottom then bottom = snap(bottom, moveSnap) end
		end
	end
	local width, height = math.max(GUI_MIN_SIZE, right - left), math.max(GUI_MIN_SIZE, bottom - top)
	local parentPosition, parentSize = guiParentMetrics(object)
	local anchor = object.AnchorPoint or { X = 0, Y = 0 }
	local position, size = object.Position, object.Size
	object.Position = UDim2.new(
		position.X.Scale,
		left - parentPosition.X + width * anchor.X - parentSize.X * position.X.Scale,
		position.Y.Scale,
		top - parentPosition.Y + height * anchor.Y - parentSize.Y * position.Y.Scale
	)
	if drag.mode == "resize" then
		object.Size = UDim2.new(
			size.X.Scale,
			width - parentSize.X * size.X.Scale,
			size.Y.Scale,
			height - parentSize.Y * size.Y.Scale
		)
	end
end

local function rotateXY(x, y, degrees)
	local angle = math.rad(degrees or 0)
	local c, s = math.cos(angle), math.sin(angle)
	return x * c - y * s, x * s + y * c
end

local function inverseRotatePoint(point, center, degrees)
	local x, y = rotateXY(point.X - center.X, point.Y - center.Y, -(degrees or 0))
	return { X = x, Y = y }
end

snap = function(value, increment)
	if increment <= 0 then
		return value
	end
	if value >= 0 then
		return math.floor(value / increment + 0.5) * increment
	end
	return math.ceil(value / increment - 0.5) * increment
end

local function objectPosition(object)
	if object.ClassName == "Attachment2D" then
		return object.WorldPosition or object.Position
	end
	return object.Position
end

local function setObjectPosition(object, position)
	local Vector2 = require("@Vector2")
	local value = Vector2.new(position.X, position.Y)
	if object.ClassName == "Attachment2D" and object.SetWorldPosition then
		object:SetWorldPosition(value)
	else
		object.Position = value
	end
end

local function objectRotation(object)
	if object.ClassName == "Attachment2D" then
		return object.WorldRotation or object.Rotation or 0
	end
	return object.Rotation or 0
end

local function isBody(object)
	return object ~= nil and (object.ClassName == "Body2D" or object.BaseClass == "Body2D")
end

local function isEditable(object)
	return isBody(object) or object.ClassName == "Attachment2D" or object.ClassName == "Tilemap"
end

local function bodyCorners(body)
	local position = body.Position
	local halfX = math.max(body.Size.X, 0) * 0.5
	local halfY = math.max(body.Size.Y, 0) * 0.5
	local corners = {}
	for _, corner in ipairs({ { -halfX, -halfY }, { halfX, -halfY }, { halfX, halfY }, { -halfX, halfY } }) do
		local x, y = rotateXY(corner[1], corner[2], body.Rotation or 0)
		table.insert(corners, { X = position.X + x, Y = position.Y + y })
	end
	return corners
end

local function pointInBody(point, body)
	local localPoint = inverseRotatePoint(point, body.Position, body.Rotation)
	return math.abs(localPoint.X) <= body.Size.X * 0.5 and math.abs(localPoint.Y) <= body.Size.Y * 0.5
end

local function drawWorldPolygon(view, points, color, width)
	local screenPoints = {}
	for _, point in ipairs(points) do
		table.insert(screenPoints, view.worldToScreen(point.X, point.Y))
	end
	argon:DrawPolygon(view.window, screenPoints, true, color, width or 1)
end

local function attachmentWorldPosition(attachment)
	if not attachment then
		return nil
	end
	if attachment.GetWorldPosition then
		return attachment:GetWorldPosition()
	end
	return attachment.WorldPosition or attachment.Position
end

local function constraintAttachments(constraint)
	return attachmentWorldPosition(constraint.Attachment0), attachmentWorldPosition(constraint.Attachment1)
end

local function drawConstraint(view, constraint)
	if constraint.Enabled == false then
		return
	end
	local first, second = constraintAttachments(constraint)
	if not first or not second then
		return
	end
	local color = if constraint.Active then rgba(96, 220, 130, 210) else rgba(255, 176, 72, 210)
	argon:DrawLine(view.window, view.worldToScreen(first.X, first.Y), view.worldToScreen(second.X, second.Y), 2, color)
end

local function drawCollider(view, body, collider)
	if collider.Enabled == false then
		return
	end
	local offset = collider.Offset or { X = 0, Y = 0 }
	local ox, oy = rotateXY(offset.X, offset.Y, body.Rotation or 0)
	local center = { X = body.Position.X + ox, Y = body.Position.Y + oy }
	local rotation = (body.Rotation or 0) + (collider.Rotation or 0)
	local color = if collider.IsSensor then rgba(180, 95, 255, 225) else rgba(90, 225, 150, 225)

	if collider.ClassName == "CircleCollider2D" then
		local screen = view.worldToScreen(center.X, center.Y)
		argon:DrawCircle(view.window, screen, math.max(collider.Radius or 0, 0) * view.zoom, color, 2)
	elseif collider.ClassName == "PolygonCollider2D" then
		local points = {}
		for _, point in ipairs(collider.Points or {}) do
			local x, y = rotateXY(point.X, point.Y, rotation)
			table.insert(points, { X = center.X + x, Y = center.Y + y })
		end
		if #points >= 2 then
			drawWorldPolygon(view, points, color, 2)
		end
	else
		local size = collider.Size or body.Size
		local halfX, halfY = size.X * 0.5, size.Y * 0.5
		local points = {}
		for _, corner in ipairs({ { -halfX, -halfY }, { halfX, -halfY }, { halfX, halfY }, { -halfX, halfY } }) do
			local x, y = rotateXY(corner[1], corner[2], rotation)
			table.insert(points, { X = center.X + x, Y = center.Y + y })
		end
		drawWorldPolygon(view, points, color, 2)
	end
end

local function drawAttachment(view, attachment)
	if attachment.Visible == false then
		return
	end
	local position = attachmentWorldPosition(attachment)
	if not position then
		return
	end
	local screen = view.worldToScreen(position.X, position.Y)
	local color = rgba(255, 190, 70, 255)
	argon:DrawCircle(view.window, screen, 5, color, 2)
	argon:DrawLine(view.window, { X = screen.X - 8, Y = screen.Y }, { X = screen.X + 8, Y = screen.Y }, 1, color)
	argon:DrawLine(view.window, { X = screen.X, Y = screen.Y - 8 }, { X = screen.X, Y = screen.Y + 8 }, 1, color)
end

local function drawBody(view, body, selected)
	if body.Enabled == false then
		return
	end
	if body.Visible ~= false and body.Color and (body.Transparency or 0) < 1 then
		local center = view.worldToScreen(body.Position.X, body.Position.Y)
		local color = body.Color
		argon:DrawRotatedRectangle(view.window, {
			x = center.X,
			y = center.Y,
			width = body.Size.X * view.zoom,
			height = body.Size.Y * view.zoom,
			Color = { R = color.R, G = color.G, B = color.B, A = 1 - (body.Transparency or 0) },
		}, body.Rotation or 0)
	end

	if body.Visible == false or selected then
		drawWorldPolygon(view, bodyCorners(body), if selected then rgba(66, 160, 255, 255) else rgba(150, 165, 180, 160), selected and 2 or 1)
	end

	if selected then
		for _, child in ipairs(body:GetChildren()) do
			if child.BaseClass == "Collider2D" then
				drawCollider(view, body, child)
			elseif child.ClassName == "Attachment2D" then
				drawAttachment(view, child)
			end
		end
	end
end

local function drawTileLayer(view, tilemap, layer, textureCache)
	if tilemap.Visible == false or layer.Visible == false then
		return
	end
	local tileSize = if (layer.TileSize or 0) > 0 then layer.TileSize else (tilemap.TileSize or 32)
	local origin = tilemap.Position + (layer.Offset or require("@Vector2").new(0, 0))
	local screenSize = tileSize * view.zoom
	for y = 1, layer.Height or 0 do
		local row = layer.Tiles and layer.Tiles[y]
		if not row then
			continue
		end
		for x = 1, layer.Width or 0 do
			local tileId = row[x] or 0
			local definition = tileId ~= 0 and tilemap.Tiles and tilemap.Tiles[tileId] or nil
			if not definition then
				continue
			end
			local center = view.worldToScreen(origin.X + (x - 0.5) * tileSize, origin.Y + (y - 0.5) * tileSize)
			local rect = { x = center.X - screenSize * 0.5, y = center.Y - screenSize * 0.5, width = screenSize, height = screenSize }
			if rect.x + rect.width < view.x or rect.x > view.x + view.width or rect.y + rect.height < view.y or rect.y > view.y + view.height then
				continue
			end
			local source = definition.Image or definition.Texture
			local image = nil
			if type(source) == "table" and source._handle then
				image = source
			elseif type(source) == "string" and source ~= "" then
				if textureCache[source] == nil then
					textureCache[source] = argon:CreateImageFromPath(source) or false
				end
				image = textureCache[source] or nil
			end
			if image then
				argon:DrawImageSized(view.window, image, rect, 1 - (definition.Transparency or 0))
			else
				local color = definition.Color or { R = 1, G = 0, B = 1 }
				rect.Color = { R = color.R, G = color.G, B = color.B, A = 1 - (definition.Transparency or 0) }
				argon:DrawRectangle(view.window, rect)
			end
		end
	end
end

local function drawSelectionGizmo(view, object, tool)
	local position = objectPosition(object)
	if not position then
		return
	end
	local screen = view.worldToScreen(position.X, position.Y)
	local red = rgba(235, 82, 92, 255)
	local green = rgba(80, 205, 118, 255)
	local accent = rgba(66, 160, 255, 255)

	if tool == "Move" then
		argon:DrawLine(view.window, screen, { X = screen.X + 44, Y = screen.Y }, 3, red)
		argon:DrawLine(view.window, screen, { X = screen.X, Y = screen.Y + 44 }, 3, green)
		argon:DrawPolygon(view.window, {
			{ X = screen.X + 44, Y = screen.Y }, { X = screen.X + 35, Y = screen.Y - 5 }, { X = screen.X + 35, Y = screen.Y + 5 },
		}, true, red, 1)
		argon:DrawPolygon(view.window, {
			{ X = screen.X, Y = screen.Y + 44 }, { X = screen.X - 5, Y = screen.Y + 35 }, { X = screen.X + 5, Y = screen.Y + 35 },
		}, true, green, 1)
	elseif tool == "Rotate" and isBody(object) then
		local radius = math.max(object.Size.X, object.Size.Y) * 0.5 * view.zoom + 18
		argon:DrawCircle(view.window, screen, radius, accent, 2)
	elseif tool == "Size" and isBody(object) then
		for _, corner in ipairs(bodyCorners(object)) do
			local handle = view.worldToScreen(corner.X, corner.Y)
			argon:DrawRectangle(view.window, { x = handle.X - 4, y = handle.Y - 4, width = 8, height = 8, Color = accent })
		end
	end
end

local function collectScene(workspace)
	local bodies, attachments, constraints, layers = {}, {}, {}, {}
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isBody(descendant) then
			table.insert(bodies, descendant)
		elseif descendant.ClassName == "Attachment2D" then
			table.insert(attachments, descendant)
		elseif descendant.BaseClass == "Constraint2D" then
			table.insert(constraints, descendant)
		elseif descendant.ClassName == "Layer2D" and descendant.Parent and descendant.Parent.ClassName == "Tilemap" then
			table.insert(layers, { tilemap = descendant.Parent, layer = descendant })
		end
	end
	table.sort(bodies, function(a, b)
		return (a.ZIndex or 0) < (b.ZIndex or 0)
	end)
	table.sort(layers, function(a, b)
		return ((a.tilemap.ZIndex or 0) + (a.layer.ZIndex or 0)) < ((b.tilemap.ZIndex or 0) + (b.layer.ZIndex or 0))
	end)
	return bodies, attachments, constraints, layers
end

local function hitTest(worldPoint, bodies, attachments, layers, zoom)
	local attachmentRadius = 9 / math.max(zoom, 0.0001)
	for index = #attachments, 1, -1 do
		local attachment = attachments[index]
		local position = attachmentWorldPosition(attachment)
		if position then
			local dx, dy = worldPoint.X - position.X, worldPoint.Y - position.Y
			if dx * dx + dy * dy <= attachmentRadius * attachmentRadius then
				return attachment
			end
		end
	end
	for index = #bodies, 1, -1 do
		if pointInBody(worldPoint, bodies[index]) then
			return bodies[index]
		end
	end
	for index = #layers, 1, -1 do
		local entry = layers[index]
		local tilemap, layer = entry.tilemap, entry.layer
		local tileSize = if (layer.TileSize or 0) > 0 then layer.TileSize else (tilemap.TileSize or 32)
		local origin = tilemap.Position + (layer.Offset or require("@Vector2").new(0, 0))
		if worldPoint.X >= origin.X and worldPoint.Y >= origin.Y
			and worldPoint.X <= origin.X + (layer.Width or 0) * tileSize
			and worldPoint.Y <= origin.Y + (layer.Height or 0) * tileSize
		then
			return tilemap
		end
	end
	return nil
end

local function beginDrag(field, object, tool, worldPoint)
	local position = objectPosition(object)
	if not position then
		return
	end
	field.drag = {
		kind = "world",
		object = object,
		tool = tool,
		startMouse = worldPoint,
		startPosition = { X = position.X, Y = position.Y },
		startRotation = objectRotation(object),
		startSize = isBody(object) and { X = object.Size.X, Y = object.Size.Y } or nil,
		startAngle = math.atan2(worldPoint.Y - position.Y, worldPoint.X - position.X),
	}
end

local function updateDrag(field, worldPoint, snapEnabled, moveSnap, rotateSnap)
	local drag = field.drag
	if not drag or drag.kind == "gui" then
		return
	end
	local object = drag.object
	if drag.tool == "Move" or drag.tool == "Select" then
		local x = drag.startPosition.X + worldPoint.X - drag.startMouse.X
		local y = drag.startPosition.Y + worldPoint.Y - drag.startMouse.Y
		if snapEnabled then
			x, y = snap(x, moveSnap), snap(y, moveSnap)
		end
		setObjectPosition(object, { X = x, Y = y })
	elseif drag.tool == "Rotate" and isBody(object) then
		local angle = math.atan2(worldPoint.Y - drag.startPosition.Y, worldPoint.X - drag.startPosition.X)
		local rotation = drag.startRotation + math.deg(angle - drag.startAngle)
		object.Rotation = if snapEnabled then snap(rotation, rotateSnap) else rotation
	elseif drag.tool == "Size" and isBody(object) and drag.startSize then
		local startLocal = inverseRotatePoint(drag.startMouse, drag.startPosition, drag.startRotation)
		local currentLocal = inverseRotatePoint(worldPoint, drag.startPosition, drag.startRotation)
		local width = math.max(1, drag.startSize.X + (math.abs(currentLocal.X) - math.abs(startLocal.X)) * 2)
		local height = math.max(1, drag.startSize.Y + (math.abs(currentLocal.Y) - math.abs(startLocal.Y)) * 2)
		if snapEnabled then
			width, height = math.max(moveSnap, snap(width, moveSnap)), math.max(moveSnap, snap(height, moveSnap))
		end
		object.Size = require("@Vector2").new(width, height)
	end
end

return function(params, dt)
	local storage = params.RetainedStorage
	local id = params.id
	local field = storage[id]
	if not field then
		field = { drag = nil, keyDown = {}, textureCache = {} }
		storage[id] = field
	end
	field.textureCache = field.textureCache or {}

	local view = params.view
	local workspace = params.workspace
	local guiRoot = params.GuiRoot
	local selection = params.selection
	local tool = params.ActiveTool or "Select"
	local bodies, attachments, constraints, layers = collectScene(workspace)
	local guiEntries = collectGui(guiRoot, view, dt, params.renderer)
	local selectedList = selection.Get()
	local selected = selectedList and selectedList[1]

	for _, entry in ipairs(layers) do
		drawTileLayer(view, entry.tilemap, entry.layer, field.textureCache)
	end
	for _, constraint in ipairs(constraints) do
		drawConstraint(view, constraint)
	end
	for _, body in ipairs(bodies) do
		drawBody(view, body, body == selected)
	end
	for _, attachment in ipairs(attachments) do
		if attachment.Parent ~= selected then
			drawAttachment(view, attachment)
		end
	end
	if selected and isEditable(selected) then
		drawSelectionGizmo(view, selected, tool)
	elseif isScreenGuiObject(selected) then
		local selectedRect = guiRect(selected, view, dt, params.renderer)
		if selectedRect then
			drawGuiSelection(view, selectedRect, tool)
		end
	end

	local mouse = argon:GetMousePosition()
	local excluded = params.InputExclusionRect and pointInRect(mouse, params.InputExclusionRect)
	local worldPoint = view.screenToWorld(mouse.X, mouse.Y)
	local pressed = argon:IsMouseButtonPressed(LEFT_MOUSE_BUTTON)
	local down = argon:IsMouseButtonDown(LEFT_MOUSE_BUTTON)
	local released = argon:IsMouseButtonReleased(LEFT_MOUSE_BUTTON)

	if pressed and view.hovered and not view.dragging and not excluded then
		local hit, hitRect
		local selectedRect = isScreenGuiObject(selected) and guiRect(selected, view, dt, params.renderer) or nil
		local handle = selectedRect and guiHandleAt(mouse, selectedRect) or nil
		if handle and (tool == "Size" or tool == "Select") then
			hit, hitRect = selected, selectedRect
		else
			hit, hitRect = hitTestGui(mouse, guiEntries)
		end
		if hit then
			if hit ~= selected then
				selection.Set({ hit })
				selected = hit
			end
			beginGuiDrag(field, hit, tool, mouse, hitRect, handle)
		else
			hit = hitTest(worldPoint, bodies, attachments, layers, view.zoom)
		end
		if hit then
			if not isScreenGuiObject(hit) and hit ~= selected then
				selection.Set({ hit })
				selected = hit
			end
			if not isScreenGuiObject(hit) then
				beginDrag(field, hit, tool, worldPoint)
			end
		else
			selection.Set({})
			field.drag = nil
		end
	end

	if field.drag then
		if released or not down then
			field.drag = nil
		else
			if field.drag.kind == "gui" then
				updateGuiDrag(field, mouse, params.SnapEnabled ~= false, params.MoveSnap or DEFAULT_SNAP)
			else
				updateDrag(field, worldPoint, params.SnapEnabled ~= false, params.MoveSnap or DEFAULT_SNAP, params.RotateSnap or 15)
			end
		end
	end

	-- Godot-style shortcuts: Q select, W move, E rotate, S scale, F frame selection.
	for keyName, toolName in pairs({ Q = "Select", W = "Move", E = "Rotate", S = "Size" }) do
		local key = argon.Key[keyName]
		local keyDown = key and argon:IsKeyDown(key) or false
		if keyDown and not field.keyDown[keyName] and params.OnToolChanged then
			params.OnToolChanged(toolName)
		end
		field.keyDown[keyName] = keyDown
	end
	local focusDown = argon.Key.F and argon:IsKeyDown(argon.Key.F) or false
	if focusDown and not field.keyDown.F and selected and objectPosition(selected) and not isScreenGuiObject(selected) then
		local position = objectPosition(selected)
		view.state.cameraX, view.state.cameraY = position.X, position.Y
	end
	field.keyDown.F = focusDown

	return field
end
