-- description: "A remote event that sends data without guaranteeing delivery."
local signal = require("@Kinemium.signal")
local RemoteBridge = require("@RemoteBridge")
local Enum = require("@EnumMap")

return {
	class = "UnreliableRemoteEvent",
	callback = function(instance, properties, datamodel)
		local clientEvent = signal.new()
		local serverEvent = signal.new()

		instance:SetProperties({
			OnClientEvent = clientEvent,
			OnServerEvent = serverEvent,
			Reliability = Enum.NetworkReliability.Unreliable,
		})
		RemoteBridge.BindEvent(instance, datamodel, Enum.NetworkReliability.Unreliable)

		return instance
	end,
}
