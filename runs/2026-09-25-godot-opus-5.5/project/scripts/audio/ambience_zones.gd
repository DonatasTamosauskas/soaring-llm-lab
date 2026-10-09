class_name AmbienceZones
extends Node
## Ambience per zone: a breeze in the trees (with a distant bird chorus),
## water, the village, the meadow (grass and crickets), open air (a soft
## breeze over rock and hills, also the floor anywhere else near the
## ground). Where the listener is decides each zone's weight, from the
## World's landmarks (forest, orchard, lake, town, meadow, ...); height above
## the ground fades every bed out (up in the sky only the wind remains).
## Beds are non-positional stereo loops crossfaded smoothly; a fully silent
## bed is paused so it costs no mixing. The village also gets a church bell,
## positioned in 3D.
##
## Levels: every bed sits at about the same loudness (about -38 dB
## A-weighted per ear at full weight), well under the calls and the wind.
## Flight speed ducks the whole ambience (FlightSoundMap.ambience_duck_db):
## perched or flying slowly the zone is heard in full; from cruise up the
## bird's own wind stands clearly above every bed, as in real flight, so the
## wind stays the main speed cue (tests/unit/audio: the wind is above each
## bed A-weighted and in the octave bands it carries).
##
## Without a World or landmarks (dev scenes) the quiet open-air bed plays
## near the ground.

const ZONES: Array[StringName] = [&"trees", &"water", &"village", &"meadow", &"open"]
## Landmark kind -> [zone, strength].
const KIND_ZONE := {
	"forest": [&"trees", 1.0], "orchard": [&"trees", 0.8], "glade": [&"trees", 0.7],
	"ride": [&"trees", 0.8], "hedgerow": [&"trees", 0.35], "hedge": [&"trees", 0.35],
	"lake": [&"water", 1.0], "river": [&"water", 1.0], "jetty": [&"water", 0.8], "bridge": [&"water", 0.6],
	"town": [&"village", 1.0], "village": [&"village", 1.0], "farm": [&"village", 0.55],
	"meadow": [&"meadow", 1.0], "field": [&"meadow", 0.8],
	"cliff": [&"open", 0.8], "canyon": [&"open", 1.0], "arch": [&"open", 0.5],
}
## Per zone: [[stream key, level dB at full weight], ...]. Each zone lands
## at about -38 dB A-weighted per ear (the clips differ: the meadow's
## crickets and grass are 9 dB louder to the ear than the village murmur at
## the same gain), so no zone jumps out and none disappears.
const BEDS := {
	&"trees": [[&"amb_leaves", -17.0], [&"amb_forest_birds", -16.0]],
	&"water": [[&"amb_water", -11.5]],
	&"village": [[&"amb_village", -10.5]],
	&"meadow": [[&"amb_meadow", -21.5]],
	&"open": [[&"amb_open", -13.5]],
}
## Open-air floor so low flight is never dead silent: a soft breeze (no
## insects: over rocks, cliffs and hills crickets would be wrong).
const FLOOR_ZONE := &"open"
const FLOOR_WEIGHT := 0.3
## Beds fade out between these heights above the ground (m).
const ALT_FULL := 12.0
const ALT_GONE := 80.0
const UPDATE_HZ := 4.0
## Gain smoothing time constant (s): zone changes crossfade, never jump.
const TAU := 1.2
const SLEEP_DB := -70.0
## The speed duck follows flight quickly when the air gets louder (a dive)
## and lets the world back in slowly when the bird slows down (s).
const DUCK_TAU_DOWN := 0.25
const DUCK_TAU_UP := 1.0
## The church bell, in world metres like the calls (CallVoices: sound
## follows the world, not the player's size; until round 5 its distances
## were divided by world_scale, which made it 18.5 dB quieter 30 m from the
## tower for a sparrow-sized player): BELL_DB within BELL_UNIT of the
## belfry (max_db caps it there: without the cap Godot's inverse-distance
## law boosts a near bell to its +3 dB default ceiling, the loudest sound in
## the game), falling 6 dB per doubling beyond, silent past BELL_REACH. -8 dB
## puts a stroke at the tower at about -9 dBFS peak on the Ambience bus:
## under the catch and caught cues, over the beds.
const BELL_DB := -8.0
const BELL_UNIT := 20.0
const BELL_REACH := 1200.0
const BELL_STROKES := 3
const BELL_STROKE_GAP := 2.3

var bank: AudioBank
var world: World = null
## Zone -> current target weight (0..1), for tests and the dev HUD.
var weights := {}
var _landmarks: Array[Dictionary] = []  # [{zone, strength, position, radius}]
var _bell_pos := Vector3.INF
var _players := {}  # key -> {player, level, gain (linear), target (linear), quiet_t}
var _acc := 0.0
var _bell: AudioStreamPlayer3D
var _bell_next := 20.0
var _bell_strokes := 0
var _bell_t := 0.0
var _bell_duck := INF
var _bell_air := 0.0
var _clock := 0.0
var _rng := RandomNumberGenerator.new()
var scheduling := true
## Current speed duck of every bed and the bell, dB (smoothed), and its
## target (tests and the dev HUD).
var duck_db := 0.0
var duck_target_db := 0.0


func setup(p_bank: AudioBank) -> void:
	bank = p_bank
	_rng.seed = 11
	for z in ZONES:
		weights[z] = 0.0
		for spec in BEDS[z]:
			var key: StringName = spec[0]
			var p := AudioStreamPlayer.new()
			p.name = "Bed_" + String(key)
			p.bus = AudioBuses.AMBIENCE
			p.volume_db = -80.0
			add_child(p)
			_players[key] = {"player": p, "level": float(spec[1]), "gain": 0.0, "target": 0.0, "quiet_t": 0.0, "zone": z}
	_bell = AudioStreamPlayer3D.new()
	_bell.name = "Bell"
	_bell.bus = AudioBuses.AMBIENCE
	_bell.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_bell.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	# Air absorption from distance, as the calls (CallVoices.air_absorption_db):
	# Godot's default shelf follows volume_db, and the bell's -8 dB cap and
	# the speed duck live there.
	_bell.attenuation_filter_cutoff_hz = CallVoices.AIR_SHELF_HZ
	_bell.attenuation_filter_db = 0.0
	_bell.unit_size = BELL_UNIT
	_bell.max_distance = BELL_REACH
	add_child(_bell)
	_apply_bell()


## Reads the zone landmarks once the world has generated.
func set_world(w: World) -> void:
	world = w
	_landmarks.clear()
	_bell_pos = Vector3.INF
	if w == null:
		return
	var town := Vector3.INF
	for lm in w.get_landmarks():
		# A landmark whose position or radius is not a finite number is
		# skipped: it would turn every zone weight into NaN.
		var pos: Variant = lm.get("position")
		if not (pos is Vector3 and AudioInput.position_ok(pos)):
			continue
		var kind := String(lm.get("kind", ""))
		var lm_name := String(lm.get("name", ""))
		if lm_name.contains("church"):
			_bell_pos = pos
		if kind == "town" and town == Vector3.INF:
			town = pos
		if KIND_ZONE.has(kind):
			var zs: Array = KIND_ZONE[kind]
			_landmarks.append({"zone": zs[0], "strength": zs[1], "position": pos,
				"radius": AudioInput.num(lm.get("radius", 30.0), 30.0, 0.0, 1.0e4)})
	if _bell_pos == Vector3.INF:
		_bell_pos = town


## Weight of one landmark at horizontal distance d: full inside ~85% of its
## radius, gone a margin beyond it (margin grows with size: big areas are
## heard from further away).
static func landmark_weight(d: float, radius: float) -> float:
	var inner := radius * 0.85
	var outer := radius + maxf(35.0, 0.35 * radius)
	return 1.0 - smoothstep(inner, outer, d)


static func altitude_factor(agl: float) -> float:
	return 1.0 - smoothstep(ALT_FULL, ALT_GONE, agl)


## Zone weights (0..1) at pos, agl metres above the ground.
func compute_weights(pos: Vector3, agl: float) -> Dictionary:
	var w := {}
	for z in ZONES:
		w[z] = 0.0
	for lm in _landmarks:
		var p: Vector3 = lm["position"]
		var d := Vector2(pos.x - p.x, pos.z - p.z).length()
		var v: float = lm["strength"] * landmark_weight(d, lm["radius"])
		if v > w[lm["zone"]]:
			w[lm["zone"]] = v
	var alt := altitude_factor(agl)
	var loudest := 0.0
	for z in ZONES:
		w[z] = w[z] * alt
		loudest = maxf(loudest, w[z])
	w[FLOOR_ZONE] = maxf(w[FLOOR_ZONE], FLOOR_WEIGHT * alt * (1.0 - loudest))
	return w


## Every frame. world_scale: the listener's (kept for callers; every
## distance here is in world metres); speed_duck_db:
## FlightSoundMap.ambience_duck_db of the player's flight (0 when perched,
## paused or in menus).
func tick(dt: float, listener: Vector3, _world_scale: float = 1.0, speed_duck_db: float = 0.0) -> void:
	# Inputs that are not finite are not taken (the director sanitises them
	# too): a bad listener keeps the last targets, a bad duck none.
	dt = AudioInput.num(dt, 0.0, 0.0, 1.0)
	_clock += dt
	_acc += dt
	if _acc >= 1.0 / UPDATE_HZ:
		_acc = 0.0
		_update_targets(listener)
	duck_target_db = AudioInput.num(speed_duck_db, 0.0, -80.0, 0.0)
	var kd := 1.0 - exp(-dt / (DUCK_TAU_DOWN if duck_target_db < duck_db else DUCK_TAU_UP))
	duck_db = lerpf(duck_db, duck_target_db, kd)
	if not is_finite(duck_db) or absf(duck_db - duck_target_db) < 0.02:
		duck_db = duck_target_db
	_step_beds(1.0 - exp(-dt / TAU), dt)
	_apply_bell(listener)
	_tick_bell(dt, listener)


## Zone weights at the listener and each bed's target gain.
func _update_targets(listener: Vector3) -> void:
	if not AudioInput.position_ok(listener):
		return
	var ground := world.ground_height(listener.x, listener.z) if world else 0.0
	# The ground unknown (not a finite number, or absurd): the zones keep
	# their weights.
	if not is_finite(ground) or absf(ground) > AudioInput.MAX_COORD:
		return
	weights = compute_weights(listener, listener.y - ground)
	for key in _players:
		var e: Dictionary = _players[key]
		e["target"] = float(weights[e["zone"]]) * db_to_linear(e["level"])


## Jumps every bed to its target at the listener (tests; a teleport or a
## respawn may call it so the new place is heard at once).
func settle(listener: Vector3) -> void:
	_update_targets(listener)
	duck_db = duck_target_db
	_step_beds(1.0, 0.0)  # k = 1: every gain lands on its target


## Moves each bed's gain by k towards its target and writes the player
## volume (gain + speed duck) when it has changed; sleeps silent beds.
func _step_beds(k: float, dt: float) -> void:
	for key in _players:
		var e2: Dictionary = _players[key]
		var p: AudioStreamPlayer = e2["player"]
		if p.stream == null:
			if bank and bank.has(key):
				p.stream = bank.get_stream(key)
			else:
				continue
		var g: float = e2["gain"]
		var tg: float = e2["target"]
		if g == 0.0 and tg == 0.0:
			continue  # asleep and staying asleep: no work
		g = lerpf(g, tg, k)
		if not is_finite(g):
			g = tg  # never stuck on a non-finite gain
		if tg == 0.0 and g < 1e-4:
			g = 0.0
		e2["gain"] = g
		var db := linear_to_db(maxf(g, 1e-5))
		if absf(db + duck_db - float(e2.get("db", 0.0))) > 0.02:
			e2["db"] = db + duck_db
			p.volume_db = db + duck_db
		if db < SLEEP_DB and linear_to_db(maxf(tg, 1e-5)) < SLEEP_DB:
			e2["quiet_t"] += dt
			if e2["quiet_t"] > 1.0 and p.playing:
				p.stream_paused = true
		else:
			e2["quiet_t"] = 0.0
			if not p.playing:
				# Start each bed at a random point so zones never line up.
				var st: AudioStream = p.stream
				p.play(_rng.randf() * st.get_length())
			elif p.stream_paused:
				p.stream_paused = false


## The bell's level with the speed duck and its air absorption (from its
## distance, world metres), each written only when it has moved.
func _apply_bell(listener: Vector3 = Vector3.INF) -> void:
	if _bell == null:
		return
	if AudioInput.position_ok(listener) and _bell_pos != Vector3.INF:
		var air := CallVoices.air_absorption_db(listener.distance_to(_bell_pos))
		if absf(air - _bell_air) > CallVoices.AIR_STEP_DB:
			_bell_air = air
			_bell.attenuation_filter_db = air
	if absf(duck_db - _bell_duck) > 0.1:
		_bell_duck = duck_db
		_bell.volume_db = BELL_DB + duck_db
		_bell.max_db = BELL_DB + duck_db


## Starts a toll now (three strokes) if the world has a belfry. The bell
## also tolls on its own every 45-80 s while the village is audible.
func toll() -> bool:
	if _bell_pos == Vector3.INF or bank == null or not bank.has(&"bell"):
		return false
	_bell_strokes = BELL_STROKES
	_bell_t = 0.0
	return true


## The church bell tolls three strokes every 45-80 s while the village is
## audible (and never starts while paused or in menus).
func _tick_bell(dt: float, _listener: Vector3) -> void:
	if _bell_pos == Vector3.INF or bank == null or not bank.has(&"bell"):
		return
	if _bell_strokes > 0:
		_bell_t -= dt
		if _bell_t <= 0.0:
			_bell_strokes -= 1
			_bell_t = BELL_STROKE_GAP
			_bell.global_position = _bell_pos
			_bell.stream = bank.get_stream(&"bell")
			_bell.pitch_scale = 1.0
			_bell.play()
		return
	if not scheduling:
		return
	if _clock >= _bell_next and float(weights.get(&"village", 0.0)) > 0.1:
		toll()
		_bell_next = _clock + _rng.randf_range(45.0, 80.0)
