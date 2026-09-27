extends TestCase
## L1: FlightModel physics (FLIGHT_SPEC §14.3 FM-01...FM-10).
## Pure model, WingState commands, 72 Hz, `normal` assists unless stated.
## Covers F2 (AoA like an aircraft: balloon, nose-down), F3 (stall and
## recovery), F4 (coordinated turn, auto-level) at the model level.

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DT := FS.DT


# --- FM-01: trimmed neutral glide at cruise, all player sizes -------------
func test_fm01_trim_glide_all_sizes() -> void:
	for sp in FS.SP:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 40 * 72, FS.glide(0.0), null, rec)
		var perf := SizeRules.performance(m.params.mass)
		var v := FS.mean(rec.v, rec.at(30.0))
		var sink := -FS.mean(rec.vy, rec.at(30.0))
		var ld := sqrt(maxf(v * v - sink * sink, 0.0)) / sink
		var p := m.params
		var ld_an := p.cl_n / (p.cd0 + p.k_i * p.cl_n * p.cl_n)
		between(v / perf["cruise"], 0.97, 1.03, "%s trim V / cruise" % sp)
		between(ld / ld_an, 0.90, 1.10, "%s glide ratio vs analytic polar" % sp)
		metric("%s_v_over_cruise" % sp, v / perf["cruise"])
		metric("%s_sink" % sp, sink)
		metric("%s_ld" % sp, ld)


# --- FM-02: slowest steady flight (pitch 0.88, protected) ----------------
func test_fm02_slowest_flight() -> void:
	for sp in FS.SP:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.88)
		var rec := FS.Rec.new()
		FS.run(m, 30 * 72, FS.glide(0.88), null, rec)
		var v := FS.mean(rec.v, rec.at(20.0))
		between(v / m.params.v_min, 1.00, 1.15, "%s slowest V / V_min" % sp)
		eq(rec.count("stall"), 0, "%s never stalls at pitch 0.88" % sp)
		metric("%s_vslow_over_vmin" % sp, v / m.params.v_min)


# --- FM-03: the balloon (F2) -----------------------------------------------
static func balloon(sp: StringName, pitch: float, seconds: float) -> Array:
	var m := FS.model(sp)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var rec := FS.Rec.new()
	FS.run(m, int(seconds * 72), FS.glide(pitch), null, rec)
	return [m, rec]


func test_fm03_balloon_rises_then_settles_slower() -> void:
	for sp in FS.S3:
		var m0 := FS.model(sp)
		var t_ph := m0.params.t_ph
		var r := balloon(sp, 0.5, 3.0 * t_ph + 5.0)
		var m: FlightModel = r[0]
		var rec: FS.Rec = r[1]
		var p := m.params
		var v0: float = m0.trim_solution(0.0)["v"]
		var v_trim: float = m0.trim_solution(0.5)["v"]
		var g_trim: float = rad_to_deg(m0.trim_solution(0.5)["gamma"])
		var h0 := 500.0
		var ipk := FS.argmax(rec.y)
		var rise := rec.y[ipk] - h0
		var v_lo := FS.minv(rec.v)
		var t_pk := rec.t[ipk]
		var v3 := rec.v[rec.at(3.0)]
		var v_end := rec.v[rec.size() - 1]
		var settle := _settle_time(rec, v_trim, g_trim, 0.05, 2.0)
		gt(rise / p.span, 5.0, "%s balloon peak rise in spans" % sp)
		gt(rise, 0.4 * (v0 * v0 - v_lo * v_lo) / (2.0 * FS.G), "%s rise >= 40%% of the kinetic energy traded" % sp)
		between(t_pk, 0.8, 4.0, "%s balloon peak time (s)" % sp)
		lt(v3 / v0, 0.70, "%s airspeed bleeds: V(3 s)/V0" % sp)
		near(v_end / v_trim, 1.0, 0.05, "%s settles at the slower trim of pitch 0.5" % sp)
		lt(v_trim / v0, 0.8, "%s new trim is slower than cruise" % sp)
		lt(settle, 0.8 * t_ph, "%s settled within 0.8 T_ph (phugoid damped)" % sp)
		eq(rec.count("stall"), 0, "%s never stalls in the balloon" % sp)
		gt(v_lo / p.v_min, 0.85, "%s transient V_lo / V_min" % sp)
		lt(rec.y[rec.size() - 1], rec.y[ipk], "%s the rise is temporary" % sp)
		metric("%s_rise_spans" % sp, rise / p.span)
		metric("%s_t_peak" % sp, t_pk)
		metric("%s_v3_over_v0" % sp, v3 / v0)
		metric("%s_settle_over_tph" % sp, settle / t_ph)
		metric("%s_vlo_over_vmin" % sp, v_lo / p.v_min)
		metric("%s_energy_fraction" % sp, rise / ((v0 * v0 - v_lo * v_lo) / (2.0 * FS.G)))


## Last time the run was outside the settle band (time from which it stays in).
func _settle_time(rec: FS.Rec, v_trim: float, g_trim: float, v_tol: float, g_tol_deg: float) -> float:
	var last := 0.0
	for i in rec.size():
		if absf(rec.v[i] / v_trim - 1.0) > v_tol or absf(rec.gam[i] - g_trim) > g_tol_deg:
			last = rec.t[i]
	return last


# --- FM-04: nose-down (F2) ---------------------------------------------------
func test_fm04_nose_down_speeds_up() -> void:
	for sp in FS.S3:
		var m0 := FS.model(sp)
		var r := balloon(sp, -0.5, 3.0 * m0.params.t_ph + 5.0)
		var rec: FS.Rec = r[1]
		var v0: float = m0.trim_solution(0.0)["v"]
		var v_trim: float = m0.trim_solution(-0.5)["v"]
		gt(rec.v[rec.at(3.0)] / v0, 1.07, "%s V(3 s)/V0 after nose-down" % sp)
		lt(rec.gam[rec.at(1.0)], -8.0, "%s nose drops: gamma(1 s) deg" % sp)
		near(rec.v[rec.size() - 1] / v_trim, 1.0, 0.05, "%s settles at the faster trim of pitch -0.5" % sp)
		between(v_trim / v0, 1.3, 1.55, "%s half-down trims ~1.41x faster" % sp)
		metric("%s_sag_v3" % sp, rec.v[rec.at(3.0)] / v0)
		metric("%s_sag_gamma1" % sp, rec.gam[rec.at(1.0)])


# --- FM-05: stall and recovery (F3) ------------------------------------------
func test_fm05_stall_and_recovery() -> void:
	for sp in FS.S3:
		# (a) trim at pitch 0.8, hold full up 2 s, release to 0.
		var m := FS.model(sp)
		var p := m.params
		m.trim(Vector3(0, 500, 0), 0.0, 0.8)
		var tr0 := m.trim_solution(0.0)
		# V_t is the trim (cruise) speed the recovery returns to.
		var v_t: float = tr0["v"]
		var rec := FS.Rec.new()
		FS.run(m, 2 * 72, FS.glide(1.0), null, rec)
		var i_rel := rec.size()
		FS.run(m, int(3.0 * p.t_ph * 72), FS.glide(0.0), null, rec)
		var t_st := -1.0
		for e in rec.events:
			if e[1] == "stall":
				t_st = e[0]
				break
		check(t_st > 0.0, "%s (a) full-up hold stalls" % sp)
		lt(t_st, 1.0, "%s (a) stall within 1 s of the deliberate hold" % sp)
		var stalls_hold := 0
		for e in rec.events:
			if e[1] == "stall" and e[0] <= 2.0:
				stalls_hold += 1
		eq(stalls_hold, 1, "%s (a) exactly one stall during the 2 s hold" % sp)
		var t_rec := _recovered_at(rec, i_rel, float(tr0["v"]), rad_to_deg(tr0["gamma"]))
		check(t_rec >= 0.0, "%s (a) recovers after release" % sp)
		lt(t_rec - rec.t[i_rel - 1], 0.8 * p.t_ph, "%s (a) recovery time <= 0.8 T_ph" % sp)
		# Height lost from release to the minimum before recovery.
		var i_recov := rec.at(t_rec) if t_rec >= 0.0 else rec.size() - 1
		var loss := rec.y[i_rel - 1] - FS.minv(rec.y, i_rel - 1, i_recov + 1)
		lt(loss, 0.6 * v_t * v_t / FS.G, "%s (a) height lost in the stall <= 0.6 V_t^2/g" % sp)
		metric("%s_a_t_stall" % sp, t_st)
		metric("%s_a_recovery_tph" % sp, (t_rec - rec.t[i_rel - 1]) / p.t_ph)
		metric("%s_a_loss_v2g" % sp, loss / (v_t * v_t / FS.G))
		# (b) from cruise hold full up 3 s, release.
		var m2 := FS.model(sp)
		m2.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec2 := FS.Rec.new()
		FS.run(m2, 3 * 72, FS.glide(1.0), null, rec2)
		var i2 := rec2.size()
		FS.run(m2, int(3.0 * p.t_ph * 72), FS.glide(0.0), null, rec2)
		var n_st := rec2.count("stall")
		between(n_st, 1, 2, "%s (b) stalls while held, at most one per 1.5 s" % sp)
		var t_rec2 := _recovered_at(rec2, i2, float(tr0["v"]), rad_to_deg(tr0["gamma"]))
		check(t_rec2 >= 0.0 and t_rec2 - rec2.t[i2 - 1] <= 0.8 * p.t_ph, "%s (b) recovered <= 0.8 T_ph (got %.2f s)" % [sp, t_rec2 - rec2.t[i2 - 1]])
		# Lift collapses in the stall: mean CL while stalled vs the peak before.
		# 0.62 (round 1: 0.8, which the stall FSM's nose-drop alone met with
		# the aerodynamic separation removed; measured 0.56-0.57, a halved
		# separation gives 0.64-0.66). FM-05c pins the lift curve directly.
		var i_st := rec.at(t_st)
		var cl_peak := FS.maxv(rec.cl, 0, i_st + 1)
		var cl_sum := 0.0
		var n_cl := 0
		var sig_max := 0.0
		var cl_sep_max := 0.0
		for i in range(i_st, i_rel):
			sig_max = maxf(sig_max, rec.sig[i])
			if rec.stalled[i] == 1 and rec.t[i] - t_st >= 0.2:
				cl_sum += rec.cl[i]
				n_cl += 1
			if rec.stalled[i] == 1 and rec.sig[i] >= 0.9:
				cl_sep_max = maxf(cl_sep_max, rec.cl[i])
		var lift_drop := (cl_sum / maxf(n_cl, 1)) / cl_peak
		lt(lift_drop, 0.62, "%s lift coefficient collapses in the stall (stalled mean / peak)" % sp)
		gt(cl_peak / p.cl_max, 0.9, "%s the wing reached CL_max before stalling" % sp)
		gt(sig_max, 0.9, "%s the flow separates while stalled (separation blend)" % sp)
		lt(cl_sep_max / p.cl_max, 0.66, "%s once separated, CL never exceeds 0.66 CL_max while stalled" % sp)
		metric("%s_b_stalls" % sp, n_st)
		metric("%s_cl_stalled_over_peak" % sp, lift_drop)
		metric("%s_cl_separated_max_over_clmax" % sp, cl_sep_max / p.cl_max)


# --- FM-05c: the lift curve through the stall (F3, aerodynamics alone) --------
## The model's own lift curve, read without the stall FSM: attached flow
## reaches CL_max at alpha_s; separated flow (the settled stall) collapses
## to the post-stall plateau at the same angles; past alpha_s + 6 deg the
## geometry separates the flow even without a stall latch. Every size.
func test_fm05c_lift_curve_collapses_past_the_stall() -> void:
	for sp in FS.SP:
		var m := FS.model(sp)
		var p := m.params
		var a_s := p.alpha_s
		near(m.lift_coefficient(a_s, 0.0) / p.cl_max, 1.0, 0.02, "%s attached: CL(alpha_s) = CL_max" % sp)
		var worst_sep := 0.0
		var worst_geo := 0.0
		for k in 21:
			var a := a_s + deg_to_rad(10.0) * k / 20.0
			worst_sep = maxf(worst_sep, m.lift_coefficient(a, 1.0) / p.cl_max)
			if a >= a_s + deg_to_rad(6.0):
				worst_geo = maxf(worst_geo, m.lift_coefficient(a, 0.0) / p.cl_max)
		lt(worst_sep, 0.65, "%s separated: CL <= 0.65 CL_max for alpha_s .. alpha_s + 10 deg" % sp)
		lt(worst_geo, 0.65, "%s geometric separation: CL <= 0.65 CL_max past alpha_s + 6 deg" % sp)
		# Below the stall the separation changes nothing the flow is attached to.
		near(m.lift_coefficient(0.5 * a_s, 0.0), p.a * 0.5 * a_s, 1e-6, "%s attached slope below the stall" % sp)
		check(m.sigma == 0.0, "%s reading the curve leaves the state alone" % sp)
		metric("%s_cl_sep_over_clmax" % sp, worst_sep)
		metric("%s_cl_geo_over_clmax" % sp, worst_geo)


## First time after i0 that the bird is within 5 deg of the trim gamma and
## 15% of the trim V and not stalled, and stays so for 0.5 s.
func _recovered_at(rec: FS.Rec, i0: int, v_trim: float, g_trim: float) -> float:
	var run_start := -1
	for i in range(i0, rec.size()):
		var ok := absf(rec.gam[i] - g_trim) <= 5.0 and absf(rec.v[i] / v_trim - 1.0) <= 0.15 and rec.stalled[i] == 0
		if ok:
			if run_start < 0:
				run_start = i
			if rec.t[i] - rec.t[run_start] >= 0.5:
				return rec.t[run_start]
		else:
			run_start = -1
	return -1.0


# --- FM-06: stall protection ---------------------------------------------------
func test_fm06_stall_protection() -> void:
	for sp in FS.S3:
		# (c) full-up pulses of 0.25 s every 0.5 s for 6 s.
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 6 * 72, func(i: int, ws: WingState) -> void:
			ws.set_commands(1.0 if (i % 36) < 18 else 0.0, 0.0, 1.0, 0.0, 0.0), null, rec)
		eq(rec.count("stall"), 0, "%s (c) short full-up pulses never stall" % sp)
		# (d) pitch 0.85 held 6 s from cruise.
		var m2 := FS.model(sp)
		m2.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec2 := FS.Rec.new()
		FS.run(m2, 6 * 72, FS.glide(0.85), null, rec2)
		eq(rec2.count("stall"), 0, "%s (d) pitch 0.85 never stalls" % sp)
		# Warning: trimmed at 0.85 buffets, at 0.6 it does not.
		var m3 := FS.model(sp)
		m3.trim(Vector3(0, 500, 0), 0.0, 0.85)
		FS.run(m3, 5 * 72, FS.glide(0.85))
		gt(m3.stall_warning, 0.30, "%s stall warning at trimmed pitch 0.85" % sp)
		var m4 := FS.model(sp)
		m4.trim(Vector3(0, 500, 0), 0.0, 0.6)
		FS.run(m4, 5 * 72, FS.glide(0.6))
		lt(m4.stall_warning, 0.05, "%s no warning at pitch 0.6" % sp)
		metric("%s_warn_085" % sp, m3.stall_warning)
		# (e) sim preset: steady pitch 0.9 is stalled; a 1.0 step stalls fast.
		var m5 := FS.model(sp, 0)
		m5.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec5 := FS.Rec.new()
		FS.run(m5, 8 * 72, FS.glide(0.9), null, rec5)
		gt(rec5.count("stall"), 0, "%s (e) sim preset: pitch 0.9 stalls" % sp)
		var m6 := FS.model(sp, 0)
		m6.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec6 := FS.Rec.new()
		FS.run(m6, 72, FS.glide(1.0), null, rec6)
		var t_st := -1.0
		for e in rec6.events:
			if e[1] == "stall":
				t_st = e[0]
				break
		check(t_st > 0.0 and t_st <= 0.5, "%s (e) sim preset: full-up step stalls within 0.5 s (got %.2f)" % [sp, t_st])
		metric("%s_sim_t_stall" % sp, t_st)


# --- FM-07: roll response ------------------------------------------------------
const T90_GOLDEN := {&"sparrow": 0.43, &"starling": 0.51, &"pigeon": 0.61, &"crow": 0.65, &"gull": 0.69, &"eagle": 0.81}

func test_fm07_roll_response() -> void:
	var prev := 0.0
	for sp in FS.SP:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 4 * 72, FS.glide(0.0, 0.6), null, rec)
		var tgt := rad_to_deg(0.6 * m.params.phi_max)
		var t90 := -1.0
		for i in rec.size():
			if rec.phi[i] >= 0.9 * tgt:
				t90 = rec.t[i]
				break
		var over := FS.maxv(rec.phi) / tgt - 1.0
		gt(t90, prev, "%s t90 strictly increases with size" % sp)
		lt(over, 0.05, "%s bank overshoot" % sp)
		if T90_GOLDEN.has(sp):
			near(t90, T90_GOLDEN[sp], 0.2 * T90_GOLDEN[sp], "%s t90 vs golden" % sp)
		prev = t90
		metric("%s_t90" % sp, t90)


# --- FM-08: coordinated turn (F4) -----------------------------------------------
func test_fm08_coordinated_turn() -> void:
	for sp in FS.S3:
		for roll in [0.6, 1.0]:
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var sink0 := -m.velocity.y
			var rec := FS.Rec.new()
			FS.run(m, 6 * 72, FS.glide(0.0, roll), null, rec)
			var ratio_sum := 0.0
			var n := 0
			var worst := 0.0
			var slip := 0.0
			for i in range(rec.at(1.5), rec.size()):
				var ph := deg_to_rad(rec.phi[i])
				var ideal := FS.G * tan(absf(ph)) / rec.v[i]
				var r := absf(rec.yaw_rate[i]) / ideal
				ratio_sum += r
				n += 1
				worst = maxf(worst, absf(r - 1.0))
				slip = maxf(slip, absf(rec.dpsi[i]))
			var ratio := ratio_sum / n
			var tol := 0.03 if roll < 0.9 else 0.05
			near(ratio, 1.0, tol, "%s roll %.1f: heading rate / (g tan(bank)/V)" % [sp, roll])
			lt(worst, 0.2, "%s roll %.1f: every sample within 20%% of g tan(bank)/V" % [sp, roll])
			lt(slip, 0.1, "%s roll %.1f: sideslip (deg)" % [sp, roll])
			check(rec.yaw_rate[rec.size() - 1] < 0.0, "%s positive roll turns right (heading decreases)" % sp)
			if roll < 0.9:
				var sink := -FS.mean(rec.vy, rec.at(3.0))
				lt(sink / sink0, 1.25, "%s sink in a 0.6 turn vs straight glide" % sp)
				metric("%s_sink_ratio_06" % sp, sink / sink0)
			metric("%s_ratio_%.1f" % [sp, roll], ratio)
			metric("%s_slip_%.1f" % [sp, roll], slip)
		# Full input with altitude-holding flapping: SizeRules turn rate.
		var mf := FS.model(sp)
		mf.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var recf := FS.Rec.new()
		# The bot's laws (FLIGHT_SPEC 14.4): altitude on flap effort (PI) and
		# speed on pitch (the wrist pitch also tilts the stroke forward).
		var st := {"i": 0.0, "iv": 0.0}
		var vc := mf.params.v_c
		FS.run(mf, 3 * 72, func(i: int, ws: WingState) -> void:
			var e: float = clampf(0.35 + 0.25 * (0.0 - mf.velocity.y) + st["i"], 0.0, 1.0)
			st["i"] = clampf(st["i"] + 0.05 * (0.0 - mf.velocity.y) * DT, -0.4, 0.6)
			var ev: float = (mf.airspeed() - vc) / vc
			st["iv"] = clampf(st["iv"] + 0.3 * ev * DT, -0.3, 0.3)
			var pc: float = clampf(2.0 * ev + st["iv"], -1.0, 1.0)
			ws.set_commands(pc, 1.0, 1.0, e, i * DT, 1.0, 0, NAN, mf.params.x), null, recf)
		var rate := absf(FS.mean(recf.yaw_rate, recf.at(1.0), recf.at(3.0)))
		var perf_rate: float = SizeRules.performance(mf.params.mass)["turn_rate"]
		between(rate / perf_rate, 0.85, 1.10, "%s full-input flapping turn rate / SizeRules.turn_rate" % sp)
		metric("%s_full_rate_over_perf" % sp, rate / perf_rate)


# --- FM-09: auto-level (F4 neutral input returns wings level) -------------
func test_fm09_auto_level() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 3 * 72, FS.glide(0.0, 0.6), null, rec)
		var t90 := -1.0
		var tgt := rad_to_deg(0.6 * m.params.phi_max)
		for i in rec.size():
			if rec.phi[i] >= 0.9 * tgt:
				t90 = rec.t[i]
				break
		var i_rel := rec.size()
		FS.run(m, 3 * 72, FS.glide(0.0, 0.0), null, rec)
		var t_level := -1.0
		var t_straight := -1.0
		for i in range(i_rel, rec.size()):
			if t_level < 0.0 and absf(rec.phi[i]) < 3.0:
				t_level = rec.t[i] - rec.t[i_rel - 1]
			if t_straight < 0.0 and absf(rad_to_deg(rec.yaw_rate[i])) < 2.0:
				t_straight = rec.t[i] - rec.t[i_rel - 1]
		check(t_level >= 0.0 and t_level <= 1.5 * t90, "%s wings level (<3 deg) within 1.5 t90 (%.2f vs %.2f)" % [sp, t_level, 1.5 * t90])
		check(t_straight >= 0.0 and t_straight <= 1.6 * t90, "%s turn stops (<2 deg/s) within 1.6 t90 (%.2f)" % [sp, t_straight])
		lt(absf(rec.phi[rec.size() - 1]), 0.5, "%s stays level" % sp)
		metric("%s_level_over_t90" % sp, t_level / t90)


# --- FM-10: adverse yaw exists, and the auto-rudder cancels it --------------
func test_fm10_rudder_cancels_adverse_yaw() -> void:
	for sp in FS.S3:
		var peaks := []
		for kr in [0.0, 1.0]:
			var m := FS.model(sp)
			m.k_rud = kr
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var rec := FS.Rec.new()
			FS.run(m, 2 * 72, FS.glide(0.0, 0.8), null, rec)
			var pk := 0.0
			for d in rec.dpsi:
				if absf(d) > absf(pk):
					pk = d
			peaks.append(pk)
		gt(peaks[0], 0.4, "%s k_rud 0: adverse yaw, nose left in a right roll (deg)" % sp)
		lt(absf(peaks[1]), 0.05, "%s k_rud 1: auto-rudder cancels sideslip (deg)" % sp)
		metric("%s_adverse_deg" % sp, peaks[0])


# --- FM-11: flap force direction, white box (F1) ------------------------------
func test_fm11_flap_impulse_direction() -> void:
	for sp in FS.S3:
		for bank_deg in [0.0, 30.0]:
			for tilt in [0.0, 17.0, 35.0, -20.0]:
				var m := FS.model(sp)
				m.trim(Vector3(0, 500, 0), 0.0, 0.0)
				var roll := deg_to_rad(bank_deg) / m.params.phi_max
				if bank_deg > 0.0:
					FS.run(m, 3 * 72, FS.glide(0.0, roll))
				var acc := Vector3.ZERO   # (forward, up, side) components
				var cmd := FS.flap(m, 0.0, roll, 1.0, tilt)
				var ws := WingState.new()
				var env := FlightEnv.new()
				for i in 72:
					cmd.call(i, ws)
					var i0 := m.flap_impulse
					m.step(ws, env, DT)
					var d := m.flap_impulse - i0
					var fr := FS.frame(m)
					acc += Vector3(d.dot(fr[0]), d.dot(fr[1]), d.dot(fr[2]))
				var ang := rad_to_deg(atan2(acc.x, acc.y))
				var side := rad_to_deg(atan2(acc.z, acc.y))
				near(ang, tilt, 1.0, "%s bank %d: impulse tilt toward the heading for flap tilt %d" % [sp, bank_deg, tilt])
				lt(absf(side), 1.0, "%s bank %d tilt %d: impulse lies in the banked plane (deg)" % [sp, bank_deg, tilt])
				if tilt == 0.0 and bank_deg == 0.0:
					metric("%s_flat_impulse_deg" % sp, ang)
				if tilt == 17.0 and bank_deg == 0.0:
					gt(acc.x / acc.y, 0.25, "%s wings pitched forward: forward >= 25%% of vertical" % sp)
					metric("%s_fwd_over_up_17" % sp, acc.x / acc.y)


# --- FM-11b: the upstroke's force, from the impulse the model applies (F1) --
## Round 3 (verifier): FM-11 and flap_detector f1 derived the upstroke share
## from params.up_gain, so a model whose force ignored up_gain passed both.
## Here the reference stroke's WingState stream is flown with the upstroke
## commands alone and with the downstroke commands alone.
func test_fm11b_upstroke_force_from_the_applied_impulse() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		var ws := WingState.new()
		var cmd := FS.flap(m, 0.0, 0.0, 1.0)
		var r := FS.upstroke_split(sp, func(i: int) -> WingState:
			cmd.call(i, ws)
			return ws, 5 * 72, func(i: int) -> bool: return fposmod(i * DT, 1.0) < 0.5)
		gt(float(r["down"]), 0.0, "%s: the downstroke commands lift" % sp)
		if float(r["up_gain"]) > 0.0:
			between(float(r["up_over_down"]), 0.0, 0.35, "%s: the upstroke's own force lifts at most 35%% of the downstroke's (applied impulse)" % sp)
		else:
			between(float(r["up_over_down"]), -0.15, 0.0, "%s: a big bird's upstroke opposes slightly (applied impulse)" % sp)
		# In time the downstroke's force outlasts it (tau_f smoothing), yet the
		# arms' fall still carries more of the impulse than their rise.
		lt(float(r["rise_over_fall"]), 1.0, "%s: more flap impulse while the arms fall than while they rise" % sp)
		metric("%s_upstroke" % sp, {"up_over_down": r["up_over_down"], "rise_over_fall": r["rise_over_fall"], "up_gain": r["up_gain"]})


# --- FM-12: flap direction behaviour (F1) ---------------------------------------
func test_fm12_flap_direction_behaviour() -> void:
	for sp in FS.SP:
		var res := {}
		for mode in ["flat", "fwd", "back"]:
			var m := FS.model(sp)
			m.reset(Vector3(0, 500, 0), Vector3.ZERO, 0.0)
			var p := 0.0 if mode == "flat" else (-1.0 if mode == "fwd" else 1.0)
			var rec := FS.Rec.new()
			FS.run(m, 3 * 72, FS.flap(m, p, 0.0, 1.0), null, rec)
			var fh := FlightMath.yaw_forward(0.0)
			res[mode] = [rec.y[rec.size() - 1] - 500.0, m.velocity.dot(fh), FS.horiz_speed_mean(rec, 2.0)]
		var flat: Array = res["flat"]
		var fwd: Array = res["fwd"]
		var back: Array = res["back"]
		if sp == &"sparrow":
			gt(flat[0], 1.0, "sparrow flat strokes from rest rise (m in 3 s)")
		if sp in [&"sparrow", &"starling"]:
			lt(flat[2], 0.8, "%s flat strokes: horizontal drift (m/s)" % sp)
		gt(fwd[1], 5.0, "%s full-forward strokes: forward speed (m/s)" % sp)
		lt(back[1], 0.0, "%s full-back strokes: moves backward" % sp)
		metric("%s_flat_rise" % sp, flat[0])
		metric("%s_fwd_speed" % sp, fwd[1])
		metric("%s_back_speed" % sp, back[1])
	# (b) from trim at 40% effort: forward gesture vs flat = cruise.
	for sp in FS.SP:
		var out := []
		for p in [-0.49, 0.0]:
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var rec := FS.Rec.new()
			FS.run(m, 20 * 72, FS.flap(m, p, 0.0, 0.4), null, rec)
			out.append([FS.mean(rec.vh, rec.at(15.0)), FS.mean(rec.vy, rec.at(15.0))])
		var vc := m_vc(sp)
		gt((out[0][0] - out[1][0]) / vc, 0.15, "%s forward gesture gains horizontal speed (x V_c)" % sp)
		lt(absf(out[0][1]), 1.5, "%s flapping forward at 40%% is near-level cruise (|vz|)" % sp)
		metric("%s_fwd_gain" % sp, (out[0][0] - out[1][0]) / vc)
		metric("%s_fwd_vz" % sp, out[0][1])


func m_vc(sp: StringName) -> float:
	return SizeRules.performance(FlightParams.species_mass(sp))["cruise"]


# --- FM-14: hover capability and the endurance cap ----------------------------------
func test_fm14_hover_capability() -> void:
	var ref_force := {}
	for sp in [&"sparrow", &"starling", &"pigeon", &"crow", &"eagle"]:
		for kind in ["ref", "frantic"]:
			var m := FS.model(sp)
			m.reset(Vector3(0, 500, 0), Vector3.ZERO, 0.0)
			var tab := FlapDetector.reference_table(m.params.x) if kind == "ref" \
				else FlapDetector.stroke_table(m.params.x, deg_to_rad(30.0), 2.2, 0.5, false, 72.0)
			var hz := 1.0 if kind == "ref" else 2.2
			var rec := FS.Rec.new()
			FS.run(m, 7 * 72, FS.table_flap(tab, hz, 0.5, 0.0), null, rec)
			var i2 := rec.at(2.0)
			var vz := FS.mean(rec.vy, i2)
			var drift := FS.horiz_speed_mean(rec, 2.0)
			var fy := FS.mean(rec.flap_fy, i2) / (m.params.mass * FS.G)
			if kind == "ref":
				ref_force[sp] = fy
			else:
				lt(fy / ref_force[sp], 1.20, "%s frantic flapping force <= 1.2x the reference (endurance cap)" % sp)
				metric("%s_frantic_force_ratio" % sp, fy / ref_force[sp])
			if sp == &"sparrow":
				gt(vz, 1.0, "sparrow %s: hover-climbs (vz)" % kind)
				lt(drift, 1.0, "sparrow %s: stays in place (drift)" % kind)
			elif sp == &"starling":
				gt(vz, 0.15, "starling %s: hover-climbs slowly" % kind)
				lt(drift, 1.0, "starling %s: drift" % kind)
			else:
				# Never hold position: never (vz >= 0 and drift < 1.5 m/s) over 2-7 s.
				check(not (vz >= 0.0 and drift < 1.5), "%s %s: cannot hover (vz %.2f, drift %.2f)" % [sp, kind, vz, drift])
			metric("%s_%s_vz" % [sp, kind], vz)
			metric("%s_%s_drift" % [sp, kind], drift)


# --- FM-15 / FM-16: tuck dive toward V_max, spread to pull out (F5) --------------
func test_fm15_fm16_tuck_dive_and_pullout() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		var p := m.params
		m.trim(Vector3(0, 2000, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 20 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec)
		var t95 := -1.0
		for i in rec.size():
			if rec.v[i] >= 0.95 * p.v_max:
				t95 = rec.t[i]
				break
		check(t95 > 0.0 and t95 <= 8.0, "%s tuck dive reaches 0.95 V_max within 8 s (%.2f)" % [sp, t95])
		lt(FS.maxv(rec.v) / p.v_max, 1.03, "%s never exceeds 1.03 V_max (governor)" % sp)
		metric("%s_t95" % sp, t95)
		metric("%s_dive_vmax_ratio" % sp, FS.maxv(rec.v) / p.v_max)
		# FM-16 pull-out from the V_max dive: spread, pitch +0.5.
		var h0 := m.position.y
		var i0 := rec.size()
		FS.run(m, int(1.5 * p.t_ph * 72) + 72, FS.glide(0.5, 0.0, 1.0), null, rec)
		var i_bottom := i0
		for i in range(i0, rec.size()):
			if rec.gam[i] >= 0.0:
				i_bottom = i
				break
		var loss := h0 - FS.minv(rec.y, i0)
		var ideal := p.v_max * p.v_max / ((p.n_max - 1.0) * FS.G)
		var g_pk := FS.maxv(rec.g_load, i0)
		lt(g_pk, p.n_max + 0.2, "%s pull-out peak g <= n_max + 0.2" % sp)
		lt(loss, 1.25 * ideal, "%s pull-out height loss vs the ideal circle" % sp)
		lt(loss / p.span, 75.0, "%s pull-out height loss in spans" % sp)
		check(i_bottom > i0, "%s the path comes back to level" % sp)
		metric("%s_pullout_m" % sp, loss)
		metric("%s_pullout_spans" % sp, loss / p.span)
		metric("%s_pullout_g" % sp, g_pk)
		metric("%s_pullout_over_ideal" % sp, loss / ideal)
		# FM-15 recovery: from the dive, release to neutral: recovered <= 1.5 T_ph.
		var m2 := FS.model(sp)
		m2.trim(Vector3(0, 2000, 0), 0.0, 0.0)
		FS.run(m2, 10 * 72, FS.glide(-1.0, 0.0, 0.0))
		var rec2 := FS.Rec.new()
		FS.run(m2, int(3.0 * p.t_ph * 72), FS.glide(0.0), null, rec2)
		var tr0 := m2.trim_solution(0.0)
		var t_rec := _recovered_at(rec2, 0, float(tr0["v"]), rad_to_deg(tr0["gamma"]))
		check(t_rec >= 0.0 and t_rec <= 1.5 * p.t_ph, "%s dive recovery <= 1.5 T_ph (%.2f s)" % [sp, t_rec])
		metric("%s_dive_recovery_tph" % sp, t_rec / p.t_ph)


# --- FM-17: level flapping costs 30-40% of the reference effort --------------------
## "Forward gesture" = wrists rolled forward: the full 20 deg twist (pitch
## -0.49, 17 deg tilt) and a gentler 12 deg twist (pitch -0.30, 10 deg). The
## player picks the cheaper one; for big birds the full twist cruises at
## ~1.2 V_c where muscle power (P_spec) caps the stroke (see FLIGHT.md).
func test_fm17_level_flapping_effort() -> void:
	for sp in (FS.S3 if Paths.arg("full", "") != "" else [&"pigeon"]):
		var level := -1.0
		for k in range(1, 14):
			var e := 0.1 * k
			var ok := false
			for g in [-0.49, -0.30]:
				var m := FS.model(sp)
				m.trim(Vector3(0, 500, 0), 0.0, 0.0)
				var rec := FS.Rec.new()
				FS.run(m, 25 * 72, FS.flap(m, g, 0.0, e), null, rec)
				if FS.mean(rec.vy, rec.at(15.0)) >= 0.0:
					ok = true
					break
			if ok:
				level = e
				break
		check(level > 0.0 and level <= 0.45 + 1e-6, "%s smallest effort holding altitude <= 0.45 (got %.1f)" % [sp, level])
		metric("%s_level_effort" % sp, level)


# --- FM-18: one-wing flap and one-wing fold ---------------------------------------
func test_fm18_one_wing_flap_and_fold() -> void:
	for sp in FS.S3:
		var out := {}
		for kind in ["none", "left", "both"]:
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var h0 := m.heading()
			var rec := FS.Rec.new()
			var x := m.params.x
			FS.run(m, 72, func(i: int, ws: WingState) -> void:
				var e := 0.0 if kind == "none" else 1.0
				ws.set_commands(0.0, 0.0, 1.0, e, i * DT, 1.0, -1 if kind == "left" else 0, 10.0, x), null, rec)
			FS.run(m, 36, FS.glide(0.0), null, rec)
			var dh := FlightMath.wrap_angle(rec.heading[rec.at(1.0)] - h0)
			out[kind] = [dh, FS.maxv(rec.phi), FS.maxv(FS.scale(rec.dpsi, -1.0)), FS.maxv(rec.dpsi), m.velocity.length()]
		var left: Array = out["left"]
		lt(rad_to_deg(left[0]), -3.0, "%s one left stroke turns right (heading change deg)" % sp)
		between(left[1], 5.0, 12.0, "%s one-wing flap peak bank (deg)" % sp)
		lt(maxf(left[2], left[3]), 1.5, "%s one-wing flap sideslip stays small (deg)" % sp)
		var dv_one: float = left[4] - out["none"][4]
		var dv_both: float = out["both"][4] - out["none"][4]
		between(dv_one / dv_both, 0.35, 0.85, "%s one-wing speed gain vs a symmetric stroke" % sp)
		metric("%s_one_wing_dheading" % sp, rad_to_deg(left[0]))
		metric("%s_one_wing_bank" % sp, left[1])
		metric("%s_one_wing_dv_ratio" % sp, dv_one / dv_both)
		# One-wing fold (right wing at 0.3): rolls toward the folded wing.
		var m2 := FS.model(sp)
		m2.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec2 := FS.Rec.new()
		FS.run(m2, 2 * 72, func(_i: int, ws: WingState) -> void:
			ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
			ws.ext_r = 0.3, null, rec2)
		gt(FS.maxv(rec2.phi), 10.0, "%s right-wing fold rolls right (deg)" % sp)


# --- FM-19 / FM-20: updrafts lift a glider (F6) ------------------------------------
func test_fm19_uniform_updraft_climbs_without_flapping() -> void:
	for sp in FS.S3:
		var env := FlightEnv.uniform(Vector3(0, 3, 0))
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 30 * 72, FS.glide(0.0), env, rec)
		var climb := FS.mean(rec.vy, rec.at(15.0))
		gt(climb, 1.0, "%s neutral glide in a 3 m/s updraft climbs (m/s)" % sp)
		eq(FS.maxv(rec.flap_l), 0.0, "%s no flapping" % sp)
		near(float(m.telemetry()["in_updraft"]), 3.0, 0.01, "%s in_updraft telemetry" % sp)
		var m2 := FS.model(sp)
		m2.trim(Vector3(0, 500, 0), 0.0, 0.6)
		var rec2 := FS.Rec.new()
		FS.run(m2, 30 * 72, FS.glide(0.6, deg_to_rad(30.0) / m2.params.phi_max), env, rec2)
		var climb2 := FS.mean(rec2.vy, rec2.at(15.0))
		gt(climb2, 1.7, "%s slow circling at 30 deg bank climbs (m/s)" % sp)
		metric("%s_updraft_neutral" % sp, climb)
		metric("%s_updraft_circling" % sp, climb2)


static func bell_thermal(core: float, radius: float) -> Callable:
	return func(pos: Vector3) -> Vector3:
		var r2 := (pos.x * pos.x + pos.z * pos.z) / (radius * radius)
		if r2 >= 1.0:
			return Vector3.ZERO
		return Vector3(0.0, core * pow(1.0 - r2, 2.0), 0.0)


static func thermal_circle(sp: StringName, seconds: float, rec: FS.Rec) -> FlightModel:
	var m := FS.model(sp)
	var env := FlightEnv.new()
	env.wind_fn = bell_thermal(4.0, 44.0)
	var tr := m.trim_solution(0.6)
	var v: float = tr["v"]
	var rad := v * v / (FS.G * tan(deg_to_rad(30.0)))
	m.trim(Vector3(-rad, 300, 0), 0.0, 0.6)
	FS.run(m, int(seconds * 72), FS.glide(0.6, deg_to_rad(30.0) / m.params.phi_max), env, rec)
	return m


func test_fm20_thermal_circling_climbs_every_size() -> void:
	# Default: the smallest and the largest bird (the 60 s budget); --full:
	# the whole ladder.
	for sp in (FS.SP if Paths.arg("full", "") != "" else [&"sparrow", &"eagle"]):
		var rec := FS.Rec.new()
		var _m := thermal_circle(sp, 60.0, rec)
		var climb := (rec.y[rec.size() - 1] - rec.y[rec.at(10.0)]) / 50.0
		gt(climb, 0.6, "%s net climb circling a 4 m/s, 44 m bell thermal (m/s)" % sp)
		metric("%s_thermal_climb" % sp, climb)


# --- FM-21: wind --------------------------------------------------------------------
func test_fm21_headwind() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		var env := FlightEnv.uniform(Vector3(0, 0, 5))
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		m.velocity += Vector3(0, 0, 5)
		FS.run(m, 30 * 72, FS.glide(0.0), env)
		var perf := SizeRules.performance(m.params.mass)
		var tel := m.telemetry()
		near(float(tel["airspeed"]) / perf["cruise"], 1.0, 0.03, "%s airspeed in a headwind = cruise" % sp)
		var gs := -m.velocity.z
		near(gs, float(tel["airspeed"]) * cos(m.gam) - 5.0, 0.1, "%s groundspeed = airspeed - wind" % sp)


# --- FM-22: integrator energy (F8) --------------------------------------------------
func test_fm22_energy_conserved_without_drag_or_thrust() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	for sp in FS.S3:
		var m := FS.model(sp)
		m.drag_enabled = false
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var e0 := FS.energy_height(m)
		# The altitude datum is arbitrary, so the drift is ALSO judged against
		# the kinetic part alone (v0^2 / 2g): 2% of that is the F8 bar.
		var ke0 := m.velocity.length_squared() / (2.0 * FS.G)
		var worst := 0.0
		var worst_m := 0.0
		var worst_20 := 0.0
		var cmd := [0.0, 0.0]
		var ws := WingState.new()
		var env := FlightEnv.new()
		for i in 60 * 72:
			if i % 36 == 0:
				cmd = [rng.randf_range(-0.5, 0.8), rng.randf_range(-1.0, 1.0)]
			ws.set_commands(cmd[0], cmd[1], 1.0, 0.0, 0.0)
			m.step(ws, env, DT)
			var d := absf(FS.energy_height(m) - e0)
			worst = maxf(worst, d / e0)
			worst_m = maxf(worst_m, d)
			if i < 20 * 72:
				worst_20 = maxf(worst_20, d)
		lt(worst, 0.0005, "%s energy drift over 60 s of random manoeuvres (fraction of total)" % sp)
		lt(worst_20 / ke0, 0.02, "%s F8: energy drift over 20 s within 2%% of the kinetic energy" % sp)
		lt(worst_m / ke0, 0.02, "%s energy drift over 60 s within 2%% of the kinetic energy" % sp)
		metric("%s_energy_drift_pct" % sp, worst * 100.0)
		metric("%s_energy_drift_ke_pct_20s" % sp, worst_20 / ke0 * 100.0)
		metric("%s_energy_drift_ke_pct_60s" % sp, worst_m / ke0 * 100.0)


# --- FM-23: fuzz: no NaN, bounded attitude (F8) ------------------------------------
func test_fm23_fuzz_random_inputs_and_dt_spikes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var dts := [1e-4, 1.0 / 90.0, 1.0 / 72.0, 1.0 / 30.0, 0.1]
	# Per size: 10k random frames, calm for the first 5k (the speed governor
	# is measured there), gusting +-8 m/s in every axis for the rest. The
	# default suite flies the sparrow (the lightest, most sensitive bird;
	# the 60 s budget), --full all three sizes.
	for sp in (FS.S3 if Paths.arg("full", "") != "" else [&"sparrow"]):
		for _once in 1:
			var m := FS.model(sp)
			m.trim(Vector3(0, 3000, 0), 0.0, 0.0)
			var env := FlightEnv.new()
			var w := Vector3.ZERO
			env.wind_fn = func(_p: Vector3) -> Vector3: return w
			var ws := WingState.new()
			var bad := 0
			var v_hi := 0.0
			var att_bad := 0
			for i in 10000:
				var windy := i >= 5000
				ws.pitch = rng.randf_range(-1.5, 1.5)
				ws.roll = rng.randf_range(-1.5, 1.5)
				ws.ext_l = rng.randf_range(0.0, 1.2)
				ws.ext_r = rng.randf_range(0.0, 1.2)
				ws.flap_l = rng.randf_range(-0.2, 1.5)
				ws.flap_r = rng.randf_range(-0.2, 1.5)
				ws.up_l = rng.randf_range(-0.2, 1.2)
				ws.up_r = rng.randf_range(-0.2, 1.2)
				ws.flap_dir_l = WingState.dir_for_tilt(rad_to_deg(rng.randf_range(-2.0, 2.0)))
				ws.flap_dir_r = WingState.dir_for_tilt(rad_to_deg(rng.randf_range(-2.0, 2.0)))
				ws.stroke_period = rng.randf_range(0.0, 3.0)
				if i % 997 == 0:
					ws.pitch = NAN
					ws.flap_l = INF
				if windy and i % 150 == 0:
					w = Vector3(rng.randf_range(-8, 8), rng.randf_range(-8, 8), rng.randf_range(-8, 8))
				var dt: float = dts[rng.randi() % dts.size()] if i % 7 == 0 else DT
				m.step(ws, env, dt)
				if not (FlightMath.vfinite(m.position) and FlightMath.vfinite(m.velocity) and is_finite(m.theta) and is_finite(m.phi)):
					bad += 1
				for k in m.telemetry().values():
					if (k is float and not is_finite(k)):
						bad += 1
				if not windy:
					v_hi = maxf(v_hi, m.airspeed() / m.params.v_max)
				if absf(m.theta) > PI / 2 + 1e-6 or absf(m.phi) > m.params.phi_max + deg_to_rad(0.5):
					att_bad += 1
				if m.position.y < 200.0:
					m.position.y = 3000.0
			eq(bad, 0, "%s: no NaN/inf in 10k random frames (calm, then gusting)" % sp)
			eq(att_bad, 0, "%s: pitch within +-90 and bank within phi_max" % sp)
			lt(v_hi, 1.05, "%s fuzz airspeed <= 1.05 V_max (calm half)" % sp)
			metric("%s_fuzz_vmax_ratio" % sp, v_hi)


# --- FM-24 / FM-25: frame-rate independence, determinism ----------------------
static func schedule_cmd(t: float, flapping: bool, x: float, ws: WingState, dt := 1.0 / 72.0) -> void:
	# Glide, turn, balloon, reverse turn, flapping turn, tuck dive, flare.
	var p := 0.0
	var r := 0.0
	var spread := 1.0
	var e := 0.0
	if t < 4.0:
		pass
	elif t < 8.0:
		r = 0.6
	elif t < 12.0:
		p = 0.5
	elif t < 16.0:
		r = -0.8
	elif t < 20.0:
		r = 0.5
		e = 0.7 if flapping else 0.0
	elif t < 25.0:
		p = -1.0
		spread = 0.0
	else:
		p = 0.8
	# The stroke is sampled at the tick midpoint: the best zero-order hold of
	# the continuous reference stroke over [t, t + dt).
	ws.set_commands(p, r, spread, e, t + 0.5 * dt, 1.0, 0, NAN, x)


static func schedule_run(sp: StringName, rate: float, flapping: bool) -> Array:
	var m := FS.model(sp)
	m.trim(Vector3(0, 1500, 0), 0.0, 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var n := int(round(30.0 * rate))
	var dt := 1.0 / rate
	var path := 0.0
	var prev := m.position
	for i in n:
		schedule_cmd(float(i) / rate, flapping, m.params.x, ws, dt)
		m.step(ws, env, dt)
		path += m.position.distance_to(prev)
		prev = m.position
	return [m.position, path]


func test_fm24_frame_rate_independence() -> void:
	# Default: the middle size (the 60 s budget); --full: all three.
	for sp in (FS.S3 if Paths.arg("full", "") != "" else [&"pigeon"]):
		for flapping in [false, true]:
			# Reference: 360 Hz ticks (substeps of 1/360 s; Heun is second
			# order, so its own error is ~1/6 of the 72 Hz run's).
			var ref := schedule_run(sp, 360.0, flapping)
			var worst := 0.0
			for rate in [72.0, 90.0, 120.0]:
				var r := schedule_run(sp, rate, flapping)
				worst = maxf(worst, (r[0] as Vector3).distance_to(ref[0]) / float(ref[1]))
			lt(worst, 0.015, "%s flapping=%s: final position error vs 360 Hz (fraction of path)" % [sp, flapping])
			metric("%s_%s_err_pct" % [sp, "flap" if flapping else "glide"], worst * 100.0)


func test_fm25_determinism() -> void:
	var a := schedule_run(&"pigeon", 72.0, true)
	var b := schedule_run(&"pigeon", 72.0, true)
	check((a[0] as Vector3) == (b[0] as Vector3), "bit-identical final position across runs")
	var r1 := FS.Rec.new()
	var r2 := FS.Rec.new()
	for rr in [r1, r2]:
		var m := FS.model(&"sparrow")
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		FS.run(m, 10 * 72, FS.flap(m, -0.3, 0.4, 0.8), null, rr)
	var p1 := FS.out_dir().path_join("det_a.csv")
	var p2 := FS.out_dir().path_join("det_b.csv")
	r1.csv(p1)
	r2.csv(p2)
	eq(FileAccess.get_file_as_string(p1), FileAccess.get_file_as_string(p2), "identical CSV for the same scenario twice")
	DirAccess.remove_absolute(p1)
	DirAccess.remove_absolute(p2)


# --- FM-26: growth is continuous ------------------------------------------------
func test_fm26_growth_continuous() -> void:
	var m := FS.model(&"sparrow")
	m.trim(Vector3(0, 800, 0), 0.0, 0.0)
	FS.run(m, 5 * 72, FS.glide(0.0))
	var v0 := m.velocity
	m.set_mass(0.06)
	FS.run(m, 1, FS.glide(0.0))
	lt((m.velocity - v0).length(), 0.2, "velocity continuous across a growth tick (m/s)")
	metric("growth_step_dv", (m.velocity - v0).length())
	var m2 := FS.model(&"sparrow")
	m2.trim(Vector3(0, 2500, 0), 0.0, 0.0)
	var m_hi := FlightParams.species_mass(&"eagle")
	var ws := WingState.new()
	var env := FlightEnv.new()
	var bad := 0
	# 20 s from sparrow to eagle, a new mass every 8 ticks (the game sets the
	# mass once per catch; each new size recomputes the detector's reference
	# stroke, which a per-tick ramp paid 700 times: the 60 s budget).
	for i in 20 * 72:
		if i % 8 == 0:
			m2.set_mass(0.03 * pow(m_hi / 0.03, float(i) / (20.0 * 72.0)))
		ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m2.step(ws, env, DT)
		if not FlightMath.vfinite(m2.velocity):
			bad += 1
	m2.set_mass(m_hi)
	FS.run(m2, int(2.0 * m2.params.t_ph * 72), FS.glide(0.0))
	eq(bad, 0, "no NaN during a 20 s growth ramp to eagle")
	near(m2.airspeed() / m2.params.v_c, 1.0, 0.05, "after the ramp the eagle trims at its cruise")
	metric("growth_final_ratio", m2.airspeed() / m2.params.v_c)


# --- FM-29: telemetry units -----------------------------------------------------
func test_fm29_telemetry_units() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		FS.run(m, 5 * 72, FS.glide(0.0))
		var t := m.telemetry()
		near(float(t["lift"]) / (float(t["g_load"]) * m.params.mass * FS.G), 1.0, 0.01, "%s lift = g_load m g" % sp)
		for k in t:
			if t[k] is float:
				check(is_finite(t[k]), "%s telemetry %s finite" % [sp, k])


# --- FM-30: body pitch is continuous through a vertical zoom -----------------
## A tuck dive then full nose-up zooms the bird to vertical until its speed
## is gone. At the top the flight-path angle flips from +90 to -90 deg as the
## velocity reverses; the body must rotate at a bounded rate (visual and
## telemetry only for the player, but NPCs reuse the model and would visibly
## tumble in one frame).
func test_fm30_pitch_continuous_through_a_zoom() -> void:
	for sp in FS.S3:
		for preset in [1, 0]:
			var m := FS.model(sp, preset)
			m.trim(Vector3(0, 800, 0), 0.0, 0.0)
			var rec := FS.Rec.new()
			FS.run(m, 4 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec)
			FS.run(m, 8 * 72, FS.glide(1.0), null, rec)
			var worst := 0.0
			var top_gam := -INF
			for i in range(1, rec.size()):
				worst = maxf(worst, absf(rec.theta[i] - rec.theta[i - 1]))
				top_gam = maxf(top_gam, rec.gam[i])
			var lim := rad_to_deg(2.0 * m.params.q_max * FS.DT) + 0.01
			lt(worst, lim, "%s preset %d: body pitch step per tick <= 2 q_max dt (deg)" % [sp, preset])
			metric("%s_p%d_max_pitch_step_deg" % [sp, preset], worst)
			metric("%s_p%d_max_gamma_deg" % [sp, preset], top_gam)


# --- FM-31: trim is the attached-flow glide, whatever the live state ---------
## Right after a held stall the separation blend is still decaying; the
## steady-glide solution (and trim / PlayerBird.start_flying built on it)
## must not read it.
func test_fm31_trim_ignores_the_live_stall_state() -> void:
	for sp in FS.S3:
		var fresh := FS.model(sp)
		var want: Dictionary = fresh.trim_solution(0.0)
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.8)
		FS.run(m, 2 * 72, FS.glide(1.0))
		check(m.sigma > 0.2, "%s: separated flow before the check (sigma %.2f)" % [sp, m.sigma])
		var got: Dictionary = m.trim_solution(0.0)
		near(rad_to_deg(got["gamma"]), rad_to_deg(want["gamma"]), 1e-6, "%s: trim gamma right after a stall = attached-flow gamma (deg)" % sp)
		near(float(got["v"]), float(want["v"]), 1e-6, "%s: trim speed right after a stall (m/s)" % sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		near(rad_to_deg(m.gam), rad_to_deg(want["gamma"]), 1e-6, "%s: trim() right after a stall starts on the attached glide" % sp)
		eq(m.sigma, 0.0, "%s: trim() clears the separation" % sp)


# --- FM-18b: a wing's force across the body does not push it (fix round 4) -------
## Through the arms a wing drooped mid-stroke has a normal tilted toward its
## own side; that component shoved the body toward the stroking wing (one-arm
## strokes then turned the wrong way). Pinned: a one-wing flap with the
## normal drooped 40 deg toward the stroking side has no flap force along the
## banked body's right axis, and a symmetric drooped pair gives exactly the
## force the level pair did (the components used to cancel).
func test_fm18b_flap_force_has_no_side_component() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var ws := WingState.new()
		ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		var e := deg_to_rad(40.0)
		# Equal efforts (no one-wing kick, the bank stays level), the left
		# wing drooped: its normal tilts 40 deg toward its own side.
		ws.flap_dir_l = Vector3(-sin(e), cos(e), 0.0)
		ws.flap_dir_r = Vector3.UP
		ws.flap_l = 1.0
		ws.flap_r = 1.0
		ws.stroke_period = 1.0
		var worst := 0.0
		for i in 36:
			m.step(ws, null, DT)
			var rh := Vector3(cos(m.chi), 0.0, -sin(m.chi))
			var r_b := rh * cos(m.phi) - Vector3.UP * sin(m.phi)
			worst = maxf(worst, absf(m.f_flap.dot(r_b)) / (m.params.mass * FlightMath.G))
		lt(worst, 1e-6, "%s: a drooped wing pushes nothing sideways (g; round 3: sin 40 of its force)" % sp)
		gt(m.f_flap.length(), 0.1 * m.params.mass * FlightMath.G, "%s: ... while the wings do push (up)" % sp)
		metric("%s_side_g" % sp, worst)


# --- FM-18c: the one-wing kick's dead zone (fix round 4) -------------------------
## Natural human asymmetry is a symmetric stroke: the kick (roll kick and
## paddle yaw) acts only on the stroke-mean effort asymmetry beyond
## one_wing_deadzone, rescaled so it grows from zero at the edge to full at a
## one-wing stroke (no step when an asymmetry crosses the edge).
func test_fm18c_one_wing_kick_grows_from_the_dead_zone_edge() -> void:
	for sp in (FS.S3 if Paths.arg("full", "") != "" else [&"pigeon"]):
		var bank := {}
		# Right wing's effort as a share q of the left's: relative asymmetry
		# (1 - q) / (1 + q) = 0.10 (inside), 0.20 (just past), 0.50, 1 (one wing).
		for rel: float in [0.1, 0.2, 0.5, 1.0]:
			var q := (1.0 - rel) / (1.0 + rel)
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var ws := WingState.new()
			var peak := 0.0
			for i in 144:
				ws.set_commands(0.0, 0.0, 1.0, 1.0, i * DT, 1.0, 0, NAN, m.params.x)
				ws.flap_r *= q
				ws.up_r *= q
				m.step(ws, null, DT)
				if i >= 72:  # the stroke-mean window is full after one period
					peak = maxf(peak, absf(rad_to_deg(m.phi)))
			bank[rel] = peak
		lt(bank[0.1], 0.05, "%s: 10 %% asymmetry (inside the dead zone): no kick, wings level (deg)" % sp)
		gt(bank[0.2], 1e-3, "%s: 20 %% asymmetry: a kick (deg)" % sp)
		lt(bank[0.2] / bank[1.0], 0.15, "%s: ... growing from zero at the edge (share of a one-wing stroke's bank; without the rescale 0.33)" % sp)
		check(bank[0.2] < bank[0.5] and bank[0.5] < bank[1.0], "%s: the kick grows with the asymmetry (%.2f < %.2f < %.2f deg)" % [sp, bank[0.2], bank[0.5], bank[1.0]])
		metric("%s_bank_by_rel" % sp, bank)


# --- FM-23b: the NaN guard restores a corrupted state ---------------------------
## The guard (restore the last good state on a non-finite one) was not pinned
## (round-4 engineering verifier: disabling it passed every model test).
func test_fm23b_nan_guard_restores_a_corrupted_state() -> void:
	var m := FS.model(&"pigeon")
	m.trim(Vector3(0, 300, 0), 0.0, 0.0)
	var ws := WingState.new()
	ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
	for i in 36:
		m.step(ws, null, DT)
	var good_pos := m.position
	var good_vel := m.velocity
	for field in ["velocity", "position", "phi", "chi"]:
		match field:
			"velocity": m.velocity = Vector3(NAN, 0.0, 0.0)
			"position": m.position = Vector3(0.0, INF, 0.0)
			"phi": m.phi = NAN
			"chi": m.chi = -INF
		m.step(ws, null, DT)
		check(FlightMath.vfinite(m.position) and FlightMath.vfinite(m.velocity) and is_finite(m.phi) and is_finite(m.chi),
			"a non-finite %s is restored to a finite state" % field)
		lt(m.position.distance_to(good_pos), 2.0 * good_vel.length() * DT + 0.05, "%s: restored to (near) the last good state (m)" % field)
	for i in 72:
		m.step(ws, null, DT)
	near(m.velocity.length(), good_vel.length(), 0.5 * good_vel.length(), "flies on normally after the restores (m/s)")
