class_name XRPoseSource
extends PoseSource
## Headset / simulator poses (FLIGHT_SPEC §3.1): the XRCamera3D and the grip
## XRController3D transforms local to the XROrigin3D. world_scale scales
## node ORIGINS only (bases and raw tracker poses are unscaled; QUEST.md §2),
## so each origin is divided by world_scale to get real metres. Node
## transforms include the reference frame, so recenter is handled. Hand
## velocity is never taken from the tracker (the simulator reports zero):
## WingInput differentiates positions itself.

var origin: XROrigin3D
var camera: XRCamera3D
var left: XRController3D
var right: XRController3D
## Tests only: treat the nodes as tracked (headless runs have no trackers).
var assume_tracked := false
## Stamp each sample with the real time the poses advanced (fix round 5;
## PoseFrame.pose_dt). The XR server writes the tracked nodes once per
## engine frame, before that frame's physics ticks: a frame hitch (a slow
## render, a shader compile) runs several physics ticks on one pose and the
## first of them sees the pose jump by the whole hitch. The first sample of
## each engine frame gets the wall-clock time since the previous engine
## frame's first sample; the repeats in the same frame get 0. On for the
## game's and the lab's XR sources; tests that move the nodes by hand
## within one engine frame leave it off (or inject `clock`).
var frame_timing := false
## Tests: () -> Vector2(engine frame index, seconds). Empty = the engine's
## process frame counter and Time.get_ticks_usec().
var clock := Callable()
var _last_frame := -1
var _last_time := 0.0
var _prev_head := Transform3D.IDENTITY
var _prev_left := Transform3D.IDENTITY
var _prev_right := Transform3D.IDENTITY


func _init(p_origin: XROrigin3D = null, p_camera: XRCamera3D = null, p_left: XRController3D = null, p_right: XRController3D = null) -> void:
	origin = p_origin
	camera = p_camera
	left = p_left
	right = p_right


func sample(out: PoseFrame, _dt: float) -> void:
	out.discontinuity = false
	if origin == null or not is_instance_valid(origin):
		out.head_valid = false
		out.left_valid = false
		out.right_valid = false
		return
	var inv := 1.0 / maxf(origin.world_scale, 1e-4)
	out.t += _dt
	if camera != null and is_instance_valid(camera):
		var h := camera.transform
		out.head = Transform3D(h.basis, h.origin * inv)
		out.head_valid = assume_tracked or _head_tracked()
	else:
		out.head_valid = false
	for i in 2:
		var c := left if i == 0 else right
		if c == null or not is_instance_valid(c):
			if i == 0:
				out.left_valid = false
			else:
				out.right_valid = false
			continue
		var tr := c.transform
		var t2 := Transform3D(tr.basis, tr.origin * inv)
		var ok := assume_tracked or _tracked(c)
		if i == 0:
			out.left = t2
			out.left_valid = ok
			out.grip.x = c.get_float(&"grip")
			out.trigger.x = c.get_float(&"trigger")
		else:
			out.right = t2
			out.right_valid = ok
			out.grip.y = c.get_float(&"grip")
			out.trigger.y = c.get_float(&"trigger")
	var b := 0
	if left != null and is_instance_valid(left):
		if left.is_button_pressed(&"menu_button"):
			b |= PoseFrame.BTN_MENU
		if left.is_button_pressed(&"ax_button"):
			b |= PoseFrame.BTN_AX
		if left.is_button_pressed(&"by_button"):
			b |= PoseFrame.BTN_BY
		if left.is_button_pressed(&"primary_click"):
			b |= PoseFrame.BTN_STICK_L
	if right != null and is_instance_valid(right):
		if right.is_button_pressed(&"ax_button"):
			b |= PoseFrame.BTN_AX
		if right.is_button_pressed(&"by_button"):
			b |= PoseFrame.BTN_BY
		if right.is_button_pressed(&"primary_click"):
			b |= PoseFrame.BTN_STICK_R
	out.buttons = b
	out.pose_dt = _pose_interval(out, _dt) if frame_timing else -1.0


func reset() -> void:
	_last_frame = -1


## PoseFrame.pose_dt for this sample (see frame_timing).
func _pose_interval(out: PoseFrame, dt: float) -> float:
	var now := clock.call() as Vector2 if clock.is_valid() else \
		Vector2(float(Engine.get_process_frames()), Time.get_ticks_usec() / 1e6)
	var pd := -1.0
	if int(now.x) != _last_frame:
		if _last_frame >= 0:
			pd = clampf(now.y - _last_time, 0.25 * dt, 0.25)
		_last_frame = int(now.x)
		_last_time = now.y
	elif out.head == _prev_head and out.left == _prev_left and out.right == _prev_right:
		pd = 0.0   # the same engine frame's poses again
	_prev_head = out.head
	_prev_left = out.left
	_prev_right = out.right
	return pd


## XRCamera3D is not an XRNode3D: read the head tracker directly.
static func _head_tracked() -> bool:
	var t := XRServer.get_tracker(&"head") as XRPositionalTracker
	if t == null:
		return false
	var p := t.get_pose(&"default")
	return p != null and p.has_tracking_data and p.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE


static func _tracked(n: XRNode3D) -> bool:
	if not n.get_has_tracking_data():
		return false
	var p := n.get_pose()
	if p == null:
		return false
	return p.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE
