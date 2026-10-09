# Verification · 2 October 2026

| Check | Evidence / result |
|---|---|
| Editor/runtime | Unity 6000.6.4f1 CLI; pinned OpenXR 1.18, Meta OpenXR 2.6.1, mobile URP |
| Unit/geometry/progression suite | 24/24 passed on revised source; `evidence/polish/tests.xml` |
| Native Mac build | ARM64, zero errors, four upstream warnings; ad-hoc signature verified |
| Quest APK | Zero errors, six upstream build warnings; ARM64 IL2CPP/OpenXR; APK signature v2 verified |
| APK platform | `com.soaring.sky`, minimum API32 / target36, VR launch category, required head tracking, `cambria` Quest Pro supported |
| Simulator | Live Meta XR Simulator207.0 OpenXR display; Quest Pro Touch Pro left/right controllers discovered |
| VR menu input | Simulator mapped primary A/X button opens prompted calibration; controller ray and stick navigation implemented |
| Flight checks | Strong immediate flap lift; relaxed glide; tucked acceleration/dive; extension lift burst then drag; nonlinear turn deadzone; size speed/weight; updrafts; heading-relative takeoff |
| World checks | Bounded arena, relative swept catches, clear spawns, visible recycled NPCs; 72 fixed actors; live NPC peer hunting/fleeing and player hunters observed |
| Loop checks | Explicit synthetic calibration/start, real contact catch, mass gain, frozen pause, clean restart, actual ordered crown crossings and victory; all seven runtime assertions passed |
| Visual QA | Revised home, tuning, six-card tutorial, sound/comfort settings, both calibration poses, active flight/HUD/threat, pause, death, apex and victory captures inspected under `evidence/polish/` |

Smoke pose injection and accelerated apex setup happen only with explicit command-line flags. Goal completion tests move through actual gate volumes. Normal play requires prompted human calibration and earning growth through catches.

The simulator executes the native Mac player rather than Android APKs. No physical Quest was connected (`adb devices` empty). Device installation, physical flight feel, ergonomic comfort, binocular size perception, suspend/resume behavior, and sustained Quest Pro CPU/GPU/thermal performance remain unverified. They are validation gaps, separate from reviewed source issues.

## Initial simulator performance (before visual revision)

Isolated 45-second run after builds completed, Quest Pro profile at72Hz, stationary camera with the full ecosystem active and no capture. Ten-second windows averaged **13.89–13.97ms**, around71.6–72fps; maximum intervals14.22–27.78ms. Rendered triangles around18.8–19.1k. Final population70 alive of72 pooled actors, with hunting/fleeing states present. `evidence/final/benchmark.txt` records this run.

This measures host simulator frame intervals rather than Quest GPU/CPU frame time. Startup and screenshot readbacks produce larger stalls and are excluded from this benchmark.

## Known low-severity issues
- Unity URP reports potentially uninitialized LightingPhysicallyBased shader variables; Unity IL2CPP reports TextMeshPro compile-layout recommendations. Builds succeed; no rendered corruption observed.
- Distant thin cable and gate edges can alias in the simulator mirror.
- This host's draw-call recorder returns0; frame intervals and rendered-triangle counts are usable. Draw-call count is not claimed as measured.

The initial visual acceptance was reopened following user review. The revised scene and UI are evaluated through fresh runtime captures in addition to functional checks. Human Quest acceptance remains outstanding.

## Visual corrective pass

Initial functionality checks did not establish the requested visual quality. The corrective pass replaces triangle canopies and cube perimeter scenery with layered faceted vegetation, a sculpted meadow/brook and a continuous two-layer mountain backdrop. Village towers have terracotta roofs, trim, shutters, balconies and clear fly-through openings; nests rest on branches. Skill gates have mint/coral frames; apex crowns remain gold. Bird heads, eyes, breasts, tails and separated feathers improve silhouettes. Tracked player feathers are smaller and stay outside the central sightline in the recorded relaxed simulator pose.

Sky, ambient light and fog use a coherent warm/cool palette. The sky and air shaders include stereo-instancing support. Sparse animated thermal wisps replace static sky curves. Catch particles, pentatonic bells, feather rustles and quiet wind provide feedback; sound has persisted off/soft/full settings.

Menus have rounded navy/cream cards, clear focus, illustrated pose capture, a six-card tutorial and live tuning gauges. The HUD uses separate chips, growth toward the next size checkpoint, a legible goal ribbon, catch feedback and hunter bearing/distance. Runtime screenshots were inspected twice; the second pass fixed horizon gaps, foreground feather occlusion and goal contrast. All seven gameplay assertions still pass; no runtime exceptions or shader errors were logged.

Scenery is combined by material in 90m spatial cells while preserving collision geometry. Each bird uses at most seven renderers including its warning marker and independent animated wings. Startup recorded 251 active renderers before NPC creation; the bounded population adds at most 504. The draw-call recorder remains unreliable; no measured draw-call claim is made.

The revised build's isolated 45-second Quest Pro simulator run averaged **13.91–14.03ms** in ten-second windows (about71–72fps), with maximum intervals **27.78–28.26ms**. All72 NPCs remained alive at completion, with peer hunt/flee states present. `evidence/polish/benchmark.txt` contains the original logged measurements. Triangle samples ranged from149,228 to319,480, but one window reported0; that counter is intermittent and is not used as a performance acceptance measure. These are host frame intervals, not sustained Quest Pro GPU/CPU measurements.
