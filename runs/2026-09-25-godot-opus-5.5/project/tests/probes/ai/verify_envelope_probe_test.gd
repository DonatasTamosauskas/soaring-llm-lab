extends TestCase
## VERIFIER PROBE (ai, round 1) - not part of the area suite.
## A4: flight_envelope_test measures the turn rate only at cruise. Here each
## species holds a max-rate level turn at a range of speeds below cruise
## (want_speed fixed, full effort) for 10 s; if it can hold both the speed
## and its height, that turn rate is sustainable. Reports the best
## sustainable rate as a multiple of SizeRules.performance().turn_rate.
##
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=envelope

const DT := 1.0 / 72.0


func test_probe_sustained_turn_rate_below_cruise() -> void:
	var table := {}
	for s in SizeRules.SPECIES:
		var perf := SizeRules.performance(s["mass"])
		var best := 0.0
		var best_at := 0.0
		for k in range(0, 9):
			var frac := 0.6 + 0.05 * k
			var f := NpcFlight.new(s["mass"], SpeciesProfile.of(s["id"])["glide_ratio"])
			var want := float(perf["cruise"]) * frac
			f.set_velocity(Vector3(0, 0, -want))
			var yaw := 0.0
			var t := 0.0
			var h := 0.0
			var h0 := 0.0
			var sp_min := INF
			var sp_max := 0.0
			for i in int(14.0 / DT):
				var left := Vector3(-cos(f.psi), 0, sin(f.psi))
				var before := f.psi
				f.step(DT, left, want, 1.0, 0.0)
				h += f.air_velocity().y * DT
				if i * DT >= 4.0:
					if t == 0.0:
						h0 = h
					yaw += wrapf(f.psi - before, -PI, PI)
					t += DT
					sp_min = minf(sp_min, f.speed)
					sp_max = maxf(sp_max, f.speed)
			var rate := absf(yaw) / t
			var level := absf(h - h0) < 1.5
			var steady := sp_max - sp_min < want * 0.05
			if level and steady and rate > best:
				best = rate
				best_at = f.speed / float(perf["cruise"])
		table[String(s["id"])] = {"best_ratio": snappedf(best / float(perf["turn_rate"]), 0.001), "at_speed_x_cruise": snappedf(best_at, 0.01)}
		lt(best / float(perf["turn_rate"]), 1.1, "%s best sustainable level turn (any speed) within 10%% of SizeRules turn_rate" % s["id"])
	metric("turn_below_cruise", table)
	print("[ai-verify] sustained level turn rate vs SizeRules.turn_rate by speed: ", table)
