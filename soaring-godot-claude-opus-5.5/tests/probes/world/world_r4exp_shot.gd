extends Node3D
## Verifier probe, round 4: close-ups of what the headless z-fight scan
## (world_r4exp_test.gd) flags, to see whether it shows on screen.
##
##   tools/gd.sh world_r4shot --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_r4exp_shot.tscn
##
## Reads artifacts/world/verify/r4exp/zfight_exact_{kits,trees}.json and
## writes artifacts/world/verify/r4exp/r4exp_*.png.

const TOWER := Vector3(-96.0, 19.45, 4.0)

var cam: Camera3D
var out := ""


func _ready() -> void:
	var world: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	out = Paths.artifacts("world").path_join("verify").path_join("r4exp")
	DirAccess.make_dir_recursive_absolute(out)
	# The belfry floor: from inside (a bird that flew in) and from outside
	# through the south arch, at two slightly different eye points (a
	# z-fight pattern changes with the view, a real texture does not).
	await _shot("r4exp_belfry_floor_inside", TOWER + Vector3(1.6, 2.2, 1.6), TOWER + Vector3(-0.6, 0.0, -0.6))
	await _shot("r4exp_belfry_floor_inside_b", TOWER + Vector3(1.62, 2.21, 1.58), TOWER + Vector3(-0.6, 0.0, -0.6))
	await _shot("r4exp_belfry_floor_from_arch", TOWER + Vector3(0.0, 3.2, 5.5), TOWER + Vector3(0.0, 0.0, 0.0))
	await _shot("r4exp_belfry_from_above_far", TOWER + Vector3(0.0, 40.0, 30.0), TOWER + Vector3(0.0, 0.0, 0.0))
	for f in ["zfight_exact_kits.json", "zfight_exact_trees.json"]:
		var txt := FileAccess.get_file_as_string(out.path_join(f))
		var lst: Array = JSON.parse_string(txt) if not txt.is_empty() else []
		lst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["area"]) > float(b["area"]))
		var n := 0
		for e: Dictionary in lst:
			var c := Vector3(e["centre"][0], e["centre"][1], e["centre"][2])
			var nn := Vector3(e["normal"][0], e["normal"][1], e["normal"][2])
			if c.y < 2.0 and nn.y < -0.5:
				continue  # buried footing bottoms
			if absf(c.x - TOWER.x) < 4.0 and absf(c.z - TOWER.z) < 4.0:
				continue  # the belfry floor, shot above
			var side := nn.cross(Vector3.UP)
			if side.length() < 0.1:
				side = Vector3.RIGHT
			side = side.normalized()
			var nm := "r4exp_%s_%d" % [String(e["mesh"]).replace("trees_", "t_"), n]
			await _shot(nm, c + nn * 0.7 + side * 0.25 + Vector3.UP * 0.1, c)
			await _shot(nm + "_mid", c + nn * 4.0 + side * 1.0 + Vector3.UP * 0.5, c)
			n += 1
			if n >= 3:
				break
	get_tree().quit()


func _shot(nm: String, eye: Vector3, at: Vector3) -> void:
	cam.global_position = eye
	cam.look_at(at, Vector3.UP if absf((at - eye).normalized().y) < 0.95 else Vector3.FORWARD)
	for i in 6:
		await get_tree().process_frame
	await Capture.save_viewport(get_viewport(), out.path_join(nm + ".png"))
	print("[world-r4] shot ", nm, " eye ", eye, " at ", at)
