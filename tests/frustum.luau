--!strict
-- tests/frustum.luau
-- Headless regression tests for the 6-plane camera frustum (spatial culling).

local Frustum = require("../src/environment/datatypes/Frustum")
local Vector3 = require("../src/environment/datatypes/Vector3")

local passed = 0
local function test(name: string, callback: () -> ()): ()
	callback()
	passed += 1
	print("PASS\t" .. name)
end

local function makeFrustum(): Frustum.Frustum
	return Frustum.fromBasis(
		Vector3.new(0, 0, 0),
		Vector3.new(0, 0, -1),
		Vector3.new(0, 1, 0),
		Vector3.new(1, 0, 0),
		90,
		1,
		0.1,
		100
	)
end

test("AABB directly ahead is visible", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(0, 0, -10), Vector3.new(1, 1, 1)) == true, "ahead box must be visible")
end)

test("AABB behind the camera is culled", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(0, 0, 10), Vector3.new(1, 1, 1)) == false, "behind box must be culled")
end)

test("AABB far outside the right edge is culled", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(50, 0, -10), Vector3.new(1, 1, 1)) == false, "far-right box must be culled")
end)

test("AABB beyond the far plane is culled", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(0, 0, -200), Vector3.new(1, 1, 1)) == false, "beyond-far box must be culled")
end)

test("AABB in front of the near plane is culled", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(0, 0, -0.05), Vector3.new(0.01, 0.01, 0.01)) == false, "pre-near box must be culled")
end)

test("huge AABB straddling the camera stays visible", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(0, 0, -50), Vector3.new(100, 100, 100)) == true, "straddling box must be visible")
end)

test("AABB grazing the right plane stays visible", function()
	local f = makeFrustum()
	assert(Frustum.TestAABB(f, Vector3.new(9.9, 0, -10), Vector3.new(0.5, 0.5, 0.5)) == true, "grazing box must be visible")
end)

test("sphere behind the camera is culled, sphere ahead is visible", function()
	local f = makeFrustum()
	assert(Frustum.TestSphere(f, Vector3.new(0, 0, 5), 1) == false, "behind sphere must be culled")
	assert(Frustum.TestSphere(f, Vector3.new(0, 0, -5), 1) == true, "ahead sphere must be visible")
end)

test("fromCFrame rejects malformed input without throwing", function()
	assert(Frustum.fromCFrame(nil, 70, 16 / 9, 0.1, 1000) == nil, "nil CFrame must yield nil")
	assert(Frustum.fromCFrame({}, 70, 16 / 9, 0.1, 1000) == nil, "empty table must yield nil")
end)

test("frustum exposes a conservative broad-phase AABB", function()
	local f = makeFrustum()
	assert(f.boundsCenter.Z < 0, "bounds must extend forward")
	assert(f.boundsHalfSize.X >= 99.9 and f.boundsHalfSize.Y >= 99.9, "bounds must include far-plane corners")
	assert(Frustum.TestAABB(f, f.boundsCenter, f.boundsHalfSize), "frustum must intersect its own bounds")
end)

print(`DONE frustum tests passed={passed}`)
