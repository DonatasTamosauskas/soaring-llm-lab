extends Control
## VERIFIER PLOT (round 6): the real game's tutorial (integration bot flying
## through the real WingInput / FlightModel / PlayerBird), traced by
## ui_r6x_real_trace_test into artifacts/ui/verify/r6/real_trace.csv, drawn
## as one labelled PNG: artifacts/ui/verify/r6/real_hud_swing.png.
##
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 1400x1000 \
##       res://tests/probes/ui/ui_r6x_plot.tscn
##
## Lanes share the time axis (s):
##  1. azimuth in the rig, deg (+ = right of where the body, and a head at
##     rest, faces): the flight path (blue), the HUD's centre line (orange),
##     the lesson card's words (light orange band, from the card's layout);
##  2. angle from that resting gaze to the card's farthest word (orange),
##     the 45 deg "in view" line the UI's own tests use, red ticks where the
##     readable card had words past it;
##  3. the flight path's elevation (blue).

const W := 1400.0
const H := 1000.0
const SURFACE := Color("fcfcfb")
const TEXT_PRIMARY := Color("0b0b0b")
const TEXT_SECONDARY := Color("52514e")
const GRID := Color("e4e3de")
const AXIS := Color("b9b7b0")
const PATH := Color("2a78d6")
const HUDC := Color("eb6834")
const CRITICAL := Color("d03b3b")
const L := 110.0
const R := 1360.0

var rows: Array[Dictionary] = []
var font: Font


func _ready() -> void:
	font = UITheme.font(700)
	var path := Paths.artifacts("ui").path_join("verify/r6/real_trace.csv")
	var txt := FileAccess.get_file_as_string(path)
	var lines := txt.split("\n", false)
	var head := lines[0].split(",")
	for i in range(1, lines.size()):
		var c := lines[i].split(",")
		if c.size() != head.size():
			continue
		var d := {}
		for j in head.size():
			d[head[j]] = c[j] if j in [1, 2] else float(c[j])
		rows.append(d)
	size = Vector2(W, H)
	queue_redraw()
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := Paths.artifacts("ui").path_join("verify/r6/real_hud_swing.png")
	img.save_png(out)
	print("[ui-verify] plot -> %s (%d rows)" % [out, rows.size()])
	get_tree().quit()


func _x(t: float) -> float:
	var t1: float = rows[-1]["t"]
	return L + (R - L) * t / t1


func _text(p: Vector2, s: String, sz: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	draw_string(font, p, s, align, w, sz, col)


func _lane(top: float, h: float, lo: float, hi: float, ticks: Array, title: String) -> Callable:
	_text(Vector2(L, top - 10), title, 17, TEXT_PRIMARY)
	for v: float in ticks:
		var y := top + h * (hi - v) / (hi - lo)
		draw_line(Vector2(L, y), Vector2(R, y), GRID if v != 0.0 else AXIS, 1.0)
		_text(Vector2(L - 60, y + 6), ("%+d" % int(v)) if v != 0.0 else "0", 14, TEXT_SECONDARY, HORIZONTAL_ALIGNMENT_RIGHT, 50)
	return func(v: float) -> float: return top + h * (hi - clampf(v, lo, hi)) / (hi - lo)


func _draw() -> void:
	# The project's stretch settings may scale the canvas: fit W x H to it.
	var vr := get_viewport_rect().size
	var k := minf(vr.x / W, vr.y / H)
	draw_rect(Rect2(Vector2.ZERO, vr), SURFACE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	if rows.is_empty():
		_text(Vector2(40, 60), "no trace", 24, TEXT_PRIMARY)
		return
	# Summary numbers.
	var counted := 0
	var inview := 0
	var swing := 0.0
	for d in rows:
		if d["t"] < 1.5 or d["ecc"] < 0.0:
			continue
		counted += 1
		if d["opacity"] >= 0.6 and d["ecc"] <= 45.0:
			inview += 1
		swing = maxf(swing, absf(d["panel_yaw"]))
	_text(Vector2(40, 44), "Real game, first-flight lessons flown by the integration bot: the HUD follows the flight path's heading", 26, TEXT_PRIMARY)
	_text(Vector2(40, 74), "Lesson card readable with every word within 45 deg of a resting gaze: %.0f %% of the time.  HUD centre line up to %.0f deg from where the body faces." % [100.0 * inview / maxf(counted, 1), swing], 16, TEXT_SECONDARY)
	# Legend.
	var lx := L
	for item: Array in [[PATH, "Flight path (velocity heading)", false], [HUDC, "HUD centre line", false], [Color(HUDC, 0.28), "Lesson card: its words", true], [AXIS, "Where the body faces (head at rest)", false], [CRITICAL, "Readable card, words past 45 deg", false]]:
		if item[2]:
			draw_rect(Rect2(lx, 104, 26, 12), item[0])
		else:
			draw_line(Vector2(lx, 110), Vector2(lx + 26, 110), item[0], 3.0)
		_text(Vector2(lx + 34, 116), item[1], 15, TEXT_PRIMARY)
		lx += 34 + font.get_string_size(item[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 30
	# Lesson spans (top of lane 1).
	var ya := _lane(170, 330, -180.0, 90.0, [-180.0, -135.0, -90.0, -45.0, 0.0, 45.0, 90.0], "Azimuth in the rig (deg, + right of where the body faces)")
	var prev := ""
	for d in rows:
		if d["lesson"] != prev:
			prev = d["lesson"]
			var x := _x(d["t"])
			draw_line(Vector2(x, 170), Vector2(x, 900), Color(AXIS, 0.6), 1.0)
			_text(Vector2(x + 4, 186), String(prev), 13, TEXT_SECONDARY)
	# Card band, HUD line, path line.
	for i in range(1, rows.size()):
		var a: Dictionary = rows[i - 1]
		var b: Dictionary = rows[i]
		var xa := _x(a["t"])
		var xb := _x(b["t"])
		if b["ecc"] >= 0.0:
			var c := -float(b["panel_yaw"])
			var s := float(b["side"])
			var y0: float = ya.call(c + s * 11.4)
			var y1: float = ya.call(c + s * 38.9)
			draw_rect(Rect2(xa, minf(y0, y1), maxf(xb - xa, 1.0), absf(y1 - y0)), Color(HUDC, 0.28))
	var pts_p := PackedVector2Array()
	var pts_h := PackedVector2Array()
	for d in rows:
		var vy := float(d["vel_yaw"])
		if vy > 900.0:
			vy = float(d["fwd_yaw"])
		pts_p.append(Vector2(_x(d["t"]), ya.call(-vy)))
		pts_h.append(Vector2(_x(d["t"]), ya.call(-float(d["panel_yaw"]))))
	# A heading jumping across +-180 is drawn as separate strokes.
	_poly(pts_p, PATH)
	_poly(pts_h, HUDC)
	draw_line(Vector2(L, ya.call(0.0)), Vector2(R, ya.call(0.0)), AXIS, 3.0)
	# Lane 2: gaze to the farthest word.
	var yb := _lane(560, 170, 0.0, 150.0, [0.0, 45.0, 90.0, 135.0], "Resting gaze to the card's farthest word (deg)")
	draw_dashed_line(Vector2(L, yb.call(45.0)), Vector2(R, yb.call(45.0)), CRITICAL, 1.5, 6.0)
	var pts_e := PackedVector2Array()
	for d in rows:
		if d["ecc"] >= 0.0:
			pts_e.append(Vector2(_x(d["t"]), yb.call(d["ecc"])))
			if d["t"] >= 1.5 and d["opacity"] >= 0.6 and d["ecc"] > 45.0:
				draw_line(Vector2(_x(d["t"]), 736), Vector2(_x(d["t"]), 748), CRITICAL, 2.0)
	_poly(pts_e, HUDC)
	# Lane 3: flight path elevation.
	var yc := _lane(790, 110, -60.0, 90.0, [-60.0, 0.0, 45.0, 90.0], "Flight path elevation (deg)")
	var pts_v := PackedVector2Array()
	for d in rows:
		pts_v.append(Vector2(_x(d["t"]), yc.call(d["vel_elev"])))
	_poly(pts_v, PATH)
	# Time axis.
	var t1: float = rows[-1]["t"]
	var t := 0.0
	while t <= t1 + 0.01:
		var x := _x(t)
		draw_line(Vector2(x, 900), Vector2(x, 908), AXIS, 1.0)
		_text(Vector2(x - 20, 928), "%d" % int(t), 14, TEXT_SECONDARY, HORIZONTAL_ALIGNMENT_CENTER, 40)
		t += 5.0
	_text(Vector2(R - 80, 956), "Time (s)", 15, TEXT_SECONDARY)
	_text(Vector2(40, 986), "Source: artifacts/ui/verify/r6/real_trace.csv (ui_r6x_real_trace_test, scenes/main.tscn, --fixed-fps 72). Card band from the card's layout (11.4-38.9 deg beside the HUD centre line, side as shown).", 12, TEXT_SECONDARY)


func _poly(pts: PackedVector2Array, col: Color) -> void:
	var run := PackedVector2Array()
	for i in pts.size():
		if i > 0 and absf(pts[i].y - pts[i - 1].y) > 150.0:
			if run.size() > 1:
				draw_polyline(run, col, 2.0, true)
			run = PackedVector2Array()
		run.append(pts[i])
	if run.size() > 1:
		draw_polyline(run, col, 2.0, true)
