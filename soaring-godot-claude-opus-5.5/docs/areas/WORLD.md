# World area — the valley

Where the birds live: a closed alpine valley ~1.36 km across, generated at
load from `world_seed` in ~1.2–1.4 s headless on the M1 Pro (a shared host
at load 8–11), 1.37–1.41 s in a rendering run and 1.50 s in the Meta XR Simulator. Low-poly and flat-shaded, built for Quest
budgets, with moving air you can soar on.

Root: `scenes/world/world.tscn` → `SoaringWorld` (extends the `World`
contract class). Find it with `World.find(get_tree())`.

## Integration round 1 (the integration fixer, 2026-09-27)

- **Depth-buffer headroom on the Quest** (the Quest verifier's major
  finding). The Quest's Mobile renderer draws into a 24-bit fixed-point
  depth buffer (this Mac uses a float one, so no screenshot here shows it):
  one depth step at view depth z is z^2 / (near x 2^24), and a sparrow's near
  plane is a few millimetres. VR doubled the near plane (0.06 x world_scale,
  `WorldScaleDriver.NEAR_K`); the valley removed its near-parallel pairs:
  - *shores:* the lake bed drops `WorldTerrain.SHORE_DROP` (1.3 m) under
    the water just inside the shore and the bank rises `SHORE_RISE` (0.7 m)
    over it just outside (was 0.5 / 0.3, and the river bank +0.2): the bank
    crosses the water line at ~14-20 deg instead of ~6, so the band where
    water and bank are within two depth steps is ~2.5x narrower;
  - *paving:* the street and square slabs' top is `PAVING_TOP` 0.2 m over
    the ground (was 0.1; the bridge ramps land on it);
  - *the bridge deck's cobble strip* is 12 cm proud of the deck (was 5).
  `tests/unit/integration/depth_precision_test.gd` casts the eye's rays
  through the colliders (the drawn geometry, for the merged meshes) from
  eight real viewpoints at the sparrow's near plane: no parallel surfaces of
  distinct bodies within two steps under 300 m (the street slab over the
  grass was 349 px at round 0 in the view from 60 m up), the risk between
  distinct bodies under 0.5 % of every view (0.01-0.29 %), shores crossing
  at >= 12.5 deg. Pairs within one body (a tree's collider capsules, rails
  on their posts, the farm's roof boards) are printed for the record: most
  are one colour; a check on the device is still due.
- **Water is not ground** (the experience verifier: the bird stood on the
  lake). Additive API: `World.is_water(pos)` (base: false; the valley: at
  the water line, within `WATER_BAND` 0.35 m, where the terrain lies under
  it). Flight splashes off it (`docs/areas/FLIGHT.md`).
- World suite: 39 of 39 after the changes. The world's `world_code` hash
  changed (the game loop's evidence records it).

## Integration hygiene (the integration agent, 2026-09-27)

A scan of every triangle the valley draws for overlapping parallel faces
(`tests/shots/integration_coplanar_scan.gd`, pinned by
`tests/unit/integration/coplanar_test.gd`; INTEGRATION.md §10.3) found 307
exactly coplanar spots of two colours (they fight in the Quest's 24-bit
depth buffer at every distance and size) and 3,289 within 5 mm. Fixed,
each marked "integration hygiene" in the code, the kits' random streams
consuming exactly as before (every other piece byte-identical):
- `TreeLib._seg(..., parent_col)`: a piece's hidden start (inside the piece
  it grows from, 1-4 mm under its surface) is drawn in the parent's colour -
  the birch's dark bands and the broadleaves' and snag's two-tone boles;
- the church tower's belt course is a ring round the shaft, not a slab
  whose top lay in the belfry floor;
- a closed window's cross bar is two halves either side of the upright;
- `WorldTerrain.build_water` splits a concave lattice quad along its inner
  diagonal;
- the "street" kit (street and square paving, 0.2 m over the grass) is
  drawn with `Palette.paving_material()`: the solid material with
  BaseMaterial3D's z clip scale at 1 - 3 x 2^-24, a 3-step polygon offset
  that settles its depth ties with the grass at every distance.
Left for this area (listed by the test): 5,466 spots of 1-30 cm gaps that a
sparrow sees fight from 38-150 m - the rooms' panelling 2 cm proud of the
plaster, the barn's boarding 3 cm under the moss roof, the far tree
stand-ins, house floors 0.3 m over the grass. World suite 39/39.

## What was built

| District | Contents (seed 1) | Why it is there |
|---|---|---|
| Arena | radius 680 m (`bounds_radius`), ceiling 300 m, a ring of 15 named peaks with spurs and bays, snow caps, foothill conifers; an invisible boundary (96 overlapping boxes, inner faces at 680 m) plus a lid at 300 m; far backdrop peaks; a **soft edge**: over the last 45 m the air pushes inward (up to 6 m/s at the wall) | a closed arena that looks like mountains, not a wall, and never stops a bird without warning |
| Terrain | 190×190 jittered 8 m lattice (organic facets, straight field edges), 25 chunks, trimesh collision from the drawn triangles; **far chunks** (nearest point > 260 m from the camera) drawn from the lattice's even vertices, a quarter of the triangles, except along the water line, on the east fields and wherever that would stray > 2.4 m from the collided surface | `ground_height()` equals physics to ~1 cm |
| Village | 13 houses on a cobbled street, **11 of them fly-through** (open windows front **and** back across a **lived-in room**: bed, table, bench and chair, dresser, a shelf of jars, a hanging lamp, ceiling beams, timber panelling, rug and picture, all clear of the flight line; the farmhouse makes 12); **every house has a vent** high in its side wall into its (upper) room, in **three sizes along the street** (0.30 m a pigeon's, 0.40 m a crow's, 0.52 m a gull's: each a refuge the next size up cannot follow into); gutters, sills, chimneys, TV aerials, ridge caps, shutters, doors; a church with a 17 m tower, **4 open arched belfry openings** and a bell hung above the arches' line, spire, cross and clock; the square with a well, benches and lamp posts (the two by the street ends planted in the verge) | windows, vents and belfry for acrobatics at every size; roofs, gutters, chimneys and sills to perch on |
| Farm | board-and-batten barn (open doors at both ends; a white-framed hay-loft hatch under a hay-hoist beam; **an owl hole** high in the west end a gull fits and a hawk does not; **8 slat gaps only small birds fit**; **2 broken boards a pigeon or crow fits**; dark boarding under the roof, tie beams, hay); fly-through farmhouse; **water tower** whose tank has a **single hatch** into a hollow tank; walkway rail, fences, 11 round bales | tight entrances and a tall tower |
| Power lines | 15 wooden poles over 490 m (cross-arms, insulators, transformers), 3 sagging wires per span that collide as capsule chains | classic small-bird perches, a slalom for big birds |
| Forest | **an old wood you must weave through.** 1,259 trees plus 263 young mid-storey trees, 185 bushes, 26 fallen trunks, 3 hollow oaks. The core (r 92 m) holds 621 trees about 4.8 m apart, forest-grown oaks with tall boles, dead stubs and interlocking crowns, plus spruce and birch; it thins to an open edge at r 168 m. A glade under a thermal and two **rides** (earth tracks). Drawn at three levels of detail that keep the full tree's silhouette (see Design decisions) | "trees with real branch structure to weave through" |
| Orchard | 40 fruit and blossom trees in rows, fenced | |
| Hedgerows | 251 terrain-following segments along the field grid, leafy bulges half sunk into both faces and lumps along the top, each with a **tunnel only wren to starling fit**: a 22 cm mouth, 30 cm deep, on each face, opening into a hollow in the middle (the refuge); the mouth clears the ground its approach crosses on both faces | small-bird refuges you can enter at an angle |
| Fields and meadow | patchwork crops on the grid; the NE **meadow keeps a 165 m radius completely clear** (vast open space) | vastness |
| Water | lake (ellipse 264×196 m) and river from the canyon at one water level; the water surfaces collide; **humpbacked stone bridge** with a river arch and two side arches; jetty and rowing boat; a **sea-stack arch** in the lake | a big-bird playground, flying under arches |
| Rock | **west cliff** escarpment (60 m, stratified; it faces the breeze, so it makes ridge lift). A **pale sand bed runs along the whole face** between two harder beds (a ledge below, a cap above), and the **30-burrow swallow colony** is dug into its thickest stretch: oval mouths with a worn, lit sill, a shaded throat and a dark chamber. **13 grassy rock shelves** up the face for eagles, each a broken slab set into the rock along its whole width. A **U-shaped canyon** cut into the mountains with a **natural arch** across it. A roofless **ruined tower** with arched windows. Boulders | nesting with tight airborne entrances, big-bird playgrounds |
| Mast | 92 m red/white guyed lattice mast, the lattice right up to its top plate, beacon rod and lamp on the plate; two platforms and 9 guy wires | the tallest perch, a lookout for hawks and eagles |
| Nest boxes | 14: 12 on trunks and 2 on power poles, each hung on a batten flat against one face of its trunk or pole, facing a physically clear approach; round 85–100 mm holes with dark interiors, perch pegs, hollow insides | tiny entrances |
| Air | gusty breeze (−X); **8 thermals** (bell columns of 35–44 m radius, cores 3.4–4.6 m/s, drifting about 11 m on slow Lissajous loops, ±11 % pulse, leaning downwind), wide enough that **every species' 30° thermalling circle gains ≥ 1.78 m/s** (the eagle's 19.4 m circle; the rest ≥ 2.4); **ridge lift** on the cliff, the canyon's windward massif and the west mountain slopes; pollen **motes** spiral up every thermal (240 a column, growing to twice their angular size by 400 m so a column reads across the valley) and rise over every lift zone, coloured per light (pale by day, dim warm at dusk), all in one draw call | soaring without flapping |
| Sky | procedural sky, filmic tonemap, exponential fog with aerial perspective, one sun with one orthogonal shadow split (90 m), low-poly clouds above the ceiling; `day` and `dusk` presets | |

The counts are asserted, not just reported: 1,189 perches (7 kinds, 15
districts, every one approachable and leavable), 371 openings (15 types,
spans 0.22–84 m, at least 3 made for every size of bird), 296 refuges, 453
landmarks, 1,772 tree instances, 2,539 footprints checked physically and
320 clusters of mounted pieces checked for support.

## Code map (`scripts/world/`)

| File | Role |
|---|---|
| `world.gd` | `World` contract base (flat and windless, kept cheap for other areas' tests). Adds `is_generated`, `_generate()` and `get_thermals()`. |
| `soaring_world.gd` | `SoaringWorld`: runs generation, commits kits, wires LODs and shadow proxies, **hangs the nest boxes after the commit**, **measures the rock-arch and belfry passages and the belfry refuge**, validates perches (support, clearance, an approach flyable both ways), builds the boundary and spawn, swaps far terrain each frame, sets the motes' light, overrides the API, `stats()`. |
| `world_layout.gd` | `WorldLayout`: the hand-placed district plan (anchors, river, cliff and canyon lines, thermals, fields, forest core and rides). The seed varies details only. |
| `terrain.gd` | `WorldTerrain`: height function, jittered lattice, colours, chunks and their **far meshes** (`update_lod`), water, backdrop, exact `height_at`, the **rock overlay** (`add_rock`, `rock_ground_at`). |
| `wind.gd` | `WindField`: breeze, thermals, baked ridge lift, soft edge, 32 m lookup grid. |
| `mesh_kit.gd` | `MeshKit`: flat-shaded, vertex-coloured triangles with matching collision (trimesh, capsules, hulls): boxes, cylinders, blobs, prisms (optional per-edge colours), walls with holes. **Corrects mirrored frames** (a left-handed basis or `xf` no longer builds a solid inside-out). |
| `world_build.gd` | `WorldBuild`: generation context (kits, LOD kits, **shadow proxies**, perches, openings, refuges, landmarks, features, footprints with owner and reach, occupancy grid, `ground_blob`). |
| `tree_lib.gd` | `TreeLib`: 23 tree variants (9 species), chunk meshes by bulk packed-array transforms, **three levels of detail handed over by visibility parents**, silhouette-calibrated stand-ins, per-chunk near shadows and per-group far shadows, one body per tree, `silhouette_area()`. |
| `rocks.gd` | `RockBuilder`: rock masses (with the cliff's **sand bed stratum**), the **colony** (`_colony`, `_burrow`), the **eagle shelves** (`_shelves`, seated by `_face_depth` on the face's own triangles, built by `_loft`), canyon, arches, ruin. |
| `village.gd`, `farm.gd`, `power_lines.gd`, `flora.gd`, `props.gd`, `soft_decor.gd`, `world_sky.gd`, `thermal_motes.gd` | District builders. `props.gd` also hangs nest boxes (`build_mounted`: `_post_face` finds a flat face of the drawn trunk or pole, `_collider_depth` measures the collider behind it). |
| `palette.gd` | `Palette`: the one palette (sRGB), lighting presets, shared materials. |
| `world_free_fly.gd` | Desktop free-fly camera with a live readout (dev scene). |
| `world_vr_tour.gd` | XR rig tour for the simulator evidence. |

## Design decisions

- **Everything drawn at full detail collides with the triangles that are
  drawn.** Solid kits collide as a trimesh of their own faces. Thin things
  collide as capsules at least as thick as the visual. Leaf clumps and
  conifer tiers collide as convex hulls of their own vertices. Trunk
  capsules end exactly at the drawn trunk foot.
- **Stand-ins keep the look; the colliders stay the full tree's.** A tree
  chunk is drawn at one of three levels, handed over exactly by
  `visibility_parent` (HLOD; `tests/shots/world_hlod_check.tscn` shows the
  engine draws exactly one of the three at any distance):
  - *full* while the camera is within the chunk's mid begin distance
    (forest 72 m, groves 150 m, from the mesh bounds' centre, 6 m
    hysteresis);
  - *mid* (per chunk): the stem as one tube, a 12-triangle bipyramid
    through each leaf clump's own extreme points (small tufts dropped), the
    spruce's own 7-sided tiers;
  - *far* (per 2×2-chunk group, from 130 m / 300 m or further, so no chunk
    can still be full while its group is far): the stem and one faceted
    "lozenge" per crown through the crown's own extreme points (a 5-sided
    cone for conifers, octahedra per tuft for sparse birch and pine crowns).
  Round 2's stand-ins were inscribed in the colliders, so a dense wood seen
  from 60 m looked like sparse parasols and popped on approach. Now every
  variant's mid and far stand-ins cover the full tree's projected area from
  the side and from above to within 15 % / 22 % (measured by rasterising
  both: `TreeLib.silhouette_area`), and their points may stand outside the
  colliders only by what 1° covers from the nearest they are ever seen
  (~30 m for mid, ~60 m for far).
- **Trees outside the wood are chunked on a 100 m grid** (groves), whatever
  placed them. Round 2 chunked the foothill conifers in 45° sectors of the
  ring, so a tree beside the camera could be drawn as a far stand-in
  because its sector's centre was 200 m away.
- **Far terrain is switched from the nearest point, not the chunk centre.**
  A mountain chunk's bounds are 600 m tall; a centre-based range would
  coarsen the slope right beside a bird. `SoaringWorld._process` calls
  `WorldTerrain.update_lod(camera)` (25 rectangle distances). The far mesh
  uses the lattice's own even vertices, keeps full resolution where the
  water line runs, on the east fields (their edges fall on odd lattice
  lines) and wherever two coarse triangles would miss a lattice vertex by
  more than 2.4 m, and takes in the middle vertex of every edge it shares
  with a fine block or another chunk (no cracks). Collision is unchanged.
- **Cheap shadows.** Trees: the mid stand-in casts near shadows (dappled
  light under the canopy), one crown silhouette per tree farther, merged
  per far group (one shadow draw per four chunks). Hedges cast from their
  stand-in boxes (`WorldBuild.shadow_proxy`): the full hedges cost as much
  again in the shadow pass (68 k shadow primitives in one field view).
- **Hedges are three pieces**, plain lengths either side (one quad per
  colour band a face) and a 0.9 m tunnel section: cutting the tunnel
  through the whole length cut every band into cells, twice the triangles.
- **The colony is part of the cliff.** `rock_mass()` gives the cliff six
  more face rows per station: the top of the bed below (a ledge), the sand
  bed's face, the underside and front of the bed above. The bed runs the
  whole cliff, pinching out at the low ends and thickening into the colony.
  At the colony stations the bed's face lies on one plane (folded at each
  station) and `_colony()` draws it: bedding strips sharing one list of
  cuts, burrow tiles fanned round each mouth, the strips that meet the rock
  rows fanned onto them (no T-junctions, no cracks). The cap stops short of
  the ledge's front, so the rock never overhangs open air (what a single
  ground height cannot describe).
- **Claims are verified by physics at generation.** Perches are snapped
  and need room and a clear 2.5 m approach flown both ways (1,422 proposed
  → 1,189 kept, `stats().perch_validation`). Rock arches **and the belfry** are rated by
  bisection with sphere casts through the whole passage (the belfry: out
  of the opposite arch), the belfry refuge by the largest body that flies
  in through an arch and fits there. Nest boxes face a clear approach.
- **A body "fits" only if it starts clear.** Jolt's `cast_motion` ignores
  shapes the moving sphere already overlaps; measurement and tests check
  the start too (round 3's nest-box approach check did not, and one box on
  seed 2 faced into a leaf clump).
- **A perch must be leavable.** Trimesh faces only stop what meets their
  front, so a perch walled in by inward-facing faces has a clear way in and
  none out. Perch validation and the W3 test fly each approach line back
  out as well.
- **No solid can be built inside-out.** `MeshKit` flips the winding of any
  primitive built in a mirrored frame (`box`/`prism`/`wall` with a
  left-handed basis, or a mirrored `xf`). Round 3's cliff shelves were
  boxes in the frame `(−N.z, 0, N.x), UP, N` (determinant −1): see-through
  from outside, a trap inside, their eagle perches snapped inside them. The
  suite checks the signed volume of every closed piece.
- **Mounted things are seated on what they hang from, and checked.** The
  cliff shelves' backs sit 0.5 m behind the most recessed of 15 points of
  the face across their width and height (measured on the face's own
  triangles). A nest box faces a flat face of its drawn trunk or pole, its
  back board 1.2 cm off the post's collider (rays over the board) and a
  batten reaching 2 cm into the drawn wood: the collider is a capsule up to
  ~12 cm proud of a tapered 6–7-sided trunk, and the box's inside must stay
  clear of it. The two pole boxes hang on real poles (round 3 put one on a
  corner of the line's polyline, 2 m from any pole). Nest boxes are hung
  after every kit is committed, so their clearance checks see houses,
  hedges, fences and wires, not only trees.
- **The shelves are props, not rock ground.** They overhang the air in
  front of the face (like the bridge), so they go into the `boulders` kit:
  outside `ground_height`'s rock overlay, whose columns must be solid from
  the floor up, and at no extra draw call (the boulders are drawn in nearly
  every view).
- **Tree tubes overlap at their joints.** Each wood piece above the ground
  starts a little back along its own axis inside the piece it grows from:
  two tapered rings meeting at an angle (a leaning bole, a kinked pine)
  otherwise leave an open wedge that shows the sky through the trunk.
- **`max_span` of an opening is geometric**: `span_for_gap(gap) = gap / (2 ·
  k · 1.2)` with `k` = body radius / wingspan from `SizeRules`; measured
  passages use `clear radius / (k · 1.2)`.
- **`ground_height()` is the solid ground**: the first solid-to-air
  boundary going up from the floor, counting the cliff and canyon rock
  (their triangles bucketed on a 4 m grid, exact barycentric heights).
  Arches, bridges, buildings, trees and props are not ground.
- **Every footprint names its owner** (kit or tree body), and grounding is
  measured on the owner's own collider **and** its drawn vertices (and
  points along long edges): a capsule's rounded end can reach below the
  rod it stands for.
- **Wind is fast by construction**: a 32 m grid says which thermals, lift
  or edge push can touch a cell; bells `S·(1−r²/R²)²`; ridge lift baked on
  an 8 m map with adaptive band ramps. ~1.0 µs per call.
- **Generation is single-threaded on purpose** (GDScript workers contended
  on reference counts and ran ~1.5× slower). The far terrain reuses the
  fine mesh's cell colours rather than colouring twice.

## Verification (definition of done)

```bash
# Headless: world_test (28 tests), palette_test (5), mesh_kit_test (6) = 39 world tests; the filter
# also runs the vr area's world_scale_test (10): 49 tests, 435 assertions, ~21 s
tools/gd.sh world --headless res://tests/runner.tscn -- --suite=world

# Mutations: each puts back one round-3 defect (or removes one fix) in a PRIVATE copy of the
# project and runs world_test there -> artifacts/world/mutations/results.txt
bash artifacts/world/mutations/run_mutations.sh all

# Screenshots (forward_plus, 51 views incl. close-ups) -> artifacts/world/shot_*.png
tools/gd.sh world --rendering-method forward_plus --resolution 1280x720 res://tests/shots/world_shots.tscn -- --prefix=shot
# Level-of-detail check: forest poses with stand-ins vs everything at full detail
tools/gd.sh world --rendering-method forward_plus --resolution 1280x720 res://tests/shots/world_shots.tscn -- --lodcompare

# W7 render budgets on the Quest renderer (Mobile), 1280x720, 90° FOV, far 3000 m, MSAA 4x, shadow
# pass counted; exits 1 if any frame is over budget:
#  warm = 300 views (200 in and around the forest) each measured cold (arriving from the far corner)
#         and warm (after circling 25 m round the point: every visibility range in its "near" state);
#  scan = 4,800 head directions over the old wood; flight = a continuous 2,962-frame flight
tools/gd.sh world --rendering-method mobile --resolution 1280x720 res://tests/shots/world_perf.tscn -- --mode=all
#  ... where one view's primitives go
tools/gd.sh world --rendering-method mobile --resolution 1280x720 res://tests/shots/world_perf.tscn -- --mode=breakdown --at=x,y,z --look=x,y,z
#  ... the 112 fixed still views (main views, close-ups, round-1 worst cases, 40 seeded random cameras)
tools/gd.sh world --rendering-method mobile --resolution 1280x720 res://tests/shots/world_shots.tscn -- --perf --noshots --fov=90
#  ... the engine's visibility-parent behaviour the tree LODs rely on (exits 1 on a wrong level)
tools/gd.sh world --rendering-method mobile --resolution 320x240 res://tests/shots/world_hlod_check.tscn

# Wind plots with axes, scale and colour bar -> artifacts/world/wind_*.png
tools/gd.sh world --headless res://tests/shots/world_wind_plot.tscn

# Diagnostics (not tests): timings and tree budgets; --silhouettes (stand-in area ratios per variant),
# --standins, --contrast=<png>, --seedsweep, --longcast, --overhangs, --ground_at=x,z,
# --openings (every opening's and refuge's rating by type), --opening=<name> (what stops its rated
# bird), --arenasweep (the suite's arena sweep: every suspicious line with its ray, long cast and
# 1 m-step march)
tools/gd.sh world --headless res://tests/shots/world_diag.tscn -- [--seed=3] [--silhouettes] ...

# Round 3's verifier probes, re-run on this build (13 tests; engineering determinism probe twice)
tools/gd.sh world2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=r3exp
tools/gd.sh world2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=world_verify3_determinism

# Dev scene (desktop free-fly) / its evidence frame
tools/gd.sh world --rendering-method forward_plus res://scenes/dev/world_dev.tscn
tools/gd.sh world --rendering-method forward_plus --resolution 1280x720 res://scenes/dev/world_dev.tscn -- --devshot=4

# Meta XR Simulator (Quest Pro profile): tour + mirror frames -> artifacts/world/world_vr_*.png
tools/xr.sh 88 res://scenes/dev/world_vr.tscn -- --xrshot=5,13,21,29,37,45,53,61,69,77 --xrshot_prefix=world_vr --xrshot_dir=world --xrdiag
```

| # | Criterion | How it is verified | Result |
|---|---|---|---|
| W1 | Closed arena; `is_inside` agrees | `test_w1_closed_arena`: 360 bearings × 7 altitudes; from the outermost airborne point a ray must stop at ≤ R + 0.6 m, **and a 2 cm sphere flown in 10 m casts** must be stopped; `is_inside` must agree; the lid blocks. `test_w1_no_gaps_anywhere`: 4,000 random 3D rays (a 2 cm sphere cast 5 m across every point where a ray stops at the edge) and an analytic check that every boundary box overlaps its neighbour. `test_w1_soft_edge_turns_birds_back`. `test_w123_hold_on_other_seeds`: the sweep on seeds 2, 3 **and 4242** | 2,520 + 4,000 + 3 × 720 casts, 0 escapes, 0 mismatches; edge ramp 0.20 (m/s)/m |
| W2 | ≥ 20 flyable openings, ≥ 4 kinds, wren to eagle, real holes | `test_w2_…` on **every** opening: the rated body starts clear and flies from 1 m outside to `depth` inside untouched (through the whole belfry, out of the opposite arch); rays from just inside the outer plane hit solid on all four sides within 1.35× the half-size; a body 30 % bigger does **not** fit. **New:** for every size of bird, ≥ 3 *tight* openings (it fits, a bird of twice its span does not; ≥ 10 for the pigeon and the crow) and ≥ 3 *refuges* (it is the largest bird that fits, so the next size up cannot follow); all 4 belfry arches measured for ≥ 4.0 m. Rock arches and the belfry measured after build; seeds 2, 3, 4242 | 371/371 on seed 1 (and all on seeds 2, 3, 4242); 15 types; spans 0.22 → 84 m. Tight: wren 14, sparrow 46, swallow 289, starling 264, pigeon 15, crow 14, gull 28, hawk 33, eagle 26. Refuges: wren 6, sparrow 8, swallow 30, starling 259, **pigeon 8 (was 3), crow 7, gull 5 (was 0)**, hawk 8, eagle 40. Belfry 4.43 m |
| W3 | ≥ 400 perches on real geometry with clearance, spread | `test_w3_…`: ray support within 3 cm; the rated body fits above; a clear 2.5 m approach from one of 16 directions **flown both ways** (the test's own code); ≥ 6 kinds, none > 45 %; ≥ 8 districts with ≥ 5; ≥ 20 eagle-sized and ≥ 100 small-only; `find_perches` equals brute force; seeds 2, 3, 4242. **New `test_w3_cliff_shelves_are_solid_and_set_in_the_face`**: every shelf has its perch rated ≥ 2.0 m; a drop from above stops on its top at the perch (front faces only); level flight at sparrow size meets its front ≥ 0.4 m ahead of the perch; a bird on it can leave; rays back through it from in front of the lip meet the cliff before the shelf's back end at 10 points across its width and height | 1,189 perches, 7 kinds (BRANCH 39 %), 15 districts, all approachable and leavable; 13 shelves: all solid, eagle-rated (2.1 m), 3 of 3 exits, front 0.72–0.87 m ahead, set in the face at 10/10 points |
| W4 | Thermal cores ≥ 3 m/s, < 0.5 outside, smooth, < 5 µs, a cue at every thermal | `test_w4_*`: cores at 60/120/180 m over 5 times in [3, 5]; just outside every bell and at 4,000 still-air points < 0.5 m/s; gradients through every thermal, the cliff and 120 k random points < 0.6 (m/s)/m; 100 k calls; mote uniforms equal the live thermal centres; ridge motes on real lift; `test_w4_thermals_carry_every_size`: every species' 30° circle round every live, drifting, leaning thermal at 120 m gains ≥ 1.5 m/s over 10 minutes | cores 3.42–4.64 m/s; worst gradient 0.28 (thermals/cliff), 0.39 arena-wide; 1.06 / 1.27 µs; circle lift worst: eagle 1.78 m/s (19.4 m circle), hawk 2.41, gull 2.63, crow 2.84, the rest ≥ 3.0. Motes now read across the valley (`shot_thermal.png`, `shot_overview.png`) |
| W5 | ≥ 150 m clear areas; ≥ 95 % of the inner zone within 120 m of a feature | `test_w5_…`: 709 vertical rays over a 150 m disc at the meadow hit only terrain; 10 m grid over r < 480 m against 2,404 features; 400 sampled features must have geometry above them | 0 obstructions; coverage 98.6 %; backing 99.75 % |
| W6 | Nothing floats | `test_w6_nothing_floats`: for all 2,539 footprints, horizontal rays 10 cm above the ground must hit the **owner's** collider **and** a drawn vertex of the owner within reach must touch the ground; every footprint has an owner; none declared above the ground; a vertex test for loose props. `test_w6_detector_catches_floating` lifts every owner of every kind by its deepest embedding + 0.3 m and requires every footprint flagged, then restores. **New `test_w6_mounted_things_are_attached`** (things on other things, which footprints never see): every full-detail kit mesh split into connected pieces; pieces whose boxes touch form clusters; each cluster must reach the ground or have a vertex within 3 cm of another object's collider (its own kit's excluded); the detector is checked on a grounded and a lifted probe box. **New `test_w6_nest_boxes_hang_on_their_trunk_or_pole`**: behind every box's back board the post's collider is within 2 cm at the nearest of 9 points and 5 cm at the farthest; nothing but the box inside it; along the batten's centre line the **drawn** wood (ray-triangle on the tree or pole mesh) is met before the batten's own back end | 0 floating footprints; the lift mutation caught for all 24 kinds (841 footprints, incl. the new lamp posts); 320 clusters, **0 detached** (round 3: mast top, nest box, 2 lamp posts); 14 boxes: collider 1.2–1.5 cm at the nearest point, ≤ 4.4 cm at the farthest corner, battens 5.4–15.3 cm reaching 0.7–2.1 cm into the drawn wood (at its most recessed height) |
| W7 | ≤ 150 draw calls, ≤ 300 k primitives; generation < 2 s | `world_perf.gd --mode=all` (above, **a gate: exit 1 over budget**): warm, scan, flight; also the 112 still views. The world keeps a margin (target ≤ 270 k) for the birds, wings and UI the game adds. **New `test_tree_levels_are_wired`** (headless): every tree chunk with stand-ins hands its full level over to its mid by visibility parent, the mid to its far group, which begins later | **worst 260,681 primitives** (scan, over the old wood looking down across it; p99 247,284) and **130 draw calls** (flight); warm 245,090 (300 views, cold and warm), flight 250,259 (p99 241,878), 112 still views 216,162 / 112 draws; **0 frames over the budget or the 270 k target**. Round 3 peaked at 254,029 / 128: the +6.7 k is mostly the rooms' furnishings (~3.3 k at that pose; they are counted whenever the village is in view) and the farm's new details (breakdown: `world_perf --mode=breakdown`). Round 3's verifiers' own searches re-run on this build: experience 280 views **251,742 / 122**, engineering walk 214,162 and climb **227,459 / 128**; 0 over. `test_tree_levels_are_wired`: 123 chunks, all handed over and in far groups; `world_hlod_check`: one level at all 11 distances. Generation 1.22–1.39 s headless, 1.37–1.41 s rendering, 1.50 s in the simulator |
| W8 | ≥ 12 screenshots, cohesive, no z-fighting, missing faces or floating | 51 views reviewed by eye (10 new ones of what round 3 found), the LOD comparison (4 poses × 2), 8 simulator mirror frames | see Evidence |
| W9 | Deterministic by seed | `test_w9_…`: SHA-256 over every perch, landmark and refuge **and a second SHA-256 over the built geometry** (every drawn mesh's vertices and colours, every collision shape and its transform); two more worlds in isolated physics spaces: seed 1 identical, seed 2 different | pass (`150e671d…`, geometry `73778174…`); the engineering verifier's cross-process probe on this build: identical in two processes (`d32ba8a4…`), different for seed 2 |
| W10 | Every visible solid collides | `test_w10_every_visible_solid_collides`: every drawn mesh declares its collider; 250 random triangles per full-detail mesh probed 2 cm outside their face; stand-ins within 1° of the colliders from the nearest they are seen; `test_tree_stand_ins_keep_the_silhouette`. **New `test_w10_no_inside_out_solids`**: the divergence-theorem volume of every closed piece of every kit must not be clearly negative (checked on an outward and an inside-out probe box). **New `test_w10_no_invisible_colliders`** (the converse): every point of every capsule axis (poles, rods, wires, the mast's legs) has drawn geometry of its kit within its radius + 25 cm, or lies buried (under the terrain or inside a closed drawn solid) | full detail 100 %; 38,245 stand-in points, 0 beyond 1°; stand-in areas mid 0.88–1.11, far 0.82–1.20; 3,712 pieces, 3,416 closed outward solids, **0 inside-out** (round 3: 13 shelves); 874 capsules, 8,140 axis points, 0 undrawn (round 3: the mast legs' top 1.2 m) |
| — | Forest demands weaving (round-1 requirement) | `test_forest_demands_weaving`: straight-line flights at 3–12 m through the wood and the core; canopy cover; trunk spacing; from anywhere in the core a 15 m gap to fly on | sparrow mean free path 32.5 m in the wood, 19.3 m in the core; eagle 24.0 m; canopy 47 % of the wood, 60 % of the core; trunks 4.8 m apart; weavable 96 % (sparrow, core), 99 % (crow); the meadow stays open (119.8 m) |
| — | `ground_height` is the solid ground | `test_ground_height_is_the_solid_ground`: 10,880 samples (2,659 on rock, 190 with several rock surfaces above the floor) against physics; `test_rock_ground_contract` pins the overhang rule on synthetic rock; every perch and opening approach is `is_inside` | worst error 11 mm (limit 20 mm) |

Supporting suites: `palette_test.gd` (all colour names used exist, only
white things may clip, meeting surfaces differ in value, presets and
materials complete) and `mesh_kit_test.gd` (winding, real holes, capsules,
`height_at`, and **`test_mirrored_frames_stay_outward`**: a box, prism and
wall in a mirrored frame, a box under a mirrored `xf` and a doubly mirrored
box all have their exact positive volume, drawn and collided).

**Mutations** (`artifacts/world/mutations/results.txt`): each round-3
defect put back in a private copy, world_test run there.

| Mutation | Caught by |
|---|---|
| M01 shelves in a mirrored frame, MeshKit correction off | `no_inside_out_solids`, `cliff_shelves_…` |
| M02 the same and perch validation without the way out | + `w3_perches_…` (the trapped perches survive validation) |
| M03 shelves standing off the face (back at the face's front + 0.3 m) | `cliff_shelves_…` |
| M04 the mast lattice stopping at 90.8 m | `mounted_things_are_attached`, `no_invisible_colliders` |
| M05 a pole box on the line's corner point, 2 m from the pole | `mounted_things_are_attached`, `nest_boxes_hang_…` |
| M06 the verge lamp posts based at the paving's height | `nothing_floats`, `detector_catches_floating`, `mounted_things_are_attached` |
| M07 nest boxes without battens | `mounted_things_are_attached`, `nest_boxes_hang_…` |
| M08 tree levels not handed over | `tree_levels_are_wired` |
| M09 facet colours from the global RNG | `w9_deterministic_by_seed` (geometry hash) |
| M10 one vent size again | `w2_openings_…` (pigeon and gull refuges) |
| M11 hedge mouths from the centre line's ground | `w123_hold_on_other_seeds` (seed 4242) |
| M12 nest-box clearance casts ignoring their start | **not caught**: with the boxes hung after the commit no seed tested puts an approach start inside a crown. The class is caught by W2 whenever it happens (that is how seed 2's case was found) |

### Thresholds and measurements set this round (and why)

- **Arena: the 2 cm sphere is flown in 10 m casts** instead of one cast to
  150 m past the wall. This is a measurement fix, not a looser threshold (still 0
  escapes). Jolt's cast tolerance grows with the cast's length: on seed
  4242, bearing 246° at 2 m, the start falls back to the valley centre and
  one ~700 m cast of a 2 cm sphere reports no hit, while the ray stops on
  `terrain_1_0` at r 533 m and a 1 m-step march of the same sphere stops
  at r 533.16 m on the same body (`world_diag --seed=4242 --arenasweep`,
  `verify/r3fix/diag_arenasweep_4242.log`). A bird moves under 1 m a tick.
  This is also the explanation of the single long-cast "escape" per seed
  that round 1's seeds probe and round 3's verifier found on seeds 3, 4242
  and 90001; the verifier's 1 m-step march finds 0 on all five of its seeds
  (`verify/r3fix/r3exp_probes_on_fix3.log`).
- **Nest boxes: the collider within 2 cm at the nearest of 9 points, 5 cm at
  the farthest.** A flat board on a round, leaning trunk touches along a
  line; the box is seated 1.2 cm off the collider on purpose (so a ray
  from just behind the board does not start inside the capsule).
- **Tight and refuge opening counts** are two definitions on purpose:
  *tight* (fits, twice the span does not) is round 2's verifier's; *refuge*
  (the largest bird that fits) is what hiding from the next size up needs.
- **Shelf front ≥ 0.4 m ahead of the perch** at sparrow size: the perch is
  0.7 m in from the nearer lip; the lip is bevelled.
- **Attachment contact 3 cm** (a vertex within 3 cm of another object's
  collider): tighter than round 3's verifier's box test (5 cm on bounding
  boxes), which could not see a box 8 cm off a round trunk.
- **No existing threshold was loosened.**

## Round 3 → fix round 3: what changed and why

| Verifier finding | Fix | Evidence |
|---|---|---|
| **The 13 cliff shelves are inside-out** (major, experience): mirrored basis, see-through from outside, perches snapped inside, a bird cannot leave; 5 stand 0.1–1 m off the face | MeshKit corrects mirrored frames; the shelves are right-handed wedges lofted between two jittered end profiles, their backs 0.5 m behind the most recessed of 15 face points (rays on the face's own triangles), in the `boulders` kit (not rock ground, no extra draw call); perch validation flies every approach back out; new suite tests for signed volume, shelf solidity and seating, and the W3 test flies approaches both ways | 13/13 solid, eagle-rated, set in the face; 0 inside-out pieces; the verifier's `test_cliff_shelves_are_solid_and_attached` and `test_no_inside_out_pieces` pass; `shot_detail_cliff_shelf.png` (their profile pose), `shot_detail_cliff_shelf_below.png`, `shot_cliff_shelves.png`, `shot_cliff_colony_25m.png` |
| **Floating mounted things W6 could not see** (major, experience): the mast's top plate and beacon 1.6 m over the lattice, `nest_box_13` 2 m from its pole, two lamp posts 10 cm up | The lattice is drawn right up to `H` and the plate (now 2.4 m, over the legs) sits on it; pole boxes hang on real poles (`PowerLineBuilder` publishes them); the verge lamp posts are planted 15 cm into the ground, with footprints; new tests for mounted things, nest-box seating and undrawn colliders | 0 detached clusters, 0 undrawn capsule points; the verifier's `test_no_detached_pieces_in_kits` and `test_nest_boxes_touch_their_mount` pass (gaps 1.2–1.5 cm, was up to 1.01 m); `shot_detail_mast_top.png`, `shot_detail_nestbox_pole.png`, `shot_detail_lamp_post.png` |
| Two trunk boxes 7–8 cm off their trunks (minor) | Every box faces a flat face of its drawn trunk and hangs on a batten reaching into the drawn wood, 1.2 cm off the collider | `shot_detail_nestbox_side.png`, `shot_detail_nestbox.png`, `shot_detail_nestbox_wren.png` |
| Seed 4242: a hedge tunnel's approach runs into the ground (minor) | The mouth clears the ground 0.8–2.5 m out on both faces; seed 4242 added to the suite's other-seed test | all openings pass on seeds 2, 3, 4242 (and in the verifier's probe on 3, 4242, 90001, 0, 2³¹−1) |
| Art polish (minor): faint motes, bare rooms, door-like hollow, green loft hatch, flat hedges | Motes: 240 a column, twice the angular size by 400 m, coloured per light; rooms furnished (bed, chair, shelf of jars, lamp, beams, panelling); an oval knot-hole; dark boarding under the barn roof, a framed hatch and a hay-hoist beam; leafy bulges on the hedges | `shot_thermal.png`, `shot_overview.png`, `shot_dusk.png`, `shot_detail_room_inside.png`, `shot_through_window.png`, `shot_detail_hollow_tree.png`, `shot_detail_barn.png`, `shot_hedgerow_low.png` |
| Evidence predates the final source edit (minor, engineering) | Every run below was made after the last change to generation code (the tree-joint fix): suite, screenshots, LOD pairs, budgets, still views, HLOD check, dev frame, mutations, the verifiers' probes; then two stops were added to the simulator tour script (`world_vr_tour.gd`, evidence only) and the simulator run made | timestamps in `artifacts/world/` |
| Per-tier opening coverage and the belfry rating unpinned (minor) | W2 asserts tight and refuge counts for every size and a ≥ 4.0 m belfry; vents in three sizes and an owl hole make a pigeon's and a gull's refuges | M10 caught |
| W7 has no gate; the HLOD check asserts nothing (minor) | `world_perf` exits 1 over budget; `world_hlod_check` asserts one level per distance and exits 1; `test_tree_levels_are_wired` checks the built wiring headless | M08 caught; `verify/r3fix/hlod_check.log` |
| W9 hashes no geometry (minor) | A second hash over every drawn vertex and colour and every collision shape | M09 caught |
| Stale comments, dead code (minor) | TreeLib header rewritten; `displace_plane`, `ico_faces`, `add_box`, `add_sphere`, `add_convex`, `Palette.soft_material` removed (no callers); `stop[1]` | |
| The world uses ~85 % of the draw calls (cross-area risk) | Nothing new costs a draw call (shelves in `boulders`, furniture in the house kits) | worst 130 draws (see W7) |
| Round 2's W6 probe lifted only 1 m (for the record) | none needed, as the verifier found | |

**Found and fixed while reviewing this round's screenshots** (not in the
verifiers' reports):
- **Cracks at trunk joints.** Where a leaning or kinked trunk's two pieces
  meet, the open wedge between their rings showed the sky through the trunk.
  Tubes now overlap there (Design decisions).
- **White "snow" at dusk.** The unshaded motes stayed pollen-white at dusk.
  They now take a colour per light, and only the thermal columns grow with
  distance.

**Where the verifiers' probes disagree with this build, and why:**

- Round 3's experience probe (`world_r3exp_test`, 13 tests) passes in full
  on this build, including its shelf, detached-piece, inside-out, nest-box,
  seed and line-up tests
  (`verify/r3fix/r3exp_probes_on_fix3.log`). Its seeds test still prints
  `long_cast_leaks: 1` on seeds 3, 4242 and 90001 as information; its own
  1 m-step march finds 0 escapes on all five seeds (see the arena bullet
  above).
- *Round 1's `world_probe_geometry_test` / `world_probe_test` dense
  coverage (1 cm) ~85 %*, *`world_probe_seeds_test` "arena closed: 1"*,
  *`world_probe_test` "39 sphere escapes"* and *`world_probe_float_test`'s
  21 farm cells*: unchanged explanations. These are stand-ins drawn only from
  30–245 m (held to 1° by the suite), long single casts (see above), and door
  leaves and rugs on plinth tops.

## Earlier rounds (summary)

Round 1 → fix round 1: a dense old-wood core with rides and understory;
`ground_height` includes the cliff and canyon rock; the W6 test measures
built geometry; floating props seated; readable colony and tank; round
nest-box holes; hedge tunnels with short mouths; a soft edge; measured rock
arches; other-seed checks; W4 arena-wide gradient and live mote checks;
perch approach validation.

Round 2 → fix round 2: HLOD by visibility parents and silhouette-matched
stand-ins (the old wood's worst frame 329 k → 254 k primitives); the swallow
colony as a sand bed in the cliff's strata with oval burrows; thermals
widened so every species' circle climbs; a pigeon hole in every house and
two broken barn boards; the belfry rated by a measured flight; every
footprint owned and grounded on drawn geometry; wind plots with axes. See
the git history of this file for the full tables.

## Evidence index (`artifacts/world/`)

Every file below was made after the last code change of this round.

- **Valley:** `shot_overview.png`, `shot_overview_north.png`, `shot_from_edge.png`, `shot_dusk.png`, `shot_meadow.png`.
- **Forest:** `shot_forest_canopy.png`, `shot_forest_core.png`, `shot_forest_interior.png`, `shot_forest_ride.png`, `shot_detail_forest_floor.png`, `shot_detail_hollow_tree.png` (the oval knot-hole); **LOD comparison** `shot_lod_on_{wood_60m,wood_edge_25m,canopy_skim,core_far_view}.png` vs `shot_lod_off_*.png` (foliage cover 54.9 vs 54.6 %, 53.5 vs 53.3 %, 48.6 vs 48.7 %, 80.4 vs 80.4 %; 1.6–7.9 % of pixels change; `verify/r3fix/lod_compare.log`).
- **Village:** `shot_village_street.png`, `shot_through_window.png`, `shot_detail_room_inside.png` (the furnished room), `shot_detail_house_vent.png` (a gull vent), `shot_belfry.png`, `shot_detail_lamp_post.png` (a verge lamp in the ground).
- **Rock:** `shot_cliff_colony.png`, `shot_cliff_colony_25m.png`, `shot_cliff_colony_60m.png`, `shot_detail_cliff_colony_6m.png`, `shot_detail_cliff_hole_swallow.png`, `shot_detail_cliff_holes.png`, **`shot_detail_cliff_shelf.png`** (round 3's verifier's shelf, side-on), **`shot_detail_cliff_shelf_below.png`**, **`shot_cliff_shelves.png`**, `shot_canyon_arch.png`, `shot_detail_canyon_mouth.png`, `shot_detail_ruin.png`, `shot_detail_rubble.png`.
- **Refuges and holes:** `shot_detail_nestbox.png`, `shot_detail_nestbox_wren.png`, **`shot_detail_nestbox_side.png`** (the batten on the trunk face), **`shot_detail_nestbox_pole.png`**, `shot_detail_tank_hatch.png`, `shot_detail_tank_inside.png`, `shot_detail_hedge.png`, `shot_detail_hedge_mouth.png`, **`shot_hedgerow_low.png`**, `shot_detail_barn.png` (the framed hatch), **`shot_detail_barn_owl_hole.png`**.
- **Elsewhere:** `shot_power_lines.png`, `shot_thermal.png`, `shot_lake_bridge.png`, `shot_detail_bridge_under.png`, `shot_orchard_farm.png`, `shot_detail_orchard_low.png`, `shot_water_tower.png`, `shot_mast_lake.png`, `shot_detail_mast.png`, **`shot_detail_mast_top.png`**.
- **Budgets:** `perf_budget_mobile.json` (warm, scan and flight, with every view), `perf_mobile.json` (112 still views), `verify/r3fix/perf_all.log`, `verify/r3fix/hlod_check.log`.
- **Mutations:** `mutations/run_mutations.sh`, `mutations/results.txt`, one log per mutation.
- **Round 3's verifier probes on this build:** `verify/r3fix/r3exp_probes_on_fix3.log` + `report_r3exp_on_fix3.json` (13/13), `verify/r3fix/determinism_two_processes.log`.
- **Diagnostics:** `verify/r3fix/diag_seed1.log` (silhouettes, opening and refuge ratings, arena sweep on seed 1: 0 suspicious lines), `verify/r3fix/diag_arenasweep_4242.log`.
- **Air:** `wind_map.png`, `wind_thermal_section.png`, `wind_ridge_section.png`.
- `dev_scene.png`: the dev scene with its readout.
- **Simulator:** `world_vr_{5,13,21,29,37,45,53,61,69,77}s.png` + `artifacts/xr/run_20260926_033054.app.log`: Meta Quest Pro profile at 72 Hz, 0 script errors.
  - Stops: sparrow scale on the spawn roof and on a wire, **a nest box on its trunk (sparrow scale, new)**, inside the old wood; crow scale skimming the old wood's canopy from its rim (the round-2 worst view); the village street; the colony from 25 m and at swallow scale from 6 m; **an eagle shelf at eagle scale (new)**; over the valley.
  - Generated in 1,495 ms; at most 107 draw calls and 234,774 primitives in stereo.
  - 72 of 87 per-second samples at 70–72 fps; the rest 61–69 at stop changes and the heaviest views, and 35 in the first second (start-up), on a host at load average ~9 from other agents. Magenta specks are the known MoltenVK Mobile-renderer artefact on this Mac, not on Quest.
- `artifacts/tests/report_world.json` (+ `verify/r3fix/suite_final.log`): every metric quoted above.

## Using the world (for other areas)

- Wait for it: `if not world.is_generated: await world.generated`.
- `get_wind(pos)`: fine for every bird every tick (~1 µs). Breeze,
  thermals, ridge lift and the soft edge. `get_thermals()` gives live
  columns `{name, position (ground centre), radius, strength, base_strength,
  top, lean}`; the column at height y is centred at `position + lean * y`.
- `ground_height(x, z)`: the solid ground (terrain, water, cliff and canyon
  rock): the first solid-to-air boundary above the floor. Under an arch,
  bridge, house or the colony's cap it is the ground (or the ledge) beneath.
- Perches: `position` is the grip point; every perch has a clear final
  approach for its `max_span` bird, flyable both ways; `district` tells
  roosts apart; `find_perches` is grid-accelerated (~20 µs for an 80 m
  query).
- Landmark kinds: places `town`, `forest` (`forest` and the dense
  `old_wood`), `glade`, `ride`, `cliff`, `canyon`, `arch`, `tower`,
  `bridge`, `lake`, `meadow`, `field`, `hedge`, `hedgerow`, `orchard`,
  `farm`, `powerline`, `jetty`, `landmark`; for birds `thermal`, `nest`,
  `roost`, `window` (fly-through houses, with `exit`); `opening` with
  `type` (`window`, `vent` (three sizes: pigeon, crow, gull), `belfry`,
  `barn_door`, `barn_slat`, `barn_board`, `barn_loft`, `owl_hole`, `tower`,
  `nest_box`, `tree_hollow`, `hedge_gap`, `cliff_hole`, `bridge_arch`,
  `arch`), `normal`, `width`, `height`, `max_span`, `depth` and `up`.
  Names are unique.
- Refuges: `{name, position, radius, max_span}`: hedge hollows, nest
  boxes, cliff burrows, hollow trees, rooms (a shut house's only through
  its vent), the belfry (measured), the loft, the tank and the ruin.
- Spawn: the highest roof ridge near the square, facing the bridge and the
  lake.
- `SoaringWorld` extras: `set_lighting(&"dusk")`, `set_air_time(t)`,
  `get_openings()`, `stats()`; exports `world_seed`, `lighting`,
  `with_environment`, `with_decoration`. Far terrain follows the current
  `Camera3D` (the XR camera in VR); nothing to wire.
- Physics: all static geometry on layer 1; tree bodies also on layer 2
  (perch). No `Area3D`s: updrafts are `get_wind`, not volumes.

## Known limits

- Generation takes ~1.2–1.4 s on the M1 Pro in GDScript, single-threaded
  (the hedge bulges added ~30 ms). On Quest expect several times that;
  baking the generated scene at export or generating behind a loading view
  is not done.
- Render budget: the world alone peaks at 261 k of 300 k primitives and 130 of 150 draw calls (forest views). That leaves ~39 k primitives and ~20 draw calls for birds, wings and UI; birds should be instanced (one draw per model and LOD).
- The room furnishings are part of each house's kit, so they are counted
  whenever the village is in view (~3.3 k primitives at the old wood's
  worst pose). Splitting interiors into near-only kits would save that but
  cost a draw call or two near the village, and draw calls are the tighter
  budget.
- Stand-ins are silhouette-true, not shape-true: a mid-level tree seen from
  30–80 m has 12-triangle clumps instead of 20, a far one a faceted crown.
  The switch is visible if you look for it (1.5–8 % of pixels change in
  the comparison poses), not a change in size or density.
- A single ground height cannot describe two layers; spawners should test
  the point, not assume clearance (round 2's verifier's probe: 2 of 2,375
  points at `ground_height + 10 m` inside rock). The eagle shelves overhang
  the air in front of the cliff like the bridge: `ground_height` under and
  on them is the valley floor.
- The mutation that removes the nest-box start-overlap check (M12) is not
  caught on the seeds the suite builds: none of them faces a box into a
  crown now. W2's per-opening flight catches the consequence whenever it
  happens.
- The shelves and nest boxes are seated by measurement at build time;
  small gaps remain where a flat board meets a round trunk (≤ 4.4 cm at a
  board's far corner to the invisible collider; the batten meets the drawn
  wood).
- Soft decoration (grass, flowers, reeds) and clouds do not collide, by
  design and by test.
- One water level: the river is flat and has no current. Building faces
  make no ridge lift.
- The boundary is a 96-sided polygon whose inner faces sit at 680 m;
  `is_inside` uses the circle (≤ 0.35 m disagreement in the corners).
- Deep tunnels (the full 1.4 m of a hedge for a bird exactly the rated
  size) reward a straight entry; sliding on glancing hits is flight's job.
- The simulator run is a scripted tour, not the player rig; the whole-game
  VR run belongs to integration. Simulator frame rates on this shared Mac
  are not Quest frame rates.
