extends Node3D
# Diagnostic only: installed in a disposable copy, no game resources are saved.
var modes := ["baseline", "baseline-control", "no-fog", "linear", "no-fog-linear"]
var views: Array[SubViewport] = []
var cameras: Array[Camera3D] = []

func vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

func settings(env: Environment) -> Dictionary:
	return {"fog_enabled":env.fog_enabled,"fog_density":env.fog_density,"fog_color":env.fog_light_color.to_html(false),"fog_mode":env.fog_mode,"fog_sky_affect":env.fog_sky_affect,"fog_aerial_perspective":env.fog_aerial_perspective,"fog_sun_scatter":env.fog_sun_scatter,"tonemap_mode":env.tonemap_mode,"tonemap_exposure":env.tonemap_exposure,"tonemap_white":env.tonemap_white,"adjustment_enabled":env.adjustment_enabled,"glow_enabled":env.glow_enabled,"volumetric_fog_enabled":env.volumetric_fog_enabled}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("SOARING_COMPARISON_ROUTE")))
	var output := OS.get_environment("SOARING_FOG_OUTPUT")
	var world := load("res://scenes/world/world.tscn").instantiate() as SoaringWorld
	add_child(world)
	var environments := {}
	for mode: String in modes:
		var vp := SubViewport.new()
		vp.size = Vector2i(int(route.width),int(route.height))
		vp.world_3d = get_viewport().world_3d
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var cam := Camera3D.new()
		cam.fov = float(route.verticalFov)
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.near = float(route.near)
		cam.far = float(route.far)
		cam.environment = world.environment_node.environment.duplicate() as Environment
		if mode in ["no-fog","no-fog-linear"]: cam.environment.fog_enabled = false
		if mode in ["linear","no-fog-linear"]: cam.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		vp.add_child(cam)
		cam.current = true
		views.append(vp); cameras.append(cam)
		environments[mode] = settings(cam.environment)
		DirAccess.make_dir_recursive_absolute(output.path_join(mode))
	# Display one native viewport; screenshots are read from all five at once.
	var preview := TextureRect.new()
	preview.texture = views[2].get_texture()
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(preview)
	for view: Dictionary in route.views:
		for cam in cameras:
			cam.position = vec(view.position)
			cam.look_at(vec(view.target))
		for i in 12: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		# Every variant uses the same world, camera, animation time and draw frame.
		for i in views.size():
			var image := views[i].get_texture().get_image()
			assert(image != null and not image.is_empty())
			var error := image.save_png(output.path_join(modes[i]).path_join(view.id + ".png"))
			assert(error == OK)
		print("FOG_PROBE_VIEW_OK ",view.id)
	var report := {"engine":Engine.get_version_info().string,"renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name(),"world_seed":world.world_seed,"route":route,"environments":environments,"method":"simultaneous native subviewports sharing one world; identical camera, animation time and draw frame; baseline-control duplicates original settings"}
	var file := FileAccess.open(output.path_join("capture.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	print("FOG_PROBE_OK")
	get_tree().quit()
