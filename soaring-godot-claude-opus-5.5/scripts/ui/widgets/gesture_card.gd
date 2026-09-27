class_name GestureCard
extends Control
## An illustrated gesture (GestureArt) on a sky-coloured chamfered card.
## Animates at `fps` while visible; each animation frame is a redraw, which
## the owning UIPanel sees and renders (and only then).

@export var art: StringName = &"flap"
@export var fps := 30.0
@export var animate := true
@export var backdrop := true

var _t := 0.0
var _acc := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_art(id: StringName) -> void:
	if id == art:
		return
	art = id
	_t = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	if not animate or not is_visible_in_tree():
		return
	_t += delta
	_acc += delta
	if _acc >= 1.0 / fps:
		_acc = 0.0
		queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if backdrop:
		var c := minf(28.0, minf(size.x, size.y) * 0.1)
		var poly := PackedVector2Array([
			Vector2(c, 0), Vector2(size.x - c, 0), Vector2(size.x, c), Vector2(size.x, size.y - c),
			Vector2(size.x - c, size.y), Vector2(c, size.y), Vector2(0, size.y - c), Vector2(0, c)])
		GestureArt.poly(self, poly, Color("2f4a6b"))
		# A lighter sky facet across the top half.
		GestureArt.poly(self, PackedVector2Array([poly[0], poly[1], poly[2], Vector2(size.x, size.y * 0.45), Vector2(0, size.y * 0.62), poly[7]]), Color("365579"))
	GestureArt.draw(self, art, r.grow(-minf(size.x, size.y) * 0.04), _t)
