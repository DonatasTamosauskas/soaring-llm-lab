extends TestCase
## Verifier probe (experience lens): the VR extras on the flight area's REAL
## player scene (scenes/player/player.tscn), the way integration will
## instance them, instead of the VR area's stand-in. Informational for
## integration: a failure here may be the flight area's in-progress code.
##
## Checks: the extras find the grip controllers (not UI/flight aim ones),
## move the wings under the origin and the vignette under the camera, own
## world_scale and the near plane (flight's fallback driver off), keep the
## whole XROrigin3D subtree running while paused (V8), and the calibration
## reaches PlayerBird.wing_input.calibration.

const PLAYER := "res://scenes/player/player.tscn"
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")

var player: Node3D
var extras: VRRigExtras


func before_all() -> void:
	if not ResourceLoader.exists(PLAYER):
		return
	var ps := load(PLAYER) as PackedScene
	if ps == null:
		return
	player = ps.instantiate() as Node3D
	# Never touch the shared settings file from a probe.
	if &"use_settings" in player:
		player.set(&"use_settings", false)
	var origin := player.get_node_or_null(^"XROrigin3D")
	extras = EXTRAS.instantiate() as VRRigExtras
	var cal := extras.get_node("Calibration") as VRCalibration
	cal.persist = false
	cal.store = load("res://tests/unit/vr/vr_memory_store.gd").new()
	if origin != null:
		origin.add_child(extras)
	add_child(player)
	player.position = Vector3(0, 20, 0)
	await wait_physics(10)
	await wait_frames(4)


func after_all() -> void:
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	if player != null:
		player.queue_free()
	XRServer.world_scale = 1.0


func test_extras_attach_to_the_real_rig() -> void:
	if not check(player != null and extras != null, "flight's player scene instanced"):
		return
	var origin := player.get_node(^"XROrigin3D") as XROrigin3D
	eq(extras.origin, origin, "extras attached to the player's XROrigin3D")
	eq(extras.camera, player.get_node(^"XROrigin3D/XRCamera3D"), "found the XRCamera3D")
	eq(extras.left_hand, player.get_node(^"XROrigin3D/LeftHand"), "left grip controller (not LeftAim)")
	eq(extras.right_hand, player.get_node(^"XROrigin3D/RightHand"), "right grip controller (not RightAim)")
	eq(extras.wings.get_parent(), origin, "wings under the origin")
	eq(extras.vignette.get_parent(), extras.camera, "vignette under the camera")
	var p := Birds.player()
	check(p == player, "PlayerBird registered as the player")
	var want := WorldScaleDriver.target_scale(p.mass, extras.calibration.calibrator.arm_span)
	near(origin.world_scale, want, 1e-4, "world_scale = VR's target for the player's mass (%.4f)" % origin.world_scale)
	near(extras.camera.near, WorldScaleDriver.near_for(origin.world_scale), 1e-6, "near plane = 0.03 x ws")
	if &"drive_world_scale" in player:
		check(not bool(player.get(&"drive_world_scale")), "flight's fallback world_scale driver stays off")
	var wi: Variant = player.get(&"wing_input")
	check(wi is Object and (wi as Object).get(&"calibration") is Resource, "PlayerBird.wing_input.calibration exists (VR writes it)")


func test_real_rig_keeps_tracking_while_paused() -> void:
	if not check(player != null, "player"):
		return
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	var origin := player.get_node(^"XROrigin3D") as XROrigin3D
	check(origin.can_process(), "origin processes while paused")
	var stuck: Array[String] = []
	for n in origin.find_children("*", "", true, false):
		if not n.can_process():
			stuck.append(String(n.name))
	eq(stuck.size(), 0, "every node under the real rig processes while paused %s" % str(stuck))
	check(not player.can_process(), "PlayerBird itself pauses (flight)")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.BOOT)
