extends TestCase
## Verifier probes (round 2, engineering & contract lens) for the ui area.
## Not part of the area suite. Run with:
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_probe_r2
## A failing check here is a finding, not a flaky test.
##
## 1. The real XR input path (UIXRPointerSource -> XRController3D -> XRServer
##    tracker) that the simulator cannot exercise: drive a fake tracker the way
##    the OpenXR interface does (pose "aim", inputs "trigger", "menu_button",
##    "by_button") and check the UI reacts end to end.
## 2. attach_rig() idempotence (UIAim controllers under the player's rig).
## 3. Victory: what the player is shown when GameLoop ends the run in victory.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit
var _trackers: Array[XRPositionalTracker] = []


func after_each() -> void:
	for t in _trackers:
		XRServer.remove_tracker(t)
	_trackers.clear()
	if k:
		k.teardown()
		k = null
	await wait_frames(2)


func _tracker(tname: StringName) -> XRPositionalTracker:
	var t := XRPositionalTracker.new()
	t.type = XRServer.TRACKER_CONTROLLER
	t.name = tname
	t.hand = XRPositionalTracker.TRACKER_HAND_LEFT if tname == &"left_hand" else XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(t)
	_trackers.append(t)
	return t


## Pose in tracking space (rig-local, unscaled metres), aimed at a rig-local point.
func _aim(t: XRPositionalTracker, from_local: Vector3, at_local: Vector3) -> void:
	var dir := (at_local - from_local).normalized()
	t.set_pose(&"aim", Transform3D(Basis.looking_at(dir, Vector3.UP), from_local), Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	t.set_pose(&"default", Transform3D(Basis.looking_at(dir, Vector3.UP), from_local), Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## A UIRoot in VR mode on a real rig, with NO scripted sources: the pointer
## reads XRController3D nodes, exactly as in the headset.
func _setup_real_sources() -> void:
	k = Kit.new()
	# Kit.setup installs scripted sources; rebuild the UI without them.
	k.setup(self, true)
	await k.settle(self, 2)
	k.ui.queue_free()
	await wait_frames(2)
	for c in k.rig.get_children():
		if c is XRController3D:
			c.queue_free()
	await wait_frames(1)
	k.ui = Kit.UI_SCENE.instantiate() as UIRoot
	k.ui.mode = UIRoot.Mode.VR
	k.ui.progress_path = k.progress_path
	add_child(k.ui)
	k.ui.quit_handler = func() -> void: k.quits += 1
	await k.settle(self, 4)


func test_xr_source_reads_real_controller_inputs() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 2)
	var t := _tracker(&"right_hand")
	var src := UIXRPointerSource.new(&"right_hand", k.rig)
	_aim(t, Vector3(0.2, 1.3, -0.3), Vector3(0, 1.5, -1.5))
	await wait_frames(3)
	check(src.is_tracked(), "tracked once the aim pose has data")
	var want := k.rig.global_transform * Transform3D(Basis.looking_at((Vector3(0, 1.5, -1.5) - Vector3(0.2, 1.3, -0.3)).normalized(), Vector3.UP), Vector3(0.2, 1.3, -0.3))
	vnear(src.aim_transform().origin, want.origin, 0.001, "aim origin from the 'aim' pose")
	vnear(-src.aim_transform().basis.z, -want.basis.z, 0.001, "aim direction from the 'aim' pose")
	t.set_input(&"trigger", 0.8)
	await wait_frames(1)
	near(src.trigger(), 0.8, 0.001, "analogue 'trigger' read")
	t.set_input(&"trigger", 0.0)
	t.set_input(&"trigger_click", true)
	await wait_frames(1)
	near(src.trigger(), 1.0, 0.001, "'trigger_click' counts as a full pull")
	t.set_input(&"trigger_click", false)
	t.set_input(&"menu_button", true)
	t.set_input(&"by_button", true)
	await wait_frames(1)
	check(src.menu_pressed(), "'menu_button' read")
	check(src.back_pressed(), "'by_button' read")
	src.controller.queue_free()


func test_end_to_end_click_and_menu_through_xr_controllers() -> void:
	await _setup_real_sources()
	var aims := k.rig.find_children("*", "XRController3D", false, false)
	eq(aims.size(), 2, "exactly two UI aim controllers under the rig")
	var r := _tracker(&"right_hand")
	var l := _tracker(&"left_hand")
	var play := k.ui.get_screen(&"main").get_button(&"play")
	var at_world := k.ui.menu_panel.control_to_world(play)
	var at_local := k.rig.global_transform.affine_inverse() * at_world
	_aim(r, Vector3(0.22, 1.25, -0.25), at_local)
	_aim(l, Vector3(-0.25, 1.0, -0.2), Vector3(-0.25, 0.0, -0.2))
	await wait_seconds(0.3)
	eq(k.ui.pointer.hovered(), play, "the real aim pose hovers Play")
	r.set_input(&"trigger", 1.0)
	await wait_frames(3)
	r.set_input(&"trigger", 0.0)
	await wait_frames(3)
	eq(Game.state, Game.State.PLAYING, "a real trigger pull on Play starts a run")
	await wait_seconds(0.3)
	l.set_input(&"menu_button", true)
	await wait_frames(3)
	l.set_input(&"menu_button", false)
	await wait_frames(3)
	eq(Game.state, Game.State.PAUSED, "the left controller's real menu_button pauses")
	await wait_seconds(0.3)
	l.set_input(&"menu_button", true)
	await wait_frames(3)
	l.set_input(&"menu_button", false)
	await wait_frames(3)
	eq(Game.state, Game.State.PLAYING, "and resumes while the tree is paused")


func test_attach_rig_twice_does_not_duplicate_aim_controllers() -> void:
	await _setup_real_sources()
	var before := k.rig.find_children("*", "XRController3D", false, false).size()
	# Integration (or a respawned rig) attaching the same rig explicitly.
	k.ui.attach_rig(k.rig, k.cam)
	k.ui.attach_rig(k.rig, k.cam)
	await wait_frames(2)
	var after := k.rig.find_children("*", "XRController3D", false, false).size()
	metric("aim_controllers", {"before": before, "after_two_attach_calls": after})
	eq(after, before, "attach_rig is idempotent: no orphaned UIAim controllers (%d -> %d)" % [before, after])


class ArtTimer:
	extends Control
	var art: StringName
	var t := 0.0
	var ms := 0.0

	func _draw() -> void:
		var t0 := Time.get_ticks_usec()
		GestureArt.draw(self, art, Rect2(Vector2.ZERO, size), t)
		ms = (Time.get_ticks_usec() - t0) / 1000.0


func test_illustration_cpu_cost_per_redraw() -> void:
	# The HUD lesson thumbnail redraws at 15 fps all through the tutorial
	# (gameplay), the how-to card at 30 fps: record what one redraw costs.
	var probe := ArtTimer.new()
	add_child(probe)
	var out := {}
	var worst_thumb := 0.0
	for sz: Vector2 in [Vector2(210, 250), Vector2(900, 380)]:
		probe.size = sz
		for id: StringName in GestureArt.IDS:
			var total := 0.0
			var worst := 0.0
			for k in 20:
				probe.art = id
				probe.t = k * 0.113
				probe.queue_redraw()
				await wait_frames(1)
				total += probe.ms
				worst = maxf(worst, probe.ms)
			out["%s@%dx%d" % [id, sz.x, sz.y]] = [snappedf(total / 20.0, 0.01), snappedf(worst, 0.01)]
			if sz.x < 300.0:
				worst_thumb = maxf(worst_thumb, total / 20.0)
	metric("art_ms_mean_worst", out)
	metric("hud_thumbnail_mean_ms_worst_art", snappedf(worst_thumb, 0.01))
	lt(worst_thumb, 1.0, "HUD lesson thumbnail redraw < 1 ms on the dev Mac (%.2f ms mean, worst art)" % worst_thumb)
	probe.queue_free()


func test_victory_is_presented_as_a_victory() -> void:
	# GameLoop.end_run(&"victory") emits this summary shape (docs/areas/GAMELOOP.md).
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	var by := {&"hawk": 2, &"gull": 3}
	var s := {"reason": &"victory", "victory": true, "score": 9100, "time": 1500.0, "max_mass": 3.3, "max_tier": 9,
		"catches_by_species": by, "apex": {"reached": true, "catches": 5, "needed": 5, "victory": true},
		"new_records": {"score": true}, "records": {"best_score": 9100}}
	Game.set_state(Game.State.ENDED)
	Events.run_ended.emit(s)
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	var labels := []
	for lab in ss.find_children("*", "Label", true, false):
		if (lab as Label).is_visible_in_tree():
			labels.append((lab as Label).text)
	var buttons := []
	for id in ss.button_ids():
		if ss.get_button(id).is_visible_in_tree():
			buttons.append(ss.get_button(id).text)
	metric("victory_summary_labels", labels)
	metric("victory_summary_buttons", buttons)
	var says_won := false
	for t: String in labels:
		if t.to_lower().contains("victory") or t.to_lower().contains("won") or t.to_lower().contains("win"):
			says_won = true
	check(says_won, "a victory run says so on the summary (labels: %s)" % [labels])
	var can_continue := false
	for b: String in buttons:
		if b.to_lower().contains("keep") or b.to_lower().contains("continue"):
			can_continue = true
	check(can_continue, "GameLoop's continue_after_victory (victory lap) is reachable (buttons: %s)" % [buttons])
