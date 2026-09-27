class_name FlightModel
extends RefCounted
## The flight physics (FLIGHT_SPEC §7 and Appendix A): a point mass with a
## lagged attitude (pitch theta, bank phi, a small yaw-offset channel),
## integrated with Heun (RK2) in substeps of h = dt / ceil(dt * substep_hz)
## (144 Hz: two substeps at 72 and 90 Hz ticks, so h <= 1/120 s).
##
## Pure RefCounted, no scene dependencies, deterministic, allocation-free per
## step: the player and NPCs can share it. Lift and drag follow airspeed and
## angle of attack; the coordinated turn comes from tilting lift with bank;
## the balloon, the phugoid, the energy trade and updraft climbs all emerge.
## The few non-physical "gameplay laws" (stall protection, auto-level,
## phugoid damper, governor, ...) are the named, bounded assists of §9.

enum Contact { SLIDE, BOUNCE }

const G := FlightMath.G

var tuning: FlightTuning
var params: FlightParams
## StringName -> bool, from the tuning preset (§9).
var assists := {}
## Auto-rudder: 1 cancels adverse yaw (tests set 0 to prove it exists).
var k_rud := 1.0
## Player comfort caps enforced as bank limits (rad/s, rad/s^2; 0 = off).
var comfort_yaw_rate := 0.0
var comfort_yaw_accel := 0.0
## NPC "lite" mode: one Heun step per tick instead of the substeps.
var lite := false
## Tests only (FM-22 energy): no aerodynamic drag or governor.
var drag_enabled := true

# ---- state (read-only to callers) ----
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var chi := 0.0            ## path heading (yaw of the horizontal air velocity, held when slow)
var dpsi := 0.0           ## body yaw offset from the path (+ = nose left)
var theta := 0.0          ## body pitch (visual/telemetry only, never the camera)
var phi := 0.0            ## bank (+ = right wing down)
var alpha := 0.0          ## measured angle of attack
var gam := 0.0            ## flight-path angle of the air velocity
var stalled := false
var stall_warning := 0.0
var stall_count := 0
var yaw_rate := 0.0       ## heading rate, rad/s
var yaw_acc := 0.0        ## heading acceleration, rad/s^2 (filtered)
var phidot := 0.0
var sigma := 0.0          ## separation blend 0..1
var endurance_l := 1.0    ## 1 = uncapped
var endurance_r := 1.0
var airspeed_v := 0.0
var wind := Vector3.ZERO  ## wind at the body (last evaluation)
## Heading jumps (rad) since the last take_heading_step(): the small turn a
## contact gives the body (apply_contact: at most contact_turn_max_deg), or
## the path heading snapping faster than any flown turn (slow flight). The
## player's rig pays these to the view smoothly (ViewTurn) instead of
## dropping them at its comfort clamp.
var heading_step := 0.0

# ---- private state ----
var _t_stall := 0.0
var _delib_t := 0.0
var _stall_side := 1.0
var _udot := 0.0
var _v_lp := 0.0
var _vh_lp := 0.0
var _p_l := 0.0
var _p_r := 0.0
var _u_l := 0.0
var _u_r := 0.0
var _yaw_rate_prev := 0.0
var _tick_y0 := 0.0
var _hov := 0.0
var _acc_last := Vector3.ZERO
var _events := PackedStringArray()
## The wind the path heading was last taken against (see _absorb_wind_turn).
var _w_chi := Vector3.ZERO
var _w_chi_ok := false
# Assist flags and radians cached once per tick (dictionary lookups and
# deg_to_rad calls per substep cost ~10% of the step).
var _as_protect := true
var _as_turn := true
var _as_damper := true
var _as_nlimit := true
var _as_floor := true
var _as_cushion := true
var _as_novice := false
var _r_top := 0.0
var _r_enter := 0.0
var _r_exit := 0.0
var _r_simtop := 0.0
var _r_warn := 0.0
var _r_tuck := 0.0
var _r_kick := 0.0
var _r_drop := 0.0
var _r_nose := 0.0
var _r_floor := 0.0
var _hold := 0.35
var _turn_comp := 0.85
var _top := 0.3
var _ext_roll := 0.5
var _cushion_g := 1.5
# Per-tick filter factors and environment (h is constant within a tick).
var _k_f := 0.0
var _k_ud := 0.0
var _k_lp := 0.0
var _k_sep := 0.0
var _k_al := 0.0
var _k_bk := 0.0
var _k_ya := 0.0
## Stroke-mean net effort per wing (see _substep): the one-wing kick's input.
var _as_l := 0.0
var _as_r := 0.0
var _t_kick_dz := 0.15
var _t_flap_side := 0.0
var _has_wind := false
## The last two wind samples of this step (see _wind); cleared every step.
var _wc_pos0 := Vector3.ZERO
var _wc_val0 := Vector3.ZERO
var _wc_ok0 := false
var _wc_pos1 := Vector3.ZERO
var _wc_val1 := Vector3.ZERO
var _wc_ok1 := false
var _env_accel := Vector3.ZERO
var _env_ground := INF
var _env_alpha_bias := 0.0
var _env_drag_bonus := 0.0
var _env_lift_scale := 1.0
## True while the belly is below the stall guard height (see _alpha_cmd).
var _stall_guard := false
## The stall guard's height (m): see FlightTuning.stall_guard_vmin2g.
var _t_guard_h := 0.0

# Endurance: stroke-synchronous full-window mean of the raw effort (§7.7),
# as a ring of cumulative integrals in 1/120 s buckets.
const END_N := 256
const END_BUCKET := 1.0 / 120.0
var _end_ring_l := PackedFloat64Array()
var _end_ring_r := PackedFloat64Array()
var _end_idx := 0
var _end_filled := 0
var _end_cum_l := 0.0
var _end_cum_r := 0.0
var _end_bucket_t := 0.0

# Last-good state for the NaN guard (members, not an Array: no allocation).
var _g_pos := Vector3.ZERO
var _g_vel := Vector3.ZERO
var _g_att := Vector4.ZERO
var _g_flap := Vector4.ZERO
var _g_lp := Vector2.ZERO
var _guard_logged := false

# Forces from the last committed evaluation (telemetry, tests).
var f_lift := Vector3.ZERO
var f_drag := Vector3.ZERO
var f_flap := Vector3.ZERO
var f_gravity := Vector3.ZERO
var lift_n := 0.0
var drag_n := 0.0
var flap_n := 0.0
var flap_power := 0.0     ## W/kg of flap work into the air
var g_load := 1.0
var lhat := Vector3.UP
## Cumulative flap impulse (N s): exactly what the integrator applied (the
## mean of both Heun stages' flap forces; round 1 summed the first stage
## only, which lagged a rising stroke by half a substep). Tests difference
## it across a stroke.
var flap_impulse := Vector3.ZERO
var _f_flap2 := Vector3.ZERO
var _cl := 0.0


func _init(mass: float = 0.03, p_tuning: FlightTuning = null) -> void:
	tuning = p_tuning if p_tuning != null else FlightTuning.default_tuning()
	assists = tuning.assists()
	params = FlightParams.derive(mass, tuning)
	_refresh_cache()
	_end_ring_l.resize(END_N)
	_end_ring_r.resize(END_N)
	reset(Vector3.ZERO, Vector3(0, 0, -params.v_c), 0.0)


## Re-derive for a new mass; the state is kept (continuous growth).
func set_mass(mass: float) -> void:
	params.set_mass(mass, tuning)
	_refresh_cache()


func set_tuning(t: FlightTuning) -> void:
	tuning = t
	assists = tuning.assists()
	params.set_mass(params.mass, tuning)
	_refresh_cache()


func reset(pos: Vector3, vel: Vector3, heading := NAN) -> void:
	position = pos
	velocity = vel
	var vh := FlightMath.horiz(vel)
	if not is_nan(heading):
		chi = heading
	elif vh.length() > 0.1:
		chi = FlightMath.yaw_of(vh)
	else:
		chi = 0.0
	var fh := FlightMath.yaw_forward(chi)
	var v := vel.length()
	gam = atan2(vel.y, vel.dot(fh)) if v > 1e-6 else 0.0
	theta = clampf(gam + params.alpha_n, -PI / 2, PI / 2)
	alpha = theta - gam
	phi = 0.0
	phidot = 0.0
	dpsi = 0.0
	stalled = false
	stall_warning = 0.0
	sigma = 0.0
	_t_stall = 0.0
	_delib_t = 0.0
	_udot = 0.0
	_v_lp = v
	_vh_lp = vh.length()
	_p_l = 0.0
	_p_r = 0.0
	_u_l = 0.0
	_u_r = 0.0
	_as_l = 0.0
	_as_r = 0.0
	_hov = 0.0
	_acc_last = Vector3.ZERO
	yaw_rate = 0.0
	yaw_acc = 0.0
	_yaw_rate_prev = 0.0
	airspeed_v = v
	_end_idx = 0
	_end_filled = 0
	_end_cum_l = 0.0
	_end_cum_r = 0.0
	_end_bucket_t = 0.0
	endurance_l = 1.0
	endurance_r = 1.0
	heading_step = 0.0
	_w_chi_ok = false
	_events.clear()
	_save_good()


## Start in the steady glide at `pitch` (spread, still air), solved
## analytically from the polar: no phugoid is injected (§14.1 "trim").
func trim(pos: Vector3, heading: float, pitch := 0.0) -> void:
	var sol := trim_solution(pitch)
	var fh := FlightMath.yaw_forward(heading)
	var g0: float = sol["gamma"]
	var v0: float = sol["v"]
	reset(pos, (fh * cos(g0) + Vector3.UP * sin(g0)) * v0, heading)
	gam = g0
	theta = clampf(g0 + float(sol["alpha"]), -PI / 2, PI / 2)
	alpha = theta - gam
	_save_good()


## Steady-glide solution {v, gamma, alpha, cl, cd} for a pitch command, in
## attached flow: the polar of a steady glide never includes the stall's
## separation drag, whatever the live state (right after a stall sigma is
## still decaying; reading it gave gamma -30 deg instead of -7).
func trim_solution(pitch: float) -> Dictionary:
	var p := params
	var a_cmd := _alpha_base(pitch, 1.0)
	if assists.get(&"stall_protect", true):
		a_cmd = minf(a_cmd, p.alpha_s - deg_to_rad(tuning.margin_top_deg))
	var cl := clampf(p.a * a_cmd, tuning.cl_min, 1.05 * p.cl_max)
	var s0 := sigma
	sigma = 0.0
	var cd := _cd_of(a_cmd, cl, 1.0, 0.0, INF)
	sigma = s0
	var m := p.mass
	# |aero force| = m g: bisection on V (monotonic).
	var lo := 0.05
	var hi := 3.0 * p.v_max
	for i in 60:
		var mid := 0.5 * (lo + hi)
		var q := 0.5 * tuning.rho * mid * mid
		var l := q * p.s * cl
		var d := q * p.s * cd + _governor(mid)
		if sqrt(l * l + d * d) > m * G:
			hi = mid
		else:
			lo = mid
	var v := 0.5 * (lo + hi)
	var q2 := 0.5 * tuning.rho * v * v
	var g0 := -atan2(q2 * p.s * cd + _governor(v), q2 * p.s * cl)
	return {"v": v, "gamma": g0, "alpha": a_cmd, "cl": cl, "cd": cd}


var _ws_safe := WingState.new()
## Hot-path copies of params / tuning fields (refreshed with the cache):
## a member read is ~2x cheaper than a property read on another object.
var _c_a := 0.0
var _c_alpha_n := 0.0
var _c_alpha_s := 0.0
var _c_cd0 := 0.0
var _c_cl_max := 0.0
var _c_cl_n := 0.0
var _c_e_cap := 0.0
var _c_k_flap := 0.0
var _c_k_hover := 0.0
var _c_k_i := 0.0
var _c_mass := 0.0
var _c_n_max := 0.0
var _c_p_max := 0.0
var _c_p_ref := 0.0
var _c_p_ref_pos := 0.0
var _c_p_spec := 0.0
var _c_phi_max := 0.0
var _c_q_max := 0.0
var _c_r_body := 0.0
var _c_s := 0.0
var _c_span := 0.0
var _c_tau_sf := 0.0
var _c_tau_wc := 0.0
var _c_up_gain := 0.0
var _c_v_c := 0.0
var _c_v_max := 0.0
var _c_v_min := 0.0
var _t_adverse := 0.0
var _t_cl_min := 0.0
var _t_damper_down := 0.0
var _t_damper_up := 0.0
var _t_deliberate_pitch := 0.0
var _t_forced_recovery := 0.0
var _t_governor_gain := 0.0
var _t_governor_start := 0.0
var _t_ground_lift_gain := 0.0
var _t_paddle_yaw := 0.0
var _t_plate_drag := 0.0
var _t_post_stall_plateau := 0.0
var _t_rho := 0.0
var _t_stall_drag := 0.0
var _ck_assists := 0
var _ck_tuning: FlightTuning = null
var _ck_mass := -1.0
var _ck_h := -1.0


func step(ws: WingState, env: FlightEnv, dt: float) -> void:
	if dt <= 0.0 or not is_finite(dt):
		return
	if not _inputs_finite(ws):
		# A corrupt input tick (NaN from a glitching tracker) is replaced by
		# neutral commands with the finite parts kept; it never enters the state.
		_ws_safe.copy_from(ws)
		_sanitize(_ws_safe)
		ws = _ws_safe
	dt = minf(dt, 0.25)
	var n := 1 if lite else maxi(1, ceili(dt * tuning.substep_hz - 1e-9))
	var h := dt / n
	_tick_y0 = position.y
	# The derived constants and filter factors only change with the assists,
	# the tuning, the mass (growth) or the substep; the step is the hot path
	# (72 Hz x every bird), so they are recomputed only then. Code that edits
	# a tuning field in place calls refresh().
	var ah := assists.hash()
	if ah != _ck_assists or tuning != _ck_tuning or params.mass != _ck_mass:
		_refresh_cache()
		_ck_assists = ah
		_ck_tuning = tuning
		_ck_mass = params.mass
		_ck_h = -1.0
	if h != _ck_h:
		_ck_h = h
		var p := params
		_k_f = FlightMath.lp_k(h, p.tau_f)
		_k_ud = FlightMath.lp_k(h, 0.05)
		_k_lp = FlightMath.lp_k(h, 0.5)
		_k_sep = FlightMath.lp_k(h, tuning.sep_tau)
		_k_al = FlightMath.lp_k(h, p.tau_alpha)
		_k_bk = FlightMath.lp_k(h, p.tau_bank)
		_k_ya = FlightMath.lp_k(h, 0.02)
	_has_wind = env != null and env.wind_fn.is_valid()
	_wc_ok0 = false
	_wc_ok1 = false
	if env != null:
		var ea := env.accel
		_env_accel = ea if is_finite(ea.x + ea.y + ea.z) else Vector3.ZERO
		_env_ground = env.ground_distance if is_finite(env.ground_distance) else INF
		_env_alpha_bias = clampf(env.alpha_bias, -0.0524, 0.0524) if is_finite(env.alpha_bias) else 0.0
		_env_drag_bonus = clampf(env.drag_bonus, 0.0, 0.4) if is_finite(env.drag_bonus) else 0.0
		_env_lift_scale = clampf(env.lift_scale, 0.0, 1.0) if is_finite(env.lift_scale) else 1.0
		_stall_guard = env.agl < _t_guard_h
	else:
		_env_accel = Vector3.ZERO
		_env_ground = INF
		_env_alpha_bias = 0.0
		_env_drag_bonus = 0.0
		_env_lift_scale = 1.0
		_stall_guard = false
	for i in n:
		_substep(ws, env, h)


## Re-reads the tuning after an in-place edit of its fields (a tuning panel);
## assigning a new tuning, changing assists or mass is picked up by itself.
func refresh() -> void:
	_ck_tuning = null
	_ck_h = -1.0


## Kinematic move with no velocity change (the player's physical head motion).
func displace(delta: Vector3) -> void:
	if FlightMath.vfinite(delta):
		position += delta
		_tick_y0 += delta.y


## Collision response (§12). Returns v_n, the speed into the surface.
## The contact deflects the VELOCITY: a slide keeps 92 % of the tangential
## velocity, a bounce (stun) 30 % of it plus `restitution` of v_n back out
## (walls 0.25; PlayerBird passes FlightTuning.floor_restitution for the
## ground). The body's HEADING changes as little as possible (fix round 4):
##  - slide: only as far as the model needs to represent the new path (the
##    body within the sideslip limit of it), at most `contact_turn_max_deg`;
##    the rest is sideslip, which weathercocks the body round smoothly;
##  - bounce: by `turn` (PlayerBird's small turn away from a wall, capped at
##    the same limit; 0 or NAN for floors and ceilings).
## Every heading change is reported in heading_step, and the player's view
## follows it smoothly (ViewTurn). Round 3 re-seated the heading on the
## bounced path and then turned it to leave the wall: a head-on stun swung
## the view 110 deg with no input from the player.
func apply_contact(normal: Vector3, kind: int, restitution := 0.25, turn := NAN) -> float:
	var n := normal.normalized()
	var vn := -velocity.dot(n)
	if vn <= 0.0:
		return vn
	var vt := velocity + n * vn
	if kind == Contact.SLIDE:
		velocity = vt * 0.92
	else:
		velocity = vt * 0.3 + n * (clampf(restitution, 0.0, 1.0) * vn)
	var cap := deg_to_rad(maxf(tuning.contact_turn_max_deg, 0.0))
	var h0 := chi + dpsi
	var psi := h0
	if kind == Contact.SLIDE:
		var va := velocity - wind
		if Vector2(va.x, va.z).length() >= 0.25 * _c_v_min:
			var d := wrapf(atan2(-va.x, -va.z) - h0, -PI, PI)
			if absf(d) < PI / 2:
				psi = h0 + signf(d) * minf(maxf(absf(d) - SLIP_MAX, 0.0), cap)
	elif is_finite(turn):
		psi = h0 + clampf(turn, -cap, cap)
	_seat_heading(wrapf(psi, -PI, PI), n)
	heading_step = wrapf(heading_step + wrapf(chi + dpsi - h0, -PI, PI), -PI, PI)
	_save_good()
	return vn


## The largest sideslip (rad) the yaw channel holds (dpsi is clamped to it).
const SLIP_MAX := 0.5


## Faces the body at `psi` against the current air velocity, in a state the
## model can hold: the air path within SLIP_MAX of the body (chi on the
## path, the difference as sideslip, which weathercocks away smoothly). A
## path further off would be snapped onto on the next substep (a heading
## jump); a bird cannot keep flying along a path it does not face, so the
## horizontal air velocity (speed kept) is turned to the sideslip limit on
## its side when that does not lead into the surface `n`, and otherwise
## removed: the bird drops, and flies on along its heading as it regains
## speed. (Keeping a backward path was tried: while the stunned bird fell,
## that path drifted inside 90 deg of the body and the heading snapped
## 84 deg.) Slow enough, the path does not turn the body at all.
func _seat_heading(psi: float, n: Vector3) -> void:
	var va := velocity - wind
	var vh := Vector2(va.x, va.z).length()
	if vh <= 0.25 * _c_v_min:
		# Too slow for the path to turn the body (_update_chi holds it here).
		chi = psi
		dpsi = 0.0
		return
	var th := atan2(-va.x, -va.z)
	var d := wrapf(th - psi, -PI, PI)
	if absf(d) > SLIP_MAX:
		th = psi + signf(d) * SLIP_MAX
		var f := FlightMath.yaw_forward(th)
		var nh := Vector2(n.x, n.z)
		if nh.length() > 0.3 and Vector2(f.x, f.z).dot(nh) < 0.0:
			velocity = wind + Vector3(0.0, va.y, 0.0)
			chi = psi
			dpsi = 0.0
			return
		velocity = wind + Vector3(f.x * vh, va.y, f.z * vh)
	chi = wrapf(th, -PI, PI)
	dpsi = clampf(wrapf(psi - th, -PI, PI), -SLIP_MAX, SLIP_MAX)


## The heading jumps since the last call (and clears them).
func take_heading_step() -> float:
	var s := heading_step
	heading_step = 0.0
	return s


## The acceleration the integrator applied in the last substep (m/s^2).
func last_accel() -> Vector3:
	return _acc_last


func heading() -> float:
	return chi + dpsi


## The stall guard's height (m of belly above the ground, fix round 5):
## below it a full flare is the maximum-lift flare. PlayerBird probes the
## ground this far down (fix round 6) so a flat roof counts as much as the
## terrain does.
func stall_guard_height() -> float:
	var tt := tuning
	return 0.4 * G * tt.forced_recovery * tt.forced_recovery + tt.stall_guard_vmin2g * params.v_min * params.v_min / G


## Beak direction with body pitch.
func forward() -> Vector3:
	return Basis(Vector3.UP, heading()) * (Basis(Vector3.RIGHT, theta) * Vector3.FORWARD)


func airspeed() -> float:
	return airspeed_v


func gamma() -> float:
	return gam


func drain_events() -> PackedStringArray:
	var e := _events.duplicate()
	_events.clear()
	return e


func telemetry() -> Dictionary:
	return {
		"airspeed": airspeed_v, "groundspeed": FlightMath.horiz(velocity).length(),
		"vertical_speed": velocity.y, "aoa": alpha, "bank": phi, "stalled": stalled,
		"g_load": g_load, "lift": lift_n, "drag": drag_n, "pitch": theta, "gamma": gam,
		"heading": heading(), "sideslip": dpsi, "yaw_rate": yaw_rate,
		"speed_ratio": airspeed_v / params.v_c, "stall_warning": stall_warning,
		"flap_force": flap_n, "flap_power": flap_power,
		"endurance": minf(endurance_l, endurance_r), "in_updraft": maxf(0.0, wind.y),
	}


# ---------------------------------------------------------------------------

func _substep(ws: WingState, env: FlightEnv, h: float) -> void:
	var w0 := _wind(env, position) if _has_wind else Vector3.ZERO
	wind = w0
	var va := velocity - w0
	var v := va.length()
	var vh := Vector2(va.x, va.z).length()
	airspeed_v = v
	var hd0 := chi + dpsi
	var wc := _update_chi(va, vh)
	if _has_wind:
		_absorb_wind_turn(velocity, w0, wc)
	_note_jump(hd0, h)
	var fh := Vector3(-sin(chi), 0.0, -cos(chi))
	var g0 := atan2(va.y, va.dot(fh)) if v > 1e-6 else 0.0
	gam = g0
	var spread := clampf(0.5 * (ws.ext_l + ws.ext_r), 0.0, 1.0)
	var f_a := 0.25 + 0.75 * spread
	var vmin := _c_v_min

	# --- flap smoothing and the endurance cap (G11)
	var pl0 := _p_l
	var pr0 := _p_r
	var ul0 := _u_l
	var ur0 := _u_r
	var fl := clampf(ws.flap_l, 0.0, 1.3)
	var fr := clampf(ws.flap_r, 0.0, 1.3)
	var ul := clampf(ws.up_l, 0.0, 1.0)
	var ur := clampf(ws.up_r, 0.0, 1.0)
	_p_l += (fl - _p_l) * _k_f
	_p_r += (fr - _p_r) * _k_f
	_u_l += (ul - _u_l) * _k_f
	_u_r += (ur - _u_r) * _k_f
	var ugp := maxf(0.0, _c_up_gain)
	# Endurance ring (inlined _endurance_push / _endurance_mean: hot path).
	_end_cum_l += (fl + ugp * ul) * h
	_end_cum_r += (fr + ugp * ur) * h
	_end_bucket_t += h
	while _end_bucket_t >= END_BUCKET - 1e-12:
		_end_bucket_t -= END_BUCKET
		_end_ring_l[_end_idx] = _end_cum_l
		_end_ring_r[_end_idx] = _end_cum_r
		_end_idx = (_end_idx + 1) % END_N
		_end_filled = mini(_end_filled + 1, END_N)
	var win := clampf(ws.stroke_period, 0.3, 1.5)
	var cap_e := _c_e_cap * _c_p_ref_pos
	var kb := clampi(int(round(win / END_BUCKET)), 1, END_N - 1)
	var st_l := 0.0
	var st_r := 0.0
	var span := win
	if _end_filled >= kb:
		var ib := posmod(_end_idx - kb, END_N)
		st_l = _end_ring_l[ib]
		st_r = _end_ring_r[ib]
		# The exact time the window covers (that entry was written kb - 1
		# bucket boundaries before the last one).
		span = maxf((kb - 1) * END_BUCKET + _end_bucket_t, END_BUCKET)
	endurance_l = minf(1.0, cap_e * win / maxf(_end_cum_l - st_l, 1e-6 * win))
	endurance_r = minf(1.0, cap_e * win / maxf(_end_cum_r - st_r, 1e-6 * win))
	# Each wing's net effort (flap + max(0, up_gain) up) averaged over the
	# last stroke period (fix round 4): the one-wing roll kick and paddle yaw
	# act on the stroke's MEAN asymmetry. The instantaneous difference swung
	# the bank and the heading with every wingbeat when the arms were only a
	# little uneven (10 % amplitude or 30 ms apart: 5-7 deg of view yaw
	# wobble per beat); over a whole stroke a timing offset averages out and
	# an amplitude difference is a steady turn.
	var m_l := maxf(_end_cum_l - st_l, 0.0) / span
	var m_r := maxf(_end_cum_r - st_r, 0.0) / span
	# Natural human asymmetry is a symmetric stroke: only the relative
	# asymmetry |l - r| / (l + r) beyond one_wing_deadzone (0.15, about a
	# 26 % amplitude difference) counts, rescaled to full strength at a
	# one-wing stroke (1). Within the dead zone a steady small bank made
	# every wingbeat's force pulse turn the view (1-1.5 deg per beat for a
	# climbing sparrow with one arm 20-25 % smaller).
	var mean_as := 0.5 * (m_l + m_r)
	var half_d := 0.5 * (m_l - m_r)
	var k_dz := 0.0
	if mean_as > 1e-9:
		var rel := absf(half_d) / mean_as
		if rel > _t_kick_dz:
			k_dz = (rel - _t_kick_dz) / ((1.0 - _t_kick_dz) * rel)
	_as_l = mean_as + half_d * k_dz
	_as_r = mean_as - half_d * k_dz

	# --- speed-rate damper input and regime filters. dV/dt comes from the
	# integrator's own tangential acceleration (exact, no finite-difference
	# lag): the damper feeds it back at 0.4 rad per g.
	var udot_raw := _acc_last.dot(va) / v if v > 1e-3 else 0.0
	_udot += (udot_raw - _udot) * _k_ud
	_v_lp += (v - _v_lp) * _k_lp
	_vh_lp += (vh - _vh_lp) * _k_lp

	# --- pitch (7.4)
	var a_cmd := _alpha_cmd(ws, v, f_a, h)
	var tt := clampf((maxf(_vh_lp / vmin, (_v_lp - vmin) / (0.5 * vmin)) - 0.5) / 0.7, 0.0, 1.0)
	var th_hi := PI / 2 * tt * tt * (3.0 - 2.0 * tt)
	var pm := 0.5 * (_p_l + _p_r)
	var hov := 0.0
	if pm > 0.05 and _v_lp < 0.6 * vmin:
		hov = FlightMath.sstep(0.05, 0.2, pm) * (1.0 - FlightMath.sstep(0.3, 0.6, _v_lp / vmin))
	_hov = hov
	var th_lo := -PI / 2 * (1.0 - hov)
	var target := clampf(g0 + a_cmd, th_lo, th_hi)
	var theta0 := theta
	var phi0 := phi
	# Exact first-order response (k = 1 - e^-h/tau, the spec's filter rule),
	# rate-limited: explicit h/tau made the attitude lead by h/2 per transient.
	var qh := _c_q_max * h
	theta += clampf((target - theta) * _k_al, -qh, qh)
	var protect_on := _as_protect
	var aoa_valid := _v_lp >= 0.5 * vmin
	var clamp_on := protect_on and _delib_t < _hold and not stalled and aoa_valid
	if clamp_on:
		# The protection holds alpha below the stall, but never rotates the
		# body faster than its pitch rate (a path that turns faster, e.g. the
		# top of a vertical zoom, would otherwise drag the body with it).
		theta = maxf(theta - qh, minf(theta, g0 + _c_alpha_s - _r_enter))
	var alpha_m := theta - g0

	# --- stall FSM (7.5). AoA only means something with real airspeed (the
	# same 0.5 V_min gate as the protection): a hovering or launching bird
	# sees alpha ~ 90 deg and must not enter it (wing drop, buffet haptics).
	if not stalled and aoa_valid and alpha_m > _c_alpha_s + _r_enter:
		stalled = true
		stall_count += 1
		_t_stall = 0.0
		_events.append("stall")
		if absf(phi) > 0.01745:
			_stall_side = signf(phi)
		elif absf(ws.roll) > 0.02:
			_stall_side = signf(ws.roll)
		else:
			_stall_side = -_stall_side
	if stalled:
		_t_stall += h
		# A stall is held while the player holds the deliberate pitch, but not
		# below the stall guard height (fix round 5): there the flow
		# reattaches as soon as the nose is down again (_alpha_cmd).
		var held := protect_on and ws.pitch >= _t_deliberate_pitch and _t_stall <= _t_forced_recovery and not _stall_guard
		if _t_stall > 0.3 and (alpha_m < _c_alpha_s - _r_exit or _v_lp < 0.4 * vmin) and not held:
			stalled = false
			_events.append("unstall")
	if stalled or sigma > 1e-6:
		sigma += ((1.0 if stalled else 0.0) - sigma) * _k_sep
	if stalled:
		stall_warning = 1.0
	elif alpha_m > _c_alpha_s - _r_warn and _v_lp > 0.4 * vmin:
		stall_warning = FlightMath.sstep(_c_alpha_s - _r_warn, _c_alpha_s, alpha_m) * FlightMath.sstep(0.4, 0.5, _v_lp / vmin)
	else:
		stall_warning = 0.0

	# --- bank (7.6); ws.roll already includes PlayerBird's body steer
	var phi_cmd := clampf(ws.roll, -1.0, 1.0) * _c_phi_max + _r_kick * (_as_l - _as_r) \
		+ _ext_roll * (clampf(ws.ext_l, 0.0, 1.0) - clampf(ws.ext_r, 0.0, 1.0)) * _c_phi_max
	if stalled:
		phi_cmd += _r_drop * _stall_side * FlightMath.sstep(0.0, 0.5, _t_stall)
	var lim := _c_phi_max
	var plim := _c_p_max * clampf(v / _c_v_c, 0.4, 1.25)
	# Comfort caps as bank limits (§11.2), generalised to the ACTUAL normal
	# load n = (lift + flap) along the lift axis: psi_dot = n g sin(phi) / V_h.
	# For a level 1-g turn (n = 1 / cos phi) these are exactly the spec's
	# atan(Psi_max V / g) and Psi2_max V cos^2(phi) / g; with flapping (flap
	# force tilts with the bank) n is larger and the bank limit tightens.
	if comfort_yaw_rate > 0.0 or comfort_yaw_accel > 0.0:
		var cph := cos(phi)
		var n_load := maxf(maxf(g_load, 1.0 / maxf(cph, 0.2)), 0.5)
		# The heading turns with the HORIZONTAL velocity: psi_dot = n g sin(phi) / (V cos(gamma)).
		var vv := maxf(vh, 0.5 * vmin)
		if comfort_yaw_rate > 0.0:
			var sl := comfort_yaw_rate * vv / (n_load * G)
			if sl < 1.0:
				lim = minf(lim, asin(sl))
		if comfort_yaw_accel > 0.0:
			plim = minf(plim, comfort_yaw_accel * vv / (n_load * G * maxf(cph, 0.2)))
	var dphi := clampf((clampf(phi_cmd, -lim, lim) - phi) * _k_bk, -plim * h, plim * h)
	phidot = dphi / h
	phi += dphi

	# --- yaw offset channel (7.6)
	var n_adv := 0.0
	if k_rud < 1.0:
		n_adv = (1.0 - k_rud) * _t_adverse * clampf(_c_a * alpha_m / _c_cl_n, -2.0, 5.0) * phidot
	var n_kick := 0.0
	if _as_l > 1e-6 or _as_r > 1e-6:
		# (Equal efforts still yaw when the wings are tilted differently:
		# the forward-tilted wing's thrust, a real effect of twisting while
		# flapping.)
		var d_l := asin(clampf(-ws.flap_dir_l.z, -1.0, 1.0))
		var d_r := asin(clampf(-ws.flap_dir_r.z, -1.0, 1.0))
		n_kick = -_t_paddle_yaw * (_as_l * (0.3 + sin(d_l)) - _as_r * (0.3 + sin(d_r)))
	dpsi += (n_adv + n_kick - dpsi / _c_tau_wc - dpsi / _c_tau_sf) * h
	dpsi = clampf(dpsi, -0.5, 0.5)

	# --- translate: Heun (RK2) with symmetric splitting: stage one sees the
	# attitude and flap state at the start of the substep, stage two at its end.
	var heading0 := chi + dpsi
	var a1 := _acc(position, velocity, ws, env, f_a, alpha_m, true, theta0, phi0, pl0, pr0, ul0, ur0)
	var a2 := _acc(position + velocity * h, velocity + a1 * h, ws, env, f_a, alpha_m, false, theta, phi, _p_l, _p_r, _u_l, _u_r)
	_acc_last = 0.5 * (a1 + a2)
	var v_new := velocity + _acc_last * h
	position += (velocity + v_new) * (0.5 * h)
	velocity = v_new
	flap_impulse += (f_flap + _f_flap2) * (0.5 * h)

	# --- weathercock feed-forward (D2): the body rotates with its path.
	# Gated on the CURRENT airspeed as well as the filtered one, and at most
	# the pitch rate: at the top of a vertical zoom the velocity reverses and
	# the path angle flips by 180 deg in one substep while the 0.5 s
	# low-passed speed still says "flying" (the body flipped with it).
	var w2 := _wind(env, position) if _has_wind else Vector3.ZERO
	var va2 := velocity - w2
	var va2_len := va2.length()
	var g2 := atan2(va2.y, va2.dot(fh)) if va2_len > 1e-6 else g0
	var v_gate := minf(_v_lp, va2_len)
	if v_gate > 0.5 * vmin:
		var tw := clampf((v_gate - 0.5 * vmin) / (0.5 * vmin), 0.0, 1.0)
		theta += clampf(tw * tw * (3.0 - 2.0 * tw) * wrapf(g2 - g0, -PI, PI), -qh, qh)
	if protect_on and _delib_t < _hold and not stalled and aoa_valid:
		theta = maxf(theta - qh, minf(theta, g2 + _c_alpha_s - _r_enter))
	theta = clampf(theta, -PI / 2, PI / 2)
	var hd1 := chi + dpsi
	var wc2 := _update_chi(va2, Vector2(va2.x, va2.z).length())
	if _has_wind:
		_absorb_wind_turn(velocity, w2, wc2)
	_note_jump(hd1, h)
	gam = atan2(va2.y, va2.dot(Vector3(-sin(chi), 0.0, -cos(chi)))) if va2_len > 1e-6 else g2
	alpha = theta - gam
	yaw_rate = wrapf(chi + dpsi - heading0, -PI, PI) / h
	yaw_acc += ((yaw_rate - _yaw_rate_prev) / h - yaw_acc) * _k_ya
	_yaw_rate_prev = yaw_rate
	_guard_finite()


static func _inputs_finite(ws: WingState) -> bool:
	# One sum: NaN or +-inf anywhere makes it non-finite (inf - inf is NaN).
	var a := ws.flap_dir_l
	var b := ws.flap_dir_r
	return is_finite(ws.pitch + ws.roll + ws.ext_l + ws.ext_r + ws.flap_l + ws.flap_r + ws.up_l + ws.up_r \
		+ a.x + a.y + a.z + b.x + b.y + b.z + ws.stroke_period)


static func _sanitize(ws: WingState) -> void:
	if not is_finite(ws.pitch): ws.pitch = 0.0
	if not is_finite(ws.roll): ws.roll = 0.0
	if not is_finite(ws.ext_l): ws.ext_l = 1.0
	if not is_finite(ws.ext_r): ws.ext_r = 1.0
	if not is_finite(ws.flap_l): ws.flap_l = 0.0
	if not is_finite(ws.flap_r): ws.flap_r = 0.0
	if not is_finite(ws.up_l): ws.up_l = 0.0
	if not is_finite(ws.up_r): ws.up_r = 0.0
	if not FlightMath.vfinite(ws.flap_dir_l): ws.flap_dir_l = Vector3.UP
	if not FlightMath.vfinite(ws.flap_dir_r): ws.flap_dir_r = Vector3.UP
	if not is_finite(ws.stroke_period): ws.stroke_period = 1.0


func _refresh_cache() -> void:
	var pp := params
	_c_a = pp.a
	_c_alpha_n = pp.alpha_n
	_c_alpha_s = pp.alpha_s
	_c_cd0 = pp.cd0
	_c_cl_max = pp.cl_max
	_c_cl_n = pp.cl_n
	_c_e_cap = pp.e_cap
	_c_k_flap = pp.k_flap
	_c_k_hover = pp.k_hover
	_c_k_i = pp.k_i
	_c_mass = pp.mass
	_c_n_max = pp.n_max
	_c_p_max = pp.p_max
	_c_p_ref = pp.p_ref
	_c_p_ref_pos = pp.p_ref_pos
	_c_p_spec = pp.p_spec
	_c_phi_max = pp.phi_max
	_c_q_max = pp.q_max
	_c_r_body = pp.r_body
	_c_s = pp.s
	_c_span = pp.span
	_c_tau_sf = pp.tau_sf
	_c_tau_wc = pp.tau_wc
	_c_up_gain = pp.up_gain
	_c_v_c = pp.v_c
	_c_v_max = pp.v_max
	_c_v_min = pp.v_min
	var tt := tuning
	_t_adverse = tt.adverse
	_t_cl_min = tt.cl_min
	_t_damper_down = tt.damper_down
	_t_damper_up = tt.damper_up
	_t_deliberate_pitch = tt.deliberate_pitch
	_t_forced_recovery = tt.forced_recovery
	_t_governor_gain = tt.governor_gain
	_t_governor_start = tt.governor_start
	_t_ground_lift_gain = tt.ground_lift_gain
	_t_guard_h = 0.4 * G * tt.forced_recovery * tt.forced_recovery + tt.stall_guard_vmin2g * pp.v_min * pp.v_min / G
	_t_paddle_yaw = tt.paddle_yaw
	_t_flap_side = clampf(tt.flap_side_share, 0.0, 1.0)
	_t_kick_dz = clampf(tt.one_wing_deadzone, 0.0, 0.9)
	_t_plate_drag = tt.plate_drag
	_t_post_stall_plateau = tt.post_stall_plateau
	_t_rho = tt.rho
	_t_stall_drag = tt.stall_drag
	_as_protect = assists.get(&"stall_protect", true)
	_as_turn = assists.get(&"turn_comp", true)
	_as_damper = assists.get(&"damper", true)
	_as_nlimit = assists.get(&"nlimit", true)
	_as_floor = assists.get(&"flap_floor", true)
	_as_cushion = assists.get(&"ground_cushion", true)
	_as_novice = assists.get(&"novice", false)
	var tu := tuning
	_r_top = deg_to_rad(tu.margin_top_deg)
	_r_enter = deg_to_rad(tu.margin_enter_deg)
	_r_exit = deg_to_rad(tu.margin_exit_deg)
	_r_simtop = deg_to_rad(tu.margin_sim_top_deg)
	_r_warn = deg_to_rad(tu.warn_margin_deg)
	_r_tuck = deg_to_rad(tu.tuck_bias_deg)
	_r_kick = deg_to_rad(tu.roll_kick_deg)
	_r_drop = deg_to_rad(tu.wing_drop_deg)
	_r_nose = deg_to_rad(tu.nose_drop_deg_s)
	_r_floor = deg_to_rad(tu.flap_floor_deg)
	_hold = tu.deliberate_hold_value()
	_turn_comp = tu.turn_comp_value()
	_ext_roll = tu.ext_roll
	_cushion_g = tu.cushion_g
	_top = params.alpha_s - _r_top if _as_protect else params.alpha_s + _r_simtop


func _wind(env: FlightEnv, pos: Vector3) -> Vector3:
	# One step never moves the world's clock, so the wind at a point is the
	# same for the whole step: a substep's first Heun evaluation is where the
	# substep starts, which is where the last one ended (fix round 6: half of
	# the 8 World.get_wind calls a tick were repeats, ~12 us). Exact: a hit
	# is the same point, bit for bit, in the same step.
	if pos == _wc_pos0 and _wc_ok0:
		return _wc_val0
	if pos == _wc_pos1 and _wc_ok1:
		return _wc_val1
	var w: Vector3 = env.wind_fn.call(pos)
	if not is_finite(w.x + w.y + w.z):
		w = Vector3.ZERO
	_wc_pos1 = _wc_pos0
	_wc_val1 = _wc_val0
	_wc_ok1 = _wc_ok0
	_wc_pos0 = pos
	_wc_val0 = w
	_wc_ok0 = true
	return w


## §7.3 step 1: follow the air-velocity heading, held when slow, never
## flipped by a tail-slide or a vertical climb. Returns the share of the
## change that was applied (0 = held).
func _update_chi(va: Vector3, vh: float) -> float:
	if vh < 1e-6:
		return 0.0
	# Held below 0.25 V_min, fully following from 0.6 V_min. The spec's
	# 0.1..0.4 band let a hovering bird's heading chase its 0.5 m/s bob-drift
	# (160 deg in 2 s, peaks of 375 deg/s: the rig would spin while hovering).
	# In sustained flight vh >= V_min, so turns are unaffected.
	var r := vh / _c_v_min
	if r <= 0.25:
		return 0.0
	var w := 1.0
	if r < 0.6:
		var t := (r - 0.25) / 0.35
		w = t * t * (3.0 - 2.0 * t)
	var d := wrapf(atan2(-va.x, -va.z) - chi, -PI, PI)
	if absf(d) < PI / 2:
		chi = wrapf(chi + w * d, -PI, PI)
		return w
	return 0.0


## A change of the wind (a gust front, flying into another air mass) turns
## the AIR path under the bird, not its body. chi follows the air (the
## aerodynamics need it); the part of that turn the wind caused is taken
## back into the sideslip channel, so the heading (chi + dpsi) does not jump
## with the air: the sideslip then weathercocks the body round (tau_wc) while
## its side force carries the bird with the air (tau_sf), and the heading
## settles 0.375 of the way into the new relative wind, smoothly. Round 2
## followed the air instantly: a gust front stepped the view's yaw rate in
## one tick (up to the 720 deg/s^2 cap; verifier round 3).
func _absorb_wind_turn(v: Vector3, w_new: Vector3, applied: float) -> void:
	if not _w_chi_ok:
		_w_chi = w_new
		_w_chi_ok = true
		return
	if w_new == _w_chi:
		return
	var a := v - _w_chi
	var b := v - w_new
	_w_chi = w_new
	if applied <= 0.0 or a.x * a.x + a.z * a.z < 1e-6 or b.x * b.x + b.z * b.z < 1e-6:
		return
	var s := wrapf(atan2(-b.x, -b.z) - atan2(-a.x, -a.z), -PI, PI)
	if absf(s) >= PI / 2:
		return
	# Beyond the sideslip limit the body does turn with the air (the caller's
	# _note_jump reports it if that is faster than a flown turn).
	dpsi = clampf(dpsi - applied * s, -0.5, 0.5)


## A heading change within one substep faster than any flown turn (the
## player's cap is 240 deg/s; 6 rad/s is 344) is a jump, not a turn.
func _note_jump(h0: float, h: float) -> void:
	var dj := wrapf(chi + dpsi - h0, -PI, PI)
	if absf(dj) > 6.0 * h:
		heading_step = wrapf(heading_step + dj, -PI, PI)


## The pitch map before the dynamic terms: nose-up linear in alpha (the
## balloon lever), nose-down linear in lift (full down = zero lift), tuck bias.
func _alpha_base(pitch_cmd: float, spread: float) -> float:
	var p := params
	var pc := clampf(pitch_cmd, -1.0, 1.0)
	var top := p.alpha_s - deg_to_rad(tuning.margin_top_deg) if assists.get(&"stall_protect", true) \
		else p.alpha_s + deg_to_rad(tuning.margin_sim_top_deg)
	var ab := 0.0
	if pc >= 0.0:
		ab = p.alpha_n + pc * (top - p.alpha_n)
	else:
		ab = p.alpha_n * (1.0 + pc)
	ab += -deg_to_rad(tuning.tuck_bias_deg) * clampf((0.5 - spread) / 0.5, 0.0, 1.0)
	return ab


func _alpha_cmd(ws: WingState, v: float, f_a: float, h: float) -> float:
	var pc := clampf(ws.pitch, -1.0, 1.0)
	var spread := clampf(0.5 * (ws.ext_l + ws.ext_r), 0.0, 1.0)
	var ab := 0.0
	if pc >= 0.0:
		ab = _c_alpha_n + pc * (_top - _c_alpha_n)
	else:
		ab = _c_alpha_n * (1.0 + pc)
	if spread < 0.5:
		ab -= _r_tuck * (0.5 - spread) / 0.5
	if _as_turn and ab > 0.0 and phi != 0.0:
		ab *= 1.0 + _turn_comp * (1.0 / maxf(cos(phi), 0.34) - 1.0)
	if _as_damper and not stalled:
		var k := _t_damper_up if _udot > 0.0 else _t_damper_down
		var rv := _c_v_c / maxf(v, 0.1)
		ab += k * clampf(_udot / G, -1.0, 1.0) * minf(1.0, rv * rv)
	if _as_nlimit and ab > 0.0:
		var q := 0.5 * _t_rho * v * v
		if q > 1e-6:
			ab = minf(ab, _c_n_max * _c_mass * G / (q * _c_s * f_a * _c_a))
	if _as_protect:
		# Holding full nose-up commits to a stall (F3), except near the ground
		# (fix round 5, tuning.stall_guard_vmin2g): there a full flare is the
		# maximum-lift flare that lands. Round 4 let a flare from the glide
		# speed zoom a sparrow 10 spans up, stall it there and hold the stall
		# while the nose dropped to -45 deg: it dived into the grass at
		# 4.7 m/s and was stunned from every flare height tried.
		_delib_t = _delib_t + h if pc >= _t_deliberate_pitch and not _stall_guard else 0.0
		if _delib_t >= _hold:
			ab = _c_alpha_s + _r_simtop * pc
		else:
			ab = minf(ab, _c_alpha_s - _r_top)
	if stalled:
		ab -= _r_nose * _t_stall
		if _t_stall > _t_forced_recovery:
			ab = minf(ab, _c_alpha_s - _r_exit)
	return ab


## The lift curve the model flies: CL at angle of attack `a` (rad) with the
## stall's separation blend `separation` (0 = attached flow, 1 = the settled
## stalled flow). Tests and plots read the aerodynamics through this (F3:
## the lift collapses past the stall); the state is not changed.
func lift_coefficient(a: float, separation: float) -> float:
	var s0 := sigma
	sigma = clampf(separation, 0.0, 1.0)
	var cl := _cl_of(a, a)
	sigma = s0
	return cl


## Lift coefficient (§7.5): attached slope, geometric separation past
## alpha_s, the stalled separation blend, post-stall plate lift.
func _cl_of(a: float, alpha_m: float) -> float:
	var cl_att := clampf(_c_a * a, _t_cl_min, 1.05 * _c_cl_max)
	var am := absf(alpha_m)
	var s_geo := 0.0
	if am > _c_alpha_s + 0.01745:
		s_geo = FlightMath.sstep(_c_alpha_s + 0.01745, _c_alpha_s + 0.10472, am)
	var sep := maxf(sigma, s_geo)
	if sep <= 0.0:
		return cl_att
	# Plateau term clamped on BOTH sides: the spec's min(a alpha, 0.6 CL_max)
	# leaves negative alpha unbounded (CL -2 at -25 deg, a nose-down "rocket");
	# the attached curve's own floor (cl_min) is the physical bound.
	var cl_post := lerpf(clampf(_c_a * a, _t_cl_min, _t_post_stall_plateau * _c_cl_max), 0.9 * sin(2.0 * a),
		FlightMath.sstep(_c_alpha_s + 0.03491, _c_alpha_s + 0.34907, absf(a)))
	return lerpf(cl_att, cl_post, sep)


func _cd_of(a: float, cl: float, f_a: float, drag_bonus: float, ground_h: float) -> float:
	var ind := f_a * _c_k_i * cl * cl
	if ground_h < _c_span and _as_cushion:
		var r := 1.0 - maxf(ground_h, 0.0) / _c_span
		ind *= 1.0 - 0.5 * r * r
	var cd := _c_cd0 * (0.35 + 0.65 * f_a) + ind + _t_stall_drag * sigma + drag_bonus
	var aa := absf(a)
	if aa > _c_alpha_s:
		var sa := sin(a)
		cd += _t_plate_drag * sa * sa * FlightMath.sstep(_c_alpha_s, _c_alpha_s + 0.2618, aa)
	return cd


func _governor(v: float) -> float:
	var p := params
	var ex := v / p.v_max - tuning.governor_start
	if ex <= 0.0:
		return 0.0
	return p.mass * G * tuning.governor_gain * ex * ex


func _acc(x: Vector3, v: Vector3, ws: WingState, env: FlightEnv, f_a: float, alpha_m: float, commit: bool,
		th: float, ph: float, pl: float, pr: float, ul: float, ur: float) -> Vector3:
	var va := v - _wind(env, x) if _has_wind else v
	var vmag := va.length()
	var vh := Vector2(va.x, va.z).length()
	var sc := sin(chi)
	var cc := cos(chi)
	var fh := Vector3(-sc, 0.0, -cc)
	var rh := Vector3(cc, 0.0, -sc)
	var cph := cos(ph)
	var sph := sin(ph)
	var acc := Vector3(0.0, -G, 0.0) + _env_accel
	var ground_h := INF
	if _env_ground < INF:
		ground_h = _env_ground - (x.y - _tick_y0)
	var l_vec := Vector3.ZERO
	var d_vec := Vector3.ZERO
	var lh := Vector3.UP
	var inv_m := 1.0 / _c_mass
	if vmag > 1e-4:
		var g1 := atan2(va.y, va.dot(fh))
		var a_eff := wrapf(th - g1 + _env_alpha_bias, -PI, PI)
		var vhat := va / vmag
		var rp := rh - vhat * rh.dot(vhat)
		var rpl := rp.length()
		var perp := (rp / rpl).cross(vhat) if rpl > 1e-6 else (Vector3.UP * cos(g1) - fh * sin(g1))
		lh = perp * cph + vhat.cross(perp) * sph
		var cl := _cl_of(a_eff, alpha_m)
		var cd := _cd_of(a_eff, cl, f_a, _env_drag_bonus, ground_h)
		var q := 0.5 * _t_rho * vmag * vmag * _env_lift_scale
		# Ground effect (G15): within a span of the ground the same wing makes
		# more lift (and less induced drag, in _cd_of), so a low glide floats.
		var ge := 1.0
		if _as_cushion and ground_h - _c_r_body < _c_span:
			var rg := 1.0 - maxf(ground_h - _c_r_body, 0.0) / _c_span
			ge = 1.0 + _t_ground_lift_gain * rg * rg
		# In a powered hover the wing's force IS the flap force (K_H); the
		# glide polar's lift at the +-60 deg incidences of the wingbeat bob
		# would count the same wing twice and push the bird around, so it
		# fades out with the hover blend. Drag stays (it damps the bob).
		var lift := q * _c_s * f_a * cl * (1.0 - _hov) * ge
		var drag := 0.0
		if drag_enabled:
			drag = q * _c_s * cd
			var ex := vmag / _c_v_max - _t_governor_start
			if ex > 0.0:
				drag += _c_mass * G * _t_governor_gain * ex * ex
		l_vec = lh * lift
		d_vec = vhat * -drag
		acc += (l_vec + d_vec) * inv_m
		if commit:
			lift_n = lift
			drag_n = drag
			_cl = cl
			lhat = lh
		# Ground cushion (G15): ground effect catches a skimming glide. Height
		# is the BELLY's (centre minus body radius) and the cushion is a soft
		# sink damper: the spec's 0.6 g at the centre height gave ~0.2 g at
		# touchdown, which cannot stop even a trimmed glide's sink.
		var belly := ground_h - _c_r_body
		if belly < 0.5 * _c_span and va.y < 0.0 and g1 > -0.6109 and _as_cushion:
			var cg := _cushion_g * (1.33 if _as_novice else 1.0)
			var r := 1.0 - maxf(belly, 0.0) / (0.5 * _c_span)
			acc.y += cg * G * r * r * minf(1.0, -va.y / 1.0)
	elif commit:
		lift_n = 0.0
		drag_n = 0.0
	# --- flaps (7.7)
	var ffl := Vector3.ZERO
	var fpow := 0.0
	if pl > 1e-9 or pr > 1e-9 or ul > 1e-9 or ur > 1e-9:
		var rr := vh / _c_v_min
		var k := _c_k_flap if rr >= 1.0 else lerpf(_c_k_hover, _c_k_flap, rr * rr * (3.0 - 2.0 * rr))
		var up_b := Vector3.UP * cph + rh * sph
		var r_b := rh * cph - Vector3.UP * sph
		var floor_tilt := 0.0
		if _as_floor and _c_k_hover < 1.0 and va.y < 0.0 and (pl + pr) > 0.05 \
				and vh < 0.8 * _c_v_min and ws.pitch <= 0.3:
			floor_tilt = _r_floor * (1.0 - vh / (0.8 * _c_v_min))
		var half_w := 0.5 * _c_mass * G
		var ugp := maxf(0.0, _c_up_gain)
		for side in 2:
			var en := endurance_l if side == 0 else endurance_r
			var dn := (pl if side == 0 else pr) * en
			var up := (ul if side == 0 else ur) * en
			var e := dn + _c_up_gain * up
			if absf(e) < 1e-9:
				continue
			var d: Vector3 = ws.flap_dir_l if side == 0 else ws.flap_dir_r
			var dh := r_b * d.x + up_b * d.y - fh * d.z
			var dl2 := dh.length_squared()
			if dl2 < 1e-12:
				continue
			dh /= sqrt(dl2)
			if floor_tilt > 0.0:
				dh = (dh * cos(floor_tilt) + fh * sin(floor_tilt)).normalized()
			# The wing normal's component across the body (the arm's droop or
			# raise during the stroke) is not a force on the body (fix round 4):
			# only its lift and thrust parts push. Late in a downstroke the wing
			# droops 20-45 deg, so each wing pushed the body sideways toward its
			# own side; symmetric strokes cancelled it, but one arm stroking (or
			# the stronger of two) shoved the bird toward the stroking wing at up
			# to 0.76 g and the turn went the wrong way after the first beat.
			# The stroke's roll and yaw moments are the roll kick and the paddle
			# yaw (7.6). Symmetric strokes are unchanged (their parts cancelled).
			dh -= r_b * (dh.dot(r_b) * (1.0 - _t_flap_side))
			var f := half_w * k * e / _c_p_ref
			var dv := dh.dot(va)
			if f > 0.0 and dv > 1e-6:
				f = minf(f, half_w * _c_p_spec * (dn + ugp * up) / _c_p_ref_pos / dv)
			# Thin air under the arena's lid (integration fix): the wing pushes
			# on air of density ratio lift_scale, so the stroke's force (and the
			# power it puts into the air) fades with it exactly as lift and drag
			# do. Before, only lift and drag faded: a flapping bird's thrust
			# carried it through the fade to the lid at full climb rate, where
			# it was stunned again and again.
			f *= _env_lift_scale
			ffl += dh * f
			fpow += f * maxf(dv, 0.0)
		acc += ffl * inv_m
	# Side force from the yaw offset: the path follows the body.
	if vh > 1e-3 and dpsi != 0.0:
		acc -= rh * (vh * dpsi / _c_tau_sf)
	if not commit:
		_f_flap2 = ffl
	if commit:
		f_lift = l_vec
		f_drag = d_vec
		f_flap = ffl
		f_gravity = Vector3(0.0, -G * _c_mass, 0.0)
		flap_n = ffl.length()
		flap_power = fpow * inv_m
		g_load = (l_vec + ffl).dot(lh) * inv_m / G
	return acc


func _save_good() -> void:
	_g_pos = position
	_g_vel = velocity
	_g_att = Vector4(chi, dpsi, theta, phi)
	_g_flap = Vector4(_p_l, _p_r, _u_l, _u_r)
	_g_lp = Vector2(_v_lp, _vh_lp)


func _guard_finite() -> void:
	if not is_finite(heading_step):
		heading_step = 0.0
	var ok := is_finite(position.x + position.y + position.z + velocity.x + velocity.y + velocity.z \
		+ chi + dpsi + theta + phi + _p_l + _p_r + _u_l + _u_r + _udot + _v_lp + sigma + yaw_acc)
	if not ok:
		if not _guard_logged:
			_guard_logged = true
			push_warning("[flight] non-finite state restored to last good state")
		position = _g_pos
		velocity = _g_vel
		chi = _g_att.x
		dpsi = _g_att.y
		theta = _g_att.z
		phi = _g_att.w
		_p_l = _g_flap.x
		_p_r = _g_flap.y
		_u_l = _g_flap.z
		_u_r = _g_flap.w
		_v_lp = _g_lp.x
		_vh_lp = _g_lp.y
		phidot = 0.0
		_udot = 0.0
		yaw_rate = 0.0
		yaw_acc = 0.0
		_yaw_rate_prev = 0.0
		sigma = 0.0
		_acc_last = Vector3.ZERO
		return
	var cap := 3.0 * params.v_max
	if velocity.length_squared() > cap * cap:
		velocity = velocity.normalized() * cap
	_save_good()


# ---------------------------------------------------------------------------
# The published envelope (§7.12), for AI, HUD and tests.

static func envelope(mass: float, p_tuning: FlightTuning = null) -> Dictionary:
	var m := FlightModel.new(mass, p_tuning)
	var p := m.params
	var tr0 := m.trim_solution(0.0)
	var tr_slow := m.trim_solution(0.88)
	var cruise: float = tr0["v"]
	var glide_ratio := p.cl_n / (p.cd0 + p.k_i * p.cl_n * p.cl_n)
	# Minimum sink over the attached range.
	var min_sink := INF
	for i in 41:
		var pc := -0.3 + 1.2 * i / 40.0
		var s := m.trim_solution(minf(pc, 0.88))
		min_sink = minf(min_sink, -float(s["v"]) * sin(float(s["gamma"])))
	# Roll t90 at roll 0.6 (first order, rate-limited), from wings level.
	var phi_r := 0.0
	var t90 := 0.0
	var tgt := 0.6 * p.phi_max
	var hh := 1.0 / 240.0
	while phi_r < 0.9 * tgt and t90 < 5.0:
		var pl := p.p_max
		phi_r += clampf((tgt - phi_r) / p.tau_bank, -pl, pl) * hh
		t90 += hh
	var climb := _climb_curve(p, m.tuning)
	return {
		"cruise": cruise, "min_speed": float(tr_slow["v"]), "max_speed": p.v_max,
		"phi_max": p.phi_max, "n_max": p.n_max, "turn_rate_cruise": G * tan(p.phi_max) / p.v_c,
		"t90_roll": t90, "climb_best": climb.x, "v_climb_best": climb.y, "climb_at_cruise": climb.z,
		"glide_ratio": glide_ratio, "min_sink": min_sink, "hover_capable": p.k_hover * p.e_cap >= 1.0,
		"t_phugoid": p.t_ph,
	}


## Steady powered climb from the §7.7 force and power law with the reference
## stroke (mean force K m g along the stroke direction, muscle power capped
## at P_spec per unit weight): Vector3(best climb, its speed, climb at
## cruise). It solves the same steady problems FM-13 flies: best climb over
## wrist pitch {0, 0.2, 0.4} x stroke tilt {0..30 deg}; climb at cruise with
## the speed held at V_c by pitch, stroke tilt <= 35 deg and effort <= 1.
static func _climb_curve(p: FlightParams, tu: FlightTuning) -> Vector3:
	var best := -INF
	var v_best := 0.0
	var mg := p.mass * G
	var top := p.alpha_s - deg_to_rad(tu.margin_top_deg)
	for pc in [0.0, 0.2, 0.4]:
		var cl: float = p.a * (p.alpha_n + pc * (top - p.alpha_n))
		for it in 7:
			var tau := deg_to_rad(5.0 * it)
			var vv := p.v_c
			var g1 := 0.0
			var ok := true
			for k in 80:
				var sg := sin(tau + g1)
				var kk := lerpf(p.k_hover, p.k_flap, FlightMath.sstep(0.0, 1.0, vv * cos(g1) / p.v_min))
				var f := kk * mg
				if sg > 1e-6:
					f = minf(f, mg * p.p_spec / (vv * sg))
				var nrm := mg * cos(g1) - f * cos(tau + g1)
				if nrm <= 0.0:
					ok = false
					break
				var v2 := sqrt(2.0 * nrm / (tu.rho * p.s * cl))
				vv = lerpf(vv, v2, 0.5)
				var q := 0.5 * tu.rho * vv * vv
				var dr := q * p.s * (p.cd0 + p.k_i * cl * cl)
				g1 = lerpf(g1, asin(clampf((f * sin(tau + g1) - dr) / mg, -1.0, 1.0)), 0.5)
			if ok and vv * sin(g1) > best:
				best = vv * sin(g1)
				v_best = vv
	var at_cruise := -INF
	var vc := p.v_c
	var qc := 0.5 * tu.rho * vc * vc
	for it in 8:
		var tau := deg_to_rad(5.0 * it)
		for ie in 8:
			var e := 0.3 + 0.1 * ie
			var g1 := 0.0
			var ok := true
			for k in 60:
				var sg := sin(tau + g1)
				var f := p.k_flap * mg * e
				if sg > 1e-6:
					f = minf(f, mg * p.p_spec * e / (vc * sg))
				var cl := (mg * cos(g1) - f * cos(tau + g1)) / (qc * p.s)
				if cl < 0.0 or cl > p.a * top:
					ok = false
					break
				var dr := qc * p.s * (p.cd0 + p.k_i * cl * cl)
				g1 = lerpf(g1, asin(clampf((f * sg - dr) / mg, -1.0, 1.0)), 0.5)
			if ok:
				at_cruise = maxf(at_cruise, vc * sin(g1))
	return Vector3(best, v_best, at_cruise)
