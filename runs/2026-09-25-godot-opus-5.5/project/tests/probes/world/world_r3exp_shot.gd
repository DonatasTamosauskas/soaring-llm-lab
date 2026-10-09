extends Node3D
## Verifier probe, round 3: close-ups of things the headless probe flags
## (cliff shelves that do not touch the face, the nest box at (-20, -60)).
##
##   tools/gd.sh world_verify --rendering-method forward_plus --resolution 1280x720 res://tests/probes/world/world_r3exp_shot.tscn
##
## Writes artifacts/world/verify/r3/*.png.

const SHOTS := [
	# name, camera, look-at
	["r3exp_shelf_222_player_above", Vector3(-454.64, 29.30, 225.86), Vector3(-461.40, 25.80, 222.30)],
	["r3exp_shelf_222_player_below", Vector3(-457.56, 22.80, 224.62), Vector3(-461.40, 25.80, 222.30)],
	["r3exp_shelf_222_profile", Vector3(-461.36, 26.20, 229.35), Vector3(-462.00, 25.80, 222.25)],
	["r3exp_shelf_048_player_above", Vector3(-447.80, 48.40, 52.24), Vector3(-454.40, 44.90, 48.50)],
	["r3exp_shelf_048_player_below", Vector3(-450.66, 41.90, 50.92), Vector3(-454.40, 44.90, 48.50)],
	["r3exp_shelf_048_profile", Vector3(-454.58, 45.30, 55.50), Vector3(-454.99, 44.90, 48.43)],
	["r3exp_nestbox_13", Vector3(-17.0, 8.6, -55.5), Vector3(-20.0, 7.6, -59.8)],
	["r3exp_mast_top", Vector3(474.0, 103.0, 116.0), Vector3(468.0, 103.0, 110.0)],
	["r3exp_mast_top_far", Vector3(486.0, 100.0, 128.0), Vector3(468.0, 102.5, 110.0)],
	["r3exp_lamp_post_street_end", Vector3(-158.8, 2.55, 23.8), Vector3(-160.0, 2.3, 25.0)],
]


func _ready() -> void:
	var world: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	var cam := Camera3D.new()
	cam.fov = 70.0
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var out := Paths.artifacts("world").path_join("verify").path_join("r3")
	DirAccess.make_dir_recursive_absolute(out)
	# Side views of nest boxes (their back board against the trunk).
	for o in world.get_openings():
		if o["name"] in ["nest_box_4", "nest_box_6", "nest_box_0"]:
			var n: Vector3 = o["normal"]
			var c: Vector3 = o["position"]
			var right := Vector3.UP.cross(n).normalized()
			cam.global_position = c + right * 0.7 + n * 0.05 + Vector3.UP * 0.1
			cam.look_at(c - n * 0.2, Vector3.UP)
			for i in 6:
				await get_tree().process_frame
			await Capture.save_viewport(get_viewport(), out.path_join("r3exp_%s_side.png" % o["name"]))
			print("[world-r3] shot ", o["name"])
	for s in SHOTS:
		cam.global_position = s[1]
		cam.look_at(s[2], Vector3.UP)
		for i in 6:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), out.path_join(String(s[0]) + ".png"))
		print("[world-r3] shot ", s[0])
	get_tree().quit()
