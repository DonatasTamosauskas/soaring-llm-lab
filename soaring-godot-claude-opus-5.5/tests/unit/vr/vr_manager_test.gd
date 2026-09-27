extends TestCase
## V1 (headless part), V2, V9: the VR autoload. Refresh-rate policy and
## physics tick = refresh; focus loss / headset removal / session stopping
## pause the game with the pause menu (and stay paused on focus regain);
## recenter requests; the desktop fallback when no runtime is present
## (this suite runs with --xr-mode off). Session signals are driven by
## calling the autoload's OpenXR handlers directly, exactly as the
## runtime's signals would.

var menu := 0
var unfocused := 0
var focused_sig := 0
var stopping := 0
var _ticks := 0


func before_all() -> void:
	_ticks = Engine.physics_ticks_per_second
	Events.menu_requested.connect(func() -> void: menu += 1)
	VR.session_unfocused.connect(func() -> void: unfocused += 1)
	VR.session_focused.connect(func() -> void: focused_sig += 1)
	VR.session_stopping.connect(func() -> void: stopping += 1)


func before_each() -> void:
	menu = 0
	unfocused = 0
	focused_sig = 0
	stopping = 0


func after_each() -> void:
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.focused = false
	VR.user_present = true
	VR.presence_supported = false
	VR.session_state = "none"
	Engine.physics_ticks_per_second = _ticks


# -----------------------------------------------------------------------------

func test_desktop_fallback_is_clean() -> void:
	check(not VR.active, "no runtime: desktop mode")
	check(VR.xr == null, "no OpenXR interface held")
	check(not get_viewport().use_xr, "main viewport renders to the window")
	eq(Engine.physics_ticks_per_second, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second")), "physics tick untouched on desktop")
	# Every XR-facing call is a safe no-op.
	VR.apply_refresh_policy()
	VR.apply_foveation()
	VR.haptics.play(&"catch")
	VR.haptics.tick(0.2)
	eq((VR.haptics.sink as VRHaptics.XRSink).calls, 0, "haptics reach no device")
	VR.controls.tick(0.1)
	check(not VR.controls.is_pressed(&"left_hand", &"menu_button"), "no controller input on desktop")
	eq(VR.controls.grip(&"right_hand"), 0.0, "grip reads 0 on desktop")
	for n in [VR, VR.haptics, VR.controls]:
		eq((n as Node).process_mode, Node.PROCESS_MODE_ALWAYS, "%s processes while paused" % (n as Node).name)


func test_refresh_policy() -> void:
	var sim := [30.0, 60.0, 72.0, 80.0, 90.0]
	eq(VRManager.choose_refresh_rate([72.0, 80.0, 90.0, 120.0], 0.0), 72.0, "auto on Quest: 72 Hz")
	eq(VRManager.choose_refresh_rate(sim, 0.0), 72.0, "auto in the simulator: the same 72 Hz the Quest ships with")
	eq(VRManager.choose_refresh_rate(sim, 90.0), 90.0, "90 Hz is one setting away")
	eq(VRManager.choose_refresh_rate([72.0, 90.0], 90.0), 90.0, "the setting may ask for 90")
	eq(VRManager.choose_refresh_rate([72.0, 90.0], 120.0), 90.0, "never above what the display offers")
	eq(VRManager.choose_refresh_rate(sim, 60.0), 72.0, "never below 72 Hz")
	eq(VRManager.choose_refresh_rate(sim, 80.0), 80.0, "exact rates are honoured")
	eq(VRManager.choose_refresh_rate([60.0], 0.0), 60.0, "only what exists")
	eq(VRManager.choose_refresh_rate([], 0.0), 0.0, "no list: leave the runtime default")


func test_physics_tick_follows_the_display() -> void:
	var got: Array[float] = []
	var cb := func(hz: float) -> void: got.append(hz)
	VR.refresh_rate_changed.connect(cb)
	eq(VRManager.apply_physics_tick(90.0), 90, "tick for 90 Hz")
	eq(Engine.physics_ticks_per_second, 90, "physics at 90 Hz")
	# The runtime changes the rate (thermal throttling, a setting): re-applied.
	VR._on_refresh_rate_changed(72.0)
	eq(Engine.physics_ticks_per_second, 72, "physics follows the runtime to 72 Hz")
	near(VR.refresh_rate, 72.0, 1e-6, "refresh rate recorded")
	VR._on_refresh_rate_changed(89.9)
	eq(Engine.physics_ticks_per_second, 90, "rounded to whole ticks")
	eq(got.size(), 2, "refresh_rate_changed forwarded")
	eq(Engine.max_fps, 0, "no fps cap (the compositor paces frames)")
	VR.refresh_rate_changed.disconnect(cb)


func test_focus_loss_pauses_with_the_menu() -> void:
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	eq(focused_sig, 1, "session_focused emitted")
	check(VR.focused, "focused")
	eq(VR.session_state, "focused", "state focused")
	# System menu / headset coming off.
	VR._on_session_visible()
	eq(menu, 1, "focus loss -> Events.menu_requested (the pause menu)")
	eq(Game.state, Game.State.PAUSED, "game paused")
	check(get_tree().paused, "tree paused")
	eq(unfocused, 1, "session_unfocused emitted")
	check(not VR.focused, "not focused")
	eq(VR.session_state, "visible", "state visible")
	# Focus comes back: stay paused, the player resumes deliberately.
	VR._on_session_focused()
	eq(Game.state, Game.State.PAUSED, "regaining focus does not resume")
	eq(menu, 1, "and does not toggle the menu")


## The UI toggles pause on menu_requested and pauses on session_unfocused:
## the order VR emits them in must leave the game paused, not resumed.
func test_focus_loss_with_a_toggling_ui() -> void:
	var toggles := [0]
	var ui_menu := func() -> void:
		toggles[0] += 1
		if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
			Game.set_state(Game.State.PAUSED)
		elif Game.state == Game.State.PAUSED:
			Game.set_state(Game.State.PLAYING)
	var ui_unfocus := func() -> void:
		if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
			Game.set_state(Game.State.PAUSED)
	Events.menu_requested.connect(ui_menu)
	VR.session_unfocused.connect(ui_unfocus)
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	VR._on_session_visible()
	eq(Game.state, Game.State.PAUSED, "paused with the UI listening")
	eq(toggles[0], 1, "the UI saw exactly one menu request")
	Events.menu_requested.disconnect(ui_menu)
	VR.session_unfocused.disconnect(ui_unfocus)


func test_focus_loss_outside_play_changes_nothing() -> void:
	Game.set_state(Game.State.MENU)
	VR._on_session_focused()
	VR._on_session_visible()
	eq(menu, 0, "in the main menu: no menu toggle")
	eq(Game.state, Game.State.MENU, "still in the menu")
	eq(unfocused, 1, "listeners still told")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	VR._on_session_focused()
	VR._on_session_visible()
	eq(menu, 0, "already paused: the menu is not toggled closed")
	eq(Game.state, Game.State.PAUSED, "stays paused")


func test_caught_moment_pauses_too() -> void:
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.CAUGHT)
	VR._on_session_focused()
	VR._on_session_visible()
	eq(Game.state, Game.State.PAUSED, "focus loss while caught pauses")


func test_headset_removed_pauses() -> void:
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	var got: Array[bool] = []
	var cb := func(p: bool) -> void: got.append(p)
	VR.user_presence_changed.connect(cb)
	VR._on_user_presence_changed(false)
	eq(Game.state, Game.State.PAUSED, "headset off -> paused")
	check(not VR.user_present, "user absent")
	eq(got, [false] as Array[bool], "user_presence_changed forwarded")
	VR._on_user_presence_changed(true)
	eq(Game.state, Game.State.PAUSED, "headset back on: still paused")
	VR.user_presence_changed.disconnect(cb)


## Foveation only reaches the Mobile renderer through the main viewport's
## VRS mode (QUEST.md §0.2): VRS_XR for any level > 0 (mutant R11 turned it
## off and survived). The simulator harness checks the live viewport.
func test_foveation_uses_the_xr_density_map() -> void:
	for level in [1, 2, 3]:
		eq(VRManager.vrs_mode_for(level), Viewport.VRS_XR, "level %d: VRS_XR" % level)
	eq(VRManager.vrs_mode_for(0), Viewport.VRS_DISABLED, "level 0: VRS off")


## An XR interface stand-in: initialised, room-scale, with a camera
## (head) transform the test sets. XRServer.center_on_hmd reads the primary
## interface's camera transform.
class FakeXR:
	extends XRInterfaceExtension
	var head := Transform3D.IDENTITY

	func _get_name() -> StringName:
		return &"vr_test_fake"

	func _is_initialized() -> bool:
		return true

	func _get_play_area_mode() -> XRInterface.PlayAreaMode:
		return XRInterface.XR_PLAY_AREA_ROOMSCALE

	func _get_camera_transform() -> Transform3D:
		return head


## Recenter really re-centres the tracking space (XRServer.center_on_hmd,
## yaw only, height kept) when a headset is active (mutant R10 removed the
## call and survived: the desktop tests only saw the signal). A head 40° to
## the left at (0.3, 1.6, -0.2) m becomes the new origin and forward.
func test_recenter_centres_the_tracking_space() -> void:
	var fake := FakeXR.new()
	fake.head = Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(0.3, 1.6, -0.2))
	var prev := XRServer.primary_interface
	XRServer.add_interface(fake)
	XRServer.primary_interface = fake
	XRServer.clear_reference_frame()
	var was_active := VR.active
	VR.active = true
	VR.recenter()
	VR.active = was_active
	var ref := XRServer.get_reference_frame()
	var head_now := ref * fake.head
	XRServer.clear_reference_frame()
	XRServer.primary_interface = prev
	XRServer.remove_interface(fake)
	near(head_now.origin.x, 0.0, 1e-4, "the head is at the new origin (x)")
	near(head_now.origin.z, 0.0, 1e-4, "(z)")
	near(head_now.origin.y, 1.6, 1e-4, "height kept")
	near(rad_to_deg(VRMath.yaw_of(-head_now.basis.z)), 0.0, 0.01, "facing the new forward")


func test_session_stopping_pauses() -> void:
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	VR._on_session_stopping()
	eq(Game.state, Game.State.PAUSED, "stopping -> paused")
	eq(stopping, 1, "session_stopping emitted")
	eq(VR.session_state, "stopping", "state stopping")


func test_recenter_request() -> void:
	var got := [0]
	var cb := func() -> void: got[0] += 1
	VR.recentered.connect(cb)
	var before := VR.recenter_count
	Events.recenter_requested.emit()
	eq(got[0], 1, "one recentered signal per request")
	eq(VR.recenter_count, before + 1, "recenter counted")
	VR._on_pose_recentered()
	eq(got[0], 2, "the runtime's pose_recentered also recenters")
	VR.recentered.disconnect(cb)
