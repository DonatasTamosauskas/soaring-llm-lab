# Capture protocol

Media are only comparable when they are captured the same way. Each run's gallery has these
kinds, labelled in their captions.

## 1. Start-up capture (automated, Godot builds)

```bash
tools/capture_godot.sh <run>          # 12 s; add a length in seconds as a second argument
```

On a scratch copy in `raw/_work/<run>/`: headless import with the installed Godot, then the main
scene in a desktop window with XR off, Forward+ (the Mobile renderer misdraws under MoltenVK on
macOS), 1280×720, fixed 30 fps, no input, recorded with Godot's movie writer. Produces
`media/startup.mp4`, `startup-first.jpg` (2 s), `startup-end.jpg` and `checks.json`. A Godot
window opens on your screen while it records.

It shows what a build presents on launch, which for most of them is a menu or the first view of
the world, not gameplay. VR-only builds may show little without a headset.

Both Godot capture tools pin the copy's window to 1280×720 (the movie writer records at the
project's window size, so a different `--resolution` gives a zoomed crop) and give it its own,
emptied `user://` folder: several builds are called "Soaring" and would otherwise read and write
the same saves (`tools/godot_overrides.py`).

Unity builds: `tools/capture_unity.sh <run>` copies the project to `raw/_work/<run>/Soaring`,
opens it in batch mode with Unity 6000.6.4f1 (accepting a version upgrade in the copy only) and
counts distinct C# compile errors. It then builds a macOS player with XR initialisation off and
records the same 12 s start-up at 1280×720 and a fixed 30 fps, plus a 36 s scripted-flight capture
driven by `eval/capture-unity/<run>.cs` through each build's own input path where it has one
(Sol's desktop keys, the port's harness hook, Prime Muse's controller transforms). Per-run copy
changes and captions are in `eval/capture-unity/<run>.json`; Prime Muse also needs
`<run>.patch.py` before its scene loads in a player.

## 2. The agents' own media (chosen per run)

Screenshots and videos the agent produced while verifying its work, listed under `media` in
`run.json` (`source`, `file`, `caption`) and converted by `python3 tools/lab media`. They are
picked to show the same things where possible: menu, first flight, the world from above, growth.
The Opus 5.5 and Unity-port runs share matched camera positions from the port's comparison.

## 3. Gameplay capture (automated, Godot builds, desktop)

```bash
tools/capture_gameplay_godot.sh <run>          # 36 s; add a length in seconds as a second argument
DRY=1 tools/capture_gameplay_godot.sh <run>    # tuning: plays the timeline headless, no window, no media
```

Each build flies on its own desktop controls, pressed by a timeline instead of a person:
`eval/capture-input/<run>.gd` lists what is pressed and when (menu, take-off, flaps, banks, a dive),
on top of a shared driver (`eval/capture-input/driver.gd`) that only injects keyboard and mouse
events through `Input`, the path real input takes. No autopilot, no calls into game code. On a
scratch copy in `raw/_work/<run>/gameplay/`, the tool adds the driver as an autoload, applies
`eval/capture-input/<run>.patch` when a build needs one to show anything on desktop (only Prime
Muse: its desktop fallback handed the window to XR), and records like the start-up capture:
desktop window, XR off, Forward+, fixed 30 fps, movie writer. Two settings differ in the copy only:

- the window is pinned to 1280×720 (the movie writer records at the project's window size, and a
  mismatch with `--resolution` produces a zoomed crop), so every build has the same frame;
- `user://` points at a folder of its own, emptied before each run, so every capture starts like a
  first launch and never reads or writes the real saves (several builds share the name "Soaring").

It writes `media/gameplay.mp4` (H.264, crf 28, faststart), `gameplay.poster.jpg` and
`gameplay-1.jpg`… at times the timeline names, and merges them into `checks.json` (`captures`
entries and a `gameplay` block with frame counts and the input file). Captions start with
"Scripted flight on desktop, XR off". The Godot window stays on top for two to three minutes:
leave it visible and keep the pointer off it. If it stops drawing part-way (covered, minimised,
another Space), the tool leaves the media unchanged. A build that reads mouse motion without
capturing the cursor (Prime Muse) also sees a real pointer moving over the window.

How repeatable a rerun is depends on the build. Sol and Opus 5.5 flew the same path headless and
in the window. Opus 5 matched an earlier take for 14 s and then drifted; that take still had the
old saved settings, so the cause is not pinned down. Prime Muse's NPC birds use Godot's unseeded
random generator, and contact with them changes the player's size and lift, so its reruns differ
(the driver can fix the seed; see its timeline file).

This shows the flight model and world under identical, repeatable input. It is not the headset
experience: arm-flapping is replaced by each build's own keyboard stand-in, which the builds
designed differently. A headset-input comparison (the Meta XR Simulator with the same scripted
wing poses) is still to do.

## 4. Headset capture (when you playtest)

Record on the Quest itself (Meta button → Camera → Record video) during the rubric session, then
`adb pull /sdcard/Oculus/VideoShots/<file>.mp4 runs/<run>/media-src/` and list it in `run.json`
with the caption "Headset recording, <date>". Raw files can live outside git; only the converted
copy in `media/` is committed.
