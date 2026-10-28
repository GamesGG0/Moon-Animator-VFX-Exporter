# VFX Exporter

A Roblox Studio plugin that turns the events in a [Moon Animator 2](https://create.roblox.com/store/asset/4725618216) animation, or an [Eclipse Animator](https://create.roblox.com/store/asset/86116556258301) project, into ready-to-use VFX code. Created by Games.GG.

## [Download on the Creator Store](https://create.roblox.com/store/asset/88386490728445/VFX-Exporter)

Instead of scrubbing to every VFX event and printing `HumanoidRootPart.CFrame:ToObjectSpace(part.CFrame)` by hand, the plugin reads the saved animation and writes the whole cue table for you:

```lua
local MoonAnimation = {
	Lifetime = 6,
	CueTolerance = 0.15,
	FrameRate = 60,

	Cues = {
		[0] =   { Effect = "Start",                            Offset = CFrame.new(...) },
		[27] =  { Effect = "Hit",   Object = "ImpactAnti",     Offset = CFrame.new(...) },
		[84] =  { Effect = "Shine", Parent = "Right Arm",      Offset = CFrame.new(...) },
		[106] = { Effect = "Slash",                            Offset = CFrame.new(...), Function = function(self, effect, character, cue, data)
			-- your own code
		end },
	},
}
```

and the `Sequence` module that plays it, in time with the animation, and cleans up after it:

```lua
local sequence = Sequence.new(MoonAnimation, character)
track:Play()
sequence:Play(track, data, Resources.VFX) -- track and data are optional; the VFX are required
```

## Features

- **Exact offsets, straight from the save.** Each effect's CFrame and the HumanoidRootPart's are worked out from the keyframes: easing, rig joints and rig movement included. Where Moon's playhead was left doesn't matter.
- **One module plays everything.** The exported table is only data. The `Sequence` module clones each cue's VFX from the objects you give it, places, emits and animates them, plays screen, Lighting and camera effects, and removes it all after its `Lifetime` or as soon as you call `sequence:Stop()`.
- **Works with VFX Forge, Part_Icles and your own emitter.** Events whose code calls `shared.vfx.emit(a, b, ...)`, or an emit method of a module it requires (`local VFX = require(ReplicatedStorage.Utilities.VFX)` then `VFX:Emit(part)`, or `Part_Icles:AbsoluteEmit(a)`), become cues for what they emit, whichever item the event sits on, even Moon's Subtitles. Locals in the code (`local A = game:GetService(...)`, `local VFX = workspace.Barrage`) are followed. When an event names emitters inside a part or attachment, they're one cue, and only they are packed and fired, not everything else in there. A beam brings the attachments at both its ends. In game, the Sequence emits through `shared.vfx.emit` when your game has it, just like in Moon. With your own module, the export only names it (`Emitter = "ReplicatedStorage.Utilities.VFX:Emit"`), and the Sequence requires that module once (never cloned, though code made for Moon often does `require(X:Clone())`) and emits every cue's VFX with it, so those cues need no `Function`. If the code does more than emit, the rest stays in the cue's `Function`. If it uses the module for more than emitting (`Part_Icles:Activate()`, say), or emits inside an `if` or a loop, the code stays whole in the `Function`, which then does the emitting (`Emitter = false`). Either way each VFX is emitted once.
- **Camera effects.** VFX on the part Moon's camera is attached to get `Parent = "Camera"`, and in game they stay in front of the camera of the player whose character played the move.
- **Effects that follow a body part.** A cue can have a `Parent`, a part or attachment of the character. The effect spawns there and stays attached.
- **Keyframed effects.** Effects Moon animates with keyframes instead of events become cues too, at their first key, with the keys as data (`Keys`) that the Sequence replays with Moon's easing: a Highlight flashing its fill, a PointLight pulsing, `Lighting.ExposureCompensation`, the camera's field of view, a part (a BezTrail, say) moving along a path. Lights in a prop are spawned where the prop was; a moving part starts when it starts moving, with its path relative to the character. Such an effect stays until its keys finish, even past the table's `Lifetime`. Lighting and the field of view hold their last values until the animation ends, as in Moon, then go back.
- **Screen effects too.** Moon's screen effects become cues with their look and keys (`Screen`, `Properties`, `Keys`), which the Sequence replays on the player's screen. That covers its overlays (the vignette, the letterbox, the screen cover) and post effects such as blur and color correction. Overlays Moon builds from several pieces come whole: its vignette is four images tiling the screen, its letterbox two bars. Moon's **Subtitles** come too: their lines and how they type out, with the text sized for the player's screen as Moon sizes it, and the last line up until the animation ends. Only the player whose character it is sees them (Lighting and camera effects too).
- **Subtitles and camera shakes from Eclipse.** Eclipse Animator's subtitles are drawn by the Sequence as Eclipse draws them, with their entrances and exits, letter-by-letter motion, styles and keys, and its camera shakes shake the player's camera with Eclipse's own pattern. See [From Eclipse Animator](#from-eclipse-animator).
- **Images load ahead of time.** The Sequence preloads the images its ImageLabels show, once per client, so an overlay doesn't pop in late.
- **Your own code per cue.** An optional `Function` runs when a cue fires, only where you want one: nothing the exporter can express as data gets a Function. It gets the sequence as `self` and whatever `data` you passed to `Play`, and it's kept when you export the animation again. Hand `self:AddToCleaner(thing)` anything it makes, and the sequence cleans that up with its VFX.
- **Event code runs in game.** An event that runs other code in Moon (tweening beams, making a Highlight) becomes a cue with that code in its `Function`. The code used the objects in your Moon scene, so the exporter rewrites them to what they are in game: what the code names becomes `effect`, the spawned copy of it (`workspace:WaitForChild("Runbeams")` becomes `effect`, and its beams, attachments and connections work on the copy); the rig becomes `character`, the one playing the move; and another rig becomes the character you pass in `data.Rigs` (the code only runs when you do). What the code makes and puts in the world, and the connections it makes, are handed to `self:AddToCleaner`, so `sequence:Stop()` removes them too, and its loops are written without `ipairs` or `pairs`. Code that uses anything else from the scene is left commented out, with a note saying what to adapt.
- **Warnings, not errors.** What can't be exported as it is (event code that can't run in game, a keyed value of a type the module can't write, an emit of something that isn't in the place) is a warning when you export, in the status line and the Output, and the rest of the export goes ahead. In game, a cue's `Function` that errors is a warning too, and the other cues still play.
- **Other rigs.** Effects on a second rig in the file (a victim, say) get `Rig = "TemplateR6"` and play on the character you pass in `data.Rigs`.
- **Attachments everywhere.** They work as VFX objects, as a `Parent`, and nested inside other attachments.
- **Only real VFX.** Events on things that aren't VFX objects (Moon's Subtitles and other GUI, the camera) only count for what their code emits or runs; empty ones are left out, and the status line lists them. (Moon's Subtitles still show their lines, as a screen effect.) An event on a rig with no name and no code, only keys in Moon's Events tab (`Damage = 3`, `Ragdoll`...), is a marker for your game, not a VFX, so it's left out too, unless **Measured at** is set. A Highlight goes on the character, and an emitter, light or sound inside a part spawns with its part.
- **Preview in Studio.** **Preview** exports, then plays the export on the file's rig in edit mode, so you can check where the VFX land without starting a game. It runs what the game gets (the module, its VFX and its Sequence), by the clock; Moon's animation doesn't play along. Click **Stop preview** to end it; nothing it spawns is saved with the place.
- **One-click file.** **Save .rbxm** saves the module, Sequence and VFX objects as one file you can drop into any place.
- **Eclipse Animator projects too.** Projects saved in Eclipse Animator are listed next to Moon's files and export the same way (see [From Eclipse Animator](#from-eclipse-animator)): Eclipse's own emits, event code, keyed effects, rigs, camera field of view, screen effects, subtitles and camera shakes, with its curves replayed as Eclipse plays them.
- **Built into Moon and Eclipse.** An **Export VFX** button sits next to Moon's Options button, and Eclipse Animator's **Item** menu has an **Export VFX** row.
- **Frame or time keys.** Cues are keyed by frame number or by time in seconds. The frame rate is raised automatically when events need more precision.

## Using it

1. In Moon Animator, add an event (Edit Events) on each VFX item at the frame it should fire, then save the file (Ctrl+S). The plugin reads the saved copy.
2. Click **Export VFX** in Moon Animator, or open **VFX Exporter** from the Plugins tab, pick the file and click **Export cues**.
3. The module appears in `ServerStorage.VFXExports` and opens in the script editor, with its `Sequence` module and a `VFX` folder of the objects it uses. Move the module and `Sequence` to ReplicatedStorage, put the VFX where you keep yours (say `Resources.VFX`), and on the client:

```lua
local Sequence = require(ReplicatedStorage.Sequence)
local MoonAnimation = require(ReplicatedStorage.MoonAnimation)

local track = animator:LoadAnimation(animation)
local sequence = Sequence.new(MoonAnimation, character)
track:Play()
sequence:Play(track, nil, {
	ImpactAnti = Resources.VFX.ImpactAnti,
	Shine = Resources.VFX.Shine,
})
```

The animation is optional. With `track`, the VFX keep in time with it: they follow its time position, so they keep up if it's sped up, paused, looped or rewound, and once it stops no more cues fire. Without one, pass `nil`, and the cues play by the clock from the moment you call `Play`:

```lua
sequence:Play(nil, nil, Resources.VFX) -- no animation: the cues play by the clock
```

`data` is optional too. Only the VFX table is required.

The VFX table names each object the way the cues do: a cue's `Object`, or its `Effect` when it has no `Object`. The comment at the top of the module lists them all, and a Folder holding them works in place of the table. `Play` warns once about any that are missing.

If some cues are on another rig in Moon (they have a `Rig` field, and the status line names the rig), pass the character that plays it in `data`:

```lua
sequence:Play(track, { Rigs = { TemplateR6 = victim } }, Resources.VFX)
```

Without it those cues are skipped, with one warning. Anything else you put in that table reaches every cue's `Function` as `data`.

`sequence:Play` only plays on the client: called on the server, it warns and plays nothing. To show a move to every player, have each client play it on that player's character (the server can tell them to with a RemoteEvent).

To end the move early (the character got hit, say), call `sequence:Stop()`: the cues still to come are cancelled and everything the sequence spawned is removed, with Lighting and the camera put back. Otherwise, when the track ends, what's already out finishes on its own.

> **Tip:** Animations, VFX, SFX, or anything visual should stay on the client, NEVER on the server.

### From Eclipse Animator

1. In Eclipse Animator, add events to the timeline items at the frames they should fire, and save the project. Eclipse keeps it in `ServerStorage › Eclipse Animator Saves › EclipseAnimator_Saves`, which is what the plugin reads.
2. In Eclipse, choose **Item › Export VFX**: it exports the project Eclipse has open, as last saved. Or open **VFX Exporter** from the Plugins tab, pick the project (it's marked **Eclipse** in the list) and click **Export cues**. The export is the same module, `Sequence` and `VFX` as for Moon, played the same way.

What it reads from the project:

- **Emits.** An event's emits become cues for what they emit, found from the item the event is on: **Exact** emits just the effect it names, **Selected** the effects right inside what it names, **All** everything in it. A count set on the emit becomes the cue's `EmitCount`.
- **Switching effects on and off.** An emit set to **Enable** or **Disable** becomes keys on the effect's `Enabled`, which the Sequence replays: it spawns when it's switched on, and what it gave off has time to fade once it's switched off.
- **Event code.** Code an event runs when it fires, and when it ends (after its duration), goes into the cue's `Function`, rewritten to run in game like Moon's. It starts with what Eclipse gives event code, for the names it uses: `rig` (what the event is on: usually `character`), `parameter`, `event`, and `context`, a table the two parts share. The end code runs after the event's duration, unless the sequence stops first.
- **Keyed effects.** Property tracks on lights, Highlights, emitters, parts, Lighting and post effects become keyframed cues, as in Moon. Eclipse's easing styles carry over as they are. Its default style, **Bezier** with automatic handles, depends on the keys either side and is smoothed through a run of keys. A key whose value is one number becomes a `"Bezier"` key with its curve's two control points. A value whose parts curve differently, like a Vector3 on a bent path, gets a key at each frame where a straight line wouldn't do. Either way it plays as it does in Eclipse. `Transparency`, `Color` and `Reflectance` keyed on a whole model go on its parts (and decals), as Eclipse does it.
- **Rigs.** Joints are posed from their keyed `C0`, and Eclipse's master control moves the whole rig, so offsets are measured from where the character really is at each event.
- **The camera's field of view**, from Eclipse's camera rigs.
- **Everything in Eclipse's Effects menu:**
  - **Subtitles** become `Subtitle` cues, which the Sequence draws as Eclipse does: text, speaker and portrait, font, colours, outline, background, gradient and rainbow, jitter, wave and pulse, words styled on their own, where it sits (top, centre or bottom, with others showing at once stacked by their order), keys that change its look as it shows, and every entrance and exit (fades, slides, pop, zoom, spin, typewriter, word by word, wipe, and the letter and word motions).
  - **Vignette**, **Screen Cover** and **Impact Frames** (one cue per image they show, the built-in White, Black, Burst and Inverse ones included) become screen cues, drawn as Eclipse draws them.
  - **Letterbox**: a solid one is two bars on the screen, sized as Eclipse's cover the view (keyed bar sizes too). One made of effects (beams and particles) is spawned whole in front of the player's camera, faded and tinted as Eclipse paints it.
  - **Camera Shake** becomes a `Target = "Shake"` cue: the Sequence shakes the player's camera with its keyed strength and speed, in the same pattern Eclipse shakes its camera.
  - One that's still showing when its keys end stays until the animation does. Like screen effects, they're only for the player whose character played the move.
- Items switched off in Eclipse's timeline are left out.

Not exported yet, with a warning when a project has them: a gradient's colour keys (on a letterbox made of effects, its gradient), a keyed **VFX Size** on a letterbox made of effects, and animation layers (only the layer being edited when the project was saved is read). Event sounds aren't VFX, so they're left out.

### The exporter window

| Setting | What it does |
| --- | --- |
| **Animation file** | The Moon save or Eclipse project to export (Eclipse's are marked **Eclipse**). **Use file open in Moon or Eclipse** picks the one open there. Moon's autosaves aren't listed. |
| **Table name** | The variable name in the generated code. Defaults to `MoonAnimation`. |
| **Lifetime** | Seconds before a spawned effect is removed. Defaults to the animation's length. |
| **CueTolerance** | Seconds a cue may already be overdue when `Play` starts (e.g. partway through the animation) before it's skipped. |
| **Effect name** | Use the event's Name (falling back to the part's name), or always the part's name. |
| **Cue keys** | Frame numbers (`[27]`) or timestamps in seconds (`[0.45]`). |
| **Export FPS** | **Auto** keeps the file's frame rate unless events fall between frames or share a frame, then raises it. Or pick 30, 60, 120 or 240. |
| **Relative to** | What offsets are measured from. Defaults to the HumanoidRootPart of the first rig in the file. |
| **Measured at** | Measure every event at one part (such as a container part) instead of the item each event is on. |
| **Export button** | Where the **Export VFX** button goes in Moon Animator, or hide it. |

Under the settings are **Export cues**, **Preview**, **Save .rbxm** and **Dump save**. **Preview** plays the export on the file's first rig (its other rigs stand in for `data.Rigs`), from where the rig stands, with screen, Lighting and camera effects on Studio's view. **Dump save** prints the selected file's structure to the Output window, which helps when something doesn't export the way you expect.

### Setting a Parent

A cue gets a `Parent` automatically when its VFX object is:

- on a part Moon animates through a joint (a limb or an animated weapon): that part, or
- an attachment on a limb, a part welded to one, or a part put inside one (in the Explorer, with no weld): that limb, or
- a part or model outside the rig welded to a limb (directly, or through other parts welded to it), or an emitter inside one: that limb. Anchored parts stay put.

In game the Sequence welds the VFX to that part of the character, so it follows it.

To choose one yourself, open the event in Moon's **Edit Events** window, go to the **Events** tab, and add a key `Parent` whose value is a part or attachment name, such as `Right Arm` or `RightGripAttachment`. That wins over the automatic choice. `HumanoidRootPart` works too: the effect then follows the character as it moves (run beams, say), where without a `Parent` it stays where it was placed.

## The exported module

```
MoonAnimation (ModuleScript)  the cues: only data
├── Sequence (ModuleScript)   plays the cues and cleans up after them
└── VFX (Folder)              a copy of each effect object, named as the cues refer to them
```

Re-exporting rewrites the cues and rebuilds `VFX`. It keeps `Sequence` if one is already there (unless it's an older version that can't play the new cues; the module has a `Version`), and keeps any `Function`s you added. A `Sequence` you've moved into your game isn't updated: after updating the plugin, replace it with the new one from an export.

### Cue fields

| Field | Meaning |
| --- | --- |
| `Effect` | The effect's name. |
| `Offset` | The effect's CFrame relative to the HumanoidRootPart, or to its `Parent`. A cue without one has no VFX: it's a subtitle, a screen, Lighting or camera effect, or just its `Function`. |
| `Object` | The name of the VFX to spawn, when it isn't `Effect`. |
| `Parent` | A part or attachment of the character the effect spawns on and follows (`"HumanoidRootPart"` included). Without one, it's placed from the HumanoidRootPart and stays put. `"Camera"` keeps it in front of the camera, for the player whose character played the move only. |
| `Rig` | The effect was on another rig in Moon. It plays on `data.Rigs[Rig]` instead of the character. |
| `Keys` | Keyframes the Sequence plays: `{ Property = { { seconds, value, easingStyle, easingDirection }, ... } }`. CFrame keys are offsets, like `Offset`. An Eclipse Bezier key has its curve's control points where the direction goes: `{ seconds, value, "Bezier", { x1, y1, x2, y2 } }`. `Transparency`, `Color` and `Reflectance` keys on a model go on its parts. |
| `EmitCount` | Optional. How many particles each of the VFX's ParticleEmitters gives off, instead of its own `EmitCount` (from an Eclipse emit's count). |
| `Emitter` | Optional. The emitter this cue's VFX is emitted with, when its event emitted with a different module than the table's `Emitter` (named the same way); or `false` when it isn't emitted (its `Function` emits it, or it's an Eclipse letterbox, whose effects run while it shows). |
| `Path` | Names leading from the spawned VFX to what `Keys` animate, e.g. `{ "i1", "PointLight" }`; for a screen effect, from the effect to its keyed piece. |
| `Screen` | A screen effect to show instead of a VFX: a GUI class such as `"ImageLabel"`, or a post effect such as `"BlurEffect"`, set up with `Properties` and animated by `Keys`. Moon's vignette is four images tiling the screen (no image can be 1920 by 1080) and its letterbox two bars, so a screen effect's other pieces come in `Children` (each with its `Name`, `ClassName`, `Properties`, own `Children`, and `Keys` of its own if it has them). `Keys` play on the piece `Path` leads to, or the effect itself, and on the pieces marked `Mirrors`, as Moon copies its look onto them. `ScaleText = true` sizes its text for the player's screen from sizes made for a 1080 pixel tall one, as Moon's Subtitles do. |
| `Subtitle` | A subtitle to show instead of a VFX, drawn as Eclipse Animator draws them: `{ Duration, In, Out, Entrance, Exit, Order, Style, Keys }`, times in seconds. `Style` is how it looks, as what differs from Eclipse's defaults (`Text`, `Speaker`, `Size`, `Color`, `Font`...), and `Keys` change it as it shows: `{ { seconds, style, "Smooth" \| "Linear" \| "Hold" } }`, each style what differs from `Style`. `Entrance` and `Exit` are Eclipse's motions (`"Fade"` when left out), taking `In` and `Out` seconds. |
| `Target` | `"Lighting"` or `"Camera"`: `Keys` play on that instead, held for `Hold` seconds, then put back. A `Screen` with a `Hold` is shown for that long, if it's longer than its keys. `"Shake"` shakes the camera as Eclipse's Camera Shake does: `Keys` are its `Strength` (0 to 100), `Speed` and `Enabled`, `Seed` picks its pattern and `Phase` where in it it starts. |
| `Lifetime` | Optional. Seconds before this cue's VFX is removed, instead of the table's. |
| `Function` | Optional. `function(self, effect, character, cue, data)`, run right after the cue's VFX spawns. `self` is the sequence, `effect` is `nil` if the cue has no VFX, and `data` is what you passed to `Play`. If it errors (code that isn't supported in game, say), that's a warning, and the other cues still play. A `Function` from before `self` was passed, `function(effect, ...)`, gets it added when you export again. |

`Lifetime`, `CueTolerance` and `FrameRate` (the rate the cue keys are in) sit at the top of the table, and so does `Emitter` when the events emitted with a module of yours:

```lua
	-- Moon's events emitted their VFX with ReplicatedStorage.Utilities.VFX, so the Sequence emits each cue's VFX with it too.
	Emitter = "ReplicatedStorage.Utilities.VFX:Emit",
```

That's the ModuleScript from a service down, then the method, called with `:` or `.` as the events called it. The Sequence requires the module once, the first time it's needed, and emits every cue's VFX with it instead of with `Sequence.Emit`. If it isn't there, that's a warning, and `Sequence.Emit` stands in.

### The Sequence module

| | What it does |
| --- | --- |
| `Sequence.new(animation, character, frameRate, tolerance)` | A sequence of the exported table's cues, played on `character`. `frameRate` (optional) is the rate the cue keys are in; it defaults to the table's `FrameRate`, or 1 when its keys are in seconds. `tolerance` (optional) is how many seconds a cue may already be overdue when the sequence first reaches it (say, `Play` was called partway through the track) before it's skipped; it defaults to the table's `CueTolerance`, or no limit. Frame-rate dips and hitches never skip cues. |
| `sequence:Play(track, data, vfx)` | Plays the cues, on the client only: on the server it warns and plays nothing (so does `Spawn`). `track` (optional) is the AnimationTrack to keep in time with; call `Play` right after `track:Play()`. Without one, the cues play by the clock. `data` (optional) goes to every cue's `Function`. `vfx` (required) holds the objects the cues use, by name, or is a Folder of them. |
| `sequence:Stop()` | Cancels the cues still to come and removes everything the sequence spawned: VFX, screen effects, and Lighting and camera changes (put back as they were), and everything added to its cleaner. |
| `sequence:AddToCleaner(thing, lifetime)` | Has the sequence clean up something a `Function` made, like its VFX: an Instance is destroyed, a connection disconnected, a function called, a thread (from `task.delay`, say) cancelled. That happens when the sequence stops, or after `lifetime` seconds (optional: the animation's `Lifetime`; `math.huge` waits for the stop). Returns `thing`, so `local highlight = self:AddToCleaner(Instance.new("Highlight"))` works. |
| `sequence:Spawn(cue, data, vfx)` | Fires one cue right away. `data` and `vfx` default to what was given to `Play`. |
| `Sequence.Preload(animation, vfx)` | Loads the images the cues' ImageLabels show ahead of time (screen effects' images, and ImageLabels and ImageButtons in the VFX), so they don't pop in late. `Sequence.new` and `Play` do it themselves; call it earlier (when the character spawns, say) to load them sooner. `vfx` is optional, and each image is only loaded once. |
| `Sequence.Emit(object, count)` | Fires the effects in a spawned VFX, through VFX Forge's `shared.vfx.emit` when the game has it. Otherwise ParticleEmitters use their `EmitCount`, `EmitDelay` and `EmitDuration` attributes when they have them (`count`, optional, is how many particles each gives off instead: a cue's `EmitCount`), and Sounds play. An export's `Emitter` (or a cue's) is used instead when it names one. To use some other emitter everywhere, replace it: `Sequence.Emit = yourEmit`. |
| `Sequence.Emitter(name)` | The emitter an export names, such as `"ReplicatedStorage.Utilities.VFX:Emit"`: a function that emits a VFX with that module, which is required once, the first time. Returns `nil` and why when there's no such module or method. |

Its helpers can be used in your own `Function`s too. Each returns what it made or animated, and a function that undoes it now:

| Helper | What it does |
| --- | --- |
| `Sequence.Animate(object, keys, options)` | Plays keys on `object`. `options.Path` names a descendant to animate instead, `options.Origin` makes CFrame keys relative to a CFrame, `options.Restore` puts the values back at the end, and `options.Duration` holds the last values until that many seconds have passed. |
| `Sequence.LightingEffect(character, keys, duration)` | Animates `Lighting` for that character's player, holds the last values for `duration` seconds, then puts it back. |
| `Sequence.CameraEffect(character, keys, duration)` | The same for the player's camera (its field of view). |
| `Sequence.ScreenEffect(character, className, properties, keys, duration, children, path, options)` | Shows a GUI overlay or post effect for that character's player, animated by `keys`. `children` (optional) are its other pieces and `path` its keyed piece, as in a `Screen` cue; `options.ScaleText` sizes its text for the screen. |
| `Sequence.Subtitle(character, subtitle)` | Shows a subtitle for that character's player, as Eclipse draws it. `subtitle` is a `Subtitle` cue's table. |
| `Sequence.CameraShake(character, keys, duration, seed, phase)` | Shakes that character's player's camera as Eclipse does, by its `Strength`, `Speed` and `Enabled` keys, then puts it back. |
| `Sequence.RootCFrame(character)` | The character's HumanoidRootPart CFrame, or its pivot. |

### Keeping your Functions

When you export the same animation again, the exporter reads the existing module first and puts each `Function` back on its cue: by frame, or by effect name if you moved the event. If a cue was deleted in Moon, its `Function` is kept in a comment at the end of the module rather than lost.

A `Function` holding an event's code from Moon starts with a comment saying so, and is written again on each export, rewritten or commented out. Delete that comment line once you've edited it, to make it yours. (Exports from older versions had generated `Function`s for screen and keyframed effects; re-exporting replaces them with data.)

## Building from source

Requires [Rojo](https://rojo.space) 7.

```bash
rojo build --plugin VFXExporter.rbxmx
```

This installs the plugin straight into your Studio plugins folder. Use `rojo build -o build/VFXExporter.rbxmx` to build a file instead.

| Module | Job |
| --- | --- |
| `SaveReader` | Reads Moon Animator 2 saves: items, tracks, rig joints and events. |
| `EclipseReader` | Reads Eclipse Animator projects into the same items, tracks, joints and events. |
| `EclipseCurves` | Eclipse's easing and automatic Bézier curves, as Moon-style keys. |
| `Sampler`, `Easing` | Evaluate a keyframe track at any frame. |
| `RigPose` | Works out where any part of a rig is at any frame. |
| `Exporter` | Turns events and keyframed effects into cues: offsets, `Parent`, `Rig`, frame rate. |
| `Formatter` | Writes the cue table. |
| `Carryover` | Keeps cue `Function`s across exports. |
| `Packager` | Copies the VFX objects into the export. |
| `MoonHook` | The button inside Moon Animator and detecting the open file. |
| `EclipseHook` | The **Item › Export VFX** row inside Eclipse Animator and detecting its open project. |
| `Widget` | The exporter window. |
| `Templates/Sequence` | The Sequence module shipped with every export: plays the cues and cleans up after them. |

## Tests

The plugin's logic is tested outside Studio with the [Luau](https://luau.org) CLI and Python 3:

```bash
python tests/run.py
```

## Notes

- The exporter's rig posing was checked against real Moon saves, where it reproduces Moon's pose exactly. How Moon blends between two keys couldn't be fully confirmed, so an event that falls between keys of something moving may be slightly off. Events on a key, or on something still, are exact.
- An effect on a second rig in the file (a victim, say) plays only when you pass that rig's character in `data.Rigs`.
- Screen effects' look (the vignette's images, say) is copied from Moon's own GUI when Moon Animator is open. Without it, Moon's vignette, letterbox, screen cover and subtitles are made the way Moon makes them; any other overlay starts see-through and full-screen, with a note on the cue.
- The camera's own movement (a cutscene camera) isn't exported, only its field of view. Keyframed movement of something on Moon's camera part isn't replayed either: an emitted one is placed where it is when it fires, and one with no events is listed with the left-out items.
- The **Export VFX** button inside Moon Animator and the "Use file open in Moon" detection rely on Moon Animator's internal, undocumented API (`_G.MoonGlobal`), so a Moon update could break them. Everything else only reads Moon's save files.
- Moon's save format was worked out with help from [Moonlite](https://github.com/MaximumADHD/Moonlite) by MaximumADHD.
- Eclipse Animator's project format was worked out from what the plugin writes, and checked by reading back projects written by Eclipse's own save code. Its curves were checked against Eclipse's own interpolation, which they match, and so were its subtitles (their layout, motions, letter animation and keys) and its camera shake. The **Item › Export VFX** row is added to Eclipse's own menu from outside it, so an Eclipse update could move or break it; the exporter window always works. Rig poses use each joint's keys the way Eclipse eases a property, so a rig animated with the graph editor's per-axis curves or IK may be slightly off between keys (keys themselves are exact). Like everything that reads another plugin's saves, a new Eclipse version could change the format.
