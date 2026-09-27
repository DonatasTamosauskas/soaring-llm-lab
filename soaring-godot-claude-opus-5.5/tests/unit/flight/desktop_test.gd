extends TestCase
## DSK-01 and F13: the desktop controls, driven by real key events
## (Input.parse_input_event, flushed), through DesktopPoseSource ->
## HumanPoseModel -> the SAME WingInput a headset feeds. Nothing here writes
## WingState. Part two flies the lab course on keys alone: a closed-loop
## "key pilot" that can only press and release W/S/A/D/Space/Shift, the way a
## player at a keyboard would.

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0

var _down := {}
var _trace := false


func after_each() -> void:
	_release_all()


func _key(code: Key, down: bool) -> void:
	if bool(_down.get(code, false)) == down:
		return
	_down[code] = down
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = down
	Input.parse_input_event(e)
	# Input buffers events until the next frame; flush so the state is live
	# for this tick (the same thing the main loop does once per frame).
	Input.flush_buffered_events()


func _release_all() -> void:
	for code in _down.keys():
		_key(code, false)
	_down.clear()


func _rig() -> Array:
	var src := DesktopPoseSource.new()
	var wi := WingInput.new()
	wi.auto_calibrate = false
	return [src, wi, PoseFrame.new()]


## Runs the desktop rig for `seconds`; cb.call(ws, wi) after each tick.
func _run(r: Array, seconds: float, cb: Callable = Callable()) -> WingState:
	var src: DesktopPoseSource = r[0]
	var wi: WingInput = r[1]
	var fr: PoseFrame = r[2]
	var ws := wi.state
	for i in int(round(seconds / DT)):
		src.sample(fr, DT)
		ws = wi.update(fr, DT)
		if cb.is_valid():
			cb.call(ws, wi)
	return ws


func test_dsk01_keys_pitch_roll() -> void:
	var r := _rig()
	_run(r, 1.0)
	_key(KEY_W, true)
	var ws := _run(r, 0.5)
	metric("w_pitch", ws.pitch)
	lt(ws.pitch, -0.8, "hold W 0.5 s: pitch")
	_key(KEY_W, false)
	_run(r, 1.0)
	near(ws.pitch, 0.0, 0.05, "W released: pitch springs back")
	_key(KEY_S, true)
	ws = _run(r, 0.5)
	metric("s_pitch", ws.pitch)
	gt(ws.pitch, 0.8, "hold S 0.5 s: pitch")
	_key(KEY_S, false)
	_run(r, 1.0)
	_key(KEY_A, true)
	ws = _run(r, 0.5)
	metric("a_roll", ws.roll)
	lt(ws.roll, -0.8, "hold A 0.5 s: roll (left)")
	_key(KEY_A, false)
	_run(r, 1.0)
	_key(KEY_D, true)
	ws = _run(r, 0.5)
	metric("d_roll", ws.roll)
	gt(ws.roll, 0.8, "hold D 0.5 s: roll (right)")
	_key(KEY_D, false)
	ws = _run(r, 1.0)
	near(ws.roll, 0.0, 0.05, "D released: roll back to level")


func test_dsk01_space_tap_one_stroke() -> void:
	var r := _rig()
	_run(r, 1.0)
	var acc := {"onsets": 0, "events": 0, "peak_l": 0.0, "peak_r": 0.0}
	var cb := func(w: WingState, wi: WingInput) -> void:
		if w.onset_l or w.onset_r:
			acc["onsets"] += 1
		acc["events"] += wi.flapped_events().size()
		acc["peak_l"] = maxf(acc["peak_l"], w.flap_l)
		acc["peak_r"] = maxf(acc["peak_r"], w.flap_r)
	_key(KEY_SPACE, true)
	_run(r, DT, cb)
	_key(KEY_SPACE, false)
	_run(r, 3.0, cb)
	metric("tap_events", acc["events"])
	metric("tap_peak", minf(acc["peak_l"], acc["peak_r"]))
	eq(acc["events"], 1, "a Space tap is exactly one flap event")
	eq(acc["onsets"], 1, "a Space tap is exactly one (paired) onset tick")
	gt(minf(acc["peak_l"], acc["peak_r"]), 0.8, "tap stroke peak flap, both wings")


func test_dsk01_one_wing_and_tuck() -> void:
	var r := _rig()
	_run(r, 1.0)
	var acc := {"l": 0.0, "r": 0.0}
	var cb := func(w: WingState, _wi: WingInput) -> void:
		acc["l"] = maxf(acc["l"], w.flap_l)
		acc["r"] = maxf(acc["r"], w.flap_r)
	_key(KEY_Q, true)
	_run(r, 3.0, cb)
	_key(KEY_Q, false)
	_run(r, 1.5, cb)
	metric("q_flap_l", acc["l"])
	metric("q_flap_r", acc["r"])
	gt(acc["l"], 0.0, "Q: the left wing flaps")
	eq(acc["r"], 0.0, "Q: the right wing never flaps")
	acc["l"] = 0.0
	acc["r"] = 0.0
	_key(KEY_E, true)
	_run(r, 3.0, cb)
	_key(KEY_E, false)
	_run(r, 1.5, cb)
	gt(acc["r"], 0.0, "E: the right wing flaps")
	eq(acc["l"], 0.0, "E: the left wing never flaps")
	_key(KEY_SHIFT, true)
	var ws := _run(r, 0.6)
	check(ws.tucked, "Shift: tucked")
	metric("shift_ext", ws.mean_extension())
	lt(ws.mean_extension(), 0.5, "Shift: wings folded")
	_key(KEY_SHIFT, false)
	ws = _run(r, 1.0)
	check(not ws.tucked, "Shift released: spread again")


func test_dsk01_mouse_look_never_steers() -> void:
	var r := _rig()
	var src: DesktopPoseSource = r[0]
	var ws := _run(r, 1.0)
	var before := WR.snap(ws)
	# Look around hard: yaw +-90 deg, pitch +-45 deg, over 2 s.
	var acc := {"worst": 0.0, "key": ""}
	for i in 144:
		var t := i * DT
		var yaw := 0.5 * PI * sin(TAU * 0.5 * t)
		var pit := 0.25 * PI * sin(TAU * 0.7 * t)
		var prev_yaw := 0.5 * PI * sin(TAU * 0.5 * (t - DT)) if i > 0 else 0.0
		var prev_pit := 0.25 * PI * sin(TAU * 0.7 * (t - DT)) if i > 0 else 0.0
		src.look(yaw - prev_yaw, pit - prev_pit)
		ws = _run(r, DT)
		var d: Array = WR.max_diff(before, WR.snap(ws))
		if float(d[0]) > float(acc["worst"]):
			acc["worst"] = d[0]
			acc["key"] = d[1]
	metric("look_worst", acc["worst"])
	lt(acc["worst"], 0.01, "mouse look leaves every command unchanged (worst: %s)" % acc["key"])
	# A captured-mouse motion event takes the same path (a no-op when not captured).
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(400, 0)
	src.handle_input(mm)
	ws = _run(r, 0.2)
	lt(float(WR.max_diff(before, WR.snap(ws))[0]), 0.01, "mouse motion event leaves commands unchanged")


# --- F13: fly the lab on keys ---------------------------------------------------

## A keyboard pilot: bang-bang keys with hysteresis, the way a person holds
## and releases keys. It sees what a player sees (position, velocity, bank,
## airspeed) and presses only W/S/A/D/Space/Shift.
class KeyPilot:
	var suite: Node
	var target := Vector3.ZERO
	var alt := 20.0
	var v_c := 9.0
	var bank_max := 0.6
	var flap_on := false
	var roll_key := 0

	func _init(p_suite: Node) -> void:
		suite = p_suite

	func update(p: PlayerBird) -> void:
		var m := p.model
		var pos := m.position
		var to := Vector2(target.x - pos.x, target.z - pos.z)
		var want := atan2(-to.x, -to.y)
		var err := wrapf(want - m.heading(), -PI, PI)
		# Desired bank from the heading error (right turn = heading falls).
		var phi_d := clampf(-1.2 * err, -bank_max, bank_max)
		var phi := m.phi
		if phi < phi_d - 0.08:
			roll_key = 1
		elif phi > phi_d + 0.08:
			roll_key = -1
		elif absf(phi - phi_d) < 0.03:
			roll_key = 0
		suite._key(KEY_D, roll_key > 0)
		suite._key(KEY_A, roll_key < 0)
		# Energy on flapping, height on pitch - the way people fly it: flap
		# while total energy (height + v^2/2g) is short of the target, and
		# trade speed for height with W/S. Both use a short look-ahead (a
		# stroke keeps pushing after the key is released).
		var v := m.airspeed()
		var e_now := pos.y + v * v / (2.0 * FlightMath.G)
		var e_rate := m.velocity.y + (v - _v_prev) / DT_TICK * v / FlightMath.G if _v_prev > 0.0 else m.velocity.y
		_v_prev = v
		_e_rate += (e_rate - _e_rate) * 0.1
		var e_tgt := alt + v_c * v_c / (2.0 * FlightMath.G)
		var e_pred := e_now + 0.8 * _e_rate
		if e_pred < e_tgt - 0.3:
			flap_on = true
		elif e_pred > e_tgt + 0.3:
			flap_on = false
		suite._key(KEY_SPACE, flap_on)
		var y_pred := pos.y + 0.7 * m.velocity.y
		suite._key(KEY_W, y_pred > alt + 0.3 and v < 1.4 * v_c)
		suite._key(KEY_S, y_pred < alt - 0.3 and v > 0.8 * v_c)

	var _v_prev := -1.0
	var _e_rate := 0.0
	const DT_TICK := 1.0 / 72.0


func _fly_lab(sp: StringName) -> Dictionary:
	var course := FlightCourse.new(FlightParams.species_mass(sp))
	var fx := FX.new(self)
	await fx.setup(sp, func(w: World) -> void: course.build(w, false, true))
	var p := fx.player
	p.set_pose_source(DesktopPoseSource.new())
	p.start_flying(course.start.origin, 0.0)
	var pilot := KeyPilot.new(self)
	pilot.v_c = p.model.params.v_c
	(p.pose_source as DesktopPoseSource).amplitude = 30.0     # a wheel notch or three down: gentler strokes
	var phase := {"name": "rings"}
	var rec := {"t": PackedFloat64Array(), "x": PackedFloat64Array(), "y": PackedFloat64Array(), "z": PackedFloat64Array(),
		"v": PackedFloat64Array(), "keys": []}
	fx.on_tick = func(tk: int, f: RefCounted) -> void:
		var mm: FlightModel = f.player.model
		rec["t"].append(tk * DT)
		rec["x"].append(mm.position.x)
		rec["y"].append(mm.position.y)
		rec["z"].append(mm.position.z)
		rec["v"].append(mm.airspeed())
		rec["keys"].append(_down.keys().filter(func(k: Variant) -> bool: return _down[k]))
		if _trace and tk % 36 == 0:
			var m: FlightModel = f.player.model
			print("[flight] trace %s t %.1f pos %s alt* %.1f tgt %s keys %s phi %.2f hd %.0f v %.1f vz %.2f mode %s" % [phase["name"], tk * DT,
				m.position.snapped(Vector3.ONE * 0.1), pilot.alt, pilot.target.snapped(Vector3.ONE), str(_down.keys().filter(func(k): return _down[k])),
				m.phi, rad_to_deg(m.heading()), m.airspeed(), m.velocity.y, PlayerBird.MODE_NAMES[f.player.mode]])
	var res := {"rings": 0, "ring_miss": [], "turned": false, "turn_x_err": INF, "landed": false,
		"stuns": 0, "took_off": false, "climb_after_takeoff": 0.0, "max_speed_tuck": 0.0, "nan": false}
	var ring_i := 0
	var prev_z := p.model.position.z
	var t := 0.0
	# 1) Rings along leg 1.
	while ring_i < course.rings.size() and t < 60.0:
		var c: Vector3 = course.rings[ring_i]
		pilot.target = c + Vector3(0, 0, -30.0)
		# The rings climb with the leg: aim at the straight line from the
		# previous gate (or the start) to this one, like a glide path.
		var c0: Vector3 = course.rings[ring_i - 1] if ring_i > 0 else course.start.origin
		var f := clampf((c0.z - p.model.position.z) / maxf(c0.z - c.z, 1.0), 0.0, 1.0)
		pilot.alt = lerpf(c0.y, c.y, minf(1.0, f + 0.15))
		pilot.update(p)
		fx.step()
		t += DT
		var z := p.model.position.z
		if prev_z > c.z and z <= c.z:
			var d := Vector2(p.model.position.x - c.x, p.model.position.y - c.y).length()
			if d < course.ring_r:
				res["rings"] += 1
			res["ring_miss"].append(snappedf(d / course.ring_r, 0.01))
			ring_i += 1
		prev_z = z
	phase["name"] = "turn"
	# 2) A 180 deg left turn onto a parallel return leg in open air (the
	#    right-hand return leg is the window leg; its wall is the bot's job).
	pilot.alt = FlightCourse.CRUISE_ALT
	var x_ret := -(course.offset + 10.0)
	var t_turn := 0.0
	while t_turn < 40.0:
		var pos := p.model.position
		pilot.target = Vector3(x_ret, 0, pos.z + 30.0) if pos.x < 0.6 * x_ret \
			else Vector3(x_ret, 0, -course.leg_len - 0.5 * absf(x_ret))
		pilot.update(p)
		fx.step()
		t_turn += DT
		var hd := wrapf(p.model.heading() - PI, -PI, PI)
		if absf(hd) < deg_to_rad(15.0) and pos.x < 0.6 * x_ret:
			# Settle on the new leg for a few seconds, then measure.
			for i in int(4.0 / DT):
				pilot.target = Vector3(x_ret, 0, p.model.position.z + 30.0)
				pilot.update(p)
				fx.step()
			res["turned"] = absf(wrapf(p.model.heading() - PI, -PI, PI)) < deg_to_rad(15.0)
			res["turn_x_err"] = absf(p.model.position.x - x_ret)
			break
	phase["name"] = "tuck"
	# 3) Tuck dive: Shift and nothing else for 3 s; speed relative to the
	#    speed the dive started from (whatever the turn left).
	_release_all()
	var v_entry := p.model.airspeed()
	res["tuck_entry"] = v_entry / p.model.params.v_c
	_key(KEY_SHIFT, true)
	for i in int(3.0 / DT):
		fx.step()
		res["max_speed_tuck"] = maxf(res["max_speed_tuck"], p.model.airspeed() / v_entry)
	_key(KEY_SHIFT, false)
	phase["name"] = "land"
	# 4) Land on the ground: a steady glide at about cruise speed, wings
	#    level, then hold S (flare) for the last couple of spans.
	var stun0: int = p.contacts["stun"]
	var t_land := 0.0
	var sp_ := p.model.params.span
	while t_land < 60.0 and p.mode == PlayerBird.Mode.FLYING:
		var h := p.model.position.y - p.model.params.r_body
		var v := p.model.airspeed()
		var vc := p.model.params.v_c
		_key(KEY_SPACE, false)
		_key(KEY_D, p.model.phi < -0.05)
		_key(KEY_A, p.model.phi > 0.05)
		var flare := h < 2.0 * sp_ + 0.3
		_key(KEY_W, not flare and v < 0.9 * vc)
		_key(KEY_S, flare or (v > 1.2 * vc and p.model.velocity.y < 0.0))
		fx.step()
		t_land += DT
	_release_all()
	res["landed"] = p.mode == PlayerBird.Mode.GROUNDED or p.mode == PlayerBird.Mode.PERCHED
	res["land_mode"] = PlayerBird.MODE_NAMES[p.mode]
	res["stuns"] = int(p.contacts["stun"]) - stun0
	res["land_t"] = t_land
	phase["name"] = "takeoff"
	# 5) Take off from the ground with Space.
	fx.run(0.5)
	var y0 := p.model.position.y
	# Scroll the wheel up to the biggest stroke (the lab forwards input events).
	for i in 8:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		p.pose_source.handle_input(wheel)
	_key(KEY_SPACE, true)
	for i in int(3.0 / DT):
		fx.step()
		if p.mode == PlayerBird.Mode.FLYING:
			res["took_off"] = true
	_key(KEY_SPACE, false)
	res["climb_after_takeoff"] = p.model.position.y - y0
	res["comfort"] = fx.comfort.duplicate()
	res["nan"] = not FlightMath.vfinite(p.model.position)
	fx.assert_comfort(self, "F13 %s" % sp)
	_plot_f13(sp, course, rec, res, p.model.params)
	fx.teardown()
	return res


func test_f13_desktop_flies_the_lab() -> void:
	# Default: the sparrow (the 60 s budget, fix round 4); --full adds the pigeon.
	for sp in ([&"sparrow", &"pigeon"] if Paths.arg("full", "") != "" else [&"sparrow"]):
		var r: Dictionary = await _fly_lab(sp)
		print("[flight] F13 %s %s" % [sp, str(r)])
		metric("%s_rings" % sp, r["rings"])
		metric("%s_turn_x_err" % sp, r["turn_x_err"])
		metric("%s_tuck_speed" % sp, r["max_speed_tuck"])
		eq(r["rings"], 3, "%s: all three rings flown through on keys (miss/r %s)" % [sp, str(r["ring_miss"])])
		check(r["turned"], "%s: the 180 deg turn onto the return leg" % sp)
		lt(r["turn_x_err"], 3.0, "%s: holds the return leg line on keys (m)" % sp)
		gt(r["max_speed_tuck"], 1.3, "%s: a 3 s Shift tuck dive gains >= 30%% airspeed" % sp)
		check(r["landed"], "%s: landed on the ground on keys (mode %s)" % [sp, r["land_mode"]])
		eq(r["stuns"], 0, "%s: no stun on the key landing" % sp)
		check(r["took_off"], "%s: Space takes off from the ground" % sp)
		gt(r["climb_after_takeoff"], 0.5, "%s: climbs after take-off" % sp)
		check(not r["nan"], "%s: finite state" % sp)


## Evidence: artifacts/flight/f13_keys_<species>.png - the key-flown track
## (top and side views with the ring gates) and the key timeline.
func _plot_f13(sp: StringName, c: FlightCourse, rec: Dictionary, res: Dictionary, prm: FlightParams) -> void:
	var pl := FlightPlot.new(1600, 900, "Desktop keys fly the lab: %s (key events only)" % sp)
	pl.note("rings %d/3 (miss/r %s); return leg x err %.2f m; tuck x%.2f speed; landed %s, stuns %d; take-off climb %.1f m" % [
		res["rings"], str(res["ring_miss"]), res["turn_x_err"], res["max_speed_tuck"], res["land_mode"], res["stuns"], res["climb_after_takeoff"]])
	var nz := PackedFloat64Array()
	for z in rec["z"]:
		nz.append(-z)
	# Top view drawn along-track (-z to the right) so the long legs fill the panel.
	var top := pl.panel(Rect2i(80, 110, 700, 420), "Top view", "-z (m)", "x (m)")
	top.equal_aspect = true
	top.line(nz, rec["x"], 0, "flown")
	for g in c.rings:
		top.segment(Vector2(-g.z, g.x - c.ring_r), Vector2(-g.z, g.x + c.ring_r), FlightPlot.INK, 3)
	top.label_at(Vector2(-c.rings[0].z, c.rings[0].x + c.ring_r + 3.0), "rings")
	var side := pl.panel(Rect2i(880, 110, 680, 420), "Side view (leg 1)", "-z (m)", "alt (m)")
	var sz := PackedFloat64Array()
	var sy := PackedFloat64Array()
	var n_leg := 0
	for i in rec["t"].size():
		if rec["z"][i] < -c.leg_len - 5.0:
			break
		n_leg = i
	for i in n_leg:
		sz.append(-rec["z"][i])
		sy.append(rec["y"][i])
	side.line(sz, sy, 0, "altitude")
	for g in c.rings:
		side.segment(Vector2(-g.z, g.y - c.ring_r), Vector2(-g.z, g.y + c.ring_r), FlightPlot.INK, 3)
	side.label_at(Vector2(-c.rings[0].z + 1.0, c.rings[0].y + c.ring_r), "ring gates")
	var sp_panel := pl.panel(Rect2i(80, 610, 700, 220), "Airspeed", "t (s)", "m/s")
	sp_panel.line(rec["t"], rec["v"], 0, "airspeed")
	sp_panel.hline(prm.v_c, FlightPlot.series_color(2), "V_c")
	sp_panel.legend_pos = 2
	# Key timeline: one row per key, a bar while held.
	var kp := pl.panel(Rect2i(880, 610, 680, 220), "Keys held", "t (s)", "")
	var rows := [[KEY_SPACE, "Space"], [KEY_W, "W"], [KEY_S, "S"], [KEY_A, "A"], [KEY_D, "D"], [KEY_SHIFT, "Shift"]]
	kp.set_x(0.0, rec["t"][rec["t"].size() - 1])
	kp.set_y(-0.5, rows.size() - 0.5)
	kp.y_ticks = false
	for r in rows.size():
		var code: int = rows[r][0]
		var y := float(rows.size() - 1 - r)
		var t0 := -1.0
		for i in rec["t"].size():
			var held: bool = (rec["keys"][i] as Array).has(code)
			if held and t0 < 0.0:
				t0 = rec["t"][i]
			elif not held and t0 >= 0.0:
				kp.segment(Vector2(t0, y), Vector2(rec["t"][i], y), FlightPlot.series_color(r % 8), 6)
				t0 = -1.0
		if t0 >= 0.0:
			kp.segment(Vector2(t0, y), Vector2(rec["t"][rec["t"].size() - 1], y), FlightPlot.series_color(r % 8), 6)
		kp.label_at(Vector2(0.0, y + 0.35), rows[r][1])
	var out := Paths.artifacts("flight").path_join("f13_keys_%s.png" % sp)
	pl.save(out)
	check(FileAccess.file_exists(out), "%s: F13 plot written" % sp)
