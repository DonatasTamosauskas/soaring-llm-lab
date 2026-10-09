# Credits

Third-party assets that ship with Soaring. Each area adds its own section.
Everything not listed here was made for this project (code, procedural
meshes, synthesized sounds).

## Audio

Shipped files live under `assets/audio/`. The species calls and the forest
chorus were **trimmed, band-limited, noise-reduced (spectral subtraction),
faded and peak-normalised, and converted to 32 kHz mono** by
`scripts/audio/tools/call_prep.gd` (the exact cut of each file is listed
there). Source URLs, licenses and authors were taken from
`assets/_candidates/<source>/MANIFEST.json`.

**CC BY 3.0 (attribution required; https://creativecommons.org/licenses/by/3.0/)**

- "BarnSwallows.ogg" by Justin Wasack (via freesound / Wikimedia Commons),
  https://commons.wikimedia.org/wiki/File:BarnSwallows.ogg
  (trimmed, noise-reduced, converted to mono) -> `calls/swallow_1..3.wav`
- "Screaming Hawk.wav" by PsychoBird (SoundBible, via Wikimedia Commons),
  https://commons.wikimedia.org/wiki/File:Screaming_Hawk.wav
  (trimmed, noise-reduced, converted to mono) -> `calls/hawk_1..3.wav`
- "Golden eagle.ogg" by Bubulcus,
  https://commons.wikimedia.org/wiki/File:Golden_eagle.ogg
  (trimmed, noise-reduced, converted to mono) -> `calls/eagle_1.wav`, `calls/eagle_2.wav`
- "Troglodytes troglodytes chirp.ogg" by Amada44,
  https://commons.wikimedia.org/wiki/File:Troglodytes_troglodytes_chirp.ogg
  (trimmed, noise-reduced, converted to mono) -> `calls/wren_3.wav`

**Public domain, U.S. National Park Service (credit requested)**

- Bird and nature recordings courtesy of the U.S. National Park Service
  (NPS Natural Sounds gallery; Yellowstone National Park Sound Library):
  common raven, Black Sand Basin (https://www.nps.gov/yell/learn/photosmultimedia/sounds-raven.htm)
  -> `calls/crow_1..3.wav`; western gull
  (https://www.nps.gov/subjects/sound/sounds-western-gull.htm) -> `calls/gull_3.wav`, `calls/gull_4.wav`;
  bald eagle (https://www.nps.gov/subjects/sound/sounds-bald-eagle.htm) -> `calls/eagle_3.wav`;
  Yellowstone bird chorus (https://www.nps.gov/yell/learn/photosmultimedia/sounds-birdchorus.htm)
  -> `ambience/amb_forest_birds.wav`.

**Public domain (courtesy credits)**

- "Troglodytes troglodytes.ogg" by Sogning Norway (Wikimedia Commons) -> `calls/wren_1.wav`, `calls/wren_2.wav`
- "Passer domesticus.ogg" by Oona Räisänen (Mysid) (Wikimedia Commons) -> `calls/sparrow_1..3.wav`
- "Dove cooing.ogg" by mary905 (via pdsounds.org / Wikimedia Commons) -> `calls/pigeon_1..3.wav`
  (a dove standing in for the pigeon)
- "Gull 2.ogg" (herring gull) by avphillips (via pdsounds.org / Wikimedia Commons) -> `calls/gull_1.wav`, `calls/gull_2.wav`

**CC0 (courtesy credits)**

- "Heavenly Loop" by isaiah658, OpenGameArt.org,
  https://opengameart.org/content/heavenly-loop -> `music/menu_heavenly_loop.ogg` (unchanged)
- Interface Sounds by Kenney (www.kenney.nl) -> `ui/ui_*.ogg`
  (click_001, select_002, back_002, open_002, close_002, confirmation_002, tick_002; renamed, unchanged)

Synthesized in code (no third-party material): the wind, wingbeats, stall
buffet, updraft hum, moth flutter, starling whistles, catch crunch and
feather puff, caught stinger, tier-up fanfare, danger heartbeat and drone,
collision sounds, church bell, and the leaves, water, village, meadow and
open-air ambience beds (`scripts/audio/sound_designs.gd`).

## Unity port

The valley geometry, species meshes and audio files were transferred from the
Soaring Godot game. New Unity runtime code, shaders and build tools were created
for this port. Unity package dependencies retain their upstream licenses in
`Soaring/Library/PackageCache/<package>/LICENSE.md` and are resolved from the
pinned package manifest; no Unity package source has been modified.

The OpenXR project configuration and local Mac loader postprocessor were adapted
from the local `vr-unity-example` project supplied by the user.

## Unity UI fonts

Nunito, Copyright 2014 The Nunito Project Authors, is licensed under the
SIL Open Font License 1.1. The port derives static weight-700 and weight-900
faces from the source game's variable font using fontTools 4.59.2. The full
license accompanies the fonts in
`Soaring/Assets/Soaring/Resources/UI/Fonts/OFL.txt`. The source's procedural
emblem, species silhouettes and gesture illustrations are exported unchanged
by the UI art tool. See `docs/ui-art-provenance.json` for hashes.
