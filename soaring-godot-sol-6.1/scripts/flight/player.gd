extends CharacterBody3D

const FlightModel = preload("res://scripts/flight/model.gd")
const WingGesture = preload("res://scripts/flight/gesture.gd")

signal flap(strength: float)
signal collision_hit(speed: float)

var mass := 1.0
var flying := false
var perched := false
var xr_active := false
var tracking_valid := true
var tracking_lost_seconds := 0.0
var boundary_active := false
var boundary_strength := 0.0
var soft_boundary_radius := 175.0
var hard_boundary_radius := 200.0
var flight_ceiling := 112.0
var _bounds_center := Vector2.ZERO
var origin: XROrigin3D
var head: Camera3D
var left_controller: XRController3D
var right_controller: XRController3D
var heading := 0.0
var flight_speed := 0.0
var comfort := true
var telemetry: Dictionary = {}
var flight_model = FlightModel.new()
var gesture = WingGesture.new()
var _thermal_lift := 0.0
var _calibrated_tracking := false
var _has_launched := false
var _tracking_was_valid := false
var _collision_cooldown := 0.0
var _snap_cooldown := 0.0
var _space_held := false
var _snap_held := false
var _helper_held := false
var _helper_cooldown := 0.0
var _mouse_pitch := 0.0
var _wing_animation := 0.0
var _wing_nodes: Array[Node3D] = []
var _collider: CollisionShape3D
var _desktop_pitch := 0.0
var _desktop_bank := 0.0
var _last_controls := {"spread": 0.82, "pitch": 0.0, "bank": 0.0, "tuck": 0.0, "brake": 0.0, "flap": 0.0}

func _init() -> void:
	name = "BirdPlayer"
	process_mode = Node.PROCESS_MODE_ALWAYS
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	safe_margin = 0.035
	collision_layer = 2
	collision_mask = 1
	_build_rig()

func _ready() -> void:
	head.current = true
	set_mass(mass)

func configure(use_xr: bool) -> void:
	xr_active = use_xr
	tracking_valid = not use_xr
	tracking_lost_seconds = 0.0
	var old_head := head
	if use_xr and not head is XRCamera3D:
		head = XRCamera3D.new()
	elif not use_xr and head is XRCamera3D:
		head = Camera3D.new()
	if old_head != head:
		origin.remove_child(old_head)
		old_head.free()
		origin.add_child(head)
		head.name = "Head"
		head.near = 0.06
		head.far = 1200.0
		head.fov = 85.0
		head.current = true
	if not use_xr:
		head.position = Vector3(0.0, 1.6, 0.0)
		left_controller.position = Vector3(-0.40, 1.15, -1.10)
		right_controller.position = Vector3(0.40, 1.15, -1.10)
		head.rotation = Vector3.ZERO
	origin.position.y = -1.5
	origin.scale = Vector3.ONE
	origin.world_scale = 1.0
	_calibrated_tracking = false
	_tracking_was_valid = false
	gesture.reset()

func set_mass(value: float) -> void:
	mass = clampf(value, 0.4, 64.0)
	var sphere := _collider.shape as SphereShape3D
	sphere.radius = 0.34 * pow(mass, 0.20)
	var art_scale := clampf(pow(mass, 0.19), 0.85, 1.9)
	for wing in _wing_nodes:
		wing.scale = Vector3.ONE * art_scale
	# Mass changes body art and collision clearance, never the tracked rig.
	origin.scale = Vector3.ONE

func reset_at(pos: Vector3) -> void:
	global_position = pos
	heading = 0.0
	rotation = Vector3.ZERO
	flight_model.reset(heading)
	_has_launched = false
	perched = false
	velocity = Vector3.ZERO
	flight_speed = 0.0
	_thermal_lift = 0.0
	_collision_cooldown = 0.0
	_mouse_pitch = 0.0
	gesture.reset()
	if not xr_active:
		head.rotation = Vector3.ZERO

func set_flying(active: bool) -> void:
	if active and not flying:
		if not _has_launched:
			flight_model.reset(heading)
			_has_launched = true
		velocity = flight_model.velocity
		gesture.reset()
	if not active and flying:
		flight_model.velocity = velocity
	flying = active
	_space_held = Input.is_physical_key_pressed(KEY_SPACE)
	if not active:
		velocity = Vector3.ZERO

func set_thermal_lift(value: float) -> void:
	_thermal_lift = maxf(value, 0.0)

func set_flight_bounds(bounds: AABB) -> void:
	var centre := bounds.get_center()
	_bounds_center = Vector2(centre.x, centre.z)
	var radius := minf(bounds.size.x, bounds.size.z) * 0.5
	soft_boundary_radius = maxf(10.0, radius - 5.0)
	hard_boundary_radius = radius + 20.0
	flight_ceiling = bounds.end.y + 7.0

func calibrate() -> void:
	if xr_active and (not left_controller.get_has_tracking_data() or not right_controller.get_has_tracking_data() or head.position.length_squared() < 0.001):
		# Startup/menu actions can arrive before OpenXR has delivered real poses.
		# Calibrating the placeholder transforms would make every wrist stall.
		_calibrated_tracking = false
		gesture.reset()
		return
	gesture.calibrate(left_controller.transform, right_controller.transform, head.transform)
	# Keep the actual eye level near the bird's centre for standing and seated play.
	origin.position.y = -head.position.y + 0.10
	_calibrated_tracking = true

func set_comfort(enabled: bool) -> void:
	comfort = enabled
	origin.rotation.z = 0.0

func _physics_process(delta: float) -> void:
	_collision_cooldown = maxf(0.0, _collision_cooldown - delta)
	_snap_cooldown = maxf(0.0, _snap_cooldown - delta)
	var controls := _read_controls(delta)
	_last_controls = controls
	_update_wings(delta, controls)
	# Room-scale leaning must move the physical hull along with the tracked head.
	_collider.position = to_local(head.global_position) - Vector3.UP * 0.10
	if not flying or get_tree().paused:
		# Sampling continues during menus so resuming cannot accumulate a stroke.
		return
	if perched:
		if float(controls.get("flap", 0.0)) > 0.0:
			perched = false
			flight_model.reset(heading, 7.0)
		elif _has_perch_support():
			velocity = Vector3.ZERO
			flight_model.velocity = Vector3.ZERO
			flight_speed = 0.0
			telemetry = {"speed": 0.0, "vertical_speed": 0.0, "lift": 0.0, "stall": false, "perched": true}
			return
		else:
			perched = false
			flight_model.velocity = Vector3(0.0, -1.0, 0.0)
	controls = _apply_boundary_controls(controls)
	telemetry = flight_model.update(delta, controls, mass, _thermal_lift)
	velocity = flight_model.velocity
	_apply_boundary_wind(delta)
	heading = flight_model.heading
	rotation.y = heading
	flight_speed = float(telemetry.speed)
	var incoming_velocity := velocity
	move_and_slide()
	_guard_world_limits()
	if get_slide_collision_count() > 0:
		var impact := 0.0
		var landing := false
		for index in range(get_slide_collision_count()):
			var normal := get_slide_collision(index).get_normal()
			impact = maxf(impact, -incoming_velocity.dot(normal))
			var approach_speed := Vector2(incoming_velocity.x, incoming_velocity.z).length()
			if normal.y > 0.65 and incoming_velocity.y <= 1.0 and (approach_speed < 6.0 or (float(controls.get("brake", 0.0)) > 0.72 and approach_speed < 13.5)):
				landing = true
			if velocity.dot(normal) < 0.0:
				velocity = velocity.slide(normal)
		flight_model.velocity = velocity
		if landing:
			perched = true
			velocity = Vector3.ZERO
			flight_model.velocity = Vector3.ZERO
			flight_model.bank = 0.0
			flight_speed = 0.0
			telemetry["perched"] = true
		if impact > 2.5 and _collision_cooldown <= 0.0:
			collision_hit.emit(impact)
			_collision_cooldown = 0.65
			_haptic(0.28, 0.08)
	if float(controls.get("flap", 0.0)) > 0.0:
		flap.emit(float(controls.flap))
		_wing_animation = 1.0
		_haptic(0.13, 0.035)
	# Head remains level by default. Opt-in mild visual banking only changes origin.
	origin.rotation.z = lerpf(origin.rotation.z, 0.0 if comfort else -flight_model.bank * 0.10, 1.0 - exp(-3.0 * delta))

func _has_perch_support() -> bool:
	var centre := _collider.global_position
	var radius: float = _collider.shape.radius
	# A narrow branch can support the side of the hull without lying directly
	# beneath its centre. Sample the contact footprint as well as its centre.
	for index in range(9):
		var offset := Vector3.ZERO
		if index > 0:
			var angle := float(index - 1) * TAU / 8.0
			offset = Vector3(cos(angle), 0.0, sin(angle)) * radius * 0.7
		var start := centre + offset
		var query := PhysicsRayQueryParameters3D.create(start, start - Vector3.UP * (radius + 0.18), 1)
		query.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and Vector3(hit.normal).y > 0.65:
			return true
	return false

func _apply_boundary_controls(controls: Dictionary) -> Dictionary:
	var horizontal := Vector2(global_position.x, global_position.z) - _bounds_center
	boundary_strength = smoothstep(soft_boundary_radius, hard_boundary_radius - 5.0, horizontal.length())
	var ceiling_strength := smoothstep(flight_ceiling - 8.0, flight_ceiling, global_position.y)
	boundary_active = boundary_strength > 0.01 or ceiling_strength > 0.01
	if not boundary_active:
		return controls
	var adjusted := controls.duplicate()
	if boundary_strength > 0.0:
		var inward := -horizontal.normalized()
		var desired_heading := atan2(-inward.x, -inward.y)
		var angle := wrapf(desired_heading - flight_model.heading, -PI, PI)
		var inward_bank := clampf(-angle / 0.65, -1.0, 1.0)
		adjusted.bank = lerpf(float(controls.get("bank", 0.0)), inward_bank, clampf(boundary_strength * 2.0, 0.0, 1.0))
		adjusted.tuck = float(controls.get("tuck", 0.0)) * (1.0 - boundary_strength)
		adjusted.brake = maxf(float(controls.get("brake", 0.0)), boundary_strength * 0.3)
	if ceiling_strength > 0.0:
		adjusted.pitch = lerpf(float(controls.get("pitch", 0.0)), -0.45, ceiling_strength)
		adjusted.flap = float(controls.get("flap", 0.0)) * (1.0 - ceiling_strength)
	return adjusted

func _apply_boundary_wind(delta: float) -> void:
	if boundary_strength > 0.0:
		var horizontal := Vector2(global_position.x, global_position.z) - _bounds_center
		var inward := Vector3(-horizontal.x, 0.0, -horizontal.y).normalized()
		var outward_speed := maxf(0.0, -velocity.dot(inward))
		velocity += inward * (8.0 + outward_speed * 0.28) * boundary_strength * delta
	var ceiling_strength := smoothstep(flight_ceiling - 8.0, flight_ceiling, global_position.y)
	velocity.y -= ceiling_strength * (8.0 + maxf(0.0, velocity.y) * 1.2) * delta
	flight_model.velocity = velocity
	telemetry["boundary"] = boundary_strength

func _guard_world_limits() -> void:
	var horizontal := Vector2(global_position.x, global_position.z) - _bounds_center
	if horizontal.length() > hard_boundary_radius:
		horizontal = horizontal.limit_length(hard_boundary_radius)
		global_position.x = _bounds_center.x + horizontal.x
		global_position.z = _bounds_center.y + horizontal.y
		var outward := Vector3(horizontal.x, 0.0, horizontal.y).normalized()
		if velocity.dot(outward) > 0.0:
			velocity -= outward * velocity.dot(outward)
		flight_model.velocity = velocity
	if global_position.y > flight_ceiling:
		global_position.y = flight_ceiling
		velocity.y = minf(velocity.y, -1.2)
		flight_model.velocity = velocity

func _read_controls(delta: float) -> Dictionary:
	_helper_cooldown = maxf(0.0, _helper_cooldown - delta)
	if xr_active:
		var valid := left_controller.get_has_tracking_data() and right_controller.get_has_tracking_data()
		tracking_valid = valid
		tracking_lost_seconds = 0.0 if valid else tracking_lost_seconds + delta
		if valid:
			var helper_pressed := left_controller.is_button_pressed("ax_button") or right_controller.is_button_pressed("ax_button")
			if not _tracking_was_valid:
				gesture.reset()
				_helper_held = helper_pressed
			if not _calibrated_tracking:
				calibrate()
			_tracking_was_valid = true
			var squeeze := minf(left_controller.get_float("grip"), right_controller.get_float("grip"))
			var trigger := minf(left_controller.get_float("trigger"), right_controller.get_float("trigger"))
			var result := gesture.sample(delta, left_controller.transform, right_controller.transform, head.transform, squeeze, trigger)
			if helper_pressed and not _helper_held and _helper_cooldown <= 0.0:
				result.flap = maxf(float(result.flap), 0.88)
				_helper_cooldown = 0.30
			_helper_held = helper_pressed
			var stick := right_controller.get_vector2("primary")
			if absf(stick.x) > 0.75 and not _snap_held and _snap_cooldown <= 0.0 and flying and not get_tree().paused:
				_snap_turn(-signf(stick.x) * PI / 6.0)
				_snap_held = true
			elif absf(stick.x) < 0.3:
				_snap_held = false
			return result
		_tracking_was_valid = false
		gesture.reset()
		return {"spread": 0.82, "pitch": 0.0, "bank": 0.0, "tuck": 0.0, "brake": 0.0, "flap": 0.0}
	tracking_valid = true
	tracking_lost_seconds = 0.0
	_desktop_pitch = move_toward(_desktop_pitch, float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)), delta * 3.0)
	_desktop_bank = move_toward(_desktop_bank, float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), delta * 4.0)
	var space := Input.is_physical_key_pressed(KEY_SPACE)
	var flap_strength := 1.12 if space and not _space_held else 0.0
	_space_held = space
	return {"spread": 0.82, "pitch": _desktop_pitch, "bank": _desktop_bank, "tuck": float(Input.is_physical_key_pressed(KEY_SHIFT)), "brake": float(Input.is_physical_key_pressed(KEY_CTRL)), "flap": flap_strength}

func _unhandled_input(event: InputEvent) -> void:
	if xr_active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and flying and not get_tree().paused:
		# Mouse turns the bird and looks vertically; the VR head never drives steering.
		_snap_turn(-event.relative.x * 0.0023, false)
		_mouse_pitch = clampf(_mouse_pitch - event.relative.y * 0.0018, -0.80, 0.80)
		head.rotation.x = _mouse_pitch
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_C:
			calibrate()
		elif event.physical_keycode == KEY_Q and flying and not get_tree().paused:
			_snap_turn(PI / 6.0)
		elif event.physical_keycode == KEY_E and flying and not get_tree().paused:
			_snap_turn(-PI / 6.0)

func _snap_turn(angle: float, snap: bool = true) -> void:
	var pivot := head.global_position
	rotation.y += angle
	global_position += pivot - head.global_position
	heading = rotation.y
	flight_model.heading = heading
	flight_model.velocity = flight_model.velocity.rotated(Vector3.UP, angle)
	velocity = velocity.rotated(Vector3.UP, angle)
	if snap:
		_snap_cooldown = 0.3

func _haptic(amplitude: float, seconds: float) -> void:
	if xr_active:
		left_controller.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)
		right_controller.trigger_haptic_pulse("haptic", 0.0, amplitude, seconds, 0.0)

func _build_rig() -> void:
	_collider = CollisionShape3D.new()
	_collider.name = "BirdHull"
	_collider.shape = SphereShape3D.new()
	add_child(_collider)
	origin = XROrigin3D.new()
	origin.name = "TrackingOrigin"
	origin.current = true
	origin.position.y = -1.5
	add_child(origin)
	head = Camera3D.new()
	head.name = "Head"
	head.position.y = 1.6
	head.near = 0.06
	head.far = 1200.0
	head.fov = 85.0
	origin.add_child(head)
	left_controller = XRController3D.new()
	left_controller.name = "LeftWing"
	left_controller.tracker = &"left_hand"
	left_controller.pose = &"grip"
	origin.add_child(left_controller)
	right_controller = XRController3D.new()
	right_controller.name = "RightWing"
	right_controller.tracker = &"right_hand"
	right_controller.pose = &"grip"
	origin.add_child(right_controller)
	left_controller.position = Vector3(-0.40, 1.15, -1.10)
	right_controller.position = Vector3(0.40, 1.15, -1.10)
	for side in [-1.0, 1.0]:
		var wing := _make_wing(side)
		(left_controller if side < 0.0 else right_controller).add_child(wing)
		_wing_nodes.append(wing)

func _make_wing(side: float) -> Node3D:
	var wing := Node3D.new()
	wing.name = "Feathers"
	var teal := StandardMaterial3D.new()
	teal.albedo_color = Color("#285d67")
	teal.roughness = 0.82
	teal.cull_mode = BaseMaterial3D.CULL_DISABLED
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color("#e7bd70")
	gold.roughness = 0.85
	gold.cull_mode = BaseMaterial3D.CULL_DISABLED
	var base := SurfaceTool.new()
	base.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array[Vector3] = [Vector3.ZERO, Vector3(side * 0.30, 0.025, -0.13), Vector3(side * 0.79, -0.01, -0.09), Vector3(side * 1.20, -0.06, 0.12), Vector3(side * 0.88, -0.07, 0.40), Vector3(side * 0.40, -0.025, 0.43), Vector3(side * 0.04, 0.0, 0.18)]
	for index in range(1, points.size() - 1):
		_add_wing_triangle(base, points[0], points[index], points[index + 1])
	base.generate_normals()
	base.index()
	var membrane := MeshInstance3D.new()
	membrane.mesh = base.commit()
	membrane.material_override = teal
	wing.add_child(membrane)
	for index in range(7):
		var feather := SurfaceTool.new()
		feather.begin(Mesh.PRIMITIVE_TRIANGLES)
		var x := 0.22 + float(index) * 0.135
		var length := 0.40 + sin(float(index) / 6.0 * PI) * 0.16
		var p := Vector3(side * x, -0.032, 0.16)
		_add_wing_triangle(feather, p, p + Vector3(side * 0.16, -0.018, length * 0.78), p + Vector3(side * 0.065, -0.065, length))
		feather.generate_normals()
		feather.index()
		var mesh := MeshInstance3D.new()
		mesh.mesh = feather.commit()
		mesh.material_override = gold if index >= 4 else teal
		wing.add_child(mesh)
	return wing

func _add_wing_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	# Explicit indices and valid faces keep the mobile multiview upload path
	# well-defined. Degenerate faces would otherwise generate invalid normals.
	if not a.is_finite() or not b.is_finite() or not c.is_finite():
		return
	var cross := (b - a).cross(c - a)
	if not cross.is_finite() or cross.length_squared() < 0.00000001:
		return
	for vertex in [a, b, c]:
		surface.add_vertex(vertex)

func _update_wings(delta: float, controls: Dictionary) -> void:
	_wing_animation = maxf(0.0, _wing_animation - delta * 4.8)
	if not xr_active:
		var animation := sin(_wing_animation * PI) * 0.34
		left_controller.position.y = 1.15 - animation + float(controls.get("bank", 0.0)) * 0.12
		right_controller.position.y = 1.15 - animation - float(controls.get("bank", 0.0)) * 0.12
		left_controller.rotation.z = -animation * 1.6
		right_controller.rotation.z = animation * 1.6
	for index in range(_wing_nodes.size()):
		var side := -1.0 if index == 0 else 1.0
		_wing_nodes[index].rotation.y = side * float(controls.get("tuck", 0.0)) * 0.92
		_wing_nodes[index].rotation.x = -float(controls.get("pitch", 0.0)) * 0.16
