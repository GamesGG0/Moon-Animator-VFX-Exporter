# Moon VFX Exporter

A Roblox Studio plugin that turns the events in a [Moon Animator 2](https://create.roblox.com/store/asset/4725618216) animation into ready-to-use VFX code. Created by Games.GG.

## [Download on the Creator Store](https://create.roblox.com/store/asset/88386490728445/Moon-VFX-Exporter)

Instead of scrubbing to every VFX event and printing `HumanoidRootPart.CFrame:ToObjectSpace(part.CFrame)` by hand, the plugin reads the saved animation and writes the whole cue table for you, along with the code that plays it:

```lua
local MoonAnimation = {
	Lifetime = 6,
	CueTolerance = 0.15,
	FrameRate = 60,

	Cues = {
		[0] =   { Effect = "Start",                            Offset = CFrame.new(...) },
		[27] =  { Effect = "Hit",   Object = "ImpactAnti",     Offset = CFrame.new(...) },
		[84] =  { Effect = "Shine", Parent = "Right Arm",      Offset = CFrame.new(...) },
		[106] = { Effect = "Slash",                            Offset = CFrame.new(...), Function = function(effect, character, cue)
			-- your own code
		end },
	},
}
```

## Features

- **Exact offsets, straight from the save.** Each effect's CFrame and the HumanoidRootPart's are worked out from the keyframes: easing, rig joints and rig movement included. Where Moon's playhead was left doesn't matter.
- **Ready to play.** The export is a self-contained ModuleScript with `Play(character, track)`, a `Sequence` module that keeps the VFX in time with the animation, and a `VFX` folder holding copies of the effect objects.
- **Effects that follow a body part.** A cue can have a `Parent`, a part or attachment of the character. The effect spawns there and stays attached.
- **Your own code per cue.** An optional `Function` runs when a cue fires. It's kept when you export the animation again.
- **Attachments everywhere.** They work as VFX objects, as a `Parent`, and nested inside other attachments.
- **One-click file.** **Save .rbxm** saves the module, Sequence and VFX objects as one file you can drop into any place.
- **Built into Moon Animator.** An **Export VFX** button sits next to Moon's Options button.
- **Frame or time keys.** Cues are keyed by frame number or by time in seconds. The frame rate is raised automatically when events need more precision.

## Using it

1. In Moon Animator, add an event (Edit Events) on each VFX item at the frame it should fire, then save the file (Ctrl+S). The plugin reads the saved copy.
2. Click **Export VFX** in Moon Animator, or open **VFX Exporter** from the Plugins tab, pick the file and click **Export cues**.
3. The module appears in `ServerStorage.MoonVFXExports` and opens in the script editor. Move it to ReplicatedStorage and, on the client:

```lua
local MoonAnimation = require(ReplicatedStorage.MoonAnimation)

local track = animator:LoadAnimation(animation)
track:Play()
MoonAnimation.Play(character, track)
```

> **Tip:** Animations, VFX, SFX, or anything visual should stay on the client, NEVER on the server.
>
> **Tip:** Make sure to keep all of your VFX objects in a cleaner module and destroy them when done!

### The exporter window

| Setting | What it does |
| --- | --- |
| **Animation file** | The Moon save to export. **Use file open in Moon** picks the one Moon has open. Moon's autosaves aren't listed. |
| **Table name** | The variable name in the generated code. Defaults to `MoonAnimation`. |
| **Lifetime** | Seconds before a spawned effect is removed. Defaults to the animation's length. |
| **CueTolerance** | Seconds a cue may already be overdue when `Play` starts (e.g. partway through the animation) before it's skipped. |
| **Effect name** | Use the event's Name (falling back to the part's name), or always the part's name. |
| **Cue keys** | Frame numbers (`[27]`) or timestamps in seconds (`[0.45]`). |
| **Export FPS** | **Auto** keeps the file's frame rate unless events fall between frames or share a frame, then raises it. Or pick 30, 60, 120 or 240. |
| **Relative to** | What offsets are measured from. Defaults to the HumanoidRootPart of the first rig in the file. |
| **Measured at** | Measure every event at one part (such as a container part) instead of the item each event is on. |
| **Export button** | Where the **Export VFX** button goes in Moon Animator, or hide it. |

**Dump save** prints the selected file's structure to the Output window, which helps when something doesn't export the way you expect.

### Setting a Parent

A cue gets a `Parent` automatically when its VFX object is:

- on a part Moon animates through a joint (a limb or an animated weapon): that part, or
- an attachment on a limb, or a part welded to one: that limb.

To choose one yourself, open the event in Moon's **Edit Events** window, go to the **Events** tab, and add a key `Parent` whose value is a part or attachment name, such as `Right Arm` or `RightGripAttachment`. That wins over the automatic choice.

## The exported module

```
MoonAnimation (ModuleScript)  the cues and the code that plays them
├── Sequence (ModuleScript)   keeps callbacks in time with an AnimationTrack
└── VFX (Folder)              a copy of each effect object, named as the cues refer to them
```

Re-exporting rewrites the cues and rebuilds `VFX`. It keeps `Sequence` if one is already there, and keeps any `Function`s you added.

### Cue fields

| Field | Meaning |
| --- | --- |
| `Effect` | The effect's name. |
| `Offset` | The effect's CFrame relative to the HumanoidRootPart, or to its `Parent`. |
| `Object` | The VFX object to spawn, when it isn't named the same as `Effect`. |
| `Parent` | A part or attachment of the character the effect spawns on and follows. Leave it out for the HumanoidRootPart. |
| `Function` | Optional. `function(effect, character, cue)`, run right after the cue's VFX spawns. `effect` is `nil` if the cue has no VFX object. |

`Lifetime`, `CueTolerance` and `FrameRate` (the rate the cue keys are in) sit at the top of the table.

### Functions

| Function | What it does |
| --- | --- |
| `Play(character, track)` | Plays the cues in time with `track`. Call it right after `track:Play()`. Returns the Sequence; call `:Stop()` on it to cancel the rest. |
| `Spawn(character, root, cue)` | Spawns one cue's effect and runs its `Function`. |
| `Emit(object)` | Fires the effects in a spawned object. ParticleEmitters use their `EmitCount`, `EmitDelay` and `EmitDuration` attributes when they have them, and Sounds play. Replace it to use your own, e.g. `MoonAnimation.Emit = shared.vfx.emit`. |

### Keeping your Functions

When you export the same animation again, the exporter reads the existing module first and puts each `Function` back on its cue: by frame, or by effect name if you moved the event. If a cue was deleted in Moon, its `Function` is kept in a comment at the end of the module rather than lost.

## Building from source

Requires [Rojo](https://rojo.space) 7.

```bash
rojo build --plugin MoonVFXExporter.rbxmx
```

This installs the plugin straight into your Studio plugins folder. Use `rojo build -o build/MoonVFXExporter.rbxmx` to build a file instead.

| Module | Job |
| --- | --- |
| `SaveReader` | Reads Moon Animator 2 saves: items, tracks, rig joints and events. |
| `Sampler`, `Easing` | Evaluate a keyframe track at any frame. |
| `RigPose` | Works out where any part of a rig is at any frame. |
| `Exporter` | Turns events into cues: offsets, `Parent`, frame rate. |
| `Formatter` | Writes the cue table and the play code. |
| `Carryover` | Keeps cue `Function`s across exports. |
| `Packager` | Copies the VFX objects into the export. |
| `MoonHook` | The button inside Moon Animator and detecting the open file. |
| `Widget` | The exporter window. |
| `Templates/Sequence` | The Sequence module shipped with every export. |

## Tests

The plugin's logic is tested outside Studio with the [Luau](https://luau.org) CLI and Python 3:

```bash
python tests/run.py
```

## Notes

- The exporter's rig posing was checked against real Moon saves, where it reproduces Moon's pose exactly. How Moon blends between two keys couldn't be fully confirmed, so an event that falls between keys of something moving may be slightly off. Events on a key, or on something still, are exact.
- In game the cues play on one character, so an effect on a second rig in the file (a victim, say) is placed relative to the main character.
- The **Export VFX** button inside Moon Animator and the "Use file open in Moon" detection rely on Moon Animator's internal, undocumented API (`_G.MoonGlobal`), so a Moon update could break them. Everything else only reads Moon's save files.
- Moon's save format was worked out with help from [Moonlite](https://github.com/MaximumADHD/Moonlite) by MaximumADHD.
