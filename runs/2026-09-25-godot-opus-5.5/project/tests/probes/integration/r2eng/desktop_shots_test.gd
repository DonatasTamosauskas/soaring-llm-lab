extends TestCase
## PROBE (round-2 engineering verifier): the integrated game in its DESKTOP
## form, rendered (the builders' shots put the UI in its VR form): the 2D
## overlay menu, a mouse click on Play, keyboard flight (Space / D / W),
## Escape -> pause, resume, a predator's strike -> the caught screen, the
## run's end -> the summary, Fly again. One screenshot per step:
##
##   tools/gd.sh v2e_desk --rendering-method forward_plus --resolution 1280x720 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/integration/r2eng --suite=desktop_shots --fresh-settings
##
## Writes artifacts/integration/verify/r2eng/desk_*.png.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var shots := []


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


func _shot(name: String) -> void:
	await wait_frames(3)
	var dir := Paths.artifacts("integration").path_join("verify/r2eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("desk_%s.png" % name)
	var err: Error = await Capture.save_viewport(get_viewport(), path)
	shots.append({"name": name, "err": err, "state": Game.state_name(), "screen": String(kit.screen()),
		"pos": str(kit.main.player.global_position), "mode": kit.main.player.mode_name()})
	print("[r2eng] desk shot %s: %s" % [name, shots.back()])


func _step(what: String) -> void:
	print("[r2eng] desk step %s at %d ms, state %s, fps %.1f, pos %s, mode %s" % [what, Time.get_ticks_msec(), Game.state_name(),
		Engine.get_frames_per_second(), kit.main.player.global_position, kit.main.player.mode_name()])


func _wait_wall(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await wait_frames(1)


func test_desktop_game_end_to_end() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	check(not m.ui.vr_mode, "desktop UI")
	await _wait_wall(500)
	await _shot("menu")
	await _mouse_click(kit.button(&"main", &"play"))
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "Play by mouse")
	await kit.advance(1.5)
	await _shot("play_lesson")
	_key(KEY_SPACE, true)
	await kit.advance(4.0)
	await _shot("flap_climb")
	_key(KEY_SPACE, false)
	_key(KEY_D, true)
	await kit.advance(1.5)
	await _shot("bank_right")
	_key(KEY_D, false)
	_key(KEY_W, true)
	await kit.advance(2.0)
	await _shot("tilt_dive")
	_key(KEY_W, false)
	_step("space 3 s")
	_key(KEY_SPACE, true)
	await kit.advance(3.0)
	_key(KEY_SPACE, false)
	_step("escape")
	_key(KEY_ESCAPE, true)
	await wait_frames(2)
	_key(KEY_ESCAPE, false)
	eq(Game.state, Game.State.PAUSED, "Escape pauses")
	_step("paused")
	await _wait_wall(400)
	_step("paused+400ms")
	await _shot("pause")
	await _mouse_click(kit.button(&"pause", &"resume"))
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0), "resume by mouse")
	# A hawk's strike: the caught screen.
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	var n := kit.count("player_caught")
	kit.stage_strike(&"hawk", 25.0, 12.0)
	var hit := await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 8.0)
	kit.free_staged()
	check(hit, "a hawk caught the player")
	await kit.frames(10)
	await _shot("caught")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 1.0)
	await kit.advance(0.5)
	await _shot("respawned")
	m.game_loop.end_run(&"caught")
	await kit.frames(10)
	await _wait_wall(400)
	await _shot("summary")
	await _mouse_click(kit.button(&"summary", &"again"))
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "Fly again by mouse")
	await kit.advance(1.0)
	await _shot("fly_again")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings: %s" % kit.log.summary())
