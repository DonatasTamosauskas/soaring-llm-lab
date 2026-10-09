extends TestCase
## Verifier probe (flight, ENGINEERING & CONTRACT lens, round 6 = the check of
## builder fix round 5). Independent of the area's own assertions: every rig
## quantity is measured from the NODES with the dt actually ticked.
##  1. The resume hold is reached through Godot's real pause (SceneTree.paused),
##     not only through a hand-sent NOTIFICATION_UNPAUSED (PB-29 sends it).
##  2. telemetry() read from inside an Events handler mid-tick vs the
##     end-of-tick values ("same values" claim of the round-5 cache).
##  3. Touchdown grid: G1 pins the gentlest touchdown (0.6 V_min forward,
##     0.2 V_min down). Every LAND-classified descent angle, from the nodes.
##  4. Random play near the ground (touchdowns, run-outs, an edge, a wall, a
##     branch, flares, flaps, tucks, tracking loss, resumes, long ticks):
##     node-measured rig comfort, camera on the body, never into the ground,
##     GROUNDED only on a floor, no NaN.
##  5. In-game stall guard boundary: full nose-up held from level flight at
##     several heights above the ground (PlayerBird level, normal preset).
##  6. Determinism of a ground landing (bit-identical twice, and after an
##     unrelated flight).
## Output: artifacts/flight/verify/r6eng/probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0
const S3: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]

var fx: FX
var _lines: PackedStringArray = []


func _log(s: String) -> void:
	print("[flight-r6eng] ", s)
	_lines.append(s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	get_tree().paused = false
	await get_tree().process_frame


func after_all() -> void:
	var dir := Paths.artifacts("flight").path_join("verify/r6eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("probe.txt"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _fx(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, world_setup)
	return fx


# --- 1. the real pause path --------------------------------------------------------
func test_r6_real_unpause_engages_the_resume_hold() -> void:
	await _fx(&"pigeon")
	var p := fx.player
	p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
	fx.run(1.0)
	var hold0: float = p.get("_resume_hold")
	get_tree().paused = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	get_tree().paused = false
	var hold1: float = p.get("_resume_hold")
	var fade1: float = p.get("_controls_fade")
	_log("real pause: resume hold before %.2f s, after unpause %.2f s, controls fade %.2f" % [hold0, hold1, fade1])
	eq(hold0, 0.0, "no hold before the pause")
	near(hold1, 1.5, 1e-6, "a real SceneTree unpause starts the 1.5 s resume hold")
	eq(fade1, 0.0, "and zeroes the controls fade")


# --- 2. telemetry read inside an event handler mid-tick --------------------------
func test_r6_telemetry_read_in_a_handler_matches_end_of_tick() -> void:
	await _fx(&"sparrow")
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, pr.r_body + 0.25, 0)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, -0.2 * pr.v_min, -0.6 * pr.v_min), 0.0)
	var got := {"mid": {}}
	var h := func(_pos: Vector3) -> void:
		got["mid"] = p.telemetry().duplicate()
	Events.player_perched.connect(h)
	var diffs: PackedStringArray = []
	for i in 72:
		fx.step()
		if not (got["mid"] as Dictionary).is_empty():
			var stale := p.telemetry().duplicate()
			p.set("_tel_tick", -1)
			var fresh := p.telemetry()
			for k in fresh:
				if k == "tick_ms":
					continue
				if str(stale.get(k)) != str(fresh[k]):
					diffs.append("%s: read %s, end of tick %s" % [k, str(stale.get(k)), str(fresh[k])])
			break
	Events.player_perched.disconnect(h)
	check(not (got["mid"] as Dictionary).is_empty(), "the touchdown fired player_perched")
	_log("telemetry read inside player_perched, then read again after the tick: %d keys differ from the end-of-tick build" % diffs.size())
	for d in diffs:
		_log("   " + d)
	eq(diffs.size(), 0, "a read inside an Events handler leaves the tick's telemetry at end-of-tick values (keys differing: %s)" % ", ".join(diffs))


# --- 3. touchdown grid -------------------------------------------------------------
func _touchdown(sp: StringName, fwd: float, down: float) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, pr.r_body + 0.01, 0)
	p.start_flying(start, 0.0, 0.0)
	var v0 := Vector3(0, -down * pr.v_min, -fwd * pr.v_min)
	p.model.reset(start, v0, 0.0)
	var st := {"last": p.camera.global_position, "lastv": v0, "worst": 0.0, "td": false, "v_td": 0.0, "vn_td": 0.0,
		"stun": 0, "slide": 0, "prev_v": v0}
	for i in 90:
		fx.step()
		var c := p.camera.global_position
		var v: Vector3 = (c - st["last"]) / DT
		if i < 60:
			st["worst"] = maxf(st["worst"], (v - st["lastv"]).length())
		st["lastv"] = v
		st["last"] = c
		if not bool(st["td"]) and p.mode == PlayerBird.Mode.GROUNDED:
			st["td"] = true
			var pv: Vector3 = st["prev_v"]
			st["v_td"] = pv.length()
			st["vn_td"] = -pv.y
		st["prev_v"] = p.model.velocity
	var out := {"landed": bool(st["td"]), "stuns": p.contacts["stun"], "slides": p.contacts["slide"],
		"ratio": float(st["worst"]) / maxf(v0.length(), 1e-3), "dv": float(st["worst"]),
		"dv_perceived": float(st["worst"]) / p.origin.world_scale, "v_td": st["v_td"], "vn_td": st["vn_td"]}
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r6_touchdown_grid() -> void:
	var over := 0
	var landed_n := 0
	for sp in S3:
		var row: PackedStringArray = []
		for down: float in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]:
			for fwd: float in [0.4, 0.6, 0.8, 1.0]:
				var r: Dictionary = await _touchdown(sp, fwd, down)
				if bool(r["landed"]):
					landed_n += 1
					if float(r["ratio"]) > 0.45:
						over += 1
				row.append("%s f%.1f d%.1f: %s stun%d ratio %.2f dv %.2f m/s (%.1f perceived) vn_td %.2f" % [sp, fwd, down,
					"LAND" if r["landed"] else "----", r["stuns"], r["ratio"], r["dv"], r["dv_perceived"], r["vn_td"]])
		for l in row:
			_log(l)
	_log("touchdown grid: %d of %d landings exceed G1's 0.45 x touchdown-speed bound" % [over, landed_n])
	gt(landed_n, 0, "some grid cells land")
	metric("landings_over_045", over)
	metric("landings", landed_n)


# --- 4. random play near the ground ------------------------------------------------
func _ground_world(w: World) -> void:
	# A 3 m platform with an edge, a wall, and a branch.
	w.add_wall(Vector3(30, 1.5, 0), Vector3(20, 3.0, 20))
	w.add_wall(Vector3(-25, 5.0, 0), Vector3(1.0, 10.0, 40))
	w.add_perch(Vector3(0, 4.0, -20), Vector3.FORWARD, 10.0, 0.02, 2.0)


func _random_play(sp: StringName, seed_v: int, seconds: float) -> Dictionary:
	await _fx(sp, _ground_world)
	var p := fx.player
	var pr := p.model.params
	var cal := p.wing_input.calibration
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var g := {"kind": 0, "until": 0.0, "amp": 45.0, "hz": 1.5, "tw": 30.0, "r": 0.0, "lost": 0.0, "menu": 0.0}
	var clk := {"t": 0.0}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		var t: float = clk["t"]
		b.set_airplane()
		b.head_valid = true
		b.left_valid = true
		b.right_valid = true
		match int(g["kind"]):
			1:
				b.arms[0].twist = float(g["tw"]) * DEG
				b.arms[1].twist = float(g["tw"]) * DEG
			2:
				ScriptedPoseSource.flap(b, t, g["amp"], g["hz"])
			3:
				b.synth(0.0, 0.0, 0.1, cal)
			4:
				b.synth(0.2, float(g["r"]), 1.0, cal)
			5:
				b.arms[0].dihedral = -80.0 * DEG
				b.arms[1].dihedral = -80.0 * DEG
			6:
				b.arms[0].dihedral = -80.0 * DEG
				b.arms[1].dihedral = 35.0 * DEG
				b.arms[1].sweep = 60.0 * DEG
		if float(g["lost"]) > t:
			match int(g["lost_kind"]):
				0: b.head_valid = false
				1: b.left_valid = false
				_: b.right_valid = false
	var st := {"basis_bad": 0, "max_rate": 0.0, "max_acc": 0.0, "cam_h": 0.0, "cam_v": 0.0, "below": 0.0,
		"ground_bad": 0, "nan": 0, "td": 0, "run_off": 0, "launch": 0, "stun": 0, "perched_as": 0,
		"gs_max": 0.0, "grounded_ticks": 0, "worst_where": ""}
	p.start_flying(Vector3(0, 4.0 * pr.span + 1.0, 0), 0.0, 0.0)
	var prev_yaw := FlightMath.yaw_of(-p.global_basis.z)
	var prev_rate := 0.0
	var skip := 2
	var prev_mode := p.mode
	var t := 0.0
	var i := 0
	while t < seconds:
		if t >= float(g["until"]):
			g["kind"] = rng.randi_range(0, 6)
			g["until"] = t + rng.randf_range(0.8, 3.0)
			g["amp"] = rng.randf_range(30.0, 60.0)
			g["hz"] = rng.randf_range(1.0, 2.5)
			g["tw"] = rng.randf_range(10.0, 45.0)
			g["r"] = rng.randf_range(-1.0, 1.0)
			if rng.randf() < 0.15:
				g["lost"] = t + rng.randf_range(0.1, 1.2)
				g["lost_kind"] = rng.randi_range(0, 2)
			if rng.randf() < 0.1:
				p.notification(Node.NOTIFICATION_UNPAUSED)
		var dt := DT
		var u := rng.randf()
		if u < 0.02:
			dt = 0.1
		elif u < 0.12:
			dt = 1.0 / 90.0
		elif u < 0.2:
			dt = 1.0 / 120.0
		t += dt
		clk["t"] = t
		p.tick(dt)
		i += 1
		# Wandered off: back over the ground in trimmed flight (a flagged snap).
		if Vector2(p.model.position.x, p.model.position.z).length() > 120.0 or p.model.position.y > 80.0:
			p.start_flying(Vector3(rng.randf_range(-10, 10), 4.0 * pr.span + 1.0, rng.randf_range(-10, 10)), rng.randf_range(-PI, PI), 0.0)
		var pos := p.model.position
		if not (FlightMath.vfinite(pos) and FlightMath.vfinite(p.model.velocity) and FlightMath.vfinite(p.camera.global_position)):
			st["nan"] += 1
			continue
		var b := p.global_basis
		var ob := p.origin.global_basis
		if b.y.dot(Vector3.UP) < 1.0 - 1e-6 or absf(b.determinant() - 1.0) > 1e-5 \
				or ob.y.dot(Vector3.UP) < 1.0 - 1e-6 or not p.origin.transform.basis.is_equal_approx(Basis.IDENTITY):
			st["basis_bad"] += 1
		var yaw := FlightMath.yaw_of(-b.z)
		var rate := wrapf(yaw - prev_yaw, -PI, PI) / dt
		if p.yaw_flagged:
			skip = 2
		elif skip > 0:
			skip -= 1
		else:
			st["max_rate"] = maxf(st["max_rate"], absf(rate))
			var acc := absf(rate - prev_rate) / dt
			if acc > float(st["max_acc"]):
				st["max_acc"] = acc
				st["worst_where"] = "t=%.2f mode=%s dt=%.4f" % [t, p.mode_name(), dt]
		prev_yaw = yaw
		prev_rate = rate
		var want := pos + Vector3.UP * p.heave_offset()
		var c := p.camera.global_position
		st["cam_h"] = maxf(st["cam_h"], Vector2(c.x - want.x, c.z - want.z).length())
		st["cam_v"] = maxf(st["cam_v"], absf(c.y - want.y))
		# Ground under the bird: 3 m on the platform, else 0.
		var gh := 3.0 if (absf(pos.x - 30.0) < 10.0 and absf(pos.z) < 10.0) else 0.0
		st["below"] = maxf(st["below"], (gh + pr.r_body) - pos.y)
		if p.mode == PlayerBird.Mode.GROUNDED:
			st["grounded_ticks"] += 1
			if absf(pos.y - (gh + pr.r_body)) > 0.01:
				st["ground_bad"] += 1
			st["gs_max"] = maxf(st["gs_max"], Vector2(p.model.velocity.x, p.model.velocity.z).length() / pr.v_min)
		var tel := p.telemetry()
		if bool(tel["perched"]) and float(tel["airspeed"]) != 0.0:
			st["perched_as"] += 1
		if p.mode != prev_mode:
			if p.mode == PlayerBird.Mode.GROUNDED:
				st["td"] += 1
			elif prev_mode == PlayerBird.Mode.GROUNDED and p.mode == PlayerBird.Mode.FLYING:
				if p._run_v == Vector3.ZERO and p.model.velocity.y > 0.1:
					st["launch"] += 1
				else:
					st["run_off"] += 1
			if p.mode == PlayerBird.Mode.STUNNED:
				st["stun"] += 1
		prev_mode = p.mode
	var out := st.duplicate()
	out["ticks"] = i
	out["v_min"] = pr.v_min
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r6_random_play_near_the_ground() -> void:
	var tot := {"td": 0, "grounded_ticks": 0}
	for sp in S3:
		for seed_v in [11, 12]:
			var r: Dictionary = await _random_play(sp, seed_v, 40.0)
			var tag := "%s seed %d" % [sp, seed_v]
			_log("%s: ticks %d, touchdowns %d, grounded ticks %d, launches %d, run-offs %d, stuns %d | rate %.1f deg/s, acc %.1f deg/s^2 (%s) | cam off body h %.6f v %.6f m | below ground %.4f m | GROUNDED off the floor %d | perched with airspeed %d | groundspeed max %.2f V_min | NaN %d | basis bad %d" % [
				tag, r["ticks"], r["td"], r["grounded_ticks"], r["launch"], r["run_off"], r["stun"],
				rad_to_deg(r["max_rate"]), rad_to_deg(r["max_acc"]), r["worst_where"], r["cam_h"], r["cam_v"],
				r["below"], r["ground_bad"], r["perched_as"], r["gs_max"], r["nan"], r["basis_bad"]])
			tot["td"] += int(r["td"])
			tot["grounded_ticks"] += int(r["grounded_ticks"])
			eq(r["nan"], 0, "%s: no NaN" % tag)
			eq(r["basis_bad"], 0, "%s: rig pure yaw, unit scale, origin basis identity" % tag)
			lt(rad_to_deg(r["max_rate"]), 240.0 + 0.01, "%s: node yaw rate <= 240 deg/s" % tag)
			lt(rad_to_deg(r["max_acc"]), 720.0 + 0.5, "%s: node yaw accel <= 720 deg/s^2 (%s)" % [tag, r["worst_where"]])
			lt(float(r["cam_h"]), 0.001, "%s: camera horizontally on the body (m)" % tag)
			lt(float(r["cam_v"]), 0.001, "%s: camera = body + heave_offset vertically (m)" % tag)
			lt(float(r["below"]), 0.002, "%s: the body never sinks into the ground (m)" % tag)
			eq(r["ground_bad"], 0, "%s: GROUNDED only standing on a floor" % tag)
			eq(r["perched_as"], 0, "%s: perched / grounded telemetry reports airspeed 0" % tag)
			lt(float(r["gs_max"]), 1.3, "%s: the run-out never runs faster than the touchdown speed (x V_min)" % tag)
	gt(tot["td"], 3, "random play touched down several times (%d)" % tot["td"])


# --- 3b. the touchdowns flares actually produce (G4's scenarios) ----------------
## G4 asserts only "no stun" and "lands within 20 s" for flares near the ground;
## G1 measures the view's per-tick velocity change only for its own gentle set-up.
## Here: G4's grid, the camera's worst per-tick velocity change within 0.3 s of
## the touchdown, against the speed just before it (G1's 0.45 bound).
func _flare_td(sp: StringName, twist: float, h_spans: float) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
	var st := {"flare_t": -1.0, "td": -1, "v_td": 0.0, "vn_td": 0.0, "worst": 0.0, "lastv": Vector3.INF,
		"last": Vector3.INF, "prev_v": Vector3.ZERO, "t": 0.0}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if float(st["flare_t"]) >= 0.0:
			var k := clampf((float(st["t"]) - float(st["flare_t"])) / 0.3, 0.0, 1.0)
			b.arms[0].twist = k * twist * DEG
			b.arms[1].twist = k * twist * DEG
	var n := 0
	while n < int(30.0 / DT) and (int(st["td"]) < 0 or n < int(st["td"]) + 30):
		st["t"] = n * DT
		fx.step()
		n += 1
		if float(st["flare_t"]) < 0.0 and p.model.position.y - pr.r_body < h_spans * pr.span:
			st["flare_t"] = n * DT
		var c := p.camera.global_position
		if st["last"] != Vector3.INF:
			var v: Vector3 = (c - st["last"]) / DT
			if st["lastv"] != Vector3.INF and int(st["td"]) >= 0 and n <= int(st["td"]) + 22:
				st["worst"] = maxf(st["worst"], (v - st["lastv"]).length())
			st["lastv"] = v
		st["last"] = c
		if int(st["td"]) < 0 and p.mode == PlayerBird.Mode.GROUNDED:
			st["td"] = n
			var pv: Vector3 = st["prev_v"]
			st["v_td"] = pv.length()
			st["vn_td"] = -pv.y
			# the tick of the touchdown itself counts too
			var v2: Vector3 = st["lastv"]
			st["worst"] = 0.0
			st["pre_v"] = v2
		st["prev_v"] = p.model.velocity
	var out := {"landed": int(st["td"]) >= 0, "stuns": p.contacts["stun"], "v_td": st["v_td"], "vn_td": st["vn_td"],
		"ratio": float(st["worst"]) / maxf(float(st["v_td"]), 1e-3), "dv_perceived": float(st["worst"]) / p.origin.world_scale}
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r6_flare_touchdown_jolt() -> void:
	var over := 0
	var n := 0
	for sp in S3:
		for tw: float in [20.0, 30.0, 40.0]:
			for h: float in [0.3, 1.0, 2.0]:
				var r: Dictionary = await _flare_td(sp, tw, h)
				if bool(r["landed"]):
					n += 1
					if float(r["ratio"]) > 0.45:
						over += 1
				_log("flare %s +%d deg from %.1f spans: %s stuns %d, touchdown %.2f m/s (down %.2f), worst view dv/tick %.2f x (%.1f m/s perceived)" % [
					sp, int(tw), h, "landed" if r["landed"] else "NOT LANDED", r["stuns"], r["v_td"], r["vn_td"], r["ratio"], r["dv_perceived"]])
	_log("flare touchdowns over G1's 0.45 bound: %d of %d" % [over, n])
	gt(n, 0, "flares land")
	metric("flare_td_over_045", over)


# --- 5. in-game stall guard boundary -----------------------------------------------
func test_r6_stall_guard_heights_in_game() -> void:
	for sp in S3:
		var row: PackedStringArray = []
		for h: float in [3.0, 6.0, 12.0, 20.0, 40.0]:
			await _fx(sp)
			var p := fx.player
			var pr := p.model.params
			var cal := p.wing_input.calibration
			p.start_flying(Vector3(0, h + pr.r_body, 0), 0.0, 0.0)
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				b.synth(clampf(t / 0.2, 0.0, 1.0), 0.0, 1.0, cal)
			var st := {"stall_agl": -1.0, "max_agl": -INF}
			fx.on_tick = func(_i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				st["max_agl"] = maxf(st["max_agl"], pl.model.position.y - pr.r_body)
				if float(st["stall_agl"]) < 0.0 and pl.model.stalled:
					st["stall_agl"] = pl.model.position.y - pr.r_body
			fx.run(5.0)
			row.append("%s from %.0f m: %s, top %.1f m, stuns %d, mode %s" % [sp, h,
				("stalled at %.1f m" % st["stall_agl"]) if float(st["stall_agl"]) >= 0.0 else "no stall",
				st["max_agl"], p.contacts["stun"], p.mode_name()])
			fx.teardown()
			fx = null
			await get_tree().process_frame
		for l in row:
			_log(l)
	check(true, "reported")


# --- 6. determinism of a ground landing ---------------------------------------------
func _glide_land(sp: StringName) -> PackedFloat64Array:
	await _fx(sp)
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
	var out := PackedFloat64Array()
	for i in int(12.0 / DT):
		fx.step()
		if i % 8 == 0:
			out.append(p.model.position.x)
			out.append(p.model.position.y)
			out.append(p.model.position.z)
			out.append(p.camera.global_position.y)
			out.append(float(p.mode))
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_r6_ground_landing_is_deterministic() -> void:
	var a: PackedFloat64Array = await _glide_land(&"pigeon")
	var _other: PackedFloat64Array = await _glide_land(&"eagle")
	var b: PackedFloat64Array = await _glide_land(&"pigeon")
	var same := a.size() == b.size()
	var first_diff := -1
	if same:
		for k in a.size():
			if a[k] != b[k]:
				same = false
				first_diff = k
				break
	_log("ground landing determinism: %s (samples %d, first difference at %d)" % ["bit-identical" if same else "DIFFERS", a.size(), first_diff])
	check(same, "the same glide into the ground twice (after an unrelated flight) is bit-identical")


# --- 7. frame timing under ordinary frame-time jitter ------------------------------
## XRPoseSource.frame_timing divides each frame's pose change by the WALL-CLOCK
## time since the previous frame's first sample. OpenXR poses are predicted for
## each frame's display time, which advances by exactly one display period when
## no frame is dropped, while the wall clock at sample time jitters. Emulated as
## in WI-34 (injected engine clock), with no hitch: the poses advance exactly
## 1/72 s per frame, the clock by 1/72 s +- jitter. Compare with frame timing
## off (the tick's dt) and with no jitter.
func _xr_jitter_run(kind: int, jitter_ms: float, timing: bool, seed_v: int) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var lh := XRController3D.new()
	var rh := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(lh)
	origin.add_child(rh)
	add_child(origin)
	var src := XRPoseSource.new(origin, cam, lh, rh)
	src.assume_tracked = true
	src.frame_timing = timing
	var clock := {"frame": 0, "t": 0.0}
	src.clock = func() -> Vector2: return Vector2(float(clock["frame"]), float(clock["t"]))
	var wi := WingInput.new()
	wi.auto_calibrate = false
	var body := HumanPoseModel.new(3)
	var fr := PoseFrame.new()
	var truth := PoseFrame.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var dt := 1.0 / 72.0
	var out := {"onsets": 0, "flap_max": 0.0, "flap_sum": 0.0, "ticks": 0, "pd_min": INF, "pd_max": 0.0}
	var pose_t := 0.0
	# Wall clock of each sample: the frame's nominal time plus a jitter (the
	# main loop wakes a little early or late); poses at the display time.
	while pose_t < 12.0:
		pose_t += dt
		clock["frame"] = int(clock["frame"]) + 1
		clock["t"] = pose_t + rng.randf_range(-jitter_ms, jitter_ms) / 1000.0
		body.set_airplane()
		if kind == 0:
			var e := deg_to_rad(25.0) * sin(TAU * 0.25 * pose_t)
			body.arms[0].dihedral = e
			body.arms[1].dihedral = e
		else:
			ScriptedPoseSource.flap(body, pose_t, 45.0, 1.0)
		body.frame(truth)
		cam.transform = truth.head
		lh.transform = truth.left
		rh.transform = truth.right
		src.sample(fr, dt)
		if fr.pose_dt > 0.0:
			out["pd_min"] = minf(out["pd_min"], fr.pose_dt)
			out["pd_max"] = maxf(out["pd_max"], fr.pose_dt)
		var w := wi.update(fr, dt)
		if w.onset_l or w.onset_r:
			out["onsets"] += 1
		out["flap_max"] = maxf(out["flap_max"], maxf(w.flap_l, w.flap_r))
		out["flap_sum"] += 0.5 * (w.flap_l + w.flap_r)
		out["ticks"] += 1
	origin.queue_free()
	return out


func test_r6_frame_timing_under_frame_jitter() -> void:
	var ref_str: Dictionary = _xr_jitter_run(1, 0.0, false, 1)
	var ref_slow: Dictionary = _xr_jitter_run(0, 0.0, false, 1)
	var m_ref := float(ref_str["flap_sum"]) / float(ref_str["ticks"])
	_log("frame jitter: reference (frame timing off, no jitter): strokes %d onsets, mean effort %.4f; slow sweeps %d onsets" % [
		ref_str["onsets"], m_ref, ref_slow["onsets"]])
	var worst := 0.0
	var slow_on := 0
	for j: float in [0.0, 0.5, 1.0, 2.0, 3.0, 4.0]:
		for sd in [1, 2, 3]:
			var s: Dictionary = _xr_jitter_run(1, j, true, sd)
			var sl: Dictionary = _xr_jitter_run(0, j, true, sd)
			var m := float(s["flap_sum"]) / float(s["ticks"])
			slow_on += int(sl["onsets"])
			if j <= 2.0:
				worst = maxf(worst, absf(m / m_ref - 1.0))
			_log("  jitter +-%.1f ms seed %d: strokes %d onsets, effort x%.3f of the reference; slow sweeps %d onsets, flap max %.3f; pose_dt %.1f-%.1f ms" % [
				j, sd, s["onsets"], m / m_ref, sl["onsets"], sl["flap_max"], 1000.0 * float(s["pd_min"]), 1000.0 * float(s["pd_max"])])
	metric("effort_dev_upto_2ms", worst)
	lt(worst, 0.1, "stroke effort within 10 %% of the reference under <= 2 ms frame jitter (worst %.3f)" % worst)
	eq(slow_on, 0, "slow sweeps give no onset under frame jitter")
