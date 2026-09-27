extends TestCase
## VERIFIER PROBE (A4): the builder's envelope test only flies the ten ladder
## species at their book masses. In the game NPC masses vary +-9% per
## individual, GameLoop grows eaters by up to +15%, and apex eagles are
## sized to the player (up to 4.5 x 1.25 x 1.3 = 7.3 kg, x1.15 after meals).
## Check cruise, sustained turn, sustained climb and tucked max speed at
## those off-ladder masses stay within 10% of SizeRules.performance(mass).

const DT := 1.0 / 72.0
const TOL := 0.10


func _cases() -> Array:
	var out := []
	for s in SizeRules.SPECIES:
		var m: float = s["mass"]
		for k in [0.91, 1.09, 1.09 * 1.15]:
			out.append([s["id"], m * k])
	out.append([&"eagle", 7.31])
	out.append([&"eagle", 7.31 * 1.15])
	return out


func _mk(sp: StringName, m: float) -> NpcFlight:
	var f := NpcFlight.new(m, SpeciesProfile.of(sp)["glide_ratio"])
	f.set_velocity(Vector3(0, 0, -f.cruise))
	return f


func test_off_ladder_envelopes_within_10_percent() -> void:
	var worst := {"cruise": 0.0, "turn": 0.0, "climb": 0.0, "max": 0.0}
	var rows := []
	for c in _cases():
		var sp: StringName = c[0]
		var m: float = c[1]
		var perf := SizeRules.performance(m)
		# cruise
		var f := _mk(sp, m)
		f.set_velocity(Vector3(0, 0, -f.cruise * 0.6))
		for i in int(8.0 / DT):
			f.step(DT, Vector3.FORWARD, f.cruise, 1.0, 0.0)
		var e_cr := absf(f.speed / perf["cruise"] - 1.0)
		# sustained turn at cruise
		f = _mk(sp, m)
		var yaw := 0.0
		var t := 0.0
		for i in int(14.0 / DT):
			var left := Vector3(-cos(f.psi), 0, sin(f.psi))
			var before := f.psi
			f.step(DT, left, f.cruise, 1.0, 0.0)
			if i * DT >= 4.0:
				yaw += wrapf(f.psi - before, -PI, PI)
				t += DT
		var e_turn := absf(absf(yaw) / t / perf["turn_rate"] - 1.0)
		# sustained climb
		f = _mk(sp, m)
		var h := 0.0
		var h0 := 0.0
		t = 0.0
		for i in int(16.0 / DT):
			f.step(DT, Vector3(0, 1, -0.2), f.cruise, 1.0, 0.0)
			h += f.air_velocity().y * DT
			if i * DT >= 6.0:
				if t == 0.0:
					h0 = h
				t += DT
		var e_cl := absf((h - h0) / t / perf["climb"] - 1.0)
		# tucked dive
		f = _mk(sp, m)
		var top := 0.0
		for i in int(30.0 / DT):
			f.step(DT, Vector3(0, -1, -0.05), 999.0, 0.0, 1.0)
			top = maxf(top, f.speed)
		var e_mx := absf(top / perf["max_speed"] - 1.0)
		lt(e_cr, TOL, "%s %.3f kg cruise error" % [sp, m])
		lt(e_turn, TOL, "%s %.3f kg sustained turn error" % [sp, m])
		lt(e_cl, TOL, "%s %.3f kg sustained climb error" % [sp, m])
		lt(e_mx, TOL, "%s %.3f kg tucked max-speed error" % [sp, m])
		worst["cruise"] = maxf(worst["cruise"], e_cr)
		worst["turn"] = maxf(worst["turn"], e_turn)
		worst["climb"] = maxf(worst["climb"], e_cl)
		worst["max"] = maxf(worst["max"], e_mx)
		rows.append("%s %.3f: cr %.3f turn %.3f climb %.3f max %.3f" % [sp, m, e_cr, e_turn, e_cl, e_mx])
	metric("worst_errors", worst)
	print("[ai-verify] envelope worst errors ", worst)
	for r in rows:
		print("[ai-verify]   ", r)
