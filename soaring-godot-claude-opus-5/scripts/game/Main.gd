extends Node3D

## Assembles the game: world, player, flock, HUD.

const PLAYER_SCENE: String = "res://scenes/Player.tscn"
const SPAWN_ALTITUDE: float = 95.0

var world: WorldBuilder
var player: BirdPlayer
var manager: GameManager
var hud: HUD
var audio: FlightAudio


func _ready() -> void:
	world = WorldBuilder.new()
	world.name = "World"
	add_child(world)

	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as BirdPlayer
	player.name = "Player"
	add_child(player)
	# Start airborne and already at flying speed. Being dropped into a stall on
	# spawn is a miserable first three seconds, and the whole point is the air.
	var start := Vector3(0.0, world.height_at(0.0, 0.0) + SPAWN_ALTITUDE, 0.0)
	player.global_position = start
	player.set_spawn_point(start)
	player.model.velocity = player.model.forward() * player.model.trim_speed()

	manager = GameManager.new()
	manager.name = "GameManager"
	add_child(manager)
	manager.setup(player, world)

	hud = HUD.new()
	hud.name = "HUD"
	hud.attach(player, manager)

	audio = FlightAudio.new()
	audio.name = "FlightAudio"
	add_child(audio)
	audio.attach(player)

	player.perched_changed.connect(_on_perched_changed)
	manager.player_was_caught.connect(_on_player_caught)

	print("[Soaring] ready — %d birds aloft" % manager.birds.size())
	_maybe_schedule_capture()
	_maybe_run_probe()
	_maybe_run_xr_diagnostic()


func _maybe_run_xr_diagnostic() -> void:
	if not _flag("xrdiag"):
		return
	var diagnostic := XRDiagnostic.new()
	diagnostic.name = "XRDiagnostic"
	add_child(diagnostic)
	diagnostic.start(player)
	_finish_diagnostic(diagnostic)


func _finish_diagnostic(diagnostic: XRDiagnostic) -> void:
	await get_tree().create_timer(12.0).timeout
	get_tree().quit(0 if diagnostic.report() else 1)


func _maybe_run_probe() -> void:
	if not _flag("probe"):
		return
	var probe := FlightProbe.new()
	probe.name = "FlightProbe"
	add_child(probe)
	probe.finished.connect(func(passed: bool) -> void: get_tree().quit(0 if passed else 1))
	probe.start(player, world, manager)


func _flag(name: String) -> bool:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == name and parts[1] != "0":
			return true
	return false


## Lets the CLI photograph the running game:
##   godot -- --capture=/tmp/shot.png --capture_delay=6
## Iterating on a VR world from a terminal is otherwise blind.
func _maybe_schedule_capture() -> void:
	var path: String = ""
	var delay: float = 4.0
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() != 2:
			continue
		if parts[0] == "capture":
			path = parts[1]
		elif parts[0] == "capture_delay":
			delay = parts[1].to_float()
	if path.is_empty():
		return
	_capture_after(path, delay)


func _capture_after(path: String, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	var source: Viewport = get_viewport()
	if player.xr_active:
		# In XR the main viewport is submitted straight to the compositor and
		# reads back black, so photograph the scene through a mirror camera
		# pinned to the headset instead. Same pose, same view, capturable.
		source = _build_headset_mirror()
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image: Image = source.get_texture().get_image()
	var error: int = image.save_png(path)
	print("[Soaring] captured %s (%d)" % [path, error])
	get_tree().quit(0)


## A plain (non-XR) viewport looking out of the player's headset. Used only for
## capturing what the player sees, so VR work can be reviewed from a terminal.
func _build_headset_mirror() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 900)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = get_viewport().world_3d
	viewport.own_world_3d = false
	add_child(viewport)

	var camera := Camera3D.new()
	camera.fov = 90.0
	camera.near = 0.05
	camera.far = 4000.0
	viewport.add_child(camera)
	camera.global_transform = player.xr_camera.global_transform
	camera.current = true
	return viewport


func _on_perched_changed(is_perched: bool) -> void:
	if is_perched:
		print("[Soaring] perched")


func _on_player_caught(by_size: float) -> void:
	print("[Soaring] caught by a size %.2f bird" % by_size)
