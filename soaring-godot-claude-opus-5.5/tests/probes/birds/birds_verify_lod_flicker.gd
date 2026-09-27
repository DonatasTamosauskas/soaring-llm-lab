extends Node
## Verifier render probe (birds, round 1): does a LOD switch drop a frame?
## BirdBatch.sync_all re-attaches birds that change LOD AFTER all batches
## have uploaded their buffers; add() only writes the CPU buffer, and a
## growing batch re-allocates its GPU data. So in the frame of the switch
## the moved bird (or its whole destination batch) may not be drawn.
## Three cases, each counting the non-background pixels of every frame
## around the switch (a one-frame dip = flicker):
##   A  the destination batch does not exist yet (eagle, alone),
##   B  the destination batch is full and must grow (8 hawks + 1 mover),
##   C  the destination batch has room (3 crows + 1 mover).
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 640x360 \
##       res://tests/probes/birds/birds_verify_lod_flicker.tscn
## Output: artifacts/birds/verify/lod_flicker.json

const Stage := preload("res://tests/shots/birds_stage.gd")

var vp: SubViewport


func _count(img: Image) -> int:
	var n := 0
	# The rendered background (tonemapped), sampled from a corner.
	var bg := img.get_pixel(1, 1)
	for y in range(0, img.get_height(), 1):
		for x in range(0, img.get_width(), 1):
			var c := img.get_pixel(x, y)
			if absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b) > 0.08:
				n += 1
	return n


func _case(sp: StringName, span: float, others: int) -> Dictionary:
	var birds: Array[BirdModel] = []
	# Others: parked at LOD1 distance (36.4 m..) so their batch exists.
	for i in others:
		var o := BirdModels.create(sp)
		o.scale = Vector3.ONE * span
		vp.add_child(o)
		o.position = Vector3(-18.0 + i * 5.0, -6.0, -span / 0.03)
		birds.append(o)
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * span
	vp.add_child(m)
	# Start close (LOD0), then jump just past the LOD0->1 threshold.
	var near_d := span / 0.06
	var far_d := span / 0.04
	m.position = Vector3(0, 3.0, -near_d)
	for b in birds + [m]:
		b.snap()
	for i in 6:
		await RenderingServer.frame_post_draw
	var counts := []
	var lods := []
	for f in 8:
		if f == 3:
			m.position = Vector3(0, 3.0, -far_d)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		counts.append(_count(img))
		lods.append(m.get_lod())
	for b in birds + [m]:
		b.free()
	for i in 3:
		await RenderingServer.frame_post_draw
	# Settled counts after the switch; a dip well below them = flicker.
	var settled: int = counts[counts.size() - 1]
	var dip := 0
	for i in range(3, counts.size() - 1):
		if counts[i] < settled * 0.9:
			dip += 1
	return {"counts": counts, "lods": lods, "dip_frames": dip}


func _ready() -> void:
	vp = Stage.make(self, Vector2i(640, 360), Stage.BG, 0.0, 40.0)
	var cam := Stage.cam(vp)
	cam.position = Vector3.ZERO
	cam.look_at(Vector3(0, 0, -10), Vector3.UP)
	cam.far = 500.0
	for i in 3:
		await RenderingServer.frame_post_draw
	var report := {}
	report["A_new_batch_eagle"] = await _case(&"eagle", 2.1, 0)
	report["B_batch_grows_hawk"] = await _case(&"hawk", 1.6, 8)
	report["C_batch_has_room_crow"] = await _case(&"crow", 0.95, 3)
	var dir := Paths.artifacts("birds").path_join("verify")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("lod_flicker.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	for k in report:
		print("[birds-verify] %s: %s" % [k, str(report[k])])
	get_tree().quit(0)
