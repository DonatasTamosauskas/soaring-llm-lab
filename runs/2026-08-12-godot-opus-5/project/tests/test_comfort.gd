class_name ComfortTests
extends RefCounted

## What the game does to a person wearing it: what their hands feel, how fast
## the world is allowed to rotate, and what happens when the trackers stop
## reporting.
##
## All three are plain objects for the same reason [FlightModel] is — "a catch
## does not feel like a wingbeat", "a stepped view never rotates smoothly" and
## "a controller put down mid-turn does not spiral the bird into a hill" are
## measurable claims, and measuring them in a headset is slow, unrepeatable and
## depends on which day it is.

const DT: float = 1.0 / 90.0
const FINE: float = 1.0 / 240.0


static func run(t: TestCase) -> void:
	_test_every_cue_is_short_and_ends(t)
	_test_the_cues_are_tellable_apart(t)
	_test_a_one_winged_beat_is_felt_in_one_hand(t)
	_test_haptics_never_become_a_buzz(t)
	_test_the_bigger_event_wins(t)
	_test_states_throb_rather_than_hum(t)
	_test_haptics_survive_hostile_input(t)
	_test_smooth_view_follows_exactly(t)
	_test_eased_view_is_rate_limited_and_catches_up(t)
	_test_stepped_view_never_rotates_smoothly(t)
	_test_the_vignette_closes_with_speed_and_turn(t)
	_test_the_vignette_is_really_there(t)
	_test_the_horizon_roll_is_partial_and_optional(t)
	_test_turning_around_turns_the_world(t)
	_test_looking_around_does_not(t)
	_test_lost_tracking_levels_the_wings(t)
	_test_a_blink_of_lost_tracking_changes_nothing(t)
	_test_a_resting_pose_is_not_a_dive(t)


# --- haptics -----------------------------------------------------------------

## Plays one cue on its own and reports its shape: how long it lasted, how loud
## it got, how many separate bursts it had, and at what frequency.
static func _signature(cue: StringName) -> Dictionary:
	var h := Haptics.new()
	h.fire(cue, 1.0)
	var seconds: float = 0.0
	var peak: float = 0.0
	var bursts: int = 0
	var frequency: float = 0.0
	var sounding: bool = false
	var silence: float = 0.0
	for i in 400:
		h.update(FINE)
		var amplitude: float = maxf(h.amplitude(Haptics.LEFT), h.amplitude(Haptics.RIGHT))
		if amplitude > Haptics.SILENCE:
			if not sounding:
				bursts += 1
			sounding = true
			silence = 0.0
			seconds = float(i + 1) * FINE
			peak = maxf(peak, amplitude)
			frequency = maxf(frequency, h.frequency(Haptics.LEFT))
		else:
			sounding = false
			silence += FINE
			if bursts > 0 and silence > 0.12:
				break
	return {"seconds": seconds, "peak": peak, "bursts": bursts, "frequency": frequency}


static func _test_every_cue_is_short_and_ends(t: TestCase) -> void:
	t.begin("every haptic cue is a moment, not a vibration")
	for cue: StringName in Haptics.CUES:
		var signature: Dictionary = _signature(cue)
		var seconds: float = float(signature["seconds"])
		t.in_range(
			seconds, 0.02, Haptics.MAX_CUE_SECONDS,
			"%s lasts %.2f s" % [cue, seconds]
		)
		t.in_range(float(signature["peak"]), 0.3, 1.0, "%s is loud enough to feel" % cue)
		t.greater(float(signature["frequency"]), 20.0, "%s has a pitch" % cue)
		t.near(
			Haptics.cue_seconds(cue), seconds, 0.05,
			"%s runs for as long as its envelope says" % cue
		)

	# And having ended, it is over: nothing re-triggers itself.
	var h := Haptics.new()
	h.fire(&"caught", 1.0)
	for i in 200:
		h.update(FINE)
	t.ok(h.is_silent(), "the hands are still once the cue has played")
	t.ok(h.playing() == &"", "and nothing is left playing")


static func _test_the_cues_are_tellable_apart(t: TestCase) -> void:
	t.begin("no two cues feel the same")
	var names: Array = Haptics.CUES.keys()
	var signatures: Dictionary = {}
	for cue: StringName in names:
		signatures[cue] = _signature(cue)

	for i in names.size():
		for j in range(i + 1, names.size()):
			var a: Dictionary = signatures[names[i]]
			var b: Dictionary = signatures[names[j]]
			# Two cues are distinguishable if they differ clearly in at least one
			# of the three channels a rumble motor actually has: how long, how
			# many bursts, how high.
			var length: bool = absf(float(a["seconds"]) - float(b["seconds"])) > 0.04
			var bursts: bool = int(a["bursts"]) != int(b["bursts"])
			var pitch: bool = absf(float(a["frequency"]) - float(b["frequency"])) > 25.0
			t.ok(
				length or bursts or pitch,
				"%s and %s are tellable apart" % [names[i], names[j]]
			)


static func _test_a_one_winged_beat_is_felt_in_one_hand(t: TestCase) -> void:
	t.begin("a one-winged beat is felt in that wing")
	for balance: float in [-1.0, 1.0]:
		var h := Haptics.new()
		h.fire(&"wingbeat", 1.0, balance)
		var left: float = 0.0
		var right: float = 0.0
		for i in 60:
			h.update(FINE)
			left = maxf(left, h.amplitude(Haptics.LEFT))
			right = maxf(right, h.amplitude(Haptics.RIGHT))
		var strong: float = right if balance > 0.0 else left
		var weak: float = left if balance > 0.0 else right
		t.greater(strong, 0.5, "the working wing feels it")
		t.less(weak, 0.05, "the other one does not")

	var both := Haptics.new()
	both.fire(&"wingbeat", 1.0, 0.0)
	var peak_left: float = 0.0
	var peak_right: float = 0.0
	for i in 60:
		both.update(FINE)
		peak_left = maxf(peak_left, both.amplitude(Haptics.LEFT))
		peak_right = maxf(peak_right, both.amplitude(Haptics.RIGHT))
	t.near(peak_left, peak_right, 0.001, "an even beat arrives evenly")


## The single most important property in this file. Controllers that vibrate
## continuously stop carrying information within about ten seconds and become
## fatigue for the rest of the session.
static func _test_haptics_never_become_a_buzz(t: TestCase) -> void:
	t.begin("the controllers never turn into a continuous buzz")
	var h := Haptics.new()
	var busy: float = 0.0
	var longest_gap: float = 0.0
	var gap: float = 0.0
	var beats: int = 0
	var seconds: int = int(20.0 / DT)
	for i in seconds:
		# Everything at once, every frame, forever: riding lift while stalled
		# while beating the wings as fast as the sensor will credit.
		h.texture(&"thermal", 1.0)
		h.texture(&"stall", 1.0)
		var before: StringName = h.playing()
		h.fire(&"wingbeat", 1.0)
		if h.playing() == &"wingbeat" and before != &"wingbeat":
			beats += 1
		h.update(DT)
		if maxf(h.amplitude(Haptics.LEFT), h.amplitude(Haptics.RIGHT)) > Haptics.SILENCE:
			busy += DT
			gap = 0.0
		else:
			gap += DT
			longest_gap = maxf(longest_gap, gap)
	var duty: float = busy / 20.0
	t.less(duty, 0.75, "the hands are quiet most of the time (%.0f%% busy)" % (duty * 100.0))
	t.greater(longest_gap, 0.1, "and get a real gap, not a flicker (%.2f s)" % longest_gap)
	t.less(float(beats), 20.0 / Haptics.CUES[&"wingbeat"]["interval"] + 1.0,
		"a beat every frame still only earns a beat every interval (%d in 20 s)" % beats)
	t.in_range(h.load_factor(), 0.0, 1.0, "the load average stays sane")


static func _test_the_bigger_event_wins(t: TestCase) -> void:
	t.begin("a wingbeat cannot talk over being eaten")
	var h := Haptics.new()
	h.fire(&"caught", 1.0)
	h.update(DT)
	h.fire(&"wingbeat", 1.0)
	t.ok(h.playing() == &"caught", "the death rumble keeps the hands")

	# The other way round: what happened to you outranks what you were doing.
	var g := Haptics.new()
	g.fire(&"wingbeat", 1.0)
	g.update(DT)
	g.fire(&"caught", 1.0)
	t.ok(g.playing() == &"caught", "and interrupts a wingbeat when it arrives")


static func _test_states_throb_rather_than_hum(t: TestCase) -> void:
	t.begin("riding lift throbs; it does not hum")
	var h := Haptics.new()
	var silent: float = 0.0
	var peak: float = 0.0
	var seconds: float = 6.0
	for i in int(seconds / DT):
		h.texture(&"thermal", 1.0)
		h.update(DT)
		var amplitude: float = h.amplitude(Haptics.LEFT)
		peak = maxf(peak, amplitude)
		if amplitude <= Haptics.SILENCE:
			silent += DT
	t.in_range(peak, 0.1, 0.25, "lift is felt but never shouts (%.2f)" % peak)
	t.greater(
		silent / seconds, 0.5,
		"and is silent for most of every cycle (%.0f%%)" % (100.0 * silent / seconds)
	)

	# Lift that stops being lift stops being felt.
	for i in 200:
		h.texture(&"thermal", 0.0)
		h.update(DT)
	t.ok(h.is_silent(), "leaving the thermal ends it")


static func _test_haptics_survive_hostile_input(t: TestCase) -> void:
	t.begin("the haptic mixer survives nonsense")
	var h := Haptics.new()
	var nan_value: float = sqrt(-1.0)
	h.fire(&"nonexistent", 1.0)
	t.ok(h.playing() == &"", "an unknown cue plays nothing")
	h.fire(&"wingbeat", nan_value)
	h.fire(&"catch", 1e9, nan_value)
	h.texture(&"thermal", nan_value)
	h.texture(&"nonexistent", 1.0)
	for dt: float in [0.0, -1.0, nan_value, 1e9, DT]:
		h.update(dt)
		t.finite(h.amplitude(Haptics.LEFT), "amplitude stayed finite through dt=%s" % dt)
		t.in_range(h.amplitude(Haptics.RIGHT), 0.0, 1.0, "and inside its range")
		t.finite(h.frequency(Haptics.LEFT), "frequency stayed finite")
	h.reset()
	t.ok(h.is_silent(), "a reset mixer is silent")


# --- the view ----------------------------------------------------------------

## Flies a heading that turns at [param rate] rad/s for [param seconds], then
## holds still, and reports what the view did about it.
static func _turn(
	comfort: ViewComfort, rate: float, seconds: float, hold: float = 0.0
) -> Dictionary:
	var heading: float = comfort.yaw
	var fastest: float = 0.0
	var worst_lag: float = 0.0
	var deltas: Array[float] = []
	var total: float = seconds + hold
	for i in int(total / DT):
		if float(i) * DT < seconds:
			heading = wrapf(heading + rate * DT, -PI, PI)
		var before: float = comfort.yaw
		comfort.update(heading, 0.8, 24.0, DT)
		var step: float = wrapf(comfort.yaw - before, -PI, PI)
		deltas.append(step)
		fastest = maxf(fastest, absf(step) / DT)
		worst_lag = maxf(worst_lag, absf(wrapf(heading - comfort.yaw, -PI, PI)))
	return {
		"heading": heading, "fastest": fastest, "worst_lag": worst_lag, "deltas": deltas,
	}


static func _test_smooth_view_follows_exactly(t: TestCase) -> void:
	t.begin("the default view is the bird's own nose")
	var comfort := ViewComfort.new()
	comfort.mode = ViewComfort.Turning.SMOOTH
	var result: Dictionary = _turn(comfort, 1.4, 4.0)
	t.near(
		comfort.yaw, float(result["heading"]), 0.0001,
		"a smooth view is exactly the heading"
	)
	t.near(float(result["worst_lag"]), 0.0, 0.0001, "with no lag at all")


static func _test_eased_view_is_rate_limited_and_catches_up(t: TestCase) -> void:
	t.begin("the eased view is rate limited and always catches up")
	var comfort := ViewComfort.new()
	comfort.mode = ViewComfort.Turning.EASED
	# 1.7 rad/s is about this bird's hardest turn: a 72-degree bank at trim.
	var result: Dictionary = _turn(comfort, 1.7, 6.0, 2.0)
	t.less(
		float(result["fastest"]), 1.7,
		"the view rotates slower than the bird does (%.2f rad/s)" % result["fastest"]
	)
	t.less(
		float(result["worst_lag"]), 0.35,
		"but never falls far behind it (%.0f deg)" % rad_to_deg(result["worst_lag"])
	)
	t.near(
		comfort.yaw, float(result["heading"]), 0.01,
		"and is level with the bird two seconds after the turn stops"
	)

	# A heading that teleports — a respawn, a restart — is not a turn, and easing
	# through it would spin the player.
	comfort.update(comfort.yaw + PI, 0.0, 20.0, DT)
	t.near(
		absf(wrapf(comfort.yaw - float(result["heading"]) - PI, -PI, PI)), 0.0, 0.01,
		"a teleported heading is taken instantly rather than eased through"
	)


static func _test_stepped_view_never_rotates_smoothly(t: TestCase) -> void:
	t.begin("a stepped view moves in whole steps or not at all")
	var comfort := ViewComfort.new()
	comfort.mode = ViewComfort.Turning.STEPPED
	comfort.vignette_gain = 0.7
	var result: Dictionary = _turn(comfort, 1.2, 8.0, 1.0)
	var steps: int = 0
	var smooth: int = 0
	for step: float in result["deltas"] as Array[float]:
		if is_zero_approx(step):
			continue
		steps += 1
		if absf(absf(step) - ViewComfort.STEP) > 0.001:
			smooth += 1
	t.near(float(smooth), 0.0, 0.5, "every movement is exactly one step")
	t.greater(float(steps), 20.0, "and there were plenty of them (%d)" % steps)
	t.less(
		float(steps) * ViewComfort.STEP, 1.2 * 8.0 + ViewComfort.STEP,
		"which add up to the turn the bird made, not more"
	)
	t.near(
		absf(wrapf(comfort.yaw - float(result["heading"]), -PI, PI)), 0.0,
		ViewComfort.STEP * 0.51, "and end within half a step of the bird"
	)

	# While it is stepping, the periphery is masked — the steps happen inside an
	# aperture that is already narrow.
	t.greater(comfort.vignette, 0.2, "the view is narrowed while stepping")
	for i in 200:
		comfort.update(comfort.yaw, 0.0, 5.0, DT)
	t.less(comfort.vignette, 0.05, "and opens again once the turning stops")


static func _test_the_vignette_closes_with_speed_and_turn(t: TestCase) -> void:
	t.begin("the vignette closes with speed and with turning")
	var comfort := ViewComfort.new()
	comfort.vignette_gain = 1.0
	for i in 30:
		comfort.update(0.0, 0.0, 14.0, DT)
	t.near(comfort.vignette, 0.0, 0.001, "a slow straight glide is not vignetted")

	var slow: float = 0.0
	for i in 30:
		comfort.update(0.0, 0.0, 30.0, DT)
	slow = comfort.vignette
	t.greater(slow, 0.1, "speed alone closes it")

	var banked := ViewComfort.new()
	banked.vignette_gain = 1.0
	for i in 30:
		banked.update(0.0, 1.2, 30.0, DT)
	t.greater(banked.vignette, slow, "and a hard bank closes it further")
	t.less(banked.vignette, ViewComfort.VIGNETTE_CEILING + 0.001, "never past the ceiling")

	var off := ViewComfort.new()
	off.vignette_gain = 0.0
	for i in 200:
		off.update(0.0, 1.2, 55.0, DT)
	t.near(off.vignette, 0.0, 0.0001, "a player who turned it off gets no vignette")


## The vignette spent its whole life drawing its darkening outside the frame:
## the quad is a 1.6 m square held 0.32 m from the eye, the shader measured
## distance in the quad's own UV, and everything past about two thirds of the
## way out was off screen. Nothing was visible at any speed. These are the
## assertions that would have caught it.
static func _test_the_vignette_is_really_there(t: TestCase) -> void:
	t.begin("the vignette is actually on the screen")
	t.greater(
		ViewComfort.aperture(0.0), ViewComfort.FRAME_CORNER,
		"at nought the view is completely unobstructed"
	)
	t.less(
		ViewComfort.aperture(ViewComfort.VIGNETTE_CEILING)
			+ ViewComfort.APERTURE_FEATHER,
		ViewComfort.FRAME_CORNER,
		"at the strongest the game ever goes, the corners are solid black"
	)
	t.less(
		ViewComfort.aperture(1.0) + ViewComfort.APERTURE_FEATHER, 1.0,
		"and at full strength the whole edge of the frame is gone"
	)
	var previous: float = INF
	for i in 21:
		var strength: float = float(i) / 20.0
		var radius: float = ViewComfort.aperture(strength)
		t.less(radius, previous + 0.0001, "the aperture only ever narrows")
		t.finite(radius, "and stays finite")
		previous = radius
	var nan_value: float = sqrt(-1.0)
	t.finite(ViewComfort.aperture(nan_value), "a NaN strength is not a hole in the view")
	t.near(
		ViewComfort.aperture(-5.0), ViewComfort.APERTURE_OPEN, 0.0001,
		"and a nonsense one is clamped"
	)

	# The shader has to measure the frame rather than the mesh, or all of the
	# above is arithmetic about something nobody can see.
	# The exact expression, not just the word: SCREEN_UV also appears in the
	# comment explaining why it is there, and a check that a comment mentions the
	# right thing is not a check.
	t.ok(
		HUD.VIGNETTE_SHADER.contains("length((SCREEN_UV - vec2(0.5)) * 2.0)"),
		"the shader measures distance across the frame"
	)
	t.ok(
		HUD.VIGNETTE_SHADER.contains("uniform float inner"),
		"and takes its aperture from ViewComfort rather than inventing one"
	)


static func _test_the_horizon_roll_is_partial_and_optional(t: TestCase) -> void:
	t.begin("the horizon rolls partially, or not at all")
	var comfort := ViewComfort.new()
	comfort.roll_fraction = 0.35
	for i in 200:
		comfort.update(0.0, 1.0, 20.0, DT)
	t.near(comfort.roll, -0.35, 0.01, "the view shows a third of the bank")

	comfort.roll_fraction = 0.0
	for i in 200:
		comfort.update(0.0, 1.0, 20.0, DT)
	t.near(comfort.roll, 0.0, 0.001, "and none of it when asked for none")


static func _test_turning_around_turns_the_world(t: TestCase) -> void:
	t.begin("a player who turns their chair round gets the world back")
	var comfort := ViewComfort.new()
	var offset: float = 1.6  # 92 degrees: they have swivelled right round
	var elapsed: float = 0.0
	var fastest: float = 0.0
	for i in int(30.0 / DT):
		var before: float = comfort.reorientation
		comfort.update_reorientation(offset, true, DT)
		fastest = maxf(fastest, absf(comfort.reorientation - before) / DT)
		elapsed += DT
		if absf(comfort.reorientation - offset) < 0.02:
			break
	t.near(
		comfort.reorientation, offset, ViewComfort.REORIENT_SETTLED + 0.01,
		"the world comes round to meet them"
	)
	t.less(
		fastest, ViewComfort.REORIENT_RATE * 1.05,
		"slowly enough not to be seen as motion (%.0f deg/s)" % rad_to_deg(fastest)
	)
	t.greater(elapsed, ViewComfort.REORIENT_DWELL, "and only after they stayed there")

	var off := ViewComfort.new()
	off.reorient_enabled = false
	for i in int(30.0 / DT):
		off.update_reorientation(offset, true, DT)
	t.near(off.reorientation, 0.0, 0.0001, "unless they asked it not to")

	var deliberate := ViewComfort.new()
	deliberate.reorient_now(offset)
	t.near(deliberate.reorientation, offset, 0.0001, "a deliberate recentre is instant")

	var hostile := ViewComfort.new()
	var nan_value: float = sqrt(-1.0)
	hostile.update_reorientation(nan_value, true, DT)
	hostile.update_reorientation(0.5, true, nan_value)
	hostile.reorient_now(nan_value)
	t.finite(hostile.reorientation, "and nonsense never moves the world")


static func _test_looking_around_does_not(t: TestCase) -> void:
	t.begin("looking around does not move the world")
	# A glance over the shoulder at a bird you are chasing: right round, but
	# briefly.
	var glance := ViewComfort.new()
	for i in int(ViewComfort.REORIENT_DWELL * 0.8 / DT):
		glance.update_reorientation(1.6, true, DT)
	for i in int(4.0 / DT):
		glance.update_reorientation(0.0, true, DT)
	t.near(glance.reorientation, 0.0, 0.02, "a glance leaves the world where it was")

	# An asymmetric posture — one hand further forward, which is also this
	# game's pitch control — is worth about 12 degrees and must never count.
	var posture := ViewComfort.new()
	for i in int(60.0 / DT):
		posture.update_reorientation(0.25, true, DT)
	t.near(posture.reorientation, 0.0, 0.0001, "nor does holding one hand ahead")

	# Tracking loss is not a body turn either.
	var lost := ViewComfort.new()
	for i in int(60.0 / DT):
		lost.update_reorientation(1.6, false, DT)
	t.near(lost.reorientation, 0.0, 0.0001, "nor does a hand the trackers cannot see")


# --- tracking ----------------------------------------------------------------

static func _hand(side: float, height: float, out: float = 0.70) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(side * out, height, -0.15))


static func _head() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.60, 0.0))


## A controller put down on a table, or a hand that went behind the player's
## back and stayed there. Holding the last command through that is a spiral, and
## spirals end in the ground.
static func _test_lost_tracking_levels_the_wings(t: TestCase) -> void:
	t.begin("abandoned wings level themselves")
	var w := WingInput.new()
	for i in int(2.0 / DT):
		w.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), true, true, DT)
	t.greater(w.command.bank, 0.4, "the bird is in a banked turn to start with")
	t.ok(w.tracking_ok, "and the trackers are reporting")

	for i in int(4.0 / DT):
		w.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), false, false, DT)
	t.ok(not w.tracking_ok, "the sensor knows the hands are gone")
	t.near(w.command.bank, 0.0, 0.05, "the wings came level")
	t.near(w.command.alpha, WingInput.TRIM_ALPHA, 0.02, "and settled at trim")
	t.greater(w.command.span, 0.95, "with the wings open, which is a glide")
	t.near(w.command.stroke_speed, 0.0, 0.001, "and no thrust from a hand nobody is holding")

	# Poses that are present but meaningless — a NaN origin, a zero-scale basis —
	# are the same situation and get the same answer.
	var broken := WingInput.new()
	for i in int(2.0 / DT):
		broken.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), true, true, DT)
	var nan_value: float = sqrt(-1.0)
	var nonsense := Transform3D(Basis.IDENTITY, Vector3(nan_value, 0.0, 0.0))
	for i in int(4.0 / DT):
		broken.update(_head(), nonsense, _hand(1.0, 1.20), true, true, DT)
	t.near(broken.command.bank, 0.0, 0.05, "a broken pose levels the wings too")
	t.finite(broken.command.alpha, "and everything stays finite")

	# And the player gets their bird back the moment the trackers do.
	for i in int(1.5 / DT):
		w.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), true, true, DT)
	t.ok(w.tracking_ok, "tracking coming back is not a special case")
	t.greater(w.command.bank, 0.4, "and the player's own bank comes back with it")


static func _test_a_blink_of_lost_tracking_changes_nothing(t: TestCase) -> void:
	t.begin("a blink of lost tracking is not a hand-back")
	var w := WingInput.new()
	for i in int(2.0 / DT):
		w.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), true, true, DT)
	var bank: float = w.command.bank
	# A hand passing behind the head, a controller briefly occluded: shorter than
	# the grace period, and the bird should not notice.
	for i in int(WingInput.TRACKING_GRACE * 0.7 / DT):
		w.update(_head(), _hand(-1.0, 1.70), _hand(1.0, 1.20), false, false, DT)
	t.ok(w.tracking_ok, "a blink does not count as losing the player")
	t.near(w.command.bank, bank, 0.01, "and the turn they were in is still there")


## Measured from [tests/hands.sh]: holding the controllers still 0.10, 0.25 or
## 0.40 m apart folded the wings to zero and put the bird in a field within
## seconds, every time, because a resting posture was being read as a command.
static func _test_a_resting_pose_is_not_a_dive(t: TestCase) -> void:
	t.begin("holding the controllers still is not a dive")
	for separation: float in [0.10, 0.25, 0.40, 0.50]:
		var w := WingInput.new()
		var lowest: float = INF
		for i in int(8.0 / DT):
			var cmd: FlightCommand = w.update(
				_head(), _hand(-1.0, 1.35, separation * 0.5),
				_hand(1.0, 1.35, separation * 0.5), true, true, DT
			)
			lowest = minf(lowest, cmd.span)
		# A literal rather than [constant WingInput.NOVICE_MIN_SPAN]: a test that
		# reads the number it is checking passes for any value of it, including
		# nought, which is exactly the bug this is here to catch.
		t.greater(
			lowest, 0.75,
			"hands %.2f m apart never folds the wings (worst %.2f)" % [separation, lowest]
		)
		t.ok(not w.has_spread, "and the game knows it has been told nothing yet")

	# Once. That is all it takes, and after it the tuck is a real control again.
	var w := WingInput.new()
	for i in int(1.5 / DT):
		w.update(_head(), _hand(-1.0, 1.45), _hand(1.0, 1.45), true, true, DT)
	t.ok(w.has_spread, "spreading your arms once is enough")
	var cmd: FlightCommand = null
	for i in int(1.5 / DT):
		cmd = w.update(
			_head(), _hand(-1.0, 1.35, 0.09), _hand(1.0, 1.35, 0.09), true, true, DT
		)
	t.less(cmd.span, 0.12, "after which hands together is a full tuck again")
