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
