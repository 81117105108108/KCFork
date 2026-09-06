-- description: "Enables asynchronous communication between the client and server."
local signal = require("@Kinemium.signal")
local RemoteBridge = require("@RemoteBridge")
local Enum = require("@EnumMap")

return {
	class = "RemoteEvent",
	callback = function(instance, renderer, datamodel)
		local OnClientEvent = signal.new()
		local OnServerEvent = signal.new()

		instance:SetProperties({
			OnClientEvent = OnClientEvent,
			OnServerEvent = OnServerEvent,
			Reliability = Enum.NetworkReliability.ReliableOrdered,
		})
		RemoteBridge.BindEvent(instance, datamodel, Enum.NetworkReliability.ReliableOrdered)

		return instance
	end,
}
