-- description: "A spring between two Attachment2D instances."
return {
	class = "SpringConstraint2D",
	callback = function(instance)
		instance:SetProperties({
			Name = "SpringConstraint2D",
			BaseClass = "Constraint2D",
			Attachment0 = nil,
			Attachment1 = nil,
			FreeLength = 100,
			Stiffness = 100,
			Damping = 5,
			Frequency = 0,
			DampingRatio = 0,
			CollideConnected = false,
			Active = false,
			JointID = nil,
			Enabled = true,
		})
		return instance
	end,
}
