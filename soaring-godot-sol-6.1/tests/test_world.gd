extends SceneTree

const WorldScript = preload("res://scripts/world/world.gd")
var failures: Array[String] = []
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var world := WorldScript.new()
	scene.add_child(world)
	await physics_frame
	await physics_frame
	_audit_mesh_node(world)
	var stats: Dictionary = world.get_world_stats()
	_check(world.spawn_position.y >= 17, "Spawn must be above the launch platform")
	_check(world.flight_bounds.has_point(world.spawn_position), "Launch belongs to the simulated flight volume")
	_check(stats.get("trees", 0) >= 10, "The grove requires layered trees")
	_check(stats.get("branches", 0) >= 70, "Layered branches are real perching routes")
	_check(stats.get("buildings", 0) >= 7, "Quarter requires a variety of building heights")
	_check(stats.get("windows", 0) >= 150, "Hollow buildings must have many fly-through windows")
	_check(stats.get("arches", 0) >= 3, "Coastal flight arches must exist")
	_check(stats.get("nest_entrances", 0) >= 5, "At least four tight nests plus the home aerie")
	_check(stats.get("utility_poles", 0) >= 6, "Utility slalom/perch line must exist")
	_check(stats.get("thermal_count", 0) >= 6, "Each important area has a thermal escape route")
	_check(stats.get("perches", 0) >= 100, "Abundant well-distributed resting perches")
	_check(stats.get("waypoint_count", 0) >= 45, "AI has multiple zones and height bands")
	_check(stats.get("draw_batches", 99) <= 15, "Static artwork must remain XR-friendly")
	_check(stats.get("opaque_triangles", 100000) < 60000, "World triangle budget")
	_check(world._opaque_mesh.material_override.vertex_color_is_srgb, "Hex art palette is interpreted as sRGB")
	_check(world._opaque_mesh.material_override.cull_mode == BaseMaterial3D.CULL_BACK, "Closed art uses ordinary face culling")
	var winding := (world._vertices[1] - world._vertices[0]).cross(world._vertices[2] - world._vertices[0])
	_check(winding.dot(world._normals[0]) < 0, "Clockwise front-face winding agrees with Godot explicit normals")
	_check(stats.get("camera_presets", []).size() >= 5, "Art has reproducible visual inspection viewpoints")
	_check(world.zone_at(world.spawn_position) == "Launch Aerie", "Home zone is correctly named")
	_check(world.zone_at(Vector3(1000, 30, 1000)) == "The Open Sky", "Out-of-range zone query is safe")
	for thermal in world.thermals:
		var c: Vector3 = thermal["center"]
		var midpoint := (float(thermal["bottom"]) + float(thermal["height"])) * 0.5
		_check(world.thermal_at(c + Vector3(0, midpoint, 0)) > 6.0, "Thermal core must support fatigue-free ascent")
		_check(world.thermal_at(c + Vector3(0, float(thermal["height"]) + 0.1, 0)) == 0.0, "Lift never leaks above its visible column")
		_check(world.thermal_at(c + Vector3(0, float(thermal["bottom"]) - 0.1, 0)) == 0.0, "Lift never leaks below column")
		var edge := c + Vector3(float(thermal["radius"]) + 0.1, midpoint, 0)
		_check(world.thermal_at(edge) == 0.0, "Lift never leaks outside its visible radius")
		var last := world.thermal_at(c + Vector3(0, midpoint, 0))
		for step in range(1, 10):
			var value: float = world.thermal_at(c + Vector3(float(thermal["radius"]) * step / 10, midpoint, 0))
			_check(value >= 0 and value <= 10, "Thermal is bounded and positive")
			_check(value <= last + 0.001, "Thermal radial falloff remains smooth and monotonic")
			last = value
	var space := scene.get_world_3d().direct_space_state
	for probe in world.window_probes:
		var gap_ray := PhysicsRayQueryParameters3D.create(probe["outside"], probe["inside"], 1)
		_check(space.intersect_ray(gap_ray).is_empty(), "%s entrance must physically remain open" % probe["name"])
		var wall_ray := PhysicsRayQueryParameters3D.create(probe["wall_outside"], probe["wall_inside"], 1)
		_check(not space.intersect_ray(wall_ray).is_empty(), "%s wall must physically collide" % probe["name"])
		_check(float(probe["clear_width"]) > 1.6 and float(probe["clear_height"]) > 1.6, "Grown birds fit the entrance")
		# A grown bird's sphere must clear the actual collision surface, not just a ray.
		var sphere := SphereShape3D.new()
		sphere.radius = 0.75
		var shape_query := PhysicsShapeQueryParameters3D.new()
		shape_query.shape = sphere
		shape_query.collision_mask = 1
		shape_query.transform = Transform3D(Basis(), (Vector3(probe["inside"]) + Vector3(probe["outside"])) * 0.5)
		_check(space.intersect_shape(shape_query, 1).is_empty(), "%s accepts grown bird collider" % probe["name"])
	for gate in world.route_rings:
		var sphere := SphereShape3D.new()
		sphere.radius = 0.75
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = sphere
		query.collision_mask = 1
		query.transform = Transform3D(Basis(), gate["center"])
		_check(space.intersect_shape(query, 1).is_empty(), "%s gate %d has physical center clearance" % [gate["route"], gate["index"]])
	# Launch platform and the open front must agree with visible geometry.
	_check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(world.spawn_position, world.spawn_position - Vector3(0, 5, 0), 1)).is_empty(), "Launch nest has a solid floor")
	_check(space.intersect_ray(PhysicsRayQueryParameters3D.create(world.spawn_position, world.spawn_position + Vector3(0, 0, -14), 1)).is_empty(), "Launch direction is unobstructed")
	for height in [24.0, 45.0, 80.0]:
		var start := Vector3(0, height, 10)
		_check(space.intersect_ray(PhysicsRayQueryParameters3D.create(start, start + Vector3(0, 0, -50), 1)).is_empty(), "Open valley offers clear flight at %s meters" % height)
	var report := stats.duplicate()
	for verbose_key in ["window_probes", "camera_presets", "route_rings"]:
		report.erase(verbose_key)
	print("WORLD_TESTS: %d checks; %d failures. %s" % [checks, failures.size(), JSON.stringify(report)])
	quit(0 if failures.is_empty() else 1)

func _audit_mesh_node(node: Node) -> void:
	var mesh: Mesh
	if node is MeshInstance3D:
		mesh = node.mesh
	elif node is MultiMeshInstance3D:
		mesh = node.multimesh.mesh
	if mesh != null:
		for surface in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var index_valid := indices.size() > 0 and indices.size() % 3 == 0
			var finite_vertices := true
			var valid_normals := vertices.size() == normals.size()
			var positive_area := true
			var clockwise := true
			for v in vertices:
				finite_vertices = finite_vertices and v.is_finite()
			for n in normals:
				valid_normals = valid_normals and n.is_finite() and n.length_squared() > 0.5 and n.length_squared() < 1.5
			for index in indices:
				index_valid = index_valid and index >= 0 and index < vertices.size()
			if index_valid:
				for i in range(0, indices.size(), 3):
					var a := vertices[indices[i]]
					var b := vertices[indices[i + 1]]
					var c := vertices[indices[i + 2]]
					var cross_product := (b - a).cross(c - a)
					positive_area = positive_area and cross_product.length_squared() > 0.000000000001
					clockwise = clockwise and cross_product.dot(normals[indices[i]]) < 0
			_check(index_valid, "%s has explicit, in-range triangle indices" % node.name)
			_check(finite_vertices, "%s vertices contain no NaN or infinity" % node.name)
			_check(valid_normals, "%s normals are finite and nonzero" % node.name)
			_check(positive_area, "%s excludes collapsed triangles" % node.name)
			_check(clockwise, "%s uses consistent clockwise winding and outward normals" % node.name)
	for child in node.get_children():
		_audit_mesh_node(child)
