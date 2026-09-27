class_name FlightSoundMap
extends RefCounted
## How the flight model's telemetry and the game's threat level become sound
## parameters. Pure functions (no nodes), so the curves are unit-tested and
## plotted (artifacts/audio/curves_*.png) independently of the mixer.
##
## Speed is judged relative to the bird's own cruise speed
## (SizeRules.performance(mass).cruise): gliding at cruise sounds the same
## for a sparrow (9 m/s) and an eagle (19 m/s), a dive sounds like a dive at
## any size, and within one size every level is strictly increasing in
## airspeed (AU1). Bigger birds get a darker wind (lower cut-off) and a
## slower stall buffet.

## The wind is anchored on two speeds: at DIVE_RATIO x cruise the body
## plays at BODY_DB_AT_DIVE (the loudest the wind gets, with headroom for
## the rest of the mix), at cruise at BODY_DB_AT_CRUISE, log-linear in
## between (27 dB per decade of speed); below cruise it falls
## BODY_DB_PER_DECADE (level ~ ratio^1.8: dynamic pressure grows with v^2,
## a touch less keeps slow flight audible). Tucking adds TUCK_DB, which
## makes up for the energy the tuck's high-pass removes, so a tucked dive is
## thinner AND louder.
##
## The cruise anchor is set by the programme loudness, not by the dive
## alone: a glide at cruise is the game's ordinary state and must not sit
## far under the menu music the player sets the headset volume by. Round 3
## measured it 11.6 LU under the music with the cruise wind at -16.3 dB;
## at -14.3 (and the music 2 dB lower) it is within 8 LU, while a tucked
## dive still plays 13 dB (RMS) over a glide (AU1: >= 12).
const DIVE_RATIO := 2.6
const BODY_DB_AT_DIVE := -3.0
const BODY_DB_AT_CRUISE := -14.3
const BODY_DB_PER_DECADE := 36.0
const TUCK_DB := 2.5
const SILENT_DB := -80.0


static var _cruise_mass := -1.0
static var _cruise_val := 9.0


## Cruise speed for a mass (cached: called every frame, and
## SizeRules.performance builds a dictionary).
static func cruise(mass: float) -> float:
	mass = AudioInput.num(mass, 0.03, 0.001, 100.0)
	if mass != _cruise_mass:
		_cruise_mass = mass
		_cruise_val = float(SizeRules.performance(mass)["cruise"])
	return _cruise_val


## The fastest a bird is taken to fly, relative to its cruise: past every
## dive (DIVE_RATIO is the tucked V_max), where every level has long reached
## its ceiling. Faster readings are clamped here.
const MAX_RATIO := 4.0


## airspeed / cruise, in [0, MAX_RATIO].
static func speed_ratio(airspeed: float, mass: float) -> float:
	return AudioInput.num(airspeed / cruise(mass), 0.0, 0.0, MAX_RATIO)


## 0 = wings spread .. 1 = fully tucked.
static func tuck_amount(tel: Dictionary) -> float:
	if AudioInput.flag(tel.get("tucked", false)):
		return 1.0
	var ext := AudioInput.num(tel.get("wing_extension", 1.0), 1.0, 0.0, 1.0)
	return clampf((0.55 - ext) / 0.4, 0.0, 1.0)


## The telemetry keys audio reads, each a finite number (or a flag) in its
## sane range, whatever the flight area sent: a key that is missing, NaN,
## INF or not a number takes its safe default (still air for the airspeed
## unless `fallback_speed`, the Bird's own velocity, is given; spread wings;
## no stall, lift or perch; world_scale 1), a number out of range is clamped.
## One bad frame from a glitching tracker must never reach a smoothed gain.
static func clean_telemetry(tel: Dictionary, fallback_speed: float = 0.0) -> Dictionary:
	return {
		"airspeed": AudioInput.num(tel.get("airspeed"), AudioInput.num(fallback_speed, 0.0, 0.0, 1000.0), 0.0, 1000.0),
		"wing_extension": AudioInput.num(tel.get("wing_extension"), 1.0, 0.0, 1.0),
		"tucked": AudioInput.flag(tel.get("tucked")),
		"stalled": AudioInput.flag(tel.get("stalled")),
		"stall_warning": AudioInput.num(tel.get("stall_warning"), 0.0, 0.0, 1.0),
		"perched": AudioInput.flag(tel.get("perched")),
		"in_updraft": AudioInput.num(tel.get("in_updraft"), 0.0, -50.0, 50.0),
		"world_scale": AudioInput.num(tel.get("world_scale"), 1.0, 0.01, 100.0),
	}


## Wind body level, dB: silent at rest, -14.3 dB at cruise, -3 dB in a
## 2.6x dive, strictly increasing in airspeed; tucking adds TUCK_DB.
static func body_db(x: float, tuck: float = 0.0) -> float:
	x = AudioInput.num(x, 0.0, 0.0, MAX_RATIO)
	tuck = AudioInput.num(tuck, 0.0, 0.0, 1.0)
	if x <= 0.03:
		return SILENT_DB
	var dec := log(x) / log(10.0)
	var fast := (BODY_DB_AT_DIVE - BODY_DB_AT_CRUISE) / (log(DIVE_RATIO) / log(10.0))
	var slope := BODY_DB_PER_DECADE if x < 1.0 else fast
	return clampf(BODY_DB_AT_CRUISE + slope * dec + TUCK_DB * clampf(tuck, 0.0, 1.0), SILENT_DB, 0.0)


## The wind's A-weighted level on its bus follows its body level about
## 1.5 dB per dB (it brightens as it grows: the low-pass opens with speed,
## the edge layer comes in): WIND_AW_AT_0 + WIND_AW_PER_DB x body_db,
## measured on the mixer at seven speeds from cruise to a tucked 2.6x dive,
## spread and tucked, within 0.8 dB. Used to size the catch duck.
const WIND_AW_AT_0 := -20.8
const WIND_AW_PER_DB := 1.5


static func wind_aw_db(body: float) -> float:
	return WIND_AW_AT_0 + WIND_AW_PER_DB * body


## Catch duck of the flight layers (dB, <= 0): CATCH_DUCK_DB as a rule,
## deeper in a fast dive, where the wind is the loudest sound of the game
## and a 5 dB duck left the crunch 1-3 dB over it (round 3). The wind is
## brought CATCH_CLEAR_DB under the crunch (CATCH_CRUNCH_AW_DB: crunch and
## puff, loudest 0.2 s A-weighted on the SFX bus), at most CATCH_DUCK_MAX_DB
## down: 10-11 dB clear from 2x cruise to a tucked 2.6x dive (more below),
## with the wind back within half a second. 11 rather than a bare 6: the
## duck lands in the same mix block as the crunch, and a window that starts
## a frame early counts undiminished wind (one 23 ms frame at the dive's
## level weighs as much as a dozen ducked ones). body: the wind's body
## level (body_db).
const CATCH_DUCK_DB := -5.0
const CATCH_DUCK_MAX_DB := -14.0
const CATCH_CRUNCH_AW_DB := -25.2
const CATCH_CLEAR_DB := 11.0


static func catch_duck_db(body: float) -> float:
	body = AudioInput.num(body, SILENT_DB, SILENT_DB, 0.0)
	var want := CATCH_CRUNCH_AW_DB - CATCH_CLEAR_DB - wind_aw_db(body)
	return clampf(want, CATCH_DUCK_MAX_DB, CATCH_DUCK_DB)


## Wind low-pass cut-off, Hz: a dull 300 Hz rumble when slow, ~1 kHz at
## cruise, ~7 kHz in a dive; tucking opens it further (brighter), bigger
## birds hear it darker.
static func body_cutoff(x: float, tuck: float, mass: float) -> float:
	var size_k := pow(9.0 / cruise(mass), 0.35)
	return clampf(320.0 * exp(1.2 * x) * (1.0 + 0.6 * tuck) * size_k, 250.0, 16000.0)


## Wind high-pass, Hz: tucking thins the wind (cuts its body).
static func body_highpass(tuck: float) -> float:
	return 30.0 + 320.0 * tuck


## Bright "edge" layer (hiss + whistles), dB: comes in above cruise, fully
## in a dive, and mostly when tucked.
static func edge_db(x: float, tuck: float) -> float:
	var g := smoothstep(0.9, 2.4, x) * (0.3 + 0.7 * tuck)
	return SILENT_DB if g <= 0.001 else maxf(SILENT_DB, -6.0 + 20.0 * log(g) / log(10.0))


## Stall buffet level, dB. stall: 1 while stalled, else stall_warning x0.4.
## Needs some airflow to flutter (fades out when nearly stopped).
static func flutter_db(stall: float, x: float) -> float:
	var g := clampf(stall, 0.0, 1.0) * clampf(0.35 + x, 0.0, 1.0)
	return SILENT_DB if g <= 0.001 else maxf(SILENT_DB, -5.0 + 20.0 * log(g) / log(10.0))


## Buffet rate factor (the loop is 14 Hz at 1.0): 14 Hz for a sparrow,
## ~10 Hz for an eagle, a little faster for a wren.
static func flutter_pitch(mass: float) -> float:
	return clampf(pow(0.03 / AudioInput.num(mass, 0.03, 0.001, 100.0), 0.07), 0.7, 1.2)


## Updraft hum level, dB, from the lift under the wings (m/s).
static func hum_db(lift: float) -> float:
	var g := smoothstep(0.25, 3.0, lift)
	return SILENT_DB if g <= 0.001 else maxf(SILENT_DB, -9.0 + 20.0 * log(g) / log(10.0))


## The hum rises a little in pitch in stronger lift (variometer-like cue).
static func hum_pitch(lift: float) -> float:
	return 1.0 + 0.12 * clampf(lift / 5.0, 0.0, 1.0)


## Ambience speed duck, dB (<= 0): the faster the bird flies, the more its
## own airflow masks the world around it, as it does in real flight (wind
## noise at the ears grows some 50-60 dB per decade of speed). None below
## AMB_DUCK_FROM x cruise (perched, hovering, slow flight: the zone is heard
## in full); then the beds recede log-linearly to AMB_DUCK_AT_CRUISE_DB at
## cruise, where the wind, the main speed cue, stands clearly above every
## bed, and on to at most AMB_DUCK_MAX_DB. (Round 3: the cruise wind is
## 2 dB louder than in round 2 and the beds keep the same place under it,
## 15.9 dB down; and the duck starts at 0.55x rather than 0.4x, so a slow
## glide near the ground, a quiet wind, keeps its world: 2.3 dB down at
## 0.6x instead of 7.9.)
const AMB_DUCK_FROM := 0.55
const AMB_DUCK_AT_CRUISE_DB := 15.9
const AMB_DUCK_MAX_DB := 24.0


static func ambience_duck_db(x: float) -> float:
	if x <= AMB_DUCK_FROM:
		return 0.0
	var per_decade := AMB_DUCK_AT_CRUISE_DB / (log(1.0 / AMB_DUCK_FROM) / log(10.0))
	return -minf(AMB_DUCK_MAX_DB, per_decade * log(x / AMB_DUCK_FROM) / log(10.0))


## NPC calls speed duck, dB (<= 0): none up to CALLS_DUCK_FROM x cruise
## (calls are gameplay information: where prey and predators are), then
## down to -CALLS_DUCK_MAX_DB in a full dive, where the rushing air masks
## them in real flight too. It also keeps a close call from landing at full
## level on the loudest wind of the game (heavy-play headroom).
const CALLS_DUCK_FROM := 1.2
const CALLS_DUCK_MAX_DB := 6.0


static func calls_duck_db(x: float) -> float:
	return -CALLS_DUCK_MAX_DB * smoothstep(CALLS_DUCK_FROM, DIVE_RATIO, x)


## The threatening predator's call over the wind's edge (dB, >= 0), on top
## of making up the calls' speed duck (CallVoices): the edge layer (hiss and
## narrow whistles, 2-8 kHz) is the part of the wind that covers a scream's
## band, and it comes in mostly when tucked. Round 5's verifier measured a
## hawk screaming from 45 m in a tucked 2.6x dive (sparrow scale) at the
## wind's own level in its 2 and 4 kHz octaves (-0.3 dB; +6 to +7 with the
## wings spread, where the edge is 10 dB lower). The call rises with the
## edge's gain, THREAT_EDGE_LIFT_DB when the edge is fully in (a tucked full
## dive), 1.2 dB spread at 2.6x, nothing below 0.9x cruise. Headroom stays
## with the crowd rule, which counts the lifted voice.
const THREAT_EDGE_LIFT_DB := 4.0
## edge_db at its full level (edge_db's gain 1).
const EDGE_FULL_DB := -6.0


static func threat_call_lift_db(edge: float) -> float:
	edge = AudioInput.num(edge, SILENT_DB, SILENT_DB, 0.0)
	if edge <= SILENT_DB:
		return 0.0
	return THREAT_EDGE_LIFT_DB * clampf(db_to_linear(edge - EDGE_FULL_DB), 0.0, 1.0)


## Wind body pitch: a slight rise with speed adds urgency without sounding
## like a sample being sped up.
static func body_pitch(x: float) -> float:
	return clampf(0.92 + 0.06 * x, 0.9, 1.1)


## Stereo pan of the wind from where the air comes from relative to the
## head: head turned left (air arriving from the right) -> right ear louder.
## rel_yaw: head yaw minus flight-direction yaw (rad, + = head turned left).
static func wind_pan(rel_yaw: float, x: float) -> float:
	return clampf(sin(rel_yaw) * 0.5 * clampf(x, 0.0, 1.0), -0.5, 0.5)


# --- danger ---

## Heartbeat level, dB: silent at 0, strictly increasing, -8 dB at 1. (The
## beat is shaped for a low crest factor: at -8 dB it is as loud to the ear
## as the earlier, peakier beat at -5 dB, with 3 dB more headroom.)
static func heart_db(level: float) -> float:
	level = AudioInput.num(level, 0.0, 0.0, 1.0)
	if level <= 0.02:
		return SILENT_DB
	return maxf(SILENT_DB, -8.0 + 26.0 * log(clampf(level, 0.0, 1.0)) / log(10.0))


## Tension drone, dB: only once the threat is real (> 0.25), then rising
## to -12 dB at contact. It rises early (a smoothstep to the 0.35 power:
## -16 dB at 0.5, within 0.5 dB of the square root it was from 0.75 up)
## because it is the layer that carries the danger over the wind: its E3/F3
## sits in the 125-250 Hz bands where the flight wind is strongest and a
## headset still plays (round 3: at threat 0.5 in fast flight the danger cue
## had fallen under the wind there; round 5: with the square root, -18 dB at
## 0.5, its lead over a spread dive's wind moved between 1.4 and 2.6 dB from
## one gust to the next against the test's 1 dB bar).
static func drone_db(level: float) -> float:
	var g := pow(smoothstep(0.25, 1.0, AudioInput.num(level, 0.0, 0.0, 1.0)), 0.35)
	return SILENT_DB if g <= 0.001 else maxf(SILENT_DB, -12.0 + 20.0 * log(g) / log(10.0))


## Heartbeat tempo in beats per second: 1 (60 bpm) at a faint threat, 1.85
## (111 bpm) at contact. The director schedules beats at this rate; the
## beat itself keeps its pitch.
static func heart_rate(level: float) -> float:
	return 1.0 + 0.85 * AudioInput.num(level, 0.0, 0.0, 1.0)


## Seconds from lub to dub. A faster heart shortens systole too, but less
## than the whole beat (0.26 s at 60 bpm, 0.19 s at 111): the "lub-dub,
## pause" rhythm stays a heartbeat instead of becoming an even pulse.
static func heart_dub(level: float) -> float:
	return maxf(SoundDesigns.HEART_LUB_END, SoundDesigns.HEART_DUB_AT / sqrt(heart_rate(level)))


## Danger make-up in fast flight with the wings spread (dB, >= 0), on the
## drone. The suite pins the danger cue's margin over the wind in the 125
## and 250 Hz octaves at 1.5x cruise (>= 1 dB at threat 0.5, >= 6 at 1).
## Above that the wind's body rises 27 dB per decade of speed, and with the
## wings spread nothing thins its low end (a tuck high-passes it at 350 Hz,
## where the danger stands 12-19 dB clear): round 5's verifier measured the
## danger 2.6-2.8 dB under the wind at threat 0.5 in a spread 2.6x dive.
## The drone (E3/F3, the layer that carries the danger in those bands) rises
## with the wind's body above DANGER_MAKEUP_FROM x cruise, up to
## DANGER_MAKEUP_MAX_DB, and less as the wings tuck. Only the drone: the
## heartbeat's harmonics sit an octave apart and its crest is higher, and
## the drone alone keeps the headroom (-7 dBFS peak at threat 1).
const DANGER_MAKEUP_FROM := 1.5
const DANGER_MAKEUP_MAX_DB := 6.0


static func danger_makeup_db(x: float, tuck: float) -> float:
	x = AudioInput.num(x, 0.0, 0.0, MAX_RATIO)
	tuck = AudioInput.num(tuck, 0.0, 0.0, 1.0)
	if x <= DANGER_MAKEUP_FROM:
		return 0.0
	var rise := body_db(x) - body_db(DANGER_MAKEUP_FROM)
	return clampf(rise, 0.0, DANGER_MAKEUP_MAX_DB) * (1.0 - tuck)


# --- wingbeats ---

## Whoosh level, dB, from the flap strength (0..1): WHOOSH_DB at full
## strength. -10 rather than round 2's -7: until round 3 Godot's default
## air-absorption shelf dulled the small bird's whoosh by 3-6 dB A, and
## without it a full flap was as loud as the catch crunch (about -25 dB A);
## a wingbeat is the player's own action, the catch its reward. Now a full
## flap sits 3 dB under the crunch and still 10 dB and more over the wind
## up to 1.5x cruise.
const WHOOSH_DB := -10.0


static func whoosh_db(strength: float) -> float:
	return WHOOSH_DB + 20.0 * log(0.18 + 0.82 * AudioInput.num(strength, 0.5, 0.0, 1.0)) / log(10.0)


## Whoosh size class for a body mass: 0 small, 1 medium, 2 large.
static func whoosh_size(mass: float) -> int:
	var tier := SizeRules.tier_for_mass(AudioInput.num(mass, 0.03, 0.001, 100.0))
	return 0 if tier <= 3 else (1 if tier <= 6 else 2)


## Pitch within a size class: heavier birds sound lower, continuously.
static func whoosh_pitch(mass: float) -> float:
	mass = AudioInput.num(mass, 0.03, 0.001, 100.0)
	var ref: float = [0.03, 0.3, 1.3][whoosh_size(mass)]
	return clampf(pow(ref / maxf(mass, 0.001), 0.1), 0.85, 1.18)


## Everything the director sets from one telemetry sample. Any input is
## taken (see clean_telemetry): every value returned is finite.
## fallback_speed: the airspeed to use when telemetry has none (the Bird's
## velocity).
static func compute(raw: Dictionary, mass: float, rel_yaw: float = 0.0, fallback_speed: float = 0.0) -> Dictionary:
	var tel := clean_telemetry(raw, fallback_speed)
	mass = AudioInput.num(mass, 0.03, 0.001, 100.0)
	rel_yaw = AudioInput.num(rel_yaw, 0.0, -PI, PI)
	var x := speed_ratio(tel["airspeed"], mass)
	var tuck := tuck_amount(tel)
	var stalled: bool = tel["stalled"]
	var stall := 1.0 if stalled else 0.4 * float(tel["stall_warning"])
	var perched: bool = tel["perched"]
	var lift := 0.0 if perched else float(tel["in_updraft"])
	var edge := edge_db(x, tuck)
	var p := {
		"x": x,
		"tuck": tuck,
		"body_db": body_db(x, tuck) - (10.0 if perched else 0.0),
		"body_cutoff": body_cutoff(x, tuck, mass),
		"body_highpass": body_highpass(tuck),
		"body_pitch": body_pitch(x),
		"edge_db": edge,
		"flutter_db": SILENT_DB if perched else flutter_db(stall, x),
		"flutter_pitch": flutter_pitch(mass),
		"hum_db": hum_db(lift),
		"hum_pitch": hum_pitch(lift),
		"pan": wind_pan(rel_yaw, x),
		"amb_duck_db": 0.0 if perched else ambience_duck_db(x),
		"calls_duck_db": 0.0 if perched else calls_duck_db(x),
		"threat_lift_db": 0.0 if perched else threat_call_lift_db(edge),
		"danger_makeup_db": 0.0 if perched else danger_makeup_db(x, tuck),
	}
	return p
