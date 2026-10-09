extends TestCase
## VERIFIER PROBE (vr, round 3, experience lens) on flight's REAL player rig
## (scenes/player/player.tscn) with scenes/vr/vr_rig_extras.tscn attached as
## docs/areas/VR.md tells integration (same harness as the builder's
## tests/sim/flight_rig). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3x_flight_rig
## Questions:
##  1. Ordinary play is not steady flapping: players glide, flap a few
##     beats, glide again. The builder measures steady flapping after a 10 s
##     settle and reports the onset separately (peak 0.3 = the accel term
##     saturated at setting 0.6). How much of an ordinary flap/glide rhythm
##     in straight open-sky flight is spent with the view narrowed?
##  2. VR.md §2.3 / the report: "A capture flight makes anyway (its own
##     begin_calibration, or one taken before the extras attached) is
##     adopted and refined". Check it when VR already holds a calibration.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const PLAYER := "res://scenes/player/player.tscn"
const DT := 1.0 / 72.0
const MODE_GROUNDED := 3


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
	return {"player": player, "origin": origin, "store": store, "extras": extras, "cal": cal}


func drive(rig: Dictionary, h: VRHumanPose) -> void:
	var origin: XROrigin3D = rig["origin"]
	var ws := origin.world_scale
	var hd := h.head_transform()
	(origin.get_node("XRCamera3D") as Node3D).transform = Transform3D(hd.basis, hd.origin * ws)
	for side in 2:
		var x := h.hand_transform(side)
		(origin.get_node("LeftHand" if side == 0 else "RightHand") as Node3D).transform = Transform3D(x.basis, x.origin * ws)


func ground_frame(rig: Dictionary, h: VRHumanPose) -> void:
	drive(rig, h)
	(rig["player"] as Node).call("tick", DT)
	(rig["player"] as Node).set("mode", MODE_GROUNDED)
	(rig["cal"] as VRCalibration).tick(DT)


func fly_frame(rig: Dictionary, h: VRHumanPose) -> float:
	drive(rig, h)
	(rig["player"] as Node).call("tick", DT)
	(rig["cal"] as VRCalibration).tick(DT)
	var v: ComfortVignette = (rig["extras"] as VRRigExtras).vignette
	v.measure(DT)
	return v.update_strength(DT)


func free_rig(rig: Dictionary) -> void:
	(rig["player"] as Node).queue_free()
	await wait_frames(2)


func test_flap_glide_rhythm_in_open_sky() -> void:
	var rows := {}
	# [flap amplitude deg, Hz, wrist twist deg, beats per burst, glide s]
	var styles := {
		"gentle cruise bursts (3 beats, 20°, 1 Hz)": [20.0, 1.0, -10.0, 3, 4.0],
		"cruise bursts (4 beats, 25°, 1 Hz)": [25.0, 1.0, -20.0, 4, 4.0],
		"climb bursts (4 beats, 40°, 1.2 Hz)": [40.0, 1.2, 0.0, 4, 3.0],
	}
	for sp in ["sparrow", "starling", "pigeon"]:
		for sname in styles:
			var st: Array = styles[sname]
			var store := MemoryStore.new()
			store.set_value("comfort_vignette", 0.6)
			var rig: Dictionary = await make_rig(store)
			var p: Node = rig["player"]
			p.set("mass", SizeRules.SPECIES[SizeRules.species_index(StringName(sp))]["mass"])
			var extras: VRRigExtras = rig["extras"]
			extras.world_scale_driver.snap()
			extras.vignette.auto_update = false
			extras.vignette.store = store
			var h := VRHumanPose.for_span(1.6)
			h.spread_pose()
			for i in int(2.5 / DT):
				ground_frame(rig, h)
			p.call("start_flying", Vector3(0, 300, 0), 0.0, 0.0)
			# Settle into a glide first.
			for i in int(6.0 / DT):
				h.set_arms(deg_to_rad(-5.0))
				fly_frame(rig, h)
			var amp: float = st[0]
			var hz: float = st[1]
			var tw: float = st[2]
			var burst := float(st[3]) / hz
			var glide: float = st[4]
			var cycle := burst + glide
			var total := cycle * 6.0
			var n := int(total / DT)
			var over10 := 0
			var over05 := 0
			var peak := 0.0
			var sum := 0.0
			var t := 0.0
			for i in n:
				t += DT
				var ph := fmod(t, cycle)
				if ph < burst:
					h.set_arms(deg_to_rad(-5.0 + amp * sin(TAU * hz * ph)), 0.0, deg_to_rad(tw))
				else:
					h.set_arms(deg_to_rad(-5.0), 0.0, 0.0)
				var s := fly_frame(rig, h)
				peak = maxf(peak, s)
				sum += s
				over10 += 1 if s > 0.10 else 0
				over05 += 1 if s > 0.05 else 0
			var tag := "%s %s" % [sp, sname]
			rows[tag] = {"peak": snappedf(peak, 0.001), "mean": snappedf(sum / n, 0.003), "frac_over_0.10": snappedf(float(over10) / n, 0.001),
				"frac_over_0.05": snappedf(float(over05) / n, 0.001), "mode": p.call("mode_name"), "flow": extras.vignette.flow,
				"ws": snappedf((rig["origin"] as XROrigin3D).world_scale, 0.001), "airspeed": snappedf(float((p.call("telemetry") as Dictionary).get("airspeed", 0.0)), 0.01)}
			print("[vr-verify] flap/glide ", tag, " ", rows[tag])
			eq(p.call("mode_name"), "flying", "%s: still flying" % tag)
			eq(extras.vignette.flow, 0.0, "%s: open sky (no optic flow)" % tag)
			# Experience bar: ordinary straight flight in open sky keeps the
			# full view most of the time.
			lt(float(over10) / n, 0.15, "%s: view narrowed > 0.10 for < 15 %% of ordinary flap/glide flight (%.0f %%)" % [tag, 100.0 * over10 / n])
			await free_rig(rig)
	metric("flap_glide_rhythm", rows)


func test_flight_recapture_after_vr_calibrated_is_refined() -> void:
	var store := MemoryStore.new()
	var rig: Dictionary = await make_rig(store)
	var cal: VRCalibration = rig["cal"]
	var p: Node = rig["player"]
	var h := VRHumanPose.for_span(1.75)
	h.spread_pose()
	for i in int(2.5 / DT):
		ground_frame(rig, h)
	check(cal.calibrator.calibrated, "(setup) VR calibrated")
	var vr_drop := cal.calibrator.shoulder_drop
	var res: Object = (p.get("wing_input") as Object).get("calibration")
	near(float(res.get("shoulder_drop")), vr_drop, 1e-4, "(setup) flight flies VR's drop")
	# Flight's own capture requested (its begin_calibration API), arms held 12°
	# high as some players do: flight's §5.10 capture derives the drop from
	# the hand line.
	h.set_arms(deg_to_rad(8.0))
	p.call("begin_calibration", &"neutral")
	for i in int(3.0 / DT):
		ground_frame(rig, h)
	var after := float(res.get("shoulder_drop"))
	var persisted := float((store.get_value("wing_calibration", {}) as Dictionary).get("shoulder_drop", -1.0))
	print("[vr-verify] recapture: VR drop %.3f, flight's resource now %.3f, VR's %.3f, persisted %.3f, true %.3f" % [vr_drop, after,
		cal.calibrator.shoulder_drop, persisted, h.shoulder_drop])
	metric("recapture", {"vr_drop": vr_drop, "flight_after": after, "vr_after": cal.calibrator.shoulder_drop, "persisted": persisted, "true": h.shoulder_drop})
	lt(absf(after - h.shoulder_drop), 0.015, "flight's own recapture is refined to VR's maths (drop %.3f vs true %.3f)" % [after, h.shoulder_drop])
	near(after, cal.calibrator.shoulder_drop, 0.005, "flight and VR agree on the calibration after flight recaptures")
	await free_rig(rig)
