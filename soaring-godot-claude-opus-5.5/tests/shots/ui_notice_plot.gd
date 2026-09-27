extends Node
## Evidence plots for the HUD's centre line and the lesson card beside it,
## replayed in synthetic time through the real UI (VR mode, the lesson card
## up), one labelled PNG per scenario in artifacts/ui/, numbers in
## notice_calm.json:
##
##   notice_real_tutorial.png    the REAL game's tutorial as the round-6
##                               verifier flew it (tests/shots/
##                               ui_game_record.gd: the breeze, the loop
##                               over the top after the dive, GameLoop's
##                               targets and threats), head at rest
##   notice_real_manoeuvres.png  the real game, 54 s more: turns both ways,
##                               a dive, a zoom, a chase, two celebrations
##   notice_torso_turn.png       the flight area's B1 course (sparrow) with
##                               a 30 deg torso turn to the right at 5 s
##
## Four lanes share the time axis (seconds):
##  - azimuth in the rig (degrees, + right of the rig's forward, clipped at
##    +-90): where the body faces (grey), the HUD's centre line (aqua), the
##    flight path (blue, while it has a heading), the span of the card's
##    words (orange);
##  - the resting gaze (the head, along the torso) to the card's farthest
##    word (degrees), with the 45 deg in-view bound;
##  - the flight path's elevation and the notice band's (+8..+20);
##  - the card's opacity, with status-red ticks wherever the flight path was
##    behind the readable card.
## Colours: the reference data-viz palette's first three categorical slots
## (blue, orange, aqua; validated all-pairs, light), status red, neutral
## grey; every series is named in the legend.
##
##   tools/gd.sh ui --rendering-method forward_plus --resolution 1400x1180 \
##       res://tests/shots/ui_notice_plot.tscn
## (A renderer is needed for the labels; the run quits itself.)

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0
const W := 1400
const H := 1180
const SURFACE := Color("fcfcfb")
const TEXT_PRIMARY := Color("0b0b0b")
const TEXT_SECONDARY := Color("52514e")
const GRID := Color("e4e3de")
const AXIS := Color("b9b7b0")
const BODY := Color("8a8983")
const PATH := Color("2a78d6")
const CARD := Color("eb6834")
const HUDC := Color("1baf7a")
const CRITICAL := Color("d03b3b")


func _ready() -> void:
	var out := Paths.artifacts("ui")
	var report := {}
	var jobs := [
		["real_tutorial", "Real game, first-flight lessons (recorded): the HUD stays where the body faces", "tutorial"],
		["real_manoeuvres", "Real game, 54 s of turns, a dive, a zoom and a chase in the breeze (recorded)", "manoeuvres"],
		["torso_turn", "B1 course (sparrow), the player turns their torso 30 deg to the right at 5 s", "b1"],
	]
	for job: Array in jobs:
		var rows: Array = await _replay(String(job[2]))
		var summary := _summarise(rows)
		report[job[0]] = summary
		var secs := float(rows[rows.size() - 1][0])
		await _plot(rows, secs, String(job[1]), summary, out.path_join("notice_%s.png" % job[0]))
		print("[ui] notice plot %s: %s" % [job[0], str(summary)])
	var f := FileAccess.open(out.path_join("notice_calm.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	get_tree().quit(0)


static func _b1(species: String) -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_b1_flightpath.json"))
	return ((d as Dictionary)["series"] as Dictionary).get(species, []) if d is Dictionary else []


static func _sample(s: Array, t: float) -> Vector2:
	t = fmod(t, float(s[s.size() - 1][0]))
	for i in range(1, s.size()):
		if float(s[i][0]) >= t:
			var a: Array = s[i - 1]
			var b: Array = s[i]
			var u := clampf((t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4), 0.0, 1.0)
			return Vector2(lerpf(float(a[1]), float(b[1]), u), lerpf(float(a[2]), float(b[2]), u))
	return Vector2(float(s[s.size() - 1][1]), float(s[s.size() - 1][2]))


## Azimuth in the rig (deg, + right of its forward) of a world direction.
static func _az_rig(k: Kit, d: Vector3) -> float:
	var l := k.rig.global_basis.orthonormalized().inverse() * d
	return rad_to_deg(atan2(l.x, -l.z))


## [min, max] azimuth in the rig (deg, + right) of the lesson card's words,
## and the largest angle between the gaze and any of them.
func _card_text(k: Kit) -> Array:
	var eye := k.cam.global_position
	var g := -k.cam.global_basis.z
	var mn := INF
	var mx := -INF
	var ecc := 0.0
	for lbl: Label in k.ui.hud.lesson_labels():
		if not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var w := lbl.get_theme_font(&"font").get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		var r := lbl.get_global_rect()
		var x0 := r.end.x - w if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT else r.position.x
		for x: float in [x0, x0 + w * 0.5, x0 + w]:
			var d := k.ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - eye
			var az := _az_rig(k, d)
			mn = minf(mn, az)
			mx = maxf(mx, az)
			ecc = maxf(ecc, rad_to_deg(g.angle_to(d)))
	return [mn, mx, ecc]


## Replay a flight with the lesson card up, the head at rest along the
## torso. Per frame: [t, body az, HUD az, path az (NAN without a heading),
## path el, card words az min, max (NAN when not shown), gaze to farthest
## word, card opacity, path hidden, read in view, HUD.move_count, a
## celebration showing] (azimuths in the rig, deg, + right).
func _replay(which: String) -> Array:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.reset()
	var game: Array = [] if which == "b1" else Kit.game_flight(which)
	var b1: Array = _b1("sparrow") if which == "b1" else []
	var seconds := 20.0 if which == "b1" else float(game[game.size() - 1][0])
	var replay := {}
	if not game.is_empty():
		k.parent_rig_like_player_bird()
		k.apply_game_row(game, 0.0, 0.0, replay)
	else:
		k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)
	k.ui.hud_panel.set_process(false)
	var rows: Array = []
	var t := float(game[0][0]) if not game.is_empty() else 0.0
	var tierups := [8.0, 30.0] if which == "manoeuvres" else []
	var tier := 2
	while t < seconds:
		var torso := 0.0
		if not game.is_empty():
			torso = float(k.apply_game_row(game, t, 0.0, replay)["torso_deg"])
		else:
			var g := _sample(b1, t)
			var a := deg_to_rad(g.x)
			torso = -clampf((t - 5.0) * 60.0, 0.0, 30.0)
			var turned := Basis(Vector3.UP, deg_to_rad(torso))
			k.player.velocity = turned * Vector3(0.0, sin(a), -cos(a)) * g.y
			k.player.global_basis = turned
			k.player.tel["body_yaw"] = deg_to_rad(torso)
			k.set_head(Vector3(0, Kit.EYE, 0), torso)
		if not tierups.is_empty() and t >= float(tierups[0]):
			tierups.pop_front()
			k.player.mass = float(SizeRules.SPECIES[tier + 1]["mass"]) * 1.02
			Events.player_tier_changed.emit(tier, tier + 1)
			tier += 1
			k.ui.hud.set_process(false)
			await get_tree().process_frame
		k.ui.hud_panel.follow(SDT)
		k.ui.indicators.step(SDT)
		k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
		k.ui.hud.advance(SDT)
		t += SDT
		var p := k.ui.hud_panel
		var v := k.player.velocity
		var alpha := p.band_alpha(HUD.BAND_NOTICE) if p.is_band_visible(HUD.BAND_NOTICE) and k.ui.hud.lesson_visible() else 0.0
		var hidden := false
		if v.length() > 1.5 * k.rig.world_scale and alpha >= HUD.READABLE_ALPHA:
			var hit := p.intersect_ray(k.cam.global_position, v.normalized())
			if not hit.is_empty():
				for r: Rect2 in k.ui.hud.notice_rects():
					if r.has_point(hit["pixel"]):
						hidden = true
		var ct := _card_text(k) if alpha > 0.0 else [NAN, NAN, NAN]
		var vh := Vector2(v.x, v.z).length()
		var path_az := _az_rig(k, v) if vh > 0.3 * k.rig.world_scale else NAN
		var path_el := rad_to_deg(atan2(v.y, vh)) if v.length() > 0.1 * k.rig.world_scale else 0.0
		var in_view := alpha >= HUD.READABLE_ALPHA and float(ct[2]) <= 45.0
		rows.append([t, -torso, -rad_to_deg(p.panel_yaw()), path_az, path_el, ct[0], ct[1], ct[2], alpha, hidden, in_view,
			k.ui.hud.move_count, k.ui.hud.toast_active()])
	k.end_game_replay(replay)
	k.teardown()
	await get_tree().process_frame
	await get_tree().process_frame
	return rows


func _summarise(rows: Array) -> Dictionary:
	var fades := 0
	var was := false
	var hidden_frames := 0
	var run := 0
	var longest := 0
	var shown := 0
	var in_view := 0
	var hud_off := 0.0
	var travel := 0.0
	var far := 0.0
	var prev_hud := NAN
	for r: Array in rows:
		var up := float(r[8]) > 0.0
		var faded := up and float(r[8]) < HUD.READABLE_ALPHA
		if faded and not was:
			fades += 1
		was = faded
		run = run + 1 if bool(r[9]) else 0
		longest = maxi(longest, run)
		if bool(r[9]):
			hidden_frames += 1
		if up:
			shown += 1
			if bool(r[10]):
				in_view += 1
			if not faded:
				far = maxf(far, float(r[7]))
		hud_off = maxf(hud_off, absf(float(r[2]) - float(r[1])))
		if is_finite(prev_hud):
			travel += absf(float(r[2]) - prev_hud)
		prev_hud = float(r[2])
	var moves := int(rows[rows.size() - 1][11]) - int(rows[0][11]) if not rows.is_empty() else 0
	return {"frames": rows.size(), "fades": fades, "moves": moves, "path_hidden_frames": hidden_frames,
		"path_hidden_longest_s": snappedf(longest * SDT, 0.001),
		"read_in_view_frac": snappedf(in_view / float(maxi(shown, 1)), 0.001),
		"card_words_max_from_resting_gaze_deg": snappedf(far, 0.1),
		"hud_off_body_max_deg": snappedf(hud_off, 0.01), "hud_travel_deg": snappedf(travel, 0.1)}


func _plot(rows: Array, seconds: float, title: String, summary: Dictionary, path: String) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)
	var c := _Chart.new()
	c.rows = rows
	c.seconds = seconds
	c.title = title
	c.subtitle = "HUD off where the body faces: max %.1f deg, %.0f deg of travel   ·   card read in view %.1f %%   ·   %d fade%s, %d move%s   ·   path behind the readable card %d frames, longest %.3f s" % [
		summary["hud_off_body_max_deg"], summary["hud_travel_deg"], float(summary["read_in_view_frac"]) * 100.0,
		summary["fades"], "" if int(summary["fades"]) == 1 else "s", summary["moves"], "" if int(summary["moves"]) == 1 else "s",
		summary["path_hidden_frames"], summary["path_hidden_longest_s"]]
	c.size = Vector2(W, H)
	vp.add_child(c)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(path)
	vp.queue_free()


class _Chart:
	extends Control
	var rows: Array = []
	var seconds := 20.0
	var title := ""
	var subtitle := ""
	var _font: Font

	func _draw() -> void:
		_font = UITheme.font(700)
		draw_rect(Rect2(Vector2.ZERO, size), SURFACE)
		draw_string(_font, Vector2(40, 46), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, TEXT_PRIMARY)
		draw_string(_font, Vector2(40, 80), subtitle, HORIZONTAL_ALIGNMENT_LEFT, size.x - 80.0, 16, TEXT_SECONDARY)
		var x0 := 110.0
		var x1 := size.x - 60.0
		var lanes := [
			[Rect2(x0, 192, x1 - x0, 290), -90.0, 90.0, 30.0, "Azimuth in the rig (deg, + right of its forward; clipped at +-90)"],
			[Rect2(x0, 542, x1 - x0, 150), 0.0, 60.0, 15.0, "Resting gaze to the card's farthest word (deg)"],
			[Rect2(x0, 752, x1 - x0, 220), -60.0, 90.0, 30.0, "Flight path elevation (deg)"],
			[Rect2(x0, 1022, x1 - x0, 70), 0.0, 1.0, 0.5, "Lesson card opacity (grey: a celebration shows instead)"],
		]
		for lane: Array in lanes:
			_axes(lane[0], lane[1], lane[2], lane[3], lane[4])
		_legend(Vector2(x0, 116))
		# Lane 1: the card's words, the flight path, the body, the HUD.
		var l1: Rect2 = lanes[0][0]
		var top := PackedVector2Array()
		var bottom := PackedVector2Array()
		for i in rows.size() + 1:
			var r: Array = rows[i] if i < rows.size() else []
			if not r.is_empty() and is_finite(float(r[5])):
				top.append(Vector2(_x(l1, float(r[0])), _y(l1, float(r[6]), -90.0, 90.0)))
				bottom.append(Vector2(_x(l1, float(r[0])), _y(l1, float(r[5]), -90.0, 90.0)))
			elif top.size() > 1:
				var poly := top.duplicate()
				bottom.reverse()
				poly.append_array(bottom)
				draw_colored_polygon(poly, Color(CARD, 0.45))
				top.clear()
				bottom.clear()
			else:
				top.clear()
				bottom.clear()
		_series(l1, 3, -90.0, 90.0, PATH, 2.0)
		_series(l1, 1, -90.0, 90.0, BODY, 5.0)
		_series(l1, 2, -90.0, 90.0, HUDC, 2.0)
		# Direct labels at the right end (the aqua line is light on white).
		var last: Array = rows[rows.size() - 1]
		draw_string(_font, Vector2(l1.end.x + 6, _y(l1, float(last[2]), -90.0, 90.0) - 4), "HUD", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_PRIMARY)
		# Lane 2: the gaze to the farthest word, and the bounds.
		var l2: Rect2 = lanes[1][0]
		var y45 := _y(l2, 45.0, 0.0, 60.0)
		_dashed(Vector2(l2.position.x, y45), Vector2(l2.end.x, y45), CRITICAL)
		draw_string(_font, Vector2(l2.end.x + 6, y45 + 5), "45", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_PRIMARY)
		_series(l2, 7, 0.0, 60.0, CARD, 2.0)
		# Lane 3: the notice band's elevations and the flight path.
		var l3: Rect2 = lanes[2][0]
		var yb := _y(l3, 8.0, -60.0, 90.0)
		var yt := _y(l3, 20.0, -60.0, 90.0)
		draw_rect(Rect2(l3.position.x, yt, l3.size.x, yb - yt), Color(CARD, 0.18))
		_series(l3, 4, -60.0, 90.0, PATH, 2.0)
		# Lane 4: the card's opacity, and where the path was behind it.
		var l4: Rect2 = lanes[3][0]
		var t0 := -1.0
		for i in rows.size() + 1:
			var on := i < rows.size() and bool(rows[i][12])
			if on and t0 < 0.0:
				t0 = float(rows[i][0])
			elif not on and t0 >= 0.0:
				var xa := _x(l4, t0)
				var xb := _x(l4, float(rows[i - 1][0]))
				draw_rect(Rect2(xa, l4.position.y, xb - xa, l4.size.y), Color(BODY, 0.25))
				t0 = -1.0
		_series(l4, 8, 0.0, 1.0, CARD, 2.0)
		for r: Array in rows:
			if bool(r[9]):
				var x := _x(l4, float(r[0]))
				draw_line(Vector2(x, l4.end.y + 6), Vector2(x, l4.end.y + 22), CRITICAL, 2.0)
		# Time axis.
		var step := 5 if seconds <= 40.0 else 10
		for s in int(seconds) + 1:
			var x := _x(l4, float(s))
			draw_line(Vector2(x, l4.end.y + 26), Vector2(x, l4.end.y + 32), AXIS, 1.0)
			if s % step == 0:
				draw_string(_font, Vector2(x - 8, l4.end.y + 52), str(s), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_SECONDARY)
		draw_string(_font, Vector2(x1 - 70, l4.end.y + 72), "Time (s)", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT_SECONDARY)

	func _axes(r: Rect2, lo: float, hi: float, step: float, label: String) -> void:
		var v := lo
		while v <= hi + 1e-6:
			var y := _y(r, v, lo, hi)
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), AXIS if absf(v) < 1e-6 else GRID, 1.0)
			var txt := ("%+.0f" % v) if step >= 1.0 else ("%.1f" % v)
			if absf(v) < 1e-6:
				txt = "0"
			draw_string(_font, Vector2(r.position.x - 58, y + 6), txt, HORIZONTAL_ALIGNMENT_RIGHT, 48, 15, TEXT_SECONDARY)
			v += step
		var tick := 5 if seconds <= 40.0 else 10
		for s in range(0, int(seconds) + 1, tick):
			var x := _x(r, float(s))
			draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(GRID, 0.6), 1.0)
		draw_string(_font, Vector2(r.position.x, r.position.y - 10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, TEXT_PRIMARY)

	func _legend(at: Vector2) -> void:
		var x := at.x
		var y := at.y
		var items := [[BODY, "Where the body faces (resting gaze)", 5], [HUDC, "HUD centre line", 0], [PATH, "Flight path (dotted: beyond +-90)", 0],
			[CARD, "Lesson card: its words", 1], [Color(CARD, 0.3), "Notice band, +8 to +20", 4], [CRITICAL, "Flight path behind the readable card", 3],
			[CRITICAL, "In-view bound, 45 deg", 6]]
		for it: Array in items:
			var col: Color = it[0]
			var w := 36.0 + _font.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 26.0
			if x + w > size.x - 40.0:
				x = at.x
				y += 26.0
			var at_row := Vector2(x, y)
			_legend_item(at_row, col, int(it[2]), String(it[1]))
			x += w

	func _legend_item(at: Vector2, col: Color, kind: int, text: String) -> void:
		var x := at.x
		if true:
			match kind:
				0:
					draw_line(Vector2(x, at.y), Vector2(x + 28, at.y), col, 2.0)
				5:
					draw_line(Vector2(x, at.y), Vector2(x + 28, at.y), col, 5.0)
				1:
					draw_rect(Rect2(x, at.y - 8, 28, 16), Color(col, 0.45))
				4:
					draw_rect(Rect2(x, at.y - 8, 28, 16), col)
				3:
					draw_line(Vector2(x + 14, at.y - 9), Vector2(x + 14, at.y + 9), col, 2.0)
				6:
					_dashed(Vector2(x, at.y), Vector2(x + 28, at.y), col)
			draw_string(_font, Vector2(x + 36, at.y + 6), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_PRIMARY)

	## A line series; gaps where the value is not finite; beyond the lane's
	## range it runs dotted along the edge (the flight path over the top of
	## a loop points behind the player).
	func _series(r: Rect2, col_i: int, lo: float, hi: float, col: Color, width: float) -> void:
		var pts := PackedVector2Array()
		var prev_out := false
		for row: Array in rows:
			var v := float(row[col_i])
			var out := is_finite(v) and (v < lo or v > hi)
			if not is_finite(v) or out != prev_out:
				if pts.size() > 1:
					if prev_out:
						_dotted(pts, r, col, width)
					else:
						draw_polyline(pts, col, width, true)
				pts.clear()
			prev_out = out
			if is_finite(v):
				pts.append(Vector2(_x(r, float(row[0])), _y(r, v, lo, hi)))
		if pts.size() > 1:
			if prev_out:
				_dotted(pts, r, col, width)
			else:
				draw_polyline(pts, col, width, true)

	## Dots along an out-of-range stretch (pinned to the lane's edge); no
	## segment across the lane where the value wraps from one edge to the
	## other.
	func _dotted(pts: PackedVector2Array, r: Rect2, col: Color, width: float) -> void:
		for i in range(0, pts.size() - 1, 3):
			var a := pts[i]
			var b := pts[mini(i + 1, pts.size() - 1)]
			if absf(a.y - b.y) < r.size.y * 0.5:
				draw_line(a, b, col, width)

	func _dashed(a: Vector2, b: Vector2, col: Color) -> void:
		var n := int(a.distance_to(b) / 10.0)
		for i in n:
			if i % 2 == 0:
				draw_line(a.lerp(b, float(i) / n), a.lerp(b, float(i + 1) / n), col, 1.5)

	func _x(r: Rect2, t: float) -> float:
		return r.position.x + clampf(t / seconds, 0.0, 1.0) * r.size.x

	func _y(r: Rect2, v: float, lo: float, hi: float) -> float:
		return r.end.y - clampf((v - lo) / (hi - lo), 0.0, 1.0) * r.size.y
