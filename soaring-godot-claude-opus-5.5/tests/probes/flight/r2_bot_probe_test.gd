extends TestCase
## Verifier probe (round 2, flight): F12 bot course on the CURRENT code
## (wing_input.gd changed after the builder's full sweep) with seeds the
## builder never used (101-105), species outside the builder's sweep
## (swallow, hawk) and non-ladder masses (growth is continuous in the game:
## 0.15 kg, 1.0 kg). Pass = window within 60% of its tolerance, perched on
## the target, 0 stuns, 0 frame hits, comfort monitor clean.
## Output: artifacts/flight/verify/r2/bot_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const BC := preload("res://tests/unit/flight/bot_course.gd")

var _fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_each() -> void:
	if _fx != null:
		_fx.teardown()
		_fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r2/bot_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


## BotCourse.setup with an arbitrary mass (species id only names the fixture).
func _setup_mass(b: BC, mass: float, seed: int) -> void:
	b.course = FlightCourse.new(mass)
	var c := b.course
	await _fx.setup(&"sparrow", func(w: Variant) -> void:
		c.build(w, false, false))
	var p := _fx.player
	p.mass = mass
	b.pilot = FlightAutopilot.new(p.model.params, c)
	var pl := p
	b.bot = BotPoseSource.new(b.pilot, func() -> Dictionary:
		return {"pos": pl.model.position, "vel": pl.model.velocity, "airspeed": pl.model.airspeed()}, 21)
	b.bot.calibration = p.wing_input.calibration
	b.bot.body.set_seed(seed)
	b.bot.rng.seed = seed
	b.bot.set_novice(false)
	p.set_pose_source(b.bot)
	p.start_flying(c.start.origin, 0.0, 0.0)
	b.limit_s = 1.6 * c.length_to_perch() / c.v_c + 10.0


func _run(tag: String, mass: float, seed: int) -> bool:
	_fx = FX.new(self)
	var b := BC.new(_fx, &"sparrow")
	await _setup_mass(b, mass, seed)
	b.fly()
	var ok: bool = b.window_ok(0.6) and b.perched_on_target and _fx.player.contacts["stun"] == 0 and _fx.player.contacts["slide"] == 0
	var cf: Dictionary = _fx.comfort
	var comfort_ok: bool = cf["basis_bad"] == 0 and cf["scale_bad"] == 0 and cf["origin_bad"] == 0 \
		and rad_to_deg(cf["max_rate"]) <= 240.001 and rad_to_deg(cf["max_accel"]) <= 756.0 \
		and float(cf["cam_jerk"]) <= 1.4 * float(cf["body_jerk"]) + 0.05
	_log("%-9s seed %3d: %s window worst %.2f, perched %s at %.1f s (limit %.0f), stuns %d, slides %d, brushes %d; comfort %s (yaw rate %.0f, accel %.0f, view jerk %.2f vs body %.2f cm)" % [
		tag, seed, "PASS" if ok else "FAIL", b.worst_window_frac(), b.perched_on_target, b.perched_t, b.limit_s,
		_fx.player.contacts["stun"], _fx.player.contacts["slide"], _fx.player.contacts["brush"], "ok" if comfort_ok else "BAD",
		rad_to_deg(cf["max_rate"]), rad_to_deg(cf["max_accel"]), cf["cam_jerk"], cf["body_jerk"]])
	check(comfort_ok, "%s seed %d: comfort monitor clean" % [tag, seed])
	_fx.teardown()
	_fx = null
	return ok


func test_r2_bot_new_seeds_and_sizes() -> void:
	var runs: Array = []
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		for seed in [101, 102, 103, 104, 105]:
			runs.append([String(sp), FlightParams.species_mass(sp), seed])
	for sp in [&"swallow", &"hawk"]:
		for seed in [101, 102]:
			runs.append([String(sp), FlightParams.species_mass(sp), seed])
	for mass in [0.15, 1.0]:
		for seed in [101, 102]:
			runs.append(["m%.2f" % mass, mass, seed])
	var ok := 0
	var fails := PackedStringArray()
	for r in runs:
		var good: bool = await _run(r[0], r[1], r[2])
		if good:
			ok += 1
		else:
			fails.append("%s s%d" % [r[0], r[2]])
	_log("bot probe: %d / %d complete; failures: %s" % [ok, runs.size(), ", ".join(fails)])
	metric("bot_probe_ok", [ok, runs.size()])
	gt(float(ok) / runs.size(), 0.95 - 1e-6, "B1 completion >= 95%% on new seeds / sizes (failures: %s)" % ", ".join(fails))
