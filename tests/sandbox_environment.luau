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

-- Phase 3.2: raw capability denial beyond the base list.
for _, name in { "sockets", "net", "load", "loadfile", "dofile", "package", "rawget", "rawset", "getmetatable" } do
	assert(run("return " .. name, { [name] = zune }) == nil, name .. " leaked")
end
assert(run("return os.execute") == nil, "os.execute leaked")
assert(run("return os.exit") == nil, "os.exit leaked")
assert(run("return os.getenv") == nil, "os.getenv leaked")
assert(run("return os.remove") == nil, "os.remove leaked")
assert(run("return os.rename") == nil, "os.rename leaked")
assert(run("return type(os.clock)") == "function", "os.clock missing")

-- Phase 3.2: HttpService domain allowlist.
assert(Sandbox.isUrlAllowed("https://example.com/api", { "example.com" }) == true)
assert(Sandbox.isUrlAllowed("https://sub.example.com/x", { "example.com" }) == true)
assert(Sandbox.isUrlAllowed("https://evil.com/x", { "example.com" }) == false)
assert(Sandbox.isUrlAllowed("https://example.com/x", {}) == false)
assert(Sandbox.isUrlAllowed("https://example.com.evil.com/x", { "example.com" }) == false)
assert(Sandbox.isUrlAllowed("ftp://example.com/x", { "example.com" }) == false)
assert(Sandbox.isUrlAllowed("https://user:pass@example.com/", { "example.com" }) == false)
assert(Sandbox.isUrlAllowed("https://localhost/x", { "localhost" }) == false)
assert(Sandbox.isUrlAllowed("http://127.0.0.1/x", { "127.0.0.1" }) == false)
assert(Sandbox.isUrlAllowed("https://10.0.0.5/x", { "10.0.0.5" }) == false)

-- Phase 3.2: HttpService proxy denies raw sockets and enforces allowlist.
local mockHost = {
	GetAsync = function(_self: unknown, url: string): string
		return "GET:" .. url
	end,
	PostAsync = function(_self: unknown, url: string): string
		return "POST:" .. url
	end,
	RequestAsync = function(_self: unknown, options: { Url: string }): { Url: string }
		return { Url = options.Url }
	end,
}
local proxy = Sandbox.createHttpProxy(mockHost, { "example.com" }, nil)
assert(proxy:GetAsync("https://example.com/a") == "GET:https://example.com/a")
assert(not pcall(function(): unknown return proxy:GetAsync("https://evil.com/a") end), "allowlist bypass")
assert(not pcall(function(): unknown return proxy:PostAsync("https://evil.com/a", {}) end), "allowlist bypass")
assert(not pcall(function(): unknown return proxy:RequestAsync({ Url = "https://evil.com/a" }) end), "allowlist bypass")
assert(not pcall(function(): unknown return (proxy :: any).CreateSocket() end), "raw socket allowed")
assert(not pcall(function(): unknown return (proxy :: any).Websocket({ host = "wss://example.com" }) end), "raw socket allowed")
local offline = Sandbox.createHttpProxy(nil, {}, nil)
assert(type(offline.JSONEncode) == "function", "offline JSONEncode missing")
assert(type(offline.JSONDecode) == "function", "offline JSONDecode missing")
assert(type((offline :: any).GenerateGUID("x")) == "string", "offline GUID missing")

-- Phase 3.2: game wiring returns proxied HttpService without breaking other services.
local fakeGame = {
	GetService = function(_self: unknown, name: string): unknown
		if name == "HttpService" then
			return mockHost
		end
		return "service:" .. name
	end,
}
local wrappedGame: any = Sandbox.wrapGameWithHttpPolicy(fakeGame, { "example.com" }, nil)
assert(wrappedGame:GetService("Workspace") == "service:Workspace", "game delegation broke")
local wrappedHttp: any = wrappedGame:GetService("HttpService")
assert(type(wrappedHttp.GetAsync) == "function", "wrapped HttpService missing")
assert(not pcall(function(): unknown return wrappedHttp:GetAsync("https://evil.com/") end), "wrapped allowlist bypass")

-- Phase 3.2: timeout and budget guardrails plus trusted engine path.
assert(Sandbox.getTimeoutSec(nil) == Sandbox.DEFAULT_TIMEOUT_SEC)
assert(Sandbox.getTimeoutSec({ timeoutSec = 1 } :: any) == 1)
assert(Sandbox.getTimeoutSec({ timeoutSec = 1000 } :: any) == Sandbox.MAX_TIMEOUT_SEC)
local budgetOk, _ = Sandbox.checkSourceBudget("return 1", nil)
assert(budgetOk == true)
local overOk, _ = Sandbox.checkSourceBudget(string.rep("x", Sandbox.MAX_SOURCE_BYTES + 1), nil)
assert(overOk == false)
local okIso, resIso = Sandbox.runIsolated("return 21 * 2", {}, nil)
assert(okIso and resIso == 42, "runIsolated basic failed")
local okTimeout, errTimeout = Sandbox.runIsolated("while true do task.wait() end", { task = zune.task } :: any, { timeoutSec = 0.2 } :: any)
assert(not okTimeout and string.find(tostring(errTimeout), "timed out", 1, true) ~= nil, "timeout guardrail failed")
local okTrusted, resTrusted = Sandbox.runIsolated("return type(zune) == 'table'", { SecurityCapabilities = 2 } :: any, nil)
assert(okTrusted and resTrusted == true, "trusted engine path broke")
local okBudget, _ = Sandbox.runIsolated(string.rep("x", Sandbox.MAX_SOURCE_BYTES + 1), {}, nil)
assert(not okBudget, "source budget guardrail failed")

-- Phase 3.2: sandboxed runner adapter stays headless and delegates isolation.
local Runner = require("../src/sandboxed/sandbox_runner")
assert(Runner.isUrlAllowed("https://example.com/", { "example.com" }) == true)
local okRunner, resRunner = Runner.runIsolated("return 6 * 7", {}, nil)
assert(okRunner and resRunner == 42, "sandbox_runner delegation failed")

print("PASS: sandbox global denial, module path denial, ModuleScript delegation, and isolation")
print("PASS: phase 3.2 allowlist proxy, timeout guardrails, trusted path")
