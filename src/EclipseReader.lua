--!strict
-- Reads Eclipse Animator projects into the same Animation SaveReader reads from Moon's files, so
-- the exporter treats both alike.
--
-- Eclipse saves a project as a Folder in ServerStorage["Eclipse Animator Saves"].EclipseAnimator_Saves
-- (@ marks an attribute):
--   <project>                    @EclipseSave, @FPS, @EclipseTimelineEnd (its last frame)
--     Rigs/<item>                each thing on the timeline: an ObjectValue Rig pointing at it, and
--                                @RigName, @RigClass, @RigPath, @RigGamePath, @RigId, @Order
--       Animation                a KeyframeSequence holding Eclipse's data for it:
--         EclipseKeyframeData    JSON: its joints, each a path to the part it moves and keys of the
--                                joint's C0
--         EclipseProperties      JSON: its property tracks, keyed by frame
--         EclipseEvents          a Folder per event: @Frame, @Duration, @EventName, its code
--                                (CodeBegin, CodeEnd) and what it emits (Emits, JSON)
--     EclipseTrackOrganization   which items are switched off
-- Text too long for one StringValue is split over several in a Folder.

local EclipseCurves = require(script.Parent.EclipseCurves)
local SaveReader = require(script.Parent.SaveReader)

local EclipseReader = {}

local ROOT = "Eclipse Animator Saves"
local SAVES = "EclipseAnimator_Saves"

-- Property ids that are another name in Roblox.
local PROPERTY_NAMES = { TimeOfDay = "ClockTime" }

local function decode(json: string): any
	return game:GetService("HttpService"):JSONDecode(json)
end

-- Text Eclipse saved: a StringValue's, or the StringValues' in a Folder, in order.
local function readText(node: Instance?): string
	if not node then
		return ""
	end
	if node:IsA("StringValue") then
		return (node :: StringValue).Value
	end
	local chunks = node:GetChildren()
	table.sort(chunks, function(a, b)
		return a.Name < b.Name
	end)
	local parts = {}
	for _, chunk in chunks do
		if chunk:IsA("StringValue") then
			table.insert(parts, (chunk :: StringValue).Value)
		end
	end
	return table.concat(parts)
end

local function readJson(node: Instance?): any
	local text = readText(node)
	if not string.find(text, "%S") then
		return nil
	end
	local ok, value = pcall(decode, text)
	return if ok then value else nil
end

-- An enum by its names, or (where it doesn't exist) a table holding them.
local function enumItem(enumType: any, name: any): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumType][name]
	end)
	if ok and typeof(item) == "EnumItem" then
		return item
	end
	return { EnumType = enumType, Name = name }
end

-- A value in Eclipse's typed JSON (its project format): { t = "cf", v = { ... } } is a CFrame,
-- { t = "table", v = { { key, value }, ... } } a table, and so on.
local function fromDocument(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local kind, v = value.t, value.v
	if kind == "table" then
		local out = {}
		for _, entry in v or {} do
			if type(entry) == "table" and entry[1] ~= nil then
				out[entry[1]] = fromDocument(entry[2])
			end
		end
		return out
	elseif kind == "enum" then
		return enumItem(value.e, v)
	end

	local ok, made = pcall(function(): any
		if kind == "cf" then
			return CFrame.new(table.unpack(v))
		elseif kind == "v3" then
			return Vector3.new(v[1], v[2], v[3])
		elseif kind == "Color3" then
			return Color3.new(v[1], v[2], v[3])
		elseif kind == "Vector2" then
			return Vector2.new(v[1], v[2])
		elseif kind == "NumberRange" then
			return NumberRange.new(v[1], v[2])
		elseif kind == "UDim" then
			return UDim.new(v[1], v[2])
		elseif kind == "UDim2" then
			return UDim2.new(v[1], v[2], v[3], v[4])
		elseif kind == "Rect" then
			return Rect.new(v[1], v[2], v[3], v[4])
		elseif kind == "BrickColor" then
			return BrickColor.new(v)
		elseif kind == "NumberSequence" then
			local points = {}
			for _, point in v do
				table.insert(points, NumberSequenceKeypoint.new(point[1], point[2], point[3] or 0))
			end
			return NumberSequence.new(points)
		elseif kind == "ColorSequence" then
			local points = {}
			for _, point in v do
				table.insert(points, ColorSequenceKeypoint.new(point[1], fromDocument(point[2])))
			end
			return ColorSequence.new(points)
		end
		return value
	end)
	return if ok then made else nil
end

-- A value in Eclipse's keyframe JSON: { T = { key, value, key, value, ... } } is a table,
-- { C = { ... } } a CFrame, { V = { ... } } a Vector3, { E = { enum, name } } an enum.
local function fromKeyframe(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if value.T then
		local out = {}
		local flat = value.T
		for i = 1, #flat, 2 do
			out[flat[i]] = fromKeyframe(flat[i + 1])
		end
		out._EclipseDerivedPose = nil
		return out
	elseif value.C then
		return CFrame.new(table.unpack(value.C))
	elseif value.V then
		return Vector3.new(value.V[1], value.V[2], value.V[3])
	elseif value.E then
		return enumItem(value.E[1], value.E[2])
	end

	-- Older saves.
	if value.type == "CFrame" then
		return CFrame.new(table.unpack(value.value))
	elseif value.type == "Vector3" then
		return Vector3.new(value.value[1], value.value[2], value.value[3])
	elseif value.type == "Enum" then
		return enumItem(value.enum, value.value)
	elseif value.type == "Table" then
		local out = {}
		for _, entry in value.entries or {} do
			out[entry.key] = fromKeyframe(entry.value)
		end
		return out
	end
	return value
end

-- Follows a path of steps from `root`: each step a child's name and class, and which of the
-- children with both it is ({ name, class, index }, or Name, Class, Index). A { link = "Part1" }
-- step goes from a Motor6D to the part it moves.
local function follow(root: Instance?, path: any): Instance?
	if not root or type(path) ~= "table" then
		return nil
	end
	local current: Instance = root
	for _, step in path do
		if type(step) ~= "table" then
			return nil
		end
		if step.link == "Part1" then
			local part = if current:IsA("Motor6D") then (current :: Motor6D).Part1 else nil
			if not part then
				return nil
			end
			current = part
		elseif step.link then
			return nil
		else
			local name, class, index = step.name or step.Name, step.class or step.Class, step.index or step.Index or 1
			local found, count = nil, 0
			for _, child in current:GetChildren() do
				if child.Name == name and child.ClassName == class then
					count += 1
					if count == index then
						found = child
						break
					end
				end
			end
			if not found then
				return nil
			end
			current = found
		end
	end
	return current
end

local function followJson(root: Instance, text: any): Instance?
	if type(text) ~= "string" then
		return nil
	end
	local ok, path = pcall(decode, text)
	return if ok then follow(root, path) else nil
end

local function isCameraRig(inst: Instance): boolean
	local root = inst:FindFirstChild("RootPart")
	return inst:IsA("Model") and root ~= nil and root:FindFirstChild("FovPart") ~= nil and inst:FindFirstChild("FovPart") ~= nil
end

local function isEffectObject(inst: Instance): boolean
	return inst:IsA("Model") and inst:GetAttribute("EclipseEffectObject") == 1
end

-- The thing a Rigs entry animates: what its Rig points at, or (when that's gone) what's at its
-- saved path, has its Eclipse id, or has its name.
local function findRig(entry: Instance, save: Instance): Instance?
	local reference = entry:FindFirstChild("Rig")
	local rig = if reference and reference:IsA("ObjectValue") then (reference :: ObjectValue).Value else nil
	if rig and rig.Parent then
		return rig
	end

	local class = entry:GetAttribute("RigClass")
	for _, saved in { { "RigGamePath", game }, { "RigPath", game:GetService("Workspace") } } do
		local found = followJson(saved[2] :: Instance, entry:GetAttribute(saved[1] :: string))
		if found and (class == nil or found.ClassName == class) then
			return found
		end
	end

	local id = entry:GetAttribute("RigId")
	local name = entry:GetAttribute("RigName") or entry.Name
	local byName = {}
	local places = { game:GetService("Workspace") :: Instance }
	local copies = save:FindFirstChild("EclipseEffectObjects")
	if copies then
		table.insert(places, copies)
	end
	for _, place in places do
		for _, candidate in place:GetDescendants() do
			if id ~= nil and candidate:GetAttribute("EclipseTrackId") == id then
				return candidate
			end
			if candidate.Name == name and (class == nil or candidate.ClassName == class) then
				table.insert(byName, candidate)
			end
		end
	end
	return if #byName == 1 then byName[1] else nil
end

-- The items switched off in Eclipse's timeline (or in a switched-off folder there).
local function switchedOff(save: Instance): { [Instance]: boolean }
	local off = {}
	local root = save:FindFirstChild("EclipseTrackOrganization")
	if not root then
		return off
	end

	local folders = {}
	for _, entry in root:GetChildren() do
		if entry:GetAttribute("Kind") == "Folder" then
			folders[entry.Name] = entry
		end
	end
	local function insideOff(entry: Instance, seen: { [Instance]: boolean }): boolean
		if entry:GetAttribute("ParentKind") ~= "Folder" then
			return false
		end
		local folder = folders[entry:GetAttribute("ParentId")]
		if not folder or seen[folder] then
			return false
		end
		seen[folder] = true
		return folder:GetAttribute("Enabled") == false or insideOff(folder, seen)
	end

	for _, entry in root:GetChildren() do
		if entry:GetAttribute("Kind") == "Item" then
			local reference = entry:FindFirstChild("Target")
			local target = if reference and reference:IsA("ObjectValue") then (reference :: ObjectValue).Value else nil
			if target and (entry:GetAttribute("Removed") == true or entry:GetAttribute("Enabled") == false or insideOff(entry, {})) then
				off[target] = true
			end
		end
	end
	return off
end

local function isSave(inst: Instance): boolean
	return inst:IsA("Folder") and inst:GetAttribute("EclipseSave") == true and inst:FindFirstChild("Rigs") ~= nil
end
EclipseReader.isSave = isSave

local function entryFor(save: Instance): SaveReader.SaveEntry
	local fps = tonumber(save:GetAttribute("FPS"))
	local length = tonumber(save:GetAttribute("EclipseTimelineEnd"))
	return {
		Save = save :: any,
		Name = save.Name,
		Length = length or 0,
		FPS = if fps and fps > 0 then fps else 60,
		Modified = nil,
		Source = "Eclipse",
	}
end

-- Every Eclipse project in the place, by name.
function EclipseReader.findSaves(): { SaveReader.SaveEntry }
	local ServerStorage = game:GetService("ServerStorage")
	local folders = {}
	local root = ServerStorage:FindFirstChild(ROOT)
	for _, parent in { root, ServerStorage } do
		local saves = parent and parent:FindFirstChild(SAVES)
		if saves then
			table.insert(folders, saves)
		end
	end

	local found = {}
	for _, folder in folders do
		for _, save in folder:GetChildren() do
			if isSave(save) then
				table.insert(found, entryFor(save))
			end
		end
	end
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	return found
end

-- Where an instance is, as names and classes from the DataModel down.
local function pathOf(inst: Instance): ({ string }, { string })
	local names, classes = {}, {}
	local node: Instance? = inst
	while node do
		table.insert(names, 1, node.Name)
		table.insert(classes, 1, node.ClassName)
		node = node.Parent
	end
	return names, classes
end

-- A value as numbers for EclipseCurves, and back. nil for values that don't blend.
local CURVED = {
	number = {
		Values = function(v)
			return { v }
		end,
		Value = function(n)
			return n[1]
		end,
	},
	Vector3 = {
		Values = function(v)
			return { v.X, v.Y, v.Z }
		end,
		Value = function(n)
			return Vector3.new(n[1], n[2], n[3])
		end,
	},
	Vector2 = {
		Values = function(v)
			return { v.X, v.Y }
		end,
		Value = function(n)
			return Vector2.new(n[1], n[2])
		end,
	},
	Color3 = {
		Values = function(v)
			return { v.R, v.G, v.B }
		end,
		Value = function(n)
			return Color3.new(math.clamp(n[1], 0, 1), math.clamp(n[2], 0, 1), math.clamp(n[3], 0, 1))
		end,
	},
	NumberRange = {
		Values = function(v)
			return { v.Min, v.Max }
		end,
		Value = function(n)
			return NumberRange.new(math.min(n[1], n[2]), math.max(n[1], n[2]))
		end,
	},
	CFrame = {
		Values = EclipseCurves.cframeValues,
		Value = EclipseCurves.toCFrame,
		Rotation = true,
	},
}

-- A property key's value: as Eclipse recorded it, or read from the CFrame it blends with.
local function propertyValue(key: { [string]: any }, default: any): any
	local kind = typeof(default)
	if key.PropertyValue ~= nil and typeof(key.PropertyValue) == kind then
		return key.PropertyValue
	end
	local c0 = key.C0
	if typeof(c0) ~= "CFrame" then
		return default
	end
	if kind == "number" then
		return c0.X
	elseif kind == "Vector3" then
		return c0.Position
	elseif kind == "Vector2" then
		return Vector2.new(c0.X, c0.Y)
	elseif kind == "Color3" then
		return Color3.new(math.clamp(c0.X, 0, 1), math.clamp(c0.Y, 0, 1), math.clamp(c0.Z, 0, 1))
	elseif kind == "NumberRange" then
		return NumberRange.new(math.min(c0.X, c0.Y), math.max(c0.X, c0.Y))
	elseif kind == "CFrame" then
		return c0
	end
	return default
end

type Raw = { Frame: number, Value: any, Data: { [string]: any } }

-- Keys as the exporter reads them (SaveReader.Keyframe), from Eclipse's: blended values through
-- EclipseCurves, the rest held until the next key.
local function keyframes(raw: { Raw }): { SaveReader.Keyframe }
	table.sort(raw, function(a, b)
		return a.Frame < b.Frame
	end)
	if #raw == 0 then
		return {}
	end

	local codec = CURVED[typeof(raw[1].Value)]
	if not codec then
		local held = {}
		for _, key in raw do
			-- Blended in Eclipse (a UDim2, a NumberSequence...): eased the way it was, where it can be.
			local ease = if typeof(key.Value) == "UDim2" then EclipseCurves.mapEase(key.Data) else nil
			table.insert(held, { Time = key.Frame, Value = key.Value, Ease = ease or { Type = "Constant", Params = {} } })
		end
		return held
	end

	local keys = {}
	for _, key in raw do
		table.insert(keys, { Frame = key.Frame, Values = codec.Values(key.Value), Data = key.Data })
	end
	local out = {}
	for _, key in EclipseCurves.track(keys, codec.Rotation) do
		table.insert(out, { Time = key.Frame, Value = codec.Value(key.Values), Ease = key.Ease })
	end
	return out
end

-- The Motor6D in `rig` that moves `part`.
local function motorFor(rig: Instance, part: Instance): Motor6D?
	for _, item in rig:GetDescendants() do
		if item:IsA("Motor6D") and (item :: Motor6D).Part1 == part then
			return item :: Motor6D
		end
	end
	return nil
end

-- A camera rig's default field of view.
local function defaultFov(entry: Instance, rig: Instance?): number
	local folder = rig and rig:FindFirstChild("FieldOfView")
	local default = folder and folder:FindFirstChild("default")
	local value = if default and default:IsA("NumberValue") then (default :: NumberValue).Value else entry:GetAttribute("CameraDefaultFOV")
	return if type(value) == "number" then math.clamp(value, 1, 120) else 70
end

-- The effects an Enable or Disable row switches: the target alone (Exact), with its effects right
-- inside it (Selected), or with all the effects in it (All).
local SWITCHED = { "ParticleEmitter", "Beam", "Trail", "Light" }
local function switchable(inst: Instance): boolean
	for _, class in SWITCHED do
		if inst:IsA(class) then
			return true
		end
	end
	return false
end
local function switchedBy(target: Instance, mode: string): { Instance }
	local found = {}
	if switchable(target) then
		table.insert(found, target)
	end
	if mode ~= "Exact" then
		for _, inside in (if mode == "All" then target:GetDescendants() else target:GetChildren()) do
			if switchable(inside) then
				table.insert(found, inside)
			end
		end
	end
	return found
end

-- A readable path for a warning: Torso/RightGripAttachment.
local function pathText(path: any): string
	local names = {}
	for _, step in path or {} do
		if type(step) == "table" then
			table.insert(names, tostring(step.Name or step.name))
		end
	end
	return table.concat(names, "/")
end

-- An event's markers, code and emits (see EclipseEvents above) as a SaveReader.Marker.
local function readEvent(node: Instance, rig: Instance?, warnings: { string }, itemName: string): SaveReader.Marker?
	local frame = node:GetAttribute("Frame")
	if type(frame) ~= "number" or node:GetAttribute("Enabled") == false then
		return nil
	end

	local name = node:GetAttribute("EventName")
	local parameter = node:GetAttribute("Parameter")
	local keys = {}
	local markers = readJson(node:FindFirstChild("Markers"))
	if type(markers) == "table" then
		for _, marker in markers do
			if type(marker) == "table" and type(marker.Name) == "string" and marker.Name ~= "" then
				keys[marker.Name] = tostring(marker.Parameter or "")
			end
		end
		local first = markers[1]
		if type(first) == "table" then
			name, parameter = first.Name, first.Parameter
		end
	end
	name = if type(name) == "string" then name else ""
	-- Eclipse names a new event "Event"; that's no name for its VFX.
	if name == "Event" then
		name = ""
	end

	local begin = readText(node:FindFirstChild("CodeBegin"))
	local finish = readText(node:FindFirstChild("CodeEnd"))
	local marker: SaveReader.Marker = {
		Frame = math.max(0, math.floor(frame + 0.5)),
		Name = name,
		Width = math.max(0, math.floor((tonumber(node:GetAttribute("Duration")) or 0) + 0.5)),
		Code = if string.find(begin, "%S") then { begin } else {},
		Keys = keys,
		Parameter = if parameter ~= nil then tostring(parameter) else "",
		EndCode = if string.find(finish, "%S") then finish else nil,
		Emits = {},
		Switches = {},
	}

	local rows = readJson(node:FindFirstChild("Emits"))
	for _, row in if type(rows) == "table" then rows else {} do
		if type(row) ~= "table" or type(row.Path) ~= "table" or not (row.Mode == "All" or row.Mode == "Selected" or row.Mode == "Exact") then
			continue
		end
		local target = follow(rig, row.Path)
		if not target then
			table.insert(warnings, `The event at frame {marker.Frame} on {itemName} emits {pathText(row.Path)}, which isn't in the place, so it's left out.`)
			continue
		end
		if row.Action == "Enable" or row.Action == "Disable" then
			table.insert(marker.Switches :: any, { Instance = target, Mode = row.Mode, Enabled = row.Action == "Enable" })
		elseif row.Action == nil or row.Action == "Emit" then
			local count = tonumber(row.Count)
			table.insert(marker.Emits :: any, { Instance = target, Mode = row.Mode, Count = if count then math.clamp(math.floor(count), 0, 100000) else nil })
		end
	end
	return marker
end

-- Whether a KeyframeSequence's Eclipse data has more than its base animation layer.
local function hasLayers(sequence: Instance): boolean
	local node = sequence:FindFirstChild("EclipseAnimationLayers")
	local stack = if node then fromDocument(readJson(node)) else nil
	return type(stack) == "table" and type(stack.layers) == "table" and #stack.layers > 1
end

function EclipseReader.load(save: Instance): SaveReader.Animation
	if not isSave(save) then
		error(`"{save.Name}" is not an Eclipse Animator project`, 0)
	end

	local anim = entryFor(save) :: any
	anim.Items = {}
	anim.Warnings = {}
	local warnings: { string } = anim.Warnings
	local off = switchedOff(save)

	local entries = (save:FindFirstChild("Rigs") :: Instance):GetChildren()
	local function order(entry: Instance): number
		local value = entry:GetAttribute("Order")
		return if type(value) == "number" then value else math.huge
	end
	table.sort(entries, function(a, b)
		if order(a) ~= order(b) then
			return order(a) < order(b)
		end
		return a.Name < b.Name
	end)

	local lastFrame = 0
	local byInstance: { [Instance]: SaveReader.Item } = {}
	local switches = {}

	for _, entry in entries do
		local rig = findRig(entry, save)
		local sequence = entry:FindFirstChildWhichIsA("KeyframeSequence")
		local name = tostring(entry:GetAttribute("RigName") or entry.Name)
		if rig and off[rig] then
			table.insert(warnings, `{rig.Name} is switched off in Eclipse's timeline, so it's left out.`)
			continue
		end

		local names, classes = {}, {}
		if rig then
			names, classes = pathOf(rig)
		else
			local ok, path = pcall(decode, entry:GetAttribute("RigGamePath") :: any)
			if ok and type(path) == "table" then
				names, classes = { "Game" }, { "DataModel" }
				for _, step in path do
					if type(step) == "table" then
						table.insert(names, tostring(step.name))
						table.insert(classes, tostring(step.class))
					end
				end
			else
				names, classes = { name }, { tostring(entry:GetAttribute("RigClass") or "?") }
			end
		end

		local camera = entry:GetAttribute("EclipseCamera") == true or (rig ~= nil and (isCameraRig(rig) or rig:IsA("Camera")))
		local itemType = if camera then "Camera"
			elseif rig and rig:IsA("Lighting") then "Lighting"
			elseif rig and isEffectObject(rig) then "ScreenEffect"
			elseif rig and rig:IsA("Model") and (rig:FindFirstChildOfClass("Humanoid") or rig:FindFirstChild("HumanoidRootPart")) then "Rig"
			elseif rig then rig.ClassName
			else tostring(entry:GetAttribute("RigClass") or "?")

		local item: SaveReader.Item = {
			Index = #anim.Items + 1,
			Path = table.concat(names, "."),
			PathNames = names,
			PathTypes = classes,
			ItemType = itemType,
			Instance = rig,
			Tracks = {},
			Defaults = {},
			Markers = {},
			Joints = {},
		}
		table.insert(anim.Items, item)
		if rig then
			byInstance[rig] = item
		end
		if not sequence then
			continue
		end

		if hasLayers(sequence) then
			table.insert(warnings, `{name} has animation layers in Eclipse. Only the layer being edited when it was saved is read, so its poses may be off.`)
		end

		-- Property tracks.
		local properties = fromDocument(readJson(sequence:FindFirstChild("EclipseProperties")))
		for _, row in if type(properties) == "table" and type(properties.tracks) == "table" then properties.tracks else {} do
			local id = row.id
			if type(id) ~= "string" or row.enabled == false or row.disabled or string.find(id, "^FaceControls%.") or id == "ApplyMesh" or id == "ApplyTexture" then
				continue
			end
			-- On a whole model, these blend each of its parts from its own value, which isn't replayed.
			if rig and rig:IsA("Model") and not isEffectObject(rig) and (id == "Transparency" or id == "Color" or id == "Reflectance") then
				table.insert(warnings, `{name}'s {id} is keyed on the whole model in Eclipse, which isn't exported yet; key its parts instead.`)
				continue
			end
			local property = PROPERTY_NAMES[id] or id
			local raw = {}
			for frame, key in if type(row.keys) == "table" then row.keys else {} do
				if type(frame) == "number" and type(key) == "table" and not key.Disabled then
					table.insert(raw, { Frame = frame, Value = propertyValue(key, row.default), Data = key })
					lastFrame = math.max(lastFrame, frame)
				end
			end
			if #raw > 0 then
				item.Tracks[property] = keyframes(raw)
			end
			if row.default ~= nil then
				item.Defaults[property] = row.default
			end
		end

		-- Joints, and a camera's field of view (its FovPart joint's C0.Y, from its default).
		local archive = readJson(sequence:FindFirstChild("EclipseKeyframeData"))
		for _, track in if rig and type(archive) == "table" and type(archive.tracks) == "table" then archive.tracks else {} do
			if type(track) ~= "table" or track.control then
				continue
			end
			local part = follow(rig, track.path)
			if not part then
				continue
			end
			local motor = nil
			if type(track.jointPath) == "table" then
				local joint = follow(rig, track.jointPath)
				if joint and joint:IsA("Motor6D") and (joint :: Motor6D).Part1 == part then
					motor = joint :: Motor6D
				end
			else
				motor = motorFor(rig :: Instance, part)
			end

			local raw = {}
			for _, record in if type(track.keys) == "table" then track.keys else {} do
				local key = if type(record) == "table" then fromKeyframe(record.data) else nil
				if type(key) == "table" and typeof(key.C0) == "CFrame" and type(record.frame) == "number" and not key.Disabled then
					table.insert(raw, { Frame = record.frame, Value = key.C0, Data = key })
					lastFrame = math.max(lastFrame, record.frame)
				end
			end

			if camera and part.Name == "FovPart" then
				if properties and type(properties.camera) == "table" and properties.camera.FieldOfView == false then
					continue
				end
				local default = defaultFov(entry, rig)
				local fov = {}
				for _, key in raw do
					table.insert(fov, { Frame = key.Frame, Value = math.clamp(default + key.Value.Y, 1, 120), Data = key.Data })
				end
				if #fov > 0 then
					item.Tracks.FieldOfView = keyframes(fov)
				end
				item.Defaults.FieldOfView = default
				continue
			end

			-- Eclipse's master control moves the whole rig: keys on its root part, which is then at
			-- rest * C0 * restC0:Inverse(), from where it rests (where it is now, unless Eclipse still
			-- has it moved by the C0 it's posed at). That's the rig's CFrame track.
			local masterRest = sequence:GetAttribute("EclipseMasterRest")
			if not motor and part:IsA("BasePart") and sequence:GetAttribute("EclipseMasterControl") == true and typeof(masterRest) == "CFrame" then
				local root = part :: BasePart
				local posed = rig:GetAttribute("EclipseMasterInput")
				local rest = if typeof(posed) == "CFrame" then root.CFrame * masterRest * posed:Inverse() else root.CFrame
				local pivot = if rig:IsA("Model") then root.CFrame:ToObjectSpace((rig :: Model):GetPivot()) else CFrame.new()
				local moved = {}
				for _, key in raw do
					table.insert(moved, { Frame = key.Frame, Value = rest * key.Value * masterRest:Inverse() * pivot, Data = key.Data })
				end
				if #moved > 0 then
					item.Tracks.CFrame = keyframes(moved)
				end
				continue
			end

			local rest = fromKeyframe(track.rest)
			if motor and (#raw > 0 or typeof(rest) == "CFrame") then
				table.insert(item.Joints, {
					Hier = {},
					Motor = motor,
					Keyed = "C0",
					Default = if typeof(rest) == "CFrame" then rest else nil,
					Track = keyframes(raw),
				})
			end
		end

		-- Events.
		local events = sequence:FindFirstChild("EclipseEvents")
		if events and events:GetAttribute("Enabled") ~= false then
			for _, node in events:GetChildren() do
				if node:IsA("Folder") then
					local marker = readEvent(node, rig, warnings, name)
					if marker then
						table.insert(item.Markers, marker)
						lastFrame = math.max(lastFrame, marker.Frame + marker.Width)
						for _, switch in marker.Switches or {} do
							table.insert(switches, { Frame = marker.Frame, Switch = switch })
						end
					end
				end
			end
			table.sort(item.Markers, function(a, b)
				return a.Frame < b.Frame
			end)
		end
	end

	if anim.Length <= 0 then
		anim.Length = lastFrame
	end

	-- What Enable and Disable rows switch is an Enabled track on each effect they switch, which the
	-- exporter replays like any keyed effect. Each one stays on until the animation ends, and what
	-- it gave off has time to fade once it's switched off.
	local tracks: { [Instance]: { SaveReader.Keyframe } } = {}
	table.sort(switches, function(a, b)
		return a.Frame < b.Frame
	end)
	for _, entry in switches do
		for _, effect in switchedBy(entry.Switch.Instance, entry.Switch.Mode) do
			tracks[effect] = tracks[effect] or {}
			table.insert(tracks[effect], { Time = entry.Frame, Value = entry.Switch.Enabled, Ease = { Type = "Constant", Params = {} } })
		end
	end
	for effect, track in tracks do
		local last = track[#track]
		local tail = 0
		if last.Value == false then
			local lifetime = (effect :: any).Lifetime
			tail = if typeof(lifetime) == "NumberRange" then lifetime.Max elseif type(lifetime) == "number" then lifetime else 0
			tail *= anim.FPS
		end
		local finish = if last.Value then math.max(anim.Length, last.Time) else last.Time + tail
		if finish > last.Time then
			table.insert(track, { Time = finish, Value = last.Value, Ease = { Type = "Constant", Params = {} } })
		end

		local item = byInstance[effect]
		if not item then
			local names, classes = pathOf(effect)
			item = {
				Index = #anim.Items + 1,
				Path = table.concat(names, "."),
				PathNames = names,
				PathTypes = classes,
				ItemType = effect.ClassName,
				Instance = effect,
				Tracks = {},
				Defaults = {},
				Markers = {},
				Joints = {},
			}
			table.insert(anim.Items, item)
			byInstance[effect] = item
		end
		local current = item :: SaveReader.Item
		current.Tracks.Enabled = track
		local ok, enabled = pcall(function()
			return (effect :: any).Enabled
		end)
		current.Defaults.Enabled = if ok then enabled else nil
	end

	return anim :: SaveReader.Animation
end

-- An outline of a project, for working out one this reader gets wrong.
function EclipseReader.dump(save: Instance): string
	local lines = { `Eclipse project: {save:GetFullName()}` }
	local attributes = {}
	for key, value in save:GetAttributes() do
		table.insert(attributes, `{key}={tostring(value)}`)
	end
	table.sort(attributes)
	table.insert(lines, "Attributes: " .. table.concat(attributes, ", "))

	local function walk(inst: Instance, depth: number)
		local children = inst:GetChildren()
		table.sort(children, function(a, b)
			return a.Name < b.Name
		end)
		for i, child in children do
			if i > (if depth <= 3 then 60 else 6) then
				table.insert(lines, `{string.rep("  ", depth)}... {#children - i + 1} more`)
				break
			end
			local text = `{string.rep("  ", depth)}{child.Name} [{child.ClassName}]`
			if child:IsA("ValueBase") then
				local value = string.gsub(tostring((child :: any).Value), "\n", "\\n")
				text ..= " = " .. (if #value > 90 then string.sub(value, 1, 90) .. "..." else value)
			end
			for key, value in child:GetAttributes() do
				text ..= ` @{key}={tostring(value)}`
			end
			table.insert(lines, text)
			if depth < 6 then
				walk(child, depth + 1)
			end
		end
	end
	walk(save, 1)
	return table.concat(lines, "\n")
end

return EclipseReader
