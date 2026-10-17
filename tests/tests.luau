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

check("an emit call on a rig event spawns what it emits", byFrame[5].Object == shine and #byFrame[5].Notes == 0, byFrame[5].Notes[1])
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
	-- Shine sits inside the rig with no keys of its own, so Moon carries it along with the rig.
	check("a part inside a moving rig moves with it", cfNear(movingResult.Cues[1].Offset, hrpCFrame:ToObjectSpace(shine.CFrame)))

	-- A part outside the rig stays put while the rig moves away from it.
	local post = Instance.new("Part", { Name = "Post", CFrame = hrpCFrame * CFrame.new(0, 0, -4), Parent = game:GetService("Workspace") })
	local postSave = value("StringValue", "MovingPast", mockJson({
		Information = { Length = 120, FPS = 60, Modified = 1640000000 },
		Items = { { Path = path("Ripper Test") }, { Path = { InstanceNames = { "Game", "Workspace", "Post" }, InstanceTypes = { "DataModel", "Workspace", "Part" }, ItemType = "BasePart" } } },
	}), saves)
	local postRigTrack = folder("CFrame", folder("1", postSave))
	keyframe(postRigTrack, 0, { hrpCFrame })
	keyframe(postRigTrack, 60, { moved })
	marker(folder("MarkerTrack", folder("2", postSave)), 60, "Pass")
	local postResult = Exporter.collect(SaveReader.load(postSave), { EffectName = "Event" })
	check("a part outside the rig stays put", cfNear(postResult.Cues[1].Offset, moved:ToObjectSpace(post.CFrame)))
	post.Parent = nil
	postSave.Parent = nil
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

-- Rig posing: the Iron Clash case --------------------------------------------------------------
-- The rig lunges 40 studs early on. Its effect parts sit inside the rig with no keys, so Moon
-- carries them along. The exporter used to read their live position, which depends on where
-- Moon's playhead was left, and put every effect 40 studs behind the character.

local function ironClash(parkedAfterLunge: boolean)
	local workspace = game:GetService("Workspace")
	local start = CFrame.new(0, 3, 0)
	local lunge = start * CFrame.new(0, 0, -40)
	local slashLocal = CFrame.new(0, 0, -3) * CFrame.Angles(0, 0.4, 0)
	local parked = if parkedAfterLunge then lunge else start

	local rig = Instance.new("Model", { Name = "Ripper", Parent = workspace })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = parked, Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
	Instance.new("Part", { Name = "Slash", CFrame = parked * slashLocal, Parent = rig })

	local save = value("StringValue", "Iron Clash", mockJson({
		Information = { Length = 300, FPS = 60, Modified = 1 },
		Items = {
			{ Path = { InstanceNames = { "game", "Workspace", "Ripper" }, InstanceTypes = { "DataModel", "Workspace", "Model" }, ItemType = "Rig" } },
			{ Path = { InstanceNames = { "game", "Workspace", "Ripper", "Slash" }, InstanceTypes = { "DataModel", "Workspace", "Model", "Part" }, ItemType = "BasePart" } },
		},
	}), saves)
	local rigTrack = folder("CFrame", folder("1", save))
	keyframe(rigTrack, 0, { start })
	keyframe(rigTrack, 4, { lunge })
	local events = folder("MarkerTrack", folder("2", save))
	marker(events, 10, "")
	marker(events, 100, "Second")

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	rig.Parent = nil
	save.Parent = nil
	return result, slashLocal
end

for _, parkedAfterLunge in { false, true } do
	local result, slashLocal = ironClash(parkedAfterLunge)
	local where = if parkedAfterLunge then "after the lunge" else "at frame 0"
	check(`Iron Clash offsets are right with the playhead {where}`,
		cfNear(result.Cues[1].Offset, slashLocal) and cfNear(result.Cues[2].Offset, slashLocal),
		tostring(result.Cues[1].Offset))
	check(`Iron Clash cues have no Parent ({where})`, result.Cues[1].Parent == nil)
end

-- Rig posing: joints and welds ------------------------------------------------------------------

local RigPose = __load("RigPose")

do
	local workspace = game:GetService("Workspace")
	local rig = Instance.new("Model", { Name = "R6", Parent = workspace })
	local rootCF = CFrame.new(10, 3, 0) * CFrame.Angles(0, math.pi / 2, 0)
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = rootCF, Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
	local torso = Instance.new("Part", { Name = "Torso", Parent = rig })
	local arm = Instance.new("Part", { Name = "Right Arm", Parent = rig })
	local sword = Instance.new("Part", { Name = "Sword", Anchored = false, Parent = rig })

	local rootC0 = CFrame.Angles(-math.pi / 2, 0, math.pi)
	Instance.new("Motor6D", { Name = "RootJoint", Part0 = root, Part1 = torso, C0 = rootC0, C1 = rootC0, Parent = root })
	local shoulderC0 = CFrame.new(1, 0.5, 0) * CFrame.Angles(0, math.pi / 2, 0)
	local restC1 = CFrame.new(-0.5, 0.5, 0) * CFrame.Angles(0, math.pi / 2, 0)
	Instance.new("Motor6D", { Name = "Right Shoulder", Part0 = torso, Part1 = arm, C0 = shoulderC0, C1 = restC1, Parent = torso })

	-- The live scene, posed at rest (where the playhead happened to be).
	torso.CFrame = rootCF * rootC0 * rootC0:Inverse()
	arm.CFrame = torso.CFrame * shoulderC0 * restC1:Inverse()
	local swordLocal = CFrame.new(0, -1, -2)
	sword.CFrame = arm.CFrame * swordLocal
	Instance.new("WeldConstraint", { Part0 = arm, Part1 = sword, Parent = sword })

	local raised = CFrame.new(-0.5, 0.5, 0) * CFrame.Angles(math.pi / 2, math.pi / 2, 0)
	local joints = {
		{ Hier = { "Torso", "Right Arm" }, Track = { { Time = 0, Value = restC1 }, { Time = 10, Value = raised } } },
	}

	local pose = RigPose.new(rig, root, nil, joints)
	local expectedArm = rootCF * rootC0 * rootC0:Inverse() * shoulderC0 * raised:Inverse()
	check("poses a limb from its joint keys (C1)", cfNear(pose:CFrameAt(arm, 10), expectedArm))
	check("a welded part follows its limb", cfNear(pose:CFrameAt(sword, 10), expectedArm * swordLocal))
	check("knows what a welded part hangs off", pose:AttachedTo(sword) == arm)
	check("an unkeyed joint stays at rest", cfNear(pose:CFrameAt(torso, 10), torso.CFrame))

	-- Through the exporter: an event on the sword gets Parent = "Right Arm".
	local save = value("StringValue", "Swing", mockJson({
		Information = { Length = 60, FPS = 60, Modified = 1 },
		Items = {
			{ Path = { InstanceNames = { "game", "Workspace", "R6" }, InstanceTypes = { "DataModel", "Workspace", "Model" }, ItemType = "Rig" } },
			{ Path = { InstanceNames = { "game", "Workspace", "R6", "Sword" }, InstanceTypes = { "DataModel", "Workspace", "Model", "Part" }, ItemType = "BasePart" } },
		},
	}), saves)
	local jointFolder = folder("_joint", folder("Rig", folder("1", save)))
	value("StringValue", "_hier", "Torso.Right Arm", jointFolder)
	value("CFrameValue", "default", restC1, jointFolder)
	local keyframes = folder("_keyframes", jointFolder)
	keyframe(keyframes, 0, { restC1 })
	keyframe(keyframes, 10, { raised })

	local swordEvents = folder("MarkerTrack", folder("2", save))
	marker(swordEvents, 10, "Shine")

	-- A second event that names its own Parent in Moon's Events tab.
	local named = folder("20", swordEvents)
	value("StringValue", "codeBegin", "", named)
	value("IntValue", "width", 0, named)
	local kf = folder("KFMarkers", named)
	local entry = value("StringValue", "1", "Parent", kf)
	value("StringValue", "Val", "Torso", entry)

	-- An event whose Parent is an attachment on the arm.
	local grip = Instance.new("Attachment", { Name = "RightGripAttachment", CFrame = CFrame.new(0, -1, 0), Parent = arm })
	local gripped = folder("40", swordEvents)
	value("IntValue", "width", 0, gripped)
	local gripEntry = value("StringValue", "1", "Parent", folder("KFMarkers", gripped))
	value("StringValue", "Val", "RightGripAttachment", gripEntry)

	local bad = folder("30", swordEvents)
	value("IntValue", "width", 0, bad)
	local badEntry = value("StringValue", "1", "Parent", folder("KFMarkers", bad))
	value("StringValue", "Val", "Left Wing", badEntry)

	local loaded = SaveReader.load(save)
	check("reads rig joints", #loaded.Items[1].Joints == 1 and loaded.Items[1].Joints[1].Hier[2] == "Right Arm")
	check("reads event keys", loaded.Items[2].Markers[2].Keys.Parent == "Torso")

	local result = Exporter.collect(loaded, { EffectName = "Event", FrameRate = 60 })
	local shineCue, namedCue, badCue = result.Cues[1], result.Cues[2], result.Cues[3]
	check("Parent comes from what the object is welded to", shineCue.Parent == "Right Arm", shineCue.Parent)
	check("Offset is measured from the Parent", cfNear(shineCue.Offset, swordLocal), tostring(shineCue.Offset))
	check("an event's Parent key wins", namedCue.Parent == "Torso", namedCue.Parent)
	-- By frame 20 the arm is raised, and the sword with it.
	check("explicit Parent offset is from that part", cfNear(namedCue.Offset, torso.CFrame:ToObjectSpace(expectedArm * swordLocal)))
	check("an unknown Parent falls back to the root with a note", badCue.Parent == nil and badCue.Notes[1] ~= nil and string.find(badCue.Notes[1], "Left Wing", 1, true) ~= nil)

	local gripCue = result.Cues[4]
	check("Parent can name an attachment", gripCue.Parent == "RightGripAttachment", gripCue.Parent)
	check("and the offset is from the attachment", cfNear(gripCue.Offset, grip.CFrame:Inverse() * swordLocal), tostring(gripCue.Offset))

	local withParent = Formatter.format({ TableName = "T", Lifetime = 1, CueTolerance = 0.1, Cues = { shineCue } })
	check("writes the Parent field", string.find(withParent, 'Parent = "Right Arm",', 1, true) ~= nil, "\n" .. withParent)

	rig.Parent = nil
	save.Parent = nil
end

-- Two rigs, loose parts and nested attachments (shaped like the AeroFinisher save) -------------

do
	local workspace = game:GetService("Workspace")
	local function makeRig(name: string, at: CFrame)
		local model = Instance.new("Model", { Name = name, Parent = workspace })
		local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = at, Parent = model })
		model.PrimaryPart = root
		Instance.new("Humanoid", { Name = "Humanoid", Parent = model })
		return model, root
	end

	local mainRig, mainRoot = makeRig("Main", CFrame.new(0, 3, 0))
	local torso = Instance.new("Part", { Name = "Torso", CFrame = CFrame.new(0, 3, 0), Parent = mainRig })
	Instance.new("Motor6D", { Part0 = mainRoot, Part1 = torso, C0 = CFrame.new(), C1 = CFrame.new(), Parent = mainRoot })
	local victimRig, victimRoot = makeRig("Victim", CFrame.new(0, 3, -6))
	local victimFx = Instance.new("Part", { Name = "VicFx", CFrame = victimRoot.CFrame * CFrame.new(0, 1, 0), Parent = victimRig })
	local loose = Instance.new("Part", { Name = "Loose", Anchored = false, CFrame = CFrame.new(5, 0, 0), Parent = workspace })
	local holder = Instance.new("Part", { Name = "Holder", CFrame = CFrame.new(0, 0, -2), Parent = workspace })
	local outer = Instance.new("Attachment", { Name = "Outer", CFrame = CFrame.new(0, 1, 0), Parent = holder })
	Instance.new("Attachment", { Name = "Inner", CFrame = CFrame.new(0, 0, -1), Parent = outer })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game", "Workspace" }, { "DataModel", "Workspace" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "TwoRigs", mockJson({
		Information = { Length = 60, FPS = 60, Modified = 1 },
		Items = {
			p({ "Main" }, { "Model" }, "Rig"),
			p({ "Victim" }, { "Model" }, "Rig"),
			p({ "Victim", "VicFx" }, { "Model", "Part" }, "BasePart"),
			p({ "Loose" }, { "Part" }, "BasePart"),
			p({ "Holder", "Outer", "Inner" }, { "Part", "Attachment", "Attachment" }, "Attachment"),
			p({ "Main", "Torso" }, { "Model", "Part" }, "BasePart"),
		},
	}), saves)

	-- The main rig's torso is animated through its joint.
	local joint = folder("_joint", folder("Rig", folder("1", save)))
	value("StringValue", "_hier", "Torso", joint)
	keyframe(folder("_keyframes", joint), 0, { CFrame.new() })

	for index = 3, 6 do
		marker(folder("MarkerTrack", folder(tostring(index), save)), index * 10, "")
	end

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byName = {}
	for _, cue in result.Cues do
		byName[cue.Effect] = cue
	end

	local vic = byName.VicFx
	check("another rig's effect is for that rig", vic.Rig == "Victim" and vic.Parent == nil and #vic.Notes == 0, vic.Rig)
	check("and measured from that rig", cfNear(vic.Offset, victimRoot.CFrame:ToObjectSpace(victimFx.CFrame)))

	check("a loose unanchored part needs no note", #byName.Loose.Notes == 0, byName.Loose.Notes[1])

	local inner = byName.Inner
	check("a nested attachment is placed from the outer one", cfNear(inner.Offset, mainRoot.CFrame:ToObjectSpace(holder.CFrame * outer.CFrame * CFrame.new(0, 0, -1))), tostring(inner.Offset))
	check("and notes it", inner.Notes[1] ~= nil and string.find(inner.Notes[1], "inside another attachment", 1, true) ~= nil)

	local deep = Instance.new("Attachment", { Name = "Deep", Parent = Instance.new("Attachment", { Name = "Shell", Parent = torso }) })
	check("a nested attachment hangs off the part it's on", RigPose.new(mainRig, mainRoot):AttachedTo(deep) == torso)

	local torsoCue = byName.Torso
	check("an effect on an animated body part is parented to that part", torsoCue.Parent == "Torso" and cfNear(torsoCue.Offset, CFrame.new()), torsoCue.Parent)

	mainRig.Parent, victimRig.Parent, loose.Parent, holder.Parent, save.Parent = nil, nil, nil, nil, nil
end

-- Cue Functions kept across exports -------------------------------------------------------------

local Carryover = __load("Carryover")

do
	local old = table.concat({
		"local Thing = {",
		"\tLifetime = 1,",
		"\tCues = {",
		'\t\t[0] =  { Effect = "Start", Offset = CFrame.new(), Function = function(effect, character)',
		"\t\t\tlocal a, b = 1, { 2, 3 } -- a comment with end and }",
		'\t\t\tif a then print("}, end") end',
		"\t\t\tlocal c = if b then 1 else 2",
		"\t\t\tfor i = 1, 2 do a += i end",
		"\t\t\trepeat a -= 1 until a < 0",
		"\t\tend },",
		'\t\t[27] = { Effect = "Hit", Offset = CFrame.new(1, 2, 3), Function = Helpers.shake, },',
		'\t\t[51] = { Effect = "Gone", Offset = CFrame.new() , Function = function() return [[ x ]] end },',
		'\t\t[60] = { Effect = "Plain", Offset = CFrame.new() },',
		"\t},",
		"}",
	}, "\n")

	local found = Carryover.extract(old)
	check("finds each cue Function", #found == 3, #found)
	check("keeps a multi-line function whole", string.sub(found[1].Text, 1, 8) == "function" and string.sub(found[1].Text, -3) == "end", found[1].Text)
	check("keeps a reference to a function", found[2].Text == "Helpers.shake", found[2].Text)
	check("reads keys and effects", found[1].Key == "0" and found[2].Effect == '"Hit"')

	-- The next export: Start moved to frame 2, Hit stayed at 27, Gone was deleted in Moon.
	local cues = {
		{ Frame = 2, Effect = "Start", Offset = CFrame.new() },
		{ Frame = 27, Effect = "Hit", Offset = CFrame.new() },
		{ Frame = 60, Effect = "Plain", Offset = CFrame.new() },
	}
	local orphans = Carryover.apply(found, cues, function(cue)
		return tostring(cue.Frame)
	end)
	check("matched by key", cues[2].Function == "Helpers.shake")
	check("matched by effect name when its frame moved", cues[1].Function == Carryover.upgrade(found[1].Text))
	check("a Function written before self was passed gets it", string.sub(cues[1].Function, 1, 33) == "function(self, effect, character)", string.sub(cues[1].Function, 1, 40))
	check("one that has it already, or isn't written out, is left alone", Carryover.upgrade("function(self, effect) end") == "function(self, effect) end" and Carryover.upgrade("Helpers.shake") == "Helpers.shake" and Carryover.upgrade("function(effectName) end") == "function(effectName) end")
	check("a Function whose cue is gone is set aside", #orphans == 1 and orphans[1].Key == "51" and cues[3].Function == nil)

	local source = Formatter.format({ TableName = "Thing", Lifetime = 1, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = cues, Orphans = orphans })
	local chunk, compileError = loadstring(source)
	check("an export with Functions compiles", chunk ~= nil, compileError)
	check("set-aside Functions are in a comment", string.find(source, Carryover.ORPHAN_MARKER, 1, true) ~= nil and string.find(source, "--[=[", 1, true) ~= nil)
	check("Functions survive the export after that too", #Carryover.extract(source) == 3, #Carryover.extract(source))
	check("an export with no Functions finds none", #Carryover.extract(Formatter.format({ TableName = "T", Lifetime = 1, CueTolerance = 0.1, Runtime = true, Cues = {} })) == 0)
end

-- Function, attachment Parents and attachment VFX at runtime ------------------------------------

-- The exported module is only data; loading it needs nothing but what its values are made of.
local function loadData(source: string, extra: { [string]: any }?): any
	local chunk, compileError = loadstring(source)
	assert(chunk, compileError)
	local env = { CFrame = CFrame, Instance = Instance }
	for key, value in extra or {} do
		env[key] = value
	end
	setfenv(chunk, setmetatable(env, { __index = getfenv(0) }))
	return chunk()
end

do
	local Sequence = __load("Sequence")
	local vfx = Instance.new("Folder", { Name = "VFX" })
	Instance.new("Part", { Name = "Dust", Parent = vfx })
	Instance.new("Attachment", { Name = "Spark", Parent = vfx })

	local source = Formatter.format({
		TableName = "Fx",
		Lifetime = 1,
		CueTolerance = 0.1,
		Runtime = true,
		FPS = 60,
		Cues = {
			{ Frame = 0, Effect = "Dust", Offset = CFrame.new(0, 0, -1), Function = "function(self, effect, character, cue) record(self, effect, character, cue) end" },
			{ Frame = 1, Effect = "CodeOnly", Code = "print(1)", Function = "function(self, effect, character, cue) record(self, effect, character, cue) end" },
			{ Frame = 2, Effect = "Grip", Asset = "Dust", Parent = "RightGripAttachment", Offset = CFrame.new(0, 0, -2) },
			{ Frame = 3, Effect = "Spark", Offset = CFrame.new(0, 2, 0) },
		},
	})
	check("the exported module is only data", string.find(source, "function Fx.", 1, true) == nil and string.find(source, "require(", 1, true) == nil and string.find(source, "return Fx", 1, true) ~= nil)
	check("a cue that only runs code has no Offset", string.find(source, '{ Effect = "CodeOnly", Function', 1, true) ~= nil)

	local recorded = {}
	local Fx = loadData(source, {
		record = function(...)
			table.insert(recorded, { ... })
		end,
	})

	local character = Instance.new("Model", { Name = "Character" })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = CFrame.new(0, 3, 0), Parent = character })
	local arm = Instance.new("Part", { Name = "Right Arm", CFrame = CFrame.new(1.5, 3, 0), Parent = character })
	local grip = Instance.new("Attachment", { Name = "RightGripAttachment", CFrame = CFrame.new(0, -1, 0), Parent = arm })
	local sequence = Sequence.new(Fx, character)

	table.clear(warnings)
	local dust = sequence:Spawn(Fx.Cues[0], nil, vfx)
	check("the VFX is a copy of the one given", dust and dust.Parent == game:GetService("Workspace") and vfx:FindFirstChild("Dust") ~= dust)
	check("Function runs after the VFX spawns", recorded[1] and recorded[1][2] == dust and recorded[1][3] == character and recorded[1][4] == Fx.Cues[0])
	check("with the sequence first, as self", recorded[1] and recorded[1][1] == sequence)

	local none = sequence:Spawn(Fx.Cues[1], nil, vfx)
	check("a cue with no Offset runs its Function with no effect and no warning", none == nil and recorded[2] and recorded[2][1] == sequence and recorded[2][2] == nil and #warnings == 0, warnings[1])

	local gripped = sequence:Spawn(Fx.Cues[2], nil, vfx)
	check("Parent can be an attachment", gripped and cfNear(gripped.CFrame, arm.CFrame * grip.CFrame * CFrame.new(0, 0, -2)))
	local weld = gripped and gripped:FindFirstChild("WeldConstraint")
	check("and follows the part it's on", weld ~= nil and weld.Part0 == arm)

	local spark = sequence:Spawn(Fx.Cues[3], nil, { Spark = vfx:FindFirstChild("Spark") })
	check("an attachment VFX goes on a part", spark and spark.Parent == root and cfNear(spark.WorldCFrame, root.CFrame * CFrame.new(0, 2, 0)))
	check("the VFX can be a table of objects by name", spark ~= nil)

	sequence:Stop()
	check("Stop removes everything the sequence spawned", dust.Parent == nil and gripped.Parent == nil and spark.Parent == nil)
end

-- VFX Forge: shared.vfx.emit(...) in event code ---------------------------------------------

do
	local workspace = game:GetService("Workspace")
	local rig = Instance.new("Model", { Name = "Slinky", Parent = workspace })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = CFrame.new(0, 3, 0), Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
	local glow = Instance.new("Highlight", { Name = "Highlight", Parent = rig })

	-- VFX the events emit: two bubbles in a folder, and one stored in ReplicatedStorage.
	local fx = Instance.new("Model", { Name = "Fx", Parent = workspace })
	local holder = Instance.new("Part", { Name = "Holder", CFrame = CFrame.new(0, 3, -4), Parent = fx })
	local bubbleA = Instance.new("Attachment", { Name = "Bubble 61", CFrame = CFrame.new(0, 1, 0), Parent = holder })
	local bubbleB = Instance.new("Attachment", { Name = "Bubble (62)", CFrame = CFrame.new(0, 2, 0), Parent = holder })
	local replicated = Instance.new("ReplicatedStorage", { Name = "ReplicatedStorage", Parent = game })
	local stored = Instance.new("Part", { Name = "Big Hit", CFrame = CFrame.new(0, 3, -10), Parent = Instance.new("Folder", { Name = "Effects", Parent = replicated }) })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "Forge Move", mockJson({
		Information = { Length = 120, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Slinky" }, { "Workspace", "Model" }, "Rig"),
			-- Events sit on the Highlight, as in the Plummet Rework save; the code says what to emit.
			p({ "Workspace", "Slinky", "Highlight" }, { "Workspace", "Model", "Highlight" }, "Highlight"),
		},
	}), saves)

	local events = folder("MarkerTrack", folder("2", save))
	marker(events, 10, "", 'shared.vfx.emit(workspace.Fx.Holder["Bubble 61"], workspace.Fx.Holder["Bubble (62)"])')
	marker(events, 20, "Slam", 'local A = game:GetService("ReplicatedStorage")\n\nshared.vfx.emit(A.Effects["Big Hit"])')
	marker(events, 30, "", 'print("works")\nlocal beams = workspace:WaitForChild("Runbeams")')

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byName = {}
	for _, cue in result.Cues do
		byName[cue.Effect] = cue
	end

	check("each object an emit call names is its own cue", byName["Bubble 61"] and byName["Bubble (62)"] and byName["Bubble 61"].Object == bubbleA and byName["Bubble (62)"].Object == bubbleB)
	check("in the order the call names them", result.Cues[1].Effect == "Bubble 61" and result.Cues[2].Effect == "Bubble (62)", result.Cues[1].Effect)
	check("each has its own offset", byName["Bubble 61"] and cfNear(byName["Bubble 61"].Offset, root.CFrame:ToObjectSpace(holder.CFrame * bubbleA.CFrame)))
	check("VFX Forge's service aliases are followed", byName.Slam and byName.Slam.Object == stored, byName.Slam and byName.Slam.Effect)
	check("one emitted object keeps the event's Name", byName.Slam ~= nil)
	local custom = byName.Highlight
	check("other code is kept for the cue's Function", custom and custom.Object == glow and custom.Code and string.find(custom.Code, "Runbeams", 1, true) ~= nil and #custom.Notes == 0)
	check("what it looks for that the place doesn't have keeps it from running as is", custom and custom.Adapted == nil and custom.CodeMissing and custom.CodeMissing[1] == "Runbeams")
	check("no cue is made for the carrier Highlight itself", #result.Cues == 4, #result.Cues)

	check("code paths come back in order", (function()
		local found = Exporter.findInstancesInCode('x(workspace.Fx.Holder["Bubble (62)"], workspace.Fx.Holder["Bubble 61"])')
		return found[1] == bubbleB and found[2] == bubbleA
	end)())

	local function emitted(code: string): string
		local names = {}
		for _, inst in Exporter.findEmitTargets(code) do
			table.insert(names, inst.Name)
		end
		return table.concat(names, ",")
	end
	check("a local holding an effect is followed", emitted('local VFX = workspace.Fx.Holder\nshared.vfx.emit(VFX["Bubble 61"])') == "Bubble 61")
	check("Part_Icles' AbsoluteEmit counts as emitting", emitted('local Part_Icles = require(game.ReplicatedStorage:WaitForChild("Part_Icles"))\nPart_Icles:Activate()\n\nlocal VFX = workspace.Fx.Holder\nPart_Icles:AbsoluteEmit(VFX)') == "Holder")
	check("locals build on each other", emitted('local fx = workspace:WaitForChild("Fx")\nlocal h = fx.Holder\nshared.vfx.emit(h["Bubble (62)"])') == "Bubble (62)")
	check("a path that isn't in the place emits nothing, not the part of it that is", emitted("shared.vfx.emit(workspace.Fx.Holder.Missing)") == "")
	check("paths outside the call aren't emitted", emitted('local h = workspace.Fx.Holder\nprint(workspace.Fx)\nshared.vfx.emit(h["Bubble 61"])') == "Bubble 61")
	check("a local set to something else isn't a path", emitted('local VFX = workspace.Fx.Holder:Clone()\nshared.vfx.emit(VFX)') == "")

	rig.Parent, fx.Parent, replicated.Parent, save.Parent = nil, nil, nil, nil
end

-- Keyframed effects (shaped like Plummet Rework) -----------------------------------------------

do
	local workspace = game:GetService("Workspace")
	local function makeRig(name: string, at: CFrame)
		local model = Instance.new("Model", { Name = name, Parent = workspace })
		local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = at, Parent = model })
		model.PrimaryPart = root
		Instance.new("Humanoid", { Name = "Humanoid", Parent = model })
		return model, root
	end

	local slinky, root = makeRig("Slinky", CFrame.new(0, 3, 0))
	local arm = Instance.new("Part", { Name = "Right Arm", CFrame = CFrame.new(1.5, 3, 0), Parent = slinky })
	Instance.new("Motor6D", { Part0 = root, Part1 = arm, C0 = CFrame.new(1.5, 0, 0), C1 = CFrame.new(), Parent = root })
	Instance.new("Highlight", { Name = "Highlight", Parent = slinky })
	local a1 = Instance.new("Attachment", { Name = "A1", CFrame = CFrame.new(0, -1, 0), Parent = arm })
	local armBulb = Instance.new("PointLight", { Name = "PointLight", Parent = a1 })
	local fire = Instance.new("ParticleEmitter", { Name = "Fire", Parent = a1 })
	Instance.new("Highlight", { Name = "Rigg", Parent = arm })

	local victim, victimRoot = makeRig("Victim", CFrame.new(0, 3, -6))
	local head = Instance.new("Part", { Name = "Head", CFrame = CFrame.new(0, 4.5, -6), Parent = victim })
	Instance.new("Motor6D", { Part0 = victimRoot, Part1 = head, C0 = CFrame.new(0, 1.5, 0), C1 = CFrame.new(), Parent = victimRoot })
	Instance.new("Highlight", { Name = "Highlight", Parent = head })

	local p1 = Instance.new("Part", { Name = "P1", CFrame = CFrame.new(4, 0, -2), Parent = workspace })
	local i1 = Instance.new("Attachment", { Name = "i1", CFrame = CFrame.new(0, 1, 0), Parent = p1 })
	local p1Bulb = Instance.new("PointLight", { Name = "PointLight", Parent = i1 })
	Instance.new("ParticleEmitter", { Name = "Sparks", Parent = i1 })
	local box = Instance.new("Part", { Name = "Box", CFrame = CFrame.new(2, 2, -8), Parent = workspace })
	for _, name in { "E1", "E2", "E3" } do
		Instance.new("ParticleEmitter", { Name = name, Parent = box })
	end
	local b0 = Instance.new("Attachment", { Name = "B0", CFrame = CFrame.new(0, 1, 0), Parent = box })
	local b1 = Instance.new("Attachment", { Name = "B1", CFrame = CFrame.new(0, -1, 0), Parent = box })
	local slash = Instance.new("Beam", { Name = "Slash", Attachment0 = b0, Attachment1 = b1, Parent = b0 })
	local lamp = Instance.new("Part", { Name = "Lamp", CFrame = CFrame.new(-4, 2, 0), Parent = workspace })
	Instance.new("PointLight", { Name = "Glow", Parent = lamp })
	local trail = Instance.new("Part", { Name = "BezTrail", CFrame = CFrame.new(0, 3, -1), Parent = workspace })
	local lighting = Instance.new("Lighting", { Name = "Lighting", ExposureCompensation = 0, Parent = game })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "Plummet", mockJson({
		Information = { Length = 600, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Slinky" }, { "Workspace", "Model" }, "Rig"),
			p({ "Workspace", "Victim" }, { "Workspace", "Model" }, "Rig"),
			p({ "Workspace", "Slinky", "Highlight" }, { "Workspace", "Model", "Highlight" }, "Highlight"),
			p({ "Workspace", "Slinky", "Right Arm", "A1", "PointLight" }, { "Workspace", "Model", "Part", "Attachment", "PointLight" }, "PointLight"),
			p({ "Workspace", "Slinky", "Right Arm", "Rigg" }, { "Workspace", "Model", "Part", "Highlight" }, "Highlight"),
			p({ "Workspace", "Victim", "Head", "Highlight" }, { "Workspace", "Model", "Part", "Highlight" }, "Highlight"),
			p({ "Workspace", "P1", "i1", "PointLight" }, { "Workspace", "Part", "Attachment", "PointLight" }, "PointLight"),
			p({ "Workspace", "Lamp", "Glow" }, { "Workspace", "Part", "PointLight" }, "PointLight"),
			p({ "Lighting" }, { "Lighting" }, "Lighting"),
			p({ "Workspace", "BezTrail" }, { "Workspace", "Part" }, "BasePart"),
			-- VFX Forge and Part_Icles events on Moon's Subtitles, as in the Plummet Rework save.
			p({ "CoreGui", "MoonAnimatorEffects", "Subtitles" }, { "CoreGui", "ScreenGui", "TextLabel" }, "TextLabel"),
		},
	}), saves)

	local function numberTrack(item: string, property: string, keys: { { number } })
		local track = folder(property, save:FindFirstChild(item) or folder(item, save))
		for _, key in keys do
			value("NumberValue", "0", key[2], folder("Values", folder(tostring(key[1]), track)))
		end
		return track
	end

	local subtitles = folder("MarkerTrack", folder("11", save))
	marker(subtitles, 150, "", "shared.vfx.emit(workspace.P1)")
	marker(subtitles, 160, "", 'local Part_Icles = require(game.ReplicatedStorage:WaitForChild("Part_Icles"))\nPart_Icles:Activate()\nlocal VFX = workspace.Lamp\nPart_Icles:AbsoluteEmit(VFX)')
	marker(subtitles, 170, "", 'local character = game.Workspace:FindFirstChild("Slinky")\nif character then\n\tlocal highlight = Instance.new("Highlight")\n\thighlight.Parent = character\nend')
	marker(subtitles, 180, "")
	marker(subtitles, 190, "", 'shared.vfx.emit(workspace.Slinky["Right Arm"].A1.Fire)')
	marker(subtitles, 195, "", 'shared.vfx.emit(workspace.Victim.Head.Missing)')
	marker(subtitles, 197, "", "shared.vfx.emit(workspace.Box.E1, workspace.Box.E2)")
	marker(subtitles, 199, "", "shared.vfx.emit(workspace.Box.B0)")

	numberTrack("3", "FillTransparency", { { 100, 1 }, { 110, 0 }, { 130, 1 } })
	marker(folder("MarkerTrack", save:FindFirstChild("3")), 105, "", 'print("not an emit")')
	numberTrack("4", "Brightness", { { 200, 0 }, { 210, 5 }, { 230, 0 } })
	numberTrack("5", "FillTransparency", { { 300, 1 }, { 305, 0.5 } })
	numberTrack("6", "FillTransparency", { { 320, 1 }, { 330, 0 } })
	numberTrack("7", "Brightness", { { 400, 0 }, { 420, 8 } })
	numberTrack("8", "Brightness", { { 410, 0 }, { 415, 3 } })
	numberTrack("9", "ExposureCompensation", { { 500, 0 }, { 520, 2 }, { 540, 0 } })
	local trailTrack = folder("CFrame", folder("10", save))
	keyframe(trailTrack, 50, { CFrame.new(0, 3, -1) })
	keyframe(trailTrack, 60, { CFrame.new(0, 3, -1) })
	keyframe(trailTrack, 80, { CFrame.new(0, 3, -21) })

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byFrame = {}
	for _, cue in result.Cues do
		byFrame[cue.Frame] = cue
	end

	local hl = byFrame[100]
	check("a keyed Highlight on the character is a cue at its first key", hl and hl.Object ~= nil and hl.Object.Name == "Highlight" and hl.Parent == nil and hl.Rig == nil and hl.Animation and hl.Animation.Keys.FillTransparency[2].Time == 0.1667)
	local codeCue = byFrame[105]
	check("code on a keyed effect's event is a cue holding it, not another copy", codeCue and codeCue.Object == nil and codeCue.Code == 'print("not an emit")' and result.Skipped.Highlight == nil)
	local light = byFrame[200]
	check("a light in an arm attachment goes on the arm in its own copy of the attachment", light and light.Object == armBulb and light.Wrap == "Attachment" and light.Parent == "Right Arm" and light.Animation.Path[1] == "PointLight" and #light.Animation.Path == 1 and cfNear(light.Offset, a1.CFrame), light and tostring(light.Offset))
	check("a Highlight on the arm goes on the arm", byFrame[300] and byFrame[300].Parent == "Right Arm")
	local victimHl = byFrame[320]
	check("a victim's Highlight is for that rig", victimHl and victimHl.Rig == "Victim" and victimHl.Parent == "Head", victimHl and victimHl.Rig)
	local prop = byFrame[400]
	check("a light in a prop's attachment is carried where the prop was", prop and prop.Object == p1Bulb and prop.Wrap == "AttachmentPart" and prop.Rig == nil and prop.Animation.Path[1] == "i1" and prop.Animation.Path[2] == "PointLight" and cfNear(prop.Offset, root.CFrame:ToObjectSpace(p1.CFrame * i1.CFrame)))
	local lampCue = byFrame[410]
	check("a light straight in a prop's part rides in an invisible part", lampCue and lampCue.Wrap == "Part" and lampCue.Animation.Path[1] == "Glow" and cfNear(lampCue.Offset, root.CFrame:ToObjectSpace(lamp.CFrame)))
	check("Lighting is a lighting cue", byFrame[500] and byFrame[500].Animation.Kind == "Lighting" and byFrame[500].Object == nil)
	local moving = byFrame[60]
	check("a moving part spawns where it starts moving, not while it sits still", byFrame[50] == nil and moving ~= nil and moving.Animation.Keys.CFrame[1].Time == 0 and #moving.Animation.Keys.CFrame == 2)
	check("and spawns where it starts", moving and moving.Object == trail and cfNear(moving.Offset, root.CFrame:ToObjectSpace(trail.CFrame)))
	check("and its path is relative to the character", moving and moving.Animation.Origin and cfNear(moving.Animation.Keys.CFrame[2].Value, root.CFrame:ToObjectSpace(CFrame.new(0, 3, -21))))

	-- Events on Moon's Subtitles count for what they emit; code that does something else is kept.
	check("an emit on Moon's Subtitles is a cue", byFrame[150] and byFrame[150].Object == p1, byFrame[150] and byFrame[150].Effect)
	check("so is Part_Icles' AbsoluteEmit through a local", byFrame[160] and byFrame[160].Object == lamp and byFrame[160].Code == nil)
	local script = byFrame[170]
	check("other code on Subtitles is a cue holding it", script and script.Object == nil and script.Effect == "Event code" and string.find(script.Code, "Instance.new(\"Highlight\")", 1, true) ~= nil)
	check("an empty event on Subtitles is left out", byFrame[180] == nil and result.Skipped.Subtitles == 1, result.Skipped.Subtitles)
	check("no warning about the Subtitles item", not string.find(table.concat(result.Warnings, " "), "Couldn't find", 1, true), result.Warnings[1])
	local fireCue = byFrame[190]
	check("an emitter emitted from a rig's attachment spawns a copy of the attachment, on its part", fireCue and fireCue.Object == a1 and fireCue.Only and fireCue.Only[1] == fire and fireCue.Effect == "Fire" and fireCue.Parent == "Right Arm" and cfNear(fireCue.Offset, a1.CFrame), fireCue and fireCue.Parent)
	local boxCue = byFrame[197]
	check("emitters named in a prop's part are one cue for the part", boxCue and boxCue.Object == box and boxCue.Only and #boxCue.Only == 2 and boxCue.Effect == "Box" and byFrame[198] == nil)
	local beamCue = byFrame[199]
	check("an attachment whose beam reaches another attachment brings both, and only its beam", beamCue and beamCue.Object == box and beamCue.Only and #beamCue.Only == 1 and beamCue.Only[1] == slash and beamCue.Effect == "B0", beamCue and beamCue.Object and beamCue.Object.Name)
	check("an emit of something that isn't in the place is left out, with a warning", byFrame[195] == nil and #result.Warnings == 1 and string.find(result.Warnings[1], "frame 195", 1, true) ~= nil, result.Warnings[1])

	-- Packaging wraps the prop's light; the generated module compiles and plays with data.Rigs.
	local assets = __load("Packager").build(result.Cues)
	local glowHolder = assets:FindFirstChild("Glow")
	check("the prop's light is packed in a holder part", glowHolder and glowHolder.ClassName == "Part" and glowHolder:FindFirstChild("Glow") ~= nil)
	local fireHolder = assets:FindFirstChild(fireCue.Asset)
	local fireA1 = fireHolder and fireHolder:FindFirstChild("A1")
	check("an emitter from a rig's attachment is packed in a copy of it, alone", fireHolder and fireHolder.ClassName == "Part" and fireA1 and fireA1:FindFirstChild("Fire") and not fireA1:FindFirstChild("PointLight"))
	local boxCopy = assets:FindFirstChild(boxCue.Asset)
	check("a part packed for named emitters has only those, and is invisible", boxCopy and boxCopy:FindFirstChild("E1") and boxCopy:FindFirstChild("E2") and not boxCopy:FindFirstChild("E3") and boxCopy.Transparency == 1)
	local beamCopy = assets:FindFirstChild(beamCue.Asset)
	local copiedBeam = beamCopy and beamCopy:FindFirstChild("B0") and beamCopy:FindFirstChild("B0"):FindFirstChild("Slash")
	check("the beam's copy is drawn between the copied attachments", copiedBeam and copiedBeam.Attachment0 == beamCopy:FindFirstChild("B0") and copiedBeam.Attachment1 == beamCopy:FindFirstChild("B1") and not beamCopy:FindFirstChild("E1"))
	local bulbHolder = assets:FindFirstChild(prop.Asset)
	check("a prop attachment's light is packed alone", bulbHolder and bulbHolder.ClassName == "Part" and bulbHolder:FindFirstChild("i1") and bulbHolder:FindFirstChild("i1"):FindFirstChild("PointLight") and not bulbHolder:FindFirstChild("i1"):FindFirstChild("Sparks"))
	local p1Copy = assets:FindFirstChild("P1")
	check("an emitted prop leaves out the keyframed light its own cue plays", p1Copy and p1Copy:FindFirstChild("i1") and p1Copy:FindFirstChild("i1"):FindFirstChild("Sparks") and not p1Copy:FindFirstChild("i1"):FindFirstChild("PointLight"))
	check("and the original keeps it", i1:FindFirstChild("PointLight") == p1Bulb)

	local source = Formatter.format({ TableName = "Plummet", Lifetime = 10, CueTolerance = 0.15, Runtime = true, FPS = 60, Cues = result.Cues })
	local chunk, compileError = loadstring(source)
	check("a module with keyframed effects compiles", chunk ~= nil, compileError)
	check("it explains how to pass other rigs", string.find(source, 'sequence:Play(track, { Rigs = { ["Victim"] = victim } }, VFX)', 1, true) ~= nil)
	check("event code that only used the character is rewritten to run in game", string.find(source, `-- {__load("Carryover").ADAPTED_MARKER}\n\t\t\t-- Of what it used in Moon's scene, Slinky is character.\n\t\t\tlocal character = character\n`, 1, true) ~= nil)
	check("and isn't carried over (it's written again)", #__load("Carryover").extract(source) == 0)
	check("keyframes are data the Sequence plays, not Functions", string.find(source, "Keys = {\n\t\t\tFillTransparency = { { 0, 1 }, { 0.1667, 0 }, { 0.5, 1 } },\n\t\t}", 1, true) ~= nil and string.find(source, "return Sequence.", 1, true) == nil and string.find(source, __load("Carryover").GENERATED_MARKER, 1, true) == nil)
	check("a light in a prop's attachment says where it is in its VFX", string.find(source, 'Path = { "i1", "PointLight" }, Keys = {', 1, true) ~= nil)
	check("Lighting is a Target, held until the animation ends", string.find(source, '{ Effect = "Lighting", Target = "Lighting", Hold = 1.667, Keys = {', 1, true) ~= nil)
	check("no cue needs its own Lifetime: the Sequence keeps a keyframed effect until its keys finish", select(2, string.gsub(source, "Lifetime = ", "")) == 1)
	check("the VFX it uses are listed", string.find(source, "-- VFX it uses: ", 1, true) ~= nil and string.find(source, "Glow", 1, true) ~= nil)

	local Plummet = loadData(source)
	local Sequence = __load("Sequence")

	local character, charRoot = makeRig("Player", CFrame.new(50, 3, 50))
	local charArm = Instance.new("Part", { Name = "Right Arm", Parent = character })
	local enemy, enemyRoot = makeRig("Enemy", CFrame.new(50, 3, 40))
	local enemyHead = Instance.new("Part", { Name = "Head", Parent = enemy })
	local sequence = Sequence.new(Plummet, character)

	table.clear(warnings)
	local victimCue = Plummet.Cues[320]
	check("a victim cue without data is skipped", sequence:Spawn(victimCue, nil, assets) == nil and #warnings == 1 and string.find(warnings[1], "Victim", 1, true) ~= nil, warnings[1])
	sequence:Spawn(victimCue, nil, assets)
	check("and warns only once", #warnings == 1)

	local onEnemy = sequence:Spawn(victimCue, { Rigs = { Victim = enemy } }, assets)
	check("with data.Rigs it plays on that character", onEnemy and onEnemy.Parent == enemyHead and onEnemy.ClassName == "Highlight")
	check("the Sequence replays Moon's keys on it", onEnemy and onEnemy.FillTransparency == 1)

	local armLight = sequence:Spawn(Plummet.Cues[200], nil, assets)
	local bulb = armLight and armLight:FindFirstChild("PointLight")
	check("a light spawns on the arm and its brightness is animated", armLight and bulb and bulb.Brightness == 0 and armLight.ClassName == "Attachment" and armLight.Parent == charArm)
	for _ = 1, 10 do
		step()
	end
	check("brightness follows the keys", bulb and math.abs(bulb.Brightness - 5) < 1e-2, bulb and bulb.Brightness)

	local players = Instance.new("Players", { Name = "Players", Parent = game })
	local player = Instance.new("Player", { Name = "Player1", Character = character, Parent = players })
	players.LocalPlayer = player
	lighting.ExposureCompensation = 0.5
	sequence:Spawn(Plummet.Cues[500], nil, assets)
	for _ = 1, 20 do
		step()
	end
	check("Lighting is animated for the local player", math.abs(lighting.ExposureCompensation - 2) < 1e-2, lighting.ExposureCompensation)

	local movingPart = sequence:Spawn(Plummet.Cues[60], nil, assets)
	for _ = 1, 30 do
		step()
	end
	check("a moving part follows its path from the character", movingPart and cfNear(movingPart.CFrame, charRoot.CFrame * CFrame.new(0, 0, -21)), movingPart and tostring(movingPart.CFrame))

	sequence:Spawn(Plummet.Cues[170], nil, assets)
	local made = character:FindFirstChildOfClass("Highlight")
	check("and it makes its Highlight on the character playing the move", made ~= nil and made.Parent == character)
	if made then
		made.Parent = nil
	end

	sequence:Stop()
	check("Stop puts Lighting back as it was", lighting.ExposureCompensation == 0.5, lighting.ExposureCompensation)
	check("and removes the VFX", armLight.Parent == nil and movingPart.Parent == nil and onEnemy.Parent == nil)

	-- A keyframed effect stays until its keys finish, even past the animation's Lifetime.
	local short = Sequence.new({ Lifetime = 0.2, FrameRate = 60, Cues = Plummet.Cues }, character)
	local flash = short:Spawn(Plummet.Cues[100], nil, assets)
	for _ = 1, 24 do
		step()
	end
	check("a keyframed effect outlasts a shorter Lifetime", flash and flash.Parent == character)
	for _ = 1, 12 do
		step()
	end
	check("and goes once its keys are done", flash and flash.Parent == nil)

	-- Play hands its data to the cues' Functions, and says once which VFX are missing.
	local got
	local withData = Sequence.new({ FrameRate = 60, Cues = {
		[0] = { Effect = "Note", Function = function(_self, _effect, _character, _cue, data)
			got = data
		end },
		[1] = { Effect = "Spark", Offset = CFrame.new() },
		[2] = { Effect = "Spark", Offset = CFrame.new() },
	} }, character)
	table.clear(warnings)
	local track = Instance.new("AnimationTrack", { IsPlaying = true, TimePosition = 0, Looped = false, Length = 1 })
	withData:Play(track, { Hello = true }, {})
	check("Play says once which VFX weren't given", #warnings == 1 and string.find(warnings[1], 'No VFX given for "Spark"', 1, true) ~= nil, warnings[1])
	step()
	track.TimePosition = 3 / 60
	step()
	check("Play hands its data to the cues' Functions", got and got.Hello == true)
	check("and doesn't warn again as they fire", #warnings == 1, warnings[2])
	check("a missing VFX table is an error", not pcall(withData.Play, withData, track, nil, nil))

	for _, inst in { slinky, victim, p1, lamp, trail, lighting, save, players, character, enemy } do
		inst.Parent = nil
	end
	for _, child in workspace:GetChildren() do
		if child.Name == "BezTrail" or child.Name == "Glow" or child.Name == "i1" then
			child.Parent = nil
		end
	end
end

-- Event code rewritten to run in game: the spawned VFX, the character, other rigs --------------

do
	local workspace = game:GetService("Workspace")
	local Sequence = __load("Sequence")
	local function makeRig(name: string, at: CFrame)
		local model = Instance.new("Model", { Name = name, Parent = workspace })
		local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = at, Parent = model })
		model.PrimaryPart = root
		Instance.new("Humanoid", { Name = "Humanoid", Parent = model })
		return model, root
	end

	-- Shaped like Runbeams in the Plummet Rework save: beams from A1 to attachments in the same part.
	local runner = makeRig("Runner", CFrame.new(0, 3, 0))
	local dummy = makeRig("Dummy", CFrame.new(0, 3, -6))
	local runbeams = Instance.new("Part", { Name = "Runbeams", CFrame = CFrame.new(0, 1, -3), Transparency = 1, Parent = workspace })
	local a1 = Instance.new("Attachment", { Name = "A1", Parent = runbeams })
	local a = Instance.new("Attachment", { Name = "a", CFrame = CFrame.new(-4, 0, 9), Parent = runbeams })
	local b = Instance.new("Attachment", { Name = "b", CFrame = CFrame.new(4, 0, 9), Parent = runbeams })
	local original = Instance.new("Beam", { Name = "Beam115", Attachment0 = a1, Attachment1 = b, Width1 = 8, Parent = a1 })
	Instance.new("Beam", { Name = "BeamDrag smoke", Attachment0 = a1, Attachment1 = a, Width1 = 8, Parent = a1 })
	local barrel = Instance.new("Part", { Name = "Barrel", Parent = workspace })
	local crate = Instance.new("Part", { Name = "Crate", Parent = workspace })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "Run", mockJson({
		Information = { Length = 120, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Runner" }, { "Workspace", "Model" }, "Rig"),
			p({ "Workspace", "Dummy" }, { "Workspace", "Model" }, "Rig"),
			p({ "CoreGui", "MoonAnimatorEffects", "Subtitles" }, { "CoreGui", "ScreenGui", "TextLabel" }, "TextLabel"),
		},
	}), saves)
	local events = folder("MarkerTrack", folder("3", save))
	marker(events, 10, "", [[
local RunService = game:GetService("RunService")
local beamPart = workspace:WaitForChild("Runbeams")
local attachment = beamPart:WaitForChild("A1")
local frames = 0
local connection
connection = RunService.RenderStepped:Connect(function()
	frames += 1
	for _, child in ipairs(attachment:GetChildren()) do
		if child:IsA("Beam") then
			child.Width1 = frames
		end
	end
	if frames >= 3 then
		connection:Disconnect()
	end
end)]])
	-- The Runbeams event names the HumanoidRootPart as its Parent in Moon's Events tab.
	local parentKey = value("StringValue", "1", "Parent", events:FindFirstChild("10"):FindFirstChild("KFMarkers"))
	value("StringValue", "Val", "HumanoidRootPart", parentKey)
	marker(events, 20, "", 'local victim = workspace.Dummy\nlocal highlight = Instance.new("Highlight")\nhighlight.Parent = victim')
	marker(events, 30, "", "workspace.Barrel.Transparency = 1\nworkspace.Crate.Transparency = 1")

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byFrame = {}
	for _, cue in result.Cues do
		byFrame[cue.Frame] = cue
	end

	local run = byFrame[10]
	check("code using only the VFX it names is rewritten to use the spawned copy", run and run.Object == runbeams and run.Adapted and run.Adapted.Effect and run.Adapted.Uses[1].From == "Runbeams" and run.Adapted.Uses[1].To == "effect")
	check("a Parent key can name the HumanoidRootPart, so the effect follows it", run and run.Parent == "HumanoidRootPart", run and run.Parent)
	local victimCode = byFrame[20]
	check("another rig in the code is the one given in data.Rigs", victimCode and victimCode.Adapted and victimCode.Adapted.Rigs[1] == "Dummy")
	local stuck = byFrame[30]
	check("code using other things in the scene stays to adapt by hand", stuck and stuck.Object == barrel and stuck.Adapted == nil and stuck.CodeMissing and stuck.CodeMissing[1] == "Crate")

	local source = Formatter.format({ TableName = "Run", Lifetime = 5, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = result.Cues })
	check("the rewritten code is live in the Function", string.find(source, "\t\t\tif not effect then\n\t\t\t\treturn\n\t\t\tend\n\t\t\tlocal RunService = game:GetService(\"RunService\")\n\t\t\tlocal beamPart = effect\n", 1, true) ~= nil)
	check("and needs the rig it uses", string.find(source, '\t\t\tif not (data and data.Rigs and data.Rigs["Dummy"]) then\n\t\t\t\treturn\n\t\t\tend\n\t\t\tlocal victim = data.Rigs["Dummy"]\n', 1, true) ~= nil)
	check("code it can't rewrite says what to adapt", string.find(source, "-- It uses Crate from your Moon scene", 1, true) ~= nil and string.find(source, "--[[\n\t\t\tworkspace.Barrel.Transparency = 1", 1, true) ~= nil)
	check("the HumanoidRootPart Parent is written", string.find(source, 'Parent = "HumanoidRootPart"', 1, true) ~= nil)
	local codeWarning = nil
	for _, warning in result.Warnings do
		if string.find(warning, "Crate", 1, true) then
			codeWarning = warning
		end
	end
	check("code that can't run in game is a warning when exporting", codeWarning ~= nil and string.find(codeWarning, "frame 30", 1, true) ~= nil, codeWarning)
	check("and its Function warns when it runs instead of doing nothing quietly", string.find(source, '\t\t\twarn("[Moon VFX] Cue [30] \\"Barrel\\" runs event code from Moon that uses Crate', 1, true) ~= nil)
	check("what the code makes goes to the sequence's cleaner", string.find(source, "\t\t\thighlight.Parent = victim\n\t\t\tself:AddToCleaner(highlight)\n", 1, true) ~= nil and string.find(source, "\t\t\tend)\n\t\t\tself:AddToCleaner(connection)\n", 1, true) ~= nil)
	check("the Function gets the sequence as self", string.find(source, "Function = function(self, effect, character, cue, data)", 1, true) ~= nil)
	check("its loops don't use ipairs or pairs", string.find(source, "ipairs", 1, true) == nil and string.find(source, "for _, child in attachment:GetChildren() do", 1, true) ~= nil)

	-- In game: the copy follows the root, and the code's connection drives the copy's beams.
	local assets = __load("Packager").build(result.Cues)
	local Run = loadData(source, { game = game, warn = warn })
	local player, playerRoot = makeRig("Player", CFrame.new(20, 3, 0))
	local sequence = Sequence.new(Run, player)
	local copy = sequence:Spawn(Run.Cues[10], nil, assets)
	local weld = copy and copy:FindFirstChild("WeldConstraint")
	check("the Runbeams copy is welded to the HumanoidRootPart", weld ~= nil and weld.Part0 == playerRoot and weld.Part1 == copy)
	for _ = 1, 5 do
		step()
	end
	local copiedA1 = copy and copy:FindFirstChild("A1")
	local copiedBeam = copiedA1 and copiedA1:FindFirstChild("Beam115")
	check("its connection runs and animates the copy's beams", copiedBeam and copiedBeam.Width1 == 3 and original.Width1 == 8, copiedBeam and copiedBeam.Width1)
	check("which stay joined to the copy's own attachments", copiedBeam and copiedBeam.Attachment0 == copiedA1 and copiedBeam.Attachment1 == copy:FindFirstChild("b"))

	local enemy = makeRig("Enemy", CFrame.new(20, 3, -6))
	check("without the rig in data.Rigs the code doesn't run", pcall(sequence.Spawn, sequence, Run.Cues[20], nil, assets) and enemy:FindFirstChildOfClass("Highlight") == nil)
	sequence:Spawn(Run.Cues[20], { Rigs = { Dummy = enemy } }, assets)
	local made = enemy:FindFirstChildOfClass("Highlight")
	check("with it, the Highlight goes on that character", made ~= nil and made.Parent == enemy)

	table.clear(warnings)
	check("running it warns, and nothing errors", pcall(sequence.Spawn, sequence, Run.Cues[30], nil, assets) and #warnings == 1 and string.find(warnings[1], "Crate", 1, true) ~= nil, warnings[1])

	-- Stopping cleans up what the code made: its Highlight, and its connection mid-way.
	local second = sequence:Spawn(Run.Cues[10], nil, assets)
	step()
	local secondBeam = second:FindFirstChild("A1"):FindFirstChild("Beam115")
	sequence:Stop()
	for _ = 1, 3 do
		step()
	end
	check("Stop removes the Highlight the code made", made and made.Parent == nil)
	check("and disconnects the code's connection", secondBeam.Width1 == 1 and second.Parent == nil, secondBeam.Width1)
	for _, inst in { runner, dummy, runbeams, barrel, crate, save, player, enemy } do
		inst.Parent = nil
	end
end

-- Camera VFX: emitted from the part Moon's camera follows -------------------------------------

do
	local workspace = game:GetService("Workspace")
	local rig = Instance.new("Model", { Name = "Slinky", Parent = workspace })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = CFrame.new(0, 3, 0), Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
	Instance.new("Highlight", { Name = "Highlight", Parent = rig })

	-- A camera rig like the one in Plummet Rework: Moon's camera follows CamPart.
	local camRig = Instance.new("Model", { Name = "Cam", Parent = workspace })
	local camPart = Instance.new("Part", { Name = "CamPart", CFrame = CFrame.new(0, 5, 10) * CFrame.Angles(0, 0.3, 0), Parent = camRig })
	local a2 = Instance.new("Attachment", { Name = "A2", CFrame = CFrame.new(0, 0, -3), Parent = camPart })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "Camera VFX", mockJson({
		Information = { Length = 300, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Slinky" }, { "Workspace", "Model" }, "Rig"),
			p({ "Workspace", "CurrentCamera" }, { "Workspace", "Camera" }, "Camera"),
			p({ "Workspace", "Slinky", "Highlight" }, { "Workspace", "Model", "Highlight" }, "Highlight"),
		},
	}), saves)

	-- The camera attaches to CamPart from frame 213.
	local attach = folder("AttachToPart", folder("2", save))
	value("ObjectValue", "0", nil, folder("Values", folder("0", attach)))
	value("ObjectValue", "0", camPart, folder("Values", folder("213", attach)))
	local fov = folder("FieldOfView", save:FindFirstChild("2"))
	value("NumberValue", "0", 70, folder("Values", folder("0", fov)))
	value("NumberValue", "0", 70, folder("Values", folder("230", fov)))
	value("NumberValue", "0", 90, folder("Values", folder("236", fov)))
	value("NumberValue", "0", 70, folder("Values", folder("248", fov)))
	marker(folder("MarkerTrack", folder("3", save)), 220, "", "shared.vfx.emit(workspace.Cam.CamPart.A2)")

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local fovCue = result.Cues[2]
	check("the camera's field of view is a cue from when it starts changing", fovCue and fovCue.Frame == 230 and fovCue.Animation.Kind == "Camera" and #fovCue.Animation.Keys.FieldOfView == 3 and fovCue.Animation.Keys.FieldOfView[2].Value == 90, fovCue and fovCue.Frame)
	local fovSource = Formatter.format({ TableName = "Cam", Lifetime = 1, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = { fovCue } })
	check("it's a camera Target the Sequence plays", string.find(fovSource, '{ Effect = "FieldOfView", Target = "Camera", Hold = 1.167, Keys = {', 1, true) ~= nil and loadstring(fovSource) ~= nil, fovSource)
	check("held until the animation ends, as Moon does", fovCue and fovCue.Animation.Hold == 1.167, fovCue and fovCue.Animation.Hold)

	-- Animate's Duration holds the last values before putting the originals back.
	local held = Instance.new("PointLight", { Name = "Held", Brightness = 1, Parent = workspace })
	__load("Sequence").Animate(held, { Brightness = { { 0, 0 }, { 0.1, 5 } } }, { Restore = true, Duration = 0.5 })
	for _ = 1, 12 do
		step()
	end
	check("Duration holds the last key's value", held.Brightness == 5, held.Brightness)
	for _ = 1, 30 do
		step()
	end
	check("then puts the original back", held.Brightness == 1, held.Brightness)
	held.Parent = nil
	local cue = result.Cues[1]
	check("an effect on the part the camera follows is a camera effect", cue and cue.Parent == "Camera" and cue.Object == a2, cue and cue.Parent)
	check("measured from that part", cue and cfNear(cue.Offset, a2.CFrame), cue and tostring(cue.Offset))
	check("with no notes", cue and #cue.Notes == 0, cue and cue.Notes[1])

	-- At runtime it's placed in front of the camera and follows it.
	local vfx = Instance.new("Folder", { Name = "VFX" })
	Instance.new("Part", { Name = "A2", Parent = vfx })
	local source = Formatter.format({ TableName = "Fx", Lifetime = 1, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = { { Frame = 0, Effect = "A2", Parent = "Camera", Offset = CFrame.new(0, 0, -3) } } })
	local Fx = loadData(source)
	local camera = Instance.new("Camera", { Name = "Camera", CFrame = CFrame.new(1, 2, 3), FieldOfView = 60, Parent = workspace })
	workspace.CurrentCamera = camera

	local character = Instance.new("Model", { Name = "Character" })
	Instance.new("Part", { Name = "HumanoidRootPart", Parent = character })
	local sequence = __load("Sequence").new(Fx, character)
	local effect = sequence:Spawn(Fx.Cues[0], nil, vfx)
	check("a camera effect starts in front of the camera", effect and cfNear(effect.CFrame, camera.CFrame * CFrame.new(0, 0, -3)))
	camera.CFrame = CFrame.new(10, 0, 0) * CFrame.Angles(0, 1, 0)
	step()
	check("and follows the camera", effect and cfNear(effect.CFrame, camera.CFrame * CFrame.new(0, 0, -3)))

	-- The field of view zooms for the player whose character it is, and goes back when it stops.
	local players = Instance.new("Players", { Name = "Players", Parent = game })
	players.LocalPlayer = Instance.new("Player", { Name = "Player1", Character = character, Parent = players })
	local zoom = loadData(fovSource)
	sequence:Spawn(zoom.Cues[230], nil, vfx)
	for _ = 1, 6 do
		step()
	end
	check("the camera's field of view follows Moon's keys", math.abs(camera.FieldOfView - 90) < 1e-2, camera.FieldOfView)
	sequence:Stop()
	check("Stop puts the field of view back", camera.FieldOfView == 60 and effect.Parent == nil, camera.FieldOfView)
	players.Parent, camera.Parent = nil, nil

	rig.Parent, camRig.Parent, save.Parent = nil, nil, nil
	workspace.CurrentCamera = nil
end

-- Events on things that aren't VFX objects --------------------------------------------------

do
	local workspace = game:GetService("Workspace")
	local rig = Instance.new("Model", { Name = "Slinky", Parent = workspace })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", CFrame = CFrame.new(0, 3, 0), Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })
	local arm = Instance.new("Part", { Name = "Right Arm", CFrame = CFrame.new(1.5, 3, 0), Parent = rig })
	Instance.new("Motor6D", { Part0 = root, Part1 = arm, C0 = CFrame.new(1.5, 0, 0), C1 = CFrame.new(), Parent = root })
	Instance.new("Highlight", { Name = "Highlight", Parent = rig })
	Instance.new("Highlight", { Name = "ArmGlow", Parent = arm })
	Instance.new("ParticleEmitter", { Name = "ArmSparks", Parent = arm })
	local burst = Instance.new("Part", { Name = "Burst", CFrame = CFrame.new(0, 3, -5), Parent = workspace })
	Instance.new("ParticleEmitter", { Name = "BurstEmitter", Parent = burst })
	Instance.new("Camera", { Name = "Camera", Parent = workspace })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	local save = value("StringValue", "Slinky Move", mockJson({
		Information = { Length = 120, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Slinky" }, { "Workspace", "Model" }, "Rig"),
			-- Moon's subtitles live in CoreGui, which the place doesn't have here.
			p({ "CoreGui", "MoonAnimatorEffects", "Subtitles" }, { "CoreGui", "ScreenGui", "TextLabel" }, "TextLabel"),
			p({ "Workspace", "Camera" }, { "Workspace", "Camera" }, "Camera"),
			p({ "Workspace", "Slinky", "Highlight" }, { "Workspace", "Model", "Highlight" }, "Highlight"),
			p({ "Workspace", "Slinky", "Right Arm", "ArmGlow" }, { "Workspace", "Model", "Part", "Highlight" }, "Highlight"),
			p({ "Workspace", "Burst", "BurstEmitter" }, { "Workspace", "Part", "ParticleEmitter" }, "ParticleEmitter"),
			p({ "Workspace", "Slinky", "Right Arm", "ArmSparks" }, { "Workspace", "Model", "Part", "ParticleEmitter" }, "ParticleEmitter"),
		},
	}), saves)

	local subtitleEvents = folder("MarkerTrack", folder("2", save))
	marker(subtitleEvents, 10, "")
	marker(subtitleEvents, 20, "")
	marker(folder("MarkerTrack", folder("3", save)), 30, "")
	marker(folder("MarkerTrack", folder("4", save)), 40, "")
	marker(folder("MarkerTrack", folder("5", save)), 50, "")
	marker(folder("MarkerTrack", folder("6", save)), 60, "")
	marker(folder("MarkerTrack", folder("7", save)), 70, "")

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byFrame = {}
	for _, cue in result.Cues do
		byFrame[cue.Frame] = cue
	end

	check("Subtitles events are left out", result.Skipped.Subtitles == 2 and byFrame[10] == nil and byFrame[20] == nil)
	check("camera events are left out", result.Skipped.Camera == 1 and byFrame[30] == nil)
	check("only the real effects become cues", #result.Cues == 4 and result.EventCount == 4, #result.Cues)

	-- Screen effects: a blur in Lighting (present in the place) and one of Moon's own (not present).
	local lighting = Instance.new("Lighting", { Name = "Lighting", Parent = game })
	Instance.new("BlurEffect", { Name = "Blur", Parent = lighting })
	local screenSave = value("StringValue", "Screen Effects", mockJson({
		Information = { Length = 60, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Slinky" }, { "Workspace", "Model" }, "Rig"),
			p({ "Lighting", "Blur" }, { "Lighting", "BlurEffect" }, "BlurEffect"),
			p({ "Lighting", "MoonColorCorrection" }, { "Lighting", "ColorCorrectionEffect" }, "ColorCorrectionEffect"),
			p({ "Workspace", "Camera", "MoonFlash" }, { "Workspace", "Camera", "Frame" }, "Frame"),
		},
	}), saves)
	marker(folder("MarkerTrack", folder("2", screenSave)), 5, "")
	marker(folder("MarkerTrack", folder("3", screenSave)), 6, "")
	marker(folder("MarkerTrack", folder("4", screenSave)), 7, "")
	local screen = Exporter.collect(SaveReader.load(screenSave), { EffectName = "Event", FrameRate = 60 })
	-- None of these has keyframes, so there's no screen effect to play; the camera's never one.
	check("screen effects with nothing keyed, and camera items, are left out", #screen.Cues == 0 and screen.Skipped.Blur == 1 and screen.Skipped.MoonColorCorrection == 1 and screen.Skipped.MoonFlash == 1, #screen.Cues)
	check("and so not reported as missing", #screen.Warnings == 0, screen.Warnings[1])
	lighting.Parent, screenSave.Parent = nil, nil

	local highlight = byFrame[40]
	check("a Highlight on the rig is a cue for the character", highlight and highlight.Object ~= nil and highlight.Parent == nil and #highlight.Notes == 0, highlight and highlight.Notes[1])
	check("a Highlight on a limb has that limb as Parent", byFrame[50] and byFrame[50].Parent == "Right Arm")
	check("an emitter in a free part spawns its part", byFrame[60] and byFrame[60].Object == burst and cfNear(byFrame[60].Offset, root.CFrame:ToObjectSpace(burst.CFrame)))
	check("an emitter on a limb goes on that limb", byFrame[70] and byFrame[70].Parent == "Right Arm" and byFrame[70].Object.Name == "ArmSparks")

	rig.Parent, burst.Parent, save.Parent = nil, nil, nil
	workspace:FindFirstChild("Camera").Parent = nil
end

-- At runtime, a Highlight goes on the character and an emitter on its part.
do
	local vfx = Instance.new("Folder", { Name = "VFX" })
	Instance.new("Highlight", { Name = "Highlight", Parent = vfx })
	Instance.new("ParticleEmitter", { Name = "ArmSparks", Rate = 5, Parent = vfx })
	local source = Formatter.format({
		TableName = "Fx",
		Lifetime = 1,
		CueTolerance = 0.1,
		Runtime = true,
		FPS = 60,
		Cues = {
			{ Frame = 0, Effect = "Highlight", Offset = CFrame.new() },
			{ Frame = 1, Effect = "ArmSparks", Parent = "Right Arm", Offset = CFrame.new() },
		},
	})
	local Fx = loadData(source)

	local character = Instance.new("Model", { Name = "Character" })
	Instance.new("Part", { Name = "HumanoidRootPart", Parent = character })
	local arm = Instance.new("Part", { Name = "Right Arm", Parent = character })
	local sequence = __load("Sequence").new(Fx, character)

	local highlight = sequence:Spawn(Fx.Cues[0], nil, vfx)
	check("a Highlight goes on the character", highlight and highlight.Parent == character)
	local sparks = sequence:Spawn(Fx.Cues[1], nil, vfx)
	check("an emitter goes on its Parent part", sparks and sparks.Parent == arm)
	sequence:Stop()
end

-- Screen effects become cues whose Function plays them ------------------------------------------

do
	local workspace = game:GetService("Workspace")
	local rig = Instance.new("Model", { Name = "Hero", Parent = workspace })
	local root = Instance.new("Part", { Name = "HumanoidRootPart", Parent = rig })
	rig.PrimaryPart = root
	Instance.new("Humanoid", { Name = "Humanoid", Parent = rig })

	-- A blur that is in the place, in Lighting.
	local lighting = Instance.new("Lighting", { Name = "Lighting", Parent = game })
	Instance.new("BlurEffect", { Name = "Blur", Size = 0, Enabled = true, Parent = lighting })

	local function p(names: { string }, types: { string }, itemType: string)
		local n, t = { "game" }, { "DataModel" }
		for i, name in names do
			table.insert(n, name)
			table.insert(t, types[i])
		end
		return { Path = { InstanceNames = n, InstanceTypes = t, ItemType = itemType } }
	end

	-- Shaped like the Vignette in the AeroFinisher save: Moon's overlay, keyed 193 -> 266 -> 274.
	local save = value("StringValue", "With Vignette", mockJson({
		Information = { Length = 300, FPS = 60, Modified = 1 },
		Items = {
			p({ "Workspace", "Hero" }, { "Workspace", "Model" }, "Rig"),
			p({ "CoreGui", "MoonAnimatorEffects", "Vignette" }, { "CoreGui", "ScreenGui", "ImageLabel" }, "ImageLabel"),
			p({ "Lighting", "Blur" }, { "Lighting", "BlurEffect" }, "BlurEffect"),
		},
	}), saves)

	local function numberKeys(track, keys: { { any } })
		for _, key in keys do
			local pack = folder(tostring(key[1]), track)
			value("NumberValue", "0", key[2], folder("Values", pack))
			if key[3] then
				local easeInst = folder("0", folder("Eases", pack))
				value("StringValue", "Type", key[3], easeInst)
				value("StringValue", "Direction", key[4], folder("Params", easeInst))
			end
		end
	end

	local vignette = folder("ImageTransparency", folder("2", save))
	numberKeys(vignette, { { 193, 1, "Sine", "Out" }, { 266, 0.1 }, { 274, 1 } })
	value("NumberValue", "default", 1, vignette)
	numberKeys(folder("Size", folder("3", save)), { { 30, 0 }, { 45, 24 }, { 90, 0 } })

	local result = Exporter.collect(SaveReader.load(save), { EffectName = "Event", FrameRate = 60 })
	local byEffect = {}
	for _, cue in result.Cues do
		byEffect[cue.Effect] = cue
	end

	local v = byEffect.Vignette
	check("a keyed screen effect becomes a cue where its keys start", v ~= nil and v.Frame == 193 and v.Screen ~= nil, v and v.Frame)
	local keys = v and v.Screen.Keys.ImageTransparency
	check("its keys are timed from the cue, in seconds", keys and keys[1].Time == 0 and keys[2].Time == 1.2167 and keys[3].Time == 1.35 and keys[1].Style == "Sine" and keys[1].Direction == "Out")
	check("an overlay Moon wasn't showing starts see-through and full-screen", v and v.Screen.Properties.BackgroundTransparency == 1 and v.Screen.Properties.ImageTransparency == 1 and v.Notes[1] ~= nil)
	local blur = byEffect.Blur
	check("a blur becomes a post-effect cue", blur ~= nil and blur.Frame == 30 and blur.Screen.ClassName == "BlurEffect" and blur.Screen.Properties.Enabled == true)
	check("screen-effect cues have no VFX object", v and v.Object == nil and blur and blur.Object == nil)

	-- The Sequence module plays it on the player's screen.
	local source = Formatter.format({ TableName = "Move", Lifetime = 5, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = result.Cues })
	local chunk, compileError = loadstring(source)
	check("a module with screen effects compiles", chunk ~= nil, compileError)
	check("a screen effect is data: its class, look and keys", string.find(source, '{ Effect = "Vignette", Screen = "ImageLabel", Properties = {', 1, true) ~= nil and string.find(source, "}, Keys = {", 1, true) ~= nil and string.find(source, ", Function = ", 1, true) == nil)
	check("and says who sees them", string.find(source, "-- Screen, Lighting and camera effects show only for the player whose character played them.", 1, true) ~= nil and string.find(source, "ScreenEffectsForEveryone", 1, true) == nil)
	check("and that it plays on the client", string.find(source, "-- Play it on the client (from a LocalScript)", 1, true) ~= nil)

	local character = Instance.new("Model", { Name = "Character" })
	local players = Instance.new("Players", { Name = "Players", Parent = game })
	local player = Instance.new("Player", { Name = "Player1", Character = character, Parent = players })
	players.LocalPlayer = player
	local playerGui = Instance.new("PlayerGui", { Name = "PlayerGui", Parent = player })
	local camera = Instance.new("Camera", { Name = "Camera" })
	workspace.CurrentCamera = camera

	local Move = loadData(source, { UDim2 = UDim2, Enum = Enum })
	local sequence = __load("Sequence").new(Move, character)

	local cue = Move.Cues[193]
	local overlay = sequence:Spawn(cue, nil, {})
	local gui = playerGui:FindFirstChild("MoonScreenEffect")
	check("an overlay goes in a ScreenGui on the player's screen", overlay ~= nil and gui ~= nil and overlay.Parent == gui and overlay.ClassName == "ImageLabel")
	check("it starts at its first key", overlay and overlay.ImageTransparency == 1)
	for _ = 1, 73 do -- 73 frames at 60 fps: the second key, 1.2167 s in
		step()
	end
	check("and follows Moon's keys", overlay and math.abs(overlay.ImageTransparency - 0.1) < 1e-3, overlay and overlay.ImageTransparency)
	for _ = 1, 10 do
		step()
	end
	check("and ends on the last key, then goes away", overlay and overlay.ImageTransparency == 1 and gui.Parent == nil)

	local blurEffect = sequence:Spawn(Move.Cues[30], nil, {})
	check("a post effect goes on the camera", blurEffect ~= nil and blurEffect.Parent == camera and blurEffect.ClassName == "BlurEffect")
	sequence:Stop()
	check("Stop removes it", blurEffect.Parent == nil)

	local someoneElse = Instance.new("Model", { Name = "Other" })
	check("other characters' screen effects aren't shown", __load("Sequence").new(Move, someoneElse):Spawn(cue, nil, {}) == nil)

	-- Re-exporting an older export: its generated Functions are dropped (the Sequence plays those
	-- cues now) unless they were made yours.
	local old = table.concat({
		"local Move",
		"Move = {",
		"\tCues = {",
		'\t\t[193] = { Effect = "Vignette", Offset = CFrame.new(), Function = function(effect, character, cue)',
		`\t\t\t-- {Carryover.GENERATED_MARKER}`,
		'\t\t\treturn Sequence.ScreenEffect(character, "ImageLabel", {}, {})',
		"\t\tend },",
		"\t},",
		"}",
	}, "\n")
	local found = Carryover.extract(old)
	check("an older export's generated Function isn't carried over", #found == 0)

	local edited = string.gsub(old, "%-%- " .. string.gsub(Carryover.GENERATED_MARKER, "%p", "%%%0"), "-- my own version", 1)
	local mine = Carryover.extract(edited)
	Carryover.apply(mine, result.Cues, function(c)
		return tostring(c.Frame)
	end)
	local carried = 0
	for _, c in result.Cues do
		if c.Function and string.find(c.Function, "my own version", 1, true) then
			carried += 1
		end
	end
	check("once its marker line is gone it's kept", carried == 1, carried)

	rig.Parent, lighting.Parent, players.Parent, save.Parent = nil, nil, nil, nil
	workspace.CurrentCamera = nil
end

-- Moon builds its vignette and letterbox from several pieces; the whole effect is exported.
do
	local Sequence = __load("Sequence")

	-- As in Moon Animator: the vignette is four images tiling a 1920x1080 screen...
	local effects = Instance.new("ScreenGui", { Name = "MoonAnimatorEffects" })
	local vignette = Instance.new("ImageLabel", {
		Name = "Vignette",
		Image = "rbxassetid://1",
		ImageTransparency = 1,
		Size = UDim2.new(0.53333336, 0, 0.94814813, 0),
		Position = UDim2.new(0, 0, 0, 0),
		Parent = effects,
	})
	Instance.new("ImageLabel", { Name = "UR", Image = "rbxassetid://2", ImageTransparency = 1, Size = UDim2.new(0.875, 0, 1, 0), Position = UDim2.new(1, 0, 0, 0), Parent = vignette })
	local ll = Instance.new("ImageLabel", { Name = "LL", Image = "rbxassetid://3", ImageTransparency = 1, Size = UDim2.new(1, 0, 0.0546875, 0), Position = UDim2.new(0, 0, 1, 0), Parent = vignette })
	Instance.new("ImageLabel", { Name = "LR", Image = "rbxassetid://4", ImageTransparency = 1, Size = UDim2.new(0.875, 0, 1, 0), Position = UDim2.new(1, 0, 0, 0), Parent = ll })
	-- ...and the letterbox is two bars in a frame, the bottom one keyed.
	local letterbox = Instance.new("Frame", { Name = "Letterbox", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Parent = effects })
	Instance.new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.12174941, 0), Parent = letterbox })
	local bottom = Instance.new("Frame", { Name = "Letterbox", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0.12174941, 0), Position = UDim2.new(0, 0, 1, 0), Parent = letterbox })

	local function item(inst, property, keys)
		return {
			Instance = inst,
			Path = "game.CoreGui.MoonAnimatorEffects." .. inst.Name,
			PathNames = { "game", "CoreGui", "MoonAnimatorEffects", inst.Name },
			PathTypes = { "DataModel", "CoreGui", "ScreenGui", inst.ClassName },
			ItemType = inst.ClassName,
			Markers = {},
			Defaults = {},
			Tracks = { [property] = keys },
		}
	end

	local cue = Exporter.screenCue(item(vignette, "ImageTransparency", { { Time = 10, Value = 1 }, { Time = 20, Value = 0 } }) :: any, 60)
	local screen = cue and cue.Screen
	check("Moon's vignette keeps its own place on screen", screen ~= nil and screen.ClassName == "ImageLabel" and screen.Properties.Size.X.Scale == 0.53333336 and screen.Path == nil)
	local pieces = {}
	for _, child in screen and screen.Children or {} do
		pieces[child.Name] = child
	end
	check("and brings its other three images, which mirror its keys", pieces.UR and pieces.UR.Mirrors and pieces.UR.Properties.Image == "rbxassetid://2" and pieces.LL and pieces.LL.Mirrors and pieces.LL.Children and pieces.LL.Children[1].Name == "LR" and pieces.LL.Children[1].Mirrors)

	local bar = Exporter.screenCue(item(bottom, "BackgroundTransparency", { { Time = 0, Value = 1 }, { Time = 30, Value = 0 } }) :: any, 60)
	local barScreen = bar and bar.Screen
	check("Moon's letterbox is exported from its frame, with Path to the keyed bar", barScreen ~= nil and barScreen.ClassName == "Frame" and barScreen.Path ~= nil and barScreen.Path[1] == "Letterbox" and barScreen.Properties.Size.Y.Scale == 1)
	local top, keyedBar
	for _, child in barScreen and barScreen.Children or {} do
		if child.Name == "Top" then
			top = child
		else
			keyedBar = child
		end
	end
	check("its other bar mirrors the keyed one", top ~= nil and top.Mirrors and keyedBar ~= nil and not keyedBar.Mirrors)

	-- Written out, then played: every piece shows, and the mirrors follow the keyed piece.
	local source = Formatter.format({ TableName = "Fx", Lifetime = 2, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = { bar, cue } })
	check("the pieces are written as Children", string.find(source, '}, Children = {\n\t\t\t{ Name = "UR", ClassName = "ImageLabel", Mirrors = true, Properties = {', 1, true) ~= nil and string.find(source, 'Path = { "Letterbox" }', 1, true) ~= nil)
	local Fx = loadData(source, { UDim2 = UDim2, Enum = Enum })

	local gui = Instance.new("Folder", { Name = "PreviewGui" })
	Sequence.Preview = { GuiParent = gui }
	local watcher = Instance.new("Model", { Name = "Watcher" })
	local seq = Sequence.new(Fx, watcher)
	local shown = seq:Spawn(Fx.Cues[10], nil, {})
	local ur = shown and shown:FindFirstChild("UR")
	local lr = shown and shown:FindFirstChild("LL") and shown:FindFirstChild("LL"):FindFirstChild("LR")
	check("every image of the vignette shows", ur ~= nil and lr ~= nil and ur.Image == "rbxassetid://2" and lr.Image == "rbxassetid://4")
	local frame = seq:Spawn(Fx.Cues[0], nil, {})
	for _ = 1, 30 do
		step()
	end
	check("and the mirrors follow its keys", shown.ImageTransparency == 0 and ur.ImageTransparency == 0 and lr.ImageTransparency == 0, ur and ur.ImageTransparency)
	local keyedFrame, topFrame = frame:FindFirstChild("Letterbox"), frame:FindFirstChild("Top")
	check("the letterbox's keyed bar and its mirror change, not its frame", keyedFrame.BackgroundTransparency < 1e-6 and topFrame.BackgroundTransparency < 1e-6 and frame.BackgroundTransparency == 1)
	seq:Stop()
	Sequence.Preview = nil
end

-- The preview splits long exports so Roblox's 16,384-character text limit doesn't cut them off.
do
	local Widget = __load("Widget")
	local ui = Widget.new(Instance.new("DockWidgetPluginGui"))
	local lines = {}
	for i = 1, 600 do
		lines[i] = string.format("\t\t[%d] = { Effect = \"Effect%d\", Offset = CFrame.new(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1) },", i, i)
	end
	local text = table.concat(lines, "\n")
	ui:SetPreview(text)

	local boxes = { ui.Preview }
	for _, extra in ui.PreviewChunks do
		table.insert(boxes, extra)
	end
	local joined, longest = {}, 0
	for _, box in boxes do
		table.insert(joined, box.Text)
		longest = math.max(longest, #box.Text)
	end
	check("a long preview is split into several boxes", #boxes > 1, #boxes)
	check("each box stays under the limit", longest <= 16384, longest)
	check("nothing is lost", table.concat(joined, "\n") == (string.gsub(text, "\t", "    ")))

	ui:SetPreview("short")
	check("a short preview goes back to one box", #ui.PreviewChunks == 0 and ui.Preview.Text == "short")
	ui:Destroy()
end

-- Autosaves ------------------------------------------------------------------------------------

do
	local autosaves = folder("Autosaves", saves)
	value("StringValue", "Ripper TestAutosave 04-10-2026", mockJson({ Information = { Length = 1, Modified = 9e9 }, Items = {} }), folder("Ripper Test", autosaves))
	local names = {}
	for _, entry in SaveReader.findSaves() do
		table.insert(names, entry.Name)
	end
	check("Moon's autosaves aren't listed", not string.find(table.concat(names, ","), "Autosave", 1, true), table.concat(names, ","))
	autosaves.Parent = nil
end

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

local runner = Instance.new("Model", { Name = "Runner" })
Instance.new("Part", { Name = "HumanoidRootPart", Parent = runner })

local function newTrack(props: { [string]: any }?)
	local track = Instance.new("AnimationTrack", { IsPlaying = true, TimePosition = 0, Looped = false, Length = 2 })
	for key, value in props or {} do
		track[key] = value
	end
	return track
end

-- A sequence of cues at `frames` (60 fps) whose Functions note their frame as they fire.
local function recording(frames: { number }, tolerance: number?)
	local fired = {}
	local cues = {}
	for _, frame in frames do
		cues[frame] = {
			Effect = tostring(frame),
			Function = function()
				table.insert(fired, frame)
			end,
		}
	end
	return Sequence.new({ Cues = cues }, runner, 60, tolerance), fired
end

local function at(track, frame: number)
	track.TimePosition = frame / 60
	step()
end

do
	local seq, fired = recording({ 0, 10, 20 }, 0.15)
	local track = newTrack()
	seq:Play(track, nil, {})
	at(track, 0)
	at(track, 12)
	check("fires cues in order as they come due", table.concat(fired, ",") == "0,10", table.concat(fired, ","))
	at(track, 25)
	check("stops after the last cue", table.concat(fired, ",") == "0,10,20" and seq.Active == false)
end

do
	local seq, fired = recording({ 10 }, 0)
	local track = newTrack()
	seq:Play(track, nil, {})
	at(track, 3)
	at(track, 14) -- lands 4 frames after the cue was due
	check("zero tolerance doesn't drop cues between heartbeats", fired[1] == 10, #fired)
end

do
	local seq, fired = recording({ 0, 55, 70 }, 0.15)
	local track = newTrack({ TimePosition = 1 }) -- Play called a second into the track
	seq:Play(track, nil, {})
	at(track, 60)
	at(track, 72)
	check("skips cues overdue by more than CueTolerance at Play", table.concat(fired, ",") == "55,70", table.concat(fired, ","))
end

do
	local seq, fired = recording({ 5, 58 }, 0.15)
	local track = newTrack({ Looped = true, Length = 1 })
	seq:Play(track, nil, {})
	at(track, 6)
	at(track, 57)
	at(track, 3) -- wrapped around
	at(track, 6)
	check("looped tracks replay cues and catch the one before the wrap", table.concat(fired, ",") == "5,58,5", table.concat(fired, ","))
	check("looped sequence keeps running", seq.Active)
	seq:Stop()
end

do
	local seq, fired = recording({ 5, 118 }, 0.15)
	local track = newTrack()
	seq:Play(track, nil, {})
	at(track, 6)
	at(track, 117)
	track.IsPlaying = false
	at(track, 120) -- ended between heartbeats
	check("cues due as the track ends still fire", table.concat(fired, ",") == "5,118" and not seq.Active, table.concat(fired, ","))
end

do
	local seq, fired = recording({ 5, 30 }, 0.15)
	local track = newTrack()
	seq:Play(track, nil, {})
	at(track, 6)
	at(track, 2) -- rewound
	at(track, 7)
	check("rewinding re-arms cues", table.concat(fired, ",") == "5,5", table.concat(fired, ","))
	seq:Stop()
	at(track, 40)
	check("Stop cancels the rest", table.concat(fired, ",") == "5,5")
end

do
	local seq, fired = recording({ 0 })
	local track = newTrack()
	seq:Play({ AnimationTrack = track }, nil, {})
	at(track, 1)
	check("accepts a table holding the track", fired[1] == 0)
end

do
	local seq, fired = recording({ 0, 30 })
	seq:Play(nil, nil, {})
	step()
	check("without a track, cues play by the clock from Play", table.concat(fired, ",") == "0" and seq.Active, table.concat(fired, ","))
	for _ = 1, 30 do
		step()
	end
	check("and it ends after the last one", table.concat(fired, ",") == "0,30" and not seq.Active, table.concat(fired, ","))
end

do
	table.clear(warnings)
	local seq = recording({ 0 })
	local ok1 = pcall(seq.Play, seq, {}, nil, {})
	local ok2 = pcall(seq.Play, seq, Instance.new("Animation"), nil, {})
	check("a bad track warns instead of erroring", ok1 and ok2 and #warnings == 2 and not seq.Active, #warnings)
	check("the VFX table is required", not pcall(seq.Play, seq, nil, nil, nil) and not pcall(seq.Play, seq, nil, nil, "VFX"))
end

check("rejects non-number cue keys", not pcall(Sequence.new, { Cues = { Hit = {} } }, runner))
check("rejects cues that aren't tables", not pcall(Sequence.new, { Cues = { [0] = "Hit" } }, runner))
check("rejects a zero frame rate", not pcall(Sequence.new, { FrameRate = 0, Cues = {} }, runner) and not pcall(Sequence.new, { Cues = {} }, runner, 0))
check("rejects a negative tolerance", not pcall(Sequence.new, { Cues = {} }, runner, 60, -1))

do
	local exported = { FrameRate = 240, CueTolerance = 0.5, Cues = {} }
	local given = Sequence.new(exported, runner, 60, 0.1)
	check("a frame rate and tolerance given to new() are used", given.FrameRate == 60 and given.Tolerance == 0.1)
	local defaults = Sequence.new(exported, runner)
	check("otherwise they're the table's", defaults.FrameRate == 240 and defaults.Tolerance == 0.5)
	local bare = Sequence.new({ Cues = {} }, runner)
	check("and with neither, keys are in seconds and nothing is too late", bare.FrameRate == 1 and bare.Tolerance == math.huge)
end
check("needs the exported table", not pcall(Sequence.new, {}, runner))
check("needs a character", not pcall(Sequence.new, { Cues = {} }, nil))

do
	local workspace = game:GetService("Workspace")
	local seq = Sequence.new({ Lifetime = 1, Cues = {} }, runner)
	local part = Instance.new("Part", { Name = "Made", Parent = workspace })
	check("AddToCleaner hands back what it's given", seq:AddToCleaner(part) == part)
	local called = false
	seq:AddToCleaner(function()
		called = true
	end)
	local connection = game:GetService("RunService").Heartbeat:Connect(function() end)
	seq:AddToCleaner(connection)
	local kept = seq:AddToCleaner(Instance.new("Part", { Name = "Kept", Parent = workspace }), math.huge)
	local brief = seq:AddToCleaner(Instance.new("Part", { Name = "Brief", Parent = workspace }), 0.1)
	for _ = 1, 7 do
		step()
	end
	check("a lifetime of its own removes it then", brief.Parent == nil and part.Parent ~= nil)
	for _ = 1, 60 do
		step()
	end
	check("otherwise the animation's Lifetime does", part.Parent == nil and called and not connection.Connected)
	check("math.huge keeps it until the sequence stops", kept.Parent ~= nil)
	seq:Stop()
	check("which cleans up the rest", kept.Parent == nil)
end

do
	-- A Function that fails is a warning; the other cues still fire.
	local fired = {}
	local failing = Sequence.new({ FrameRate = 60, Cues = {
		[0] = { Effect = "Broken", Function = function()
			error("not supported in game")
		end },
		[1] = { Effect = "Fine", Function = function()
			table.insert(fired, 1)
		end },
	} }, runner)
	table.clear(warnings)
	local track = newTrack()
	local ok = pcall(function()
		failing:Play(track, nil, {})
		at(track, 0)
		at(track, 2)
	end)
	check("a cue's Function that errors doesn't stop the sequence", ok and fired[1] == 1)
	check("it's a warning naming the cue instead", #warnings == 1 and string.find(warnings[1], '[0] "Broken"', 1, true) ~= nil and string.find(warnings[1], "not supported in game", 1, true) ~= nil, warnings[1])
	check("firing one by hand doesn't error either", pcall(failing.Spawn, failing, failing.Animation.Cues[0], nil, {}))

	-- What the Formatter can't write is a warning too, not silently dropped.
	local _, formatWarnings = Formatter.format({ TableName = "T", Lifetime = 1, CueTolerance = 0.1, Runtime = true, FPS = 60, Cues = {
		{ Frame = 0, Effect = "Odd", Asset = "Odd", Offset = CFrame.new(), Animation = { Kind = "Animate", Keys = {
			Transparency = { { Time = 0, Value = {} } },
			Brightness = { { Time = 0, Value = 1 } },
		} } },
	} })
	check("keys it can't write are a warning", #formatWarnings == 1 and string.find(formatWarnings[1], 'Cue [0] "Odd"', 1, true) ~= nil and string.find(formatWarnings[1], "Transparency", 1, true) ~= nil, formatWarnings[1])
end

do
	-- ImageLabels' images are loaded ahead of time, each once.
	local loaded = {}
	local provider = Instance.new("ContentProvider", {
		Name = "ContentProvider",
		PreloadAsync = function(_self, list)
			for _, image in list do
				table.insert(loaded, image)
			end
		end,
		Parent = game,
	})
	local vfx = Instance.new("Folder", { Name = "VFX" })
	local sign = Instance.new("Part", { Name = "Sign", Parent = vfx })
	local billboard = Instance.new("BillboardGui", { Name = "Board", Parent = sign })
	Instance.new("ImageLabel", { Name = "Icon", Image = "rbxassetid://222", Parent = billboard })
	local animation = { FrameRate = 60, Cues = {
		[0] = { Effect = "Vignette", Screen = "ImageLabel", Properties = { Image = "rbxassetid://111" } },
		[1] = { Effect = "Sign", Offset = CFrame.new() },
	} }

	local seq = Sequence.new(animation, runner)
	check("a screen effect's image is loaded as soon as there's a sequence", table.concat(loaded, ",") == "rbxassetid://111", table.concat(loaded, ","))
	seq:Play(nil, nil, vfx)
	check("an ImageLabel in the VFX is loaded at Play", table.concat(loaded, ",") == "rbxassetid://111,rbxassetid://222", table.concat(loaded, ","))
	seq:Stop()
	local again = Sequence.new(animation, runner)
	again:Play(nil, nil, vfx)
	again:Stop()
	check("and each image is loaded only once", #loaded == 2, #loaded)
	provider.Parent = nil
	check("without a ContentProvider nothing errors", pcall(Sequence.Preload, { Cues = { [0] = { Effect = "V", Screen = "ImageLabel", Properties = { Image = "rbxassetid://333" } } } }))
end

do
	-- The plugin's preview: no player, screen effects in its GUI, and told of everything spawned.
	local gui = Instance.new("Folder", { Name = "PreviewGui" })
	local made = {}
	Sequence.Preview = {
		GuiParent = gui,
		Spawned = function(object)
			table.insert(made, object)
			object.Archivable = false
		end,
	}
	local vfx = Instance.new("Folder", { Name = "VFX" })
	Instance.new("Part", { Name = "Spark", Parent = vfx })
	local seq = Sequence.new({ FrameRate = 60, Cues = {
		[0] = { Effect = "Spark", Offset = CFrame.new() },
		[1] = { Effect = "Flash", Screen = "Frame", Keys = { BackgroundTransparency = { { 0, 0 }, { 0.5, 1 } } } },
	} }, runner)
	local spark = seq:Spawn(seq.Animation.Cues[0], nil, vfx)
	local flash = seq:Spawn(seq.Animation.Cues[1], nil, vfx)
	check("a preview shows screen effects with no player, in its GUI", flash ~= nil and flash.Parent ~= nil and flash.Parent.Parent == gui)
	check("and is told of what it spawns, so it can keep them out of the place", spark ~= nil and table.find(made, spark) ~= nil and spark.Archivable == false)
	seq:Stop()
	check("which stopping removes", spark.Parent == nil and #gui:GetChildren() == 0)
	Sequence.Preview = nil
end

do
	-- VFX only play on the client: on the server, Play and Spawn warn and play nothing.
	local RunService = game:GetService("RunService")
	local isClient = RunService.IsClient
	RunService.IsClient = function()
		return false
	end

	local fired = {}
	local onServer = Sequence.new({ FrameRate = 60, Cues = {
		[0] = { Effect = "Burst", Function = function()
			table.insert(fired, 0)
		end },
	} }, runner)
	table.clear(warnings)
	local track = newTrack()
	local ok = pcall(onServer.Play, onServer, track, nil, {})
	at(track, 1)
	check("on the server, Play warns and plays nothing", ok and #fired == 0 and not onServer.Active and #warnings == 1 and string.find(warnings[1], "on the server", 1, true) ~= nil, warnings[1])
	check("and doesn't error, even without its VFX table", pcall(onServer.Play, onServer, nil, nil, nil) and #warnings == 2)
	check("Spawn warns the same way", onServer:Spawn(onServer.Animation.Cues[0], nil, {}) == nil and #fired == 0 and #warnings == 3)

	Sequence.Preview = { GuiParent = Instance.new("Folder") }
	onServer:Spawn(onServer.Animation.Cues[0], nil, {})
	check("a preview in Studio isn't the server", #fired == 1 and #warnings == 3)
	Sequence.Preview = nil

	RunService.IsClient = isClient
end

check("loops are written without ipairs or pairs", Formatter.withoutPairs("for _, c in ipairs(x:GetChildren()) do end\nfor k, v in pairs(t) do end") == "for _, c in x:GetChildren() do end\nfor k, v in t do end")
check("other calls with those names are left alone", Formatter.withoutPairs("local n = #ipairs\nprint(pairs)") == "local n = #ipairs\nprint(pairs)")

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
			{ Frame = 50, Effect = "ArmGlow", Asset = "Dust", Parent = "Right Arm", Offset = CFrame.new(0, -1, 0) },
		},
	})

	local chunk, compileError = loadstring(source)
	check("generated module compiles", chunk ~= nil, compileError)
	local Ripper = loadData(source)

	local vfx = Instance.new("Folder", { Name = "VFX" })
	local impactTemplate = Instance.new("Part", { Name = "ImpactAnti", Parent = vfx })
	local burst = Instance.new("ParticleEmitter", { Name = "Burst", Rate = 20, Parent = impactTemplate })
	burst:SetAttribute("EmitCount", 12)
	local dustTemplate = Instance.new("Part", { Name = "Dust", Parent = vfx })
	Instance.new("ParticleEmitter", { Name = "Puff", Rate = 7.6, Parent = dustTemplate })

	local character = Instance.new("Model", { Name = "Character" })
	local rootCFrame = CFrame.new(5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	Instance.new("Part", { Name = "HumanoidRootPart", CFrame = rootCFrame, Parent = character })
	local armCFrame = rootCFrame * CFrame.new(1.5, 0, 0)
	local rightArm = Instance.new("Part", { Name = "Right Arm", CFrame = armCFrame, Parent = character })
	local track = newTrack()

	table.clear(calls)
	table.clear(warnings)
	local seq = Sequence.new(Ripper, character)
	seq:Play(track, nil, {
		ImpactAnti = vfx:FindFirstChild("ImpactAnti"),
		Dust = vfx:FindFirstChild("Dust"),
	})
	check("Play says which VFX it wasn't given", #warnings == 1 and string.find(warnings[1], 'No VFX given for "Gone"', 1, true) ~= nil, warnings[1])
	at(track, 0)

	local spawned = game:GetService("Workspace"):FindFirstChild("ImpactAnti")
	check("spawns a copy of the cue's VFX", spawned ~= nil and spawned ~= impactTemplate)
	check("places it at root * Offset", spawned and cfNear(spawned.CFrame, rootCFrame * CFrame.new(0, 0, -2)))
	check("emits using EmitCount", calls[1] and calls[1].Name == "Emit" and calls[1].Args[1] == 12)

	at(track, 31)
	local dustEmit = calls[2]
	check("falls back to Rate for the emit count", dustEmit and dustEmit.Name == "Emit" and dustEmit.Args[1] == 8)

	at(track, 46)
	check("a missing VFX isn't warned about again as its cue fires", #warnings == 1, warnings[2])
	at(track, 51)
	local glow
	for _, child in game:GetService("Workspace"):GetChildren() do
		if child.Name == "Dust" and child.CFrame and cfNear(child.CFrame, armCFrame * CFrame.new(0, -1, 0)) then
			glow = child
		end
	end
	check("a cue with a Parent spawns at that part", glow ~= nil)
	local weld = glow and glow:FindFirstChild("WeldConstraint")
	check("and is welded to it", weld ~= nil and weld.Part0 == rightArm and weld.Part1 == glow and glow.Anchored == false, weld)
	check("sequence finishes", not seq.Active)

	for _ = 1, 100 do
		step()
	end
	check("the VFX stay out for their Lifetime after the track ends", spawned.Parent ~= nil and glow and glow.Parent ~= nil)
	for _ = 1, 25 do
		step()
	end
	check("then they're removed", spawned.Parent == nil and glow and glow.Parent == nil)

	check("generated table carries its frame rate", string.find(source, "\tFrameRate = 60,", 1, true) ~= nil)
	check("generated module has no tips", string.find(source, "Tip:", 1, true) == nil)
	check("it says how to play it with the Sequence module", string.find(source, "--   local sequence = Sequence.new(Ripper, character)", 1, true) ~= nil and string.find(source, "--   sequence:Play(track, data, VFX)", 1, true) ~= nil and string.find(source, "--   Sequence.new(Ripper, character, frameRate, tolerance)", 1, true) ~= nil)
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
