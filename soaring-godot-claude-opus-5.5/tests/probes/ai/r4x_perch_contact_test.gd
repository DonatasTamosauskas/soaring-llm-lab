extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, experience lens): do birds perched on branches
## actually sit ON the wood? Close-up renders (verify/r4/eye/perched_branch*)
## showed wrens and a moth "perched" on branches with nothing under their
## feet. In the real valley, round a sparrow-sized mock player (seed 4701,
## the render's run), every bird that settles on a perch is measured:
##  * seat error: body centre vs Habitat.seat(perch) (one radius above the
##    grip point);
##  * support: a physics ray (layers world + perch) straight down from the
##    body centre - how far below the feet (centre - radius) is the first
##    surface; and from the grip point itself (perch.position + 3 cm down to
##    -15 cm): is there any collider right under the grip point.
## Also every BRANCH perch the valley offers, by the grip-point ray alone.
## Report: artifacts/ai/verify/r4/perch_contact.json
##   tools/gd.sh ai_r4exp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_perch_contact

var _w: World = null


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated


func after_all() -> void:
	if is_instance_valid(_w):
		_w.queue_free()
	_w = null
	Habitat.clear_cache()
	await wait_frames(2)


func _down(from: Vector3, length: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * length, 1 | 2)
	var hit := _w.get_world_3d().direct_space_state.intersect_ray(q)
	return -1.0 if hit.is_empty() else from.distance_to(hit["position"])


## Rendered wood under a point: the full-detail tree chunk meshes (world's
## "trees_<chunk>" MeshInstance3D nodes) turned into a trimesh body on a
## private layer (20) once, then a ray straight down on that layer only.
## (The foliage shader's wind sway moves limbs by at most ~2 cm; not modelled.)
var _vis_body: StaticBody3D = null


func _build_visual_wood() -> int:
	_vis_body = StaticBody3D.new()
	_vis_body.collision_layer = 1 << 19
	_vis_body.collision_mask = 0
	add_child(_vis_body)
	# Every rendered mesh of the world that could hold a branch perch: all
	# MeshInstance3D nodes except the trees' mid/far stand-ins and
	# shadow-only casters, whose global AABB contains a branch perch point.
	var pts: Array[Vector3] = []
	for pp in _w.get_perches():
		pts.append(pp.position)
	var faces_total := 0
	var used := 0
	for node in _w.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var nm := String(mi.name)
		if mi.mesh == null or not mi.is_visible_in_tree() or nm.begins_with("trees_lod_") or nm.begins_with("trees_far_") \
				or mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY or mi.has_meta(&"shadow_only"):
			continue
		var box := (mi.global_transform * mi.mesh.get_aabb()).grow(0.2)
		var any := false
		for q in pts:
			if box.has_point(q):
				any = true
				break
		if not any:
			continue
		var faces := mi.mesh.get_faces()
		if faces.is_empty():
			continue
		used += 1
		faces_total += faces.size() / 3
		var shp := ConcavePolygonShape3D.new()
		shp.backface_collision = true
		shp.set_faces(faces)
		var cs := CollisionShape3D.new()
		cs.shape = shp
		_vis_body.add_child(cs)
		cs.global_transform = mi.global_transform
	print("[ai-r4x] visual meshes used: %d" % used)
	return faces_total


func _down_visual(from: Vector3, length: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * length, 1 << 19)
	q.hit_back_faces = true
	var hit := _w.get_world_3d().direct_space_state.intersect_ray(q)
	return -1.0 if hit.is_empty() else from.distance_to(hit["position"])


func test_r4x_perched_birds_touch_their_perch() -> void:
	if _w == null:
		return
	# Every branch perch offered in the valley: a collider right under the grip?
	var kinds := {}
	for p in _w.get_perches():
		var kn := String(Perch.Kind.keys()[p.kind])
		var k: Dictionary = kinds.get(kn, {"n": 0, "unsupported": 0, "examples": []})
		k["n"] += 1
		var d := _down(p.position + Vector3.UP * 0.03, 0.18)
		if d < 0.0:
			k["unsupported"] += 1
			if k["examples"].size() < 5:
				k["examples"].append("%s %s span<=%.2f" % [p.position.snapped(Vector3.ONE * 0.01), p.district, p.max_span])
		kinds[kn] = k
	var tri := _build_visual_wood()
	await wait_physics(2)
	print("[ai-r4x] visual wood: %d triangles" % tri)
	# Offered branch perches: rendered wood right under the grip point?
	var vis_offered := {"n": 0, "wood_within_2cm": 0, "wood_2_to_10cm": 0, "no_wood_within_10cm": 0, "examples": []}
	for pp in _w.get_perches():
		if pp.kind != Perch.Kind.BRANCH:
			continue
		vis_offered["n"] += 1
		var dv := _down_visual(pp.position + Vector3.UP * 0.05, 0.15)
		var gap := dv - 0.05 if dv >= 0.0 else 99.0
		if absf(gap) <= 0.02:
			vis_offered["wood_within_2cm"] += 1
		elif gap <= 0.10:
			vis_offered["wood_2_to_10cm"] += 1
		else:
			vis_offered["no_wood_within_10cm"] += 1
			if vis_offered["examples"].size() < 6:
				vis_offered["examples"].append("%s %s" % [pp.position.snapped(Vector3.ONE * 0.01), pp.district])
	kinds["BRANCH_visual"] = vis_offered
	# Birds that actually perch round a sparrow-sized player.
	var p := MockPlayer.new()
	p.mass = 0.03
	p.speed = minf(SizeRules.cruise_speed(0.03), 14.0)
	var sp0 := _w.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * 90.0, sp0.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = int(Paths.arg("r4_seed", "4701"))
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var seen := {}
	var cap_ratios := []
	var rows := []
	var by_kind := {}
	for i in int(float(Paths.arg("r4_s", "240")) / DT):
		var t := i * DT
		air(_w, t)
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if i % 18 != 0:
			continue
		for n in e.get_npcs():
			if not n.perched or n.perch_spot == null or n.state_time < 0.5:
				continue
			var key := "%d:%d" % [n.get_instance_id(), n.perch_spot.get_instance_id()]
			if seen.has(key):
				continue
			seen[key] = true
			var r := n.get_body_radius()
			var seat := Habitat.seat(n.perch_spot, r)
			var body := n.global_position
			var below := _down(body, r + 0.5)
			var gap := below - r if below >= 0.0 else 99.0
			var grip := _down(n.perch_spot.position + Vector3.UP * 0.03, 0.18)
			var kn := String(Perch.Kind.keys()[n.perch_spot.kind])
			var vgap := 99.0
			var cap_r := -1.0
			var dvv0 := _down_visual(body, r + 0.3)
			var vgap_any := dvv0 - r if dvv0 >= 0.0 else 99.0
			if n.perch_spot.kind == Perch.Kind.BRANCH:
				var dvv := _down_visual(body, r + 0.3)
				vgap = dvv - r if dvv >= 0.0 else 99.0
				var rq := PhysicsRayQueryParameters3D.create(body, body + Vector3.DOWN * (r + 0.2), 1 | 2)
				var hit := _w.get_world_3d().direct_space_state.intersect_ray(rq)
				if not hit.is_empty() and hit["collider"] is CollisionObject3D:
					var co := hit["collider"] as CollisionObject3D
					var shp := co.shape_owner_get_shape(co.shape_find_owner(hit["shape"]), 0)
					if shp is CapsuleShape3D:
						cap_r = (shp as CapsuleShape3D).radius
					elif shp is CylinderShape3D:
						cap_r = (shp as CylinderShape3D).radius
				if cap_r > 0.0 and vgap < 1.0:
					cap_ratios.append(snappedf(vgap / cap_r, 0.01))
			var row := {"visual_feet_gap_m": snappedf(vgap, 0.001), "species": String(n.species), "kind": kn, "seat_err_m": snappedf(body.distance_to(seat), 0.001),
				"feet_gap_m": snappedf(gap, 0.001), "grip_supported": grip >= 0.0, "model_offset_m": snappedf(n.model.global_position.distance_to(body), 0.001) if n.model else -1.0,
				"at": body.snapped(Vector3.ONE * 0.01)}
			rows.append(row)
			var bk: Dictionary = by_kind.get(kn, {"n": 0, "floating_gt_3cm": 0, "grip_unsupported": 0, "seat_err_gt_1cm": 0, "max_gap": 0.0})
			bk["n"] += 1
			if gap > 0.03:
				bk["floating_gt_3cm"] += 1
			if grip < 0.0:
				bk["grip_unsupported"] += 1
			if body.distance_to(seat) > 0.01:
				bk["seat_err_gt_1cm"] += 1
			bk["max_gap"] = maxf(bk["max_gap"], gap)
			bk["visual_gaps_all"] = bk.get("visual_gaps_all", []) + [snappedf(vgap_any, 0.001)]
			if n.perch_spot.kind == Perch.Kind.BRANCH:
				bk["visual_float_gt_2cm"] = int(bk.get("visual_float_gt_2cm", 0)) + (1 if vgap > 0.02 else 0)
				bk["visual_gaps"] = bk.get("visual_gaps", []) + [snappedf(vgap, 0.001)]
			by_kind[kn] = bk
	var out := {"offered_perches": kinds, "perched_birds_by_kind": by_kind, "perched_birds": rows.slice(0, 60)}
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("perch_contact.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("[ai-r4x] perch contact: offered %s" % JSON.stringify(kinds))
	print("[ai-r4x] perch contact: perched %s" % JSON.stringify(by_kind))
	print("[ai-r4x] visual gap / collider radius under branch-perched birds: %s" % str(cap_ratios))
	out["visual_gap_over_collider_radius"] = cap_ratios
	var f2 := FileAccess.open(dir.path_join("perch_contact.json"), FileAccess.WRITE)
	f2.store_string(JSON.stringify(out, "  "))
	f2.close()
	gt(float(vis_offered["wood_within_2cm"]) / maxf(vis_offered["n"], 1), 0.9, "offered BRANCH perches with rendered wood within 2 cm of the grip point %s" % JSON.stringify(vis_offered))
	if by_kind.has("BRANCH"):
		eq(int(by_kind["BRANCH"].get("visual_float_gt_2cm", 0)), 0, "birds perched on branches floating > 2 cm above the rendered wood %s" % str(by_kind["BRANCH"].get("visual_gaps", [])))
	for kn in by_kind:
		var bk: Dictionary = by_kind[kn]
		eq(bk["seat_err_gt_1cm"], 0, "%s: perched bodies at their seat (%d birds)" % [kn, bk["n"]])
		eq(bk["floating_gt_3cm"], 0, "%s: perched bodies with > 3 cm of air under the feet (%d birds, max %.2f m)" % [kn, bk["n"], bk["max_gap"]])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
