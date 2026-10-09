extends Node3D
# Run only in the private Godot copy; original game files stay untouched.
var camera: Camera3D

func vector(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("SOARING_COMPARISON_ROUTE")))
	var output := OS.get_environment("SOARING_COMPARISON_OUTPUT")
	var frames := OS.get_environment("SOARING_COMPARISON_FRAMES")
	DirAccess.make_dir_recursive_absolute(output)
	DirAccess.make_dir_recursive_absolute(frames)
	var world := load("res://scenes/world/world.tscn").instantiate() as SoaringWorld
	add_child(world)
	camera = Camera3D.new()
	camera.fov = float(route.verticalFov)
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = float(route.near)
	camera.far = float(route.far)
	add_child(camera)
	camera.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
	var count := int(route.fps * route.secondsPerView)
	var frame := 0
	for view: Dictionary in route.views:
		camera.position = vector(view.position)
		camera.look_at(vector(view.target))
		for i in 8:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), output.path_join(view.id + ".png"))
		for i in count:
			var fraction := float(i) / float(count - 1) - 0.5
			camera.position = vector(view.position) + vector(view.travel) * fraction
			camera.look_at(vector(view.target))
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image()
			var err := image.save_png(frames.path_join("%05d.png" % frame))
			if err != OK:
				push_error("Comparison frame could not be saved")
				get_tree().quit(1)
				return
			frame += 1
			await get_tree().process_frame
		print("COMPARISON_GODOT_VIEW_OK ", view.id)
	var report := {"engine": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name(), "world_seed": world.world_seed, "frame_count": frame, "route": route, "mode": "world only; no NPCs or HUD; native lighting and materials"}
	var file := FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	print("COMPARISON_GODOT_OK frames=", frame)
	get_tree().quit()
