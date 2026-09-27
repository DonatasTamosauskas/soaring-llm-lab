extends TestCase
## Independent verifier probes for the ui area (round 1). Not part of the
## area suite: run with
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_probe_test
## A failing check here is a finding, not a flaky test.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


# --- contract: process mode, group, XR aim nodes --------------------------------

func test_contract_process_mode_and_group() -> void:
	eq(k.ui.process_mode, Node.PROCESS_MODE_ALWAYS, "UIRoot is PROCESS_MODE_ALWAYS")
	check(k.ui.is_in_group(&"ui_root"), "UIRoot in group ui_root")
	var aims := k.rig.find_children("UIAim_*", "XRController3D", false, false)
	eq(aims.size(), 2, "two UIAim controllers added under the rig in VR mode")
	for a: XRController3D in aims:
		eq(a.process_mode, Node.PROCESS_MODE_ALWAYS, "%s is PROCESS_MODE_ALWAYS (Quest rule 6)" % a.name)
		eq(a.pose, &"aim", "%s uses the aim pose" % a.name)
	eq(k.rig.scale, Vector3.ONE, "rig never scaled (Quest rule 1)")


# --- real input paths while the tree is paused ----------------------------------

func test_controller_menu_button_resumes_while_paused() -> void:
	k.gl.start_run()
	await wait_seconds(0.3)
	k.left.menu_down = true
	await k.settle(self, 2)
	k.left.menu_down = false
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "menu button pauses")
	await wait_seconds(0.3)
	k.left.menu_down = true
	await k.settle(self, 2)
	k.left.menu_down = false
	await k.settle(self, 2)
	eq(Game.state, Game.State.PLAYING, "menu button pressed again while paused resumes")


func test_back_button_pops_while_paused() -> void:
	k.gl.start_run()
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	k.ui.push_screen(&"settings")
	await k.settle(self, 2)
	k.right.back_down = true
	await k.settle(self, 2)
	k.right.back_down = false
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"pause", "B/Y pops Settings back to Pause while the tree is paused")


# --- U1: true glyph angle at the glyph's real position on the quad ---------------

func _text_span_x(c: Control, w: float) -> Vector2:
	var r := c.get_global_rect()
	var align := HORIZONTAL_ALIGNMENT_LEFT
	var pad_l := 0.0
	var pad_r := 0.0
	if c is Label:
		align = (c as Label).horizontal_alignment
	elif c is Button:
		align = (c as Button).alignment
		var sb := c.get_theme_stylebox("normal")
		pad_l = sb.content_margin_left
		pad_r = sb.content_margin_right
	var x0 := r.position.x + pad_l
	var x1 := r.end.x - pad_r
	w = minf(w, x1 - x0)
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			var cx := (x0 + x1) * 0.5
			return Vector2(cx - w * 0.5, cx + w * 0.5)
		HORIZONTAL_ALIGNMENT_RIGHT:
			return Vector2(x1 - w, x1)
	return Vector2(x0, x0 + w)


## Smallest real angular cap height over the text of a control, seen from the
## camera, sampling both ends of the text run (worst corner of the glyph run).
func _true_min_deg(panel: UIPanel, c: Control, font: Font, fs: int, txt: String) -> float:
	var cap := UITheme.cap_height_px(font, fs)
	var w := 0.0
	for line in txt.split("\n"):
		w = maxf(w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var span := _text_span_x(c, w)
	var r := c.get_global_rect()
	var eye := k.cam.global_position
	var out := 999.0
	# Multi-line labels: sample the first and last line band.
	var n_lines := maxi(1, txt.split("\n").size())
	if c is Label and (c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF:
		n_lines = maxi(n_lines, (c as Label).get_line_count())
	var ys := [r.get_center().y]
	if n_lines > 1:
		ys = [r.position.y + r.size.y / n_lines * 0.5, r.end.y - r.size.y / n_lines * 0.5]
	for y: float in ys:
		for x: float in [span.x, span.y]:
			var a := panel.pixel_to_world(Vector2(x, y - cap * 0.5)) - eye
			var b := panel.pixel_to_world(Vector2(x, y + cap * 0.5)) - eye
			out = minf(out, rad_to_deg(a.angle_to(b)))
	return out


func _items(root: Node) -> Array:
	var out := []
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
		out.append([c, c.get_theme_font("font"), c.get_theme_font_size("font_size"), txt])
	return out


func _worst_ctx() -> Dictionary:
	return {
		"player_mass": SizeRules.SPECIES[4]["mass"], "best_score": 1234567, "tutorial_active": true,
		"predator_name": "Starling", "respawn_in": 3.0,
		"stats": {"lives": 3, "lives_max": 3, "catches": 123, "time": 5999.0},
		"summary": {"score": 1234567, "time": 5999.0, "max_mass": 0.09,
			"catches_by_species": {&"starling": 12, &"swallow": 30, &"sparrow": 45, &"wren": 99, &"moth": 120, &"pigeon": 3}},
		"new_best": true,
	}


func test_true_glyph_angle_on_the_quad() -> void:
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 2)
	var overall := 999.0
	var below := 0
	var total := 0
	var worst_all := ""
	for id: StringName in UIRoot.SCREEN_IDS:
		k.ui.stack = [id]
		k.ui._show_top()
		var s := k.ui.get_screen(id)
		var ctx := k.ui.context()
		ctx.merge(_worst_ctx(), true)
		s.refresh(ctx)
		await k.settle(self, 4)
		var mn := 999.0
		var worst := ""
		for it in _items(s):
			var d := _true_min_deg(k.ui.menu_panel, it[0], it[1], it[2], it[3])
			total += 1
			if d < UITheme.MIN_GLYPH_DEG:
				below += 1
			if d < mn:
				mn = d
				worst = "%s '%s' %dpx" % [(it[0] as Control).name, it[3], it[2]]
		metric("true_min_glyph_deg_%s" % id, snappedf(mn, 0.001))
		metric("worst_%s" % id, worst)
		check(mn >= UITheme.MIN_GLYPH_DEG, "%s: true smallest glyph %.3f deg >= 1.5 (%s)" % [id, mn, worst])
		if mn < overall:
			overall = mn
			worst_all = "%s: %s" % [id, worst]
	metric("true_min_glyph_deg_menus", snappedf(overall, 0.001))
	metric("text_items_below_1_5_deg", "%d of %d" % [below, total])
	metric("worst_overall", worst_all)


func test_true_glyph_angle_on_hud() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	var hud := k.ui.hud
	hud.set_growth(0.05)
	hud.show_lesson(1, 7, Onboarding.LESSONS[1])
	await k.settle(self, 3)
	k.ui.hud_panel.snap_to_head()
	await k.settle(self, 2)
	var mn := 999.0
	var worst := ""
	for it in _items(hud):
		var d := _true_min_deg(k.ui.hud_panel, it[0], it[1], it[2], it[3])
		if d < mn:
			mn = d
			worst = "%s '%s' %dpx" % [(it[0] as Control).name, it[3], it[2]]
	metric("true_min_glyph_deg_hud", snappedf(mn, 0.001))
	metric("worst_hud", worst)
	check(mn >= UITheme.MIN_GLYPH_DEG, "HUD: true smallest glyph %.3f deg >= 1.5 (%s)" % [mn, worst])


# --- Settings: segmented choice shows exactly one selection -----------------------

func test_choice_toggle_single_selection_after_external_change() -> void:
	Settings.set_value("seated", false)
	k.ui.push_screen(&"settings")
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	var standing := ss.get_stance().get_option_button("standing")
	var seated := ss.get_stance().get_option_button("seated")
	check(standing.button_pressed and not seated.button_pressed, "standing selected initially")
	k.ui.pop_screen()
	await k.settle(self, 2)
	# Another area (e.g. VR calibration) changes the value, then the player
	# opens Settings again.
	Settings.set_value("seated", true)
	k.ui.push_screen(&"settings")
	await k.settle(self, 3)
	metric("standing_pressed", standing.button_pressed)
	metric("seated_pressed", seated.button_pressed)
	check(seated.button_pressed, "seated shown as selected")
	check(not standing.button_pressed, "standing no longer shown as selected (exactly one option lit)")


# --- Summary: "New best!" must agree with the GameLoop's records ------------------

func test_new_best_badge_agrees_with_game_loop_records() -> void:
	# A GameLoop like the real one keeps its own records: best 5000 from an
	# earlier run (e.g. quit to menu, which still counts bests), and ends this
	# run with 3000 and new_records.score = false.
	k.gl.stats["best_score"] = 5000
	k.gl.start_run()
	await k.settle(self, 2)
	k.gl.fake_end({"score": 3000, "best_score": 5000, "new_records": {"score": false}})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	var badge := ss.find_child("NewBest", true, false) as Label
	var best_label := ""
	for l in ss.find_children("*", "Label", true, false):
		if (l as Label).text == "5 000":
			best_label = "5 000"
	metric("badge_visible", badge.visible)
	metric("best_shown", best_label)
	eq(best_label, "5 000", "Best shows the GameLoop's 5 000")
	check(not badge.visible, "no 'New best!' when the score (3 000) is below the best (5 000)")


# --- U7: what does the SubViewport's update mode read after a one-off render ------

func test_update_mode_after_request() -> void:
	var p := k.ui.menu_panel
	p.mark_dirty()
	await wait_frames(5)
	metric("menu_update_mode_5_frames_after_request", p.get_viewport_node().render_target_update_mode)
	metric("active_viewport_count_idle_menu", k.ui.active_viewport_count())
	check(true, "recorded")
