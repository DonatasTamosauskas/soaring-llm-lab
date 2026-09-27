extends Bird
## DEV/TEST-ONLY stand-in for the flight area's PlayerBird: a Bird with
## is_player() == true, settable telemetry and an optional wing_state, so
## the VR area's features (haptics polling, wing tint and extension, world
## scale) can be exercised without the flight area's in-progress rig.

var telemetry_data := {}
## Anything with ext_l / ext_r (a WingState look-alike), or null.
var wing_state_obj: Object = null
## PlayerBird.mode_name() look-alike ("spawning", "flying", "perched",
## "grounded", "stunned", "caught"): gates the automatic calibration.
var mode_label := "perched"
## PlayerBird.yaw_flagged look-alike: a deliberate one-tick yaw step.
var yaw_flagged := false
## A WingCalibration look-alike when a test gives one (else null).
var calibration: Resource = null
## A WingInput look-alike (with its own `calibration`) when a test gives
## one: PlayerBird.wing_input.
var wing_input: Object = null
## PlayerBird.auto_calibrate look-alike: VR's calibration switches it off
## while it owns the automatic capture.
var auto_calibrate := true


func mode_name() -> String:
	return mode_label


func is_player() -> bool:
	return true


func telemetry() -> Dictionary:
	return telemetry_data


func wing_state() -> Object:
	return wing_state_obj


func get_body_position() -> Vector3:
	var cam := find_child("XRCamera3D", true, false) as Node3D
	return cam.global_position if cam != null else global_position
