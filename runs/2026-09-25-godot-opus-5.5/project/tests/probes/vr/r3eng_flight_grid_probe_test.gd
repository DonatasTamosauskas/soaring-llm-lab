extends TestCase
## Round-3 engineering verifier probe: the V3 grid (arm spans 1.4-2.0 m x
## wrist habits -25/0/+25/+-25°) read through what the player actually
## flies: flight's REAL WingInput (scenes/player/player.tscn) with VR's rig
## extras attached and VR making the capture. The unit suite pins the grid
## on VR's own calibrator reading; flight_rig pins one 1.75 m body. This
## asks whether the normalised extension / pitch / roll that FLIGHT receives
## are the same for every player. Depends on flight's in-progress code (a
## probe, not a unit test).
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3eng_flight_grid

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const PLAYER := "res://scenes/player/player.tscn"
const DT := 1.0 / 72.0
const MODE_GROUNDED := 3
const SPANS := [1.4, 1.6, 1.8, 2.0]
const OFFSETS := [[-25.0, -25.0], [0.0, 0.0], [25.0, 25.0], [25.0, -25.0]]
## name -> [dihedral, sweep, twist L, twist R, elbow] (degrees), as calibration_test.
const GESTURES := {
	"spread": [0.0, 0.0, 0.0, 0.0, 0.0],
	"glide": [-45.0, 0.0, 0.0, 0.0, 40.0],
	"twist_up_20": [-5.0, 0.0, 20.0, 20.0, 10.0],
	"twist_down_20": [-5.0, 0.0, -20.0, -20.0, 10.0],
	"aileron_20": [-5.0, 0.0, 20.0, -20.0, 10.0],
	"arm_raise_40": [40.0, 0.0, 0.0, 0.0, 0.0],
	"half_fold": [-20.0, 0.0, 0.0, 0.0, 105.0],
}


func after_each() -> void:
	XRServer.world_scale = 1.0
	await wait_frames(2)


func make_rig(store: Object) -> Dictionary:
	var player := (load(PLAYER) as PackedScene).instantiate() as Node3D
	player.set("use_settings", false)
	player.set("default_source", &"none")
	player.set("auto_process", false)
	player.position = Vector3(0, 20, 0)
	add_child(player)
	var origin := player.get_node("XROrigin3D") as XROrigin3D
	var src := XRPoseSource.new(origin, origin.get_node("XRCamera3D"), origin.get_node("LeftHand"), origin.get_node("RightHand"))
	src.assume_tracked = true
	player.call("set_pose_source", src)
	player.set("mode", MODE_GROUNDED)
	var extras := EXTRAS.instantiate() as VRRigExtras
	var cal := extras.get_node("Calibration") as VRCalibration
	cal.store = store
	cal.auto_tick = false
	cal.show_prompt = false
	origin.add_child(extras)
	await wait_frames(3)
	return {"player": player, "origin": origin, "cal": cal}


func frame(rig: Dictionary, h: VRHumanPose) -> void:
	var origin: XROrigin3D = rig["origin"]
	var ws := origin.world_scale
	var hd := h.head_transform()
	(origin.get_node("XRCamera3D") as Node3D).transform = Transform3D(hd.basis, hd.origin * ws)
	for side in 2:
		var x := h.hand_transform(side)
		(origin.get_node("LeftHand" if side == 0 else "RightHand") as Node3D).transform = Transform3D(x.basis, x.origin * ws)
	(rig["player"] as Node).call("tick", DT)
	(rig["player"] as Node).set("mode", MODE_GROUNDED)
	(rig["cal"] as VRCalibration).tick(DT)


func readings(rig: Dictionary, h: VRHumanPose) -> Dictionary:
	var out := {}
	for g in GESTURES:
		var a: Array = GESTURES[g]
		h.dihedral = [deg_to_rad(a[0]), deg_to_rad(a[0])]
		h.sweep = [deg_to_rad(a[1]), deg_to_rad(a[1])]
		h.twist = [deg_to_rad(a[2]), deg_to_rad(a[3])]
		h.elbow = [deg_to_rad(a[4]), deg_to_rad(a[4])]
		for i in int(1.0 / DT):
			frame(rig, h)
		var ws: Object = (rig["player"] as Node).call("wing_state")
		out[g] = {"ext_l": float(ws.get("ext_l")), "ext_r": float(ws.get("ext_r")), "pitch": float(ws.get("pitch")),
			"roll": float(ws.get("roll")), "tw_l": rad_to_deg(float(ws.get("twist_l"))), "tw_r": rad_to_deg(float(ws.get("twist_r")))}
	return out


func player_reads(span: float, off: Array) -> Dictionary:
	var rig: Dictionary = await make_rig(MemoryStore.new())
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
	h.spread_pose()
	for i in int(3.0 / DT):
		frame(rig, h)
	var cal: VRCalibration = rig["cal"]
	check(cal.calibrator.calibrated, "span %.1f habit %s: VR captured" % [span, str(off)])
	var r := readings(rig, h)
	(rig["player"] as Node).queue_free()
	await wait_frames(2)
	return r


func test_flight_reads_the_same_for_every_player() -> void:
	var ref: Dictionary = await player_reads(1.6, [0.0, 0.0])
	var worst := {"ext": 0.0, "pitch": 0.0, "roll": 0.0, "twist": 0.0}
	var where := {"ext": "", "pitch": "", "roll": "", "twist": ""}
	for span in SPANS:
		for off in OFFSETS:
			var r: Dictionary = await player_reads(span, off)
			for g in GESTURES:
				var a: Dictionary = r[g]
				var b: Dictionary = ref[g]
				var tag := "%.1f m %s %s" % [span, str(off), g]
				var de := maxf(absf(a["ext_l"] - b["ext_l"]), absf(a["ext_r"] - b["ext_r"]))
				var dp := absf(a["pitch"] - b["pitch"])
				var dr := absf(a["roll"] - b["roll"])
				var dt := maxf(absf(a["tw_l"] - b["tw_l"]), absf(a["tw_r"] - b["tw_r"]))
				if de > worst["ext"]:
					worst["ext"] = de
					where["ext"] = tag
				if dp > worst["pitch"]:
					worst["pitch"] = dp
					where["pitch"] = tag
				if dr > worst["roll"]:
					worst["roll"] = dr
					where["roll"] = tag
				if g != "half_fold" and dt > worst["twist"]:
					worst["twist"] = dt
					where["twist"] = tag
	print("[vr-verify] flight grid worst: %s at %s" % [str(worst), str(where)])
	print("[vr-verify] flight grid reference: %s" % str(ref))
	metric("worst", worst)
	metric("where", where)
	metric("reference", ref)
	lt(worst["ext"], 0.03, "flight's extension within 0.03 of the reference for all 16 players (%.4f at %s)" % [worst["ext"], where["ext"]])
	lt(worst["pitch"], 0.02, "flight's pitch command within 0.02 (%.4f at %s)" % [worst["pitch"], where["pitch"]])
	lt(worst["roll"], 0.02, "flight's roll command within 0.02 (%.4f at %s)" % [worst["roll"], where["roll"]])
	lt(worst["twist"], 1.0, "flight's wrist twist within 1° on spread-wing gestures (%.2f° at %s)" % [worst["twist"], where["twist"]])


## Integration seam: VR writes a new calibration straight into flight's
## WingCalibration resource, but flight's neutral-relative state (the
## FLIGHT_SPEC §5.10 auto-trim, up to +-10°, learnt against the OLD
## neutral) is only cleared by flight's own _capture_neutral. After the
## player recalibrates from the menu (VR's manual flow), flat wrists should
## read flat. The trim a long glide would have learnt (6°) is set directly
## (probe-only access to flight's internal) to stand in for minutes of play.
func test_manual_recalibration_leaves_no_stale_trim() -> void:
	var rig: Dictionary = await make_rig(MemoryStore.new())
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	for i in int(3.0 / DT):
		frame(rig, h)
	var cal: VRCalibration = rig["cal"]
	check(cal.calibrator.calibrated, "(setup) VR captured")
	var wi: Object = (rig["player"] as Node).get("wing_input")
	var trim: Array[float] = [deg_to_rad(6.0), deg_to_rad(6.0)]
	wi.set("_trim", trim)
	# The player recalibrates from the menu: neutral step, then the glide step times out.
	var done := [0]
	cal.flow_finished.connect(func(ok: bool, _why: String) -> void: done[0] += 1 if ok else 0)
	cal.start_manual()
	h.spread_pose()
	var t := 0.0
	while done[0] == 0 and t < 20.0:
		frame(rig, h)
		t += DT
	eq(done[0], 1, "(setup) manual recalibration finished OK (%.1f s)" % t)
	for i in int(0.5 / DT):
		frame(rig, h)
	var ws: Object = (rig["player"] as Node).call("wing_state")
	var tw := rad_to_deg(float(ws.get("twist_l")))
	print("[vr-verify] after VR's manual recalibration: flight twist_l %.2f°, pitch %.3f (stale trim 6°)" % [tw, float(ws.get("pitch"))])
	metric("twist_after_recalibration_deg", snappedf(tw, 0.01))
	lt(absf(tw), 1.0, "flat wrists read flat right after recalibrating (twist %.2f°)" % tw)
	(rig["player"] as Node).queue_free()
	await wait_frames(2)
