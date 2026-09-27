extends Node3D
## Verifier probe, round 3: the builder's old-wood scan (tests/shots/
## world_perf.gd _scan: 25 positions x 4 heights x 12 yaws x 4 pitches,
## 2 frames each, in sequence) replayed on the FINAL code, because
## scripts/world/terrain.gd changed (02:04:58) after perf_budget_mobile.json
## was written (01:59:26). Same protocol: Mobile, 1280x720, 90 deg FOV,
## near 0.05, far 3000, MSAA 4x, visible + shadow pass.
##
##   tools/gd.sh world_verify2 --rendering-method mobile --resolution 1280x720 \
##       res://tests/probes/world/world_verify3_scan.tscn
##
## Writes artifacts/world/verify/r3/perf_scan_replay_mobile.json.

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
	var res := {"views": 0, "worst_draw_calls": 0, "worst_primitives": 0, "worst_at": "", "over_budget": 0}
	var prims: Array = []
	var c := WorldLayout.FOREST
	for gx in range(-2, 3):
		for gz in range(-2, 3):
			var x := c.x + gx * 20.0
			var z := c.y + gz * 20.0
			for h: float in [4.0, 10.0, 18.0, 30.0]:
				var p := Vector3(x, world.ground_height(x, z) + h, z)
				for yi in 12:
					var yaw := TAU * yi / 12.0
					for pitch_deg: float in [-20.0, 0.0, 20.0, 40.0]:
						var pt := deg_to_rad(pitch_deg)
						cam.look_at_from_position(p, p + Vector3(cos(yaw) * cos(pt), sin(pt), sin(yaw) * cos(pt)), Vector3.UP)
						await get_tree().process_frame
						await get_tree().process_frame
						var dc := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) \
							+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
						var pr := _vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME) \
							+ _vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
						res["views"] = int(res["views"]) + 1
						prims.append(pr)
						res["worst_draw_calls"] = maxi(int(res["worst_draw_calls"]), dc)
						if pr > int(res["worst_primitives"]):
							res["worst_primitives"] = pr
							res["worst_at"] = "%s yaw %d pitch %d" % [p.snapped(Vector3.ONE * 0.1), int(rad_to_deg(yaw)), int(pitch_deg)]
						if dc > 150 or pr > 300000:
							res["over_budget"] = int(res["over_budget"]) + 1
	prims.sort()
	res["p50_primitives"] = prims[prims.size() / 2]
	res["p99_primitives"] = prims[int(prims.size() * 0.99)]
	print("[world-verify3] scan replay: %d views, worst %d prims at %s, %d draws, p99 %d, over budget %d" % [
		res["views"], res["worst_primitives"], res["worst_at"], res["worst_draw_calls"], res["p99_primitives"], res["over_budget"]])
	var dir := Paths.artifacts("world").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var fa := FileAccess.open(dir.path_join("perf_scan_replay_mobile.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(res, "  "))
	get_tree().quit()
