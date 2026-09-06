local Rectangle = require("./Rectangle")
local Text = require("./Text")
local TextInput = require("./TextInput")
local argon = require("@Argon")
local scroller = require("./Scroller")

local DEFAULT_SEPARATOR_HEIGHT = 9
local DEFAULT_SEARCH_GAP = 4
local SUBMENU_OVERLAP = 2
local EMPTY_TEXT = "No results"

local Vector2 = require("@Vector2")

local SIZE_PRESETS = {
	xs = {
		itemHeight = 22,
		textSize = 11,
		padding = 3,
		textPadding = 7,
		searchHeight = 20,
		leadingWidth = 16,
	},
	sm = {
		itemHeight = 24,
		textSize = 12,
		padding = 4,
		textPadding = 8,
		searchHeight = 22,
		leadingWidth = 17,
	},
	md = {
		itemHeight = 26,
		textSize = 13,
		padding = 4,
		textPadding = 9,
		searchHeight = 24,
		leadingWidth = 18,
	},
	lg = {
		itemHeight = 32,
		textSize = 15,
		padding = 5,
		textPadding = 11,
		searchHeight = 28,
		leadingWidth = 20,
	},
	xl = {
		itemHeight = 38,
		textSize = 17,
		padding = 6,
		textPadding = 13,
		searchHeight = 32,
		leadingWidth = 22,
	},
}

export type ContextMenuSize = "xs" | "sm" | "md" | "lg" | "xl"
export type ContextMenuVariant = "default" | "soft" | "bordered" | "minimal"
export type ContextMenuItemKind = "normal" | "checkbox" | "radio"

export type ContextMenuItem = {
	text: string?,
	shortcut: string?,
	mnemonic: string?,
	iconText: string?,
	disabled: boolean?,
	separator: boolean?,
	header: boolean?,
	active: boolean?,
	danger: boolean?,
	keepOpen: boolean?,
	kind: ContextMenuItemKind?,
	checked: boolean?,
	children: { ContextMenuItem }?,
	submenuWidth: number?,
	submenuMaxHeight: number?,
	callback: (() -> ())?,
	onToggle: ((boolean) -> ())?,
}

export type ContextMenuParams = {
	id: string?,
	x: number,
	y: number,
	width: number,
	MaxHeight: number?,
	SubmenuWidth: number?,
	SubmenuMaxHeight: number?,
	RetainedStorage: any?,
	EnableSearch: boolean?,
	SearchPlaceholder: string?,
	EmptyText: string?,
	items: { ContextMenuItem },
	visible: boolean?,
	SuppressInput: boolean?,
	EnableKeyboard: boolean?,
	EnableMnemonics: boolean?,
	ShowMnemonics: boolean?,
	MnemonicRequiresAlt: boolean?,
	OpenSubmenusOnHover: boolean?,
	CloseOnSelect: boolean?,
	ClampToWindow: boolean?,
	Size: ContextMenuSize?,
	Variant: ContextMenuVariant?,
	Color: any?,
	HoverColor: any?,
	ActiveColor: any?,
	TextColor: any?,
	ActiveTextColor: any?,
	DangerColor: any?,
	BorderColor: any?,
	SeparatorColor: any?,
	ShadowColor: any?,
	Shadow: boolean?,
	CornerRadius: number?,
	onSelect: ((ContextMenuItem) -> ())?,
	onClose: (() -> ())?,
	renderer: any,
	engine_window: any,
	theme: any,
}

local function withAlpha(color, alpha: number)
	if not color then
		return nil
	end

	return {
		R = color.R,
		G = color.G,
		B = color.B,
		A = (color.A or 1) * alpha,
	}
end

local function resolveMetrics(size: ContextMenuSize?)
	return SIZE_PRESETS[size or "md"] or SIZE_PRESETS.md
end

local function resolveColors(params: ContextMenuParams, theme, variant: ContextMenuVariant)
	local background = params.Color or theme.SecondaryColor
	local hover = params.HoverColor or theme.ThirdColor
	local active = params.ActiveColor or theme.AccentColor or hover
	local border = params.BorderColor or theme.ThirdColor

	if variant == "soft" then
		background = params.Color or theme.BackgroundColor or theme.SecondaryColor
		hover = params.HoverColor or withAlpha(theme.AccentColor, 0.14) or theme.ThirdColor
		active = params.ActiveColor or withAlpha(theme.AccentColor, 0.24) or theme.ThirdColor
		border = params.BorderColor
	elseif variant == "bordered" then
		background = params.Color or theme.BackgroundColor or theme.SecondaryColor
		hover = params.HoverColor or theme.ThirdColor
		active = params.ActiveColor or theme.AccentColor or hover
		border = params.BorderColor or withAlpha(theme.SecondaryTextColor, 0.35) or theme.ThirdColor
	elseif variant == "minimal" then
		background = params.Color or theme.SecondaryColor
		hover = params.HoverColor or theme.BackgroundColor or theme.ThirdColor
		active = params.ActiveColor or theme.ThirdColor
		border = params.BorderColor
	end

	return {
		background = background,
		hover = hover,
		active = active,
		border = border,
		text = params.TextColor or theme.TextColor,
		activeText = params.ActiveTextColor or params.TextColor or theme.TextColor,
		disabledText = theme.SecondaryTextColor,
		dangerText = params.DangerColor or theme.ErrorColor or argon:RGBA(220, 80, 80),
		separator = params.SeparatorColor or theme.ThirdColor,
		shortcut = theme.SecondaryTextColor,
	}
end

local function containsPoint(renderer, rect): boolean
	return renderer:isMouseInRect(rect)
end

local function clampMenuRect(rect, window, clampToWindow: boolean)
	if not clampToWindow then
		return rect
	end

	local width = window.Width or rect.width
	local height = window.Height or rect.height

	return {
		x = math.clamp(rect.x, 0, math.max(0, width - rect.width)),
		y = math.clamp(rect.y, 0, math.max(0, height - rect.height)),
		width = rect.width,
		height = rect.height,
	}
end

local function textMatches(text: string?, search: string): boolean
	if search == "" then
		return true
	end
	return string.find(string.lower(text or ""), search, 1, true) ~= nil
end

local function itemHasSearchMatch(item: ContextMenuItem, search: string): boolean
	if item.separator then
		return false
	end

	if textMatches(item.text, search) then
		return true
	end

	if item.children then
		for _, child in ipairs(item.children) do
			if itemHasSearchMatch(child, search) then
				return true
			end
		end
	end

	return false
end

local function getVisibleItems(items: { ContextMenuItem }, search: string): { ContextMenuItem }
	if search == "" then
		return items
	end

	local filtered = {}
	local pendingSeparator: ContextMenuItem? = nil

	for _, item in ipairs(items) do
		if item.separator then
			if #filtered > 0 then
				pendingSeparator = item
			end
		elseif itemHasSearchMatch(item, search) then
			if pendingSeparator then
				table.insert(filtered, pendingSeparator)
				pendingSeparator = nil
			end
			table.insert(filtered, item)
		end
	end

	return filtered
end

local function isSelectable(item: ContextMenuItem): boolean
	return not item.separator and not item.header and not item.disabled
end

local function firstSelectable(items: { ContextMenuItem }): number?
	for index, item in ipairs(items) do
		if isSelectable(item) then
			return index
		end
	end
	return nil
end

local function lastSelectable(items: { ContextMenuItem }): number?
	for index = #items, 1, -1 do
		if isSelectable(items[index]) then
			return index
		end
	end
	return nil
end

local function moveSelectable(items: { ContextMenuItem }, current: number?, direction: number): number?
	if #items == 0 then
		return nil
	end

	local index = current or (direction > 0 and 0 or (#items + 1))

	for _ = 1, #items do
		index += direction
		if index < 1 then
			index = #items
		elseif index > #items then
			index = 1
		end

		if isSelectable(items[index]) then
			return index
		end
	end

	return nil
end

local function clearOpenFrom(openPath: { number }, depth: number)
	local index = depth
	while openPath[index] ~= nil do
		openPath[index] = nil
		index += 1
	end
end

local function buildMnemonics(items: { ContextMenuItem }): { [number]: { char: string, position: number } }
	local frequency = {}

	for _, item in ipairs(items) do
		if not item.separator and not item.header then
			local seen = {}
			local text = item.text or ""

			for position = 1, #text do
				local char = string.lower(text:sub(position, position))
				if char:match("^[a-z]$") and not seen[char] then
					seen[char] = true
					frequency[char] = (frequency[char] or 0) + 1
				end
			end
		end
	end

	local used = {}
	local result = {}

	for index, item in ipairs(items) do
		if item.separator or item.header then
			continue
		end

		local text = item.text or ""
		local explicit = item.mnemonic and string.lower(item.mnemonic:sub(1, 1)) or nil

		if explicit and explicit:match("^[a-z]$") and not used[explicit] then
			local position = string.find(string.lower(text), explicit, 1, true)
			if position then
				result[index] = { char = explicit, position = position }
				used[explicit] = true
				continue
			end
		end

		local bestChar = nil
		local bestPosition = nil
		local bestFrequency = math.huge

		for position = 1, #text do
			local char = string.lower(text:sub(position, position))
			if char:match("^[a-z]$") and not used[char] then
				local charFrequency = frequency[char] or math.huge
				if charFrequency < bestFrequency then
					bestChar = char
					bestPosition = position
					bestFrequency = charFrequency
				end
			end
		end

		if not bestChar then
			for position = 1, #text do
				local char = string.lower(text:sub(position, position))
				if char:match("^[a-z]$") then
					local charFrequency = frequency[char] or math.huge
					if charFrequency < bestFrequency then
						bestChar = char
						bestPosition = position
						bestFrequency = charFrequency
					end
				end
			end
		end

		if bestChar and bestPosition then
			result[index] = { char = bestChar, position = bestPosition }
			used[bestChar] = true
		end
	end

	return result
end

return function(params: ContextMenuParams, dt: number)
	local id = params.id or "ContextMenu"

	if params.visible == false then
		local retained = params.RetainedStorage
		if retained and retained[id] then
			retained[id].wasVisible = false
		end
		return
	end

	local window = params.engine_window
	local renderer = params.renderer
	local theme = params.theme
	local suppressInput = params.SuppressInput == true
	local searchEnabled = params.EnableSearch == true
	local keyboardEnabled = params.EnableKeyboard ~= false
	local mnemonicsEnabled = params.EnableMnemonics ~= false
	local showMnemonics = params.ShowMnemonics ~= false
	local mnemonicRequiresAlt = params.MnemonicRequiresAlt == true
	local hoverSubmenus = params.OpenSubmenusOnHover ~= false
	local closeOnSelect = params.CloseOnSelect ~= false
	local clampToWindow = params.ClampToWindow ~= false
	local metrics = resolveMetrics(params.Size)
	local variant = params.Variant or "default"
	local colors = resolveColors(params, theme, variant)
	local separatorHeight = DEFAULT_SEPARATOR_HEIGHT
	local searchGap = DEFAULT_SEARCH_GAP
	local cornerRadius = params.CornerRadius or theme.CornerRadius or 4
	local font = argon:CreateFont(theme.Font)
	local storage = params.RetainedStorage
	assert(storage, "ContextMenu requires RetainedStorage")

	local field = storage[id]
	local createdField = false
	if not field then
		createdField = true
		field = {
			searchStorage = {},
			search = "",
			openPath = {},
			focusedIndex = {},
			keyDown = {},
		}
		storage[id] = field
	end

	field.searchStorage = field.searchStorage or {}
	field.openPath = field.openPath or {}
	field.focusedIndex = field.focusedIndex or {}
	field.keyDown = field.keyDown or {}

	local openingFrame = createdField or field.wasVisible ~= true
	field.wasVisible = true

	local searchText = field.search or ""
	local loweredSearch = string.lower(searchText)
	local textHeight = argon:GetFontLineHeight(metrics.textSize, font)
	local textAscent = argon:GetFontAscent(metrics.textSize, font)
	local drawnRects = {}
	local levelInfos = {}
	local closed = false

	local function closeMenu()
		if closed then
			return
		end
		closed = true
		field.wasVisible = false
		table.clear(field.openPath)
		if params.onClose then
			params.onClose()
		end
	end

	local function activateItem(item: ContextMenuItem)
		if item.disabled or item.header or item.separator then
			return
		end

		if item.kind == "checkbox" and item.onToggle then
			item.onToggle(not item.checked)
		elseif item.kind == "radio" and item.onToggle and not item.checked then
			item.onToggle(true)
		end

		if item.callback then
			item.callback()
		end

		if params.onSelect then
			params.onSelect(item)
		end

		if closeOnSelect and not item.keepOpen then
			closeMenu()
		end
	end

	local function computeHeight(
		items: { ContextMenuItem },
		includeSearch: boolean,
		maxHeight: number?
	): (number, number, number)
		local searchBlockHeight = includeSearch and (metrics.searchHeight + searchGap) or 0
		local contentHeight = 0

		if #items == 0 then
			contentHeight = metrics.itemHeight
		else
			for _, item in ipairs(items) do
				contentHeight += if item.separator then separatorHeight else metrics.itemHeight
			end
		end

		local naturalHeight = metrics.padding * 2 + searchBlockHeight + contentHeight
		local height = math.min(naturalHeight, maxHeight or naturalHeight)
		return height, contentHeight, searchBlockHeight
	end

	local renderLevel
	renderLevel = function(
		items: { ContextMenuItem },
		x: number,
		y: number,
		width: number,
		maxHeight: number?,
		depth: number,
		pathKey: string,
		search: string,
		includeSearch: boolean
	)
		if closed then
			return
		end

		local visibleItems = getVisibleItems(items, search)
		local mnemonicMap = buildMnemonics(visibleItems)
		local height, contentHeight, searchBlockHeight = computeHeight(visibleItems, includeSearch, maxHeight)
		local menuRect = clampMenuRect({ x = x, y = y, width = width, height = height }, window, clampToWindow)
		table.insert(drawnRects, menuRect)

		local focusedIndex = field.focusedIndex[pathKey]
		if focusedIndex and (not visibleItems[focusedIndex] or not isSelectable(visibleItems[focusedIndex])) then
			focusedIndex = nil
			field.focusedIndex[pathKey] = nil
		end

		table.insert(levelInfos, {
			depth = depth,
			pathKey = pathKey,
			items = visibleItems,
			mnemonics = mnemonicMap,
			search = search,
		})

		params.Shadow = true

		if params.Shadow == true then
			argon:DrawUIShadow(window, {
				x = menuRect.x,
				y = menuRect.y,
				width = menuRect.width,
				height = menuRect.height,
				Color = argon:RGBA(0, 0, 0),
			}, 4, 4, Vector2.new(0, 0), 8, 0)
		end

		argon:Save(window)
		argon:ClipRoundRect(window, menuRect, cornerRadius, cornerRadius)

		Rectangle({
			x = menuRect.x,
			y = menuRect.y,
			width = menuRect.width,
			height = menuRect.height,
			Color = colors.background,
			theme = theme,
			engine_window = window,
		}, dt)

		if includeSearch then
			TextInput({
				x = menuRect.x + metrics.padding,
				y = menuRect.y + metrics.padding,
				width = menuRect.width - metrics.padding * 2,
				height = metrics.searchHeight,
				id = id .. "-search",
				RetainedStorage = field.searchStorage,
				renderer = renderer,
				theme = theme,
				Color = theme.BackgroundColor or colors.background,
				FocusColor = colors.hover,
				TextColor = colors.text,
				PlaceholderColor = theme.SecondaryTextColor,
				placeholder = params.SearchPlaceholder or "Search...",
				padding = math.max(5, metrics.textPadding - 2),
				TextSize = metrics.textSize,
				OnChange = function(text)
					if field.search ~= text then
						field.search = text
						table.clear(field.openPath)
						table.clear(field.focusedIndex)
					end
				end,
				engine_window = window,
			}, dt)
		end

		if colors.border then
			Rectangle({
				x = menuRect.x,
				y = menuRect.y,
				width = menuRect.width,
				height = menuRect.height,
				Color = colors.border,
				isOutline = true,
				theme = theme,
				engine_window = window,
			}, dt)
		end

		local listTop = menuRect.y + metrics.padding + searchBlockHeight
		local listHeight = math.max(0, menuRect.height - metrics.padding * 2 - searchBlockHeight)
		local submenuRequest = nil
		local anyLeading = false

		for _, item in ipairs(visibleItems) do
			if not item.separator and (item.kind == "checkbox" or item.kind == "radio" or item.iconText ~= nil) then
				anyLeading = true
				break
			end
		end

		scroller({
			x = menuRect.x + metrics.padding,
			y = listTop,
			width = menuRect.width - metrics.padding * 2,
			height = listHeight,
			ContentWidth = menuRect.width - metrics.padding * 2,
			ContentHeight = contentHeight,
			RetainedStorage = storage,
			id = id .. "-scroller-" .. pathKey,
			renderer = renderer,
			window = window,
			theme = theme,
			ScrollbarWidth = 4,
			ScrollSpeed = metrics.itemHeight * 2,
			CornerRadius = cornerRadius,
			ThumbColor = theme.SecondaryTextColor,
			callback = function(content)
				if #visibleItems == 0 then
					local empty = params.EmptyText or EMPTY_TEXT
					local emptyWidth = argon:MeasureText(window, empty, metrics.textSize, font)
					local emptyY = content.y + (metrics.itemHeight - textHeight) / 2 + textAscent
					Text({
						x = content.x + math.max(metrics.textPadding, (content.width - emptyWidth) / 2),
						y = emptyY,
						TextSize = metrics.textSize,
						Font = font,
						text = empty,
						Color = colors.disabledText,
						theme = theme,
						engine_window = window,
					}, dt)
					return
				end

				local rowY = content.y

				for index, item in ipairs(visibleItems) do
					if item.separator then
						Rectangle({
							x = content.x + 2,
							y = rowY + math.floor(separatorHeight / 2),
							width = content.width - 8,
							height = 1,
							Color = colors.separator,
							theme = theme,
							engine_window = window,
						}, dt)
						rowY += separatorHeight
						continue
					end

					local rowRect = {
						x = content.x,
						y = rowY,
						width = content.width - 6,
						height = metrics.itemHeight,
					}

					local rowVisible = rowRect.y + rowRect.height >= content.viewportY
						and rowRect.y <= content.viewportY + content.viewportHeight

					if rowVisible then
						local hovered = not suppressInput and isSelectable(item) and containsPoint(renderer, rowRect)
						local keyboardFocused = field.focusedIndex[pathKey] == index and isSelectable(item)
						local highlighted = hovered or keyboardFocused or item.active == true

						if highlighted then
							Rectangle({
								x = rowRect.x,
								y = rowRect.y,
								width = rowRect.width,
								height = rowRect.height,
								Color = item.active and colors.active or colors.hover,
								theme = theme,
								engine_window = window,
							}, dt)
						end

						if hovered then
							field.focusedIndex[pathKey] = index
							if hoverSubmenus then
								if item.children and #item.children > 0 then
									field.openPath[depth] = index
									clearOpenFrom(field.openPath, depth + 1)
								elseif field.openPath[depth] ~= nil then
									clearOpenFrom(field.openPath, depth)
								end
							end
						end

						local textColor = colors.text
						if item.disabled or item.header then
							textColor = colors.disabledText
						elseif item.danger then
							textColor = colors.dangerText
						elseif item.active then
							textColor = colors.activeText
						end

						local textY = rowY + (metrics.itemHeight - textHeight) / 2 + textAscent
						local leftX = content.x + metrics.textPadding
						local textX = leftX

						if anyLeading then
							local marker = item.iconText or ""
							if item.kind == "checkbox" then
								marker = item.checked and "✓" or ""
							elseif item.kind == "radio" then
								marker = item.checked and "●" or ""
							end

							if marker ~= "" then
								Text({
									x = leftX,
									y = textY,
									TextSize = metrics.textSize,
									Font = font,
									text = marker,
									Color = textColor,
									theme = theme,
									engine_window = window,
								}, dt)
							end
							textX += metrics.leadingWidth
						end

						local label = item.text or ""
						Text({
							x = textX,
							y = textY,
							TextSize = metrics.textSize,
							Font = font,
							text = label,
							Color = textColor,
							theme = theme,
							engine_window = window,
						}, dt)

						local mnemonic = mnemonicMap[index]
						if showMnemonics and mnemonicsEnabled and mnemonic then
							local prefix = label:sub(1, mnemonic.position - 1)
							local char = label:sub(mnemonic.position, mnemonic.position)
							local prefixWidth = argon:MeasureText(window, prefix, metrics.textSize, font)
							local charWidth = math.max(2, argon:MeasureText(window, char, metrics.textSize, font))

							Rectangle({
								x = textX + prefixWidth,
								y = textY + 2,
								width = charWidth,
								height = 1,
								Color = textColor,
								theme = theme,
								engine_window = window,
							}, dt)
						end

						local hasChildren = item.children ~= nil and #item.children > 0
						local rightX = content.x + rowRect.width - metrics.textPadding

						if hasChildren then
							local arrow = "›"
							local arrowWidth = argon:MeasureText(window, arrow, metrics.textSize, font)
							Text({
								x = rightX - arrowWidth,
								y = textY,
								TextSize = metrics.textSize,
								Font = font,
								text = arrow,
								Color = item.disabled and colors.disabledText or colors.shortcut,
								theme = theme,
								engine_window = window,
							}, dt)
							rightX -= arrowWidth + 10
						end

						if item.shortcut then
							local shortcutWidth = argon:MeasureText(window, item.shortcut, metrics.textSize, font)
							Text({
								x = rightX - shortcutWidth,
								y = textY,
								TextSize = metrics.textSize,
								Font = font,
								text = item.shortcut,
								Color = colors.shortcut,
								theme = theme,
								engine_window = window,
							}, dt)
						end

						if not suppressInput and isSelectable(item) and renderer:HasClicked(rowRect) then
							field.focusedIndex[pathKey] = index
							if hasChildren then
								field.openPath[depth] = index
								clearOpenFrom(field.openPath, depth + 1)
							else
								activateItem(item)
							end
						end

						if not closed and hasChildren and field.openPath[depth] == index then
							local childSearch = if search ~= "" and not textMatches(item.text, search)
								then search
								else ""
							submenuRequest = {
								item = item,
								rowRect = rowRect,
								search = childSearch,
								index = index,
							}
						end
					end

					rowY += metrics.itemHeight
				end
			end,
		}, dt)

		argon:Restore(window)

		if submenuRequest and not closed then
			local item = submenuRequest.item :: ContextMenuItem
			local children = item.children :: { ContextMenuItem }
			local childWidth = item.submenuWidth or params.SubmenuWidth or params.width
			local childMaxHeight = item.submenuMaxHeight or params.SubmenuMaxHeight or params.MaxHeight
			local childVisibleItems = getVisibleItems(children, submenuRequest.search)
			local childHeight = select(1, computeHeight(childVisibleItems, false, childMaxHeight))
			local preferredX = menuRect.x + menuRect.width - SUBMENU_OVERLAP
			local childX = preferredX

			if clampToWindow and window.Width and preferredX + childWidth > window.Width then
				childX = menuRect.x - childWidth + SUBMENU_OVERLAP
			end

			local childY = submenuRequest.rowRect.y - metrics.padding
			if clampToWindow and window.Height and childY + childHeight > window.Height then
				childY = window.Height - childHeight
			end
			childY = math.max(0, childY)

			renderLevel(
				children,
				childX,
				childY,
				childWidth,
				childMaxHeight,
				depth + 1,
				pathKey .. "/" .. tostring(submenuRequest.index),
				submenuRequest.search,
				false
			)
		end
	end

	local rootItems = getVisibleItems(params.items, loweredSearch)
	local rootHeight = select(1, computeHeight(rootItems, searchEnabled, params.MaxHeight))
	local rootRect = clampMenuRect({
		x = params.x,
		y = params.y,
		width = params.width,
		height = rootHeight,
	}, window, clampToWindow)

	renderLevel(
		params.items,
		rootRect.x,
		rootRect.y,
		rootRect.width,
		params.MaxHeight,
		1,
		"root",
		loweredSearch,
		searchEnabled
	)

	if not suppressInput and not closed and keyboardEnabled then
		local pressed = {}

		local function sampleKey(key: number?)
			if not key then
				return false
			end
			local down = argon:IsKeyDown(key)
			pressed[key] = down and not field.keyDown[key]
			field.keyDown[key] = down
			return pressed[key]
		end

		local keyList = {
			argon.Key.Up,
			argon.Key.Down,
			argon.Key.Left,
			argon.Key.Right,
			argon.Key.Home,
			argon.Key.End,
			argon.Key.Enter,
			argon.Key.Space,
			argon.Key.Escape,
		}

		for _, key in ipairs(keyList) do
			sampleKey(key)
		end

		for code = string.byte("A"), string.byte("Z") do
			local key = argon.Key[string.char(code)]
			if key then
				sampleKey(key)
			end
		end

		local altDown = argon:IsKeyDown(argon.Key.LeftAlt) or argon:IsKeyDown(argon.Key.RightAlt)
		local searchFocused = searchEnabled and field.searchStorage.focusedId == id .. "-search"

		if openingFrame then
			-- Populate key history on the opening frame so the key that opened the menu
			-- cannot immediately trigger a mnemonic or menu action.
		elseif pressed[argon.Key.Escape] then
			closeMenu()
		elseif not searchFocused and #levelInfos > 0 then
			local level = levelInfos[#levelInfos]
			local items = level.items :: { ContextMenuItem }
			local pathKey = level.pathKey :: string
			local depth = level.depth :: number
			local focused = field.focusedIndex[pathKey]

			if focused == nil then
				focused = firstSelectable(items)
				field.focusedIndex[pathKey] = focused
			end

			if pressed[argon.Key.Down] then
				field.focusedIndex[pathKey] = moveSelectable(items, focused, 1)
				clearOpenFrom(field.openPath, depth)
			elseif pressed[argon.Key.Up] then
				field.focusedIndex[pathKey] = moveSelectable(items, focused, -1)
				clearOpenFrom(field.openPath, depth)
			elseif pressed[argon.Key.Home] then
				field.focusedIndex[pathKey] = firstSelectable(items)
				clearOpenFrom(field.openPath, depth)
			elseif pressed[argon.Key.End] then
				field.focusedIndex[pathKey] = lastSelectable(items)
				clearOpenFrom(field.openPath, depth)
			elseif pressed[argon.Key.Left] and depth > 1 then
				clearOpenFrom(field.openPath, depth - 1)
			elseif pressed[argon.Key.Right] or pressed[argon.Key.Enter] or pressed[argon.Key.Space] then
				local currentIndex = field.focusedIndex[pathKey]
				local item = currentIndex and items[currentIndex] or nil

				if item and isSelectable(item) then
					if item.children and #item.children > 0 then
						field.openPath[depth] = currentIndex
						clearOpenFrom(field.openPath, depth + 1)
						local childPath = pathKey .. "/" .. tostring(currentIndex)
						local childSearch = if level.search ~= "" and not textMatches(item.text, level.search)
							then level.search
							else ""
						field.focusedIndex[childPath] = firstSelectable(getVisibleItems(item.children, childSearch))
					elseif pressed[argon.Key.Enter] or pressed[argon.Key.Space] then
						activateItem(item)
					end
				end
			end

			if not closed and mnemonicsEnabled and (not mnemonicRequiresAlt or altDown) then
				for index, mnemonic in pairs(level.mnemonics) do
					local key = argon.Key[string.upper(mnemonic.char)]
					if key and pressed[key] then
						local item = items[index]
						if item and isSelectable(item) then
							field.focusedIndex[pathKey] = index
							if item.children and #item.children > 0 then
								field.openPath[depth] = index
								clearOpenFrom(field.openPath, depth + 1)
							else
								activateItem(item)
							end
						end
						break
					end
				end
			end
		end
	end

	if not suppressInput and not closed and argon:IsMouseButtonPressed(1) then
		local inside = false
		for _, rect in ipairs(drawnRects) do
			if containsPoint(renderer, rect) then
				inside = true
				break
			end
		end

		if not inside then
			closeMenu()
		end
	end
end
