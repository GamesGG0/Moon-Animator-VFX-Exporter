--!strict
-- Moon VFX Exporter
-- Created by Games.GG
--
-- Turns the events in a Moon Animator 2 file into a table of VFX cues:
--   [frame] = { Effect = "Name", Offset = <effect CFrame relative to the HumanoidRootPart> }
-- exported as a ModuleScript that can play them, with a Sequence module and the VFX objects inside.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")
local CoreGui = game:GetService("CoreGui")

local Carryover = require(script.Carryover)
local Exporter = require(script.Exporter)
local Formatter = require(script.Formatter)
local MoonHook = require(script.MoonHook)
local Packager = require(script.Packager)
local SaveReader = require(script.SaveReader)
local Widget = require(script.Widget)

local SEQUENCE_TEMPLATE = script.Templates.Sequence
-- The Sequence version exports are written for: Sequence.new(animation, character), with
-- :Play(track, data, vfx) playing the cues' Keys, Screen and Target fields itself, and calling
-- Functions as Function(sequence, effect, character, cue, data).
local SEQUENCE_VERSION = 8

-- A Sequence module's version, from its `module.Version = n` line (versions before 2 had none).
local function sequenceVersion(source: string): number
	return tonumber(string.match(source, "module%.Version%s*=%s*(%d+)")) or 1
end

local plugin = plugin :: Plugin

local EXPORT_FOLDER = "MoonVFXExports"
local DEFAULT_TOLERANCE = 0.15
local DEFAULT_TABLE_NAME = "MoonAnimation"

local PLACEMENT_OPTIONS = {
	{ Value = "Auto", Label = "Next to Moon's Options button" },
	{ Value = "TopRight", Label = "Top right of Moon's window" },
	{ Value = "TopLeft", Label = "Top left of Moon's window" },
	{ Value = "BottomRight", Label = "Bottom right of Moon's window" },
	{ Value = "BottomLeft", Label = "Bottom left of Moon's window" },
	{ Value = "Hidden", Label = "Hidden" },
}
local EFFECT_OPTIONS = {
	{ Value = "Event", Label = "Event name (else part name)" },
	{ Value = "Item", Label = "Part name" },
}
local KEY_OPTIONS = {
	{ Value = "Frame", Label = "Frame numbers  [27]" },
	{ Value = "Time", Label = "Timestamps in seconds  [0.45]" },
}
-- "Auto" keeps the Moon file's FPS unless the export needs more precision.
local FPS_OPTIONS = {
	{ Value = "Auto", Label = "Auto (raised when needed for precision)" },
	{ Value = 30, Label = "30 fps" },
	{ Value = 60, Label = "60 fps" },
	{ Value = 120, Label = "120 fps" },
	{ Value = 240, Label = "240 fps" },
}

local function setting(key: string, default: any): any
	local ok, value = pcall(plugin.GetSetting, plugin, key)
	if ok and value ~= nil then
		return value
	end
	return default
end

local state = {
	Saves = {} :: { SaveReader.SaveEntry },
	Selected = nil :: SaveReader.SaveEntry?,
	Origin = nil :: BasePart?,
	Target = nil :: Instance?,
	EffectName = setting("EffectName", "Event") :: string,
	KeyFormat = setting("KeyFormat", "Frame") :: string,
	Placement = setting("MoonButtonPlacement", "Auto") :: string,
	ExportFps = setting("ExportFps", "Auto") :: string | number,
}

local toolbar = plugin:CreateToolbar("Moon VFX Exporter")
local toolbarButton = toolbar:CreateButton(
	"MoonVFXExporter",
	"Turn Moon Animator events into VFX offset cues",
	"",
	"VFX Exporter"
)
toolbarButton.ClickableWhenViewportHidden = true

local dock = plugin:CreateDockWidgetPluginGui(
	"MoonVFXExporter",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 400, 700, 320, 420)
)
dock.Name = "MoonVFXExporter"
dock.Title = "Moon VFX Exporter"

local ui = Widget.new(dock)
ui.CueTolerance.Text = tostring(setting("CueTolerance", DEFAULT_TOLERANCE))
ui.Selects.EffectName:SetOptions(EFFECT_OPTIONS)
ui.Selects.KeyFormat:SetOptions(KEY_OPTIONS)
ui.Selects.ExportFps:SetOptions(FPS_OPTIONS)
ui.Selects.Placement:SetOptions(PLACEMENT_OPTIONS)

local function round2(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

local function describeInstance(inst: Instance?, fallback: string): string
	if inst and inst.Parent then
		return inst:GetFullName()
	end
	return fallback
end

local function refreshLabels()
	ui.Selects.EffectName:Set(state.EffectName)
	ui.Selects.KeyFormat:Set(state.KeyFormat)
	ui.Selects.ExportFps:Set(state.ExportFps)
	ui.Selects.Placement:Set(state.Placement)
	ui.OriginLabel.Text = describeInstance(state.Origin, "Auto: the rig's HumanoidRootPart")
	ui.TargetLabel.Text = describeInstance(state.Target, "Auto: the item each event is on")
end

local function selectSave(entry: SaveReader.SaveEntry?)
	state.Selected = entry
	ui:SetSaves(state.Saves, entry)

	if entry then
		local seconds = if entry.FPS > 0 then entry.Length / entry.FPS else 0
		ui.TableName.PlaceholderText = DEFAULT_TABLE_NAME
		ui.Lifetime.PlaceholderText = `{round2(seconds)} (animation length)`
		ui.SaveInfo.Text = `{entry.Length} frames at {entry.FPS} fps  ·  {entry.Save:GetFullName()}`
	else
		ui.TableName.PlaceholderText = ""
		ui.Lifetime.PlaceholderText = ""
		ui.SaveInfo.Text = ""
	end
end

local function refreshSaves()
	local ok, saves = pcall(SaveReader.findSaves)
	state.Saves = if ok then saves else {}

	local keep = nil
	if state.Selected then
		for _, entry in state.Saves do
			if entry.Save == state.Selected.Save then
				keep = entry
				break
			end
		end
	end
	selectSave(keep)
end

local function selectOpenSave(): SaveReader.SaveEntry?
	local entry, how = MoonHook.detectOpenSave(state.Saves)
	selectSave(entry)
	if entry then
		ui:SetStatus(`Selected "{entry.Name}" ({how}).`, "info")
	else
		ui:SetStatus("No Moon Animator 2 saves found. Save your animation in Moon first.", "warn")
	end
	return entry
end

-- Writes the exported module along with what its code requires: the Sequence module (kept if it's
-- already there, in case it was edited) and a fresh copy of the VFX objects.
local function writeModule(name: string, source: string, cues: { Exporter.Cue }): (ModuleScript, number, boolean)
	local recording = ChangeHistoryService:TryBeginRecording("Export Moon VFX cues")

	local folder = ServerStorage:FindFirstChild(EXPORT_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = EXPORT_FOLDER
		folder.Parent = ServerStorage
	end

	local existing = (folder :: Instance):FindFirstChild(name)
	local module: ModuleScript
	if existing and existing:IsA("ModuleScript") then
		module = existing
		local ok = pcall(function()
			ScriptEditorService:UpdateSourceAsync(module, function()
				return source
			end)
		end)
		if not ok then
			module.Source = source
		end
	else
		module = Instance.new("ModuleScript")
		module.Name = name
		module.Source = source
		module.Parent = folder
	end

	-- The cues are played by the Sequence module; one from an older export can't play them, so it's
	-- replaced.
	local sequence = module:FindFirstChild("Sequence")
	local updatedSequence = false
	if sequence and sequence:IsA("ModuleScript") and sequenceVersion(sequence.Source) < SEQUENCE_VERSION then
		sequence:Destroy()
		sequence = nil
		updatedSequence = true
	end
	if not sequence then
		SEQUENCE_TEMPLATE:Clone().Parent = module
	end

	local oldAssets = module:FindFirstChild("VFX")
	if oldAssets then
		oldAssets:Destroy()
	end
	local assets, packed = Packager.build(cues)
	assets.Parent = module

	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end

	return module, packed, updatedSequence
end

-- Exports the selected file. Returns the module and the animation read from the file, or nil if
-- there was nothing to export.
local function export(openScript: boolean): (ModuleScript?, any)
	local entry = state.Selected
	if not entry then
		ui:SetStatus("Pick an animation file first.", "error")
		return nil
	end

	local loaded, anim = pcall(SaveReader.load, entry.Save)
	if not loaded then
		ui:SetStatus(`Couldn't read "{entry.Name}": {anim}`, "error")
		return nil
	end

	local result = Exporter.collect(anim, {
		EffectName = state.EffectName,
		Origin = if state.Origin and state.Origin.Parent then state.Origin else nil,
		Target = if state.Target and state.Target.Parent then state.Target else nil,
		MoonEasing = MoonHook.getEasingFunctions(),
		FrameRate = if type(state.ExportFps) == "number" then state.ExportFps else nil,
	})

	if #result.Cues == 0 then
		ui:SetPreview("")
		ui:SetStatus(
			`No events found in "{entry.Name}". If you just added them, save in Moon (Ctrl+S) and export again. `
				.. "If they still don't show up, click Dump save and check the outline.",
			"warn"
		)
		return nil
	end

	local tableName = trim(ui.TableName.Text)
	tableName = Formatter.identifier(if tableName ~= "" then tableName else DEFAULT_TABLE_NAME)

	local seconds = if anim.FPS > 0 then anim.Length / anim.FPS else 0
	local lifetime = tonumber(ui.Lifetime.Text) or round2(seconds)
	local tolerance = tonumber(ui.CueTolerance.Text) or DEFAULT_TOLERANCE

	local timestamps = state.KeyFormat == "Time"

	-- Keep the Functions added to the last export of this file.
	local kept, orphans = 0, {}
	local exportFolder = ServerStorage:FindFirstChild(EXPORT_FOLDER)
	local previous = exportFolder and exportFolder:FindFirstChild(entry.Name)
	if previous and previous:IsA("ModuleScript") then
		local okSource, oldSource = pcall(function()
			return ScriptEditorService:GetEditorSource(previous)
		end)
		if not okSource or type(oldSource) ~= "string" then
			oldSource = previous.Source
		end

		local okFound, found = pcall(Carryover.extract, oldSource)
		if okFound then
			orphans = Carryover.apply(found, result.Cues, function(cue)
				return Formatter.key(cue.Frame, timestamps, result.FrameRate)
			end)
			kept = #found - #orphans
		end
	end
	local rate = result.FrameRate
	local keyKind = if timestamps then "times in seconds" else `frames at {rate} fps`
	if result.FrameRateReason and not timestamps then
		keyKind ..= ` ({result.FrameRateReason})`
	end
	local source, formatWarnings = Formatter.format({
		TableName = tableName,
		Lifetime = lifetime,
		CueTolerance = tolerance,
		Header = `Moon Animator file "{entry.Name}" ({anim.FPS} fps). Cue keys are {keyKind}.`,
		Timestamps = timestamps,
		FPS = rate,
		Runtime = true,
		Cues = result.Cues,
		Orphans = orphans,
	})

	local module, packed, updatedSequence = writeModule(entry.Name, source, result.Cues)
	ui:SetPreview(source)

	local flagged, objectless, screens, keyframed, adapted, rigNames = 0, 0, 0, 0, 0, {}
	for _, cue in result.Cues do
		if #cue.Notes > 0 then
			flagged += 1
		end
		if cue.Screen then
			screens += 1
		elseif cue.Animation then
			keyframed += 1
		elseif cue.Code and not cue.Function then
			if cue.Adapted then
				adapted += 1
			end
		elseif not cue.Object and not cue.Function and not cue.Code then
			objectless += 1
		end
		if cue.Rig and not table.find(rigNames, cue.Rig) then
			table.insert(rigNames, cue.Rig)
		end
	end

	local message = `Exported {#result.Cues} cues and {packed} VFX objects to {module:GetFullName()}.`
	if kept > 0 then
		message ..= ` Kept {kept} cue Function{if kept == 1 then "" else "s"} from the last export.`
	end
	if #orphans > 0 then
		message ..= ` {#orphans} Function{if #orphans == 1 then "'s cue is" else "s' cues are"} gone; kept in a comment at the end of the module.`
	end
	if result.FrameRateReason and not timestamps then
		message ..= ` Cue keys are at {rate} fps ({result.FrameRateReason}).`
	end
	if flagged > 0 then
		message ..= ` {flagged} cues have a comment to check.`
	end
	if screens > 0 then
		message ..= ` {screens} of them {if screens == 1 then "is a screen effect" else "are screen effects"}, which the Sequence module plays.`
	end
	if keyframed > 0 then
		message ..= ` {keyframed} {if keyframed == 1 then "is an effect" else "are effects"} Moon animates with keyframes (Highlights, lights, Lighting, the camera's field of view, moving parts); the Sequence module replays their keys.`
	end
	if adapted > 0 then
		message ..= ` {adapted} {if adapted == 1 then "event's" else "events'"} code from Moon was rewritten to run in game, in the cue's Function.`
	end
	if #rigNames > 0 then
		table.sort(rigNames)
		message ..= ` Some cues are on {table.concat(rigNames, ", ")}: pass {if #rigNames == 1 then "that character" else "those characters"} to Play, like sequence:Play(track, \{ Rigs = \{ ["{rigNames[1]}"] = victim } }, VFX).`
	end
	if updatedSequence then
		message ..= " Its Sequence module was replaced with the new one, which plays the cues: Sequence.new(module, character):Play(track, data, VFX)."
	end

	-- Left out: events on things that can't be spawned (Moon's Subtitles, the camera...), events on
	-- effects their keyframes already play, and parts moving on the camera.
	local skippedNames, skippedCount = {}, 0
	for name, count in result.Skipped do
		table.insert(skippedNames, if count > 1 then `{name} ×{count}` else name)
		skippedCount += count
	end
	if skippedCount > 0 then
		table.sort(skippedNames)
		message ..= ` Left out {table.concat(skippedNames, ", ")} (nothing to spawn, already played by keyframes, or moving on the camera).`
	end
	if objectless > 0 then
		message ..= ` {objectless} cues have no VFX object to spawn (events on the rig with no part named in their code).`
	end
	-- What couldn't be exported as it is (code that can't run in game, values it can't write...): a
	-- warning, here and in the Output, and the rest of the export goes ahead.
	local warnings = table.clone(result.Warnings)
	for _, warning in formatWarnings do
		table.insert(warnings, warning)
	end
	if #warnings > 0 then
		message ..= "\n" .. table.concat(warnings, "\n")
	end
	ui:SetStatus(message, if flagged > 0 or objectless > 0 or #orphans > 0 or #warnings > 0 then "warn" else "ok")

	print(`[Moon VFX Exporter] {message}`)
	for _, warning in warnings do
		warn(`[Moon VFX Exporter] {warning}`)
	end
	if openScript then
		plugin:OpenScript(module)
	end
	return module, anim
end

-- Exports, then asks where to save the module (with its Sequence and VFX objects) as an .rbxm.
local function saveRbxm()
	local module = export(false)
	if not module then
		return
	end

	-- The save dialog saves whatever is selected.
	local previous = Selection:Get()
	Selection:Set({ module })

	-- PromptSaveSelectionAsync replaced the deprecated PromptSaveSelection; older Studio builds
	-- only have the latter.
	local hasAsync = pcall(function()
		return (plugin :: any).PromptSaveSelectionAsync
	end)
	local method = if hasAsync then "PromptSaveSelectionAsync" else "PromptSaveSelection"
	local ok, saved = pcall(function()
		return (plugin :: any)[method](plugin, module.Name)
	end)

	local fallback = `You can also right-click {module.Name} in ServerStorage.MoonVFXExports and choose Save to File.`
	if not ok then
		-- Leave the module selected so Save to File is one right-click away.
		ui:SetStatus(`Couldn't open the save window: {saved}\n{fallback}`, "error")
		warn(`[Moon VFX Exporter] {method} failed: {saved}`)
	elseif saved then
		Selection:Set(previous)
		ui:SetStatus(
			`Saved "{module.Name}" as an .rbxm. Drop it into ReplicatedStorage and play it with its Sequence module: Sequence.new(require(it), character):Play(track, data, VFX).`,
			"ok"
		)
	else
		ui:SetStatus(`Not saved (the save window was closed). {fallback}`, "info")
	end
end

-- The preview playing, if any: its sequence, and the copy of the export it plays.
local previewing: { Sequence: any, Copy: Instance }? = nil

local function stopPreview()
	local current = previewing
	if not current then
		return
	end
	previewing = nil
	pcall(function()
		current.Sequence:Stop()
	end)
	current.Copy:Destroy()
	ui.Buttons.Preview.Text = "Preview"
end

-- Exports, then plays the export in Studio on the file's rig, so placements can be checked without
-- starting a game. It's what a game gets (the module, its VFX and its Sequence), played the same
-- way, by the clock: Moon's animation doesn't play along. Clicking again stops it.
local function preview()
	if previewing then
		stopPreview()
		ui:SetStatus("Preview stopped.", "info")
		return
	end

	local module, anim = export(false)
	if not module or not anim then
		return
	end

	-- The file's first rig plays it, and its other rigs are given in data.Rigs, as a game would.
	local rigs = Exporter.rigsOf(anim)
	local character = rigs[1]
	if not character then
		ui:SetStatus("There's no rig in this file to preview the VFX on.", "warn")
		return
	end
	local others = {}
	for i = 2, #rigs do
		others[rigs[i].Name] = rigs[i]
	end

	-- A copy, so require runs this export rather than an older one it has cached. It's not part of
	-- the place, and neither is anything the preview spawns, so saving mid-preview saves none of it.
	local copy = module:Clone()
	copy.Name = "MoonVFXPreview"
	copy.Archivable = false
	pcall(function()
		copy.Parent = CoreGui
	end)

	local loadedData, data = pcall(require, copy)
	local sequenceModule = copy:FindFirstChild("Sequence")
	local loadedSequence, Sequence = pcall(require, sequenceModule :: any)
	if not (loadedData and loadedSequence and type(data) == "table" and type(Sequence) == "table") then
		copy:Destroy()
		local problem = if not loadedData then data elseif not loadedSequence then Sequence else "it didn't return a table"
		ui:SetStatus(`Couldn't load the export to preview it: {problem}`, "error")
		return
	end

	Sequence.Preview = {
		GuiParent = CoreGui,
		Spawned = function(object: Instance)
			object.Archivable = false
		end,
	}
	local ok, sequence = pcall(function()
		local made = Sequence.new(data, character)
		made:Play(nil, { Rigs = others }, copy:FindFirstChild("VFX"))
		return made
	end)
	if not ok then
		copy:Destroy()
		ui:SetStatus(`Couldn't play the preview: {sequence}`, "error")
		return
	end

	local current = { Sequence = sequence, Copy = copy }
	previewing = current
	ui.Buttons.Preview.Text = "Stop preview"

	-- Over once the last cue has fired and its VFX are gone.
	local last = 0
	for frame in data.Cues do
		last = math.max(last, frame)
	end
	local seconds = last / (data.FrameRate or 1) + (data.Lifetime or 5) + 1
	task.delay(seconds, function()
		if previewing == current then
			stopPreview()
			ui:SetStatus("Preview finished.", "info")
		end
	end)

	local otherNames = {}
	for name in others do
		table.insert(otherNames, name)
	end
	ui:SetStatus(
		`Previewing on {character.Name}{if #otherNames > 0 then ` (with {table.concat(otherNames, ", ")} for its Rig cues)` else ""}. `
			.. "The VFX play by the clock from now, from where the rig stands; Moon's animation doesn't play along. "
			.. "Click Stop preview to end it. The export's details are in the Output.",
		"info"
	)
end

local function dump()
	local entry = state.Selected
	if not entry then
		ui:SetStatus("Pick an animation file first.", "error")
		return
	end

	local outline = SaveReader.dump(entry.Save)
	print(outline)
	ui:SetPreview(outline)
	ui:SetStatus("Save outline printed to the Output window.", "info")
end

local function pickFromSelection(): Instance?
	local selected = Selection:Get()
	return selected[1]
end

local hook = MoonHook.new(function()
	dock.Enabled = true
	refreshSaves()
	if selectOpenSave() then
		export(true)
	end
end)
hook:SetPlacement(state.Placement :: any)

ui.OnSaveSelected = function(entry)
	selectSave(entry)
	ui:SetStatus("", "info")
end

ui.Buttons.Refresh.MouseButton1Click:Connect(function()
	refreshSaves()
	ui:SetStatus(`Found {#state.Saves} Moon Animator save(s).`, "info")
end)

ui.Buttons.Detect.MouseButton1Click:Connect(function()
	refreshSaves()
	selectOpenSave()
end)

ui.Buttons.Export.MouseButton1Click:Connect(function()
	export(true)
end)
ui.Buttons.Preview.MouseButton1Click:Connect(preview)
ui.Buttons.SaveRbxm.MouseButton1Click:Connect(saveRbxm)
ui.Buttons.Dump.MouseButton1Click:Connect(dump)

ui.Selects.EffectName.OnChanged = function(value)
	state.EffectName = value
	plugin:SetSetting("EffectName", value)
end

ui.Selects.KeyFormat.OnChanged = function(value)
	state.KeyFormat = value
	plugin:SetSetting("KeyFormat", value)
end

ui.Selects.ExportFps.OnChanged = function(value)
	state.ExportFps = value
	plugin:SetSetting("ExportFps", value)
end

ui.Selects.Placement.OnChanged = function(value)
	state.Placement = value
	plugin:SetSetting("MoonButtonPlacement", value)
	hook:SetPlacement(value)
end

ui.Buttons.OriginSelect.MouseButton1Click:Connect(function()
	local picked = pickFromSelection()
	if picked and picked:IsA("Model") then
		local root = picked:FindFirstChild("HumanoidRootPart") or picked.PrimaryPart
		picked = if root and root:IsA("BasePart") then root else nil
	end

	if picked and picked:IsA("BasePart") then
		state.Origin = picked
		ui:SetStatus("", "info")
	else
		ui:SetStatus("Select the HumanoidRootPart (or its rig) in the Explorer first.", "error")
	end
	refreshLabels()
end)

ui.Buttons.OriginAuto.MouseButton1Click:Connect(function()
	state.Origin = nil
	refreshLabels()
end)

ui.Buttons.TargetSelect.MouseButton1Click:Connect(function()
	local picked = pickFromSelection()
	if picked and (picked:IsA("BasePart") or picked:IsA("Model") or picked:IsA("Attachment") or picked:IsA("Bone")) then
		state.Target = picked
		ui:SetStatus("Every event will be measured at this part.", "info")
	else
		ui:SetStatus("Select the part to measure at (e.g. your effect container) in the Explorer first.", "error")
	end
	refreshLabels()
end)

ui.Buttons.TargetAuto.MouseButton1Click:Connect(function()
	state.Target = nil
	refreshLabels()
end)

ui.CueTolerance.FocusLost:Connect(function()
	local value = tonumber(ui.CueTolerance.Text)
	if value then
		plugin:SetSetting("CueTolerance", value)
	else
		ui.CueTolerance.Text = tostring(setting("CueTolerance", DEFAULT_TOLERANCE))
	end
end)

toolbarButton.Click:Connect(function()
	dock.Enabled = not dock.Enabled
end)

dock:GetPropertyChangedSignal("Enabled"):Connect(function()
	toolbarButton:SetActive(dock.Enabled)
	if dock.Enabled then
		refreshSaves()
		if not state.Selected then
			selectOpenSave()
		end
	end
end)

plugin.Unloading:Connect(function()
	stopPreview()
	hook:Destroy()
	ui:Destroy()
end)

refreshLabels()
if dock.Enabled then
	toolbarButton:SetActive(true)
	refreshSaves()
end
