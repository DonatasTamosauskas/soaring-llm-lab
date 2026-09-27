class_name UIXRPointerSource
extends UIPointerSource
## Pointer input from a real (or simulated) OpenXR controller.
##
## Reads an XRController3D bound to the *aim* pose under the player's
## XROrigin3D: grip is where the fist points, aim is where a person thinks
## they are pointing. The player rig already has one per hand (flight's
## LeftAim / RightAim, "the UI laser source"); that one is used. Only a rig
## without one gets a UIAim_<hand> added (and freed again on release).
## XRController3D already applies world_scale to the tracked position, so
## the ray lives in world space.

var controller: XRController3D
## True if this source added `controller` (and so frees it on release).
var owns_controller := false


func _init(p_hand: StringName, origin: Node3D) -> void:
	super(p_hand)
	controller = find_aim(origin, p_hand)
	if controller:
		return
	controller = XRController3D.new()
	controller.name = "UIAim_%s" % String(p_hand)
	controller.tracker = p_hand
	controller.pose = &"aim"
	# Everything under the rig keeps running while paused (ARCHITECTURE 7.6).
	controller.process_mode = Node.PROCESS_MODE_ALWAYS
	owns_controller = true
	origin.add_child(controller)


## The rig's own aim controller for `hand` (a direct child XRController3D on
## that tracker with the aim pose, not one a UI source added), or null.
static func find_aim(origin: Node3D, hand: StringName) -> XRController3D:
	if origin == null:
		return null
	for c in origin.get_children():
		var x := c as XRController3D
		if x and x.tracker == hand and x.pose == &"aim" and not x.is_queued_for_deletion() \
				and not String(x.name).begins_with("UIAim_"):
			return x
	return null


## Free the aim controller this source added under the rig, so replacing
## sources (attach_rig on a new rig, scripted sources) leaves no orphans. The
## rig's own controllers are left alone.
func release() -> void:
	if owns_controller and is_instance_valid(controller):
		if controller.get_parent():
			controller.get_parent().remove_child(controller)
		controller.queue_free()
	controller = null
	owns_controller = false


func aim_transform() -> Transform3D:
	return controller.global_transform if is_instance_valid(controller) and controller.is_inside_tree() else aim


func trigger() -> float:
	if trigger_override >= 0.0:
		return trigger_override
	if not is_instance_valid(controller):
		return 0.0
	return maxf(controller.get_float(&"trigger"), 1.0 if controller.is_button_pressed(&"trigger_click") else 0.0)


func is_tracked() -> bool:
	return is_instance_valid(controller) and controller.get_is_active() and controller.get_has_tracking_data()


func menu_pressed() -> bool:
	return is_instance_valid(controller) and controller.is_button_pressed(&"menu_button")


func back_pressed() -> bool:
	return is_instance_valid(controller) and controller.is_button_pressed(&"by_button")


## Real pulses only: no test log on hardware (it would grow all session).
func haptic(amplitude: float, seconds: float) -> void:
	if is_instance_valid(controller) and amplitude > 0.0:
		controller.trigger_haptic_pulse(&"haptic", 0.0, amplitude, seconds, 0.0)
