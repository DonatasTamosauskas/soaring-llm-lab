extends TestCase
## Verifier probes (round 1) for U5/U6/U7: growth while the HUD is up,
## opening a menu while looking down, a 180 degree turn, replaying the
## tutorial mid-run, and a long idle session. Independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _angular_width(p: UIPanel) -> float:
	var eye := k.cam.global_position
	var s := Vector2(p.panel_size)
	var l := p.pixel_to_world(Vector2(0, s.y * 0.5)) - eye
	var r := p.pixel_to_world(Vector2(s.x, s.y * 0.5)) - eye
	return rad_to_deg(l.angle_to(r))


func test_stress_hud_size_under_uncapped_growth() -> void:
	# STRESS, not a gameplay rate: 3x world_scale in 120 *uncapped headless*
	# frames (a fraction of a second). Informational: shows the anchor lag
	# (position_tau 0.3 s); the realistic-rate check is in
	# ui_probe_geometry_test.test_hud_during_realistic_growth.
	k.ui.onboarding.skip()
	k.set_world_scale(0.3)
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.hud_panel.snap_to_head()
	await k.settle(self, 2)
	var ref := _angular_width(k.ui.hud_panel)
	var worst_size := 0.0
	var worst_dist := 0.0
	var n := 120
	for i in n:
		k.set_world_scale(lerpf(0.3, 0.9, (i + 1) / float(n)))
		await wait_frames(1)
		var w := _angular_width(k.ui.hud_panel)
		worst_size = maxf(worst_size, absf(w - ref) / ref)
		var d := k.cam.global_position.distance_to(k.ui.hud_panel.global_position) / k.rig.world_scale
		worst_dist = maxf(worst_dist, absf(d - UITheme.HUD_DISTANCE) / UITheme.HUD_DISTANCE)
	metric("stress_growth_while_hud_up", {"max_size_err": snappedf(worst_size, 0.0001), "max_dist_err": snappedf(worst_dist, 0.0001)})
	# Only guard against gross failure (panel lost / wildly misplaced).
	lt(worst_size, 0.25, "HUD apparent width stays sane under stress (%.3f)" % worst_size)


func test_menu_opens_in_front_when_looking_down() -> void:
	# Player is staring at the ground (pitch -70) when they pause.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	k.set_head(Vector3(0, Kit.EYE, 0), 35.0, -70.0)
	await k.settle(self, 2)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var p := k.ui.menu_panel
	var to := p.global_position - k.cam.global_position
	var yaw := rad_to_deg(atan2(-to.x, -to.z))
	var elev := rad_to_deg(asin(to.normalized().y))
	metric("look_down", {"panel_yaw": snappedf(yaw, 0.1), "panel_elevation": snappedf(elev, 0.1)})
	near(yaw, 35.0, 3.0, "panel opens in the direction the player faces")
	between(elev, -10.0, 0.0, "panel at comfortable eye level, not on the floor")


func test_panel_follows_a_full_about_turn() -> void:
	var p := k.ui.menu_panel
	p.snap_to_head()
	await k.settle(self, 2)
	k.set_head(Vector3(0, Kit.EYE, 0), 180.0)
	p.peak_follow_speed = 0.0
	var t0 := Time.get_ticks_msec()
	var secs := -1.0
	for i in 400:
		await wait_frames(1)
		if absf(rad_to_deg(p.yaw_error())) < 3.0:
			secs = (Time.get_ticks_msec() - t0) / 1000.0
			break
	metric("about_turn", {"seconds": secs, "peak_deg_s": snappedf(p.peak_follow_speed, 0.1)})
	gt(secs, 0.0, "panel ends up in front after a 180 turn")
	lt(secs, 3.0, "within 3 s")
	lt(p.peak_follow_speed, p.follow_max_speed_deg + 0.01, "still speed-capped")


func test_replay_tutorial_mid_run_brings_the_lessons_back() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	check(not k.ui.hud.lesson_visible(), "no lesson after skipping")
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"settings"))
	await k.settle(self, 2)
	await k.click_control(self, k.ui.get_screen(&"settings").get_button(&"replay_tutorial"))
	await k.click_control(self, k.ui.get_screen(&"settings").get_button(&"back"))
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"resume"))
	await k.settle(self, 3)
	eq(Game.state, Game.State.PLAYING, "resumed")
	check(k.ui.onboarding.active, "lessons active again")
	eq(k.ui.onboarding.index, 0, "from lesson 1")
	check(k.ui.hud.lesson_visible(), "lesson card on the HUD")
	eq(k.ui.hud.lesson_title(), Onboarding.LESSONS[0]["title"], "showing lesson 1")


func test_skip_button_hidden_after_tutorial_done_and_back_after_replay() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	var skip := k.ui.get_screen(&"pause").get_button(&"skip_tutorial")
	check(skip.visible, "Skip tutorial offered during the lessons")
	await k.click_control(self, skip)
	await k.settle(self, 2)
	check(not skip.is_visible_in_tree(), "Skip tutorial gone once skipped")
	eq(k.ui.current_screen_id(), &"pause", "still on the pause screen")


func test_idle_session_never_blocks_and_ends_cleanly() -> void:
	# Seven lessons x 45 s of doing nothing at 72 Hz (stepped by hand).
	var path := "user://ui_probe_idle_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new(path)
	add_child(o)
	o.start()
	var fin := [0]
	o.finished.connect(func(_s: bool) -> void: fin[0] += 1)
	var t := {"airspeed": 8.0, "vertical_speed": 0.0, "wing_extension": 0.2, "flapping": 0.0,
		"bank": 0.0, "tucked": false, "perched": false}
	var steps := int((Onboarding.TIMEOUT + Onboarding.CELEBRATE + 0.5) * 7.0 * 72.0)
	for i in steps:
		o.step(1.0 / 72.0, t)
	eq(fin[0], 1, "finished exactly once")
	check(not o.active, "no longer active")
	check(UIProgress.new(path).onboarding_done(), "completion persisted")
	o.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
