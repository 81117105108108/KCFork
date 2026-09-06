local ffi = zune.ffi
local funcs = require("./miniaudio/funcs")
local zembed = require("@zembed")

local libraryName = "KinemiumLibs." .. ffi.suffix
local function libraryPath()
	if zembed.IsEmbedded() then
		return zembed.RuntimePath(libraryName)
	end
	for _, path in ipairs({ "./vendor/" .. libraryName, "../vendor/" .. libraryName, "./" .. libraryName }) do
		local ok, stat = pcall(zune.fs.stat, path)
		if ok and stat.kind == "file" then
			return path
		end
	end
	return "./vendor/" .. libraryName
end

local lib = ffi.dlopen(libraryPath(), funcs)

return {
	lib = lib,
	LoadSound = function(path, stream)
		local bytes = buffer.fromstring(path .. "\0")
		local pointer = ffi.alloc(buffer.len(bytes))
		pointer:write(0, bytes, 0, buffer.len(bytes))
		local sound = lib.Kine_Audio_LoadSound(pointer, stream and 1 or 0)
		ffi.free(pointer)
		return sound
	end,
	IsNull = function(pointer)
		return not pointer or pointer == ffi.null
	end,
}
