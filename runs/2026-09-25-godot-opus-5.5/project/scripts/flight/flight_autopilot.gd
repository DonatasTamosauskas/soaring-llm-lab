class_name FlightAutopilot
extends RefCounted
## A pilot that flies the FlightCourse (FLIGHT_SPEC §14.4). It sees only
## what a player sees (position, velocity, airspeed) plus the read-only
## FlightParams, and outputs commands (pitch, roll, spread, flap effort).
## BotPoseSource turns those into ARM motion, so the bot exercises the whole
## input chain; NPCs could drive WingState.set_commands() with it directly.
##
## Control laws:
##   lateral   L1 guidance: target point L1 = max(2.5 spans, 1.3 V_c) ahead on
##             the path, a_lat = 2 V^2 / L1 sin(eta), roll = atan(a_lat/g)/phi_max
##   speed     on pitch: pitch = pitch_trim(V_tgt) + 2 (V - V_tgt)/V_tgt + I_v
##   altitude  on flap effort: feed-forward from the envelope (0.35 of the
##             reference stroke holds level, 1.0 climbs at climb_at_cruise)
##             plus PI on vz, vz_cmd = clamp(dh / (0.6 T_ph), -2, climb)
##   path      glides use a path-angle loop through the inverted pitch map
##             (pitch_for_load): gamma_dot = omega (gamma_cmd - gamma), the
##             same bandwidth at every speed; omega and the line time
##             constant are slower for big birds (their wrists act later)
##   gap       climb to a glideslope through the gap centre, stop flapping a
##             beat early, then glide it (no wingbeat ripple at the gap)
##   landing   descend and slow on a glide path; excess energy is flown off
##             in 360 deg descending orbits; the final line to the grip
##             point is flown with an air brake (extra angle of attack above
##             the capture speed), grip held, and the perch assist steering
##             and braking the last spans.

enum Phase { CRUISE, GAP_PREP, FINAL_GLIDE, APPROACH, FLARE, DONE, ORBIT }
const PHASE_NAMES := ["cruise", "gap_prep", "final_glide", "descent", "final", "done", "orbit"]

var params: FlightParams
var course: FlightCourse
var phase: Phase = Phase.CRUISE

# ---- outputs ----
var pitch := 0.0
var roll := 0.0
var spread := 1.0
var effort := 0.0        ## 0..1 flap effort for the next stroke
var flapping := false
var grip := false
var h_target := 0.0
var v_target := 0.0
var progress := 0.0      ## metres along the path

# ---- gains (re-picked by the gain-sweep dev test when tuning moves) ----
var k_v := 2.0
var k_iv := 0.3
var k_h := 0.25
var k_ih := 0.05
var final_glide_s := 5.0
## Seconds of gliding before the final glide (no stroke may carry into it).
var flap_stop_lead := 1.0
## Seconds of flapping flight toward the final glide's entry height.
var gap_prep_s := 3.0
## Final-glide line tracking: time constant of the line error (s) and the
## integral gain (1/s^2).
var line_tau := 0.9
var k_ie := 0.3
## Path-angle loop bandwidth (rad/s), through the inverted pitch map.
var omega_gamma := 3.5
## Integral gain of the path-angle loop (pitch per rad s).
var k_ig := 0.8
var _ig := 0.0
## L1 distance = max(2.5 spans, k_l1 * V_c) (spec 0.9; the human delay and
## a big bird's slow roll make 0.9 weave, see the gain sweep in FLIGHT.md).
var k_l1 := 1.3
## Cruise speed as a fraction of V_c (level flapping is cheapest below V_c).
var k_vc := 1.0
## Velocity smoothing time constant, s (the pilot's perceived path).
var tau_path := 0.35
## Glide ratio assumed for the energy the rest of the approach can shed.
var approach_ld := 0.0
var orbits := 0
var _orbit_turn := 0.0
var _orbit_prev_heading := 0.0

var _iv := 0.0
var _ih := 0.0
var _vel_lp := Vector3.ZERO
var _line_y0 := 0.0
var _line_len := 0.0
var _v_lp := 0.0
var _lp_init := false
var _gap_passed := false
var _s_gap := -1.0
var _ie_y := 0.0
var _climb_cruise := 1.0
var _g_slope := -0.15
var _v_slope := 8.0


func _init(p_params: FlightParams = null, p_course: FlightCourse = null) -> void:
	params = p_params
	course = p_course
	if params != null:
		set_params(params)


func set_params(p: FlightParams) -> void:
	params = p
	_plan_glideslope()
	var env := FlightModel.envelope(p.mass)
	_climb_cruise = maxf(float(env["climb_at_cruise"]), 0.3)
	# Big birds answer the wrist more slowly (alpha lag, slow arms): the
	# path loops are slower for them (gain sweep in FLIGHT.md).
	var x0 := FlightParams.size_x_for_species(&"sparrow")
	var xn := clampf((p.x - x0) / (1.0 - x0), 0.0, 1.0)
	omega_gamma = lerpf(3.5, 2.0, xn)
	line_tau = lerpf(0.9, 1.5, xn)


## The gap glideslope. The final glide lasts T = final_glide_s +
## flap_stop_lead at about V_c, over d = V_c T. Gliding d costs d / LD of
## energy height; the entry is just high enough that the bird arrives having
## lost at most a quarter of its speed: h = d / LD - 0.44 V_c^2 / 2g (>= 0.5 m).
## Big birds (LD 15) glide in almost level, small birds (LD 6) from a few
## metres up - both within what they can climb on the way.
func _plan_glideslope() -> void:
	var p := params
	var tr0 := FlightModel.new(p.mass).trim_solution(0.0)
	var ld := -1.0 / tan(minf(float(tr0["gamma"]), -0.01))
	var d := p.v_c * (final_glide_s + flap_stop_lead)
	var h := maxf(d / ld - 0.44 * p.v_c * p.v_c / (2.0 * FlightMath.G), 0.5)
	_g_slope = -atan(h / d)
	_v_slope = sqrt(maxf(p.v_c * p.v_c + 2.0 * FlightMath.G * (h - d / ld), 0.25 * p.v_c * p.v_c))


## Pitch command that trims level 1-g flight at speed v (inverts §7.4).
func pitch_trim(v: float) -> float:
	var p := params
	var cl := 2.0 * p.mass * FlightMath.G / (FlightMath.RHO * v * v * p.s)
	var a := cl / p.a
	var top := p.alpha_s - deg_to_rad(1.0)
	if a >= p.alpha_n:
		return clampf((a - p.alpha_n) / (top - p.alpha_n), 0.0, 1.0)
	return clampf(a / p.alpha_n - 1.0, -1.0, 0.0)


## Pitch command for load factor n at airspeed v (the §7.4 map inverted:
## CL = n * 2 m g / (rho v^2 S)). With it the path-angle loop has the same
## bandwidth at every size and speed: gamma_dot = g (n - cos gamma) / V.
func pitch_for_load(v: float, n: float) -> float:
	var p := params
	var cl := n * 2.0 * p.mass * FlightMath.G / (FlightMath.RHO * maxf(v * v, 0.01) * p.s)
	var a := cl / p.a
	var top := p.alpha_s - deg_to_rad(1.0)
	if a >= p.alpha_n:
		return clampf((a - p.alpha_n) / (top - p.alpha_n), 0.0, 1.0)
	return clampf(a / p.alpha_n - 1.0, -1.0, 0.0)


## Path-angle loop: the pitch that turns the path toward g_cmd at rate
## omega_gamma * error, plus an integral that learns the map's bias (the
## model's damper, lags and the real lift slope differ from the inverse).
func pitch_for_gamma_rate(v: float, g_now: float, g_cmd: float, dt: float, omega := -1.0) -> float:
	var err := g_cmd - g_now
	var w := omega_gamma if omega <= 0.0 else omega
	var n := cos(g_now) + v / FlightMath.G * w * err
	var u := pitch_for_load(v, clampf(n, -0.5, 2.5)) + _ig
	# Anti-windup: learn the bias only while tracking (small error, output
	# not saturated); a transient must not bank a lasting pitch offset.
	if absf(err) < 0.07 and u > -0.95 and u < 0.8:
		_ig = clampf(_ig + k_ig * err * dt, -0.3, 0.3)
	return u


func update(pos: Vector3, vel_raw: Vector3, airspeed: float, dt: float) -> void:
	var p := params
	var c := course
	# A pilot flies the average path, not the wingbeat: the +-2 m/s vertical
	# ripple of each stroke would otherwise drive the altitude loop into
	# resonance with the strokes.
	var kf := 1.0 - exp(-dt / tau_path)
	if not _lp_init:
		_vel_lp = vel_raw
		_v_lp = airspeed
		_lp_init = true
	_vel_lp += (vel_raw - _vel_lp) * kf
	_v_lp += (airspeed - _v_lp) * kf
	var vel := _vel_lp
	var v := maxf(_v_lp, 0.1)
	# --- lateral: L1 guidance along the course polyline
	var l1 := maxf(2.5 * p.span, k_l1 * p.v_c)
	var near := _closest_on_path(pos)
	progress = near[1]
	var target := _point_at(progress + l1)
	# Lateral guidance on the raw horizontal velocity (little wingbeat ripple).
	var vh := Vector3(vel_raw.x, 0.0, vel_raw.z)
	var to := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	var roll_cmd := 0.0
	if vh.length() > 0.3 and to.length() > 1e-3:
		var sin_eta := -(vh.normalized().cross(to.normalized())).y
		var cos_eta := vh.normalized().dot(to.normalized())
		var eta := atan2(sin_eta, cos_eta)
		var a_lat := 2.0 * v * v / l1 * sin(clampf(eta, -PI / 2, PI / 2))
		roll_cmd = atan(a_lat / FlightMath.G) / p.phi_max
	roll = clampf(roll_cmd, -1.0, 1.0)
	# --- phase logic (vertical and speed)
	var gap := c.window_center
	# Distance to the gap ALONG THE PATH: the final glide may begin in the
	# turn onto the return leg (on a small bird's course the straight part
	# before the window is shorter than the glide).
	if _s_gap < 0.0:
		_s_gap = float(_closest_on_path(gap)[1])
	var along_gap := _s_gap - progress if not _gap_passed else INF
	if pos.x > 0.5 * c.offset:
		along_gap = minf(along_gap, gap.z - pos.z) if gap.z - pos.z > -c.wall_thick else INF
	var to_perch := c.perch_grip.z - pos.z
	var perch_pt := c.perch_grip + Vector3.UP * p.r_body
	var d_perch := Vector2(perch_pt.x - pos.x, perch_pt.z - pos.z).length()
	var v_land := 0.95 * 1.12 * p.v_min
	var d_final := 12.0 * p.span + 1.5 * p.v_c
	var heading := FlightMath.yaw_of(vh) if vh.length() > 0.3 else 0.0
	if not _gap_passed and pos.x > 0.5 * c.offset and pos.z > gap.z + c.wall_thick:
		_gap_passed = true
	# Energy the bird has vs what it needs at the perch plus what gliding the
	# remaining distance sheds.
	var ld := approach_ld if approach_ld > 0.0 else 0.8 * p.ld
	var e_now := pos.y + v * v / (2.0 * FlightMath.G)
	var e_need := perch_pt.y + v_land * v_land / (2.0 * FlightMath.G) + maxf(d_perch - 2.0 * p.span, 0.0) / ld
	var excess := e_now - e_need
	match phase:
		Phase.CRUISE:
			# Time to climb to the glideslope entry height, plus settling.
			var dh_entry := gap.y + p.v_c * (final_glide_s + flap_stop_lead) * tan(-_g_slope) - pos.y
			var t_prep := gap_prep_s + maxf(dh_entry, 0.0) / _climb_cruise
			if not _gap_passed and along_gap > 0.0 and along_gap < v * (final_glide_s + flap_stop_lead + t_prep):
				phase = Phase.GAP_PREP
		Phase.GAP_PREP:
			# The glide's energy plan assumes it starts straight at V_c. Every
			# size starts it in the turn onto the return leg (27-40 deg of
			# bank at the entry); a big bird's steep, slow turn sheds a
			# quarter of its speed there that the glide never gets back (the
			# eagle crossed the window at 1.07 V_min on 2 seeds of 6, fix
			# round 4). While still banked beyond ~30 deg (roll 0.45) the
			# powered prep goes on, for at most 30 % of the glide.
			var d_glide := p.v_c * (final_glide_s + flap_stop_lead)
			if along_gap < d_glide and (absf(roll) < 0.45 or along_gap < 0.7 * d_glide):
				phase = Phase.FINAL_GLIDE
				_ie_y = 0.0
				_ig = 0.0
		Phase.FINAL_GLIDE:
			if _gap_passed:
				phase = Phase.APPROACH
		Phase.APPROACH:
			# An orbit reaches one radius back and one forward of where it
			# starts: only well past the wall, and finishing before the final.
			var v_orb := 1.3 * p.v_min
			var r_orb := v_orb * v_orb / (FlightMath.G * tan(0.6 * p.phi_max))
			var room := pos.z > gap.z + c.wall_thick + 1.1 * r_orb + p.span and to_perch > d_final + 1.2 * r_orb
			if excess > 3.0 * p.span and room and orbits < 3:
				phase = Phase.ORBIT
				_orbit_turn = 0.0
				_orbit_prev_heading = heading
				orbits += 1
			elif to_perch < d_final:
				phase = Phase.FLARE
				_line_y0 = pos.y
				_line_len = maxf(d_perch, 1.0)
				_ig = 0.0

		Phase.ORBIT:
			_orbit_turn += absf(FlightMath.wrap_angle(heading - _orbit_prev_heading))
			_orbit_prev_heading = heading
			if _orbit_turn >= TAU - 0.35:
				phase = Phase.APPROACH
		Phase.FLARE:
			pass
	flapping = true
	grip = false
	spread = 1.0
	v_target = k_vc * p.v_c
	h_target = FlightCourse.CRUISE_ALT
	match phase:
		Phase.CRUISE:
			pass
		Phase.GAP_PREP:
			# Flap to the gap glideslope's height at the final-glide entry.
			h_target = gap.y + p.v_c * (final_glide_s + flap_stop_lead) * tan(-_g_slope)
		Phase.FINAL_GLIDE:
			# Track a fixed glideslope through the gap centre (like an ILS):
			# y = gap.y + along * tan(-g_slope). Feed-forward: the pitch whose
			# steady glide has the commanded path angle (the bird's polar);
			# feedback: path-angle error (P) and height error (P + I). Aiming
			# at the gap every tick (pure pursuit) has a gain ~ 1 / distance
			# and goes unstable in the last metres; a plain P loop on gamma
			# leaves a steady error (a steeper glide needs a faster trim).
			# No flapping: the wingbeat ripple would dominate the crossing.
			flapping = false
			var y_line := gap.y + maxf(along_gap, 0.0) * tan(-_g_slope)
			var e_y := pos.y - y_line
			# Integral only near the slope (a large entry error would wind
			# it up and overshoot).
			if absf(e_y) < 0.5 * p.span:
				_ie_y = clampf(_ie_y + e_y * dt, -0.5 * p.span, 0.5 * p.span)
			# The correction is limited to +-6 deg around the slope: a big
			# entry error is flown out gently, not by a zoom or a dive.
			var g_cmd := _g_slope + clampf(-(e_y / line_tau + k_ie * _ie_y) / maxf(v, 1.0), -0.105, 0.105)
			var g_now := atan2(vel.y, maxf(Vector2(vel.x, vel.z).length(), 0.1))
			pitch = clampf(pitch_for_gamma_rate(v, g_now, g_cmd, dt), -1.0, 0.85)
			effort = 0.0
			return
		Phase.APPROACH:
			# Straight glide path to the final point, just above the perch;
			# slowing to 1.3 V_min on the way.
			var h_fin := perch_pt.y + 0.5 * p.span
			var start_z := gap.z + c.wall_thick
			var k := clampf((pos.z - start_z) / maxf(c.perch_grip.z - d_final - start_z, 1.0), 0.0, 1.0)
			h_target = lerpf(gap.y, h_fin, k)
			v_target = lerpf(minf(p.v_c, _v_slope), 1.3 * p.v_min, k)
		Phase.ORBIT:
			# A steady descending turn: lose the excess energy, no flapping.
			roll = 0.6
			flapping = false
			effort = 0.0
			v_target = 1.3 * p.v_min
			var ev_o := (v - v_target) / v_target
			pitch = clampf(pitch_trim(v_target) + k_v * ev_o, -1.0, 0.85)
			return
		Phase.FLARE:
			# Final approach along the fixed line from the entry point to the
			# grip point, slowing toward the capture speed; grip held (the
			# 1.4 x V_cap capture). In the last 3 spans a steady flare: the
			# perch assist does the fine steering.
			grip = true
			var s_along := clampf(1.0 - d_perch / maxf(_line_len, 1.0), 0.0, 1.0)
			var y_line := lerpf(_line_y0, perch_pt.y, s_along)
			var g_line := atan2(perch_pt.y - _line_y0, _line_len)
			var e_y := pos.y - y_line
			var g_now2 := atan2(vel.y, maxf(Vector2(vel.x, vel.z).length(), 0.1))
			if d_perch < 1.5 * p.span:
				# The last span and a half: a steady flare; the perch assist
				# steers and brakes onto the grip point.
				pitch = 0.75
			else:
				# The same path-angle loop as the final glide, along the line
				# to the grip point (+-8 deg of correction).
				var g_cmd2 := g_line + clampf(-e_y / (line_tau * maxf(v, 1.0)), -0.14, 0.14)
				# Air brake: above the capture speed the wings are held at a
				# higher angle of attack than the path needs (induced drag
				# bleeds the energy a short final cannot glide away; the
				# bird balloons a little above the line and settles back).
				var v_goal := lerpf(v_land, 1.3 * p.v_min, clampf(d_perch / maxf(_line_len, 1.0), 0.0, 1.0))
				var brake := 0.5 * maxf(v - v_goal, 0.0) / v_goal
				pitch = clampf(pitch_for_gamma_rate(v, g_now2, g_cmd2, dt) + brake, -1.0, 0.85)
			# Flap only when well below the line and not yet close.
			effort = clampf(0.4 * (-e_y - p.span) / maxf(p.span, 0.1), 0.0, 1.0) if d_perch > 4.0 * p.span else 0.0
			flapping = effort > 0.15
			return
		Phase.DONE:
			flapping = false
			pitch = 0.0
			roll = 0.0
			effort = 0.0
			return
	var dh := h_target - pos.y
	# --- speed on pitch (PI around the level-flight trim of the target)
	var ev := (v - v_target) / v_target
	_iv = clampf(_iv + k_iv * ev * dt, -0.3, 0.3)
	# <= 0.85: holding 0.9 for 0.35 s is the deliberate-stall gesture.
	pitch = clampf(pitch_trim(v_target) + k_v * ev + _iv, -1.0, 0.85)
	# --- altitude on flap effort: feed-forward from the envelope (level
	# flight costs ~0.35 of the reference stroke, the full stroke climbs at
	# climb_at_cruise) plus PI on the vertical speed error.
	var vz_cmd := clampf(dh / (0.6 * p.t_ph), -2.0, _climb_cruise)
	var e := vz_cmd - vel.y
	_ih = clampf(_ih + k_ih * e * dt, -0.4, 0.6)
	effort = clampf(0.35 + 0.65 * maxf(vz_cmd, 0.0) / _climb_cruise + k_h * e + _ih, 0.0, 1.0)
	if phase == Phase.APPROACH and dh < 0.5 * p.span:
		effort = 0.0


func mark_done() -> void:
	phase = Phase.DONE


func phase_name() -> String:
	return PHASE_NAMES[phase]


## -> [closest point, distance along the path]
## The path's segments in the ground plane, computed once per path (fix
## round 6: the per-tick search recomputed them, ~30 us a bot tick).
var _seg_key := ""
var _seg_a := PackedVector2Array()
var _seg_ab := PackedVector2Array()
var _seg_l2 := PackedFloat64Array()
var _seg_len := PackedFloat64Array()


func _segments() -> void:
	var path := course.path
	var key := "%d %s %s %f" % [path.size(), path[0] if path.size() > 0 else Vector3.ZERO,
		path[path.size() - 1] if path.size() > 0 else Vector3.ZERO, course.total_len]
	if key == _seg_key:
		return
	_seg_key = key
	_seg_a.clear()
	_seg_ab.clear()
	_seg_l2.clear()
	_seg_len.clear()
	for i in range(1, path.size()):
		var a := Vector2(path[i - 1].x, path[i - 1].z)
		var ab := Vector2(path[i].x, path[i].z) - a
		_seg_a.append(a)
		_seg_ab.append(ab)
		_seg_l2.append(maxf(ab.length_squared(), 1e-9))
		_seg_len.append(ab.length())


## The closest point of the path to pos in the ground plane and its
## distance along the path (the same arithmetic per segment as before the
## cache: identical results).
func _closest_on_path(pos: Vector3) -> Array:
	_segments()
	var best := INF
	var best_s := 0.0
	var best_p := Vector3.ZERO
	var s := 0.0
	var p2 := Vector2(pos.x, pos.z)
	for i in _seg_a.size():
		var a := _seg_a[i]
		var ab := _seg_ab[i]
		var t := clampf((p2 - a).dot(ab) / _seg_l2[i], 0.0, 1.0)
		var q := a + ab * t
		var d := p2.distance_to(q)
		if d < best:
			best = d
			best_s = s + _seg_len[i] * t
			best_p = Vector3(q.x, pos.y, q.y)
		s += _seg_len[i]
	return [best_p, best_s]


func _point_at(s_target: float) -> Vector3:
	var s := 0.0
	var path := course.path
	for i in range(1, path.size()):
		var a := path[i - 1]
		var b := path[i]
		var seg := Vector2(b.x - a.x, b.z - a.z).length()
		if s + seg >= s_target:
			var t := (s_target - s) / maxf(seg, 1e-9)
			return a.lerp(b, t)
		s += seg
	var last := path[path.size() - 1]
	var prev := path[path.size() - 2]
	var dir := (last - prev).normalized()
	return last + dir * (s_target - s)
