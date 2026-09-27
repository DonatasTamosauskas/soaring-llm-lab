class_name VignetteModel
extends RefCounted
## How strongly to narrow the view: fast turns, speed (DESIGN: "comfort
## vignette on fast turns/speed") and sustained accelerations near what the
## eye can see them by.
##
## All inputs in WORLD units measured on the rig (so they are exactly the
## vection-inducing motion: the rig's motion excludes the player's own head
## movement, which is never a mismatch):
##   yaw_term   = smoothstep(35°/s, 150°/s, |rig yaw rate|)
##                (the view's angular velocity: flight never pitches or
##                rolls the view, so its yaw is all of it)
##   speed_term = smoothstep(1.3, 2.3, speed / cruise speed)
##                (speed_ratio: the rig's smoothed speed over the bird's own
##                cruise, SizeRules.cruise_speed; a dive or a boost, never
##                steady cruise; ComfortVignette)
##   accel_term = smoothstep(6, 20, |rig acceleration| / world_scale)
##                x proximity
##                (perceived m/s²: the eye judges motion in body sizes;
##                speed changes and heave only: a coordinated turn's
##                centripetal part is the yaw term's job; averaged over one
##                wingbeat, so the beat itself never counts: ComfortVignette)
##   proximity  = 1 near a surface, 0 with nothing within 8 body spans; a
##                SLOW quantity (held and low-passed, ComfortVignette)
##   target     = setting * max(yaw_term, 0.7 speed_term, 0.5 accel_term)
##   strength   -> target with a fast attack (0.08 s) and a slow release
##                (0.5 s)
## (flight_vr.md §11.4 / FLIGHT_SPEC C9 thresholds and weights for yaw and
## acceleration, and its speed-driven term's weight.)
##
## The speed term (fix round 5; the experience verifier: round 4 had no
## speed response, which DESIGN asks for). flight_vr.md §11.4's version,
## optic flow = speed / the nearest surface, follows the distance to the
## canopy: per frame on single rays it made the ring pulse 0 <-> 0.4 about
## once a second over the orchard rows (fix round 4 removed it), and even
## held and smoothed it swings with the canopy's height along a line (a
## sweep over the real orchard, forest and power line: std up to 0.20 in
## steady cruise; VR.md §2.5). Speed over the bird's own cruise speed is
## steady whenever the speed is (every steady cruise keeps the full view,
## wherever it is flown), scale-free (a sparrow's and an eagle's dives read
## alike) and still answers what DESIGN names: going fast.

const YAW_LO := deg_to_rad(35.0)
const YAW_HI := deg_to_rad(150.0)
const ACCEL_LO := 6.0
const ACCEL_HI := 20.0
const ACCEL_WEIGHT := 0.5
## Speed (fix round 5): the rig's smoothed speed over the bird's own
## cruise speed (SizeRules.cruise_speed; ComfortVignette.speed_ratio).
## Cruise and anything slower keep the full view; a dive or a boost
## narrows it, in full from 2.3 x cruise (flight's tucked-dive limit is
## 2.6 x). The weight is flight_vr.md §11.4's for its speed-driven flow
## term.
const SPEED_LO := 1.3
const SPEED_HI := 2.3
const SPEED_WEIGHT := 0.7
const ATTACK := 0.08
const RELEASE := 0.5

var strength := 0.0
var target := 0.0
## Last terms, for plots and logs.
var yaw_term := 0.0
var accel_term := 0.0
var speed_term := 0.0


## proximity: 0..1, how near a surface is to judge an acceleration by
## (1 = within 3 body spans; ComfortVignette.accel_proximity). speed_ratio:
## the smoothed speed over the bird's cruise speed (0: unknown, no term).
static func target_for(setting: float, yaw_rate: float, accel: float, world_scale: float, proximity: float = 1.0, speed_ratio: float = 0.0) -> float:
	if setting <= 0.0:
		return 0.0
	var y := VRMath.sstep(YAW_LO, YAW_HI, absf(yaw_rate))
	var a := VRMath.sstep(ACCEL_LO, ACCEL_HI, accel / maxf(world_scale, 0.01)) * clampf(proximity, 0.0, 1.0)
	var v := VRMath.sstep(SPEED_LO, SPEED_HI, speed_ratio)
	return clampf(setting, 0.0, 1.0) * maxf(y, maxf(SPEED_WEIGHT * v, ACCEL_WEIGHT * a))


## Advances the smoothed strength. Returns it.
func update(setting: float, yaw_rate: float, accel: float, world_scale: float, dt: float, proximity: float = 1.0, speed_ratio: float = 0.0) -> float:
	yaw_term = VRMath.sstep(YAW_LO, YAW_HI, absf(yaw_rate))
	accel_term = VRMath.sstep(ACCEL_LO, ACCEL_HI, accel / maxf(world_scale, 0.01)) * clampf(proximity, 0.0, 1.0)
	speed_term = VRMath.sstep(SPEED_LO, SPEED_HI, speed_ratio)
	# = target_for(...), from the terms just computed.
	target = clampf(setting, 0.0, 1.0) * maxf(yaw_term, maxf(SPEED_WEIGHT * speed_term, ACCEL_WEIGHT * accel_term)) if setting > 0.0 else 0.0
	var tau := ATTACK if target > strength else RELEASE
	strength += (target - strength) * VRMath.lp(dt, tau)
	if setting <= 0.0:
		strength = 0.0
	elif strength < 0.002 and target <= 0.0:
		# Below what the ring can show (the node hides under 0.002): done.
		strength = 0.0
	return strength


func reset() -> void:
	strength = 0.0
	target = 0.0
