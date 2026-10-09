extends TestCase
## U1 (computed half) - every piece of text on every screen and the HUD:
## cap-height visual angle >= 1.5 degrees *as the eye sees it* (each text
## run measured at its real position on the real curved panel, from the real
## camera, using the real font's glyph outline), WCAG contrast >= 4.5:1
## against the worst background it can sit on, and no text overflowing its
## control or the panel, in worst-case content (apex headline, new best,
## seven-digit scores, every species caught, every tier).
## The screenshot half of U1 lives in tests/shots/ui_shots.gd.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
## The brief's bars, as literals: the checks below never read them from
## UITheme, so lowering UITheme's constants to get green cannot pass (the
## round-5 engineering verifier's mutations B2/B3/L2 did exactly that).
const BRIEF_GLYPH_DEG := 1.5
const BRIEF_CONTRAST := 4.5

var k: Kit


func before_all() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_all() -> void:
	k.teardown()
	await wait_frames(2)


## Every text-bearing Control under root that is visible: [control, font, size].
static func text_items(root: Node) -> Array:
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


func _show(id: StringName, ctx_patch: Dictionary = {}) -> UIScreen:
	var s := k.ui.get_screen(id)
	k.ui.stack = [id]
	k.ui._show_top()
	if not ctx_patch.is_empty():
		var ctx := k.ui.context()
		ctx.merge(ctx_patch, true)
		s.refresh(ctx)
	await k.settle(self, 4)
	return s


func _worst_case_ctx() -> Dictionary:
	# Longest strings the screens can show: long species names, big numbers.
	return {
		"player_mass": SizeRules.SPECIES[4]["mass"],
		"best_score": 1234567,
		"tutorial_active": true,
		"predator_name": "Starling",
		"predator_species": &"starling",
		"respawn_in": 3.0,
		"stats": {"lives": 3, "lives_max": 3, "catches": 123, "time": 5999.0,
			"apex": {"catches": 4, "needed": 5, "victory": false}},
		"summary": {"score": 1234567, "time": 5999.0, "max_mass": 0.09,
			"catches_by_species": {&"starling": 12, &"swallow": 30, &"sparrow": 45, &"wren": 99, &"moth": 120, &"pigeon": 3}},
		"new_best": true,
	}


## The run everyone hopes to end on: the apex headline, a new best, a huge
## score and every species on the ladder caught.
func _apex_ctx() -> Dictionary:
	var by := {}
	for i in SizeRules.SPECIES.size() - 1:
		by[SizeRules.SPECIES[i]["id"]] = 100 + i
	return {
		"player_mass": 3.2, "best_score": 1234567, "tutorial_active": false,
		"predator_name": "Eagle", "predator_species": &"eagle", "respawn_in": 3.0,
		"stats": {"lives": 3, "lives_max": 3, "catches": 999, "time": 5999.0},
		"summary": {"score": 1234567, "time": 5999.0, "max_mass": 3.2, "max_tier": 9, "catches_by_species": by},
		"new_best": true,
	}


## A won run: the victory headline and the three buttons (Keep flying).
func _victory_ctx() -> Dictionary:
	var c := _apex_ctx()
	c["summary"] = (c["summary"] as Dictionary).duplicate()
	c["summary"]["victory"] = true
	c["summary"]["reason"] = &"victory"
	return c


## Every context a screen is checked in: the worst-case strings, the apex
## run, a victory, and (pause) every rung of the ladder, with the apex goal
## at the top.
func _contexts(id: StringName) -> Array:
	var out := [_worst_case_ctx(), _apex_ctx(), _victory_ctx()]
	if id == &"pause":
		for i in SizeRules.SPECIES.size():
			for f: float in [1.0, 1.05, 1.2]:
				var c := _worst_case_ctx()
				c["player_mass"] = float(SizeRules.SPECIES[i]["mass"]) * f
				out.append(c)
	return out


## Horizontal extent (panel px) of a text line of width w inside control c,
## honouring alignment and button padding.
static func text_span_x(c: Control, w: float) -> Vector2:
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


## Cap-height bands (top y, bottom y in panel px) of the first and last
## visible line of the text, from the control's real line layout.
static func cap_bands(c: Control, font: Font, fs: int, txt: String) -> Array:
	var cap := UITheme.cap_height_px(font, fs)
	var r := c.get_global_rect()
	var asc := font.get_ascent(fs)
	var bands := []
	if c is Label:
		var l := c as Label
		var lines := maxi(1, l.get_visible_line_count())
		var lh := float(l.get_line_height())
		var spacing := float(l.get_theme_constant("line_spacing"))
		var total := lines * lh + (lines - 1) * spacing
		var y0 := r.position.y
		match l.vertical_alignment:
			VERTICAL_ALIGNMENT_CENTER:
				y0 += floorf((r.size.y - total) * 0.5)
			VERTICAL_ALIGNMENT_BOTTOM:
				y0 += r.size.y - total
		for i: int in ([0] if lines == 1 else [0, lines - 1]):
			var base := y0 + i * (lh + spacing) + asc
			bands.append(Vector2(base - cap, base))
	else:
		var sb := c.get_theme_stylebox("normal")
		var top := r.position.y + sb.content_margin_top
		var h := r.size.y - sb.content_margin_top - sb.content_margin_bottom
		var base := top + (h - font.get_height(fs)) * 0.5 + asc
		bands.append(Vector2(base - cap, base))
	return bands


## Smallest visual angle (deg) of the text's cap height as the eye sees it:
## both ends of the widest line, on its first and last line, projected from
## the panel's pixels to world space and measured from the camera.
func true_min_deg(panel: UIPanel, c: Control, font: Font, fs: int, txt: String) -> float:
	var w := 0.0
	for line in txt.split("\n"):
		w = maxf(w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var span := text_span_x(c, w)
	var eye := k.cam.global_position
	var out := 999.0
	for band: Vector2 in cap_bands(c, font, fs, txt):
		for x: float in [span.x, span.y]:
			var a := panel.pixel_to_world(Vector2(x, band.x)) - eye
			var b := panel.pixel_to_world(Vector2(x, band.y)) - eye
			out = minf(out, rad_to_deg(a.angle_to(b)))
	return out


func test_glyph_angle_where_the_text_sits_on_every_screen() -> void:
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 2)
	var overall := 999.0
	var total := 0
	var below := 0
	for id: StringName in UIRoot.SCREEN_IDS:
		var min_deg := 999.0
		var worst := ""
		for ctx: Dictionary in _contexts(id):
			var s := await _show(id, ctx)
			for it in text_items(s):
				var deg := true_min_deg(k.ui.menu_panel, it[0], it[1], it[2], it[3])
				total += 1
				if deg < BRIEF_GLYPH_DEG:
					below += 1
				if deg < min_deg:
					min_deg = deg
					worst = "%s '%s' (%d px)" % [(it[0] as Control).name, it[3], it[2]]
		check(min_deg >= BRIEF_GLYPH_DEG, "%s: smallest glyph as seen %.3f deg >= 1.5 (%s)" % [id, min_deg, worst])
		metric("min_glyph_deg_%s" % id, snappedf(min_deg, 0.001))
		metric("worst_%s" % id, worst)
		overall = minf(overall, min_deg)
	metric("min_glyph_deg_all_menus", snappedf(overall, 0.001))
	metric("text_runs_checked", total)
	eq(below, 0, "no text run anywhere is below 1.5 deg (%d of %d)" % [below, total])


func test_glyph_angle_where_the_text_sits_on_hud() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	var hud := k.ui.hud
	k.ui.hud_panel.snap_to_head()
	var min_deg := 999.0
	var worst := ""
	# Every lesson card (longest hints) and every tier on the growth strip.
	for i in Onboarding.LESSONS.size():
		hud.set_growth(float(SizeRules.SPECIES[mini(i + 2, 9)]["mass"]) * 1.05)
		hud.show_lesson(i, Onboarding.LESSONS.size(), Onboarding.LESSONS[i])
		await k.settle(self, 3)
		for it in text_items(hud):
			var deg := true_min_deg(k.ui.hud_panel, it[0], it[1], it[2], it[3])
			if deg < min_deg:
				min_deg = deg
				worst = "%s '%s' (%d px)" % [(it[0] as Control).name, it[3], it[2]]
	hud.show_tier_up(4, 5)
	await k.settle(self, 3)
	for it in text_items(hud):
		min_deg = minf(min_deg, true_min_deg(k.ui.hud_panel, it[0], it[1], it[2], it[3]))
	# The top of the ladder: the apex goal on the strip and its toasts.
	hud.set_apex({"catches": 3, "needed": 5, "won": false})
	hud.set_growth(3.2)
	hud.show_tier_up(8, 9, 3.2)
	await k.settle(self, 3)
	for it in text_items(hud):
		min_deg = minf(min_deg, true_min_deg(k.ui.hud_panel, it[0], it[1], it[2], it[3]))
	hud.show_apex_progress(3, 5)
	await k.settle(self, 3)
	for it in text_items(hud):
		min_deg = minf(min_deg, true_min_deg(k.ui.hud_panel, it[0], it[1], it[2], it[3]))
	hud.set_apex({})
	check(min_deg >= BRIEF_GLYPH_DEG, "HUD smallest glyph as seen %.3f deg >= 1.5 (%s)" % [min_deg, worst])
	metric("min_glyph_deg_hud", snappedf(min_deg, 0.001))
	metric("worst_hud", worst)
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_body_text_legible_anywhere_on_either_panel() -> void:
	# Layout-independent guarantee: body-size text placed *anywhere* inside
	# the panels' 20 px safe margin clears 1.5 deg (this also covers text the
	# illustrations draw at FS_BODY). A flat panel would fail at the corners.
	var cap := UITheme.cap_height_px(UITheme.font(700), UITheme.FS_BODY)
	k.gl.start_run()
	await k.settle(self, 2)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var eye := k.cam.global_position
	var result := {}
	for p: UIPanel in [k.ui.menu_panel, k.ui.hud_panel]:
		p.show_panel()
		p.snap_to_head()
		var mn := 999.0
		var sz := Vector2(p.panel_size)
		for gx in 13:
			for gy in 9:
				var px := Vector2(lerpf(20.0, sz.x - 20.0, gx / 12.0), lerpf(20.0 + cap, sz.y - 20.0, gy / 8.0))
				# Only where the panel is shown (the HUD's bands).
				if not (p.is_row_shown(px.y - cap) and p.is_row_shown(px.y)):
					continue
				var a := p.pixel_to_world(px - Vector2(0, cap)) - eye
				var b := p.pixel_to_world(px) - eye
				mn = minf(mn, rad_to_deg(a.angle_to(b)))
		result[p.name] = snappedf(mn, 0.001)
		check(mn >= BRIEF_GLYPH_DEG, "%s: body text anywhere >= 1.5 deg (min %.3f)" % [p.name, mn])
	metric("body_min_deg_anywhere", result)
	# The same text on a flat quad would not make it (why the panels curve).
	var flat := rad_to_deg((Vector3(0.66, 0.43 - cap / UITheme.PX_PER_M, -1.5)).angle_to(Vector3(0.66, 0.43, -1.5)))
	metric("flat_panel_corner_deg", snappedf(flat, 0.001))
	lt(flat, BRIEF_GLYPH_DEG, "a flat panel's corner would be below 1.5 deg (%.3f), which is why the panels curve" % flat)
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_the_theme_states_the_brief_bars() -> void:
	# UITheme's own bars (used to size things) must say what the brief says;
	# the checks in this suite use the literals above either way.
	eq(UITheme.MIN_GLYPH_DEG, 1.5, "UITheme.MIN_GLYPH_DEG is the brief's 1.5 deg")
	eq(UITheme.MIN_CONTRAST, 4.5, "UITheme.MIN_CONTRAST is the brief's 4.5:1")


func test_hud_text_keeps_its_size_wherever_the_notices_move() -> void:
	# Notices live 10-52 deg right of the flight path and may move to the
	# mirror placement on its left (and slide through everything between),
	# by turning their band about the eye: every glyph keeps exactly its
	# visual angle, and the layout for the left side (text on the inner
	# side) is as legible.
	k.gl.start_run()
	await k.settle(self, 3)
	var hud := k.ui.hud
	var p := k.ui.hud_panel
	p.snap_to_head()
	var measure := func() -> float:
		var mn := 999.0
		for it in text_items(hud):
			var c := it[0] as Control
			if p.band_of_row(c.get_global_rect().get_center().y) != HUD.BAND_NOTICE:
				continue
			mn = minf(mn, true_min_deg(p, c, it[1], it[2], it[3]))
		return mn
	var rows := {}
	for what: String in ["lesson", "toast"]:
		if what == "lesson":
			hud.show_lesson(6, Onboarding.LESSONS.size(), Onboarding.LESSONS[6])
		else:
			hud.show_tier_up(4, 5)
		await k.settle(self, 3)
		p.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
		var home: float = measure.call()
		for off: Vector2 in [HUD.NOTICE_MIRROR, HUD.NOTICE_MIRROR * 0.5, Vector2(-12, 8)]:
			p.set_band_offset(HUD.BAND_NOTICE, off)
			if off == HUD.NOTICE_MIRROR:
				# At rest on the left the text moves to the inner side.
				hud.set_notice_side(-1)
				await k.settle(self, 2)
			var deg: float = measure.call()
			rows["%s %s" % [what, off]] = snappedf(deg, 0.0001)
			near(deg, home, 0.001, "%s moved by %s: glyphs keep their angle (%.4f vs %.4f deg)" % [what, off, deg, home])
			check(deg >= BRIEF_GLYPH_DEG, "%s moved by %s: >= 1.5 deg" % [what, off])
		p.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
		hud.set_notice_side(1)
		await k.settle(self, 2)
	metric("notice_glyph_deg_by_offset", rows)
	hud.cancel_toast()
	hud.hide_lesson()
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_drawn_mesh_matches_the_analytic_surface() -> void:
	# The pointer and every angle measured here use the analytic cylinder;
	# the mesh the GPU draws must lie on it: vertices exactly, chords within
	# 0.5 mm (32 strips). Also for a notice band moved off its home.
	k.gl.start_run()
	await k.settle(self, 3)
	var rows := {}
	for pass_i in 2:
		if pass_i == 1:
			k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2(12, 8))
		for panel: UIPanel in [k.ui.menu_panel, k.ui.hud_panel]:
			var worst_v := 0.0
			var worst_mid := 0.0
			var strips := 0
			for bi in panel.band_count():
				var mi := panel.band_mesh(bi)
				var arr := mi.mesh.surface_get_arrays(0)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
				for i in verts.size():
					worst_v = maxf(worst_v, (mi.transform * verts[i]).distance_to(panel.local_point(uvs[i])))
				# Top edge of every strip: chord midpoint vs the true arc.
				for t in range(0, verts.size(), 6):
					strips += 1
					var mid := mi.transform * ((verts[t] + verts[t + 1]) * 0.5)
					worst_mid = maxf(worst_mid, mid.distance_to(panel.local_point((uvs[t] + uvs[t + 1]) * 0.5)))
			var key := "%s%s" % [panel.name, " (notices moved)" if pass_i == 1 else ""]
			rows[key] = {"vertex_err_mm": snappedf(worst_v * 1000.0, 0.001), "chord_err_mm": snappedf(worst_mid * 1000.0, 0.001), "strips": strips}
			lt(worst_v, 1e-4, "%s: vertices on the analytic surface (%.4f mm)" % [key, worst_v * 1000.0])
			lt(worst_mid, 5e-4, "%s: chords within 0.5 mm of it (%.3f mm)" % [key, worst_mid * 1000.0])
			check(strips >= 32 * panel.band_count(), "%s: at least 32 strips per band (%d)" % [key, strips])
	metric("mesh_vs_surface", rows)
	k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_settings_status_messages_fit_and_are_legible() -> void:
	# The only feedback for Recalibrate / Recenter / Replay tutorial is a
	# status line beside "Replay tutorial". Round 3: one message (820 px in
	# a 716 px slot) widened its row and pushed Back, every percentage and
	# "Right" off the panel for 4 s. Every message, in place.
	k.ui.menu_panel.snap_to_head()
	var st := await _show(&"settings") as SettingsScreen
	var rows := {}
	for text: String in SettingsScreen.STATUS_TEXTS:
		st.show_status(text)
		await k.settle(self, 3)
		var l := st.status_label()
		var w := l.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x
		var deg := true_min_deg(k.ui.menu_panel, l, l.get_theme_font("font"), l.get_theme_font_size("font_size"), text)
		rows[text] = {"text_px": int(w), "slot_px": int(l.size.x), "deg": snappedf(deg, 0.001)}
		lt(w, l.size.x + 0.5, "'%s' fits its slot untrimmed (%.0f <= %.0f px)" % [text, w, l.size.x])
		check(deg >= BRIEF_GLYPH_DEG, "'%s' legible (%.3f deg)" % [text, deg])
		_check_all_inside(StringName("settings '%s'" % text), st)
		_check_no_overflow(StringName("settings '%s'" % text), st)
	metric("settings_status", rows)
	# However long a future message, the row never widens (it is trimmed).
	var back_x := st.get_button(&"back").get_global_rect().end.x
	st.show_status("A status message far longer than any slot on this screen could hold")
	await k.settle(self, 3)
	near(st.get_button(&"back").get_global_rect().end.x, back_x, 0.5, "a too-long message moves nothing")
	_check_all_inside(&"settings (too-long status)", st)
	st.show_status("")


func test_type_scale_constants() -> void:
	# The theme's smallest size must clear the bar on its own, with margin.
	var cap := UITheme.cap_height_px(UITheme.font(700), UITheme.FS_BODY)
	var deg := UITheme.px_to_deg(cap, UITheme.PANEL_DISTANCE)
	metric("body_cap_px", cap)
	metric("body_cap_deg", deg)
	between(cap / UITheme.FS_BODY, 0.66, 0.78, "cap height ratio of the shipped font is sane")
	gt(deg, BRIEF_GLYPH_DEG * 1.03, "body text clears 1.5 deg with >= 3% margin")


func test_contrast_all_text_pairs() -> void:
	var white := Color.WHITE
	var black := Color.BLACK
	var sky := UITheme.SKY
	# Menu panels are 94% opaque: composite the lightest facet over the
	# brightest possible world behind it (white) and over black.
	var panel_bgs := {
		"panel/white": UITheme.over(Color(UITheme.PANEL, UITheme.PANEL_ALPHA), white),
		"facet/white": UITheme.over(Color(UITheme.FACET_LIGHT, UITheme.PANEL_ALPHA), white),
		"facet/black": UITheme.over(Color(UITheme.FACET_LIGHT, UITheme.PANEL_ALPHA), black),
	}
	var panel_text := {"TEXT": UITheme.TEXT, "TEXT_DIM": UITheme.TEXT_DIM, "ACCENT": UITheme.ACCENT,
		"PREY": UITheme.PREY, "THREAT_TEXT": UITheme.THREAT_TEXT}
	var worst := 99.0
	for tn in panel_text:
		for bn in panel_bgs:
			var c := UITheme.contrast(panel_text[tn], panel_bgs[bn])
			check(c >= BRIEF_CONTRAST, "%s on %s: %.2f >= 4.5" % [tn, bn, c])
			worst = minf(worst, c)
	# Buttons (opaque fills).
	var pairs := [
		["TEXT on BUTTON", UITheme.TEXT, UITheme.BUTTON],
		["TEXT on BUTTON_HOVER", UITheme.TEXT, UITheme.BUTTON_HOVER],
		["INK on BUTTON_PRESSED", UITheme.INK, UITheme.BUTTON_PRESSED],
		["INK on ACCENT (primary)", UITheme.INK, UITheme.ACCENT],
		["INK on ACCENT hover", UITheme.INK, UITheme.ACCENT.lightened(0.2)],
		["TEXT_DIM on transparent tab over facet", UITheme.TEXT_DIM, panel_bgs["facet/white"]],
	]
	for p in pairs:
		var c := UITheme.contrast(p[1], p[2])
		check(c >= BRIEF_CONTRAST, "%s: %.2f >= 4.5" % [p[0], c])
		worst = minf(worst, c)
	# HUD plates over anything the world can show. Desktop blends in sRGB;
	# in VR the quad blends with the world in linear light (worse for a dark
	# plate over a bright sky) and then the Filmic tonemapper runs on the mix
	# (the panel colours themselves are pre-compensated, see UITonemap).
	# Worst case for Quest: Mobile renderer clips the colour buffer at 2.0.
	var filmic := {"mode": Environment.TONE_MAPPER_FILMIC, "white": 6.0, "exposure": 1.0, "max_input": UITonemap.MOBILE_MAX_INPUT}
	for bg: Color in [white, sky, black, Color("5d9e4a")]:
		var plate := UITheme.over(Color(UITheme.HUD_PLATE, UITheme.HUD_PLATE_ALPHA), bg)
		var pl := UITonemap.compensate(UITheme.HUD_PLATE, filmic).srgb_to_linear()
		var bl := bg.srgb_to_linear()
		var a := UITheme.HUD_PLATE_ALPHA
		var mix_lin := Color(pl.r * a + bl.r * (1.0 - a), pl.g * a + bl.g * (1.0 - a), pl.b * a + bl.b * (1.0 - a))
		var plate_vr := UITonemap.apply(mix_lin.linear_to_srgb(), filmic)
		for tc: Color in [UITheme.TEXT, UITheme.TEXT_DIM, UITheme.ACCENT, UITheme.PREY]:
			var c := UITheme.contrast(tc, plate)
			check(c >= BRIEF_CONTRAST, "HUD %s over plate on %s (desktop): %.2f" % [tc.to_html(false), bg.to_html(false), c])
			# Text as the headset shows it (compensated, then clipped by Mobile).
			var tv := UITonemap.apply(UITonemap.compensate(tc, filmic), filmic)
			var cv := UITheme.contrast(tv, plate_vr)
			check(cv >= BRIEF_CONTRAST, "HUD %s over plate on %s (VR, linear blend + Filmic): %.2f" % [tc.to_html(false), bg.to_html(false), cv])
			worst = minf(worst, minf(c, cv))
	# Menu text on panels/buttons as a Quest shows it (Mobile clip at 2.0).
	for p in [["TEXT", UITheme.TEXT, UITheme.BUTTON], ["TEXT", UITheme.TEXT, UITheme.PANEL],
			["TEXT_DIM", UITheme.TEXT_DIM, UITheme.FACET_LIGHT], ["ACCENT", UITheme.ACCENT, UITheme.FACET_LIGHT],
			["PREY", UITheme.PREY, UITheme.FACET_LIGHT], ["THREAT_TEXT", UITheme.THREAT_TEXT, UITheme.FACET_LIGHT],
			["INK on ACCENT", UITheme.INK, UITheme.ACCENT]]:
		var fg := UITonemap.apply(UITonemap.compensate(p[1], filmic), filmic)
		var bgc := UITonemap.apply(UITonemap.compensate(p[2], filmic), filmic)
		var c := UITheme.contrast(fg, bgc)
		check(c >= BRIEF_CONTRAST, "Quest (Mobile clip): %s on %s: %.2f" % [p[0], (p[2] as Color).to_html(false), c])
		worst = minf(worst, c)
	metric("worst_contrast", snappedf(worst, 0.01))


func test_text_uses_only_theme_colours() -> void:
	# Every text colour actually applied on screen must be one of the checked
	# palette entries (so the contrast test above covers reality).
	var allowed := [UITheme.TEXT, UITheme.TEXT_DIM, UITheme.ACCENT, UITheme.PREY, UITheme.THREAT_TEXT, UITheme.INK]
	for id: StringName in UIRoot.SCREEN_IDS:
		var s := await _show(id, _worst_case_ctx())
		for it in text_items(s):
			var c := it[0] as Control
			var col := c.get_theme_color("font_color")
			var ok := false
			for a: Color in allowed:
				if col.is_equal_approx(a):
					ok = true
			check(ok, "%s/%s text colour %s is a checked palette colour" % [id, c.name, col.to_html()])


## Every visible Control of a screen (bars, icons, buttons, not only text)
## must lie inside the screen's own content margins (its MarginContainer's
## inner rect), so nothing crowds the panel's border or spills off it.
func _check_all_inside(id: StringName, s: UIScreen) -> void:
	var m := s.get_node_or_null("Margin") as MarginContainer
	var inner := Rect2(Vector2(20, 20), Vector2(UITheme.MENU_SIZE) - Vector2(40, 40))
	if m:
		# From the panel's rect, not the container's: a container pushed
		# wider by its content must not widen its own allowance.
		var r0 := Rect2(Vector2.ZERO, Vector2(UITheme.MENU_SIZE))
		var l := m.get_theme_constant("margin_left")
		var t := m.get_theme_constant("margin_top")
		inner = Rect2(r0.position + Vector2(l, t), r0.size - Vector2(l + m.get_theme_constant("margin_right"), t + m.get_theme_constant("margin_bottom")))
	for n in s.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree() or c is FacetBackground or c is MarginContainer or c.size == Vector2.ZERO:
			continue
		var r := c.get_global_rect()
		check(inner.grow(1.0).encloses(r), "%s/%s inside the content margins %s (%s)" % [id, c.name, inner, r])


func test_every_control_inside_panel() -> void:
	for id: StringName in UIRoot.SCREEN_IDS:
		for ctx: Dictionary in _contexts(id):
			var s := await _show(id, ctx)
			_check_all_inside(id, s)
	# The pause screen shows a new tip per pause: every tip must fit.
	for i in PauseScreen.TIPS.size():
		(k.ui.get_screen(&"pause") as PauseScreen).next_tip()
		var s := await _show(&"pause", _worst_case_ctx())
		_check_all_inside(&"pause tip %d" % i, s)
		var tip := s.find_child("Tip", true, false) as Label
		check(tip.get_line_count() == 1, "tip '%s' fits one line (%d)" % [tip.text, tip.get_line_count()])


func test_no_text_overflows() -> void:
	for id: StringName in UIRoot.SCREEN_IDS:
		for ctx: Dictionary in _contexts(id):
			_check_no_overflow(id, await _show(id, ctx))


func _check_no_overflow(id: StringName, s: UIScreen) -> void:
	for it in text_items(s):
		var c := it[0] as Control
		var f: Font = it[1]
		var fs: int = it[2]
		var txt: String = it[3]
		if c is Label and (c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF:
			continue
		var w := 0.0
		for line in txt.split("\n"):
			w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		var avail := c.size.x
		if c is Button:
			var sb := c.get_theme_stylebox("normal")
			avail -= sb.content_margin_left + sb.content_margin_right
		check(w <= avail + 1.0, "%s/%s '%s' fits (%.0f <= %.0f px)" % [id, c.name, txt, w, avail])
		# And the control stays inside the panel.
		var r := c.get_global_rect()
		check(r.position.x >= -1.0 and r.end.x <= UITheme.MENU_SIZE.x + 1.0 and r.position.y >= -1.0 and r.end.y <= UITheme.MENU_SIZE.y + 1.0,
			"%s/%s inside the panel (%s)" % [id, c.name, r])


func _check_hud_inside(tag: String) -> void:
	var hud := k.ui.hud
	var p := k.ui.hud_panel
	for it in text_items(hud):
		var c := it[0] as Control
		var w: float = (it[1] as Font).get_string_size(it[3], HORIZONTAL_ALIGNMENT_LEFT, -1, it[2]).x
		check(w <= c.size.x + 1.0, "%s: HUD '%s' fits its label (%.0f <= %.0f)" % [tag, it[3], w, c.size.x])
		var r := c.get_global_rect()
		# In VR only the HUD's bands are shown: text must lie wholly inside
		# one band's rows (and the texture), or it is cut off.
		var bi := p.band_of_row(r.get_center().y)
		var rows := p.band_rows(bi)
		var band := Rect2(0.0, rows.x, float(UITheme.HUD_SIZE.x), rows.y - rows.x)
		check(band.grow(1.0).encloses(r), "%s: HUD '%s' inside band %d (%s in %s)" % [tag, it[3], bi, r, band])
	# The plates too (a plate straddling two bands would be cut in half).
	for bi in 2:
		for plate: Control in hud.band_plates(bi):
			var rows := p.band_rows(bi)
			var pr := plate.get_global_rect()
			check(pr.position.y >= rows.x - 1.0 and pr.end.y <= rows.y + 1.0, "%s: %s plate inside band %d (%s)" % [tag, plate.name, bi, pr])


## Every line of the celebration shown now, at the size it is drawn, is
## at most HUD.TOAST_TEXT_W (680 px) wide: the plate's text then ends 39 deg
## from the flight path at home, inside a Quest Pro's sharp view
## (ui_hud_test measures where the words land).
func _check_toast_width(tag: String) -> void:
	for lbl: Label in k.ui.hud.toast_labels():
		if not lbl.visible or lbl.text == "":
			continue
		var w := lbl.get_theme_font(&"font").get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		lt(w, HUD.TOAST_TEXT_W + 0.5, "%s: celebration line '%s' %.0f px <= %.0f" % [tag, lbl.text, w, HUD.TOAST_TEXT_W])


func test_hud_text_fits_all_species() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hud := k.ui.hud
	for i in SizeRules.SPECIES.size():
		hud.set_growth(SizeRules.SPECIES[i]["mass"] * 1.01)
		hud.show_tier_up(i - 1, i, SizeRules.SPECIES[i]["mass"] * 1.01)
		await k.settle(self, 3)
		_check_hud_inside("tier %d up" % i)
		_check_toast_width("tier %d up" % i)
		hud.show_tier_up(i + 1, i)
		await k.settle(self, 3)
		_check_hud_inside("tier %d down" % i)
	# The apex goal: strip, eagle toast (goal line), progress toast, a won run.
	for goal: Dictionary in [{"catches": 4, "needed": 5, "won": false}, {"catches": 5, "needed": 5, "won": true}]:
		hud.set_apex(goal)
		hud.set_growth(3.3)
		hud.show_tier_up(8, 9, 3.3)
		await k.settle(self, 3)
		_check_hud_inside("eagle %s" % str(goal))
	hud.show_apex_progress(4, 5)
	await k.settle(self, 3)
	_check_hud_inside("apex progress")
	_check_toast_width("apex progress")
	# The celebration's lines, as toast_lines() reports them, all fit its plate.
	for line: String in hud.toast_lines():
		var tw := UITheme.font(700).get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_BODY).x
		lt(tw, HUD.TOAST_TEXT_W + 0.5, "toast line '%s' fits the plate at body size" % line)
	eq(hud.toast_lines()[0], "4 of 5!", "toast_lines starts with the headline")
	hud.set_apex({})
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_hud_lessons_fit_the_viewport() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hud := k.ui.hud
	var card := hud.get_node("Lesson") as Control
	for i in Onboarding.LESSONS.size():
		hud.show_lesson(i, Onboarding.LESSONS.size(), Onboarding.LESSONS[i])
		await k.settle(self, 3)
		_check_hud_inside("lesson %s" % Onboarding.LESSONS[i]["id"])
		# Every line fits the card's text column (round 6: 604 px, so the
		# words end within 35 deg of a level gaze), and the card never
		# grows past its width to make room.
		for l: Label in hud.lesson_labels():
			var w := l.get_theme_font(&"font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size(&"font_size")).x
			check(w <= HUD.CARD_TEXT_W, "lesson %s: '%s' fits the text column (%.0f <= %.0f px)" % [Onboarding.LESSONS[i]["id"], l.text, w, HUD.CARD_TEXT_W])
		near(card.size.x, HUD.CARD_W, 0.5, "lesson %s: the card keeps its width" % Onboarding.LESSONS[i]["id"])
		hud.lesson_done(i % 2 == 0)
		await k.settle(self, 2)
		_check_hud_inside("lesson %s done" % Onboarding.LESSONS[i]["id"])
	# The desktop's key hints (integration round 2) fit the same column.
	hud.set_vr(false)
	for i in Onboarding.LESSONS.size():
		hud.show_lesson(i, Onboarding.LESSONS.size(), Onboarding.LESSONS[i])
		await k.settle(self, 2)
		for l: Label in hud.lesson_labels():
			var w := l.get_theme_font(&"font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size(&"font_size")).x
			check(w <= HUD.CARD_TEXT_W, "desktop lesson %s: '%s' fits the text column (%.0f <= %.0f px)" % [Onboarding.LESSONS[i]["id"], l.text, w, HUD.CARD_TEXT_W])
	# The catch lesson's words (Onboarding.catch_copy: the lesson prey named,
	# every help level), in VR and on the desktop, for every species a
	# player of some size could be taught to catch: every line fits the
	# column too, and the card keeps its width.
	var catch_i := Onboarding.LESSONS.size() - 1
	var widest := {}
	for vr: bool in [true, false]:
		hud.set_vr(vr)
		hud.show_lesson(catch_i, Onboarding.LESSONS.size(), Onboarding.LESSONS[catch_i])
		for sp: Dictionary in SizeRules.SPECIES:
			for level in Onboarding.CATCH_HINT_LEVELS + 2:
				for glow: bool in [false, true]:
					# (Mass: the species plus 3 tiers, where it is worth a chase.)
					var eater := float(SizeRules.SPECIES[mini(SizeRules.species_index(sp["id"]) + 3, SizeRules.SPECIES.size() - 1)]["mass"]) * 1.2
					var view := (Onboarding.LESSONS[catch_i] as Dictionary).duplicate()
					view.merge(Onboarding.catch_copy({"species": sp["id"], "glow": glow}, level, eater), true)
					hud.update_lesson(view)
					for l: Label in hud.lesson_labels():
						var w := l.get_theme_font(&"font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size(&"font_size")).x
						if w > float(widest.get(l.text, 0.0)):
							widest[l.text] = w
		await k.settle(self, 2)
		near(card.size.x, HUD.CARD_W, 0.5, "the catch lesson's card keeps its width (%s)" % ("VR" if vr else "desktop"))
	var too_wide: Array = []
	for t: String in widest:
		if float(widest[t]) > HUD.CARD_TEXT_W:
			too_wide.append("'%s' %.0f px" % [t, widest[t]])
	eq(too_wide, [], "every catch-lesson line fits the text column (%d lines; widest %.0f <= %.0f px)" % [widest.size(), widest.values().max(), HUD.CARD_TEXT_W])
	hud.set_vr(true)
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)


func test_tonemap_compensation_restores_palette() -> void:
	# The world renders with Filmic (white 6); panels are 3D quads in VR, so
	# the tonemapper would dull them. UITonemap inverts it exactly.
	for p: Dictionary in [
			{"mode": Environment.TONE_MAPPER_FILMIC, "white": 6.0, "exposure": 1.0},
			{"mode": Environment.TONE_MAPPER_FILMIC, "white": 12.0, "exposure": 1.2},
			{"mode": Environment.TONE_MAPPER_REINHARDT, "white": 4.0, "exposure": 1.0},
			{"mode": Environment.TONE_MAPPER_LINEAR, "white": 1.0, "exposure": 0.8}]:
		var worst := 0.0
		for c: Color in [UITheme.TEXT, UITheme.TEXT_DIM, UITheme.ACCENT, UITheme.PREY, UITheme.THREAT_TEXT,
				UITheme.PANEL, UITheme.FACET_LIGHT, UITheme.BUTTON, UITheme.BUTTON_HOVER, UITheme.INK, Color.WHITE, Color.BLACK]:
			var shown := UITonemap.apply(UITonemap.compensate(c, p), p)
			worst = maxf(worst, maxf(maxf(absf(shown.r - c.r), absf(shown.g - c.g)), absf(shown.b - c.b)))
		lt(worst * 255.0, 0.5, "mode %d white %.0f: compensated colours reach the screen exactly (%.3f/255)" % [p["mode"], p["white"], worst * 255.0])
	# And the LUT the shader samples reproduces the inverse closely.
	var pf := {"mode": Environment.TONE_MAPPER_FILMIC, "white": 6.0, "exposure": 1.0}
	var lut: Array = UITonemap.build_lut(pf)
	var img := (lut[0] as ImageTexture).get_image()
	var scale: float = lut[1]
	var max_err := 0.0
	for c: Color in [UITheme.TEXT, UITheme.ACCENT, UITheme.PANEL, UITheme.BUTTON, UITheme.PREY]:
		var lin := c.srgb_to_linear()
		for ch in [lin.r, lin.g, lin.b]:
			# Shader: u = sqrt(t), linear filtering between texels.
			var fu := sqrt(ch) * (UITonemap.LUT_SIZE - 1)
			var i0 := int(floor(fu))
			var i1 := mini(i0 + 1, UITonemap.LUT_SIZE - 1)
			var x := lerpf(img.get_pixel(i0, 0).r, img.get_pixel(i1, 0).r, fu - i0) * scale
			var shown := UITonemap.forward(x, pf["mode"], pf["white"])
			max_err = maxf(max_err, absf(Color(shown, shown, shown).linear_to_srgb().r - Color(ch, ch, ch).linear_to_srgb().r))
	metric("lut_max_error_255", snappedf(max_err * 255.0, 0.01))
	lt(max_err * 255.0, 1.5, "LUT lookup lands within 1.5/255 of every palette channel")
	# Without compensation Filmic would cost real contrast: record by how much.
	var raw := UITheme.contrast(UITonemap.apply(UITheme.TEXT, pf), UITonemap.apply(UITheme.BUTTON, pf))
	metric("text_on_button_contrast_uncompensated", snappedf(raw, 0.01))
	metric("text_on_button_contrast_design", snappedf(UITheme.contrast(UITheme.TEXT, UITheme.BUTTON), 0.01))
	lt(raw, UITheme.contrast(UITheme.TEXT, UITheme.BUTTON), "(uncompensated Filmic really does reduce contrast)")


func test_panel_angular_size_comfortable() -> void:
	# The menu is curved round the eye: its width is an arc.
	var w := rad_to_deg(UITheme.MENU_SIZE.x / UITheme.PX_PER_M / UITheme.PANEL_DISTANCE)
	var h := 2.0 * rad_to_deg(atan(UITheme.MENU_SIZE.y / UITheme.PX_PER_M * 0.5 / UITheme.PANEL_DISTANCE))
	metric("menu_deg", [snappedf(w, 0.1), snappedf(h, 0.1)])
	lt(w, 55.0, "menu panel narrower than 55 deg (fits comfortable eye rotation)")
	lt(h, 40.0, "menu panel shorter than 40 deg")
	between(UITheme.PANEL_DISTANCE, 1.2, 1.6, "menu distance in the 1.2-1.6 m band")
	# Panel texel density vs Quest Pro (~22 px/deg centre): no blur.
	var px_per_deg := UITheme.MENU_SIZE.x / w
	metric("menu_px_per_deg", snappedf(px_per_deg, 0.1))
	gt(px_per_deg, 22.0, "panel texture at least as sharp as the display")
	# The real panel measures what the maths says (arc, seen from the eye).
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 2)
	var p := k.ui.menu_panel
	var eye := k.cam.global_position
	var l := p.pixel_to_world(Vector2(0, UITheme.MENU_SIZE.y * 0.5)) - eye
	var mid := p.pixel_to_world(Vector2(UITheme.MENU_SIZE) * 0.5) - eye
	var r := p.pixel_to_world(Vector2(UITheme.MENU_SIZE.x, UITheme.MENU_SIZE.y * 0.5)) - eye
	near(rad_to_deg(l.angle_to(r)), w, 0.05, "rendered arc spans the designed width")
	near(l.length(), mid.length(), 0.001, "edges exactly as far from the eye as the centre (curved round it)")


func test_how_to_captions_fit_three_lines() -> void:
	var h := await _show(&"howto") as HowToScreen
	for desk in [false, true]:
		h.set_desktop(desk)
		for i in HowToScreen.CARDS.size():
			h.show_card(i)
			await k.settle(self, 2)
			var cap := h.find_child("Caption", true, false) as Label
			var tag := "%s%s" % ["desktop " if desk else "", HowToScreen.CARDS[i]["id"]]
			check(cap.get_line_count() <= 3, "card %s caption fits 3 lines (%d)" % [tag, cap.get_line_count()])
			check(Rect2(Vector2(20, 20), Vector2(UITheme.MENU_SIZE) - Vector2(40, 40)).encloses(cap.get_global_rect()),
				"card %s caption inside the panel" % tag)
	h.set_desktop(false)
	h.show_card(0)
