# Parked: "the world isn't visible on Quest"

**Status: unresolved.** Three hypotheses, three fixes, none of them the cause.
The reporter confirmed the symptom is unchanged after each. Recording what was
tested so the next attempt does not repeat it.

## The symptom

On a Quest Pro: the game appears correct for a moment after launch, then the
view becomes flat colour — blue when looking up, green when looking down, with
no visible detail. It does not recover. Reported as identical after every fix
below.

## What is definitely true

Measured on device, not inferred:

- The world renders. 55–86 draw calls, ~150k primitives, sustained.
- No shader corruption on device: `broken-shader pixels: 0.000%`.
- OpenXR reaches `XR_SESSION_STATE_FOCUSED`, stereo swapchains 1440×1584.
- Both controllers track; poses arrive in metres.
- 72/72 fps, zero stale frames.
- A headset-eye screenshot pulled from the device shows the world correctly:
  buildings, trees, arch, power lines, terrain.

That last point is the awkward one. **The device's own capture of what the
headset should be showing looks right, while the reporter sees flat colour.**
Nothing tested so far explains that gap, and it is the most important clue.

## Hypotheses tested and rejected

### 1. `VISIBILITY_RANGE_FADE_SELF` broken on the mobile renderer

*Theory:* every structure had a visibility range with dithered fade; the
terrain did not. A broken fade variant would delete exactly the structures and
leave exactly the terrain — matching "green ground, blue sky".

*Evidence for:* running the desktop build with `--rendering-method mobile`
showed heavy magenta corruption, which disappeared with the fade removed.

*Rejected by:* a fair warm-cache A/B showed no difference — magenta at
1.9/1.7/6.9% with fade off versus 7.5/2.8/2.3% with it on. The corruption is a
macOS/MoltenVK artifact of Forward Mobile on Apple silicon: blocky pink tiles
over the terrain, varying run to run with identical input, still present after
25 s. The same build reports 0.000% on real Quest hardware. **The magenta was
never present on the target device.** Noise was read as signal.

### 2. Folded wings flying the player into the ground

*Theory:* holding both controllers together is a full-tuck command, which from
spawn altitude is a power dive into terrain in ~4 s, leaving the player
face-down in a field looking at grass and sky.

*Evidence for:* device telemetry showed `span=0.00, perched=true, speed=0.0`,
position frozen at ground level for 40 s.

*Rejected by:* fixed, verified on device (`span=1.00, perched=false`), symptom
unchanged. Note the telemetry that motivated this came from a build predating
the fix being judged — the deploy was never verified (see below).

### 3. Gliding out of the world

*Theory:* a bird with no input never banks, so it glides dead straight and
leaves the 640 m populated radius in ~40 s. Device telemetry showed draw calls
collapsing 21 → 3 as the nearest building receded past 295 m.

*Evidence for:* reproduced locally over a 60 s run; nearest landmark reached
316 m with nothing else in view.

*Rejected by:* the reporter confirmed no change. This one is a **real defect
regardless** — the world genuinely runs out — but it is not this bug. Left for
the world-building work to solve properly (a larger or bounded arena) rather
than patched with the soft boundary that was reverted along with the rest.

**Fixed since, in the world-building pass**, and not with a boundary rule: the
arena is now closed by a 340 m mountain wall with more mountains rising behind
it, and structures are placed on a district-aware grid instead of scattered.
`WorldTests` walks all 720 bearings for a gap in the wall and ray-marches 96
bearings for a bare patch. The hands-still repro's furthest landmark went from
230 m to 71 m. It still fails, but now only on "spent the run on the ground",
which is a game-loop question (a bird given no input has to land eventually),
not a world one.

## Process failures worth not repeating

- **Deploys were never verified.** `build_stamp.txt` was not in the APK at all
  (Godot's `all_resources` filter skips plain text files), and `am start` on a
  running app only refocuses it, so the stamp was never reprinted. For most of
  this investigation there was no way to know which build was executing.
  `tools/deploy_quest.sh` now force-stops, enlarges the log buffer, polls for
  up to two minutes, and refuses to report success until it reads its own stamp
  back off the device.
- **Diagnosis ran ahead of reproduction.** The first two hypotheses came from
  telemetry and inference. The third came from a reproduction, and was still
  wrong — but it was wrong in a way that produced a real bug fix and a real
  test, which is the difference.
- **A repro that is too short is worse than none.** The 15 s hands-still repro
  passed while the failure was still unfolding at 40 s.

## Where to look next

Untested avenues, roughly in order of promise:

1. **The gap between the device capture and what the eyes see.** The mirror
   capture uses a plain `Camera3D` copying the XR camera's transform, so it
   proves the *scene* is fine but says nothing about what is submitted to the
   compositor. A per-eye readback, or `XR_ENV_BLEND_MODE`/layer inspection,
   would test the actual submitted frames.
2. **The `ViewRig` scale.** `view_rig.scale = Vector3.ONE * size` scales an
   ancestor of `XROrigin3D`. Godot builds the XR view transform from the
   origin's global transform; a scaled origin may produce a view or projection
   matrix the compositor handles differently from the mirror camera. Test by
   pinning scale to 1 and growing the collision radius alone.
3. **Near/far planes.** 0.05 m to 4000 m is an 80,000:1 range. Fine on desktop,
   potentially not with the Quest's depth format plus foveation.
4. **Foveation level 3 + dynamic.** Aggressive peripheral reduction; worth
   testing at 0.
5. **Ask what "no detail" means precisely.** Uniform flat colour, or the world
   greyed/washed out, or geometry present but untextured? Whether the horizon
   line is visible would separate "nothing rendered" from "everything rendered
   flat".

## Reverted with this document

Speculative fixes removed, since none addressed the reported bug:

- the mobile-only visibility-range fade split
- the magenta/broken-shader frame checker and its gate
- the first-spread grace span and its training-wheels state
- the novice rescue that relaunched a grounded player
- the soft boundary that turned the bird back

Kept, because each fixes a defect that was demonstrated independently:

- calibration completing on a timer (it previously dead-ended forever if the
  player never spread their arms past 40 cm)
- reach calibrated from any pose, wrist angle only from a wings-out pose
- ergonomic full-span threshold, so full wings do not require a locked-out
  arm span for a whole session
- the `pose_source` test seam, `HandsRepro`, the device diagnostic and the
  verified deploy script — all of which are how the next attempt gets evidence
