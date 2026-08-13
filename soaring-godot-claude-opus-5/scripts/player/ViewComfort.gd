class_name ViewComfort
extends RefCounted

## Everything between the bird's motion and the player's inner ear: how fast the
## view is allowed to yaw, how far the horizon tips, how hard the vignette
## closes, and which way the world faces when the player has physically turned
## around in their room.
##
## Scene-free, so all of it is arithmetic a test can pin down. "The view never
## rotates faster than the player asked it to" and "a stepped view only ever
## moves in whole steps" are properties, not intentions.
##
## The one thing to understand before changing anything here: rotation is what
## makes people ill, not speed. A bird flying flat out in a straight line is
## comfortable for almost everybody; the same bird in a 70-degree turn is not,
## because the eyes report a spin the inner ear cannot feel. Every knob below is
## some way of spending visual fidelity to buy that spin down.

## How the view follows the bird's heading.
enum Turning {
	## 1:1. The bird's nose is where you are looking, always. Most players want
	## this and it is the default.
	SMOOTH,
	## Rate-limited. Violent turns are smeared out over the following moment,
	## which costs a small, self-correcting misalignment between where the bird
	## is pointing and where you are facing, and buys the peak rotation rate.
	EASED,
	## Discrete. The view only ever sits at whole multiples of [constant STEP],
	## so there is no smooth rotation to be sick about at all — the classic
	## comfort trade, and for some people the difference between playing and
	## taking the headset off.
	STEPPED,
}

## Baseline ceiling on view yaw rate in EASED, rad/s. About 50 deg/s, which is
## roughly the fastest a person turns their own head without thinking about it.
const EASED_RATE: float = 0.9
## Extra rad/s of catch-up per radian of lag. This is what bounds the lag: at a
## steady turn rate H the view settles at (H − EASED_RATE) / EASED_CATCHUP
## radians behind, which for this bird's hardest turn is about 13 degrees.
const EASED_CATCHUP: float = 4.0
## Beyond this the view is not lagging, it is somewhere else — a respawn, a
## restart, a teleport. Snap instead, and let [method snap_to] say so.
const EASED_GIVE_UP: float = 1.6

## Size of one step in STEPPED. Smaller than a walking game's snap turn (which
## is usually 30 to 45 degrees) because in flight the heading changes constantly
## rather than on demand, and an 18-degree misalignment between where the bird
## points and where the player faces is about as much as still reads as flying
## forwards.
const STEP: float = 0.314159  # 18 degrees

## While a stepped view is turning, the periphery is masked continuously rather
## than blinked per step: at four steps a second a blink is a strobe, and a
## strobe is worse than the thing it was hiding.
const STEP_MASK: float = 0.55
const STEP_MASK_RATE: float = 0.12  # rad/s of heading change that fully masks

## Vignette shape. Speed opens it gradually from a cruise; bank and yaw rate
## close it hard, because those are the moments the eyes and the inner ear
## disagree most.
const VIGNETTE_SPEED_FLOOR: float = 16.0
const VIGNETTE_SPEED_RANGE: float = 34.0
const VIGNETTE_BANK_WEIGHT: float = 0.45
const VIGNETTE_YAW_FLOOR: float = 0.5   # rad/s below which turning is free
const VIGNETTE_YAW_RANGE: float = 1.5
const VIGNETTE_YAW_WEIGHT: float = 0.35
const VIGNETTE_CEILING: float = 0.85

## How quickly the shown roll chases the commanded roll.
const ROLL_RATE: float = 5.0

## The vignette's shape, in half-frame units: 0 is the centre of the view, 1.0
## the middle of an edge, 1.41 a corner. [method aperture] turns a strength into
## the radius inside which the view is untouched, and the shader in [HUD] fades
## to black over [constant APERTURE_FEATHER] beyond it.
##
## The numbers live here rather than in the shader so that "at full strength the
## corners of the frame are actually black" and "at nought the player sees an
## unobstructed view" are assertions instead of a thing somebody once looked at.
## They needed to be: this vignette spent its whole life measuring distance in
## the quad's own UV, and the quad is much bigger than the view, so the entire
## darkening fell outside the frame and the comfort feature did nothing at all.
const APERTURE_OPEN: float = 1.55
const APERTURE_SHUT: float = 0.30
const APERTURE_FEATHER: float = 0.35
## Longest distance from the centre of a frame to any pixel of it.
const FRAME_CORNER: float = 1.4143


## Radius, in half-frame units, of the hole the player still sees through.
static func aperture(strength: float) -> float:
	return lerpf(APERTURE_OPEN, APERTURE_SHUT, clampf(
		strength if is_finite(strength) else 0.0, 0.0, 1.0
	))

# --- physically turning around -----------------------------------------------

## How far the player's shoulders may be from the bird's heading before the
## world is quietly turned to meet them. Deliberately huge: an asymmetric
## posture — one hand further forward, which is also this game's pitch control —
## is worth about 12 degrees, and nothing that a player is doing on purpose
## should ever move the world.
const REORIENT_DEADBAND: float = 0.96  # 55 degrees
## And it has to persist. A glance over the shoulder at a bird you are chasing
## takes a moment; sitting sideways in a swivel chair does not end.
const REORIENT_DWELL: float = 3.0
## Rate the correction is applied at, rad/s. Around 8 deg/s: below the rate at
## which a rotation is noticed as motion at all, which is the entire point —
## the world should be facing you again without you having seen it move.
const REORIENT_RATE: float = 0.14
## Close enough to aligned to stop.
const REORIENT_SETTLED: float = 0.05

var mode: Turning = Turning.SMOOTH
## 0 uses [constant EASED_RATE]. Set from [member Tuning.max_view_yaw_rate].
var max_yaw_rate: float = 0.0
var roll_fraction: float = 0.35
var vignette_gain: float = 0.7
var reorient_enabled: bool = true

## Yaw the view should be drawn at, in the same frame as the heading it follows.
var yaw: float = 0.0
## Roll, in radians, to tip the horizon by.
var roll: float = 0.0
## 0..1 for the comfort vignette.
var vignette: float = 0.0
## Yaw offset applied to the tracked rig to face the player's own body forward.
var reorientation: float = 0.0

var _yaw_rate: float = 0.0
var _step_mask: float = 0.0
var _offset_time: float = 0.0
var _reorienting: bool = false


## One frame. [param heading] is the bird's heading in radians, [param bank] its
## roll, [param speed] its airspeed.
func update(heading: float, bank: float, speed: float, delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var dt: float = minf(delta, 0.1)
	var target: float = heading if is_finite(heading) else yaw
	var safe_bank: float = bank if is_finite(bank) else 0.0
	var safe_speed: float = maxf(speed, 0.0) if is_finite(speed) else 0.0

	var previous: float = yaw
	match mode:
		Turning.EASED:
			_ease_toward(target, dt)
		Turning.STEPPED:
			_step_toward(target)
		_:
			yaw = target
	# Smoothed, not instantaneous: a stepped view moves 18 degrees in one frame
	# and nothing that reads this wants to be told the view briefly rotated at
	# 28 rad/s. The raw delta is still there for anyone measuring the mode's
	# behaviour — it is [member yaw] itself.
	var instant: float = absf(wrapf(yaw - previous, -PI, PI)) / dt
	_yaw_rate = lerpf(_yaw_rate, instant, clampf(dt / 0.15, 0.0, 1.0))

	roll = lerpf(roll, -safe_bank * roll_fraction, clampf(dt * ROLL_RATE, 0.0, 1.0))
	_update_vignette(safe_speed, safe_bank, target, previous, dt)


func _ease_toward(target: float, dt: float) -> void:
	var lag: float = wrapf(target - yaw, -PI, PI)
	if absf(lag) > EASED_GIVE_UP:
		yaw = target
		return
	var ceiling: float = max_yaw_rate if max_yaw_rate > 0.0 else EASED_RATE
	var rate: float = ceiling + EASED_CATCHUP * absf(lag)
	yaw = wrapf(yaw + clampf(lag, -rate * dt, rate * dt), -PI, PI)


## The view sits on the nearest whole step to the heading, and moves only when
## the heading has genuinely crossed into the next one. Rounding rather than
## thresholding is what keeps it from wandering: the same heading always maps to
## the same step, so a bird hovering on a boundary cannot flicker across it more
## than once per crossing.
func _step_toward(target: float) -> void:
	yaw = round(target / STEP) * STEP


func _update_vignette(
	speed: float, bank: float, target: float, previous_yaw: float, dt: float
) -> void:
	var speed_term: float = clampf(
		(speed - VIGNETTE_SPEED_FLOOR) / VIGNETTE_SPEED_RANGE, 0.0, 1.0
	)
	var turn_term: float = clampf(absf(bank) / 1.2, 0.0, 1.0) * VIGNETTE_BANK_WEIGHT
	var yaw_term: float = clampf(
		(_yaw_rate - VIGNETTE_YAW_FLOOR) / VIGNETTE_YAW_RANGE, 0.0, 1.0
	) * VIGNETTE_YAW_WEIGHT
	var strength: float = clampf(
		(speed_term + turn_term + yaw_term) * vignette_gain, 0.0, VIGNETTE_CEILING
	)

	# A stepped view masks the periphery for as long as the heading is moving,
	# whether or not this particular frame stepped. The jumps then happen inside
	# an aperture that is already narrow, which is the whole trick.
	var wanted_mask: float = 0.0
	if mode == Turning.STEPPED:
		var heading_rate: float = absf(wrapf(target - previous_yaw, -PI, PI)) / dt
		wanted_mask = STEP_MASK * clampf(heading_rate / STEP_MASK_RATE, 0.0, 1.0)
	_step_mask = lerpf(_step_mask, wanted_mask, clampf(dt * 4.0, 0.0, 1.0))
	# The mask is scaled by the player's own vignette setting like everything
	# else here: somebody who turned the vignette off asked for an open view and
	# does not get one back through a side door.
	vignette = clampf(
		maxf(strength, _step_mask * vignette_gain), 0.0, VIGNETTE_CEILING
	)


## Puts the view exactly where the bird is, with no easing and no stepping. For
## the moments where "catch up smoothly" would mean spinning the player: a
## respawn, a restart, a recentre.
func snap_to(heading: float) -> void:
	if not is_finite(heading):
		return
	yaw = heading
	_yaw_rate = 0.0
	_step_mask = 0.0


# --- physically turning around -----------------------------------------------

## Eases the tracked rig around to face wherever the player's body has ended up.
##
## [param body_yaw] is the yaw of the line between the player's own shoulders,
## measured in rig space — where they are facing, not where they are looking.
## Reading it from the wing line rather than from the head is what makes this
## safe to leave on: a player watching a bird over their shoulder has not turned
## around, and the world does not move for them. A player who has swivelled
## their chair has, and it does.
##
## [param valid] should be false whenever the measurement is not trustworthy —
## tracking lost, or the hands too close together to define a line.
func update_reorientation(body_yaw: float, valid: bool, delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	if not reorient_enabled or not valid or not is_finite(body_yaw):
		_offset_time = 0.0
		return
	var dt: float = minf(delta, 0.1)
	var error: float = wrapf(body_yaw - reorientation, -PI, PI)

	if absf(error) > REORIENT_DEADBAND:
		_offset_time += dt
	else:
		_offset_time = 0.0
		if absf(error) < REORIENT_SETTLED:
			_reorienting = false
	if _offset_time >= REORIENT_DWELL:
		_reorienting = true
	if not _reorienting:
		return
	reorientation = wrapf(
		reorientation + clampf(error, -REORIENT_RATE * dt, REORIENT_RATE * dt), -PI, PI
	)


## Snaps the rig to the player's body immediately. This is the deliberate
## version — a button or a held gesture — where an instant rotation is expected
## and is therefore not a comfort problem.
func reorient_now(body_yaw: float) -> void:
	if not is_finite(body_yaw):
		return
	reorientation = wrapf(body_yaw, -PI, PI)
	_reorienting = false
	_offset_time = 0.0


func is_reorienting() -> bool:
	return _reorienting


func yaw_rate() -> float:
	return _yaw_rate


func reset() -> void:
	yaw = 0.0
	roll = 0.0
	vignette = 0.0
	reorientation = 0.0
	_yaw_rate = 0.0
	_step_mask = 0.0
	_offset_time = 0.0
	_reorienting = false
