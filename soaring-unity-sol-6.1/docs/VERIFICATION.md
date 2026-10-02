# Verification · 2 October 2026

| Check | Evidence / result |
|---|---|
| Editor/runtime | Unity 6000.6.4f1 CLI; pinned OpenXR 1.18, Meta OpenXR 2.6.1, mobile URP |
| Unit/geometry/progression suite | 24/24 passed; `evidence/final/tests.xml` |
| Native Mac build | ARM64, zero errors, two upstream URP shader warnings; ad-hoc signature verified |
| Quest APK | Zero errors, eight upstream build warnings; ARM64 IL2CPP/OpenXR; APK signature v2 verified |
| APK platform | `com.soaring.sky`, minimum API32 / target36, VR launch category, required head tracking, `cambria` Quest Pro supported |
| Simulator | Live Meta XR Simulator207.0 OpenXR display; Quest Pro Touch Pro left/right controllers discovered |
| VR menu input | Simulator mapped primary A/X button opens prompted calibration; controller ray and stick navigation implemented |
| Flight checks | Strong immediate flap lift; relaxed glide; tucked acceleration/dive; extension lift burst then drag; nonlinear turn deadzone; size speed/weight; updrafts; heading-relative takeoff |
| World checks | Bounded arena, relative swept catches, clear spawns, visible recycled NPCs; 72 fixed actors; live NPC peer hunting/fleeing and player hunters observed |
| Loop checks | Explicit synthetic calibration/start, real contact catch, mass gain, frozen pause, clean restart, actual ordered crown crossings and victory; all seven runtime assertions passed |
| Visual QA | Final home, tuning, calibration, active flight/HUD/threat, pause, death, apex and victory screenshots inspected under `evidence/final/` |

Smoke pose injection and accelerated apex setup happen only with explicit command-line flags. Goal completion tests move through actual gate volumes. Normal play requires prompted human calibration and earning growth through catches.

The simulator executes the native Mac player rather than Android APKs. No physical Quest was connected (`adb devices` empty). Device installation, physical flight feel, ergonomic comfort, binocular size perception, suspend/resume behavior, and sustained Quest Pro CPU/GPU/thermal performance remain unverified. They are validation gaps, separate from reviewed source issues.

## Simulator performance

Isolated 45-second run after builds completed, Quest Pro profile at72Hz, stationary camera with the full ecosystem active and no capture. Ten-second windows averaged **13.89–13.97ms**, around71.6–72fps; maximum intervals14.22–27.78ms. Rendered triangles around18.8–19.1k. Final population70 alive of72 pooled actors, with hunting/fleeing states present. `evidence/final/benchmark.txt` records this run.

This measures host simulator frame intervals rather than Quest GPU/CPU frame time. Startup and screenshot readbacks produce larger stalls and are excluded from this benchmark.

## Known low-severity issues
- Unity URP reports potentially uninitialized LightingPhysicallyBased shader variables; Unity IL2CPP reports TextMeshPro compile-layout recommendations. Builds succeed; no rendered corruption observed.
- Thin distant rings can alias in the simulator mirror.
- This host's draw-call recorder returns0; frame intervals and rendered-triangle counts are usable. Draw-call count is not claimed as measured.

No critical, significant or medium source issue remains in the reviewed implementation. Human Quest acceptance remains outstanding.
