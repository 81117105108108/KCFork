local button = require("./button")

return {
	name = "UI",
	type = "category",
	buttons = {
		button("Screen GUI", "ScreenGui", "Insert a ScreenGui", "insert", { "ScreenGui", "ScreenGui" }),
		button("Frame", "Frame", "Insert a Frame", "insert", { "Frame", "Frame" }),
		button("Text", "TextLabel", "Insert a TextLabel", "insert", { "TextLabel", "TextLabel" }),
		button("Button", "TextButton", "Insert a TextButton", "insert", { "TextButton", "TextButton" }),
		button("Text Box", "TextBox", "Insert a TextBox", "insert", { "TextBox", "TextBox" }),
		button("Image", "ImageLabel", "Insert an ImageLabel", "insert", { "ImageLabel", "ImageLabel" }),
		button("Image Button", "ImageButton", "Insert an ImageButton", "insert", { "ImageButton", "ImageButton" }),
		button(
			"Scrolling",
			"ScrollingFrame",
			"Insert a ScrollingFrame",
			"insert",
			{ "ScrollingFrame", "ScrollingFrame" }
		),
		button("List Layout", "UIListLayout", "Insert a UIListLayout", "insert", { "UIListLayout", "UIListLayout" }),
		button("Grid Layout", "UIGridLayout", "Insert a UIGridLayout", "insert", { "UIGridLayout", "UIGridLayout" }),
		button("Corner", "UICorner", "Round the selected UI object", "insert", { "UICorner", "UICorner" }),
		button(
			"Gradient",
			"UIGradient",
			"Add a gradient to the selected UI object",
			"insert",
			{ "UIGradient", "UIGradient" }
		),
		button("Padding", "UIPadding", "Add padding to the selected UI object", "insert", { "UIPadding", "UIPadding" }),
		button("Stroke", "UIStroke", "Add a stroke to the selected UI object", "insert", { "UIStroke", "UIStroke" }),
	},
}
