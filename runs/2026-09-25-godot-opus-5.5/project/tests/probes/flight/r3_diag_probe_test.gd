extends TestCase
## Verifier (round 3) diagnostics behind r3_experience_probe's failures:
## traces, no pass/fail beyond sanity. Output: artifacts/flight/verify/r3/diag_*.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const WW := preload("res://tests/probes/flight/r3_wind_world.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

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
	var path := Paths.artifacts("flight").path_join("verify/r3/diag_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _setup_wind(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	var w := WW.new()
	if world_setup.is_valid():
		world_setup.call(w)
	fx.world = w
	add_child(w)
	fx.body = HumanPoseModel.new(1)
	var f := fx
	f.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
	f.src = ScriptedPoseSource.new(f.body, func(tick: int, t: float, b: HumanPoseModel) -> void:
		f.driver.call(tick, t, b))
	f.player = PLAYER.instantiate() as PlayerBird
	f.player.auto_process = false
	f.player.use_settings = false
	f.player.drive_world_scale = true
	f.player.default_source = &"none"
	f.player.mass = FlightParams.species_mass(sp)
	add_child(f.player)
	f.player.auto_calibrate = false
	f.player.set_pose_source(f.src)
	f._connect()
	await get_tree().physics_frame
	await get_tree().physics_frame
	return fx


func test_diag_vertical_impact() -> void:
	check(true, "diagnostic trace (no pass/fail)")
	for sp in [&"sparrow", &"pigeon"]:
		fx = FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		var pr := p.model.params
		var v := 0.97 * pr.v_max
		var start := Vector3(0, pr.r_body + v * 0.6 + 0.01, 0)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, -v, 0), 0.0)
		fx.driver = fx.synth(0.0, 0.0, 0.0)
		p.debug_contacts = true
		_log("== %s vertical V_max impact: v_c %.2f v_stun %.2f v_min %.2f r_body %.3f" % [sp, pr.v_c, maxf(0.35 * pr.v_c, 2.0), pr.v_min, pr.r_body])
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var agl := pl.model.position.y - pl.model.params.r_body
			if agl < 3.0 and tick < 80:
				_log("  t=%.3f y-r=%.3f v=%s tucked=%s ext=%.2f mode=%s contacts=%s" % [tick * DT, agl, pl.model.velocity.snapped(Vector3.ONE * 0.01),
					str(pl.wing_state().tucked), pl.wing_state().ext_l, pl.mode_name(), str(pl.contacts)])
		fx.run(1.2)
		p.debug_contacts = false
		fx.teardown()
		fx = null


func test_diag_perch_headwind() -> void:
	check(true, "diagnostic trace (no pass/fail)")
	var perch_at := Vector3(0, 20, -10)
	for c in [[&"sparrow", Vector3(0, 0, 2.64)], [&"sparrow", Vector3(2.64, 0, 0)], [&"pigeon", Vector3(2.64, 0, 0)],
			[&"sparrow", Vector3(0, 0, 1.5)], [&"sparrow", Vector3(1.5, 0, 0)], [&"pigeon", Vector3(1.5, 0, 0)]]:
		var sp: StringName = c[0]
		var wv: Vector3 = c[1]
		await _setup_wind(sp, func(w: Variant) -> void:
			w.add_perch(perch_at, Vector3.FORWARD, 10.0, 0.015, 1.0)
			w.uniform_wind = wv)
		var p := fx.player
		var pr := p.model.params
		var vcap := 0.8 * pr.v_min
		var target := perch_at + Vector3.UP * pr.r_body
		var start := target + Vector3(0, 0.3 * pr.span, 6.0 * pr.span)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 0, -1.2 * vcap) + wv, 0.0)
		fx.driver = fx.synth(0.3, 0.0, 1.0)
		_log("== %s perch approach, wind %s, V_cap %.2f span %.3f" % [sp, wv, vcap, pr.span])
		var st := {"dmin": INF, "t": -1.0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var d: Vector3 = pl.model.position - target
			if d.length() < float(st["dmin"]):
				st["dmin"] = d.length()
			if st["t"] < 0.0 and pl.mode == PlayerBird.Mode.PERCHED:
				st["t"] = tick * DT
			if tick % 18 == 0:
				_log("  t=%.2f rel=(%.2f,%.2f,%.2f) spans air %.2f gnd %.2f vz %.2f hdg %.0f mode %s cand %s cdist %.2f assist %s" % [
					tick * DT, d.x / pr.span, d.y / pr.span, d.z / pr.span, pl.model.airspeed(), Vector2(pl.model.velocity.x, pl.model.velocity.z).length(),
					pl.model.velocity.y, rad_to_deg(pl.model.heading()), pl.mode_name(), str(pl.perch_candidate != null), pl.perch_candidate_dist,
					pl.env.accel.snapped(Vector3.ONE * 0.01)])
		fx.run(6.0)
		_log("  -> min distance to the grip point %.2f spans, perched at %.2f" % [float(st["dmin"]) / pr.span, st["t"]])
		fx.teardown()
		fx = null


func test_diag_stun_turn() -> void:
	check(true, "diagnostic trace (no pass/fail)")
	for c in [[&"sparrow", 90.0], [&"sparrow", 40.0], [&"pigeon", 90.0]]:
		var sp: StringName = c[0]
		var inc: float = c[1]
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -20), Vector3(200, 60, 1.0)))
		var p := fx.player
		var pr := p.model.params
		var yaw := (90.0 - inc) * DEG
		var start := Vector3(0, 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
		start.x += pr.v_c * 0.8 * cos(inc * DEG)
		p.start_flying(start, yaw, 0.0)
		p.debug_contacts = true
		_log("== %s wall at incidence %.0f" % [sp, inc])
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var t := tick * DT
			if t > 0.6 and t < 2.9 and tick % 4 == 0:
				_log("  t=%.3f mode %s rig_yaw %.1f hdg %.1f vel_hdg %.1f rate %.0f acc %.0f turnT %.2f bank %.1f v %s" % [
					t, pl.mode_name(), rad_to_deg(pl.rig_yaw), rad_to_deg(pl.model.heading()),
					rad_to_deg(FlightMath.yaw_of(pl.model.velocity)) if Vector2(pl.model.velocity.x, pl.model.velocity.z).length() > 0.1 else 0.0,
					rad_to_deg(pl.rig_yaw_rate), rad_to_deg(pl.rig_yaw_accel), pl._turn_T, rad_to_deg(pl.model.phi),
					pl.model.velocity.snapped(Vector3.ONE * 0.1)])
		fx.run(3.0)
		p.debug_contacts = false
		fx.teardown()
		fx = null


func test_diag_gust_front() -> void:
	check(true, "diagnostic trace (no pass/fail)")
	for ramp in [0.5, 2.0, 5.0]:
		await _setup_wind(&"sparrow", func(w: Variant) -> void:
			w.step_wind = Vector3(2.64, 0, 0)
			w.step_t0 = 3.0
			w.step_ramp = ramp)
		var p := fx.player
		p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
		var st := {"acc": 0.0, "at": 0.0, "rate": 0.0, "limited0": 0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			f.world.clock += DT
			var pl: PlayerBird = f.player
			if tick * DT < 3.0:
				st["limited0"] = pl.rig_limited_ticks
				return
			if absf(pl.rig_yaw_accel) > float(st["acc"]):
				st["acc"] = absf(pl.rig_yaw_accel)
				st["at"] = tick * DT
			st["rate"] = maxf(st["rate"], absf(pl.rig_yaw_rate))
		fx.run(12.0)
		_log("== sparrow crosswind gust front 2.64 m/s over %.1f s: rig yaw accel max %.0f deg/s2 at t=%.2f, rate max %.1f deg/s, rig-limited ticks %d" % [
			ramp, rad_to_deg(st["acc"]), st["at"], rad_to_deg(st["rate"]), p.rig_limited_ticks - int(st["limited0"])])
		fx.teardown()
		fx = null
