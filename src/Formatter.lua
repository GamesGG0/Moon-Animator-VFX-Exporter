--!strict
-- Writes cues as Lua source in this layout:
--
-- local Savage = {
-- 	Lifetime = 6,
-- 	CueTolerance = 0.15,
--
-- 	Cues = {
-- 		[0] =   { Effect = "Start",   Offset = CFrame.new(...) },
-- 		[27] =  { Effect = "Hit",     Offset = CFrame.new(...) },
-- 	},
-- }
--
-- The module is only data: the Sequence module plays it (keyframes, screen effects, Lighting and the
-- camera included), so a cue has a Function only for code someone wrote.

local Carryover = require(script.Parent.Carryover)

local Formatter = {}

export type Spec = {
	TableName: string,
	Lifetime: number,
	CueTolerance: number,
	Header: string?,
	-- Key cues by time in seconds (frame / FPS) instead of by frame number.
	Timestamps: boolean?,
	FPS: number?,
	-- Played by the Sequence module: write its FrameRate and how to play it.
	Runtime: boolean?,
	-- Exporter cues. Function is the source text of a cue's Function, carried over from the last
	-- export; Animation, Screen and Code are written as the fields the Sequence module plays.
	Cues: { any },
	-- Functions from the last export that no longer have a cue.
	Orphans: { { Key: string, Text: string } }?,
	-- The animation tool the file is from, for what the module says about it: "Moon" (the
	-- default) or "Eclipse".
	Source: string?,
}

local KEYWORDS = {}
for _, word in
	string.split(
		"and break continue do else elseif end false for function if in local nil not or repeat return then true until while",
		" "
	)
do
	KEYWORDS[word] = true
end

local function number(n: number): string
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	local text = string.format("%.9g", n)
	return if text == "-0" then "0" else text
end

function Formatter.cframe(cf: CFrame): string
	local parts = {}
	for _, component in { cf:GetComponents() } do
		local text = string.format("%.9g", component)
		table.insert(parts, if text == "-0" then "0" else text)
	end
	return `CFrame.new({table.concat(parts, ", ")})`
end

-- Frame 27 at 60 fps -> "0.45", frame 88 -> "1.4667": the fewest decimals (3 to 6) that keep the
-- time within 0.05 ms, trailing zeros dropped.
function Formatter.seconds(frame: number, fps: number): string
	local exact = frame / fps
	local text = ""
	for decimals = 3, 6 do
		text = string.format(`%.{decimals}f`, exact)
		if math.abs((tonumber(text) :: number) - exact) < 5e-5 then
			break
		end
	end
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- A value as Lua source, or nil for types the exporter can't write.
function Formatter.value(v: any): string?
	local kind = typeof(v)
	if kind == "number" then
		return number(v)
	elseif kind == "boolean" then
		return tostring(v)
	elseif kind == "string" then
		return string.format("%q", v)
	elseif kind == "Color3" then
		return `Color3.new({number(v.R)}, {number(v.G)}, {number(v.B)})`
	elseif kind == "UDim2" then
		return `UDim2.new({number(v.X.Scale)}, {number(v.X.Offset)}, {number(v.Y.Scale)}, {number(v.Y.Offset)})`
	elseif kind == "UDim" then
		return `UDim.new({number(v.Scale)}, {number(v.Offset)})`
	elseif kind == "Vector2" then
		return `Vector2.new({number(v.X)}, {number(v.Y)})`
	elseif kind == "Vector3" then
		return `Vector3.new({number(v.X)}, {number(v.Y)}, {number(v.Z)})`
	elseif kind == "Rect" then
		return `Rect.new({number(v.Min.X)}, {number(v.Min.Y)}, {number(v.Max.X)}, {number(v.Max.Y)})`
	elseif kind == "EnumItem" then
		return tostring(v)
	elseif kind == "CFrame" then
		return Formatter.cframe(v)
	elseif kind == "NumberRange" then
		return `NumberRange.new({number(v.Min)}, {number(v.Max)})`
	elseif kind == "BrickColor" then
		return `BrickColor.new({string.format("%q", v.Name)})`
	elseif kind == "ColorSequence" then
		local points = {}
		for _, point in v.Keypoints do
			table.insert(points, `ColorSequenceKeypoint.new({number(point.Time)}, {Formatter.value(point.Value)})`)
		end
		return `ColorSequence.new(\{ {table.concat(points, ", ")} })`
	elseif kind == "NumberSequence" then
		local points = {}
		for _, point in v.Keypoints do
			table.insert(points, `NumberSequenceKeypoint.new({number(point.Time)}, {number(point.Value)}, {number(point.Envelope)})`)
		end
		return `NumberSequence.new(\{ {table.concat(points, ", ")} })`
	elseif kind == "Font" then
		return `Font.new({string.format("%q", v.Family)}, {Formatter.value(v.Weight) or "Enum.FontWeight.Regular"}, {Formatter.value(v.Style) or "Enum.FontStyle.Normal"})`
	end
	return nil
end

-- A table of plain values (strings, numbers, booleans, and tables of them) as Lua source on one
-- line, its fields in `first` order and then by name.
local function plainTable(t: { [any]: any }, first: { string }?): string
	if #t > 0 then
		local items = {}
		for _, item in t do
			table.insert(items, if type(item) == "table" then plainTable(item) else Formatter.value(item) or "nil")
		end
		return `\{ {table.concat(items, ", ")} }`
	end
	local names = {}
	for name in t do
		table.insert(names, tostring(name))
	end
	local rank = {}
	for i, name in first or {} do
		rank[name] = i
	end
	table.sort(names, function(a, b)
		if (rank[a] or math.huge) ~= (rank[b] or math.huge) then
			return (rank[a] or math.huge) < (rank[b] or math.huge)
		end
		return a < b
	end)
	local fields = {}
	for _, name in names do
		local item = t[name]
		local text = if type(item) == "table" then plainTable(item) else Formatter.value(item) or "nil"
		local key = if string.match(name, "^[%a_][%w_]*$") and not KEYWORDS[name] then name else string.format("[%q]", name)
		table.insert(fields, `{key} = {text}`)
	end
	return if #fields > 0 then `\{ {table.concat(fields, ", ")} }` else "{}"
end

local function sortedKeys(t: { [string]: any }): { string }
	local names = {}
	for name in t do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Called with a property the module can't write, and the type of its value.
type Skipped = (string, string) -> ()

-- Keys as Lua source lines: Property = { { seconds, value, style, direction }, ... }, where a
-- Bezier key's direction is its control points: { seconds, value, "Bezier", { x1, y1, x2, y2 } }.
local function keysSource(keys: any, indent: string, skipped: Skipped?): { string }
	local lines = {}
	for _, name in sortedKeys(keys) do
		local parts = {}
		for _, key in keys[name] do
			local text = Formatter.value(key.Value)
			if not text then
				if skipped then
					skipped(name, typeof(key.Value))
				end
				parts = {}
				break
			end
			local entry = `\{ {number(key.Time)}, {text}`
			if key.Style == "Bezier" and type(key.Bezier) == "table" then
				local points = {}
				for i = 1, 4 do
					local point = string.format("%.4g", key.Bezier[i])
					table.insert(points, if point == "-0" then "0" else point)
				end
				entry ..= `, "Bezier", \{ {table.concat(points, ", ")} }`
			elseif key.Style and key.Style ~= "Linear" and key.Style ~= "Bezier" then
				entry ..= string.format(", %q", key.Style)
				if key.Direction then
					entry ..= string.format(", %q", key.Direction)
				end
			end
			table.insert(parts, entry .. " }")
		end
		if #parts > 0 then
			table.insert(lines, `{indent}{name} = \{ {table.concat(parts, ", ")} },`)
		end
	end
	return lines
end

-- Properties as Lua source lines: Property = value,
local function propertiesSource(properties: any, indent: string, skipped: Skipped?): { string }
	local lines = {}
	for _, name in sortedKeys(properties) do
		local text = Formatter.value(properties[name])
		if text then
			table.insert(lines, `{indent}{name} = {text},`)
		elseif skipped then
			skipped(name, typeof(properties[name]))
		end
	end
	return lines
end

-- A screen effect's pieces as Lua source lines at `indent`: each one's Name, ClassName, whether it
-- Mirrors the keyed piece, its look (Properties), its own pieces (Children) and keys (Keys).
local function childrenSource(children: { any }, indent: string, skipped: Skipped?): { string }
	local lines = {}
	for _, child in children do
		local open = string.format("%s{ Name = %q, ClassName = %q", indent, child.Name, child.ClassName)
		if child.Mirrors then
			open ..= ", Mirrors = true"
		end
		local function skippedHere(name: string, kind: string)
			if skipped then
				skipped(`{child.Name}.{name}`, kind)
			end
		end

		local parts = {}
		local properties = propertiesSource(child.Properties or {}, indent .. "\t", skippedHere)
		if #properties > 0 then
			table.insert(parts, { "Properties", properties })
		end
		local nested = if child.Children then childrenSource(child.Children, indent .. "\t", skipped) else {}
		if #nested > 0 then
			table.insert(parts, { "Children", nested })
		end
		local keys = if child.Keys then keysSource(child.Keys, indent .. "\t", skippedHere) else {}
		if #keys > 0 then
			table.insert(parts, { "Keys", keys })
		end

		if #parts == 0 then
			table.insert(lines, open .. " },")
		else
			local current = open
			for _, part in parts do
				table.insert(lines, `{current}, {part[1]} = \{`)
				for _, line in part[2] do
					table.insert(lines, line)
				end
				current = indent .. "}"
			end
			table.insert(lines, indent .. "} },")
		end
	end
	return lines
end

-- A table written over several lines, opening on the cue's line and closing at its indent.
local function block(lines: { string }): string
	return "{\n" .. table.concat(lines, "\n") .. "\n\t\t}"
end

-- Code with its `for ... in ipairs(t) do` and `for ... in pairs(t) do` loops written the Luau way,
-- `for ... in t do`, which goes over a table the same way.
function Formatter.withoutPairs(source: string): string
	local init = 1
	while true do
		local s, e = string.find(source, "%f[%w_]in%s+i?pairs%s*%(", init)
		if not s then
			break
		end

		-- The call's closing parenthesis, past strings.
		local depth, i, quote = 1, e + 1, nil
		while i <= #source and depth > 0 do
			local c = string.sub(source, i, i)
			if quote then
				if c == "\\" then
					i += 1
				elseif c == quote then
					quote = nil
				end
			elseif c == '"' or c == "'" then
				quote = c
			elseif c == "(" then
				depth += 1
			elseif c == ")" then
				depth -= 1
			end
			i += 1
		end

		local inner = string.sub(source, e + 1, i - 2)
		if depth == 0 and string.find(source, "^%s*do%f[^%w_]", i) and string.find(inner, "%S") then
			local replacement = "in " .. inner
			source = string.sub(source, 1, s - 1) .. replacement .. string.sub(source, i)
			init = s + #replacement
		else
			init = e + 1
		end
	end
	return source
end

-- What else goes into a cue's Function from an Eclipse event (see Exporter.Cue): the locals
-- Eclipse gives its code, its code for when it ends and how long after, and the tool's name.
export type CodeExtras = {
	Locals: { { Name: string, Value: string } }?,
	EndCode: string?,
	EndDelay: number?,
	Tool: string?,
}

-- The Function a cue whose event ran code in Moon gets. When the exporter could rewrite the code to
-- run in game (`adapted`, see Exporter.adaptCode), that's the Function. Otherwise it's the code
-- commented out, to adapt by hand: `missing` names what it used from the Moon scene, and it warns
-- (`label` names the cue) when it runs, rather than doing nothing quietly. `asset` is the VFX the
-- cue spawns, if any. An Eclipse event's code starts with the locals Eclipse gives it, and its end
-- code runs after the event's duration, unless the sequence stops first (`extras`). Either way its
-- loops don't use ipairs or pairs.
function Formatter.codeFunction(code: string, asset: string?, adapted: any?, missing: { string }?, label: string?, extras: CodeExtras?): string
	local more: CodeExtras = extras or {}
	local tool = more.Tool or "Moon"

	local function body(source: string, indent: string): { string }
		local lines = {}
		source = Formatter.withoutPairs(source)
		for _, line in string.split(string.gsub(string.gsub(source, "\r", ""), "%s+$", ""), "\n") do
			table.insert(lines, if string.find(line, "%S") then indent .. line else "")
		end
		return lines
	end

	-- The code itself: its locals, what it does when the event fires, and then when it ends.
	local function statements(begin: string, finish: string?): { string }
		local lines = {}
		for _, entry in more.Locals or {} do
			table.insert(lines, `\t\t\tlocal {entry.Name} = {entry.Value}`)
		end
		if string.find(begin, "%S") then
			for _, line in body(begin, "\t\t\t") do
				table.insert(lines, line)
			end
		end
		if finish then
			table.insert(lines, `\t\t\t-- When the event ends:`)
			table.insert(lines, `\t\t\tself:AddToCleaner(task.delay({number(more.EndDelay or 0)}, function()`)
			for _, line in body(finish, "\t\t\t\t") do
				table.insert(lines, line)
			end
			table.insert(lines, "\t\t\tend), math.huge)")
		end
		return lines
	end

	-- The markers say where the code is from (Carryover knows them by how they end).
	local function marker(text: string): string
		return (string.gsub(text, "in Moon", "in " .. tool, 1))
	end

	local lines = { "function(self, effect, character, cue, data)" }

	if adapted then
		table.insert(lines, `\t\t\t-- {marker(Carryover.ADAPTED_MARKER)}`)
		local uses = {}
		for _, use in adapted.Uses do
			table.insert(uses, `{use.From} is {use.To}`)
		end
		if #uses > 0 then
			table.insert(lines, `\t\t\t-- Of what it used in {tool}'s scene, {table.concat(uses, ", ")}.`)
		end
		-- It can only run with what it uses.
		if adapted.Effect then
			table.insert(lines, "\t\t\tif not effect then")
			table.insert(lines, "\t\t\t\treturn")
			table.insert(lines, "\t\t\tend")
		end
		for _, rig in adapted.Rigs do
			table.insert(lines, `\t\t\tif not (data and data.Rigs and data.Rigs[{string.format("%q", rig)}]) then`)
			table.insert(lines, "\t\t\t\treturn")
			table.insert(lines, "\t\t\tend")
		end
		for _, line in statements(adapted.Code, adapted.EndCode) do
			table.insert(lines, line)
		end
		table.insert(lines, "\t\tend")
		return table.concat(lines, "\n")
	end

	local commented = statements(code, more.EndCode)
	local text = table.concat(commented, "\n")
	local level = ""
	while string.find(text, "]" .. level .. "]", 1, true) do
		level ..= "="
	end
	table.insert(lines, `\t\t\t-- {marker(Carryover.CODE_MARKER)}`)
	table.insert(lines, if asset
		then `\t\t\t-- In game, effect is the spawned {string.format("%q", asset)} and character is the one playing the move.`
		else "\t\t\t-- In game, character is the one playing the move.")
	local uses = if missing and #missing > 0 then table.concat(missing, ", ") else "things"
	if missing and #missing > 0 then
		table.insert(lines, `\t\t\t-- It uses {uses} from your {tool} scene, which the game won't have: adapt that, then uncomment it.`)
	end
	local warning = `[Moon VFX] {label or "A cue"} runs event code from {tool} that uses {uses} from the {tool} scene, so it does nothing until it's adapted (see its Function).`
	table.insert(lines, `\t\t\twarn({string.format("%q", warning)})`)
	table.insert(lines, `\t\t\t--[{level}[`)
	for _, line in commented do
		table.insert(lines, line)
	end
	table.insert(lines, `\t\t\t]{level}]`)
	table.insert(lines, "\t\tend")
	return table.concat(lines, "\n")
end

-- A cue's key as written: its frame, or its time in seconds.
function Formatter.key(frame: number, timestamps: boolean?, fps: number?): string
	return if timestamps then Formatter.seconds(frame, fps or 60) else tostring(frame)
end

-- "Ripper Test" -> "RipperTest", "2nd move" -> "_2ndmove", "end" -> "_end"
function Formatter.identifier(name: string): string
	local id = string.gsub(name, "[^%w_]", "")
	if id == "" then
		return "VFX"
	end
	if string.match(id, "^%d") or KEYWORDS[id] then
		id = "_" .. id
	end
	return id
end

-- The keyframed effects that play on Lighting or the camera instead of a VFX: their cue's Target.
local TARGETS = { Lighting = true, Camera = true, Shake = true }

-- Whether a cue spawns a VFX (and so has an Offset). Subtitles and screen, Lighting and camera
-- effects don't, and neither does an event that only ran code.
local function spawnsVfx(cue: any): boolean
	if cue.Screen or cue.Subtitle or (cue.Animation and TARGETS[cue.Animation.Kind]) then
		return false
	end
	return not (cue.Code and not cue.Asset)
end

-- The short fields written on the cue's first line, before its Offset.
local function headFields(cue: any): { string }
	-- Object is only written when the effect's name isn't already its VFX's name.
	local head = { string.format("Effect = %q", cue.Effect) }
	if cue.Asset and cue.Asset ~= cue.Effect then
		table.insert(head, string.format("Object = %q", cue.Asset))
	end
	if cue.Parent then
		table.insert(head, string.format("Parent = %q", cue.Parent))
	end
	if cue.Rig then
		table.insert(head, string.format("Rig = %q", cue.Rig))
	end
	if cue.Screen then
		table.insert(head, string.format("Screen = %q", cue.Screen.ClassName))
	end
	if cue.Animation and TARGETS[cue.Animation.Kind] then
		table.insert(head, string.format("Target = %q", cue.Animation.Kind))
	end
	local hold = (cue.Animation and cue.Animation.Hold) or (cue.Screen and cue.Screen.Hold)
	if hold then
		table.insert(head, `Hold = {number(hold)}`)
	end
	if cue.Animation and cue.Animation.Kind == "Shake" then
		table.insert(head, `Seed = {number(cue.Animation.Seed or 0)}`)
		table.insert(head, `Phase = {number(cue.Animation.Phase or 0)}`)
	end
	if cue.Screen and cue.Screen.ScaleText then
		table.insert(head, "ScaleText = true")
	end
	if cue.Lifetime then
		table.insert(head, `Lifetime = {number(cue.Lifetime)}`)
	end
	if cue.EmitCount then
		table.insert(head, `EmitCount = {number(cue.EmitCount)}`)
	end
	return head
end

-- A subtitle's data (see Exporter.subtitleCue) as Lua source lines: its timing and motions, then its
-- style, then its keys, one a line.
local function subtitleSource(subtitle: any, indent: string): { string }
	local timing = {}
	for _, name in { "Duration", "In", "Out", "Entrance", "Exit", "Order" } do
		if subtitle[name] ~= nil then
			table.insert(timing, `{name} = {Formatter.value(subtitle[name])}`)
		end
	end
	local lines = { `{indent}{table.concat(timing, ", ")},` }
	table.insert(lines, `{indent}Style = {plainTable(subtitle.Style or {}, { "Text", "Speaker" })},`)
	if subtitle.Keys and #subtitle.Keys > 0 then
		table.insert(lines, `{indent}Keys = \{`)
		for _, key in subtitle.Keys do
			table.insert(lines, `{indent}\t\{ {number(key[1])}, {plainTable(key[2], { "Text", "Speaker" })}, {string.format("%q", key[3])} },`)
		end
		table.insert(lines, `{indent}},`)
	end
	return lines
end

-- The emitter every cue's VFX can share (see Exporter.Cue's Emitter): the module the events
-- emitted with, when they all used the same one and no cue's VFX was emitted another way (with VFX
-- Forge, or by Eclipse, which the Sequence's own emit does).
local function sharedEmitter(cues: { any }): { Name: string, Module: string }?
	local shared = nil
	for _, cue in cues do
		if cue.DefaultEmit then
			return nil
		end
		if type(cue.Emitter) == "table" then
			if shared and shared.Name ~= cue.Emitter.Name then
				return nil
			end
			shared = cue.Emitter
		end
	end
	return shared
end

-- The fields after the Offset: what the Sequence plays (Path, Properties, Keys), how it emits the
-- cue's VFX when that isn't the table's way, and the Function. `label` names the cue in warnings;
-- `warn` is told what couldn't be written; `tool` is where the animation was made; `shared` is the
-- emit the table gives every cue, if any.
local function tailFields(cue: any, label: string, warn: (string) -> (), tool: string?, shared: string?): { string }
	local tail = {}
	local keys = nil
	local function skippedKeys(name: string, kind: string)
		warn(`{label}'s {name} keys are {kind} values, which can't be exported, so they're left out.`)
	end
	local function skippedProperty(name: string, kind: string)
		warn(`{label}'s {name} is a {kind}, which can't be exported, so it's left out of its look.`)
	end
	if cue.Subtitle then
		table.insert(tail, "Subtitle = " .. block(subtitleSource(cue.Subtitle, "\t\t\t")))
	elseif cue.Screen then
		local properties = propertiesSource(cue.Screen.Properties, "\t\t\t", skippedProperty)
		if #properties > 0 then
			table.insert(tail, "Properties = " .. block(properties))
		end
		if cue.Screen.Children then
			table.insert(tail, "Children = " .. block(childrenSource(cue.Screen.Children, "\t\t\t", skippedProperty)))
		end
		local path = cue.Screen.Path
		if path and #path > 0 then
			local names = {}
			for _, name in path do
				table.insert(names, string.format("%q", name))
			end
			table.insert(tail, `Path = \{ {table.concat(names, ", ")} }`)
		end
		keys = cue.Screen.Keys
	elseif cue.Animation then
		local path = cue.Animation.Path
		if path and #path > 0 then
			local names = {}
			for _, name in path do
				table.insert(names, string.format("%q", name))
			end
			table.insert(tail, `Path = \{ {table.concat(names, ", ")} }`)
		end
		keys = cue.Animation.Keys
	end
	if keys then
		local lines = keysSource(keys, "\t\t\t", skippedKeys)
		if #lines > 0 then
			table.insert(tail, "Keys = " .. block(lines))
		end
	end

	if cue.Emitter == false then
		table.insert(tail, "Emitter = false")
	elseif type(cue.Emitter) == "table" and cue.Emitter.Name ~= shared then
		table.insert(tail, string.format("Emitter = %q", cue.Emitter.Name))
	end

	if cue.Function then
		table.insert(tail, `Function = {Formatter.withoutPairs(cue.Function)}`)
	elseif cue.Code then
		local extras = { Locals = cue.Locals, EndCode = cue.EndCode, EndDelay = cue.EndDelay, Tool = tool }
		table.insert(tail, `Function = {Formatter.codeFunction(cue.Code, cue.Asset, cue.Adapted, cue.CodeMissing, label, extras)}`)
	end
	return tail
end

-- Lines of a comment listing `words`, wrapped.
local function wrapped(prefix: string, words: { string }): { string }
	local lines = {}
	local line = prefix
	for i, word in words do
		local piece = word .. (if i < #words then "," else "")
		if #line + #piece + 1 > 100 and line ~= prefix then
			table.insert(lines, line)
			line = "--  "
		end
		line ..= " " .. piece
	end
	table.insert(lines, line)
	return lines
end

-- How to play the module with the Sequence module.
local function usage(spec: Spec, name: string): { string }
	local lines = {
		"-- Play it on the client (from a LocalScript) with the Sequence module that comes with it. On the",
		"-- server, sequence:Play only warns: VFX play on clients, each on the character doing the move.",
		`--   local sequence = Sequence.new({name}, character)`,
		"--   track:Play()",
		"--   sequence:Play(track, data, VFX)",
		"-- track is optional (without it, the cues play by the clock), and so is data, which every cue's",
		"-- Function gets. VFX holds the objects the cues use, by name: this module's VFX folder, or a table",
		"-- like { Shine = Resources.VFX.Shine }. sequence:Stop() ends it early and removes all it spawned.",
		"-- For another frame rate or tolerance than the FrameRate and CueTolerance below, pass them too:",
		`--   Sequence.new({name}, character, frameRate, tolerance)`,
	}

	local assets: { string } = {}
	local rig: string? = nil
	local screen = false
	for _, cue in spec.Cues do
		if cue.Asset and spawnsVfx(cue) and not table.find(assets, cue.Asset) then
			table.insert(assets, cue.Asset)
		end
		rig = rig or cue.Rig
		screen = screen or cue.Screen ~= nil or cue.Subtitle ~= nil or (cue.Animation ~= nil and TARGETS[cue.Animation.Kind] == true)
	end

	if rig then
		table.insert(lines, "--")
		table.insert(lines, `-- Cues with a Rig were on another rig in {spec.Source or "Moon"}. Give its character in data.Rigs:`)
		table.insert(lines, `--   sequence:Play(track, \{ Rigs = \{ ["{rig}"] = victim } }, VFX)`)
	end
	if screen then
		table.insert(lines, "--")
		table.insert(lines, "-- Screen, Lighting and camera effects show only for the player whose character played them.")
	end

	table.insert(lines, "--")
	table.insert(lines, "-- Any cue can take Function = function(self, effect, character, cue, data) ... end. It runs")
	table.insert(lines, "-- when the cue fires, right after its VFX spawns (effect is nil if it has none), and it's kept")
	table.insert(lines, "-- when the animation is exported again. self is the sequence: self:AddToCleaner(thing) has it")
	table.insert(lines, "-- clean up something the Function makes, along with its VFX.")

	if #assets > 0 then
		table.sort(assets)
		table.insert(lines, "--")
		for _, line in wrapped("-- VFX it uses:", assets) do
			table.insert(lines, line)
		end
	end
	return lines
end

-- The module's source, and warnings about what in the cues it couldn't write.
function Formatter.format(spec: Spec): (string, { string })
	local name = spec.TableName
	local warnings = {}
	local function warn(message: string)
		table.insert(warnings, message)
	end

	local lines = {}
	local function add(line: string)
		table.insert(lines, line)
	end

	if spec.Header then
		add(`-- {spec.Header}`)
	end
	if spec.Runtime then
		for _, line in usage(spec, name) do
			add(line)
		end
	end
	if spec.Header or spec.Runtime then
		add("")
	end

	if spec.Runtime then
		-- Declared first, so a cue's Function can refer to the table by name: inside
		-- `local X = { ... }` the name doesn't exist yet.
		add(`local {name}`)
		add(`{name} = \{`)
	else
		add(`local {name} = \{`)
	end
	add(`\tLifetime = {number(spec.Lifetime)},`)
	add(`\tCueTolerance = {number(spec.CueTolerance)},`)
	if spec.Runtime and not spec.Timestamps then
		-- Cue keys are frames at this rate.
		add(`\tFrameRate = {number(spec.FPS or 60)},`)
	end
	-- How the events emitted their VFX, when it was a module's emit method: the Sequence emits every
	-- cue's VFX the same way, so no cue needs a Function for it.
	local shared = sharedEmitter(spec.Cues)
	if shared then
		add(`\t-- {spec.Source or "Moon"}'s events emitted their VFX with {shared.Module}, so the Sequence emits each cue's VFX with it too.`)
		add(string.format("\tEmitter = %q,", shared.Name))
	end
	add("")

	if #spec.Cues == 0 then
		add("\tCues = {},")
	else
		local keys, heads, spawns = {}, {}, {}
		local keyWidth, headWidth = 0, 0

		for i, cue in spec.Cues do
			keys[i] = `[{Formatter.key(cue.Frame, spec.Timestamps, spec.FPS)}] =`
			heads[i] = table.concat(headFields(cue), ", ")
			spawns[i] = spawnsVfx(cue)
			keyWidth = math.max(keyWidth, #keys[i])
			if spawns[i] then
				headWidth = math.max(headWidth, #heads[i])
			end
		end

		add("\tCues = {")
		for i, cue in spec.Cues do
			local line = `\t\t{keys[i]}{string.rep(" ", keyWidth - #keys[i] + 1)}\{ {heads[i]}`
			-- Offsets line up, so a cue's other fields read as a column.
			if spawns[i] then
				line ..= `,{string.rep(" ", headWidth - #heads[i] + 1)}Offset = {Formatter.cframe(cue.Offset)}`
			end
			local label = `Cue {keys[i]:sub(1, -3)} "{cue.Effect}"`
			for _, field in tailFields(cue, label, warn, spec.Source, shared and shared.Name) do
				line ..= ", " .. field
			end
			line ..= " },"

			if cue.Notes and #cue.Notes > 0 then
				line ..= " -- " .. table.concat(cue.Notes, "; ")
			end
			add(line)
		end
		add("\t},")
	end

	add("}")
	add("")

	-- Functions from the last export whose cue is gone, kept so the code isn't lost.
	if spec.Orphans and #spec.Orphans > 0 then
		local body = {}
		for _, orphan in spec.Orphans do
			table.insert(body, `[{orphan.Key}] = \{ Function = {orphan.Text} },`)
		end
		local text = table.concat(body, "\n")
		local level = ""
		while string.find(text, "]" .. level .. "]", 1, true) do
			level ..= "="
		end
		add("-- These Functions were on cues that are gone since the last export. Put them on a cue to use them.")
		-- (Carryover.ORPHAN_MARKER matches the first sentence, so they survive the next export too.)
		add(`--[{level}[`)
		for _, line in string.split(text, "\n") do
			add(line)
		end
		add(`]{level}]`)
		add("")
	end

	add(`return {name}`)
	add("")

	return table.concat(lines, "\n"), warnings
end

return Formatter
