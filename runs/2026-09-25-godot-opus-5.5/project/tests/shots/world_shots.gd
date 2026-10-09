extends Node3D
## World screenshots and per-view render stats.
##
##   tools/gd.sh world --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/world_shots.tscn -- [--only=a,b] [--prefix=shot] [--perf]
##
## Writes artifacts/world/<prefix>_<view>.png and, with --perf, measures draw
## calls / primitives per view into artifacts/world/perf_<renderer>.json
## (run it with --rendering-method mobile for the Quest renderer numbers).

var world: SoaringWorld
var cam: Camera3D
var _out := ""


func _ready() -> void:
	var args := Paths.user_args()
	_out = Paths.artifacts("world")
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = float(args.get("fov", "70"))
	cam.near = 0.05
	# Quest rule 7.5: far <= 3000 (the backdrop's far edge is ~2300 m away).
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	get_viewport().msaa_3d = Viewport.MSAA_4X
	await _run(args)
	get_tree().quit()


func _views() -> Array:
	var v := []
	var o := world.get_openings()
	var lm := func(nm: String) -> Dictionary:
		for l in world.get_landmarks():
			if l["name"] == nm:
				return l
		return {}
	var first_opening := func(type: String) -> Dictionary:
		for l in o:
			if l["type"] == type:
				return l
		return {}
	v.append(["overview", Vector3(-430, 210, 470), Vector3(20, 10, -60)])
	v.append(["overview_north", Vector3(380, 190, -470), Vector3(-60, 0, 60)])
	v.append(["village_street", Vector3(-212, 7.5, 31), Vector3(-60, 5.5, 29)])
	var win: Dictionary = first_opening.call("window")
	if not win.is_empty():
		var p: Vector3 = win["position"]
		var n: Vector3 = win["normal"]
		v.append(["through_window", p + n * 2.6 + Vector3(0, 0.25, 0), p - n * 8.0])
	var bel: Dictionary = first_opening.call("belfry")
	if not bel.is_empty():
		var p: Vector3 = bel["position"]
		var n: Vector3 = bel["normal"]
		v.append(["belfry", p + n * 7.0 + Vector3(2.0, -1.5, 0), p - n * 2.0])
	v.append(["power_lines", _wire_view(), _wire_target()])
	v.append(["forest_interior", Vector3(-205, 4.0, -170), Vector3(-280, 7.0, -260)])
	# Inside the old wood at sparrow height, the canopy from above, a ride.
	var fc := WorldLayout.FOREST
	v.append(["forest_core", Vector3(fc.x + 20, world.ground_height(fc.x + 20, fc.y + 30) + 3.5, fc.y + 30), Vector3(fc.x - 30, world.ground_height(fc.x - 30, fc.y - 20) + 6.0, fc.y - 20)])
	v.append(["forest_canopy", Vector3(-180, 45, -180), Vector3(-262, 0, -258)])
	var ride: Array = WorldLayout.FOREST_RIDES[0]
	var r0: Vector2 = ride[0]
	var r2: Vector2 = ride[2]
	v.append(["forest_ride", Vector3(r0.x, world.ground_height(r0.x, r0.y) + 5.0, r0.y), Vector3(r2.x, world.ground_height(r2.x, r2.y) + 5.0, r2.y)])
	var col: Dictionary = first_opening.call("cliff_hole")
	if not col.is_empty():
		var p: Vector3 = col["position"]
		var n: Vector3 = col["normal"]
		v.append(["cliff_colony", p + n * 11.0 + Vector3(0, -2.5, 6), p + Vector3(0, -0.5, -3)])
	else:
		v.append(["cliff_colony", Vector3(-380, 30, 90), Vector3(-455, 30, 90)])
	var th: Array = world.get_thermals()
	if not th.is_empty():
		var tp: Vector3 = th[2]["position"]
		v.append(["thermal", tp + Vector3(110, 40, 90), tp + Vector3(-10, 90, 0)])
	v.append(["lake_bridge", Vector3(20, 14, -35), Vector3(110, 0, 150)])
	var arch: Dictionary = lm.call("canyon_arch")
	var ca := Vector3(162, 60, -455) if arch.is_empty() else (arch["position"] as Vector3)
	v.append(["canyon_arch", Vector3(118, 16, -300), ca])
	v.append(["meadow", Vector3(260, 4.5, -60), Vector3(420, 30, -260)])
	v.append(["orchard_farm", Vector3(-60, 18, 262), Vector3(-230, 8, 140)])
	v.append(["water_tower", Vector3(-160, 22, 205), Vector3(-205, 24, 168)])
	v.append(["mast_lake", Vector3(290, 40, 330), Vector3(470, 60, 110)])
	v.append(["dusk", Vector3(-430, 150, 430), Vector3(20, 10, -60)])
	v.append(["from_edge", Vector3(560, 250, 280), Vector3(-100, 0, -50)])
	# Close-ups for z-fighting / missing faces / floating checks.
	for pair in [["detail_barn", "barn_door_e", 7.0], ["detail_hedge", "hedge_gap", 1.2], ["detail_nestbox", "nest_box", 0.7],
			["detail_cliff_holes", "cliff_hole", 2.2], ["detail_tank_hatch", "tower", 3.0], ["detail_hollow_tree", "tree_hollow", 1.6],
			["detail_bridge_under", "bridge_arch", 9.0]]:
		var op: Dictionary = {}
		for l in world.get_openings():
			if l["name"] == pair[1] or l["type"] == pair[1]:
				op = l
				break
		if op.is_empty():
			continue
		var p: Vector3 = op["position"]
		var n: Vector3 = op["normal"]
		var side := n.cross(Vector3.UP).normalized()
		v.append([pair[0], p + n * float(pair[2]) + side * float(pair[2]) * 0.35 + Vector3(0, float(pair[2]) * 0.15, 0), p - n * 0.5])
	var win2: Dictionary = first_opening.call("window")
	if not win2.is_empty():
		var p: Vector3 = win2["position"]
		var n: Vector3 = win2["normal"]
		# Inside the room, looking out through the back window.
		v.append(["detail_room_inside", p - n * 0.9 + Vector3(0, 0.2, 0), p - n * 12.0])
	# Round-1 verifier close-ups (same cameras): colony readability at 6 m,
	# a nest box at wren scale, inside the tank refuge, a hedge mouth, the
	# canyon mouth's rock, the rubble and a forest log at ground level.
	var nth := func(type: String, k: int) -> Dictionary:
		var i := 0
		for l in o:
			if l["type"] == type:
				if i == k:
					return l
				i += 1
		return {}
	var ch: Dictionary = nth.call("cliff_hole", 12)
	if not ch.is_empty():
		v.append(["detail_cliff_colony_6m", (ch["position"] as Vector3) + (ch["normal"] as Vector3) * 6.0 + Vector3.UP * 0.5, ch["position"]])
		# The round-2 verifier's view (how the band sits in the cliff) and a
		# wider one from 60 m.
		var c0: Dictionary = nth.call("cliff_hole", 0)
		v.append(["cliff_colony_25m", (c0["position"] as Vector3) + (c0["normal"] as Vector3) * 25.0 + Vector3(0, 4, 8), c0["position"]])
		v.append(["cliff_colony_60m", (ch["position"] as Vector3) + (ch["normal"] as Vector3) * 60.0 + Vector3(0, 6, 25), ch["position"]])
		v.append(["detail_cliff_hole_swallow", (ch["position"] as Vector3) + (ch["normal"] as Vector3) * 0.8 + Vector3.UP * 0.1, ch["position"]])
	var nb: Dictionary = nth.call("nest_box", 3)
	if not nb.is_empty():
		v.append(["detail_nestbox_wren", (nb["position"] as Vector3) + (nb["normal"] as Vector3) * 0.45 + Vector3.UP * 0.05, nb["position"]])
	var hg: Dictionary = nth.call("hedge_gap", 40)
	if not hg.is_empty():
		v.append(["detail_hedge_mouth", (hg["position"] as Vector3) + (hg["normal"] as Vector3) * 0.6 + Vector3.UP * 0.05, hg["position"]])
	for rfg in world.get_refuges():
		if String(rfg.get("name", "")).contains("tank"):
			var tp: Vector3 = rfg["position"]
			v.append(["detail_tank_inside", tp + Vector3(0.3, 0.2, 0.3), tp + Vector3(-3, 0, -3)])
			break
	v.append(["detail_canyon_mouth", Vector3(115, 6, -280), Vector3(135, 2, -380)])
	for hc in [["detail_rubble", -22.5, -244.5], ["detail_forest_floor", -250.0, -250.0]]:
		var gx: float = hc[1]
		var gz: float = hc[2]
		var gg := world.ground_height(gx, gz)
		v.append([hc[0], Vector3(gx + 3.0, gg + 0.6, gz + 3.0), Vector3(gx, gg + 0.2, gz)])
	var rg := world.ground_height(WorldLayout.RUIN.x, WorldLayout.RUIN.y)
	v.append(["detail_ruin", Vector3(WorldLayout.RUIN.x + 16, rg + 24, WorldLayout.RUIN.y + 18), Vector3(WorldLayout.RUIN.x, rg + 6, WorldLayout.RUIN.y)])
	v.append(["detail_mast", Vector3(440, 70, 150), Vector3(468, 60, 110)])
	v.append(["detail_orchard_low", Vector3(-120, world.ground_height(-120, 190) + 2.2, 190), Vector3(-95, world.ground_height(-95, 222) + 2.5, 222)])
	# Fix round 3: what the round-3 verifier found floating or inside-out.
	# An eagle shelf side-on (the verifier's shelf at (-454, 45, 48)) and
	# the shelves along the face.
	var shelf: Perch = null
	for pr in world.get_perches():
		if pr.kind == Perch.Kind.LEDGE and pr.district == &"cliff" and (shelf == null or pr.position.distance_to(Vector3(-454, 45, 48.5)) < shelf.position.distance_to(Vector3(-454, 45, 48.5))):
			shelf = pr
	if shelf:
		var f := shelf.facing
		var lat := Vector3.UP.cross(f).normalized()
		v.append(["detail_cliff_shelf", shelf.position + f * 3.5 + lat * 5.0 + Vector3.UP * 1.2, shelf.position - f * 0.6 - Vector3.UP * 0.3])
		v.append(["detail_cliff_shelf_below", shelf.position + f * 4.0 + lat * 2.0 - Vector3.UP * 3.0, shelf.position - f * 0.5])
		v.append(["cliff_shelves", Vector3(-380, 40, 120), Vector3(-455, 28, 150)])
	var mg := world.ground_height(468, 110)
	v.append(["detail_mast_top", Vector3(474, mg + 93.0, 116), Vector3(468, mg + 90.0, 110)])
	var nbt: Dictionary = nth.call("nest_box", 4)
	var nbp: Dictionary = nth.call("nest_box", 13)
	for pair in [["detail_nestbox_side", nbt], ["detail_nestbox_pole", nbp]]:
		var bx: Dictionary = pair[1]
		if bx.is_empty():
			continue
		var out: Vector3 = bx["normal"]
		var orig: Vector3 = (bx["position"] as Vector3) - out * 0.1 - Vector3.UP * 0.04
		var side := Vector3.UP.cross(out).normalized()
		v.append([pair[0], orig + side * 0.95 + out * 0.3 + Vector3.UP * 0.15, orig - out * 0.12])
	# A hedgerow at a bird's height, looking along it (the leafy bulges).
	var hr: Dictionary = nth.call("hedge_gap", 60)
	if not hr.is_empty():
		var hp: Vector3 = hr["position"]
		var hn: Vector3 = hr["normal"]
		var along := hn.cross(Vector3.UP).normalized()
		v.append(["hedgerow_low", hp + hn * 6.0 + along * 7.0 + Vector3.UP * 1.6, hp - along * 9.0])
	var lg := world.ground_height(-160, 25)
	v.append(["detail_lamp_post", Vector3(-156.5, lg + 1.1, 21.5), Vector3(-160, lg + 0.9, 25)])
	var owl: Dictionary = nth.call("owl_hole", 0)
	if not owl.is_empty():
		var p: Vector3 = owl["position"]
		var n: Vector3 = owl["normal"]
		v.append(["detail_barn_owl_hole", p + n * 6.0 + n.cross(Vector3.UP) * 2.5 - Vector3.UP * 1.5, p])
	var vent: Dictionary = nth.call("vent", 2)
	if not vent.is_empty():
		var p: Vector3 = vent["position"]
		var n: Vector3 = vent["normal"]
		v.append(["detail_house_vent", p + n * 3.0 + n.cross(Vector3.UP) * 1.2 + Vector3.UP * 0.3, p])
	return v


## Extra perf-only views: the worst cases the round-1 verifiers found (the
## whole valley from the ring, over the forest canopy, roofs toward the
## wood, along the hedgerows, the mast top) plus 40 seeded random cameras
## anywhere birds can be. Measured with --perf; not screenshotted.
func _perf_views() -> Array:
	var v := []
	for k in 8:
		var a := TAU * k / 8.0
		v.append(["ring_%d" % k, Vector3(cos(a) * 470.0, 200.0, sin(a) * 470.0), Vector3(0, 10, 0)])
	v.append(["center_high_down", Vector3(0, 285, 150), Vector3(-120, 0, -100)])
	v.append(["canopy_to_village", Vector3(-262, 32, -258), Vector3(-100, 8, 30)])
	v.append(["roofs_to_forest", Vector3(-100, 22, 60), Vector3(-262, 10, -258)])
	v.append(["forest_low_toward_edge", Vector3(-262, 6, -200), Vector3(-400, 20, -400)])
	v.append(["inside_forest_to_mast", Vector3(-262, 3, -258), Vector3(468, 40, 110)])
	v.append(["forest_edge_to_village", Vector3(-150, 6, -120), Vector3(-60, 5, 30)])
	v.append(["village_to_forest_low", Vector3(-40, 8, 40), Vector3(-262, 10, -258)])
	v.append(["orchard_to_forest", Vector3(-110, 3, 205), Vector3(-262, 5, -258)])
	v.append(["hedgerows_low", Vector3(-340, 6, 300), Vector3(100, 2, 320)])
	v.append(["square_low", Vector3(-90, 3, 40), Vector3(-200, 4, 30)])
	v.append(["mast_top_west", Vector3(466, 93, 110), Vector3(0, 0, 0)])
	v.append(["lake_to_village", Vector3(230, 25, 230), Vector3(-120, 5, 20)])
	v.append(["forest_canopy_high", Vector3(-262, 60, -120), Vector3(-262, 0, -300)])
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	while v.size() < 21 + 40:
		var p := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 600.0
		var g := world.ground_height(p.x, p.y)
		var y := g + rng.randf_range(2.0, 80.0)
		if y > world.ceiling - 5.0:
			continue
		var d := Vector2.from_angle(rng.randf() * TAU)
		v.append(["rand_%02d" % (v.size() - 21), Vector3(p.x, y, p.y), Vector3(p.x + d.x * 50.0, y + rng.randf_range(-25.0, 10.0), p.y + d.y * 50.0)])
	return v


func _wire_view() -> Vector3:
	for p in world.get_perches():
		if p.kind == Perch.Kind.WIRE and p.district == &"powerline":
			return p.position + Vector3(0.0, 0.35, 0.0) + p.facing * 1.4
	return Vector3(-150, 8, -50)


func _wire_target() -> Vector3:
	var first := Vector3.INF
	for p in world.get_perches():
		if p.kind == Perch.Kind.WIRE and p.district == &"powerline":
			if first == Vector3.INF:
				first = p.position
			elif p.position.distance_to(first) > 60.0:
				return p.position + Vector3(0, -1.5, 0)
	return Vector3(0, 6, -60)


## --breakdown=<view>: primitives of that view with each category of
## visual mesh hidden in turn (what the budget is spent on).
func _breakdown(view: Array) -> void:
	cam.global_position = view[1]
	cam.look_at(view[2], Vector3.UP)
	var cats := {"trees_full": "trees_", "trees_lod": "trees_lod_", "trees_far": "trees_far_", "trees_shadow": "trees_shadow_",
		"terrain": "terrain_", "hedges": "hedges", "village": "village", "backdrop": "backdrop", "water": "water"}
	var vis: Node = world.get_node("Visual")
	var base := await _measure()
	print("[world] breakdown %s: all %s" % [view[0], base])
	for cname in cats:
		var hidden: Array[Node3D] = []
		for n in vis.get_children():
			var nm := String(n.name)
			var hit: bool = nm.begins_with(cats[cname])
			if cname == "trees_full":
				hit = hit and not (nm.begins_with("trees_lod_") or nm.begins_with("trees_far_") or nm.begins_with("trees_shadow_"))
			if hit and (n as Node3D).visible:
				(n as Node3D).visible = false
				hidden.append(n)
		var m := await _measure()
		print("[world]   without %-13s %s  (saves %d + %d shadow)" % [cname, m, base[0] - m[0], base[1] - m[1]])
		for n in hidden:
			n.visible = true
	var soft: Node = world.get_node("Soft")
	soft.visible = false
	var m2 := await _measure()
	print("[world]   without soft          %s  (saves %d)" % [m2, base[0] - m2[0]])
	soft.visible = true


func _measure() -> Array:
	for i in 4:
		await get_tree().process_frame
	var vp := get_viewport()
	return [vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)]


## --lodcompare: the same forest poses with the level-of-detail system as
## built and with every tree forced to full detail (and all terrain fine),
## to show that the stand-ins keep the wood's look (round 2's shrank it).
## Writes shot_lod_on_<pose>.png / shot_lod_off_<pose>.png and prints, per
## pose, the share of pixels that change and the foliage cover of each.
func _lod_compare() -> void:
	var g := func(x: float, z: float) -> float: return world.ground_height(x, z)
	var fc := WorldLayout.FOREST
	var poses := [
		["wood_60m", Vector3(-120, g.call(-120, -120) + 60, -120), Vector3(-330, g.call(-330, -330) + 10, -330)],
		["wood_edge_25m", Vector3(-160, g.call(-160, -150) + 25, -150), Vector3(-300, g.call(-300, -300) + 10, -300)],
		["canopy_skim", Vector3(fc.x - 60, g.call(fc.x - 60, fc.y - 110) + 16, fc.y - 110), Vector3(fc.x, g.call(fc.x, fc.y) + 12, fc.y)],
		["core_far_view", Vector3(fc.x + 30, g.call(fc.x + 30, fc.y + 20) + 6, fc.y + 20), Vector3(fc.x - 120, g.call(fc.x - 120, fc.y - 60) + 8, fc.y - 60)],
	]
	var on := {}
	for pz in poses:
		cam.global_position = pz[1]
		cam.look_at(pz[2], Vector3.UP)
		for i in 10:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("shot_lod_on_%s.png" % pz[0]))
		on[pz[0]] = get_viewport().get_texture().get_image()
	# Everything at full detail: no parents, no ranges, stand-ins hidden,
	# the terrain's far meshes off (and the world's switching paused).
	world.set_process(false)
	for n in world.get_node("Visual").get_children():
		var nm := String(n.name)
		if not n is GeometryInstance3D:
			continue
		var gi := n as GeometryInstance3D
		if nm.begins_with("trees_lod_") or nm.begins_with("trees_far_") or nm.begins_with("terrain_far_"):
			gi.visible = false
		elif nm.begins_with("trees_") and not nm.begins_with("trees_shadow"):
			gi.visibility_parent = NodePath("")
			gi.visibility_range_begin = 0.0
			gi.visibility_range_end = 0.0
		elif nm.begins_with("terrain_"):
			gi.visible = true
	for pz in poses:
		cam.global_position = pz[1]
		cam.look_at(pz[2], Vector3.UP)
		for i in 10:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("shot_lod_off_%s.png" % pz[0]))
		var off := get_viewport().get_texture().get_image()
		var a: Image = on[pz[0]]
		var changed := 0
		var leaf_on := 0
		var leaf_off := 0
		var total := 0
		for y in range(0, a.get_height(), 2):
			for x in range(0, a.get_width(), 2):
				var ca := a.get_pixel(x, y)
				var cb := off.get_pixel(x, y)
				total += 1
				if absf(ca.get_luminance() - cb.get_luminance()) > 0.08:
					changed += 1
				# Foliage: green-dominant pixels.
				if ca.g > ca.r * 1.08 and ca.g > ca.b * 1.15:
					leaf_on += 1
				if cb.g > cb.r * 1.08 and cb.g > cb.b * 1.15:
					leaf_off += 1
		print("[world] lod compare %s: %.1f%% of pixels change; foliage cover %.1f%% with stand-ins vs %.1f%% at full detail (ratio %.2f)" % [
			pz[0], 100.0 * changed / total, 100.0 * leaf_on / total, 100.0 * leaf_off / total, float(leaf_on) / maxf(leaf_off, 1)])


func _run(args: Dictionary) -> void:
	if args.has("lodcompare"):
		for i in 4:
			await get_tree().process_frame
		await _lod_compare()
		return
	if args.has("breakdown"):
		await get_tree().process_frame
		var all := _views()
		all.append_array(_perf_views())
		for bv in String(args["breakdown"]).split(","):
			for view in all:
				if view[0] == bv:
					await _breakdown(view)
		return
	var only: PackedStringArray = String(args.get("only", "")).split(",", false)
	var prefix: String = args.get("prefix", "shot")
	var perf := args.has("perf")
	var results := {}
	await get_tree().process_frame
	var views := _views()
	if perf and args.has("noshots"):
		views.append_array(_perf_views())
	for view in views:
		var nm: String = view[0]
		if not only.is_empty() and not nm in only:
			continue
		world.set_lighting(&"dusk" if nm == "dusk" else &"day")
		cam.global_position = view[1]
		cam.look_at(view[2], Vector3.UP)
		for i in 6:
			await get_tree().process_frame
		if perf:
			var vp := get_viewport()
			var dc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			var pr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
			var sdc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			var spr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
			var obj := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)
			results[nm] = {"draw_calls": dc, "primitives": pr, "shadow_draw_calls": sdc, "shadow_primitives": spr,
				"objects": obj, "total_draw_calls": dc + sdc, "total_primitives": pr + spr,
				"camera": [view[1].x, view[1].y, view[1].z]}
			print("[world] view %-16s draws %4d (+%3d shadow)  prims %7d (+%6d shadow)" % [nm, dc, sdc, pr, spr])
		if not args.has("noshots"):
			await Capture.save_viewport(get_viewport(), _out.path_join("%s_%s.png" % [prefix, nm]))
	if perf:
		var method: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")
		var rm := RenderingServer.get_current_rendering_method()
		var path := _out.path_join("perf_%s.json" % rm)
		var fa := FileAccess.open(path, FileAccess.WRITE)
		var worst := ["", 0, "", 0]
		for k in results:
			if int(results[k]["total_draw_calls"]) > int(worst[1]):
				worst[0] = k
				worst[1] = results[k]["total_draw_calls"]
			if int(results[k]["total_primitives"]) > int(worst[3]):
				worst[2] = k
				worst[3] = results[k]["total_primitives"]
		print("[world] perf worst: %d draw calls (%s), %d primitives (%s) over %d views" % [worst[1], worst[0], worst[3], worst[2], results.size()])
		fa.store_string(JSON.stringify({"renderer": rm, "setting": method, "resolution": [1280, 720],
			"fov": cam.fov, "far": cam.far, "generation_ms": world.generation_ms, "views": results,
			"worst_draw_calls": worst[1], "worst_draw_calls_view": worst[0],
			"worst_primitives": worst[3], "worst_primitives_view": worst[2]}, "  "))
		print("[world] perf -> ", path)
