-- Minimal stand-ins for the Roblox types the plugin's pure modules touch.

local builtinTypeof = typeof

-- The CLI's real _G is read-only; plugins share a writable one in Studio.
local _G = {}

local Vector3MT = {}
local CFrameMT = {}
local InstanceMT = {}
local UDim2MT = {}
local Vector2MT = {}
local Color3MT = {}
local ColorSequenceMT = {}
local NumberSequenceMT = {}
local FontMT = {}

local function typeof(value: any): string
	local mt = getmetatable(value)
	if mt == Vector3MT then
		return "Vector3"
	elseif mt == CFrameMT then
		return "CFrame"
	elseif mt == InstanceMT then
		return "Instance"
	elseif mt == UDim2MT then
		return "UDim2"
	elseif mt == Vector2MT then
		return "Vector2"
	elseif mt == Color3MT then
		return "Color3"
	elseif mt == ColorSequenceMT then
		return "ColorSequence"
	elseif mt == NumberSequenceMT then
		return "NumberSequence"
	elseif mt == FontMT then
		return "Font"
	end
	return builtinTypeof(value)
end

local Color3 = {}
Color3MT.__index = Color3
Color3MT.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
function Color3.new(r: number?, g: number?, b: number?)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3MT)
end
function Color3.Lerp(a, b, t)
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
function Color3.fromRGB(r: number, g: number, b: number)
	return Color3.new(r / 255, g / 255, b / 255)
end
function Color3.fromHex(hex: string)
	local r, g, b = string.match(string.gsub(hex, "#", ""), "^(%x%x)(%x%x)(%x%x)$")
	assert(r, `mock Color3.fromHex: "{hex}" isn't a colour`)
	return Color3.new(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
end
function Color3.ToHex(c)
	local function byte(v)
		return math.clamp(math.round(v * 255), 0, 255)
	end
	return string.format("%02X%02X%02X", byte(c.R), byte(c.G), byte(c.B))
end
function Color3.fromHSV(h: number, s: number, v: number)
	local i = math.floor(h * 6) % 6
	local f = h * 6 - math.floor(h * 6)
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local rgb = ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1]
	return Color3.new(rgb[1], rgb[2], rgb[3])
end

local ColorSequence = {
	new = function(a, b)
		if type(a) == "table" and getmetatable(a) ~= Color3MT then
			return setmetatable({ Keypoints = a }, ColorSequenceMT)
		end
		return setmetatable({ Keypoints = { { Time = 0, Value = a }, { Time = 1, Value = b or a } } }, ColorSequenceMT)
	end,
}
local ColorSequenceKeypoint = {
	new = function(time, value)
		return { Time = time, Value = value }
	end,
}
local NumberSequence = {
	new = function(a, b)
		if type(a) == "table" then
			return setmetatable({ Keypoints = a }, NumberSequenceMT)
		end
		return setmetatable({ Keypoints = { { Time = 0, Value = a, Envelope = 0 }, { Time = 1, Value = b or a, Envelope = 0 } } }, NumberSequenceMT)
	end,
}
local NumberSequenceKeypoint = {
	new = function(time, value, envelope)
		return { Time = time, Value = value, Envelope = envelope or 0 }
	end,
}

-- Fonts by family, weight and style; an Enum.Font (a string here, see Enum) by its name.
local Font = {}
FontMT.__index = Font
FontMT.__eq = function(a, b)
	return a.Family == b.Family and a.Weight == b.Weight and a.Style == b.Style
end
function Font.new(family: string, weight: any?, style: any?)
	return setmetatable({ Family = family, Weight = weight or "FontWeight.Regular", Style = style or "FontStyle.Normal" }, FontMT)
end
function Font.fromEnum(item: any)
	return Font.new(`rbxasset://fonts/families/{string.match(tostring(item), "[^.]+$")}.json`)
end

-- Luau's own utf8, and Roblox's graphemes (here, each character).
local utf8 = setmetatable({
	graphemes = function(text: string)
		local starts = {}
		for at in utf8.codes(text) do
			table.insert(starts, at)
		end
		local i = 0
		return function()
			i += 1
			if not starts[i] then
				return nil
			end
			return starts[i], (starts[i + 1] or #text + 1) - 1
		end
	end,
}, { __index = utf8 })

-- Vector3 ------------------------------------------------------------------------------------

local Vector3 = {}
Vector3MT.__index = Vector3

function Vector3.new(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3MT)
end

Vector3MT.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3MT.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3MT.__tostring = function(v)
	return `{v.X}, {v.Y}, {v.Z}`
end
function Vector3.Lerp(a, b, t)
	return Vector3.new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end

-- CFrame (rotation stored row-major, like GetComponents) -------------------------------------

local CFrame = {}

-- Like Roblox's, CFrames are equal when every component is.
CFrameMT.__eq = function(a, b)
	if a.x ~= b.x or a.y ~= b.y or a.z ~= b.z then
		return false
	end
	for i = 1, 9 do
		if a.r[i] ~= b.r[i] then
			return false
		end
	end
	return true
end

local function makeCFrame(x, y, z, r)
	return setmetatable({ x = x, y = y, z = z, r = r }, CFrameMT)
end

local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

function CFrame.new(...)
	local n = select("#", ...)
	if n == 0 then
		return makeCFrame(0, 0, 0, table.clone(IDENTITY))
	elseif n == 3 then
		local x, y, z = ...
		return makeCFrame(x, y, z, table.clone(IDENTITY))
	elseif n == 12 then
		local c = { ... }
		return makeCFrame(c[1], c[2], c[3], { c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12] })
	end
	error("unsupported CFrame.new arity " .. n)
end

local function matmul(a, b)
	local out = {}
	for row = 0, 2 do
		for col = 0, 2 do
			local sum = 0
			for k = 0, 2 do
				sum += a[row * 3 + k + 1] * b[k * 3 + col + 1]
			end
			out[row * 3 + col + 1] = sum
		end
	end
	return out
end

local function rotate(r, x, y, z)
	return r[1] * x + r[2] * y + r[3] * z, r[4] * x + r[5] * y + r[6] * z, r[7] * x + r[8] * y + r[9] * z
end

function CFrame.Angles(rx: number, ry: number, rz: number)
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	local Rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local Rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return makeCFrame(0, 0, 0, matmul(matmul(Rx, Ry), Rz))
end

CFrameMT.__index = function(cf, key)
	if key == "Position" then
		return Vector3.new(cf.x, cf.y, cf.z)
	elseif key == "X" then
		return cf.x
	elseif key == "Y" then
		return cf.y
	elseif key == "Z" then
		return cf.z
	elseif key == "Rotation" then
		return makeCFrame(0, 0, 0, table.clone(cf.r))
	end
	return CFrame[key]
end

CFrameMT.__mul = function(a, b)
	if getmetatable(b) == Vector3MT then
		local x, y, z = rotate(a.r, b.X, b.Y, b.Z)
		return Vector3.new(x + a.x, y + a.y, z + a.z)
	end
	local x, y, z = rotate(a.r, b.x, b.y, b.z)
	return makeCFrame(x + a.x, y + a.y, z + a.z, matmul(a.r, b.r))
end

CFrameMT.__add = function(a, v)
	return makeCFrame(a.x + v.X, a.y + v.Y, a.z + v.Z, table.clone(a.r))
end

CFrameMT.__tostring = function(cf)
	return table.concat({ cf:GetComponents() }, ", ")
end

function CFrame.GetComponents(cf)
	local r = cf.r
	return cf.x, cf.y, cf.z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
end

function CFrame.Inverse(cf)
	local r = cf.r
	local t = { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
	local x, y, z = rotate(t, cf.x, cf.y, cf.z)
	return makeCFrame(-x, -y, -z, t)
end

function CFrame.ToObjectSpace(a, b)
	return a:Inverse() * b
end

function CFrame.Lerp(a, b, t)
	local r = {}
	for i = 1, 9 do
		r[i] = a.r[i] + (b.r[i] - a.r[i]) * t
	end
	return makeCFrame(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, r)
end

CFrame.identity = CFrame.new()

-- GUI value types used at module load -------------------------------------------------------

local Vector2 = {
	new = function(x, y)
		return setmetatable({ X = x, Y = y }, Vector2MT)
	end,
}
Vector2MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
local UDim2 = {}
function UDim2.new(xScale, xOffset, yScale, yOffset)
	return setmetatable({
		X = { Scale = xScale or 0, Offset = xOffset or 0 },
		Y = { Scale = yScale or 0, Offset = yOffset or 0 },
	}, UDim2MT)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x, 0, y, 0)
end
UDim2MT.__eq = function(a, b)
	return a.X.Scale == b.X.Scale and a.X.Offset == b.X.Offset and a.Y.Scale == b.Y.Scale and a.Y.Offset == b.Y.Offset
end
local UDim = {
	new = function(scale, offset)
		return { Scale = scale, Offset = offset }
	end,
}

-- Any Enum item, as a string like "Font.SourceSans".
local Enum = setmetatable({}, {
	__index = function(_, enumName)
		return setmetatable({}, {
			__index = function(_, item)
				return `{enumName}.{item}`
			end,
		})
	end,
})

-- Studio's theme hands back a fixed colour name; ThemeChanged is a plain signal.
local studioSettings
local function settings()
	return studioSettings
end

-- Instances ----------------------------------------------------------------------------------

local SUPERCLASSES = {
	Part = "BasePart",
	MeshPart = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	Workspace = "Model",
	StringValue = "ValueBase",
	CFrameValue = "ValueBase",
	IntValue = "ValueBase",
	NumberValue = "ValueBase",
	Vector3Value = "ValueBase",
	BoolValue = "ValueBase",
	ObjectValue = "ValueBase",
	Weld = "JointInstance",
	Motor6D = "JointInstance",
	Bone = "Attachment",
	RopeConstraint = "Constraint",
	PointLight = "Light",
	ImageLabel = "GuiObject",
	TextLabel = "GuiObject",
	Frame = "GuiObject",
	TextButton = "GuiButton",
	ImageButton = "GuiButton",
	GuiButton = "GuiObject",
	TextBox = "GuiObject",
	GuiObject = "GuiBase2d",
	ScreenGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	BlurEffect = "PostEffect",
	ColorCorrectionEffect = "PostEffect",
}

local Instance = {}
local methods = {}

function Instance.new(className: string, props: { [string]: any }?)
	local data = {
		Name = className,
		ClassName = className,
		Parent = nil,
		Children = {},
		Attributes = {},
		Archivable = true,
	}
	if className == "Part" then
		data.CFrame = CFrame.new()
		data.Anchored = true
	elseif className == "Attachment" then
		data.CFrame = CFrame.new()
	end

	local inst = setmetatable({ __data = data }, InstanceMT)
	for key, value in props or {} do
		inst[key] = value
	end
	return inst
end

local function newSignal()
	local handlers = {}
	return {
		Connect = function(_self, handler)
			table.insert(handlers, handler)
			return {
				Disconnect = function()
					local at = table.find(handlers, handler)
					if at then
						table.remove(handlers, at)
					end
				end,
			}
		end,
		Fire = function(_self, ...)
			for _, handler in table.clone(handlers) do
				handler(...)
			end
		end,
	}
end

studioSettings = {
	Studio = {
		Theme = {
			GetColor = function(_self, color, modifier)
				return `{color}/{modifier or "Default"}`
			end,
		},
		ThemeChanged = newSignal(),
	},
}

local EVENTS = {
	MouseEnter = true,
	MouseLeave = true,
	MouseButton1Down = true,
	MouseButton1Up = true,
	MouseButton1Click = true,
	Activated = true,
	InputBegan = true,
	Focused = true,
	FocusLost = true,
}

InstanceMT.__index = function(inst, key)
	local m = methods[key]
	if m then
		return m
	end
	local data = rawget(inst, "__data")
	local value = data[key]
	if value ~= nil then
		return value
	end
	if EVENTS[key] then
		data[key] = newSignal()
		return data[key]
	elseif key == "WorldCFrame" and data.ClassName == "Attachment" then
		local parent = data.Parent
		return if parent and parent.CFrame then parent.CFrame * data.CFrame else data.CFrame
	elseif key == "AbsoluteSize" and data.ClassName == "ScreenGui" then
		-- A 1080p screen.
		return Vector2.new(1920, 1080)
	elseif key == "AbsoluteSize" or key == "AbsolutePosition" or key == "TextBounds" then
		return { X = 0, Y = 0 }
	end
	return nil
end

InstanceMT.__newindex = function(inst, key, value)
	local data = rawget(inst, "__data")
	if key == "Parent" then
		local old = data.Parent
		if old then
			local siblings = rawget(old, "__data").Children
			local at = table.find(siblings, inst)
			if at then
				table.remove(siblings, at)
			end
		end
		data.Parent = value
		if value then
			table.insert(rawget(value, "__data").Children, inst)
		end
	elseif key == "WorldCFrame" and data.ClassName == "Attachment" then
		local parent = data.Parent
		data.CFrame = if parent and parent.CFrame then parent.CFrame:Inverse() * value else value
	elseif data[key] ~= value then
		data[key] = value
		local changed = data["__changed_" .. key]
		if changed then
			changed:Fire()
		end
	end
end

InstanceMT.__tostring = function(inst)
	return inst.Name
end

function methods.IsA(inst, className)
	local class = inst.ClassName
	while class do
		if class == className or className == "Instance" then
			return true
		end
		class = SUPERCLASSES[class]
	end
	return false
end

function methods.GetChildren(inst)
	return table.clone(rawget(inst, "__data").Children)
end

function methods.GetDescendants(inst)
	local out = {}
	local function walk(node)
		for _, child in rawget(node, "__data").Children do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(inst)
	return out
end

function methods.IsAncestorOf(inst, other)
	return other:IsDescendantOf(inst)
end

-- Doesn't wait: in the tests a child is either there or it isn't.
function methods.WaitForChild(inst, name)
	return inst:FindFirstChild(name)
end

function methods.FindFirstChild(inst, name, recursive)
	for _, child in rawget(inst, "__data").Children do
		if child.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in rawget(inst, "__data").Children do
			local found = child:FindFirstChild(name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function methods.FindFirstChildOfClass(inst, className)
	for _, child in rawget(inst, "__data").Children do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

function methods.FindFirstChildWhichIsA(inst, className)
	for _, child in rawget(inst, "__data").Children do
		if child:IsA(className) then
			return child
		end
	end
	return nil
end

function methods.FindFirstAncestorWhichIsA(inst, className)
	local node = inst.Parent
	while node do
		if node:IsA(className) then
			return node
		end
		node = node.Parent
	end
	return nil
end

function methods.GetAttribute(inst, name)
	return rawget(inst, "__data").Attributes[name]
end

function methods.GetAttributes(inst)
	return table.clone(rawget(inst, "__data").Attributes)
end

function methods.SetAttribute(inst, name, value)
	rawget(inst, "__data").Attributes[name] = value
end

function methods.GetFullName(inst)
	local names = {}
	local node = inst
	while node and node.ClassName ~= "DataModel" do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return table.concat(names, ".")
end

function methods.GetPropertyChangedSignal(inst, property)
	local data = rawget(inst, "__data")
	local key = "__changed_" .. property
	data[key] = data[key] or newSignal()
	return data[key]
end

function methods.IsDescendantOf(inst, ancestor)
	local node = inst.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = node.Parent
	end
	return false
end

function methods.FindFirstAncestor(inst, name)
	local node = inst.Parent
	while node do
		if node.Name == name then
			return node
		end
		node = node.Parent
	end
	return nil
end

function methods.Destroy(inst)
	inst.Parent = nil
	rawget(inst, "__data").Destroyed = true
end

-- Like Roblox, references to instances inside the copied subtree point at the copies.
function methods.Clone(inst)
	if not inst.Archivable then
		return nil
	end

	local map = {}
	local function copy(source)
		local data = rawget(source, "__data")
		local clone = Instance.new(data.ClassName)
		map[source] = clone
		local cloneData = rawget(clone, "__data")
		for key, value in data do
			if key ~= "Parent" and key ~= "Children" and key ~= "Attributes" then
				cloneData[key] = value
			end
		end
		cloneData.Attributes = table.clone(data.Attributes)
		for _, child in data.Children do
			if child.Archivable then
				copy(child).Parent = clone
			end
		end
		return clone
	end

	local root = copy(inst)
	for _, clone in map do
		local data = rawget(clone, "__data")
		for key, value in data do
			if key ~= "Parent" and getmetatable(value) == InstanceMT and map[value] then
				data[key] = map[value]
			end
		end
	end
	return root
end

-- Records calls instead of doing anything.
local calls = {}
local function record(name)
	return function(inst, ...)
		table.insert(calls, { Name = name, Instance = inst, Args = { ... } })
	end
end
methods.Emit = record("Emit")
methods.Play = record("Play")

function methods.PivotTo(inst, cf)
	rawget(inst, "__data").Pivot = cf
end

function methods.GetPivot(inst)
	local primary = inst.PrimaryPart
	if primary then
		return primary.CFrame
	end
	return CFrame.new()
end

-- DataModel ----------------------------------------------------------------------------------

local jsonRegistry = {}
local jsonCount = 0

-- Registers a decoded table and returns a JSON-looking key for it.
local function mockJson(value: any): string
	jsonCount += 1
	local key = `\{"mock":{jsonCount}}`
	jsonRegistry[key] = value
	return key
end

-- Real JSON, for saves written as text (Eclipse's).
local function parseJson(text: string): any
	local at = 1
	local function space()
		at = (string.find(text, "[^ \t\r\n]", at) or #text + 1)
	end
	local value
	local function str(): string
		local out = {}
		at += 1
		while true do
			local c = string.sub(text, at, at)
			if c == '"' then
				at += 1
				return table.concat(out)
			elseif c == "\\" then
				local n = string.sub(text, at + 1, at + 1)
				table.insert(out, ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n)
				at += 2
			elseif c == "" then
				error("mock JSONDecode: unterminated string")
			else
				table.insert(out, c)
				at += 1
			end
		end
	end
	function value(): any
		space()
		local c = string.sub(text, at, at)
		if c == "{" then
			local out = {}
			at += 1
			space()
			if string.sub(text, at, at) == "}" then
				at += 1
				return out
			end
			while true do
				space()
				local key = str()
				space()
				at += 1 -- :
				out[key] = value()
				space()
				local sep = string.sub(text, at, at)
				at += 1
				if sep == "}" then
					return out
				end
			end
		elseif c == "[" then
			local out = {}
			at += 1
			space()
			if string.sub(text, at, at) == "]" then
				at += 1
				return out
			end
			while true do
				table.insert(out, value())
				space()
				local sep = string.sub(text, at, at)
				at += 1
				if sep == "]" then
					return out
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, at, at + 3) == "true" then
			at += 4
			return true
		elseif string.sub(text, at, at + 4) == "false" then
			at += 5
			return false
		elseif string.sub(text, at, at + 3) == "null" then
			at += 4
			return nil
		end
		local s, e = string.find(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", at)
		if not s then
			error("mock JSONDecode: bad json at " .. at)
		end
		at = e + 1
		return tonumber(string.sub(text, s, e))
	end
	return value()
end

local HttpService = {
	JSONDecode = function(_self, json)
		local value = jsonRegistry[json]
		if value == nil then
			return parseJson(json)
		end
		return value
	end,
}

local game = Instance.new("DataModel", { Name = "Game" })
local Workspace = Instance.new("Workspace", { Name = "Workspace", Parent = game })
local workspace = Workspace
Instance.new("ServerStorage", { Name = "ServerStorage", Parent = game })

local function resetGame()
	for _, service in game:GetChildren() do
		for _, child in service:GetChildren() do
			child.Parent = nil
		end
	end
end

-- Heartbeat is stepped by hand: step() fires every connected handler once.
local heartbeatHandlers = {}
local RunService = {
	Heartbeat = {
		Connect = function(_self, handler)
			local connection = { Connected = true }
			heartbeatHandlers[connection] = handler
			function connection.Disconnect(c)
				c.Connected = false
				heartbeatHandlers[c] = nil
			end
			return connection
		end,
	},
}

-- The tests act as a client, where RenderStepped runs alongside Heartbeat.
RunService.RenderStepped = RunService.Heartbeat
RunService.IsClient = function()
	return true
end

-- task.delay waits on this clock, which step() moves on by a frame.
local clock = 0
local delayed = {}

local function step()
	clock += 1 / 60
	for connection, handler in table.clone(heartbeatHandlers) do
		if connection.Connected then
			handler(1 / 60)
		end
	end

	local due = {}
	for i = #delayed, 1, -1 do
		if delayed[i].At <= clock + 1e-9 then
			table.insert(due, table.remove(delayed, i))
		end
	end
	table.sort(due, function(a, b)
		return a.At < b.At
	end)
	for _, entry in due do
		entry.Fn(table.unpack(entry.Args, 1, entry.Args.n))
	end
end

local Debris = {
	AddItem = function(_self, inst, lifetime)
		table.insert(calls, { Name = "AddItem", Instance = inst, Args = { lifetime } })
	end,
}

methods.GetService = function(inst, name)
	if name == "HttpService" then
		return HttpService
	elseif name == "RunService" then
		return RunService
	elseif name == "Debris" then
		return Debris
	elseif name == "TweenService" then
		-- Linear is enough: the tests check values on keyframes.
		return {
			GetValue = function(_self, alpha)
				return alpha
			end,
		}
	elseif name == "TextService" then
		-- Each character half as wide as the text is tall.
		return {
			GetTextSize = function(_self, text, size)
				return Vector2.new(utf8.len(text) * size * 0.5, size)
			end,
		}
	end
	return inst:FindFirstChild(name)
end

-- task runs everything immediately, except a delay of more than nothing, which waits for step() to
-- reach it; warn is captured.
local task = {
	-- In a thread of its own, so a loop that waits (a hook's polling) stops at its first wait.
	spawn = function(fn, ...)
		local thread = coroutine.create(fn)
		local ok, problem = coroutine.resume(thread, ...)
		if not ok then
			error(problem, 0)
		end
		return thread
	end,
	wait = function()
		return coroutine.yield()
	end,
	delay = function(seconds, fn, ...)
		if not seconds or seconds <= 0 then
			fn(...)
			return
		end
		table.insert(delayed, { At = clock + seconds, Fn = fn, Args = table.pack(...) })
	end,
	defer = function(fn, ...)
		fn(...)
	end,
}

local warnings = {}
local function warn(...)
	table.insert(warnings, table.concat({ ... }, " "))
end

-- Module loader ------------------------------------------------------------------------------

local definitions = {}
local loaded = {}

local function __load(name: string)
	if loaded[name] == nil then
		local fakeScript = {
			Name = name,
			Parent = setmetatable({}, {
				__index = function(_, child)
					return { __module = child }
				end,
			}),
		}
		loaded[name] = definitions[name](fakeScript, function(ref)
			-- A ModuleScript in the mock DataModel returns what a test put in its Returns.
			if typeof(ref) == "Instance" then
				local returns = rawget(ref, "__data").Returns
				assert(returns ~= nil, `mock require: {ref.Name} returns nothing`)
				return returns
			end
			return __load(ref.__module)
		end)
	end
	return loaded[name]
end

local function __define(name: string, fn)
	definitions[name] = fn
end
