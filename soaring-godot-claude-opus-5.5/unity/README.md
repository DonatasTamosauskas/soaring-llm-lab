# Soaring — Unity 6.6

The Unity recreation lives entirely in this directory. The Godot source project
remains the source of the valley and species art, and is not needed to play a
built Unity player. Unity version: **6000.6.4f1**.

The [Godot / Unity comparison gallery](docs/comparison/index.html) includes a
20-second matched camera tour, seven paired screenshots, and original captures.
See [capture notes](docs/comparison/README.md) for reproduction and limits.

## Run

```sh
./tools/unity.sh open          # Unity editor
./tools/unity.sh build-mac     # Apple Silicon player
./tools/run-simulator.sh       # installed standalone Meta XR Simulator
./tools/run-desktop.sh         # keyboard and mouse
./tools/unity.sh build-android # ARM64 IL2CPP Vulkan release Quest APK
./tools/verify-apk.sh          # ABI, OpenXR, manifest and signature checks
```

Native meshes, materials, the valley prefab and scene are included.
`./tools/unity.sh setup` regenerates them from the frozen source assets. This is an explicit, reproducible editor operation; opening the editor
does not rewrite the scene.

The installed simulator's device profile must be **Meta Quest Pro**. For mouse
testing, enable **Inputs → Keyboard and mouse → Point & click** in its UI. Its runtime
manifest is selected per launched process. Both Touch Pro controllers must be
tracked. The Mac loader placement and development signing fix from the supplied
Unity example is applied automatically during the Mac build.

The CLI passes an explicit build target for each editor process and reapplies
the project's baseline before a build. The Quest profile supplies platform
shader optimizations and inherits the game's player settings.

## Play

Point with either controller and pull the trigger to use menus. Spread your
wings to calibrate on first launch. Downstrokes climb; symmetric wrist tilt
changes speed and lift; opposite tilts or one raised hand bank; tuck to dive.
Fly slowly onto a branch, wire, or ledge to perch; flap to launch. Thermals and
windward cliffs lift a gliding bird. Blue rings identify worthwhile prey,
magenta triangles identify bigger birds. Catch prey by flying through it.

Grow from sparrow through swallow, starling, pigeon, crow, gull, hawk, and eagle.
Size changes continuously, including your scale in the world. A catch costs a
predator time to handle its meal. Getting caught costs a life and some mass,
then returns you to a perch with protection. Growth and every five worthwhile
meals restore lives. Three worthwhile catches as an eagle win the valley.

Left menu or hold B pauses. Hold A/X to recenter; hold Y to recalibrate. Restart
and quit require a 0.8-second trigger hold with a progress bar. Settings include comfort, turn rate,
volumes, wing power, haptics, seated mode, dominant hand, recenter and calibration.

Desktop: Space flaps, W/S tilt, A/D bank, Q/E one-wing flaps, Shift tucks,
Ctrl/X sweep, mouse looks, Escape pauses, R recenters. Menus release the cursor.

## Verify

```sh
./tools/unity.sh validate
./tools/unity.sh test
./tools/verify-builds.sh # tests, both builds, APK validation
./tools/run-desktop.sh --verify-soaring --evidence "$PWD/Logs/desktop-evidence"
./tools/run-simulator.sh --verify-soaring --evidence "$PWD/Logs/xr-evidence"
```

The visual revision restores the source font, faceted styling, curved menus,
animated gesture illustrations, species/growth/life HUD and hold feedback.
URP uses one hard-shadow sun with a 2048-pixel map and a 90 m range; source
shadow-only tree meshes and nearby birds cast shadows. This needs a headset
frame-time measurement before any performance improvement can be claimed.

The opt-in player harness runs the real scene, verifies flight, pause/resume,
growth, a caught/respawn cycle and apex victory, and saves screenshots and a run
report. Normal play does not run it. Tests cover size anchors, food rules,
continuous catches, aerodynamic relationships, stalls and recovery, coordinated
turns, frame rate consistency, persistence, and exported content.

The presentation harness captures each menu, exercises both pointer sources,
checks visible glyphs and hold feedback, and compares shadow-on/off images:

```sh
./tools/run-desktop.sh --verify-presentation --evidence "$PWD/Logs/presentation-desktop"
SOARING_SIMULATOR_LOG="$PWD/Logs/presentation-xr.log" ./tools/run-simulator.sh --verify-presentation --evidence "$PWD/Logs/presentation-xr"
```

`./tools/run-simulator.sh --trace-input` logs controller trigger edges and menu
targets when diagnosing simulator pointing or input bindings.

See [verification](docs/VERIFICATION.md) for observed results and
[architecture](docs/ARCHITECTURE.md) for implementation choices. Asset attribution
is retained in [third-party notices](THIRD_PARTY_NOTICES.md).

## Install on Quest Pro

Use the Android platform tools bundled with Unity, or your existing `adb`:

```sh
adb install -r Builds/Soaring.apk
adb shell am start -n com.soaring.unity/com.unity3d.player.UnityPlayerGameActivity
adb logcat -s Unity
```

The APK uses development signing for sideloading and is a release player. Store
submission needs your own signing key and the usual device/store validation.
The package is `com.soaring.unity`, separate from the Godot game's package.
