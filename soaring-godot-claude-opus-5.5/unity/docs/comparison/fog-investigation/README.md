# Godot haze investigation — 4 October 2026

The grey/white veil is chiefly the game's configured distance fog. Disabling
only `Environment.fog_enabled` removes most of the veil while retaining the
original sky, sun, shadows, materials, exposure and Filmic tone mapping.
The source Godot project was not edited or run in place. The playable preview,
rendering probe, logs and all evidence live under `unity/`.

## Cause

[WorldSky](/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/scripts/world/world_sky.gd:19)
explicitly selects Filmic tone mapping (exposure 1, white 6) and enables
exponential fog. The [day palette](/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/scripts/world/palette.gd:146)
sets its pale blue color to `#c4d8e3`, density to `0.00042` and sky influence to
`0.2`. WorldSky adds aerial perspective `0.25` and sun scattering `0.12`.
The captured environment confirms these settings at runtime; color adjustment,
glow and volumetric fog are disabled.

The broad valley views contain mostly objects hundreds of metres from the
camera. Distance fog blends these toward a bright pale color and reduces their
contrast and saturation. The sky is affected too. Godot documents the
[exponential fog and sky controls](https://docs.godotengine.org/en/stable/classes/class_environment.html#class-environment-property-fog-density)
and the [aerial perspective blend](https://docs.godotengine.org/en/stable/classes/class_environment.html#class-environment-property-fog-aerial-perspective).

Filmic is a second, independent contributor to the image's overall brightness
and highlight/color response. Switching to Linear removes that tone curve,
but clips bright values. The [Godot tone-mapping reference](https://docs.godotengine.org/en/stable/classes/class_environment.html#enum-environment-tonemapper)
explains that tradeoff. Fog removal does not require changing tone mapping.

The earlier Godot/Unity comparison also uses different atmospheric settings.
[Unity's setup](/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5/unity/Soaring/Assets/Soaring/Editor/ProjectSetup.cs:289)
uses linear fog beginning at 270 m and ending at 1450 m. Godot's exponential
fog starts accumulating immediately. The Unity player has no Filmic
post-processing curve. Therefore the earlier comparison's clearer Unity
foreground partly reflects the different configuration.

## Controlled reproduction

Five views from the existing shared route were rendered in Godot **4.7.2**,
Forward+ / Vulkan on the Apple M1 Pro. Each view has five simultaneous native
1280 × 720 subviewports sharing one seed-1 world, identical cameras (70° vertical
FOV, 0.05–3000 m clipping), 4× MSAA, animation time and draw frame:

| State | Fog | Tone mapping |
| --- | --- | --- |
| Original | Original exponential fog | Original Filmic, white 6 |
| Original control | Same as original | Same as original |
| Fog off | Disabled | Original Filmic |
| Linear only | Original exponential fog | Linear, exposure 1 |
| Fog off + Linear | Disabled | Linear, exposure 1 |

Every original/control pair was **pixel-identical**, validating that the
camera and shared scene render the same pixels without a changed setting.
All five fog-off views visibly recover distant surface contrast. The paired
PNG and four-state panel rectangles preserve native screenshot pixels exactly;
only the surrounding captions are added. No image grading or retouching is used.

For the valley overview, fog removal raises mean 8-bit HSV saturation from
**0.1779 to 0.2805**, and image luma standard deviation from **0.0656 to 0.1223**.
These are image descriptors, not headset colorimetric or performance results.
Fog off with Filmic retains zero pixels with a clipped 255 channel in this
view; fog off with Linear clips a channel in **4.88%** of pixels, visibly on
bright snow/cloud surfaces. `verification.json` contains every view's metrics.

Three launches of the actual full game also completed and captured its menu:
original, fog off, and fog off + Linear. These validate the preview integration,
not a full gameplay or physical Quest test. World capture isolates rendering
from gameplay and UI. Godot reports its existing ObjectDB cleanup warning on
shutdown; all captures and processes complete successfully.

## Play the separate preview

From the original repository root:

```sh
unity/tools/run-godot-fog-preview.sh                # Fog off; Filmic retained
unity/tools/run-godot-fog-preview.sh no-fog-linear  # Fog and Filmic curve off
unity/tools/run-godot-fog-preview.sh baseline       # Original settings in the copy
```

The private Godot project is `unity/.godot-fog-investigation`. Its default main
scene inherits the original game and adds a preview node that changes only the
runtime environment after the game loads. Opening this copy and running its
default scene uses fog off. Its settings/records directory is isolated from
the original game's `user://`. Original game resources are never saved or
patched. Desktop Forward+ is used because the original capture helper notes
Mobile/MoltenVK artifacts on this Mac.

`tools/prepare-godot-fog-copy.sh` recreates this copy from the source and imports
it. It copies the two diagnostic scripts and installs the alternate entry
scene only inside that private project. It is independent of the Unity frozen
asset export and does not alter the Unity player.

To repeat the controlled captures:

```sh
unity/tools/prepare-godot-fog-copy.sh
SOARING_COMPARISON_ROUTE="$PWD/unity/tools/comparison-route.json" \
SOARING_FOG_OUTPUT="$PWD/unity/docs/fog-investigation/raw" \
godot --path unity/.godot-fog-investigation --xr-mode off \
  --rendering-method forward_plus --resolution 1280x720 --disable-vsync \
  --fixed-fps 30 res://fog_probe.tscn -- --fresh-settings
/Users/don/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 \
  unity/tools/compose_fog_investigation.py
```

The compositor requires Pillow and the local Avenir Next font. The workspace
Python supplies Pillow on this machine. Root import/render logs are under
`unity/Logs/fog-investigation/`.

## Original integrity

A before/after SHA-256 comparison covered **2,596 original source, asset,
configuration, test and documentation files**. Their contents and file lists
match exactly. `source-before.json` stores the hashes; `source-integrity.json`
records zero added, removed or modified files. The separate Unity directory,
existing import caches, sandbox projects and generated build/artifact folders
are excluded from this source check. No original project was launched.

Open `index.html` for the interactive comparison. `raw/capture.json` records
actual runtime environment settings, route and engine. The served comparison
gallery also contains a copy of this evidence at `comparison/fog-investigation/`.
