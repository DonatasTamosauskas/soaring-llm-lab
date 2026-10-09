extends SceneTree

const Model = preload("res://scripts/flight/model.gd")
const Gesture = preload("res://scripts/flight/gesture.gd")
const Player = preload("res://scripts/flight/player.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_strokes()
	_test_pose_rejection()
	_test_controls()
	_test_aerodynamics()
	_test_rates()
	_test_rig()
	_test_tracking()
	_test_boundaries()
	await _test_collision()
	await _test_perch()
	for failure in failures:
		printerr("FAIL: " + failure)
	print("FLIGHT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _poses(y: float = 1.08, span: float = 0.8, head_offset: Vector3 = Vector3.ZERO) -> Array[Transform3D]:
	return [Transform3D(Basis.IDENTITY, Vector3(-span * 0.5, y, -0.25) + head_offset), Transform3D(Basis.IDENTITY, Vector3(span * 0.5, y, -0.25) + head_offset), Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0) + head_offset)]

func _flap_train(hz: float) -> Dictionary:
	var gesture = Gesture.new()
	var total := 0.0
	var events := 0
	var dt := 1.0 / hz
	for frame in range(int(hz * 4.0) + 1):
		var t := float(frame) * dt
		var poses := _poses(1.05 + 0.22 * cos(TAU * 1.5 * t))
		var result := gesture.sample(dt, poses[0], poses[1], poses[2])
		if float(result.flap) > 0.0:
			events += 1
			total += float(result.flap)
	return {"events": events, "strength": total, "strokes": gesture.strokes}

func _test_strokes() -> void:
	for hz in [15.0, 30.0, 72.0, 90.0, 120.0]:
		var train := _flap_train(hz)
		_check(int(train.events) == 6, "Six downstrokes recognized at %.0f Hz: %s" % [hz, train])
		_check(int(train.strokes) == 12, "One impulse per hand per downstroke at %.0f Hz" % hz)
		_check(float(train.strength) > 4.5, "Compact strokes remain powerful at %.0f Hz" % hz)
	var gesture = Gesture.new()
	var events := 0
	for frame in range(180):
		var y := 1.25 - minf(float(frame) / 90.0, 0.4)
		var p := _poses(y)
		if float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).flap) > 0.0:
			events += 1
	_check(events == 1, "A continuous downward movement produces exactly one paired flap")
	print("Stroke train: ", _flap_train(90.0))

func _test_pose_rejection() -> void:
	var gesture = Gesture.new()
	var total := 0.0
	for frame in range(360):
		var t := float(frame) / 90.0
		var p := _poses(1.05 + sin(t * 40.0) * 0.0025, 0.75)
		total += float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).flap)
	_check(total == 0.0, "Tracking jitter does not flap")
	gesture.reset()
	total = 0.0
	for frame in range(360):
		var t := float(frame) / 90.0
		var p := _poses(1.05, 0.75, Vector3(t * 8.0, sin(t * 6.0) * 0.4, -t * 22.0))
		total += float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).flap)
	_check(total == 0.0, "Locomotion, crouching and shared head/hand motion do not flap")
	gesture.reset()
	total = 0.0
	for frame in range(360):
		var p := _poses()
		p[2].origin.y += sin(float(frame) / 90.0 * 6.0) * 0.25
		total += float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).flap)
	_check(total == 0.0, "Head-only bobbing does not flap")
	gesture.reset()
	var p := _poses(1.3)
	gesture.sample(1.0 / 90.0, p[0], p[1], p[2])
	p = _poses(0.3)
	_check(float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).flap) == 0.0, "Tracking teleport does not produce a flap")

func _test_controls() -> void:
	var gesture = Gesture.new()
	var p := _poses(1.05, 0.40)
	gesture.calibrate(p[0], p[1], p[2])
	var rest := gesture.sample(1.0 / 90.0, p[0], p[1], p[2], 1.0)
	_check(float(rest.spread) >= 0.81, "Bent-arm squeeze yields fatigue-relief glide")
	p[0].origin.y += 0.2
	p[1].origin.y -= 0.2
	var turning := gesture.sample(1.0 / 90.0, p[0], p[1], p[2])
	_check(float(turning.bank) > 0.9, "Lowering right wing commands a coordinated right turn")
	p = _poses()
	p[0].basis = Basis(Vector3.RIGHT, 0.42)
	p[1].basis = Basis(Vector3.RIGHT, 0.42)
	var pitched := gesture.sample(1.0 / 90.0, p[0], p[1], p[2])
	_check(float(pitched.pitch) > 0.6, "Controller incidence sets positive angle of attack")
	gesture.calibrate(p[0], p[1], p[2])
	_check(absf(float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).pitch)) < 0.01, "Calibration supports different natural controller grip angles")
	p = _poses(1.05, 0.24)
	_check(float(gesture.sample(1.0 / 90.0, p[0], p[1], p[2]).tuck) > 0.5, "Bringing both wings inward tucks them")

func _simulate(model: RefCounted, seconds: float, controls: Dictionary, mass_value: float = 1.0, thermal: float = 0.0, hz: float = 90.0) -> Vector3:
	var position := Vector3.ZERO
	for frame in range(int(seconds * hz)):
		model.update(1.0 / hz, controls, mass_value, thermal)
		position += model.velocity / hz
	return position

func _test_aerodynamics() -> void:
	var neutral := {"spread": 0.82}
	var model = Model.new()
	_simulate(model, 12.0, neutral)
	_check(absf(model.velocity.y) < 1.5, "Neutral comfort glide is sustainable with low sink")
	_check(Vector2(model.velocity.x, model.velocity.z).length() > 10.0, "Neutral glide retains useful airspeed")
	var before: float = model.velocity.y
	model.update(1.0 / 90.0, {"spread": 0.82, "flap": 1.0})
	_check(model.velocity.y > before + 6.5, "A paired flap provides substantial immediate lift")
	var tucked = Model.new()
	_simulate(tucked, 10.0, {"spread": 0.82, "tuck": 1.0})
	_check(tucked.velocity.length() > model.velocity.length() + 5.0, "Tucking increases speed")
	_check(tucked.velocity.y < -3.0, "Tucking trades lift for a dive")
	var braking = Model.new()
	_simulate(braking, 8.0, {"spread": 1.0, "brake": 1.0})
	_check(Vector2(braking.velocity.x, braking.velocity.z).length() < 11.0, "Spreading and braking slow the bird for tight approaches")
	var balloon = Model.new()
	_simulate(balloon, 3.0, neutral)
	var peak := -100.0
	for frame in range(180):
		balloon.update(1.0 / 90.0, {"spread": 0.82, "pitch": 0.7})
		peak = maxf(peak, balloon.velocity.y)
	_simulate(balloon, 6.0, {"spread": 0.82, "pitch": 0.7})
	_check(peak > balloon.velocity.y + 0.7, "Angle of attack produces temporary ballooning before induced drag")
	var stall = Model.new()
	stall.reset(0.0, 3.0)
	stall.update(1.0 / 90.0, neutral)
	_check(stall.stalled and stall.velocity.y < 0.0, "Insufficient airspeed loses lift")
	var thermal = Model.new()
	_simulate(thermal, 6.0, neutral, 1.0, 12.0)
	_check(thermal.velocity.y > 5.0, "Thermal climbs without flapping")
	var small = Model.new()
	var big = Model.new()
	_simulate(small, 2.0, {"spread": 0.82, "bank": 1.0}, 1.0)
	_simulate(big, 2.0, {"spread": 0.82, "bank": 1.0}, 16.0)
	_check(small.heading < -0.8 and big.heading < 0.0, "Right-wing bank turns right")
	_check(absf(big.heading) < absf(small.heading) * 0.8, "Growth reduces turn agility")
	var light = Model.new()
	var heavy = Model.new()
	light.update(1.0 / 90.0, {"flap": 1.0}, 1.0)
	heavy.update(1.0 / 90.0, {"flap": 1.0}, 16.0)
	_check(heavy.velocity.y < light.velocity.y * 0.8 and heavy.velocity.y > 3.0, "Growth changes flight feel while preserving useful flaps")
	print("Aerodynamics: neutral=", model.velocity, " tuck=", tucked.velocity, " thermal=", thermal.velocity, " balloon=", peak, " -> ", balloon.velocity.y)

func _test_rates() -> void:
	var reference = Model.new()
	_simulate(reference, 8.0, {"spread": 0.75, "bank": 0.4, "pitch": 0.2}, 4.0, 3.0, 90.0)
	for hz in [15.0, 30.0, 72.0, 120.0]:
		var model = Model.new()
		_simulate(model, 8.0, {"spread": 0.75, "bank": 0.4, "pitch": 0.2}, 4.0, 3.0, hz)
		_check(model.velocity.distance_to(reference.velocity) < 0.12, "Flight integration remains stable at %.0f Hz" % hz)
	for mass_value in [0.4, 1.0, 4.0, 16.0, 64.0]:
		var model = Model.new()
		for frame in range(800):
			model.update(0.2, {"spread": float(frame % 10) / 10.0, "bank": sin(float(frame)), "pitch": cos(float(frame)), "flap": 1.6 if frame % 3 == 0 else 0.0, "tuck": float(frame % 2)}, mass_value, 18.0)
		_check(model.velocity.is_finite() and model.velocity.length() < 37.0 and absf(model.velocity.y) <= 16.0, "Bounded finite forces at mass %.1f and low FPS" % mass_value)

func _test_rig() -> void:
	var player = Player.new()
	root.add_child(player)
	player.configure(false)
	player.set_mass(32.0)
	_check(player.origin.scale.is_equal_approx(Vector3.ONE) and player.scale.is_equal_approx(Vector3.ONE), "Growth never scales the XR rig")
	_check(player.left_controller.get_parent() == player.origin and player.right_controller.get_parent() == player.origin and player.head.get_parent() == player.origin, "Tracked nodes remain direct children of XROrigin3D")
	_check(player.left_controller.pose == &"grip" and player.right_controller.pose == &"grip", "Controllers use natural grip tracking poses")
	player.calibrate()
	_check(absf(player.head.global_position.y - player.global_position.y - 0.1) < 0.01, "Eye-centred calibration supports seated and standing players")
	player.set_comfort(true)
	_check(is_zero_approx(player.origin.rotation.z), "Comfort mode keeps a level horizon")
	player.reset_at(Vector3(0.0, 18.0, 50.0))
	player.set_flying(true)
	_check(player.velocity.length() > 10.0, "Flight launches with useful starting airspeed")
	player.set_flying(false)
	_check(player.velocity.is_zero_approx(), "Menu state stops movement")
	player.set_flying(true)
	player.velocity = Vector3(3.0, -2.0, -18.0)
	player.flight_model.velocity = player.velocity
	player.set_flying(false)
	player.set_flying(true)
	_check(player.velocity.is_equal_approx(Vector3(3.0, -2.0, -18.0)), "Pause/resume preserves airborne momentum")
	var paused_position: Vector3 = player.global_position
	paused = true
	player._physics_process(0.2)
	paused = false
	_check(player.global_position.is_equal_approx(paused_position), "Always-processing XR rig does not move while tree is paused")
	player.free()

func _test_tracking() -> void:
	var player = Player.new()
	root.add_child(player)
	player.configure(true)
	player.set_physics_process(false)
	player.head.position = Vector3(0.0, 1.6, 0.0)
	player.calibrate()
	_check(not player._calibrated_tracking, "Startup calibration defers until real controller poses are available")
	var trackers: Array[XRControllerTracker] = []
	for hand in [&"left_hand", &"right_hand"]:
		var tracker := XRControllerTracker.new()
		tracker.name = hand
		tracker.set_input(&"grip", 0.0)
		tracker.set_input(&"trigger", 0.0)
		tracker.set_input(&"primary", Vector2.ZERO)
		tracker.set_input(&"ax_button", false)
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
	var total := 0.0
	for frame in range(91):
		var p := _poses(1.05 + 0.22 * cos(TAU * float(frame) / 90.0))
		p[0].basis = Basis(Vector3.RIGHT, 0.70)
		p[1].basis = Basis(Vector3.RIGHT, 0.70)
		for index in range(2):
			trackers[index].set_pose(&"grip", p[index], Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		var controls: Dictionary = player._read_controls(1.0 / 90.0)
		total += float(controls.flap)
		if frame == 0:
			_check(absf(float(controls.pitch)) < 0.01 and player._calibrated_tracking, "First tracked neutral grip calibrates incidence without stalling")
	_check(player.left_controller.get_has_tracking_data() and player.right_controller.get_has_tracking_data(), "Native XRController nodes receive grip tracker poses")
	_check(total > 0.65, "XR flapping works with zero runtime velocity reports")
	trackers[1].set_input(&"ax_button", true)
	_check(float(player._read_controls(1.0 / 90.0).flap) > 0.85, "A/X button assists a low-fatigue flap")
	_check(float(player._read_controls(1.0 / 90.0).flap) == 0.0, "Holding flap assistance does not repeat")
	trackers[1].set_input(&"ax_button", false)
	player._read_controls(1.0 / 90.0)
	trackers[1].set_input(&"ax_button", true)
	_check(float(player._read_controls(1.0 / 90.0).flap) == 0.0, "Flap assistance is debounced")
	trackers[1].set_input(&"ax_button", false)
	player._read_controls(0.4)
	trackers[1].set_input(&"ax_button", true)
	_check(float(player._read_controls(1.0 / 90.0).flap) > 0.85, "Flap assistance rearms after a deliberate release")
	for tracker in trackers:
		tracker.invalidate_pose(&"grip")
	_check(float(player._read_controls(1.0 / 90.0).flap) == 0.0, "Tracking loss yields safe glide without phantom lift")
	player._read_controls(0.5)
	_check(not player.tracking_valid and player.tracking_lost_seconds >= 0.5, "Tracking loss duration is exposed for automatic pause")
	var p := _poses(0.8)
	for index in range(2):
		trackers[index].set_pose(&"grip", p[index], Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_check(float(player._read_controls(1.0 / 90.0).flap) == 0.0, "Tracking reacquisition does not flap on a discontinuity")
	_check(player.tracking_valid and is_zero_approx(player.tracking_lost_seconds), "Tracking reacquisition clears loss duration")
	for tracker in trackers:
		XRServer.remove_tracker(tracker)
	player.free()

func _test_collision() -> void:
	var wall := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, 10.0, 0.5)
	collider.shape = box
	wall.add_child(collider)
	root.add_child(wall)
	wall.position = Vector3(0.0, 5.0, -4.0)
	var player = Player.new()
	root.add_child(player)
	player.configure(false)
	player.reset_at(Vector3(0.0, 5.0, 0.0))
	var hits: Array[int] = [0]
	player.collision_hit.connect(func(_speed: float) -> void: hits[0] += 1)
	player.set_flying(true)
	for frame in range(60):
		await physics_frame
	_check(player.global_position.z > -3.5, "Bird hull cannot tunnel through an obstacle at flying speed")
	_check(hits[0] >= 1, "Physical impacts emit collision feedback")
	print("Collision: position=", player.global_position, " impacts=", hits[0])
	player.free()
	wall.free()

func _test_boundaries() -> void:
	for mass_value in [0.6, 16.0, 64.0]:
		var player = Player.new()
		root.add_child(player)
		player.configure(false)
		player.set_mass(mass_value)
		player.reset_at(Vector3(174.0, 40.0, 0.0))
		player.set_flying(true)
		player.flight_model.reset(-PI * 0.5, 28.0)
		player.heading = -PI * 0.5
		var maximum_radius := 0.0
		var warned := false
		for frame in range(720):
			player._physics_process(1.0 / 90.0)
			maximum_radius = maxf(maximum_radius, Vector2(player.global_position.x, player.global_position.z).length())
			warned = warned or player.boundary_active
		_check(maximum_radius <= 200.01, "Valley boundary contains a fast outward flight at mass %.1f" % mass_value)
		_check(warned and Vector2(player.global_position.x, player.global_position.z).length() < 175.0, "Boundary wind guides flight back into valley at mass %.1f" % mass_value)
		print("Boundary mass=", mass_value, " maximum_radius=", maximum_radius, " returned=", player.global_position)
		player.reset_at(Vector3(0.0, 111.8, 0.0))
		player.flight_model.velocity = Vector3(0.0, 13.0, -13.8)
		player.velocity = player.flight_model.velocity
		for frame in range(120):
			player._physics_process(1.0 / 90.0)
		_check(player.global_position.y <= 112.0 and player.velocity.y <= 0.0, "Ceiling guides bird down at mass %.1f" % mass_value)
		player.free()

func _test_perch() -> void:
	var ledge := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 0.3, 6.0)
	collider.shape = box
	ledge.add_child(collider)
	root.add_child(ledge)
	var player = Player.new()
	root.add_child(player)
	player.configure(false)
	player.reset_at(Vector3(0.0, 1.2, 0.0))
	player.set_flying(true)
	player.flight_model.reset(0.0, 2.0)
	player.flight_model.velocity.y = -2.0
	for frame in range(65):
		await physics_frame
	_check(player.perched and player.velocity.is_zero_approx(), "A slow ledge landing becomes a stable perch")
	var resting_position: Vector3 = player.global_position
	for frame in range(35):
		await physics_frame
	_check(player.global_position.is_equal_approx(resting_position), "Perching rests wings without automatic trim acceleration")
	player.set_flying(false)
	player.set_flying(true)
	_check(player.perched and player.velocity.is_zero_approx(), "Pause/resume preserves the perch")
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	for frame in range(3):
		await physics_frame
	key.pressed = false
	Input.parse_input_event(key)
	_check(not player.perched and player.velocity.y > 3.0 and player.global_position.y > resting_position.y + 0.05, "Intentional flap launches from a physical perch")
	print("Perch: rest=", resting_position, " takeoff=", player.global_position, " velocity=", player.velocity)
	player.free()
	ledge.free()
	var branch := StaticBody3D.new()
	var branch_shape := CollisionShape3D.new()
	var branch_box := BoxShape3D.new()
	branch_box.size = Vector3(3.0, 0.15, 0.15)
	branch_shape.shape = branch_box
	branch.add_child(branch_shape)
	root.add_child(branch)
	var resting = Player.new()
	root.add_child(resting)
	resting.configure(false)
	resting.reset_at(Vector3(0.0, 0.4, 0.18))
	await physics_frame
	_check(resting._has_perch_support(), "Off-centre hull contact remains supported by a thin branch")
	resting.free()
	branch.free()
