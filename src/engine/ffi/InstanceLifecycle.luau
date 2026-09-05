--!strict

local resources = require("./ResourceTracker").shared

type Signal = { Fire: (self: Signal) -> (), Destroy: (self: Signal) -> () }
type State = {
	_props: { Name: string?, Parent: State?, [string]: any }?,
	_children: { State }?,
	_childByName: { [string]: State }?,
	Destroy: (self: State) -> (),
	Parent: State?,
}

local SIGNALS = {
	"ChildAdded", "AncestryChanged", "Changed", "ChildRemoved",
	"DescendantRemoving", "Destroying", "DescendantAdded", "DescendantChanged",
}

local function destroy(owner: {}): ()
	if rawget(owner, "Destroyed") or rawget(owner, "_destroying") then
		return
	end
	rawset(owner, "_destroying", true)
	local self = owner :: State
	local failures: { string } = {}
	local function attempt(callback: () -> ()): ()
		local ok, failure = pcall(function(): unknown
			callback()
			return nil
		end)
		if not ok then
			table.insert(failures, if type(failure) == "string" then failure else "Non-string destruction error")
		end
	end

	local destroying: Signal? = rawget(owner, "Destroying")
	if destroying then
		attempt(function(): () destroying:Fire() end)
	end
	local children: { State } = table.clone(rawget(owner, "_children") or {})
	local props = self._props
	local parent = if props then props.Parent else nil
	if parent then
		attempt(function(): () self.Parent = nil end)
		-- Parent barriers/listeners may fail before __newindex finishes detaching.
		local siblings = rawget(parent, "_children") :: { State }?
		if siblings then
			for index = #siblings, 1, -1 do
				if rawequal(siblings[index], self) then
					table.remove(siblings, index)
				end
			end
		end
		local names = rawget(parent, "_childByName") :: { [string]: State }?
		local name = if props then props.Name else nil
		if names and name and rawequal(names[name], self) then
			names[name] = nil
			for _, sibling in ipairs(siblings or {}) do
				local siblingProps: { Name: string? }? = rawget(sibling :: {}, "_props")
				if siblingProps and siblingProps.Name == name then
					names[name] = sibling
					break
				end
			end
		end
		if props then props.Parent = nil end
	end
	rawset(owner, "_children", {})
	rawset(owner, "_childByName", {})
	for _, child in ipairs(children) do
		attempt(function(): () child:Destroy() end)
	end
	attempt(function(): () resources:Collect(owner) end)
	rawset(owner, "_props", nil)
	rawset(owner, "Destroyed", true)
	for _, name in ipairs(SIGNALS) do
		local event: Signal? = rawget(owner, name)
		if event then attempt(function(): () event:Destroy() end) end
	end
	for _, name in ipairs({ "_propertySignals", "_attributeSignals" }) do
		local events: { [string]: Signal }? = rawget(owner, name)
		if events then
			for _, event in pairs(events) do
				attempt(function(): () event:Destroy() end)
			end
			rawset(owner, name, nil)
		end
	end
	rawset(owner, "_destroying", nil)
	if #failures > 0 then error("Instance destruction failed: " .. table.concat(failures, "; "), 2) end
end

return table.freeze({ Destroy = destroy })
