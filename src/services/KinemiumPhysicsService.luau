--!strict
-- KinemiumPhysicsService.luau
-- Fixed-Step Physics Accumulator, Substepping & Transform Interpolation Service

local CFrame = require("../environment/datatypes/CFrame")
local Vector3 = require("../environment/datatypes/Vector3")

export type BodyTransformState = {
	previousCFrame: any,
	currentCFrame: any,
	renderCFrame: any,
	isSimulated: boolean,
	hasRotationChanged: boolean,
	q0x: number,
	q0y: number,
	q0z: number,
	q0w: number,
	q1x: number,
	q1y: number,
	q1z: number,
	q1w: number,
}

export type StepCallback = (fixedDt: number, subStepIndex: number) -> ()

export type KinemiumPhysicsService = {
	-- Configuration
	FixedDt: number,
	MaxSubSteps: number,
	MaxAccumulator: number,
	InterpolationEnabled: boolean,

	-- State
	Accumulator: number,
	InterpolationAlpha: number,
	SubstepsLastTick: number,
	SimulationTime: number,

	-- Methods
	Step: (self: KinemiumPhysicsService, dt: number, stepCallback: StepCallback?) -> (number, number),
	Reset: (self: KinemiumPhysicsService) -> (),
	GetInterpolationAlpha: (self: KinemiumPhysicsService) -> number,
	GetFixedDt: (self: KinemiumPhysicsService) -> number,
	SetFixedDt: (self: KinemiumPhysicsService, fixedDt: number) -> (),
	GetMaxSubSteps: (self: KinemiumPhysicsService) -> number,
	SetMaxSubSteps: (self: KinemiumPhysicsService, maxSubSteps: number) -> (),
	SetInterpolationEnabled: (self: KinemiumPhysicsService, enabled: boolean) -> (),

	-- Body transform lifecycle
	RegisterBody: (self: KinemiumPhysicsService, body: any, initialCFrame: any) -> (),
	UnregisterBody: (self: KinemiumPhysicsService, body: any) -> (),
	HasBody: (self: KinemiumPhysicsService, body: any) -> boolean,
	GetBodyState: (self: KinemiumPhysicsService, body: any) -> BodyTransformState?,
	GetRenderCFrame: (self: KinemiumPhysicsService, body: any) -> any?,
	GetCurrentCFrame: (self: KinemiumPhysicsService, body: any) -> any?,
	GetPreviousCFrame: (self: KinemiumPhysicsService, body: any) -> any?,
	UpdateBodyCFrame: (self: KinemiumPhysicsService, body: any, newCFrame: any) -> (),
	SnapshotTransforms: (self: KinemiumPhysicsService) -> (),
	InterpolateTransforms: (self: KinemiumPhysicsService, alpha: number?) -> (),
	SyncRenderTransforms: (self: KinemiumPhysicsService) -> (),
	ClearBodies: (self: KinemiumPhysicsService) -> (),
	GetBodyCount: (self: KinemiumPhysicsService) -> number,
}

local DEFAULT_FIXED_DT = 1 / 60
local DEFAULT_MAX_SUB_STEPS = 4

local function createService(): KinemiumPhysicsService
	local self = {} :: KinemiumPhysicsService

	self.FixedDt = DEFAULT_FIXED_DT
	self.MaxSubSteps = DEFAULT_MAX_SUB_STEPS
	self.MaxAccumulator = DEFAULT_MAX_SUB_STEPS * DEFAULT_FIXED_DT
	self.InterpolationEnabled = true

	self.Accumulator = 0
	self.InterpolationAlpha = 0
	self.SubstepsLastTick = 0
	self.SimulationTime = 0

	local trackedBodies: { [any]: BodyTransformState } = {}
	local bodyList: { any } = {}
	local bodyIndexMap: { [any]: number } = {}

	local function snapshotTransforms()
		for i = 1, #bodyList do
			local body = bodyList[i]
			local state = trackedBodies[body]
			if state and state.isSimulated then
				state.previousCFrame = state.currentCFrame
				state.q0x, state.q0y, state.q0z, state.q0w = state.q1x, state.q1y, state.q1z, state.q1w
			end
		end
	end

	local function interpolateTransforms(alphaOverride: number?)
		local alpha = alphaOverride or self.InterpolationAlpha

		for i = 1, #bodyList do
			local body = bodyList[i]
			local state = trackedBodies[body]
			if not state or not state.isSimulated then
				continue
			end

			local prev = state.previousCFrame
			local curr = state.currentCFrame
			if not prev or not curr then
				state.renderCFrame = curr or prev
				continue
			end

			if alpha <= 0 then
				state.renderCFrame = prev
				continue
			elseif alpha >= 1 then
				state.renderCFrame = curr
				continue
			end

			-- Fast position lerp
			local p0 = prev.Position
			local p1 = curr.Position
			local px = p0.X + (p1.X - p0.X) * alpha
			local py = p0.Y + (p1.Y - p0.Y) * alpha
			local pz = p0.Z + (p1.Z - p0.Z) * alpha

			if not state.hasRotationChanged then
				-- Rotations match: reuse rotation directly without quaternion math
				local r = curr.Rotation
				state.renderCFrame = CFrame.new(
					px, py, pz,
					r[1][1], r[1][2], r[1][3],
					r[2][1], r[2][2], r[2][3],
					r[3][1], r[3][2], r[3][3]
				)
			else
				-- Quaternion slerp using pre-extracted quaternions
				local q1x, q1y, q1z, q1w = state.q0x, state.q0y, state.q0z, state.q0w
				local q2x, q2y, q2z, q2w = state.q1x, state.q1y, state.q1z, state.q1w

				local dot = q1x * q2x + q1y * q2y + q1z * q2z + q1w * q2w
				if dot < 0 then
					dot = -dot
					q2x, q2y, q2z, q2w = -q2x, -q2y, -q2z, -q2w
				end

				local rx: number, ry: number, rz: number, rw: number
				if dot > 0.9995 then
					rx = q1x + (q2x - q1x) * alpha
					ry = q1y + (q2y - q1y) * alpha
					rz = q1z + (q2z - q1z) * alpha
					rw = q1w + (q2w - q1w) * alpha
				else
					local theta0 = math.acos(math.clamp(dot, -1, 1))
					local sinTheta0 = math.sin(theta0)
					local theta = theta0 * alpha
					local sinTheta = math.sin(theta)

					local s0 = math.cos(theta) - dot * sinTheta / sinTheta0
					local s1 = sinTheta / sinTheta0

					rx = q1x * s0 + q2x * s1
					ry = q1y * s0 + q2y * s1
					rz = q1z * s0 + q2z * s1
					rw = q1w * s0 + q2w * s1
				end

				local len = math.sqrt(rx * rx + ry * ry + rz * rz + rw * rw)
				if len > 1e-12 then
					rx, ry, rz, rw = rx / len, ry / len, rz / len, rw / len
				else
					rx, ry, rz, rw = 0, 0, 0, 1
				end

				local xx, yy, zz = rx * rx, ry * ry, rz * rz
				local xy, xz, yz = rx * ry, rx * rz, ry * rz
				local wx, wy, wz = rw * rx, rw * ry, rw * rz

				local m00 = 1 - 2 * (yy + zz)
				local m01 = 2 * (xy - wz)
				local m02 = 2 * (xz + wy)

				local m10 = 2 * (xy + wz)
				local m11 = 1 - 2 * (xx + zz)
				local m12 = 2 * (yz - wx)

				local m20 = 2 * (xz - wy)
				local m21 = 2 * (yz + wx)
				local m22 = 1 - 2 * (xx + yy)

				state.renderCFrame = CFrame.new(px, py, pz, m00, m01, m02, m10, m11, m12, m20, m21, m22)
			end
		end
	end

	function self.Step(_self: KinemiumPhysicsService, dt: number, stepCallback: StepCallback?): (number, number)
		if dt < 0 or dt ~= dt then
			dt = 0
		end

		-- Clamp frame dt to prevent spiral-of-death accumulation during hitches
		local clampedDt = math.min(dt, self.MaxAccumulator)
		self.Accumulator += clampedDt

		local subStepsTaken = 0

		if self.Accumulator >= self.FixedDt then
			-- Rotate previous transforms before executing any new substeps
			snapshotTransforms()

			while self.Accumulator >= self.FixedDt and subStepsTaken < self.MaxSubSteps do
				subStepsTaken += 1
				self.Accumulator -= self.FixedDt
				self.SimulationTime += self.FixedDt

				if stepCallback then
					stepCallback(self.FixedDt, subStepsTaken)
				end
			end

			-- Discard remaining excess time if max substeps was exceeded
			if self.Accumulator >= self.FixedDt then
				self.Accumulator = self.Accumulator % self.FixedDt
			end
		end

		-- Compute interpolation alpha: alpha = accumulator / FixedDt in [0, 1)
		local alpha = math.clamp(self.Accumulator / self.FixedDt, 0, 1)
		self.InterpolationAlpha = alpha
		self.SubstepsLastTick = subStepsTaken

		if self.InterpolationEnabled then
			interpolateTransforms(alpha)
		end

		return subStepsTaken, alpha
	end

	function self.Reset(_self: KinemiumPhysicsService): ()
		self.Accumulator = 0
		self.InterpolationAlpha = 0
		self.SubstepsLastTick = 0
		self.SimulationTime = 0
	end

	function self.GetInterpolationAlpha(_self: KinemiumPhysicsService): number
		return self.InterpolationAlpha
	end

	function self.GetFixedDt(_self: KinemiumPhysicsService): number
		return self.FixedDt
	end

	function self.SetFixedDt(_self: KinemiumPhysicsService, fixedDt: number): ()
		assert(fixedDt > 0 and fixedDt == fixedDt, "FixedDt must be a positive number")
		self.FixedDt = fixedDt
		self.MaxAccumulator = self.MaxSubSteps * fixedDt
	end

	function self.GetMaxSubSteps(_self: KinemiumPhysicsService): number
		return self.MaxSubSteps
	end

	function self.SetMaxSubSteps(_self: KinemiumPhysicsService, maxSubSteps: number): ()
		assert(maxSubSteps >= 1 and maxSubSteps % 1 == 0, "MaxSubSteps must be a positive integer >= 1")
		self.MaxSubSteps = maxSubSteps
		self.MaxAccumulator = maxSubSteps * self.FixedDt
	end

	function self.SetInterpolationEnabled(_self: KinemiumPhysicsService, enabled: boolean): ()
		self.InterpolationEnabled = enabled
	end

	function self.RegisterBody(_self: KinemiumPhysicsService, body: any, initialCFrame: any): ()
		assert(body ~= nil, "Body cannot be nil")
		local qx, qy, qz, qw = initialCFrame:ToQuaternion()
		local existing = trackedBodies[body]
		if existing then
			existing.currentCFrame = initialCFrame
			existing.previousCFrame = initialCFrame
			existing.renderCFrame = initialCFrame
			existing.hasRotationChanged = false
			existing.q0x, existing.q0y, existing.q0z, existing.q0w = qx, qy, qz, qw
			existing.q1x, existing.q1y, existing.q1z, existing.q1w = qx, qy, qz, qw
			return
		end

		local state: BodyTransformState = {
			previousCFrame = initialCFrame,
			currentCFrame = initialCFrame,
			renderCFrame = initialCFrame,
			isSimulated = true,
			hasRotationChanged = false,
			q0x = qx,
			q0y = qy,
			q0z = qz,
			q0w = qw,
			q1x = qx,
			q1y = qy,
			q1z = qz,
			q1w = qw,
		}
		trackedBodies[body] = state
		table.insert(bodyList, body)
		bodyIndexMap[body] = #bodyList
	end

	function self.UnregisterBody(_self: KinemiumPhysicsService, body: any): ()
		if not trackedBodies[body] then
			return
		end
		trackedBodies[body] = nil
		local index = bodyIndexMap[body]
		if index then
			local lastBody = bodyList[#bodyList]
			bodyList[index] = lastBody
			bodyIndexMap[lastBody] = index
			bodyList[#bodyList] = nil
			bodyIndexMap[body] = nil
		end
	end

	function self.HasBody(_self: KinemiumPhysicsService, body: any): boolean
		return trackedBodies[body] ~= nil
	end

	function self.GetBodyState(_self: KinemiumPhysicsService, body: any): BodyTransformState?
		return trackedBodies[body]
	end

	function self.GetRenderCFrame(_self: KinemiumPhysicsService, body: any): any?
		local state = trackedBodies[body]
		return state and state.renderCFrame
	end

	function self.GetCurrentCFrame(_self: KinemiumPhysicsService, body: any): any?
		local state = trackedBodies[body]
		return state and state.currentCFrame
	end

	function self.GetPreviousCFrame(_self: KinemiumPhysicsService, body: any): any?
		local state = trackedBodies[body]
		return state and state.previousCFrame
	end

	function self.UpdateBodyCFrame(_self: KinemiumPhysicsService, body: any, newCFrame: any): ()
		local state = trackedBodies[body]
		if not state then
			return
		end

		state.currentCFrame = newCFrame
		local r0 = state.previousCFrame.Rotation
		local r1 = newCFrame.Rotation

		if r0 == r1 or (
			r0[1][1] == r1[1][1] and r0[1][2] == r1[1][2] and r0[1][3] == r1[1][3]
			and r0[2][1] == r1[2][1] and r0[2][2] == r1[2][2] and r0[2][3] == r1[2][3]
			and r0[3][1] == r1[3][1] and r0[3][2] == r1[3][2] and r0[3][3] == r1[3][3]
		) then
			state.hasRotationChanged = false
		else
			state.hasRotationChanged = true
			state.q1x, state.q1y, state.q1z, state.q1w = newCFrame:ToQuaternion()
		end
	end

	function self.SnapshotTransforms(_self: KinemiumPhysicsService): ()
		snapshotTransforms()
	end

	function self.InterpolateTransforms(_self: KinemiumPhysicsService, alpha: number?): ()
		interpolateTransforms(alpha)
	end

	function self.SyncRenderTransforms(_self: KinemiumPhysicsService): ()
		for i = 1, #bodyList do
			local body = bodyList[i]
			local state = trackedBodies[body]
			if state and state.isSimulated and type(body) == "table" and body.CFrame ~= nil then
				body.CFrame = state.renderCFrame
			end
		end
	end

	function self.ClearBodies(_self: KinemiumPhysicsService): ()
		table.clear(trackedBodies)
		table.clear(bodyList)
		table.clear(bodyIndexMap)
	end

	function self.GetBodyCount(_self: KinemiumPhysicsService): number
		return #bodyList
	end

	return self
end

local sharedService = createService()

return table.freeze({
	new = createService,
	shared = sharedService,
	FIXED_DT = DEFAULT_FIXED_DT,
	MAX_SUB_STEPS = DEFAULT_MAX_SUB_STEPS,
})
