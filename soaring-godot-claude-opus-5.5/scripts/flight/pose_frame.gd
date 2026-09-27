class_name PoseFrame
extends RefCounted
## One tick of the player's body in TRACKING space, REAL metres (never
## world_scale'd): XROrigin3D-local with the scale removed (FLIGHT_SPEC §3.1).
## Hands are the OpenXR GRIP pose (§3.2): -Z through the fist tube, +X the
## palm normal (out of the left palm, into the right).

const BTN_MENU := 1
const BTN_AX := 2
const BTN_BY := 4
const BTN_STICK_L := 8
const BTN_STICK_R := 16

var t := 0.0
var head := Transform3D.IDENTITY
var left := Transform3D.IDENTITY
var right := Transform3D.IDENTITY
var head_valid := false
var left_valid := false
var right_valid := false
## Analog 0..1 (x = left, y = right).
var grip := Vector2.ZERO
var trigger := Vector2.ZERO
var buttons := 0
## Set by a source when this tick is a discontinuity (recenter, respawn):
## WingInput and PlayerBird then treat head motion as zero for the tick.
var discontinuity := false
## Seconds the poses advanced since the previous sample, when the source
## knows it (fix round 5): the XR server updates the tracked nodes once per
## engine frame, so a frame hitch runs several physics ticks on one pose and
## then jumps by the whole hitch. 0 = the same poses as last tick; -1 =
## unknown (every tick is a new sample one tick apart: synthetic sources).
var pose_dt := -1.0


func copy_from(o: PoseFrame) -> void:
	t = o.t
	head = o.head
	left = o.left
	right = o.right
	head_valid = o.head_valid
	left_valid = o.left_valid
	right_valid = o.right_valid
	grip = o.grip
	trigger = o.trigger
	buttons = o.buttons
	discontinuity = o.discontinuity
	pose_dt = o.pose_dt


func hand(side: int) -> Transform3D:
	return left if side == 0 else right
