class_name GameMain
extends Node3D
## The game: scenes/main.tscn composes every area as docs/ARCHITECTURE.md §4
## describes, and this script starts it (docs/INTEGRATION.md):
##
##   Main
##   ├── World       scenes/world/world.tscn   (placeholder until its step)
##   ├── Ecosystem   scenes/ai/ecosystem.tscn  (placeholder until its step)
##   ├── Player      scenes/player/player.tscn (placeholder until its step)
##   │   └── XROrigin3D/VRRigExtras  scenes/vr/vr_rig_extras.tscn
##   ├── GameLoop    scripts/game/game_loop.gd (created in its step)
##   ├── UI          scenes/ui/ui_root.tscn    (placeholder until its step)
##   ├── Audio       scenes/audio/audio_director.tscn (placeholder)
##   ├── BirdFX      BirdFXDirector (feather bursts on every catch)
##   ├── UISounds    UISoundBridge (menu sounds; created with the UI)
##   └── XRMirror    head-view captures for the simulator (renders only then)
##
## Startup never freezes a frame of ours for long: the headset gets a boot
## rig (an XROrigin3D and camera of our own) with the day sky and a loading
## card, and the work runs in steps (bird meshes, the valley, the player at
## the valley's spawn, the population, the loop, audio, the menus) with the
## card updated in between; in a headset the long steps run before the
## first frame, under the runtime's own loading indicator (see boot()).
## Then BOOT -> MENU with the main menu in front of the player. Each step's
## time and the longest frame gap after it are in `load_report`.
##
## Game-state glue owned here (nobody else's job):
##  * the player's body is still in BOOT, MENU and ENDED (a calm view behind
##    the menus; arms pointing at a menu never fly the bird) and flies in
##    PLAYING and CAUGHT; back in the menu it waits on the spawn perch;
##  * desktop: the mouse looks around while flying (captured), and is free
##    in menus (the UI frees it);
##  * Quit stops every sound (AudioDirector.shutdown) before quitting;
##  * a Quest quality tier (QualityTier) on Android or with --quality=quest.
##
## User args: --quality=quest|full, --harness=<name> (adds
## res://tests/shots/integration_<name>.gd as a child: simulator and
## evidence runs of this very scene), --load_report=<tag> (writes
## artifacts/integration/load_<tag>.json), --load_mode=stepped|early (see
## boot()).

signal loaded(report: Dictionary)
signal quit_started()

const LOAD_STEPS := ["birds", "world", "player", "ecosystem", "game_loop", "audio", "warm_up", "ui"]
const STEP_TEXT := {
	"birds": "Preening the birds",
	"world": "Shaping the valley",
	"player": "Finding a perch",
	"ecosystem": "Filling the sky",
	"game_loop": "Setting the pecking order",
	"audio": "Tuning the wind",
	"warm_up": "Warming up",
	"ui": "Ready",
}
## How long to wait for an XR session to show frames before loading anyway.
const XR_WAIT_S := 8.0
## Frames drawn with the whole world behind the card before the menu opens
## (pipelines compile, the population settles).
const WARM_UP_FRAMES := 12
const RIG_EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
## Eye height of the boot rig on desktop (VR tracks the real head).
const BOOT_EYE := 1.6

## Quit really quits (tests turn it off and watch quit_started).
@export var quit_for_real := true
## Run the startup steps (tests may drive them one by one).
@export var auto_boot := true

var world: World
var ecosystem: Ecosystem
var player: PlayerBird
var rig_extras: VRRigExtras
var game_loop: GameLoop
var ui: UIRoot
var audio: AudioDirector
var fx: BirdFXDirector
var ui_sounds: UISoundBridge
var mirror: XRMirror
var card: LoadingCard
var quality: QualityTier
## The Quest tier's frame-rate safety valve (VR only; see QualityGovernor).
var governor: QualityGovernor
## Play's gate to the first flight (the first-launch wing calibration).
var gate: FirstFlightGate
var is_loaded := false
var load_report := {}

var _boot_env: WorldEnvironment
var _boot_rig: XROrigin3D
var _boot_cam: XRCamera3D
var _bank_held := false
var _quitting := false
var _frame_prev_us := 0
var _max_gap_us := 0
var _boot_t0_us := 0
var _spawn := Transform3D.IDENTITY


func _ready() -> void:
	_boot_t0_us = Time.get_ticks_usec()
	# ms since the engine started: scene load and script compilation, the
	# time the headset shows the system's own loading indicator.
	load_report["engine_to_main_ms"] = Time.get_ticks_msec()
	if Game.state != Game.State.BOOT:
		Game.set_state(Game.State.BOOT)
	get_tree().auto_accept_quit = false
	fx = $BirdFX as BirdFXDirector
	mirror = $XRMirror as XRMirror
	quality = QualityTier.choose()
	_boot_env = WorldEnvironment.new()
	_boot_env.name = "BootSky"
	_boot_env.environment = WorldSky.make_environment(&"day")
	add_child(_boot_env)
	# The boot rig: the headset's view until the player exists (the player
	# spawns into the finished valley, ARCHITECTURE §4). Not in "player_rig".
	_boot_rig = XROrigin3D.new()
	_boot_rig.name = "BootRig"
	_boot_rig.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_boot_rig)
	_boot_cam = XRCamera3D.new()
	_boot_cam.name = "XRCamera3D"
	_boot_cam.near = WorldScaleDriver.NEAR_K
	_boot_cam.far = 3000.0
	if not VR.active:
		_boot_cam.position = Vector3(0, BOOT_EYE, 0)
	_boot_rig.add_child(_boot_cam)
	_boot_rig.current = true
	_boot_cam.current = true
	mirror.source = _boot_cam
	card = LoadingCard.new()
	card.rig = _boot_rig
	card.camera = _boot_cam
	_boot_rig.add_child(card)
	card.set_text("Loading")
	# The audio buffers synthesize on worker threads from now on, while the
	# main thread builds the world (the director takes the same bank later).
	AudioBank.acquire(true)
	_bank_held = true
	Events.game_state_changed.connect(_on_game_state_changed)
	var h := Paths.arg("harness", "")
	if not h.is_empty():
		var path := "res://tests/shots/integration_%s.gd" % h
		if ResourceLoader.exists(path):
			var harness: Node = load(path).new()
			harness.name = "Harness"
			add_child(harness)
	print("[integration] main ready %d ms after engine start (quality %s)" % [load_report["engine_to_main_ms"], quality.name])
	if auto_boot:
		boot()


func _exit_tree() -> void:
	get_tree().auto_accept_quit = true
	if _bank_held:
		_bank_held = false
		AudioBank.release()
	if Events.game_state_changed.is_connected(_on_game_state_changed):
		Events.game_state_changed.disconnect(_on_game_state_changed)


func _process(_dt: float) -> void:
	# Longest frame-to-frame gap since the last reset: during loading, the
	# longest time the headset got no new frame.
	var now := Time.get_ticks_usec()
	if _frame_prev_us > 0:
		_max_gap_us = maxi(_max_gap_us, now - _frame_prev_us)
	_frame_prev_us = now


# =====================================================================
# Startup
# =====================================================================

## Runs every load step, one per frame, then opens the main menu.
func boot() -> void:
	load_report["steps"] = []
	# In the headset, until the XR session shows frames of ours the runtime
	# draws its own loading indicator (compositor-drawn, head-tracked). The
	# two long steps (bird meshes, the valley: ~1.4-1.8 s on the M1, several
	# times that on a Quest) run there, before our first frame, so no frame
	# of ours ever stands frozen for long. On a desktop (and when a session
	# is already showing frames) they run after the card, one per frame.
	# --load_mode=stepped|early forces either (measurements).
	var mode := Paths.arg("load_mode", "")
	var early := mode == "early" or (mode != "stepped" and VR.active \
		and not (VR.session_state in ["synchronized", "visible", "focused"]))
	var done_early: Array[String] = []
	if early:
		for step: String in ["birds", "world", "player"]:
			var te := Time.get_ticks_usec()
			await _run_step(step)
			var ms_e := (Time.get_ticks_usec() - te) / 1000.0
			load_report["steps"].append({"name": step, "ms": snappedf(ms_e, 0.1), "max_frame_gap_ms": 0.0,
				"before_first_frame": true})
			print("[integration] load step %-9s %7.1f ms (before the first frame)" % [step, ms_e])
			done_early.append(step)
	load_report["mode"] = "early" if early else "stepped"
	var t_first := Time.get_ticks_usec()
	await _first_frames()
	load_report["first_frames_ms"] = (Time.get_ticks_usec() - t_first) / 1000.0
	var n := LOAD_STEPS.size()
	for i in n:
		var step: String = LOAD_STEPS[i]
		if done_early.has(step):
			continue
		card.set_text(STEP_TEXT.get(step, step))
		card.progress = float(i) / n
		# Let the card's new line reach the headset before the work starts.
		await _frames(2)
		_max_gap_us = 0
		var t0 := Time.get_ticks_usec()
		await _run_step(step)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		await _frames(1)
		var gap := _max_gap_us / 1000.0
		load_report["steps"].append({"name": step, "ms": snappedf(ms, 0.1), "max_frame_gap_ms": snappedf(gap, 0.1)})
		print("[integration] load step %-9s %7.1f ms (longest frame gap %.1f ms)" % [step, ms, gap])
	load_report["total_ms"] = snappedf((Time.get_ticks_usec() - _boot_t0_us) / 1000.0, 0.1)
	load_report["audio_bank_ready"] = audio != null and audio.bank_ready()
	var worst := 0.0
	for s: Dictionary in load_report["steps"]:
		worst = maxf(worst, float(s["max_frame_gap_ms"]))
	load_report["worst_frame_gap_ms"] = worst
	print("[integration] loaded in %.0f ms (engine start to menu %d ms; worst frame gap %.0f ms)" % [
		load_report["total_ms"], Time.get_ticks_msec(), worst])
	var tag := Paths.arg("load_report", "")
	if not tag.is_empty():
		var f := FileAccess.open(Paths.artifacts("integration").path_join("load_%s.json" % tag), FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(load_report, "  "))
	is_loaded = true
	loaded.emit(load_report)


func _run_step(step: String) -> void:
	match step:
		"birds":
			_step_birds()
		"world":
			_step_world()
		"player":
			_step_player()
		"ecosystem":
			await _step_ecosystem()
		"game_loop":
			_step_game_loop()
		"audio":
			_step_audio()
		"warm_up":
			await _step_warm_up()
		"ui":
			_step_ui()


## Frames on screen before any heavy work: in VR, until the session shows
## frames (or XR_WAIT_S), then a few drawn frames with the sky and the card.
func _first_frames() -> void:
	if VR.active:
		var t0 := Time.get_ticks_msec()
		while not (VR.session_state in ["visible", "focused"]) and Time.get_ticks_msec() - t0 < int(XR_WAIT_S * 1000.0):
			await get_tree().process_frame
	await _frames(3)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _step_birds() -> void:
	# All 30 species x LOD meshes now (~74 ms on an M1) instead of ~8 ms
	# stalls the first time each species appears in flight.
	BirdModels.prewarm()


func _step_world() -> void:
	var ph := get_node(^"World") as InstancePlaceholder
	# One sky at a time: the world brings the same day sky and its sun.
	remove_child(_boot_env)
	_boot_env.queue_free()
	world = ph.create_instance(true) as World
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	_spawn = world.get_player_spawn()


## The player spawns at the valley's spawn (on its perch), with VR's rig
## extras under its XROrigin3D; the boot rig hands the headset over to it.
func _step_player() -> void:
	var ph := get_node(^"Player") as InstancePlaceholder
	var p := (load(ph.get_instance_path()) as PackedScene).instantiate() as PlayerBird
	p.name = "Player"
	# Its _ready respawns at its own transform: the spawn perch.
	p.transform = _spawn
	# Still until a run starts (a menu is no place to fly).
	p.auto_process = false
	rig_extras = RIG_EXTRAS.instantiate() as VRRigExtras
	# The first-launch calibration waits for Play (FirstFlightGate), not for
	# the session's focus: set before the node's first tick, so the card
	# never comes up over the loading card or the main menu.
	var cal := rig_extras.get_node_or_null(^"Calibration") as VRCalibration
	if cal != null:
		cal.first_launch_prompt = false
	p.get_node(^"XROrigin3D").add_child(rig_extras)
	# One XROrigin3D at a time: the boot rig goes before the player enters.
	card.reparent(p.get_node(^"XROrigin3D"), false)
	remove_child(_boot_rig)
	_boot_rig.queue_free()
	ph.replace_by(p)
	ph.queue_free()
	player = p
	player.origin.current = true
	player.camera.current = true
	mirror.source = player.camera
	card.rig = player.origin
	card.camera = player.camera
	if not VR.active:
		# Desktop: the virtual arms and head are written into the rig's XR
		# nodes by the pose source during a tick. The body is still in the
		# menu, so give it one tick on its perch now; otherwise the hands sit
		# at the rig's origin and the first-person wings cross the view.
		player.tick(1.0 / 72.0)
	card.place(true)


func _step_ecosystem() -> void:
	var ph := get_node(^"Ecosystem") as InstancePlaceholder
	ecosystem = ph.create_instance(true) as Ecosystem
	ecosystem.process_mode = Node.PROCESS_MODE_PAUSABLE
	quality.apply_ecosystem(ecosystem)
	if quality.governor and VR.active:
		governor = QualityGovernor.new()
		governor.ecosystem = ecosystem
		governor.floor_npcs = QualityTier.GOVERNOR_FLOOR
		governor.ceiling_npcs = quality.max_npcs
		add_child(governor)
	# The first physics step populates the whole sky around the spawn.
	var t0 := Time.get_ticks_msec()
	while ecosystem.count() == 0 and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().physics_frame
	load_report["npcs_at_load"] = ecosystem.count()


func _step_game_loop() -> void:
	game_loop = GameLoop.new()
	game_loop.name = "GameLoop"
	add_child(game_loop)
	move_child(game_loop, player.get_index() + 1)


func _step_audio() -> void:
	var ph := get_node(^"Audio") as InstancePlaceholder
	audio = ph.create_instance(true) as AudioDirector


func _step_warm_up() -> void:
	await _frames(WARM_UP_FRAMES)


func _step_ui() -> void:
	var ph := get_node(^"UI") as InstancePlaceholder
	ui = ph.create_instance(true) as UIRoot
	ui.quit_handler = quit_game
	# Play asks for the wing calibration first on a first launch in the
	# headset (FirstFlightGate); otherwise it is UIRoot's own GameBridge.
	gate = FirstFlightGate.new(get_tree(), ui, rig_extras.calibration if rig_extras != null else null)
	ui.bridge = gate
	ui_sounds = UISoundBridge.new()
	add_child(ui_sounds)
	ui_sounds.attach(ui, audio)
	# The card goes in the frame the menu appears.
	card.queue_free()
	card = null
	Game.set_state(Game.State.MENU)


# =====================================================================
# Game-state glue
# =====================================================================

func _on_game_state_changed(new_state: int, old_state: int) -> void:
	if player == null or not is_instance_valid(player):
		return
	match new_state:
		Game.State.PLAYING, Game.State.CAUGHT:
			player.auto_process = true
			if new_state == Game.State.PLAYING:
				_capture_mouse()
		Game.State.MENU:
			player.auto_process = false
			if old_state != Game.State.BOOT:
				# The menu's view: the spawn perch, calm.
				player.respawn(_spawn)
		Game.State.ENDED, Game.State.BOOT:
			player.auto_process = false


func _capture_mouse() -> void:
	if VR.active or DisplayServer.get_name() == "headless":
		return
	if DisplayServer.window_is_focused():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# Desktop: a click while flying takes the mouse back (after alt-tab).
	if event is InputEventMouseButton and event.pressed and Game.state == Game.State.PLAYING \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


## The menu's Quit (and closing the window): stop every sound, then quit.
func quit_game() -> void:
	if _quitting:
		return
	_quitting = true
	print("[integration] quitting")
	quit_started.emit()
	if audio != null and is_instance_valid(audio):
		await audio.shutdown()
	if quit_for_real:
		get_tree().quit()
