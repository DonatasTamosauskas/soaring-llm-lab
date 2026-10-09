class_name FacetBar
extends Control
## A slanted, faceted progress bar (growth, lesson progress).

var fill_color := UITheme.ACCENT
var value := 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if v != value:
			value = v
			queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var h := size.y
	var sl := h * 0.5
	var bg := PackedVector2Array([Vector2(sl, 0), Vector2(size.x, 0), Vector2(size.x - sl, h), Vector2(0, h)])
	GestureArt.poly(self, bg, Color(UITheme.BUTTON, 0.95))
	if value > 0.0:
		var w := lerpf(sl * 2.0, size.x, value)
		GestureArt.poly(self, PackedVector2Array([Vector2(sl, 0), Vector2(w, 0), Vector2(w - sl, h), Vector2(0, h)]), fill_color)
		# Upper facet highlight.
		GestureArt.poly(self, PackedVector2Array([Vector2(sl, 0), Vector2(w, 0), Vector2(w - sl * 0.5, h * 0.45), Vector2(sl * 0.5, h * 0.45)]), fill_color.lightened(0.2))
