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
	-- Source of the cue's Function, carried over from the last export (see Carryover).
	Function: string?,
}

export type Result = {
	Cues: { Cue },
	Warnings: { string },
	EventCount: number,
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

-- Follows instance paths written in event code, e.g. workspace["Ripper Test"].ImpactAnti
function Exporter.findInstancesInCode(code: string): { Instance }
	local found = {}
	local Workspace = game:GetService("Workspace")

	local starts = {
		{ pattern = "game%s*:%s*GetService%s*%(%s*[\"']Workspace[\"']%s*%)" },
		{ pattern = "game%s*%.%s*Workspace" },
		{ pattern = "workspace" },
		{ pattern = "Workspace" },
	}

	local function walkChain(pos: number): Instance
		local current: Instance = Workspace
		while true do
			local name, nextPos

			local _, e, captured = string.find(code, "^%s*%.%s*([%a_][%w_]*)", pos)
			if captured then
				name, nextPos = captured, e + 1
			else
				_, e, captured = string.find(code, "^%s*%[%s*\"([^\"]*)\"%s*%]", pos)
				if not captured then
					_, e, captured = string.find(code, "^%s*%[%s*'([^']*)'%s*%]", pos)
				end
				if captured then
					name, nextPos = captured, e + 1
				else
					_, e, captured = string.find(code, "^%s*:%s*[%a]+%s*%(%s*[\"']([^\"']*)[\"']", pos)
					if captured then
						local close = string.find(code, ")", e + 1, true)
						name, nextPos = captured, (close or e) + 1
					end
				end
			end

			if not name then
				break
			end

			local child = current:FindFirstChild(name)
			if not child then
				break
			end

			current = child
			pos = nextPos
		end
		return current
	end

	for _, start in starts do
		local init = 1
		while true do
			local s, e = string.find(code, start.pattern, init)
			if not s then
				break
			end
			init = e + 1

			local before = if s > 1 then string.sub(code, s - 1, s - 1) else ""
			if not string.match(before, "[%w_%.:]") then
				local inst = walkChain(e + 1)
				if inst ~= Workspace and not table.find(found, inst) then
					table.insert(found, inst)
				end
			end
		end
	end

	return found
end

local function pathLeaf(item: SaveReader.Item): string
	return item.PathNames[#item.PathNames] or item.Path
end

local function isPlaceable(inst: Instance): boolean
	return inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Attachment") or inst:IsA("Bone")
end

-- The VFX object an event spawns: the item it sits on, or, for an event on a rig, the part named
-- in its code. The second return says whether it came from the code.
local function vfxObjectFor(item: SaveReader.Item, marker: SaveReader.Marker): (Instance?, boolean)
	local inst = item.Instance
	if inst and not isRig(inst) then
		return inst, false
	end

	for _, code in marker.Code do
		for _, found in Exporter.findInstancesInCode(code) do
			if isPlaceable(found) and not isRig(found) and not (inst and found == rootPartOf(inst)) then
				return found, true
			end
		end
	end

	return nil, false
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
-- with the same name get numbered ("Dust", "Dust2") so a cue always finds its own object.
function Exporter.assignAssets(cues: { Cue })
	local owners: { [string]: Instance } = {}
	local names: { [Instance]: string } = {}

	for _, cue in cues do
		local object = cue.Object
		if not object then
			continue
		end

		local name = names[object]
		if not name then
			local base = object.Name
			name = base
			local n = 1
			while owners[name] do
				n += 1
				name = base .. n
			end
			owners[name] = object
			names[object] = name
		end

		cue.Asset = name
	end
end

-- Offsets are measured from the main character: the picked origin, or the first rig in the
-- animation. In game the cues play on one character, so an effect on another rig (a victim, say)
-- is still placed relative to the main one.
local function originFor(ctx: Context, target: Instance): BasePart?
	if ctx.Options.Origin then
		return ctx.Options.Origin
	end
	if ctx.MainPose then
		return ctx.MainPose.Root
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

-- The part of the main character an effect is connected to, when it isn't the HumanoidRootPart.
-- Set by a "Parent" key in the event's Events tab, or worked out from the VFX object:
--   a part Moon animates through a joint (a limb, an animated weapon)  -> that part itself
--   an attachment, or a part jointed or welded to the rig              -> the part it hangs off
local function parentFor(ctx: Context, marker: SaveReader.Marker, object: Instance): (Instance?, string?)
	local main = ctx.MainPose

	local explicit: string? = nil
	for key, value in marker.Keys do
		if string.lower(key) == "parent" then
			explicit = value
		end
	end

	if explicit then
		if explicit == "" or not main or explicit == main.Root.Name then
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
	if not pose or pose ~= main or object == pose.Root then
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
	table.sort(cues, function(a, b)
		if a.Frame ~= b.Frame then
			return a.Frame < b.Frame
		end
		return a.Effect < b.Effect
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
	}

	for _, item in anim.Items do
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
	local eventCount = 0

	for _, item in anim.Items do
		if #item.Markers == 0 then
			continue
		end

		if not item.Instance then
			table.insert(warnings, `Couldn't find {item.Path} in the place; its events use an empty offset.`)
		end

		for _, marker in item.Markers do
			eventCount += 1

			local notes = {}
			local object, fromCode = vfxObjectFor(item, marker)
			local target, fallbackName, targetNote = targetFor(ctx, item, object, fromCode)
			if targetNote then
				table.insert(notes, targetNote)
			end

			local offset = CFrame.new()
			local parentInst: Instance? = nil
			if target then
				local parentNote
				parentInst, parentNote = parentFor(ctx, marker, object or target)
				if parentNote then
					table.insert(notes, parentNote)
				end

				local otherRig = poseOf(ctx, object or target)
				if ctx.MainPose and otherRig and otherRig ~= ctx.MainPose and not ctx.Options.Origin then
					table.insert(notes, `on {otherRig.Rig.Name}, not {ctx.MainPose.Rig.Name}; placed relative to {ctx.MainPose.Rig.Name}`)
				end

				local origin: Instance? = parentInst or originFor(ctx, target)
				local targetCFrame, cfNote = cframeAt(ctx, target, marker.Frame)

				if not origin then
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

			local effect = fallbackName
			if options.EffectName ~= "Item" and marker.Name ~= "" then
				effect = marker.Name
			end

			table.insert(cues, {
				Frame = marker.Frame, -- in the Moon file's frames until the export rate is chosen
				Effect = effect,
				Offset = offset,
				Notes = notes,
				Object = object,
				Parent = if parentInst then parentInst.Name else nil,
			})
		end
	end

	-- Convert to the export frame rate.
	local fps = if anim.FPS > 0 then anim.FPS else 60
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
		FrameRate = rate,
		FrameRateReason = rateReason,
	}
end

return Exporter
