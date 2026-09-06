-- description: "Represents a Mouse in the environment."
local Argon = require("@Argon")
local Vector3 = require("@Vector3")
local CFrame = require("@CFrame")
local Enum = require("@EnumMap")
local Ray = require("@Ray")
local RaycastParams = require("@RaycastParams")
local signal = require("@Kinemium.signal")
local MouseCursor = require("@Kinemium.MouseCursor")

local DEFAULT_RAY_DISTANCE = 1000
local LEFT_MOUSE_BUTTON = 1
local RIGHT_MOUSE_BUTTON = 3

local function getViewport(renderer)
	local viewport = renderer and renderer.tex3d_rect
	if viewport then
		return viewport.X or 0, viewport.Y or 0, viewport.Width or 0, viewport.Height or 0
	end
	return 0, 0, (renderer and renderer.Width) or 0, (renderer and renderer.Height) or 0
end

local function getCamera(workspace, renderer)
	if workspace then
		local camera = workspace.CurrentCamera or workspace.Camera or workspace:FindFirstChildOfClass("Camera")
		if camera then
			return camera
		end
	end
	return renderer and renderer.GetActiveCamera and renderer:GetActiveCamera() or nil
end

local function makeUnitRay(camera, mouseX, mouseY, viewportX, viewportY, viewportWidth, viewportHeight)
	if not camera or not camera.CFrame or viewportWidth <= 0 or viewportHeight <= 0 then
		return nil
	end

	local normalizedX = ((mouseX - viewportX) / viewportWidth) * 2 - 1
	local normalizedY = 1 - ((mouseY - viewportY) / viewportHeight) * 2
	local halfFov = math.tan(math.rad(tonumber(camera.FieldOfView) or 60) * 0.5)
	local aspect = viewportWidth / viewportHeight
	local cameraCFrame = camera.CFrame
	local direction = (
		cameraCFrame:GetLookVector()
		+ cameraCFrame:GetRightVector() * (normalizedX * halfFov * aspect)
		+ cameraCFrame:GetUpVector() * (normalizedY * halfFov)
	):Unit()

	return Ray.new(cameraCFrame.Position, direction)
end

local function appendTargetFilter(params, targetFilter)
	if not targetFilter then
		return
	end

	if type(targetFilter) == "table" and rawget(targetFilter, "_props") == nil then
		for _, item in ipairs(targetFilter) do
			params.FilterDescendantsInstances[#params.FilterDescendantsInstances + 1] = item
		end
	else
		params.FilterDescendantsInstances[#params.FilterDescendantsInstances + 1] = targetFilter
	end
end

local function makeRaycastParams(targetFilter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	appendTargetFilter(params, targetFilter)
	return params
end

local function castMouseRay(mouse, distance)
	local unitRay = mouse.UnitRay
	local workspace = mouse._workspace
	if not unitRay or not workspace or not workspace.Raycast then
		return nil
	end

	local rayDistance = tonumber(distance) or DEFAULT_RAY_DISTANCE
	return workspace:Raycast(
		unitRay.Origin,
		unitRay.Direction * rayDistance,
		makeRaycastParams(mouse.TargetFilter)
	)
end

local propTable = {
	Icon = Enum.KinemiumMouseCursor.MOUSE_CURSOR_DEFAULT,
	Target = nil,
	Hit = nil,
	UnitRay = nil,
	TargetFilter = nil,
	TargetSurface = nil,

	IsMouseHidden = false,
	IsMouseOutOfBounds = false,

	X = 0,
	Y = 0,

	ViewSizeX = 0,
	ViewSizeY = 0,

	-- description: "Sets the Icon."
	SetIcon = function(mouse, icon)
		mouse.Icon = icon
	end,

	-- description: "Gets the Screen Position."
	GetScreenPosition = function(mouse)
		return mouse.X, mouse.Y
	end,

	-- description: "Raycasts from 2d to 3d space."
	Raycast = function(mouse, distance)
		return castMouseRay(mouse, distance)
	end,

	-- description: "Detects if button is down."
	IsButtonDown = function(mouse, button)
		if button == Enum.MouseButton.Left or button == Enum.MouseButton.MouseButton1 then
			return mouse._button1Down == true
		elseif button == Enum.MouseButton.Right or button == Enum.MouseButton.MouseButton2 then
			return mouse._button2Down == true
		end
		return false
	end,

	Name = "Mouse",
}

return {
	class = "Mouse",
	non_creatable = true,
	callback = function(instance, renderer, game)
		instance:SetProperties(propTable)
		instance:SetProperties({
			Button1Down = signal.new(),
			Button1Up = signal.new(),
			Button2Down = signal.new(),
			Button2Up = signal.new(),
			Move = signal.new(),
			WheelForward = signal.new(),
			WheelBackward = signal.new(),
		})
		instance._workspace = game and game.Workspace

		instance.Changed:Connect(function(property, value)
			if property == "Icon" then
				MouseCursor.request(type(value) == "table" and value.Value or value)
			end
		end)

		local previousX = nil
		local previousY = nil
		local previousButton1 = false
		local previousButton2 = false

		local function updateMouse()
			local position = Argon:GetMousePosition()
			local mouseX = position.X or position.x or 0
			local mouseY = position.Y or position.y or 0
			local viewportX, viewportY, viewportWidth, viewportHeight = getViewport(renderer)
			local outOfBounds = mouseX < viewportX
				or mouseY < viewportY
				or mouseX >= viewportX + viewportWidth
				or mouseY >= viewportY + viewportHeight

			instance.X = mouseX
			instance.Y = mouseY
			instance.ViewSizeX = viewportWidth
			instance.ViewSizeY = viewportHeight
			instance.IsMouseOutOfBounds = outOfBounds

			if previousX ~= nil and (mouseX ~= previousX or mouseY ~= previousY) then
				instance.Move:Fire()
			end
			previousX = mouseX
			previousY = mouseY

			local button1 = Argon:IsMouseButtonDown(LEFT_MOUSE_BUTTON) == true
			local button2 = Argon:IsMouseButtonDown(RIGHT_MOUSE_BUTTON) == true
			instance._button1Down = button1
			instance._button2Down = button2
			if button1 ~= previousButton1 then
				(if button1 then instance.Button1Down else instance.Button1Up):Fire()
			end
			if button2 ~= previousButton2 then
				(if button2 then instance.Button2Down else instance.Button2Up):Fire()
			end
			previousButton1 = button1
			previousButton2 = button2

			local wheel = Argon:GetMouseWheelMove()
			if wheel > 0 then
				instance.WheelForward:Fire()
			elseif wheel < 0 then
				instance.WheelBackward:Fire()
			end

			if outOfBounds then
				instance.UnitRay = nil
				instance.Target = nil
				instance.Hit = nil
				instance.TargetSurface = nil
				return
			end

			local camera = getCamera(instance._workspace, renderer)
			local unitRay = makeUnitRay(
				camera,
				mouseX,
				mouseY,
				viewportX,
				viewportY,
				viewportWidth,
				viewportHeight
			)
			instance.UnitRay = unitRay

			local result = unitRay and castMouseRay(instance, DEFAULT_RAY_DISTANCE) or nil
			instance.Target = result and result.Instance or nil
			instance.TargetSurface = result and result.Normal or nil
			local hitPosition = result and result.Position
				or (unitRay and unitRay:PointAt(DEFAULT_RAY_DISTANCE))
			instance.Hit = hitPosition and CFrame.new(hitPosition) or nil
		end

		rawset(instance, "_UpdateMouse", updateMouse)
		if renderer and renderer.EventBus then
			renderer.EventBus:Connect(function(route)
				if route == "PreRender" then
					updateMouse()
				end
			end)
		end
		updateMouse()

		return instance
	end,

	inherit = function(tble)
		for prop, val in pairs(propTable) do
			tble[prop] = val
		end
	end,
}
