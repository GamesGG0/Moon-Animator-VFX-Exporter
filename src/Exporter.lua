--!strict
-- Turns the events in a Moon Animator save into VFX cues:
--   frame -> { Effect = name, Offset = <effect CFrame relative to the HumanoidRootPart> }
--
-- This is the same number you'd get by scrubbing to each event and running
--   HumanoidRootPart.CFrame:ToObjectSpace(effectPart.CFrame)
-- except the CFrames are sampled from the save's keyframes, so nothing has to be scrubbed.

local RigPose = require(script.Parent.RigPose)
local Sampler = require(script.Parent.Sampler)
local SaveReader = require(script.Parent.SaveReader)

local Exporter = {}

export type Options = {
	-- "Event": use the event's Name, falling back to the effect part's name. "Item": always the part's name.
	EffectName: string,
	-- Origin the offsets are relative to. nil = the HumanoidRootPart of the rig the effect belongs to.
	Origin: BasePart?,
	-- Measure every event at this part instead of the item the event sits on (e.g. a "Container" part).
	Target: Instance?,
	-- Moon Animator's own easing functions, when it's running.
	MoonEasing: { [string]: any }?,
	-- Frame rate to write cue keys at. nil = automatic (see chooseFrameRate).
	FrameRate: number?,
}

export type Cue = {
	Frame: number,
	Effect: string,
	Offset: CFrame,
	Notes: { string },
	-- The VFX object this cue spawns, and its name in the exported VFX folder.
	Object: Instance?,
	Asset: string?,
	-- The character part or attachment the effect is connected to (the Offset is from it), or nil
	-- for the HumanoidRootPart.
	Parent: string?,
	-- For an effect on another rig in Moon (a victim, say): that rig's name. In game it plays on the
	-- character passed for it in Play's data.Rigs.
	Rig: string?,
	-- Source of the cue's Function, carried over from the last export (see Carryover).
	Function: string?,
	-- A screen effect this cue shows (see Exporter.screenCue); the Sequence module plays it.
	Screen: ScreenEffect?,
	-- Keyframes this cue replays (see "Keyframed effects" below); the Sequence module plays them.
	Animation: Animation?,
	-- Code the event ran in Moon (other than emitting), for the cue's Function.
	Code: string?,
	-- That code rewritten to run in game (see Exporter.adaptCode): what it used from the Moon scene
	-- and its names in game, and whether it needs the cue's VFX or other rigs from data.Rigs.
	Adapted: { Code: string, Uses: { { From: string, To: string } }, Effect: boolean, Rigs: { string } }?,
	-- Or, when it can't be, the scene objects it uses that the game won't have.
	CodeMissing: { string }?,
	-- The effects in Object the event emits, when it named them rather than all of Object; only
	-- they're packed.
	Only: { Instance }?,
	-- What the object is carried in when it's packed (see Packager.prepare): "Part" for an effect
	-- that lived in a prop's part, "Attachment" for one in a rig's attachment (the character in
	-- game may not have that attachment), "AttachmentPart" for one in a prop's attachment.
	Wrap: string?,
}

-- Keyframes a cue replays: Kind "Animate" plays them on the spawned effect (or the
-- instance at Path inside it, with CFrame keys relative to where the character stands if Origin);
-- Kind "Lighting" plays them on Lighting, and "Camera" on the camera (its field of view).
export type Animation = {
	Kind: string,
	Keys: { [string]: { { Time: number, Value: any, Style: string?, Direction: string? } } },
	Path: { string }?,
	Origin: boolean?,
	-- Seconds the last values hold before Lighting or the camera is put back: until the animation
	-- ends, as in Moon.
	Hold: number?,
}

-- One of Moon's screen effects: an overlay in its MoonAnimatorEffects GUI (a vignette, a flash...)
-- or a post effect (blur, color correction...). Keys are each animated property's keyframes, with
-- times in seconds from when the cue fires.
export type ScreenEffect = {
	ClassName: string,
	Properties: { [string]: any },
	Keys: { [string]: { { Time: number, Value: any, Style: string?, Direction: string? } } },
	-- The effect's other pieces (see guiChildren): Moon's vignette is four images, say.
	Children: { any }?,
	-- Names leading from the effect to the keyed piece, when that's one of its pieces.
	Path: { string }?,
}

export type Result = {
	Cues: { Cue },
	Warnings: { string },
	EventCount: number,
	-- Events left out because they're on something that can't be spawned (Moon's Subtitles, the
	-- camera...): how many, by item name.
	Skipped: { [string]: number },
	-- The rate cue frames are in, and why it differs from the Moon file's (if it does).
	FrameRate: number,
	FrameRateReason: string?,
}

type Context = {
	Anim: SaveReader.Animation,
	Options: Options,
	ByInstance: { [Instance]: SaveReader.Item },
	Poses: { [Instance]: any },
	-- The main character's rig: the first rig in the animation.
	MainPose: any,
	-- Parts Moon's camera is attached to (its AttachToPart keys). VFX on them follow the camera.
	CameraParts: { [Instance]: boolean },
}

local function rootPartOf(model: Instance): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end

	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	if humanoid and humanoid.RootPart then
		return humanoid.RootPart
	end

	return nil
end

local function isRig(inst: Instance): boolean
	return inst:IsA("Model") and rootPartOf(inst) ~= nil
end

-- The rigs in an animation, in the order the file lists them. The first is the main character, the
-- one offsets are measured from.
function Exporter.rigsOf(anim: SaveReader.Animation): { Model }
	local rigs = {}
	for _, item in anim.Items do
		local inst = item.Instance
		if inst and isRig(inst) and not table.find(rigs, inst) then
			table.insert(rigs, inst :: Model)
		end
	end
	return rigs
end

local function sampleTrack(ctx: Context, inst: Instance, prop: string, frame: number): any
	local item = ctx.ByInstance[inst]
	local track = item and item.Tracks[prop]
	if track and #track > 0 then
		return Sampler.sample(track, frame, ctx.Options.MoonEasing)
	end
	return nil
end

-- The pose of the animated rig `inst` is part of (or is), if any.
local function poseOf(ctx: Context, inst: Instance?): any
	local node = inst
	while node and node ~= game do
		local pose = ctx.Poses[node]
		if pose then
			return pose
		end
		node = node.Parent
	end
	return nil
end

-- A part with no keys of its own still moves if it sits inside a model whose CFrame is keyed:
-- Moon moves the whole model.
local function movedWithModel(ctx: Context, part: BasePart, frame: number): CFrame?
	local node = part.Parent
	while node and node ~= game do
		if node:IsA("Model") then
			local pivot = sampleTrack(ctx, node, "CFrame", frame)
			if typeof(pivot) == "CFrame" then
				return pivot * node:GetPivot():ToObjectSpace(part.CFrame)
			end
		end
		node = node.Parent
	end
	return nil
end

-- World CFrame of `inst` at `frame`. The second return is a note when the value is a guess.
local function cframeAt(ctx: Context, inst: Instance, frame: number): (CFrame?, string?)
	local keyed = sampleTrack(ctx, inst, "CFrame", frame)

	if inst:IsA("BasePart") then
		if typeof(keyed) == "CFrame" then
			return keyed, nil
		end

		local position = sampleTrack(ctx, inst, "Position", frame)
		if typeof(position) == "Vector3" then
			return inst.CFrame.Rotation + position, nil
		end

		-- Inside an animated rig: posed from the rig's keys, not from where the playhead was left.
		local pose = poseOf(ctx, inst)
		if pose then
			return pose:CFrameAt(inst, frame), nil
		end

		local moved = movedWithModel(ctx, inst, frame)
		if moved then
			return moved, nil
		end

		-- A loose part stays where it is. One jointed to something we can't follow is a guess.
		local ok, joints = pcall(function()
			return (inst :: any):GetJoints()
		end)
		if not inst.Anchored and ok and type(joints) == "table" and #joints > 0 then
			return inst.CFrame, `{inst.Name} is jointed to something that isn't animated here; used its current position`
		end
		return inst.CFrame, nil
	elseif inst:IsA("Model") then
		if typeof(keyed) == "CFrame" then
			return keyed, nil
		end

		local pose = poseOf(ctx, inst.Parent)
		local anchor = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		if pose and anchor then
			return pose:CFrameAt(anchor, frame) * anchor.CFrame:ToObjectSpace(inst:GetPivot()), nil
		end
		return inst:GetPivot(), nil
	elseif inst:IsA("Attachment") then
		local localCFrame = if typeof(keyed) == "CFrame" then keyed else inst.CFrame
		local parent = inst.Parent
		if parent and parent:IsA("BasePart") then
			local parentCFrame, note = cframeAt(ctx, parent, frame)
			if parentCFrame then
				return parentCFrame * localCFrame, note
			end
		elseif parent and parent:IsA("Attachment") then
			-- Roblox gives an attachment inside another attachment no position of its own; treat
			-- its CFrame as relative to the outer one.
			local parentCFrame, note = cframeAt(ctx, parent, frame)
			if parentCFrame then
				return parentCFrame * localCFrame, note or `{inst.Name} is inside another attachment; placed relative to it`
			end
		end
		return inst.WorldCFrame, nil
	elseif inst:IsA("Bone") then
		return inst.TransformedWorldCFrame, `{inst.Name} is a bone; used its current pose`
	elseif inst:IsA("Camera") then
		if typeof(keyed) == "CFrame" then
			return keyed, nil
		end
		return inst.CFrame, nil
	end

	return nil, nil
end

-- The origin (a HumanoidRootPart, or a body part an effect is parented to) at `frame`.
local function originAt(ctx: Context, origin: BasePart, frame: number): CFrame
	local keyed = sampleTrack(ctx, origin, "CFrame", frame)
	if typeof(keyed) == "CFrame" then
		return keyed
	end

	local pose = poseOf(ctx, origin)
	if pose then
		return pose:CFrameAt(origin, frame)
	end

	return movedWithModel(ctx, origin, frame) or origin.CFrame
end

-- An instance path written in event code: where it starts, what it starts from (a service, or a
-- local set to a path), each instance it goes through with where that part of the text ends, and
-- where it got to. When it got stuck, Wanted is the child it looked for by name (["X"],
-- :FindFirstChild("X") or :WaitForChild("X")) that isn't there.
type CodePath = {
	At: number,
	Root: Instance,
	Local: boolean?,
	Steps: { { Instance: Instance, Stop: number } },
	Instance: Instance,
	Complete: boolean,
	Wanted: string?,
}

-- Every instance path in event code, in order. Paths can start at workspace, game.Service,
-- game:GetService("Service"), or a local set to one earlier, like VFX Forge's service aliases or
-- a variable holding an effect:
--   local A = game:GetService("ReplicatedStorage")
--   shared.vfx.emit(A.Effects["Big Hit"])
--   local VFX = workspace.Barrage
--   Part_Icles:AbsoluteEmit(VFX)
local function pathsInCode(code: string): { CodePath }
	local function service(name: string): Instance?
		local ok, found = pcall(function()
			return game:GetService(name)
		end)
		return if ok and typeof(found) == "Instance" then found else nil
	end

	-- Every place a path starts: where, what it starts from, and where the rest of it begins.
	-- A local's name is a path on its own (VFX), a service's isn't (game.Workspace).
	local starts = {}
	local function addStart(s: number, e: number, root: Instance?, isLocal: boolean?)
		local before = if s > 1 then string.sub(code, s - 1, s - 1) else ""
		if root and not string.match(before, "[%w_%.:]") then
			table.insert(starts, { At = s, Root = root, Rest = e + 1, Local = isLocal })
		end
	end

	local function each(pattern: string, visit: (number, number, string?) -> ())
		local init = 1
		while true do
			local s, e, captured = string.find(code, pattern, init)
			if not s then
				break
			end
			visit(s, e, captured)
			init = e + 1
		end
	end

	each("game%s*:%s*GetService%s*%(%s*[\"']([%w]+)[\"']%s*%)", function(s, e, name)
		addStart(s, e, service(name :: string))
	end)
	each("game%s*%.%s*([%a][%w]*)", function(s, e, name)
		addStart(s, e, game:FindFirstChild(name :: string) or service(name :: string))
	end)
	each("%f[%w_]workspace%f[^%w_]", function(s, e)
		addStart(s, e, game:GetService("Workspace"))
	end)

	-- Follows the path after `root` from `pos`. Returns where it got to, where the path text ends,
	-- whether all of it was found, the instances on the way (see CodePath), and the child it looked
	-- for by name that isn't there.
	local function walk(root: Instance, pos: number): (Instance, number, boolean, { { Instance: Instance, Stop: number } }, string?)
		local current = root
		local steps = {}
		while true do
			local name, nextPos
			local byName = false

			local _, e, captured = string.find(code, "^%s*%.%s*([%a_][%w_]*)", pos)
			if captured then
				name, nextPos = captured, e + 1
			else
				_, e, captured = string.find(code, "^%s*%[%s*\"([^\"]*)\"%s*%]", pos)
				if not captured then
					_, e, captured = string.find(code, "^%s*%[%s*'([^']*)'%s*%]", pos)
				end
				if captured then
					name, nextPos, byName = captured, e + 1, true
				else
					local method
					_, e, method, captured = string.find(code, "^%s*:%s*([%a]+)%s*%(%s*[\"']([^\"']*)[\"']", pos)
					if captured then
						local close = string.find(code, ")", e + 1, true)
						name, nextPos = captured, (close or e) + 1
						byName = method == "FindFirstChild" or method == "WaitForChild"
					end
				end
			end

			if not name then
				return current, pos, true, steps, nil
			end

			local child = current:FindFirstChild(name)
			if not child then
				return current, pos, false, steps, if byName then name else nil
			end

			current = child
			pos = nextPos
			table.insert(steps, { Instance = child, Stop = nextPos })
		end
	end

	-- Locals set to a path (local A = game:GetService("..."), local VFX = workspace.Barrage), in the
	-- order they're written so one can build on another. Each use after it is a path start.
	each("local%s+([%a_][%w_]*)%s*=%s*", function(_, e, name)
		for _, start in starts do
			if start.At == e + 1 then
				local inst, stop, complete = walk(start.Root, start.Rest)
				local rest = string.match(code, "^[^\n]*", stop) or ""
				if complete and (string.match(rest, "^%s*;?%s*$") or string.match(rest, "^%s*;?%s*%-%-")) then
					each(`%f[%w_]{name}%f[^%w_]`, function(s, useEnd)
						if s > e then
							addStart(s, useEnd, inst, true)
						end
					end)
				end
				break
			end
		end
	end)

	table.sort(starts, function(a, b)
		return a.At < b.At
	end)

	local paths = {}
	for _, start in starts do
		local inst, _, complete, steps, wanted = walk(start.Root, start.Rest)
		table.insert(paths, {
			At = start.At,
			Root = start.Root,
			Local = start.Local,
			Steps = steps,
			Instance = inst,
			Complete = complete,
			Wanted = wanted,
		})
	end
	return paths
end

-- What the instance paths in event code point at, in the order they appear (see pathsInCode), e.g.
-- workspace["Ripper Test"].ImpactAnti. Only paths starting at or after `from` are returned. With
-- `exact`, a path whose end isn't in the place (workspace.Rig.Torso.Missing) is left out instead of
-- giving the part of it that is.
function Exporter.findInstancesInCode(code: string, from: number?, exact: boolean?): { Instance }
	local found = {}
	for _, path in pathsInCode(code) do
		if path.At >= (from or 1) then
			local inst = path.Instance
			local isPath = inst ~= path.Root or (path.Local and inst.Parent ~= game)
			if isPath and (path.Complete or not exact) and not table.find(found, inst) then
				table.insert(found, inst)
			end
		end
	end
	return found
end

-- Whether event code using `inst` used something from the Moon scene, which the game won't have
-- (the camera and terrain it will).
local function inScene(inst: Instance): boolean
	local workspace = game:GetService("Workspace")
	return inst ~= workspace
		and inst:IsDescendantOf(workspace)
		and not inst:IsA("Terrain")
		and not inst:IsA("Camera")
		and inst:FindFirstAncestorWhichIsA("Camera") == nil
end

-- Hands what event code makes to the sequence's cleaner (Sequence's self:AddToCleaner), so it goes
-- when the sequence stops: a self:AddToCleaner(X) line is added after the code puts an instance it
-- made into the world (X.Parent = ...), and after it makes a connection (X = ...:Connect(...)).
function Exporter.addCleanup(code: string): string
	local lines = string.split(code, "\n")
	local lineStarts = {}
	local at = 1
	for i, line in lines do
		lineStarts[i] = at
		at += #line + 1
	end
	local function lineAt(pos: number): number
		local found = 1
		for i, start in lineStarts do
			if start > pos then
				break
			end
			found = i
		end
		return found
	end

	-- The parenthesis closing the one at `open`, past strings and comments.
	local function closing(open: number): number?
		local depth, i = 0, open
		while i <= #code do
			local c = string.sub(code, i, i)
			if c == '"' or c == "'" then
				local j = i + 1
				while j <= #code do
					local d = string.sub(code, j, j)
					if d == "\\" then
						j += 2
					elseif d == c or d == "\n" then
						break
					else
						j += 1
					end
				end
				i = j
			elseif string.sub(code, i, i + 1) == "--" then
				i = string.find(code, "\n", i, true) or #code
			elseif c == "(" then
				depth += 1
			elseif c == ")" then
				depth -= 1
				if depth == 0 then
					return i
				end
			end
			i += 1
		end
		return nil
	end

	local after: { [number]: { { Name: string, Indent: string } } } = {}
	local function cleanAfter(line: number, name: string, indent: string)
		if string.find(code, `AddToCleaner%(%s*{name}%s*%)`) then
			return -- the code hands it over already
		end
		after[line] = after[line] or {}
		for _, entry in after[line] do
			if entry.Name == name then
				return
			end
		end
		table.insert(after[line], { Name = name, Indent = indent })
	end

	-- Instances it makes, once they're put somewhere.
	local made = {}
	for name in string.gmatch(code, "([%a_][%w_]*)%s*=%s*Instance%s*%.%s*new%s*%(") do
		made[name] = true
	end
	local cleaned = {}
	for i, line in lines do
		local indent, name = string.match(line, "^(%s*)([%a_][%w_]*)%s*%.%s*Parent%s*=[^=]")
		if name and made[name] and not cleaned[name] then
			cleaned[name] = true
			cleanAfter(i, name, indent)
		end
	end

	-- Connections, after the statement making one ends (its function can run over many lines).
	for _, method in { "Connect", "Once" } do
		local init = 1
		while true do
			local s, e, name = string.find(code, `([%a_][%w_]*)%s*=%s*[^=\n][^\n]-:%s*{method}%s*%(`, init)
			if not s then
				break
			end
			init = e + 1
			-- A plain variable, not a field (self.connection = ...).
			if s == 1 or string.match(string.sub(code, s - 1, s - 1), "[%s;]") then
				local close = closing(e)
				if close then
					local first = lines[lineAt(s)]
					cleanAfter(lineAt(close), name, string.match(first, "^%s*") or "")
				end
			end
		end
	end

	local out = {}
	for i, line in lines do
		table.insert(out, line)
		for _, entry in after[i] or {} do
			table.insert(out, `{entry.Indent}self:AddToCleaner({entry.Name})`)
		end
	end
	return table.concat(out, "\n")
end

-- Event code ran in the Moon scene. In game, what it used there has other names: `names` maps
-- instances to them (the cue's VFX -> "effect", its rig -> "character"...). Rewrites each path in
-- the code to the deepest of those it goes through:
--   local beamPart = workspace:WaitForChild("Runbeams")   ->   local beamPart = effect
-- Returns the rewritten code and the instances it renamed, or nil and the names of the scene
-- objects it uses that have no name in the game.
function Exporter.adaptCode(code: string, names: { [Instance]: string }): (string?, { any })
	local replacements, used, missing = {}, {}, {}

	for _, path in pathsInCode(code) do
		-- A local holding an object is fine once the path it was set to is rewritten.
		if path.Local and path.Root.Parent ~= game then
			continue
		end

		local best = nil
		for _, step in path.Steps do
			if names[step.Instance] then
				best = step
			end
		end

		if best then
			table.insert(replacements, { From = path.At, To = best.Stop - 1, Text = names[best.Instance] })
			if not table.find(used, best.Instance) then
				table.insert(used, best.Instance)
			end
		else
			local wanted = if path.Wanted and (path.Instance == game:GetService("Workspace") or inScene(path.Instance)) then path.Wanted else nil
			local name = wanted or (if inScene(path.Instance) then path.Instance.Name else nil)
			if name and not table.find(missing, name) then
				table.insert(missing, name)
			end
		end
	end

	if #missing > 0 then
		return nil, missing
	end

	-- From the end, so earlier positions stay put. A path inside one already rewritten is skipped.
	table.sort(replacements, function(a, b)
		return a.From > b.From
	end)
	local limit = math.huge
	for _, replacement in replacements do
		if replacement.To < limit then
			code = string.sub(code, 1, replacement.From - 1) .. replacement.Text .. string.sub(code, replacement.To + 1)
			limit = replacement.From
		end
	end
	return code, used
end

-- Calls in event code that emit VFX: VFX Forge's `shared.vfx.emit(a, b, ...)`, and Part_Icles'
-- `Part_Icles:AbsoluteEmit(a)`.
local EMIT_CALLS = {
	"shared%s*%.%s*vfx%s*%.%s*[Ee]mit%s*%(",
	":%s*AbsoluteEmit%s*%(",
}

-- What the emit calls in event code emit, in order, and how many calls there are. People put these
-- events on any item (even Moon's Subtitles), so the event's item says nothing about what's
-- emitted. A path that isn't in the place emits nothing, as in Moon.
function Exporter.findEmitTargets(code: string): ({ Instance }, number)
	-- Each call's arguments: from after its "(" to its matching ")". Quoted names can hold
	-- parentheses.
	local calls = {}
	for _, pattern in EMIT_CALLS do
		local init = 1
		while true do
			local _, open = string.find(code, pattern, init)
			if not open then
				break
			end

			local depth, i, quote = 1, open + 1, nil
			while i <= #code and depth > 0 do
				local c = string.sub(code, i, i)
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

			table.insert(calls, { From = open + 1, Close = i - 1 })
			init = i
		end
	end
	table.sort(calls, function(a, b)
		return a.From < b.From
	end)

	-- The code before a call is read too, for the locals its arguments use.
	local targets = {}
	for _, call in calls do
		for _, inst in Exporter.findInstancesInCode(string.sub(code, 1, call.Close - 1), call.From, true) do
			if not table.find(targets, inst) then
				table.insert(targets, inst)
			end
		end
	end
	return targets, #calls
end

local function pathLeaf(item: SaveReader.Item): string
	return item.PathNames[#item.PathNames] or item.Path
end

local function isPlaceable(inst: Instance): boolean
	return inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Attachment") or inst:IsA("Bone")
end

-- Effects that live inside a part or attachment, or on a model (a Highlight), rather than being
-- placed in the world themselves.
local EFFECT_CLASSES = { "ParticleEmitter", "Beam", "Trail", "Light", "Fire", "Smoke", "Sparkles", "Sound", "Highlight" }

function Exporter.isEffect(inst: Instance): boolean
	for _, class in EFFECT_CLASSES do
		if inst:IsA(class) then
			return true
		end
	end
	return false
end
local isEffect = Exporter.isEffect

local function inRig(inst: Instance): boolean
	local node = inst.Parent
	while node and node ~= game do
		if isRig(node) then
			return true
		end
		node = node.Parent
	end
	return false
end

-- An effect that goes on the character (or one of its parts) when it plays, instead of being
-- placed in the world: a Highlight, or an emitter, light or sound on the rig itself.
function Exporter.isAttachedEffect(inst: Instance): boolean
	return isEffect(inst) and (inst:IsA("Highlight") or inRig(inst))
end

-- The first part, model or attachment an event's code names (that isn't a whole rig, or the root
-- of the rig `on`).
local function codeObjectFor(marker: SaveReader.Marker, on: Instance?): Instance?
	for _, code in marker.Code do
		for _, path in pathsInCode(code) do
			-- A path can go on to a property (workspace.Barrel.Transparency), but not to a child looked
			-- up by name that isn't there.
			local found = path.Instance
			local isPath = found ~= path.Root or (path.Local and found.Parent ~= game)
			if isPath and not path.Wanted and isPlaceable(found) and not isRig(found) and not (on and found == rootPartOf(on)) then
				return found
			end
		end
	end
	return nil
end

-- The code an event runs, or nil if it has none.
local function eventCode(marker: SaveReader.Marker): string?
	local code = table.concat(marker.Code, "\n")
	return if string.find(code, "%S") then code else nil
end

-- The VFX object an event spawns: the item it sits on (or, for an emitter or light inside a part,
-- that part), or, for an event on a rig or on something that can't be spawned, the part named
-- in its code. The second return says whether it came from the code.
local function vfxObjectFor(item: SaveReader.Item, marker: SaveReader.Marker): (Instance?, boolean)
	local inst = item.Instance
	if inst and isPlaceable(inst) and not isRig(inst) then
		return inst, false
	end
	if inst and isEffect(inst) then
		local parent = inst.Parent
		if not Exporter.isAttachedEffect(inst) and parent and isPlaceable(parent) then
			return parent, false
		end
		return inst, false
	end

	local found = codeObjectFor(marker, inst)
	return found, found ~= nil
end

-- The part Moon's camera follows that `inst` is on, if any.
local function cameraPartOf(ctx: Context, inst: Instance): Instance?
	local node: Instance? = inst
	while node and node ~= game do
		if ctx.CameraParts[node] and node:IsA("BasePart") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The VFX object to spawn for something an emit call names: it, or for an emitter or light inside
-- an attachment or a prop's part, what it's in (packed with only the effects that were named). nil
-- for a whole character or anything else that can't be spawned.
local function emittedObject(inst: Instance): Instance?
	if isRig(inst) then
		return nil
	end
	if isPlaceable(inst) then
		return inst
	end
	if isEffect(inst) then
		local parent = inst.Parent
		if inst:IsA("Highlight") or not parent then
			return inst
		end
		if parent:IsA("Attachment") or (not inRig(inst) and isPlaceable(parent)) then
			return parent
		end
		return inst
	end
	return nil
end

-- A Beam or Trail is drawn between two attachments, so its copy has to hold both: the object grows
-- to what holds them (a beam from A1 to A2 in a prop: the prop), keeping to the same effects.
-- Returns the object and the effects to keep (nil for all of it). Never grows into a rig.
local function holdingBeamEnds(object: Instance, only: { Instance }?): (Instance, { Instance }?)
	local effects = only
	if not effects then
		effects = {}
		for _, item in object:GetDescendants() do
			if isEffect(item) then
				table.insert(effects, item)
			end
		end
	end

	local container: Instance? = object
	for _, effect in effects :: { Instance } do
		if effect:IsA("Beam") or effect:IsA("Trail") then
			local ends = effect :: any
			for _, attachment in { ends.Attachment0, ends.Attachment1 } do
				while container and attachment and not (attachment == container or attachment:IsDescendantOf(container)) do
					container = container.Parent
				end
			end
		end
	end

	if container == object or not container or not isPlaceable(container) or isRig(container) or inRig(container) then
		return object, only
	end
	return container, effects
end

-- Which instance an event's offset is measured at, plus the effect name to use when the event
-- has no Name of its own.
local function targetFor(
	ctx: Context,
	item: SaveReader.Item,
	object: Instance?,
	fromCode: boolean
): (Instance?, string, string?)
	local inst = item.Instance
	local fallbackName = if object then object.Name elseif inst then inst.Name else pathLeaf(item)

	if ctx.Options.Target then
		return ctx.Options.Target, fallbackName, nil
	elseif object then
		return object, fallbackName, if fromCode then `measured at {object:GetFullName()} (from the event code)` else nil
	elseif inst then
		return rootPartOf(inst), fallbackName, "event is on the rig itself; pick a Target part for a real offset"
	end

	return nil, fallbackName, nil
end

-- Names each distinct VFX object will have in the exported VFX folder. Two different objects
-- with the same name, or the same object packed with different effects (Only), get numbered
-- ("Dust", "Dust2") so a cue always finds its own object.
function Exporter.assignAssets(cues: { Cue })
	local taken: { [string]: boolean } = {}
	local names: { [Instance]: { [string]: string } } = {}

	for _, cue in cues do
		local object = cue.Object
		if not object then
			continue
		end

		local which = ""
		if cue.Only then
			local parts = {}
			for _, inst in cue.Only do
				table.insert(parts, inst:GetFullName())
			end
			table.sort(parts)
			which = table.concat(parts, "\n")
		end

		names[object] = names[object] or {}
		local name = names[object][which]
		if not name then
			local base = object.Name
			name = base
			local n = 1
			while taken[name] do
				n += 1
				name = base .. n
			end
			taken[name] = true
			names[object][which] = name
		end

		cue.Asset = name
	end
end

-- The rig a cue plays on: the animated rig its object is part of (the main character, or another
-- rig such as a victim), or the main character for anything that isn't on a rig.
local function homeOf(ctx: Context, inst: Instance?): any
	return poseOf(ctx, inst) or ctx.MainPose
end

local function originFor(ctx: Context, target: Instance): BasePart?
	if ctx.Options.Origin then
		return ctx.Options.Origin
	end
	local home = homeOf(ctx, target)
	if home then
		return home.Root
	end

	local node: Instance? = target
	while node and node ~= game do
		if node:IsA("Model") then
			local root = rootPartOf(node)
			if root then
				return root
			end
		end
		node = node.Parent
	end

	-- Not inside a rig: use the first rig in the animation.
	for _, item in ctx.Anim.Items do
		if item.Instance and isRig(item.Instance) then
			return rootPartOf(item.Instance)
		end
	end

	return nil
end

-- The part of the character an effect is connected to (it follows that part). Set by a "Parent"
-- key in the event's Events tab, which can name any part or attachment of the rig, the
-- HumanoidRootPart included, or worked out from the VFX object:
--   a part Moon animates through a joint (a limb, an animated weapon)  -> that part itself
--   an attachment, or a part jointed or welded to the rig              -> the part it hangs off
-- Without one, an effect is placed from the HumanoidRootPart and stays where it's put.
local function parentFor(ctx: Context, marker: SaveReader.Marker, object: Instance): (Instance?, string?)
	local main = homeOf(ctx, object)

	local explicit: string? = nil
	for key, value in marker.Keys do
		if string.lower(key) == "parent" then
			explicit = value
		end
	end

	if explicit then
		if explicit == "" or not main then
			return nil, nil
		end
		-- A body part, or an attachment on one (e.g. RightGripAttachment).
		local part = main.Rig:FindFirstChild(explicit, true)
		if part and (part:IsA("BasePart") or (part:IsA("Attachment") and part.Parent and part.Parent:IsA("BasePart"))) then
			return part, nil
		end
		return nil, `Parent "{explicit}" isn't a part or attachment of {main.Rig.Name}, so this is measured from the HumanoidRootPart`
	end

	local pose = poseOf(ctx, object)
	if not pose or object == pose.Root then
		return nil, nil
	end

	if object:IsA("BasePart") then
		local motor = pose.Motors[object]
		if motor and pose.JointTracks[motor] then
			return object, nil
		end
	end

	local attached = pose:AttachedTo(object)
	if attached and attached ~= pose.Root and attached ~= object then
		return attached, nil
	end
	return nil, nil
end

-- Two events on the same frame would overwrite each other as table keys, so the later one is
-- nudged forward to the next free frame.
local function separateFrames(cues: { Cue })
	-- Cues on the same frame keep the order they were made in (an emit call's order), so the
	-- first one keeps the frame.
	local order = {}
	for i, cue in cues do
		order[cue] = i
	end
	table.sort(cues, function(a, b)
		if a.Frame ~= b.Frame then
			return a.Frame < b.Frame
		end
		return order[a] < order[b]
	end)

	-- Original frames are claimed first so a moved cue never displaces another event.
	local taken, duplicates = {}, {}
	for _, cue in cues do
		if taken[cue.Frame] then
			table.insert(duplicates, cue)
		else
			taken[cue.Frame] = true
		end
	end

	for _, cue in duplicates do
		local frame = cue.Frame
		repeat
			frame += 1
		until not taken[frame]

		table.insert(cue.Notes, `moved from frame {cue.Frame}, which already has a cue`)
		cue.Frame = frame
		taken[frame] = true
	end

	table.sort(cues, function(a, b)
		return a.Frame < b.Frame
	end)
end

-- Items in Moon that are never VFX objects, by where they live: Moon's Subtitles and other GUI,
-- screen effects (blur, color correction, bloom... in Lighting, or Moon's own fades and flashes),
-- and anything on the camera. Used when the item can't be found in the place to look at.
local NOT_VFX_ROOTS = {
	CoreGui = true,
	PlayerGui = true,
	StarterGui = true,
	Lighting = true,
	MoonAnimatorEffects = true,
	Camera = true,
	CurrentCamera = true,
}

-- The same, for an item that is in the place.
local function isNotVfxInstance(inst: Instance): boolean
	if inst:IsA("PostEffect") or inst:IsA("GuiBase2d") or inst:IsA("Camera") then
		return true
	end
	if inst:IsA("Atmosphere") or inst:IsA("Sky") or inst:IsA("Clouds") then
		return true
	end
	return inst:FindFirstAncestorWhichIsA("LayerCollector") ~= nil
		or inst:FindFirstAncestorWhichIsA("Camera") ~= nil
		or inst:FindFirstAncestorWhichIsA("Lighting") ~= nil
end

local function isNotVfxPath(item: SaveReader.Item): boolean
	if item.ItemType == "Camera" or string.find(item.ItemType, "Effect$") then
		return true
	end
	for _, name in item.PathNames do
		if NOT_VFX_ROOTS[name] then
			return true
		end
	end
	return false
end

-- Where an attached effect (a Highlight, an emitter on a limb...) goes: the main character's part
-- or attachment it sits on, or nil for the character itself.
local function attachedParent(ctx: Context, effect: Instance): Instance?
	local parent = effect.Parent
	local home = poseOf(ctx, effect)
	if home and parent and (parent:IsA("BasePart") or parent:IsA("Attachment")) and parent ~= home.Root then
		return parent
	end
	return nil
end

-- Properties copied from the live effect so the game shows the same thing Moon does.
local SCREEN_PROPERTIES = {
	GuiObject = { "AnchorPoint", "Position", "Size", "Rotation", "BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "ZIndex", "Visible" },
	ImageLabel = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "SliceCenter", "SliceScale", "ResampleMode", "TileSize" },
	TextLabel = { "Text", "TextColor3", "TextTransparency", "TextSize", "Font", "TextScaled", "TextWrapped", "TextStrokeColor3", "TextStrokeTransparency", "TextXAlignment", "TextYAlignment", "RichText" },
	PostEffect = { "Enabled" },
	BlurEffect = { "Size" },
	ColorCorrectionEffect = { "Brightness", "Contrast", "Saturation", "TintColor" },
	BloomEffect = { "Intensity", "Size", "Threshold" },
	SunRaysEffect = { "Intensity", "Spread" },
	DepthOfFieldEffect = { "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity" },
}

local function className(item: SaveReader.Item): string
	if item.Instance then
		return item.Instance.ClassName
	end
	return item.PathTypes[#item.PathTypes] or item.ItemType
end

-- Moon's screen effects: anything in its MoonAnimatorEffects GUI except Subtitles, and post
-- effects (blur, color correction, bloom...) wherever they are.
local function isScreenEffect(item: SaveReader.Item): boolean
	local inst = item.Instance
	if inst then
		if inst:IsA("PostEffect") then
			return true
		end
		return inst:IsA("GuiObject") and inst:FindFirstAncestor("MoonAnimatorEffects") ~= nil and inst.Name ~= "Subtitles"
	end

	local class = className(item)
	if string.find(class, "Effect$") and class ~= "ParticleEmitter" then
		return true
	end
	return table.find(item.PathNames, "MoonAnimatorEffects") ~= nil and pathLeaf(item) ~= "Subtitles"
end

-- The first keyed frame across an item's tracks, or nil if nothing is keyed.
local function firstKey(item: SaveReader.Item): number?
	local first = math.huge
	for _, track in item.Tracks do
		if #track > 0 then
			first = math.min(first, track[1].Time)
		end
	end
	return if first == math.huge then nil else first
end

-- An item's keys, timed in seconds from `first`. Keys before `first` are left out except a track's
-- last one, which plays at `first` (so `first` must be where the track holds still).
-- `transform(property, key, at)` can rewrite a value; `at` is the frame the key plays at.
local function relativeKeys(item: SaveReader.Item, first: number, fps: number, transform: ((string, any, number) -> any)?)
	local keys = {}
	for property, track in item.Tracks do
		local from = 1
		for i, key in track do
			if key.Time <= first then
				from = i
			end
		end

		local list = {}
		for i = from, #track do
			local key = track[i]
			local at = math.max(key.Time, first)
			local ease = key.Ease
			table.insert(list, {
				Time = math.round((at - first) / fps * 10000) / 10000,
				Value = if transform then transform(property, key, at) else key.Value,
				Style = ease and ease.Type,
				Direction = ease and ease.Params and ease.Params.Direction,
			})
		end
		keys[property] = list
	end
	return keys
end

-- The frame an item starts changing: its last key before any value differs from the first. nil if
-- nothing ever changes. `valueOf(property, key)` gives the value to compare.
local function stillUntil(item: SaveReader.Item, valueOf: (string, any) -> any): number?
	local start = math.huge
	for property, track in item.Tracks do
		local held = track[1] and valueOf(property, track[1])
		for i = 2, #track do
			if valueOf(property, track[i]) ~= held then
				start = math.min(start, track[i - 1].Time)
				break
			end
		end
	end
	return if start == math.huge then nil else start
end

-- A GUI piece's look: its class's SCREEN_PROPERTIES, as they are now.
local function guiProperties(inst: Instance): { [string]: any }
	local properties = {}
	for group, names in SCREEN_PROPERTIES do
		if inst:IsA(group) then
			for _, name in names do
				local ok, value = pcall(function()
					return (inst :: any)[name]
				end)
				if ok and value ~= nil then
					properties[name] = value
				end
			end
		end
	end
	return properties
end

-- The GUI pieces inside `parent`, as data: each one's Name, ClassName, look and own pieces. A piece
-- Moon copies `keyed`'s look onto as it plays (one of the same class that doesn't hold it) Mirrors it.
local function guiChildren(parent: Instance, keyed: Instance): { any }?
	local children = {}
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			table.insert(children, {
				Name = child.Name,
				ClassName = child.ClassName,
				Properties = guiProperties(child),
				Children = guiChildren(child, keyed),
				Mirrors = child ~= keyed and child.ClassName == keyed.ClassName and not child:IsAncestorOf(keyed),
			})
		end
	end
	return if #children > 0 then children else nil
end

-- A cue for one of Moon's screen effects, at the frame its keyframes start: its class, look and
-- keys, which the Sequence module recreates and replays. nil if nothing in it is keyed.
function Exporter.screenCue(item: SaveReader.Item, fps: number): Cue?
	local first = firstKey(item)
	if not first then
		return nil
	end
	local keys = relativeKeys(item, first, fps)

	local class = className(item)
	local properties = {}
	local notes = {}
	local inst = item.Instance
	local children, path = nil, nil
	if inst then
		properties = guiProperties(inst)

		-- Moon builds some overlays from several pieces and copies the keyed one's look onto the
		-- others as it plays: its vignette is four images tiling the screen (an image can't be 1920
		-- by 1080), its letterbox two bars in a frame. So the whole effect is exported, from its
		-- piece right under Moon's ScreenGui, with Path leading to the keyed piece.
		if inst:IsA("GuiObject") then
			local root = inst
			while root.Parent and root.Parent:IsA("GuiObject") do
				root = root.Parent
			end
			if root ~= inst then
				class = root.ClassName
				properties = guiProperties(root)
				path = {}
				local node: Instance? = inst
				while node and node ~= root do
					table.insert(path, 1, node.Name)
					node = node.Parent
				end
			end
			children = guiChildren(root, inst)
		end
	else
		-- Moon isn't open, so its overlay can't be copied: start from the keyed properties' first
		-- values, on a see-through, full-screen element.
		for name, value in item.Defaults do
			properties[name] = value
		end
		if string.find(class, "Label$") or class == "Frame" then
			properties.BackgroundTransparency = properties.BackgroundTransparency or 1
			properties.Size = properties.Size or UDim2.fromScale(1, 1)
			table.insert(notes, `Moon Animator wasn't open, so {pathLeaf(item)}'s look (its image, colours) couldn't be copied`)
		end
	end

	return {
		Frame = first,
		Effect = pathLeaf(item),
		Offset = CFrame.new(),
		Notes = notes,
		Screen = { ClassName = class, Properties = properties, Keys = keys, Children = children, Path = path },
	}
end

local MAX_FRAME_RATE = 960
-- Events at the very same moment must be nudged a frame apart; at this rate that's ~4 ms.
local NUDGE_FRAME_RATE = 240

-- The frame rate to write cue keys at. Starts at the Moon file's rate and multiplies it until every
-- event lands on a whole frame, and same-moment events can be nudged apart by at most 1/240 s.
-- `frames` are event positions in the Moon file's frames. Returns the rate and why it was raised.
function Exporter.chooseFrameRate(frames: { number }, fps: number): (number, string?)
	local seen, hasSameMoment = {}, false
	for _, frame in frames do
		if seen[frame] then
			hasSameMoment = true
		end
		seen[frame] = true
	end

	local function lands(multiple: number): boolean
		for _, frame in frames do
			local scaled = frame * multiple
			if math.abs(scaled - math.round(scaled)) > 1e-4 then
				return false
			end
		end
		return true
	end

	local maxMultiple = math.max(1, math.floor(MAX_FRAME_RATE / fps))
	local fractional = not lands(1)
	local needsNudge = hasSameMoment and fps < NUDGE_FRAME_RATE

	for multiple = 1, maxMultiple do
		local rate = fps * multiple
		if lands(multiple) and (not hasSameMoment or rate >= NUDGE_FRAME_RATE or multiple == maxMultiple) then
			if multiple == 1 then
				return rate, nil
			end

			local reasons = {}
			if fractional then
				table.insert(reasons, "so events between frames stay exact")
			end
			if needsNudge then
				table.insert(reasons, "so events on the same frame are nudged apart by less")
			end
			return rate, `raised from {fps} fps {table.concat(reasons, " and ")}`
		end
	end

	return fps * maxMultiple, `raised from {fps} fps; some events still fall between frames and were rounded`
end

function Exporter.collect(anim: SaveReader.Animation, options: Options): Result
	local ctx: Context = {
		Anim = anim,
		Options = options,
		ByInstance = {},
		Poses = {},
		CameraParts = {},
	}

	for _, item in anim.Items do
		if item.ItemType == "Camera" then
			for _, key in item.Tracks.AttachToPart or {} do
				if typeof(key.Value) == "Instance" then
					ctx.CameraParts[key.Value] = true
				end
			end
		end

		local inst = item.Instance
		if inst then
			ctx.ByInstance[inst] = item

			local root = rootPartOf(inst)
			if inst:IsA("Model") and root then
				local pose = RigPose.new(inst, root, item.Tracks.CFrame, item.Joints, options.MoonEasing)
				ctx.Poses[inst] = pose
				ctx.MainPose = ctx.MainPose or pose
			end
		end
	end

	local cues = {}
	local warnings = {}
	local skipped = {}
	local eventCount = 0

	local function skip(item: SaveReader.Item)
		local name = pathLeaf(item)
		skipped[name] = (skipped[name] or 0) + 1
	end

	-- One cue: `object` measured at its frame (or at `measureAt`), relative to the main character
	-- (or its Parent). `name` is its effect name when the event's Name isn't used. Returns the cue.
	local function addCue(item: SaveReader.Item, marker: SaveReader.Marker, object: Instance?, fromCode: boolean, useEventName: boolean, measureAt: Instance?, name: string?): Cue
		local notes = {}
		local attached = object ~= nil and Exporter.isAttachedEffect(object)
		local target, fallbackName, targetNote = targetFor(ctx, item, object, fromCode)
		target = measureAt or target
		if targetNote then
			table.insert(notes, targetNote)
		end
		local effect = if useEventName and options.EffectName ~= "Item" and marker.Name ~= "" then marker.Name else name or fallbackName

		-- On a part Moon's camera follows: a camera effect, so in game it follows the camera.
		local cameraPart = if target then cameraPartOf(ctx, target) else nil
		if cameraPart and target then
			local world = cframeAt(ctx, target, marker.Frame)
			local cameraCFrame = cframeAt(ctx, cameraPart, marker.Frame) or (cameraPart :: BasePart).CFrame
			local cue: Cue = {
				Frame = marker.Frame,
				Effect = effect,
				Offset = if world then cameraCFrame:ToObjectSpace(world) else CFrame.new(),
				Notes = notes,
				Object = object,
				Parent = "Camera",
			}
			table.insert(cues, cue)
			return cue
		end

		local offset = CFrame.new()
		local parentInst: Instance? = nil
		local rigName: string? = nil
		local wrap: string? = nil
		if target then
			local parentNote
			parentInst, parentNote = parentFor(ctx, marker, object or target)
			if parentNote then
				table.insert(notes, parentNote)
			elseif attached and not parentInst then
				parentInst = attachedParent(ctx, object :: Instance)
			end

			-- An emitter or light in one of the rig's attachments: the character in game may not
			-- have that attachment (Moon rigs often get extra ones), so the effect brings its own
			-- copy of it, placed on the attachment's part.
			local holder = parentInst
			if attached and object and holder and holder:IsA("Attachment") and holder == object.Parent and not object:IsA("Highlight") and holder.Parent and holder.Parent:IsA("BasePart") then
				wrap = "Attachment"
				target = holder
				parentInst = holder.Parent
			end

			local home = poseOf(ctx, object or target)
			if ctx.MainPose and home and home ~= ctx.MainPose and not ctx.Options.Origin then
				rigName = home.Rig.Name
			end

			local origin: Instance? = parentInst or originFor(ctx, target)
			local targetCFrame, cfNote = cframeAt(ctx, target, marker.Frame)

			if attached and not wrap then
				-- It goes on the character (or its Parent) when it plays; there's nothing to place.
			elseif not origin then
				table.insert(notes, "no HumanoidRootPart found; pick an Origin part")
			elseif not targetCFrame then
				table.insert(notes, `can't get a CFrame from {target.ClassName} {target.Name}`)
			else
				-- An attachment Parent is measured from its world CFrame at the frame.
				local originCFrame = if origin:IsA("BasePart")
					then originAt(ctx, origin, marker.Frame)
					else cframeAt(ctx, origin, marker.Frame)
				offset = (originCFrame or CFrame.new()):ToObjectSpace(targetCFrame)
				if cfNote then
					table.insert(notes, cfNote)
				end
			end
		else
			table.insert(notes, `{item.Path} not found`)
		end

		local cue: Cue = {
			Frame = marker.Frame, -- in the Moon file's frames until the export rate is chosen
			Effect = effect,
			Offset = offset,
			Notes = notes,
			Object = object,
			Parent = if parentInst then parentInst.Name else nil,
			Rig = rigName,
			Wrap = wrap,
		}
		table.insert(cues, cue)
		return cue
	end

	-- An event's code from Moon, kept on its cue. It's also rewritten to run in game when everything
	-- it used from the scene is there under another name: the cue's VFX (effect), the rig the cue
	-- plays on (character), or, for a cue on the main character, another rig given in data.Rigs.
	local function attachCode(cue: Cue, code: string?, object: Instance?)
		if not code then
			return
		end
		cue.Code = code

		local names = {}
		local home = homeOf(ctx, object)
		if home then
			names[home.Rig] = "character"
			if home == ctx.MainPose then
				for rig in ctx.Poses do
					if rig ~= home.Rig and rig:FindFirstChildOfClass("Humanoid") then
						names[rig] = string.format("data.Rigs[%q]", rig.Name)
					end
				end
			end
		end
		if object then
			-- An attachment, or an effect that's wrapped, is packed inside a holder: the copy holds it.
			names[object] = if object:IsA("Attachment") or cue.Wrap then string.format("effect:FindFirstChild(%q, true)", object.Name) else "effect"
		end

		local adapted, used = Exporter.adaptCode(code, names)
		if not adapted then
			cue.CodeMissing = used
			table.insert(warnings, `The event at frame {cue.Frame} ("{cue.Effect}") runs code that uses {table.concat(used, ", ")} from your Moon scene, which the game won't have, so it can't run as it is. It's in the cue's Function, commented out, to adapt.`)
			return
		end
		local uses, rigs = {}, {}
		for _, inst in used do
			table.insert(uses, { From = inst.Name, To = names[inst] })
			if inst ~= object and home and inst ~= home.Rig then
				table.insert(rigs, inst.Name)
			end
		end
		cue.Adapted = {
			Code = Exporter.addCleanup(adapted),
			Uses = uses,
			Effect = object ~= nil and table.find(used, object) ~= nil,
			Rigs = rigs,
		}
	end

	-- The Moon file's frame rate.
	local fps = if anim.FPS > 0 then anim.FPS else 60

	for _, item in anim.Items do
		-- A screen effect becomes one cue, which the Sequence module plays.
		if isScreenEffect(item) then
			local cue = Exporter.screenCue(item, fps)
			if cue then
				table.insert(cues, cue)
			else
				for _ in item.Markers do
					skip(item)
				end
			end
			continue
		end

		if #item.Markers == 0 then
			continue
		end

		-- Moon's Subtitles, the camera and other things that aren't VFX objects: their events only
		-- count for what their code emits or names (people put VFX Forge events on Subtitles).
		local notVfx = if item.Instance then isNotVfxInstance(item.Instance) else isNotVfxPath(item)

		if not item.Instance and not notVfx then
			table.insert(warnings, `Couldn't find {item.Path} in the place; its events use an empty offset.`)
		end

		-- An effect animated by keyframes plays from them (below); its events would only spawn it
		-- again.
		local keyedEffect = item.Instance ~= nil and isEffect(item.Instance) and firstKey(item) ~= nil

		for _, marker in item.Markers do
			-- VFX Forge: the event's code says what to emit (`shared.vfx.emit(a, b, ...)`), often
			-- several things at once, from an event on any item. Each emitted object is a cue.
			-- Effects it names inside the same attachment or part are one cue, so they fire together
			-- and only they fire; an object it names whole is spawned whole.
			local emitted, named, whole, calls = {}, {}, {}, 0
			for _, code in marker.Code do
				local found, callCount = Exporter.findEmitTargets(code)
				calls += callCount
				for _, inst in found do
					local object = emittedObject(inst)
					if not object then
						continue
					end
					if not table.find(emitted, object) then
						table.insert(emitted, object)
					end
					if object == inst then
						whole[object] = true
					else
						named[object] = named[object] or {}
						table.insert(named[object], inst)
					end
				end
			end
			if #emitted > 0 then
				eventCount += 1
				for _, object in emitted do
					local only = if whole[object] then nil else named[object]
					local name = if only and #only == 1 then only[1].Name else object.Name
					local holder, keep = holdingBeamEnds(object, only)
					addCue(item, marker, holder, false, #emitted == 1, nil, name).Only = keep
				end
				continue
			end
			if calls > 0 then
				table.insert(warnings, `The event at frame {marker.Frame} on {pathLeaf(item)} emits something that isn't in the place, so it's left out.`)
				continue
			end

			-- Other code (tweening beams, making a Highlight...) ran against the Moon scene, so it's
			-- put in the cue's Function to adapt. The cue spawns what the code names, if anything.
			local code = eventCode(marker)
			if notVfx or keyedEffect then
				if not code then
					skip(item)
					continue
				end
				eventCount += 1
				local object = codeObjectFor(marker, nil)
				if object then
					attachCode(addCue(item, marker, object, true, true), code, object)
				else
					local cue: Cue = {
						Frame = marker.Frame,
						Effect = if marker.Name ~= "" then marker.Name else "Event code",
						Offset = CFrame.new(),
						Notes = {},
					}
					table.insert(cues, cue)
					attachCode(cue, code, nil)
				end
				continue
			end

			local object, fromCode = vfxObjectFor(item, marker)

			-- Nothing to spawn: leave the event out.
			local inst = item.Instance
			if not object and inst and not isRig(inst) then
				skip(item)
				continue
			end
			eventCount += 1

			attachCode(addCue(item, marker, object, fromCode, true), code, object)
		end
	end

	-- Keyframed effects: what Moon animates with keyframes instead of events (a Highlight or light
	-- flashing, a part moving along a path, Lighting, the camera's field of view). Each is one cue,
	-- at its first key, whose keys the Sequence module replays.
	local function untilEnd(frame: number): number?
		return if anim.Length > frame then math.round((anim.Length - frame) / fps * 1000) / 1000 else nil
	end
	local spawnedByEvents = {}
	for _, cue in cues do
		if cue.Object then
			spawnedByEvents[cue.Object] = true
		end
	end

	for _, item in anim.Items do
		local first = firstKey(item)
		local inst = item.Instance
		if not first or isScreenEffect(item) or item.ItemType == "Rig" then
			continue
		end

		-- The camera's field of view (a zoom punch), from when it starts changing. Its other tracks
		-- move the camera itself, which isn't VFX.
		if item.ItemType == "Camera" then
			local fovItem: any = { Tracks = { FieldOfView = item.Tracks.FieldOfView or {} } }
			local start = stillUntil(fovItem, function(_, key)
				return key.Value
			end)
			if start then
				table.insert(cues, {
					Frame = start,
					Effect = "FieldOfView",
					Offset = CFrame.new(),
					Notes = {},
					Animation = { Kind = "Camera", Keys = relativeKeys(fovItem, start, fps), Hold = untilEnd(start) },
				})
			end
			continue
		end

		local isLighting = if inst then inst:IsA("Lighting") else item.ItemType == "Lighting"
		if isLighting then
			table.insert(cues, {
				Frame = first,
				Effect = "Lighting",
				Offset = CFrame.new(),
				Notes = {},
				Animation = { Kind = "Lighting", Keys = relativeKeys(item, first, fps), Hold = untilEnd(first) },
			})
			continue
		end

		if not inst or isNotVfxInstance(inst) then
			continue
		end
		local pseudo = { Frame = first, Name = "", Width = 0, Code = {}, Keys = {} }

		if isEffect(inst) then
			-- Where it goes: a Highlight onto the character (or the part it's on); an emitter or
			-- light on a rig onto its part, in its own copy of the attachment it was in; one in a
			-- prop's attachment or part is carried in an invisible part where the prop was. Only
			-- the effect itself is packed, not what's next to it.
			local path, wrap, measureAt = {}, nil, nil
			local parent = inst.Parent
			if not Exporter.isAttachedEffect(inst) and parent then
				if parent:IsA("Attachment") then
					path, wrap, measureAt = { parent.Name, inst.Name }, "AttachmentPart", parent
				elseif parent:IsA("BasePart") then
					path, wrap, measureAt = { inst.Name }, "Part", parent
				end
			end

			local cue = addCue(item, pseudo, inst, false, false, measureAt, inst.Name)
			if wrap then
				cue.Wrap = wrap
			elseif cue.Wrap == "Attachment" then
				path = { inst.Name }
			end
			cue.Animation = { Kind = "Animate", Keys = relativeKeys(item, first, fps), Path = path }
		elseif isPlaceable(inst) and not inst:IsA("Bone") then
			-- Spawned by events: placed where it is at each event; its keyframes aren't replayed.
			-- Emitted from elsewhere while it's moving (a burst dragged across the screen), that's
			-- worth a look.
			if spawnedByEvents[inst] then
				if #item.Markers == 0 then
					for _, cue in cues do
						if cue.Object == inst then
							local here, after = cframeAt(ctx, inst, cue.Frame), cframeAt(ctx, inst, cue.Frame + 1)
							local moved = if here and after then here.Position - after.Position else nil
							if moved and math.abs(moved.X) + math.abs(moved.Y) + math.abs(moved.Z) > 1e-4 then
								table.insert(cue.Notes, "it's moving in Moon when this fires, but only where it is at this frame is exported")
							end
						end
					end
				end
				continue
			end
			if #item.Markers > 0 then
				continue
			end

			local pose = poseOf(ctx, inst)
			if pose and (inst == pose.Root or (inst:IsA("BasePart") and pose.Motors[inst])) then
				continue -- a body part: the rig animates it
			end
			if cameraPartOf(ctx, inst) then
				skip(item) -- moving on the camera: not supported yet
				continue
			end

			-- A part or attachment moving along a path: spawned where it starts moving (not while it
			-- sits still before that), then moved by its keys, which are relative to where the
			-- character stands then.
			local function worldValue(property: string, key: any, at: number?): any
				if property == "CFrame" then
					return cframeAt(ctx, inst, at or key.Time) or key.Value
				end
				return key.Value
			end
			local start = stillUntil(item, worldValue) or first
			local moving = table.clone(pseudo)
			moving.Frame = start

			local cue = addCue(item, moving, inst, false, false, nil, inst.Name)
			cue.Parent = nil -- it moves on its own
			local home = homeOf(ctx, inst)
			local originCFrame = if home then originAt(ctx, home.Root, start) else CFrame.new()
			cue.Animation = {
				Kind = "Animate",
				Origin = true,
				Keys = relativeKeys(item, start, fps, function(property, key, at)
					local value = worldValue(property, key, at)
					return if property == "CFrame" then originCFrame:ToObjectSpace(value) else value
				end),
			}
		end
	end

	-- Convert to the export frame rate.
	local sourceFrames = {}
	for _, cue in cues do
		table.insert(sourceFrames, cue.Frame)
	end

	local rate, rateReason
	if options.FrameRate and options.FrameRate > 0 then
		rate = options.FrameRate
	else
		rate, rateReason = Exporter.chooseFrameRate(sourceFrames, fps)
	end

	for _, cue in cues do
		local exact = cue.Frame * rate / fps
		cue.Frame = math.round(exact)
		if math.abs(exact - cue.Frame) > 1e-4 then
			table.insert(cue.Notes, `{string.format("%.2f", exact)} rounded to frame {cue.Frame} at {rate} fps`)
		end
	end

	separateFrames(cues)
	Exporter.assignAssets(cues)

	return {
		Cues = cues,
		Warnings = warnings,
		EventCount = eventCount,
		Skipped = skipped,
		FrameRate = rate,
		FrameRateReason = rateReason,
	}
end

return Exporter
