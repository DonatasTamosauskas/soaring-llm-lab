# Validation and acceptance

This is an implemented, playable v1. “Perfection” is a playtesting judgment, not a property that synthetic tests can prove. The checks below establish working mechanics, geometry, progression, integration and actual simulated XR input. Comfort, fatigue, haptic strength, controller occlusion and sustained Quest GPU performance remain unverified until physical playtesting is completed.

## Evidence gates

| Area | Validation | Evidence |
| --- | --- | --- |
| Flight |83 checks: strokes at multiple frame rates, jitter/crouch/head-motion rejection, pose discontinuities, incidence/ballooning, stall, tuck/brake, coordinated bank, thermals, growth, pause, tracking recovery, collision and branch perching | `artifacts/flight.log`, `tests/test_flight.gd` |
| World |274 checks: physical rays/sphere routes through windows and nests, solid adjoining walls,175 perches, terrain bounds, thermals, batching budget and all mesh vertices/normals/indices | `artifacts/world.log`, `tests/test_world.gd` |
| Food web |59 checks, including 120 seconds in the actual world: NPC-on-NPC catches, Hunt/Flee/Cruise/Soar/Perch states, replenishment, relevance-based growth, swept encounters, wall occlusion and zero underground samples | `artifacts/ecology.log`, `tests/test_ecology.gd` |
| Complete game |45 checks: actual main scene, menu widget signals, run/reset/caught, growth signals and progression to Sovereign, pause momentum, frozen ecology, delayed calibration, tracking-loss pause, desktop and XR layouts | `artifacts/game.log`, `tests/test_game.gd` |
| Art and UI | Seven rendered viewpoints inspected: nest, valley, quarter, grove, flight HUD, field guide and pause; separate Mobile/Vulkan stress renders and mesh audits | `artifacts/*.png`, `artifacts/verification.json` |
| Actual XR | Running Quest Pro simulated OpenXR session reaches FOCUSED; real controller ray+trigger launches, bilateral natural strokes flap, asymmetric hand heights bank, A/X does not repeat, left Menu pauses/resumes, paused head tracking stays live | `artifacts/xr-verification.json`, `tools/verify_xr.py` |
| Packaging | Godot Android Gradle export, APK signature, ARM64 libraries, OpenXR and Meta VR manifest entries, excluded tests/artifacts and restricted permissions | `artifacts/export.log`, `artifacts/apk-verification.json` |

The four subsystem suites contain 461 checks in total. Actual XR has 17 interaction/runtime checks; packaging has 12 checks. The numeric results and runtime counters live in the JSON evidence. The simulator runs the desktop build with real OpenXR stereo rendering and simulated controllers. It does **not** execute the Android APK and cannot validate headset GPU performance. Local XR PNGs come from a separate monoscopic spectator camera because reading the simulator swapchain through the regular viewport texture is unreliable. The simulator's actual eye view was inspected separately.

The final 60-second simulator interaction run averaged 64.8 reported FPS on this Apple M1 Pro, with 72 Hz physics, 3 NPC catches and 54 birds remaining. This does not meet a sustained 72 FPS rendering target on the host; simulator responsiveness is usable for input and visual validation, while performance acceptance stays open. The renamed Android app was installed and launched on a physical Quest Pro on 2026-10-04; sustained rendering performance has not yet been measured.

## Headset installation and startup

On 2026-10-04, **Soaring godot-sol** (`com.soaring.godotsol`, version 1.0.0 / code 10) was installed on the connected ARM64 Quest Pro. ADB returned `Success`; the exported `com.godot.game.GodotAppLauncher` alias launched with `Status: ok`, and the process remained running. Its own log confirms Godot 4.7.2, Mobile/Vulkan on Adreno 650, initialized OpenXR and `SOARING_READY` with all 54 birds and the complete world. No Godot script/parse error or fatal startup exception was found. This verifies installation and native XR startup, not physical playtesting, visual comfort or sustained performance. Evidence: `artifacts/quest-install-runtime.log` and `artifacts/quest-installation.json`.

The base `GodotApp` activity is intentionally not exported. Use the exported `GodotAppLauncher` alias in ADB commands; the README now uses the correct entry.

## Reproducible workflow

1. `python3 tools/verify.py --visual`: import and all four suites, then a 96-frame moving-camera Mobile/Vulkan probe and seven sequential render captures.
2. Inspect the seven PNGs and the actual simulator view. Geometry checks do not detect every GPU rendering artifact.
3. With Quest Pro / 72 Hz selected in Meta XR Simulator, run `python tools/verify_xr.py` from the environment described in the README. It observes the runtime's advertised RPC port, drives transient controller input and saves both checks and samples.
4. Export the APK and run `python3 tools/verify_apk.py artifacts/soaring-godot-sol-quest.apk`. The verifier inspects the signing status, manifest, native libraries and exported project contents.
5. On hardware, complete the acceptance sessions below. Tune coefficients and comfort based on those results, then repeat the relevant regression suite and actual XR test.

The implementation is split into flight, world and ecology modules, developed and checked independently in temporary projects before main-scene integration. Shared-project imports and tests are sequential. Runtime screenshots, logs and test reports are deliberately outside the exported game resources.

## Defects discovered and corrected

- Simulator-reported controller velocities stay zero: derive stroke velocity from tracked position samples instead.
- Startup tracking poses can be placeholders: defer neutral calibration until both real grip poses exist; auto-start waits for focused XR.
- Pointing at calibration distorts the neutral pose: use a two-second countdown so elbows can return to rest.
- Pausing an ordinary node stops headset tracking: tracked rig, menu rays and UI always process while physics/ecology freeze.
- Open windows must be genuine gaps: colliders are built around openings and swept body clearance is checked.
- A fast catch can tunnel or cross a wall: sweep previous/current positions and confirm line of sight at encounter contact.
- Perching on thin branches needs support probes: preserve a resting contact until an intentional takeoff.
- Large birds should not alter real-world tracking scale: grow hull and wing geometry while keeping the XR origin at scale 1.
- Mac simulator Mobile/Vulkan intermittent magenta tiles: moving-camera captures found tiny thermal decorations, and the final moving stereo check also exposed artifacts around small birds. Valid indexed meshes and removing the optional leaf decoration did not eliminate the host stereo problem. Use Forward+ on macOS, with 2× MSAA and 65% internal resolution, and retain Mobile, 4× MSAA and full resolution on Android. Inspect both real simulator eyes while birds move. Thermal physics, gold spirals and ground markers are unchanged; the Android stereo renderer still requires hardware acceptance.
- A diagnostic spectator viewport doubled render work: it now renders only the single requested capture frame.

## Engine shutdown diagnostics

Godot 4.7.2 emits a nonexistent spatial-discovery disconnect when closing an initialized OpenXR session. This is also documented in the engine's [minimal-project issue 122238](https://github.com/godotengine/godot/issues/122238). The tested runtime also reports interaction-profile RIDs at engine exit. Both occur after the successful smoke report; neither was seen during gameplay. The XR verifier records those exact diagnostics and fails for any other engine error, or if either occurs before the game completes. They are not suppressed from the logs. A future engine update should be retested with these exceptions removed once it fixes teardown.

## Physical Quest Pro acceptance

| Session | Required observations |
| --- | --- |
| First launch, standing and seated | World scale feels natural; neutral wrist calibration works; both menus are comfortably readable/selectable; no startup jump. |
| Ten minutes of compact flight | Short flaps climb reliably; grips sustain a relaxed glide; thermals and perches allow rest; no need for sustained extended arms. Record fatigue and any nausea. |
| Incidence and speed | Wrist tilt produces predictable climb ballooning followed by drag; tuck trades height for speed; slow spreads give controlled window/perch approaches. |
| Turns and precision | Differential wings turn in the expected direction; snap turns work once per deflection; pass windows, nest mouths, poles and branches without collision surprises. |
| Full food-web round | Wren→Swift→Kite→Eagle→Sovereign changes agility; tiny prey stops mattering; NPCs visibly chase one another; results and restart restore the initial state. |
| Tracking and lifecycle | Brief hand occlusion does not add lift; prolonged loss pauses; recovery/calibration work; headset removal/focus loss pauses without stopping head tracking. |
| Twenty-minute performance run | Use headset performance metrics: stable target refresh, frame timing, thermals, CPU/GPU load and battery behavior in the grove, quarter and busy predator encounters. |
| Feedback and comfort | Haptics feel appropriate; sound mix is audible without fatigue; wrist HUD is readable and does not obstruct flight; compare comfort on/off. |

Do not mark these hardware gates complete based on simulator screenshots or synthetic poses.
