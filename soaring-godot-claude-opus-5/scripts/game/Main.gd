extends Node3D

## Assembles the game: world, player, flock, HUD.

const PLAYER_SCENE: String = "res://scenes/Player.tscn"
## High enough to learn to fly in. Measured, not chosen: [FirstContact] flies a
## novice through the coach's four lessons and they cost about 70 m of glide
## before the dive lesson, which then spends another 50 m — so at the old 95 m a
## player following the game's own instructions reached the last lesson at
## treetop height and finished it in a field. This leaves a first session about
## a minute of air to be wrong in.
const SPAWN_ALTITUDE: float = 190.0

var world: WorldBuilder
var player: BirdPlayer
var manager: GameManager
var hud: HUD
var menu: GameMenu
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

	# The menu is a sibling of the world rather than a child of the camera: it is
	# an object standing in the sky, not a layer stuck to the player's face.
	menu = GameMenu.new()
	menu.name = "GameMenu"
	add_child(menu)
	menu.attach(player, manager, hud)

	audio = FlightAudio.new()
	audio.name = "FlightAudio"
	add_child(audio)
	audio.attach(player, manager, world)

	player.perched_changed.connect(_on_perched_changed)
	manager.player_was_caught.connect(_on_player_caught)
	manager.event_occurred.connect(_on_game_event)

	print("[Soaring] ready — %d birds aloft" % manager.birds.size())
	_maybe_open_menu()
	_maybe_run_menu_probe()
	_maybe_schedule_capture()
	_maybe_run_probe()
	_maybe_run_hunt_probe()
	_maybe_demo_event()
	_maybe_run_xr_diagnostic()
	_maybe_run_device_diagnostic()
	_maybe_run_hands_repro()
	_maybe_run_first_contact()


## Catching something has to be felt, not read. The event channel is the only
## place that knows a catch happened, so the sound and the haptic pulse are wired
## here rather than inside the rules — [GameManager] stays a scene-light object
## that emits what happened and does not care who reacts.
func _on_game_event(kind: StringName, payload: Dictionary) -> void:
	match kind:
		&"catch":
			audio.cue(&"catch")
			player.haptic_cue(
				&"catch", clampf(0.5 + 0.1 * float(payload.get("streak", 1)), 0.5, 1.0)
			)
		&"caught":
			audio.cue(&"caught")
			player.haptic_cue(&"caught", 1.0)
		&"rank_up":
			audio.cue(&"rank_up")
			player.haptic_cue(&"rank_up", 1.0)
		&"rank_down":
			audio.cue(&"rank_down")
		&"ended":
			audio.cue(&"won" if bool(payload.get("won", false)) else &"lost")


## Flags that mean "something is flying this game from a script": a probe, a
## diagnostic, a capture. None of them can press a FLY button, so none of them
## get a main menu.
## `uiprobe` is deliberately absent: the menu probe's first job is to check that
## the game opens on a menu at all, so it has to arrive the way a player does.
const HEADLESS_FLAGS: PackedStringArray = [
	"probe", "hunt", "hands", "demo", "xrdiag", "diag", "capture", "firstcontact",
]


const MENU_SCREENS: Dictionary = {
	"main": MenuModel.Screen.MAIN,
	"pause": MenuModel.Screen.PAUSE,
	"settings": MenuModel.Screen.SETTINGS,
	"controls": MenuModel.Screen.CONTROLS,
}


## A player arrives at a menu; everything else arrives in mid-air. `--menu=` also
## names a screen, which is how each one gets photographed and looked at:
##   godot --xr-mode off -- --menu=settings --capture=/tmp/m.png --capture_delay=6
## (the summary is reached through `--demo=ended`, which loses a run for you.)
func _maybe_open_menu() -> void:
	var wanted: String = _argument("menu")
	if MENU_SCREENS.has(wanted):
		menu.open(MENU_SCREENS[wanted])
		return
	if _flag("menu"):
		menu.open(MenuModel.Screen.MAIN)
		return
	if wanted == "0":
		return
	for flag: String in HEADLESS_FLAGS:
		if _argument(flag) != "":
			return
	menu.open(MenuModel.Screen.MAIN)


func _argument(name: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == name:
			return parts[1]
	return ""


## Drives the real menu through the real game the way a player does — points at
## rows, presses them, and checks that the world stopped, started and restarted.
##   godot --headless --xr-mode off --fixed-fps 90 -- --uiprobe=1
func _maybe_run_menu_probe() -> void:
	if not _flag("uiprobe"):
		return
	var probe := MenuProbe.new()
	probe.name = "MenuProbe"
	add_child(probe)
	probe.finished.connect(func(passed: bool) -> void: get_tree().quit(0 if passed else 1))
	probe.start(player, manager, menu)


## Fires one game event a moment after launch so the HUD states that only happen
## mid-run — a catch banner, a promotion, the end-of-run summary — can be
## photographed and looked at:
##   godot --xr-mode off -- --demo=ended --capture=/tmp/x.png --capture_delay=8
## Without it the only way to see the summary panel is to lose a real run, which
## takes a quarter of an hour and cannot be aimed at a screenshot.
func _maybe_demo_event() -> void:
	var kind: String = ""
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == "demo":
			kind = parts[1]
	if kind.is_empty():
		return
	_fire_demo_event(kind)


func _fire_demo_event(kind: String) -> void:
	await get_tree().create_timer(3.0).timeout
	match kind:
		"catch":
			# The player's size is moved too, not just the session's: rank is
			# re-derived from the bird every frame, so a session that grew while
			# the bird did not would be demoted again a frame later.
			for size: float in [1.18, 1.30, 1.42]:
				player.set_size(size)
				manager.session.record_catch(0.7, size)
			manager.event_occurred.emit(&"catch", {
				"prey": 0.7, "score": 43, "streak": 3, "total": 96, "size": 1.42,
			})
		"rank":
			manager.event_occurred.emit(
				&"rank_up", {"index": 2, "name": "RAIDER", "size": 1.24}
			)
		"caught":
			manager.event_occurred.emit(
				&"caught", {"by": 2.1, "lives": 3, "size": 0.86, "final": false}
			)
		"restart":
			# Ends a run, waits out the arm delay, then beats the wings once and
			# checks that the next run actually started. The only automated cover
			# for the way a player leaves the summary screen, which is otherwise
			# unreachable without losing a real quarter-hour run.
			for i in Progression.LIVES:
				manager.session.record_death(2.4)
			await get_tree().create_timer(GameManager.RESTART_ARM_DELAY + 0.6).timeout
			var beat := FlightCommand.new()
			beat.span = 1.0
			beat.alpha = player.model.alpha_trim
			beat.stroke_speed = 3.0
			player.scripted_command = beat
			await get_tree().create_timer(0.4).timeout
			player.scripted_command = null
			var flying: bool = not manager.session.is_over()
			print("[Soaring] restart check: state %s, size %.2f, lives %d, catches %d" % [
				"FLYING" if flying else "OVER", player.size, manager.session.lives,
				manager.session.catches,
			])
			get_tree().quit(
				0 if flying and is_equal_approx(player.size, Progression.START_SIZE)
					and manager.session.lives == Progression.LIVES else 1
			)
		"ended", "won":
			for i in 6:
				player.set_size(1.4 + 0.3 * float(i))
				manager.session.record_catch(1.0, player.size)
			if kind == "won":
				player.set_size(Progression.APEX_SIZE)
				manager.session.record_catch(2.9, player.size)
			else:
				for i in Progression.LIVES:
					manager.session.record_death(2.4)
			# The armed prompt only appears after the delay a real run gives you.
			await get_tree().create_timer(GameManager.RESTART_ARM_DELAY + 0.4).timeout


## Measures the real hunting loop: an autopilot flies the real game and counts
## catches, chases and deaths, which is what [SessionSim] is calibrated against.
##   godot --headless --xr-mode off --fixed-fps 90 -- --hunt=600
func _maybe_run_hunt_probe() -> void:
	var seconds: float = -1.0
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == "hunt":
			seconds = parts[1].to_float()
	if seconds <= 0.0:
		return
	var probe := SessionProbe.new()
	probe.name = "SessionProbe"
	probe.evade = _flag("hunt_evade")
	probe.endless = _flag("hunt_endless")
	probe.gate = _flag("hunt_gate")
	add_child(probe)
	probe.finished.connect(func(passed: bool) -> void: get_tree().quit(0 if passed else 1))
	probe.start(player, world, manager, seconds)


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


## Flies somebody's first session and checks that following the game's own
## instructions leaves them in the air:
##   godot --headless --xr-mode off --fixed-fps 90 -- --firstcontact=1
func _maybe_run_first_contact() -> void:
	if not _flag("firstcontact"):
		return
	var probe := FirstContact.new()
	probe.name = "FirstContact"
	add_child(probe)
	probe.finished.connect(func(passed: bool) -> void: get_tree().quit(0 if passed else 1))
	probe.start(player, world, hud)


## On a headset there is no console, so a debug build narrates itself to logcat
## for the first minute. Read it with `adb logcat -s godot`.
func _maybe_run_device_diagnostic() -> void:
	if not (OS.is_debug_build() and (OS.has_feature("mobile") or _flag("diag"))):
		return
	var diagnostic := DeviceDiagnostic.new()
	diagnostic.name = "DeviceDiagnostic"
	add_child(diagnostic)
	diagnostic.start(player, world, manager)


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
