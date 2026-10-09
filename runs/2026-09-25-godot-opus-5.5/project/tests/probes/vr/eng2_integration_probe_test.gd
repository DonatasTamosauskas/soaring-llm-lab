extends TestCase
## VERIFIER PROBE (vr, round 1, engineering/contract lens). Not part of the
## area suite; run with
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=eng2_
## Attaches scenes/vr/vr_rig_extras.tscn to the flight area's real
## scenes/player/player.tscn the way docs/areas/VR.md tells integration to
## (add_child under the XROrigin3D after the player is in the tree), and
## checks claims the VR suite only tests against its own stub player.
## Calibration persists into a private memory store (never user://).

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const DT := 1.0 / 90.0

var player: Node3D
var origin: XROrigin3D
var camera: XRCamera3D
var extras: VRRigExtras
var store: RefCounted


func before_all() -> void:
	var ps := load("res://scenes/player/player.tscn") as PackedScene
	player = ps.instantiate() as Node3D
	# Keep flight passive: no pose source, no ticking, no shared settings.
	player.set("use_settings", false)
	player.set("default_source", &"none")
	player.set("auto_process", false)
	player.position = Vector3(0, 30, 0)
	add_child(player)
	origin = player.get_node("XROrigin3D") as XROrigin3D
	camera = origin.get_node("XRCamera3D") as XRCamera3D
	extras = EXTRAS.instantiate() as VRRigExtras
	store = MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).store = store
	origin.add_child(extras)
	await wait_frames(3)
	await wait_physics(3)


func after_all() -> void:
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	if is_instance_valid(player):
		player.queue_free()
	await wait_frames(2)
	XRServer.world_scale = 1.0


## Drives the flight rig's camera and grip controllers from a synthetic player.
func drive(h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		var ws := origin.world_scale
		var hd := h.head_transform()
		camera.transform = Transform3D(hd.basis, hd.origin * ws)
		for side in 2:
			var x := h.hand_transform(side)
			var n := origin.get_node("LeftHand" if side == 0 else "RightHand") as Node3D
			n.transform = Transform3D(x.basis, x.origin * ws)
		extras.calibration.tick(DT)


# -----------------------------------------------------------------------------

func test_attaches_to_the_flight_rig() -> void:
	eq(extras.origin, origin, "extras found the flight rig's XROrigin3D")
	eq(extras.camera, camera, "extras use the flight rig's XRCamera3D")
	check(extras.left_hand != null and extras.left_hand.name == "LeftHand", "left grip = flight's LeftHand (not LeftAim)")
	check(extras.right_hand != null and extras.right_hand.name == "RightHand", "right grip = flight's RightHand (not RightAim)")
	check(origin.get_node_or_null("VRGrip_L") == null and origin.get_node_or_null("VRGrip_R") == null, "no duplicate grip controllers created")
	eq(extras.wings.get_parent(), origin, "wings moved under the origin")
	eq(extras.vignette.get_parent(), camera, "vignette moved under the camera")


func test_world_scale_and_near_plane_on_the_flight_rig() -> void:
	await wait_physics(4)
	var span := extras.calibration.calibrator.arm_span
	var want := WorldScaleDriver.target_scale((player as Bird).mass, span)
	near(origin.world_scale, want, 1e-4, "world_scale snapped to the player's size (mass %.3f)" % (player as Bird).mass)
	near(camera.near, maxf(0.001, 0.03 * origin.world_scale), 1e-6, "near plane 0.03 x ws overrides the scene's 0.01")
	metric("world_scale", origin.world_scale)


func test_saved_calibration_reaches_flight() -> void:
	var h := VRHumanPose.for_span(1.85)
	h.twist_offset = [deg_to_rad(15.0), deg_to_rad(15.0)]
	h.spread_pose()
	var src := WingCalibrator.new()
	for i in int(2.0 / DT):
		src.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(src.calibrated, "source calibration captured")
	store.set_value("wing_calibration", src.to_dict())
	extras.calibration.load_saved()
	var res: Object = (player.get("wing_input") as Object).get("calibration")
	check(res != null, "flight's WingCalibration exists")
	near(float(res.get("arm_span")), src.arm_span, 1e-5, "saved arm span written into flight's WingCalibration")
	check(bool(res.get("calibrated")), "flight's calibration marked calibrated")
	lt(VRMath.basis_angle(res.get("neutral_left"), src.neutral[0]), 1e-4, "neutral basis written into flight")
	check(not extras.calibration.calibrator.auto_capture, "a loaded calibration stops the automatic capture")
	await wait_physics(2)
	near(extras.world_scale_driver.target, WorldScaleDriver.target_scale((player as Bird).mass, src.arm_span), 1e-5, "world scale target follows the loaded span")


## Flight only lets its automatic neutral capture run while perched,
## spawning or grounded (player_bird.gd: "a bank held calmly for 1.2 s in
## flight must never become the player's flat"). VR's automatic capture has
## no such guard and writes into the same WingCalibration.
func test_auto_capture_while_flying_overrides_flight() -> void:
	var cal := extras.calibration.calibrator
	cal.reset_calibration()
	check(cal.auto_capture and not cal.calibrated, "fresh (first launch) VR calibrator")
	var res: Object = (player.get("wing_input") as Object).get("calibration")
	# Flight already holds a good calibration (captured while perched).
	res.set("neutral_left", WingCalibration.AIRPLANE_L)
	res.set("neutral_right", WingCalibration.AIRPLANE_R)
	res.set("calibrated", true)
	player.set("mode", 1)   # PlayerBird.Mode.FLYING
	# A calm, level glide with both wrists 20 deg leading edge down (a dive trim).
	var h := VRHumanPose.for_span(1.6)
	h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(-20.0))
	drive(h, 2.0)
	var captured_in_flight := cal.calibrated
	var drift := rad_to_deg(VRMath.basis_angle(res.get("neutral_left"), WingCalibration.AIRPLANE_L))
	metric("captured_while_flying", captured_in_flight)
	metric("flight_neutral_moved_deg", drift)
	check(not captured_in_flight, "VR must not capture a neutral while the bird is flying (captured: %s)" % str(captured_in_flight))
	lt(drift, 1.0, "flight's calibration must not be overwritten by a mid-flight capture (moved %.1f deg)" % drift)
	player.set("mode", 0)


func test_pause_keeps_the_flight_rig_alive() -> void:
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(get_tree().paused, "paused")
	var bad: Array[String] = []
	for n in origin.find_children("*", "", true, false):
		if not n.can_process():
			bad.append(String(n.name))
	eq(bad.size(), 0, "every node under the flight rig processes while paused %s" % str(bad))
	check(not player.can_process(), "the flight body is pausable")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.BOOT)


func test_growth_never_node_scales_the_flight_rig() -> void:
	(player as Bird).mass = 3.0
	var worst := 0.0
	for i in 90:
		await get_tree().physics_frame
		for n: Node3D in [player, origin, camera, extras.left_hand, extras.right_hand, extras.wings]:
			var b := n.transform.basis
			worst = maxf(worst, maxf(absf(b.x.length() - 1.0), maxf(absf(b.y.length() - 1.0), absf(b.z.length() - 1.0))))
	lt(worst, 1e-5, "no node scale on the player, rig, camera, grips or wings")
	gt(origin.world_scale, 0.16, "world_scale grew meanwhile (ramp <= 0.25 ln/s) (%.3f)" % origin.world_scale)
	(player as Bird).mass = 0.03
