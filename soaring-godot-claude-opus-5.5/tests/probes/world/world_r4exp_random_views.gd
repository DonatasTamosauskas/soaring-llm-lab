extends Node3D
## Verifier probe, round 4: unbiased look at the world. The builder's 51
## screenshots are chosen views; these are seeded random player-like views
## (3-60 m above the ground anywhere in the populated valley, random
## heading, slight look-down) plus a few edge cases, to judge W8 away from
## the curated angles.
##
##   tools/gd.sh world_r4shot --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_r4exp_random_views.tscn
##
## Writes artifacts/world/verify/r4exp/r4exp_rand_*.png.

var cam: Camera3D


func _ready() -> void:
	var world: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.03
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var out := Paths.artifacts("world").path_join("verify").path_join("r4exp")
	DirAccess.make_dir_recursive_absolute(out)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4_040_404
	var n := 0
	while n < 12:
		var p := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 470.0
		var g := world.ground_height(p.x, p.y)
		var y := g + rng.randf_range(3.0, 60.0)
		var pos := Vector3(p.x, y, p.y)
		# Not inside anything.
		var sp := SphereShape3D.new()
		sp.radius = 0.5
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sp
		q.transform = Transform3D(Basis.IDENTITY, pos)
		await get_tree().physics_frame
		if not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			continue
		var yaw := rng.randf() * TAU
		var pitch := deg_to_rad(rng.randf_range(-25.0, 3.0))
		var d := Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
		await _shot(out.path_join("r4exp_rand_%02d.png" % n), pos, pos + d * 10.0)
		print("[world-r4] rand %02d at %s heading %.0f deg pitch %.0f deg" % [n, str(pos.snapped(Vector3.ONE * 0.1)), rad_to_deg(yaw), rad_to_deg(pitch)])
		n += 1
	# Edge cases: under the lid near the rim looking out; at the water line;
	# the hedge foot at 0.5 m; the canyon floor looking up at the arch.
	await _shot(out.path_join("r4exp_edge_lid_rim.png"), Vector3(-560, 290, -300), Vector3(-700, 250, -380))
	await _shot(out.path_join("r4exp_edge_lake_waterline.png"), Vector3(120, 0.2, 200), Vector3(200, -0.3, 240))
	var hp := WorldLayout.FIELDS_ORIGIN + Vector2(112.0 * 2.0 + 6.0, 64.0 + 2.0)
	await _shot(out.path_join("r4exp_edge_hedge_foot.png"), Vector3(hp.x, world.ground_height(hp.x, hp.y) + 0.5, hp.y), Vector3(hp.x - 10.0, world.ground_height(hp.x, hp.y), hp.y - 2.0))
	await _shot(out.path_join("r4exp_edge_mountain_foot.png"), Vector3(430, world.ground_height(430, -330) + 4.0, -330), Vector3(560, world.ground_height(430, -330) + 40.0, -430))
	get_tree().quit()


func _shot(path: String, eye: Vector3, at: Vector3) -> void:
	cam.global_position = eye
	cam.look_at(at, Vector3.UP)
	for i in 8:
		await get_tree().process_frame
	await Capture.save_viewport(get_viewport(), path)
