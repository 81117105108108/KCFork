--!strict
local thread = zune.thread
local preprocessor = require("./Transpiler")
local luau = zune.luau

local function normalizeError(label: string, err: unknown): string
	local msg = tostring(err)
	if msg:match("^[^:]+:%d+:%d+:") then
		return msg
	end
	local line, rest = msg:match("^.-:(%d+):%s*(.*)$")
	if line then
		return (`{label}:{line}:1: {rest}`)
	end
	return (`{label}:1:1: {msg}`)
end

while true do
	local req = thread.receive()
	if not req then
		continue
	end

	if req.action == "compile" then
		local ok, transpiledCode = pcall(preprocessor.runLang, req.code, req.superset)
		if not ok then
			thread.send({ id = req.id, error = normalizeError(tostring(req.superset or "kilang"), transpiledCode) })
			continue
		end

		-- Compilation errors must fail this request, not terminate the worker.
		local compiled, bytecode, compile_err = pcall(luau.compile, transpiledCode, { optimization_level = 2 })
		if not compiled or not bytecode then
			local raw = if compiled then compile_err else tostring(bytecode)
			thread.send({ id = req.id, error = normalizeError(tostring(req.superset or "kilang"), raw) })
			continue
		end

		thread.send({ id = req.id, result = bytecode })
	end
end
