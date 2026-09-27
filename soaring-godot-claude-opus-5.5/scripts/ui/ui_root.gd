class_name UIRoot
extends Node3D
## Root of the UI area (scenes/ui/ui_root.tscn, group "ui_root",
## PROCESS_MODE_ALWAYS). Owns every menu, the HUD, the VR laser pointer and
## the first-flight lessons, and maps game states to screens:
##
##   BOOT/MENU -> main menu      PLAYING -> HUD (+ lessons, cues)
##   PAUSED    -> pause menu     CAUGHT  -> caught screen (menu button pauses)
##   ENDED     -> run summary (a victory offers "Keep flying")
##
## Two surfaces only: `menu_panel` (all menu screens share it; a screen stack
## gives Back) and `hud_panel`. In VR each is a SubViewport on a quad, so at
## most two SubViewports ever exist (U7). On desktop both are 2D overlays.
##
## Talks to other areas only through Events, Game, Settings, Birds, the
## "player_rig" group and GameBridge (duck-typed GameLoop calls).

## VR asks the player to redo arm-span / neutral-wrist calibration.
signal recalibrate_requested()

enum Mode { AUTO, VR, DESKTOP }

## AUTO follows the VR autoload; tests and shots force VR or DESKTOP.
@export var mode: Mode = Mode.AUTO
@export var progress_path := UIProgress.DEFAULT_PATH
## Tint the current target/threat bird via BirdModel.highlight.
@export var highlight_birds := true
## Fallback respawn countdown when GameLoop's stats have no "respawn_in".
@export var respawn_delay := 3.0

const SCREEN_IDS: Array[StringName] = [&"main", &"pause", &"settings", &"howto", &"caught", &"summary"]
## Two menu-button presses closer than this are one press (the VR area may
## emit Events.menu_requested for the same button).
const MENU_DEBOUNCE_MS := 250
## A threat at or above this level is real: its bird is tinted as danger
## and the HUD makes way for it (below it, a distant hawk is not worth
## either). One constant, one comparison (>=), used for both.
const REAL_THREAT := 0.1
## The HUD's centre line is where the player's body faces (see body_yaw),
## followed calmly: the torso estimate is smoothed (time constant
## HUD_BODY_SMOOTH_TAU, s), the HUD holds still while that wanders less than
## HUD_HEADING_LEASH_DEG (the hands' swing in a flap moves the estimate a
## few degrees), then eases back onto it (HUD_HEADING_TAU, s) at no more
## than HUD_FOLLOW_MAX_SPEED deg/s (the menu's own follow is capped at 110).
## A 30 deg torso turn is followed in about 1 s, peaking near 55 deg/s;
## the estimate's jitter at a flap's 1-2 Hz is cut to a third.
const HUD_BODY_SMOOTH_TAU := 0.2
const HUD_HEADING_LEASH_DEG := 6.0
const HUD_HEADING_TAU := 0.2
const HUD_FOLLOW_MAX_SPEED := 90.0
## A player bird without a torso estimate in its telemetry: where it faces
## (Bird.get_forward()) stands in, except while that points more steeply
## than this (degrees) up or down, where its horizontal part is noise or
## flips over the top of a loop; the last good value is held then.
const BODY_STEEP_DEG := 60.0
## Only without a player bird does the HUD follow the head, with this dead
## zone (degrees).
const HUD_FOLLOW_DEADZONE_DEG := 55.0

var vr_mode := false
var menu_panel: UIPanel
var hud_panel: UIPanel
var hud: HUD
var indicators: HudIndicators
var pointer: UIPointer
var onboarding: Onboarding
## GameLoop has been asked for the catch lesson's prey (and not yet told to
## let them go).
var _prey_asked := false
## The catch lesson's help waits while the player closes on a lesson bird:
## within this many of its wingspans, gaining at least LESSON_CLOSING_SPS
## wingspans a second (help puts the swarm ahead again: it would take the
## moth from under the beak).
const LESSON_CLOSING_SPANS := 60.0
const LESSON_CLOSING_SPS := 4.0
## The nearest lesson bird (m) and how fast the player gains on it (m/s,
## smoothed over 0.3 s).
var _prey_d := INF
var _prey_closing := 0.0
## Labels of the last hud_protected_directions(), in order (diagnostics:
## notice_causes).
var protected_labels := PackedStringArray()
var bridge: GameBridge
var progress: UIProgress
var screens := {}
var stack: Array[StringName] = []
var rig: Node3D
var camera: Node3D
## What "Quit" does (tests replace it).
var quit_handler: Callable

var _resume_state: int = Game.State.PLAYING
var _last_menu_ms := -100000
var _summary := {}
var _new_best := false
## Best score shown next to the current run summary (see summary_best()).
var _summary_best := 0
var _shown_top: StringName = &"-"
var _predator_name := ""
var _predator_species: StringName = &""
var _caught_left := -1.0
var _target: Bird
var _threat: Bird
## The threat cue's level (see REAL_THREAT).
var _threat_level := 0.0
var _saved_mouse_mode := -1
var _button_prev := {}
var _rig_retry := 0.0
var _tonemap_check := 0.0
var _custom_sources := false
## The rig the UI's own XR aim controllers live under (attach_rig reuses them).
var _aim_rig: Node3D
## GameLoop whose apex signals are connected (it may appear after the UI).
var _loop: Node
## body_yaw()'s last good value from the facing fallback (NAN: none).
var _facing_yaw := NAN


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _enter_tree() -> void:
	add_to_group(&"ui_root")


func _ready() -> void:
	progress = UIProgress.new(progress_path)
	bridge = GameBridge.new(get_tree())
	quit_handler = func() -> void: get_tree().quit()
	vr_mode = mode == Mode.VR or (mode == Mode.AUTO and VR.active)

	menu_panel = UIPanel.new()
	menu_panel.name = "MenuPanel"
	add_child(menu_panel)

	hud_panel = UIPanel.new()
	hud_panel.name = "HudPanel"
	hud_panel.panel_size = UITheme.HUD_SIZE
	hud_panel.distance = UITheme.HUD_DISTANCE
	# Two bands: notices above the horizon to the right of the centre line,
	# the growth strip low, nothing in the band a hunting bird looks through
	# (see HUD). The panel's frame is the strip's band, the HUD's permanent
	# part.
	hud_panel.bands = HUD.bands()
	hud_panel.pitch_deg = HUD.STATUS_PITCH
	# The HUD's centre line is where the body faces, not the head, and not
	# the flight path: a head at rest looks along it, so the notices beside
	# it and the strip under it stay in view, wherever the head pointed
	# when the HUD appeared (a Play or Resume button, a bird), wherever it
	# turns (to read the notices, to watch prey), and wherever the wind or
	# a loop sends the flight path (the notices make way for that instead).
	hud_panel.yaw_source = body_yaw
	hud_panel.source_smooth_tau = HUD_BODY_SMOOTH_TAU
	hud_panel.source_leash_deg = HUD_HEADING_LEASH_DEG
	hud_panel.source_tau = HUD_HEADING_TAU
	hud_panel.source_max_speed_deg = HUD_FOLLOW_MAX_SPEED
	hud_panel.follow_deadzone_deg = HUD_FOLLOW_DEADZONE_DEG
	hud_panel.desktop_fit = false
	hud_panel.desktop_scale = 0.6
	hud_panel.desktop_layer = 5
	hud_panel.render_priority = 9
	add_child(hud_panel)
	hud = HUD.new()
	hud.name = "HUD"
	hud_panel.content.add_child(hud)
	hud.panel = hud_panel
	hud.sync_bands()

	for id: StringName in SCREEN_IDS:
		var s := _make_screen(id)
		s.name = String(id).capitalize().replace(" ", "")
		s.visible = false
		menu_panel.content.add_child(s)
		s.ensure_built()
		s.action.connect(_on_action.bind(id))
		screens[id] = s

	indicators = HudIndicators.new()
	indicators.name = "Indicators"
	add_child(indicators)
	pointer = UIPointer.new()
	pointer.name = "Pointer"
	add_child(pointer)
	pointer.panels = [menu_panel]
	pointer.set_preferred_hand(str(Settings.get_value("handedness", "right")))

	onboarding = Onboarding.new()
	onboarding.name = "Onboarding"
	onboarding.progress_store = progress
	add_child(onboarding)
	onboarding.lesson_started.connect(func(i: int, l: Dictionary) -> void:
		hud.show_lesson(i, Onboarding.LESSONS.size(), l)
		_hud_make_way_now())
	onboarding.lesson_changed.connect(func(_i: int, l: Dictionary) -> void: hud.update_lesson(l))
	# The catch lesson and the game's lesson prey (GameLoop's lesson-prey
	# API, duck-typed and optional: GameBridge).
	onboarding.catch_lesson.connect(_on_catch_lesson)
	onboarding.catch_help.connect(func(level: int) -> void: bridge.lesson_prey_help(level))
	onboarding.help_ok = _lesson_help_ok
	onboarding.lesson_progress.connect(func(_i: int, p: float) -> void: hud.set_lesson_progress(p))
	onboarding.lesson_completed.connect(func(_i: int, _id: StringName, t: bool) -> void: hud.lesson_done(t))
	onboarding.finished.connect(func(_skipped: bool) -> void: hud.hide_lesson())

	Events.game_state_changed.connect(_on_state_changed)
	Events.menu_requested.connect(_on_menu_requested)
	Events.run_started.connect(_on_run_started)
	Events.run_ended.connect(_on_run_ended)
	Events.player_caught.connect(_on_player_caught)
	Events.player_tier_changed.connect(_on_tier_changed)
	Events.target_changed.connect(_on_target_changed)
	Events.threat_changed.connect(_on_threat_changed)
	Events.player_flapped.connect(func(side: int, strength: float) -> void: onboarding.notify_flap(side, strength))
	Events.bird_caught.connect(func(pred: Bird, prey: Bird) -> void: onboarding.notify_catch(pred, prey))
	Events.settings_changed.connect(_on_settings_changed)
	# After a recenter the old "in front" is meaningless: re-place at once.
	VR.recentered.connect(_on_recentered)
	# Taking the headset off or opening the system menu must not leave the
	# run going unseen (and store checks require the app to pause).
	VR.session_unfocused.connect(_on_session_unfocused)
	# VR area addition (calibration redesign): the pause screen offers "New
	# player? Recalibrate wings" while VR suggests it (duck-typed).
	if VR.has_signal(&"recalibration_suggested_changed"):
		VR.connect(&"recalibration_suggested_changed", func(_on: bool) -> void:
			if current_screen_id() == &"pause":
				refresh_current())

	set_vr_mode(vr_mode)
	_try_attach_rig()
	_connect_game_loop()
	_sync_to_state()
	refresh_tonemap.call_deferred()
	print("[ui] ready (%s)" % ("vr" if vr_mode else "desktop"))


static func _make_screen(id: StringName) -> UIScreen:
	match id:
		&"main":
			return MainMenuScreen.new()
		&"pause":
			return PauseScreen.new()
		&"settings":
			return SettingsScreen.new()
		&"howto":
			return HowToScreen.new()
		&"caught":
			return CaughtScreen.new()
		&"summary":
			return SummaryScreen.new()
	return UIScreen.new()


# --- modes and rig ------------------------------------------------------------

func set_vr_mode(on: bool) -> void:
	vr_mode = on
	menu_panel.set_vr_mode(on)
	hud_panel.set_vr_mode(on)
	hud.set_vr(on)
	if screens.has(&"howto"):
		(screens[&"howto"] as HowToScreen).set_desktop(not on)
	indicators.set_vr_mode(on)
	_update_pointer()


## Use this XROrigin3D (or any Node3D) as the player's rig: panels are placed
## in its space, the camera is its XRCamera3D, and in VR the laser pointers
## come from its controllers' aim poses.
## Idempotent: attaching the same rig again keeps its aim controllers, and a
## new rig's controllers replace (and free) the old ones.
func attach_rig(r: Node3D, cam: Node3D = null) -> void:
	rig = r
	camera = cam if cam else _find_camera(r)
	for p: UIPanel in [menu_panel, hud_panel]:
		p.rig = rig
		p.camera = camera
	indicators.rig = rig
	indicators.camera = camera
	if vr_mode and not _custom_sources and rig and (rig != _aim_rig or not _xr_sources_alive()):
		_aim_rig = rig
		pointer.set_sources(UIXRPointerSource.new(&"left_hand", rig), UIXRPointerSource.new(&"right_hand", rig))
	if menu_panel.shown:
		menu_panel.snap_to_head()
	if hud_panel.shown:
		hud_panel.snap_to_head()


## Tests and the dev scene drive the pointer with scripted sources.
func set_pointer_sources(left: UIPointerSource, right: UIPointerSource) -> void:
	_custom_sources = true
	_aim_rig = null
	pointer.set_sources(left, right)
	pointer.set_preferred_hand(str(Settings.get_value("handedness", "right")))


func _xr_sources_alive() -> bool:
	if pointer.sources.size() != 2:
		return false
	for src in pointer.sources:
		if not (src is UIXRPointerSource and is_instance_valid((src as UIXRPointerSource).controller)):
			return false
	return true


func _exit_tree() -> void:
	# The aim controllers live under the player's rig, not under the UI:
	# take them along when the UI goes.
	if pointer:
		pointer.set_sources_released()


func _find_camera(r: Node) -> Node3D:
	if r == null:
		return get_viewport().get_camera_3d()
	for c in r.get_children():
		if c is XRCamera3D:
			return c
	for c in r.get_children():
		if c is Camera3D:
			return c
	return get_viewport().get_camera_3d()


func _try_attach_rig() -> void:
	if rig and is_instance_valid(rig):
		return
	var r := get_tree().get_first_node_in_group(&"player_rig") as Node3D
	if r:
		attach_rig(r)
	elif camera == null:
		# Desktop dev scenes without a rig: cues follow the active camera.
		camera = get_viewport().get_camera_3d()
		indicators.camera = camera


## Match the panels' colour compensation to the Environment the world is
## rendered with (cheap when nothing changed; re-checked every second).
func refresh_tonemap() -> void:
	var p := UITonemap.params(UITonemap.active_environment(get_viewport()))
	menu_panel.set_tonemap(p)
	hud_panel.set_tonemap(p)
	pointer.set_tonemap(p)
	indicators.set_tonemap(p)


func world_scale() -> float:
	return (rig as XROrigin3D).world_scale if rig is XROrigin3D else 1.0


## Yaw of where the player's body faces in rig space (radians, 0 = the
## rig's -Z, + = left: UIPanel.head_yaw's convention): the HUD's centre
## line. A head at rest looks this way, so that is where the notices must
## be in view.
##  - PlayerBird reports it: telemetry "body_yaw" (WingInput's torso yaw in
##    tracking space, the rig's own frame: the perpendicular to the line
##    between the hands, the head's yaw when the hands say little). It is
##    steady through everything flight does to the view: a flown turn yaws
##    the whole rig, a loop over the top reverses the bird's heading (and
##    Bird.get_forward()) while the view turns round at its comfort rate,
##    and wind makes the flight path crab tens of degrees off where the bird
##    faces (a sparrow at 5 m/s in the valley's 2.6 m/s breeze: up to 31).
##    The round-5 HUD anchored to the flight path's heading and swung round
##    the player in exactly those cases (the round-6 verifier: 157 deg in a
##    zoom over the top, the lesson card in view 39 % of the tutorial).
##  - A player bird without it: where the bird faces (Bird.get_forward(),
##    world -> rig), held while it points steeper than BODY_STEEP_DEG.
##  - NAN without a player bird (the HUD then follows the head).
func body_yaw() -> float:
	var p := Birds.player()
	if p == null or not is_instance_valid(p):
		_facing_yaw = NAN
		return NAN
	if p.has_method(&"telemetry"):
		var tel: Variant = p.call(&"telemetry")
		if tel is Dictionary and (tel as Dictionary).has("body_yaw"):
			var v: Variant = (tel as Dictionary)["body_yaw"]
			if (v is float or v is int) and is_finite(float(v)):
				return wrapf(float(v), -PI, PI)
	var f := _to_rig(p.get_forward())
	if f.length() > 1e-6 and absf(f.normalized().y) < sin(deg_to_rad(BODY_STEEP_DEG)):
		_facing_yaw = atan2(-f.x, -f.z)
	return _facing_yaw


## Heading of the flight path in rig space (radians, same convention as
## body_yaw): the player's horizontal velocity, or NAN while it is slower
## than 0.3 m/s x world_scale (hovering, perched) or there is no player.
## Not the HUD's centre line (see body_yaw): the notices keep clear of the
## flight path itself (hud_protected_directions).
func flight_yaw() -> float:
	var p := Birds.player()
	if p == null or not is_instance_valid(p):
		return NAN
	var d := _to_rig(Vector3(p.velocity.x, 0.0, p.velocity.z))
	if Vector2(d.x, d.z).length() < 0.3 * world_scale():
		return NAN
	return atan2(-d.x, -d.z)


## A world direction in the rig's frame (the rig yaws with every flown turn:
## PlayerBird is the XROrigin3D's parent).
func _to_rig(d: Vector3) -> Vector3:
	if rig and is_instance_valid(rig) and rig.is_inside_tree():
		return rig.global_basis.orthonormalized().inverse() * d
	return d


# --- screens ------------------------------------------------------------------

func current_screen_id() -> StringName:
	return stack[-1] if not stack.is_empty() else &""


func current_screen() -> UIScreen:
	return screens.get(current_screen_id())


func get_screen(id: StringName) -> UIScreen:
	return screens.get(id)


func is_menu_open() -> bool:
	return not stack.is_empty()


func push_screen(id: StringName) -> void:
	stack.append(id)
	_show_top()


func pop_screen() -> void:
	if stack.size() > 1:
		stack.pop_back()
		_show_top()


func _set_root(id: StringName) -> void:
	stack.clear()
	if id != &"":
		stack.append(id)
	_show_top()


func _show_top() -> void:
	var top := current_screen_id()
	for id in screens:
		(screens[id] as UIScreen).visible = id == top
	if top != _shown_top:
		_shown_top = top
		# A new screen: a trigger already squeezed must be let go first.
		pointer.rearm()
	if top == &"":
		menu_panel.hide_panel()
	else:
		var s: UIScreen = screens[top]
		s.refresh(context())
		menu_panel.show_panel(not menu_panel.shown)
		if not vr_mode and s.interactive:
			var f := s.first_focus()
			if f:
				f.grab_focus()
	_update_pointer()
	_update_mouse()


## Drop any sub-screens and show the screen the current Game state implies.
func show_state_screen() -> void:
	_sync_to_state()


func refresh_current() -> void:
	var s := current_screen()
	if s:
		s.refresh(context())


## Everything screens may show. Keys: player_mass, stats (GameLoop run stats),
## run_time, tutorial_active, best_score, summary, new_best, predator_name,
## predator_species, respawn_in, recalibrate_suggested (VR area addition:
## VR.recalibration_suggested, read duck-typed).
func context() -> Dictionary:
	var stats := bridge.run_stats()
	var p := Birds.player()
	var best := maxi(progress.best_score(), int(stats.get("best_score", 0)))
	if not _summary.is_empty():
		# The summary's Best must agree with its "New best!" badge.
		best = _summary_best
	return {
		"player_mass": p.mass if p else float(stats.get("mass", SizeRules.SPECIES[2]["mass"])),
		"stats": stats,
		"run_time": Game.run_time,
		"tutorial_active": onboarding.active,
		"best_score": best,
		"summary": _summary if not _summary.is_empty() else stats,
		"new_best": _new_best,
		"predator_name": _predator_name,
		"predator_species": _predator_species,
		"respawn_in": _respawn_in(stats),
		"recalibrate_suggested": recalibration_suggested(),
	}


## VR's "the headset may be on someone new" (VR area addition, calibration
## redesign): VR.recalibration_suggested, duck-typed (false without it).
func recalibration_suggested() -> bool:
	var v: Variant = VR.get(&"recalibration_suggested")
	return v is bool and v


func _respawn_in(stats: Dictionary) -> float:
	if stats.has("respawn_in"):
		return float(stats["respawn_in"])
	return _caught_left


func _update_pointer() -> void:
	var s := current_screen()
	var on := vr_mode and s != null and s.interactive
	pointer.set_enabled(on)
	pointer.world_scale = world_scale()


func _update_mouse() -> void:
	if vr_mode:
		return
	var s := current_screen()
	if s != null and s.interactive:
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			_saved_mouse_mode = Input.mouse_mode
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _saved_mouse_mode >= 0:
		Input.mouse_mode = _saved_mouse_mode as Input.MouseMode
		_saved_mouse_mode = -1


# --- game flow ------------------------------------------------------------------

func _sync_to_state() -> void:
	match Game.state:
		Game.State.BOOT, Game.State.MENU:
			_set_root(&"main")
		Game.State.PLAYING:
			_set_root(&"")
		Game.State.PAUSED:
			_set_root(&"pause")
		Game.State.CAUGHT:
			_set_root(&"caught")
		Game.State.ENDED:
			_set_root(&"summary")
	var playing := Game.state == Game.State.PLAYING
	if playing:
		_refresh_apex()
		hud_panel.show_panel()
		hud.sync_bands()
		var p := Birds.player()
		if p:
			hud.set_growth(p.mass)
		_hud_make_way_now()
	else:
		# A pause keeps a celebration (its clock waits while the HUD is
		# hidden, and it goes on after Resume: the round-7 verifier's pause
		# 0.5 s into a tier-up lost it); being caught, a menu or the run's
		# end is the moment over, and it must not replay into the next flight.
		if Game.state != Game.State.PAUSED:
			hud.cancel_toast()
		hud_panel.hide_panel()
	indicators.set_active(playing)
	if playing:
		onboarding.start()


func _on_state_changed(new_state: int, old_state: int) -> void:
	if new_state == Game.State.PAUSED:
		_resume_state = old_state if old_state == Game.State.CAUGHT else Game.State.PLAYING
		(screens[&"pause"] as PauseScreen).next_tip()
	if new_state == Game.State.CAUGHT and old_state != Game.State.PAUSED:
		_caught_left = respawn_delay
	if new_state == Game.State.MENU or (new_state == Game.State.PLAYING and old_state == Game.State.ENDED):
		# Back to the menu, or a victory lap: the summary is done.
		_summary = {}
		_new_best = false
	if new_state == Game.State.MENU or new_state == Game.State.ENDED:
		# The run is over: its lesson prey go (the next run asks again).
		_lesson_prey(false)
	_sync_to_state()


func _on_menu_requested() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_menu_ms < MENU_DEBOUNCE_MS:
		return
	_last_menu_ms = now
	match Game.state:
		Game.State.PLAYING, Game.State.CAUGHT:
			Game.set_state(Game.State.PAUSED)
		Game.State.PAUSED:
			resume()
		Game.State.MENU:
			_set_root(&"main")
		Game.State.BOOT, Game.State.ENDED:
			Game.set_state(Game.State.MENU)


func resume() -> void:
	if Game.state == Game.State.PAUSED:
		Game.set_state(_resume_state as Game.State)


func _on_action(action_id: StringName, _screen_id: StringName) -> void:
	match action_id:
		&"play", &"again":
			bridge.start_run()
		&"howto":
			push_screen(&"howto")
		&"settings":
			push_screen(&"settings")
		&"back":
			pop_screen()
		&"quit":
			print("[ui] quit")
			quit_handler.call()
		&"resume":
			resume()
		&"restart":
			pointer.pulse(0.6, 0.06)
			bridge.restart_run()
		&"quit_menu":
			pointer.pulse(0.6, 0.06)
			bridge.quit_to_menu()
		&"menu":
			bridge.quit_to_menu()
		&"keep_flying":
			bridge.continue_after_victory()
		&"skip_tutorial":
			onboarding.skip()
			refresh_current()
		&"recalibrate":
			recalibrate_requested.emit()
			_settings_status(SettingsScreen.STATUS_RECALIBRATE)
		&"recenter":
			Events.recenter_requested.emit()
			_settings_status(SettingsScreen.STATUS_RECENTER)
		&"replay_tutorial":
			onboarding.reset()
			_settings_status(SettingsScreen.STATUS_REPLAY)


func _on_run_started() -> void:
	_summary = {}
	_new_best = false
	# A new run while the catch lesson is taught: the new sky needs its
	# lesson prey too.
	if onboarding.teaching_catch():
		_lesson_prey(true)


## The catch lesson: how near the nearest lesson bird is, and how fast the
## player gains on it (for _lesson_help_ok).
func _track_lesson_prey(p: Bird, delta: float) -> void:
	if p == null or delta <= 0.0 or not onboarding.teaching_catch():
		_prey_d = INF
		_prey_closing = 0.0
		return
	var d := INF
	var pp := p.get_body_position()
	for b: Variant in bridge.lesson_prey_birds():
		if b is Bird and is_instance_valid(b) and (b as Bird).alive:
			d = minf(d, (b as Bird).get_body_position().distance_to(pp))
	if is_finite(d) and is_finite(_prey_d):
		_prey_closing += ((_prey_d - d) / delta - _prey_closing) * (1.0 - exp(-delta / 0.3))
	else:
		_prey_closing = 0.0
	_prey_d = d


## Help may come now: the player is not closing on a lesson bird.
func _lesson_help_ok() -> bool:
	var p := Birds.player()
	var span := p.get_wingspan() if p else SizeRules.wingspan_for_mass(SizeRules.SPECIES[2]["mass"])
	return not (_prey_d < LESSON_CLOSING_SPANS * span and _prey_closing > LESSON_CLOSING_SPS * span)


## The catch lesson began (ask the game for its lesson prey: the lesson's
## words name them) or ended (by a catch, its timeout, a skip or a reset).
func _on_catch_lesson(on: bool) -> void:
	_lesson_prey(on)


## Ask GameLoop for the catch lesson's prey, or let them go: once per run
## and lesson (a run's start and the lesson's may come in either order).
func _lesson_prey(on: bool) -> void:
	if on == _prey_asked:
		return
	_prey_asked = on
	if on:
		onboarding.set_catch_prey(bridge.lesson_prey_start())
	else:
		bridge.lesson_prey_stop()
		onboarding.set_catch_prey({})


func _settings_status(text: String) -> void:
	(screens[&"settings"] as SettingsScreen).show_status(text)


func _on_run_ended(summary: Dictionary) -> void:
	_summary = summary
	var prior_ui := progress.best_score()
	var score := int(summary.get("score", 0))
	# Keep the fallback record even when a GameLoop keeps its own.
	progress.submit_score(score)
	var r := summary_best(summary, bridge.run_stats(), prior_ui)
	_new_best = r["new_best"]
	_summary_best = r["best"]
	if current_screen_id() == &"summary":
		refresh_current()


## "New best!" and the Best shown beside it, decided together so they can
## never disagree. GameLoop keeps the authoritative records (it also counts
## runs quit to the menu, which never reach this screen): when the summary
## carries them (new_records.score, records.best_score) they win. Without a
## GameLoop, UIProgress's own file (`prior_ui`, read before this run) is the
## record. Pure, so tests pin every combination.
static func summary_best(summary: Dictionary, stats: Dictionary, prior_ui: int) -> Dictionary:
	var score := int(summary.get("score", 0))
	var records: Variant = summary.get("records")
	var flags: Variant = summary.get("new_records")
	if flags is Dictionary and (flags as Dictionary).has("score"):
		var nb := bool(flags["score"])
		var rec_best := int((records as Dictionary).get("best_score", 0)) if records is Dictionary else int(stats.get("best_score", 0))
		# A new record is this score; otherwise the record stands above it.
		return {"new_best": nb, "best": score if nb else maxi(rec_best, score)}
	var prior := maxi(prior_ui, int(stats.get("best_score", 0)))
	if records is Dictionary:
		prior = maxi(prior, int((records as Dictionary).get("best_score", 0)))
	var nb2 := score > 0 and score > prior
	return {"new_best": nb2, "best": maxi(prior, score)}


func _on_player_caught(predator: Bird) -> void:
	_predator_name = UIScreen.species_name(predator.species) if is_instance_valid(predator) else ""
	_predator_species = predator.species if is_instance_valid(predator) else &""
	if current_screen_id() == &"caught":
		refresh_current()


func _on_tier_changed(old_tier: int, new_tier: int) -> void:
	var p := Birds.player()
	_refresh_apex()
	# (No keep-alive: the celebration's burst redraws every frame it
	# animates, and that books the render; while its clock is held nothing
	# changes, so nothing renders.)
	hud.show_tier_up(old_tier, new_tier, p.mass if p else -1.0)
	_hud_make_way_now()


## Place newly shown notices clear of what matters before they are first
## drawn (make_way places a new set of plates where it is clear, at once).
func _hud_make_way_now() -> void:
	if vr_mode and hud_panel.shown and Game.state == Game.State.PLAYING:
		hud.make_way(hud_protected_directions(), 0.0)


# --- GameLoop's apex goal ---------------------------------------------------------

## Connect GameLoop's apex signals (duck-typed; it may be added after the
## UI, so _process retries). The goal itself is read from its run stats.
func _connect_game_loop() -> void:
	var gl := bridge.game_loop_node()
	if gl == _loop:
		return
	_loop = gl
	if gl == null:
		return
	if gl.has_signal(&"apex_progress") and not gl.is_connected(&"apex_progress", _on_apex_progress):
		gl.connect(&"apex_progress", _on_apex_progress)
	if gl.has_signal(&"apex_reached") and not gl.is_connected(&"apex_reached", _refresh_apex):
		gl.connect(&"apex_reached", _refresh_apex)


func _refresh_apex() -> void:
	hud.set_apex(PauseScreen.apex_goal(bridge.run_stats()))
	var p := Birds.player()
	if p:
		hud.set_growth(p.mass)


func _on_apex_progress(catches: int, needed: int) -> void:
	_refresh_apex()
	if hud.apex_goal().is_empty():
		# A GameLoop without an apex block in its stats: use the signal.
		hud.set_apex({"catches": catches, "needed": needed, "won": catches >= needed})
	if Game.state == Game.State.PLAYING and catches < needed:
		hud.show_apex_progress(catches, needed)
		_hud_make_way_now()


## The bird last named may have been freed since (a despawn before the next
## event): the new one is taken first, the old one is untinted only if it
## still exists, so one freed bird can never stop the cues updating.
func _on_target_changed(prey: Bird) -> void:
	var old: Variant = _target
	_target = prey
	if is_instance_valid(old) and old != prey:
		_highlight(old, 0)
	_highlight(prey, 1)
	indicators.set_target(prey)


func _on_threat_changed(level: float, predator: Bird) -> void:
	_threat_level = level
	var old: Variant = _threat
	_threat = predator
	if is_instance_valid(old) and old != predator:
		_highlight(old, 0)
	_highlight(predator, 2 if is_real_threat(level) else 0)
	indicators.set_threat(predator, level)


static func is_real_threat(level: float) -> bool:
	return level >= REAL_THREAT


## Duck-typed (any `model` with a `highlight` property), so the UI does not
## depend on the birds area's scripts compiling. Untyped: a freed bird is
## simply skipped (a typed parameter would raise on it).
func _highlight(b: Variant, v: int) -> void:
	if not highlight_birds or not is_instance_valid(b):
		return
	var m: Variant = (b as Object).get(&"model")
	if m is Object and is_instance_valid(m) and &"highlight" in (m as Object):
		(m as Object).set(&"highlight", v)


func _on_session_unfocused() -> void:
	if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
		print("[ui] headset lost focus: pausing")
		Game.set_state(Game.State.PAUSED)


func _on_recentered() -> void:
	for p: UIPanel in [menu_panel, hud_panel]:
		if p.shown:
			p.snap_to_head()


func _on_settings_changed(key: String, value: Variant) -> void:
	if key == "handedness":
		pointer.set_preferred_hand(str(value))


# --- per frame ----------------------------------------------------------------

func _process(delta: float) -> void:
	_rig_retry -= delta
	if _rig_retry <= 0.0:
		_rig_retry = 1.0
		_connect_game_loop()
		if rig == null or not is_instance_valid(rig):
			rig = null
			_try_attach_rig()
	pointer.world_scale = world_scale()
	_tonemap_check -= delta
	if _tonemap_check <= 0.0 and vr_mode:
		_tonemap_check = 1.0
		refresh_tonemap()
	_poll_buttons()
	if Game.state == Game.State.PLAYING:
		var p := Birds.player()
		if p:
			hud.set_growth(p.mass)
		_track_lesson_prey(p, delta)
		if vr_mode and hud_panel.shown:
			hud.make_way(hud_protected_directions(), delta)
	elif Game.state == Game.State.CAUGHT:
		_caught_left -= delta
		if current_screen_id() == &"caught":
			var stats := bridge.run_stats()
			(screens[&"caught"] as CaughtScreen).set_countdown(_respawn_in(stats), int(stats.get("lives", -1)))


## World directions (from the eye) the HUD must never hide: the flight
## path (the view does not pitch, so a climb or dive moves it far above or
## below the horizon, and wind or a loop moves it far off the centre line
## to either side), the current target, a real threat, and the cue
## chevrons pointing at them (they also draw on top of the HUD, but a
## notice must not sit under a cue for long either). The cues turn with the
## head: while it points at the notices (the player is reading them) they
## sweep over the notices and are not counted, or the notices would fade
## exactly when read.
func hud_protected_directions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	protected_labels.clear()
	var eye := camera.global_position if camera and camera.is_inside_tree() else Vector3.ZERO
	var p := Birds.player()
	if p and p.velocity.length() > 1.5 * world_scale():
		out.append(p.velocity.normalized())
		protected_labels.append("path")
	if is_instance_valid(_target) and _target.is_inside_tree():
		out.append((_target.get_body_position() - eye).normalized())
		protected_labels.append("target")
	if is_instance_valid(_threat) and _threat.is_inside_tree() and is_real_threat(_threat_level):
		out.append((_threat.get_body_position() - eye).normalized())
		protected_labels.append("threat")
	var reading := camera != null and camera.is_inside_tree() and hud.looks_at_notices(-camera.global_basis.z)
	for which: StringName in [&"target", &"threat"]:
		# Where the chevron is drawn from the eye as it is now (not the
		# mesh's last position: see HudIndicators.cue_direction).
		var d := indicators.cue_direction(which)
		if d != Vector3.ZERO and not reading:
			out.append(d)
			protected_labels.append("%s cue" % which)
	return out


## What the notices made way for at the last frame (diagnostics, probes):
## the labels of hud_protected_directions() that were on the notice plates.
func notice_causes() -> PackedStringArray:
	var out := PackedStringArray()
	for i in hud.last_on:
		if i < protected_labels.size():
			out.append(protected_labels[i])
	return out


## Controller menu buttons (on Quest only the left controller has one; the
## right's system button is reserved) and B/Y = back inside menus.
func _poll_buttons() -> void:
	for src in pointer.sources:
		var key := String(src.hand)
		var m := src.menu_pressed()
		if m and not _button_prev.get(key + ":menu", false):
			Events.menu_requested.emit()
		_button_prev[key + ":menu"] = m
		var b := src.back_pressed()
		if b and not _button_prev.get(key + ":back", false) and is_menu_open():
			if stack.size() > 1:
				pop_screen()
		_button_prev[key + ":back"] = b


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Events.menu_requested.emit()
		get_viewport().set_input_as_handled()


## Number of SubViewports allowed to render this frame (U7: never above 2).
func active_viewport_count() -> int:
	var n := 0
	for p: UIPanel in [menu_panel, hud_panel]:
		if p.is_rendering_enabled():
			n += 1
	return n
