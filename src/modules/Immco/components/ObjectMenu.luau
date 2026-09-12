--!strict
-- ObjectMenu: Insert Object catalog taxonomy plus context/object menu item builders.
--
-- Phase 4.2: the Insert Object catalog is split into exactly four groups --
-- Geometry, Constraints, Logic, Interaction -- so the Explorer "create" menu and the
-- floating right-click object menu can present classes as nested submenus instead of
-- one flat sorted list.
--
-- This module is pure logic (no renderer/game/Argon requires) so it stays
-- headless-testable under `zune run tests/object_menu.luau`. Floating behavior,
-- submenus, and keyboard navigation (arrows/enter/escape/mnemonics) are provided by
-- `Immco.ContextMenu`; callers pass the tables built here straight into it.

export type Item = {
	text: string?,
	shortcut: string?,
	separator: boolean?,
	disabled: boolean?,
	children: { Item }?,
	callback: (() -> ())?,
}

export type ObjectMenuOptions = {
	targetName: string?,
	insertNames: { string }?,
	onInsert: ((className: string) -> ())?,
	onDelete: (() -> ())?,
	onDuplicate: (() -> ())?,
	onGroup: (() -> ())?,
	onUngroup: (() -> ())?,
}

local ObjectMenu = {}

ObjectMenu.CATEGORY_ORDER = { "Geometry", "Constraints", "Logic", "Interaction" }

-- Explicit taxonomy for known creatable classes. Explicit entries always win over
-- the suffix heuristics below (e.g. UI*Constraint lives in Interaction, and
-- GroundDetector lives in Logic despite the Detector suffix).
local GEOMETRY = {
	"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart",
	"UnionOperation", "NegateOperation", "IntersectOperation",
	"Model", "Folder", "SpawnLocation",
	"Seat", "SeatPart", "VehicleSeat",
	"SpecialMesh", "Decal", "Texture",
	"Part2D", "Body2D", "World2D",
	"BoxCollider2D", "CircleCollider2D", "PolygonCollider2D",
	"Tilemap", "Layer2D",
	"Camera", "Camera2D", "Sky", "Atmosphere", "Clouds",
	"Bone", "ControlPoint",
	"Highlight", "SelectionBox", "SelectionSphere", "Handles", "ArcHandles",
}

local CONSTRAINTS = {
	"Attachment", "Attachment2D",
	"Weld", "WeldConstraint", "WeldConstraint2D",
	"BallSocketConstraint", "HingeConstraint", "HingeConstraint2D",
	"PrismaticConstraint", "CylindricalConstraint",
	"RopeConstraint", "RopeConstraint2D", "RodConstraint",
	"SpringConstraint", "SpringConstraint2D", "TorsionSpringConstraint",
	"UniversalConstraint", "PlaneConstraint", "RigidConstraint",
	"NoCollisionConstraint", "Motor6D", "Snap",
	"AlignPosition", "AlignOrientation",
	"LinearVelocity", "AngularVelocity", "VectorForce", "LineForce", "Torque",
	"BodyGyro", "IKControl",
}

local LOGIC = {
	"Script", "LocalScript", "ModuleScript",
	"BindableEvent", "BindableFunction",
	"RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent", "RemoteData",
	"BoolValue", "IntValue", "NumberValue", "StringValue", "ObjectValue",
	"BrickColorValue", "CFrameValue", "Color3Value",
	"IntConstrainedValue", "DoubleConstrainedValue",
	"RayValue", "Vector3Value", "BinaryStringValue",
	"Configuration", "Actor", "StateMachine",
	"Animator", "CharacterAnimator", "Animation", "Humanoid",
	"CharacterController", "CharacterMotor", "CharacterInput", "CharacterCamera",
	"MovementController", "JumpController", "RotationController",
	"GravityController", "CollisionController",
	"NetworkController", "PhysicsInteractionController",
	"GroundDetector", "Path3D", "SoftBody", "FluidSimulation",
}

local INTERACTION = {
	"ClickDetector", "ProximityPrompt", "Tool",
	"Sound", "Explosion", "Fire", "Smoke", "Sparkles",
	"ParticleEmitter", "ParticleEmitter2D", "Beam", "Trail",
	"PointLight", "SpotLight", "SurfaceLight", "ForceField",
	"ScreenGui", "SurfaceGui", "BillboardGui",
	"Frame", "ScrollingFrame", "ViewportFrame", "CanvasGroup",
	"TextLabel", "TextButton", "TextBox", "ImageLabel", "ImageButton",
	"ShaderFrame", "PostProcessShader", "MaterialShader",
	"UIAnchorLayout", "UIAspectRatioConstraint", "UIBackdrop", "UICellList",
	"UICorner", "UIDragDetector", "UIFlexItem", "UIFlowLayout",
	"UIGradient", "UIGridLayout", "UIListLayout", "UIPadding",
	"UIPageLayout", "UIScale", "UIScaleDetector", "UIShadow",
	"UISizeConstraint", "UISquircle", "UIStackLayout", "UIStroke",
	"UITableLayout", "UITextSizeConstraint",
	"BloomEffect", "BlurEffect", "DOFEffect", "SunRaysEffect",
	"VignetteEffect", "SSAOEffect", "SSGIEffect", "SSILEffect", "SSREffect",
	"TonemapEffect", "FogEffect", "ColorEffect",
	"EchoSoundEffect", "EqualizerSoundEffect",
	"HighPassSoundEffect", "LowPassSoundEffect", "ReverbSoundEffect",
}

local EXPLICIT: { [string]: string } = {}
for _, name in ipairs(GEOMETRY) do
	EXPLICIT[name] = "Geometry"
end
for _, name in ipairs(CONSTRAINTS) do
	EXPLICIT[name] = "Constraints"
end
for _, name in ipairs(LOGIC) do
	EXPLICIT[name] = "Logic"
end
for _, name in ipairs(INTERACTION) do
	EXPLICIT[name] = "Interaction"
end

-- Joint/force classes without a "Constraint" suffix (checked after EXPLICIT).
local JOINTS: { [string]: boolean } = {
	Attachment = true,
	Weld = true,
	Motor6D = true,
	Snap = true,
	AlignPosition = true,
	AlignOrientation = true,
	LinearVelocity = true,
	AngularVelocity = true,
	VectorForce = true,
	LineForce = true,
	Torque = true,
	BodyGyro = true,
	IKControl = true,
}

local function endsWith(value: string, suffix: string): boolean
	if #suffix > #value then
		return false
	end
	return value:sub(#value - #suffix + 1) == suffix
end

local function categorize(className: string): string
	local explicit = EXPLICIT[className]
	if explicit then
		return explicit
	end

	if string.find(className, "Constraint", 1, true) then
		return "Constraints"
	end
	local base = className:gsub("2D$", "")
	if JOINTS[className] or JOINTS[base] then
		return "Constraints"
	end

	if string.find(className, "Script", 1, true)
		or string.find(className, "Value", 1, true)
		or endsWith(className, "Event")
		or endsWith(className, "Function")
		or string.find(className, "Controller", 1, true)
		or string.find(className, "Animator", 1, true)
		or string.find(className, "Humanoid", 1, true)
		or className == "Actor"
		or className == "StateMachine"
		or className == "Animation"
		or className == "Path3D"
	then
		return "Logic"
	end

	if string.find(className, "Detector", 1, true)
		or string.find(className, "Prompt", 1, true)
		or string.find(className, "Gui", 1, true)
		or string.find(className, "UI", 1, true)
		or string.find(className, "Effect", 1, true)
		or string.find(className, "Light", 1, true)
		or string.find(className, "Sound", 1, true)
		or string.find(className, "Emitter", 1, true)
		or string.find(className, "Beam", 1, true)
		or string.find(className, "Trail", 1, true)
		or string.find(className, "Tool", 1, true)
		or string.find(className, "Explosion", 1, true)
		or string.find(className, "Fire", 1, true)
		or string.find(className, "Smoke", 1, true)
		or string.find(className, "Sparkles", 1, true)
		or string.find(className, "Shader", 1, true)
		or string.find(className, "Force", 1, true)
		or string.find(className, "Image", 1, true)
	then
		return "Interaction"
	end

	if string.find(className, "Part", 1, true)
		or string.find(className, "Mesh", 1, true)
		or string.find(className, "Operation", 1, true)
		or string.find(className, "Model", 1, true)
		or string.find(className, "Collider", 1, true)
		or string.find(className, "Tile", 1, true)
		or string.find(className, "Decal", 1, true)
		or string.find(className, "Texture", 1, true)
		or string.find(className, "Spawn", 1, true)
		or string.find(className, "Camera", 1, true)
		or string.find(className, "Sky", 1, true)
		or string.find(className, "Folder", 1, true)
		or string.find(className, "Seat", 1, true)
		or string.find(className, "Bone", 1, true)
		or string.find(className, "Handles", 1, true)
		or string.find(className, "Layer", 1, true)
		or string.find(className, "World", 1, true)
		or string.find(className, "Cloud", 1, true)
		or string.find(className, "Atmosphere", 1, true)
	then
		return "Geometry"
	end

	-- Misc behavior bucket for unrecognized future classes.
	return "Logic"
end

ObjectMenu.categorize = categorize

local function groupClasses(names: { string }): { [string]: { string } }
	local groups: { [string]: { string } } = {
		Geometry = {},
		Constraints = {},
		Logic = {},
		Interaction = {},
	}
	for _, name in ipairs(names) do
		table.insert(groups[categorize(name)], name)
	end
	for _, category in ipairs(ObjectMenu.CATEGORY_ORDER) do
		table.sort(groups[category])
	end
	return groups
end

ObjectMenu.groupClasses = groupClasses

local function buildInsertItems(names: { string }, onCreate: (string) -> ()): { Item }
	local groups = groupClasses(names)
	local items: { Item } = {}
	for _, category in ipairs(ObjectMenu.CATEGORY_ORDER) do
		local children: { Item } = {}
		for _, className in ipairs(groups[category]) do
			local captured = className
			table.insert(children, {
				text = captured,
				callback = function()
					onCreate(captured)
				end,
			})
		end
		table.insert(items, { text = category, children = children })
	end
	return items
end

ObjectMenu.buildInsertItems = buildInsertItems

local function buildObjectItems(opts: ObjectMenuOptions): { Item }
	local items: { Item } = {}
	local onInsert = opts.onInsert
	local sink: (string) -> () = onInsert or function(_: string) end
	table.insert(items, {
		text = "Insert Object",
		children = buildInsertItems(opts.insertNames or {}, sink),
		disabled = if onInsert then nil else true,
	})
	table.insert(items, { separator = true })
	if opts.onDelete then
		table.insert(items, { text = "Delete", shortcut = "Del", callback = opts.onDelete })
	end
	if opts.onDuplicate then
		table.insert(items, { text = "Duplicate", shortcut = "Ctrl+D", callback = opts.onDuplicate })
	end
	if opts.onGroup then
		table.insert(items, { text = "Group", shortcut = "Ctrl+G", callback = opts.onGroup })
	end
	if opts.onUngroup then
		table.insert(items, { text = "Ungroup", shortcut = "Ctrl+Shift+G", callback = opts.onUngroup })
	end
	return items
end

ObjectMenu.buildObjectItems = buildObjectItems

return ObjectMenu
