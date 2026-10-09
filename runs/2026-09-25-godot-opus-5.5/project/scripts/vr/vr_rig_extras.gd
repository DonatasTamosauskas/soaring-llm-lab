class_name VRRigExtras
extends Node3D
## Everything the VR area adds to the player's rig, as one node that
## integration instances under the XROrigin3D (scenes/vr/vr_rig_extras.tscn):
##   Calibration      VRCalibration  (poses -> WingCalibrator, flows, persistence)
##   Wings            FirstPersonWings (one draw call, under the origin)
##   Vignette         ComfortVignette (moved under the XRCamera3D at runtime)
##   WorldScale       WorldScaleDriver (growth + camera near plane)
## It finds the rig itself: its parent if that is an XROrigin3D, else the
## first node in group "player_rig" (retrying until one exists), so it can
## also live anywhere in a dev scene. The flight area owns the player scene;
## nothing here edits it: the extras attach at runtime.
##
## It also enforces the pause rule (ARCHITECTURE §4, §7.6): the XROrigin3D
## and everything under it process while paused, so head tracking, hands,
## wings and UI rays never freeze.

signal rig_attached(origin: XROrigin3D)

@export var enable_wings := true
@export var enable_vignette := true
@export var enable_world_scale := true
@export var enable_calibration := true

var origin: XROrigin3D
var camera: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D
var calibration: VRCalibration
var wings: FirstPersonWings
var vignette: ComfortVignette
var world_scale_driver: WorldScaleDriver
## Process-mode fixes applied under the origin (for logs/tests).
var process_fixes := 0

var _retry := 0.5
## Attached to a rig that is still around (see _process).
var _attached := false
## _ready has run: a later _enter_tree is a return (the rig, or the extras
## alone, left the tree and came back).
var _set_up := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	calibration = $Calibration as VRCalibration if has_node(^"Calibration") else null
	world_scale_driver = $WorldScale as WorldScaleDriver if has_node(^"WorldScale") else null
	wings = $Wings as FirstPersonWings if has_node(^"Wings") else null
	vignette = $Vignette as ComfortVignette if has_node(^"Vignette") else null
	if calibration == null:
		calibration = VRCalibration.new()
		calibration.name = "Calibration"
		add_child(calibration)
	if world_scale_driver == null:
		world_scale_driver = WorldScaleDriver.new()
		world_scale_driver.name = "WorldScale"
		add_child(world_scale_driver)
	_ensure_parts()
	calibration.process_mode = Node.PROCESS_MODE_ALWAYS
	# Off: no VR calibration at all, and flight keeps its own capture.
	calibration.set_process(enable_calibration)
	world_scale_driver.enabled = enable_world_scale
	wings.visible = enable_wings
	get_tree().node_added.connect(_on_node_added)
	_set_up = true
	# Deferred: the rig may still be setting up its children (adding to a
	# parent during its ready propagation fails).
	try_attach.call_deferred()


## Back in the tree after leaving it (fix round 5, both verifiers: the rig
## removed and added again, or reparented, used to free the wings and the
## comfort vignette for the rest of the session, silently, and to stop
## correcting pausable nodes added under the rig). _ready does not run
## again, so the tree hook, the parts and the wiring come back here.
func _enter_tree() -> void:
	if not _set_up:
		return
	var t := get_tree()
	if not t.node_added.is_connected(_on_node_added):
		t.node_added.connect(_on_node_added)
	_set_parts_active(true)
	try_attach.call_deferred()


func _process(delta: float) -> void:
	if origin == null or not is_instance_valid(origin) or not origin.is_inside_tree():
		# The rig just went (a respawn): look for its successor at once, then
		# every 0.5 s (a new rig entering the tree is also caught by
		# _on_node_added).
		# (A freed origin compares equal to null: the flag says we had one.)
		var lost := _attached
		_attached = false
		origin = null
		_retry -= delta
		if lost or _retry <= 0.0:
			_retry = 0.5
			try_attach()


## The wings and the vignette live on the rig once attached, so a rig that
## is deleted takes them along. With the extras placed elsewhere (the
## group lookup) the next rig must get new ones (fix round 6, engineering
## verifier: a respawn that re-instanced the player assigned the freed
## wings, stopped try_attach with a SCRIPT ERROR before the world-scale
## driver was wired, and left the new rig without wings, vignette or
## growth). Called before any use of either part.
func _ensure_parts() -> void:
	if wings == null or not is_instance_valid(wings) or wings.is_queued_for_deletion():
		wings = FirstPersonWings.new()
		wings.name = "Wings"
		wings.visible = enable_wings
		add_child(wings)
	if vignette == null or not is_instance_valid(vignette) or vignette.is_queued_for_deletion():
		vignette = ComfortVignette.new()
		vignette.name = "Vignette"
		add_child(vignette)


## Finds the rig and wires every component to it. Returns true when attached.
func try_attach() -> bool:
	var o: XROrigin3D = null
	if get_parent() is XROrigin3D:
		o = get_parent()
	elif is_inside_tree():
		# The first live rig: a player being deleted this frame (its
		# queue_free marks the player, not the origin under it) is skipped.
		for n in get_tree().get_nodes_in_group(&"player_rig"):
			if n is XROrigin3D and not _doomed(n):
				o = n
				break
	if o == null or _doomed(o):
		return false
	_ensure_parts()
	origin = o
	_attached = true
	camera = _find_camera(o)
	left_hand = _find_hand(o, &"left_hand")
	right_hand = _find_hand(o, &"right_hand")
	enforce_process_modes()

	calibration.origin = o
	calibration.camera = camera
	calibration.hands = [left_hand, right_hand]
	calibration.wings = wings
	calibration.process_mode = Node.PROCESS_MODE_ALWAYS
	if enable_calibration:
		# VR's calibration is the one the player flies: flight's own
		# automatic capture is switched off from the first frame.
		calibration.claim_auto_capture()

	world_scale_driver.origin = o
	world_scale_driver.camera = camera
	world_scale_driver.calibration = calibration

	# Wings live in origin space: identity transform under the origin.
	if wings.get_parent() != o:
		wings.reparent(o, false)
	wings.transform = Transform3D.IDENTITY
	wings.origin = o
	wings.calibrator = calibration.calibrator
	wings.visible = enable_wings

	if enable_vignette and camera != null:
		if vignette.get_parent() != camera:
			vignette.reparent(camera, false)
		vignette.transform = Transform3D.IDENTITY
		vignette.origin = o
	vignette.set_process(enable_vignette)
	vignette.set_physics_process(enable_vignette)
	print("[vr] rig extras attached to %s (camera %s, hands %s / %s)" % [o.get_path(),
		camera.name if camera else "-", left_hand.name if left_hand else "-", right_hand.name if right_hand else "-"])
	rig_attached.emit(o)
	return true


## The node or one of its ancestors is queued for deletion.
static func _doomed(n: Node) -> bool:
	while n != null:
		if n.is_queued_for_deletion():
			return true
		n = n.get_parent()
	return false


func _find_camera(o: XROrigin3D) -> XRCamera3D:
	var found := o.find_children("*", "XRCamera3D", true, false)
	return found.front() as XRCamera3D if not found.is_empty() else null


## The grip-pose controller for a hand; UI's aim-pose pointers are skipped.
## Creates one if the rig has none (the wings need the grip pose).
func _find_hand(o: XROrigin3D, tracker: StringName) -> XRController3D:
	var fallback: XRController3D = null
	for c in o.find_children("*", "XRController3D", true, false):
		var xc := c as XRController3D
		if xc.tracker != tracker:
			continue
		if xc.pose == &"grip":
			return xc
		if fallback == null and xc.pose != &"aim":
			fallback = xc
	if fallback != null:
		return fallback
	var n := XRController3D.new()
	n.name = "VRGrip_" + ("L" if tracker == &"left_hand" else "R")
	n.tracker = tracker
	n.pose = &"grip"
	o.add_child(n)
	return n


## The origin and its whole subtree must keep processing while paused.
func enforce_process_modes() -> void:
	if origin == null:
		return
	if origin.process_mode != Node.PROCESS_MODE_ALWAYS:
		origin.process_mode = Node.PROCESS_MODE_ALWAYS
		process_fixes += 1
	for n in origin.find_children("*", "", true, false):
		_fix_mode(n)


func _fix_mode(n: Node) -> void:
	if n.process_mode == Node.PROCESS_MODE_PAUSABLE or n.process_mode == Node.PROCESS_MODE_WHEN_PAUSED:
		push_warning("[vr] %s under the XR rig was %s; set to ALWAYS (head and hands must track while paused)" % [n.get_path(),
			"PAUSABLE" if n.process_mode == Node.PROCESS_MODE_PAUSABLE else "WHEN_PAUSED"])
		n.process_mode = Node.PROCESS_MODE_ALWAYS
		process_fixes += 1


func _on_node_added(n: Node) -> void:
	if origin != null and is_instance_valid(origin) and origin.is_inside_tree():
		if origin.is_ancestor_of(n):
			_fix_mode(n)
	elif n is XROrigin3D and n.is_in_group(&"player_rig"):
		# A rig arrived while the extras had none (the player respawned
		# after the old rig was deleted): attach as soon as its children
		# are in (deferred), not at the next 0.5 s retry.
		try_attach.call_deferred()


## Leaving the tree is not being deleted: the rig may only be moving
## (remove_child / add_child, reparent at a respawn or a scene rebuild).
## The parts that live on the rig are parked (hidden, not processing) until
## the extras come back (_enter_tree); they are freed only with the extras
## (NOTIFICATION_PREDELETE).
func _exit_tree() -> void:
	if get_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	_set_parts_active(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# The wings and the vignette were moved onto the rig: they go with
		# the extras (a node the rig's own deletion already freed is skipped).
		for n in [wings, vignette]:
			if n != null and is_instance_valid(n) and not is_ancestor_of(n) and not n.is_queued_for_deletion():
				n.queue_free()


## Parks or restores the parts that live on the rig. Restored, the
## vignette forgets the motion from before (the rig may have moved while
## away: that is not flight).
func _set_parts_active(on: bool) -> void:
	if wings != null and is_instance_valid(wings):
		wings.visible = on and enable_wings
		wings.set_process(on)
	if vignette != null and is_instance_valid(vignette):
		vignette.set_process(on and enable_vignette)
		vignette.set_physics_process(on and enable_vignette)
		if on:
			vignette.reset_motion()
		else:
			vignette.visible = false
