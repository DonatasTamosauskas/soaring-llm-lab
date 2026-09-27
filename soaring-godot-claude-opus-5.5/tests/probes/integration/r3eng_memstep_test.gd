extends TestCase
## Round-3 engineering verifier probe (not part of the suites): where does
## the soak's one-time +2 MB static-memory step come from? In the soaks it
## lands in the 30 s window of a run's natural death at a large size (crow
## -> gull, pigeon -> crow). This plays one run and records every frame's
## Performance.MEMORY_STATIC, reporting each jump > 0.25 MB with the game's
## state and the last events, around grow-ups and deaths at several sizes.
##
##   tools/gd.sh r3e_probe --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r3eng_memstep --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var _last_mem := 0.0
var _events: Array[String] = []
var jumps: Array = []


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _ev(name: String) -> Callable:
	return func(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
		_events.append("%s@%.2f" % [name, Game.run_time])
		if _events.size() > 12:
			_events.pop_front()


func _watch() -> void:
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	if _last_mem > 0.0 and mem - _last_mem > 0.25:
		var j := {"mb": snappedf(mem - _last_mem, 0.001), "at": snappedf(mem, 0.01), "state": Game.state_name(),
			"species": kit.main.player.species, "screen": String(kit.screen()), "events": _events.duplicate()}
		jumps.append(j)
		print("[r3eng] memory jump ", JSON.stringify(j))
	_last_mem = mem


func _mem() -> float:
	return Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0


func _grow_to(species: StringName) -> void:
	var m := kit.main
	var target: float = SizeRules.species_data(species)["mass"] * 1.02
	m.game_loop._set_player_mass(m.player, target, &"probe")
	await kit.advance(4.0)


func _die_by(pred: StringName) -> bool:
	var m := kit.main
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	# (the loop's respite: nothing hunts a protected player; the staged strike is scripted)
	kit.fly_straight()
	await kit.advance(1.0)
	var n := kit.count("player_caught")
	var t0 := _mem()
	kit.stage_strike(pred, 40.0, 25.0)
	var ok := await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 10.0)
	kit.free_staged()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 2.0)
	await kit.advance(2.0)
	print("[r3eng] death by %s as %s: caught %s, memory %+.3f MB (now %.2f)" % [pred, kit.main.player.species, ok, _mem() - t0, _mem()])
	return ok


func test_memory_steps_around_growth_and_deaths() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	for sig in ["player_caught", "player_tier_changed", "run_started", "run_ended", "player_spawned", "game_state_changed"]:
		Events.connect(sig, _ev(sig))
	m.get_tree().process_frame.connect(_watch)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(41)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	print("[r3eng] start %.2f MB" % _mem())
	# Up the ladder, a death at each large size (the soak's steps were at a
	# natural death as a crow / pigeon).
	var plan := [[&"starling", &"hawk"], [&"pigeon", &"hawk"], [&"crow", &"eagle"], [&"gull", &"eagle"], [&"crow", &"gull"], [&"pigeon", &"crow"]]
	for step: Array in plan:
		if Game.state == Game.State.ENDED:
			var te := _mem()
			await kit.frames(3)
			m.ui.bridge.start_run()
			await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
			kit.set_mode(&"climb")
			await kit.advance(3.0)
			kit.set_mode(&"cruise")
			print("[r3eng] run ended; new run: memory %+.3f MB (now %.2f)" % [_mem() - te, _mem()])
		var t0 := _mem()
		await _grow_to(step[0])
		print("[r3eng] grew to %s: memory %+.3f MB (now %.2f)" % [step[0], _mem() - t0, _mem()])
		await _die_by(step[1])
	m.get_tree().process_frame.disconnect(_watch)
	print("[r3eng] jumps: ", JSON.stringify(jumps))
	metric("jumps", jumps)
	check(true, "probe ran")
