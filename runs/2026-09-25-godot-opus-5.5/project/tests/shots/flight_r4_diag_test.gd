extends TestCase
## Fix-round-4 diagnostics (on demand, not the unit suite): per-tick traces of
## the rig's yaw and what drives it, for uneven strokes, stuns and perches.
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_r4_diag --test=<name>

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func test_diag_uneven_2hz() -> void:
	fx = FX.new(self)
	await fx.setup(Paths.arg("species", "sparrow"))
	var p := fx.player
	p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	fx.run(0.5)
	var hz := float(Paths.arg("hz", "2.0"))
	var al := float(Paths.arg("al", "30"))
	var ar := float(Paths.arg("ar", "27"))
	var lag := float(Paths.arg("lag", "0"))
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, al, hz, -1)
		ScriptedPoseSource.flap(b, maxf(t - lag, 0.0), ar, hz, 1)
	var rows := PackedStringArray()
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var m := pl.model
		var w: WingState = pl.wing_state()
		var t := tick * DT
		if t > 3.0 and t < 5.0:
			var rh := Basis(Vector3.UP, m.chi) * Vector3.RIGHT
			rows.append("t %.3f rig_rate %6.1f yaw_rate %6.1f dpsi %5.2f phi %5.2f roll_in %5.3f roll %5.3f body_yaw %5.2f share %.2f ff %6.1f vt %6.1f as %.3f/%.3f flap %.2f/%.2f lat_g %+.3f per %.2f V %.2f vh %.2f vy %.2f vmin %.2f chi %.1f" % [
				t, rad_to_deg(pl.rig_yaw_rate), rad_to_deg(m.yaw_rate), rad_to_deg(m.dpsi), rad_to_deg(m.phi),
				pl.telemetry()["roll_input"], pl._ws.roll, rad_to_deg(w.body_yaw), pl._body_share, rad_to_deg(pl._ff_rate),
				rad_to_deg(pl.view_turn.rate), m._as_l, m._as_r, w.flap_l, w.flap_r, m.last_accel().dot(rh) / 9.81, w.stroke_period, m.airspeed(), Vector2(m.velocity.x, m.velocity.z).length(), m.velocity.y, m.params.v_min, rad_to_deg(m.chi)])
	fx.run(5.0)
	for r in rows:
		print("[flight] ", r)
	check(true, "diag")


## A wall hit at `inc` deg incidence, arms still (C8b's set-up), traced.
func test_diag_wall() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var inc := float(Paths.arg("inc", "60"))
	var ground := Paths.arg("ground", "false") == "true"
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.with_ground = ground
		w.add_wall(Vector3(0, 100 if not ground else 40, -20), Vector3(400, 80, 1.0)))
	var p := fx.player
	var pr := p.model.params
	var yaw := (90.0 - inc) * DEG
	var y0 := 100.0 if not ground else float(Paths.arg("h", "3"))
	var start := Vector3(pr.v_c * 0.8 * cos(inc * DEG), y0, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
	p.start_flying(start, yaw, 0.0)
	p.debug_contacts = Paths.arg("debug", "false") == "true"
	var rows := PackedStringArray()
	var y_start := rad_to_deg(p.rig_yaw)
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var m := pl.model
		var va := m.velocity - m.wind
		rows.append("t %.3f %-8s hd %7.1f rig %7.1f chi %7.1f dpsi %5.1f path %7.1f V %5.2f vh %5.2f vy %5.2f z %6.2f y %6.2f forced %5.1f debt %6.1f vt %6.1f rigr %6.1f riga %6.0f c %d/%d/%d" % [
			tick * DT, pl.mode_name(), rad_to_deg(m.heading()) - 0.0, rad_to_deg(pl.rig_yaw), rad_to_deg(m.chi), rad_to_deg(m.dpsi),
			rad_to_deg(atan2(-va.x, -va.z)), m.airspeed(), Vector2(va.x, va.z).length(), va.y, m.position.z, m.position.y,
			rad_to_deg(pl.forced_turn), rad_to_deg(pl.view_turn.debt), rad_to_deg(pl.view_turn.rate), rad_to_deg(pl.rig_yaw_rate),
			rad_to_deg(pl.rig_yaw_accel), pl.contacts["silent"], pl.contacts["slide"], pl.contacts["stun"]])
	fx.run(float(Paths.arg("secs", "4")))
	var every := int(Paths.arg("every", "2"))
	for i in rows.size():
		if i % every == 0:
			print("[flight] ", rows[i])
	print("[flight] start yaw %.1f" % y_start)
	check(true, "diag")


## C8b's flights, summarised: stuns, forced steps, total view rotation.
func test_diag_walls_summary() -> void:
	var ground := Paths.arg("ground", "false") == "true"
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.with_ground = ground
			w.add_wall(Vector3(0, 100 if not ground else 40, -20), Vector3(400, 200, 1.0)))
		for inc: float in [20.0, 30.0, 45.0, 60.0, 75.0, 90.0]:
			var p := fx.player
			var pr := p.model.params
			p.rig_limited_ticks = 0
			fx.reset_comfort()
			var yaw := (90.0 - inc) * DEG
			var y0 := 100.0 if not ground else float(Paths.arg("h", "3"))
			var vk := float(Paths.arg("vk", "0.8"))
			var start := Vector3(pr.v_c * vk * cos(inc * DEG), y0, -20 + 0.5 + pr.r_body + pr.v_c * vk * sin(inc * DEG))
			p.start_flying(start, yaw, 0.0)
			p.model.velocity = FlightMath.yaw_forward(yaw) * pr.v_c * vk * 1.0 + Vector3(0, p.model.velocity.y, 0)
			var st := {"stuns": 0, "prev": p.mode, "hit": -1.0, "rot": 0.0, "rot_stun": 0.0, "fmax": 0.0, "vtr": 0.0, "vta": 0.0,
				"yp": p.rig_yaw, "end": -1.0, "slides": 0, "off": -1.0}
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				var t := tick * DT
				if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
					if st["hit"] < 0.0:
						st["hit"] = t
				if pl.mode == PlayerBird.Mode.FLYING and st["prev"] == PlayerBird.Mode.STUNNED and st["end"] < 0.0:
					st["end"] = t
				st["prev"] = pl.mode
				var dy := absf(FlightMath.wrap_angle(pl.rig_yaw - float(st["yp"])))
				st["yp"] = pl.rig_yaw
				if st["hit"] >= 0.0 and t - float(st["hit"]) <= 3.0:
					st["rot"] += dy
					if pl.mode == PlayerBird.Mode.STUNNED:
						st["rot_stun"] += dy
				st["fmax"] = maxf(st["fmax"], absf(pl.forced_turn))
				st["vtr"] = maxf(st["vtr"], absf(pl.view_turn.rate))
				st["vta"] = maxf(st["vta"], absf(pl.view_turn.acc))
				if st["end"] >= 0.0 and st["off"] < 0.0 and t >= float(st["end"]) + 1.0:
					st["off"] = absf(FlightMath.wrap_angle(pl.rig_yaw + pl.wing_state().body_yaw - pl.model.heading()))
			fx.run(8.0)
			print("[flight] %s %2d deg: stuns %d, view rot 3 s %.1f (while stunned %.1f), max forced step %.1f, vt %.0f deg/s %.0f deg/s2, rig max %.0f / %.0f, net %d, slides %d, off %.1f, mode %s, y %.1f, dist %.1f" % [
				sp, int(inc), st["stuns"], rad_to_deg(st["rot"]), rad_to_deg(st["rot_stun"]), rad_to_deg(st["fmax"]), rad_to_deg(st["vtr"]), rad_to_deg(st["vta"]),
				rad_to_deg(fx.comfort["max_rate"]), rad_to_deg(fx.comfort["max_accel"]), p.rig_limited_ticks, p.contacts["slide"], rad_to_deg(st["off"]),
				p.mode_name(), p.model.position.y, p.model.position.z + 19.5])
			fx.on_tick = Callable()
		fx.teardown()
		fx = null
	check(true, "diag")


## The verifier's corner at 0.9 V_max (r4eng test 4), traced.
func test_diag_corner() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.with_ground = false
		w.add_wall(Vector3(0, 100, -20.5), Vector3(80, 80, 1.0))
		w.add_wall(Vector3(-20.5, 100, 0), Vector3(1.0, 80, 80)))
	var p := fx.player
	var pr := p.model.params
	var yaw := 45.0 * DEG
	p.start_flying(Vector3(0, 100, 0), yaw, 0.0)
	p.model.reset(Vector3(0, 100, 0), FlightMath.yaw_forward(yaw) * 0.9 * pr.v_max, yaw)
	var rows := PackedStringArray()
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var m := pl.model
		var va := m.velocity - m.wind
		rows.append("t %.3f %-8s hd %7.1f rig %7.1f dpsi %5.1f path %7.1f V %5.2f vh %5.2f vy %6.2f x %6.2f z %6.2f y %6.2f forced %5.1f debt %6.1f vt %6.1f rigr %6.1f c %d/%d/%d" % [
			tick * DT, pl.mode_name(), rad_to_deg(m.heading()), rad_to_deg(pl.rig_yaw), rad_to_deg(m.dpsi),
			rad_to_deg(atan2(-va.x, -va.z)), m.airspeed(), Vector2(va.x, va.z).length(), va.y, m.position.x, m.position.z, m.position.y,
			rad_to_deg(pl.forced_turn), rad_to_deg(pl.view_turn.debt), rad_to_deg(pl.view_turn.rate), rad_to_deg(pl.rig_yaw_rate),
			pl.contacts["silent"], pl.contacts["slide"], pl.contacts["stun"]])
	fx.run(9.0)
	var every := int(Paths.arg("every", "6"))
	for i in rows.size():
		if i % every == 0:
			print("[flight] ", rows[i])
	check(true, "diag")


## Desktop take-off from the ground (F13's last phase), traced.
func test_diag_desktop_takeoff() -> void:
	fx = FX.new(self)
	await fx.setup(StringName(Paths.arg("species", "sparrow")))
	var p := fx.player
	var src := DesktopPoseSource.new()
	p.set_pose_source(src)
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, p.model.params.r_body, 0)))
	fx.run(1.0)
	p.start_flying(Vector3(0, 0.5, 0), 0.0, 0.3)
	for i in 300:
		fx.step()
		if p.mode == PlayerBird.Mode.GROUNDED:
			break
	print("[flight] mode after landing: %s" % p.mode_name())
	src.relaxed = Paths.arg("relaxed", "false") == "true"
	for i in 8:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		src.handle_input(wheel)
	var e := InputEventKey.new()
	e.physical_keycode = KEY_SPACE
	e.keycode = KEY_SPACE
	e.pressed = true
	Input.parse_input_event(e)
	Input.flush_buffered_events()
	for i in int(3.0 / DT):
		fx.step()
		var d0: FlapDetector = p.wing_input.detectors[0]
		if i % 3 == 0:
			print("[flight] t %.3f %s elev %.1f ext_raw %.2f omega %.2f state %d onset %s credit %.2f pend %.2f low %.2f" % [i * DT, p.mode_name(),
				rad_to_deg(p.wing_input.elevation[0]), p.wing_input.ext_raw[0], d0.omega, d0.state, str(d0.onset), d0.onset_strength,
				p._launch_pend[0], p._launch_low[0]])
	e.pressed = false
	Input.parse_input_event(e)
	Input.flush_buffered_events()
	check(true, "diag")


## C5's crevice escape, with knobs.
func test_diag_c5() -> void:
	var r := SizeRules.body_radius_for_mass(0.03)
	var gap := 1.2 * 2.0 * r
	fx = FX.new(self)
	await fx.setup(&"sparrow", func(w: Variant) -> void:
		w.with_ground = false
		w.add_wall(Vector3(-0.5 * gap - 0.5, 100.0, 0), Vector3(1.0, 1.5, 4.0))
		w.add_wall(Vector3(0.5 * gap + 0.5, 100.0, 0), Vector3(1.0, 1.5, 4.0))
		w.add_wall(Vector3(0, 99.25 - 0.05, 0), Vector3(1.0, 0.1, 4.0)))
	var p := fx.player
	p.tuning = p.tuning.duplicate()
	p.tuning.flap_side_share = float(Paths.arg("side", "0"))
	p.tuning.one_wing_deadzone = float(Paths.arg("dz", "0.15"))
	p.model.set_tuning(p.tuning)
	p.start_flying(Vector3(0, 99.35, 0), 0.0, 0.5)
	p.model.velocity = Vector3.ZERO
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.0)
		for a in b.arms:
			a.twist = 20.0 * DEG
	var st := {"t_out": -1.0}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pos: Vector3 = f.player.model.position
		if tick % 9 == 0:
			print("[flight] t %.2f pos %s v %s hd %.1f contacts %s" % [tick * DT, pos.snapped(Vector3.ONE * 0.001), f.player.model.velocity.snapped(Vector3.ONE * 0.01), rad_to_deg(f.player.model.heading()), str(f.player.contacts)])
		if st["t_out"] < 0.0 and (pos.y > 100.75 + r or absf(pos.z) > 2.0 + r):
			st["t_out"] = tick * DT
	fx.run(3.0)
	print("[flight] c5 escape %.2f s" % st["t_out"])
	check(true, "diag")


## B1 at one size with tuning knobs (window speed, perch time).
func test_diag_b1() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	var sp := StringName(Paths.arg("species", "eagle"))
	fx = FX.new(self)
	var b := BC.new(fx, sp)
	await b.setup(false, 1, int(Paths.arg("seed", "21")))
	var p := fx.player
	var tu := p.tuning.duplicate() as FlightTuning
	tu.flap_side_share = float(Paths.arg("side", "0"))
	tu.one_wing_deadzone = float(Paths.arg("dz", "0.15"))
	p.tuning = tu
	p.model.set_tuning(tu)
	b.fly()
	print("[flight] B1 %s seed %s side %.1f dz %.2f: window V/V_min %.3f, err %s, perched %s at %.1f s, stuns %d" % [sp, Paths.arg("seed", "21"), tu.flap_side_share, tu.one_wing_deadzone,
		b.window_speed / p.model.params.v_min, str(b.window_err), str(b.perched_on_target), b.perched_t, p.contacts["stun"]])
	check(true, "diag")


## B1's phases (the autopilot's phase changes: time, position, speed).
func test_diag_b1_phases() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	var sp := StringName(Paths.arg("species", "eagle"))
	fx = FX.new(self)
	var b := BC.new(fx, sp)
	await b.setup(false, 1, int(Paths.arg("seed", "21")))
	var pl := b.pilot
	var p0 := fx.player
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var t := tick * DT
		if tick % 36 == 0 and t >= float(Paths.arg("t0", "24")) and t <= float(Paths.arg("t1", "40")):
			var m: FlightModel = f.player.model
			print("[flight] tr %.1f ph %d y %.1f V %.2f vy %.2f pitch_cmd %.2f pitch_in %.2f eff %.2f flapping %s h_t %.1f v_t %.1f flap %.2f/%.2f alpha %.1f roll %.2f phi %.1f dpsi %.2f as %.2f/%.2f ext %.2f/%.2f gload %.2f lift %.2f drag %.2f" % [t, pl.phase, m.position.y, m.airspeed(), m.velocity.y,
				pl.pitch, f.player.wing_state().pitch, pl.effort, str(pl.flapping), pl.h_target, pl.v_target, f.player.wing_state().flap_l, f.player.wing_state().flap_r, rad_to_deg(m.alpha),
				f.player.wing_state().roll, rad_to_deg(m.phi), rad_to_deg(m.dpsi), m._as_l, m._as_r, f.player.wing_state().ext_l, f.player.wing_state().ext_r, m.g_load, m.lift_n / (m.params.mass * 9.81), m.drag_n / (m.params.mass * 9.81)])
	b.fly()
	var r: Dictionary = b.rec
	var prev := -1
	var quiet := Paths.arg("quiet", "") != ""
	for i in r["t"].size():
		var ph: int = r["phase"][i]
		if quiet:
			if ph != prev and ph == 2:
				var vv: float = r["v"][i]
				print("[flight] final glide entry t %.1f y %.2f V %.2f E %.2f (gap y %.2f)" % [r["t"][i], r["y"][i], vv, float(r["y"][i]) + vv * vv / 19.62, b.course.window_center.y])
			prev = ph
			continue
		if ph != prev or i % 360 == 0:
			print("[flight] t %.1f phase %d pos (%.1f, %.1f, %.1f) V %.2f bank %.0f" % [r["t"][i], ph, r["x"][i], r["y"][i], r["z"][i], r["v"][i], r["bank"][i]])
			prev = ph
	print("[flight] window V/V_min %.3f perched %.1f orbits %d" % [b.window_speed / fx.player.model.params.v_min, b.perched_t, b.pilot.orbits])
	check(true, "diag")


## B2 novice flight (seed, size) with the heave windows traced.
func test_diag_b2_heave() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	const HM := preload("res://tests/unit/flight/heave_metrics.gd")
	var sp := StringName(Paths.arg("species", "eagle"))
	fx = FX.new(self)
	var b := BC.new(fx, sp)
	await b.setup(true, 1, int(Paths.arg("seed", "8")))
	var hm := HM.new()
	var rows := PackedStringArray()
	fx.on_tick = func(tick: int, f: Variant) -> void:
		hm.push(f.player)
		var pl: PlayerBird = f.player
		var hs := pl.heave
		var w: WingState = pl.wing_state()
		rows.append("%.3f off %.3f vy %.2f gate %.2f q %.2f act %.2f amp %.2f pf %.2f th %.2f rhythm %s per %.2f omega %.1f/%.1f flap %.2f/%.2f ph %d" % [tick * DT, hs.offset, pl.model.velocity.y, hs.gate, hs.quality,
			hs._act, hs._amp, hs._pf, hs._theta, str(hs.rhythm_open), hs.period, w.omega_l, w.omega_r, w.flap_l, w.flap_r, b.pilot.phase])
	b.fly(true)
	var ser: Array = hm.band_window_series()
	var worst := 0.0
	var wt := 0.0
	for i in ser[0].size():
		if float(ser[1][i]) > worst:
			worst = ser[1][i]
			wt = ser[0][i]
	print("[flight] B2 %s: worst window %.2f at %.1f s (centre)" % [sp, worst, wt])
	# 0.5 s sub-windows of the worst window: camera vs body band RMS.
	var pc: PackedFloat64Array = hm._band_prefix(hm.cam)
	var pb: PackedFloat64Array = hm._band_prefix(hm.body)
	var i0 := int((wt - 1.5) / DT)
	for k in 6:
		var a := i0 + k * 36
		print("[flight] sub %.2f-%.2f cam %.2f body %.2f" % [a * DT, (a + 36) * DT, hm._band_rms(pc, a, a + 36), hm._band_rms(pb, a, a + 36)])
	for r in rows:
		var t := float(r.split(" ")[0])
		if t > float(Paths.arg("r0", "0")) and t < float(Paths.arg("r1", "0")):
			print("[flight] ", r)
	check(true, "diag")


## P6's last step (a flap from the rest pose), traced.
func test_diag_rest_flap() -> void:
	fx = FX.new(self)
	await fx.setup(&"pigeon", func(w: Variant) -> void:
		w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 10.0, 0.015, 1.0))
	var p := fx.player
	p.perch_on(fx.world.get_perches()[0])
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for a in b.arms:
			a.dihedral = -85.0 * DEG
			a.elbow = 20.0 * DEG
	fx.run(2.0)
	var t0 := fx.ticks
	var raise := float(Paths.arg("raise", "0.5"))
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		var tt := (fx.ticks - t0) * DT
		b.set_airplane()
		if tt < raise:
			var k := 1.0 - tt / raise
			for a in b.arms:
				a.dihedral = -85.0 * DEG * k
				a.elbow = 20.0 * DEG * k
		else:
			ScriptedPoseSource.flap(b, tt - raise + 0.25, 45.0, 1.0)
	for i in int(2.0 / DT):
		fx.step()
		var d: FlapDetector = p.wing_input.detectors[0]
		print("[flight] t %.3f %s elev %6.1f ext %.2f om %5.2f st %d onset %s cr %.2f arc %.2f bank %.2f flap %.2f pend %.2f low %.2f" % [(fx.ticks - t0) * DT, p.mode_name(),
			rad_to_deg(p.wing_input.elevation[0]), p.wing_input.ext_raw[0], d.omega, d.state, str(d.onset), d.credit, rad_to_deg(d.up_arc), rad_to_deg(d.bank), d.flap,
			p._launch_pend[0], p._launch_low[0]])
	check(true, "diag")
