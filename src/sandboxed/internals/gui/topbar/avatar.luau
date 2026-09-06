local button = require("./button")

return {
	name = "Avatar",
	type = "category",
	buttons = {
		button("Character", "Character", "Create a default playable character rig", "character"),
		button("Humanoid", "Humanoid", "Insert a Humanoid", "insert", { "Humanoid", "Humanoid" }),
		button("Accessory", "Accessory", "Insert an Accessory", "insert", { "Accessory", "Accessory" }),
		button("Animation", "Animation", "Insert an Animation", "insert", { "Animation", "Animation" }),
		button("Animator", "Animator", "Insert an Animator", "insert", { "Animator", "Animator" }),
		button("Shirt", "Shirt", "Insert a Shirt", "insert", { "Shirt", "Shirt" }),
		button("Pants", "Pants", "Insert Pants", "insert", { "Pants", "Pants" }),
		button("Graphic", "ShirtGraphic", "Insert a ShirtGraphic", "insert", { "ShirtGraphic", "ShirtGraphic" }),
	},
}
