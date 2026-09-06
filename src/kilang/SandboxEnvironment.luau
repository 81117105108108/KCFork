--!strict
-- Global isolation only. Engine objects still require capability-safe proxies.
local SandboxEnvironment = {}
export type Environment = { [string]: unknown }

local host = getfenv()
local globals = {
	"assert", "error", "ipairs", "next", "pairs", "pcall", "print", "select",
	"tonumber", "tostring", "type", "typeof", "unpack", "warn", "xpcall",
	"rawequal", "rawlen", "setmetatable", "newproxy",
}
local libraries = { "math", "string", "table", "bit32", "utf8", "coroutine", "buffer", "vector" }
local forbidden = {
	"zune", "debug", "ffi", "fs", "io", "process", "net", "socket", "sockets",
	"load", "loadstring", "loadfile", "dofile", "getfenv", "setfenv", "getmetatable",
	"rawget", "rawset", "import", "include", "package", "_G", "_ENV",
}

function SandboxEnvironment.create(bindings: Environment): Environment
	local env: Environment = {}
	for _, name in globals do
		env[name] = host[name]
	end
	for name, value in bindings do
		env[name] = value
	end
	for _, name in forbidden do
		env[name] = nil
	end
	-- Never hand scripts the host's mutable library tables or OS capabilities.
	for _, name in libraries do
		local library = host[name]
		if type(library) == "table" then
			env[name] = table.freeze(table.clone(library))
		end
	end
	env.os = table.freeze({ clock = os.clock, date = os.date, time = os.time, difftime = os.difftime })
	local moduleRequire = bindings.require
	if type(moduleRequire) == "function" then
		env.require = function(target: unknown): unknown
			if type(target) ~= "table" then
				error("Sandbox require accepts ModuleScripts only; host module paths are forbidden", 2)
			end
			return moduleRequire(target)
		end
	else
		env.require = nil
	end
	-- No metatable fallback; globals written by one script remain in that script.
	return env
end

return SandboxEnvironment
