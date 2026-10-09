extends Node3D
## Dynamic food web. Every bird uses the same size rule as the player.
const Species = preload("res://scripts/ecology/species.gd")
const BirdActor = preload("res://scripts/ecology/bird_actor.gd")
const POPULATION := 54
const SPAWN_COUNTS := [18, 14, 10, 8, 4]
const PLAYER_PROTECTION := 8.0
const SENSE_INTERVAL := 0.18
const START_MASS := 0.6

signal player_grew(mass: float, tier: String)
signal player_caught(predator: String)
signal catch_event(position: Vector3, mass: float)
signal ecosystem_event(message: String)

var player_mass := START_MASS
var catches := 0
var elapsed := 0.0
var birds: Array = []
var grace_remaining := PLAYER_PROTECTION
var npc_catches := 0
var active := false
var player: Node3D
var world: Node3D
var bounds := AABB(Vector3(-180, 3, -180), Vector3(360, 102, 360))
var radius_limit := 180.0
var rng := RandomNumberGenerator.new()
var previous_player_position := Vector3.ZERO
var player_dead := false
var crowned := false
var _visual_clock := 0.0
var _world_has_thermal := false
var _world_has_terrain := false

func configure(player_node: Node3D, world_node: Node3D) -> void:
	player = player_node
	world = world_node
	_world_has_thermal = world != null and world.has_method("thermal_at")
	_world_has_terrain = world != null and world.has_method("terrain_height")
	if world != null and _has_property(world, "flight_bounds"):
		bounds = world.get("flight_bounds")
		radius_limit = minf(bounds.size.x, bounds.size.z) * 0.5
	reset_run()

func reset_run() -> void:
	active = false
	for bird in birds:
		bird.free()
	birds.clear()
	rng.seed = 738291
	player_mass = START_MASS
	catches = 0
	elapsed = 0.0
	npc_catches = 0
	grace_remaining = PLAYER_PROTECTION
	player_dead = false
	crowned = false
	for tier in SPAWN_COUNTS.size():
		for _slot in SPAWN_COUNTS[tier]:
			var bird := BirdActor.new()
			bird.index = birds.size()
			bird.name = "%s_%02d" % [Species.TIERS[tier]["name"], bird.index]
			bird.slot_mass = float(Species.TIERS[tier]["mass"])
			add_child(bird)
			birds.append(bird)
			_spawn(bird, true)
	if is_instance_valid(player):
		previous_player_position = player.global_position
		_set_player_mass()
	player_grew.emit(player_mass, get_player_tier())

func set_active(value: bool) -> void:
	active = value and not player_dead
	if is_instance_valid(player):
		previous_player_position = player.global_position

func get_player_tier() -> String:
	return Species.tier_name(player_mass)

func get_progress() -> float:
	return clampf((player_mass - START_MASS) / (Species.CROWN_MASS - START_MASS), 0.0, 1.0)

func get_stats() -> Dictionary:
	var alive_count := 0
	var hunters := 0
	var nearest_prey: Dictionary = {}
	var nearest_danger: Dictionary = {}
	var prey_distance := INF
	var danger_distance := INF
	var player_position := player.global_position if is_instance_valid(player) else Vector3.ZERO
	for bird in birds:
		if not bird.alive:
			continue
		alive_count += 1
		if bird.state == "Hunt":
			hunters += 1
		var distance: float = bird.global_position.distance_to(player_position)
		if Species.can_catch(bird.mass, player_mass) and distance < danger_distance:
			danger_distance = distance
			nearest_danger = {"mass": bird.mass, "position": bird.global_position, "distance": distance, "tier": Species.tier_name(bird.mass)}
		elif Species.reward(player_mass, bird.mass) > 0.015 and distance < prey_distance:
			prey_distance = distance
			nearest_prey = {"mass": bird.mass, "position": bird.global_position, "distance": distance, "tier": Species.tier_name(bird.mass)}
	return {"mass": player_mass, "catches": catches, "population": alive_count, "tier": get_player_tier(), "progress": get_progress(), "elapsed": elapsed, "predators": hunters, "npc_catches": npc_catches, "grace_remaining": grace_remaining, "crowned": crowned, "nearest_prey": nearest_prey, "nearest_danger": nearest_danger}

func _physics_process(delta: float) -> void:
	if not active:
		return
	simulate(delta)

func simulate(delta: float) -> void:
	# Public simulation hook allows reproducible validation without a headset.
	if player_dead or not is_instance_valid(player):
		return
	delta = clampf(delta, 0.0, 0.1)
	elapsed += delta
	grace_remaining = maxf(0.0, grace_remaining - delta)
	var player_position := player.global_position
	_visual_clock += delta
	for bird in birds:
		if not bird.alive:
			bird.respawn_remaining -= delta
			if bird.respawn_remaining <= 0.0:
				_spawn(bird, false)
			continue
		bird.previous_position = bird.global_position
		bird.catch_cooldown = maxf(0.0, bird.catch_cooldown - delta)
		bird.protection_remaining = maxf(0.0, bird.protection_remaining - delta)
		bird.state_remaining -= delta
		bird.sense_remaining -= delta
		bird.obstacle_remaining -= delta
		if bird.sense_remaining <= 0.0:
			_sense(bird)
			bird.sense_remaining = SENSE_INTERVAL + float(bird.index % 5) * 0.011
		_move_bird(bird, delta)
		if _visual_clock >= 1.0 / 45.0:
			bird.update_visual(_visual_clock, player_mass, player_position)
	_resolve_catches()
	previous_player_position = player_position
	if _visual_clock >= 1.0 / 45.0:
		_visual_clock = 0.0

func _sense(bird: Node3D) -> void:
	var threat: Node3D
	var prey: Node3D
	var nearest_threat := 27.0 * 27.0
	var nearest_prey := 36.0 * 36.0
	for other in birds:
		if other == bird or not other.alive or other.protection_remaining > 0.0:
			continue
		var distance: float = bird.global_position.distance_squared_to(other.global_position)
		if Species.can_catch(other.mass, bird.mass) and distance < nearest_threat:
			threat = other
			nearest_threat = distance
		elif Species.reward(bird.mass, other.mass) > 0.015 and distance < nearest_prey:
			prey = other
			nearest_prey = distance
	if grace_remaining <= 0.0:
		var distance: float = bird.global_position.distance_squared_to(player.global_position)
		if Species.can_catch(player_mass, bird.mass) and distance < nearest_threat:
			threat = player
			nearest_threat = distance
		elif Species.can_catch(bird.mass, player_mass) and distance < nearest_prey:
			prey = player
			nearest_prey = distance
	if threat != null:
		bird.state = "Flee"
		bird.target = threat
		# Evasion has a modest speed advantage and climbs while weaving; a
		# predator must predict its path and cannot simply outrun every prey.
		var away: Vector3 = bird.global_position - threat.global_position
		var sideways := away.cross(Vector3.UP).normalized()
		bird.desired_direction = (away.normalized() + sideways * sin(elapsed * 2.6 + bird.index) * 0.3 + Vector3.UP * 0.12).normalized()
		return
	if prey != null and bird.catch_cooldown <= 0.0:
		bird.state = "Hunt"
		bird.target = prey
		var prey_velocity: Vector3 = prey.get("velocity")
		var prediction := minf(sqrt(nearest_prey) / maxf(bird.velocity.length(), 6.0), 0.6)
		bird.desired_direction = (prey.global_position + prey_velocity * prediction - bird.global_position).normalized()
		return
	bird.target = null
	if bird.state == "Perch" and bird.state_remaining > 0.0:
		bird.desired_direction = (bird.perch_point - bird.global_position).normalized()
		return
	if bird.state == "Approach perch":
		if bird.global_position.distance_to(bird.perch_point) < 0.9:
			bird.state = "Perch"
			bird.state_remaining = rng.randf_range(2.0, 5.0)
			bird.velocity *= 0.2
			return
		elif bird.state_remaining <= 0.0:
			bird.state = "Cruise"
		else:
			bird.desired_direction = (bird.perch_point - bird.global_position).normalized()
			return
	if bird.state_remaining <= 0.0 or bird.global_position.distance_to(bird.waypoint) < 5.0:
		bird.waypoint = _choose_waypoint()
		bird.state_remaining = rng.randf_range(5.0, 10.0)
		bird.state = "Cruise"
		if rng.randf() < 0.16 and world != null and _has_property(world, "perch_points"):
			var perches: Array = world.get("perch_points")
			if not perches.is_empty():
				bird.perch_point = perches[rng.randi_range(0, perches.size() - 1)] + Vector3.UP * Species.radius(bird.mass)
				bird.state = "Approach perch"
				bird.state_remaining = 12.0
				bird.desired_direction = (bird.perch_point - bird.global_position).normalized()
				return
	var thermal := float(world.call("thermal_at", bird.global_position)) if _world_has_thermal else 0.0
	if thermal > 0.5 and bird.global_position.y < bounds.end.y - 10.0:
		bird.state = "Soar"
		var orbit: Vector3 = bird.velocity.cross(Vector3.UP).normalized()
		bird.desired_direction = (bird.velocity.normalized() + orbit * 0.2 + Vector3.UP * 0.24).normalized()
	else:
		bird.state = "Cruise"
		bird.desired_direction = (bird.waypoint - bird.global_position).normalized()
	# Local flock alignment. Hunt and flee take priority over social steering.
	var alignment := Vector3.ZERO
	var separation := Vector3.ZERO
	var neighbors := 0
	for other in birds:
		if other == bird or not other.alive:
			continue
		var offset: Vector3 = bird.global_position - other.global_position
		var distance: float = offset.length_squared()
		if distance < 100.0 and distance > 0.01 and absf(other.mass - bird.mass) < bird.mass * 0.5:
			alignment += other.velocity.normalized()
			neighbors += 1
			if distance < 9.0:
				separation += offset / distance
	if neighbors > 0:
		bird.desired_direction = (bird.desired_direction + alignment / neighbors * 0.2 + separation * 0.55).normalized()

func _move_bird(bird: Node3D, delta: float) -> void:
	if bird.state == "Perch":
		bird.global_position = bird.global_position.move_toward(bird.perch_point, delta * 2.0)
		bird.velocity = bird.velocity.move_toward(Vector3.ZERO, delta * 15.0)
		return
	if bird.obstacle_remaining <= 0.0:
		bird.obstacle_steer = _obstacle_avoidance(bird)
		bird.obstacle_remaining = 0.16 + float(bird.index % 4) * 0.02
	var position: Vector3 = bird.global_position
	var edge := Vector3(position.x, 0, position.z)
	var boundary := Vector3.ZERO
	if edge.length() > radius_limit - 20.0:
		boundary -= edge.normalized() * clampf((edge.length() - radius_limit + 20.0) / 10.0, 0.0, 4.0)
	if position.y < bounds.position.y + 5.0:
		boundary.y += (bounds.position.y + 5.0 - position.y) * 0.35
	if position.y > bounds.end.y - 8.0:
		boundary.y -= (position.y - bounds.end.y + 8.0) * 0.35
	var direction: Vector3 = (bird.desired_direction + boundary + bird.obstacle_steer * 2.2).normalized()
	var speed := Species.cruise_speed(bird.mass)
	if bird.state == "Flee":
		speed *= 1.24
	elif bird.state == "Hunt":
		speed *= 1.12
	elif bird.state == "Approach perch":
		speed = minf(speed, maxf(2.0, position.distance_to(bird.perch_point) * 1.1))
	elif bird.state == "Soar":
		speed *= 0.85
	var desired_velocity: Vector3 = direction * speed
	var acceleration := 16.0 if bird.state == "Flee" else 10.0
	bird.velocity = bird.velocity.move_toward(desired_velocity, acceleration * delta)
	if _world_has_thermal and bird.state == "Soar":
		bird.velocity.y += minf(float(world.call("thermal_at", position)), 6.0) * delta
	var next_position: Vector3 = position + bird.velocity * delta
	if is_inside_tree() and get_world_3d() != null and position.distance_squared_to(next_position) > 0.00001:
		var query := PhysicsRayQueryParameters3D.create(position, next_position, 1)
		var contact := get_world_3d().direct_space_state.intersect_ray(query)
		if not contact.is_empty():
			var normal: Vector3 = contact["normal"]
			next_position = contact["position"] + normal * (bird.radius + 0.05)
			bird.velocity = bird.velocity.slide(normal) + normal * 2.0
			bird.obstacle_steer = normal + Vector3.UP * 0.2
	# Hard safety bounds only guard numerical or spawn mistakes. Steering acts
	# well before them, so normal flight remains continuous.
	next_position.y = clampf(next_position.y, bounds.position.y, bounds.end.y)
	var horizontal := Vector2(next_position.x, next_position.z)
	if horizontal.length() > radius_limit:
		horizontal = horizontal.limit_length(radius_limit)
		next_position.x = horizontal.x
		next_position.z = horizontal.y
		bird.velocity.x *= -0.2
		bird.velocity.z *= -0.2
	bird.global_position = next_position

func _obstacle_avoidance(bird: Node3D) -> Vector3:
	if not is_inside_tree() or get_world_3d() == null:
		return Vector3.ZERO
	if bird.state == "Approach perch" and bird.global_position.distance_to(bird.perch_point) < 6.0:
		return Vector3.ZERO
	var space := get_world_3d().direct_space_state
	var heading: Vector3 = bird.velocity.normalized()
	if heading.length_squared() < 0.01:
		heading = bird.desired_direction
	var side := heading.cross(Vector3.UP).normalized() * maxf(0.5, bird.radius)
	var avoidance := Vector3.ZERO
	for offset in [Vector3.ZERO, side, -side]:
		var origin: Vector3 = bird.global_position + offset
		var query := PhysicsRayQueryParameters3D.create(origin, origin + heading * maxf(5.0, bird.velocity.length() * 0.65), 1)
		var result := space.intersect_ray(query)
		if not result.is_empty():
			avoidance += result["normal"] + Vector3.UP * 0.25
	return avoidance.normalized()

func _resolve_catches() -> void:
	var player_radius := Species.radius(player_mass)
	for bird in birds:
		if bird.alive:
			bird.sweep_travel = bird.previous_position.distance_to(bird.global_position)
	for bird in birds:
		if not bird.alive or bird.protection_remaining > 0.0:
			continue
		var distance := swept_distance(previous_player_position, player.global_position, bird.previous_position, bird.global_position)
		if distance <= 0.35 + player_radius + bird.radius:
			if not _capture_unobstructed(previous_player_position, player.global_position, bird.previous_position, bird.global_position):
				continue
			if Species.can_catch(player_mass, bird.mass) and Species.reward(player_mass, bird.mass) > 0.0:
				_player_catch(bird)
			elif grace_remaining <= 0.0 and bird.catch_cooldown <= 0.0 and Species.can_catch(bird.mass, player_mass):
				player_dead = true
				active = false
				bird.catch_cooldown = 2.0
				player_caught.emit(Species.tier_name(bird.mass))
				return
	for predator in birds:
		if not predator.alive or predator.protection_remaining > 0.0 or predator.catch_cooldown > 0.0:
			continue
		for prey in birds:
			if prey == predator or not prey.alive or prey.protection_remaining > 0.0 or predator.mass < prey.mass * Species.CATCH_RATIO:
				continue
			# Conservative broad phase includes both swept travels. It retains
			# fast crossing catches and avoids costly reward/power math for far
			# pairs across the entire mobile-XR flock.
			var reach: float = 0.35 + predator.radius + prey.radius + predator.sweep_travel + prey.sweep_travel
			if predator.global_position.distance_squared_to(prey.global_position) > reach * reach:
				continue
			if Species.reward(predator.mass, prey.mass) <= 0.0:
				continue
			if swept_distance(predator.previous_position, predator.global_position, prey.previous_position, prey.global_position) <= 0.35 + predator.radius + prey.radius:
				if not _capture_unobstructed(predator.previous_position, predator.global_position, prey.previous_position, prey.global_position):
					continue
				var gain := Species.reward(predator.mass, prey.mass) * 0.62
				predator.set_mass(minf(predator.mass + gain, 9.0))
				predator.catch_cooldown = 0.85
				npc_catches += 1
				_consume(prey)
				break

func _player_catch(bird: Node3D) -> void:
	var gain := Species.reward(player_mass, bird.mass)
	var old_tier := get_player_tier()
	var catch_position: Vector3 = bird.global_position
	var prey_mass: float = bird.mass
	player_mass += gain
	catches += 1
	_consume(bird)
	_set_player_mass()
	catch_event.emit(catch_position, prey_mass)
	player_grew.emit(player_mass, get_player_tier())
	if old_tier != get_player_tier():
		ecosystem_event.emit("You became a %s. Seek larger prey!" % get_player_tier())
	if not crowned and player_mass >= Species.CROWN_MASS:
		crowned = true
		ecosystem_event.emit("Sovereign of the sky! Keep soaring in the living food web.")

func _consume(bird: Node3D) -> void:
	bird.alive = false
	bird.visible = false
	bird.respawn_remaining = rng.randf_range(3.0, 6.0)
	bird.target = null
	bird.velocity = Vector3.ZERO

func _spawn(bird: Node3D, initial: bool) -> void:
	bird.alive = true
	bird.visible = true
	bird.set_mass(bird.slot_mass)
	bird.state = "Cruise"
	bird.target = null
	bird.sense_remaining = float(bird.index % 12) * 0.021
	bird.obstacle_remaining = float(bird.index % 8) * 0.022
	bird.protection_remaining = 1.2
	bird.catch_cooldown = 0.0
	bird.state_remaining = rng.randf_range(3.0, 8.0)
	bird.waypoint = _choose_waypoint()
	var player_position := player.global_position if is_instance_valid(player) else Vector3(0, 18, 64)
	var point := _choose_waypoint()
	# Six approachable starter birds ahead of spawn teach the first chase.
	if initial and bird.index < 6:
		point = player_position + Vector3((bird.index - 2.5) * 4.0, rng.randf_range(-2.0, 4.0), -rng.randf_range(13.0, 26.0))
		bird.waypoint = point + Vector3(0, 2, -25)
	else:
		var minimum_distance := 36.0 if bird.mass < player_mass else 65.0
		if not initial:
			minimum_distance = 65.0
		for _attempt in 24:
			if point.distance_to(player_position) >= minimum_distance and _spawn_clear(point, bird.radius):
				break
			point = _choose_waypoint()
		if point.distance_to(player_position) < minimum_distance:
			var away := Vector3(-player_position.x, 0.25, -player_position.z).normalized()
			if away.length_squared() < 0.01:
				away = Vector3.FORWARD
			point = player_position + away * minimum_distance
	point.y = clampf(point.y, bounds.position.y + 2, bounds.end.y - 5)
	var horizontal := Vector2(point.x, point.z).limit_length(radius_limit - 5)
	point.x = horizontal.x
	point.z = horizontal.y
	for _clearance in 8:
		if _spawn_clear(point, bird.radius):
			break
		point.y = minf(point.y + 4.0, bounds.end.y - 2.0)
	bird.global_position = point
	bird.previous_position = point
	bird.desired_direction = (bird.waypoint - point).normalized()
	if bird.desired_direction.length_squared() < 0.01:
		bird.desired_direction = Vector3.FORWARD
	bird.velocity = bird.desired_direction * Species.cruise_speed(bird.mass)
	bird.visual.phase = rng.randf_range(0, TAU)

func _spawn_clear(point: Vector3, radius: float) -> bool:
	if _world_has_terrain and point.y < float(world.call("terrain_height", point.x, point.z)) + radius + 0.3:
		return false
	if not is_inside_tree() or get_world_3d() == null:
		return true
	var shape := SphereShape3D.new()
	shape.radius = radius + 0.15
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.origin = point
	query.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _capture_unobstructed(a_start: Vector3, a_end: Vector3, b_start: Vector3, b_end: Vector3) -> bool:
	if not is_inside_tree() or get_world_3d() == null:
		return true
	var relative_start := a_start - b_start
	var relative_motion := (a_end - a_start) - (b_end - b_start)
	var t := clampf(-relative_start.dot(relative_motion) / maxf(relative_motion.length_squared(), 0.00001), 0.0, 1.0)
	var contact_a := a_start.lerp(a_end, t)
	var contact_b := b_start.lerp(b_end, t)
	if contact_a.distance_squared_to(contact_b) < 0.0001:
		return true
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(contact_a, contact_b, 1)).is_empty()

func _choose_waypoint() -> Vector3:
	if world != null and _has_property(world, "waypoints"):
		var points: Array = world.get("waypoints")
		if not points.is_empty() and rng.randf() < 0.75:
			return points[rng.randi_range(0, points.size() - 1)] + Vector3(rng.randf_range(-12, 12), rng.randf_range(-3, 5), rng.randf_range(-12, 12))
	var angle := rng.randf_range(0, TAU)
	var distance := sqrt(rng.randf()) * (radius_limit - 20.0)
	return Vector3(cos(angle) * distance, rng.randf_range(bounds.position.y + 8.0, bounds.end.y - 12.0), sin(angle) * distance)

func _set_player_mass() -> void:
	if not is_instance_valid(player):
		return
	if player.has_method("set_mass"):
		player.call("set_mass", player_mass)
	elif _has_property(player, "mass"):
		player.set("mass", player_mass)

static func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if property["name"] == property_name:
			return true
	return false

static func catch_radius(predator_mass: float, prey_mass: float) -> float:
	return 0.35 + Species.radius(predator_mass) + Species.radius(prey_mass)

static func swept_distance(a_start: Vector3, a_end: Vector3, b_start: Vector3, b_end: Vector3) -> float:
	var relative_start := a_start - b_start
	var relative_motion := (a_end - a_start) - (b_end - b_start)
	var t := clampf(-relative_start.dot(relative_motion) / maxf(relative_motion.length_squared(), 0.00001), 0.0, 1.0)
	return (relative_start + relative_motion * t).length()
