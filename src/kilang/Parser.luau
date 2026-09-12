--!strict
-- Parser.luau
-- Dedicated Kilang frontend: source -> AST with source line/column for diagnostics.
-- Part of Phase 3.1 Parser -> AST -> Compiler pipeline. Keeps legacy regex
-- supersets untouched; this parser owns the `kilang` hot path.

local Parser = {}

export type Position = { line: number, column: number }
export type Stmt =
	{ kind: string, line: number, column: number, text: string, name: string?, value: string?, flag: string? }
export type AST = {
	kind: string,
	chunk: string,
	source: string,
	lines: { string },
	body: { Stmt },
	flags: { [string]: boolean },
	annotations: { [string]: { type: string, value: string?, isPointer: boolean } },
	variables: { [string]: { value: string?, isLocal: boolean } },
}

local function fail(chunk: string, line: number, col: number, msg: string): never
	error(("%s:%d:%d: %s"):format(chunk, line, col, msg), 0)
end

local function leadingCol(text: string): number
	local s = text:match("^(%s*)")
	return #s + 1
end

-- Scan a single line char-by-char tracking '...' / "..." so markers inside
-- strings are ignored. Calls `onCode(from, to)` for each code segment.
local function scanCodeSegments(line: string, onCode: (string) -> string): string
	local out: { string } = {}
	local i = 1
	local n = #line
	local segStart = 1
	local quote: string? = nil
	local function flushCode(upto: number)
		if segStart <= upto then
			local seg = line:sub(segStart, upto)
			table.insert(out, onCode(seg))
		end
	end
	while i <= n do
		local c = line:sub(i, i)
		if quote then
			if c == "\\" then
				i += 2
			elseif c == quote then
				-- End of string; include closing quote in protected region.
				i += 1
				table.insert(out, line:sub(segStart, i - 1))
				segStart = i
				quote = nil
			else
				i += 1
			end
		else
			if c == '"' or c == "'" then
				flushCode(i - 1)
				segStart = i
				quote = c
				i += 1
			else
				i += 1
			end
		end
	end
	if segStart <= n then
		if quote then
			-- Unterminated string: keep verbatim to let luau.compile diagnose.
			table.insert(out, line:sub(segStart, n))
		else
			flushCode(n)
		end
	end
	return table.concat(out)
end

-- Returns true when marker occurs outside string literals on this line.
local function hasCodeMarker(line: string, marker: string): boolean
	local found = false
	scanCodeSegments(line, function(seg: string): string
		if not found and seg:find(marker, 1, true) then
			found = true
		end
		return seg
	end)
	return found
end

local function stripLineCommentStart(line: string): string
	-- Kept for compatibility probes; lowering lives in Compiler.
	return line
end
stripLineCommentStart = stripLineCommentStart

function Parser.parse(source: string, chunkName: string?): AST
	local chunk = chunkName or "kilang"
	if type(source) ~= "string" then
		fail(chunk, 1, 1, "source must be a string")
	end
	local normalized = source:gsub("\r\n", "\n"):gsub("\r", "\n")
	local lines: { string } = {}
	for line in (normalized .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	-- Preserve empty input as a single empty line so downstream emit keeps 1:1 mapping.
	if #lines == 0 then
		table.insert(lines, "")
	end

	local body: { Stmt } = {}
	local flags: { [string]: boolean } = {}
	local annotations: { [string]: { type: string, value: string?, isPointer: boolean } } = {}
	local variables: { [string]: { value: string?, isLocal: boolean } } = {}

	local inCBlock = false
	local inLuaBlock = false
	local inLongString = false
	local longEq = ""

	local function closeMarkers(line: string): ()
		-- Update multi-line state by scanning code segments for open/close markers.
		-- Order: close previous block first, then detect new opens without a close.
		if inCBlock and line:find("*/", 1, true) then
			inCBlock = false
		end
		if inLuaBlock and line:find("]]", 1, true) then
			inLuaBlock = false
		end
		if inLongString then
			local closing = "]" .. longEq .. "]"
			if line:find(closing, 1, true) then
				inLongString = false
				longEq = ""
			end
		end
	end

	local function openMarkers(line: string): ()
		if inCBlock or inLuaBlock or inLongString then
			return
		end
		-- Detect C block comment open without close on the same line (outside strings).
		if hasCodeMarker(line, "/*") and not line:find("*/", 1, true) then
			inCBlock = true
		end
		-- Lua block comment --[[ without ]] on the same line.
		if hasCodeMarker(line, "--[[") and not line:find("]]", 1, true) then
			inLuaBlock = true
		end
		-- Long string [[ / [=[ outside strings/comments.
		if not hasCodeMarker(line, "--[[") then
			scanCodeSegments(line, function(seg: string): string
				local s, e, eq = seg:find("%[(=*)%[")
				if s and not seg:sub(e + 1, e + 2):find("]]", 1, true) then
					local closing = "]" .. (eq or "") .. "]"
					if not seg:find(closing, e + 1, true) then
						inLongString = true
						longEq = eq or ""
					end
				end
				return seg
			end)
		end
	end

	for idx, text in lines do
		local line = idx
		closeMarkers(text)
		local protected = inCBlock or inLuaBlock or inLongString
		local col = leadingCol(text)
		local trimmed = text:match("^%s*(.-)%s*$") or ""

		local stmt: Stmt? = nil
		if protected then
			stmt = { kind = "code", line = line, column = col, text = text }
		elseif trimmed:sub(1, 6) == "#flag:" then
			local flag = trimmed:match("^#flag:%s*([%w_%-]+)%s*$")
			if not flag then
				fail(chunk, line, col, "malformed #flag directive (expected #flag: <name>)")
			end
			flags[flag] = true
			stmt = { kind = "flag", line = line, column = col, text = text, flag = flag }
		elseif trimmed:sub(1, 8) == "#include" then
			if not trimmed:match('^#include%s+[<"].+[>"]%s*$') and not trimmed:match("^#include%s*$") then
				fail(chunk, line, col, "malformed #include directive")
			end
			stmt = { kind = "include", line = line, column = col, text = text }
		elseif trimmed:sub(1, 7) == "#define" then
			local name, value = trimmed:match("^#define%s+([%w_]+)%s*(.-)%s*$")
			if not name then
				fail(chunk, line, col, "malformed #define directive (expected #define NAME value)")
			end
			if value == "" then
				fail(chunk, line, col, ("#define '%s' requires a value"):format(name))
			end
			variables[name] = { value = value, isLocal = true }
			stmt = { kind = "define", line = line, column = col, text = text, name = name, value = value }
		elseif trimmed:sub(1, 7) == "#pragma" then
			stmt = { kind = "pragma", line = line, column = col, text = text }
		elseif trimmed:sub(1, 6) == "#undef" then
			local name = trimmed:match("^#undef%s+([%w_]+)%s*$")
			if not name then
				fail(chunk, line, col, "malformed #undef directive (expected #undef NAME)")
			end
			variables[name] = nil
			stmt = { kind = "undef", line = line, column = col, text = text, name = name }
		elseif trimmed:sub(1, 8) == "#warning" then
			local msg = trimmed:match('^#warning%s+"(.-)"%s*$') or trimmed:match("^#warning%s+(.-)%s*$")
			if not msg or msg == "" then
				fail(chunk, line, col, "malformed #warning directive (expected #warning \"message\")")
			end
			stmt = { kind = "warning", line = line, column = col, text = text, value = msg }
		elseif trimmed:sub(1, 6) == "#error" then
			local msg = trimmed:match('^#error%s+"(.-)"%s*$') or trimmed:match("^#error%s+(.-)%s*$")
			if not msg or msg == "" then
				fail(chunk, line, col, "malformed #error directive (expected #error \"message\")")
			end
			stmt = { kind = "error_directive", line = line, column = col, text = text, value = msg }
		else
			-- local x: Type = value  /  local x: Type  (annotation is metadata only)
			local aName, aType, aValue = text:match("local%s+([%w_]+)%s*:%s*([%w_%*]+)%s*=%s*(.-)%s*;?%s*$")
			if aName and aType then
				local baseType = aType:gsub("%*", "")
				annotations[aName] = { type = baseType, value = aValue ~= "" and aValue or nil, isPointer = aType:find("%*") ~= nil }
				variables[aName] = { value = aValue ~= "" and aValue or nil, isLocal = true }
				stmt = { kind = "local_annotated", line = line, column = col, text = text, name = aName, value = aValue }
			else
				local bName, bType = text:match("local%s+([%w_]+)%s*:%s*([%w_%*]+)%s*;?%s*$")
				if bName and bType and not text:find("=", 1, true) then
					local baseType = bType:gsub("%*", "")
					annotations[bName] = { type = baseType, value = nil, isPointer = bType:find("%*") ~= nil }
					if not variables[bName] then
						variables[bName] = { value = nil, isLocal = true }
					end
					stmt = { kind = "local_annotated", line = line, column = col, text = text, name = bName, value = nil }
				else
					-- Track locals/assignments for compatibility with legacy dataThread.
					local lName, lVal = text:match("local%s+([%w_]+)%s*=%s*(.-)%s*;?%s*$")
					if lName then
						variables[lName] = { value = lVal ~= "" and lVal or nil, isLocal = true }
					else
						local bare = text:match("^%s*local%s+([%w_]+)%s*;?%s*$")
						if bare and not variables[bare] then
							variables[bare] = { value = nil, isLocal = true }
						end
					end
					stmt = { kind = "code", line = line, column = col, text = text }
				end
			end
		end
		table.insert(body, stmt :: Stmt)
		openMarkers(text)
	end

	return {
		kind = "chunk",
		chunk = chunk,
		source = source,
		lines = lines,
		body = body,
		flags = flags,
		annotations = annotations,
		variables = variables,
	}
end

function Parser.lineCount(ast: AST): number
	return #ast.lines
end

return Parser
