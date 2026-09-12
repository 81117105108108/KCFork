--!strict
-- tests/object_menu.luau
-- Headless regression tests for the Phase 4.2 Insert Object catalog taxonomy
-- (Geometry / Constraints / Logic / Interaction) and the object menu builders.

local ObjectMenu = require("../src/modules/Immco/components/ObjectMenu")

local passed = 0
local function test(name: string, callback: () -> ()): ()
	callback()
	passed += 1
	print("PASS\t" .. name)
end

test("category order is exactly Geometry/Constraints/Logic/Interaction", function()
	local order = ObjectMenu.CATEGORY_ORDER
	assert(#order == 4, "must expose four categories")
	assert(order[1] == "Geometry" and order[2] == "Constraints", "geometry/constraints first")
	assert(order[3] == "Logic" and order[4] == "Interaction", "logic/interaction last")
end)

test("geometry representatives categorize correctly", function()
	assert(ObjectMenu.categorize("Part") == "Geometry")
	assert(ObjectMenu.categorize("MeshPart") == "Geometry")
	assert(ObjectMenu.categorize("WedgePart") == "Geometry")
	assert(ObjectMenu.categorize("UnionOperation") == "Geometry")
	assert(ObjectMenu.categorize("Model") == "Geometry")
	assert(ObjectMenu.categorize("Folder") == "Geometry")
	assert(ObjectMenu.categorize("SpawnLocation") == "Geometry")
end)

test("constraint representatives categorize correctly", function()
	assert(ObjectMenu.categorize("WeldConstraint") == "Constraints")
	assert(ObjectMenu.categorize("BallSocketConstraint") == "Constraints")
	assert(ObjectMenu.categorize("RopeConstraint") == "Constraints")
	assert(ObjectMenu.categorize("Attachment") == "Constraints")
	assert(ObjectMenu.categorize("Motor6D") == "Constraints")
	assert(ObjectMenu.categorize("Weld") == "Constraints")
end)

test("logic representatives categorize correctly", function()
	assert(ObjectMenu.categorize("Script") == "Logic")
	assert(ObjectMenu.categorize("LocalScript") == "Logic")
	assert(ObjectMenu.categorize("ModuleScript") == "Logic")
	assert(ObjectMenu.categorize("IntValue") == "Logic")
	assert(ObjectMenu.categorize("RemoteEvent") == "Logic")
	assert(ObjectMenu.categorize("BindableFunction") == "Logic")
	assert(ObjectMenu.categorize("Humanoid") == "Logic")
end)

test("interaction representatives categorize correctly", function()
	assert(ObjectMenu.categorize("ClickDetector") == "Interaction")
	assert(ObjectMenu.categorize("ProximityPrompt") == "Interaction")
	assert(ObjectMenu.categorize("Tool") == "Interaction")
	assert(ObjectMenu.categorize("Sound") == "Interaction")
	assert(ObjectMenu.categorize("ParticleEmitter") == "Interaction")
	assert(ObjectMenu.categorize("ScreenGui") == "Interaction")
	assert(ObjectMenu.categorize("Frame") == "Interaction")
	assert(ObjectMenu.categorize("PointLight") == "Interaction")
end)

test("explicit entries win over suffix heuristics", function()
	assert(ObjectMenu.categorize("UIAspectRatioConstraint") == "Interaction", "UI*Constraint is layout, not a joint")
	assert(ObjectMenu.categorize("UISizeConstraint") == "Interaction", "UISizeConstraint is layout, not a joint")
	assert(ObjectMenu.categorize("GroundDetector") == "Logic", "GroundDetector is behavior, not interaction")
end)

test("unlisted future classes fall into deterministic buckets", function()
	assert(ObjectMenu.categorize("MyCustomConstraint") == "Constraints")
	assert(ObjectMenu.categorize("MyCustomScript") == "Logic")
	assert(ObjectMenu.categorize("FooValue") == "Logic")
	assert(ObjectMenu.categorize("BarEvent") == "Logic")
	assert(ObjectMenu.categorize("FooDetector") == "Interaction")
	assert(ObjectMenu.categorize("GlowEffect") == "Interaction")
	assert(ObjectMenu.categorize("MegaPart") == "Geometry")
	assert(ObjectMenu.categorize("SomethingEntirelyNew") == "Logic", "unknown classes land in the misc bucket")
end)

test("groupClasses covers every input exactly once with sorted groups", function()
	local names = { "Tool", "Part", "Script", "WeldConstraint", "Model", "IntValue", "Attachment", "Sound", "Frame", "MeshPart" }
	local groups = ObjectMenu.groupClasses(names)
	local seen: { [string]: boolean } = {}
	local total = 0
	for _, category in ipairs(ObjectMenu.CATEGORY_ORDER) do
		local group = groups[category]
		assert(group ~= nil, "missing group " .. category)
		for index, name in ipairs(group) do
			assert(not seen[name], "duplicate entry " .. name)
			seen[name] = true
			total += 1
			if index > 1 then
				assert(group[index - 1] <= name, category .. " must be sorted")
			end
		end
	end
	assert(total == #names, "every input must appear exactly once")
	assert(#groups.Geometry == 3, "Part/Model/MeshPart are geometry")
	assert(#groups.Constraints == 2, "WeldConstraint/Attachment are constraints")
	assert(#groups.Logic == 2, "Script/IntValue are logic")
	assert(#groups.Interaction == 3, "Tool/Sound/Frame are interaction")
end)

test("buildInsertItems returns four ordered submenus with working callbacks", function()
	local created: { string } = {}
	local items = ObjectMenu.buildInsertItems({ "Tool", "Part", "Script", "WeldConstraint" }, function(className: string)
		table.insert(created, className)
	end)
	assert(#items == 4, "insert menu must expose four category submenus")
	assert(items[1].text == "Geometry" and items[2].text == "Constraints", "submenu order follows CATEGORY_ORDER")
	assert(items[3].text == "Logic" and items[4].text == "Interaction", "submenu order follows CATEGORY_ORDER")
	assert(items[1].children ~= nil and #(items[1].children :: any) == 1, "geometry holds Part")
	assert((items[1].children :: any)[1].text == "Part", "geometry child is Part")
	;((items[1].children :: any)[1].callback :: any)()
	assert(#created == 1 and created[1] == "Part", "child callback must capture its own class")
end)

test("buildObjectItems wires Insert Object plus object actions", function()
	local deleted = 0
	local duplicated = 0
	local inserted: { string } = {}
	local items = ObjectMenu.buildObjectItems({
		insertNames = { "Part", "Script" },
		onInsert = function(className: string)
			table.insert(inserted, className)
		end,
		onDelete = function()
			deleted += 1
		end,
		onDuplicate = function()
			duplicated += 1
		end,
	})
	assert(items[1].text == "Insert Object", "first entry opens the catalog")
	assert(items[1].children ~= nil and #(items[1].children :: any) == 4, "Insert Object holds the four category submenus")
	assert(items[2].separator == true, "separator splits insert from object actions")
	assert(items[3].text == "Delete" and items[3].shortcut == "Del", "delete action present")
	assert(items[4].text == "Duplicate" and items[4].shortcut == "Ctrl+D", "duplicate action present");
	((items[3].callback :: any))()
	;((items[4].callback :: any))()
	assert(deleted == 1 and duplicated == 1, "object callbacks must fire")
	local logicGroup = (items[1].children :: any)[3]
	assert(logicGroup.text == "Logic", "nested order follows CATEGORY_ORDER")
	;((logicGroup.children :: any)[1].callback :: any)()
	assert(#inserted == 1 and inserted[1] == "Script", "nested insert callback must capture its class")
end)

test("buildObjectItems omits actions without callbacks", function()
	local items = ObjectMenu.buildObjectItems({
		onDelete = function() end,
	})
	assert(#items == 3, "only insert + separator + delete when others are missing")
	assert(items[1].disabled == true, "insert without onInsert must be disabled")
	assert((items[1].children :: any) ~= nil and #(items[1].children :: any) == 4, "disabled insert still shows taxonomy")
end)

print(`DONE object_menu tests passed={passed}`)
