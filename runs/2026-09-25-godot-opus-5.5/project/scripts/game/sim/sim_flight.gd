class_name SimFlight
extends RefCounted
## A verbatim copy of the AI area's NpcFlight (scripts/ai/npc_flight.gd as
## of 2026-09-25), so the game-loop simulations fly birds with exactly the
## physics the real NPCs fly - roll-in lag, the load-factor turn limit,
## induced drag in turns, the energy trade in climbs and dives, the tucked
## stoop. Copied, not referenced: the game-loop suite must not depend on
## another area's in-progress code. If the AI area retunes its flight,
## re-copy this file and re-run tests/shots/gameloop_pacing.tscn (the duel
## check in tests/unit/game/danger_test.gd shows whether the sims still
## behave like the AI).
##
## --- Original documentation follows. ---
##
## Lightweight, size-aware flight for NPC birds.
##
## A point mass flying along its air velocity, integrated from specific
## power and drag (every force here is per kilogram, i.e. an acceleration).
## It is not the player's full FlightModel: 60 birds share a 2 ms budget and
## an autopilot does not need wing geometry. But the relationships are the
## same real ones the player feels:
##  * speed comes from flapping power against a glide polar (parasite drag
##    rises with v^2, induced drag falls with v^2 and rises with load^2);
##  * climbing costs speed or power, diving buys speed (energy trade);
##  * with no power the bird glides at its glide ratio, so an updraft stronger
##    than its sink lifts it;
##  * turns are coordinated: bank = atan(omega * v / g), heading follows
##    without sideslip; the load factor limits the turn rate;
##  * tucked wings cut drag so a stoop reaches max_speed, spread wings cap a
##    dive at ~1.55x cruise;
##  * below min_speed the nose drops until flying speed returns (stall).
##
## Every limit is derived from SizeRules.performance(mass) so that the
## measured envelope (tests/unit/ai/flight_envelope_test.gd) lands within
## 10% of it: cruise, min_speed, max_speed (tucked dive), turn_rate
## (sustained at cruise) and climb (sustained at cruise).
##
## Conventions: heading psi = 0 flies towards -Z, positive psi turns left
## (counter-clockwise from above, like Node3D.rotation.y). bank > 0 = right
## wing down (BirdModel.bank convention). gamma > 0 = climbing.

const G := 9.81

# --- Envelope (from SizeRules.performance) ---
var mass := 0.03
var cruise := 9.0
var min_speed := 4.05
var max_speed := 23.4
var turn_rate := 3.84
var climb := 4.0
var agility := 1.0
var glide_ratio := 5.0

# --- Derived aerodynamics ---
## Best-glide speed and the drag there (= G / glide_ratio).
var v_md := 7.6
var d_min := 1.96
## Minimum-sink speed (what a soaring bird circles at).
var v_ms := 5.8
## Stall speed: min_speed is the slowest *controllable* speed, 15% above it.
var v_stall := 3.5
## Spread-wing dive limit (feathers flutter, drag climbs steeply above cruise).
var v_sd := 14.0
## Load factor of the max sustained turn at cruise.
var n_max := 3.6
## How strongly turning load raises induced drag (tuned so the max turn at
## cruise is just sustainable at full power: turn_rate is "sustained").
var c_ind := 0.5
## Max specific power, W/kg (set so the sustained climb at cruise = climb).
var p_max := 50.0
## Seconds to roll from wings-level into the maximum turn.
var roll_time := 0.12
## Heading/pitch controller gains, 1/s.
var heading_gain := 6.0
var pitch_gain := 5.0
## Max thrust as an acceleration (take-off is brisk, not rocket-like).
var thrust_cap := 24.0
## Fastest level flight at full effort (what a chase runs at).
var sprint := 11.0
## Fraction of p_max needed for level flight at the minimum-power speed.
var p_min_frac := 0.3
var _lvl := PackedFloat32Array()

## (Addition to the copy) Fraction of the turn envelope in use: a SimPilot
## flying the player may not use all of it.
var turn_scale := 1.0

# --- State ---
var psi := 0.0
var gamma := 0.0
var speed := 9.0
var omega := 0.0
var q := 0.0
var bank := 0.0
var effort := 0.0
var fold := 0.0
var brake := 0.0
var load := 1.0
var stalled := false
## Last acceleration along the path (m/s^2), for telemetry/tests.
var accel := 0.0


func _init(p_mass: float = 0.03, p_glide_ratio: float = 5.0) -> void:
	configure(p_mass, p_glide_ratio)


## Derive every coefficient from the size ladder. Call again when mass changes.
func configure(p_mass: float, p_glide_ratio: float) -> void:
	mass = p_mass
	glide_ratio = maxf(p_glide_ratio, 2.0)
	var perf := SizeRules.performance(mass)
	cruise = perf["cruise"]
	min_speed = perf["min_speed"]
	max_speed = perf["max_speed"]
	turn_rate = perf["turn_rate"]
	climb = perf["climb"]
	agility = perf["agility"]
	# Birds cruise a little faster than best glide (they are going somewhere).
	v_md = cruise * 0.85
	d_min = G / glide_ratio
	v_ms = v_md / pow(3.0, 0.25)
	v_stall = min_speed / 1.15
	v_sd = cruise * 1.55
	var tan_b := turn_rate * cruise / G
	n_max = sqrt(1.0 + tan_b * tan_b)
	# Sustained climb at cruise defines the power: climbing at gamma_c the
	# wings carry cos(gamma_c) of the weight, so induced drag is lower.
	var sin_c := clampf(climb / cruise, 0.0, 0.95)
	var cos_c := sqrt(1.0 - sin_c * sin_c)
	# c_ind and p_max depend on each other; a few fixed-point rounds settle it.
	# c_ind is picked so the max-rate level turn at cruise needs 92% of p_max.
	var vr2 := (cruise / v_md) * (cruise / v_md)
	var par := 0.5 * d_min * vr2
	var ind1 := 0.5 * d_min / vr2
	c_ind = 1.0
	for i in 4:
		p_max = G * climb + _drag_spread(cruise, cos_c, 0.0) * cruise
		var need := 0.92 * p_max / cruise - par
		c_ind = clampf((need / ind1 - 1.0) / (n_max * n_max - 1.0), 0.0, 1.0)
	p_max = G * climb + _drag_spread(cruise, cos_c, 0.0) * cruise
	roll_time = lerpf(0.45, 0.09, agility)
	# The turn rate can only change at turn_rate / roll_time. If the heading
	# loop asked for it to unwind faster than that (gain x roll_time > 1) the
	# bird would overshoot and weave: big, slow-rolling birds steer gently.
	heading_gain = minf(lerpf(3.0, 7.0, agility), 0.9 / roll_time)
	pitch_gain = heading_gain * 0.8
	thrust_cap = lerpf(1.2, 2.6, agility) * G
	_build_level_table()


## Spread-wing drag per kg at airspeed v and load factor n.
func _drag_spread(v: float, n: float, b: float) -> float:
	var vr := v / v_md
	var vr2 := maxf(vr * vr, 0.05)
	var d := 0.5 * d_min * (vr2 * (1.0 + 1.6 * b) + (1.0 + c_ind * (maxf(n * n, 0.0) - 1.0)) / vr2)
	if v > cruise:
		var x := (v - cruise) / (v_sd - cruise)
		d += G * x * x
	return d


## Total drag per kg: blend of spread wings and a tucked dive shape whose
## terminal velocity in a vertical dive is exactly max_speed.
func drag(v: float, n: float, f: float, b: float) -> float:
	var spread := _drag_spread(v, n, b)
	if f <= 0.0:
		return spread
	var r := v / max_speed
	return lerpf(spread, G * r * r, f)


## Largest yaw/pitch rate available at airspeed v (rad/s). Below the corner
## speed lift limits it; above cruise the wings have lift to spare, so the
## usable load grows with speed and the rate stays about turn_rate while the
## turn radius (v / omega) grows - big fast birds turn wide.
func max_turn_rate(v: float) -> float:
	var vs := v / v_stall
	var n_avail := minf(vs * vs, n_max * maxf(1.0, v / cruise))
	if n_avail <= 1.02:
		return 0.2
	return G * sqrt(n_avail * n_avail - 1.0) / maxf(v, 0.5)


## Steady level airspeed at effort e (the fast solution of drag x v = e x
## p_max), or 0 when e is too little to hold height at any speed.
func level_speed(e: float) -> float:
	var x := clampf(e, 0.0, 1.0) * 10.0
	var i := mini(int(x), 9)
	var a: float = _lvl[i]
	var b: float = _lvl[i + 1]
	if a <= 0.0 or b <= 0.0:
		return b if x >= float(i + 1) - 1e-4 else 0.0
	return lerpf(a, b, x - float(i))


func _build_level_table() -> void:
	_lvl.resize(11)
	# Minimum-power speed: below it level flight gets harder, not easier.
	var v_mp := min_speed
	var p_min := INF
	var v := min_speed * 0.6
	while v < max_speed:
		var pw := drag(v, 1.0, 0.0, 0.0) * v
		if pw < p_min:
			p_min = pw
			v_mp = v
		v += 0.05 * cruise
	p_min_frac = p_min / p_max
	for i in 11:
		var p := p_max * float(i) / 10.0
		if p < p_min:
			_lvl[i] = 0.0
			continue
		var lo := v_mp
		var hi := max_speed
		for k in 30:
			var mid := (lo + hi) * 0.5
			if drag(mid, 1.0, 0.0, 0.0) * mid < p:
				lo = mid
			else:
				hi = mid
		_lvl[i] = lo
	sprint = _lvl[10]


## Unit direction of flight (air-relative).
func dir() -> Vector3:
	var cg := cos(gamma)
	return Vector3(-sin(psi) * cg, sin(gamma), -cos(psi) * cg)


func air_velocity() -> Vector3:
	return dir() * speed


## Seconds of sink per second when gliding at airspeed v (m/s, positive down).
func sink_rate(v: float) -> float:
	return drag(v, 1.0, 0.0, 0.0) * v / G


## Set the state from a velocity (spawning, take-off, tests).
func set_velocity(v: Vector3) -> void:
	speed = maxf(v.length(), 0.01)
	var d := v / speed
	gamma = asin(clampf(d.y, -1.0, 1.0))
	if absf(d.x) + absf(d.z) > 1e-5:
		psi = atan2(-d.x, -d.z)
	omega = 0.0
	q = 0.0
	bank = 0.0


func set_heading_dir(d: Vector3) -> void:
	if absf(d.x) + absf(d.z) > 1e-5:
		psi = atan2(-d.x, -d.z)


## Advance dt seconds.
##   want_dir    desired direction of flight (need not be unit; air frame)
##   want_speed  desired airspeed, m/s (clamped to [min_speed, max_speed])
##   max_effort  0..1 cap on flapping power (0 = glide only)
##   want_fold   0..1 wing tuck (1 = stoop)
func step(dt: float, want_dir: Vector3, want_speed: float, max_effort: float, want_fold: float) -> void:
	want_speed = clampf(want_speed, min_speed, max_speed)
	max_effort = clampf(max_effort, 0.0, 1.0)
	fold = move_toward(fold, clampf(want_fold, 0.0, 1.0), 4.0 * dt)
	var sp := maxf(speed, 0.5)
	var w_lim := max_turn_rate(sp) * turn_scale

	# --- Heading: coordinated turn, rate-limited roll-in ---
	var hx := want_dir.x
	var hz := want_dir.z
	var wlen := want_dir.length()
	var w_cmd := 0.0
	if hx * hx + hz * hz > 1e-6 * wlen * wlen + 1e-9:
		var err := wrapf(atan2(-hx, -hz) - psi, -PI, PI)
		w_cmd = clampf(err * heading_gain, -w_lim, w_lim)
	var w_acc := turn_rate / roll_time
	omega = clampf(move_toward(omega, w_cmd, w_acc * dt), -w_lim, w_lim)
	psi = wrapf(psi + omega * dt, -PI, PI)
	bank = atan(-omega * sp / G)

	# --- Flight path angle: what we want, capped by what the wings can hold ---
	var g_des := 0.0
	if wlen > 1e-6:
		g_des = asin(clampf(want_dir.y / wlen, -1.0, 1.0))
	g_des = clampf(g_des, -1.4, 1.2)
	var cb := cos(bank)
	load = cos(gamma) / maxf(cb, 0.2)
	var d_now := drag(sp, load, fold, 0.0)
	var sin_sus := (max_effort * minf(p_max / sp, thrust_cap) - d_now) / G
	var g_sus := asin(clampf(sin_sus, -1.0, 1.0))
	# The speed we try to hold: what was asked, but no more than level flight
	# at the allowed effort can give (asking a sparrow for max_speed means
	# "sprint", not "dive until you get it"). With too little power for level
	# flight at all, the bird glides and holds speed with the path angle.
	var v_lvl := level_speed(max_effort)
	var gliding := v_lvl < min_speed
	var v_hold := want_speed if gliding else minf(want_speed, v_lvl)
	var excess := (sp - v_hold) / v_hold
	var g_cap := 0.0
	if excess >= 0.0:
		# Spare speed can be zoomed into height (energy trade): the speed
		# bleeds, the height stays.
		g_cap = (g_sus if gliding else maxf(g_sus, 0.0)) + minf(excess * 3.0, 1.3)
	elif gliding:
		g_cap = g_sus + maxf(excess, -0.5)
	else:
		# Short of the hold speed: climb less to accelerate, but never dive
		# for speed when level flight is sustainable.
		g_cap = maxf(g_sus + maxf(excess, -0.5) * 0.6, minf(g_des, 0.0))
	stalled = sp < min_speed * 0.97
	if stalled:
		g_cap = minf(g_cap, -0.3 - (min_speed - sp) / min_speed)
	g_des = minf(g_des, g_cap)
	# Pulling up needs lift (limited by w_lim); pushing over does not: with
	# the wings unloaded, gravity alone bends the path down at g cos(gamma)/v.
	# That is what makes a stall recoverable at any speed.
	var q_lo := -maxf(w_lim, G * cos(gamma) / sp * 0.9)
	var q_cmd := clampf((g_des - gamma) * pitch_gain, q_lo, w_lim)
	q = move_toward(q, q_cmd, maxf(w_acc, -q_lo * 8.0) * dt)
	gamma = clampf(gamma + q * dt, -1.52, 1.35)

	# --- Speed along the path: power in, drag and gravity out ---
	load = cos(gamma) / maxf(cb, 0.2) + absf(q) * sp / G
	var a_grav := -G * sin(gamma)
	var a_des := clampf((want_speed - sp) * 1.5, -8.0, 8.0)
	var d := drag(sp, load, fold, 0.0)
	var p_req := (d - a_grav + a_des) * sp
	effort = clampf(p_req / p_max, 0.0, max_effort)
	brake = 0.0
	if effort <= 0.0 and fold < 0.5 and sp > want_speed * 1.03:
		# Too fast with nothing to give back: spread tail, drop legs.
		brake = clampf((sp / want_speed - 1.0) * 4.0, 0.0, 1.0)
		d = drag(sp, load, fold, brake)
	var thrust := minf(effort * p_max / sp, effort * thrust_cap)
	accel = thrust - d + a_grav
	speed = clampf(speed + accel * dt, min_speed * 0.35, max_speed)
