--!strict
-- Reads Moon Animator 2 save files.
--
-- A save is a StringValue (normally in ServerStorage.MoonAnimator2Saves) whose Value is JSON:
--   { Information = { Length, FPS, Looped, Modified, ... }, Items = { { Path = {...} }, ... } }
-- Keyframe data lives in children named after each item's index:
--   <save>/<itemIndex>/<PropertyName>/<frame>/Values/<n>   value at frame + n
--   <save>/<itemIndex>/<PropertyName>/<frame>/Eases/<n>    { Type, Params }
--   <save>/<itemIndex>/MarkerTrack/<frame>                 an event: name, width, code...

local SaveReader = {}

export type Keyframe = {
	Time: number,
	Value: any,
	Ease: { Type: string?, Params: { [string]: any }? }?,
}

export type Marker = {
	Frame: number,
	Name: string,
	Width: number,
	Code: { string },
	-- Key/value pairs from the event's "Events" tab, e.g. Parent = "Right Arm".
	Keys: { [string]: string },
}

-- A rig joint's keyframes. Hier is the chain of parts from the root, e.g. "Torso.Right Arm";
-- the keyed values are the joint's C1.
export type Joint = {
	Hier: { string },
	Default: CFrame?,
	Track: { Keyframe },
}

export type Item = {
	Index: number,
	Path: string,
	PathNames: { string },
	ItemType: string,
	Instance: Instance?,
	Tracks: { [string]: { Keyframe } },
	Markers: { Marker },
	Joints: { Joint },
}

export type SaveEntry = {
	Save: StringValue,
	Name: string,
	Length: number,
	FPS: number,
	Modified: number?,
}

export type Animation = SaveEntry & {
	Items: { Item },
}

local SAVE_FOLDER = "MoonAnimator2Saves"

local function decode(json: string): any
	return game:GetService("HttpService"):JSONDecode(json)
end

local function lower(s: string): string
	return string.lower(s)
end

local function findChildNoCase(parent: Instance, name: string): Instance?
	local want = lower(name)
	for _, child in parent:GetChildren() do
		if lower(child.Name) == want then
			return child
		end
	end
	return nil
end

-- Reads a named field stored either as a ValueBase child or an attribute.
local function readField(parent: Instance, name: string): any
	local child = findChildNoCase(parent, name)
	if child and child:IsA("ValueBase") then
		return (child :: any).Value
	end

	local want = lower(name)
	for key, value in parent:GetAttributes() do
		if lower(key) == want then
			return value
		end
	end

	return nil
end

local function readValue(valueInst: Instance): any
	if valueInst:IsA("ValueBase") then
		return (valueInst :: any).Value
	end
	return valueInst:GetAttribute("Value")
end

local function parseEase(easeInst: Instance)
	local typeInst = easeInst:FindFirstChild("Type")
	local ease = {
		Type = if typeInst and typeInst:IsA("ValueBase") then tostring((typeInst :: any).Value) else "Linear",
		Params = {},
	}

	local params = easeInst:FindFirstChild("Params")
	if params then
		for _, param in params:GetChildren() do
			if param:IsA("ValueBase") then
				ease.Params[param.Name] = (param :: any).Value
			end
		end
	end

	return ease
end

-- Older saves stored a single Style/Direction pair.
local function parseLegacyEase(easeInst: Instance)
	local style = easeInst:FindFirstChild("Style")
	local direction = easeInst:FindFirstChild("Direction")
	return {
		Type = if style and style:IsA("ValueBase") then tostring((style :: any).Value) else "Linear",
		Params = {
			Direction = if direction and direction:IsA("ValueBase") then tostring((direction :: any).Value) else nil,
		},
	}
end

function SaveReader.readTrack(folder: Instance): { Keyframe }
	local sequence = {}

	for _, pack in folder:GetChildren() do
		local baseFrame = tonumber(pack.Name)
		local valuesBin = pack:FindFirstChild("Values")
		if not (baseFrame and valuesBin) then
			continue
		end

		local values = {}
		local maxIndex = -1
		for _, valueInst in valuesBin:GetChildren() do
			local index = tonumber(valueInst.Name)
			if index then
				local ok, value = pcall(readValue, valueInst)
				if ok and value ~= nil then
					values[index] = value
					maxIndex = math.max(maxIndex, index)
				end
			end
		end

		local eases = {}
		local easesBin = pack:FindFirstChild("Eases")
		local legacyEase = pack:FindFirstChild("Ease")
		if easesBin then
			for _, easeInst in easesBin:GetChildren() do
				local index = tonumber(easeInst.Name)
				if index then
					eases[index] = parseEase(easeInst)
				end
			end
		elseif legacyEase then
			eases[maxIndex] = parseLegacyEase(legacyEase)
		end

		-- A pack can hold several consecutive frames; an ease carries forward until replaced.
		local lastEase = nil
		for i = 0, maxIndex do
			local ease = eases[i] or lastEase
			if values[i] ~= nil then
				table.insert(sequence, {
					Time = baseFrame + i,
					Value = values[i],
					Ease = ease,
				})
				lastEase = ease
			end
		end
	end

	table.sort(sequence, function(a, b)
		return a.Time < b.Time
	end)

	return sequence
end

local function isMarkerTrack(folder: Instance): boolean
	local name = lower(folder.Name)
	if string.find(name, "marker", 1, true) or string.find(name, "event", 1, true) then
		return true
	end

	for _, child in folder:GetChildren() do
		if tonumber(child.Name) and not child:FindFirstChild("Values") and findChildNoCase(child, "width") then
			return true
		end
	end

	return false
end

local function collectCode(marker: Instance): { string }
	local code = {}

	local function visit(inst: Instance)
		for _, child in inst:GetChildren() do
			local childName = lower(child.Name)
			if childName == "name" or childName == "kfmarkers" then
				continue
			end

			if child:IsA("StringValue") and (child :: StringValue).Value ~= "" then
				table.insert(code, (child :: StringValue).Value)
			end
			visit(child)
		end
	end

	visit(marker)

	for key, value in marker:GetAttributes() do
		if type(value) == "string" and value ~= "" and lower(key) ~= "name" then
			table.insert(code, value)
		end
	end

	return code
end

-- The "Events" tab of Moon's Edit Events window: KFMarkers/<n> holds a key, its Val child the value.
local function readKeys(marker: Instance): { [string]: string }
	local keys = {}
	local bin = findChildNoCase(marker, "KFMarkers")
	if bin then
		for _, entry in bin:GetChildren() do
			local val = entry:FindFirstChild("Val")
			if entry:IsA("ValueBase") and val and val:IsA("ValueBase") then
				local key = tostring((entry :: any).Value)
				if key ~= "" then
					keys[key] = tostring((val :: any).Value)
				end
			end
		end
	end
	return keys
end

-- A rig's joints: Rig/_joint/{_hier, default, _keyframes}.
function SaveReader.readJoints(rigFolder: Instance): { Joint }
	local joints = {}
	for _, jointInst in rigFolder:GetChildren() do
		local hier = jointInst:FindFirstChild("_hier")
		local keyframes = jointInst:FindFirstChild("_keyframes")
		if not (hier and hier:IsA("StringValue") and keyframes) then
			continue
		end

		local default = jointInst:FindFirstChild("default")
		table.insert(joints, {
			Hier = string.split((hier :: StringValue).Value, "."),
			Default = if default and default:IsA("CFrameValue") then (default :: CFrameValue).Value else nil,
			Track = SaveReader.readTrack(keyframes),
		})
	end
	return joints
end

function SaveReader.readMarkers(folder: Instance): { Marker }
	local markers = {}

	for _, markerInst in folder:GetChildren() do
		local frame = tonumber(markerInst.Name) or tonumber(readField(markerInst, "frame"))
		if not frame then
			continue
		end

		local name = readField(markerInst, "name")
		table.insert(markers, {
			Frame = frame,
			Name = if type(name) == "string" then name else "",
			Width = tonumber(readField(markerInst, "width")) or 0,
			Code = collectCode(markerInst),
			Keys = readKeys(markerInst),
		})
	end

	table.sort(markers, function(a, b)
		return a.Frame < b.Frame
	end)

	return markers
end

local function tryResolve(path: any, startIndex: number): Instance?
	local names = path.InstanceNames
	local types = path.InstanceTypes or {}
	local current: Instance = game

	for i = startIndex, #names do
		local name = names[i]
		local wantClass = types[i]
		local nextInst: Instance? = nil

		-- Prefer the child whose class also matches, in case of duplicate names.
		for _, child in current:GetChildren() do
			if child.Name == name then
				if child.ClassName == wantClass then
					nextInst = child
					break
				end
				nextInst = nextInst or child
			end
		end

		if not nextInst then
			return nil
		end
		current = nextInst
	end

	return if current ~= game then current else nil
end

function SaveReader.resolvePath(path: any): Instance?
	if type(path) ~= "table" or type(path.InstanceNames) ~= "table" then
		return nil
	end

	-- InstanceNames[1] is normally the DataModel itself.
	return tryResolve(path, 2) or tryResolve(path, 1)
end

local function entryFromData(save: StringValue, data: any): SaveEntry
	local info = data.Information
	local modified = tonumber(info.Modified)
	if modified and modified > 1e12 then
		modified /= 1000 -- milliseconds
	end

	return {
		Save = save,
		Name = save.Name,
		Length = tonumber(info.Length) or 0,
		FPS = tonumber(info.FPS) or 60,
		Modified = modified,
	}
end

local function decodeSave(save: Instance): any
	if not save:IsA("StringValue") then
		return nil
	end

	local json = (save :: StringValue).Value
	if string.sub(json, 1, 1) ~= "{" then
		return nil
	end

	local ok, data = pcall(decode, json)
	if ok and type(data) == "table" and type(data.Items) == "table" and type(data.Information) == "table" then
		return data
	end

	return nil
end

-- Lists every Moon Animator 2 save in the place, most recently modified first. Moon's own
-- autosaves (MoonAnimator2Saves.Autosaves) are left out.
function SaveReader.findSaves(): { SaveEntry }
	local ServerStorage = game:GetService("ServerStorage")
	local root = ServerStorage:FindFirstChild(SAVE_FOLDER)
	local candidates = if root then root:GetDescendants() else ServerStorage:GetDescendants()

	local saves = {}
	for _, inst in candidates do
		if inst:FindFirstAncestor("Autosaves") then
			continue
		end
		local data = decodeSave(inst)
		if data then
			table.insert(saves, entryFromData(inst :: StringValue, data))
		end
	end

	table.sort(saves, function(a, b)
		if (a.Modified or 0) ~= (b.Modified or 0) then
			return (a.Modified or 0) > (b.Modified or 0)
		end
		return a.Name < b.Name
	end)

	return saves
end

function SaveReader.load(save: StringValue): Animation
	local data = decodeSave(save)
	if not data then
		error(`"{save.Name}" is not a Moon Animator 2 save`, 0)
	end

	local anim = entryFromData(save, data) :: any
	anim.Items = {}

	for index, itemData in data.Items do
		local path = itemData.Path or {}
		local names = if type(path.InstanceNames) == "table" then path.InstanceNames else {}

		local item: Item = {
			Index = index,
			Path = table.concat(names, "."),
			PathNames = names,
			ItemType = tostring(path.ItemType or "?"),
			Instance = SaveReader.resolvePath(path),
			Tracks = {},
			Markers = {},
			Joints = {},
		}

		local folder = save:FindFirstChild(tostring(index))
		if folder then
			for _, child in folder:GetChildren() do
				if child.Name == "Rig" then
					item.Joints = SaveReader.readJoints(child)
				elseif isMarkerTrack(child) then
					for _, marker in SaveReader.readMarkers(child) do
						table.insert(item.Markers, marker)
					end
				else
					local track = SaveReader.readTrack(child)
					if #track > 0 then
						item.Tracks[child.Name] = track
					end
				end
			end
		end

		table.insert(anim.Items, item)
	end

	return anim :: Animation
end

-- Human-readable outline of a save, for diagnosing files this reader doesn't understand.
function SaveReader.dump(save: StringValue): string
	local lines = {}
	local function add(line: string)
		table.insert(lines, line)
	end

	local function describe(inst: Instance): string
		local text = `{inst.Name} [{inst.ClassName}]`
		if inst:IsA("ValueBase") then
			local value = string.gsub(tostring((inst :: any).Value), "\n", "\\n")
			if #value > 90 then
				value = string.sub(value, 1, 90) .. "..."
			end
			text ..= ` = {value}`
		end

		for key, value in inst:GetAttributes() do
			text ..= ` @{key}={tostring(value)}`
		end

		return text
	end

	local function walk(inst: Instance, depth: number)
		local children = inst:GetChildren()
		table.sort(children, function(a, b)
			local na, nb = tonumber(a.Name), tonumber(b.Name)
			if na and nb then
				return na < nb
			end
			return a.Name < b.Name
		end)

		local limit = if depth <= 2 then math.huge else 4
		for i, child in children do
			if i > limit then
				add(`{string.rep("  ", depth)}... {#children - limit} more`)
				break
			end

			add(string.rep("  ", depth) .. describe(child))
			if depth < 7 then
				walk(child, depth + 1)
			end
		end
	end

	add(`Moon save: {save:GetFullName()}`)

	local data = decodeSave(save)
	if data then
		local info = {}
		for key, value in data.Information do
			table.insert(info, `{key}={tostring(value)}`)
		end
		table.sort(info)
		add("Information: " .. table.concat(info, ", "))

		for index, itemData in data.Items do
			local path = itemData.Path or {}
			local names = if type(path.InstanceNames) == "table" then table.concat(path.InstanceNames, ".") else "?"
			add(`Item {index}: {names} [{tostring(path.ItemType)}]`)
		end
	else
		add("(Value is not valid Moon Animator 2 JSON)")
	end

	add("Children:")
	walk(save, 1)

	return table.concat(lines, "\n")
end

return SaveReader
