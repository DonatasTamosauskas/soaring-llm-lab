extends Node3D

## Assembles the game: world, player, flock, HUD.

const PLAYER_SCENE: String = "res://scenes/Player.tscn"
const SPAWN_ALTITUDE: float = 95.0

var world: WorldBuilder
var player: BirdPlayer
var manager: GameManager
var hud: HUD
var audio: FlightAudio


## Identifies exactly which build is running. Written at export time by
## tools/deploy_quest.sh. Without it, "is the fix actually on the device?" is
## unanswerable, and I spent a debugging session assuming instead of knowing.
func _print_build_stamp() -> void:
	var stamp: String = "unstamped (built by hand?)"
	if FileAccess.file_exists("res://build_stamp.txt"):
		stamp = FileAccess.get_file_as_string("res://build_stamp.txt").strip_edges()
	print("[Soaring] build %s" % stamp)


func _ready() -> void:
	_print_build_stamp()
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
	_maybe_run_device_diagnostic()
	_maybe_run_hands_repro()


func _maybe_run_hands_repro() -> void:
	var separation: float = -1.0
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == "hands":
			separation = parts[1].to_float()
	if separation < 0.0:
		return
	var repro := HandsRepro.new()
	repro.name = "HandsRepro"
	add_child(repro)
	repro.finished.connect(func(passed: bool) -> void: get_tree().quit(0 if passed else 1))
	repro.start(player, world, separation)


## On a headset there is no console, so a debug build narrates itself to logcat
## for the first minute. Read it with `adb logcat -s godot`.
func _maybe_run_device_diagnostic() -> void:
	if not (OS.is_debug_build() and (OS.has_feature("mobile") or _flag("diag"))):
		return
	var diagnostic := DeviceDiagnostic.new()
	diagnostic.name = "DeviceDiagnostic"
	add_child(diagnostic)
	diagnostic.start(player, world)


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


## Saves what the player is currently looking at, without disturbing the game.
## On a headset this is the only way to see what the user sees: `adb exec-out
## run-as com.soaring.opus5 cat files/headset.png > headset.png`.
func capture_headset_view(path: String) -> void:
	var source: Viewport = get_viewport()
	if player.xr_active:
		source = _build_headset_mirror()
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image: Image = source.get_texture().get_image()
	var error: int = image.save_png(path)
	print("[Soaring] headset view saved to %s (%d)" % [path, error])
	_report_broken_shaders(image)
	if player.xr_active and source is SubViewport:
		source.queue_free()


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
	_report_broken_shaders(image)
	get_tree().quit(0)


## Counts Godot's "invalid material" magenta in the rendered frame.
##
## This exists because of a bug that shipped to a headset: a shader variant that
## works on Forward+ and fails on Forward Mobile. Draw calls looked healthy,
## no error was logged, and the geometry was still being submitted — it just
## came out magenta on desktop and invisible on Quest hardware. Pixel colour is
## the only signal that actually catches that, so the mobile smoke test asserts
## on this number.
func _report_broken_shaders(image: Image) -> void:
	var magenta: int = 0
	var total: int = 0
	# Sampling every 4th pixel is plenty to spot a corruption this loud, and
	# keeps the scan off the critical path of a capture.
	#
	# The test is "red and blue both strong, green clearly weaker than either"
	# rather than an exact magenta match: the corruption arrives blended with
	# whatever was behind it, so it lands anywhere from hot pink to pale mauve.
	# An exact-match test reported 0.009% on a frame that was visibly a sixth
	# magenta, which is worse than no test at all.
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var c: Color = image.get_pixel(x, y)
			total += 1
			if c.r > 0.6 and c.b > 0.6 and c.g < 0.75 * minf(c.r, c.b):
				magenta += 1
	var fraction: float = 100.0 * float(magenta) / maxf(float(total), 1.0)
	print("[Soaring] broken-shader pixels: %.3f%% (%d of %d sampled)" % [
		fraction, magenta, total
	])


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
