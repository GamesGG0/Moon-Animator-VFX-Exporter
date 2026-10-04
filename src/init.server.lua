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

local Exporter = require(script.Exporter)
local Formatter = require(script.Formatter)
local MoonHook = require(script.MoonHook)
local Packager = require(script.Packager)
local SaveReader = require(script.SaveReader)
local Widget = require(script.Widget)

local SEQUENCE_TEMPLATE = script.Templates.Sequence

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
local function writeModule(name: string, source: string, cues: { Exporter.Cue }): (ModuleScript, number)
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

	if not module:FindFirstChild("Sequence") then
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

	return module, packed
end

-- Exports the selected file. Returns the module, or nil if there was nothing to export.
local function export(openScript: boolean): ModuleScript?
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
	local rate = result.FrameRate
	local keyKind = if timestamps then "times in seconds" else `frames at {rate} fps`
	if result.FrameRateReason and not timestamps then
		keyKind ..= ` ({result.FrameRateReason})`
	end
	local source = Formatter.format({
		TableName = tableName,
		Lifetime = lifetime,
		CueTolerance = tolerance,
		Header = `Moon Animator file "{entry.Name}" ({anim.FPS} fps). Cue keys are {keyKind}.`,
		Timestamps = timestamps,
		FPS = rate,
		Runtime = true,
		Cues = result.Cues,
	})

	local module, packed = writeModule(entry.Name, source, result.Cues)
	ui:SetPreview(source)

	local flagged, objectless = 0, 0
	for _, cue in result.Cues do
		if #cue.Notes > 0 then
			flagged += 1
		end
		if not cue.Object then
			objectless += 1
		end
	end

	local message = `Exported {#result.Cues} cues and {packed} VFX objects to {module:GetFullName()}.`
	if result.FrameRateReason and not timestamps then
		message ..= ` Cue keys are at {rate} fps ({result.FrameRateReason}).`
	end
	if flagged > 0 then
		message ..= ` {flagged} cues have a comment to check.`
	end
	if objectless > 0 then
		message ..= ` {objectless} cues have no VFX object to spawn (events on the rig with no part named in their code).`
	end
	if #result.Warnings > 0 then
		message ..= "\n" .. table.concat(result.Warnings, "\n")
	end
	ui:SetStatus(message, if flagged > 0 or objectless > 0 or #result.Warnings > 0 then "warn" else "ok")

	print(`[Moon VFX Exporter] {message}`)
	if openScript then
		plugin:OpenScript(module)
	end
	return module
end

-- Exports, then asks where to save the module (with its Sequence and VFX objects) as an .rbxm.
local function saveRbxm()
	local module = export(false)
	if not module then
		return
	end

	local previous = Selection:Get()
	Selection:Set({ module })
	local ok, saved = pcall(plugin.PromptSaveSelection, plugin, module.Name)
	Selection:Set(previous)

	if not ok then
		ui:SetStatus(`Couldn't save the .rbxm: {saved}`, "error")
	elseif saved then
		ui:SetStatus(
			`Saved "{module.Name}" as an .rbxm. Drop it into ReplicatedStorage and call .Play(character, track).`,
			"ok"
		)
	else
		ui:SetStatus("Save cancelled. The export is still in ServerStorage.MoonVFXExports.", "info")
	end
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
	hook:Destroy()
	ui:Destroy()
end)

refreshLabels()
if dock.Enabled then
	toolbarButton:SetActive(true)
	refreshSaves()
end
