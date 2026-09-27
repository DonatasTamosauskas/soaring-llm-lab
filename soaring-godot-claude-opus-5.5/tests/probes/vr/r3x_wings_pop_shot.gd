extends Node3D
## VERIFIER PROBE SHOT (vr, round 3): the folded-wing pop in first person.
##   tools/gd.sh vr_verify --rendering-method forward_plus --resolution 960x720 res://tests/probes/vr/r3x_wings_pop_shot.tscn
## Relaxed hands (the builder's "held" pose), looking down at the right hand
## (the builder's wings_fp_held_right view), the wrist rolled 33° vs 35°:
## a 2° wrist roll. Writes artifacts/vr/verify/r3/r3x_wings_pop_*.png.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DEG := PI / 180.0


class Ext:
	extends RefCounted
	var ext_l := 0.0
	var ext_r := 0.0
	var stroke_period := 1.0


var rig: Dictionary
var puppet: VRPosePuppet
var extras: VRRigExtras


func _ready() -> void:
	Env.build_environment(self)
	rig = Env.build_rig(self, Vector3(0, 2.5, 0), MemoryStore.new(), true, false)
	extras = rig["extras"]
	puppet = rig["puppet"]
	puppet.set_process(false)
	(rig["camera"] as XRCamera3D).fov = 90.0
	(rig["camera"] as XRCamera3D).current = true
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		puppet.apply()
		await get_tree().process_frame


func _run() -> void:
	puppet.human.set_arms(-5.0 * DEG)
	var t := 0.0
	while not extras.calibration.calibrator.calibrated and t < 6.0:
		await _frames(1)
		t += get_process_delta_time()
	(rig["player"] as Object).set("wing_state_obj", Ext.new())
	(rig["player"] as Bird).mass = float(SizeRules.SPECIES[SizeRules.species_index(&"sparrow")]["mass"])
	(rig["player"] as Bird).species = &"sparrow"
	await get_tree().create_timer(1.0).timeout
	var imgs: Array[Image] = []
	for roll in [33.0, 35.0]:
		puppet.human.set_arms(-68.0 * DEG, 8.0 * DEG, roll * DEG, 95.0 * DEG)
		puppet.look_yaw = -35.0 * DEG
		puppet.look_pitch = -45.0 * DEG
		puppet.human.head_yaw = puppet.look_yaw
		puppet.human.head_pitch = puppet.look_pitch
		await _frames(20)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := Paths.artifacts("vr").path_join("verify/r3/r3x_wings_pop_roll%02d.png" % int(roll))
		img.save_png(path)
		imgs.append(img)
		print("[vr-verify] shot ", path, " primary normal ", extras.wings.feather_transform(FirstPersonWings.PER_WING).basis.y.normalized())
	var w := imgs[0].get_width()
	var h := imgs[0].get_height()
	var sheet := Image.create(w * 2 + 8, h, false, imgs[0].get_format())
	sheet.fill(Color.WHITE)
	sheet.blit_rect(imgs[0], Rect2i(0, 0, w, h), Vector2i(0, 0))
	sheet.blit_rect(imgs[1], Rect2i(0, 0, w, h), Vector2i(w + 8, 0))
	sheet.save_png(Paths.artifacts("vr").path_join("verify/r3/r3x_wings_pop_sheet.png"))
	get_tree().quit()
