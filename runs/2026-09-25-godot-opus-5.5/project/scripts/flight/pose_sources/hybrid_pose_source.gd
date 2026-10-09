class_name HybridPoseSource
extends PoseSource
## Real head from XR, synthetic hands (FLIGHT_SPEC §3.1): the Meta XR
## Simulator's controllers are fixed in place, so this is the only way to
## fly there through the real XR head path. The synthetic body is carried
## along with the real head (translation only, via the neck point), so
## looking around in the headset never moves the wings.

var xr: XRPoseSource
var hands_source: PoseSource
var _synth := PoseFrame.new()


func _init(p_xr: XRPoseSource = null, p_hands: PoseSource = null) -> void:
	xr = p_xr
	hands_source = p_hands


func sample(out: PoseFrame, dt: float) -> void:
	if xr != null:
		xr.sample(out, dt)
	if hands_source == null:
		return
	hands_source.sample(_synth, dt)
	var real_neck := out.head.origin + out.head.basis * Vector3(0.0, -0.08, 0.09)
	var synth_neck := _synth.head.origin + _synth.head.basis * Vector3(0.0, -0.08, 0.09)
	var off := real_neck - synth_neck if out.head_valid else Vector3.ZERO
	if not out.head_valid:
		out.head = _synth.head
		out.head_valid = true
	out.left = Transform3D(_synth.left.basis, _synth.left.origin + off)
	out.right = Transform3D(_synth.right.basis, _synth.right.origin + off)
	out.left_valid = _synth.left_valid
	out.right_valid = _synth.right_valid
	out.grip = _synth.grip
	# The wings are the synthetic hands, a new sample every tick.
	out.pose_dt = -1.0


## Synthetic hands, real head: PlayerBird writes the hands into the
## controller nodes so the wings and screenshots show them.
func drives_nodes() -> bool:
	return true


func reset() -> void:
	if hands_source != null:
		hands_source.reset()


func handle_input(event: InputEvent) -> void:
	if hands_source != null:
		hands_source.handle_input(event)
