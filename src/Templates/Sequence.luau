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
		Parent    a part or attachment of the character to place it on and follow, or "Camera"
		Rig       the other rig it plays on, from data.Rigs
		Lifetime  seconds before its VFX is removed, instead of the animation's
		Keys      keyframes it plays: { Property = { { seconds, value, easingStyle, easingDirection } } }.
		          CFrame keys are offsets, like Offset. An Eclipse Bezier key's direction is its
		          curve's two control points: { seconds, value, "Bezier", { x1, y1, x2, y2 } }.
		EmitCount particles each of its ParticleEmitters gives off, instead of its own EmitCount
		Emitter   the emitter its VFX is emitted with, instead of the animation's (see
		          Sequence.Emitter); false when its Function emits it
		Path      names leading from its VFX to what its Keys animate, e.g. { "A1", "PointLight" }
		Screen    a screen effect to show instead of a VFX (a GUI class such as "ImageLabel", or a
		          post effect such as "BlurEffect"), set up with Properties and animated by Keys.
		          Its other pieces are in Children ({ Name, ClassName, Properties, Children,
		          Mirrors }): Moon's vignette is four images tiling the screen. Keys play on the
		          piece Path leads to (or the effect itself) and on the pieces that Mirror it.
		Target    "Lighting" or "Camera": its Keys play on that instead, held for Hold seconds, then
		          put back (a Screen is shown for its Hold seconds, too, when that's longer)
		Function  function(self, effect, character, cue, data), run when it fires, after its VFX
		          spawns. self is the sequence (for self:AddToCleaner), effect its VFX (or nil),
		          character the one it plays on, data what was given to Play. If it errors, that's a
		          warning, and the other cues still play.
	A cue with no Offset (and no Object) has no VFX: it's a screen, Lighting or camera effect, or just
	its Function.
]]

local RunService = game:GetService("RunService")

local module = {}

-- The Moon VFX Exporter replaces older versions of this module that it finds next to its exports.
module.Version = 11

-- VFX play only on the client. On the server, Play and Spawn warn and do nothing.
local function OnServer(Method)
	if RunService:IsClient() or module.Preview then
		return false
	end
	warn(`[Sequence] sequence:{Method} was called on the server, so nothing plays: VFX only play on the client. Call it from a LocalScript; to show a move to every player, have each client play it on that player's character.`)
	return true
end

-- Set by the Moon VFX Exporter's Preview button, which plays an export in Studio without a game:
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
-- ClassName, Properties, Children, Mirrors }) inside. Pieces that Mirror the keyed one go in Mirrors.
local function BuildPiece(ClassName, Properties, Children, Mirrors)
	local Made, Object = pcall(Instance.new, ClassName)
	if not Made then
		warn(`[Sequence] Can't show a screen effect of class "{ClassName}": {Object}`)
		return nil
	end
	for Property, Value in Properties or {} do
		pcall(SetProperty, Object, Property, Value)
	end
	for _, Child in Children or {} do
		local Piece = BuildPiece(Child.ClassName, Child.Properties, Child.Children, Mirrors)
		if Piece then
			Piece.Name = Child.Name or Piece.Name
			Piece.Parent = Object
			if Child.Mirrors then
				table.insert(Mirrors, Piece)
			end
		end
	end
	return Object
end

-- Shows one of Moon's screen effects: an overlay (vignette, flash...) in a ScreenGui, or a post
-- effect (blur, color correction...) on the camera. Properties is its look; Keys animate it from now.
-- An overlay Moon makes from several pieces (its vignette is four images) has them in Children, and
-- Keys play on the piece Path leads to (or the effect itself) and on the pieces that Mirror it, as
-- Moon copies its look onto them. It's removed once the last key is reached (or after Duration
-- seconds, if that's later). Returns it, and a function that removes it now; nothing if this
-- player doesn't see it.
function module.ScreenEffect(Character, ClassName, Properties, Keys, Duration, Children, Path)
	if not ShowsHere(Character) then
		return nil
	end
	local Players = game:GetService("Players")
	local Player = Players and Players.LocalPlayer

	local Mirrors = {}
	local Object = BuildPiece(ClassName, Properties, Children, Mirrors)
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
	local Length = math.max(Duration or 0, KeysLength(Keys))
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

-- Whether a cue spawns a VFX: it has an Offset (or names its Object), and isn't a screen, Lighting or
-- camera effect.
local function HasVFX(Cue)
	return not Cue.Screen and not Cue.Target and (Cue.Offset ~= nil or Cue.Object ~= nil)
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
	if Cue.Screen then
		local Object, Remove = module.ScreenEffect(Character, Cue.Screen, Cue.Properties, Cue.Keys, Cue.Hold, Cue.Children, Cue.Path)
		if Remove then
			self:_Track(Remove)
		end
		Effect = Object
	elseif Cue.Target then
		local Helper = TargetEffects[Cue.Target]
		local PutBack
		if Helper then
			_, PutBack = module[Helper](Character, Cue.Keys or {}, Cue.Hold)
		else
			self:_WarnOnce("Target " .. tostring(Cue.Target), `[Sequence] Unknown Target "{Cue.Target}"; it can be "Lighting" or "Camera"`)
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
