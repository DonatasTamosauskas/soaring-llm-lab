extends TestCase
## Verifier probe (flight, ENGINEERING & CONTRACT lens, this round).
## Independent of the area's own comfort monitor (which reads PlayerBird's
## own rig_yaw_rate / rig_yaw_accel bookkeeping): here every rig quantity is
## measured from the NODES (PlayerBird / XROrigin3D global transforms) with
## the dt that was actually ticked.
##  1. ViewTurn with the tick length changing every tick (72/90/120 Hz, and
##     random 4-100 ms): caps, conservation, convergence.
##  2. Random play (every gesture kind, tracking loss, head turns, growth,
##     respawn, recenter) in a closed box with rods, perches and a thermal,
##     with the refresh rate switching and frame hitches: rig pure yaw with
##     unit scale up the whole ancestor chain, yaw rate / accel from the
##     nodes inside 240 deg/s / 720 deg/s^2, camera on the body, no NaN, no
##     rig spin while perched / grounded, Events arguments in range.
##  3. Determinism: the same flight twice (and after an unrelated flight)
##     gives bit-identical trajectories.
##  4. Telemetry contract (ARCHITECTURE section 6): keys, types, units.
##  5. Frame hitches while the arms move slowly: WingInput clamps dt to
##     1/30 s while the hands moved for the whole hitch.
## Output: artifacts/flight/verify/r5eng/probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const DEG := PI / 180.0

var fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r5eng/probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


static func _yaw_of_basis(b: Basis) -> float:
	var z := b.z
	return atan2(z.x, z.z)


# --------------------------------------------------------------------------
# 1. ViewTurn under a tick length that changes every tick
func test_r5_viewturn_variable_dt() -> void:
	for mode in 2:
		_vt_variable(mode)


## mode 0: refresh-rate switches only (72 / 90 / 120 Hz, each tick);
## mode 1: also random 4-100 ms ticks (hitches through tick(dt)).
func _vt_variable(mode: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5151
	var worst := {"rate": 0.0, "acc": 0.0, "cons": 0.0, "t_conv": 0.0, "over": 0.0, "over_case": ""}
	var fails := 0
	var first := ""
	for s in 3000:
		var vt := ViewTurn.new()
		var owed := 0.0
		var paid := 0.0
		var rate_prev := 0.0
		var n_ev := rng.randi_range(1, 5)
		var ev_t: Array[float] = []
		var tt := 0.0
		for i in n_ev:
			tt += rng.randf_range(0.0, 0.5)
			ev_t.append(tt)
		var ei := 0
		var t := 0.0
		var t_last := ev_t[ev_t.size() - 1]
		var converged := -1.0
		var ok := true
		var e0 := 0.0
		var x_since := 0.0
		var armed := false
		var over := 0.0
		while t < t_last + 12.0:
			while ei < ev_t.size() and ev_t[ei] <= t:
				var k := rng.randf()
				var mag := rng.randf_range(0.5, 40.0) if k < 0.5 else rng.randf_range(40.0, 180.0)
				var d := mag * DEG * (1.0 if rng.randf() < 0.5 else -1.0)
				vt.owe(d)
				owed += d
				ei += 1
			var dt := 0.0
			var r := rng.randf()
			if r < 0.3:
				dt = 1.0 / 72.0
			elif r < 0.6:
				dt = 1.0 / 90.0
			elif r < 0.9 or mode == 0:
				dt = 1.0 / 120.0
			else:
				dt = rng.randf_range(0.004, 0.1)
			if ei >= ev_t.size() and not armed and vt.rate == 0.0:
				armed = true
				e0 = vt.debt
				x_since = 0.0
			var x := vt.step(dt)
			paid += x
			t += dt
			var rn := x / dt
			if absf(rn) > vt.max_rate * (1.0 + 1e-9) + 1e-12:
				ok = false
			var a := absf(rn - rate_prev) / dt
			if a > vt.max_acc * (1.0 + 1e-6) + 1e-9:
				ok = false
			worst["rate"] = maxf(worst["rate"], absf(rn))
			worst["acc"] = maxf(worst["acc"], a)
			rate_prev = rn
			worst["cons"] = maxf(worst["cons"], absf(wrapf(owed - paid - vt.debt, -PI, PI)))
			if armed:
				x_since += x
				if e0 != 0.0:
					over = maxf(over, x_since * signf(e0) - absf(e0))
			if ei >= ev_t.size() and not vt.active():
				converged = t - t_last
				break
		if over > worst["over"]:
			worst["over"] = over
			worst["over_case"] = "seq %d e0 %.2f deg" % [s, rad_to_deg(e0)]
		if converged < 0.0:
			ok = false
		else:
			worst["t_conv"] = maxf(worst["t_conv"], converged)
		if not ok:
			fails += 1
			if first.is_empty():
				first = "seq %d (debt %.3f deg rate %.3f deg/s)" % [s, rad_to_deg(vt.debt), rad_to_deg(vt.rate)]
	_log("[viewturn variable dt, mode %d] 3000 sequences, %d failing (%s); peak rate %.4f deg/s, peak accel %.4f deg/s^2, conservation %.12f rad, worst convergence %.2f s after the last owe, overshoot from rest %.6f deg (%s)" % [
		mode, fails, first, rad_to_deg(worst["rate"]), rad_to_deg(worst["acc"]), worst["cons"], worst["t_conv"], rad_to_deg(worst["over"]), worst["over_case"]])
	eq(fails, 0, "ViewTurn with a varying tick length (mode %d): caps every tick, converges" % mode)
	lt(worst["cons"], 1e-4, "ViewTurn with a varying tick length (mode %d): nothing lost (rad)" % mode)
	lt(rad_to_deg(worst["over"]), 1e-4, "ViewTurn with a varying tick length (mode %d): no overshoot from rest (deg)" % mode)


# --------------------------------------------------------------------------
# 2. Random play with node-measured comfort
func _box_world(w: World) -> void:
	var tw: Variant = w
	# A closed 70 m box, 45 m high, with rods (wires), perches and a thermal.
	tw.add_wall(Vector3(0, 22.5, -35), Vector3(70, 45, 1))
	tw.add_wall(Vector3(0, 22.5, 35), Vector3(70, 45, 1))
	tw.add_wall(Vector3(-35, 22.5, 0), Vector3(1, 45, 70))
	tw.add_wall(Vector3(35, 22.5, 0), Vector3(1, 45, 70))
	tw.add_wall(Vector3(0, 45.5, 0), Vector3(70, 1, 70))
	tw.add_wall(Vector3(10, 8, 10), Vector3(6, 16, 6))
	tw.add_rod(Vector3(-30, 12, -5), Vector3(30, 12, -5), 0.01)
	tw.add_rod(Vector3(-30, 20, 12), Vector3(30, 20, 12), 0.01)
	tw.add_rod(Vector3(-5, 0, -20), Vector3(-5, 30, -20), 0.02)
	for i in 6:
		tw.add_perch(Vector3(-20 + 8 * i, 6 + 3 * (i % 3), -12 + 5 * (i % 2)), Vector3.FORWARD, 10.0)
	tw.set("thermal_center", Vector3(-15, 0, 15))
	tw.set("thermal_core", 3.5)
	tw.set("thermal_radius", 10.0)


func _gesture(b: HumanPoseModel, kind: int, t: float, g: Dictionary) -> void:
	b.set_airplane()
	b.left_valid = true
	b.right_valid = true
	for i in 2:
		b.hand_offset[i] = Vector3.ZERO
	match kind:
		0:  # glide with a symmetric twist
			for a in b.arms:
				a.twist = g["twist"]
		1:  # both arms flap
			ScriptedPoseSource.flap(b, t, g["amp"], g["hz"])
		2:  # one arm flaps
			ScriptedPoseSource.flap(b, t, g["amp"], g["hz"], g["side"])
		3:  # uneven strokes
			b.arms[0].dihedral = ScriptedPoseSource.stroke(t, deg_to_rad(g["amp"]), g["hz"])
			b.arms[1].dihedral = ScriptedPoseSource.stroke(t + g["lag"], deg_to_rad(g["amp"] * g["ratio"]), g["hz"])
		4:  # opposite twists (aileron roll) and a dihedral
			b.arms[0].twist = g["twist"]
			b.arms[1].twist = -g["twist"]
			b.arms[0].dihedral = g["dih"]
		5:  # tuck / arms to the sides
			for a in b.arms:
				a.dihedral = -1.3
				a.elbow = 0.4
		6:  # look round and turn the torso
			b.head_yaw = g["head"] * sin(1.3 * t)
			b.torso_yaw = g["torso"]
		7:  # shake the hands
			for i in 2:
				b.hand_offset[i] = Vector3(0, 0.05 * sin(TAU * 8.0 * t + i), 0)
		8:  # tracking loss of one hand, then both
			b.left_valid = false
			if g["both"]:
				b.right_valid = false
		9:  # fold hands to the chest (rest)
			for a in b.arms:
				a.elbow = 1.4
				a.fold = 0.8
				a.dihedral = -0.4


func _random_play(sp: StringName, seed_v: int, seconds: float) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp, _box_world, seed_v)
	var p := fx.player
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v * 7919 + 13
	p.start_flying(Vector3(0, 25, 0), rng.randf_range(-PI, PI), 0.0)
	var clock := {"t": 0.0, "kind": 0, "until": 0.0, "g": {}}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		_gesture(b, int(clock["kind"]), float(clock["t"]), clock["g"])
		b.humanize(float(clock["dt"]) if clock.has("dt") else 1.0 / 72.0)
	var st := {"ticks": 0, "basis_bad": 0, "scale_bad": 0, "anc_scale_bad": 0, "origin_local_bad": 0,
		"rate": 0.0, "acc": 0.0, "rate_at": "", "acc_at": "", "cam_err": 0.0, "nan": 0, "rest_spin_s": 0.0,
		"flap_strength_max": 0.0, "flap_side_bad": 0, "collided_bad": 0, "modes": {}, "stuns": 0, "perches": 0,
		"respawns": 0, "grows": 0, "hitches": 0, "safety_net": 0, "flagged": 0, "internal_vs_node": 0.0}
	var sig := {"flaps": []}
	var on_flap := func(side: int, strength: float) -> void:
		sig["flaps"].append([side, strength])
	var on_col := func(imp: float, n: Vector3) -> void:
		if not is_finite(imp) or imp < 0.0 or not n.is_finite() or absf(n.length() - 1.0) > 1e-3:
			st["collided_bad"] += 1
	Events.player_flapped.connect(on_flap)
	Events.player_collided.connect(on_col)
	var hz := 1.0 / 72.0
	var hz_until := 0.0
	var yaw_prev := NAN
	var rate_prev := NAN
	var skip := 0
	var rest_t := 0.0
	var t := 0.0
	var next_event := rng.randf_range(4.0, 8.0)
	var mass0 := p.mass
	var snap_pending := false
	while t < seconds:
		if t >= float(clock["until"]):
			clock["kind"] = rng.randi_range(0, 9)
			clock["until"] = t + rng.randf_range(0.4, 2.5)
			clock["g"] = {"twist": rng.randf_range(-0.6, 0.6), "amp": rng.randf_range(25.0, 60.0),
				"hz": rng.randf_range(0.8, 2.6), "side": -1 if rng.randf() < 0.5 else 1, "lag": rng.randf_range(0.0, 0.08),
				"ratio": rng.randf_range(0.5, 1.0), "dih": rng.randf_range(-0.5, 0.5), "head": rng.randf_range(0.3, 1.3),
				"torso": rng.randf_range(-0.6, 0.6), "both": rng.randf() < 0.3}
		if t >= hz_until:
			var r := rng.randf()
			hz = 1.0 / 72.0 if r < 0.4 else (1.0 / 90.0 if r < 0.7 else 1.0 / 120.0)
			hz_until = t + rng.randf_range(1.0, 4.0)
		var dt := hz
		if rng.randf() < 0.004:
			dt = rng.randf_range(0.04, 0.3)
			st["hitches"] += 1
		clock["dt"] = dt
		if t >= next_event:
			next_event = t + rng.randf_range(4.0, 8.0)
			var e := rng.randi_range(0, 2)
			if e == 0:
				# growth mid-flight (GameLoop changes mass at any time)
				p.mass = p.mass * rng.randf_range(1.05, 1.6) if p.mass < 2.0 else mass0
				p._on_mass_changed()
				st["grows"] += 1
			elif e == 1:
				p.respawn(Transform3D(Basis(Vector3.UP, rng.randf_range(-PI, PI)), Vector3(rng.randf_range(-20, 20), 25, rng.randf_range(-20, 20))))
				st["respawns"] += 1
				snap_pending = true
			else:
				Events.recenter_requested.emit()
		var lim0 := p.rig_limited_ticks
		var pre := {"ff": p._ff_rate, "vt": p.view_turn.rate, "rig": p.rig_yaw_rate, "mode": p.mode_name(), "dt_prev": clock.get("dt_prev", 0.0)}
		p.tick(dt)
		t += minf(dt, 0.1)
		clock["t"] = float(clock["t"]) + minf(dt, 0.1)
		st["ticks"] += 1
		if p.rig_limited_ticks > lim0:
			st["safety_net"] += 1
			if st["safety_net"] <= 3:
				_log("[safety net] %s seed %d t %.2f: mode %s -> %s, dt %.4f (prev %.4f), before: ff %.1f vt %.1f rig %.1f deg/s; after: ff %.1f vt %.1f rig %.1f deg/s, accel %.1f, owed %.2f deg" % [
					sp, seed_v - 100, t, pre["mode"], p.mode_name(), dt, pre["dt_prev"], rad_to_deg(pre["ff"]), rad_to_deg(pre["vt"]), rad_to_deg(pre["rig"]),
					rad_to_deg(p._ff_rate), rad_to_deg(p.view_turn.rate), rad_to_deg(p.rig_yaw_rate), rad_to_deg(p.rig_yaw_accel), rad_to_deg(p.view_turn.debt)])
		clock["dt_prev"] = dt
		var mn := p.mode_name()
		st["modes"][mn] = int(st["modes"].get(mn, 0)) + 1
		# --- node-measured rig checks
		var b := p.global_basis
		var ob := p.origin.global_basis
		for bb: Basis in [b, ob]:
			if absf(bb.y.dot(Vector3.UP) - 1.0) > 1e-6 or absf(bb.x.y) > 1e-6 or absf(bb.z.y) > 1e-6:
				st["basis_bad"] += 1
			if absf(bb.x.length() - 1.0) > 1e-5 or absf(bb.y.length() - 1.0) > 1e-5 or absf(bb.z.length() - 1.0) > 1e-5 \
					or absf(bb.determinant() - 1.0) > 1e-5:
				st["scale_bad"] += 1
		if not p.origin.transform.basis.is_equal_approx(Basis.IDENTITY):
			st["origin_local_bad"] += 1
		var n: Node = p.origin
		while n != null:
			if n is Node3D and not (n as Node3D).scale.is_equal_approx(Vector3.ONE):
				st["anc_scale_bad"] += 1
			n = n.get_parent()
		var yaw := _yaw_of_basis(ob)
		var edt := minf(dt, 0.1)
		if p.yaw_flagged or snap_pending:
			snap_pending = false
			st["flagged"] += 1
			yaw_prev = yaw
			rate_prev = NAN
			skip = 1
		else:
			if not is_nan(yaw_prev):
				var rate := wrapf(yaw - yaw_prev, -PI, PI) / edt
				st["internal_vs_node"] = maxf(st["internal_vs_node"], absf(rate - p.rig_yaw_rate))
				if absf(rate) > st["rate"]:
					st["rate"] = absf(rate)
					st["rate_at"] = "t %.2f mode %s" % [t, mn]
				if skip <= 0 and not is_nan(rate_prev):
					var acc := absf(rate - rate_prev) / edt
					if acc > st["acc"]:
						st["acc"] = acc
						st["acc_at"] = "t %.2f mode %s dt %.4f rate %.1f -> %.1f deg/s" % [t, mn, edt, rad_to_deg(rate_prev), rad_to_deg(rate)]
				rate_prev = rate
				if mn == "perched" or mn == "grounded":
					if absf(rate) > deg_to_rad(1.0):
						rest_t += edt
						st["rest_spin_s"] = maxf(st["rest_spin_s"], rest_t)
					else:
						rest_t = 0.0
				else:
					rest_t = 0.0
			skip -= 1
			yaw_prev = yaw
		if mn == "flying":
			var want := p.model.position + Vector3.UP * p.heave_offset()
			st["cam_err"] = maxf(st["cam_err"], p.camera.global_position.distance_to(want))
		var tel := p.telemetry()
		for k in tel:
			var v: Variant = tel[k]
			if (v is float and not is_finite(v)):
				if not (k == "altitude_agl"):
					st["nan"] += 1
		if not p.global_position.is_finite():
			st["nan"] += 1
	for f: Array in sig["flaps"]:
		st["flap_strength_max"] = maxf(st["flap_strength_max"], float(f[1]))
		if not (int(f[0]) in [-1, 0, 1]):
			st["flap_side_bad"] += 1
	st["flap_events"] = sig["flaps"].size()
	st["stuns"] = p.contacts["stun"]
	st["perches"] = fx.events["perched"]
	Events.player_flapped.disconnect(on_flap)
	Events.player_collided.disconnect(on_col)
	return st


func test_r5_random_play_node_measured_comfort() -> void:
	var tot := {"ticks": 0, "basis_bad": 0, "scale_bad": 0, "anc_scale_bad": 0, "origin_local_bad": 0, "nan": 0,
		"rate": 0.0, "acc": 0.0, "cam_err": 0.0, "rest_spin_s": 0.0, "flap_strength_max": 0.0, "flap_side_bad": 0,
		"collided_bad": 0, "safety_net": 0, "internal_vs_node": 0.0}
	var runs := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for s in 3:
			var st: Dictionary = await _random_play(sp, 100 + s, 40.0)
			runs += 1
			_log("[random play] %s seed %d: %d ticks, modes %s, stuns %d, perch events %d, respawns %d, growth %d, hitches %d, flagged %d; rig rate %.1f deg/s (%s), accel %.1f deg/s^2 (%s); safety net %d ticks; basis %d, scale %d, ancestors %d, origin local %d; camera err %.4f m; rest spin %.2f s; flap events %d (max strength %.3f, bad side %d); collided bad %d; NaN %d; |node rate - rig_yaw_rate| %.9f rad/s" % [
				sp, s, st["ticks"], JSON.stringify(st["modes"]), st["stuns"], st["perches"], st["respawns"], st["grows"], st["hitches"],
				st["flagged"], rad_to_deg(st["rate"]), st["rate_at"], rad_to_deg(st["acc"]), st["acc_at"], st["safety_net"],
				st["basis_bad"], st["scale_bad"], st["anc_scale_bad"], st["origin_local_bad"], st["cam_err"], st["rest_spin_s"],
				st["flap_events"], st["flap_strength_max"], st["flap_side_bad"], st["collided_bad"], st["nan"], st["internal_vs_node"]])
			for k in ["ticks", "basis_bad", "scale_bad", "anc_scale_bad", "origin_local_bad", "nan", "flap_side_bad", "collided_bad", "safety_net"]:
				tot[k] += st[k]
			for k in ["rate", "acc", "cam_err", "rest_spin_s", "flap_strength_max", "internal_vs_node"]:
				tot[k] = maxf(tot[k], st[k])
			fx.teardown()
			fx = null
			await get_tree().process_frame
	_log("[random play] TOTAL %d runs, %s" % [runs, JSON.stringify(tot)])
	eq(tot["basis_bad"], 0, "random play: the rig never pitches or rolls (node bases)")
	eq(tot["scale_bad"], 0, "random play: unit scale on PlayerBird and XROrigin3D (node bases)")
	eq(tot["anc_scale_bad"], 0, "random play: every ancestor of XROrigin3D has scale 1")
	eq(tot["origin_local_bad"], 0, "random play: XROrigin3D local basis identity")
	eq(tot["nan"], 0, "random play: telemetry and position finite")
	lt(rad_to_deg(tot["rate"]), 240.0 + 1e-3, "random play: node-measured yaw rate <= 240 deg/s")
	# Node transforms are float32: +-4e-5 rad/s of rate noise is +-0.5 deg/s^2 at 120 Hz.
	lt(rad_to_deg(tot["acc"]), 720.0 + 0.5, "random play: node-measured yaw acceleration <= 720 deg/s^2 (float32 node noise)")
	lt(tot["cam_err"], 0.001, "random play: camera = body + heave in flight (m)")
	lt(tot["rest_spin_s"], 0.36, "random play: perched or grounded, the rig is at rest within 0.35 s (s)")
	lt(tot["flap_strength_max"], 1.0 + 1e-6, "random play: player_flapped strength within the contract's 0..1")
	eq(tot["collided_bad"], 0, "random play: player_collided arguments finite, unit normal")


# --------------------------------------------------------------------------
# 3. Determinism
func _det_run(sp: StringName, seed_v: int) -> PackedFloat64Array:
	var st: Dictionary = await _random_play(sp, seed_v, 12.0)
	var out := PackedFloat64Array()
	var p := fx.player
	out.append_array([p.model.position.x, p.model.position.y, p.model.position.z, p.model.velocity.x, p.model.velocity.y,
		p.model.velocity.z, p.rig_yaw, p.model.heading(), p.model.phi, float(st["ticks"]), float(st["flap_events"])])
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r5_determinism() -> void:
	var a: PackedFloat64Array = await _det_run(&"pigeon", 7)
	var other: PackedFloat64Array = await _det_run(&"eagle", 9)
	var b: PackedFloat64Array = await _det_run(&"pigeon", 7)
	var same := a == b
	_log("[determinism] pigeon seed 7 twice (an eagle flight in between): identical %s; a %s; b %s; other %s" % [same, a, b, other])
	check(same, "the same random flight twice (after an unrelated flight) is bit-identical")
	# FlightModel alone: the same WingState sequence twice.
	var res: Array = []
	for rep in 2:
		var m := FlightModel.new(FlightParams.species_mass(&"sparrow"))
		m.trim(Vector3(0, 100, 0), 0.3, 0.0)
		var ws := WingState.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		var env := FlightEnv.new()
		for i in 3000:
			ws.set_commands(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(0, 1), rng.randf_range(0, 1),
				i / 72.0, rng.randf_range(0.8, 2.0))
			m.step(ws, env, 1.0 / 72.0)
		res.append([m.position, m.velocity, m.chi, m.phi, m.theta])
	check(str(res[0]) == str(res[1]), "FlightModel: the same inputs twice give the same state")
	_log("[determinism] FlightModel 3000 random ticks twice: %s | %s" % [res[0], res[1]])


# --------------------------------------------------------------------------
# 4. Telemetry contract
const CONTRACT_KEYS := {"airspeed": TYPE_FLOAT, "groundspeed": TYPE_FLOAT, "vertical_speed": TYPE_FLOAT,
	"altitude_agl": TYPE_FLOAT, "aoa": TYPE_FLOAT, "bank": TYPE_FLOAT, "stalled": TYPE_BOOL, "flapping": TYPE_FLOAT,
	"wing_extension": TYPE_FLOAT, "tucked": TYPE_BOOL, "perched": TYPE_BOOL, "in_updraft": TYPE_FLOAT,
	"g_load": TYPE_FLOAT, "lift": TYPE_FLOAT, "drag": TYPE_FLOAT}


func test_r5_telemetry_contract_units() -> void:
	fx = FX.new(self)
	await fx.setup(&"pigeon", func(w: World) -> void:
		w.set("thermal_center", Vector3(500, 0, 0))
		w.set("thermal_core", 3.0)
		w.set("thermal_radius", 30.0))
	var p := fx.player
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	fx.run(8.0)
	var t := p.telemetry()
	var missing := []
	var badtype := []
	for k in CONTRACT_KEYS:
		if not t.has(k):
			missing.append(k)
		elif typeof(t[k]) != CONTRACT_KEYS[k]:
			badtype.append("%s:%s" % [k, type_string(typeof(t[k]))])
	eq(missing.size(), 0, "telemetry has every ARCHITECTURE section 6 key (missing %s)" % [missing])
	eq(badtype.size(), 0, "telemetry types (float / bool) (bad %s)" % [badtype])
	var m := p.model
	var mg := m.params.mass * FlightMath.G
	# A steady glide: lift ~ m g cos(gamma), drag ~ m g sin(-gamma) (newtons), g_load ~ 1.
	var gam := float(t["gamma"])
	_log("[telemetry] pigeon glide: V %.2f, gamma %.2f deg, lift %.3f N (m g cos gamma %.3f), drag %.3f N (m g sin -gamma %.3f), g %.3f, aoa %.2f deg, in_updraft %.2f, agl %.2f (y %.2f), vs %.3f (vel.y %.3f)" % [
		t["airspeed"], rad_to_deg(gam), t["lift"], mg * cos(gam), t["drag"], mg * sin(-gam), t["g_load"], rad_to_deg(t["aoa"]), t["in_updraft"],
		t["altitude_agl"], m.position.y, t["vertical_speed"], m.velocity.y])
	near(float(t["lift"]) / (mg * cos(gam)), 1.0, 0.1, "lift is newtons: ~ m g cos(gamma) in a steady glide")
	near(float(t["drag"]) / (mg * sin(-gam)), 1.0, 0.15, "drag is newtons: ~ m g sin(-gamma) in a steady glide")
	near(float(t["g_load"]), 1.0, 0.1, "g_load ~ 1 in a steady glide")
	near(float(t["altitude_agl"]), m.position.y, 1e-3, "altitude_agl over flat ground at y 0")
	near(float(t["vertical_speed"]), m.velocity.y, 1e-6, "vertical_speed = velocity.y")
	between(float(t["aoa"]), 0.0, 0.4, "aoa in radians (a glide's few degrees)")
	# Into the thermal core: in_updraft reads its m/s.
	p.start_flying(Vector3(500, 60, 0), 0.0, 0.0)
	fx.player.tick(1.0 / 72.0)
	var tu := p.telemetry()
	near(float(tu["in_updraft"]), 3.0, 0.3, "in_updraft = m/s of rising air at the core")
	# Perched: every contract key still present.
	var pr: Perch = fx.world.call("add_perch", Vector3(0, 5, 30), Vector3.FORWARD, 10.0)
	await get_tree().physics_frame
	p.perch_on(pr)
	fx.run(0.5)
	var tp := p.telemetry()
	var miss_p := []
	for k in CONTRACT_KEYS:
		if not tp.has(k) or typeof(tp[k]) != CONTRACT_KEYS[k]:
			miss_p.append(k)
	eq(miss_p.size(), 0, "perched telemetry: every contract key with its type (bad %s)" % [miss_p])
	check(bool(tp["perched"]), "perched telemetry: perched = true")


# --------------------------------------------------------------------------
# 5. Frame hitches while the arms move slowly: no spurious flaps
func _slow_arms_run(sp: StringName, hitch: bool) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp)
	var p := fx.player
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var clk := {"t": 0.0}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		# Slow +-25 deg arm sweeps at 0.25 Hz: far below any credited stroke.
		var e := deg_to_rad(25.0) * sin(TAU * 0.25 * float(clk["t"]))
		b.arms[0].dihedral = e
		b.arms[1].dihedral = e
	var flaps := [0]
	var cb := func(_s: int, _st: float) -> void:
		flaps[0] += 1
	Events.player_flapped.connect(cb)
	var t := 0.0
	var i := 0
	var fmax := 0.0
	while t < 20.0:
		var dt := 1.0 / 72.0
		if hitch and i % 36 == 18:
			dt = 0.1
		p.tick(dt)
		t += dt
		clk["t"] = t
		fmax = maxf(fmax, maxf(p.wing_input.state.flap_l, p.wing_input.state.flap_r))
		i += 1
	Events.player_flapped.disconnect(cb)
	var out := {"flaps": flaps[0], "flap_max": fmax, "y": p.model.position.y}
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r5_hitches_do_not_make_slow_arms_flap() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		var a: Dictionary = await _slow_arms_run(sp, false)
		var b: Dictionary = await _slow_arms_run(sp, true)
		_log("[hitch flaps] %s slow arm sweeps 20 s: no hitches -> %d flap events (max flap %.3f); a 0.1 s hitch every 0.5 s -> %d flap events (max flap %.3f)" % [
			sp, a["flaps"], a["flap_max"], b["flaps"], b["flap_max"]])
		eq(int(b["flaps"]), int(a["flaps"]), "%s: frame hitches never turn slow arm sweeps into flaps" % sp)
		lt(float(b["flap_max"]), float(a["flap_max"]) + 0.05, "%s: hitches add no flap effort" % sp)


## The engine's own behaviour on a frame hitch: physics keeps its fixed
## delta and runs several steps in one frame, while the XR poses update once
## per frame. So the first step after a 100 ms hitch sees 100 ms of hand
## motion in 1/72 s, the next six see none. `perch`: a perched bird lowering
## raised arms slowly back to the spread (never a flap) meets one hitch.
func _engine_hitch_run(sp: StringName, hitch: bool, perched: bool, steps := 7) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp, func(w: World) -> void:
		w.call("add_perch", Vector3(0, 10, 0), Vector3.FORWARD, 10.0))
	var p := fx.player
	await get_tree().physics_frame
	if perched:
		p.perch_on(fx.world.get_perches()[0])
	else:
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var clk := {"pose_t": 0.0}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var tt := float(clk["pose_t"])
		var e := 0.0
		if perched:
			# Raise the arms to +35 deg over 1 s, hold, lower them over 1.6 s
			# (0.38 rad/s, well under a downstroke), hold level; repeat.
			var c := fmod(tt, 5.0)
			if c < 1.0:
				e = deg_to_rad(35.0) * c
			elif c < 2.0:
				e = deg_to_rad(35.0)
			elif c < 3.6:
				e = deg_to_rad(35.0) * (1.0 - (c - 2.0) / 1.6)
		else:
			e = deg_to_rad(25.0) * sin(TAU * 0.25 * tt)
		b.arms[0].dihedral = e
		b.arms[1].dihedral = e
	var flaps := [0, 0]
	var cb_f := func(_s: int, _st: float) -> void:
		flaps[0] += 1
	var cb_t := func() -> void:
		flaps[1] += 1
	Events.player_flapped.connect(cb_f)
	Events.player_took_off.connect(cb_t)
	var dt := 1.0 / 72.0
	var t := 0.0
	var hold := 0
	var i := 0
	var left_at := -1.0
	while t < 20.0:
		t += dt
		if hitch and hold == 0 and i % 36 == 5:
			hold = steps
		if hold > 0:
			# All the steps of the hitch frame read the pose at its end.
			if hold == steps:
				clk["pose_t"] = t + (steps - 1) * dt
			hold -= 1
		else:
			clk["pose_t"] = t
		p.tick(dt)
		if perched and left_at < 0.0 and p.mode != PlayerBird.Mode.PERCHED:
			left_at = t
		i += 1
	Events.player_flapped.disconnect(cb_f)
	Events.player_took_off.disconnect(cb_t)
	var out := {"flaps": flaps[0], "took_off": flaps[1], "left_at": left_at, "mode": p.mode_name()}
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r5_engine_style_hitches() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for perched in [false, true]:
			var a: Dictionary = await _engine_hitch_run(sp, false, perched)
			var b: Dictionary = await _engine_hitch_run(sp, true, perched)
			_log("[engine hitch] %s %s: no hitches -> %d flap events, %d take-offs (left the perch at %.2f s, mode %s); a 100 ms hitch every 0.5 s (fixed dt, poses frozen then jumping) -> %d flap events, %d take-offs (left at %.2f s, mode %s)" % [
				sp, "perched, arms raised and lowered slowly" if perched else "flying, slow arm sweeps", a["flaps"], a["took_off"], a["left_at"], a["mode"],
				b["flaps"], b["took_off"], b["left_at"], b["mode"]])
			eq(int(b["flaps"]), int(a["flaps"]), "%s %s: hitches never turn slow arm motion into flaps" % [sp, "perched" if perched else "flying"])
			eq(int(b["took_off"]), int(a["took_off"]), "%s %s: hitches never launch" % [sp, "perched" if perched else "flying"])


## A recenter while the view is paying a stun's turn: the rig's rate is not
## restarted (only rig_yaw snaps and the debt is dropped), so the rig keeps
## turning, braking at the 720 deg/s^2 safety net, and that extra rotation
## is owed back and paid the other way.
func test_r5_recenter_during_a_view_payout() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: World) -> void:
			w.call("add_wall", Vector3(0, 40, -30), Vector3(80, 80, 1)))
		var p := fx.player
		var v := p.model.params.v_c
		p.start_flying(Vector3(0, 40, -30 + 0.3 * v + 0.5), 0.0, 0.0)
		# Straight at the wall: a head-on stun turns the body 40 deg, owed to the view.
		var peak := 0.0
		var i := 0
		while i < 400 and not (p.view_turn.active() and absf(p.view_turn.rate) > deg_to_rad(60.0)):
			fx.step()
			i += 1
		var paying := rad_to_deg(p.view_turn.rate)
		_log("  before recenter: mode %s rig %.2f heading %.2f debt %.2f vt %.1f" % [p.mode_name(), rad_to_deg(p.rig_yaw), rad_to_deg(p.model.heading()), rad_to_deg(p.view_turn.debt), rad_to_deg(p.view_turn.rate)])
		var rig_rate0 := rad_to_deg(p.rig_yaw_rate)
		Events.recenter_requested.emit()
		var lim0 := p.rig_limited_ticks
		var yaw_after_snap := NAN
		var extra := 0.0
		var back := 0.0
		var prev := NAN
		for k in 144:
			fx.step()
			if k == 0:
				yaw_after_snap = p.rig_yaw
				prev = p.rig_yaw
				continue
			var d := wrapf(p.rig_yaw - prev, -PI, PI)
			prev = p.rig_yaw
			var head_d := wrapf(p.model.heading() - p.wing_input.state.body_yaw - yaw_after_snap, -PI, PI)
			if sp == &"sparrow" and k % 6 == 0:
				_log("  k %d mode %s rig %.2f heading %.2f body_yaw %.2f debt %.2f vt %.1f rig_rate %.1f ff %.1f" % [k, p.mode_name(), rad_to_deg(p.rig_yaw), rad_to_deg(p.model.heading()),
					rad_to_deg(p.wing_input.state.body_yaw), rad_to_deg(p.view_turn.debt), rad_to_deg(p.view_turn.rate), rad_to_deg(p.rig_yaw_rate), rad_to_deg(p._ff_rate)])
			peak = maxf(peak, absf(wrapf(p.rig_yaw - yaw_after_snap, -PI, PI) - head_d))
			if signf(d) == signf(deg_to_rad(rig_rate0)):
				extra += absf(d)
			else:
				back += absf(d)
		_log("[recenter mid-payout] %s: ViewTurn paying %.1f deg/s (rig %.1f deg/s) when recentered; afterwards the rig turned on %.2f deg the old way and %.2f deg back; safety net %d ticks; worst view-vs-heading gap after the snap %.2f deg" % [
			sp, paying, rig_rate0, rad_to_deg(extra), rad_to_deg(back), p.rig_limited_ticks - lim0, rad_to_deg(peak)])
		metric("%s_recenter_extra_deg" % sp, rad_to_deg(extra))
		check(true, "logged")
		fx.teardown()
		fx = null
		await get_tree().process_frame


## Head-on stun, arms still, no recenter: split the heading change in the
## 3 s after the hit into what the model reported as heading JUMPS (forced
## turns owed to the view: PlayerBird.forced_turn) and the flown remainder.
## FLIGHT.md: "the forced turn is 40 deg; the bird then lines up with the
## wall it slides along, a flown, player-overridable turn".
func test_r5_head_on_stun_forced_vs_flown() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for inc: float in [60.0, 90.0]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: World) -> void:
				w.set("with_ground", false)
				w.call("add_wall", Vector3(0, 100, -20), Vector3(400, 200, 1.0)))
			var p := fx.player
			var pr := p.model.params
			var yaw := (90.0 - inc) * DEG
			var start := Vector3(pr.v_c * 0.8 * cos(inc * DEG), 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
			p.start_flying(start, yaw, 0.0)
			var hit := -1
			var forced := 0.0
			var forced_n := 0
			var forced_stunned := 0.0
			var total := 0.0
			var hp := p.model.heading()
			var big: Array = []
			for k in 8 * 72:
				fx.step()
				var dh := wrapf(p.model.heading() - hp, -PI, PI)
				hp = p.model.heading()
				if hit < 0 and p.mode == PlayerBird.Mode.STUNNED:
					hit = k
				if hit >= 0 and k - hit <= 3 * 72:
					total += absf(dh)
					if absf(p.forced_turn) > 1e-6:
						forced += absf(p.forced_turn)
						forced_n += 1
						if p.mode == PlayerBird.Mode.STUNNED:
							forced_stunned += absf(p.forced_turn)
						if absf(p.forced_turn) > deg_to_rad(2.0):
							big.append("t+%.2f %.1f deg (%s, slide %d stun %d)" % [(k - hit) / 72.0, rad_to_deg(p.forced_turn), p.mode_name(), p.contacts["slide"], p.contacts["stun"]])
			_log("[head-on split] %s %d deg: heading changed %.1f deg in the 3 s after the hit; of it %.1f deg reported as jumps (%d ticks, %.1f deg while stunned), flown %.1f deg; jumps > 2 deg: %s" % [
				sp, int(inc), rad_to_deg(total), rad_to_deg(forced), forced_n, rad_to_deg(forced_stunned), rad_to_deg(total - forced), big])
			metric("%s_%d_forced_deg" % [sp, int(inc)], rad_to_deg(forced))
			check(true, "logged")
			fx.teardown()
			fx = null
			await get_tree().process_frame


## Milder, more common hitches: one or three dropped frames (2 or 4 physics
## steps in one frame at 72 Hz), every 0.5 s, flying with slow arm sweeps.
func test_r5_engine_hitch_sizes() -> void:
	for steps in [2, 3, 4, 7]:
		var a: Dictionary = await _engine_hitch_run(&"pigeon", true, false, steps)
		_log("[engine hitch size] pigeon flying, slow arm sweeps, %d physics steps per hitch frame (%.0f ms) every 0.5 s: %d flap events in 20 s" % [steps, steps * 1000.0 / 72.0, a["flaps"]])
		metric("pigeon_hitch_%d_flaps" % steps, a["flaps"])
		check(true, "logged")
