local typedefs = require("../typedefs")

local argon = require("@Argon")

local Image = require("./Image")
local Text = require("./Text")
local Dropdown = require("./Dropdown")
local arrowDown = argon:CreateImageFromPath("./src/assets/images/icons/ArrowDown.png")

local TEXT_SIZE = 13
local DEFAULT_DROPDOWN_WIDTH = 22

return function(params: typedefs.ImageTextButtonParams, dt: number)
	local window = params.engine_window
	local renderer = params.renderer
	local theme = params.theme

	local cornerRadius = params.CornerRadius or theme.ButtonCornerRadius or 12

	local drawX = params.x
	local drawY = params.y

	local hasDropdown = params.HasDropdown == true
	local dropdownWidth = hasDropdown and (params.DropdownWidth or DEFAULT_DROPDOWN_WIDTH) or 0
	local contentWidth = math.max(params.width - dropdownWidth, 0)

	local dropdownX = drawX + contentWidth

	local dropdownRect = {
		x = dropdownX,
		y = drawY,
		width = dropdownWidth,
		height = params.height,
	}

	local dropdownHovered = false

	if hasDropdown and renderer then
		dropdownHovered = renderer:isMouseInRect(dropdownRect)
	end

	argon:Save(window)

	argon:ClipRoundRect(window, {
		x = drawX,
		y = drawY,
		width = params.width,
		height = params.height,
	}, cornerRadius, cornerRadius)

	-- Main button background
	argon:DrawRectangle(window, {
		x = drawX,
		y = drawY,
		width = params.width,
		height = params.height,
		Color = params.Color,
	})

	--
	-- Dropdown drawer section
	--

	if hasDropdown then
		if dropdownHovered then
			argon:DrawRectangle(window, {
				x = dropdownRect.x,
				y = dropdownRect.y,
				width = dropdownRect.width,
				height = dropdownRect.height,
				Color = params.DropdownHoverColor or theme.ButtonHoverColor or theme.SecondaryColor or params.Color,
			})
		end

		-- Separator between main button and drawer button
		argon:DrawLine(window, {
			X = dropdownX,
			Y = drawY + 7,
		}, {
			X = dropdownX,
			Y = drawY + params.height - 7,
		}, 1, params.DropdownSeparatorColor or theme.BorderColor or theme.SecondaryTextColor or theme.TextColor)
	end

	--
	-- Main image/text content
	--

	local padding = params.padding or 8
	local textSize = params.TextSize or TEXT_SIZE

	local font = argon:CreateFont(theme.Font)

	local textHeight = argon:GetFontLineHeight(textSize, font)
	local textAscent = argon:GetFontAscent(textSize, font)

	local textAreaHeight = textHeight + padding * 2
	local imageAreaHeight = math.max(params.height - textAreaHeight, 0)

	local maxImageWidth = math.max(contentWidth - padding * 2, 0)
	local maxImageHeight = math.max(imageAreaHeight - padding * 2, 0)

	local imageWidth = params.imageWidth or maxImageWidth
	local imageHeight = params.imageHeight or maxImageHeight

	if params.preserveAspectRatio and params.imageAspectRatio then
		local aspect = params.imageAspectRatio

		if aspect > 0 then
			if imageWidth / aspect > imageHeight then
				imageWidth = imageHeight * aspect
			else
				imageHeight = imageWidth / aspect
			end
		end
	end

	imageWidth = math.min(imageWidth, maxImageWidth)
	imageHeight = math.min(imageHeight, maxImageHeight)

	local imageX = drawX + contentWidth / 2 - imageWidth / 2

	local imageY = drawY + padding + maxImageHeight / 2 - imageHeight / 2

	Image({
		x = imageX,
		y = imageY,

		width = imageWidth,
		height = imageHeight,

		Image = params.Image,

		engine_window = window,
	}, dt)

	local text = params.text or ""

	local textWidth = argon:MeasureText(window, text, textSize, font)

	local textX = drawX + contentWidth / 2 - textWidth / 2

	local textY = drawY + params.height - textAreaHeight + (textAreaHeight - textHeight) / 2 + textAscent

	Text({
		x = textX,
		y = textY,

		TextSize = textSize,

		theme = theme,
		Font = font,

		text = text,

		Color = params.TextColor or theme.TextColor,

		engine_window = window,
	}, dt)

	argon:Restore(window)

	--
	-- Actual Immco Dropdown
	--
	-- This is outside the clip so the dropdown menu itself
	-- isn't clipped to the ImageTextButton.
	--

	if hasDropdown then
		local dropdownParams = table.clone(params.DropdownParams or {})

		dropdownParams.id = dropdownParams.id or params.id or (text .. "_dropdown")

		dropdownParams.x = dropdownRect.x
		dropdownParams.y = dropdownRect.y

		dropdownParams.width = dropdownRect.width
		dropdownParams.height = dropdownRect.height

		dropdownParams.theme = dropdownParams.theme or theme
		dropdownParams.engine_window = dropdownParams.engine_window or window
		dropdownParams.renderer = dropdownParams.renderer or renderer

		dropdownParams.RetainedStorage = dropdownParams.RetainedStorage or params.RetainedStorage

		Dropdown(dropdownParams, dt)

		Image({
			x = dropdownX + (dropdownWidth - 12) / 2,
			y = drawY + 9,
			width = 12,
			height = 12,

			Image = arrowDown,

			theme = theme,
			engine_window = window,
		}, dt)
	end
end
