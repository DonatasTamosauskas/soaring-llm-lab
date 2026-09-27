extends TestCase
## Verifier probe (round 2, flight, experience lens): camera heave with
## HUMAN-like flapping the builder's PB-08b does not cover:
##  - tempo changes (1.2 -> 0.8 -> 1.6 -> 1.0 Hz, continuous strokes),
##  - irregular strokes (random duration 0.6-1.4 s, amplitude 25-50 deg,
##    random short pauses), 3 seeds per size,
##  - flap-flap-glide (2 strokes, 0.7 s glide, repeat),
##  - one-wing strokes (steering kicks),
##  - growth sparrow -> eagle while flapping (world_scale changing).
## Questions: does the view ever jerk harder than the body (a hitch)? Does
## the smoother ever ADD vertical motion (camera wingbeat or wingbeat-band
## vertical acceleration above the raw body's) - and for how much of the
## flight?
## Output: artifacts/flight/verify/r2/heave_probe.txt, heave_*.png

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const HM := preload("res://tests/unit/flight/heave_metrics.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX
var _lines := PackedStringArray()
var _plots := {}


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r2/heave_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


## Stroke schedule for the irregular pilot: [t0, dur, amp_deg] per stroke.
## jit: per-stroke duration jitter around 1 s (0.4 = 0.6..1.4 s);
## pause_p: chance of a 0.2-1.5 s glide after a stroke.
var jit := 0.4
var pause_p := 0.35
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


## Wingbeat-band vertical acceleration RMS per sliding window (perceived
## m/s^2): [worst cam/body ratio, share of windows with ratio > 1.1, mean
## cam, mean body]. Windows whose body band RMS is tiny are skipped.
func _acc_windows(hm: HM, win: float, step: float) -> Array:
	var n := int(win / DT)
	var st := int(step / DT)
	var worst := 0.0
	var over := 0
	var cnt := 0
	var sc := 0.0
	var sb := 0.0
	var i := 72
	while i + n < hm.size() - 72:
		var ok := true
		for j in range(i, i + n, 6):
			if hm.flying[j] == 0:
				ok = false
				break
		if ok:
			var c := hm.band_acc(hm.cam, i, i + n)
			var b := hm.band_acc(hm.body, i, i + n)
			if b > 0.3:
				cnt += 1
				sc += c
				sb += b
				worst = maxf(worst, c / b)
				if c > 1.1 * b:
					over += 1
		i += st
	return [worst, float(over) / maxf(cnt, 1), sc / maxf(cnt, 1), sb / maxf(cnt, 1)]


func _fly(sp: StringName, kind: String, secs: float, seed := 1, grow := false) -> HM:
	fx = FX.new(self)
	await fx.setup(sp)
	var f := fx
	var hm := HM.new()
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
		hm.push(fix.player)
	f.run(secs)
	_plots["%s %s s%d%s" % [sp, kind, seed, " grow" if grow else ""]] = hm
	fx.teardown()
	fx = null
	return hm


func _report(tag: String, hm: HM) -> Array:
	var cam := hm.max_cam_d2()
	var body := hm.max_body_d2()
	var sw := hm.wingbeat_sweep(3.0, 0.5)
	var aw := _acc_windows(hm, 3.0, 0.5)
	var w_at := hm.worst_cam_d2_at()
	_log("%-28s jerk cam/body %.2f/%.2f cm (%.2fx) at t=%.2f | wingbeat 3s mean cam %.1f raw %.1f cm (%.0f%%), worst window %.2fx | band acc worst %.2fx, windows >1.1x %.0f%%, mean cam %.2f body %.2f m/s2 | offset max %.0f%% of limit" % [
		tag, cam, body, cam / maxf(body, 1e-6), float(w_at[0]) * DT, sw[0], sw[1], 100.0 * sw[0] / maxf(sw[1], 1e-6), sw[2],
		aw[0], 100.0 * aw[1], aw[2], aw[3], 100.0 * hm.max_off_fraction])
	metric(tag.replace(" ", "_"), {"jerk": [cam, body], "wingbeat": sw, "acc": aw})
	return [cam, body, sw, aw]


func test_r2_heave_human_flapping() -> void:
	var worst_jerk := 0.0
	var worst_jerk_tag := ""
	var worst_amp := 0.0
	var worst_amp_tag := ""
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var runs: Array = [["tempo", 1], ["flapflapglide", 1], ["onewing", 1], ["steady", 1],
			["irregular", 11], ["irregular", 12], ["irregular", 13]]
		for r in runs:
			var hm: HM = await _fly(sp, r[0], 30.0, r[1])
			var tag := "%s %s s%d" % [sp, r[0], r[1]]
			var res := _report(tag, hm)
			var ratio: float = float(res[0]) / maxf(float(res[1]), 1e-6)
			if ratio > worst_jerk:
				worst_jerk = ratio
				worst_jerk_tag = tag
			var aw: Array = res[3]
			if float(aw[0]) > worst_amp:
				worst_amp = aw[0]
				worst_amp_tag = tag
			# No hitch: the builder's own bound for irregular flying.
			lt(float(res[0]), 1.4 * float(res[1]) + 0.05, "%s: camera per-tick jerk <= 1.4x body's (no hitch)" % tag)
			# Mean over the flight: the smoother must not add vertical motion.
			var sw: Array = res[2]
			lt(float(sw[0]), 1.0 * float(sw[1]) + 0.5, "%s: mean camera wingbeat (3 s windows) <= raw body's" % tag)
			lt(float(aw[2]), 1.0 * float(aw[3]) + 0.02, "%s: mean wingbeat-band vertical acceleration of the view <= body's" % tag)
	_log("worst jerk ratio %.2f (%s); worst band-acc window ratio %.2f (%s)" % [worst_jerk, worst_jerk_tag, worst_amp, worst_amp_tag])


## How irregular must a human be before the smoother hurts? Per-stroke
## duration jitter 10 / 20 / 30 %, with and without short glides.
func test_r2_heave_irregularity_sweep() -> void:
	var rows := PackedStringArray()
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for cfg in [[0.1, 0.0], [0.2, 0.0], [0.3, 0.0], [0.1, 0.35], [0.2, 0.35]]:
			jit = cfg[0]
			pause_p = cfg[1]
			var acc_ratio := 0.0
			var over := 0.0
			var jr := 0.0
			var wb := 0.0
			for seed in [21, 22, 23]:
				var hm: HM = await _fly(sp, "irregular", 30.0, seed)
				var aw := _acc_windows(hm, 3.0, 0.5)
				var sw := hm.wingbeat_sweep(3.0, 0.5)
				acc_ratio += float(aw[2]) / maxf(float(aw[3]), 1e-6) / 3.0
				over += float(aw[1]) / 3.0
				jr = maxf(jr, hm.max_cam_d2() / maxf(hm.max_body_d2(), 1e-6))
				wb += float(sw[0]) / maxf(float(sw[1]), 1e-6) / 3.0
			var line := "%s jitter +-%d%% pauses %d%%: view band-acc / body %.2f (mean of 3 seeds), windows > 1.1x %.0f%%, worst jerk ratio %.2f, wingbeat cam/raw %.0f%%" % [
				sp, int(cfg[0] * 100), int(cfg[1] * 100), acc_ratio, 100.0 * over, jr, 100.0 * wb]
			_log(line)
			rows.append(line)
			metric("%s_jit%d_p%d" % [sp, int(cfg[0] * 100), int(cfg[1] * 100)], [acc_ratio, over, jr, wb])
			if cfg[1] == 0.0 and cfg[0] <= 0.2:
				# Positive control: continuous flapping with natural timing
				# jitter is what the smoother is built for.
				lt(acc_ratio, 0.9, "%s continuous flapping, jitter +-%d%%: the view moves less than the body" % [sp, int(cfg[0] * 100)])
			else:
				# Flap-glide / irregular timing: the smoother must at least do
				# no harm on average.
				lt(acc_ratio, 1.02, "%s jitter +-%d%% pauses %d%%: the view moves no more than the body (mean)" % [sp, int(cfg[0] * 100), int(cfg[1] * 100)])
	jit = 0.4
	pause_p = 0.35


## The bot pilot with novice noise (B2) flying the whole course: the closest
## thing to a real player the builder has. Heave metrics over the flight.
func test_r2_heave_novice_bot() -> void:
	const BC := preload("res://tests/unit/flight/bot_course.gd")
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for seed in [1, 2, 3]:
			fx = FX.new(self)
			var b := BC.new(fx, sp)
			await b.setup(true, 1, seed)
			var hm := HM.new()
			fx.on_tick = func(_tick: int, fix: Variant) -> void:
				hm.push(fix.player)
			b.fly(false)
			var res := _report("%s novice bot s%d (%.0f s)" % [sp, seed, hm.size() * DT], hm)
			var aw: Array = res[3]
			metric("%s_novice_s%d" % [sp, seed], [float(res[0]) / maxf(float(res[1]), 1e-6), aw[0], aw[1], float(aw[2]) / maxf(float(aw[3]), 1e-6)])
			# A default-on comfort filter must not add vertical motion to the
			# view over a realistic flight.
			lt(float(aw[2]), 1.02 * float(aw[3]), "%s novice bot s%d: mean wingbeat-band vertical acceleration of the view <= body's" % [sp, seed])
			lt(float(aw[1]), 0.15, "%s novice bot s%d: < 15%% of 3 s windows where the view moves > 1.1x the body" % [sp, seed])
			fx.teardown()
			fx = null


func test_r2_heave_while_growing() -> void:
	var hm: HM = await _fly(&"sparrow", "steady", 30.0, 1, true)
	var res := _report("sparrow->eagle growing, steady flapping", hm)
	lt(float(res[0]), 1.4 * float(res[1]) + 0.05, "growing while flapping: camera jerk <= 1.4x body")
	var hm2: HM = await _fly(&"sparrow", "irregular", 30.0, 12, true)
	var res2 := _report("sparrow->eagle growing, irregular", hm2)
	lt(float(res2[0]), 1.4 * float(res2[1]) + 0.05, "growing while flapping irregularly: camera jerk <= 1.4x body")


func test_r2_zz_plot() -> void:
	# Plot the three most interesting runs: body vs camera, perceived.
	var keys: Array = []
	for k in _plots:
		keys.append(k)
	if keys.is_empty():
		return
	var pl := FlightPlot.new(1600, 1100, "R2 verifier: camera heave with human-like flapping (perceived: / world_scale)")
	var picks: Array = []
	for want in ["sparrow irregular s12", "pigeon irregular s11", "pigeon tempo s1", "eagle flapflapglide s1"]:
		if _plots.has(want):
			picks.append(want)
	var n := picks.size()
	for idx in n:
		var hm: HM = _plots[picks[idx]]
		var r := Rect2i(90, 130 + idx * 240, 1440, 180)
		var pn := pl.panel(r, picks[idx], "t (s)", "m perceived")
		var ts := PackedFloat64Array()
		var yb := PackedFloat64Array()
		var yc := PackedFloat64Array()
		var y0 := hm.body[0]
		for i in hm.size():
			ts.append(i * DT)
			yb.append((hm.body[i] - y0) / hm.ws[i])
			yc.append((hm.cam[i] - y0) / hm.ws[i])
		pn.line(ts, yb, 0, "body", 2, FlightPlot.MUTED)
		pn.line(ts, yc, 1, "camera")
	pl.note("Grey: raw body height; colour: camera (body + heave offset). Perceived metres (world / world_scale).")
	if _plots.has("pigeon irregular s12"):
		var hmz: HM = _plots["pigeon irregular s12"]
		var pz := FlightPlot.new(1600, 900, "R2 verifier: pigeon irregular s12, 14-24 s: bob (height minus 1 s mean) and vertical acceleration, perceived")
		var tz := PackedFloat64Array()
		var bb := PackedFloat64Array()
		var cb := PackedFloat64Array()
		var ba := PackedFloat64Array()
		var ca := PackedFloat64Array()
		for i in range(int(14.0 / DT), int(24.0 / DT)):
			var mb := 0.0
			var mc := 0.0
			for k in range(-36, 37):
				mb += hmz.body[i + k]
				mc += hmz.cam[i + k]
			mb /= 73.0
			mc /= 73.0
			tz.append(i * DT)
			bb.append((hmz.body[i] - mb) / hmz.ws[i] * 100.0)
			cb.append((hmz.cam[i] - mc) / hmz.ws[i] * 100.0)
			ba.append((hmz.body[i + 1] - 2.0 * hmz.body[i] + hmz.body[i - 1]) / (DT * DT) / hmz.ws[i])
			ca.append((hmz.cam[i + 1] - 2.0 * hmz.cam[i] + hmz.cam[i - 1]) / (DT * DT) / hmz.ws[i])
		var p1 := pz.panel(Rect2i(90, 130, 1440, 300), "bob: height minus its centred 1 s mean", "", "cm perceived")
		p1.line(tz, bb, 0, "body", 2, FlightPlot.MUTED)
		p1.line(tz, cb, 1, "camera")
		var p2 := pz.panel(Rect2i(90, 520, 1440, 300), "vertical acceleration", "t (s)", "m/s2 perceived")
		p2.line(tz, ba, 0, "body", 2, FlightPlot.MUTED)
		p2.line(tz, ca, 1, "camera")
		pz.note("Irregular human strokes (0.6-1.4 s each, 25-50 deg, 35% chance of a short glide): where the smoother's fitted wingbeat no longer matches the body's, the camera carries the residual plus the misfit.")
		pz.save(Paths.artifacts("flight").path_join("verify/r2/heave_zoom_pigeon.png"))
	var out := Paths.artifacts("flight").path_join("verify/r2/heave_human.png")
	pl.save(out)
	check(FileAccess.file_exists(out), "plot written")
