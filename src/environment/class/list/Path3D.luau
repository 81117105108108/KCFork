-- description: "A sampled 3D path made from ControlPoint children."
local CFrame = require("@CFrame")
local Enum = require("@EnumMap")
local Vector3 = require("@Vector3")

local EPSILON = 1e-7

local propTable = {
	Name = "Path3D",
	BaseClass = "Instance",
	CurveType = Enum.Path3DMode.CatmullRom,
	Closed = false,
	LengthSamples = 32,
	ClosestPointSamples = 64,
	UpVector = Vector3.new(0, 1, 0),
}

local function curveName(value)
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		return value.Name or tostring(value.Value)
	end
	return tostring(value)
end

local function getPoints(instance)
	local points = {}
	for childIndex, child in ipairs(instance:GetChildren()) do
		if child.ClassName == "ControlPoint" then
			table.insert(points, { point = child, childIndex = childIndex })
		end
	end
	table.sort(points, function(a, b)
		local aOrder = tonumber(a.point.Order) or 0
		local bOrder = tonumber(b.point.Order) or 0
		if aOrder == bOrder then
			return a.childIndex < b.childIndex
		end
		return aOrder < bOrder
	end)
	for index, entry in ipairs(points) do
		points[index] = entry.point
	end
	return points
end

local function segmentCount(points, closed)
	if #points < 2 then
		return 0
	end
	return closed and #points or (#points - 1)
end

local function pointAt(points, index, closed)
	local count = #points
	if closed then
		return points[((index - 1) % count) + 1]
	end
	return points[math.clamp(index, 1, count)]
end

local function splitT(t, segments)
	t = math.clamp(tonumber(t) or 0, 0, 1)
	if t >= 1 then
		return segments, 1
	end
	local scaled = t * segments
	local zeroBased = math.floor(scaled)
	return zeroBased + 1, scaled - zeroBased
end

local function evaluateSegment(points, segment, u, mode, closed)
	local p0Object = pointAt(points, segment, closed)
	local p1Object = pointAt(points, segment + 1, closed)
	local p0 = p0Object.Position
	local p1 = p1Object.Position

	if mode == "Linear" then
		return p0:Lerp(p1, u), p1 - p0
	elseif mode == "Bezier" then
		local c0 = p0 + p0Object.TangentOut
		local c1 = p1 + p1Object.TangentIn
		local inverse = 1 - u
		local position = p0 * (inverse ^ 3)
			+ c0 * (3 * inverse * inverse * u)
			+ c1 * (3 * inverse * u * u)
			+ p1 * (u ^ 3)
		local tangent = (c0 - p0) * (3 * inverse * inverse)
			+ (c1 - c0) * (6 * inverse * u)
			+ (p1 - c1) * (3 * u * u)
		return position, tangent
	elseif mode == "Hermite" then
		local t0 = p0Object.TangentOut
		local t1 = p1Object.TangentIn
		local u2, u3 = u * u, u * u * u
		local position = p0 * (2 * u3 - 3 * u2 + 1)
			+ t0 * (u3 - 2 * u2 + u)
			+ p1 * (-2 * u3 + 3 * u2)
			+ t1 * (u3 - u2)
		local tangent = p0 * (6 * u2 - 6 * u)
			+ t0 * (3 * u2 - 4 * u + 1)
			+ p1 * (-6 * u2 + 6 * u)
			+ t1 * (3 * u2 - 2 * u)
		return position, tangent
	end

	-- Uniform Catmull-Rom. Endpoints are repeated for open paths.
	local before = pointAt(points, segment - 1, closed).Position
	local after = pointAt(points, segment + 2, closed).Position
	local u2, u3 = u * u, u * u * u
	local position = (p0 * 2
		+ (p1 - before) * u
		+ (before * 2 - p0 * 5 + p1 * 4 - after) * u2
		+ (-before + p0 * 3 - p1 * 3 + after) * u3)
		* 0.5
	local tangent = ((p1 - before)
		+ (before * 2 - p0 * 5 + p1 * 4 - after) * (2 * u)
		+ (-before + p0 * 3 - p1 * 3 + after) * (3 * u2))
		* 0.5
	return position, tangent
end

local function evaluate(instance, t, knownPoints)
	local points = knownPoints or getPoints(instance)
	if #points == 0 then
		return Vector3.new(0, 0, 0), Vector3.new(0, 0, -1)
	elseif #points == 1 then
		return points[1].Position, Vector3.new(0, 0, -1)
	end

	local segments = segmentCount(points, instance.Closed == true)
	local segment, u = splitT(t, segments)
	return evaluateSegment(points, segment, u, curveName(instance.CurveType), instance.Closed == true)
end

return {
	class = "Path3D",

	callback = function(instance)
		instance:SetProperties(propTable)

		function instance:GetPosition(t)
			local position = evaluate(self, t)
			return position
		end

		function instance:GetCFrame(t)
			local position, tangent = evaluate(self, t)
			if tangent:MagnitudeSquared() <= EPSILON then
				local offset = 1 / math.max(64, tonumber(self.LengthSamples) or 32)
				local before = self:GetPosition(math.max(0, (tonumber(t) or 0) - offset))
				local after = self:GetPosition(math.min(1, (tonumber(t) or 0) + offset))
				tangent = after - before
			end
			if tangent:MagnitudeSquared() <= EPSILON then
				tangent = Vector3.new(0, 0, -1)
			end
			return CFrame.lookAt(position, position + tangent, self.UpVector)
		end

		function instance:GetLength()
			local points = getPoints(self)
			local segments = segmentCount(points, self.Closed == true)
			if segments == 0 then
				return 0
		end
			local samplesPerSegment = math.max(2, math.floor(tonumber(self.LengthSamples) or 32))
			local samples = segments * samplesPerSegment
			local length = 0
			local previous = evaluate(self, 0, points)
			for index = 1, samples do
				local current = evaluate(self, index / samples, points)
				length += (current - previous):Magnitude()
				previous = current
			end
			return length
		end

		function instance:GetClosestPoint(position)
			assert(position and position.X and position.Y and position.Z, "Path3D:GetClosestPoint expects a Vector3")
			local points = getPoints(self)
			local segments = segmentCount(points, self.Closed == true)
			if segments == 0 then
				local closest = evaluate(self, 0, points)
				return closest, 0, (closest - position):Magnitude()
			end

			local sampleCount = segments * math.max(4, math.floor(tonumber(self.ClosestPointSamples) or 64))
			local bestT, bestPosition, bestDistanceSquared = 0, evaluate(self, 0, points), math.huge
			for index = 0, sampleCount do
				local candidateT = index / sampleCount
				local candidate = evaluate(self, candidateT, points)
				local distanceSquared = (candidate - position):MagnitudeSquared()
				if distanceSquared < bestDistanceSquared then
					bestT, bestPosition, bestDistanceSquared = candidateT, candidate, distanceSquared
				end
			end

			-- Refine the best sampled interval with ternary search.
			local step = 1 / sampleCount
			local left, right = math.max(0, bestT - step), math.min(1, bestT + step)
			for _ = 1, 12 do
				local a = left + (right - left) / 3
				local b = right - (right - left) / 3
				local distanceA = (evaluate(self, a, points) - position):MagnitudeSquared()
				local distanceB = (evaluate(self, b, points) - position):MagnitudeSquared()
				if distanceA <= distanceB then
					right = b
				else
					left = a
				end
			end
			bestT = (left + right) * 0.5
			bestPosition = evaluate(self, bestT, points)
			return bestPosition, bestT, (bestPosition - position):Magnitude()
		end

		return instance
	end,

	inherit = function()
		return propTable
	end,
}
