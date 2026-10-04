--!strict
-- Evaluates a Moon Animator keyframe track at a given frame.
--
-- Matches Moon's playback: the ease stored on a keyframe shapes the transition from that
-- keyframe to the next one, and the value holds before the first and after the last keyframe.

local Easing = require(script.Parent.Easing)

local Sampler = {}

export type Keyframe = {
	Time: number,
	Value: any,
	Ease: Easing.EaseInfo?,
}

local function lerp(a: any, b: any, t: number): any
	if type(a) == "number" and type(b) == "number" then
		return a + (b - a) * t
	end

	local ok, result = pcall(function()
		return a:Lerp(b, t)
	end)
	if ok then
		return result
	end

	-- Booleans, strings, instances etc. don't interpolate.
	return if t >= 1 then b else a
end

-- `sequence` must be sorted by Time.
function Sampler.sample(sequence: { Keyframe }, frame: number, moonEasing: { [string]: any }?): any
	local count = #sequence
	if count == 0 then
		return nil
	end

	if frame <= sequence[1].Time then
		return sequence[1].Value
	end

	for i = 1, count - 1 do
		local from = sequence[i]
		local to = sequence[i + 1]

		if frame < to.Time then
			local span = to.Time - from.Time
			if span <= 0 then
				return to.Value
			end

			local ease = Easing.get(from.Ease, moonEasing)
			return lerp(from.Value, to.Value, ease((frame - from.Time) / span))
		end
	end

	return sequence[count].Value
end

return Sampler
