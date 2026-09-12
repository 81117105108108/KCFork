--!strict
-- Compiler.luau
-- AST -> standard Luau emitter for Phase 3.1. Preserves source line numbers so
-- `luau.compile` diagnostics map 1:1 back to Kilang source line/column.
-- Expression lowering is token-aware (string literals verbatim); it replaces
-- the legacy regex-only whole-file transpilation on the `kilang` hot path.

local Parser = require("./Parser")

local Compiler = {}

export type CompileMeta = {
	flags: { [string]: boolean },
	annotations: { [string]: { type: string, value: string?, isPointer: boolean } },
	variables: { [string]: { value: string?, isLocal: boolean } },
}

local function diag(chunk: string, line: number, col: number, msg: string): string
	return ("%s:%d:%d: %s"):format(chunk, line, col, msg)
end

-- String-placeholder lowering: extract '...' / "..." / [[...]] single-line
-- literals to __KILANG_STR_N__ before transforms (legacy-compatible
-- protection), then restore verbatim. Placeholders keep patterns like
-- printf("hi") matchable while leaving literal contents untouched.
local function extractStrings(line: string): (string, { string })
	local strings: { string } = {}
	local out: { string } = {}
	local i = 1
	local n = #line
	local segStart = 1
	local function flushCode(upto: number)
		if segStart <= upto then
			table.insert(out, line:sub(segStart, upto))
		end
	end
	while i <= n do
		local c = line:sub(i, i)
		if c == '"' or c == "'" then
			flushCode(i - 1)
			local quote = c
			local s = i
			i += 1
			while i <= n do
				local d = line:sub(i, i)
				if d == "\\" then
					i += 2
				elseif d == quote then
					i += 1
					break
				else
					i += 1
				end
			end
			table.insert(strings, line:sub(s, math.min(i - 1, n)))
			table.insert(out, ("__KILANG_STR_%d__"):format(#strings))
			segStart = i
		elseif c == "[" then
			local eq = line:match("^%[(=*)%[", i)
			if eq ~= nil then
				local closing = "]" .. eq .. "]"
				local closeAt = line:find(closing, i + 2 + #eq, true)
				if closeAt then
					flushCode(i - 1)
					table.insert(strings, line:sub(i, closeAt + #closing - 1))
					table.insert(out, ("__KILANG_STR_%d__"):format(#strings))
					i = closeAt + #closing
					segStart = i
				else
					-- Multi-line long string open: leave for verbatim tracking.
					break
				end
			else
				i += 1
			end
		else
			i += 1
		end
	end
	flushCode(n)
	return table.concat(out), strings
end

local function restoreStrings(line: string, strings: { string }): string
	local s = line
	for j = #strings, 1, -1 do
		local replacement = strings[j]:gsub("%%", "%%%%")
		s = s:gsub("__KILANG_STR_" .. j .. "__", replacement)
	end
	return s
end

local function lowerCodeSegment(seg: string): string
	local s = seg
	-- C++ line comments -> Luau comments (first // outside strings starts comment).
	local commentAt = s:find("//", 1, true)
	if commentAt then
		s = s:sub(1, commentAt - 1) .. "--" .. s:sub(commentAt + 2)
	end
	-- C block comments -> Luau block comments (per-occurrence; multi-line spans
	-- stay balanced because open/close convert symmetrically).
	s = s:gsub("/%*", "--[[")
	s = s:gsub("%*/", "]]")
	-- Member access through pointer.
	s = s:gsub("([%w_%)%]%\"']+)%->([%w_]+)", "%1.%2")
	-- Null-like literals.
	s = s:gsub("%f[%w]NULL%f[%W]", "nil")
	s = s:gsub("%f[%w]nullptr%f[%W]", "nil")
	s = s:gsub("%f[%w]TRUE%f[%W]", "true")
	s = s:gsub("%f[%w]FALSE%f[%W]", "false")
	-- C casts.
	s = s:gsub("%(int%)%s*([%w_%.%(%)]+)", "math.floor(%1)")
	s = s:gsub("%(float%)%s*([%w_%.%(%)]+)", "%1")
	s = s:gsub("%(double%)%s*([%w_%.%(%)]+)", "%1")
	s = s:gsub("static_cast%s*<%s*int%s*>%s*%((.-)%)", "math.floor(%1)")
	s = s:gsub("static_cast%s*<%s*float%s*>%s*%((.-)%)", "%1")
	s = s:gsub("static_cast%s*<%s*double%s*>%s*%((.-)%)", "%1")
	s = s:gsub("%(string%)%s*([%w_%.%(%)]+)", "tostring(%1)")
	-- Preprocessor leftovers that appear mid-line (line-start forms are AST nodes).
	s = s:gsub("#include%s*[<\"].*[>\"]", "")
	s = s:gsub("#pragma%s+once", "")
	-- stdio / std shims (same surface as legacy kilang superset).
	s = s:gsub("printf%s*%((.-)%)%s*;?", "print(%1)")
	s = s:gsub("std::cout%s*<<(.-)<<.-std::endl", function(expr: string): string
		local trimmed = expr:match("^%s*(.-)%s*$") or expr
		return "print(" .. trimmed .. ")"
	end)
	s = s:gsub("std::string", "string")
	s = s:gsub("std::vector%s*<.->%s+([%w_]+)", "local %1 = {}")
	s = s:gsub("%f[%w]nullptr%f[%W]", "nil")
	-- Bitwise operators -> bit32 shims (legacy kilang surface).
	s = s:gsub("([%w_%)%]%\"']+)%s*<<%s*([%w_%)%(%\"']+)", "bit32.lshift(%1, %2)")
	s = s:gsub("([%w_%)%]%\"']+)%s*>>%s*([%w_%)%(%\"']+)", "bit32.rshift(%1, %2)")
	s = s:gsub("([%w_%)%]%\"']+)%s*&%s*([%w_%)%(%\"']+)", "bit32.band(%1, %2)")
	s = s:gsub("([%w_%)%]%\"']+)%s*|%s*([%w_%)%(%\"']+)", "bit32.bor(%1, %2)")
	s = s:gsub("([%w_%)%]%\"']+)%s*%^%s*([%w_%)%(%\"']+)", "bit32.bxor(%1, %2)")
	s = s:gsub("~([%w_%)%(%\"']+)", "bit32.bnot(%1)")
	return s
end

function Compiler.lowerLine(line: string): string
	if line == "" then
		return ""
	end
	local protected, strings = extractStrings(line)
	local lowered = lowerCodeSegment(protected)
	return restoreStrings(lowered, strings)
end

local function escapeForPrint(msg: string): string
	-- %q-style quoting without relying on string.format %q portability.
	return '"' .. msg:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

function Compiler.emit(ast: Parser.AST): (string, CompileMeta)
	local out: { string } = {}
	-- Verbatim tracking for multi-line C blocks, Lua blocks, and long strings:
	-- lines inside are emitted unchanged so their contents are never lowered.
	local inCBlock = false
	local inLuaBlock = false
	local inLong = false
	local longEq = ""
	for _, stmt in ast.body do
		if stmt.kind == "include" or stmt.kind == "pragma" or stmt.kind == "flag" then
			-- Elided but line-preserving: emit empty line so downstream
			-- luau.compile line numbers match the Kilang source.
			table.insert(out, "")
		elseif stmt.kind == "define" then
			local value = Compiler.lowerLine(stmt.value or "")
			table.insert(out, ("local %s = %s"):format(stmt.name :: string, value))
		elseif stmt.kind == "undef" then
			table.insert(out, ((stmt.name :: string) .. " = nil"))
		elseif stmt.kind == "warning" then
			table.insert(out, ("print(%s)"):format(escapeForPrint("[WARNING] " .. (stmt.value or ""))))
		elseif stmt.kind == "error_directive" then
			table.insert(out, ("error(%s)"):format(escapeForPrint("[ERROR] " .. (stmt.value or ""))))
		elseif stmt.kind == "local_annotated" then
			if stmt.value ~= nil and stmt.value ~= "" then
				table.insert(out, ("local %s = %s"):format(stmt.name :: string, Compiler.lowerLine(stmt.value :: string)))
			else
				table.insert(out, ("local %s"):format(stmt.name :: string))
			end
		else
			if inCBlock or inLuaBlock or inLong then
				table.insert(out, stmt.text)
				if inCBlock and stmt.text:find("*/", 1, true) then
					inCBlock = false
				end
				if inLuaBlock and stmt.text:find("]]", 1, true) then
					inLuaBlock = false
				end
				if inLong and stmt.text:find("]" .. longEq .. "]", 1, true) then
					inLong = false
					longEq = ""
				end
			else
				table.insert(out, Compiler.lowerLine(stmt.text))
				local protected = extractStrings(stmt.text)
				if protected:find("/*", 1, true) and not protected:find("*/", 1, true) then
					inCBlock = true
				end
				if protected:find("--[[", 1, true) and not protected:find("]]", 1, true) then
					inLuaBlock = true
				end
				local s, e, eq = protected:find("%[(=*)%[")
				if s then
					local closing = "]" .. (eq or "") .. "]"
					if not protected:find(closing, e + 1, true) then
						inLong = true
						longEq = eq or ""
					end
				end
			end
		end
	end
	local meta: CompileMeta = { flags = ast.flags, annotations = ast.annotations, variables = ast.variables }
	return table.concat(out, "\n"), meta
end

local function luauAvailable(): boolean
	local g = getfenv(0) :: any
	local z = (g :: any).zune
	return type(z) == "table" and type(z.luau) == "table" and type(z.luau.compile) == "function"
end

local function normalizeLuauError(chunk: string, err: unknown): string
	local msg = tostring(err)
	-- luau.compile failures look like ":line: message" or "chunk:line: message".
	-- Normalize to "chunk:line:col: message" with best-effort col 1.
	if msg:match("^[^:]+:%d+:%d+:") then
		return msg
	end
	local line, rest = msg:match("^.-:(%d+):%s*(.*)$")
	if line then
		return ("%s:%s:1: %s"):format(chunk, line, rest)
	end
	return ("%s:1:1: %s"):format(chunk, msg)
end

function Compiler.compileSource(source: string, chunkName: string?): (string?, unknown)
	local chunk = chunkName or "kilang"
	local okParse, astOrErr = pcall(Parser.parse, source, chunk)
	if not okParse then
		return nil, tostring(astOrErr)
	end
	local ast = astOrErr :: Parser.AST
	local luauSource, meta = Compiler.emit(ast)
	if luauAvailable() then
		local g = getfenv(0) :: any
		local compile = (g :: any).zune.luau.compile
		local ok, err = pcall(compile, luauSource, { optimization_level = 2 })
		if not ok then
			return nil, normalizeLuauError(chunk, err)
		end
	end
	return luauSource, meta
end

function Compiler.compile(astOrSource: Parser.AST | string, chunkName: string?): (string?, unknown)
	if type(astOrSource) == "string" then
		return Compiler.compileSource(astOrSource :: string, chunkName)
	end
	local ast = astOrSource :: Parser.AST
	local chunk = chunkName or ast.chunk or "kilang"
	local luauSource, meta = Compiler.emit(ast)
	if luauAvailable() then
		local g = getfenv(0) :: any
		local compile = (g :: any).zune.luau.compile
		local ok, err = pcall(compile, luauSource, { optimization_level = 2 })
		if not ok then
			return nil, normalizeLuauError(chunk, err)
		end
	end
	return luauSource, meta
end

function Compiler.diagnostic(chunk: string, line: number, col: number, msg: string): string
	return diag(chunk, line, col, msg)
end

return Compiler
