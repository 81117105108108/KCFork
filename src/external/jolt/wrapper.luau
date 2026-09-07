local ffi = zune.ffi

local zembed = require("@zembed")

local structs = require("./structs")
local funcs = require("./funcs")

local libname = "KinemiumLibs." .. ffi.suffix

local function getLibraryPath(): string
	if zembed.IsEmbedded() then
		return zembed.RuntimePath(libname)
	end

	local paths = {
		"./vendor/" .. libname,
		"../vendor/" .. libname,
		"./" .. libname,
	}

	for _, path in paths do
		local ok, stat = pcall(zune.fs.stat, path)
		if ok and stat.kind == "file" then
			return path
		end
	end

	return paths[1]
end

local path = getLibraryPath()
local ok, jolt = pcall(ffi.dlopen, path, funcs)
if not ok then
	-- Zune resolves eagerly. Retry without only the optional Phase 1 symbol;
	-- missing required symbols still fail instead of masking a broken library.
	local required = table.clone(funcs)
	required.JPH_BodyInterface_GetBulkTransforms = nil
	jolt = ffi.dlopen(path, required)
end

return {
	lib = jolt,
	structs = structs,
}
