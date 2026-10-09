extends TestCase
## The game on a desktop (--xr-mode off, keyboard and mouse), through the
## engine's input path (Input.parse_input_event): the menus are the UI's 2D
## overlay clicked with the mouse, and the bird flies on the keyboard
## through DesktopPoseSource's virtual arms and the real WingInput.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self, false)


func after_all() -> void:
	for k in [KEY_SPACE, KEY_W, KEY_D, KEY_SHIFT]:
		_key(k, false)
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


## A left click at the centre of a Control, as the OS would deliver it to
## the window's viewport (headless has no window for Input to route mouse
## events through, so they are pushed to the viewport; keys go through
## Input.parse_input_event).
func _mouse_click(c: Control) -> void:
	var at := c.get_screen_transform() * (c.size * 0.5)
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	get_viewport().push_input(mv, true)
	await wait_frames(2)
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = at
		e.global_position = at
		e.pressed = down
		get_viewport().push_input(e, true)
		await wait_frames(2)


func test_desktop_menu_play_with_the_mouse() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	check(not m.ui.vr_mode, "desktop UI (2D overlay)")
	eq(kit.screen(), &"main", "main menu")
	var play := kit.button(&"main", &"play")
	check(play != null and play.is_visible_in_tree(), "Play is on screen")
	# (A new player: an earlier suite in this process finished the lessons.)
	m.ui.onboarding.reset()
	await _mouse_click(play)
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "a mouse click on Play started a run")
	check(m.player.pose_source is DesktopPoseSource, "the desktop pose source flies the bird")
	# The lessons name keys on the desktop (integration round 2: they showed
	# arm gestures only - no desktop screen named a key).
	await kit.wait_until(func() -> bool: return m.ui.hud.lesson_visible(), 2.0)
	if check(m.ui.hud.lesson_visible() and m.ui.onboarding.index >= 0, "a lesson card is up"):
		var lesson: Dictionary = Onboarding.LESSONS[m.ui.onboarding.index]
		var shown := (m.ui.hud.lesson_labels()[2] as Label).text
		eq(shown, lesson["keys"], "the card says the keys, not the gesture ('%s')" % shown)
	eq((m.ui.get_screen(&"howto") as HowToScreen).desktop, true, "How to fly shows the desktop captions")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_desktop_keyboard_flight() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var y0 := m.player.global_position.y
	var flaps := kit.count("player_flapped")
	# Space: flap (hold). The virtual arms stroke; WingInput credits them.
	_key(KEY_SPACE, true)
	await kit.advance(4.0)
	_key(KEY_SPACE, false)
	gt(kit.count("player_flapped"), flaps + 3, "Space flaps the wings (%d strokes)" % (kit.count("player_flapped") - flaps))
	eq(m.player.mode_name(), "flying", "took off from the perch")
	gt(m.player.global_position.y, y0 + 1.0, "and climbed")
	# D: bank right; the heading follows.
	var h_prev := m.player.rig_yaw
	var turned := 0.0
	var bank_max := 0.0
	_key(KEY_D, true)
	for i in 144:
		await kit.advance(1.0 / 72.0)
		turned += wrapf(m.player.rig_yaw - h_prev, -PI, PI)
		h_prev = m.player.rig_yaw
		bank_max = maxf(bank_max, float(m.player.telemetry()["bank"]))
	_key(KEY_D, false)
	lt(turned, -0.5, "D banks and turns right (yaw %.2f rad in 2 s)" % turned)
	gt(bank_max, deg_to_rad(20.0), "a real bank (%.0f deg)" % rad_to_deg(bank_max))
	metric("desktop_turn_rad_2s", turned)
	# Escape: the pause menu, and back.
	_key(KEY_ESCAPE, true)
	await wait_frames(2)
	_key(KEY_ESCAPE, false)
	eq(Game.state, Game.State.PAUSED, "Escape pauses")
	eq(kit.screen(), &"pause", "pause screen")
	var resume := kit.button(&"pause", &"resume")
	# A person reads the menu before clicking (the UI ignores input in a
	# screen's first moments).
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 400:
		await wait_frames(1)
	await _mouse_click(resume)
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0), "Resume with the mouse")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings: %s" % kit.log.summary())
