extends TestCase
## Round-3 engineering verifier probe (not part of the suites): the longest
## frame (wall clock, headless, one tick per frame) around the moments that
## build content the first time in a session - the first caught screen and
## respawn, the first run summary, Fly again - and the same moments a second
## time. In a headset a long frame there is a visible hitch. Only Play is
## measured by the suite (game_flow_test: < 250 ms).
##
##   tools/gd.sh r3e_probe --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r3eng_hitch --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var _prev := 0
var _max := 0
var _max_state := ""
var rows: Array = []


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _tick() -> void:
	var now := Time.get_ticks_usec()
	if _prev > 0 and now - _prev > _max:
		_max = now - _prev
		_max_state = "%s/%s" % [Game.state_name(), String(kit.screen())]
	_prev = now


func _phase(name: String) -> void:
	rows.append({"phase": name, "longest_ms": snappedf(_max / 1000.0, 0.1), "at": _max_state})
	print("[r3eng] %-34s longest frame %6.1f ms (%s)" % [name, _max / 1000.0, _max_state])
	_max = 0
	_prev = 0


func _die(pred: StringName) -> void:
	var m := kit.main
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	kit.fly_straight()
	await kit.advance(1.0)
	_max = 0
	_prev = 0
	var n := kit.count("player_caught")
	kit.stage_strike(pred, 40.0, 25.0)
	await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 10.0)
	kit.free_staged()
	await kit.wait_until(func() -> bool: return Game.state != Game.State.CAUGHT, GameLoop.CAUGHT_BEAT_S + 2.0)
	await kit.advance(1.0)


func _run_once(tag: String) -> void:
	var m := kit.main
	m.game_loop._set_player_mass(m.player, SizeRules.species_data(&"crow")["mass"] * 1.02, &"probe")
	await kit.advance(3.0)
	await _die(&"eagle")
	_phase("%s: death 1 (caught, respawn)" % tag)
	await _die(&"eagle")
	_phase("%s: death 2" % tag)
	await _die(&"eagle")
	await kit.frames(10)
	_phase("%s: death 3 -> run summary" % tag)
	check(Game.state == Game.State.ENDED, "%s: the run ended" % tag)
	check(await kit.click(&"summary", &"again"), "%s: Fly again" % tag)
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	await kit.advance(2.0)
	_phase("%s: Fly again" % tag)


func test_first_time_content_hitches() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	m.get_tree().process_frame.connect(_tick)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(43)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	await kit.advance(2.0)
	_max = 0
	_prev = 0
	await kit.advance(5.0)
	_phase("baseline flight 5 s")
	await _run_once("first run")
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	await _run_once("second run")
	m.get_tree().process_frame.disconnect(_tick)
	metric("hitches", rows)
