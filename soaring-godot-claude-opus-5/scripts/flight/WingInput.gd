class_name WingInput
extends RefCounted

## Turns two tracked controllers into a [FlightCommand].
##
## Takes raw [Transform3D]s rather than reaching into the scene tree, so the
## whole mapping can be driven by synthetic poses in a headless test — the same
## trick that makes [FlightModel] testable.
##
## Design notes on the three measurements that matter:
##
## [b]Span[/b] is the distance between the hands, auto-calibrated against the
## player's own reach. Nobody should have to tell the game how long their arms
## are.
##
## [b]Bank[/b] is the roll of the line between the hands. Drop your right hand,
## bank right, turn right. It is the one control that needs no explanation.
##
## [b]Angle of attack[/b] is read primarily from the wrists — how far you have
## tipped your hands into the oncoming air — and secondarily from how far
## forward or back you are holding them. The redundancy matters: wrist rotation
## is precise but tiring, arm position is coarse but effortless, and having both
## lets a player use whichever their body prefers.

## Wingspan below which the wings count as fully tucked, in metres. Roughly
## "hands held together in front of you".
const MIN_SPAN: float = 0.30
## Hand separation that already counts as fully spread wings. A modest, holdable
## spread rather than a full arm-span: the wings should open the moment you open
## your arms, and staying at full extension for a whole session is exhausting.
const FULL_SPAN_AT: float = 0.85
## If a player demonstrates a wider reach, use this much of it instead.
const REACH_USED_FRACTION: float = 0.80

## Separation that counts as "this player has understood the gesture".
const FIRST_SPREAD_THRESHOLD: float = 0.60
## Wing extension held until then: enough to glide, not enough to fly well.
const GRACE_SPAN: float = 0.55
## Starting assumption about reach, refined at runtime. Deliberately equal to
## [constant FULL_SPAN_AT] rather than a real arm-span: assuming a wide reach
## nobody has demonstrated makes every normal posture read as narrow, which is
## the folded-wing dive all over again. Reach is earned upward, never assumed.
const DEFAULT_MAX_SPAN: float = FULL_SPAN_AT
## Wing axis shorter than this is too degenerate to derive a heading from.
const DEGENERATE_SPAN: float = 0.22

## Converts arm tilt to commanded bank. Above 1 so that a comfortable arm
## movement reaches a hard turn without dislocating a shoulder: a 20 cm tilt is
## already a gentle turn, and a full-reach tilt pegs the bank limit.
const BANK_GAIN: float = 2.2
const MAX_BANK: float = 1.25  # ~72 degrees

## Split between wrist rotation and arm fore/aft position when reading AoA.
## They sum to more than 1 on purpose — either gesture alone has enough
## authority to fly with, so players can favour whichever suits them.
const WRIST_AOA_WEIGHT: float = 0.80
const REACH_AOA_WEIGHT: float = 0.35
## Fore/aft hand travel, in metres, that corresponds to full pitch authority.
const REACH_RANGE: float = 0.45
## Initial guess at where the hands sit, ahead of the head, in a relaxed
## wings-out pose. Refined per player during calibration. Reach is measured as a
## deviation from here so that "arms out" reads as neutral rather than as a
## permanent dive command.
const REACH_CENTRE: float = 0.15
## Sanity bounds on the learned rest position.
const MIN_REACH_ZERO: float = -0.25
const MAX_REACH_ZERO: float = 0.70

## A downstroke only counts once the hand has been raised at least this far
## since the previous one. This is what makes flapping an athletic act: you
## cannot vibrate your wrists and fly, you have to lift your arms.
const UPSTROKE_RESET_FRACTION: float = 0.7
## A wingbeat has a finite length. Past this much travel the stroke is spent,
## so leaning on the controllers and shoving them steadily downward earns
## nothing after the first stroke's worth of motion.
const MAX_STROKE_TRAVEL_FACTOR: float = 2.4

## Calibration only shrinks toward the player's real reach while the wings are
## actually out; a tuck must never be mistaken for short arms.
const CALIBRATION_DECAY: float = 0.25  # metres per second
const CALIBRATION_MIN_OBSERVED: float = 0.55

## Seconds of steady wings-out pose used to learn where this player's neutral
## is. Without this the game assumes "controller upright = wings level", which
## is a guess — and the wrong guess means the player either spawns permanently
## stalled or permanently diving, with no way to tell why.
const CALIBRATION_WINDOW: float = 1.2
## A pose only counts as wings-out (and therefore as calibratable) above this.
const CALIBRATION_MIN_SPAN: float = 0.40
## Sanity bound on the learned wrist offset, so a bizarre starting pose cannot
## invert the pitch control.
const MAX_WRIST_ZERO: float = 0.9

var command := FlightCommand.new()

# --- Tunables. Owned here rather than read from the Tuning autoload so that
# --- this class stays a plain object a headless test can drive directly.
var min_flap_travel: float = 0.30
var min_flap_speed: float = 0.9
var tilt_sensitivity: float = 1.0
var smoothing_tau: float = 0.07

# Auto-calibration.
var max_span: float = DEFAULT_MAX_SPAN
## The wrist angle this player's relaxed, level wings sit at. Everything about
## angle of attack is measured relative to this rather than to an assumed
## upright controller.
var wrist_zero: float = 0.0
## How far ahead of the head this player rests their hands. Learned alongside
## [member wrist_zero], for the same reason: both halves of the pitch control
## have to be measured from where the player actually is.
var reach_zero: float = REACH_CENTRE
var _calibrating: bool = true
var _calibration_elapsed: float = 0.0

# Smoothed outputs.
var _bank: float = 0.0
var _alpha: float = 0.0
var _span: float = 1.0

# Per-hand flap tracking.
var _hands: Array[HandTracker] = [HandTracker.new(), HandTracker.new()]

# Fallback body heading when the wing axis is unusable (hands tucked together).
var _fallback_forward: Vector3 = Vector3.FORWARD
var _last_head_origin: Vector3 = Vector3.ZERO

## Set true while the player is flapping hard enough to be worth a haptic pulse.
var flap_pulse: bool = false
## 0..1 how hard the last stroke was, for audio and haptics.
var flap_strength: float = 0.0
## Body forward derived from the wing line — used to orient the bird's mesh.
var body_forward: Vector3 = Vector3.FORWARD

## True until the player has spread their arms at least once.
##
## A player who puts the headset on holding the controllers together is, by the
## rules of this game, commanding a full tuck — and a full tuck from the spawn
## altitude is a power dive into the ground inside four seconds, with no way to
## work out why. Until they have made the gesture once the wings stay partly
## open, so the bird glides while the HUD explains itself. The moment they do
## spread, the training wheels come off for good.
var awaiting_first_spread: bool = true


class HandTracker extends RefCounted:
	var previous_position: Vector3 = Vector3.ZERO
	var has_previous: bool = false
	var stroking: bool = false
	var stroke_travel: float = 0.0
	## Lowest height the hand has dropped to since the last credited wingbeat.
	## Arming is measured as height *above this point*, not as a sum of upward
	## motion — otherwise a rapid shake accumulates its way to a free flap, four
	## tiny lifts at a time.
	var lowest: float = 0.0
	var stroke_speed: float = 0.0
	## Starts false: the very first thing a player must do to fly is lift their
	## arms. Nobody gets a free wingbeat for holding the controllers still.
	var armed: bool = false

	func rise() -> float:
		return previous_position.y - lowest

	func reset() -> void:
		has_previous = false
		stroking = false
		stroke_travel = 0.0
		lowest = 0.0
		stroke_speed = 0.0
		armed = false


func reset() -> void:
	command.reset()
	_bank = 0.0
	_alpha = 0.0
	_span = 1.0
	wrist_zero = 0.0
	reach_zero = REACH_CENTRE
	max_span = DEFAULT_MAX_SPAN
	awaiting_first_spread = true
	recentre()
	for h: HandTracker in _hands:
		h.reset()


## [param head], [param left] and [param right] are poses in the same space
## (the XR origin's local space). [param dt] is the frame time.
func update(
	head: Transform3D,
	left: Transform3D,
	right: Transform3D,
	left_tracked: bool,
	right_tracked: bool,
	dt: float
) -> FlightCommand:
	if not is_finite(dt) or dt <= 0.0:
		return command
	if not _pose_is_sane(head) or not _pose_is_sane(left) or not _pose_is_sane(right):
		# Tracking dropped. Hold the last good command and let the bird coast
		# rather than spasm, but stop crediting flaps.
		command.stroke_speed = 0.0
		command.asymmetry = 0.0
		return command

	var lp: Vector3 = left.origin
	var rp: Vector3 = right.origin
	var wing: Vector3 = rp - lp
	var span_metres: float = wing.length()

	_last_head_origin = head.origin
	_update_body_forward(wing, span_metres, head)
	# Reach tracking always runs. It used to be gated behind neutral calibration
	# finishing, and neutral calibration only finishes if it sees a wings-out
	# pose — so a player who never spread their arms wide was pinned to the
	# default reach forever, which read their hands as permanently folded and
	# flew them straight into the ground.
	_calibrate(span_metres, left_tracked and right_tracked, dt)
	if _calibrating:
		_learn_neutral(left, right, span_metres, left_tracked and right_tracked, dt)
	var target_span: float = _measure_span(span_metres)
	if span_metres >= FIRST_SPREAD_THRESHOLD:
		awaiting_first_spread = false
	if awaiting_first_spread:
		target_span = maxf(target_span, GRACE_SPAN)
	var target_bank: float = _measure_bank(wing, span_metres)
	var target_alpha: float = _measure_alpha(left, right, head)

	var smoothing: float = _smoothing_weight(dt)
	_span = lerpf(_span, target_span, smoothing)
	_bank = lerpf(_bank, target_bank, smoothing)
	_alpha = lerpf(_alpha, target_alpha, smoothing)

	_update_flap(head, lp, rp, left_tracked, right_tracked, dt)

	command.span = _span
	command.bank = _bank
	command.alpha = _alpha
	command.sanitize()
	return command


func _smoothing_weight(dt: float) -> float:
	return clampf(1.0 - exp(-dt / maxf(smoothing_tau, 0.001)), 0.0, 1.0)


## Restarts calibration. Bind this to a button if players ever need to re-trim
## mid-session — after handing the headset to someone else, say.
func recentre() -> void:
	_calibrating = true
	_calibration_elapsed = 0.0


## Learns, from the first steady wings-out pose it sees, both how far this
## player can reach and what angle they naturally hold their wrists at.
##
## The wrist part matters more than it looks. Angle of attack is only a couple
## of degrees wide between "gliding" and "stalled", and different people — and
## different controllers — rest at wildly different angles. Assuming a neutral
## instead of measuring it is the difference between a bird that flies and one
## that mushes into the ground for reasons the player cannot see.
func _learn_neutral(
	left: Transform3D, right: Transform3D, span_metres: float, both_tracked: bool, dt: float
) -> void:
	# The window always closes, whether or not a usable pose ever showed up. If
	# it never does we simply keep the defaults, which fly fine — far better than
	# waiting forever for a gesture the player does not know to make.
	_calibration_elapsed += dt
	if _calibration_elapsed >= CALIBRATION_WINDOW:
		_calibrating = false
	if not both_tracked or span_metres < CALIBRATION_MIN_SPAN:
		return  # a tuck tells us nothing about where neutral is

	var blend: float = clampf(dt / 0.3, 0.0, 1.0)

	var raw_wrist: float = 0.5 * (
		_wrist_pitch(left, _fallback_forward) + _wrist_pitch(right, _fallback_forward)
	)
	wrist_zero = clampf(
		lerpf(wrist_zero, raw_wrist, blend), -MAX_WRIST_ZERO, MAX_WRIST_ZERO
	)

	var mid: Vector3 = (left.origin + right.origin) * 0.5
	var raw_reach: float = (mid - _last_head_origin).dot(_fallback_forward)
	reach_zero = clampf(
		lerpf(reach_zero, raw_reach, blend), MIN_REACH_ZERO, MAX_REACH_ZERO
	)


## Tracks the widest the player actually flies with. Grows immediately to any
## span they demonstrate, then creeps back down so a one-off tracking glitch
## does not permanently desensitise the tuck control.
##
## The decay is deliberately gated on the wings being out. Without that gate a
## player who held a long tuck would have their calibration collapse, and would
## then find their tucked hands reading as fully spread wings — a bug that
## would feel like the game randomly refusing to let them dive.
func _calibrate(span_metres: float, both_tracked: bool, dt: float) -> void:
	if not both_tracked or not is_finite(span_metres):
		return
	if span_metres > max_span and span_metres < 2.4:
		max_span = span_metres
	elif span_metres > CALIBRATION_MIN_OBSERVED:
		max_span = maxf(span_metres, max_span - CALIBRATION_DECAY * dt)


## Hand separation to wing extension.
##
## The upper end is whichever is *smaller*: a comfortable modest spread, or the
## player's demonstrated reach. That asymmetry is the whole point. Anchoring
## full span to a full arm-span means anyone holding the controllers in a normal,
## closed posture reads as fully folded — which is a power dive, and which is
## exactly how a first play session ends face-down in a field four seconds after
## spawning. Anchoring it to a reachable spread means the wings open as soon as
## you open your arms at all, and tucking still requires bringing your hands
## genuinely together.
func _measure_span(span_metres: float) -> float:
	var full: float = minf(maxf(max_span * REACH_USED_FRACTION, FULL_SPAN_AT), max_span)
	var range_span: float = maxf(full - MIN_SPAN, 0.1)
	return clampf((span_metres - MIN_SPAN) / range_span, 0.0, 1.0)


func _measure_bank(wing: Vector3, span_metres: float) -> float:
	if span_metres < DEGENERATE_SPAN:
		# Hands tucked to the chest: no wing line to read a roll from, so hold
		# the last bank rather than snapping to level mid-dive.
		return _bank
	var tilt: float = clampf(wing.y / span_metres, -1.0, 1.0)
	# Right hand low means the right wing is down, which banks and turns right.
	return clampf(-asin(tilt) * BANK_GAIN * tilt_sensitivity, -MAX_BANK, MAX_BANK)


func _update_body_forward(wing: Vector3, span_metres: float, head: Transform3D) -> void:
	if span_metres >= DEGENERATE_SPAN:
		var wing_hat: Vector3 = wing / span_metres
		var fwd: Vector3 = Vector3.UP.cross(wing_hat)
		if fwd.length_squared() > 1e-4:
			_fallback_forward = fwd.normalized()
	else:
		var head_fwd: Vector3 = -head.basis.z
		head_fwd.y = 0.0
		if head_fwd.length_squared() > 1e-4:
			_fallback_forward = head_fwd.normalized()
	body_forward = _fallback_forward


## Angle of attack, in radians, relative to the body's forward axis.
func _measure_alpha(left: Transform3D, right: Transform3D, head: Transform3D) -> float:
	var fwd: Vector3 = _fallback_forward
	# Measured against this player's learned neutral, not against an assumption.
	var wrist: float = 0.5 * (_wrist_pitch(left, fwd) + _wrist_pitch(right, fwd)) - wrist_zero

	# How far forward or back the hands are held, relative to the head. Arms
	# swept back rears the bird up; arms pushed out ahead drops the nose.
	var mid: Vector3 = (left.origin + right.origin) * 0.5
	var offset: Vector3 = mid - head.origin
	var reach: float = clampf((offset.dot(fwd) - reach_zero) / REACH_RANGE, -1.0, 1.0)

	var model_range: float = 0.42  # matches FlightModel.alpha_range
	var trim: float = 0.105  # matches FlightModel.alpha_trim
	var blended: float = WRIST_AOA_WEIGHT * (wrist / (PI * 0.4)) - REACH_AOA_WEIGHT * reach
	return trim + clampf(blended * tilt_sensitivity, -1.0, 1.0) * model_range


## Rotation of one hand about its own wing axis: how far the back of the hand
## has tipped away from straight up, measured in the vertical plane.
func _wrist_pitch(hand: Transform3D, fwd: Vector3) -> float:
	var normal: Vector3 = hand.basis.y
	var along_forward: float = normal.dot(fwd)
	var along_up: float = normal.dot(Vector3.UP)
	if absf(along_forward) < 1e-5 and absf(along_up) < 1e-5:
		return 0.0
	return atan2(-along_forward, along_up)


func _update_flap(
	head: Transform3D,
	left_position: Vector3,
	right_position: Vector3,
	left_tracked: bool,
	right_tracked: bool,
	dt: float
) -> void:
	flap_pulse = false
	var positions: Array[Vector3] = [left_position, right_position]
	var tracked: Array[bool] = [left_tracked, right_tracked]
	var speeds: Array[float] = [0.0, 0.0]

	for i in 2:
		var hand: HandTracker = _hands[i]
		if not tracked[i]:
			hand.reset()
			continue
		# Measure hand motion relative to the head so that ducking, leaning or
		# a room-scale step is not mistaken for a wingbeat.
		var relative: Vector3 = positions[i] - head.origin
		if not hand.has_previous:
			hand.previous_position = relative
			hand.lowest = relative.y
			hand.has_previous = true
			continue
		var delta_y: float = relative.y - hand.previous_position.y
		hand.previous_position = relative
		hand.lowest = minf(hand.lowest, relative.y)
		var vertical_speed: float = -delta_y / dt  # positive = moving down

		# Moving up: the stroke is over, and this is how the next one is earned.
		if delta_y > 0.0:
			hand.stroking = false
			hand.stroke_travel = 0.0
			if hand.rise() >= min_flap_travel * UPSTROKE_RESET_FRACTION:
				hand.armed = true
			hand.stroke_speed = 0.0
			continue

		# Drifting down too gently to be a wingbeat.
		if vertical_speed < min_flap_speed:
			hand.stroke_speed = 0.0
			continue

		if not hand.stroking:
			if not hand.armed:
				# They never raised their arms since the last beat. A wrist
				# shake or a slow downward shove earns exactly nothing.
				hand.stroke_speed = 0.0
				continue
			# Commit to a stroke. Disarming here — at the start rather than
			# after some travel threshold — is what makes short, fast jitters
			# worthless: one beat per arm-raise, no matter how it is performed.
			hand.stroking = true
			hand.armed = false
			hand.lowest = relative.y  # the next beat must be earned from here
			hand.stroke_travel = 0.0

		hand.stroke_travel += -delta_y
		if hand.stroke_travel > min_flap_travel * MAX_STROKE_TRAVEL_FACTOR:
			# A wingbeat is a finite motion; this one is spent.
			hand.stroking = false
			hand.stroke_speed = 0.0
			continue

		hand.stroke_speed = vertical_speed
		speeds[i] = vertical_speed

	var left_speed: float = speeds[0]
	var right_speed: float = speeds[1]
	var combined: float = 0.5 * (left_speed + right_speed)
	command.stroke_speed = combined

	# One wing working harder than the other yaws the bird — the flick that
	# gets you around a branch when there is no room to bank. Driving the right
	# wing harder pushes that side forward, swinging the nose left.
	var total: float = left_speed + right_speed
	command.asymmetry = 0.0
	if total > 0.05:
		command.asymmetry = clampf((right_speed - left_speed) / total, -1.0, 1.0)

	if combined > 0.01:
		flap_strength = clampf(combined / 3.5, 0.0, 1.0)
		flap_pulse = true
	else:
		flap_strength = maxf(0.0, flap_strength - dt * 3.0)


static func _pose_is_sane(t: Transform3D) -> bool:
	if not t.origin.is_finite():
		return false
	var b: Basis = t.basis
	return b.x.is_finite() and b.y.is_finite() and b.z.is_finite() \
		and b.determinant() > 1e-6 and t.origin.length() < 100.0
