-- Converts render/editable mesh data into the indexed local-space geometry
-- used to construct Jolt collision shapes. This module intentionally has no
-- renderer or FFI dependency so its scaling/index behavior can be tested.

local CollisionGeometry = {}

local CUSTOM_CLASSES = {
	MeshPart = true,
	UnionOperation = true,
	IntersectOperation = true,
	NegateOperation = true,
}

local function xyz(value)
	if type(value) ~= "table" then
		return nil
	end
	if value.X ~= nil then
		return value.X, value.Y, value.Z
	end
	if value.x ~= nil then
		return value.x, value.y, value.z
	end
	return value[1], value[2], value[3]
end

local function geometryScale(part)
	local meshScale = tonumber(part.MeshScale) or 1
	local collisionScale = tonumber(part.CollisionScale) or 1
	local uniformScale = meshScale * collisionScale

	if part._meshUsesPartSize == false then
		return uniformScale, uniformScale, uniformScale
	end

	local size = part.Size
	if not size then
		return uniformScale, uniformScale, uniformScale
	end
	return size.X * uniformScale, size.Y * uniformScale, size.Z * uniformScale
end

local function scaledPoint(value, sx, sy, sz)
	local x, y, z = xyz(value)
	if x == nil or y == nil or z == nil then
		return nil
	end
	return { x * sx, y * sy, z * sz }
end

local function appendTriangle(triangles, i0, i1, i2, pointCount)
	if
		type(i0) ~= "number"
		or type(i1) ~= "number"
		or type(i2) ~= "number"
		or i0 < 0
		or i1 < 0
		or i2 < 0
		or i0 >= pointCount
		or i1 >= pointCount
		or i2 >= pointCount
		or i0 == i1
		or i1 == i2
		or i0 == i2
	then
		return
	end
	table.insert(triangles, { i0, i1, i2 })
end

local function fromCpuMeshData(meshData, sx, sy, sz)
	if type(meshData) ~= "table" or meshData.released or type(meshData.vertices) ~= "table" then
		return nil
	end

	local points = {}
	for _, vertex in ipairs(meshData.vertices) do
		local point = scaledPoint(vertex.position or vertex.pos or vertex[1] or vertex, sx, sy, sz)
		if not point then
			return nil
		end
		table.insert(points, point)
	end
	if #points < 3 then
		return nil
	end

	local indices = meshData.indices
	if type(indices) ~= "table" or #indices == 0 then
		indices = table.create(#points)
		for index = 1, #points do
			indices[index] = index - 1
		end
	end

	local triangles = {}
	for index = 1, #indices - 2, 3 do
		appendTriangle(triangles, indices[index], indices[index + 1], indices[index + 2], #points)
	end
	if #triangles == 0 then
		return nil
	end
	return points, triangles, "cpu"
end

local function fromEditableMesh(mesh, sx, sy, sz)
	if type(mesh) ~= "table" or type(mesh._vertices) ~= "table" or type(mesh._faces) ~= "table" then
		return nil
	end

	local vertexIds = {}
	for id in pairs(mesh._vertices) do
		table.insert(vertexIds, id)
	end
	table.sort(vertexIds)
	if #vertexIds < 3 then
		return nil
	end

	local points = {}
	local vertexIndex = {}
	for _, vertexId in ipairs(vertexIds) do
		local point = scaledPoint(mesh._vertices[vertexId], sx, sy, sz)
		if not point then
			return nil
		end
		vertexIndex[vertexId] = #points
		table.insert(points, point)
	end

	local triangles = {}
	for _, face in pairs(mesh._faces) do
		local i0 = vertexIndex[face[1]]
		local i1 = vertexIndex[face[2]]
		local i2 = vertexIndex[face[3]]
		if i0 ~= nil and i1 ~= nil and i2 ~= nil then
			appendTriangle(triangles, i0, i1, i2, #points)
		end
	end
	if #triangles == 0 then
		return nil
	end
	return points, triangles, "editable"
end

function CollisionGeometry.IsCustomPart(part)
	return part ~= nil and CUSTOM_CLASSES[part.ClassName] == true
end

function CollisionGeometry.Get(part)
	if not CollisionGeometry.IsCustomPart(part) then
		return nil
	end

	local sx, sy, sz = geometryScale(part)
	local points, triangles, source = fromCpuMeshData(part._cpuMeshData, sx, sy, sz)
	if points then
		return points, triangles, source
	end

	local mesh = part.MeshObject
	if mesh and (mesh.ClassName == "EditableMesh" or mesh.class == "EditableMesh") then
		return fromEditableMesh(mesh, sx, sy, sz)
	end
	return nil
end

-- Triangle meshes preserve concavity for non-dynamic bodies. Jolt does not
-- permit a triangle mesh as a dynamic shape, so moving custom parts use their
-- real vertex cloud as a convex hull instead of silently becoming a box.
function CollisionGeometry.ChooseShapeKind(part, motionType, collisionFidelity)
	local fidelityName = type(collisionFidelity) == "table" and collisionFidelity.Name or collisionFidelity
	local fidelityValue = type(collisionFidelity) == "table" and collisionFidelity.Value or collisionFidelity
	if fidelityName == "Box" or fidelityValue == 2 then
		return "primitive"
	end
	if fidelityName == "Hull" or fidelityValue == 1 or motionType == 2 then
		return "hull"
	end
	return "mesh"
end

return CollisionGeometry
