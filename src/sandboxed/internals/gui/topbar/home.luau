local button = require("./button")
local separator = require("./separator")

return {
	name = "Home",
	type = "category",
	buttons = {
		button("Select", "Cursor", "Select objects in the viewport", "tool", { "Select" }),
		button("Move", "Move", "Move the selected part", "tool", { "Move" }),
		button("Scale", "Size", "Resize the selected part", "tool", { "Size" }),
		button("Rotate", "Rotate", "Rotate the selected part", "tool", { "Rotate" }),
		separator(),
		{
			type = "custom",
			id = "transform-snap",
			width = 90,

			studs = 1,
			degrees = 45,

			render = function(ctx)
				local rect = ctx.rect
				local button = ctx.button

				local inputHeight = 20
				local gap = 3

				local function parseNumber(text)
					return tonumber(text:match("[-+]?%d*%.?%d+"))
				end

				ctx.Immco.TextInput({
					x = rect.x,
					y = rect.y,
					width = rect.width,
					height = inputHeight,

					id = "toolbar-snap-studs",
					RetainedStorage = ctx.retained,

					renderer = ctx.renderer,
					engine_window = ctx.window,
					theme = ctx.theme,
					Color = ctx.theme.InputColor,
					FocusColor = ctx.theme.InputFocusColor,
					TextColor = ctx.theme.InputTextColor,
					PlaceholderColor = ctx.theme.InputPlaceholderColor,

					placeholder = tostring(button.studs) .. " studs",

					OnSubmit = function(text)
						local value = parseNumber(text)

						if value and value > 0 then
							button.studs = value

							if button.OnStudsChanged then
								button.OnStudsChanged(value)
							end
						end
					end,
				}, ctx.dt)

				ctx.Immco.TextInput({
					x = rect.x,
					y = rect.y + inputHeight + gap,
					width = rect.width,
					height = inputHeight,

					id = "toolbar-snap-degrees",
					RetainedStorage = ctx.retained,

					renderer = ctx.renderer,
					engine_window = ctx.window,
					theme = ctx.theme,
					Color = ctx.theme.InputColor,
					FocusColor = ctx.theme.InputFocusColor,
					TextColor = ctx.theme.InputTextColor,
					PlaceholderColor = ctx.theme.InputPlaceholderColor,

					placeholder = tostring(button.degrees) .. "°",

					OnSubmit = function(text)
						local value = parseNumber(text)

						if value and value > 0 then
							button.degrees = value

							if button.OnDegreesChanged then
								button.OnDegreesChanged(value)
							end
						end
					end,
				}, ctx.dt)
			end,
		},
		separator(),
		button("Material", "Texture", "Cycle the material of selected parts", "material"),
		button("Color", "ColorPicker", "Cycle the color of selected parts", "color"),
		require("./buttons/shader_maker"),

		separator(),

		button("Lock", "SelectionBox", "Lock or unlock selected parts", "lock"),
		button("Anchor", "Attachment", "Anchor or unanchor selected parts", "anchor"),
		button("Group", "Model", "Group or ungroup the selection", "group"),
	},
}
