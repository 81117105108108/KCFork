return function(context)
	local game = context.game
	local Instance = context.Instance
	local Color3 = context.Color3
	local CFrame = context.CFrame
	local Enum = context.Enum
	local ishared = context.ishared
	local warn = context.warn
	local Selection = game:GetService("Selection")

	local Actions = {}

	local colors = {
		Color3.fromRGB(76, 152, 255),
		Color3.fromRGB(255, 105, 97),
		Color3.fromRGB(112, 214, 128),
		Color3.fromRGB(255, 196, 87),
		Color3.fromRGB(180, 115, 255),
	}
	local colorIndex = 0
	local materialIndex = 0

	local uiClasses = {
		Frame = true,
		TextLabel = true,
		TextButton = true,
		TextBox = true,
		ImageLabel = true,
		ImageButton = true,
		ScrollingFrame = true,
		CanvasGroup = true,
	}

	local uiDecorators = {
		UICorner = true,
		UIGradient = true,
		UIGridLayout = true,
		UIListLayout = true,
		UIPadding = true,
		UIScale = true,
		UIStroke = true,
	}

	local function currentSelection()
		local selected = Selection.Get and Selection.Get() or nil
		return type(selected) == "table" and selected or {}
	end

	local function select(objects)
		if Selection.Set then
			Selection.Set(objects)
		end
	end

	local function selectedParent()
		local selected = currentSelection()
		return selected[1]
	end

	local function create(className)
		local ok, object = pcall(Instance.new, className)
		if not ok then
			warn(("Topbar could not create %s: %s"):format(tostring(className), tostring(object)))
			return nil
		end
		return object
	end

	local function ensureScreenGui()
		local StarterGui = game:GetService("StarterGui")
		local selected = selectedParent()
		if selected then
			if selected.ClassName == "ScreenGui" then
				return selected
			end
			local ancestor = selected
			while ancestor do
				if ancestor.ClassName == "ScreenGui" then
					return ancestor
				end
				ancestor = ancestor.Parent
			end
		end

		local screen = StarterGui:FindFirstChildOfClass("ScreenGui")
		if not screen then
			screen = create("ScreenGui")
			if screen then
				screen.Name = "ScreenGui"
				screen.Parent = StarterGui
			end
		end
		return screen
	end

	local function defaultParent(className)
		local selected = selectedParent()
		if className == "ScreenGui" then
			return game:GetService("StarterGui")
		elseif uiClasses[className] then
			if selected and (selected.BaseClass == "GuiObject" or selected.ClassName == "ScreenGui") then
				return selected
			end
			return ensureScreenGui()
		elseif uiDecorators[className] then
			if selected and selected.BaseClass == "GuiObject" then
				return selected
			end
			return ensureScreenGui()
		elseif className == "Script" or className == "ModuleScript" then
			return selected or game:GetService("ServerScriptService")
		elseif className == "LocalScript" then
			local StarterPlayer = game:GetService("StarterPlayer")
			return selected or StarterPlayer:FindFirstChild("StarterPlayerScripts") or StarterPlayer
		elseif className == "Accessory" or className == "Animation" or className == "Animator" then
			return selected or game:GetService("Workspace")
		elseif className == "Attachment" or className:find("Constraint", 1, true) or className == "ParticleEmitter" then
			return selected or game:GetService("Workspace")
		end
		return game:GetService("Workspace")
	end

	local function insertInstance(className, name)
		local object = create(className)
		if not object then
			return nil
		end
		if name then
			object.Name = name
		end
		object.Parent = defaultParent(className)
		select({ object })
		return object
	end

	local function selectedParts()
		local parts = {}
		for _, object in ipairs(currentSelection()) do
			if object.IsA and object:IsA("BasePart") then
				table.insert(parts, object)
			end
		end
		return parts
	end

	local function createCharacter()
		local model = create("Model")
		local humanoid = create("Humanoid")
		if not model or not humanoid then
			return
		end
		model.Name = "Character"
		model.Parent = game:GetService("Workspace")
		return pcall(function()
			humanoid.Parent = model
			humanoid:CreateDefaultRig()
			select({ model })
		end)
	end

	local function groupSelection()
		local selected = currentSelection()
		if #selected == 1 and selected[1].ClassName == "Model" then
			local model = selected[1]
			local parent = model.Parent or game:GetService("Workspace")
			local children = model:GetChildren()
			for _, child in ipairs(children) do
				child.Parent = parent
			end
			model:Destroy()
			select(children)
			return
		end
		if #selected == 0 then
			return
		end
		local model = create("Model")
		if not model then
			return
		end
		model.Name = "Model"
		model.Parent = selected[1].Parent or game:GetService("Workspace")
		for _, object in ipairs(selected) do
			object.Parent = model
		end
		select({ model })
	end

	local function togglePartProperty(property)
		local parts = selectedParts()
		if #parts == 0 then
			return
		end
		local nextValue = not parts[1][property]
		for _, part in ipairs(parts) do
			part[property] = nextValue
		end
	end

	local function paintSelection()
		colorIndex = (colorIndex % #colors) + 1
		for _, part in ipairs(selectedParts()) do
			part.Color = colors[colorIndex]
		end
	end

	local function cycleMaterial()
		local items = Enum.Material:GetEnumItems()
		if #items == 0 then
			return
		end
		materialIndex = (materialIndex % #items) + 1
		for _, part in ipairs(selectedParts()) do
			part.Material = items[materialIndex]
		end
	end

	local function resetTransform()
		for _, object in ipairs(currentSelection()) do
			if object.IsA and object:IsA("BasePart") then
				object.CFrame = CFrame.new(object.CFrame.Position)
			elseif object.ClassName == "Model" and object.GetPivot and object.PivotTo then
				object:PivotTo(CFrame.new(object:GetPivot().Position))
			end
		end
	end

	local function setPivot()
		for _, object in ipairs(currentSelection()) do
			if object.ClassName == "Model" and object.SetPivot then
				local primary = object.PrimaryPart or object:FindFirstChildOfClass("BasePart")
				if primary then
					object:SetPivot(primary.CFrame)
				end
			elseif object.IsA and object:IsA("BasePart") and object.Parent and object.Parent.ClassName == "Model" then
				object.Parent:SetPivot(object.CFrame)
			end
		end
	end

	local function alignSelection()
		local parts = selectedParts()
		local target = parts[1]
		if not target then
			return
		end
		for index = 2, #parts do
			local part = parts[index]
			part.CFrame = CFrame.new(target.CFrame.Position) * part.CFrame.Rotation
		end
	end

	local function weldSelection()
		local parts = selectedParts()
		if #parts < 2 then
			return
		end
		local weld = create("WeldConstraint")
		if not weld then
			return
		end
		weld.Part0 = parts[1]
		weld.Part1 = parts[2]
		weld.Parent = parts[1]
		select({ weld })
	end

	local function constrainSelection()
		local parts = selectedParts()
		if #parts < 2 then
			return
		end
		local attachment0 = create("Attachment")
		local attachment1 = create("Attachment")
		local constraint = create("BallSocketConstraint")
		if not attachment0 or not attachment1 or not constraint then
			return
		end
		attachment0.Parent = parts[1]
		attachment1.Parent = parts[2]
		constraint.Attachment0 = attachment0
		constraint.Attachment1 = attachment1
		constraint.Parent = parts[1]
		select({ constraint })
	end

	local function runCsg(method)
		local parts = selectedParts()
		if #parts < 2 then
			return
		end
		local primary = parts[1]
		local operands = { table.unpack(parts, 2) }
		local GeometryService = game:GetService("GeometryService")
		local operation = GeometryService[method]
		if type(operation) ~= "function" then
			return
		end
		local results = operation(GeometryService, primary, operands, {})
		if type(results) ~= "table" or not results[1] then
			return
		end
		local parent = primary.Parent or game:GetService("Workspace")
		local result = results[1]
		result.ConnectedParts = parts
		result.Parent = parent
		for _, part in ipairs(parts) do
			part.Parent = nil
		end
		select({ result })
	end

	local function separateSelection()
		local separated = {}
		for _, object in ipairs(currentSelection()) do
			local connected = object.ConnectedParts
			if type(connected) == "table" and #connected > 0 then
				local parent = object.Parent or game:GetService("Workspace")
				for _, part in ipairs(connected) do
					part.Parent = parent
					table.insert(separated, part)
				end
				object:Destroy()
			end
		end
		if #separated > 0 then
			select(separated)
		end
	end

	local function importMesh()
		local FileDialogService = game:GetService("FileDialogService")
		local path = FileDialogService.RequestFile({
			{ name = "3D Models", extensions = { "gltf", "glb", "obj" } },
		})
		if not path or path == "" then
			return
		end
		local mesh = insertInstance("MeshPart", "ImportedMesh")
		if mesh then
			mesh.MeshId = path
		end
	end

	local commands = {
		tool = function(value)
			ishared.StudioSystem:Fire("set_viewport_tool", value)
		end,
		insert = insertInstance,
		character = createCharacter,
		group = groupSelection,
		anchor = function()
			togglePartProperty("Anchored")
		end,
		lock = function()
			togglePartProperty("Locked")
		end,
		color = paintSelection,
		material = cycleMaterial,
		reset = resetTransform,
		pivot = setPivot,
		align = alignSelection,
		weld = weldSelection,
		constraint = constrainSelection,
		union = function()
			runCsg("UnionAsync")
		end,
		intersect = function()
			runCsg("IntersectAsync")
		end,
		negate = function()
			runCsg("SubtractAsync")
		end,
		separate = separateSelection,
		import = importMesh,
		route = function(route, ...)
			ishared.StudioSystem:Fire(route, ...)
		end,
		select_service = function(serviceName)
			local service = game:GetService(serviceName)
			select({ service })
		end,
	}

	function Actions.run(action)
		local command = commands[action.command]
		if not command then
			warn("Unknown topbar command: " .. tostring(action.command))
			return
		end
		return command(table.unpack(action.arguments or {}))
	end

	return Actions
end
