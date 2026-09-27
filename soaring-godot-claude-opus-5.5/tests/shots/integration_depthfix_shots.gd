extends Node
## Evidence (integration hygiene, 2026-09-27): the depth fixes seen close
## up, Forward+ (this Mac's depth buffer is a float one: no fight shows here;
## the shots show the fixed pieces look as they did). The valley alone, a
## camera per view, artifacts/integration/depthfix_<tag>_<view>.png.
##
##   tools/gd.sh ih_shots --rendering-method forward_plus --resolution 1280x720 res://tests/shots/integration_depthfix_shots.tscn -- --tag=after

const VIEWS := {
	# The belfry floor through the south arch (the belt course was a slab
	# whose top lay in that floor).
	"belfry": [Vector3(-96.0, 21.6, 11.5), Vector3(-96.0, 19.6, 4.0)],
	# A closed upper window: the cross bar now in two halves.
	"window": [Vector3(-188.5, 7.0, 16.2), Vector3(-188.5, 6.85, 18.25)],
	# A birch's banded trunk (its hidden piece starts now in the colour of
	# the piece they start in).
	"birch": [Vector3(-129.2, 4.6, -311.2), Vector3(-132.4, 4.3, -311.7)],
	# The street and the square from 30 m up (the paving material).
	"street": [Vector3(-130.0, 32.0, 60.0), Vector3(-110.0, 2.4, 30.0)],
}


func _ready() -> void:
	var world := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(world)
	var t0 := Time.get_ticks_msec()
	while not world.is_generated and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	if Paths.arg("steps", "") != "":
		# Diagnostics: the paving material with another offset (0 = none).
		Palette.paving_material().z_clip_scale = 1.0 - float(Paths.arg("steps", "3")) / 16777216.0
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var tag := Paths.arg("tag", "after")
	for v: String in VIEWS:
		var eye: Vector3 = VIEWS[v][0]
		var at: Vector3 = VIEWS[v][1]
		cam.global_transform = Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)
		# The world swaps terrain and tree levels of detail by distance.
		for i in 20:
			await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), Paths.artifacts("integration").path_join("depthfix_%s_%s.png" % [tag, v]))
	print("[integration] depthfix shots done")
	get_tree().quit()
