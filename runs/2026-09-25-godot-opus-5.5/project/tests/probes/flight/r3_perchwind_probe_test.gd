extends TestCase
## Verifier (round 3): perching in wind, with controls. The same slow
## player-like approach (6 spans back, 0.3 span above, 1.2 V_cap airspeed,
## wrists up 0.3) in still air vs a 1.5 m/s wind (the real world's breeze at
## perch height 5-15 m is ~1.2-1.9 m/s: wind.gd k = 0.4 + 0.02 y), and a
## cruise-speed approach (V_c, 10 spans back) where the player flares with
## pitch +0.6. Head, cross (both sides) and tail wind. Sparrow (the starting
## bird), pigeon, eagle. Output: artifacts/flight/verify/r3/perchwind_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const WW := preload("res://tests/probes/flight/r3_wind_world.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 20, -10)

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
	var path := Paths.artifacts("flight").path_join("verify/r3/perchwind_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _setup_wind(sp: StringName, wind: Vector3) -> FX:
	fx = FX.new(self)
	var w := WW.new()
	w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.015, 1.0)
	w.uniform_wind = wind
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


## Returns the time to perch (s) or -1.
func _approach(sp: StringName, wind: Vector3, back: float, air: float, pitch: float) -> Array:
	await _setup_wind(sp, wind)
	var p := fx.player
	var pr := p.model.params
	var target := PERCH + Vector3.UP * pr.r_body
	var start := target + Vector3(0, 0.3 * pr.span, back * pr.span)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, 0, -air) + wind, 0.0)
	fx.driver = fx.synth(pitch, 0.0, 1.0)
	var st := {"t": -1.0, "dmin": INF}
	var t0 := fx.ticks
	fx.reset_events()
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["dmin"] = minf(st["dmin"], pl.model.position.distance_to(target))
		if st["t"] < 0.0 and pl.mode == PlayerBird.Mode.PERCHED:
			st["t"] = (tick - t0) * DT
	fx.run(8.0)
	var out := [float(st["t"]), float(st["dmin"]) / pr.span, fx.events["collided"]]
	fx.teardown()
	fx = null
	return out


func test_r3_perch_wind_controls() -> void:
	var winds := [[Vector3.ZERO, "still"], [Vector3(0, 0, 1.5), "head 1.5"], [Vector3(1.5, 0, 0), "cross+ 1.5"],
		[Vector3(-1.5, 0, 0), "cross- 1.5"], [Vector3(0, 0, -1.5), "tail 1.5"]]
	var fails := {}
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		var vmin := FlightParams.derive(FlightParams.species_mass(sp)).v_min
		var vc := FlightParams.derive(FlightParams.species_mass(sp)).v_c
		for kind in [["slow", 6.0, 1.2 * 0.8 * vmin, 0.3], ["cruise+flare", 10.0, vc, 0.6]]:
			var row := PackedStringArray()
			for wd in winds:
				var r: Array = await _approach(sp, wd[0], kind[1], kind[2], kind[3])
				row.append("%s: %s" % [wd[1], ("%.2f s" % r[0]) if r[0] >= 0.0 else "MISS (closest %.2f spans)" % r[1]])
				metric("perch_%s_%s_%s" % [sp, kind[0], String(wd[1]).replace(" ", "_")], r)
				# cruise+flare is info only: pitching up at cruise balloons over
				# the perch even in still air (the physics the brief asks for).
				if kind[0] != "slow":
					continue
				if wd[1] == "still":
					check(r[0] >= 0.0, "%s %s approach in still air perches (control)" % [sp, kind[0]])
				elif not String(wd[1]).begins_with("tail"):
					if r[0] < 0.0:
						fails["%s %s %s" % [sp, kind[0], wd[1]]] = r[1]
			_log("[perch wind] %-7s %-12s | %s" % [sp, kind[0], " | ".join(row)])
	_log("[perch wind] head/cross-wind misses: %s" % str(fails))
	eq(fails.size(), 0, "every slow approach into a 1.5 m/s head or cross wind perches (misses: %s)" % str(fails.keys()))


## Sweep of approach geometries per wind: how many of a broad set of
## reasonable slow approaches perch (success share), still air vs wind.
func test_r3_perch_wind_sweep() -> void:
	var winds := [[Vector3.ZERO, "still"], [Vector3(0, 0, 1.0), "head 1.0"], [Vector3(0, 0, 1.5), "head 1.5"],
		[Vector3(1.5, 0, 0), "cross 1.5"], [Vector3(0, 0, -1.5), "tail 1.5"]]
	for sp in [&"sparrow", &"pigeon"]:
		var pr := FlightParams.derive(FlightParams.species_mass(sp))
		var vcap := 0.8 * pr.v_min
		var shares := {}
		for wd in winds:
			var ok := 0
			var n := 0
			for back in [2.0, 4.0, 6.0]:
				for up in [0.0, 0.3, 1.0]:
					for air in [0.9 * vcap, 1.2 * vcap, 1.0 * pr.v_min]:
						for pitch in [0.0, 0.3]:
							var r: Array = await _approach(sp, wd[0], back, air, pitch)
							n += 1
							if float(r[0]) >= 0.0:
								ok += 1
			shares[wd[1]] = float(ok) / n
		_log("[perch sweep] %s success share over 54 slow approaches: %s" % [sp, str(shares)])
		metric("perch_sweep_%s" % sp, shares)
		if sp == &"sparrow":
			gt(float(shares["head 1.5"]), 0.8 * float(shares["still"]), "sparrow: a 1.5 m/s headwind keeps >= 80 % of still-air perching success")
			gt(float(shares["cross 1.5"]), 0.8 * float(shares["still"]), "sparrow: a 1.5 m/s crosswind keeps >= 80 % of still-air perching success")


## Sparrow crosswind degradation curve (info).
func test_r3_perch_sparrow_crosswind_curve() -> void:
	var pr := FlightParams.derive(FlightParams.species_mass(&"sparrow"))
	var vcap := 0.8 * pr.v_min
	var curve := {}
	for cw in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var ok := 0
		var n := 0
		for back in [2.0, 4.0, 6.0]:
			for up in [0.0, 0.3, 1.0]:
				for air in [0.9 * vcap, 1.2 * vcap, 1.0 * pr.v_min]:
					for pitch in [0.0, 0.3]:
						var r: Array = await _approach(&"sparrow", Vector3(cw, 0, 0), back, air, pitch)
						n += 1
						if float(r[0]) >= 0.0:
							ok += 1
		curve["%.2f" % cw] = float(ok) / n
	_log("[perch sweep] sparrow success share vs crosswind (m/s): %s" % str(curve))
	metric("perch_sparrow_crosswind_curve", curve)
	check(true, "curve recorded (info)")


## A skilled player crabs: heading into the wind so the ground track points
## at the perch. Sparrow, 1.0 and 1.5 m/s crosswind (both sides).
func _approach_crab(sp: StringName, wind: Vector3, back: float, air: float, pitch: float) -> Array:
	await _setup_wind(sp, wind)
	var p := fx.player
	var pr := p.model.params
	var target := PERCH + Vector3.UP * pr.r_body
	var start := target + Vector3(0, 0.3 * pr.span, back * pr.span)
	# Air vector a with a + wind parallel to -Z: a.x = -wind.x.
	var ax := -wind.x
	var az := -sqrt(maxf(air * air - ax * ax, 0.01))
	var yaw := FlightMath.yaw_of(Vector3(ax, 0, az))
	p.start_flying(start, yaw, 0.0)
	p.model.reset(start, Vector3(ax, 0, az) + wind, yaw)
	fx.driver = fx.synth(pitch, 0.0, 1.0)
	var st := {"t": -1.0}
	var t0 := fx.ticks
	fx.on_tick = func(tick: int, f: Variant) -> void:
		if st["t"] < 0.0 and f.player.mode == PlayerBird.Mode.PERCHED:
			st["t"] = (tick - t0) * DT
	fx.run(6.0)
	var out := [float(st["t"])]
	fx.teardown()
	fx = null
	return out


func test_r3_perch_sparrow_crab() -> void:
	var pr := FlightParams.derive(FlightParams.species_mass(&"sparrow"))
	var vcap := 0.8 * pr.v_min
	var res := {}
	for cw in [0.0, 1.0, -1.0, 1.5, -1.5]:
		var ok := 0
		var n := 0
		for back in [2.0, 4.0, 6.0]:
			for up in [0.0, 0.3, 1.0]:
				for air in [0.9 * vcap, 1.2 * vcap, 1.0 * pr.v_min]:
					for pitch in [0.0, 0.3]:
						var r: Array = await _approach_crab(&"sparrow", Vector3(cw, 0, 0), back, air, pitch)
						n += 1
						if float(r[0]) >= 0.0:
							ok += 1
		res["%.1f" % cw] = float(ok) / n
	_log("[perch sweep] sparrow CRABBED approaches, success share vs crosswind (m/s): %s" % str(res))
	metric("perch_sparrow_crab", res)
	gt(float(res["1.5"]), 0.8 * float(res["0.0"]), "sparrow crabbed approach in a 1.5 m/s crosswind keeps >= 80 % of still-air success")
