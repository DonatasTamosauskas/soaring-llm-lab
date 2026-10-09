extends TestCase
## V8: pausing keeps head tracking and hands alive. With the game paused
## (Game.PAUSED -> SceneTree.paused) the XROrigin3D and its whole subtree
## still process, the wings keep following the controllers, and a pausable
## node added under the rig is corrected to PROCESS_MODE_ALWAYS.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")

var rig: Dictionary


func before_all() -> void:
	rig = Env.build_rig(self, Vector3(0, 3, 0), MemoryStore.new(), true, false)
	(rig["puppet"] as VRPosePuppet).gesture = &"spread"
	await wait_frames(4)


func after_all() -> void:
	# world_scale is global XRServer state: leave it as found.
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	(rig["player"] as Node).queue_free()
	(rig["puppet"] as Node).queue_free()


func test_rig_subtree_processes_while_paused() -> void:
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(get_tree().paused, "game paused")
	var origin: XROrigin3D = rig["origin"]
	check(origin.can_process(), "XROrigin3D processes while paused")
	var count := 0
	for n in origin.find_children("*", "", true, false):
		count += 1
		check(n.can_process(), "%s processes while paused" % n.name)
	gt(float(count), 5.0, "camera, hands, wings, vignette and extras all checked")
	check(not (rig["player"] as Node).can_process(), "the flight body itself is pausable (sanity)")
	check((rig["puppet"] as Node).can_process(), "the pose driver (stand-in for the XR runtime) runs")
	# The wings follow a moving hand while paused.
	var wings := (rig["extras"] as VRRigExtras).wings
	await wait_frames(2)
	var tip0 := wings.wingtip(1)
	var puppet := rig["puppet"] as VRPosePuppet
	puppet.gesture = &"bank_right"
	await wait_frames(4)
	var ws := origin.world_scale
	gt(wings.wingtip(1).distance_to(tip0), 0.05 * ws, "wing followed the controller while paused (%.3f m at ws %.3f)" % [wings.wingtip(1).distance_to(tip0), ws])
	puppet.gesture = &"spread"
	Game.set_state(Game.State.PLAYING)
	check(not get_tree().paused, "unpaused")


## Both modes that stop a node on one side of the pause are corrected: a
## PAUSABLE node freezes while paused (the pause menu), a WHEN_PAUSED one
## freezes while PLAYING (fix round 6, engineering verifier: a mutant that
## corrected PAUSABLE only passed the whole suite). A hand model or pointer
## added as either would stop tracking.
func test_pausable_node_under_the_rig_is_fixed() -> void:
	var extras := rig["extras"] as VRRigExtras
	for mode in [Node.PROCESS_MODE_PAUSABLE, Node.PROCESS_MODE_WHEN_PAUSED]:
		var tag := "PAUSABLE" if mode == Node.PROCESS_MODE_PAUSABLE else "WHEN_PAUSED"
		var before := extras.process_fixes
		var bad := Node3D.new()
		bad.name = "Stopping" + tag
		bad.process_mode = mode
		(rig["camera"] as Node).add_child(bad)
		eq(bad.process_mode, Node.PROCESS_MODE_ALWAYS, "%s: set to ALWAYS on entering the rig" % tag)
		eq(extras.process_fixes, before + 1, "%s: fix counted" % tag)
		# Processes on both sides of the pause.
		Game.set_state(Game.State.PLAYING)
		check(bad.can_process(), "%s: processes in play" % tag)
		Game.set_state(Game.State.PAUSED)
		check(bad.can_process(), "%s: processes while paused" % tag)
		Game.set_state(Game.State.PLAYING)
		bad.queue_free()
	Game.set_state(Game.State.BOOT)


## A rig built with its origin INHERIT (under a PAUSABLE body) and a
## pausable node already under it: attaching the extras alone (no manual
## call) must make the whole subtree process while paused.
func test_origin_forced_to_always_at_attach() -> void:
	var r2 := Env.build_rig(self, Vector3(40, 3, 0), MemoryStore.new(), false, false, false)
	var origin: XROrigin3D = r2["origin"]
	eq(origin.process_mode, Node.PROCESS_MODE_INHERIT, "(setup) origin starts INHERIT")
	# Already under the rig before the (deferred) attach: only the attach
	# itself can fix it (mutant R09 skipped that pass and survived).
	var early := Node3D.new()
	early.name = "EarlyPausable"
	early.process_mode = Node.PROCESS_MODE_PAUSABLE
	(r2["camera"] as Node).add_child(early)
	eq(early.process_mode, Node.PROCESS_MODE_PAUSABLE, "(setup) added before the extras attached: not yet fixed")
	var early_wp := Node3D.new()
	early_wp.name = "EarlyWhenPaused"
	early_wp.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	origin.add_child(early_wp)
	await wait_frames(3)
	eq(origin.process_mode, Node.PROCESS_MODE_ALWAYS, "the extras set the origin to ALWAYS when they attached")
	eq(early.process_mode, Node.PROCESS_MODE_ALWAYS, "and the pausable node already under the rig")
	eq(early_wp.process_mode, Node.PROCESS_MODE_ALWAYS, "and a WHEN_PAUSED one (it would stop in play)")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(origin.can_process(), "the attached rig processes while paused")
	check((r2["camera"] as Node).can_process(), "its camera too")
	check(early.can_process(), "and the early node")
	check(not (r2["player"] as Node).can_process(), "its body stays pausable")
	Game.set_state(Game.State.PLAYING)
	(r2["player"] as Node).queue_free()
	await wait_frames(1)


## Where the extras put their parts on attach (integration instances them
## under flight's XROrigin3D): the vignette under the XRCamera3D (the
## brief's "camera-attached"; mutant E07 left it under the extras and
## survived), the wings under the origin with an identity transform, and
## the calibration wired to the rig's own grip controllers. When the extras
## leave the tree they take the moved parts along and hand the automatic
## capture back to the player (mutant E08 left them on the rig).
func test_extras_place_their_parts_and_clean_up() -> void:
	var r := Env.build_rig(self, Vector3(0, 40, 0), MemoryStore.new(), false, false)
	await wait_frames(3)
	var extras: VRRigExtras = r["extras"]
	var origin: XROrigin3D = r["origin"]
	var cam: XRCamera3D = r["camera"]
	eq(extras.vignette.get_parent(), cam, "the vignette hangs under the XRCamera3D")
	eq(extras.vignette.transform, Transform3D.IDENTITY, "at the camera's own frame")
	eq(extras.wings.get_parent(), origin, "the wings hang under the XROrigin3D")
	eq(extras.wings.transform, Transform3D.IDENTITY, "with an identity transform (origin space)")
	eq(extras.calibration.hands[0], r["left"], "calibration reads the rig's left grip controller")
	eq(extras.calibration.hands[1], r["right"], "and the right one")
	eq(extras.world_scale_driver.camera, cam, "the near plane follows the rig's camera")
	var player: Object = r["player"]
	check(not bool(player.get("auto_calibrate")), "(setup) the player's own capture is VR's while the extras run")
	var wings := extras.wings
	var vignette := extras.vignette
	extras.queue_free()
	await wait_frames(2)
	check(not is_instance_valid(wings), "the wings left with the extras")
	check(not is_instance_valid(vignette), "the vignette left with the extras")
	check(bool(player.get("auto_calibrate")), "the player's own automatic capture is handed back")
	(r["player"] as Node).queue_free()
	await wait_frames(1)


## Leaving the tree is not being deleted (fix round 5, both verifiers'
## probe): the player (with the extras under its XROrigin3D) removed and
## added back, then reparented under another node, keeps its first-person
## wings and comfort vignette on the rig and working, the pause rule still
## corrects nodes added under the rig afterwards, and the automatic capture
## is VR's again. The extras removed alone park the parts (hidden, idle)
## and restore them when added back. Round 4 freed both parts for the rest
## of the session on the first removal.
func test_rig_leaving_and_reentering_keeps_its_parts() -> void:
	var r := Env.build_rig(self, Vector3(20, 40, 0), MemoryStore.new(), false, false)
	await wait_frames(3)
	var extras: VRRigExtras = r["extras"]
	var origin: XROrigin3D = r["origin"]
	var cam: XRCamera3D = r["camera"]
	var player: Node3D = r["player"]
	var wings := extras.wings
	var vignette := extras.vignette
	var holder := Node3D.new()
	holder.name = "RespawnHolder"
	add_child(holder)
	for how in ["remove_child / add_child", "reparent"]:
		if how == "reparent":
			player.reparent(holder)
		else:
			remove_child(player)
			await wait_frames(2)
			add_child(player)
		await wait_frames(3)
		check(is_instance_valid(wings) and wings == extras.wings, "%s: the wings survive" % how)
		check(is_instance_valid(vignette) and vignette == extras.vignette, "%s: the vignette survives" % how)
		if not (is_instance_valid(wings) and is_instance_valid(vignette)):
			return
		check(wings.is_inside_tree() and wings.get_parent() == origin, "%s: the wings are on the rig" % how)
		check(wings.visible and wings.is_processing(), "%s: the wings are shown and laid out" % how)
		check(vignette.get_parent() == cam and vignette.is_physics_processing() and vignette.is_processing(), "%s: the vignette is on the camera and measuring" % how)
		check(not bool(player.get("auto_calibrate")), "%s: the automatic capture is VR's again" % how)
		var n := Node3D.new()
		n.process_mode = Node.PROCESS_MODE_PAUSABLE
		cam.add_child(n)
		eq(n.process_mode, Node.PROCESS_MODE_ALWAYS, "%s: a pausable node added under the rig afterwards is still corrected" % how)
		n.queue_free()
	# The extras alone leave (a desktop mode, a rebuild): the parts are
	# parked on the rig, then restored.
	origin.remove_child(extras)
	await wait_frames(2)
	check(is_instance_valid(wings) and not wings.visible and not wings.is_processing(), "extras removed: the wings are parked (hidden, idle)")
	check(is_instance_valid(vignette) and not vignette.visible and not vignette.is_physics_processing(), "extras removed: the vignette is parked")
	origin.add_child(extras)
	await wait_frames(3)
	check(wings.visible and wings.is_processing(), "extras back: the wings are shown again")
	check(vignette.is_physics_processing(), "extras back: the vignette measures again")
	# Deleted: the parts go with them.
	extras.queue_free()
	await wait_frames(2)
	check(not is_instance_valid(wings) and not is_instance_valid(vignette), "extras deleted: the parts go too")
	holder.queue_free()
	await wait_frames(1)

