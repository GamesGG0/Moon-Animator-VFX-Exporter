# Moon VFX Exporter
# DOWNLOAD HERE: https://create.roblox.com/store/asset/88386490728445/Moon-VFX-Exporter

A Roblox Studio plugin that turns the events in a [Moon Animator 2](https://create.roblox.com/store/asset/4725618216) animation into ready-to-use VFX code. Created by Games.GG.

Instead of scrubbing to every VFX event and printing `HumanoidRootPart.CFrame:ToObjectSpace(part.CFrame)` by hand, the plugin reads the saved animation and writes the whole cue table for you:

```lua
local MoonAnimation = {
	Lifetime = 6,
	CueTolerance = 0.15,
	FrameRate = 60,

	Cues = {
		[0] =   { Effect = "Start",   Offset = CFrame.new(...) },
		[27] =  { Effect = "Hit",     Offset = CFrame.new(...) },
		[88] =  { Effect = "Barrage", Offset = CFrame.new(...) },
	},
}
```

## Features

- Finds every event in a Moon Animator 2 file and calculates each effect's offset from the HumanoidRootPart, straight from the keyframes (easing, rig joints and rig movement included), so it doesn't matter where Moon's playhead was left.
- Effects connected to a body part get a `Parent`, such as `Parent = "Right Arm"`. They spawn at that part and are welded to it. It's set automatically for effects attached or welded to a limb, or you can add a `Parent` key in Moon's Edit Events → **Events** tab.
- Exports a self-contained ModuleScript with `Play(character, track)`, a `Sequence` module that keeps the VFX in time with the animation, and a `VFX` folder holding copies of the effect objects.
- **Save .rbxm** saves that module as one file you can drop into any place.
- Adds an **Export VFX** button next to Moon Animator's Options button.
- Frame-number or timestamp keys, with the export frame rate raised automatically when events need more precision.

## Using it

1. Save your animation in Moon Animator (Ctrl+S). The plugin reads the saved copy.
2. Click **Export VFX** in Moon Animator, or open **VFX Exporter** from the Plugins tab and click **Export cues**.
3. The module appears in `ServerStorage.MoonVFXExports`. Move it to ReplicatedStorage and, on the client:

```lua
local MoonAnimation = require(ReplicatedStorage.MoonAnimation)

track:Play()
MoonAnimation.Play(character, track)
```

> Tip: Animations, VFX, SFX, or anything visual should stay on the client, NEVER on the server.

## Building from source

Requires [Rojo](https://rojo.space) 7.

```bash
rojo build --plugin MoonVFXExporter.rbxmx
```

This installs the plugin straight into your Studio plugins folder. Use `rojo build -o build/MoonVFXExporter.rbxmx` to build a file instead.

## Tests

The plugin's logic (save reading, easing, offsets, formatting, the Sequence module, and the generated code) is tested outside Studio with the [Luau](https://luau.org) CLI and Python 3:

```bash
python tests/run.py
```

## Notes

- The **Export VFX** button inside Moon Animator and the "Use file open in Moon" detection rely on Moon Animator's internal, undocumented API (`_G.MoonGlobal`), so a Moon update could break them. Everything else only reads Moon's save files.
- Moon's save format was worked out with help from [Moonlite](https://github.com/MaximumADHD/Moonlite) by MaximumADHD.
