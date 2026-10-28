--!strict
-- Eclipse Animator's keyframe curves, from a save alone.
--
-- Eclipse eases each keyframe into the next one like Moon does, with Roblox's easing styles, and
-- those carry over as they are. Its default style is different: "Bezier" with automatic handles,
-- where the curve between two keys also depends on the keys either side (as in Blender's graph
-- editor), and a run of such keys is smoothed so the motion's acceleration doesn't jump. Each
-- stretch of that curve is still one cubic Bézier, so where every part of the value follows the
-- same shape it's a "Bezier" ease with two control points (see Easing.bezier). Values whose parts
-- curve differently (a Vector3 moving on a bent path, say) are sampled at every frame instead,
-- leaving out the samples a straight line between their neighbours already matches.

local Easing = require(script.Parent.Easing)

local EclipseCurves = {}

-- How closely a straight line between kept samples has to follow a sampled stretch, as a share of
-- how far each number moves there.
EclipseCurves.SampleTolerance = 2e-3

-- A keyframe going in. Values is the value as numbers: a number is { n }, a Vector3 or Color3
-- { x, y, z }, a CFrame its position then its rotation as a quaternion { x, y, z, w, i, j, k }
-- (see EclipseCurves.cframeValues). Data is the key as Eclipse saved it: its EasingStyle,
-- EasingDirection, BezierPoints, HandleType...
export type Key = {
	Frame: number,
	Values: { number },
	Data: { [string]: any },
}

-- A keyframe coming out: its frame, its numbers, and how they ease into the next key's.
export type Out = {
	Frame: number,
	Values: { number },
	Ease: Easing.EaseInfo?,
}

local DEFAULT_POINTS = { 0.42, 0, 0.58, 1 }
-- An automatic handle reaches this far towards the neighbouring key, as a share of the gap.
local AUTO_LENGTH = 1 / 2.5614

local ALIASES = {
	Quadratic = "Quad",
	Quartic = "Quart",
	Quintic = "Quint",
	Sinusoidal = "Sine",
	Exponential = "Expo",
	Circular = "Circ",
	CubicV2 = "Cubic",
}
-- With direction "Automatic", these ease out; the rest ease in.
local BOUNCY = { Back = true, Bounce = true, Elastic = true }
local AUTO_HANDLES = { Automatic = true, AutoClamped = true }
local STRAIGHT_HANDLES = { Vector = true, Free = true }
local HANDLES = { Automatic = true, AutoClamped = true, Aligned = true, Vector = true, Free = true }

-- An enum's name, whether the save holds it as a string or as an enum.
local function nameOf(value: any): string?
	if type(value) == "string" then
		return value
	elseif type(value) == "table" and type(value.Name) == "string" then
		return value.Name
	elseif typeof(value) == "EnumItem" then
		return (value :: EnumItem).Name
	end
	return nil
end

-- Whether a key came from a Roblox KeyframeSequence (its easing is a PoseEasingStyle), which
-- Eclipse plays the way Roblox does.
local function isNative(data: { [string]: any }): boolean
	if data.NativePose then
		return true
	end
	local style = data.EasingStyle
	if typeof(style) == "EnumItem" then
		return tostring((style :: EnumItem).EnumType) == "PoseEasingStyle"
	end
	return type(style) == "table" and style.EnumType == "PoseEasingStyle"
end

-- A key's easing style and direction, by Eclipse's names for them (Bezier when it has none).
function EclipseCurves.styleOf(data: { [string]: any }): (string, string)
	local style = nameOf(data.EasingStyle) or "Bezier"
	style = ALIASES[style] or style
	local direction = nameOf(data.EasingDirection) or "Automatic"
	if direction == "Automatic" then
		direction = if BOUNCY[style] then "Out" else "In"
	end
	return style, direction
end

local function handleOf(data: { [string]: any }): string
	local handle = if type(data.HandleType) == "string" then string.gsub(data.HandleType, "%s+", "") else nil
	return if handle and HANDLES[handle] then handle else "AutoClamped"
end

local function pointsOf(data: { [string]: any }): { number }
	local points = data.BezierPoints
	if type(points) == "table" and #points >= 4 then
		return points
	end
	return DEFAULT_POINTS
end

local function isDefaultPoints(data: { [string]: any }): boolean
	local points = pointsOf(data)
	for i, value in DEFAULT_POINTS do
		if type(points[i]) ~= "number" or math.abs(points[i] - value) > 1e-7 then
			return false
		end
	end
	return true
end

-- The easing as one of Moon's (which the exporter and Sequence module already play), or nil when
-- it has no match there.
function EclipseCurves.mapEase(data: { [string]: any }): Easing.EaseInfo?
	local style, direction = EclipseCurves.styleOf(data)
	if style == "Bezier" then
		return nil
	end
	if style == "Linear" or style == "Constant" then
		return if isNative(data) and style == "Constant" then nil else { Type = style, Params = {} }
	end
	if isNative(data) then
		if style == "Bounce" and direction == "InOut" then
			return nil
		elseif style == "Cubic" then
			-- Roblox's own Cubic eases the other way round.
			direction = if direction == "In" then "Out" elseif direction == "Out" then "In" else direction
		end
	end
	if data.Reversed then
		direction = if direction == "In" then "Out" elseif direction == "Out" then "In" else direction
	end
	return {
		Type = style,
		Params = { Direction = direction, Overshoot = data.Overshoot, Amplitude = data.Amplitude, Period = data.Period },
	}
end

-- How far (0 to 1) a key has eased into the next one at `alpha` of the way there, as Eclipse plays
-- a key on its own: its style, or for Bezier its two control points.
function EclipseCurves.ease(data: { [string]: any }, alpha: number): number
	if alpha <= 0 then
		return 0
	elseif alpha >= 1 then
		return 1
	end
	if data.Reversed then
		local forward = table.clone(data)
		forward.Reversed = nil
		return 1 - EclipseCurves.ease(forward, 1 - alpha)
	end

	local style, direction = EclipseCurves.styleOf(data)
	if style == "Bezier" then
		local points = pointsOf(data)
		return Easing.bezier(alpha, points[1], points[2], points[3], points[4])
	end
	if style == "Constant" and isNative(data) then
		-- Roblox's Constant: In jumps to the next value at once, InOut halfway.
		local raw = nameOf(data.EasingDirection) or "In"
		if raw == "In" then
			return 1
		elseif raw == "InOut" then
			return if alpha >= 0.5 then 1 else 0
		end
		return 0
	end
	if style == "Bounce" and direction == "InOut" and isNative(data) then
		local bounceIn = Easing.get({ Type = "Bounce", Params = { Direction = "In" } })
		return if alpha < 0.5 then bounceIn(alpha * 2) / 2 else bounceIn(alpha * 2 - 1) / 2 + 0.5
	end
	return Easing.get(EclipseCurves.mapEase(data))(alpha)
end

-- Automatic Bézier handles -------------------------------------------------------------------

-- How far a key's handles reach towards the keys either side (either can be missing).
local function handleLengths(previous: number?, time: number, following: number?, handle: string): (number, number)
	local left = if previous then time - previous else (following :: number) - time
	local right = if following then following - time else time - (previous :: number)
	if handle == "Vector" then
		return left / 3, right / 3
	end
	return math.min(left, right * 5) * AUTO_LENGTH, math.min(right, left * 5) * AUTO_LENGTH
end

-- The heights of a key's left and right handles: a Vector handle points at its neighbour, an
-- automatic one follows the slope through the neighbours (flat at a peak or dip when clamped).
local function handleHeights(
	previous: number?,
	value: number,
	following: number?,
	previousTime: number?,
	time: number,
	followingTime: number?,
	left: number,
	right: number,
	handle: string
): (number, number)
	if handle == "Vector" then
		local leftSlope = if previous ~= nil
			then (value - previous) / (time - (previousTime :: number))
			else ((following :: number) - value) / ((followingTime :: number) - time)
		local rightSlope = if following ~= nil then (following - value) / ((followingTime :: number) - time) else leftSlope
		return value - leftSlope * left, value + rightSlope * right
	end

	local slope = 0
	if previous ~= nil and following ~= nil then
		local fall, rise = value - previous, following - value
		slope = (fall / (time - (previousTime :: number)) + rise / ((followingTime :: number) - time)) / 2
		if handle == "AutoClamped" then
			if fall * rise <= 0 then
				slope = 0
			else
				local limit = math.min(math.abs(fall) / left, math.abs(rise) / right)
				slope = math.sign(slope) * math.min(math.abs(slope), limit)
			end
		end
	end
	return value - slope * left, value + slope * right
end

-- A point of a smoothed curve: where it is, its handles, and whether smoothing may move them.
type Point = { x: number, y: number, kind: string, locked: boolean, lx: number, ly: number, rx: number, ry: number }

local function isAutoKind(kind: string): boolean
	return kind == "AUTO" or kind == "AUTO_ANIM"
end

local function isFree(point: Point): boolean
	return isAutoKind(point.kind) and not point.locked
end

-- The curve's points with their handles before smoothing: a third of the way to each neighbour,
-- the curve's two ends and (when clamped) its peaks and dips flat and locked in place.
local function curvePoints(times: { number }, values: { number }, handles: { string }): { Point }
	local points = {}
	local count = #times
	for i = 1, count do
		local time, value, handle = times[i], values[i], handles[i]
		local previous, following = if i > 1 then i - 1 else nil, if i < count then i + 1 else nil
		local previousTime, followingTime = if previous then times[previous] else nil, if following then times[following] else nil
		local previousValue, followingValue = if previous then values[previous] else nil, if following then values[following] else nil

		local left, right = handleLengths(previousTime, time, followingTime, handle)
		if AUTO_HANDLES[handle] then
			left = (if previousTime then time - previousTime else (followingTime :: number) - time) / 3
			right = (if followingTime then followingTime - time else time - (previousTime :: number)) / 3
		end
		local ly, ry = handleHeights(previousValue, value, followingValue, previousTime, time, followingTime, left, right, handle)

		local locked = false
		if handle == "AutoClamped" and previousValue ~= nil and followingValue ~= nil then
			local a, b = previousValue - value, followingValue - value
			locked = (a <= 0 and b <= 0) or (a >= 0 and b >= 0)
		end
		if AUTO_HANDLES[handle] and (i == 1 or i == count) then
			ly, ry, locked = value, value, true
		end

		table.insert(points, {
			x = time,
			y = value,
			kind = if handle == "Automatic" then "AUTO" elseif handle == "AutoClamped" then "AUTO_ANIM" elseif handle == "Vector" then "VECT" else "FIXED",
			locked = locked,
			lx = time - left,
			ly = ly,
			rx = time + right,
			ry = ry,
		})
	end
	return points
end

-- Solves a tridiagonal system (arrays from 0 to n - 1): the unknowns, or nil if it can't.
local function tridiagonal(a: { number }, b: { number }, c: { number }, d: { number }, n: number): { number }?
	local cs, ds = {}, {}
	cs[0], ds[0] = c[0] / b[0], d[0] / b[0]
	for i = 1, n - 1 do
		local denominator = b[i] - a[i] * cs[i - 1]
		cs[i] = c[i] / denominator
		ds[i] = (d[i] - a[i] * ds[i - 1]) / denominator
	end
	local x = {}
	x[n - 1] = ds[n - 1]
	for i = n - 2, 0, -1 do
		x[i] = ds[i] - cs[i] * x[i + 1]
	end
	for i = 0, n - 1 do
		if x[i] ~= x[i] or math.abs(x[i]) == math.huge then
			return nil
		end
	end
	return x
end

-- Solves it keeping each unknown within its range: one that goes outside is pinned to the edge it
-- crossed and the rest solved again, and a pinned one is let go if the others pull it back inside.
local function solveWithin(a, b, c, d, low: { number }, high: { number }, n: number): { number }?
	local a0, b0, c0, d0 = table.clone(a), table.clone(b), table.clone(c), table.clone(d)
	local pinned, released = {}, {}
	for i = 0, n - 1 do
		pinned[i], released[i] = false, 0
	end

	for _ = 1, 200 do
		local h = tridiagonal(a, b, c, d, n)
		if not h then
			return nil
		end

		-- Pin what's outside its range, first only where the edge isn't 0, then anywhere.
		local outside, pinnedAny, anywhere = false, false, false
		repeat
			for i = 0, n - 1 do
				if not (h[i] >= low[i] and h[i] <= high[i]) then
					outside = true
					local edge = if h[i] > high[i] then high[i] else low[i]
					if edge ~= 0 or anywhere then
						pinned[i] = true
						a[i], b[i], c[i], d[i] = 0, 1, 0, edge
						pinnedAny = true
					end
				end
			end
			anywhere = true
		until not (outside and not pinnedAny)

		local freed = false
		if not pinnedAny then
			for i = 0, n - 1 do
				if pinned[i] and released[i] < 2 then
					local residual = a0[i] * h[(i + n - 1) % n] + b0[i] * h[i] + c0[i] * h[(i + 1) % n] - d0[i]
					local pull = -residual * b0[i]
					if (pull > 0 and h[i] < high[i]) or (pull < 0 and h[i] > low[i]) then
						a[i], b[i], c[i], d[i] = a0[i], b0[i], c0[i], d0[i]
						pinned[i] = false
						released[i] += 1
						freed = true
					end
				end
			end
		end

		if not (outside or freed) then
			return h
		end
	end
	return nil
end

-- Narrows the range of a handle's height: no turning back against the way the curve goes, and no
-- going past the next key's value.
local function clampRange(high: { number }, low: { number }, i: number, rise: number, clamped: boolean)
	if not clamped then
		return
	end
	if rise > 0 then
		high[i] = math.min(high[i], rise)
		low[i] = 0
	elseif rise < 0 then
		high[i] = 0
		low[i] = math.max(low[i], rise)
	else
		high[i], low[i] = 0, 0
	end
end

-- An end handle that isn't solved, as a height for a handle a third of the gap long, and how much
-- shorter (or longer) than that it is.
local function fixedEnd(length: number, height: number, gap: number): (number, number)
	local factor = gap / (length + gap / 3)
	if factor < 1 then
		length, height = length * factor, height * factor
	end
	return height, 1 - 3 * length / gap
end

local function setHandle(point: Point, right: boolean, height: number, mirror: boolean)
	if not (isAutoKind(point.kind) or point.kind == "VECT") then
		return
	end
	if right then
		point.ry = point.y + height
		if mirror then
			point.lx, point.ly = 2 * point.x - point.rx, 2 * point.y - point.ry
		end
	else
		point.ly = point.y + height
		if mirror then
			point.rx, point.ry = 2 * point.x - point.lx, 2 * point.y - point.ly
		end
	end
end

-- Smooths the handles of the free points from `first` (count points, ends included) so the curve's
-- acceleration is continuous through them, as Blender's graph editor does.
local function smoothRun(points: { Point }, first: number, count: number)
	if count < 2 then
		return
	end
	local total = #points
	local firstPoint, lastPoint = points[first], points[first + count - 1]
	local solveFirst = firstPoint.kind == "VECT" or (first == 1 and isFree(firstPoint))
	local solveLast = lastPoint.kind == "VECT" or (first + count - 1 == total and isFree(lastPoint))
	if count == 2 and solveFirst == solveLast then
		return
	end

	local n = count - 1
	local gaps, rises, ratios = {}, {}, {}
	for i = 1, n do
		gaps[i] = points[first + i].x - points[first + i - 1].x
		rises[i] = points[first + i].y - points[first + i - 1].y
	end
	ratios[0], ratios[n] = 1, 1
	for i = 1, n - 1 do
		ratios[i] = gaps[i + 1] / gaps[i]
	end

	local high, low = {}, {}
	for i = 0, n do
		high[i], low[i] = math.huge, -math.huge
	end
	local clampedBefore, clamped = false, firstPoint.kind == "AUTO_ANIM"
	for i = 1, n do
		clampedBefore = clamped
		clamped = points[first + i].kind == "AUTO_ANIM"
		clampRange(high, low, i - 1, rises[i], clampedBefore)
		clampRange(high, low, i, rises[i] * ratios[i], clamped)
	end

	local a, b, c, d = {}, {}, {}, {}
	local firstAdjust, lastAdjust = 0, 0
	if solveFirst then
		a[0], b[0], c[0], d[0] = 0, 2, 1 / ratios[1], rises[1]
	else
		local height, adjust = fixedEnd(firstPoint.rx - firstPoint.x, firstPoint.ry - firstPoint.y, gaps[1])
		firstAdjust = adjust
		a[0], b[0], c[0], d[0] = 0, 1, 0, height
	end
	if solveLast then
		a[n], b[n], c[n], d[n] = ratios[n] * ratios[n], 2 * ratios[n], 0, rises[n] * ratios[n] * ratios[n]
	else
		local height, adjust = fixedEnd(lastPoint.x - lastPoint.lx, lastPoint.y - lastPoint.ly, gaps[n])
		lastAdjust = adjust
		a[n], b[n], c[n], d[n] = 0, 1, 0, height
	end
	for i = 1, n - 1 do
		a[i] = ratios[i] * ratios[i]
		b[i] = 2 * (ratios[i] + 1)
		c[i] = 1 / ratios[i + 1]
		d[i] = rises[i] * ratios[i] * ratios[i] + rises[i + 1]
	end
	if count > 2 or solveLast then
		b[1] += ratios[1] * firstAdjust
	end
	if count > 2 or solveFirst then
		b[n - 1] += lastAdjust
	end

	local heights = solveWithin(a, b, c, d, low, high, count)
	if not heights then
		return
	end
	for i = 1, n - 1 do
		local point = points[first + i]
		setHandle(point, false, -heights[i] / ratios[i], false)
		setHandle(point, true, heights[i], false)
	end
	if solveFirst then
		setHandle(firstPoint, true, heights[0], first == 1)
	end
	if solveLast then
		setHandle(lastPoint, false, -heights[n] / ratios[n], first + count - 1 == total)
	end
end

-- Smooths every run of free points between the locked ones.
local function smooth(points: { Point })
	local start, count = 1, 1
	for j = 2, #points do
		if not isFree(points[j]) then
			smoothRun(points, start, count + 1)
			start, count = j, 1
		else
			count += 1
		end
	end
	if count > 1 then
		smoothRun(points, start, count)
	end
end

-- The Bézier between two points as an ease: its control points' times as shares of the gap, and
-- their values. Handles reaching past each other are shortened to fit.
local function segmentOf(a: Point, b: Point): (number, number, number, number)
	local duration = b.x - a.x
	local outValue, inValue = a.ry, b.ly
	local right, left = math.abs(a.rx - a.x), math.abs(b.x - b.lx)
	if right + left > duration then
		local factor = duration / (right + left)
		outValue = a.y + (outValue - a.y) * factor
		inValue = b.y + (inValue - b.y) * factor
		right *= factor
		left *= factor
	end
	return right / duration, outValue, 1 - left / duration, inValue
end

-- Quaternions ------------------------------------------------------------------------------------

-- A CFrame as numbers: its position, then its rotation as a quaternion (w, x, y, z).
function EclipseCurves.cframeValues(cf: CFrame): { number }
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local w, i, j, k
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		w, i, j, k = s / 4, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		w, i, j, k = (r21 - r12) / s, s / 4, (r01 + r10) / s, (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		w, i, j, k = (r02 - r20) / s, (r01 + r10) / s, s / 4, (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		w, i, j, k = (r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, s / 4
	end
	return { x, y, z, w, i, j, k }
end

-- Numbers from cframeValues back as a CFrame.
function EclipseCurves.toCFrame(values: { number }): CFrame
	local w, i, j, k = values[4], values[5], values[6], values[7]
	local length = math.sqrt(w * w + i * i + j * j + k * k)
	if length < 1e-12 then
		return CFrame.new(values[1], values[2], values[3])
	end
	w, i, j, k = w / length, i / length, j / length, k / length
	return CFrame.new(
		values[1], values[2], values[3],
		1 - 2 * (j * j + k * k), 2 * (i * j - k * w), 2 * (i * k + j * w),
		2 * (i * j + k * w), 1 - 2 * (i * i + k * k), 2 * (j * k - i * w),
		2 * (i * k - j * w), 2 * (j * k + i * w), 1 - 2 * (i * i + j * j)
	)
end

local function normalizeRotation(values: { number })
	local length = math.sqrt(values[4] ^ 2 + values[5] ^ 2 + values[6] ^ 2 + values[7] ^ 2)
	if length > 1e-12 then
		for c = 4, 7 do
			values[c] /= length
		end
	end
end

-- The rotation `alpha` of the way from a to b along the shortest arc.
local function slerp(a: { number }, b: { number }, alpha: number, out: { number })
	local dot = a[4] * b[4] + a[5] * b[5] + a[6] * b[6] + a[7] * b[7]
	local sign = if dot < 0 then -1 else 1
	dot *= sign
	local wa, wb
	if dot > 0.9995 then
		wa, wb = 1 - alpha, alpha
	else
		local angle = math.acos(math.clamp(dot, -1, 1))
		local sine = math.sin(angle)
		wa, wb = math.sin((1 - alpha) * angle) / sine, math.sin(alpha * angle) / sine
	end
	for c = 4, 7 do
		out[c] = a[c] * wa + b[c] * wb * sign
	end
	normalizeRotation(out)
end

-- Curves -----------------------------------------------------------------------------------------

local function cubic(a: number, b: number, c: number, d: number, u: number): number
	local v = 1 - u
	return a * v * v * v + b * 3 * v * v * u + c * 3 * v * u * u + d * u * u * u
end

-- Whether every key is Bezier with automatic handles, the case Eclipse smooths as one curve.
local function allAutomatic(keys: { Key }): boolean
	for _, key in keys do
		local data = key.Data
		local style = EclipseCurves.styleOf(data)
		if style ~= "Bezier" or not isDefaultPoints(data) or not AUTO_HANDLES[handleOf(data)] then
			return false
		end
		if data.QuaternionInterpolationVersion == 1 or data.PathTangentOut or data.PathTangentIn then
			return false
		end
	end
	return #keys >= 2
end

-- Whether the stretch from `from` to `to` is an automatic Bézier.
local function isAutomatic(from: { [string]: any }, to: { [string]: any }): boolean
	if from.PathTangentOut or to.PathTangentIn then
		return false
	end
	if EclipseCurves.styleOf(from) ~= "Bezier" or not isDefaultPoints(from) then
		return false
	end
	local a, b = handleOf(from), handleOf(to)
	return (AUTO_HANDLES[a] or a == "Vector") and (AUTO_HANDLES[b] or b == "Vector") and (AUTO_HANDLES[a] or AUTO_HANDLES[b]) or false
end

-- A Catmull-Rom style tangent leaving key `at` (or arriving, with `arriving`), per position number.
local function tangent(keys: { Key }, at: number, arriving: boolean, dimensions: number): { number }
	local from, to = if arriving then keys[at - 1] else keys[at], if arriving then keys[at] else keys[at + 1]
	local far = if arriving then keys[at + 1] else keys[at - 1]
	local handle = handleOf((if arriving then to else from).Data)
	local manual = if arriving then to.Data.PathTangentIn else from.Data.PathTangentOut
	if typeof(manual) == "Vector3" then
		return { manual.X, manual.Y, manual.Z }
	end

	local result = {}
	for c = 1, dimensions do
		result[c] = to.Values[c] - from.Values[c]
	end
	if STRAIGHT_HANDLES[handle] or not far then
		return result
	end

	local gap = to.Frame - from.Frame
	local span = if arriving then far.Frame - from.Frame else to.Frame - far.Frame
	local scale = if span > 0 then gap / span else 0
	for c = 1, dimensions do
		local current = if arriving then to.Values[c] else from.Values[c]
		local neighbour = if arriving then from.Values[c] else to.Values[c]
		local auto = (if arriving then far.Values[c] - from.Values[c] else to.Values[c] - far.Values[c]) * scale
		-- Clamped: flat where this key is a peak or a dip.
		if handle == "AutoClamped" and ((current >= neighbour and current >= far.Values[c]) or (current <= neighbour and current <= far.Values[c])) then
			auto = 0
		end
		result[c] = auto
	end
	return result
end

local function hermite(p0: number, p1: number, m0: number, m1: number, t: number): number
	local t2, t3 = t * t, t * t * t
	return p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t) + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)
end

-- Samples a stretch at every frame between its keys (both ends excluded), leaving out the samples
-- a straight line between the ones kept already matches.
local function bake(from: Key, to: Key, valueAt: (number) -> { number }): { Out }
	local frames, samples = {}, {}
	local frame = from.Frame + 1
	while frame < to.Frame - 1e-6 do
		table.insert(frames, frame)
		table.insert(samples, valueAt((frame - from.Frame) / (to.Frame - from.Frame)))
		frame += 1
	end
	table.insert(frames, 1, from.Frame)
	table.insert(samples, 1, from.Values)
	table.insert(frames, to.Frame)
	table.insert(samples, to.Values)

	-- How close a straight line has to come, per number: a small share of how far it moves here.
	local dimensions = #from.Values
	local tolerance = {}
	for c = 1, dimensions do
		local low, high = math.huge, -math.huge
		for _, sample in samples do
			low, high = math.min(low, sample[c]), math.max(high, sample[c])
		end
		tolerance[c] = math.max(1e-6, (high - low) * EclipseCurves.SampleTolerance)
	end
	local function fits(first: number, last: number): boolean
		for i = first + 1, last - 1 do
			local alpha = (frames[i] - frames[first]) / (frames[last] - frames[first])
			for c = 1, dimensions do
				local line = samples[first][c] + (samples[last][c] - samples[first][c]) * alpha
				if math.abs(samples[i][c] - line) > tolerance[c] then
					return false
				end
			end
		end
		return true
	end

	local out = {}
	local anchor = 1
	for i = 3, #samples do
		if not fits(anchor, i) then
			anchor = i - 1
			table.insert(out, { Frame = frames[anchor], Values = samples[anchor] })
		end
	end
	return out
end

-- The keys a track plays, from Eclipse's. Stretches that ease as one of Moon's easings, or as a
-- Bezier ease, keep their keys; the rest gain sampled ones (see bake). `rotation` says the values
-- are a CFrame's (see cframeValues), whose rotation is blended as a rotation.
function EclipseCurves.track(keys: { Key }, rotation: boolean?): { Out }
	local count = #keys
	if count == 0 then
		return {}
	end
	local dimensions = #keys[1].Values
	local positions = if rotation then 3 else dimensions

	-- A rotation can be held by either sign of its quaternion; keep each one on the side of the last.
	if rotation then
		for i = 2, count do
			local a, b = keys[i - 1].Values, keys[i].Values
			if a[4] * b[4] + a[5] * b[5] + a[6] * b[6] + a[7] * b[7] < 0 then
				local flipped = table.clone(b)
				for c = 4, 7 do
					flipped[c] = -flipped[c]
				end
				keys[i] = { Frame = keys[i].Frame, Values = flipped, Data = keys[i].Data }
			end
		end
	end

	-- All automatic: one smoothed curve per number.
	local curves: { { Point } }? = nil
	if allAutomatic(keys) then
		local made = {}
		local times = {}
		local handles = {}
		for i, key in keys do
			times[i] = key.Frame
			handles[i] = handleOf(key.Data)
		end
		for c = 1, dimensions do
			local values = {}
			for i, key in keys do
				values[i] = key.Values[c]
			end
			local points = curvePoints(times, values, handles)
			smooth(points)
			made[c] = points
		end
		curves = made
	end

	-- The automatic Bézier from key i to i + 1 for number c: its control points' times (as shares
	-- of the gap) and values.
	local function automatic(i: number, c: number): (number, number, number, number)
		if curves then
			return segmentOf(curves[c][i], curves[c][i + 1])
		end
		local before, from, to, after = keys[i - 1], keys[i], keys[i + 1], keys[i + 2]
		local fromHandle, toHandle = handleOf(from.Data), handleOf(to.Data)
		local fromLeft, fromRight = handleLengths(before and before.Frame, from.Frame, to.Frame, fromHandle)
		local toLeft, toRight = handleLengths(from.Frame, to.Frame, after and after.Frame, toHandle)
		local _, outValue = handleHeights(
			before and before.Values[c], from.Values[c], to.Values[c],
			before and before.Frame, from.Frame, to.Frame, fromLeft, fromRight, fromHandle
		)
		local inValue = handleHeights(
			from.Values[c], to.Values[c], after and after.Values[c],
			from.Frame, to.Frame, after and after.Frame, toLeft, toRight, toHandle
		)
		local duration = to.Frame - from.Frame
		return fromRight / duration, outValue, 1 - toLeft / duration, inValue
	end

	local out: { Out } = {}
	for i = 1, count - 1 do
		local from, to = keys[i], keys[i + 1]
		local entry: Out = { Frame = from.Frame, Values = from.Values }
		table.insert(out, entry)

		local still = true
		for c = 1, dimensions do
			if from.Values[c] ~= to.Values[c] then
				still = false
			end
		end
		if still then
			continue
		end

		if isAutomatic(from.Data, to.Data) then
			local segments = {}
			for c = 1, dimensions do
				segments[c] = { automatic(i, c) }
			end
			local function valueAt(alpha: number): { number }
				local values = {}
				for c = 1, dimensions do
					local segment = segments[c]
					values[c] = cubic(from.Values[c], segment[2], segment[4], to.Values[c], Easing.bezierParameter(alpha, segment[1], segment[3]))
				end
				if rotation then
					normalizeRotation(values)
				end
				return values
			end

			-- One ease for all of it, from the number that moves most, if every number follows it.
			local lead, most = 1, -1
			for c = 1, dimensions do
				local moved = math.abs(to.Values[c] - from.Values[c])
				if moved > most then
					lead, most = c, moved
				end
			end
			local segment = segments[lead]
			local span = to.Values[lead] - from.Values[lead]
			local points = {
				segment[1],
				(segment[2] - from.Values[lead]) / span,
				segment[3],
				(segment[4] - from.Values[lead]) / span,
			}
			local shared = true
			for _, alpha in { 0.1, 0.25, 0.5, 0.75, 0.9 } do
				local eased = Easing.bezier(alpha, points[1], points[2], points[3], points[4])
				local actual = valueAt(alpha)
				for c = 1, positions do
					local moved = to.Values[c] - from.Values[c]
					if math.abs(actual[c] - (from.Values[c] + moved * eased)) > math.max(1e-4, math.abs(moved) * 1e-3) then
						shared = false
					end
				end
				-- A rotation is played as a turn along the shortest arc, so it's compared as one.
				if rotation then
					local turned = table.clone(actual)
					slerp(from.Values, to.Values, eased, turned)
					local dot = 0
					for c = 4, 7 do
						dot += actual[c] * turned[c]
					end
					if math.abs(dot) < math.cos(5e-4) then
						shared = false
					end
				end
			end
			if shared then
				entry.Ease = { Type = "Bezier", Params = { Bezier = points } }
			else
				for _, sample in bake(from, to, valueAt) do
					table.insert(out, sample)
				end
			end
			continue
		end

		local style = EclipseCurves.styleOf(from.Data)
		local manual = from.Data.PathTangentOut ~= nil or to.Data.PathTangentIn ~= nil
		if style ~= "Bezier" and not manual then
			local mapped = EclipseCurves.mapEase(from.Data)
			if mapped then
				entry.Ease = mapped
			else
				for _, sample in bake(from, to, function(alpha)
					local eased = EclipseCurves.ease(from.Data, alpha)
					local values = {}
					for c = 1, positions do
						values[c] = from.Values[c] + (to.Values[c] - from.Values[c]) * eased
					end
					if rotation then
						slerp(from.Values, to.Values, eased, values)
					end
					return values
				end) do
					table.insert(out, sample)
				end
			end
			continue
		end

		-- Bezier with its own control points: eased by them, and when its handles aren't straight,
		-- curved through the neighbouring keys as well.
		local straight = not manual and STRAIGHT_HANDLES[handleOf(from.Data)] and STRAIGHT_HANDLES[handleOf(to.Data)]
		if straight then
			local points = pointsOf(from.Data)
			entry.Ease = { Type = "Bezier", Params = { Bezier = { points[1], points[2], points[3], points[4] } } }
			continue
		end
		local leaving = tangent(keys, i, false, positions)
		local arriving = tangent(keys, i + 1, true, positions)
		for _, sample in bake(from, to, function(alpha)
			local eased = EclipseCurves.ease(from.Data, alpha)
			local values = {}
			for c = 1, positions do
				values[c] = hermite(from.Values[c], to.Values[c], leaving[c], arriving[c], eased)
			end
			if rotation then
				slerp(from.Values, to.Values, eased, values)
			end
			return values
		end) do
			table.insert(out, sample)
		end
	end
	table.insert(out, { Frame = keys[count].Frame, Values = keys[count].Values })
	return out
end

return EclipseCurves
