extends TestCase
## A4 size fairness: every species' NPC flight envelope, measured by flying
## the NpcFlight model through standard manoeuvres, lands within 10% of
## SizeRules.performance(mass). Also pins the aerodynamic relationships the
## brief asks for (energy trade, glide, coordinated bank, stall recovery).

const DT := 1.0 / 72.0
const TOL := 0.10


func _species() -> Array:
	var out := []
	for s in SizeRules.SPECIES:
		out.append(s)
	return out


func _make(s: Dictionary) -> NpcFlight:
	var f := NpcFlight.new(s["mass"], SpeciesProfile.of(s["id"])["glide_ratio"])
	f.set_velocity(Vector3(0, 0, -f.cruise))
	return f


func _within(measured: float, target: float, what: String) -> bool:
	return between(measured, target * (1.0 - TOL), target * (1.0 + TOL), what)


func test_cruise_speed_matches() -> void:
	var table := {}
	for s in _species():
		var f := _make(s)
		f.set_velocity(Vector3(0, 0, -f.cruise * 0.6))
		var y := 0.0
		for i in int(8.0 / DT):
			f.step(DT, Vector3.FORWARD, f.cruise, 1.0, 0.0)
			y += f.air_velocity().y * DT
		var perf := SizeRules.performance(s["mass"])
		_within(f.speed, perf["cruise"], "%s cruise speed" % s["id"])
		lt(absf(f.air_velocity().y), 0.2, "%s level at cruise" % s["id"])
		table[s["id"]] = snappedf(f.speed, 0.01)
	metric("cruise", table)


func test_min_speed_matches() -> void:
	var table := {}
	for s in _species():
		var f := _make(s)
		for i in int(10.0 / DT):
			f.step(DT, Vector3.FORWARD, 0.0, 1.0, 0.0)
		var perf := SizeRules.performance(s["mass"])
		_within(f.speed, perf["min_speed"], "%s slowest controllable speed" % s["id"])
		lt(absf(f.air_velocity().y), 0.3, "%s holds height at min speed" % s["id"])
		check(not f.stalled, "%s not stalled at min speed" % s["id"])
		table[s["id"]] = snappedf(f.speed, 0.01)
	metric("min_speed", table)


func test_tucked_dive_reaches_max_speed() -> void:
	var table := {}
	for s in _species():
		var f := _make(s)
		var top := 0.0
		for i in int(25.0 / DT):
			f.step(DT, Vector3(0, -1, -0.05), 999.0, 0.0, 1.0)
			top = maxf(top, f.speed)
		var perf := SizeRules.performance(s["mass"])
		_within(top, perf["max_speed"], "%s tucked dive top speed" % s["id"])
		lt(top, perf["max_speed"] * 1.0001, "%s never exceeds max_speed" % s["id"])
		table[s["id"]] = snappedf(top, 0.01)
	metric("max_speed", table)


func test_spread_dive_is_much_slower_than_tucked() -> void:
	# Tucking is what makes a stoop a stoop.
	for s in _species():
		var f := _make(s)
		for i in int(25.0 / DT):
			f.step(DT, Vector3(0, -1, -0.05), 999.0, 0.0, 0.0)
		lt(f.speed, f.max_speed * 0.72, "%s spread-wing dive capped well below max" % s["id"])
		gt(f.speed, f.cruise * 1.2, "%s spread dive still faster than cruise" % s["id"])


func test_sustained_turn_rate_matches() -> void:
	var table := {}
	for s in _species():
		var f := _make(s)
		var yaw := 0.0
		var t := 0.0
		var sp_sum := 0.0
		var bank_sum := 0.0
		var y0 := 0.0
		var y := 0.0
		for i in int(14.0 / DT):
			# Always want to be 90 degrees left of where we point: max-rate turn.
			var left := Vector3(-cos(f.psi), 0, sin(f.psi))
			var before := f.psi
			f.step(DT, left, f.cruise, 1.0, 0.0)
			y += f.air_velocity().y * DT
			if i * DT >= 4.0:
				if t == 0.0:
					y0 = y
				yaw += wrapf(f.psi - before, -PI, PI)
				t += DT
				sp_sum += f.speed * DT
				bank_sum += f.bank * DT
		var perf := SizeRules.performance(s["mass"])
		var rate := absf(yaw) / t
		_within(rate, perf["turn_rate"], "%s sustained turn rate" % s["id"])
		_within(sp_sum / t, perf["cruise"], "%s holds cruise in the max turn" % s["id"])
		lt(absf(y - y0), 1.5 * t / 10.0, "%s level in the max turn" % s["id"])
		# Coordinated: bank = atan(omega v / g); turning left means left wing
		# down, i.e. negative BirdModel bank.
		var want_bank := -atan(perf["turn_rate"] * perf["cruise"] / NpcFlight.G)
		near(bank_sum / t, want_bank, 0.1, "%s coordinated bank angle" % s["id"])
		table[s["id"]] = snappedf(rad_to_deg(rate), 0.1)
	metric("turn_rate_deg", table)


func test_sustained_climb_matches() -> void:
	var table := {}
	for s in _species():
		var f := _make(s)
		var h0 := 0.0
		var h := 0.0
		var t := 0.0
		for i in int(16.0 / DT):
			f.step(DT, Vector3(0, 1, -0.2), f.cruise, 1.0, 0.0)
			h += f.air_velocity().y * DT
			if i * DT >= 6.0:
				if t == 0.0:
					h0 = h
				t += DT
		var perf := SizeRules.performance(s["mass"])
		_within((h - h0) / t, perf["climb"], "%s sustained climb rate" % s["id"])
		_within(f.speed, perf["cruise"], "%s climbs at cruise" % s["id"])
		table[s["id"]] = snappedf((h - h0) / t, 0.01)
	metric("climb", table)


func test_zoom_climb_trades_speed_for_height() -> void:
	# Energy trade: a fast bird pulling up gains more height than its steady
	# climb would give, and loses speed doing it.
	# (A hawk pulling out of a stoop keeps its wings half folded: fully spread
	# at twice cruise the drag would eat the energy instead.)
	var s: Dictionary = SizeRules.SPECIES[8]  # hawk
	var f := _make(s)
	f.set_velocity(Vector3(0, 0, -f.max_speed * 0.8))
	f.fold = 0.8
	var h := 0.0
	var v0 := f.speed
	for i in int(2.0 / DT):
		f.step(DT, Vector3(0, 1, -0.3), f.cruise, 0.0, 0.8)
		h += f.air_velocity().y * DT
	lt(f.speed, v0 * 0.8, "speed bled in the zoom")
	gt(h, f.climb * 2.0 * 2.0, "zoom gains far more than 2 s of steady climb")
	metric("zoom_height_2s", h)


func test_glide_sinks_at_glide_ratio() -> void:
	for s in _species():
		var f := _make(s)
		var h := 0.0
		var dist := 0.0
		for i in int(12.0 / DT):
			f.step(DT, Vector3.FORWARD, f.v_md, 0.0, 0.0)
			if i * DT > 4.0:
				var v := f.air_velocity()
				h += v.y * DT
				dist += Vector2(v.x, v.z).length() * DT
		var gr: float = SpeciesProfile.of(s["id"])["glide_ratio"]
		lt(h, 0.0, "%s gliding loses height" % s["id"])
		near(dist / -h, gr, gr * 0.12, "%s glide ratio at best-glide speed" % s["id"])
		lt(f.effort, 0.001, "%s no flapping in a glide" % s["id"])


func test_stall_recovers_by_dropping_the_nose() -> void:
	var f := _make(SizeRules.SPECIES[5])  # pigeon
	f.set_velocity(Vector3(0, 0, -f.min_speed * 0.5))
	var min_gamma := 0.0
	for i in int(4.0 / DT):
		f.step(DT, Vector3(0, 0.5, -1), f.cruise, 0.3, 0.0)
		min_gamma = minf(min_gamma, f.gamma)
	lt(min_gamma, -0.2, "nose dropped while stalled")
	gt(f.speed, f.min_speed, "flying speed recovered")
	check(not f.stalled, "no longer stalled")


func test_bigger_is_faster_but_turns_wider() -> void:
	var prev_speed := 0.0
	var prev_radius := 0.0
	for s in _species():
		var f := _make(s)
		var r := f.cruise / f.max_turn_rate(f.cruise)
		gt(f.cruise, prev_speed, "%s cruises faster than the smaller species" % s["id"])
		gt(r, prev_radius, "%s turns wider than the smaller species" % s["id"])
		prev_speed = f.cruise
		prev_radius = r
