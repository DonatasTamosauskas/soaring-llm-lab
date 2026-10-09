# Audio: the sound of flight and a living sky

Owner: audio area. Code in `scripts/audio/`, scene `scenes/audio/audio_director.tscn`,
assets in `assets/audio/`, tests in `tests/unit/audio/`, evidence in `artifacts/audio/`.
Contract notes: `docs/ARCHITECTURE.md` › Contract changes › *2026-09-26, audio*.
Credits: `docs/CREDITS.md` › Audio.

Nobody listened to any of this. Every claim below is a measurement of the
engine's own mix (captured from its buses with `AudioEffectCapture`) or of
the clips, and every sound has a spectrogram in `artifacts/audio/` for
review. A human listening pass on a Quest Pro is the one check still to do.

Every number audio takes from another area passes through one boundary
(`AudioInput`) before it reaches a gain, a filter or a smoothed state, and
every smoothed state restarts from its target should it ever become
non-finite. One glitching frame cannot silence the mix (round 4; see
**Fix round 4**).

Sound follows the world, not the listener's size: every NPC call and the
church bell are placed by their distance in world metres, at every player
size, so the Ecosystem's sky is heard from the first flight (round 5; see
**Fix round 5**). Every shipped call ends at a natural decay.

## What was built

| File | What it does |
|---|---|
| `scripts/audio/audio_director.gd` (`AudioDirector`) | Root of `scenes/audio/audio_director.tscn` (group `audio_director`, PROCESS_MODE_ALWAYS). Listens to `Events` (while in the tree), polls `PlayerBird.telemetry()`, runs the loop layers, one-shots, pause/menu mix, Settings volumes, and hands the flight speed ducks to the calls and the ambience. API: `play_ui(kind)`, `await shutdown()`, signal `cue(name, info)`, `debug_snapshot()`, `perf_stats()`, `settings` (where the volume sliders are read: the Settings autoload unless set). |
| `scripts/audio/audio_input.gd` (`AudioInput`) | The boundary: `num()`, `flag()`, `position_ok()`, `transform_ok()`. Every number from another area gets a safe default when it is not finite and is clamped when it is absurd. |
| `scripts/audio/flight_sound_map.gd` (`FlightSoundMap`) | Pure functions from telemetry and threat to sound parameters (levels, filter cut-offs, pitches, pan, the ambience and calls speed ducks, the danger drone's fast-flight make-up, the threatening predator's lift over the wind's edge). Total: `clean_telemetry()` sanitises every key, and any input gives finite output. Tested and plotted on its own. |
| `scripts/audio/call_voices.gd` (`CallVoices`) | NPC voices: a fixed pool of 8 `AudioStreamPlayer3D`, per-species call timing, levels set by measured loudness (`CALL_LOUDNESS`), every distance in world metres, air absorption set from distance (never Godot's default shelf), relevance ranking on the full distance law (`audibility`, checked against the mixer), no voice for a call that would reach the ear under -62 dB A (`MIN_CALL_DB`), voice stealing, the threatening predator heard from any distance (and lifted over a dive's wind), crowd normalisation by the voices' summed gain at the listener plus the speed and cue ducks on the Calls bus, moth flutter loops, NPC-on-NPC catch sounds, and letting go of birds that leave the world. |
| `scripts/audio/ambience_zones.gd` (`AmbienceZones`) | Zone weights from `World.get_landmarks()` and height above ground; crossfaded stereo beds levelled to one loudness and ducked by flight speed; the village bell in 3D, in world metres, capped at -8 dB, with air absorption from distance. |
| `scripts/audio/audio_bank.gd` (`AudioBank`) | Every clip, built/loaded once and shared: synthesis on worker threads (`SYNTH_THREADS`, 3 clips at a time), a content-addressed disk cache in `user://audio_cache/<key>/` (read and written on the workers), recordings from `assets/audio/`. |
| `scripts/audio/sound_designs.gd` (`SoundDesigns`) | The procedural sounds (wind body/edge, stall buffet, updraft hum, moth, 9 wingbeats, crunches, feather puffs, stinger, fanfare, heartbeat, drone, bump, brush, starling whistles, 5 ambience beds, church bell). |
| `scripts/audio/audio_synth.gd` (`AudioSynth`) | DSP blocks: noise, biquads (inlined, swept, circular for seamless loops), recurrence oscillators, FM, envelopes, loop folding, 16-bit `AudioStreamWAV` packing. |
| `scripts/audio/audio_buses.gd` (`AudioBuses`) | Bus layout (also shipped as `res://default_bus_layout.tres`), `ensure()`, the Settings volume taper. |
| `scripts/audio/audio_analysis.gd` (`AudioAnalysis`) | Offline measurement: FFT/STFT, RMS/peak/envelope, centroid, roll-off, flatness, tonality, pitch track, syllables, notes, periodicity, clip features, A-weighted short-term loudness (`loudness_aw`, with where its loudest window is), ITU-R BS.1770 K-weighted programme loudness (`lufs`), octave-band and A-weighted levels of a spectrum, the A-weighted share above a frequency. |
| `scripts/audio/audio_plot.gd` (`AudioPlot`) | Spectrograms and charts drawn with `Image` (built-in 5x7 font, the project's data-viz palette). |
| `scripts/audio/tools/` | `decode_candidates.sh` + `plain_pcm_wav.py` (afconvert the candidates to PCM WAV), `audio_survey.gd` (spectrogram + syllables of every candidate), `call_prep.gd` (cuts, denoises and levels the shipped calls). Dev-only. |
| `scenes/dev/audio_synth_timing.tscn` | Dev-only: synthesizes every clip without the cache and prints each one's cost (first-launch evidence). |

### Mixer

```
Master [HardLimiter -1.5 dB]          <- master_volume   (9 buses, 6 effects)
├ Music                                <- music_volume
├ SFX   [muffle low-pass, off]         <- sfx_volume, ducked in pause/menus
│ ├ Wind   [HighPass, LowPass, Panner]    the player's wind
│ ├ Body                                  wingbeats, stall buffet, updraft hum
│ ├ Calls                                 NPC voices (crowd-normalised, speed- and cue-ducked)
│ └ Danger                                heartbeat + tension drone
├ Ambience [muffle, off]               <- ambience_volume, ducked in pause/menus and under cues
└ UI                                   <- ui_volume, never ducked
```

Settings slider v maps to bus gain 40·log10(v) dB (half the slider is
-12 dB, which sounds like half as loud; 0 mutes). `sfx_volume`,
`ambience_volume` and `ui_volume` are optional keys (default 1.0).

State mix (`AudioDirector.STATE_MIX`): PLAYING is unducked with no music.
CAUGHT keeps SFX unducked (the stinger is SFX) and lowers the Ambience
4 dB so the moment reads. PAUSED ducks SFX by 20 dB and Ambience by 14 dB,
muffles both (900 Hz low-pass), keeps UI, and plays the music 3 dB under
its menu level. MENU/BOOT/ENDED duck SFX 20 dB and Ambience 10 dB with full
music. The SFX and Ambience ducks each ramp linearly in dB (60 dB/s) to
their own target, so a transition that moves only one of them (PLAYING <->
CAUGHT, MENU <-> PAUSED) still lands. Music fades in over 2 s and out over
1.5 s, both linear, and is paused when silent. New NPC calls and bells
start only in PLAYING/CAUGHT.

### The sounds, and why they are made that way

**Wind (the main speed cue).** Two stereo loops on the Wind bus, 12 s and
7 s long so a long dive never hears the noise repeat (the pair realigns only
every 84 s, and the gust cycles within each loop share no common factor).
The *body* is pink noise with a low shelf, lightly decorrelated between the
ears, with ±0.5 dB gusts (deep gusts would read as speed changes). Both
loops have their rare noise peaks tamed to 11 dB over their RMS
(`AudioSynth.tame_peaks_pair`, a memoryless soft knee, then scaled back to
the calibrated RMS). They are just as loud (RMS -17.1 and -18.1 dBFS, as
before) with peaks at -5.4 and -4.4 dBFS instead of -3.0, and that
headroom goes to the rest of the mix. Its level
follows speed relative to the bird's own cruise: -14.3 dB at cruise and
-3 dB in a 2.6x dive (36 dB/decade below cruise, 27 dB/decade above;
the cruise anchor was -16.3 until round 3, see **Programme loudness**). A
bus low-pass opens from about 300 Hz (a dull rumble when slow) to about
7 kHz in a dive; bigger birds hear it darker, and a tuck opens it 60%
further. The *edge* is high-passed hiss plus three narrow wandering
"whistle" bands; it fades in above cruise and mostly when tucked. A tuck
also high-passes the body at 350 Hz (thinner) and adds 2.5 dB, so a tucked
dive is brighter, thinner **and louder to the ear**: +4.2-4.3 dB A-weighted
at the same speed (2.2x cruise; the test asks for 3). (Plain RMS is lower
when tucked, because the high-pass removes low-frequency energy the ear
barely hears; the tuck test pins the A-weighted level.) A
panner tilts the wind toward the ear facing the airflow when the head
turns (a strong VR direction cue). Speed is relative to cruise
(`SizeRules.performance`), so a glide sounds like a glide at every size.
From 0.55x cruise up, the ambience recedes as the wind rises (see
**Ambience**), so the wind is the loudest continuous sound whenever the
bird is really flying.

**Stall buffet.** A 2 s loop of exactly 28 feather-flutter pulses (14 Hz)
with a small low "thup" and slight timing jitter. `pitch_scale` sets the
buffet rate by size (14 Hz for a sparrow, about 10 Hz for an eagle). It
plays at full level while `stalled`, and at 40% of `stall_warning` when
that key exists.

**Updraft hum.** A soft G/D chord with each partial doubled 0.25 Hz apart
(slow beating), over an airy swell. It fades in from 0.25 m/s of lift to
full at 3 m/s and rises in pitch by up to 12% in strong lift, like a
variometer. Measured on the Body bus: silent without lift, -50 dBFS at
1 m/s, -35 dBFS at 4 m/s with the centroid 143 → 168 Hz.

**Wingbeats.** Nine synthesized whooshes: three size classes (small
2.8→1.6 kHz flutter, medium 1.5 kHz→750 Hz, large 800→330 Hz "whump" with
a pressure thump) × three variants. Each is a noise band swept down as the
wing passes, plus feather-rustle grains, with a 22-40 ms attack and a
62-75 ms decay. Level is set by flap strength (-10 dB at 1.0, about 9 dB
lower at 0.2; `FlightSoundMap.WHOOSH_DB`). Pitch follows mass within the
class, ±5% random, and a variant never repeats twice in a row. Each
whoosh plays in 3D at the flapping hand (`LeftHand`/`RightHand` under the
rig; arm's length to that side without a rig) with panning strength 1.5,
which gives about 12 dB between the ears; side 0 plays both. The whoosh
players have no air-absorption shelf (a wing at arm's length): the
rendered whoosh is as bright as its clip, centroid within 3-4% (the test
allows 10%). Until round 3 Godot's default shelf dulled the small bird's
flutter from 3.6 to 2.0 kHz; without it a full flap was as loud as the
catch crunch (about -25 dB A), so the whoosh came down 3 dB (from -7) to
sit under the reward, still 10 dB and more over the wind up to 1.5x
cruise.

**Catch / caught / tier-up / collisions.**
- *Catch:* a crunch (five crisp grains in 70 ms over a pitched-down bite)
  and then, 80 ms later, a feather puff (an airy burst, then feathers
  thinning out), pitched by prey size. The feathers fly after the bite, and
  the two onsets no longer stack. The crunch's needle peaks are softened
  by 3 dB (`AudioSynth.soften_peaks`) and it plays 3 dB lower (-9 dB), so
  it is just as loud with 3 dB more headroom. A second catch within
  0.25 s (two prey in one sweep) plays 6 dB lower (`CUE_STACK_DB`): both
  are heard, but the second crunch does not land on the first at full
  level. On the mix, two catches in one frame peak +3.5 dB over one, not
  +6 (pinned since round 4). NPC-on-NPC catches in earshot play a quieter
  crunch in 3D.
- *Caught stinger:* a low boom and a descending D-minor motif (A4, F4, D4
  over D3) in a warm FM brass voice, with feathers.
- *Tier-up fanfare:* a rising D-major arpeggio of glassy FM bells, a
  shimmering chord and sparkles. Losing a tier is not celebrated.
  GameLoop's `apex_reached` plays it lower, `victory` at normal pitch.
- *Cue ducks* (`AudioDirector.CUE_DUCK`): while a reward or failure cue
  plays, everything but the cue and the player's own wingbeats steps back:
  the continuous layers (wind, buffet, hum, heartbeat, drone) and, since
  round 3, the rest of the world (the Calls and Ambience buses, so the
  NPC calls and the bell too):
  - catch: -5 dB for 0.35 s in ordinary flight, deeper in a fast dive
    (`FlightSoundMap.catch_duck_db`, below);
  - caught: -10 dB for 2.5 s;
  - fanfare: -6 dB for 2 s.

  The duck drops at once, masked by the cue's own onset, and comes back
  smoothly. A smoothed duck would arrive after the transient it is meant
  to make room for.
- *The catch in a dive.* Round 3 found a 5 dB duck left the crunch only
  1-3 dB A over a tucked dive's wind, the loudest sound in the game. The
  wind's A-weighted level follows its body level almost exactly, 1.5 dB
  per dB (measured at seven speeds, spread and tucked, within 0.8 dB):
  `WIND_AW_AT_0 + WIND_AW_PER_DB x body_db`. So the catch duck brings the
  wind 11 dB under the crunch (-25.2 dB A, loudest 0.2 s), 5 dB at
  least, 14 at most (`plots/catch_duck.png`):
  - -5 dB up to about 1.9x cruise spread (1.5x tucked);
  - -11 dB at 2.6x spread, -14 dB in a tucked 2.6x dive.

  Measured from the frames where the crunch sounds, the crunch stands
  19.2 dB A over the wind at 1.2x and 9.3-9.7 dB A in a tucked 2.6x dive
  (the test asks for 6). The duck measures -4.7 and -13.8 dB against -5
  and -14 designed. Why 11 rather than 6: the duck lands in the same mix
  block as the crunch, so an analysis window that starts a frame early
  counts undiminished wind. One 23 ms frame at the dive's level weighs as
  much as a dozen ducked ones.
- *Ducking the world too* keeps a nearby crow, a hawk's scream or the
  tolling bell from landing on the crunch at full level. Before it, the
  heavy-play belfry scene touched -1.3 dBFS before the limiter once Godot's
  shelf was gone. It also lets the moment read.
- *Collisions and perching:* a bump scaled by impact speed, a feather
  rustle for wing brushes (impact 0), and a soft grip rustle on perching.

**Danger.** A heartbeat (lub-dub with 2nd-4th harmonics and a soft knock,
because headset speakers barely reproduce 55 Hz) plus a tension drone (a
minor second, E3 against F3, with a 6 Hz tremolo and a thin E5).
- *Level:* the heartbeat is silent at threat 0 and rises strictly to -8 dB
  at 1.
- *Crest:* its 2nd and 4th partials are a quarter cycle out of phase and
  the fundamental is 0.7 of the old weight. At the same A-weighted and
  speaker-band loudness as the earlier beat at -5 dB, it peaks 3 dB lower.
- *Tempo at a fixed pitch:* it speeds up from 60 to 111 bpm without
  changing pitch. The director schedules each beat into an
  `AudioStreamGenerator`, the lub and the dub separately: a slice and a
  `push_buffer` per frame, no per-sample GDScript.
- *Rhythm:* the dub follows the lub after 0.26 s/√rate (0.19 s at contact,
  as a real heart's systole shortens), and the pause after it is still
  clearly longer (0.36 s at contact). It stays "lub-dub, pause" instead of
  an even double-time pulse.

It used to be a loop sped up with `pitch_scale`, which raised the heart
about 10.6 semitones at contact. The drone enters above 0.25 and rises
early (a smoothstep to the 0.35 power since round 5: -16 dB at 0.5, -12 dB
at 1; the square root it was put it 2 dB lower at 0.5). It
is the layer that carries the danger over the wind, since its E3/F3 sits in
the 125-250 Hz bands where the flight wind is strongest and a headset
still plays. Round 3's louder cruise wind had put the danger cue at threat
0.5 under the wind there at 1.5x cruise; it now leads by about 5 dB at
0.5 (the test asks for 1). If the predator leaves the world before
GameLoop reports a new level, the danger cue falls silent: 20 dB and more
down 0.5 s later.

*The danger in a fast spread dive* (round 5). Above 1.5x cruise the wind's
body rises 27 dB per decade of speed, and with the wings spread nothing
thins its low end, so in a spread 2.6x dive the danger at threat 0.5 sat
2.6-2.8 dB under the wind (the round-5 verifier). The drone now rises with
the wind's body above 1.5x cruise, up to 6 dB, less as the wings tuck
(`FlightSoundMap.danger_makeup_db`; a tuck high-passes the wind at 350 Hz,
where the danger stands 11-19 dB clear already). Only the drone: its
E3/F3 is the part that carries the danger in those octaves, and it is
the low-crest layer (at threat 1 it peaks at -7 dBFS). In a spread 2.6x
dive the danger now leads the wind by 3-4 dB at 0.5 and about 8 dB at 1
(the suite's bars: 1 and 6; `plots/danger_over_wind.png`). Round 5 also
raised the drone at mid threat (above): with the make-up alone its lead at
0.5 moved between 1.4 and 2.6 dB from one gust of the wind to the next.

*The predator's scream* ("predator screech getting louder"). When the
threat crosses 0.6 the predator screams in 3D from where it is, and a
stooping hawk or eagle aimed at the player screams as its stoop begins.
These calls are *urgent*: they skip the reach cut, wherever ThreatWatch
names the hawk. The voice's unit distance is widened so the call starts no
quieter than a floor under the species' unit level (`threat_floor_db`, at
the distance the player perceives: world metres / world_scale), then grows
by the distance law as the hawk closes in, up to the voice's ceiling (a
full voice: 0 dB of gain). The floor is -6 dB from 400 perceived metres
out, then rises 1.5 dB per halving of the distance (round 4). Since round 5
the natural level is in world metres, so for a sparrow-sized player the
floor holds from far out to about 35 m and the free-field law takes over
from there: new calls from a hawk 60, 40, 20, 10 and 5 m away start at
about -6.0, -5.2, +0.2 dB and then a full voice (`plots/successive_screams.png`;
round 4: -6.0, -5.3, -3.8, -2.3, -0.8; round 3: -6 at every distance).
The threatening predator's voice is also exempt from the calls' speed duck:
in a dive it makes up the Calls bus's duck, level and ceiling alike, and
follows it. Since round 5 it also rises over the wind's edge layer, the
hiss and whistles that fill its band in a tucked dive (up to 4 dB when the
edge is fully in, `FlightSoundMap.threat_call_lift_db`). The crowd rule
still counts the voice at its lifted gain, so the scream is never louder
than a full voice under the dive's duck, and a near one pulls the Calls
bus down by as much. In a tucked 2.6x dive, at sparrow scale, the scream
from 45 m now stands about 3 dB over the wind in its best 2 or 4 kHz
octave and from 15 m about 6 dB (the round-4 verifier's probe; it read -0.3
and +2.1 before). The 5 s cooldown starts only when a scream actually
sounds. The threatening predator is ranked at its floor too (`priority`),
so a far scream still wins a voice. The scheduler keeps it in reach for
its ordinary calls (`in_reach`, pinned).

**NPC calls (3D).** Species are tuned by what they are:

| Species | Source | Character |
|---|---|---|
| moth | synthesized | a soft 42 Hz wing flutter loop, heard only within 5 m |
| wren | recording | loud trill (3 variants) |
| sparrow | recording | chirps |
| swallow | recording | twittering runs of buzzy notes |
| starling | synthesized | whistles (wolf whistle, falling "wheeoo", double "tseee-oo") |
| pigeon | recording (dove) | coos |
| crow | recording (raven) | dry "kraa" caws |
| gull | recording | herring and western gull laughing "keks" (4 cuts, each ending in a pause or trailing off) |
| hawk | recording | the red-tailed "kee-eeer" screech (3 cuts; the two short ones with a natural release) |
| eagle | recording | golden eagle yelps, bald eagle chitter |

Each species has a pace, a loudness at its unit distance (`VOICE.loud`),
a unit distance and a reach, all in **world metres at every player size**
(since round 5). The player sees the world magnified by 1 / world_scale: a
sparrow-sized player sees a crow 60 m away as a giant crow 450 m away. A
source magnified with the world carries as much further as it is bigger,
so the level at the ear depends on distance over size alone, which is the
physical law in world metres: a real sparrow hears a crow 60 m away as a
person does. Rounds 1-4 divided distances by `world_scale` but did not
magnify the sources, so every call played 17.5 dB too quiet for a
sparrow-sized player and its reach shrank 7.5x (a songbird cut at 12 m, a
crow at 27 m, a hawk at 40 m): the Ecosystem's sky was silent (see **Fix
round 5**). `world_scale` now only places the threatening predator's
urgency floor, which is about how far the danger feels.

*The living sky.* The Ecosystem keeps about 60 NPCs round the player,
mostly 60-110 m out. Every bird in reach calls at its species' pace, and
the 8 voices go to the loudest and most relevant calls. A call that would
reach the ear under -62 dB A takes no voice (`MIN_CALL_DB`): nothing that
quiet is heard in flight (the cruise wind is about -43 dB A, the beds
-38 dB A at rest), and in a full sky those calls, fading out at the edges
of their reach, took voices only to be stolen by the next near one. With
the sky laid out as AI.md documents it, a sparrow-sized player at cruise
hears ~200 calls a minute over the wind in their own octave, the loudest
~12 dB A over the cruise wind, and about one call in ten is cut short by
another taking its voice (`plots/living_sky.png`).

*Levels by loudness, not by peak.* Every clip is peak-normalised to
-3 dBFS, but a near-pure synthesized whistle carries 10-15 dB more energy
per dB of peak than a sparse recorded chirp, so by peak the starlings
towered over the sparrows (round 2). Each clip's A-weighted short-term
loudness (loudest 0.4 s) is now measured and tabled
(`CallVoices.CALL_LOUDNESS`; `audio_calls_test` re-measures every shipped
clip and fails, printing the table to paste, if any entry is 0.3 dB off),
and a voice plays the clip at `VOICE.loud - CALL_LOUDNESS` (±1.5/1 dB of
random variety). At its unit distance every clip of a species is equally
loud, except where that would need more than 0 dB of gain (a voice never
plays a clip's -3 dBFS peak any louder): `wren_3`, a short soft chirp,
stays 3.7 dB under the wren level, a quieter call type.

*Air absorption, from distance only.* Godot's `AudioStreamPlayer3D` has
a high shelf of its own (`attenuation_filter_db`, -24 dB at 5 kHz by
default) whose depth is (1 - gain) x that value, with the player's
`volume_db` inside the gain. The levelling above lives in `volume_db`,
so until round 3 the default shelf dulled every loud clip even up close.
The round-3 verifiers measured the wren, swallow and starling 10-14 dB
under their level at their unit distance and a 27 dB small-bird spread at
25 m, against 4.1 in the table this doc then quoted. That table was a
model, and the suite checked it only on paper. Every 3D player now sets
its shelf itself:
- calls and the bell use `CallVoices.air_absorption_db(distance)`, 0.04 dB
  per metre above 5 kHz, at most 12 dB (ISO 9613-1: 23 and 77 dB/km at 4
  and 8 kHz in mild humid air). A wren 25 m away loses 1 dB of its top
  octave, one at the edge of its reach 3.6 dB, a crow 150 m away 6 dB (a
  literal the suite pins). A far call is duller as well as quieter, and a
  near one is untouched.
- The wingbeat whooshes use none.

Each species' share of A-weighted power above 5 kHz
(`CallVoices.AIR_SHARE`, re-measured by the suite like `CALL_LOUDNESS`)
turns that shelf into a loudness loss (`air_loss_db`). `audibility()`,
which ranks the voices, is now Godot's whole law: inverse distance, the
near-field cap, the linear fade to the reach (left out before, which
overrated a small bird near the edge of its reach by up to 10 dB), and
the air loss.

The suite renders the balance on the mixer
(`test_calls_balance_holds_on_the_mixer`). Each species' loudest clip
(the lowest `volume_db`, where a gain-driven filter bites hardest) plays
through the voice pools at its unit distance and at 25 m, each voice on its
own tap bus (three pools of 8, one take). Both ears are summed, A-weighted, over the
loudest 0.4 s:

| on the mixer, dB A | wren | sparrow | swallow | starling | pigeon | crow | gull | hawk | eagle | moth |
|---|---|---|---|---|---|---|---|---|---|---|
| at the unit distance | -23.0 | -23.6 | -23.9 | -23.7 | -23.1 | -19.7 | -17.6 | -14.6 | -17.7 | -36.8 |
| at 25 m | -38.2 | -38.5 | -39.5 | -36.7 | -34.6 | -24.6 | -21.9 | -15.8 | -18.9 | — |

- **Unit distance:** every species is within 1.5 dB of `VOICE.loud`; the
  small gap is Godot's fade to the reach at the unit distance, which
  `audibility` includes.
- **Mixer against `audibility`:** within 0.7 dB for every species at both
  distances (the test allows 1). The worst are the wren and swallow at 25 m,
  whose trills lose a little more to the shelf's slope below 5 kHz than
  their share above it predicts.
- **Balance at 25 m:** wren..pigeon within 4.9 dB (limit 6); the starling
  1.5 dB over the recorded songbirds (limit 2); crows and gulls 10 dB
  over them, raptors on top. The values repeat exactly run to run: the
  renders are deterministic.
- **The swallow** (twitters mostly above 5 kHz, air share 0.67) is 0.5 dB
  louder than in round 2 (`VOICE.loud` -23), so it stays in the balance as
  the air takes its top octave.
- **Plot:** `plots/call_balance.png` shows the model, the mixer now, and
  round 2 as the verifier rendered it.

*Near field and flight.* Closer than its unit distance a call grows by at
most 6 dB and never past 0 dB of gain (`NEAR_BOOST_DB`; the cap moves with
a voice's fade so a close bird fades too). In a fast dive the Calls bus
dips up to 6 dB (`FlightSoundMap.calls_duck_db`, from 1.2x cruise): the
rushing air masks calls in real flight, and a close call no longer lands
at full level on the loudest wind of the game. The threatening predator's call makes that dip up (round 4, see the
scream above). Behaviour changes the pace: fleeing or hiding ×0.45 (alarm
calls), perched ×0.7, hunting raptors/gulls/crows ×0.5, the current
target ×0.6. A stooping hawk or eagle screams at once (NpcBird
`behaviour` signal).

A call's priority is its loudness at the listener (`audibility`) plus
boosts (the threatening predator +20 dB, the chased prey +6 dB). It takes a free
voice, or a voice already fading, or steals the weakest voice (judged by
what that voice will play next) if it beats it by 3 dB; otherwise it is
dropped. The victim fades out over 50 ms.

*Crowd normalisation* lowers the Calls bus by as much as the voices
together would play louder than one voice at its full level (0 dB of
gain at the ear, where a clip peaks at -3 dBFS). That is 10·log10 of the
sum of the voices' power gains at the listener (`crowd_target_db`, by
Godot's law from each player's own settings), in 0.25 dB steps, when
positive. A lone bird, or a flock far off, keeps its level. Birds calling
at arm's length add up to one full voice, not to the limiter. Round 2
counted voices (10·log10(n/3) above three). That left two or three loud
ones alone: a hawk screaming 16 m away and a crow 11 m away, with the
heart and the bell, reached -1.3 dBFS before the limiter once the shelf
was gone. With 8 voices 2-20 m away the bus comes down 6.75 dB. The
gain attacks fast and releases slowly. The bus is written only when the
total (crowd, speed duck and cue duck) moves by 0.05 dB or lands: 76
writes over a whole release, none once settled.

When the director leaves the tree the Calls bus goes back to 0 dB, and a
new director writes its own value on its first frame, so no gain carries
over to a reloaded scene. The voice pool is fixed: nothing is created or
freed while playing.

Birds leave mid-call all the time: prey is eaten, the Ecosystem recycles
far, surplus and outgrown birds (`alive = false`, `remove_child`,
`queue_free`), and Restart clears the sky. `Events.bird_removed` fires
from the bird's `_exit_tree` while it is still a valid object, and
`CallVoices.forget` then:
- lets go of every voice following it: the sound stays where the bird last
  was and fades out over 0.12 s;
- drops any call it had queued on a stolen voice.

Every other access goes through `_present()` (valid **and** in the tree),
with a separate `follows` flag. In Godot 4.7 a freed Object compares equal
to null, so `bird != null` cannot tell "no bird" from "freed bird". Queued
requests hold the caller's instance id, never the Bird, and are
re-validated when they start. A bird that is caught (`alive = false`) but
not yet removed falls silent the same way.

**Ambience.** Five stereo beds:
- *trees:* a leaf rustle whose grain density follows the gusts, plus the
  NPS Yellowstone bird chorus;
- *water:* lapping swells and resonant bubbles (Farnell's model) bunched
  on the wave crests;
- *village:* a low murmur and wind whistling round walls, plus a 3D
  church bell tolling three strokes every 45-80 s at the `church*`
  landmark (or the town centre);
- *meadow:* grass breeze and three crickets;
- *open air:* a soft breeze over rock and hills.

Each landmark kind maps to a zone with a strength. A landmark counts fully
inside 85% of its radius and fades out a margin beyond it. Everything
fades with height above the ground (full up to 12 m, gone at 80 m, where
only the wind is left). Anywhere else near the ground, the open-air bed
plays at 0.3. Beds crossfade with a 1.2 s time constant and pause when
silent. See `artifacts/audio/plots/ambience_map.png` for the weights over
the real world.

*Levels.* Every zone sits at about -38 dB A-weighted per ear at full
weight (`BEDS`: leaves -17, forest chorus -16, water -11.5, village -10.5,
meadow -21.5, open -13.5 dB). The clips differ a lot to the ear: round 2
found the meadow's crickets and grass 12 dB louder than the village
murmur at similar gains.

*Speed duck (the wind stays the speed cue).* Flying faster, the bird's own
airflow masks the world, as in real flight (wind noise at the ears grows
some 50-60 dB per decade of speed). From 0.55x cruise the beds (and the
bell) recede log-linearly to 15.9 dB down at cruise and at most 24 dB
from 1.36x (`FlightSoundMap.ambience_duck_db`, `plots/speed_ducks.png`):
- 0 dB perched, hovering or slow;
- 2.3 dB down at 0.6x;
- -15.9 dB at cruise.

It follows a dive in 0.25 s and lets the world back in over about a
second as the bird slows (the dev tour's lake shot). Paused or in menus
it releases (the state mix rules there; pinned since round 3).

Round 3 moved it twice. The cruise wind is 2 dB louder, so the beds sit
2 dB less ducked at cruise and keep round 2's place under it. The duck
also starts at 0.55x rather than 0.4x, so a slow glide near the ground,
under a quiet wind, keeps its world: 2.3 dB down at 0.6x instead of 7.9.
That glide measured 15.9 LU under the menu music and is now 9.2.

Flying at cruise 4 m up, the wind leads every bed by 9.8-10.4 dB
A-weighted and by 3.9-4.5 dB in each octave band it carries, over six
runs (the test asks for 6 and 2; the bands are 250 Hz-2 kHz for a
sparrow and 250 Hz-1 kHz for the darker eagle wind;
`plots/wind_over_ambience.png`). Round 2 had measured the cruise wind
2-14 dB *under* the beds near the ground.

*The church bell* tolls three strokes every 45-80 s while the village is
audible (`toll()` starts one at once). It is ambience, not a cue: -8 dB
within 20 m of the belfry, where `max_db` caps it (Godot's default +3 dB
ceiling made it, 8 m from the spire, the loudest sound in the game at
+1 dBFS), then 6 dB per doubling of distance, silent past 1200 m.
Distances are in world metres at every player size, like the calls (rounds
2-4 divided them by world_scale, so a sparrow-sized player 30 m from the
church heard it 18.5 dB quieter than a person; a giant bell carries as far
as it is big). The speed duck and the cue ducks take it down with the
beds, and its air absorption is set from distance like the calls'. A
stroke 8 m from the tower peaks at -9.7 dBFS on the Ambience bus
(`plots/bell_vs_distance.png`).

**Menu music.** OGA "Heavenly Loop" (CC0): sustained pads with no
percussion, the only gentle candidate (the other two loops have drums).
It is mastered quiet and very steady: -23.9 LUFS over its 33.7 s, every
2 s within 1 LU of that, peak -11.9 dBFS. It gets +10 dB of make-up gain
(+9 in round 1, +12 in round 2). At the default settings (music 0.5,
master 0.8) that is about -28.6 LUFS at the output, and -29.7 LUFS
(-34.2 dBFS RMS) over the suite's window at the loop's start.

The level is set by the programme, not by an absolute number (see
**Programme loudness**): the menu is where the player sets the headset
volume. It sits at the loudness of ordinary play near the ground
(perched in a wood with birds calling -28.1 LUFS, flapping at cruise
-27.7), with a glide at cruise within 8 LU under it. With both sliders at
full its peaks reach -2.1 dBFS, under the limiter's -1.5.

**UI sounds.** Each kind plays at its own level (`AudioDirector.UI_LEVEL`),
set from its measured loudness (A-weighted, integrated over 0.1 s): the
Kenney files span 25 dB to the ear, and one -4 dB for all put the confirm
chime 20 dB over the click. They follow the music, 2 dB lower since round
3. At the default settings select, open, back and confirm land within
0.4 dB of each other, 6.4-6.8 dB over the menu music. Click and hover are
20-90 ms ticks as loud as their peaks allow (-3 dBFS), which integrate
to +3.1 and -1.6 dB against the music (a tick is heard by its onset).
`play_ui(kind, volume_db)` still takes an explicit level.

**Loudness hierarchy** (`AudioDirector.LEVEL`, FlightSoundMap, `VOICE.loud`,
`BEDS`). Reward and failure moments are loudest *at their moment*: the
crunch (-9 dB, peak-softened, so as loud as -6), the stinger (-4 dB) and
the fanfare (-6 dB), each with a cue duck under it that takes the flight
layers, the calls and the ambience down together. Below them, loudest
first:
- the dive wind (Wind bus about -21.5 dBFS RMS);
- nearby calls (raptors -14/-17, crows and gulls -19/-17, small birds
  -22 to -23 dB A at their unit distance);
- wingbeats (-10 dB; a full small-bird flap is about 3 dB A under the
  crunch);
- danger (-8 dB max, low-crest);
- the cruise wind (about -35 dBFS RMS, -43 dB A);
- the ambience beds (about -38 dB A at rest, -54 dB A at cruise) and the
  bell (-9.7 dBFS peak at the tower, at rest).

**Programme loudness** (ITU-R BS.1770, K-weighted, at the output with
the shipped settings; `plots/programme_loudness.png`). The round-3
experience verifier's probe measures every state for 2 s:

| | menu | perched, birds | flapping at cruise | glide at cruise | slow glide 0.6x | tucked dive |
|---|---|---|---|---|---|---|
| round 2 (their run) | -26.6 | -29.9 | -31.4 | -38.2 | -42.5 | -19.5 |
| now (their probe, rerun) | -28.6 | -28.1 | -27.7 | -36.3 | -37.8 | -19.4 |

(LUFS; their menu window is a louder stretch of the loop, 1.1 LU over
its average.) A player sets the headset volume in the menu, then plays:
ordinary play near the ground is now as loud as the menu, a glide at
cruise 7.7 LU under it (was 11.6) and a slow glide 9.2 (was 15.9), and a
dive 9 LU over it. The glide is the wind alone and cannot come closer
without flattening the dive: AU1 wants the dive 12 dB over a glide on the
Wind bus (13.2-13.7 dB now; 25 dB would be physical), and the dive is
already near the -18 LUFS of portable targets. So the cruise wind came
up 2 dB and the music down 2. The suite pins the menu at -32..-27 LUFS
and a glide within 8 LU under it: 6.9-7.0 LU over three runs.

**Headroom** is managed by shape, not by turning things down:
- the wind's noise peaks, the heart's crest and the crunch's needle peaks
  are reduced at equal loudness;
- a second quick catch plays 6 dB lower;
- calls dip in a dive;
- NPC voices are normalised by their summed gain at the ear;
- a cue ducks the world under it.

Realistic heavy play (the suite's two scenes, each with two catches 50 ms
apart) peaks between -2.64 and -5.59 dBFS before the limiter over 30
trials on round 4's final code, with the event timing shifted, against the
-1.5 dBFS ceiling (`tests/shots/audio_probes/peaks_test.gd`,
`artifacts/audio/fix_r4/heavy_play_peaks_*.log`). Round 5 added a third
scene to the probe, a spread 2.6x dive, where the drone's make-up is at its
full 6 dB (the tucked dive has the hawk's full 4 dB lift instead). Over
five trials each on round 5's final code: belfry -2.98 to -6.12, tucked
dive -3.25 to -3.73, spread dive **-2.22** to -3.62 dBFS
(`artifacts/audio/fix_r5/heavy_play_peaks_final.log`; `_run1.log`, before
the drone's mid-threat change, read -2.20 at worst). The spread dive is the
closest to the ceiling, 0.7 dB under it: the danger bus (the drone at
threat 0.8 with its make-up) peaks at about -6 dBFS there. The suite's own
final runs measured -3.8 (dive) and -4.4 to -4.9 dBFS (belfry).
`artifacts/audio/mix_levels.json` lists every clip's peak/RMS and each
cue, UI sound, bed and the bell at its mix level.

### Performance (Quest)

- **Runtime.** No per-sample GDScript: every sound is a pre-rendered
  buffer, and each frame only changes volume, pitch and bus-filter
  parameters, each written only when it actually changes. The NPC
  scheduler visits a few birds per frame in round-robin (never all 60 at
  once: one frame visits ceil(n / 12) birds, pinned). Measured on the M1
  Pro with 60 birds and 40 landmarks, the flight changing on every call:
  **0.078-0.084 ms per `_process` call CPU-bound** (the tight loop, round
  5's final runs at machine load 7-8). Round 4 quoted 0.067-0.084 ms for a
  loop that repeated one frozen state, not "flight changing every frame" as
  this doc then said; the round-5 engineering verifier measured the
  difference, 0.076-0.091 ms against 0.066-0.069. The wall-clock frames
  (120 of them, the flight changing each frame) read a mean of
  0.12-0.14 ms, a median of 0.11-0.13 ms and a p95 of 0.16-0.20 ms. A
  wingbeat event handler costs 0.014-0.015 ms. GDScript on a Quest Pro is
  roughly 3-4x slower, which puts the director around 0.25-0.5 ms against
  the 1 ms budget. Mixing itself runs on the engine's audio thread and is
  not in these numbers.
- **Load.** Synthesizing every procedural clip takes about 6 s of GDScript
  work on the Mac (`scenes/dev/audio_synth_timing.tscn` prints each clip;
  the two wind loops and the village bed cost most), several times that on
  a Quest. Since round 5 the clips are built `SYNTH_THREADS` (3) at a time
  on the `WorkerThreadPool`, in priority order (the wind first, beds last),
  each used the moment it exists: a first launch in the background takes
  2.8 s of wall time on the Mac (was about 6), and a synchronous build
  (tests; every fresh test sandbox) 2.2 s on all the pool's threads. The
  first launch starts in the menu, so the wind (ready in under a second on
  the Mac) is in place long before take-off.
- **Cache.** Finished clips go to `user://audio_cache/<key>/`. The key is
  a hash of the design sources (`SoundDesigns`, `AudioSynth`, the job list
  in `AudioBank`), the engine version and `DESIGN_VERSION`. Any change to a
  design therefore misses the cache and is synthesized afresh, and a test
  checks that the designs use no project class outside those sources.
  Clips are bit-identical to a fresh synthesis, since the designs are
  seeded, and a test checks that too.
  - The cache is plain 16-bit PCM behind a small header, written and read
    **on the worker**: the main thread never touches the disk for audio.
    ResourceLoader/ResourceSaver stay off the worker, because they leave
    engine load tokens behind there.
  - Writes go to a temporary file that is renamed into place, so a
    truncated clip is detected and rebuilt.
  - Folders from older designs or builds are pruned: every unstamped
    leftover, and all but the 3 most recently used others.
  - The clips are written and read on the synthesis threads; each clip is
    its own file, and the folder is made before they start.
  - Measured first launch: starting the build (imported files only)
    9-11 ms, then a median of 0.005-0.006 ms per frame of main-thread bank
    work while the workers synthesize (0 frames over 0.5 ms). The test
    pins the median under 0.1 ms and at most 2 of the frames over 0.5 ms:
    main-thread cache writes would cost a slow frame per clip. It used to
    pin the worst frame, and one round-3 run under load 10 read 0.69 ms on
    a single preempted frame. A warm launch reads all 35 clips back in
    8-19 ms on the worker (`audio_synth_timing.tscn` prints both).
- **Rates and formats.** Sample rates are 32 kHz for effects and 22.05 kHz
  for beds and the hum. Imported WAVs are QOA-compressed.
- **Mixer.** Nine buses and six bus effects: the limiter, the SFX and
  Ambience muffles, and high-pass, low-pass and panner on Wind. There are
  13 looping players (silent ones paused, pinned since round 5): 6
  flight/danger layers, one of
  them the heartbeat generator, the music, and 6 ambience beds. On top of
  those come 8 pooled 3D voices, 4 whoosh voices, the 3D bell and 2
  polyphonic one-shot players. The voices' air-absorption shelves and the
  crowd's summed gain change slowly. They are refreshed every 4th frame
  (the shelves staggered across the voices, the crowd target at once when
  a voice starts), and a shelf is written only when it moves by 0.25 dB.
  The crowd target moves in 0.25 dB steps, so the Calls bus is not
  rewritten every frame as birds move.

### Fix round 5 (verifier findings)

The round-5 experience verifier failed round 4 on two major defects: the
sky was silent for small players, and 9 of 25 shipped calls stopped
mid-note. Both verifiers also listed minor defects. Each is fixed at its
root and pinned by a test that fails on the old behaviour. A mutation run
on a private copy put each defect back, and each fix of this round out, one
at a time: the suite catches all 15, and passes unmutated
(`artifacts/audio/fix_r5/mutants_summary.log`, `mutate.py`). One bar was
changed for the brief's own (the cost test, justified in the table); none
was loosened to pass.

| Finding | Root cause and fix | Pinned by (result) |
|---|---|---|
| **Major:** the living sky silent for small players. The verifier laid out 60 NPCs as AI.md documents the Ecosystem (mostly 60-110 m out): a sparrow-sized player heard 0 calls in 14 s, a pigeon-sized one 5, all 23 dB under the wind | The distance law. Every call's distance was divided by `world_scale` ("perceived metres") while the sources were not magnified with the world, so a sparrow-sized player heard every call 17.5 dB too quiet and cut a songbird at 12 m, a crow at 27 m, a hawk at 40 m. A world magnified by 1 / world_scale with its sources magnified too sounds exactly like the real world: the level depends on distance over size. **Calls and the church bell now use world metres at every size** (reach, unit distance, fade, air absorption); `world_scale` only places the threatening predator's urgency floor. With every bird of a full sky in reach, a call that would reach the ear under -62 dB A no longer takes a voice (`MIN_CALL_DB`): those were the calls fading out at the edge of their reach, and they took voices only to be stolen | `audio_wind_test.test_living_sky_is_heard_over_the_wind` (new). Simulated: a voice pool of the director's class stepped at 60 Hz in the Ecosystem's sky at the sparrow's, the pigeon's and the eagle's world scale; each call placed at the ear by Godot's law on its voice's own settings and heard when it stands over the cruise wind in its own octave. Bars: a call heard in every 5 s, at most a quarter cut short, 70% of the calls started heard. Result: 48 of 60 calls heard in 15 s at sparrow size (16/18/14 per 5 s), 9% cut short, the same at every scale. On the mixer, the sparrow's flight session through the same sky: 13 calls in 2.6 s, the loudest -31.2 dB A against a -42.9 dB A cruise wind, 31 dB over it in its own octave. `test_scheduler_calls_respect_reach_and_scale` (rewritten: a songbird 60 m away in reach at the sparrow's scale, the same bird ranked the same at every scale), `test_church_bell_is_ambience` (a sparrow-sized player 30 m away hears it as a person does: -11.7 dB both). The verifier's probe now: sparrow 63 calls in 14 s, loudest -31.3 dB A (was 0), pigeon 56, -28.7 dB A (was 5, -66.5), eagle 57 (was 90); its chorus test: 5% cut short (was 21%) |
| **Major:** 9 of 25 calls ended mid-note (gull_4 -3.2 dB, hawk_3 -5.4, gull_2 -10.3, hawk_2 -10.6, gull_1 -13.4, wren_1 -13.7, gull_3 -17.5, swallow_3 -18.6, swallow_1 -19.5 under their loudest 50 ms, just before the end fade) | The cut windows. A window that ended inside a note, or less than ~0.1 s after one, left the note to the fixed 40 ms end fade; the suite's trim test looked at the last sample and the trailing silence only. The gull, wren and swallow cuts now end in a pause of the call at least 0.12 s after the last note (the herring gull's laugh in two cuts sharing one note; the western gull's gaps are all ~80 ms, so one cut runs to the recording's own end and one trails off). The hawk's scream is one continuous note, so its two short cuts get a release: their last 0.8 s fall 60 dB, linear in dB, at the rate the scream itself dies away (`call_prep.gd`, `release`). The new check also found two synthesized starling whistles ending 8 and 17 dB up (the buffer ended on the whistle's release) and a faint click at every whistle's end (its envelope met zero at an infinite slope): the buffers run 0.1 s past the whistle, which eases out | `test_recordings_are_trimmed_and_levelled`: every call, recorded or synthesized, ends at least 20 dB under its loudest 50 ms in the 50 ms before its end fade (the verifier's measure). Worst now -24.9 dB (sparrow_1, unchanged); the re-cut ones -28.5 to -42.2; hawk_2 -42.2, hawk_3 -41.8; starlings silent. `CALL_LOUDNESS` re-measured (gulls and starlings) and the balance on the mixer re-rendered: unchanged at 25 m, 4.9 dB small-bird spread. The verifier's probe: no chopped clip (`plots/call_endings.png`) |
| Minor: the danger cue at threat 0.5 in a spread 2.6x dive 2.6-2.8 dB under the wind at 125/250 Hz; the hawk's scream at the wind's level in a tucked 2.6x dive (-0.3 dB from 45 m) | Above 1.5x cruise the wind's body rises 27 dB per decade and, wings spread, nothing thins its low end; in a tucked dive the edge layer (hiss and whistles) fills the scream's band. The drone rises with the wind's body above 1.5x cruise, up to 6 dB, less as the wings tuck (`danger_makeup_db`), and rises earlier with the threat (-16 dB at 0.5, was -18: with the make-up alone the lead at 0.5 moved between 1.4 and 2.6 dB from one gust to the next). The threatening predator's voice rises with the edge layer's gain, up to 4 dB (`threat_call_lift_db`), on top of making up the calls' speed duck; the crowd rule still holds it to a full voice under the duck | `test_danger_cue_scales_with_threat` (now in the flight session): in a spread 2.6x dive +3.1 to +4.0 dB at threat 0.5 (bar 1) and +8.3 to +8.4 at 1 (bar 6, two beat periods); at 1.5x +5.2 to +5.3 at 0.5. `test_successive_screams_grow_as_the_predator_closes`: in a tucked full dive the threat's voice is lifted 10 dB (the 6 dB duck and 4 dB over the edge, literal), its far call reaches the ear 1.7 dB louder than at cruise and never louder than a full voice under the dive's duck. The round-4 verifier's dive probe on round 5's code: scream from 45 m +2.9 dB over the wind in its best 2/4 kHz octave (was -0.3), from 15 m +6.1 (was +2.1); spread 2.6x danger at 0.5 +3.9 (was -2.6) |
| Minor (both): the suite over its 60 s budget (60.7-68.8 s) | Real-time mixing, plus about 6 s of cold synthesis in every fresh sandbox (each has its own user://). Clips now synthesize on worker threads (a cold build 2.2 s). The danger cue rides along the flight session on its own bus (the session records Wind, Body, Danger and Calls at once) instead of a 7.8 s test of its own; the pause checks moved into the menu-music test's pause, which also measures the SFX setting while the music fades; the call balance renders in one take; the tuck is judged at 2.6x (the dive's own steps); after-test waits are a frame | 54.2-54.7 s over the final three runs at machine load 7, 43 tests, 1100 assertions (53-55 s over this round's other full runs) |
| Minor (eng): the suite blind to the director losing PROCESS_MODE_ALWAYS (mutant R7) | Every stage sat under the runner, which is ALWAYS | The menu-music and pause test builds its stage under a PAUSABLE parent, and the game's pause pauses the tree: R7 is caught (music silent, no duck) |
| Minor (eng): the VR rig path (rig world_scale, whooshes at the hands) not in the suite (R1, R2) | Test gap | `test_vr_rig_sets_the_scale_and_the_hands` (new): an XROrigin3D in `player_rig` at world_scale 0.14 with its hands; the voices take its scale over telemetry's, each flap plays at its hand, both wings at both, and a change of scale is followed |
| Minor (eng): the 0.1 ms tight-loop bar flaky under load (0.106 ms once) | The bar was a regression tripwire with no footing in the brief, and a best-of-5 still lands on an efficiency core now and then | The cost test asserts the brief's budget: the wall-clock mean under 1 ms (0.13-0.17) and the tight loop, with the flight changing on every call as the verifier asked, under 0.25 ms, which is 1 ms on a Quest 3-4x slower (0.077-0.082). The regression the tripwire caught (mutant R5: the scheduler visiting every bird each frame) is now pinned structurally: one frame visits ceil(n / 12) birds (6 of 61) |
| Minor (eng): silent-layer pausing and air absorption claimed but unpinned (R3, R4) | Test gaps | `test_silent_layers_cost_no_mixing` (new): at cruise with nothing to play the buffet, hum, heart and drone are paused, and 100 m up every bed; the scheduler test: a call 150 m away has a 5-7 dB shelf above 5 kHz (ISO 9613-1, literal; -6.0) and one 60 m away 1.5-3 dB |
| Minor (eng): doc inaccuracies | (1) The cache is per sandbox now (tools/gd.sh gives each its own user://), not shared. (2) Round 4's tight loop repeated one frozen state | Corrected (Known limits, Performance) |
| Minor (eng): dead code and a per-frame array shift | `perf_max_usec` removed (no reader in the tree); the frame-cost window is a ring. `Voice.started` is kept and now read by `playing()` (a call's age); the round-5 experience verifier's own chorus probe reads it too | — |
| Minor (eng): the calls-balance model read `NEAR_BOOST_DB` from the code under test | — | A literal 6 dB in the test |
| Minor (exp): nothing calls `play_ui`; no AudioDirector in main.tscn | Integration's files, not audio's | Recorded in ARCHITECTURE.md (round-5 audio note) for integration; the API is ready |

More things round 5 turned up:
- **The heart's pitch, measured over whole beats.** Moving the danger test
  into the session put a 2.2-period window on the resting heart: one lub
  more than dubs (the lub's partial sits a little under the dub's) read
  59.6 against 63.6 Hz at contact, 1.1 semitones (the first mutation
  baseline failed on it). Both windows are now exactly two beat periods:
  59.6 and 61.7-62.5 Hz, 0.6-0.8 semitones.
- **The fade's timing, measured every frame.** Folding the pause and the
  SFX setting into the menu-music test put recordings past the music's
  1.5 s fade, and the old loop that looked for the pause after them read
  1.8-1.9 s. The pause is now noted on the frame it happens: 1.50-1.51 s.
- **Thousands of engine writes in one frame stall the next frames**, as
  the round-5 engineering verifier found: the simulated sky yields a
  frame every 30 steps, and the cost test's tight loop one per block.
- **Headroom with the new make-ups.** See **Headroom**: the spread-dive
  scene's worst trial is -2.2 dBFS before the limiter, 0.7 dB under the
  ceiling.
- **Why -62 dB A.** At cruise the wind is about -43 dB A and the beds
  -54 (-38 at rest); a call 19 dB under the quietest of them is not heard
  in flight. It trims the last 10-15% of each reach (a songbird about 76 m
  out rather than 90). In the Ecosystem's sky, without it (the mutant
  L03), 26% of the calls were cut short at the pigeon's and the eagle's
  scale and 52-57% of those started were heard; with it 9% and 83%.
- **Bell and scream plots** are redrawn for world metres
  (`plots/bell_vs_distance.png`, `plots/successive_screams.png`), and
  three plots are new: `living_sky.png`, `call_endings.png`,
  `danger_over_wind.png`.

Where a verifier's claim needs a note:
- The round-5 experience verifier's living-sky probe prints a
  `reach_world_m` table computed by the probe itself as reach x
  world_scale. Since round 5 it no longer describes the code: every reach
  is in world metres at every size (a songbird's 90 m).
- The engineering verifier listed `Voice.started` as written and never
  read. It was never read by the product, but the experience verifier's
  chorus probe reads it; it is kept and the product now reads it too.

### Fix round 4 (verifier findings)

The round-4 experience verifier failed round 3 on one major defect: one
bad number from outside silenced a layer for the rest of the session. Both
verifiers also listed minor defects. Each is fixed at its root and pinned
by a test that fails on the old behaviour. A mutation run on a private copy
put each defect back, and each fix of this round out, one at a time: the
suite catches all 18, and passes unmutated (`artifacts/audio/fix_r4/mutants_summary.log`,
`mutate.py`). No threshold was loosened except the frame-cost test's
wall-clock median, which is now recorded rather than asserted (justified in
the table).

| Finding | Root cause and fix | Pinned by (result) |
|---|---|---|
| **Major:** one NaN in telemetry (`wing_extension`, `in_updraft`, `stall_warning`) or in the threat level silenced the wind, the hum, the buffet or the danger cue for good. Flight anticipates NaN wing states from a glitching tracker, and its telemetry is built from the raw state | Nothing from outside was sanitised, and a smoothed state never leaves NaN (`lerp` from NaN is NaN; Godot's `clampf`, `minf` and `maxf` pass NaN through or turn it into one bound, by argument order). Two lines of defence now. **The boundary** (`AudioInput`, `FlightSoundMap.clean_telemetry`): every number audio takes from outside gets a safe default when it is not finite and is clamped when it is absurd. That covers telemetry keys, masses, the threat level, flap strength, impact, `play_ui` levels, Settings volumes, the world scale and the frame delta. A NaN airspeed falls back to `Bird.velocity`, and a threat event whose level is not a number is ignored. Positions that are not finite or lie beyond 100 km are not used: a voice holds where its bird was, and the listener, the hands and the ground keep their last good values. Bad landmarks are skipped. **The state**: every smoothed gain, filter, pan and duck in the director, the voices and the ambience restarts from its target if it ever becomes non-finite, and a non-finite bus volume is never written | `audio_input_test` (new). Frame-stepped, 24 inputs × NaN, ±INF, ±1e30 for 4 frames, then normal input: nothing handed to the engine is non-finite at any frame. 0.5 s later every layer, fader, filter and duck is back within 1.5 dB (worst 1.34 dB, `tel.stalled` = 1e30 played as a stall). Every smoothed state set to NaN at once: back within 0.05 dB. On the mixer, a burst of every bad value at once leaves no non-finite sample, and wind, buffet and danger are back within 3 dB. All pure functions are total (190 cases). The verifier's probe: all six bad frames recover |
| Minor: the predator's scream masked in a tucked full-speed escape dive (7-9 dB A under the wind) | The Calls bus's speed duck (6 dB at 2.6x) applied to the one call the player must hear. The threatening predator's voice now makes up the bus's current duck, in level and ceiling alike, and follows it as the bird speeds up or pulls out. Headroom stays with the crowd rule, which counts the voice at its lifted gain: a near scream over a full voice pulls the Calls bus down by as much | `test_successive_screams_grow_as_the_predator_closes`: from 30 m the call reaches the ear in a dive exactly as at cruise (-6.4 dB both). From 2 m it is held to a full voice under the dive's duck (-5.9 dB ≤ -5.7). Pulling out of the dive mid-scream leaves it where it was (-6.4 → -6.4 dB). The verifier's probe, tucked 2.6x dive, scream over the wind in its best 2k/4k band: 15 m **+2.1 dB** (was -6.8), 45 m **-0.3 dB** (was -7.3), at the wind's level; spread 2.6x +6.2/+7.2 (was -1.0/-1.5) |
| Minor: successive screams did not get louder as the hawk closed in (every new call from 65 m to 6 m started at -6 dB) | A flat urgent floor. `threat_floor_db(d)`: -6 dB from 400 perceived m out, rising 1.5 dB per halving of the distance, up to the unit level. That is a quarter of the free-field law, so the far scream stays where it was (`plots/successive_screams.png`) | Same test: new calls from 60/40/20/10/5 m start at -6.0/-5.3/-3.8/-2.3/-0.8 dB relative to the unit level, each louder than the last. 10 m is +3.75 dB over 60 m (≥ 3) and 60 m keeps ≥ -6.5. The far-scream test is unchanged (65 m: 19.9 dB A over the wind). The verifier's probe reads the same numbers |
| Minor: the three hawk clips are nested cuts of one recording | Kept, and documented as intentional. The only clean red-tailed hawk recording (PsychoBird, 3.4 s) holds one scream, and the red-tailed hawk's scream is a single stereotyped call. The red-shouldered hawk's "kee-ah" was tried in round 1 and measured as an eagle yelp. Variety comes from three lengths, ±5% pitch and size | Known limits |
| Minor: the frame-cost test sat near its wall-clock limit (median 0.19 of 0.2 ms at load 8) | The wall-clock median carries the OS's preemption on a machine shared by about 10 agents. The director's cost is the CPU-bound tight loop, 0.055-0.07 ms. This round's runs showed it again: one run read a median of 0.21 ms, and an unmutated copy 0.26 ms at load 12, while the tight loop stayed at 0.07 | As the verifier suggested, the test asserts the tight loop (< 0.1 ms, unchanged) and a robust lower statistic, the fastest quarter of the frames (< 0.2 ms, new). The median, mean, trimmed mean and p95 are recorded, not asserted: this is the one threshold dropped, because on a loaded machine it measures the load, not the director. 120 frames, was 200. Results: tight loop 0.069-0.084 ms, fastest quarter 0.14-0.16 ms, median 0.16-0.21 ms, at machine load 18-32 |
| Minor (eng): `test_event_cues` could not tell a missing fanfare (mutant V13) | `stop()` plus two short headless frames left the previous cue's tail in the window: the stinger's tail passed for the fanfare | Each cue now waits for two mix blocks of silence on the SFX bus (asserted) before it fires. V13 and V14 are caught |
| Minor (eng): the stinger's and fanfare's audibility, and the caught duck, had no absolute bar (V02, V10) | Test gap | `test_reward_and_failure_cues_cut_through_the_wind` (was `test_catch_cuts_through_the_wind`). In a tucked 2.6x dive the stinger and the fanfare each duck the wind by their design (literal 10 and 6 dB, ±1.5: -9.7 to -9.8 / -6.0 to -6.2 dB). They stand ≥ 6 dB A over it (+9.4 to +9.6 / +8.4 to +9.2 dB A), and the calls and ambience step back by the same duck at their onset |
| Minor (eng): the both-wings flap (side 0, most real wingbeats) was never rendered (V06) | Test gap | The wingbeat render test plays side 0 too. The ears are within 2 dB of each other (-32.2 dB in each ear), total power is within 3 dB of a one-wing flap (+2.0 dB), and it decays in < 0.3 s |
| Minor (eng): `CUE_STACK_DB` unpinned (V04) and its comment stale | Kept, with no mix change. The comment now says why it stays: round 3's world duck keeps heavy play's headroom without it, and two bites at full level are +6 dB of transient | `test_event_cues`: two catches in one frame, the same clip (the director's rng reseeded), peak +3.53 dB over one. That is a full crunch plus one 6 dB down (+3.5); no rule would read +6 |
| Minor: doc and comment inaccuracies | (1) Round 3's claim that its mutation run caught "every behaviour listed" was wrong: V02, V04, V06, V10 and V13 survived. They are caught now. (2) The `CUE_DUCK` comment said -12.6 dB in a tucked dive; it is -14, the limit. (3) Round 3's contract note said every `UI_LEVEL` default dropped 2 dB; click and hover stayed at -2 (correction appended to the note). (4) The dive-over-glide contrast is quoted from this round's runs. (5) Round 3 quoted the soft flap 7.4 dB quieter; its own report measured 6.2, as this round's does | — |
| Minor: audio tests rewrote the shared `user://settings.cfg` | Settings always saves, and the tests set volumes through it | `AudioDirector.settings` (a Settings-like source; the autoload when null). The fixture gives every director an in-memory store, and no suite test touches the Settings autoload. `test_settings_volumes_drive_the_buses` asserts that the autoload's values and the file are unchanged |

More things round 4 turned up:
- **Godot guards some of this itself.** A player's `volume_db` refuses
  NaN ("Volume can't be set to NaN", which is how the flap mutant was
  caught). Smoothed gains, filter cut-offs, positions and shelves are not
  guarded, so the guard has to live in audio.
- **Three flaky reads,** found by the first mutation pass
  (`mutants_run_first.log`), are fixed in the tests:
  - The two-catch step could start the catches a mix block apart: the
    audio thread may mix between two calls. They now fire under
    `AudioServer.lock()`.
  - The stinger's "wind before" window counted ducked frames. Its first
    sound is a low boom that A-weighting discounts, so its onset was
    detected a few frames late, and the caught duck read -8.9 dB instead
    of -10. The window now ends where the cue is fired: -9.7.
  - The cost test's median is covered in the table above.
- **Time.** The stinger's take follows the tucked catch in the same
  director, and the 0.22 s before the stinger doubles as the catch's
  "the wind comes back" check. That saves the separate 0.75 s recording.
  The cost test runs 120 frames.
- **The make-up has to follow the duck.** This round's first version of
  the scream's speed-duck make-up was fixed when the call started. The
  headroom probe caught it: heavy play's belfry scene is entered straight
  from its dive, and a scream begun under the dive's duck played 6 dB
  loud once the duck released. It peaked at -2.08 dBFS, 0.6 dB under the
  limiter's ceiling. The make-up now follows the bus's duck. Over 30
  trials the final code reads -2.64 to -5.59 dBFS, and the round-3 code
  -2.64 to -5.58 in the same probe the same day. Mutant S03 puts the
  fixed make-up back, and the suite catches it.

Where a verifier probe still disagreed after round 4 (it passes since
round 5, see **Fix round 5**):
- **`r4x_experience.test_danger_and_scream_heard_while_fleeing_in_a_dive`**
  wants the hawk's scream over the wind in its 2k/4k band in a tucked
  2.6x dive. It reads +2.1 dB from 15 m and -0.3 dB from 45 m, at the
  wind's level, against its bar of > 0. Round 3 read -6.8 and -7.3. The
  scream is no longer ducked by speed, and its floor is -5.5 dB there.
  More would mean raising the far floor, or ducking the wind for a
  scream as the catch does. Both are mix changes this round did not
  make. The heart and drone carry the danger in that dive: +11.8 and
  +18.9 dB over the wind at 125/250 Hz. Every other round-4 probe passes:
  the bad frames, the successive screams (the same numbers as the suite),
  the seams, the hum, the moth, the 40 s soak (0 errors, peak -3.6 dBFS),
  and all four engineering probes.

### Fix round 3 (verifier findings)

Both round-3 verifiers failed round 2 on one major defect. Godot's
default air-absorption shelf was left on every `AudioStreamPlayer3D`,
and the call balance round 2 claimed held only in a model. They also
found seven minor issues. Each is fixed at its root and pinned by a
suite test. No threshold was loosened. Two measures were re-based,
justified under "More things round 3 turned up": the first-launch
statistic, and the menu-music range, which moved from dBFS RMS to LUFS
plus a relation to the glide. A mutation run on a private copy confirmed
the suite catches all 14 mutants: the 7 the round-3 verifier found
surviving and 7 of this round's fixes
(`artifacts/audio/fix_r3/mutants_summary.log`, `mutate.py`).

| Finding | Root cause and fix | Pinned by (result) |
|---|---|---|
| **Major:** calls 10-14 dB under their level at the unit distance on the mixer, a 27 dB small-bird spread at 25 m, the balance checked only on paper (both verifiers) | Godot's shelf depth is (1 - gain) x -24 dB with `volume_db` in the gain, and the loudness levelling lives in `volume_db`. Every 3D player now sets its shelf: calls and the bell from perceived distance (`air_absorption_db`, 0.04 dB/m above 5 kHz, at most 12), the whooshes none. `audibility()` became Godot's whole law (the fade to the reach and the air loss via a measured `AIR_SHARE` added). The swallow went up 0.5 dB | `test_calls_balance_holds_on_the_mixer`: every species rendered on the mixer at its unit distance (within 1.5 dB of `VOICE.loud`) and 25 m (within 1 dB of `audibility`: worst 0.7); wren..pigeon 4.9 dB (< 6), starling +1.5 (< 2). `AIR_SHARE` re-measured by the table test. Their probes now: spread 4.8 dB, 0.0 dB lost to the shelf at every species |
| Minor: the same shelf dulled the player's wingbeats (and the bell) | Same root; whooshes get no shelf, the bell a distance one. With the whoosh at its designed brightness a full flap was as loud as the catch crunch, so the whoosh came down 3 dB (`WHOOSH_DB` -10) | `test_wingbeat_render_side_strength_and_decay`: rendered centroid within 3-4% of the played clip's (≤ 10%). Their probe: centroid ratio 1.00 |
| Minor: ordinary play far under the menu music (glide at cruise 11.6 LU, slow glide 15.9 LU under it) | The glide is the wind alone, and AU1 holds the dive 12 dB over it. Cruise wind +2 dB (dive unchanged: 13.2-13.7 dB contrast), music -2 dB (+10, UI with it), the ambience duck from 0.55x (slow flight keeps its world) | `test_music_plays_in_menus_and_pause_not_in_flight`: the menu -29.7 LUFS (pinned -32..-27), a glide at cruise 6.9-7.0 LU under it (≤ 8). Their probe: glide 7.7 LU, slow glide 9.2, perched and flapping at the menu's level |
| Minor: the catch crunch 2.6 dB A over a tucked dive's wind | A flat 5 dB duck under the loudest wind in the game. The catch duck now follows the wind's level (`catch_duck_db`: -5 up to about 2x, -14 in a tucked 2.6x dive) and takes the calls and the ambience down with it | `test_catch_cuts_through_the_wind`: at 1.2x and in a tucked 2.6x dive the duck lands at once (-4.7 / -13.8 dB for -5 / -14), the crunch stands 19.2 / 9.3-9.7 dB A clear (≥ 6), the Calls and Ambience buses drop by the same duck at the onset and come back. Their probe: +10.5 dB A at 2.4x |
| Minor: seven claimed behaviours unpinned (surviving mutants M05, M09, M21, M29, M30, M38, M41) | Tests added | M05 calls dive duck: the catch test reads the Calls bus at 1.2x (0) and at 2.6x (5-6.5 dB down, a literal). M09 `TUCK_DB`: the tuck must be ≥ 3 dB louder A-weighted (4.2-4.3; with `TUCK_DB` 0 it reads 2.85-2.9). M21: the scheduler keeps the threatening hawk in reach, the ordinary one out. M29: in every state a bird whose call is due calls only in play, and the bell may start only in play. M30: `test_wind_follows_the_head` (head turned left, R - L 8.9 dB; straight within 1.1). M38: the danger test removes the predator and wants the danger bus 20 dB down 0.7 s later (25-30 dB). M41: every state checks both speed ducks hold only in play |
| Minor: builder files in the verifiers' probe folder, verifier evidence overwritten | The peaks probe moved to `tests/shots/audio_probes/peaks_test.gd`. This round their probes were run with their folders backed up and restored byte for byte; the outputs went to `artifacts/audio/fix_r3/verifier_probes/` | `diff -r` of `artifacts/audio/verify` against the backup: identical |
| Minor: doc figures from one run stated as floors | This doc quotes each test's threshold and the range over three full runs (`artifacts/audio/fix_r3/report_audio_run{1,2,3}.json`) | — |
| Minor: the suite at 57.7 s of its 60 s budget | The wind suite records one flight session per size in `before_all`. Wind and Body are separate buses, so the sweep also measures the buffet, the hum, the tuck and the head's pan, and the four tests read it. Directors start in play (no BOOT duck to wait out). Two voice pools render the call balance in two takes. Windows are trimmed to what their time constants need | 36 tests (34 in round 2) and 940 assertions (825) in 53.3-53.7 s over the final three runs, 11% under the budget |

More things round 3 turned up:
- **Heavy-play headroom.** Once the shelf was gone, heavy play reached
  -1.34 dBFS once in 10 trials. Tapping every bus at the peaks found two
  causes. A single loud call panned to one side peaks at -3.4 dBFS on
  the Calls bus, and two loud voices near the listener were never
  normalised, because the crowd rule counted voices. The crowd now
  follows the summed gain at the ear, and a cue ducks the world under
  it. The worst trial now reads -2.85 dBFS.
- **Timers and hitches in tests.** A SceneTree timer counts a frame's
  whole delta, even when created during that frame, while the director
  clamps its delta to 0.1 s. After a stretch of analysis on the main
  thread a "0.5 s" wait ended 0.15 s later in director time. Tests now
  let two frames pass first (`Fixture.past_hitch`). This is not a
  product issue: the game never blocks its own frame on analysis.
- **The first-launch check** pinned the worst frame of about 180 and
  failed once on a single preempted frame under load 10. It now pins the
  median (under 0.1 ms) and at most 2 frames over 0.5 ms. Main-thread
  cache writes, the regression it guards, would cost one slow frame per
  clip (9).
- **The menu-music range** was -34..-24 dBFS RMS on the loop's first
  1.5 s. Round 2 chose it from round 1's "very quiet at -36 dBFS". It is
  now -32..-27 LUFS (K-weighted, the loudness measure) plus the relation
  to the glide, because round 3 showed that the reference that matters is
  the game's own programme. At -29.7 LUFS (-34.2 dBFS RMS) the music is
  2 dB under round 2 and 1 dB over round 1.
- **The danger cue at threat 0.5** had fallen 0.2 dB under the 1.5x
  wind in the 125-250 Hz bands once the cruise wind came up. The drone
  now rises earlier, and the danger test records the wind at 1.5x
  alongside: +3.0-3.3 dB at 0.5, +10.5-10.8 at 1.

Where the verifiers' own probes still disagree:
- **`r3x_experience.test_reward_cues_cut_through_flight`** wants a catch
  to lift the whole SFX mix 4 dB A over the loudest 0.2 s before it, in a
  tucked dive too. It reads +0.0-0.1 there: the catch swaps 14 dB of
  roaring wind for a crunch that stands 9-10 dB A clear of what remains.
  That is contrast by ducking, the technique the verifier's own finding
  asked for ("a speed-dependent catch duck"). Its listed defect (crunch
  ≥ 6 dB A over the wind) passes in `r3x_cues` at +10.5. A 4 dB lift
  over a -22.7 dB A dive wind would need the crunch 6.5 dB louder, which
  would put heavy play back into the limiter. At cruise the lift is
  +17.6 dB A.
- **`r2x_experience.test_call_loudness_balance_at_equal_distance`**
  still stops on `VOICE["db"]`, which round 2 replaced. The mixer test
  above checks the same balance on the real mix.

### Fix round 2 (verifier findings)

(Figures in this section are as of round 2; round 3 changed some of the
levels, see above.)

Two verifiers reviewed round 1: the experience verifier failed it on three
major defects, the engineering verifier passed it with seven minor ones.
Each was fixed at its root and is pinned by a suite test; no threshold was
loosened. Their probes (`tests/probes/audio/r2x_experience_test.gd`,
`probe_r2_eng_test.gd`) were re-run on the final code: all 5 engineering
probes pass (tempo on literal bpm, danger silenced when the predator
leaves, out of the tree and back, updraft hum, Calls bus not leaking), and
8 of 9 experience probes pass. The ninth,
`test_call_loudness_balance_at_equal_distance`, reads `VOICE["db"]`,
which the loudness levelling replaced (`VOICE.loud` plus
`CALL_LOUDNESS`); `audio_calls_test.test_calls_are_balanced_by_loudness`
checks the same balance with Godot's full law. Every round-1 probe passes
too (`artifacts/audio/fix_r2/verifier_probes_rerun.log`,
`r2x_probes_rerun.log`, `r2eng_probes_rerun.log`).

| Finding | Root cause and fix | Pinned by (result) |
|---|---|---|
| **Major:** the church bell was the loudest sound in the game near the church (+1 dBFS peak at 8 m) and drove the limiter | `max_db` was left at Godot's +3 dB default, so inside 30 m the bell played at +3 dB. Now capped at -8 dB within 20 perceived m, distances scaled by world_scale like the calls, ducked with the ambience in flight; `toll()` forces a toll, and the max-load and heavy-play tests toll it | `test_church_bell_is_ambience` (stroke at 8 m -9.7 dBFS peak, < -8; sparrow scale 18.5 dB quieter at 30 m; -16.2 dB at cruise), heavy play "belfry" scene; the verifier's probe: -9.5 / -12.6 / -14.9 dBFS peaks at 8 / 30 / 80 m |
| **Major:** the wind (the main speed cue) sat 2-14 dB under the ambience beds near the ground at cruise | The beds had no relation to speed and were unbalanced (the meadow 12 dB over the village to the ear). Beds levelled to one loudness (-38 dB A) and ducked by speed (45 dB/decade from 0.4x cruise, -17.9 dB at cruise, 24 dB max); perched, the zone is heard in full | `test_wind_stands_above_the_ambience_at_cruise`: 5 zones × sparrow and eagle, wind ≥ 6 dB A over the bed (worst 10.3) and ≥ 2 dB in each band it carries (worst 4.7); the verifier's probe: margins 8.9-14.2 dB A at cruise |
| **Major:** a stooping hawk's scream was dropped for a sparrow-sized player, and the failed attempt started the 5 s cooldown | The reach cut (300 perceived m = 42 world m at world_scale 0.141) applied to the threat too. Threat and stoop-at-player screams are urgent: no reach cut, a floor 6 dB under the unit level, growing as the hawk closes; the cooldown starts only on success | `test_small_player_hears_the_predator_scream_from_afar`: at sparrow scale a hawk 65 m away screams, 17.4 dB over the cruise wind (A), +7.8 dB by 12 m; a failed attempt leaves no cooldown; the verifier's probe passes at 20/35/50/65 m |
| Minor: synthesized starling whistles 7-11 dB over the recorded songbirds | Clips were levelled by peak. Now by measured A-weighted loudness (`CALL_LOUDNESS`, re-measured by the suite) to `VOICE.loud` | `test_calls_are_balanced_by_loudness`: wren..pigeon within 4.1 dB at 25 m (< 6), starling +0.7 dB over the wren (< 2), crows/gulls and raptors above |
| Minor: two quick catches could reach the limiter ceiling (-1.17 dBFS) | Stacked crunches summed at full level. A repeat within 0.25 s plays 6 dB lower; calls dip up to 6 dB in a dive (the other contributor, found by tapping every bus at the peaks) | the heavy-play test has two catches 50 ms apart in both scenes; 10 trials -2.7 to -4.7 dBFS; the verifier's probe -4.2 to -5.3 |
| Minor: menu music very quiet at the defaults (-36 dBFS), select 18 dB over it | Music +12 dB make-up (was +9; headroom measured on the decoded loop); UI sounds each at a measured level | music test: -32.4 dBFS RMS at the output (1 s window; -30 over the loop); select/open/back/confirm +6.6-6.9 dB A over the music; every UI peak ≤ -3 dBFS |
| Minor: director broken after a re-parent (a SCRIPT ERROR each frame) and its crowd gain leaking to the next director | The bank was released on `_exit_tree` and Events stayed connected. The bank now lives as long as the director (released on PREDELETE), Events connect on enter and disconnect on exit, the mix is restored on re-entry; CallVoices resets the Calls bus on exit and writes it on its first frame | `test_director_leaves_the_tree_and_comes_back` (0 errors out and back in, wind resumes, Calls bus 0 dB after leaving and under a new director) |
| Minor: heartbeat tempo and dub checked against the code under test | Literal ranges | danger test: 73 bpm at 0.25 (60-85), 111 bpm at 1 (100-125), ratio 1.52 (≥ 1.35), dub 0.18 s (0.15-0.24) |
| Minor: the updraft hum had no test | Added | `test_updraft_hum_follows_lift` (silent / -50 / -35 dBFS at 0 / 1 / 4 m/s, centroid 143 → 168 Hz) |
| Minor: tests persisted Settings (the shared `settings.cfg` held music 0) | Tests restored "what they found" | Every director test starts and ends on the shipped defaults (`Fixture.restore_default_settings`), so a killed run is healed by the next; the file now holds the defaults |
| Minor: dead code (`AudioSynth.sine_sweep`, `AudioBank.cache_path`) and the obsolete `.res` cache probe | Removed; the probe retired in `audio_probe_test.gd` with a note | — |
| Minor: reported numbers were best runs | This doc quotes ranges over runs and the thresholds the tests pin | — |

More things the round-2 work turned up:
- `AudioAnalysis.loudness_aw` (and the verifier's `_aw_level`, which it
  mirrored) averaged a buffer's first windows over fewer frames, so a
  sound at the start of a recording was read as loud as its first 23 ms:
  up to 10 dB high for a 43 ms UI click. Every window now spans its full
  length, frames before the buffer counting as silence. By this corrected
  measure the round-1 select sound sat about 10 dB over the music, not
  18; the verifier's probe still reads +14.4 dB for it for that reason.
- `AmbienceZones.settle()` (tests; a teleport may use it) first jumped the
  gains without writing the players' volumes; the wind test caught it.
- The catch-duck test read 3.6-3.9 dB for the designed 5 dB duck, 0.1 dB
  from its lower bound: its 0.1 s window began with the one or two 23 ms
  blocks the mixer had already mixed before the catch. The window now
  starts after them (4.7-5.1 dB over 4 runs); the 3.5-6.5 dB bounds are
  unchanged.

The suite grew from 28 to 34 tests and runs in about 57 s of its 60 s
budget (56.6-57.8 s over this round's full runs): redundant waits were cut
(a fresh stage instead of waiting for a release, shorter heavy-play and
cost loops), the call loudness comes from the feature pass's own STFT, and
the bed spectra are computed on the worker pool.

### Fix round 1 (verifier findings)

Two verifiers reviewed the first build. Every finding was fixed at its
root, and each fix is pinned by a test in the suite. Their own probes
(`tests/probes/audio/`) were re-run against the fixed code: all 9 in
`probe_director_test.gd`, plus the removal, queued-steal and CAUGHT-duck
probes in `audio_probe_test.gd`, pass with no `!is_inside_tree()` or
script errors in the log. Two of their probes no longer apply:
`test_cache_matches_fresh_synthesis` loads the old `.res` cache format,
and `test_crowd_gain_settles_without_per_frame_writes` re-implements the
old write condition in the probe itself. The suite now covers both.

| Finding | Fix | Pinned by |
|---|---|---|
| **Major:** voices broke when their bird left mid-call (engine ERRORs, call jumping to the origin, moth loop never stopping, SCRIPT ERROR at `call_voices.gd:404`) | `CallVoices.forget` (on `Events.bird_removed`, fired from `_exit_tree` while the bird is still valid) lets go of the bird's voices, which fade where it was, and drops its queued calls; `_present()` guards every access (a freed Object == null in 4.7); a separate `follows` flag; queued requests hold an instance id and are re-validated; `playing()` lists only live birds | `test_voices_let_go_of_birds_that_leave` (0 errors via Logger) |
| **Major:** clip tests measured a disk cache keyed by a hand-bumped version | Content-addressed cache key (hash of the design sources + engine version); a test proves the design code uses no unhashed project class and that 9 clips from every family are bit-identical to a fresh synthesis | `audio_bank_test.gd` |
| Voice cap and buffet size scaling derived from the code under test | Literal 8; buffet pinned on measured rates (sparrow 12-16 Hz, eagle 8-12 Hz and ≤ 0.8x sparrow) | pooled and stall tests |
| CAUGHT ambience duck never applied (and MENU <-> PAUSED) | SFX and Ambience ducks ramp to their own targets | `test_every_state_lands_on_its_mix` |
| Calls bus rewritten every frame | Crowd gain snaps when within 0.02 dB and is written only in 0.05 dB steps or when it lands | pooled test: 59 writes over a release, 0 once settled |
| First-launch cache saves on the main thread (up to 4.7 ms each) | Cache written and read on the worker (plain PCM, atomic rename) | first-launch test: 0.03-0.07 ms/frame on the main thread over runs (< 0.5) |
| Heartbeat sped up by resampling (+10.6 semitones) | Scheduled beats in an `AudioStreamGenerator` at a fixed pitch, lub-dub spacing shortening like a real heart | danger test: pitch, tempo and rhythm on the mix |
| `mix_levels.json` empty after a partial export | `--only` merges into the file; full export rerun | `artifacts/audio/mix_levels.json` (69 clips) |
| Plot/sheet layout (axis titles over legends, labels over subtitles, half-empty sheets) | Margins from the legend height; the y-axis title on its own line; sheets packed by row width, clips sorted by name | the images in `artifacts/audio/` |
| `test_event_cues` checked only the signal | Every cue measured on the mix against clip peak + `LEVEL` | `test_event_cues` |
| Docs/code nits (bus/effect/player counts, header API, dead `_update_danger` logic, shadowed variables) | Corrected; the dead line is now a real safety net (a predator that leaves the world silences the danger cue) | this doc |
| Suite at 56.5 s of a 60 s budget | Call features computed on the worker pool (3.8 s → 0.75 s), waits cut to what the ramps need | 28 tests in about 57 s |
| Listening-pass concern: 5-6 s wind loops may be heard repeating | 12 s and 7 s loops, gust cycles with no common factor | spectrograms `wind_body.png`, `wind_edge.png` |

**Headroom.** The fixed-pitch heartbeat first broke the heavy-play test
(pre-limiter peak -0.1 dBFS). A 58 Hz lub is longer than the old
pitched-up one, so it lined up with the catch crunch, the feather puff
and both wingbeats. Tapping every bus at the peak sample showed the
crunch's needle grain (-7 dBFS) sitting on a dive-wind noise peak. The
fix manages headroom by shape at equal loudness, not by turning things
down:
- the lower-crest heart;
- the softened crunch at -3 dB;
- the tamed wind noise peaks;
- the puff 80 ms after the bite;
- an instant catch duck.

Heavy play then peaked at -4.2 dBFS in that run (-2.6 to -3.4 dBFS in the
engineering verifier's 10 reruns); round 2 added two quick catches and
the belfry scene, see **Loudness hierarchy** for today's range.

## How each criterion is verified

All headless tests: 43 tests and 1100 assertions over five suites. Round
5's final three full runs took 54.2-54.7 s at machine load 7, against
the 60 s budget (round 4: 60.8-63.0 s at load 18-32; the round-5 verifiers
60.7-68.8 s, the upper figure with a cold cache). The headless mixer runs
in real time, so most of the suite is waiting on audio; this round records
the danger cue alongside the wind session, folds the pause checks into the
menu-music test and synthesizes on worker threads (see **Fix round 5**). A
fresh sandbox (its own user://) or the first run after a design change
adds about 2 s of synthesis.

```
tools/gd.sh audio --headless res://tests/runner.tscn -- --suite=audio
```

**Reports.** `artifacts/tests/report_audio.json`. Round 5's three final
runs are kept as `artifacts/audio/fix_r5/report_audio_run{1,2,3}.json`,
with their logs as `suite_run{1,2,3}.log` (earlier rounds' in `fix_r4/`,
`fix_r3/`). Measurements for the plots go to
`artifacts/audio/measurements.json`, renders to `artifacts/audio/renders/`.

**The fixture** (`tests/unit/audio/audio_fixture.gd`) uses only core
contracts:
- a mock player Bird with scripted `telemetry()`, mock NPC Birds and a
  mock World with landmarks and a settable ground height;
- the Ecosystem's sky as AI.md documents it (`sky_layout`, `add_sky`: 60
  NPCs, mostly 60-110 m out, the round-5 verifier's layout);
- in-memory volume sliders (`MemorySettings`), which every director it
  builds reads instead of the Settings autoload;
- a current Camera3D as the ears;
- capture taps on the buses (of any length), temporary per-voice tap buses
  and multi-tap recording.

The headless Dummy driver mixes in real time, so these are the engine's
real mixes. Most values repeat to the hundredth of a dB run to run.

**Test hygiene.**
- `audio_error_log.gd` (Godot's `Logger` API) lets a test assert that no
  engine or script error was logged.
- No suite test writes the Settings autoload or `user://settings.cfg`:
  directors read the fixture's in-memory store. The settings test pins
  that the autoload's values and the file are unchanged.
- Director tests start their director in play. The test that pauses the
  game builds its stage under a PAUSABLE parent, as in the game.
- After heavy analysis a test lets two frames pass before a timed wait
  (`Fixture.past_hitch`); a loop that writes the engine thousands of times
  yields frames.

**Literal thresholds.** Thresholds come from the brief. They are written
as literals wherever the code under test could otherwise set its own bar:
- the voice limit is 8, the near-field ceiling 6 dB (the calls model);
- the buffet rates and the heart's tempo and systole are pinned on
  measured ranges, not on `flutter_pitch()` or `heart_rate()`;
- the calls' dive duck is about 6 dB; the threat's voice in a tucked full
  dive is lifted 10 dB (6 + 4);
- the crowd rule is checked on the Calls bus against the test's own copy
  of Godot's distance law;
- the caught and fanfare ducks (10 and 6 dB), every reward cue at least
  6 dB A over the wind it lands in, a new threat call from 10 m at least
  3 dB over one from 60 m, two catches in one frame +2.5 to +4.5 dB over
  one;
- the bad-input recovery: 1.5 dB after 0.5 s;
- the danger over the wind (1 and 6 dB), every call's ending (20 dB under
  its loudest), the air shelf at 150 m (5-7 dB), the bell's fall from 20
  to 30 m (3-4.5 dB), the cost budget (1 ms on a Quest: 0.25 ms here).

Round 5's mutation run (`artifacts/audio/fix_r5/mutants_summary.log`)
puts back each of this round's defects (the perceived-distance law for
the calls and the bell, round 4's call cuts, the starlings' ending), takes
out each of its fixes (the call floor, the drone make-up, the threat's
lift, its speed-duck make-up, its rising floor) and repeats the round-5
engineering verifier's survivors (R1 hands swapped, R2 rig scale ignored,
R3 silent layers never paused, R4 no air absorption, R5 the scheduler
visiting every bird, R7 the director pausable): all 15 are caught, and the
unmutated copy passes. Numbers are ranges over round 5's three final runs.

| Criterion | Test (tests/unit/audio/) | Result |
|---|---|---|
| **AU1** wind RMS monotonic with airspeed | `audio_wind_test.test_wind_rms_rises_strictly_with_airspeed`: one flight session per size (`before_all`), 8 speeds (sparrow) and 3 (eagle) from 0.15x to 2.6x cruise; Wind bus RMS must rise ≥ 0.5 dB each step | sparrow -66.3..-66.4 → -21.8..-22.0 dBFS, eagle -67.0 → -21.7..-21.8 dBFS, strictly rising |
| AU1 dive >> glide | same test: tucked 2.6x dive vs glide at cruise, ≥ 12 dB | **+13.2 dB** (-21.3..-21.4 vs -34.5 dBFS) |
| AU1 tuck brighter/thinner | `test_tuck_is_brighter_and_thinner`: the session's 2.6x cruise (the dive's own steps), spread vs tucked; centroid ≥ 1.5x, 85% roll-off ≥ 1.4x, < 400 Hz share < 0.35x, > 3 kHz share ≥ 2x, A-weighted level ≥ +3 dB | centroid 940-988 → **3706-3728 Hz**, roll-off 2.1-2.2 → 6.8 kHz, low share 59-62% → **5.2-6.0%**, high share 10% → 52%, **+4.1-4.3 dB A** (round 4 judged it at 2.2x: +4.3) |
| AU1 wind follows the head | `test_wind_follows_the_head`: head straight (sparrow) within 1.5 dB L/R; head turned 90° left (eagle's session) the right ear ≥ 4 dB louder | straight within 0.3 dB, turned **+8.4 dB** |
| AU1 stall periodic at a buffet rate | `test_stall_buffets_periodically`: Body bus envelope autocorrelation; rate within 6% of the design, strength > 0.6; measured sparrow 12-16 Hz, eagle 8-12 Hz and ≤ 0.8x the sparrow; silent (< -70 dBFS) without a stall | sparrow **13.8-13.9 Hz** (0.82-0.86), eagle **10.2 Hz** (0.86); unstalled silent |
| AU1 updraft hum (brief deliverable) | `test_updraft_hum_follows_lift`: slow flight; silent (< -70) without lift, > -60 dBFS at 1 m/s, ≥ 6 dB louder and centroid ≥ 1.03x at 4 m/s | -inf / **-50.0 / -34.6 dBFS**, centroid 143 → 175 Hz |
| AU1 no clipping at maximum load | `test_max_load_never_clips`: dive + tuck + stall + updraft + threat 1, both wings flapping every 0.1 s, catches, fanfare, stinger, bumps, 11 NPCs at 1.5 m all calling, every ambience bed, the church bell tolling 3 m away, UI clicks; Master tapped before and after the limiter (1 s) | output peak **-1.50 dBFS** (< -1), limiter costs 1.1-1.4 dB RMS (< 3) at this absurd pile-up (pre-limiter +1.6..+2.8 dBFS over this round's runs) |
| AU1 gain staging (extra) | `test_heavy_play_needs_no_limiting`: (dive) a tucked dive by a forest and lake, hard flapping, a hawk at threat 0.8, three calls 10-25 m, two catches 50 ms apart; (belfry) slow flight 10 m from the tolling bell, the same events; pre-limiter peak < -1.5 dBFS in both | suite runs **-3.8 (dive), -4.4..-4.9 dBFS (belfry)**; the headroom probe with a spread 2.6x dive added: worst -2.22 dBFS over 15 trials (see **Headroom**) |
| AU1 wind over the ambience (speed cue) | `test_wind_stands_above_the_ambience_at_cruise`: sparrow and eagle at cruise 4 m up in forest, lake, village, meadow and canyon zones; the wind (mixer) vs each bed (whole-loop spectrum at its player's gain; the lake bed's recording checked against its clip within 1.5 dB); wind ≥ bed + 6 dB A-weighted and ≥ bed + 2 dB in every octave band the wind carries | worst **+10.2-10.4 dB A**, worst band **+4.0-4.4 dB** |
| **AU2** species distinct | `audio_calls_test.test_species_are_distinct`: for all 45 species pairs, the medians differ by ≥ 1/4 octave in dominant pitch or spectral centroid, or ≥ 1/2 octave in note rate or longest note; every clip is nearest (normalised feature space) to its own species | all 45 pairs distinct (closest: sparrow/swallow, 1.6x the threshold, by pitch); nearest-species accuracy **100%** (with the re-cut gulls) |
| AU2 in character | `test_calls_in_character`: literature ranges per species (header of the test file), e.g. coo 250-800 Hz and tonality > 0.6; caw 0.5-2 kHz, harmonic-rich and not a pure tone; gull 0.7-3.2 kHz in a laughing series of 3-10 notes/s; screech 2-4.5 kHz with falling pitch; moth RMS < -24 dBFS with 25-70 Hz wingbeat AM | all pass (moth flutter at 41.9 Hz) |
| AU2 balanced by loudness, the model | `test_calls_are_balanced_by_loudness`: `CALL_LOUDNESS` within 0.3 dB and `AIR_SHARE` within 0.05 of every clip's measurement; every clip at its species' level at the unit distance (0.5 dB), a gain-capped quieter call within 4 dB; at 25 m wren..pigeon within 6 dB, starling ≤ loudest recorded songbird + 2 dB, crows/gulls ≥ 3 dB over them, raptors ≥ 1 dB over crows/gulls | tables fresh; `wren_3` capped at -3.7 dB |
| **AU2 balanced by loudness, on the mixer** | `test_calls_balance_holds_on_the_mixer`: every species' loudest clip rendered through three voice pools at its unit distance and at 25 m, 19 voices on their own tap buses in one take; each within 1.5 dB of `VOICE.loud` at the unit distance, within 1 dB of `audibility()` at both; the same balance limits as above | table in **NPC calls**; spread **4.9 dB**, starling under the recorded songbirds + 2, crow/gull +10, raptors on top |
| AU2 recordings clean, calls end naturally | `test_recordings_are_trimmed_and_levelled`: mono 32 kHz 16-bit, peak -3.0 ± 0.1 dBFS, sound within 60 ms, < 150 ms trailing silence, fades, no DC, 0.3-3.5 s; **every call (recorded or synthesized) ends ≥ 20 dB under its loudest 50 ms in the 50 ms before its end fade** (round 5). `test_synth_clips_are_clean`: every synthesized clip peaks at -1 to -13 dBFS, loops are seamless, one-shots end silent | all pass; worst ending **-24.9 dB** (sparrow_1); the re-cut calls -28.5 to -42.2; starlings silent (`plots/call_endings.png`) |
| **AU2 a living sky** (brief: "3D calls per species", DESIGN: "a big, alive sky") | `audio_wind_test.test_living_sky_is_heard_over_the_wind` (round 5): the Ecosystem's sky simulated at the sparrow's (15 s), pigeon's and eagle's (5 s) world scale, each call placed at the ear by Godot's law on its voice's own settings and heard when over the cruise wind in its own octave: a call heard in every 5 s, ≤ 25% cut short, ≥ 70% of the calls started heard; on the mixer, the sparrow's session through the same sky up to cruise: calls start, the loudest over the cruise wind in its octave | **16 / 18 / 14** calls heard per 5 s at sparrow size (48 of 60 started), 16 of 19 in 5 s at the others; **9%** cut short; mixer: 13 calls in 2.6 s, loudest **-31.2 dB A** against a -42.9 dB A wind, **+31 dB** in its octave (`plots/living_sky.png`) |
| **AU3** wingbeat transient | `audio_director_test.test_wingbeat_clips_are_transients` (all 9 clips: < 10% of peak within 300 ms of onset, peak within 80 ms) and `test_wingbeat_render_side_strength_and_decay` (the mixer's Body bus after `Events.player_flapped` left, right, soft and both wings; the rendered centroid within 10% of the played clip's at its pitch) | worst clip decay **0.19 s**; rendered decays < 0.3 s; left flap 12.0 dB left of right (bounded 6-20 dB); a 0.3-strength flap 6.2 dB quieter (≥ 6); both wings centred, -32.2 dB in each ear, +2.0 dB total over a one-wing flap (≤ 3); centroid 0.96-0.98x the clip's |
| AU3 on the VR rig | `test_vr_rig_sets_the_scale_and_the_hands` (round 5): an XROrigin3D in `player_rig` (world_scale 0.14) with LeftHand/RightHand | the voices take the rig's scale over telemetry's; each flap plays at its own hand, both wings at both; a change of scale followed |
| **AU4** danger scales with threat | `audio_wind_test.test_danger_cue_scales_with_threat` (the Danger bus recorded without a break beside the sparrow's session): RMS over one beat period at threat 0, 0.25 … 1.0 where the drone's make-up is 0, silent at 0, +1 dB or more per step, ≥ 15 dB from 0.25 to 1; tempo from lub-dub onsets on literal ranges (60-85 bpm at 0.25, 100-125 at 1, ratio ≥ 1.35), the strongest 40-150 Hz partial over two whole beats < 1 semitone apart, the dub 0.15-0.24 s after the lub and the pause ≥ 1.5x that; the danger over the wind at 125/250 Hz ≥ 1 dB at threat 0.5 at 1.5x and in a spread 2.6x dive, ≥ 6 at 1 in that dive. `audio_director_test.test_danger_falls_silent_when_its_predator_leaves`: 20 dB down within 0.7 s | **-inf, -39.9, -26.4..-26.5, -22.4..-22.8, -19.7..-20.1 dBFS**; **73 → 111 bpm**; partial 59.6 / 61.7-62.5 Hz (0.6-0.8 semitones); lub→dub 0.18-0.20 s, dub→lub 0.32-0.36 s; over the wind **+5.2-5.3 dB** at 1.5x (0.5), **+3.1-4.0 / +8.3-8.4 dB** in the spread dive (0.5 / 1); -20.5 → **-53.8 to -54.5 dBFS** 0.5 s after the predator left (`plots/danger.png`, `plots/danger_over_wind.png`) |
| AU4 predator scream | `test_predator_screams_when_threat_turns_serious` (one 3D scream at the 0.6 crossing, cooldown), `test_small_player_hears_the_predator_scream_from_afar` (world_scale 0.141: an ordinary hawk 50 m away calls, one 350 m away is out of reach; the threatening hawk 65 m away screams, ≥ -6.5 dB relative to its unit level, ≥ 10 dB A over the cruise wind, ≥ 6 dB louder by 12 m; the scheduler keeps it in reach; an attempt that cannot sound leaves no cooldown) and `test_successive_screams_grow_as_the_predator_closes` (new calls from 60/40/20/10/5 m each louder than the last until a full voice, never quieter, 10 m ≥ 3 dB over 60 m, 60 m ≥ -6.5; in a tucked 2.6x dive the voice lifted 10 dB, the far call louder than at cruise and no louder than a full voice under the dive's duck, from 2 m the same; pulling out never jumps it up) | 65 m: **19.8-19.9 dB A over the wind**, **+8.9 dB** at 12 m; new calls **-6.0 / -5.2 / +0.2 / +1.5 (a full voice) / +1.7 (a full voice)**; dive at 60 m **-6.0 dB (cruise -7.8)**, lift **10.0 dB** |
| **AU5** voice limiting / pooling | `test_voices_are_pooled_and_capped` (30 birds requesting calls every 10 frames for 120 frames, then two crows at arm's length), `test_voices_go_to_the_most_relevant_birds` (24 birds + a far threatening hawk, requested farthest first), `test_scheduler_calls_respect_reach_and_scale` | at most **8** voices (a literal), no players created or freed, far voices stolen; crowd target = the summed-gain rule within 0.2 dB, -6.75 dB with 8 near voices; two crows 4 m away bring the bus to -2.66..-2.68 dB (model -2.84, ≤ -2); 76 bus writes over a whole release and **0 once settled**; the nearest bird and the hawk 120 m away have voices; the same bird ranks the same at world_scale 1 and 0.13; a call 150 m away with a **6.0 dB** air shelf |
| AU5 birds leaving mid-call | `test_voices_let_go_of_birds_that_leave` | voices let go at once; the call stays where the hawk was (0 m jump); calls and loops stop within 0.22 s; queued calls never start; **0 engine or script errors** |
| AU5 director leaving the tree | `test_director_leaves_the_tree_and_comes_back`: events while out of the tree, re-added, then a crowd and removal | **0 errors** out and back; Calls bus 0 dB after it leaves and under a new director |
| AU5 cost < 1 ms/frame | `test_director_cost_under_load`: 120 frames, 60 birds, 40 landmarks, the flight changing every frame, flaps and threats; wall-clock mean < 1 ms (the brief); one frame visits ceil(n / 12) birds; tight loop (CPU-bound, the flight changing on every call, best of 5 × 200 calls, a frame between blocks) < 0.25 ms (1 ms on a Quest 3-4x slower); wingbeat event < 0.1 ms | mean **0.13-0.17 ms**, median 0.12-0.16, p95 0.18-0.25 (recorded); **6 of 61** birds a frame; tight loop **0.077-0.082 ms**; a wingbeat event 0.014-0.019 ms |
| AU5 silent layers cost no mixing | `test_silent_layers_cost_no_mixing` (round 5) | at cruise with nothing to play the buffet, hum, heart and drone paused; 100 m up every bed paused or never started; the wind playing |
| AU5 first launch | `audio_bank_test.test_first_launch_is_off_the_main_thread_and_matches_the_cache` | 150-164 frames pass during 1.0-1.1 s of synthesis (9 clips, on worker threads); main-thread bank work median 0.006-0.010 ms, worst 0.04-0.09 ms, 0 frames over 0.5 ms (≤ 2 allowed); start 8.8-28 ms (< 50) |
| Cache integrity | same test + `test_cache_key_follows_every_design_source` | the key is the hash of the 3 design sources; 9 clips from every design family bit-identical to a fresh synthesis; a truncated file is rebuilt; old folders pruned; 0 errors |
| **AU6** pause/menu ducking, music, UI, Settings on the mix | `test_menu_music_and_the_pause_mix` (under a pausable parent; menu → flight → pause): menu music at the output -32..-27 LUFS; UI sounds 3-12 dB A over it, peaks ≤ -3 dBFS; in flight the music fades out over about 1.5 s and pauses, a glide at cruise within 8 LU under the menu, `sfx_volume` 0.5 is 12.04 ± 0.3 dB quieter on the mix; paused from fast flight the music comes back, gameplay (SFX bus + fader, against the Wind bus) ≥ 18 dB down and muffled (centroid < 0.8x the wind it carries), a UI sound plays, the UI bus untouched. `test_every_state_lands_on_its_mix` (flying at 2x cruise with a bird whose call is due) | menu **-29.7 LUFS**, glide **-36.6..-36.8 LUFS: 6.9-7.0 LU under**; select/open/back/confirm **+6.0-6.8 dB A** over the music, click +3.1-4.5, hover -1.6; the music pauses 1.50-1.51 s into flight; `sfx_volume` 0.5 **12.04 dB** quieter; paused: gameplay **-21.1..-21.2 dB**, centroid **183-193 Hz** against the wind's 418-448; every state lands on its SFX and Ambience duck within 0.05 dB; both speed ducks hold only in play; a due call starts only in play |
| AU6 Settings volumes | `test_settings_volumes_drive_the_buses` (every key at 1, 0.5, 0.25 → 40·log10(v) ± 0.05 dB, 0 mutes, read from the director's `settings` store; the Settings autoload and `user://settings.cfg` untouched); a NaN or corrupt volume reads as its default (`audio_input_test`) | autoload and file unchanged |
| **AU7** WAV + spectrogram per clip | `tools/gd.sh audio --headless res://tests/shots/audio_clips.tscn` (~90 s; `-- --only=<group>` redoes one group) | 69 WAVs in `artifacts/audio/clips/`, a PNG each in `artifacts/audio/spectrograms/` (+13 `render_*`), contact sheets `artifacts/audio/sheet_*.png`, `mix_levels.json` (clips, cues, UI levels, beds, bell); calls re-exported in round 5 |
| Reward and failure cues over the wind | `test_reward_and_failure_cues_cut_through_the_wind`: the catch at 1.2x and in a tucked 2.6x dive (the wind's duck from the crunch's onset, A-weighted, within 1.5 dB of `catch_duck_db`, deeper than 10 dB in the dive; the crunch (SFX - Wind) ≥ 6 dB A over the wind in the same 0.2 s; the wind, Calls and Ambience back after); the caught stinger and the fanfare in the tucked dive (their wind ducks 10 and 6 dB ± 1.5, literal; ≥ 6 dB A over the wind); every cue steps the Calls and Ambience buses back by its duck at its onset; the calls' dive duck 5-6.5 dB at 2.6x, 0 at 1.2x | catch duck **-4.9..-5.0 / -13.8..-14.0 dB** (designed -5 / -14), crunch **+19.4 / +9.7-9.9 dB A**; stinger duck **-9.9..-10.1 dB**, **+9.4-9.5 dB A**; fanfare duck **-6.0..-6.1 dB**, **+9.2 dB A**; buses -5 / -14 / -10 / -6 at the onsets; the dive wind back within 0.3 dB |
| Events cues, ambience zones, bell | `test_event_cues` (each cue alone on the SFX bus, the bus drained to silence first, peak within ±2 dB of clip peak + `LEVEL`; two catches in one frame +2.5..+4.5 dB over one), `test_ambience_zones_follow_landmarks_and_altitude`, `test_church_bell_is_ambience` | cues within 0.2 dB of their design (±2 allowed); two catches **+3.53 dB**; zones full inside their landmarks and up to 12 m, gone 150 m up; bell 8 m from the tower -9.7 dBFS peak (< -8), 30 m away -11.7 dB at every player size (world metres), -25 dB at cruise |
| **Bad input** (round 4) | `audio_input_test`: `test_pure_functions_are_total` (190 cases); `test_bad_inputs_recover_within_half_a_second` (frame-stepped: 24 inputs × 5 bad values for 4 frames; everything handed to the engine finite at every frame; every layer, fader, filter and duck within 1.5 dB of its level before, 0.5 s later; then every smoothed state set to NaN at once, the same bar); `test_bad_frames_on_the_mixer` (a burst of every bad value at once on the real mixer: no non-finite sample; wind, buffet, danger within 3 dB 0.5 s later, ambience within 10) | 120 cases, **worst 1.34 dB**; poisoned state back within **0.02-0.05 dB**; mixer: buffet -40.4..-40.5 → -39.7..-40.3, danger -19.8..-19.9 → -20.3..-20.4 dBFS, 0 non-finite samples, 0 engine errors (`plots/bad_input_recovery.png`) |

Plots (reviewed by eye) come from the tests' measurements:

```
tools/gd.sh audio --headless res://tests/shots/audio_plots.tscn
```

Dev scene: a scripted 40 s tour that touches every sound, with a live HUD
(layer levels, zones, speed ducks, voices, pause duck, cost, per-bus peak
meters). It quits cleanly through `AudioDirector.shutdown()`. Without
`--tour` it is manual: W/S speed, T tuck, X stall, U updraft, F/Q/E flap,
C catch, G caught, L tier-up, 1-5 threat, P pause, M menu.

```
tools/gd.sh audio --rendering-method forward_plus --resolution 1280x720 res://scenes/dev/audio_dev.tscn -- --tour --shots=4,8,12,16,20,28,32,36.5 --seconds=39.5
```

Builder probes in `tests/shots/audio_probes/` (not part of the suite):
the headroom probe (5 trials each of the two heavy-play scenes and, since
round 5, a spread 2.6x dive; every bus tapped) and the round-3 calibration
measurements (catch margins by
speed, programme loudness by state, the menu loop's profile, the catch
cluster's peaks):

```
tools/gd.sh audio --headless res://tests/runner.tscn -- --dir=res://tests/shots/audio_probes --suite=peaks
tools/gd.sh audio --headless res://tests/runner.tscn -- --dir=res://tests/shots/audio_probes --suite=explore
```

Rebuilding the shipped calls from the candidates (dev only, macOS):

```
scripts/audio/tools/decode_candidates.sh /tmp/soaring_dec
tools/gd.sh audio --headless res://scenes/dev/audio_survey.tscn -- --in=/tmp/soaring_dec [--only=swallow --from=8 --max=6]
tools/gd.sh audio --headless res://scenes/dev/audio_call_prep.tscn -- --in=/tmp/soaring_dec [--only=crow]
```

After re-cutting a call, run `audio_calls_test` and paste the tables it
prints into `CallVoices.CALL_LOUDNESS` and `CallVoices.AIR_SHARE`.

## How the recordings were chosen


The survey (`artifacts/audio/survey/*.png`) drew a spectrogram of every
candidate. Snippets were cut where the spectrogram shows clean calls, then
`call_prep.gd` band-limits each to the species' voice (24 dB/oct),
applies spectral subtraction against a noise profile measured within ±4 s
of the snippet (Rayleigh-corrected: a percentile of the magnitudes
underestimates noise power by 3.5x), trims (start at -30 dB, end at
-40 dB of the peak), fades, and peak-normalises to -3 dBFS
(`artifacts/audio/prep/*.png`, `_calls_sheet.png`, `prep.json`). Choices
made by measurement:
- **Crow = Yellowstone raven.** The American crow recordings are
  reverberant: their caws measured nearer the eagle yelps than the ravens'
  dry "kraa".
- **Hawk.** The red-shouldered hawk's "kee-ah" was dropped (it measured as
  an eagle yelp or a starling whistle); the hawk is the red-tailed screech
  in three cuts.
- **Swallow.** Snippets were re-cut after the first one turned out to be a
  falling whistle, not a twitter.
- **Starling = synthesized whistles.** The only starling file is flock
  wing roar. A rattle variant was tried and removed: it measured closest
  to the wren's trill.
- **Pigeon = dove coo.** No clean public-domain rock pigeon exists.

## Evidence index

- `artifacts/tests/report_audio.json`: all test results and metrics
  (round 5's three final runs also in `artifacts/audio/fix_r5/`, round
  4's in `fix_r4/`, round 3's in `fix_r3/`).
- `artifacts/audio/measurements.json`: raw numbers behind the plots (wind
  sweep, tuck spectra, stall envelopes, hum, danger, voices, calls
  features and balance on the mixer, catch over the wind, programme
  loudness, wind over ambience, bell, pause, cost, max/heavy load; since
  round 5 the living sky, every call's ending, the danger over the wind).
- `artifacts/audio/plots/`:
  - `wind_rms_vs_airspeed.png` (AU1, measured);
  - `wind_curves.png`, `wind_cutoff.png` (the design);
  - `tuck_spectrum.png` (AU1);
  - `stall_envelope.png` (AU1);
  - `danger.png` (AU4; since round 5 also the drone with its spread-dive
    make-up);
  - `danger_over_wind.png` (round 5: the danger over the wind at 125/250 Hz
    at 1.5x and in a spread 2.6x dive, round 4's code and now, the bars);
  - `calls_map.png` (AU2);
  - `call_balance.png` (AU2: calls at 25 m on the mixer now, as round 2
    played them with Godot's default shelf, and the model);
  - `living_sky.png` (round 5: calls per minute in the Ecosystem's sky by
    player size: round 4's code by the verifier's probe, its rerun on
    round 5's code, the suite's simulation, and the calls heard over the
    cruise wind);
  - `call_endings.png` (round 5: every shipped call's ending, dB under its
    loudest 50 ms, round 4's re-cut ones beside, the -20 dB bar);
  - `catch_duck.png` (the catch duck vs speed and the crunch over the
    wind, measured; since round 4 also the stinger and the fanfare in a
    tucked dive, and the test's 6 dB bar);
  - `bad_input_recovery.png` (round 4: every input fed NaN, ±INF, ±1e30;
    the worst level 0.5 s later against the 1.5 dB tolerance);
  - `successive_screams.png` (a closing hawk's new calls: world metres and
    the floor now, round 4's perceived law, the measured starts, a full
    voice);
  - `programme_loudness.png` (menu and ordinary play at the output, round 2
    vs now, and the suite's pinned pair);
  - `wind_over_ambience.png` (the wind at cruise over every bed, per octave, and the meadow bed perched);
  - `speed_ducks.png` (the wind level, the ambience and calls ducks, and
    since round 5 the drone's make-up and the threat's call lift vs speed);
  - `bell_vs_distance.png` (the bell's gain vs distance: round 1, rounds 2-4
    at sparrow scale, now at every size, at cruise; the measured stroke);
  - `ambience_map.png` (zones over the real world's landmarks).
- `artifacts/audio/clips/*.wav`, `artifacts/audio/spectrograms/*.png`,
  `artifacts/audio/sheet_{flight,cues,calls,ambience,ui_music,renders}.png`:
  AU7.
- `artifacts/audio/renders/*.wav`: mixer renders saved by the tests (glide,
  dive, 2.2x spread/tucked, stall per size, danger at 1, pause before and
  during, menu music, heavy play in the dive and at the belfry, max load).
- `artifacts/audio/mix_levels.json`: every clip's peak/RMS (69 clips) and
  each cue, UI sound, bed and the bell at its mix level.
- `artifacts/audio/dev/audio_dev_*.png`: dev scene tour (glide, dive with
  the ambience ducked 24 dB and the calls 4 dB, stall, updraft, threat
  with the hawk screaming, the forest at cruise with the ambience ducked
  15.9 dB, a slow glide over the lake with the zone back in full, paused
  in the village). The tour clock holds while a screenshot is pending, so
  each shot shows its moment.
- `artifacts/audio/fix_r5/` (round 5):
  - `suite_run{1,2,3}.log` and `report_audio_run{1,2,3}.json`: the final
    runs (`baseline_suite.log`, `suite_try*.log`: this round's earlier
    runs, the first on round 4's code);
  - `mutate.py`, `mutants_summary.log` and `mutants/*.log`: the mutation
    run on a private copy (`mutants_run_first.log` and
    `mutants/mutants_summary_first.log`: the first pass, whose baseline
    failed on the heart's pitch window; `calls_round4/`: round 4's call
    cuts, for mutant E01);
  - `call_prep.log`: the re-cut calls; `synth_timing.log`: synthesis on
    worker threads (a first launch in the background, a synchronous build,
    a warm launch);
  - `heavy_play_peaks_final.log` (and `_run1.log`, an earlier pass): the
    headroom probe with the spread-dive scene;
  - `dev_tour.log`, `dev_tour_headless.log`: the dev tour (screenshots
    retaken in `artifacts/audio/dev/`, looked at);
  - `verifier_probe_r5x.log`, `verifier_probe_r5eng.log`,
    `verifier_probe_r4x_dive.log` and `verifier_probes/`: the verifiers'
    probes run on round 5's code, with their outputs (their own folders in
    `artifacts/audio/verify/` and their reports in `artifacts/tests/` were
    backed up and restored byte for byte);
  - `au7_export*.log`, `plots.log`.
- `artifacts/audio/fix_r4/` (round 4):
  - `suite_run{1,2,3}.log` and `report_audio_run{1,2,3}.json`: the final
    runs;
  - `mutate.py`, `mutants_summary.log` and `mutants/*.log`: the mutation
    run on a private copy (`mutants_run_first.log`: the first pass, whose
    flaky reads led to the drained stack step, the stinger take's
    pre-roll window and the cost test's lower statistic);
  - `verifier_probe_r4x_run2.log` (the whole experience probe),
    `verifier_probe_r4x_run3_dive.log` (its dive test on the final code),
    `verifier_probe_r4eng.log` and `verifier_probes/` (their outputs): the
    round-4 verifiers' probes run on the fixed code, their own folders
    backed up and restored byte for byte (`run1` is an early pass);
  - `heavy_play_peaks_10_trials*.log`: the headroom probe on the final
    code (three runs), `heavy_play_peaks_round3_code.log` on the round-3
    code, `heavy_play_peaks_fixed_lift_version.log` on the first make-up;
  - `plots.log`.
- `artifacts/audio/fix_r3/` (round 3):
  - `suite_run{1,2,3}.log` and `report_audio_run{1,2,3}.json`: the final
    runs;
  - `heavy_play_peaks_10_trials.log`: the headroom probe on the final
    code;
  - `mutants_summary.log` and `mutate.py`: the mutation run;
  - `verifier_probe_*.log` and `verifier_probes/`: the round-3 verifiers'
    probes run on the fixed code, with their outputs. Their own folders in
    `artifacts/audio/verify/` were backed up and restored byte for byte.
  - `verifier_r3x_measurements_before.json`, `verifier_r3x_cues_before.json`
    and `verifier_r3eng_call_balance_before.json`: copies of their round-2
    measurements, which the plots compare with;
  - `au7_export.log`, `au7_export_renders.log`, `plots.log`,
    `dev_tour.log`.
- `artifacts/audio/fix_r2/`: round 2's logs.
- `scenes/dev/audio_synth_timing.tscn` output: per-clip synthesis cost.
- `artifacts/audio/prep/`, `artifacts/audio/survey/`: how the calls were
  chosen and cleaned.

## Known limits

- **Not listened to.** Levels, timbres and trims are measured, not heard.
  A listening pass on the headset is still needed. The knobs are:
  - `AudioDirector.LEVEL` / `UI_LEVEL` / `MUSIC_GAIN_DB`;
  - `FlightSoundMap`: the wind curve (`BODY_DB_AT_*`), `WHOOSH_DB`,
    `CATCH_*`, `AMB_DUCK_*` and `CALLS_DUCK_*`;
  - `CallVoices.VOICE.loud`, `VOICE.reach`, `AIR_DB_PER_M`, `MIN_CALL_DB`,
    `THREAT_FLOOR_DB`, `THREAT_FLOOR_FAR` and `THREAT_FLOOR_RISE_DB`;
  - `FlightSoundMap.DANGER_MAKEUP_MAX_DB` and `THREAT_EDGE_LIFT_DB`;
  - `AmbienceZones.BEDS` / `BELL_*`.

  Items for that pass:
  - the sparrow cuts are noisy (tonality 0.23-0.35, gaps 26-38 dB under
    the chirps);
  - `wren_3` is two short noisy bursts (and 3.7 dB under the other wrens);
  - the synthesized starling whistles are near-pure;
  - the speed duck: whether 16 dB at cruise leaves enough of the zone
    while gliding (it is realistic: at 30 km/h the air at the ears masks
    a meadow), and how the world returning over a second as the bird
    slows feels;
  - the catch in a full dive: a 14 dB dip of the wind and the world for
    0.35 s under the crunch. It reads as impact on paper, and it should
    be heard;
  - the menu music level. It has been +9, +12 and now +10 dB over three
    rounds, and is now set against the game's own loudness. The UI ticks
    (click, hover) sit at about the music's loudness;
  - the hawk's scream as it closes in and in a dive (no speed duck, and
    lifted over the edge in a tuck): whether "getting louder" reads, and
    whether it stands too far forward in a dive;
  - the living sky at the start sizes (round 5): about 200 calls a minute
    over the wind in the Ecosystem's full sky, giants and raptors loudest.
    Whether that reads as alive or as busy is for the ear; the knobs are
    each species' pace (`VOICE.every`), `MIN_CALL_DB` and the reaches;
  - the hawk's two short screams now fall away over their last 0.5 s (a
    release at the scream's own decay rate), and one western gull cut
    trails off: whether they sound natural;
  - the danger drone rising by up to 6 dB in a fast spread dive.
- **Programme loudness.** A glide at cruise is 7.7 LU under the menu
  music and a slow glide 9.2 (the verifier's probe). They are the wind
  alone, and a closer match would flatten the dive/glide contrast AU1
  asks for. The catch in a tucked dive does not make the SFX mix louder
  over its loudest 0.2 s (the round-3 verifier's reward-lift probe reads
  +0.0-0.1 dB A there). The crunch stands 9-10 dB A clear of what remains
  of the wind; see Fix round 3.
- **Not run on a Quest or in the simulator.** Performance on a Quest is
  extrapolated from Mac timings (tight-loop and per-frame). The Quest's
  small speakers are why every low sound carries harmonics above 150 Hz.
- **Recordings keep some residual noise** (about -45 dB under their peaks)
  after denoising. At game distances it sits under the wind and beds.
- **3D.**
  - Doppler is off, and there is no reverb or occlusion: a bird behind a
    building is not muffled.
  - Ambience beds are non-positional (zone weights, not emitters); only
    the village bell is placed in 3D.
  - Air absorption is one high shelf at 5 kHz, set from the distance in
    world metres. It is not a per-band ISO 9613 filter: a wren's and a
    swallow's trills lose about 0.6 dB more at 25 m than `audibility()`
    predicts, from the shelf's slope below 5 kHz.
  - Godot scales any shelf by (1 - gain), so close up the depth is less
    than designed. There it is under 1 dB anyway.
- **Calls and headroom.** A voice never plays a clip above 0 dB of gain
  (peak -3 dBFS, one ear when panned hard), so a quiet call type stays
  quiet (`wren_3`). A single loud call close by and panned to one side
  peaks at about -3.4 dBFS on the Calls bus: the loudest single sound
  after the stinger. Heavy play keeps 0.7 dB or more under the limiter's
  ceiling over the probe's 15 trials; the closest is the spread 2.6x dive,
  where the drone's make-up is at its full 6 dB (-2.2 dBFS). A spread
  2.6x dive is the rarest of those states (2.6x is the tucked top speed).
- **Quit.** Godot's AudioServer does not free playbacks still in its list
  at exit, so quitting while sounds play reports "resources still in use".
  Call `await AudioDirector.shutdown()` before `get_tree().quit()` (the
  dev scene does; integration's Quit path should). The test suites wait
  0.15 s in `after_all` for the same reason. The one "ObjectDB instance
  leaked" line at exit is not audio's: the core suite alone prints it too.
- **Cache location.** `user://audio_cache/<key>/`. tools/gd.sh gives every
  sandbox its own user://, so each new sandbox synthesizes once (about
  2 s on the pool's threads since round 5; round 4's doc said the cache was
  shared across sandboxes, which stopped being true when tools/gd.sh
  changed). The key is the content hash, so a stale clip is never read.
  An exported build with binary-token scripts hashes the `.gdc` files; if
  neither form can be read, the key falls back to `DESIGN_VERSION` and the
  engine version.
- **Settings in probes.** The suite never writes Settings: every
  director the fixture builds reads its in-memory store. The older
  verifier probes in `tests/probes/audio/` that set the real `Settings`
  (rounds 1-2) no longer move those directors; they would set
  `fx.settings` instead. `Fixture.restore_default_settings()` is kept for
  them.
- **One hawk recording.** The three hawk clips are cuts of different
  lengths of one scream. The only clean red-tailed hawk recording
  (PsychoBird, 3.4 s) holds one scream, and the red-shouldered hawk's
  "kee-ah" measured as an eagle yelp in round 1. It is a stereotyped call
  in nature too. Variety comes from length, ±5% pitch and the bird's size.
  Since round 5 the two short cuts end with a release (their last 0.8 s
  fall 60 dB), not mid-note. A second recording would be the fix, if a
  clean one turns up. The gulls are two recordings in four cuts, two of
  them sharing one note.
- **The scream in a full dive.** In a tucked 2.6x escape dive, the
  loudest wind of the game, the scream is held to a full voice under the
  dive's 6 dB calls duck (headroom), so it stands only about 3 dB over the
  wind in its own octave from 45 m and 6 dB from 15 m (the round-4
  verifier's probe on round 5's code; -0.3 and +2.1 before). More would
  need a wind duck under the scream, which would dip the main speed cue
  every time the hawk calls. The heart and drone carry the danger there
  (11-19 dB over the wind's low end).
- **Bad input.** A non-finite number from another area gets a safe
  default (the audio never goes NaN or silent), and an absurd finite one
  is clamped and played as that extreme. A mass the Bird clamps to
  0.001 kg is played as a moth-light bird at 4x its cruise for as long as
  it lasts: the wind roars and releases on its designed 0.18 s time
  constant. Flight's telemetry still builds `wing_extension` from the raw
  WingState (flight's concern). Audio no longer depends on it.
- **Heartbeat latency.** The generator buffer is 0.15 s, so a change of
  tempo is heard within about that long. The level follows at once.
- **Tests and CPU.** The suite mixes in real time (the headless mixer
  cannot run faster): 54.2-54.7 s over round 5's final runs at machine load
  7, about 5 s under the 60 s budget. On a machine far busier than
  that it may still come close (round 4's runs at load 18-32 took 2-3 s
  longer than at load 11-15). The cost test asserts the brief's budget
  (the wall-clock mean, the tight loop scaled to a Quest) and records the
  rest. The wind suite's flight and danger tests share one session per
  size, so `--test=tuck` still records the whole session (about 11 s).
- **Contract assumptions.** The flight telemetry keys and `stall_warning`
  follow the flight spec. If `telemetry()` is missing, wind falls back to
  `Bird.velocity`. NPC extras are duck-typed (`state_name()`, `hidden`,
  `target`, the `behaviour` signal). The bell uses a landmark named
  `church*` if present.
- The village bed is the least characterful: a murmur and a wind whistle.
  The bell carries it.
- **Verifier probes.**
  - `r2x_experience.test_call_loudness_balance_at_equal_distance`
    (round 2's verifier) still stops on `VOICE["db"]`, which the round-2
    levelling replaced. The mixer balance test covers it.
  - Round 2's reruns of the verifiers' probes rewrote some of their
    round-2 files (`artifacts/audio/verify/r2x/`, see round 2's report).
    Rounds 3 and 4 left their folders untouched.
  - `r4x_experience.test_danger_and_scream_heard_while_fleeing_in_a_dive`
    passes on round 5's code (+2.9 dB from 45 m in a tucked dive, bar > 0).
  - Round 5's reruns of the verifiers' probes: every r5x (7), r5eng (7) and
    that r4x test pass; their folders and report files were restored byte
    for byte afterwards.
  - The r5x living-sky probe prints a `reach_world_m` table it computes
    itself as reach x world_scale; since round 5 every reach is in world
    metres at every size.
- **Integration (not audio's files).** Nothing calls
  `AudioDirector.play_ui()` yet, so menu clicks are silent until the UI
  wires it; `scenes/main.tscn` has no AudioDirector; the Quit path should
  `await AudioDirector.shutdown()`. Noted in ARCHITECTURE.md.
