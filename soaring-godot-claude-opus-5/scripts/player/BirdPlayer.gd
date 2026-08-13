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
## Emitted when the player has re-trimmed themselves, so the display can say so.
## A recentre with no feedback is indistinguishable from a button that does not
## work, and a player who thinks the recentre is broken has no way out of a
## world that is facing the wrong way.
signal recentred()

## Speed at or below which a collision becomes a landing instead of a crash.
const PERCH_SPEED: float = 5.0
## And with a hand closed around the branch. Squeezing the grips is a bird
## putting its feet out: it does not make you fly better, it makes the arrival
## survivable, which is the difference between landing on a wire and bouncing
## off it.
const CLING_SPEED: float = 9.0
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
## Everything the player's inner ear has an opinion about: view yaw, horizon
## roll, the vignette, and which way the world faces.
var comfort := ViewComfort.new()
## Everything their hands feel. See [Haptics] for why it is a mixer rather than
## a list of pulse calls.
var haptics := Haptics.new()

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
var _body_rig: BirdRig
var _species: BirdMesh.Species = BirdMesh.Species.FALCON

## How far below and behind the head the player's own body hangs, in metres at
## size 1.0. Far enough back that it never crowds the forward view, close enough
## that looking down finds a bird rather than a void.
const BODY_DROP: float = 0.40
const BODY_BEHIND: float = 0.62


func _ready() -> void:
	_setup_camera()
	_sync_tuning()
	_build_wings()
	_build_body()
	set_size(1.0)
	_spawn_point = global_position


## Wings hang off the controllers, so they inherit tracking exactly and there is
## never a lag between where the player's arms are and where their wings appear.
func _build_wings() -> void:
	var tint: Color = Palette.colour("plumage_player")
	_left_wing = WingVisual.new()
	_left_wing.name = "LeftWing"
	left_hand.add_child(_left_wing)
	_left_wing.build(-1.0, tint, _species)

	_right_wing = WingVisual.new()
	_right_wing.name = "RightWing"
	right_hand.add_child(_right_wing)
	_right_wing.build(1.0, tint, _species)


## The player's own body: the same bird every rival wears, with the head left off
## because the head is the camera and the wings left off because the wings are
## the player's arms. Looking down used to find nothing at all, which is the one
## thing guaranteed to remind someone they are a floating pair of eyes.
func _build_body() -> void:
	_body_rig = BirdRig.new()
	_body_rig.name = "Body"
	view_rig.add_child(_body_rig)
	_body_rig.build(_species, Palette.colour("plumage_player"), false, true)
	_body_rig.hide_shadows()


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
	comfort.mode = clampi(int(round(Tuning.turning_comfort)), 0, 2) as ViewComfort.Turning
	comfort.max_yaw_rate = Tuning.max_view_yaw_rate
	comfort.roll_fraction = Tuning.visual_roll_fraction
	comfort.vignette_gain = Tuning.comfort_vignette
	comfort.reorient_enabled = Tuning.auto_recentre >= 0.5


## Re-reads [Tuning] into the wings. Called by [GameMenu] when the player
## changes a setting, so a comfort change takes effect on the next frame rather
## than on the next launch.
func apply_tuning() -> void:
	_sync_tuning()


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
	_apply_species()
	size_changed.emit(size)


## Growing out of a size class rebuilds the player as the next bird up: a falcon
## at 1.0, an eagle at 8.0. It is the only feedback on growth that is visible
## without reading a number off the HUD.
func _apply_species() -> void:
	_species = BirdMesh.species_for_size(size, _species)
	if _left_wing != null:
		_left_wing.set_species(_species)
		_right_wing.set_species(_species)
	if _body_rig != null:
		_body_rig.set_species(_species)


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
	_read_buttons(delta)
	_apply_haptics(delta)
	_update_wings(delta)



func _update_wings(delta: float) -> void:
	if _left_wing == null:
		return
	_left_wing.set_span(command.span, delta, command.stroke_speed)
	_right_wing.set_span(command.span, delta, command.stroke_speed)
	_update_body(delta)


## The body follows the head's position but not its rotation: a bird's body
## points where the bird is flying, and swinging it around with every glance
## would turn the one stable reference in the view into the least stable thing
## in it.
func _update_body(delta: float) -> void:
	if _body_rig == null:
		return
	var camera: Node3D = xr_camera if xr_active else desktop_camera
	var head: Vector3 = view_rig.to_local(camera.global_position)
	_body_rig.position = head + Vector3(0.0, -BODY_DROP, BODY_BEHIND)
	_body_rig.animate(
		command.stroke_speed, command.span, model.bank,
		command.alpha, model.alpha_trim, delta
	)


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
	# Escape used to free the mouse here. It now opens the menu, which frees the
	# mouse itself and recaptures it on the way out — see [GameMenu.toggle].
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_desktop_yaw -= motion.relative.x * 0.003
		_desktop_pitch = clampf(_desktop_pitch - motion.relative.y * 0.003, -1.4, 1.4)


func _move(delta: float) -> void:
	var motion: Vector3 = model.velocity * delta
	if not motion.is_finite():
		model.velocity = Vector3.ZERO
		return

	# Reaching for the branch. Closing a hand widens the speed at which an
	# arrival is a landing rather than a crash, which is the one place in this
	# game a button beats a gesture: you cannot flap your way onto a wire.
	var catch_speed: float = CLING_SPEED if is_clinging() else PERCH_SPEED

	for i in 4:
		var hit: KinematicCollision3D = move_and_collide(motion)
		if hit == null:
			break
		var normal: Vector3 = hit.get_normal()
		var impact: float = -model.velocity.dot(normal)
		_last_impact_speed = maxf(_last_impact_speed, impact)

		if impact < catch_speed and model.velocity.length() < catch_speed * 1.4:
			_begin_perch(normal)
			return

		if impact > HARD_IMPACT_SPEED:
			# Clipping a branch at speed should hurt and should be your fault.
			stun_timer = STUN_DURATION
			model.velocity = model.velocity.slide(normal) * 0.25 + normal * 2.5
			haptics.fire(&"impact", clampf(impact / 25.0, 0.5, 1.0))
		else:
			model.velocity = model.velocity.slide(normal) * 0.75 + normal * 0.5
			haptics.fire(&"impact", clampf(impact / 25.0, 0.15, 0.6))

		motion = hit.get_remainder().slide(normal)
		if motion.length_squared() < 1e-6:
			break

	velocity = model.velocity


func _begin_perch(normal: Vector3) -> void:
	perched = true
	perch_normal = normal if normal.is_normalized() else Vector3.UP
	model.velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	haptics.fire(&"cling", 1.0)
	perched_changed.emit(true)





## While clinging, a wingbeat is what gets you airborne again — which makes
## launching from a branch the same gesture as flying, not a separate button.
##
## There is no rescue for a player who has not worked out the flap yet: the one
## that used to be described here was reverted long ago and the comment outlived
## it. What a landed player gets instead is the HUD's "PERCHED — spread your
## arms and flap", and a bird that will sit on its branch indefinitely until
## they do. See [FirstContact] for what that first session actually looks like.
func _process_perched(delta: float) -> void:
	model.velocity = Vector3.ZERO
	velocity = Vector3.ZERO


	if command.stroke_speed > 0.5:
		perched = false
		haptics.fire(&"launch", 1.0)
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

	comfort.update(model.heading, model.bank, model.velocity.length(), delta)
	rotation = Vector3(0.0, comfort.yaw, 0.0)
	if not xr_active:
		desktop_camera.rotation = Vector3(_desktop_pitch, _desktop_yaw, 0.0)

	_update_reorientation(delta)
	_visual_roll = comfort.roll
	view_rig.rotation = Vector3(0.0, 0.0, _visual_roll)
	# The correction goes on the tracked rig, not on the view rig above it, for
	# two reasons: the player's own body hangs off the view rig and must keep
	# pointing where the bird is actually flying, and inside the view rig the
	# rotation axis is the bird's up rather than the world's — which is the
	# frame the player's shoulders were measured in anyway.
	xr_origin.rotation = Vector3(0.0, comfort.reorientation, 0.0)

	# Rotating about the body origin would swing the player's head through an
	# arc they never physically moved through. Pin the rotation to the head.
	var head_after: Vector3 = camera.global_position
	var correction: Vector3 = head_before - head_after
	if correction.is_finite() and correction.length() < 5.0:
		global_position += correction


## Turns the tracked rig to face wherever the player's body has ended up.
##
## Measured off the wing line rather than the head, so looking around costs
## nothing — see [method ViewComfort.update_reorientation]. Only the rig moves:
## the bird's own body is counter-rotated so it keeps pointing where it is
## actually flying, which is the whole reason the correction is applied here and
## not to the player's heading.
func _update_reorientation(delta: float) -> void:
	var forward: Vector3 = wings.body_forward
	var usable: bool = xr_active and wings.tracking_ok and command.span > 0.5 \
		and forward.is_finite() and forward.length_squared() > 0.5
	var body_yaw: float = atan2(forward.x, -forward.z) if usable else 0.0
	comfort.update_reorientation(body_yaw, usable, delta)


## Re-trims the player where they are standing: relearns their neutral wrist
## angle and reach, and faces the world at their shoulders.
func recentre() -> void:
	wings.recentre()
	var forward: Vector3 = wings.body_forward
	if xr_active and forward.is_finite() and forward.length_squared() > 0.5 \
			and command.span > 0.5:
		comfort.reorient_now(atan2(forward.x, -forward.z))
	haptics.fire(&"recentre", 1.0)
	recentred.emit()


# --- buttons -----------------------------------------------------------------

## Grip, on either hand, as a single "am I holding on" flag. Both the click and
## the analogue squeeze are read, because which one a runtime reports depends on
## the controller and a player who squeezes should not have to know that.
const GRIP_THRESHOLD: float = 0.7
## Both triggers, held. Long enough that it cannot be an accident, short enough
## that a player who has just turned their chair round is not standing there
## wondering whether it is working.
const RECENTRE_HOLD: float = 1.2

var _recentre_held: float = 0.0
var _recentre_armed: bool = true
var _was_flapping: bool = false


func _read_buttons(delta: float) -> void:
	if not xr_active:
		return
	if both_triggers_held():
		_recentre_held += delta
		if _recentre_armed and _recentre_held >= RECENTRE_HOLD:
			_recentre_armed = false
			recentre()
	else:
		# One-shot per hold: a player who rests their fingers on the triggers
		# re-trims once, not once a second.
		_recentre_held = 0.0
		_recentre_armed = true


## Both triggers squeezed: the recentre gesture. Public so [XRDiagnostic] can
## report whether the buttons this game binds are reaching it at all.
func both_triggers_held() -> bool:
	return _trigger_held(left_hand) and _trigger_held(right_hand)


func _trigger_held(controller: XRController3D) -> bool:
	if not controller.get_has_tracking_data():
		return false
	return controller.is_button_pressed(&"trigger_click") \
		or controller.get_float(&"trigger") > GRIP_THRESHOLD


## True while the player is closing a hand — the cling gesture. Either hand
## counts: a bird landing puts both feet out, and asking for two buttons at once
## while arriving at a branch at 9 m/s is asking for a miss.
func is_clinging() -> bool:
	if not xr_active:
		return false
	return _grip_held(left_hand) or _grip_held(right_hand)


func _grip_held(controller: XRController3D) -> bool:
	if not controller.get_has_tracking_data():
		return false
	return controller.is_button_pressed(&"grip_click") \
		or controller.get_float(&"grip") > GRIP_THRESHOLD


# --- haptics -----------------------------------------------------------------

## Feeds the mixer this frame's events and states, then sends whatever it says
## to the controllers.
##
## The mixer runs whether or not there is a headset attached, so the probes
## exercise it and a change that makes it produce nonsense fails in the suite
## rather than in somebody's hands.
func _apply_haptics(delta: float) -> void:
	# The leading edge only. [member WingInput.flap_pulse] is true for every frame
	# of the downstroke, and a thump per frame is not a wingbeat, it is a burr.
	if wings.flap_pulse and not _was_flapping:
		# Felt in the arm that did the work. A one-winged beat that arrives in
		# both hands is the game disagreeing with the player's own body.
		haptics.fire(
			&"wingbeat", clampf(wings.flap_strength, 0.25, 1.0), command.asymmetry
		)
	_was_flapping = wings.flap_pulse
	# Lift is the one thing in this game a player can be in the middle of and
	# never notice. It reads as a slow pulse under both hands.
	haptics.texture(&"thermal", clampf((wind.y - 0.8) / 3.0, 0.0, 1.0))
	haptics.texture(&"stall", clampf(model.stall_amount, 0.0, 1.0) if model.is_stalled else 0.0)
	haptics.update(delta)
	if not xr_active:
		return
	_send_pulse(left_hand, Haptics.LEFT, delta)
	_send_pulse(right_hand, Haptics.RIGHT, delta)


func _send_pulse(controller: XRController3D, hand: int, delta: float) -> void:
	var amplitude: float = haptics.amplitude(hand)
	if amplitude <= Haptics.SILENCE:
		return
	# Slightly longer than a frame so consecutive pulses overlap into one
	# continuous shape instead of a row of clicks at the frame rate. OpenXR has
	# no way to cancel a pulse, so it must never be long enough to outlive the
	# thing it describes.
	var seconds: float = clampf(delta * 2.0, 0.02, 0.05)
	controller.trigger_haptic_pulse(
		"haptic", haptics.frequency(hand), amplitude, seconds, 0.0
	)


## Plays a named cue from [constant Haptics.CUES]. This is how everything
## outside the player — a catch, a promotion, being eaten — reaches the player's
## hands, and it is one call rather than an amplitude and a duration so that
## what a thing feels like is decided in one place.
func haptic_cue(cue: StringName, strength: float = 1.0, balance: float = 0.0) -> void:
	haptics.fire(cue, strength, balance)


## Nothing calls this any more — every caller names a cue instead, which is the
## point of [Haptics]. Kept because "buzz both hands for this long" is the one
## thing an outside caller might reasonably still want, and routing it through
## the mixer means even that cannot become a continuous vibration.
func pulse_haptic(strength: float, duration: float) -> void:
	haptics.fire(&"caught" if duration > 0.2 else &"catch", strength)


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
	# The view is put where the bird is rather than allowed to catch up: an
	# eased or stepped view rotating a hundred and eighty degrees to follow a
	# respawn is the one rotation in this game nobody asked for.
	comfort.snap_to(model.heading)
	haptics.reset()


func respawn() -> void:
	respawn_at(_spawn_point)


func set_spawn_point(point: Vector3) -> void:
	if point.is_finite():
		_spawn_point = point
