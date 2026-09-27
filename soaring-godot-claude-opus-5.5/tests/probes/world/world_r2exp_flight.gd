extends Node3D
## Verifier probe (round 2, experience lens): render budgets along a real
## FLIGHT, not from teleported still views. A camera flies a ~5 km route at
## bird speed (forest canopy, a dive into the old wood, the village street,
## the lake and its arch, the mast, the canyon, 360-degree pans at 60 m over
## the wood and at 280 m over the whole valley, the cliff colony, and back
## into the wood from the west) and every frame's draw calls and primitives
## (visible + shadow) are recorded. Level-of-detail hysteresis depends on
## where the camera came from, so continuous motion is the honest test.
##
##   tools/gd.sh world_verify_r --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_r2exp_flight.tscn -- --mode=perf
##   tools/gd.sh world_verify_r --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_r2exp_flight.tscn -- --mode=shots
##
## Budgets (ARCHITECTURE 7.4): <= 150 draw calls, <= 300k primitives, at
## 1280x720 with a 90-degree vertical FOV (wider than one Quest Pro eye).

var world: SoaringWorld
var cam: Camera3D
var _out := ""


func _ready() -> void:
	_out = Paths.artifacts("world").path_join("verify")
	DirAccess.make_dir_recursive_absolute(_out)
	cam = Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	if not world.is_generated:
		await world.generated
	var args := Paths.user_args()
	if String(args.get("mode", "perf")) == "shots":
		await _shots()
	elif String(args.get("mode", "perf")) == "scan":
		await _scan()
	elif String(args.get("mode", "perf")) == "lod":
		await _lod_compare()
	else:
		await _perf()
	get_tree().quit(0)


func _g(x: float, z: float) -> float:
	return world.ground_height(x, z)


## Route: [position, look-ahead or null]. Heights above ground where noted.
func _route() -> Array:
	var r: Array = []
	var sp := world.get_player_spawn().origin
	r.append(sp + Vector3(0, 0.3, 0))
	r.append(Vector3(-90, _g(-90, 48) + 20, 48))
	r.append(Vector3(-160, 30, -150))
	r.append(Vector3(-230, _g(-230, -230) + 30, -230))
	r.append(Vector3(-262, _g(-262, -258) + 4, -258))
	r.append(Vector3(-300, _g(-300, -300) + 4, -300))
	r.append(Vector3(-262, _g(-262, -258) + 60, -258))
	r.append(["pan", 60.0])
	r.append(Vector3(-150, _g(-150, -120) + 12, -120))
	r.append(Vector3(-60, _g(-60, 40) + 5, 40))
	r.append(Vector3(20, _g(20, 40) + 5, 40))
	r.append(Vector3(110, _g(110, 150) + 8, 150))
	r.append(Vector3(290, 12, 250))
	r.append(Vector3(468, 60, 110))
	r.append(Vector3(335, 40, -140))
	r.append(Vector3(135, 20, -380))
	r.append(Vector3(160, 40, -470))
	r.append(Vector3(0, 280, 0))
	r.append(["pan", 280.0])
	r.append(Vector3(-400, 40, 120))
	r.append(Vector3(-420, _g(-420, -250) + 20, -250))
	r.append(Vector3(-262, _g(-262, -258) + 20, -258))
	r.append(["pan", 20.0])
	return r


func _perf() -> void:
	for i in 8:
		await get_tree().process_frame
	var frames: Array = []
	var step := 2.5
	var prev := Vector3.ZERO
	var have_prev := false
	var vp := get_viewport()
	for wp in _route():
		if wp is Array:
			var c := cam.global_position
			for a in 72:
				var yaw := TAU * a / 72.0
				var fwd := Vector3(cos(yaw), -0.25, sin(yaw)).normalized()
				cam.look_at_from_position(c, c + fwd, Vector3.UP)
				await get_tree().process_frame
				frames.append(_sample(vp, "pan%d" % int(wp[1])))
			continue
		var target: Vector3 = wp
		if not have_prev:
			cam.global_position = target
			prev = target
			have_prev = true
			continue
		var d := prev.distance_to(target)
		var n := maxi(1, int(ceil(d / step)))
		for k in n:
			var p := prev.lerp(target, float(k + 1) / n)
			var ahead := (target - prev).normalized()
			if ahead.length() < 0.5:
				ahead = Vector3.FORWARD
			var look := p + ahead * 10.0 + Vector3(0, -1.5, 0)
			if absf(ahead.dot(Vector3.UP)) > 0.95:
				look = p + Vector3(1, 0, 0)
			cam.look_at_from_position(p, look, Vector3.UP)
			await get_tree().process_frame
			frames.append(_sample(vp, "leg"))
		prev = target
	# The info read after a frame describes that frame; drop warm-up.
	var worst_dc := 0
	var worst_pr := 0
	var worst_dc_at := ""
	var worst_pr_at := ""
	var dcs: Array = []
	var prs: Array = []
	var over := 0
	for f in frames:
		var dc: int = f["dc"] + f["sdc"]
		var pr: int = f["pr"] + f["spr"]
		dcs.append(dc)
		prs.append(pr)
		if dc > 150 or pr > 300000:
			over += 1
		if dc > worst_dc:
			worst_dc = dc
			worst_dc_at = "%s %s" % [f["tag"], f["pos"]]
		if pr > worst_pr:
			worst_pr = pr
			worst_pr_at = "%s %s" % [f["tag"], f["pos"]]
	dcs.sort()
	prs.sort()
	var p99_dc: int = dcs[int(dcs.size() * 0.99)]
	var p99_pr: int = prs[int(prs.size() * 0.99)]
	var res := {"renderer": RenderingServer.get_current_rendering_method(), "frames": frames.size(), "over_budget_frames": over,
		"worst_draw_calls": worst_dc, "worst_draw_calls_at": worst_dc_at, "worst_primitives": worst_pr, "worst_primitives_at": worst_pr_at,
		"p99_draw_calls": p99_dc, "p99_primitives": p99_pr, "median_draw_calls": dcs[dcs.size() / 2], "median_primitives": prs[prs.size() / 2],
		"fov": cam.fov, "far": cam.far, "resolution": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"generation_ms": world.generation_ms}
	print("[world-r2exp] flight perf: ", res)
	var fa := FileAccess.open(_out.path_join("r2exp_flight_perf_%s.json" % res["renderer"]), FileAccess.WRITE)
	res["frames_detail"] = frames
	fa.store_string(JSON.stringify(res, " "))


func _sample(vp: Viewport, tag: String) -> Dictionary:
	return {"tag": tag, "pos": cam.global_position.snapped(Vector3.ONE * 0.1),
		"dc": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"pr": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		"sdc": vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"spr": vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)}


## Experience views the builder did not shoot.
func _shots() -> void:
	var views: Array = []
	# What the player sees when the soft edge / invisible wall turns them back
	# at altitude: 610 m out, 250 m up, looking outward.
	for deg: float in [20.0, 200.0]:
		var d := Vector3(cos(deg_to_rad(deg)), 0, sin(deg_to_rad(deg)))
		views.append(["edge_250m_%d" % int(deg), d * 610.0 + Vector3(0, 250, 0), d * 900.0 + Vector3(0, 240, 0)])
	# Just under the lid.
	views.append(["under_lid", Vector3(-100, 296, 120), Vector3(300, 280, -200)])
	# Across the old wood at 60 m (mid/far tree LODs in view).
	views.append(["wood_60m_grazing", Vector3(-120, _g(-120, -120) + 60, -120), Vector3(-330, _g(-330, -330) + 10, -330)])
	# The swallow colony from 25 m: how the band sits in the cliff.
	var col: Dictionary = {}
	for l in world.get_openings():
		if l["type"] == "cliff_hole":
			col = l
			break
	if not col.is_empty():
		var p: Vector3 = col["position"]
		var n: Vector3 = col["normal"]
		views.append(["colony_25m", p + n * 25.0 + Vector3(0, 4, 8), p])
	# Inside the belfry, looking out through the opposite arch (pigeon eye).
	for l in world.get_openings():
		if l["name"] == "belfry_s":
			var p2: Vector3 = l["position"]
			var n2: Vector3 = l["normal"]
			views.append(["belfry_inside", p2 - n2 * 0.4 + Vector3(0, -0.3, 0), p2 - n2 * 6.0 + Vector3(0, -0.3, 0)])
	# Inside a hedge hollow at wren scale.
	for rf in world.get_refuges():
		if String(rf["name"]).begins_with("hedge"):
			var hp: Vector3 = rf["position"]
			views.append(["hedge_hollow", hp + Vector3(0.05, 0.02, 0.05), hp + Vector3(1.0, 0.0, 0.0)])
			break
	# The lake arch at eagle scale, low over the water.
	views.append(["lake_arch_low", Vector3(270, 4.5, 225), Vector3(306, 6, 262)])
	for v in views:
		cam.global_position = v[1]
		cam.look_at(v[2], Vector3.UP)
		for i in 8:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("r2exp_%s.png" % v[0]))
		print("[world-r2exp] shot ", v[0])


## Head directions a VR player can take anywhere in the old wood: positions
## on a 20 m grid over the core, 4 heights, 12 yaws x 4 pitches; plus the
## worst flight pose re-measured statically (arriving from far and near) to
## see how much level-of-detail history matters.
func _scan() -> void:
	for i in 8:
		await get_tree().process_frame
	var vp := get_viewport()
	var worst_pose := Vector3(-298.8, 10.6, -298.7)
	var worst_look := worst_pose + Vector3(0.44, 0.69, 0.57) * 10.0 + Vector3(0, -1.5, 0)
	var statics := {}
	for arrive in [["from_far", Vector3(400, 200, 400)], ["from_near", worst_pose + Vector3(-12, -5, -12)], ["from_above", worst_pose + Vector3(0, 80, 0)]]:
		cam.look_at_from_position(arrive[1], arrive[1] + Vector3(1, 0, 0), Vector3.UP)
		for i in 6:
			await get_tree().process_frame
		cam.look_at_from_position(worst_pose, worst_look, Vector3.UP)
		for i in 6:
			await get_tree().process_frame
		var smp := _sample(vp, arrive[0])
		statics[arrive[0]] = [smp["dc"] + smp["sdc"], smp["pr"] + smp["spr"], smp["pr"]]
	print("[world-r2exp] worst flight pose re-measured statically [draws, total prims, visible prims]: ", statics)
	var c := Vector2(-262, -258)
	var worst := [0, 0, ""]
	var worst_vis := 0
	var over := 0
	var n := 0
	for gx in range(-2, 3):
		for gz in range(-2, 3):
			var x := c.x + gx * 20.0
			var z := c.y + gz * 20.0
			for h: float in [4.0, 10.0, 18.0, 30.0]:
				var p := Vector3(x, _g(x, z) + h, z)
				for yi in 12:
					var yaw := TAU * yi / 12.0
					for pitch_deg: float in [-20.0, 0.0, 20.0, 40.0]:
						var pt := deg_to_rad(pitch_deg)
						var fwd := Vector3(cos(yaw) * cos(pt), sin(pt), sin(yaw) * cos(pt))
						cam.look_at_from_position(p, p + fwd, Vector3.UP)
						await get_tree().process_frame
						await get_tree().process_frame
						var smp := _sample(vp, "scan")
						var dc: int = smp["dc"] + smp["sdc"]
						var pr: int = smp["pr"] + smp["spr"]
						n += 1
						worst_vis = maxi(worst_vis, smp["pr"])
						if dc > 150 or pr > 300000:
							over += 1
						if pr > worst[1]:
							worst = [dc, pr, "%s yaw %d pitch %d" % [p.snapped(Vector3.ONE * 0.1), int(rad_to_deg(yaw)), int(pitch_deg)]]
	var res := {"views": n, "over_budget": over, "worst_total_prims": worst[1], "worst_draws_there": worst[0], "worst_at": worst[2],
		"worst_visible_prims": worst_vis, "static_worst_pose": statics}
	print("[world-r2exp] old-wood head-direction scan: ", res)
	var fa := FileAccess.open(_out.path_join("r2exp_wood_scan_%s.json" % RenderingServer.get_current_rendering_method()), FileAccess.WRITE)
	fa.store_string(JSON.stringify(res, " "))


## The same forest poses with the level-of-detail system as shipped, and with
## every tree forced to full detail: how much does the wood change as a bird
## flies in (popping), and does it look as dense from afar as it is?
func _lod_compare() -> void:
	var poses := [
		["wood_60m", Vector3(-120, _g(-120, -120) + 60, -120), Vector3(-330, _g(-330, -330) + 10, -330)],
		["wood_edge_25m", Vector3(-160, _g(-160, -150) + 25, -150), Vector3(-300, _g(-300, -300) + 10, -300)],
	]
	for pz in poses:
		cam.global_position = pz[1]
		cam.look_at(pz[2], Vector3.UP)
		for i in 8:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("r2exp_lod_on_%s.png" % pz[0]))
	var changed := 0
	var stack: Array[Node] = [world.get_node("Visual")]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if not n is GeometryInstance3D:
			continue
		var gi := n as GeometryInstance3D
		var nm := String(n.name)
		if not nm.begins_with("trees_") or nm.begins_with("trees_shadow"):
			continue
		if nm.begins_with("trees_lod_") or nm.begins_with("trees_far_"):
			gi.visible = false
		else:
			gi.visibility_range_begin = 0.0
			gi.visibility_range_end = 0.0
		changed += 1
	print("[world-r2exp] forced full detail on %d tree meshes" % changed)
	for pz in poses:
		cam.global_position = pz[1]
		cam.look_at(pz[2], Vector3.UP)
		for i in 8:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), _out.path_join("r2exp_lod_off_%s.png" % pz[0]))
		print("[world-r2exp] lod shots ", pz[0])
