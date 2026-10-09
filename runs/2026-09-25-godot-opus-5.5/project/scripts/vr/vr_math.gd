class_name VRMath
extends RefCounted
## Small math helpers shared by the VR area (calibration, wings, vignette).
##
## Conventions follow docs/areas/FLIGHT_SPEC.md §1: +Y up, -Z forward, yaw
## CCW-positive seen from above, side sign σ = -1 left / +1 right.


## smoothstep that also works when a > b (FLIGHT_SPEC §1: never use the
## built-in, whose edge handling differs when the edges are reversed).
static func sstep(a: float, b: float, v: float) -> float:
	if is_equal_approx(a, b):
		return 1.0 if v >= b else 0.0
	var t := clampf((v - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Wraps an angle to (-PI, PI].
static func wrap_angle(a: float) -> float:
	return wrapf(a, -PI, PI)


## Horizontal part of v (y removed).
static func horiz(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Godot yaw of a horizontal direction: forward (0,0,-1) is 0, CCW positive.
static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


## Exponential smoothing factor for a time constant (never h/τ: FLIGHT_SPEC §1).
static func lp(dt: float, tau: float) -> float:
	return 1.0 if tau <= 0.0 else 1.0 - exp(-dt / tau)


## Head forward that stays continuous through straight-up and straight-down
## gazes (FLIGHT_SPEC §5.1).
static func head_forward(head: Basis) -> Vector3:
	var zf := -head.z
	var f := horiz(zf) - zf.y * horiz(head.y)
	if f.length_squared() < 1e-8:
		return Vector3.FORWARD
	return f.normalized()


## Twist angle (rad) of rotation q about unit axis (swing-twist
## decomposition, FLIGHT_SPEC §5.7) and the decomposition's confidence
## (near 0 when the swing is close to 180°, where twist is undefined).
static func twist_about(q: Quaternion, axis: Vector3) -> Vector2:
	var p := Vector3(q.x, q.y, q.z).dot(axis)
	var t := wrap_angle(2.0 * atan2(p, q.w))
	return Vector2(t, sqrt(q.w * q.w + p * p))


## Mean of rotations (sign-aligned quaternion average); good for the small
## spreads of a held pose.
static func mean_basis(bases: Array[Basis]) -> Basis:
	if bases.is_empty():
		return Basis.IDENTITY
	var ref := bases[0].get_rotation_quaternion()
	var acc := Vector4.ZERO
	for b in bases:
		var q := b.get_rotation_quaternion()
		var v := Vector4(q.x, q.y, q.z, q.w)
		if v.dot(Vector4(ref.x, ref.y, ref.z, ref.w)) < 0.0:
			v = -v
		acc += v
	acc = acc.normalized()
	return Basis(Quaternion(acc.x, acc.y, acc.z, acc.w))


## Angle (rad) between two rotations.
static func basis_angle(a: Basis, b: Basis) -> float:
	var q := (a.inverse() * b).get_rotation_quaternion()
	return 2.0 * acos(clampf(absf(q.w), 0.0, 1.0))


## Plain arrays (JSON-safe persistence, as flight's from_dict also
## accepts) -> Basis / Vector3; native values pass through.
static func array_to_basis(a: Variant, fallback: Basis) -> Basis:
	if a is Basis:
		return a
	if not (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) or a.size() != 9:
		return fallback
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8]))


static func array_to_vec(a: Variant, fallback: Vector3) -> Vector3:
	if a is Vector3:
		return a
	if not (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) or a.size() != 3:
		return fallback
	return Vector3(a[0], a[1], a[2])


## True when every component of the transform is finite and the basis is
## a sane rotation (FLIGHT_SPEC §3.1 per-tick sanity check).
static func pose_sane(t: Transform3D, max_dist: float = 20.0) -> bool:
	var o := t.origin
	if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)):
		return false
	if o.length() > max_dist:
		return false
	var d := t.basis.determinant()
	return is_finite(d) and d > 0.5
