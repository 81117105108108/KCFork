local ConstraintRetry = {}
local states = setmetatable({}, { __mode = "k" })

local function stateFor(owner)
	local state = states[owner]
	if not state then
		state = { generation = 0, pending = false, connections = {} }
		states[owner] = state
	end
	return state
end

function ConstraintRetry.Cancel(owner)
	local state = stateFor(owner)
	state.generation += 1
	state.pending = false
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)
end

function ConstraintRetry.Track(owner, connection)
	if connection then
		table.insert(stateFor(owner).connections, connection)
	end
	return connection
end

function ConstraintRetry.Schedule(owner, callback, delaySeconds)
	local state = stateFor(owner)
	if state.pending then
		return false
	end

	state.pending = true
	local generation = state.generation

	local delay = math.max(delaySeconds or 0.05, 0.001)
	task.delay(delay, function()
		if state.generation ~= generation then
			return
		end
		state.pending = false
		callback()
	end)
	return true
end

return ConstraintRetry
