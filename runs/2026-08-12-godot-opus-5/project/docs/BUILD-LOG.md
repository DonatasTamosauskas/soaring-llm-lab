# Build provenance: the overnight v1 pass

The workflow's integration agent initialised a nested git repository inside the
project directory, unaware that the real history lives one level up. Its commit
log is preserved here and the nested repo removed, so the work lands as one
commit in the repository that actually holds this project's history.

## README: assertion count 10634

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

## world: drop spokes as the rings come in, and pin the mesh watertight

A fixed 320 spokes was the same mistake as a fixed 15 m grid, at the other end
of the disc: under the town the triangles were fifteen metres long and thirty
centimetres wide, and from 360 m up the bowl showed a pinwheel radiating out of
the spawn point. The count now halves whenever neighbours get closer than 8 m,
which holds the tangential step between 8 and 16 m from the town to the massif,
and rings of different counts are stitched with a three-triangle fan.

That stitch is the kind of thing that fails silently and leaves slots in the
ground a bird falls through, so WorldTests now counts how many triangles use
each edge: every edge shared by exactly two, and exactly TERRAIN_SPOKES open
ones where the disc ends. Dropping one triangle of the fan takes that from 320
to 1250 and fails.

Cheaper as well as better: 533k vertices and 589 ms, from 567k and 659 ms.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

## integration: README describes the game as it now is, plus a Quest section

- All five gates listed, with tests/all.sh at the top and why it exists.
- Audio documented for the first time, in the README and in docs/AUDIO.md.
- A "Putting it on a Quest" section: what deploy_quest.sh does, what it needs,
  how to read the diagnostic back off the device, and the flat statement that
  nothing here has ever run on a headset.
- Removed the reference to tests/mobile_check.sh, which does not exist and
  cannot usefully exist on this machine: the project already renders through
  Forward Mobile everywhere and macOS/MoltenVK paints spurious magenta, so a
  magenta check would fail on platform noise. Said so rather than deleting the
  paragraph silently.
- The prey chevron in the HUD follows the prey tint to cyan; the two are one
  statement and had drifted apart.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

## integration: fix the five things that looked broken in a frame

Every one of these came from reading a rendered PNG, and each has a before/after
number or picture.

- Terrain is built on rings and spokes instead of a square grid. The rim wall
  climbs 340 m across 180 m of ground, which on 15 m quads is one quad wide and
  45 m long down the slope — the whole horizon rendered as a comb of vertical
  needles, and it is the biggest object in nearly every frame. Radial resolution
  is now 6 m on the wall and 15 m in the bowl, which comes to roughly square
  facets on a 65-degree face. 567k vertices against a 800k budget (was 460k),
  659 ms to build (was 472 ms).
- The flock was invisible. Prey and peers are now dealt into a near band
  (55-190 m); predators still arrive from a distance, because an ambush you
  could not have avoided is not a threat. Measured with a new flock line in
  DeviceDiagnostic: nearest bird 165 m at 0.48 degrees before, 56-65 m at
  1.3-2.6 degrees after, with 1-3 birds inside 80 m instead of none. The hunt
  gate reads 0.70 catches/min against 0.60, and the first catch arrives at
  60 s instead of 175 s.
- --sky=evening was an opaque amber wash that erased the rim and the districts
  from 360 m up. The fog was the sky's own colour at nearly twice morning's
  density; it is now a dusty mauve at 0.00048 with a shallower valley layer, and
  the sun is no longer brighter than noon.
- The prey tint is cyan, not green, and as strong as the predator tint. Green on
  a green hillside at 40 m was not there at all while red was obvious — half a
  signal. Cyan appears nowhere in the land and, unlike green, separates from red
  for a red-green colourblind player. tests/aviary.gd gains a threat-far shot
  that asks the question at the distance it matters.
- HUD text was sized in em boxes against a 1.4-degree floor, which passed a
  0.9-degree capital. UITheme now states the floor as a cap height and UITests
  measures it there, for the menus as well; the three HUD fonts went up by half
  again.

tests/all.sh: all five gates pass. run.sh 10630 assertions.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

## integration: test the strike rule, close the perched-hunter vacuum, gate hunting

- GameRules.within_strike required no motion, so a bird with no heading struck
  in every direction at once: a perched player ate anything smaller within
  reach from any bearing, and roosting NPCs did the same inside the communal
  roosts Flock builds. Hunters must now be flying (MIN_STRIKE_SPEED). NaN sizes
  no longer slip past the range check via a NaN comparison.
- GameRulesTests gains 67 assertions on the cone (on-nose, 90-degree slide-past,
  the 44-degree boundary), on reach at real closing speeds (19.8 m for a size-5
  stoop, not the 10.8 m the old bound measured at a standstill), on the perched
  case, and on hostile input. Proof: STRIKE_COSINE = -1.0 now fails 10
  assertions; restoring the perched fallback fails 17.
- tests/hunt.sh is a new gate. Ten minutes of SessionProbe flying the real game
  must convert chases: 6 catches now, 2 required. With the awareness constants
  reverted to 95 m / never-tires it returns 1 and fails, while all four other
  gates stay green — which is exactly the hole the reviewers found.
- AudioTests (tests/test_audio.gd, ~1250 assertions) registered in run_tests:
  ~1800 lines of shipped audio had no assertions at all. docs/AUDIO.md written.
- AudioDirector placed the town bed before adding it to the tree, printing an
  engine error on every launch. Fixed; the comment and the test say honestly
  that the placement itself was never wrong, because the director is a plain
  Node and breaks the transform chain.
- tests/all.sh runs all five gates and fails on any of them.

run.sh 9363 -> 10624 assertions, ALL PASS. probe.sh, ui.sh, firstcontact.sh,
hunt.sh all pass.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

## Soaring: eight areas of build — arena world, art direction, bird assets, game loop, enemy AI, UI and flow, VR comfort, audio

Baseline commit of the whole tree as built area by area, so subsequent
integration work is diffable. Gates at this commit: run.sh 9363 assertions
ALL PASS; probe.sh, ui.sh, firstcontact.sh status recorded in the integration
report.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>

