class_name BirdPlayer
extends CharacterBody3D

## The player's bird. Owns a [FlightModel], feeds it from the wings (XR) or
## the keyboard, and moves the body through the world with collisions.
## The XR origin is a child: the camera sits on the bird's back, the origin
## yaws with the heading, and rolls with a comfort-scaled fraction of the bank.

signal perched_changed(perched: bool)
signal collided(speed: float, normal: Vector3)
signal launched()
signal wingbeat(strength: float)

const PERCH_SPEED: float = 6.0       # m/s or slower against a surface: land
const GRIP_PERCH_SPEED: float = 11.0 # with a grip held you can cling harder
const CRASH_SPEED: float = 12.0      # faster than this into a wall: it hurts
const LAUNCH_SPEED_FACTOR: float = 1.35  # x stall speed when leaving a perch
const CAMERA_ROLL_FRACTION_DEFAULT: float = 0.35

var model: FlightModel = FlightModel.new(1.0)
var wings: WingInput = WingInput.new()
var keys: KeyboardWings = KeyboardWings.new()
var command: FlightCommand = FlightCommand.new()
var xr_active: bool = false
var perched: bool = false
var perch_normal: Vector3 = Vector3.UP
var stunned: float = 0.0
var camera_roll_fraction: float = CAMERA_ROLL_FRACTION_DEFAULT
var camera_pitch_fraction: float = 0.0
## Optional external driver: when set, it is called for the command instead of
## wings/keys (autopilots, probes, tutorials use this).
var command_source: Callable = Callable()
var frozen: bool = false   # pause: physics skipped but head tracking continues

@onready var origin: XROrigin3D = $XROrigin3D
@onready var camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var left: XRController3D = $XROrigin3D/LeftHand
@onready var right: XRController3D = $XROrigin3D/RightHand
@onready var body_visual: Node3D = $Body
@onready var shape: CollisionShape3D = $CollisionShape3D

var _size: float = 1.0
var size: float:
	get: return _size
	set(v):
		_size = clampf(v, 0.2, 8.0)
		model.size = _size
		_apply_size()

func _ready() -> void:
	collision_layer = 2
	collision_mask = 1 | 8
	floor_stop_on_slope = false
	_apply_size()

func _apply_size() -> void:
	if shape and shape.shape is SphereShape3D:
		(shape.shape as SphereShape3D).radius = 0.25 * _size + 0.1
	if body_visual:
		body_visual.scale = Vector3.ONE * _size

func set_xr_active(active: bool) -> void:
	xr_active = active

func spawn(pos: Vector3, dir: Vector3, speed: float = -1.0) -> void:
	global_position = pos
	model.launch(pos, dir, speed)
	velocity = model.velocity
	perched = false
	stunned = 0.0
	_apply_orientation()

func _physics_process(dt: float) -> void:
	if frozen:
		return
	command = _gather_command(dt)
	if perched:
		_perched_tick(dt)
		return
	model.position = global_position
	model.step(command, dt)
	velocity = model.velocity
	if stunned > 0.0:
		stunned -= dt
	move_and_slide()
	var count: int = get_slide_collision_count()
	if count > 0:
		_handle_contact()
	model.velocity = velocity
	model.position = global_position
	_apply_orientation()
	if command.flap > 0.5 and _beat_edge():
		wingbeat.emit(command.flap)

var _last_flap: float = 0.0
func _beat_edge() -> bool:
	var edge: bool = _last_flap <= 0.5
	_last_flap = command.flap
	return edge

func _gather_command(dt: float) -> FlightCommand:
	if command_source.is_valid():
		var c: Variant = command_source.call(dt)
		if c is FlightCommand:
			return (c as FlightCommand).clamped()
	if xr_active and left.get_is_active() and right.get_is_active():
		var head: Transform3D = camera.transform
		return wings.update(head, left.transform, right.transform, dt,
			left.get_float("grip"), right.get_float("grip"), true, true)
	return keys.update(dt)

func _handle_contact() -> void:
	var col: KinematicCollision3D = get_slide_collision(0)
	var n: Vector3 = col.get_normal()
	var impact: float = maxf(-model.velocity.dot(n), 0.0)
	var speed: float = model.velocity.length()
	var can_perch: float = GRIP_PERCH_SPEED if command.grip else PERCH_SPEED
	if speed <= can_perch or impact < 1.5 and speed <= can_perch * 1.3:
		_perch(n)
		return
	collided.emit(impact, n)
	if impact > CRASH_SPEED:
		# Hitting a wall hard: lose most of the speed, tumble for a moment.
		velocity = velocity * 0.35
		stunned = 0.6
	# Otherwise move_and_slide already turned the velocity along the surface.

func _perch(n: Vector3) -> void:
	perched = true
	perch_normal = n
	velocity = Vector3.ZERO
	model.velocity = Vector3.ZERO
	model.bank = 0.0
	perched_changed.emit(true)

func _perched_tick(_dt: float) -> void:
	velocity = Vector3.ZERO
	model.velocity = Vector3.ZERO
	model.position = global_position
	# Level the view gently while sitting.
	model.bank = move_toward(model.bank, 0.0, 2.0 * _dt)
	_apply_orientation()
	if command.flap > 0.45 and _beat_edge():
		launch()

## Leave the perch: push off along the heading, away from the surface.
func launch() -> void:
	var dir: Vector3 = model.heading
	dir = (dir - dir.project(perch_normal) * 0.5).normalized() if dir.length_squared() > 0 else perch_normal
	if perch_normal.y > 0.7:
		dir = (dir + Vector3.UP * 0.35).normalized()
	global_position += perch_normal * (0.3 + 0.2 * _size)
	model.launch(global_position, dir, model.stall_speed() * LAUNCH_SPEED_FACTOR)
	velocity = model.velocity
	perched = false
	perched_changed.emit(false)
	launched.emit()

func _apply_orientation() -> void:
	# Body mesh: full flight attitude.
	body_visual.transform.basis = model.body_basis()
	# XR origin: yaw with the heading, roll a comfort fraction of the bank,
	# never pitch (the horizon tipping in VR is the fastest route to nausea).
	var f: Vector3 = model.heading
	var flat: Vector3 = Vector3(f.x, 0.0, f.z)
	if flat.length_squared() < 1e-4:
		flat = -origin.transform.basis.z
	flat = flat.normalized()
	var yaw_basis: Basis = Basis.looking_at(flat, Vector3.UP)
	var roll: float = -model.bank * camera_roll_fraction
	var pitch: float = asin(clampf(f.y, -1.0, 1.0)) * camera_pitch_fraction
	origin.transform.basis = yaw_basis * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.FORWARD, roll)

## Where the rider's eyes are, in world space.
func eye_position() -> Vector3:
	return camera.global_position

func haptic(hand: int, strength: float, duration: float) -> void:
	if not xr_active:
		return
	var c: XRController3D = left if hand == 0 else right
	c.trigger_haptic_pulse("haptic", 0.0, clampf(strength, 0.0, 1.0), duration, 0.0)
