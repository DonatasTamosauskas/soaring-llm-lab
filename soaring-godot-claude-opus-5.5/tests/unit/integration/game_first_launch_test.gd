extends TestCase
## The first launch in the headset (no saved wing calibration), in the real
## main.tscn (integration round 1; three verifier findings): the VR area's
## calibration card used to come up by itself during loading, sat over the
## main menu (hiding How to fly, Settings and Quit), and Play cancelled it
## silently, so the first flight flew uncalibrated. Now Play is the gate:
##  * in the menu nothing comes up by itself, however long the headset is on;
##  * Play closes the menu and asks for the spread; the run waits (the body
##    still on its perch) and starts only after a capture or an explicit
##    skip (B or Y), never uncalibrated behind the player's back;
##  * the menu button abandons the step: the menu comes back and the next
##    Play asks again;
##  * the card is the only thing in front of the player while it waits.
## VR is emulated (VR.active, focus, the rig's tracked nodes written as a
## headset would, the calibrator's tracking check forced valid); the UI runs
## in its VR form with scripted laser pointers (game_kit.gd).

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const DT := 1.0 / 72.0

var kit: Kit
var booted := false
var cal: VRCalibration
var _saved_vr := []
var _saved_cal: Variant = null
var _saved_span: Variant = null


func before_all() -> void:
	_saved_cal = Settings.get_value("wing_calibration", {})
	_saved_span = Settings.get_value("arm_span", null)
	# A first launch: nothing saved.
	Settings.set_value("wing_calibration", {})
	kit = Kit.new()
	booted = await kit.boot(self, true)
	if booted:
		cal = kit.main.rig_extras.calibration


func after_all() -> void:
	VR.active = false
	VR.focused = false
	if kit:
		await kit.teardown()
	Settings.set_value("wing_calibration", _saved_cal if _saved_cal != null else {})
	if _saved_span != null:
		Settings.set_value("arm_span", _saved_span)
	await wait_frames(5)


func _headset_on() -> void:
	VR.active = true
	VR.focused = true
	cal.force_valid = true


## Writes the rig's tracked nodes as the headset would, for `seconds` of
## frames: the head and both grips of a standing player (1.75 m span).
func _pose(h: VRHumanPose, seconds: float) -> void:
	var ws := kit.main.player.origin.world_scale
	for i in int(round(seconds / DT)):
		var hd := h.head_transform()
		kit.main.player.camera.transform = Transform3D(hd.basis, hd.origin * ws)
		for s in 2:
			var x := h.hand_transform(s)
			(cal.hands[s] as Node3D).transform = Transform3D(x.basis, x.origin * ws)
		await wait_frames(1)


func _press_b() -> void:
	VR.controls.button_changed.emit(&"right_hand", &"by_button", true)
	await wait_frames(2)
	VR.controls.button_changed.emit(&"right_hand", &"by_button", false)


func test_no_card_by_itself_in_the_menu() -> void:
	if not check(booted, "the game loaded"):
		return
	eq(Game.state, Game.State.MENU, "in the main menu")
	check(cal != null, "VR's calibration is on the player's rig")
	check(not cal.first_launch_prompt, "main.tscn: the first-launch step waits for Play")
	check(cal.first_launch_pending, "nothing saved: the step is due")
	check(kit.main.ui.bridge is FirstFlightGate, "Play goes through the first-flight gate")
	_headset_on()
	var h := VRHumanPose.for_span(1.75)
	h.set_arms(deg_to_rad(-75.0))
	await _pose(h, 3.0)
	eq(cal.flow, VRCalibration.Flow.IDLE, "3 s in the menu with the headset on: no card by itself")
	check(cal.prompt == null or not cal.prompt.visible, "nothing over the main menu")
	eq(kit.screen(), &"main", "the main menu is up")


func test_menu_button_abandons_and_play_asks_again() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	check(await kit.click(&"main", &"play"), "Play hovered and pulled")
	await wait_frames(3)
	eq(Game.state, Game.State.MENU, "Play did not start the run yet")
	eq(cal.flow, VRCalibration.Flow.CAPTURE, "the card asks for the spread")
	eq(cal.flow_reason, &"first_launch", "as the first-launch step")
	eq(kit.screen(), &"", "the menu closed: the card is the only panel")
	check(not kit.main.ui.menu_panel.shown, "the menu panel is hidden")
	Events.menu_requested.emit()
	await wait_frames(4)
	eq(cal.flow, VRCalibration.Flow.IDLE, "the menu button abandons the step (no result card)")
	eq(kit.screen(), &"main", "the main menu is back")
	eq(Game.state, Game.State.MENU, "still in the menu")
	check(cal.first_launch_pending, "nothing decided: still due")
	check(not cal.calibrator.calibrated, "nothing captured")
	# The debounce of the menu button (UIRoot, 250 ms).
	await get_tree().create_timer(0.3).timeout


func test_play_asks_first_and_b_skips_to_the_default_wings() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	var runs := kit.count("run_started")
	check(await kit.click(&"main", &"play"), "Play hovered and pulled")
	await wait_frames(3)
	eq(cal.flow, VRCalibration.Flow.CAPTURE, "Play asks for the spread again")
	check(cal.prompt != null and cal.prompt.visible, "the card is shown")
	if cal.prompt != null:
		eq(cal.prompt.hint.text, VRCalibration.SKIP_HINT, "it says how to skip ('%s')" % VRCalibration.SKIP_HINT)
	check(not kit.main.player.auto_process, "the body waits on its perch")
	var h := VRHumanPose.for_span(1.75)
	h.set_arms(deg_to_rad(-75.0))
	await _pose(h, 4.0)
	eq(Game.state, Game.State.MENU, "arms down for 4 s: still waiting (no timeout, no run)")
	eq(kit.count("run_started"), runs, "no run started")
	await _press_b()
	await wait_frames(2)
	eq(cal.flow, VRCalibration.Flow.FAILED, "B: the step ends")
	check(cal.prompt_text().begins_with("Calibration skipped"), "the card says so ('%s')" % cal.prompt_text().replace("\n", " / "))
	check(cal.prompt_text().ends_with("Using default wings"), "and that the default wings fly")
	eq(Game.state, Game.State.MENU, "the skip card has its moment before the run")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 4.0), "then the run starts")
	eq(kit.count("run_started"), runs + 1, "one run")
	eq(kit.main.gate.last_outcome, "skipped", "the gate's outcome")
	check(not cal.first_launch_pending, "skipped: not asked again this session")
	check(not cal.calibrator.calibrated, "the defaults fly")
	eq(cal.flow, VRCalibration.Flow.IDLE, "no card over the first flight")
	# Back to the menu for the next case.
	Game.set_state(Game.State.PAUSED)
	await wait_frames(3)
	check(await kit.hold(&"pause", &"quit_menu"), "Quit to menu")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.MENU, 3.0), "back in the menu")
	# Once skipped, Play starts the run at once.
	check(await kit.click(&"main", &"play"), "Play again")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0), "skipped this session: Play starts the run at once")
	eq(cal.flow, VRCalibration.Flow.IDLE, "no card")
	Game.set_state(Game.State.PAUSED)
	await wait_frames(3)
	check(await kit.hold(&"pause", &"quit_menu"), "Quit to menu")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.MENU, 3.0), "back in the menu")


func test_play_asks_first_and_a_held_spread_is_captured() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	# The next launch of a player who skipped: due again.
	cal.first_launch_pending = true
	cal.persist = false
	var runs := kit.count("run_started")
	check(await kit.click(&"main", &"play"), "Play hovered and pulled")
	await wait_frames(3)
	eq(cal.flow, VRCalibration.Flow.CAPTURE, "Play asks for the spread")
	var h := VRHumanPose.for_span(1.75)
	h.set_arms(deg_to_rad(-75.0))
	await _pose(h, 0.5)
	# The arms come up into the spread and hold still.
	h.spread_pose()
	var t := 0.0
	while not cal.calibrator.calibrated and t < 4.0:
		await _pose(h, DT)
		t += DT
	check(cal.calibrator.calibrated, "the held spread is captured (%.2f s)" % t)
	eq(cal.flow, VRCalibration.Flow.DONE, "'Wings calibrated'")
	eq(Game.state, Game.State.MENU, "the confirmation has its moment before the run")
	var res: Variant = kit.main.player.wing_input.calibration
	check(res != null and bool(res.get("calibrated")), "flight flies the new calibration")
	h.set_arms(deg_to_rad(-75.0))
	var started := false
	t = 0.0
	while t < 4.0 and not started:
		await _pose(h, DT)
		t += DT
		started = Game.state == Game.State.PLAYING
	check(started, "then the run starts (%.2f s after the capture)" % t)
	eq(kit.count("run_started"), runs + 1, "one run")
	eq(kit.main.gate.last_outcome, "captured", "the gate's outcome")
	eq(cal.flow, VRCalibration.Flow.IDLE, "no card over the first flight")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings: %s" % kit.log.summary())
	cal.persist = true


## A step the player asks for from the pause menu (integration round 2, the
## Quest verifier): Settings > Recalibrate wings put the card, 1.25 m away,
## straight over the pause panel at 1.5 m - it covered Settings and the
## laser still hit buttons behind it. The menus make way while the card is
## up and come back as they were (the Settings screen over the pause
## screen) once its result card has gone.
func test_recalibrating_from_the_pause_menu_hides_the_menu_until_done() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	if Game.state != Game.State.PLAYING:
		kit.main.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 6.0)
	cal.persist = false
	Events.menu_requested.emit()
	await wait_frames(3)
	eq(Game.state, Game.State.PAUSED, "(setup) paused")
	check(await kit.click(&"pause", &"settings"), "Settings from the pause menu")
	await wait_frames(3)
	eq(kit.screen(), &"settings", "(setup) the Settings screen")
	check(await kit.click(&"settings", &"recalibrate"), "Recalibrate wings")
	await wait_frames(3)
	eq(cal.flow, VRCalibration.Flow.CAPTURE, "the card asks for the spread")
	eq(kit.main.ui.stack, [] as Array[StringName], "no menu screen behind the card")
	check(not kit.main.ui.menu_panel.shown, "the menu panel made way for the card")
	check(kit.main.gate.hiding_for_step, "(the bridge knows)")
	await _press_b()
	await wait_frames(3)
	eq(cal.flow, VRCalibration.Flow.FAILED, "B cancels: 'Calibration cancelled'")
	check(not kit.main.ui.menu_panel.shown, "the menu stays away while the result card shows")
	var t0 := Time.get_ticks_msec()
	while cal.flow != VRCalibration.Flow.IDLE and Time.get_ticks_msec() - t0 < 4000:
		await wait_frames(1)
	await wait_frames(3)
	eq(Game.state, Game.State.PAUSED, "still paused")
	eq(kit.main.ui.stack, [&"pause", &"settings"] as Array[StringName], "the menus are back as they were: Settings over the pause screen")
	check(kit.main.ui.menu_panel.shown, "the menu panel is back")
	# Back to the game.
	await kit.click(&"settings", &"back")
	Events.menu_requested.emit()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	cal.persist = true
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
