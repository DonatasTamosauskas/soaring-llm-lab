class_name WingCalibration
extends Resource
## How this player's body maps onto a bird's wings (FLIGHT_SPEC §5.11).
## Owned by flight (the fields WingInput reads); WingInput captures it
## automatically (§5.10) and the VR area's calibration flow may fill it too.
## Persisted as Settings["wing_calibration"] through to_dict()/from_dict().
## All lengths are real-world metres in tracking space (before world_scale).
##
## Contract change 2026-09-25: the old neutral_roll_*/neutral_pitch_* fields
## are replaced by full neutral bases plus calibrated forearm and chord axes
## (a single roll angle cannot express a neutral orientation); arm_span is
## now grip-to-grip (default 1.50 m).

## Measured "airplane arms, palms down" grip bases (FLIGHT_SPEC §3.2).
## IDENTITY is NOT palms-down.
const AIRPLANE_R := Basis(Vector3(0, 1, 0), Vector3(-0.8660254, 0, -0.5), Vector3(-0.5, 0, 0.8660254))
const AIRPLANE_L := Basis(Vector3(0, -1, 0), Vector3(0.8660254, 0, -0.5), Vector3(0.5, 0, 0.8660254))
const DEFAULT_FOREARM := Vector3(0, -0.8660254, -0.5)
const DEFAULT_CHORD := Vector3(0, 0.5, -0.8660254)

## Grip-to-grip distance at full spread.
@export var arm_span := 1.50
@export var shoulder_width := 0.345
## Shoulder joints below the eyes.
@export var shoulder_drop := 0.24
## Controller basis in the body frame at neutral (flat wings).
@export var neutral_left := AIRPLANE_L
@export var neutral_right := AIRPLANE_R
## Outward forearm axis in the grip frame.
@export var forearm_axis_left := DEFAULT_FOREARM
@export var forearm_axis_right := DEFAULT_FOREARM
## Chord (leading-edge) axis in the grip frame.
@export var chord_axis_left := DEFAULT_CHORD
@export var chord_axis_right := DEFAULT_CHORD
## R_HI: reach (fraction of arm length) that counts as fully spread.
@export var glide_reach := 0.62
## Arm elevation below which the wing folds (rad, -62 deg).
@export var fold_elevation := -1.082
## omega_full, rad/s: stroke rate that gives full flap effort.
@export var stroke_full_rate := 4.5
## A_FULL, rad: upstroke arc that earns full credit.
@export var stroke_full_arc := 0.611
@export var seated := false
## True once a real capture (not defaults) happened.
@export var calibrated := false


func arm_length() -> float:
	return (arm_span - shoulder_width) * 0.5


func neutral(side: int) -> Basis:
	return neutral_left if side == 0 else neutral_right


func forearm_axis(side: int) -> Vector3:
	return forearm_axis_left if side == 0 else forearm_axis_right


func chord_axis(side: int) -> Vector3:
	return chord_axis_left if side == 0 else chord_axis_right


const _SCALARS := ["arm_span", "shoulder_width", "shoulder_drop", "glide_reach", "fold_elevation",
	"stroke_full_rate", "stroke_full_arc", "seated", "calibrated"]


## JSON-safe dictionary (bases as 9 floats x.x x.y x.z y.x ..., vectors as 3),
## the same layout the VR area's calibrator writes.
func to_dict() -> Dictionary:
	var d := {"version": 1}
	for f in _SCALARS:
		d[f] = get(f)
	for f in ["neutral_left", "neutral_right"]:
		var b: Basis = get(f)
		d[f] = [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z]
	for f in ["forearm_axis_left", "forearm_axis_right", "chord_axis_left", "chord_axis_right"]:
		var v: Vector3 = get(f)
		d[f] = [v.x, v.y, v.z]
	return d


## Reads what to_dict wrote (or VR's calibrator, or native Basis / Vector3
## values). Every value is checked the same way whatever its form (fix
## round 4, VR's request: a native Basis skipped the finite / determinant
## check the flat-array path had): a non-finite scalar, a singular or
## non-finite basis, a non-finite or near-zero axis is ignored.
func from_dict(d: Dictionary) -> void:
	for f in _SCALARS:
		if d.has(f):
			if typeof(get(f)) == TYPE_BOOL:
				set(f, bool(d[f]))
			elif (d[f] is float or d[f] is int) and is_finite(float(d[f])):
				set(f, float(d[f]))
	for f in ["neutral_left", "neutral_right"]:
		if d.has(f):
			var a: Variant = d[f]
			var b := Basis()
			var ok := false
			if a is Basis:
				b = a
				ok = true
			elif (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) and a.size() == 9:
				b = Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8]))
				ok = true
			if ok and FlightMath.bfinite(b) and absf(b.determinant()) > 0.5:
				set(f, b.orthonormalized())
	for f in ["forearm_axis_left", "forearm_axis_right", "chord_axis_left", "chord_axis_right"]:
		if d.has(f):
			var a2: Variant = d[f]
			var v := Vector3.ZERO
			if a2 is Vector3:
				v = a2
			elif (a2 is Array or a2 is PackedFloat32Array or a2 is PackedFloat64Array) and a2.size() == 3:
				v = Vector3(a2[0], a2[1], a2[2])
			if FlightMath.vfinite(v) and v.length() > 0.1:
				set(f, v.normalized())
	arm_span = clampf(arm_span, 1.0, 2.2)
	shoulder_drop = clampf(shoulder_drop, 0.15, 0.35)
	glide_reach = clampf(glide_reach, 0.5, 0.75)
	stroke_full_rate = clampf(stroke_full_rate, 3.0, 6.0)
	stroke_full_arc = clampf(stroke_full_arc, deg_to_rad(20.0), deg_to_rad(45.0))
