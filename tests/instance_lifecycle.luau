--!strict

local runtime = getfenv(0).zune
local resources = require("../src/engine/ffi/ResourceTracker").shared
local lifecycle = require("../src/engine/ffi/InstanceLifecycle")
local function loadModule(path: string, imports: { [string]: any }): any
	local env = setmetatable({
		_G = { zune = runtime }, task = runtime.task,
		require = function(name: string): any assert(imports[name], name); return imports[name] end,
	}, { __index = getfenv(0) })
	return runtime.luau.load(runtime.luau.compile(runtime.fs.readFile(path)), { env = env, chunk_name = path })()
end
local signal = loadModule("src/external/signal.luau", {})
local Instance = loadModule("src/environment/class/Instance.luau", {
	["@Kinemium.signal"] = signal,
	["../../engine/ffi/InstanceLifecycle"] = lifecycle,
})
local passed = 0
local function test(name: string, callback: () -> ()): ()
	callback()
	resources:CollectAll()
	passed += 1
	print("PASS", name)
end

test("real Instance destruction drains children and legacy aliases", function(): ()
	local root, child = Instance.new("Folder"), Instance.new("Part")
	child.Parent = root
	local order: { string } = {}
	root.Destroying:Connect(function(): () table.insert(order, "event") end)
	resources:Track(root, 1, function(_ptr: any): () table.insert(order, "root") end)
	resources:Track(child, 2, function(_ptr: any): () table.insert(order, "child") end)
	root:destroy()
	root:Destroy()
	assert(table.concat(order, ",") == "event,child,root")
	assert(root.Destroyed and child.Destroyed)
	assert(next(rawget(root, "_childByName") or {}) == nil)
end)

test("callback errors cannot skip native or child cleanup", function(): ()
	local root, child = Instance.new("Folder"), Instance.new("Part")
	child.Parent = root
	local count = 0
	resources:Track(root, 1, function(_ptr: any): () count += 1 end)
	resources:Track(child, 2, function(_ptr: any): () count += 1 end)
	root.Destroying:Connect(function(): () error("listener failure") end)
	local ok, failure = pcall(root.Destroy, root)
	assert(not ok and string.find(tostring(failure), "listener failure", 1, true))
	assert(root.Destroyed and child.Destroyed and count == 2)
	root:Destroy()
end)

test("recursive Destroy is idempotent", function(): ()
	local owner = Instance.new("Part")
	local count = 0
	owner.Destroying:Connect(function(): () owner:Destroy() end)
	resources:Track(owner, 1, function(_ptr: any): () count += 1 end)
	owner:Destroy()
	assert(count == 1)
end)

test("failed Parent notification still removes hierarchy references", function(): ()
	local parent, child = Instance.new("Folder"), Instance.new("Part")
	child.Parent = parent
	child.AncestryChanged:Connect(function(): () error("ancestry failure") end)
	local ok = pcall(child.Destroy, child)
	assert(not ok and child.Destroyed)
	assert(#parent:GetChildren() == 0 and parent:FindFirstChild("Part") == nil)
	parent:Destroy()
end)

test("destroying owners reject new resources and reparenting", function(): ()
	local parent, child = Instance.new("Folder"), Instance.new("Part")
	parent.Destroying:Connect(function(): ()
		assert(not pcall(function(): () child.Parent = parent end))
		assert(not pcall(function(): () resources:Track(parent, 3, function(_ptr: any): () error("must not register") end) end))
	end)
	parent:Destroy()
	assert(not pcall(function(): () child.Parent = parent end))
	child:Destroy()
end)

test("single pointer release preserves unrelated owned resources", function(): ()
	local owner = Instance.new("Part")
	local order: { number } = {}
	local function free(ptr: any): () table.insert(order, ptr) end
	resources:Track(owner, 1, free)
	resources:Track(owner, 2, free)
	resources:Release(owner, 1)
	resources:Release(owner, 1)
	assert(#order == 1 and order[1] == 1)
	owner:Destroy()
	assert(#order == 2 and order[2] == 2)
end)

test("Part replacement and cloning own independent native resources", function(): ()
	local allocated: { buffer } = {}
	local freed: { [buffer]: boolean } = {}
	local failAllocation = false
	local function allocate(...: any): any
		if failAllocation then return runtime.ffi.null end
		local pointer = buffer.create(8)
		table.insert(allocated, pointer)
		return pointer
	end
	local function free(pointer: any): ()
		assert(not freed[pointer], "Double free")
		freed[pointer] = true
	end
	local vector3 = { new = function(x: number, y: number, z: number): any return { X = x, Y = y, Z = z } end }
	local Part = loadModule("src/environment/class/list/Part.luau", {
		["../../../engine/ffi/ResourceTracker"] = { shared = resources },
		["@Vector3"] = vector3, ["@Color3"] = vector3,
		["@CFrame"] = { new = function(x: number, y: number, z: number): any
			return { Position = vector3.new(x, y, z), ToOrientation = function(): (number, number, number) return 0, 0, 0 end }
		end },
		["@EnumMap"] = { Material = { SmoothPlastic = 0 }, PartType = { Block = 0, Ball = 1, Cylinder = 2 }, MachineNetworkOwner = { Server = 0 } },
		["@Kinemium.signal"] = signal,
		["@manifold"] = { gen = { box = allocate, sphere = allocate, cylinder = allocate, alloc = allocate, free = free },
			lib = { manifold_copy = function(destination: any, _source: any): any return destination end } },
		["@PhysicalProperties"] = { new = function(...: any): {} return {} end },
	})
	local game = { GetService = function(_self: {}, _name: string): nil return nil end }
	local owner = Instance.new("Part")
	Part.callback(owner, nil, game)
	local original = owner._manifoldptr
	owner.Size = vector3.new(4, 5, 6)
	assert(freed[original] and not freed[owner._manifoldptr])
	local replacement = owner._manifoldptr
	failAllocation = true
	assert(not pcall(function(): () owner.Size = vector3.new(7, 8, 9) end))
	assert(owner._manifoldptr == replacement and not freed[replacement])
	failAllocation = false
	Instance.SetCloneInitializer(function(_source: any, clone: any): () Part.callback(clone, nil, game) end)
	local clone = owner:Clone()
	Instance.SetCloneInitializer(nil)
	assert(clone._manifoldptr ~= owner._manifoldptr)
	owner:Destroy()
	assert(not freed[clone._manifoldptr])
	clone:Destroy()
	for _, pointer in ipairs(allocated) do assert(freed[pointer], "Leaked allocation") end
end)

test("failed clone initialization cleans native allocations", function(): ()
	local owner = Instance.new("Part")
	local count = 0
	Instance.SetCloneInitializer(function(_source: any, clone: any): ()
		resources:Track(clone, 1, function(_ptr: any): () count += 1 end)
		error("clone initialization failed")
	end)
	local ok = pcall(owner.Clone, owner)
	Instance.SetCloneInitializer(nil)
	assert(not ok and count == 1)
	owner:Destroy()
end)

print(string.format("%d instance lifecycle tests passed", passed))
