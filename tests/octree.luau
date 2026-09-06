--!strict

local Octree = require("../src/environment/datatypes/Octree")
local Vector3 = require("../src/environment/datatypes/Vector3")

local tree = Octree.new(Vector3.new(0, 0, 0), 16, 1, 4, 1.5)
assert(tree:Insert({ id = 1, position = Vector3.new(0, 0, 0), size = Vector3.new(1, 1, 1) }))
assert(tree:Insert({ id = 2, position = Vector3.new(14, 4, 4), size = Vector3.new(1, 1, 1) }))

local looseHit = tree:QueryAABB(Vector3.new(14.5, 4, 4), Vector3.new(0.1, 0.1, 0.1))
assert(#looseHit == 1 and looseHit[1].id == 2, "query must traverse loose child bounds")

tree:Update({ id = 2, position = Vector3.new(-8, 0, 0), size = Vector3.new(1, 1, 1) })
assert(#tree:QueryAABB(Vector3.new(14, 4, 4), Vector3.new(2, 2, 2)) == 0, "update must remove old bounds")
assert(#tree:QueryAABB(Vector3.new(-8, 0, 0), Vector3.new(1, 1, 1)) == 1, "update must insert new bounds")

tree:Remove(2)
assert(#tree:QueryAABB(Vector3.new(-8, 0, 0), Vector3.new(1, 1, 1)) == 0, "remove must erase object")
assert(not tree:Insert({ id = 3, position = Vector3.new(100, 0, 0), size = Vector3.new(1, 1, 1) }), "out-of-root insert must fail")

print("DONE octree tests passed=6")
