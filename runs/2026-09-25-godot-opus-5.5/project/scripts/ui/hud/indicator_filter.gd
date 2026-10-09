class_name IndicatorFilter
extends RefCounted
## Turns raw per-frame cue inputs into calm, flicker-free cue state:
##  - visibility has hysteresis on the off-axis angle (appears past CONE_OUT,
##    disappears inside CONE_IN), so a target hovering at the edge of view
##    does not blink;
##  - the wanted strength is low-passed and then held inside a dead band, so
##    a jittery threat level (it is recomputed every physics frame) cannot
##    make the cue shimmer;
##  - alpha eases with a time constant and a hard rate limit;
##  - angle eases on the circle (wrap-aware), only while the bird is outside
##    the central cone, and snaps while invisible;
##  - a bird behind you gets a *latched* turn side: it only changes once the
##    bird is SIDE_SWITCH past dead behind on the other side. A hawk wobbling
##    on your tail would otherwise flip the cue left/right several times a
##    second, swinging it under the view;
##  - a change of side, or a new bird in a clearly different direction, is a
##    cut (hidden, moved, faded back in), never a sweep across the view.

const CONE_IN := deg_to_rad(15.0)
const CONE_OUT := deg_to_rad(21.0)
## Low-pass on the wanted strength (noise rejection), s.
const INPUT_TAU := 0.25
## Changes of the wanted strength smaller than this are ignored.
const DEADBAND := 0.08
const ALPHA_TAU := 0.15
## Max alpha change per second (full fade no faster than ~0.25 s).
const ALPHA_RATE := 4.0
const ANGLE_TAU := 0.07
## A cue fainter than this is not drawn at all.
const MIN_VISIBLE_ALPHA := 0.02
## A bird behind you must be this far past the view's vertical mid-plane
## (true angle, see HudMath "lateral"), on the other side, before the
## latched turn side changes (a 30-degree-wide hysteresis band).
const SIDE_SWITCH := deg_to_rad(15.0)
## A side change whose two cue directions are closer than this (a bird high
## overhead: both point nearly straight up) slides the cue over instead of
## cutting it; a cut there would only be a blink.
const SIDE_SLIDE := deg_to_rad(60.0)
## A new bird further than this from where the cue points is a cut, not an
## eased move (birds in the same flock just slide the cue over).
const RETARGET_CUT := deg_to_rad(45.0)

var alpha := 0.0
var angle := 0.0
var outside := false
var toggles := 0
## Latched turn side for birds behind the eye plane (+1 right, -1 left).
var side := 0
## Side changes and retarget cuts so far (diagnostics and tests).
var cuts := 0

var _want := 0.0
var _held := 0.0
var _retarget := false


func reset() -> void:
	alpha = 0.0
	outside = false
	side = 0
	_want = 0.0
	_held = 0.0
	_retarget = false


## The cue now tracks a different bird: the next update decides between an
## eased slide (same direction) and a cut (anywhere else).
func retarget() -> void:
	_retarget = true


## polar: HudMath.view_polar(); strength: 0..1 wanted opacity when outside
## the central cone (0 also for "no target").
func update(delta: float, polar: Dictionary, strength: float) -> void:
	var has := not polar.is_empty() and strength > 0.0
	var visible_before := alpha >= MIN_VISIBLE_ALPHA
	var target_angle := _target_angle(polar, has, visible_before)
	# A side change behind you cuts the cue (see _target_angle).
	visible_before = visible_before and alpha >= MIN_VISIBLE_ALPHA
	if _retarget:
		_retarget = false
		if has:
			var off: float = polar["off_axis"]
			var far_off := absf(wrapf(target_angle - angle, -PI, PI)) > RETARGET_CUT
			if visible_before and (far_off or off < CONE_IN):
				_cut()
				visible_before = false
			# The new bird gets its own cone state (no inherited hysteresis).
			outside = off > (CONE_IN + CONE_OUT) * 0.5
		elif visible_before:
			_cut()
			visible_before = false
	var was := outside
	if has:
		var off2: float = polar["off_axis"]
		if outside and off2 < CONE_IN:
			outside = false
		elif not outside and off2 > CONE_OUT:
			outside = true
	else:
		outside = false
	if was != outside:
		toggles += 1
	var raw := strength if (has and outside) else 0.0
	if raw <= 0.0:
		# Disappearing must be prompt: no low-pass on the way to zero.
		_want = 0.0
		_held = 0.0
	else:
		# Appearing starts from the current strength, then tracks it slowly.
		_want = raw if _held <= 0.0 else lerpf(_want, raw, 1.0 - exp(-delta / INPUT_TAU))
		if _held <= 0.0 or absf(_want - _held) > DEADBAND:
			_held = _want
	var eased := lerpf(alpha, _held, 1.0 - exp(-delta / ALPHA_TAU))
	alpha = move_toward(alpha, eased, ALPHA_RATE * delta)
	if has and not is_nan(target_angle):
		if not visible_before:
			angle = target_angle
		elif outside:
			# Inside the cone the cue is fading out: hold its direction rather
			# than let it swing round as the bird crosses the view centre.
			angle += wrapf(target_angle - angle, -PI, PI) * (1.0 - exp(-delta / ANGLE_TAU))
			angle = wrapf(angle, -PI, PI)


func is_drawn() -> bool:
	return alpha >= MIN_VISIBLE_ALPHA


## Drawn, or about to be (a bird outside the central cone that it is
## fading in for).
func is_wanted() -> bool:
	return is_drawn() or _held > 0.0


## Where the cue should point this frame (NAN = no direction), updating the
## latched turn side for birds behind the eye plane.
func _target_angle(polar: Dictionary, has: bool, visible_before: bool) -> float:
	if not has:
		return NAN
	if not bool(polar.get("behind", false)):
		var s: int = polar.get("side", 0)
		var a: float = NAN if bool(polar.get("ambiguous", false)) else float(polar["angle"])
		# A bird that jumped round to the other side in one step (respawn,
		# teleport) must not drag the cue across the view either.
		if s != 0 and side != 0 and s != side and visible_before and not is_nan(a) and absf(wrapf(a - angle, -PI, PI)) > PI * 0.5:
			_cut()
		if s != 0:
			side = s
		return a
	var s2: int = polar.get("side", 0)
	if side == 0 or not visible_before or _retarget:
		# Fresh cue: take the bird's own side, else keep pointing the way the
		# cue already points, else right.
		side = s2 if s2 != 0 else (side if side != 0 else (1 if cos(angle) >= 0.0 else -1))
	elif s2 != 0 and s2 != side and absf(float(polar.get("lateral", 0.0))) > SIDE_SWITCH:
		side = s2
		var a := HudMath.behind_angle(float(polar.get("elevation", 0.0)), float(polar.get("behindness", 1.0)), side)
		# The cue jumps to the other side of the view: cut, never sweep
		# (unless both sides point almost the same way: then it slides).
		if absf(wrapf(a - angle, -PI, PI)) > SIDE_SLIDE:
			_cut()
		return a
	return HudMath.behind_angle(float(polar.get("elevation", 0.0)), float(polar.get("behindness", 1.0)), side)


## Hide the cue at once so it can reappear somewhere else (fades back in).
func _cut() -> void:
	if alpha >= MIN_VISIBLE_ALPHA:
		cuts += 1
	alpha = 0.0
	_want = 0.0
	_held = 0.0
