class_name FlightMath
extends RefCounted
## Small numeric helpers shared by the flight area.
##
## The spec (FLIGHT_SPEC §1) defines smoothstep and the shaping curve
## precisely, including edge cases the built-ins handle differently, so every
## flight script uses these instead of the engine's smoothstep().

const G := 9.81
const RHO := 1.225


## t = clamp((v - a) / (b - a), 0, 1); t^2 (3 - 2t). Also valid when a > b
## (then it falls from 1 to 0), which the built-in does not promise.
static func sstep(a: float, b: float, v: float) -> float:
	if a == b:
		return 1.0 if v >= a else 0.0
	var t := clampf((v - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Dead-zone plus expo shaping (§5.9): 0 inside the dead zone, then a power
## curve to +-1 at full scale. full_pos applies to x > 0, full_neg to x < 0.
static func shape(x: float, dz: float, full_pos: float, full_neg: float, expo: float) -> float:
	var a := absf(x) - dz
	if a <= 0.0:
		return 0.0
	var full := full_pos if x > 0.0 else full_neg
	return signf(x) * pow(clampf(a / maxf(full - dz, 1e-6), 0.0, 1.0), expo)


## Inverse of shape() for |y| <= 1 (used by the pose synthesiser and the bot):
## the raw input that produces y. 0 maps to 0 (the dead-zone centre).
static func unshape(y: float, dz: float, full_pos: float, full_neg: float, expo: float) -> float:
	if absf(y) < 1e-9:
		return 0.0
	var full := full_pos if y > 0.0 else full_neg
	return signf(y) * (dz + (full - dz) * pow(clampf(absf(y), 0.0, 1.0), 1.0 / expo))


## Wraps to [-PI, PI), exactly (fix round 6): Godot's wrapf snaps a result
## within its is_equal_approx tolerance of the upper bound (~1e-5 relative,
## 3e-5 rad here) to the lower one, losing that much angle at the seam.
static func wrap_angle(a: float) -> float:
	if a >= -PI and a < PI:
		return a
	return fposmod(a + PI, TAU) - PI


## Horizontal part of v (y removed).
static func horiz(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Godot yaw of a horizontal direction: forward (-Z) is 0, CCW from above is +.
static func yaw_of(v: Vector3) -> float:
	return atan2(-v.x, -v.z)


## Unit forward for a Godot yaw.
static func yaw_forward(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## First-order low-pass factor for a time constant (never h/tau: §1).
static func lp_k(h: float, tau: float) -> float:
	if tau <= 0.0:
		return 1.0
	return 1.0 - exp(-h / tau)


static func vfinite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


static func bfinite(b: Basis) -> bool:
	return vfinite(b.x) and vfinite(b.y) and vfinite(b.z)


## Piecewise-linear interpolation over sorted (x, y) pairs, clamped at the ends.
static func pwl(xs: PackedFloat64Array, ys: PackedFloat64Array, x: float) -> float:
	var n := xs.size()
	if n == 0:
		return 0.0
	if x <= xs[0]:
		return ys[0]
	for i in range(1, n):
		if x <= xs[i]:
			var span := xs[i] - xs[i - 1]
			var k := (x - xs[i - 1]) / span if span > 1e-12 else 1.0
			return lerpf(ys[i - 1], ys[i], k)
	return ys[n - 1]
