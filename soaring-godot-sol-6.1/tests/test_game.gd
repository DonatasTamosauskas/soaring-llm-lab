extends SceneTree
## End-to-end tests of the real scene, widget signals, food web and tracked rig.
const MainScene = preload("res://scenes/main.tscn")
const UI = preload("res://scripts/ui/game_ui.gd")
const Species = preload("res://scripts/ecology/species.gd")
const FlightModel = preload("res://scripts/flight/model.gd")
var game
var checks := 0
var failures: Array[String] = []
var layout_report: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 800)
	game = MainScene.instantiate()
	root.add_child(game)
	current_scene = game
	await _frames(3)
	_check(game.state == "nest" and not game.player.flying and not game.ecology.active, "Main scene opens at the nest")
	_check(game.ecology.birds.size() == 54, "Complete living population is assembled")
	game.ui.primary.pressed.emit()
	_check(game.state == "flying" and game.player.flying and game.ecology.active and not paused, "Take Flight button launches player and ecosystem")
	var start: Vector3 = game.player.global_position
	await _frames(12)
	_check(game.player.global_position.distance_to(start) > 1.0 and game.ecology.elapsed > 0.05, "Real physics advances flight and ecology")
	await _test_pause()
	await _test_growth()
	await _test_caught_restart()
	_test_integrated_bounds()
	await _test_layouts()
	await _test_xr_tracking_pause()
	paused = false
	# Let the audio thread release active WAV playbacks before tree teardown.
	game.audio.wind.stop()
	game.audio.wind.stream = null
	for voice in game.audio.voices:
		voice.stop()
		voice.stream = null
	OS.delay_msec(60)
	current_scene = null
	game.free()
	game = null
	await _frames(3)
	for failure in failures:
		printerr("FAIL: " + failure)
	print("GAME_LAYOUTS ", JSON.stringify(layout_report))
	print("GAME: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame
	await process_frame

func _test_pause() -> void:
	var momentum: Vector3 = game.player.velocity
	game.toggle_pause()
	_check(game.state == "paused" and paused and not game.ecology.active, "Pause stops the complete gameplay simulation")
	_check(game.player.process_mode == Node.PROCESS_MODE_ALWAYS and game.ui.process_mode == Node.PROCESS_MODE_ALWAYS, "Head/controller tracking and menus process during pause")
	var position: Vector3 = game.player.global_position
	var elapsed: float = game.ecology.elapsed
	var bird_position: Vector3 = game.ecology.birds[0].global_position
	await _frames(24)
	_check(game.player.global_position.is_equal_approx(position), "Pause freezes player position")
	_check(is_equal_approx(game.ecology.elapsed, elapsed) and game.ecology.birds[0].global_position.is_equal_approx(bird_position), "Pause freezes both flock simulation and elapsed time")
	game.ui.secondary.pressed.emit()
	_check(game.ui.state == "guide" and game.state == "paused" and paused, "Field guide retains the paused simulation")
	game.ui.primary.pressed.emit()
	_check(game.ui.state == "paused" and game.state == "paused", "Field-guide Back restores the originating menu")
	game.ui.primary.pressed.emit()
	_check(game.state == "flying" and not paused and game.player.velocity.is_equal_approx(momentum), "Continue button restores flight momentum")
	game.ui.comfort.button_pressed = false
	_check(not game.comfort_enabled and not game.player.comfort, "Comfort widget controls the real flight rig")
	game.ui.comfort.button_pressed = true
	_check(game.player.comfort and is_zero_approx(game.player.origin.rotation.z), "Comfort restores a level horizon")
	game.ui.sound.button_pressed = false
	_check(not game.audio.enabled, "Sound widget mutes generated audio")
	game.ui.sound.button_pressed = true

func _test_growth() -> void:
	var initial_mass: float = game.ecology.player_mass
	var initial_hull: float = game.player._collider.shape.radius
	var initial_tier: String = game.ecology.get_player_tier()
	var growths: Array[int] = [0]
	game.ecology.player_grew.connect(func(_mass: float, _tier: String) -> void: growths[0] += 1)
	for bird in game.ecology.birds:
		bird.protection_remaining = 100.0
	var prey = game.ecology.birds[0]
	prey.protection_remaining = 0.0
	prey.global_position = game.player.global_position
	prey.previous_position = prey.global_position
	game.ecology.previous_player_position = game.player.global_position
	game.ecology._resolve_catches()
	_check(game.ecology.catches == 1 and game.ecology.player_mass > initial_mass and not prey.alive, "Real food-web contact consumes prey and grows the player")
	_check(game.ecology.get_player_tier() != initial_tier and growths[0] == 1, "Growth signal advances the progression tier")
	_check(is_equal_approx(game.player.mass, game.ecology.player_mass) and game.player._collider.shape.radius > initial_hull, "Growth reaches the player hull")
	_check(game.player.scale.is_equal_approx(Vector3.ONE) and game.player.origin.scale.is_equal_approx(Vector3.ONE) and is_equal_approx(game.player.origin.world_scale, 1.0), "Progression preserves physical tracking scale")
	var light = FlightModel.new()
	var grown = FlightModel.new()
	light.update(1.0 / 90.0, {"flap": 1.0}, initial_mass)
	grown.update(1.0 / 90.0, {"flap": 1.0}, game.player.mass)
	_check(grown.velocity.y < light.velocity.y, "Integrated growth changes the flight response")
	# Reach the final tier through actual catch/reward/signal routing.
	for catch_index in range(13):
		prey.alive = true
		prey.set_mass(game.ecology.player_mass * 0.80)
		prey.protection_remaining = 0.0
		prey.global_position = game.player.global_position
		prey.previous_position = prey.global_position
		game.ecology._resolve_catches()
	_check(game.ecology.player_mass >= Species.CROWN_MASS and game.ecology.crowned and game.crowned, "Relevant catches complete sovereign progression in the assembled game")
	game.toggle_pause()
	_find_button(game.ui, "Return to nest / restart").pressed.emit()
	_check(game.state == "nest" and not paused and not game.player.flying and game.ecology.catches == 0 and game.ecology.get_player_tier() == "Wren", "Restart widget resets catches, tier and flight state")
	_check(is_equal_approx(game.player.mass, game.ecology.START_MASS) and is_equal_approx(game.ecology.player_mass, game.ecology.START_MASS) and not game.crowned, "Restart resets both growth state and player mass")
	_check(game.player.global_position.is_equal_approx(game.world.spawn_position), "Restart returns to the launch nest")

func _test_caught_restart() -> void:
	game.ui.primary.pressed.emit()
	for bird in game.ecology.birds:
		bird.protection_remaining = 100.0
	var predator = game.ecology.birds.back()
	predator.protection_remaining = 0.0
	predator.catch_cooldown = 0.0
	predator.global_position = game.player.global_position
	predator.previous_position = predator.global_position
	game.ecology.grace_remaining = 0.0
	game.ecology.previous_player_position = game.player.global_position
	game.ecology._resolve_catches()
	_check(game.ecology.player_dead and game.state == "caught" and paused and not game.player.flying and not game.ecology.active, "Predator contact shows results and freezes the ecosystem")
	_check(game.ui.guide.text.contains("Caught by") and game.ui.guide.text.contains("catches") and game.ui.guide.text.contains("mass"), "Result menu includes predator, catches and progression score")
	var position: Vector3 = game.player.global_position
	var bird_position: Vector3 = game.ecology.birds[1].global_position
	await _frames(20)
	_check(game.player.global_position.is_equal_approx(position) and game.ecology.birds[1].global_position.is_equal_approx(bird_position), "Caught state remains frozen while its menu processes")
	game.ui.primary.pressed.emit()
	_check(game.state == "nest" and not game.ecology.player_dead and game.ecology.catches == 0, "Fly Again widget resets a caught run")

func _test_layouts() -> void:
	for state_name in ["nest", "paused", "caught", "guide"]:
		game.ui.show_state(state_name, "Caught by Sovereign.\n14 catches / 2.35 mass / 91 seconds aloft.")
		await _frames(2)
		_record_layout(game.ui, Vector2(1280, 800), "desktop", state_name)
	game.ui.show_state("nest")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1000, 820)
	root.add_child(viewport)
	var ui = UI.new()
	ui.xr_mode = true
	viewport.add_child(ui)
	for state_name in ["nest", "paused", "caught", "guide"]:
		ui.show_state(state_name, "Caught by Sovereign.\n14 catches / 2.35 mass / 91 seconds aloft.")
		await _frames(2)
		_record_layout(ui, Vector2(1000, 820), "xr", state_name)
	viewport.free()

func _test_integrated_bounds() -> void:
	_check(is_equal_approx(game.player.soft_boundary_radius, 175.0) and is_equal_approx(game.player.hard_boundary_radius, 200.0) and is_equal_approx(game.player.flight_ceiling, 112.0), "Main scene configures the player with the real world's flight bounds")
	game.player.global_position = Vector3(207.0, 114.0, 0.0)
	game.player.velocity = Vector3(20.0, 8.0, 0.0)
	game.player._guard_world_limits()
	_check(Vector2(game.player.global_position.x, game.player.global_position.z).length() <= 200.01 and game.player.global_position.y <= 112.0 and game.player.velocity.x <= 0.0 and game.player.velocity.y < 0.0, "Integrated world guard contains an out-of-world fallback and turns ceiling motion downward")
	game.player.reset_at(game.world.spawn_position)

func _record_layout(ui: Control, viewport_size: Vector2, mode: String, state_name: String) -> void:
	var clipped: Array[String] = []
	var widgets: Array[Control] = [ui.title, ui.subtitle, ui.guide, ui.note]
	widgets.append_array(_buttons(ui))
	for widget in widgets:
		if not widget.is_visible_in_tree():
			continue
		var rect: Rect2 = widget.get_global_rect()
		if rect.position.x < -1.0 or rect.position.y < -1.0 or rect.end.x > viewport_size.x + 1.0 or rect.end.y > viewport_size.y + 1.0:
			clipped.append(str(widget.text).substr(0, 70))
	layout_report.append({"mode": mode, "state": state_name, "panel": str(ui.panel.get_global_rect()), "guide": str(ui.guide.get_global_rect()), "primary": str(ui.primary.get_global_rect()), "clipped": clipped})
	_check(clipped.is_empty(), "%s %s menu keeps controls within its viewport: %s" % [mode, state_name, clipped])

func _buttons(node: Node) -> Array[Button]:
	var result: Array[Button] = []
	if node is Button:
		result.append(node)
	for child in node.get_children():
		result.append_array(_buttons(child))
	return result

func _find_button(node: Node, text_value: String) -> Button:
	for button in _buttons(node):
		if button.text == text_value:
			return button
	return null

func _test_xr_tracking_pause() -> void:
	# Build the real immersive menu path with deterministic native trackers.
	# OpenXR itself is exercised by the separate Meta Simulator acceptance run.
	var old_layer: Node = game.ui.get_parent()
	game.player.configure(true)
	game.xr_active = true
	game._build_ui()
	game._build_xr_ui()
	old_layer.free()
	game._set_state("nest")
	game.ui.primary.pressed.emit()
	game.player.global_position = Vector3(0.0, 75.0, 0.0)
	game.ecology.previous_player_position = game.player.global_position
	await _frames(85)
	_check(game.state == "paused" and paused and game.player.tracking_lost_seconds > 0.75, "Prolonged native controller tracking loss automatically pauses the game")
	_check(game.menu_surface.visible and game.menu_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Tracking-loss pause leaves the immersive menu accessible")
	var trackers: Array[XRControllerTracker] = []
	game.player.head.position.y = 1.6
	for index in range(2):
		var tracker := XRControllerTracker.new()
		tracker.name = &"left_hand" if index == 0 else &"right_hand"
		tracker.set_input(&"grip", 1.0)
		tracker.set_input(&"trigger", 0.0)
		tracker.set_input(&"primary", Vector2.ZERO)
		tracker.set_input(&"ax_button", false)
		tracker.set_pose(&"grip", Transform3D(Basis(Vector3.RIGHT, 0.6), Vector3(-0.28 if index == 0 else 0.28, 1.04, -0.35)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
	await _frames(3)
	_check(game.player.tracking_valid and is_zero_approx(game.player.tracking_lost_seconds), "Native tracking recovers while game remains safely paused")
	var previous_calibrations: int = game.control_events.calibration
	game.ui.calibration.pressed.emit()
	_check(game.control_events.calibration == previous_calibrations, "Immersive calibration gives the player time to lower pointing arms")
	await _frames(195)
	_check(game.control_events.calibration == previous_calibrations + 1 and game.player._calibrated_tracking, "Immersive calibration button routes to the tracked flight rig")
	game.ui.primary.pressed.emit()
	_check(game.state == "flying" and not paused and not game.menu_surface.visible, "Continue leaves the immersive menu and resumes flight")
	await _frames(3)
	_check(absf(game.player.flight_model.pitch) < 0.05 and not game.player.flight_model.stalled, "Recovered calibrated controllers resume neutral unstalled flight")
	game.toggle_pause()
	_find_button(game.ui, "Restart").pressed.emit()
	_check(game.state == "nest" and not paused and game.ecology.catches == 0 and game.menu_surface.visible, "Immersive Restart widget returns a paused flight to the nest")
	for tracker in trackers:
		XRServer.remove_tracker(tracker)
