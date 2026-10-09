extends "res://tests/unit/ai/ai_sim.gd"
## COPY of the verifier probe tests/probes/ai/r3x_where_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER DIAGNOSTIC (round 3): what geometry is at the spots where
## r3x_contacts found a wedged hawk and a crow inside a tree.
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_where


func _name(col: Object) -> String:
	if col is Node:
		var nd := col as Node
		var s := String(nd.name)
		var p := nd.get_parent()
		for i in 3:
			if p == null:
				break
			s = String(p.name) + "/" + s
			p = p.get_parent()
		return s
	return str(col)


func test_r3_where() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var sp := rw.get_world_3d().direct_space_state
	for pt in [Vector3(-325.5, 7.6, -274.9), Vector3(78.25, 4.73, 150.86), Vector3(-130.5, 5.5, 52.5), Vector3(-94.5, 20.8, 3.0), Vector3(-163.8, 4.4, 35.5)]:
		var out := {"pt": pt, "ground": rw.ground_height(pt.x, pt.z), "rays": {}}
		for d in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK, Vector3(0.5, 0.9, 0.1).normalized()]:
			var q := PhysicsRayQueryParameters3D.create(pt, pt + d * 30.0, 1)
			var h := sp.intersect_ray(q)
			out["rays"][str(d.snapped(Vector3(0.1, 0.1, 0.1)))] = "-" if h.is_empty() else "%s at %.2f m n=%s" % [_name(h["collider"]), pt.distance_to(h["position"]), str((h["normal"] as Vector3).snapped(Vector3(0.1, 0.1, 0.1)))]
		var pq := PhysicsPointQueryParameters3D.new()
		pq.position = pt
		pq.collision_mask = 1
		out["inside"] = sp.intersect_point(pq, 4).map(func(h: Dictionary) -> String: return _name(h["collider"]))
		var near_lm := []
		for lm in rw.get_landmarks():
			var lp: Vector3 = lm.get("position", Vector3.INF)
			if lp.distance_to(pt) < 25.0:
				near_lm.append("%s %s %.1f m" % [lm.get("kind", "?"), lm.get("name", "?"), lp.distance_to(pt)])
		out["landmarks_within_25m"] = near_lm
		print("[ai-r3x] where %s" % JSON.stringify(out))
	check(true, "done")
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
