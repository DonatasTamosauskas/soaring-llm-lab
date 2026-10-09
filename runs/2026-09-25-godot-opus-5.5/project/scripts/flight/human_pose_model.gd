class_name HumanPoseModel
extends RefCounted
## A small kinematic human that synthesises anatomically consistent head and
## GRIP poses in tracking space (FLIGHT_SPEC §3, VR panel §2.4). Tests, the
## desktop emulator, the bot pilot and simulator scripts all move ARMS
## through this, never WingState, so calibration, the body frame, shaping,
## flap detection and the physics are exercised together.
##
## Body layout (torso frame: x right, y up, z back), matching WingInput's
## neck-pivot estimate exactly so a default-calibrated WingInput reads this
## body without bias: eye at eye_height; neck = eye + (0, -0.08, +0.09);
## shoulder centre = (0, eye - shoulder_drop, +0.11); shoulders +-width/2.
## The head rotates about the neck, so nods do not move the shoulders.
##
## Arm joints per side (radians):
##   dihedral  elevation of the upper arm (+ = hand up)
##   sweep     hand forward of the shoulder line (+ = forward)
##   twist     wrist roll, + = leading edge up on BOTH hands
##   elbow     forearm bent forward in the arm's horizontal plane (hands to chest)
##   fold      elbow dropped in the vertical plane: reach shrinks along the
##             same line, so dihedral and sweep readings are unchanged
## The controller orientation is the minimal swing from the neutral forearm
## direction to the actual forearm direction, times the wrist twist, times
## the measured "airplane arms, palms down" grip basis: a bent or raised arm
## never reads as twist.

class ArmPose:
	var dihedral := 0.0
	var sweep := 0.0
	var twist := 0.0
	var elbow := 0.0
	var fold := 0.0

	func copy_from(o: ArmPose) -> void:
		dihedral = o.dihedral
		sweep = o.sweep
		twist = o.twist
		elbow = o.elbow
		fold = o.fold

## Measured grip basis for airplane arms, palms down, facing -Z (§3.2):
## a_local = (0, -0.866, -0.5) maps to outward, c_local = (0, 0.5, -0.866)
## to forward, and the up-normal is +X_grip (right) / -X_grip (left).
const NEUTRAL_R := Basis(Vector3(0, 1, 0), Vector3(-0.8660254, 0, -0.5), Vector3(-0.5, 0, 0.8660254))
const NEUTRAL_L := Basis(Vector3(0, -1, 0), Vector3(0.8660254, 0, -0.5), Vector3(0.5, 0, 0.8660254))
const A_LOCAL := Vector3(0, -0.8660254, -0.5)
const C_LOCAL := Vector3(0, 0.5, -0.8660254)

var arm_span := 1.50
var eye_height := 1.62
var shoulder_width := 0.345
var shoulder_drop := 0.24
var torso_yaw := 0.0
var room_offset := Vector3.ZERO
## Whole body lowered by this (crouch, jump < 0).
var crouch := 0.0
var head_yaw := 0.0
var head_pitch := 0.0
var head_roll := 0.0
var arms: Array[ArmPose] = [ArmPose.new(), ArmPose.new()]
## Added to each hand position (tests: shakes, noise, rowing).
var hand_offset: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
## Post-multiplied onto each controller basis (grip-convention robustness).
var grip_offset: Array[Basis] = [Basis(), Basis()]
var tremor_mm := 0.0
var tremor_hz := 9.0
var twist_noise_deg := 0.0
var head_valid := true
var left_valid := true
var right_valid := true
var grip := Vector2.ZERO
var trigger := Vector2.ZERO
var buttons := 0
var t := 0.0

var _rng := RandomNumberGenerator.new()
var _tremor_phase := PackedFloat64Array([0.0, 1.3, 2.1, 0.4, 2.9, 1.7])


func _init(p_seed := 1) -> void:
	set_seed(p_seed)


func set_seed(s: int) -> void:
	_rng.seed = s
	for i in 6:
		_tremor_phase[i] = _rng.randf() * TAU


## Resize the body for an arm span (grip to grip), keeping proportions.
func set_body(p_span: float, p_eye := 1.62) -> void:
	arm_span = p_span
	shoulder_width = 0.23 * p_span
	eye_height = p_eye


func arm_length() -> float:
	return (arm_span - shoulder_width) * 0.5


func torso_basis() -> Basis:
	return Basis(Vector3.UP, torso_yaw)


## Airplane arms, palms down, head level.
func set_airplane() -> void:
	for a in arms:
		a.dihedral = 0.0
		a.sweep = 0.0
		a.twist = 0.0
		a.elbow = 0.0
		a.fold = 0.0
	head_yaw = 0.0
	head_pitch = 0.0
	head_roll = 0.0


## Human-rate arms: low-pass every joint toward the values set this tick
## (call after setting the targets). Scripts that switch gestures abruptly
## otherwise teleport the hands, which no person can do.
var _jf: Array = []
func humanize(dt: float, tau := 0.12) -> void:
	var k := 1.0 - exp(-dt / tau)
	if _jf.is_empty():
		for a in arms:
			_jf.append([a.dihedral, a.sweep, a.twist, a.elbow, a.fold])
		return
	for i in 2:
		var a := arms[i]
		var f: Array = _jf[i]
		var tgt := [a.dihedral, a.sweep, a.twist, a.elbow, a.fold]
		for j in 5:
			f[j] = f[j] + (float(tgt[j]) - float(f[j])) * k
		a.dihedral = f[0]
		a.sweep = f[1]
		a.twist = f[2]
		a.elbow = f[3]
		a.fold = f[4]


func neck_point() -> Vector3:
	return room_offset + torso_basis() * Vector3(0.0, eye_height - crouch - 0.08, 0.09)


func shoulder_centre() -> Vector3:
	return room_offset + torso_basis() * Vector3(0.0, eye_height - crouch - shoulder_drop, 0.11)


func shoulder(side: int) -> Vector3:
	var sig := -1.0 if side == 0 else 1.0
	return shoulder_centre() + torso_basis() * Vector3(sig * shoulder_width * 0.5, 0.0, 0.0)


func head_basis() -> Basis:
	return torso_basis() * Basis(Vector3.UP, head_yaw) * Basis(Vector3.RIGHT, head_pitch) * Basis(Vector3.BACK, head_roll)


func head_transform() -> Transform3D:
	var hb := head_basis()
	return Transform3D(hb, neck_point() + hb * Vector3(0.0, 0.08, -0.09))


## Upper arm and forearm directions in the torso frame.
func arm_dirs(side: int) -> Array[Vector3]:
	var sig := -1.0 if side == 0 else 1.0
	var a := arms[side]
	var cd := cos(a.dihedral)
	var u := Vector3(sig * cd * cos(a.sweep), sin(a.dihedral), -cd * sin(a.sweep))
	var f := u
	if absf(a.fold) > 1e-6:
		# Elbow dropped in the vertical plane through the arm line: rotating
		# about the horizontal axis k = u x UP tilts the upper arm down and the
		# forearm up by the same angle, so the hand stays on the arm line at
		# reach L cos(fold).
		var k := u.cross(Vector3.UP)
		k = k.normalized() if k.length() > 1e-6 else Vector3(0, 0, 1)
		f = (Basis(k, a.fold) * u).normalized()
		u = (Basis(k, -a.fold) * u).normalized()
	if absf(a.elbow) > 1e-6:
		var fwd := Vector3(0, 0, -1)
		var fp := fwd - f * fwd.dot(f)
		if fp.length() < 1e-4:
			fp = Vector3.UP - f * f.y
		fp = fp.normalized()
		f = (f * cos(a.elbow) + fp * sin(a.elbow)).normalized()
	return [u, f]


func hand_position(side: int) -> Vector3:
	return _hand_position(side, arm_dirs(side), torso_basis())


func _hand_position(side: int, d: Array[Vector3], tb: Basis) -> Vector3:
	var l2 := arm_length() * 0.5
	var p := shoulder(side) + tb * (d[0] * l2 + d[1] * l2) + hand_offset[side]
	if tremor_mm > 0.0:
		var k := side * 3
		var w := TAU * tremor_hz * t
		p += Vector3(sin(w + _tremor_phase[k]), sin(w * 1.13 + _tremor_phase[k + 1]), sin(w * 0.91 + _tremor_phase[k + 2])) * tremor_mm * 0.001
	return p


func hand_basis(side: int) -> Basis:
	return _hand_basis(side, arm_dirs(side), torso_basis())


func _hand_basis(side: int, d: Array[Vector3], tb: Basis) -> Basis:
	var sig := -1.0 if side == 0 else 1.0
	var f: Vector3 = d[1]
	var out := Vector3(sig, 0.0, 0.0)
	var swing := Basis(Quaternion(out, f)) if out.dot(f) > -0.9999 else Basis(Vector3.UP, PI)
	var tw := arms[side].twist
	if twist_noise_deg > 0.0:
		tw += deg_to_rad(_rng.randfn(0.0, twist_noise_deg))
	var neutral := NEUTRAL_L if side == 0 else NEUTRAL_R
	return tb * swing * Basis(Vector3.RIGHT, tw) * neutral * grip_offset[side]


## (The arm directions and the torso frame once per hand, fix round 6: the
## suite's time budget; the same values as hand_basis and hand_position.)
func hand_transform(side: int) -> Transform3D:
	var d := arm_dirs(side)
	var tb := torso_basis()
	return Transform3D(_hand_basis(side, d, tb), _hand_position(side, d, tb))


## Build the tracking-space frame (no allocation beyond Transform values).
func frame(out: PoseFrame) -> void:
	out.t = t
	out.head = head_transform()
	out.left = hand_transform(0)
	out.right = hand_transform(1)
	out.head_valid = head_valid
	out.left_valid = left_valid
	out.right_valid = right_valid
	out.grip = grip
	out.trigger = trigger
	out.buttons = buttons
	out.discontinuity = false


# ---------------------------------------------------------------------------
# Pose synthesis: WingState-style commands -> joints (the inverse of
# WingInput's shaping, for the bot, the desktop emulator and round trips).

## Sets both arms for a symmetric pitch, a roll and a spread, as twist (pitch,
## aileron) and vertical elbow fold (spread). `stroke` adds to the dihedral
## (the wingbeat). dz_scale/sensitivity mirror WingInput's shaping settings.
func synth(pitch: float, roll: float, spread: float, cal: WingCalibration, dz_scale := 1.0, sensitivity := 1.0,
		roll_by_dihedral := 0.0) -> void:
	var ts := FlightMath.unshape(clampf(pitch, -1.0, 1.0), deg_to_rad(5.0) * dz_scale,
		deg_to_rad(40.0) / sensitivity, deg_to_rad(30.0) / sensitivity, 1.4)
	var r := clampf(roll, -1.0, 1.0)
	var r_twist := r * (1.0 - roll_by_dihedral)
	var r_dih := r * roll_by_dihedral
	var ta := FlightMath.unshape(r_twist, deg_to_rad(4.0) * dz_scale, deg_to_rad(25.0) / sensitivity,
		deg_to_rad(25.0) / sensitivity, 1.3)
	var da := FlightMath.unshape(r_dih, deg_to_rad(4.0) * dz_scale, deg_to_rad(30.0), deg_to_rad(30.0), 1.2)
	arms[0].twist = ts + ta
	arms[1].twist = ts - ta
	arms[0].dihedral = da
	arms[1].dihedral = -da
	var fold := fold_for_extension(spread, cal)
	for a in arms:
		a.fold = fold
		a.elbow = 0.0
		a.sweep = 0.0


## Vertical elbow fold that makes WingInput read extension `e` (straight arm
## = 1). Inverts smoothstep(0.30, R_HI, reach).
static func fold_for_extension(e: float, cal: WingCalibration) -> float:
	var ee := clampf(e, 0.0, 1.0)
	if ee >= 0.999:
		return 0.0
	# inverse of t^2 (3 - 2t)
	var tt := 0.5 - sin(asin(1.0 - 2.0 * ee) / 3.0)
	var r_hi := cal.glide_reach if cal != null else 0.62
	var rc := lerpf(0.30, r_hi, tt)
	return acos(clampf(rc, 0.0, 1.0))
