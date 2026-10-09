class_name AudioPlot
extends RefCounted
## Review images drawn straight into a Godot Image (works headless): labelled
## spectrograms of clips and simple line/dot charts for the audio evidence
## under artifacts/audio/.
##
## Text uses a built-in 5x7 pixel font (upper case, digits, punctuation), so
## no renderer or font import is needed. Colours follow the project's data-viz
## reference palette (light surface, recessive hairline grid, fixed series
## order; the spectrogram is a one-hue sequential ramp with a scale legend).

const SURFACE := Color("#fcfcfb")
const INK := Color("#0b0b0b")
const INK_2 := Color("#52514e")
const GRID := Color("#e6e5e0")
const AXIS := Color("#b9b8b2")
## Categorical slots, fixed order (never cycled).
const SERIES: Array[Color] = [Color("#2a78d6"), Color("#eb6834"), Color("#1baf7a"), Color("#eda100"),
	Color("#e87ba4"), Color("#008300"), Color("#4a3aa7"), Color("#e34948")]
## Sequential blue ramp, quiet -> loud (surface at the bottom so silence recedes).
const RAMP: Array[Color] = [Color("#fcfcfb"), Color("#cde2fb"), Color("#9ec5f4"), Color("#6da7ec"),
	Color("#3987e5"), Color("#256abf"), Color("#184f95"), Color("#0d366b"), Color("#061a36")]

const GLYPHS := {
	"0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14], "2": [14, 17, 1, 2, 4, 8, 31],
	"3": [31, 2, 4, 2, 1, 17, 14], "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14],
	"6": [6, 8, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14],
	"9": [14, 17, 17, 15, 1, 2, 12], "A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30],
	"C": [14, 17, 16, 16, 16, 17, 14], "D": [28, 18, 17, 17, 17, 18, 28], "E": [31, 16, 16, 30, 16, 16, 31],
	"F": [31, 16, 16, 30, 16, 16, 16], "G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17],
	"I": [14, 4, 4, 4, 4, 4, 14], "J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17],
	"L": [16, 16, 16, 16, 16, 16, 31], "M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 17, 25, 21, 19, 17, 17],
	"O": [14, 17, 17, 17, 17, 17, 14], "P": [30, 17, 17, 30, 16, 16, 16], "Q": [14, 17, 17, 17, 21, 18, 13],
	"R": [30, 17, 17, 30, 20, 18, 17], "S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4],
	"U": [17, 17, 17, 17, 17, 17, 14], "V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 21, 10],
	"X": [17, 17, 10, 4, 10, 17, 17], "Y": [17, 17, 17, 10, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
	" ": [0, 0, 0, 0, 0, 0, 0], ".": [0, 0, 0, 0, 0, 12, 12], ",": [0, 0, 0, 0, 12, 4, 8],
	":": [0, 12, 12, 0, 12, 12, 0], ";": [0, 12, 12, 0, 12, 4, 8], "-": [0, 0, 0, 31, 0, 0, 0], "+": [0, 4, 4, 31, 4, 4, 0],
	"/": [0, 1, 2, 4, 8, 16, 0], "(": [2, 4, 8, 8, 8, 4, 2], ")": [8, 4, 2, 2, 2, 4, 8],
	"%": [24, 25, 2, 4, 8, 19, 3], "=": [0, 0, 31, 0, 31, 0, 0], "_": [0, 0, 0, 0, 0, 0, 31],
	"<": [2, 4, 8, 16, 8, 4, 2], ">": [8, 4, 2, 1, 2, 4, 8], "'": [12, 4, 8, 0, 0, 0, 0],
	"#": [10, 10, 31, 10, 31, 10, 10], "|": [4, 4, 4, 4, 4, 4, 4], "*": [0, 4, 21, 14, 21, 4, 0],
	"!": [4, 4, 4, 4, 4, 0, 4], "?": [14, 17, 1, 2, 4, 0, 4], "[": [14, 8, 8, 8, 8, 8, 14],
	"]": [14, 2, 2, 2, 2, 2, 14], "~": [0, 0, 8, 21, 2, 0, 0], "^": [4, 10, 17, 0, 0, 0, 0],
}


static func canvas(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(SURFACE)
	return img


static func text_width(s: String, scale: int = 1) -> int:
	return s.length() * 6 * scale - scale


## Draws s with its top-left at (x, y). Lower case is drawn as upper case.
static func text(img: Image, x: int, y: int, s: String, color: Color = INK, scale: int = 1) -> void:
	var cx := x
	var w := img.get_width()
	var h := img.get_height()
	for ch in s.to_upper():
		var g: Array = GLYPHS.get(ch, GLYPHS["?"])
		for row in 7:
			var bits: int = g[row]
			for col in 5:
				if bits & (16 >> col):
					for dy in scale:
						for dx in scale:
							var px := cx + col * scale + dx
							var py := y + row * scale + dy
							if px >= 0 and py >= 0 and px < w and py < h:
								img.set_pixel(px, py, color)
		cx += 6 * scale


static func text_right(img: Image, x_right: int, y: int, s: String, color: Color = INK, scale: int = 1) -> void:
	text(img, x_right - text_width(s, scale), y, s, color, scale)


static func rect(img: Image, x: int, y: int, w: int, h: int, color: Color) -> void:
	var r := Rect2i(x, y, w, h).intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x > 0 and r.size.y > 0:
		img.fill_rect(r, color)


## Anti-aliasing-free line of the given width (px).
static func line(img: Image, a: Vector2, b: Vector2, color: Color, width: int = 1) -> void:
	var steps := int(ceil(maxf(absf(b.x - a.x), absf(b.y - a.y)))) + 1
	var off := width / 2
	for i in steps:
		var p := a.lerp(b, float(i) / maxf(1.0, steps - 1))
		rect(img, int(round(p.x)) - off, int(round(p.y)) - off, width, width, color)


static func dot(img: Image, c: Vector2, radius: float, color: Color, ring: Color = SURFACE) -> void:
	var r2 := radius + 2.0
	for y in range(int(c.y - r2), int(c.y + r2) + 1):
		for x in range(int(c.x - r2), int(c.x + r2) + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var d := Vector2(x, y).distance_to(c)
			if d <= radius:
				img.set_pixel(x, y, color)
			elif d <= r2:
				img.set_pixel(x, y, ring)


## [Vector2(x offset, row)] per series for a legend `width` px wide.
static func _legend_layout(series: Array, width: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var x := 0
	var row := 0
	for s in series:
		var wd := 20 + text_width(str(s["name"])) + 24
		if x > 0 and x + wd > width:
			x = 0
			row += 1
		out.append(Vector2(x, row))
		x += maxi(wd, width / 3)
	if out.is_empty():
		out.append(Vector2.ZERO)
	return out


static func ramp(t: float) -> Color:
	t = clampf(t, 0.0, 1.0) * (RAMP.size() - 1)
	var i := mini(int(t), RAMP.size() - 2)
	return RAMP[i].lerp(RAMP[i + 1], t - i)


static func _nice_step(span: float, target: int) -> float:
	var raw := span / maxf(1.0, target)
	var mag := pow(10.0, floor(log(raw) / log(10.0)))
	for m in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if raw <= m * mag:
			return m * mag
	return 10.0 * mag


static func fmt(v: float) -> String:
	if absf(v) >= 1000.0 and fmod(absf(v), 1000.0) < 1e-6:
		return "%dK" % int(v / 1000.0)
	if absf(v - round(v)) < 1e-6:
		return str(int(round(v)))
	if absf(v) >= 10.0:
		return "%.0f" % v
	return ("%.2f" % v).rstrip("0").rstrip(".")


## A line/dot chart. series: [{name, x: PackedFloat32Array, y: PackedFloat32Array,
## dots: bool, line: bool}]; colours follow series order. opts: x_label,
## y_label, x_min/x_max/y_min/y_max, hlines: [{y, label}], note (a line under
## the title), log_x.
static func chart(title: String, series: Array, opts: Dictionary = {}) -> Image:
	var w: int = opts.get("width", 960)
	var h: int = opts.get("height", 540)
	var img := canvas(w, h)
	var left := 84
	var right := 28
	# Title (16..30), note (40..47), then the y-axis title on its own line
	# above the plot, so none of them touch.
	var top := 76 if opts.has("note") else 60
	# Legend rows: items flow left to right and wrap (long names get room).
	var legend_rows := _legend_layout(series, w - 84 - 28)
	var legend_h := 18 * (int(legend_rows[-1].y) + 1) if series.size() > 1 else 0
	# Tick labels (+8), the x-axis title (+24..31), then the legend below it.
	var bottom := 44 + legend_h
	text(img, left, 16, title, INK, 2)
	if opts.has("note"):
		text(img, left, 40, str(opts["note"]), INK_2, 1)
	var xmin := INF
	var xmax := -INF
	var ymin := INF
	var ymax := -INF
	for s in series:
		for v in s["x"]:
			xmin = minf(xmin, v)
			xmax = maxf(xmax, v)
		for v in s["y"]:
			ymin = minf(ymin, v)
			ymax = maxf(ymax, v)
	for hl in opts.get("hlines", []):
		ymin = minf(ymin, hl["y"])
		ymax = maxf(ymax, hl["y"])
	xmin = opts.get("x_min", xmin)
	xmax = opts.get("x_max", xmax)
	ymin = opts.get("y_min", ymin)
	ymax = opts.get("y_max", ymax)
	if xmax <= xmin:
		xmax = xmin + 1.0
	if ymax <= ymin:
		ymax = ymin + 1.0
	var pw := w - left - right
	var ph := h - top - bottom
	var log_x: bool = opts.get("log_x", false)
	var fx := func(v: float) -> float:
		if log_x:
			return left + pw * (log(maxf(v, 1e-9) / xmin) / log(xmax / xmin))
		return left + pw * (v - xmin) / (xmax - xmin)
	var fy := func(v: float) -> float:
		return top + ph * (1.0 - (v - ymin) / (ymax - ymin))
	# Grid and ticks (hairlines, recessive).
	var ys := _nice_step(ymax - ymin, 6)
	var yv := ceilf(ymin / ys) * ys
	while yv <= ymax + 1e-9:
		var py := int(fy.call(yv))
		rect(img, left, py, pw, 1, GRID)
		text_right(img, left - 8, py - 3, fmt(yv), INK_2)
		yv += ys
	var xticks: Array = []
	if log_x:
		var dec := pow(10.0, floor(log(xmin) / log(10.0)))
		while dec <= xmax:
			for m in [1.0, 2.0, 5.0]:
				if dec * m >= xmin - 1e-9 and dec * m <= xmax + 1e-9:
					xticks.append(dec * m)
			dec *= 10.0
	else:
		var xs := _nice_step(xmax - xmin, 8)
		var xv := ceilf(xmin / xs) * xs
		while xv <= xmax + 1e-9:
			xticks.append(xv)
			xv += xs
	for xv2 in xticks:
		var px := int(fx.call(xv2))
		rect(img, px, top, 1, ph, GRID)
		var lab := fmt(xv2)
		text(img, px - text_width(lab) / 2, top + ph + 8, lab, INK_2)
	rect(img, left, top + ph, pw, 1, AXIS)
	rect(img, left, top, 1, ph, AXIS)
	# Reference lines (thresholds) in secondary ink with a label.
	for hl in opts.get("hlines", []):
		var py2 := int(fy.call(hl["y"]))
		for x in range(left, left + pw, 1):
			img.set_pixel(x, py2, INK_2)
		text_right(img, left + pw - 4, py2 - 10, str(hl.get("label", "")), INK_2)
	for si in series.size():
		var s: Dictionary = series[si]
		var col: Color = s.get("color", SERIES[si % SERIES.size()])
		var xa: PackedFloat32Array = s["x"]
		var ya: PackedFloat32Array = s["y"]
		if s.get("line", true):
			for i in range(1, mini(xa.size(), ya.size())):
				line(img, Vector2(fx.call(xa[i - 1]), fy.call(ya[i - 1])), Vector2(fx.call(xa[i]), fy.call(ya[i])), col, 2)
		if s.get("dots", false):
			for i in mini(xa.size(), ya.size()):
				dot(img, Vector2(fx.call(xa[i]), fy.call(ya[i])), 4.0, col)
		if s.has("labels"):
			var labs: Array = s["labels"]
			for i in mini(labs.size(), xa.size()):
				text(img, int(fx.call(xa[i])) + 7, int(fy.call(ya[i])) - 10, str(labs[i]), INK)
	var xl: String = opts.get("x_label", "")
	text(img, left + pw / 2 - text_width(xl) / 2, top + ph + 24, xl, INK_2)
	var yl: String = opts.get("y_label", "")
	text(img, 8, top - 16, yl, INK_2)
	# Legend (always present for >= 2 series): swatch + name in ink.
	if series.size() > 1:
		for si in series.size():
			var pos: Vector2 = legend_rows[si]
			var lx := left + int(pos.x)
			var ly := h - legend_h + 2 + int(pos.y) * 18
			var col2: Color = series[si].get("color", SERIES[si % SERIES.size()])
			rect(img, lx, ly + 2, 14, 4, col2)
			text(img, lx + 20, ly, str(series[si]["name"]), INK)
	return img


const SPEC_LO := 50.0
const SPEC_DB_MIN := -96.0
const SPEC_DB_MAX := -6.0


## A labelled review image of one clip: waveform envelope (dBFS) on top, a
## log-frequency spectrogram below (50 Hz .. Nyquist, -96..-6 dBFS on a fixed
## scale so clips are comparable), and a scale legend. Stereo clips are
## analysed as mono.
static func spectrogram(buf: PackedFloat32Array, rate: float, title: String, note: String = "") -> Image:
	var dur := buf.size() / rate
	var n := 1024
	# At least 360 columns so short clips keep readable time labels.
	var cols := clampi(int(dur * 200.0), 360, 1400)
	var hop := maxi(8, int(buf.size() / float(cols)))
	cols = maxi(1, int(ceil(buf.size() / float(hop))))
	var left := 70
	var right := 110
	var top := 44
	var wave_h := 70
	var gap := 14
	var spec_h := 256
	var bottom := 40
	var w := left + cols + right
	var h := top + wave_h + gap + spec_h + bottom
	var img := canvas(maxi(w, 640), h)
	text(img, left, 10, title, INK, 2)
	if not note.is_empty():
		text(img, left, 30, note, INK_2)
	# Waveform: per-column peak and RMS in dBFS (-60..0), mirrored.
	var mid := top + wave_h / 2
	rect(img, left, top, cols, wave_h, Color("#f3f2ee"))
	for c in cols:
		var a := c * hop
		var b := mini(buf.size(), a + hop)
		var pk := 0.0
		var s := 0.0
		for i in range(a, b):
			pk = maxf(pk, absf(buf[i]))
			s += buf[i] * buf[i]
		var r := sqrt(s / maxf(1.0, b - a))
		var hp := clampf((AudioAnalysis.db(pk) + 60.0) / 60.0, 0.0, 1.0) * wave_h * 0.5
		var hr := clampf((AudioAnalysis.db(r) + 60.0) / 60.0, 0.0, 1.0) * wave_h * 0.5
		rect(img, left + c, int(mid - hp), 1, int(hp * 2.0) + 1, SERIES[0].lerp(SURFACE, 0.55))
		rect(img, left + c, int(mid - hr), 1, int(hr * 2.0) + 1, SERIES[0])
	# -1 dBFS guide lines (the clipping budget).
	var clip_h := (59.0 / 60.0) * wave_h * 0.5
	for x in range(left, left + cols, 3):
		img.set_pixel(x, int(mid - clip_h), SERIES[7])
		img.set_pixel(x, int(mid + clip_h), SERIES[7])
	text_right(img, left - 6, top - 2, "0DB", INK_2)
	text_right(img, left - 6, mid - 3, "WAVE", INK_2)
	# Spectrogram.
	var sy := top + wave_h + gap
	var nyq := rate * 0.5
	var lo_l := log(SPEC_LO)
	var hi_l := log(nyq)
	var row_bin := PackedFloat32Array()
	row_bin.resize(spec_h + 1)
	for row in spec_h + 1:
		var f := exp(lo_l + (hi_l - lo_l) * (1.0 - float(row) / spec_h))
		row_bin[row] = f * n / rate
	for c in cols:
		var mag := AudioAnalysis.magnitude(buf, c * hop + hop / 2 - n / 2, n)
		for row in spec_h:
			# Max over the bins this pixel row covers (rows are wider than bins up high).
			var b_hi := row_bin[row]
			var b_lo := row_bin[row + 1]
			var i0 := int(floor(b_lo))
			var i1 := maxi(i0, int(floor(b_hi)))
			var m := 0.0
			for i in range(i0, mini(i1, n / 2) + 1):
				m = maxf(m, mag[i])
			var t := (AudioAnalysis.db(m) - SPEC_DB_MIN) / (SPEC_DB_MAX - SPEC_DB_MIN)
			img.set_pixel(left + c, sy + row, ramp(t))
	# Frequency ticks.
	for f in [100.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]:
		if f > nyq:
			continue
		var py := int(sy + spec_h * (1.0 - (log(f) - lo_l) / (hi_l - lo_l)))
		rect(img, left - 5, py, 5, 1, INK_2)
		text_right(img, left - 8, py - 3, fmt(f), INK_2)
	text_right(img, left - 8, sy - 12, "HZ", INK_2)
	# Time ticks.
	var ts := _nice_step(dur, clampi(cols / 70, 3, 10))
	var tv := 0.0
	while tv <= dur + 1e-6:
		var px := int(left + tv * rate / hop)
		rect(img, px, sy + spec_h, 1, 5, INK_2)
		var lab := fmt(tv)
		text(img, px - text_width(lab) / 2, sy + spec_h + 9, lab, INK_2)
		tv += ts
	text(img, left + cols / 2 - 20, sy + spec_h + 24, "TIME S", INK_2)
	# Scale legend.
	var lx := left + cols + 30
	for row in spec_h:
		var t2 := 1.0 - float(row) / spec_h
		rect(img, lx, sy + row, 16, 1, ramp(t2))
	text(img, lx + 22, sy - 3, fmt(SPEC_DB_MAX), INK_2)
	text(img, lx + 22, sy + spec_h / 2 - 3, fmt((SPEC_DB_MAX + SPEC_DB_MIN) * 0.5), INK_2)
	text(img, lx + 22, sy + spec_h - 7, fmt(SPEC_DB_MIN), INK_2)
	text(img, lx, sy - 14, "DBFS", INK_2)
	return img


## Stacks images vertically (contact sheets).
static func stack(images: Array, pad: int = 8) -> Image:
	var w := 0
	var h := 0
	for im in images:
		w = maxi(w, (im as Image).get_width())
		h += (im as Image).get_height() + pad
	var out := canvas(w, maxi(1, h))
	var y := 0
	for im in images:
		out.blit_rect(im, Rect2i(0, 0, im.get_width(), im.get_height()), Vector2i(0, y))
		y += im.get_height() + pad
	return out
