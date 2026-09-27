class_name UIPointerSource
extends RefCounted
## Where a laser pointer comes from: an aim pose, a trigger, a couple of
## buttons. The XR implementation reads an XRController3D bound to the "aim"
## pose; tests and the dev scene use the base class with fields set by hand,
## so every pointer behaviour can be driven without a headset.

## "left_hand" or "right_hand".
var hand: StringName = &"right_hand"
## Scripted state (used as-is by the base class).
var aim := Transform3D.IDENTITY
var trigger_value := 0.0
var tracked := true
var menu_down := false
var back_down := false
## Haptic pulses requested (amplitude, seconds), newest last: tests assert
## feedback. Scripted sources only, and capped, so it never grows unbounded.
var haptic_log: Array[Vector2] = []
const HAPTIC_LOG_MAX := 64
## >= 0 replaces the real trigger (dev scene: scripted clicks on real aim poses).
var trigger_override := -1.0


func _init(p_hand: StringName = &"right_hand") -> void:
	hand = p_hand


## Aim pose in world space; -Z is the pointing direction.
func aim_transform() -> Transform3D:
	return aim


func trigger() -> float:
	return trigger_override if trigger_override >= 0.0 else trigger_value


func is_tracked() -> bool:
	return tracked


func menu_pressed() -> bool:
	return menu_down


func back_pressed() -> bool:
	return back_down


func haptic(amplitude: float, seconds: float) -> void:
	haptic_log.append(Vector2(amplitude, seconds))
	if haptic_log.size() > HAPTIC_LOG_MAX:
		haptic_log.pop_front()


## No longer used by the pointer (replaced, or the UI is going away).
func release() -> void:
	pass


## Convenience for tests: aim from `from` at world point `at`.
func aim_at(from: Vector3, at: Vector3) -> void:
	var dir := (at - from).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.BACK
	aim = Transform3D(Basis.looking_at(dir, up), from)
