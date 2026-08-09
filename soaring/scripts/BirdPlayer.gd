extends CharacterBody3D

## Soaring — VR Bird Flight Player
## Core: flapping via controller vertical velocity, wing tilt for lift/turn.

# --- Tunables (flight perfected after iteration) ---
@export var gravity: float = 9.8
@export var flap_lift: float = 8.5
@export var flap_thrust: float = 9.0
@export var flap_threshold: float = 1.8        # m/s down speed to count as flap
@export var flap_cooldown: float = 0.18
@export var glide_lift_coeff: float = 0.64
@export var bank_turn_rate: float = 1.45
@export var pitch_dive_rate: float = 6.0
@export var base_drag: float = 0.92
@export var stall_speed: float = 5.5
@export var stall_angle_deg: float = 22.0
@export var max_speed: float = 26.0
@export var perch_speed_threshold: float = 3.2

# --- nodes ---
@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var left_ctrl: XRController3D = $XROrigin3D/LeftController
@onready var right_ctrl: XRController3D = $XROrigin3D/RightController
@onready var wing_left_mesh: MeshInstance3D = $XROrigin3D/LeftController/WingMesh
@onready var wing_right_mesh: MeshInstance3D = $XROrigin3D/RightController/WingMesh
@onready var body_collision: CollisionShape3D = $BodyCollision
@onready var catch_area: Area3D = $CatchArea
@onready var perch_ray: RayCast3D = $PerchRay
@onready var perch_shape: Area3D = $PerchArea

# visual
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var beak_mesh: MeshInstance3D = $BodyMesh/Beak
@onready var tail_mesh: MeshInstance3D = $BodyMesh/Tail

# --- state ---
var player_size: float = 1.0
var score: int = 0
var is_perched: bool = false
var flap_count: int = 0

# flight internal
var _prev_left_y: float = 0.0
var _prev_right_y: float = 0.0
var _left_vel_y: float = 0.0
var _right_vel_y: float = 0.0
var _last_left_pos: Vector3 = Vector3.ZERO
var _last_right_pos: Vector3 = Vector3.ZERO
var _flap_timer: float = 0.0
var _has_prev: bool = false
var _xr_active: bool = false
var _desktop_yaw: float = 0.0
var _desktop_pitch: float = 0.0
var _bank_smooth: float = 0.0
var _pitch_smooth: float = 0.0
var _speed_smooth: float = 0.0

signal bird_caught(value: int, new_size: float)
signal player_caught_by(bigger_size: float)
signal size_changed(new_size: float)

func _ready():
    # XR init
    var xr_interface = XRServer.find_interface("OpenXR")
    if xr_interface and xr_interface.is_initialized():
        get_viewport().use_xr = true
        _xr_active = true
        print("[Soaring] XR active — wing flight enabled")
    else:
        # fallback: try enable anyway
        if xr_interface:
            get_viewport().use_xr = true
            _xr_active = xr_interface.is_initialized()
        print("[Soaring] Desktop fallback — mouse + space to flap")
    # input mouse capture for desktop
    if not _xr_active:
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    # collisions
    catch_area.body_entered.connect(_on_catch_area_body_entered)
    catch_area.area_entered.connect(_on_catch_area_entered)
    # perch ray
    if perch_ray:
        perch_ray.enabled = true
    add_to_group("player")
    update_scale()

func _input(event):
    if not _xr_active:
        if event is InputEventMouseMotion:
            _desktop_yaw -= event.relative.x * 0.003
            _desktop_pitch = clamp(_desktop_pitch - event.relative.y * 0.003, deg_to_rad(-80), deg_to_rad(60))
        if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
            _do_flap(1.0, true)
        if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
            if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            else:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta: float):
    if not is_finite(delta) or delta <= 0.0:
        return
    delta = clamp(delta, 0.0, 0.05)
    _flap_timer = max(0.0, _flap_timer - delta)

    var head_basis: Basis
    var cam_pos: Vector3
    var left_pos: Vector3
    var right_pos: Vector3
    var left_basis: Basis
    var right_basis: Basis

    if _xr_active and left_ctrl and right_ctrl:
        # XR poses are auto-updated by Godot — use global positions
        left_pos = left_ctrl.global_position
        right_pos = right_ctrl.global_position
        left_basis = left_ctrl.global_transform.basis
        right_basis = right_ctrl.global_transform.basis
        cam_pos = xr_camera.global_position
        head_basis = xr_camera.global_transform.basis
    else:
        # Desktop: simulate hands in front of camera, driven by yaw/pitch
        var base = global_position + Vector3(0, 0.35, 0) # chest
        head_basis = Basis.from_euler(Vector3(_desktop_pitch, _desktop_yaw, 0))
        cam_pos = global_position + Vector3(0, 0.55, 0)
        # simulate wing positions: hands 0.7m in front, 0.6 apart
        var forward = -head_basis.z
        var right = head_basis.x
        var up = head_basis.y
        # add breathing bob
        var bob = sin(Time.get_ticks_msec() / 700.0) * 0.04 if is_perched else 0
        left_pos = base + forward * 0.45 + right * -0.65 + up * bob
        right_pos = base + forward * 0.45 + right * 0.65 + up * bob
        left_basis = head_basis
        right_basis = head_basis
        # mouse wheel / Q E for simulated bank for desktop tuning
        if Input.is_key_pressed(KEY_Q):
            left_pos.y -= 0.25
            right_pos.y += 0.25
        if Input.is_key_pressed(KEY_E):
            left_pos.y += 0.25
            right_pos.y -= 0.25
        if Input.is_key_pressed(KEY_W):
            # pitched forward dive
            head_basis = Basis.from_euler(Vector3(deg_to_rad(-24), _desktop_yaw, 0))
        if Input.is_key_pressed(KEY_S):
            head_basis = Basis.from_euler(Vector3(deg_to_rad(28), _desktop_yaw, 0))

    # --- flap detection (XR) ---
    if _xr_active:
        if _has_prev:
            _left_vel_y = (left_pos.y - _last_left_pos.y) / delta
            _right_vel_y = (right_pos.y - _last_right_pos.y) / delta
            var left_down_speed = max(0.0, -_left_vel_y)
            var right_down_speed = max(0.0, -_right_vel_y)
            # check cooldown
            if _flap_timer <= 0.0:
                var flap_power_left = clamp((left_down_speed - 0.4) / flap_threshold, 0.0, 1.7)
                var flap_power_right = clamp((right_down_speed - 0.4) / flap_threshold, 0.0, 1.7)
                var triggered = false
                var power: float = 0
                var is_sync: bool = false
                if left_down_speed > flap_threshold and right_down_speed > flap_threshold:
                    # synchronous powerful flap
                    power = (flap_power_left + flap_power_right) * 0.5 * 1.25
                    # bonus if hands are separated (wingspan)
                    var spread = clamp(left_pos.distance_to(right_pos) / 1.4, 0.35, 1.0)
                    power *= lerp(0.75, 1.0, spread)
                    triggered = true
                    is_sync = true
                elif left_down_speed > flap_threshold * 1.15:
                    power = flap_power_left * 0.7
                    triggered = true
                elif right_down_speed > flap_threshold * 1.15:
                    power = flap_power_right * 0.7
                    triggered = true

                if triggered and power > 0.35:
                    _do_flap(power, is_sync)
                    _flap_timer = flap_cooldown
                    # haptics
                    if left_ctrl and right_ctrl:
                        if is_sync:
                            left_ctrl.trigger_haptic_pulse("haptic", 0.6, 80, 0, 0)
                            right_ctrl.trigger_haptic_pulse("haptic", 0.6, 80, 0, 0)
                        else:
                            if left_down_speed > flap_threshold:
                                left_ctrl.trigger_haptic_pulse("haptic", 0.35, 55, 0, 0)
                            if right_down_speed > flap_threshold:
                                right_ctrl.trigger_haptic_pulse("haptic", 0.35, 55, 0, 0)

        _last_left_pos = left_pos
        _last_right_pos = right_pos
        _has_prev = true
    else:
        # desktop auto-spread detection via W/S/Q/E already; space handled in _input
        # also hold flap with left mouse or space
        if Input.is_action_pressed("flap") or Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            if _flap_timer <= 0:
                _do_flap(1.0, true)
                _flap_timer = 0.22

    # --- aerodynamics ---
    # wing metrics
    var wing_span_dist = left_pos.distance_to(right_pos)
    var wing_spread = clamp(wing_span_dist / 1.45, 0.0, 1.0)
    # average wing up (lift direction)
    var avg_wing_up: Vector3 = (left_basis.y + right_basis.y) * 0.5
    if avg_wing_up.length_squared() < 0.001:
        avg_wing_up = Vector3.UP
    else:
        avg_wing_up = avg_wing_up.normalized()

    # bank angle from avg wing up tilt (roll)
    var bank_angle = atan2(avg_wing_up.x, avg_wing_up.y) # rad, -PI..PI
    # desktop Q/E bank override: use hand height diff
    if not _xr_active:
        var hand_bank = clamp((right_pos.y - left_pos.y) * 2.2, -1.0, 1.0)
        bank_angle = hand_bank * deg_to_rad(45)

    _bank_smooth = lerp(_bank_smooth, bank_angle, delta * 4.0)

    # pitch: from head / wing forward pitch
    # head pitch: look down = dive
    var head_forward = -head_basis.z
    head_forward.y = 0
    head_forward = head_forward.normalized() if head_forward.length_squared() > 0.001 else Vector3.FORWARD
    var head_pitch = asin(clamp((-head_basis.z).y, -1.0, 1.0)) # positive when looking up
    # wing pitch (AoA): average of wing normals vs -forward
    var avg_wing_forward = -(left_basis.z + right_basis.z) * 0.5
    avg_wing_forward = avg_wing_forward.normalized()
    var wing_pitch = asin(clamp(avg_wing_forward.y, -1.0, 1.0))
    var combined_pitch = head_pitch * 0.65 + wing_pitch * 0.35
    _pitch_smooth = lerp(_pitch_smooth, combined_pitch, delta * 3.2)

    var airspeed = velocity.length()
    _speed_smooth = lerp(_speed_smooth, airspeed, delta * 2.5)

    # --- perching check ---
    var can_perch = false
    if perch_ray and perch_ray.is_colliding():
        var d = perch_ray.get_collision_point().distance_to(global_position)
        if airspeed < perch_speed_threshold * 1.2 and d < 2.2:
            can_perch = true

    # if perched: lock unless flap
    if is_perched:
        # damp motion
        velocity = velocity.lerp(Vector3.ZERO, delta * 4.0)
        if airspeed > 0.5:
            move_and_slide()
        # check take-off already handled in _do_flap (it unperches)
        # also auto-unperch if looking away and small input
        if not _xr_active and Input.is_key_pressed(KEY_SPACE):
            is_perched = false
        if perch_ray and not perch_ray.is_colliding():
            # still allow staying if over air? but if player moves off branch, fall
            pass
        # slight bob
        return

    # Try to auto-perch if slow and near branch and not flapping recently
    if can_perch and airspeed < perch_speed_threshold and _flap_timer > 0.32:
        # require wings somewhat level?
        if abs(_bank_smooth) < deg_to_rad(28):
            if perch_ray.get_collider() and perch_ray.get_collider().is_in_group("perch"):
                is_perched = true
                velocity = Vector3.ZERO
                print("[Soaring] Perched on ", perch_ray.get_collider().name)
                return

    # --- gravity & lift ---
    # base gravity
    var accel = Vector3(0, -gravity, 0)

    # lift: opposing gravity when you have airspeed + wing spread + correct AoA
    # stall handling
    var aoa_deg = rad_to_deg(abs(combined_pitch)) # roughly
    var is_stall = (airspeed < stall_speed and aoa_deg > stall_angle_deg) or (airspeed < 2.0 and wing_spread < 0.35)
    var lift_eff: float = 1.0
    if is_stall:
        lift_eff = 0.28
    else:
        # high AoA reduces efficiency slightly at high speed
        lift_eff = clamp(1.0 - max(0, aoa_deg - 14) * 0.018, 0.45, 1.0)

    # spread bonus: too tucked = no lift
    var spread_lift = lerp(0.18, 1.0, wing_spread)

    var lift_mag = 0.0
    if airspeed > 0.7:
        # classic: lift ~ v * coeff * spread * efficiency, tuned so level glide ~86% gravity at 13 m/s
        lift_mag = airspeed * glide_lift_coeff * spread_lift * lift_eff * (1.0 + clamp(airspeed * 0.012, 0, 0.24))
        # pitch modifier: pitched up (positive) gives a touch more lift but more drag; pitched down trades lift for thrust
        if _pitch_smooth > 0:
            lift_mag *= 1.0 + clamp(_pitch_smooth * 0.55, 0, 0.35)
        else:
            lift_mag *= 1.0 + clamp(_pitch_smooth * 0.35, -0.28, 0) # dive loses lift

    # lift vector is primarily up, but tilted with bank
    var lift_vec: Vector3
    if is_stall:
        lift_vec = Vector3.UP * lift_mag * 0.55 + avg_wing_up * lift_mag * 0.45
    else:
        # blend between world up and wing up based on bank severity
        var bank_factor = clamp(abs(_bank_smooth) / deg_to_rad(55), 0, 1)
        lift_vec = Vector3.UP.lerp(avg_wing_up, bank_factor * 0.92) * lift_mag

    accel += lift_vec

    # --- thrust & pitch dive ---
    # when pitched down, convert altitude to speed (dive)
    if _pitch_smooth < -0.12:
        var dive_strength = clamp(-_pitch_smooth * 1.8, 0, 1.0)
        # more dive = more forward accel
        var dive_thrust = head_basis.z * 0.0 # placeholder
        # forward direction is head forward horizontal
        var horiz_forward = -head_basis.z
        horiz_forward.y = 0
        if horiz_forward.length_squared() > 0.001:
            horiz_forward = horiz_forward.normalized()
            accel += horiz_forward * dive_strength * pitch_dive_rate * lerp(0.9, 1.35, clamp(airspeed/16, 0, 1))
        # also add downwards accel a bit (gravity assist)
        accel.y -= dive_strength * 2.4

    # slight pitch-up climb requires speed bleed
    if _pitch_smooth > 0.18 and airspeed > 7:
        var climb_drag = clamp(_pitch_smooth * 2.0, 0, 1)
        # converting speed to altitude: reduce forward speed but lift helps hold
        accel -= velocity.normalized() * climb_drag * 2.2

    # --- turning from bank ---
    if abs(_bank_smooth) > 0.08:
        var turn_power = _bank_smooth * bank_turn_rate * clamp(airspeed / 7.0, 0.35, 1.6)
        # lateral accel
        var right_dir = head_basis.x
        accel += right_dir * turn_power * 7.0
        # yaw rotation (banked turn): rotate velocity vector
        var yaw_rate = turn_power * 0.9
        # apply yaw to the character's facing (so head yaw follows turn)
        if not _xr_active:
            _desktop_yaw += yaw_rate * delta
        else:
            # in VR, we yaw the whole player body so forward aligns with velocity
            # rotate velocity around up
            velocity = velocity.rotated(Vector3.UP, yaw_rate * delta)
        # also rotate the player node itself for visual / collider alignment
        rotate_y(yaw_rate * delta * 0.65)

    # --- drag ---
    var drag_factor = base_drag * (1.0 + (1.0 - spread_lift) * 0.25 + (1.0 if is_stall else 0.0) * 0.9)
    # high speed drag increases quadratically
    drag_factor += clamp(airspeed * 0.003, 0, 0.06)
    # banked flight increases induced drag
    drag_factor += abs(_bank_smooth) * 0.018

    velocity += accel * delta
    # --- corrected drag (per-second, not per-tick) ---
    velocity *= (1.0 - clamp(drag_factor * delta * 1.45, 0.0, 0.62))

    # sanitize NaN/INF
    if not velocity.is_finite():
        velocity = Vector3.FORWARD * 8.0
    # speed clamp
    var _vlen: float = velocity.length()
    if not is_finite(_vlen):
        velocity = Vector3.FORWARD * 8.0
    elif _vlen > max_speed:
        velocity = velocity.normalized() * max_speed

    # always keep a tiny forward creep when not perched and not stalled fully, to avoid dead hover
    if not is_stall and airspeed < 1.2 and wing_spread > 0.6:
        var fwd = -head_basis.z
        fwd.y *= 0.15
        velocity += fwd.normalized() * 1.2 * delta

    # --- collide & move ---
    # add small hover safeguard above ground
    if global_position.y < 1.2 and velocity.y < 0:
        velocity.y = max(velocity.y, -1.2)
        if global_position.y < 0.8:
            global_position.y = 0.8
            velocity.y = max(velocity.y, 0)
            if airspeed < 2.0:
                is_perched = false # not perched, just bumped ground

    var prev_vel = velocity
    move_and_slide()
    # stick to floor lightly? we want flight, so no
    # clamp world bounds
    var lim = 190.0
    if abs(global_position.x) > lim or abs(global_position.z) > lim:
        var to_center = Vector3.ZERO - global_position
        to_center.y = 0
        velocity += to_center.normalized() * 8.0 * delta
    if global_position.y > 85.0:
        velocity.y -= 9.0 * delta
    if global_position.y < 0.9:
        global_position.y = 0.9

    # --- wing mesh visual scale ---
    if wing_left_mesh and wing_right_mesh:
        var flap_anim = sin(Time.get_ticks_msec() / 90.0) * 0.08 if _flap_timer > 0 else 0
        wing_left_mesh.scale = Vector3.ONE * player_size
        wing_right_mesh.scale = Vector3.ONE * player_size
        # optional tilt visual via rotation

    # --- debug telemetry every ~0.6s ---
    if Engine.get_frames_drawn() % 38 == 0:
        # could update UI via GameManager
        pass

func _do_flap(power: float, is_sync: bool):
    power = clamp(power, 0.45, 2.0)
    var forward = Vector3.FORWARD
    if _xr_active and xr_camera:
        forward = -xr_camera.global_transform.basis.z
    else:
        forward = Basis.from_euler(Vector3(_desktop_pitch, _desktop_yaw, 0)).z * -1

    forward.y *= 0.45
    forward = forward.normalized()

    var lift_imp = flap_lift * power * (1.25 if is_sync else 1.0)
    # AoA at flap moment affects efficiency: if stalled, weaker
    if _pitch_smooth > deg_to_rad(28) and _speed_smooth < stall_speed:
        lift_imp *= 0.55

    var thrust_imp = flap_thrust * power * (1.15 if is_sync else 0.85)
    # scale with size: larger birds need more flap but get more momentum (scale slightly)
    var size_factor = clamp(player_size, 0.9, 2.2)
    lift_imp *= lerp(1.0, 0.88, (size_factor -1)/1.2)
    thrust_imp *= lerp(1.0, 0.92, (size_factor -1)/1.2)

    # apply impulses
    velocity.y += lift_imp
    velocity += forward * thrust_imp

    # if perched, strong take-off
    if is_perched:
        velocity.y += 3.2
        velocity += forward * 4.0
        is_perched = false
        print("[Soaring] Take-off flap power=", snapped(power,0.05))

    # flap count anim
    flap_count += 1
    # clamp
    if velocity.length() > max_speed * 1.1:
        velocity = velocity.normalized() * max_speed * 1.1

func update_scale():
    if not is_finite(player_size):
        player_size = 1.0
    var s: float = clamp(player_size, 0.65, 3.0)
    if not is_finite(s):
        s = 1.0
    scale = Vector3.ONE * s
    if body_collision and body_collision.shape:
        # collision radius scales via node scale, no extra
        pass
    # inform HUD
    size_changed.emit(player_size)

func grow(amount: float):
    player_size = clamp(player_size + amount, 0.65, 3.2)
    score += 1
    update_scale()
    bird_caught.emit(1, player_size)
    print("[Soaring] GROW to ", snapped(player_size,0.01), " score ", score)
    # flash
    if body_mesh:
        var tw = create_tween()
        tw.tween_property(body_mesh, "scale", Vector3.ONE*1.22, 0.12)
        tw.tween_property(body_mesh, "scale", Vector3.ONE, 0.22)

func shrink(amount: float):
    player_size = max(0.7, player_size - amount)
    update_scale()

# --- catching ---
func _on_catch_area_body_entered(body):
    _try_catch(body)

func _on_catch_area_entered(area):
    var p = area.get_parent()
    if p and p.has_method("get_bird_size"):
        _try_catch(p)

func _try_catch(other: Node):
    if other == null or not is_instance_valid(other) or not other.has_method("get_bird_size"):
        return
    var _raw = other.get_bird_size()
    if typeof(_raw) != TYPE_FLOAT and typeof(_raw) != TYPE_INT:
        return
    var other_size: float = float(_raw)
    if not is_finite(other_size):
        return
    # small grace
    if other_size < player_size * 0.92:
        # we eat them
        if other.has_method("be_eaten"):
            other.be_eaten()
        grow(0.12 + other_size * 0.06)
        # haptic success
        if _xr_active and left_ctrl:
            left_ctrl.trigger_haptic_pulse("haptic", 0.9, 120, 1.0, 0)
    elif other_size > player_size * 1.08:
        # we get eaten -> respawn smaller
        print("[Soaring] Got caught by size ", other_size, " vs ", player_size)
        player_caught_by.emit(other_size)
        # knockback and shrink instead of instant death for playability
        velocity += (global_position - other.global_position).normalized() * 9.0 + Vector3.UP * 4.0
        shrink(0.22)
        # invuln flash? simplified
        if other.has_method("on_ate_player"):
            other.on_ate_player(self)

func get_bird_size() -> float:
    return player_size

func be_eaten():
    if not is_instance_valid(self):
        return
    # respawn at safe height
    global_position = Vector3(randf_range(-18.0, 18.0), randf_range(18.0, 32.0), randf_range(-18.0, 18.0))
    var rnd: Vector3 = Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-4.0, -1.0))
    velocity = rnd * 2.0
    if not velocity.is_finite():
        velocity = Vector3.FORWARD * 6.0
    shrink(0.18)
    print("[Soaring] Player respawned")

func on_ate_player(_player):
    pass

func is_finite(v: float) -> bool:
    return not is_nan(v) and not is_inf(v)
