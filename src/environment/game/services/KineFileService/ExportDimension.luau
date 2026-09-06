local ExportDimension = {}

local function normalize(value)
	if type(value) == "table" then
		value = value.Name or value.Value
	end
	value = string.upper(tostring(value or ""))
	return if value == "2D" or value == "2" then "2D" else "3D"
end

function ExportDimension.Resolve(options, datamodel, renderer)
	options = options or {}
	local requested = options.Dimension or options.dimension
	if requested ~= nil then
		return normalize(requested)
	end

	if datamodel and datamodel.GetMetadata then
		local manifest = datamodel:GetMetadata("ProjectManif")
		if manifest and manifest.info and manifest.info.dimension ~= nil then
			return normalize(manifest.info.dimension)
		end
	end

	if renderer and renderer.Dimension ~= nil then
		return normalize(renderer.Dimension)
	end
	return "3D"
end

function ExportDimension.AddRuntimeFlags(flags, dimension, extraFlags)
	local present = {}
	for _, flag in ipairs(flags) do
		present[string.lower(tostring(flag))] = true
	end
	if normalize(dimension) == "2D" and not present["2d"] then
		table.insert(flags, "2d")
		present["2d"] = true
	end
	for _, flag in ipairs(extraFlags or {}) do
		local key = string.lower(tostring(flag))
		if not present[key] then
			table.insert(flags, flag)
			present[key] = true
		end
	end
	return flags
end

ExportDimension.Normalize = normalize

return ExportDimension
