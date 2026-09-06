-- description: "A rigid 2D joint between two Body2D instances."
return {
	class = "WeldConstraint2D",
	callback = function(instance)
		instance:SetProperties({
			Name = "WeldConstraint2D",
			BaseClass = "Constraint2D",
			Body0 = nil,
			Body1 = nil,
			Attachment0 = nil,
			Attachment1 = nil,
			LinearFrequency = 0,
			AngularFrequency = 0,
			LinearDampingRatio = 1,
			AngularDampingRatio = 1,
			CollideConnected = false,
			Active = false,
			JointID = nil,
			Enabled = true,
		})
		return instance
	end,
}
