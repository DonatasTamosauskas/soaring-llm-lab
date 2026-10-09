extends Node
## Plots the air: where it rises, how strongly, and how smoothly.
##
##   tools/gd.sh world --headless res://tests/shots/world_wind_plot.tscn
##
## Writes artifacts/world/wind_map.png (vertical wind at 120 m over the whole
## arena, hill-shaded terrain underneath, thermal centres marked),
## wind_thermal_section.png (x-y slice through the meadow thermal) and
## wind_ridge_section.png (slice across the west cliff's ridge lift). Every
## plot has metre axes, a title and a colour bar in m/s (a small built-in
## bitmap font: the run is headless, so there is no renderer to draw text).

const RAMP := [[0.0, Color("f7f0d2")], [0.5, Color("f5e6a8")], [1.5, Color("f2c14e")], [3.0, Color("e0703a")], [4.5, Color("a8325e")], [6.0, Color("5b1a5e")]]
const INK := Color(0.12, 0.12, 0.14)
const PAPER := Color(1, 1, 1)

## 5x7 glyphs, one string of 7 rows x 5 columns ("#" = ink).
const FONT := {
	"0": ".###.#...##..###.#.###..##...#.###.", "1": "..#...##....#....#....#....#...###.",
	"2": ".###.#...#....#...#...#...#...#####", "3": "####.....#...#...##.....##...#.###.",
	"4": "...#...##..#.#.#..#.#####...#....#.", "5": "######....####.....#....##...#.###.",
	"6": "..##..#...#....####.#...##...#.###.", "7": "#####....#...#...#...#....#....#...",
	"8": ".###.#...##...#.###.#...##...#.###.", "9": ".###.#...##...#.####....#...#..##..",
	"A": ".###.#...##...#######...##...##...#", "B": "####.#...##...#####.#...##...#####.",
	"C": ".###.#...##....#....#....#...#.###.", "D": "###..#..#.#...##...##...##..#.###..",
	"E": "######....#....####.#....#....#####", "F": "######....#....####.#....#....#....",
	"G": ".###.#...##....#.####...##...#.####", "H": "#...##...##...#######...##...##...#",
	"I": ".###...#....#....#....#....#...###.", "J": "..###...#....#....#.#..#.#..#..##..",
	"K": "#...##..#.#.#..##...#.#..#..#.#...#", "L": "#....#....#....#....#....#....#####",
	"M": "#...###.###.#.##...##...##...##...#", "N": "#...###..##.#.##..###...##...##...#",
	"O": ".###.#...##...##...##...##...#.###.", "P": "####.#...##...#####.#....#....#....",
	"Q": ".###.#...##...##...##.#.##..#..##.#", "R": "####.#...##...#####.#.#..#..#.#...#",
	"S": ".#####....#.....###.....#....#####.", "T": "#####..#....#....#....#....#....#..",
	"U": "#...##...##...##...##...##...#.###.", "V": "#...##...##...##...##...#.#.#...#..",
	"W": "#...##...##...##.#.##.#.##.#.#.#.#.", "X": "#...##...#.#.#...#...#.#.#...##...#",
	"Y": "#...##...#.#.#...#....#....#....#..", "Z": "#####....#...#...#...#...#....#####",
	" ": "...................................", "-": "...............###.................",
	".": "..............................##...", "/": "....#....#...#...#...#...#....#....",
	":": "......##...##........##...##.......", "(": "...#...#...#....#....#.....#.....#.",
	")": ".#.....#.....#....#....#...#...#...", ",": ".........................##...#..#.",
	"+": "..........#....#..#####..#....#....", "=": "..........#####.....#####..........",
	">": ".#.....#.....#.....#...#...#...#...",
}


func _ready() -> void:
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.with_decoration = false
	add_child(w)
	w.set_air_time(30.0)
	var out := Paths.artifacts("world")
	_map(w, out.path_join("wind_map.png"))
	var th: Dictionary = w.get_thermals()[2]
	var c: Vector3 = th["position"]
	_section(w, out.path_join("wind_thermal_section.png"), Vector3(c.x - 90, 0, c.z), Vector3(1, 0, 0), 180.0, 300.0,
		"MEADOW THERMAL - W-E SLICE AT Z = %d M" % int(c.z))
	var cl := WorldLayout.CLIFF
	var mid := cl[2].lerp(cl[3], 0.5)
	_section(w, out.path_join("wind_ridge_section.png"), Vector3(mid.x - 40, 0, mid.y), Vector3(1, 0, 0), 200.0, 150.0,
		"CLIFF RIDGE LIFT - W-E SLICE AT Z = %d M" % int(mid.y))
	get_tree().quit()


static func _ramp(v: float) -> Color:
	if v <= 0.0:
		return Color(0.25, 0.45, 0.85, clampf(-v / 1.0, 0.0, 0.8))
	for i in RAMP.size() - 1:
		if v <= RAMP[i + 1][0]:
			var t: float = (v - RAMP[i][0]) / (RAMP[i + 1][0] - RAMP[i][0])
			return (RAMP[i][1] as Color).lerp(RAMP[i + 1][1], t)
	return RAMP[-1][1]


# --- tiny text and axes -------------------------------------------------------

## Draws s (upper-case) with its top-left at (x, y), each font pixel k x k.
static func _text(img: Image, x: int, y: int, s: String, k := 2, col := INK) -> void:
	var cx := x
	for ch in s.to_upper():
		var g: String = FONT.get(ch, FONT[" "])
		for r in 7:
			for c in 5:
				if g[r * 5 + c] == "#":
					img.fill_rect(Rect2i(cx + c * k, y + r * k, k, k), col)
		cx += 6 * k


static func _text_w(s: String, k := 2) -> int:
	return s.length() * 6 * k - k


static func _line(img: Image, a: Vector2i, b: Vector2i, col := INK, t := 1) -> void:
	var n := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in n + 1:
		var p := Vector2(a).lerp(Vector2(b), float(i) / maxf(n, 1))
		img.fill_rect(Rect2i(int(p.x) - t / 2, int(p.y) - t / 2, t, t), col)


## A vertical colour bar at (x, y), h tall, for 0..vmax m/s (plus a blue
## notch for sinking air), with ticks every metre per second.
static func _colour_bar(img: Image, x: int, y: int, h: int, vmax: float) -> void:
	_text(img, x - 4, y - 44, "UP", 2)
	_text(img, x - 4, y - 26, "M/S", 2)
	for j in h:
		var v := vmax * (1.0 - float(j) / h)
		var c := _ramp(v)
		img.fill_rect(Rect2i(x, y + j, 22, 1), Color(c.r, c.g, c.b))
	var sink := _ramp(-0.8)
	img.fill_rect(Rect2i(x, y + h + 6, 22, 12), Color(0.93, 0.95, 0.97).lerp(Color(sink.r, sink.g, sink.b), sink.a))
	_text(img, x + 28, y + h + 8, "SINK", 1)
	_line(img, Vector2i(x, y), Vector2i(x + 21, y))
	_line(img, Vector2i(x, y + h), Vector2i(x + 21, y + h))
	for t in int(vmax) + 1:
		var ty := y + int(h * (1.0 - t / vmax))
		_line(img, Vector2i(x + 22, ty), Vector2i(x + 27, ty))
		_text(img, x + 31, ty - 7, str(t), 2)


# --- the map --------------------------------------------------------------------

func _map(w: SoaringWorld, path: String) -> void:
	var n := 700
	var half := 700.0
	var ml := 70
	var mt := 56
	var mr := 150
	var mb := 60
	var img := Image.create(n + ml + mr, n + mt + mb, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	for j in n:
		for i in n:
			var x := -half + (i + 0.5) * 2.0 * half / n
			var z := -half + (j + 0.5) * 2.0 * half / n
			var g := w.terrain.height_at(x, z)
			var nrm := w.terrain.normal_at(x, z)
			var shade := clampf(0.55 + 0.45 * nrm.dot(Vector3(-0.5, 0.7, -0.4).normalized()), 0.2, 1.0)
			var base := Color(0.72, 0.76, 0.66) * shade
			if g < WorldLayout.WATER_Y + 0.05:
				base = Color(0.55, 0.7, 0.85)
			if Vector2(x, z).length() > w.bounds_radius:
				base = base.darkened(0.45)
			var y := maxf(120.0, g + 25.0)
			var up := w.get_wind(Vector3(x, y, z)).y
			var col := _ramp(up)
			# Blend in by strength so a trace of lift is a trace of colour.
			img.set_pixel(ml + i, mt + j, base.lerp(Color(col.r, col.g, col.b), col.a if up <= 0.0 else clampf(up / 1.2, 0.0, 1.0) * 0.9))
	for t in w.get_thermals():
		var p: Vector3 = t["position"]
		var ci := ml + int((p.x + half) / (2.0 * half) * n)
		var cj := mt + int((p.z + half) / (2.0 * half) * n)
		for k in range(-5, 6):
			img.fill_rect(Rect2i(ci + k, cj, 1, 1), INK)
			img.fill_rect(Rect2i(ci, cj + k, 1, 1), INK)
	# Frame, ticks every 200 m, axis titles.
	_line(img, Vector2i(ml - 1, mt - 1), Vector2i(ml + n, mt - 1))
	_line(img, Vector2i(ml - 1, mt + n), Vector2i(ml + n, mt + n))
	_line(img, Vector2i(ml - 1, mt - 1), Vector2i(ml - 1, mt + n))
	_line(img, Vector2i(ml + n, mt - 1), Vector2i(ml + n, mt + n))
	for v in range(-600, 601, 200):
		var px := ml + int((v + half) / (2.0 * half) * n)
		var py := mt + int((v + half) / (2.0 * half) * n)
		_line(img, Vector2i(px, mt + n), Vector2i(px, mt + n + 6))
		_text(img, px - _text_w(str(v)) / 2, mt + n + 10, str(v))
		_line(img, Vector2i(ml - 7, py), Vector2i(ml - 1, py))
		_text(img, ml - 10 - _text_w(str(v)), py - 7, str(v))
	_text(img, ml + n / 2 - _text_w("X (M) - EAST >") / 2, mt + n + 32, "X (M) - EAST >")
	_text(img, 6, mt + n + 32, "Z (M)", 2)
	_text(img, ml + n / 2 - _text_w("VERTICAL WIND AT 120 M (25 M OVER HIGH GROUND) - T = 30 S") / 2, 10,
		"VERTICAL WIND AT 120 M (25 M OVER HIGH GROUND) - T = 30 S")
	_text(img, ml + n / 2 - _text_w("NORTH UP.  + : THERMAL CORE.  DARK: OUTSIDE THE ARENA (R 680 M).  BLUE: WATER", 1) / 2, 34,
		"NORTH UP.  + : THERMAL CORE.  DARK: OUTSIDE THE ARENA (R 680 M).  BLUE: WATER", 1)
	# Scale bar: 100 m.
	var sb := int(100.0 / (2.0 * half) * n)
	_line(img, Vector2i(ml + 16, mt + n - 20), Vector2i(ml + 16 + sb, mt + n - 20), INK, 3)
	_text(img, ml + 16, mt + n - 40, "100 M")
	_colour_bar(img, ml + n + 40, mt + 60, 420, 6.0)
	img.save_png(path)
	print("[world] wind map -> ", path)


# --- sections ------------------------------------------------------------------

func _section(w: SoaringWorld, path: String, start: Vector3, dir: Vector3, length: float, height: float, title: String) -> void:
	var nx := 600
	var ny := int(600.0 * height / length)
	var ml := 70
	var mt := 62
	var mr := 150
	var mb := 72
	var img := Image.create(nx + ml + mr, ny + mt + mb, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	for i in nx:
		var p := start + dir * (length * (i + 0.5) / nx)
		var g := w.terrain.height_at(p.x, p.z)
		for j in ny:
			var y := height * (1.0 - (j + 0.5) / ny)
			var col: Color
			if y < g:
				col = Color(0.42, 0.36, 0.3)
			else:
				var up := w.get_wind(Vector3(p.x, y, p.z)).y
				var r := _ramp(up)
				col = Color(0.93, 0.95, 0.97).lerp(Color(r.r, r.g, r.b), clampf(r.a if up <= 0.0 else up / 1.0, 0.0, 1.0))
				# 1 m/s contour lines.
				var frac := fposmod(up, 1.0)
				if up > 0.2 and (frac < 0.04 or frac > 0.96):
					col = col.darkened(0.35)
			img.set_pixel(ml + i, mt + j, col)
	# Solid geometry (rock faces etc.) from physics, so the lift is shown
	# against what makes it.
	var space := w.get_world_3d().direct_space_state
	for i in nx:
		var p := start + dir * (length * (i + 0.5) / nx)
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, height, p.z), Vector3(p.x, -20, p.z))
		var hit := space.intersect_ray(q)
		if hit:
			var top: float = (hit["position"] as Vector3).y
			for j in ny:
				var y := height * (1.0 - (j + 0.5) / ny)
				if y <= top and y >= w.terrain.height_at(p.x, p.z):
					img.set_pixel(ml + i, mt + j, Color(0.55, 0.5, 0.45))
	_line(img, Vector2i(ml - 1, mt - 1), Vector2i(ml + nx, mt - 1))
	_line(img, Vector2i(ml - 1, mt + ny), Vector2i(ml + nx, mt + ny))
	_line(img, Vector2i(ml - 1, mt - 1), Vector2i(ml - 1, mt + ny))
	_line(img, Vector2i(ml + nx, mt - 1), Vector2i(ml + nx, mt + ny))
	var step := 20 if length <= 200.0 else 30
	for v in range(0, int(length) + 1, step):
		var px := ml + int(v / length * nx)
		_line(img, Vector2i(px, mt + ny), Vector2i(px, mt + ny + 6))
		_text(img, px - _text_w(str(v)) / 2, mt + ny + 10, str(v))
	for v in range(0, int(height) + 1, 50 if height > 200.0 else 25):
		var py := mt + int((1.0 - v / height) * ny)
		_line(img, Vector2i(ml - 7, py), Vector2i(ml - 1, py))
		_text(img, ml - 10 - _text_w(str(v)), py - 7, str(v))
	_text(img, ml + nx / 2 - _text_w("DISTANCE EAST ALONG THE SLICE (M) FROM X = %d" % int(start.x)) / 2, mt + ny + 34,
		"DISTANCE EAST ALONG THE SLICE (M) FROM X = %d" % int(start.x))
	_text(img, 4, mt - 22, "ALT (M)")
	_text(img, ml, 8, title, 2)
	_text(img, ml + 120, 32, "VERTICAL WIND IN M/S AT T = 30 S", 1)
	_text(img, ml + nx / 2 - _text_w("DARK LINES EVERY 1 M/S.  BROWN: GROUND AND ROCK", 1) / 2, mt + ny + 54,
		"DARK LINES EVERY 1 M/S.  BROWN: GROUND AND ROCK", 1)
	_colour_bar(img, ml + nx + 40, mt + 40, ny - 80, 5.0)
	img.save_png(path)
	print("[world] section -> ", path)
