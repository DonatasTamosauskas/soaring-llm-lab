class_name VRPosePuppet
extends Node
## Moves the rig's XRCamera3D and grip XRController3Ds from a VRHumanPose:
## the desktop dev scene, screenshots, and the simulator harness's scripted
## pose override (the simulated controllers are fixed in place).
##
## Writes node transforms in origin space (positions x world_scale, like the
## XR runtime does), after the XR nodes updated this frame (process_priority
## 40) and before the calibration / wings read them (50 / 100). With
## drive_head off (in a headset) the head stays real and the arms are placed
## on a body fitted under it: a "hybrid" pose.

const GESTURES: Array[StringName] = [&"spread", &"glide", &"tuck", &"flap", &"bank_left", &"bank_right",
	&"twist_up", &"twist_down", &"superman", &"cycle", &"wings_forward", &"held", &"spread_high"]

var human := VRHumanPose.for_span(1.5)
var origin: XROrigin3D
var camera: Node3D
var hands: Array[Node3D] = [null, null]
@export var drive_head := true
@export var gesture: StringName = &"glide"
## Gesture time scale (1 = real time).
@export var speed := 1.0
## Extra forward sweep added to every gesture (rad): brings the wings in
## front of a real head for mirror screenshots.
var extra_sweep := 0.0
## Extra head look for screenshots (rad, relative to the torso).
var look_yaw := 0.0
var look_pitch := 0.0
## Hybrid pose (drive_head off): the fitted body's torso turned this far
## from the real head's gaze (rad, + = left), as when the player looks over
## a shoulder at a spread wing. The simulator's head cannot be turned
## without persisted settings, so the body turns under it instead.
var torso_yaw_offset := 0.0
var t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 40


func _process(dt: float) -> void:
	t += dt * speed
	pose_for(gesture, t)
	if extra_sweep != 0.0:
		human.sweep = [human.sweep[0] + extra_sweep, human.sweep[1] + extra_sweep]
	apply()


## Sets the human's arms for a gesture at time `time`.
func pose_for(g: StringName, time: float) -> void:
	human.head_yaw = look_yaw
	human.head_pitch = look_pitch
	human.head_roll = 0.0
	match g:
		&"spread":
			human.set_arms(deg_to_rad(-5.0))
		&"glide":
			human.set_arms(deg_to_rad(-28.0), 0.0, 0.0, deg_to_rad(22.0))
		&"tuck":
			human.set_arms(deg_to_rad(-35.0), deg_to_rad(-10.0), 0.0, deg_to_rad(150.0))
		&"wings_forward":
			# Arms reaching forward and out, as when flaring to land: both
			# wings in front of the eyes (screenshots with a real head).
			human.set_arms(deg_to_rad(-4.0), deg_to_rad(48.0), 0.0, deg_to_rad(20.0))
		&"superman":
			human.set_arms(deg_to_rad(-10.0), deg_to_rad(80.0), 0.0, deg_to_rad(10.0))
		&"spread_high":
			# Spread with the arms raised a little: the wing at eye level
			# (screenshots looking along a wing).
			human.set_arms(deg_to_rad(12.0), 0.0, 0.0, deg_to_rad(8.0))
		&"held":
			# Relaxed hands holding the controllers in front of the hips,
			# pointing forward (the Meta XR Simulator's fixed controllers).
			human.set_arms(deg_to_rad(-68.0), deg_to_rad(8.0), 0.0, deg_to_rad(95.0))
		&"flap":
			# Downstroke faster than the upstroke, like a bird's.
			var ph := fposmod(time * 0.9, 1.0)
			var d := -cos(PI * ph / 0.4) if ph < 0.4 else -cos(PI + PI * (ph - 0.4) / 0.6)
			human.set_arms(deg_to_rad(-10.0 - 40.0 * d), 0.0, deg_to_rad(-12.0), deg_to_rad(15.0))
		&"bank_left":
			human.set_arms(0.0, 0.0, 0.0, deg_to_rad(15.0))
			human.dihedral = [deg_to_rad(-20.0), deg_to_rad(12.0)]
			human.twist = [deg_to_rad(-18.0), deg_to_rad(18.0)]
		&"bank_right":
			human.set_arms(0.0, 0.0, 0.0, deg_to_rad(15.0))
			human.dihedral = [deg_to_rad(12.0), deg_to_rad(-20.0)]
			human.twist = [deg_to_rad(18.0), deg_to_rad(-18.0)]
		&"twist_up":
			human.set_arms(deg_to_rad(-12.0), 0.0, deg_to_rad(30.0), deg_to_rad(15.0))
		&"twist_down":
			human.set_arms(deg_to_rad(-12.0), 0.0, deg_to_rad(-25.0), deg_to_rad(15.0))
		&"cycle":
			var seq: Array[StringName] = [&"spread", &"glide", &"flap", &"bank_left", &"bank_right", &"tuck", &"twist_up"]
			pose_for(seq[int(time / 3.0) % seq.size()], time)


## Writes the pose into the rig nodes.
func apply() -> void:
	if origin == null or not is_instance_valid(origin):
		return
	var ws := origin.world_scale
	if not drive_head and camera != null:
		_fit_to_head(Transform3D(camera.transform.basis, camera.transform.origin / maxf(ws, 1e-4)))
	elif camera != null:
		var h := human.head_transform()
		camera.transform = Transform3D(h.basis, h.origin * ws)
	for i in 2:
		var n := hands[i]
		if n == null or not is_instance_valid(n):
			continue
		var x := human.hand_transform(i)
		n.transform = Transform3D(x.basis, x.origin * ws)


## Places the synthetic body under a real (tracked) head.
func _fit_to_head(h: Transform3D) -> void:
	human.torso_yaw = VRMath.yaw_of(VRMath.head_forward(h.basis)) + torso_yaw_offset
	human.head_yaw = 0.0
	human.head_pitch = 0.0
	human.eye_height = h.origin.y
	human.room_offset = Vector3(h.origin.x, 0.0, h.origin.z)
