# Asset scout: open 3D models and audio for Soaring

Scouted 2026-09-25 by the asset-scout agent. This covers low-poly bird models for the 10-species ladder, world props, and audio (wind, flaps, per-species calls, impacts, ambience, music).

**Short version**

- **Birds:** build them procedurally. No open pack covers the ladder in one consistent style with usable wings (see the evidence in section 2). Keep the downloaded Poly-by-Google birds as a colour and silhouette reference only.
- **Props:** use Kenney's Nature, Fantasy Town and Suburban kits (all CC0) and a few Quaternius and CreativeTrio pieces (CC0) as dressing and background. Anything the player flies *through* or perches *on* should be generated in code: branchy trees, poles and wires, buildings with open windows, nest-box holes.
- **Audio:** synthesize everything driven by flight (wind, flaps, stall flutter, updraft hum, moth buzz). Use recordings for bird calls (public-domain NPS and Wikimedia files, all downloaded), ambience beds, UI clicks, impacts, jingles and menu music (Kenney and OpenGameArt, CC0).

Everything downloaded is under `assets/_candidates/` (50 MB, 1,505 files). Each source folder has a `MANIFEST.json` with the source URL, the license and the author.

---

## 0. How this was verified

| Check | How | Result |
|---|---|---|
| License | Read on each source page, not on search snippets. poly.pizza: the `Licence` field in the page's embedded model JSON. Wikimedia: the Commons API `extmetadata` (LicenseShortName / AttributionRequired, which come from the file page's license template). Kenney: `License.txt` inside each zip. NPS: the statement on the library pages. OGA: the page's license field. | Only CC0, public domain or CC-BY were downloaded. No NC, SA or custom licenses. |
| Download without login | Fetched with plain `curl` | Every file under `_candidates/` came through `curl` with no login. |
| Loads in Godot 4.7.2 | Copied candidates into an **isolated scratch project** (not the shared tree) and ran `godot --headless --import` | **457 files imported, 0 errors.** Covers all poly.pizza GLBs, the Kenney kit samples, and all ogg/mp3/wav files. |
| Style and scale | Rendered each set in Godot, normalised to 1 m, one sun | `_candidates/polypizza/_lineup_birds_godot.png`, `_lineup_props_godot.png` |
| Poly budget | Parsed the GLB JSON: triangles, materials, textures, skins, animations | Tables below |
| Audio | `afinfo` for durations. Tested `afconvert` (built into macOS) for mono 32 kHz WAV output. | It reads **mp3 and Ogg Vorbis**. No ffmpeg or sox is needed (see 4.4). |

`assets/_candidates/.gdignore` is in place, so Godot and every `tools/gd.sh` sandbox **skip this folder**. Without it, ~1,500 files would be imported by every agent's sandbox, and the import step has a 180 s alarm. To use an asset, copy it into your own area folder (`assets/birds/`, `assets/audio/`, …) and add a line to `docs/CREDITS.md`. Whether `_candidates/` is committed or git-ignored is integration's call. It is 50 MB and nothing depends on it.

---

## 1. What was downloaded

| Folder | Source | License | Size | Contents |
|---|---|---|---|---|
| `kenney/nature-kit/` | [kenney.nl/assets/nature-kit](https://kenney.nl/assets/nature-kit) | CC0 | 11 MB | 329 GLB (glTF folder only; DAE/FBX/OBJ/STL removed), `Side/` thumbnails, Preview.png |
| `kenney/fantasy-town-kit/` | [kenney.nl/assets/fantasy-town-kit](https://kenney.nl/assets/fantasy-town-kit) | CC0 | 4 MB | 167 GLB: modular walls with window and door openings, roofs, chimneys, windmill, watermill, hedges, fences, trees |
| `kenney/city-kit-suburban/` | [kenney.nl/assets/city-kit-suburban](https://kenney.nl/assets/city-kit-suburban) | CC0 | 3.5 MB | 40 GLB: 21 houses, fences, paths, 2 trees |
| `kenney/impact-sounds/` | [kenney.nl/assets/impact-sounds](https://kenney.nl/assets/impact-sounds) | CC0 | 1.2 MB | 130 ogg (impactSoft, impactPunch, impactWood, impactPlank …) |
| `kenney/interface-sounds/` | [kenney.nl/assets/interface-sounds](https://kenney.nl/assets/interface-sounds) | CC0 | 1.1 MB | 100 ogg (click, select, confirmation, back, open/close, toggle …) |
| `kenney/music-jingles/` | [kenney.nl/assets/music-jingles](https://kenney.nl/assets/music-jingles) | CC0 | 1.5 MB | 94 ogg: 8-bit, hit, pizzicato, sax and steel jingles (0.3–2 s) |
| `polypizza/birds/` | poly.pizza CDN | 10 × CC-BY 3.0, 1 × CC0 | 5.6 MB | Reference birds: moth, wren, sparrow, swallow, pigeon (mourning dove), crow, gull (flying), hawk, eagle, flying silhouette, plus a CC0 "Brown Bird". A preview PNG sits beside each GLB. |
| `polypizza/props/` | poly.pizza CDN | 8 × CC0, 3 × CC-BY 3.0 | 1.3 MB | barn, open barn, silo, windmill, water tower ×2, bird house, church, radio tower, post, bird's nest |
| `nps/` | U.S. National Park Service sound libraries | Public domain | 6.2 MB | 16 mp3: western gull, bald eagle ×2, common raven ×2, osprey, peregrine + raven, sparrows ×2, magpie, red-winged blackbird, bluebird, meadowlark, dawn chorus, bird chorus, wind soundscape |
| `wikimedia/` | Wikimedia Commons | 9 PD, 1 CC0, 5 CC-BY | 9.2 MB | 15 calls: wren ×2, house sparrow, barn swallow, starling flock take-off, dove coo, crow ×2, herring gull ×3, hawk ×2, eagle ×2 |
| `oga/` | OpenGameArt | CC0 | 11 MB | large wing flaps, wind whoosh loop, forest ambience, ambient birds, bird chirps, 3 calm music loops, 8 nature/noise loops |

The four Kenney 3D kits come to about 20 MB. The largest single file is the 5.3 MB starling recording. The total is far under the 300 MB cap.

**Not downloaded**, with reasons, is in section 5.

---

## 2. Bird models

### 2.1 Candidates

Triangle, material, texture and skin counts come from parsing the GLB. The license is the model page's own field.

| Species slot | Best open candidate | License | Tris | Format | Rigged / animated | Pose | Direct DL | Style fit |
|---|---|---|---|---|---|---|---|---|
| moth | "Lil' Moth", Lee Mason ([poly.pizza/m/8ojwMQpu6DK](https://poly.pizza/m/8ojwMQpu6DK)) | CC-BY 3.0 | 770 | glb (6 mats) | no | wings spread, modelled upright | yes | ok, but a different author |
| wren | "Cactus wren", Poly by Google ([/m/6b7Ul6MeLrJ](https://poly.pizza/m/6b7Ul6MeLrJ)) | CC-BY 3.0 | 932 | glb + 1.1 MB PNG | no | perched, wings folded | yes | good |
| sparrow | "Sparrow", Poly by Google ([/m/3rTjKefT184](https://poly.pizza/m/3rTjKefT184)) | CC-BY 3.0 | 608 | glb + tex | no | perched | yes | good |
| swallow | "Cliffswallow", Poly by Google ([/m/5dl4UWhvuTW](https://poly.pizza/m/5dl4UWhvuTW)) | CC-BY 3.0 | 844 | glb + tex | no | perched (no visible tail fork) | yes | good |
| starling | none found on any open source | n/a | n/a | n/a | n/a | n/a | n/a | **gap** |
| pigeon | "Mourning dove", Poly by Google ([/m/1cF8DTp2sAi](https://poly.pizza/m/1cF8DTp2sAi)) | CC-BY 3.0 | 966 | glb + 1 MB tex | no | standing | yes | good (a dove, not a rock pigeon) |
| crow | "Crow", Poly by Google ([/m/1MIvWQ5Q3R9](https://poly.pizza/m/1MIvWQ5Q3R9)) | CC-BY 3.0 | 682 | glb + tex | no | standing | yes | good |
| gull | "Flying gull", Poly by Google ([/m/eMNhHDZakYp](https://poly.pizza/m/eMNhHDZakYp)) | CC-BY 3.0 | 410 | glb + tex | no | **in flight** (fixed wing pose) | yes | good |
| hawk | "Red-tailed hawk", Poly by Google ([/m/9adZAZ2BmGL](https://poly.pizza/m/9adZAZ2BmGL)) | CC-BY 3.0 | 1112 | glb + 1.2 MB tex | no | perched, **branch baked into the mesh** | yes | good |
| eagle | "Golden eagle", Poly by Google ([/m/2YF1DGWp4vx](https://poly.pizza/m/2YF1DGWp4vx)) | CC-BY 3.0 | 1568 | glb + 1.4 MB tex | no | standing | yes | good |
| (far silhouette) | "Bird", Poly by Google ([/m/8Ph79kHbt9s](https://poly.pizza/m/8Ph79kHbt9s)) | CC-BY 3.0 | 386 | glb | no | in flight, modelled upright | yes | fine |
| (CC0 option) | "Brown Bird", AssetQuest ([/m/aDrUGRtDcm](https://poly.pizza/m/aDrUGRtDcm)) | CC0 | 194 | glb + tex | no | round "blob" bird | yes | cute style, does not match |
| alt: hawk | "Hawk Lp Rigged", Sherkiz ([/m/RkN6MEbP6g](https://poly.pizza/m/RkN6MEbP6g)) | CC-BY 3.0 | **9,956** | FBX→glb | **yes** | flying | yes | too heavy (≈60 of them = 600k tris) |
| alt: pigeon | Quaternius "Pigeon" ([/m/9NGlBTpDEr](https://poly.pizza/m/9NGlBTpDEr)) | CC0 | 2,024 | glb | yes | n/a | yes | **no**: a cartoon monster head |
| alt: bird | Quaternius "Bird" (jay) / "Birb" | CC0 | 1,204 / 2,668 | glb | no / yes | n/a | yes | **no**: cartoon (Birb is a monster) |
| alt: various | Sketchfab CC-BY animated: "Low-Poly Seagull (with Animation & Rigged)" 580 faces, "Low Poly Eagle" 414, "Animated Bird, Pigeon" (dudecon) 710 / 5 clips, "American Crow V1" 469, "Low Poly Crow NPC" 1,631 | CC-BY | 400–1,600 | glb/fbx | yes (1–5 clips) | flying | **login required** | 6 different authors, 6 different styles |
| alt: robin | SoltorchGames "Animated Low Poly Bird – American Robin" (itch.io) | **custom** ("use anywhere, don't resell"), not CC | 1,424 | glb/fbx/blend | yes, 20 clips | n/a | itch download flow | nice, but its sibling packs are paid ($5–20) and none covers our species |
| alt: raven, shrike, basemesh | OGA "Raven" (Teh_Bucket, CC0), "Bird (Yellow-Billed Shrike)" (CC0), "Bird basemesh" (CC0), "Bird – Animated" (PantherOne, CC-BY 3.0, 324 tris, 7-key flap) | CC0 / CC-BY | ~300–2k | **.blend only** | some | n/a | yes | unusable here: Godot needs Blender installed to import .blend, and this Mac has no Blender |

**Evidence image:** `assets/_candidates/polypizza/_lineup_birds_godot.png` (the reference birds rendered in Godot).

### 2.2 Recommendation: procedural birds, with the open models as reference only

I recommend building the birds in code. The open models lose on every point that matters for this game:

1. **No wings to animate.** Every Poly-by-Google bird is **one rigid mesh**: 1 node, 0 skins, 0 animations, wings merged into the body. Eight of ten are perched with folded wings. The only one in flight (the gull) is frozen in one pose. The `BirdModel` contract needs `flap_phase / flap_amount / wing_fold / bank / perched` every frame. Getting that from these meshes means separating and re-rigging the wings in Blender, and Blender isn't installed.
2. **Materials.** Each species has its own texture, up to 1.4 MB PNG. That means 10 materials and ~7 MB of textures, against ARCHITECTURE §7 ("share materials, a palette texture / vertex colours") and the brief ("one or very few materials for all birds").
3. **Inconsistent source data.** In Godot, the source sizes range from **0.13 m to 241 m**, the axes differ (the moth and the silhouette are modelled upright), and the hawk has its branch baked in. Every model needs manual normalisation before it can be used.
4. **Coverage.** There is no starling in any open source. The moth is by another author. The only rigged candidates are too heavy (10k tris), cartoon-style (Quaternius), behind a login with mixed styles (Sketchfab), or paid or custom-licensed (itch.io).
5. **Procedural fits the contract and the Quest budget better.** The birds area then owns wingspan = 1.0 exactly, beak along −Z, and the origin at the body centre. Every silhouette cue the brief asks for becomes a parameter.

**How I'd build them (suggestion for the birds area):**

- **One mesh per bird, animated in the vertex shader rather than with a Skeleton3D.** When the mesh is generated, tag each wing vertex with its segment (inner, outer, primaries/fingers) and its distance from the hinge, in `CUSTOM0` or UV2. The shader rotates segments about the shoulder, wrist and finger hinges from per-instance values (`instance uniform float flap_phase, flap_amount, wing_fold, bank`).
  - Draw calls: separate wing `MeshInstance3D`s would cost 3–5 draw calls per bird, so 60 NPCs would blow the **≤150 draw-call** budget on birds alone. One mesh per bird is 1 draw call, and a MultiMesh per species with `INSTANCE_CUSTOM` would be about 10 for the whole flock.
  - This also costs no CPU skinning, and the downstroke/upstroke asymmetry is just a phase curve.
- **Triangles:** about 150–300 per bird (body ~80, head and beak ~40, two 3-segment wings ~30–50 each, tail ~12–30). 60 NPCs come to roughly 18k tris, against the 300k budget.
- **One shared material:** vertex colours or a small palette strip, flat shaded. Colour zones per species: back, belly, wing, wingtip, head/cap, throat accent, beak, legs.
- **Silhouette parameters, so shape as well as size says what a bird is:**
  - wing aspect ratio and sweep
  - tip shape: pointed, rounded, or slotted with N fingers
  - tail: fork depth, fan width, length, cock angle
  - body length and girth
  - head size, and beak length/hook
- **Species cues**, matching the reference renders in `_candidates/polypizza/birds/*_preview.png`:

| Species | Shape cues | Colour cues |
|---|---|---|
| moth | 4 broad fins, fat furry body, antennae | pale beige/grey, eye-spots |
| wren | tiny and round, short rounded wings, **tail cocked straight up** | barred brown |
| sparrow | stocky, conical beak, notched short tail | streaked brown back, grey crown, black bib |
| swallow | long swept pointed wings, **deep tail fork with streamers** | glossy blue-black back, rusty throat, cream belly |
| starling | short **triangular** pointed wings ("star" shape in flight), short square tail, long yellow beak | glossy black with speckles |
| pigeon | plump, small head, pointed wings | blue-grey, **two black wing bars**, iridescent neck, dark tail band |
| crow | broad wings with **5 finger slots**, heavy beak | all black |
| gull | long narrow wings with a crooked wrist, yellow beak | white body, pale grey mantle, **black wingtips** |
| hawk | broad rounded wings, **fanned tail**, hooked beak | rufous tail, pale belly with a dark band |
| eagle | very large plank wings with **7 deep finger slots**, huge hooked beak | dark brown, golden nape |

- **Reference use:** keep the downloaded Poly-by-Google models as reference only. Looking at them for proportions and colours needs no credit. If any geometry or texture from them is actually shipped, add the CC-BY credit from section 6.

---

## 3. World props

### 3.1 Candidates

| Asset | Source | License | Tris | Mats / tex | Direct DL | Use for | Notes |
|---|---|---|---|---|---|---|---|
| Nature Kit (329 models) | [Kenney](https://kenney.nl/assets/nature-kit) | CC0 | 2–720 (median 76) | 1–6 flat colour mats, **no textures** | yes (zip) | rocks, stones, cliff blocks, bushes, fences, logs, stumps, flowers, crops, filler trees (61 variants, 50–456 tris) | Trees are "lollipop" blobs with no branch structure you can weave through. Fine for background forest, not for acrobatics. The teal/orange palette needs recolouring. |
| Fantasy Town Kit 2.0 (167) | [Kenney](https://kenney.nl/assets/fantasy-town-kit) | CC0 | 4–1,628 (median 96) | 1 mat + shared `colormap.png` | yes | modular houses: `wall-window-*`, `wall-doorway-*`, `wall-arch`, roofs, `chimney*`, hedges, fences, windmill, watermill, stalls | Could assemble village houses, but openings and interior rooms must match collision exactly. Procedural buildings are safer (3.2). |
| City Kit Suburban 2.0 (40) | [Kenney](https://kenney.nl/assets/city-kit-suburban) | CC0 | 12–2,062 (median 785) | 1 mat + colormap | yes | closed suburban houses, fences, paths | Background town. Windows are solid. |
| Farm Buildings: Barn, Open Barn, Silo, Tower Windmill | Quaternius (via [poly.pizza bundle](https://poly.pizza/bundle/x-ppbnhEfNEt)) | CC0 | 1.6k / 1.6k / 1.6k / 7.8k | 4–7 flat mats | yes (CDN glb) | barn with **open sides** (fly-through), silo | The windmill is heavy (7.8k). The full Quaternius packs are Google-Drive folders, which can't be fetched with curl. |
| Water Tower | Quaternius ([/m/tMK8bhapAK](https://poly.pizza/m/tMK8bhapAK)) | CC0 | 1,158 | 1 + tex | yes | "old water tower", lattice legs to weave through | |
| Watertower (squat) | Kay Lousberg ([/m/WGSUkExDJ4](https://poly.pizza/m/WGSUkExDJ4)) | CC0 | 146 | 1 + tex | yes | rooftop tank | |
| Bird House | CreativeTrio ([/m/xFKC7GxgdL](https://poly.pizza/m/xFKC7GxgdL)) | CC0 | 70 | 1 + tex | yes | nest box look | The entrance hole may be painted, not cut. A procedural nest box with a real hole and trigger is trivial. |
| Church | CreativeTrio ([/m/GHzPfvoyzX](https://poly.pizza/m/GHzPfvoyzX)) | CC0 | 2,265 | 1 + tex | yes | village church silhouette | The belfry is closed. The brief wants open belfry arches. |
| Radio tower | Poly by Google ([/m/eWEYV9ppUjv](https://poly.pizza/m/eWEYV9ppUjv)) | CC-BY 3.0 | 1,326 | 4 flat mats | yes | tall mast for big birds | |
| Post | Quaternius ([/m/jnuIFJsXZJ](https://poly.pizza/m/jnuIFJsXZJ)) | CC0 | 524 | 1 + tex | yes | fence/utility post | |
| Birds nest | Poly by Google ([/m/fq_bAKD1Khg](https://poly.pizza/m/fq_bAKD1Khg)) | CC-BY 3.0 | 619 | 1 + tex (300 KB) | yes | nest decoration | |
| Telephone poles pair / Transmission tower / Bell tower | Poly by Google (CC-BY) / iPoly3D (CC0) / Quaternius (CC0) | as listed | **6.5k / 5.7k / 10.1k** | n/a | yes | n/a | Not downloaded: too heavy. Poles and wires must be generated anyway so the perches match the catenary. |
| KayKit Forest Nature Pack (free tier 100+ models) | [kaylousberg.itch.io/kaykit-forest](https://kaylousberg.itch.io/kaykit-forest) | CC0 | low | one gradient atlas | **no**: itch download flow; not on KayKit's GitHub | nicer stylised trees and rocks | Worth a manual download if the world builder wants a second tree style. |
| Quaternius Stylized Nature MegaKit / Ultimate Stylized Nature | quaternius.com (Google Drive) / poly.pizza | CC0 | n/a | alpha-card leaves (MegaKit) | Drive only / per-model CDN | n/a | The MegaKit uses **alpha-tested leaf cards**, which cost overdraw on Quest. Ultimate Stylized Nature is flat, but its multi-tree meshes are awkward for MultiMesh. |

**Evidence images:** `assets/_candidates/polypizza/_lineup_props_godot.png`, `kenney/*/Preview.png`.

### 3.2 Recommendation for the world area

- **Use the Kenney kits for dressing and far background.** They are tiny (median 76–785 tris), CC0, one colormap or flat materials, and a style that matches ours.
  - Convert on import: bake material albedo into **vertex colours** and remap to the world palette. Then every prop shares one material and MultiMesh works for rocks, bushes, fences and filler trees.
  - All the Kenney, Quaternius and Google props are flat-shaded, but their palettes differ (Kenney teal/orange, Quaternius saturated red). Recolouring to one palette is what makes them look like a single world.
- **Generate in code anything the flight model interacts with:**
  - Trees with real branches (trunk plus recursive limbs plus leaf clumps). The brief's "branches to weave through" and branch perches need known geometry.
  - Poles with **catenary wires**. The perch positions have to sit exactly on the wire.
  - Buildings with **open windows through a real room** and a belfry with open arches.
  - Nest boxes, cliff holes and silos with real openings plus trigger volumes.
  - The Kenney Fantasy-Town walls, roofs and chimneys can still skin those procedural shells.
- Quaternius **Open Barn** and **Water Tower** are good as-is fly-through set pieces. Credit is optional (CC0).

---

## 4. Audio

### 4.1 Procedural or sampled

| Sound | Make it | Why | Starting material |
|---|---|---|---|
| **Wind by airspeed** | **Synthesize.** Broadband noise loop through a low-pass (cutoff ~300 Hz → 6 kHz with airspeed; gain rising with dynamic pressure), plus a resonant band-pass "whistle" layer in dives. Pan per ear by head yaw against the airflow, which is a strong VR cue. | It is the main speed cue, so it must follow telemetry continuously without audible loop seams. | Optional texture layer: `oga/wind_woosh_loop.ogg` (CC0, 6 s loop), `nps/yell_soundscapes.mp3` (wind in cabin, PD) |
| **Wingbeats (player and NPC)** | **Synthesize.** At load time, build a bank of about 8 whoosh one-shots: noise × envelope (attack 20–40 ms, decay 120–300 ms), band-pass centre scaled by bird size (~2–3 kHz flutter for small birds, ~300–600 Hz "whump" for large ones). Trigger on each downstroke with gain from stroke speed; upstrokes get a quiet rustle. | It must track the player's own arm speed and size exactly. Samples repeat and can't scale with size. | Optional layer for big birds: `oga/wings_flap_large/` (CC0, 3 flaps, slice them) |
| Stall flutter, updraft hum, moth buzz | **Synthesize** (pre-rendered loops: AM noise at ~20 Hz for flutter; low noise with a slow LFO for updraft hum; 50–70 Hz buzz for the moth) | Parameter-driven and cheap | n/a |
| **Bird calls, per species, 3D** | **Sample** | Nobody can synthesize a convincing crow or gull. Recognisable calls are how the player hears what's nearby. | Species table below |
| Danger cue | Predator call getting louder (sampled) + a synthesized low heartbeat pulse | Readable and diegetic | hawk / eagle files below |
| Catch crunch / feather puff | Sample + synth: Kenney `impactSoft_heavy_*` / `impactPunch_medium_*` layered with a short synthesized high noise burst | Punchy and cheap | `kenney/impact-sounds/` |
| Collision / stun | Sample | n/a | `kenney/impact-sounds/impactWood_*`, `impactPlank_*`, `impactSoft_*` |
| UI | Sample | n/a | `kenney/interface-sounds/` (click, select, confirmation, back, toggle) |
| Tier-up celebration | Sample | n/a | `kenney/music-jingles/` **Pizzicato** or **Steel** jingles (the 8-bit ones clash with the tone) |
| Ambience per zone | Sample beds, plus sparse individual calls scattered as 3D one-shots | n/a | forest/meadow: `nps/yell_dawn_chorus.mp3` (62 s), `nps/yell_bird_chorus.mp3` (37 s), `oga/forest_ambience.mp3` (45 s), `oga/ambient_birds_isaiah658.ogg` (31 s); river: `oga/sfx_loops/water_flowing.ogg` |
| Light menu music | Sample | n/a | `oga/music_heavenly_loop_isaiah658.ogg` (34 s loop), `oga/music_calm_loop_wipics.mp3` (19 s), `oga/music_menu_chill_etrock.wav` (17.5 s). All CC0. |

**Quest performance note.** Don't generate continuous layers sample by sample at runtime: GDScript `AudioStreamGenerator.push_frame` costs real CPU on Quest. Generate the noise loops and one-shot banks **once at load** into `AudioStreamWAV` (16-bit PCM byte arrays). At runtime, only change `pitch_scale`, `volume_db` and bus-effect parameters (`AudioEffectLowPassFilter.cutoff_hz` and so on) each frame. This keeps it procedural, costs almost nothing, and loops seamlessly.

### 4.2 Bird calls per species (all downloaded)

| Species | Primary | Alternates | License |
|---|---|---|---|
| moth | none (synth buzz) | n/a | n/a |
| wren | `wikimedia/wren_pd_sogning.ogg`: real *Troglodytes troglodytes*, 7.4 s | `wikimedia/wren_chirp_ccby3_amada44.ogg` (0.7 s) | PD; alt CC-BY 3.0 |
| sparrow | `wikimedia/sparrow_house_pd_mysid.ogg`: house sparrow, 10.8 s | `nps/white_crowned_sparrow.mp3` (20 s), `nps/yell_savannah_sparrow.mp3` (39 s) | PD |
| swallow | `wikimedia/swallow_barn_ccby3_wasack.ogg`: barn swallows, 35 s | n/a | CC-BY 3.0 |
| starling | `wikimedia/starling_flock_takeoff_ccby4_koenigsmann.ogg`: a **murmuration taking off**, 86 s (wing roar and chatter, ideal for flocks) | chatter stand-in: `nps/yell_redwinged_blackbird.mp3` (an icterid, not a starling), `nps/yell_western_meadowlark.mp3`. More starling audio, not downloaded (large): Commons "2018-10-10 kreisende stare.ogg" (348 s, CC-BY 4.0, same author) | CC-BY 4.0; alts PD |
| pigeon | `wikimedia/pigeon_dove_cooing_pd_mary905.ogg`: dove coo, 7.9 s (species unstated, probably a collared or mourning dove) | none (no clean PD/CC0 rock pigeon found) | PD |
| crow | `wikimedia/crow_american_pd_mcgrane.ogg` (20 s) | `wikimedia/crow_american_pd_usgs.ogg` (8 s), `nps/common_raven.mp3`, `nps/yell_raven.mp3`, `nps/yell_magpie.mp3` | PD |
| gull | `nps/western_gull.mp3` (4.7 s) | `wikimedia/gull_herring_pd_avphillips_1.ogg` (18 s), `_2.ogg` (5.7 s), `wikimedia/gull_herring_cc0_advl.mp3` (19.5 s, from xeno-canto) | PD / CC0 |
| hawk | `wikimedia/hawk_scream_ccby3_psychobird.wav`: the classic "kee-eeer" scream, 3.4 s; the best **danger cue** | `wikimedia/hawk_red_shouldered_pd_mcgrane.ogg` (20 s, PD), `nps/osprey.mp3`, `nps/peregrine_raven.mp3` (PD) | CC-BY 3.0; alts PD |
| eagle | `nps/bald_eagle.mp3` (2.5 s) | `nps/yell_bald_eagle_2.mp3` (10 s), `wikimedia/eagle_bald_pd_nps.ogg`, `wikimedia/eagle_golden_ccby3_bubulcus.ogg` (3.8 s, CC-BY) | PD |

Real eagles sound thin and chirpy. The film "eagle scream" is actually a red-tailed hawk. For game readability, the eagle can reuse the hawk scream at a lower pitch.

### 4.3 Processing the calls need (audio area)

- Cut 3–6 clean snippets of 0.3–2.5 s per species.
- Convert to **mono** (3D sources should be mono) at 32 kHz, peak-normalise to about −3 dBFS, and balance loudness between species.
- Then use a `JSON` call bank of `{species: [file, …]}`, randomise `pitch_scale` by ±5–8%, and pitch down slightly with the bird's size scale.

### 4.4 Tooling on this Mac (tested)

There is no ffmpeg or sox, but macOS `afconvert` reads **mp3 and Ogg Vorbis** and writes WAV. For example:

```
afconvert -f WAVE -d LEI16@32000 -c 1 in.ogg out.wav
```

Verified on `wren_pd_sogning.ogg` and `western_gull.mp3`: output is 1 ch, 32 kHz, Int16. Trim with Python's stdlib `wave` module. Godot imports WAV and can set loop points.

---

## 5. Surveyed and rejected, or not downloaded

| Source | Why not |
|---|---|
| itch.io paid bird packs: SoltorchGames Coastal/Forest/Highlands/Lowlands/Wetlands ($5 each, $20 all), vertexcat "Common birds set" ($7), MrMGames voxel birds ($20) | Paid. Also, itch.io blocks curl (HTTP 403). |
| SoltorchGames free robin sample | Custom license (not CC0/CC-BY), itch download flow, and a species we don't need |
| Fab / Unity "Low Poly Bird: Ultimate Pack" (21 animated species) | Paid, Unity Asset Store license |
| Quaternius full packs (quaternius.com) | CC0, but hosted as Google Drive **folders** (no curl URL). Individual models were taken from poly.pizza's CDN instead. Quaternius has only 2 birds, both cartoon. |
| Kenney Cube Pets, Mini Forest | CC0, but cube/cartoon style |
| Sketchfab (CC-BY animated birds listed in 2.1) | Download needs a login; mixed styles |
| OpenGameArt .blend birds | No Blender on this Mac, so Godot can't import .blend |
| freesound.org (e.g. "Bird flapping wings" by Elfman-Rox, 238555, CC0) | Many good CC0 sounds, but **download requires login**. Worth it only if someone logs in manually. Its previews are not meant as download sources. |
| Sonniss #GameAudioGDC bundles | Royalty-free with no attribution needed, but **not CC**: a custom license with no AI/ML use, and 7+ GB per year (200 GB archive). Excellent if a human downloads it. |
| xeno-canto | Most recordings are **CC BY-NC-SA** (non-commercial). One CC0 file (herring gull XC707075) was taken via Commons. |
| BBC Sound Effects (RemArc) | Non-commercial license |
| Pixabay sounds/music | Pixabay Content License (not CC0/CC-BY) |
| Commons "Joseph Sardin – Passer domesticus tschilp call" (CC0) | Its credit says "Moineau domestique **en peluche**", which is a plush toy |
| OGA "Wind Loop" (AntumDeluge) | CC-BY 3.0 and not needed; the CC0 whoosh loop plus synthesis covers wind |
| OGA "First Light Particles" (CC0 piano) | 24 MB WAV; listed as a music option, not downloaded |
| Kevin MacLeod / incompetech | CC-BY 4.0 with direct mp3s. A good fallback for menu music if the CC0 loops feel thin. Not downloaded. |

**Data fix:** the NPS page slugged `sounds-goldeneagle.htm` actually holds **bald eagle** recordings (file code BAEA), so it was saved as `nps/yell_bald_eagle_2.mp3`.

---

## 6. Attribution: `docs/CREDITS.md`-ready text

Only what actually **ships** needs a credit. CC-BY items **must** be credited. The CC-BY license also asks that changes be indicated, e.g. "trimmed, converted to mono". NPS **asks** for a credit. CC0 and PD credits are courtesy only.

**Required if used (CC-BY):**

```
Audio
- "BarnSwallows.ogg" by Justin Wasack (via freesound / Wikimedia Commons), CC BY 3.0,
  https://commons.wikimedia.org/wiki/File:BarnSwallows.ogg (trimmed, converted to mono)
- "2018-10-10 startende stare.ogg" by Gunter Königsmann, CC BY 4.0,
  https://commons.wikimedia.org/wiki/File:2018-10-10_startende_stare.ogg (trimmed, converted to mono)
- "Screaming Hawk.wav" by PsychoBird (SoundBible), CC BY 3.0,
  https://commons.wikimedia.org/wiki/File:Screaming_Hawk.wav (trimmed, converted to mono)
- "Golden eagle.ogg" by Bubulcus, CC BY 3.0,
  https://commons.wikimedia.org/wiki/File:Golden_eagle.ogg
- "Troglodytes troglodytes chirp.ogg" by Amada44, CC BY 3.0,
  https://commons.wikimedia.org/wiki/File:Troglodytes_troglodytes_chirp.ogg

3D models (only if geometry/textures are shipped, not needed for visual reference)
- "<Title>" by Poly by Google, CC BY 3.0 (https://creativecommons.org/licenses/by/3.0/),
  via Poly Pizza https://poly.pizza/m/<id>
  (Cactus wren 6b7Ul6MeLrJ, Sparrow 3rTjKefT184, Cliffswallow 5dl4UWhvuTW, Mourning dove 1cF8DTp2sAi,
   Crow 1MIvWQ5Q3R9, Flying gull eMNhHDZakYp, Red-tailed hawk 9adZAZ2BmGL, Golden eagle 2YF1DGWp4vx,
   Bird 8Ph79kHbt9s, Radio tower eWEYV9ppUjv, Birds nest fq_bAKD1Khg)
- "Lil' Moth" by Lee Mason, CC BY 3.0, via Poly Pizza https://poly.pizza/m/8ojwMQpu6DK
```

**Requested (public domain, NPS asks for a credit):**

```
- Bird and nature recordings courtesy of the U.S. National Park Service
  (NPS Natural Sounds gallery; Yellowstone National Park Sound Library, with the
  Acoustic Atlas at Montana State University Library). Public domain.
```

**Courtesy (CC0 / PD, optional but kind):**

```
- 3D models and sounds by Kenney (www.kenney.nl), CC0
- 3D models by Quaternius (quaternius.com), CreativeTrio, Kay Lousberg, AssetQuest, CC0 (via Poly Pizza)
- Sounds from OpenGameArt.org, CC0: "Large Wings Flap" (AntumDeluge, from dave.des on freesound),
  "wind whoosh loop" (SketchMan3), "Forest Ambience" (TinyWorlds), "Ambient Bird Sounds" and
  "Heavenly Loop" (isaiah658), "Bird chirping sounds" (syncopika), "Calm Loop" (wipics),
  "Menu Chill Music" (etrock), "30 CC0 SFX loops" (rubberduck)
- Wikimedia Commons public-domain/CC0 recordings: G. McGrane (American Crow, Red-shouldered Hawk),
  USGS (Corvus brachyrhynchos call), avphillips (Gull 1/2, via pdsounds.org), Sonothèque ADVL
  (XC707075 Herring Gull, CC0), mary905 (Dove cooing, via pdsounds.org),
  Oona Räisänen (Passer domesticus), Sogning Norway (Troglodytes troglodytes)
```

Each file's exact source URL, license and author is in `assets/_candidates/<source>/MANIFEST.json`. Kenney's are in each pack's `License.txt`.
