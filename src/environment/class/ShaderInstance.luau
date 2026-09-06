local Shader = require("@ShaderDatatype")

local ShaderInstance = {}

ShaderInstance.DefaultMaterialSource = [[material {
    name : "PartMaterialShader",
    shadingModel : lit,
    blending : opaque,
    parameters : [
        { type : float4, name : tint },
        { type : float, name : roughness }
    ]
}

fragment {
    void material(inout MaterialInputs material) {
        prepareMaterial(material);
        material.baseColor = materialParams.tint;
        material.roughness = materialParams.roughness;
    }
}]]

ShaderInstance.DefaultPostProcessSource = [[material {
    name : "LightingPostProcessShader",
    shadingModel : unlit,
    blending : opaque,
    culling : none,
    depthWrite : false,
    depthCulling : false,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : inputTexture },
        { type : float, name : intensity }
    ]
}

fragment {
    float rand(vec2 p) {
        return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    }

    void material(inout MaterialInputs material) {
        prepareMaterial(material);

        vec2 uv = getUV0();
        float strength = clamp(materialParams.intensity, 0.0, 1.0);

        // CRT barrel distortion.
        vec2 centered = uv * 2.0 - 1.0;
        float r2 = dot(centered, centered);
        centered *= 1.0 + r2 * 0.08 * strength;
        vec2 crtUV = centered * 0.5 + 0.5;

        // Black outside the curved screen.
        if (
            crtUV.x < 0.0 || crtUV.x > 1.0 ||
            crtUV.y < 0.0 || crtUV.y > 1.0
        ) {
            material.baseColor = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }

        // Chromatic aberration / RGB separation.
        float separation = 0.0025 * strength;

        float r = texture(
            materialParams_inputTexture,
            crtUV + vec2(separation, 0.0)
        ).r;

        float g = texture(
            materialParams_inputTexture,
            crtUV
        ).g;

        float b = texture(
            materialParams_inputTexture,
            crtUV - vec2(separation, 0.0)
        ).b;

        vec3 color = vec3(r, g, b);

        // Horizontal scanlines.
        float scanline =
            0.90 +
            0.10 * sin(crtUV.y * 900.0);

        color *= mix(1.0, scanline, strength);

        // Fine CRT shadow-mask approximation.
        float mask =
            0.94 +
            0.06 * sin(crtUV.x * 1200.0);

        color *= mix(1.0, mask, strength);

        // Slight random analogue noise.
        float noise =
            (rand(crtUV * 1000.0) - 0.5) *
            0.025 *
            strength;

        color += noise;

        // Darken screen edges.
        vec2 edge = crtUV * (1.0 - crtUV);
        float vignette =
            clamp(
                edge.x *
                edge.y *
                20.0,
                0.0,
                1.0
            );

        vignette = pow(vignette, 0.25);

        color *= mix(1.0, vignette, strength);

        // Small CRT contrast boost.
        color = mix(
            color,
            (color - 0.5) * 1.08 + 0.5,
            strength
        );

        material.baseColor = vec4(
            clamp(color, 0.0, 1.0),
            1.0
        );
    }
}]]

local uniformLengths = {
	float = 1,
	float2 = 2,
	float3 = 3,
	float4 = 4,
}

function ShaderInstance.GetUniformDefinitions(source)
	local definitions = {}
	local parameters = type(source) == "string" and source:match("parameters%s*:%s*%[(.-)%]") or nil
	if not parameters then
		return definitions
	end
	for entry in parameters:gmatch("%b{}") do
		local uniformType = entry:match("type%s*:%s*([%w_]+)")
		local name = entry:match("name%s*:%s*([%w_]+)")
		local length = uniformType and uniformLengths[uniformType]
		if name and length then
			definitions[#definitions + 1] = { Name = name, Type = uniformType, Length = length }
		end
	end
	return definitions
end

local function defaultUniformValue(length)
	local values = {}
	for index = 1, length do
		values[index] = 0
	end
	return values
end

local function uniformComponents(value)
	if type(value) == "number" then
		return { value }
	end
	if type(value) == "vector" then
		return { value.X, value.Y, value.Z }
	end
	if type(value) ~= "table" then
		return nil
	end
	if value.__type == "Vector2" then
		return { value.X, value.Y }
	elseif value.__type == "Vector3" or value.__type == "CFrame" then
		local vector = value.__type == "CFrame" and value.Position or value
		return { vector.X, vector.Y, vector.Z }
	elseif value.__type == "Color3" then
		return { value.R, value.G, value.B }
	elseif value.__type == "Color4" then
		return { value.R, value.G, value.B, value.A }
	end
	if value.X ~= nil and value.Y ~= nil then
		return value.W ~= nil and { value.X, value.Y, value.Z, value.W }
			or (value.Z ~= nil and { value.X, value.Y, value.Z } or { value.X, value.Y })
	end
	if value.R ~= nil and value.G ~= nil and value.B ~= nil then
		return value.A ~= nil and { value.R, value.G, value.B, value.A } or { value.R, value.G, value.B }
	end
	local result = {}
	for index = 1, math.min(#value, 4) do
		if type(value[index]) ~= "number" then
			return nil
		end
		result[index] = value[index]
	end
	return #result > 0 and result or nil
end

local function normalizeUniform(value, expectedLength)
	local components = uniformComponents(value)
	if not components or #components ~= expectedLength then
		return nil
	end
	for _, component in ipairs(components) do
		if type(component) ~= "number" then
			return nil
		end
	end
	return expectedLength == 1 and components[1] or components
end

function ShaderInstance.Attach(instance, renderer, shaderType, defaultSource, defaultUniforms, onRuntimeChanged)
	instance:SetProperties({
		Source = defaultSource,
		Uniforms = defaultUniforms or {},
		Enabled = true,
		CompileError = "",
		BaseClass = "ShaderInstance",
	})

	local runtimeShader = nil
	local compiling = false
	local settingUniforms = false

	local function definitionFor(name)
		for _, definition in ipairs(ShaderInstance.GetUniformDefinitions(instance.Source)) do
			if definition.Name == name then
				return definition
			end
		end
		return nil
	end

	local function applyUniforms()
		if not runtimeShader then
			return true
		end
		for name, value in pairs(instance.Uniforms or {}) do
			local definition = definitionFor(name)
			local normalized = definition and normalizeUniform(value, definition.Length) or nil
			local ok, reason = normalized and runtimeShader:SetUniform(name, normalized)
			if not ok then
				reason = reason or `Uniform "{name}" needs {definition and definition.Length or "a declared number of"} numeric value(s)`
				rawget(instance, "_props").CompileError = tostring(reason)
				return false, reason
			end
		end
		return true
	end

	local function compile()
		if compiling then
			return false, "Shader is already compiling"
		end
		compiling = true
		local nextShader = if shaderType == "surface"
			then Shader.fromMemorySurface(instance.Source)
			else Shader.fromMemoryPostProcess(instance.Source)
		for _, definition in ipairs(ShaderInstance.GetUniformDefinitions(instance.Source)) do
			local value = normalizeUniform((instance.Uniforms or {})[definition.Name], definition.Length)
			if value == nil then
				value = defaultUniformValue(definition.Length)
			end
			nextShader:SetUniform(definition.Name, value)
		end
		local ok, reason = nextShader:Compile(renderer and renderer.Window)
		if not ok then
			nextShader:Unload()
			rawget(instance, "_props").CompileError = tostring(reason)
			compiling = false
			return false, reason
		end

		local previous = runtimeShader
		runtimeShader = nextShader
		rawset(instance, "_runtimeShader", nextShader)
		rawset(instance, "_shaderHandle", nextShader._shader)
		rawget(instance, "_props").CompileError = ""
		if onRuntimeChanged then
			onRuntimeChanged(instance, nextShader)
		end
		if previous then
			previous:Unload()
		end
		compiling = false
		return true
	end

	function instance:Compile()
		return compile()
	end

	function instance:SetUniform(name, value)
		if type(name) ~= "string" or name == "" then
			return false, "Uniform name is required"
		end
		local definition = definitionFor(name)
		if not definition then
			return false, `Uniform "{name}" is not declared in this shader`
		end
		local normalized = normalizeUniform(value, definition.Length)
		if normalized == nil then
			return false, `Uniform "{name}" requires {definition.Length} numeric value(s)`
		end
		if runtimeShader then
			local ok, reason = runtimeShader:SetUniform(name, normalized)
			if not ok then
				return false, reason
			end
		end
		local uniforms = table.clone(instance.Uniforms or {})
		uniforms[name] = normalized
		settingUniforms = true
		instance.Uniforms = uniforms
		settingUniforms = false
		rawget(instance, "_props").CompileError = ""
		return true
	end

	function instance:GetUniform(name)
		return (instance.Uniforms or {})[name]
	end

	function instance:GetUniformDefinitions()
		return ShaderInstance.GetUniformDefinitions(instance.Source)
	end

	function instance:GetCompileError()
		return instance.CompileError ~= "" and instance.CompileError or nil
	end

	instance.Changed:Connect(function(property)
		if property == "Source" then
			compile()
		elseif property == "Uniforms" and not settingUniforms then
			applyUniforms()
		elseif (property == "Enabled" or property == "Parent") and onRuntimeChanged then
			onRuntimeChanged(instance, runtimeShader)
		end
	end)
	instance.AncestryChanged:Connect(function()
		if onRuntimeChanged then
			onRuntimeChanged(instance, runtimeShader)
		end
	end)
	instance.Destroying:Connect(function()
		rawset(instance, "_shaderHandle", nil)
		rawset(instance, "_runtimeShader", nil)
		if runtimeShader then
			runtimeShader:Unload()
		end
		runtimeShader = nil
	end)

	if renderer and renderer.Window then
		compile()
	end
	return instance
end

return ShaderInstance
