extends TestCase
## VERIFIER PROBE (vr, round 4, requirements lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r4x_menu_recalibration
##
## V3 "manual recalibrate works" -- the way a player actually reaches it:
## Settings > "Recalibrate wings" lives in the PAUSE menu, so the flow runs
## with Game.PAUSED and the SceneTree paused, on real frames (not the
## unit test's manual tick()). Checks:
##  - the flow runs to DONE while paused and the new body is persisted;
##  - the instruction card is shown while paused and draws above UI panels
##    (UIPanel.render_priority is 10; the settings panel stays open);
##  - the "confirm" haptic is still sent while paused (VR.haptics drops
##    every other pattern while paused);
##  - the automatic capture stays shut while paused (a still spread in the
##    menu is not captured unless the player asked).

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")


## Writes the synthetic player's poses into the rig every frame, before
## VRCalibration (priority 50) reads them; keeps running while paused.
class Driver:
	extends Node
	var human: VRHumanPose
	var origin: XROrigin3D
	var camera: Node3D
	var hands: Array = []

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = -10

	func _process(_dt: float) -> void:
		var ws := origin.world_scale
		var hd := human.head_transform()
		camera.transform = Transform3D(hd.basis, hd.origin * ws)
		for i in 2:
			var x := human.hand_transform(i)
			(hands[i] as Node3D).transform = Transform3D(x.basis, x.origin * ws)


var _prev_state := 0


func before_all() -> void:
	XRServer.world_scale = 1.0
	_prev_state = Game.state


func after_all() -> void:
	get_tree().paused = false
	Game.set_state(_prev_state as Game.State)


func build(store: Object, human: VRHumanPose) -> Dictionary:
	var origin := XROrigin3D.new()
	origin.process_mode = Node.PROCESS_MODE_ALWAYS
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	var drv := Driver.new()
	drv.human = human
	drv.origin = origin
	drv.camera = cam
	drv.hands = [l, r]
	add_child(drv)
	var node := VRCalibration.new()
	node.store = store
	node.force_valid = true
	node.show_prompt = true
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	return {"origin": origin, "driver": drv, "node": node}


func test_recalibrate_from_the_pause_menu() -> void:
	var store := MemoryStore.new()
	# Player A is already calibrated (saved), player B takes the headset.
	var a := VRHumanPose.for_span(1.5)
	var pre := VRCalibration.new()
	pre.store = store
	pre.auto_tick = false
	pre.show_prompt = false
	pre.force_valid = true
	add_child(pre)
	var rig0 := {}
	var o0 := XROrigin3D.new()
	var c0 := XRCamera3D.new()
	var l0 := XRController3D.new()
	var r0 := XRController3D.new()
	o0.add_child(c0)
	o0.add_child(l0)
	o0.add_child(r0)
	add_child(o0)
	pre.origin = o0
	pre.camera = c0
	pre.hands = [l0, r0]
	pre.force_auto_allowed = true
	a.spread_pose()
	for i in 180:
		var hd := a.head_transform()
		c0.transform = hd
		l0.transform = a.hand_transform(0)
		r0.transform = a.hand_transform(1)
		pre.tick(1.0 / 90.0)
	check(pre.calibrator.calibrated, "player A calibrated and saved (setup)")
	var span_a := float(store.get_value("wing_calibration", {}).get("arm_span", 0.0))
	pre.queue_free()
	o0.queue_free()
	await wait_frames(2)

	var b := VRHumanPose.for_span(1.9)
	b.twist_offset = [deg_to_rad(15.0), deg_to_rad(-10.0)]
	b.set_arms(deg_to_rad(-60.0))
	var rig := build(store, b)
	var node: VRCalibration = rig["node"]
	await wait_frames(3)
	near(node.calibrator.arm_span, span_a, 1e-6, "B's rig loads A's saved calibration")
	var pre_neutral: Array = [node.calibrator.neutral[0], node.calibrator.neutral[1]]

	# The pause menu is open.
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(get_tree().paused, "tree paused (pause menu)")
	# A still spread in the pause menu without asking: never captured.
	b.spread_pose()
	await wait_seconds(2.0)
	var neutral_same := node.calibrator.neutral[0].is_equal_approx(pre_neutral[0]) and node.calibrator.neutral[1].is_equal_approx(pre_neutral[1])
	check(neutral_same, "paused: no automatic neutral capture of B's still spread (the gate holds)")
	near(node.calibrator.arm_span, span_a, 1e-6, "paused, nobody asked: B's spread in the menu must leave the saved calibration alone (span refinement runs while paused; saved %.3f)" % float(store.get_value("wing_calibration", {}).get("arm_span", 0.0)))

	# Settings > Recalibrate wings (UIRoot.recalibrate_requested -> start_manual).
	var confirms := []
	var cb := func(_h: int, _a: float, _d: float, pat: StringName) -> void:
		if pat == &"confirm":
			confirms.append(pat)
	VR.haptics.pulse_sent.connect(cb)
	var results := []
	node.flow_finished.connect(func(ok: bool, why: String) -> void: results.append([ok, why]))
	b.set_arms(deg_to_rad(-60.0))
	node.start_manual()
	await wait_frames(3)
	check(node.prompt != null and node.prompt.visible, "the instruction card is shown while paused")
	if node.prompt != null:
		var mat := node.prompt.card.material_override as Material
		gt(float(mat.render_priority), 10.0, "card draws above UI panels (UIPanel.render_priority 10)")
		check(node.prompt.text.no_depth_test and node.prompt.text.render_priority > 10, "card text draws above UI panels")
	b.spread_pose()
	await wait_seconds(2.5)
	eq(node.flow, VRCalibration.Flow.GLIDE, "paused: neutral captured on real frames -> glide step")
	b.set_arms(deg_to_rad(-30.0), 0.0, 0.0, deg_to_rad(30.0))
	await wait_seconds(3.0)
	check(node.flow == VRCalibration.Flow.DONE or (not results.is_empty() and results[0][0]), "paused: flow finished (flow %d)" % node.flow)
	check(not results.is_empty() and bool(results[0][0]), "reported success")
	var want := b.shoulder_width + 2.0 * b.arm_length()
	near(node.calibrator.arm_span, want, 0.01, "now fits player B (span)")
	near(float(store.get_value("wing_calibration", {}).get("arm_span", 0.0)), node.calibrator.arm_span, 1e-6, "B persisted")
	gt(confirms.size(), 0.0, "confirm haptic sent while paused (%d pulses)" % confirms.size())
	metric("menu_recalibration", {"span_a": span_a, "span_b": node.calibrator.arm_span, "want_b": want, "confirm_pulses": confirms.size(), "flow": node.flow})
	VR.haptics.pulse_sent.disconnect(cb)
	get_tree().paused = false
	Game.set_state(Game.State.MENU)
	(rig["node"] as Node).queue_free()
	(rig["driver"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()
	await wait_frames(2)
