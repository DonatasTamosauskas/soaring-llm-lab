extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens), V5 first-person wings.
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_wings
## The unit suite pins where the hand feathers sit relative to the grip. A
## player also sees the ARM feathers (rooted on the shoulder -> hand line),
## which sit right beside the head. Sweeping the whole reachable arm space
## (dihedral -85..+80°, sweep -30..+60°, elbow 0..150°), how close does any
## feather surface come to the eyes, compared with the hands themselves?
## A feather a few cm from the eye fills half the view with a flat brown
## plane (or is cut open by the 3 cm near plane) while the player's hands
## are well away: bad for comfort and readability.
## Also: extreme / broken input (NaN, zero basis, hands swapped, huge
## world_scale) never produces non-finite transforms.

const DT := 1.0 / 90.0

var wings: FirstPersonWings
var cal: WingCalibrator
var h: VRHumanPose


func before_all() -> void:
	cal = WingCalibrator.new()
	cal.auto_capture_allowed = true
	h = VRHumanPose.for_span(1.6)
	h.spread_pose()
	for i in int(2.0 / DT):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	wings = FirstPersonWings.new()
	wings.auto_update = false
	wings.use_flight_extension = false
	wings.species_override = &"sparrow"
	add_child(wings)
	wings.calibrator = cal
	await wait_frames(1)


func after_all() -> void:
	wings.queue_free()


func _arms(dih: float, sw: float, elb: float, tw: float = 0.0) -> void:
	h.set_arms(deg_to_rad(dih), deg_to_rad(sw), deg_to_rad(tw), deg_to_rad(elb))
	for i in 3:
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	wings.update_wings(0.0)


## Min distance from the eye to any sampled feather surface point, and the
## feather index that did it.
func _closest(eye: Vector3) -> Array:
	var best := INF
	var who := -1
	for k in FirstPersonWings.PER_WING * 2:
		var t := wings.feather_transform(k)
		for u in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
			for v in [-0.5, -0.25, 0.0, 0.25, 0.5]:
				var p: Vector3 = t.origin + t.basis.x * float(u) + t.basis.z * float(v)
				var d: float = p.distance_to(eye)
				if d < best:
					best = d
					who = k
	return [best, who]


func test_feathers_stay_clear_of_the_face() -> void:
	var worst := {"d": INF, "pose": "", "hand_d": 0.0, "feather": -1}
	var intrusions: Array = []
	var n := 0
	for dih in range(-85, 81, 15):
		for sw in range(-30, 61, 30):
			for elb in range(0, 151, 30):
				_arms(dih, sw, elb)
				var eye := cal.head.origin
				var hand_d := minf(cal.hands[0].origin.distance_to(eye), cal.hands[1].origin.distance_to(eye))
				var c := _closest(eye)
				n += 1
				if c[0] < worst["d"]:
					worst = {"d": c[0], "pose": "dihedral %d sweep %d elbow %d" % [dih, sw, elb], "hand_d": hand_d, "feather": c[1],
						"ext": [snappedf(cal.extension[0], 0.01), snappedf(cal.extension[1], 0.01)]}
				# A feather much closer to the eye than either hand, and inside
				# 12 cm (it covers > ~60° of view there). Arms raised above
				# 60° put the arm itself across the face: not counted (the one
				# hit at dihedral 80°, sweep 60°: a covert 10.8 cm away).
				if c[0] < 0.12 and hand_d > 0.30 and dih <= 60:
					intrusions.append("dih %d sw %d elb %d: feather %d at %.3f m, hands %.2f m" % [dih, sw, elb, c[1], c[0], hand_d])
	print("[vr-verify] %d poses; closest feather %s" % [n, str(worst)])
	for s in intrusions.slice(0, 12):
		print("[vr-verify]   intrusion ", s)
	metric("r2x_wings_closest_feather", worst)
	metric("r2x_wings_face_intrusions", intrusions.size())
	metric("r2x_wings_face_intrusion_examples", intrusions.slice(0, 12))
	gt(float(worst["d"]), 0.03, "no feather ever reaches inside the 3 cm near plane (a clipped hole in the wing)")
	eq(intrusions.size(), 0, "no pose puts a feather within 12 cm of the eyes while both hands are > 30 cm away (of %d poses)" % n)


func test_broken_input_never_gives_non_finite_feathers() -> void:
	var bad := 0
	var cases := {
		"nan hand": Transform3D(Basis.IDENTITY, Vector3(NAN, 1.0, 0.0)),
		"zero basis": Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3(0.7, 1.4, 0.0)),
		"inf hand": Transform3D(Basis.IDENTITY, Vector3(INF, 1.4, 0.0)),
		"hand on the shoulder": Transform3D(Basis.IDENTITY, Vector3(0.18, 1.45, 0.0)),
	}
	for name in cases:
		for i in 3:
			cal.measure(h.head_transform(), cases[name], h.hand_transform(1), 7, DT)
		wings.update_wings(DT)
		for k in FirstPersonWings.PER_WING * 2:
			var t := wings.feather_transform(k)
			if not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite() and t.basis.z.is_finite()):
				bad += 1
				print("[vr-verify] non-finite feather %d after '%s'" % [k, name])
				break
	eq(bad, 0, "broken tracking input never produces NaN/inf feather transforms")
