extends TestCase
## Round-3 engineering verifier probe (not part of the suites): does the
## pause menu's "Restart run" (held with the laser pointer, as a player
## does) really start a new run in the composed game? game_flow_test's
## restart test only waits for PLAYING and counts nodes/objects.
##
##   tools/gd.sh r3e_probe --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r3eng_restart --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _staged_catch(species: StringName) -> bool:
	var m := kit.main
	var c0: int = kit.stats()["catches"]
	var a0: float = m.game_loop.assist_override
	m.game_loop.assist_override = 1.0
	var ok := false
	for attempt in 4:
		kit.fly_straight()
		await kit.advance(1.5)
		var prey := kit.stage_prey(species, 30.0)
		for i in 40:
			await kit.advance(0.2)
			if int(kit.stats()["catches"]) > c0:
				ok = true
				break
			if not is_instance_valid(prey):
				break
		if ok:
			break
		if is_instance_valid(prey):
			kit.release(prey)
		kit.cruise()
	m.game_loop.assist_override = a0
	kit.cruise()
	return ok


func test_restart_run_starts_a_new_run() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(33)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	var caught := 0
	for i in 6:
		if await _staged_catch(&"wren"):
			caught += 1
		if SizeRules.tier_for_mass(m.player.mass) > SizeRules.tier_for_mass(GameLoop.START_MASS):
			break
	gt(float(caught), 0.5, "some catches before the restart (%d)" % caught)
	# A death (a life lost) before the restart.
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	kit.fly_straight()
	await kit.advance(1.0)
	var n := kit.count("player_caught")
	kit.stage_strike(&"hawk", 30.0, 12.0)
	await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 8.0)
	kit.free_staged()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 1.0)
	await kit.advance(5.0)
	var before := kit.stats().duplicate(true)
	var mass_before := m.player.mass
	var ws_before: float = m.player.origin.world_scale
	print("[r3eng] before restart: mass %.4f species %s lives %s catches %s caught %s run_time %.1f ws %.3f" % [
		mass_before, m.player.species, before["lives"], before["catches"], before["times_caught"], float(before["run_time"]), ws_before])
	check(int(before["catches"]) > 0 and int(before["lives"]) < GameLoop.MAX_LIVES, "a run with catches and a lost life")
	# Restart run from the pause menu, held with the pointer.
	Events.menu_requested.emit()
	await kit.frames(2)
	eq(kit.screen(), &"pause", "paused")
	var starts := kit.count("run_started")
	check(await kit.hold(&"pause", &"restart"), "held Restart run")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0), "playing again")
	await kit.advance(0.2)
	var st := kit.stats()
	print("[r3eng] after restart: mass %.4f species %s lives %s catches %s caught %s run_time %.2f ws %.3f" % [
		m.player.mass, m.player.species, st["lives"], st["catches"], st["times_caught"], float(st["run_time"]), m.player.origin.world_scale])
	eq(kit.count("run_started"), starts + 1, "one run_started")
	near(m.player.mass, GameLoop.START_MASS, 1e-6, "mass back to a sparrow's")
	eq(m.player.species, &"sparrow", "species sparrow")
	eq(st["lives"], GameLoop.MAX_LIVES, "full lives")
	eq(st["catches"], 0, "no catches")
	eq(st["times_caught"], 0, "never caught")
	lt(float(st["run_time"]), 1.0, "run clock restarted")
	check(m.player.global_position.distance_to(m.world.get_player_spawn().origin) < 1.0, "at the spawn")
	var want := WorldScaleDriver.target_scale(GameLoop.START_MASS, m.rig_extras.world_scale_driver.arm_span())
	near(m.player.origin.world_scale, want, 0.01 * want, "world_scale back to a sparrow's")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings: %s" % kit.log.summary())
