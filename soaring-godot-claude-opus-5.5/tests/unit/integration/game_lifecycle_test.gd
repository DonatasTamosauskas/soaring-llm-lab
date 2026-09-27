extends TestCase
## The whole game comes and goes cleanly: boot it, play, free it, boot it
## again. Nothing of a freed game may stay behind (birds in the registry,
## orphan nodes, a growing object count), and a second boot in the same
## process works (static caches: bird meshes, the audio bank, the AI's
## habitat, the UI theme).

const Kit := preload("res://tests/unit/integration/game_kit.gd")


func _play_a_little(kit: Kit) -> void:
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(5)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	await kit.advance(3.0)


func test_boot_play_free_twice() -> void:
	await wait_frames(5)
	var base := [_nodes(), _objects(), _orphans()]
	var after := []
	var load_ms := []
	for round_i in 2:
		var kit := Kit.new()
		check(await kit.boot(self), "boot %d" % round_i)
		if kit.main == null or not kit.main.is_loaded:
			return
		load_ms.append(kit.main.load_report["total_ms"])
		await _play_a_little(kit)
		eq(Game.state, Game.State.PLAYING, "playing (%d)" % round_i)
		gt(Birds.all().size(), 50, "birds registered while playing (%d)" % round_i)
		var errors: int = kit.log.errors
		var warnings: int = kit.log.warnings
		var summary: String = kit.log.summary()
		await kit.teardown()
		await wait_frames(10)
		eq(errors, 0, "no errors in round %d: %s" % [round_i, summary])
		eq(warnings, 0, "no warnings in round %d: %s" % [round_i, summary])
		eq(Birds.all().size(), 0, "no bird left in the registry after freeing the game (%d)" % round_i)
		eq(_orphans(), base[2], "no orphan nodes after freeing the game (%d)" % round_i)
		after.append([_nodes(), _objects()])
		if Game.state != Game.State.BOOT and Game.state != Game.State.MENU:
			Game.set_state(Game.State.MENU)
	print("[integration] lifecycle base %s after %s load %s" % [base, after, load_ms])
	eq(after[0][0], base[0], "node count back to the baseline")
	eq(after[1][0], base[0], "node count back to the baseline after the second game")
	# Objects: the first game builds process-wide caches (bird meshes, the
	# theme, the synthesized audio bank); a second game must not add more.
	lt(absf(after[1][1] - after[0][1]), 50.0, "a second game leaves no more objects behind than the first (%d vs %d)" % [after[1][1], after[0][1]])
	metric("objects_base", base[1])
	metric("objects_after", [after[0][1], after[1][1]])
	metric("load_ms", load_ms)


func _nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _objects() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))


func _orphans() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
