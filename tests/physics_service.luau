--!strict
-- tests/physics_service.luau
-- Unit and regression tests for KinemiumPhysicsService (fixed-step accumulator, substepping, and transform interpolation)

local PhysicsServiceModule = require("../src/services/KinemiumPhysicsService")
local CFrame = require("../src/environment/datatypes/CFrame")
local Vector3 = require("../src/environment/datatypes/Vector3")

local passed = 0
local function test(name: string, callback: () -> ()): ()
	callback()
	passed += 1
	print("PASS\t" .. name)
end

local FIXED_DT = PhysicsServiceModule.FIXED_DT

test("exact 60 FPS framerate produces 1 substep and 0 remainder alpha", function()
	local service = PhysicsServiceModule.new()
	local substepCount = 0
	local reportedDt = 0

	local steps, alpha = service:Step(FIXED_DT, function(fdt, _idx)
		substepCount += 1
		reportedDt = fdt
	end)

	assert(steps == 1, "Expected 1 substep at 60 FPS")
	assert(substepCount == 1, "Callback should have been called once")
	assert(math.abs(reportedDt - FIXED_DT) < 1e-9, "Reported dt must match FIXED_DT")
	assert(math.abs(alpha) < 1e-9, "Alpha should be 0 on exact step")
	assert(math.abs(service.Accumulator) < 1e-9, "Accumulator should be empty")
end)

test("120 FPS high framerate alternates between 0 and 1 substep with 0.5 alpha", function()
	local service = PhysicsServiceModule.new()
	local dt = FIXED_DT / 2 -- 120 FPS

	-- Frame 1: half a physics tick
	local steps1, alpha1 = service:Step(dt)
	assert(steps1 == 0, "Frame 1 at 120 FPS should have 0 substeps")
	assert(math.abs(alpha1 - 0.5) < 1e-6, "Frame 1 alpha should be ~0.5")

	-- Frame 2: completes a physics tick
	local steps2, alpha2 = service:Step(dt)
	assert(steps2 == 1, "Frame 2 at 120 FPS should have 1 substep")
	assert(math.abs(alpha2 - 0.0) < 1e-6, "Frame 2 alpha should reset to ~0")
end)

test("30 FPS low framerate produces 2 substeps per frame", function()
	local service = PhysicsServiceModule.new()
	local dt = FIXED_DT * 2 -- 30 FPS
	local callbackSteps = 0

	local steps, alpha = service:Step(dt, function(_fdt, idx)
		callbackSteps = idx
	end)

	assert(steps == 2, "Expected 2 substeps at 30 FPS")
	assert(callbackSteps == 2, "Expected callback to report 2nd substep")
	assert(math.abs(alpha) < 1e-6, "Expected alpha ~0 on exact multiple")
end)

test("spiral-of-death prevention caps substeps at MaxSubSteps", function()
	local service = PhysicsServiceModule.new()
	service:SetMaxSubSteps(4)

	-- Simulate a massive 1-second lag spike / hitch
	local steps, alpha = service:Step(1.0)

	assert(steps == 4, string.format("Expected capped at 4 substeps, got %d", steps))
	assert(service.SubstepsLastTick == 4, "SubstepsLastTick must record 4")
	assert(alpha >= 0 and alpha < 1, "Alpha must remain within [0, 1)")
	assert(service.Accumulator < service.FixedDt, "Excess accumulator must not accumulate indefinitely")
end)

test("negative or NaN delta time is handled safely without corruption", function()
	local service = PhysicsServiceModule.new()

	local steps1, alpha1 = service:Step(-0.5)
	assert(steps1 == 0 and alpha1 == 0, "Negative dt must be clamped to 0")

	local steps2, alpha2 = service:Step(0 / 0) -- NaN
	assert(steps2 == 0 and alpha2 == 0, "NaN dt must be clamped to 0")
end)

test("body registration, update, and linear position interpolation", function()
	local service = PhysicsServiceModule.new()
	local body = {}

	local cfStart = CFrame.new(0, 0, 0)
	local cfEnd = CFrame.new(10, 20, 30)

	service:RegisterBody(body, cfStart)
	assert(service:HasBody(body), "Body should be registered")
	assert(service:GetBodyCount() == 1, "Body count should be 1")

	-- Update current transform after a physics tick
	service:UpdateBodyCFrame(body, cfEnd)

	-- Interpolate at alpha = 0.5
	service:InterpolateTransforms(0.5)
	local renderCF = service:GetRenderCFrame(body)
	assert(renderCF ~= nil, "Render CFrame should exist")

	local expectedPos = Vector3.new(5, 10, 15)
	local diff = (renderCF.Position - expectedPos):Magnitude()
	assert(diff < 1e-5, string.format("Expected position (5, 10, 15), got %s", tostring(renderCF.Position)))

	-- Interpolate at alpha = 0
	service:InterpolateTransforms(0)
	local renderCF0 = service:GetRenderCFrame(body)
	assert((renderCF0.Position - cfStart.Position):Magnitude() < 1e-5, "Alpha 0 should match start CFrame")

	-- Interpolate at alpha = 1
	service:InterpolateTransforms(1)
	local renderCF1 = service:GetRenderCFrame(body)
	assert((renderCF1.Position - cfEnd.Position):Magnitude() < 1e-5, "Alpha 1 should match end CFrame")
end)

test("quaternion rotation slerp interpolation produces smooth intermediate orientations", function()
	local service = PhysicsServiceModule.new()
	local body = {}

	-- Rotation from 0 deg to 90 deg around Y axis
	local cfStart = CFrame.Angles(0, 0, 0)
	local cfEnd = CFrame.Angles(0, math.rad(90), 0)

	service:RegisterBody(body, cfStart)
	service:UpdateBodyCFrame(body, cfEnd)

	-- Interpolate halfway (45 degrees)
	service:InterpolateTransforms(0.5)
	local midCF = service:GetRenderCFrame(body)

	local _rx, ry, _rz = midCF:ToOrientation()
	local expectedDeg = 45
	local actualDeg = math.deg(ry)
	assert(math.abs(actualDeg - expectedDeg) < 0.5, string.format("Expected ~45 deg, got %.2f deg", actualDeg))
end)

test("unregister body removes from tracking and maintains contiguous list", function()
	local service = PhysicsServiceModule.new()
	local b1, b2, b3 = {}, {}, {}

	service:RegisterBody(b1, CFrame.new(1, 0, 0))
	service:RegisterBody(b2, CFrame.new(2, 0, 0))
	service:RegisterBody(b3, CFrame.new(3, 0, 0))
	assert(service:GetBodyCount() == 3)

	service:UnregisterBody(b2)
	assert(service:GetBodyCount() == 2)
	assert(service:HasBody(b1) and not service:HasBody(b2) and service:HasBody(b3))

	service:ClearBodies()
	assert(service:GetBodyCount() == 0)
end)

test("performance budget: 1,000 bodies transform update and interpolation completes in < 1.5ms", function()
	local service = PhysicsServiceModule.new()
	local count = 1000
	local bodies = table.create(count)

	for i = 1, count do
		local b = { id = i }
		bodies[i] = b
		service:RegisterBody(b, CFrame.new(i, 0, 0))
	end

	-- Measure time to advance simulation and interpolate 1,000 bodies
	local start = os.clock()

	-- 1. Step accumulator with 1/60s dt
	service:Step(FIXED_DT, function(_fdt, _idx)
		-- Simulate physics update for 1,000 bodies
		for i = 1, count do
			local b = bodies[i]
			service:UpdateBodyCFrame(b, CFrame.new(i + 1, 0.5, 0))
		end
	end)

	-- 2. Interpolate transforms at alpha = 0.5
	service:InterpolateTransforms(0.5)

	local elapsed = os.clock() - start
	local elapsedMs = elapsed * 1000

	print(string.format("  -> 1,000 bodies update & interpolate took: %.3f ms (Budget: < 1.5 ms)", elapsedMs))
	assert(elapsedMs < 1.5, string.format("Transform sync exceeded 1.5ms budget: %.3f ms", elapsedMs))
end)

test("reset clears accumulated time and simulation metrics", function()
	local service = PhysicsServiceModule.new()
	service:Step(FIXED_DT * 3)
	assert(service.SimulationTime > 0)

	service:Reset()
	assert(service.Accumulator == 0)
	assert(service.InterpolationAlpha == 0)
	assert(service.SimulationTime == 0)
	assert(service.SubstepsLastTick == 0)
end)

print(string.format("%d physics service tests passed", passed))
