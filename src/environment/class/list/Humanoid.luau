-- description: "Compatibility wrapper for CharacterController."
local Enum = require("@EnumMap")
local signal = require("@Kinemium.signal")
local Vector3 = require("@Vector3")
local CFrame = require("@CFrame")
local Color3 = require("@Color3")

local ZERO = Vector3.new(0, 0, 0)
local CONTROLLER_PROPERTIES = {
	AutoRotate = true,
	WalkSpeed = true,
	JumpPower = true,
	JumpHeight = true,
	UseJumpPower = true,
	TurnSpeed = true,
	SprintMultiplier = true,
	JumpQueueWindow = true,
	RootPart = true,
}
local propTable = {
	AutoRotate = true,
	WalkSpeed = 16,
	JumpPower = 50,
	JumpHeight = 7.2,
	HipHeight = 0,
	MaxHealth = 100,
	Health = 100,
	DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer,
	NameDisplayDistance = 100,
	HealthDisplayDistance = 100,
	HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged,
	RigType = Enum.RigType.Rig15,
	PlatformStand = false,
	Sit = false,
	UseJumpPower = true,
	TurnSpeed = 18,
	SprintMultiplier = 1.5,
	JumpQueueWindow = 0.1,
	MoveDirection = ZERO,
	RootPart = nil,
	Character = nil,
}
local STATE_ENUM = {
	Idle = Enum.HumanoidStateType.Running,
	Running = Enum.HumanoidStateType.Running,
	Jumping = Enum.HumanoidStateType.Jumping,
	Freefall = Enum.HumanoidStateType.Freefall,
	Landed = Enum.HumanoidStateType.Landed,
	Swimming = Enum.HumanoidStateType.Swimming,
	Climbing = Enum.HumanoidStateType.Climbing,
	Dead = Enum.HumanoidStateType.Dead,
	Seated = Enum.HumanoidStateType.Seated,
}
local ENUM_STATE = {}
for name, value in pairs(STATE_ENUM) do
	ENUM_STATE[value] = name
end
ENUM_STATE[Enum.HumanoidStateType.Running] = "Running"

return {
	class = "Humanoid",
	callback = function(instance, renderer, datamodel)
		instance:SetProperties(propTable)
		instance.Died = signal.new()
		instance.HealthChanged = signal.new()
		instance.Jumping = signal.new()
		instance.StateChanged = signal.new()

		local controller
		local controllerConnections = {}
		local writingController = false
		local function disconnectController()
			for _, connection in ipairs(controllerConnections) do
				connection:Disconnect()
			end
			table.clear(controllerConnections)
		end
		local function newObject(className)
			local Registry = require("@InstanceRegistry")
			local ok, object = pcall(Registry.new, className, renderer, datamodel)
			return ok and object or nil
		end
		local function bindController(nextController)
			if controller == nextController then
				return controller
			end
			disconnectController()
			controller = nextController
			if not controller then
				return nil
			end
			writingController = true
			for property in pairs(CONTROLLER_PROPERTIES) do
				if instance[property] ~= nil then
					controller[property] = instance[property]
				end
			end
			controller.Character = instance.Parent
			writingController = false
			table.insert(
				controllerConnections,
				controller.Jumping:Connect(function(active)
					instance.Jumping:Fire(active)
				end)
			)
			table.insert(
				controllerConnections,
				controller.StateChanged:Connect(function(nextState, previousState)
					instance.StateChanged:Fire(
						STATE_ENUM[nextState] or nextState,
						STATE_ENUM[previousState] or previousState
					)
				end)
			)
			return controller
		end
		local function ensureController()
			local character = instance.Parent
			if not character or character.ClassName ~= "Model" then
				bindController(nil)
				return nil
			end
			instance.Character = character
			-- Replication parents instances before the complete authoritative
			-- hierarchy exists. Do not manufacture a parallel local controller tree
			-- while that hierarchy is being assembled.
			if datamodel and rawget(datamodel, "_ApplyingReplicationHierarchy") then
				return nil
			end
			local found = character:FindFirstChildOfClass("CharacterController")
			if not found then
				found = newObject("CharacterController")
				if found then
					found.Parent = character
				end
			end
			return bindController(found)
		end

		for property in pairs(CONTROLLER_PROPERTIES) do
			instance:_SetPropertyHandler(property, function(value)
				if not writingController then
					local active = ensureController()
					if active then
						active[property] = value
					end
				end
			end)
		end
		instance:_SetPropertyHandler("Parent", ensureController)
		instance:_SetPropertyHandler("Health", function(value)
			value = math.clamp(tonumber(value) or 0, 0, tonumber(instance.MaxHealth) or 100)
			rawget(instance, "_props").Health = value
			instance.HealthChanged:Fire(value)
			if value <= 0 then
				local active = ensureController()
				if active then
					active:ChangeState("Dead")
				end
				instance.Died:Fire()
			end
		end)

		function instance:GetController()
			return ensureController()
		end
		function instance:Move(direction)
			local active = ensureController()
			if active then
				active:Move(direction)
				self.MoveDirection = active.MoveDirection
			end
		end
		function instance:MoveRelative(direction, basis)
			local active = ensureController()
			if active then
				active:MoveRelative(direction, basis)
				self.MoveDirection = active.MoveDirection
			end
		end
		function instance:Jump()
			local active = ensureController()
			return active and active:Jump() or false
		end
		instance.RequestJump = instance.Jump
		function instance:SetSprinting(sprinting)
			local active = ensureController()
			if active then
				active:SetSprinting(sprinting)
			end
		end
		function instance:Face(direction)
			local active = ensureController()
			if active then
				active:Face(direction)
			end
		end
		function instance:ClearFacingDirection()
			local active = ensureController()
			if active then
				active:ClearFacingDirection()
			end
		end
		function instance:GetState()
			local active = ensureController()
			return STATE_ENUM[active and active:GetState() or "Freefall"] or Enum.HumanoidStateType.None
		end
		function instance:ChangeState(state)
			local active = ensureController()
			return active and active:ChangeState(ENUM_STATE[state] or state) or false
		end
		function instance:TakeDamage(amount)
			self.Health = self.Health - math.max(tonumber(amount) or 0, 0)
		end

		function instance:CreateDefaultRig(options)
			options = options or {}
			local character = options.Character or self.Parent
			if not character then
				error("CreateDefaultRig requires a Character model", 2)
			end
			self.Character = character
			if self.Parent ~= character then
				self.Parent = character
			end
			local spawn = options.SpawnCFrame or CFrame.new(0, 10, 0)
			local bodyColor = options.BodyColor or Color3.fromRGB(244, 244, 244)
			local roundedCubeMesh = options.BodyMeshId or "./src/assets/meshes/capsule/scene.gltf"
			local legacyPartNames = {
				"Torso",
				"Neck",
				"Head",
				"Left Shoulder",
				"Left Arm",
				"Left Hand",
				"Left Hip",
				"Left Leg",
				"Left Foot",
				"Right Shoulder",
				"Right Arm",
				"Right Hand",
				"Right Hip",
				"Right Leg",
				"Right Foot",
			}
			for _, name in ipairs(legacyPartNames) do
				local legacyPart = character:FindFirstChild(name)
				if legacyPart then
					legacyPart:Destroy()
				end
			end

			local part = character:FindFirstChild("HumanoidRootPart")
			local created = false
			if part and part.ClassName ~= "MeshPart" then
				part:Destroy()
				part = nil
			end
			if not part then
				part = newObject("MeshPart")
				if part then
					part.Name = "HumanoidRootPart"
					created = true
				end
			end
			if not part then
				error("CreateDefaultRig could not create the capsule body", 2)
			end

			part.Size = options.BodySize or Vector3.new(1.3, 1.5, 1.3)
			part.CFrame = spawn
			part.Color = bodyColor
			part.Material = Enum.Material.SmoothPlastic
			part.Reflectance = 0
			part.Metallic = 0
			part.Roughness = 0.62
			part.Transparency = 0
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = true
			part.MeshScale = options.BodyMeshScale or 0.5
			part.MeshId = roundedCubeMesh
			if created then
				part.Parent = character
			end
			self.RootPart = part
			self.HipHeight = 0
			character.PrimaryPart = self.RootPart
			local animator = self:FindFirstChildOfClass("Animator") or newObject("Animator")
			if animator and not animator.Parent then
				animator.Parent = self
			end
			local active = ensureController()
			if active then
				active.RootPart = self.RootPart
			end
			return character
		end

		function instance:RestoreRig()
			local character = self.Parent
			if not character then
				return false
			end
			self.RootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			character.PrimaryPart = self.RootPart
			local active = ensureController()
			if active then
				active.RootPart = self.RootPart
			end
			return self.RootPart ~= nil
		end

		instance.Destroying:Connect(disconnectController)
		return instance
	end,
	inherit = function(tble)
		for prop, val in pairs(propTable) do
			tble[prop] = val
		end
	end,
}
