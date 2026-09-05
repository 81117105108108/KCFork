--!strict

-- Owners are tables; pointers are opaque FFI values (userdata, buffer, or address).
-- Destructors must not yield or capture their owner. See docs/resource-ownership.md.
export type Owner = {}
export type Destructor = (ptr: any) -> ()
export type ResourceTracker = {
	Track: (self: ResourceTracker, owner: Owner, ptr: any, destructor: Destructor) -> (),
	Untrack: (self: ResourceTracker, owner: Owner) -> (),
	Collect: (self: ResourceTracker, owner: Owner) -> (),
	Release: (self: ResourceTracker, owner: Owner, ptr: any) -> (),
	Sweep: (self: ResourceTracker) -> (),
	CollectAll: (self: ResourceTracker) -> (),
}

type Resource = { ptr: any, destructor: Destructor, group: Group }
type Group = { owner: { [number]: Owner }, resources: { Resource } }

local function validateOwner(owner: Owner): ()
	assert(type(owner) == "table", "ResourceTracker owner must be a table")
end

local function validatePointer(ptr: any): ()
	local kind = type(ptr)
	assert(kind == "userdata" or kind == "buffer" or kind == "number", "Invalid native pointer")
	if kind == "number" then
		assert(ptr > 0 and ptr <= 9007199254740991 and ptr % 1 == 0, "Invalid native address")
	end
end

local function new(): ResourceTracker
	-- Keep records alive independently of weak owners: otherwise GC loses the
	-- destructor along with the owner. No strong path may lead back to an owner.
	local owners = setmetatable({} :: { [Owner]: Group }, { __mode = "k" })
	local groups: { [Group]: boolean } = {}
	local claims: { [any]: Resource } = {}
	local collecting = false
	local tracker = {} :: ResourceTracker

	local function release(selected: { Group }): ()
		if #selected == 0 then
			return
		end
		assert(not collecting, "ResourceTracker cleanup is already running")
		collecting = true
		-- Detach every selected group first so recursive Collect is a no-op.
		for _, group in ipairs(selected) do
			local owner = group.owner[1]
			if owner then
				owners[owner] = nil
			end
			groups[group] = nil
			table.clear(group.owner)
		end

		local failures: { string } = {}
		for _, group in ipairs(selected) do
			for index = #group.resources, 1, -1 do
				local resource = group.resources[index]
				-- A yielding callback must not strand the registry in its busy state.
				-- Coroutines execute on the calling native thread, not a worker thread.
				local cleanup = coroutine.create(resource.destructor)
				local ok, failure = coroutine.resume(cleanup, resource.ptr)
				if coroutine.status(cleanup) == "suspended" then
					coroutine.close(cleanup)
					ok = false
					failure = "ResourceTracker destructor must not yield"
				end
				claims[resource.ptr] = nil
				if not ok then
					local printable, message = pcall(tostring, failure)
					table.insert(failures, if printable then message else "Unprintable destructor error")
				end
			end
			table.clear(group.resources)
		end
		collecting = false
		if #failures > 0 then
			-- Never retry: a throwing native destructor may already have freed memory.
			error("ResourceTracker cleanup failed: " .. table.concat(failures, "; "), 2)
		end
	end

	function tracker.Track(_self: ResourceTracker, owner: Owner, ptr: any, destructor: Destructor): ()
		validateOwner(owner)
		validatePointer(ptr)
		assert(type(destructor) == "function", "ResourceTracker destructor must be a function")
		assert(not collecting, "Cannot track resources during cleanup")
		assert(not rawget(owner, "Destroyed") and not rawget(owner, "_destroying"), "Cannot track resources on a destroyed owner")
		local group: Group? = owners[owner]
		local claimed = claims[ptr]
		if claimed then
			assert(claimed.group == group, "Native pointer already belongs to another owner")
			assert(claimed.destructor == destructor, "Native pointer already has a different destructor")
			return
		end
		local target: Group = group or { owner = { owner }, resources = {} }
		if not group then
			setmetatable(target.owner, { __mode = "v" })
			owners[owner] = target
			groups[target] = true
		end
		local resource: Resource = { ptr = ptr, destructor = destructor, group = target }
		table.insert(target.resources, resource)
		claims[ptr] = resource
	end

	function tracker.Untrack(_self: ResourceTracker, owner: Owner): ()
		validateOwner(owner)
		assert(not collecting, "Cannot transfer resources during cleanup")
		local group = owners[owner]
		if not group then
			return
		end
		owners[owner] = nil
		groups[group] = nil
		for _, resource in ipairs(group.resources) do
			claims[resource.ptr] = nil
		end
		table.clear(group.resources)
		table.clear(group.owner)
	end

	function tracker.Collect(_self: ResourceTracker, owner: Owner): ()
		validateOwner(owner)
		local group = owners[owner]
		if group then
			release({ group })
		end
	end

	function tracker.Sweep(_self: ResourceTracker): ()
		local selected: { Group } = {}
		for group in pairs(groups) do
			if group.owner[1] == nil then
				table.insert(selected, group)
			end
		end
		release(selected)
	end

	function tracker.Release(_self: ResourceTracker, owner: Owner, ptr: any): ()
		validateOwner(owner)
		assert(not collecting, "Cannot release resources during cleanup")
		local resource = claims[ptr]
		if not resource then return end
		local group = owners[owner]
		assert(group == resource.group, "Native pointer belongs to another owner")
		for index, candidate in ipairs(group.resources) do
			if candidate == resource then table.remove(group.resources, index); break end
		end
		if #group.resources == 0 then
			owners[owner] = nil
			groups[group] = nil
			table.clear(group.owner)
		end
		release({ { owner = {}, resources = { resource } } })
	end

	function tracker.CollectAll(_self: ResourceTracker): ()
		local selected: { Group } = {}
		for group in pairs(groups) do
			table.insert(selected, group)
		end
		release(selected)
	end

	return table.freeze(tracker)
end

return table.freeze({ new = new, shared = new() })
