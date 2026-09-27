extends Node
## Verifier render probe (birds, round 1): the LOD attach defect made
## visible. Left: a hawk created 3 m from the camera (drawn at LOD0, as it
## should be). Right: the same species, but it was hidden while 300 m away
## (at LOD2) and shown again 3 m away (as pooling / respawning does): it
## keeps the 52-triangle LOD2 mesh (no legs, eyes, fingers) while
## get_lod() says 0.
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 1280x640 \
##       res://tests/probes/birds/birds_verify_lod_shot.tscn
## Output: artifacts/birds/verify/lod_reshow_defect.png

const Stage := preload("res://tests/shots/birds_stage.gd")


func _ready() -> void:
	var vp := Stage.make(self, Vector2i(1280, 640), Stage.BG, 0.0, 40.0)
	var cam := Stage.cam(vp)
	cam.position = Vector3(0, 0.6, 3.2)
	cam.look_at(Vector3(0, 0, 0), Vector3.UP)
	var good := BirdModels.create(&"hawk")
	good.scale = Vector3.ONE * 1.6
	vp.add_child(good)
	good.position = Vector3(-0.95, 0, 0)
	good.rotation.y = deg_to_rad(-60)
	var bad := BirdModels.create(&"hawk")
	bad.scale = Vector3.ONE * 1.6
	vp.add_child(bad)
	# Walk it away through the LODs, hide it far away, bring it back close.
	for d in [4.0, 40.0, 90.0, 200.0, 300.0]:
		bad.position = Vector3(0, 0, -d)
		for i in 3:
			BirdBatch.sync_all(1.0 / 60.0)
	bad.visible = false
	bad.position = Vector3(0.95, 0, 0)
	bad.rotation.y = deg_to_rad(-60)
	bad.visible = true
	for m in [good, bad]:
		m.flap_amount = 0.0
		m.snap()
	for i in 4:
		await get_tree().process_frame
	var img: Image = await Stage.grab(vp)
	var drawn := -1
	for l in BirdModels.LOD_COUNT:
		if bad._batch.mesh == BirdModels.mesh(&"hawk", l):
			drawn = l
	var labels := [
		["created 3 m away: get_lod()=%d, drawn LOD%d" % [good.get_lod(), good.get_lod()], Vector2(40, 20), 22, Color(0.1, 0.1, 0.1)],
		["hidden at 300 m, shown 3 m away: get_lod()=%d, drawn LOD%d" % [bad.get_lod(), drawn], Vector2(660, 20), 22, Color(0.6, 0.05, 0.05)],
	]
	var out: Image = await Stage.annotate(self, img, labels)
	var dir := Paths.artifacts("birds").path_join("verify")
	DirAccess.make_dir_recursive_absolute(dir)
	out.save_png(dir.path_join("lod_reshow_defect.png"))
	print("[birds-verify] lod reshow: reported %d drawn %d" % [bad.get_lod(), drawn])
	get_tree().quit(0)
