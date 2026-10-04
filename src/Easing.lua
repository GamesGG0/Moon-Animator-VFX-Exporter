--!strict
-- Easing curves for Moon Animator 2 keyframes.
--
-- Moon stores an ease per keyframe as { Type = "Quad", Params = { Direction = "Out", ... } }.
-- When Moon Animator is running we use its own functions (_G.MoonGlobal.EasingFunctions) so the
-- sampled values match the timeline exactly; otherwise we fall back to the Penner curves below,
-- which is what Moon is built on.

local Easing = {}

type EaseFn = (number) -> number

export type EaseInfo = {
	Type: string?,
	Params: { [string]: any }?,
}

local pi = math.pi
local sin, cos, sqrt, asin = math.sin, math.cos, math.sqrt, math.asin

local function power(n: number): EaseFn
	return function(t)
		return t ^ n
	end
end

local function outBounce(t: number): number
	if t < 1 / 2.75 then
		return 7.5625 * t * t
	elseif t < 2 / 2.75 then
		t -= 1.5 / 2.75
		return 7.5625 * t * t + 0.75
	elseif t < 2.5 / 2.75 then
		t -= 2.25 / 2.75
		return 7.5625 * t * t + 0.9375
	else
		t -= 2.625 / 2.75
		return 7.5625 * t * t + 0.984375
	end
end

-- "In" curve for each style. Out / InOut / OutIn are derived from it.
local IN: { [string]: (t: number, params: { [string]: any }) -> number } = {
	Sine = function(t)
		return 1 - cos(t * pi / 2)
	end,
	Quad = power(2),
	Cubic = power(3),
	Quart = power(4),
	Quint = power(5),
	Sextic = power(6),
	Expo = function(t)
		return if t == 0 then 0 else 2 ^ (10 * (t - 1))
	end,
	Circ = function(t)
		return 1 - sqrt(math.max(0, 1 - t * t))
	end,
	Back = function(t, params)
		local s = tonumber(params.Overshoot) or 1.70158
		return t * t * ((s + 1) * t - s)
	end,
	Bounce = function(t)
		return 1 - outBounce(1 - t)
	end,
}

-- Elastic is not symmetric once Amplitude > 1, so both halves are explicit (Penner's equations).
local function elasticShape(params: { [string]: any }): (number, number, number)
	local p = tonumber(params.Period) or 0.3
	local a = tonumber(params.Amplitude) or 1
	if p <= 0 then
		p = 0.3
	end

	local s
	if a < 1 then
		a = 1
		s = p / 4
	else
		s = p / (2 * pi) * asin(1 / a)
	end

	return a, p, s
end

local function inElastic(t: number, params: { [string]: any }): number
	if t <= 0 or t >= 1 then
		return if t <= 0 then 0 else 1
	end

	local a, p, s = elasticShape(params)
	t -= 1
	return -(a * 2 ^ (10 * t) * sin((t - s) * (2 * pi) / p))
end

local function outElastic(t: number, params: { [string]: any }): number
	if t <= 0 or t >= 1 then
		return if t <= 0 then 0 else 1
	end

	local a, p, s = elasticShape(params)
	return a * 2 ^ (-10 * t) * sin((t - s) * (2 * pi) / p) + 1
end

local function curves(style: string, params: { [string]: any }): (EaseFn?, EaseFn?)
	if style == "Elastic" then
		return function(t)
			return inElastic(t, params)
		end, function(t)
			return outElastic(t, params)
		end
	end

	local inFn = IN[style]
	if not inFn then
		return nil, nil
	end

	return function(t)
		return inFn(t, params)
	end, function(t)
		return 1 - inFn(1 - t, params)
	end
end

local function fallback(style: string, direction: string, params: { [string]: any }): EaseFn
	if style == "Linear" then
		return function(t)
			return t
		end
	elseif style == "Constant" then
		return function(t)
			return if t >= 1 then 1 else 0
		end
	end

	if style == "Back" and (direction == "InOut" or direction == "OutIn") then
		-- Penner's InOutBack widens the overshoot.
		params = table.clone(params)
		params.Overshoot = (tonumber(params.Overshoot) or 1.70158) * 1.525
	end

	local easeIn, easeOut = curves(style, params)
	if not (easeIn and easeOut) then
		return function(t)
			return t
		end
	end

	if direction == "Out" then
		return easeOut
	elseif direction == "InOut" then
		return function(t)
			return if t < 0.5 then easeIn(t * 2) / 2 else 0.5 + easeOut(t * 2 - 1) / 2
		end
	elseif direction == "OutIn" then
		return function(t)
			return if t < 0.5 then easeOut(t * 2) / 2 else 0.5 + easeIn(t * 2 - 1) / 2
		end
	end

	return easeIn
end

local function hasCustomParams(params: { [string]: any }): boolean
	return params.Overshoot ~= nil or params.Amplitude ~= nil or params.Period ~= nil
end

-- Moon's live functions are named like "QuadOut", "Linear", "Constant".
local function fromMoon(moonFuncs: { [string]: any }?, style: string, direction: string): EaseFn?
	if type(moonFuncs) ~= "table" then
		return nil
	end

	local fn = moonFuncs[style .. direction]
	if type(fn) ~= "function" then
		fn = moonFuncs[style]
	end
	if type(fn) ~= "function" then
		return nil
	end

	-- Only trust it if it behaves like a 0..1 curve.
	local ok, a, b = pcall(function()
		return fn(0), fn(1)
	end)
	if ok and type(a) == "number" and type(b) == "number" and math.abs(a) < 1e-3 and math.abs(b - 1) < 1e-3 then
		return fn
	end

	return nil
end

-- Returns a function mapping progress (0..1) to an eased alpha for the given Moon ease.
function Easing.get(info: EaseInfo?, moonFuncs: { [string]: any }?): EaseFn
	local style = (info and info.Type) or "Linear"
	local params = (info and info.Params) or {}
	local direction = tostring(params.Direction or "In")

	if not hasCustomParams(params) then
		local live = fromMoon(moonFuncs, style, direction)
		if live then
			return live
		end
	end

	return fallback(style, direction, params)
end

return Easing
