--!strict
-- Run from the repository root: zune run tests/run_tests.luau [--benchmarks]
local directory = "tests"
local benchmarks = false
local args = zune.process.args
local index = 2 -- Zune includes the script path as argument 1.
while index <= #args do
	local arg = args[index]
	if arg == "--benchmarks" then
		benchmarks = true
	elseif arg == "--test-dir" then
		index += 1
		assert(args[index], "--test-dir requires a directory")
		directory = args[index]
	else
		error("Unknown argument: " .. arg)
	end
	index += 1
end

local tests: { string } = {}
for _, entry in zune.fs.entries(directory) do
	local name = entry.name
	local supported = name:match("%.luau$") or name:match("%.py$")
	local benchmark = name:lower():find("benchmark", 1, true) ~= nil
	if entry.kind == "file" and supported and name ~= "run_tests.luau"
		and name ~= "verify_ffi_symbols.py" and (benchmarks or not benchmark) then
		table.insert(tests, name)
	end
end
table.sort(tests)
assert(#tests > 0, "No tests discovered in " .. directory)

local failures = 0
for _, name in tests do
	local path = zune.fs.path.join(directory, name)
	local executable = zune.fs.getExePath()
	local childArgs = { "run", path }
	if name:match("%.py$") then
		executable = zune.process.env.PYTHON or "python"
		childArgs = { path }
	end
	print("RUN " .. name)
	local ok, result = pcall(function()
		return zune.process.create(executable, childArgs, {
			stdin = "ignore", stdout = "inherit", stderr = "inherit",
		}):wait()
	end)
	if not ok then
		failures += 1
		print("FAIL " .. name .. ": " .. tostring(result))
	elseif not result.ok or result.code ~= 0 then
		failures += 1
		print("FAIL " .. name .. " (exit " .. tostring(result.code) .. ")")
	else
		print("OK " .. name)
	end
end
print(string.format("%d tests, %d failed", #tests, failures))
zune.process.exit(if failures == 0 then 0 else 1)
