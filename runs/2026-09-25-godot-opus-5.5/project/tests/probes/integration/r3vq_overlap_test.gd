extends TestCase
## VERIFIER PROBE (integration verify round 3, VR/Quest lens). Not a suite.
## Round 2 made the menus give way while a calibration card the player asked
## for is up (FirstFlightGate.hiding_for_step). Does anything bring a menu
## back over the card while it waits?
##   A. main menu -> Settings -> Recalibrate wings (MENU state), then the
##      left menu button while the card waits.
##   B. the same from the pause menu (PAUSED), then the menu button.
## VR emulated as in game_first_launch_test (game_kit.gd).
## Run: tools/gd.sh r3vq_ov --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r3vq_overlap --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var cal: VRCalibration
var _saved_cal: Variant = null


func before_all() -> void:
	_saved_cal = Settings.get_value("wing_calibration", {})
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
	await wait_frames(5)


func _headset_on() -> void:
	VR.active = true
	VR.focused = true
	cal.force_valid = true
	cal.persist = false


func _press_b() -> void:
	VR.controls.button_changed.emit(&"right_hand", &"by_button", true)
	await wait_frames(2)
	VR.controls.button_changed.emit(&"right_hand", &"by_button", false)


func _snapshot(label: String) -> Dictionary:
	var d := {"label": label, "state": Game.state_name(), "flow": VRCalibration.Flow.keys()[cal.flow],
		"card_visible": cal.prompt != null and cal.prompt.visible, "menu_shown": kit.main.ui.menu_panel.shown,
		"stack": str(kit.main.ui.stack), "hiding": kit.main.gate.hiding_for_step}
	print("[integration-verify] ", JSON.stringify(d))
	metric(label, d)
	return d


func test_a_menu_button_during_a_recalibration_from_the_main_menu() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	eq(Game.state, Game.State.MENU, "(setup) main menu")
	check(await kit.click(&"main", &"settings"), "Settings")
	await wait_frames(3)
	check(await kit.click(&"settings", &"recalibrate"), "Recalibrate wings")
	await wait_frames(5)
	var a := _snapshot("A_card_up")
	check(a["flow"] == "CAPTURE" and a["card_visible"] and not a["menu_shown"], "the card alone")
	Events.menu_requested.emit()
	await wait_frames(10)
	var b := _snapshot("A_after_menu_button")
	check(not (b["card_visible"] and b["menu_shown"] and b["flow"] == "CAPTURE"),
		"a menu never comes up over a waiting card (card %s, menu %s, flow %s, stack %s)" % [b["card_visible"], b["menu_shown"], b["flow"], b["stack"]])
	await _press_b()
	var t0 := Time.get_ticks_msec()
	while cal.flow != VRCalibration.Flow.IDLE and Time.get_ticks_msec() - t0 < 4000:
		await wait_frames(1)
	await wait_frames(3)
	_snapshot("A_after_cancel")
	check(kit.main.ui.menu_panel.shown and Game.state == Game.State.MENU, "a menu is shown after the step")


func test_b_menu_button_during_a_recalibration_from_the_pause_menu() -> void:
	if not booted or cal == null:
		fail("needs the game")
		return
	_headset_on()
	# (No first-launch gate for this setup: the step was skipped already.)
	cal.first_launch_pending = false
	if Game.state != Game.State.PLAYING:
		kit.main.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 6.0)
	Events.menu_requested.emit()
	await wait_frames(3)
	eq(Game.state, Game.State.PAUSED, "(setup) paused")
	check(await kit.click(&"pause", &"settings"), "Settings")
	await wait_frames(3)
	check(await kit.click(&"settings", &"recalibrate"), "Recalibrate wings")
	await wait_frames(5)
	_snapshot("B_card_up")
	await wait_frames(20)
	Events.menu_requested.emit()
	await wait_frames(10)
	var b := _snapshot("B_after_menu_button")
	check(not (b["card_visible"] and b["menu_shown"] and b["flow"] == "CAPTURE"), "no menu over a waiting card")
	var t0 := Time.get_ticks_msec()
	while cal.flow != VRCalibration.Flow.IDLE and Time.get_ticks_msec() - t0 < 4000:
		await wait_frames(1)
	await wait_frames(3)
	_snapshot("B_end")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
