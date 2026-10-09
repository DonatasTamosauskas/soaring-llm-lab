extends TestCase
## V3, fix round 4 (engineering verifier): a corrupt saved calibration is
## rejected, never loaded into VR or written into flight's WingCalibration.
## Written against VRCalibration / WingCalibrator's round-3 API only, so the
## same file shows how round 3 failed it (artifacts/vr/old_code_check_round4.log).

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 90.0


func player(span: float, off: Array) -> VRHumanPose:
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
	return h


func calibrated_for(h: VRHumanPose) -> WingCalibrator:
	var cal := WingCalibrator.new()
	cal.request_capture()
	h.spread_pose()
	for i in int(round(2.0 / DT)):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
	return cal


func make_rig() -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	return {"origin": origin, "camera": cam, "hands": [l, r]}


func run(node: VRCalibration, rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		(rig["camera"] as Node3D).transform = h.head_transform()
		for s in 2:
			(rig["hands"][s] as Node3D).transform = h.hand_transform(s)
		node.tick(DT)


func make_node(rig: Dictionary, store: Object) -> VRCalibration:
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = rig["origin"]
	node.camera = rig["camera"]
	node.hands = [rig["hands"][0], rig["hands"][1]]
	return node


func make_player(mode: String) -> Bird:
	var p := StubPlayer.new()
	p.mode_label = mode
	p.calibration = CalMock.new()
	add_child(p)
	return p


func drop_player(p: Bird) -> void:
	remove_child(p)
	p.free()


static func _basis_ok(b: Basis) -> bool:
	for v in [b.x, b.y, b.z]:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			return false
	return absf(b.determinant() - 1.0) < 1e-3


static func _axis_ok(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z) and absf(v.length() - 1.0) < 1e-3


## Fix round 4 (engineering verifier): a corrupt saved wrist neutral or
## axis (NaN, INF, a singular or mirrored basis, a zero axis, the wrong
## number of values) was loaded as is and written into flight's
## WingCalibration: a 20° wrist roll then read 0° while the calibration
## still said "calibrated", so nothing repaired it. Now any corrupt one
## rejects them all: the defaults, uncalibrated (the calibration step is
## due, as on a first launch), and VR pushes nothing into flight; a clean
## dict still loads.
func test_corrupt_saved_geometry_is_rejected() -> void:
	var nan_b := Basis(Vector3(NAN, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	var cases := {
		"NaN neutral_left": {"neutral_left": nan_b},
		"singular neutral_right": {"neutral_right": Basis(Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1))},
		"mirrored neutral_left": {"neutral_left": Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))},
		"NaN forearm_axis_right": {"forearm_axis_right": Vector3(NAN, 0, 0)},
		"INF chord_axis_left (flat array)": {"chord_axis_left": [INF, 0.0, 0.0]},
		"zero forearm_axis_left": {"forearm_axis_left": Vector3.ZERO},
		"short neutral_right array": {"neutral_right": [1.0, 0.0, 0.0]},
	}
	var src := calibrated_for(player(1.7, [0.0, 0.0]))
	for what in cases:
		var d := src.to_dict()
		d.merge(cases[what], true)
		var cal := WingCalibrator.new()
		check(cal.from_dict(d), "%s: the rest of the dict still loads" % what)
		check(not cal.calibrated, "%s: rejected (uncalibrated)" % what)
		check(not cal.capturing, "%s: nothing captures by itself" % what)
		for i in 2:
			check(_basis_ok(cal.neutral[i]) and _axis_ok(cal.forearm_axis[i]) and _axis_ok(cal.chord_axis[i]), "%s: side %d neutral and axes are sane" % [what, i])
			lt(VRMath.basis_angle(cal.neutral[i], VRHumanPose.airplane_basis(i)), 1e-5, "%s: side %d neutral is the default" % [what, i])
			vnear(cal.forearm_axis[i], WingCalibrator.DEFAULT_FOREARM, 1e-6, "%s: side %d forearm axis is the default" % [what, i])
		near(cal.arm_span, src.arm_span, 1e-6, "%s: the (valid) span is kept" % what)
	var clean := WingCalibrator.new()
	check(clean.from_dict(src.to_dict()) and clean.calibrated, "a clean dict loads calibrated")
	# Through the service: flight's resource is left uncalibrated, the
	# first-launch step is due, and the step (the player spreading) repairs
	# it: a 20° roll reads 20°.
	var store := MemoryStore.new()
	var bad := src.to_dict()
	bad["neutral_left"] = nan_b
	bad["forearm_axis_right"] = Vector3(NAN, 0, 0)
	store.set_value("wing_calibration", bad)
	var rig := make_rig()
	var p := make_player("perched")
	var node := make_node(rig, store)
	check(not node.calibrator.calibrated, "service: the corrupt saved calibration is not used")
	check(not bool(p.calibration.get("calibrated")), "service: nothing pushed into flight's WingCalibration")
	check(_basis_ok(p.calibration.get("neutral_left")) and _axis_ok(p.calibration.get("forearm_axis_right")), "service: flight's fields stay sane")
	check(node.first_launch_pending, "service: the calibration step is due (as on a first launch)")
	var h := player(1.7, [0.0, 0.0])
	h.spread_pose()
	run(node, rig, h, 2.5)
	check(not node.calibrator.calibrated, "service: a spread alone captures nothing (desktop: the step is not shown by itself)")
	node.start_manual()
	run(node, rig, h, 2.5)
	check(node.calibrator.calibrated and bool(p.calibration.get("calibrated")), "service: the step recalibrated (and reached flight)")
	h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(20.0))
	run(node, rig, h, 0.2)
	near(rad_to_deg(node.calibrator.twist[1]), 20.0, 1.0, "service: a 20° roll reads %.1f°" % rad_to_deg(node.calibrator.twist[1]))
	check(_basis_ok((store.get_value("wing_calibration", {}) as Dictionary).get("neutral_left")), "service: the repaired calibration is persisted")
	drop_player(p)
	node.queue_free()
	(rig["origin"] as Node).queue_free()
