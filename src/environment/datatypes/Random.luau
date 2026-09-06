--!strict
local Vector3 = require("@Vector3")
local Random = {}
Random.__index = Random

local zrand = zune.random

function Random.new(seed: number?)
	local self = setmetatable({}, Random)
	self._rng = zrand.Pcg32.new(seed)
	return self
end

function Random:_next()
	return self._rng:nextNumber()
end

function Random:NextInteger(min: number, max: number): number
	return self._rng:nextInteger(min, max)
end

function Random:NextNumber(min: number?, max: number?): number
	if min == nil and max == nil then
		return self._rng:nextNumber()
	end

	return self._rng:nextNumber(min or 0, max or 1)
end

function Random:NextUnitVector()
	-- basic sphere method
	local x, y, z
	while true do
		x = self:NextNumber(-1, 1)
		y = self:NextNumber(-1, 1)
		z = self:NextNumber(-1, 1)
		local m = x * x + y * y + z * z
		if m > 0 and m <= 1 then
			local s = 1 / math.sqrt(m)
			return Vector3.new(x * s, y * s, z * s)
		end
	end
end

function Random:ToTable()
	return {
		type = "Random",
	}
end

function Random.FromTable(tbl)
	assert(tbl.type == "Random")
	return Random.new()
end

return Random
