class_name HoldButton
extends Button
## A button for actions that throw a run away (Restart run, Quit to menu):
## it acts only once it has been held down for HOLD_S. Restart sits right
## under Resume, and a run to the eagle takes 20-30 minutes, so one
## mis-aimed laser pull must not cost it. Holding is safer than "pull again
## to confirm": a player whose click seemed not to register pulls again at
## the same spot, which would confirm it.
##
## While held, a bar fills along the bottom edge. Letting go early shows
## `hint` (e.g. "Hold to restart") on the button for a moment, so the first
## short pull teaches the gesture. Works the same with the VR pointer, a
## mouse, or a held Enter key (any press BaseButton recognises).

## Emitted once per hold, when the bar is full.
signal held()

## Seconds the button must be held.
const HOLD_S := 0.8
## Seconds the "hold" hint stays up after an early release.
const HINT_S := 2.5
const BAR_H := 12.0

var hint := "Hold to confirm"
## Seconds to hold (HOLD_S; logic tests shorten it, one test pins HOLD_S).
var hold_seconds := HOLD_S
## 0..1 while held.
var progress := 0.0
var _label := ""
var _hint_left := 0.0
## Pressed at least one frame since the last release.
var _was_held := false
## The hold already fired: wait for the release before counting again.
var _fired := false


func _ready() -> void:
	_label = text


func hint_showing() -> bool:
	return _hint_left > 0.0


func _process(delta: float) -> void:
	var holding := is_visible_in_tree() and not disabled and get_draw_mode() == DRAW_PRESSED
	if holding and not _fired:
		_was_held = true
		progress = minf(1.0, progress + delta / hold_seconds)
		queue_redraw()
		if progress >= 1.0:
			_fired = true
			progress = 0.0
			queue_redraw()
			held.emit()
	elif not holding:
		if _was_held and not _fired:
			# Let go early: say how this button works.
			_hint_left = HINT_S
			text = hint
		if progress > 0.0:
			progress = 0.0
			queue_redraw()
		_was_held = false
		_fired = false
	if _hint_left > 0.0 and not holding:
		_hint_left -= delta
		if _hint_left <= 0.0:
			text = _label


func _draw() -> void:
	if progress <= 0.0:
		return
	# A flat ink bar along the bottom edge, inside the chamfer: the button
	# shows its pressed (accent) fill while held, so ink is what contrasts.
	var inset := float(UITheme.CHAMFER)
	var w := (size.x - 2.0 * inset) * progress
	draw_rect(Rect2(inset, size.y - BAR_H - 8.0, w, BAR_H), UITheme.INK)
