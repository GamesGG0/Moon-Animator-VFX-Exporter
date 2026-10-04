local module = {}

local RunService = game:GetService("RunService")

local Class = {}
Class.__index = Class

-- Sequence is { [Frame] = function(Frame) }, with frames counted at FrameRate (use 1 for keys in seconds).
-- Tolerance: seconds a step may already be overdue when the sequence first reaches it (e.g. Play was called
-- partway through the track) before it is skipped. Frame-rate dips and hitches never skip steps.
function module.new(Sequence, FrameRate, Tolerance)
	local self = setmetatable({}, Class)

	self.Sequence = Sequence or {}
	self.FrameRate = FrameRate or 60
	self.Tolerance = Tolerance or math.huge

	if type(self.FrameRate) ~= "number" or self.FrameRate <= 0 then
		error(`Sequence FrameRate must be a number above 0, got {self.FrameRate}`, 2)
	end
	if type(self.Tolerance) ~= "number" or self.Tolerance < 0 then
		error(`Sequence Tolerance must be a number of seconds (0 or more), got {self.Tolerance}`, 2)
	end
	for Frame, Step in self.Sequence do
		if type(Frame) ~= "number" then
			error(`Sequence keys must be frame numbers, got {typeof(Frame)} "{Frame}"`, 2)
		end
		if type(Step) ~= "function" then
			error(`Sequence step at frame {Frame} must be a function, got {typeof(Step)}`, 2)
		end
	end

	self._Connection = nil
	self.Active = false

	return self
end

-- AnimationAnchor is the AnimationTrack to follow, or a table holding it in .AnimationTrack.
-- Call this after Track:Play(): the sequence stops once the track is no longer playing.
function Class:Play(AnimationAnchor)
	self:Stop()

	local Track = AnimationAnchor
	if typeof(Track) ~= "Instance" and type(Track) == "table" then
		Track = Track.AnimationTrack
	end
	if typeof(Track) ~= "Instance" or not Track:IsA("AnimationTrack") then
		warn(`Sequence:Play needs an AnimationTrack (or a table with one in .AnimationTrack), got {typeof(Track)}`)
		return
	end

	-- Read the steps now so changes to self.Sequence after new() are picked up.
	local Frames = {}
	for Frame in self.Sequence do
		table.insert(Frames, Frame)
	end
	table.sort(Frames)

	local FrameRate = self.FrameRate
	local Late = self.Tolerance * FrameRate
	local Index = 1
	local Previous = Track.TimePosition * FrameRate

	-- Fires every step up to frame UpTo. A step counts as late only if it was due before the previous check.
	local function RunDue(UpTo)
		while Frames[Index] and Frames[Index] <= UpTo do
			local Frame = Frames[Index]
			Index += 1

			local Step = self.Sequence[Frame]
			if Step and Frame >= Previous - Late then
				task.spawn(Step, Frame)
			end
		end
	end

	self.Active = true
	self._Connection = RunService.Heartbeat:Connect(function()
		local Current = Track.TimePosition * FrameRate

		if not Track.IsPlaying then
			-- Steps due between the last check and the moment the track ended still play.
			if Current >= Previous then
				RunDue(Current)
			end
			self:Stop()
			return
		end

		if Current < Previous then
			if Track.Looped then
				-- Wrapped around: finish the steps that were due before the end, then start over.
				RunDue(Track.Length * FrameRate)
				Index = 1
				Previous = 0
			else
				-- Rewound: steps from the new position onwards can play again.
				Index = 1
				while Frames[Index] and Frames[Index] < Current do
					Index += 1
				end
				Previous = Current
			end
		end

		RunDue(Current)
		Previous = Current

		if not Frames[Index] and not Track.Looped then
			self:Stop()
		end
	end)
end

function Class:Stop()
	if self._Connection then
		self._Connection:Disconnect()
		self._Connection = nil
	end

	self.Active = false
end

function Class:Destroy()
	self:Stop()
end

return module
