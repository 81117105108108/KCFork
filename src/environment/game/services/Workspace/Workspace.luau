local Instance = require("@Instance")
local Workspace = Instance.new("Workspace")
local Enum = require("@EnumMap")
local CFrame = require("@CFrame")
local argon = require("@Argon")
local zembed = require("@zembed")
local Vector3 = require("@Vector3")
local Frustum = require("../../../datatypes/Frustum")
local Octree = require("../../../datatypes/Octree")

export type KinemiumCFrame = typeof(CFrame.new())
Workspace._Intents = Enum.PluginIntents.Graphic

local materialTextures = {}
local displacedMaterials = {}

local materialHeightScales = {
	brick = 0.12,
	wood = 0.04,
}

Workspace.InitRenderer = function(renderer, signal, game)
	Workspace:SetProperties({
		Test = 1,
		MaterialMode = Enum.WorkspaceMaterialMode.Compressed,
		PhysicsEngine = Enum.PhysicsEngine.Default,
		Gravity = -9.81,
		GlobalWind = Vector3.new(0, 0, 0),
		CurrentCamera2D = nil,
	})

	function Workspace:Raycast(origin, direction, params)
		local physicsService = game:GetService("UnifiedPhysicsService")
		if not physicsService or not physicsService.Raycast then
			return nil
		end
		return physicsService.Raycast(origin, direction, params)
	end

	if IsHeadless == true then
		Workspace.MeshesPreset = {}
		return Workspace
	end

	local meshes = {
		cube = argon:CreateMesh(renderer.Window, "cube"),
		displacedCube = argon:CreateMesh(renderer.Window, "displacedCube"),
		sphere = argon:CreateMesh(renderer.Window, "sphere"),
		cylinder = argon:CreateMesh(renderer.Window, "cylinder"),
		wedge = argon:CreateMesh(renderer.Window, "wedge"),
	}
	Workspace.MeshesPreset = meshes

	local material_index = {}

	for _, material in pairs(Enum.Material:GetEnumItems()) do
		material_index[material.Value] = material
	end

	local function fillMaterialTex(WorkspaceMaterialMode)
		if WorkspaceMaterialMode == Enum.WorkspaceMaterialMode.Compressed then
			local path = "./src/assets/materials/compressed"
			local entries = {}

			if zembed.IsEmbedded() then
				local seen = {}
				for _, filePath in pairs(zembed.GetAssetFilesUnder(path)) do
					local materialName =
						filePath:gsub([[\]], "/"):match("^src/assets/materials/compressed/([^/]+)/albedo%.png$")
					if materialName and not seen[materialName] then
						seen[materialName] = true
						table.insert(entries, {
							kind = "directory",
							name = materialName,
						})
					end
				end
			else
				entries = zune.fs.entries(path)
			end

			for _, dir in pairs(entries) do
				if dir.kind ~= "directory" then
					continue
				end

				local albedo_tex = path .. `/{dir.name}/albedo.png` -- assume pngs
				local normal_tex = path .. `/{dir.name}/normal.png`
				local orm_tex = path .. `/{dir.name}/orm.png`
				local height_tex = path .. `/{dir.name}/height.png`

				local ptr = argon:CreatePbrMeshTexture(
					renderer.Window,
					albedo_tex,
					normal_tex,
					orm_tex,
					height_tex,
					materialHeightScales[dir.name] or 0
				)

				materialTextures[material_index[dir.name]] = ptr
				if (materialHeightScales[dir.name] or 0) > 0 then
					displacedMaterials[material_index[dir.name]] = true
				end
			end
		end
	end

	fillMaterialTex(Enum.WorkspaceMaterialMode.Compressed)

	local function getMaterialKind(materialEnum)
		if not materialEnum then
			return 0
		end
		if materialEnum == Enum.Material.Glass then
			return 1
		end
		if materialEnum == Enum.Material.Neon then
			return 2
		end
		if materialEnum == Enum.Material.Water then
			return 3
		end
		return 0
	end

	local function getMeshForShape(shape, material)
		if shape == Enum.PartType.Ball then
			return meshes.sphere
		end
		if shape == Enum.PartType.Cylinder then
			return meshes.cylinder
		end
		if shape == Enum.PartType.Wedge or shape == Enum.PartType.CornerWedge then
			return meshes.wedge
		end
		if displacedMaterials[material] then
			return meshes.displacedCube
		end
		return meshes.cube
	end

	local renderParts = {}
	local renderPartIndices = {}
	local metadataDirty = true
	local dynamicGroups = {}
	local dynamicPartState = {}
	local spatialIndex = Octree.new(Vector3.new(0, 0, 0), 1048576, 32, 8, 1.5)
	local spatialOverflow = {}
	local nextSpatialId = 0
	local frameFrustum: Frustum.Frustum? = nil
	local cullStats = { testedGroups = 0, culledGroups = 0, testedParts = 0, visibleParts = 0, culledParts = 0 }
	local renderProperties = {
		Size = true,
		Color = true,
		Transparency = true,
		Metallic = true,
		Roughness = true,
		CastShadow = true,
		Material = true,
		Shape = true,
		MeshObject = true,
		_mesh = true,
		MeshScale = true,
		TextureID = true,
		TextureId = true,
		_meshTexture = true,
	}
	local transformProperties = {
		CFrame = true,
		Position = true,
	}

	local function isBasePart(object)
		local props = rawget(object, "_props")
		return props
			and (
				props.ClassName == "BasePart"
				or props.BaseClass == "BasePart"
				or rawget(object, "BaseClass") == "BasePart"
			)
	end

	local function addPart(object)
		if not isBasePart(object) or renderPartIndices[object] then
			return
		end
		table.insert(renderParts, object)
		renderPartIndices[object] = #renderParts
		metadataDirty = true
	end

	local function removePart(object)
		local index = renderPartIndices[object]
		if not index then
			return
		end
		local last = renderParts[#renderParts]
		renderParts[index] = last
		renderParts[#renderParts] = nil
		renderPartIndices[object] = nil
		if last and last ~= object then
			renderPartIndices[last] = index
		end
		metadataDirty = true
	end

	local function addTree(object)
		if object.ClassName == "MaterialShader" then
			metadataDirty = true
		end
		addPart(object)
		for _, descendant in pairs(object:GetDescendants()) do
			addPart(descendant)
		end
	end

	local function removeTree(object)
		if object.ClassName == "MaterialShader" then
			metadataDirty = true
		end
		removePart(object)
		for _, descendant in pairs(object:GetDescendants()) do
			removePart(descendant)
		end
	end

	for _, descendant in pairs(Workspace:GetDescendants()) do
		addPart(descendant)
	end
	local descendantAdded = Workspace.DescendantAdded:Connect(addTree)
	local descendantRemoving = Workspace.DescendantRemoving:Connect(removeTree)
	local descendantChanged = Workspace.DescendantChanged:Connect(function(object, property)
		if object.ClassName == "MaterialShader" then
			metadataDirty = true
			return
		end
		if not renderPartIndices[object] then
			return
		end
		if transformProperties[property] then
			local state = dynamicPartState[object]
			if state and not state.dirty then
				state.dirty = true
				table.insert(state.group.dirtyUpdates, state)
			end
		elseif renderProperties[property] then
			metadataDirty = true
		end
	end)

	local function getRenderableMesh(object, props, material)
		local mesh = props._mesh
			or (props.MeshObject and (props.MeshObject._mesh or props.MeshObject._meshgenHandle))
		if mesh and mesh._handle then
			return mesh
		end
		return getMeshForShape(props.Shape, material)
	end

	local function getRenderScale(props)
		local meshScale = tonumber(props.MeshScale) or 1
		if props._meshUsesPartSize == false then
			return Vector3.new(meshScale, meshScale, meshScale)
		end
		local size = props.Size
		if props.ClassName == "MeshPart" and meshScale ~= 1 then
			return Vector3.new(size.X * meshScale, size.Y * meshScale, size.Z * meshScale)
		end
		return size
	end

	local function updateSpatialState(state, props)
		local position = props.CFrame and props.CFrame.Position
		local size = getRenderScale(props)
		if not position or not size then
			return
		end
		local radius = 0.5 * math.sqrt(size.X * size.X + size.Y * size.Y + size.Z * size.Z)
		state.bounds = {
			id = state.spatialId,
			position = position,
			size = Vector3.new(radius, radius, radius),
			data = state,
		}
		spatialIndex:Remove(state.spatialId)
		if spatialIndex:Insert(state.bounds) then
			spatialOverflow[state] = nil
		else
			spatialOverflow[state] = true
		end
	end

	local function updateDrawCallTransform(drawCall, props)
		drawCall.matrix = nil
		drawCall.cframe = props.CFrame
		drawCall.scale = getRenderScale(props)
	end

	local function getPartShader(object)
		for _, child in ipairs(object:GetChildren()) do
			if child.ClassName == "MaterialShader" and child.Enabled ~= false and child._shaderHandle then
				return child._shaderHandle
			end
		end
		return nil
	end

	local function destroyDynamicGroups()
		for _, group in pairs(dynamicGroups) do
			if group.batch then
				renderer.MeshPool.DestroyInstanceBatch(group.batch)
			end
		end
		table.clear(dynamicGroups)
		table.clear(dynamicPartState)
		spatialIndex:Clear()
		table.clear(spatialOverflow)
		nextSpatialId = 0
	end

	local function fillDrawCall(drawCall, object, props)
		local size = props.Size
		local material = props.Material
		local isGlass = material == Enum.Material.Glass
		drawCall.texture = props._meshTexture or materialTextures[material]
		drawCall.MaterialKind = getMaterialKind(material)
		drawCall.shader = getPartShader(object)
		if isGlass then
			drawCall.roughness = math.clamp((props.Roughness or 0.5) * 0.2, 0.02, 0.18)
			drawCall.metallic = 1.52
			drawCall.MaterialTileScale = math.max(0.05, math.min(size.X, size.Y, size.Z) * 0.5)
			-- Glass opacity is controlled by the BasePart exactly like every
			-- other material; do not impose an independent transmission floor.
			drawCall.transmission = math.clamp(props.Transparency or 0, 0, 1)
		else
			drawCall.MaterialTileScale = math.max(1, math.max(size.X, size.Y, size.Z) / 4)
			drawCall.metallic = props.Metallic
			drawCall.roughness = props.Roughness
			drawCall.transmission = 0
		end
		drawCall.mesh = getRenderableMesh(object, props, material)
		updateDrawCallTransform(drawCall, props)
		drawCall.color = props.Color
		drawCall.transparency = props.Transparency
		-- Filament's depth-only shadow pass treats transmissive solids as opaque.
		-- Avoid the solid black shadow until transparent shadows are supported.
		drawCall.CastShadow = props.CastShadow and not isGlass
		drawCall.RecieveShadow = true
		drawCall.Culling = true
	end

	local function getRenderKey(object, props)
		local color = props.Color
		local material = props.Material
		local isGlass = material == Enum.Material.Glass
		local size = props.Size
		local texture = props._meshTexture or materialTextures[material]
		local mesh = getRenderableMesh(object, props, material)
		local shader = getPartShader(object)
		local materialParam3 = if isGlass
			then math.max(0.05, math.min(size.X, size.Y, size.Z) * 0.5)
			else math.max(1, math.max(size.X, size.Y, size.Z) / 4)
		return table.concat({
			tostring(mesh),
			tostring(shader),
			tostring(texture),
			tostring(getMaterialKind(material)),
			tostring(color.R),
			tostring(color.G),
			tostring(color.B),
			tostring(props.Transparency),
			tostring(props.Metallic),
			tostring(props.Roughness),
			tostring(props.CastShadow),
			tostring(materialParam3),
		}, "|")
	end

	local function rebuildDynamicGroups()
		destroyDynamicGroups()

		for _, object in pairs(renderParts) do
			local props = rawget(object, "_props")
			if not props or (tonumber(props.Transparency) or 0) >= 1 then
				continue
			end

			local key = getRenderKey(object, props)
			local group = dynamicGroups[key]
			if not group then
				group = {
					drawCalls = {},
					parts = {},
					dirtyUpdates = {},
				}
				dynamicGroups[key] = group
			end

			local drawCall = {}
			fillDrawCall(drawCall, object, props)
			table.insert(group.drawCalls, drawCall)
			table.insert(group.parts, object)
			nextSpatialId += 1
			local state = {
				group = group,
				object = object,
				index = #group.parts - 1,
				spatialId = nextSpatialId,
				dirty = false,
			}
			dynamicPartState[object] = state
			updateSpatialState(state, props)
		end

		for _, group in pairs(dynamicGroups) do
			group.batch = renderer.MeshPool.CreateInstanceBatch(group.drawCalls, #group.drawCalls)
		end

		metadataDirty = false
	end

	local function buildFrameFrustum(): Frustum.Frustum?
		local ok, cam = pcall(function()
			return renderer:GetActiveCamera()
		end)
		if not ok or cam == nil then
			return nil
		end
		local cfOk, cf = pcall(function()
			return cam.CFrame
		end)
		if not cfOk or cf == nil then
			return nil
		end
		local fov = 70
		local fovOk, fovValue = pcall(function()
			return cam.FieldOfView
		end)
		if fovOk and type(fovValue) == "number" and fovValue > 0 then
			fov = fovValue
		end
		local width = tonumber(renderer.Width) or 16
		local height = tonumber(renderer.Height) or 9
		local aspect = if height > 0 then width / height else 16 / 9
		return Frustum.fromCFrame(cf, fov, aspect, 0.1, 10000)
	end

	local function flushTransformUpdates()
		for _, group in pairs(dynamicGroups) do
			local updates = group.dirtyUpdates
			if group.batch and #updates > 0 then
				for i = 1, #updates do
					local state = updates[i]
					local props = rawget(state.object, "_props")
					if props then
						state.matrix = nil
						state.cframe = props.CFrame
						state.scale = getRenderScale(props)
						updateSpatialState(state, props)
					end
				end
				renderer.MeshPool.UpdateInstanceTransforms(group.batch, updates, #updates)
				for i = 1, #updates do
					local state = updates[i]
					state.dirty = false
					state.cframe = nil
					state.scale = nil
				end
				table.clear(updates)
			end
		end
	end

	local function updateBatchVisibility()
		local visibleByGroup = {}
		local totalParts = 0
		for _, group in pairs(dynamicGroups) do
			visibleByGroup[group] = {}
			totalParts += #group.parts
		end

		local candidates = {}
		if frameFrustum then
			candidates = spatialIndex:QueryAABB(frameFrustum.boundsCenter, frameFrustum.boundsHalfSize)
			for state in pairs(spatialOverflow) do
				table.insert(candidates, state.bounds)
			end
		else
			for _, state in pairs(dynamicPartState) do
				table.insert(candidates, state.bounds)
			end
		end

		local visibleParts = 0
		for _, bounds in ipairs(candidates) do
			local state = bounds.data
			if state and (not frameFrustum or Frustum.TestAABB(frameFrustum, bounds.position, bounds.size)) then
				table.insert(visibleByGroup[state.group], state.index)
				visibleParts += 1
			end
		end

		cullStats.testedGroups = 0
		cullStats.culledGroups = 0
		for group, indices in pairs(visibleByGroup) do
			cullStats.testedGroups += 1
			if #indices == 0 then
				cullStats.culledGroups += 1
			end
			if group.batch and renderer.MeshPool.SetInstanceBatchVisibility then
				renderer.MeshPool.SetInstanceBatchVisibility(group.batch, indices, #indices)
			end
		end
		cullStats.testedParts = #candidates
		cullStats.visibleParts = visibleParts
		cullStats.culledParts = totalParts - visibleParts
	end

	renderer.Hook.new("Renderstep", function()
		if metadataDirty then
			rebuildDynamicGroups()
		end
		frameFrustum = buildFrameFrustum()
		flushTransformUpdates()
		updateBatchVisibility()
	end)

	renderer.Hook.new("Shutdown", function()
		destroyDynamicGroups()
		descendantAdded:Disconnect()
		descendantRemoving:Disconnect()
		descendantChanged:Disconnect()
	end)

	Workspace.GetFrustumCullStats = function()
		return {
			testedGroups = cullStats.testedGroups,
			culledGroups = cullStats.culledGroups,
			testedParts = cullStats.testedParts,
			visibleParts = cullStats.visibleParts,
			culledParts = cullStats.culledParts,
		}
	end
end

return Workspace
