-- Test cases. Appended after mocks.luau and the wrapped modules by run.py.

local Easing = __load("Easing")
local Sampler = __load("Sampler")
local SaveReader = __load("SaveReader")
local Exporter = __load("Exporter")
local Formatter = __load("Formatter")
local MoonHook = __load("MoonHook")

local passed, failed = 0, 0

local function check(name: string, ok: boolean, detail: any?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then "\n      " .. tostring(detail) else ""}`)
	end
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

local function cfNear(a: any, b: any): boolean
	local ca, cb = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if not near(ca[i], cb[i], 1e-5) then
			return false
		end
	end
	return true
end

local function ease(style: string, direction: string?, params: { [string]: any }?)
	local p = params or {}
	p.Direction = direction
	return Easing.get({ Type = style, Params = p })
end

-- Easing -------------------------------------------------------------------------------------

check("linear midpoint", near(ease("Linear")(0.5), 0.5))
check("quad in", near(ease("Quad", "In")(0.5), 0.25))
check("quad out", near(ease("Quad", "Out")(0.5), 0.75))
check("quad inout first half", near(ease("Quad", "InOut")(0.25), 0.125))
check("quad inout second half", near(ease("Quad", "InOut")(0.75), 0.875))
check("quad outin first half", near(ease("Quad", "OutIn")(0.25), 0.375))
check("constant holds", ease("Constant")(0.99) == 0 and ease("Constant")(1) == 1)
check("back in default overshoot", near(ease("Back", "In")(0.5), -0.0876975), ease("Back", "In")(0.5))
check("no ease info is linear", near(Easing.get(nil)(0.3), 0.3))
check("unknown style is linear", near(ease("Wobbly", "In")(0.3), 0.3))

for _, style in { "Sine", "Quad", "Cubic", "Quart", "Quint", "Sextic", "Expo", "Circ", "Back", "Elastic", "Bounce" } do
	for _, direction in { "In", "Out", "InOut", "OutIn" } do
		local fn = ease(style, direction)
		check(`{style}{direction} endpoints`, near(fn(0), 0, 1e-3) and near(fn(1), 1, 1e-3), `{fn(0)} {fn(1)}`)
	end
end

local moonEasing = {
	QuadOut = function(t)
		return t -- deliberately different so we can tell it was used
	end,
	CubicIn = function()
		return nil
	end,
}
check("prefers Moon's own easing", near(Easing.get({ Type = "Quad", Params = { Direction = "Out" } }, moonEasing)(0.5), 0.5))
check("ignores broken Moon easing", near(Easing.get({ Type = "Cubic", Params = { Direction = "In" } }, moonEasing)(0.5), 0.125))
check(
	"custom params skip Moon's easing",
	not near(Easing.get({ Type = "Quad", Params = { Direction = "Out", Overshoot = 2 } }, moonEasing)(0.5), 0.5)
)

-- Sampler ------------------------------------------------------------------------------------

local linearSeq = { { Time = 0, Value = 0 }, { Time = 10, Value = 10 } }
check("sample midpoint", near(Sampler.sample(linearSeq, 5), 5))
check("sample holds before first key", Sampler.sample(linearSeq, -3) == 0)
check("sample holds after last key", Sampler.sample(linearSeq, 20) == 10)
check("sample exactly on key", Sampler.sample(linearSeq, 10) == 10)
check("sample empty", Sampler.sample({}, 3) == nil)

local easedSeq = {
	{ Time = 0, Value = 0, Ease = { Type = "Quad", Params = { Direction = "Out" } } },
	{ Time = 10, Value = 10 },
}
check("start key's ease shapes the segment", near(Sampler.sample(easedSeq, 5), 7.5))

local constantSeq = { { Time = 0, Value = 0, Ease = { Type = "Constant", Params = {} } }, { Time = 10, Value = 10 } }
check("constant ease holds until next key", Sampler.sample(constantSeq, 9) == 0 and Sampler.sample(constantSeq, 10) == 10)

local cfSeq = { { Time = 0, Value = CFrame.new(0, 0, 0) }, { Time = 4, Value = CFrame.new(4, 8, 0) } }
check("cframe lerp", cfNear(Sampler.sample(cfSeq, 1), CFrame.new(1, 2, 0)))

-- Fixture: a rig with VFX parts and a Moon save ----------------------------------------------

local function folder(name: string, parent: any)
	return Instance.new("Folder", { Name = name, Parent = parent })
end

local function value(className: string, name: string, v: any, parent: any)
	return Instance.new(className, { Name = name, Value = v, Parent = parent })
end

-- Moon's keyframe layout: <track>/<frame>/Values/<n>, <track>/<frame>/Eases/<n>/{Type, Params}
local function keyframe(track: any, frame: number, values: { any }, eases: { [number]: string }?)
	local pack = folder(tostring(frame), track)
	local valuesBin = folder("Values", pack)
	for i, v in values do
		value("CFrameValue", tostring(i - 1), v, valuesBin)
	end
	if eases then
		local easesBin = folder("Eases", pack)
		for index, style in eases do
			local easeInst = folder(tostring(index), easesBin)
			value("StringValue", "Type", style, easeInst)
			local params = folder("Params", easeInst)
			value("StringValue", "Direction", "In", params)
		end
	end
end

local function marker(track: any, frame: number, name: string, code: string?)
	local m = folder(tostring(frame), track)
	value("StringValue", "name", name, m)
	value("IntValue", "width", 0, m)
	folder("KFMarkers", m)
	if code then
		value("StringValue", "CodeBegin", code, m)
	end
end

local function path(...)
	local names = { "Game", "Workspace", ... }
	local types = { "DataModel", "Workspace" }
	for i = 3, #names do
		types[i] = if i == 3 then "Model" else "Part"
	end
	return { InstanceNames = names, InstanceTypes = types, ItemType = if #names == 3 then "Rig" else "Part" }
end

local rig = Instance.new("Model", { Name = "Ripper Test", Parent = game:GetService("Workspace") })
local hrpCFrame = CFrame.new(10, 3, 5) * CFrame.Angles(0, math.pi / 2, 0)
local hrp = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = hrpCFrame, Parent = rig })
rig.PrimaryPart = hrp
Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
local impact = Instance.new("Part", { Name = "ImpactAnti", Parent = rig })
local swordDust = Instance.new("Part", { Name = "SwordDust", Parent = rig })
local shine = Instance.new("Part", { Name = "Shine", CFrame = CFrame.new(12, 4, 2), Parent = rig })

local cfA = CFrame.new(10, 4, 1)
local cfB = CFrame.new(14, 4, 1) * CFrame.Angles(0, 0.3, 0)
local cfC = CFrame.new(9, 3, 9)
local cfD = CFrame.new(8, 3, 9)

local saves = folder("MoonAnimator2Saves", game:GetService("ServerStorage"))
local save = value("StringValue", "Ripper Test", mockJson({
	Information = { Length = 360, FPS = 60, Modified = 1700000000, Looped = false },
	Items = {
		{ Path = path("Ripper Test") },
		{ Path = path("Ripper Test", "ImpactAnti") },
		{ Path = path("Ripper Test", "SwordDust") },
		{ Path = path("Ripper Test", "Shine") },
		{ Path = path("Ripper Test", "Missing") },
	},
}), saves)

do -- 1: the rig, with an event whose code names the Shine part
	local item = folder("1", save)
	folder("Rig", item)
	marker(folder("MarkerTrack", item), 5, "Spawn", 'shared.vfx.emit(workspace["Ripper Test"].Shine)')
end

do -- 2: ImpactAnti, linear move from cfA (frame 0) to cfB (frame 20)
	local item = folder("2", save)
	local cframe = folder("CFrame", item)
	keyframe(cframe, 0, { cfA }, { [0] = "Linear" })
	keyframe(cframe, 20, { cfB })
	local markers = folder("MarkerTrack", item)
	marker(markers, 10, "", 'shared.vfx.emit(workspace["Ripper Test"].ImpactAnti)')
	marker(markers, 30, "Hit")
end

do -- 3: SwordDust, one pack holding two consecutive frames (40, 41)
	local item = folder("3", save)
	keyframe(folder("CFrame", item), 40, { cfC, cfD })
	local markers = folder("MarkerTrack", item)
	marker(markers, 41, "")
	marker(markers, 10, "") -- same frame as ImpactAnti's first event
end

do -- 4: Shine, not keyed
	folder("4", save)
end

do -- 5: an item that no longer exists in the place
	marker(folder("MarkerTrack", folder("5", save)), 50, "")
end

value("StringValue", "Older", mockJson({
	Information = { Length = 120, FPS = 60, Modified = 1600000000 },
	Items = {},
}), saves)
value("StringValue", "NotASave", "hello", saves)

-- SaveReader ---------------------------------------------------------------------------------

local found = SaveReader.findSaves()
check("finds both saves", #found == 2, #found)
check("newest save first", found[1] and found[1].Name == "Ripper Test" and found[2].Name == "Older")
check("reads length and fps", found[1].Length == 360 and found[1].FPS == 60)

local anim = SaveReader.load(save)
check("loads every item", #anim.Items == 5, #anim.Items)
check("resolves item paths", anim.Items[2].Instance == impact and anim.Items[1].Instance == rig)
check("missing item resolves to nil", anim.Items[5].Instance == nil)
check("reads keyframes", #anim.Items[2].Tracks.CFrame == 2)
check("reads eases", anim.Items[2].Tracks.CFrame[1].Ease.Type == "Linear")
check("expands multi-frame packs", anim.Items[3].Tracks.CFrame[2].Time == 41)
check("rig joints are skipped", anim.Items[1].Tracks.Rig == nil)
check("reads markers sorted", #anim.Items[2].Markers == 2 and anim.Items[2].Markers[1].Frame == 10)
check("reads marker name", anim.Items[2].Markers[2].Name == "Hit")
check("reads marker code", anim.Items[1].Markers[1].Code[1] == 'shared.vfx.emit(workspace["Ripper Test"].Shine)')
check("dump mentions items", string.find(SaveReader.dump(save), "Item 2: Game.Workspace.Ripper Test.ImpactAnti", 1, true) ~= nil)

local ok, err = pcall(SaveReader.load, saves:FindFirstChild("NotASave"))
check("rejects non-saves", not ok and string.find(tostring(err), "not a Moon Animator 2 save", 1, true) ~= nil, err)

-- Code paths ---------------------------------------------------------------------------------

local function codeTargets(code: string)
	local names = {}
	for _, inst in Exporter.findInstancesInCode(code) do
		table.insert(names, inst.Name)
	end
	return table.concat(names, ",")
end

check("code: bracket path", codeTargets('shared.vfx.emit(workspace["Ripper Test"].ImpactAnti)') == "ImpactAnti")
check(
	"code: WaitForChild chain",
	codeTargets("game.Workspace:WaitForChild(\"Ripper Test\"):FindFirstChild('Shine')") == "Shine"
)
check("code: GetService", codeTargets('game:GetService("Workspace")["Ripper Test"].SwordDust:Emit(5)') == "SwordDust")
check("code: unknown path", codeTargets("workspace.Nope.Thing") == "")

-- Exporter -----------------------------------------------------------------------------------

local result = Exporter.collect(anim, { EffectName = "Event", FrameRate = 60 })
local byFrame = {}
local frames = {}
for _, cue in result.Cues do
	byFrame[cue.Frame] = cue
	table.insert(frames, cue.Frame)
end

check("cue frames", table.concat(frames, ",") == "5,10,11,30,41,50", table.concat(frames, ","))
check("event count", result.EventCount == 6)
check("warns about missing items", #result.Warnings == 1, result.Warnings[1])

local function expectOffset(frame: number, effect: string, world: any)
	local cue = byFrame[frame]
	check(`cue {frame} effect`, cue and cue.Effect == effect, cue and cue.Effect)
	check(`cue {frame} offset`, cue and cfNear(cue.Offset, hrpCFrame:ToObjectSpace(world)), cue and tostring(cue.Offset))
end

expectOffset(5, "Spawn", shine.CFrame)
expectOffset(10, "ImpactAnti", cfA:Lerp(cfB, 0.5))
expectOffset(11, "SwordDust", cfC)
expectOffset(30, "Hit", cfB)
expectOffset(41, "SwordDust", cfD)

check("rig event notes where it measured", byFrame[5].Notes[1] and string.find(byFrame[5].Notes[1], "Shine", 1, true) ~= nil)
check("shifted cue is noted", byFrame[11].Notes[1] and string.find(byFrame[11].Notes[1], "moved from frame 10", 1, true) ~= nil)
check("missing item cue", byFrame[50].Effect == "Missing" and cfNear(byFrame[50].Offset, CFrame.new()) and #byFrame[50].Notes == 1)
check("clean cues have no notes", #byFrame[10].Notes == 0 and #byFrame[30].Notes == 0)

local itemNames = Exporter.collect(anim, { EffectName = "Item", FrameRate = 60 })
check("item naming ignores event names", itemNames.Cues[4].Effect == "ImpactAnti", itemNames.Cues[4].Effect)

local overridden = Exporter.collect(anim, { EffectName = "Event", Target = shine, FrameRate = 60 })
check("target override measures every cue at it", cfNear(overridden.Cues[2].Offset, hrpCFrame:ToObjectSpace(shine.CFrame)))
check("target override keeps item names", overridden.Cues[2].Effect == "ImpactAnti", overridden.Cues[2].Effect)

local origin = Instance.new("Part", { Name = "Origin", CFrame = CFrame.new(0, 10, 0), Parent = game:GetService("Workspace") })
local custom = Exporter.collect(anim, { EffectName = "Event", Origin = origin, FrameRate = 60 })
check("origin override", cfNear(custom.Cues[4].Offset, CFrame.new(0, 10, 0):ToObjectSpace(cfB)))

-- A rig whose own CFrame is keyed: the HumanoidRootPart moves with it.
do
	local moved = hrpCFrame * CFrame.new(0, 0, -10)
	local movingSave = value("StringValue", "Moving", mockJson({
		Information = { Length = 120, FPS = 60, Modified = 1650000000 },
		Items = { { Path = path("Ripper Test") }, { Path = path("Ripper Test", "Shine") } },
	}), saves)

	local rigItem = folder("1", movingSave)
	local rigTrack = folder("CFrame", rigItem)
	keyframe(rigTrack, 0, { hrpCFrame })
	keyframe(rigTrack, 60, { moved })
	marker(folder("MarkerTrack", folder("2", movingSave)), 60, "Burst")

	local movingResult = Exporter.collect(SaveReader.load(movingSave), { EffectName = "Event" })
	check("follows a keyed rig", cfNear(movingResult.Cues[1].Offset, moved:ToObjectSpace(shine.CFrame)))
	movingSave.Parent = nil
end

-- Formatter ----------------------------------------------------------------------------------

local savage = Formatter.format({
	TableName = "Savage",
	Lifetime = 6,
	CueTolerance = 0.15,
	Cues = {
		{ Frame = 0, Effect = "Start", Offset = CFrame.new(-0.0599994659, 1.69000387, -2.71000004, 1, 0, 0, 0, 1, 0, 0, 0, 1) },
		{ Frame = 27, Effect = "Hit", Offset = CFrame.new(-0.0599994659, 1.69000387, -2.71000051, 0.95105654, 0, -0.309017003, 0, 1, 0, 0.309017003, 0, 0.95105654) },
		{ Frame = 51, Effect = "Hit1", Offset = CFrame.new(0.447206497, 1.69000387, -2.76330996, 0.994521916, 0, 0.104528464, 0, 1, 0, -0.104528464, 0, 0.994521916) },
		{ Frame = 88, Effect = "Barrage", Offset = CFrame.new(-0.0599994659, 0.750003576, -1.05499935, 1, 0, 0, 0, 1, 0, 0, 0, 1) },
		{ Frame = 156, Effect = "Hit2", Offset = CFrame.new(0.417938232, 1.69000387, -3.04177618, 0.994521916, 0, 0.104528464, 0, 1, 0, -0.104528464, 0, 0.994521916) },
		{ Frame = 210, Effect = "Hit3", Offset = CFrame.new(-0.79848671, 1.71601105, -2.2011137, 0.998621762, -0.00273905159, -0.0524072833, 0.00547059625, 0.998629451, 0.052049268, 0.0521929115, -0.0522642322, 0.997268736) },
	},
})

local expected = table.concat({
	"local Savage = {",
	"\tLifetime = 6,",
	"\tCueTolerance = 0.15,",
	"",
	"\tCues = {",
	'\t\t[0] =   { Effect = "Start",   Offset = CFrame.new(-0.0599994659, 1.69000387, -2.71000004, 1, 0, 0, 0, 1, 0, 0, 0, 1) },',
	'\t\t[27] =  { Effect = "Hit",     Offset = CFrame.new(-0.0599994659, 1.69000387, -2.71000051, 0.95105654, 0, -0.309017003, 0, 1, 0, 0.309017003, 0, 0.95105654) },',
	'\t\t[51] =  { Effect = "Hit1",    Offset = CFrame.new(0.447206497, 1.69000387, -2.76330996, 0.994521916, 0, 0.104528464, 0, 1, 0, -0.104528464, 0, 0.994521916) },',
	'\t\t[88] =  { Effect = "Barrage", Offset = CFrame.new(-0.0599994659, 0.750003576, -1.05499935, 1, 0, 0, 0, 1, 0, 0, 0, 1) },',
	'\t\t[156] = { Effect = "Hit2",    Offset = CFrame.new(0.417938232, 1.69000387, -3.04177618, 0.994521916, 0, 0.104528464, 0, 1, 0, -0.104528464, 0, 0.994521916) },',
	'\t\t[210] = { Effect = "Hit3",    Offset = CFrame.new(-0.79848671, 1.71601105, -2.2011137, 0.998621762, -0.00273905159, -0.0524072833, 0.00547059625, 0.998629451, 0.052049268, 0.0521929115, -0.0522642322, 0.997268736) },',
	"\t},",
	"}",
	"",
	"return Savage",
	"",
}, "\n")

check("matches the hand-written format exactly", savage == expected, "\n" .. savage)

check("formats notes as comments", string.find(Formatter.format({
	TableName = "T",
	Lifetime = 1.5,
	CueTolerance = 0.15,
	Cues = { { Frame = 3, Effect = "X", Offset = CFrame.new(), Notes = { "a", "b" } } },
}), "}, -- a; b", 1, true) ~= nil)
local timed = Formatter.format({
	TableName = "T",
	Lifetime = 6,
	CueTolerance = 0.15,
	Timestamps = true,
	FPS = 60,
	Cues = {
		{ Frame = 0, Effect = "Start", Offset = CFrame.new() },
		{ Frame = 27, Effect = "Hit", Offset = CFrame.new() },
		{ Frame = 88, Effect = "Barrage", Offset = CFrame.new() },
		{ Frame = 210, Effect = "Hit3", Offset = CFrame.new() },
	},
})
check("timestamp keys", string.match(timed, '\t\t%[0%] =%s+{ Effect = "Start",') ~= nil, "\n" .. timed)
check("timestamp keys drop trailing zeros", string.match(timed, '\t\t%[0%.45%] =%s+{ Effect = "Hit",') ~= nil, "\n" .. timed)
check(
	"timestamps keep 0.05 ms precision",
	string.find(timed, "[1.4667] =", 1, true) ~= nil and string.find(timed, "[3.5] =", 1, true) ~= nil,
	"\n" .. timed
)
check("timestamp of one frame", Formatter.seconds(1, 240) == "0.0042" and Formatter.seconds(1, 60) == "0.0167")
check("seconds at 30 fps", Formatter.seconds(45, 30) == "1.5")

check("empty cue list", string.find(Formatter.format({ TableName = "T", Lifetime = 2, CueTolerance = 0.1, Cues = {} }), "Cues = {},", 1, true) ~= nil)
check("negative zero prints as 0", Formatter.cframe(CFrame.new(-0, 0, 0)) == "CFrame.new(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)")
check("identifier from file name", Formatter.identifier("Ripper Test") == "RipperTest" and Formatter.identifier("2nd move") == "_2ndmove")
check("identifier fallback", Formatter.identifier("!!") == "VFX")

-- MoonHook -----------------------------------------------------------------------------------

local entries = SaveReader.findSaves()
local ripper, older = entries[1], entries[2]

local picked, how = MoonHook.detectOpenSave(entries)
check("no Moon: newest save", picked == ripper and how == "most recently saved", how)

_G.MoonGlobal = { ready = true, LayerSystem = { CurrentFile = { Save = older.Save } } }
picked, how = MoonHook.detectOpenSave(entries)
check("finds the save Moon holds", picked == older and how == "open in Moon Animator", how)

_G.MoonGlobal = {
	ready = true,
	FileList = { ripper.Save, older.Save },
	LayerSystem = { file = older.Save, history = { older.Save } },
}
picked = MoonHook.detectOpenSave(entries)
check("most referenced save wins", picked == older)

_G.MoonGlobal = { ready = true, EasingFunctions = { QuadOut = function(t)
	return t
end } }
check("exposes Moon easing", MoonHook.getEasingFunctions() ~= nil)
_G.MoonGlobal = nil

-- Export frame rate --------------------------------------------------------------------------

do
	local rate, reason = Exporter.chooseFrameRate({ 0, 27, 51 }, 60)
	check("keeps the file's fps when it's exact", rate == 60 and reason == nil, rate)

	rate, reason = Exporter.chooseFrameRate({ 0, 12.5 }, 60)
	check("doubles for half-frame events", rate == 120 and reason ~= nil, rate)

	rate = Exporter.chooseFrameRate({ 1 / 3, 10 }, 60)
	check("triples for third-frame events", rate == 180, rate)

	rate, reason = Exporter.chooseFrameRate({ 10, 10, 20 }, 60)
	check("raises to 240 to nudge same-frame events less", rate == 240 and string.find(reason, "same frame", 1, true) ~= nil, rate)

	rate = Exporter.chooseFrameRate({ 10, 10 }, 24)
	check("24 fps file with same-frame events goes to 240", rate == 240, rate)

	rate = Exporter.chooseFrameRate({}, 60)
	check("no events keeps the file's fps", rate == 60)

	rate, reason = Exporter.chooseFrameRate({ 0.123456 }, 60)
	check("caps the rate when nothing lands exactly", rate == 960 and string.find(reason, "rounded", 1, true) ~= nil, rate)

	-- The fixture has two events on frame 10, so Auto raises it to 240 fps.
	local auto = Exporter.collect(anim, { EffectName = "Event" })
	local autoFrames = {}
	for _, cue in auto.Cues do
		table.insert(autoFrames, cue.Frame)
	end
	check("auto export rate", auto.FrameRate == 240 and auto.FrameRateReason ~= nil, auto.FrameRate)
	check("auto frames are scaled and nudged by one 240th", table.concat(autoFrames, ",") == "20,40,41,120,164,200", table.concat(autoFrames, ","))

	local fixed = Exporter.collect(anim, { EffectName = "Event", FrameRate = 30 })
	check("a fixed rate is used as-is", fixed.FrameRate == 30 and fixed.FrameRateReason == nil)
	local rounded = false
	for _, cue in fixed.Cues do
		for _, note in cue.Notes do
			if string.find(note, "rounded to frame", 1, true) then
				rounded = true
			end
		end
	end
	check("a too-low fixed rate notes the rounding", rounded)
end

-- VFX objects on cues ------------------------------------------------------------------------

check("cue knows its VFX object", byFrame[10].Object == impact and byFrame[10].Asset == "ImpactAnti")
check("named event keeps its object", byFrame[30].Effect == "Hit" and byFrame[30].Asset == "ImpactAnti")
check("rig event spawns the part from its code", byFrame[5].Object == shine and byFrame[5].Asset == "Shine")
check("missing item has no object", byFrame[50].Object == nil and byFrame[50].Asset == nil)
check("target override still spawns the event's own object", overridden.Cues[2].Object == impact)

do
	local dustA = Instance.new("Part", { Name = "Dust" })
	local dustB = Instance.new("Part", { Name = "Dust" })
	local cues = { { Object = dustA }, { Object = dustB }, { Object = dustA }, {} }
	Exporter.assignAssets(cues)
	check("same-named objects get numbered", cues[1].Asset == "Dust" and cues[2].Asset == "Dust2", cues[2].Asset)
	check("an object keeps one asset name", cues[3].Asset == "Dust" and cues[4].Asset == nil)
end

local withObject = Formatter.format({
	TableName = "T",
	Lifetime = 1,
	CueTolerance = 0.15,
	Cues = {
		{ Frame = 0, Effect = "Hit", Asset = "ImpactAnti", Offset = CFrame.new() },
		{ Frame = 5, Effect = "Shine", Asset = "Shine", Offset = CFrame.new() },
	},
})
check("writes Object when it differs from Effect", string.find(withObject, '{ Effect = "Hit", Object = "ImpactAnti", Offset', 1, true) ~= nil, "\n" .. withObject)
check("omits Object when it matches", string.match(withObject, '{ Effect = "Shine",%s+Offset') ~= nil, "\n" .. withObject)
check("keyword table names are escaped", Formatter.identifier("end") == "_end")

-- Sequence -----------------------------------------------------------------------------------

local Sequence = __load("Sequence")

local function newTrack(props: { [string]: any }?)
	local track = Instance.new("AnimationTrack", { IsPlaying = true, TimePosition = 0, Looped = false, Length = 2 })
	for key, value in props or {} do
		track[key] = value
	end
	return track
end

local function recorder()
	local fired = {}
	local function make(frame)
		return function(f)
			table.insert(fired, f)
		end
	end
	return fired, make
end

local function at(track, frame: number)
	track.TimePosition = frame / 60
	step()
end

do
	local fired, make = recorder()
	local track = newTrack()
	local seq = Sequence.new({ [0] = make(0), [10] = make(10), [20] = make(20) }, 60, 0.15)
	seq:Play(track)
	at(track, 0)
	at(track, 12)
	check("fires steps in order as they come due", table.concat(fired, ",") == "0,10", table.concat(fired, ","))
	at(track, 25)
	check("stops after the last step", table.concat(fired, ",") == "0,10,20" and seq.Active == false)
end

do
	local fired, make = recorder()
	local track = newTrack()
	local seq = Sequence.new({ [10] = make(10) }, 60, 0)
	seq:Play(track)
	at(track, 3)
	at(track, 14) -- lands 4 frames after the step was due
	check("zero tolerance doesn't drop steps between heartbeats", fired[1] == 10, #fired)
end

do
	local fired, make = recorder()
	local track = newTrack({ TimePosition = 1 }) -- Play called a second into the track
	local seq = Sequence.new({ [0] = make(0), [55] = make(55), [70] = make(70) }, 60, 0.15)
	seq:Play(track)
	at(track, 60)
	at(track, 72)
	check("skips steps overdue by more than Tolerance at Play", table.concat(fired, ",") == "55,70", table.concat(fired, ","))
end

do
	local fired, make = recorder()
	local track = newTrack({ Looped = true, Length = 1 })
	local seq = Sequence.new({ [5] = make(5), [58] = make(58) }, 60, 0.15)
	seq:Play(track)
	at(track, 6)
	at(track, 57)
	at(track, 3) -- wrapped around
	at(track, 6)
	check("looped tracks replay steps and catch the one before the wrap", table.concat(fired, ",") == "5,58,5", table.concat(fired, ","))
	check("looped sequence keeps running", seq.Active)
	seq:Stop()
end

do
	local fired, make = recorder()
	local track = newTrack()
	local seq = Sequence.new({ [5] = make(5), [118] = make(118) }, 60, 0.15)
	seq:Play(track)
	at(track, 6)
	at(track, 117)
	track.IsPlaying = false
	at(track, 120) -- ended between heartbeats
	check("steps due as the track ends still fire", table.concat(fired, ",") == "5,118" and not seq.Active, table.concat(fired, ","))
end

do
	local fired, make = recorder()
	local track = newTrack()
	local seq = Sequence.new({ [5] = make(5), [30] = make(30) }, 60, 0.15)
	seq:Play(track)
	at(track, 6)
	at(track, 2) -- rewound
	at(track, 7)
	check("rewinding re-arms steps", table.concat(fired, ",") == "5,5", table.concat(fired, ","))
	seq:Stop()
	at(track, 40)
	check("Stop cancels the rest", table.concat(fired, ",") == "5,5")
end

do
	local fired, make = recorder()
	local track = newTrack()
	local seq = Sequence.new({ [0] = make(0) }, 60)
	seq:Play({ AnimationTrack = track })
	at(track, 1)
	check("accepts a table holding the track", fired[1] == 0)
end

do
	table.clear(warnings)
	local seq = Sequence.new({ [0] = function() end }, 60)
	local ok1 = pcall(seq.Play, seq, nil)
	local ok2 = pcall(seq.Play, seq, {})
	local ok3 = pcall(seq.Play, seq, Instance.new("Animation"))
	check("bad anchors warn instead of erroring", ok1 and ok2 and ok3 and #warnings == 3 and not seq.Active, #warnings)
end

check("rejects non-number keys", not pcall(Sequence.new, { Hit = function() end }, 60))
check("rejects non-function steps", not pcall(Sequence.new, { [0] = "Hit" }, 60))
check("rejects a zero frame rate", not pcall(Sequence.new, {}, 0))

-- Packager -----------------------------------------------------------------------------------

local Packager = __load("Packager")

do
	local fx = Instance.new("Model", { Name = "Fx", Parent = game:GetService("Workspace") })
	local partA = Instance.new("Part", { Name = "A", Anchored = false, CanCollide = true, Parent = fx })
	local partB = Instance.new("Part", { Name = "B", Parent = fx })
	Instance.new("WeldConstraint", { Name = "Inner", Part0 = partA, Part1 = partB, Parent = partA })
	Instance.new("Weld", { Name = "ToRig", Part0 = partA, Part1 = hrp, Parent = partA })

	local copy = Packager.prepare(fx)
	local copyA = copy:FindFirstChild("A")
	check("keeps joints inside the copy", copyA:FindFirstChild("Inner") ~= nil)
	check("drops joints to parts left behind", copyA:FindFirstChild("ToRig") == nil)
	check("copies are anchored and non-colliding", copyA.Anchored == true and copyA.CanCollide == false)

	local spark = Instance.new("Attachment", { Name = "Spark", CFrame = CFrame.new(1, 2, 3), Parent = impact })
	local wrapped = Packager.prepare(spark)
	check("attachments ride in a part", wrapped.ClassName == "Part" and wrapped.Name == "Spark")
	check("wrapped attachment sits at the part's centre", cfNear(wrapped:FindFirstChild("Spark").CFrame, CFrame.new()))

	shine.Archivable = false
	check("copies non-archivable objects", Packager.prepare(shine) ~= nil and shine.Archivable == false)
	shine.Archivable = true

	local folder, count = Packager.build({
		{ Object = impact, Asset = "ImpactAnti" },
		{ Object = impact, Asset = "ImpactAnti" },
		{ Object = shine, Asset = "Shine" },
		{},
	})
	check("one copy per VFX object", count == 2 and #folder:GetChildren() == 2 and folder:FindFirstChild("Shine") ~= nil)
	fx.Parent = nil
	spark.Parent = nil
end

-- Generated module, end to end ----------------------------------------------------------------

do
	local source = Formatter.format({
		TableName = "Ripper",
		Lifetime = 2,
		CueTolerance = 0.15,
		FPS = 60,
		Runtime = true,
		Cues = {
			{ Frame = 0, Effect = "Start", Asset = "ImpactAnti", Offset = CFrame.new(0, 0, -2) },
			{ Frame = 30, Effect = "Dust", Asset = "Dust", Offset = CFrame.new(1, 0, 0) },
			{ Frame = 45, Effect = "Gone", Offset = CFrame.new() },
		},
	})

	local chunk, compileError = loadstring(source)
	check("generated module compiles", chunk ~= nil, compileError)

	local vfx = Instance.new("Folder", { Name = "VFX" })
	local impactTemplate = Instance.new("Part", { Name = "ImpactAnti", Parent = vfx })
	local burst = Instance.new("ParticleEmitter", { Name = "Burst", Rate = 20, Parent = impactTemplate })
	burst:SetAttribute("EmitCount", 12)
	local dustTemplate = Instance.new("Part", { Name = "Dust", Parent = vfx })
	Instance.new("ParticleEmitter", { Name = "Puff", Rate = 7.6, Parent = dustTemplate })

	local sequenceRef = {}
	setfenv(chunk, setmetatable({
		script = { Sequence = sequenceRef, VFX = vfx },
		require = function(ref)
			assert(ref == sequenceRef, "unexpected require")
			return Sequence
		end,
		game = game,
		workspace = game:GetService("Workspace"),
		task = task,
		warn = warn,
		CFrame = CFrame,
	}, { __index = getfenv(0) }))
	local Ripper = chunk()

	local character = Instance.new("Model", { Name = "Character" })
	local rootCFrame = CFrame.new(5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	Instance.new("Part", { Name = "HumanoidRootPart", CFrame = rootCFrame, Parent = character })
	local track = newTrack()

	table.clear(calls)
	table.clear(warnings)
	local seq = Ripper.Play(character, track)
	at(track, 0)

	local spawned = game:GetService("Workspace"):FindFirstChild("ImpactAnti")
	check("spawns the cue's VFX object", spawned ~= nil and spawned ~= impactTemplate)
	check("places it at root * Offset", spawned and cfNear(spawned.CFrame, rootCFrame * CFrame.new(0, 0, -2)))
	check("emits using EmitCount", calls[1] and calls[1].Name == "Emit" and calls[1].Args[1] == 12)
	check("cleans up after Lifetime", calls[2] and calls[2].Name == "AddItem" and calls[2].Args[1] == 2)

	at(track, 31)
	local dustEmit = calls[3]
	check("falls back to Rate for the emit count", dustEmit and dustEmit.Name == "Emit" and dustEmit.Args[1] == 8)

	at(track, 46)
	check("warns about a cue with no VFX object", warnings[1] and string.find(warnings[1], 'No VFX named "Gone"', 1, true) ~= nil, warnings[1])
	check("sequence finishes", not seq.Active)

	local runtimeNamed = Formatter.format({ TableName = "Sequence", Lifetime = 1, CueTolerance = 0.1, Runtime = true, Cues = {} })
	check("table can't shadow the Sequence module", string.find(runtimeNamed, "local SequenceCues = {", 1, true) ~= nil)
	check("generated table carries its frame rate", string.find(source, "\tFrameRate = 60,", 1, true) ~= nil)
	check("generated module has no tips", string.find(source, "Tip:", 1, true) == nil)

	for _, child in game:GetService("Workspace"):GetChildren() do
		if child.Name == "ImpactAnti" or child.Name == "Dust" then
			child.Parent = nil
		end
	end
end

-- Moon button colour ---------------------------------------------------------------------------

do
	local bar = Instance.new("Frame", { Name = "MenuBar" })
	local options = Instance.new("TextButton", { Name = "Options", Text = "Options", TextColor3 = "white", TextTransparency = 0, Parent = bar })
	-- A copy taken while Moon's menus were disabled.
	local copy = Instance.new("TextButton", { Name = "MoonVFXExporterButton", Text = "Export VFX", TextColor3 = "grey", TextTransparency = 0, Parent = bar })

	local hook = setmetatable({ Watchers = {} }, MoonHook)
	hook:WatchLook(options, copy)
	check("copy takes Options' live colour", copy.TextColor3 == "white", copy.TextColor3)

	copy.TextColor3 = "grey" -- Moon greys out an item it doesn't know
	check("copy is re-coloured when greyed out", copy.TextColor3 == "white", copy.TextColor3)

	options.MouseEnter:Fire()
	options.TextColor3 = "orange" -- Moon's hover highlight on Options
	check("Options' hover colour isn't copied", copy.TextColor3 == "white", copy.TextColor3)
	options.TextColor3 = "white"
	options.MouseLeave:Fire()

	options.TextColor3 = "blue" -- theme change
	check("follows Options' colour", copy.TextColor3 == "blue", copy.TextColor3)

	hook:Unwatch()
	copy.TextColor3 = "grey"
	check("stops syncing once the button is removed", copy.TextColor3 == "grey")
end

-- Widget (smoke test: builds and drives the window against mocks) ------------------------------

do
	local Widget = __load("Widget")
	local dock = Instance.new("DockWidgetPluginGui")
	local ok, ui = pcall(Widget.new, dock)
	check("window builds", ok, ui)

	if ok then
		check("window is parented", dock:FindFirstChild("Root") ~= nil)

		local fps = ui.Selects.ExportFps
		fps:SetOptions({ { Value = "Auto", Label = "Auto" }, { Value = 60, Label = "60 fps" }, { Value = 240, Label = "240 fps" } })
		fps:Set(60)
		check("dropdown shows the chosen option", fps.Label.Text == "60 fps")

		local picked
		fps.OnChanged = function(value)
			picked = value
		end
		ui:OpenMenu(fps)
		local menu = ui.MenuLayer:FindFirstChild("Menu")
		check("dropdown opens a menu", ui.MenuLayer.Visible and menu ~= nil and #menu:GetChildren() >= 3)

		local option240
		for _, child in menu:GetChildren() do
			if child.Text == "240 fps" then
				option240 = child
			end
		end
		option240.MouseButton1Click:Fire()
		check("picking an option updates and closes", picked == 240 and fps.Label.Text == "240 fps" and not ui.MenuLayer.Visible)

		local chosen
		ui.OnSaveSelected = function(entry)
			chosen = entry
		end
		local saveA = { Name = "Ripper Test", Modified = 1700000000 }
		ui:SetSaves({ saveA, { Name = "Older" } }, saveA)
		local rows = {}
		for _, child in ui.SaveList:GetChildren() do
			if child.ClassName == "TextButton" then
				table.insert(rows, child)
			end
		end
		check("save list shows each save", #rows == 2)
		rows[2].MouseButton1Click:Fire()
		check("clicking a save selects it", chosen and chosen.Name == "Older")

		ui:SetSaves({}, nil)
		check("empty save list explains what to do", #ui.SaveList:GetChildren() >= 1)

		ui:SetStatus("Exported 6 cues.", "warn")
		check("status shows", ui.StatusBox.Visible and ui.Status.Text == "Exported 6 cues.")
		ui:SetStatus("", "info")
		check("empty status hides", not ui.StatusBox.Visible)

		ui:SetPreview("a\tb")
		check("preview expands tabs", ui.Preview.Text == "a    b")

		local repainted = pcall(function()
			ui:Repaint()
		end)
		check("theme change repaints", repainted)
		ui:Destroy()
	end
end

print(`{passed} passed, {failed} failed`)
if failed > 0 then
	error("tests failed", 0)
end
