--!strict
local runtime = require("../src/kilang")

local function execute(source: string, id: string, capabilities: number?): (boolean, unknown)
	local _, _, _, _, getResult = runtime:execute(source, {
		StackId = id, SecurityCapabilities = capabilities,
	})
	assert(getResult ~= nil, "runtime did not start")
	local success, result = getResult()
	runtime:remove(id)
	return success, result
end

local success, result = execute("return zune == nil and getfenv == nil and loadstring == nil", "globals")
assert(success and result == true)
success, result = execute("return math.floor(4.9)", "stdlib")
assert(success and result == 4)
success, result = execute("local isolated = false; task.spawn(function() isolated = zune == nil and getfenv == nil end); task.wait(); return isolated", "child-task")
assert(success and result == true, "spawned script closures must retain isolation")
success, result = execute("local =", "syntax-error")
assert(not success and type(result) == "string", "syntax failure must complete, not strand getResult")
success, result = execute("error('script failure')", "runtime-error")
assert(not success and string.find(tostring(result), "script failure", 1, true))
success, result = execute("return type(zune) == 'table'", "trusted-internals", 2)
assert(success and result == true, "trusted engine initialization must retain native runtime")
success, result = execute("return 42", "recovery")
assert(success and result == 42)
print("PASS: runtime isolation, stdlib, compiler failure, execution failure, trusted path, recovery")
