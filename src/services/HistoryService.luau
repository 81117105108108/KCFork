--!strict
-- HistoryService.luau
-- Reversible undo/redo action stack for editor mutations.
--
-- Covers:
--   * property mutations  (Changed / GetPropertyChangedSignal sources)
--   * hierarchy changes   (Parent / AncestryChanged sources)
--   * instantiation       (Instance.new + Parent / ChildAdded sources)
--   * deletion            (Parent = nil / ChildRemoved / Destroying sources)
--
-- Design notes:
--   * Pure Luau with no external requires, so it stays headless-testable
--     (see tests/history_service.luau) and imposes no load order on callers.
--   * Operates on duck-typed instances: anything indexable by property name
--     with an assignable `Parent` field. Real Instances trigger __newindex
--     (and therefore Changed/AncestryChanged) on apply; plain tables work
--     for headless tests.
--   * Undo application never re-records: `IsApplying()` is true while an
--     action is being applied, so `Watch*` helpers and editor call sites
--     can skip recording reflected changes.
--   * True `:Destroy()` is irreversible by the engine (props are wiped), so
--     undoable deletes go through `RecordDelete`/`DoDelete`, which detach
--     (Parent = nil) instead of destroying. A pre-delete `Clone` snapshot is
--     captured best-effort so undo can resurrect even a destroyed instance.
--   * Editor shortcut wiring lives here via `ConnectEditorShortcuts`, which
--     binds Ctrl+Z (undo) and Ctrl+Y / Ctrl+Shift+Z (redo) on a
--     UserInputService-like object. Text-box focus and processed events are
--     skipped by default so field-level Ctrl+Z keeps working.

export type HistoryInstance = { [string]: any }
export type HistoryActionKind = "property" | "parent" | "create" | "delete"

export type HistoryAction = {
	kind: HistoryActionKind,
	instance: HistoryInstance?,
	label: string?,
	property: string?,
	before: any,
	after: any,
	parent: HistoryInstance?,
	index: number?,
	snapshot: HistoryInstance?,
}

export type PushOptions = {
	label: string?,
	coalesce: boolean?,
}

export type ShortcutOptions = {
	allowProcessed: boolean?,
	allowWhileTyping: boolean?,
	onUndo: ((ok: boolean) -> ())?,
	onRedo: ((ok: boolean) -> ())?,
}

export type HistoryService = {
	RecordSetProperty: (self: HistoryService, instance: HistoryInstance, property: string, before: any, after: any, opts: PushOptions?) -> boolean,
	DoSetProperty: (self: HistoryService, instance: HistoryInstance, property: string, after: any, opts: PushOptions?) -> boolean,
	RecordSetParent: (self: HistoryService, instance: HistoryInstance, before: HistoryInstance?, after: HistoryInstance?, opts: PushOptions?) -> boolean,
	DoSetParent: (self: HistoryService, instance: HistoryInstance, parent: HistoryInstance?, opts: PushOptions?) -> boolean,
	RecordCreate: (self: HistoryService, instance: HistoryInstance, parent: HistoryInstance?, opts: PushOptions?) -> boolean,
	DoCreate: (self: HistoryService, factory: () -> HistoryInstance?, parent: HistoryInstance?, opts: PushOptions?) -> HistoryInstance?,
	RecordDelete: (self: HistoryService, instance: HistoryInstance, opts: PushOptions?) -> boolean,
	DoDelete: (self: HistoryService, instance: HistoryInstance, opts: PushOptions?) -> boolean,
	Undo: (self: HistoryService) -> boolean,
	Redo: (self: HistoryService) -> boolean,
	CanUndo: (self: HistoryService) -> boolean,
	CanRedo: (self: HistoryService) -> boolean,
	GetUndoCount: (self: HistoryService) -> number,
	GetRedoCount: (self: HistoryService) -> number,
	PeekUndo: (self: HistoryService) -> HistoryAction?,
	PeekRedo: (self: HistoryService) -> HistoryAction?,
	Clear: (self: HistoryService) -> (),
	SetMaxSize: (self: HistoryService, maxSize: number) -> (),
	GetMaxSize: (self: HistoryService) -> number,
	IsApplying: (self: HistoryService) -> boolean,
	HandleShortcut: (self: HistoryService, keyName: string?, ctrlDown: boolean?, shiftDown: boolean?) -> string?,
	ConnectEditorShortcuts: (self: HistoryService, userInputService: any, opts: ShortcutOptions?) -> any?,
	AttachChangeHistory: (self: HistoryService, changeHistory: any?) -> (),
}

local DEFAULT_MAX_SIZE = 200

local function isDestroyed(instance: any): boolean
	if type(instance) ~= "table" then
		return true
	end
	local ok, value = pcall(function(): any
		return (instance :: HistoryInstance).Destroyed
	end)
	return ok and value == true
end

local function readField(instance: any, key: string): (boolean, any)
	if type(instance) ~= "table" or type(key) ~= "string" then
		return false, nil
	end
	local ok, value = pcall(function(): any
		return (instance :: HistoryInstance)[key]
	end)
	return ok, if ok then value else nil
end

local function instanceName(instance: any): string
	if type(instance) ~= "table" then
		return "?"
	end
	local ok, name = pcall(function(): any
		return (instance :: HistoryInstance).Name
	end)
	if ok and type(name) == "string" and #name > 0 then
		return name
	end
	return "?"
end

local function applyProperty(instance: HistoryInstance?, property: string?, value: any): boolean
	if type(instance) ~= "table" or type(property) ~= "string" then
		return false
	end
	if isDestroyed(instance) then
		return false
	end
	local target = instance :: HistoryInstance
	local setter: any = target.SetProperty
	if type(setter) == "function" then
		local ok = pcall(setter, target, property, value)
		return ok
	end
	local ok = pcall(function(): ()
		target[property :: string] = value
	end)
	return ok
end

local function applyParent(instance: HistoryInstance?, parent: HistoryInstance?): boolean
	if type(instance) ~= "table" then
		return false
	end
	if isDestroyed(instance) then
		return false
	end
	if parent ~= nil and (type(parent) ~= "table" or isDestroyed(parent)) then
		return false
	end
	local target = instance :: HistoryInstance
	local ok = pcall(function(): ()
		target.Parent = parent
	end)
	return ok
end

local function captureSiblingIndex(instance: HistoryInstance, parent: HistoryInstance?): number?
	if type(parent) ~= "table" then
		return nil
	end
	local holder = parent :: HistoryInstance
	if type(holder.GetChildren) ~= "function" then
		return nil
	end
	local ok, children = pcall(holder.GetChildren, holder)
	if not ok or type(children) ~= "table" then
		return nil
	end
	for index, child in ipairs(children) do
		if rawequal(child, instance) or child == instance then
			return index
		end
	end
	return nil
end

local function captureSnapshot(instance: HistoryInstance): HistoryInstance?
	local target = instance :: HistoryInstance
	if type(target.Clone) ~= "function" then
		return nil
	end
	local ok, snapshot = pcall(target.Clone, target)
	if not ok or type(snapshot) ~= "table" then
		return nil
	end
	return snapshot
end

local function resurrect(action: HistoryAction, parent: HistoryInstance?): HistoryInstance?
	local snapshot = action.snapshot
	if type(snapshot) ~= "table" or type(parent) ~= "table" then
		return nil
	end
	local cloneFn: any = (snapshot :: HistoryInstance).Clone
	if type(cloneFn) ~= "function" then
		return nil
	end
	local ok, clone = pcall(cloneFn, snapshot)
	if not ok or type(clone) ~= "table" then
		return nil
	end
	if not applyParent(clone, parent) then
		pcall(function(): ()
			(clone :: HistoryInstance):Destroy()
		end)
		return nil
	end
	action.instance = clone
	return clone
end

local function defaultLabel(kind: HistoryActionKind, instance: HistoryInstance?, property: string?): string
	if kind == "property" then
		return `Set {property or "?"} on {instanceName(instance)}`
	elseif kind == "parent" then
		return `Reparent {instanceName(instance)}`
	elseif kind == "create" then
		return `Create {instanceName(instance)}`
	else
		return `Delete {instanceName(instance)}`
	end
end

local function createService(): HistoryService
	local self = {} :: HistoryService
	local undoStack: { HistoryAction } = {}
	local redoStack: { HistoryAction } = {}
	local maxSize = DEFAULT_MAX_SIZE
	local applying = false
	local changeHistory: any = nil

	local function fireChangeHistory(signalName: string): ()
		if changeHistory == nil then
			return
		end
		local ok, signal = pcall(function(): any
			return (changeHistory :: any)[signalName]
		end)
		if not ok or signal == nil then
			return
		end
		if type(signal) == "function" then
			pcall(signal, changeHistory)
		elseif type(signal) == "table" and type((signal :: any).Fire) == "function" then
			pcall((signal :: any).Fire, signal)
		end
	end

	local function trim(stack: { HistoryAction }): ()
		while #stack > maxSize do
			table.remove(stack, 1)
		end
	end

	local function push(action: HistoryAction): ()
		table.insert(undoStack, action)
		trim(undoStack)
		table.clear(redoStack)
	end

	local function sameTarget(top: HistoryAction, kind: HistoryActionKind, instance: HistoryInstance, property: string?): boolean
		return top.kind == kind and top.instance == instance and top.property == property
	end

	function self.RecordSetProperty(
		_self: HistoryService,
		instance: HistoryInstance,
		property: string,
		before: any,
		after: any,
		opts: PushOptions?
	): boolean
		if type(instance) ~= "table" or type(property) ~= "string" or isDestroyed(instance) then
			return false
		end
		if before == after then
			return false
		end
		local options = opts or {}
		local top = undoStack[#undoStack]
		if options.coalesce == true and top ~= nil and sameTarget(top, "property", instance, property) then
			top.after = after
			if top.before == top.after then
				table.remove(undoStack, #undoStack)
				return false
			end
			if options.label ~= nil then
				top.label = options.label
			end
			table.clear(redoStack)
			return true
		end
		push({
			kind = "property",
			instance = instance,
			label = options.label or defaultLabel("property", instance, property),
			property = property,
			before = before,
			after = after,
			parent = nil,
			index = nil,
			snapshot = nil,
		})
		return true
	end

	function self.DoSetProperty(
		_self: HistoryService,
		instance: HistoryInstance,
		property: string,
		after: any,
		opts: PushOptions?
	): boolean
		local _, before = readField(instance, property)
		if not applyProperty(instance, property, after) then
			return false
		end
		if before == after then
			return true
		end
		return self:RecordSetProperty(instance, property, before, after, opts)
	end

	function self.RecordSetParent(
		_self: HistoryService,
		instance: HistoryInstance,
		before: HistoryInstance?,
		after: HistoryInstance?,
		opts: PushOptions?
	): boolean
		if type(instance) ~= "table" or isDestroyed(instance) then
			return false
		end
		if before == after then
			return false
		end
		local options = opts or {}
		push({
			kind = "parent",
			instance = instance,
			label = options.label or defaultLabel("parent", instance, nil),
			property = "Parent",
			before = before,
			after = after,
			parent = nil,
			index = nil,
			snapshot = nil,
		})
		return true
	end

	function self.DoSetParent(
		_self: HistoryService,
		instance: HistoryInstance,
		parent: HistoryInstance?,
		opts: PushOptions?
	): boolean
		local _, before = readField(instance, "Parent")
		if not applyParent(instance, parent) then
			return false
		end
		if before == parent then
			return true
		end
		return self:RecordSetParent(instance, before, parent, opts)
	end

	function self.RecordCreate(
		_self: HistoryService,
		instance: HistoryInstance,
		parent: HistoryInstance?,
		opts: PushOptions?
	): boolean
		if type(instance) ~= "table" or isDestroyed(instance) then
			return false
		end
		local options = opts or {}
		local owner = parent
		if owner == nil then
			local _, current = readField(instance, "Parent")
			owner = if type(current) == "table" then current else nil
		end
		push({
			kind = "create",
			instance = instance,
			label = options.label or defaultLabel("create", instance, nil),
			property = nil,
			before = nil,
			after = nil,
			parent = owner,
			index = nil,
			snapshot = nil,
		})
		return true
	end

	function self.DoCreate(
		_self: HistoryService,
		factory: () -> HistoryInstance?,
		parent: HistoryInstance?,
		opts: PushOptions?
	): HistoryInstance?
		if type(factory) ~= "function" then
			return nil
		end
		local ok, instance = pcall(factory)
		if not ok or type(instance) ~= "table" then
			return nil
		end
		if not applyParent(instance, parent) then
			return nil
		end
		if not self:RecordCreate(instance, parent, opts) then
			return nil
		end
		return instance
	end

	function self.RecordDelete(_self: HistoryService, instance: HistoryInstance, opts: PushOptions?): boolean
		if type(instance) ~= "table" or isDestroyed(instance) then
			return false
		end
		local _, parent = readField(instance, "Parent")
		local owner = if type(parent) == "table" then parent else nil
		local options = opts or {}
		push({
			kind = "delete",
			instance = instance,
			label = options.label or defaultLabel("delete", instance, nil),
			property = nil,
			before = nil,
			after = nil,
			parent = owner,
			index = captureSiblingIndex(instance, owner),
			snapshot = captureSnapshot(instance),
		})
		return true
	end

	function self.DoDelete(_self: HistoryService, instance: HistoryInstance, opts: PushOptions?): boolean
		if not self:RecordDelete(instance, opts) then
			return false
		end
		return applyParent(instance, nil)
	end

	local function applyUndo(action: HistoryAction): boolean
		local instance = action.instance
		if action.kind == "property" then
			return applyProperty(instance, action.property, action.before)
		elseif action.kind == "parent" then
			return applyParent(instance, action.before)
		elseif action.kind == "create" then
			return applyParent(instance, nil)
		else
			if type(instance) == "table" and not isDestroyed(instance) then
				return applyParent(instance, action.parent)
			end
			return resurrect(action, action.parent) ~= nil
		end
	end

	local function applyRedo(action: HistoryAction): boolean
		local instance = action.instance
		if action.kind == "property" then
			return applyProperty(instance, action.property, action.after)
		elseif action.kind == "parent" then
			return applyParent(instance, action.after)
		elseif action.kind == "create" then
			return applyParent(instance, action.parent)
		else
			return applyParent(instance, nil)
		end
	end

	function self.Undo(_self: HistoryService): boolean
		local action = table.remove(undoStack, #undoStack)
		if action == nil then
			return false
		end
		applying = true
		local ok = false
		local success, result = pcall(applyUndo, action)
		ok = success and result == true
		applying = false
		table.insert(redoStack, action)
		trim(redoStack)
		fireChangeHistory("OnUndo")
		return ok
	end

	function self.Redo(_self: HistoryService): boolean
		local action = table.remove(redoStack, #redoStack)
		if action == nil then
			return false
		end
		applying = true
		local ok = false
		local success, result = pcall(applyRedo, action)
		ok = success and result == true
		applying = false
		table.insert(undoStack, action)
		trim(undoStack)
		fireChangeHistory("OnRedo")
		return ok
	end

	function self.CanUndo(_self: HistoryService): boolean
		return #undoStack > 0
	end

	function self.CanRedo(_self: HistoryService): boolean
		return #redoStack > 0
	end

	function self.GetUndoCount(_self: HistoryService): number
		return #undoStack
	end

	function self.GetRedoCount(_self: HistoryService): number
		return #redoStack
	end

	function self.PeekUndo(_self: HistoryService): HistoryAction?
		return undoStack[#undoStack]
	end

	function self.PeekRedo(_self: HistoryService): HistoryAction?
		return redoStack[#redoStack]
	end

	function self.Clear(_self: HistoryService): ()
		table.clear(undoStack)
		table.clear(redoStack)
	end

	function self.SetMaxSize(_self: HistoryService, newMax: number): ()
		if type(newMax) == "number" and newMax >= 1 then
			maxSize = math.floor(newMax)
			trim(undoStack)
			trim(redoStack)
		end
	end

	function self.GetMaxSize(_self: HistoryService): number
		return maxSize
	end

	function self.IsApplying(_self: HistoryService): boolean
		return applying
	end

	function self.HandleShortcut(
		_self: HistoryService,
		keyName: string?,
		ctrlDown: boolean?,
		shiftDown: boolean?
	): string?
		if ctrlDown ~= true or type(keyName) ~= "string" then
			return nil
		end
		local key = string.upper(keyName)
		if key == "Z" then
			if shiftDown == true then
				return "redo"
			end
			return "undo"
		elseif key == "Y" then
			return "redo"
		end
		return nil
	end

	function self.ConnectEditorShortcuts(
		_self: HistoryService,
		userInputService: any,
		opts: ShortcutOptions?
	): any?
		if type(userInputService) ~= "table" then
			return nil
		end
		local options = opts or {}
		local okSignal, inputBegan = pcall(function(): any
			return (userInputService :: any).InputBegan
		end)
		if not okSignal or inputBegan == nil or type((inputBegan :: any).Connect) ~= "function" then
			return nil
		end
		local function isCtrlDown(input: any): boolean
			if type(input) == "table" and type((input :: any).IsModifierKeyDown) == "function" then
				local ok, down = pcall((input :: any).IsModifierKeyDown, input, "Ctrl")
				if ok then
					return down == true
				end
			end
			if type((userInputService :: any).IsModifierKeyDown) == "function" then
				local ok, down = pcall((userInputService :: any).IsModifierKeyDown, userInputService, "Ctrl")
				if ok then
					return down == true
				end
			end
			return false
		end
		local function isShiftDown(input: any): boolean
			if type(input) == "table" and type((input :: any).IsModifierKeyDown) == "function" then
				local ok, down = pcall((input :: any).IsModifierKeyDown, input, "Shift")
				if ok then
					return down == true
				end
			end
			return false
		end
		local function hasTextFocus(): boolean
			local getter: any = (userInputService :: any).GetFocusedTextBox
			if type(getter) ~= "function" then
				return false
			end
			local ok, focused = pcall(getter, userInputService)
			return ok and focused ~= nil
		end
		local okConnect, connection = pcall((inputBegan :: any).Connect, inputBegan, function(input: any, processed: boolean?): ()
			if processed == true and options.allowProcessed ~= true then
				return
			end
			if options.allowWhileTyping ~= true and hasTextFocus() then
				return
			end
			local keyName: string? = nil
			if type(input) == "table" then
				local okKey, keyCode = pcall(function(): any
					return (input :: any).KeyCode
				end)
				if okKey and type(keyCode) == "table" then
					local okName, name = pcall(function(): any
						return (keyCode :: any).Name
					end)
					if okName and type(name) == "string" then
						keyName = name
					end
				elseif okKey and type(keyCode) == "string" then
					keyName = keyCode
				end
			end
			local intent = self:HandleShortcut(keyName, isCtrlDown(input), isShiftDown(input))
			if intent == "undo" then
				local okUndo = self:Undo()
				if type(options.onUndo) == "function" then
					pcall(options.onUndo, okUndo);
				end
			elseif intent == "redo" then
				local okRedo = self:Redo()
				if type(options.onRedo) == "function" then
					pcall(options.onRedo, okRedo);
				end
			end
		end)
		if not okConnect then
			return nil
		end
		return connection
	end

	function self.AttachChangeHistory(_self: HistoryService, changeHistoryService: any?): ()
		changeHistory = changeHistoryService
	end

	return self
end

local sharedService = createService()

return table.freeze({
	new = createService,
	shared = sharedService,
	DEFAULT_MAX_SIZE = DEFAULT_MAX_SIZE,
})
