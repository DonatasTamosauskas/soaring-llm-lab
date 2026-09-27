class_name WorldFreeFly
extends Camera3D
## Desktop free-fly camera for exploring the valley (world dev scene).
##
##   WASD move, Q/E down/up, hold right mouse (or Tab to toggle capture) to
##   look, Shift x5 speed, Ctrl x0.2 (bird scale), mouse wheel scales speed.
##   N / B  next / previous landmark        L  toggle day / dusk
##   H      toggle this help / readout      P  print position
##
## The readout shows what flight and AI see at the camera: wind (thermals,
## ridge lift, breeze), ground height, is_inside, nearest perch, and the
## render stats that the Quest budgets are measured with.

@export var speed := 18.0
## Automated evidence: with user arg --devshot=<sec> the dev scene saves
## artifacts/world/dev_scene.png at that time and quits.
var _shot_at := -1.0
var _t := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _captured := false
var _label: Label
var _landmark_i := -1
var _world: World


func _ready() -> void:
	near = 0.03
	far = 3000.0  # Quest rule 7.5
	fov = 75.0
	current = true
	_yaw = rotation.y
	_pitch = rotation.x
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(12, 10)
	_label.add_theme_color_override(&"font_color", Color(1, 1, 1))
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override(&"outline_size", 5)
	_label.add_theme_font_size_override(&"font_size", 15)
	layer.add_child(_label)
	_shot_at = float(Paths.arg("devshot", "-1"))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_set_capture(mb.pressed)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed *= 1.25
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed /= 1.25
	elif event is InputEventMouseMotion and _captured:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.003
		_pitch = clampf(_pitch - mm.relative.y * 0.003, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_TAB:
				_set_capture(not _captured)
			KEY_N:
				_jump(1)
			KEY_B:
				_jump(-1)
			KEY_L:
				if _world is SoaringWorld:
					var sw := _world as SoaringWorld
					sw.set_lighting(&"dusk" if sw.lighting == &"day" else &"day")
			KEY_H:
				_label.visible = not _label.visible
			KEY_P:
				print("[world] camera at %s looking %s" % [global_position, -global_basis.z])


func _set_capture(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _jump(step: int) -> void:
	if _world == null:
		return
	var lms := _world.get_landmarks()
	if lms.is_empty():
		return
	_landmark_i = posmod(_landmark_i + step, lms.size())
	var lm: Dictionary = lms[_landmark_i]
	var p: Vector3 = lm["position"]
	var back := Vector3(0.6, 0.45, 0.66).normalized() * clampf(float(lm.get("radius", 5.0)) * 2.5, 4.0, 160.0)
	if lm.get("kind", "") == "opening":
		back = (lm["normal"] as Vector3) * 3.0 + Vector3(0, 0.3, 0)
	global_position = p + back
	look_at(p, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x
	print("[world] landmark %d/%d: %s (%s)" % [_landmark_i + 1, lms.size(), lm["name"], lm["kind"]])


func _process(delta: float) -> void:
	if _world == null or not is_instance_valid(_world):
		_world = World.find(get_tree())
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= global_basis.z
	if Input.is_key_pressed(KEY_S):
		dir += global_basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= global_basis.x
	if Input.is_key_pressed(KEY_D):
		dir += global_basis.x
	if Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		dir -= Vector3.UP
	var s := speed
	if Input.is_key_pressed(KEY_SHIFT):
		s *= 5.0
	if Input.is_key_pressed(KEY_CTRL):
		s *= 0.2
	global_position += dir.normalized() * s * delta
	if _label.visible:
		_label.text = _readout()
	_t += delta
	if _shot_at > 0.0 and _t >= _shot_at:
		_shot_at = -1.0
		await Capture.save_viewport(get_viewport(), Paths.artifacts("world").path_join("dev_scene.png"))
		get_tree().quit()


func _readout() -> String:
	var p := global_position
	var lines := PackedStringArray()
	lines.append("Soaring world dev  (H hides)   WASD/QE move, RMB or Tab look, Shift fast, Ctrl slow, wheel speed %.1f m/s" % speed)
	lines.append("N/B landmarks, L day/dusk, P print")
	lines.append("pos (%.1f, %.1f, %.1f)" % [p.x, p.y, p.z])
	if _world:
		var w := _world.get_wind(p)
		var g := _world.ground_height(p.x, p.z)
		lines.append("ground %.1f m  (AGL %.1f)   inside %s" % [g, p.y - g, _world.is_inside(p)])
		lines.append("wind (%.2f, %.2f, %.2f) m/s   updraft %.2f m/s" % [w.x, w.y, w.z, w.y])
		var near_p := _world.find_perches(p, 25.0, 0.2)
		var best: Perch = null
		for q in near_p:
			if best == null or q.position.distance_to(p) < best.position.distance_to(p):
				best = q
		if best:
			lines.append("nearest perch %.1f m: %s max span %.2f m (%s)" % [best.position.distance_to(p), Perch.Kind.keys()[best.kind], best.max_span, best.district])
	var vp := get_viewport()
	lines.append("fps %d   draws %d (+%d shadow)   prims %d (+%d shadow)" % [Engine.get_frames_per_second(),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)])
	if _world is SoaringWorld:
		lines.append("generated in %.0f ms" % (_world as SoaringWorld).generation_ms)
	return "\n".join(lines)
