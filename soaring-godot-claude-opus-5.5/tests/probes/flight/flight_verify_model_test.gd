extends TestCase
## Verifier probes (round 1, flight): FlightModel claims F2-F8 re-measured
## across ALL eight player sizes plus off-ladder masses, other trims, other
## step sizes, banked and flapping entries, crosswind, the sim preset, and
## fresh fuzz seeds. Pure model (no scene), so this is fast.

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0
const G := 9.81
const SP: Array[StringName] = [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]

var _lines := PackedStringArray()


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("model_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


func _m(mass: float, preset := 1) -> FlightModel:
	var tu := FlightTuning.new()
	tu.preset = preset
	return FlightModel.new(mass, tu)


func _masses() -> Array:
	var out: Array = []
	for sp in SP:
		out.append([String(sp), FlightParams.species_mass(sp)])
	for extra: float in [0.045, 0.2, 0.7, 2.0, 4.5]:
		out.append(["m%.3f" % extra, extra])
	return out


# --- F2: balloon / sag, many sizes, trims and step sizes ----------------------------
func test_f2_balloon_and_sag_everywhere() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for step: Array in [[0.0, 0.5], [-0.3, 0.3], [0.0, 0.2], [0.2, 0.7]]:
			var p0: float = step[0]
			var p1: float = step[1]
			var m := _m(mass)
			m.trim(Vector3(0, 2000, 0), 0.0, p0)
			var v0 := m.airspeed()
			var y0 := m.position.y
			var g_first := 0.0
			var peak := -INF
			var t_peak := 0.0
			var v3 := 0.0
			var stalled := false
			var n := int((3.0 * m.params.t_ph + 8.0) / DT)
			var ws := WingState.new()
			for i in n:
				ws.set_commands(p1, 0.0, 1.0, 0.0, 0.0)
				m.step(ws, null, DT)
				if i == int(0.15 / DT):
					g_first = m.g_load
				if m.position.y - y0 > peak:
					peak = m.position.y - y0
					t_peak = (i + 1) * DT
				if i == int(3.0 / DT):
					v3 = m.airspeed()
				stalled = stalled or m.stalled
			var v_end := m.airspeed()
			var v_trim: float = m.trim_solution(p1)["v"]
			_lines.append("F2 %s pitch %+.1f -> %+.1f: g(0.15 s) %.2f, peak rise %.2f m (%.1f spans) at %.2f s, V0 %.2f V(3 s) %.2f V_end %.2f (trim %.2f), stalled %s" % [
				name, p0, p1, g_first, peak, peak / m.params.span, t_peak, v0, v3, v_end, v_trim, str(stalled)])
			gt(g_first, 1.03, "%s %+.1f->%+.1f: lift rises immediately (g at 0.15 s)" % [name, p0, p1])
			gt(peak, 0.5 * m.params.span, "%s %+.1f->%+.1f: balloons above the start" % [name, p0, p1])
			lt(v3, v0, "%s %+.1f->%+.1f: airspeed falls" % [name, p0, p1])
			near(v_end / v_trim, 1.0, 0.05, "%s %+.1f->%+.1f: settles at the new (slower) trim" % [name, p0, p1])
			lt(v_end, v0, "%s %+.1f->%+.1f: the new trim is slower" % [name, p0, p1])
			check(not stalled, "%s %+.1f->%+.1f: never stalls (protected)" % [name, p0, p1])
		# Nose-down.
		for step2: Array in [[0.0, -0.5], [0.3, -0.2], [0.0, -1.0]]:
			var m2 := _m(mass)
			m2.trim(Vector3(0, 4000, 0), 0.0, step2[0])
			var v0b := m2.airspeed()
			var g0b := m2.gamma()
			var ws2 := WingState.new()
			var g1 := 0.0
			var v3b := 0.0
			for i in int(6.0 / DT):
				ws2.set_commands(step2[1], 0.0, 1.0, 0.0, 0.0)
				m2.step(ws2, null, DT)
				if i == int(1.0 / DT):
					g1 = m2.gamma()
				if i == int(3.0 / DT):
					v3b = m2.airspeed()
			_lines.append("F2 %s pitch %+.1f -> %+.1f: gamma %.1f -> %.1f deg at 1 s, V %.2f -> %.2f at 3 s" % [name, step2[0], step2[1],
				rad_to_deg(g0b), rad_to_deg(g1), v0b, v3b])
			lt(g1, g0b - 2.0 * DEG, "%s %+.1f->%+.1f: the nose drops (gamma at 1 s)" % [name, step2[0], step2[1]])
			gt(v3b, 1.03 * v0b, "%s %+.1f->%+.1f: speed builds (V at 3 s)" % [name, step2[0], step2[1]])


# --- F3: stall and recovery in many entries ------------------------------------------
func _stall_run(mass: float, preset: int, entry: String) -> Dictionary:
	var m := _m(mass, preset)
	var trim_p := 0.0 if entry != "slow" else 0.8
	m.trim(Vector3(0, 3000, 0), 0.0, trim_p)
	var v_trim0 := m.airspeed()
	var ws := WingState.new()
	var t_stall := -1.0
	var cl_peak := 0.0
	var cl_after := INF
	var stall_count0 := m.stall_count
	var roll := 0.7 if entry == "banked" else 0.0
	var effort := 1.0 if entry == "flapping" else 0.0
	var hold := int(2.0 / DT)
	for i in hold:
		ws.set_commands(1.0, roll, 1.0, effort, i * DT, 1.0, 0, NAN, m.params.x)
		m.step(ws, null, DT)
		cl_peak = maxf(cl_peak, m._cl)
		if m.stalled and t_stall < 0.0:
			t_stall = (i + 1) * DT
		if t_stall >= 0.0 and (i + 1) * DT <= t_stall + 0.6:
			cl_after = minf(cl_after, m._cl)
	# Release: lower the AoA (neutral wrists, wings level).
	var t_unstall := -1.0
	var t_rec := -1.0
	# Reference trim from a FRESH model: trim_solution() reads the live stall
	# separation (sigma) through _cd_of, so right after a stall it is wrong.
	var sol: Dictionary = _m(mass, preset).trim_solution(0.0)
	var sol_stale: Dictionary = m.trim_solution(0.0)
	var h0 := m.position.y
	var h_min := h0
	for i in int(3.0 * m.params.t_ph / DT):
		ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, null, DT)
		h_min = minf(h_min, m.position.y)
		if not m.stalled and t_unstall < 0.0:
			t_unstall = (i + 1) * DT
		if t_rec < 0.0 and not m.stalled and absf(m.gamma() - float(sol["gamma"])) < 5.0 * DEG and absf(m.airspeed() / float(sol["v"]) - 1.0) < 0.15:
			t_rec = (i + 1) * DT
	return {"t_stall": t_stall, "cl_peak": cl_peak, "cl_after": cl_after, "t_unstall": t_unstall, "t_rec": t_rec,
		"t_ph": m.params.t_ph, "loss": h0 - h_min, "stalls": m.stall_count - stall_count0, "v_trim0": v_trim0,
		"stale_gamma": rad_to_deg(float(sol_stale["gamma"])), "fresh_gamma": rad_to_deg(float(sol["gamma"]))}


func test_f3_stall_and_recovery_everywhere() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for preset in [1, 0]:
			for entry: String in ["cruise", "slow", "banked", "flapping"]:
				var r := _stall_run(mass, preset, entry)
				var tag := "%s %s %s" % [name, "sim" if preset == 0 else "normal", entry]
				_lines.append("F3 %s: stall at %.2f s, CL peak %.2f -> %.2f (%.0f%%), unstall %.2f s after release, recovered %.2f s (%.2f T_ph), loss %.1f m, stall events %d" % [
					tag, r["t_stall"], r["cl_peak"], r["cl_after"], 100.0 * r["cl_after"] / maxf(r["cl_peak"], 1e-6), r["t_unstall"], r["t_rec"],
					r["t_rec"] / r["t_ph"], r["loss"], r["stalls"]])
				# A hover-capable bird flapping hard at full nose-up slows into the
				# hover regime, where AoA is gated off (M-4): no stall there is fine.
				var hover_case: bool = entry == "flapping" and mass <= 0.1
				if not hover_case:
					check(r["t_stall"] >= 0.0 and r["t_stall"] <= 1.5, "%s: full nose-up held stalls (within 1.5 s)" % tag)
					lt(r["cl_after"], 0.8 * r["cl_peak"], "%s: lift collapses in the stall (CL < 80%% of its peak)" % tag)
				check(r["t_unstall"] >= 0.0 and r["t_unstall"] <= 1.5, "%s: lowering the AoA unstalls within 1.5 s" % tag)
				if preset == 1:
					check(r["t_rec"] >= 0.0 and r["t_rec"] <= 1.2 * r["t_ph"], "%s: recovered (trim gamma +-5 deg, V +-15 %%) within 1.2 T_ph" % tag)
				else:
					# sim preset: no phugoid damper by design; it must still get there.
					check(r["t_rec"] >= 0.0, "%s: recovered to trim eventually (within 3 T_ph)" % tag)
				if entry == "cruise":
					_lines.append("   trim_solution(0) right after the release: gamma %.2f deg (fresh model %.2f deg)" % [r["stale_gamma"], r["fresh_gamma"]])


# --- F4: coordinated turns, every size, crosswind, flapping ---------------------------
func test_f4_coordinated_turns_everywhere() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for roll: float in [0.3, 0.6, 1.0, -0.8]:
			for cond: String in ["glide", "crosswind", "flapping"]:
				var m := _m(mass)
				m.trim(Vector3(0, 3000, 0), 0.0, 0.0)
				var env := FlightEnv.new()
				if cond == "crosswind":
					env = FlightEnv.uniform(Vector3(5.0, 0, 0))
				var ws := WingState.new()
				var worst_ratio := 0.0
				var worst_slip := 0.0
				var samples := 0
				for i in int(6.0 / DT):
					ws.set_commands(0.0, roll, 1.0, 0.6 if cond == "flapping" else 0.0, i * DT, 1.0, 0, 10.0, m.params.x)
					m.step(ws, env, DT)
					var t := (i + 1) * DT
					var va := m.velocity - m.wind
					var vh := Vector2(va.x, va.z)
					# True sideslip: body heading vs the horizontal AIR velocity.
					var slip := absf(FlightMath.wrap_angle(m.heading() - atan2(-va.x, -va.z)))
					if t > 1.5:
						var ideal := G * tan(absf(m.phi)) / maxf(vh.length(), 0.1)
						if absf(m.phi) > 5.0 * DEG and cond != "flapping":
							worst_ratio = maxf(worst_ratio, absf(absf(m.yaw_rate) / ideal - 1.0))
							samples += 1
						worst_slip = maxf(worst_slip, slip)
				_lines.append("F4 %s roll %+.1f %s: bank %.1f deg, worst |rate/ideal - 1| %.3f over %d samples, worst sideslip %.2f deg" % [
					name, roll, cond, rad_to_deg(m.phi), worst_ratio, samples, rad_to_deg(worst_slip)])
				lt(rad_to_deg(worst_slip), 5.0, "%s roll %+.1f %s: sideslip < 5 deg" % [name, roll, cond])
				if cond != "flapping":
					lt(worst_ratio, 0.2, "%s roll %+.1f %s: heading rate within 20%% of g tan(bank)/V (every sample after 1.5 s)" % [name, roll, cond])
				check(signf(m.phi) == signf(roll), "%s roll %+.1f %s: banks toward the input" % [name, roll, cond])
		# Neutral input returns toward wings-level from a full bank (and from a stall's wing drop).
		var m3 := _m(mass)
		m3.trim(Vector3(0, 3000, 0), 0.0, 0.0)
		var ws3 := WingState.new()
		for i in int(3.0 / DT):
			ws3.set_commands(0.0, 1.0, 1.0, 0.0, 0.0)
			m3.step(ws3, null, DT)
		var t_level := -1.0
		for i in int(4.0 / DT):
			ws3.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
			m3.step(ws3, null, DT)
			if t_level < 0.0 and absf(m3.phi) < 3.0 * DEG:
				t_level = (i + 1) * DT
		var bank_end := rad_to_deg(absf(m3.phi))
		_lines.append("F4 %s auto-level from full bank: |bank| < 3 deg after %.2f s, %.2f deg at 4 s" % [name, t_level, bank_end])
		check(t_level >= 0.0 and t_level <= 2.5, "%s: neutral input levels the wings (< 3 deg within 2.5 s)" % name)
		lt(bank_end, 1.0, "%s: stays level" % name)


# --- F5: tuck dive and pull-out, every size --------------------------------------------
func test_f5_tuck_and_pullout_everywhere() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for start_p: float in [0.0, 0.8]:
			var m := _m(mass)
			m.trim(Vector3(0, 6000, 0), 0.0, start_p)
			var ws := WingState.new()
			var vmax := m.params.v_max
			var t95 := -1.0
			var v_peak := 0.0
			for i in int(12.0 / DT):
				ws.set_commands(-1.0, 0.0, 0.0, 0.0, 0.0)
				m.step(ws, null, DT)
				v_peak = maxf(v_peak, m.airspeed())
				if t95 < 0.0 and m.airspeed() >= 0.9 * vmax:
					t95 = (i + 1) * DT
			var g_peak := 0.0
			var t_out := -1.0
			var h0 := m.position.y
			for i in int(15.0 / DT):
				ws.set_commands(0.5, 0.0, 1.0, 0.0, 0.0)
				m.step(ws, null, DT)
				g_peak = maxf(g_peak, m.g_load)
				if t_out < 0.0 and m.gamma() > -5.0 * DEG:
					t_out = (i + 1) * DT
			_lines.append("F5 %s from pitch %.1f: 0.9 V_max at %.2f s, peak %.3f V_max; pull-out to gamma > -5 deg in %.2f s, peak %.2f g (n_max %.2f), height lost %.1f m" % [
				name, start_p, t95, v_peak / vmax, t_out, g_peak, m.params.n_max, h0 - m.position.y])
			check(t95 >= 0.0 and t95 <= 10.0, "%s from %.1f: tuck dive reaches 0.9 V_max within 10 s" % [name, start_p])
			lt(v_peak / vmax, 1.03, "%s from %.1f: never above 1.03 V_max" % [name, start_p])
			check(t_out >= 0.0 and t_out <= 8.0, "%s from %.1f: spreading pulls out (gamma > -5 deg within 8 s)" % [name, start_p])
			lt(g_peak, m.params.n_max + 0.2, "%s from %.1f: pull-out load <= n_max + 0.2" % [name, start_p])


# --- F6: updraft climb without flapping, every size -----------------------------------
func test_f6_updraft_everywhere() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for pitch: float in [0.0, 0.4]:
			for bank: float in [0.0, 0.4]:
				var m := _m(mass)
				m.trim(Vector3(0, 500, 0), 0.0, pitch)
				var env := FlightEnv.uniform(Vector3(0, 3.0, 0))
				var ws := WingState.new()
				for i in int(10.0 / DT):
					ws.set_commands(pitch, bank, 1.0, 0.0, 0.0)
					m.step(ws, env, DT)
				var y0 := m.position.y
				for i in int(20.0 / DT):
					ws.set_commands(pitch, bank, 1.0, 0.0, 0.0)
					m.step(ws, env, DT)
				var rate := (m.position.y - y0) / 20.0
				_lines.append("F6 %s pitch %.1f roll %.1f in 3 m/s: climb %+.2f m/s (in_updraft %.2f)" % [name, pitch, bank, rate, m.telemetry()["in_updraft"]])
				gt(rate, 0.3, "%s pitch %.1f roll %.1f: a 3 m/s updraft climbs without flapping" % [name, pitch, bank])


# --- F7: the envelope at every size and between species ---------------------------------
func test_f7_envelope_everywhere() -> void:
	var prev_c := 0.0
	var prev_r := 0.0
	var prev_x := 0.0
	var rows: Array = []
	for row in _masses():
		rows.append(row)
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) < float(b[1]))
	for row in rows:
		var name: String = row[0]
		var mass: float = row[1]
		var perf := SizeRules.performance(mass)
		var m := _m(mass)
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 40 * 72, FS.glide(0.0), null, rec)
		var cruise := FS.mean(rec.v, rec.at(30.0))
		var m2 := _m(mass)
		m2.trim(Vector3(0, 800, 0), 0.0, 0.88)
		var rec2 := FS.Rec.new()
		FS.run(m2, 20 * 72, FS.glide(0.88), null, rec2)
		var vmin := FS.mean(rec2.v, rec2.at(10.0))
		var m3 := _m(mass)
		m3.trim(Vector3(0, 5000, 0), 0.0, 0.0)
		var rec3 := FS.Rec.new()
		FS.run(m3, 20 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec3)
		var vmax := FS.maxv(rec3.v)
		var m4 := _m(mass)
		m4.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec4 := FS.Rec.new()
		FS.run(m4, int(2.5 * 72), FS.glide(0.0, 1.0), null, rec4)
		var i0 := rec4.at(1.0)
		var rate := absf(FS.mean(rec4.yaw_rate, i0))
		var radius := FS.mean(rec4.v, i0) / maxf(rate, 1e-3)
		# Climb: best of a small grid (reference strokes), energy-height rate.
		var best := -INF
		for p: float in [0.0, 0.2, 0.4]:
			for tilt: float in [0.0, 15.0, 30.0]:
				var m5 := _m(mass)
				m5.trim(Vector3(0, 300, 0), 0.0, 0.0)
				FS.run(m5, 20 * 72, FS.flap(m5, p, 0.0, 1.0, tilt))
				var e0 := FS.energy_height(m5)
				FS.run(m5, 10 * 72, FS.flap(m5, p, 0.0, 1.0, tilt))
				best = maxf(best, (FS.energy_height(m5) - e0) / 10.0)
		var ratios := {"cruise": cruise / perf["cruise"], "min": vmin / perf["min_speed"], "max": vmax / perf["max_speed"],
			"turn": rate / perf["turn_rate"], "climb": best / perf["climb"]}
		_lines.append("F7 %s (%.3f kg): %s radius %.1f m" % [name, mass, str(ratios), radius])
		for k in ratios:
			near(ratios[k], 1.0, 0.15, "%s: emergent %s / SizeRules within 15%%" % [name, k])
		gt(cruise, prev_c, "%s cruises faster than the lighter bird" % name)
		gt(radius, prev_r, "%s turns wider than the lighter bird" % name)
		gt(vmax, prev_x, "%s dives faster than the lighter bird" % name)
		prev_c = cruise
		prev_r = radius
		prev_x = vmax


# --- F8: energy with drag and thrust off; fuzz with fresh seeds -------------------------
func test_f8_energy_and_fuzz_fresh_seeds() -> void:
	for row in _masses():
		var name: String = row[0]
		var mass: float = row[1]
		for seed in [101, 202, 303]:
			for dt: float in [DT, 1.0 / 90.0, 1.0 / 30.0]:
				var m := _m(mass)
				m.drag_enabled = false
				m.trim(Vector3(0, 3000, 0), 0.0, 0.0)
				var rng := RandomNumberGenerator.new()
				rng.seed = seed
				var e0 := FS.energy_height(m)
				var ke0 := m.velocity.length_squared() / (2.0 * G)
				var ws := WingState.new()
				var worst := 0.0
				var cmd_p := 0.0
				var cmd_r := 0.0
				for i in int(20.0 / dt):
					if i % int(0.5 / dt) == 0:
						cmd_p = rng.randf_range(-1.0, 1.0)
						cmd_r = rng.randf_range(-1.0, 1.0)
					ws.set_commands(cmd_p, cmd_r, 1.0, 0.0, 0.0)
					m.step(ws, null, dt)
					worst = maxf(worst, absf(FS.energy_height(m) - e0))
				var frac_total := worst / e0
				var frac_ke := worst / ke0
				_lines.append("F8 %s seed %d dt %.4f: worst |dE| %.4f m = %.4f %% of E(total, datum y=0), %.3f %% of KE height" % [name, seed, dt, worst, 100.0 * frac_total, 100.0 * frac_ke])
				lt(frac_ke, 0.02, "%s seed %d dt %.4f: energy drift within 2%% of the kinetic energy over 20 s" % [name, seed, dt])
		# Fuzz: 10k random frames, fresh seed, with NaN / inf / out-of-range inputs and dt spikes.
		var mf := _m(mass)
		mf.trim(Vector3(0, 3000, 0), 0.0, 0.0)
		var rngf := RandomNumberGenerator.new()
		rngf.seed = 9000 + int(mass * 1000)
		var wsf := WingState.new()
		var bad := 0
		var vmax_seen := 0.0
		var dts := [1e-5, 1e-4, 1.0 / 144.0, DT, 1.0 / 30.0, 0.1, 0.5, 2.0, 0.0, -0.1]
		for i in 10000:
			wsf.pitch = rngf.randf_range(-3, 3)
			wsf.roll = rngf.randf_range(-3, 3)
			wsf.ext_l = rngf.randf_range(-0.5, 1.5)
			wsf.ext_r = rngf.randf_range(-0.5, 1.5)
			wsf.flap_l = rngf.randf_range(-1, 3)
			wsf.flap_r = rngf.randf_range(-1, 3)
			wsf.up_l = rngf.randf_range(-1, 2)
			wsf.up_r = rngf.randf_range(-1, 2)
			wsf.flap_dir_l = Vector3(rngf.randf_range(-2, 2), rngf.randf_range(-2, 2), rngf.randf_range(-2, 2))
			wsf.flap_dir_r = Vector3.ZERO if rngf.randf() < 0.05 else Vector3(rngf.randf_range(-2, 2), rngf.randf_range(-2, 2), rngf.randf_range(-2, 2))
			wsf.stroke_period = rngf.randf_range(-1, 5)
			if rngf.randf() < 0.02:
				wsf.pitch = NAN
			if rngf.randf() < 0.02:
				wsf.flap_dir_l = Vector3(INF, 0, 0)
			if rngf.randf() < 0.01:
				wsf.stroke_period = INF
			var dt2: float = dts[rngf.randi_range(0, dts.size() - 1)] if rngf.randf() < 0.1 else DT
			mf.step(wsf, null, dt2)
			if not (FlightMath.vfinite(mf.position) and FlightMath.vfinite(mf.velocity) and is_finite(mf.theta + mf.phi + mf.chi + mf.alpha + mf.g_load + mf.lift_n)):
				bad += 1
			vmax_seen = maxf(vmax_seen, mf.airspeed())
			if mf.position.y < 100.0:
				mf.position.y = 3000.0
		_lines.append("F8 fuzz %s: non-finite ticks %d, max airspeed %.2f (V_max %.2f)" % [name, bad, vmax_seen, mf.params.v_max])
		eq(bad, 0, "%s: 10k fuzz frames stay finite" % name)
		lt(vmax_seen, 1.25 * mf.params.v_max, "%s: fuzz airspeed bounded (< 1.25 V_max)" % name)
