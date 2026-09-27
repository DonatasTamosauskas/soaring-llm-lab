# Birds — looks and motion

Owned by the birds area: `scripts/birds/`, `assets/birds/` (unused: every
bird is generated), `tests/unit/birds/`, `tests/shots/birds_*`,
`scenes/dev/birds_dev.*`, `artifacts/birds/`.

Every species on the ladder is a procedural low-poly mesh drawn with one
shared flat-shaded material: moth, wren, sparrow, swallow, starling, pigeon,
crow, gull, hawk and eagle. The wings, tail, legs and head are animated in
the vertex shader from four numbers per bird. Every species/LOD is drawn as
one MultiMesh. Sixty animated birds cost about 0.25–0.29 ms of CPU per
frame, headless, on desktop and in the Meta XR Simulator, and 19 draw calls
on the Mobile renderer. The per-bird node API from ARCHITECTURE is kept.

A highlighted bird is drawn at its true size and, once it is big enough to
show its plumage, in its own colours. The state is carried by a marker around
it at every distance: a ring for edible, a warning triangle for danger.

![lineup](../../artifacts/birds/lineup_equal_span.png)

## What was built

| File | What |
|---|---|
| `bird_species.gd` (`BirdSpecies`) | Shape and colour data per species: body, head, beak, wing planform stations, finger slots, tail shape, colour slots, patterns, animation constants (including the perched wing droop and the tail's folded close) |
| `bird_mesh_builder.gd` (`BirdMeshBuilder`) | Builds a species at LOD 0/1/2: body loft ending in a rump, head with beak and eyes, wings (arm/hand bands, ridge, finger slots with spines, colour bands), tail with a low central ridge (notch / fork / fan / wedge / square), legs, moth wings and antennae; the fold gathers (the hand narrowing to its tip, the fingers closing up) and the fold hug table (UV2); far LODs scaled to cover LOD0's silhouette; and the highlight marker's own mesh. Flat faces, sRGB vertex colours (alpha: the species' readable angle), per-vertex rig data |
| `bird_pose.gd` (`BirdPose`) | The animation maths on the CPU, the same as the shader line for line. Tests pose meshes with it; FX use it for wingtips |
| `bird.gdshader` | The one bird material: vertex animation, flat lighting, highlight (the hue on a tiny bird, the marker) and pulse |
| `bird_models.gd` (`BirdModels`) | Factory (`create`), mesh and material cache (all three LODs of a species built together), the marker mesh, palettes, highlight colours and readable angles, budgets, camera cache for LOD |
| `bird_model.gd` (`BirdModel`) | The per-bird node: the ARCHITECTURE fields, smoothing (no pops, bad values ignored), beat following, bank, LOD choice, marker membership, wingtip query |
| `bird_batch.gd` (`BirdBatch`) | One RenderingServer MultiMesh per (World3D, species, LOD, layers, shadows), plus one marker MultiMesh per (World3D, layers) holding the highlighted birds; fills and uploads one buffer per batch at `frame_pre_draw` |
| `bird_fx.gd` (`BirdFX`), `feather_burst.gd` (`FeatherBurst`), `wing_trails.gd` (`WingTrails`), `bird_fx_director.gd` (`BirdFXDirector`) | Feather burst on catch, wingtip trails at speed, optional auto-bursts on `Events.bird_caught` |

### Using it

```gdscript
var m := BirdModels.create(&"hawk")      # BirdModel (Node3D), wingspan 1.0
m.scale = Vector3.ONE * bird.get_wingspan()
bird.add_child(m)
# every frame (plain fields, any order, abrupt changes are fine):
m.flap_phase = phase      # 0..1, 0 = top of the upstroke (advance it forwards)
m.flap_amount = a         # 0 glide .. 1 full beats
m.wing_fold = f           # 0 spread .. 1 tucked (flying) / folded (perched)
m.perched = true          # body up, wings along the back, legs down
m.bank = roll             # radians, + = right wing down
m.highlight = 1           # 0 none, 1 edible (blue-violet ring), 2 danger (magenta triangle)

BirdFX.catch_burst(prey)            # feathers where prey was caught
BirdFX.attach_trails(m)             # wingtip trails while flying fast
```

Optional extras on `BirdModel`:

- `snap()` shows the fields at once, unsmoothed (after pooling or
  teleporting);
- `get_wingtip(side)`, `displayed_pose()`, `displayed_bank()`,
  `displayed_highlight()`;
- `get_lod()` (the LOD being drawn);
- `lod_bias`, `lod_override`, `render_layers`, `cast_shadows`.

On `BirdModels`:

- `palette(sp)` and `wing_palette(sp)` (VR's first-person wings read it,
  `scripts/vr/fp_wings.gd`);
- `HIGHLIGHT_EDIBLE` / `HIGHLIGHT_DANGER` (for matching UI cues);
- `min_highlight_angle(sp)`: the wingspan angle from which a highlighted
  bird reads by itself (below it the bird is tinted in the hue; from 1.8×
  it wears its own plumage);
- `prewarm()` (builds all 30 meshes in about 74 ms on an M1; without it,
  the first bird of a species builds its three LODs, about 8 ms, when it is
  attached);
- `triangle_count()`, `body_aabb()`, `material()`, `marker_mesh()`.

## Design decisions

**Procedural, not open assets.** `docs/research/ASSETS.md` found no open
pack that fits:

- The Poly-by-Google birds are rigid (wings merged into the body) and mostly
  perched. They use 10 textures and 10 materials, come at scales from
  0.13 m to 241 m, and include no starling.
- The rigged candidates are 10k triangles, cartoons, or behind a login.

Generating the birds gives exact conventions, one material, animatable
wings and a parameter for every silhouette cue. The downloaded models were
used only as a reference for proportions and colours. No geometry shipped,
so `docs/CREDITS.md` needs no bird entry.

**Shape cues** (field-guide silhouettes, from ASSETS.md §2):

| Species | Cues |
|---|---|
| Moth | Four wings |
| Wren | Round body, short round wings, narrow tail cocked up between the wingtips when perched (69°) |
| Sparrow | Round-tipped wings, notched tail, grey crown, chestnut nape, black bib |
| Swallow | Long swept hand, deep fork with streamers (closed into one spike when folded) |
| Starling | Triangular pointed wing, square tail, long yellow bill, pale speckles |
| Pigeon | Swept pointed wings, small head, two dark wing bars, green neck, dark tail band |
| Crow | Five fingers, heavy bill |
| Gull | Crooked M wing (arm +15°, hand −2°), black tips |
| Hawk | Broad, nearly flat wing with five short fingers, rufous fan tail, deep chest and short neck, pale belly with a dark band, dark patagial bar underneath |
| Eagle | Plank wing held in a shallow V (arm 10°), seven fingers, big head and heavy bill projecting well forward, golden nape, tawny covert panel |

**Rig in vertex attributes, animation in the shader.** Each vertex carries
its group (body, arm, hand, tail, leg, head; group 6 is the marker, in its
own mesh), its side, its pivots (shoulder, wrist, tail base, hip, neck) and
a few weights, in CUSTOM0–3 and UV. The shader computes the pose from
INSTANCE_CUSTOM:

| INSTANCE_CUSTOM | Holds |
|---|---|
| x | phase |
| y | amount |
| z | fold (12 bits) + perch (12 bits) |
| w | edible (8 bits) + danger (8 bits) + seed (8 bits) |

All values stay below 2^24, so they are exact in a float. There is no
skinning, and no per-bird material or node. Bank is a roll in the instance
transform. Wing vertices also carry the fold hug in UV2 (below), and every
vertex carries its species' readable angle in COLOR.a (the highlight tint).

**The wingbeat** (`BirdPose`):

- *Downstroke:* 42% of the cycle. The leading edge goes down, the tips
  bend up under load, and the hand trails through the turns.
- *Upstroke (58%):* the wrist flexes. The arm shortens and sweeps back; the
  hand drops, sweeps and twists open. This is a real bird's recovery
  stroke, with less area than the power stroke.
- *Hand:* its own rotation grows linearly from wrist to tip, so it bends
  like a flexible plate instead of creasing at one joint.
- *Elevation:* runs +50° to −38°, scaled per species (eagle 0.65 up to
  wren 1.1), and is C1-smooth at both turns.
- *Body:* bobs 1.4% of the span against the beat.
- *Folding:* the beat fades as (1 − fold)², because birds don't beat a
  folded wing.

**The fold.** The wing rotates about the root's leading edge (the
shoulder): it sweeps back 84°, the arm shortens to 28%, and the glide
dihedral is flattened.

- *Gather:* each vertex slides along the chord by a baked distance, so the
  folded wing keeps only part of its chord (the feathers stack). The gather
  leads the sweep (1 − (1 − fold)²), so by half fold the trailing edge at
  the wrist is mostly gathered and the sweep cannot swing it into the flank.
- *The hand narrows to its tip* (round 3): beyond the wrist the kept chord
  falls to 0.55 of the wrist's at the plate's end, taken off the leading
  edge (the outer side of a folded wing), so the trailing edge still lies
  along the back where the wrist's share puts it. Kept whole, a folded hand
  stood out beside the tail by its own width behind the rump (0.031–0.037
  span).
- *The primaries stack* (round 3): folding, each slotted primary turns
  about its own root until it lies along the span like the rest of the
  folded hand (a shear along the chord: every finger keeps its triangles
  the right way round, and fingers whose roots only touched stay side by
  side). A folded crow, hawk or eagle wing now ends in a stack of parallel
  primaries, staggered along the wing (12% of the spread fan across it),
  not a comb (32–34% before). A fan closed by compressing the chord
  towards the leading edge turned the swept-back fingers inside out (40–54
  inverted triangles), so the shear it is.
- *Roll:* the wing rolls so its upper surface faces out: −70° perched,
  −55° in a dive (a tight teardrop).
- *Hug:* the rotations alone lay the folded wing as a straight plate on the
  upper flank, while the body narrows behind its widest point, so its back
  half stood off the body by up to 0.09 span (round-2 verifier). Each wing
  *station* (a spanwise position: every vertex across the chord and both
  surfaces, so the plate keeps its shape) also moves in towards the
  midline, and up where it must clear the tail, by a baked amount (UV2,
  applied as fold³, so a half-folded or flapping wing barely moves):
  - the target is the inner edge just inside the body's outline seen from
    above (0.004 span in), and next to the midline behind the rump; the
    station before the rump comes in far enough that its chord to the next
    station passes the rump within 0.006 of it;
  - limits: every vertex stays outside the body's ellipse ×1.03 and at
    least 0.005 off the midline (the other wing is its mirror), and beside
    or 0.004 above the tail, in five perch blends (perched, dive and three
    between: the tail cocks and the droop changes); among six lifts
    (0–0.02) the one that gets furthest in wins;
  - neighbouring stations differ by at most 0.4 × their distance along the
    folded wing (in only ever shrinks, up only ever grows), so the plate
    bends smoothly and never through itself; the slotted primaries go with
    the plate's end.
  The table is computed once per species from LOD0 (about 4 ms) and every
  LOD uses it by spanwise position.
- *Rump:* the body ends in a short horizontal edge as wide as the tail's
  base (at least 0.3 × W), not in a point, so the wings converge onto
  something and the tail comes out of the body.
- *Perched droop:* each species has its own droop (`anim[4]`, 5–20°), so
  its folded wing lies along the back with the tips just above the tail
  (0.001–0.021 span above it; the swallow's 0.059, see thresholds).
- *Tail:* it closes as the bird folds, on the same leading curve, by a
  per-species share (45%; the wren's 55%, a narrow cocked tail between its
  wingtips; the swallow's fork 70%, into one spike). Its upper surface has
  a low central ridge (0.3 × its half-width), so a tail seen exactly
  side-on is a thin wedge, not an invisible line.

**Perching.** The body pitches nose-up (10–22° by species) while the head
counter-pitches, so the bill points exactly as in flight. The legs swing
down to hang vertically, with the feet exactly one SizeRules body radius
(0.16 × span) below the body centre. That is the perch grip point
(`Perch.position`). Perched birds look around in short held glances,
seeded per bird and driven by `TIME`.

**No pops, no poison.** `BirdModel` shows smoothed values, and a field set
to NaN or INF for a frame is ignored (the last good value stays; a
smoothed value that is not a number restarts from the fields), so one bad
frame can no longer hide a bird or kill its banking for good. A model
scaled to 0, or put at a NaN or INF position, draws nothing, with finite
numbers in its batch, and is drawn again as soon as its transform is sane.

- `flap_amount`, `wing_fold`, `perched`, `bank` and `highlight` use
  exponential time constants of 0.08–0.16 s.
- `flap_phase` follows the owner's beat, measured in cycles per second. The
  owner's step each frame is read forwards or backwards, whichever matches
  the beat it has been showing. Owners beat forwards: a 50 ms hitch at
  16 Hz is 0.8 of a beat, which a shortest-path reading takes for −0.2.
- The drawn phase catches up at 1.6× the owner's beat over the frame's real
  time. So a steady beat of any frequency, and a hitch, are drawn exactly,
  and the wings never play backwards unless the owner goes back.
- A jump of a still owner becomes a sweep of 0.02 cycles per frame.
- `snap()` skips smoothing.

**Batching.** One MultiMesh per (world, species, LOD, layers, shadows).
Each model writes its 3×4 transform and custom data into its batch's float
buffer. Once per frame, at `RenderingServer.frame_pre_draw` (after all game
logic), `BirdBatch.sync_all` does four things in order:

1. Ticks every model.
2. Moves the models whose LOD changed into their new batch.
3. Adds the birds that became highlighted to their world's marker batch
   (and drops the ones whose highlight has faded), then copies every marked
   bird's transform and data into it.
4. Only then uploads every batch.

A bird changing LOD is therefore drawn in that very frame, including when
its new batch had to be created or to grow (which reallocates its GPU
data). Removal swaps the last bird into the hole; the MultiMesh draws only
the live count (the slots past it hold stale data, checked rendered), and
empty batches free their RIDs. Headless runs never draw, so tests call
`BirdBatch.sync_all(dt)` themselves.

The **marker batch** (one per world and render layers, only while some bird
there is highlighted) draws `BirdModels.marker_mesh()` for each highlighted
bird with the bird's own transform and data: one extra draw call, no
shadow, never frustum-culled (a far bird's marker reaches well beyond its
box). The birds' own meshes carry no marker geometry.

**Meshes are built per species.** The first call for a species builds all
three of its LODs (LOD0 first: the far LODs take its normalisation, hug
table and readable angle), about 8 ms on an M1, when its first bird is
attached. So a bird flying out across a LOD threshold never builds a mesh
inside the frame's sync (round-3 verifier: 17 ms the first time a species
went far). `BirdModels.prewarm()` builds all 30 (74 ms) for a loading
screen.

**LOD** is chosen by the wingspan's angular size from the viewport's
camera, *before* a model joins a batch. A bird spawned far away starts at
LOD2, and one shown again close up starts at LOD0.

| LOD | Wingspan seen | ≈ px on a Quest Pro | Triangles |
|---|---|---|---|
| 0 | > 2.9° | > 58 | 272–388 |
| 1 | 0.9–2.9° | 18–58 | 116–168 |
| 2 | < 0.9° | < 18 | 52–64, no shadow pass |

A 12% hysteresis stops flicker at the thresholds. Every LOD keeps the exact
wingtip vertex, so the span is 1.0 at all of them. LOD1 has three (wider)
fingers; LOD2 has no legs or eyes and averages the colour bands.

**Far LODs cover LOD0's area.** Fewer rings, sides and wing stations cut
every curve inwards, so LOD1 used to draw a bird 10–15% smaller than LOD0.
Each far LOD scales its body rings' width and height and its head so their
silhouettes from above and from the side cover LOD0's (computed
analytically from the rings), stretches its wing chords so the plate
covers LOD0's area (the root and the plate's end keep theirs, so the span
stays 1.0), keeps the mid-hand station nearest the tip, uses a six-sided
head at LOD1 and widens its three fingers to 0.95 of all of them. From
above and the side LOD1 covers 94–100% of LOD0.

**Edge-on wings.** The arm carries a leading-edge ridge. Large birds (the
600-triangle budget) continue it along the hand, and give each slotted
primary a raised spine: the fingers' roots just touch rather than overlap,
so a spine can't pierce its neighbour. A crow, hawk or eagle flying
straight at the player shows its wings as continuous thin lines out to the
fingertips. Small birds have no triangles to spare (276–294 of 300), and
their thin wings vanish head-on as real ones do.

**Highlight.** It must say "edible" or "danger" against everything the
world has, at every distance a bird can be highlighted (GameLoop highlights
within max(70 player spans, 6 s of cruise), about 50 m for a sparrow), with
a shape cue for colour-blind players, without lying about the bird's size
and without erasing what species it is (the brief: "shape and colour say
what a bird is from a distance"; "readability tint/outline states").

- *Hues:* chosen from Oklab distance to every `Palette` colour, then
  confirmed by the rendered measurement below. Edible is a deep
  blue-violet, `#4020f0`, 0.23 from the nearest palette colour (deep
  water). Danger is magenta, `#ff00c8`, 0.22 from the nearest (a flower
  red). They also differ in lightness, and edible pulses slowly while
  danger pulses fast.
- *The marker, at every distance:* a thin **ring** (32 sides) for edible, a
  **warning triangle** for danger, in the state's hue, self-lit, facing the
  viewer (in stereo the centre between the eyes, so both eyes see one flat
  marker). Far away it has a fixed angular size (0.32° radius: a 13 px
  ring on a Quest Pro around a bird of a few pixels); once the bird is
  bigger it sits just outside the wingtips (0.62 × the bird's drawn angle;
  the triangle's corners 1.65× further, so its edges pass outside the
  wingtips too). Its line is 0.1° wide (2 px), growing with a near bird's
  ring to at most 0.23° (4.6 px): a fine line, never a heavy band. It never
  thins below 0.1° (a line under a pixel wide breaks up and shimmers); only
  the state's own 0.1 s blend in and out thins it. It casts no shadow.
- *The bird itself:* while it is smaller than its species' readable angle
  (`min_highlight_angle`: 0.69° wren … 1.60° moth, where its body is about
  2.5 px thick and its plumage cannot be told apart) it is drawn mostly
  self-lit in the hue (90% of the plumage gives way to the hue at 0.25 lit
  albedo, plus 1.3 × hue unlit), so the dot inside the marker is the state
  colour too. From 1× to 1.8× its readable angle the tint eases out; from
  there on (by 2.9° for every species, 1.2–1.6° for most) the bird is drawn
  in exactly its own plumage, with no tint, dye or rim.
- *True size:* a highlighted bird is always drawn at its true size, so it
  looms exactly as the player closes in and prey never looks bigger than
  the hunter.

Why this design (round 3): the round-2 look painted every highlighted bird
under 6.9° across 90% in the hue, and 45% up close. In play that is nearly
every bird that matters, so seven species became the same violet or
magenta cutout (verifier: at 3° all 45 species pairs closer than 0.05 in
Oklab). A partial tint cannot keep B1's distinctness: mixing every bird
towards one colour shrinks every pair's distance, and the closest pairs sit
at 0.06. A rim on flat-shaded faces recolours whole facets (tried: up to
0.068 change at 25°). So the plumage stays exact and the marker, which
already carried the state far away, carries it at every distance. Keeping
the marker whole also removes the round-2 fade band, where the line thinned
below a pixel and the measurement failed (engineering verifier).

**Colours** are stored as sRGB bytes and linearised in the shader (8-bit
linear crushed the dark plumage). **FX** use their own tiny materials: the
feathers are two-sided and lit through; the trails are unshaded alpha
strips. The birds and their markers use exactly one material.

**Feather bursts** scale with the prey: speed = 2.3 m/s × (span /
0.24)^0.85, and small feathers or scales sink more slowly. Half a second
after any catch the feathers cover 0.7–1.6 of the prey's wingspan.

**Wingtip trails** are built from fixed ring buffers (no allocation per
frame) as one triangle strip, 2 vertices per point. A trail that isn't
showing only tracks its bird's speed. At most 12 draw at once, the nearest
to the camera. A trail is ranked from the frame after it first wants to
draw, and one the budget cuts fades out fast (τ 0.04 s) and is dropped as
soon as it is too faint to see (strength 0.15, alpha 0.05). So 40 trails
starting together never draw more than 12, and a handover to nearer birds
is back to 12 within 6 frames.

## Perfection criteria — how each is verified

Headless suite (65 tests, 1406 assertions, about 32 s):

```bash
tools/gd.sh birds --headless res://tests/runner.tscn -- --suite=birds
```

Rendered evidence. Each script quits itself and exits 1 on failure (lineup
and flap: a cell that shows no bird; fx: a leaked node or a burst that ends
at once); outputs go to `artifacts/birds/`.

```bash
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_lineup.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_flap.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_gpu_check.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_lod_check.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 1600x900 res://tests/shots/birds_highlight.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_fx.tscn
tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 res://tests/shots/birds_flock.tscn
tools/gd.sh birds --rendering-method mobile       --resolution 640x360 res://tests/shots/birds_flock.tscn   # Quest renderer counts
tools/xr.sh 70 res://tests/shots/birds_xr.tscn -- --xrshot=12 --xrshot_dir=birds --xrshot_prefix=xr_birds  # Meta XR Simulator
tools/gd.sh birds --rendering-method mobile --resolution 1280x960 res://tests/shots/birds_xr.tscn -- --desktop_quit=14  # its desktop baseline
tools/gd.sh birds --rendering-method forward_plus res://scenes/dev/birds_dev.tscn -- --shot=4
tools/gd.sh birds --rendering-method forward_plus res://scenes/dev/birds_dev.tscn -- --shot=4 --highlight=1 --mode=5 --dist=9
```

(Under heavy machine load the highlight shot can outrun `tools/gd.sh`'s
300 s guard: prefix `GD_TIMEOUT=1800`. It takes about 8 minutes;
`-- --passes=identity,close` alone takes 20 s.)

**The shader and `BirdPose` are proven equal** by `birds_gpu_check`. It
renders 84 cases (7 species; beat phases, half and full tuck, fold/perch
blends, a perched beat, perched; 3/4, front and side views) with the real
shader and with a mesh posed by `BirdPose`. It compares them twice:

1. *Silhouettes:* pixels of one silhouette with no pixel of the other
   within 1 px, both with back faces culled as the bird material does.
   Worst **0.40%** (limit 0.5%): two pixels at the tip of the perched
   swallow's narrowed hand, a sub-pixel sliver, where the positions agree
   exactly.
2. *Positions:* a copy of the real shader code whose fragment writes each
   pixel's posed model-space position as its colour, against the CPU mesh
   carrying `BirdPose`'s positions through the same encoding. The colour is
   8-bit sRGB, so a position reads to within one byte: 0.001 span at the
   dark end of the encoding, 0.0075 at mid-grey, 0.011 at the bright end.
   The limit, 0.012 span, is just over one byte anywhere. Inside both
   silhouettes the 99th-percentile error is **0.0000** in every case, the
   fold hug, the hand narrowing and the stacked primaries included.

Shader-only changes still fail it: one perched fold angle by 2° fails 9
cases, the hug weight fold³ → fold² fails 7 (round 2). So every vertex test
below tests what is drawn.

### B1 — distinct silhouettes and colouring

`birds_silhouette_test.gd`:

- **Silhouette IoU** is taken pairwise over the 45 pairs, glide pose, equal
  span, 160 px grids. Top-view maximum **0.800** (hawk/eagle), side-view
  maximum **0.786** (wren/sparrow); limit < 0.85. The same limit holds at
  LOD1 (0.799), at the bottom of the downstroke (0.792) and at the top of
  the upstroke (0.800), and (new this round) in the resting poses players
  see most:

  | Pose | From above | From the side |
  |---|---|---|
  | Perched | 0.795 (sparrow/pigeon) | 0.787 (starling/hawk) |
  | Dive tuck | 0.795 (crow/eagle) | 0.802 (starling/hawk) |
  | Half tuck | 0.804 (wren/sparrow) | 0.789 (pigeon/hawk) |

  The dive-tucked hawk and eagle side-on were 0.852 (round-3 verifier) and
  0.861 once the hands narrowed. Two field marks separate them now: the
  eagle's big head and heavy bill project further forward, and the hawk
  has a deeper chest. The front view is reported (glide 0.735; perched
  head-on every bird is an upright oval).
- **Colour:** the depth-buffered mean colour of the top, bottom and side
  views, in Oklab. Every pair differs by more than 0.05 in its best view.
  The closest pair is starling/eagle at **0.062**; their shapes differ
  strongly (IoU 0.63 top, 0.67 side).
- **Colour when highlighted** (new, `test_highlighted_birds_keep_their_colouring`):
  the same signature through a CPU mirror of the shader's highlight fragment
  (reading the uniform defaults from `bird.gdshader`'s source, so it cannot
  drift), edible and danger at 3°, 10° and 20° across. Every species wears
  its own plumage from 2.87° at the latest (the moth's tint end), every pair
  stays > 0.05 apart (closest 0.062, as unhighlighted), and no bird's
  colours change (0.0000). With the tint lasting to 5× the readable angle (a
  mutation) it fails. The rendered proof is B4's identity pass.
- **Field marks**, judged by what they look like, not by which colour slot
  painted them:
  - *Swallow:* fork depth 0.23 span (everyone else < 0.06).
  - *Fingers:* a chordwise line near the tip crosses 5/5/7 separate fingers
    on crow/hawk/eagle and 1 on everyone else.
  - *Gull:* the wrist sits ahead of the root, with an M-shaped dihedral.
    Dark faces (luminance < 0.2) cover ≥ 40% of the outer upper hand and
    < 5% of the inner wing.
  - *Pigeon:* dark bars cover ≥ 15% of the upper arm.
  - *Hawk:* a rufous tail (≥ 60% of the upper tail); crow, eagle and gull
    have none.
  - *Tails side-on* (new): every tail's ridge is 0.30 × its half-width at
    every LOD (limit 0.2), and the perched wren's cocked tail covers 30 px
    side-on (limit 15; a flat tail, a sandboxed mutation, covers 0).
- **By eye:** `lineup_equal_span.png` (from above, from below, side, front,
  perched, 3/4), `lineup_true_scale.png`, and `highlight_identity.png`
  (every species plain / edible / danger at five sizes).

### B2 — animation

`birds_animation_test.gd`. All poses are computed with `BirdPose`, proven
equal to the shader.

- **Stroke timing:** over 400 phases, tip highest to tip lowest takes
  **0.41–0.44** of the beat for every species (it must be less than the
  upstroke, within 0.35–0.48). Tip travel is ≥ 0.41 span per beat, the wings
  are still at `flap_amount` 0, and amplitude grows monotonically with
  `flap_amount`.
- **No inversion or collapse:** no wing or tail triangle turns against its
  normal at LOD 0/1/2 over the 36-pose sweep. In flight none shrinks below
  15% of its area (smallest 21%). The upper surface never faces down during
  the beat.
- **No self-intersection** (strict edge-through-triangle test, at every
  LOD, the fold hug, narrowing and stacked primaries included):
  - left wing against right, and each wing against itself: **0**;
  - wings against the tail over the whole fold × perch space (10 folds × 7
    perch blends × glide and 5 beat phases): **0**.
- **Wings stay outside the body:** outer wing vertices stay outside the
  body's ellipse over that whole space (420 poses per species). The closest
  are the wren's 0.990 and the swallow's 0.999 (1 = the surface).
- **Drawn transitions:** real models are driven through smoothing, at a
  9 Hz beat at 72 Hz, for landing, take-off, dive, pull-out, half tuck and
  a perched balance flap. Every other drawn frame is checked for all of the
  above: **0 defects** (108 checked poses per species).
- **Folded wings lie on the body** (`test_folded_wings_lie_on_the_body`,
  the round-2 verifier's measure): 24 slabs along the body, the right
  wing's innermost point minus the body's widest point in each slab.
  Positive is a see-through gap from above or behind; limit 0.012 span. At
  LOD0 the worst is **0.010** perched (wren) and **0.004** in a dive tuck;
  at LOD1 (drawn under 3.2°, limit 1.5 px there = 0.023 span) 0.008.
- **Folded wings keep inside the outline** (new,
  `test_folded_wings_keep_inside_the_outline`, the round-3 verifier's
  measures adopted), perched and dive-tucked:
  - beyond the body's widest point: at most **0.022** span (hawk; limit
    0.03 = the wing's thickness plus the fold's outward offset);
  - flared out beside the tail behind the rump: at most **0.027**
    (sparrow; limit 0.03; was 0.034–0.041 for sparrow, hawk and eagle). The
    wren is measured against its body instead: its tail is cocked 69° up out
    of that plane, so its drooping wingtips (0.045 past the narrow cocked
    tail) are compared with the body's width (0.020 inside the limit);
  - crow, hawk and eagle primaries spread across the wing: at most
    **0.028** (limit 0.04; was 0.059–0.079), 12% of the spread wing's fan.
  Turning the fingers off or the narrowing off (sandboxed mutations) fails
  it.
- **Fold, tuck and perch:**
  - The half tuck is 0.44–0.61 span wide; the full tuck and perched poses
    stay within 2.6× and 2.3× the body width, wingtips back over the tail.
  - Perched wingtips sit 0.001–0.021 span above the tail's upper edge (its
    ridge) in profile (swallow 0.059; the wren's tail is cocked above
    them). The hawk's and eagle's droop is now 7° and 6°: narrowed from the
    leading edge their hands ride higher.
  - Perched, the bill points exactly as in flight (elevation equal to the
    glide pose's within 3°; measured 0.0° off; without the head's
    counter-pitch it would tilt up by the 10–22° body pitch, and the test
    fails) and the body is nose-up. The wren's tail is cocked +69°; the
    others hang −16° to −27°.
  - The moth rests with its wings as a delta roof 0.53 span wide.
- **Bank:** `bank = 0.5` rolls the drawn wingtips exactly 0.5 rad, right
  wing down; negative bank puts the left wing down.
- **No pops:** every field switched abruptly moves the tip at most **18.3%**
  of the way in one frame (limit 25%), and the tip arrives in 23–32 frames.
- **Bad values:** one frame of NaN or INF in `flap_phase`, `flap_amount`,
  `wing_fold` or `bank` leaves the batch data finite on every frame, and
  within a second the beat and the bank are drawn again
  (`birds_highlight_test.test_bad_owner_values_do_not_stick`). A steady
  4 Hz beat is drawn with zero lag.
- **Beat following:** at 72/90/120 fps and 4–16 Hz, both from rest and
  after a 50 ms hitch, no frame steps backwards. The hitch frame is drawn
  as the owner's own step, and the lag is under 0.01 cycle within 0.15 s.
- **Body bob:** 0.01–0.04 span.
- **Evidence:** `flap_strip.png`, `flap_plot.png`, `poses.png` (all 10
  species: glide, half tuck, dive tuck from the top, side and behind,
  perched from five sides, bank), `perched_close.png` (every bird perched
  and dive-tucked, close up: the folded wings on the body, the primaries
  stacked).

### B3 — budgets

`birds_budget_test.gd`, `birds_batch_test.gd`, and the rendered flock, LOD
and XR checks:

- **LOD0 triangles:** small birds 276–294 (limit 300), large birds 272–388
  (limit 600). LOD1 116–168 (≤ 55% of LOD0), LOD2 52–64. No bird mesh
  holds any marker geometry (tested); the marker mesh has 70 triangles and
  is drawn only for highlighted birds.
- **One material:** all 30 meshes and the marker are one surface each with
  the same material. Building all 30 takes **74 ms** (limit 250 ms).
- **No mesh is built inside a sync** (new): the first crow attached builds
  all three of its LODs (8.1 ms, outside the sync); flying it out to LOD1
  and LOD2 then costs **0.04 ms** per sync. Built lazily per LOD (a
  sandboxed mutation) the test fails. In the round-3 verifier's 20-minute
  soak the worst sync is now **1.08 ms** (was 17.1 ms).
- **CPU:** 60 animated birds (10 species, moving, every field changing each
  frame, a camera for LOD) cost a **median 250 µs** per frame, p95 311 µs
  (limit 1000 µs).
- **LOD is what is drawn:** every bird's batch mesh is the mesh of
  `get_lod()`: at spawn far away (LOD2), when shown again close up (LOD0),
  after re-parenting, and in the Ecosystem's add-then-move pattern.
- **GPU in sync:** after every sync each batch's GPU buffer equals its CPU
  buffer, slot by slot, through 24 LOD moves into batches that have room,
  are new, or must grow.
- **Markers** (new, `test_marker_batch_holds_exactly_the_highlighted_birds`):
  one marker batch per world; its instances are exactly the highlighted
  birds, with their own transform and data, at every LOD (a far bird forced
  to LOD0 is marked too); a bird leaves it once its highlight has faded or
  when hidden, and follows its bird to other render layers; no highlighted
  bird, no marker batch.
- **RIDs:** freeing the last bird frees the batch's MultiMesh and instance,
  checked by asking the RenderingServer.
- **Rendered LOD switches (`birds_lod_check` → `lod_check.json/.png`):**
  every frame is grabbed while a sparrow crosses LOD0↔1 (the batch has
  room), an eagle LOD1↔2 (the batch is created by the move) and a hawk
  joins 8 parked hawks (the batch grows). Result: 5 switches, **0 blinks**,
  **0 frames** drawing a LOD other than the one reported, largest pixel
  count change at a switch **4.1%** (limit 6%).
  New: **no ghosts.** Four parked hawks are freed and the rest fly
  elsewhere, leaving 11 stale slots in the grown batch's GPU buffer:
  **0 px** are drawn where any of them was (`lod_check_ghosts.png`).
  Without the MultiMesh's visible-instance count (a sandboxed mutation):
  183 px.
- **Rendered flock (`birds_flock` → `flock_perf*.json`):**

  | Renderer | Sync (median, p95) | Draw calls | Primitives | LODs drawn |
  |---|---|---|---|---|
  | Forward+ (Mac) | 251 µs, 276 µs | 51 (depth pre-pass and shadows) | 37k | 9 / 36 / 15 |
  | Mobile (Quest) | 264 µs, 281 µs | **19** (one of them the markers) | 37k | 9 / 36 / 15 |

  Also 0 models drawing another LOD than they report. The architecture
  budget is ≤ 150 draw calls and ≤ 300k triangles for the whole frame.
- **In XR (new, `birds_xr` → `xr_perf_xr.json`, `xr_birds_12s.png`):** 60
  birds (every species close up flapping, at 40 m edible and danger,
  perched at 5 m, and 20 wheeling at 15–70 m) in the Meta XR Simulator
  (Mobile, multiview, 72 Hz), 70 s, 4870 frames: sync **median 287 µs, p95
  309 µs, p99 346 µs**, max 788 µs (gate: p95 < 1000 µs); 38 draw calls and
  50.5k primitives for the whole frame; 0 frames with a bird in the wrong
  batch; the markers draw in both eyes. Desktop Mobile, same scene: 277 /
  326 / 344 µs.
  *Where the tail comes from:* the shot times the same fixed GDScript
  workload right before and right after the birds' sync, and each bird's
  own tick. In the frames where the sync is over 1.8× its median (8 of
  4870 in this run, 49 of 1718 in a busier one), the canary right *before*
  the sync is **2.85×** slower too, the one right after is not (1.00×), and
  every bird's tick is uniformly **3.1–3.4×** slower. The main thread runs
  about 3× slower at that moment of the frame (the simulator's threads, or
  the core it runs on), so no per-bird cost spikes. The round-3 verifier's
  canary ran only *after* the sync, when the slow moment had passed.
- **Trails** (`birds_fx_test`), for 60 birds with trails attached: an idle
  trail costs **0.8 µs** per frame, a drawing trail **30 µs**; 40 fast
  birds with 12 trails drawing cost **0.51 ms** in all.
- **Quest CPU estimate:** at 3–4× the M1's single-thread time, about
  0.9–1.2 ms per frame for 60 birds, or up to ~2 ms with a dozen trails
  drawing.

### B4 — highlight readable at 40 m

`birds_highlight` (exits non-zero on failure) → `highlight.json`, and
`birds_highlight_test.gd` headless.

- **Light:** the world's own daylight (`WorldSky` "day" and the Palette,
  loaded at run time). The camera has Quest Pro pixel density (20 px/deg).
- **Birds and backgrounds:**
  - *dist:* all **10 species × 3 states** at **40 m** and **16 m**, against
    the sky (looking up 8°, wings nearly edge-on) and, from 35° above, 16
    large world surfaces: grass, meadow, wheat, ploughland, forest canopy
    (light and dark), conifers, water (shallow and deep), red and
    terracotta roofs, the barn red, slate roofs, rock, sandstone, white
    walls;
  - *band* (new): every species at **1.0, 1.2, 1.4, 1.8 and 2.5 × its own
    readable angle** (the whole span of the tint's ease, 1.0–1.8×) over
    six backgrounds (sky, white wall, meadow, deep water, red roof, dark
    canopy), so no distance between 16 and 40 m hides a weak spot (the
    engineering verifier found 18 failures at 38–48 m in the round-2 fade
    band).
- **Measurement:** the pulse is pinned to its dimmest and to its brightest
  (the shader's `pulse_test`), and the worse counts. Colours are means over
  core pixels (the half that differs most from what is behind them:
  antialiased edges are mostly background), in Oklab.
  - *The marker, everywhere:* its own pixels are where the frame with the
    markers differs from the same frame without them. It must cover at
    least 24 px, differ from what is behind it by ≥ 0.15, from the plain
    bird by ≥ 0.12, and edible's from danger's by ≥ 0.15.
  - *The whole bird box (bird + marker):* required where the bird itself is
    tinted (at or under its readable angle): highlighted vs the same bird
    unhighlighted ≥ 0.12, edible vs danger ≥ 0.15, highlighted vs background
    ≥ 0.15. Above that angle it is reported: there the bird wears its own
    plumage by design, and a dark or pale bird out-contrasts its thin marker
    in the "core" half (a hawk on a white wall: 0.042), so that number
    measures the plumage, not the cue.
- **Results (Oklab 0.02 is about one just-noticeable difference):**

  | Comparison | Worst over 10 species × 3 states × (17 backgrounds × 40/16 m + 6 × 5 band sizes) | Threshold |
  |---|---|---|
  | Marker vs the plain bird | **0.161** (2.5× sky, swallow) | 0.12 |
  | Edible marker vs danger marker | **0.172** (16 m dark canopy, eagle) | 0.15 |
  | Marker vs background | **0.193** (1.0× deep water, eagle) | 0.15 |
  | Tinted bird vs unhighlighted | **0.164** (16 m water, swallow) | 0.12 |
  | Tinted edible vs danger | **0.179** (40 m white wall, starling) | 0.15 |
  | Tinted bird vs background | **0.184** (1.0× deep water, gull) | 0.15 |

  **0 failures.** Mutations through the shot's own uniform overrides: markers
  of zero width fail 78 cases at 40 m (sky, roofs).
- **Identity and the marker, one bird at a time** (new, *identity* pass,
  over the meadow): every species at 0.8× and 1.5× its readable angle and
  at 3°, 10° and 25° across, in each state:
  - with the marker hidden and the pulse at its brightest, a highlighted
    bird's own pixels from 3° up equal the plain bird's: mean Oklab change
    **0.000** (limit 0.02) — the highlight takes nothing from its colours.
    With the tint lasting to 5× the readable angle (the round-2 kind of
    look) it fails 20 cases, worst 0.298;
  - the marker is where the shader puts it (its extent within **2.3 px** of
    the expected radius, limit 3 px) at every size, from a 13 px ring
    around a 5 px bird to one around a 25° bird; unhighlighted birds draw
    nothing beyond themselves;
  - the marker's own pixels are clearly coloured: Oklab chroma ≥ **0.127**
    (limit 0.12; the hues are ~0.3), and at least 12 px.
- **Size (headless):** every hunter/prey pair the game can highlight (21:
  the player is never lighter than GameLoop's start mass, a sparrow) is
  flown in from 160 m to 0.3 m in 3% steps, and every species in both
  states with no player registered: the drawn angle grows at every step,
  the drawn span equals the true span (off by < 1e-4), and no prey is ever
  drawn wider than the hunter's own wingspan (the widest is 0.825 of it: a
  swallow hunted by a starling).
- **Marker geometry (headless):** a 32-sided ring and a triangle, every
  vertex at the origin, wound to face the viewer, drawn with the one bird
  material; the shader's copies of the ring's sides and of READABLE_MAX
  match the GDScript constants; every vertex of every bird LOD carries its
  species' readable angle in COLOR.a (8 bits).
- **Images:**
  - `highlight_40m.png`: all 30 birds against the sky at 40 m, as the
    headset sees them; `highlight_40m_roofs.png`: over the red roofs;
  - `highlight_zoom_40m.png`, `highlight_zoom_16m.png`: every bird × 3 over
    every background; `highlight_zoom_band.png`: the band over sky and
    meadow;
  - `highlight_identity.png`: every species plain / edible / danger at the
    five identity sizes;
  - `highlight_close.png`: four species at 8° across, plain / edible /
    danger;
  - `dev_aviary_hl1_mode5.png`: the aviary with every bird edible and
    perched.

### B5 — FX

`birds_fx_test.gd` and `birds_fx` (exits 1 on a leaked node):

- **Motion:** a sparrow burst spreads to 0.2 m (almost a wingspan) in
  0.25 s, then sinks at 0.47 m/s (limit 0.1–1.2). Every species spreads
  **0.73–1.59** of its own wingspan at 0.5 s (limit 0.4–1.6; largest to
  smallest < 2.5×).
- **No leaks:** a burst frees itself after its lifetime, with the node
  count back to where it started. 25 bursts leave no nodes, orphans or
  objects.
- **Catches:** `catch_burst` reads the prey's species, span, position and
  velocity. `BirdFXDirector` makes one burst per `Events.bird_caught`.
- **Trails:** off at cruise, full in a 2.4× cruise stoop, gone again within
  1 s at slow speed. The budget (new, `test_trail_budget_holds_from_the_first_frame`):
  40 trails starting in the same frame draw at most **12** in every frame
  (the round-3 verifier saw all 40 for 30 frames); when 12 nearer birds
  overtake them the handover draws at most 23 for 4 frames and is back to
  12 within 6. Without dropping the cut trails (a sandboxed mutation) it
  fails.
- **Evidence:** `feather_burst.png` (sparrow, pigeon and hawk catches,
  0–2.2 s), `wing_trails.png` (stoop against cruise) and `fx_report.json`
  (0 leaked nodes; bursts live 2.3 s; trail strength 0.96 in the stoop, 0 at
  cruise).

### B6 — conventions

`birds_conventions_test.gd`:

- **Wingspan:** exactly **1.0000** (±1e-4) in the rest-mesh AABB and in the
  drawn glide pose, at every LOD of every species, centred on x = 0.
  Through the public API, `get_wingtip` at scale 2.1 puts the tips 2.1 m
  apart.
- **Beak towards −Z:** the foremost vertex is the beak, ahead of z = −0.2
  and near the midline; the tail is at +Z.
- **Origin:** the body loft's bounds are centred on the origin (±1e-4).
- **Symmetry and faces:** every vertex has a mirror twin, and every face is
  flat and wound for Godot's clockwise front faces.
- **Feet:** perched, they reach exactly `SizeRules.body_radius_for_mass /
  wingspan_for_mass` below the body centre (0.160 span: the perch grip),
  checked against SizeRules itself; in flight they are tucked (above −0.11).
- **Factory:** `create()` returns a child-less `BirdModel` with all the
  contract fields; an unknown species warns and draws a sparrow.
- **Scaled to nothing, or put at NaN:** a highlighted bird at scale 0 or
  1e-9 is drawn at that size with finite numbers in its batch; one put at
  a NaN or INF position draws nothing with finite numbers and is drawn at
  its position and size again once that is sane
  (`birds_highlight_test`; without the guard, a sandboxed mutation, it
  fails).

`birds_batch_test.gd` adds:

- species batching, slot bookkeeping on removal, and visibility of the
  model or a parent;
- leaving or re-entering the tree, and species change;
- LOD walking 0→1→2→1→0 with the new mesh drawn in the switch frame and no
  flicker at a threshold;
- exact encode/decode of the packed instance data, transform, scale and
  bank;
- pause freezing the smoothing;
- (`birds_highlight_test`) setting `render_layers` or `cast_shadows` moves
  the bird into a batch with that layer mask or shadow setting, drawn once;
  `get_wingtip` is the drawn transform × the posed tip, banked, highlighted
  or not.

## Evidence index (`artifacts/birds/`)

| File | Shows |
|---|---|
| `lineup_equal_span.png` | 10 species × top / bottom / side / front / perched / 3/4 at span 1 |
| `lineup_true_scale.png` | the ladder at true relative size (2.3 m windows) |
| `flap_strip.png`, `flap_plot.png` | one wingbeat in 10 frames; tip height over the beat |
| `poses.png` | glide, half tuck, dive tuck (top, side, behind), perched (side, top, behind, 35° above-behind, 3/4), bank, all 10 species |
| `perched_close.png` | every bird perched (5 views) and dive-tucked (top, behind), close up: the folded wings on the body, the primaries stacked |
| `gpu_vs_cpu.png/.json` | shader against BirdPose, 84 cases: silhouette overlays (top) and position error maps (bottom) |
| `lod_check.png/.json`, `lod_check_ghosts.png` | frame-by-frame bird pixels through 5 LOD switches (0 blinks, largest area jump 4.1%); the frames before, of and after each; the frame after freeing and moving hawks (0 ghost px) |
| `highlight.json`, `highlight_40m.png`, `highlight_40m_roofs.png`, `highlight_zoom_40m.png`, `highlight_zoom_16m.png`, `highlight_zoom_band.png`, `highlight_identity.png`, `highlight_close.png` | highlight readability (markers, tinted tiny birds, the band, identity), measured and seen |
| `feather_burst.png`, `wing_trails.png`, `fx_report.json` | FX sequence, trails, leak counts |
| `flock.png`, `flock_perf.json`, `flock_perf_mobile.json` | 60 birds: CPU, draw calls, primitives, drawn LODs |
| `xr_perf_xr.json`, `xr_perf_desktop.json`, `xr_birds_12s.png` | 60 birds in the Meta XR Simulator: sync percentiles and phases, the canaries, the mirror view |
| `dev_aviary.png`, `dev_aviary_hl1_mode5.png` | the dev scene; all edible and perched |
| `../tests/report_birds.json` | every test's numbers (metrics per test) |

## Thresholds I set and why

- **Perched width ≤ 2.3× body width.** The folded wings sit on the flanks,
  so the width is the body plus two wing layers plus the outward offset.
  2.3× admits the slimmest body (the gull, 0.089 span wide) with its long
  folded hand.
- **Moth bounds.** A resting moth holds its wings as a low delta roof 40–55%
  of its span wide (noctuid moths), not tucked: 0.40–0.60 perched and
  0.60–0.92 at half fold.
- **Perched wingtips 0–0.065 span above the tail's edge** (round 1).
  Most species sit at 0.001–0.021. The swallow sits at 0.059: its long
  wings lie on its back above the closed streamers, and any more droop
  carries the half-folded hand through them.
- **Folded wing gap < 0.012 span** (round 2): the round-2 verifier's
  measure and limit, perched and in a dive tuck at LOD0. At LOD1, drawn
  only while the whole wingspan is under 3.2° (64 px), the limit is 1.5 px
  there (0.023 span).
- **Folded outline** (round 3): the round-3 verifier's measures and limits
  as proposed (beyond the widest point 0.03, flare behind the rump 0.03,
  primaries across the wing 0.04). One deviation, argued above: the wren's
  flare is measured against its body, because its tail stands 69° up out
  of the plane the flare is measured in.
- **Tail ridge ≥ 0.2 × half-width; perched wren tail ≥ 15 px side-on**
  (round 3): the ridge is 0.3 by design; 15 px is half of what it draws
  (a flat tail draws 0).
- **LOD switch area jump ≤ 6%** (round 2), for birds of ≥ 80 px: the
  flight alone moves a bird's pixel count 1–2% a frame, and the verifier
  saw 9–12.5%; 6% is clear of both.
- **Ghost pixels ≤ 4** (round 3): antialiasing noise; a ghost hawk is
  40–50 px.
- **Highlight: what is measured** (round 3). The thresholds are unchanged
  (0.12 / 0.15 / 0.15). What they are applied to follows the design: the
  cue. Until round 2 the cue was the tinted bird itself, and the whole-box
  core colour measured it. Now the bird keeps its plumage above its
  readable angle and the marker is the cue, so the marker's own pixels are
  measured, at every size, with the same thresholds; the whole box stays
  required wherever the bird is tinted. Measuring plumage against a
  threshold for a tint would just demand the tint back, which is what
  erased the species (the major finding). Stricter than before in scope:
  the band adds 5 sizes per species, and the identity pass adds a check
  the old design failed.
- **Identity ΔE ≤ 0.02** (round 3): one just-noticeable difference in the
  mean: the highlight must not visibly change a bird's own colours. It
  measures 0.000.
- **Marker chroma ≥ 0.12, ≥ 12 px; extent within 3 px** (round 3): the
  round-2 close-up chroma limit, now on the marker; 3 px is antialiasing
  plus the pixel grid (the ring's radius is set to a fraction of a degree).
- **Marker width 0.1–0.23°** (round 3): 2 px on a Quest Pro is the thinnest
  line that does not break up; 4.6 px keeps a near bird's ring a line, not
  a band.
- **Highlight core-pixel metric.** With a bird covering 6–50 px, over half
  its pixels are antialiased edges blended with the background, which pulls
  every bird's mean towards the background whatever its colour. The core
  pixels are what the eye reads.
- **GPU/CPU: silhouettes and positions.** Wings seen edge-on are 1–2 px
  thick, so raw IoU mostly measures antialiasing. The 1-px-tolerant
  mismatch catches outline changes, and the position encoding catches any
  posing difference inside the outline. 0.012 span is one byte of the
  encoding anywhere; it still catches a 2° shader-only fold change.
- **XR sync p95 < 1 ms** (round 3): the brief's 1 ms budget, as a tail
  rather than a median (the round-3 verifier's ask).

## Fix round 1 — the verifiers' findings

| Finding | What was done |
|---|---|
| Major: LOD switches blank birds for a frame (a whole batch when it grows) | `sync_all` uploads every batch after the LOD moves, and `_grow` no longer leaves a frame with cleared GPU data. Tested headless (GPU buffer = CPU buffer after every sync, 24 moves) and rendered (`birds_lod_check`: 0 blinks; 12 with the old order). Both verifiers' render probes now report no missing frames. |
| Major: drawn LOD ≠ reported LOD (`_attach` ignored its own LOD choice) | The LOD is chosen before the model joins a batch. Tests assert the batch mesh is `mesh(species, get_lod())` at spawn, re-show, re-parent, the Ecosystem pattern and in the 60-bird flock; the LOD histograms come from the drawn meshes. |
| Major: the danger highlight vanished over red roofs; small species were unverified | New hues far from every palette colour, a self-lit far look, and a minimum drawn body size (replaced in round 2 by true size and the marker). Verified for 10 species × 17 backgrounds × 40/16 m in world light: 0 failures. |
| Minor: the swallow's wing passed through its tail while landing; wren/crow wings dipped into the body | Per-species perched droop (the old 22° put wings under tails), a gather that leads the sweep, and a per-species tail close. The whole fold × perch × beat space and six drawn transitions are now tested: 0 crossings, 0 intrusions. |
| Minor: the drawn beat ran backwards after a hitch / from rest | The beat is tracked in cycles per second and each owner step is read in the beat's direction. Tested at 3 frame rates × 4 beat rates. |
| Minor: trails were expensive | Ring buffers, one strip, a cheap idle path, and at most 12 trails drawing: 30 µs per drawing trail (was 63), 0.73 µs idle (was 2.2); 60 birds with 10 stooping 0.52 ms (was 0.91). |
| Minor: stale "teal" comments, dead code | Fixed: `species_ids()` and the dead shader constants removed; finger counts (5/5/7) and prewarm time (33 ms, measured) corrected. |
| Minor: edge-on wings vanished head-on; fingertips floated | Hand ridge and finger spines on large birds (see Design decisions). |
| Minor: the highlight tint hid the plumage | Full tint only where the bird is too small for plumage to be told apart. From 7° across it eases to 45%, with a rim of the hue (`highlight_close.png`). |
| Minor: tests that could not fail (RID release, feet, gull tips, GPU tolerance) | RID release is checked through the RenderingServer, feet against SizeRules, gull tips and pigeon bars by darkness and the hawk's tail by hue, and the GPU check compares positions. Each was mutation-tested: the skipped `free_rid`, feet at 0.22, grey gull tips, and a 2° shader-only fold change all now fail. |
| Minor: the moth's burst spread 2.4 spans, the eagle's 0.3 | The burst speed and sink scale with the prey: 0.73–1.59 spans for all. |
| Side effects on other areas' reports | Compatibility runs of other suites now go through a private sandbox with artifacts redirected. The AI behaviour and flight-envelope, game threat/danger/loop-shift/state/mechanics, VR wings, and UI flow/pointer suites pass: 130 tests. |

Verifier probe results that I believe are measurement artefacts, not
defects:

- `birds_verify_pops_perf_test.test_fast_beat...` counts 2 "backwards"
  frames at 16 Hz. They are frame 0 after `snap()` (compared against the
  pose before the snap) and the hitch frame, where the owner itself
  advanced 0.8 of a beat. In both the model shows *exactly* the owner's
  phase (shown 0.222 = owner 0.222; shown 0.800 = owner 0.800). No later
  frame steps backwards.
- The same probe's "60 birds with trails forced on for all": 1.09 ms (was
  4.1 ms). It sets `min_speed = 1` so every bird trails while diving
  2–250 m every second, and trails fading out of the 12-trail budget still
  draw their last 0.2 s. In play trails need 1.35× cruise speed (a stoop).
  The realistic loads (10 stooping, 40 fast) measure about 0.5 ms.
- `birds_verify_silhouette_test` rasterises side views at 64 and 32 px
  (birds ~50 and ~26 px across). Starling/hawk reaches 0.861 at 64 px, and
  moth/swallow at LOD2 reaches 0.90 at 32 px. At that size a bird side-on is
  its body blob. B1's measurement (160 px) and every top view at every
  raster stay below 0.85 (≤ 0.844). (Round 2: this probe now passes.)

## Fix round 2 — the verifiers' findings

| Finding | What was done |
|---|---|
| Major: perched (and tucked) folded wings stood off the body as detached blades, 0.031–0.088 span perched, 0.016–0.073 tucked; B2 "fold/tuck/perch poses correct" partial | The fold hug (Design decisions: each wing station moves in onto the back and follows the taper onto the rump, baked in UV2, applied as fold³) and a blunt rump as wide as the tail's base. Now at most 0.011 perched and 0.004 tucked at LOD0 (limit 0.012), 0 crossings and 0 body intrusions over the whole pose space and the drawn transitions. New test `test_folded_wings_lie_on_the_body` (fails with the hug off); `poses.png` gains views from behind and 35° above, `perched_close.png` is new. The verifier's own probe `test_r2_perched_wings_lie_on_the_body` passes. |
| Major: the highlight's minimum size drew prey bigger than the hunter (43 cases) and froze its size over most of a chase (no looming) | Highlighted birds are drawn at their true size; far readability comes from a marker around the bird (ring = edible, triangle = danger, fixed angular size, thinning away once the bird reads by itself). B4 is re-measured at true size: 10 species × 17 backgrounds × 40/16 m, 0 failures, worst 0.161 / 0.163 / 0.189 (round 1, with the enlargement: 0.161 / 0.167 / 0.153). New tests: every edible pair flown in from 160 m grows at every step and stays under the hunter's span; the marker's geometry. The verifier's `test_r2_highlighted_prey_is_never_drawn_bigger_than_the_hunter` passes. |
| Minor: one NaN/INF frame broke a model for good | Non-finite fields are ignored, non-finite smoothed state restarts from the fields, a NaN transform draws nothing; tested for 7 field/value pairs. |
| Minor: a highlighted bird at scale 0 wrote NaN; tiny ones were re-inflated | There is no enlargement any more; tested at scale 0 and 1e-9. |
| Minor: LOD0↔1 switch popped the silhouette area ~10% | Far LODs scale body rings, head and chords to cover LOD0's silhouette (94–100% from above and the side), a six-sided LOD1 head, wider LOD1 fingers, the outer mid-hand station kept. Rendered jumps now ≤ 3.4%, checked by `birds_lod_check` (limit 6%; 10.8% without the matching). |
| Minor: `lod_check.png` showed only the switch frame | It shows the frames before, of and after each switch. |
| Minor: the wren's cocked tail was an invisible line in profile | Every tail's upper surface has a low central ridge (0.3 × its half-width, closed at the end; +2 triangles), so a tail reads as a thin wedge side-on; the wren's tail is a little longer (0.15) and closes narrower (45% of its width), standing between its wingtips: the verifier's 35°-above visibility probe measures 0.40 (limit 0.3). |
| Minor: the close-up danger tint on pale species washed out to pastel | Pale plumage is dyed towards the hue and the unlit glow gives way to the rim close up; the gull's edible chroma 0.097 → 0.173, checked by the highlight shot (limit 0.12). |
| Minor: the perched "head stays level" check could not fail | It now compares the perched bill's elevation with the glide pose's (within 3°; 0.0° off); removing the counter-pitch fails it. |
| Minor: the trail ranking list grew without bound when nothing drew | A new ranking frame starts when a trail asks twice or the birds sync; one trail stepped 600 times lists 1; tested. |
| Minor: `render_layers` / `cast_shadows` setters and the minimum size had no headless test | Tested (the setter without its reattach fails); the minimum size is gone, its replacement tested. |
| Minor: stale docs (wing_palette, enlarged species, MIN_HIGHLIGHT_BODY degrees, "gpu_check compares silhouettes only", position-limit units) | Corrected here and in the code comments; VR's `fp_wings.gd` does read `wing_palette`. |
| Minor: `get_wingtip` ignored the enlargement | Moot (no enlargement); tested as the drawn transform × the posed tip. |
| Minor: two untyped vars; "a BirdModel has no child nodes" vs `attach_trails` | Typed (`Variant`); the contract note says "no child nodes of its own". |

Every new test was checked to fail on the old behaviour by a mutation in a
private copy of the tree (`.sandboxes/mut_*`, artifacts redirected): hug
off, round-1 minimum size back, NaN guards off, head counter-pitch off,
the layers setter's reattach off, the trail frame keyed on syncs only; and
rendered: LOD area matching off (`lod_check` 10.8%, fails), marker off
(`birds_highlight` 33 failures at 40 m), dye off (the gull's chroma fails),
and two shader-only changes (`gpu_check` fails 9 and 7 cases).

Compatibility: the other areas' suites that touch birds (UI flow, VR
wings, game loop shift/danger/mechanics/state/threat, AI flight envelope:
100 tests) pass, run in a private copy so their reports are untouched.

Verifier probes, rerun against this round (in a private copy): all 8
round-2 experience probes and 9 of 10 round-2 engineering probes pass. The
one that fails, `test_min_highlight_size_is_applied`, asserts the round-1
behaviour this round removed on the other verifier's finding (a moth at
40 m drawn at 1.6°); it is expected to fail. The verifier's rendered
probe's pixel "drawn widths" now measure the marker far away (a 12 px ring
around a 2 px moth) and the bird itself once it reads; its world view
reports 3 moth measurements among moving pollen motes, which its own crops
show clearly marked. Of the round-1 probes 28 of 30 pass; the two that
fail are the ones explained below (a 16 Hz hitch frame that shows the
owner's own phase; trails forced on for all 60 birds). The side-view
silhouette probe at 64 px now passes (0.786 at 160 px).

(Round 3 superseded two round-2 items above: the far-only, fading marker is
now drawn at every distance from its own mesh, and the close-up dye and rim
are gone. See below.)

## Fix round 3 — the verifiers' findings

| Finding | What was done |
|---|---|
| Major (experience): the highlight erased every species' colouring across the whole gameplay range (at 3° all 45 pairs < 0.05 apart; seven species the same violet or magenta cutout) | New highlight look (Design decisions › Highlight). A bird big enough to show its plumage (from 1.8 × its readable angle, ≤ 2.9° for every species) is drawn in exactly its own colours; the marker (ring = edible, triangle = danger) carries the state at every distance and LOD, from its own mesh in one extra MultiMesh per world. Only a bird smaller than its readable angle (a few pixels) is tinted. Verified: rendered identity pass, highlighted vs plain 0.000 at 3/10/25° (the round-2 kind of tint fails it 20 times); headless, B1's colour signature under the highlight keeps every pair > 0.05 (closest 0.062, same as plain); B4 re-measured with 0 failures over 40 m, 16 m and the new band. |
| Minor (experience): folded primaries of crow/hawk/eagle fanned into a comb (0.059–0.079 across); hands flared beside the tail (up to 0.041) | The primaries turn to the span as the wing folds (a per-finger shear: no inverted faces, fingers stay side by side) and the hand narrows to 0.55 of its kept chord at the tip, off the leading edge so the trailing edge still meets the body; hawk/eagle droop 7°/6°. Now 0.022–0.028 across (12% of the glide fan) and ≤ 0.027 beside the tail; the inner gap stays ≤ 0.010. New test `test_folded_wings_keep_inside_the_outline` (the verifier's measures; fails with either change undone). |
| Minor (experience): dive-tuck side IoU hawk/eagle 0.852 | B1's gate now covers perched, dive-tuck and half-tuck poses from above and the side (worst 0.804). Hawk and eagle are separated by their field marks: the eagle's big head and heavy bill project further, the hawk's chest is deeper (dive side 0.802, starling/hawk). |
| Minor (experience): in XR the sync had a 3.3× tail, "not the machine" | Measured in the simulator with a canary placed right *before* the sync and each bird's tick timed (`birds_xr`): in the slow frames the canary before the sync is 2.85× slower too and every bird's tick is uniformly 3.1–3.4× slower, while the canary after is normal. The main thread is slow at that moment; no per-bird work spikes. The verifier's canary ran after the sync. XR over 70 s: p95 309 µs, p99 346 µs, gated at p95 < 1 ms. The per-frame finiteness checks were also cut to one test each. |
| Minor (experience): first use of a LOD1/LOD2 mesh built inside the sync (17 ms) | All three LODs of a species are built when its first bird is attached; tested (`test_no_mesh_is_built_inside_a_sync`: 0.04 ms syncs through LOD0→1→2; fails built lazily). The verifier's soak: worst sync 1.08 ms (was 17.1). |
| Minor (engineering): B4 failed inside the marker's fade band (38–48 m) | The marker no longer fades (so no sub-pixel line), and the shot samples every species at 1.0/1.2/1.4/1.8/2.5 × its readable angle over six backgrounds: 0 failures. |
| Minor (engineering): the marker's fade was untested | The identity pass measures the marker's extent at five sizes per species (within 2.3 px of where the shader puts it, highlighted only); a marker of zero width fails 78 B4 cases. |
| Minor (engineering): three guards untested (NaN transform, tail ridge, visible instance count) | `test_nan_position_draws_nothing_then_recovers`, `test_tails_have_a_ridge_seen_side_on`, and `birds_lod_check`'s ghost check (0 px; 183 px without the visible count). Each fails on its mutation. |
| Minor (engineering): 40 trails starting together all drew for 30 frames | A trail cut by the budget fades out fast and is dropped once too faint to see; a trail is ranked from the frame after it first asks. Now at most 12 in every frame; handover back to 12 within 6 frames. New test (fails without the drop). |
| Minor (engineering): doc inaccuracies | Corrected: the marker faces the viewer's head (the centre view in stereo), not each eye; the LOD table's triangle ranges (116–168, 52–64); the readable angles are listed per species (0.69° wren … 1.60° moth, in `report_birds.json`); `birds_fx` exits 1 on a leak, lineup and flap on an empty cell. |

Every new test was checked to fail on the behaviour it guards, by a
mutation applied to the source for one sandboxed run and restored: tint
lasting to 5× the readable angle, fingers not turned, hand not narrowed,
cut trails not dropped, meshes built lazily per LOD, NaN transform guard
off, a hidden bird keeping its marker, a flat tail, no visible instance
count; and through the highlight shot's uniform overrides: zero-width
markers, a long tint.

Compatibility: the other areas' suites that touch birds (UI pointer and
flow, VR wings, game danger/loop shift/state/mechanics/threat, AI flight
envelope: 129 tests) pass, run in a private copy so their reports are
untouched.

Verifier probes rerun against this round (in a private copy): 53 of 57
pass, the round-3 engineering probes and the soak included. The four that
fail:

- `birds_r3_experience_test.test_r3_highlighted_species_keep_their_colouring`
  mirrors the *round-2* shader's fragment in its own code (near_tint_from
  0.12, near_tint 0.45, the dye), so it still computes the old look. The
  current shader, rendered, changes no highlighted bird's colours from 3°
  up (0.000), and a mirror that reads the shader's own uniforms finds no
  pair under 0.05.
- `birds_r3_experience_test.test_r3_folded_wing_stays_inside_the_outline`
  now fails only on the wren (0.045 beside the tail behind the rump), which
  the verifier called "its cocked tail, by design": the tail stands 69° up,
  so the flare is measured against a sliver of it. Its wingtips are 0.020
  inside the body's width. Every other species and measure passes (fan
  0.022–0.028, flare ≤ 0.027).
- `birds_r2eng_test.test_min_highlight_size_is_applied` asserts the
  round-1 minimum drawn size that round 2 removed.
- `birds_verify_pops_perf_test.test_fast_beat...` counts the 16 Hz hitch
  frame, which shows exactly the owner's own phase (the round-3 verifier
  agrees it is the probe's wrap).

## Known limits

- A batch is frustum-culled as one box: at 60 birds × 300 triangles,
  drawing the off-screen ones costs less than culling them one by one. The
  marker batch is never culled (a handful of birds, 70 triangles each).
- LOD uses the camera of the viewport the model is in. A SubViewport
  sharing the world (for example `XRMirror`) draws the same LODs; the
  highlight's tint and marker size are per view (computed in the shader).
- Headless runs never reach `frame_pre_draw`, so smoothing only runs where
  something draws (or where tests call `BirdBatch.sync_all`). Other areas'
  headless tests read and write the plain fields and are unaffected.
- A moth perched by the SizeRules convention (body centre 0.16 span above
  the grip) stands on long legs; that convention is sized for birds.
- The marker of a highlighted bird right next to the player is large (just
  outside its wingtips: a ring 1.24× its wingspan across); it stays a fine
  line (at most 0.23° wide). In stereo it faces the centre between the eyes (one flat
  marker for both eyes), checked in the Meta XR Simulator, not yet on a
  Quest.
- LOD2's cross-section is a square: from above and the side it covers
  96–100% of LOD0, but head-on up to 1.4 × (at under 18 px).
- The folded wren's gap is 0.010 at its rump, where its cocked tail stands
  between the wingtips, and its drooping wingtips stand 0.045 beside the
  narrow cocked tail (inside its body's width).
- Building a species' meshes takes about 8 ms on an M1 (the fold hug is
  4 ms of it), when its first bird is attached; `BirdModels.prewarm()`
  (74 ms for all 30) behind a loading screen avoids it. Nothing outside the
  birds area calls it yet.
- Nothing outside the birds area calls `BirdFX` or `BirdFXDirector` yet
  (integration or gameloop must wire one), and the HUD's prey/threat
  colours match the in-world highlight only if UI adopts
  `BirdModels.HIGHLIGHT_*` (it does not yet). VR's first-person wings do
  read `wing_palette` (`scripts/vr/fp_wings.gd`).
- Idle head glances use the shader's `TIME`, which wraps at 3600 s by
  default, so a glance may jump once an hour.
- Small birds' primaries are single-thickness plates (no triangles to spare
  under 300), so their wings are a line or nothing when seen head-on, as
  real ones are.
- The edible/danger pair is weakest for protanopes (about 0.1 Oklab in
  simulation; 0.26 for deuteranopes, 0.37 for normal vision). The marker's
  shape (ring or triangle), the lightness and the pulse rate (slow, fast)
  tell them apart without colour.
- The Quest CPU cost is an estimate (3–4× the M1: about 0.9–1.2 ms for 60
  birds at the XR median), not measured on the device; the per-bird tick is
  GDScript (~4 µs a bird on the M1). If a device measurement exceeds the
  budget, `BirdModel._tick` and `BirdBatch.write` are the code to move to
  native.
- In the simulator the main thread is occasionally about 3× slower at the
  start of `frame_pre_draw` for a frame (8 of 4870 frames, up to 0.8 ms of
  bird sync); the birds' code does not cause it and cannot avoid it.

## Contract changes

See the 2026-09-26 birds entries in `docs/ARCHITECTURE.md`. The first is
additive. The fix-round-1 entry covers value changes (the highlight hues,
the minimum highlighted size, the perched look) and additions
(`min_highlight_angle`, a guaranteed drawn LOD). The fix-round-2 entry:
true size with the far marker, the perched look (hug, rump), ignored
NaN/INF fields. The fix-round-3 entry: the marker at every distance from
its own mesh and batch, highlighted birds keeping their own colours from
1.8× their readable angle, the folded hand and primaries, the eagle's head
and the hawk's chest, meshes built per species; no API change for owners.
