extends TestCase
## Foundation contracts: size ladder, registry, game state machine.


func test_size_ladder_is_ordered() -> void:
	var prev_mass := 0.0
	var prev_span := 0.0
	for s in SizeRules.SPECIES:
		gt(s["mass"], prev_mass, "species %s heavier than the previous" % s["id"])
		gt(s["span"], prev_span, "species %s wider than the previous" % s["id"])
		prev_mass = s["mass"]
		prev_span = s["span"]


func test_wingspan_matches_species_at_species_mass() -> void:
	for s in SizeRules.SPECIES:
		near(SizeRules.wingspan_for_mass(s["mass"]), s["span"], 0.001, "%s span" % s["id"])
		eq(SizeRules.species_for_mass(s["mass"]), s["id"], "species at own mass")


func test_eat_rule() -> void:
	check(SizeRules.can_eat(1.0, 0.5), "double mass eats")
	check(not SizeRules.can_eat(1.0, 0.9), "near-equal cannot eat")
	check(not SizeRules.can_eat(0.5, 1.0), "smaller cannot eat larger")


func test_registry_tracks_birds() -> void:
	var n0 := Birds.count()
	var a := Bird.new()
	var b := Bird.new()
	a.mass = 1.0
	b.mass = 0.1
	add_child(a)
	add_child(b)
	b.position = Vector3(3, 0, 0)
	eq(Birds.count(), n0 + 2, "two birds registered")
	eq(Birds.nearby(Vector3.ZERO, 5.0, a).size(), 1, "one neighbour within 5 m")
	eq(Birds.nearest(Vector3.ZERO, 10.0, func(x: Bird) -> bool: return a.can_eat(x), a), b, "a finds b edible")
	a.queue_free()
	b.queue_free()
	await wait_frames(1)
	eq(Birds.count(), n0, "unregistered on exit")


func test_game_state_machine() -> void:
	var seen := []
	var cb := func(n: int, o: int) -> void: seen.append([n, o])
	Events.game_state_changed.connect(cb)
	Game.set_state(Game.State.MENU)
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(get_tree().paused, "paused state pauses the tree")
	Game.set_state(Game.State.PLAYING)
	check(not get_tree().paused, "playing unpauses")
	Events.game_state_changed.disconnect(cb)
	eq(seen.size(), 4, "four transitions signalled")


func test_async_test_supported() -> void:
	var f0 := Engine.get_physics_frames()
	await wait_physics(3)
	gt(Engine.get_physics_frames() - f0, 2, "awaited physics frames")
