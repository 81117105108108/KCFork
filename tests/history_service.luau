--!strict
-- tests/history_service.luau
-- Focused headless tests for src/services/HistoryService.luau:
-- property / hierarchy / create / delete undo-redo plus Ctrl+Z / Ctrl+Y wiring.

local HistoryServiceModule = require("../src/services/HistoryService")

local passed = 0
local function test(name: string, callback: () -> ()): ()
	callback()
	passed += 1
	print("PASS\t" .. name)
end

local function mockInstance(name: string): any
	local instance: any = {
		Name = name,
		ClassName = "Part",
		Parent = nil,
		Destroyed = nil,
		_children = {},
	}
	function instance:GetChildren(): { any }
		local copy = {}
		for i, child in ipairs(self._children) do
			copy[i] = child
		end
		return copy
	end
	function instance:Destroy(): ()
		self.Destroyed = true
		self.Parent = nil
	end
	return instance
end

local function attachChild(parent: any, child: any): ()
	child.Parent = parent
	table.insert(parent._children, child)
end

local function makeKeyInput(keyName: string, ctrl: boolean, shift: boolean?): any
	return {
		KeyCode = { Name = keyName },
		IsModifierKeyDown = function(_self: any, modifier: string): boolean
			if modifier == "Ctrl" then
				return ctrl
			elseif modifier == "Shift" then
				return shift == true
			end
			return false
		end,
	}
end

local function makeFakeUIS(): any
	local handler: any = nil
	local uis: any = {
		focused = nil,
	}
	uis.InputBegan = {
		Connect = function(_self: any, fn: any): any
			handler = fn
			return {
				Disconnect = function(): ()
					handler = nil
				end,
			}
		end,
	}
	function uis:GetFocusedTextBox(): any
		return self.focused
	end
	function uis:fire(input: any, processed: boolean?): ()
		assert(handler ~= nil, "no shortcut handler connected")
		handler(input, processed)
	end
	return uis
end

test("property undo/redo round-trips value", function()
	local service = HistoryServiceModule.new()
	local part = mockInstance("Brick")
	part.Color = "Red"
	assert(service:DoSetProperty(part, "Color", "Blue") == true)
	assert(part.Color == "Blue")
	assert(service:CanUndo() and not service:CanRedo())
	assert(service:Undo() == true)
	assert(part.Color == "Red")
	assert(service:CanRedo())
	assert(service:Redo() == true)
	assert(part.Color == "Blue")
end)

test("no-op property push is rejected and redo clears on new push", function()
	local service = HistoryServiceModule.new()
	local part = mockInstance("Brick")
	part.Size = 1
	assert(service:RecordSetProperty(part, "Size", 1, 1) == false)
	assert(service:CanUndo() == false)
	service:DoSetProperty(part, "Size", 2)
	service:Undo()
	assert(service:CanRedo())
	service:DoSetProperty(part, "Size", 3)
	assert(service:CanRedo() == false)
	assert(part.Size == 3)
end)

test("coalesced property edits merge into one undo step", function()
	local service = HistoryServiceModule.new()
	local part = mockInstance("Slider")
	part.Transparency = 0
	service:RecordSetProperty(part, "Transparency", 0, 0.25, { coalesce = true })
	part.Transparency = 0.25
	service:RecordSetProperty(part, "Transparency", 0.25, 0.5, { coalesce = true })
	part.Transparency = 0.5
	assert(service:GetUndoCount() == 1)
	assert(service:Undo() == true)
	assert(part.Transparency == 0)
end)

test("hierarchy reparent undo/redo restores parents", function()
	local service = HistoryServiceModule.new()
	local a = mockInstance("A")
	local b = mockInstance("B")
	local part = mockInstance("Brick")
	attachChild(a, part)
	assert(service:DoSetParent(part, b) == true)
	assert(part.Parent == b)
	assert(service:Undo() == true)
	assert(part.Parent == a)
	assert(service:Redo() == true)
	assert(part.Parent == b)
end)

test("create undo detaches and redo reattaches", function()
	local service = HistoryServiceModule.new()
	local workspace = mockInstance("Workspace")
	local created = service:DoCreate(function(): any
		return mockInstance("NewPart")
	end, workspace)
	assert(created ~= nil and created.Parent == workspace)
	assert(service:Undo() == true)
	assert(created.Parent == nil)
	assert(service:Redo() == true)
	assert(created.Parent == workspace)
end)

test("delete undo restores parent and redo detaches again", function()
	local service = HistoryServiceModule.new()
	local workspace = mockInstance("Workspace")
	local part = mockInstance("Brick")
	attachChild(workspace, part)
	assert(service:DoDelete(part) == true)
	assert(part.Parent == nil)
	assert(service:Undo() == true)
	assert(part.Parent == workspace)
	assert(service:Redo() == true)
	assert(part.Parent == nil)
end)

test("undo on destroyed instance is safe and reports failure", function()
	local service = HistoryServiceModule.new()
	local part = mockInstance("Brick")
	part.Color = "Red"
	service:DoSetProperty(part, "Color", "Blue")
	part:Destroy()
	assert(service:Undo() == false)
	assert(service:CanRedo() == true)
end)

test("max size trims oldest actions", function()
	local service = HistoryServiceModule.new()
	service:SetMaxSize(3)
	local part = mockInstance("Brick")
	for i = 1, 5 do
		part.N = i - 1
		service:DoSetProperty(part, "N", i)
	end
	assert(service:GetUndoCount() == 3)
	assert(service:GetMaxSize() == 3)
end)

test("HandleShortcut maps Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z", function()
	local service = HistoryServiceModule.new()
	assert(service:HandleShortcut("Z", true, false) == "undo")
	assert(service:HandleShortcut("z", true, nil) == "undo")
	assert(service:HandleShortcut("Y", true, false) == "redo")
	assert(service:HandleShortcut("Z", true, true) == "redo")
	assert(service:HandleShortcut("Z", false, false) == nil)
	assert(service:HandleShortcut("A", true, false) == nil)
	assert(service:HandleShortcut(nil, true, false) == nil)
end)

test("Ctrl+Z / Ctrl+Y shortcut wiring drives undo/redo", function()
	local service = HistoryServiceModule.new()
	local uis = makeFakeUIS()
	local connection = service:ConnectEditorShortcuts(uis, {})
	assert(connection ~= nil)
	local part = mockInstance("Brick")
	part.Color = "Red"
	service:DoSetProperty(part, "Color", "Blue")
	uis:fire(makeKeyInput("Z", true), false)
	assert(part.Color == "Red")
	uis:fire(makeKeyInput("Y", true), false)
	assert(part.Color == "Blue")
	uis:fire(makeKeyInput("Z", true), false)
	assert(part.Color == "Red")
	uis:fire(makeKeyInput("Z", true, true), false)
	assert(part.Color == "Blue")
	connection.Disconnect()
end)

test("shortcut wiring ignores processed events and text focus", function()
	local service = HistoryServiceModule.new()
	local uis = makeFakeUIS()
	service:ConnectEditorShortcuts(uis, {})
	local part = mockInstance("Brick")
	part.Color = "Red"
	service:DoSetProperty(part, "Color", "Blue")
	uis:fire(makeKeyInput("Z", true), true)
	assert(part.Color == "Blue")
	uis.focused = { Name = "TextBox" }
	uis:fire(makeKeyInput("Z", true), false)
	assert(part.Color == "Blue")
	uis.focused = nil
	uis:fire(makeKeyInput("Z", false), false)
	assert(part.Color == "Blue")
end)

test("AttachChangeHistory fires OnUndo/OnRedo signals", function()
	local service = HistoryServiceModule.new()
	local fired: { string } = {}
	local changeHistory: any = {
		OnUndo = { Fire = function(_self: any): () table.insert(fired, "undo") end },
		OnRedo = { Fire = function(_self: any): () table.insert(fired, "redo") end },
	}
	service:AttachChangeHistory(changeHistory)
	local part = mockInstance("Brick")
	part.Color = "Red"
	service:DoSetProperty(part, "Color", "Blue")
	service:Undo()
	service:Redo()
	assert(#fired == 2 and fired[1] == "undo" and fired[2] == "redo")
	service:AttachChangeHistory(nil)
end)

print(string.format("%d history service tests passed", passed))
