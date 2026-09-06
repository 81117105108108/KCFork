local Vector3 = {
	__type = "Vector3",
}

Vector3.new = vector.create

Vector3.zero = vector.zero
Vector3.one = vector.one

function Vector3.Magnitude(v)
	return vector.magnitude(v)
end

function Vector3.MagnitudeSquared(v)
	return vector.dot(v, v)
end

function Vector3.Unit(v)
	local magnitude = vector.magnitude(v)

	if magnitude == 0 then
		return vector.zero
	end

	return vector.normalize(v)
end

function Vector3.Dot(a, b)
	return vector.dot(a, b)
end

function Vector3.Cross(a, b)
	return vector.cross(a, b)
end

function Vector3.Lerp(a, b, alpha)
	return a + (b - a) * alpha
end

function Vector3.Slerp(a, b, t)
	local v0 = Vector3.Unit(a)
	local v1 = Vector3.Unit(b)

	local dot = math.clamp(vector.dot(v0, v1), -1, 1)
	local theta = math.acos(dot)

	if theta < 1e-5 then
		return Vector3.Unit(Vector3.Lerp(v0, v1, t))
	end

	local sinTheta = math.sin(theta)

	if math.abs(sinTheta) < 1e-5 then
		return v0
	end

	local w0 = math.sin((1 - t) * theta) / sinTheta
	local w1 = math.sin(t * theta) / sinTheta

	return Vector3.Unit(v0 * w0 + v1 * w1)
end

function Vector3.Distance(a, b)
	return vector.magnitude(a - b)
end

function Vector3.DistanceSquared(a, b)
	local d = a - b
	return vector.dot(d, d)
end

function Vector3.ClampMagnitude(v, maxLength)
	local magnitudeSquared = vector.dot(v, v)
	local maxSquared = maxLength * maxLength

	if magnitudeSquared > maxSquared then
		return vector.normalize(v) * maxLength
	end

	return v
end

function Vector3.DirectionTo(a, b)
	local difference = b - a
	local magnitude = vector.magnitude(difference)

	if magnitude == 0 then
		return vector.zero
	end

	return vector.normalize(difference)
end

function Vector3.DirectionToLength(a, target, length)
	return Vector3.DirectionTo(a, target) * length
end

function Vector3.Angle(a, b)
	if vector.magnitude(a) == 0 or vector.magnitude(b) == 0 then
		return 0
	end

	return vector.angle(a, b)
end

function Vector3.Project(v, onto)
	local denominator = vector.dot(onto, onto)

	if denominator == 0 then
		return vector.zero
	end

	return onto * (vector.dot(v, onto) / denominator)
end

function Vector3.Reflect(v, normal)
	return v - normal * (2 * vector.dot(v, normal))
end

function Vector3.Abs(v)
	return vector.abs(v)
end

function Vector3.Min(a, b)
	return vector.min(a, b)
end

function Vector3.Max(a, b)
	return vector.max(a, b)
end

function Vector3.Round(v)
	return vector.create(math.round(v.X), math.round(v.Y), math.round(v.Z))
end

function Vector3.IsZero(v, epsilon)
	epsilon = epsilon or 1e-5

	return math.abs(v.X) < epsilon and math.abs(v.Y) < epsilon and math.abs(v.Z) < epsilon
end

function Vector3.Equals(a, b, epsilon)
	epsilon = epsilon or 1e-5

	local delta = vector.abs(a - b)

	return delta.X < epsilon and delta.Y < epsilon and delta.Z < epsilon
end

function Vector3.RotateByMatrix(v, matrix)
	return vector.create(
		v.X * matrix[1][1] + v.Y * matrix[1][2] + v.Z * matrix[1][3],
		v.X * matrix[2][1] + v.Y * matrix[2][2] + v.Z * matrix[2][3],
		v.X * matrix[3][1] + v.Y * matrix[3][2] + v.Z * matrix[3][3]
	)
end

function Vector3.RotationMatrix(axis, angle)
	axis = Vector3.Unit(axis)

	local c = math.cos(angle)
	local s = math.sin(angle)
	local t = 1 - c

	local x = axis.X
	local y = axis.Y
	local z = axis.Z

	return {
		{
			t * x * x + c,
			t * x * y - s * z,
			t * x * z + s * y,
		},
		{
			t * x * y + s * z,
			t * y * y + c,
			t * y * z - s * x,
		},
		{
			t * x * z - s * y,
			t * y * z + s * x,
			t * z * z + c,
		},
	}
end

function Vector3.LookAt(position, target, up)
	up = up or vector.create(0, 1, 0)

	local forward = Vector3.DirectionTo(position, target)
	local right = Vector3.Unit(vector.cross(up, forward))
	local realUp = vector.cross(forward, right)

	return {
		right = right,
		up = realUp,
		forward = forward,
	}
end

function Vector3.RotateEuler(v, pitch, yaw, roll)
	local cp, sp = math.cos(pitch), math.sin(pitch)
	local cy, sy = math.cos(yaw), math.sin(yaw)
	local cr, sr = math.cos(roll), math.sin(roll)

	return vector.create(
		v.X * (cy * cr + sy * sp * sr) + v.Y * (sr * cp) + v.Z * (-sy * cr + cy * sp * sr),
		v.X * (-cy * sr + sy * sp * cr) + v.Y * (cr * cp) + v.Z * (sr * sy + cy * sp * cr),
		v.X * (sy * cp) + v.Y * -sp + v.Z * (cy * cp)
	)
end

function Vector3.RotateAroundAxis(v, axis, angle)
	axis = Vector3.Unit(axis)

	local cosA = math.cos(angle)
	local sinA = math.sin(angle)
	local dot = vector.dot(v, axis)

	return v * cosA + vector.cross(axis, v) * sinA + axis * dot * (1 - cosA)
end

function Vector3.RotateTowards(v, target, maxAngle)
	local magnitude = vector.magnitude(v)

	if magnitude == 0 then
		return vector.zero
	end

	local current = vector.normalize(v)
	local targetMagnitude = vector.magnitude(target)

	if targetMagnitude == 0 then
		return vector.zero
	end

	local targetUnit = vector.normalize(target)
	local angle = vector.angle(current, targetUnit)

	if angle <= maxAngle then
		return targetUnit * magnitude
	end

	local axis = vector.cross(current, targetUnit)

	if vector.magnitude(axis) < 1e-5 then
		axis = vector.cross(Vector3.RandomUnit(), current)

		if vector.magnitude(axis) < 1e-5 then
			axis = vector.cross(vector.create(1, 0, 0), current)

			if vector.magnitude(axis) < 1e-5 then
				axis = vector.cross(vector.create(0, 1, 0), current)
			end
		end
	end

	return Vector3.RotateAroundAxis(v, axis, maxAngle)
end

function Vector3.ToEulerAngles(v)
	local pitch = math.atan2(v.Y, math.sqrt(v.X * v.X + v.Z * v.Z))

	local yaw = math.atan2(-v.X, -v.Z)

	return pitch, yaw, 0
end

function Vector3.RandomUnit()
	local theta = math.random() * 2 * math.pi
	local z = math.random() * 2 - 1
	local radius = math.sqrt(1 - z * z)

	return vector.create(radius * math.cos(theta), radius * math.sin(theta), z)
end

function Vector3.ToBuffer(v)
	local buf = buffer.create(12)

	buffer.writef32(buf, 0, v.X)
	buffer.writef32(buf, 4, v.Y)
	buffer.writef32(buf, 8, v.Z)

	return buf
end

function Vector3.ToZuneVector(v)
	return v
end

function Vector3.ToTable(v)
	return {
		type = "Vector3",
		__type = "Vector3",
		X = v.X,
		Y = v.Y,
		Z = v.Z,
	}
end

function Vector3.FromTable(tbl)
	assert(tbl.type == "Vector3" or tbl.__type == "Vector3", "Expected Vector3 table")

	return vector.create(tbl.X, tbl.Y, tbl.Z)
end

function Vector3.ToString(v)
	return string.format("Vector3(%g, %g, %g)", v.X, v.Y, v.Z)
end

return Vector3
