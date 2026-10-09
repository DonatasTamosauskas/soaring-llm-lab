extends Node3D

const WorldScript = preload("res://scripts/world/world.gd")
const PlayerScript = preload("res://scripts/flight/player.gd")
const EcologyScript = preload("res://scripts/ecology/ecosystem.gd")
const UIScript = preload("res://scripts/ui/game_ui.gd")
const AudioScript = preload("res://scripts/audio.gd")
var world: Node3D
var player: CharacterBody3D
var ecology: Node3D
var ui: Control
var audio: Node
var xr_active := false
var xr: OpenXRInterface
var state := "nest"
var comfort_enabled := true
var crowned := false
var menu_viewport: SubViewport
var menu_surface: MeshInstance3D
var aim_controllers: Array[XRController3D] = []
var ray_meshes: Array[MeshInstance3D] = []
var wrist_label: Label3D
var xr_toast: Label3D
var toast_time := 0.0
var vignette: MeshInstance3D
var vignette_material: ShaderMaterial
var spectator: SubViewport
var spectator_camera: Camera3D
var runtime_age := 0.0
var capture_path := ""
var capture_mode := "nest"
var smoke_seconds := 0.0
var captured := false
var smoke_done := false
var report_path := ""
var auto_start := false
var course_index := 0
var course_previous := Vector3.ZERO
var route_points: Array[Vector3] = []
var frame_count := 0
var fps_sum := 0.0
var render_stats := {}
var control_events := {"menu":0,"calibration":0,"flaps":0}
var trail_progress := {}
var completed_trails := 0
var danger_text := ""
var last_danger_warning := 0.0
var telemetry_path := ""
var telemetry_due := 0.0
var calibration_remaining := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_args()
	xr = XRServer.find_interface("OpenXR") as OpenXRInterface
	xr_active = xr != null and xr.is_initialized()
	if xr_active:
		# The Mac simulator uses Forward+ through MoltenVK. Reduce only its
		# stereo buffer; desktop practice and Android retain full resolution.
		if OS.has_feature("macos"):
			get_viewport().scaling_3d_scale = 0.65
		get_viewport().use_xr = true
		get_viewport().physics_object_picking = false
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		xr.session_begun.connect(_xr_started)
		xr.refresh_rate_changed.connect(_set_refresh_rate)
		xr.session_visible.connect(_xr_focus_lost)
		xr.session_stopping.connect(_xr_focus_lost)
		xr.user_presence_changed.connect(func(present: bool):
			if not present: _xr_focus_lost())
		_xr_started()
	_build_environment()
	world = WorldScript.new()
	world.name = "WildSky"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(world)
	for ring in world.route_rings: trail_progress[ring.route] = 0
	player = PlayerScript.new()
	player.name = "BirdPlayer"
	player.configure(xr_active)
	player.set_flight_bounds(world.flight_bounds)
	add_child(player)
	player.reset_at(world.spawn_position)
	ecology = EcologyScript.new()
	ecology.name = "LivingFlock"
	ecology.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(ecology)
	ecology.configure(player, world)
	ecology.player_grew.connect(_on_growth)
	ecology.player_caught.connect(_on_caught)
	ecology.catch_event.connect(_on_catch)
	ecology.ecosystem_event.connect(_on_ecology_event)
	audio = AudioScript.new()
	add_child(audio)
	player.flap.connect(func(strength: float):
		control_events.flaps += 1
		audio.flap(strength))
	player.collision_hit.connect(audio.bump)
	_build_ui()
	if xr_active: _build_xr_ui()
	_set_state("nest")
	if capture_mode == "guide": ui._toggle_guide()
	elif capture_mode == "paused":
		start_run()
		_set_state("paused")
	elif capture_mode == "caught": _on_caught("Eagle")
	if not capture_path.is_empty() and xr_active: _build_spectator()
	if capture_mode == "overview" or capture_mode == "town" or capture_mode == "grove":
		_set_photo_camera(capture_mode)
	if auto_start and not xr_active: call_deferred("start_run")
	print("SOARING_READY ", JSON.stringify({"xr":xr_active,"world":_world_summary(),"population":ecology.get_stats().get("population",0)}))

func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("508f9c")
	sky_material.sky_horizon_color = Color("f6d6a1")
	sky_material.ground_bottom_color = Color("45594f")
	sky_material.ground_horizon_color = Color("e2c69c")
	sky_material.sky_curve = 0.2
	sky_material.sun_angle_max = 7
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d7eeec")
	environment.ambient_light_energy = 0.5
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true
	environment.fog_light_color = Color("d0dacf")
	environment.fog_density = 0.0017
	environment.fog_aerial_perspective = 0.5
	var env_node := WorldEnvironment.new()
	env_node.environment = environment
	add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32,-28,0)
	sun.light_color = Color("ffe0ad")
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 130
	sun.shadow_bias = 0.07
	sun.shadow_normal_bias = 1.2
	add_child(sun)

func _build_ui() -> void:
	ui = UIScript.new()
	ui.xr_mode = xr_active
	if xr_active:
		menu_viewport = SubViewport.new()
		menu_viewport.size = Vector2i(1000, 820)
		menu_viewport.transparent_bg = true
		menu_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		menu_viewport.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(menu_viewport)
		menu_viewport.add_child(ui)
	else:
		var layer := CanvasLayer.new()
		layer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(layer)
		layer.add_child(ui)
	ui.launch_requested.connect(start_run)
	ui.resume_requested.connect(resume_run)
	ui.restart_requested.connect(restart_run)
	ui.calibrate_requested.connect(calibrate)
	ui.comfort_changed.connect(func(on: bool):
		comfort_enabled = on
		player.set_comfort(on))
	ui.sound_changed.connect(audio.set_enabled)
	ui.quit_requested.connect(func(): get_tree().quit())

func _build_xr_ui() -> void:
	menu_surface = MeshInstance3D.new()
	menu_surface.name = "TrackedFlightMenu"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.2,1.804)
	menu_surface.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = menu_viewport.get_texture()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	menu_surface.material_override = material
	add_child(menu_surface)
	for side in ["left_hand", "right_hand"]:
		var aim := XRController3D.new()
		aim.tracker = side
		aim.pose = "aim"
		aim.process_mode = Node.PROCESS_MODE_ALWAYS
		player.origin.add_child(aim)
		aim_controllers.append(aim)
		aim.button_pressed.connect(_xr_button.bind(aim))
		var ray := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.003
		cylinder.bottom_radius = 0.003
		cylinder.height = 1
		cylinder.radial_segments = 5
		ray.mesh = cylinder
		var ray_material := StandardMaterial3D.new()
		ray_material.albedo_color = Color("f6c77c")
		ray_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ray.material_override = ray_material
		add_child(ray)
		ray_meshes.append(ray)
	wrist_label = Label3D.new()
	wrist_label.font_size = 30
	wrist_label.pixel_size = 0.00065
	wrist_label.modulate = Color("ecedda")
	wrist_label.outline_size = 6
	wrist_label.position = Vector3(0,0.12,-0.17)
	wrist_label.rotation_degrees.x = -65
	player.left_controller.add_child(wrist_label)
	xr_toast = Label3D.new()
	xr_toast.font_size = 32
	xr_toast.pixel_size = 0.0015
	xr_toast.position = Vector3(0,-0.32,-1.8)
	xr_toast.modulate = Color("ffe0a1")
	player.head.add_child(xr_toast)
	_build_vignette()
	_place_menu()

func _build_vignette() -> void:
	vignette = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.4,1.4)
	vignette.mesh = quad
	vignette.position.z = -0.3
	vignette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_disabled, depth_test_disabled, shadows_disabled; uniform float strength = 0.0; void fragment(){ float d=length(UV-vec2(0.5))*2.0; ALBEDO=vec3(0.015,0.04,0.045); ALPHA=smoothstep(0.40,0.72,d)*strength; }"
	vignette_material = ShaderMaterial.new()
	vignette_material.shader = shader
	vignette.material_override = vignette_material
	player.head.add_child(vignette)

func _place_menu() -> void:
	if not menu_surface: return
	var head_transform: Transform3D = player.head.global_transform
	var forward := -head_transform.basis.z
	forward.y = 0
	if forward.length_squared() < 0.01: forward = Vector3.FORWARD
	forward = forward.normalized()
	menu_surface.global_position = head_transform.origin + forward * 2.4
	menu_surface.look_at(head_transform.origin, Vector3.UP, true)

func _xr_button(button: String, aim: XRController3D) -> void:
	if button == "menu_button":
		control_events.menu += 1
		toggle_pause()
	elif button == "trigger_click" and state != "flying":
		var point := _menu_point(aim)
		if point.x >= 0:
			var down := InputEventMouseButton.new()
			down.position = point
			down.button_index = MOUSE_BUTTON_LEFT
			down.pressed = true
			menu_viewport.push_input(down, true)
			var up := down.duplicate() as InputEventMouseButton
			up.pressed = false
			menu_viewport.push_input(up, true)

func _menu_point(aim: XRController3D) -> Vector2:
	if not menu_surface.visible or not aim.get_is_active(): return Vector2(-1,-1)
	var inverse := menu_surface.global_transform.affine_inverse()
	var start: Vector3 = inverse * aim.global_position
	var direction: Vector3 = inverse.basis * -aim.global_basis.z
	if absf(direction.z) < 0.001: return Vector2(-1,-1)
	var distance := -start.z / direction.z
	if distance < 0 or distance > 8: return Vector2(-1,-1)
	var hit := start + direction * distance
	if absf(hit.x) > 1.1 or absf(hit.y) > 0.902: return Vector2(-1,-1)
	return Vector2((hit.x / 2.2 + 0.5) * 1000, (0.5 - hit.y / 1.804) * 820)

func start_run() -> void:
	if state == "nest":
		ecology.reset_run()
		player.reset_at(world.spawn_position)
		course_previous = player.global_position
		_set_state("flying")
		_toast("Find a smaller bird. Short flaps give you lift.", 6)

func resume_run() -> void:
	if state == "paused": _set_state("flying")

func restart_run() -> void:
	get_tree().paused = false
	ecology.reset_run()
	player.reset_at(world.spawn_position)
	player.set_mass(ecology.player_mass)
	crowned = false
	course_index = 0
	completed_trails = 0
	for key in trail_progress: trail_progress[key] = 0
	_set_state("nest")
	if auto_start: start_run()

func calibrate() -> void:
	if xr_active:
		calibration_remaining = 2.0
		ui.note.text = "Relax both elbows. Wing calibration in 2 seconds…"
		_toast("Relax both elbows. Wing calibration in 2 seconds…",3)
		return
	_finish_calibration()

func _finish_calibration() -> void:
	player.calibrate()
	if xr_active and menu_surface: _place_menu()
	control_events.calibration += 1
	_toast("Wing position calibrated. Keep your elbows relaxed.")
	if ui and state != "flying": ui.show_state(ui.state)

func toggle_pause() -> void:
	if state == "flying": _set_state("paused")
	elif state == "paused": resume_run()
	elif ui.state == "guide": ui.show_state(state)

func _set_state(value: String, details := "") -> void:
	state = value
	get_tree().paused = state == "paused" or state == "caught"
	player.set_flying(state == "flying")
	ecology.set_active(state == "flying")
	ui.show_state(state, details)
	if xr_active:
		menu_surface.visible = state != "flying"
		menu_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if state != "flying" else SubViewport.UPDATE_DISABLED
		wrist_label.visible = state == "flying"
		if menu_surface.visible: _place_menu()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if state == "flying" else Input.MOUSE_MODE_VISIBLE

func _on_growth(mass: float, tier: String) -> void:
	player.set_mass(mass)
	_toast("%s  •  %.2f mass" % [tier.to_upper(),mass])
	audio.growth_chime()
	if mass >= 8 and not crowned:
		crowned = true
		_toast("SOVEREIGN OF THE SKY — keep exploring!", 8)

func _on_catch(pos: Vector3, mass: float) -> void:
	audio.catch_chime(pos,mass)
	_haptic(0.22,0.07)

func _on_caught(predator: String) -> void:
	_set_state("caught", "Caught by %s.\n%d catches  /  %.2f mass  /  %d seconds aloft." % [predator,ecology.catches,ecology.player_mass,ecology.elapsed])
	_haptic(0.4,0.16)

func _on_ecology_event(message: String) -> void:
	if not message.is_empty() and state == "flying": _toast(message)

func _haptic(amplitude: float, duration: float) -> void:
	if xr_active:
		for controller in [player.left_controller,player.right_controller]:
			if controller.get_is_active(): controller.trigger_haptic_pulse("haptic", 0, amplitude, duration, 0)

func _toast(message: String, duration := 3.5) -> void:
	if ui: ui.toast(message,duration)
	toast_time = duration
	if xr_toast: xr_toast.text = message

func _xr_started() -> void:
	_set_refresh_rate(xr.display_refresh_rate)
	print("XR_SESSION_STARTED ", xr.get_session_state())

func _set_refresh_rate(hz: float) -> void:
	Engine.physics_ticks_per_second = clampi(roundi(hz),72,144) if hz > 1 else 90

func _xr_focus_lost() -> void:
	if state == "flying" and player: _set_state("paused")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE: toggle_pause()
			KEY_C:
				calibrate()
				get_viewport().set_input_as_handled()
			KEY_R:
				if state != "flying": restart_run()
			KEY_ENTER:
				if state == "nest": start_run()
				elif state == "paused": resume_run()
				elif state == "caught": restart_run()

func _physics_process(_dt: float) -> void:
	if not player or state != "flying": return
	player.set_thermal_lift(world.thermal_at(player.global_position))
	_check_trails()
	if player.global_position.y < -6:
		player.reset_at(world.spawn_position)
		_set_state("paused")
		_toast("Returned to your nest. Continue when you're ready.",6)

func _check_trails() -> void:
	var pos := player.global_position
	for ring in world.route_rings:
		if int(ring.index) != int(trail_progress[ring.route]): continue
		var a: float = (course_previous - ring.center).dot(ring.normal)
		var b: float = (pos - ring.center).dot(ring.normal)
		if a * b > 0 or absf(a-b) < 0.001: continue
		var crossing: Vector3 = course_previous.lerp(pos, a / (a-b))
		if crossing.distance_to(ring.center) > float(ring.radius) - 0.35 * pow(player.mass,0.2): continue
		trail_progress[ring.route] += 1
		var total := 0
		for other in world.route_rings:
			if other.route == ring.route: total += 1
		if trail_progress[ring.route] == total:
			completed_trails += 1
			_toast("%s complete! %d / 3 sky trails" % [ring.route,completed_trails],5)
			audio.growth_chime()
		else:
			_toast("%s  •  gate %d / %d" % [ring.route,trail_progress[ring.route],total],2)
			audio.catch_chime()
		_haptic(0.12,0.035)
	course_previous = pos

func _danger_hint(stats: Dictionary) -> String:
	var danger: Dictionary = stats.get("nearest_danger",{})
	if danger.is_empty() or float(danger.distance) > 28 or ecology.grace_remaining > 0: return ""
	var offset: Vector3 = player.head.global_basis.inverse() * (danger.position - player.head.global_position)
	var bearing := "AHEAD"
	if absf(offset.x) > absf(offset.z) * 0.6: bearing = "LEFT" if offset.x < 0 else "RIGHT"
	elif offset.z > 0: bearing = "BEHIND"
	return "%s   /   %s   /   %d M" % [str(danger.tier).to_upper(),bearing,int(danger.distance)]

func _process(dt: float) -> void:
	if not player: return
	runtime_age += dt
	if calibration_remaining > 0:
		calibration_remaining = maxf(0,calibration_remaining - dt)
		if calibration_remaining == 0: _finish_calibration()
	if auto_start and state == "nest" and xr_active and xr.get_session_state() == OpenXRInterface.SESSION_STATE_FOCUSED:
		start_run()
	frame_count += 1
	fps_sum += Engine.get_frames_per_second()
	var thermal: float = world.thermal_at(player.global_position)
	var stats: Dictionary = ecology.get_stats()
	danger_text = _danger_hint(stats)
	stats["danger_text"] = danger_text
	stats["perched"] = player.perched
	if xr_active and state == "flying" and player.tracking_lost_seconds > 0.75:
		_set_state("paused")
		_toast("Controller tracking lost. Restore tracking, then continue.",6)
	ui.update_hud(stats,player.velocity.length(),player.global_position.y,world.zone_at(player.global_position),thermal)
	audio.update_speed(player.velocity.length(),state == "flying")
	toast_time = maxf(0,toast_time - dt)
	if xr_active:
		if runtime_age < 1.0 and state != "flying": _place_menu()
		wrist_label.text = "%s   %.2f\n%.1f m/s   %d m%s\n%s" % [ecology.get_player_tier(),ecology.player_mass,player.velocity.length(),player.global_position.y,"   ↑" if thermal > 0.3 else "","PERCHED • FLAP TO LAUNCH" if player.perched else danger_text]
		xr_toast.visible = toast_time > 0 and state == "flying"
		vignette_material.set_shader_parameter("strength", clampf((player.velocity.length() - 9) / 25,0,0.45) if comfort_enabled and state == "flying" else 0.0)
		_update_menu_rays()
	if spectator_camera: spectator_camera.global_transform = player.head.global_transform
	if not captured and not capture_path.is_empty() and runtime_age > 4:
		captured = true
		_capture.call_deferred()
	if smoke_seconds > 0 and runtime_age > smoke_seconds and not smoke_done:
		smoke_done = true
		_finish_smoke.call_deferred()
	if not telemetry_path.is_empty() and runtime_age > telemetry_due:
		telemetry_due = runtime_age + 0.2
		var file := FileAccess.open(telemetry_path,FileAccess.WRITE)
		if file: file.store_string(JSON.stringify(get_runtime_report()))

func _update_menu_rays() -> void:
	for i in aim_controllers.size():
		var aim := aim_controllers[i]
		var ray := ray_meshes[i]
		ray.visible = state != "flying" and aim.get_is_active()
		if not ray.visible: continue
		var point := _menu_point(aim)
		var length := 2.8
		if point.x >= 0:
			var motion := InputEventMouseMotion.new()
			motion.position = point
			menu_viewport.push_input(motion,true)
			var hit := menu_surface.global_transform * Vector3((point.x / 1000 - 0.5)*2.2, (0.5-point.y/820)*1.804,0)
			length = aim.global_position.distance_to(hit)
		var direction := -aim.global_basis.z
		ray.global_position = aim.global_position + direction * length * 0.5
		ray.global_basis = Basis(Quaternion(Vector3.UP,direction))
		ray.scale.y = length

func _read_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--capture-mode="): capture_mode = arg.trim_prefix("--capture-mode=")
		elif arg.begins_with("--smoke-seconds="): smoke_seconds = arg.trim_prefix("--smoke-seconds=").to_float()
		elif arg.begins_with("--report="): report_path = arg.trim_prefix("--report=")
		elif arg.begins_with("--telemetry="): telemetry_path = arg.trim_prefix("--telemetry=")
		elif arg == "--auto-start": auto_start = true

func _build_spectator() -> void:
	spectator = SubViewport.new()
	spectator.size = Vector2i(1440,900)
	spectator.world_3d = get_viewport().world_3d
	spectator.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(spectator)
	spectator_camera = Camera3D.new()
	spectator_camera.fov = 90
	spectator_camera.far = 800
	spectator.add_child(spectator_camera)

func _set_photo_camera(mode: String) -> void:
	var camera := Camera3D.new()
	camera.far = 850
	camera.fov = 74
	add_child(camera)
	var pos := Vector3(80,78,140)
	var target := Vector3(0,15,-30)
	var names := {"overview":"valley", "town":"quarter", "grove":"canopy"}
	var presets: Array = world.get_world_stats().get("camera_presets",[])
	for preset in presets:
		if preset.name == names.get(mode,mode):
			pos = preset.position
			target = preset.look_at
			break
	camera.global_position = pos
	camera.look_at(target)
	camera.current = true
	ui.visible = false

func _capture() -> void:
	if spectator: spectator.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var viewport: Viewport = spectator if spectator else get_viewport()
	var screenshot := viewport.get_texture().get_image()
	var error := screenshot.save_png(capture_path)
	print("CAPTURE ",capture_path," result=",error)

func _world_summary() -> Dictionary:
	var summary: Dictionary = world.get_world_stats()
	for key in ["window_probes", "route_rings", "camera_presets"]: summary.erase(key)
	return summary

func get_runtime_report() -> Dictionary:
	return {"xr_active":xr_active,"xr_session_state":xr.get_session_state() if xr_active else -1,
		"state":state,"runtime_seconds":runtime_age,"frames":frame_count,"average_fps":fps_sum/maxi(1,frame_count),
		"physics_hz":Engine.physics_ticks_per_second,"world":_world_summary(),"ecosystem":ecology.get_stats(),
		"player_position":player.global_position,"player_velocity":player.velocity,"controls":control_events,
		"trails_completed":completed_trails,
		"tracking_valid":player.tracking_valid,"tracking_lost_seconds":player.tracking_lost_seconds,
		"head_position":[player.head.position.x,player.head.position.y,player.head.position.z],
		"left_position":[player.left_controller.position.x,player.left_controller.position.y,player.left_controller.position.z],
		"right_position":[player.right_controller.position.x,player.right_controller.position.y,player.right_controller.position.z],
		"flight":player.telemetry,
		"perched":player.perched,"ui_primary_rect":[ui.primary.global_position.x,ui.primary.global_position.y,ui.primary.size.x,ui.primary.size.y],
		"menu_points":_get_menu_points(),
		"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)}

func _get_menu_points() -> Array:
	var points := []
	if xr_active:
		for aim in aim_controllers:
			var point := _menu_point(aim)
			points.append([point.x,point.y])
	return points

func _finish_smoke() -> void:
	var report := get_runtime_report()
	print("SOARING_SMOKE ",JSON.stringify(report))
	if not report_path.is_empty():
		var file := FileAccess.open(report_path,FileAccess.WRITE)
		if file: file.store_string(JSON.stringify(report,"\t"))
	get_tree().paused = false
	get_tree().quit()
