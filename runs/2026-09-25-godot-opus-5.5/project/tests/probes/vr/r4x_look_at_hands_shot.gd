extends Node3D
## VERIFIER PROBE SHOT (vr, round 4, experience lens): the first thing most
## players do in a new VR game is hold their hands up and look at them.
##   tools/gd.sh vr_verify --rendering-method forward_plus --resolution 800x600 res://tests/probes/vr/r4x_look_at_hands_shot.tscn
## Natural "look at my wings" poses (hands in front of the chest, elbows
## bent, head pitched down towards them) with palms down, palms in and
## wrists turned up, as a sparrow and as a crow, then one arm spread to the
## side and the head turned to look along it. First person, world_scale 1
## (the view is identical at any scale). Writes a contact sheet to
## artifacts/vr/verify/r4/r4x_look_at_hands_sheet.png.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DEG := PI / 180.0


var rig: Dictionary
var puppet: VRPosePuppet
var extras: VRRigExtras
var cam: XRCamera3D


func _ready() -> void:
	Env.build_environment(self)
	rig = Env.build_rig(self, Vector3(0, 2.5, 0), MemoryStore.new(), true, false)
	extras = rig["extras"]
	puppet = rig["puppet"]
	puppet.set_process(false)
	cam = rig["camera"]
	cam.fov = 90.0
	cam.current = true
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		puppet.apply()
		await get_tree().process_frame


func _species(id: StringName) -> void:
	var p := rig["player"] as Bird
	p.mass = float(SizeRules.SPECIES[SizeRules.species_index(id)]["mass"])
	p.species = id


func _run() -> void:
	var h := puppet.human
	h.set_arms(-5.0 * DEG)
	var t := 0.0
	while not extras.calibration.calibrator.calibrated and t < 6.0:
		await _frames(1)
		t += get_process_delta_time()
	extras.world_scale_driver.enabled = false
	(rig["origin"] as XROrigin3D).world_scale = 1.0
	cam.near = WorldScaleDriver.near_for(1.0)
	# [label, species, dihedral, sweep (fwd), twist, elbow, head pitch, head yaw]
	var poses := [
		["sparrow palms down", &"sparrow", -35.0, 55.0, 0.0, 70.0, -35.0, 0.0],
		["sparrow palms in", &"sparrow", -35.0, 55.0, 80.0, 70.0, -35.0, 0.0],
		["sparrow wrists up", &"sparrow", -30.0, 60.0, 40.0, 90.0, -30.0, 0.0],
		["crow palms in", &"crow", -35.0, 55.0, 80.0, 70.0, -35.0, 0.0],
		["sparrow right arm spread, look right", &"sparrow", -10.0, 10.0, 0.0, 10.0, -15.0, -75.0],
		["eagle right arm spread, look right", &"eagle", -10.0, 10.0, 0.0, 10.0, -15.0, -75.0],
	]
	var imgs: Array[Image] = []
	for p: Array in poses:
		_species(p[1])
		h.set_arms(float(p[2]) * DEG, float(p[3]) * DEG, float(p[4]) * DEG, float(p[5]) * DEG)
		# The right-hand twist sign mirrors the left's (palms turn in together).
		h.twist = [float(p[4]) * DEG, -float(p[4]) * DEG]
		h.head_pitch = float(p[6]) * DEG
		h.head_yaw = float(p[7]) * DEG
		puppet.look_yaw = h.head_yaw
		puppet.look_pitch = h.head_pitch
		# Past the 0.8 s tier cross-fade and the extension smoothing.
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1500:
			await _frames(1)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var cal := extras.calibration.calibrator
		print("[vr_verify] %s: ext %.2f / %.2f, species %s" % [p[0], cal.extension[0], cal.extension[1], str((rig["player"] as Bird).species)])
		imgs.append(img)
		img.save_png(Paths.artifacts("vr").path_join("verify/r4/r4x_look_%s.png" % String(p[0]).replace(" ", "_").replace(",", "")))
	var w := imgs[0].get_width()
	var hh := imgs[0].get_height()
	var cols := 3
	var rows := int(ceil(imgs.size() / float(cols)))
	var sheet := Image.create(w * cols + 8 * (cols - 1), hh * rows + 8 * (rows - 1), false, imgs[0].get_format())
	sheet.fill(Color.WHITE)
	for i in imgs.size():
		sheet.blit_rect(imgs[i], Rect2i(0, 0, w, hh), Vector2i((i % cols) * (w + 8), (i / cols) * (hh + 8)))
	sheet.save_png(Paths.artifacts("vr").path_join("verify/r4/r4x_look_at_hands_sheet.png"))
	print("[vr_verify] sheet written")
	get_tree().quit()
