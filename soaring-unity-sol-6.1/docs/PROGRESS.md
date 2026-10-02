# Progress

## Milestones and acceptance
1. Flight slice: compile; deterministic tests prove strong flap lift, extension balloon/drag, turn dead zone, size handling; calibrate explicitly; live Quest Pro OpenXR session with one catchable bird; tuning available in VR. Simulator evidence is separate from physical device testing.
2. World/ecosystem: closed arena, obstacles/windows/nests/branches/wires/updrafts; mixed flock seeks/flees player and peers; respawn keeps easy food available; bounded population; screenshots and behavior checks.
3. Loop/UI: calibrated start, eat/grow/death/restart/pause/settings, editable pacing, apex ring goal, haptics; automated progression checks and simulator menu review.
4. Polish/performance: readable low-poly art, comfortable level horizon, size/world scale transition, pooled NPC visuals, measured simulator frame timings, Quest APK build; no known medium-or-higher source issue. Physical headset flight feel/performance remain unverified until human playtest.

## Bootstrap
Reviewed `../vr-unity-example` findings and adopted pinned native OpenXR/Meta profile/mobile renderer and Mac loader workaround. Root owns core; independent world and UI work delegated against ARCHITECTURE.md.

## 1 · Flight slice verified (2 October 2026)
- Unity CLI build: native ARM64 Mac app succeeded, zero build errors/warnings. OpenXR settings validation zero errors.
- 16/16 automated flight/world tests passed.
- Live Meta XR Simulator 207.0 session: Quest Pro profile, left/right Touch Pro controller devices; mapped A/X button opened prompted calibration.
- Explicit synthetic calibration smoke: calibrated=true, playing=true, one bird; contact caught the bird and increased mass; pause held position/time. Captures in `docs/evidence/slice/` inspected for readability and scene rendering.
- First slice includes flight lab on day one: 31 ranged parameters, presets/save/load/fine controls.
- Simulator verifies integration. Physical headset flight feel and comfort remain a required human acceptance step.

## 2 · World and ecosystem verified (2 October 2026)
- Saved scene now enables full arena: 24 cedar trees with branches, 5 hollow towers, power lines, tight nest entrances, 5 skill gates, 3 updrafts and 3 ordered apex crowns; closed bounds at all growth sizes.
- 72 NPCs, staggered decisions, player/peer hunting and fleeing, bounded recycled population, swept catch detection and nearby food replenishment. Recycled renderer visibility fixed during review.
- Full Quest Pro simulator smoke: 72 birds; catch increased mass; pause froze position/time; death, restart and apex victory APIs passed. `docs/evidence/ecosystem/` screenshots inspected. Smoke calibration and apex acceleration are explicitly synthetic verification, not human pacing evidence.
- Expanded tests 20/20 pass, including tucked acceleration/dive, size-gated eating, uncalibrated start rejection and growth targets under a stated synthetic catch rate.
- Tucking now accelerates beyond relaxed glide. Early growth boost/late growth factor and apex navigation added.

## 3 · Core loop and UI verified (2 October 2026)
- 23/23 automated tests pass. Menu calibration guards/presets/defaults and progression checks added. At the declared synthetic rate (one 60%-size catch each 15s), defaults reach 1.2× within 2min, 2.2× within 5–8min, and 4.6× within 20–30min. Human pacing remains unmeasured.
- Native Quest Pro smoke checks: catch increases mass, pause freezes flight and run clock, death screen, clean restart, apex accessible, ordered spatial crossings of the three crown gates yield victory. Captures `docs/evidence/loop/` inspected, including apex navigation and death/victory panels.
- In-game developer menu now exposes 35 values; controls remain readable at every size, saved presets and comfort/haptic toggles persist. Camera maintains a flight-level horizon; growth scales tracked space smoothly around the head.
- Review corrections: startup panel placement, heading-relative takeoff/food, desktop mouse/arrow interaction, solid-free NPC spawning, preset-aware NPC speed advantage, and blue neutral birds distinct from edible gold/coral predators.
- Removed unused imported tutorial/sample scenes and controls; retained mobile URP, OpenXR loader workaround and native Quest build profile.
