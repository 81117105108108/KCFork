-- description: "Renders a 3D Mesh in 3D Space."
local Vector3 = require("@Vector3")
local Part = require("@Part")
local Enum = require("@EnumMap")
local argon = require("@Argon")

local propTable = {
	MeshObject = nil,
	MeshId = "",
	TextureID = "",
	TextureId = "",
	_showhitbox = false,
	CollisionFidelity = Enum.CollisionFidelity.Default,
	RenderFidelity = Enum.RenderFidelity.Automatic,
	CollisionScale = 1,
	_meshUsesPartSize = true,
	Anchored = true,
	Name = "MeshPart",
	BaseClass = "BasePart",
	MeshScale = 1,
	Transparency = 0,
	Size = Vector3.new(1, 1, 1),
}

Part.inherit(propTable)

return {
	class = "MeshPart",

	callback = function(instance, renderer, game)
		instance:SetProperties(propTable)
		Part.setupTouchSignals(instance, renderer)
		instance:SetMetadata("IsMovable", true)

		local KinemiumPhysicsService = game and game:GetService("UnifiedPhysicsService") or nil

		instance.ApplyImpulse = function(self, v)
			if KinemiumPhysicsService then
				return KinemiumPhysicsService.ApplyImpulse(instance, v)
			end
			return false
		end

		renderer.EventBus:Fire("UpdatePart", instance)

		local syncingTransform = false

		local ownedMeshObject = nil
		local loadingMeshId = false
		local ownedTexture = nil
		local loadingTexture = false

		local function syncMeshObject(meshObject)
			instance._mesh = meshObject and (meshObject._mesh or meshObject._meshgenHandle) or nil
			instance._cpuMeshData = meshObject and meshObject._cpuMeshData or nil
			instance._materialHandle = meshObject and meshObject._materialHandle or nil
		end

		local function releaseOwnedMeshObject()
			if not ownedMeshObject then
				return
			end
			local previous = ownedMeshObject
			ownedMeshObject = nil
			if instance.MeshObject == previous then
				rawget(instance, "_props").MeshObject = nil
			end
			previous:Destroy()
		end

		local function releaseOwnedTexture()
			if ownedTexture and renderer and renderer.Window then
				argon:Destroy3DTexture(renderer.Window, ownedTexture)
			end
			ownedTexture = nil
			rawget(instance, "_props")._meshTexture = nil
		end

		local function loadTexture(textureId)
			if loadingTexture then
				return
			end
			loadingTexture = true
			releaseOwnedTexture()

			local path = type(textureId) == "string" and textureId or ""
			if path ~= "" and not _G.IsHeadless and renderer and renderer.Window then
				local ok, texture = pcall(argon.CreateMeshTexture, argon, renderer.Window, path)
				if ok and texture then
					ownedTexture = texture
					rawget(instance, "_props")._meshTexture = texture
				else
					warn(`MeshPart could not load texture "{path}"`)
				end
			end

			loadingTexture = false
			renderer.EventBus:Fire("UpdatePart", instance)
		end

		local function loadMeshId(meshId)
			if loadingMeshId then
				return
			end
			loadingMeshId = true
			releaseOwnedMeshObject()

			local path = type(meshId) == "string" and meshId or ""
			if path ~= "" and not _G.IsHeadless and renderer and renderer.Window then
				local ok, mesh = pcall(argon.CreateMeshFromPath, argon, renderer.Window, path)
				if ok and mesh and mesh._handle then
					local Registry = require("@InstanceRegistry")
					local meshObject = Registry.new("EditableMesh", renderer, game)
					mesh._window = renderer.Window
					meshObject.Name = instance.Name .. "Mesh"
					meshObject._mesh = mesh
					meshObject._meshgenHandle = mesh
					meshObject._sourcePath = path
					meshObject._geometryDirty = false
					ownedMeshObject = meshObject
					rawget(instance, "_props").MeshObject = meshObject
					syncMeshObject(meshObject)
				else
					warn(`MeshPart could not load mesh "{path}"`)
					syncMeshObject(nil)
				end
			else
				syncMeshObject(nil)
			end

			loadingMeshId = false
			renderer.EventBus:Fire("UpdatePart", instance)
		end

		local function syncFromCFrame(cf)
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
		end

		local function syncFromPosition(position)
			if not position then
				return
			end
			local props = rawget(instance, "_props")
			if not props or not props.CFrame then
				return
			end
			props.CFrame = props.CFrame:WithPosition(position)
		end

		if instance.MeshId ~= "" then
			loadMeshId(instance.MeshId)
		else
			syncMeshObject(instance.MeshObject)
		end
		if instance.TextureID ~= "" then
			loadTexture(instance.TextureID)
		elseif instance.TextureId ~= "" then
			loadTexture(instance.TextureId)
		end

		instance.Changed:Connect(function(property, value)
			if syncingTransform then
				return
			end
			if property == "CFrame" then
				syncingTransform = true
				syncFromCFrame(value)
				syncingTransform = false
			elseif property == "Position" then
				syncingTransform = true
				syncFromPosition(value)
				syncingTransform = false
			elseif property == "MeshObject" then
				if value ~= ownedMeshObject then
					releaseOwnedMeshObject()
				end
				syncMeshObject(value)
				renderer.EventBus:Fire("UpdatePart", instance)
			elseif property == "MeshId" then
				loadMeshId(value)
			elseif property == "TextureID" or property == "TextureId" then
				local props = rawget(instance, "_props")
				if property == "TextureID" then
					props.TextureId = value
				else
					props.TextureID = value
				end
				loadTexture(value)
			elseif
				property == "_mesh"
				or property == "_cpuMeshData"
				or property == "_meshUsesPartSize"
				or property == "Material"
			then
				renderer.EventBus:Fire("UpdatePart", instance)
			elseif property == "Parent" then
				renderer.EventBus:Fire("UpdatePart", instance)
			end
		end)

		instance.Destroying:Connect(function()
			releaseOwnedTexture()
			releaseOwnedMeshObject()
		end)

		return instance
	end,
	inherit = function()
		return propTable
	end,
}
