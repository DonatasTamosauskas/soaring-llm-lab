extends TestCase
## Round-3 engineering verifier probes for the VR area (not part of the
## unit suite). Each test pins a behaviour docs/areas/VR.md claims but the
## unit suite does not measure, on the production code path.
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3eng

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const Env := preload("res://scenes/dev/vr_dev_env.gd")
const DT := 1.0 / 90.0


func make_rig() -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	return {"origin": origin, "camera": cam, "hands": [l, r]}


func drive(rig: Dictionary, h: VRHumanPose) -> void:
	var ws := (rig["origin"] as XROrigin3D).world_scale
	var hd := h.head_transform()
	(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin * ws)
	for i in 2:
		var x := h.hand_transform(i)
		(rig["hands"][i] as Node3D).transform = Transform3D(x.basis, x.origin * ws)


func run(node: VRCalibration, rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		drive(rig, h)
		node.tick(DT)


func make_node(rig: Dictionary, store: Object) -> VRCalibration:
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = rig["origin"]
	node.camera = rig["camera"]
	node.hands = [rig["hands"][0], rig["hands"][1]]
	return node


func make_player(mode: String) -> Bird:
	var p := StubPlayer.new()
	p.mode_label = mode
	p.calibration = CalMock.new()
	add_child(p)
	return p


func drop(p: Node) -> void:
	remove_child(p)
	p.free()


## VR.md §2.3: "Seated: head below 1.30 m for 5 s (hysteresis: standing
## again above 1.40 m for 5 s)"; ARCHITECTURE (vr fix round 1): "Live seated
## written into flight's resource is detected OR the Settings preference".
## A player who calibrates standing and then sits down is detected by VR's
## calibrator and persisted; the calibration flight flies must follow
## (flight uses cal.seated for its reach threshold and fold limits).
func test_detected_seating_reaches_flight() -> void:
	var rig := make_rig()
	var store := MemoryStore.new()
	var node := make_node(rig, store)
	var p := make_player("perched")
	var res: Resource = p.calibration
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	run(node, rig, h, 2.0)
	check(node.calibrator.calibrated and not bool(res.get("seated")), "(setup) standing player calibrated, flight standing")
	# Sit down: eyes at 1.15 m, relaxed arms, for 6 s.
	h.eye_height = 1.15
	h.set_arms(deg_to_rad(-60.0))
	run(node, rig, h, 6.0)
	check(node.calibrator.seated, "VR detected seated play")
	check(bool((store.get_value("wing_calibration", {}) as Dictionary).get("seated", false)), "and persisted it")
	check(bool(res.get("seated")), "flight's live calibration follows the detected seating (got seated=%s)" % str(res.get("seated")))
	metric("flight_seated_after_sitting", bool(res.get("seated")))
	# Stand up again for 6 s: VR goes back to standing; flight must too.
	h.eye_height = 1.60
	run(node, rig, h, 6.0)
	check(not node.calibrator.seated, "VR detected standing again")
	check(not bool(res.get("seated")), "flight's live calibration follows standing up (got seated=%s)" % str(res.get("seated")))
	drop(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()


## VR.md §2.3 hysteresis: a head between 1.30 and 1.40 m must not flip a
## seated player back to standing (mutant E04 survives the unit suite).
func test_seated_hysteresis_band() -> void:
	var cal := WingCalibrator.new()
	cal.auto_capture_allowed = true
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	for i in int(2.0 / DT):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(cal.calibrated, "(setup) calibrated")
	h.eye_height = 1.15
	for i in int(6.0 / DT):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(cal.seated, "(setup) seated")
	h.eye_height = 1.35
	for i in int(8.0 / DT):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	check(cal.seated, "leaning up to 1.35 m (inside the 1.30-1.40 band) keeps seated mode")


## VR.md §2.3: "a player without mode_name() is trusted only outside
## PLAYING" (mutant E02 survives the unit suite).
func test_player_without_mode_name_not_captured_in_play() -> void:
	var node := VRCalibration.new()
	node.auto_tick = false
	node.persist = false
	node.store = MemoryStore.new()
	add_child(node)
	var bare := preload("res://tests/probes/vr/r3eng_bare_player.gd").new() as Bird
	add_child(bare)
	var old := Game.state
	Game.state = Game.State.PLAYING
	check(not node.auto_capture_safe(), "a player without mode_name(): no automatic capture while PLAYING")
	Game.state = Game.State.MENU
	check(node.auto_capture_safe(), "and allowed in the menu")
	Game.state = old
	drop(bare)
	node.queue_free()


## The rig extras' production wiring (mutant E07 survives the unit suite
## and the flight_rig checks): the vignette must end up under the
## XRCamera3D (its flow rays start at the eyes, its ring depth follows the
## camera's near plane) and the wings under the origin with identity.
func test_extras_attach_vignette_to_the_camera() -> void:
	var rig := Env.build_rig(self, Vector3(0, 3, 0), MemoryStore.new(), false, false)
	await wait_frames(3)
	var extras: VRRigExtras = rig["extras"]
	eq(extras.vignette.get_parent(), rig["camera"], "vignette under the XRCamera3D")
	eq(extras.wings.get_parent(), rig["origin"], "wings under the XROrigin3D")
	check(extras.wings.transform.is_equal_approx(Transform3D.IDENTITY), "wings at identity")
	# Leaving: the moved components go with the extras (mutant E08 survives).
	var wings := extras.wings
	var vignette := extras.vignette
	extras.get_parent().remove_child(extras)
	extras.free()
	await wait_frames(2)
	check(not is_instance_valid(wings), "wings freed with the extras")
	check(not is_instance_valid(vignette), "vignette freed with the extras")
	(rig["player"] as Node).queue_free()
	XRServer.world_scale = 1.0


## Code audit of FirstPersonWings._place_wing: the folded-wing plane turns
## towards level only `if level.length() > 0.2 and level.dot(n_h) > -0.2`,
## a hard branch on a continuous input (mutant E31, which drops half of it,
## survives the unit suite). Sweep a folded right wing's wrist roll about
## the forearm in 0.5° steps and measure how far the primaries' plane jumps
## between neighbouring poses: a continuous layout moves ~0.5° per step.
func test_folded_wing_plane_is_continuous_in_wrist_roll() -> void:
	var cal := WingCalibrator.new()
	var wings := FirstPersonWings.new()
	wings.auto_update = false
	wings.use_flight_extension = false
	wings.calibrator = cal
	add_child(wings)
	cal.valid = [true, true]
	cal.shoulders = [Vector3(-0.17, 1.38, 0.0), Vector3(0.17, 1.38, 0.0)]
	cal.extension = [0.0, 0.0]
	# A relaxed right hand beside the hip-ish, forearm pointing forward-down.
	var base := VRHumanPose.airplane_basis(1)
	var hand_pos := Vector3(0.30, 1.05, -0.25)
	var axis := (base * WingCalibrator.DEFAULT_FOREARM).normalized()
	var worst := 0.0
	var worst_at := 0.0
	var prev := Vector3.ZERO
	for i in 721:
		var roll := deg_to_rad(0.5 * i)
		cal.hands[1] = Transform3D(Basis(axis, roll) * base, hand_pos)
		cal.hands[0] = Transform3D(VRHumanPose.airplane_basis(0), Vector3(-0.30, 1.05, -0.25))
		wings.update_wings(0.0)
		var n := wings.feather_transform(FirstPersonWings.PER_WING + 3).basis.y.normalized()
		if i > 0:
			var step := rad_to_deg(prev.angle_to(n))
			if step > worst:
				worst = step
				worst_at = 0.5 * i
		prev = n
	metric("folded_wing_worst_step_deg", snappedf(worst, 0.01))
	print("[vr-verify] folded wing: worst plane jump %.1f° for a 0.5° wrist step at roll %.1f°" % [worst, worst_at])
	lt(worst, 5.0, "a 0.5° wrist roll never flips the folded wing's plane (worst %.1f° at %.1f°)" % [worst, worst_at])
	wings.queue_free()
