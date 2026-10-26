--!strict
-- Hooks into a running Eclipse Animator through the windows it puts in CoreGui:
--   * puts an "Export VFX" row at the bottom of Eclipse's ITEM menu
--   * works out which project Eclipse has open, from the name in its project box
-- Eclipse's internals are undocumented, so every access here is defensive and fails quietly.

local EclipseHook = {}
EclipseHook.__index = EclipseHook

local ROW_NAME = "MoonVFXExporterRow"
local LABEL = "Export VFX"
-- Eclipse's own export icon.
local ICON = "rbxassetid://136636358423324"
-- How Eclipse colours its menu rows: hovered, and pressed.
local HOVER = Color3.fromRGB(34, 0, 52)
local PRESS = Color3.fromRGB(100, 0, 151)
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
-- The name Eclipse shows for a project that hasn't been named.
local UNNAMED = "Eclipse Animation"

-- Eclipse's main windows: the ScreenGuis it puts in CoreGui, each tagged with its session.
function EclipseHook.findGuis(): { ScreenGui }
	local found = {}
	local ok, children = pcall(function()
		return game:GetService("CoreGui"):GetChildren()
	end)
	for _, gui in if ok then children else {} do
		if gui:IsA("ScreenGui") and gui:GetAttribute("EclipseInstance") ~= nil and string.find(gui.Name, "^Eclipse Animator") then
			table.insert(found, gui)
		end
	end
	-- The one showing first.
	table.sort(found, function(a, b)
		return a.Enabled and not b.Enabled
	end)
	return found
end

-- Whether Eclipse is running with its window showing.
function EclipseHook.isShowing(): boolean
	local gui = EclipseHook.findGuis()[1]
	return gui ~= nil and gui.Enabled
end

-- The ITEM menu in one of Eclipse's windows, and the frame its rows are in. Eclipse builds its
-- menus once, the first time its animator opens.
local function itemMenu(gui: Instance): (GuiObject?, Instance?)
	local menus = gui:FindFirstChild("MenuBarDropdowns")
	local menu = menus and menus:FindFirstChild("MenuItem")
	local content = menu and menu:FindFirstChild("Content")
	if menu and menu:IsA("GuiObject") and content then
		return menu, content
	end
	return nil, nil
end

-- The box Eclipse shows the open project's name in.
local function projectBox(gui: Instance): TextBox?
	for _, item in gui:GetDescendants() do
		if item.Name == "Edit" and item:IsA("TextBox") and item.Parent and item.Parent.Name == "ProjectName" then
			return item
		end
	end
	return nil
end

-- The name of the project Eclipse has open (in `gui`, or the window showing), or nil if it has
-- none or it hasn't been named.
function EclipseHook.openProjectName(gui: Instance?): string?
	local window = gui or EclipseHook.findGuis()[1]
	local box = if window then projectBox(window) else nil
	if not box then
		return nil
	end
	for _, text in { box.Text, box.PlaceholderText } do
		local name = string.match(text, "^%s*(.-)%s*$")
		if name and name ~= "" and name ~= UNNAMED then
			return name
		end
	end
	return nil
end

-- Sets a look the way Eclipse does, easing into it when it can.
local function fade(target: Instance, properties: { [string]: any })
	local ok = pcall(function()
		local TweenService = game:GetService("TweenService")
		TweenService:Create(target, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties):Play()
	end)
	if not ok then
		for name, value in properties do
			pcall(function()
				(target :: any)[name] = value
			end)
		end
	end
end

-- An "Export VFX" row for the ITEM menu: a copy of one of Eclipse's own plain rows, so it looks like
-- the others, relabelled, lit up as Eclipse lights its rows, and closing the menu when it's picked.
local function makeRow(menu: GuiObject, content: Instance, onClick: () -> ()): Instance?
	local source = content:FindFirstChild("AddFolder") or content:FindFirstChild("AddCamera") or content:FindFirstChild("DeleteItem")
	if not (source and source:IsA("GuiObject")) then
		return nil
	end
	local archivable = source.Archivable
	source.Archivable = true
	local ok, copy = pcall(source.Clone, source)
	source.Archivable = archivable
	local row = if ok then copy :: GuiObject? else nil
	if not row then
		return nil
	end
	local button = row:FindFirstChildWhichIsA("GuiButton")
	if not button then
		row:Destroy()
		return nil
	end

	row.Name = ROW_NAME
	local order = 0
	for _, child in content:GetChildren() do
		if child:IsA("GuiObject") then
			order = math.max(order, child.LayoutOrder)
		end
	end
	row.LayoutOrder = order + 1
	button.Name = ROW_NAME .. "Button"
	local title = button:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = LABEL
	end
	local icon = button:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.Image = ICON
		icon.Visible = true
		-- What Eclipse draws in place of its own icon while that loads.
		for _, drawing in icon:GetChildren() do
			if drawing:GetAttribute("EclipseRasterFallback") then
				drawing:Destroy()
			end
		end
	end
	for _, name in { "Keybind", "Check" } do
		local part = button:FindFirstChild(name)
		if part and part:IsA("GuiObject") then
			part.Visible = false
		end
	end
	local arrow = button:FindFirstChild("Arrow")
	if arrow then
		arrow:Destroy()
	end

	local halftone = button:FindFirstChild("Halftone")
	local function look(color: Color3, transparency: number, shade: number, shadeColor: Color3)
		if button.BackgroundTransparency >= 0.99 then
			button.BackgroundColor3 = color
		end
		fade(button, { BackgroundColor3 = color, BackgroundTransparency = transparency })
		if halftone and halftone:IsA("ImageLabel") then
			fade(halftone, { ImageTransparency = shade, ImageColor3 = shadeColor })
		end
	end
	-- The Effects menu that opens beside Add Effects closes when another row is hovered.
	local function closeEffects()
		local effects = menu.Parent and menu.Parent:FindFirstChild("MenuEffects")
		if effects and effects:IsA("GuiObject") then
			effects.Visible = false
		end
	end

	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	if halftone and halftone:IsA("ImageLabel") then
		halftone.ImageTransparency = 1
	end
	button.MouseEnter:Connect(function()
		closeEffects()
		look(HOVER, 0, 0.8, WHITE)
	end)
	button.MouseLeave:Connect(function()
		look(HOVER, 1, 1, WHITE)
	end)
	button.MouseButton1Down:Connect(function()
		look(PRESS, 0, 0.4, BLACK)
	end)
	button.MouseButton1Click:Connect(function()
		look(HOVER, 1, 1, WHITE)
		-- Picking a row closes Eclipse's menus.
		menu.Visible = false
		closeEffects()
		task.spawn(onClick)
	end)

	row.Parent = content
	return row
end

-- Keeps an Export VFX row in each Eclipse window's ITEM menu. `onClick` gets the name of the
-- project open in that window (nil if it has none).
function EclipseHook.new(onClick: (projectName: string?) -> ())
	local self = setmetatable({
		OnClick = onClick,
		Alive = true,
		-- Each window's row, made by this session.
		Rows = {} :: { [Instance]: Instance },
	}, EclipseHook)

	task.spawn(function()
		while self.Alive do
			pcall(self.Refresh, self)
			task.wait(1.5)
		end
	end)

	return self
end

function EclipseHook:Refresh()
	for _, gui in EclipseHook.findGuis() do
		local menu, content = itemMenu(gui)
		if not (menu and content) then
			continue
		end
		local mine = self.Rows[gui]
		if mine and mine.Parent == content then
			continue
		end
		-- Rows left over from an earlier session of this plugin no longer do anything.
		for _, child in content:GetChildren() do
			if child.Name == ROW_NAME then
				child:Destroy()
			end
		end
		self.Rows[gui] = makeRow(menu, content, function()
			self.OnClick(EclipseHook.openProjectName(gui))
		end)
	end
end

function EclipseHook:Destroy()
	self.Alive = false
	for _, row in self.Rows do
		row:Destroy()
	end
	table.clear(self.Rows)
end

return EclipseHook
