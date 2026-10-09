# SOARING · Crown of the sky

A body-driven VR bird game for Meta Quest Pro, built with Unity 6.6. Flap to climb, fold in to accelerate, spread briefly to balloon and brake, lower one hand to bank. Catch smaller golden birds, escape coral hunters, and grow until the sanctuary feels tiny. At apex size, fly the three crown gates.

## Run

Unity project: **Soaring/**. Pinned editor **6000.6.4f1**. OpenXR, mobile URP and Meta Quest Android profile are included. The Mac simulator app and Quest APK are generated under **Builds/**, excluded from Git.

To play the current build, run `./scripts/run-simulator.sh`. The saved scene and final builds use the full ecosystem.

With Unity closed, to rebuild or deliberately revisit the slice:

```sh
./scripts/unity.sh setup          # Recreates the one-bird flight slice scene
./scripts/unity.sh test           # Flight and ecosystem EditMode checks
./scripts/unity.sh build-mac
./scripts/run-simulator.sh        # Native app using installed Meta XR Simulator
./scripts/unity.sh full-world     # Enables complete 72-bird ecosystem in scene
./scripts/unity.sh build-mac
./scripts/unity.sh build-android  # Builds/Soaring-unity-sol-6.1.apk
```

Use `./scripts/unity.sh play` for Unity Editor Play in Meta XR Simulator. Only one simulator client should run. Select **Quest Pro** in the simulator Inputs device panel, then restart the player. The simulator runs the native Mac app; it does not execute the Android APK. The runtime marker `QUEST_BOOTSTRAP_XR_RUNNING` and both Quest Pro controller device lines establish XR connection, not a flat window alone.

For a physical Quest with Developer Mode enabled and paired adb: `adb install -r Builds/Soaring-unity-sol-6.1.apk`. Installed app name **Soaring Unity-Sol 6.1**, application ID `com.soaring.unitysol61`; development signing. No headset is required for the Mac simulator.

## Controls and calibration

- Menu: point either controller at a button and press trigger; or use either stick up/down to focus, A/X to select. B/Y or Menu opens pause. Left/right stick adjusts tuning; hold right grip for finer steps. Golden birds are edible, coral birds can eat you, and blue birds are too close to your size to eat.
- Calibration is required before flight. Sit or stand comfortably: upper arms down, forearms out. Select capture, then hold the pose through the three-second countdown. Next briefly extend both arms for the second capture. If the spans are too similar, retry extension.
- Fast downstrokes give lift and forward power. Relaxed calibrated wings sustain a glide. Bring arms inward for speed; fully extend for a brief balloon followed by slower flight. Lower the right hand to turn right, left hand for left. Head gaze is free; the flight rig never pitches or rolls.
- Teal thermal wisps lift without flapping. Coral hunters have a warning crown and a HUD bearing/distance alert before they can catch you. Same-size birds cannot eat each other; catches require a 12% size margin.
- Collisions slide and slow you; there is no impact death. The arena boundary contains flight at all sizes. Growth gradually scales tracked space around the head, making the world shrink without a camera jump.

Desktop preview: `./scripts/run-simulator.sh --desktop`. Space flaps, A/D banks, E extends, Shift tucks, left/right arrows look during flight. Mouse or arrows/Enter operates menus. Hold E during the extension calibration countdown. This is a development fallback; VR uses tracked arms.

## Tuning

The developer menu is available from the home and pause panels. It exposes every ranged flight parameter: cruise/max speed, acceleration, flap threshold/lift/thrust/cooldown, gravity/glide, extension balloon duration/drag, dead zone/curve/smoothing/turn rate, climb/vertical drag, size handling, updrafts, growth nutrition/apex size, hunt telegraph/grace and haptics. Changes apply immediately. Comfort, Arcade and Heavy presets provide starting points. Save persists to Unity's app data; Load restores; defaults are available.

Pacing defaults aim for visible growth on the first catch, mid-size around 5–8 minutes and apex around 20–30 minutes at a moderate catch rate. These are **playtest targets**, not measured human completion times. Nutrition plus early/late growth factors control growth per catch, NPC speed controls chase difficulty, and apex size controls run length. A deterministic test reaches those checkpoints with one 60%-size catch each 15 seconds; this rate is a test assumption. See docs/PROGRESS.md for measured checks and outstanding validation.

Run `./scripts/run-simulator.sh --benchmark` for a stationary-camera, active-ecosystem 45-second frame-interval benchmark. Run it after builds finish; the simulator uses its selected refresh rate. Logs report intervals and triangles; this host does not report reliable draw-call counts.

Run `./scripts/verify-simulator.sh` for explicit synthetic calibration, real swept catch/spatial gate tests and screenshots; it exits nonzero on a failed check. Quit the previous player before launching it. Normal play never injects these test poses or accelerates growth.

Shared ownership and units: docs/ARCHITECTURE.md. Source/license attribution: THIRD_PARTY_NOTICES.md. The setup was adapted from ../vr-unity-example; advanced Meta services/eye tracking are not required.

## Presentation

The sanctuary uses layered faceted mountains, a winding brook, varied meadow and canopies, warm sandstone village towers with terracotta roofs, woven branch nests and carved mint/coral flight gates. Golden crowns remain the apex goal. Player wings have navy primary feathers, teal coverts and ivory tips; NPC birds have faces, breasts, tails and separated flight feathers. Shared scenery is combined into spatial material chunks, and each NPC retains two animated wing meshes.

The world-space menus use rounded navy/cream cards, illustrated calibration poses, a six-card flight guide and live flight-lab gauges. The compact HUD shows the next growth checkpoint, airspeed, catches and hunter bearing. Catch feathers and bell notes reward contact; soft wind and wing rustles support flight. Settings include off/soft/full sound levels. Screenshot evidence and validation limits are recorded in docs/VERIFICATION.md.

## Showcase video

The local deliverable is `Videos/Soaring-showcase.mp4`: 60 seconds, 1920×1080 at 30 fps, H.264/AAC with captions, game effects and an original procedural score. Reproduce it with the native simulator build and one simulator client:

```sh
./scripts/unity.sh build-mac
./scripts/run-simulator.sh --showcase "$PWD/Logs/showcase-capture"
python3 scripts/edit-showcase.py
```

The editor requires Python with NumPy and ffmpeg; use `--ffmpeg` to select a different binary. On this host the bundled Python is `/Users/don/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3`. Capture frames and generated video files are excluded from Git. A manifest beside the MP4 records capture events, provenance and encoded format verification.

The footage is rendered live by Unity under Meta XR Simulator with curated takes and scripted wing inputs through the real flight model. Contact catches and crown crossings use the game collision/goal systems; progression between takes is accelerated, and threats are staged with extended safety grace. A mono camera provides a clean showcase view. The video visibly discloses scripted controls and accelerated progression. It is presentation footage, not human flight-feel or physical Quest performance evidence. The capture harness is attached only with `--showcase`, and its temporary tuning changes are not saved.
