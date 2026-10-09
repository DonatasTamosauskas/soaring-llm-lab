extends TestCase
## Verifier probe (round 2, flight, experience lens): the rig and the
## situations a player actually gets into.
##  - respawn(xform) with a pitched / rolled / scaled / degenerate xform: the
##    rig must still be yaw-only with unit scale (F11);
##  - a long mixed session (6 min): comfort monitor, no drift, frame time;
##  - flying head-on into a wall with neutral arms: stun, then what? (a
##    stun-lock would be a bad experience);
##  - V_max dive into a 2 cm twig / wire at a 100 ms frame hitch (dt clamp):
##    no tunnelling (F10);
##  - perching like a player: approaches from 8 spans at 0/30/60 deg off the
##    perch axis, from below and above, flaring with the wrists (not injected
##    velocities); cruise-speed pass must not perch; an oversize bird never
##    perches; one real stroke launches (F10);
##  - body pitch while perched (the eagle shot shows pitch -8 deg).
## Output: artifacts/flight/verify/r2/rig_perch_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 30, -10)

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
	var path := Paths.artifacts("flight").path_join("verify/r2/rig_perch_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _rig_ok(p: PlayerBird) -> bool:
	var ok := true
	var n := p as Node
	while n != null and n is Node3D:
		var b := (n as Node3D).global_basis
		if absf(b.x.length() - 1.0) > 1e-5 or absf(b.y.length() - 1.0) > 1e-5 or absf(b.z.length() - 1.0) > 1e-5:
			ok = false
		n = n.get_parent()
	var ob := p.origin.global_basis
	if ob.y.dot(Vector3.UP) < 1.0 - 1e-6 or absf(ob.determinant() - 1.0) > 1e-5:
		ok = false
	return ok


func test_r2_respawn_with_tilted_xforms() -> void:
	fx = FX.new(self)
	await fx.setup(&"pigeon")
	var p := fx.player
	var bad := 0
	var xforms := {
		"pitched 60": Transform3D(Basis(Vector3.RIGHT, 60.0 * DEG), Vector3(0, 50, 0)),
		"rolled 90": Transform3D(Basis(Vector3.BACK, 90.0 * DEG) * Basis(Vector3.UP, 1.0), Vector3(5, 50, 0)),
		"looking straight down": Transform3D(Basis(Vector3.RIGHT, -90.0 * DEG), Vector3(0, 50, 5)),
		"scaled x3": Transform3D(Basis.IDENTITY.scaled(Vector3(3, 3, 3)), Vector3(0, 50, 10)),
		"degenerate": Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3(0, 50, 15)),
		"upside down": Transform3D(Basis(Vector3.BACK, PI), Vector3(0, 50, 20)),
	}
	for k in xforms:
		p.respawn(xforms[k])
		var r0 := _rig_ok(p)
		fx.run(1.5)
		var r1: bool = _rig_ok(p) and fx.comfort["basis_bad"] == 0 and fx.comfort["scale_bad"] == 0
		var fin := FlightMath.vfinite(p.global_position) and FlightMath.vfinite(p.camera.global_position)
		_log("respawn %-22s: rig level + unit scale at respawn %s, after 1.5 s %s, mode %s, finite %s" % [k, r0, r1, p.mode_name(), fin])
		if not (r0 and r1 and fin):
			bad += 1
	eq(bad, 0, "respawn with any xform keeps the rig yaw-only, unit scale, finite")
	fx.assert_comfort(self, "respawn xforms")


func test_r2_long_mixed_session() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var p := fx.player
	p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	# Segments of 3-8 s: flap climb, glide turn L/R, dive, flare, one-wing,
	# torso turn, look around; the arms are humanised.
	var segs: Array = []
	var t := 0.0
	while t < 360.0:
		var d := rng.randf_range(3.0, 8.0)
		segs.append([t, d, rng.randi() % 8, rng.randf_range(-1.0, 1.0)])
		t += d
	var cal := p.wing_input.calibration
	var st := {"i": 0, "max_tick_us": 0.0, "sum_us": 0.0, "n": 0, "alt_min": INF, "alt_max": -INF}
	fx.driver = func(_tick: int, tt: float, b: HumanPoseModel) -> void:
		while st["i"] < segs.size() - 1 and tt >= float(segs[st["i"] + 1][0]):
			st["i"] += 1
		var s: Array = segs[st["i"]]
		var lt := tt - float(s[0])
		var x: float = s[3]
		b.set_airplane()
		b.torso_yaw = 0.0
		match int(s[2]):
			0:
				ScriptedPoseSource.flap(b, lt, 40.0, 1.0)
			1:
				b.synth(0.1, x, 1.0, cal)
			2:
				b.synth(-0.8, 0.0, 0.3, cal)
			3:
				b.synth(0.9, 0.0, 1.0, cal)
			4:
				ScriptedPoseSource.flap(b, lt, 40.0, 1.0, -1 if x < 0.0 else 1)
			5:
				b.synth(0.0, 0.0, 1.0, cal)
				b.torso_yaw = 0.8 * x * sin(lt)
			6:
				b.synth(0.2, 0.0, 1.0, cal)
				b.head_yaw = 1.2 * sin(lt * 1.3)
				b.head_pitch = 0.6 * sin(lt * 0.7)
			7:
				ScriptedPoseSource.flap(b, lt, 30.0, 1.4)
				b.synth(0.0, 0.5 * x, 1.0, cal)
				ScriptedPoseSource.flap(b, lt, 30.0, 1.4)
		b.humanize(DT)
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["max_tick_us"] = maxf(st["max_tick_us"], pl.tick_us)
		st["sum_us"] += pl.tick_us
		st["n"] += 1
		st["alt_min"] = minf(st["alt_min"], pl.model.position.y)
		st["alt_max"] = maxf(st["alt_max"], pl.model.position.y)
		if pl.mode == PlayerBird.Mode.GROUNDED or pl.mode == PlayerBird.Mode.PERCHED:
			# Relaunch at altitude: this probe is about the airborne rig.
			pl.start_flying(pl.model.position + Vector3.UP * 60.0, pl.model.heading(), 0.0)
	fx.run(360.0)
	var cf: Dictionary = fx.comfort
	_log("6 min session: ticks %d, mean tick %.0f us, max %.0f us, alt %.0f..%.0f m, rig yaw rate max %.0f deg/s, accel max %.0f deg/s2, basis_bad %d, scale_bad %d, origin_bad %d, cam err %.4f m, view jerk %.2f vs body %.2f cm, limited ticks %d, contacts %s" % [
		cf["checked"], st["sum_us"] / maxf(st["n"], 1), st["max_tick_us"], st["alt_min"], st["alt_max"], rad_to_deg(cf["max_rate"]),
		rad_to_deg(cf["max_accel"]), cf["basis_bad"], cf["scale_bad"], cf["origin_bad"], cf["camera_err"], cf["cam_jerk"], cf["body_jerk"],
		p.rig_limited_ticks, str(p.contacts)])
	fx.assert_comfort(self, "6 min mixed session")
	check(p.origin.transform.basis.is_equal_approx(Basis.IDENTITY), "origin basis still identity after 6 min")
	check(FlightMath.vfinite(p.origin.position) and p.origin.position.length() < 5.0, "origin offset bounded after 6 min (%.3f m)" % p.origin.position.length())


func test_r2_wall_head_on_neutral_arms() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.add_wall(Vector3(0, 40, -40), Vector3(60, 80, 1.0)))
		var p := fx.player
		p.start_flying(Vector3(0, 40, -40 + 6.0 * p.model.params.span + 3.0), 0.0, 0.0)
		var st := {"stuns": 0, "prev": p.mode, "stun_time": 0.0, "first_stun": -1.0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var m: int = f.player.mode
			if m == PlayerBird.Mode.STUNNED:
				st["stun_time"] += DT
				if st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
					if st["first_stun"] < 0.0:
						st["first_stun"] = tick * DT
			st["prev"] = m
		fx.run(8.0)
		var d_wall: float = p.model.position.z - (-40.0 + 0.5)
		_log("%s head-on into a wall at cruise, neutral arms: first stun at %.2f s, %d stun(s), %.2f s stunned in 8 s, mode %s, %.1f m from the wall, alt %.1f, heading %.0f deg vs rig %.0f deg" % [
			sp, st["first_stun"], st["stuns"], st["stun_time"], p.mode_name(), d_wall, p.model.position.y,
			rad_to_deg(p.model.heading()), rad_to_deg(p.rig_yaw)])
		gt(st["stuns"], 0, "%s: a head-on hit stuns" % sp)
		lt(st["stuns"], 3, "%s: no stun-lock against the wall with neutral arms (8 s)" % sp)
		fx.assert_comfort(self, "%s wall" % sp)
		fx.teardown()
		fx = null


func test_r2_dive_into_twig_with_frame_hitch() -> void:
	# A tucked vertical dive at V_max onto a horizontal twig / wire, offset
	# 0.3 r_body from dead centre, at 72 Hz and with 100 ms frame hitches.
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for dt: float in [DT, 0.1]:
			for kind in ["twig", "wire"]:
				fx = FX.new(self)
				var r := 0.01 if kind == "twig" else 0.004
				await fx.setup(sp, func(w: Variant) -> void:
					w.with_ground = false
					w.add_rod(Vector3(-2, 100, 0), Vector3(2, 100, 0), r))
				var p := fx.player
				var vmax := p.model.params.v_max
				var r_sum := p.model.params.r_body + r
				var start := Vector3(0.0, 100.0 + maxf(4.0, 3.0 * vmax * dt), 0.3 * p.model.params.r_body)
				p.start_flying(start, 0.0, 0.0)
				p.model.reset(start, Vector3(0, -vmax, 0), 0.0)
				# A real terminal tuck dive: body along the path (alpha ~ 0).
				p.model.theta = -PI / 2
				var cal := p.wing_input.calibration
				fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					b.synth(-1.0, 0.0, 0.0, cal)
				var st := {"below": false, "min_d": INF, "v_at": 0.0}
				for i in 30:
					p.tick(dt)
					var pos := p.model.position
					var d := Vector2(pos.y - 100.0, pos.z).length()
					if d < st["min_d"]:
						st["min_d"] = d
						st["v_at"] = p.model.velocity.length()
					if pos.y < 100.0 - r_sum and absf(pos.z) < r_sum:
						st["below"] = true
				var touched: bool = p.contacts["stun"] + p.contacts["slide"] + p.contacts["silent"] > 0
				_log("%s tucked dive %.1f m/s onto a %s (r %.3f) at dt %.3f: min centre distance %.4f (r_sum %.4f), passed below within r_sum %s, contacts %s, mode %s" % [
					sp, vmax, kind, r, dt, st["min_d"], r_sum, st["below"], str(p.contacts), p.mode_name()])
				gt(st["min_d"], r_sum - 0.002, "%s %s dt %.3f: never inside the rod (m)" % [sp, kind, dt])
				check(touched, "%s %s dt %.3f: the rod is hit (a contact), not skipped" % [sp, kind, dt])
				check(not st["below"], "%s %s dt %.3f: no tunnelling (never below the rod within r_sum of its axis)" % [sp, kind, dt])
				fx.teardown()
				fx = null


## A player's approach: glide in from 8 spans at 1.25 V_min, wrists up (pitch
## 0.8) for the last 3 spans, from an angle off the perch axis and from
## below / above.
func test_r2_player_like_perching() -> void:
	var total := 0
	var ok := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for c in [["aligned", 0.0, 0.3], ["30deg side", 30.0, 0.3], ["60deg side", 60.0, 0.3], ["from 1 span below", 0.0, -1.0],
				["from 1.5 spans above", 0.0, 1.5], ["behind the perch", 180.0, 0.3]]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: Variant) -> void:
				w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.02, 1.0))
			var p := fx.player
			var pr := p.model.params
			var target := PERCH + Vector3.UP * pr.r_body
			var ang: float = float(c[1]) * DEG
			var dir := Vector3(sin(ang), 0.0, -cos(ang))   # flight direction
			var start := target - dir * 8.0 * pr.span + Vector3.UP * float(c[2]) * pr.span
			var v := 1.25 * pr.v_min
			var vel := (target - start).normalized() * v
			var yaw := atan2(-vel.x, -vel.z)
			p.start_flying(start, yaw, 0.0)
			p.rig_yaw = yaw
			p.model.reset(start, vel, yaw)
			var cal := p.wing_input.calibration
			var st := {"t": -1.0}
			fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				var dd: float = fx.player.model.position.distance_to(target) / pr.span
				b.synth(0.8 if dd < 3.0 else 0.4, 0.0, 1.0, cal)
			var t0 := fx.ticks
			fx.on_tick = func(tick: int, f: Variant) -> void:
				if st["t"] < 0.0 and f.player.mode == PlayerBird.Mode.PERCHED:
					st["t"] = (tick - t0) * DT
			fx.run(4.0)
			total += 1
			var good: bool = float(st["t"]) >= 0.0
			ok += 1 if good else 0
			_log("perch %s %-20s: %s at %.2f s, stuns %d, slides %d, final mode %s, dist %.2f spans, perched pitch %.1f deg" % [
				sp, c[0], "PERCHED" if good else "missed", st["t"], p.contacts["stun"], p.contacts["slide"], p.mode_name(),
				p.model.position.distance_to(target) / pr.span, rad_to_deg(p.model.theta)])
			if c[0] in ["aligned", "30deg side", "from 1 span below", "from 1.5 spans above"]:
				check(good, "%s %s: a slow player-like approach perches" % [sp, c[0]])
			if good:
				fx.run(2.0)
				lt(absf(rad_to_deg(p.model.theta)), 3.0, "%s %s: perched body is level after 2 s (deg)" % [sp, c[0]])
			fx.teardown()
			fx = null
	_log("player-like perching: %d / %d" % [ok, total])


func test_r2_cruise_pass_and_oversize() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		# A cruise-speed pass 0.3 span above the perch does not perch.
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.02, 1.0))
		var p := fx.player
		var pr := p.model.params
		var start := PERCH + Vector3(0, pr.r_body + 0.3 * pr.span, 8.0 * pr.span)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 0, -pr.v_c), 0.0)
		fx.run(1.5)
		_log("%s cruise pass over the perch: mode %s, perched events %d, stuns %d" % [sp, p.mode_name(), fx.events["perched"], p.contacts["stun"]])
		eq(fx.events["perched"], 0, "%s: a cruise-speed pass does not perch" % sp)
		fx.teardown()
		fx = null
	# An eagle onto a sparrow-sized perch: never perches.
	fx = FX.new(self)
	var small := SizeRules.wingspan_for_mass(FlightParams.species_mass(&"sparrow"))
	await fx.setup(&"eagle", func(w: Variant) -> void:
		w.add_perch(PERCH, Vector3.FORWARD, small, 0.01, 0.3))
	var pe := fx.player
	var pre := pe.model.params
	var s2 := PERCH + Vector3(0, pre.r_body + 0.3 * pre.span, 6.0 * pre.span)
	pe.start_flying(s2, 0.0, 0.0)
	pe.model.reset(s2, (PERCH + Vector3.UP * pre.r_body - s2).normalized() * 1.1 * pre.v_min, 0.0)
	fx.driver = fx.synth(0.8, 0.0)
	fx.run(3.0)
	_log("eagle onto a sparrow-sized perch: mode %s, perched events %d, stuns %d, slides %d" % [pe.mode_name(), fx.events["perched"], pe.contacts["stun"], pe.contacts["slide"]])
	eq(fx.events["perched"], 0, "an eagle never perches on a sparrow-sized perch")
