extends Node3D
## Verifier (round 1, engineering lens): independent render-budget check for
## the world area on the Quest renderer. Measures the builder's views plus
## extra worst cases (8 bearings from 200 m, over the forest canopy toward the
## village, village roofs toward the forest, along the hedgerows, mast top),
## 1280x720, 90 deg FOV, far 3000 m (ARCHITECTURE 7.5), shadow pass included.
##
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_verify_perf.tscn
##
## Writes artifacts/world/verify/perf_<renderer>_verify.json.

var world: SoaringWorld
var cam: Camera3D


func _ready() -> void:
	var t0 := Time.get_ticks_usec()
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	var gen_ms := (Time.get_ticks_usec() - t0) / 1000.0
	cam = Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
	await get_tree().process_frame
	var views := _views()
	var results := {}
	var worst_dc := 0
	var worst_pr := 0
	for v in views:
		cam.global_position = v[1]
		cam.look_at(v[2], Vector3.UP)
		for i in 5:
			await get_tree().process_frame
		var vp := get_viewport()
		var dc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var pr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		var sdc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var spr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		results[v[0]] = {"draw_calls": dc + sdc, "primitives": pr + spr, "shadow_draw_calls": sdc, "shadow_primitives": spr,
			"camera": [v[1].x, v[1].y, v[1].z]}
		worst_dc = maxi(worst_dc, dc + sdc)
		worst_pr = maxi(worst_pr, pr + spr)
		print("[world-verify] perf %-22s draws %4d (shadow %3d)  prims %7d (shadow %6d)" % [v[0], dc + sdc, sdc, pr + spr, spr])
	var rm := RenderingServer.get_current_rendering_method()
	var out := Paths.artifacts("world").path_join("verify")
	DirAccess.make_dir_recursive_absolute(out)
	var fa := FileAccess.open(out.path_join("perf_%s_verify.json" % rm), FileAccess.WRITE)
	fa.store_string(JSON.stringify({"renderer": rm, "resolution": [get_viewport().size.x, get_viewport().size.y], "fov": 90.0,
		"generation_ms_render_run": gen_ms, "worst_draw_calls": worst_dc, "worst_primitives": worst_pr, "views": results}, "  "))
	print("[world-verify] perf %s: %d views, worst %d draws, %d prims, generation %.0f ms (render run)" % [rm, views.size(), worst_dc, worst_pr, gen_ms])
	get_tree().quit()


func _views() -> Array:
	var v := []
	# The builder's main views (same cameras as tests/shots/world_shots.gd).
	v.append(["overview", Vector3(-430, 210, 470), Vector3(20, 10, -60)])
	v.append(["overview_north", Vector3(380, 190, -470), Vector3(-60, 0, 60)])
	v.append(["from_edge", Vector3(560, 250, 280), Vector3(-100, 0, -50)])
	v.append(["village_street", Vector3(-212, 7.5, 31), Vector3(-60, 5.5, 29)])
	v.append(["forest_interior", Vector3(-205, 4.0, -170), Vector3(-280, 7.0, -260)])
	v.append(["orchard_farm", Vector3(-60, 18, 262), Vector3(-230, 8, 140)])
	v.append(["water_tower", Vector3(-160, 22, 205), Vector3(-205, 24, 168)])
	# Extra worst cases.
	for k in 8:
		var a := TAU * k / 8.0
		v.append(["ring_%d" % k, Vector3(cos(a) * 470.0, 200.0, sin(a) * 470.0), Vector3(0, 10, 0)])
	v.append(["center_high_down", Vector3(0, 285, 150), Vector3(-120, 0, -100)])
	v.append(["canopy_to_village", Vector3(-262, 32, -258), Vector3(-100, 8, 30)])
	v.append(["roofs_to_forest", Vector3(-100, 22, 60), Vector3(-262, 10, -258)])
	v.append(["forest_low_toward_edge", Vector3(-262, 6, -200), Vector3(-400, 20, -400)])
	v.append(["hedgerows_low", Vector3(-340, 6, 300), Vector3(100, 2, 320)])
	v.append(["square_low", Vector3(-90, 3, 40), Vector3(-200, 4, 30)])
	v.append(["mast_top_west", Vector3(466, 93, 110), Vector3(0, 0, 0)])
	v.append(["lake_to_village", Vector3(230, 25, 230), Vector3(-120, 5, 20)])
	return v
