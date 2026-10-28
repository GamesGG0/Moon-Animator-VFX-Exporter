--[[
	Sequence
	Plays the VFX exported from a Moon Animator or Eclipse Animator animation, in time with the
	animation, and cleans up after them.

		local Sequence = require(path.to.Sequence)
		local MoonAnimation = require(path.to.MoonAnimation)

		local sequence = Sequence.new(MoonAnimation, character)
		track:Play()
		sequence:Play(track, data, {
			Shine = Resources.VFX.Shine,
			ImpactAnti = Resources.VFX.ImpactAnti,
		})

		sequence:Stop() -- ends it now and removes everything it spawned

	Sequence.new(animation, character, frameRate, tolerance)
		animation  The exported table: Lifetime, CueTolerance, FrameRate and Cues, and Emitter when
		           its VFX are emitted with a module of the game's (see Sequence.Emitter).
		character  Who plays it. Offsets are from its HumanoidRootPart, and Parents are its parts.
		frameRate  Optional. The rate the cue keys are in, in frames per second. Defaults to the
		           table's FrameRate, or 1 when its keys are in seconds.
		tolerance  Optional. Seconds a cue may already be overdue when the sequence first reaches it
		           (say, Play was called partway through the track) before it's skipped. Frame-rate
		           dips and hitches never skip cues. Defaults to the table's CueTolerance, or no limit.

	sequence:Play(track, data, vfx)
		Client only (a LocalScript): on the server it warns and plays nothing. To show a move to
		every player, have each client play it on that player's character.
		track  Optional. The AnimationTrack to keep in time with; call Play right after track:Play().
		       Without one, the cues play by the clock from now.
		data   Optional. Anything you like; every cue's Function gets it. Its Rigs field gives the
		       characters for cues that were on other rigs in Moon: { Rigs = { TemplateR6 = victim } }.
		vfx    Required. The VFX objects the cues use, by name: { [Name] = Instance }. A cue's name is
		       its Object, or its Effect when it has no Object. A Folder holding them works too.

	sequence:Stop()
		Cancels the cues still to come and removes everything the sequence spawned: its VFX, its
		screen effects, and its Lighting and camera changes (put back as they were), and everything
		added to its cleaner.

	sequence:AddToCleaner(thing, lifetime)
		Has the sequence clean up something a cue's Function made, like its VFX: an Instance is
		destroyed, a connection disconnected, a function called, a thread cancelled (and a table's
		Destroy or Disconnect). That's when the sequence stops, or after `lifetime` seconds
		(optional: the animation's Lifetime; math.huge waits for the stop). Returns `thing`, so it
		can wrap where it's made:
			local highlight = self:AddToCleaner(Instance.new("Highlight"))

	Sequence.Preload(animation, vfx)
		Loads the images the cues' ImageLabels show (screen effects, and ones in the VFX) ahead of
		time, so they don't pop in late. Sequence.new and Play do it too; call it earlier (when the
		character spawns, say) to load them sooner. vfx is optional.

	Sequence.Emitter(name)
		The emitter an animation names, by its module and method: "ReplicatedStorage.Utilities.VFX:Emit"
		emits each VFX with require(ReplicatedStorage.Utilities.VFX):Emit(vfx). The module is
		required once, the first time, and never cloned. An animation without one is emitted with
		Sequence.Emit: VFX Forge's emitter when the game has it.

	Each cue's VFX is cloned from vfx, placed at its Offset, emitted, animated by its Keys, and removed
	after the animation's Lifetime (or once its Keys finish, if that's later), or when the sequence
	stops. When the track stops, no more cues fire; what's already out finishes on its own.

	A cue is { Effect = "Hit", Offset = CFrame.new(...) }, and can also have:
		Object    the name of its VFX, when that isn't Effect
		Parent    a part or attachment of the character to place it on and follow, or "Camera" (in
		          front of the camera, which only the player whose character played it sees)
		Rig       the other rig it plays on, from data.Rigs
		Lifetime  seconds before its VFX is removed, instead of the animation's
		Keys      keyframes it plays: { Property = { { seconds, value, easingStyle, easingDirection } } }.
		          CFrame keys are offsets, like Offset. An Eclipse Bezier key's direction is its
		          curve's two control points: { seconds, value, "Bezier", { x1, y1, x2, y2 } }.
		          Transparency, Color and Reflectance keyed on a model go on its parts, as in Moon
		          and Eclipse.
		EmitCount particles each of its ParticleEmitters gives off, instead of its own EmitCount
		Emitter   the emitter its VFX is emitted with, instead of the animation's (see
		          Sequence.Emitter); false when it isn't emitted (its Function emits it, say)
		Path      names leading from its VFX to what its Keys animate, e.g. { "A1", "PointLight" }
		Screen    a screen effect to show instead of a VFX (a GUI class such as "ImageLabel", or a
		          post effect such as "BlurEffect"), set up with Properties and animated by Keys.
		          Its other pieces are in Children ({ Name, ClassName, Properties, Children,
		          Mirrors, Keys }): Moon's vignette is four images tiling the screen. Keys play on
		          the piece Path leads to (or the effect itself) and on the pieces that Mirror it; a
		          piece can have Keys of its own. ScaleText = true sizes its text for the player's
		          screen from sizes for a 1080 pixel tall one, as Moon's Subtitles do.
		Subtitle  a subtitle to show instead of a VFX, drawn as Eclipse Animator draws them:
		          { Duration, In, Out, Entrance, Exit, Style, Keys, Order }, times in seconds. Style
		          is how it looks, as what differs from Eclipse's defaults (Text, Speaker, Size,
		          Color, Font...); Keys change that as it shows: { { seconds, style, "Smooth" |
		          "Linear" | "Hold" } }, each style what differs from its Style. Entrance and Exit
		          are Eclipse's motions ("Fade", "Pop", "Typewriter", "Letter pop"...), taking In
		          and Out seconds.
		Target    "Lighting" or "Camera": its Keys play on that instead, held for Hold seconds, then
		          put back (a Screen is shown for its Hold seconds, too, when that's longer).
		          "Shake" shakes the camera as Eclipse's Camera Shake does: Keys are its Strength
		          (0 to 100), Speed and Enabled; Seed picks its pattern, Phase where in it it starts.
		Function  function(self, effect, character, cue, data), run when it fires, after its VFX
		          spawns. self is the sequence (for self:AddToCleaner), effect its VFX (or nil),
		          character the one it plays on, data what was given to Play. If it errors, that's a
		          warning, and the other cues still play.
	A cue with no Offset (and no Object) has no VFX: it's a subtitle, a screen, Lighting or camera
	effect, or just its Function. Subtitles and screen, Lighting and camera effects show only for the
	player whose character played them.
]]

local RunService = game:GetService("RunService")

local module = {}

-- The VFX Exporter replaces older versions of this module that it finds next to its exports.
module.Version = 12

-- VFX play only on the client. On the server, Play and Spawn warn and do nothing.
local function OnServer(Method)
	if RunService:IsClient() or module.Preview then
		return false
	end
	warn(`[Sequence] sequence:{Method} was called on the server, so nothing plays: VFX only play on the client. Call it from a LocalScript; to show a move to every player, have each client play it on that player's character.`)
	return true
end

-- Set by the VFX Exporter's Preview button, which plays an export in Studio without a game:
-- { GuiParent = Instance, Spawned = function(object) }. Screen, Lighting and camera effects then
-- show with no player (screen effects go in GuiParent), and Spawned is given everything the
-- sequence makes. Leave it nil in a game.
module.Preview = nil

-- Tells a preview about something the sequence made.
local function Spawned(Object)
	local Preview = module.Preview
	if Preview and Preview.Spawned and typeof(Object) == "Instance" then
		pcall(Preview.Spawned, Object)
	end
end

-- Keyframes ------------------------------------------------------------------------------------

local TweenService = game:GetService("TweenService")

local MoonEasing = {
	Linear = "Linear", Sine = "Sine", Quad = "Quad", Cubic = "Cubic", Quart = "Quart", Quint = "Quint",
	Sextic = "Quint", Expo = "Exponential", Circ = "Circular", Back = "Back", Bounce = "Bounce", Elastic = "Elastic",
}

-- Roblox's EasingStyle and EasingDirection for each of Moon's easings, looked up once each.
local Easings = {}

-- An Eclipse Bezier ease: the curve from (0, 0) to (1, 1) through two control points, read as how
-- far it has eased (y) at Alpha of the way (x).
local function Bezier(Points, Alpha)
	local X1, Y1, X2, Y2 = math.clamp(Points[1], 0, 1), Points[2], math.clamp(Points[3], 0, 1), Points[4]
	-- Where along the curve x is Alpha: Newton's method, halving when it overshoots.
	local Low, High, U = 0, 1, Alpha
	for _ = 1, 24 do
		local V = 1 - U
		local Miss = 3 * V * V * U * X1 + 3 * V * U * U * X2 + U * U * U - Alpha
		if math.abs(Miss) <= 1e-7 then
			break
		end
		if Miss < 0 then
			Low = U
		else
			High = U
		end
		local Slope = 3 * V * V * X1 + 6 * V * U * (X2 - X1) + 3 * U * U * (1 - X2)
		local Guess = if Slope > 1e-9 then U - Miss / Slope else -1
		U = if Guess > Low and Guess < High then Guess else (Low + High) / 2
	end
	local V = 1 - U
	return 3 * V * V * U * Y1 + 3 * V * U * U * Y2 + U * U * U
end

local function Ease(Style, Direction, Alpha)
	if Style == "Constant" then
		return if Alpha >= 1 then 1 else 0
	end
	if Style == nil or Style == "Linear" then
		return Alpha
	end
	if Style == "Bezier" then
		return if type(Direction) == "table" and Alpha > 0 and Alpha < 1 then Bezier(Direction, Alpha) else Alpha
	end

	local Name = Style .. "/" .. (Direction or "In")
	local Easing = Easings[Name]
	if Easing == nil then
		local Ok, EnumStyle, EnumDirection = pcall(function()
			return Enum.EasingStyle[MoonEasing[Style] or "Linear"], Enum.EasingDirection[Direction or "In"]
		end)
		Easing = if Ok then { EnumStyle, EnumDirection } else false
		Easings[Name] = Easing
	end
	return if Easing then TweenService:GetValue(Alpha, Easing[1], Easing[2]) else Alpha
end

-- Called through pcall, so a value that can't be blended, or a property the object doesn't have,
-- doesn't stop the rest.
local function Lerp(From, To, Alpha)
	return From:Lerp(To, Alpha)
end

local function SetProperty(Object, Property, Value)
	Object[Property] = Value
end

-- A property's value Time seconds in, from Keys of { Seconds, Value, EasingStyle, EasingDirection }.
-- A key's easing shapes the change from it to the next key. Index is the key the last sample was
-- between (time only moves forwards, so the search starts there); returns it for the next sample.
local function Sample(Keys, Time, Index)
	if Time <= Keys[1][1] then
		return Keys[1][2], 1
	end
	Index = Index or 1
	if Keys[Index][1] > Time then
		Index = 1
	end
	while Index < #Keys and Keys[Index + 1][1] <= Time do
		Index += 1
	end
	if Index >= #Keys then
		return Keys[#Keys][2], Index
	end

	local From, To = Keys[Index], Keys[Index + 1]
	local Alpha = Ease(From[3], From[4], (Time - From[1]) / (To[1] - From[1]))
	if type(From[2]) == "number" then
		return From[2] + (To[2] - From[2]) * Alpha, Index
	end
	local Ok, Mixed = pcall(Lerp, From[2], To[2], Alpha)
	if Ok then
		return Mixed, Index
	end
	return (if Alpha >= 1 then To[2] else From[2]), Index
end

-- How long keys run, in seconds.
local function KeysLength(Keys)
	local Length = 0
	for _, Track in Keys or {} do
		if #Track > 0 then
			Length = math.max(Length, Track[#Track][1])
		end
	end
	return Length
end

-- What's in a model as it was before its Transparency, Color or Reflectance was first keyed (see
-- Aggregate): model -> { [Instance] = { Property = original } }.
local AggregateOriginals = setmetatable({}, { __mode = "k" })

local function Fade(Sequence, Amount)
	local Points = {}
	for _, Point in Sequence.Keypoints do
		table.insert(Points, NumberSequenceKeypoint.new(Point.Time, Point.Value + (1 - Point.Value) * Amount, Point.Envelope * (1 - Amount)))
	end
	return NumberSequence.new(Points)
end

local function Tint(Sequence, Color)
	local Points = {}
	for _, Point in Sequence.Keypoints do
		local Value = Point.Value
		table.insert(Points, ColorSequenceKeypoint.new(Point.Time, Color3.new(Value.R * Color.R, Value.G * Color.G, Value.B * Color.B)))
	end
	return ColorSequence.new(Points)
end

-- An Eclipse effect's beam or particles as Eclipse made them (it saves them on each, as JSON in
-- their EffectOriginalProperties attribute): their Color, Transparency, Enabled and a beam's
-- TextureSpeed (Eclipse scrolls its beams' textures itself as it draws them, so it sets theirs to 0).
local function EclipseOriginals(Item)
	local Text = Item:GetAttribute("EffectOriginalProperties")
	if type(Text) ~= "string" then
		return nil
	end
	local HttpService = game:GetService("HttpService")
	local Ok, Row = pcall(HttpService.JSONDecode, HttpService, Text)
	if not Ok or type(Row) ~= "table" then
		return nil
	end
	local function Points(Value)
		return if type(Value) == "table" and type(Value.v) == "table" then Value.v else nil
	end
	local Saved = { Effect = true, Enabled = Row.Enabled ~= false, TextureSpeed = if type(Row.TextureSpeed) == "number" then Row.TextureSpeed else nil }
	pcall(function()
		local List = Points(Row.Transparency)
		if List then
			local Keys = {}
			for _, Point in List do
				table.insert(Keys, NumberSequenceKeypoint.new(Point[1], Point[2], Point[3] or 0))
			end
			Saved.Transparency = NumberSequence.new(Keys)
		end
	end)
	pcall(function()
		local List = Points(Row.Color)
		if List then
			local Keys = {}
			for _, Point in List do
				local Color = Points(Point[2]) or { 1, 1, 1 }
				table.insert(Keys, ColorSequenceKeypoint.new(Point[1], Color3.new(Color[1], Color[2], Color[3])))
			end
			Saved.Color = ColorSequence.new(Keys)
		end
	end)
	return Saved
end

-- Eclipse's helpers in a model, which its model-wide values leave alone.
local function EclipseHelper(Item, Model)
	while Item and Item ~= Model do
		if Item:GetAttribute("EclipsePartRigRoot") or Item:GetAttribute("EclipseGeneratedVisual") or Item:GetAttribute("EclipseArmatureSkinningHelper") then
			return true
		end
		Item = Item.Parent
	end
	return false
end

-- A model has no Transparency, Color or Reflectance of its own; keyed on one, as Moon and Eclipse
-- can, they go on its parts as they do there: Transparency and Reflectance from each part's own
-- (Transparency on its decals too), and Color paints them. An Eclipse effect's beams and particles
-- (a letterbox's, say) fade and tint from how Eclipse made them, and are off once fully faded.
local function Aggregate(Model, Property, Value)
	local Originals = AggregateOriginals[Model]
	if not Originals then
		Originals = {}
		AggregateOriginals[Model] = Originals
	end
	for _, Item in Model:GetDescendants() do
		local Saved = Originals[Item]
		if not Saved then
			Saved = EclipseOriginals(Item) or {}
			Originals[Item] = Saved
			if Saved.TextureSpeed and Item:IsA("Beam") then
				Item.TextureSpeed = Saved.TextureSpeed
			end
			if EclipseHelper(Item, Model) then
				Saved.Helper = true
			elseif Item:IsA("BasePart") then
				Saved.Transparency, Saved.Color, Saved.Reflectance = Item.Transparency, Item.Color, Item.Reflectance
			elseif Item:IsA("Decal") then
				Saved.Transparency = Item.Transparency
			end
		end
		local Original = Saved[Property]
		if Saved.Helper or Original == nil then
			continue
		end
		pcall(function()
			if type(Original) == "number" then
				Item[Property] = Original + (1 - Original) * Value
			elseif Property == "Color" and typeof(Original) == "Color3" then
				Item.Color = Value
			elseif typeof(Original) == "NumberSequence" then
				Item.Transparency = Fade(Original, Value)
				Item.Enabled = Saved.Enabled and Value < 1
			elseif typeof(Original) == "ColorSequence" then
				Item.Color = Tint(Original, Value)
			end
		end)
	end
end

-- Sets a keyed value. With Origin, CFrame values are offsets from it.
local function SetValue(Object, Property, Value, Origin)
	if Origin and typeof(Value) == "CFrame" then
		Value = Origin * Value
		if Property == "CFrame" and Object:IsA("Model") then
			Object:PivotTo(Value)
			return
		elseif Property == "CFrame" and Object:IsA("Attachment") then
			Object.WorldCFrame = Value
			return
		end
	end
	if (Property == "Transparency" or Property == "Color" or Property == "Reflectance") and (Object:IsA("Model") or Object:IsA("Folder")) then
		Aggregate(Object, Property, Value)
		return
	end
	pcall(SetProperty, Object, Property, Value)
end

-- Replays keyframes on Target's properties, starting now. Keys is { [Property] = { { Seconds, Value,
-- EasingStyle, EasingDirection }, ... } }. Options:
--   Path      names leading from Target to the instance to animate, e.g. { "A1", "PointLight" }
--   Origin    a CFrame that CFrame keys are offsets from (where the character stood)
--   Restore   put the original values back at the end
--   Duration  seconds to keep going for, holding the last keys' values, if that's longer
-- Stops early if the instance is destroyed. Returns the animated instance, and a function that stops
-- it now (putting the originals back, with Restore).
function module.Animate(Target, Keys, Options)
	Options = Options or {}

	local Object = Target
	for _, Name in Options.Path or {} do
		Object = Object and Object:FindFirstChild(Name)
	end
	if not Object then
		return nil, function() end
	end

	local Originals = {}
	if Options.Restore then
		for Property in Keys do
			pcall(function()
				Originals[Property] = Object[Property]
			end)
		end
	end

	local Length = math.max(Options.Duration or 0, KeysLength(Keys))
	local Elapsed = 0
	local Cursors = {}
	local Connection
	local Done = false

	local function Finish()
		if Done then
			return
		end
		Done = true
		if Connection then
			Connection:Disconnect()
		end
		for Property, Value in Originals do
			pcall(SetProperty, Object, Property, Value)
		end
	end

	local function Step(DeltaTime)
		Elapsed += DeltaTime
		if not Object.Parent then
			return Finish()
		end
		for Property, Track in Keys do
			if #Track > 0 then
				local Value
				Value, Cursors[Property] = Sample(Track, Elapsed, Cursors[Property])
				SetValue(Object, Property, Value, Options.Origin)
			end
		end
		if Elapsed >= Length then
			Finish()
		end
	end

	Step(0)
	if not Done then
		Connection = RunService.Heartbeat:Connect(Step)
	end
	return Object, Finish
end

-- Whether this player sees a screen effect played by Character's move: screen effects, and Lighting
-- and camera effects, show only for the player whose character played them.
local function ShowsHere(Character)
	if module.Preview then
		return true
	end
	local Players = game:GetService("Players")
	local Player = Players and Players.LocalPlayer
	return Player ~= nil and Character == Player.Character
end

-- Makes a screen effect's piece from its class and look, with its own pieces (Children: { Name,
-- ClassName, Properties, Children, Mirrors, Keys }) inside. Pieces that Mirror the keyed one go in
-- Mirrors; pieces with Keys of their own go in Keyed, with them.
local function BuildPiece(ClassName, Properties, Children, Mirrors, Keyed)
	local Made, Object = pcall(Instance.new, ClassName)
	if not Made then
		warn(`[Sequence] Can't show a screen effect of class "{ClassName}": {Object}`)
		return nil
	end
	for Property, Value in Properties or {} do
		pcall(SetProperty, Object, Property, Value)
	end
	for _, Child in Children or {} do
		local Piece = BuildPiece(Child.ClassName, Child.Properties, Child.Children, Mirrors, Keyed)
		if Piece then
			Piece.Name = Child.Name or Piece.Name
			Piece.Parent = Object
			if Child.Mirrors then
				table.insert(Mirrors, Piece)
			end
			if Child.Keys then
				table.insert(Keyed, { Piece, Child.Keys })
			end
		end
	end
	return Object
end

-- Text sizes in an overlay made for a 1080 pixel tall screen, scaled to this one (as Moon scales its
-- Subtitles), now and whenever the screen changes size. Returns what undoes the watching.
local function ScaleText(Object)
	local Camera = workspace.CurrentCamera
	if not Camera then
		return function() end
	end
	local Labels = {}
	for _, Item in Object:GetDescendants() do
		if Item:IsA("TextLabel") or Item:IsA("TextButton") or Item:IsA("TextBox") then
			Labels[Item] = Item.TextSize
		end
	end
	if Object:IsA("TextLabel") or Object:IsA("TextButton") or Object:IsA("TextBox") then
		Labels[Object] = Object.TextSize
	end
	local function Fit()
		local Ratio = Camera.ViewportSize.Y / 1080
		for Label, Size in Labels do
			Label.TextSize = math.max(1, math.floor(Size * Ratio + 0.5))
		end
	end
	Fit()
	local Connection = Camera:GetPropertyChangedSignal("ViewportSize"):Connect(Fit)
	return function()
		Connection:Disconnect()
	end
end

-- Shows one of Moon's screen effects: an overlay (vignette, flash...) in a ScreenGui, or a post
-- effect (blur, color correction...) on the camera. Properties is its look; Keys animate it from now.
-- An overlay Moon makes from several pieces (its vignette is four images) has them in Children, and
-- Keys play on the piece Path leads to (or the effect itself) and on the pieces that Mirror it, as
-- Moon copies its look onto them; a piece can have Keys of its own too. It's removed once the last
-- key is reached (or after Duration seconds, if that's later). Options.ScaleText scales its text
-- sizes, made for a 1080 pixel tall screen, to the player's. Returns it, and a function that
-- removes it now; nothing if this player doesn't see it.
function module.ScreenEffect(Character, ClassName, Properties, Keys, Duration, Children, Path, Options)
	if not ShowsHere(Character) then
		return nil
	end
	local Players = game:GetService("Players")
	local Player = Players and Players.LocalPlayer

	local Mirrors, PieceKeys = {}, {}
	local Object = BuildPiece(ClassName, Properties, Children, Mirrors, PieceKeys)
	if not Object then
		return nil
	end
	local Keyed = Object
	for _, Name in Path or {} do
		Keyed = Keyed and Keyed:FindFirstChild(Name)
	end

	local Container = Object
	if Object:IsA("PostEffect") then
		Object.Parent = workspace.CurrentCamera
	else
		Container = Instance.new("ScreenGui")
		Container.Name = "MoonScreenEffect"
		Container.IgnoreGuiInset = true
		Container.ResetOnSpawn = false
		Object.Parent = Container
		Container.Parent = if module.Preview then module.Preview.GuiParent else Player:FindFirstChildOfClass("PlayerGui")
	end
	Spawned(Container)

	local Stops = {}
	for _, Piece in { Keyed or Object, table.unpack(Mirrors) } do
		local _, Stop = module.Animate(Piece, Keys or {}, { Duration = Duration })
		table.insert(Stops, Stop)
	end
	local Length = math.max(Duration or 0, KeysLength(Keys))
	for _, Entry in PieceKeys do
		local _, Stop = module.Animate(Entry[1], Entry[2], { Duration = Duration })
		table.insert(Stops, Stop)
		Length = math.max(Length, KeysLength(Entry[2]))
	end
	if Options and Options.ScaleText then
		table.insert(Stops, ScaleText(Object))
	end
	local Done = false
	local function Remove()
		if Done then
			return
		end
		Done = true
		for _, Stop in Stops do
			Stop()
		end
		Container:Destroy()
	end

	-- Animate stops once the keys (and Duration) are done; the effect goes with it.
	if Length <= 0 then
		Remove()
	else
		task.delay(Length, Remove)
	end
	return Object, Remove
end

-- Animates Lighting's properties (exposure, brightness...) like a screen effect: only for the player
-- whose character played the move. The last values hold for Duration seconds (as they do in Moon
-- until the animation ends), then the originals are put back. Returns Lighting, and a function that
-- puts it back now.
function module.LightingEffect(Character, Keys, Duration)
	if not ShowsHere(Character) then
		return nil
	end
	return module.Animate(game:GetService("Lighting"), Keys, { Restore = true, Duration = Duration })
end

-- Animates the camera (its field of view) the same way: only for the player whose character played
-- the move, held for Duration seconds, then put back.
function module.CameraEffect(Character, Keys, Duration)
	local Camera = workspace.CurrentCamera
	if not (Camera and ShowsHere(Character)) then
		return nil
	end
	return module.Animate(Camera, Keys, { Restore = true, Duration = Duration })
end

-- Camera shakes playing, each { Elapsed, Phase, Seed, Keys, Cursors, Length, Stopped }, and the
-- camera as it was before they last moved it.
local Shakes = {}
local ShakeBase, ShakeApplied = nil, nil
local ShakeBound = false
-- When the render step can't be bound (in a preview), the shakes step on RenderStepped instead.
local ShakeConnection = nil

local function ShakeStep(DeltaTime)
	local Camera = workspace.CurrentCamera
	if not Camera then
		return
	end
	-- Where the camera is without the shakes: as the camera scripts just left it, or (when nothing
	-- moved it since the last frame) where it was before the shakes moved it then.
	if not (ShakeApplied and Camera.CFrame == ShakeApplied) then
		ShakeBase = Camera.CFrame
	end
	local Offset = CFrame.identity
	for Shake in Shakes do
		Shake.Elapsed += DeltaTime
		if Shake.Elapsed >= Shake.Length then
			Shake.Stop()
			continue
		end
		local function Value(Property, Default)
			local Track = Shake.Keys[Property]
			if not Track or #Track == 0 then
				return Default
			end
			local Found
			Found, Shake.Cursors[Property] = Sample(Track, Shake.Elapsed, Shake.Cursors[Property])
			return Found
		end
		local Strength = math.clamp(tonumber(Value("Strength", 0)) or 0, 0, 100)
		Shake.Phase += math.clamp(tonumber(Value("Speed", 12)) or 12, 0, 60) * DeltaTime
		if Value("Enabled", true) ~= false and Strength > 0 then
			local function Noise(Axis)
				return math.noise(Shake.Phase, Shake.Seed * 0.017 + Axis * 17.1, Axis * 0.73) * 2
			end
			local Turn = math.rad(Strength * 1.5)
			Offset *= CFrame.new(Noise(1) * Strength * 0.15, Noise(2) * Strength * 0.15, Noise(3) * Strength * 0.15)
				* CFrame.Angles(Noise(4) * Turn, Noise(5) * Turn, Noise(6) * Turn)
		end
	end
	-- The last one to end has put the camera back.
	if not ShakeBase then
		return
	end
	ShakeApplied = ShakeBase * Offset
	Camera.CFrame = ShakeApplied
end

-- Shakes the camera, as Eclipse Animator's Camera Shake does: only for the player whose character
-- played the move. Keys are its Strength (0 to 100: up to 0.15 studs and 1.5 degrees each), Speed
-- (how fast it moves through its noise; 12 if not keyed) and Enabled; Seed picks its pattern and
-- Phase where in it it starts. It runs until its keys end (or for Duration seconds, if that's
-- longer). Returns the camera, and a function that stops it now.
function module.CameraShake(Character, Keys, Duration, Seed, Phase)
	local Camera = workspace.CurrentCamera
	if not (Camera and ShowsHere(Character)) then
		return nil
	end
	local Shake = { Elapsed = 0, Phase = Phase or 0, Seed = Seed or 0, Keys = Keys or {}, Cursors = {} }
	Shake.Length = math.max(Duration or 0, KeysLength(Shake.Keys))
	function Shake.Stop()
		if not Shakes[Shake] then
			return
		end
		Shakes[Shake] = nil
		if next(Shakes) == nil then
			-- Put the camera back where the shakes found it, unless something has moved it since.
			if ShakeApplied and Camera.CFrame == ShakeApplied and ShakeBase then
				Camera.CFrame = ShakeBase
			end
			ShakeBase, ShakeApplied = nil, nil
			if ShakeConnection then
				ShakeConnection:Disconnect()
				ShakeConnection = nil
			elseif ShakeBound then
				pcall(RunService.UnbindFromRenderStep, RunService, "SequenceCameraShake")
			end
			ShakeBound = false
		end
	end
	Shakes[Shake] = true
	if not ShakeBound then
		ShakeBound = true
		-- After the camera scripts move the camera each frame.
		local Bound = pcall(function()
			RunService:BindToRenderStep("SequenceCameraShake", Enum.RenderPriority.Camera.Value + 1, ShakeStep)
		end)
		if not Bound then
			ShakeConnection = RunService.RenderStepped:Connect(ShakeStep)
		end
	end
	return Camera, Shake.Stop
end

-- Subtitles ------------------------------------------------------------------------------------

-- How a subtitle looks when its cue doesn't say (Eclipse Animator's defaults). Colours are hex.
local SUBTITLE_STYLE = {
	Text = "", Speaker = "", Image = "", ImageSide = "Left", ImageShape = "Circle", ImageSize = 64,
	Size = 28, Font = "Gotham", Bold = true, Italic = false, Underline = false, Color = "FFFFFF",
	NameColor = "FFFFFF", NameBold = true, NameItalic = false, NameSize = 21, NameOffset = 4,
	NameOutline = 1, NameOutlineColor = "000000", NameFont = "Gotham", OutlineColor = "15111D",
	Outline = 1, Background = "15111D", BackgroundOpacity = 0, Padding = 12, Radius = 8, Width = 0.65,
	Position = "Bottom", Align = "Center", X = 0, Y = 0, Scale = 1, Rotation = 0, Opacity = 1,
	Rainbow = false, RainbowSpeed = 0.2, RainbowSpread = 0.05, Gradient = false, GradientColor = "A7C8FF",
	GradientAngle = 90, Jitter = 0, JitterSpeed = 18, JitterDecay = 0, Wave = 0, Pulse = 0,
}
-- What blends from one style key to the next: numbers, and colours.
local SUBTITLE_NUMBERS = {
	"NameOffset", "NameOutline", "JitterDecay", "NameSize", "RainbowSpread", "GradientAngle", "Size",
	"ImageSize", "Outline", "BackgroundOpacity", "Padding", "Radius", "Width", "X", "Y", "Scale",
	"Rotation", "Opacity", "RainbowSpeed", "Jitter", "JitterSpeed", "Wave", "Pulse",
}
local SUBTITLE_COLORS = { "NameOutlineColor", "GradientColor", "Color", "NameColor", "OutlineColor", "Background" }
-- Entrances and exits that move each letter (or word) on its own.
local LETTER_MOTIONS = { ["Letter pop"] = true, ["Letter slide"] = true, ["Letter drop"] = true, ["Word spring"] = true }

local function Hex(Value)
	local Ok, Color = pcall(Color3.fromHex, tostring(Value))
	return if Ok then Color else Color3.new(1, 1, 1)
end

-- A subtitle's style Time seconds in: its Style, blended towards its next key (each { seconds,
-- style, "Smooth" | "Linear" | "Hold" }). Its Style gives what differs from the defaults, and each
-- key's what differs from its Style.
local function SubtitleStyle(Subtitle, Time)
	local Base = Subtitle.Style or {}
	local function Full(Part)
		local Style = table.clone(SUBTITLE_STYLE)
		Style.Words = {}
		for _, Changes in { Base, Part } do
			for Name, Value in Changes do
				Style[Name] = Value
			end
		end
		return Style
	end
	local Left, Right = { 0, {} }, nil
	for _, Key in Subtitle.Keys or {} do
		if Key[1] <= Time then
			Left = Key
		else
			Right = Key
			break
		end
	end
	local Style = Full(Left[2])
	if Right and Right[3] ~= "Hold" and Right[1] > Left[1] then
		local To = Full(Right[2])
		local Alpha = math.clamp((Time - Left[1]) / (Right[1] - Left[1]), 0, 1)
		if Right[3] ~= "Linear" then
			Alpha = Alpha * Alpha * (3 - 2 * Alpha)
		end
		for _, Name in SUBTITLE_NUMBERS do
			Style[Name] = Style[Name] + (To[Name] - Style[Name]) * Alpha
		end
		for _, Name in SUBTITLE_COLORS do
			Style[Name] = Hex(Style[Name]):Lerp(Hex(To[Name]), Alpha):ToHex()
		end
	end
	return Style
end

-- A springy 0 to 1 that settles at 1.
local function Spring(T)
	if T <= 0 then
		return 0
	elseif T >= 1 then
		return 1
	end
	local function At(X)
		return 1 - math.exp(-7.5 * X) * (math.cos(10 * X) + 0.75 * math.sin(10 * X))
	end
	return At(T) / At(1)
end

-- Where a subtitle's entrance or exit has it, Age seconds in: its opacity, offset, scale and turn,
-- how much of its text shows (by letter, or by word), and how much of it is wiped in.
local function SubtitleMotion(Subtitle, Age)
	local Result = { Alpha = 1, X = 0, Y = 0, Scale = 1, Rotation = 0, Reveal = 1, Words = false, Wipe = 1 }
	local function Apply(Kind, Progress, Entering)
		if Kind == "None" or LETTER_MOTIONS[Kind] then
			return
		end
		local Settled = if Entering then Spring(Progress) else 1 - (1 - Progress) ^ 2
		local Left = 1 - Settled
		if Kind == "Wipe" then
			Result.Wipe = math.min(Result.Wipe, Progress)
		elseif Kind == "Typewriter" or Kind == "Word by word" then
			Result.Reveal = math.min(Result.Reveal, Progress)
			Result.Words = Kind == "Word by word"
		else
			Result.Alpha *= math.clamp(Progress * 2, 0, 1)
		end
		local Way = if Entering then 1 else -1
		if Kind == "Slide up" then
			Result.Y += Way * Left * 42
		elseif Kind == "Slide down" then
			Result.Y -= Way * Left * 42
		elseif Kind == "Slide left" then
			Result.X += Way * Left * 72
		elseif Kind == "Slide right" then
			Result.X -= Way * Left * 72
		elseif Kind == "Pop" then
			Result.Scale *= math.max(0.01, 0.55 + 0.45 * Settled)
		elseif Kind == "Zoom" then
			Result.Scale *= 0.75 + 0.25 * Settled
		elseif Kind == "Spin" then
			Result.Rotation -= Way * Left * 12
			Result.Scale *= 0.8 + 0.2 * Settled
		end
	end
	local In, Out, Duration = Subtitle.In or 0, Subtitle.Out or 0, Subtitle.Duration or 0
	if In > 0 and Age < In then
		Apply(Subtitle.Entrance or "Fade", math.clamp(Age / In, 0, 1), true)
	end
	if Out > 0 and Age > Duration - Out then
		Apply(Subtitle.Exit or "Fade", math.clamp((Duration - Age) / Out, 0, 1), false)
	end
	return Result
end

-- Where one letter is, Age seconds in, for entrances and exits that move letters (or words) one by
-- one, and the jitter that shakes them.
local function SubtitleGlyph(Subtitle, Age, Index, Count, Word, WordCount, Style)
	local Result = { Alpha = 1, Scale = 1, X = 0, Y = 0, Rotation = 0 }
	local Born = 0
	local function Apply(Kind, Since, Duration, Entering)
		if not LETTER_MOTIONS[Kind] or Duration <= 0 then
			return
		end
		local Rank = if Kind == "Word spring" then Word else Index
		local Total = if Kind == "Word spring" then WordCount else Count
		local Delay = (Rank - 1) / math.max(1, Total - 1) * Duration * 0.6
		local Progress = math.clamp((Since - Delay) / math.max(1 / 60, Duration * 0.4), 0, 1)
		if Entering then
			Born = Delay
		end
		local Value = if Entering then Spring(Progress) else Progress * Progress
		local Left = if Entering then 1 - Value else Value
		Result.Alpha *= if Entering then math.clamp(Progress * 2, 0, 1) else 1 - Progress
		if Kind == "Letter pop" then
			Result.Scale *= math.max(0.01, 1 + Left * 0.65)
		elseif Kind == "Letter drop" then
			Result.Y += Left * (if Entering then -26 else 42)
			Result.Rotation += Left * ((Index % 3) - 1) * 7
		else
			Result.Y += Left * 18
		end
	end
	local Out, Duration = Subtitle.Out or 0, Subtitle.Duration or 0
	Apply(Subtitle.Entrance, Age, Subtitle.In or 0, true)
	Apply(Subtitle.Exit, Age - (Duration - Out), Out, false)
	local Tick = math.floor(Age * Style.JitterSpeed)
	local Decay = if Style.JitterDecay > 0 then math.clamp(1 - math.max(0, Age - Born) / Style.JitterDecay, 0, 1) else 1
	local Strength = (Style.Jitter or 0) * Decay
	Result.X += math.sin(Tick * 127.1 + Index * 311.7) * Strength
	Result.Y += math.sin(Tick * 269.5 + Index * 183.3) * Strength
	return Result
end

-- A style's font: the FontFace to show, and the Enum.Font to measure text with.
local function SubtitleFont(Style)
	local Name = Style.Font
	local Ok, Enum_ = pcall(function()
		return Enum.Font[if Name == "RobotoMono" then "Code" else Name]
	end)
	local Measure = if Ok then Enum_ else Enum.Font.Gotham
	if Style.Bold and Name == "Gotham" then
		Measure = Enum.Font.GothamBold
	elseif Style.Bold and Name == "SourceSans" then
		Measure = Enum.Font.SourceSansBold
	end
	local Family = if Name == "RobotoMono" then Font.new("rbxasset://fonts/families/RobotoMono.json") else Font.fromEnum(if Ok then Enum_ else Enum.Font.Gotham)
	return Font.new(Family.Family, if Style.Bold then Enum.FontWeight.Bold else Enum.FontWeight.Regular, if Style.Italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal), Measure
end

-- Lays a subtitle out at a width (pixels on a 1080 tall screen): its words in lines, with the
-- speaker's name above and its portrait beside or above.
local function SubtitleLayout(Style, Width)
	local TextService = game:GetService("TextService")
	local function Measure(Text, Font)
		return TextService:GetTextSize(Text, Style.Size, Font, Vector2.new(10000, 10000)).X
	end
	local Image = if Style.Image ~= "" then Style.ImageSize else 0
	local Beside = Image > 0 and Style.ImageSide ~= "Above"
	local TextWidth = math.max(40, Width - 2 * Style.Padding - (if Beside then Image + 12 else 0))
	local Lines = { { Width = 0 } }
	local Words, Letters, Index = {}, 0, 0

	local function Add(Piece, WordStyle, WordIndex, Before)
		local Face, Font = SubtitleFont(WordStyle)
		local Line = Lines[#Lines]
		if string.find(Before, "\n", 1, true) then
			Line = { Width = 0 }
			table.insert(Lines, Line)
		end
		local Gap = if Line.Width > 0 then Measure(" ", Font) else 0
		local PieceWidth = Measure(Piece, Font) + 2
		if Line.Width > 0 and Line.Width + Gap + PieceWidth > TextWidth then
			Line = { Width = 0 }
			table.insert(Lines, Line)
			Gap = 0
		end
		local Word = { Text = Piece, Index = WordIndex, Style = WordStyle, Face = Face, Font = Font, X = Line.Width + Gap, Width = math.min(PieceWidth, TextWidth), Line = #Lines, Start = Letters }
		for _ in utf8.graphemes(Piece) do
			Letters += 1
		end
		Word.Finish = Letters
		table.insert(Words, Word)
		Line.Width = Word.X + Word.Width
	end

	for Before, Text in string.gmatch(Style.Text, "(%s*)(%S+)") do
		Index += 1
		if Index > 300 then
			break
		end
		local WordStyle = table.clone(Style)
		for Name, Value in (Style.Words or {})[tostring(Index)] or {} do
			WordStyle[Name] = Value
		end
		local _, Font = SubtitleFont(WordStyle)
		if Measure(Text, Font) <= TextWidth then
			Add(Text, WordStyle, Index, Before)
		else
			-- Too long for a line: split between letters.
			local Piece, First = "", true
			for From, To in utf8.graphemes(Text) do
				local Letter = string.sub(Text, From, To)
				if Piece ~= "" and Measure(Piece .. Letter, Font) > TextWidth then
					Add(Piece, WordStyle, Index, if First then Before else "")
					Piece, First = "", false
				end
				Piece ..= Letter
			end
			if Piece ~= "" then
				Add(Piece, WordStyle, Index, if First then Before else "")
			end
		end
	end

	local LineHeight = math.ceil(Style.Size * 1.3)
	local NameHeight = if Style.Speaker ~= "" then math.ceil(Style.NameSize * 1.3) + 6 else 0
	local TextHeight = #Lines * LineHeight + NameHeight
	local ContentHeight = if Beside then math.max(TextHeight, Image) else TextHeight + (if Image > 0 then Image + 10 else 0)
	local TextX = Style.Padding + (if Beside and Style.ImageSide == "Left" then Image + 12 else 0)
	local TextY = Style.Padding + (if Beside then (ContentHeight - TextHeight) / 2 elseif Image > 0 then Image + 10 else 0) + NameHeight
	for _, Word in Words do
		local Line = Lines[Word.Line]
		local Align = if Style.Align == "Left" then 0 elseif Style.Align == "Right" then TextWidth - Line.Width else (TextWidth - Line.Width) / 2
		Word.X += TextX + Align
		Word.Y = TextY + (Word.Line - 1) * LineHeight
	end
	return {
		Words = Words,
		Width = Width,
		Height = ContentHeight + Style.Padding * 2,
		TextX = TextX,
		TextY = TextY - NameHeight,
		TextWidth = TextWidth,
		NameHeight = NameHeight,
		Image = Image,
		ImageX = if Beside then (if Style.ImageSide == "Left" then Style.Padding else Width - Style.Padding - Image) else (Width - Image) / 2,
		ImageY = if Beside then Style.Padding + (ContentHeight - Image) / 2 else Style.Padding,
		LineHeight = LineHeight,
		Letters = Letters,
		WordCount = Index,
	}
end

-- The subtitles showing, in the order they started, and the ScreenGui they're in.
local Subtitles = {}
local SubtitleGui = nil
local SubtitleConnection = nil

local function Make(ClassName, Parent, Properties)
	local Object = Instance.new(ClassName)
	for Name, Value in Properties do
		Object[Name] = Value
	end
	Object.Parent = Parent
	return Object
end

-- Builds a subtitle's pieces for its layout, in its frame: a box (its background), its words (one
-- label each, and one per letter when letters move or jitter), the speaker's name and the portrait.
-- Built again when its layout changes; its frame stays.
local function BuildSubtitle(Item, Style, Width, Letters)
	local Layout = SubtitleLayout(Style, Width)
	if not Item.Frame then
		Item.Frame = Make("Frame", SubtitleGui, { Name = "Subtitle", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 241 })
		Item.Scale = Make("UIScale", Item.Frame, { Scale = 1 })
	end
	if Item.Clip then
		Item.Clip:Destroy()
	end
	local Frame = Item.Frame
	Frame.Size = UDim2.fromOffset(Width, Layout.Height)
	Item.Layout, Item.Letters, Item.Rows, Item.Glyphs = Layout, Letters, {}, 0
	Item.Clip = Make("Frame", Frame, { Name = "Reveal", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 241 })
	local Content = Make("Frame", Item.Clip, { Name = "Content", Size = UDim2.fromOffset(Width, Layout.Height), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 241 })
	Item.Background = Make("Frame", Content, { Name = "Background", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 241 })
	Item.Corner = Make("UICorner", Item.Background, {})

	local TextService = game:GetService("TextService")
	for _, Word in Layout.Words do
		local Label = Make("TextLabel", Content, {
			Name = "Word" .. Word.Index, BackgroundTransparency = 1, Size = UDim2.fromOffset(Word.Width, Layout.LineHeight),
			Position = UDim2.fromOffset(Word.X, Word.Y), Text = Word.Text, FontFace = Word.Face, TextSize = Style.Size,
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 243,
		})
		local Row = { Label = Label, Word = Word, Glyphs = {} }
		Row.Outline = Make("UIStroke", Label, {})
		Row.Gradient = Make("UIGradient", Label, { Enabled = false })
		if Word.Style.Underline then
			Row.Underline = Make("Frame", Label, { Name = "Underline", BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -4), Size = UDim2.new(1, -2, 0, math.max(1, Style.Size / 20)), ZIndex = 243 })
		end
		if Letters then
			local Before = ""
			for From, To in utf8.graphemes(Word.Text) do
				local Letter = string.sub(Word.Text, From, To)
				local Left = TextService:GetTextSize(Before, Style.Size, Word.Font, Vector2.new(10000, 10000)).X
				Before ..= Letter
				local Right = TextService:GetTextSize(Before, Style.Size, Word.Font, Vector2.new(10000, 10000)).X
				local Glyph = Make("TextLabel", Label, {
					Name = "Letter", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset((Left + Right) / 2, Layout.LineHeight / 2),
					Size = UDim2.fromOffset(math.max(1, Right - Left) + 4, Layout.LineHeight * 2),
					Text = Letter, FontFace = Word.Face, TextSize = Style.Size, ZIndex = 244,
				})
				Item.Glyphs += 1
				table.insert(Row.Glyphs, { Label = Glyph, Outline = Make("UIStroke", Glyph, {}), X = (Left + Right) / 2, Index = Item.Glyphs })
			end
		end
		table.insert(Item.Rows, Row)
	end
	if Layout.NameHeight > 0 then
		local NameStyle = table.clone(Style)
		NameStyle.Font, NameStyle.Bold, NameStyle.Italic = Style.NameFont, Style.NameBold, Style.NameItalic
		Item.Speaker = Make("TextLabel", Content, {
			Name = "Speaker", BackgroundTransparency = 1, Position = UDim2.fromOffset(Layout.TextX, Layout.TextY + Style.NameOffset),
			Size = UDim2.fromOffset(Layout.TextWidth, Layout.NameHeight - 6), Text = Style.Speaker, FontFace = (SubtitleFont(NameStyle)),
			TextSize = Style.NameSize, TextXAlignment = Enum.TextXAlignment[Style.Align], ZIndex = 243,
		})
		Item.SpeakerOutline = Make("UIStroke", Item.Speaker, {})
	else
		Item.Speaker = nil
	end
	if Layout.Image > 0 then
		Item.Portrait = Make("ImageLabel", Content, {
			Name = "Portrait", BackgroundTransparency = 1, Image = "rbxassetid://" .. Style.Image,
			Position = UDim2.fromOffset(Layout.ImageX, Layout.ImageY), Size = UDim2.fromOffset(Layout.Image, Layout.Image),
			ScaleType = Enum.ScaleType.Crop, ZIndex = 242,
		})
		Make("UICorner", Item.Portrait, { CornerRadius = if Style.ImageShape == "Circle" then UDim.new(0.5, 0) else UDim.new(0, 4) })
	else
		Item.Portrait = nil
	end
end

-- What changes a subtitle's layout (so it's built again): its text and how it's set, and its words'
-- own looks, not its colours, motion or place.
local LAYOUT_FIELDS = { "Text", "Speaker", "Image", "ImageSide", "ImageShape", "ImageSize", "Size", "Font", "Bold", "Italic", "Underline", "NameBold", "NameItalic", "NameSize", "NameOffset", "NameFont", "Padding", "Width", "Position", "Align", "Rainbow", "Gradient" }

local function WordsSignature(Words)
	local List = {}
	for Index, Look in Words or {} do
		local Fields = {}
		for Name, Value in Look do
			table.insert(Fields, `{Name}={tostring(Value)}`)
		end
		table.sort(Fields)
		table.insert(List, `{Index}:{table.concat(Fields, ",")}`)
	end
	table.sort(List)
	return table.concat(List, ";")
end

local function SubtitleStep(DeltaTime)
	for _, Item in Subtitles do
		Item.Age += DeltaTime or 0
	end
	local Viewport = SubtitleGui and SubtitleGui.Parent and SubtitleGui.AbsoluteSize
	if not Viewport or Viewport.X < 1 or Viewport.Y < 1 then
		return
	end
	local Resolution = math.max(0.1, Viewport.Y / 1080)
	local Groups = { Top = {}, Center = {}, Bottom = {} }
	for _, Item in Subtitles do
		local Age = Item.Age
		local Subtitle = Item.Subtitle
		local Style = SubtitleStyle(Subtitle, Age)
		local Width = math.min(Viewport.X * Style.Width / Resolution, Viewport.X * 0.94 / (Resolution * Style.Scale * (1 + Style.Pulse)))
		local Letters = LETTER_MOTIONS[Subtitle.Entrance] or LETTER_MOTIONS[Subtitle.Exit] or Style.Jitter > 0
		for _, Word in Style.Words or {} do
			if (Word.Jitter or 0) > 0 then
				Letters = true
			end
		end
		local Signature = { tostring(Letters), string.format("%.2f", Width), WordsSignature(Style.Words) }
		for _, Name in LAYOUT_FIELDS do
			table.insert(Signature, tostring(Style[Name]))
		end
		Signature = table.concat(Signature, "|")
		if Item.Signature ~= Signature then
			BuildSubtitle(Item, Style, Width, Letters)
			Item.Signature = Signature
		end
		Item.Style = Style
		Item.Motion = SubtitleMotion(Subtitle, Age)
		Item.Height = (Item.Layout.Height + (if Letters then 10 else 0)) * Resolution * Style.Scale * (1 + Style.Pulse)
			* (if Subtitle.Entrance == "Pop" or Subtitle.Exit == "Pop" then 1.16 else 1)
		table.insert(Groups[Style.Position] or Groups.Bottom, Item)
	end

	for Position, Items in Groups do
		local Height = 0
		for _, Item in Items do
			Height += Item.Height + 12 * Resolution
		end
		local Fit = math.min(1, Viewport.Y * 0.86 / math.max(Height, 1))
		Height *= Fit
		local Cursor = if Position == "Top" then Viewport.Y * 0.065 elseif Position == "Bottom" then Viewport.Y * 0.935 - Height else (Viewport.Y - Height) / 2
		for _, Item in Items do
			local Style, Motion, Layout, Age = Item.Style, Item.Motion, Item.Layout, Item.Age
			local Alpha = Style.Opacity * Motion.Alpha
			Item.Frame.Position = UDim2.fromOffset(Viewport.X * (0.5 + Style.X) + Motion.X * Resolution, Cursor + Item.Height * Fit / 2 + Viewport.Y * Style.Y + Motion.Y * Resolution)
			Item.Frame.Rotation = Style.Rotation + Motion.Rotation
			Item.Clip.ClipsDescendants = Motion.Wipe < 1
			Item.Clip.Size = UDim2.new(Motion.Wipe, 0, 1, 0)
			Item.Scale.Scale = Resolution * Fit * Style.Scale * Motion.Scale * (1 + Style.Pulse * math.sin(Age * 6))
			Item.Background.BackgroundColor3 = Hex(Style.Background)
			Item.Background.BackgroundTransparency = 1 - Style.BackgroundOpacity * Alpha
			Item.Corner.CornerRadius = UDim.new(0, Style.Radius)

			-- Where each word is drawn: its line laid out again from how wide the words come out on
			-- screen (which can differ a little from what TextService measured), aligned as the style says.
			local Unit = math.max(0.01, Item.Scale.Scale)
			local Lines = {}
			for _, Row in Item.Rows do
				local Word = Row.Word
				local Line = Lines[Word.Line]
				if not Line then
					Line = { Width = 0, X = {} }
					Lines[Word.Line] = Line
				end
				local Drawn = Row.Label.TextBounds.X / Unit
				if Drawn <= 0 then
					Drawn = Word.Width
				end
				if Line.Last then
					Line.Width += math.max(0, Word.X - Line.Last.X - Line.Last.Width)
				end
				Line.X[Word] = Line.Width
				Line.Width += Drawn
				Line.Last = Word
			end
			for _, Line in Lines do
				local Offset = Layout.TextX + (if Style.Align == "Left" then 0 elseif Style.Align == "Right" then Layout.TextWidth - Line.Width else (Layout.TextWidth - Line.Width) / 2)
				for Word, X in Line.X do
					Line.X[Word] = Offset + X
				end
			end

			local Letters = math.floor(Layout.Letters * Motion.Reveal + 0.00001)
			local Words = math.floor(Layout.WordCount * Motion.Reveal + 0.00001)
			for _, Row in Item.Rows do
				local Word = Row.Word
				local Own = setmetatable(table.clone((Style.Words or {})[tostring(Word.Index)] or {}), { __index = Style })
				local function Rainbow(Rank, Total)
					return Color3.fromHSV((Age * Style.RainbowSpeed + (Rank - 1) / math.max(1, Total - 1) * Style.RainbowSpread) % 1, 0.8, 1)
				end
				local Color = if Own.Rainbow then Rainbow(Word.Index, Layout.WordCount) else Hex(Own.Color)
				-- A gradient runs across the whole text, so each word shows its own stretch of it.
				local Angle = math.rad(Style.GradientAngle)
				local Cx, Cy = math.cos(Angle), math.sin(Angle)
				local Wide, Tall = Layout.TextWidth, Layout.Height - 2 * Style.Padding
				local Span = math.max(1, math.abs(Cx) * Wide + math.abs(Cy) * Tall)
				local Least = math.min(0, Cx * Wide) + math.min(0, Cy * Tall)
				local function Along(X, Y)
					return ((X - Layout.TextX) * Cx + (Y - Layout.TextY) * Cy - Least) / Span
				end
				Row.Gradient.Enabled = Style.Gradient and not Own.Rainbow and not Item.Letters
				if Row.Gradient.Enabled then
					Row.Label.TextColor3 = Color3.new(1, 1, 1)
					local Middle = Along(Word.X + Word.Width / 2, Word.Y + Layout.LineHeight / 2)
					local Half = (math.abs(Cx) * Word.Width + math.abs(Cy) * Layout.LineHeight) / (2 * Span)
					local From, To = Hex(Own.Color), Hex(Style.GradientColor)
					Row.Gradient.Color = ColorSequence.new(From:Lerp(To, math.clamp(Middle - Half, 0, 1)), From:Lerp(To, math.clamp(Middle + Half, 0, 1)))
					Row.Gradient.Rotation = Style.GradientAngle
				else
					Row.Label.TextColor3 = Color
				end
				Row.Label.TextTransparency = if Item.Letters then 1 else 1 - Alpha
				Row.Outline.Color = Hex(Style.OutlineColor)
				Row.Outline.Thickness = Style.Outline
				Row.Outline.Enabled = Style.Outline > 0 and not Item.Letters
				Row.Outline.Transparency = 1 - Alpha
				local Shown = Motion.Reveal >= 1 or (if Motion.Words then Word.Index <= Words else Letters > Word.Start)
				if Row.Underline then
					Row.Underline.BackgroundColor3 = Color
					Row.Underline.BackgroundTransparency = 1 - Alpha
					Row.Underline.Visible = Shown
				end
				Row.Label.MaxVisibleGraphemes = if Motion.Words then (if Word.Index <= Words then -1 else 0)
					elseif Motion.Reveal >= 1 then -1
					else math.clamp(Letters - Word.Start, 0, Word.Finish - Word.Start)
				local DrawnX = Lines[Word.Line].X[Word] or Word.X
				Row.Label.Position = UDim2.fromOffset(DrawnX, Word.Y + math.sin(Age * 5 + Word.Index * 0.8) * Style.Wave)
				if Item.Letters then
					Row.Label.MaxVisibleGraphemes = -1
					for _, Glyph in Row.Glyphs do
						local Moved = SubtitleGlyph(Item.Subtitle, Age, Glyph.Index, Item.Glyphs, Word.Index, Layout.WordCount, Own)
						local Visible = if Motion.Words then Word.Index <= Words else Glyph.Index <= Letters
						local Opacity = if Visible then Alpha * Moved.Alpha else 0
						Glyph.Label.TextTransparency = 1 - Opacity
						Glyph.Label.TextSize = Style.Size * Moved.Scale
						Glyph.Label.Position = UDim2.fromOffset(Glyph.X + Moved.X, Layout.LineHeight / 2 + Moved.Y)
						Glyph.Label.Rotation = Moved.Rotation
						Glyph.Label.TextColor3 = if Style.Gradient and not Own.Rainbow
							then Hex(Own.Color):Lerp(Hex(Style.GradientColor), math.clamp(Along(DrawnX + Glyph.X, Word.Y), 0, 1))
							elseif Own.Rainbow then Rainbow(Glyph.Index, Item.Glyphs)
							else Color
						Glyph.Outline.Color = Hex(Style.OutlineColor)
						Glyph.Outline.Thickness = Style.Outline
						Glyph.Outline.Enabled = Style.Outline > 0
						Glyph.Outline.Transparency = 1 - Opacity
					end
				end
			end
			if Item.Speaker then
				Item.Speaker.TextColor3 = Hex(Style.NameColor)
				Item.Speaker.TextTransparency = 1 - Alpha
				Item.SpeakerOutline.Color = Hex(Style.NameOutlineColor)
				Item.SpeakerOutline.Thickness = Style.NameOutline
				Item.SpeakerOutline.Enabled = Style.NameOutline > 0
				Item.SpeakerOutline.Transparency = 1 - Alpha
			end
			if Item.Portrait then
				Item.Portrait.ImageTransparency = 1 - Alpha
			end
			Cursor += (Item.Height + 12 * Resolution) * Fit
		end
	end
end

-- Shows a subtitle, as Eclipse Animator does: only for the player whose character played the move.
-- Subtitle is { Duration, In, Out, Entrance, Exit, Style, Keys, Order } (seconds; see the top of
-- this module). Subtitles showing at once stack at their Position, by Order (lowest first), then by
-- when they started. Returns its frame, and a function that removes it now.
function module.Subtitle(Character, Subtitle)
	if not ShowsHere(Character) then
		return nil
	end
	if not (SubtitleGui and SubtitleGui.Parent) then
		local Players = game:GetService("Players")
		local Player = Players and Players.LocalPlayer
		SubtitleGui = Instance.new("ScreenGui")
		SubtitleGui.Name = "SequenceSubtitles"
		SubtitleGui.IgnoreGuiInset = true
		SubtitleGui.ResetOnSpawn = false
		SubtitleGui.DisplayOrder = 50
		SubtitleGui.Parent = if module.Preview then module.Preview.GuiParent else Player:FindFirstChildOfClass("PlayerGui")
		Spawned(SubtitleGui)
		-- Ones still showing were in the last one: they're built again in this one.
		for _, Other in Subtitles do
			Other.Frame, Other.Clip, Other.Signature = nil, nil, nil
		end
	end
	local Item = { Subtitle = Subtitle, Age = 0 }
	local Order = Subtitle.Order or 0
	local At = #Subtitles + 1
	while At > 1 and (Subtitles[At - 1].Subtitle.Order or 0) > Order do
		At -= 1
	end
	table.insert(Subtitles, At, Item)
	if not SubtitleConnection then
		SubtitleConnection = RunService.RenderStepped:Connect(SubtitleStep)
	end
	SubtitleStep()

	local Done = false
	local function Remove()
		if Done then
			return
		end
		Done = true
		local Index = table.find(Subtitles, Item)
		if Index then
			table.remove(Subtitles, Index)
		end
		if Item.Frame then
			Item.Frame:Destroy()
		end
		if #Subtitles == 0 and SubtitleConnection then
			SubtitleConnection:Disconnect()
			SubtitleConnection = nil
		end
	end
	task.delay(Subtitle.Duration or 0, Remove)
	return Item.Frame, Remove
end

-- A character's HumanoidRootPart, or its PrimaryPart.
local function RootOf(Character)
	local Root = Character:FindFirstChild("HumanoidRootPart")
	if Root and Root:IsA("BasePart") then
		return Root
	end
	return if Character:IsA("Model") then Character.PrimaryPart else nil
end

-- Where a character stands: its HumanoidRootPart, or its pivot.
function module.RootCFrame(Character)
	local Root = RootOf(Character)
	return if Root then Root.CFrame else Character:GetPivot()
end

-- Emits the effects in a spawned VFX. If the game has VFX Forge's emitter (shared.vfx), it's used,
-- just as it is in Moon Animator. Otherwise ParticleEmitters use their EmitCount, EmitDelay and
-- EmitDuration attributes when they have them (Count, when given, is how many particles each gives
-- off instead), and Sounds play. An animation that names an Emitter is emitted with that instead
-- (see Sequence.Emitter). To use another emitter everywhere: Sequence.Emit = yourEmit
function module.Emit(Object, Count)
	local Forge = shared and shared.vfx
	if type(Forge) == "table" and type(Forge.emit) == "function" then
		Forge.emit(Object)
		return
	end

	local Items = Object:GetDescendants()
	table.insert(Items, Object)

	for _, Item in Items do
		if Item:IsA("ParticleEmitter") then
			local Particles = Count or tonumber(Item:GetAttribute("EmitCount")) or math.max(1, math.round(Item.Rate))
			local Delay = tonumber(Item:GetAttribute("EmitDelay")) or 0
			local Duration = tonumber(Item:GetAttribute("EmitDuration"))

			task.delay(Delay, function()
				if Duration then
					Item.Enabled = true
					task.delay(Duration, function()
						Item.Enabled = false
					end)
				else
					Item:Emit(Particles)
				end
			end)
		elseif Item:IsA("Sound") then
			Item:Play()
		end
	end
end

-- The emitters animations name, once found: name -> function(object).
local Emitters = {}

-- An emitter by its name: a module's emit method, as "ReplicatedStorage.Utilities.VFX:Emit" (the
-- ModuleScript from a service down, then : or . and the method, called the way the animation's
-- events called it). The module is required once, the first time, not cloned. Returns a function
-- that emits an object with it, or nil and why it can't be found.
function module.Emitter(Name)
	local Emitter = Emitters[Name]
	if Emitter then
		return Emitter
	end

	local Path, Separator, Method = string.match(Name, "^(.+)([:.])([%a_][%w_]*)$")
	if not Path then
		return nil, `it isn't a module and a method, like "ReplicatedStorage.Utilities.VFX:Emit"`
	end
	local Node = nil
	for Step in string.gmatch(Path, "[^%.]+") do
		if Node == nil then
			local Ok, Service = pcall(game.GetService, game, Step)
			Node = if Ok then Service else nil
		else
			Node = Node:FindFirstChild(Step)
		end
		if not Node then
			break
		end
	end
	if not (Node and Node:IsA("ModuleScript")) then
		return nil, `there's no ModuleScript at {Path}`
	end
	local Ok, Loaded = pcall(require, Node)
	if not Ok then
		return nil, `requiring {Path} failed: {Loaded}`
	end
	if type(Loaded) ~= "table" or type(Loaded[Method]) ~= "function" then
		return nil, `{Path} has no {Method} function`
	end

	Emitter = if Separator == ":"
		then function(Object)
			return Loaded[Method](Loaded, Object)
		end
		else function(Object)
			return Loaded[Method](Object)
		end
	Emitters[Name] = Emitter
	return Emitter
end

-- Sequences ------------------------------------------------------------------------------------

local Class = {}
Class.__index = Class

-- The helper that plays a cue's Keys on its Target.
local TargetEffects = {
	Lighting = "LightingEffect",
	Camera = "CameraEffect",
}

-- A cue's VFX from the table (or Folder) given to Play.
local function TemplateFor(VFX, Name)
	if typeof(VFX) == "Instance" then
		return VFX:FindFirstChild(Name)
	end
	local Template = VFX[Name]
	return if typeof(Template) == "Instance" then Template else nil
end

local function CopyOf(Template)
	local Archivable = Template.Archivable
	Template.Archivable = true
	local Ok, Copy = pcall(Template.Clone, Template)
	Template.Archivable = Archivable
	return if Ok then Copy else nil
end

-- Whether a cue spawns a VFX: it has an Offset (or names its Object), and isn't a subtitle, or a
-- screen, Lighting or camera effect.
local function HasVFX(Cue)
	return not Cue.Screen and not Cue.Target and not Cue.Subtitle and (Cue.Offset ~= nil or Cue.Object ~= nil)
end

-- Images already loaded, or loading.
local Preloaded = {}

-- Loads the images an animation shows ahead of time, so an ImageLabel shows its image the moment
-- its cue fires instead of a moment later: screen effects' Image (and Image keys), and the
-- ImageLabels and ImageButtons in the VFX (optional; the table or Folder given to Play). Doesn't
-- wait for them, and loads each image once. Sequence.new and Play call this; call it yourself to
-- load them earlier, when the character spawns, say.
function module.Preload(Animation, VFX)
	local Images = {}
	local function Add(Image)
		if type(Image) == "string" and Image ~= "" and not Preloaded[Image] then
			Preloaded[Image] = true
			table.insert(Images, Image)
		end
	end

	for _, Cue in Animation.Cues or {} do
		if Cue.Screen then
			-- Its image, its pieces' images (Moon's vignette is four), and images it's keyed to.
			local function AddPiece(Properties, Children)
				if type(Properties) == "table" then
					Add(Properties.Image)
				end
				for _, Child in Children or {} do
					AddPiece(Child.Properties, Child.Children)
				end
			end
			AddPiece(Cue.Properties, Cue.Children)
			for _, Key in Cue.Keys and Cue.Keys.Image or {} do
				Add(Key[2])
			end
		elseif type(Cue.Subtitle) == "table" then
			-- The speaker's portrait, and portraits it changes to.
			local Styles = { Cue.Subtitle.Style }
			for _, Key in Cue.Subtitle.Keys or {} do
				table.insert(Styles, Key[2])
			end
			for _, Style in Styles do
				if type(Style) == "table" and type(Style.Image) == "string" and Style.Image ~= "" then
					Add("rbxassetid://" .. Style.Image)
				end
			end
		elseif VFX and HasVFX(Cue) then
			local Name = Cue.Object or Cue.Effect
			local Template = if type(Name) == "string" then TemplateFor(VFX, Name) else nil
			if Template then
				local Items = Template:GetDescendants()
				table.insert(Items, Template)
				for _, Item in Items do
					if Item:IsA("ImageLabel") or Item:IsA("ImageButton") then
						Add(Item.Image)
					end
				end
			end
		end
	end

	if #Images > 0 then
		task.spawn(function()
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync(Images)
			end)
		end)
	end
end

function module.new(Animation, Character, FrameRate, Tolerance)
	if type(Animation) ~= "table" or type(Animation.Cues) ~= "table" then
		error(`Sequence.new needs an exported animation (a table with Cues), got {typeof(Animation)}`, 2)
	end
	if typeof(Character) ~= "Instance" then
		error(`Sequence.new needs the character that plays it, got {typeof(Character)}`, 2)
	end

	-- The table leaves FrameRate out when its cue keys are in seconds.
	FrameRate = FrameRate or Animation.FrameRate or 1
	Tolerance = Tolerance or Animation.CueTolerance or math.huge
	if type(FrameRate) ~= "number" or FrameRate <= 0 then
		error(`Sequence FrameRate must be a number above 0, got {FrameRate}`, 2)
	end
	if type(Tolerance) ~= "number" or Tolerance < 0 then
		error(`Sequence Tolerance must be a number of seconds (0 or more), got {Tolerance}`, 2)
	end
	for Frame, Cue in Animation.Cues do
		if type(Frame) ~= "number" then
			error(`Sequence cue keys must be frame numbers, got {typeof(Frame)} "{Frame}"`, 2)
		end
		if type(Cue) ~= "table" then
			error(`Sequence cue at frame {Frame} must be a table, got {typeof(Cue)}`, 2)
		end
	end

	local self = setmetatable({}, Class)
	self.Animation = Animation
	self.Character = Character
	self.FrameRate = FrameRate
	self.Tolerance = Tolerance
	self.Lifetime = Animation.Lifetime or 5
	self.Active = false
	self._Connection = nil
	self._Cleanups = {}
	self._Warned = {}
	module.Preload(Animation)
	return self
end

function Class:_WarnOnce(Key, Message)
	if not self._Warned[Key] then
		self._Warned[Key] = true
		warn(Message)
	end
end

-- Remembers something to undo when the sequence stops. Returns the undo, which can also run sooner
-- (it only ever runs once).
function Class:_Track(Undo)
	local Cleanups = self._Cleanups
	local Ran = false
	local function Run()
		if Ran then
			return
		end
		Ran = true
		local Index = table.find(Cleanups, Run)
		if Index then
			table.remove(Cleanups, Index)
		end
		Undo()
	end
	table.insert(Cleanups, Run)
	return Run
end

-- Plays the cues: in time with Track if there is one, otherwise by the clock from now. Data goes to
-- every cue's Function; VFX holds the objects the cues use, by name (see the top of this module).
function Class:Play(Track, Data, VFX)
	if OnServer("Play") then
		return
	end
	if type(VFX) ~= "table" and typeof(VFX) ~= "Instance" then
		error(`Sequence:Play needs the VFX the cues use as its third argument, \{ [Name] = Instance }, got {typeof(VFX)}`, 2)
	end

	if typeof(Track) ~= "Instance" and type(Track) == "table" then
		Track = Track.AnimationTrack
		if Track == nil then
			warn("Sequence:Play's track must be an AnimationTrack (or a table with one in .AnimationTrack), or nil to play by the clock")
			return
		end
	end
	if Track ~= nil and (typeof(Track) ~= "Instance" or not Track:IsA("AnimationTrack")) then
		warn(`Sequence:Play's track must be an AnimationTrack, or nil to play by the clock; got {typeof(Track)}`)
		return
	end

	self:Stop()
	self.Track = Track
	self.Data = Data
	self.VFX = VFX
	self._Warned = {}
	module.Preload(self.Animation, VFX)

	local Cues = self.Animation.Cues

	-- Say once which VFX the cues need that weren't given.
	local Missing = {}
	for _, Cue in Cues do
		local Name = Cue.Object or Cue.Effect
		if HasVFX(Cue) and type(Name) == "string" and not TemplateFor(VFX, Name) and not table.find(Missing, Name) then
			table.insert(Missing, Name)
			self._Warned["VFX " .. Name] = true
		end
	end
	if #Missing > 0 then
		table.sort(Missing)
		warn(`[Sequence] No VFX given for "{table.concat(Missing, `", "`)}". Pass {if #Missing == 1 then "it" else "them"} in sequence:Play's VFX table, by name.`)
	end

	-- Read the cues now so changes to them after new() are picked up.
	local Frames = {}
	for Frame in Cues do
		table.insert(Frames, Frame)
	end
	table.sort(Frames)

	local FrameRate = self.FrameRate
	local Late = self.Tolerance * FrameRate
	local Index = 1
	local Clock = 0
	local Previous = if Track then Track.TimePosition * FrameRate else 0

	-- Fires every cue up to frame UpTo. A cue counts as late only if it was due before the previous
	-- check.
	local function RunDue(UpTo)
		while Frames[Index] and Frames[Index] <= UpTo do
			local Frame = Frames[Index]
			Index += 1

			local Cue = Cues[Frame]
			if Cue and Frame >= Previous - Late then
				task.spawn(self.Spawn, self, Cue, Data, VFX)
			end
		end
	end

	self.Active = true
	self._Connection = RunService.Heartbeat:Connect(function(DeltaTime)
		if not Track then
			Clock += DeltaTime
			local Current = Clock * FrameRate
			RunDue(Current)
			Previous = Current
			if not Frames[Index] then
				self:_StopCues()
			end
			return
		end

		local Current = Track.TimePosition * FrameRate

		if not Track.IsPlaying then
			-- Cues due between the last check and the moment the track ended still play.
			if Current >= Previous then
				RunDue(Current)
			end
			self:_StopCues()
			return
		end

		if Current < Previous then
			if Track.Looped then
				-- Wrapped around: finish the cues that were due before the end, then start over.
				RunDue(Track.Length * FrameRate)
				Index = 1
				Previous = 0
			else
				-- Rewound: cues from the new position onwards can play again.
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
			self:_StopCues()
		end
	end)
end

-- No more cues fire; what's already out finishes on its own.
function Class:_StopCues()
	if self._Connection then
		self._Connection:Disconnect()
		self._Connection = nil
	end
	self.Active = false
end

-- Cancels the cues still to come and removes everything the sequence spawned.
function Class:Stop()
	self:_StopCues()

	-- Newest first, so Lighting and the camera end up as they were before the first change.
	local Cleanups = self._Cleanups
	self._Cleanups = {}
	for Index = #Cleanups, 1, -1 do
		local Undo = Cleanups[Index]
		if Undo then
			Undo()
		end
	end
end

function Class:Destroy()
	self:Stop()
end

-- Destroys an Instance, disconnects a connection, calls a function, cancels a thread (one from
-- task.delay, say), or calls a table's Destroy or Disconnect.
local function CleanUp(Thing)
	local Kind = typeof(Thing)
	if Kind == "Instance" then
		Thing:Destroy()
	elseif Kind == "RBXScriptConnection" then
		Thing:Disconnect()
	elseif Kind == "function" then
		Thing()
	elseif Kind == "thread" then
		task.cancel(Thing)
	elseif Kind == "table" then
		if type(Thing.Destroy) == "function" then
			Thing:Destroy()
		elseif type(Thing.Disconnect) == "function" then
			Thing:Disconnect()
		end
	end
end

-- Has the sequence clean up Thing (something a cue's Function made) like its VFX: when it stops, or
-- after Lifetime seconds (the animation's Lifetime if not given; math.huge waits for the stop).
-- Returns Thing.
function Class:AddToCleaner(Thing, Lifetime)
	Spawned(Thing)
	local Remove = self:_Track(function()
		pcall(CleanUp, Thing)
	end)
	Lifetime = Lifetime or self.Lifetime
	if Lifetime ~= math.huge then
		task.delay(Lifetime, Remove)
	end
	return Thing
end

-- Places a copy of Template for Cue on Character, emits it and plays its Keys. It's removed after
-- its Lifetime, or when the sequence stops.
function Class:_Place(Template, Cue, Character)
	local Root = RootOf(Character)
	if not Root then
		self:_WarnOnce("Root " .. Character:GetFullName(), `[Sequence] {Character:GetFullName()} has no HumanoidRootPart, so its VFX can't be placed`)
		return nil
	end

	local AnchorCFrame, AnchorPart, Follow = Root.CFrame, Root, false
	local Camera = if Cue.Parent == "Camera" then workspace.CurrentCamera else nil
	-- In front of the camera, it's a screen effect: only the player whose character played it sees it.
	if Cue.Parent == "Camera" and not ShowsHere(Character) then
		return nil
	end
	if Camera then
		AnchorCFrame = Camera.CFrame
	elseif Cue.Parent then
		local Found = Character:FindFirstChild(Cue.Parent, true)
		if Found and Found:IsA("BasePart") then
			AnchorCFrame, AnchorPart, Follow = Found.CFrame, Found, true
		elseif Found and Found:IsA("Attachment") and Found.Parent and Found.Parent:IsA("BasePart") then
			AnchorCFrame, AnchorPart, Follow = Found.WorldCFrame, Found.Parent, true
		else
			self:_WarnOnce(`Parent {Character:GetFullName()} {Cue.Parent}`, `[Sequence] {Character:GetFullName()} has no part or attachment named "{Cue.Parent}"; using the HumanoidRootPart`)
		end
	end

	local Effect = CopyOf(Template)
	if not Effect then
		return nil
	end
	Spawned(Effect)
	local Offset = Cue.Offset or CFrame.new()
	local Where = AnchorCFrame * Offset
	local Connections = {}

	if Effect:IsA("Attachment") then
		-- An attachment lives on a part, so it goes on the one it's measured from.
		Effect.Parent = AnchorPart
		Effect.WorldCFrame = Where
	elseif not (Effect:IsA("BasePart") or Effect:IsA("Model")) then
		-- A Highlight, emitter, light or sound goes on what it's for: a Highlight on the whole
		-- character (or its Parent), anything else on the part it's measured from.
		Effect.Parent = if Effect:IsA("Highlight") and not Follow then Character else AnchorPart
	else
		if Effect:IsA("Model") then
			Effect:PivotTo(Where)
		else
			Effect.CFrame = Where
		end
		Effect.Parent = workspace

		if Camera then
			-- A camera effect stays where it is in front of the camera.
			local IsModel = Effect:IsA("Model")
			table.insert(Connections, RunService.RenderStepped:Connect(function()
				local InFront = Camera.CFrame * Offset
				if IsModel then
					Effect:PivotTo(InFront)
				else
					Effect.CFrame = InFront
				end
			end))
		elseif Follow then
			local Parts = Effect:GetDescendants()
			table.insert(Parts, Effect)
			for _, Part in Parts do
				if Part:IsA("BasePart") then
					local Weld = Instance.new("WeldConstraint")
					Weld.Part0 = AnchorPart
					Weld.Part1 = Part
					Weld.Parent = Part
					Part.Anchored = false
					Part.Massless = true
				end
			end
		end
	end

	-- Emitted with the emitter the cue or its animation names (a module of the game's, see
	-- Sequence.Emitter), else with Sequence.Emit. Emitter = false leaves it to the cue's Function.
	local Emitter = Cue.Emitter
	if Emitter == nil then
		Emitter = self.Animation.Emitter
	end
	if Emitter ~= false then
		local Emit = nil
		if type(Emitter) == "string" then
			local Problem
			Emit, Problem = module.Emitter(Emitter)
			if not Emit then
				self:_WarnOnce("Emitter " .. Emitter, `[Sequence] Can't emit with "{Emitter}" ({Problem}), so VFX are emitted with Sequence.Emit instead.`)
			end
		elseif type(Emitter) == "function" then
			Emit = Emitter
		end
		if Emit then
			local Ok, Problem = pcall(Emit, Effect)
			if not Ok then
				self:_WarnOnce("Emit " .. Effect.Name, `[Sequence] Emitting "{Effect.Name}" didn't work, so it's shown without emitting: {Problem}`)
			end
		else
			module.Emit(Effect, Cue.EmitCount)
		end
	end

	local StopKeys = nil
	if Cue.Keys then
		_, StopKeys = module.Animate(Effect, Cue.Keys, { Path = Cue.Path, Origin = AnchorCFrame })
	end

	local Remove = self:_Track(function()
		for _, Connection in Connections do
			Connection:Disconnect()
		end
		if StopKeys then
			StopKeys()
		end
		Effect:Destroy()
	end)
	task.delay(Cue.Lifetime or math.max(self.Lifetime, KeysLength(Cue.Keys)), Remove)
	return Effect
end

-- Fires one cue now: its VFX (copied from VFX), or its screen, Lighting or camera effect, then its
-- Function. Play calls this as each cue comes due; it's here to fire one by hand too. Data and VFX
-- default to what was given to Play. Returns the spawned VFX or screen effect, if any.
function Class:Spawn(Cue, Data, VFX)
	if OnServer("Spawn") then
		return nil
	end
	if Data == nil then
		Data = self.Data
	end
	VFX = VFX or self.VFX or {}

	-- A cue from another rig in Moon plays on the character given for it.
	local Character = self.Character
	if Cue.Rig then
		local Other = type(Data) == "table" and type(Data.Rigs) == "table" and Data.Rigs[Cue.Rig] or nil
		if typeof(Other) ~= "Instance" then
			self:_WarnOnce("Rig " .. Cue.Rig, `[Sequence] Some cues are for "{Cue.Rig}". Pass its character to play them: sequence:Play(track, \{ Rigs = \{ ["{Cue.Rig}"] = victim } }, vfx)`)
			return nil
		end
		Character = Other
	end

	local Effect = nil
	if Cue.Subtitle then
		local Frame, Remove = module.Subtitle(Character, Cue.Subtitle)
		if Remove then
			self:_Track(Remove)
		end
		Effect = Frame
	elseif Cue.Screen then
		local Object, Remove = module.ScreenEffect(Character, Cue.Screen, Cue.Properties, Cue.Keys, Cue.Hold, Cue.Children, Cue.Path, { ScaleText = Cue.ScaleText })
		if Remove then
			self:_Track(Remove)
		end
		Effect = Object
	elseif Cue.Target then
		local Helper = TargetEffects[Cue.Target]
		local PutBack
		if Cue.Target == "Shake" then
			_, PutBack = module.CameraShake(Character, Cue.Keys or {}, Cue.Hold, Cue.Seed, Cue.Phase)
		elseif Helper then
			_, PutBack = module[Helper](Character, Cue.Keys or {}, Cue.Hold)
		else
			self:_WarnOnce("Target " .. tostring(Cue.Target), `[Sequence] Unknown Target "{Cue.Target}"; it can be "Lighting", "Camera" or "Shake"`)
		end
		if PutBack then
			self:_Track(PutBack)
		end
	elseif HasVFX(Cue) then
		local Name = Cue.Object or Cue.Effect
		local Template = if type(Name) == "string" then TemplateFor(VFX, Name) else nil
		if Template then
			Effect = self:_Place(Template, Cue, Character)
		else
			self:_WarnOnce("VFX " .. tostring(Name), `[Sequence] No VFX given for "{Name}". Pass it in sequence:Play's VFX table, by name.`)
		end
	end

	-- A Function that fails (code that isn't supported in game, say) is a warning, and the other cues
	-- carry on.
	if Cue.Function then
		local Ran, Problem = pcall(Cue.Function, self, Effect, Character, Cue, Data)
		if not Ran then
			local Key = "?"
			for Frame, Other in self.Animation.Cues do
				if Other == Cue then
					Key = tostring(Frame)
				end
			end
			warn(`[Sequence] The Function of cue [{Key}] "{Cue.Effect}" didn't work, so it was skipped: {Problem}`)
		end
	end
	return Effect
end

return module
