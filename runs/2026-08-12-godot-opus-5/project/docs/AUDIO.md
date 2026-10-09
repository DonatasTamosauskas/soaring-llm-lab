# What the game sounds like

Nothing here ships an audio file. Every sound in Soaring is arithmetic: the air
over your own wings is synthesised a sample at a time while you fly, and
everything else — bird calls, wingbeats heard from outside, a catch, a
collision, a promotion, the murmur of the land — is baked once at load into
`AudioStreamWAV`s and played by the engine's own mixer.

That split is the whole design, and it is a split by *what the sound has to do*:

| | what it is | why |
|---|---|---|
| `Soundscape` | your own air, synthesised per sample | it has to track airspeed and wing shape continuously — a looped clip cannot |
| `VoiceBank` | every event, baked once | a bird calling to your left is a fixed gesture; baked, it costs GDScript nothing and can be positional |
| `FlockAudio` | decides what the sky says | scene-free, so "you can hear a bigger bird closing on you" is an assertion |
| `AudioDirector` | owns the emitters | a fixed pool of eight, four buses, ducking |
| `SoundState` | the one channel in | what `FlightCommand` is to physics, this is to sound |

`FlightAudio` on the player is the only thing in the area that knows an
`AudioStreamPlayer` exists.

---

## Your own air

The first-person layer is what a headset player is actually flying on. Measured
with `tests/audio_report.gd` on this build:

| airspeed | rms | brightness |
|---|---|---|
| 0 m/s | 0.003 | 387 Hz |
| 17.5 m/s (trim) | 0.033 | 1902 Hz |
| 35 m/s | 0.108 | 2245 Hz |
| 78 m/s (dive cap) | 0.343 | 2595 Hz |

Trim to a full dive is a tenfold change in level — about 20 dB — and the sound
gets brighter as well as louder, so the speed cue survives somebody turning the
volume down. Tucking at a fixed 35 m/s moves the centroid from 2245 Hz to
3378 Hz: the wings alone are audible.

Layered on top, each gated so a bird that is not doing the thing pays nothing
for it:

- **wingbeat** — a swish that sweeps down in pitch, plus a thump whose weight
  moves lower as you grow. Panned by which arm did the work, so a one-winged
  beat arrives in one ear.
- **stall buffet** — broadband noise chopped at about 13 Hz. It is the one sound
  in the game meant to be unpleasant and it arrives before the HUD can say
  STALL.
- **the land below** — fades out from under you as you climb; by 300 m there is
  nothing but air. This is the altitude cue.
- **lift** — a low swell and a slight hush of the hiss, not more noise, because
  a thermal is smooth air. Sink is silent: only lift is worth telling you about.

Cost, measured: every layer at once is **1.65 % of one core** on this desktop
for real-time audio, at a 16 kHz mix rate. No `sin`, no `exp`, no allocation and
no engine calls inside the sample loop.

## The sky

`FlockAudio.menace()` is the one claim the flock's audio has to earn: *you can
hear what is about to eat you.* Three terms, all of which must be true — it is
close, it is bigger than you, and it is getting closer:

| distance | a peer | something bigger, drifting | the same bird closing |
|---|---|---|---|
| 5 m | 0.000 | 0.235 | 0.693 |
| 30 m | 0.000 | 0.117 | 0.345 |
| 70 m | 0.000 | 0.013 | 0.038 |
| 90 m+ | 0.000 | 0.000 | 0.000 |

A bird that cannot eat you is never menacing, however large — the sound is
honest about the rules, so if you can hear the rush you are prey. It is the only
continuous voice in the game; everything else is a one-shot, capped at seven a
second and six voices, so a squabble two hundred metres away cannot mask the
thing behind you.

Five species have five call contours and three moods (contact, alarm, hunting).
An alarmed bird is recognisably the same bird, frightened: higher, shorter,
rougher. A hunter's calls come 9 s apart when it is calm and 1.4 s apart when it
is on top of you, which is the same information the HUD's chevron carries,
without having to look at anything.

---

## Running it

```sh
tests/run.sh                                              # includes AudioTests
godot --headless --xr-mode off --script res://tests/audio_report.gd
godot --headless --xr-mode off --script res://tests/audio_report.gd -- --wav=/tmp/soaring
```

The report asserts nothing — it is the instrument the area was tuned against,
the equivalent of `tests/flight_report.gd` for the ears, and every number in
this document is a line of its output. `--wav=` writes the clips out as real
WAV files for somebody who has speakers.

`AudioTests` (in `tests/test_audio.gd`) is what fails. It asserts the shapes
rather than the tuning constants: that wind rises monotonically with airspeed
and a dive is many times a glide, that a tuck is thinner, that the ground fades
as you climb, that a wingbeat is a transient that ends, that a stall shakes at
the buffet rate and not at some slow swell, that lift swells low, that nothing
in the game clips, that a poisoned frame cannot silence the synthesiser for
ever (a one-pole filter that takes on NaN keeps it), that every clip the game
can name exists and is normalised, that species do not sound alike, and that
the sky cannot shout all at once.

## What is not here

- **Nobody has heard it in a headset.** Every claim above is a number taken off
  a rendered buffer. Levels, the balance between the beds and the air, and
  whether the buffet is unpleasant or merely annoying are all judgements that
  need ears and a Quest.
- **No music, no reverb, no occlusion.** A gorge sounds like open sky.
- **No wind noise from the world itself** — only from your own motion. Standing
  still on a branch in a gale is silent.
- **`FlightAudio.cue()`** is a single swept-sine voice for events on the
  head-locked channel; the positional events go through `VoiceBank`. It is a
  placeholder that the event work left in place.
- **Paused audio is silence by omission**, not by design: the generator stops
  being fed. The ambience beds deliberately keep playing under the menu.
