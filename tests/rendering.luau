--!strict
-- Run from the repository root: zune run tests/rendering.luau
-- Executes the production modules with deterministic graphics/FFI test doubles.
local runtime = zune
local root = runtime.process.env.KINE_RENDER_TEST_ROOT or "."
local passed, failed = 0, 0

local function test(name, callback)
	local ok, err = pcall(callback)
	if ok then
		passed += 1
		print("PASS", name)
	else
		failed += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function equal(actual, expected, message)
	assert(actual == expected, (message or "Unexpected value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function loadModule(path, replacements)
	local env = setmetatable(replacements, { __index = getfenv(0) })
	local source = runtime.fs.readFile(root .. "/" .. path)
	return runtime.luau.load(runtime.luau.compile(source), { env = env, chunk_name = path })()
end

local function makeRenderer(backend)
	local calls = {}
	local function record(name, ...)
		calls[#calls + 1] = { name = name, args = { ... } }
	end
	local argon = setmetatable({}, { __index = function(_, name)
		return function(_, ...) record(name, ...) end
	end })
	function argon:InitWindow(config)
		return { Width = config.Width, Height = config.Height, WGI = config.WGI, _uihandle = {} }
	end
	function argon:CreateRenderingContext(window) return { Window = window } end
	function argon:CreateRenderer() return {} end
	function argon:CreateTexture(config) return { config = config } end
	function argon:CreateSkiaSurface() return { _uihandle = {} } end
	function argon:PollEvents() record("PollEvents"); return false, nil, nil, false, {} end
	function argon:GetPixels() return {} end
	function argon:BeginOverlay() return true end
	function argon:DrawMeshList(window, items, count, ...)
		record("DrawMeshList", window, table.clone(items), count, ...)
	end
	local signal = {}
	function signal.new()
		local listeners = {}
		return {
			Connect = function(_, cb) listeners[#listeners + 1] = cb end,
			GetConnectionCount = function() return #listeners end,
			Fire = function(_, route, ...)
				record(route, ...)
				for _, cb in ipairs(listeners) do cb(route, ...) end
			end,
		}
	end
	local libs = { ["@Kinemium.signal"] = signal, ["@Argon"] = argon, ["@meshgen"] = { setWindow = function() end } }
	libs["../engine/ffi/ResourceTracker"] = { shared = {
		Sweep = function() record("ResourceSweep") end,
		CollectAll = function() record("ResourceDrain") end,
	} }
	local module = loadModule("src/renderer/init.luau", {
		require = function(name) assert(libs[name], name); return libs[name] end,
		zune = { task = { wait = function() end }, process = { exit = function(code) record("exit", code) end } },
	})
	local renderer = module.new({ width = 800, height = 600, title = "test", WGI = backend or "opengl" })
	table.clear(calls)
	return renderer, calls, argon
end

local function findCall(calls, name)
	for index, call in ipairs(calls) do if call.name == name then return index, call end end
	error("Missing call: " .. name)
end

test("render hooks run before scene submission and presentation", function()
	local renderer, calls = makeRenderer()
	local current = 0
	renderer.EventBus:Connect(function(route) if route == "RenderStepped" then current = 42 end end)
	renderer.Pool.new("3d", function() equal(current, 42) end)
	renderer:Step()
	assert(findCall(calls, "PollEvents") < findCall(calls, "PreRender"))
	assert(findCall(calls, "ResourceSweep") < findCall(calls, "PollEvents"))
	assert(findCall(calls, "RenderStepped") < findCall(calls, "Begin3D"))
	assert(findCall(calls, "Render3D") < findCall(calls, "Heartbeat"))
	assert(renderer.Frametime >= 0)
	equal(renderer.Frametime, renderer.RuntimeLibrary.dt)
end)

test("camera roll reaches the 3D adapter", function()
	local renderer, calls = makeRenderer()
	local up = vector.create(1, 0, 0)
	renderer:UseRlCamera({ CFrame = {
		Position = vector.create(0, 0, 0),
		GetLookVector = function() return vector.create(0, 0, -1) end,
		GetUpVector = function() return up end,
	} })
	renderer:Render3D()
	local _, call = findCall(calls, "SetCameraLookAt")
	equal(call.args[4], up)
end)

test("pool priorities are stable, mutable, and support overlays", function()
	local renderer = makeRenderer()
	local order = {}
	local first = renderer.Pool.new("2da", function() order[#order + 1] = "first" end, 0)
	local second = renderer.Pool.new("2da", function() order[#order + 1] = "second" end, 0)
	renderer:Render2DAbove()
	equal(table.concat(order), "firstsecond")
	table.clear(order)
	renderer.Pool.SetPriority(second, -1)
	renderer:Render2DAbove()
	equal(table.concat(order), "secondfirst")
	table.clear(order)
	renderer.Pool.Destroy(first)
	renderer:Render2DAbove()
	equal(table.concat(order), "second")
end)

test("destroyed callbacks are skipped during traversal; new callbacks wait", function()
	local renderer = makeRenderer()
	local second, added, later = nil, false, 0
	renderer.Pool.new("3d", function()
		renderer.Pool.Destroy(second)
		if not added then
			added = true
			renderer.Pool.new("3d", function() later += 1 end)
		end
	end)
	second = renderer.Pool.new("3d", function() error("Destroyed callback ran") end)
	renderer:Render3D()
	equal(later, 0)
	renderer:Render3D()
	equal(later, 1)
end)

test("pool identifiers are unique across all pool types", function()
	local renderer = makeRenderer()
	local seen = {}
	for index = 1, 10000 do
		for _, kind in ipairs({ "2d", "3d", "2da", "gizmo" }) do
			local id = renderer.Pool.new(kind, function() end)
			assert(not seen[id], "Cross-pool collision")
			seen[id] = true
		end
	end
end)

test("individual mesh flags and callbacks survive dispatch", function()
	local renderer, calls = makeRenderer()
	local order = {}
	local draw = { mesh = {}, matrix = {}, color = { R = 1, G = 0, B = 0 },
		CastShadow = false, ReceiveShadow = false, Culling = true }
	renderer.MeshPool.DrawMesh(draw, nil, nil, function() order[#order + 1] = "begin" end,
		function() order[#order + 1] = "end" end)
	renderer:Render3D()
	equal(table.concat(order), "beginend")
	local _, call = findCall(calls, "DrawMeshList")
	equal(call.args[2][1].CastShadow, false)
	equal(call.args[2][1].ReceiveShadow, false)
	equal(call.args[2][1].Culling, true)
end)

test("individual meshes batch together without crossing callback barriers", function()
	local renderer, calls, argon = makeRenderer()
	for _ = 1, 100 do renderer.MeshPool.DrawMesh({ mesh = {} }) end
	renderer.MeshPool.DrawMesh({ mesh = {} }, nil, nil,
		function() argon:Marker("begin") end, function() argon:Marker("end") end)
	for _ = 1, 100 do renderer.MeshPool.DrawMesh({ mesh = {} }) end
	renderer:Render3D()
	local batches = {}
	for _, call in ipairs(calls) do
		if call.name == "DrawMeshList" then batches[#batches + 1] = call.args[3] end
	end
	equal(table.concat(batches, ","), "100,1,100")
	local first = findCall(calls, "DrawMeshList")
	equal(calls[first + 1].name, "Marker")
	equal(calls[first + 2].name, "DrawMeshList")
	equal(calls[first + 3].name, "Marker")
end)

test("OpenGL overlays are composited after the 3D image", function()
	local renderer, calls = makeRenderer()
	renderer:Step()
	local scene = findCall(calls, "DrawTextureFlipped")
	equal(calls[scene + 1].name, "DrawTexture")
end)

test("GUI statistics include both layers", function()
	local renderer = makeRenderer()
	renderer.Pool.new("2d", function() end)
	renderer.Pool.new("2da", function() end)
	renderer:Step()
	equal(renderer.PerfStats.gui_roots, 2)
end)

test("shutdown frees owned resources once and skips borrowed surfaces", function()
	local renderer, calls = makeRenderer("vulkan")
	local borrowed, raster = {}, {}
	renderer.Window._uihandle = borrowed
	renderer.Window._vulkanCompositorFrameSurface = borrowed
	renderer.Window._rasterUIHandle = raster
	renderer:Shutdown()
	assert(findCall(calls, "ResourceDrain") < findCall(calls, "Shutdown"))
	local surfaces, textures, shutdowns = 0, 0, 0
	for _, call in ipairs(calls) do
		if call.name == "DestroySkiaSurface" then
			assert(call.args[1] ~= borrowed, "Freed borrowed compositor surface")
			surfaces += 1
		elseif call.name == "DestroyTexture" then textures += 1
		elseif call.name == "Shutdown" then shutdowns += 1 end
	end
	equal(surfaces, 2)
	equal(textures, 3)
	equal(shutdowns, 1)
	local count = #calls
	renderer:Shutdown()
	equal(#calls, count)
end)

local function makeAdapter()
	local calls, allocations = {}, {}
	local null = {}
	local failAllocation = false
	local function checkedWrite(pointer, offset, value, bytes)
		assert(not pointer.freed, "Use after free")
		assert(offset >= 0 and offset + bytes <= pointer.size, "Buffer overflow")
		pointer.values[offset] = value
	end
	local ffi = { null = null }
	function ffi.alloc(bytes)
		if failAllocation then return null end
		local pointer = { size = bytes, values = {} }
		function pointer:writef32(offset, value) checkedWrite(self, offset, value, 4) end
		pointer.writeu32 = pointer.writef32
		pointer.writei32 = pointer.writef32
		function pointer:writeptr(offset, value) checkedWrite(self, offset, value, 8) end
		function pointer:write(offset, source, sourceOffset, length) checkedWrite(self, offset, source, length) end
		allocations[#allocations + 1] = pointer
		return pointer
	end
	function ffi.free(pointer) assert(not pointer.freed, "Double free"); pointer.freed = true end
	-- Mirrors KineFilamentDrawItem in external/kine_render_shim/include/kine_filament_shim.h.
	-- The trailing `shader` pointer makes the packed size 128 (was 120 before it was added).
	local offsets = { mesh = 0, tex = 8, transform = 16, r = 80, g = 84, b = 88, param1 = 92,
		param2 = 96, param3 = 100, transmission = 104, materialKind = 108, flags = 112,
		reserved = 116, shader = 120 }
	local lib = setmetatable({}, { __index = function(_, name)
		return function(...)
			calls[#calls + 1] = { name = name, args = { ... } }
			if name == "Kine_Filament_Create" or name == "Kine_Filament_CreateInstanceBatch" then return {} end
			return 1
		end
	end })
	local adapter = loadModule("src/modules/Argon/adapters/sdl3/filamentlib.luau", {
		zune = { ffi = ffi },
		require = function(name)
			if name == "./filament" then
				return { lib = lib, structs = { KineFilamentDrawItem = {
					size = function() return 128 end, offset = function(_, key) return offsets[key] end,
				} } }
			end
			equal(name, "../../typedefs")
			return {}
		end,
	})
	return adapter, calls, allocations, null, function(value) failAllocation = value end
end

local function makeDraw()
	return { mesh = { _handle = {} }, color = { R = 1, G = 0.5, B = 0 },
		cframe = { Position = { X = 10, Y = 20, Z = 30 }, Rotation = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } },
		scale = { X = 2, Y = 3, Z = 4 } }
end

test("FFI packing preserves affine layout, flags, and legacy spelling", function()
	local adapter, calls = makeAdapter()
	local window = { _3dhandle = {} }
	local draw = makeDraw()
	draw.CastShadow, draw.ReceiveShadow, draw.Culling = false, false, true
	adapter:DrawMeshList(window, { draw })
	local values = calls[#calls].args[2].values
	equal(values[16], 2); equal(values[28], 10)
	equal(values[36], 3); equal(values[44], 20)
	equal(values[56], 4); equal(values[60], 30); equal(values[76], 1)
	equal(values[112], 4)
	draw.ReceiveShadow, draw.RecieveShadow = nil, false
	adapter:DrawMeshList(window, { draw })
	equal(calls[#calls].args[2].values[112], 4)
end)

test("retained lists repack after gaps and resource invalidation", function()
	local adapter, calls, _, null = makeAdapter()
	local window, draw = { _3dhandle = {} }, makeDraw()
	adapter:DrawMeshList(window, { draw }, 1, 5, 10)
	local revision = calls[#calls].args[5]
	adapter:Render3D(window, 0.016)
	adapter:DrawMeshList(window, { draw }, 1, 5, 10)
	equal(calls[#calls].args[2], null)
	equal(calls[#calls].args[5], revision)
	adapter:Render3D(window, 0.016)
	adapter:Render3D(window, 0.016)
	adapter:DrawMeshList(window, { draw }, 1, 5, 10)
	assert(calls[#calls].args[2] ~= null)
	assert(calls[#calls].args[5] > revision)
	revision = calls[#calls].args[5]
	adapter:SetGlobalMaterialShader(window, {})
	adapter:DrawMeshList(window, { draw }, 1, 5, 10)
	assert(calls[#calls].args[2] ~= null)
	assert(calls[#calls].args[5] > revision)
	adapter:DestroyMesh(window, draw.mesh)
	adapter:DrawMeshList(window, { draw }, 1, 5, 10)
	equal(calls[#calls].args[3], 0)
end)

test("stream zero uses immediate submission", function()
	local adapter, calls = makeAdapter()
	adapter:DrawMeshList({ _3dhandle = {} }, { makeDraw() }, 1, 0, 1)
	equal(calls[#calls].name, "Kine_Filament_DrawMeshList")
end)

test("instance creation rejects holes instead of shifting update indices", function()
	local adapter, calls = makeAdapter()
	equal(adapter:CreateInstanceBatch({ _3dhandle = {} }, { makeDraw(), {}, makeDraw() }), nil)
	equal(#calls, 0)
end)

test("primitive mesh names map to distinct native shapes", function()
	local adapter, calls = makeAdapter()
	local window = { _3dhandle = {} }
	adapter:CreateMesh(window, "cube")
	adapter:CreateMesh(window, "sphere")
	adapter:CreateMesh(window, "cylinder")
	adapter:CreateMesh(window, "wedge")
	local shapes = {}
	for _, call in ipairs(calls) do
		if call.name == "Kine_Filament_CreateMesh" then
			table.insert(shapes, call.args[2])
		end
	end
	equal(table.concat(shapes, ","), "1,2,6,7")
end)

test("invalid instance indices never reach native code", function()
	local adapter, calls = makeAdapter()
	local updates = {}
	for _, index in ipairs({ -1, 0.5, 4294967296, math.huge, 0 / 0 }) do
		local update = makeDraw(); update.index = index; updates[#updates + 1] = update
	end
	local valid = makeDraw(); valid.index = 0; updates[#updates + 1] = valid
	adapter:UpdateInstanceTransforms({ _3dhandle = {} }, {}, updates)
	equal(calls[#calls].args[4], 1)
	equal(calls[#calls].args[2].values[0], 0)
end)

test("instance visibility packs valid indices and supports an empty batch", function()
	local adapter, calls, _, null = makeAdapter()
	local window, batch = { _3dhandle = {} }, {}
	adapter:SetInstanceBatchVisibility(window, batch, { 5, -1, 2.5, 3 })
	local call = calls[#calls]
	equal(call.name, "Kine_Filament_SetInstanceBatchVisibility")
	equal(call.args[3], 2)
	equal(call.args[2].values[0], 5)
	equal(call.args[2].values[4], 3)
	adapter:SetInstanceBatchVisibility(window, batch, {})
	call = calls[#calls]
	equal(call.args[2], null)
	equal(call.args[3], 0)
end)

test("readback buffers are isolated per window and absent on Vulkan", function()
	local adapter, _, allocations = makeAdapter()
	local first = { _3dhandle = {}, Width = 2, Height = 2, WGI = "opengl" }
	local second = { _3dhandle = {}, Width = 64, Height = 64, WGI = "opengl" }
	local a, b = adapter:GetPixels(first), adapter:GetPixels(second)
	assert(a ~= b)
	assert(b.size >= 64 * 64 * 4)
	adapter:Shutdown(first)
	assert(a.freed and not b.freed)
	equal(adapter:GetPixels(second), b)
	adapter:Shutdown(second)
	local vulkan = { Width = 4096, Height = 2160, WGI = "vulkan" }
	local before = #allocations
	adapter:Init(vulkan)
	adapter:ResizePixelBuffer(vulkan, 4096, 2160)
	equal(adapter:GetPixels(vulkan), nil)
	equal(#allocations, before)
end)

test("shutdown releases draw, index, transform, and pixel buffers", function()
	local adapter, _, allocations = makeAdapter()
	local window = { _3dhandle = {}, Width = 2, Height = 2, WGI = "opengl" }
	local draw = makeDraw(); draw.index = 0
	adapter:DrawMeshList(window, { draw })
	adapter:UpdateInstanceTransforms(window, {}, { draw })
	adapter:GetPixels(window)
	equal(#allocations, 4)
	adapter:Shutdown(window)
	adapter:Shutdown(window)
	for _, pointer in ipairs(allocations) do assert(pointer.freed) end
end)

test("failed buffer growth preserves the previous allocation", function()
	local adapter, _, allocations, _, failAllocation = makeAdapter()
	local window = { _3dhandle = {}, Width = 2, Height = 2, WGI = "opengl" }
	local original = adapter:GetPixels(window)
	failAllocation(true)
	window.Width, window.Height = 1024, 1024
	assert(not pcall(function() adapter:GetPixels(window) end))
	assert(not original.freed)
	failAllocation(false)
	adapter:Shutdown(window)
	for _, pointer in ipairs(allocations) do assert(pointer.freed) end
end)

if runtime.process.env.KINE_RENDER_BENCHMARK == "1" then
	local renderer = makeRenderer()
	for index = 1, 10000 do
		renderer.Pool.new("2d", function() end, index % 17)
	end
	renderer:Render2D()
	local start = os.clock()
	for _ = 1, 100 do renderer:Render2D() end
	print(string.format("Pool benchmark: 100 frames x 10,000 callbacks: %.3f ms", (os.clock() - start) * 1000))
end

print(string.format("Rendering regressions: %d passed, %d failed", passed, failed))
assert(failed == 0, "Rendering regressions failed")
