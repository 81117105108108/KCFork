--!strict
--!optimize 2

-- Frustum: 6-plane camera frustum for spatial culling before batch submission.
-- Planes use inward-facing normals; a point p is inside iff dot(n, p) + d >= 0
-- for every plane. Construct from a camera basis (no matrices needed) so both
-- headless and filament/SDL3 renderers can share it.

local Vector3 = require("@Vector3")

export type Plane = {
	nx: number,
	ny: number,
	nz: number,
	d: number,
}

export type Frustum = {
	planes: { Plane },
	boundsCenter: Vector3,
	boundsHalfSize: Vector3,
}

local Frustum = {}

local function makePlane(nx: number, ny: number, nz: number, d: number): Plane
	return { nx = nx, ny = ny, nz = nz, d = d }
end

-- Build from an orthonormal-ish camera basis. fwd/right/up need not be unit;
-- they are normalized here. near/far must be positive distances.
function Frustum.fromBasis(
	pos: Vector3,
	fwd: Vector3,
	up: Vector3,
	right: Vector3,
	fovYDeg: number,
	aspect: number,
	near: number,
	far: number
): Frustum
	local f = fwd:Unit()
	local r = right:Unit()
	local u = up:Unit()
	local n = math.max(near, 0.01)
	local fa = math.max(far, n + 0.01)
	local tanH = math.tan(math.rad(math.clamp(fovYDeg, 1, 179) * 0.5))
	local tanW = tanH * math.max(aspect, 0.01)

	local nearC = pos + f * n
	local farC = pos + f * fa

	local planes: { Plane } = {}
	-- Near / far.
	planes[1] = makePlane(f.X, f.Y, f.Z, -(f:Dot(nearC)))
	local nf = f * -1
	planes[2] = makePlane(nf.X, nf.Y, nf.Z, f:Dot(farC))
	-- Sides pass through the camera position: d = -(n . pos).
	local function sidePlane(edgeDir: Vector3, tangent: Vector3): Plane
		local normal = edgeDir:Cross(tangent):Unit()
		return makePlane(normal.X, normal.Y, normal.Z, -(normal:Dot(pos)))
	end
	-- Right: edge through near-plane right midpoint, tangent = up.
	local eR = (f * n + r * (n * tanW)):Unit()
	planes[3] = sidePlane(u, eR) -- cross(up, eR) points inward (-x)
	-- Left: tangent = up, flipped order so the normal points inward (+x).
	local eL = (f * n - r * (n * tanW)):Unit()
	planes[4] = sidePlane(eL, u) -- cross(eL, up) points inward (+x)
	-- Top: tangent = right, normal points inward (-y).
	local eT = (f * n + u * (n * tanH)):Unit()
	planes[5] = sidePlane(eT, r) -- cross(eT, right) points inward (-y)
	-- Bottom: flipped order, normal points inward (+y).
	local eB = (f * n - u * (n * tanH)):Unit()
	planes[6] = sidePlane(r, eB) -- cross(right, eB) points inward (+y)

	local corners = {}
	for _, distance in { n, fa } do
		local center = pos + f * distance
		local halfWidth = distance * tanW
		local halfHeight = distance * tanH
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				table.insert(corners, center + r * (halfWidth * x) + u * (halfHeight * y))
			end
		end
	end
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, corner in corners do
		minX, minY, minZ = math.min(minX, corner.X), math.min(minY, corner.Y), math.min(minZ, corner.Z)
		maxX, maxY, maxZ = math.max(maxX, corner.X), math.max(maxY, corner.Y), math.max(maxZ, corner.Z)
	end

	return {
		planes = planes,
		boundsCenter = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5),
		boundsHalfSize = Vector3.new((maxX - minX) * 0.5, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5),
	}
end

-- Convenience wrapper around a camera CFrame (Position + GetLook/Right/UpVector).
-- Returns nil when the CFrame does not expose the expected API.
function Frustum.fromCFrame(camCF: any, fovYDeg: number, aspect: number, near: number, far: number): Frustum?
	local ok, result = pcall(function()
		return Frustum.fromBasis(
			camCF.Position,
			camCF:GetLookVector(),
			camCF:GetUpVector(),
			camCF:GetRightVector(),
			fovYDeg,
			aspect,
			near,
			far
		)
	end)
	if ok then
		return result
	end
	return nil
end

-- AABB test: center + halfSize (half extents). True when intersecting or inside.
function Frustum.TestAABB(f: Frustum, center: Vector3, halfSize: Vector3): boolean
	local cx, cy, cz = center.X, center.Y, center.Z
	local hx, hy, hz = halfSize.X, halfSize.Y, halfSize.Z
	for i = 1, #f.planes do
		local p = f.planes[i]
		local dist = p.nx * cx + p.ny * cy + p.nz * cz + p.d
		local rad = hx * math.abs(p.nx) + hy * math.abs(p.ny) + hz * math.abs(p.nz)
		if dist < -rad then
			return false
		end
	end
	return true
end

-- Sphere test for point lights / bounds without extents.
function Frustum.TestSphere(f: Frustum, center: Vector3, radius: number): boolean
	for i = 1, #f.planes do
		local p = f.planes[i]
		if p.nx * center.X + p.ny * center.Y + p.nz * center.Z + p.d < -radius then
			return false
		end
	end
	return true
end

return Frustum
