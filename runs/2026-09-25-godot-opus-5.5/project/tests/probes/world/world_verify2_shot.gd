extends Node3D
## Verifier probe, round 2: a screenshot of the over-budget forest view
## (forest_034 from world_verify2_perf.gd) for the record.
##
##   tools/gd.sh world_verify2 --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_verify2_shot.tscn
##
## Writes artifacts/world/verify/r2/v2_forest_034.png.

func _ready() -> void:
	var world: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	var cam := Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	cam.global_position = Vector3(-276.6, 16.0, -331.2)
	cam.look_at(Vector3(-247.8, 20.0, -290.4), Vector3.UP)
	print("[world-verify2] ground at camera %.1f" % world.ground_height(-276.6, -331.2))
	for i in 8:
		await get_tree().process_frame
	var out := Paths.artifacts("world").path_join("verify").path_join("r2")
	DirAccess.make_dir_recursive_absolute(out)
	await Capture.save_viewport(get_viewport(), out.path_join("v2_forest_034.png"))
	get_tree().quit()
