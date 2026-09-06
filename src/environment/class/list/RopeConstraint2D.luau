-- description: "A distance-limited rope between two Attachment2D instances."
return {
	class = "RopeConstraint2D",
	callback = function(instance)
		instance:SetProperties({
			Name = "RopeConstraint2D",
			BaseClass = "Constraint2D",
			Attachment0 = nil,
			Attachment1 = nil,
			Length = 100,
			MinLength = 0,
			-- Retained for project compatibility; ropes are inextensible, so these
			-- values do not affect the Box2D distance limit.
			Stiffness = 0,
			Damping = 0.1,
			CollideConnected = false,
			Active = false,
			JointID = nil,
			Enabled = true,
		})
		return instance
	end,
}
