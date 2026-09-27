extends TestCase
## Round-1 engineering verifier probes (after the builder's fix round 4),
## not the builder's suite. Each test pins a robustness / contract claim
## the unit suite does not exercise.
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r1eng

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const Env := preload("res://scenes/dev/vr_dev_env.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")


func after_all() -> void:
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false


## A bare stand-in rig (Bird "player" -> XROrigin3D in group player_rig ->
## camera + two grip controllers), without the extras.
func _bare_rig(at: Vector3) -> Dictionary:
	var p: Node3D = StubPlayer.new()
	p.name = "BareRig"
	p.position = at
	var o := XROrigin3D.new()
	o.name = "XROrigin3D"
	o.add_to_group(&"player_rig")
	o.process_mode = Node.PROCESS_MODE_ALWAYS
	p.add_child(o)
	var cam := XRCamera3D.new()
	cam.name = "XRCamera3D"
	cam.position = Vector3(0, 1.6, 0)
	o.add_child(cam)
	var hands: Array[XRController3D] = []
	for side in [&"left_hand", &"right_hand"]:
		var c := XRController3D.new()
		c.name = "L" if side == &"left_hand" else "R"
		c.tracker = side
		c.pose = &"grip"
		o.add_child(c)
		hands.append(c)
	return {"player": p, "origin": o, "camera": cam, "left": hands[0], "right": hands[1]}


## The rig (the player bird) leaves the scene tree and comes back (a
## remove_child / add_child or reparent by the game, e.g. moving the player
## under another node at a respawn or a scene rebuild). The extras stay
## attached to that same rig: the first-person wings and the comfort
## vignette must still exist and be on the rig afterwards.
func test_rig_leaving_and_reentering_the_tree_keeps_wings_and_vignette() -> void:
	var rig := Env.build_rig(self, Vector3(0, 60, 0), MemoryStore.new(), true, false)
	await wait_frames(4)
	var extras: VRRigExtras = rig["extras"]
	var player: Node3D = rig["player"]
	check(is_instance_valid(extras.wings) and extras.wings.get_parent() == rig["origin"], "(setup) wings on the origin")
	check(is_instance_valid(extras.vignette) and extras.vignette.get_parent() == rig["camera"], "(setup) vignette on the camera")
	remove_child(player)
	await wait_frames(2)
	add_child(player)
	await wait_frames(4)
	var wings_ok := is_instance_valid(extras.wings) and extras.wings.is_inside_tree()
	var vig_ok := is_instance_valid(extras.vignette) and extras.vignette.is_inside_tree()
	check(wings_ok, "the first-person wings survive the rig leaving and re-entering the tree")
	check(vig_ok, "the comfort vignette survives the rig leaving and re-entering the tree")
	metric("wings_valid_after_reenter", wings_ok)
	metric("vignette_valid_after_reenter", vig_ok)
	player.queue_free()
	(rig["puppet"] as Node).queue_free()
	await wait_frames(2)


## Integration may instance the extras before the player exists, or not
## under the XROrigin3D (ARCHITECTURE contract note "it also finds group
## player_rig if placed elsewhere, retrying until the rig exists"). The
## parts must then land on the rig exactly as when parented directly.
func test_extras_placed_elsewhere_attach_when_the_rig_appears() -> void:
	var extras := EXTRAS.instantiate() as VRRigExtras
	(extras.get_node("Calibration") as VRCalibration).store = MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).persist = false
	add_child(extras)
	await wait_frames(3)
	check(extras.origin == null, "(setup) no rig yet")
	var rig := _bare_rig(Vector3(30, 60, 0))
	add_child(rig["player"])
	await wait_seconds(0.8)
	eq(extras.origin, rig["origin"], "found the rig by group")
	eq(extras.vignette.get_parent(), rig["camera"], "vignette under the XRCamera3D")
	eq(extras.wings.get_parent(), rig["origin"], "wings under the XROrigin3D")
	eq(extras.calibration.hands[0], rig["left"], "calibration reads the rig's grip controllers")
	eq((rig["origin"] as XROrigin3D).process_mode, Node.PROCESS_MODE_ALWAYS, "origin processes while paused")
	# UI adds aim-pose pointers (UIAim_*) under the rig: they must not be taken
	# for the grip controllers when the extras attach later.
	extras.queue_free()
	(rig["player"] as Node).queue_free()
	await wait_frames(2)


## ARCHITECTURE §4/§7.6: "Everything under XROrigin3D is PROCESS_MODE_ALWAYS".
## A node added under the rig with PROCESS_MODE_WHEN_PAUSED would stop
## while playing; with DISABLED it never runs. The extras correct PAUSABLE
## and WHEN_PAUSED; record what happens to DISABLED (a deliberate choice).
func test_when_paused_nodes_under_the_rig_are_corrected() -> void:
	var rig := Env.build_rig(self, Vector3(-30, 60, 0), MemoryStore.new(), false, false)
	await wait_frames(3)
	var n := Node3D.new()
	n.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	(rig["camera"] as Node).add_child(n)
	eq(n.process_mode, Node.PROCESS_MODE_ALWAYS, "WHEN_PAUSED under the rig corrected to ALWAYS")
	(rig["player"] as Node).queue_free()
	await wait_frames(2)


## V7 on the stand-in rig while PAUSED: world_scale holds (documented) and
## the near plane still follows a foreign write to the scale.
func test_near_plane_is_reasserted_while_paused() -> void:
	var rig := Env.build_rig(self, Vector3(0, 90, 0), MemoryStore.new(), false, false)
	(rig["player"] as Bird).mass = 0.03
	await wait_physics(4)
	var o: XROrigin3D = rig["origin"]
	var cam: XRCamera3D = rig["camera"]
	var ws0 := o.world_scale
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	cam.near = 0.5
	await wait_physics(3)
	near(cam.near, WorldScaleDriver.near_for(o.world_scale), 1e-6, "near plane restored while paused")
	near(o.world_scale, ws0, 1e-6, "world_scale held while paused")
	Game.set_state(Game.State.PLAYING)
	(rig["player"] as Node).queue_free()
	await wait_frames(2)
