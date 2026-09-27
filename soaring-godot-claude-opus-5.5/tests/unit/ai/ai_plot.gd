extends RefCounted
## Tiny raster plotter on a Godot Image (works headless - no renderer), for
## trajectory plots and charts that document AI behaviour. Includes a 5x7
## bitmap font so plots carry their own labels and legends.

var img: Image
var w := 0
var h := 0
## World rectangle mapped onto the image: x -> right, z -> down (top-down).
var wmin := Vector2(-100, -100)
var wmax := Vector2(100, 100)

const FONT := {
	"A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
	"B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
	"C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
	"D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
	"E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
	"F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
	"G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
	"H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
	"I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
	"J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
	"K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
	"L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
	"M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
	"N": ["10001", "10001", "11001", "10101", "10011", "10001", "10001"],
	"O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
	"P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
	"Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
	"R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
	"S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
	"T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
	"U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
	"V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
	"W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
	"X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
	"Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
	"Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
	"0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
	"1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
	"2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
	"3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
	"4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
	"5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
	"6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
	"7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
	"8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
	"9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
	".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
	",": ["00000", "00000", "00000", "00000", "01100", "00100", "01000"],
	":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
	"-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
	"+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
	"/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
	"%": ["11001", "11010", "00010", "00100", "01000", "01011", "10011"],
	">": ["10000", "01000", "00100", "00010", "00100", "01000", "10000"],
	"<": ["00001", "00010", "00100", "01000", "00100", "00010", "00001"],
	"=": ["00000", "00000", "11111", "00000", "11111", "00000", "00000"],
	"(": ["00010", "00100", "01000", "01000", "01000", "00100", "00010"],
	")": ["01000", "00100", "00010", "00010", "00010", "00100", "01000"],
	"_": ["00000", "00000", "00000", "00000", "00000", "00000", "11111"],
	"#": ["01010", "01010", "11111", "01010", "11111", "01010", "01010"],
	"!": ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
	"?": ["01110", "10001", "00001", "00010", "00100", "00000", "00100"],
	"{": ["00011", "00100", "00100", "01000", "00100", "00100", "00011"],
	"}": ["11000", "00100", "00100", "00010", "00100", "00100", "11000"],
	"[": ["01110", "01000", "01000", "01000", "01000", "01000", "01110"],
	"]": ["01110", "00010", "00010", "00010", "00010", "00010", "01110"],
	"'": ["00100", "00100", "00000", "00000", "00000", "00000", "00000"],
	" ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
}


func _init(width: int, height: int, bg: Color, world_min: Vector2 = Vector2(-100, -100), world_max: Vector2 = Vector2(100, 100)) -> void:
	w = width
	h = height
	wmin = world_min
	wmax = world_max
	img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(bg)


## World (x, z) -> pixel.
func px(p: Vector2) -> Vector2:
	return Vector2((p.x - wmin.x) / (wmax.x - wmin.x) * w, (p.y - wmin.y) / (wmax.y - wmin.y) * h)


func top(p: Vector3) -> Vector2:
	return px(Vector2(p.x, p.z))


func dot(p: Vector2, c: Color, r: int = 0) -> void:
	var xi := int(p.x)
	var yi := int(p.y)
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r + r:
				continue
			_blend(xi + dx, yi + dy, c)


func _blend(x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= w or y >= h:
		return
	if c.a >= 0.999:
		img.set_pixel(x, y, c)
	else:
		img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color(c.r, c.g, c.b, 1.0), c.a))


func line(a: Vector2, b: Vector2, c: Color, width: int = 0) -> void:
	var d := b - a
	var n := int(maxf(absf(d.x), absf(d.y)))
	if n > 4000:
		return
	for i in n + 1:
		var t := float(i) / maxf(n, 1)
		dot(a + d * t, c, width)


func polyline(pts: PackedVector2Array, c: Color, width: int = 0) -> void:
	for i in range(1, pts.size()):
		line(pts[i - 1], pts[i], c, width)


func circle(center: Vector2, r: float, c: Color, fill := false) -> void:
	if fill:
		for y in range(int(center.y - r), int(center.y + r) + 1):
			for x in range(int(center.x - r), int(center.x + r) + 1):
				if Vector2(x, y).distance_to(center) <= r:
					_blend(x, y, c)
		return
	var n := int(maxf(r * 6.0, 12.0))
	for i in n:
		var a := TAU * i / n
		_blend(int(center.x + cos(a) * r), int(center.y + sin(a) * r), c)


func rect(p0: Vector2, p1: Vector2, c: Color, fill := true) -> void:
	if fill:
		for y in range(int(minf(p0.y, p1.y)), int(maxf(p0.y, p1.y)) + 1):
			for x in range(int(minf(p0.x, p1.x)), int(maxf(p0.x, p1.x)) + 1):
				_blend(x, y, c)
	else:
		line(p0, Vector2(p1.x, p0.y), c)
		line(Vector2(p1.x, p0.y), p1, c)
		line(p1, Vector2(p0.x, p1.y), c)
		line(Vector2(p0.x, p1.y), p0, c)


## Filled convex polygon (pixel coordinates).
func poly(pts: PackedVector2Array, c: Color) -> void:
	if pts.size() < 3:
		return
	var lo := pts[0]
	var hi := pts[0]
	for q in pts:
		lo = lo.min(q)
		hi = hi.max(q)
	for y in range(int(lo.y), int(hi.y) + 1):
		for x in range(int(lo.x), int(hi.x) + 1):
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
				_blend(x, y, c)


func cross(p: Vector2, c: Color, s: int = 4) -> void:
	line(p + Vector2(-s, -s), p + Vector2(s, s), c, 1)
	line(p + Vector2(-s, s), p + Vector2(s, -s), c, 1)


## Text at pixel position, scale = pixel size of one font dot.
func text(p: Vector2, s: String, c: Color, scale: int = 2) -> void:
	var x := int(p.x)
	for ch in s.to_upper():
		var g: Array = FONT.get(ch, FONT["?"])
		for row in 7:
			var bits: String = g[row]
			for col in 5:
				if bits[col] == "1":
					for sy in scale:
						for sx in scale:
							_blend(x + col * scale + sx, int(p.y) + row * scale + sy, c)
		x += 6 * scale


func save(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	print("[ai] plot %s -> %s" % [error_string(err), path])
	return err
