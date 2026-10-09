extends CharacterBody3D

## Bird NPC — flocks + hunt/flee Agar.io logic — polished + type-safe

@export var bird_size: float = 1.0
@export var is_predator: bool = false
@export var base_speed: float = 9.0
@export var agility: float = 1.0
@export var color: Color = Color(0.85, 0.75, 0.2, 1)

var velocity_target: Vector3 = Vector3.ZERO
var _time: float = 0.0
var _perch_point: Vector3 = Vector3.ZERO
var _is_perched: bool = false
var _perch_time: float = 0.0
var _wander_center: Vector3 = Vector3.ZERO
var _is_being_eaten: bool = false

@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var beak: MeshInstance3D = $BodyMesh/Beak
@onready var wing_l: MeshInstance3D = $WingL
@onready var wing_r: MeshInstance3D = $WingR

func _ready():
	add_to_group("bird")
	_wander_center = Vector3(randf_range(-60.0, 60.0), randf_range(14.0, 38.0), randf_range(-60.0, 60.0))
	global_position = _wander_center + Vector3(randf_range(-6.0, 6.0), randf_range(-2.0, 2.0), randf_range(-6.0, 6.0))
	bird_size = clamp(bird_size + randf_range(-0.12, 0.12), 0.55, 2.4)
	base_speed = clamp(11.5 - bird_size * 2.2 + randf_range(-1.0, 1.0), 5.5, 14.0)
	agility = clamp(1.35 - bird_size * 0.18 + randf_range(-0.15, 0.15), 0.55, 1.45)
	scale = Vector3.ONE * bird_size
	_apply_color()
	_time = randf() * 10.0
	var init_dir: Vector3 = Vector3(randf_range(-4.0, 4.0), randf_range(-1.0, 2.0), randf_range(-4.0, 4.0))
	if init_dir.length_squared() > 0.001:
		init_dir = init_dir.normalized()
	else:
		init_dir = Vector3.FORWARD
	velocity = init_dir * base_speed * 0.65
	if randf() < 0.18:
		_is_perched = true
		_perch_time = randf_range(2.0, 6.0)

func _apply_color():
	if body_mesh != null and is_instance_valid(body_mesh) and body_mesh.mesh is SphereMesh:
		(body_mesh.mesh as SphereMesh).radial_segments = 7
		(body_mesh.mesh as SphereMesh).rings = 4
	if body_mesh != null and is_instance_valid(body_mesh):
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = color if not is_predator else color.lerp(Color(0.92, 0.18, 0.22, 1), 0.55)
		mat.roughness = 0.92
		body_mesh.material_override = mat
	if beak != null and is_instance_valid(beak):
		var bm: StandardMaterial3D = StandardMaterial3D.new()
		bm.albedo_color = Color(1, 0.79, 0.18, 1)
		bm.roughness = 0.88
		beak.material_override = bm
	for w in [wing_l, wing_r]:
		if w != null and is_instance_valid(w) and w.get_surface_override_material(0) == null:
			var wm = StandardMaterial3D.new()
			wm.albedo_color = Color(0.90, 0.87, 0.76, 1).lerp(color, 0.28)
			wm.roughness = 0.90
			w.set_surface_override_material(0, wm)

func _physics_process(delta: float):
	if _is_being_eaten:
		return
	if not is_finite(delta) or delta <= 0.0:
		return
	delta = clamp(delta, 0.0, 0.05)
	_time += delta
	if _is_perched:
		_perch_time -= delta
		velocity = velocity.lerp(Vector3.ZERO, delta * 4.0)
		move_and_slide()
		if _perch_time <= 0.0 or _should_flee() or _should_hunt():
			_is_perched = false
			velocity = Vector3(randf_range(-2.0, 2.0), 3.5, randf_range(-2.0, 2.0)) + Vector3.FORWARD * -base_speed
			_wander_center = global_position + Vector3(randf_range(-14.0, 14.0), randf_range(-4.0, 6.0), randf_range(-14.0, 14.0))
		if wing_l != null and wing_r != null and is_instance_valid(wing_l) and is_instance_valid(wing_r):
			wing_l.rotation.z = deg_to_rad(18.0)
			wing_r.rotation.z = deg_to_rad(-18.0)
		return

	# --- AI ---
	var player: Node = get_tree().get_first_node_in_group("player")
	var accel: Vector3 = Vector3.ZERO
	var to_player: Vector3 = Vector3.ZERO
	var dist_to_player: float = 9999.0
	if player != null and is_instance_valid(player):
		to_player = player.global_position - global_position
		dist_to_player = to_player.length()
		var player_size: float = 1.0
		if player.has_method("get_bird_size"):
			var v = player.get_bird_size()
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				player_size = float(v)
			else:
				player_size = 1.0
		if is_nan(player_size) or is_inf(player_size):
			player_size = 1.0
		player_size = clamp(player_size, 0.55, 3.2)

		if bird_size < player_size * 0.92 and dist_to_player < 28.0:
			var dir_len: float = to_player.length()
			if dir_len > 0.001:
				var flee_dir: Vector3 = -to_player.normalized()
				flee_dir.y = clamp(flee_dir.y + 0.35, -0.5, 0.85)
				if flee_dir.length_squared() > 0.001:
					flee_dir = flee_dir.normalized()
					var panic: float = clamp(remap(dist_to_player, 22.0, 3.0, 0.4, 1.85), 0.4, 1.85)
					accel += flee_dir * 18.0 * panic * agility
					accel += Vector3(sin(_time * 3.2) * 0.9, cos(_time * 2.7) * 0.45, 0.0).rotated(Vector3.UP, to_player.angle_to(Vector3.FORWARD))
			if randf() < 0.0009 and dist_to_player > 16.0:
				_is_perched = true
				_perch_time = randf_range(4.0, 9.0)
		elif bird_size > player_size * 1.08 and dist_to_player < 34.0 and dist_to_player > 1.2:
			var hunt_len: float = to_player.length()
			if hunt_len > 0.001:
				var hunt_dir: Vector3 = to_player.normalized()
				if player is CharacterBody3D and is_instance_valid(player):
					var pv: Vector3 = (player as CharacterBody3D).velocity
					var lead: Vector3 = to_player + pv * 0.45
					if lead.length_squared() > 0.001:
						hunt_dir = lead.normalized()
				accel += hunt_dir * 13.0 * agility
				if dist_to_player < 4.5:
					accel += hunt_dir * 9.0
		else:
			accel += _wander_force(delta)
	else:
		accel += _wander_force(delta)

	accel += _separation_force() * 2.2
	accel += _bounds_force()
	accel += _obstacle_avoidance() * 3.0
	accel.y += _altitude_hold(delta)

	if accel.length_squared() > 2500.0:
		accel = accel.normalized() * 50.0

	velocity += accel * delta
	velocity *= 0.985

	var max_s: float = base_speed * (1.7 if _should_flee() or _should_hunt() else 1.0)
	if velocity.length() > max_s:
		velocity = velocity.normalized() * max_s
	if velocity.length() < base_speed * 0.42:
		var vlen: float = velocity.length()
		if vlen > 0.1:
			velocity = velocity.normalized() * base_speed * 0.42
		else:
			var rnd: Vector3 = Vector3(randf_range(-1.0, 1.0), 0.2, randf_range(-1.0, 1.0))
			if rnd.length_squared() > 0.001:
				rnd = rnd.normalized()
			else:
				rnd = Vector3.FORWARD
			velocity = rnd * base_speed * 0.5

	velocity.y -= 1.1 * delta
	if not is_finite_vec(velocity):
		velocity = Vector3.FORWARD * base_speed * 0.5

	move_and_slide()

	if velocity.length_squared() > 0.25:
		var dir: Vector3 = velocity.normalized()
		if dir.length_squared() > 0.001 and dir.is_finite():
			var target_basis: Basis = Basis.looking_at(-dir, Vector3.UP)
			var cur_q: Quaternion = basis.get_rotation_quaternion()
			var tgt_q: Quaternion = target_basis.get_rotation_quaternion()
			if cur_q.is_finite() and tgt_q.is_finite():
				var t: float = clamp(delta * 3.2 * agility, 0.0, 1.0)
				var q: Quaternion = cur_q.slerp(tgt_q, t)
				if q.is_finite():
					basis = Basis(q)
			var bank: float = clamp(velocity.x * 0.06, -0.9, 0.9) if velocity.length() > 2.0 else 0.0
			rotation.z = lerp(rotation.z, -bank, delta * 4.0)

	if wing_l != null and wing_r != null and is_instance_valid(wing_l) and is_instance_valid(wing_r):
		var flap_speed: float = remap(velocity.length(), 4.0, 16.0, 6.0, 16.0)
		var flap_amp: float = remap(velocity.length(), 4.0, 16.0, 0.42, 0.85)
		var fl: float = sin(_time * flap_speed) * flap_amp
		wing_l.rotation.z = fl
		wing_r.rotation.z = -fl
		wing_l.rotation.x = sin(_time * flap_speed * 0.5) * 0.18
		wing_r.rotation.x = sin(_time * flap_speed * 0.5 + PI) * 0.18

	if not _is_perched and velocity.length() < base_speed * 0.65 and randf() < 0.0011 and global_position.y < 28.0:
		var perches: Array[Node] = get_tree().get_nodes_in_group("perch")
		var nearest: float = 9999.0
		var best: Node = null
		for p in perches:
			if p == null or not is_instance_valid(p):
				continue
			var d: float = (p as Node3D).global_position.distance_to(global_position) if p is Node3D else 9999.0
			if is_nan(d) or is_inf(d):
				continue
			if d < 14.0 and d < nearest:
				nearest = d
				best = p
		if best != null and nearest < 12.0 and nearest > 1.2 and best is Node3D:
			var diff: Vector3 = (best as Node3D).global_position - global_position
			if diff.length_squared() > 0.001:
				velocity += diff.normalized() * 11.0
			if nearest < 2.2:
				_is_perched = true
				_perch_time = randf_range(3.5, 8.5)
				global_position = (best as Node3D).global_position + Vector3(0.0, 0.35, 0.0)

func _wander_force(_delta: float) -> Vector3:
	var noise: Vector3 = Vector3(sin(_time * 0.71 + bird_size) * 1.2, sin(_time * 0.53) * 0.6, cos(_time * 0.62) * 1.2)
	var diff: Vector3 = _wander_center - global_position
	var dist: float = diff.length()
	var to_center: Vector3 = Vector3.ZERO
	if dist > 0.001:
		to_center = diff.normalized() * 1.35
	if dist > 22.0:
		to_center *= 2.2
		if randf() < 0.008:
			_wander_center = Vector3(randf_range(-70.0, 70.0), randf_range(12.0, 42.0), randf_range(-70.0, 70.0))
	var combined: Vector3 = noise + to_center
	if combined.length_squared() > 0.001:
		return combined.normalized() * 5.4 * agility
	return Vector3.ZERO

func _separation_force() -> Vector3:
	var sep: Vector3 = Vector3.ZERO
	var cnt: int = 0
	var birds: Array[Node] = get_tree().get_nodes_in_group("bird")
	for b in birds:
		if b == self:
			continue
		if b == null or not is_instance_valid(b) or not (b is Node3D):
			continue
		var bd: float = (b as Node3D).global_position.distance_to(global_position)
		if is_nan(bd) or is_inf(bd):
			continue
		if bd < 4.2 * bird_size and bd > 0.01:
			var diff: Vector3 = global_position - (b as Node3D).global_position
			if diff.length_squared() > 0.001:
				sep += diff.normalized() / max(bd, 0.55)
				cnt += 1
				if cnt > 6:
					break
	if cnt > 0 and sep.length_squared() > 0.001:
		return sep.normalized() * min(sep.length() * 6.5, 18.0)
	return Vector3.ZERO

func _bounds_force() -> Vector3:
	var f: Vector3 = Vector3.ZERO
	var lim: float = 145.0
	if abs(global_position.x) > lim:
		f.x = -sign(global_position.x) * 11.0
	if abs(global_position.z) > lim:
		f.z = -sign(global_position.z) * 11.0
	if global_position.y > 62.0:
		f.y -= 10.0
	if global_position.y < 4.5:
		f.y += 9.0
	return f

func _obstacle_avoidance() -> Vector3:
	var vnorm: Vector3 = Vector3.FORWARD
	if velocity.length_squared() > 0.001:
		vnorm = velocity.normalized()
	else:
		return Vector3.ZERO
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return Vector3.ZERO
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(global_position, global_position + vnorm * 6.0)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(params)
	if hit.has("position"):
		var n: Vector3 = hit.get("normal", Vector3.UP)
		if n is Vector3 and n.is_finite():
			return n * 9.0 + Vector3.UP * 2.2
	return Vector3.ZERO

func _altitude_hold(_delta: float) -> float:
	var ideal: float = clamp(_wander_center.y, 10.0, 44.0)
	return clamp((ideal - global_position.y) * 0.45, -6.0, 7.0)

func _should_flee() -> bool:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null or not is_instance_valid(player) or not player.has_method("get_bird_size"):
		return false
	var v = player.get_bird_size()
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return false
	var psz: float = float(v)
	if is_nan(psz) or is_inf(psz):
		return false
	return bird_size < psz * 0.92 and global_position.distance_to((player as Node3D).global_position) < 26.0

func _should_hunt() -> bool:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null or not is_instance_valid(player) or not player.has_method("get_bird_size"):
		return false
	var v = player.get_bird_size()
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return false
	var psz: float = float(v)
	if is_nan(psz) or is_inf(psz):
		return false
	return bird_size > psz * 1.08

func get_bird_size() -> float:
	return bird_size

func be_eaten():
	if _is_being_eaten:
		return
	_is_being_eaten = true
	# disable collisions during tween so we don't get re-entered
	collision_layer = 0
	collision_mask = 0
	var tw: Tween = create_tween()
	if tw != null:
		tw.tween_property(self, "scale", Vector3.ZERO, 0.18)
		await tw.finished
	else:
		await get_tree().create_timer(0.18).timeout
	if not is_instance_valid(self):
		return
	global_position = Vector3(randf_range(-85.0, 85.0), randf_range(14.0, 44.0), randf_range(-85.0, 85.0))
	bird_size = clamp(randf_range(0.72, 1.45), 0.6, 1.6)
	scale = Vector3.ZERO
	base_speed = clamp(11.5 - bird_size * 2.2 + randf_range(-1.0, 1.0), 5.5, 14.0)
	agility = clamp(1.35 - bird_size * 0.18, 0.6, 1.4)
	_apply_color()
	collision_layer = 2
	collision_mask = 1
	_is_being_eaten = false
	var tw2: Tween = create_tween()
	if tw2 != null:
		tw2.tween_property(self, "scale", Vector3.ONE * bird_size, 0.28)
	else:
		scale = Vector3.ONE * bird_size
	var init_dir: Vector3 = Vector3(randf_range(-4.0, 4.0), randf_range(-1.0, 2.0), randf_range(-4.0, 4.0))
	if init_dir.length_squared() > 0.001:
		init_dir = init_dir.normalized()
	else:
		init_dir = Vector3.FORWARD
	velocity = init_dir * base_speed * 0.65
	_wander_center = global_position + Vector3(randf_range(-10.0, 10.0), 0.0, randf_range(-10.0, 10.0))

func on_ate_player(_p):
	bird_size = clamp(bird_size + 0.09, 0.6, 2.6)
	scale = Vector3.ONE * bird_size
	base_speed = clamp(11.5 - bird_size * 2.2, 5.2, 13.0)
	_apply_color()

func is_finite(v: float) -> bool:
	return not is_nan(v) and not is_inf(v)

func is_finite_vec(v: Vector3) -> bool:
	return v.is_finite()
