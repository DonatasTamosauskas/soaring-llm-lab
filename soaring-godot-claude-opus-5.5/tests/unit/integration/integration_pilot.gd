extends FlightAutopilot
## TEST-ONLY: the whole-game suites' pilot. Flight's FlightAutopilot flies a
## fixed lab course; this one flies the real valley: it holds a height above
## the terrain ahead, steers at a target (prey, a predator, a waypoint) or a
## heading, and can fly the onboarding lessons' gestures (glide, nose-down
## for speed, bank, tuck-dive, flap). It only sets the pilot's commands
## (pitch, roll, effort, flapping, tuck); flight's BotPoseSource turns them
## into human arm motion and the real WingInput reads them, so everything
## downstream is the game's own chain.

## Where to fly (INF: hold `heading`).
var target := Vector3.INF
## Fly at the target's height too (a chase); else cruise at `agl`.
var chase := false
## Yaw to hold without a target (rad; 0 = -Z).
var heading := 0.0
## Height above the highest ground ahead to cruise at.
var agl := 30.0
## Never lower than this above the ground ahead (unless diving at a target).
var min_agl := 8.0
## cruise | glide | speed | turn | dive | flap | climb
var mode := &"cruise"
var turn_sign := 1.0
## Read by IntegrationBot: arms in to the chest (the dive tuck).
var tuck := false
var world: World
## Diagnostics.
var last_agl := 0.0
var last_ground := 0.0
## Metres added to the height the pilot flies at (a pilot climbing over
## something in its way; see steer_round).
var climb_bonus := 0.0
## Chasing: the lowest it flies over the ground ahead (spans), and how far
## under its target it climbs at cruise before it sprints (m, or spans).
const CHASE_CLEAR_SPANS := 1.5
const CLIMB_FIRST_M := 3.0
const CLIMB_FIRST_SPANS := 2.0


## The goal the lateral guidance steers at, after looking where the bird is
## going (a subclass steers round what is in the way). Default: unchanged.
func steer_round(_pos: Vector3, _vel: Vector3, goal: Vector3) -> Vector3:
	return goal


func update(pos: Vector3, vel_raw: Vector3, airspeed: float, dt: float) -> void:
	var p := params
	var kf := 1.0 - exp(-dt / tau_path)
	if not _lp_init:
		_vel_lp = vel_raw
		_v_lp = airspeed
		_lp_init = true
	_vel_lp += (vel_raw - _vel_lp) * kf
	_v_lp += (airspeed - _v_lp) * kf
	var v := maxf(_v_lp, 0.1)
	var vh := Vector3(vel_raw.x, 0.0, vel_raw.z)
	var dir := vh.normalized() if vh.length() > 0.3 else Vector3(-sin(heading), 0.0, -cos(heading))
	# --- the ground ahead (terrain, water, cliffs) along the path
	var ground := -INF
	if world != null:
		for d: float in [0.0, 8.0, 20.0, 40.0, 70.0]:
			var q := pos + dir * d
			ground = maxf(ground, world.ground_height(q.x, q.z))
	else:
		ground = 0.0
	last_ground = ground
	last_agl = pos.y - ground
	# --- lateral: L1 guidance at the target (or along the heading)
	var goal := target if target != Vector3.INF else pos + Vector3(-sin(heading), 0.0, -cos(heading)) * 60.0
	goal = steer_round(pos, vel_raw, goal)
	var l1 := maxf(2.5 * p.span, k_l1 * p.v_c)
	var to := Vector3(goal.x - pos.x, 0.0, goal.z - pos.z)
	roll = 0.0
	if vh.length() > 0.3 and to.length() > 1e-3:
		var sin_eta := -(vh.normalized().cross(to.normalized())).y
		var cos_eta := vh.normalized().dot(to.normalized())
		var eta := atan2(sin_eta, cos_eta)
		var l := minf(l1, maxf(to.length(), 0.5 * l1))
		var a_lat := 2.0 * v * v / l * sin(clampf(eta, -PI / 2, PI / 2))
		roll = clampf(atan(a_lat / FlightMath.G) / p.phi_max, -1.0, 1.0)
	# --- vertical: height above the ground ahead, or the target's height
	if chase and target != Vector3.INF:
		# (Core loop round: never lower than a span and a half over the ground
		# ahead - a hawk-sized bot chasing at 1 m skimmed the ground and the
		# lake, touching down every ~15 s.)
		h_target = maxf(target.y, ground + maxf(1.0, CHASE_CLEAR_SPANS * p.span))
	else:
		h_target = ground + maxf(agl, min_agl)
	h_target += climb_bonus
	v_target = k_vc * p.v_c
	# A person climbs to its quarry before it sprints at it (core loop round):
	# pitched down for speed, a heavy bird flapping flat out does not climb -
	# a hawk-sized bot chased a gull 40 m above it along the ground for
	# minutes. Well below the target, it flies at its cruise.
	if chase and h_target - pos.y > maxf(CLIMB_FIRST_M, CLIMB_FIRST_SPANS * p.span):
		v_target = minf(v_target, p.v_c)
	tuck = false
	flapping = true
	grip = false
	spread = 1.0
	var ev := (v - v_target) / v_target
	_iv = clampf(_iv + k_iv * ev * dt, -0.3, 0.3)
	pitch = clampf(pitch_trim(v_target) + k_v * ev + _iv, -1.0, 0.85)
	var dh := h_target - pos.y
	# (A chase closes height errors faster: the target is seconds away.)
	var tau_h := 0.6 * p.t_ph if not chase else minf(0.6 * p.t_ph, 0.8)
	var vz_cmd := clampf(dh / tau_h, -2.0, _climb_cruise)
	var e := vz_cmd - vel_raw.y
	_ih = clampf(_ih + k_ih * e * dt, -0.4, 0.6)
	effort = clampf(0.35 + 0.65 * maxf(vz_cmd, 0.0) / _climb_cruise + k_h * e + _ih, 0.0, 1.0)
	# --- the gestures (the low-ground guard wins over every one of them)
	var low := last_agl < min_agl and not chase
	match mode:
		&"glide":
			if not low:
				flapping = false
				effort = 0.0
		&"speed":
			if not low:
				flapping = false
				effort = 0.0
				pitch = -0.7
		&"turn":
			roll = 0.8 * turn_sign
		&"dive":
			if not low:
				flapping = false
				effort = 0.0
				tuck = true
				pitch = -0.5
		&"flap":
			effort = maxf(effort, 0.9)
		&"climb":
			effort = 1.0
			pitch = maxf(pitch, pitch_trim(v_target))
