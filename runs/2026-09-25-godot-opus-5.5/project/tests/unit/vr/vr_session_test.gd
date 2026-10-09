extends TestCase
## V1/V2 wiring, fix round 5 (the engineering verifier's surviving mutants
## E30, E53 and "delete any xr.*.connect line"): the V2 tests call the
## autoload's handlers directly, so the connections to OpenXR's signals, the
## refresh policy at session start and a headset put back on while the
## session is only VISIBLE were never exercised (and at 72 Hz the simulator
## cannot tell whether the policy ran: the project's tick is 72 already).
##
## Here a stand-in interface carrying OpenXRInterface's signals and the
## methods the policies call is connected with VRManager.connect_interface
## (the same call _ready makes with the real interface), and every signal is
## EMITTED, as the runtime does.

## OpenXRInterface's session signals and the calls VR makes, recorded.
class FakeRuntime:
	extends RefCounted
	signal session_begun
	signal session_synchronized
	signal session_visible
	signal session_focussed
	signal session_stopping
	signal session_loss_pending
	signal instance_exiting
	signal pose_recentered
	signal refresh_rate_changed(refresh_rate: float)
	signal user_presence_changed(is_user_present: bool)
	signal cpu_level_changed(sub_domain: int, from_level: int, to_level: int)
	signal gpu_level_changed(sub_domain: int, from_level: int, to_level: int)
	## The simulator's list (QUEST.md): 30/60/72/80/90/120 Hz.
	var rates: Array = [30.0, 60.0, 72.0, 80.0, 90.0, 120.0]
	var display_refresh_rate := 60.0
	var cpu_level := -1
	var gpu_level := -1

	func get_available_display_refresh_rates() -> Array:
		return rates

	func set_cpu_level(level: int) -> void:
		cpu_level = level

	func set_gpu_level(level: int) -> void:
		gpu_level = level


var fake: FakeRuntime
var counts := {}
var _cbs: Array = []
var _ticks0 := 60


func before_all() -> void:
	_ticks0 = Engine.physics_ticks_per_second
	for sig in [&"session_focused", &"session_unfocused", &"session_stopping", &"recentered", &"refresh_rate_changed", &"quitting"]:
		var cb := func(_a: Variant = null) -> void: counts[sig] = int(counts.get(sig, 0)) + 1
		VR.connect(sig, cb)
		_cbs.append([sig, cb])
	var m := func() -> void: counts[&"menu"] = int(counts.get(&"menu", 0)) + 1
	Events.menu_requested.connect(m)
	_cbs.append([&"menu", m])


func after_all() -> void:
	for c in _cbs:
		if c[0] == &"menu":
			Events.menu_requested.disconnect(c[1])
		else:
			VR.disconnect(c[0], c[1])
	Engine.physics_ticks_per_second = _ticks0


func before_each() -> void:
	counts.clear()
	fake = FakeRuntime.new()
	VR.quit_on_session_end = false
	VR.connect_interface(fake)


func after_each() -> void:
	VR.disconnect_interface()
	VR.quit_on_session_end = true
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.focused = false
	VR.user_present = true
	VR.presence_supported = false
	VR.session_state = "none"
	VR.refresh_rate = 0.0
	Engine.physics_ticks_per_second = _ticks0


func n(sig: StringName) -> int:
	return int(counts.get(sig, 0))


## Every OpenXR session signal reaches its handler through the connection
## _ready makes: begun (with the refresh policy and the perf levels),
## synchronized, visible, focussed, stopping, loss pending, exiting,
## recentered, refresh changes, presence and the perf notifications.
func test_runtime_signals_drive_the_session() -> void:
	Engine.physics_ticks_per_second = 60
	var runs := VR.refresh_policy_runs
	fake.session_begun.emit()
	eq(VR.session_state, "begun", "session_begun -> begun")
	eq(VR.refresh_policy_runs, runs + 1, "the refresh policy runs at session start (E53)")
	eq(fake.display_refresh_rate, 72.0, "the runtime is asked for the policy's 72 Hz (it offered 60 first)")
	eq(Engine.physics_ticks_per_second, 72, "physics tick = the refresh rate from the first frame")
	eq(VR.refresh_rate, 72.0, "VR.refresh_rate holds it")
	eq(fake.cpu_level, OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH, "CPU perf level sustained high")
	eq(fake.gpu_level, OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH, "GPU perf level sustained high")
	fake.session_synchronized.emit()
	eq(VR.session_state, "synchronized", "session_synchronized -> synchronized")
	fake.session_visible.emit()
	eq(VR.session_state, "visible", "session_visible -> visible")
	fake.session_focussed.emit()
	eq(VR.session_state, "focused", "session_focussed -> focused")
	check(VR.focused, "and VR.focused")
	eq(n(&"session_focused"), 1, "session_focused emitted")
	# In play: the headset comes off -> paused with the menu.
	Game.set_state(Game.State.PLAYING)
	fake.user_presence_changed.emit(false)
	check(not VR.focused, "headset off -> not focused")
	eq(Game.state, Game.State.PAUSED, "headset off pauses the game")
	eq(n(&"menu"), 1, "with the pause menu")
	eq(n(&"session_unfocused"), 1, "session_unfocused once")
	fake.user_presence_changed.emit(true)
	check(VR.focused, "headset back on, session still focused -> focused")
	eq(Game.state, Game.State.PAUSED, "never resumed by itself")
	# The display rate changes (thermal, a setting): the tick follows.
	fake.refresh_rate_changed.emit(90.0)
	eq(Engine.physics_ticks_per_second, 90, "refresh_rate_changed(90) -> physics 90 Hz")
	eq(VR.refresh_rate, 90.0, "VR.refresh_rate follows")
	eq(n(&"refresh_rate_changed"), 1, "and is announced")
	var rc := VR.recenter_count
	fake.pose_recentered.emit()
	eq(VR.recenter_count, rc + 1, "the runtime's pose_recentered recenters")
	eq(n(&"recentered"), 1, "VR.recentered once")
	var perf := VR.perf_notifications
	fake.cpu_level_changed.emit(0, 1, 2)
	fake.gpu_level_changed.emit(1, 1, 2)
	eq(VR.perf_notifications, perf + 2, "CPU and GPU perf notifications are received")
	fake.session_stopping.emit()
	eq(VR.session_state, "stopping", "session_stopping -> stopping")
	eq(n(&"session_stopping"), 1, "VR.session_stopping emitted")
	fake.session_loss_pending.emit()
	eq(VR.session_state, "loss_pending", "session_loss_pending -> loss_pending")
	eq(n(&"quitting"), 1, "and the app quits")
	fake.instance_exiting.emit()
	eq(VR.session_state, "exiting", "instance_exiting -> exiting")
	eq(n(&"quitting"), 2, "and the app quits")


## A headset put back on while the session is only VISIBLE (the system menu
## is still up, or the runtime has not refocused yet) is not focus: the
## player cannot play until session_focussed (E30 made presence-on always
## focus). Then focused, still paused.
func test_headset_on_while_only_visible_is_not_focus() -> void:
	fake.session_begun.emit()
	fake.session_focussed.emit()
	Game.set_state(Game.State.PLAYING)
	fake.user_presence_changed.emit(false)
	fake.session_visible.emit()
	check(not VR.focused, "(setup) off and visible")
	var focused0 := n(&"session_focused")
	fake.user_presence_changed.emit(true)
	check(not VR.focused, "headset on while the session is only visible: not focused")
	eq(n(&"session_focused"), focused0, "no session_focused yet")
	fake.session_focussed.emit()
	check(VR.focused, "session focused with the headset on: focused")
	eq(n(&"session_focused"), focused0 + 1, "session_focused now")
	eq(Game.state, Game.State.PAUSED, "still paused: the player resumes from the menu")


## An explicit 90 Hz setting (or --refresh=90) is honoured at session
## start; the policy never asks for a rate the runtime does not offer.
func test_session_start_applies_the_requested_rate() -> void:
	Engine.physics_ticks_per_second = 60
	# --refresh=90 (the same path as the vr_refresh_rate setting; the shared
	# settings file is never written by a test).
	VR._refresh_override = 90.0
	fake.session_begun.emit()
	eq(fake.display_refresh_rate, 90.0, "90 Hz asked for")
	eq(Engine.physics_ticks_per_second, 90, "physics 90 Hz")
	fake.rates = [60.0, 72.0]
	fake.display_refresh_rate = 60.0
	fake.session_begun.emit()
	eq(fake.display_refresh_rate, 72.0, "a runtime without 90 Hz gets its best rate <= 90 (72)")
	eq(Engine.physics_ticks_per_second, 72, "physics 72 Hz")
	VR._refresh_override = 0.0


## disconnect_interface undoes connect_interface (the test stand-in never
## keeps driving the autoload).
func test_disconnect_removes_every_connection() -> void:
	VR.disconnect_interface()
	var left := 0
	for sig in fake.get_signal_list():
		left += fake.get_signal_connection_list(sig["name"]).size()
	eq(left, 0, "no connection left on the stand-in")
	check(VR.runtime == null, "no runtime")
	VR.connect_interface(fake)
	var made := 0
	for sig in fake.get_signal_list():
		made += fake.get_signal_connection_list(sig["name"]).size()
	eq(made, 12, "all twelve session signals connected")
