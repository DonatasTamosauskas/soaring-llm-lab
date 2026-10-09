class_name HudMath
extends RefCounted
## Pure maths for the HUD's directional cues and growth bar. No scene access,
## so every case (target behind, left, right, above, below; fades) is pinned
## by unit tests.
##
## Angle convention for cues: radians in the view plane, 0 = right,
## +PI/2 = up, PI = left, -PI/2 = down (like a clock face read on screen).

## Behind the player, up/down matters much less than which way to turn
## (the bird can yaw, the camera can't pitch), so the chevron's up/down tilt
## is the bird's elevation scaled down towards this weight as the bird gets
## further behind (full elevation at the eye plane, 0.3 of it dead behind).
const BEHIND_VERTICAL_WEIGHT := 0.3
## A bird within this fraction of its distance of the view's vertical
## mid-plane has no clear side (dead ahead or dead behind).
const SIDE_EPS := 0.02


## Where `target` is relative to a camera/head transform (-Z forward):
##   off_axis   angle from the view centre, rad (0 ahead .. PI behind)
##   angle      direction on the view plane (see convention above); behind
##              the eye plane it is the "turn this way" cue for `side`
##   distance   metres
##   behind     target is behind the eye plane
##   side       +1 right, -1 left, 0 on the vertical mid-plane
##   lateral    true angle from the view's vertical mid-plane, rad (signed,
##              + right): asin(x / distance). Unlike a horizontal-plane
##              angle it stays small for a bird high above and behind, so a
##              few degrees of real movement never look like a big swing
##   elevation  angle above the horizontal plane of the view, rad
##   behindness 0 at the eye plane .. 1 dead behind (level)
##   ambiguous  no preferred side and no direction (dead ahead or dead behind)
static func view_polar(cam: Transform3D, target: Vector3) -> Dictionary:
	var local := cam.affine_inverse() * target
	var dist := local.length()
	if dist < 1e-6:
		return {"off_axis": 0.0, "angle": 0.0, "distance": 0.0, "behind": false, "side": 0, "lateral": 0.0,
			"elevation": 0.0, "behindness": 0.0, "ambiguous": true}
	var off := acos(clampf(-local.z / dist, -1.0, 1.0))
	var behind := local.z > 0.0
	var side := 1 if local.x > dist * SIDE_EPS else (-1 if local.x < -dist * SIDE_EPS else 0)
	var elevation := atan2(local.y, Vector2(local.x, local.z).length())
	var behindness := clampf(local.z / dist, 0.0, 1.0)
	var angle := 0.0
	var ambiguous := false
	if behind:
		# The cue says which way to turn; a bird dead behind has no side of
		# its own (IndicatorFilter latches one so the cue never swings).
		ambiguous = side == 0
		angle = behind_angle(elevation, behindness, side if side != 0 else 1)
	else:
		var flat := Vector2(local.x, local.y)
		ambiguous = flat.length() < dist * SIDE_EPS
		angle = atan2(flat.y, flat.x) if not ambiguous else 0.0
	return {"off_axis": off, "angle": angle, "distance": dist, "behind": behind, "side": side,
		"lateral": asin(clampf(local.x / dist, -1.0, 1.0)), "elevation": elevation, "behindness": behindness, "ambiguous": ambiguous}


## Cue angle for a bird behind the eye plane, pointing to `side` (+1 right,
## -1 left) and tilted by its (down-weighted) elevation. At the eye plane
## (behindness 0) this equals the in-front projection angle atan2(y, x), so
## the cue is continuous as a bird passes your wingtip.
static func behind_angle(elevation: float, behindness: float, side: int) -> float:
	var tilt := elevation * lerpf(1.0, BEHIND_VERTICAL_WEIGHT, clampf(behindness, 0.0, 1.0))
	return tilt if side >= 0 else wrapf(PI - tilt, -PI, PI)


## Target cue strength from how long it would take to reach the target at
## cruise speed: full within near_s, gone beyond far_s. Scale-free, so it
## means the same for a wren and an eagle.
static func target_alpha(distance: float, cruise: float, near_s: float = 2.0, far_s: float = 9.0) -> float:
	var t := distance / maxf(cruise, 0.5)
	return 1.0 - smoothstep(near_s, far_s, t)


## Threat cue strength from the game loop's threat level (0..1): nothing
## below `floor`, then rising, so a distant hawk does not nag.
static func threat_alpha(level: float, floor_level: float = 0.12) -> float:
	return clampf(inverse_lerp(floor_level, 0.8, level), 0.0, 1.0)


## 0..1 progress from the current species towards the next, on a log scale
## (growth is multiplicative: 2x mass feels like the same step anywhere).
static func growth_progress(mass: float) -> float:
	var i := SizeRules.tier_for_mass(mass)
	if i >= SizeRules.SPECIES.size() - 1:
		return 1.0
	var m0: float = SizeRules.SPECIES[i]["mass"]
	var m1: float = SizeRules.SPECIES[i + 1]["mass"]
	return clampf(log(maxf(mass, 1e-6) / m0) / log(m1 / m0), 0.0, 1.0)


## Point on a view-space ring: `eccentricity` rad from the view centre at
## `angle` on the view plane, `radius` metres in front of the eye.
static func ring_point(angle: float, eccentricity: float, radius: float) -> Vector3:
	return Vector3(sin(eccentricity) * cos(angle), sin(eccentricity) * sin(angle), -cos(eccentricity)) * radius
