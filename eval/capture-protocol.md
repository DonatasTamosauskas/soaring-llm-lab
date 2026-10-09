# Capture protocol

Media are only comparable when they are captured the same way. Each run's gallery has three
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

Unity builds: not automated yet. Their `Library/` folders were cleared, so the first step is a
batch-mode re-import (`Unity -batchmode -projectPath <run>/project/... -quit`), then a player
build and a scripted capture.

## 2. The agents' own media (chosen per run)

Screenshots and videos the agent produced while verifying its work, listed under `media` in
`run.json` (`source`, `file`, `caption`) and converted by `python3 tools/lab media`. They are
picked to show the same things where possible: menu, first flight, the world from above, growth.
The Opus 5.5 and Unity-port runs share matched camera positions from the port's comparison.

## 3. Gameplay capture (to do, the next step for comparability)

A 60-second recording per build in the Meta XR Simulator (Quest Pro profile) with the same
scripted wing input: take off, glide, bank left and right, dive, attempt one catch. This needs a
small input-driver per engine, which the Opus 5.5 build already has (`--harness=shots` and its
synthetic wing input) and the others do not.

## 4. Headset capture (when you playtest)

Record on the Quest itself (Meta button → Camera → Record video) during the rubric session, then
`adb pull /sdcard/Oculus/VideoShots/<file>.mp4 runs/<run>/media-src/` and list it in `run.json`
with the caption "Headset recording, <date>". Raw files can live outside git; only the converted
copy in `media/` is committed.
