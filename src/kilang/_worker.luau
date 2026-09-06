--!strict
local thread = zune.thread
local preprocessor = require("./Transpiler")
local luau = zune.luau

while true do
	local req = thread.receive()
	if not req then
		continue
	end

	if req.action == "compile" then
		local ok, transpiledCode = pcall(preprocessor.runLang, req.code, req.superset)
		if not ok then
			thread.send({ id = req.id, error = transpiledCode })
			continue
		end

		-- Compilation errors must fail this request, not terminate the worker.
		local compiled, bytecode, compile_err = pcall(luau.compile, transpiledCode, { optimization_level = 2 })
		if not compiled or not bytecode then
			thread.send({ id = req.id, error = if compiled then compile_err else tostring(bytecode) })
			continue
		end

		thread.send({ id = req.id, result = bytecode })
	end
end
