--!strict
-- Phase 3.2: isolated execution boundary.
-- Global isolation only. Engine objects still require capability-safe proxies.
-- Untrusted scripts get frozen stdlibs, denied host capabilities, an HttpService
-- domain-allowlist proxy (raw sockets denied), and cooperative timeout/budget
-- guardrails. Trusted engine path (SecurityCapabilities == 2) retains host access.
local SandboxEnvironment = {}
export type Environment = { [string]: unknown }
export type HttpAllowlist = { string }
export type SandboxOptions = {
	httpAllowlist: HttpAllowlist?,
	httpService: unknown?,
	httpTimeoutSec: number?,
	timeoutSec: number?,
	maxSourceBytes: number?,
	chunkName: string?,
}

SandboxEnvironment.TRUSTED_CAPABILITY = 2
SandboxEnvironment.DEFAULT_TIMEOUT_SEC = 5
SandboxEnvironment.DEFAULT_HTTP_TIMEOUT_SEC = 10
SandboxEnvironment.MAX_SOURCE_BYTES = 256 * 1024
SandboxEnvironment.MAX_TIMEOUT_SEC = 60
SandboxEnvironment.DEFAULT_HTTP_ALLOWLIST = {} :: HttpAllowlist

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

function SandboxEnvironment.isTrusted(bindings: Environment): boolean
	return (bindings :: any).SecurityCapabilities == SandboxEnvironment.TRUSTED_CAPABILITY
end

function SandboxEnvironment.extractHost(url: unknown): string?
	if type(url) ~= "string" then
		return nil
	end
	local trimmed = (url :: string):match("^%s*(.+)$") or (url :: string)
	local rest = trimmed:match("^[Hh][Tt][Tt][Pp][Ss]?://(.+)$")
	if not rest then
		return nil
	end
	local authority = rest:match("^([^/%?#]+)")
	if not authority or #authority == 0 then
		return nil
	end
	if authority:find("@", 1, true) ~= nil then
		return nil
	end
	local hostPart: string?
	if authority:sub(1, 1) == "[" then
		hostPart = authority:match("^(%[[^%]]+%])")
	else
		hostPart = authority:match("^([^:]+)")
	end
	if not hostPart or #hostPart == 0 then
		return nil
	end
	return hostPart:lower()
end

local function isBlockedHost(hostName: string): boolean
	if hostName == "localhost" or hostName == "0.0.0.0" or hostName == "::" or hostName == "[::]" then
		return true
	end
	if hostName == "::1" or hostName == "[::1]" then
		return true
	end
	if hostName:match("^127%.%d+%.%d+%.%d+$") ~= nil then
		return true
	end
	if hostName:match("^10%.%d+%.%d+%.%d+$") ~= nil then
		return true
	end
	if hostName:match("^192%.168%.") ~= nil then
		return true
	end
	if hostName:match("^169%.254%.") ~= nil then
		return true
	end
	local octet = hostName:match("^172%.(%d+)%.")
	if octet ~= nil then
		local n = tonumber(octet)
		if n ~= nil and n >= 16 and n <= 31 then
			return true
		end
	end
	return false
end

function SandboxEnvironment.isUrlAllowed(url: unknown, allowlist: unknown): boolean
	if type(url) ~= "string" then
		return false
	end
	if type(allowlist) ~= "table" then
		return false
	end
	local list = allowlist :: HttpAllowlist
	if #list == 0 then
		return false
	end
	local hostName = SandboxEnvironment.extractHost(url)
	if not hostName then
		return false
	end
	if isBlockedHost(hostName) then
		return false
	end
	for _, entry in list do
		if type(entry) == "string" then
			local normalized = ((entry :: string):match("^%s*(.-)%s*$") or (entry :: string)):lower()
			if #normalized > 0 then
				if normalized:sub(1, 1) == "." then
					local base = normalized:sub(2)
					if #base > 0 and #hostName > #base and hostName:sub(-#base - 1) == "." .. base then
						return true
					end
				else
					if hostName == normalized then
						return true
					end
					if #hostName > #normalized and hostName:sub(-#normalized - 1) == "." .. normalized then
						return true
					end
				end
			end
		end
	end
	return false
end

function SandboxEnvironment.checkSourceBudget(source: unknown, maxBytes: number?): (boolean, string?)
	local limit = maxBytes or SandboxEnvironment.MAX_SOURCE_BYTES
	if type(limit) ~= "number" or limit <= 0 then
		limit = SandboxEnvironment.MAX_SOURCE_BYTES
	end
	if type(source) ~= "string" then
		return false, "source must be a string"
	end
	if #(source :: string) > (limit :: number) then
		return false, `source exceeds {(limit :: number)} bytes`
	end
	return true, nil
end

function SandboxEnvironment.getTimeoutSec(opts: unknown): number
	if type(opts) == "table" then
		local requested = (opts :: any).timeoutSec
		if type(requested) == "number" and requested > 0 then
			return math.min(requested, SandboxEnvironment.MAX_TIMEOUT_SEC)
		end
	end
	return SandboxEnvironment.DEFAULT_TIMEOUT_SEC
end

local function denyRawSocket(): never
	error("Sandbox: raw sockets denied (use HttpService allowlisted requests)", 2)
end

function SandboxEnvironment.createHttpProxy(hostHttp: unknown, allowlist: HttpAllowlist?, opts: unknown): { [string]: unknown }
	local list: HttpAllowlist = SandboxEnvironment.DEFAULT_HTTP_ALLOWLIST
	if type(allowlist) == "table" then
		list = allowlist :: HttpAllowlist
	end
	local httpTimeout = SandboxEnvironment.DEFAULT_HTTP_TIMEOUT_SEC
	if type(opts) == "table" and type((opts :: any).httpTimeoutSec) == "number" then
		httpTimeout = (opts :: any).httpTimeoutSec
	end
	local hostTable: { [string]: any }? = if type(hostHttp) == "table" then (hostHttp :: any) else nil

	local function checkUrl(url: unknown): string
		if type(url) ~= "string" then
			error("Sandbox HttpService: Url must be a string", 2)
		end
		if not SandboxEnvironment.isUrlAllowed(url, list) then
			local hostName = SandboxEnvironment.extractHost(url) or tostring(url)
			error(`Sandbox HttpService: domain not allowlisted: {hostName}`, 2)
		end
		return url :: string
	end

	local function withTimeout(requestOpts: any): any
		if type(requestOpts) ~= "table" then
			return { Timeout = httpTimeout }
		end
		if requestOpts.Timeout == nil then
			local copy: { [string]: any } = table.clone(requestOpts)
			copy.Timeout = httpTimeout;
			(copy :: any).AllowRedirects = requestOpts.AllowRedirects
			return copy
		end
		return requestOpts
	end

	local proxy: { [string]: any } = {}

	proxy.GetAsync = function(selfOrUrl: unknown, urlOrHeaders: unknown, headersOrOpts: unknown, optsOrNil: unknown): unknown
		local url: unknown
		local headers: unknown
		local callOpts: unknown
		if type(selfOrUrl) == "string" then
			url = selfOrUrl
			headers = urlOrHeaders
			callOpts = headersOrOpts
		else
			url = urlOrHeaders
			headers = headersOrOpts
			callOpts = optsOrNil
		end
		local allowed = checkUrl(url)
		if hostTable == nil or type(hostTable.GetAsync) ~= "function" then
			error(`Sandbox HttpService: GET {allowed} blocked (no host transport in sandbox)`, 2)
		end
		return (hostTable :: any).GetAsync(hostTable, allowed, headers, withTimeout(callOpts))
	end

	proxy.PostAsync = function(selfOrUrl: unknown, urlOrBody: unknown, bodyOrHeaders: unknown, headersOrOpts: unknown, optsOrNil: unknown): unknown
		local url: unknown
		local body: unknown
		local headers: unknown
		local callOpts: unknown
		if type(selfOrUrl) == "string" then
			url = selfOrUrl
			body = urlOrBody
			headers = bodyOrHeaders
			callOpts = headersOrOpts
		else
			url = urlOrBody
			body = bodyOrHeaders
			headers = headersOrOpts
			callOpts = optsOrNil
		end
		local allowed = checkUrl(url)
		if hostTable == nil or type(hostTable.PostAsync) ~= "function" then
			error(`Sandbox HttpService: POST {allowed} blocked (no host transport in sandbox)`, 2)
		end
		return (hostTable :: any).PostAsync(hostTable, allowed, body, headers, withTimeout(callOpts))
	end

	proxy.RequestAsync = function(selfOrOptions: unknown, optionsOrNil: unknown): unknown
		local requestOptions: unknown = if type(selfOrOptions) == "table"
			and (selfOrOptions :: any).Url ~= nil
			then selfOrOptions
			else optionsOrNil
		if type(requestOptions) ~= "table" then
			-- Delegate validation to host when present so error shapes stay familiar.
			if hostTable ~= nil and type(hostTable.RequestAsync) == "function" then
				return (hostTable :: any).RequestAsync(hostTable, requestOptions)
			end
			error("Sandbox HttpService: RequestAsync expects a request dictionary", 2)
		end
		local urlValue = (requestOptions :: any).Url
		local allowed = checkUrl(urlValue)
		if hostTable == nil or type(hostTable.RequestAsync) ~= "function" then
			error(`Sandbox HttpService: {allowed} blocked (no host transport in sandbox)`, 2)
		end
		local copy: { [string]: any } = table.clone(requestOptions :: any)
		copy.Url = allowed
		if copy.Timeout == nil then
			copy.Timeout = httpTimeout
		end
		return (hostTable :: any).RequestAsync(hostTable, copy)
	end

	if hostTable ~= nil and type(hostTable.JSONEncode) == "function" then
		local hostFn = hostTable.JSONEncode
		proxy.JSONEncode = function(_self: unknown, value: unknown): unknown
			local payload: unknown = if _self == proxy then value else if value ~= nil then value else _self
			return hostFn(hostTable, payload)
		end
	else
		proxy.JSONEncode = function(_self: unknown, value: unknown): unknown
			local payload: unknown = if _self == proxy then value else if value ~= nil then value else _self
			local ok, serde = pcall(function(): unknown return (host :: any).zune.serde.json end)
			if ok and type(serde) == "table" then
				return (serde :: any).encode(payload)
			end
			error("Sandbox HttpService: JSONEncode unavailable", 2)
		end
	end

	if hostTable ~= nil and type(hostTable.JSONDecode) == "function" then
		local hostFn = hostTable.JSONDecode
		proxy.JSONDecode = function(_self: unknown, value: unknown): unknown
			local payload: unknown = if _self == proxy then value else if value ~= nil then value else _self
			return hostFn(hostTable, payload)
		end
	else
		proxy.JSONDecode = function(_self: unknown, value: unknown): unknown
			local payload: unknown = if _self == proxy then value else if value ~= nil then value else _self
			local ok, serde = pcall(function(): unknown return (host :: any).zune.serde.json end)
			if ok and type(serde) == "table" then
				return (serde :: any).decode(payload)
			end
			error("Sandbox HttpService: JSONDecode unavailable", 2)
		end
	end

	if hostTable ~= nil and type(hostTable.GenerateGUID) == "function" then
		local hostFn = hostTable.GenerateGUID
		proxy.GenerateGUID = function(_self: unknown, curly: unknown): unknown
			local arg = if curly ~= nil then curly else if type(_self) == "boolean" then _self else nil
			return hostFn(hostTable, arg)
		end
	else
		proxy.GenerateGUID = function(_self: unknown, curly: unknown): string
			local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
			local guid = template:gsub("[xy]", function(c: string): string
				local r = math.random(0, 15)
				local v = if c == "x" then r else (r % 4 + 8)
				return string.format("%x", v)
			end)
			local wantCurly = if curly ~= nil then curly else if type(_self) == "boolean" then _self else false
			if wantCurly then
				return "{" .. guid .. "}"
			end
			return guid
		end
	end

	proxy.CreateSocket = denyRawSocket
	proxy.Websocket = denyRawSocket
	proxy.CreateWebSocket = denyRawSocket

	return table.freeze(proxy)
end

local function wrapTaskForSandbox(taskValue: unknown): unknown
	if type(taskValue) ~= "table" then
		taskValue = (host :: any).zune.task
	end
	if type(taskValue) ~= "table" then
		return nil
	end
	local source = taskValue :: any
	local wrapped: { [string]: any } = {}
	if type(source.cancel) == "function" then
		wrapped.cancel = source.cancel
	end
	if type(source.wait) == "function" then
		wrapped.wait = source.wait
	end
	if type(source.spawn) == "function" then
		wrapped.spawn = source.spawn
	end
	if type(source.defer) == "function" then
		wrapped.defer = source.defer
	end
	if type(source.delay) == "function" then
		wrapped.delay = source.delay
	end
	if type(source.desynchronize) == "function" then
		wrapped.desynchronize = source.desynchronize
	end
	if type(source.synchronize) == "function" then
		wrapped.synchronize = source.synchronize
	end
	return table.freeze(wrapped)
end

function SandboxEnvironment.wrapGameWithHttpPolicy(gameValue: unknown, allowlist: HttpAllowlist?, opts: unknown): unknown
	if type(gameValue) ~= "table" then
		return gameValue
	end
	local list: HttpAllowlist = SandboxEnvironment.DEFAULT_HTTP_ALLOWLIST
	if type(allowlist) == "table" then
		list = allowlist :: HttpAllowlist
	end
	local gameTable = gameValue :: any
	local originalGetService = gameTable.GetService
	if type(originalGetService) ~= "function" then
		return gameValue
	end
	local cachedProxy: { [string]: unknown }? = nil
	local function getHttpProxy(): { [string]: unknown }
		if cachedProxy == nil then
			local hostHttp: unknown = nil
			local ok, service = pcall(originalGetService, gameTable, "HttpService")
			if ok then
				hostHttp = service
			end
			cachedProxy = SandboxEnvironment.createHttpProxy(hostHttp, list, opts)
		end
		return cachedProxy :: { [string]: unknown }
	end
	local proxy: any = setmetatable({}, {
		__index = function(_: unknown, key: unknown): unknown
			if key == "GetService" then
				return function(_self: unknown, name: unknown): unknown
					if name == "HttpService" then
						return getHttpProxy()
					end
					return originalGetService(gameTable, name)
				end
			end
			return gameTable[key]
		end,
		__newindex = function(_: unknown, key: unknown, value: unknown): ()
			gameTable[key] = value
		end,
	})
	return proxy
end

function SandboxEnvironment.create(bindings: Environment, opts: SandboxOptions?): Environment
	-- Preserve the trusted engine path: Internals capability keeps host access.
	if SandboxEnvironment.isTrusted(bindings) then
		return bindings
	end
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
	-- Cooperative scheduling only: freeze the safe subset when the caller supplies task.
	-- Do not inject host task when absent; least privilege by default.
	local taskBinding = (bindings :: any).task
	if taskBinding ~= nil then
		env.task = wrapTaskForSandbox(taskBinding)
	else
		env.task = nil
	end
	-- Proxy HttpService through the domain allowlist; raw sockets stay denied.
	local options: SandboxOptions? = opts
	if options == nil and type((bindings :: any).HttpAllowlist) == "table" then
		options = { httpAllowlist = (bindings :: any).HttpAllowlist }
	end
	local allowlist: HttpAllowlist = SandboxEnvironment.DEFAULT_HTTP_ALLOWLIST
	if options ~= nil and type(options.httpAllowlist) == "table" then
		allowlist = options.httpAllowlist :: HttpAllowlist
	elseif type((bindings :: any).HttpAllowlist) == "table" then
		allowlist = (bindings :: any).HttpAllowlist
	end
	local envAny: any = env
	envAny.HttpAllowlist = nil
	local hostHttp: unknown = nil
	if options ~= nil and (options :: SandboxOptions).httpService ~= nil then
		hostHttp = (options :: SandboxOptions).httpService
	elseif (bindings :: any).HttpService ~= nil then
		hostHttp = (bindings :: any).HttpService
	end
	if hostHttp ~= nil then
		env.HttpService = SandboxEnvironment.createHttpProxy(hostHttp, allowlist, options)
	else
		-- Deny-by-default proxy still offers offline JSON/GUID helpers without transport.
		env.HttpService = SandboxEnvironment.createHttpProxy(nil, allowlist, options)
	end
	-- NOTE: game:GetService("HttpService") interception lives in
	-- wrapGameWithHttpPolicy for explicit engine wiring (ScriptContext layer).
	-- Auto-wrapping game here would break Instance identity/equality, so direct
	-- HttpService bindings are proxied above while game objects pass through.
	local moduleRequire = bindings.require
	if type(moduleRequire) == "function" then
		env.require = function(target: unknown): unknown
			if type(target) ~= "table" then
				error("Sandbox require accepts ModuleScripts only; host module paths are forbidden", 2)
			end
			return (moduleRequire :: any)(target)
		end
	else
		env.require = nil
	end
	-- No metatable fallback; globals written by one script remain in that script.
	return env
end

function SandboxEnvironment.runIsolated(source: string, bindings: Environment?, opts: SandboxOptions?): (boolean, unknown)
	local inputBindings: Environment = bindings or ({} :: Environment)
	local options: SandboxOptions? = opts
	local budgetOk, budgetErr = SandboxEnvironment.checkSourceBudget(source, if options ~= nil then options.maxSourceBytes else nil)
	if not budgetOk then
		return false, budgetErr
	end
	if SandboxEnvironment.isTrusted(inputBindings) then
		-- Trusted engine path: host fallback plus native codegen, matching kilang:init.
		local trustedEnv: any = {}
		for key, value in inputBindings do
			trustedEnv[key] = value
		end
		if trustedEnv.zune == nil then
			trustedEnv.zune = (host :: any).zune
		end
		setmetatable(trustedEnv, { __index = host })
		local luauLib = (host :: any).zune.luau
		local compiledOk, bytecodeOrErr = pcall(luauLib.compile, source, { optimization_level = 2 })
		if not compiledOk then
			return false, tostring(bytecodeOrErr)
		end
		local loadedOk, threadOrErr = pcall(luauLib.load, bytecodeOrErr, {
			env = trustedEnv,
			chunk_name = if options ~= nil and options.chunkName ~= nil then options.chunkName else "trusted",
			native_code_gen = true,
		})
		if not loadedOk then
			return false, tostring(threadOrErr)
		end
		pcall(setfenv, threadOrErr, trustedEnv)
		local ok, result = pcall(threadOrErr)
		return ok, result
	end
	local env = SandboxEnvironment.create(inputBindings, options)
	local timeoutSec = SandboxEnvironment.getTimeoutSec(options)
	local chunkName = if options ~= nil and options.chunkName ~= nil then options.chunkName else "sandbox"
	local luauLib = (host :: any).zune.luau
	local taskLib = (host :: any).zune.task
	local compiledOk, bytecodeOrErr = pcall(luauLib.compile, source, { optimization_level = 2 })
	if not compiledOk then
		return false, tostring(bytecodeOrErr)
	end
	local loadedOk, threadOrErr = pcall(luauLib.load, bytecodeOrErr, {
		env = env,
		chunk_name = chunkName,
		native_code_gen = false,
	})
	if not loadedOk then
		return false, tostring(threadOrErr)
	end
	pcall(setfenv, threadOrErr, env)
	-- Cooperative timeout: yielding scripts are cancelled after the budget.
	-- A tight non-yielding loop cannot be preempted without debug hooks; the
	-- source-byte budget above bounds that vector instead.
	if type(taskLib) ~= "table" or type(taskLib.spawn) ~= "function" then
		local ok, result = pcall(threadOrErr)
		return ok, result
	end
	local success: boolean? = nil
	local result: unknown = nil
	local finished = false
	local worker: thread? = nil
	worker = taskLib.spawn(function(): ()
		local ok, value = pcall(threadOrErr)
		success = ok
		result = value
		finished = true
	end)
	local deadline = os.clock() + timeoutSec
	while not finished do
		if os.clock() >= deadline then
			if worker ~= nil then
				pcall(taskLib.cancel, worker)
			end
			return false, `Sandbox: execution timed out after {timeoutSec} seconds`
		end
		taskLib.wait()
	end
	return (success :: boolean), result
end

return SandboxEnvironment
