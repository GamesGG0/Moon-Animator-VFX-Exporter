--!strict
-- Turns the events in a Moon Animator save into VFX cues:
--   frame -> { Effect = name, Offset = <effect CFrame relative to the HumanoidRootPart> }
--
-- This is the same number you'd get by scrubbing to each event and running
--   HumanoidRootPart.CFrame:ToObjectSpace(effectPart.CFrame)
-- except the CFrames are sampled from the save's keyframes, so nothing has to be scrubbed.

local EclipseReader = require(script.Parent.EclipseReader)
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
	-- An Eclipse event's code for when it ends, EndDelay seconds after it fires.
	EndCode: string?,
	EndDelay: number?,
	-- What Eclipse gives event code, as locals the Function starts with: rig (the thing the event
	-- is on), parameter, event and context, each { Name, Value } with Value as Lua source.
	Locals: { { Name: string, Value: string } }?,
	-- That code rewritten to run in game (see Exporter.adaptCode): what it used from the Moon scene
	-- and its names in game, and whether it needs the cue's VFX or other rigs from data.Rigs. EndCode
	-- is the end code rewritten the same way.
	Adapted: { Code: string, EndCode: string?, Uses: { { From: string, To: string } }, Effect: boolean, Rigs: { string } }?,
	-- Or, when it can't be, the scene objects it uses that the game won't have.
	CodeMissing: { string }?,
	-- The effects in Object the event emits, when it named them rather than all of Object; only
	-- they're packed.
	Only: { Instance }?,
	-- What the object is carried in when it's packed (see Packager.prepare): "Part" for an effect
	-- that lived in a prop's part, "Attachment" for one in a rig's attachment (the character in
	-- game may not have that attachment), "AttachmentPart" for one in a prop's attachment.
	Wrap: string?,
	-- Particles each of its ParticleEmitters gives off, when an Eclipse emit sets how many.
	EmitCount: number?,
	-- How its VFX was emitted in the animation, when that was a module's emit method: the emitter
	-- as the Sequence names one ("ReplicatedStorage.Utilities.VFX:Emit"), and the module (see
	-- Exporter.findEmitCalls). The Sequence emits it the same way. false when its Function emits it
	-- itself, so the Sequence doesn't as well.
	Emitter: ({ Name: string, Module: string } | boolean)?,
	-- Its VFX was emitted with VFX Forge, or by Eclipse: the Sequence's own emit does that.
	DefaultEmit: boolean?,
	-- One of Eclipse's subtitles, which the Sequence draws as Eclipse does (see Exporter.subtitleCue).
	Subtitle: { [string]: any }?,
	-- Seconds before its VFX is removed, when that isn't the animation's Lifetime: an Eclipse
	-- letterbox showing until the animation ends, say.
	Lifetime: number?,
}

-- Keyframes a cue replays: Kind "Animate" plays them on the spawned effect (or the
-- instance at Path inside it, with CFrame keys relative to where the character stands if Origin);
-- Kind "Lighting" plays them on Lighting, "Camera" on the camera (its field of view), and "Shake"
-- shakes the camera with them, as Eclipse's Camera Shake does.
-- A key's Bezier is the control points of an Eclipse Bezier ease (Style "Bezier", see Easing.bezier).
export type Animation = {
	Kind: string,
	Keys: { [string]: { { Time: number, Value: any, Style: string?, Direction: string?, Bezier: { number }? } } },
	Path: { string }?,
	Origin: boolean?,
	-- Seconds the last values hold before Lighting or the camera is put back: until the animation
	-- ends, as in Moon.
	Hold: number?,
	-- A camera shake's pattern, and how far into it the shake is when the cue fires.
	Seed: number?,
	Phase: number?,
}

-- One of Moon's screen effects: an overlay in its MoonAnimatorEffects GUI (a vignette, a flash...)
-- or a post effect (blur, color correction...). Keys are each animated property's keyframes, with
-- times in seconds from when the cue fires.
export type ScreenEffect = {
	ClassName: string,
	Properties: { [string]: any },
	Keys: { [string]: { { Time: number, Value: any, Style: string?, Direction: string?, Bezier: { number }? } } },
	-- The effect's other pieces (see guiChildren): Moon's vignette is four images, say.
	Children: { any }?,
	-- Names leading from the effect to the keyed piece, when that's one of its pieces.
	Path: { string }?,
	-- Seconds to keep showing it, if that's longer than its keys: an Eclipse effect still showing
	-- when its keys end shows until the animation does.
	Hold: number?,
	-- Its text sizes are for a 1080 pixel tall screen, and scale to the player's (Moon's Subtitles).
	ScaleText: boolean?,
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
	-- Parts out of a rig that move with it (welded to it), and models holding them: their rig's pose.
	Linked: { [Instance]: any },
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

-- The pose of the animated rig `inst` is part of (or is, or is welded to), if any.
local function poseOf(ctx: Context, inst: Instance?): any
	local node = inst
	while node and node ~= game do
		local pose = ctx.Poses[node] or ctx.Linked[node]
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

		local anchor = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		local pose = poseOf(ctx, anchor or inst.Parent)
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

-- The parenthesis closing the one at `open` in `code`, past strings and comments; nil if there's none.
local function closingParen(code: string, open: number): number?
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
				local close = closingParen(code, e)
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

-- Whether code uses `name` as a variable of its own (not as a field, like part.rig).
local function usesName(code: string, name: string): boolean
	local init = 1
	while true do
		local s, e = string.find(code, `%f[%w_]{name}%f[^%w_]`, init)
		if not s then
			return false
		end
		local before = string.match(string.sub(code, 1, s - 1), "(%S)%s*$")
		if before ~= "." and before ~= ":" then
			return true
		end
		init = e + 1
	end
end

-- `require(X:Clone())` written as `require(X)`. Moon runs event code in Studio over and over, so
-- code made for it often clones a module to get a fresh copy each time; in game that makes and
-- runs a new copy of the module on every cue, where one, required once, is what's wanted.
function Exporter.withoutClonedRequires(code: string): string
	local out, init = {}, 1
	while true do
		local s, open = string.find(code, "%f[%w_]require%s*%(", init)
		if not s then
			break
		end
		local close = closingParen(code, open)
		if not close then
			break
		end
		local inner = string.sub(code, open + 1, close - 1)
		local module = string.match(inner, "^%s*(.-)%s*:%s*Clone%s*%(%s*%)%s*$")
		table.insert(out, string.sub(code, init, open))
		table.insert(out, module or inner)
		table.insert(out, ")")
		init = close + 1
	end
	table.insert(out, string.sub(code, init))
	return table.concat(out)
end

-- How deep in blocks (if, loops, functions) `code` is at `pos`, past strings and comments.
local function blockDepth(code: string, pos: number): number
	local depth, i = 0, 1
	while i < pos do
		local c = string.sub(code, i, i)
		if c == '"' or c == "'" then
			local j = i + 1
			while j <= #code and string.sub(code, j, j) ~= c and string.sub(code, j, j) ~= "\n" do
				j += if string.sub(code, j, j) == "\\" then 2 else 1
			end
			i = j + 1
		elseif string.sub(code, i, i + 1) == "--" then
			i = (string.find(code, "\n", i, true) or #code) + 1
		elseif string.match(c, "[%a_]") then
			local word = string.match(code, "^[%w_]+", i) :: string
			if word == "then" or word == "do" or word == "function" or word == "repeat" then
				depth += 1
			elseif word == "end" or word == "until" or word == "elseif" then
				depth -= 1
			end
			i += #word
		else
			i += 1
		end
	end
	return depth
end

-- A call in event code that emits VFX (see Exporter.findEmitCalls).
export type EmitCall = {
	-- What it emits that's in the place.
	Targets: { Instance },
	-- For an emit method of a module the code requires: the module's place in the game and the
	-- method, as the Sequence names an emitter ("ReplicatedStorage.Utilities.VFX:Emit"), and the
	-- module's.
	Emitter: { Name: string, Module: string }?,
	-- Where the call is in the code, and whether the Sequence's own emit stands in for it in game:
	-- VFX Forge's always does; a module's does when the call just emits one thing, isn't inside an
	-- if, a loop or a function, and the code uses the module for nothing else.
	From: number,
	To: number,
	Removable: boolean,
}

local FORGE_CALL = "shared%s*%.%s*vfx%s*%.%s*[Ee]mit%s*%("

-- The calls in event code that emit VFX, in order: VFX Forge's `shared.vfx.emit(a, b, ...)`, and
-- an emit method of a module the code requires, as in
--   local VFX = require(game.ReplicatedStorage.Utilities.VFX)
--   VFX:Emit(workspace.Slash)
-- (Part_Icles' `Part_Icles:AbsoluteEmit(a)` is one). People put these events on any item (even
-- Moon's Subtitles), so the event's item says nothing about what's emitted. A module's method only
-- counts when what it's given is a path in the place, or one that's missing from it.
function Exporter.findEmitCalls(code: string): { EmitCall }
	local calls: { EmitCall } = {}

	-- What a call's arguments name: the instances there, and whether they're a path at all. The
	-- code before the call is read too, for the locals they use.
	local function named(open: number, close: number): ({ Instance }, boolean)
		local prefix = string.sub(code, 1, close - 1)
		local isPath = false
		for _, path in pathsInCode(prefix) do
			if path.At > open then
				isPath = true
			end
		end
		return Exporter.findInstancesInCode(prefix, open + 1, true), isPath
	end

	-- Whether the call from `from` to `to` is a statement of its own.
	local function alone(from: number, to: number): boolean
		local before = string.match(string.sub(code, 1, from - 1), "([^\n]*)$") or ""
		local after = string.match(code, "^[^\n]*", to + 1) or ""
		return not string.find(before, "%S") and (not string.find(after, "%S") or string.match(after, "^%s*;?%s*%-%-") ~= nil or string.match(after, "^%s*;%s*$") ~= nil)
	end
	local function oneArgument(open: number, close: number): boolean
		local depth, i = 0, open + 1
		while i < close do
			local c = string.sub(code, i, i)
			if c == '"' or c == "'" then
				local j = i + 1
				while j < close and string.sub(code, j, j) ~= c do
					j += if string.sub(code, j, j) == "\\" then 2 else 1
				end
				i = j
			elseif c == "(" or c == "{" or c == "[" then
				depth += 1
			elseif c == ")" or c == "}" or c == "]" then
				depth -= 1
			elseif c == "," and depth == 0 then
				return false
			end
			i += 1
		end
		return true
	end

	local init = 1
	while true do
		local s, open = string.find(code, FORGE_CALL, init)
		if not s then
			break
		end
		local close = closingParen(code, open) or #code
		table.insert(calls, { Targets = (named(open, close)), From = s, To = close, Removable = true })
		init = close + 1
	end

	-- A module's emit method: through a local holding the module, or straight on require(...).
	-- `module` is the ModuleScript, when it's in the place. The Sequence can only stand in for the
	-- call when it is, and is somewhere it can find it by name.
	local function moduleCall(from: number, module: Instance?, rest: number)
		local _, open, separator, method = string.find(code, "^%s*([:.])%s*([%a_][%w_]*)%s*%(", rest)
		if not open or not string.find(string.lower(method), "emit", 1, true) then
			return
		end
		local close = closingParen(code, open)
		if not close then
			return
		end
		local targets, isPath = named(open, close)
		if not isPath then
			return
		end
		-- Its place as names from a service down, each without a "." or ":" (the Sequence splits on them).
		local place = nil
		if module and module:IsA("ModuleScript") then
			local names, node = {}, module :: Instance?
			while node and node.Parent and node.Parent ~= game do
				table.insert(names, 1, node.Name)
				node = node.Parent
			end
			if node and node.Parent == game then
				table.insert(names, 1, node.Name)
				local text = table.concat(names, ".")
				local _, dots = string.gsub(text, "%.", "")
				if dots == #names - 1 and not string.find(text, ":", 1, true) then
					place = text
				end
			end
		end
		local findable = place ~= nil
		table.insert(calls, {
			Targets = targets,
			Emitter = if findable then { Name = `{place}{separator}{method}`, Module = place :: string } else nil,
			From = from,
			To = close,
			Removable = findable and alone(from, close) and oneArgument(open, close) and blockDepth(code, from) == 0,
		})
	end

	local modules = {}
	init = 1
	while true do
		local s, open = string.find(code, "%f[%w_]require%s*%(", init)
		if not s then
			break
		end
		local close = closingParen(code, open)
		if not close then
			break
		end
		-- The module it requires (through any locals before it, and past a :Clone()).
		local module = Exporter.findInstancesInCode(string.sub(code, 1, close - 1), open + 1, true)[1]
		local name = string.match(string.sub(code, 1, s - 1), "local%s+([%a_][%w_]*)%s*=%s*$")
		if name then
			modules[name] = module or false
		else
			moduleCall(s, module, close + 1)
		end
		init = close + 1
	end
	for name, module in modules do
		local first, uses = #calls + 1, 0
		init = 1
		while true do
			local s, e = string.find(code, `%f[%w_]{name}%f[^%w_]`, init)
			if not s then
				break
			end
			local before = string.sub(code, s - 1, s - 1)
			if before ~= "." and before ~= ":" and not string.match(string.sub(code, 1, s - 1), "local%s+$") then
				uses += 1
				moduleCall(s, module or nil, e + 1)
			end
			init = e + 1
		end
		-- Code that does more with the module (Part_Icles:Activate(), say) keeps all of it.
		if uses > #calls - first + 1 then
			for i = first, #calls do
				calls[i].Removable = false
			end
		end
	end

	table.sort(calls, function(a, b)
		return a.From < b.From
	end)
	return calls
end

-- What the emit calls in event code emit, in order, and how many calls there are (see
-- Exporter.findEmitCalls). A path that isn't in the place emits nothing, as in Moon.
function Exporter.findEmitTargets(code: string): ({ Instance }, number)
	local calls = Exporter.findEmitCalls(code)
	local targets = {}
	for _, call in calls do
		for _, inst in call.Targets do
			if not table.find(targets, inst) then
				table.insert(targets, inst)
			end
		end
	end
	return targets, #calls
end

-- Whether a local's value can go without anything else changing: a module, or an instance path.
local QUIET_METHODS = { GetService = true, WaitForChild = true, FindFirstChild = true, FindFirstChildOfClass = true, FindFirstChildWhichIsA = true, Clone = true }
local function isQuiet(value: string): boolean
	if string.match(value, "^require%s*%(") then
		return true
	end
	if not (string.match(value, "^game%f[^%w_]") or string.match(value, "^workspace%f[^%w_]")) then
		return false
	end
	local bare = string.gsub(string.gsub(value, '"[^"]*"', '""'), "'[^']*'", "''")
	local calls = select(2, string.gsub(bare, "%(", ""))
	local methods = 0
	for method in string.gmatch(bare, ":%s*([%a_][%w_]*)%s*%(") do
		if not QUIET_METHODS[method] then
			return false
		end
		methods += 1
	end
	return calls == methods
end

-- Event code without the emit calls the Sequence's own emit stands in for (see
-- Exporter.findEmitCalls), or the locals only they used: the rest of what it does, or nil when
-- that's nothing.
function Exporter.withoutEmitCalls(code: string, calls: { EmitCall }): string?
	-- The names the calls used, for the locals that may go with them.
	local used: { [string]: boolean } = {}
	local removable = {}
	for _, call in calls do
		if call.Removable then
			table.insert(removable, call)
			for name in string.gmatch(string.sub(code, call.From, call.To), "[%a_][%w_]*") do
				used[name] = true
			end
		end
	end
	table.sort(removable, function(a, b)
		return a.From > b.From
	end)
	for _, call in removable do
		local after = string.match(code, "^%s*;", call.To + 1) or ""
		code = string.sub(code, 1, call.From - 1) .. string.sub(code, call.To + 1 + #after)
	end

	-- A local only those used, set to a module or a path, goes too (and so on, for its value).
	local lines = string.split(code, "\n")
	repeat
		local changed = false
		for i, line in lines do
			local name, value = string.match(line, "^%s*local%s+([%a_][%w_]*)%s*=%s*(.-)%s*;?%s*$")
			if name and used[name] then
				value = string.gsub(value, "%s*%-%-[^\"']*$", "")
				local others = table.clone(lines)
				table.remove(others, i)
				if isQuiet(value) and not usesName(table.concat(others, "\n"), name) then
					for other in string.gmatch(value, "[%a_][%w_]*") do
						used[other] = true
					end
					lines = others
					changed = true
					break
				end
			end
		end
	until not changed

	-- Blank lines where the calls were go, and so does code that's only comments now.
	local kept = {}
	for _, line in lines do
		if string.find(line, "%S") or (kept[#kept] and string.find(kept[#kept], "%S")) then
			table.insert(kept, line)
		end
	end
	local rest = string.gsub(table.concat(kept, "\n"), "%s+$", "")
	local content = string.gsub(string.gsub(rest, "%-%-%[(=*)%[.-%]%1%]", ""), "%-%-[^\n]*", "")
	return if string.find(content, "%S") then rest else nil
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

	-- An emitter or light in a part (or attachment) out of the rig hangs off what that part does.
	local anchor: Instance = object
	local holder = object.Parent
	if not (object:IsA("BasePart") or object:IsA("Model") or object:IsA("Attachment")) and holder and (holder:IsA("BasePart") or holder:IsA("Attachment")) and not holder:IsDescendantOf(pose.Rig) then
		anchor = holder
	end
	local attached = pose:AttachedTo(anchor)
	-- Through parts out of the rig to the rig part they're welded to.
	local hops = 0
	while attached and pose.Linked[attached] and hops < 50 do
		attached = pose:AttachedTo(attached)
		hops += 1
	end
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
	TextLabel = { "Text", "TextColor3", "TextTransparency", "TextSize", "FontFace", "TextScaled", "TextWrapped", "TextStrokeColor3", "TextStrokeTransparency", "TextXAlignment", "TextYAlignment", "RichText", "MaxVisibleGraphemes" },
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
-- effects (blur, color correction, bloom...) wherever they are. Eclipse's are its effect objects.
local function isScreenEffect(item: SaveReader.Item): boolean
	if item.ItemType == "ScreenEffect" then
		return true
	end
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

-- Moon's Subtitles: the text label in its MoonAnimatorEffects GUI that shows lines of text.
local function isMoonSubtitles(item: SaveReader.Item): boolean
	if pathLeaf(item) ~= "Subtitles" then
		return false
	end
	local inst = item.Instance
	if inst then
		return inst:IsA("TextLabel") and inst:FindFirstAncestor("MoonAnimatorEffects") ~= nil
	end
	return table.find(item.PathNames, "MoonAnimatorEffects") ~= nil
end

-- Moon's overlays as Moon makes them, for when it isn't open to copy them from: the piece right
-- under its MoonAnimatorEffects GUI, by name, with its own pieces.
local function moonImage(id: string, name: string?, size: UDim2, position: UDim2?, children: { any }?): any
	return {
		Name = name,
		ClassName = "ImageLabel",
		Properties = {
			Size = size,
			Position = position or UDim2.new(),
			ZIndex = -500,
			BackgroundTransparency = 1,
			Image = "rbxassetid://" .. id,
			ImageColor3 = Color3.new(0, 0, 0),
			ImageTransparency = 1,
			ScaleType = Enum.ScaleType.Stretch,
		},
		Children = children,
	}
end
local function moonBar(name: string, bottom: boolean): any
	return {
		Name = name,
		ClassName = "Frame",
		Properties = {
			Size = UDim2.new(1, 0, 0.12174941, 0),
			Position = UDim2.new(0, 0, if bottom then 1 else 0, 0),
			AnchorPoint = Vector2.new(0, if bottom then 1 else 0),
			ZIndex = -499,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
		},
	}
end
local MOON_TEMPLATES: { [string]: any } = {
	-- Four images tiling a 1920 by 1080 screen (one image can't be that big).
	Vignette = moonImage("4764912210", nil, UDim2.new(0.53333336, 0, 0.94814813, 0), nil, {
		moonImage("4764912960", "UR", UDim2.new(0.875, 0, 1, 0), UDim2.new(1, 0, 0, 0)),
		moonImage("4764912557", "LL", UDim2.new(1, 0, 0.0546875, 0), UDim2.new(0, 0, 1, 0), {
			moonImage("4764912732", "LR", UDim2.new(0.875, 0, 1, 0), UDim2.new(1, 0, 0, 0)),
		}),
	}),
	-- Two bars in a frame; Moon keys the bottom one, named like the frame.
	Letterbox = {
		ClassName = "Frame",
		Properties = { Size = UDim2.fromScale(1, 1), ZIndex = -499, BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1 },
		Children = { moonBar("Top", false), moonBar("Letterbox", true) },
	},
	["Screen Cover"] = {
		ClassName = "Frame",
		Properties = { Size = UDim2.fromScale(1, 1), ZIndex = -501, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1 },
	},
	-- Its text is sized for a 1080 pixel tall screen; Moon scales it to the one it's on.
	Subtitles = {
		ClassName = "TextLabel",
		Properties = {
			Size = UDim2.new(1, 0, 0.700946, 0),
			Position = UDim2.new(0, 0, 0.14952719, 0),
			ZIndex = -498,
			BackgroundTransparency = 1,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Text = "",
			TextSize = 72,
			TextWrapped = true,
			FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal),
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeColor3 = Color3.new(0, 0, 0),
			TextStrokeTransparency = 0,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Bottom,
		},
	},
}

-- One of Moon's overlays from its template (see MOON_TEMPLATES): the template, the names leading
-- from it to the piece the item keys, and its pieces as data (see guiChildren). nil when the item
-- isn't one of Moon's own.
local function fromMoonTemplate(item: SaveReader.Item): (any?, { string }, { any }?)
	local at = table.find(item.PathNames, "MoonAnimatorEffects")
	local names = if at then table.move(item.PathNames, at + 1, #item.PathNames, 1, {}) else {}
	local template = MOON_TEMPLATES[names[1] or ""]
	if not template then
		return nil, {}, nil
	end
	local path = table.move(names, 2, #names, 1, {})
	if names[1] == "Letterbox" and #path == 0 then
		path = { "Letterbox" }
	end

	-- The keyed piece, and the pieces on the way to it.
	local keyed, ancestors = template, {}
	for _, name in path do
		ancestors[keyed] = true
		local found = nil
		for _, child in keyed.Children or {} do
			if child.Name == name then
				found = child
			end
		end
		if not found then
			break
		end
		keyed = found
	end
	local function copy(children: { any }?): { any }?
		if not children then
			return nil
		end
		local out = {}
		for _, child in children do
			table.insert(out, {
				Name = child.Name,
				ClassName = child.ClassName,
				Properties = table.clone(child.Properties),
				Children = copy(child.Children),
				Mirrors = child ~= keyed and child.ClassName == keyed.ClassName and not ancestors[child],
			})
		end
		return out
	end
	return template, path, copy(template.Children)
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
				Bezier = ease and ease.Params and ease.Params.Bezier,
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
-- keys, which the Sequence module recreates and replays. nil if nothing in it is keyed. Moon's
-- Subtitles size their text for the screen, and their last line stays up until the animation ends
-- (`length`, its last frame).
function Exporter.screenCue(item: SaveReader.Item, fps: number, length: number?): Cue?
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
	local template, keyedPath, pieces = fromMoonTemplate(item)
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
	elseif template then
		-- Moon isn't open, so its overlay is made as Moon makes it.
		class, properties, children = template.ClassName, table.clone(template.Properties), pieces
		path = if #keyedPath > 0 then keyedPath else nil
		for name, value in item.Defaults do
			if not path then
				properties[name] = value
			end
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

	local scaleText, hold = nil, nil
	if isMoonSubtitles(item) then
		-- Moon scales its text from 72 on a 1080 pixel tall screen as it plays, so the size it shows
		-- now isn't the one to copy.
		properties.TextSize, scaleText = 72, true
		local lines = item.Tracks.Text
		local last = lines and lines[#lines]
		if last and type(last.Value) == "string" and string.find(last.Value, "%S") and length and length > last.Time then
			hold = math.round((length - first) / fps * 1000) / 1000
		end
	end

	return {
		Frame = first,
		Effect = pathLeaf(item),
		Offset = CFrame.new(),
		Notes = notes,
		Screen = { ClassName = class, Properties = properties, Keys = keys, Children = children, Path = path, Hold = hold, ScaleText = scaleText },
	}
end

-- Eclipse's screen effects -----------------------------------------------------------------------

-- Eclipse Animator's screen effects are models it calls effect objects, drawn as overlays: a
-- vignette (four images tiling the screen), a cover, impact frames, letterbox bars. Each becomes
-- that overlay in a Screen cue, its keys turned into the overlay's properties at every frame (then
-- thinned out, see framesToKeys), from when it starts showing.

local VIGNETTE_IMAGES = { "82598366942133", "106569976373084", "92678033024080", "100796043365951" }
-- Older images Eclipse swaps for those.
local REPLACED_IMAGES = { ["4764912210"] = 1, ["4764912960"] = 2, ["4764912557"] = 3, ["4764912732"] = 4 }
-- Each vignette image's place on a 1920 by 1080 screen: x, y, width, height.
local VIGNETTE_TILES = {
	{ 0, 0, 1024, 1024 },
	{ 1024, 0, 896, 1024 },
	{ 0, 1024, 1024, 56 },
	{ 1024, 1024, 896, 56 },
}

-- The numbers a value is made of, to check a straight line from one key to the next follows it.
-- nil for values that don't blend.
local function numbersOf(value: any): { number }?
	local kind = typeof(value)
	if kind == "number" then
		return { value }
	elseif kind == "Color3" then
		return { value.R, value.G, value.B }
	elseif kind == "UDim2" then
		return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
	elseif kind == "Vector2" then
		return { value.X, value.Y }
	end
	return nil
end

-- A property's value at every frame, as cue keys (seconds from `first`): a value that blends keeps
-- the frames a straight line from the last kept one doesn't follow, one that doesn't (a string, a
-- boolean) the frames it changes on, held until the next.
local function framesToKeys(samples: { { Frame: number, Value: any } }, first: number, fps: number): { any }
	local function key(sample, style: string?)
		return { Time = math.round((sample.Frame - first) / fps * 10000) / 10000, Value = sample.Value, Style = style }
	end
	local numbers = {}
	for i, sample in samples do
		numbers[i] = numbersOf(sample.Value)
	end

	if not numbers[1] then
		local keys = { key(samples[1], "Constant") }
		for i = 2, #samples do
			if samples[i].Value ~= samples[i - 1].Value then
				table.insert(keys, key(samples[i], "Constant"))
			end
		end
		return keys
	end

	local tolerance = {}
	for c = 1, #numbers[1] do
		local low, high = math.huge, -math.huge
		for _, list in numbers do
			low, high = math.min(low, list[c]), math.max(high, list[c])
		end
		tolerance[c] = math.max(1e-4, (high - low) * 2e-3)
	end
	local function fits(from: number, to: number): boolean
		for i = from + 1, to - 1 do
			local alpha = (samples[i].Frame - samples[from].Frame) / (samples[to].Frame - samples[from].Frame)
			for c, value in numbers[i] do
				local line = numbers[from][c] + (numbers[to][c] - numbers[from][c]) * alpha
				if math.abs(value - line) > tolerance[c] then
					return false
				end
			end
		end
		return true
	end

	local keys = { key(samples[1]) }
	local anchor = 1
	for i = 3, #samples do
		if not fits(anchor, i) then
			anchor = i - 1
			table.insert(keys, key(samples[anchor]))
		end
	end
	if #samples > 1 then
		table.insert(keys, key(samples[#samples]))
	end
	return keys
end

-- The share of the screen's height a letterbox bar covers, from its part in front of Eclipse's
-- camera: the bars sit either side of the middle of the view, which is `height` tall there.
local function barCover(top: BasePart, bottom: BasePart, model: Instance, size: number, isTop: boolean): number
	local gap = top.CFrame:ToObjectSpace(bottom.CFrame).Y
	local depth, fov = model:GetAttribute("EffectReferenceDepth"), model:GetAttribute("EffectReferenceFOV")
	local height = if type(depth) == "number" and type(fov) == "number"
		then 2 * depth * math.tan(math.rad(fov) / 2)
		else (math.abs(gap) + top.Size.Y) / 1.5
	if height <= 0 then
		return 0
	end
	local inner = if isTop then -size / 2 - gap / 2 else gap + size / 2 - gap / 2
	return math.clamp(if isTop then (height / 2 - inner) / height else (inner + height / 2) / height, 0, 1)
end

-- The cue for one of Eclipse's camera shakes, from where it starts shaking: its Strength, Speed and
-- Enabled keys, which the Sequence's CameraShake plays as Eclipse does; its pattern (Seed, picked
-- from the effect's id as Eclipse picks it); and how far into the pattern it is by then (Phase:
-- Eclipse's shakes move through theirs from the start of the animation). None if it never shakes.
local function shakeCues(item: SaveReader.Item, fps: number, length: number): { Cue }
	local model = item.Instance
	local function at(id: string, frame: number): any
		local track = item.Tracks[id]
		if track and #track > 0 then
			return Sampler.sample(track, frame)
		end
		local value = if model then model:GetAttribute("Effect" .. id) else nil
		if value == nil then
			value = item.Defaults[id]
		end
		return value
	end
	local function finite(value: any): boolean
		return type(value) == "number" and value == value and math.abs(value) ~= math.huge
	end
	local function speed(frame: number): number
		local value = at("Speed", frame)
		return if finite(value) then math.clamp(value, 0, 60) else 12
	end
	local function strength(frame: number): number
		local value = at("Strength", frame)
		if at("Enabled", frame) == false or not finite(value) then
			return 0
		end
		return math.clamp(value, 0, 100)
	end

	local lastKey = 0
	for _, track in item.Tracks do
		if #track > 0 then
			lastKey = math.max(lastKey, track[#track].Time)
		end
	end
	local finish = math.max(length, lastKey)
	local first = nil
	for frame = 0, finish do
		if strength(frame) > 0 then
			first = frame
			break
		end
	end
	if not first then
		return {}
	end

	-- From the key it starts shaking after, so its keys play from one (see relativeKeys).
	local start = -math.huge
	for _, id in { "Strength", "Enabled" } do
		for _, key in item.Tracks[id] or {} do
			if key.Time <= first then
				start = math.max(start, key.Time)
			end
		end
	end
	if start == -math.huge then
		start = first
	end

	local tracks = {}
	for _, id in { "Strength", "Speed", "Enabled" } do
		local track = item.Tracks[id]
		if track and #track > 0 then
			tracks[id] = track
		end
	end
	local keys = relativeKeys({ Tracks = tracks } :: any, start, fps)
	-- What isn't keyed is as the effect is.
	if not keys.Strength then
		keys.Strength = { { Time = 0, Value = strength(start) } }
	end
	if not keys.Speed and speed(start) ~= 12 then
		keys.Speed = { { Time = 0, Value = speed(start) } }
	end

	-- Where its pattern is by `start`: the speed it moved at, added up from the start.
	local phase = 0
	if tracks.Speed then
		local steps = math.max(1, math.ceil(start * 4))
		local step = start / steps
		for i = 0, steps - 1 do
			local from = i * step
			phase += step / 6 * (speed(from) + 4 * speed(from + step / 2) + speed(from + step))
		end
		phase /= fps
	else
		phase = speed(start) * start / fps
	end

	local seed = 0
	local id = if model then model:GetAttribute("EclipseTrackId") else nil
	id = if type(id) == "string" then id else item.TrackId
	for i = 1, if id then #id else 0 do
		seed = (seed * 31 + string.byte(id :: string, i)) % 65521
	end

	-- Still shaking when its keys end: it goes on until the animation does.
	local hold = if strength(lastKey) > 0 and finish > start then math.round((finish - start) / fps * 1000) / 1000 else nil
	return {
		{
			Frame = start,
			Effect = pathLeaf(item),
			Offset = CFrame.new(),
			Notes = {},
			Animation = { Kind = "Shake", Keys = keys, Hold = hold, Seed = seed, Phase = math.round(phase * 10000) / 10000 },
		},
	}
end

-- The cues for one of Eclipse's effect objects: one (for impact frames, one per image shown), or
-- none when it never shows. `length` is the animation's last frame.
function Exporter.eclipseScreenCues(item: SaveReader.Item, fps: number, length: number, warnings: { string }): { Cue }
	local model = item.Instance
	local kind = if model then model:GetAttribute("EffectKind") else nil
	local name = pathLeaf(item)
	if kind == "Camera Shake" then
		return shakeCues(item, fps, length)
	end

	local defaults: { [string]: any } = {
		Color = Color3.new(0, 0, 0),
		Transparency = 1,
		Size = Vector2.new(1, 1),
		Position = Vector2.new(0, 0),
		Rotation = 0,
		Enabled = true,
		Gradient = false,
		Color2 = Color3.new(1, 1, 1),
		GradientRotation = 90,
		Image = "",
	}
	-- An effect property at a frame: from its keys, else as the effect is.
	local function at(id: string, frame: number): any
		local track = item.Tracks[id]
		if track and #track > 0 then
			return Sampler.sample(track, frame)
		end
		local value = if model then model:GetAttribute("Effect" .. id) else nil
		if value == nil then
			value = item.Defaults[id]
		end
		return if value == nil then defaults[id] else value
	end
	local function shown(frame: number): number
		return if at("Enabled", frame) == false then 1 else math.clamp(at("Transparency", frame), 0, 1)
	end
	local function colour(frame: number): Color3
		return if at("Gradient", frame) == true then Color3.new(1, 1, 1) else at("Color", frame)
	end

	-- From the effect's first key to its last; from the start if it already shows then, and on to
	-- the end of the animation if it still shows when its keys end.
	local first, last = math.huge, -math.huge
	for _, track in item.Tracks do
		if #track > 0 then
			first, last = math.min(first, track[1].Time), math.max(last, track[#track].Time)
		end
	end
	if first == math.huge then
		first, last = 0, 0
	end
	if shown(first) < 1 then
		first = 0
	end
	local function holdFrom(start: number, finish: number): number?
		return if shown(finish) < 1 and length > finish then math.round((length - start) / fps * 1000) / 1000 else nil
	end

	-- One overlay from `start` to `finish`: its root's look, its pieces, the piece its keys play on,
	-- and its keyed properties at a frame.
	local function overlay(start: number, finish: number, class: string, properties: { [string]: any }, children: { any }?, path: { string }?, keyed: (number) -> { [string]: any }, hold: number?): Cue?
		local samples = {}
		local visible = false
		for frame = start, math.max(start, finish) do
			if shown(frame) < 1 then
				visible = true
			end
			for property, value in keyed(frame) do
				samples[property] = samples[property] or {}
				table.insert(samples[property], { Frame = frame, Value = value })
			end
		end
		if not visible then
			return nil
		end

		local keys = {}
		for property, list in samples do
			local changes = false
			for _, sample in list do
				if sample.Value ~= list[1].Value then
					changes = true
				end
			end
			if changes then
				keys[property] = framesToKeys(list, start, fps)
			end
		end
		if model and (item.Tracks.Color or item.Tracks.Color2) and at("Gradient", start) == true then
			table.insert(warnings, `{name}'s colour is keyed while it's a gradient, which isn't exported; it keeps its first colours.`)
		end
		return {
			Frame = start,
			Effect = name,
			Offset = CFrame.new(),
			Notes = if model then {} else { `{name} isn't in the place, so its look is Eclipse's default` },
			Screen = { ClassName = class, Properties = properties, Keys = keys, Children = children, Path = path, Hold = hold },
		}
	end

	-- What every overlay has: centred, sized and turned as the effect is, with its gradient.
	local function frame(start: number): ({ [string]: any }, { any })
		local size, position = at("Size", start), at("Position", start)
		local properties: { [string]: any } = {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(math.max(0.01, size.X), math.max(0.01, size.Y)),
			Position = UDim2.fromScale(0.5 + position.X, 0.5 + position.Y),
			Rotation = at("Rotation", start),
		}
		local children = {}
		if at("Gradient", start) == true then
			table.insert(children, {
				Name = "EffectGradient",
				ClassName = "UIGradient",
				Properties = { Color = ColorSequence.new(at("Color", start), at("Color2", start)), Rotation = at("GradientRotation", start) },
			})
		end
		return properties, children
	end
	local function placed(f: number): { [string]: any }
		local size, position = at("Size", f), at("Position", f)
		return {
			Size = UDim2.fromScale(math.max(0.01, size.X), math.max(0.01, size.Y)),
			Position = UDim2.fromScale(0.5 + position.X, 0.5 + position.Y),
			Rotation = at("Rotation", f),
		}
	end

	if kind == "Vignette" then
		local properties, children = frame(first)
		properties.Size, properties.Position, properties.Rotation = UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), 0
		for i, tile in VIGNETTE_TILES do
			local id = tostring(if model then model:GetAttribute("VignetteImage" .. i) or VIGNETTE_IMAGES[i] else VIGNETTE_IMAGES[i])
			id = if REPLACED_IMAGES[id] then VIGNETTE_IMAGES[REPLACED_IMAGES[id]] else id
			table.insert(children, {
				Name = "Tile" .. i,
				ClassName = "ImageLabel",
				Mirrors = i > 1,
				Properties = {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale((tile[1] + tile[3] / 2) / 1920, (tile[2] + tile[4] / 2) / 1080),
					Size = UDim2.fromScale(tile[3] / 1920, tile[4] / 1080),
					BackgroundTransparency = 1,
					Image = "rbxassetid://" .. id,
					ImageColor3 = colour(first),
					ImageTransparency = shown(first),
				},
			})
		end
		local cue = overlay(first, last, "CanvasGroup", properties, children, { "Tile1" }, function(f)
			return { ImageTransparency = shown(f), ImageColor3 = colour(f) }
		end, holdFrom(first, last))
		return if cue then { cue } else {}
	elseif kind == "Screen Cover" then
		local properties, children = frame(first)
		properties.BackgroundTransparency, properties.BackgroundColor3 = shown(first), colour(first)
		local cue = overlay(first, last, "CanvasGroup", properties, children, nil, function(f)
			local look = placed(f)
			look.BackgroundTransparency, look.BackgroundColor3 = shown(f), colour(f)
			return look
		end, holdFrom(first, last))
		return if cue then { cue } else {}
	elseif kind == "Impact Frames" then
		-- An overlay for each stretch one image shows for: Eclipse's built-in White, Black, Burst and
		-- Inverse frames, or an image asset.
		local cues = {}
		local function piece(image: string): { any }
			local inverse, white = image == "builtin:Inverse", image == "builtin:White"
			local properties: { [string]: any } = { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true }
			local inside = {}
			if string.sub(image, 1, 8) == "builtin:" then
				properties.BackgroundTransparency = 0
				properties.BackgroundColor3 = if white or inverse then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
				if image == "builtin:Burst" or inverse then
					local ray = if inverse then Color3.new(0, 0, 0) else Color3.new(1, 1, 1)
					for n = 0, 23 do
						table.insert(inside, {
							Name = "Ray",
							ClassName = "Frame",
							Properties = {
								AnchorPoint = Vector2.new(0.5, 0.5),
								Position = UDim2.fromScale(0.5, 0.5),
								Size = UDim2.fromScale(2, if n % 3 == 0 then 0.045 else 0.012),
								Rotation = n * 15 + 7,
								BorderSizePixel = 0,
								BackgroundColor3 = ray,
							},
						})
					end
					table.insert(inside, {
						Name = "Core",
						ClassName = "Frame",
						Properties = {
							AnchorPoint = Vector2.new(0.5, 0.5),
							Position = UDim2.fromScale(0.5, 0.5),
							Size = UDim2.fromScale(0.18, 0.3),
							BorderSizePixel = 0,
							BackgroundColor3 = properties.BackgroundColor3,
						},
						Children = { { Name = "UICorner", ClassName = "UICorner", Properties = { CornerRadius = UDim.new(1, 0) } } },
					})
				end
			else
				local id = string.match(image, "^%s*(%d+)%s*$") or string.match(image, "^rbxassetid://(%d+)$")
				table.insert(inside, {
					Name = "Picture",
					ClassName = "ImageLabel",
					Properties = {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Image = if id then "rbxassetid://" .. id else image,
						ScaleType = Enum.ScaleType.Stretch,
					},
				})
			end
			return { { Name = "ImpactImage", ClassName = "CanvasGroup", Properties = properties, Children = if #inside > 0 then inside else nil } }
		end

		local stretchStart, image = first, at("Image", first)
		local function finishStretch(finish: number, final: boolean)
			if image ~= "" then
				local properties, children = frame(stretchStart)
				properties.GroupTransparency, properties.GroupColor3 = shown(stretchStart), colour(stretchStart)
				for _, child in piece(image) do
					table.insert(children, child)
				end
				local hold = if final then holdFrom(stretchStart, finish) else math.round((finish - stretchStart) / fps * 1000) / 1000
				local cue = overlay(stretchStart, finish, "CanvasGroup", properties, children, nil, function(f)
					local look = placed(f)
					look.GroupTransparency, look.GroupColor3 = shown(f), colour(f)
					return look
				end, hold)
				if cue then
					table.insert(cues, cue)
				end
			end
		end
		for f = first + 1, math.max(first, last) do
			local now = at("Image", f)
			if now ~= image then
				finishStretch(f, false)
				stretchStart, image = f, now
			end
		end
		finishStretch(math.max(first, last), true)
		return cues
	elseif kind == "Letterbox" and model and model:GetAttribute("EffectStyle") ~= "Solid" then
		-- A letterbox made of effects: beams and particles on an invisible plane in front of the
		-- camera, which follows the camera on a part rig. It's spawned whole, kept in front of the
		-- camera, and faded and tinted by its keys (on a model, those go to its effects as Eclipse
		-- paints them). The Sequence doesn't emit it: its effects run while it shows.
		local samples = { Transparency = {}, Color = {} }
		local visible = false
		for f = first, math.max(first, last) do
			visible = visible or shown(f) < 1
			table.insert(samples.Transparency, { Frame = f, Value = shown(f) })
			table.insert(samples.Color, { Frame = f, Value = at("Color", f) })
		end
		if not visible then
			return {}
		end
		local keys = {}
		for property, list in samples do
			keys[property] = framesToKeys(list, first, fps)
		end
		if at("Gradient", first) == true then
			table.insert(warnings, `{name}'s gradient isn't exported; it's tinted its first colour.`)
		end
		if item.Tracks.VFXSize then
			table.insert(warnings, `{name}'s VFX Size is keyed, which isn't exported; it keeps the size it has now.`)
		end

		-- Where it is from the camera: its part rig's root stands where Eclipse's camera is.
		local root: BasePart? = nil
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part:GetAttribute("EclipsePartRigRoot") then
				root = part
			end
		end
		local pivot = (model :: Model):GetPivot()
		local camera = if root then root.CFrame else pivot
		local hold = holdFrom(first, last)
		local fov = model:GetAttribute("EffectReferenceFOV")
		return {
			{
				Frame = first,
				Effect = name,
				Offset = camera:ToObjectSpace(pivot),
				Notes = if type(fov) == "number" then { `made for a {fov}° field of view` } else {},
				Object = model,
				Parent = "Camera",
				Emitter = false,
				Lifetime = hold or math.max(1 / fps, math.round((last - first) / fps * 1000) / 1000),
				Animation = { Kind = "Animate", Keys = keys },
			},
		}
	elseif kind == "Letterbox" then
		local top = model and model:FindFirstChild("Top")
		local bottom = model and model:FindFirstChild("Bottom")
		if not (model and top and bottom and top:IsA("BasePart") and bottom:IsA("BasePart")) then
			table.insert(warnings, `{name} is an Eclipse letterbox without its bars, so it's left out.`)
			return {}
		end
		local function cover(isTop: boolean, f: number): number
			local part = (if isTop then top else bottom) :: BasePart
			local keyed = item.Tracks[if isTop then "TopSize" else "BottomSize"]
			local size = if keyed and #keyed > 0 then Sampler.sample(keyed, f) else nil
			local height = if typeof(size) == "Vector3" then math.max(0.001, size.Y) else part.Size.Y
			return barCover(top :: BasePart, bottom :: BasePart, model :: Instance, height, isTop)
		end
		local function bar(barName: string, isTop: boolean, f: number): any
			-- A bar whose size is keyed (an older Eclipse letterbox's) has its own keys for it.
			local keyed = item.Tracks[if isTop then "TopSize" else "BottomSize"]
			local keys = nil
			if keyed and #keyed > 0 then
				local samples = {}
				for frame = f, math.max(f, last) do
					table.insert(samples, { Frame = frame, Value = UDim2.fromScale(1, cover(isTop, frame)) })
				end
				keys = { Size = framesToKeys(samples, f, fps) }
			end
			return {
				Name = barName,
				ClassName = "Frame",
				Mirrors = not isTop,
				Keys = keys,
				Properties = {
					AnchorPoint = Vector2.new(0, if isTop then 0 else 1),
					Position = UDim2.fromScale(0, if isTop then 0 else 1),
					Size = UDim2.fromScale(1, cover(isTop, f)),
					BorderSizePixel = 0,
					BackgroundColor3 = at("Color", f),
					BackgroundTransparency = shown(f),
				},
			}
		end
		local properties = { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0 }
		local cue = overlay(first, last, "Frame", properties, { bar("Top", true, first), bar("Bottom", false, first) }, { "Top" }, function(f)
			return { BackgroundTransparency = shown(f), BackgroundColor3 = at("Color", f) }
		end, holdFrom(first, last))
		return if cue then { cue } else {}
	end

	table.insert(warnings, `{name} is an Eclipse effect of a kind this exporter doesn't know ({tostring(kind)}), so it's left out.`)
	return {}
end

-- Eclipse's subtitles ------------------------------------------------------------------------------

-- A subtitle style as the Sequence needs it: what differs from Eclipse's defaults (with no text of
-- its own), and its words' own looks. A key's is what differs from its subtitle's style (`base`).
local function subtitleStyle(style: { [string]: any }, base: { [string]: any }?): { [string]: any }
	local out = {}
	for key, default in EclipseReader.SUBTITLE_DEFAULTS do
		local from = if base then base[key] elseif key == "Text" then "" else default
		if style[key] ~= from then
			out[key] = style[key]
		end
	end
	-- Words, as text: their looks are only ever strings, numbers and booleans.
	local function words(value: any): string
		local list = {}
		for index, look in if type(value) == "table" then value else {} do
			local fields = {}
			for name, v in look do
				table.insert(fields, `{name}={tostring(v)}`)
			end
			table.sort(fields)
			table.insert(list, `{index}:{table.concat(fields, ",")}`)
		end
		table.sort(list)
		return table.concat(list, ";")
	end
	if words(style.Words) ~= words(if base then base.Words else nil) then
		out.Words = style.Words or {}
	end
	return out
end

-- The cue for one of Eclipse's subtitles, at its frame: what the Sequence's Subtitle draws, with
-- its times in seconds (see the top of the Sequence module).
function Exporter.subtitleCue(subtitle: SaveReader.Subtitle, fps: number): Cue
	local cue = subtitle.Cue
	local function seconds(frames: number): number
		return math.round(frames / fps * 10000) / 10000
	end
	local data: { [string]: any } = {
		Duration = seconds(cue.Duration),
		In = seconds(cue.InFrames),
		Out = seconds(cue.OutFrames),
		Style = subtitleStyle(cue.Base, nil),
	}
	if cue.Entrance ~= "Fade" then
		data.Entrance = cue.Entrance
	end
	if cue.Exit ~= "Fade" then
		data.Exit = cue.Exit
	end
	if cue.Order ~= 0 then
		data.Order = cue.Order
	end
	if #cue.Keys > 0 then
		data.Keys = {}
		for _, key in cue.Keys do
			table.insert(data.Keys, { seconds(key.Frame), subtitleStyle(key.Value, cue.Base), key.Ease })
		end
	end
	return {
		Frame = subtitle.Frame,
		Effect = "Subtitle",
		Offset = CFrame.new(),
		Notes = {},
		Subtitle = data,
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
		Linked = {},
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
				-- What's welded to it from outside goes with it, and so does a model all of whose
				-- parts are (a VFX model welded to a hand).
				local function allLinked(model: Instance): boolean
					for _, desc in model:GetDescendants() do
						if desc:IsA("BasePart") and not pose.Linked[desc] then
							return false
						end
					end
					return true
				end
				for part in pose.Linked do
					ctx.Linked[part] = pose
					local node = part.Parent
					while node and node:IsA("Model") and node ~= workspace and not ctx.Poses[node] and allLinked(node) do
						ctx.Linked[node] = ctx.Linked[node] or pose
						node = node.Parent
					end
				end
			end
		end
	end

	local cues = {}
	local warnings = table.clone(anim.Warnings or {})
	local skipped = {}
	local eventCount = 0
	-- Where the animation was made, for what's said about it.
	local eclipse = anim.Source == "Eclipse"
	local tool = if eclipse then "Eclipse" else "Moon"
	-- The file's frame rate.
	local fps = if anim.FPS > 0 then anim.FPS else 60

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
	-- An Eclipse event (on `item`) can also have code for when it ends, and its code gets locals from
	-- Eclipse: rig (what the event is on), parameter, event and context (a table both parts share).
	local function attachCode(cue: Cue, code: string?, object: Instance?, item: SaveReader.Item?, marker: SaveReader.Marker?)
		local finish = if marker then marker.EndCode else nil
		if not code and not finish then
			return
		end
		-- Modules are required as they are, once, not cloned for each cue.
		code = if code then Exporter.withoutClonedRequires(code) else nil
		finish = if finish then Exporter.withoutClonedRequires(finish) else nil
		cue.Code = code or ""
		if finish and marker then
			cue.EndCode = finish
			cue.EndDelay = math.round(marker.Width / fps * 1000) / 1000
		end

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

		-- Eclipse's locals, for the ones the code uses. rig needs a name in game, like a path would.
		local missing: { string } = {}
		local extra: { Instance } = {}
		if eclipse and marker then
			local text = (code or "") .. "\n" .. (finish or "")
			local locals = {}
			if usesName(text, "rig") then
				local on = item and item.Instance
				local value = if on then names[on] else nil
				if on and value then
					table.insert(locals, { Name = "rig", Value = value })
					table.insert(extra, on)
				else
					table.insert(missing, if on then on.Name elseif item then pathLeaf(item) else "rig")
				end
			end
			if usesName(text, "parameter") then
				table.insert(locals, { Name = "parameter", Value = string.format("%q", marker.Parameter or "") })
			end
			if usesName(text, "event") then
				table.insert(locals, {
					Name = "event",
					Value = string.format("{ Name = %q, Frame = %d, Duration = %d, Parameter = %q }", marker.Name, marker.Frame, marker.Width, marker.Parameter or ""),
				})
			end
			if usesName(text, "context") then
				table.insert(locals, { Name = "context", Value = "{}" })
			end
			cue.Locals = locals
		end

		local adapted, used = Exporter.adaptCode(code or "", names)
		local adaptedEnd, usedEnd = nil, {}
		if finish then
			adaptedEnd, usedEnd = Exporter.adaptCode(finish, names)
		end
		for _, list in { if adapted then {} else used, if finish and not adaptedEnd then usedEnd else {} } do
			for _, name in list do
				if not table.find(missing, name) then
					table.insert(missing, name)
				end
			end
		end
		if #missing > 0 then
			cue.CodeMissing = missing
			table.insert(warnings, `The event at frame {cue.Frame} ("{cue.Effect}") runs code that uses {table.concat(missing, ", ")} from your {tool} scene, which the game won't have, so it can't run as it is. It's in the cue's Function, commented out, to adapt.`)
			return
		end

		local all = table.clone(used)
		for _, list in { usedEnd, extra } do
			for _, inst in list do
				if not table.find(all, inst) then
					table.insert(all, inst)
				end
			end
		end
		local uses, rigs = {}, {}
		for _, inst in all do
			table.insert(uses, { From = inst.Name, To = names[inst] })
			if inst ~= object and home and inst ~= home.Rig then
				table.insert(rigs, inst.Name)
			end
		end
		cue.Adapted = {
			Code = Exporter.addCleanup(adapted :: string),
			EndCode = if adaptedEnd then Exporter.addCleanup(adaptedEnd) else nil,
			Uses = uses,
			Effect = object ~= nil and table.find(all, object) ~= nil,
			Rigs = rigs,
		}
	end

	for _, item in anim.Items do
		-- A screen effect becomes one cue, which the Sequence module plays. So do Moon's Subtitles,
		-- whose events still count for what their code emits (below).
		local subtitles = isMoonSubtitles(item)
		if isScreenEffect(item) or subtitles then
			if item.ItemType == "ScreenEffect" then
				for _, cue in Exporter.eclipseScreenCues(item, fps, anim.Length, warnings) do
					table.insert(cues, cue)
				end
				continue
			end
			local cue = Exporter.screenCue(item, fps, anim.Length)
			if cue then
				table.insert(cues, cue)
			elseif not subtitles then
				for _ in item.Markers do
					skip(item)
				end
			end
			if not subtitles then
				continue
			end
		end

		if #item.Markers == 0 then
			continue
		end

		-- Moon's Subtitles, the camera and other things that aren't VFX objects: their events only
		-- count for what their code emits or names (people put VFX Forge events on Subtitles).
		local notVfx = item.ItemType == "Camera" or (if item.Instance then isNotVfxInstance(item.Instance) else isNotVfxPath(item))

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
			-- A module's emit method is the same, and the Sequence emits through that module (the cue's
			-- Emitter), so the cue needs no Function for it. What else the code does stays (`rest`).
			local emitted, named, whole, calls = {}, {}, {}, 0
			local emitters, byDefault, rest = {}, {}, {}
			-- Whether code that stays still emits something itself (the Sequence then mustn't).
			local stillEmits = false
			for _, code in marker.Code do
				local found = Exporter.findEmitCalls(code)
				calls += #found
				for _, call in found do
					if not call.Removable then
						stillEmits = true
					end
					for _, inst in call.Targets do
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
						if call.Removable then
							if call.Emitter then
								emitters[object] = call.Emitter
							else
								byDefault[object] = true
							end
						end
					end
				end
				local left = if #found > 0 then Exporter.withoutEmitCalls(code, found) else code
				if left then
					table.insert(rest, left)
				end
			end
			-- Eclipse's own emits, each naming what to emit from the item the event is on: Exact emits
			-- the effect it names, Selected the effects right inside what it names, All everything in
			-- it (see EclipseReader).
			local counts = {}
			for _, row in marker.Emits or {} do
				local inst = row.Instance
				local effects: { Instance }? = nil
				if not isEffect(inst) then
					if row.Mode == "Exact" then
						continue
					elseif row.Mode == "Selected" then
						effects = {}
						for _, child in inst:GetChildren() do
							if isEffect(child) then
								table.insert(effects :: { Instance }, child)
							end
						end
						if #(effects :: { Instance }) == 0 then
							continue
						end
					end
				end
				local object = emittedObject(inst)
				if not object then
					continue
				end
				if not table.find(emitted, object) then
					table.insert(emitted, object)
				end
				if effects then
					named[object] = named[object] or {}
					for _, effect in effects do
						if not table.find(named[object], effect) then
							table.insert(named[object], effect)
						end
					end
				elseif object == inst then
					whole[object] = true
				else
					named[object] = named[object] or {}
					table.insert(named[object], inst)
				end
				counts[object] = row.Count or counts[object]
				byDefault[object] = true
			end

			if #emitted > 0 then
				eventCount += 1
				local firstCue = nil
				for _, object in emitted do
					local only = if whole[object] then nil else named[object]
					local name = if only and #only == 1 then only[1].Name else object.Name
					local holder, keep = holdingBeamEnds(object, only)
					local cue = addCue(item, marker, holder, false, #emitted == 1, nil, name)
					cue.Only = keep
					cue.EmitCount = counts[object]
					cue.Emitter = emitters[object]
					cue.DefaultEmit = byDefault[object]
					firstCue = firstCue or cue
				end
				-- What else the event's code does goes on the first cue's Function.
				local leftover = table.concat(rest, "\n")
				local more = if string.find(leftover, "%S") then leftover else nil
				if firstCue and (more or marker.EndCode) then
					attachCode(firstCue, more, firstCue.Object, item, marker)
					if stillEmits then
						firstCue.Emitter = false
					end
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
			local hasCode = code ~= nil or marker.EndCode ~= nil

			-- An Eclipse event with nothing else to play here: one that only switches effects on or
			-- off (their Enabled keys play that), emits nothing in the end, or has no name.
			if eclipse and not hasCode and (marker.Name == "" or #(marker.Switches or {}) > 0 or #(marker.Emits or {}) > 0) then
				continue
			end

			if notVfx or keyedEffect then
				if not hasCode then
					skip(item)
					continue
				end
				eventCount += 1
				local object = codeObjectFor(marker, nil)
				if object then
					attachCode(addCue(item, marker, object, true, true), code, object, item, marker)
				else
					local cue: Cue = {
						Frame = marker.Frame,
						Effect = if marker.Name ~= "" then marker.Name else "Event code",
						Offset = CFrame.new(),
						Notes = {},
					}
					table.insert(cues, cue)
					attachCode(cue, code, nil, item, marker)
				end
				continue
			end

			local object, fromCode = vfxObjectFor(item, marker)

			-- Nothing to spawn: leave the event out. That includes an event on a rig with no name and
			-- no code (only keys in Moon's Events tab, like Damage = 3: markers for the game, which the
			-- animation itself carries), unless every event is measured at a chosen part.
			local inst = item.Instance
			if not object and inst and (not isRig(inst) or (marker.Name == "" and not hasCode and not options.Target)) then
				skip(item)
				continue
			end
			eventCount += 1

			attachCode(addCue(item, marker, object, fromCode, true), code, object, item, marker)
		end
	end

	-- Eclipse's subtitles: each one a cue the Sequence draws as Eclipse does.
	for _, subtitle in anim.Subtitles or {} do
		eventCount += 1
		table.insert(cues, Exporter.subtitleCue(subtitle, fps))
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
								table.insert(cue.Notes, `it's moving in {tool} when this fires, but only where it is at this frame is exported`)
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
