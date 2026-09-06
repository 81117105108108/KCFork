--!strict
-- Run the real worker with an in-memory transport and deterministic transpiler.
type Request = { id: number, action: string, code: string, superset: string }
type Response = { id: number, result: string?, error: string? }

local responses: { Response } = {}
local environment = setmetatable({
	zune = {
		luau = zune.luau,
		thread = {
			receive = function(): Request
				return coroutine.yield()
			end,
			send = function(response: Response): ()
				table.insert(responses, response)
			end,
		},
	},
	require = function(path: string): { runLang: (string, string) -> string }
		assert(path == "./Transpiler")
		return {
			runLang = function(source: string, language: string): string
				assert(language == "kilang")
				if source == "transpile-error" then
					error("transpilation rejected")
				end
				return if source == "answer" then "return 42" else source
			end,
		}
	end,
}, { __index = getfenv() })

local worker = coroutine.create(zune.luau.load(zune.luau.compile(
	zune.fs.readFile("src/kilang/_worker.luau")
), { env = environment }))
assert(coroutine.resume(worker))

local function request(id: number, source: string): Response
	local ok, failure = coroutine.resume(worker, {
		id = id, action = "compile", code = source, superset = "kilang",
	})
	assert(ok, tostring(failure))
	assert(#responses == id, "worker must send exactly one response per request")
	local response = responses[id]
	assert(response.id == id)
	return response
end

local success = request(1, "answer")
assert(success.result ~= nil and success.error == nil)
assert(zune.luau.load(success.result)() == 42, "must compile transpiled source")
assert(string.find(request(2, "transpile-error").error or "", "transpilation rejected", 1, true))
assert(request(3, "local =").error ~= nil, "compile failure must be returned")
assert(request(4, "").result ~= nil, "empty source remains valid")
assert(request(5, "answer").result ~= nil, "worker must survive failed requests")
coroutine.close(worker)
print("PASS: Kilang worker transpilation, errors, empty input, and recovery")
