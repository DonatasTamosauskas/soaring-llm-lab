class_name UIMockPlayer
extends Bird
## Stand-in for PlayerBird in UI tests and the UI dev scene (flight is built
## in parallel). Exposes the telemetry() contract with scriptable values and
## records the calls the UI must never make (e.g. disabling controls).

var tel := {
	"airspeed": 8.0, "groundspeed": 8.0, "vertical_speed": 0.0, "altitude_agl": 20.0,
	"aoa": 0.08, "bank": 0.0, "stalled": false, "flapping": 0.0, "wing_extension": 0.0,
	"tucked": false, "perched": false, "in_updraft": 0.0, "g_load": 1.0, "lift": 0.3, "drag": 0.05,
	"pitch_input": 0.0,
	# PlayerBird's telemetry extra: the torso's yaw in the rig's (tracking)
	# frame, radians, + = left. The HUD's centre line (UIRoot.body_yaw);
	# tests turn the player's body with it.
	"body_yaw": 0.0,
}
var controls_calls: Array[bool] = []
var head_offset := Vector3.ZERO


func _init() -> void:
	species = &"sparrow"
	mass = SizeRules.SPECIES[2]["mass"]


func is_player() -> bool:
	return true


func telemetry() -> Dictionary:
	return tel


func get_body_position() -> Vector3:
	return global_position + head_offset


func set_controls_enabled(on: bool) -> void:
	controls_calls.append(on)


func respawn(xform: Transform3D) -> void:
	global_transform = xform
