# Verification — 4 October 2026

The project was built with the installed Unity **6000.6.4f1** CLI on macOS.
Both the Apple Silicon development player and the ARM64 IL2CPP Quest release
APK were built successfully. The final APK is **128.8 MiB**; its hash and
visual-revision assertion counts are retained in `reports/visual-revision.json`. The Godot project is unchanged; all port source,
assets, build scripts, logs and generated players are under `unity/`.

## Automated checks

| Check | Result | Evidence |
| --- | --- | --- |
| Edit Mode tests | 21 passed; no failed or skipped tests | `Logs/editmode-results.xml` |
| OpenXR configuration validation | Zero errors for Standalone and Android | `Logs/validation.txt` |
| Mac build | Succeeded; zero errors, two warnings | `Logs/build-StandaloneOSX.txt` |
| Quest build | Succeeded; zero errors, nine warnings | `Logs/build-Android.txt` |
| APK integrity, manifest and ABI | Passed; `com.soaring.unity`, Quest Pro (`cambria`), VR activity, head tracking, nine ARM64 native libraries, IL2CPP and OpenXR present; min SDK 32, target SDK 36 | `Logs/apk-badging.txt`, `Logs/apk-manifest.txt` |
| APK signature | Verified with Android SDK apksigner; v2 signature, one signer | `tools/verify-apk.sh` |
| Desktop presentation harness | Passed: visible glyphs on menu/settings/tracking/help/pause/calibration; both pointer paths; short/complete hold; visible sun and water shadows | `Logs/presentation-desktop.log`, `docs/comparison/presentation/` |
| Quest Pro simulator presentation harness | Passed: running/tracked XR, illustrated curved pages, both synthetic pointer paths, hold feedback and visible glyphs | `Logs/presentation-xr.log`, `docs/comparison/presentation/xr/` |
| Desktop player harness | 11 gameplay assertions passed; process exited 0 | `Logs/comparison/unity-ui.log`, `Logs/comparison/unity-ui/` |
| Quest Pro simulator player harness | 13 assertions passed, including running XR display and tracked controllers; process exited 0 | `Logs/xr-verification.log`, `Logs/xr-evidence/` |

Tests cover the source mass/span anchors, food and dust rules, swept catches and
bounded assistance, finite flight across species, angle of attack, tuck, flaps,
stall/recovery, banked turns, integration consistency, atomic persistence,
imported ground and water, moth food budgets, and calibrated wrist twist that
ignores arm swing. New geometry tests round-trip offset pointer rays through the
curved menu surface and reject backward/vertical rays; the compatibility shadow
policy excludes noncasting decoration.

The player harness uses the real scene, flight model, collision world and pooled
ecosystem. It feeds synthetic wing input for ten seconds, checks movement and
the game clock, then exercises pause, grace preservation, growth, life loss,
respawn and victory. It deliberately sets masses and invokes catches to reach
the apex quickly. These results verify lifecycle behavior; they do not establish
the pacing or feel of a complete natural sparrow-to-eagle playthrough.

## Simulator and visual checks

Meta XR Simulator **207** was configured as **Meta Quest Pro**, 72 Hz, with
both Touch Pro controllers tracked. The player selected its OpenXR runtime
through process environment variables. Logs identify the headset and each
left/right controller. Startup waits for valid tracking before placing the
world-space menu. The grip and aim poses are separate.

The menu, valley in flight and victory panel were inspected in both desktop and
XR captures. The valley geometry, water, vegetation, buildings and articulated
birds render with the Unity shaders. Panels fit the view and remain readable.
XR tracking stays active while the game is paused. The Mac player continues
updating while the simulator window has focus and explicitly stops and releases
the XR loader on quit.

Manual controller checks navigated the settings and tracking pages. An opt-in
input trace recorded trigger edges and the selected buttons in
`Logs/controller-ui-check.log`. This verifies menu input routing; complete
calibration and physical arm gestures still need a headset playtest. The
simulator's point-and-click cursor can differ from the OpenXR aim ray; the
highlighted button shows the actual ray target.

Captured images and JSON reports are in `Logs/comparison/unity-ui/`,
`Logs/presentation-desktop/`, `Logs/presentation-xr/` and `Logs/xr-evidence/`. Selected copies are retained in [screenshots](screenshots/)
and [reports](reports/).
Build and runtime logs are ignored by Git; source assets and these notes are
retained.

## Restored lighting and UI

The original missing shadows were an incomplete shader/rendering setup. The
revised URP asset enables one 2048-pixel hard-shadow map, one cascade and a 90 m
range, matching the source’s near-scene budget. The sun orientation reflects the
original day preset into Unity coordinates. Valley, water and near bird LODs
receive shadows; source scenery flags and 142 simplified tree shadow renderers
preserve cheap casting. Birds use the same HLSL articulation in visible/caster
passes. Water receives bridge shadows and its highlights respond to occlusion.

With a fixed village camera, the final desktop check found **15,679 pixels**
darkened by the sun shadows. At the lake/bridge camera, **1,498 water-colored
pixels** darkened when shadows were enabled. Both checks save native on/off PNGs.
The mobile Vulkan shader variants compile in the APK; this does not prove the
same quality or frame time on a physical Quest Pro.

The UI now retains the source Nunito 700/900 faces, emblem, species silhouettes,
faceted palette, original gesture illustrations, growth/lives, lesson progress
and hold-to-confirm feedback. Artwork is exported from the original drawing
routines into 12-frame transparent atlases. Native uGUI graphics are curved
without an extra camera or render texture, and pointer intersection uses the
same cylinder as the rendered vertices. Text reserves Nunito’s full line height;
the presentation harness verifies visible glyphs on every captured page.
Lessons and the status strip fade when covering a flight path, prey or threat.
Both synthesized pointer sources reach the actual controls, and tests confirm
that a short restart hold retains the run while a completed hold restarts it.
These checks exercise the real UI code; they do not replace physical aiming,
reading, or comfort testing on the headset.

The [comparison gallery](comparison/index.html) has new Unity recordings and
paired screenshots. Its previous first pass is preserved for before/after
inspection. Godot source and footage remain unchanged. UI captures use curved VR panels in both games. Godot’s harness selects its
VR mode with synthetic controller pointers; Unity’s non-XR capture uses desktop
instruction text. Spawn views and input paths differ.

## Frozen content

The importer consumes a frozen export of the original world: 10,347 meshes,
26,821 collider shapes, 1,189 perches, 453 landmarks, 371 openings, 296 refuges
and eight thermals. Collision baking produces 1,634 spatial mesh colliders.
Birds retain all three source LODs and four articulation channels.

`FrozenWorld.zip` SHA-256:
`c7dc269707598207f812cbf5e727b21e2fc1d9598d7893cfa6d74bf30a4b418d`.
The native assets ship with the project; rebuilding a player does not run Godot.

## Limits and device validation

The simulator checks functional OpenXR behavior on macOS. It does **not** run
the Android Vulkan player or reproduce the Quest Pro GPU, thermal limits,
display optics, controller ergonomics or real headset lifecycle. No physical
Quest Pro was connected during this work. Visual or performance improvement
over the Godot build therefore remains unmeasured.

On the headset, sideload the APK as described in the README, calibrate both
wings, play through the lessons, test perching/catches and pause/recenter, and
measure a sustained flight with Meta's device performance tools. The target is
72 Hz; verify CPU/GPU frame time, thermal stability and allocations before
raising scene quality or the NPC budget. The runtime governor can reduce NPCs
from 28 to 20. The Mac draw-call recorder returned zero and is unavailable for
that measurement; it does not mean the scene uses zero draw calls.

The release APK is signed with a development key for sideloading. Store delivery
requires the owner's signing key and store/device validation. The C# flight and
AI implement the original design and scalar rules, with fresh tuning; exact
frame-by-frame Godot behavior is not a claim of this port.

Non-fatal build diagnostics include package sample-cache notices and Unity/URP
compiler warnings. The final OpenXR validation reports zero errors and no
warnings. Runtime harnesses report no Unity errors or
exceptions. The simulator emits an analytics shutdown warning on this host;
the player still exits successfully.
