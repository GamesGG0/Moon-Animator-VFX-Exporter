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
-- With Runtime on, the module also gets Emit/Spawn/Play functions that play the VFX in time with
-- an AnimationTrack, using the Sequence module and VFX folder exported alongside it.

local Formatter = {}

export type Spec = {
	TableName: string,
	Lifetime: number,
	CueTolerance: number,
	Header: string?,
	-- Key cues by time in seconds (frame / FPS) instead of by frame number.
	Timestamps: boolean?,
	FPS: number?,
	-- Add the functions that play the cues.
	Runtime: boolean?,
	-- Function is the source text of a cue's Function, carried over from the last export.
	Cues: { { Frame: number, Effect: string, Offset: CFrame, Notes: { string }?, Asset: string?, Parent: string?, Function: string? } },
	-- Functions from the last export that no longer have a cue.
	Orphans: { { Key: string, Text: string } }?,
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

-- Locals the runtime code declares; the table can't share their names.
local RUNTIME_NAMES = { Debris = true, Sequence = true, VFX = true }

local RUNTIME_HEADER = [[
local Debris = game:GetService("Debris")
local Sequence = require(script.Sequence)

local VFX = script.VFX
]]

local RUNTIME = [[
-- Emits the effects in a spawned VFX object. ParticleEmitters use their EmitCount, EmitDelay and
-- EmitDuration attributes when they have them. To use your own emitter instead:
--   NAME.Emit = shared.vfx.emit
function NAME.Emit(object: Instance)
	local items = object:GetDescendants()
	table.insert(items, object)

	for _, item in items do
		if item:IsA("ParticleEmitter") then
			local count = tonumber(item:GetAttribute("EmitCount")) or math.max(1, math.round(item.Rate))
			local delay = tonumber(item:GetAttribute("EmitDelay")) or 0
			local duration = tonumber(item:GetAttribute("EmitDuration"))

			task.delay(delay, function()
				if duration then
					item.Enabled = true
					task.delay(duration, function()
						item.Enabled = false
					end)
				else
					item:Emit(count)
				end
			end)
		elseif item:IsA("Sound") then
			item:Play()
		end
	end
end

-- Spawns one cue's VFX and removes it after Lifetime seconds, then runs the cue's Function if it
-- has one. The VFX is placed at Offset from the HumanoidRootPart, or, for a cue with a Parent,
-- from that part or attachment of the character, and attached to it so it follows.
function NAME.Spawn(character: Model, root: BasePart, cue)
	local anchorCFrame, anchorPart, follow = root.CFrame, root, false
	if cue.Parent then
		local found = character:FindFirstChild(cue.Parent, true)
		if found and found:IsA("BasePart") then
			anchorCFrame, anchorPart, follow = found.CFrame, found, true
		elseif found and found:IsA("Attachment") and found.Parent and found.Parent:IsA("BasePart") then
			anchorCFrame, anchorPart, follow = found.WorldCFrame, found.Parent, true
		else
			warn(`[NAME] {character:GetFullName()} has no part or attachment named "{cue.Parent}"; using the HumanoidRootPart`)
		end
	end

	local effect = nil
	local name = cue.Object or cue.Effect
	local template = VFX:FindFirstChild(name)
	if template then
		effect = template:Clone()
		local cframe = anchorCFrame * cue.Offset

		if effect:IsA("Attachment") then
			-- An attachment lives on a part, so it goes on the one it's measured from.
			effect.Parent = anchorPart
			effect.WorldCFrame = cframe
		else
			if effect:IsA("Model") then
				effect:PivotTo(cframe)
			elseif effect:IsA("BasePart") then
				effect.CFrame = cframe
			end
			effect.Parent = workspace

			if follow then
				local parts = effect:GetDescendants()
				table.insert(parts, effect)
				for _, part in parts do
					if part:IsA("BasePart") then
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = anchorPart
						weld.Part1 = part
						weld.Parent = part
						part.Anchored = false
						part.Massless = true
					end
				end
			end
		end

		NAME.Emit(effect)
		Debris:AddItem(effect, NAME.Lifetime)
	elseif not cue.Function then
		warn(`[NAME] No VFX named "{name}" in {VFX:GetFullName()}`)
	end

	if cue.Function then
		cue.Function(effect, character, cue)
	end
	return effect
end

-- Plays the VFX in time with `track`, the character's AnimationTrack for this move. Call it right
-- after track:Play(). Returns the Sequence; call :Stop() on it to cancel the remaining VFX.
function NAME.Play(character: Model, track: AnimationTrack)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		warn(`[NAME] {character:GetFullName()} has no HumanoidRootPart`)
		return nil
	end

	local steps = {}
	for key, cue in NAME.Cues do
		steps[key] = function()
			NAME.Spawn(character, root, cue)
		end
	end

	-- FrameRate is left out when cue keys are in seconds.
	local sequence = Sequence.new(steps, NAME.FrameRate or 1, NAME.CueTolerance)
	sequence:Play(track)
	return sequence
end
]]

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

function Formatter.format(spec: Spec): string
	local name = spec.TableName
	if spec.Runtime and RUNTIME_NAMES[name] then
		name ..= "Cues"
	end

	local lines = {}
	local function add(line: string)
		table.insert(lines, line)
	end

	if spec.Header then
		add(`-- {spec.Header}`)
	end

	if spec.Runtime then
		add("-- Usage:")
		add("--   track:Play()")
		add(`--   {name}.Play(character, track)`)
		add("--")
		add("-- Any cue can also take Function = function(effect, character, cue) ... end. It runs when")
		add("-- the cue fires, right after its VFX spawns (effect is nil if the cue has none), and it's")
		add("-- kept when the animation is exported again.")
		add("")
		for _, line in string.split(RUNTIME_HEADER, "\n") do
			add(line)
		end
	end

	add(`local {name} = \{`)
	add(`\tLifetime = {number(spec.Lifetime)},`)
	add(`\tCueTolerance = {number(spec.CueTolerance)},`)
	if spec.Runtime and not spec.Timestamps then
		-- Cue keys are frames at this rate.
		add(`\tFrameRate = {number(spec.FPS or 60)},`)
	end
	add("")

	if #spec.Cues == 0 then
		add("\tCues = {},")
	else
		local keys, fields = {}, {}
		local keyWidth, fieldWidth = 0, 0

		for i, cue in spec.Cues do
			keys[i] = `[{Formatter.key(cue.Frame, spec.Timestamps, spec.FPS)}] =`

			-- Object is only written when the effect's name isn't already its VFX object's name.
			fields[i] = string.format("Effect = %q,", cue.Effect)
			if cue.Asset and cue.Asset ~= cue.Effect then
				fields[i] ..= string.format(" Object = %q,", cue.Asset)
			end
			if cue.Parent then
				fields[i] ..= string.format(" Parent = %q,", cue.Parent)
			end

			keyWidth = math.max(keyWidth, #keys[i])
			fieldWidth = math.max(fieldWidth, #fields[i])
		end

		add("\tCues = {")
		for i, cue in spec.Cues do
			local key = keys[i] .. string.rep(" ", keyWidth - #keys[i] + 1)
			local field = fields[i] .. string.rep(" ", fieldWidth - #fields[i] + 1)
			local line = `\t\t{key}\{ {field}Offset = {Formatter.cframe(cue.Offset)}`
			if cue.Function then
				line ..= `, Function = {cue.Function}`
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

	if spec.Runtime then
		for _, line in string.split((string.gsub(RUNTIME, "NAME", name)), "\n") do
			add(line)
		end
	end

	add(`return {name}`)
	add("")

	return table.concat(lines, "\n")
end

return Formatter
