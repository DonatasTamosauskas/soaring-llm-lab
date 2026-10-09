extends RefCounted

## [WingInput]: invented controller poses in, commands out.

const DT: float = 1.0 / 90.0
const HEAD := Transform3D(Basis.IDENTITY, Vector3(0, 1.7, 0))

func _hand(x: float, y: float = 1.4, z: float = -0.05, tilt: float = 0.0) -> Transform3D:
	# Aim forward is -Z; rolling the wrist "nose up" pitches the basis about X.
	return Transform3D(Basis(Vector3.RIGHT, tilt), Vector3(x, y, z))

func _settle(w: WingInput, l: Transform3D, r: Transform3D, seconds: float = 1.2) -> FlightCommand:
	var c: FlightCommand
	for i in int(seconds / DT):
		c = w.update(HEAD, l, r, DT)
	return c

func run(t: TestCase) -> void:
	_test_neutral(t)
	_test_attack(t)
	_test_ailerons(t)
	_test_drop_hand(t)
	_test_tuck_needs_calibration(t)
	_test_wingbeat(t)
	_test_jitter_is_not_a_beat(t)
	_test_one_wing_beat(t)
	_test_no_hands(t)
	_test_neutral_calibration(t)
	_test_grip(t)
	_test_hostile(t)

func _test_neutral(t: TestCase) -> void:
	var w := WingInput.new()
	var c := _settle(w, _hand(-0.6), _hand(0.6))
	t.near(c.spread, 1.0, 0.05, "arms wide = wings open")
	t.near(c.alpha, WingInput.ALPHA_TRIM, 0.01, "neutral wrists = trim attack")
	t.near(c.bank, 0.0, 0.01, "level hands = no bank")
	t.near(c.flap, 0.0, 1e-6, "still hands = no beat")

func _test_attack(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6), _hand(0.6))
	var up := _settle(w, _hand(-0.6, 1.4, -0.05, deg_to_rad(25)), _hand(0.6, 1.4, -0.05, deg_to_rad(25)), 0.3)
	t.gt(up.alpha, WingInput.ALPHA_TRIM + deg_to_rad(8), "wrists rolled up raise the angle of attack")
	t.gt(up.alpha, FlightModel.ALPHA_STALL, "rolling 25 degrees up is enough to stall")
	var down := _settle(w, _hand(-0.6, 1.4, -0.05, deg_to_rad(-25)), _hand(0.6, 1.4, -0.05, deg_to_rad(-25)), 0.3)
	t.lt(down.alpha, WingInput.ALPHA_TRIM - deg_to_rad(8), "wrists rolled down lower it")
	t.near(up.bank, 0.0, 0.02, "symmetric tilt does not bank")

func _test_ailerons(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6), _hand(0.6))
	var c := _settle(w, _hand(-0.6, 1.4, -0.05, deg_to_rad(15)), _hand(0.6, 1.4, -0.05, deg_to_rad(-15)), 0.3)
	t.gt(c.bank, deg_to_rad(20), "left up / right down rolls right (bank %.2f)" % c.bank)
	t.near(c.alpha, WingInput.ALPHA_TRIM, 0.02, "pure aileron does not change attack")
	var c2 := _settle(w, _hand(-0.6, 1.4, -0.05, deg_to_rad(-15)), _hand(0.6, 1.4, -0.05, deg_to_rad(15)), 0.3)
	t.lt(c2.bank, -deg_to_rad(20), "and the opposite rolls left")

func _test_drop_hand(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6), _hand(0.6))
	var c := _settle(w, _hand(-0.6, 1.5), _hand(0.6, 1.15), 0.3)
	t.gt(c.bank, deg_to_rad(15), "dropping the right hand banks right")

func _test_tuck_needs_calibration(t: TestCase) -> void:
	var w := WingInput.new()
	var c := _settle(w, _hand(-0.15), _hand(0.15), 0.5)
	t.near(c.spread, 1.0, 1e-6, "hands together before opening the arms is NOT a tuck")
	_settle(w, _hand(-0.6), _hand(0.6), 0.5)
	t.ok(w.calibrated, "opening the arms calibrates")
	c = _settle(w, _hand(-0.15), _hand(0.15), 0.5)
	t.lt(c.spread, 0.05, "hands together after calibration tucks the wings")
	c = _settle(w, _hand(-0.4), _hand(0.4), 0.5)
	t.ok(c.spread > 0.2 and c.spread < 0.9, "half open is partly tucked (%.2f)" % c.spread)

func _test_wingbeat(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6, 1.3), _hand(0.6, 1.3))
	# Raise the arms over 0.4 s, then beat down over 0.25 s.
	var peak: float = 0.0
	var thrust_during_rise: float = 0.0
	for i in int(0.4 / DT):
		var y: float = 1.3 + 0.4 * (i * DT / 0.4)
		var c := w.update(HEAD, _hand(-0.6, y), _hand(0.6, y), DT)
		thrust_during_rise = maxf(thrust_during_rise, c.flap)
	for i in int(0.25 / DT):
		var y: float = 1.7 - 0.6 * (i * DT / 0.25)
		var c := w.update(HEAD, _hand(-0.6, y), _hand(0.6, y), DT)
		peak = maxf(peak, c.flap)
	t.near(thrust_during_rise, 0.0, 1e-6, "raising the arms is not a beat")
	t.gt(peak, 0.5, "a brisk downstroke is a strong beat (%.2f)" % peak)
	var after := _settle(w, _hand(-0.6, 1.1), _hand(0.6, 1.1), 0.3)
	t.near(after.flap, 0.0, 1e-6, "holding the arms down after the beat gives nothing")
	# A second beat without lifting the arms first gives nothing either.
	var second: float = 0.0
	for i in int(0.2 / DT):
		var y: float = 1.1 - 0.3 * (i * DT / 0.2)
		second = maxf(second, w.update(HEAD, _hand(-0.6, y), _hand(0.6, y), DT).flap)
	t.near(second, 0.0, 1e-6, "you must lift your arms before the next beat counts")

func _test_jitter_is_not_a_beat(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6), _hand(0.6))
	var peak: float = 0.0
	for i in 400:
		var y: float = 1.4 + 0.012 * sin(i * 1.7)
		peak = maxf(peak, w.update(HEAD, _hand(-0.6, y), _hand(0.6, y), DT).flap)
	t.near(peak, 0.0, 1e-6, "shaking the controllers earns nothing")

func _test_one_wing_beat(t: TestCase) -> void:
	var w := WingInput.new()
	_settle(w, _hand(-0.6, 1.3), _hand(0.6, 1.3))
	for i in int(0.4 / DT):
		var y: float = 1.3 + 0.4 * (i * DT / 0.4)
		w.update(HEAD, _hand(-0.6, 1.3), _hand(0.6, y), DT)
	var asym: float = 0.0
	var flap: float = 0.0
	for i in int(0.25 / DT):
		var y: float = 1.7 - 0.6 * (i * DT / 0.25)
		var c := w.update(HEAD, _hand(-0.6, 1.3), _hand(0.6, y), DT)
		if c.flap > flap:
			flap = c.flap
			asym = c.flap_asym
	t.gt(flap, 0.25, "one wing beating still gives some thrust")
	t.gt(asym, 0.5, "and reads as a right-wing beat (asym %.2f)" % asym)

func _test_no_hands(t: TestCase) -> void:
	var w := WingInput.new()
	var c := w.update(HEAD, _hand(-0.6), _hand(0.6), DT, 0.0, 0.0, false, false)
	t.near(c.spread, 1.0, 1e-6, "no controllers = wings open")
	t.near(c.alpha, WingInput.ALPHA_TRIM, 1e-6, "no controllers = trim glide")
	t.near(c.bank, 0.0, 1e-6, "no controllers = no bank")

func _test_neutral_calibration(t: TestCase) -> void:
	var w := WingInput.new()
	# This player rests their wrists 15 degrees nose-up. Level for them is 15.
	var c := _settle(w, _hand(-0.6, 1.4, -0.05, deg_to_rad(15)), _hand(0.6, 1.4, -0.05, deg_to_rad(15)), 1.5)
	t.near(c.alpha, WingInput.ALPHA_TRIM, 0.02, "resting wrist angle is learned as neutral")
	t.ok(w.neutral_locked, "neutral locks after the sample window")
	w.recentre()
	t.ok(not w.neutral_locked, "recentre re-opens the sample window")

func _test_grip(t: TestCase) -> void:
	var w := WingInput.new()
	var c := w.update(HEAD, _hand(-0.6), _hand(0.6), DT, 0.9, 0.0)
	t.ok(c.grip, "left grip squeezed = cling")
	c = w.update(HEAD, _hand(-0.6), _hand(0.6), DT, 0.1, 0.1)
	t.ok(not c.grip, "light touch is not a grip")

func _test_hostile(t: TestCase) -> void:
	var w := WingInput.new()
	var bad := Transform3D(Basis.IDENTITY, Vector3(NAN, 1, 1))
	var c := w.update(HEAD, bad, _hand(0.6), DT)
	t.ok(is_finite(c.alpha) and is_finite(c.bank) and is_finite(c.spread), "NaN pose yields a finite command")
	c = w.update(HEAD, _hand(-0.6), _hand(0.6), 0.0)
	t.ok(is_finite(c.alpha), "zero dt is safe")
