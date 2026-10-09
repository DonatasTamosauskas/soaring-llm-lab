extends TestCase
## Dev tool (not in the flight suite): records the raw body motion and the
## model's own flap acceleration for every heave scenario the verifiers and
## PB-08b fly, so camera-heave designs can be compared offline on the exact
## same flights (the heave never feeds back into the physics).
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_heave_dump
## Output: artifacts/flight/dev/heave_data/<run>.csv

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const BC := preload("res://tests/unit/flight/bot_course.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX
var jit := 0.4
var pause_p := 0.35


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


class Rec:
	extends RefCounted
	var rows := PackedStringArray()
	var imp_prev := Vector3.ZERO
	var have := false

	func push(p: PlayerBird) -> void:
		var m := p.model
		var imp := m.flap_impulse
		var af := Vector3.ZERO
		if have:
			af = (imp - imp_prev) / m.params.mass / DT
		imp_prev = imp
		have = true
		var ws := p.wing_state()
		rows.append("%.5f,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.4f,%.5f,%.5f,%.4f,%.5f,%.5f,%.5f,%.4f,%.4f,%.5f,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
			p.tick_count * DT, 1 if p.mode == PlayerBird.Mode.FLYING else 0, maxf(p.origin.world_scale, 1e-4),
			m.position.y, m.velocity.y, p.camera.global_position.y, p._heave_off,
			(1 if ws.onset_l else 0) + (2 if ws.onset_r else 0), ws.stroke_period,
			af.y, af.length(), m.airspeed(), m.alpha, m.params.span * p.tuning.heave_clamp_spans,
			m.params.mass, 0.5 * (ws.flap_l + ws.flap_r), m.g_load,
			ws.dihedral_l, ws.dihedral_r, ws.omega_l, ws.omega_r, ws.stroke_phase_l, ws.stroke_phase_r,
			0.5 * (ws.up_l + ws.up_r), ws.flapping])

	func save(path: String) -> void:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_line("t,flying,ws,body,vy,cam,off,onset,period,afy,afn,V,alpha,lim,mass,flap,g,dih_l,dih_r,om_l,om_r,ph_l,ph_r,up,flapping")
		for r in rows:
			f.store_line(r)


func _out(tag: String) -> String:
	return Paths.artifacts("flight").path_join("dev/heave_data/%s.csv" % tag)


func _irregular(seed: int, secs: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array = []
	var t := 1.5
	while t < secs:
		var dur := rng.randf_range(1.0 - jit, 1.0 + jit)
		out.append([t, dur, rng.randf_range(32.0, 45.0) if jit < 0.3 else rng.randf_range(25.0, 50.0)])
		t += dur
		if rng.randf() < pause_p:
			t += rng.randf_range(0.2, 1.5)
	return out


## The round-2 verifier's scenarios, verbatim.
func _fly_v(sp: StringName, kind: String, secs: float, seed := 1, grow := false) -> Rec:
	fx = FX.new(self)
	await fx.setup(sp)
	var f := fx
	var rec := Rec.new()
	var sched := _irregular(seed, secs)
	f.player.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	var st := {"phase": 0.0}
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		match kind:
			"tempo":
				var hz := 1.2
				if t > 6.0:
					hz = 0.8
				if t > 12.0:
					hz = 1.6
				if t > 18.0:
					hz = 1.0
				st["phase"] += hz * DT
				ScriptedPoseSource.flap(b, float(st["phase"]), 40.0, 1.0)
			"irregular":
				for s in sched:
					var t0: float = s[0]
					var dur: float = s[1]
					if t >= t0 and t < t0 + dur:
						ScriptedPoseSource.flap(b, (t - t0) / dur, float(s[2]), 1.0)
				b.humanize(DT)
			"flapflapglide":
				var tt := fmod(t, 2.7)
				if tt < 2.0:
					ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
				b.humanize(DT)
			"onewing":
				var tt := fmod(t, 3.0)
				if tt < 1.0:
					ScriptedPoseSource.flap(b, tt, 40.0, 1.0, -1 if int(t / 3.0) % 2 == 0 else 1)
				elif tt >= 1.5 and tt < 2.5:
					ScriptedPoseSource.flap(b, tt - 1.5, 40.0, 1.0)
				b.humanize(DT)
			"steady":
				ScriptedPoseSource.flap(b, t, 35.0, 1.0)
		for a in b.arms:
			a.twist = -12.0 * DEG
	var sparrow_m := FlightParams.species_mass(&"sparrow")
	var eagle_m := FlightParams.species_mass(&"eagle")
	f.on_tick = func(tick: int, fix: Variant) -> void:
		if grow:
			var k := clampf((tick * DT - 5.0) / 20.0, 0.0, 1.0)
			fix.player.mass = sparrow_m * pow(eagle_m / sparrow_m, k)
		rec.push(fix.player)
	f.run(secs)
	fx.teardown()
	fx = null
	return rec


## heave_test.gd's PB-08b scenarios, verbatim.
func _fly_pb(sp: StringName, kind: String, secs: float, seed := 7) -> Rec:
	fx = FX.new(self)
	await fx.setup(sp)
	var f := fx
	var rec := Rec.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var sched: Array = []
	var t0 := 2.0
	while t0 < secs:
		var hz := rng.randf_range(0.7, 1.5)
		var n := rng.randi_range(1, 5)
		sched.append([t0, n, hz, rng.randf_range(25.0, 50.0)])
		t0 += n / hz + rng.randf_range(0.3, 3.0)
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		match kind:
			"bursts":
				var tt := fmod(t, 5.0)
				if tt < 3.0:
					ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
				for a in b.arms:
					a.twist = -10.0 * DEG
			"irregular":
				for s in sched:
					var dur: float = float(s[1]) / float(s[2])
					if t >= s[0] and t < float(s[0]) + dur:
						ScriptedPoseSource.flap(b, t - float(s[0]), s[3], s[2])
				for a in b.arms:
					a.twist = -10.0 * DEG
				b.humanize(DT)
			"single":
				var ts := fmod(t, 2.5)
				if ts < 1.0:
					ScriptedPoseSource.flap(b, ts, 40.0, 1.0)
				b.humanize(DT)
			"cruise":
				ScriptedPoseSource.flap(b, t, 25.0, 1.0)
				for a in b.arms:
					a.twist = -20.0 * DEG
			"headbob":
				ScriptedPoseSource.flap(b, t, 25.0, 1.0)
				for a in b.arms:
					a.twist = -20.0 * DEG
				b.room_offset = Vector3(0.0, 0.05 * sin(TAU * 1.3 * t), 0.0)
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		rec.push(fix.player)
	f.run(secs)
	fx.teardown()
	fx = null
	return rec


func _bot(sp: StringName, novice: bool, seed: int, to_window := false) -> Rec:
	fx = FX.new(self)
	var b := BC.new(fx, sp)
	if novice:
		await b.setup(true, 1, seed)
	else:
		await b.setup()
	var rec := Rec.new()
	fx.on_tick = func(_tick: int, fix: Variant) -> void:
		rec.push(fix.player)
	b.fly(to_window)
	fx.teardown()
	fx = null
	return rec


func test_dump() -> void:
	var only := String(Paths.user_args().get("only", ""))
	# --set=heldout: other seeds, never used while tuning (generalisation).
	var held := String(Paths.user_args().get("set", "")) == "heldout"
	var sub := "heave_data_heldout" if held else "heave_data"
	var n := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var jobs: Array = []
		var o := 20 if held else 0
		for r in [["tempo", 1], ["flapflapglide", 1], ["onewing", 1], ["steady", 1],
				["irregular", 11 + o], ["irregular", 12 + o], ["irregular", 13 + o]]:
			jobs.append(["v", r[0], r[1], 0.4, 0.35])
		for cfg in [[0.1, 0.0], [0.2, 0.0], [0.3, 0.0], [0.1, 0.35], [0.2, 0.35]]:
			for seed in [21 + o, 22 + o, 23 + o]:
				jobs.append(["v", "irregular", seed, cfg[0], cfg[1]])
		for k in ["bursts", "irregular", "single"]:
			jobs.append(["pb", k, 7 + o, 0.0, 0.0])
		jobs.append(["pbc", "cruise", 7, 0.0, 0.0])
		jobs.append(["pbc", "headbob", 7, 0.0, 0.0])
		for seed in [1 + o, 2 + o, 3 + o]:
			jobs.append(["nov", "novice", seed, 0.0, 0.0])
		jobs.append(["b1", "course", 21 + o, 0.0, 0.0])
		# B2's flights (novice, to the window), seeds 1-10.
		for seed in range(1, 11):
			jobs.append(["novw", "novice_window", seed, 0.0, 0.0])
		for j in jobs:
			var tag := "%s_%s_%s_s%d" % [sp, j[0], j[1], j[2]]
			if j[0] == "v" and j[1] == "irregular" and int(j[2]) >= 21 and int(j[2]) != 31 and int(j[2]) != 32 and int(j[2]) != 33:
				tag = "%s_sweep_j%d_p%d_s%d" % [sp, int(float(j[3]) * 100), int(float(j[4]) * 100), j[2]]
			if not only.is_empty() and not tag.contains(only):
				continue
			var rec: Rec
			match j[0]:
				"v":
					jit = j[3]
					pause_p = j[4]
					rec = await _fly_v(sp, j[1], 30.0, j[2])
				"pb":
					rec = await _fly_pb(sp, j[1], 20.0, j[2])
				"pbc":
					rec = await _fly_pb(sp, j[1], 14.0, j[2])
				"nov":
					rec = await _bot(sp, true, j[2])
				"b1":
					rec = await _bot(sp, false, j[2])
				"novw":
					rec = await _bot(sp, true, j[2], true)
			rec.save(_out(tag).replace("heave_data/", sub + "/"))
			n += 1
	if only.is_empty() or "grow".contains(only):
		jit = 0.4
		pause_p = 0.35
		(await _fly_v(&"sparrow", "steady", 30.0, 1, true)).save(_out("grow_steady").replace("heave_data/", sub + "/"))
		(await _fly_v(&"sparrow", "irregular", 30.0, 32 if held else 12, true)).save(_out("grow_irregular_s12").replace("heave_data/", sub + "/"))
		n += 2
	print("[flight] heave dump: %d runs" % n)
	gt(n, 0, "runs dumped")
