class_name WingInputTests
extends RefCounted

## Drives [WingInput] with synthetic controller poses. Hand-testing an input
## mapping in a headset is slow and unrepeatable; this pins the behaviour down
## so tuning one gesture cannot silently break another.

const DT: float = 1.0 / 90.0
const HEAD_HEIGHT: float = 1.60
const HAND_OUT: float = 0.70
const HAND_FORWARD: float = -0.15  # -Z is forward, so this is 0.15 m ahead


static func run(t: TestCase) -> void:
	_test_neutral_pose_is_neutral(t)
	_test_arm_tilt_banks_the_right_way(t)
	_test_hands_together_tucks(t)
	_test_wrist_rotation_drives_angle_of_attack(t)
	_test_arm_sweep_drives_angle_of_attack(t)
	_test_a_real_flap_produces_thrust(t)
	_test_wrist_vibration_produces_nothing(t)
	_test_flapping_requires_raising_the_arms(t)
	_test_ducking_is_not_a_flap(t)
	_test_asymmetric_flap_yaws(t)
	_test_short_arms_still_reach_full_span(t)
	_test_calibration_always_finishes(t)
	_test_a_modest_spread_is_full_wings(t)
	_test_neutral_is_calibrated_not_assumed(t)
	_test_calibration_ignores_a_tuck(t)
	_test_wings_open_quickly_on_spawn(t)
	_test_tracking_loss_is_survivable(t)


# --- pose helpers ------------------------------------------------------------

static func _head(height: float = HEAD_HEIGHT) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, height, 0.0))


## A hand held out to the side. [param roll] tips the back of the hand backward,
## which is the wrist motion that increases angle of attack.
static func _hand(
	side: float,
	height: float,
	roll: float = 0.0,
	out: float = HAND_OUT,
	forward: float = HAND_FORWARD
) -> Transform3D:
	# Rotating about the wing axis (world X) tips the hand's up-vector fore/aft.
	var basis := Basis(Vector3.RIGHT, roll)
	return Transform3D(basis, Vector3(side * out, height, forward))


## Settles the smoother so a steady pose reports its steady-state value.
## Returns a copy, not the live command — [WingInput] reuses one object, so
## holding onto it would silently alias two "different" results together.
static func _settle(
	w: WingInput, head: Transform3D, left: Transform3D, right: Transform3D, seconds: float = 0.6
) -> FlightCommand:
	var steps: int = int(seconds / DT)
	for i in steps:
		w.update(head, left, right, true, true, DT)
	return _snapshot(w.command)


static func _snapshot(source: FlightCommand) -> FlightCommand:
	var copy := FlightCommand.new()
	copy.bank = source.bank
	copy.alpha = source.alpha
	copy.span = source.span
	copy.stroke_speed = source.stroke_speed
	copy.asymmetry = source.asymmetry
	copy.wind = source.wind
	return copy


# --- tests -------------------------------------------------------------------

static func _test_neutral_pose_is_neutral(t: TestCase) -> void:
	t.begin("relaxed wings-out pose is neutral")
	var w := WingInput.new()
	var cmd: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45)
	)
	t.greater(cmd.span, 0.9, "arms out reads as full span")
	t.near(cmd.bank, 0.0, 0.05, "level arms read as wings level")
	t.near(cmd.alpha, 0.105, 0.05, "relaxed hands sit near trim, not diving or stalling")
	t.near(cmd.stroke_speed, 0.0, 0.001, "holding still is not flapping")


static func _test_arm_tilt_banks_the_right_way(t: TestCase) -> void:
	t.begin("dropping a hand banks toward that hand")
	var w := WingInput.new()
	var right_down: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.70), _hand(1.0, 1.20)
	)
	t.greater(right_down.bank, 0.4, "right hand low banks right")

	w.reset()
	var left_down: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.20), _hand(1.0, 1.70)
	)
	t.less(left_down.bank, -0.4, "left hand low banks left")

	# A modest, comfortable arm tilt should already be a usable turn.
	w.reset()
	var gentle: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.58), _hand(1.0, 1.38)
	)
	t.in_range(gentle.bank, 0.25, 0.75, "a 20 cm arm tilt is a real but controllable bank")


static func _test_hands_together_tucks(t: TestCase) -> void:
	t.begin("hands drawn to the chest tucks the wings")
	var w := WingInput.new()
	_settle(w, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45))  # calibrate reach
	var cmd: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.35, 0.0, 0.09), _hand(1.0, 1.35, 0.0, 0.09)
	)
	t.less(cmd.span, 0.12, "hands together is a full tuck")


static func _test_wrist_rotation_drives_angle_of_attack(t: TestCase) -> void:
	t.begin("tipping the wrists changes angle of attack")
	var w := WingInput.new()
	# Establish neutral first — the sensor calibrates to whatever pose it sees
	# on spawn, so a tipped pose held from the start is by definition level.
	_settle(w, _head(), _hand(-1.0, 1.45, 0.0), _hand(1.0, 1.45, 0.0), 2.0)

	var back: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.45), _hand(1.0, 1.45, 0.45)
	)
	t.greater(back.alpha, 0.2, "wrists tipped back raise the nose")

	var forward: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, -0.45), _hand(1.0, 1.45, -0.45)
	)
	t.less(forward.alpha, 0.0, "wrists tipped forward drop the nose below level")
	t.greater(back.alpha - forward.alpha, 0.2, "the wrists alone span a useful pitch range")


static func _test_arm_sweep_drives_angle_of_attack(t: TestCase) -> void:
	t.begin("sweeping the arms fore and aft also changes angle of attack")
	var w := WingInput.new()
	# Calibrate against a relaxed pose first; sweep is measured from there.
	_settle(w, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45), 2.0)

	var swept_back: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.0, HAND_OUT, 0.25), _hand(1.0, 1.45, 0.0, HAND_OUT, 0.25)
	)
	t.greater(swept_back.alpha, 0.14, "arms swept back flares the bird")

	var ahead: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.0, HAND_OUT, -0.55), _hand(1.0, 1.45, 0.0, HAND_OUT, -0.55)
	)
	t.less(ahead.alpha, 0.07, "arms pushed out ahead lowers the nose")


## Feeds a full flap cycle: raise the arms, then drive them down.
static func _flap_cycle(
	w: WingInput, down_speed: float, travel: float, head: Transform3D
) -> float:
	var peak: float = 0.0
	var high: float = 1.75
	var low: float = high - travel
	# Upstroke, slow enough not to register as anything.
	var up_steps: int = int(travel / (0.6 * DT))
	for i in up_steps:
		var y: float = low + travel * (float(i) / float(maxi(up_steps - 1, 1)))
		w.update(head, _hand(-1.0, y), _hand(1.0, y), true, true, DT)
	# Downstroke.
	var down_steps: int = int(travel / (down_speed * DT))
	for i in down_steps:
		var y: float = high - travel * (float(i) / float(maxi(down_steps - 1, 1)))
		var cmd: FlightCommand = w.update(head, _hand(-1.0, y), _hand(1.0, y), true, true, DT)
		peak = maxf(peak, cmd.stroke_speed)
	return peak


static func _test_a_real_flap_produces_thrust(t: TestCase) -> void:
	t.begin("a real wingbeat produces thrust")
	var w := WingInput.new()
	var peak: float = _flap_cycle(w, 2.8, 0.65, _head())
	t.greater(peak, 2.0, "a full-arm downstroke registers at close to its true speed")
	t.less(peak, 4.0, "and is not wildly amplified")


## The mechanic only means anything if it cannot be shortcut. A player shaking
## their wrists moves fast but barely travels, and must get nothing for it.
static func _test_wrist_vibration_produces_nothing(t: TestCase) -> void:
	t.begin("shaking the controllers is not flying")
	var w := WingInput.new()
	var head: Transform3D = _head()
	var total_thrust: float = 0.0
	# 4 seconds of a fast 6 cm wrist shake at ~6 Hz.
	for i in int(4.0 / DT):
		var y: float = 1.45 + 0.03 * sin(float(i) * DT * TAU * 6.0)
		var cmd: FlightCommand = w.update(head, _hand(-1.0, y), _hand(1.0, y), true, true, DT)
		total_thrust += cmd.stroke_speed * DT
	t.less(total_thrust, 0.05, "four seconds of frantic shaking earns essentially no thrust")


static func _test_flapping_requires_raising_the_arms(t: TestCase) -> void:
	t.begin("you must raise your arms between wingbeats")
	var w := WingInput.new()
	var head: Transform3D = _head()
	# One clean stroke, then keep pressing downward without ever lifting again.
	# Credit integrates to distance travelled, so a proper 0.65 m beat is worth
	# 0.65 — the grind that follows must not come close to earning another one.
	_flap_cycle(w, 2.8, 0.65, head)
	var extra: float = 0.0
	var y: float = 1.10
	for i in int(2.0 / DT):
		y -= 2.5 * DT
		var cmd: FlightCommand = w.update(head, _hand(-1.0, y), _hand(1.0, y), true, true, DT)
		extra += cmd.stroke_speed * DT
	t.less(extra, 0.16, "two seconds of grinding downward is not a second wingbeat")


static func _test_ducking_is_not_a_flap(t: TestCase) -> void:
	t.begin("bobbing your head is not a flap")
	var w := WingInput.new()
	var total: float = 0.0
	# Whole body drops 40 cm quickly; hands stay put relative to the head.
	for i in int(1.0 / DT):
		var drop: float = 0.4 * (float(i) * DT)
		var head: Transform3D = _head(HEAD_HEIGHT - drop)
		var cmd: FlightCommand = w.update(
			head, _hand(-1.0, 1.45 - drop), _hand(1.0, 1.45 - drop), true, true, DT
		)
		total += cmd.stroke_speed * DT
	t.less(total, 0.02, "hands that never moved relative to the body earn no thrust")


static func _test_asymmetric_flap_yaws(t: TestCase) -> void:
	t.begin("flapping one wing harder yaws the bird")
	var w := WingInput.new()
	var head: Transform3D = _head()
	var high: float = 1.75
	var low: float = 1.10
	# Both arms genuinely raised, which is what arms the next beat.
	var up_steps: int = int(0.6 / DT)
	for i in up_steps:
		var y: float = low + (high - low) * (float(i) / float(up_steps - 1))
		w.update(head, _hand(-1.0, y), _hand(1.0, y), true, true, DT)
	# Right wing drives down hard, left wing barely moves.
	var seen: float = 0.0
	var yr: float = high
	var yl: float = high
	for i in int(0.25 / DT):
		yr -= 2.8 * DT
		yl -= 0.3 * DT
		var cmd: FlightCommand = w.update(head, _hand(-1.0, yl), _hand(1.0, yr), true, true, DT)
		if absf(cmd.asymmetry) > absf(seen):
			seen = cmd.asymmetry
	t.greater(seen, 0.5, "a hard right-wing beat yaws left")


static func _test_short_arms_still_reach_full_span(t: TestCase) -> void:
	t.begin("wingspan calibrates to the player")
	var w := WingInput.new()
	# A player whose full reach is only 0.9 m between the hands.
	var cmd: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.0, 0.45), _hand(1.0, 1.45, 0.0, 0.45), 4.0
	)
	t.greater(cmd.span, 0.9, "a smaller player still gets full wings")
	t.in_range(w.max_span, 0.85, 0.95, "calibration learned their actual reach")

	# ...and a long tuck must not be mistaken for short arms, or the player
	# would come out of a dive unable to spread their wings.
	var tucked := WingInput.new()
	_settle(tucked, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45), 1.0)
	_settle(tucked, _head(), _hand(-1.0, 1.35, 0.0, 0.09), _hand(1.0, 1.35, 0.0, 0.09), 6.0)
	var reopened: FlightCommand = _settle(
		tucked, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45), 0.8
	)
	t.greater(reopened.span, 0.9, "wings still open fully after a long tuck")




## The dead end behind the crash: neutral calibration only completed if it saw a
## wings-out pose, and reach calibration was gated behind neutral finishing. A
## player who never spread their arms was pinned to the default reach forever.
static func _test_calibration_always_finishes(t: TestCase) -> void:
	t.begin("calibration finishes even without a wings-out pose")
	var w := WingInput.new()
	var narrow_left: Transform3D = _hand(-1.0, 1.30, 0.0, 0.12)
	var narrow_right: Transform3D = _hand(1.0, 1.30, 0.0, 0.12)
	for i in int(5.0 / DT):
		w.update(_head(), narrow_left, narrow_right, true, true, DT)
	t.ok(not w._calibrating, "the calibration window closed on its own")


static func _test_a_modest_spread_is_full_wings(t: TestCase) -> void:
	t.begin("a comfortable spread is already full wings")
	var w := WingInput.new()
	# 0.9 m between the hands: arms out, elbows soft. Should be full span
	# without demanding a locked-out crucifix pose for the whole session.
	var cmd: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.0, 0.45), _hand(1.0, 1.45, 0.0, 0.45), 2.5
	)
	t.greater(cmd.span, 0.95, "a relaxed spread gives full wings")


## Found by running against the Meta XR Simulator: its resting controller pose
## read as 16.3 degrees of angle of attack, with the stall at 17.2. Whatever
## angle a player happens to hold their wrists at has to become "level", or the
## bird spawns stalled (or diving) for reasons invisible to them.
static func _test_neutral_is_calibrated_not_assumed(t: TestCase) -> void:
	t.begin("neutral is learned from the player, not assumed")
	for rest_angle: float in [-0.5, -0.25, 0.0, 0.3, 0.55]:
		var w := WingInput.new()
		var cmd: FlightCommand = _settle(
			w, _head(), _hand(-1.0, 1.45, rest_angle), _hand(1.0, 1.45, rest_angle), 2.0
		)
		t.near(
			cmd.alpha, 0.105, 0.05,
			"a rest pose of %.2f rad calibrates to level flight" % rest_angle
		)
		t.less(cmd.alpha, 0.30, "calibrated neutral is never at the stall")

		# ...and pitch authority still works either side of that new neutral.
		var up: FlightCommand = _settle(
			w, _head(), _hand(-1.0, 1.45, rest_angle + 0.45),
			_hand(1.0, 1.45, rest_angle + 0.45)
		)
		var down: FlightCommand = _settle(
			w, _head(), _hand(-1.0, 1.45, rest_angle - 0.45),
			_hand(1.0, 1.45, rest_angle - 0.45)
		)
		t.greater(up.alpha - down.alpha, 0.2, "pitch still spans a useful range after calibration")


static func _test_calibration_ignores_a_tuck(t: TestCase) -> void:
	t.begin("calibration ignores a tucked pose")
	var w := WingInput.new()
	# Player spawns holding the controllers together in their lap, then spreads.
	_settle(w, _head(), _hand(-1.0, 1.15, 0.8, 0.08), _hand(1.0, 1.15, 0.8, 0.08), 3.0)
	var spread: FlightCommand = _settle(
		w, _head(), _hand(-1.0, 1.45, 0.0), _hand(1.0, 1.45, 0.0), 2.5
	)
	t.greater(spread.span, 0.9, "spreading after a tuck opens the wings fully")
	t.near(spread.alpha, 0.105, 0.06, "neutral was learned from the spread pose, not the tuck")


## Also from the simulator run: reach calibration decayed so slowly that the
## wings read as tucked — i.e. diving — for the first four seconds of play.
static func _test_wings_open_quickly_on_spawn(t: TestCase) -> void:
	t.begin("wings open within a second of spreading your arms")
	var w := WingInput.new()
	var head: Transform3D = _head()
	# A player with a 0.60 m reach, the same as the simulator reported.
	var left: Transform3D = _hand(-1.0, 1.45, 0.0, 0.30)
	var right: Transform3D = _hand(1.0, 1.45, 0.0, 0.30)
	var lowest_span: float = 1.0
	var lowest_at: float = 0.0
	for i in int(4.0 / DT):
		var cmd: FlightCommand = w.update(head, left, right, true, true, DT)
		if cmd.span < lowest_span:
			lowest_span = cmd.span
			lowest_at = float(i) * DT
	# A 0.60 m stance is a genuinely narrow spread, so it need not read as full
	# wings — but it must never read as folded, which is what dropped a player
	# out of the sky on spawn.
	t.greater(
		lowest_span, 0.45,
		"wings never read as folded while held out (worst %.2f at t=%.2fs)" % [
			lowest_span, lowest_at
		]
	)


static func _test_tracking_loss_is_survivable(t: TestCase) -> void:
	t.begin("tracking loss does not corrupt the command")
	var w := WingInput.new()
	_settle(w, _head(), _hand(-1.0, 1.45), _hand(1.0, 1.45))

	var nan_value: float = sqrt(-1.0)
	var broken := Transform3D(Basis.IDENTITY, Vector3(nan_value, nan_value, nan_value))
	var cmd: FlightCommand = w.update(_head(), broken, _hand(1.0, 1.45), true, true, DT)
	t.finite(cmd.bank, "bank stayed finite through a broken pose")
	t.finite(cmd.alpha, "alpha stayed finite through a broken pose")
	t.finite(cmd.span, "span stayed finite through a broken pose")
	t.near(cmd.stroke_speed, 0.0, 0.001, "a broken pose grants no thrust")

	# A zero-scale basis (some runtimes emit this on a dropped controller).
	var degenerate := Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0.5, 1.4, 0.0))
	cmd = w.update(_head(), degenerate, _hand(1.0, 1.45), true, true, DT)
	t.finite(cmd.bank, "bank survived a degenerate basis")

	# Untracked controllers should simply stop contributing thrust.
	cmd = w.update(_head(), _hand(-1.0, 1.0), _hand(1.0, 1.0), false, false, DT)
	t.near(cmd.stroke_speed, 0.0, 0.001, "untracked hands cannot flap")
	t.finite(cmd.alpha, "alpha stayed finite with untracked hands")
