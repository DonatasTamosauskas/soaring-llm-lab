class_name FacetBackground
extends Control
## The panel backdrop: a chamfered plate filled with a subtle triangulated
## mosaic in two close shades of dusk blue, the UI's nod to the low-poly
## world. Shades stay between UITheme.PANEL and UITheme.FACET_LIGHT so text
## contrast is guaranteed against the lightest facet (tested).

@export var chamfer := 34.0
@export var cell := 150.0
@export var border_width := 4.0
@export var border_color := Color(UITheme.ACCENT, 0.9)
@export var alpha := UITheme.PANEL_ALPHA
@export var seed_value := 7

var _tris: Array[PackedVector2Array] = []
var _cols: PackedColorArray = []
var _outline := PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	_tris.clear()
	_cols.clear()
	var w := size.x
	var h := size.y
	if w < 2.0 or h < 2.0:
		return
	var c := minf(chamfer, minf(w, h) * 0.3)
	_outline = PackedVector2Array([
		Vector2(c, 0), Vector2(w - c, 0), Vector2(w, c), Vector2(w, h - c),
		Vector2(w - c, h), Vector2(c, h), Vector2(0, h - c), Vector2(0, c)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var nx := maxi(2, int(ceil(w / cell)) + 1)
	var ny := maxi(2, int(ceil(h / cell)) + 1)
	var pts := []
	for j in ny:
		var row := []
		for i in nx:
			var p := Vector2(w * i / float(nx - 1), h * j / float(ny - 1))
			# Jitter interior points only, so the mosaic covers the rect exactly.
			if i > 0 and i < nx - 1:
				p.x += rng.randf_range(-0.3, 0.3) * cell
			if j > 0 and j < ny - 1:
				p.y += rng.randf_range(-0.3, 0.3) * cell
			row.append(p)
		pts.append(row)
	for j in ny - 1:
		for i in nx - 1:
			var a: Vector2 = pts[j][i]
			var b: Vector2 = pts[j][i + 1]
			var cc: Vector2 = pts[j + 1][i + 1]
			var d: Vector2 = pts[j + 1][i]
			var flip := rng.randf() < 0.5
			var quads := [[a, b, cc], [a, cc, d]] if flip else [[a, b, d], [b, cc, d]]
			for t: Array in quads:
				var tri := PackedVector2Array(t)
				for piece: PackedVector2Array in Geometry2D.intersect_polygons(tri, _outline):
					# Clipping at the chamfers can leave zero-area slivers.
					if Geometry2D.triangulate_polygon(piece).is_empty():
						continue
					_tris.append(piece)
					# Shade by a gentle top-left light plus noise: facets, not stripes.
					var ctr: Vector2 = (tri[0] + tri[1] + tri[2]) / 3.0
					var k := clampf(0.55 - 0.35 * (ctr.y / h) + rng.randf_range(-0.22, 0.22), 0.0, 1.0)
					_cols.append(Color(UITheme.PANEL.lerp(UITheme.FACET_LIGHT, k), alpha))
	queue_redraw()


func _draw() -> void:
	for i in _tris.size():
		GestureArt.poly(self, _tris[i], _cols[i])
	if border_width > 0.0 and _outline.size() > 2:
		var loop := _outline.duplicate()
		loop.append(_outline[0])
		draw_polyline(loop, border_color, border_width, true)


## The lightest colour any facet can have (for contrast checks).
static func lightest() -> Color:
	return UITheme.FACET_LIGHT
