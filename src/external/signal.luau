--!strict
-- KinemiumSignal.lua
local task = getfenv(0).task
type ConnectionState = {
	Connected: boolean, Priority: number, _signal: SignalState?,
	_fn: ((...any) -> ())?, [string]: any,
}
type SignalState = {
	_connections: { ConnectionState }?, _queuedFires: { { any } }?,
	_history: { { any } }?, [string]: any,
}
local Signal = { __type = "KinemiumSignal" }
Signal.__index = Signal

-- connection object
local Connection = { __type = "KinemiumConnection" }
Connection.__index = Connection

function Connection.new(signal: SignalState, fn: (...any) -> (), priority: number?): ConnectionState
	local self = {} :: ConnectionState
	setmetatable(self, Connection)
	self._signal = signal
	self._fn = fn
	self.Connected = true
	self.Priority = priority or 0
	return (self :: unknown) :: ConnectionState
end

function Connection.Disconnect(self: ConnectionState): ()
	if not self.Connected then
		return
	end
	self.Connected = false
	local sig = self._signal
	if sig and sig._connections then
		for i = #sig._connections, 1, -1 do
			if sig._connections[i] == self then
				table.remove(sig._connections, i)
				break
			end
		end
	end
	self._signal = nil
	self._fn = nil
end

function Connection:Fire(...)
	if self.Connected and self._fn then
		self._fn(...)
	end
end

function Connection:SetPriority(priority)
	self.Priority = priority
	if self._signal then
		self._signal:_sortConnections()
	end
end

-- signal container
function Signal.new(): SignalState
	local self = {} :: SignalState
	setmetatable(self, Signal)
	self._paused = false
	self._debugMode = false
	return (self :: unknown) :: SignalState
end

function Signal:Connect(fn, priority)
	local conn = Connection.new(self, fn, priority)
	if not self._connections then
		self._connections = { conn }
	else
		table.insert(self._connections, conn)
		if priority or conn.Priority ~= 0 then
			self:_sortConnections()
		end
	end
	return conn
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait(timeout)
	local thread = coroutine.running()
	local conn
	local timedOut = false

	conn = self:Connect(function(...)
		if not timedOut then
			conn:Disconnect()
			task.spawn(thread, true, ...)
		end
	end)

	if timeout then
		task.delay(timeout, function()
			if conn.Connected then
				timedOut = true
				conn:Disconnect()
				task.spawn(thread, false)
			end
		end)
	end

	return coroutine.yield()
end

function Signal.Fire(self: SignalState, ...: any): ()
	if self._paused then
		local queued = self._queuedFires or {}
		self._queuedFires = queued
		table.insert(queued, { ... })
		return
	end

	-- Avoid {...} allocation if possible
	local args = nil
	local hasArgs = false

	-- Apply filters
	if self._filters then
		args = { ... }
		hasArgs = true
		for _, filter in ipairs(self._filters) do
			local shouldContinue, modifiedArgs = filter(table.unpack(args))
			if not shouldContinue then
				return
			end
			if modifiedArgs then
				args = modifiedArgs
			end
		end
	end

	-- Apply middlewares
	if self._middlewares then
		if not hasArgs then
			args = { ... }
			hasArgs = true
		end
		for _, middleware in ipairs(self._middlewares) do
			args = { middleware(table.unpack(args)) }
		end
	end

	-- Store in history
	if self._historyLimit and self._historyLimit > 0 then
		if not hasArgs then
			args = { ... }
			hasArgs = true
		end
		local history = self._history or {}
		self._history = history
		local entry: { any } = { os.clock(), args }
		table.insert(history, 1, entry)
		if #history > self._historyLimit then
			table.remove(history)
		end
	end

	if self._debugMode then
		if not hasArgs then
			args = { ... }
			hasArgs = true
		end
		local count = self._connections and #self._connections or 0
		print(string.format("[Signal Debug] Firing with %d args to %d listeners", #args, count))
	end

	if self._connections then
		for _, conn in ipairs(self._connections) do
			if hasArgs then
				conn:Fire(table.unpack(args))
			else
				conn:Fire(...)
			end
		end
	end
end

function Signal:FireDeferred(...)
	local args = { ... }
	task.defer(function()
		self:Fire(table.unpack(args))
	end)
end

function Signal:FireParallel(...)
	if not self._connections then
		return
	end
	local args = { ... }
	for _, conn in ipairs(self._connections) do
		task.spawn(function()
			conn:Fire(table.unpack(args))
		end)
	end
end

function Signal:Pause()
	self._paused = true
end

function Signal.Resume(self: SignalState): ()
	self._paused = false
	if self._queuedFires then
		for _, args in ipairs(self._queuedFires) do
			self:Fire(table.unpack(args))
		end
		self._queuedFires = nil
	end
end

function Signal:IsPaused()
	return self._paused
end

function Signal:AddFilter(filterFn)
	if not self._filters then
		self._filters = {}
	end
	table.insert(self._filters, filterFn)
	return function()
		if not self._filters then
			return
		end
		for i, f in ipairs(self._filters) do
			if f == filterFn then
				table.remove(self._filters, i)
				break
			end
		end
	end
end

function Signal:AddMiddleware(middlewareFn)
	if not self._middlewares then
		self._middlewares = {}
	end
	table.insert(self._middlewares, middlewareFn)
	return function()
		if not self._middlewares then
			return
		end
		for i, m in ipairs(self._middlewares) do
			if m == middlewareFn then
				table.remove(self._middlewares, i)
				break
			end
		end
	end
end

function Signal:GetHistory(count)
	if not self._history then
		return {}
	end
	count = count or #self._history
	local result = {}
	for i = 1, math.min(count, #self._history) do
		table.insert(result, self._history[i])
	end
	return result
end

function Signal:SetHistoryLimit(limit)
	self._historyLimit = limit
	if self._history then
		while #self._history > limit do
			table.remove(self._history)
		end
	end
end

function Signal.ClearHistory(self: SignalState): ()
	self._history = nil
end

function Signal:SetDebugMode(enabled)
	self._debugMode = enabled
end

function Signal.DisconnectAll(self: SignalState): ()
	if self._connections then
		for i = #self._connections, 1, -1 do
			self._connections[i]:Disconnect()
		end
		self._connections = nil
	end
end

function Signal:GetConnectionCount()
	return self._connections and #self._connections or 0
end

function Signal:FireOncePerPress(id, currentState, ...)
	if not self._prevState then
		self._prevState = {}
	end
	if not self._prevState[id] then
		self._prevState[id] = 0
	end

	local state = 0
	if type(currentState) == "boolean" then
		state = currentState and 1 or 0
	elseif type(currentState) == "number" then
		state = (currentState ~= 0) and 1 or 0
	else
		error("FireOncePerPress: currentState must be boolean or number")
	end

	if state == 1 and self._prevState[id] == 0 then
		self:Fire(...)
	end

	self._prevState[id] = state
end

function Signal:ConnectThrottled(fn, cooldown)
	local lastFire = 0
	return self:Connect(function(...)
		local now = os.clock()
		if now - lastFire >= cooldown then
			lastFire = now
			fn(...)
		end
	end)
end

function Signal:ConnectDebounced(fn, delay)
	local scheduled = nil
	return self:Connect(function(...)
		local args = { ... }
		if scheduled then
			task.cancel(scheduled)
		end
		scheduled = task.delay(delay, function()
			fn(table.unpack(args))
			scheduled = nil
		end)
	end)
end

function Signal:ConnectConditional(condition, fn)
	return self:Connect(function(...)
		if condition(...) then
			fn(...)
		end
	end)
end

function Signal:Map(transformFn)
	local mappedSignal = Signal.new()
	self:Connect(function(...)
		local result = { transformFn(...) }
		mappedSignal:Fire(table.unpack(result))
	end)
	return mappedSignal
end

function Signal:Merge(otherSignal)
	local mergedSignal = Signal.new()
	self:Connect(function(...)
		mergedSignal:Fire(...)
	end)
	otherSignal:Connect(function(...)
		mergedSignal:Fire(...)
	end)
	return mergedSignal
end

function Signal._sortConnections(self: SignalState): ()
	if self._connections then
		table.sort(self._connections, function(a, b)
			return a.Priority > b.Priority
		end)
	end
end

function Signal:Destroy()
	self:DisconnectAll()
	self._prevState = nil
	self._queuedFires = nil
	self._filters = nil
	self._middlewares = nil
	self._history = nil
	setmetatable(self, nil)
end

Signal.__type = "KinemiumSignal"
Connection.__type = "KinemiumConnection"

export type Signal = typeof(Signal.new())
export type Connection = typeof(Connection.new(Signal.new(), function() end))

return Signal
