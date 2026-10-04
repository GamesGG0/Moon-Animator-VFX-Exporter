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
	Cues: { { Frame: number, Effect: string, Offset: CFrame, Notes: { string }?, Asset: string? } },
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

-- Spawns one cue's VFX relative to the HumanoidRootPart; it's removed after Lifetime seconds.
function NAME.Spawn(root: BasePart, cue)
	local name = cue.Object or cue.Effect
	local template = VFX:FindFirstChild(name)
	if not template then
		warn(`[NAME] No VFX named "{name}" in {VFX:GetFullName()}`)
		return nil
	end

	local effect = template:Clone()
	local cframe = root.CFrame * cue.Offset
	if effect:IsA("Model") then
		effect:PivotTo(cframe)
	elseif effect:IsA("BasePart") then
		effect.CFrame = cframe
	end

	effect.Parent = workspace
	NAME.Emit(effect)
	Debris:AddItem(effect, NAME.Lifetime)
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
			NAME.Spawn(root, cue)
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
			local key = if spec.Timestamps then Formatter.seconds(cue.Frame, spec.FPS or 60) else tostring(cue.Frame)
			keys[i] = `[{key}] =`

			-- Object is only written when the effect's name isn't already its VFX object's name.
			fields[i] = string.format("Effect = %q,", cue.Effect)
			if cue.Asset and cue.Asset ~= cue.Effect then
				fields[i] ..= string.format(" Object = %q,", cue.Asset)
			end

			keyWidth = math.max(keyWidth, #keys[i])
			fieldWidth = math.max(fieldWidth, #fields[i])
		end

		add("\tCues = {")
		for i, cue in spec.Cues do
			local key = keys[i] .. string.rep(" ", keyWidth - #keys[i] + 1)
			local field = fields[i] .. string.rep(" ", fieldWidth - #fields[i] + 1)
			local line = `\t\t{key}\{ {field}Offset = {Formatter.cframe(cue.Offset)} },`

			if cue.Notes and #cue.Notes > 0 then
				line ..= " -- " .. table.concat(cue.Notes, "; ")
			end
			add(line)
		end
		add("\t},")
	end

	add("}")
	add("")

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
