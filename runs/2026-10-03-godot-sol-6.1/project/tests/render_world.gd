extends SceneTree
## Reproducible host-side graphics regression probe for the procedural world.
## Run a real render window (not --headless):
## godot --path . --xr-mode off --script res://tests/render_world.gd
## The full game/simulator verifies stereo separately; this narrow probe detects
## magenta tile corruption across 96 moving-camera frames of world-only art.
var camera: Camera3D
var world: Node3D

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("World render probe requires a real Mobile/Vulkan render window.")
		quit(2)
		return
	root.size = Vector2i(1440, 900)
	var scene := Node3D.new()
	root.add_child(scene)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("6ba8b2")
	sky_mat.sky_horizon_color = Color("d9ccab")
	sky_mat.ground_bottom_color = Color("879e91")
	sky_mat.ground_horizon_color = Color("d9ccab")
	sky_mat.sky_curve = 0.15
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("bfd5c3")
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color("d6c9a8")
	env.fog_density = 0.0015
	env_node.environment = env
	scene.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-28, -40, 0)
	sun.light_color = Color("ffdda5")
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.shadow_bias = 0.07
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_max_distance = 150
	scene.add_child(sun)
	world = preload("res://scripts/world/world.gd").new()
	scene.add_child(world)
	camera = Camera3D.new()
	camera.fov = 76
	camera.far = 650
	scene.add_child(camera)
	camera.current = true
	var positions := [Vector3(1.5, 14, 41), Vector3(35, 25, 14), Vector3(65, 32, 0), Vector3(-67, 32, -37)]
	var tested_frames := 0
	var bad_pixels := 0
	for view in range(96):
		camera.position = positions[(view / 6) % positions.size()] + Vector3(sin(view * 0.8) * 2, sin(view * 0.4), 0)
		var angle := (view % 6 - 2.5) * 0.28
		camera.look_at(camera.position + Vector3(sin(angle), -0.03, -cos(angle)) * 30, Vector3.UP)
		for frame in range(10):
			await process_frame
		await RenderingServer.frame_post_draw
		var rendered := root.get_texture().get_image()
		rendered.resize(360, 225, Image.INTERPOLATE_NEAREST)
		rendered.convert(Image.FORMAT_RGBA8)
		var pixels := rendered.get_data()
		var frame_magenta := 0
		for i in range(0, pixels.size(), 4):
			if pixels[i] > 240 and pixels[i + 1] < 15 and pixels[i + 2] > 240:
				frame_magenta += 1
		if frame_magenta > 0:
			root.get_texture().get_image().save_png("/private/tmp/soaring-world-render-failure-%d.png" % view)
		bad_pixels += frame_magenta
		tested_frames += 1
	print("WORLD_RENDER_AUDIT: %d moving-camera Mobile/Vulkan frames; %d unexpected magenta pixels" % [tested_frames, bad_pixels])
	quit(0 if bad_pixels == 0 else 1)
