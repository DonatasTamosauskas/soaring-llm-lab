# Soaring — art direction

**Warm stone, cold air.**

One low warm sun. Everything it cannot reach falls toward sky blue. Everything
far away falls toward the haze. Faceted, unspecular, untextured, high contrast,
silhouette first.

The implementation is `scripts/world/Palette.gd` and nothing else. This document
is the reasoning; the palette is the source of truth. `tests/test_palette.gd`
enforces both.

---

## The four rules

### 1. Value carries the silhouette. Hue carries the identity.

Aerial perspective eats hue long before it eats brightness. At 600 m a green
leaf and a brown trunk are the same blue-grey, and the only thing left holding
the shape together is the difference in brightness between them. So every pair
of surfaces that meet in the world — bark under leaf, roof over wall, wire
against pole — is separated by luminance first and colour second.

`Palette.CONTRAST_PAIRS` lists the pairs that matter and the suite checks them in
greyscale. **Add a pair when you add a prop that sits on another one.**

### 2. Nothing is authored above 0.80 albedo, except snow and cloud.

The sun is strong and the tonemapper is ACES. A 0.9 grey lit head-on clips to
white, and a clipped surface has no shape. The rim first came out looking like a
meringue for exactly this reason. Snow and cloud are the two exceptions, because
they are the two things that are genuinely white, and they earn it by being the
brightest thing in the frame — which is what makes them read as landmarks.

### 3. Warm light, cool shadow — at every scale.

The sun is warm (`1.0, 0.94, 0.84`); the fill it fights is blue
(`0.66, 0.74, 0.88`). That separation is what makes a flat-shaded facet read as a
facet instead of as one grey mass, and it repeats all the way down:

- **Per light**: warm key, cool fill.
- **Per facet**: the terrain's per-patch shade offset is applied hardest to red
  and softest to blue, so a brighter facet is also a warmer one.
- **Per distance**: haze is blue, so the far world is cool and the near world is
  warm. That, and not a number, is how a player reads distance.

### 4. Nothing invents a colour.

Every colour in the game comes out of `Palette.SURFACES`, `Palette.GROUND_BANDS`
or `Palette.atmosphere()`. `PaletteTests._test_the_world_invents_no_colours`
reads the source of every file that draws something and fails on a stray `Color`
literal. Without that, "one palette" is a convention, and conventions decay one
prop at a time.

(The HUD is deliberately outside this: white text with a black outline is a
legibility decision owned by the UI work, not a palette entry.)

---

## The air

**Aerial perspective is the game's main altitude and speed cue.** It is tuned
deliberately, and it is the one thing here worth reading numbers about.

| Distance | Haze | What it is for |
|---|---|---|
| 40 m | 1.6 % | The bird you are chasing stays crisp. |
| 300 m | 11 % | The middle distance softens; depth begins. |
| 900 m | 30 % | The rim reads as **mass**, not as a ghost. |
| 1600 m | 47 % | The massif beyond the rim is air and silhouette. |

Exponential fog, because haze is exponential and because the density is then a
real per-metre number you can reason about. **Do not switch it to
`FOG_MODE_DEPTH`.** In depth mode `fog_density` is a fraction of the way to
`fog_depth_end`, not a density per metre: the value this world shipped with,
`0.00021` over 3200 m, is 0.02 % opacity. The air was documented as the main
altitude cue and was rendering *nothing at all*, which is why the mountains
looked like a black wall and the world looked like a diorama.
`_test_the_air_is_thick_enough_to_see` exists to make that impossible to repeat.

Two more deliberate choices:

- **The haze is darker and less blue than the sky it stands in front of.** Haze
  the colour of the sky turns distant land into milk. A shade under it keeps a
  mountain reading as a mountain.
- **A gentle valley layer** (`fog_height` / `fog_height_density`) thickens the
  air below ~120 m, so climbing out of the bowl visibly clears it. It is
  deliberately weak: Godot's height fog takes no account of distance, so a strong
  layer would fog a bird thirty metres away just as much as the horizon.

## The light

One `DirectionalLight3D` at 46° with shadows; a bright blue ambient fill doing
the rest. The fill is unusually strong and mostly flat rather than sky-dominated,
because a *ring* of mountains means half the rim is backlit from anywhere in the
bowl, and a wall whose shape you cannot see is not a landmark.

Shadow splits are the most expensive thing in the scene — each one re-renders
every tree in range. A headset gets two shallow splits at 110 m; a desktop gets
four at 260 m.

## The ground

Painted by height, steepness and thermal dust into vertex colours — no textures,
one material, one draw call for 600 000 vertices. It doubles as an altitude
instrument: green in the bowl, heath on the shoulders, warm crag on the walls,
scree, then snow on the rim.

Two things make it read as *low poly* rather than as painted felt:

- **One flat colour per triangle**, taken at its centre. Colouring per vertex
  smears every band across the triangles that touch it.
- **A per-patch shade offset**, hashed from the position so the world stays
  deterministic, quantised to patches ~34 m across. Per-triangle noise reads as
  static, and on the rim wall — where the quads stretch into vertical slivers —
  it combed the whole mountain into fur.

Steep ground goes only *partly* toward bare stone (`STEEP_ROCK`). Taken all the
way, the rim — steep from top to bottom — became one flat lavender curtain 900 m
wide with no height bands left in it at all.

## The sky and the clouds

A baked procedural sky: deepest overhead, pale at the horizon, with a small hard
sun disc, because the sun is the only fixed point in a world with no compass.

Cloud is the one thing in the game that is **unshaded**. It paints its own
gradient from the world-space normal: a bright warm crown, a cool blue base, and
a hard line between them. A cumulus is seen from underneath for the whole game
and its underside faces nothing but the sky's ground colour, which is dirt — lit
normally it reads as a grey-green disc, and lifted with emission until the base
looks right, the top blows out. It is also the cheapest material in the game: no
light loop, no shadow lookup, no ambient probe, for the largest surfaces on
screen.

## Time of day

`--sky=morning|noon|evening`. **Morning is the default** because it is the most
legible: the sun is high enough that nothing important sits in shadow and low
enough that every facet still has a lit and an unlit face.

The land keeps its own colours at every hour — rock does not change because the
sun moved — so an hour is purely a lighting and atmosphere state: sun angle and
colour, fill, sky, haze, cloud shading, and how hard the town's windows glow.

## Budget

The look is free, and it must stay that way.

- One shared material per surface; under 32 materials for the entire world.
- Specular disabled everywhere. Nothing is transparent, so nothing sorts.
- No textures, no post-processing passes, no per-pixel extravagance. The one
  custom shader in the game is nine lines and unlit.
- The sky's radiance is baked once, not re-rendered per frame.

## How to work on this

```bash
# Twelve fixed viewpoints, the whole arena, any hour.
godot --xr-mode off --script res://tests/vista.gd -- --out=/tmp/v --sky=evening

# What the player is actually looking at, in the real game.
godot --xr-mode off -- --capture=/tmp/x.png --capture_delay=8

./tests/run.sh        # includes PaletteTests
```

Then **read the PNGs back and look at them**. Every judgement in this document
was made from a screenshot, and every first attempt was wrong.

One local trap: on macOS/MoltenVK the Forward Mobile renderer paints spurious
magenta tiles into captures of the running game. It is a known artifact of this
machine, not a defect, and it does not appear on device. `vista.gd` renders come
out clean.
