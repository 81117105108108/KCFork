--!strict
-- Phase 3.2 sandbox runner (headless-testable).
-- Isolated execution boundary for untrusted scripts:
--   * SandboxEnvironment global isolation (debug/ffi/fs/process/raw sockets denied)
--   * HttpService domain-allowlist proxy (deny by default, raw sockets denied)
--   * Cooperative timeout + source-byte budget guardrails
--   * Trusted engine path (SecurityCapabilities == 2) preserves host access.
-- No top-level game access so this module can be required headlessly.
local SandboxRunner = {}

local SandboxEnvironment = require("../kilang/SandboxEnvironment")

export type Environment = SandboxEnvironment.Environment
export type HttpAllowlist = SandboxEnvironment.HttpAllowlist
export type SandboxOptions = SandboxEnvironment.SandboxOptions

SandboxRunner.TRUSTED_CAPABILITY = SandboxEnvironment.TRUSTED_CAPABILITY
SandboxRunner.DEFAULT_TIMEOUT_SEC = SandboxEnvironment.DEFAULT_TIMEOUT_SEC
SandboxRunner.DEFAULT_HTTP_TIMEOUT_SEC = SandboxEnvironment.DEFAULT_HTTP_TIMEOUT_SEC
SandboxRunner.MAX_SOURCE_BYTES = SandboxEnvironment.MAX_SOURCE_BYTES
SandboxRunner.DEFAULT_HTTP_ALLOWLIST = {} :: HttpAllowlist

function SandboxRunner.isTrusted(bindings: Environment): boolean
	return SandboxEnvironment.isTrusted(bindings)
end

function SandboxRunner.isUrlAllowed(url: unknown, allowlist: HttpAllowlist?): boolean
	local list: HttpAllowlist = if type(allowlist) == "table"
		then allowlist :: HttpAllowlist
		else SandboxRunner.DEFAULT_HTTP_ALLOWLIST
	return SandboxEnvironment.isUrlAllowed(url, list)
end

function SandboxRunner.createHttpProxy(hostHttp: unknown, allowlist: HttpAllowlist?, opts: SandboxOptions?): { [string]: unknown }
	local list: HttpAllowlist = if type(allowlist) == "table"
		then allowlist :: HttpAllowlist
		else SandboxRunner.DEFAULT_HTTP_ALLOWLIST
	return SandboxEnvironment.createHttpProxy(hostHttp, list, opts)
end

function SandboxRunner.wrapGame(gameValue: unknown, allowlist: HttpAllowlist?, opts: SandboxOptions?): unknown
	return SandboxEnvironment.wrapGameWithHttpPolicy(gameValue, allowlist, opts)
end

function SandboxRunner.createEnv(bindings: Environment, opts: SandboxOptions?): Environment
	return SandboxEnvironment.create(bindings, opts)
end

function SandboxRunner.checkBudget(source: string, maxBytes: number?): (boolean, string?)
	return SandboxEnvironment.checkSourceBudget(source, maxBytes)
end

function SandboxRunner.runIsolated(source: string, bindings: Environment?, opts: SandboxOptions?): (boolean, unknown)
	return SandboxEnvironment.runIsolated(source, bindings, opts)
end

return SandboxRunner
