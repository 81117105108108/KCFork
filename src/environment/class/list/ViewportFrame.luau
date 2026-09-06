-- description: "A GUI frame that renders an isolated Filament 3D scene."
local Frame = require("@Frame")
local GuiObject = require("@GuiObject")
local Color3 = require("@Color3")
local Vector3 = require("@Vector3")
local Enum = require("@EnumMap")
local argon = require("@Argon")
local Shader = require("@ShaderDatatype")

local states = setmetatable({}, { __mode = "k" })

local propTable = {
	Camera = nil,
	AmbientColor = Color3.fromRGB(48, 52, 61),
	LightColor = Color3.new(1, 1, 1),
	LightDirection = Vector3.new(-0.45, -0.7, -0.55),
	ManualRender = false,
	ResolutionScale = 1,
	MaterialShader = nil,
	PostProcessShader = nil,
	Name = "ViewportFrame",
	ClipsDescendants = true,
}
Frame.inherit(propTable)

local function isBasePart(object)
	local props = rawget(object, "_props")
	return props
		and (props.ClassName == "BasePart" or props.BaseClass == "BasePart" or rawget(object, "BaseClass") == "BasePart")
end

local function materialKind(material)
	if material == Enum.Material.Glass then return 1 end
	if material == Enum.Material.Neon then return 2 end
	if material == Enum.Material.Water then return 3 end
	return 0
end

local function destroyState(state)
	if not state then return end
	if state.viewport and state.viewport.Window then
		for _, mesh in pairs(state.meshes) do
			argon:DestroyMesh(state.viewport.Window, mesh)
		end
		for _, mesh in pairs(state.pathMeshes) do
			argon:DestroyMesh(state.viewport.Window, mesh)
		end
	end
	if state.surfaceShader then state.surfaceShader:Unload() end
	if state.postprocessShader then state.postprocessShader:Unload() end
	if state.viewport then argon:DestroyFilamentViewport(state.viewport) end
	for _, connection in ipairs(state.connections) do connection:Disconnect() end
	state.viewport = nil
	table.clear(state.meshes)
	table.clear(state.pathMeshes)
end

local function cloneShader(value, shaderType)
	if type(value) == "string" then
		return if shaderType == "surface" then Shader.fromMemorySurface(value) else Shader.fromMemoryPostProcess(value)
	end
	if type(value) == "table" and value._class == "shader" then
		if value._type ~= shaderType then
			return nil, `Expected a {shaderType} shader, got {tostring(value._type)}`
		end
		return value:Clone()
	end
	return nil, `Expected Filamat source or a {shaderType} Shader`
end

local function syncShader(state, value, shaderType)
	local valueKey = shaderType .. "Value"
	local shaderKey = shaderType .. "Shader"
	local errorKey = shaderType .. "Error"
	if state[valueKey] == value then
		local cachedError = state[errorKey]
		return cachedError == nil, cachedError
	end
	if value == nil then
		if state[shaderKey] then state[shaderKey]:Unload() end
		state[shaderKey], state[valueKey] = nil, nil
		state[errorKey] = nil
		return true
	end

	local shader, reason = cloneShader(value, shaderType)
	if not shader then
		state[valueKey], state[errorKey] = value, tostring(reason)
		return false, reason
	end
	local compiled, compileError = shader:Compile(state.viewport.Window)
	if not compiled then
		state[valueKey], state[errorKey] = value, tostring(compileError)
		return false, compileError
	end
	local applied, applyError = shader:ApplyGlobal(state.viewport.Window)
	if not applied then
		shader:Unload()
		state[valueKey], state[errorKey] = value, tostring(applyError)
		return false, applyError
	end
	if state[shaderKey] then state[shaderKey]:Unload() end
	state[shaderKey], state[valueKey] = shader, value
	state[errorKey] = nil
	return true
end

local function syncShaders(state, object)
	local ok, reason = syncShader(state, object.MaterialShader, "surface")
	if ok then ok, reason = syncShader(state, object.PostProcessShader, "postprocess") end
	state.shaderError = if ok then nil else tostring(reason)
	return ok
end

local function ensureViewport(state, width, height)
	if not state.viewport then
		local viewport, reason = argon:CreateFilamentViewport(width, height)
		if not viewport then
			if not state.warned then
				warn("ViewportFrame could not create its Filament target: " .. tostring(reason))
				state.warned = true
			end
			return false
		end
		state.viewport = viewport
		state.width, state.height = width, height
		state.meshes.cube = argon:CreateMesh(viewport.Window, "cube")
		state.meshes.sphere = argon:CreateMesh(viewport.Window, "sphere")
		state.meshes.cylinder = argon:CreateMesh(viewport.Window, "cylinder")
		state.warmupFrames = 2
		state.dirty = true
	elseif state.width ~= width or state.height ~= height then
		if not argon:ResizeFilamentViewport(state.viewport, width, height) then return false end
		state.width, state.height = width, height
		state.warmupFrames = 2
		state.dirty = true
	end
	return true
end

local function meshForPart(state, props)
	if props.ClassName == "MeshPart" then
		local path = props.MeshId
		if type(path) == "string" and path ~= "" then
			local cached = state.pathMeshes[path]
			if cached == nil then
				cached = argon:CreateMeshFromPath(state.viewport.Window, path) or false
				state.pathMeshes[path] = cached
			end
			if cached ~= false then return cached end
		end
	end
	if props.Shape == Enum.PartType.Ball then return state.meshes.sphere end
	if props.Shape == Enum.PartType.Cylinder then return state.meshes.cylinder end
	return state.meshes.cube
end

local function renderFilament(state, object, dt)
	local camera = object.Camera
	if not camera or not camera.CFrame then return false end
	local position = camera.CFrame.Position
	local target = position + camera.CFrame:GetLookVector()
	if not argon:SetFilamentViewportCamera(state.viewport, position, target, camera.FieldOfView or 60) then
		return false
	end
	if not syncShaders(state, object) then return false end

	local drawCalls = {}
	for _, child in ipairs(object:GetDescendants()) do
		if isBasePart(child) then
			local props = rawget(child, "_props")
			local transparency = math.clamp(tonumber(props.Transparency) or 0, 0, 1)
			local mesh = meshForPart(state, props)
			if mesh and mesh._handle and props.CFrame and props.Size and transparency < 1 then
				local meshScale = if props.ClassName == "MeshPart" then tonumber(props.MeshScale) or 1 else 1
				drawCalls[#drawCalls + 1] = {
					mesh = mesh,
					cframe = props.CFrame,
					scale = Vector3.new(props.Size.X * meshScale, props.Size.Y * meshScale, props.Size.Z * meshScale),
					color = props.Color or Color3.new(1, 1, 1),
					transparency = transparency,
					roughness = tonumber(props.Roughness) or 0.5,
					metallic = tonumber(props.Metallic) or 0,
					transmission = 0,
					MaterialKind = materialKind(props.Material),
					MaterialTileScale = 1,
					CastShadow = props.CastShadow ~= false,
					RecieveShadow = true,
					Culling = true,
				}
			end
		end
	end
	argon:DrawMeshList(state.viewport.Window, drawCalls)
	state.pixels, state.rowBytes = argon:RenderFilamentViewport(state.viewport, dt)
	state.dirty = false
	return state.pixels ~= nil
end

propTable.render = function(window, object, dt, renderer)
	if not object or not object.Visible then return end
	local framePos, frameSize = GuiObject.render(window, object, dt, renderer)
	if not framePos or not frameSize then return end

	local state = states[object]
	if state then
		local resolutionScale = math.clamp(tonumber(object.ResolutionScale) or 1, 0.25, 2)
		local width = math.max(1, math.floor(frameSize.X * resolutionScale + 0.5))
		local height = math.max(1, math.floor(frameSize.Y * resolutionScale + 0.5))
		if ensureViewport(state, width, height) and (state.dirty or state.warmupFrames > 0) then
			renderFilament(state, object, dt)
			state.warmupFrames = math.max(0, state.warmupFrames - 1)
		end
		if state.pixels then
			argon:DrawPixels(window, state.pixels, state.width, state.height, state.rowBytes, {
				x = framePos.X,
				y = framePos.Y,
				width = frameSize.X,
				height = frameSize.Y,
			}, true)
		end
	end

	GuiObject.renderChildren(window, object, dt, renderer)
	return framePos, frameSize
end

return {
	class = "ViewportFrame",
	render = propTable.render,
	callback = function(instance)
		instance:SetProperties(propTable)
		local state = {
			viewport = nil,
			meshes = {},
			pathMeshes = {},
			connections = {},
			dirty = true,
			pixels = nil,
			rowBytes = 0,
			warmupFrames = 0,
		}
		states[instance] = state

		function instance:Render()
			state.dirty = true
		end

		function instance:GetShaderError()
			return state.shaderError
		end

		table.insert(state.connections, instance.Changed:Connect(function(property)
			if property == "Size" or property == "Camera" or property == "ResolutionScale"
				or property == "MaterialShader" or property == "PostProcessShader" then
				state.dirty = true
			end
		end))
		table.insert(state.connections, instance.DescendantAdded:Connect(function()
			state.dirty = true
		end))
		table.insert(state.connections, instance.DescendantRemoving:Connect(function()
			state.dirty = true
		end))
		table.insert(state.connections, instance.DescendantChanged:Connect(function(descendant)
			if not instance.ManualRender or descendant == instance.Camera then state.dirty = true end
		end))
		instance.Destroying:Connect(function()
			destroyState(state)
			states[instance] = nil
		end)
		return instance
	end,
	inherit = function(tble)
		Frame.inherit(tble)
		for prop, value in pairs(propTable) do
			if tble[prop] == nil then tble[prop] = value end
		end
	end,
}
