extends TestCase
## Water is not ground (integration round 1; the experience verifier's
## finding: gliding down onto the lake the bird went "grounded" at the
## water line and stood on it, eye at the water, the view half water - and
## once the simulator's bird ended up standing on the river).
##
## The real game in the shipped valley: the player placed 4 m over the lake
## with no input (the arms at rest: a glide down onto the water), for 12 s;
## then the bot flaps. Pinned: it meets the water (flight's "water"
## contacts), is never grounded, perched or stunned on it, never sinks under
## the surface, and flaps away from it.

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


func test_the_bird_splashes_off_water() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	var p := m.player
	var lake := Vector3(WorldLayout.LAKE.x, WorldLayout.WATER_Y, WorldLayout.LAKE.y)
	check(m.world.is_water(lake), "(setup) the lake's middle is water")
	check(not m.world.is_water(Vector3(-90.0, m.world.ground_height(-90.0, WorldLayout.STREET_Z), WorldLayout.STREET_Z)),
		"(setup) the village street is not")
	var c0: int = p.contacts["water"]
	# From the side of the lake, 4 m up, the arms at rest (a glide down).
	p.start_flying(lake + Vector3(-40.0, 4.0, 0.0), -PI / 2.0, 0.0)
	m.game_loop.teleported(p)
	var modes := {}
	var min_y := INF
	for i in int(12.0 * 72.0):
		await kit.advance(1.0 / 72.0)
		modes[p.mode_name()] = int(modes.get(p.mode_name(), 0)) + 1
		min_y = minf(min_y, p.global_position.y)
	var met: int = p.contacts["water"] - c0
	print("[integration] water: %d splashes, modes %s, lowest body %.2f (water line %.2f)" % [met, modes, min_y, WorldLayout.WATER_Y])
	gt(float(met), 0.5, "it met the water (%d splashes)" % met)
	eq(int(modes.get("grounded", 0)) + int(modes.get("perched", 0)), 0, "never grounded or perched on the water (%s)" % modes)
	eq(int(modes.get("stunned", 0)), 0, "never stunned by it")
	gt(min_y, WorldLayout.WATER_Y - 0.05, "never under the surface (lowest %.2f)" % min_y)
	# Flap away.
	var y0 := p.global_position.y
	kit.fly_bot(3)
	kit.set_mode(&"climb")
	await kit.advance(5.0)
	gt(p.global_position.y - y0, 3.0, "flaps away from the water (%.1f m up in 5 s)" % (p.global_position.y - y0))
	eq(p.mode_name(), "flying", "flying")
	metric("water", {"splashes": met, "modes": modes, "lowest": min_y})
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
