class_name CallVoices
extends Node3D
## NPC bird voices: a fixed pool of AudioStreamPlayer3D (nothing is created
## or freed while playing) shared by every NPC in earshot.
##
## Each NPC gets a call timer from its species (VOICE); behaviour changes
## the pace (fleeing birds alarm-call, perched birds sing more, hunting
## raptors scream more). When a timer fires, the call is scored by how loud
## it would be at the listener (species level + distance attenuation, in
## world metres: see below) plus relevance boosts (the bird that threatens
## the player, the prey being chased). It takes a free voice, or steals the
## weakest playing voice if it beats it by STEAL_MARGIN_DB (the victim fades
## out over 50 ms), or is dropped. So the voices always go to the nearest
## and most relevant birds (AU5). Moths are a soft looping flutter heard
## only close up. The pool also plays NPC-on-NPC catch sounds.
##
## Levels are set by loudness, not by peak: every clip's A-weighted
## short-term loudness is measured (CALL_LOUDNESS, pinned by a test against
## the shipped clips) and the voice plays it so the species sounds as loud
## as VOICE.loud at its unit distance. (The clips are peak-normalised, and a
## near-pure synthesized whistle carries 10-15 dB more energy per dB of peak
## than a sparse recorded chirp: by peak, the starlings towered over the
## sparrows.) The suite renders every species through this pool and checks
## the mixer against that model (audio_calls_test).
##
## Sound follows the world, not the listener's size: every distance here
## (inverse distance from the unit distance, the fade to the reach, the air
## absorption) is in world metres, whatever the player's world_scale. The
## player sees the world magnified by 1 / world_scale (a sparrow-sized
## player sees a crow 60 m away as a giant crow 450 m away), and a source
## magnified with it carries as much further as it is bigger, so the level
## at the ear depends on distance over size alone: exactly the physical
## law in world metres. (A real sparrow hears a crow 60 m away as a person
## does.) Until round 5 distances were divided by world_scale and the
## sources were not magnified with them: every call played 17.5 dB too quiet
## for a sparrow-sized player, and its reach shrank 7.5x (a songbird cut at
## 12 m, a crow at 27 m, a hawk at 40 m), so the Ecosystem's sky, 60 birds
## mostly 60-110 m out, was silent at the start sizes (the round-5 verifier
## heard 0 calls in 14 s at sparrow size). world_scale now only places the
## threatening predator's urgency floor (threat_floor_db), which is about
## how far the danger feels.
##
## Air absorption is set here from distance, never left to Godot's default.
## AudioStreamPlayer3D's own high shelf (attenuation_filter_db, -24 dB at
## 5 kHz out of the box) is (1 - gain) x its depth, where the gain includes
## the player's volume_db. Since the loudness levelling lives in volume_db,
## the default shelf dulled every loud clip up close: round 3 measured the
## wren, swallow and starling 10-14 dB under their level at their unit
## distance and a 27 dB small-bird spread at 25 m. Each voice's shelf depth
## is now air_absorption_db(distance) (ISO 9613-1 magnitudes), so
## a far call is duller as well as quieter, and a near one is not touched.
##
## The predator threatening the player is always heard: its calls skip the
## reach cut (wherever ThreatWatch names it) and start no quieter than a
## floor under its unit level (threat_floor_db, at the distance the player
## perceives),
## which rises as it closes in, so every new call from a closing hawk starts
## louder than the one before; within a call it grows by the distance law.
##
## Birds come and go (the Ecosystem recycles them, prey is eaten, Restart
## clears the sky). A voice never touches a bird that has left: on
## Events.bird_removed (emitted synchronously when the bird exits the tree,
## while it is still a valid object) its voices let go of it and fade out
## where it last was, and any call it had queued is dropped. Every access is
## also guarded by _present(), because a freed Object compares equal to null
## in Godot 4.7 (so `bird != null` cannot tell "no bird" from "freed bird")
## and a bird outside the tree has no global position.
##
## Only core contracts are used: Birds.all(), Bird fields, plus optional
## duck-typed NPC extras (state name, hidden, behaviour signal) when present.

const MAX_VOICES := 8
## A new call must be this much louder/more relevant than the weakest
## playing voice to steal it.
const STEAL_MARGIN_DB := 3.0
## Scheduling visits each bird about 5 times a second (call timers run in
## seconds), a few birds per frame in round-robin: never all 60 in one frame.
## Frames per full pass; per frame ceil(n / this) birds are visited.
const SCHEDULE_FRAMES := 12
const FADE_OUT := 0.05
## Fade of a voice whose bird has gone (eaten, despawned): short enough that
## an eaten bird falls silent under the crunch, long enough not to click.
const GONE_FADE := 0.12
## A predator closing in on the player is always heard (it outranks any
## bird in reach), the chased prey is favoured.
const THREAT_BOOST_DB := 20.0
const TARGET_BOOST_DB := 6.0
## The threatening predator's call starts at least threat_floor_db(d) loud
## relative to its unit-distance level, wherever it is: the one call the
## player must hear. THREAT_FLOOR_DB from THREAT_FLOOR_FAR perceived metres
## out (world metres / world_scale: how far the danger feels; -6 dB puts a
## hawk's scream well over the cruise wind: the suite measures it), rising
## THREAT_FLOOR_RISE_DB per halving of the distance closer in, up to the
## unit level. Round 4 found a flat floor: at sparrow scale every new call
## from 65 m down to 6 m started at the same -6 dB, so successive screams
## did not get louder as the hawk closed in ("predator screech getting
## louder", DESIGN). 1.5 dB per halving is a quarter of the free-field law:
## a gentle rise that keeps the far scream where it was. Since round 5 the
## natural level (world metres) takes over from about 30 m for a sparrow-
## sized player and grows by the free-field law up to the voice's ceiling.
const THREAT_FLOOR_DB := -6.0
const THREAT_FLOOR_FAR := 400.0
const THREAT_FLOOR_RISE_DB := 1.5
## Closer than the unit distance a call grows by at most this much (dB),
## and never past 0 dB of gain: eight birds at arm's length must not pile
## up past the limiter.
const NEAR_BOOST_DB := 6.0
## A-weighted short-term loudness assumed for effects played through the
## pool (the NPC catch crunch), for ranking them against calls.
const FX_LOUDNESS_DB := -12.0
## A call that would reach the ear quieter than this (A-weighted, its
## priority: audibility plus relevance) does not take a voice. Nothing that
## quiet is heard in flight (the cruise wind is about -43 dB A, the ambience
## beds -38 dB A at rest), and in the Ecosystem's sky, where every bird is
## in reach of one voice pool of 8, the calls fading out at the edges of
## their reach took voices only to be stolen by the next near one: fewer
## calls cut short (round 5; the edge of each reach loses its last 10-15%,
## a songbird about 76 m out rather than 90).
const MIN_CALL_DB := -62.0
## Air absorption: a high shelf at AIR_SHELF_HZ, AIR_DB_PER_M deeper per
## metre (world metres: the air absorbs, whoever listens), at most
## AIR_MAX_DB. In mild humid air (ISO 9613-1, 20 C, 70% RH) sound loses
## about 23 dB/km at 4 kHz and 77 dB/km at 8 kHz: 0.04 dB/m over the band
## above 5 kHz. A wren 25 m away loses 1 dB of its
## top octave, one at the edge of its reach (90 m) 3.6 dB. The engine scales
## the depth by (1 - the voice's gain at the ear): where it matters (far
## away) that gain is a few percent, so the heard depth is this value;
## close up it is lighter still. Written only when it moves AIR_STEP_DB.
const AIR_SHELF_HZ := 5000.0
const AIR_DB_PER_M := 0.04
const AIR_MAX_DB := 12.0
const AIR_STEP_DB := 0.25
## Share of each species' A-weighted loudness above AIR_SHELF_HZ (median of
## its clips): how much of its call the shelf acts on, so audibility()
## matches the mix at any distance (a wren's trill loses to the air what a
## crow's caw keeps). audio_calls_test measures the shipped clips and fails,
## printing the table, if an entry is off by more than 0.05.
const AIR_SHARE := {
	&"moth": 0.10, &"wren": 0.32, &"sparrow": 0.15, &"swallow": 0.67, &"starling": 0.01,
	&"pigeon": 0.00, &"crow": 0.00, &"gull": 0.00, &"hawk": 0.09, &"eagle": 0.00,
}
## Crowd normalisation: the Calls bus comes down by as much as the voices
## together would play louder than one voice at its full level (0 dB of
## gain at the ear, where a clip peaks at -3 dBFS): 10 log10 of the sum of
## the voices' power gains at the listener, when positive. A lone bird, or
## a flock far off, keeps its level; birds calling at arm's length add up to
## one full voice, not to the limiter. (Counting voices, 10 log10(n / 3)
## above three, left two or three loud ones alone: round 3 measured a hawk
## screaming 16 m away and a crow 11 m away, with the heart and the bell,
## at -1.3 dBFS before the limiter.)
const CROWD_FULL_DB := 0.0
## The crowd gain is written to the bus only when it has moved this much
## (or has landed on its target): smaller steps are inaudible.
const CROWD_STEP_DB := 0.05

## Per species: every = [min, max] s between calls at rest; loud = its
## A-weighted short-term loudness (dB, loudest 0.4 s) at the unit distance,
## on the Calls bus, both ears; unit/reach = world metres (unit level
## distance / cut-off), at every player size. The small birds sit within 1 dB of each other (the
## wren a touch louder, as wrens are; the swallow's twitter, most of it
## above 5 kHz, as loud as a sparrow's chirp up close, since the air takes
## more of it with distance), crows and gulls 2-5 dB over them from
## further away, raptors on top; the moth is a soft flutter heard only close
## up. A clip plays at most at 0 dB of gain (its peak, -3 dBFS, is the
## ceiling of one voice), so a call type quieter than its species' level
## (wren_3, a short soft chirp, 3.7 dB) stays that much quieter.
const VOICE := {
	&"moth": {"every": [0.0, 0.0], "loud": -35.5, "unit": 0.6, "reach": 5.0, "loop": true},
	&"wren": {"every": [4.0, 10.0], "loud": -22.0, "unit": 6.0, "reach": 90.0},
	&"sparrow": {"every": [3.0, 8.0], "loud": -23.0, "unit": 6.0, "reach": 90.0},
	&"swallow": {"every": [2.5, 7.0], "loud": -23.0, "unit": 6.0, "reach": 90.0},
	&"starling": {"every": [3.0, 9.0], "loud": -23.0, "unit": 7.0, "reach": 100.0},
	&"pigeon": {"every": [6.0, 14.0], "loud": -22.5, "unit": 8.0, "reach": 110.0},
	&"crow": {"every": [5.0, 12.0], "loud": -19.0, "unit": 15.0, "reach": 200.0},
	&"gull": {"every": [5.0, 12.0], "loud": -17.0, "unit": 16.0, "reach": 220.0},
	&"hawk": {"every": [10.0, 22.0], "loud": -14.0, "unit": 22.0, "reach": 300.0},
	&"eagle": {"every": [10.0, 22.0], "loud": -17.0, "unit": 22.0, "reach": 300.0},
}
## A-weighted short-term loudness of every call clip at 0 dB (dB, loudest
## 0.4 s; AudioAnalysis.loudness_aw), by clip name (AudioBank tags each
## stream with meta "clip"). audio_calls_test measures the shipped clips
## and fails if any entry is off by more than 0.3 dB, printing the table to
## paste here.
const CALL_LOUDNESS := {
	&"moth_flutter": -29.51,
	&"wren_1": -16.27, &"wren_2": -15.10, &"wren_3": -25.74,
	&"sparrow_1": -21.91, &"sparrow_2": -21.55, &"sparrow_3": -18.55,
	&"swallow_1": -16.54, &"swallow_2": -16.51, &"swallow_3": -16.86,
	&"starling_0": -7.82, &"starling_1": -8.51, &"starling_2": -9.65,
	&"pigeon_1": -12.05, &"pigeon_2": -13.23, &"pigeon_3": -13.75,
	&"crow_1": -17.00, &"crow_2": -17.56, &"crow_3": -18.75,
	&"gull_1": -10.29, &"gull_2": -14.27, &"gull_3": -14.49, &"gull_4": -16.63,
	&"hawk_1": -11.57, &"hawk_2": -11.57, &"hawk_3": -11.57,
	&"eagle_1": -16.88, &"eagle_2": -16.34, &"eagle_3": -13.90,
}


class Voice:
	extends RefCounted
	var player: AudioStreamPlayer3D
	## The bird this voice follows: null for fixed-position sounds and once
	## the bird has gone. Never a freed or out-of-tree bird (see forget()).
	var bird: Bird = null
	## True while the voice follows a bird. Kept apart from `bird` because a
	## freed Object compares equal to null: `bird != null` alone would take a
	## freed bird for "no bird" and never let go of it.
	var follows := false
	var species: StringName = &""
	var kind: StringName = &""  # call, loop, fx
	var prio := -INF
	var base_db := 0.0
	var fading := false
	var fade_t := 0.0
	var fade_len := FADE_OUT
	## A queued call (a steal waiting for this voice's fade), or {}. Holds
	## the caller's instance id, never the Bird itself: a queued caller can
	## be freed during the fade.
	var pending: Dictionary = {}
	## When the call began (CallVoices clock, s): playing() reports its age.
	var started := 0.0
	## Near-field ceiling (max_db) at full level, dB.
	var cap_db := 0.0
	var urgent := false
	## Air-absorption shelf depth last written to the player (dB).
	var air_db := 0.0
	## What an urgent voice adds to its level and ceiling to make up the
	## Calls bus's speed duck, as last written (dB, >= 0; 0 otherwise).
	var lift_db := 0.0

	func busy() -> bool:
		return player.playing or not pending.is_empty()


var bank: AudioBank
var voices: Array[Voice] = []
## World scale of the listener: only the threatening predator's urgency
## floor uses it (perceived metres = world / world_scale); every other
## distance is in world metres.
var world_scale := 1.0
var listener := Vector3.ZERO
## Bird that currently threatens the player / is its target (boosted).
var threat: Bird = null
var target: Bird = null
## False while paused/in menus: no new calls start (running ones finish).
var scheduling := true
## Counters for tests and the dev HUD.
var stats := {"started": 0, "stolen": 0, "dropped": 0, "quiet": 0, "fx": 0, "gone": 0, "crowd_writes": 0}

var _rng := RandomNumberGenerator.new()
var _next := {}  # instance_id -> time of next call
var _clock := 0.0
var _sched_i := 0
var _sched_frame := 0
## Frames ticked, and the crowd target as last computed (with the start
## count it saw): the summed gain and the shelves change slowly, so they
## are refreshed every SLOW_EVERY frames (the shelves staggered per voice)
## and the crowd target at once when a voice starts.
var _frame := 0
var _crowd_want := 0.0
var _crowd_seen := -1
const SLOW_EVERY := 4
var _moths := {}  # instance_id -> moth Bird in reach (checked with _present)
var _calls_bus := -1
var _connected := {}  # instance_id -> true (behaviour signal hooked)
var _last_scream := {}  # instance_id -> time
## Current crowd gain on the Calls bus, dB, and the value last written
## (crowd + speed duck; NAN: never written, so the first update sets the
## bus whatever an earlier director left on it).
var crowd_db := 0.0
var _crowd_applied := NAN
## Flight speed duck of every call (FlightSoundMap.calls_duck_db): its
## target, set by the director each frame, and the smoothed value applied.
var speed_duck_target_db := 0.0
var speed_duck_db := 0.0
## Cue duck of every call (dB, <= 0): while a reward or failure cue plays
## the calls step back with the flight layers. Set by the director (at once
## at the cue's onset, then back up smoothly).
var cue_duck_db := 0.0
## What the threatening predator's call adds over the wind's edge layer
## (FlightSoundMap.threat_call_lift_db, dB >= 0): its target, set by the
## director each frame, and the smoothed value applied (with the speed
## duck's time constant).
var edge_lift_target_db := 0.0
var edge_lift_db := 0.0


func setup(p_bank: AudioBank, seed_value: int = 7) -> void:
	bank = p_bank
	_rng.seed = seed_value
	if voices.is_empty():
		for i in MAX_VOICES:
			var v := Voice.new()
			v.player = AudioStreamPlayer3D.new()
			v.player.name = "Voice%d" % i
			v.player.bus = AudioBuses.CALLS
			v.player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			v.player.max_db = 0.0
			v.player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
			# Distance alone sets the shelf (_apply_air), not the gain.
			v.player.attenuation_filter_cutoff_hz = AIR_SHELF_HZ
			v.player.attenuation_filter_db = 0.0
			add_child(v.player)
			voices.append(v)


func _enter_tree() -> void:
	if not Events.bird_removed.is_connected(forget):
		Events.bird_removed.connect(forget)


func _exit_tree() -> void:
	if Events.bird_removed.is_connected(forget):
		Events.bird_removed.disconnect(forget)
	# Leave the shared Calls bus as we found it: a crowd gain left on it
	# would make every call of the next director (a reloaded scene) quieter.
	var bi := AudioServer.get_bus_index(AudioBuses.CALLS)
	if bi >= 0 and not is_nan(_crowd_applied) and _crowd_applied != 0.0:
		AudioServer.set_bus_volume_db(bi, 0.0)
	crowd_db = 0.0
	speed_duck_db = 0.0
	edge_lift_db = 0.0
	cue_duck_db = 0.0
	_crowd_applied = NAN
	_crowd_seen = -1


## True for a bird a voice may read: still allocated and inside the tree
## (get_body_position() of a node outside the tree is an engine error and
## returns the origin). Takes a Variant: assigning a freed object to a typed
## Bird variable is itself a script error.
static func _present(b: Variant) -> bool:
	return is_instance_valid(b) and (b as Node).is_inside_tree()


## Distance attenuation (dB) of this species' calls at distance d (world
## metres), relative to its unit distance, as Godot plays a voice: inverse
## distance (up to NEAR_BOOST_DB closer in) times the linear fade to the
## reach (max_distance). Leaving the fade out overrated a small bird near
## the edge of its reach by up to 10 dB against a crow at the same range.
static func distance_db(species: StringName, d: float) -> float:
	d = AudioInput.num(d, 1.0e9, 0.0, 1.0e9)
	var sp: Dictionary = VOICE.get(species, VOICE[&"sparrow"])
	var unit: float = sp["unit"]
	var inv := 20.0 * log(unit / maxf(d, unit * 0.5)) / log(10.0)
	var fade := 20.0 * log(maxf(1.0 - d / float(sp["reach"]), 1e-3)) / log(10.0)
	return inv + fade


## Loudness (dB, A-weighted short-term, both ears) a call of this species
## has at distance d (world metres) on the Calls bus: what ranks calls
## against each other. The suite checks it against the mixer at the unit
## distance and at 25 m for every species.
static func audibility(species: StringName, d: float) -> float:
	return float(VOICE.get(species, VOICE[&"sparrow"])["loud"]) + distance_db(species, d) \
		+ air_loss_db(species, d)


## Floor (dB relative to the species' unit level, <= 0) under the call of
## the predator threatening the player, at perceived distance d.
static func threat_floor_db(d_perceived: float) -> float:
	var d := AudioInput.num(d_perceived, THREAT_FLOOR_FAR, 0.01, 1.0e9)
	var rise := THREAT_FLOOR_RISE_DB * log(THREAT_FLOOR_FAR / d) / log(2.0)
	return clampf(THREAT_FLOOR_DB + rise, THREAT_FLOOR_DB, 0.0)


## Air-absorption shelf depth (dB, <= 0) above AIR_SHELF_HZ at distance d
## (world metres).
static func air_absorption_db(d: float) -> float:
	return -minf(AIR_MAX_DB, AIR_DB_PER_M * AudioInput.num(d, 1.0e9, 0.0, 1.0e9))


## Loudness this species' call loses to air absorption at distance d (world
## metres; dB, <= 0): the shelf acts on its AIR_SHARE of the power.
static func air_loss_db(species: StringName, d: float) -> float:
	var hf: float = AIR_SHARE.get(species, 0.0)
	var keep := 1.0 - hf + hf * pow(10.0, air_absorption_db(d) / 10.0)
	return 10.0 * log(maxf(keep, 1e-6)) / log(10.0)


## Volume (dB) that plays clip `stream` of a species at its VOICE.loud at
## the unit distance (its measured loudness taken out).
static func clip_gain_db(species: StringName, stream: AudioStream) -> float:
	var loud := float(VOICE.get(species, VOICE[&"sparrow"])["loud"])
	var clip: StringName = stream.get_meta(&"clip", &"") if stream else &""
	return loud - float(CALL_LOUDNESS.get(clip, loud))


## True for a bird whose call the player must hear: the predator that
## threatens the player, or one stooping at it (NpcBird.target).
func is_player_threat(b: Bird) -> bool:
	if b == null:
		return false
	if b == threat:
		return true
	var t: Variant = b.get("target")
	return _present(t) and t is Bird and (t as Bird).is_player()


## Distance from the listener, world metres (what every level uses).
func distance_m(pos: Vector3) -> float:
	return listener.distance_to(pos)


## Distance as the player's eyes judge it, world metres / world_scale:
## only the threatening predator's urgency floor uses it.
func perceived_distance(pos: Vector3) -> float:
	return listener.distance_to(pos) / maxf(world_scale, 0.01)


## Score of a call from bird b right now (dB + relevance boosts). A bird
## that threatens the player is scored at no less than its urgent floor
## (threat_floor_db under its unit level), where its voice will play it.
func priority(b: Bird) -> float:
	var pos := b.get_body_position()
	if not AudioInput.position_ok(pos):
		return -INF  # a glitching position: the weakest claim on a voice
	var p := audibility(b.species, distance_m(pos))
	if is_player_threat(b):
		p = maxf(p, float(VOICE.get(b.species, VOICE[&"sparrow"])["loud"]) + threat_floor_db(perceived_distance(pos)))
	if b == threat:
		p += THREAT_BOOST_DB
	elif b == target:
		p += TARGET_BOOST_DB
	return p


## Within its species' reach (world metres), or the threatening predator.
func in_reach(b: Bird) -> bool:
	if is_player_threat(b):
		return true
	var sp: Variant = VOICE.get(b.species)
	var reach: float = sp["reach"] if sp != null else 90.0
	return listener.distance_squared_to(b.get_body_position()) <= reach * reach


func active_count() -> int:
	var n := 0
	for v in voices:
		if v.busy():
			n += 1
	return n


## Re-scores the voices that follow a bird (they move; fixed-position
## effects keep the score they started with). A voice whose bird has gone
## lets go of it here too.
func _refresh_priorities() -> void:
	for v in voices:
		if not v.follows or v.fading or not v.player.playing:
			continue
		if not _present(v.bird):
			_let_go(v)
		else:
			v.prio = priority(v.bird)


## [{bird, species, kind, prio, age}] of the voices that are sounding.
## bird is a live Bird in the tree, or null (fixed-position effects); age is
## how long the call has played (s).
func playing() -> Array:
	_refresh_priorities()
	var out := []
	for v in voices:
		if v.player.playing and not v.fading:
			out.append({"bird": v.bird, "species": v.species, "kind": v.kind, "prio": v.prio, "age": _clock - v.started})
	return out


func tick(dt: float, p_listener: Vector3, p_world_scale: float) -> void:
	# Inputs that are not finite (or absurdly far) are not taken: the last
	# good listener and scale stand.
	dt = AudioInput.num(dt, 0.0, 0.0, 1.0)
	_clock += dt
	if AudioInput.position_ok(p_listener):
		listener = p_listener
	world_scale = AudioInput.num(p_world_scale, world_scale, 0.01, 100.0)
	_frame += 1
	for i in voices.size():
		_update_voice(voices[i], dt, (_frame + i) % SLOW_EVERY == 0)
	_update_crowd(dt)
	if not scheduling:
		return
	_schedule_batch()


## Gain (dB) Godot gives voice v at the listener: volume + inverse
## distance from the unit size, capped at max_db, times the linear fade to
## max_distance (AudioStreamPlayer3D's law, world metres).
func voice_gain_db(v: Voice) -> float:
	var d := maxf(listener.distance_to(v.player.global_position), 0.001)
	var att := minf(v.player.volume_db + 20.0 * log(v.player.unit_size / d) / log(10.0), v.player.max_db)
	return att + 20.0 * log(maxf(1.0 - d / maxf(v.player.max_distance, 0.001), 1e-5)) / log(10.0)


## The crowd normalisation the voices call for now (dB, <= 0), in
## CROWD_TARGET_STEP_DB steps: birds move all the time, and a target that
## crept with them would have the bus rewritten every frame.
const CROWD_TARGET_STEP_DB := 0.25


func crowd_target_db() -> float:
	var p := 0.0
	for v in voices:
		if v.player.playing:
			p += pow(10.0, voice_gain_db(v) / 10.0)
	var over := 10.0 * log(maxf(p, 1e-9)) / log(10.0) - CROWD_FULL_DB
	return -snappedf(over, CROWD_TARGET_STEP_DB) if over > 0.5 * CROWD_TARGET_STEP_DB else 0.0


## Writes the Calls bus now (a cue's onset: the duck must land with it).
func apply_bus_now() -> void:
	_update_crowd(0.0)


## The Calls bus gain: crowd normalisation (attack fast on a burst of
## calls, release slowly: no pumping) plus the flight speed duck (0.3 s)
## plus the cue duck (set by the director).
## The bus is written only when the gain has moved audibly or has landed,
## not on every frame of an asymptotic approach.
func _update_crowd(dt: float) -> void:
	if _frame % SLOW_EVERY == 0 or _crowd_seen != int(stats["started"]) or dt == 0.0:
		_crowd_want = AudioInput.num(crowd_target_db(), 0.0, -80.0, 0.0)
		_crowd_seen = stats["started"]
	var want := _crowd_want
	# The ducks come from the director (already finite); a state that is
	# not finite restarts from its target rather than staying stuck.
	speed_duck_target_db = AudioInput.num(speed_duck_target_db, 0.0, -80.0, 0.0)
	cue_duck_db = AudioInput.num(cue_duck_db, 0.0, -80.0, 0.0)
	crowd_db = lerpf(crowd_db, want, 1.0 - exp(-dt / (0.03 if want < crowd_db else 0.6)))
	if not is_finite(crowd_db) or absf(crowd_db - want) < 0.02:
		crowd_db = want
	speed_duck_db = lerpf(speed_duck_db, speed_duck_target_db, 1.0 - exp(-dt / 0.3))
	if not is_finite(speed_duck_db) or absf(speed_duck_db - speed_duck_target_db) < 0.02:
		speed_duck_db = speed_duck_target_db
	edge_lift_target_db = AudioInput.num(edge_lift_target_db, 0.0, 0.0, 12.0)
	edge_lift_db = lerpf(edge_lift_db, edge_lift_target_db, 1.0 - exp(-dt / 0.3))
	if not is_finite(edge_lift_db) or absf(edge_lift_db - edge_lift_target_db) < 0.02:
		edge_lift_db = edge_lift_target_db
	var total := crowd_db + speed_duck_db + cue_duck_db
	var landed := crowd_db == want and speed_duck_db == speed_duck_target_db
	if total == _crowd_applied or (absf(total - _crowd_applied) < CROWD_STEP_DB and not landed):
		return
	if _calls_bus < 0 or AudioServer.get_bus_name(_calls_bus) != AudioBuses.CALLS:
		_calls_bus = AudioServer.get_bus_index(AudioBuses.CALLS)
	if _calls_bus >= 0:
		AudioServer.set_bus_volume_db(_calls_bus, total)
		_crowd_applied = total
		stats["crowd_writes"] += 1


func _update_voice(v: Voice, dt: float, slow: bool = true) -> void:
	if v.fading:
		v.fade_t += dt
		var k := clampf(v.fade_t / v.fade_len, 0.0, 1.0)
		# The ceiling moves with the volume: a bird closer than its unit
		# distance plays at the ceiling, and a fade of the volume alone would
		# not be heard until it dropped below it.
		var f := linear_to_db(maxf(1.0 - k, 0.0001))
		v.player.volume_db = v.base_db + v.lift_db + f
		v.player.max_db = v.cap_db + v.lift_db + f
		if k >= 1.0:
			v.player.stop()
			v.fading = false
			v.bird = null
			v.follows = false
			v.prio = -INF
			if not v.pending.is_empty():
				var p := v.pending
				v.pending = {}
				_start(v, p)
		return
	if not v.player.playing:
		v.bird = null
		v.follows = false
		v.prio = -INF
		return
	if v.follows:
		# The bird left without Events.bird_removed reaching us (or was
		# eaten and is about to be removed): stay where it last was and fade.
		if not _present(v.bird) or not v.bird.alive:
			_let_go(v)
			return
		# A position that is not finite (a glitch) is not followed: the
		# voice holds where the bird last was until it makes sense again.
		var pos := v.bird.get_body_position()
		if AudioInput.position_ok(pos):
			v.player.global_position = pos
		if v.urgent:
			_apply_lift(v)
		if v.kind == &"loop" and not in_reach(v.bird):
			_fade(v)
	if slow:
		_apply_air(v)


## The voice's air-absorption shelf from its distance (the listener or the
## bird moved), written when it has moved AIR_STEP_DB.
func _apply_air(v: Voice, force: bool = false) -> void:
	var a := air_absorption_db(distance_m(v.player.global_position))
	if force or absf(a - v.air_db) > AIR_STEP_DB:
		v.air_db = a
		v.player.attenuation_filter_db = a


## The threatening predator's call is not ducked by flight speed: the
## rushing air of a dive masks ordinary calls (the Calls bus's speed duck),
## but this is the one the player must hear, fleeing in a dive above all
## (round 4: in a tucked 2.6x dive the hawk's scream sat 7 dB under the
## wind in its own band). Its voice makes up the bus's current speed duck,
## level and ceiling alike, and follows it (a scream that began in a dive
## must not jump 6 dB when the bird pulls out). Since round 5 it also rises
## over the wind's edge layer (edge_lift_db: the hiss that fills its band
## in a tucked dive, where it still sat at the wind's level). Headroom stays
## with the crowd rule, which counts the voice at that gain: a near scream
## lifted over a full voice brings the Calls bus down by as much.
func _apply_lift(v: Voice, force: bool = false) -> void:
	var lift := maxf(0.0, -speed_duck_db) + maxf(0.0, edge_lift_db)
	if force or absf(lift - v.lift_db) > 0.05:
		v.lift_db = lift
		v.player.volume_db = v.base_db + lift
		v.player.max_db = v.cap_db + lift


func _fade(v: Voice, seconds: float = FADE_OUT) -> void:
	if not v.fading:
		v.fading = true
		v.fade_t = 0.0
		v.fade_len = seconds


## The voice's bird has gone: the sound stays where the bird last was
## (the player's global_position is not touched again) and fades out.
func _let_go(v: Voice) -> void:
	v.bird = null
	v.follows = false
	stats["gone"] += 1
	_fade(v, GONE_FADE)


## Visits the next few birds (round-robin): starts calls whose timer has
## come, tracks moths in reach, hooks raptors' "stoop" behaviour.
func _schedule_batch() -> void:
	var all := Birds.all()
	var n := all.size()
	if n > 0:
		var batch := ceili(float(n) / SCHEDULE_FRAMES)
		for k in batch:
			_sched_i = (_sched_i + 1) % n
			_visit(all[_sched_i])
	_sched_frame += 1
	if _sched_frame >= SCHEDULE_FRAMES:
		_sched_frame = 0
		var moths: Array[Bird] = []
		for id in _moths.keys():
			var m: Variant = _moths[id]
			if _present(m) and m.alive and in_reach(m):
				moths.append(m)
			else:
				_moths.erase(id)
		_schedule_moths(moths)


func _visit(b: Bird) -> void:
	if not _present(b) or b.is_player():
		return
	var id := b.get_instance_id()
	if not b.alive:
		_next.erase(id)
		return
	if not _connected.has(id):
		_connected[id] = true
		if b.has_signal(&"behaviour") and not b.is_connected(&"behaviour", _on_behaviour):
			b.connect(&"behaviour", _on_behaviour)
	if b.species == &"moth":
		if in_reach(b):
			_moths[id] = b
		return
	if b.get("hidden") == true or not in_reach(b):
		_next.erase(id)
		return
	if not _next.has(id):
		# First heard: stagger so a flock does not call in unison.
		_next[id] = _clock + _rng.randf() * _interval(b)
		return
	if _clock >= float(_next[id]):
		_next[id] = _clock + _interval(b)
		request_call(b, 0.0, is_player_threat(b))


## A bird left the tree (Events.bird_removed: emitted from its _exit_tree,
## while it is still a valid object, whether it was removed, recycled or
## freed outright). Its voices let go of it and fade where it was; a call it
## had queued on another voice is dropped; its timers are forgotten.
func forget(b: Bird) -> void:
	var id := b.get_instance_id()
	for v in voices:
		if v.follows and v.bird == b:
			_let_go(v)
		if not v.pending.is_empty() and int(v.pending.get("bird_id", 0)) == id:
			v.pending = {}
			stats["dropped"] += 1
	_next.erase(id)
	_moths.erase(id)
	_connected.erase(id)
	_last_scream.erase(id)


## Seconds until this bird's next call: its species' pace, changed by what
## it is doing (duck-typed NPC state when available).
func _interval(b: Bird) -> float:
	var sp: Dictionary = VOICE.get(b.species, VOICE[&"sparrow"])
	var every: Array = sp["every"]
	var t := _rng.randf_range(every[0], every[1])
	var state := ""
	if b.has_method("state_name"):
		state = String(b.call("state_name"))
	if b.perched or state == "perched":
		t *= 0.7
	if state == "flee" or state == "hide":
		t *= 0.45
	if (state == "hunt" or state == "stoop") and b.species in [&"hawk", &"eagle", &"gull", &"crow"]:
		t *= 0.5
	if b == target:
		t *= 0.6
	return maxf(t, 0.8)


func _schedule_moths(moths: Array[Bird]) -> void:
	moths.sort_custom(func(a: Bird, c: Bird) -> bool:
		return listener.distance_squared_to(a.get_body_position()) < listener.distance_squared_to(c.get_body_position()))
	for m in moths.slice(0, 2):
		var has_voice := false
		for v in voices:
			if v.bird == m and v.kind == &"loop" and v.busy() and not v.fading:
				has_voice = true
		if not has_voice:
			var clips := bank.calls_for(&"moth") if bank else []
			if not clips.is_empty():
				_request(m, {"species": &"moth", "stream": clips[0], "kind": &"loop", "prio": priority(m),
					"db": clip_gain_db(&"moth", clips[0])})


## Asks for a call from bird b now. Returns true if it will sound (or is
## queued on a voice that is fading out for it). urgent: the bird threatens
## the player: no reach cut, and a floor under its level (threat_floor_db).
func request_call(b: Bird, boost_db: float = 0.0, urgent: bool = false) -> bool:
	if bank == null or not _present(b):
		return false
	var clips := bank.calls_for(b.species)
	if clips.is_empty():
		return false
	var stream: AudioStream = clips[_rng.randi() % clips.size()]
	return _request(b, {"species": b.species, "stream": stream, "kind": &"call",
		"prio": priority(b) + boost_db, "db": clip_gain_db(b.species, stream) + _rng.randf_range(-1.5, 1.0),
		"pitch": _pitch_for(b), "urgent": urgent or is_player_threat(b)})


## A one-shot at a fixed position (NPC catches), competing for voices like
## a call. species sets the distance model.
func play_fx(pos: Vector3, stream: AudioStream, db: float, species: StringName, pitch: float = 1.0) -> bool:
	if not AudioInput.position_ok(pos):
		stats["dropped"] += 1
		return false
	var prio := FX_LOUDNESS_DB + db + distance_db(species, distance_m(pos))
	stats["fx"] += 1
	return _request(null, {"pos": pos, "species": species, "stream": stream, "kind": &"fx", "prio": prio, "db": db, "pitch": pitch})


func _pitch_for(b: Bird) -> float:
	var nominal := AudioInput.num(SizeRules.species_data(b.species).get("mass", b.mass), 0.1, 0.0005, 1000.0)
	var size_k := clampf(pow(nominal / AudioInput.num(b.mass, nominal, 0.0005, 1000.0), 0.08), 0.88, 1.12)
	return size_k * _rng.randf_range(0.95, 1.05)


## Finds a voice for request r from bird b (null for a fixed-position
## effect at r.pos). The request itself only records the bird's instance id.
func _request(b: Bird, r: Dictionary) -> bool:
	var sp: Dictionary = VOICE.get(r["species"], VOICE[&"sparrow"])
	# A bird whose position is not finite (a glitch) is not given a voice.
	if b != null and not AudioInput.position_ok(b.get_body_position()):
		stats["dropped"] += 1
		return false
	r["bird_id"] = b.get_instance_id() if b != null else 0
	if r["kind"] != &"loop" and not r.get("urgent", false):
		var pos: Vector3 = b.get_body_position() if b != null else r["pos"]
		if distance_m(pos) > float(sp["reach"]):
			stats["dropped"] += 1
			return false
		if r["kind"] == &"call" and float(r["prio"]) < MIN_CALL_DB:
			stats["quiet"] += 1
			return false
	# A bird already speaking (or queued) does not start a second voice.
	if b != null:
		var id: int = r["bird_id"]
		for v in voices:
			if (v.bird == b and v.busy() and not v.fading) or (not v.pending.is_empty() and int(v.pending.get("bird_id", 0)) == id):
				return false
	for v in voices:
		if not v.busy():
			return _start(v, r)
	# A voice already fading out with nothing queued takes it next.
	for v in voices:
		if v.fading and v.pending.is_empty():
			v.pending = r
			return true
	# Otherwise the weakest voice, judged by what it will play next (a
	# queued steal counts at the queued call's priority, so a burst of
	# requests ends with the strongest ones, whatever their order). Playing
	# voices' priorities are refreshed here, only when a call competes.
	_refresh_priorities()
	var weakest: Voice = null
	var weakest_p := INF
	for v in voices:
		var p: float = v.pending["prio"] if not v.pending.is_empty() else v.prio
		if p < weakest_p:
			weakest_p = p
			weakest = v
	if weakest != null and float(r["prio"]) > weakest_p + STEAL_MARGIN_DB:
		if weakest.pending.is_empty():
			_fade(weakest)
		weakest.pending = r
		stats["stolen"] += 1
		return true
	stats["dropped"] += 1
	return false


## Starts request r on voice v. A queued request re-checks its bird: if the
## caller has gone during the fade the call is dropped and the voice stays
## free.
func _start(v: Voice, r: Dictionary) -> bool:
	var b: Bird = null
	var id: int = r.get("bird_id", 0)
	if id != 0:
		var o: Object = instance_from_id(id)
		if not _present(o) or not (o as Bird).alive or not AudioInput.position_ok((o as Bird).get_body_position()):
			stats["dropped"] += 1
			return false
		b = o as Bird
	v.bird = b
	v.follows = b != null
	v.species = r["species"]
	v.kind = r["kind"]
	v.prio = r["prio"]
	v.urgent = bool(r.get("urgent", false)) and b != null
	v.base_db = float(r.get("db", 0.0))
	v.cap_db = minf(v.base_db + NEAR_BOOST_DB, 0.0)
	v.lift_db = 0.0
	v.fading = false
	v.fade_len = FADE_OUT
	v.started = _clock
	v.player.stream = r["stream"]
	v.player.volume_db = v.base_db
	v.player.max_db = v.cap_db
	if v.urgent:
		_apply_lift(v, true)
	v.player.pitch_scale = r.get("pitch", 1.0)
	v.player.global_position = b.get_body_position() if b != null else r.get("pos", Vector3.ZERO)
	var sp: Dictionary = VOICE.get(v.species, VOICE[&"sparrow"])
	var unit := float(sp["unit"])
	var reach := float(sp["reach"])
	if v.urgent:
		# Wherever the predator is, its call starts at least
		# threat_floor_db (at the distance the player perceives) under its
		# unit level (Godot's law, world metres: unit / d, times the linear
		# fade 1 - d / max_distance) and grows as it closes in.
		var pos := b.get_body_position()
		var d0 := distance_m(pos)
		reach = maxf(reach, 4.0 * d0)
		var taper := 1.0 - d0 / reach
		unit = maxf(unit, d0 * db_to_linear(threat_floor_db(perceived_distance(pos))) / maxf(taper, 0.05))
	v.player.unit_size = unit
	v.player.max_distance = reach
	_apply_air(v, true)
	v.player.play()
	stats["started"] += 1
	return true


## Hawks and eagles scream when they start a stoop (NpcBird "behaviour").
func _on_behaviour(b: Bird, what: StringName) -> void:
	if not scheduling or what != &"stoop" or not (b.species in [&"hawk", &"eagle"]):
		return
	var id := b.get_instance_id()
	if _clock - float(_last_scream.get(id, -100.0)) < 6.0:
		return
	if request_call(b, 6.0, is_player_threat(b)):
		_last_scream[id] = _clock


func stop_all() -> void:
	for v in voices:
		v.player.stop()
		v.pending = {}
		v.fading = false
		v.bird = null
		v.follows = false
		v.prio = -INF
	_next.clear()
	_moths.clear()
	_crowd_seen = -1  # the crowd target is recomputed on the next update
