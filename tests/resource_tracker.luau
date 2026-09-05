--!strict

local ResourceTracker = require("../src/engine/ffi/ResourceTracker")
local runtime = getfenv(0).zune :: { luau: { garbagecollect: () -> () } }
local passed = 0

local function test(name: string, callback: () -> ()): ()
	callback()
	passed += 1
	print("PASS", name)
end

local function expectError(callback: () -> (), message: string): ()
	local ok, failure = pcall(function(): unknown
		callback()
		return nil
	end)
	assert(not ok, "Expected error: " .. message)
	assert(string.find(tostring(failure), message, 1, true), tostring(failure))
end

local function collectGarbage(): ()
	-- More than one cycle handles weak-table clearing after temporary stack roots.
	for _ = 1, 3 do
		runtime.luau.garbagecollect()
	end
end

test("collect releases in reverse order exactly once", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local released: { number } = {}
	local function free(ptr: any): () table.insert(released, ptr) end
	tracker:Track(owner, 101, free)
	tracker:Track(owner, 102, free)
	tracker:Collect(owner)
	tracker:Collect(owner)
	tracker:Sweep()
	tracker:CollectAll()
	assert(#released == 2 and released[1] == 102 and released[2] == 101)
end)

test("same registration is idempotent", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	local function free(_ptr: any): () count += 1 end
	local ptr = buffer.create(8)
	tracker:Track(owner, ptr, free)
	tracker:Track(owner, ptr, free)
	tracker:Collect(owner)
	assert(count == 1)
end)

test("conflicting ownership and destructors are rejected", function(): ()
	local tracker, first, second = ResourceTracker.new(), {}, {}
	local released: { number } = {}
	local function free(ptr: any): () table.insert(released, ptr) end
	tracker:Track(first, 1, free)
	expectError(function(): () tracker:Track(second, 1, free) end, "another owner")
	expectError(function(): () tracker:Track(first, 1, function(_ptr: any): () error("wrong destructor") end) end, "different destructor")
	tracker:CollectAll()
	assert(#released == 1)
end)

test("untrack transfers responsibility without freeing", function(): ()
	local tracker, first, second = ResourceTracker.new(), {}, {}
	local count = 0
	local function free(_ptr: any): () count += 1 end
	tracker:Track(first, 1, free)
	tracker:Untrack(first)
	tracker:Untrack(first)
	tracker:Collect(first)
	assert(count == 0)
	tracker:Track(second, 1, free)
	tracker:CollectAll()
	assert(count == 1)
end)

test("GC clears weak owners without losing destructors", function(): ()
	local tracker = ResourceTracker.new()
	local count = 0
	local observed = setmetatable({} :: { [number]: {} }, { __mode = "v" })
	local function allocate(): ()
		local owner = {}
		observed[1] = owner
		tracker:Track(owner, buffer.create(8), function(_ptr: any): () count += 1 end)
	end
	allocate()
	collectGarbage()
	assert(observed[1] == nil, "Tracker retained its owner")
	assert(count == 0, "Cleanup must occur on explicit safe-point sweep")
	tracker:Sweep()
	tracker:Sweep()
	assert(count == 1)
end)

test("live owners survive sweep", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	tracker:Track(owner, 1, function(_ptr: any): () count += 1 end)
	collectGarbage()
	tracker:Sweep()
	assert(count == 0)
	tracker:Collect(owner)
	assert(count == 1)
end)

test("destructor failure does not skip remaining resources", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	tracker:Track(owner, 1, function(_ptr: any): () count += 1 end)
	tracker:Track(owner, 2, function(_ptr: any): () count += 1; error("native failure") end)
	expectError(function(): () tracker:Collect(owner) end, "native failure")
	tracker:CollectAll()
	assert(count == 2, "Failed destruction must not be retried")
end)

test("collect all drains other owners despite failure", function(): ()
	local tracker, first, second = ResourceTracker.new(), {}, {}
	local count = 0
	tracker:Track(first, 1, function(_ptr: any): () error("native failure") end)
	tracker:Track(second, 2, function(_ptr: any): () count += 1 end)
	expectError(function(): () tracker:CollectAll() end, "native failure")
	tracker:CollectAll()
	assert(count == 1)
end)

test("unprintable errors do not interrupt cleanup", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	tracker:Track(owner, 1, function(_ptr: any): () count += 1 end)
	tracker:Track(owner, 2, function(_ptr: any): ()
		error(setmetatable({}, { __tostring = function(): string error("cannot stringify") end }))
	end)
	expectError(function(): () tracker:Collect(owner) end, "Unprintable destructor error")
	assert(count == 1)
end)

test("recursive collection of same owner is harmless", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	tracker:Track(owner, 1, function(_ptr: any): () count += 1; tracker:Collect(owner) end)
	tracker:Collect(owner)
	assert(count == 1)
end)

test("registration during cleanup is rejected without orphaning records", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	tracker:Track(owner, 1, function(_ptr: any): ()
		tracker:Track(owner, 2, function(_other: any): () error("must not register") end)
	end)
	expectError(function(): () tracker:Collect(owner) end, "during cleanup")
	tracker:CollectAll()
	local count = 0
	tracker:Track(owner, 2, function(_ptr: any): () count += 1 end)
	tracker:Collect(owner)
	assert(count == 1, "Registry must recover after cleanup failure")
end)

test("yielding destructors cannot strand the registry", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local count = 0
	tracker:Track(owner, 1, function(_ptr: any): () count += 1 end)
	tracker:Track(owner, 2, function(_ptr: any): () coroutine.yield(); error("must not resume") end)
	expectError(function(): () tracker:Collect(owner) end, "must not yield")
	assert(count == 1)
	tracker:Track(owner, 3, function(_ptr: any): () count += 1 end)
	tracker:Collect(owner)
	assert(count == 2)
end)

test("empty cleanup operations are harmless", function(): ()
	local tracker = ResourceTracker.new()
	tracker:Collect({})
	tracker:Untrack({})
	tracker:Sweep()
	tracker:CollectAll()
end)

test("invalid addresses are rejected before mutation", function(): ()
	local tracker, owner = ResourceTracker.new(), {}
	local function free(_ptr: any): () error("invalid pointer registered") end
	for _, ptr in ipairs({ 0, -1, 0.5, math.huge, -math.huge, 0 / 0, 9007199254740992 }) do
		expectError(function(): () tracker:Track(owner, ptr, free) end, "Invalid native address")
	end
	for _, ptr in ipairs({ false, "address", {} } :: { any }) do
		expectError(function(): () tracker:Track(owner, ptr, free) end, "Invalid native pointer")
	end
	expectError(function(): () tracker:Track(owner, nil, free) end, "Invalid native pointer")
	tracker:CollectAll()
end)

test("invalid owners and destructors are rejected", function(): ()
	local tracker = ResourceTracker.new()
	local function free(_ptr: any): () error("invalid registration") end
	expectError(function(): () tracker:Track(nil :: any, 1, free) end, "owner must be a table")
	expectError(function(): () tracker:Track(1 :: any, 1, free) end, "owner must be a table")
	expectError(function(): () tracker:Track({}, 1, nil :: any) end, "destructor must be a function")
	expectError(function(): () tracker:Track({ Destroyed = true }, 1, free) end, "destroyed owner")
	tracker:CollectAll()
end)

test("independent registries and shared registry are available", function(): ()
	assert(ResourceTracker.shared ~= ResourceTracker.new())
	assert(table.isfrozen(ResourceTracker.shared))
	assert(table.isfrozen(ResourceTracker))
end)

print(string.format("%d resource tracker tests passed", passed))
