extends TestCase
## Verifier probes (round 1), geometry as the eye really sees it:
##  - the cap height of every visible label, measured as the angle between
##    the label's cap top and baseline *points on the quad* from the eye
##    (not at the nominal 1.5 m centre distance), and
##  - HUD placement during growth at a realistic, real-time rate.
## Independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


## Smallest true angular cap height (deg) of any visible label/button under
## root, drawn on `panel`, seen from the camera. Returns [deg, name, text].
func _true_min_cap(panel: UIPanel, root: Node) -> Array:
	var eye := k.cam.global_position
	var best := [999.0, "", ""]
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var txt := ""
		if c is Label:
			txt = (c as Label).text
		elif c is Button:
			txt = (c as Button).text
		if txt.strip_edges().is_empty():
			continue
		var cap := UITheme.cap_height_px(c.get_theme_font("font"), c.get_theme_font_size("font_size"))
		var r := c.get_global_rect()
		# Worst horizontal position of the text inside the control: the end
		# farthest from the panel centre (text spans most of the control).
		var cx := Vector2(panel.panel_size).x * 0.5
		var xs := [r.position.x + 4.0, r.end.x - 4.0, r.get_center().x]
		for x: float in xs:
			var mid := Vector2(x, r.get_center().y)
			var top := panel.pixel_to_world(mid - Vector2(0, cap * 0.5)) - eye
			var bot := panel.pixel_to_world(mid + Vector2(0, cap * 0.5)) - eye
			var deg := rad_to_deg(top.angle_to(bot))
			if deg < best[0]:
				best = [deg, c.name, txt.left(40)]
	return best


func test_true_cap_angle_menus() -> void:
	var overall := 999.0
	var per := {}
	for id: StringName in UIRoot.SCREEN_IDS:
		k.ui.stack = [id]
		k.ui._show_top()
		k.ui.menu_panel.snap_to_head()
		await k.settle(self, 4)
		var r := _true_min_cap(k.ui.menu_panel, k.ui.get_screen(id))
		per[id] = [snappedf(r[0], 0.001), r[1], r[2]]
		overall = minf(overall, r[0])
	metric("true_min_cap_deg_by_screen", per)
	metric("true_min_cap_deg", snappedf(overall, 0.001))
	gt(overall, UITheme.MIN_GLYPH_DEG, "every visible glyph >= 1.5 deg as the eye sees it (min %.3f)" % overall)


func test_true_cap_angle_hud() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	k.ui.hud.set_growth(0.05)
	k.ui.hud.show_lesson(3, 7, Onboarding.LESSONS[3])
	k.ui.hud_panel.snap_to_head()
	await k.settle(self, 4)
	var r := _true_min_cap(k.ui.hud_panel, k.ui.hud)
	metric("hud_true_min_cap", [snappedf(r[0], 0.001), r[1], r[2]])
	gt(r[0], UITheme.MIN_GLYPH_DEG, "HUD glyphs >= 1.5 deg as the eye sees them (min %.3f, %s)" % [r[0], r[2]])


func test_hud_during_realistic_growth() -> void:
	# A tier-up style growth: world_scale 0.33 -> 0.66 over 3 s of real time.
	k.ui.onboarding.skip()
	k.set_world_scale(0.33)
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.hud_panel.snap_to_head()
	await k.settle(self, 2)
	var eye := k.cam.global_position
	var p := k.ui.hud_panel
	var s := Vector2(p.panel_size)
	var ref := rad_to_deg((p.pixel_to_world(Vector2(0, s.y * 0.5)) - eye).angle_to(p.pixel_to_world(Vector2(s.x, s.y * 0.5)) - eye))
	var t0 := Time.get_ticks_msec()
	var worst_size := 0.0
	var worst_elev := 0.0
	var frames := 0
	while true:
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		if t > 3.0:
			break
		k.set_world_scale(lerpf(0.33, 0.66, t / 3.0))
		await wait_frames(1)
		frames += 1
		eye = k.cam.global_position
		var w := rad_to_deg((p.pixel_to_world(Vector2(0, s.y * 0.5)) - eye).angle_to(p.pixel_to_world(Vector2(s.x, s.y * 0.5)) - eye))
		worst_size = maxf(worst_size, absf(w - ref) / ref)
		var to := p.global_position - eye
		worst_elev = maxf(worst_elev, absf(rad_to_deg(asin(to.normalized().y)) + 19.0))
	metric("realistic_growth", {"frames": frames, "max_size_err": snappedf(worst_size, 0.0001), "max_elev_err_deg": snappedf(worst_elev, 0.01)})
	lt(worst_size, 0.02, "HUD apparent size within 2%% during a 3 s doubling (%.4f)" % worst_size)
	lt(worst_elev, 3.0, "HUD stays within 3 deg of its elevation during growth (%.2f)" % worst_elev)
