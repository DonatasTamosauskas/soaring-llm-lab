class_name SegmentBar
extends Control
## A chunky stepped slider for VR: a row of slanted segments you point at and
## click (or drag across) to set a 0..1 value, with - / + end caps. Discrete
## steps are far easier to hit with a laser at 1.5 m than a thin slider, and
## the value snaps so a shaky hand can't nudge it.

signal value_changed(value: float)

@export var steps := 10
@export var allow_zero := true

var value := 0.5:
	set(v):
		v = clampf(snappedf(v, 1.0 / steps), 0.0 if allow_zero else 1.0 / steps, 1.0)
		if is_equal_approx(v, value):
			return
		value = v
		queue_redraw()

var _hover := -2
var _dragging := false
const CAP := 72.0
const GAP := 8.0
const SLANT := 12.0


func _init() -> void:
	custom_minimum_size = Vector2(560, 64)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func set_value_no_signal(v: float) -> void:
	value = v


## -1 = minus cap, steps = plus cap, 0..steps-1 = segment, -2 = none.
func _slot_at(pos: Vector2) -> int:
	if pos.y < -8.0 or pos.y > size.y + 8.0:
		return -2
	if pos.x < CAP:
		return -1
	if pos.x > size.x - CAP:
		return steps
	var inner := size.x - 2.0 * CAP - 2.0 * GAP
	var i := int(floor((pos.x - CAP - GAP) / inner * steps))
	return clampi(i, 0, steps - 1)


func _apply_slot(slot: int) -> void:
	var old := value
	if slot == -1:
		value = value - 1.0 / steps
	elif slot == steps:
		value = value + 1.0 / steps
	elif slot >= 0:
		value = (slot + 1) / float(steps)
	if not is_equal_approx(old, value):
		value_changed.emit(value)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var slot := _slot_at(event.position)
			_apply_slot(slot)
			_dragging = slot >= 0 and slot < steps
			accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion:
		var slot := _slot_at(event.position)
		if slot != _hover:
			_hover = slot
			queue_redraw()
		if _dragging and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) and slot >= 0 and slot < steps:
			_apply_slot(slot)
	elif event.is_action_pressed("ui_left"):
		_apply_slot(-1)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		_apply_slot(steps)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = -2
		_dragging = false
		queue_redraw()
	elif what == NOTIFICATION_FOCUS_ENTER or what == NOTIFICATION_FOCUS_EXIT:
		queue_redraw()


func _draw() -> void:
	var h := size.y
	# End caps: chamfered squares with - and +.
	_draw_cap(Rect2(0, 0, CAP, h), false, _hover == -1)
	_draw_cap(Rect2(size.x - CAP, 0, CAP, h), true, _hover == steps)
	var inner := size.x - 2.0 * CAP - 2.0 * GAP
	var seg_w := inner / steps
	var filled := int(round(value * steps))
	for i in steps:
		var x0 := CAP + GAP + i * seg_w + 3.0
		var x1 := x0 + seg_w - 6.0
		var poly := PackedVector2Array([
			Vector2(x0 + SLANT, 4), Vector2(x1 + SLANT, 4),
			Vector2(x1 - SLANT, h - 4), Vector2(x0 - SLANT, h - 4)])
		var col := UITheme.ACCENT if i < filled else UITheme.BUTTON
		if i == _hover:
			col = col.lightened(0.25) if i < filled else UITheme.BUTTON_HOVER
		GestureArt.poly(self, poly, col)
	if has_focus():
		draw_rect(Rect2(Vector2(-6, -6), size + Vector2(12, 12)), Color(UITheme.ACCENT, 0.6), false, 3.0)


func _draw_cap(r: Rect2, plus: bool, hot: bool) -> void:
	var c := 12.0
	var p := r.position
	var s := r.size
	var poly := PackedVector2Array([
		p + Vector2(c, 0), p + Vector2(s.x - c, 0), p + Vector2(s.x, c), p + Vector2(s.x, s.y - c),
		p + Vector2(s.x - c, s.y), p + Vector2(c, s.y), p + Vector2(0, s.y - c), p + Vector2(0, c)])
	GestureArt.poly(self, poly, UITheme.BUTTON_HOVER if hot else UITheme.BUTTON)
	if hot:
		var loop := poly.duplicate()
		loop.append(poly[0])
		draw_polyline(loop, UITheme.ACCENT, 5.0)
	var ctr := r.get_center()
	var arm := s.x * 0.24
	draw_line(ctr - Vector2(arm, 0), ctr + Vector2(arm, 0), UITheme.TEXT, 8.0)
	if plus:
		draw_line(ctr - Vector2(0, arm), ctr + Vector2(0, arm), UITheme.TEXT, 8.0)


## Pixel centre of a segment in local coordinates (tests aim at it).
func segment_center(i: int) -> Vector2:
	var inner := size.x - 2.0 * CAP - 2.0 * GAP
	var seg_w := inner / steps
	return Vector2(CAP + GAP + (i + 0.5) * seg_w, size.y * 0.5)


func cap_center(plus: bool) -> Vector2:
	return Vector2(size.x - CAP * 0.5 if plus else CAP * 0.5, size.y * 0.5)
