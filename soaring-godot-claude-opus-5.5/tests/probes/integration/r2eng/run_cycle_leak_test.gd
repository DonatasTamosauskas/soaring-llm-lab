extends TestCase
## PROBE (round-2 engineering verifier): where does the soak's creep come from?
## The builders' soak (tests/soak) measured ~4 objects and ~0.05 MB more at
## every whole run's start (victory, summary, Fly again, menus), plain
## restarts flat. This repeats ONE kind of run end many times, fast, in the
## real main.tscn, and prints nodes / objects / static memory at the same
## moment of every run (a new run, 3 s of flight):
##
##   --variant=victory  grow through every tier (GameLoop's own mass path:
##                      tier-up events, toasts), apex victory (end_run), the
##                      victory summary, Fly again (the pointer)
##   --variant=caught   the run ends by end_run(&"caught"), the summary, Fly again
##   --variant=grow     grow through every tier, then Restart run from pause
##   --variant=menu     Quit to menu from pause, then Play again
##
##   tools/gd.sh v2e_leak --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/integration/r2eng --suite=run_cycle_leak --fresh-settings --variant=victory [--cycles=10]
##
## Writes artifacts/integration/verify/r2eng/leak_<variant>.json.

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


func _grow_all() -> void:
	var m := kit.main
	var p := m.player
	for sd in SizeRules.SPECIES:
		var sm: float = sd["mass"]
		if sm <= p.mass:
			continue
		m.game_loop.call(&"_set_player_mass", p, sm * 1.02, &"meal")
		await kit.advance(1.2)


func _sample(i: int) -> Dictionary:
	return {"i": i, "nodes": kit.nodes(), "objects": kit.objects(), "orphans": kit.orphans(),
		"mem_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.001), "npcs": kit.main.ecosystem.count(),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))}


func test_repeat_one_run_end() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var variant := Paths.arg("variant", "victory")
	var cycles := int(Paths.arg("cycles", "10"))
	m.ui.onboarding.skip()
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	var rows := []
	for c in cycles:
		kit.fly_bot(11)
		m.game_loop.set_protection(m.player, 1e6)
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		rows.append(_sample(c))
		match variant:
			"victory":
				await _grow_all()
				m.game_loop.stats.victory = true
				m.game_loop.end_run(&"victory")
				await kit.advance(3.0)
				await kit.frames(3)
				check(await kit.click(&"summary", &"again"), "Fly again (%d)" % c)
			"caught":
				m.game_loop.end_run(&"caught")
				await kit.advance(3.0)
				await kit.frames(3)
				check(await kit.click(&"summary", &"again"), "Fly again (%d)" % c)
			"grow":
				await _grow_all()
				Events.menu_requested.emit()
				await kit.frames(3)
				check(await kit.hold(&"pause", &"restart"), "Restart (%d)" % c)
			"screens":
				# The soak's pause-menu tour: Settings and back, How to fly and back, resume.
				Events.menu_requested.emit()
				await kit.frames(3)
				for pair: Array in [[&"pause", &"settings"], [&"settings", &"back"], [&"pause", &"howto"], [&"howto", &"back"]]:
					await kit.click(pair[0], pair[1])
					await kit.frames(3)
				var tw := Time.get_ticks_msec()
				while Time.get_ticks_msec() - tw < 300:
					await kit.frames(1)
				Events.menu_requested.emit()
				await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0)
				await kit.advance(2.0)
			"catches":
				# A moth placed at the beak: the real catch rule, growth, a feather burst.
				var p := m.player
				var fwd := p.get_forward()
				kit.stage_bird(&"moth", p.get_body_position() + fwd * 0.15, -fwd)
				await kit.advance(0.5)
				kit.free_staged()
				await kit.advance(3.0)
			"deaths":
				m.game_loop.set_protection(m.player, 0.0)
				kit.fly_straight()
				kit.stage_strike(&"hawk", 30.0, 12.0)
				var nd := kit.count("player_caught")
				await kit.wait_until(func() -> bool: return kit.count("player_caught") > nd, 8.0)
				kit.free_staged()
				await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 2.0)
				await kit.advance(1.0)
				if Game.state == Game.State.ENDED or int(kit.stats()["lives"]) < 2:
					m.game_loop.lives = GameLoop.MAX_LIVES
			"menu":
				Events.menu_requested.emit()
				await kit.frames(3)
				check(await kit.hold(&"pause", &"quit_menu"), "Quit to menu (%d)" % c)
				await kit.wait_until(func() -> bool: return Game.state == Game.State.MENU, 2.0)
				await kit.frames(5)
				check(await kit.click(&"main", &"play"), "Play (%d)" % c)
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(11)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	rows.append(_sample(cycles))
	for r in rows:
		print("[r2eng] leak %s %s" % [variant, r])
	var n := rows.size()
	# Slope over the second half (first-time content excluded).
	var a: Dictionary = rows[n / 2]
	var b: Dictionary = rows[n - 1]
	var k := float(n - 1 - n / 2)
	var res := {"variant": variant, "rows": rows,
		"objects_per_run": (float(b["objects"]) - float(a["objects"])) / k,
		"nodes_per_run": (float(b["nodes"]) - float(a["nodes"])) / k,
		"resources_per_run": (float(b["resources"]) - float(a["resources"])) / k,
		"mem_kb_per_run": (float(b["mem_mb"]) - float(a["mem_mb"])) * 1024.0 / k}
	print("[r2eng] leak %s slope (second half): %s" % [variant, {"objects": res["objects_per_run"], "nodes": res["nodes_per_run"],
		"resources": res["resources_per_run"], "mem_kb": res["mem_kb_per_run"]}])
	var dir := Paths.artifacts("integration").path_join("verify/r2eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("leak_%s.json" % variant), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
