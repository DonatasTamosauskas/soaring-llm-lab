extends CharacterBody3D

## Soaring — VR Bird Flight Player v2
## Fixed: local-hand flap detection, energy-conserving dive, level sink, bank via hand diff
## Exposes test hooks: _test_set_hand_local(left_local, right_local, head_basis) and _test_force_flap

@export var gravity: float = 9.8
@export var flap_lift: float = 7.2
@export var flap_thrust: float = 6.8
@export var flap_threshold: float = 1.65
@export var flap_cooldown: float = 0.22
@export var flap_min_amplitude: float = 0.22  # meters down-stroke required
@export var glide_lift_coeff: float = 0.55
@export var bank_turn_rate: float = 1.15
@export var base_drag: float = 0.82
@export var stall_speed: float = 5.5
@export var stall_angle_deg: float = 24.0
@export var max_speed: float = 28.0
@export var perch_speed_threshold: float = 3.4

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

@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var beak_mesh: MeshInstance3D = $BodyMesh/Beak
@onready var tail_mesh: MeshInstance3D = $BodyMesh/Tail

# --- state ---
var player_size: float = 1.0
var score: int = 0
var is_perched: bool = false
var flap_count: int = 0

# internal
var _flap_timer: float = 0.0
var _has_prev: bool = false
var _left_local_prev: Vector3 = Vector3.ZERO
var _right_local_prev: Vector3 = Vector3.ZERO
var _left_vel_local_y: float = 0.0
var _right_vel_local_y: float = 0.0
var _xr_active: bool = false
var _desktop_yaw: float = 0.0
var _desktop_pitch: float = 0.0
var _bank_smooth: float = 0.0
var _pitch_smooth: float = 0.0
var _speed_smooth: float = 0.0
var _test_override: bool = false
var _test_left_local: Vector3 = Vector3.ZERO
var _test_right_local: Vector3 = Vector3.ZERO
var _test_head_basis: Basis = Basis.IDENTITY

# Per-hand flap state machine
class HandFlapState:
    var peak_y: float = 0.0
    var trough_y: float = 0.0
    var moving_down: bool = false
    var max_down_speed: float = 0.0
    var last_y: float = 0.0
    var has_prev: bool = false

var _left_hand_state: HandFlapState = HandFlapState.new()
var _right_hand_state: HandFlapState = HandFlapState.new()
var _last_sync_time: float = -999.0

signal bird_caught(value: int, new_size: float)
signal player_caught_by(bigger_size: float)
signal size_changed(new_size: float)

func _ready():
    var xr_interface = XRServer.find_interface("OpenXR")
    if xr_interface and xr_interface.is_initialized():
        get_viewport().use_xr = true
        _xr_active = true
        print("[Soaring v2] XR active — LOCAL-hand flap + energy dive")
    else:
        if xr_interface:
            get_viewport().use_xr = true
            _xr_active = xr_interface.is_initialized()
        print("[Soaring v2] Desktop fallback — mouse + space")
    if not _xr_active:
        Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    if catch_area:
        if not catch_area.body_entered.is_connected(_on_catch_area_body_entered):
            catch_area.body_entered.connect(_on_catch_area_body_entered)
        if not catch_area.area_entered.is_connected(_on_catch_area_entered):
            catch_area.area_entered.connect(_on_catch_area_entered)
    if perch_ray:
        perch_ray.enabled = true
    add_to_group("player")
    update_scale()
    # Ensure no initial false flap
    _has_prev = false
    _flap_timer = 0.22

func _input(event):
    if _test_override:
        return
    if not _xr_active:
        if event is InputEventMouseMotion:
            _desktop_yaw -= event.relative.x * 0.0032
            _desktop_pitch = clamp(_desktop_pitch - event.relative.y * 0.0032, deg_to_rad(-78), deg_to_rad(58))
        if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
            _do_flap(1.0, true)
        if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
            if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
                Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            else:
                Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# ---- TEST HOOKS ----
func _test_set_hand_local(left_local: Vector3, right_local: Vector3, head_basis: Basis):
    _test_override = true
    _test_left_local = left_local
    _test_right_local = right_local
    _test_head_basis = head_basis

func _test_clear_override():
    _test_override = false

func _test_force_flap(power: float = 1.0):
    _do_flap(power, true)

func _test_get_state() -> Dictionary:
    return {
        "velocity": velocity,
        "position": global_position,
        "is_perched": is_perched,
        "flap_count": flap_count,
        "bank_smooth": _bank_smooth,
        "pitch_smooth": _pitch_smooth,
        "speed": velocity.length(),
        "player_size": player_size,
    }

func _physics_process(delta: float):
    if not is_finite(delta) or delta <= 0.0:
        return
    delta = clamp(delta, 0.0, 0.05)
    _flap_timer = max(0.0, _flap_timer - delta)

    var head_basis: Basis
    var left_local: Vector3
    var right_local: Vector3
    var left_basis: Basis
    var right_basis: Basis

    if _test_override:
        left_local = _test_left_local
        right_local = _test_right_local
        head_basis = _test_head_basis
        left_basis = head_basis
        right_basis = head_basis
    elif _xr_active and left_ctrl and right_ctrl and xr_origin and xr_camera and is_instance_valid(left_ctrl) and is_instance_valid(right_ctrl):
        # LOCAL hand pos relative to XROrigin (player body) — eliminates world drift contamination
        left_local = xr_origin.to_local(left_ctrl.global_position)
        right_local = xr_origin.to_local(right_ctrl.global_position)
        left_basis = left_ctrl.global_transform.basis
        right_basis = right_ctrl.global_transform.basis
        head_basis = xr_camera.global_transform.basis
    else:
        # Desktop simulated hands relative to body (stored directly as local)
        var forward = Basis.from_euler(Vector3(_desktop_pitch, _desktop_yaw, 0)).z * -1
        var right_vec = Basis.from_euler(Vector3(0, _desktop_yaw, 0)).x
        var up_vec = Vector3.UP
        # hands 0.65m apart, 0.45 forward, local space
        left_local = Vector3(-0.62, 0.02, -0.45)  # x,y,z in local (z forward negative?)
        right_local = Vector3(0.62, 0.02, -0.45)
        # apply Q/E bank offset in local
        if Input.is_key_pressed(KEY_Q):
            left_local.y -= 0.28
            right_local.y += 0.28
        if Input.is_key_pressed(KEY_E):
            left_local.y += 0.28
            right_local.y -= 0.28
        # convert to global for head basis but keep local for flap
        head_basis = Basis.from_euler(Vector3(_desktop_pitch, _desktop_yaw, 0))
        if Input.is_key_pressed(KEY_W):
            head_basis = Basis.from_euler(Vector3(deg_to_rad(-28), _desktop_yaw, 0))
        elif Input.is_key_pressed(KEY_S):
            head_basis = Basis.from_euler(Vector3(deg_to_rad(30), _desktop_yaw, 0))
        left_basis = head_basis
        right_basis = head_basis
        # For desktop also set left/right global for bank calc compatibility
        # but flap detection uses local y

    # --- robust flap detection (local y, amplitude-gated) ---
    if _has_prev:
        _left_vel_local_y = (left_local.y - _left_local_prev.y) / delta
        _right_vel_local_y = (right_local.y - _right_local_prev.y) / delta
    else:
        _left_vel_local_y = 0.0
        _right_vel_local_y = 0.0
        # init hand states
        _left_hand_state.last_y = left_local.y
        _left_hand_state.peak_y = left_local.y
        _left_hand_state.trough_y = left_local.y
        _left_hand_state.has_prev = true
        _right_hand_state.last_y = right_local.y
        _right_hand_state.peak_y = right_local.y
        _right_hand_state.trough_y = right_local.y
        _right_hand_state.has_prev = true

    # Update hand state machines for flap stroke detection
    var left_flapped: bool = false
    var right_flapped: bool = false
    var left_power: float = 0.0
    var right_power: float = 0.0
    if _flap_timer <= 0.0:
        left_flapped = _update_hand_flap(_left_hand_state, left_local.y, _left_vel_local_y, delta, left_power)
        if left_flapped:
            left_power = _get_last_power(_left_hand_state)
        right_flapped = _update_hand_flap(_right_hand_state, right_local.y, _right_vel_local_y, delta, right_power)
        if right_flapped:
            right_power = _get_last_power(_right_hand_state)

        var now_t: float = Time.get_ticks_msec() / 1000.0
        if left_flapped and right_flapped:
            var power: float = (left_power + right_power) * 0.5 * 1.22
            var hand_dist: float = left_local.distance_to(right_local)
            var spread: float = clamp(hand_dist / 1.35, 0.25, 1.0)
            power *= lerp(0.82, 1.0, spread)
            _do_flap(clamp(power, 0.55, 1.85), true)
            _flap_timer = flap_cooldown
            _last_sync_time = now_t
            if _xr_active and left_ctrl and right_ctrl and is_instance_valid(left_ctrl) and is_instance_valid(right_ctrl):
                left_ctrl.trigger_haptic_pulse("haptic", 0.55, 75, 0.0, 0)
                right_ctrl.trigger_haptic_pulse("haptic", 0.55, 75, 0.0, 0)
        elif left_flapped and (now_t - _last_sync_time) > 0.24:
            _do_flap(clamp(left_power * 0.72, 0.45, 1.35), false)
            _flap_timer = flap_cooldown * 0.85
            if _xr_active and left_ctrl and is_instance_valid(left_ctrl):
                left_ctrl.trigger_haptic_pulse("haptic", 0.32, 50, 0, 0)
        elif right_flapped and (now_t - _last_sync_time) > 0.24:
            _do_flap(clamp(right_power * 0.72, 0.45, 1.35), false)
            _flap_timer = flap_cooldown * 0.85
            if _xr_active and right_ctrl and is_instance_valid(right_ctrl):
                right_ctrl.trigger_haptic_pulse("haptic", 0.32, 50, 0, 0)
    else:
        _advance_hand_state(_left_hand_state, left_local.y, _left_vel_local_y)
        _advance_hand_state(_right_hand_state, right_local.y, _right_vel_local_y)

    # Desktop space flap override — respects cooldown
    if not _test_override and not _xr_active:
        if Input.is_action_pressed("flap") or Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            if _flap_timer <= 0.0:
                _do_flap(1.0, true)
                _flap_timer = 0.24

    _left_local_prev = left_local
    _right_local_prev = right_local
    _has_prev = true

    # --- wing metrics (spread & bank & pitch) ---
    var hand_dist_local: float = left_local.distance_to(right_local)
    var wing_spread: float = clamp(hand_dist_local / 1.35, 0.18, 1.0)
    # hand diff bank (most reliable)
    var hand_diff: float = right_local.y - left_local.y
    var bank_from_hands: float = clamp(hand_diff * 1.85, -1.0, 1.0) * deg_to_rad(42)
    # wing roll bank from average wing up (for XR roll)
    var avg_wing_up: Vector3 = (left_basis.y + right_basis.y) * 0.5
    if avg_wing_up.length_squared() < 0.001:
        avg_wing_up = Vector3.UP
    else:
        avg_wing_up = avg_wing_up.normalized()
    var bank_from_wing: float = atan2(avg_wing_up.x, avg_wing_up.y)
    # Blend: trust hands diff 60% + wing roll 40% in XR, 100% hands in desktop
    var bank_angle: float
    if _xr_active:
        bank_angle = bank_from_hands * 0.62 + bank_from_wing * 0.38
    else:
        bank_angle = bank_from_hands
    _bank_smooth = lerp(_bank_smooth, bank_angle, delta * 4.8)

    # pitch
    var head_pitch: float = asin(clamp((-head_basis.z).y, -1.0, 1.0))
    var avg_wing_forward: Vector3 = -(left_basis.z + right_basis.z) * 0.5
    if avg_wing_forward.length_squared() > 0.001:
        avg_wing_forward = avg_wing_forward.normalized()
    else:
        avg_wing_forward = -head_basis.z
    var wing_pitch: float = asin(clamp(avg_wing_forward.y, -1.0, 1.0))
    var combined_pitch: float = head_pitch * 0.72 + wing_pitch * 0.28
    _pitch_smooth = lerp(_pitch_smooth, combined_pitch, delta * 3.6)

    var airspeed: float = velocity.length()
    _speed_smooth = lerp(_speed_smooth, airspeed, delta * 2.8)

    # --- perching ---
    var can_perch: bool = false
    var perch_collider: Node = null
    if perch_ray and perch_ray.is_colliding():
        var d: float = perch_ray.get_collision_point().distance_to(global_position)
        perch_collider = perch_ray.get_collider()
        if airspeed < perch_speed_threshold * 1.15 and d < 2.4 and perch_collider and perch_collider.is_in_group("perch"):
            can_perch = true

    if is_perched:
        velocity = velocity.lerp(Vector3.ZERO, delta * 5.0)
        if airspeed > 0.25:
            move_and_slide()
        if not _test_override and Input.is_key_pressed(KEY_SPACE) and not _xr_active:
            is_perched = false
        return

    if can_perch and airspeed < perch_speed_threshold and _flap_timer > 0.34:
        if abs(_bank_smooth) < deg_to_rad(30):
            is_perched = true
            velocity = Vector3.ZERO
            print("[Soaring v2] Perched on ", perch_collider.name if perch_collider else "?")
            return

    # --- aerodynamics (energy-conserving) ---
    var aoa_deg: float = rad_to_deg(abs(combined_pitch))
    var is_stall: bool = (airspeed < stall_speed and aoa_deg > stall_angle_deg) or (airspeed < 2.2 and wing_spread < 0.32)
    var lift_eff: float = 1.0
    if is_stall:
        lift_eff = 0.24
    else:
        lift_eff = clamp(1.0 - max(0.0, aoa_deg - 15.0) * 0.018, 0.42, 1.0)

    var spread_lift: float = lerp(0.14, 1.0, wing_spread)

    var accel: Vector3 = Vector3(0, -gravity, 0)

    var lift_mag: float = 0.0
    if airspeed > 0.65:
        lift_mag = airspeed * glide_lift_coeff * spread_lift * lift_eff * (1.0 + clamp(airspeed * 0.011, 0.0, 0.22))
        if _pitch_smooth > 0.08:
            lift_mag *= 1.0 + clamp(_pitch_smooth * 0.42, 0.0, 0.28)
        elif _pitch_smooth < -0.08:
            lift_mag *= clamp(1.0 + _pitch_smooth * 0.52, 0.62, 1.0)  # dive reduces lift

    # stall: lift is mushy and tilted randomly
    var lift_vec: Vector3
    if is_stall:
        lift_vec = Vector3.UP * lift_mag * 0.42 + avg_wing_up * lift_mag * 0.22
    else:
        var bank_factor: float = clamp(abs(_bank_smooth) / deg_to_rad(52), 0.0, 1.0)
        lift_vec = Vector3.UP.lerp(avg_wing_up, bank_factor * 0.88) * lift_mag

    accel += lift_vec

    # --- dive / climb energy exchange ---
    # Use component of gravity along forward to trade altitude for speed
    var forward: Vector3 = -head_basis.z
    # ensure forward is roughly normalized
    if forward.length_squared() > 0.001:
        forward = forward.normalized()
    else:
        forward = Vector3.FORWARD
    # dive: when pitch negative, gravity component along forward accelerates you
    if _pitch_smooth < -0.10:
        var dive_factor: float = clamp(-_pitch_smooth / deg_to_rad(34), 0.0, 1.0)
        # thrust from gravity projected onto forward — energy conserving
        var grav_along_forward: float = gravity * -forward.y  # positive when forward points down
        if grav_along_forward < 0:
            grav_along_forward = 0
        # scale with speed (more energy to gain at moderate speeds)
        var dive_thrust: float = grav_along_forward * dive_factor * 0.88 * lerp(0.85, 1.25, clamp(airspeed / 18.0, 0.0, 1.0))
        # apply along forward (mostly horizontal + down)
        accel += forward * dive_thrust
        # slight extra down accel already comes from lift reduction above
    elif _pitch_smooth > 0.18 and airspeed > 7.0:
        # climb: convert speed to altitude — induce drag
        var climb_factor: float = clamp(_pitch_smooth / deg_to_rad(28), 0.0, 1.0)
        # bleed speed
        var bleed: float = climb_factor * 3.4 * clamp(airspeed / 14.0, 0.4, 1.2)
        if velocity.length_squared() > 0.001:
            accel -= velocity.normalized() * bleed

    # --- banked turn ---
    if abs(_bank_smooth) > 0.07:
        var turn_power: float = _bank_smooth * bank_turn_rate * clamp(airspeed / 8.0, 0.3, 1.65)
        var right_dir: Vector3 = head_basis.x
        # bank creates lateral acceleration (coordinated turn)
        accel += right_dir * turn_power * 8.2
        var yaw_rate: float = turn_power * 0.86
        if not _xr_active:
            _desktop_yaw += yaw_rate * delta
        else:
            # rotate velocity vector around world up for coordinated turn
            velocity = velocity.rotated(Vector3.UP, yaw_rate * delta)
        rotate_y(yaw_rate * delta * 0.62)

    # --- drag ---
    var drag_factor: float = base_drag * (1.0 + (1.0 - spread_lift) * 0.32)
    if is_stall:
        drag_factor += 0.92
    drag_factor += clamp(airspeed * 0.0028, 0.0, 0.055)
    drag_factor += abs(_bank_smooth) * 0.022

    velocity += accel * delta
    # per-second exponential drag
    velocity *= (1.0 - clamp(drag_factor * delta * 1.45, 0.0, 0.64))

    if not velocity.is_finite():
        velocity = Vector3.FORWARD * 8.0
    var vlen: float = velocity.length()
    if not is_finite(vlen):
        velocity = Vector3.FORWARD * 8.0
    elif vlen > max_speed:
        velocity = velocity.normalized() * max_speed

    # tiny forward creep to avoid dead hang when spread
    if not is_stall and vlen < 1.0 and wing_spread > 0.58:
        var fwd_creep: Vector3 = forward
        fwd_creep.y *= 0.12
        if fwd_creep.length_squared() > 0.001:
            velocity += fwd_creep.normalized() * 0.9 * delta

    if global_position.y < 1.05 and velocity.y < 0:
        velocity.y = max(velocity.y, -1.0)
        if global_position.y < 0.85:
            global_position.y = 0.85
            velocity.y = max(velocity.y, 0.0)

    move_and_slide()

    var lim: float = 188.0
    if abs(global_position.x) > lim or abs(global_position.z) > lim:
        var to_center: Vector3 = Vector3.ZERO - global_position
        to_center.y = 0
        if to_center.length_squared() > 0.001:
            velocity += to_center.normalized() * 8.0 * delta
    if global_position.y > 88.0:
        velocity.y -= 9.0 * delta
    if global_position.y < 0.85:
        global_position.y = 0.85

# helpers for flap state machine
func _advance_hand_state(state: HandFlapState, y: float, vy: float):
    if not state.has_prev:
        state.last_y = y
        state.peak_y = y
        state.trough_y = y
        state.has_prev = true
        return
    # update peak/trough tracking
    if vy < -0.12:
        # moving down
        if not state.moving_down:
            state.moving_down = true
            state.peak_y = state.last_y  # peak before down
            state.max_down_speed = 0.0
        state.max_down_speed = max(state.max_down_speed, -vy)
        state.trough_y = min(state.trough_y, y)
    elif vy > 0.12:
        if state.moving_down:
            state.moving_down = false
            state.trough_y = y
        state.peak_y = max(state.peak_y, y)
        state.trough_y = y  # reset trough when moving up
    state.last_y = y

func _update_hand_flap(state: HandFlapState, y: float, vy: float, delta: float, power_out: float) -> bool:
    # combined advance + check in one — returns flap detected
    if not state.has_prev:
        state.last_y = y
        state.peak_y = y
        state.trough_y = y
        state.has_prev = true
        return false
    var was_down: bool = state.moving_down
    # detect direction
    if vy < -0.18:
        if not state.moving_down:
            state.moving_down = true
            state.peak_y = state.last_y
            state.max_down_speed = 0.0
            state.trough_y = y
        state.max_down_speed = max(state.max_down_speed, -vy)
        state.trough_y = min(state.trough_y, y)
    elif vy > 0.34:
        if state.moving_down:
            # just finished down stroke — evaluate flap
            state.moving_down = false
            var amplitude: float = state.peak_y - state.trough_y
            var speed: float = state.max_down_speed
            # reset for next up
            state.peak_y = y
            # flap criteria: amplitude and speed
            if amplitude > flap_min_amplitude and speed > flap_threshold:
                var p: float = clamp((speed - flap_threshold) * 0.62 + amplitude * 1.18, 0.0, 1.85)
                # we cannot return power via param in GDScript easily, so store in state temporarily
                state.set_meta("last_power", p)
                state.last_y = y
                return true
            state.last_y = y
            return false
        state.peak_y = max(state.peak_y, y)
    state.last_y = y
    return false

func _get_last_power(state: HandFlapState) -> float:
    if state.has_meta("last_power"):
        return float(state.get_meta("last_power"))
    return 0.0

func _do_flap(power: float, is_sync: bool):
    power = clamp(power, 0.42, 1.95)
    var forward: Vector3 = Vector3.FORWARD
    if _test_override:
        forward = -_test_head_basis.z
    elif _xr_active and xr_camera and is_instance_valid(xr_camera):
        forward = -xr_camera.global_transform.basis.z
    else:
        forward = Basis.from_euler(Vector3(_desktop_pitch, _desktop_yaw, 0)).z * -1

    forward.y *= 0.38
    if forward.length_squared() > 0.001:
        forward = forward.normalized()
    else:
        forward = Vector3.FORWARD

    var lift_imp: float = flap_lift * power * (1.18 if is_sync else 1.0)
    if _pitch_smooth > deg_to_rad(32) and _speed_smooth < stall_speed:
        lift_imp *= 0.52

    var thrust_imp: float = flap_thrust * power * (1.12 if is_sync else 0.82)
    var size_factor: float = clamp(player_size, 0.9, 2.2)
    lift_imp *= lerp(1.0, 0.86, (size_factor - 1.0) / 1.2)
    thrust_imp *= lerp(1.0, 0.90, (size_factor - 1.0) / 1.2)

    velocity.y += lift_imp
    velocity += forward * thrust_imp

    if is_perched:
        velocity.y += 3.4
        velocity += forward * 4.2
        is_perched = false
        print("[Soaring v2] Take-off flap power=", snapped(power, 0.05))

    flap_count += 1
    if not velocity.is_finite():
        velocity = Vector3.FORWARD * 8.0
    if velocity.length() > max_speed * 1.12:
        velocity = velocity.normalized() * max_speed * 1.12

func update_scale():
    if not is_finite(player_size):
        player_size = 1.0
    var s: float = clamp(player_size, 0.65, 3.0)
    if not is_finite(s):
        s = 1.0
    scale = Vector3.ONE * s

func grow(amount: float):
    if not is_finite(amount):
        return
    player_size = clamp(player_size + amount, 0.65, 3.2)
    score += 1
    update_scale()
    bird_caught.emit(1, player_size)
    print("[Soaring v2] GROW to ", snapped(player_size, 0.01), " score ", score)
    if body_mesh and is_instance_valid(body_mesh):
        var tw: Tween = create_tween()
        if tw:
            tw.tween_property(body_mesh, "scale", Vector3.ONE * 1.22, 0.12)
            tw.tween_property(body_mesh, "scale", Vector3.ONE, 0.22)

func shrink(amount: float):
    if not is_finite(amount):
        return
    player_size = max(0.7, player_size - amount)
    update_scale()

func _on_catch_area_body_entered(body: Node):
    _try_catch(body)

func _on_catch_area_entered(area: Area3D):
    var p: Node = area.get_parent()
    if p and is_instance_valid(p) and p.has_method("get_bird_size"):
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
    other_size = clamp(other_size, 0.55, 3.2)
    if other_size < player_size * 0.92:
        if other.has_method("be_eaten"):
            other.be_eaten()
        grow(0.12 + other_size * 0.06)
        if _xr_active and left_ctrl and is_instance_valid(left_ctrl):
            left_ctrl.trigger_haptic_pulse("haptic", 0.9, 120, 1.0, 0)
    elif other_size > player_size * 1.08:
        print("[Soaring v2] Got caught by size ", other_size, " vs ", player_size)
        player_caught_by.emit(other_size)
        var diff: Vector3 = global_position - other.global_position
        if diff.length_squared() > 0.001:
            velocity += diff.normalized() * 9.0 + Vector3.UP * 4.0
        else:
            velocity += Vector3.UP * 4.0
        if not velocity.is_finite():
            velocity = Vector3.FORWARD * 6.0
        shrink(0.22)
        if other.has_method("on_ate_player"):
            other.on_ate_player(self)

func get_bird_size() -> float:
    return player_size

func be_eaten():
    if not is_instance_valid(self):
        return
    global_position = Vector3(randf_range(-18.0, 18.0), randf_range(18.0, 32.0), randf_range(-18.0, 18.0))
    var rnd: Vector3 = Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-4.0, -1.0))
    velocity = rnd * 2.0
    if not velocity.is_finite():
        velocity = Vector3.FORWARD * 6.0
    shrink(0.18)
    print("[Soaring v2] Player respawned")

func on_ate_player(_player):
    pass

func is_finite(v: float) -> bool:
    return not is_nan(v) and not is_inf(v)