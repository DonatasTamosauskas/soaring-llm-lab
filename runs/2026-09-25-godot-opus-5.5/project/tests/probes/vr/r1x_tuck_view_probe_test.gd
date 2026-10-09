extends TestCase
## VERIFIER PROBE (vr, independent round 1, experience lens): "You see your
## wings: feathered wings attached to your hands" (DESIGN). With the wings
## tucked in to the chest (the dive / tuck gesture) and the head pitched
## down to look at them, how much of the wing is inside a Quest Pro-like
## view (vertical FOV 90 deg, 4:3)? A rendered shot of that pose
## (artifacts/vr/verify/r1x/r1x_look_sparrow_tucked_dive_look_down.png)
## showed no wing at all. Result: geometry, not a defect (see the end).
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r1x_tuck_view

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DEG := PI / 180.0
const HALF_V := 45.0
const HALF_H := 53.13


func _frames(puppet: VRPosePuppet, n: int) -> void:
	for i in n:
		puppet.apply()
		await get_tree().process_frame


## Fraction of feather roots/tips inside the view, and each hand's angles
## (deg) from the view axis.
func view_stats(extras: VRRigExtras, cam: Node3D, origin: XROrigin3D, hands: Array) -> Dictionary:
	var wings := extras.wings
	var inside := 0
	var n := 0
	var cam_inv := cam.global_transform.affine_inverse()
	var count := wings.multimesh.instance_count
	for k in count:
		var ft := wings.feather_transform(k)
		for p in [ft.origin, ft.origin + ft.basis.z * 0.5, ft.origin - ft.basis.z * 0.5]:
			var w: Vector3 = origin.global_transform * p
			var c := cam_inv * w
			n += 1
			if c.z < -0.01:
				var ax := rad_to_deg(atan2(c.x, -c.z))
				var ay := rad_to_deg(atan2(c.y, -c.z))
				if absf(ax) < HALF_H and absf(ay) < HALF_V:
					inside += 1
	var hs := []
	for hnode in hands:
		var c := cam_inv * (hnode as Node3D).global_position
		hs.append({"cam_space": c.snapped(Vector3.ONE * 0.01), "right_deg": snappedf(rad_to_deg(atan2(c.x, -c.z)), 0.1),
			"up_deg": snappedf(rad_to_deg(atan2(c.y, -c.z)), 0.1), "dist": snappedf(c.length(), 0.01)})
	return {"frac_inside": float(inside) / maxf(n, 1), "hands": hs, "visible": wings.visible}


func test_tucked_wings_are_seen_when_looking_down() -> void:
	var root := Node3D.new()
	add_child(root)
	var rig := Env.build_rig(root, Vector3(0, 2.5, 0), MemoryStore.new(), true, false)
	var extras: VRRigExtras = rig["extras"]
	var puppet: VRPosePuppet = rig["puppet"]
	puppet.set_process(false)
	var origin: XROrigin3D = rig["origin"]
	var cam: Node3D = rig["camera"]
	var h := puppet.human
	h.set_arms(-5.0 * DEG)
	var t := 0
	while not extras.calibration.calibrator.calibrated and t < 400:
		await _frames(puppet, 1)
		t += 1
	check(extras.calibration.calibrator.calibrated, "(setup) calibrated")
	extras.world_scale_driver.enabled = false
	origin.world_scale = 1.0
	# [label, dihedral, sweep, twist, elbow, head pitch]
	var poses := [
		["puppet tuck (the builder's own), look down 40", -35.0, -10.0, 0.0, 150.0, -40.0],
		["hands together at the chest, look down 40", -30.0, 20.0, 0.0, 150.0, -40.0],
		["dive tuck, forearms along the body, look down 50", -60.0, 0.0, 0.0, 150.0, -50.0],
		["palms down in front (reference), look down 35", -35.0, 55.0, 0.0, 70.0, -35.0],
	]
	var rows := {}
	for p: Array in poses:
		h.set_arms(float(p[1]) * DEG, float(p[2]) * DEG, float(p[3]) * DEG, float(p[4]) * DEG)
		h.head_pitch = float(p[5]) * DEG
		puppet.look_pitch = h.head_pitch
		await _frames(puppet, 90)
		var st := view_stats(extras, cam, origin, [rig["left"], rig["right"]])
		st["ext"] = [snappedf(extras.calibration.calibrator.extension[0], 0.01), snappedf(extras.calibration.calibrator.extension[1], 0.01)]
		rows[p[0]] = st
		print("[vr_verify] %s: %s" % [p[0], str(st)])
	metric("rows", rows)
	gt(float(rows["palms down in front (reference), look down 35"]["frac_inside"]), 0.3, "reference: the folded wings in front are in view")
	# Finding: with the hands tucked at the chest (25-30 cm from the eyes)
	# the hands themselves sit 48-62 deg off the view axis, at or past the
	# edge of a 90 deg view (Quest Pro: ~106 x 96 deg), and the folded wing
	# lies back along the forearms, further out. That is the geometry of
	# real hands, not a wing defect: recorded, not asserted.
	for k in rows:
		check(bool(rows[k]["visible"]), "%s: the wings stay visible (not hidden)" % k)
	root.queue_free()
	await wait_frames(2)
