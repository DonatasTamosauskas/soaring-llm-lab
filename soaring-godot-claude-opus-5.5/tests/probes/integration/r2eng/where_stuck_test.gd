extends TestCase
## PROBE (round-2 engineering verifier): what is at the two places where the
## real-chain progress probe's sparrow sat for a minute at ~1.4 m/s (seed 11):
## landmarks within 12 m and the static geometry around the point (ray casts
## in 8 horizontal directions and up/down).
##   tools/gd.sh v2e_where --headless res://tests/runner.tscn -- --dir=res://tests/probes/integration/r2eng --suite=where_stuck

func test_what_is_there() -> void:
	var w: World = (load("res://scenes/world/world.tscn") as PackedScene).instantiate()
	add_child(w)
	await wait_frames(3)
	var space := w.get_world_3d().direct_space_state
	for p: Vector3 in [Vector3(-88.6, 5.0, -0.8), Vector3(-50.1, 6.5, 41.3), Vector3(-93.1, 2.9, 7.1)]:
		print("[r2eng] where %s: ground %.2f, inside %s, water %s" % [p, w.ground_height(p.x, p.z), w.is_inside(p), w.call(&"is_water", p) if w.has_method(&"is_water") else "?"])
		for l in w.get_landmarks():
			var lp: Vector3 = l.get("position", Vector3.INF)
			if lp.distance_to(p) < 16.0:
				print("[r2eng]   landmark %s (%s) at %s d %.1f r %s" % [l.get("name"), l.get("kind"), lp, lp.distance_to(p), l.get("radius", "")])
		var dirs := [Vector3.UP, Vector3.DOWN]
		for i in 16:
			dirs.append(Vector3.FORWARD.rotated(Vector3.UP, i * PI / 8.0))
		for d: Vector3 in dirs:
			var q := PhysicsRayQueryParameters3D.create(p, p + d * 30.0, 1)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				var col: Object = hit["collider"]
				print("[r2eng]   ray %s hits at %.2f m: %s (%s)" % [d.snapped(Vector3.ONE * 0.01), (hit["position"] as Vector3).distance_to(p),
					col.get_parent().name if col is Node and col.get_parent() else "?", col.name if col is Node else col])
	w.queue_free()
	check(true, "done")
