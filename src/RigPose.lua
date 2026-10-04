--!strict
-- Works out where any part of a Moon Animator rig is at a given frame, from the save alone.
--
-- Checked against real Moon saves: Moon poses a rig by setting each Motor6D's C1 to the keyed
-- value, and moves the whole rig with its CFrame track, whose value is the root part's CFrame. So:
--   root           the rig's CFrame track at the frame (or where it stands, if it never moves)
--   jointed part   its Part0 * C0 * C1:Inverse(), with C1 from the joint's keys
--   welded part    keeps its placement relative to whatever it's welded to
--   anything else  rides the rig as a whole
-- None of this depends on where Moon's playhead was left, unlike the live scene.

local Sampler = require(script.Parent.Sampler)

local RigPose = {}
RigPose.__index = RigPose

export type Joint = { Hier: { string }, Default: CFrame?, Track: { any } }

function RigPose.new(rig: Model, root: BasePart, rootTrack: { any }?, joints: { Joint }?, moonEasing: { [string]: any }?)
	local self = setmetatable({
		Rig = rig,
		Root = root,
		RootTrack = rootTrack,
		MoonEasing = moonEasing,
		Motors = {} :: { [BasePart]: Motor6D }, -- keyed by the part each one moves (Part1)
		Welds = {} :: { [BasePart]: { BasePart } },
		JointTracks = {} :: { [Motor6D]: Joint },
	}, RigPose)

	local motorsByPart0: { [BasePart]: { Motor6D } } = {}
	local function addWeld(a: BasePart, b: BasePart)
		self.Welds[a] = self.Welds[a] or {}
		table.insert(self.Welds[a], b)
	end

	for _, desc in rig:GetDescendants() do
		if desc:IsA("Motor6D") then
			local part0, part1 = desc.Part0, desc.Part1
			if part0 and part1 then
				self.Motors[part1] = desc
				motorsByPart0[part0] = motorsByPart0[part0] or {}
				table.insert(motorsByPart0[part0], desc)
			end
		elseif desc:IsA("JointInstance") or desc:IsA("WeldConstraint") then
			local joint = desc :: any
			local part0, part1 = joint.Part0, joint.Part1
			if part0 and part1 then
				addWeld(part0, part1)
				addWeld(part1, part0)
			end
		end
	end

	-- A joint's _hier ("Torso.Right Arm") names the chain of parts from the root.
	for _, joint in joints or {} do
		local current: BasePart = root
		local motor: Motor6D? = nil
		for _, name in joint.Hier do
			motor = nil
			for _, candidate in motorsByPart0[current] or {} do
				if candidate.Part1 and candidate.Part1.Name == name then
					motor = candidate
					break
				end
			end
			if not motor then
				break
			end
			current = (motor :: Motor6D).Part1 :: BasePart
		end

		if motor then
			self.JointTracks[motor] = joint
		end
	end

	return self
end

function RigPose:RootAt(frame: number): CFrame
	local track = self.RootTrack
	if track and #track > 0 then
		local pivot = Sampler.sample(track, frame, self.MoonEasing)
		if typeof(pivot) == "CFrame" then
			return pivot * self.Rig:GetPivot():ToObjectSpace(self.Root.CFrame)
		end
	end
	return self.Root.CFrame
end

function RigPose:Resolve(part: BasePart, frame: number, visiting: { [BasePart]: boolean }): CFrame?
	if part == self.Root then
		return self:RootAt(frame)
	end
	if visiting[part] then
		return nil
	end
	visiting[part] = true

	local motor = self.Motors[part]
	if motor and motor.Part0 then
		local parent = self:Resolve(motor.Part0, frame, visiting)
		if parent then
			local c1 = motor.C1
			local joint = self.JointTracks[motor]
			if joint then
				local keyed = Sampler.sample(joint.Track, frame, self.MoonEasing)
				if typeof(keyed) == "CFrame" then
					c1 = keyed
				end
			end
			return parent * motor.C0 * c1:Inverse()
		end
	end

	for _, other in self.Welds[part] or {} do
		local otherCFrame = self:Resolve(other, frame, visiting)
		if otherCFrame then
			return otherCFrame * other.CFrame:ToObjectSpace(part.CFrame)
		end
	end

	return nil
end

-- Where `part` (any BasePart inside the rig) is at `frame`.
function RigPose:CFrameAt(part: BasePart, frame: number): CFrame
	local resolved = self:Resolve(part, frame, {})
	if resolved then
		return resolved
	end
	-- Not jointed or welded to the rig: it moves with the rig as a whole.
	return self:RootAt(frame) * self.Root.CFrame:ToObjectSpace(part.CFrame)
end

-- The rig part `inst` hangs off: an attachment's part, or the part it's jointed or welded to.
-- nil when it isn't connected to anything.
function RigPose:AttachedTo(inst: Instance): BasePart?
	if inst:IsA("Attachment") then
		-- Through any attachments it's nested in, to the part they're on.
		local parent = inst.Parent
		while parent and parent:IsA("Attachment") do
			parent = parent.Parent
		end
		return if parent and parent:IsA("BasePart") then parent else nil
	elseif inst:IsA("Model") then
		local primary = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		return if primary then self:AttachedTo(primary) else nil
	elseif inst:IsA("BasePart") then
		local motor = self.Motors[inst]
		if motor and motor.Part0 then
			return motor.Part0
		end
		-- Prefer the neighbour that leads back to the root (the limb, not another accessory).
		local welds = self.Welds[inst]
		if welds then
			for _, other in welds do
				if other == self.Root or self.Motors[other] then
					return other
				end
			end
			return welds[1]
		end
	end
	return nil
end

return RigPose
