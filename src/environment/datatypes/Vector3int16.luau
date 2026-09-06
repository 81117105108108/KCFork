local Vector3int16 = {}

local MIN_INT16 = -32768
local MAX_INT16 = 32767
local RANGE = 65536

local function clampInt16(value: number): number
	value = math.floor(value)

	if value >= MIN_INT16 and value <= MAX_INT16 then
		return value
	end

	return ((value - MIN_INT16) % RANGE) + MIN_INT16
end

local function wrap(v: vector): vector
	return vector.create(clampInt16(v.X), clampInt16(v.Y), clampInt16(v.Z))
end

function Vector3int16.new(x: number?, y: number?, z: number?): vector
	return vector.create(clampInt16(x or 0), clampInt16(y or 0), clampInt16(z or 0))
end

Vector3int16.zero = vector.zero

function Vector3int16.add(a: vector, b: vector): vector
	return wrap(a + b)
end

function Vector3int16.sub(a: vector, b: vector): vector
	return wrap(a - b)
end

function Vector3int16.neg(a: vector): vector
	return wrap(-a)
end

function Vector3int16.mul(a: vector | number, b: vector | number): vector
	if type(a) == "number" then
		return wrap((b :: vector) * a)
	elseif type(b) == "number" then
		return wrap((a :: vector) * b)
	else
		return wrap((a :: vector) * (b :: vector))
	end
end

function Vector3int16.div(a: vector, b: vector | number): vector
	return wrap(a / b)
end

function Vector3int16.Abs(v: vector): vector
	return wrap(vector.abs(v))
end

function Vector3int16.Dot(a: vector, b: vector): number
	return vector.dot(a, b)
end

function Vector3int16.Cross(a: vector, b: vector): vector
	return wrap(vector.cross(a, b))
end

function Vector3int16.Unit(v: vector): vector
	local magnitude = vector.magnitude(v)

	if magnitude == 0 then
		return vector.zero
	end

	return vector.normalize(v)
end

function Vector3int16:Magnitude(v: vector): number
	return vector.magnitude(v)
end

function Vector3int16:MagnitudeSquared(v: vector): number
	return vector.dot(v, v)
end

function Vector3int16.Min(a: vector, b: vector): vector
	return wrap(vector.create(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z)))
end

function Vector3int16.Max(a: vector, b: vector): vector
	return wrap(vector.create(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z)))
end

function Vector3int16.Lerp(a: vector, b: vector, alpha: number): vector
	return wrap(a + (b - a) * alpha)
end

function Vector3int16.Length(v: vector): number
	return vector.magnitude(v)
end

function Vector3int16.ToVector3(v: vector): vector
	return v
end

function Vector3int16.ToTable(v: vector): {
	type: string,
	X: number,
	Y: number,
	Z: number,
}
	return {
		type = "Vector3int16",
		X = v.X,
		Y = v.Y,
		Z = v.Z,
	}
end

function Vector3int16.FromTable(tbl: {
	type: string,
	X: number,
	Y: number,
	Z: number,
}): vector
	assert(tbl.type == "Vector3int16", "Table is not a Vector3int16")

	return Vector3int16.new(tbl.X, tbl.Y, tbl.Z)
end

export type Vector3int16 = vector

return Vector3int16
