class_name BirdNPC
extends Node3D

## A rival bird.
##
## Crucially it flies through the *same* [FlightModel] the player does — it
## banks to turn, must dive to build speed, and cannot climb without flapping.
## An NPC that cheated physics would immediately give the game away, and would
## also make the size/agility tradeoff meaningless.

signal died(bird: BirdNPC)

enum State { WANDER, HUNT, FLEE, PERCH }

const SENSE_RADIUS: float = 95.0
const PERCH_REST_MIN: float = 2.0
const PERCH_REST_MAX: float = 7.0
## Prey must be this much smaller to be worth chasing, and predators this much
## bigger to be worth running from. The gap stops birds of near-equal size from
## twitching between hunting and fleeing.
const SIZE_MARGIN: float = 1.12

var model := FlightModel.new()
var command := FlightCommand.new()
var state: State = State.WANDER
var size: float = 1.0

var world: WorldBuilder
var target: Node3D = null
var _goal: Vector3 = Vector3.ZERO
var _goal_timer: float = 0.0
var _perch_timer: float = 0.0
var _flap_phase: float = 0.0
var _rng := RandomNumberGenerator.new()
var _body: Node3D
var _left_wing: MeshInstance3D
var _right_wing: MeshInstance3D
var _scaler: Node3D
var _material: StandardMaterial3D


func configure(new_size: float, spawn: Vector3, world_ref: WorldBuilder, rng_seed: int) -> void:
	_rng.seed = rng_seed
	size = new_size
	world = world_ref
	position = spawn
	model.set_size(size)
	model.heading = _rng.randf() * TAU
	model.velocity = model.forward() * model.trim_speed()
	_pick_new_goal()


func _ready() -> void:
	_build_visual()
	_apply_size()


func _build_visual() -> void:
	# Rotation and scale are kept on separate nodes on purpose: slerping a basis
	# that carries a scale is not a valid rotation and Godot rejects it.
	_body = Node3D.new()
	add_child(_body)
	_scaler = Node3D.new()
	_body.add_child(_scaler)

	_material = StandardMaterial3D.new()
	_material.albedo_color = Color.from_hsv(_rng.randf(), 0.45, 0.85)
	_material.roughness = 0.9
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 0.0
	var material: StandardMaterial3D = _material

	var torso := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.30
	capsule.height = 1.15
	capsule.radial_segments = 6
	capsule.rings = 2
	torso.mesh = capsule
	torso.material_override = material
	# Capsules stand up the Y axis; lay it along the bird's forward axis.
	torso.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	_scaler.add_child(torso)

	_left_wing = _make_wing(material, -1.0)
	_right_wing = _make_wing(material, 1.0)
	_scaler.add_child(_left_wing)
	_scaler.add_child(_right_wing)


func _make_wing(material: StandardMaterial3D, side: float) -> MeshInstance3D:
	var wing := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(1.5, 0.08, 0.75)
	wing.mesh = prism
	wing.material_override = material
	wing.position = Vector3(side * 0.85, 0.05, 0.0)
	wing.rotation_degrees = Vector3(0.0, 0.0, -side * 90.0)
	return wing


## Glow tells you, at a glance and at 40 m/s, whether the shape ahead is lunch
## or a predator. Without it the size comparison has to be made by eye against
## an unfamiliar silhouette at unknown distance, which is exactly the judgement
## players are worst at in VR.
func show_threat(relative_to_size: float) -> void:
	if _material == null:
		return
	if GameRules.can_catch(relative_to_size, size):
		_material.emission = Color(0.25, 1.0, 0.35)
		_material.emission_energy_multiplier = 0.55
	elif GameRules.can_catch(size, relative_to_size):
		_material.emission = Color(1.0, 0.22, 0.18)
		_material.emission_energy_multiplier = 0.8
	else:
		_material.emission_energy_multiplier = 0.0


func _apply_size() -> void:
	if _scaler != null:
		_scaler.scale = Vector3.ONE * size


func set_size(new_size: float) -> void:
	size = clampf(new_size, 0.2, 10.0)
	model.set_size(size)
	_apply_size()


func catch_radius() -> float:
	return 0.55 * size


func _physics_process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return

	if state == State.PERCH:
		_process_perched(delta)
		return

	_think(delta)
	command.wind = world.wind_at(global_position) if world != null else Vector3.ZERO
	model.step(command, delta)
	position += model.velocity * delta
	_avoid_ground()
	_update_pose(delta)


## Steering is expressed purely as wing commands — a heading and altitude the
## bird wants, converted into bank, angle of attack and effort. It has no
## ability to move except by flying, exactly like the player.
func _think(delta: float) -> void:
	_goal_timer -= delta
	_choose_state()

	match state:
		State.HUNT:
			if is_instance_valid(target):
				_goal = target.global_position
			else:
				state = State.WANDER
		State.FLEE:
			if is_instance_valid(target):
				var away: Vector3 = (global_position - target.global_position).normalized()
				_goal = global_position + away * 120.0 + Vector3.UP * 25.0
			else:
				state = State.WANDER
		State.WANDER:
			if _goal_timer <= 0.0 or global_position.distance_to(_goal) < 25.0:
				_pick_new_goal()

	_steer_toward(_goal, delta)


func _choose_state() -> void:
	var previous: State = state
	if not is_instance_valid(target):
		target = null
		if state != State.WANDER:
			state = State.WANDER
	# The manager assigns targets; this only decides what to do about one.
	if target != null:
		var other_size: float = _size_of(target)
		var distance: float = global_position.distance_to(target.global_position)
		if distance > SENSE_RADIUS * 1.4:
			target = null
			state = State.WANDER
		elif other_size * SIZE_MARGIN < size:
			state = State.HUNT
		elif other_size > size * SIZE_MARGIN:
			state = State.FLEE
		else:
			state = State.WANDER
	if previous != state:
		_goal_timer = 0.0


static func _size_of(node: Node3D) -> float:
	if node is BirdPlayer:
		return (node as BirdPlayer).size
	if node is BirdNPC:
		return (node as BirdNPC).size
	return 1.0


func _pick_new_goal() -> void:
	_goal_timer = _rng.randf_range(4.0, 9.0)
	# Head for a perch now and then, so the world's branches and wires actually
	# get used and the sky feels inhabited rather than decorative.
	if world != null and not world.perch_points.is_empty() and _rng.randf() < 0.25:
		_goal = world.perch_points[_rng.randi() % world.perch_points.size()]
		_goal.y += 1.0
		return
	var angle: float = _rng.randf() * TAU
	var radius: float = _rng.randf_range(80.0, 380.0)
	var ground: float = world.height_at(cos(angle) * radius, sin(angle) * radius) if world != null else 0.0
	_goal = Vector3(
		cos(angle) * radius,
		ground + _rng.randf_range(35.0, 140.0),
		sin(angle) * radius
	)


func _steer_toward(goal: Vector3, delta: float) -> void:
	var offset: Vector3 = goal - global_position
	var horizontal := Vector2(offset.x, offset.z)
	if horizontal.length_squared() < 1.0:
		horizontal = Vector2(0.0, -1.0)

	# Bank toward the target: how far off the nose it is becomes roll command.
	var desired_heading: float = atan2(-horizontal.x, -horizontal.y)
	var error: float = wrapf(desired_heading - model.heading, -PI, PI)
	command.bank = clampf(-error * 1.5, -1.15, 1.15)

	# Climb by raising the nose; dive by lowering it. Held short of the stall,
	# because an AI that stalls itself into the ground is not a threat.
	var height_error: float = offset.y
	var pitch: float = clampf(height_error / 45.0, -1.0, 1.0)
	command.alpha = clampf(
		model.alpha_trim + pitch * model.alpha_range,
		-model.alpha_range,
		model.alpha_stall * 0.92
	)

	# Tuck to dive on prey or to escape downhill; spread to climb and turn.
	var diving: bool = height_error < -25.0 and (state == State.HUNT or state == State.FLEE)
	command.span = 0.25 if diving else 1.0

	_update_effort(height_error, delta)


## Flapping is rhythmic and only when it is needed — birds that beat their wings
## constantly look like insects.
func _update_effort(height_error: float, delta: float) -> void:
	var slow: bool = model.velocity.length() < model.trim_speed() * 0.95
	var wants_height: bool = height_error > 8.0
	var urgent: bool = state == State.FLEE or state == State.HUNT
	var should_flap: bool = (slow or wants_height) and command.span > 0.5

	if not should_flap:
		command.stroke_speed = 0.0
		_flap_phase = 0.0
		return

	var period: float = 0.55 if urgent else 0.8
	_flap_phase = fmod(_flap_phase + delta, period)
	var downstroke: bool = _flap_phase < period * 0.45
	command.stroke_speed = (3.2 if urgent else 2.4) if downstroke else 0.0


func _avoid_ground() -> void:
	if world == null:
		return
	var ground: float = world.height_at(global_position.x, global_position.z)
	var clearance: float = 3.0 * size
	if global_position.y < ground + clearance:
		position.y = ground + clearance
		# Bounce the flight path upward rather than teleporting silently, so it
		# reads as a bird skimming a hillside.
		model.velocity.y = maxf(model.velocity.y, 4.0)


func _update_pose(delta: float) -> void:
	if _body == null:
		return
	var forward: Vector3 = model.velocity
	if forward.length_squared() > 1.0:
		var direction: Vector3 = forward.normalized()
		# In a vertical dive or climb the world up-vector is useless as a
		# reference, so fall back on the bird's own heading.
		var up: Vector3 = Vector3.UP
		if absf(direction.dot(Vector3.UP)) > 0.99:
			up = model.forward()
		var target_basis := Basis.looking_at(direction, up)
		# Roll the model with the bank so the turn is visible from outside.
		target_basis = target_basis.rotated(direction, -model.bank)
		_body.global_basis = _body.global_basis.slerp(
			target_basis, clampf(delta * 8.0, 0.0, 1.0)
		)

	# Wings sweep down on the beat and stretch out in a glide.
	var beat: float = clampf(command.stroke_speed / 3.2, 0.0, 1.0)
	var sweep: float = lerpf(10.0, -35.0, beat)
	var fold: float = lerpf(1.0, 0.35, 1.0 - command.span)
	_left_wing.rotation_degrees.z = 90.0 + sweep
	_right_wing.rotation_degrees.z = -90.0 - sweep
	_left_wing.scale.x = fold
	_right_wing.scale.x = fold


func _process_perched(delta: float) -> void:
	_perch_timer -= delta
	model.velocity = Vector3.ZERO
	if _perch_timer <= 0.0:
		state = State.WANDER
		model.velocity = model.forward() * model.trim_speed() * 0.6 + Vector3.UP * 3.0
		_pick_new_goal()


func perch_here() -> void:
	state = State.PERCH
	_perch_timer = _rng.randf_range(PERCH_REST_MIN, PERCH_REST_MAX)


func devour(prey_size: float) -> void:
	# Same growth rule the player uses, so the leaderboard means something.
	set_size(GameRules.grown_size(size, prey_size))


func die() -> void:
	died.emit(self)
	queue_free()
