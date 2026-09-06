local Protocol = require("./Protocol")
local ReplicationWorld = require("./ReplicationWorld")
local ReplicationSchema = require("./ReplicationSchema")
local CharacterReplicator = require("./CharacterReplicator")
local CollaboratorCameraGizmos = require("./CollaboratorCameraGizmos")
local Enum = require("@EnumMap")
local Vector3 = require("@Vector3")

local ServerReplicator = {}
ServerReplicator.__index = ServerReplicator

local function playerIdFor(name)
	local hash = 2166136261
	for index = 1, #name do
		hash = bit32.bxor(hash, string.byte(name, index))
		hash = (hash * 16777619) % 2147483647
	end
	return math.max(1, math.floor(hash))
end

function ServerReplicator.new(transport, datamodel, renderer, options)
	local self = setmetatable({}, ServerReplicator)
	self.transport, self.datamodel, self.renderer = transport, datamodel, renderer
	self.world = ReplicationWorld.new("server", datamodel, renderer, options)
	self.character = CharacterReplicator.new({
		role = "server",
		tick = function()
			return self.world.tick
		end,
	})
	self.connections, self.events, self.packetRates = {}, {}, {}
	self.options = options or {}
	self.studioCameras = {}
	-- Ensure camera gizmos are available when a renderer is present (unless headless).
	self.cameraGizmos = nil
	if renderer and not _G.IsHeadless then
		self.cameraGizmos = CollaboratorCameraGizmos.new(renderer)
	end
	self.running = false
	self.characterStatesAccepted = 0
	self.characterStatesRejected = 0
	return self
end

local function characterRootForPeer(peer)
	local character = peer.player and peer.player.Character
	return character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")) or nil
end

function ServerReplicator:ValidateCharacterState(peer, instance, cframe, velocity)
	local root = characterRootForPeer(peer)
	if instance ~= root then
		return true
	end
	local now = os.clock()
	local authority = peer.characterAuthority
	if not authority then
		authority = { position = root.CFrame.Position, acceptedAt = now }
		peer.characterAuthority = authority
	end

	local controller = root.Parent and root.Parent:FindFirstChildOfClass("CharacterController")
	local walkSpeed = math.max(tonumber(controller and controller.WalkSpeed) or 16, 0)
	local sprintMultiplier = math.max(tonumber(controller and controller.SprintMultiplier) or 1.5, 1)
	local horizontalLimit = walkSpeed * sprintMultiplier * 1.35 + 4
	local jumpPower = math.max(tonumber(controller and controller.JumpPower) or 50, 0)
	local upwardLimit = jumpPower * 1.6 + 10
	local downwardLimit = math.max(tonumber(controller and controller.TerminalVelocity) or 500, upwardLimit)

	local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	if horizontalSpeed > horizontalLimit or velocity.Y > upwardLimit or velocity.Y < -downwardLimit then
		return false, "character velocity exceeded movement limits"
	end

	local elapsed = math.clamp(now - authority.acceptedAt, 1 / 120, 2)
	local delta = cframe.Position - authority.position
	local horizontalDistance = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	local verticalLimit = if delta.Y >= 0 then upwardLimit else downwardLimit
	local horizontalAllowance = math.min((authority.horizontalCredit or 3) + horizontalLimit * elapsed, 3)
	local verticalCreditCap = if delta.Y >= 0 then 4 else 20
	local verticalAllowance = math.min(
		(authority.verticalCredit or verticalCreditCap) + verticalLimit * elapsed,
		verticalCreditCap
	)
	if horizontalDistance > horizontalAllowance or math.abs(delta.Y) > verticalAllowance then
		return false, "character displacement exceeded movement limits"
	end

	authority.position = cframe.Position
	authority.acceptedAt = now
	authority.horizontalCredit = horizontalAllowance - horizontalDistance
	authority.verticalCredit = verticalAllowance - math.abs(delta.Y)
	authority.acceptedFrom = cframe.Position - delta
	authority.acceptedDelta = delta
	authority.acceptedVelocity = velocity
	return true
end

function ServerReplicator:ApplyCharacterInteraction(peer, velocity)
	local authority = peer.characterAuthority
	local character = peer.player and peer.player.Character
	local workspace = self.datamodel:GetService("Workspace")
	local delta = authority and authority.acceptedDelta
	if not character or not workspace or not workspace.Raycast or not delta then
		return false
	end
	local horizontal = Vector3.new(delta.X, 0, delta.Z)
	if horizontal:Magnitude() <= 0.0001 then
		return false
	end
	local direction = horizontal:Unit()
	local distance = horizontal:Magnitude() + 1.25
	local params = {
		FilterDescendantsInstances = { character },
		RespectCanCollide = true,
		CollisionGroup = "Default",
	}
	local hit = nil
	for _, height in ipairs({ -1.8, 0, 1.65 }) do
		local candidate = workspace:Raycast(
			authority.acceptedFrom + Vector3.new(0, height, 0),
			direction * distance,
			params
		)
		if candidate and (not hit or (tonumber(candidate.Distance) or math.huge) < (tonumber(hit.Distance) or math.huge)) then
			hit = candidate
		end
	end
	local part = hit and hit.Instance
	if not part or part.Anchored ~= false or type(part.ApplyImpulse) ~= "function" then
		return false
	end

	peer.characterPushTimes = peer.characterPushTimes or setmetatable({}, { __mode = "k" })
	local now = os.clock()
	if now - (peer.characterPushTimes[part] or -math.huge) < 0.12 then
		return false
	end
	local speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	local impulseMagnitude = math.clamp(speed * 80 * 0.05, 20, 180)
	local impulse = direction * impulseMagnitude + Vector3.new(0, impulseMagnitude * 0.08, 0)
	local ok, applied = pcall(part.ApplyImpulse, part, impulse)
	if ok and applied ~= false then
		peer.characterPushTimes[part] = now
		return true
	end
	return false
end

function ServerReplicator:BroadcastStudioPresence()
	local collaborators = {}
	for _, peer in pairs(self.world.peers) do
		if peer.isStudio then
			table.insert(collaborators, {
				Id = "peer:" .. peer.key,
				Name = peer.player and peer.player.Name or peer.key,
				UserId = peer.player and peer.player.UserId or 0,
			})
		end
	end
	for _, peer in pairs(self.world.peers) do
		if peer.isStudio then
			peer.send(Protocol.Kinds.StudioPresence, { collaborators = collaborators }, true)
		end
	end
end

function ServerReplicator:SendKnownStudioCameras(peer)
	if not peer or not peer.isStudio then
		return
	end
	for id, camera in pairs(self.studioCameras) do
		if id ~= "peer:" .. peer.key then
			peer.send(Protocol.Kinds.StudioCamera, {
				id = id,
				name = camera.name,
				cframe = camera.cframe,
			}, true)
		end
	end
end

function ServerReplicator:ApplyStudioEdit(peer, payload)
	local requestId = tonumber(payload.requestId) or 0
	local function finish(ok, reason, instance)
		peer.send(Protocol.Kinds.StudioEditResult, {
			requestId = requestId,
			ok = ok,
			reason = reason,
			id = instance and self.world:GetId(instance) or nil,
		})
		return ok
	end

	if not peer.isStudio or self.options.readOnlyStudio then
		return finish(false, "studio edit permission denied")
	end
	if type(payload.op) ~= "string" then
		return finish(false, "invalid edit operation")
	end

	if payload.op == "set" then
		local instance = self.world:GetInstance(payload.id)
		local property = payload.property
		if not instance or type(property) ~= "string" or #property > 64 then
			return finish(false, "invalid edit target")
		end
		if not ReplicationSchema.IsReplicated(instance, property) then
			return finish(false, "property is not collaboration-safe")
		end
		if not ReplicationSchema.IsSafeValue(payload.value) then
			return finish(false, "invalid property value")
		end
		local decoded, value = pcall(ReplicationSchema.DecodeValue, payload.value, self.world, Enum)
		if not decoded or value == nil then
			return finish(false, "property value could not be decoded")
		end
		local assigned = pcall(function()
			instance[property] = value
		end)
		return finish(assigned, assigned and nil or "property assignment failed", instance)
	elseif payload.op == "create" then
		local parent = self.world:GetInstance(payload.parent)
		local className = payload.class
		if not parent or type(className) ~= "string" or #className > 64 then
			return finish(false, "invalid class or parent")
		end
		local Registry = require("@InstanceRegistry")
		if not Registry.ClassValid(className) then
			return finish(false, "class is unavailable")
		end
		local created, instance = pcall(Registry.new, className, self.renderer, self.datamodel, true)
		if not created or not instance then
			return finish(false, "class creation failed")
		end
		if type(payload.state) == "table" and ReplicationSchema.IsSafeValue(payload.state) then
			ReplicationSchema.Apply(instance, payload.state, self.world, Enum)
		end
		instance.Parent = parent
		return finish(true, nil, instance)
	elseif payload.op == "delete" then
		local instance = self.world:GetInstance(payload.id)
		if not instance or instance.Parent == self.datamodel then
			return finish(false, "cannot delete collaboration root")
		end
		instance:Destroy()
		return finish(true)
	elseif payload.op == "reparent" then
		local instance = self.world:GetInstance(payload.id)
		local parent = self.world:GetInstance(payload.parent)
		if not instance or not parent or instance.Parent == self.datamodel or parent:IsDescendantOf(instance) then
			return finish(false, "invalid hierarchy edit")
		end
		instance.Parent = parent
		return finish(true, nil, instance)
	end
	return finish(false, "unsupported edit operation")
end

function ServerReplicator:Send(client, kind, payload, reliableOverride)
	local reliable = reliableOverride
	if reliable == nil then
		reliable = Protocol.IsReliable(kind)
	end
	return self.transport:Send(client, Protocol.Packet(kind, payload), reliable)
end

function ServerReplicator:Broadcast(kind, payload)
	return self.transport:SendAll(Protocol.Packet(kind, payload), Protocol.IsReliable(kind))
end

function ServerReplicator:RegisterEntity(instance)
	local id = self.world:Register(instance)
	if not id then
		return nil
	end
	local spawn = self.world:BuildSpawn(instance)
	for _, peer in pairs(self.world.peers) do
		local parent = instance.Parent
		local parentId = parent == self.datamodel and 0 or self.world:GetId(parent)
		if not peer.known[id]
			and self.world:IsVisibleToPeer(instance, peer)
			and (parentId == 0 or peer.known[parentId])
		then
			peer.known[id] = true
			peer.send(Protocol.Kinds.Spawn, spawn)
		end
	end
	return id
end

function ServerReplicator:UnregisterEntity(instance)
	local id = self.world:GetId(instance)
	if not id then
		return false
	end
	for _, peer in pairs(self.world.peers) do
		if peer.known[id] then
			peer.send(Protocol.Kinds.Despawn, { id = id })
			peer.known[id] = nil
		end
	end
	return self.world:Unregister(instance) ~= nil
end

function ServerReplicator:RegisterWorld()
	-- Pre-existing descendants need stable IDs before the first full snapshot.
	-- This includes Workspace: otherwise edits to an existing baseplate cannot be
	-- addressed by a collaboration client.
	for _, serviceName in ipairs({ "Workspace", "ReplicatedStorage", "Players" }) do
		local service = self.datamodel:GetService(serviceName)
		if service then
			self.world:Register(service)
			for _, instance in ipairs(service:GetDescendants()) do
				self.world:Register(instance)
			end
		end
	end
	table.insert(
		self.connections,
		self.datamodel.DescendantChanged:Connect(function(instance, property)
			self.world:MarkDirty(instance, property)
		end)
	)
	table.insert(
		self.connections,
		self.datamodel.DescendantAdded:Connect(function(instance)
			local added = { instance }
			for _, descendant in ipairs(instance:GetDescendants()) do
				table.insert(added, descendant)
			end
			table.sort(added, function(a, b)
				return a:GetDepth() < b:GetDepth()
			end)
			for _, addedInstance in ipairs(added) do
				if not self.world:GetId(addedInstance) then
					local id = self.world:Register(addedInstance)
					if id then
						local spawn = self.world:BuildSpawn(addedInstance)
						for _, peer in pairs(self.world.peers) do
							local parent = addedInstance.Parent
							local parentId = parent == self.datamodel and 0 or self.world:GetId(parent)
							if self.world:IsVisibleToPeer(addedInstance, peer)
								and (parentId == 0 or peer.known[parentId])
							then
								peer.known[id] = true
								peer.send(Protocol.Kinds.Spawn, spawn)
							end
						end
					end
				end
			end
		end)
	)
	table.insert(
		self.connections,
		self.datamodel.DescendantRemoving:Connect(function(instance)
			local removing = { instance }
			for _, descendant in ipairs(instance:GetDescendants()) do
				table.insert(removing, descendant)
			end
			for index = #removing, 1, -1 do
				local target = removing[index]
				local id = self.world:GetId(target)
				if id then
					for _, peer in pairs(self.world.peers) do
						if peer.known[id] then
							peer.send(Protocol.Kinds.Despawn, { id = id })
							peer.known[id] = nil
						end
					end
					self.world:Unregister(target)
				end
			end
		end)
	)
end

function ServerReplicator:ValidateConnection(arguments)
	if type(arguments) ~= "table" or type(arguments.name) ~= "string" then
		return false, "invalid handshake"
	end
	if #arguments.name < 1 or #arguments.name > 32 or not arguments.name:match("^[%w_%-]+$") then
		return false, "invalid player name"
	end
	if ENGINE_VERSION and arguments.engine_version ~= ENGINE_VERSION then
		return false, "engine version mismatch"
	end
	if arguments.protocol_version ~= Protocol.Version then
		return false, "replication protocol mismatch"
	end
	if arguments.mods ~= nil and type(arguments.mods) ~= "table" then
		return false, "invalid mod manifest"
	end
	if self.options.studioToken then
		if arguments.studio ~= true or arguments.studioToken ~= self.options.studioToken then
			return false, "invalid or expired studio invitation"
		end
	end
	if self.world.peers[arguments.name] then
		return false, "player already connected"
	end
	local players = self.datamodel:GetService("Players")
	if players and #players.Players >= players.MaxPlayers then
		return false, "server is full"
	end
	return true
end

function ServerReplicator:OnConnect(client, arguments)
	local valid, reason = self:ValidateConnection(arguments)
	if not valid then
		self:Send(client, Protocol.Kinds.HandshakeRejected, { reason = reason })
		self.transport:DisconnectClient(client, reason)
		return
	end
	-- A client starts its input sequence from zero for every connection. Clear
	-- any state left under this reusable username before accepting the session.
	self.character:RemovePeer(arguments.name)
	self.packetRates[arguments.name] = nil
	local players = self.datamodel:GetService("Players")
	local player = players:AddPlayer(arguments.name, playerIdFor(arguments.name), self.datamodel, {
		noCharacter = arguments.studio == true,
	})
	if not player then
		self:Send(client, Protocol.Kinds.HandshakeRejected, { reason = "could not create player" })
		self.transport:DisconnectClient(client, "could not create player")
		return
	end
	local peer = self.world:AddPeer(arguments.name, player, function(kind, payload, reliableOverride)
		return self:Send(client, kind, payload, reliableOverride)
	end)
	peer.isStudio = arguments.studio == true and self.options.studioToken ~= nil
	peer.client = client
	local root = player.Character
		and (player.Character.PrimaryPart or player.Character:FindFirstChild("HumanoidRootPart"))
	local controller = player.Character and player.Character:FindFirstChildOfClass("CharacterController")
	if controller then
		controller.Enabled = false
		local motor = controller:GetMotor()
		if motor then
			motor.Enabled = false
		end
	end
	if root then
		peer.characterAuthority = { position = root.CFrame.Position, acceptedAt = os.clock() }
		self:AssignOwnership(root, player)
	end
	self:Send(client, Protocol.Kinds.HandshakeAccepted, {
		playerId = player.UserId,
		playerName = player.Name,
		characterId = root and self.world:GetId(root) or nil,
		serverTick = self.world.tick,
		snapshotRate = self.world.config.snapshotRate,
	})
	local snapshot = self.world:BuildFullSnapshot(peer)
	self:Send(client, Protocol.Kinds.FullSnapshot, snapshot)
	print(
		`[Replication][Server] Accepted {player.Name}; sent {#snapshot.spawns} entities at tick {snapshot.serverTick}`
	)
	if peer.isStudio then
		self:BroadcastStudioPresence()
		self:SendKnownStudioCameras(peer)
	end
end

function ServerReplicator:RateAllowed(peerKey)
	local now = os.clock()
	local rate = self.packetRates[peerKey]
	if not rate or now - rate.started >= 1 then
		rate = { started = now, count = 0 }
		self.packetRates[peerKey] = rate
	end
	rate.count += 1
	return rate.count <= 180
end

function ServerReplicator:OnMessage(client, packet)
	local valid = Protocol.Validate(packet)
	if not valid then
		self.world.stats.malformedPackets += 1
		return
	end
	local peer
	for _, candidate in pairs(self.world.peers) do
		if candidate.client == client then
			peer = candidate
			break
		end
	end
	if not peer or not self:RateAllowed(peer.key) then
		return
	end
	local kind, payload = packet.kind, packet.payload
	if kind == Protocol.Kinds.SnapshotAck then
		if not self.world:Acknowledge(peer, payload.serverTick) then
			-- An unreliable acknowledgement can arrive after its snapshot version
			-- has fallen out of the bounded history. It is stale, not evidence that
			-- the client's scene is corrupt. A future ACK can still advance the
			-- baseline; forcing a full snapshot here creates a resnapshot storm.
			self.world.stats.staleSnapshotAcks += 1
		end
	elseif kind == Protocol.Kinds.ResyncRequest then
		self.world.stats.resyncs += 1
		peer.send(Protocol.Kinds.FullSnapshot, self.world:BuildFullSnapshot(peer))
	elseif kind == Protocol.Kinds.InputCommand then
		local character = peer.player and peer.player.Character
		local controller = character and character:FindFirstChildOfClass("CharacterController")
		if controller then
			local accepted = self.character:ProcessServerInput(peer.key, payload, controller)
			if not accepted then
				self.world.stats.malformedPackets += 1
			end
		end
	elseif kind == Protocol.Kinds.OwnedPhysicsState then
		local instance = type(payload) == "table" and self.world:GetInstance(payload.id) or nil
		local isCharacter = instance ~= nil and instance == characterRootForPeer(peer)
		local accepted = self.world:ApplyOwnedPhysics(peer, payload, isCharacter and function(target, cframe, velocity)
			return self:ValidateCharacterState(peer, target, cframe, velocity)
		end or nil)
		if isCharacter then
			if accepted then
				self.characterStatesAccepted += 1
				local velocity = peer.characterAuthority and peer.characterAuthority.acceptedVelocity
				if velocity then
					self:ApplyCharacterInteraction(peer, velocity)
				end
			else
				self.characterStatesRejected += 1
			end
		end
	elseif kind == Protocol.Kinds.Ping then
		peer.send(
			Protocol.Kinds.Pong,
			{ nonce = payload.nonce, clientTime = payload.clientTime, serverTime = os.clock() }
		)
	elseif kind == Protocol.Kinds.StudioEdit and type(payload) == "table" then
		self:ApplyStudioEdit(peer, payload)
	elseif kind == Protocol.Kinds.StudioCamera and peer.isStudio and ReplicationSchema.IsSafeValue(payload.cframe) then
		local decoded, cframe = pcall(ReplicationSchema.DecodeValue, payload.cframe, self.world, Enum)
		if decoded and typeof(cframe) == "CFrame" then
			local id = "peer:" .. peer.key
			self.studioCameras[id] = {
				name = peer.player and peer.player.Name or peer.key,
				cframe = payload.cframe,
			}
			if self.cameraGizmos then
				self.cameraGizmos:Update(id, peer.player and peer.player.Name or peer.key, cframe)
			end
			for _, other in pairs(self.world.peers) do
				if other ~= peer and other.isStudio then
					other.send(Protocol.Kinds.StudioCamera, {
						id = id,
						name = peer.player and peer.player.Name or peer.key,
						cframe = payload.cframe,
					}, false)
				end
			end
		end
	elseif
		kind == Protocol.Kinds.Event
		and type(payload.name) == "string"
		and #payload.name <= 64
		and ReplicationSchema.IsSafeValue(payload.data)
	then
		local callbacks = self.events[payload.name]
		if callbacks then
			for _, callback in ipairs(callbacks) do
				task.spawn(callback, peer.player, payload.data)
			end
		end
	end
end

function ServerReplicator:Step()
	self.world:AdvanceTick()
	for _, peer in pairs(self.world.peers) do
		local spawns, despawns = self.world:ReconcilePeerVisibility(peer)
		for _, item in ipairs(despawns) do
			peer.send(Protocol.Kinds.Despawn, { id = item.id })
		end
		for _, spawn in ipairs(spawns) do
			peer.send(Protocol.Kinds.Spawn, spawn)
		end
		local snapshot, reason = self.world:BuildSnapshot(peer)
		if snapshot then
			snapshot.lastProcessedInputSequence = self.character:GetLastProcessed(peer.key)
			peer.send(Protocol.Kinds.Snapshot, snapshot)
		elseif reason == "baseline unavailable" then
			peer.send(Protocol.Kinds.FullSnapshot, self.world:BuildFullSnapshot(peer))
		end
	end
end

function ServerReplicator:Start(address, port)
	if self.running then
		return self
	end
	self.running = true
	if self.transport.Host then
		self.transport:Shutdown()
	end
	self.transport:Init(address, tonumber(port) or 1234)
	self:RegisterWorld()
	self.transport:OnClientConnectionRequest(function(client, args)
		self:OnConnect(client, args)
	end)
	self.transport:OnClientRemoved(function(client)
		local key
		for name, peer in pairs(self.world.peers) do
			if peer.client == client then
				key = name
				break
			end
		end
		if key then
			self.character:RemovePeer(key)
			self.packetRates[key] = nil
			local peer = self.world:RemovePeer(key)
			if peer and peer.player then
				self.datamodel:GetService("Players"):RemovePlayer(peer.player)
			end
			self:BroadcastStudioPresence()
			self.studioCameras["peer:" .. key] = nil
			if self.cameraGizmos then
				self.cameraGizmos:Remove("peer:" .. key)
			end
		end
	end)
	self.transport:OnRecieve(function(client, packet)
		self:OnMessage(client, packet)
	end)
	task.spawn(function()
		local interval = 1 / self.world.config.snapshotRate
		while self.running do
			task.wait(interval)
			self:Step()
		end
	end)
	task.spawn(function()
		local lastCamera
		local lastCameraSentAt = -math.huge
		while self.running do
			task.wait(0.1)
			local workspace = self.datamodel:GetService("Workspace")
			local camera = workspace and (workspace.CurrentCamera or workspace:FindFirstChildOfClass("Camera"))
			local cframe = camera and camera.CFrame
			local now = os.clock()
			if cframe and (not lastCamera or not cframe:IsSameTransform(lastCamera, 1e-3) or now - lastCameraSentAt >= 1) then
				local encoded = ReplicationSchema.EncodeValue(cframe, self.world)
				self.studioCameras.host = {
					name = self.options.studioHostName or "Host",
					cframe = encoded,
				}
				for _, peer in pairs(self.world.peers) do
					if peer.isStudio then
						peer.send(Protocol.Kinds.StudioCamera, {
							id = "host",
							name = self.options.studioHostName or "Host",
							cframe = encoded,
						}, false)
					end
				end
				lastCamera = cframe
				lastCameraSentAt = now
			end
		end
	end)
	return self
end

function ServerReplicator:OnEvent(name, callback)
	self.events[name] = self.events[name] or {}
	table.insert(self.events[name], callback)
end

function ServerReplicator:SendEvent(name, data, reliable)
	return self.transport:SendAll(
		Protocol.Packet(Protocol.Kinds.Event, { name = name, data = data }),
		if reliable == nil then true else reliable
	)
end

function ServerReplicator:SendEventTo(player, name, data, reliable)
	if not player then
		return false
	end
	for _, peer in pairs(self.world.peers) do
		if peer.player == player or (peer.player and player.UserId ~= nil and peer.player.UserId == player.UserId) then
			return peer.send(
				Protocol.Kinds.Event,
				{ name = name, data = data },
				if reliable == nil then true else reliable
			)
		end
	end
	return false
end

function ServerReplicator:AssignOwnership(instance, player)
	local record = self.world:AssignOwnership(instance, player and player.UserId or nil, player)
	if record then
		local id = self.world:GetId(instance)
		for _, peer in pairs(self.world.peers) do
			if peer.known[id] then
				peer.send(Protocol.Kinds.OwnershipChanged, { id = id, record = record })
			end
		end
	end
	return record
end

function ServerReplicator:AddPlayerToGroup(player, groupName)
	return self.world:AddPlayerToGroup(player, groupName)
end

function ServerReplicator:RemovePlayerFromGroup(player, groupName)
	return self.world:RemovePlayerFromGroup(player, groupName)
end

function ServerReplicator:IsPlayerInGroup(player, groupName)
	return self.world:IsPlayerInGroup(player, groupName)
end

function ServerReplicator:ReplicateTo(instance, player)
	return self.world:SetManualRecipient(instance, player, true)
end

function ServerReplicator:StopReplicatingTo(instance, player)
	return self.world:SetManualRecipient(instance, player, false)
end

function ServerReplicator:GetStats()
	local stats = self.world:GetStats()
	for key, value in pairs(self.character:GetStats()) do
		stats[key] = value
	end
	stats.characterStatesAccepted = self.characterStatesAccepted
	stats.characterStatesRejected = self.characterStatesRejected
	if self.transport.GetStats then
		for key, value in pairs(self.transport:GetStats()) do
			stats[key] = value
		end
	end
	return stats
end

function ServerReplicator:Stop()
	self.running = false
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)
	if self.cameraGizmos then
		self.cameraGizmos:Destroy()
		self.cameraGizmos = nil
	end
	self.transport:Shutdown()
end

return ServerReplicator
