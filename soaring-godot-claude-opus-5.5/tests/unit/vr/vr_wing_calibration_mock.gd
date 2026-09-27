extends Resource
## TEST-ONLY look-alike of the flight area's WingCalibration with exactly the
## FLIGHT_SPEC §5.11 fields. The VR suite must not depend on flight's
## in-progress class (a mid-edit parse error there would stop this suite
## loading); the production code is duck-typed, so the same fields are all
## it needs. No to_dict(): read_from() then takes the field-by-field path.

@export var arm_span := 1.50
@export var shoulder_width := 0.345
@export var shoulder_drop := 0.24
@export var neutral_left := Basis(Vector3(0, -1, 0), Vector3(0.8660254, 0, -0.5), Vector3(0.5, 0, 0.8660254))
@export var neutral_right := Basis(Vector3(0, 1, 0), Vector3(-0.8660254, 0, -0.5), Vector3(-0.5, 0, 0.8660254))
@export var forearm_axis_left := Vector3(0, -0.8660254, -0.5)
@export var forearm_axis_right := Vector3(0, -0.8660254, -0.5)
@export var chord_axis_left := Vector3(0, 0.5, -0.8660254)
@export var chord_axis_right := Vector3(0, 0.5, -0.8660254)
@export var glide_reach := 0.62
@export var fold_elevation := -1.082
@export var stroke_full_rate := 4.5
@export var stroke_full_arc := 0.611
@export var seated := false
@export var calibrated := false
