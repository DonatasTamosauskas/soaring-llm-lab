class_name VRHumanPose
extends RefCounted
## A small kinematic human that produces anatomically consistent head and
## grip poses in TRACKING space (real metres, before world_scale).
##
## Used by the VR tests (synthetic players of different sizes and wrist
## habits), the dev scene's puppet, and the simulator harness's scripted pose
## override. It follows the construction in docs/design/flight_vr.md §2.4 so
## its neutral "airplane arms, palms down" grip reproduces the measured
## OpenXR grip convention (FLIGHT_SPEC §3.2): forearm axis (0,-0.866,-0.5)
## and chord (0,0.5,-0.866) in the grip frame, for both hands.
##
## Arm angles are per side, index 0 = left, 1 = right; all radians:
##   dihedral + = hand above the shoulder, sweep + = hand forward,
##   twist    + = leading edge up (both hands), elbow + = forearm bent forward.

const SIDE_SIGN := [-1.0, 1.0]
## Measured grip = aim · Rx(+60°) (FLIGHT_SPEC §3.2).
const GRIP_OFF_ANGLE := PI / 3.0
## Neck pivot relative to the eyes, head frame (FLIGHT_SPEC §5.3).
const NECK_OFFSET := Vector3(0.0, -0.08, 0.09)

var arm_span := 1.50          ## grip to grip, arms spread straight, m
var eye_height := 1.62
var shoulder_width := 0.345
var shoulder_drop := 0.24     ## eyes to shoulder joints, m
var torso_yaw := 0.0
var room_offset := Vector3.ZERO
var head_yaw := 0.0           ## relative to the torso
var head_pitch := 0.0
var head_roll := 0.0
var dihedral: Array[float] = [0.0, 0.0]
var sweep: Array[float] = [0.0, 0.0]
var twist: Array[float] = [0.0, 0.0]
var elbow: Array[float] = [0.0, 0.0]
## The player's own idea of "flat": a wrist roll they hold without knowing.
## Calibration must absorb it.
var twist_offset: Array[float] = [0.0, 0.0]


## A player whose grip-to-grip span is `span` (ape index 1: height is about
## span + 0.16 m fingertip allowance), standing or seated.
static func for_span(span: float, seated: bool = false) -> VRHumanPose:
	var h := VRHumanPose.new()
	var height := span + 0.16
	h.arm_span = span
	h.shoulder_width = 0.23 * span
	h.shoulder_drop = 0.15 * height
	h.eye_height = (0.455 + 0.44 * height) if seated else 0.935 * height
	return h


func arm_length() -> float:
	return (arm_span - shoulder_width) * 0.5


func torso_basis() -> Basis:
	return Basis(Vector3.UP, torso_yaw)


func head_basis() -> Basis:
	return torso_basis() * Basis(Vector3.UP, head_yaw) * Basis(Vector3.RIGHT, head_pitch) * Basis(Vector3.BACK, head_roll)


## The neck pivot is fixed on the torso; the eyes rotate about it.
func neck() -> Vector3:
	var t := torso_basis()
	return room_offset + Vector3(0.0, eye_height + NECK_OFFSET.y, 0.0) + t * Vector3(0.0, 0.0, NECK_OFFSET.z)


func head_transform() -> Transform3D:
	var hb := head_basis()
	return Transform3D(hb, neck() - hb * NECK_OFFSET)


## True shoulder joint. Matches the neck-pivot estimator of FLIGHT_SPEC §5.3
## exactly for any head rotation (by construction), so tests isolate the
## calibration maths from shoulder-model error.
func shoulder(side: int) -> Vector3:
	var t := torso_basis()
	var f := t * Vector3.FORWARD
	var rt := t * Vector3.RIGHT
	var centre := neck() + Vector3(0.0, -(shoulder_drop + NECK_OFFSET.y), 0.0) - f * 0.02
	return centre + rt * (SIDE_SIGN[side] * shoulder_width * 0.5)


## The "airplane arms, palms down" grip basis for a side, in the arm-local
## frame (flight_vr.md §2.4 AIR_s · GRIP_OFF).
static func airplane_basis(side: int) -> Basis:
	var air: Basis
	if side == 1:
		air = Basis(Vector3(0, 1, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0))
	else:
		air = Basis(Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))
	return air * Basis(Vector3.RIGHT, GRIP_OFF_ANGLE)


## Rotation from the neutral arm frame (arm straight out, level) to the
## current arm direction: torso yaw, sweep and dihedral.
func _arm_frame(side: int) -> Basis:
	var s: float = SIDE_SIGN[side]
	return torso_basis() * Basis(Vector3.UP, s * sweep[side]) * Basis(Vector3.BACK, s * dihedral[side])


func hand_transform(side: int) -> Transform3D:
	var s: float = SIDE_SIGN[side]
	var d := _arm_frame(side)
	var outward := d * Vector3(s, 0.0, 0.0)
	var hinge := d * Vector3.UP
	var bend := Basis(hinge, s * elbow[side])
	var l := arm_length()
	var elbow_pos := shoulder(side) + outward * (l * 0.5)
	var hand := elbow_pos + (bend * outward) * (l * 0.5)
	var basis := bend * d * Basis(Vector3.RIGHT, twist[side] + twist_offset[side]) * airplane_basis(side)
	return Transform3D(basis.orthonormalized(), hand)


## Sets both arms to one pose (convenience for tests and the puppet).
func set_arms(p_dihedral: float, p_sweep: float = 0.0, p_twist: float = 0.0, p_elbow: float = 0.0) -> void:
	for i in 2:
		dihedral[i] = p_dihedral
		sweep[i] = p_sweep
		twist[i] = p_twist
		elbow[i] = p_elbow


## The pose people hold when told "spread your wings, hands flat": arms
## straight, about 5° below level (FLIGHT_SPEC §5.10), no twist.
func spread_pose() -> void:
	set_arms(deg_to_rad(-5.0))
