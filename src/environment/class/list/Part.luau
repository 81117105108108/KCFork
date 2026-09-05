--!strict
-- description: "A basic 3D primitive used for physics, collision, and world building."
local resources = require("../../../engine/ffi/ResourceTracker").shared
local Vector3 = require("@Vector3")
local Color3 = require("@Color3")
local CFrame = require("@CFrame")
local Enum = require("@EnumMap")
local signal = require("@Kinemium.signal")
local manifold = require("@manifold")
local PhysicalProperties = require("@PhysicalProperties")

local propTable = {
	Position = Vector3.new(0, 10, 0),
	Size = Vector3.new(2, 1, 4),
	Color = Color3.new(1, 1, 1),
	Material = Enum.Material.SmoothPlastic,
	Transparency = 0,
	Anchored = true,
	NeonEnergy = 5.0,
	CanCollide = true,
	CanQuery = true,
	CollisionGroup = "Default",
	Velocity = Vector3.new(0, 0, 0),
	CustomPhysicalProperties = PhysicalProperties.new(1, 1, 0, 1, 0),
	CurrentPhysicalProperties = PhysicalProperties.new(1, 1, 0, 1, 0),
	MeshScale = 1,
	Mass = 1,
	AudioCanCollide = true,
	EnableFluidForces = false,
	Restitution = 0.5,
	Elasticity = 0.5,
	Friction = 0.3,
	Shape = Enum.PartType.Block,
	CastsShadow = true,
	Reflectance = 0,
	Roughness = 0.5,
	Metallic = 0,
	Locked = false,
	Orientation = Vector3.new(0, 0, 0),
	Rotation = Vector3.new(0, 0, 0),
	MouseOverObject = false,
	CFrame = CFrame.new(0, 10, 0),
	ElapsedTime = 0,
	Name = "Part",
	BaseClass = "BasePart",
	IsKinematic = false,
	CastShadow = true,

	_mesh = nil,
	_manifoldptr = nil,

	-- Velocity
	AssemblyAngularVelocity = Vector3.new(0, 0, 0),
	AssemblyCenterOfMass = Vector3.new(0, 0, 0),
	AssemblyLinearVelocity = Vector3.new(0, 0, 0),
	AssemblyMass = 0,
	AssemblyRootPart = nil,

	-- Network
	NetworkOwnerType = Enum.MachineNetworkOwner.Server,
}

local function UpdateManifoldPointer(instance, sizeOverride)
	local size = sizeOverride or instance.Size
	if instance.Shape == Enum.PartType.Block then
		instance._manifoldptr = manifold.gen.box(size.X, size.Y, size.Z)
	elseif instance.Shape == Enum.PartType.Ball then
		local radius = size.X * 0.5
		instance._manifoldptr = manifold.gen.sphere(radius, 32)
	elseif instance.Shape == Enum.PartType.Cylinder then
		local radius = size.X * 0.5
		local height = size.Y
		local segments = 24

		instance._manifoldptr = manifold.gen.cylinder(radius, height, segments, true, radius)
	end
end

local function syncFromCFrame(instance, cf)
	if not cf or not cf.Position then
		return
	end

	local rx, ry, rz = cf:ToOrientation()
	local props = rawget(instance, "_props")
	if not props then
		return
	end

	props.Position = cf.Position
	props.Orientation = Vector3.new(rx, ry, rz)
	props.Rotation = props.Orientation
	rawset(instance, "__matrixDirty", true)
	local batch = rawget(instance, "__workspaceBatch")
	if batch then
		batch.instancesDirty = true
	end
	local chunk = rawget(instance, "__workspaceChunk")
	if chunk then
		chunk.instanceDataDirty = true
	end
end

local function syncFromPosition(instance, position)
	if not position then
		return
	end

	local props = rawget(instance, "_props")
	if not props or not props.CFrame then
		return
	end

	props.CFrame = props.CFrame:WithPosition(position)
end

local function setupTouchSignals(instance, renderer)
	if rawget(instance, "Touched") and rawget(instance, "TouchEnded") then
		return
	end

	local touched = signal.new()
	local touchEnded = signal.new()
	rawset(instance, "Touched", touched)
	rawset(instance, "TouchEnded", touchEnded)

	instance.Destroying:Connect(function()
		if renderer and renderer.EventBus then
			renderer.EventBus:Fire("RemovedPartFromRenderPool", instance)
		end
		touched:Destroy()
		touchEnded:Destroy()
		rawset(instance, "Touched", nil)
		rawset(instance, "TouchEnded", nil)
	end)
end

return {
	class = "Part",
	setupTouchSignals = setupTouchSignals,

	callback = function(instance, renderer, game)
		instance:SetMetadata("IsMovable", true)

		local KinemiumPhysicsService = game:GetService("UnifiedPhysicsService")
		instance:SetProperties(propTable)
		setupTouchSignals(instance, renderer)
		syncFromCFrame(instance, instance.CFrame)
		if renderer and renderer.EventBus then
			renderer.EventBus:Fire("UpdatePart", instance)
		end

		-- api

		-- description: "Applies physics impulse."
		-- args: "self: table, v: Vector3"
		function instance:ApplyImpulse(v)
			if KinemiumPhysicsService then
				return KinemiumPhysicsService.ApplyImpulse(instance, v)
			end
			return false
		end

		-- description: "Applies physics impulse at a specified position."
		-- args: "self: table, v: Vector3"
		function instance:ApplyImpulseAtPosition(v)
			-- add impulse at position feature
			if KinemiumPhysicsService then
				return KinemiumPhysicsService.ApplyImpulse(instance, v)
			end
			return false
		end

		-- description: "Returns whether the parts can collide with each other."
		-- args: "self: table, part: Part"
		function instance:CanCollideWith(part)
			-- add support
		end

		-- All writes, including CSG replacements, transfer native ownership here.
		instance:SetBarrier("_manifoldptr", function(pointer: any): boolean
			local props = rawget(instance, "_props")
			if not props then return false end
			local previous = props._manifoldptr
			if pointer == previous then return true end
			assert(pointer ~= zune.ffi.null, "Manifold allocation failed")
			if pointer ~= nil then resources:Track(instance, pointer, manifold.gen.free) end
			props._manifoldptr = pointer
			if previous ~= nil then resources:Release(instance, previous) end
			return true
		end)
		UpdateManifoldPointer(instance)
		local cloners = rawget(instance, "_propertyCloners") or {}
		rawset(instance, "_propertyCloners", cloners)
		cloners._manifoldptr = function(pointer: any): any
			local copy = manifold.gen.alloc()
			assert(copy ~= nil and copy ~= zune.ffi.null, "Manifold allocation failed")
			local ok, failure = pcall(function()
				assert(manifold.lib.manifold_copy(copy, pointer) ~= zune.ffi.null, "Manifold copy failed")
				resources:Track(instance, copy, manifold.gen.free)
			end)
			if not ok then
				manifold.gen.free(copy)
				error(failure)
			end
			return copy
		end
		instance:SetBarrier("CFrame", function(value)
			syncFromCFrame(instance, value)
			return true
		end)
		instance:SetBarrier("Position", function(value)
			syncFromPosition(instance, value)
			return true
		end)
		instance:SetBarrier("Size", function(value)
			UpdateManifoldPointer(instance, value)
			return true
		end)

		instance:_SetPropertyHandler("Parent", function()
			if renderer and renderer.EventBus then
				local route = instance.Parent and "UpdatePart" or "RemovedPartFromRenderPool"
				renderer.EventBus:Fire(route, instance)
			end
		end)

		local function updatePhysicsParticipation()
			if renderer and renderer.EventBus and instance.Parent then
				renderer.EventBus:Fire("UpdatePart", instance)
			end
		end
		instance:_SetPropertyHandler("Anchored", updatePhysicsParticipation)
		instance:_SetPropertyHandler("CanCollide", updatePhysicsParticipation)
		instance:_SetPropertyHandler("IsKinematic", updatePhysicsParticipation)

		instance.Destroying:Connect(function()
			instance._mesh = nil
		end)

		return instance
	end,

	inherit = function(tble)
		for prop, val in pairs(propTable) do
			if not tble[prop] then
				tble[prop] = val
			end
		end
	end,
}
