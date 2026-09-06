local Delivery = {
	ChannelCount = 18,
}

local reliableUnorderedChannel = 1

function Delivery.Resolve(delivery)
	if delivery == true or delivery == nil then
		return 0, 1
	elseif delivery == false then
		-- Preserve the legacy sequenced-unreliable lane for engine packets.
		return 1, 0
	end

	local name = type(delivery) == "table" and delivery.Name or tostring(delivery)
	if name == "ReliableUnordered" then
		-- ENet orders reliable packets within one channel. Strip global ordering by
		-- rotating across independent reliable lanes while retaining retransmission.
		reliableUnorderedChannel = (reliableUnorderedChannel - 1) % 14 + 2
		return reliableUnorderedChannel, 1
	elseif name == "Unreliable" then
		return 16, 2
	elseif name == "UnreliableSequenced" then
		return 17, 0
	end
	return 0, 1
end

return Delivery
