class_name FlightTests
extends RefCounted

## The specification for "flight feels right", written as physics.
##
## Every one of these ran red at some point during tuning; they are the reason
## the numbers in [FlightModel] are the numbers they are.

const DT: float = 1.0 / 90.0


static func run(t: TestCase) -> void:
	_test_integrator_conserves_energy(t)
	_test_trim_glide_is_stable(t)
	_test_glide_ratio_is_birdlike(t)
	_test_dive_trades_altitude_for_speed(t)
	_test_tuck_dives_harder_than_spread(t)
	_test_zoom_climb_trades_speed_for_altitude(t)
	_test_flapping_climbs_from_a_standstill(t)
	_test_gliding_alone_never_gains_energy(t)
	_test_flapping_needs_open_wings(t)
	_test_stall_collapses_lift_and_is_recoverable(t)
	_test_bank_produces_a_coordinated_turn(t)
	_test_bigger_birds_turn_wider(t)
	_test_dive_speed_is_bounded(t)
	_test_survives_hostile_input(t)


## The strongest single check on the integrator. With drag switched off, lift
## acts perpendicular to velocity and therefore does no work, so total energy
## must be conserved through an arbitrary banked, curving flight path. If this
## drifts, every "dive for speed" behaviour above it is built on sand.
static func _test_integrator_conserves_energy(t: TestCase) -> void:
	t.begin("integrator conserves energy without drag")
	var m := FlightModel.new()
	m.cd0 = 0.0
	m.induced_k = 0.0
	m.stall_cd = 0.0
	m.high_alpha_cd = 0.0
	m.base_body_drag_area = 0.0
	m.set_size(1.0)

	var h := FlightHarness.new(m)
	h.launch(22.0, 0.0, 1000.0)
	var cmd := FlightCommand.new()
	cmd.alpha = m.alpha_trim
	cmd.bank = deg_to_rad(35.0)  # curving flight exercises the whole frame
	var start_energy: float = h.specific_energy()
	h.fly(cmd, 20.0)
	var drift: float = absf(h.specific_energy() - start_energy) / start_energy
	t.less(drift, 0.02, "specific energy drifted over 20s of banked flight")


## Hands relaxed and level should be a usable glide, not a departure into an
## oscillation or a stall. This is the pose a new player holds by default, so it
## has to be forgiving.
static func _test_trim_glide_is_stable(t: TestCase) -> void:
	t.begin("neutral hands produce a stable glide")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	var v_trim: float = m.trim_speed()
	t.in_range(v_trim, 10.0, 30.0, "trim speed is a sensible cruise")

	h.launch(v_trim, 0.0, 500.0)
	var cmd := FlightCommand.new()
	cmd.alpha = m.alpha_trim
	h.fly(cmd, 25.0)

	t.ok(not h.ever_nonfinite, "state stayed finite")
	t.in_range(h.speed() / v_trim, 0.75, 1.35, "speed stayed near trim (no phugoid blow-up)")
	t.ok(not m.is_stalled, "trim glide does not stall")
	var sink_rate: float = (500.0 - h.altitude) / 25.0
	t.in_range(sink_rate, 0.5, 5.0, "sink rate is a glide, not a plummet")


static func _test_glide_ratio_is_birdlike(t: TestCase) -> void:
	t.begin("best glide ratio is in a birdlike range")
	var m := FlightModel.new()
	var best: float = 0.0
	# Sweep angle of attack to find the wing's best lift-to-drag ratio.
	for i in 40:
		var alpha: float = 0.02 + 0.008 * i
		var h := FlightHarness.new(FlightModel.new())
		h.launch(h.model.trim_speed(), 0.0, 4000.0)
		var cmd := FlightCommand.new()
		cmd.alpha = alpha
		var start: Vector3 = h.position
		h.fly(cmd, 40.0)  # long enough to settle onto its natural glide
		var ratio: float = h.glide_ratio(start)
		if is_finite(ratio):
			best = maxf(best, ratio)
	t.in_range(best, 5.0, 16.0, "best L/D sits between a pigeon and an albatross")


## The move the whole game is built around: point down, get fast.
static func _test_dive_trades_altitude_for_speed(t: TestCase) -> void:
	t.begin("diving converts altitude into speed")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(12.0, 0.0, 900.0)
	var cmd := FlightCommand.new()
	cmd.span = 0.25
	cmd.alpha = -0.06
	var start_energy: float = h.specific_energy()
	h.fly(cmd, 7.0)

	t.greater(h.speed(), 34.0, "a 7 second tuck dive builds real speed")
	t.less(h.altitude, 900.0, "the bird actually descended")
	var kept: float = h.specific_energy() / start_energy
	t.greater(kept, 0.55, "a tuck dive is efficient, not a drag brake")
	t.less(kept, 1.0, "a dive cannot create energy")


static func _test_tuck_dives_harder_than_spread(t: TestCase) -> void:
	t.begin("tucking accelerates harder than spread wings")
	var tucked := FlightHarness.new(FlightModel.new())
	tucked.launch(12.0, -0.3, 900.0)
	var c1 := FlightCommand.new()
	c1.span = 0.1
	c1.alpha = 0.0
	tucked.fly(c1, 6.0)

	var spread := FlightHarness.new(FlightModel.new())
	spread.launch(12.0, -0.3, 900.0)
	var c2 := FlightCommand.new()
	c2.span = 1.0
	c2.alpha = 0.0
	spread.fly(c2, 6.0)

	t.greater(tucked.speed() - spread.speed(), 5.0, "tuck is clearly the faster dive")


## The payoff move: arrive fast and low, then convert that speed straight back
## into height. Without this, a dive is a one-way trip and the flight loop has
## no rhythm.
static func _test_zoom_climb_trades_speed_for_altitude(t: TestCase) -> void:
	t.begin("pulling up converts speed into altitude")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(48.0, 0.0, 100.0)
	var cmd := FlightCommand.new()
	cmd.span = 1.0
	# Hold just under the stall so the pull-up is aggressive but clean.
	cmd.alpha = m.alpha_stall * 0.85
	var start_energy: float = h.specific_energy()
	var start_altitude: float = h.altitude
	h.fly(cmd, 4.0)

	t.greater(h.peak_altitude - start_altitude, 40.0, "a 48 m/s zoom climb gains real height")
	t.less(h.speed(), 40.0, "speed was spent buying that height")
	t.greater(h.specific_energy() / start_energy, 0.6, "the exchange is not ruinously lossy")


static func _test_flapping_climbs_from_a_standstill(t: TestCase) -> void:
	t.begin("flapping climbs from a standstill")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(0.0, 0.0, 100.0)
	var cmd := FlightCommand.new()
	cmd.alpha = m.alpha_trim
	# ~1.8 flaps/second: a 0.25s downstroke, then a recovery stroke.
	var driver := func(_harness: FlightHarness, c: FlightCommand, time: float) -> void:
		var phase: float = fmod(time, 0.55)
		c.stroke_speed = 3.0 if phase < 0.25 else 0.0
	h.fly(cmd, 8.0, driver)

	t.greater(h.altitude, 100.0, "sustained flapping gains altitude from rest")
	t.greater(h.speed(), 6.0, "flapping also builds forward speed")
	t.ok(not h.ever_nonfinite, "state stayed finite")


static func _test_gliding_alone_never_gains_energy(t: TestCase) -> void:
	t.begin("gliding cannot create energy")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(25.0, 0.0, 2000.0)
	var cmd := FlightCommand.new()
	var previous: float = h.specific_energy()
	var violations: int = 0
	# Wobble the controls throughout: no amount of flapping-free stick-waggling
	# should ever be a free energy source.
	for i in 400:
		cmd.alpha = m.alpha_trim + 0.25 * sin(float(i) * 0.11)
		cmd.bank = 0.7 * sin(float(i) * 0.07)
		cmd.span = 0.5 + 0.5 * sin(float(i) * 0.05)
		h.fly(cmd, 0.1)
		var now: float = h.specific_energy()
		if now > previous + 1e-3:
			violations += 1
		previous = now
	t.ok(violations == 0, "energy increased on %d of 400 control inputs" % violations)


static func _test_flapping_needs_open_wings(t: TestCase) -> void:
	t.begin("flapping with tucked wings does almost nothing")
	var open := FlightHarness.new(FlightModel.new())
	open.launch(0.0, 0.0, 100.0)
	var c1 := FlightCommand.new()
	c1.span = 1.0
	c1.stroke_speed = 3.0
	open.fly(c1, 2.0)

	var shut := FlightHarness.new(FlightModel.new())
	shut.launch(0.0, 0.0, 100.0)
	var c2 := FlightCommand.new()
	c2.span = 0.05
	c2.stroke_speed = 3.0
	shut.fly(c2, 2.0)

	# Compare altitude, not raw speed: a tucked bird beating its stumps still
	# picks up plenty of speed, all of it straight down.
	t.greater(open.altitude, 100.0, "open wings beat gravity")
	t.less(shut.altitude, 90.0, "tucked wings fall out of the sky regardless of effort")
	t.greater(open.model.velocity.y, 0.0, "open wings produce a climb")
	t.less(shut.model.velocity.y, -5.0, "tucked wings produce a fall")


static func _test_stall_collapses_lift_and_is_recoverable(t: TestCase) -> void:
	t.begin("stalling is punishing but recoverable")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(14.0, 0.0, 600.0)
	var cmd := FlightCommand.new()
	cmd.alpha = m.alpha_stall * 2.0  # yanked well past the break
	h.fly(cmd, 3.0)

	t.ok(m.is_stalled, "holding too much angle of attack stalls the wing")
	t.less(m.load_factor, 1.0, "a stalled wing cannot carry the bird's weight")
	var stalled_altitude: float = h.altitude
	t.less(stalled_altitude, 600.0, "the bird sinks while stalled")

	# Recovery: lower the nose, let it fly again.
	cmd.alpha = 0.0
	h.fly(cmd, 4.0)
	t.ok(not m.is_stalled, "lowering the nose unstalls the wing")
	t.greater(h.speed(), 18.0, "speed comes back after recovery")


## Textbook coordinated turn: omega = g * tan(bank) / V. Because the model
## turns by tilting real lift rather than by scripting a yaw rate, it should
## land close to the analytic answer on its own.
static func _test_bank_produces_a_coordinated_turn(t: TestCase) -> void:
	t.begin("banking produces a physically correct turn rate")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	var bank_angle: float = deg_to_rad(45.0)
	h.launch(m.trim_speed() * 1.25, 0.0, 3000.0)
	var cmd := FlightCommand.new()
	cmd.bank = bank_angle
	# Hold the extra AoA a level 45-degree turn needs (load factor 1/cos(bank)).
	cmd.alpha = m.alpha_trim / cos(bank_angle)
	h.fly(cmd, 1.0)  # let the roll settle before measuring

	var heading_before: float = m.heading
	var speed_before: float = h.speed()
	h.fly(cmd, 2.0)
	var swept: float = absf(wrapf(m.heading - heading_before, -PI, PI))
	var measured_rate: float = swept / 2.0
	var expected_rate: float = m.gravity * tan(bank_angle) / speed_before

	t.greater(measured_rate, 0.15, "a 45 degree bank actually turns the bird")
	t.near(
		measured_rate,
		expected_rate,
		expected_rate * 0.45,
		"turn rate matches g*tan(bank)/V"
	)


static func _test_bigger_birds_turn_wider(t: TestCase) -> void:
	t.begin("bigger birds carry more momentum through turns")
	var radii: Array[float] = []
	for s: float in [1.0, 3.0]:
		var m := FlightModel.new(s)
		var h := FlightHarness.new(m)
		h.launch(m.trim_speed() * 1.2, 0.0, 5000.0)
		var cmd := FlightCommand.new()
		cmd.bank = deg_to_rad(50.0)
		cmd.alpha = m.alpha_trim / cos(deg_to_rad(50.0))
		h.fly(cmd, 1.5)
		var heading_before: float = m.heading
		var speed_before: float = h.speed()
		h.fly(cmd, 2.0)
		var rate: float = absf(wrapf(m.heading - heading_before, -PI, PI)) / 2.0
		radii.append(speed_before / maxf(rate, 1e-3))
	t.greater(radii[1], radii[0] * 1.15, "a size-3 bird needs a noticeably wider arc")


static func _test_dive_speed_is_bounded(t: TestCase) -> void:
	t.begin("a vertical dive reaches a bounded terminal speed")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(20.0, -PI * 0.5, 100000.0)
	var cmd := FlightCommand.new()
	cmd.span = 0.0
	cmd.alpha = 0.0
	h.fly(cmd, 60.0)
	t.ok(not h.ever_nonfinite, "state stayed finite through a 60s dive")
	t.less(h.peak_speed, m.hard_speed_cap + 0.5, "speed never exceeds the hard cap")
	t.greater(h.speed(), 40.0, "a full tuck really is fast")


## Tracking drops out. Controllers get yanked off a desk. A single NaN in the
## velocity would freeze the player mid-air forever, so the model has to eat
## garbage without breaking.
static func _test_survives_hostile_input(t: TestCase) -> void:
	t.begin("hostile input cannot poison the simulation")
	var m := FlightModel.new()
	var h := FlightHarness.new(m)
	h.launch(20.0, 0.0, 500.0)
	var cmd := FlightCommand.new()

	var nan_value: float = sqrt(-1.0)
	var poisons: Array = [
		func() -> void: cmd.alpha = nan_value,
		func() -> void: cmd.bank = INF,
		func() -> void: cmd.span = -INF,
		func() -> void: cmd.stroke_speed = nan_value,
		func() -> void: cmd.wind = Vector3(nan_value, INF, 0.0),
		func() -> void: cmd.asymmetry = 1e30,
	]
	for poison: Callable in poisons:
		poison.call()
		m.step(cmd, DT)
		t.finite(m.velocity, "velocity survived poisoned input")
		t.finite(m.heading, "heading survived poisoned input")
		t.finite(m.bank, "bank survived poisoned input")
		cmd.reset()

	# Degenerate timesteps.
	for bad_dt: float in [0.0, -1.0, nan_value, 1e9]:
		m.step(cmd, bad_dt)
		t.finite(m.velocity, "velocity survived dt=%s" % str(bad_dt))

	# Degenerate airspeed and a dead-vertical airflow frame.
	m.velocity = Vector3.ZERO
	m.step(cmd, DT)
	t.finite(m.velocity, "velocity survived zero airspeed")
	m.velocity = Vector3(0.0, -30.0, 0.0)
	cmd.bank = 1.0
	m.step(cmd, DT)
	t.finite(m.velocity, "velocity survived a dead-vertical dive")

	m.set_size(nan_value)
	t.finite(m.size_scale, "size survived a NaN scale")
