--!strict
local Sandbox = require("../src/kilang/SandboxEnvironment")
local function run(source: string, bindings: Sandbox.Environment?): unknown
	return zune.luau.load(zune.luau.compile(source), {
		env = Sandbox.create(bindings or {}),
	})()
end

for _, name in { "zune", "debug", "ffi", "fs", "io", "process", "net", "socket",
	"loadstring", "getfenv", "setfenv", "import", "include", "_G", "_ENV" } do
	assert(run("return " .. name, { [name] = zune }) == nil, name .. " leaked")
end
for _, source in { "loadstring('return 1')", "fs.read('secret')", "os.execute('command')",
	"ffi.load('library')", "require('@engine')", "getfenv(0)" } do
	assert(run("return not pcall(function() " .. source .. " end)", {
		require = function(): never error("must not reach host require") end,
	}) == true, "escape did not fail: " .. source)
end
local called = false
assert(run("return pcall(require, '../host')", { require = function(): () called = true end }) == false)
assert(not called, "string require reached host")
local module = {}
assert(run("return require(script)", { script = module, require = function(target: unknown): number
	assert(target == module)
	return 42
end }) == 42)
assert(run("return math.floor(4.9) + bit32.lshift(1, 2)") == 8)
assert(run("return not pcall(function() math.floor = nil end)") == true)
assert(type(math.floor) == "function")
run("leakedGlobal = true")
assert(run("return leakedGlobal") == nil)
print("PASS: sandbox global denial, module path denial, ModuleScript delegation, and isolation")
