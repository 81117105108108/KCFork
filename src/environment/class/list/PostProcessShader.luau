-- description: "A Filament fullscreen shader parented under Lighting."
local ShaderInstance = require("@ShaderInstance")
local Argon = require("@Argon")

local propTable = {
	Name = "PostProcessShader",
	BaseClass = "ShaderInstance",
}

local instances = setmetatable({}, { __mode = "k" })
local activeInstance = nil
local activeHandle = nil

local function updateActive(renderer, game)
	if not renderer or not renderer.Window then
		return
	end
	local lighting = game and game:GetService("Lighting") or nil
	local selected = nil
	if lighting then
		for _, child in ipairs(lighting:GetChildren()) do
			if child.ClassName == "PostProcessShader" and child.Enabled ~= false and child._shaderHandle then
				selected = child
				break
			end
		end
	end
	local handle = selected and selected._shaderHandle or nil
	if selected == activeInstance and handle == activeHandle then
		return
	end
	local ok, reason = Argon:SetFilamentPostProcessShader(renderer.Window, handle)
	if ok == false and selected then
		rawget(selected, "_props").CompileError = tostring(reason)
		return
	end
	activeInstance, activeHandle = selected, handle
end

return {
	class = "PostProcessShader",
	callback = function(instance, renderer, game)
		instance:SetProperties(propTable)
		instances[instance] = true
		ShaderInstance.Attach(
			instance,
			renderer,
			"postprocess",
			ShaderInstance.DefaultPostProcessSource,
			{ intensity = 0.35 },
			function()
				updateActive(renderer, game)
			end
		)
		instance.Destroying:Connect(function()
			instances[instance] = nil
			if activeInstance == instance then
				activeInstance, activeHandle = nil, nil
			end
			updateActive(renderer, game)
		end)
		updateActive(renderer, game)
		return instance
	end,
	inherit = function(target)
		for name, value in pairs(propTable) do
			target[name] = value
		end
	end,
}
