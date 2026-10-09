class_name WingInput
extends RefCounted

## Turns two controller poses into a [FlightCommand]. Pure: feed it transforms
## in XR-origin space (the origin yaws with the bird, so these are body-relative)
## and a dt, read the command. No scene dependencies, so every gesture can be
## tested with invented poses.
##
## Gesture vocabulary (see docs/FLIGHT.md):
##   spread arms            -> wings open; bring hands together -> tuck (dive)
##   beat both arms down    -> a wingbeat; thrust scales with stroke speed, and
##                             only a stroke that was preceded by a real lift of
##                             the arms counts (no thrust from jitter)
##   roll both wrists up    -> more angle of attack: flare, slow, climb briefly,
##                             and past ~16 degrees of attack the wing stalls
##   roll both wrists down  -> less attack: nose drops, speed builds
##   roll wrists opposite   -> ailerons: the wing whose leading edge drops loses
##                             lift, and the bird rolls toward it
##   drop one hand          -> also banks that way (dihedral instinct)
##   beat one arm harder    -> yaw flick away from that wing
##   squeeze a grip         -> cling to what you touch

const ALPHA_TRIM: float = deg_to_rad(6.0)   # angle of attack with wrists neutral
const ALPHA_GAIN: float = 0.6               # rad of attack per rad of wrist roll
const AILERON_GAIN: float = 1.6             # rad of bank per rad of differential tilt
const DROP_GAIN: float = 2.2                # rad of bank per (reach) of hand height difference
const DEFAULT_REACH: float = 1.25           # m, hand-to-hand at full stretch, until measured
const MIN_REACH: float = 0.8
const CALIBRATED_FRACTION: float = 0.62     # arms must have opened this far once to enable tuck
const SPREAD_LOW: float = 0.30              # fraction of reach that reads as fully tucked
const SPREAD_HIGH: float = 0.82             # fraction of reach that reads as fully open
const STROKE_MIN_AMPLITUDE: float = 0.14    # fraction of reach the arm must have risen before a beat counts
const STROKE_SPEED_MIN: float = 0.55        # m/s downward before a beat starts
const STROKE_SPEED_FULL: float = 2.6        # m/s downward that reads as a full-strength beat
const NEUTRAL_SAMPLE_TIME: float = 0.8      # s spent learning the resting wrist angle
const VELOCITY_SMOOTHING: float = 0.03      # s, hand velocity low-pass

var reach: float = DEFAULT_REACH
var calibrated: bool = false
var neutral_tilt: float = 0.0
var _neutral_accum: float = 0.0
var _neutral_time: float = 0.0
var neutral_locked: bool = false

var _prev_y: Array[float] = [NAN, NAN]
var _vel_y: Array[float] = [0.0, 0.0]
var _stroke_top: Array[float] = [NAN, NAN]
var _armed: Array[bool] = [false, false]

## Last measured values, exposed for HUD / diagnostics / tests.
var tilt_left: float = 0.0
var tilt_right: float = 0.0
var separation: float = 0.0
var flap_left: float = 0.0
var flap_right: float = 0.0
var height_diff: float = 0.0     # (left hand y - right hand y) / reach

var command: FlightCommand = FlightCommand.new()

## Forget the resting wrist angle and reach; the next second re-learns them.
func recentre() -> void:
	neutral_tilt = 0.0
	_neutral_accum = 0.0
	_neutral_time = 0.0
	neutral_locked = false

## Elevation of a controller's aim direction above the horizontal, in radians.
## Rolling the wrist so the controller's nose rises is a positive tilt.
static func tilt_of(t: Transform3D) -> float:
	var fwd: Vector3 = -t.basis.z
	if fwd.length_squared() < 1e-6:
		return 0.0
	return asin(clampf(fwd.normalized().y, -1.0, 1.0))

## `head`, `left`, `right` are in XR origin space. `grip_l/r` are 0..1.
func update(head: Transform3D, left: Transform3D, right: Transform3D, dt: float,
		grip_l: float = 0.0, grip_r: float = 0.0, active_l: bool = true, active_r: bool = true) -> FlightCommand:
	var cmd := FlightCommand.new()
	if dt <= 0.0 or not is_finite(dt) or not (active_l and active_r):
		# No hands: hold a neutral glide rather than diving or spinning.
		cmd.spread = 1.0
		cmd.alpha = ALPHA_TRIM
		command = cmd.clamped()
		return command

	var hl: Vector3 = left.origin - head.origin
	var hr: Vector3 = right.origin - head.origin
	if not (_finite(hl) and _finite(hr)):
		command = cmd.clamped()
		return command

	# --- reach and spread --------------------------------------------------
	separation = (left.origin - right.origin).length()
	if separation > reach:
		reach = minf(separation, 2.2)
	elif separation > CALIBRATED_FRACTION * reach:
		calibrated = true
	if separation > CALIBRATED_FRACTION * DEFAULT_REACH:
		calibrated = true
	if calibrated:
		var lo: float = SPREAD_LOW * reach
		var hi: float = SPREAD_HIGH * reach
		cmd.spread = smoothstep(lo, hi, separation)
	else:
		# Until the player has opened their arms once, holding the controllers
		# together is not a dive command: it is what everybody does before
		# they know anything.
		cmd.spread = 1.0

	# --- wrist tilt: attack and ailerons ------------------------------------
	tilt_left = tilt_of(left)
	tilt_right = tilt_of(right)
	var mean_tilt: float = 0.5 * (tilt_left + tilt_right)
	if not neutral_locked:
		_neutral_accum += mean_tilt * dt
		_neutral_time += dt
		neutral_tilt = _neutral_accum / maxf(_neutral_time, 1e-4)
		if _neutral_time >= NEUTRAL_SAMPLE_TIME:
			neutral_locked = true
	cmd.alpha = ALPHA_TRIM + ALPHA_GAIN * (mean_tilt - neutral_tilt)

	var diff_tilt: float = tilt_left - tilt_right
	height_diff = (hl.y - hr.y) / reach
	cmd.bank = AILERON_GAIN * diff_tilt + DROP_GAIN * height_diff
	# Bank is meaningless with the wings folded; a tucked bird just falls.
	cmd.bank *= lerpf(0.25, 1.0, cmd.spread)

	# --- wingbeats ------------------------------------------------------------
	var ys: Array[float] = [hl.y, hr.y]
	var flaps: Array[float] = [0.0, 0.0]
	for i in 2:
		var y: float = ys[i]
		if is_nan(_prev_y[i]):
			_prev_y[i] = y
			_stroke_top[i] = y
		var raw_v: float = (y - _prev_y[i]) / dt
		_prev_y[i] = y
		var k: float = 1.0 - exp(-dt / VELOCITY_SMOOTHING)
		_vel_y[i] = lerpf(_vel_y[i], raw_v, k)
		var v: float = _vel_y[i]
		if v > 0.15:
			# Arm rising: remember the top of the stroke and arm the beat.
			_stroke_top[i] = maxf(_stroke_top[i], y)
			if _stroke_top[i] - y < 0.02:
				_armed[i] = true
		var amplitude: float = _stroke_top[i] - y
		if v < -STROKE_SPEED_MIN and _armed[i] and amplitude > STROKE_MIN_AMPLITUDE * reach:
			flaps[i] = clampf((-v - STROKE_SPEED_MIN) / (STROKE_SPEED_FULL - STROKE_SPEED_MIN), 0.0, 1.0)
		elif v >= -STROKE_SPEED_MIN * 0.5 and _armed[i] and amplitude > STROKE_MIN_AMPLITUDE * reach:
			# The downstroke has ended; the next one needs a fresh lift of the arm.
			_armed[i] = false
			_stroke_top[i] = y
	flap_left = flaps[0]
	flap_right = flaps[1]
	cmd.flap = 0.5 * (flap_left + flap_right)
	cmd.flap_asym = flap_right - flap_left

	cmd.grip = grip_l > 0.5 or grip_r > 0.5
	command = cmd.clamped()
	return command

static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
