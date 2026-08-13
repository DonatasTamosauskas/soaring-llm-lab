class_name GameMenu
extends Node3D

## The way in and the way out: main menu, pause, comfort settings, the controls
## card, and the end-of-run summary — all of it world-space, pointed at with a
## controller, reachable without taking the headset off.
##
## Everything this node does with the game is deliberately narrow: it pauses the
## tree, it pushes settings into [Tuning], it asks [GameManager] to restart, and
## it quits. What each row [i]means[/i] lives in [MenuModel] and where each row
## [i]is[/i] lives in [MenuLayout], both of which are plain objects the test
## suite can drive without a scene.

signal opened(screen: int)
signal closed()

## Buttons that open and close the menu. Two of them because the Quest's menu
## button is claimed by the system on some runtimes, and a player who cannot
## find the way out of a game is a player who takes the headset off.
const OPEN_BUTTONS: PackedStringArray = ["menu_button", "by_button"]
const SELECT_BUTTONS: PackedStringArray = ["trigger_click", "ax_button", "select_button"]

## How far off-axis the summary panel is allowed to drift before it eases back
## in front of the player, and how fast it eases. Slow and dead-banded on
## purpose: a panel that chases the head is head-locked UI wearing a disguise.
const FOLLOW_DEADBAND: float = 0.52  # ~30 degrees
const FOLLOW_RATE: float = 1.6

var player: BirdPlayer
var manager: GameManager
var hud: HUD
var settings := PlayerSettings.new()
## Where the settings live. Overridable so a probe can keep its experiments out
## of the player's own file.
var settings_path: String = PlayerSettings.FILE_PATH
var model: MenuModel

var is_open: bool = false

var _panel: MenuPanel
var _pointers: Array[UIPointer] = []
var _aims: Array[Node3D] = []
var _hover_row: int = -1
var _follow_direction: Vector3 = Vector3.FORWARD
var _built: bool = false
## Desktop only: the mouse ray, refreshed from the last motion event so that
## hovering works without polling a captured mouse.
var _mouse_position: Vector2 = Vector2.ZERO


func attach(player_ref: BirdPlayer, manager_ref: GameManager, hud_ref: HUD) -> void:
	player = player_ref
	manager = manager_ref
	hud = hud_ref
	model = MenuModel.new(settings)

	settings.load_from(settings_path)
	apply_settings()

	# The menu has to keep running while the game it paused does not.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# ...and so do the XR trackers. Pausing the tree stops XRCamera3D and
	# XRController3D updating their poses, which freezes the view inside the
	# headset while the player's actual head keeps moving — the single most
	# reliable way to make somebody ill that this codebase contains. These nodes
	# only ever copy a tracker into a transform, so running them while paused
	# costs nothing and is always correct.
	for node: Node3D in [
		player.xr_origin, player.xr_camera, player.left_hand, player.right_hand
	]:
		node.process_mode = Node.PROCESS_MODE_ALWAYS

	if hud != null:
		hud.use_settings(settings)
		hud.tutorial_finished.connect(_on_tutorial_finished)
	if manager != null:
		manager.event_occurred.connect(_on_event)
	_bind_controller_buttons()


# --- opening and closing -----------------------------------------------------

func open(screen: MenuModel.Screen) -> void:
	_build()
	model.reset_to(screen)
	is_open = true
	visible = true
	_refresh()
	_place_now()
	_set_paused(model.is_pausing())
	# Start the mouse in the middle of the panel rather than wherever it was
	# last left, so a desktop menu is usable before the mouse has moved.
	if not player.xr_active and is_inside_tree():
		_mouse_position = get_viewport().get_visible_rect().size * 0.5
	if hud != null:
		# The readout is the one thing that must not compete with a menu: two
		# sets of numbers in the same view is how a HUD stops being read.
		hud.visible = not model.is_pausing()
	if not player.xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	opened.emit(int(screen))


func close() -> void:
	if not is_open:
		return
	# A finished run has nothing to go back to. Closing the pause screen over one
	# would leave the player in a sky that cannot be played, with the summary
	# they earned thrown away — so it lands back on the summary instead.
	if manager != null and manager.session.is_over() \
			and model.screen != MenuModel.Screen.SUMMARY:
		open(MenuModel.Screen.SUMMARY)
		return
	is_open = false
	visible = false
	_set_paused(false)
	_hover(-1)
	if hud != null:
		hud.visible = true
	if not player.xr_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	settings.save(settings_path)
	closed.emit()


## The menu button: opens the pause screen, or backs out of wherever you are.
func toggle() -> void:
	if is_open:
		if model.depth() > 0:
			model.back()
			_refresh()
			_set_paused(model.is_pausing())
			return
		if model.screen == MenuModel.Screen.SUMMARY:
			# The summary has no "keep flying" — the run is over. The menu button
			# takes you to the pause screen, which does.
			open(MenuModel.Screen.PAUSE)
			return
		close()
		return
	open(MenuModel.Screen.PAUSE)


func _set_paused(paused: bool) -> void:
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.paused = paused


# --- the run -----------------------------------------------------------------

func _on_event(kind: StringName, payload: Dictionary) -> void:
	match kind:
		&"ended":
			var summary: Dictionary = payload.duplicate()
			summary["title"] = manager.session.outcome_title()
			model.summary = summary
			model.restart_armed = false
			settings.set_value(
				"best_score",
				maxf(settings.get_value("best_score"), float(payload.get("score", 0)))
			)
			settings.save(settings_path)
			open(MenuModel.Screen.SUMMARY)
		&"restart_ready":
			model.restart_armed = true
			if is_open and model.screen == MenuModel.Screen.SUMMARY:
				_refresh()
		&"restart":
			if is_open:
				close()


func _act(action: StringName) -> void:
	match action:
		MenuModel.ACT_START, MenuModel.ACT_RESUME:
			close()
		MenuModel.ACT_RESTART:
			# A deliberate press restarts immediately, even inside the delay that
			# stops a stray wingbeat skipping the summary — pressing a button
			# labelled FLY AGAIN is not a stray anything.
			if manager != null:
				manager.restart()
			close()
		MenuModel.ACT_QUIT:
			settings.save(settings_path)
			get_tree().quit()
		MenuModel.ACT_RECENTRE:
			_recentre()
		MenuModel.ACT_DEFAULTS:
			apply_settings()
			_refresh()
		MenuModel.ACT_TEACH:
			if hud != null:
				hud.teach_again()
			settings.set_value("learned", 0.0)
			settings.save(settings_path)
			close()
		_:
			pass


## Re-learns where the player's hands rest and, in a headset, where forward is.
## [method WingInput.recentre] has existed unbound since the input work; this is
## the button it always wanted.
func _recentre() -> void:
	# One implementation, in [method BirdPlayer.recentre], shared with the
	# hold-both-triggers gesture. This used to call XRServer.center_on_hmd as
	# well, which recentres on the player's [i]head[/i] — doing both turned the
	# world twice, and recentring on where somebody happens to be looking is not
	# what "face forward" means to a bird whose wings are its arms.
	player.recentre()
	_place_now()


func apply_settings() -> void:
	var values: Dictionary = settings.tuning_values()
	for key: String in values:
		if key in Tuning:
			Tuning.set(key, float(values[key]))
	if player != null:
		player.apply_tuning()
	_update_pointer_hand()


# --- building ----------------------------------------------------------------

## Nothing is built until the menu is first opened. A headless probe, a capture
## run or a device diagnostic never opens it and therefore never pays for it.
func _build() -> void:
	if _built:
		return
	_built = true
	_panel = MenuPanel.new()
	_panel.name = "Panel"
	add_child(_panel)
	if player.xr_active:
		_build_xr_pointers()
	else:
		_build_desktop_pointer()
	_update_pointer_hand()


func _build_xr_pointers() -> void:
	for hand: StringName in [&"left_hand", &"right_hand"]:
		# The aim pose, not the grip pose the wings hang off: grip points where
		# the fist points, aim points where a person thinks they are pointing.
		var aim := XRController3D.new()
		aim.name = "Aim_%s" % hand
		aim.tracker = hand
		aim.pose = &"aim"
		aim.process_mode = Node.PROCESS_MODE_ALWAYS
		player.xr_origin.add_child(aim)
		var pointer := UIPointer.new()
		pointer.name = "Pointer"
		aim.add_child(pointer)
		_aims.append(aim)
		_pointers.append(pointer)


func _build_desktop_pointer() -> void:
	var pointer := UIPointer.new()
	pointer.name = "MousePointer"
	add_child(pointer)
	_pointers.append(pointer)


func _update_pointer_hand() -> void:
	if _pointers.size() < 2:
		return
	var right: bool = settings.pointer_is_right_handed()
	_pointers[0].set_shown(not right)
	_pointers[1].set_shown(right)


func _refresh() -> void:
	if _panel == null:
		return
	_panel.rebuild(model)


# --- placement ---------------------------------------------------------------

func _head() -> Transform3D:
	var camera: Node3D = player.xr_camera if player.xr_active else player.desktop_camera
	return camera.global_transform


## How far the head can move before a world-locked panel is re-placed in front of
## it. Sized to catch one specific thing: on the first frames of an XR session
## the camera has no pose yet and reads as the origin, so a menu opened at launch
## was placed at the player's feet and only became visible if they looked down.
## A player leaning or turning never moves this far; a tracking pose arriving
## always does.
const REPLACE_DISTANCE: float = 0.9

var _placed_at: Vector3 = Vector3.ZERO


func _place_now() -> void:
	if _panel == null:
		return
	var head: Transform3D = _head()
	_panel.global_transform = MenuLayout.place(head)
	_placed_at = head.origin
	var direction: Vector3 = _panel.global_position - head.origin
	direction.y = 0.0
	_follow_direction = direction.normalized() if direction.length_squared() > 1e-6 \
		else Vector3.FORWARD


## While the world is stopped the panel is simply an object in it and never
## moves. The summary is the exception: the bird is still gliding, so the panel
## travels with the player, keeps its own heading, and only turns to face them
## once they have looked well away from it and stayed there.
func _follow(delta: float) -> void:
	var head: Transform3D = _head()
	if not head.is_finite():
		return
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	if forward.length_squared() > 1e-6:
		forward = forward.normalized()
		if _follow_direction.angle_to(forward) > FOLLOW_DEADBAND:
			var weight: float = clampf(delta * FOLLOW_RATE, 0.0, 1.0)
			_follow_direction = _follow_direction.slerp(forward, weight).normalized()
	var origin: Vector3 = head.origin + _follow_direction * MenuLayout.DISTANCE
	_panel.global_transform = Transform3D(
		Basis.looking_at(_follow_direction, Vector3.UP), origin
	)


func _process(delta: float) -> void:
	if not is_open or _panel == null:
		return
	if model.screen == MenuModel.Screen.SUMMARY:
		_follow(delta)
	elif _head().origin.distance_to(_placed_at) > REPLACE_DISTANCE:
		_place_now()
	_update_pointing()


# --- pointing ----------------------------------------------------------------

## Test seam: a Callable returning [origin, direction] in world space, standing
## in for a controller. [MenuProbe] drives the real menu through it, which is
## the only automated cover for the whole pointing path — the same reason
## [BirdPlayer.pose_source] exists.
var ray_source: Callable = Callable()


func _pointing_ray() -> Array:
	if ray_source.is_valid():
		return ray_source.call() as Array
	if player.xr_active:
		var index: int = 1 if settings.pointer_is_right_handed() else 0
		if index >= _aims.size():
			return []
		var aim: Transform3D = (_aims[index] as Node3D).global_transform
		if not aim.is_finite():
			return []
		return [aim.origin, -aim.basis.z]
	var camera: Camera3D = player.desktop_camera
	if camera == null or not camera.is_inside_tree():
		return []
	return [
		camera.project_ray_origin(_mouse_position),
		camera.project_ray_normal(_mouse_position),
	]


func _update_pointing() -> void:
	var ray: Array = _pointing_ray()
	if ray.is_empty():
		_hover(-1)
		return
	var hit: Dictionary = _panel.probe(ray[0] as Vector3, ray[1] as Vector3)
	_hover(int(hit["row"]))

	var index: int = 0
	if player.xr_active:
		index = 1 if settings.pointer_is_right_handed() else 0
	if index >= _pointers.size():
		return
	var landed: bool = bool(hit["hit"])
	if not player.xr_active:
		# The mouse ray starts at the near plane; a beam drawn from there is a
		# stripe across the middle of the screen. Show only the dot.
		_pointers[index].global_position = (ray[0] as Vector3) \
			+ (ray[1] as Vector3) * float(hit["distance"])
		_pointers[index].aim(0.05, landed, false)
		_pointers[index].visible = landed
	else:
		_pointers[index].aim(
			float(hit["distance"]) if landed else UIPointer.MAX_LENGTH, landed
		)


func _hover(row: int) -> void:
	if row == _hover_row:
		return
	_hover_row = row
	model.hover(row)
	_panel.set_hovered(row)
	# The settings screen's hint line changes with the hovered row, so the panel
	# has to be rebuilt rather than just re-highlighted.
	if model.screen == MenuModel.Screen.SETTINGS:
		_refresh()
		_panel.set_hovered(row)


## Presses whatever is under the pointer. Public so [MenuProbe] can fly the
## menu the same way a player does, rather than calling the model directly and
## proving only that the model works.
func press() -> void:
	if not is_open or _hover_row < 0:
		return
	var previous: MenuModel.Screen = model.screen
	var action: StringName = model.activate(_hover_row)
	var moved: bool = model.screen != previous
	# A settings row is the only thing that can have changed a value, and
	# pushing them all through again costs five assignments.
	apply_settings()
	_refresh()
	if moved:
		_hover(-1)
		_set_paused(model.is_pausing())
		_place_now()
	else:
		_panel.set_hovered(_hover_row)
	_act(action)


func hovered_row() -> int:
	return _hover_row


## Where row [param row] is in the world, for anything that needs to aim at it.
func row_point(row: int) -> Vector3:
	if _panel == null:
		return global_position
	return _panel.global_transform * Vector3(
		0.0,
		MenuLayout.row_centre(row, _panel.rows, _panel.has_title, _panel.body_lines),
		0.0
	)


## Re-reads the pointer this frame. Public so a probe can point and then press
## without waiting for the next frame.
func repoint() -> void:
	if is_open and _panel != null:
		_update_pointing()


# --- input -------------------------------------------------------------------

func _bind_controller_buttons() -> void:
	if not player.xr_active:
		return
	for controller: XRController3D in [player.left_hand, player.right_hand]:
		controller.button_pressed.connect(_on_controller_button)


func _on_controller_button(button: String) -> void:
	if OPEN_BUTTONS.has(button):
		toggle()
		return
	if is_open and SELECT_BUTTONS.has(button):
		press()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not is_open or player.xr_active:
		return
	if event is InputEventMouseMotion:
		_mouse_position = (event as InputEventMouseMotion).position
		_update_pointing()
	elif event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			_mouse_position = click.position
			_update_pointing()
			press()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		_keyboard(event as InputEventKey)


## Keyboard navigation exists for desktop iteration, not for players. It costs
## twenty lines and makes every menu change testable without a headset.
func _keyboard(key: InputEventKey) -> void:
	var count: int = model.rows().size()
	match key.keycode:
		KEY_DOWN:
			_hover(posmod(_hover_row + 1, maxi(count, 1)))
		KEY_UP:
			_hover(posmod(_hover_row - 1 if _hover_row >= 0 else count - 1, maxi(count, 1)))
		KEY_LEFT:
			if model.adjust(_hover_row, -1):
				apply_settings()
				_refresh()
				_panel.set_hovered(_hover_row)
		KEY_RIGHT:
			if model.adjust(_hover_row, 1):
				apply_settings()
				_refresh()
				_panel.set_hovered(_hover_row)
		KEY_ENTER, KEY_SPACE, KEY_KP_ENTER:
			press()


func _on_tutorial_finished() -> void:
	settings.set_value("learned", 1.0)
	settings.save(settings_path)
