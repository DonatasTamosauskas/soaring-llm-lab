class_name VRManager
extends Node
## OpenXR lifecycle (autoload "VR"). Owned by the VR area; see
## docs/ARCHITECTURE.md and docs/areas/VR.md.
##
## - Starts XR when a runtime is present (headset or the Meta XR Simulator),
##   otherwise the game runs in desktop mode (`active` false) and every XR call
##   here is skipped.
## - Session lifecycle: `session_state` follows begun -> synchronized ->
##   visible -> focused -> stopping. Losing focus (system menu, headset off:
##   session_visible or user_presence_changed(false)) pauses the game through
##   Events.menu_requested (the UI then shows the pause menu); regaining focus
##   leaves the game paused so the player resumes deliberately.
## - Refresh policy: Settings "vr_refresh_rate" (0 = auto: 72 Hz, on the
##   Quest and in the simulator alike, until profiled on the device). Physics ticks always equal the display
##   rate (re-applied on refresh_rate_changed) so flight integrates once per
##   displayed frame; CPU/GPU perf levels are set to sustained-high.
## - Foveation: fixed foveated rendering (level from Settings
##   "vr_foveation_level", dynamic), with the main viewport's VRS mode set to
##   XR (without it the Mobile renderer ignores foveation).
## - Recenter: Events.recenter_requested and the runtime's pose_recentered
##   both call XRServer.center_on_hmd(RESET_BUT_KEEP_TILT, keep height) and
##   emit `recentered` once.
## - Services for every scene: `haptics` (VRHaptics) and `controls`
##   (VRControls: menu button, long presses, trigger/grip).
##
## Command-line user args (after "--"):
##   --autoquit=<sec>  quit cleanly after <sec> seconds (simulator runs)
##   --xrdiag          print session state, fps and poses each second
##   --refresh=<hz>    override the refresh-rate setting for this run

signal session_focused()
signal session_unfocused()
signal session_stopping()
signal recentered()
signal session_state_changed(state: String)
signal refresh_rate_changed(hz: float)
signal user_presence_changed(present: bool)
## The player asked to redo the wing calibration (Y-hold); VRCalibration
## listens (UIRoot.recalibrate_requested is the menu route).
signal recalibrate_requested()
## recalibration_suggested changed (the UI's pause menu shows or hides its
## "New player? Recalibrate wings" button).
signal recalibration_suggested_changed(on: bool)
## The runtime is ending the app (session loss pending, instance exiting):
## emitted just before the quit.
signal quitting(reason: String)

## Auto refresh: 72 Hz everywhere, the Quest Pro default until OVR Metrics
## shows headroom for 90 on the device. The simulator runs the same rate
## the game ships with (90 Hz there only measured this shared Mac's load:
## the fps shortfall was identical with every VR feature off). 90 Hz stays
## one setting away (vr_refresh_rate = 90, or --refresh=90).
const REFRESH_AUTO := 72.0
## Never choose below this (the simulator also offers 30 and 60 Hz).
const REFRESH_MIN := 72.0

var xr: OpenXRInterface = null
## What drives the session: the object whose signals the handlers are
## connected to and whose refresh / perf-level calls they make. OpenXR's
## interface in the game; tests connect a stand-in with the same signals
## and methods (connect_interface) so the wiring itself is exercised (fix
## round 5: deleting a connect line, or the refresh policy at session start,
## passed every test).
var runtime: Object = null
## True when frames go to a headset (or the simulator), false on desktop.
var active := false
## The player can play right now: the session has input focus AND someone
## wears the headset (fix round 4: it stayed true after the headset came
## off until the runtime also reported session_visible).
var focused := false
var session_state := "none"
var user_present := true
## The runtime reports the headset coming off and going back on
## (XR_EXT_user_presence: user_presence_changed): the interface says so,
## or a presence event arrived. Without it a removal only shows as lost
## focus (VRCalibration then counts a long loss of focus as a possible new
## player).
var presence_supported := false
## The headset may be on someone new (it came off and back on, focus was
## lost for a long time, or the app started with a saved calibration):
## the pause menu offers "New player? Recalibrate wings". Only a hint for
## the UI (read duck-typed): nothing is ever recalibrated because of it.
## Raised by VRCalibration, cleared by a completed calibration.
var recalibration_suggested := false
## Display refresh rate in Hz once the session runs (0 before / desktop).
var refresh_rate := 0.0
## Pause the game on focus loss (tests may turn it off).
var pause_on_focus_loss := true
## Quit when the runtime ends the session (tests turn it off).
var quit_on_session_end := true
## Counters for the simulator harness and tests.
var focus_losses := 0
var recenter_count := 0
## apply_refresh_policy() runs (the harness checks the policy ran at
## session start: at 72 Hz the physics tick matches the display either way).
var refresh_policy_runs := 0
## Perf-level notifications received from the runtime.
var perf_notifications := 0

var haptics: VRHaptics
var controls: VRControls

var _autoquit := -1.0
var _diag := false
var _diag_t := 0.0
var _elapsed := 0.0
var _refresh_override := 0.0
var _frames := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := Paths.user_args()
	_autoquit = float(args.get("autoquit", "-1"))
	_diag = args.has("xrdiag")
	_refresh_override = float(args.get("refresh", "0"))

	haptics = VRHaptics.new()
	haptics.name = "Haptics"
	add_child(haptics)
	controls = VRControls.new()
	controls.name = "Controls"
	add_child(controls)
	controls.recalibrate_requested.connect(func() -> void: recalibrate_requested.emit())
	Events.recenter_requested.connect(recenter)
	Events.settings_changed.connect(_on_settings_changed)

	xr = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr and xr.is_initialized():
		active = true
		get_viewport().use_xr = true
		# Physics object picking (on by default in the project settings)
		# cannot work in stereo: the engine switches it off itself with a
		# warning the first time a mouse event reaches the desktop mirror
		# window (fix round 5: a simulator run caught it when the pointer
		# crossed the window). Off from the start, silently.
		get_viewport().physics_object_picking = false
		# The compositor paces frames; vsync on the desktop mirror would halve them.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		connect_interface(xr)
		apply_foveation()
		print("[vr] OpenXR initialised: ", xr.get_system_info())
	else:
		xr = null
		print("[vr] no OpenXR runtime; desktop mode")


## The runtime's signals and the handler each one drives (OpenXRInterface
## names; session_focussed is its spelling).
func _session_wiring() -> Array:
	return [
		[&"session_begun", _on_session_begun],
		[&"session_synchronized", _on_session_synchronized],
		[&"session_visible", _on_session_visible],
		[&"session_focussed", _on_session_focused],
		[&"session_stopping", _on_session_stopping],
		[&"session_loss_pending", _on_session_loss_pending],
		[&"instance_exiting", _on_instance_exiting],
		[&"pose_recentered", _on_pose_recentered],
		[&"refresh_rate_changed", _on_refresh_rate_changed],
		[&"user_presence_changed", _on_user_presence_changed],
		[&"cpu_level_changed", _on_cpu_level_changed],
		[&"gpu_level_changed", _on_gpu_level_changed],
	]


## Connects the session handlers to `source`'s signals and makes it the
## runtime the policies talk to (OpenXR's interface; a stand-in in tests).
func connect_interface(source: Object) -> void:
	disconnect_interface()
	runtime = source
	for w in _session_wiring():
		if source.has_signal(w[0]) and not source.is_connected(w[0], w[1]):
			source.connect(w[0], w[1])
	_query_presence_support()


## OpenXRInterface.is_user_presence_supported(): the extension is enabled
## (project setting xr/openxr/extensions/user_presence) and the runtime
## has it. Asked when connected and again when the session begins (the
## runtime's system properties are known by then).
func _query_presence_support() -> void:
	if runtime != null and runtime.has_method(&"is_user_presence_supported"):
		presence_supported = presence_supported or bool(runtime.call(&"is_user_presence_supported"))


func disconnect_interface() -> void:
	if runtime != null and is_instance_valid(runtime):
		for w in _session_wiring():
			if runtime.has_signal(w[0]) and runtime.is_connected(w[0], w[1]):
				runtime.disconnect(w[0], w[1])
	runtime = null


# =============================================================================
# Policies (pure where possible, so tests can pin them)
# =============================================================================

## The refresh rate to ask for, from the runtime's list. requested <= 0 means
## auto: 72 Hz (Quest: the safe default until OVR Metrics shows headroom
## for 90, docs/research/QUEST.md §1.2; the simulator runs what ships).
## Picks the highest available rate <= the target and never goes below
## 72 Hz if it can help it.
static func choose_refresh_rate(available: Array, requested: float) -> float:
	if available.is_empty():
		return 0.0
	var target := requested if requested > 0.0 else REFRESH_AUTO
	target = maxf(target, REFRESH_MIN)
	var best := -1.0
	var lowest_ok := INF
	for r in available:
		var hz := float(r)
		if hz <= target + 0.5 and hz > best and hz >= REFRESH_MIN - 0.5:
			best = hz
		if hz >= REFRESH_MIN - 0.5:
			lowest_ok = minf(lowest_ok, hz)
	if best > 0.0:
		return best
	if lowest_ok < INF:
		return lowest_ok
	var top := 0.0
	for r in available:
		top = maxf(top, float(r))
	return top


## Physics ticks = display refresh, so the rig moves exactly once per frame
## (XROrigin3D pushes its transform to XRServer on every change and XR nodes
## never interpolate; a 72 Hz tick on a 90 Hz display judders the world).
static func apply_physics_tick(hz: float) -> int:
	var ticks := roundi(hz) if hz > 1.0 else 72
	Engine.physics_ticks_per_second = ticks
	Engine.max_fps = 0
	return ticks


func requested_refresh() -> float:
	if _refresh_override > 0.0:
		return _refresh_override
	return float(Settings.get_value("vr_refresh_rate", 0.0))


func apply_refresh_policy() -> void:
	if runtime == null:
		return
	refresh_policy_runs += 1
	var rates: Array = runtime.call(&"get_available_display_refresh_rates")
	var want := choose_refresh_rate(rates, requested_refresh())
	var now := float(runtime.get(&"display_refresh_rate"))
	if want > 0.0 and absf(now - want) > 0.5:
		runtime.set(&"display_refresh_rate", want)
	# The runtime may apply the change a frame later; refresh_rate_changed
	# re-applies the tick then.
	var hz := want if want > 0.0 else now
	refresh_rate = hz if hz > 1.0 else 72.0
	var ticks := apply_physics_tick(refresh_rate)
	print("[vr] refresh rates %s requested %.0f -> %.0f Hz, physics %d Hz" % [rates, requested_refresh(), refresh_rate, ticks])


## The main viewport's VRS mode for a foveation level: without VRS_XR the
## Mobile renderer never uses the runtime's density map (QUEST.md §0.2), so
## foveation would silently do nothing.
static func vrs_mode_for(level: int) -> Viewport.VRSMode:
	return Viewport.VRS_XR if level > 0 else Viewport.VRS_DISABLED


func apply_foveation() -> void:
	if xr == null:
		return
	var level := clampi(int(Settings.get_value("vr_foveation_level", 3)), 0, 3)
	# Subsampled images: open Godot bug #123406 renders wrong at high
	# foveation (QUEST.md §1.1); keep off until A/B tested on the Quest Pro.
	xr.foveation_with_subsampled_images = false
	if xr.is_foveation_supported():
		xr.foveation_level = level
		xr.foveation_dynamic = bool(Settings.get_value("vr_foveation_dynamic", true))
	get_viewport().vrs_mode = vrs_mode_for(level)
	print("[vr] foveation level %d dynamic %s supported %s vrs_mode %d" % [level,
		str(xr.foveation_dynamic), str(xr.is_foveation_supported()), get_viewport().vrs_mode])


# =============================================================================
# Session lifecycle
# =============================================================================

func _set_state(s: String) -> void:
	if s == session_state:
		return
	session_state = s
	session_state_changed.emit(s)


func _on_session_begun() -> void:
	_set_state("begun")
	_query_presence_support()
	apply_refresh_policy()
	if runtime != null:
		runtime.call(&"set_cpu_level", OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)
		runtime.call(&"set_gpu_level", OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)
	print("[vr] session begun")


func _on_session_synchronized() -> void:
	_set_state("synchronized")


## Visible but not focused: the system menu or a guardian dialog is up, or
## the headset is coming off. Pause.
func _on_session_visible() -> void:
	var was := focused
	focused = false
	_set_state("visible")
	print("[vr] session visible (not focused)")
	_focus_lost("session visible", was)


func _on_session_focused() -> void:
	_set_state("focused")
	print("[vr] session focused")
	_set_focused(user_present)


## `focused` = session focused and the headset worn; session_focused fires
## when that becomes true (the headset put back on counts too).
func _set_focused(f: bool) -> void:
	var was := focused
	focused = f
	if f and not was:
		session_focused.emit()


func _on_session_stopping() -> void:
	var was := focused
	focused = false
	_set_state("stopping")
	print("[vr] session stopping")
	_focus_lost("session stopping", was)
	session_stopping.emit()


func _on_session_loss_pending() -> void:
	_set_state("loss_pending")
	_quit("session loss pending")


func _on_instance_exiting() -> void:
	_set_state("exiting")
	_quit("instance exiting")


## The runtime is going away: quit cleanly.
func _quit(reason: String) -> void:
	print("[vr] %s: quitting" % reason)
	quitting.emit(reason)
	if quit_on_session_end:
		get_tree().quit()


## The headset came off (or back on). Off: not focused any more, pause
## with the menu (once: the runtime usually follows with session_visible,
## which then finds focus already gone). On: focused again if the session
## still has focus; the game stays paused.
func _on_user_presence_changed(present: bool) -> void:
	var was := focused
	user_present = present
	presence_supported = true
	print("[vr] user present: %s" % str(present))
	user_presence_changed.emit(present)
	if not present:
		focused = false
		_focus_lost("headset removed", was)
	else:
		_set_focused(session_state == "focused")


func _on_refresh_rate_changed(hz: float) -> void:
	refresh_rate = hz
	var ticks := apply_physics_tick(hz)
	print("[vr] refresh rate changed to %.1f Hz; physics %d Hz" % [hz, ticks])
	refresh_rate_changed.emit(hz)


func _on_cpu_level_changed(sub_domain: int, from_level: int, to_level: int) -> void:
	_on_perf_level_changed(sub_domain, from_level, to_level, "cpu")


func _on_gpu_level_changed(sub_domain: int, from_level: int, to_level: int) -> void:
	_on_perf_level_changed(sub_domain, from_level, to_level, "gpu")


func _on_perf_level_changed(sub_domain: int, from_level: int, to_level: int, which: String) -> void:
	perf_notifications += 1
	print("[vr] %s perf notification: domain %d level %d -> %d" % [which, sub_domain, from_level, to_level])


## Focus went away (or a loss signal arrived): pause a running game with the
## pause menu up (every time: request_pause is idempotent, and a game that
## is PLAYING while nobody wears the headset must pause whatever came
## before), then, only when `focused` just went from true to false, count
## it and tell listeners (one focus loss per removal, however many of
## session_visible / user_presence_changed(false) / session_stopping the
## runtime sends). Order matters: the UI toggles pause on menu_requested
## and ignores session_unfocused once paused, so the menu request goes
## first.
func _focus_lost(reason: String, was_focused: bool) -> void:
	if was_focused:
		focus_losses += 1
		print("[vr] focus lost (%s)" % reason)
	request_pause()
	if was_focused:
		session_unfocused.emit()


## Sets recalibration_suggested (and tells the UI when it changes).
func suggest_recalibration(on: bool) -> void:
	if on == recalibration_suggested:
		return
	recalibration_suggested = on
	recalibration_suggested_changed.emit(on)


## Pauses a running game (PLAYING or CAUGHT) via the menu request; if no UI
## handled it (dev scenes), pauses directly. Never resumes a paused game.
func request_pause() -> void:
	if not pause_on_focus_loss:
		return
	if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
		Events.menu_requested.emit()
		if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
			Game.set_state(Game.State.PAUSED)


# =============================================================================
# Recenter
# =============================================================================

## Recenters the view on the head (yaw only, keeping height) and tells the
## rig (PlayerBird zeroes that tick's head delta and re-aims the view).
func recenter() -> void:
	if active:
		XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)
	recenter_count += 1
	print("[vr] recentered")
	recentered.emit()


## The runtime recentered (Oculus button long-press): re-apply our reference
## frame against the new tracking origin, as Godot's XR start script does.
func _on_pose_recentered() -> void:
	recenter()


func _on_settings_changed(key: String, _value: Variant) -> void:
	match key:
		"vr_refresh_rate":
			apply_refresh_policy()
		"vr_foveation_level", "vr_foveation_dynamic":
			apply_foveation()


# =============================================================================
# Diagnostics
# =============================================================================

func _process(delta: float) -> void:
	_elapsed += delta
	_frames += 1
	if _autoquit > 0.0 and _elapsed >= _autoquit:
		print("[vr] autoquit after %.1f s" % _elapsed)
		_autoquit = -1.0
		get_tree().quit()
	if _diag:
		_diag_t += delta
		if _diag_t >= 1.0:
			_print_diag(_diag_t)
			_diag_t = 0.0
			_frames = 0


func _print_diag(window: float) -> void:
	var line := "[vr] t=%.1f state=%s fps=%.1f refresh=%.0f physics=%d" % [_elapsed, session_state,
		_frames / maxf(window, 1e-3), refresh_rate, Engine.physics_ticks_per_second]
	for tracker_name in [&"head", &"left_hand", &"right_hand"]:
		var t := XRServer.get_tracker(tracker_name) as XRPositionalTracker
		if t:
			var p := t.get_pose(&"grip") if tracker_name != &"head" else t.get_pose(&"default")
			if p and p.has_tracking_data:
				line += " %s=%s" % [tracker_name, p.transform.origin.snapped(Vector3.ONE * 0.01)]
	print(line)
