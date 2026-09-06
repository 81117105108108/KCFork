local Instance = require("@Instance")
local Enum = require("@EnumMap")
local Vector2 = require("@Vector2")
local native = require("@kinebox2d")

local Service = Instance.new("Box2DService")
Service.ExplorerHidden = true
Service._Intents = Enum.PluginIntents.Physics

local worlds = {}
local null = zune.ffi.null
local rebuildConstraint

local function isBody2D(object)
	return object ~= nil and (object.ClassName == "Body2D" or object.BaseClass == "Body2D")
end

local function isConstraint2D(object)
	return object ~= nil and object.BaseClass == "Constraint2D"
end

local function disconnectAll(connections)
	for _, connection in pairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function dropConstraintHandle(world, object, record)
	if record.handle and record.handle ~= null then
		native.Kine_Box2D_DestroyJoint(record.handle)
	end
	record.handle = nil
	world.object.Constraints[object] = nil
	object.JointID = nil
	object.Active = false
end

local function rebuildAllConstraints(world)
	for object in pairs(world.constraintRecords) do
		rebuildConstraint(world, object)
	end
end

local function destroyBody(world, object)
	local record = world.bodies[object]
	if not record then
		return
	end
	for constraint, constraintRecord in pairs(world.constraintRecords) do
		constraintRecord.rebuilding = true
		dropConstraintHandle(world, constraint, constraintRecord)
		constraintRecord.rebuilding = false
	end
	disconnectAll(record.connections)
	if record.handle and record.handle ~= null then
		native.Kine_Box2D_DestroyBody(record.handle)
	end
	world.bodies[object] = nil
	world.object.Bodies[object] = nil
	object.BodyID = nil
	rebuildAllConstraints(world)
end

local function createBody(world, object)
	if not isBody2D(object) or object.Parent ~= world.object or world.bodies[object] then
		return false
	end
	local size = object.Size or Vector2.new(32, 32)
	local position = object.Position or Vector2.new(0, 0)
	local handle = native.Kine_Box2D_CreateBoxBody(
		world.handle,
		position.X,
		position.Y,
		size.X,
		size.Y,
		math.rad(object.Rotation or 0),
		object.Anchored == false and 1 or 0,
		object.Density or 1,
		object.Friction or 0.3,
		object.Restitution or 0,
		object.IsSensor and 1 or 0
	)
	if not handle or handle == null then
		return false
	end
	local velocity = object.LinearVelocity or Vector2.new(0, 0)
	native.Kine_Box2D_SetBodyVelocity(handle, velocity.X, velocity.Y, math.rad(object.AngularVelocity or 0))

	local record = { handle = handle, connections = {}, writing = false }
	world.bodies[object] = record
	world.object.Bodies[object] = true
	object.BodyID = handle
	record.connections.changed = object.Changed:Connect(function(property)
		if record.writing then
			return
		end
		if property == "Anchored" then
			native.Kine_Box2D_SetBodyType(handle, object.Anchored == false and 1 or 0)
		elseif property == "Position" or property == "Rotation" then
			native.Kine_Box2D_SetBodyTransform(
				handle,
				object.Position.X,
				object.Position.Y,
				math.rad(object.Rotation or 0)
			)
		elseif property == "LinearVelocity" or property == "AngularVelocity" then
			local nextVelocity = object.LinearVelocity or Vector2.new(0, 0)
			native.Kine_Box2D_SetBodyVelocity(
				handle,
				nextVelocity.X,
				nextVelocity.Y,
				math.rad(object.AngularVelocity or 0)
			)
		elseif
			property == "Size"
			or property == "Density"
			or property == "Friction"
			or property == "Restitution"
			or property == "IsSensor"
		then
			destroyBody(world, object)
			createBody(world, object)
		end
	end)
	record.connections.destroying = object.Destroying:Connect(function()
		destroyBody(world, object)
	end)
	rebuildAllConstraints(world)
	return true
end

local function attachmentBody(attachment)
	if attachment and attachment.ClassName == "Attachment2D" and isBody2D(attachment.Parent) then
		return attachment.Parent
	end
	return nil
end

local function attachmentFrame(attachment)
	if not attachment then
		return 0, 0, 0
	end
	return attachment.Position.X, attachment.Position.Y, math.rad(attachment.Rotation or 0)
end

local function bindConstraintReference(world, object, record, attachment)
	if not attachment then
		return
	end
	table.insert(
		record.referenceConnections,
		attachment.Changed:Connect(function(property)
			if property == "Position" or property == "Rotation" or property == "Parent" then
				rebuildConstraint(world, object)
			end
		end)
	)
end

rebuildConstraint = function(world, object)
	local record = world.constraintRecords[object]
	if not record or record.rebuilding then
		return false
	end
	record.rebuilding = true
	dropConstraintHandle(world, object, record)
	disconnectAll(record.referenceConnections)

	if object.Parent ~= world.object or object.Enabled == false then
		record.rebuilding = false
		return false
	end

	local className = object.ClassName
	local attachment0 = object.Attachment0
	local attachment1 = object.Attachment1
	bindConstraintReference(world, object, record, attachment0)
	bindConstraintReference(world, object, record, attachment1)

	local body0
	local body1
	if className == "WeldConstraint2D" then
		body0 = attachmentBody(attachment0) or object.Body0
		body1 = attachmentBody(attachment1) or object.Body1
	else
		body0 = attachmentBody(attachment0)
		body1 = attachmentBody(attachment1)
	end
	local bodyRecord0 = body0 and world.bodies[body0]
	local bodyRecord1 = body1 and world.bodies[body1]
	if not bodyRecord0 or not bodyRecord1 or body0 == body1 then
		record.rebuilding = false
		return false
	end

	local ax, ay, ar = attachmentFrame(attachment0)
	local bx, by, br = attachmentFrame(attachment1)
	local handle
	if className == "HingeConstraint2D" then
		handle = native.Kine_Box2D_CreateHingeJoint(
			world.handle,
			bodyRecord0.handle,
			bodyRecord1.handle,
			ax,
			ay,
			ar,
			bx,
			by,
			br,
			object.LimitsEnabled and 1 or 0,
			math.rad(object.LowerAngle or -180),
			math.rad(object.UpperAngle or 180),
			object.MotorEnabled and 1 or 0,
			math.rad(object.AngularVelocity or 0),
			object.MaxTorque or 1000,
			object.CollideConnected and 1 or 0
		)
	elseif className == "RopeConstraint2D" then
		local maxLength = math.max(object.Length or 100, 0.01)
		handle = native.Kine_Box2D_CreateDistanceJoint(
			world.handle,
			bodyRecord0.handle,
			bodyRecord1.handle,
			ax,
			ay,
			bx,
			by,
			maxLength,
			1,
			0,
			0,
			1,
			math.max(object.MinLength or 0, 0.01),
			maxLength,
			object.CollideConnected and 1 or 0
		)
	elseif className == "SpringConstraint2D" then
		local stiffness = math.max(object.Stiffness or 0, 0)
		local hertz = object.Frequency and object.Frequency > 0 and object.Frequency
			or math.sqrt(stiffness) / (2 * math.pi)
		local dampingRatio = object.DampingRatio and object.DampingRatio > 0 and object.DampingRatio
			or (stiffness > 0 and (object.Damping or 0) / (2 * math.sqrt(stiffness)) or 1)
		handle = native.Kine_Box2D_CreateDistanceJoint(
			world.handle,
			bodyRecord0.handle,
			bodyRecord1.handle,
			ax,
			ay,
			bx,
			by,
			math.max(object.FreeLength or 100, 0.01),
			1,
			hertz,
			dampingRatio,
			0,
			0.01,
			math.max(object.FreeLength or 100, 0.01),
			object.CollideConnected and 1 or 0
		)
	elseif className == "WeldConstraint2D" then
		handle = native.Kine_Box2D_CreateWeldJoint(
			world.handle,
			bodyRecord0.handle,
			bodyRecord1.handle,
			ax,
			ay,
			ar,
			bx,
			by,
			br,
			object.LinearFrequency or 0,
			object.AngularFrequency or 0,
			object.LinearDampingRatio or 1,
			object.AngularDampingRatio or 1,
			(attachment0 and attachment1) and 0 or 1,
			object.CollideConnected and 1 or 0
		)
	end

	if handle and handle ~= null then
		record.handle = handle
		world.object.Constraints[object] = true
		object.JointID = handle
		object.Active = true
	end
	record.rebuilding = false
	return record.handle ~= nil
end

local function destroyConstraint(world, object)
	local record = world.constraintRecords[object]
	if not record then
		return
	end
	record.rebuilding = true
	dropConstraintHandle(world, object, record)
	disconnectAll(record.referenceConnections)
	disconnectAll(record.connections)
	world.constraintRecords[object] = nil
end

local function watchConstraint(world, object)
	if not isConstraint2D(object) or object.Parent ~= world.object or world.constraintRecords[object] then
		return false
	end
	local record = { handle = nil, rebuilding = false, connections = {}, referenceConnections = {} }
	world.constraintRecords[object] = record
	record.connections.changed = object.Changed:Connect(function(property)
		if not record.rebuilding and property ~= "Active" and property ~= "JointID" then
			rebuildConstraint(world, object)
		end
	end)
	record.connections.destroying = object.Destroying:Connect(function()
		destroyConstraint(world, object)
	end)
	return rebuildConstraint(world, object)
end

local function syncBodies(world)
	for object, record in pairs(world.bodies) do
		if object.Parent ~= world.object then
			destroyBody(world, object)
		elseif object.Anchored == false then
			local x, y, angle = zune.ffi.alloc(4), zune.ffi.alloc(4), zune.ffi.alloc(4)
			native.Kine_Box2D_GetBodyTransform(record.handle, x, y, angle)
			record.writing = true
			world.bodyUpdate(object, Vector2.new(x:readf32(0), y:readf32(0)))
			object.Rotation = math.deg(angle:readf32(0))
			record.writing = false
			zune.ffi.free(x)
			zune.ffi.free(y)
			zune.ffi.free(angle)
		end
	end
end

local function destroyWorld(world)
	local constraints = {}
	for object in pairs(world.constraintRecords) do
		table.insert(constraints, object)
	end
	for _, object in ipairs(constraints) do
		destroyConstraint(world, object)
	end
	local bodies = {}
	for object in pairs(world.bodies) do
		table.insert(bodies, object)
	end
	for _, object in ipairs(bodies) do
		destroyBody(world, object)
	end
	disconnectAll(world.connections)
	if world.handle and world.handle ~= null then
		native.Kine_Box2D_DestroyWorld(world.handle)
	end
	worlds[world.object] = nil
end

Service.InitRenderer = function(_, signal, game)
	Service:SetProperties({
		init = function(object, bodyUpdate)
			if worlds[object] then
				destroyWorld(worlds[object])
			end
			local gravity = object.Gravity or Vector2.new(0, 981)
			local handle = native.Kine_Box2D_CreateWorld(gravity.X, gravity.Y)
			assert(handle and handle ~= null, "Failed to create Box2D world")
			local world = {
				object = object,
				handle = handle,
				bodyUpdate = bodyUpdate,
				bodies = {},
				constraintRecords = {},
				connections = {},
			}
			worlds[object] = world
			object._world = world

			for _, child in ipairs(object:GetChildren()) do
				createBody(world, child)
			end
			for _, child in ipairs(object:GetChildren()) do
				watchConstraint(world, child)
			end
			world.connections.added = object.ChildAdded:Connect(function(child)
				if not createBody(world, child) then
					watchConstraint(world, child)
				end
			end)
			world.connections.removed = object.ChildRemoved:Connect(function(child)
				if world.bodies[child] then
					destroyBody(world, child)
				elseif world.constraintRecords[child] then
					destroyConstraint(world, child)
				end
			end)
			world.connections.changed = object.Changed:Connect(function(property)
				if property == "Gravity" then
					native.Kine_Box2D_SetGravity(handle, object.Gravity.X, object.Gravity.Y)
				end
			end)

			object.AddBody = function(_, body)
				body.Parent = object
				return world.bodies[body] ~= nil
			end
			object.RemoveBody = function(_, body)
				destroyBody(world, body)
				body.Parent = nil
			end
			object.AddConstraint = function(_, constraint)
				constraint.Parent = object
				return constraint.Active == true
			end
			object.RemoveConstraint = function(_, constraint)
				destroyConstraint(world, constraint)
				constraint.Parent = nil
			end
			object.Clear = function()
				local constraints = {}
				for constraint in pairs(world.constraintRecords) do
					table.insert(constraints, constraint)
				end
				for _, constraint in ipairs(constraints) do
					destroyConstraint(world, constraint)
					constraint.Parent = nil
				end
				local bodies = {}
				for body in pairs(world.bodies) do
					table.insert(bodies, body)
				end
				for _, body in ipairs(bodies) do
					destroyBody(world, body)
					body.Parent = nil
				end
			end
			object.Step = function(_, dt)
				native.Kine_Box2D_StepWithGravity(
					handle,
					dt,
					object.VelocityIterations or 4,
					tonumber(object.Gravity.X),
					tonumber(object.Gravity.Y)
				)
				object.ElapsedTime = object.ElapsedTime + dt
				syncBodies(world)
			end
			return handle
		end,
	})

	signal:Connect(function(route, dt)
		if route ~= "RenderStepped" then
			return
		end
		for _, world in pairs(worlds) do
			local object = world.object
			if not object.Paused then
				local step = (object.FixedDeltaTime or dt) * (object.TimeScale or 1)
				native.Kine_Box2D_StepWithGravity(
					world.handle,
					step,
					object.VelocityIterations or 4,
					tonumber(object.Gravity.X),
					tonumber(object.Gravity.Y)
				)
				object.ElapsedTime = object.ElapsedTime + step
				syncBodies(world)
			end
		end
	end)
	table.insert(game.ShutdownCallbacks, function()
		local list = {}
		for _, world in pairs(worlds) do
			table.insert(list, world)
		end
		for _, world in ipairs(list) do
			destroyWorld(world)
		end
	end)
end

return Service
