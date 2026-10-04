--!strict
-- Hooks into a running Moon Animator 2 through the global it publishes (_G.MoonGlobal):
--   * puts an "Export VFX" button next to Moon's Options button
--   * works out which save file Moon has open
--   * exposes Moon's easing functions so sampled keyframes match the timeline exactly
-- Moon's internals are undocumented, so every access here is defensive and fails quietly.

local MoonHook = {}
MoonHook.__index = MoonHook

local BUTTON_NAME = "MoonVFXExporterButton"
local LABEL = "Export VFX"
local GAP = 4

-- "Auto" = beside Moon's Options button.
export type Placement = "Auto" | "TopRight" | "TopLeft" | "BottomRight" | "BottomLeft" | "Hidden"

local CORNERS = {
	TopRight = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -6, 0, 4) },
	TopLeft = { anchor = Vector2.new(0, 0), position = UDim2.new(0, 6, 0, 4) },
	BottomRight = { anchor = Vector2.new(1, 1), position = UDim2.new(1, -6, 1, -4) },
	BottomLeft = { anchor = Vector2.new(0, 1), position = UDim2.new(0, 6, 1, -4) },
}

function MoonHook.getGlobal(): { [string]: any }?
	local ok, g = pcall(function()
		return (_G :: any).MoonGlobal
	end)
	if ok and type(g) == "table" then
		return g
	end
	return nil
end

function MoonHook.isRunning(): boolean
	local g = MoonHook.getGlobal()
	return g ~= nil and g.ready == true
end

function MoonHook.getEasingFunctions(): { [string]: any }?
	local g = MoonHook.getGlobal()
	local ok, funcs = pcall(function()
		return g and g.EasingFunctions
	end)
	if ok and type(funcs) == "table" then
		return funcs
	end
	return nil
end

function MoonHook.getMainUi(): GuiObject?
	local g = MoonHook.getGlobal()
	if not (g and g.ready) then
		return nil
	end

	local ok, ui = pcall(function()
		return g.Windows.MoonAnimator.UI
	end)
	if ok and typeof(ui) == "Instance" and ui:IsA("GuiObject") then
		return ui
	end
	return nil
end

-- Walks Moon's object graph looking for references to save StringValues. The file Moon has
-- open is held by its timeline, so it usually turns up more often than any other save.
local function countSaveReferences(root: { [any]: any }, lookup: { [Instance]: boolean }): { [Instance]: number }
	local hits = {}
	local seen = { [root] = true }
	local queue = { root }
	local head = 1

	local function visit(v: any)
		if typeof(v) == "Instance" then
			if lookup[v] then
				hits[v] = (hits[v] or 0) + 1
			end
		elseif type(v) == "table" and not seen[v] then
			seen[v] = true
			table.insert(queue, v)
		end
	end

	while head <= #queue and head <= 60000 do
		local current = queue[head]
		head += 1

		pcall(function()
			for key, value in pairs(current) do
				visit(key)
				visit(value)
			end
		end)
	end

	return hits
end

local function mainWindowTexts(): { string }
	local texts = {}
	local ui = MoonHook.getMainUi()
	if not ui then
		return texts
	end

	local widget = ui:FindFirstAncestorWhichIsA("PluginGui")
	if widget then
		table.insert(texts, widget.Title)
	end

	for _, desc in ui:GetDescendants() do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
			if desc.Text ~= "" and (desc :: GuiObject).Visible then
				table.insert(texts, desc.Text)
			end
		end
	end

	return texts
end

-- Picks the save Moon Animator currently has open; `saves` is sorted newest first.
-- Returns the entry and how it was chosen.
function MoonHook.detectOpenSave(saves: { any }): (any, string)
	if #saves == 0 then
		return nil, "no saves"
	end

	local g = MoonHook.getGlobal()
	if not g then
		return saves[1], "most recently saved"
	end

	local lookup = {}
	for _, entry in saves do
		lookup[entry.Save] = true
	end

	local hits = countSaveReferences(g, lookup)
	local referenced = {}
	local best, bestCount, tied = nil, 0, false
	for _, entry in saves do
		local count = hits[entry.Save] or 0
		if count > 0 then
			table.insert(referenced, entry)
		end
		if count > bestCount then
			best, bestCount, tied = entry, count, false
		elseif count == bestCount and count > 0 then
			tied = true
		end
	end

	if #referenced == 1 then
		return referenced[1], "open in Moon Animator"
	end

	-- Several saves referenced (e.g. the file browser is open), or none: look for the file name
	-- on Moon's main window.
	local candidates = if #referenced > 0 then referenced else saves
	local texts = mainWindowTexts()
	local partial, partialLength = nil, 0
	for _, entry in candidates do
		for _, text in texts do
			if text == entry.Name then
				return entry, "open in Moon Animator"
			elseif #entry.Name > partialLength and string.find(text, entry.Name, 1, true) then
				partial, partialLength = entry, #entry.Name
			end
		end
	end

	if best and not tied then
		return best, "open in Moon Animator"
	elseif partial then
		return partial, "open in Moon Animator"
	end

	return candidates[1], "most recently saved"
end

-- Export button ------------------------------------------------------------------------------
--
-- In "Auto" placement the button is a copy of Moon's own Options button, relabelled and slotted in
-- right beside it, so it picks up Moon's font, size, colours and corners. If Options can't be
-- found it copies the File menu item and goes at the end of the menu bar, and failing that it sits
-- in a corner of the window.

local function isText(inst: Instance): boolean
	return inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")
end

local function cleanText(s: string): string
	return string.lower((string.gsub(s, "^%s*(.-)%s*$", "%1")))
end

local function isShown(inst: Instance): boolean
	local node: Instance? = inst
	while node and node:IsA("GuiObject") do
		if not (node :: GuiObject).Visible then
			return false
		end
		node = node.Parent
	end
	return true
end

local function isOurs(inst: Instance): boolean
	return inst.Name == BUTTON_NAME or inst:FindFirstAncestor(BUTTON_NAME) ~= nil
end

local function guiChildren(parent: Instance): { GuiObject }
	local list = {}
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") and not isOurs(child) then
			table.insert(list, child)
		end
	end
	return list
end

-- A text match is usually a label inside the real button, maybe inside a wrapper frame. Climb to
-- the element that sits in the bar alongside its neighbours.
local function itemFor(found: GuiObject, root: Instance): GuiObject
	local item = found
	local parent = item.Parent
	if parent and parent ~= root and parent:IsA("GuiButton") then
		item = parent :: GuiObject
	elseif parent and parent ~= root and parent.Parent and parent.Parent ~= root and parent.Parent:IsA("GuiButton") then
		item = parent.Parent :: GuiObject
	end

	while true do
		local wrapper = item.Parent
		if not (wrapper and wrapper ~= root and wrapper:IsA("GuiObject")) then
			break
		end
		if #guiChildren(wrapper) ~= 1 or (wrapper :: GuiObject).AbsoluteSize.X > item.AbsoluteSize.X + 24 then
			break
		end
		item = wrapper :: GuiObject
	end

	return item
end

-- The visible element that best matches, preferring the top-most.
local function findItem(root: Instance, score: (text: string, name: string) -> number): GuiObject?
	local best, bestScore, bestY = nil, 0, math.huge
	for _, desc in root:GetDescendants() do
		if not desc:IsA("GuiObject") or isOurs(desc) then
			continue
		end

		local text = if isText(desc) then cleanText((desc :: any).Text) else ""
		local points = score(text, string.lower(desc.Name))
		if points > 0 and desc.AbsoluteSize.X > 0 and isShown(desc) then
			local y = desc.AbsolutePosition.Y
			if points > bestScore or (points == bestScore and y < bestY) then
				best, bestScore, bestY = desc, points, y
			end
		end
	end

	return if best then itemFor(best, root) else nil
end

local function scoreOptions(text: string, name: string): number
	if text == "options" then
		return 3
	elseif string.sub(text, 1, 6) == "option" then
		return 2
	elseif string.find(name, "option", 1, true) then
		return 1
	end
	return 0
end

local function scoreFile(text: string): number
	return if text == "file" then 1 else 0
end

-- The right-most item on the same row as `item`.
local function lastInRow(item: GuiObject): GuiObject
	local last = item
	for _, sibling in guiChildren(item.Parent :: Instance) do
		local sameRow = math.abs(sibling.AbsolutePosition.Y - item.AbsolutePosition.Y) < item.AbsoluteSize.Y
		if sameRow and isShown(sibling) and sibling.AbsolutePosition.X > last.AbsolutePosition.X then
			last = sibling
		end
	end
	return last
end

local function primaryText(root: Instance): GuiObject?
	if isText(root) and (root :: any).Text ~= "" then
		return root :: GuiObject
	end
	for _, desc in root:GetDescendants() do
		if isText(desc) and (desc :: any).Text ~= "" then
			return desc :: GuiObject
		end
	end
	return nil
end

local function textWidth(label: any, text: string): number
	local ok, size = pcall(function()
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = label.FontFace
		params.Size = label.TextSize
		params.Width = 100000
		return game:GetService("TextService"):GetTextBoundsAsync(params)
	end)
	if ok and typeof(size) == "Vector2" then
		return size.X
	end
	return #text * label.TextSize * 0.55
end

-- Copies Moon's item and relabels it. Fixed-width parts grow to fit the longer label.
local function cloneItem(source: GuiObject): GuiObject?
	if not primaryText(source) then
		return nil
	end

	local button = source:Clone()
	button.Name = BUTTON_NAME
	local label = primaryText(button) :: any

	local delta = 0
	if not label.TextScaled then
		delta = math.ceil(textWidth(label, LABEL) - textWidth(label, label.Text))
	end
	label.Text = LABEL

	if delta ~= 0 then
		local node: Instance? = label
		while node do
			if node:IsA("GuiObject") then
				local auto = node.AutomaticSize
				if node.Size.X.Scale == 0 and auto ~= Enum.AutomaticSize.X and auto ~= Enum.AutomaticSize.XY then
					node.Size += UDim2.fromOffset(delta, 0)
				end
			end
			if node == button then
				break
			end
			node = node.Parent
		end
	end

	-- Hide the original's icons (a dropdown arrow, say) but keep full-size background images.
	for _, desc in button:GetDescendants() do
		if (desc:IsA("ImageLabel") or desc:IsA("ImageButton")) and desc.Size.X.Scale < 0.9 then
			desc.Visible = false
		end
	end

	return button
end

-- A plain button with exact, centred text, styled after `textStyle` when there is one.
local function plainButton(textStyle: GuiObject?, background: GuiObject?, height: number): TextButton
	local styleLabel = if textStyle then primaryText(textStyle) :: any else nil

	local button = Instance.new("TextButton")
	button.Name = BUTTON_NAME
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.FontFace = if styleLabel then styleLabel.FontFace else Font.fromEnum(Enum.Font.SourceSansSemibold)
	button.TextSize = if styleLabel then styleLabel.TextSize else 14
	button.TextColor3 = if styleLabel then styleLabel.TextColor3 else Color3.fromRGB(230, 230, 230)
	button.TextXAlignment = Enum.TextXAlignment.Center
	button.TextYAlignment = Enum.TextYAlignment.Center
	button.Text = LABEL
	button.Size = UDim2.fromOffset(math.ceil(textWidth(button, LABEL)) + 16, height)

	if background then
		button.BackgroundColor3 = background.BackgroundColor3
		button.BackgroundTransparency = background.BackgroundTransparency
		button.ZIndex = background.ZIndex
		local corner = background:FindFirstChildWhichIsA("UICorner")
		if corner then
			corner:Clone().Parent = button
		end
	else
		button.BackgroundColor3 = Color3.fromRGB(32, 32, 36)
		button.BackgroundTransparency = 0.15
		button.ZIndex = 1000

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = button.TextColor3
		stroke.Transparency = 0.65
		stroke.Parent = button
	end

	return button
end

-- Click handling plus a subtle hover highlight in the button's own text colour.
local function makeClickable(button: GuiObject, onClick: () -> ())
	local label = primaryText(button) :: any
	local tint = if label then label.TextColor3 else Color3.new(1, 1, 1)

	if button:FindFirstChildWhichIsA("UIGridStyleLayout") then
		-- A layout would rearrange an overlay, so listen on the item itself.
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				onClick()
			end
		end)
		return
	end

	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BorderSizePixel = 0
	hit.BackgroundColor3 = tint
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)

	local z = button.ZIndex
	for _, desc in button:GetDescendants() do
		if desc:IsA("GuiObject") then
			z = math.max(z, desc.ZIndex)
		end
	end
	hit.ZIndex = z + 1

	local corner = button:FindFirstChildWhichIsA("UICorner")
	if corner then
		corner:Clone().Parent = hit
	end

	hit.MouseEnter:Connect(function()
		hit.BackgroundTransparency = 0.88
	end)
	hit.MouseLeave:Connect(function()
		hit.BackgroundTransparency = 1
	end)
	hit.Activated:Connect(onClick)
	hit.Parent = button
end

local function overlapsSibling(parent: Instance, x: number, y: number, w: number, h: number): boolean
	for _, sibling in guiChildren(parent) do
		if isShown(sibling) then
			local p, s = sibling.AbsolutePosition, sibling.AbsoluteSize
			if x < p.X + s.X and p.X < x + w and y < p.Y + s.Y and p.Y < y + h then
				return true
			end
		end
	end
	return false
end

-- Puts `button` immediately after `anchor` in the same bar.
local function placeAfter(button: GuiObject, anchor: GuiObject)
	local parent = anchor.Parent :: GuiObject
	if button.Parent ~= parent then
		button.Parent = parent
	end

	local layout = parent:FindFirstChildWhichIsA("UIGridStyleLayout")
	if layout then
		-- Moon lays the bar out with a list: take the slot after the anchor.
		local siblings = guiChildren(parent)
		local clash = false
		for _, sibling in siblings do
			if sibling.LayoutOrder == button.LayoutOrder then
				clash = true
			end
		end

		if clash or button.LayoutOrder ~= anchor.LayoutOrder + 1 then
			local horizontal = layout:IsA("UIListLayout") and layout.FillDirection == Enum.FillDirection.Horizontal
			table.sort(siblings, function(a, b)
				if a.LayoutOrder ~= b.LayoutOrder then
					return a.LayoutOrder < b.LayoutOrder
				end
				local pa, pb = a.AbsolutePosition, b.AbsolutePosition
				if horizontal or pa.Y == pb.Y then
					return pa.X < pb.X
				end
				return pa.Y < pb.Y
			end)

			for i, sibling in siblings do
				sibling.LayoutOrder = i * 2
				if sibling == anchor then
					button.LayoutOrder = i * 2 + 1
				end
			end
		end
		return
	end

	-- Absolutely positioned bar: go right of the anchor, or left if that's off the edge or taken.
	local width = if button.AbsoluteSize.X > 0 then button.AbsoluteSize.X else button.Size.X.Offset
	local ap, as = anchor.AbsolutePosition, anchor.AbsoluteSize
	local pp, ps = parent.AbsolutePosition, parent.AbsoluteSize
	local leftEdge = anchor.Position - UDim2.fromOffset(as.X * anchor.AnchorPoint.X, 0)

	local rightX, leftX = ap.X + as.X + GAP, ap.X - GAP - width
	local rightOk = rightX + width <= pp.X + ps.X and not overlapsSibling(parent, rightX, ap.Y, width, as.Y)
	local leftOk = leftX >= pp.X and not overlapsSibling(parent, leftX, ap.Y, width, as.Y)
	local goLeft = if anchor.AnchorPoint.X >= 0.5 then leftOk or not rightOk else not rightOk and leftOk

	if goLeft then
		button.AnchorPoint = Vector2.new(1, anchor.AnchorPoint.Y)
		button.Position = leftEdge - UDim2.fromOffset(GAP, 0)
	else
		button.AnchorPoint = Vector2.new(0, anchor.AnchorPoint.Y)
		button.Position = leftEdge + UDim2.fromOffset(as.X + GAP, 0)
	end
end

-- Changes whenever Moon's theme does, so the copy can be rebuilt in the new colours.
local function themeSignature(): string
	local parts = {}
	pcall(function()
		local g = MoonHook.getGlobal() :: any
		for key, value in pairs(g.Themer._Theme) do
			if typeof(value) == "Color3" then
				table.insert(parts, `{key}={value}`)
			end
		end
	end)
	table.sort(parts)
	return table.concat(parts, ";")
end

function MoonHook.new(onClick: () -> ())
	local self = setmetatable({
		Placement = "Auto" :: Placement,
		OnClick = onClick,
		Alive = true,
		Button = nil :: GuiObject?,
		Mode = nil :: string?,
		Signature = nil :: string?,
		Style = nil :: GuiObject?,
		Anchor = nil :: GuiObject?,
		NextSearch = 0,
		Reported = false,
		Watchers = {} :: { RBXScriptConnection },
		SyncLook = nil :: (() -> ())?,
	}, MoonHook)

	task.spawn(function()
		while self.Alive do
			pcall(self.Refresh, self)
			task.wait(1.5)
		end
	end)

	return self
end

function MoonHook:ClearButton()
	self:Unwatch()
	if self.Button then
		self.Button:Destroy()
	end
	self.Button = nil
	self.Mode = nil
	self.Signature = nil
end

function MoonHook:Unwatch()
	for _, connection in self.Watchers do
		connection:Disconnect()
	end
	table.clear(self.Watchers)
	self.SyncLook = nil
end

-- Keeps the copy's text looking like Moon's live Options button. A copy taken while Moon's menus
-- were still disabled would stay grey, and Moon greys out menu items it doesn't recognise, so the
-- colour is re-applied whenever either label changes. While Options itself is hovered its colour
-- is left alone, so the copy doesn't pick up Moon's hover highlight.
function MoonHook:WatchLook(style: GuiObject, button: GuiObject)
	self:Unwatch()

	local source = primaryText(style) :: any
	local label = primaryText(button) :: any
	if not (source and label and source ~= label) then
		return
	end

	local sourceHovered = false
	local function sync()
		if sourceHovered then
			return
		end
		if label.TextColor3 ~= source.TextColor3 then
			label.TextColor3 = source.TextColor3
		end
		if label.TextTransparency ~= source.TextTransparency then
			label.TextTransparency = source.TextTransparency
		end
	end

	local watchers = self.Watchers
	table.insert(watchers, style.MouseEnter:Connect(function()
		sourceHovered = true
	end))
	table.insert(watchers, style.MouseLeave:Connect(function()
		sourceHovered = false
		task.defer(sync) -- after Moon has restored Options' normal colour
	end))
	for _, property in { "TextColor3", "TextTransparency" } do
		table.insert(watchers, source:GetPropertyChangedSignal(property):Connect(sync))
		table.insert(watchers, label:GetPropertyChangedSignal(property):Connect(sync))
	end

	self.SyncLook = sync
	sync()
end

-- Logs what's on Moon's top bar once, so a missed Options button can be tracked down.
function MoonHook:Report(ui: GuiObject, fellBackTo: string)
	if self.Reported then
		return
	end
	self.Reported = true

	local found = {}
	local top = ui.AbsolutePosition.Y
	for _, desc in ui:GetDescendants() do
		if desc:IsA("GuiObject") and not isOurs(desc) and (isText(desc) or desc:IsA("GuiButton")) then
			if desc.AbsolutePosition.Y - top < 40 and isShown(desc) then
				local text = if isText(desc) then (desc :: any).Text else ""
				table.insert(found, string.format("%s %q %q", desc.ClassName, desc.Name, text))
				if #found >= 25 then
					break
				end
			end
		end
	end

	print(
		`[Moon VFX Exporter] Couldn't find Moon's Options button, so Export VFX went {fellBackTo}. `
			.. `Moon's top bar: {table.concat(found, ", ")}`
	)
end

function MoonHook:FindAnchor(ui: GuiObject, scope: Instance)
	local roots = if scope ~= ui then { ui, scope } else { ui }

	for _, root in roots do
		local options = findItem(root, scoreOptions)
		if options then
			self.Style, self.Anchor = options, options
			return
		end
	end

	for _, root in roots do
		local file = findItem(root, scoreFile)
		if file then
			self.Style, self.Anchor = file, lastInRow(file)
			self:Report(ui, "at the end of the menu bar")
			return
		end
	end

	self.Style, self.Anchor = nil, nil
	self:Report(ui, "in the corner of the window")
end

function MoonHook:Refresh()
	local ui = if self.Placement ~= "Hidden" then MoonHook.getMainUi() else nil
	if not ui then
		self:ClearButton()
		return
	end

	local scope = ui:FindFirstAncestorWhichIsA("LayerCollector") or ui

	-- Copies left over from an earlier session of this plugin.
	if not self.Button then
		local stale = scope:FindFirstChild(BUTTON_NAME, true)
		while stale do
			stale:Destroy()
			stale = scope:FindFirstChild(BUTTON_NAME, true)
		end
	end

	if self.Placement == "Auto" then
		local valid = self.Style ~= nil
			and self.Anchor ~= nil
			and self.Style:IsDescendantOf(scope)
			and self.Anchor:IsDescendantOf(scope)

		if not valid and os.clock() >= self.NextSearch then
			self.NextSearch = os.clock() + 4
			self:FindAnchor(ui, scope)
			valid = self.Style ~= nil
		end

		if valid then
			local style, anchor = self.Style :: GuiObject, self.Anchor :: GuiObject
			local signature = themeSignature()
			local stale = not self.Button or self.Button.Parent ~= anchor.Parent or signature ~= self.Signature
			if self.Mode ~= "Auto" or stale then
				self:ClearButton()
				local button = cloneItem(style) or plainButton(style.Parent :: GuiObject, style, style.AbsoluteSize.Y)
				makeClickable(button, self.OnClick)
				self.Button, self.Mode, self.Signature = button, "Auto", signature
				self:WatchLook(style, button)
			end

			local button = self.Button :: GuiObject
			placeAfter(button, anchor)
			button.Visible = isShown(anchor)
			if self.SyncLook then
				self.SyncLook()
			end
			return
		end
	end

	-- A corner of the window.
	local corner = CORNERS[self.Placement] or CORNERS.TopRight
	local container: Instance = if ui:FindFirstChildWhichIsA("UIGridStyleLayout") then scope else ui
	if self.Mode ~= "Corner" or not self.Button or self.Button.Parent ~= container then
		self:ClearButton()
		local button = plainButton(findItem(ui, scoreFile), nil, 20)
		makeClickable(button, self.OnClick)
		button.Parent = container
		self.Button, self.Mode = button, "Corner"
	end

	local button = self.Button :: GuiObject
	button.Visible = true
	button.AnchorPoint = corner.anchor
	button.Position = corner.position
end

function MoonHook:SetPlacement(placement: Placement)
	if placement ~= self.Placement then
		self.Placement = placement
		self.NextSearch = 0
		self:ClearButton()
	end
	pcall(self.Refresh, self)
end

function MoonHook:Destroy()
	self.Alive = false
	self:ClearButton()
end

return MoonHook
