extends Node3D
## VERIFIER PROBE (vr, round 2, experience lens): what the comfort vignette
## looks like at the strengths it holds during ordinary flapping flight
## (r2x_flight_vignette_probe_test: sparrow climb mean 0.22 / peak 0.29,
## hover peak 0.26, at the default setting 0.6), next to rest. Same camera
## as the area's own vignette shots (90° vertical FOV, 4:3, ~ Quest Pro).
##   tools/gd.sh vr_verify --rendering-method forward_plus --resolution 1280x960 res://tests/probes/vr/r2x_vignette_levels.tscn
## Writes artifacts/vr/verify/r2x_vignette_<level>.png and a contact sheet.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const LEVELS := [0.0, 0.1, 0.22, 0.29, 0.6]

var rig: Dictionary


func _ready() -> void:
	Env.build_environment(self)
	rig = Env.build_rig(self, Vector3(0, 2.5, 0), MemoryStore.new(), true, false)
	var cam := rig["camera"] as Camera3D
	cam.fov = 90.0
	cam.current = true
	(rig["puppet"] as Node).set("gesture", &"spread")
	_run.call_deferred()


func _run() -> void:
	for i in 30:
		await get_tree().process_frame
	var extras := rig["extras"] as VRRigExtras
	var vig := extras.vignette
	vig.auto_update = false
	var tiles: Array[Image] = []
	var dir := Paths.artifacts("vr/verify")
	var stats := {}
	for s in LEVELS:
		vig.apply_strength(s)
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		var name := "r2x_vignette_%03d" % int(round(s * 100.0))
		img.save_png(dir.path_join(name + ".png"))
		tiles.append(img)
		# Mean luminance of the outer frame (10 % border) and the corners.
		var w := img.get_width()
		var h := img.get_height()
		var edge := 0.0
		var ne := 0
		var corner := 0.0
		var nc := 0
		for y in range(0, h, 8):
			for x in range(0, w, 8):
				var c := img.get_pixel(x, y)
				var lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
				var bx := x < w * 0.1 or x > w * 0.9
				var by := y < h * 0.1 or y > h * 0.9
				if bx or by:
					edge += lum
					ne += 1
				if bx and by:
					corner += lum
					nc += 1
		stats[name] = {"edge_luma": snappedf(edge / ne, 0.001), "corner_luma": snappedf(corner / nc, 0.001)}
		print("[vr-verify] vignette %.2f edge %.3f corner %.3f" % [s, edge / ne, corner / nc])
	# Contact sheet: half-size tiles in a row.
	var tw := tiles[0].get_width() / 2
	var th := tiles[0].get_height() / 2
	var sheet := Image.create(tw * tiles.size(), th, false, Image.FORMAT_RGB8)
	for i in tiles.size():
		var t := tiles[i].duplicate() as Image
		t.resize(tw, th)
		sheet.blit_rect(t, Rect2i(0, 0, tw, th), Vector2i(i * tw, 0))
	sheet.save_png(dir.path_join("r2x_vignette_levels_sheet.png"))
	var f := FileAccess.open(dir.path_join("r2x_vignette_levels.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(stats, "  "))
		f.close()
	print("[vr-verify] vignette levels done")
	get_tree().quit()
