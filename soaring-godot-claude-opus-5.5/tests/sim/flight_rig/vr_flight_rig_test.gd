extends TestCase
## INTEGRATION CHECKS on the flight area's REAL player rig
## (scenes/player/player.tscn, PlayerBird's public API only: tick, mode,
## wing_state, wing_input.calibration, start_flying, set_pose_source), with
## scenes/vr/vr_rig_extras.tscn attached under its XROrigin3D exactly as
## docs/areas/VR.md tells integration. Not part of the headless unit suite
## (that one depends only on core contracts and VR's own mocks, so another
## area's mid-edit file can never break it); run as evidence:
##
##   tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=flight_rig
##
## Report: artifacts/tests/report_flight_rig.json. Frame order as in the
## game: flight's physics tick, then VR's _process tick. Poses are written
## to the rig's nodes (like a headset) by a synthetic player (VRHumanPose)
## and read by flight's XRPoseSource. Persistence goes to a private memory
## store, never user://settings.cfg.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const PLAYER := "res://scenes/player/player.tscn"
const DT := 1.0 / 72.0
const MODE_GROUNDED := 3

var _rng := RandomNumberGenerator.new()


func after_each() -> void:
	XRServer.world_scale = 1.0
	await wait_frames(2)


## Flight's player with the VR extras; `attach_extras` false leaves them
## out (added later by the caller).
func make_rig(store: Object, attach_extras: bool = true) -> Dictionary:
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
	var rig := {"player": player, "origin": origin, "store": store}
	if attach_extras:
		await attach(rig)
	return rig


func attach(rig: Dictionary) -> void:
	var extras := EXTRAS.instantiate() as VRRigExtras
	var cal := extras.get_node("Calibration") as VRCalibration
	cal.store = rig["store"]
	cal.auto_tick = false
	cal.show_prompt = false
	(rig["origin"] as Node).add_child(extras)
	await wait_frames(3)
	rig["extras"] = extras
	rig["cal"] = cal


func drive(rig: Dictionary, h: VRHumanPose, noise_mm: float) -> void:
	var origin: XROrigin3D = rig["origin"]
	var ws := origin.world_scale
	var k := noise_mm * 0.001
	var jit := func() -> Vector3: return Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)) if k > 0.0 else Vector3.ZERO
	var hd := h.head_transform()
	(origin.get_node("XRCamera3D") as Node3D).transform = Transform3D(hd.basis, (hd.origin + jit.call()) * ws)
	for side in 2:
		var x := h.hand_transform(side)
		(origin.get_node("LeftHand" if side == 0 else "RightHand") as Node3D).transform = Transform3D(x.basis, (x.origin + jit.call()) * ws)


## One game frame: flight's physics tick, then VR's tick (if attached).
func frame(rig: Dictionary, h: VRHumanPose, noise_mm: float) -> void:
	drive(rig, h, noise_mm)
	(rig["player"] as Node).call("tick", DT)
	(rig["player"] as Node).set("mode", MODE_GROUNDED)
	if rig.has("cal"):
		(rig["cal"] as VRCalibration).tick(DT)


## What the player flies for a half fold (arms 20° low, elbows 105°): flight's
## own WingState after 1 s, and the calibration's reading of it.
func half_fold(rig: Dictionary, h: VRHumanPose) -> Dictionary:
	h.dihedral = [deg_to_rad(-20.0), deg_to_rad(-20.0)]
	h.sweep = [0.0, 0.0]
	h.twist = [0.0, 0.0]
	h.elbow = [deg_to_rad(105.0), deg_to_rad(105.0)]
	for i in int(1.0 / DT):
		frame(rig, h, 0.0)
	var ws: Object = (rig["player"] as Node).call("wing_state")
	return {"ext": float(ws.get("ext_l")), "ext_r": float(ws.get("ext_r")), "pitch": float(ws.get("pitch")),
		"twist_deg": rad_to_deg(float(ws.get("twist_l")))}


func flight_calibration(rig: Dictionary) -> Object:
	return ((rig["player"] as Node).get("wing_input") as Object).get("calibration")


func free_rig(rig: Dictionary) -> void:
	(rig["player"] as Node).queue_free()
	await wait_frames(2)


# -----------------------------------------------------------------------------

## The composed game: VR's extras take the calibration over from flight's
## WingInput (its automatic capture is switched off, and VR has none of its
## own: a still spread held 3 s without the calibration step captures
## nothing on flight's real rig); with the step, whoever holds the pose
## however steadily, the calibration flight flies with is VR's, and the
## half fold reads the same whatever the arm height at capture (12° low ..
## 8° high) and tremor (0 .. 1.5 mm).
func test_vr_owns_the_capture_on_flights_rig() -> void:
	var rows := {}
	var ext: Array[float] = []
	var pit: Array[float] = []
	for elev in [-12.0, -5.0, 0.0, 8.0]:
		for tremor in [0.0, 0.3, 1.5]:
			_rng.seed = 77
			var rig: Dictionary = await make_rig(MemoryStore.new())
			var cal: VRCalibration = rig["cal"]
			var p: Node = rig["player"]
			var res := flight_calibration(rig)
			var tag := "arms %+.0f° tremor %.1f mm" % [elev, tremor]
			check(not bool(p.get("auto_calibrate")), "%s: flight's automatic capture switched off as soon as VR's extras attach" % tag)
			var vr_caps := [0]
			cal.calibrator.captured.connect(func(_k: StringName) -> void: vr_caps[0] += 1)
			var h := VRHumanPose.for_span(1.75)
			h.set_arms(deg_to_rad(elev))
			for i in int(3.0 / DT):
				frame(rig, h, tremor)
			check(not bool(res.get("calibrated")) and not cal.calibrator.calibrated and vr_caps[0] == 0,
				"%s: without the calibration step nothing captures the spread (flight's defaults apply)" % tag)
			cal.start_manual()
			for i in int(3.0 / DT):
				frame(rig, h, tremor)
			check(bool(res.get("calibrated")), "%s: the player is calibrated by the step" % tag)
			eq(vr_caps[0], 1, "%s: VR made the one capture" % tag)
			near(float(res.get("shoulder_drop")), cal.calibrator.shoulder_drop, 1e-5, "%s: flight flies VR's shoulder height" % tag)
			near(float(res.get("arm_span")), cal.calibrator.arm_span, 1e-5, "%s: and VR's span" % tag)
			lt(VRMath.basis_angle(res.get("neutral_left"), cal.calibrator.neutral[0]), 1e-4, "%s: and VR's neutral" % tag)
			lt(absf(float(res.get("shoulder_drop")) - h.shoulder_drop), 0.01, "%s: shoulder height within 1 cm of the body's" % tag)
			var hf := half_fold(rig, h)
			rows[tag] = {"drop": snappedf(float(res.get("shoulder_drop")), 0.001), "true_drop": snappedf(h.shoulder_drop, 0.001),
				"half_fold_ext": snappedf(hf["ext"], 0.001), "half_fold_pitch": snappedf(hf["pitch"], 0.001), "twist_deg": snappedf(hf["twist_deg"], 0.01)}
			print("[vr] flight rig %s: %s" % [tag, str(rows[tag])])
			ext.append(hf["ext"])
			pit.append(hf["pitch"])
			await free_rig(rig)
	metric("vr_owns_capture", rows)
	metric("half_fold_ext_range", snappedf(ext.max() - ext.min(), 0.0001))
	metric("half_fold_pitch_range", snappedf(pit.max() - pit.min(), 0.0001))
	lt(ext.max() - ext.min(), 0.04, "flight's half-fold extension is the same for every capture height and tremor (range %.4f)" % (ext.max() - ext.min()))
	lt(pit.max() - pit.min(), 0.02, "and so is its pitch command (range %.4f)" % (pit.max() - pit.min()))


## A capture flight made before VR's extras attached (flight's own §5.10:
## arms-5°-low drop, neutral as held) is adopted, refined to VR's maths and
## written back: the half fold then reads what VR's own capture reads.
func test_a_capture_flight_made_first_is_refined() -> void:
	var rows := {}
	var ext: Array[float] = []
	var pit: Array[float] = []
	var ref := {}
	for elev in [-5.0, -12.0, 0.0, 8.0]:
		_rng.seed = 5
		var rig: Dictionary = await make_rig(MemoryStore.new(), false)
		var p: Node = rig["player"]
		var res := flight_calibration(rig)
		var tag := "arms %+.0f°" % elev
		var h := VRHumanPose.for_span(1.75)
		h.set_arms(deg_to_rad(elev))
		for i in int(2.5 / DT):
			frame(rig, h, 0.0)
		check(bool(res.get("calibrated")), "%s: flight captured by itself (no VR yet)" % tag)
		var flight_drop := float(res.get("shoulder_drop"))
		var unrefined := half_fold(rig, h)
		h.set_arms(deg_to_rad(elev))
		for i in 12:
			frame(rig, h, 0.0)
		await attach(rig)
		var cal: VRCalibration = rig["cal"]
		frame(rig, h, 0.0)
		check(cal.calibrator.calibrated and not cal.calibrator.capturing and cal.flow == VRCalibration.Flow.IDLE, "%s: VR adopted it (no capture of its own)" % tag)
		near(float(res.get("shoulder_drop")), cal.calibrator.shoulder_drop, 1e-5, "%s: the refined calibration is written back to flight" % tag)
		near(float(((rig["store"] as Object).call("get_value", "wing_calibration", {}) as Dictionary).get("shoulder_drop", 0.0)),
			cal.calibrator.shoulder_drop, 1e-5, "%s: and persisted" % tag)
		lt(absf(cal.calibrator.shoulder_drop - h.shoulder_drop), 0.01, "%s: shoulder height within 1 cm of the body's (flight had %.3f, true %.3f)" % [tag, flight_drop, h.shoulder_drop])
		var hf := half_fold(rig, h)
		rows[tag] = {"flight_drop": snappedf(flight_drop, 0.001), "refined_drop": snappedf(cal.calibrator.shoulder_drop, 0.001),
			"true_drop": snappedf(h.shoulder_drop, 0.001), "half_fold_unrefined": [snappedf(unrefined["ext"], 0.001), snappedf(unrefined["pitch"], 0.001)],
			"half_fold_refined": [snappedf(hf["ext"], 0.001), snappedf(hf["pitch"], 0.001)]}
		print("[vr] flight rig adoption %s: %s" % [tag, str(rows[tag])])
		ext.append(hf["ext"])
		pit.append(hf["pitch"])
		await free_rig(rig)
	metric("adoption", rows)
	lt(ext.max() - ext.min(), 0.04, "after the refinement the half fold reads the same for every capture height (range %.4f)" % (ext.max() - ext.min()))
	lt(pit.max() - pit.min(), 0.02, "and the same pitch command (range %.4f)" % (pit.max() - pit.min()))


## Flight captures again after VR has calibrated (its public
## begin_calibration(&"neutral")), with the arms held 8° high: VR adopts it,
## refines it to its own maths and writes it back, so flight flies the
## body's drop and both agree (fix round 3; the verifier's r3x_flight_rig
## probe found flight flying drop 0.150 for a true 0.286).
func test_flight_recapture_after_vr_is_refined() -> void:
	var store := MemoryStore.new()
	var rig: Dictionary = await make_rig(store)
	var cal: VRCalibration = rig["cal"]
	var h := VRHumanPose.for_span(1.75)
	h.spread_pose()
	cal.start_manual()
	for i in int(2.5 / DT):
		frame(rig, h, 0.0)
	check(cal.calibrator.calibrated, "(setup) VR calibrated")
	var res := flight_calibration(rig)
	h.set_arms(deg_to_rad(8.0))
	(rig["player"] as Node).call("begin_calibration", &"neutral")
	for i in int(3.0 / DT):
		frame(rig, h, 0.0)
	var drop := float(res.get("shoulder_drop"))
	var saved := float((store.get_value("wing_calibration", {}) as Dictionary).get("shoulder_drop", -1.0))
	var row := {"flight_drop": snappedf(drop, 0.0001), "vr_drop": snappedf(cal.calibrator.shoulder_drop, 0.0001),
		"persisted": snappedf(saved, 0.0001), "true_drop": snappedf(h.shoulder_drop, 0.0001)}
	print("[vr] flight rig recapture: %s" % str(row))
	metric("flight_recapture", row)
	lt(absf(drop - h.shoulder_drop), 0.015, "flight's recapture refined: the body's drop (%.3f vs %.3f)" % [drop, h.shoulder_drop])
	near(drop, cal.calibrator.shoulder_drop, 1e-5, "flight and VR agree")
	near(saved, drop, 1e-5, "persisted")
	await free_rig(rig)


## After VR's manual recalibration flight's learnt neutral-twist trim is
## void: flat wrists read flat straight away (the verifier's
## r3eng_flight_grid probe measured 5.64° of twist with 6° of stale trim).
func test_recalibration_clears_flights_trim() -> void:
	var rig: Dictionary = await make_rig(MemoryStore.new())
	var cal: VRCalibration = rig["cal"]
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	cal.start_manual()
	for i in int(3.0 / DT):
		frame(rig, h, 0.0)
	check(cal.calibrator.calibrated, "(setup) VR captured")
	var wi: Object = (rig["player"] as Node).get("wing_input")
	# Six degrees learnt against the old neutral (as flight's auto-trim
	# would after a minute of gliding with a drifting "flat").
	var trim: Variant = wi.get("_trim")
	if trim is Array:
		(trim as Array)[0] = deg_to_rad(6.0)
		(trim as Array)[1] = deg_to_rad(6.0)
	var done := [0]
	cal.flow_finished.connect(func(ok: bool, _why: String) -> void: done[0] += 1 if ok else 0)
	cal.start_manual()
	var t := 0.0
	while done[0] == 0 and t < 20.0:
		frame(rig, h, 0.0)
		t += DT
	eq(done[0], 1, "(setup) the manual recalibration finished (%.1f s)" % t)
	for i in int(0.5 / DT):
		frame(rig, h, 0.0)
	var ws: Object = (rig["player"] as Node).call("wing_state")
	var tw := rad_to_deg(float(ws.get("twist_l")))
	metric("twist_after_recalibration_deg", snappedf(tw, 0.01))
	print("[vr] flight rig: twist on flat wrists right after a recalibration %.2f° (stale trim was 6°; hook %s)" % [tw,
		"calibration_replaced()" if wi.has_method(&"calibration_replaced") else "_trim zeroed"])
	lt(absf(tw), 1.0, "flat wrists read flat right after recalibrating (%.2f°)" % tw)
	await free_rig(rig)


## Seating detected after the capture reaches the calibration flight flies
## at once, and standing up again does too (the verifier's r3eng probe:
## flight kept standing limits until the next respawn).
func test_detected_seating_reaches_flight() -> void:
	var rig: Dictionary = await make_rig(MemoryStore.new())
	var cal: VRCalibration = rig["cal"]
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	cal.start_manual()
	for i in int(2.5 / DT):
		frame(rig, h, 0.0)
	var res := flight_calibration(rig)
	check(cal.calibrator.calibrated and not bool(res.get("seated")), "(setup) standing player calibrated, flight standing")
	h.eye_height = 1.15
	h.set_arms(deg_to_rad(-60.0))
	for i in int(6.0 / DT):
		frame(rig, h, 0.0)
	check(bool(res.get("seated")), "flight's calibration is seated once VR detects it")
	h.eye_height = 1.60
	for i in int(6.0 / DT):
		frame(rig, h, 0.0)
	check(not bool(res.get("seated")), "and standing again when the player stands")
	await free_rig(rig)


## Fix round 4 (a verifier's major, and the lead's scenarios) on flight's
## real rig: a controller set down on a table 2 m from the other grip for
## 4 s. VR's calibration ignores it; flight's own WingInput still refines
## its copy's span by the round-3 rule, and VR puts its span back each
## tick, so what the player flies (flight's WingState for a half fold)
## reads the same afterwards and flight's resource keeps VR's span.
func test_a_controller_on_a_table_changes_nothing_in_flight() -> void:
	var store := MemoryStore.new()
	var rig: Dictionary = await make_rig(store)
	var cal: VRCalibration = rig["cal"]
	var h := VRHumanPose.for_span(1.6)
	h.spread_pose()
	cal.start_manual()
	for i in int(2.5 / DT):
		frame(rig, h, 0.0)
	check(cal.calibrator.calibrated, "(setup) calibrated")
	var span0 := cal.calibrator.arm_span
	var before := half_fold(rig, h)
	h.set_arms(deg_to_rad(-80.0))
	var lg := h.hand_transform(0).origin
	var table := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(lg.x + 1.96, 0.75, lg.z - 0.4))
	var origin: XROrigin3D = rig["origin"]
	var worst_flight_span := 0.0
	for i in int(4.0 / DT):
		drive(rig, h, 0.0)
		(origin.get_node("RightHand") as Node3D).transform = Transform3D(table.basis, table.origin * origin.world_scale)
		(rig["player"] as Node).call("tick", DT)
		(rig["player"] as Node).set("mode", MODE_GROUNDED)
		# Between flight's tick and VR's: what flight's own rule made of it.
		worst_flight_span = maxf(worst_flight_span, float(flight_calibration(rig).get("arm_span")))
		cal.tick(DT)
	var res := flight_calibration(rig)
	near(cal.calibrator.arm_span, span0, 1e-4, "VR's span unchanged (%.3f)" % cal.calibrator.arm_span)
	near(float(res.get("arm_span")), span0, 1e-4, "flight's resource flies VR's span after each VR tick")
	near(float((store.get_value("wing_calibration", {}) as Dictionary).get("arm_span", 0.0)), span0, 1e-4, "the persisted span unchanged")
	h.spread_pose()
	for i in int(1.0 / DT):
		frame(rig, h, 0.0)
	var after := half_fold(rig, h)
	near(float(after["ext"]), float(before["ext"]), 0.01, "flight's half fold reads the same afterwards (%.3f vs %.3f)" % [after["ext"], before["ext"]])
	metric("table_on_flights_rig", {"span": span0, "flight_span_peak_between_vr_ticks": worst_flight_span,
		"half_fold_before": before["ext"], "half_fold_after": after["ext"]})
	await free_rig(rig)


## One flight tick (no mode forcing) and the rig's vignette measured on it.
func fly_frame(rig: Dictionary, h: VRHumanPose) -> float:
	drive(rig, h, 0.0)
	(rig["player"] as Node).call("tick", DT)
	(rig["cal"] as VRCalibration).tick(DT)
	var v: ComfortVignette = (rig["extras"] as VRRigExtras).vignette
	v.measure(DT)
	return v.update_strength(DT)


## A sparrow/starling/... rig flying at `alt` over nothing (open sky) after
## a calibration on the ground; returns {rig, player, human}.
func flying_rig(sp: String, alt: float, pitch: float = 0.0) -> Dictionary:
	var store := MemoryStore.new()
	store.set_value("comfort_vignette", 0.6)
	var rig: Dictionary = await make_rig(store)
	var p: Node = rig["player"]
	p.set("mass", SizeRules.SPECIES[SizeRules.species_index(StringName(sp))]["mass"])
	var extras: VRRigExtras = rig["extras"]
	# A new body (the run starts as this species): no growth ramp.
	extras.world_scale_driver.snap()
	extras.vignette.auto_update = false
	extras.vignette.store = store
	var h := VRHumanPose.for_span(1.6)
	h.spread_pose()
	(rig["cal"] as VRCalibration).start_manual()
	for i in int(2.5 / DT):
		frame(rig, h, 0.0)
	check((rig["cal"] as VRCalibration).calibrator.calibrated, "%s: (setup) calibrated" % sp)
	p.call("start_flying", Vector3(0, alt, 0), 0.0, pitch)
	return {"rig": rig, "player": p, "human": h}


## The comfort vignette on flight's real PlayerBird (heave smoothing on),
## default setting 0.6, straight flight in open sky (no surface within the
## vignette's probe rays, no turning): the brief's "straight, fast flight in open
## sky keeps the full view" (flight_vr.md §11.4).
## Fix round 2: the stroke-averaged acceleration stopped the wingbeat itself
## from narrowing the view. Fix round 3 (a verifier's flap/glide probe): the
## flight model's real accelerations when a burst starts (a sparrow pitches
## up into a climb, ~35 m/s² perceived) still narrowed it for 30-86 % of
## ordinary flap/glide flight, because the acceleration term counted with
## nothing near to see it by. It now needs a surface within 8 body spans.
## So here every case is asserted over the WHOLE run, onset included:
## steady flapping of every kind, and the verifier's flap/glide rhythms.
func test_vignette_in_open_sky_flight() -> void:
	var cases := {
		"sparrow": [["glide", 0.0, 0.0, 0.0], ["cruise", 25.0, 1.0, -20.0], ["climb", 45.0, 1.0, 0.0], ["hover", 45.0, 1.0, 20.0], ["fast_flaps", 40.0, 1.6, 0.0]],
		"starling": [["cruise", 25.0, 1.0, -20.0], ["climb", 45.0, 1.0, 0.0]],
		"pigeon": [["cruise", 25.0, 1.0, -20.0], ["climb", 45.0, 1.0, 0.0]],
		"eagle": [["cruise", 25.0, 1.0, -20.0], ["climb", 45.0, 1.0, 0.0]],
	}
	var rows := {}
	for sp in cases:
		for c in cases[sp]:
			var fr: Dictionary = await flying_rig(sp, 300.0, 0.5 if c[0] == "hover" else 0.0)
			var rig: Dictionary = fr["rig"]
			var p: Node = fr["player"]
			var h: VRHumanPose = fr["human"]
			var extras: VRRigExtras = rig["extras"]
			if c[0] == "hover":
				(p.get("model") as Object).set("velocity", Vector3.ZERO)
			var amp: float = c[1]
			var hz: float = c[2]
			var t := 0.0
			var st := {"peak": 0.0, "first_10s_peak": 0.0, "over05": 0, "n": 0, "sum": 0.0, "accel_peak_perceived": 0.0}
			for i in int(16.0 / DT):
				t += DT
				h.set_arms(deg_to_rad(amp * sin(TAU * hz * t)) if amp > 0.0 else deg_to_rad(-5.0), 0.0, deg_to_rad(c[3]))
				var s := fly_frame(rig, h)
				st["peak"] = maxf(st["peak"], s)
				if t < 10.0:
					st["first_10s_peak"] = maxf(st["first_10s_peak"], s)
				st["over05"] += 1 if s > 0.05 else 0
				st["n"] += 1
				st["sum"] += s
				st["accel_peak_perceived"] = maxf(st["accel_peak_perceived"], extras.vignette.accel / (rig["origin"] as XROrigin3D).world_scale)
			var tag := "%s %s" % [sp, c[0]]
			var ws: Object = p.call("wing_state")
			rows[tag] = {"peak": snappedf(st["peak"], 0.001), "first_10s_peak": snappedf(st["first_10s_peak"], 0.001),
				"mean": snappedf(st["sum"] / st["n"], 0.001), "frac_over_0.05": snappedf(float(st["over05"]) / st["n"], 0.001),
				"accel_peak_perceived": snappedf(st["accel_peak_perceived"], 0.1),
				"stroke_period": snappedf(float(ws.get("stroke_period")), 0.001), "mode": p.call("mode_name"),
				"world_scale": snappedf((rig["origin"] as XROrigin3D).world_scale, 0.001), "proximity": snappedf(extras.vignette.proximity, 0.001)}
			print("[vr] flight rig vignette %s: %s" % [tag, str(rows[tag])])
			eq(p.call("mode_name"), "flying", "%s: flying (not landed or stalled out)" % tag)
			eq(extras.vignette.nearest, INF, "%s: open sky (nothing within the probes' reach)" % tag)
			lt(float(st["peak"]), 0.05, "%s: the whole 16 s, onset included, keeps the view open (peak %.3f)" % [tag, st["peak"]])
			await free_rig(rig)
	# Ordinary play: a few beats, then a glide, again and again (the
	# verifier's r3x_flight_rig probe styles: [amplitude deg, Hz, wrist
	# twist deg, beats per burst, glide s]).
	var styles := {
		"gentle bursts (3 x 20°, 1 Hz, 4 s glide)": [20.0, 1.0, -10.0, 3, 4.0],
		"cruise bursts (4 x 25°, 1 Hz, 4 s glide)": [25.0, 1.0, -20.0, 4, 4.0],
		"climb bursts (4 x 40°, 1.2 Hz, 3 s glide)": [40.0, 1.2, 0.0, 4, 3.0],
	}
	for sp in ["sparrow", "starling", "pigeon"]:
		for sname in styles:
			var st: Array = styles[sname]
			var fr: Dictionary = await flying_rig(sp, 300.0)
			var rig: Dictionary = fr["rig"]
			var p: Node = fr["player"]
			var h: VRHumanPose = fr["human"]
			var extras: VRRigExtras = rig["extras"]
			for i in int(6.0 / DT):
				h.set_arms(deg_to_rad(-5.0))
				fly_frame(rig, h)
			var burst := float(st[3]) / float(st[1])
			var cycle := burst + float(st[4])
			var n := int(cycle * 6.0 / DT)
			var over10 := 0
			var peak := 0.0
			var a_peak := 0.0
			var t := 0.0
			for i in n:
				t += DT
				var ph := fmod(t, cycle)
				if ph < burst:
					h.set_arms(deg_to_rad(-5.0 + float(st[0]) * sin(TAU * float(st[1]) * ph)), 0.0, deg_to_rad(float(st[2])))
				else:
					h.set_arms(deg_to_rad(-5.0))
				var s := fly_frame(rig, h)
				peak = maxf(peak, s)
				over10 += 1 if s > 0.10 else 0
				a_peak = maxf(a_peak, extras.vignette.accel / (rig["origin"] as XROrigin3D).world_scale)
			var tag := "%s %s" % [sp, sname]
			rows[tag] = {"peak": snappedf(peak, 0.001), "frac_over_0.10": snappedf(float(over10) / n, 0.001),
				"accel_peak_perceived": snappedf(a_peak, 0.1), "mode": p.call("mode_name"), "proximity": snappedf(extras.vignette.proximity, 0.001)}
			print("[vr] flight rig vignette %s: %s" % [tag, str(rows[tag])])
			eq(p.call("mode_name"), "flying", "%s: still flying" % tag)
			lt(float(over10) / n, 0.15, "%s: narrowed > 0.10 for < 15 %% of flap/glide flight (%.1f %%)" % [tag, 100.0 * over10 / n])
			lt(peak, 0.05, "%s: in open sky not even a visible edge (peak %.3f)" % [tag, peak])
			await free_rig(rig)
	# Near a surface: a sparrow glides straight along a cliff face 0.6 m to
	# its right (4.3 perceived m) and keeps the full view (fix round 4: no
	# optic-flow term), then folds into a dive there, and the dive's
	# acceleration narrows the view.
	var cliff := StaticBody3D.new()
	cliff.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 600.0, 2000.0)
	cs.shape = box
	cliff.add_child(cs)
	cliff.position = Vector3(0.6 + 0.2, 150.0, 0.0)
	add_child(cliff)
	var fr2: Dictionary = await flying_rig("sparrow", 300.0)
	var rig2: Dictionary = fr2["rig"]
	var h2: VRHumanPose = fr2["human"]
	var p2: Node = fr2["player"]
	await wait_physics(2)
	var glide_peak := 0.0
	for i in int(2.0 / DT):
		glide_peak = maxf(glide_peak, fly_frame(rig2, h2))
	var dive_peak := 0.0
	var acc_term := 0.0
	var v2: ComfortVignette = (rig2["extras"] as VRRigExtras).vignette
	h2.set_arms(deg_to_rad(-85.0))
	for i in int(2.0 / DT):
		dive_peak = maxf(dive_peak, fly_frame(rig2, h2))
		acc_term = maxf(acc_term, v2.model.accel_term)
	rows["sparrow dive along a cliff"] = {"peak": snappedf(dive_peak, 0.001), "accel_term_peak": snappedf(acc_term, 0.001),
		"nearest_m": snappedf(v2.nearest, 0.01), "proximity": snappedf(v2.proximity, 0.001), "glide_peak_before": snappedf(glide_peak, 0.001),
		"speed": snappedf(((p2.get("model") as Object).call("airspeed") as float), 0.01)}
	print("[vr] flight rig vignette sparrow dive along a cliff: %s" % str(rows["sparrow dive along a cliff"]))
	lt(glide_peak, 0.05, "gliding straight along the cliff keeps the full view (peak %.3f)" % glide_peak)
	gt(dive_peak, 0.15, "a sparrow diving along a cliff narrows the view (peak %.3f)" % dive_peak)
	gt(acc_term, 0.3, "and the dive's acceleration counts there (term %.2f)" % acc_term)
	await free_rig(rig2)
	cliff.queue_free()
	metric("vignette_on_flights_player", rows)
