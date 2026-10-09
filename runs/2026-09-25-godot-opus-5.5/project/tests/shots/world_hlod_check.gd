extends Node3D
## Checks the engine behaviour the tree levels of detail rely on
## (GeometryInstance3D.visibility_parent, "HLOD"): a far mesh (range begin
## 100 m), its child mid mesh (begin 50 m) and the mid's child full mesh
## (no range). Walking the camera out and back, exactly one of them must be
## drawn at a time: full within 50 m, mid from 50 to 100 m, far beyond.
## Each mesh has its own triangle count (full 2000, mid 20, far 200), so the
## frame's primitive count says which one is drawn; any other count fails
## the run (exit code 1).
##
##   tools/gd.sh world --rendering-method mobile --resolution 320x240 res://tests/shots/world_hlod_check.tscn

var cam: Camera3D


func _mk(nm: String, pos: Vector3, segs: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	var bm := CylinderMesh.new()
	bm.radial_segments = segs
	bm.rings = 0
	bm.cap_top = false
	bm.cap_bottom = false
	mi.mesh = bm
	mi.position = pos
	add_child(mi)
	return mi


func _ready() -> void:
	cam = Camera3D.new()
	add_child(cam)
	cam.current = true
	var far := _mk("far", Vector3(0, 0, 0), 100)
	far.visibility_range_begin = 100.0
	var mid := _mk("mid", Vector3(20, 0, 0), 10)
	mid.visibility_range_begin = 50.0
	var full := _mk("full", Vector3(20, 0, 0), 1000)
	await get_tree().process_frame
	mid.visibility_parent = mid.get_path_to(far)
	full.visibility_parent = full.get_path_to(mid)
	var fails := 0
	for d in [10.0, 40.0, 60.0, 90.0, 110.0, 150.0, 110.0, 90.0, 60.0, 40.0, 10.0]:
		cam.position = Vector3(20, 0, d)
		cam.look_at(Vector3(10, 0, 0))
		for i in 3:
			await get_tree().process_frame
		var objs := get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)
		var pr := get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
		# Exactly one level: full inside the mid's begin (50 m from the chunk),
		# the far one once the camera is beyond 100 m of the group, mid between.
		var want := 2000 if d < 50.0 else (200 if Vector3(20, 0, d).length() > 100.0 else 20)
		var ok := objs == 1 and pr == want
		if not ok:
			fails += 1
		print("[world] hlod cam d=%.0f (far group %.0f, chunk %.0f): objects %d prims %d, want 1 object of %d: %s" % [
			d, Vector3(20, 0, d).length(), d, objs, pr, want, "ok" if ok else "FAIL"])
	print("[world] hlod check: %s" % ("PASS" if fails == 0 else "FAIL (%d distances)" % fails))
	get_tree().quit(1 if fails > 0 else 0)
