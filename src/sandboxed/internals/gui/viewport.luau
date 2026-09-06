local Selection = game:GetService("Selection")
local StudioThemeService = game:GetService("StudioThemeService")
local PlaytestService = game:GetService("PlaytestService")
local Immco = require("@Immco")
local theme = StudioThemeService.SelectedTheme
local Argon = require("@Argon")
local retained = {}
local playIcon = Argon:CreateImageFromPath("./src/assets/images/icons/Play.svg")
local stopIcon = Argon:CreateImageFromPath("./src/assets/images/icons/Stop.svg")

if IsServer then
	return
end

if IsClient then
	return
end

repeat
	task.wait()
until game.CoreGui:FindFirstChild("Studio")

local widget
local activeTool = "Select"
local dragState = nil
local snap2D = true

local Viewport = Instance.new("Frame")
Viewport.Name = "Viewport"
Viewport.Size = theme.ViewportCoordinates.Size
Viewport.Position = theme.ViewportCoordinates.Position
Viewport.Parent = game.CoreGui:FindFirstChild("Studio")
Viewport.BackgroundTransparency = 1

export type EditorButton = {
	name: string,
	iconPath: string,
	clicked: () -> (),
}

local toolHandles = Instance.new("Handles")
toolHandles.Name = "ViewportHandles"
toolHandles.Adornee = nil
toolHandles.RotationSnap = 15
toolHandles.Parent = Viewport

local function selectedPart()
	local selected = Selection.Get()
	local object = selected and selected[1]
	if object and object.IsA and object:IsA("BasePart") then
		return object
	end
	return nil
end

local function normalAxis(normalId)
	local name = normalId and normalId.Name
	if name == "Right" then
		return Vector3.new(1, 0, 0), "X"
	elseif name == "Top" then
		return Vector3.new(0, 1, 0), "Y"
	end
	return Vector3.new(0, 0, 1), "Z"
end

local function refreshHandles()
	local part = selectedPart()
	if renderer.Dimension ~= "3D" then
		part = nil
	end
	if activeTool == "Move" then
		toolHandles.Style = Enum.HandlesStyle.Movement
	elseif activeTool == "Size" then
		toolHandles.Style = Enum.HandlesStyle.Resize
	elseif activeTool == "Rotate" then
		toolHandles.Style = Enum.HandlesStyle.Rotation
	else
		part = nil
	end
	toolHandles.Adornee = part
end

local paintColors = {
	Color3.fromRGB(76, 152, 255),
	Color3.fromRGB(255, 105, 97),
	Color3.fromRGB(112, 214, 128),
	Color3.fromRGB(255, 196, 87),
}
local paintIndex = 0

local function toggleTool(name)
	if renderer.Dimension == "2D" then
		activeTool = name
	elseif activeTool == name then
		activeTool = nil
	else
		activeTool = name
	end
	if name == "Paint" and activeTool == "Paint" then
		local part = selectedPart()
		if part then
			paintIndex = (paintIndex % #paintColors) + 1
			part.Color = paintColors[paintIndex]
		end
	end
	refreshHandles()
end

if ishared.StudioSystem then
	ishared.StudioSystem:Connect(function(route, value)
		if route ~= "set_viewport_tool" then
			return
		end
		activeTool = value
		refreshHandles()
	end)
end

toolHandles.MouseButton1Down:Connect(function()
	local part = selectedPart()
	if not part then
		return
	end
	dragState = {
		part = part,
		cframe = part.CFrame,
		size = part.Size,
	}
	game.Stop3DInput = true
end)

toolHandles.MouseDrag:Connect(function(normalId, delta)
	local state = dragState
	if not state or state.part ~= selectedPart() then
		return
	end
	local localAxis, component = normalAxis(normalId)
	if activeTool == "Move" then
		local worldAxis = state.cframe:VectorToWorldSpace(localAxis)
		state.part.CFrame = state.cframe:WithPosition(state.cframe.Position + worldAxis * delta)
	elseif activeTool == "Size" then
		local size = state.size
		state.part.Size = Vector3.new(
			component == "X" and math.max(0.05, size.X + delta) or size.X,
			component == "Y" and math.max(0.05, size.Y + delta) or size.Y,
			component == "Z" and math.max(0.05, size.Z + delta) or size.Z
		)
	elseif activeTool == "Rotate" then
		state.part.CFrame = state.cframe * CFrame.fromAxisAngle(localAxis, delta)
	end
end)

toolHandles.MouseButton1Up:Connect(function()
	dragState = nil
	game.Stop3DInput = false
end)

local buttons: { EditorButton } = {
	{
		name = "Move",
		iconPath = "./src/assets/images/icons/Move.svg",
		clicked = function()
			toggleTool("Move")
		end,
		tooltip = "Move a 3D object.",
	},
	{
		name = "Size",
		iconPath = "./src/assets/images/icons/Size.svg",
		clicked = function()
			toggleTool("Size")
		end,
		tooltip = "Resize a 3D object.",
	},
	{
		name = "Rotate",
		iconPath = "./src/assets/images/icons/Rotate.svg",
		clicked = function()
			toggleTool("Rotate")
		end,
		tooltip = "Rotate a 3D object.",
	},
	{
		name = "Paint",
		iconPath = "./src/assets/images/icons/ColorEffect.svg",
		clicked = function()
			toggleTool("Paint")
		end,
		tooltip = "Paint a 3D object.",
	},
}

local buttons2D: { EditorButton } = {
	{
		name = "Select",
		iconPath = "./src/assets/images/icons/Cursor.svg",
		clicked = function()
			activeTool = "Select"
		end,
		tooltip = "Select and drag a 2D node (Q).",
	},
	{
		name = "Move",
		iconPath = "./src/assets/images/icons/Move.svg",
		clicked = function()
			activeTool = "Move"
		end,
		tooltip = "Move a 2D node (W).",
	},
	{
		name = "Rotate",
		iconPath = "./src/assets/images/icons/Rotate.svg",
		clicked = function()
			activeTool = "Rotate"
		end,
		tooltip = "Rotate a Body2D (E).",
	},
	{
		name = "Size",
		iconPath = "./src/assets/images/icons/Size.svg",
		clicked = function()
			activeTool = "Size"
		end,
		tooltip = "Resize a Body2D (S).",
	},
	{
		name = "Snap",
		iconPath = "./src/assets/images/icons/Snap.svg",
		clicked = function()
			snap2D = not snap2D
		end,
		tooltip = "Toggle 8 pixel move/size and 15 degree rotation snapping.",
	},
}

for _, button in ipairs(buttons) do
	button.icon = Argon:CreateImageFromPath(button.iconPath)
end
for _, button in ipairs(buttons2D) do
	button.icon = Argon:CreateImageFromPath(button.iconPath)
end

local rects = {}
local guiYOffset = 32

renderer.Pool.new("2d", function()
	local dt = renderer.RuntimeLibrary.dt
	local absolutePosition = Viewport.AbsolutePosition
	local absoluteSize = Viewport.AbsoluteSize

	Viewport.Size = theme.ViewportCoordinates.Size
	Viewport.Position = theme.ViewportCoordinates.Position

	if not absolutePosition then
		return
	end
	if not absoluteSize then
		return
	end

	for _, object in pairs(game.StarterGui:GetChildren()) do
		if object:IsA("ScreenGui") then
			object.OverrideScreenSize = true
			object.Size = UDim2.new(0, absoluteSize.X, 0, absoluteSize.Y - guiYOffset)
			object.RenderOffset = Vector2.new(absolutePosition.X, absolutePosition.Y + guiYOffset + 5)
		end
	end

	Immco.Widget({
		x = absolutePosition.X,
		y = absolutePosition.Y + 5,
		width = absoluteSize.X,
		height = absoluteSize.Y,
		title = "Viewport",
		theme = theme,
		engine_window = renderer.Window,
		renderer = renderer,

		callback = function(params)
			if renderer.Dimension == "2D" then
				local toolbarRect = {
					x = absolutePosition.X + 28,
					y = absolutePosition.Y + 40,
					width = 40,
					height = #buttons2D * 40,
				}
				Immco.PanZoomCanvas({
					id = "2d-editor",
					x = absolutePosition.X,
					y = absolutePosition.Y + 35,
					width = absoluteSize.X,
					height = absoluteSize.Y - 35,

					engine_window = renderer.Window,
					renderer = renderer,
					theme = theme,
					RetainedStorage = retained,

					GridSize = 32,

					callback = function(view, frameDt)
						Immco.Scene2DEditor({
							id = "2d-editor-scene",
							view = view,
							workspace = workspace,
							GuiRoot = game.StarterGui,
							renderer = renderer,
							selection = Selection,
							ActiveTool = activeTool,
							SnapEnabled = snap2D,
							MoveSnap = 8,
							RotateSnap = 15,
							InputExclusionRect = toolbarRect,
							RetainedStorage = retained,
							OnToolChanged = function(tool)
								activeTool = tool
							end,
						}, frameDt)
					end,
				}, dt)
			else
				renderer:Set3DTexProps(absolutePosition.X, absolutePosition.Y + 35, absoluteSize.X, absoluteSize.Y - 35)
			end
			widget = params
		end,
	}, dt)
end)

renderer.Pool.new("2da", function()
	local params = widget

	if not params then
		return
	end

	local dt = renderer.RuntimeLibrary.dt
	local absolutePosition = Viewport.AbsolutePosition
	local absoluteSize = Viewport.AbsoluteSize

	local selected = Selection.Get()
	local items = {}
	local object = selected and selected[1]
	refreshHandles()

	local titleButtonSize = 26
	local titleButtonGap = 6
	local titleControlsWidth = titleButtonSize * 2 + titleButtonGap
	local titleControlsX = absolutePosition.X + (absoluteSize.X - titleControlsWidth) * 0.5
	local titleControlsY = absolutePosition.Y + 8
	local buttonsRect = {
		x = titleControlsX,
		y = titleControlsY,
		width = titleButtonSize,
		height = titleButtonSize,
	}

	Immco.ButtonGroup({
		x = buttonsRect.x,
		y = buttonsRect.y,

		width = 52,

		engine_window = renderer.Window,
		renderer = renderer,
		theme = theme,

		Orientation = "horizontal",

		ItemHeight = 26,
		IconSize = 16,
		PaddingX = 0,

		CornerRadius = 4,

		BackgroundColor = Argon:RGBA(44, 44, 44),
		ButtonColor = Argon:RGBA(44, 44, 44),

		HoverColor = Argon:RGBA(33, 33, 33),
		PressedColor = Argon:RGBA(25, 25, 25),

		BorderColor = Argon:RGBA(70, 70, 70),
		DividerColor = Argon:RGBA(70, 70, 70),

		ShowBorder = true,
		ShowDividers = true,

		Items = {
			{
				Icon = playIcon,
				Width = titleButtonSize,
				Height = titleButtonSize,

				OnClick = function()
					PlaytestService.CreatePlaytestAsync("game")
				end,
			},
			{
				Icon = stopIcon,
				Width = titleButtonSize,
				Height = titleButtonSize,

				OnClick = function()
					PlaytestService.StopCurrentPlaytest("game")
				end,
			},
		},
	}, dt)

	if selected and object then
		local path = object:GetFullName()
		local split = string.split(path, ".")

		for _, item in pairs(split) do
			table.insert(items, {
				Text = item,

				OnClick = function()
					Selection.Clear()
					Selection.Set({ object })
				end,
			})
		end
	end

	if renderer.Dimension == "3D" then
		Immco.Breadcrumb({
			x = absolutePosition.X + 8,
			y = absolutePosition.Y + absoluteSize.Y - 35,
			height = 32,

			engine_window = renderer.Window,
			renderer = renderer,
			theme = theme,

			Collapsed = true,
			Items = items,

			OnEllipsisClick = function(hiddenItems) end,
		}, dt)
	end

	local toolbarX = absolutePosition.X + (renderer.Dimension == "2D" and 28 or 10)
	local toolbarY = absolutePosition.Y + 40

	local buttonSize = 40
	local iconSize = 30

	local buttonItems = {}

	local visibleButtons = if renderer.Dimension == "2D" then buttons2D else buttons
	for i, btn in ipairs(visibleButtons) do
		local btnRect = {
			x = toolbarX,
			y = toolbarY + ((i - 1) * buttonSize),
			width = buttonSize,
			height = buttonSize,
		}

		rects[btn.iconPath] = btnRect

		table.insert(buttonItems, {
			Icon = btn.icon,
			Color = (activeTool == btn.name or (btn.name == "Snap" and snap2D)) and theme.AccentColor or nil,

			Width = buttonSize,
			Height = buttonSize,

			IconSize = iconSize,

			OnClick = function()
				btn.clicked()
			end,
		})
	end

	if renderer.Dimension == "3D" or renderer.Dimension == "2D" then
		Immco.RoundedRectangle({
			x = toolbarX - 2,
			y = toolbarY - 2,

			width = buttonSize + 4,
			height = (#visibleButtons * buttonSize) + 4,

			CornerRadius = 6,

			Color = Argon:RGBA(70, 70, 70),

			theme = theme,
			engine_window = renderer.Window,
		}, dt)

		Immco.ButtonGroup({
			x = toolbarX,
			y = toolbarY,

			width = buttonSize,

			engine_window = renderer.Window,
			renderer = renderer,
			theme = theme,

			Orientation = "vertical",

			ItemHeight = buttonSize,
			IconSize = iconSize,
			PaddingX = 0,

			CornerRadius = 4,

			BackgroundColor = Argon:RGBA(44, 44, 44),
			ButtonColor = Argon:RGBA(44, 44, 44),

			HoverColor = Argon:RGBA(33, 33, 33),
			PressedColor = Argon:RGBA(25, 25, 25),

			BorderColor = Argon:RGBA(70, 70, 70),
			DividerColor = Argon:RGBA(70, 70, 70),

			ShowBorder = false,
			ShowDividers = true,

			Items = buttonItems,
		}, dt)
	end

	-- Tooltips
	for _, btn in pairs(visibleButtons) do
		local btnRect = rects[btn.iconPath]

		if not btnRect then
			continue
		end

		Immco.Tooltip({
			RetainedStorage = retained,

			id = btn.iconPath,

			renderer = renderer,
			canvas = renderer.Window,
			window = renderer.Window,

			theme = theme,

			HoverRect = btnRect,
			Text = btn.tooltip,

			HoverDelay = 0.4,
			FadeSpeed = 14,

			Placement = "right",

			Offset = {
				x = 12,
				y = 40,
			},

			Gap = 8,
			MaxWidth = 220,
			Padding = 6,
			CornerRadius = 6,
		}, dt)
	end
end)
