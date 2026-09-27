extends Control
## A small static chart panel for the VR area's evidence plots (drawn by
## Godot, captured to PNG by tests/shots/vr_plots.gd).
##
## Look: light chart surface, hairline solid recessive grid, 2 px lines,
## >= 8 px markers with a 2 px surface ring, bars <= 24 px with a 2 px gap,
## a legend for >= 2 series, sparse direct labels, text in text inks (never
## the series colour). Categorical colours in fixed order from the
## validated reference palette (blue, orange, aqua, yellow).

const SURFACE := Color("#fcfcfb")
const INK := Color("#0b0b0b")
const INK2 := Color("#52514e")
const MUTED := Color("#8a8984")
const GRID := Color("#e6e5e1")
const SERIES: Array[Color] = [Color("#2a78d6"), Color("#eb6834"), Color("#1baf7a"), Color("#eda100")]

var title := ""
var subtitle := ""
var x_label := ""
var y_label := ""
var x_min := 0.0
var x_max := 1.0
var y_min := 0.0
var y_max := 1.0
var x_ticks: Array = []
var y_ticks: Array = []
## Tick label formatter: "%.0f", "%.1f", ...
var x_fmt := "%.0f"
var y_fmt := "%.1f"
## [{name, points: PackedVector2Array, kind: line|dots|bars|pulses, color_index, label_end: bool}]
var series: Array = []
## [{x, text}] vertical reference lines (muted, labelled at the top)
var vlines: Array = []
## [{y, text}] horizontal reference lines
var hlines: Array = []
## Row labels for the "pulses" kind (categorical y), top to bottom.
var rows: Array = []
var legend := true
## Legend position as a fraction of the plot area.
var legend_at := Vector2(0.02, 0.04)
## Optional text labels for the x ticks (same order as x_ticks).
var x_tick_labels: Array = []

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _plot_rect() -> Rect2:
	var left := 74.0 if rows.is_empty() else 120.0
	return Rect2(left, 100.0, size.x - left - 28.0, size.y - 100.0 - 62.0)


func _px(p: Vector2) -> Vector2:
	var r := _plot_rect()
	var tx := (p.x - x_min) / maxf(x_max - x_min, 1e-9)
	var ty := (p.y - y_min) / maxf(y_max - y_min, 1e-9)
	return Vector2(r.position.x + tx * r.size.x, r.position.y + (1.0 - ty) * r.size.y)


func _text(pos: Vector2, s: String, sz: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(_font, pos, s, align, width, sz, col)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), SURFACE)
	var r := _plot_rect()
	_text(Vector2(18, 30), title, 20, INK)
	if subtitle != "":
		_text(Vector2(18, 54), subtitle, 14, INK2)
	# Grid and ticks.
	for t in y_ticks:
		var p := _px(Vector2(x_min, float(t)))
		draw_line(Vector2(r.position.x, p.y), Vector2(r.end.x, p.y), GRID, 1.0)
		_text(Vector2(r.position.x - 8 - 60, p.y + 5), y_fmt % float(t), 13, INK2, HORIZONTAL_ALIGNMENT_RIGHT, 60)
	for t in x_ticks:
		var p := _px(Vector2(float(t), y_min))
		draw_line(Vector2(p.x, r.position.y), Vector2(p.x, r.end.y), GRID, 1.0)
		var i := x_ticks.find(t)
		var lab: String = str(x_tick_labels[i]) if i >= 0 and i < x_tick_labels.size() else x_fmt % float(t)
		_text(Vector2(p.x - 40, r.end.y + 20), lab, 12, INK2, HORIZONTAL_ALIGNMENT_CENTER, 80)
	for i in rows.size():
		var y := r.position.y + (i + 0.5) * r.size.y / rows.size()
		_text(Vector2(8, y + 5), str(rows[i]), 14, INK2, HORIZONTAL_ALIGNMENT_RIGHT, r.position.x - 16)
		draw_line(Vector2(r.position.x, y + r.size.y / rows.size() * 0.5), Vector2(r.end.x, y + r.size.y / rows.size() * 0.5), GRID, 1.0)
	draw_line(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y), MUTED, 1.0)
	_text(Vector2(r.position.x, r.end.y + 44), x_label, 14, INK2, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	if y_label != "":
		_text(Vector2(r.position.x - 60, r.position.y - 14), y_label, 13, INK2)
	for v in vlines:
		var p := _px(Vector2(float(v["x"]), y_min))
		draw_line(Vector2(p.x, r.position.y), Vector2(p.x, r.end.y), MUTED, 1.0)
		_text(Vector2(p.x + 4, r.position.y + 14), str(v["text"]), 12, INK2)
	for h in hlines:
		var p := _px(Vector2(x_min, float(h["y"])))
		draw_line(Vector2(r.position.x, p.y), Vector2(r.end.x, p.y), MUTED, 1.0)
	# Series.
	for s in series:
		var col: Color = SERIES[int(s.get("color_index", 0)) % SERIES.size()]
		var pts: PackedVector2Array = s["points"]
		match String(s.get("kind", "line")):
			"line":
				var px := PackedVector2Array()
				for p in pts:
					px.append(_px(p))
				if px.size() >= 2:
					draw_polyline(px, col, 2.0, true)
				if s.get("label_end", false) and not px.is_empty():
					draw_circle(px[px.size() - 1], 6.0, SURFACE)
					draw_circle(px[px.size() - 1], 4.0, col)
					_text(px[px.size() - 1] + Vector2(-150, -10), str(s["name"]), 13, INK, HORIZONTAL_ALIGNMENT_RIGHT, 144)
			"dots":
				for p in pts:
					var q := _px(p)
					draw_circle(q, 6.0, SURFACE)
					draw_circle(q, 4.0, col)
			"bars":
				var w := minf(24.0, r.size.x / maxf(pts.size() * 2.5, 1.0))
				var off := float(s.get("offset", 0.0)) * (w + 2.0)
				for p in pts:
					var top := _px(p)
					var base := _px(Vector2(p.x, maxf(y_min, 0.0)))
					var x0 := top.x - w * 0.5 + off
					var rect := Rect2(x0, minf(top.y, base.y), w, absf(base.y - top.y))
					draw_rect(rect, col)
			"pulses":
				# p.x = start s, p.y = row index; widths in "widths", heights by amp.
				var widths: PackedFloat32Array = s["widths"]
				var amps: PackedFloat32Array = s["amps"]
				var rh := r.size.y / maxf(rows.size(), 1)
				for i in pts.size():
					var x0 := _px(Vector2(pts[i].x, 0)).x
					var x1 := _px(Vector2(pts[i].x + widths[i], 0)).x
					var cy := r.position.y + (pts[i].y + 0.5) * rh
					var h := maxf(3.0, amps[i] * rh * 0.7)
					draw_rect(Rect2(x0, cy + rh * 0.35 - h, maxf(x1 - x0, 2.0), h), col)
	# Reference-line labels over the data, on a surface knockout.
	for h in hlines:
		var p := _px(Vector2(x_min, float(h["y"])))
		var txt := str(h["text"])
		var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_rect(Rect2(r.end.x - w - 8, p.y - 19, w + 6, 16), SURFACE)
		_text(Vector2(r.end.x - w - 5, p.y - 6), txt, 12, INK2)
	# Legend (>= 2 series): swatch + text ink.
	if legend and series.size() >= 2:
		var x := r.position.x + r.size.x * legend_at.x
		var y := r.position.y + r.size.y * legend_at.y + 12.0
		for s in series:
			var col: Color = SERIES[int(s.get("color_index", 0)) % SERIES.size()]
			if String(s.get("kind", "line")) == "line":
				draw_line(Vector2(x, y - 4), Vector2(x + 18, y - 4), col, 2.0)
			else:
				draw_rect(Rect2(x + 4, y - 9, 10, 10), col)
			_text(Vector2(x + 24, y), str(s["name"]), 13, INK)
			y += 20.0
