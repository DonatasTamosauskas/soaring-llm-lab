extends RefCounted

## Aerodynamics of [FlightModel], headless.

const DT: float = 1.0 / 90.0

func _cmd(alpha: float = FlightModel.ALPHA_ZERO_LIFT + 0.16, bank: float = 0.0, spread: float = 1.0, flap: float = 0.0) -> FlightCommand:
	var c := FlightCommand.new()
	c.alpha = alpha; c.bank = bank; c.spread = spread; c.flap = flap
	return c

func _fly(m: FlightModel, c: FlightCommand, seconds: float) -> void:
	var n: int = int(seconds / DT)
	for i in n:
		m.step(c, DT)

func run(t: TestCase) -> void:
	_test_trim_glide(t)
	_test_lift_does_no_work(t)
	_test_coordinated_turn(t)
	_test_stall_and_recovery(t)
	_test_dive_and_zoom(t)
	_test_flap_climbs(t)
	_test_terminal_velocity(t)
	_test_size_changes_handling(t)
	_test_nan_resistance(t)
	_test_asymmetric_flap_yaws(t)
	_test_body_basis(t)
	_test_tuck_reduces_lift(t)

func _test_trim_glide(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 200, 0), Vector3.FORWARD)
	var v0: float = m.velocity.length()
	t.gt(v0, m.stall_speed(), "trim speed is above stall speed")
	t.lt(v0, 25.0, "a hawk does not cruise above 25 m/s")
	var c := _cmd(deg_to_rad(6.0))
	_fly(m, c, 12.0)
	t.finite3(m.velocity, "glide stays finite")
	var v: float = m.velocity.length()
	t.gt(v, m.stall_speed() * 0.95, "steady glide does not stall")
	t.lt(v, v0 * 1.6, "steady glide does not run away")
	var horiz: float = Vector2(m.position.x, m.position.z).length()
	var drop: float = 200.0 - m.position.y
	t.gt(drop, 0.0, "a glide sinks")
	t.gt(horiz / drop, 6.0, "glide ratio better than 6:1 (got %.1f)" % (horiz / drop))
	t.lt(horiz / drop, 22.0, "glide ratio is bird-like, not sailplane (got %.1f)" % (horiz / drop))
	t.ok(not m.stalled, "not stalled at 6 degrees")

func _test_lift_does_no_work(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 100, 0), Vector3.FORWARD)
	var c := _cmd(deg_to_rad(8.0), deg_to_rad(35.0))
	var worst: float = 0.0
	for i in 600:
		m.step(c, DT)
		var l: float = m.last_lift.length()
		if l > 1e-3:
			worst = maxf(worst, absf(m.last_lift.dot((m.velocity - m.wind).normalized())) / l)
	t.lt(worst, 0.06, "lift stays perpendicular to the airflow (max cos %.3f)" % worst)

func _test_coordinated_turn(t: TestCase) -> void:
	for bank_deg in [25.0, 45.0]:
		var m := FlightModel.new(1.0)
		m.launch(Vector3(0, 300, 0), Vector3.FORWARD)
		var c := _cmd(deg_to_rad(9.0), deg_to_rad(bank_deg))
		_fly(m, c, 3.0)  # let the bank establish
		var h0: Vector3 = Vector3(m.heading.x, 0, m.heading.z).normalized()
		var ideal_sum: float = 0.0
		var n: int = int(6.0 / DT)
		for i in n:
			m.step(c, DT)
			ideal_sum += m.ideal_turn_rate() * DT
		var h1: Vector3 = Vector3(m.heading.x, 0, m.heading.z).normalized()
		var turned: float = absf(fmod(h0.signed_angle_to(h1, Vector3.UP), TAU))
		# Unwrap: over six seconds at these banks the turn may exceed 180 deg.
		var total: float = 0.0
		var prev: Vector3 = h0
		# Recompute with fine sampling to unwrap.
		var m2 := FlightModel.new(1.0)
		m2.launch(Vector3(0, 300, 0), Vector3.FORWARD)
		_fly(m2, c, 3.0)
		prev = Vector3(m2.heading.x, 0, m2.heading.z).normalized()
		for i in n:
			m2.step(c, DT)
			var cur: Vector3 = Vector3(m2.heading.x, 0, m2.heading.z).normalized()
			total += prev.signed_angle_to(cur, Vector3.UP)
			prev = cur
		var sign_ok: bool = total < 0.0  # right bank => clockwise from above => negative angle about +Y
		t.ok(sign_ok, "bank right turns right at %.0f deg (total %.2f rad)" % [bank_deg, total])
		var ratio: float = absf(total) / maxf(ideal_sum, 1e-3)
		t.ok(ratio > 0.85 and ratio < 1.15, "turn rate matches g*tan(phi)/V within 15%% at %.0f deg (ratio %.2f)" % [bank_deg, ratio])
		t.ok(not m.stalled, "coordinated turn at %.0f deg does not stall" % bank_deg)
		t.ok(turned >= 0.0, "unused")

func _test_stall_and_recovery(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 300, 0), Vector3.FORWARD)
	var glide := _cmd(deg_to_rad(8.0))
	_fly(m, glide, 4.0)
	var y_a: float = m.position.y
	_fly(m, glide, 2.0)
	var sink_glide: float = (y_a - m.position.y) / 2.0
	var m2 := FlightModel.new(1.0)
	m2.launch(Vector3(0, 300, 0), Vector3.FORWARD)
	var deep := _cmd(deg_to_rad(30.0))
	_fly(m2, deep, 4.0)
	t.ok(m2.stalled, "30 degrees of attack stalls")
	var y_b: float = m2.position.y
	_fly(m2, deep, 2.0)
	var sink_stall: float = (y_b - m2.position.y) / 2.0
	t.gt(sink_stall, sink_glide * 1.6, "a stalled bird sinks much faster (%.1f vs %.1f m/s)" % [sink_stall, sink_glide])
	# Lower the nose: it flies out of it.
	_fly(m2, _cmd(deg_to_rad(3.0)), 4.0)
	t.ok(not m2.stalled, "lowering the nose recovers from the stall")
	t.gt(m2.velocity.length(), m2.stall_speed(), "speed rebuilt after recovery")

func _test_dive_and_zoom(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 400, 0), Vector3.FORWARD)
	var v0: float = m.velocity.length()
	_fly(m, _cmd(deg_to_rad(0.0), 0.0, 0.0), 4.0)   # tuck
	var v_dive: float = m.velocity.length()
	t.gt(v_dive, v0 * 1.8, "a four-second tuck nearly doubles the speed (%.1f -> %.1f)" % [v0, v_dive])
	t.lt(m.velocity.y, -10.0, "a tuck is a dive")
	var y_low: float = m.position.y
	_fly(m, _cmd(deg_to_rad(13.0), 0.0, 1.0), 2.5)     # spread and pull up
	t.gt(m.position.y, y_low, "spreading and flaring converts speed to height (zoom climb)")
	t.gt(m.velocity.y, -2.0, "still going up or level after the zoom")
	t.lt(m.velocity.length(), v_dive, "the zoom spends the speed")

func _test_flap_climbs(t: TestCase) -> void:
	var glider := FlightModel.new(1.0)
	glider.launch(Vector3(0, 200, 0), Vector3.FORWARD)
	_fly(glider, _cmd(deg_to_rad(6.0)), 10.0)
	var flapper := FlightModel.new(1.0)
	flapper.launch(Vector3(0, 200, 0), Vector3.FORWARD)
	var c := _cmd(deg_to_rad(6.0))
	var n: int = int(10.0 / DT)
	for i in n:
		var phase: float = fmod(i * DT * 2.5, 1.0)
		c.flap = 1.0 if phase < 0.45 else 0.0
		flapper.step(c, DT)
	t.gt(flapper.position.y, glider.position.y + 20.0, "ten seconds of beating buys a lot of height over gliding (%.1f vs %.1f)" % [flapper.position.y, glider.position.y])
	t.gt(flapper.position.y, 200.0 - 5.0, "hard flapping at least holds altitude (%.1f)" % flapper.position.y)
	t.lt(flapper.velocity.length(), 35.0, "flapping does not turn a hawk into a jet (%.1f m/s)" % flapper.velocity.length())

func _test_terminal_velocity(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 3000, 0), Vector3.FORWARD)
	_fly(m, _cmd(deg_to_rad(-2.0), 0.0, 0.0), 25.0)
	var v1: float = m.velocity.length()
	_fly(m, _cmd(deg_to_rad(-2.0), 0.0, 0.0), 2.0)
	var v2: float = m.velocity.length()
	t.lt(absf(v2 - v1), 1.0, "tucked dive reaches a terminal velocity (%.1f -> %.1f)" % [v1, v2])
	t.gt(v2, 40.0, "a tucked hawk stoops fast (%.1f m/s)" % v2)
	t.lt(v2, FlightModel.MAX_SPEED, "below the hard clamp")

func _test_size_changes_handling(t: TestCase) -> void:
	var small := FlightModel.new(0.5)
	var big := FlightModel.new(3.0)
	t.gt(big.wing_loading(), small.wing_loading(), "bigger birds carry more weight per wing area")
	t.gt(big.trim_speed(), small.trim_speed(), "bigger birds cruise faster")
	t.gt(big.stall_speed(), small.stall_speed(), "bigger birds stall faster")
	t.lt(big.trim_speed() / small.trim_speed(), 2.0, "but not absurdly so (%.2fx)" % (big.trim_speed() / small.trim_speed()))
	# Turn radius at the same bank scales with V^2: big birds turn wider.
	var rs: float = small.trim_speed() * small.trim_speed() / (FlightModel.G * tan(0.6))
	var rb: float = big.trim_speed() * big.trim_speed() / (FlightModel.G * tan(0.6))
	t.gt(rb, rs * 1.3, "big birds need wider turns (%.1f m vs %.1f m)" % [rb, rs])

func _test_nan_resistance(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 100, 0), Vector3.FORWARD)
	m.velocity = Vector3(NAN, 1, 1)
	m.step(_cmd(), DT)
	t.finite3(m.velocity, "NaN velocity is repaired")
	t.finite3(m.position, "position stays finite")
	var c := FlightCommand.new()
	c.alpha = NAN
	c.bank = INF
	m.step(c, DT)
	t.finite3(m.velocity, "hostile command cannot poison the model")
	m.step(_cmd(), 0.0)
	m.step(_cmd(), -1.0)
	t.finite3(m.velocity, "zero and negative dt are ignored")
	m.velocity = Vector3.ZERO
	m.step(_cmd(), DT)
	t.finite3(m.velocity, "zero airspeed is fine")

func _test_asymmetric_flap_yaws(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3(0, 100, 0), Vector3.FORWARD)
	var c := _cmd(deg_to_rad(6.0))
	c.flap = 1.0
	c.flap_asym = 1.0   # right wing harder
	var h0: Vector3 = m.heading
	_fly(m, c, 1.0)
	var ang: float = h0.signed_angle_to(Vector3(m.heading.x, 0, m.heading.z).normalized(), Vector3.UP)
	t.gt(ang, 0.05, "beating the right wing harder yaws left (%.2f rad)" % ang)

func _test_body_basis(t: TestCase) -> void:
	var m := FlightModel.new(1.0)
	m.launch(Vector3.ZERO, Vector3(1, 0, -1))
	m.bank = 0.5
	m.alpha = 0.2
	var b: Basis = m.body_basis()
	t.near(b.x.length(), 1.0, 1e-4, "basis x unit")
	t.near(b.y.length(), 1.0, 1e-4, "basis y unit")
	t.near(b.z.length(), 1.0, 1e-4, "basis z unit")
	t.near(b.x.dot(b.y), 0.0, 1e-4, "basis orthogonal xy")
	t.near(b.y.dot(b.z), 0.0, 1e-4, "basis orthogonal yz")
	t.near(b.determinant(), 1.0, 1e-3, "basis is right-handed")
	t.lt(b.x.y, 0.0, "banking right drops the right wing")
	m.launch(Vector3.ZERO, Vector3.UP)
	t.finite3(m.body_basis().x, "vertical heading does not break the basis")

func _test_tuck_reduces_lift(t: TestCase) -> void:
	var open := FlightModel.new(1.0)
	var shut := FlightModel.new(1.0)
	open.launch(Vector3(0, 100, 0), Vector3.FORWARD, 14.0)
	shut.launch(Vector3(0, 100, 0), Vector3.FORWARD, 14.0)
	open.step(_cmd(deg_to_rad(6.0), 0.0, 1.0), DT)
	shut.step(_cmd(deg_to_rad(6.0), 0.0, 0.0), DT)
	t.lt(shut.last_lift.length(), open.last_lift.length() * 0.3, "tucked wings make a fraction of the lift")
	t.lt(shut.last_drag.length(), open.last_drag.length(), "and less drag than open wings at cruise")
