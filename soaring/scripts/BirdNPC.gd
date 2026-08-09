extends CharacterBody3D

## Bird NPC — flocks + hunt/flee Agar.io logic

@export var bird_size: float = 1.0
@export var is_predator: bool = false
@export var base_speed: float = 9.0
@export var agility: float = 1.0
@export var color: Color = Color(0.85, 0.75, 0.2, 1)

var velocity_target: Vector3 = Vector3.ZERO
var _time: float = 0.0
var _perch_point: Vector3 = Vector3.ZERO
var _is_perched: bool = false
var _perch_time: float = 0
var _wander_center: Vector3

@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var beak: MeshInstance3D = $BodyMesh/Beak
@onready var wing_l: MeshInstance3D = $WingL
@onready var wing_r: MeshInstance3D = $WingR

func _ready():
    add_to_group("bird")
    _wander_center = Vector3(randf_range(-60,60), randf_range(14, 38), randf_range(-60,60))
    global_position = _wander_center + Vector3(randf_range(-6,6), randf_range(-2,2), randf_range(-6,6))
    bird_size = clamp(bird_size + randf_range(-0.12, 0.12), 0.55, 2.4)
    base_speed = clamp(11.5 - bird_size * 2.2 + randf_range(-1,1), 5.5, 14.0)
    agility = clamp(1.35 - bird_size * 0.18 + randf_range(-0.15, 0.15), 0.55, 1.45)
    scale = Vector3.ONE * bird_size
    _apply_color()
    _time = randf()*10
    velocity = Vector3(randf_range(-4,4), randf_range(-1,2), randf_range(-4,4)).normalized() * base_speed * 0.65
    # random perch at spawn
    if randf() < 0.18:
        _is_perched = true
        _perch_time = randf_range(2, 6)

func _apply_color():
    if body_mesh:
        var mat = StandardMaterial3D.new()
        mat.albedo_color = color if not is_predator else color.lerp(Color(0.92,0.18,0.22,1), 0.55)
        mat.roughness = 0.78
        body_mesh.material_override = mat
    if beak:
        var bm = StandardMaterial3D.new()
        bm.albedo_color = Color(1, 0.72, 0.12, 1)
        beak.material_override = bm

func _physics_process(delta):
    _time += delta
    if _is_perched:
        _perch_time -= delta
        velocity = velocity.lerp(Vector3.ZERO, delta * 4.0)
        move_and_slide()
        if _perch_time <= 0 or _should_flee() or _should_hunt():
            _is_perched = false
            velocity = Vector3(randf_range(-2,2), 3.5, randf_range(-2,2)) + Vector3.FORWARD * -base_speed
            _wander_center = global_position + Vector3(randf_range(-14,14), randf_range(-4,6), randf_range(-14,14))
        # still animate wings folded
        if wing_l and wing_r:
            wing_l.rotation.z = deg_to_rad(18)
            wing_r.rotation.z = deg_to_rad(-18)
        return

    # --- AI ---
    var player = get_tree().get_first_node_in_group("player")
    var accel = Vector3.ZERO

    var to_player: Vector3 = Vector3.ZERO
    var dist_to_player: float = 9999
    if player:
        to_player = player.global_position - global_position
        dist_to_player = to_player.length()
        var player_size = 1.0
        if player.has_method("get_bird_size"):
            player_size = player.get_bird_size()

        # agar.io logic
        if bird_size < player_size * 0.92 and dist_to_player < 28.0:
            # flee
            var flee_dir = -to_player.normalized()
            # add vertical component to climb
            flee_dir.y = clamp(flee_dir.y + 0.35, -0.5, 0.85)
            flee_dir = flee_dir.normalized()
            # panic speed boost
            var panic = clamp(remap(dist_to_player, 22, 3, 0.4, 1.85), 0.4, 1.85)
            accel += flee_dir * 18.0 * panic * agility
            # juke sideways
            accel += Vector3(sin(_time*3.2)*0.9, cos(_time*2.7)*0.45, 0).rotated(Vector3.UP, to_player.angle_to(Vector3.FORWARD))
            # maybe perch to hide?
            if randf() < 0.0009 and dist_to_player > 16:
                _is_perched = true
                _perch_time = randf_range(4, 9)
        elif bird_size > player_size * 1.08 and dist_to_player < 34.0 and dist_to_player > 1.2:
            # hunt player if larger
            var hunt_dir = to_player.normalized()
            # lead target
            if player is CharacterBody3D:
                hunt_dir = (to_player + player.velocity * 0.45).normalized()
            accel += hunt_dir * 13.0 * agility
            # pounce when close
            if dist_to_player < 4.5:
                accel += hunt_dir * 9.0
        else:
            # wander / flock
            accel += _wander_force(delta)
    else:
        accel += _wander_force(delta)

    # separation from other birds
    accel += _separation_force() * 2.2
    # world bounds
    accel += _bounds_force()
    # obstacle avoidance simplified via ray avoidance
    accel += _obstacle_avoidance() * 3.0
    # keep altitude
    accel.y += _altitude_hold(delta)

    # integrate
    velocity += accel * delta
    # drag
    velocity *= 0.985
    # speed clamp
    var max_s = base_speed * (1.7 if _should_flee() or _should_hunt() else 1.0)
    if velocity.length() > max_s:
        velocity = velocity.normalized() * max_s
    # avoid stall (min speed unless perched)
    if velocity.length() < base_speed * 0.42:
        velocity = velocity.normalized() * base_speed * 0.42 if velocity.length() > 0.1 else Vector3(randf_range(-1,1),0.2,randf_range(-1,1)).normalized()*base_speed*0.5

    # gravity minor
    velocity.y -= 1.1 * delta

    # move
    move_and_slide()
    # reorient mesh to face velocity (orthonormalized to avoid scale-issues)
    if velocity.length_squared() > 0.25:
        var dir = velocity.normalized()
        var target_basis = Basis.looking_at(-dir, Vector3.UP)
        # slerp via quaternions to preserve uniform scale
        var cur_q = basis.get_rotation_quaternion()
        var tgt_q = target_basis.get_rotation_quaternion()
        var q = cur_q.slerp(tgt_q, clamp(delta * 3.2 * agility, 0, 1))
        basis = Basis(q)
        # re-apply uniform scale kept in `scale` property (Basis from quat is orthonormal)
        # banking visual — compose after basis
        var bank = clamp(velocity.x * 0.06, -0.9, 0.9) if velocity.length() > 2 else 0
        rotation.z = lerp(rotation.z, -bank, delta*4)

    # wing flap anim
    if wing_l and wing_r:
        var flap_speed = remap(velocity.length(), 4, 16, 6, 16)
        var flap_amp = remap(velocity.length(), 4, 16, 0.42, 0.85)
        var fl = sin(_time * flap_speed) * flap_amp
        wing_l.rotation.z = fl
        wing_r.rotation.z = -fl
        wing_l.rotation.x = sin(_time* flap_speed*0.5)*0.18
        wing_r.rotation.x = sin(_time* flap_speed*0.5+PI)*0.18

    # occasional perch decision
    if not _is_perched and velocity.length() < base_speed*0.65 and randf() < 0.0011 and global_position.y < 28:
        # scan for perch nearby
        var perches = get_tree().get_nodes_in_group("perch")
        var nearest = 9999.0
        var best = null
        for p in perches:
            var d = p.global_position.distance_to(global_position)
            if d < 14 and d < nearest:
                nearest = d
                best = p
        if best and nearest < 12 and nearest > 1.2:
            velocity += (best.global_position - global_position).normalized() * 11.0
            if nearest < 2.2:
                _is_perched = true
                _perch_time = randf_range(3.5, 8.5)
                global_position = best.global_position + Vector3(0, 0.35, 0)

func _wander_force(_delta) -> Vector3:
    var noise = Vector3(sin(_time*0.71 + bird_size)*1.2, sin(_time*0.53)*0.6, cos(_time*0.62)*1.2)
    var to_center = (_wander_center - global_position).normalized() * 1.35
    if global_position.distance_to(_wander_center) > 22:
        to_center *= 2.2
        # pick new center
        if randf() < 0.008:
            _wander_center = Vector3(randf_range(-70,70), randf_range(12,42), randf_range(-70,70))
    return (noise + to_center).normalized() * 5.4 * agility

func _separation_force() -> Vector3:
    var sep = Vector3.ZERO
    var cnt = 0
    for b in get_tree().get_nodes_in_group("bird"):
        if b == self: continue
        var d = global_position.distance_to(b.global_position)
        if d < 4.2 * bird_size and d > 0.01:
            sep += (global_position - b.global_position).normalized() / max(d, 0.55)
            cnt += 1
            if cnt > 6: break
    return sep * 6.5 if cnt>0 else Vector3.ZERO

func _bounds_force() -> Vector3:
    var f = Vector3.ZERO
    var lim = 145.0
    if abs(global_position.x) > lim:
        f.x = -sign(global_position.x) * 11.0
    if abs(global_position.z) > lim:
        f.z = -sign(global_position.z) * 11.0
    if global_position.y > 62:
        f.y -= 10.0
    if global_position.y < 4.5:
        f.y += 9.0
    return f

func _obstacle_avoidance() -> Vector3:
    # cheap: move away from closest static obstacle within 6m (query physics)
    var space = get_world_3d().direct_space_state
    var params = PhysicsRayQueryParameters3D.create(global_position, global_position + velocity.normalized()*6.0)
    params.collide_with_areas = false
    params.collide_with_bodies = true
    var hit = space.intersect_ray(params)
    if hit and hit.has("position"):
        var n = hit.get("normal", Vector3.UP)
        return n * 9.0 + Vector3.UP * 2.2
    return Vector3.ZERO

func _altitude_hold(_delta) -> float:
    var ideal = clamp(_wander_center.y, 10, 44)
    return clamp((ideal - global_position.y)*0.45, -6, 7)

func _should_flee() -> bool:
    var player = get_tree().get_first_node_in_group("player")
    if not player or not player.has_method("get_bird_size"): return false
    return bird_size < player.get_bird_size()*0.92 and global_position.distance_to(player.global_position) < 26

func _should_hunt() -> bool:
    var player = get_tree().get_first_node_in_group("player")
    if not player or not player.has_method("get_bird_size"): return false
    return bird_size > player.get_bird_size()*1.08

func get_bird_size() -> float: return bird_size

func be_eaten():
    # particle + respawn far away with smaller size
    var tw = create_tween()
    tw.tween_property(self, "scale", Vector3.ZERO, 0.18)
    await tw.finished
    # respawn
    global_position = Vector3(randf_range(-85,85), randf_range(14,44), randf_range(-85,85))
    bird_size = clamp(randf_range(0.72, 1.45), 0.6, 1.6)
    scale = Vector3.ONE * bird_size
    base_speed = clamp(11.5 - bird_size*2.2 + randf_range(-1,1), 5.5, 14)
    agility = clamp(1.35 - bird_size*0.18, 0.6, 1.4)
    _apply_color()
    var tw2 = create_tween()
    scale = Vector3.ZERO
    tw2.tween_property(self, "scale", Vector3.ONE*bird_size, 0.28)
    velocity = Vector3(randf_range(-4,4), randf_range(-1,2), randf_range(-4,4)).normalized()*base_speed*0.65

func on_ate_player(_p):
    bird_size = clamp(bird_size + 0.09, 0.6, 2.6)
    scale = Vector3.ONE * bird_size
    base_speed = clamp(11.5 - bird_size*2.2, 5.2, 13)
    _apply_color()
