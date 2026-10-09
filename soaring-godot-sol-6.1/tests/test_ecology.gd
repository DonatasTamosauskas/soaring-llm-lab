extends SceneTree
const Ecosystem = preload("res://scripts/ecology/ecosystem.gd")
const Species = preload("res://scripts/ecology/species.gd")

class MockPlayer extends Node3D:
	var mass := 1.0
	var velocity := Vector3.ZERO
	func set_mass(value: float) -> void:
		mass = value

class MockWorld extends Node3D:
	var waypoints: Array[Vector3] = [Vector3(0, 22, 15), Vector3(35, 26, -35), Vector3(-40, 16, -15), Vector3(-20, 35, 50), Vector3(50, 32, 50)]
	var perch_points: Array[Vector3] = [Vector3(20, 15, 20), Vector3(-25, 20, -25)]
	var flight_bounds := AABB(Vector3(-180, 3, -180), Vector3(360, 102, 360))
	func thermal_at(position: Vector3) -> float:
		return 3.0 if Vector2(position.x, position.z).length() < 18.0 else 0.0

var failures: Array[String] = []
var checks := 0
var ecosystem: Node3D
var player: Node3D
var world: Node3D
var death_count := 0
var grow_count := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error("FAIL: " + description)

func _run() -> void:
	check(not Species.can_catch(1.0, 1.0), "Equal birds cannot consume one another")
	check(not Species.can_catch(1.179, 1.0), "Size ratio below threshold cannot consume")
	check(Species.can_catch(1.18, 1.0), "Size ratio at threshold can consume")
	check(Species.reward(8.0, 0.38) == 0.0, "Tiny prey provide no late-game growth")
	check(Species.reward(4.0, 0.78) < Species.reward(1.0, 0.78), "Prey relevance diminishes with growth")
	check(Species.reward(1.0, 1.0) == 0.0, "Ineligible prey provide no rewards")
	check(Species.tier_name(0.38) == "Wren" and Species.tier_name(1.0) == "Swift", "Small tiers are named correctly")
	check(Species.tier_name(1.65) == "Kite" and Species.tier_name(3.35) == "Eagle" and Species.tier_name(8.0) == "Sovereign", "Growth crosses every tier")
	check(Ecosystem.swept_distance(Vector3(-10, 0, 0), Vector3(10, 0, 0), Vector3.ZERO, Vector3.ZERO) < 0.01, "Swept catch detects fast crossing")
	check(Ecosystem.swept_distance(Vector3(-10, 2, 0), Vector3(10, 2, 0), Vector3.ZERO, Vector3.ZERO) > 1.9, "Swept near miss remains a miss")
	check(is_equal_approx(Ecosystem.swept_distance(Vector3.ZERO, Vector3(5, 0, 0), Vector3(0, 4, 0), Vector3(5, 4, 0)), 4.0), "Parallel relative movement is stable")
	player = MockPlayer.new()
	world = MockWorld.new()
	ecosystem = Ecosystem.new()
	root.add_child(world)
	root.add_child(player)
	root.add_child(ecosystem)
	player.position = Vector3(0, 18, 64)
	ecosystem.configure(player, world)
	ecosystem.player_caught.connect(func(_tier: String) -> void: death_count += 1)
	ecosystem.player_grew.connect(func(_mass: float, _tier: String) -> void: grow_count += 1)
	await physics_frame
	check(ecosystem.birds.size() == 54 and ecosystem.get_stats()["population"] == 54, "Population starts at 54")
	check(ecosystem.grace_remaining == 8.0, "New run receives eight seconds protection")
	var nearby_prey := 0
	var predators_clear := true
	for bird in ecosystem.birds:
		if bird.global_position.distance_to(player.global_position) < 31.0 and Species.can_catch(Ecosystem.START_MASS, bird.mass):
			nearby_prey += 1
		if Species.can_catch(bird.mass, Ecosystem.START_MASS) and bird.global_position.distance_to(player.global_position) < 60.0:
			predators_clear = false
	check(nearby_prey >= 6, "First chase has approachable prey")
	check(predators_clear, "Initial predators spawn away from player")
	check(not ecosystem.get_stats()["nearest_prey"].is_empty(), "UI receives nearest useful prey")
	check(not ecosystem.get_stats()["nearest_danger"].is_empty(), "UI receives nearest predator")
	_suspend_all()
	var prey = ecosystem.birds[0]
	_activate_at(prey, player.global_position, 0.38)
	ecosystem.previous_player_position = player.global_position
	ecosystem._resolve_catches()
	check(ecosystem.catches == 1 and ecosystem.player_mass > 0.7, "Player catch grows the player")
	check(not prey.alive and grow_count == 1 and player.mass == ecosystem.player_mass, "Catch signal and flight mass remain synchronized")
	check(ecosystem.get_progress() > 0.0, "Progress reflects growth")
	_activate_at(prey, player.global_position, 3.35)
	ecosystem._resolve_catches()
	check(not ecosystem.player_dead and death_count == 0, "Predator contact respects spawn protection")
	ecosystem.grace_remaining = 0.0
	ecosystem._resolve_catches()
	check(ecosystem.player_dead and death_count == 1 and not ecosystem.active, "Eligible predator catches unprotected player once")
	ecosystem.simulate(0.05)
	check(death_count == 1, "Death is emitted only once")
	ecosystem.reset_run()
	check(ecosystem.catches == 0 and ecosystem.player_mass == Ecosystem.START_MASS and not ecosystem.player_dead and ecosystem.birds.size() == 54, "Reset restores population and progress")
	check(ecosystem.get_player_tier() == "Wren" and ecosystem.get_progress() == 0.0, "Player starts as a Wren with zero progress")
	check(ecosystem.get_child_count() == 54, "Reset does not leak previous bird nodes")
	_suspend_all()
	var hunter = ecosystem.birds[20]
	prey = ecosystem.birds[0]
	_activate_at(hunter, Vector3(0, 24, 0), 0.78)
	_activate_at(prey, Vector3(0, 24, -4), 0.38)
	ecosystem._sense(prey)
	check(prey.state == "Flee" and prey.target == hunter, "NPC prey detect NPC predators")
	check(prey.desired_direction.dot(prey.global_position - hunter.global_position) > 0.0, "Prey steer away from their predator")
	ecosystem._sense(hunter)
	check(hunter.state == "Hunt" and hunter.target == prey, "NPCs hunt smaller NPCs")
	check(Species.cruise_speed(prey.mass) * 1.24 > Species.cruise_speed(hunter.mass) * 1.12, "Escape speed makes pursuit escapable")
	hunter.previous_position = Vector3(0, 24, 4)
	hunter.global_position = Vector3(0, 24, -8)
	prey.previous_position = Vector3(0, 24, -4)
	ecosystem._resolve_catches()
	check(ecosystem.npc_catches == 1 and hunter.mass > 0.78 and not prey.alive, "Swept NPC-to-NPC capture feeds hunter")
	check(hunter.catch_cooldown > 0.0, "NPC catch cooldown prevents instant chain feeding")
	prey.respawn_remaining = 0.01
	ecosystem.simulate(0.02)
	check(prey.alive and prey.mass == prey.slot_mass, "Consumed NPC respawns at original tier")
	check(prey.global_position.distance_to(player.global_position) >= 60.0, "Respawns occur at a distant position")
	check(prey.protection_remaining > 0.0, "Respawn has invulnerability")
	_suspend_all()
	_activate_at(prey, Vector3(20, 15, 19), 0.38)
	prey.state = "Approach perch"
	prey.perch_point = Vector3(20, 15, 20)
	prey.state_remaining = 12.0
	prey.sense_remaining = 0.0
	for _frame in 40:
		ecosystem.simulate(0.05)
	check(prey.state == "Perch" and prey.velocity.length() < 0.1, "Bird approaches a perch and rests")
	_activate_at(hunter, Vector3(20, 15, 24), 0.78)
	ecosystem._sense(prey)
	check(prey.state == "Flee", "Perched bird launches to evade a threat")
	_suspend_all()
	_activate_at(prey, Vector3(0, 24, 0), 0.38)
	prey.state = "Cruise"
	prey.state_remaining = 4.0
	prey.waypoint = Vector3(0, 25, -10)
	ecosystem._sense(prey)
	check(prey.state == "Soar" and prey.desired_direction.y > 0.0, "Bird uses thermal lift without flapping")
	var obstacle := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4, 5, 1)
	collision.shape = shape
	obstacle.add_child(collision)
	root.add_child(obstacle)
	obstacle.position = Vector3(0, 24, -4)
	prey.velocity = Vector3(0, 0, -10)
	prey.state = "Cruise"
	await physics_frame
	var avoidance: Vector3 = ecosystem._obstacle_avoidance(prey)
	check(avoidance.z > 0.0 and avoidance.y > 0.0, "Obstacle rays steer away and above solid geometry")
	prey.velocity = Vector3.UP * 10.0
	prey.update_visual(0.05, ecosystem.player_mass, player.global_position)
	check(prey.quaternion.is_finite(), "Vertical flight retains a finite visual orientation")
	check(not ecosystem._spawn_clear(Vector3(0, 24, -4), prey.radius), "Spawn clearance rejects solid geometry")
	prey.global_position = Vector3(0, 24, -3.4)
	prey.previous_position = prey.global_position
	prey.velocity = Vector3(0, 0, -14)
	prey.desired_direction = Vector3.FORWARD
	prey.obstacle_remaining = 1.0
	prey.obstacle_steer = Vector3.ZERO
	ecosystem._move_bird(prey, 0.1)
	check(prey.global_position.z > -3.5, "Swept world collision prevents crossing a solid wall")
	_suspend_all()
	shape.size = Vector3(4, 5, 0.2)
	_activate_at(hunter, Vector3(0, 24, -3.7), 0.78)
	_activate_at(prey, Vector3(0, 24, -4.3), 0.38)
	await physics_frame
	var wall_catches: int = ecosystem.npc_catches
	ecosystem._resolve_catches()
	check(prey.alive and ecosystem.npc_catches == wall_catches, "Solid wall blocks a catch through geometry")
	obstacle.free()
	ecosystem.active = false
	var paused_elapsed: float = ecosystem.elapsed
	ecosystem._physics_process(0.05)
	check(ecosystem.elapsed == paused_elapsed, "Paused ecology does not advance")
	ecosystem.set_active(true)
	ecosystem._physics_process(0.05)
	check(ecosystem.elapsed > paused_elapsed, "Ecology resumes with the game")
	ecosystem.set_active(false)
	_suspend_all()
	ecosystem.player_mass = 7.9
	_activate_at(prey, player.global_position, 6.5)
	ecosystem.previous_player_position = player.global_position
	ecosystem._resolve_catches()
	check(ecosystem.crowned and ecosystem.get_progress() == 1.0 and ecosystem.get_player_tier() == "Sovereign", "Final relevant catch earns the crown and endless play")
	_suspend_all()
	ecosystem.player_mass = Ecosystem.START_MASS
	ecosystem.crowned = false
	ecosystem.catches = 0
	var visited_tiers: Dictionary = {"Wren": true}
	for _step in 30:
		var best_mass := 0.38
		for tier in Species.TIERS:
			if Species.can_catch(ecosystem.player_mass, tier["mass"]):
				best_mass = tier["mass"]
		_activate_at(prey, player.global_position, best_mass)
		ecosystem._resolve_catches()
		visited_tiers[ecosystem.get_player_tier()] = true
		if ecosystem.crowned:
			break
	check(ecosystem.crowned and ecosystem.catches <= 22, "Crown is reachable with a practical sequence of relevant catches")
	check(visited_tiers.size() == 5, "Full progression visits all five bird tiers")
	var final_catches: int = ecosystem.catches
	_activate_at(prey, player.global_position, 0.38)
	ecosystem._resolve_catches()
	check(prey.alive and ecosystem.catches == final_catches, "Large player ignores the smallest birds")
	ecosystem.reset_run()
	ecosystem.grace_remaining = 1000.0
	var minimum_population := 54
	var max_speed := 0.0
	var states: Dictionary = {}
	var finite_motion := true
	var bounded_motion := true
	var started := Time.get_ticks_msec()
	for frame in 3600:
		ecosystem.simulate(1.0 / 30.0)
		if frame % 30 == 0:
			minimum_population = mini(minimum_population, ecosystem.get_stats()["population"])
			for bird in ecosystem.birds:
				states[bird.state] = true
				if not bird.alive:
					continue
				var p: Vector3 = bird.global_position
				finite_motion = finite_motion and p.is_finite() and bird.velocity.is_finite()
				bounded_motion = bounded_motion and Vector2(p.x, p.z).length() <= 180.01 and p.y >= 2.99 and p.y <= 105.01
				max_speed = maxf(max_speed, bird.velocity.length())
		if frame % 180 == 0:
			await process_frame
	check(finite_motion and bounded_motion, "Two-minute simulation stays finite and inside flight bounds")
	check(ecosystem.npc_catches > 4, "Natural food web produces multiple NPC captures")
	check(ecosystem.get_stats()["population"] >= 40 and minimum_population >= 36, "Respawn maintains a healthy population")
	check(states.has("Hunt") and states.has("Flee") and states.has("Cruise") and states.has("Soar"), "Natural flock exhibits hunting, fleeing, cruising and thermals")
	check(max_speed < 18.0, "NPC velocity remains bounded")
	print("ECOLOGY EVIDENCE: checks=%d failures=%d natural_catches=%d population_min=%d population_final=%d maximum_speed=%.2f states=%s simulation_ms=%d" % [checks, failures.size(), ecosystem.npc_catches, minimum_population, ecosystem.get_stats()["population"], max_speed, str(states.keys()), Time.get_ticks_msec() - started])
	ecosystem.free()
	world.free()
	player.free()
	if "--real-world" in OS.get_cmdline_user_args():
		await _test_actual_world()
	quit(0 if failures.is_empty() else 1)

func _test_actual_world() -> void:
	var world_script: Script = load("res://scripts/world/world.gd")
	if world_script == null:
		check(false, "Actual world script is available for integration checks")
		return
	var actual_world: Node3D = world_script.new()
	var actual_player := MockPlayer.new()
	var actual_ecology := Ecosystem.new()
	root.add_child(actual_world)
	root.add_child(actual_player)
	root.add_child(actual_ecology)
	actual_player.position = actual_world.get("spawn_position")
	await physics_frame
	actual_ecology.configure(actual_player, actual_world)
	actual_ecology.grace_remaining = 1000.0
	var clear_spawns := true
	for bird in actual_ecology.birds:
		clear_spawns = clear_spawns and actual_ecology._spawn_clear(bird.global_position, bird.radius)
	check(clear_spawns, "Actual-world bird spawns clear terrain and solid geometry")
	var underground_samples := 0
	var observed_states: Dictionary = {}
	var started := Time.get_ticks_msec()
	for frame in 3600:
		actual_ecology.simulate(1.0 / 30.0)
		if frame % 30 == 0:
			for bird in actual_ecology.birds:
				if not bird.alive:
					continue
				observed_states[bird.state] = true
				var position: Vector3 = bird.global_position
				if position.y < float(actual_world.call("terrain_height", position.x, position.z)) - 0.5:
					underground_samples += 1
		if frame % 180 == 0:
			await process_frame
	check(underground_samples == 0, "Actual-world birds remain above the landscape over two minutes")
	check(actual_ecology.npc_catches > 0, "Actual-world birds capture other NPCs")
	check(actual_ecology.get_stats()["population"] >= 48, "Actual-world population replenishes")
	check(observed_states.size() == 6, "Actual-world flock uses all six behavior states")
	print("ECOLOGY WORLD EVIDENCE: checks=%d failures=%d underground_samples=%d npc_captures=%d population=%d states=%s simulation_ms=%d" % [checks, failures.size(), underground_samples, actual_ecology.npc_catches, actual_ecology.get_stats()["population"], str(observed_states.keys()), Time.get_ticks_msec() - started])
	actual_ecology.free()
	actual_player.free()
	actual_world.free()

func _suspend_all() -> void:
	for bird in ecosystem.birds:
		bird.alive = false
		bird.visible = false
		bird.respawn_remaining = 1000.0

func _activate_at(bird: Node3D, position: Vector3, mass: float) -> void:
	bird.alive = true
	bird.visible = true
	bird.protection_remaining = 0.0
	bird.catch_cooldown = 0.0
	bird.set_mass(mass)
	bird.global_position = position
	bird.previous_position = position
	bird.velocity = Vector3.ZERO
