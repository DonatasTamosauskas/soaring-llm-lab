extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (ai, round 1) - not part of the area suite.
## A5 cross-check with a stricter monitor than tests/unit/ai/safety_monitor.gd
## (which samples every 6th tick and, for convex shapes, only asks whether
## the body *centre* is inside one). Every tick, for every NPC:
##  * crossing: the segment from last tick's body centre to this tick's hits
##    a non-terrain surface (the body passed into or through a solid - a
##    tunnel through a wire, branch, wall or roof between two samples);
##  * overlap: a sphere of 0.6 x body radius at the body centre touches a
##    non-terrain shape (the same 60% the area's monitor uses for trimeshes),
##    except a bird sitting on / dropping onto its own perch (small birds
##    touch the wire they sit on - expected, reported separately).
## Terrain is the only ConcavePolygonShape3D in AiTestWorld; it is skipped
## (the ground clamp and the "below" check own it).
##
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=safety [--probe_s=180]

var _ray := PhysicsRayQueryParameters3D.new()
var _sq := PhysicsShapeQueryParameters3D.new()
var _sphere := SphereShape3D.new()


static func _shape_of(col: Object, shape_idx: int) -> Shape3D:
	if col == null or not col.has_method(&"shape_find_owner"):
		return null
	var owner_id: int = col.shape_find_owner(shape_idx)
	return col.shape_owner_get_shape(owner_id, 0)


func test_probe_no_tunnelling_or_overlap_every_tick() -> void:
	var sim_s := float(Paths.arg("probe_s", "180"))
	await make_world(false, 1)
	var e := make_eco(60, int(Paths.arg("soak_seed", "7")))
	var chk := make_checker()
	_ray.collision_mask = 1
	_ray.hit_back_faces = true
	_ray.hit_from_inside = true
	_sq.shape = _sphere
	_sq.collision_mask = 1
	var space := world.get_world_3d().direct_space_state
	var prev := {}
	var was_hidden := {}
	var crossing := {}
	var overlap := {}
	var perch_touch := {}
	var examples: Array[String] = []
	var bird_ticks := 0
	for i in int(sim_s / DT):
		e.step(DT)
		chk.step(DT)
		for n: NpcBird in e.get_npcs():
			if not n.alive or not n.is_inside_tree():
				continue
			var id := n.get_instance_id()
			var p := n.global_position
			bird_ticks += 1
			var sit := "%s/%s%s%s" % [n.species, n.state_name(), "/flare" if n.is_flaring() else "", "/perched" if n.perched else ""]
			if prev.has(id) and not n.hidden and not was_hidden.get(id, false):
				var a: Vector3 = prev[id]
				if a.distance_squared_to(p) > 1e-8:
					_ray.from = a
					_ray.to = p
					var hit := space.intersect_ray(_ray)
					if not hit.is_empty() and not (_shape_of(hit["collider"], hit["shape"]) is ConcavePolygonShape3D):
						crossing[sit] = crossing.get(sit, 0) + 1
						if examples.size() < 12:
							examples.append("cross t=%.2f %s from %s to %s hit %s (%s)" % [i * DT, sit, a.snapped(Vector3.ONE * 0.01), p.snapped(Vector3.ONE * 0.01), (hit["position"] as Vector3).snapped(Vector3.ONE * 0.01), _shape_of(hit["collider"], hit["shape"]).get_class()])
			var on_perch := n.perched or (n.state == NpcBird.State.PERCH and n.is_flaring())
			if not n.hidden:
				_sphere.radius = n.get_body_radius() * 0.6
				_sq.transform = Transform3D(Basis.IDENTITY, p)
				for h in space.intersect_shape(_sq, 4):
					if _shape_of(h["collider"], h["shape"]) is ConcavePolygonShape3D:
						continue
					if on_perch:
						perch_touch[sit] = perch_touch.get(sit, 0) + 1
						break
					overlap[sit] = overlap.get(sit, 0) + 1
					if examples.size() < 24:
						examples.append("overlap t=%.2f %s at %s (%s)" % [i * DT, sit, p.snapped(Vector3.ONE * 0.01), _shape_of(h["collider"], h["shape"]).get_class()])
					break
			prev[id] = p
			was_hidden[id] = n.hidden
	var n_cross := 0
	for k in crossing:
		n_cross += crossing[k]
	var n_over := 0
	for k in overlap:
		n_over += overlap[k]
	var report := {"sim_s": sim_s, "bird_ticks": bird_ticks, "crossings": n_cross, "crossing_by_situation": crossing,
		"overlap_ticks": n_over, "overlap_by_situation": overlap, "perch_contact_ticks": perch_touch, "examples": examples, "catches": chk.catches.size()}
	metric("strict_safety", report)
	print("[ai-verify] strict safety: ", JSON.stringify(report, "  "))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("verify/strict_safety_probe.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	eq(n_cross, 0, "no body centre crossed a non-terrain surface between ticks")
	eq(n_over, 0, "no free body (60% radius) overlapped non-terrain geometry on any tick")
	await clear_sim()
