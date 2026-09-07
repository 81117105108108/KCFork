--!strict
-- zune run tests/physics_bulk.luau [path/to/newly-built/JoltWrapper.dll]
local runtime = zune
local ffi = runtime.ffi
local Vector3 = require("@Vector3")
local CFrame = require("@CFrame")
local structs = require("../src/external/jolt/structs")
local funcs = require("../src/external/jolt/funcs")
local path = "src/environment/game/services/JoltPhysicsService/JoltPhysicsService.luau"
local source = runtime.fs.readFile(path)
runtime.luau.compile(source) -- Also compile the complete service, not only the slices.
local function between(first: string, last: string): string
	local a = assert(source:find(first, 1, true), first)
	local b = assert(source:find(last, a + #first, true), last)
	return source:sub(a, b - 1)
end

-- Execute the production decoder/helper/render-sync block with real FFI storage
-- and datatypes, without initializing the unrelated renderer/game services.
local syncSource = between("local tempBodyPosition =", "local terrainBodies =")
	.. between("local function CalculateBodyPhysics(", "local function setGravity(")
	.. "\nreturn function()\n"
	.. between("local _nSimulated = 0", "local _syncDur =")
	.. "\nreturn _nSimulated, bulkCapacity, bulkIdsBuffer, bulkOutBuffer\nend"
local function makeSync(lib: any, parts: any, bodyInterface: any): any
	local env = setmetatable({
		ffi = ffi, structs = structs, CFrame = CFrame, Vector3 = Vector3,
		lib = lib, movingBodiesMap = parts, bodyInterface = bodyInterface,
	}, { __index = getfenv(0) })
	return runtime.luau.load(runtime.luau.compile(syncSource), { env = env, chunk_name = path })()
end
local passed = 0
local function test(name: string, fn: () -> ())
	fn()
	passed += 1
	print("PASS", name)
end
local function part(x: number?): any
	return {
		Parent = {}, Anchored = false, CFrame = CFrame.new(x or 0, 0, 0),
		AssemblyLinearVelocity = Vector3.zero, AssemblyAngularVelocity = Vector3.zero,
		__workspaceBatch = {}, __workspaceChunk = {}, __partAABB = {},
	}
end
local function mock(): (any, any, any)
	local states, calls = {}, { bulk = 0, transform = 0, linear = 0, angular = 0, active = 0 }
	local lib = {}
	function lib.JPH_BodyInterface_GetBulkTransforms(_, ids, count, out, capacity)
		calls.bulk += 1
		assert(typeof(ids) == "FFIPointer" and typeof(out) == "FFIPointer")
		assert(capacity == count * 32)
		local written = 0
		-- Reverse order ensures the consumer uses BodyID, not row alignment.
		for i = count - 1, 0, -1 do
			local id = ids:readu32(i * 4)
			local state = assert(states[id], "unselected body")
			if state.active then
				local base = written * 32
				out:writeu32(base, id)
				for j = 1, 7 do out:writef32(base + j * 4, state.pose[j]) end
				written += 1
			end
		end
		return written
	end
	function lib.JPH_BodyInterface_IsActive(_, id)
		calls.active += 1
		return if states[id].active then 1 else 0
	end
	function lib.JPH_BodyInterface_GetPositionAndRotation(_, id, pos, rot)
		calls.transform += 1
		local pose = states[id].pose
		for i = 0, 2 do pos:writef64(i * 8, pose[i + 1]) end
		for i = 0, 3 do rot:writef32(i * 4, pose[i + 4]) end
	end
	function lib.JPH_BodyInterface_GetLinearVelocity(_, id, out)
		calls.linear += 1
		for i = 0, 2 do out:writef32(i * 4, states[id].linear[i + 1]) end
	end
	function lib.JPH_BodyInterface_GetAngularVelocity(_, id, out)
		calls.angular += 1
		for i = 0, 2 do out:writef32(i * 4, states[id].angular[i + 1]) end
	end
	return lib, states, calls
end
local function state(x: number, active: boolean?): any
	return { active = active ~= false, pose = { x, 0, 0, 0, 0, 0, 1 }, linear = { 0, 0, 0 }, angular = { 0, 0, 0 } }
end

test("production bulk decoder, velocity-only changes, dirty flags, sleep/wake", function()
	local lib, states, calls = mock()
	local a, b, detached = part(), part(), part()
	detached.Parent = nil
	states[7], states[19] = state(2), state(-3)
	states[19].pose[6], states[19].pose[7] = math.sqrt(2), math.sqrt(2)
	local sync = makeSync(lib, { [a] = 7, [b] = 19, [detached] = 999 }, ffi.null)
	assert(sync() == 2)
	assert(a.CFrame.Position.X == 2 and b.CFrame.Position.X == -3)
	assert(b.CFrame:IsSameTransform(CFrame.new(-3, 0, 0) * CFrame.Angles(0, 0, math.pi / 2), 1e-5))
	assert(calls.transform == 0 and calls.active == 0 and calls.linear == 2 and calls.angular == 2)
	assert(a.__matrixDirty and a.__partAABB == nil and a.__workspaceBatch.instancesDirty and a.__workspaceChunk.instanceDataDirty)
	a.__matrixDirty, a.__workspaceBatch.instancesDirty, a.__workspaceChunk.instanceDataDirty = false, false, false
	states[7].linear, states[7].angular = { 4, 0, 0 }, { 0, 2, 0 }
	sync()
	assert(a.AssemblyLinearVelocity.X == 4 and a.AssemblyAngularVelocity.Y == 2)
	assert(not a.__matrixDirty and not a.__workspaceBatch.instancesDirty and not a.__workspaceChunk.instanceDataDirty)
	states[7].linear, states[7].angular = { 0, 0, 0 }, { 0, 0, 0 }
	sync()
	assert(a.AssemblyLinearVelocity == Vector3.zero and a.AssemblyAngularVelocity == Vector3.zero)
	assert(calls.transform == 0)
	states[7].active, states[7].pose[1] = false, 2.25
	a.AssemblyLinearVelocity, a.AssemblyAngularVelocity = Vector3.new(9, 0, 0), Vector3.new(0, 9, 0)
	assert(sync() == 1)
	assert(a.CFrame.Position.X == 2.25 and a.AssemblyLinearVelocity == Vector3.zero and a.AssemblyAngularVelocity == Vector3.zero)
	assert(calls.transform == 1)
	sync()
	assert(calls.transform == 1, "sleeping body must not re-fetch each frame")
	states[7].active, states[7].linear = true, { 3, 0, 0 }
	sync()
	assert(a.AssemblyLinearVelocity.X == 3 and calls.transform == 1)
end)

test("first-seen sleeping body final pose and legacy CalculateBodyPhysics arguments", function()
	local lib, states, calls = mock()
	local a = part()
	states[7] = state(4, false)
	a.AssemblyLinearVelocity = Vector3.new(0.00001, 0, 0)
	a.AssemblyAngularVelocity = Vector3.new(0, 0.00001, 0)
	local sync = makeSync(lib, { [a] = 7 }, ffi.null)
	assert(sync() == 0 and a.CFrame.Position.X == 4 and a.AssemblyLinearVelocity == Vector3.zero)
	assert(a.AssemblyAngularVelocity == Vector3.zero)
	sync()
	assert(calls.transform == 1 and calls.linear == 0 and calls.angular == 0)
	local env = setmetatable({ ffi = ffi, structs = structs, CFrame = CFrame, Vector3 = Vector3, lib = lib }, { __index = getfenv(0) })
	local helper = runtime.luau.load(runtime.luau.compile(
		between("local tempBodyPosition =", "local terrainBodies =")
		.. between("local function CalculateBodyPhysics(", "local function setGravity(")
		.. "\nreturn CalculateBodyPhysics"
	), { env = env })()
	assert(helper(a, ffi.null, 7) == nil)
	states[7].active = true
	local cf, linear, angular = helper(a, ffi.null, 7)
	assert(cf.Position.X == 4 and linear == Vector3.zero and angular == Vector3.zero)
	a.Anchored = true
	assert(helper(a, ffi.null, 7) == nil)
end)

test("zero returned rows accepted; capacity reused and grows geometrically", function()
	local lib, states, calls = mock()
	local parts = {}
	local sync = makeSync(lib, parts, ffi.null)
	assert(sync() == 0 and calls.bulk == 0)
	for i = 1, 64 do parts[part()] = i; states[i] = state(0, false) end
	local n, cap, ids, out = sync()
	assert(n == 0 and cap == 64 and calls.active == 0)
	local _, cap2, ids2, out2 = sync()
	assert(cap2 == cap and ids2 == ids and out2 == out)
	parts[part()], states[65] = 65, state(0, false)
	local _, cap3 = sync()
	assert(cap3 == 128)
end)

test("invalid counts/rows and missing or throwing bulk call fall back before applying", function()
	for _, bad in { -1, 0.5, 2, math.huge, 0 / 0, "bad", false } do
		local lib, states, calls = mock()
		local a = part()
		states[7] = state(5)
		lib.JPH_BodyInterface_GetBulkTransforms = function() return bad end
		makeSync(lib, { [a] = 7 }, ffi.null)()
		assert(a.CFrame.Position.X == 5 and calls.transform == 1 and calls.active == 1)
	end
	for _, mode in { "missing", "throws", "foreign" } do
		local lib, states, calls = mock()
		local a = part()
		states[7] = state(5)
		lib.JPH_BodyInterface_GetBulkTransforms = if mode == "missing" then nil else function(_, _, _, out)
			if mode == "throws" then error("bulk unavailable") end
			out:writeu32(0, 999)
			return 1
		end
		makeSync(lib, { [a] = 7 }, ffi.null)()
		assert(a.CFrame.Position.X == 5 and calls.transform == 1)
	end
	local lib, states, calls = mock()
	local a, b = part(), part()
	states[7], states[19] = state(5), state(8)
	local fill = lib.JPH_BodyInterface_GetBulkTransforms
	lib.JPH_BodyInterface_GetBulkTransforms = function(...)
		local written = fill(...)
		local out = select(4, ...)
		out:writeu32(32, out:readu32(0))
		return written
	end
	makeSync(lib, { [a] = 7, [b] = 19 }, ffi.null)()
	assert(a.CFrame.Position.X == 5 and b.CFrame.Position.X == 8 and calls.transform == 2)
end)

test("fallback sleep transition and ownership selection", function()
	local lib, states, calls = mock()
	lib.JPH_BodyInterface_GetBulkTransforms = nil
	local a, remote = part(), part(99)
	local parts = { [a] = 7 }
	states[7] = state(1)
	local sync = makeSync(lib, parts, ffi.null)
	sync()
	states[7].active, states[7].pose[1] = false, 1.5
	sync()
	assert(a.CFrame.Position.X == 1.5 and calls.transform == 2)
	sync()
	assert(calls.transform == 2 and remote.CFrame.Position.X == 99)
	parts[a] = nil
	states[7].active = true
	sync()
	assert(calls.transform == 2)
end)

local dll = runtime.process.args[2]
if not dll then
	print("SKIP native runtime and eager-loader checks: supply newly-built DLL path")
	print(passed, "physics bulk tests passed")
	return
end
local native = ffi.dlopen(dll, funcs)
test("production loader with eager missing optional/required symbols", function()
	local wrapper = runtime.fs.readFile("src/external/jolt/wrapper.luau")
	for _, mode in { "current", "old", "broken" } do
		local attempts = 0
		local fakeFFI = setmetatable({ dlopen = function(_, definitions)
			attempts += 1
			local defs = table.clone(definitions)
			if mode == "old" and defs.JPH_BodyInterface_GetBulkTransforms then
				defs.MissingPhase1Symbol = defs.JPH_BodyInterface_GetBulkTransforms
			end
			if mode == "broken" then defs.MissingRequiredSymbol = funcs.JPH_Init end
			return ffi.dlopen(dll, defs)
		end }, { __index = ffi })
		local env = setmetatable({ zune = { ffi = fakeFFI }, require = function(name)
			if name == "@zembed" then return { IsEmbedded = function() return true end, RuntimePath = function() return dll end } end
			return if name == "./funcs" then funcs else structs
		end }, { __index = getfenv(0) })
		local ok, result = pcall(function()
			return runtime.luau.load(runtime.luau.compile(wrapper), { env = env })()
		end)
		assert(ok == (mode ~= "broken"))
		assert(attempts == (if mode == "current" then 1 else 2))
		if ok then assert((result.lib.JPH_BodyInterface_GetBulkTransforms ~= nil) == (mode == "current")) end
	end
end)

test("native active compaction, bounds/null/zero and production sync against DLL", function()
	assert(native.JPH_Init() == 1)
	local bp = native.JPH_BroadPhaseLayerInterfaceTable_Create(1, 1)
	native.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(bp, 0, 0)
	local pair = native.JPH_ObjectLayerPairFilterTable_Create(1)
	native.JPH_ObjectLayerPairFilterTable_EnableCollision(pair, 0, 0)
	local filter = native.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(bp, 1, pair, 1)
	local system = native.JPH_PhysicsSystem_Create(structs.JPH_PhysicsSystemSettings:new({
		maxBodies = 128, numBodyMutexes = 0, maxBodyPairs = 128, maxContactConstraints = 128,
		_padding = 0, broadPhaseLayerInterface = bp, objectLayerPairFilter = pair, objectVsBroadPhaseLayerFilter = filter,
	}))
	assert(system ~= ffi.null)
	local bi = native.JPH_PhysicsSystem_GetBodyInterface(system)
	local shape = native.JPH_SphereShape_Create(0.5)
	local pos, rot, velocity = ffi.alloc(24, 8), ffi.alloc(16, 4), ffi.alloc(12, 4)
	for i = 0, 2 do pos:writef64(i * 8, 0); velocity:writef32(i * 4, 0) end
	for i = 0, 3 do rot:writef32(i * 4, if i == 3 then 1 else 0) end
	local bodyIDs = {}
	for i = 1, 3 do
		pos:writef64(0, i * 3)
		local settings = native.JPH_BodyCreationSettings_Create3(shape, pos, rot, 2, 0)
		local body = native.JPH_BodyInterface_CreateBody(bi, settings)
		assert(body ~= ffi.null)
		local id = native.JPH_Body_GetID(body)
		bodyIDs[i] = id
		native.JPH_BodyInterface_AddBody(bi, id, if i == 1 then 1 else 0)
		native.JPH_BodyCreationSettings_Destroy(settings)
	end
	assert(native.JPH_BodyInterface_IsActive(bi, bodyIDs[1]) == 0)
	assert(native.JPH_BodyInterface_IsActive(bi, bodyIDs[2]) == 1)
	local ids, out = ffi.alloc(12, 4), ffi.alloc(100, 4)
	for i, id in bodyIDs do ids:writeu32((i - 1) * 4, id) end
	local bulk = native.JPH_BodyInterface_GetBulkTransforms
	for i = 0, 99 do out:writeu8(i, 0xA5) end
	assert(bulk(bi, ids, 3, out, 0) == 0)
	assert(bulk(bi, ids, 3, out, 31) == 0)
	assert(bulk(bi, ids, 0, out, 96) == 0)
	assert(bulk(ffi.null, ids, 3, out, 96) == 0)
	assert(bulk(bi, ffi.null, 3, out, 96) == 0)
	assert(bulk(bi, ids, 3, ffi.null, 96) == 0)
	for i = 0, 99 do assert(out:readu8(i) == 0xA5) end
	assert(bulk(bi, ids, 3, out, 33) == 1)
	assert(out:readu32(0) == bodyIDs[2] and out:readf32(4) == 6 and out:readf32(28) == 1)
	for i = 32, 99 do assert(out:readu8(i) == 0xA5, "native write past complete row") end
	assert(bulk(bi, ids, 3, out, 96) == 2)
	assert(out:readu32(32) == bodyIDs[3] and out:readf32(36) == 9)
	for i = 64, 99 do assert(out:readu8(i) == 0xA5) end
	assert(bulk(bi, ids, 1, out, 32) == 0)

	local a, b = part(3), part()
	local calls = { transform = 0, linear = 0, angular = 0 }
	local counted = setmetatable({}, { __index = function(_, key) return native[key] end })
	for key, counter in { JPH_BodyInterface_GetPositionAndRotation = "transform", JPH_BodyInterface_GetLinearVelocity = "linear", JPH_BodyInterface_GetAngularVelocity = "angular" } do
		counted[key] = function(...)
			calls[counter] += 1
			return native[key](...)
		end
	end
	local sync = makeSync(counted, { [a] = bodyIDs[1], [b] = bodyIDs[2] }, bi)
	assert(sync() == 1 and b.CFrame.Position.X == 6)
	local initialTransforms = calls.transform
	velocity:writef32(0, 2)
	native.JPH_BodyInterface_SetLinearVelocity(bi, bodyIDs[2], velocity)
	native.JPH_BodyInterface_SetAngularVelocity(bi, bodyIDs[2], velocity)
	sync()
	assert(b.AssemblyLinearVelocity.X == 2 and b.AssemblyAngularVelocity.X == 2)
	assert(calls.transform == initialTransforms)
	velocity:writef32(0, 0)
	native.JPH_BodyInterface_SetLinearVelocity(bi, bodyIDs[2], velocity)
	native.JPH_BodyInterface_SetAngularVelocity(bi, bodyIDs[2], velocity)
	sync()
	assert(b.AssemblyLinearVelocity == Vector3.zero and b.AssemblyAngularVelocity == Vector3.zero)
	assert(calls.transform == initialTransforms)
	native.JPH_BodyInterface_ActivateBody(bi, bodyIDs[1])
	assert(sync() == 2)
	-- Let real Jolt transition to sleeping, with no gravity or velocity.
	native.JPH_PhysicsSystem_SetGravity(system, velocity)
	local config = ffi.alloc(32, 8)
	for i = 0, 31 do config:writeu8(i, 0) end
	local jobs = native.JPH_JobSystemThreadPool_Create(config)
	assert(jobs ~= ffi.null)
	for _ = 1, 180 do native.JPH_PhysicsSystem_Update(system, 1 / 60, 1, jobs) end
	assert(native.JPH_BodyInterface_IsActive(bi, bodyIDs[2]) == 0)
	b.AssemblyLinearVelocity = Vector3.new(8, 0, 0)
	assert(sync() == 0)
	assert(b.AssemblyLinearVelocity == Vector3.zero and b.AssemblyAngularVelocity == Vector3.zero)
	local asleepTransforms = calls.transform
	sync()
	assert(calls.transform == asleepTransforms)
	for _, id in bodyIDs do native.JPH_BodyInterface_RemoveAndDestroyBody(bi, id) end
	native.JPH_JobSystem_Destroy(jobs)
	native.JPH_PhysicsSystem_Destroy(system)
	native.JPH_Shape_Destroy(shape)
	native.JPH_Shutdown()
end)
print(passed, "physics bulk tests passed")
