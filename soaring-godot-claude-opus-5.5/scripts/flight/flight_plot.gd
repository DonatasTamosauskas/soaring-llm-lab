class_name FlightPlot
extends RefCounted
## Headless PNG charts drawn straight into an Image (FLIGHT_SPEC §14.6).
##
## Works under --headless (no renderer): lines are Bresenham with a 2 px pen,
## text is an embedded 5x7 bitmap font. Layout is small multiples: each PlotPanel
## has exactly one x and one y scale (never a dual axis), a hairline grid,
## tick labels, an optional legend, and marks in the fixed categorical order
## (blue, orange, aqua, yellow, magenta, green, violet, red) on a light
## surface. Text always uses ink colours, never the series colour.
##
##   var p := FlightPlot.new(1600, 900, "Balloon - sparrow")
##   var a := p.panel(Rect2i(70, 60, 700, 360), "Altitude", "t (s)", "m")
##   a.line(ts, hs, 0, "altitude")
##   p.save(Paths.artifacts("flight").path_join("balloon.png"))

const SURFACE := Color8(252, 252, 251)
const INK := Color8(11, 11, 11)
const INK2 := Color8(82, 81, 78)
const MUTED := Color8(140, 138, 132)
const GRID := Color8(228, 227, 223)
const AXIS := Color8(170, 168, 162)
const SERIES: Array[Color] = [
	Color8(42, 120, 214), Color8(235, 104, 52), Color8(27, 175, 122), Color8(237, 161, 0),
	Color8(232, 123, 164), Color8(0, 131, 0), Color8(74, 58, 167), Color8(227, 73, 72),
]

var img: Image
var width := 1600
var height := 900
var title := ""
var panels: Array[PlotPanel] = []
var notes: PackedStringArray = []


func _init(w := 1600, h := 900, p_title := "") -> void:
	width = w
	height = h
	title = p_title
	img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(SURFACE)


static func series_color(slot: int) -> Color:
	return SERIES[posmod(slot, SERIES.size())]


func panel(rect: Rect2i, p_title := "", xlabel := "", ylabel := "") -> PlotPanel:
	var pn := PlotPanel.new(self, rect, p_title, xlabel, ylabel)
	panels.append(pn)
	return pn


## A footnote line under the title (numbers the reviewer should see).
func note(s: String) -> void:
	notes.append(s)


func render() -> Image:
	img.fill(SURFACE)
	if not title.is_empty():
		text(16, 12, title, INK, 3)
	var y := 38
	for n in notes:
		# Word-wrap to the figure width (panels start below ~2 note lines).
		for ln in _wrap(n, width - 32, 2):
			text(16, y, ln, INK2, 2)
			y += 18
	for pn in panels:
		pn.render()
	return img


static func _wrap(s: String, max_w: int, scale: int) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for word in s.split(" "):
		var trial := word if cur.is_empty() else cur + " " + word
		if text_width(trial, scale) > max_w and not cur.is_empty():
			out.append(cur)
			cur = word
		else:
			cur = trial
	if not cur.is_empty():
		out.append(cur)
	return out


func save(path: String) -> Error:
	render()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		push_error("[flight] plot save failed: %s" % path)
	return err


# ---------------------------------------------------------------------------
# Raster primitives (pixel space)

func px(x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < width and y < height:
		img.set_pixel(x, y, c)


func rect_fill(r: Rect2i, c: Color) -> void:
	var rr := r.intersection(Rect2i(0, 0, width, height))
	if rr.size.x > 0 and rr.size.y > 0:
		img.fill_rect(rr, c)


func line_px(x0: int, y0: int, x1: int, y1: int, c: Color, thick := 2) -> void:
	# Bresenham with a square pen of `thick` pixels.
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var guard := 0
	var o := (thick - 1) / 2
	while guard < 20000:
		guard += 1
		if thick <= 1:
			px(x0, y0, c)
		else:
			rect_fill(Rect2i(x0 - o, y0 - o, thick, thick), c)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy


func circle_px(cx: int, cy: int, r: int, c: Color, filled := true) -> void:
	for yy in range(-r, r + 1):
		for xx in range(-r, r + 1):
			var d2 := xx * xx + yy * yy
			if filled:
				if d2 <= r * r:
					px(cx + xx, cy + yy, c)
			elif d2 <= r * r and d2 >= (r - 1) * (r - 1):
				px(cx + xx, cy + yy, c)


func text(x: int, y: int, s: String, c: Color, scale := 2) -> int:
	var cx := x
	for ch in s:
		var rows: Array = _glyph(ch)
		for ry in 7:
			var bits: int = rows[ry]
			for rx in 5:
				if bits & (1 << (4 - rx)):
					rect_fill(Rect2i(cx + rx * scale, y + ry * scale, scale, scale), c)
		cx += 6 * scale
	return cx


static func text_width(s: String, scale := 2) -> int:
	return s.length() * 6 * scale


static func fmt(v: float) -> String:
	var a := absf(v)
	if a >= 100.0 or is_equal_approx(v, round(v)):
		return "%d" % int(round(v))
	# Up to 3 decimals, trailing zeros dropped (0.5, not 0.500).
	var s := "%.1f" % v if a >= 10.0 else ("%.2f" % v if a >= 1.0 else "%.3f" % v)
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	return s.trim_suffix(".")


static func nice_step(span: float, target := 5) -> float:
	if span <= 0.0 or not is_finite(span):
		return 1.0
	var raw := span / target
	var mag := pow(10.0, floorf(log(raw) / log(10.0)))
	var r := raw / mag
	var s := 1.0
	if r > 5.0:
		s = 10.0
	elif r > 2.0:
		s = 5.0
	elif r > 1.0:
		s = 2.0
	return s * mag


## Tiles PNG files into one contact sheet, scaled to fit `cols` columns.
static func contact_sheet(paths: PackedStringArray, cols: int, out_path: String, tile_w := 800, sheet_title := "") -> Error:
	var imgs: Array[Image] = []
	for p in paths:
		var im := Image.load_from_file(p)
		if im != null and not im.is_empty():
			imgs.append(im)
	if imgs.is_empty():
		return FAILED
	var tile_h := int(tile_w * 9.0 / 16.0)
	var rows := int(ceil(float(imgs.size()) / cols))
	var head := 40 if not sheet_title.is_empty() else 0
	var sheet := FlightPlot.new(cols * tile_w, rows * tile_h + head, sheet_title)
	sheet.render()
	for i in imgs.size():
		var im := imgs[i]
		im.convert(Image.FORMAT_RGBA8)
		var sc := minf(float(tile_w) / im.get_width(), float(tile_h) / im.get_height())
		im.resize(maxi(1, int(im.get_width() * sc)), maxi(1, int(im.get_height() * sc)), Image.INTERPOLATE_BILINEAR)
		sheet.img.blit_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), Vector2i((i % cols) * tile_w, head + (i / cols) * tile_h))
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	return sheet.img.save_png(out_path)


# ---------------------------------------------------------------------------

class PlotPanel:
	## The figure this panel draws into. Weak: the figure owns its panels,
	## and a strong back-reference was a RefCounted cycle that leaked every
	## plot (and its Image) a test made.
	var plot: FlightPlot:
		get:
			return _plot_ref.get_ref() as FlightPlot if _plot_ref != null else null
		set(v):
			_plot_ref = weakref(v) if v != null else null
	var _plot_ref: WeakRef
	var rect: Rect2i
	var title := ""
	var xlabel := ""
	var ylabel := ""
	var xmin := INF
	var xmax := -INF
	var ymin := INF
	var ymax := -INF
	var fixed_x := false
	var fixed_y := false
	var equal_aspect := false
	var y_zero := false
	var legend_pos := 0   # 0 top-right, 1 top-left, 2 bottom-right, 3 bottom-left
	## False for categorical rows (a key timeline): no y grid or tick labels.
	var y_ticks := true
	var _ops: Array = []
	var _legend: Array = []

	func _init(p: FlightPlot, r: Rect2i, t: String, xl: String, yl: String) -> void:
		plot = p
		rect = r
		title = t
		xlabel = xl
		ylabel = yl

	func set_x(a: float, b: float) -> PlotPanel:
		xmin = a
		xmax = b
		fixed_x = true
		return self

	func set_y(a: float, b: float) -> PlotPanel:
		ymin = a
		ymax = b
		fixed_y = true
		return self

	func _grow(x: float, y: float) -> void:
		if not is_finite(x) or not is_finite(y):
			return
		if not fixed_x:
			xmin = minf(xmin, x)
			xmax = maxf(xmax, x)
		if not fixed_y:
			ymin = minf(ymin, y)
			ymax = maxf(ymax, y)

	func line(xs: PackedFloat64Array, ys: PackedFloat64Array, slot: int, label := "", thick := 2, color := Color(0, 0, 0, 0)) -> void:
		var c := color if color.a > 0.0 else FlightPlot.series_color(slot)
		for i in mini(xs.size(), ys.size()):
			_grow(xs[i], ys[i])
		_ops.append(["line", xs, ys, c, thick])
		if not label.is_empty():
			_legend.append([label, c, "line"])

	func points(xs: PackedFloat64Array, ys: PackedFloat64Array, slot: int, label := "", r := 4, color := Color(0, 0, 0, 0)) -> void:
		var c := color if color.a > 0.0 else FlightPlot.series_color(slot)
		for i in mini(xs.size(), ys.size()):
			_grow(xs[i], ys[i])
		_ops.append(["pts", xs, ys, c, r])
		if not label.is_empty():
			_legend.append([label, c, "dot"])

	func hline(y: float, color: Color, label := "", dashed := true) -> void:
		_grow(xmin if is_finite(xmin) else 0.0, y)
		_ops.append(["hline", y, color, dashed])
		if not label.is_empty():
			_legend.append([label, color, "line"])

	func vline(x: float, color: Color, label := "") -> void:
		_grow(x, ymin if is_finite(ymin) else 0.0)
		_ops.append(["vline", x, color, label])

	func rect_data(r: Rect2, color: Color, label := "", fill := false) -> void:
		_grow(r.position.x, r.position.y)
		_grow(r.end.x, r.end.y)
		_ops.append(["rect", r, color, fill])
		if not label.is_empty():
			_legend.append([label, color, "box"])

	func segment(a: Vector2, b: Vector2, color: Color, thick := 3, label := "") -> void:
		_grow(a.x, a.y)
		_grow(b.x, b.y)
		_ops.append(["seg", a, b, color, thick])
		if not label.is_empty():
			_legend.append([label, color, "line"])

	func circle(c: Vector2, r: float, color: Color, label := "") -> void:
		_grow(c.x - r, c.y - r)
		_grow(c.x + r, c.y + r)
		_ops.append(["circ", c, r, color])
		if not label.is_empty():
			_legend.append([label, color, "line"])

	func arrow(a: Vector2, b: Vector2, color: Color, label := "") -> void:
		_grow(a.x, a.y)
		_grow(b.x, b.y)
		_ops.append(["arrow", a, b, color])
		if not label.is_empty():
			_legend.append([label, color, "line"])

	func label_at(p: Vector2, s: String, color := FlightPlot.INK2) -> void:
		_ops.append(["text", p, s, color])

	func map(x: float, y: float) -> Vector2i:
		var fx := (x - xmin) / maxf(xmax - xmin, 1e-12)
		var fy := (y - ymin) / maxf(ymax - ymin, 1e-12)
		return Vector2i(rect.position.x + int(round(fx * rect.size.x)), rect.position.y + rect.size.y - int(round(fy * rect.size.y)))

	func _finish_ranges() -> void:
		if not is_finite(xmin) or not is_finite(xmax):
			xmin = 0.0
			xmax = 1.0
		if not is_finite(ymin) or not is_finite(ymax):
			ymin = 0.0
			ymax = 1.0
		if y_zero and not fixed_y:
			ymin = minf(ymin, 0.0)
			ymax = maxf(ymax, 0.0)
		if xmax - xmin < 1e-9:
			xmin -= 0.5
			xmax += 0.5
		if ymax - ymin < 1e-9:
			ymin -= 0.5
			ymax += 0.5
		if not fixed_y:
			var pad := (ymax - ymin) * 0.06
			ymin -= pad
			ymax += pad
		if equal_aspect:
			var sx := (xmax - xmin) / rect.size.x
			var sy := (ymax - ymin) / rect.size.y
			if sx > sy:
				var c := 0.5 * (ymin + ymax)
				var hh := 0.5 * sx * rect.size.y
				ymin = c - hh
				ymax = c + hh
			else:
				var c2 := 0.5 * (xmin + xmax)
				var hw := 0.5 * sy * rect.size.x
				xmin = c2 - hw
				xmax = c2 + hw

	func render() -> void:
		_finish_ranges()
		var p := plot
		var r := rect
		# Title and axis labels in ink.
		p.text(r.position.x, r.position.y - 22, title, FlightPlot.INK, 2)
		if not ylabel.is_empty():
			p.text(r.position.x - 4 - FlightPlot.text_width(ylabel, 1) + 0, r.position.y - 10, "", FlightPlot.INK2, 1)
			p.text(r.position.x + FlightPlot.text_width(title, 2) + 12, r.position.y - 20, "(" + ylabel + ")", FlightPlot.INK2, 2)
		if not xlabel.is_empty():
			p.text(r.end.x - FlightPlot.text_width(xlabel, 2), r.end.y + 24, xlabel, FlightPlot.INK2, 2)
		# Grid and ticks.
		var xs := FlightPlot.nice_step(xmax - xmin, 6)
		var ys := FlightPlot.nice_step(ymax - ymin, 5)
		var gx := ceilf(xmin / xs) * xs
		while gx <= xmax + 1e-9:
			var q := map(gx, ymin)
			p.line_px(q.x, r.position.y, q.x, r.end.y, FlightPlot.GRID, 1)
			var s := FlightPlot.fmt(gx)
			p.text(q.x - FlightPlot.text_width(s, 1) / 2, r.end.y + 6, s, FlightPlot.INK2, 1)
			gx += xs
		var gy := ceilf(ymin / ys) * ys
		while y_ticks and gy <= ymax + 1e-9:
			var q2 := map(xmin, gy)
			p.line_px(r.position.x, q2.y, r.end.x, q2.y, FlightPlot.GRID, 1)
			var s2 := FlightPlot.fmt(gy)
			p.text(r.position.x - 6 - FlightPlot.text_width(s2, 1), q2.y - 3, s2, FlightPlot.INK2, 1)
			gy += ys
		# Axes (zero line emphasised when in range).
		p.line_px(r.position.x, r.end.y, r.end.x, r.end.y, FlightPlot.AXIS, 1)
		p.line_px(r.position.x, r.position.y, r.position.x, r.end.y, FlightPlot.AXIS, 1)
		if ymin < 0.0 and ymax > 0.0:
			var z := map(xmin, 0.0)
			p.line_px(r.position.x, z.y, r.end.x, z.y, FlightPlot.AXIS, 1)
		for op in _ops:
			match op[0]:
				"line":
					_draw_poly(op[1], op[2], op[3], op[4])
				"pts":
					var pxs: PackedFloat64Array = op[1]
					var pys: PackedFloat64Array = op[2]
					for i in mini(pxs.size(), pys.size()):
						if is_finite(pxs[i]) and is_finite(pys[i]):
							var q3 := map(pxs[i], pys[i])
							if r.grow(2).has_point(q3):
								p.circle_px(q3.x, q3.y, op[4] + 2, FlightPlot.SURFACE)
								p.circle_px(q3.x, q3.y, op[4], op[3])
				"hline":
					var q4 := map(xmin, op[1])
					if q4.y >= r.position.y and q4.y <= r.end.y:
						var step := 10 if op[3] else 1
						var xx := r.position.x
						while xx < r.end.x:
							p.line_px(xx, q4.y, mini(xx + (6 if op[3] else step), r.end.x), q4.y, op[2], 2)
							xx += step if not op[3] else 10
				"vline":
					var q5 := map(op[1], ymin)
					if q5.x >= r.position.x and q5.x <= r.end.x:
						p.line_px(q5.x, r.position.y, q5.x, r.end.y, op[2], 1)
						if not String(op[3]).is_empty():
							p.text(q5.x + 3, r.position.y + 3, op[3], FlightPlot.INK2, 1)
				"rect":
					var rr: Rect2 = op[1]
					var a := map(rr.position.x, rr.position.y)
					var b := map(rr.end.x, rr.end.y)
					var box := Rect2i(mini(a.x, b.x), mini(a.y, b.y), absi(b.x - a.x), absi(b.y - a.y))
					if op[3]:
						var cf: Color = op[2]
						p.rect_fill(box.intersection(r), Color(cf.r, cf.g, cf.b, 1.0).lerp(FlightPlot.SURFACE, 0.8))
					p.line_px(box.position.x, box.position.y, box.end.x, box.position.y, op[2], 2)
					p.line_px(box.position.x, box.end.y, box.end.x, box.end.y, op[2], 2)
					p.line_px(box.position.x, box.position.y, box.position.x, box.end.y, op[2], 2)
					p.line_px(box.end.x, box.position.y, box.end.x, box.end.y, op[2], 2)
				"seg":
					var s0 := map(op[1].x, op[1].y)
					var s1 := map(op[2].x, op[2].y)
					p.line_px(s0.x, s0.y, s1.x, s1.y, op[3], op[4])
				"circ":
					var n := 64
					var prev := Vector2i.ZERO
					for i in n + 1:
						var ang := TAU * i / n
						var cq := map(op[1].x + op[2] * cos(ang), op[1].y + op[2] * sin(ang))
						if i > 0:
							p.line_px(prev.x, prev.y, cq.x, cq.y, op[3], 2)
						prev = cq
				"arrow":
					var a0 := map(op[1].x, op[1].y)
					var a1 := map(op[2].x, op[2].y)
					p.line_px(a0.x, a0.y, a1.x, a1.y, op[3], 3)
					var dir := Vector2(a1 - a0).normalized()
					var nrm := Vector2(-dir.y, dir.x)
					var h1 := Vector2(a1) - dir * 14 + nrm * 7
					var h2 := Vector2(a1) - dir * 14 - nrm * 7
					p.line_px(a1.x, a1.y, int(h1.x), int(h1.y), op[3], 3)
					p.line_px(a1.x, a1.y, int(h2.x), int(h2.y), op[3], 3)
				"text":
					var tq := map(op[1].x, op[1].y)
					p.text(tq.x, tq.y, op[2], op[3], 1)
		_draw_legend()

	func _draw_poly(xs: PackedFloat64Array, ys: PackedFloat64Array, c: Color, thick: int) -> void:
		var have := false
		var prev := Vector2i.ZERO
		var clip := rect.grow(1)
		for i in mini(xs.size(), ys.size()):
			if not is_finite(xs[i]) or not is_finite(ys[i]):
				have = false
				continue
			var q := map(xs[i], ys[i])
			q.x = clampi(q.x, clip.position.x, clip.end.x)
			q.y = clampi(q.y, clip.position.y, clip.end.y)
			if have and (q != prev):
				plot.line_px(prev.x, prev.y, q.x, q.y, c, thick)
			elif not have:
				plot.px(q.x, q.y, c)
			prev = q
			have = true

	func _draw_legend() -> void:
		if _legend.size() < 2:
			return
		var w := 0
		for e in _legend:
			w = maxi(w, FlightPlot.text_width(e[0], 1))
		var bw := w + 34
		var bh := _legend.size() * 13 + 8
		var x0 := rect.end.x - bw - 6 if legend_pos in [0, 2] else rect.position.x + 6
		var y0 := rect.position.y + 6 if legend_pos in [0, 1] else rect.end.y - bh - 6
		plot.rect_fill(Rect2i(x0, y0, bw, bh), FlightPlot.SURFACE)
		plot.line_px(x0, y0, x0 + bw, y0, FlightPlot.GRID, 1)
		plot.line_px(x0, y0 + bh, x0 + bw, y0 + bh, FlightPlot.GRID, 1)
		plot.line_px(x0, y0, x0, y0 + bh, FlightPlot.GRID, 1)
		plot.line_px(x0 + bw, y0, x0 + bw, y0 + bh, FlightPlot.GRID, 1)
		var yy := y0 + 6
		for e in _legend:
			var c: Color = e[1]
			match e[2]:
				"dot":
					plot.circle_px(x0 + 12, yy + 3, 4, c)
				"box":
					plot.rect_fill(Rect2i(x0 + 6, yy - 1, 14, 9), c)
				_:
					plot.line_px(x0 + 5, yy + 3, x0 + 21, yy + 3, c, 2)
			plot.text(x0 + 28, yy, e[0], FlightPlot.INK, 1)
			yy += 13


# ---------------------------------------------------------------------------
# 5x7 bitmap font. Lower case maps to upper case.

static func _glyph(ch: String) -> Array:
	var u := ch.to_upper()
	if _FONT.has(u):
		return _FONT[u]
	return _FONT["?"]


const _FONT := {
	" ": [0, 0, 0, 0, 0, 0, 0],
	"0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14], "2": [14, 17, 1, 2, 4, 8, 31],
	"3": [31, 2, 4, 2, 1, 17, 14], "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14],
	"6": [6, 8, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14],
	"9": [14, 17, 17, 15, 1, 2, 12],
	"A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30], "C": [14, 17, 16, 16, 16, 17, 14],
	"D": [28, 18, 17, 17, 17, 18, 28], "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
	"G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17], "I": [14, 4, 4, 4, 4, 4, 14],
	"J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
	"M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 17, 25, 21, 19, 17, 17], "O": [14, 17, 17, 17, 17, 17, 14],
	"P": [30, 17, 17, 30, 16, 16, 16], "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
	"S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4], "U": [17, 17, 17, 17, 17, 17, 14],
	"V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 21, 10], "X": [17, 17, 10, 4, 10, 17, 17],
	"Y": [17, 17, 17, 10, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
	".": [0, 0, 0, 0, 0, 12, 12], ";": [0, 12, 12, 0, 12, 4, 8], ",": [0, 0, 0, 0, 12, 4, 8], "-": [0, 0, 0, 31, 0, 0, 0],
	"+": [0, 4, 4, 31, 4, 4, 0], "/": [0, 1, 2, 4, 8, 16, 0], "%": [24, 25, 2, 4, 8, 19, 3],
	"°": [12, 18, 18, 12, 0, 0, 0], ":": [0, 12, 12, 0, 12, 12, 0], "(": [2, 4, 8, 8, 8, 4, 2],
	")": [8, 4, 2, 2, 2, 4, 8], "=": [0, 0, 31, 0, 31, 0, 0], "_": [0, 0, 0, 0, 0, 0, 31],
	"<": [2, 4, 8, 16, 8, 4, 2], ">": [8, 4, 2, 1, 2, 4, 8], "*": [0, 4, 21, 14, 21, 4, 0],
	"?": [14, 17, 1, 2, 4, 0, 4], "!": [4, 4, 4, 4, 4, 0, 4], "'": [4, 4, 8, 0, 0, 0, 0],
	"[": [14, 8, 8, 8, 8, 8, 14], "]": [14, 2, 2, 2, 2, 2, 14], "|": [4, 4, 4, 4, 4, 4, 4],
	"#": [10, 10, 31, 10, 31, 10, 10], "^": [4, 10, 17, 0, 0, 0, 0], "~": [0, 0, 8, 21, 2, 0, 0],
	"X2": [0, 0, 0, 0, 0, 0, 0], "×": [0, 17, 10, 4, 10, 17, 0], "±": [4, 4, 31, 4, 4, 0, 31],
	"Φ": [4, 14, 21, 21, 21, 14, 4], "Α": [14, 17, 17, 31, 17, 17, 17], "Γ": [31, 16, 16, 16, 16, 16, 16],
	"Θ": [14, 17, 17, 31, 17, 17, 14], "Ψ": [21, 21, 21, 14, 4, 4, 4], "Ω": [14, 17, 17, 17, 10, 10, 27],
	"Δ": [4, 4, 10, 10, 17, 17, 31], "Σ": [31, 16, 8, 4, 8, 16, 31], "Μ": [17, 27, 21, 21, 17, 17, 17],
	"Λ": [4, 4, 10, 10, 17, 17, 17],
}
