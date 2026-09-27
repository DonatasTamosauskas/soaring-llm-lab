extends TestCase
## VERIFIER PROBE (vr, round 4, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r4x_span_inflation
##
## The calibration's continuous span refinement (WingCalibrator.
## _update_refinement) sets arm_span = grip-to-grip distance whenever that
## distance exceeds the calibrated span by 5 cm (and is <= 2.2 m) for 0.5 s,
## never shrinks it, and VRCalibration persists it at once. Its only guards
## are "both controllers tracked" and the 2.2 m cap: no pose check (arms
## spread? hands near shoulder height? each grip within reach of its
## shoulder?), no pause / game-state gate.
##
## Everyday VR moments where the grips are far apart without the arms being
## longer: a player sets one controller down on a table or chair to adjust
## the headset strap, take a drink or answer a phone, often from the pause
## menu. Quest keeps tracking a controller that lies in view of the headset
## cameras (has_tracking_data stays true).
##
## Asserted (V3 "persisted and reloaded", consistency of readings): putting a
## controller down must not change the persisted calibration; afterwards the
## same full spread must read the same extension, the bird the same size
## (world_scale), and a standing player must not become "seated".

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 72.0


func before_all() -> void:
	XRServer.world_scale = 1.0


func make(store: Object) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	node.force_auto_allowed = true
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node}


## Holds the synthetic body's pose, optionally with the right controller
## replaced by a fixed transform (lying on a table).
func hold(rig: Dictionary, h: VRHumanPose, seconds: float, right_override: Variant = null) -> void:
	for i in int(round(seconds / DT)):
		(rig["camera"] as Node3D).transform = h.head_transform()
		(rig["hands"][0] as Node3D).transform = h.hand_transform(0)
		if right_override is Transform3D:
			(rig["hands"][1] as Node3D).transform = right_override
		else:
			(rig["hands"][1] as Node3D).transform = h.hand_transform(1)
		(rig["node"] as VRCalibration).tick(DT)


func readings(rig: Dictionary, h: VRHumanPose) -> Dictionary:
	var cal := (rig["node"] as VRCalibration).calibrator
	h.spread_pose()
	hold(rig, h, 0.3)
	var spread := 0.5 * (cal.extension[0] + cal.extension[1])
	# Half fold: arms 20° low, elbows 105°.
	h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
	hold(rig, h, 0.3)
	var half := 0.5 * (cal.extension[0] + cal.extension[1])
	h.spread_pose()
	return {"span": snappedf(cal.arm_span, 0.001), "spread_ext": snappedf(spread, 0.001), "half_fold_ext": snappedf(half, 0.001),
		"sparrow_world_scale": snappedf(WorldScaleDriver.target_scale(0.03, cal.arm_span), 0.0001), "seated": cal.is_seated()}


func test_controller_set_down_on_a_table() -> void:
	var rows := {}
	for table_dist: float in [1.8, 2.0, 2.15]:
		var store := MemoryStore.new()
		var rig := make(store)
		var node: VRCalibration = rig["node"]
		var h := VRHumanPose.for_span(1.6)
		h.spread_pose()
		hold(rig, h, 2.0)
		check(node.calibrator.calibrated, "setup: calibrated")
		var before := readings(rig, h)
		var saved_before := float(store.get_value("wing_calibration", {}).get("arm_span", 0.0))
		# Left arm hangs at the side holding its controller; the right
		# controller lies on a table at hip height, `table_dist` from the
		# left grip, for 4 s (adjusting the strap).
		h.set_arms(deg_to_rad(-80.0))
		var lg := h.hand_transform(0).origin
		var table := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(lg.x + table_dist * 0.98, 0.75, lg.z - table_dist * 0.2))
		table.origin.y = 0.75
		var d := table.origin.distance_to(lg)
		hold(rig, h, 4.0, table)
		var saved_after := float(store.get_value("wing_calibration", {}).get("arm_span", 0.0))
		# Picks it up again and plays standing: 10 s of normal standing,
		# then 6 s looking down at the ground below (head pitched 40° down,
		# a slight 15 cm dip at the knees, as when diving towards prey).
		h.spread_pose()
		hold(rig, h, 10.0)
		var after := readings(rig, h)
		h.head_pitch = deg_to_rad(-40.0)
		h.room_offset = Vector3(0, -0.15, 0)
		hold(rig, h, 6.0)
		h.head_pitch = 0.0
		h.room_offset = Vector3.ZERO
		hold(rig, h, 8.0)
		var seated_later := node.calibrator.is_seated()
		var row := {"grip_distance_on_table": snappedf(d, 0.01), "before": before, "after": after,
			"saved_span_before": snappedf(saved_before, 0.001), "saved_span_after": snappedf(saved_after, 0.001),
			"seated_after_a_6s_look_down_then_standing_8s": seated_later, "eye_height": snappedf(h.eye_height, 0.001)}
		rows["table_%.2f" % table_dist] = row
		print("[vr_verify] 1.6 m player, right controller set down %.2f m from the left grip: %s" % [d, str(row)])
		near(saved_after, saved_before, 0.01, "table %.2f m: a controller set down must not change the persisted span (%.3f -> %.3f)" % [d, saved_before, saved_after])
		near(float(after["spread_ext"]), float(before["spread_ext"]), 0.03, "table %.2f m: same full spread reads the same extension afterwards" % d)
		near(float(after["half_fold_ext"]), float(before["half_fold_ext"]), 0.03, "table %.2f m: same half fold reads the same afterwards" % d)
		near(float(after["sparrow_world_scale"]), float(before["sparrow_world_scale"]), 0.002, "table %.2f m: the bird keeps its size" % d)
		check(not seated_later, "table %.2f m: a standing player is not left 'seated'" % d)
		(rig["node"] as Node).queue_free()
		(rig["origin"] as Node).queue_free()
	metric("controller_set_down", rows)
