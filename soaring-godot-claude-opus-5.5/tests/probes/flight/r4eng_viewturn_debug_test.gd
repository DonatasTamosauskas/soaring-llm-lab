extends TestCase
## Verifier probe (round 4, engineering): locate the first ViewTurn tick of
## the fuzz stream whose payout rate leaves the 120 deg/s limit, and print
## the plan state around it (repro for the finding).

const DT := 1.0 / 72.0


func test_r4_viewturn_first_violation() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var vt := ViewTurn.new()
	var prev_rate := 0.0
	var hist: Array[String] = []
	var found := false
	for i in 40000:
		var owe_d := 0.0
		if rng.randf() < 0.02:
			var d := rng.randf_range(-PI, PI) * (1.0 if rng.randf() < 0.5 else 0.03)
			owe_d = d
			vt.owe(d)
		var before := "debt %.4f rate %.2f acc %.2f T %.3f t %.3f" % [vt.debt, rad_to_deg(vt.rate), rad_to_deg(vt.acc), vt._T, vt._t]
		var x := vt.step(DT)
		var r := x / DT
		hist.append("tick %d owe %.4f | before: %s | paid %.5f rate %.1f deg/s | after: debt %.4f rate %.1f acc %.1f T %.3f t %.3f" % [
			i, owe_d, before, x, rad_to_deg(r), vt.debt, rad_to_deg(vt.rate), rad_to_deg(vt.acc), vt._T, vt._t])
		if hist.size() > 12:
			hist.pop_front()
		if absf(rad_to_deg(r)) > 125.0 and not found:
			found = true
			for h in hist:
				print("[flight-verify] ", h)
			for k in 6:
				var x2 := vt.step(DT)
				print("[flight-verify]   next paid %.5f rate %.1f deg/s debt %.4f T %.3f t %.3f" % [x2, rad_to_deg(x2 / DT), vt.debt, vt._T, vt._t])
			break
		prev_rate = r
	check(not found, "no ViewTurn payout above 125 deg/s in the fuzz stream")


## Deterministic repro: a payout already at 101 deg/s and still accelerating
## (-162 deg/s^2) is owed a further 170 deg the same way (a second stun or
## re-seat while the first is being paid). No quintic from that state stays
## inside 120 deg/s, _plan() exhausts its 40 tries and keeps T = 1.08 x the
## duration its coefficients were solved for.
func test_r4_viewturn_infeasible_replan() -> void:
	var vt := ViewTurn.new()
	vt.rate = deg_to_rad(-101.0)
	vt.acc = deg_to_rad(-162.0)
	vt.owe(deg_to_rad(-170.0))
	var peak := 0.0
	var last_tick := 0.0
	var ticks := 0
	var paid := 0.0
	for i in int(70.0 / DT):
		var x := vt.step(DT)
		paid += x
		peak = maxf(peak, absf(x / DT))
		ticks = i
		last_tick = x
		if not vt.active():
			break
	print("[flight-verify] infeasible re-plan: planned T %.1f s, peak payout %.0f deg/s, stopped after %.1f s, paid %.1f deg (owed -170 plus the running turn), final tick paid %.2f deg" % [
		vt._T, rad_to_deg(peak), ticks * DT, rad_to_deg(paid), rad_to_deg(last_tick)])
	lt(rad_to_deg(peak), 120.0 * 1.02, "the payout stays inside 120 deg/s even when the start state makes it infeasible")


## settle() (a perch capture or a landing) from a rig turning faster than
## ViewTurn's own 120 deg/s (the flown turn alone may reach 240 deg/s):
## the braking plan starts outside the limits, _plan() cannot satisfy them,
## and the "brake" keeps turning the view.
func test_r4_viewturn_settle_from_a_fast_rig() -> void:
	for r0 in [100.0, 130.0, 160.0, 200.0, 240.0]:
		var vt := ViewTurn.new()
		vt.settle(deg_to_rad(-r0), 0.0)
		var total := 0.0
		var peak := 0.0
		var t := 0.0
		for i in int(90.0 / DT):
			var x := vt.step(DT)
			total += x
			peak = maxf(peak, absf(x / DT))
			if not vt.active():
				t = i * DT
				break
		print("[flight-verify] settle from %.0f deg/s: turned %.0f deg more over %.1f s, peak %.0f deg/s" % [r0, rad_to_deg(total), t, rad_to_deg(peak)])
		lt(absf(rad_to_deg(total)), 1.1 * r0 * maxf(0.3, 1.5 * r0 / 240.0) * 0.5 + 1.0, "settle from %.0f deg/s: the view only brakes (turns at most the planned stop)" % r0)
		lt(rad_to_deg(peak), maxf(r0, 120.0) * 1.02, "settle from %.0f deg/s: the view never turns faster than it was turning" % r0)


## settle() plans the stop over tt = max(min_time, 1.5 |rate| / max_acc) and
## owes rate * tt / 2, but _plan() then picks its own, longer T from the
## debt alone; from a moving start the quintic must turn back to end on the
## debt: the view swings past its stop and returns after a landing.
func test_r4_viewturn_settle_swings_back() -> void:
	for r0 in [40.0, 70.0, 100.0, 120.0]:
		var vt := ViewTurn.new()
		vt.settle(deg_to_rad(r0), 0.0)
		var x := 0.0
		var peak_x := 0.0
		for i in int(3.0 / DT):
			x += vt.step(DT)
			peak_x = maxf(peak_x, x)
			if not vt.active():
				break
		print("[flight-verify] settle from %.0f deg/s: the view runs on to %.1f deg and ends at %.1f deg (swing back %.1f deg)" % [
			r0, rad_to_deg(peak_x), rad_to_deg(x), rad_to_deg(peak_x - x)])
		lt(rad_to_deg(peak_x - x), 0.5, "settle from %.0f deg/s: the braking view never swings back" % r0)
