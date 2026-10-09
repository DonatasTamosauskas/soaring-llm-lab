extends Node
## Scripted desktop input for gameplay captures (tools/capture_gameplay_godot.sh).
##
## The capture tool copies this file to res://capture_input/driver.gd in a scratch copy of a build
## and registers the run's timeline (eval/capture-input/<run>.gd, which extends this script) as an
## autoload. It only injects input, through Input.parse_input_event and Input.action_press, the same
## path real keyboard and mouse events take. It never calls into the game's own scripts.
##
## Time is game time from the first frame. The capture runs with --fixed-fps 30, so every frame
## advances it by exactly 1/30 s and second N of the timeline is second N of the video.
##
## A timeline is a list of steps, [seconds, command, arguments...]:
##   [t, "tap", KEY_X]                    press X for 0.12 s
##   [t, "tap", KEY_X, hold]              press X for `hold` seconds
##   [t, "hold", KEY_X, seconds]          the same, for longer holds (banking, tucking)
##   [t, "press", KEY_X] / [t, "release", KEY_X]
##   [t, "repeat", KEY_X, count, every]   tap X `count` times, one every `every` seconds (flapping)
##   [t, "action", "name", seconds]       Input.action_press("name") for `seconds`
##   [t, "click", x, y]                   left click at window position (x, y), 1280x720 window
##   [t, "mouse", dx, dy, seconds]        move the mouse by (dx, dy) pixels, spread over `seconds`
##   [t, "note", "text"]                  only prints a line in the capture log
## Keys are sent with both keycode and physical_keycode set, so code that reads either sees them.

const DEFAULT_TAP := 0.12
const KEY_COMMANDS := ["tap", "hold", "press", "release", "repeat"]

## Keep the system cursor visible and free. A game that captures the mouse while flying would
## otherwise grab the cursor of whoever is at the Mac, and their real mouse movements would steer
## the recording. Only the cursor mode is reset; set false in a timeline that steers with the mouse.
var keep_cursor_free := true

var _time := 0.0
var _steps: Array = []
var _next := 0
var _releases: Array = []   # [time, kind, value]: keys and actions to let go of
var _mouse: Array = []      # [end_time, dx_per_second, dy_per_second]
var _report_due := 0.0


## Override in the run's timeline file.
func timeline() -> Array:
	return []


## Override to print extra state once per second (position, score). Must not change anything.
func report() -> String:
	return ""


## Override to fix the seed of Godot's global random generator (randf, randi) before the main scene
## loads, for a build whose flight depends on unseeded randomness (-1: leave it alone).
func random_seed() -> int:
	return -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if random_seed() >= 0:
		seed(random_seed())
		print("[capture-input] global random seed %d" % random_seed())
	_steps = timeline()
	_steps.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	print("[capture-input] %d steps" % _steps.size())


func _process(delta: float) -> void:
	_time += delta
	for i in range(_releases.size() - 1, -1, -1):
		if _releases[i][0] <= _time:
			var item: Array = _releases[i]
			_releases.remove_at(i)
			if item[1] == "key":
				_key(int(item[2]), false)
			else:
				Input.action_release(String(item[2]))
	while _next < _steps.size() and float(_steps[_next][0]) <= _time:
		_run(_steps[_next])
		_next += 1
	_move_mouse(delta)
	if keep_cursor_free and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _time >= _report_due:
		if _report_due == 0.0:
			print("[capture-input] window %s, viewport %s, content scale %s, user data %s" % [
				DisplayServer.window_get_size(), get_viewport().get_visible_rect().size,
				get_tree().root.content_scale_factor, OS.get_user_data_dir()])
		_report_due += 1.0
		var camera := get_viewport().get_camera_3d()
		var where := ""
		if camera:
			var p := camera.global_position
			where = "camera (%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
		print("[capture-input] t=%.1f %s %s" % [_time, where, report()])


func _run(step: Array) -> void:
	var t := float(step[0])
	var command := String(step[1])
	print("[capture-input] t=%.2f %s %s" % [_time, command, _describe(command, step.slice(2))])
	match command:
		"tap":
			_key(int(step[2]), true)
			_release_key_at(int(step[2]), _time + (float(step[3]) if step.size() > 3 else DEFAULT_TAP))
		"hold":
			_key(int(step[2]), true)
			_release_key_at(int(step[2]), _time + float(step[3]))
		"press":
			_key(int(step[2]), true)
		"release":
			_key(int(step[2]), false)
		"repeat":
			# Expand into single taps so they print and play like any other step.
			var count := int(step[3])
			var every := float(step[4])
			var hold := minf(DEFAULT_TAP, every * 0.5)
			for n in range(1, count):
				_insert([t + n * every, "tap", step[2], hold])
			_key(int(step[2]), true)
			_release_key_at(int(step[2]), _time + hold)
		"action":
			Input.action_press(String(step[2]))
			_releases.append([_time + float(step[3]), "action", String(step[2])])
		"click":
			_click(Vector2(float(step[2]), float(step[3])))
		"mouse":
			var seconds := maxf(float(step[4]), 1.0 / 30.0)
			_mouse.append([_time + seconds, float(step[2]) / seconds, float(step[3]) / seconds])
		"note":
			pass
		_:
			push_warning("[capture-input] unknown step %s" % [step])


func _insert(step: Array) -> void:
	var at := _next + 1
	while at < _steps.size() and float(_steps[at][0]) <= float(step[0]):
		at += 1
	_steps.insert(at, step)


func _release_key_at(keycode: int, when: float) -> void:
	_releases.append([when, "key", keycode])


func _key(keycode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode as Key
	event.physical_keycode = keycode as Key
	event.pressed = pressed
	Input.parse_input_event(event)


func _click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.position = position
		button.global_position = position
		button.pressed = pressed
		button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(button)


func _move_mouse(delta: float) -> void:
	var total := Vector2.ZERO
	for i in range(_mouse.size() - 1, -1, -1):
		total += Vector2(_mouse[i][1], _mouse[i][2]) * delta
		if _mouse[i][0] <= _time:
			_mouse.remove_at(i)
	if total != Vector2.ZERO:
		var motion := InputEventMouseMotion.new()
		motion.relative = total
		motion.screen_relative = total
		motion.position = get_viewport().get_visible_rect().size * 0.5
		Input.parse_input_event(motion)


func _describe(command: String, args: Array) -> String:
	var parts := PackedStringArray()
	for i in args.size():
		if i == 0 and command in KEY_COMMANDS:
			parts.append(OS.get_keycode_string(int(args[i])))
		else:
			parts.append(str(args[i]))
	return " ".join(parts)
