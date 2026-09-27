extends TestCase
## The player's spawn perch is the player's (integration round 1; the
## engineering verifier confirmed: an NPC sitting on it at a respawn left
## the player hovering beside it - PlayerBird perches only on a free perch).
## In the shipped valley the AI's perch search (Habitat.find_perches, every
## NPC perch choice goes through it) never offers it, while the world still
## lists it; and over a minute of the real sky round the spawn no NPC sits
## on it.

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


func test_no_npc_takes_the_spawn_perch() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var spawn := m.world.get_player_spawn().origin
	var perch: Perch = null
	for p in m.world.get_perches():
		if p.position.distance_to(spawn) < 0.05:
			perch = p
	check(perch != null, "(setup) the world has a perch at the spawn")
	# A minute of the real sky round the spawn, the player away flying.
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(7)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	check(perch != null and perch.is_free(), "(setup) the player has left it")
	var listed := false
	for p in m.world.find_perches(spawn, 1.0, 0.05):
		listed = listed or p == perch
	check(listed, "the world still lists it as a free perch")
	var offered := false
	for p in Habitat.for_world(m.world).find_perches(spawn, 5.0, 0.05):
		offered = offered or p == perch
	check(not offered, "the AI's perch search never offers it")
	var taken := 0
	for i in 60:
		await kit.advance(1.0)
		if perch != null and not perch.is_free() and perch.occupant != m.player:
			taken += 1
	eq(taken, 0, "no NPC sat on the spawn perch in 60 s")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
