class_name BirdPlayer
extends CharacterBody3D

## The player's bird: wires VR hands into [FlightModel], moves the body through
## the world, and handles collisions, perching and comfort.
##
## Deliberately thin. All the flight behaviour lives in [FlightModel] and
## [WingInput], both of which are plain objects covered by the headless test
## suite. What is left here is the part that genuinely needs a scene tree.

signal size_changed(new_size: float)
signal perched_changed(is_perched: bool)

## Speed at or below which a collision becomes a landing instead of a crash.
const PERCH_SPEED: float = 5.0
## Impact speed above which a collision really hurts.
const HARD_IMPACT_SPEED: float = 12.0
const STUN_DURATION: float = 0.7
## How hard pushing off a perch launches you.
const PERCH_LAUNCH_SPEED: float = 5.5

@onready var view_rig: Node3D = $ViewRig
@onready var xr_origin: XROrigin3D = $ViewRig/XROrigin3D
@onready var xr_camera: XRCamera3D = $ViewRig/XROrigin3D/XRCamera3D
@onready var left_hand: XRController3D = $ViewRig/XROrigin3D/LeftHand
@onready var right_hand: XRController3D = $ViewRig/XROrigin3D/RightHand
@onready var desktop_camera: Camera3D = $ViewRig/DesktopCamera
@onready var collision: CollisionShape3D = $Collision

var model := FlightModel.new()
var wings := WingInput.new()
var command := FlightCommand.new()

var xr_active: bool = false
var perched: bool = false
var perch_normal: Vector3 = Vector3.UP
var stun_timer: float = 0.0
var size: float = 1.0:
	set = set_size

## Set by the world each frame so thermals and ridge lift can push the bird.
var wind: Vector3 = Vector3.ZERO

var _visual_roll: float = 0.0
var _desktop_yaw: float = 0.0
var _desktop_pitch: float = 0.0
var _last_impact_speed: float = 0.0
var _spawn_point: Vector3 = Vector3(0.0, 60.0, 0.0)


var _left_wing: WingVisual
var _right_wing: WingVisual


func _ready() -> void:
	_setup_camera()
	_sync_tuning()
	_build_wings()
	set_size(1.0)
	_spawn_point = global_position


## Wings hang off the controllers, so they inherit tracking exactly and there is
## never a lag between where the player's arms are and where their wings appear.
func _build_wings() -> void:
	var tint := Color(0.74, 0.52, 0.34)
	_left_wing = WingVisual.new()
	_left_wing.name = "LeftWing"
	left_hand.add_child(_left_wing)
	_left_wing.build(-1.0, tint)

	_right_wing = WingVisual.new()
	_right_wing.name = "RightWing"
	right_hand.add_child(_right_wing)
	_right_wing.build(1.0, tint)


func _setup_camera() -> void:
	var interface: XRInterface = XRServer.find_interface("OpenXR")
	xr_active = interface != null and interface.is_initialized()
	if xr_active:
		get_viewport().use_xr = true
		desktop_camera.current = false
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		print("[Soaring] XR active: %s" % interface.get_name())
	else:
		# Desktop fallback. Not a toy — this is how flight gets iterated on
		# between headset sessions, so it drives the identical flight model.
		desktop_camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		print("[Soaring] No XR runtime; running desktop flight test mode")


func _sync_tuning() -> void:
	wings.min_flap_travel = Tuning.flap_min_travel
	wings.min_flap_speed = Tuning.flap_min_speed
	wings.tilt_sensitivity = Tuning.tilt_sensitivity
	wings.smoothing_tau = Tuning.input_smoothing


## Growing changes the bird's mass, wing area and reach all at once — the
## collision sphere is the catch radius, so a bigger bird is genuinely harder
## to escape as well as harder to turn.
func set_size(new_size: float) -> void:
	size = clampf(new_size if is_finite(new_size) else 1.0, 0.35, 8.0)
	model.set_size(size)
	if collision != null and collision.shape is SphereShape3D:
		(collision.shape as SphereShape3D).radius = 0.55 * size
	if view_rig != null:
		# The player's eye height scales with the bird, which is most of why
		# being big *feels* big.
		view_rig.scale = Vector3.ONE * size
	size_changed.emit(size)


func _physics_process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	stun_timer = maxf(0.0, stun_timer - delta)

	_gather_command(delta)
	command.wind = wind

	if perched:
		_process_perched(delta)
	else:
		model.step(command, delta)
		_move(delta)

	_apply_view_orientation(delta)
	_apply_haptics()
	_update_wings(delta)



func _update_wings(delta: float) -> void:
	if _left_wing == null:
		return
	_left_wing.set_span(command.span, delta)
	_right_wing.set_span(command.span, delta)


## When set, replaces controller input. Used by the automated flight probe to
## fly the real game from the command line.
var scripted_command: FlightCommand = null

## Test seam: a Callable returning [head, left, right] as Transform3Ds, standing
## in for the trackers.
##
## Without this, the [WingInput] path only ever runs when a physical headset is
## attached, so every automated test exercised the sensor in isolation while the
## thing players actually touch — controllers wired into the real game loop —
## was covered by nothing. That gap let a bug reach a headset where holding the
## controllers naturally flew the bird into the ground.
var pose_source: Callable = Callable()


func _gather_command(delta: float) -> void:
	if scripted_command != null:
		command = scripted_command
	elif pose_source.is_valid():
		var poses: Array = pose_source.call()
		command = wings.update(poses[0], poses[1], poses[2], true, true, delta)
	elif xr_active:
		var head: Transform3D = xr_camera.transform
		var l: Transform3D = left_hand.transform
		var r: Transform3D = right_hand.transform
		command = wings.update(
			head, l, r, left_hand.get_has_tracking_data(),
			right_hand.get_has_tracking_data(), delta
		)
	else:
		_gather_desktop_command(delta)

	if stun_timer > 0.0:
		# A hard hit costs you control of the wings for a moment, but never
		# your ability to recover — the wings still fly, just badly.
		var authority: float = 1.0 - clampf(stun_timer / STUN_DURATION, 0.0, 1.0)
		command.bank *= authority
		command.stroke_speed *= authority
		command.alpha = lerpf(model.alpha_trim, command.alpha, authority)


## Keyboard/mouse stand-in that produces exactly the same [FlightCommand] the
## controllers do, so desktop testing exercises the real flight model.
func _gather_desktop_command(delta: float) -> void:
	var bank_input: float = Input.get_axis("bank_left", "bank_right")
	var pitch_input: float = Input.get_axis("pitch_down", "pitch_up")
	command.bank = lerpf(command.bank, bank_input * 1.1, clampf(delta * 6.0, 0.0, 1.0))
	command.alpha = model.alpha_trim + pitch_input * model.alpha_range
	command.span = 0.1 if Input.is_action_pressed("tuck") else 1.0
	command.asymmetry = 0.0
	# Space produces a discrete wingbeat rather than continuous thrust, matching
	# the one-beat-per-arm-raise rule the real input enforces.
	command.stroke_speed = 3.0 if Input.is_action_pressed("flap") else 0.0


func _unhandled_input(event: InputEvent) -> void:
	if xr_active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_desktop_yaw -= motion.relative.x * 0.003
		_desktop_pitch = clampf(_desktop_pitch - motion.relative.y * 0.003, -1.4, 1.4)
	elif event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _move(delta: float) -> void:
	var motion: Vector3 = model.velocity * delta
	if not motion.is_finite():
		model.velocity = Vector3.ZERO
		return

	for i in 4:
		var hit: KinematicCollision3D = move_and_collide(motion)
		if hit == null:
			break
		var normal: Vector3 = hit.get_normal()
		var impact: float = -model.velocity.dot(normal)
		_last_impact_speed = maxf(_last_impact_speed, impact)

		if impact < PERCH_SPEED and model.velocity.length() < PERCH_SPEED * 1.4:
			_begin_perch(normal)
			return

		if impact > HARD_IMPACT_SPEED:
			# Clipping a branch at speed should hurt and should be your fault.
			stun_timer = STUN_DURATION
			model.velocity = model.velocity.slide(normal) * 0.25 + normal * 2.5
		else:
			model.velocity = model.velocity.slide(normal) * 0.75 + normal * 0.5

		motion = hit.get_remainder().slide(normal)
		if motion.length_squared() < 1e-6:
			break

	velocity = model.velocity


func _begin_perch(normal: Vector3) -> void:
	perched = true
	perch_normal = normal if normal.is_normalized() else Vector3.UP
	model.velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	perched_changed.emit(true)





## While clinging, a wingbeat is what gets you airborne again — which makes
## launching from a branch the same gesture as flying, not a separate button.
##
## Except for a player who has not yet worked out the flap. For them a landing
## is a dead end: they sit in a field looking at grass and sky with no idea that
## anything is expected of them, which is exactly how this game got reported as
## "the world disappeared". Until they have spread their wings once, the game
## puts them back in the air by itself.
func _process_perched(delta: float) -> void:
	model.velocity = Vector3.ZERO
	velocity = Vector3.ZERO


	if command.stroke_speed > 0.5:
		perched = false
		perched_changed.emit(false)
		var launch: Vector3 = (perch_normal + Vector3.UP * 1.5).normalized()
		model.velocity = launch * PERCH_LAUNCH_SPEED + model.forward() * 2.0
		# Nudge clear of the surface so the next frame does not re-collide.
		global_position += perch_normal * 0.15 * size


## Yaw follows the bird's heading; roll is shown only partially. A bird's-eye
## view that rolls 1:1 with the wings is thrilling for about ninety seconds and
## then makes people ill, so the horizon stays mostly level and the turn is sold
## by the yaw, the speed and the vignette instead.
func _apply_view_orientation(delta: float) -> void:
	var camera: Node3D = xr_camera if xr_active else desktop_camera
	var head_before: Vector3 = camera.global_position

	if xr_active:
		rotation = Vector3(0.0, model.heading, 0.0)
	else:
		rotation = Vector3(0.0, model.heading, 0.0)
		desktop_camera.rotation = Vector3(_desktop_pitch, _desktop_yaw, 0.0)

	var target_roll: float = -model.bank * Tuning.visual_roll_fraction
	_visual_roll = lerpf(_visual_roll, target_roll, clampf(delta * 5.0, 0.0, 1.0))
	view_rig.rotation = Vector3(0.0, 0.0, _visual_roll)

	# Rotating about the body origin would swing the player's head through an
	# arc they never physically moved through. Pin the rotation to the head.
	var head_after: Vector3 = camera.global_position
	var correction: Vector3 = head_before - head_after
	if correction.is_finite() and correction.length() < 5.0:
		global_position += correction


func _apply_haptics() -> void:
	if not xr_active or not wings.flap_pulse:
		return
	var strength: float = clampf(wings.flap_strength, 0.15, 1.0)
	left_hand.trigger_haptic_pulse("haptic", 0.0, strength * 0.6, 0.06, 0.0)
	right_hand.trigger_haptic_pulse("haptic", 0.0, strength * 0.6, 0.06, 0.0)


func airspeed() -> float:
	return model.velocity.length()


func altitude() -> float:
	return global_position.y


func head_position() -> Vector3:
	return (xr_camera if xr_active else desktop_camera).global_position


## Puts the bird back in the air at [param point], already flying. Callers own
## the choice of location because they are the ones who know where the terrain
## is — respawning is otherwise an excellent way to bury the player inside a
## hillside with no indication of what went wrong.
func respawn_at(point: Vector3) -> void:
	if not point.is_finite():
		point = _spawn_point
	global_position = point
	model.velocity = model.forward() * model.trim_speed()
	model.bank = 0.0
	stun_timer = 0.0
	if perched:
		perched = false
		perched_changed.emit(false)
	wings.reset()


func respawn() -> void:
	respawn_at(_spawn_point)


func set_spawn_point(point: Vector3) -> void:
	if point.is_finite():
		_spawn_point = point
