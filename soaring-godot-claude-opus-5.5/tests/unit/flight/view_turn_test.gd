extends TestCase
## ViewTurn (fix round 4): the time-optimal follower that pays heading jumps
## to the view. Round 3's re-planned quintic could run out of durations to
## try and keep coefficients solved for another duration: after stuns that
## ended on the floor the view spun at the 240 deg/s rig cap for tens of
## seconds (engineering verifier, round 4). These property tests pin what
## the follower guarantees by construction, over random owe sequences:
## stun-sized, large (to 180 deg, wrapping) and tiny owes, owes while a
## payout runs (in either direction), landings (reset) in between, at 72,
## 90 and 120 Hz ticks.
##  - caps: |rate| <= 120 deg/s and |rate change| <= 240 deg/s^2 every tick;
##  - conservation: owed = paid + debt (mod 2 pi), nothing lost;
##  - convergence: after the last owe the view is at rest on the target
##    within |err|/rate + rate/acc + 0.3 s from rest (the lead's bound);
##    from a moving payout, within the brake's |v|/acc first, with the
##    brake's own run v^2/2acc added to |err|;
##  - overshoot: none (1e-6 rad) from rest or on the stopping curve; from a
##    payout already too fast to stop on a shortened target, at most that
##    unavoidable brake run (and never more than 0.5 deg beyond it).
## --full runs 20 000 sequences (the default 3 000).

const DEG := PI / 180.0


func _rates() -> Array[float]:
	return [1.0 / 72.0, 1.0 / 90.0, 1.0 / 120.0]


## One random owe sequence through a fresh ViewTurn; fills `w` with the worst
## measures. Returns false if a property failed (the reason in w["why"]).
## var_dt: every tick draws its length from 72 / 90 / 120 Hz (VT-5), and the
## overshoot may reach tol_over (rad) beyond the unavoidable brake run.
func _sequence(rng: RandomNumberGenerator, w: Dictionary, var_dt := false, tol_over := 1e-6, t_slack := 0.0) -> bool:
	var vt := ViewTurn.new()
	var vmax := vt.max_rate
	var amax := vt.max_acc
	var dt: float = _rates()[rng.randi() % 3]
	var dt_max := 1.0 / 72.0 if var_dt else dt
	# Events: [tick, kind, value]. kind 0 = owe, 1 = reset (a landing).
	var events: Array = []
	var n_ev := rng.randi_range(1, 6)
	var t_ev := 0
	for i in n_ev:
		t_ev += rng.randi_range(0, int(0.45 / dt))
		var r := rng.randf()
		if r < 0.08 and i < n_ev - 1:
			events.append([t_ev, 1, 0.0])
			continue
		var mag := 0.0
		var k := rng.randf()
		if k < 0.45:
			mag = rng.randf_range(0.5, 40.0) * DEG          # a stun's turn, a slide
		elif k < 0.75:
			mag = rng.randf_range(40.0, 180.0) * DEG        # large (wraps past 180)
		else:
			mag = pow(10.0, rng.randf_range(-9.0, -3.0))    # tiny residues
		events.append([t_ev, 0, mag * (1.0 if rng.randf() < 0.5 else -1.0)])
	var owed := 0.0
	var paid := 0.0
	var ei := 0
	var tick := 0
	var last_tick := int(events[events.size() - 1][0])
	var e0 := 0.0
	var v0 := 0.0
	var x_since := 0.0
	var over := 0.0
	var allowed := 0.0
	var bound := 0.0
	var t_conv := -1.0
	var rate_prev := 0.0
	while true:
		while ei < events.size() and int(events[ei][0]) == tick:
			var ev: Array = events[ei]
			if int(ev[1]) == 1:
				vt.reset()
				owed = 0.0
				paid = 0.0
				rate_prev = 0.0
			else:
				vt.owe(float(ev[2]))
				owed += float(ev[2])
			ei += 1
		if tick == last_tick:
			e0 = vt.debt
			v0 = vt.rate
			x_since = 0.0
			var run := v0 * v0 / (2.0 * amax) + absf(v0) * dt_max
			if e0 == 0.0 or signf(v0) == signf(e0):
				allowed = maxf(0.0, run - absf(e0))
			bound = absf(v0) / amax + (absf(e0) + run) / vmax + vmax / amax + 0.3 + dt_max + t_slack
		if var_dt:
			dt = _rates()[rng.randi() % 3]
		var x := vt.step(dt)
		paid += x
		var r_now := x / dt
		# Caps (float round-off only).
		if absf(r_now) > vmax * (1.0 + 1e-9) + 1e-12:
			w["why"] = "rate %.6f deg/s > cap" % rad_to_deg(r_now)
			return false
		var a_now := absf(r_now - rate_prev) / dt
		if a_now > amax * (1.0 + 1e-6) + 1e-9:
			w["why"] = "accel %.6f deg/s^2 > cap" % rad_to_deg(a_now)
			return false
		rate_prev = r_now
		w["rate"] = maxf(w["rate"], absf(r_now))
		w["acc"] = maxf(w["acc"], a_now)
		var cons := absf(wrapf(owed - paid - vt.debt, -PI, PI))
		w["cons"] = maxf(w["cons"], cons)
		if tick >= last_tick:
			x_since += x
			var past := x_since * signf(e0) - absf(e0) if e0 != 0.0 else absf(x_since)
			over = maxf(over, past)
			if not vt.active():
				t_conv = (tick - last_tick + 1) * dt
				break
			if (tick - last_tick) * dt > bound + 1.0:
				break
		tick += 1
	if t_conv < 0.0:
		w["why"] = "no convergence within %.2f s (debt %.3f deg, rate %.3f deg/s)" % [bound + 1.0, rad_to_deg(vt.debt), rad_to_deg(vt.rate)]
		return false
	w["t_margin"] = minf(w["t_margin"], bound - t_conv)
	if t_conv > bound:
		w["why"] = "converged in %.3f s > bound %.3f s (e0 %.3f deg, v0 %.2f deg/s)" % [t_conv, bound, rad_to_deg(e0), rad_to_deg(v0)]
		return false
	var excess := over - allowed
	w["over_rest"] = maxf(w["over_rest"], over if allowed == 0.0 else 0.0)
	w["over_excess"] = maxf(w["over_excess"], excess)
	w["over_unavoidable"] = maxf(w["over_unavoidable"], allowed)
	if excess > tol_over:
		w["why"] = "overshoot %.5f deg beyond the unavoidable %.5f deg (e0 %.3f deg, v0 %.2f deg/s)" % [
			rad_to_deg(over), rad_to_deg(allowed), rad_to_deg(e0), rad_to_deg(v0)]
		return false
	if absf(vt.debt) > 0.0 or vt.rate != 0.0:
		w["why"] = "inactive but debt %s / rate %s left" % [vt.debt, vt.rate]
		return false
	return true


func test_vt1_random_owe_sequences_caps_convergence_no_overshoot() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4040
	var n := 20000 if Paths.arg("full", "") != "" else 3000
	var w := {"rate": 0.0, "acc": 0.0, "cons": 0.0, "t_margin": INF, "over_rest": 0.0, "over_excess": -INF,
		"over_unavoidable": 0.0, "why": ""}
	var failed := 0
	var first := ""
	for s in n:
		if not _sequence(rng, w):
			failed += 1
			if first.is_empty():
				first = "sequence %d: %s" % [s, w["why"]]
	eq(failed, 0, "%d random owe sequences: every property holds (first failure: %s)" % [n, first])
	lt(rad_to_deg(w["rate"]), 120.0 + 1e-6, "payout rate never above 120 deg/s (deg/s)")
	lt(rad_to_deg(w["acc"]), 240.0 + 1e-3, "payout rate change never above 240 deg/s^2 (deg/s^2)")
	metric("conservation_err_rad", w["cons"])
	lt(w["cons"], 1e-9, "owed = paid + debt (mod 2 pi) on every tick (rad)")
	gt(w["t_margin"], 0.0, "every sequence at rest on its target inside the bound (s of margin)")
	lt(rad_to_deg(w["over_rest"]), 1e-4, "no overshoot from rest or on the stopping curve (deg)")
	lt(rad_to_deg(w["over_excess"]), 1e-4, "overshoot never beyond the unavoidable brake run (deg)")
	metric("sequences", n)
	metric("peak_rate_deg", rad_to_deg(w["rate"]))
	metric("peak_acc_deg", rad_to_deg(w["acc"]))
	metric("min_time_margin_s", w["t_margin"])
	metric("worst_unavoidable_overshoot_deg", rad_to_deg(w["over_unavoidable"]))


## Single owes from rest: the time-optimal profile. At rest on the target in
## |d|/120 + 120/240 + 0.3 s at most and never faster than the continuous
## optimum (2 sqrt(d/a) below the rate cap), monotonic, no overshoot.
func test_vt2_single_owes_from_rest_are_time_optimal() -> void:
	for dt in _rates():
		for d_deg in [0.01, 0.5, 5.0, 20.0, 40.0, 60.0, 90.0, 179.0]:
			for sgn in [-1.0, 1.0]:
				var vt := ViewTurn.new()
				var d: float = sgn * d_deg * DEG
				vt.owe(d)
				var x := 0.0
				var t := 0.0
				var mono := true
				var over := 0.0
				while vt.active() and t < 10.0:
					var p := vt.step(dt)
					if p * sgn < -1e-12:
						mono = false
					x += p
					t += dt
					over = maxf(over, x * sgn - absf(d))
				var a := vt.max_acc
				var v := vt.max_rate
				var t_opt := 2.0 * sqrt(absf(d) / a) if absf(d) <= v * v / a else absf(d) / v + v / a
				var tag := "%.2f deg at %.0f Hz" % [sgn * d_deg, 1.0 / dt]
				near(x, d, 1e-9, "%s: pays exactly the debt (rad)" % tag)
				lt(t, absf(d) / v + v / a + 0.3, "%s: at rest within |d|/rate + rate/acc + 0.3 s" % tag)
				gt(t + 1e-9, t_opt, "%s: not faster than the continuous time-optimal turn" % tag)
				lt(t, t_opt + 3.0 * dt + 1e-9, "%s: within 3 ticks of the time-optimal turn" % tag)
				check(mono, "%s: the view turns one way only" % tag)
				lt(over, 1e-9, "%s: no overshoot (rad)" % tag)


## The verifier's repros (round 4): an owe of 170 deg more, the same way,
## into a payout at 101 deg/s still accelerating; a rate left above a
## lowered cap. Round 3 peaked at 10 784 deg/s and ran for ~60 s.
func test_vt3_verifier_repros_stay_inside_the_caps() -> void:
	var dt := 1.0 / 72.0
	var vt := ViewTurn.new()
	vt.owe(deg_to_rad(-60.0))
	var peak := 0.0
	# Run until the payout passes -101 deg/s (bounded: round 3's follower
	# looped here for ever).
	var k := 0
	while vt.rate > deg_to_rad(-101.0) and k < 720:
		vt.step(dt)
		k += 1
	lt(rad_to_deg(vt.rate), -101.0 + 1e-6, "a -60 deg owe from rest reaches -101 deg/s (deg/s)")
	vt.owe(deg_to_rad(-170.0))
	var t := 0.0
	var prev := vt.rate
	var acc := 0.0
	while vt.active() and t < 60.0:
		var p := vt.step(dt)
		peak = maxf(peak, absf(p / dt))
		acc = maxf(acc, absf(p / dt - prev) / dt)
		prev = p / dt
		t += dt
	lt(rad_to_deg(peak), 120.0 + 1e-6, "owe while paying fast: payout <= 120 deg/s (deg/s)")
	lt(rad_to_deg(acc), 240.0 + 1e-3, "owe while paying fast: <= 240 deg/s^2 (deg/s^2)")
	lt(t, 3.5, "owe while paying fast: at rest within 3.5 s (s)")
	metric("replan_case", {"peak": rad_to_deg(peak), "t": t})
	# A cap lowered mid-turn (a comfort setting): the rate above it brakes
	# at the acceleration cap, never jumps down, never speeds up.
	var vt2 := ViewTurn.new()
	vt2.owe(PI)
	for i in 72:
		vt2.step(dt)
	vt2.max_rate = deg_to_rad(40.0)
	var r_prev := vt2.rate
	var worst_acc := 0.0
	var rose := false
	var t2 := 0.0
	while vt2.active() and t2 < 20.0:
		var p2 := vt2.step(dt)
		worst_acc = maxf(worst_acc, absf(p2 / dt - r_prev) / dt)
		if absf(p2 / dt) > absf(r_prev) + 1e-9 and absf(r_prev) > vt2.max_rate:
			rose = true
		r_prev = p2 / dt
		t2 += dt
	lt(rad_to_deg(worst_acc), 240.0 + 1e-3, "lowered cap: braked inside 240 deg/s^2")
	check(not rose, "lowered cap: a rate above the cap never rises")
	check(not vt2.active(), "lowered cap: at rest on the target")


## The verifier's 40 000-tick stream of random owes (2 % of ticks, half of
## them large): the view is never turning when nothing is owed, and never
## for longer than its debt needs.
func test_vt4_random_stream_never_spins() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var dt := 1.0 / 72.0
	var vt := ViewTurn.new()
	var owed := 0.0
	var paid := 0.0
	var st := {"rate": 0.0, "cons": 0.0, "idle_spin": 0}
	for i in 40000:
		if rng.randf() < 0.02:
			var d := rng.randf_range(-PI, PI) * (1.0 if rng.randf() < 0.5 else 0.03)
			vt.owe(d)
			owed += d
		var was_idle := not vt.active()
		var x := vt.step(dt)
		paid += x
		if was_idle and x != 0.0:
			st["idle_spin"] += 1
		st["rate"] = maxf(st["rate"], absf(x / dt))
		st["cons"] = maxf(st["cons"], absf(wrapf(owed - paid - vt.debt, -PI, PI)))
	lt(rad_to_deg(st["rate"]), 120.0 + 1e-6, "40 000-tick stream: payout <= 120 deg/s")
	lt(st["cons"], 1e-9, "40 000-tick stream: nothing lost (rad)")
	eq(st["idle_spin"], 0, "40 000-tick stream: an idle follower never turns the view")



# --- VT-5: the tick length changing every tick -----------------------------------
## The discrete stopping curve assumes the ticks after this one have its
## length (round-5 engineering verifier: switching among 72, 90 and 120 Hz
## overshot 0.20 deg on 179.5 deg owed). The caps, conservation and
## convergence hold whatever the ticks; the overshoot from rest is bounded
## by 0.25 deg, and the payout settles within 1 s of the constant-tick
## bound (the stopping curve is re-solved as the tick changes near the
## target: +0.49 s worst over 3 000 sequences). 1 000 sequences by default,
## 5 000 with --full. Godot's physics tick is fixed, so in the game the exact
## guarantee (VT-1) is the one that applies; a refresh-rate change retunes
## the physics rate once, not every tick. (Ticks from 4 to 100 ms through
## tick(dt), which the game never produces, overshoot up to 4.7 deg.)
func test_vt5_variable_tick_lengths_keep_the_caps() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5050
	var n := 5000 if Paths.arg("full", "") != "" else 1000
	var w := {"rate": 0.0, "acc": 0.0, "cons": 0.0, "t_margin": INF, "over_rest": 0.0, "over_excess": -INF,
		"over_unavoidable": 0.0, "why": ""}
	var bad := 0
	var first := ""
	for i in n:
		if not _sequence(rng, w, true, 0.25 * DEG, 1.0):
			bad += 1
			if first.is_empty():
				first = "seq %d: %s" % [i, w["why"]]
	eq(bad, 0, "%d random owe sequences with the tick length changing every tick keep every property (%s)" % [n, first])
	lt(rad_to_deg(w["rate"]), 120.0 + 1e-6, "peak payout (deg/s)")
	lt(rad_to_deg(w["acc"]), 240.0 + 1e-4, "peak payout acceleration (deg/s^2)")
	lt(rad_to_deg(w["over_rest"]), 0.25, "overshoot from rest (deg)")
	metric("peak_rate", rad_to_deg(w["rate"]))
	metric("over_rest_deg", rad_to_deg(w["over_rest"]))
	metric("t_margin_s", w["t_margin"])


# --- VT-6: the wrap at +-180 deg is exact ---------------------------------------------
## Godot's wrapf(x, -PI, PI) returns -PI for any result within its
## is_equal_approx tolerance of +PI (~1e-5 relative): a debt summing to
## 2.5e-5 rad short of +PI became -PI and that much turn was lost (VT-1's
## conservation check, sequence 1 of the --full 20 000, found in fix round
## 6). The follower and FlightMath.wrap_angle now wrap exactly.
func test_vt6_the_wrap_at_180_deg_is_exact() -> void:
	var vt := ViewTurn.new()
	vt.owe(0.374421978699)
	vt.owe(2.76714581273804)
	near(vt.debt, 0.374421978699 + 2.76714581273804, 1e-12, "a debt just short of +PI stays itself (rad; wrapf gave -PI)")
	for x: float in [PI - 3e-5, PI - 1e-9, -PI, -PI + 1e-9, 0.1, -3.0]:
		near(FlightMath.wrap_angle(x), x, 1e-12, "wrap_angle(%s) is itself" % x)
	near(FlightMath.wrap_angle(PI), -PI, 1e-12, "wrap_angle(PI) is -PI (the range is [-PI, PI))")
	near(FlightMath.wrap_angle(PI + 0.5), -PI + 0.5, 1e-12, "wrap_angle(PI + 0.5)")
	near(FlightMath.wrap_angle(-7.0 * PI + 0.25), -PI + 0.25, 1e-9, "wrap_angle(-7 PI + 0.25)")
