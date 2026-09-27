extends Node3D
## Round-4 engineering verifier: an independent W7 search with view classes
## the builder's random/forest sets sample thinly: near-ceiling looks down
## over the whole valley, rim-inward looks, village-to-forest looks and the
## spawn. Same protocol as world_perf (Mobile, 1280x720, 90 deg FOV, far
## 3000, MSAA 4x, visible + shadow, measured cold and warm).
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 res://tests/probes/world/world_r4eng_perf.tscn

var world: SoaringWorld
var cam: Camera3D
var _vp: Viewport


func _ready() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	_vp = get_viewport()
	_vp.msaa_3d = Viewport.MSAA_4X
	if not world.is_generated:
		await world.generated
	for i in 6:
		await get_tree().process_frame
	var views: Array = []
	var fc := WorldLayout.FOREST
	var vc := WorldLayout.VILLAGE
	# Near-ceiling looks over the whole valley, 16 bearings, 2 pitches.
	for k in 16:
		var a := TAU * k / 16.0
		var p := Vector3(cos(a) * 520.0, 290.0, sin(a) * 520.0)
		views.append(["ceiling_%02d_centre" % k, p, Vector3(0, 0, 0)])
		views.append(["ceiling_%02d_forest" % k, p, Vector3(fc.x, 0, fc.y)])
	# Above the forest at the ceiling, looking steeply down and across.
	for k in 8:
		var a := TAU * k / 8.0
		var p := Vector3(fc.x + cos(a) * 120.0, 280.0, fc.y + sin(a) * 120.0)
		views.append(["ceiling_over_wood_%d" % k, p, Vector3(fc.x - cos(a) * 60.0, 0, fc.y - sin(a) * 60.0)])
	# The rim inward at mid height.
	for k in 12:
		var a := TAU * k / 12.0
		var r := 600.0
		var g := world.ground_height(cos(a) * r, sin(a) * r)
		var p := Vector3(cos(a) * r, minf(g + 40.0, 290.0), sin(a) * r)
		views.append(["rim_%02d" % k, p, Vector3(fc.x, 20, fc.y)])
	# Village street and church looking at the forest; the forest edge looking at the village.
	for k in 8:
		var off := Vector2.from_angle(TAU * k / 8.0) * 40.0
		var g := world.ground_height(vc.x + off.x, vc.y + off.y)
		views.append(["village_%d" % k, Vector3(vc.x + off.x, g + 8.0, vc.y + off.y), Vector3(fc.x, 15, fc.y)])
		var d := (vc - fc).normalized()
		var e := fc + d * (WorldLayout.FOREST_R - 10.0) + Vector2(-d.y, d.x) * (float(k) - 3.5) * 12.0
		views.append(["wood_edge_to_village_%d" % k, Vector3(e.x, world.ground_height(e.x, e.y) + 12.0, e.y), Vector3(vc.x, 5, vc.y)])
	var sp := world.get_player_spawn()
	views.append(["spawn", sp.origin + Vector3.UP * 0.3, sp.origin - sp.basis.z * 30.0])
	views.append(["spawn_to_wood", sp.origin + Vector3.UP * 0.3, Vector3(fc.x, 10, fc.y)])
	var worst_dc := 0
	var worst_pr := 0
	var worst_at := ""
	var worst_dc_at := ""
	var over := 0
	var over_target := 0
	var rows := {}
	for v in views:
		for phase in 2:
			if phase == 0:
				_place(Vector3(560, 250, 560), Vector3.ZERO)
				await _frames(3)
			else:
				for k in 8:
					var a := TAU * k / 8.0
					_place((v[1] as Vector3) + Vector3(cos(a) * 25.0, 0.0, sin(a) * 25.0), v[2])
					await _frames(2)
			_place(v[1], v[2])
			await _frames(5)
			var dc := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) \
				+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			var pr := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME) \
				+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
			rows["%s_%s" % [v[0], "cold" if phase == 0 else "warm"]] = [dc, pr]
			if pr > worst_pr:
				worst_pr = pr
				worst_at = "%s %s" % [v[0], "cold" if phase == 0 else "warm"]
			if dc > worst_dc:
				worst_dc = dc
				worst_dc_at = "%s %s" % [v[0], "cold" if phase == 0 else "warm"]
			if dc > 150 or pr > 300000:
				over += 1
			if pr > 270000:
				over_target += 1
	var out := {"renderer": RenderingServer.get_current_rendering_method(), "views": views.size(), "worst_draw_calls": worst_dc,
		"worst_draw_calls_at": worst_dc_at, "worst_primitives": worst_pr, "worst_at": worst_at, "over_budget": over,
		"over_target": over_target, "rows": rows}
	var path := Paths.artifacts("world").path_join("verify/r4eng/perf_r4eng_%s.json" % out["renderer"])
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(out, "  "))
	print("[world-r4eng] perf %d views x cold/warm: worst %d draws (%s), %d prims (%s); over budget %d, over 270k %d" % [
		views.size(), worst_dc, worst_dc_at, worst_pr, worst_at, over, over_target])
	get_tree().quit(0 if over == 0 else 1)


func _place(pos: Vector3, look: Vector3) -> void:
	if (look - pos).normalized().abs().y > 0.98:
		look += Vector3(0.3, 0.0, 0.0)
	cam.look_at_from_position(pos, look, Vector3.UP)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
