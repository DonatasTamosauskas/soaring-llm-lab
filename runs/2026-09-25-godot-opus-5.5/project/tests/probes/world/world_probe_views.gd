extends Node3D
## Verifier probe (round 1): render budgets from RANDOM viewpoints (not the
## builder's hand-picked 17) and bird's-eye close-ups the builder did not
## shoot. Outputs go to artifacts/world/verify/.
##
##   # budgets on the Quest renderer (counts only; MoltenVK tiles don't matter)
##   tools/gd.sh wv_exp --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_probe_views.tscn -- --mode=perf
##   # screenshots
##   tools/gd.sh wv_exp --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_probe_views.tscn -- --mode=shots

var world: SoaringWorld
var cam: Camera3D
var _out := ""


func _ready() -> void:
	var args := Paths.user_args()
	_out = Paths.artifacts("world").path_join("verify")
	DirAccess.make_dir_recursive_absolute(_out)
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = float(args.get("fov", "90"))
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
	await get_tree().process_frame
	if args.get("mode", "perf") == "perf":
		await _perf(int(args.get("n", "60")))
	else:
		cam.fov = float(args.get("fov", "75"))
		await _shots(String(args.get("only", "")).split(",", false))
	get_tree().quit()


func _perf(n: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var views := []
	for i in n:
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * 620.0
		var x := cos(ang) * rad
		var z := sin(ang) * rad
		var g := world.ground_height(x, z)
		var band := i % 3
		var agl := rng.randf_range(1.0, 10.0) if band == 0 else (rng.randf_range(10.0, 60.0) if band == 1 else rng.randf_range(60.0, 280.0 - maxf(g, 0.0)))
		var y := minf(g + agl, 295.0)
		var yaw := rng.randf() * TAU
		var pitch := deg_to_rad(rng.randf_range(-40.0, 10.0))
		var fwd := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
		views.append(["rand_%02d" % i, Vector3(x, y, z), Vector3(x, y, z) + fwd * 10.0])
	# Adversarial hand-picked worst cases: look across the densest content.
	views.append(["forest_edge_to_village", Vector3(-150, 6, -120), Vector3(-60, 5, 30)])
	views.append(["village_to_forest_low", Vector3(-40, 8, 40), Vector3(-262, 10, -258)])
	views.append(["over_village_down_street", Vector3(0, 40, 30), Vector3(-205, 0, 30)])
	views.append(["inside_forest_to_mast", Vector3(-262, 3, -258), Vector3(468, 40, 110)])
	views.append(["mast_top_to_valley", Vector3(468, 92, 110), Vector3(-100, 0, -50)])
	views.append(["orchard_to_forest", Vector3(-110, 3, 205), Vector3(-262, 5, -258)])
	views.append(["ceiling_down", Vector3(0, 295, 0), Vector3(0.1, 0, 0.0)])
	views.append(["rim_low_inward", Vector3(-600, 40, 0), Vector3(0, 10, 0)])
	var results := {}
	var worst_dc := 0
	var worst_pr := 0
	var worst_dc_name := ""
	var worst_pr_name := ""
	var fails := []
	for v in views:
		cam.global_position = v[1]
		cam.look_at(v[2], Vector3.UP)
		for i in 6:
			await get_tree().process_frame
		var vp := get_viewport()
		var dc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var pr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		var sdc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var spr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		var tdc := dc + sdc
		var tpr := pr + spr
		results[v[0]] = {"pos": [snappedf(v[1].x, 0.1), snappedf(v[1].y, 0.1), snappedf(v[1].z, 0.1)], "draws": dc, "shadow_draws": sdc, "prims": pr, "shadow_prims": spr}
		if tdc > worst_dc:
			worst_dc = tdc
			worst_dc_name = v[0]
		if tpr > worst_pr:
			worst_pr = tpr
			worst_pr_name = v[0]
		if tdc > 150 or tpr > 300000:
			fails.append(v[0])
	var rm := RenderingServer.get_current_rendering_method()
	var fa := FileAccess.open(_out.path_join("perf_random_%s.json" % rm), FileAccess.WRITE)
	fa.store_string(JSON.stringify({"renderer": rm, "fov_vertical": cam.fov, "views": results,
		"worst_draws": [worst_dc_name, worst_dc], "worst_prims": [worst_pr_name, worst_pr], "over_budget": fails}, "  "))
	print("[world-verify] %s: %d views, worst draws %d (%s), worst prims %d (%s), over budget %s" % [
		rm, views.size(), worst_dc, worst_dc_name, worst_pr, worst_pr_name, fails])


func _find_perch(kind: Perch.Kind, district: StringName, nth := 0) -> Perch:
	var c := 0
	for p in world.get_perches():
		if p.kind == kind and (district == &"" or p.district == district):
			if c == nth:
				return p
			c += 1
	return null


func _opening(type: String, nth := 0) -> Dictionary:
	var c := 0
	for o in world.get_openings():
		if o["type"] == type:
			if c == nth:
				return o
			c += 1
	return {}


func _shot_views() -> Array:
	var v := []
	# 1. A sparrow sitting on a power line, looking along the wire.
	var pw := _find_perch(Perch.Kind.WIRE, &"powerline", 5)
	if pw:
		var side := pw.facing.cross(Vector3.UP).normalized()
		v.append(["perch_wire_pov", pw.position + Vector3.UP * 0.08, pw.position + side * 6.0 + Vector3.UP * 0.05])
		v.append(["perch_wire_approach", pw.position + pw.facing * 1.2 + Vector3.UP * 0.25, pw.position])
	# 2. Branch perch in the forest: approach and the view from it.
	var br := _find_perch(Perch.Kind.BRANCH, &"forest", 12)
	if br:
		v.append(["perch_branch_approach", br.position + br.facing * 1.5 + Vector3.UP * 0.4, br.position])
		v.append(["perch_branch_pov", br.position + Vector3.UP * 0.1, br.position + br.facing * 10.0])
	# 3. Roof ridge perch.
	var rf := _find_perch(Perch.Kind.ROOF, &"village", 3)
	if rf:
		v.append(["perch_roof_approach", rf.position + rf.facing * 2.0 + Vector3.UP * 0.6, rf.position])
	# 4. Ledge (window sill / gutter).
	var le := _find_perch(Perch.Kind.LEDGE, &"village", 7)
	if le:
		v.append(["perch_ledge_approach", le.position + le.facing * 0.9 + Vector3.UP * 0.3, le.position])
	# 5. Rock perch on the cliff.
	var rk := _find_perch(Perch.Kind.ROCK, &"cliff", 4)
	if rk:
		v.append(["perch_cliff_rock", rk.position + rk.facing * 3.0 + Vector3.UP * 1.0, rk.position])
	# 6. Nest box at wren scale, 0.45 m out.
	var nb := _opening("nest_box", 3)
	if not nb.is_empty():
		var p: Vector3 = nb["position"]
		var n: Vector3 = nb["normal"]
		v.append(["nestbox_wren_scale", p + n * 0.45 + Vector3.UP * 0.05, p])
	# 7. Cliff hole at swallow scale, 0.8 m and 6 m out.
	var ch := _opening("cliff_hole", 12)
	if not ch.is_empty():
		var p: Vector3 = ch["position"]
		var n: Vector3 = ch["normal"]
		v.append(["cliff_hole_swallow_scale", p + n * 0.8 + Vector3.UP * 0.1, p])
		v.append(["cliff_colony_6m", p + n * 6.0 + Vector3.UP * 0.5, p])
	# 8. Hedge tunnel at 3 m.
	var hg := _opening("hedge_gap", 40)
	if not hg.is_empty():
		var p: Vector3 = hg["position"]
		var n: Vector3 = hg["normal"]
		v.append(["hedge_gap_3m", p + n * 3.0 + Vector3.UP * 0.4, p])
	# 9. Village from 25 m along the street; church from the square.
	v.append(["village_25m", Vector3(20, 25, 42), Vector3(-200, 2, 28)])
	v.append(["church_from_square", Vector3(-80, 4, 40), Vector3(-90, 12, 4)])
	# 10. Forest from above and canopy from below.
	v.append(["forest_above_30m", Vector3(-180, 45, -180), Vector3(-262, 0, -258)])
	v.append(["forest_look_up", Vector3(-262, 2.0, -250), Vector3(-262.5, 30, -254)])
	# 11. The arena edge at altitude: what does the invisible wall look like?
	v.append(["edge_250m_outward", Vector3(-640, 250, -120), Vector3(-900, 230, -170)])
	v.append(["edge_120m_along", Vector3(560, 150, -340), Vector3(350, 150, -560)])
	# 12. Straight down from the ceiling.
	v.append(["ceiling_down", Vector3(-40, 298, 20), Vector3(-40.1, 0, 20.1)])
	# 13. River under the bridge at water level; canyon mouth banks.
	v.append(["river_waterline", Vector3(52, 0.2, -30), Vector3(47, 1.5, 30)])
	v.append(["canyon_mouth_banks", Vector3(115, 6, -280), Vector3(135, 2, -380)])
	# 14. Field edge + hedge + crop at 2 m (z-fighting hotspot).
	v.append(["field_edge_2m", Vector3(-250, 2.0 + world.ground_height(-250, 300), 300), Vector3(-200, world.ground_height(-200, 310), 310)])
	# 15. Barn interior and water tank interior.
	var bd := _opening("barn_door", 0)
	if not bd.is_empty():
		var p: Vector3 = bd["position"]
		var n: Vector3 = bd["normal"]
		v.append(["barn_inside", p - n * 1.0 + Vector3.UP * 0.5, p - n * 12.0 + Vector3.UP * 0.5])
	for rfg in world.get_refuges():
		if String(rfg.get("name", "")).contains("tank"):
			var p: Vector3 = rfg["position"]
			v.append(["tank_inside", p + Vector3(0.3, 0.2, 0.3), p + Vector3(-3, 0, -3)])
			break
	# 16. Belfry from inside looking out.
	var bf := _opening("belfry", 1)
	if not bf.is_empty():
		var p: Vector3 = bf["position"]
		var n: Vector3 = bf["normal"]
		v.append(["belfry_inside_out", p - n * 1.2, p + n * 20.0 - Vector3.UP * 4.0])
	# 17. Dusk street.
	v.append(["dusk_street", Vector3(-212, 3.5, 31), Vector3(-60, 4.5, 29)])
	# 18. Low over the lake toward the sea-stack arch.
	v.append(["lake_low_arch", Vector3(250, 1.5, 250), Vector3(318, 6, 268)])
	# Hover candidates from world_probe_float_test (look along the ground).
	for hc in [["hover_ruin_a", -22.5, -244.5], ["hover_ruin_b", -23.5, -254.5], ["hover_log", -212.0, -122.5],
			["hover_barn_floor", -266.5, 123.0], ["hover_farmhouse", -225.5, 96.5], ["hover_kerb", -145.0, 25.0],
			["hover_foothill_tree", -46.0, 571.0], ["hover_boulder_canyon", 161.5, -262.5], ["hover_barn_door_n", -263.0, 105.0]]:
		var gx: float = hc[1]
		var gz: float = hc[2]
		var g := world.ground_height(gx, gz)
		v.append([hc[0], Vector3(gx + 3.0, g + 0.35, gz + 3.0), Vector3(gx, g + 0.15, gz)])
	return v


func _shots(only: PackedStringArray) -> void:
	for view in _shot_views():
		var nm: String = view[0]
		if not only.is_empty() and not nm in only:
			continue
		world.set_lighting(&"dusk" if nm.begins_with("dusk") else &"day")
		cam.global_position = view[1]
		cam.look_at(view[2], Vector3.UP if absf((view[2] - view[1]).normalized().y) < 0.99 else Vector3.FORWARD)
		for i in 6:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("v_%s.png" % nm))
