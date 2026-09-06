--!strict

local Octree = require("../src/environment/datatypes/Octree")
local Frustum = require("../src/environment/datatypes/Frustum")
local Vector3 = require("../src/environment/datatypes/Vector3")

local tree = Octree.new(Vector3.new(0, 0, 0), 1048576, 32, 8, 1.5)
for id = 1, 5000 do
	local x = ((id - 1) % 100) - 50
	local y = math.floor((id - 1) / 100) % 50 - 25
	assert(tree:Insert({
		id = id,
		position = Vector3.new(x, y, -100),
		size = Vector3.new(0.5, 0.5, 0.5),
	}))
end

local frustum = Frustum.fromBasis(
	Vector3.new(),
	Vector3.new(0, 0, -1),
	Vector3.new(0, 1, 0),
	Vector3.new(1, 0, 0),
	90,
	16 / 9,
	0.1,
	1000
)
local start = os.clock()
local visible = 0
for _ = 1, 100 do
	visible = 0
	for _, bounds in tree:QueryAABB(frustum.boundsCenter, frustum.boundsHalfSize) do
		if Frustum.TestAABB(frustum, bounds.position, bounds.size) then
			visible += 1
		end
	end
end
local millisecondsPerFrame = (os.clock() - start) * 10
assert(visible == 5000, `expected 5000 visible parts, got {visible}`)
assert(millisecondsPerFrame < 1000 / 60, `culling exceeded 60 Hz CPU budget: {millisecondsPerFrame} ms`)
print(string.format("DONE phase 2 benchmark: 5000 parts, %.3f ms/frame", millisecondsPerFrame))
