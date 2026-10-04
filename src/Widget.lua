--!strict
-- The exporter window. Builds the UI, follows the Studio theme, and exposes its controls so the
-- plugin script can wire them up.
--
-- Layout: a scrolling body of cards (file, output, offsets, Moon Animator, generated code, tips)
-- above a footer that's always visible, holding the status message and the export buttons.

local Widget = {}
Widget.__index = Widget

local Color = Enum.StudioStyleGuideColor
local Modifier = Enum.StudioStyleGuideModifier

local LABEL_WIDTH = 96
local ROW_HEIGHT = 26
local GAP = 6
local TIPS = {
	"Tip: Animations, VFX, SFX, or anything visual should stay on the client, NEVER on the server.",
	"Tip: Make sure to keep all of your VFX objects in a cleaner module and destroy them when done!",
}

type Painted = {
	Instance: Instance,
	Property: string,
	Color: Enum.StudioStyleGuideColor,
	Modifier: Enum.StudioStyleGuideModifier?,
}

export type Option = { Value: any, Label: string }

local function getTheme()
	return (settings() :: any).Studio.Theme
end

local function apply(entry: Painted)
	(entry.Instance :: any)[entry.Property] = getTheme():GetColor(entry.Color, entry.Modifier)
end

-- A dropdown field. `OnChanged` runs when the user picks a different option.
local Select = {}
Select.__index = Select

function Select:SetOptions(options: { Option })
	self.Options = options
	self:Set(self.Value)
end

function Select:Set(value: any)
	self.Value = value
	local text = ""
	for _, option in self.Options do
		if option.Value == value then
			text = option.Label
		end
	end
	self.Label.Text = text
end

function Widget.new(dock: DockWidgetPluginGui)
	local self = setmetatable({}, Widget) :: any
	self.Painted = {} :: { Painted }
	self.Saves = {}
	self.SelectedSave = nil
	self.StatusKind = "info"
	self.OnSaveSelected = function(_entry: any) end
	self.Buttons = {}
	self.Selects = {}

	dock.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local function paint(inst: Instance, property: string, color: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Painted
		local entry = { Instance = inst, Property = property, Color = color, Modifier = modifier }
		table.insert(self.Painted, entry)
		apply(entry)
		return entry
	end

	-- Hover and press feedback: switches the theme modifier of the given paints.
	local function interactive(gui: GuiButton, entries: { Painted })
		local hovered, pressed = false, false
		local function update()
			local modifier = if pressed then Modifier.Pressed elseif hovered then Modifier.Hover else Modifier.Default
			for _, entry in entries do
				entry.Modifier = modifier
				apply(entry)
			end
		end

		gui.MouseEnter:Connect(function()
			hovered = true
			update()
		end)
		gui.MouseLeave:Connect(function()
			hovered, pressed = false, false
			update()
		end)
		gui.MouseButton1Down:Connect(function()
			pressed = true
			update()
		end)
		gui.MouseButton1Up:Connect(function()
			pressed = false
			update()
		end)
	end

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local function corner(parent: Instance, radius: number)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = parent
	end

	local function stroke(parent: Instance, color: Enum.StudioStyleGuideColor): Painted
		local s = Instance.new("UIStroke")
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		local entry = paint(s, "Color", color)
		s.Parent = parent
		return entry
	end

	local function pad(parent: Instance, top: number, right: number, bottom: number, left: number)
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, top)
		p.PaddingRight = UDim.new(0, right)
		p.PaddingBottom = UDim.new(0, bottom)
		p.PaddingLeft = UDim.new(0, left)
		p.Parent = parent
	end

	local function list(parent: Instance, gap: number, horizontal: boolean?)
		local l = Instance.new("UIListLayout")
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, gap)
		if horizontal then
			l.FillDirection = Enum.FillDirection.Horizontal
			l.VerticalAlignment = Enum.VerticalAlignment.Center
		end
		l.Parent = parent
	end

	local function text(parent: Instance, content: string, color: Enum.StudioStyleGuideColor, size: number?): TextLabel
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.SourceSans
		label.TextSize = size or 14
		label.Text = content
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = true
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.LayoutOrder = nextOrder()
		paint(label, "TextColor3", color)
		label.Parent = parent
		return label
	end

	-- Root: body scrolls, footer stays put, menu layer floats over both.
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	paint(root, "BackgroundColor3", Color.MainBackground)
	self.Root = root

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.ScrollBarThickness = 6
	paint(body, "ScrollBarImageColor3", Color.ScrollBar)
	pad(body, 10, 14, 10, 10)
	list(body, 10)
	body.Parent = root

	local function card(title: string): Frame
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		frame.BorderSizePixel = 0
		frame.LayoutOrder = nextOrder()
		paint(frame, "BackgroundColor3", Color.Titlebar)
		corner(frame, 6)
		stroke(frame, Color.Border)
		pad(frame, 8, 10, 10, 10)
		list(frame, GAP)

		local heading = text(frame, string.upper(title), Color.DimmedText, 12)
		heading.Font = Enum.Font.SourceSansBold

		frame.Parent = body
		return frame
	end

	local function row(parent: Instance, height: number?): Frame
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, height or ROW_HEIGHT)
		frame.LayoutOrder = nextOrder()
		list(frame, GAP, true)
		frame.Parent = parent
		return frame
	end

	local function rowLabel(parent: Instance, content: string, width: UDim?): TextLabel
		local label = text(parent, content, Color.MainText)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Size = UDim2.new(width or UDim.new(0, LABEL_WIDTH), UDim.new(1, 0))
		return label
	end

	local function button(parent: Instance, content: string, width: UDim, primary: boolean?): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(width, UDim.new(1, 0))
		b.Font = if primary then Enum.Font.SourceSansSemibold else Enum.Font.SourceSans
		b.TextSize = 14
		b.Text = content
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.LayoutOrder = nextOrder()
		local background = paint(b, "BackgroundColor3", if primary then Color.DialogMainButton else Color.Button)
		paint(b, "TextColor3", if primary then Color.DialogMainButtonText else Color.ButtonText)
		corner(b, 4)
		local border = stroke(b, if primary then Color.DialogMainButton else Color.ButtonBorder)
		interactive(b, { background, border })
		b.Parent = parent
		return b
	end

	local function input(parent: Instance, placeholder: string, width: UDim): TextBox
		local box = Instance.new("TextBox")
		box.Size = UDim2.new(width, UDim.new(1, 0))
		box.Font = Enum.Font.SourceSans
		box.TextSize = 14
		box.Text = ""
		box.PlaceholderText = placeholder
		box.ClearTextOnFocus = false
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.TextTruncate = Enum.TextTruncate.AtEnd
		box.BorderSizePixel = 0
		box.LayoutOrder = nextOrder()
		paint(box, "BackgroundColor3", Color.InputFieldBackground)
		paint(box, "TextColor3", Color.MainText)
		paint(box, "PlaceholderColor3", Color.DimmedText)
		corner(box, 4)
		pad(box, 0, 8, 0, 8)

		local border = stroke(box, Color.InputFieldBorder)
		box.Focused:Connect(function()
			border.Modifier = Modifier.Selected
			apply(border)
		end)
		box.FocusLost:Connect(function()
			border.Modifier = nil
			apply(border)
		end)

		box.Parent = parent
		return box
	end

	local function dropdown(parent: Instance, width: UDim)
		local field = Instance.new("TextButton")
		field.Size = UDim2.new(width, UDim.new(1, 0))
		field.Text = ""
		field.AutoButtonColor = false
		field.BorderSizePixel = 0
		field.LayoutOrder = nextOrder()
		paint(field, "BackgroundColor3", Color.InputFieldBackground)
		corner(field, 4)
		interactive(field, { stroke(field, Color.InputFieldBorder) })

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(8, 0)
		label.Size = UDim2.new(1, -30, 1, 0)
		label.Font = Enum.Font.SourceSans
		label.TextSize = 14
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		paint(label, "TextColor3", Color.MainText)
		label.Parent = field

		local chevron = Instance.new("TextLabel")
		chevron.BackgroundTransparency = 1
		chevron.AnchorPoint = Vector2.new(1, 0)
		chevron.Position = UDim2.new(1, -8, 0, 0)
		chevron.Size = UDim2.new(0, 14, 1, 0)
		chevron.Font = Enum.Font.SourceSans
		chevron.TextSize = 14
		chevron.Text = "▾"
		paint(chevron, "TextColor3", Color.DimmedText)
		chevron.Parent = field

		field.Parent = parent

		local control = setmetatable({
			Button = field,
			Label = label,
			Options = {} :: { Option },
			Value = nil :: any,
			OnChanged = function(_value: any) end,
		}, Select)

		field.MouseButton1Click:Connect(function()
			self:OpenMenu(control)
		end)

		return control
	end

	local function labeled(parent: Instance, content: string, control: (Frame) -> any): any
		local r = row(parent)
		rowLabel(r, content)
		return control(r)
	end

	local FILL = UDim.new(1, -(LABEL_WIDTH + GAP))

	-- Credit ------------------------------------------------------------------------------
	local credit = text(body, "Created by Games.GG", Color.DimmedText, 13)
	credit.Font = Enum.Font.SourceSansSemibold

	-- Animation file ----------------------------------------------------------------------
	local fileCard = card("Animation file")

	local saveBox = Instance.new("Frame")
	saveBox.Size = UDim2.new(1, 0, 0, 124)
	saveBox.BorderSizePixel = 0
	saveBox.LayoutOrder = nextOrder()
	paint(saveBox, "BackgroundColor3", Color.InputFieldBackground)
	corner(saveBox, 4)
	stroke(saveBox, Color.InputFieldBorder)
	saveBox.Parent = fileCard

	local saveList = Instance.new("ScrollingFrame")
	saveList.Size = UDim2.fromScale(1, 1)
	saveList.BackgroundTransparency = 1
	saveList.BorderSizePixel = 0
	saveList.CanvasSize = UDim2.new()
	saveList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	saveList.ScrollingDirection = Enum.ScrollingDirection.Y
	saveList.ScrollBarThickness = 5
	paint(saveList, "ScrollBarImageColor3", Color.ScrollBar)
	pad(saveList, 3, 3, 3, 3)
	list(saveList, 2)
	saveList.Parent = saveBox
	self.SaveList = saveList

	self.SaveInfo = text(fileCard, "", Color.DimmedText, 13)

	local fileRow = row(fileCard)
	self.Buttons.Refresh = button(fileRow, "Refresh", UDim.new(0, 72))
	self.Buttons.Detect = button(fileRow, "Use file open in Moon", UDim.new(1, -(72 + GAP)))

	-- Output ------------------------------------------------------------------------------
	local outputCard = card("Output")

	self.TableName = labeled(outputCard, "Table name", function(r)
		return input(r, "", FILL)
	end)
	self.Lifetime = labeled(outputCard, "Lifetime", function(r)
		return input(r, "", FILL)
	end)
	self.CueTolerance = labeled(outputCard, "CueTolerance", function(r)
		return input(r, "0.15", FILL)
	end)
	self.Selects.EffectName = labeled(outputCard, "Effect name", function(r)
		return dropdown(r, FILL)
	end)
	self.Selects.KeyFormat = labeled(outputCard, "Cue keys", function(r)
		return dropdown(r, FILL)
	end)
	self.Selects.ExportFps = labeled(outputCard, "Export FPS", function(r)
		return dropdown(r, FILL)
	end)

	-- Offsets -----------------------------------------------------------------------------
	local offsetCard = card("Offsets")

	-- A label with its buttons on one line and the current choice underneath.
	local function picker(content: string): (TextLabel, TextButton, TextButton)
		local top = row(offsetCard)
		rowLabel(top, content, UDim.new(1, -(80 + GAP + 52 + GAP)))
		local useSelection = button(top, "Use selected", UDim.new(0, 80))
		local auto = button(top, "Auto", UDim.new(0, 52))

		local value = Instance.new("TextLabel")
		value.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		value.BorderSizePixel = 0
		value.Font = Enum.Font.SourceSans
		value.TextSize = 14
		value.TextXAlignment = Enum.TextXAlignment.Left
		value.TextTruncate = Enum.TextTruncate.AtEnd
		value.LayoutOrder = nextOrder()
		paint(value, "BackgroundColor3", Color.InputFieldBackground, Modifier.Disabled)
		paint(value, "TextColor3", Color.SubText)
		corner(value, 4)
		stroke(value, Color.InputFieldBorder)
		pad(value, 0, 8, 0, 8)
		value.Parent = offsetCard

		return value, useSelection, auto
	end

	self.OriginLabel, self.Buttons.OriginSelect, self.Buttons.OriginAuto = picker("Relative to")
	self.TargetLabel, self.Buttons.TargetSelect, self.Buttons.TargetAuto = picker("Measured at")

	-- Moon Animator -----------------------------------------------------------------------
	local moonCard = card("Moon Animator")
	self.Selects.Placement = labeled(moonCard, "Export button", function(r)
		return dropdown(r, FILL)
	end)

	-- Generated code ----------------------------------------------------------------------
	local codeCard = card("Generated code")

	local codeBox = Instance.new("Frame")
	codeBox.Size = UDim2.new(1, 0, 0, 220)
	codeBox.BorderSizePixel = 0
	codeBox.LayoutOrder = nextOrder()
	paint(codeBox, "BackgroundColor3", Color.ScriptBackground)
	corner(codeBox, 4)
	stroke(codeBox, Color.Border)
	codeBox.Parent = codeCard

	local codeScroll = Instance.new("ScrollingFrame")
	codeScroll.Size = UDim2.fromScale(1, 1)
	codeScroll.BackgroundTransparency = 1
	codeScroll.BorderSizePixel = 0
	codeScroll.CanvasSize = UDim2.new()
	codeScroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
	codeScroll.ScrollingDirection = Enum.ScrollingDirection.XY
	codeScroll.ScrollBarThickness = 6
	paint(codeScroll, "ScrollBarImageColor3", Color.ScrollBar)
	pad(codeScroll, 6, 6, 6, 8)
	codeScroll.Parent = codeBox

	local preview = Instance.new("TextBox")
	preview.BackgroundTransparency = 1
	preview.AutomaticSize = Enum.AutomaticSize.XY
	preview.Size = UDim2.new()
	preview.Font = Enum.Font.Code
	preview.TextSize = 13
	preview.MultiLine = true
	preview.TextEditable = false
	preview.ClearTextOnFocus = false
	preview.TextXAlignment = Enum.TextXAlignment.Left
	preview.TextYAlignment = Enum.TextYAlignment.Top
	preview.Text = ""
	preview.PlaceholderText = "Export to see the generated module here."
	paint(preview, "TextColor3", Color.ScriptText)
	paint(preview, "PlaceholderColor3", Color.DimmedText)
	preview.Parent = codeScroll
	self.Preview = preview

	-- A block of text with a coloured bar down its left edge.
	local function callout(parent: Instance, content: string, barColor: Enum.StudioStyleGuideColor): (Frame, TextLabel, Painted)
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		frame.LayoutOrder = nextOrder()

		local bar = Instance.new("Frame")
		bar.Size = UDim2.new(0, 3, 1, 0)
		bar.BorderSizePixel = 0
		local barPaint = paint(bar, "BackgroundColor3", barColor)
		corner(bar, 2)
		bar.Parent = frame

		local label = text(frame, content, Color.MainText)
		label.Position = UDim2.fromOffset(12, 0)
		label.Size = UDim2.new(1, -12, 0, 0)

		frame.Parent = parent
		return frame, label, barPaint
	end

	-- Tips --------------------------------------------------------------------------------
	local tipsCard = card("Tips")
	for _, tip in TIPS do
		callout(tipsCard, tip, Color.WarningText)
	end

	-- Footer ------------------------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, 0)
	footer.AutomaticSize = Enum.AutomaticSize.Y
	footer.BorderSizePixel = 0
	paint(footer, "BackgroundColor3", Color.MainBackground)
	pad(footer, 8, 10, 8, 10)
	list(footer, GAP)
	footer.Parent = root

	local divider = Instance.new("Frame")
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.BorderSizePixel = 0
	divider.ZIndex = 2
	paint(divider, "BackgroundColor3", Color.Border)
	divider.Parent = root

	local statusBox, statusLabel, statusBar = callout(footer, "", Color.DimmedText)
	statusBox.Visible = false
	self.StatusBox, self.Status, self.StatusBar = statusBox, statusLabel, statusBar

	local actionRow = row(footer, 30)
	self.Buttons.Export = button(actionRow, "Export cues", UDim.new(1, -(88 + GAP + 80 + GAP)), true)
	self.Buttons.SaveRbxm = button(actionRow, "Save .rbxm", UDim.new(0, 88))
	self.Buttons.Dump = button(actionRow, "Dump save", UDim.new(0, 80))

	text(footer, "Exports read the saved file, so save in Moon Animator (Ctrl+S) first.", Color.DimmedText, 13)

	-- The body fills whatever the footer leaves.
	local function fitBody()
		local height = footer.AbsoluteSize.Y
		body.Size = UDim2.new(1, 0, 1, -height)
		divider.Position = UDim2.new(0, 0, 1, -height)
	end
	footer:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBody)
	fitBody()

	-- Dropdown menus open on a layer above everything; clicking off a menu closes it.
	local layer = Instance.new("Frame")
	layer.Name = "MenuLayer"
	layer.Size = UDim2.fromScale(1, 1)
	layer.BackgroundTransparency = 1
	layer.Visible = false
	layer.ZIndex = 50
	layer.Parent = root
	self.MenuLayer = layer

	local catcher = Instance.new("TextButton")
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundTransparency = 1
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Parent = layer
	catcher.MouseButton1Click:Connect(function()
		self:CloseMenu()
	end)

	body:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:CloseMenu()
	end)
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:CloseMenu()
	end)

	root.Parent = dock

	self.ThemeConnection = (settings() :: any).Studio.ThemeChanged:Connect(function()
		self:Repaint()
	end)

	return self
end

function Widget:OpenMenu(control: any)
	self:CloseMenu()
	self.OpenSelect = control

	local theme = getTheme()
	local root, field = self.Root, control.Button
	local itemHeight = 24
	local height = #control.Options * itemHeight + 8

	local menu = Instance.new("Frame")
	menu.Name = "Menu"
	menu.BorderSizePixel = 0
	menu.ZIndex = 2
	menu.BackgroundColor3 = theme:GetColor(Color.Dropdown)

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = menu

	local s = Instance.new("UIStroke")
	s.Color = theme:GetColor(Color.Border)
	s.Parent = menu

	local p = Instance.new("UIPadding")
	p.PaddingTop, p.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
	p.PaddingLeft, p.PaddingRight = UDim.new(0, 4), UDim.new(0, 4)
	p.Parent = menu

	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = menu

	-- Below the field, or above it if there's no room.
	local x = field.AbsolutePosition.X - root.AbsolutePosition.X
	local y = field.AbsolutePosition.Y - root.AbsolutePosition.Y + field.AbsoluteSize.Y + 2
	if y + height > root.AbsoluteSize.Y then
		y = field.AbsolutePosition.Y - root.AbsolutePosition.Y - height - 2
	end
	menu.Position = UDim2.fromOffset(x, math.max(0, y))
	menu.Size = UDim2.fromOffset(field.AbsoluteSize.X, height)

	for i, option in control.Options do
		local selected = option.Value == control.Value

		local item = Instance.new("TextButton")
		item.Size = UDim2.new(1, 0, 0, itemHeight)
		item.AutoButtonColor = false
		item.BorderSizePixel = 0
		item.LayoutOrder = i
		item.Font = if selected then Enum.Font.SourceSansSemibold else Enum.Font.SourceSans
		item.TextSize = 14
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.TextTruncate = Enum.TextTruncate.AtEnd
		item.Text = option.Label
		item.TextColor3 = theme:GetColor(Color.MainText, if selected then Modifier.Selected else Modifier.Default)
		item.BackgroundColor3 = theme:GetColor(Color.Item, if selected then Modifier.Selected else Modifier.Hover)
		item.BackgroundTransparency = if selected then 0 else 1

		local itemCorner = Instance.new("UICorner")
		itemCorner.CornerRadius = UDim.new(0, 3)
		itemCorner.Parent = item

		local itemPadding = Instance.new("UIPadding")
		itemPadding.PaddingLeft = UDim.new(0, 8)
		itemPadding.PaddingRight = UDim.new(0, 8)
		itemPadding.Parent = item

		if not selected then
			item.MouseEnter:Connect(function()
				item.BackgroundTransparency = 0
			end)
			item.MouseLeave:Connect(function()
				item.BackgroundTransparency = 1
			end)
		end

		item.MouseButton1Click:Connect(function()
			self:CloseMenu()
			if option.Value ~= control.Value then
				control:Set(option.Value)
				control.OnChanged(option.Value)
			end
		end)

		item.Parent = menu
	end

	menu.Parent = self.MenuLayer
	self.MenuLayer.Visible = true
end

function Widget:CloseMenu()
	self.OpenSelect = nil
	local layer = self.MenuLayer
	if layer then
		layer.Visible = false
		local menu = layer:FindFirstChild("Menu")
		if menu then
			menu:Destroy()
		end
	end
end

function Widget:Repaint()
	for _, entry in self.Painted do
		if entry.Instance.Parent then
			apply(entry)
		end
	end
	self:CloseMenu()
	self:SetSaves(self.Saves, self.SelectedSave)
	self:SetStatus(self.Status.Text, self.StatusKind)
end

local function formatTime(timestamp: number?): string
	if not timestamp then
		return ""
	end
	local ok, t = pcall(os.date, "*t", timestamp)
	if not ok or type(t) ~= "table" then
		return ""
	end
	return string.format("%d/%d %02d:%02d", t.month, t.day, t.hour, t.min)
end

function Widget:SetSaves(saves: { any }, selected: any?)
	self.Saves = saves
	self.SelectedSave = selected

	for _, child in self.SaveList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local theme = getTheme()

	if #saves == 0 then
		local empty = Instance.new("TextLabel")
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, 0, 0, 60)
		empty.Font = Enum.Font.SourceSans
		empty.TextSize = 14
		empty.TextWrapped = true
		empty.Text = "No Moon Animator 2 saves in ServerStorage yet.\nSave an animation in Moon, then click Refresh."
		empty.TextColor3 = theme:GetColor(Color.DimmedText)
		empty.Parent = self.SaveList
		return
	end

	for i, entry in saves do
		local isSelected = entry == selected
		local modifier = if isSelected then Modifier.Selected else Modifier.Default

		local rowButton = Instance.new("TextButton")
		rowButton.Size = UDim2.new(1, 0, 0, 24)
		rowButton.BorderSizePixel = 0
		rowButton.AutoButtonColor = false
		rowButton.Text = ""
		rowButton.LayoutOrder = i
		rowButton.BackgroundColor3 = theme:GetColor(Color.Item, if isSelected then Modifier.Selected else Modifier.Hover)
		rowButton.BackgroundTransparency = if isSelected then 0 else 1

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 3)
		rowCorner.Parent = rowButton

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(8, 0)
		name.Size = UDim2.new(1, -100, 1, 0)
		name.Font = if isSelected then Enum.Font.SourceSansSemibold else Enum.Font.SourceSans
		name.TextSize = 14
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = entry.Name
		name.TextColor3 = theme:GetColor(Color.MainText, modifier)
		name.Parent = rowButton

		local time = Instance.new("TextLabel")
		time.BackgroundTransparency = 1
		time.AnchorPoint = Vector2.new(1, 0)
		time.Position = UDim2.new(1, -8, 0, 0)
		time.Size = UDim2.new(0, 84, 1, 0)
		time.Font = Enum.Font.SourceSans
		time.TextSize = 13
		time.TextXAlignment = Enum.TextXAlignment.Right
		time.Text = formatTime(entry.Modified)
		time.TextColor3 = theme:GetColor(Color.DimmedText, modifier)
		time.Parent = rowButton

		if not isSelected then
			rowButton.MouseEnter:Connect(function()
				rowButton.BackgroundTransparency = 0
			end)
			rowButton.MouseLeave:Connect(function()
				rowButton.BackgroundTransparency = 1
			end)
		end

		rowButton.MouseButton1Click:Connect(function()
			self.OnSaveSelected(entry)
		end)

		rowButton.Parent = self.SaveList
	end
end

local STATUS_BARS = {
	info = Color.DimmedText,
	ok = Color.DialogMainButton,
	warn = Color.WarningText,
	error = Color.ErrorText,
}

function Widget:SetStatus(message: string, kind: string?)
	self.StatusKind = kind or "info"
	self.Status.Text = message
	self.StatusBox.Visible = message ~= ""
	self.StatusBar.Color = STATUS_BARS[self.StatusKind] or Color.DimmedText
	apply(self.StatusBar)
end

function Widget:SetPreview(source: string)
	-- TextBoxes don't render tabs.
	self.Preview.Text = (string.gsub(source, "\t", "    "))
end

function Widget:Destroy()
	self.ThemeConnection:Disconnect()
end

return Widget
