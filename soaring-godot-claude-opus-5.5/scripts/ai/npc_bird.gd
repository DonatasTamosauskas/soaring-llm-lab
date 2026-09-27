class_name NpcBird
extends Bird
## A computer-controlled bird: body, flight and look. Its decisions live in
## NpcBrain; this node owns what the brain cannot fake:
##  * flight through NpcFlight, which obeys SizeRules.performance(mass), in
##    the air mass from World.get_wind (updrafts lift it, breezes drift it);
##  * never ending up under the ground, inside geometry or out of bounds;
##  * clinging to a Perch (one bird per perch) and hiding in a refuge;
##  * energy (flapping drains it, gliding and perching restore it) and hunger;
##  * driving its BirdModel (flap phase/amount, fold, bank, perched).
##
## Catches are not decided here: GameLoop owns the rule and calls
## on_caught/on_ate. NPCs only get close.
##
## Standalone (dev scenes, duel tests) the bird ticks itself in
## _physics_process. Inside an Ecosystem, `managed` is set and the ecosystem
## calls tick() so it can schedule level-of-detail rates for 60 birds.

signal state_changed(bird: NpcBird, old_state: int, new_state: int)
signal caught(bird: NpcBird, by: Bird)
signal ate(bird: NpcBird, prey: Bird)
## Behaviour milestones: "hunt", "stoop", "give_up", "flee", "jink",
## "refuge", "perch_go", "perch", "thermal", "thermal_top".
signal behaviour(bird: NpcBird, what: StringName)

enum State { WANDER, FLOCK, SOAR, PERCH, PERCHED, HUNT, STOOP, FLEE, HIDE }
const STATE_NAMES: Array[String] = ["wander", "flock", "soar", "perch", "perched", "hunt", "stoop", "flee", "hide"]

var model: BirdModel = null
var profile: Dictionary = {}
var flight: NpcFlight = null
var brain: NpcBrain = null
var habitat: Habitat = null
var flock: FlockGroup = null
var rng := RandomNumberGenerator.new()

var state: State = State.WANDER
var state_time := 0.0
## 0..1. Flapping drains it, gliding and perching restore it.
var energy := 1.0
## 0..1. Rises with time, reset by eating; drives hunting.
var hunger := 0.0
## Seconds of digesting left after a meal: no hunting, hunger does not rise
## (a raptor plucks and eats its catch; it does not kill again at once).
var digest := 0.0
## The bird this one is chasing (HUNT/STOOP) or null.
var target: Bird = null
## The predator this one is running from (FLEE/HIDE) or null.
var threat: Bird = null
var perch_spot: Perch = null
## The refuge this bird is heading for or hiding in: {position, radius, max_span}.
var refuge: Dictionary = {}
## True while tucked inside a refuge (unreachable for birds wider than it).
var hidden := false
## Centre of the area the bird wanders in (the ecosystem moves it with the player).
var home := Vector3.ZERO
var home_radius := 150.0
## 0 near, 1 mid, 2 far from the player: think/steer/feel less often when far.
var lod := 0
## True when an Ecosystem ticks this bird.
var managed := false
## Predators currently chasing this bird (they force it to full tick rate).
var pursuers := 0
## Set by NpcBrain: world geometry was seen nearby recently.
var near_geometry := false
## Safety sweep against layer 1 on every move (tests turn it on everywhere).
var always_sweep := false
## Turn off to make a prey that ignores predators (duel tests, A2).
var can_flee := true
## Turn off to make a bird that never starts a hunt.
var can_hunt := true
## Extra interest in the player as prey, and how much further than its hunt
## range it keeps an eye on it (1 = the player is just another bird). The
## Ecosystem raises both for the threats it places around the player: they
## are there because they have noticed it.
var player_interest := 1.0
var player_range := 1.0

## The prey this bird is striking at this tick (set by the brain while
## hunting): within strike_reach() it reaches out with feet/beak.
var strike: Bird = null

# --- Steering outputs, written by NpcBrain ---
var want_dir := Vector3.FORWARD
var want_speed := 9.0
var max_effort := 1.0
var want_fold := 0.0
## 0..1: brake hard (NpcFlight.air_brake) - an obstacle too close to turn off.
var want_brake := 0.0
## Fraction of its turn rate the brain lets the body use (NpcFlight.turn_scale).
var want_turn := 1.0

# --- Counters (stats, tests) ---
var catches := 0
## Every clamp of the body (geometry, ground, bounds; the stuck watchdog).
var bumps := 0
## Contacts the safety net had to resolve, by kind: the body's sweep or
## push-out against world geometry (not the perch or cover it meant to
## touch), the ground clamp, the arena bounds/ceiling clamp. Obstacle
## avoidance, ground clearance and bounds steering exist to keep these
## near zero (tests/unit/ai/avoidance_test.gd pins them).
var geo_hits := 0
var ground_hits := 0
var bounds_hits := 0
## Ticks in which the strike lunge moved the body (diagnostics: envelope
## measurements skip windows with it - it is a throw of the body, not flight).
var lunges := 0
## Where and how the body last hit geometry (diagnostics).
var last_hit := Vector3.ZERO
var last_hit_normal := Vector3.ZERO
var age := 0.0

var _acc_dt := 0.0
var _skip := 0
## Calm birds integrate every 2nd or 3rd tick; this bird's phase (1-6, set
## by the Ecosystem as it spawns the bird, set_tick_phase; 0: none or
## used), applied once, at its first full tick as a calm bird (never to one
## near geometry or landing), so birds
## spawned in the same tick - a whole sky at a new run - do not all
## integrate on the same ticks (integration round 1, the Quest verifier:
## even ticks cost 0.84 ms, odd ones 0.50).
var _stagger := 0
const STAGGER_AFTER_S := 1.0


## The Ecosystem's tick phase for a bird it spawns (see _stagger): k >= 0.
## Birds outside an Ecosystem (tests' loose birds) keep the plain phase.
func set_tick_phase(k: int) -> void:
	_stagger = 1 + absi(k) % 6
# Landing flare (see flare_to)
var _flaring := false
var _flare_from := Vector3.ZERO
var _flare_to := Vector3.ZERO
var _flare_face := Vector3.FORWARD
var _flare_t := 0.0
var _flare_T := 1.0
var _flare_done: Callable
var _flare_linear := false
# Displayed body attitude: yaw about +Y (0 = beak towards -Z) and pitch
# (nose up > 0). The node never rolls (BirdModel draws the bank). It turns
# towards the flight attitude at a bounded rate (BODY_TURN_MAX), so nothing
# the physics does discontinuously - a take-off, a bump, a flare leg,
# settling on a perch - can flip the body in one frame (seen up close in VR).
var _vis_yaw := 0.0
var _vis_pitch := 0.0
var _vis_ok := false
## The basis of the displayed attitude, reused while it does not change.
var _vis_basis := Basis.IDENTITY
var _vis_basis_ok := false
## Facing (yaw) of the perch the bird sits on; the body settles onto it.
var _perch_yaw := 0.0
## Fastest the displayed body turns, rad/s (per axis): 8 deg per 72 Hz frame.
## Well above what flight itself asks for (a sparrow's tightest turn is
## ~5 rad/s), so it only ever smooths discontinuities.
const BODY_TURN_MAX := 10.0
## Seconds of flight the body's collision ray looks ahead (see _resolve).
const IMMINENT_S := 0.3
## Seconds between a bird's samples of the air (see _fly).
const WIND_S := 1.0 / 24.0
## Strike reach in wingspans (see strike_reach()).
const STRIKE_SPANS := 0.5
## Seconds a sparrow-sized bird digests after a catch (scaled by body time).
const DIGEST_S := 12.0
## Flares and take-offs so far (diagnostics: envelope measurements skip
## windows with these kinematic manoeuvres).
var flares := 0
var _flap_phase := 0.0
var _flap_amount := 0.0
var _burst := 0.0
var _pause := 0.0
var _ignore_near := Vector3.INF
var _ignore_r := 0.0
var _contact_r := 0.0
## The contact target is a grip point landed on from above (a perch): the
## body may touch geometry there only while its centre stays above it.
var _contact_above := false
var _pos := Vector3.ZERO
## Height above ground at the last full tick (coasting is only allowed high up).
var _agl := 0.0
## Ground sample cache (see _ground_at).
var _g_xz := Vector2.INF
var _g_y := 0.0
const GROUND_CACHE_AGL := 6.0
const GROUND_CACHE_M := 2.0
var _wd_t := 0.0
var _wd_pos := Vector3.INF
var _wd_pos2 := Vector3.INF
var _wd_free := false
var _wd_bumps := 0
var _wd_geo := 0
## Geometry contacts in one 2.5-s watchdog period that mean "trapped".
const WEDGED_HITS := 6
## Watchdog periods in a row that found the bird stuck or wedged. The first
## asks the brain to steer out (NpcBrain.unstick); if that has not worked by
## the next check, the bird backs out the way it came (escape()).
var _wd_strikes := 0
## Times escape() was needed, and when the last one was (age, s).
var escapes := 0
var _escape_at := -999.0
## Breadcrumbs: where the body was recently clear of geometry (oldest
## first), one every TRAIL_S of free flight. A pocket among overlapping
## tree crowns can be flown into and not steered out of - every direction
## an unstick probe tries is blocked within a metre, and the ground
## clearance overlay keeps pressing up into the crown overhead (a tired hawk
## ground there for 160 s) - but the way in is always a way out.
var _trail: Array[Vector3] = []
var _trail_t := 0.0
const TRAIL_S := 0.3
const TRAIL_N := 16
## A flare leg that is an escape starts in contact with what the bird is
## wedged against: its per-step sweep check is waived for this far (m).
var _flare_free_d := 0.0
var _caught_done := false
var _wind := Vector3.INF
var _wind_age := 0.0
## Profile values read every tick, cached (see configure / _on_mass_changed).
var _style := "flap"
var _flap_hz := 8.0
var _hunger_rate := 0.0
## Endurance relative to a sparrow (see _metabolism).
var _endurance := 1.0


## Set species, mass and seed. Call before adding to the tree (or after, to
## re-use a pooled bird).
func configure(p_species: StringName, p_mass: float = -1.0, seed_value: int = 1, p_habitat: Habitat = null) -> void:
	species = p_species
	profile = SpeciesProfile.of(species)
	var base: float = SizeRules.species_data(species).get("mass", 0.03)
	mass = p_mass if p_mass > 0.0 else base
	rng.seed = seed_value
	if p_habitat:
		habitat = p_habitat
	flight = NpcFlight.new(mass, profile["glide_ratio"])
	_endurance = pow(maxf(mass, 0.001) / 0.03, 0.25)
	_style = String(profile.get("style", "flap"))
	_flap_hz = SpeciesProfile.flap_hz(mass)
	_hunger_rate = float(profile["hunger_rate"])
	flight.set_velocity(Vector3(0, 0, -flight.cruise))
	brain = NpcBrain.new(self)
	alive = true
	_caught_done = false
	visible = true
	perched = false
	hidden = false
	energy = rng.randf_range(0.6, 1.0)
	hunger = rng.randf_range(0.0, 0.6)
	digest = 0.0
	state = State.WANDER
	state_time = 0.0
	target = null
	threat = null
	pursuers = 0
	age = 0.0
	if model == null or model.species != species:
		if model:
			model.queue_free()
		model = BirdModels.create(species)
		add_child(model)
	model.scale = Vector3.ONE * get_wingspan()
	_flap_phase = rng.randf()
	# Whoever places the bird next sets its transform; the displayed attitude
	# is read back from it on the first tick, which is always a full one.
	_vis_ok = false
	_skip = 1 << 20
	_stagger = 0
	_acc_dt = 0.0
	_wind = Vector3.INF
	# Not measured until its first move (the brain reads it before then).
	_agl = 1000.0
	_trail.clear()
	_trail_t = 0.0
	_g_xz = Vector2.INF
	_wd_strikes = 0
	escapes = 0
	_escape_at = -999.0


func _ready() -> void:
	if habitat == null:
		habitat = Habitat.for_world(World.find(get_tree()))
	if flight == null:
		configure(species, mass, get_instance_id())
	brain.habitat = habitat
	set_physics_process(not managed)
	_pos = global_position


func _physics_process(delta: float) -> void:
	if not managed:
		tick(delta)


func is_engaged() -> bool:
	return state == State.HUNT or state == State.STOOP or state == State.FLEE or pursuers > 0


## Advance the bird by dt seconds (called by the Ecosystem or _physics_process).
func tick(dt: float) -> void:
	if not alive:
		return
	# Calm birds in open air integrate at 36 Hz (far ones at 24 Hz) and
	# coast in between (positions still move every tick; the model animates
	# every frame in its own _process): calm flight needs no more, and 60
	# birds must fit 2 ms a tick in the valley too. Engaged ones only when
	# far from the player and while the bird they chase or flee is still far
	# off - the close fight (strike, break) runs at full rate, and so does
	# anything near geometry (its collision sweep) or landing.
	var every := 1
	if not near_geometry and not _flaring:
		if not is_engaged():
			every = 3 if lod >= 2 else 2
		elif lod > 0 and brain.fight_far():
			every = lod + 1
	_acc_dt += dt
	_skip += 1
	if _skip < every:
		# Skipped tick: coast along the current velocity so far birds still
		# move smoothly (it costs one transform write). Only calm birds away
		# from geometry ever skip. A bird skimming low over a field coasts
		# too, held above the ground (otherwise it would move only every 2nd
		# or 3rd tick, at a fraction of its speed).
		if not (perched or hidden):
			# From where the node is (whoever placed it last), not a cached
			# position: a bird the ecosystem just placed must not coast from
			# where it was created.
			_pos = global_position + velocity * dt
			if _agl <= 3.0:
				var g := habitat.ground(_pos.x, _pos.z)
				_pos.y = maxf(_pos.y, g + get_body_radius())
				_agl = _pos.y - g
			# The body keeps turning towards its flight attitude every tick
			# (at most BODY_TURN_MAX x the tick), not in steps of two ticks.
			_pose(_pos, _body_pitch(), flight.psi, dt)
		elif perched:
			_settle(dt)
		return
	var dt_tick := dt
	dt = _acc_dt
	_acc_dt = 0.0
	_skip = 0
	if _stagger > 0 and every > 1 and age >= STAGGER_AFTER_S:
		# The phase offset, once, and only for a calm bird that may skip,
		# once it has lived a moment (a new bird has not yet sensed what is
		# round it: delayed at spawn, a hawk placed in a crown pocket coasted
		# a tick deeper into the branches and stuck; one near geometry or
		# landing integrates every tick). Evenly over the phases of both
		# rates (6 draws: 2 and 3 both divide it).
		_skip = -((_stagger - 1) % every)
		_stagger = 0
	age += dt
	state_time += dt
	_pos = global_position
	_metabolism(dt)
	_watchdog(dt)
	brain.update(dt)
	if not alive:
		return
	if perched or hidden:
		velocity = Vector3.ZERO
		if perched:
			_settle(dt_tick)
	elif _flaring:
		# In real time from the tick it starts on (a flare can begin on a tick
		# that also integrates a skipped one): the body turns per tick.
		_flare(dt_tick)
	else:
		# Dynamics over the whole interval, displacement over this tick only
		# (the skipped ticks already coasted).
		if NpcBrain.prof_on:
			var t0 := Time.get_ticks_usec()
			_fly(dt, dt_tick)
			NpcBrain.prof_us[3] += Time.get_ticks_usec() - t0
		else:
			_fly(dt, dt_tick)
	_animate(dt)


## Every 2.5 s: a free-flying bird that moved < 2 m over the last 5 s is
## trapped somewhere; the brain steers it out, and if it is still trapped at
## the next check it backs out along its breadcrumbs (escape()).
func _watchdog(dt: float) -> void:
	_wd_t += dt
	if _wd_t < 2.5:
		return
	_wd_t = 0.0
	var free := not (perched or hidden or _flaring)
	# Stuck: hardly moved for 5 s. Wedged: grinding against geometry (a
	# crevice) - many collisions a second even though it still slides.
	# (Geometry contacts alone: a bird bouncing between the walls of a yard
	# or a room it cannot find its way out of - ground and bounds clamps do
	# not count.)
	var wedged := bumps - _wd_bumps > 40 or geo_hits - _wd_geo > WEDGED_HITS
	if free and _wd_free and (wedged or (_wd_pos.distance_to(_pos) < 2.0 and _wd_pos2.distance_to(_pos) < 2.0)):
		_wd_strikes += 1
		if _wd_strikes < 2 or not escape():
			brain.unstick()
	elif not _flaring:
		_wd_strikes = 0
	_wd_pos2 = _wd_pos
	_wd_pos = _pos
	_wd_free = free
	_wd_bumps = bumps
	_wd_geo = geo_hits


## True once three watchdog checks in a row found the bird trapped: the
## brain's unstick and the escape along its trail have both been tried (or
## there was no trail to back out along). The Ecosystem then takes it out
## of play, out of the player's view - the last resort.
func trapped() -> bool:
	return _wd_strikes >= 3


## Back out the way the bird came: a kinematic leg to the newest breadcrumb
## at least a couple of wingspans away whose straight line is clear, then on
## along that direction under the brain's steering (NpcBrain.after_escape).
## Returns false if no breadcrumb qualifies.
func escape() -> bool:
	if habitat == null or _trail.is_empty():
		return false
	_pos = global_position
	var r := get_body_radius()
	var min_d := maxf(2.0, get_wingspan() * 2.0)
	for i in range(_trail.size() - 1, -1, -1):
		var q: Vector3 = _trail[i]
		var d := q.distance_to(_pos)
		if d < min_d:
			continue
		var dir := (q - _pos) / d
		# The centre line out must be clear, and so must the body once it has
		# left the contact it is wedged in (the first body radius or so).
		if not habitat.ray(_pos, q).is_empty():
			continue
		var back := habitat.ray(q, _pos)
		if not back.is_empty() and (back["position"] as Vector3).distance_to(_pos) > r:
			continue
		if not habitat.sweep_clear(_pos + dir * minf(r * 1.5, d * 0.5), q, r * 0.6):
			continue
		escapes += 1
		_escape_at = age
		_wd_strikes = maxi(_wd_strikes, 2)
		_trail.resize(i)
		var away := dir
		brain.before_escape()
		flare_to(q, away, func() -> void:
			if alive:
				var h := Vector3(away.x, maxf(away.y, 0.0), away.z)
				if h.length_squared() < 0.04:
					h = heading_dir()
				flight.set_velocity(h.normalized() * maxf(flight.min_speed * 1.2, flight.v_min_power))
				brain.after_escape(h.normalized()), true)
		_flare_free_d = r * 1.5 + 0.05
		behaviour.emit(self, &"escape")
		return true
	return false


func _metabolism(dt: float) -> void:
	var resting := perched or hidden
	var e := 0.0 if resting else flight.effort
	var gain := 0.0
	if resting:
		gain = 0.09
	elif e < 0.05:
		gain = 0.012
	# Endurance grows with size: reserves scale with mass, power with
	# mass^0.75 (Kleiber), so a bird twice as heavy lasts ~1.2x as long at
	# the same effort - in a long chase between near-equals the prey tires
	# first.
	var drain := (0.008 * e + 0.03 * e * e * e) / _endurance
	energy = clampf(energy + (gain - drain) * dt, 0.0, 1.0)
	if digest > 0.0:
		digest -= dt
	else:
		hunger = minf(1.0, hunger + _hunger_rate * dt)


## Cap on flapping power from fatigue: an exhausted bird cannot sprint, but
## it can always still hold level flight (and so reach a perch to rest).
func effort_cap() -> float:
	return clampf(0.35 + energy * 1.5, minf(flight.p_min_frac + 0.2, 1.0), 1.0)


func _fly(dt: float, move_dt: float = -1.0) -> void:
	if move_dt < 0.0:
		move_dt = dt
	var pos := _pos
	# The air is sampled at ~24 Hz per bird, not every tick: it varies over
	# metres (a thermal is tens of metres across) and a bird covers under a
	# metre in 1/24 s. (World.get_wind is one of the costlier calls.)
	_wind_age += dt
	if _wind_age >= WIND_S or _wind == Vector3.INF:
		_wind = habitat.wind(pos)
		_wind_age = 0.0
	var wind := _wind
	var wd := want_dir
	if wd.length_squared() < 1e-8:
		wd = flight.dir()
	# Crab into the breeze: aim the airspeed so the ground track follows want_dir.
	var air_want := wd.normalized() * want_speed - Vector3(wind.x, 0.0, wind.z)
	flight.air_brake = want_brake
	flight.turn_scale = want_turn
	var pt0 := Time.get_ticks_usec() if NpcBrain.prof_on else 0
	flight.step(dt, air_want, want_speed, minf(max_effort, effort_cap()), want_fold)
	velocity = flight.air_velocity() + wind
	var np := pos + velocity * move_dt
	if strike != null:
		np = _strike(np, move_dt)
	var pt1 := Time.get_ticks_usec() if NpcBrain.prof_on else 0
	np = _resolve(pos, np, wind)
	var pt2 := Time.get_ticks_usec() if NpcBrain.prof_on else 0
	_pose(np, _body_pitch(), flight.psi, move_dt)
	if NpcBrain.prof_on:
		NpcBrain.prof_us[4] += pt1 - pt0
		NpcBrain.prof_us[5] += pt2 - pt1
		NpcBrain.prof_us[6] += Time.get_ticks_usec() - pt2
	_pos = np
	_trail_t += dt
	if _trail_t >= TRAIL_S:
		_trail_t = 0.0
		# Clear with a margin (in open air - nothing felt nearby - it is).
		if not near_geometry or not habitat.blocked(np, get_body_radius() * 1.3):
			_trail.append(np)
			if _trail.size() > TRAIL_N:
				_trail.pop_front()


## Finish turning onto the perch's facing (small birds hop round), at most
## BODY_TURN_MAX x dt per axis - every tick, skipped ticks included.
func _settle(dt: float) -> void:
	if absf(_vis_pitch) > 1e-3 or absf(wrapf(_perch_yaw - _vis_yaw, -PI, PI)) > 1e-3:
		_pose(_pos, 0.0, _perch_yaw, dt)


## Place the body at pos, turning the displayed attitude towards (pitch,
## yaw) by at most BODY_TURN_MAX x dt per axis.
## The body's displayed pitch in flight: along the flight path, except that
## a bird coming in to a perch holds its body no steeper than
## APPROACH_PITCH_MIN nose-down whatever its descent (it drops in with the
## wings, not beak first - and the flare it goes into from there is held
## at +-0.5 rad: integration round 1 found a steep descent onto a low perch
## entering its flare 45 deg nose-down).
func _body_pitch() -> float:
	var g := clampf(flight.gamma, -1.25, 1.25)
	if state == State.PERCH:
		return maxf(g, APPROACH_PITCH_MIN)
	return g


const APPROACH_PITCH_MIN := -0.5


func _pose(pos: Vector3, pitch: float, yaw: float, dt: float) -> void:
	if not _vis_ok:
		_sync_vis()
	if absf(pitch - _vis_pitch) < 1e-4 and absf(wrapf(yaw - _vis_yaw, -PI, PI)) < 1e-4 and _vis_basis_ok:
		# Attitude unchanged (straight flight, a perched bird): only the
		# position moves - no trigonometry for a new basis.
		global_transform = Transform3D(_vis_basis, pos)
		return
	var step := BODY_TURN_MAX * dt
	_vis_yaw = wrapf(_vis_yaw + clampf(wrapf(yaw - _vis_yaw, -PI, PI), -step, step), -PI, PI)
	_vis_pitch += clampf(pitch - _vis_pitch, -step, step)
	_vis_basis = Basis.from_euler(Vector3(_vis_pitch, _vis_yaw, 0.0))
	_vis_basis_ok = true
	global_transform = Transform3D(_vis_basis, pos)


## Read the displayed attitude back from the node (after someone placed it).
func _sync_vis() -> void:
	var fwd := -global_basis.z
	if fwd.x * fwd.x + fwd.z * fwd.z > 1e-8:
		_vis_yaw = atan2(-fwd.x, -fwd.z)
	elif flight:
		_vis_yaw = flight.psi
	_vis_pitch = asin(clampf(fwd.y, -1.0, 1.0))
	_vis_ok = true
	_vis_basis_ok = false


## Height of the body above the ground at its last full tick.
func agl() -> float:
	return _agl


## Beak direction of the displayed body, horizontal.
func heading_dir() -> Vector3:
	if not _vis_ok:
		_sync_vis()
	return Vector3(-sin(_vis_yaw), 0.0, -cos(_vis_yaw))


## How far ahead a hunting bird can reach for its prey: the envelope in
## which it throws its body at it in the last instant (talons swung forward,
## a lunge of the neck; see _strike), never under 25 cm (a wren's snap at a
## moth). Pursuit steering alone leaves a miss of a few tenths of a metre at
## closing speeds of several m/s; the lunge covers that.
func strike_reach() -> float:
	return maxf(0.25, get_wingspan() * STRIKE_SPANS)


## How fast the body can be thrown sideways in the lunge, m/s: a raptor's
## legs sweep ~0.4 m in ~0.1 s, a sparrow's head snaps a few centimetres.
## Practised hunters strike deftly (hawk, eagle, swallow); generalists
## that take a bird now and then (gull, starling, pigeon) less so.
func strike_speed() -> float:
	return 2.5 * sqrt(get_wingspan()) * (1.0 + 0.6 * flight.agility) * (0.6 + 0.4 * float(profile.get("hunt", 0.5)))


## The final lunge: when the prey is just ahead, the hunter shifts its body
## sideways towards it at a limited speed (a raptor throwing its feet
## forward, a swallow snapping at a moth). It fixes the last few centimetres
## that flight control alone cannot, but not a real jink: that moves the
## prey metres sideways in the same time.
func _strike(np: Vector3, dt: float) -> Vector3:
	if not is_instance_valid(strike) or not strike.alive or not strike.is_inside_tree():
		strike = null
		return np
	var tp := strike.get_body_position() + strike.velocity * dt
	var rel := tp - np
	var d := rel.length()
	var vl := velocity.length()
	if d > strike_reach() or vl < 0.5:
		return np
	var vdir := velocity / vl
	var along := rel.dot(vdir)
	if along < -get_body_radius():
		return np
	var lat := rel - vdir * maxf(along, 0.0)
	var max_move := strike_speed() * dt
	if lat.length_squared() > 1e-8:
		lunges += 1
	return np + lat.limit_length(max_move)


## Ground height under p. The world's terrain lookup is one of the dearer
## calls a bird makes every tick; well above the ground (> GROUND_CACHE_AGL)
## the height sampled within GROUND_CACHE_M is reused - even a 45-degree
## slope rises less than that margin over that distance - and close to the
## ground it is sampled every time (the clamp must be exact there).
func _ground_at(p: Vector3) -> float:
	if _agl > GROUND_CACHE_AGL and Vector2(p.x - _g_xz.x, p.z - _g_xz.y).length_squared() < GROUND_CACHE_M * GROUND_CACHE_M:
		return _g_y
	_g_y = habitat.ground(p.x, p.z)
	_g_xz = Vector2(p.x, p.z)
	return _g_y


## Keep the move out of the ground, geometry and out-of-bounds.
func _resolve(pos: Vector3, np: Vector3, wind: Vector3) -> Vector3:
	var r := get_body_radius()
	if near_geometry or always_sweep:
		var mv := np - pos
		var ml := mv.length()
		if ml > 1e-6:
			# The same ray looks IMMINENT_S of flight ahead (no extra query):
			# a surface the bird would reach in that time, though not this
			# tick, makes it brake and turn now (NpcBrain.on_imminent) -
			# what a bird does when a wall looms out of a turn.
			var reach := maxf(ml, velocity.length() * IMMINENT_S) + r
			var hit := habitat.ray(pos, pos + mv / ml * reach)
			if not hit.is_empty():
				var hp: Vector3 = hit["position"]
				var n: Vector3 = hit["normal"]
				var ignored := _contact_ok(hp, np)
				# The terrain itself is handled exactly by the ground clamp below;
				# sweeping against it too would snag low fliers on every facet.
				if n.y > 0.6 and absf(hp.y - habitat.ground(hp.x, hp.z)) < 0.25:
					ignored = true
				if not ignored and hp.distance_to(pos) > ml + r:
					ignored = true
					if not _flaring:
						brain.on_imminent(hp, n)
				if not ignored:
					# Stop short of the surface and keep only the tangential
					# motion, so glancing hits slide along walls and wires.
					var stop := maxf(hp.distance_to(pos) - r - 0.02, 0.0)
					np = pos + mv / ml * stop
					var v := velocity - n * minf(velocity.dot(n), 0.0) * 1.1
					if v.length() < flight.min_speed:
						v = (v + n * flight.min_speed * 0.5).normalized() * flight.min_speed
					flight.set_velocity(v - wind)
					velocity = v
					bumps += 1
					geo_hits += 1
					last_hit = hp
					last_hit_normal = n
					brain.on_bump(n)
	if near_geometry or always_sweep:
		np = _push_out(np, r, wind)
	var g := _ground_at(np)
	_agl = np.y - g
	if np.y < g + r:
		np.y = g + r
		# Leave along the ground ahead, not just "slightly up": on a rising
		# slope steeper than the old fixed 0.1 rad the clamp caught the bird
		# again every tick, and zeroing the pitch rate each time meant a pull
		# it had already started never built up (a tired hawk scraped 50 m up
		# a hillside with its brain asking to climb).
		var hd := flight.dir()
		hd.y = 0.0
		var slope := 0.0
		if hd.length_squared() > 1e-6:
			hd = hd.normalized()
			slope = atan(habitat.ground(np.x + hd.x, np.z + hd.z) - g)
		var g_min := maxf(0.1, slope + 0.1)
		if flight.gamma < g_min:
			flight.gamma = g_min
			flight.q = maxf(flight.q, 0.0)
		if flight.speed < flight.min_speed:
			# Down on the ground too slow to fly: spring back up, as a real
			# bird takes off (legs and a few hard beats), instead of
			# scraping along in a stall it cannot dive out of. Leave at the
			# minimum-power speed on a shallow climb: a steep 0.4-rad jump at
			# the edge of the stall bled the speed straight back off, and a
			# tired hawk bounced along a field once a second.
			flight.speed = maxf(flight.min_speed * 1.05, flight.v_min_power)
			flight.gamma = maxf(g_min, 0.15)
			flight.effort = 1.0
		velocity.y = maxf(velocity.y, 0.0)
		bumps += 1
		ground_hits += 1
	var h := Vector2(np.x, np.z)
	var lim := habitat.bounds_radius - 1.0
	if h.length_squared() > lim * lim:
		h = h.normalized() * lim
		np.x = h.x
		np.z = h.y
		bumps += 1
		bounds_hits += 1
		# Turn back in: point the heading along the boundary, inward.
		var inward := -Vector3(h.x, 0.0, h.y).normalized()
		var d := flight.dir()
		flight.set_heading_dir((Vector3(d.x, 0.0, d.z) - inward * minf(Vector3(d.x, 0.0, d.z).dot(inward), 0.0) * 2.0))
	var top := habitat.ceiling - 0.5
	if np.y > top:
		np.y = top
		flight.gamma = minf(flight.gamma, -0.05)
		bounds_hits += 1
	return np


## The sweep stops head-on hits; sliding along a wall at a grazing angle can
## still let the body overlap it. Push the body sphere back out of any
## surface (not the terrain - the ground clamp owns that - and not the spot
## it is landing on).
func _push_out(np: Vector3, r: float, wind: Vector3) -> Vector3:
	for i in 2:
		var info := habitat.rest_info(np, r * 0.9)
		if info.is_empty():
			return np
		var cp: Vector3 = info["point"]
		if _contact_ok(cp, np):
			return np
		var n: Vector3 = info["normal"]
		if n.y > 0.6 and absf(cp.y - habitat.ground(cp.x, cp.z)) < 0.25:
			return np
		var away := np - cp
		var d := away.length()
		var dir := away / d if d > 1e-4 else n
		# Centre already past the surface of a solid (convex) shape - a
		# foliage clump or rock it was carried into: "away from the contact"
		# now points deeper in, so leave along the surface normal instead.
		# Not for trimesh walls: there the normal says nothing about which
		# side is open (a bird inside a barn must stay inside).
		if dir.dot(n) < 0.0 and habitat.is_solid(info):
			dir = n
		np = cp + dir * (r + 0.02)
		bumps += 1
		geo_hits += 1
		last_hit = cp
		last_hit_normal = dir
		var into := velocity.dot(dir)
		if into < 0.0:
			velocity -= dir * into
			flight.set_velocity(velocity - wind)
	return np


## The brain marks a spot whose geometry the bird is meant to touch (the perch
## it lands on, the refuge it dives into). Obstacle feelers ignore hits
## within `radius` of it (so avoidance does not steer away from the perch
## itself); the body's collision sweep only ignores the contact spot proper,
## so the approach can never cut through a roof or trunk next to it.
func set_contact_target(p: Vector3, radius: float, body_contact := true, from_above := false) -> void:
	_ignore_near = p
	_ignore_r = radius
	_contact_above = from_above
	# body_contact false: the feelers let the bird close in, but its body
	# still collides with everything there (a hunter reaching for a bird
	# hidden in a nest box must get through the hole, not the box).
	# The body may touch within about a body radius of the spot (the grip
	# point, a refuge's inside) - not 20 cm whatever its size: a wren could
	# push 8 of its own radii into the leaves round a branch perch.
	_contact_r = minf(radius, get_body_radius() * 2.0 + 0.05) if body_contact else 0.0


## True if the body at `body` may touch geometry at contact point `cp`: it
## is the spot being landed on or dived into. For a perch only from above:
## a crow that dropped past the branch it was landing on went on down into
## the tree crown under it, its collisions waived as "the perch" (A5).
func _contact_ok(cp: Vector3, body: Vector3) -> bool:
	if _ignore_near == Vector3.INF or cp.distance_squared_to(_ignore_near) >= _contact_r * _contact_r:
		return false
	return not _contact_above or body.y > _ignore_near.y


## True if a feeler hit at p belongs to the spot being landed on / dived
## into (avoidance must not steer away from it).
func is_contact_target(p: Vector3) -> bool:
	return _ignore_near != Vector3.INF and p.distance_squared_to(_ignore_near) < _ignore_r * _ignore_r


func clear_contact_target() -> void:
	_ignore_near = Vector3.INF
	_ignore_r = 0.0
	_contact_r = 0.0
	_contact_above = false


# --- Perching and hiding ---

## The last metre or three onto a perch or into cover: a braking flare
## along a clear straight line (ease-out from the current speed to a stop,
## wings beating hard), then `done` is called. Real birds do not hit a twig
## at cruise speed; they back-flap and drop onto it. The brain cancels the
## flare (cancel_flare) if something dangerous appears.
func flare_to(target: Vector3, face: Vector3, done: Callable, keep_pace: bool = false) -> void:
	var d := global_position.distance_to(target)
	# Chained flares (in through an opening, then on) start from a near stop:
	# give them a sensible pace rather than a crawl.
	var v0 := maxf(velocity.length(), flight.min_speed if flight else 1.0)
	# An intermediate leg keeps its speed; a final one brakes to a stop.
	_flare_linear = keep_pace
	_flaring = true
	_flare_free_d = 0.0
	flares += 1
	_flare_from = global_position
	_flare_to = target
	_flare_face = face
	_flare_t = 0.0
	_flare_T = clampf((1.0 if keep_pace else 2.0) * d / v0, 0.05 if keep_pace else 0.2, 1.4)
	_flare_done = done


func cancel_flare() -> void:
	if _flaring:
		_flaring = false
		near_geometry = true
		# Fly on along the leg, but never straight up or down (the last leg
		# onto a perch is a vertical drop): level off along the heading.
		var d := _flare_to - _flare_from
		var h := Vector3(d.x, 0.0, d.z)
		if h.length_squared() < 0.04 * d.length_squared() or h.length_squared() < 1e-6:
			h = heading_dir()
		var climb := clampf(d.y / maxf(d.length(), 1e-3), -0.4, 0.3)
		flight.set_velocity((h.normalized() + Vector3.UP * climb).normalized() * flight.min_speed * 1.1)


func is_flaring() -> bool:
	return _flaring


func _flare(dt: float) -> void:
	_flare_t = minf(_flare_t + dt, _flare_T)
	var u := _flare_t / _flare_T
	var e := u if _flare_linear else 1.0 - (1.0 - u) * (1.0 - u)
	var np := _flare_from.lerp(_flare_to, e)
	var prev := global_position
	# A flare flies itself, but not through things: every leg is checked
	# before it starts, and this catches what changed or slipped between the
	# checks (a frame edge, a lid). Blocked, the bird flies on under its own
	# steering and collision. (The spot it is landing on or diving into is
	# its business: the last few centimetres there may touch.)
	if habitat != null and not (_ignore_near != Vector3.INF and np.distance_to(_ignore_near) < _contact_r + get_body_radius()) \
			and np.distance_to(_flare_from) >= _flare_free_d \
			and not habitat.sweep_clear(prev, np, get_body_radius() * 0.6):
		cancel_flare()
		return
	velocity = (np - prev) / maxf(dt, 1e-4)
	# Body attitude along the leg (turned at a bounded rate by _pose). The
	# leg's direction is never used as a look target when it is (nearly)
	# vertical - the last metre onto a perch is a drop from just above it -
	# so the beak never points at the ground.
	var line := _flare_to - _flare_from
	var hl := sqrt(line.x * line.x + line.z * line.z)
	var face_h := _flare_face.x * _flare_face.x + _flare_face.z * _flare_face.z > 1e-6
	var yaw := _vis_yaw
	var pitch := 0.0
	if not _flare_linear and face_h:
		# The final, braking leg: swing round onto the facing the bird will
		# sit in (land_on's perched pose is level), nose a little up while
		# the wings flare, level again on touchdown.
		yaw = atan2(-_flare_face.x, -_flare_face.z)
		pitch = 0.3 * sin(PI * u)
	elif hl > 0.02 and hl > absf(line.y) * 0.3:
		yaw = atan2(-line.x, -line.z)
		pitch = clampf(atan2(line.y, hl), -0.5, 0.5)
	elif face_h:
		yaw = atan2(-_flare_face.x, -_flare_face.z)
	_pose(np, pitch, yaw, dt)
	_pos = np
	flight.effort = 1.0
	flight.speed = velocity.length()
	flight.bank = 0.0
	if _flare_t >= _flare_T:
		_flaring = false
		if _flare_done.is_valid():
			_flare_done.call()


## Sit on perch p. The body keeps the attitude it arrived with and settles
## onto the perch's facing over the next ticks (no snap); `snap` places it
## there at once (spawning a bird already perched, out of the player's view).
func land_on(p: Perch, snap: bool = false) -> void:
	_flaring = false
	perch_spot = p
	p.occupant = self
	perched = true
	hidden = false
	velocity = Vector3.ZERO
	flight.speed = 0.0
	flight.omega = 0.0
	flight.effort = 0.0
	var f := p.facing
	f.y = 0.0
	if f.length_squared() < 1e-4:
		f = Vector3.FORWARD
	f = f.normalized()
	_perch_yaw = atan2(-f.x, -f.z)
	if snap:
		_vis_yaw = _perch_yaw
		_vis_pitch = 0.0
		_vis_ok = true
		_vis_basis_ok = false
		if model:
			model.snap()
	var at := Habitat.seat(p, get_body_radius())
	_pose(at, 0.0, _perch_yaw, 0.0)
	_pos = at
	flight.set_heading_dir(f)
	clear_contact_target()


func release_perch() -> void:
	if perch_spot and perch_spot.occupant == self:
		perch_spot.occupant = null
	perch_spot = null
	perched = false


func hide_in(r: Dictionary) -> void:
	_flaring = false
	refuge = r
	hidden = true
	velocity = Vector3.ZERO
	flight.speed = 0.0
	flight.omega = 0.0
	global_position = r["position"]
	_pos = global_position
	clear_contact_target()


## Leave a perch or refuge flying towards dir. `keep_pitch` keeps dir's
## climb/descent (leaving cover back along the way in).
func take_off(dir: Vector3, keep_pitch: bool = false) -> void:
	var face := perch_spot.facing if perch_spot != null else Vector3.ZERO
	release_perch()
	hidden = false
	flares += 1
	near_geometry = true
	if keep_pitch and dir.length_squared() > 1e-4:
		flight.set_velocity(dir.normalized() * flight.min_speed * 1.05)
		flight.effort = 1.0
		_pos = global_position
		return
	var d := dir
	d.y = 0.0
	if d.length_squared() < 1e-4:
		d = -global_basis.z
		d.y = 0.0
	d = d.normalized() if d.length_squared() > 1e-4 else Vector3.FORWARD
	if habitat != null:
		# The way away from a threat may be a wall (a ledge or a sill with
		# the hunter on its open side): leave by the open way nearest to it
		# - to a side, off the perch's front, or back past the threat - not
		# into the wall (prey flushed off ledges hit the wall behind them).
		var p1 := global_position + Vector3.UP * get_body_radius() * 0.5
		var reach := 2.0 + get_wingspan() * 3.0
		if not habitat.ray(p1, p1 + d * reach).is_empty():
			var fh := Vector3(face.x, 0.0, face.z)
			for c: Vector3 in [d.rotated(Vector3.UP, 1.2), d.rotated(Vector3.UP, -1.2), fh.normalized() if fh.length_squared() > 1e-4 else -d, -d]:
				if habitat.ray(p1, p1 + c * reach).is_empty():
					d = c
					break
	# Small birds spring up; big ones drop off the perch to gain speed -
	# where there is room below the way out (not off a roof ridge or a
	# ledge into the tiles it sits on: then level, a touch up).
	var pitch := 0.35 if mass < 0.2 else -0.25
	if pitch < 0.0 and habitat != null:
		var out := d * cos(pitch) + Vector3.UP * sin(pitch)
		var r := get_body_radius()
		var p0 := global_position + Vector3.UP * r * 0.5
		if not habitat.ray(p0, p0 + out * (2.0 + get_wingspan() * 2.0) + Vector3.DOWN * r).is_empty():
			pitch = 0.12
	flight.set_velocity((d * cos(pitch) + Vector3.UP * sin(pitch)) * flight.min_speed * 1.05)
	flight.effort = 1.0
	global_position += Vector3.UP * get_body_radius() * 0.5
	_pos = global_position


# --- Contract ---

func on_caught(by: Bird) -> void:
	# GameLoop may already have cleared `alive` before calling this; the
	# clean-up must still happen exactly once.
	if _caught_done:
		return
	_caught_done = true
	alive = false
	_flaring = false
	release_perch()
	hidden = false
	target = null
	threat = null
	if brain:
		brain.on_removed()
	visible = false
	set_physics_process(false)
	caught.emit(self, by)
	if not managed and is_inside_tree():
		# Let this frame's listeners (VFX, audio, game loop) read the bird first.
		get_tree().create_timer(0.5, false).timeout.connect(queue_free)


func on_ate(prey: Bird, _mass_gained: float) -> void:
	catches += 1
	hunger = 0.0
	# Handling time grows with body time (an eagle takes longer over a meal
	# than a wren): 12 s for a sparrow, ~48 s for an eagle.
	digest = DIGEST_S * SizeRules.time_scale(mass)
	energy = minf(1.0, energy + 0.3)
	if brain:
		brain.on_ate(prey)
	ate.emit(self, prey)


func _on_mass_changed() -> void:
	_endurance = pow(maxf(mass, 0.001) / 0.03, 0.25)
	_flap_hz = SpeciesProfile.flap_hz(mass)
	if flight:
		flight.configure(mass, profile.get("glide_ratio", 6.0))
	if model:
		model.scale = Vector3.ONE * get_wingspan()


func _exit_tree() -> void:
	# Leaving the tree any way at all (despawned, or the whole Ecosystem
	# freed mid-chase): let go of the target, so the player's "npc_chasers"
	# count and the prey's pursuer count do not stay raised for ever (with
	# one chaser allowed, a leaked count would end all hunting of the player).
	if brain:
		brain.on_removed()
	release_perch()
	super._exit_tree()


func set_state(s: State) -> void:
	if s == state:
		return
	var old := state
	state = s
	state_time = 0.0
	state_changed.emit(self, old, s)


func state_name() -> String:
	return STATE_NAMES[state]


func debug_text() -> String:
	var t := "%s %s e%.2f h%.2f %.1fm/s" % [species, state_name(), energy, hunger, velocity.length()]
	if target:
		t += " ->%s" % target.species
	if threat:
		t += " !%s" % threat.species
	return t


# --- Look ---

func _animate(dt: float) -> void:
	if model == null:
		return
	if perched or hidden:
		model.perched = true
		model.wing_fold = 1.0
		model.flap_amount = 0.0
		model.bank = 0.0
		_flap_amount = 0.0
		return
	model.perched = false
	var e := flight.effort
	var style := _style
	var hz := _flap_hz * (0.85 + 0.3 * e)
	var flapping := e > 0.04 or flight.stalled
	var fold := flight.fold
	# Intermittent flight: the physics uses the average power, the wings show
	# it as bursts of beats and pauses whose duty cycle matches it -
	# finches bound (wings folded), starlings/crows/hawks glide.
	var intermittent := (style == "bounding" or style == "flap_glide" or style == "soar") and e < 0.8
	if flapping and intermittent:
		if _pause > 0.0:
			_pause -= dt
			flapping = false
			if style == "bounding":
				fold = maxf(fold, 0.85)
		elif _burst <= 0.0:
			_burst = float(rng.randi_range(3, 6)) if style == "bounding" else float(rng.randi_range(4, 8))
	if flapping:
		var dp := hz * dt
		_flap_phase = fposmod(_flap_phase + dp, 1.0)
		if intermittent:
			_burst -= dp
			if _burst <= 0.0:
				var duty := clampf(e / 0.8, 0.2, 0.95)
				var beats := float(rng.randi_range(3, 6))
				_pause = beats / hz * (1.0 / duty - 1.0)
		_flap_amount = move_toward(_flap_amount, clampf(0.4 + e, 0.0, 1.0), 6.0 * dt)
	else:
		_flap_amount = move_toward(_flap_amount, 0.0, 5.0 * dt)
		if _flap_amount <= 0.0:
			# Settle the wings at mid-stroke (level) for the glide.
			_flap_phase = move_toward(_flap_phase, 0.25, dt * 2.0)
	model.flap_phase = _flap_phase
	model.flap_amount = _flap_amount
	model.wing_fold = fold
	model.bank = flight.bank
