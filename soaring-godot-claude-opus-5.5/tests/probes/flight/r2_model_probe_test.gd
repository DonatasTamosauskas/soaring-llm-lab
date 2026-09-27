extends TestCase
## Verifier probe (round 2, flight, experience lens): FlightModel alone.
## - stall release: is the attitude / load continuous when the flow
##   re-attaches (the F3 plot shows alpha jumping ~9 deg at "unstall")?
## - no free energy from pumping pitch / roll / spread without flapping
##   (F8/F9: only real strokes produce thrust);
## - a 3 m/s updraft lifts EVERY size and in a 30 deg bank (F6);
## - the envelope at in-between species and non-ladder masses (F7 claims
##   are for sparrow / pigeon / eagle; growth is continuous in the game);
## - extreme dt / position robustness (F8).
## Output: artifacts/flight/verify/r2/model_probe.txt

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0

var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r2/model_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _model_mass(mass: float) -> FlightModel:
	var tu := FlightTuning.new()
	tu.preset = 1
	return FlightModel.new(mass, tu)


# --- stall release continuity --------------------------------------------------

func test_r2_stall_release_continuity() -> void:
	# (hold s, release pitch)
	var cases := [[2.0, 0.0], [1.0, 0.0], [3.0, 0.0], [2.0, -0.5], [2.0, 0.3], [0.6, 0.0]]
	var worst_da := 0.0
	var worst_dg := 0.0
	var worst_da_ref := 0.0
	var worst_dg_ref := 0.0
	for sp in FS.S3:
		# Reference: the pitch steps a player makes all the time (+0.5 balloon,
		# then -0.5), from cruise: the attitude / load change per tick there.
		var mr := FS.model(sp)
		mr.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rr := FS.Rec.new()
		FS.run(mr, 4 * 72, FS.glide(0.5), null, rr)
		FS.run(mr, 4 * 72, FS.glide(-0.5), null, rr)
		FS.run(mr, 4 * 72, FS.glide(1.0), null, rr)
		for i in range(1, rr.size()):
			worst_da_ref = maxf(worst_da_ref, absf(rr.alpha[i] - rr.alpha[i - 1]))
			worst_dg_ref = maxf(worst_dg_ref, absf(rr.g_load[i] - rr.g_load[i - 1]))
		for c in cases:
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.8)
			var rec := FS.Rec.new()
			FS.run(m, int(float(c[0]) * 72), FS.glide(1.0), null, rec)
			FS.run(m, int(3.0 * m.params.t_ph * 72), FS.glide(float(c[1])), null, rec)
			var da := 0.0
			var dth := 0.0
			var dg := 0.0
			var at := 0.0
			var dy2 := 0.0
			for i in range(2, rec.size()):
				var d := absf(rec.alpha[i] - rec.alpha[i - 1])
				if d > da:
					da = d
					at = rec.t[i]
				dth = maxf(dth, absf(rec.theta[i] - rec.theta[i - 1]))
				dg = maxf(dg, absf(rec.g_load[i] - rec.g_load[i - 1]))
				dy2 = maxf(dy2, absf(rec.y[i] - 2.0 * rec.y[i - 1] + rec.y[i - 2]))
			worst_da = maxf(worst_da, da)
			worst_dg = maxf(worst_dg, dg)
			var ev := PackedStringArray()
			for e in rec.events:
				ev.append("%s@%.2f" % [e[1], e[0]])
			_log("stall %s hold %.1f s release %.1f: max |d alpha|/tick %.2f deg at t=%.2f, |d theta|/tick %.2f deg, |d g|/tick %.3f, max |d2 y| %.4f m; events %s" % [
				sp, c[0], c[1], da, at, dth, dg, dy2, ", ".join(ev)])
			# Dump the 0.4 s around the worst alpha step for the report.
			var i_at := rec.at(at)
			var dump := PackedStringArray()
			for i in range(maxi(i_at - 6, 0), mini(i_at + 6, rec.size())):
				dump.append("t=%.3f a=%.1f th=%.1f g=%.1f n=%.2f V=%.2f st=%d sig=%.2f cl=%.2f" % [
					rec.t[i], rec.alpha[i], rec.theta[i], rec.gam[i], rec.g_load[i], rec.v[i], rec.stalled[i], rec.sig[i], rec.cl[i]])
			if c[0] == 2.0 and c[1] == 0.0:
				_log("  around worst: " + " | ".join(dump))
	_log("stall release: worst |d alpha| per tick %.2f deg (ordinary pitch steps: %.2f), worst |d g| per tick %.3f (ordinary: %.3f)" % [
		worst_da, worst_da_ref, worst_dg, worst_dg_ref])
	metric("stall_da_per_tick", [worst_da, worst_da_ref])
	metric("stall_dg_per_tick", [worst_dg, worst_dg_ref])
	# A re-attaching wing may raise lift quickly, but the body's angle of
	# attack must not step: 2 x the worst the ordinary pitch steps produce.
	lt(worst_da, maxf(2.0 * worst_da_ref, 2.0), "stall release: alpha changes per tick no more than 2x an ordinary pitch step (deg)")
	lt(worst_dg, maxf(2.0 * worst_dg_ref, 0.1), "stall release: load factor changes per tick no more than 2x an ordinary pitch step (g)")


# --- pumping: no free energy -----------------------------------------------------

func _min_sink(sp: StringName) -> float:
	var best := INF
	var p := -0.6
	while p <= 0.95:
		var m := FS.model(sp)
		m.trim(Vector3(0, 800, 0), 0.0, p)
		FS.run(m, 15 * 72, FS.glide(p))
		var e0 := FS.energy_height(m)
		FS.run(m, 10 * 72, FS.glide(p))
		var rate := (FS.energy_height(m) - e0) / 10.0
		best = minf(best, -rate)
		p += 0.1
	return best


func test_r2_pumping_gains_no_energy() -> void:
	var worst_ratio := 0.0
	var worst_desc := ""
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		var min_sink := _min_sink(sp)
		var pats := {}
		for hz: float in [0.25, 0.5, 1.0, 2.0, 4.0]:
			pats["pitch+-1@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				ws.set_commands(sin(TAU * hz * i * DT), 0.0, 1.0, 0.0, 0.0)
			pats["pitch0..1@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				ws.set_commands(0.5 + 0.5 * sin(TAU * hz * i * DT), 0.0, 1.0, 0.0, 0.0)
			pats["spread@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				ws.set_commands(0.0, 0.0, 0.6 + 0.4 * sin(TAU * hz * i * DT), 0.0, 0.0)
			pats["pitch+spread@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				var ph: float = TAU * hz * i * DT
				ws.set_commands(sin(ph), 0.0, 0.6 + 0.4 * cos(ph), 0.0, 0.0)
			pats["roll+-1@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				ws.set_commands(0.3, sin(TAU * hz * i * DT), 1.0, 0.0, 0.0)
			pats["asym-spread@%.2f" % hz] = func(i: int, ws: WingState) -> void:
				ws.set_commands(0.2, 0.0, 1.0, 0.0, 0.0)
				ws.ext_l = 0.6 + 0.4 * sin(TAU * hz * i * DT)
				ws.ext_r = 0.6 - 0.4 * sin(TAU * hz * i * DT)
		for k in pats:
			var m := FS.model(sp)
			m.trim(Vector3(0, 1500, 0), 0.0, 0.0)
			var e0 := FS.energy_height(m)
			FS.run(m, 60 * 72, pats[k])
			var rate := (FS.energy_height(m) - e0) / 60.0
			# Sink relative to the best steady glide's: >= 1 expected; < 0 is
			# a perpetual-motion exploit.
			var eff := -rate / min_sink
			if 1.0 / maxf(eff, 1e-6) > worst_ratio:
				worst_ratio = 1.0 / maxf(eff, 1e-6)
				worst_desc = "%s %s: energy rate %.3f m/s (min sink %.3f)" % [sp, k, rate, min_sink]
			lt(rate, 0.0, "%s %s: no flapping -> energy height falls (m/s)" % [sp, k])
			if rate > -0.8 * min_sink:
				_log("NOTE %s %s: energy rate %.3f m/s vs min sink %.3f (%.0f%%)" % [sp, k, rate, min_sink, 100.0 * -rate / min_sink])
		_log("%s: min sink (steady glides) %.3f m/s" % [sp, min_sink])
	_log("pumping: best pattern loses energy at %.0f%% of the min-sink rate: %s" % [100.0 / maxf(worst_ratio, 1e-6), worst_desc])
	metric("pump_best_vs_minsink", 1.0 / maxf(worst_ratio, 1e-6))
	lt(worst_ratio, 1.15, "pumping never beats the best steady glide by more than 15% (no free energy)")


# --- updrafts at every size -----------------------------------------------------

func test_r2_updraft_3ms_every_size_and_banked() -> void:
	var masses := {}
	for sp in FS.SP:
		masses[String(sp)] = FlightParams.species_mass(sp)
	masses["m0.1"] = 0.1
	masses["m0.6"] = 0.6
	masses["m2.0"] = 2.0
	masses["wren"] = FlightParams.species_mass(&"wren")
	for k in masses:
		var mass: float = masses[k]
		for case in [["neutral", 0.0, 0.0], ["bank30", 0.0, -1.0], ["fast", -0.4, 0.0], ["slow", 0.6, 0.0]]:
			var m := _model_mass(mass)
			m.trim(Vector3(0, 500, 0), 0.0, float(case[1]))
			var roll: float = case[2]
			if roll < 0.0:
				# The roll command giving ~30 deg of bank.
				roll = deg_to_rad(30.0) / m.params.phi_max
			var env := FlightEnv.uniform(Vector3(0, 3.0, 0))
			var rec := FS.Rec.new()
			FS.run(m, 30 * 72, FS.glide(float(case[1]), roll), env, rec)
			var vy := FS.mean(rec.vy, rec.at(10.0))
			var bank := FS.mean(rec.phi, rec.at(10.0))
			_log("updraft 3 m/s %s %s: climb %.2f m/s (bank %.0f deg, V %.1f)" % [k, case[0], vy, bank, FS.mean(rec.v, rec.at(10.0))])
			if case[0] in ["neutral", "bank30"]:
				gt(vy, 0.2, "%s %s in a 3 m/s updraft: climbs without flapping (m/s)" % [k, case[0]])


# --- envelope at in-between sizes -------------------------------------------------

func test_r2_envelope_between_sizes() -> void:
	var masses: Array = []
	for sp in FS.SP:
		masses.append([String(sp), FlightParams.species_mass(sp)])
	masses.append(["m0.1", 0.1])
	masses.append(["m0.6", 0.6])
	masses.append(["m2.0", 2.0])
	var prev_c := 0.0
	var prev_r := 0.0
	for row in masses:
		var mass: float = row[1]
		var perf := SizeRules.performance(mass)
		var m := _model_mass(mass)
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 40 * 72, FS.glide(0.0), null, rec)
		var cruise := FS.mean(rec.v, rec.at(30.0))
		var m3 := _model_mass(mass)
		m3.trim(Vector3(0, 3000, 0), 0.0, 0.0)
		var rec3 := FS.Rec.new()
		FS.run(m3, 20 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec3)
		var vmax := FS.maxv(rec3.v)
		var m4 := _model_mass(mass)
		m4.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec4 := FS.Rec.new()
		FS.run(m4, int(2.5 * 72), FS.glide(0.0, 1.0), null, rec4)
		var rate := absf(FS.mean(rec4.yaw_rate, rec4.at(1.0)))
		var radius := FS.mean(rec4.v, rec4.at(1.0)) / maxf(rate, 1e-3)
		# Sustained: 10 s of full roll.
		var m5 := _model_mass(mass)
		m5.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec5 := FS.Rec.new()
		FS.run(m5, 12 * 72, FS.glide(0.0, 1.0), null, rec5)
		var rate_sus := absf(FS.mean(rec5.yaw_rate, rec5.at(6.0)))
		var sink_sus := FS.mean(rec5.vy, rec5.at(6.0))
		_log("%s (%.3f kg): cruise %.2f (%.2f), vmax %.2f (%.2f), turn %.2f (%.2f) sustained %.2f rad/s sink %.1f m/s in the sustained turn, radius %.1f m" % [
			row[0], mass, cruise / perf["cruise"], cruise, vmax / perf["max_speed"], vmax, rate / perf["turn_rate"], rate,
			rate_sus / perf["turn_rate"], sink_sus, radius])
		near(cruise / perf["cruise"], 1.0, 0.15, "%s cruise / SizeRules" % row[0])
		near(vmax / perf["max_speed"], 1.0, 0.15, "%s max speed / SizeRules" % row[0])
		near(rate / perf["turn_rate"], 1.0, 0.15, "%s turn rate / SizeRules" % row[0])
		# Ordering only along the species ladder (non-ladder masses come last).
		if row[0] in ["m0.1", "m0.6", "m2.0"]:
			continue
		if prev_c > 0.0:
			gt(cruise, prev_c, "%s cruises faster than the previous size" % row[0])
			gt(radius, prev_r, "%s turns wider than the previous size" % row[0])
		prev_c = cruise
		prev_r = radius


# --- robustness ---------------------------------------------------------------------

func test_r2_extreme_dt_and_positions() -> void:
	var bad := 0
	var n := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for sp in [&"sparrow", &"eagle"]:
		var m := FS.model(sp)
		m.trim(Vector3(0, 300, 0), 0.0, 0.0)
		var ws := WingState.new()
		var env := FlightEnv.new()
		for i in 5000:
			var dt: float = [DT, 0.0, -0.01, 1e-9, 0.25, 1.0, 5.0, NAN, INF, DT, DT][rng.randi() % 11]
			ws.set_commands(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-1, 2), rng.randf_range(0, 3), i * DT)
			if i % 97 == 0:
				ws.pitch = NAN
			if i % 131 == 0:
				ws.flap_dir_l = Vector3(INF, 0, 0)
			if i % 211 == 0:
				env = FlightEnv.uniform(Vector3(rng.randf_range(-80, 80), rng.randf_range(-40, 40), 0))
			if i % 223 == 0:
				env = FlightEnv.new()
			if i % 500 == 0:
				m.position = Vector3(1e6, 1e5, -1e6)
			m.step(ws, env, dt)
			n += 1
			if not (FlightMath.vfinite(m.position) and FlightMath.vfinite(m.velocity) and is_finite(m.alpha)
					and is_finite(m.phi) and is_finite(m.theta) and is_finite(m.g_load)):
				bad += 1
			if m.velocity.length() > 500.0:
				bad += 1
	_log("extreme dt / inputs / positions: %d bad states of %d" % [bad, n])
	eq(bad, 0, "no NaN / inf / runaway speed under extreme dt, inputs, winds and positions")
