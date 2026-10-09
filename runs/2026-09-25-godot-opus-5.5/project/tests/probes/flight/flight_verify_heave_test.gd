extends TestCase
## Verifier probe (round 1, flight): perceived camera heave (vertical bob) in
## the first seconds after the player STARTS flapping from a glide (the
## builder's PB-08 only measures 4-8 s and 8-12 s in). Ripple = half
## peak-to-peak of y minus its centred 1-period moving average, divided by
## world_scale (what the eye perceives), camera vs raw body.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0

var fx: FX
var _lines := PackedStringArray()


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("heave_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


static func _ripple(ys: PackedFloat64Array, i0: int, i1: int) -> float:
	var n := 36
	var lo := INF
	var hi := -INF
	for i in range(maxi(i0, n), mini(i1, ys.size() - n)):
		var m := 0.0
		for k in range(-n, n + 1):
			m += ys[i + k]
		m /= 2 * n + 1
		lo = minf(lo, ys[i] - m)
		hi = maxf(hi, ys[i] - m)
	return 0.5 * (hi - lo) if hi > lo else 0.0


## Half peak-to-peak of y minus a least-squares QUADRATIC over [i0, i1): a
## curving flight path (glide -> climb) is removed, the wingbeat is not
## (it errs toward under-estimating the bob).
static func _ripple_q(ys: PackedFloat64Array, i0: int, i1: int) -> float:
	var a := maxi(i0, 0)
	var b := mini(i1, ys.size())
	var n := b - a
	if n < 8:
		return 0.0
	# Normal equations for y = c0 + c1 u + c2 u^2 with u in [-1, 1].
	var s := PackedFloat64Array([0, 0, 0, 0, 0])
	var sy := PackedFloat64Array([0, 0, 0])
	for i in range(a, b):
		var u := 2.0 * float(i - a) / float(n - 1) - 1.0
		var p := 1.0
		for k in 5:
			s[k] += p
			p *= u
		sy[0] += ys[i]
		sy[1] += ys[i] * u
		sy[2] += ys[i] * u * u
	var m := Basis(Vector3(s[0], s[1], s[2]), Vector3(s[1], s[2], s[3]), Vector3(s[2], s[3], s[4]))
	var c := m.inverse() * Vector3(sy[0], sy[1], sy[2])
	var lo := INF
	var hi := -INF
	for i in range(a, b):
		var u := 2.0 * float(i - a) / float(n - 1) - 1.0
		var r := ys[i] - (c.x + c.y * u + c.z * u * u)
		lo = minf(lo, r)
		hi = maxf(hi, r)
	return 0.5 * (hi - lo)


func test_heave_at_flap_onset() -> void:
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for kind: String in ["climb", "cruise"]:
			fx = FX.new(self)
			await fx.setup(sp)
			var p := fx.player
			p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
			fx.run(3.0)  # glide first
			var ts := fx.src.tick / 72.0
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				if kind == "climb":
					ScriptedPoseSource.flap(b, t - ts, 45.0, 1.0)
				else:
					ScriptedPoseSource.flap(b, t - ts, 25.0, 1.0)
					for a in b.arms:
						a.twist = -20.0 * DEG
			var ys := PackedFloat64Array()
			var bs := PackedFloat64Array()
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				ys.append(f.player.camera.global_position.y)
				bs.append(f.player.model.position.y)
			fx.run(9.0)
			var ws := p.origin.world_scale
			var row := PackedStringArray()
			var worst := 0.0
			for w in [[0, 2], [1, 3], [2, 4], [4, 6], [6, 8]]:
				var c := _ripple(ys, w[0] * 72, w[1] * 72 + 72) / ws * 100.0
				var r := _ripple(bs, w[0] * 72, w[1] * 72 + 72) / ws * 100.0
				var cq := _ripple_q(ys, w[0] * 72, w[1] * 72) / ws * 100.0
				var rq := _ripple_q(bs, w[0] * 72, w[1] * 72) / ws * 100.0
				row.append("%d-%d s: cam %.0f / quad %.0f cm (raw %.0f / %.0f)" % [w[0], w[1], c, cq, r, rq])
				worst = maxf(worst, cq)
			_lines.append("%s %s (ws %.3f): %s" % [sp, kind, ws, ", ".join(row)])
			metric("%s_%s_worst_onset_cm" % [sp, kind], worst)
			fx.teardown()
			fx = null
	check(true, "measured")


func test_heave_flap_glide_bursts() -> void:
	# Realistic flapping: bursts of 3 strokes (1 Hz, 40 deg, wrists 10 deg
	# forward) then 2 s of gliding, repeated for 30 s.
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		fx.run(2.0)
		var ts := fx.src.tick / 72.0
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var tt := fmod(t - ts, 5.0)
			if tt < 3.0:
				ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
			for a in b.arms:
				a.twist = -10.0 * DEG
		var ys := PackedFloat64Array()
		var bs := PackedFloat64Array()
		fx.on_tick = func(_tick: int, f: Variant) -> void:
			ys.append(f.player.camera.global_position.y)
			bs.append(f.player.model.position.y)
		fx.run(30.0)
		var ws := p.origin.world_scale
		var cams := PackedStringArray()
		var worst_c := 0.0
		var worst_r := 0.0
		for k in 6:
			var i0 := k * 5 * 72
			var c := _ripple(ys, i0, i0 + 4 * 72) / ws * 100.0
			var r := _ripple(bs, i0, i0 + 4 * 72) / ws * 100.0
			cams.append("%.0f/%.0f" % [c, r])
			worst_c = maxf(worst_c, c)
			worst_r = maxf(worst_r, r)
		_lines.append("%s flap-glide bursts (ws %.3f): per-burst perceived bob cam/raw cm: %s ; worst cam %.0f cm vs raw %.0f cm" % [sp, ws, ", ".join(cams), worst_c, worst_r])
		metric("%s_burst_bob_cam_cm" % sp, worst_c)
		metric("%s_burst_bob_raw_cm" % sp, worst_r)
		fx.teardown()
		fx = null
	check(true, "measured")


## Wingbeat-band vertical acceleration: second difference of y, minus its
## centred 1-period moving average (removes burst/glide level changes and
## curvature), RMS over [i0, i1). m/s^2 in world units.
static func _acc_band_rms(ys: PackedFloat64Array, i0: int, i1: int) -> float:
	var dt := 1.0 / 72.0
	var acc := PackedFloat64Array()
	acc.resize(ys.size())
	for i in range(1, ys.size() - 1):
		acc[i] = (ys[i + 1] - 2.0 * ys[i] + ys[i - 1]) / (dt * dt)
	var n := 36
	var s := 0.0
	var c := 0
	for i in range(maxi(i0, n + 1), mini(i1, ys.size() - n - 1)):
		var m := 0.0
		for k in range(-n, n + 1):
			m += acc[i + k]
		m /= 2 * n + 1
		s += (acc[i] - m) * (acc[i] - m)
		c += 1
	return sqrt(s / maxf(c, 1))


func test_heave_band_acceleration_bursts_vs_steady() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var res := {}
		for pattern: String in ["steady", "bursts"]:
			fx = FX.new(self)
			await fx.setup(sp)
			var p := fx.player
			p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
			var ts := fx.src.tick / 72.0
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				var tt := t - ts
				if pattern == "steady" or fmod(tt, 5.0) < 3.0:
					ScriptedPoseSource.flap(b, fmod(tt, 5.0) if pattern == "bursts" else tt, 40.0, 1.0)
				for a in b.arms:
					a.twist = -10.0 * DEG
			var ys := PackedFloat64Array()
			var bs := PackedFloat64Array()
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				ys.append(f.player.camera.global_position.y)
				bs.append(f.player.model.position.y)
			fx.run(30.0)
			var ws := p.origin.world_scale
			# Steady: measure the last 15 s; bursts: the whole run after 5 s.
			var i0 := 15 * 72 if pattern == "steady" else 5 * 72
			var cam := _acc_band_rms(ys, i0, ys.size()) / ws
			var raw := _acc_band_rms(bs, i0, bs.size()) / ws
			# Equivalent 1 Hz displacement amplitude (perceived cm): a / (2 pi f)^2 * sqrt(2).
			res[pattern] = [cam, raw, cam / 39.48 * 1.414 * 100.0, raw / 39.48 * 1.414 * 100.0]
			fx.teardown()
			fx = null
		_lines.append("%s wingbeat-band vertical accel (perceived, RMS m/s^2) cam/raw: steady %.2f/%.2f (~%.0f/%.0f cm at 1 Hz), flap-glide bursts %.2f/%.2f (~%.0f/%.0f cm)" % [
			sp, res["steady"][0], res["steady"][1], res["steady"][2], res["steady"][3], res["bursts"][0], res["bursts"][1], res["bursts"][2], res["bursts"][3]])
		metric("%s_steady" % sp, res["steady"])
		metric("%s_bursts" % sp, res["bursts"])
	check(true, "measured")


func test_heave_offset_jumps_in_bursts() -> void:
	# Per-tick change of the camera's heave offset (camera y - body y): a
	# smooth smoother changes it by a fraction of a mm per tick; a jump is a
	# visible vertical hitch of the whole view.
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
		var ts := fx.src.tick / 72.0
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var tt := fmod(t - ts, 5.0)
			if tt < 3.0:
				ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
			for a in b.arms:
				a.twist = -10.0 * DEG
		var st := {"prev": 0.0, "max": 0.0, "n_big": 0, "at": [], "max_off": 0.0, "clamped": 0}
		var ws := p.origin.world_scale
		var lim := p.model.params.span * 2.0 * p.tuning.heave_clamp_spans
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var off: float = f.player._heave_off
			var d := absf(off - float(st["prev"])) / ws * 100.0
			if d > float(st["max"]):
				st["max"] = d
			if d > 2.0:
				st["n_big"] += 1
				if (st["at"] as Array).size() < 12:
					(st["at"] as Array).append("t%.2f:%.1fcm(T=%.2f)" % [tick / 72.0, d, f.player.wing_state().stroke_period])
			st["max_off"] = maxf(float(st["max_off"]), absf(off) / ws * 100.0)
			if absf(absf(off) - lim) < 1e-6:
				st["clamped"] += 1
			st["prev"] = off
		fx.run(30.0)
		_lines.append("%s bursts: max per-tick heave-offset jump %.1f cm perceived; ticks with > 2 cm jumps: %d / %d; max |offset| %.0f cm perceived (clamp %.0f cm, clamped ticks %d); first jumps %s" % [
			sp, st["max"], st["n_big"], 30 * 72, st["max_off"], lim / ws * 100.0, st["clamped"], str(st["at"])])
		metric("%s_max_jump_cm" % sp, st["max"])
		metric("%s_big_jumps" % sp, st["n_big"])
		# A smoother must never move the view on its own by more than ~2 cm
		# (perceived) in one frame: that is a visible vertical hitch.
		lt(st["max"], 2.0, "%s flap-glide bursts: heave offset never jumps > 2 cm perceived in one tick" % sp)
		fx.teardown()
		fx = null


func test_heave_trace_burst_onset() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var p := fx.player
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	var ts := fx.src.tick / 72.0
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var tt := fmod(t - ts, 5.0)
		if tt < 3.0:
			ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
		for a in b.arms:
			a.twist = -10.0 * DEG
	var ws := p.origin.world_scale
	var st := {"prev_cam": p.camera.global_position.y, "prev_body": p.model.position.y}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var t := tick / 72.0
		var cam: float = f.player.camera.global_position.y
		var body: float = f.player.model.position.y
		if t >= 5.02 and t <= 5.22:
			_lines.append("  trace t %.3f body dy %+.2f cm cam dy %+.2f cm (perceived) offset %+.1f cm T %.2f onset %s flap %.2f" % [t,
				(body - float(st["prev_body"])) / ws * 100.0, (cam - float(st["prev_cam"])) / ws * 100.0, f.player._heave_off / ws * 100.0,
				f.player.wing_state().stroke_period, str(f.player.wing_state().onset_l), f.player.wing_state().flap_l])
		st["prev_cam"] = cam
		st["prev_body"] = body
	fx.run(6.0)
	fx.teardown()
	fx = null
	check(true, "traced")


func test_heave_jumps_in_bot_course() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		var b := BC.new(fx, sp)
		await b.setup()
		var ws := fx.player.origin.world_scale
		var st := {"prev": 0.0, "max": 0.0, "n5": 0, "n10": 0, "cam_prev": fx.player.camera.global_position.y,
			"body_prev": fx.player.model.position.y, "max_rel": 0.0, "at": [], "prev_T": 1.0, "prev_mode": ""}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var off: float = f.player._heave_off
			var d := absf(off - float(st["prev"])) / ws * 100.0
			st["max"] = maxf(float(st["max"]), d)
			if d > 5.0:
				st["n5"] += 1
			if d > 10.0:
				st["n10"] += 1
			var T: float = f.player.wing_state().stroke_period
			if d > 5.0 and (st["at"] as Array).size() < 10:
				(st["at"] as Array).append("t%.2f %.1fcm mode %s->%s T %.2f->%.2f onset %s" % [tick / 72.0, d, st["prev_mode"], f.player.mode_name(),
					float(st["prev_T"]), T, str(f.player.wing_state().onset_l or f.player.wing_state().onset_r)])
			st["prev_T"] = T
			st["prev_mode"] = f.player.mode_name()
			st["prev"] = off
		b.fly()
		_lines.append("%s bot course (B1): heave-offset per-tick jump max %.1f cm perceived; ticks > 5 cm: %d, > 10 cm: %d (perched %s); %s" % [
			sp, st["max"], st["n5"], st["n10"], str(b.perched_on_target), str(st["at"])])
		metric("%s_bot_max_jump_cm" % sp, st["max"])
		lt(st["max"], 2.0, "%s bot course: heave offset never jumps > 2 cm perceived in one tick" % sp)
		fx.teardown()
		fx = null
