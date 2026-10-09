extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens): whose calibration does the
## player actually fly with? Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_integ
## Flight's REAL PlayerBird (scenes/player/player.tscn) perched on a branch,
## auto-calibration on (as in the game), a ScriptedPoseSource driving the rig
## nodes, and scenes/vr/vr_rig_extras.tscn attached under the XROrigin3D the
## way VR.md tells integration to. The player holds "spread your wings" with
## the arms 12° low (a natural style; VR.md §2.3 says VR's capture no
## longer depends on it). Both WingInput and VRCalibration can capture; VR
## adopts flight's capture if flight is first (fix round 1). Which one ends
## up in flight's WingCalibration, and does it carry VR's refinements
## (shoulder height from body proportions)?

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0

var fx: Variant


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	XRServer.world_scale = 1.0


func _run_capture(arm_deg: float, tremor_mm: float = 0.0) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(&"sparrow", func(w: World) -> void: w.add_perch(Vector3(0, 10, 0)))
	var p: PlayerBird = fx.player
	p.auto_calibrate = true
	p.drive_world_scale = false
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for a in b.arms:
			a.dihedral = arm_deg * DEG
	fx.body.tremor_mm = tremor_mm
	fx.body.tremor_hz = 9.0
	p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 10.05, 0)))
	var extras := EXTRAS.instantiate() as VRRigExtras
	var store := MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).store = store
	p.origin.add_child(extras)
	await wait_frames(2)
	var vc := extras.calibration
	vc.auto_tick = false
	var vr_captured := [0]
	vc.calibrator.captured.connect(func(_k: StringName) -> void: vr_captured[0] += 1)
	var modes := {}
	for i in int(round(3.0 / DT)):
		fx.step()
		vc.tick(DT)
		modes[p.mode_name()] = true
	var res: Resource = p.wing_input.calibration
	var body: HumanPoseModel = fx.body
	var true_drop := body.head_transform().origin.y - body.shoulder(0).y
	var out := {"modes": modes.keys(), "vr_captured": vr_captured[0], "vr_calibrated": vc.calibrator.calibrated,
		"flight_calibrated": res.get("calibrated"), "flight_drop": snappedf(float(res.get("shoulder_drop")), 0.001),
		"vr_drop": snappedf(vc.calibrator.shoulder_drop, 0.001), "true_drop": snappedf(true_drop, 0.001),
		"persisted": not (store.call("get_value", "wing_calibration", {}) as Dictionary).is_empty()}
	# What VR's own capture would have measured from the same held pose.
	var solo := WingCalibrator.new()
	solo.auto_capture_allowed = true
	for i in int(round(2.5 / DT)):
		var hd := body.head_transform()
		solo.measure(hd, body.hand_transform(0), body.hand_transform(1), 7, DT)
	out["vr_solo_drop"] = snappedf(solo.shoulder_drop, 0.001)
	# The same half fold (arms 20° low, elbows 105°) read through the
	# calibration the player flies with, and through VR's own.
	body.set_airplane()
	for a in body.arms:
		a.dihedral = -20.0 * DEG
		a.elbow = 105.0 * DEG
	var flying := WingCalibrator.new()
	flying.read_from(res)
	for i in 12:
		var hd := body.head_transform()
		flying.measure(hd, body.hand_transform(0), body.hand_transform(1), 7, DT)
		solo.measure(hd, body.hand_transform(0), body.hand_transform(1), 7, DT)
	out["half_fold_flies"] = [snappedf(flying.extension[0], 0.001), snappedf(flying.pitch_command(), 0.001)]
	out["half_fold_vr_solo"] = [snappedf(solo.extension[0], 0.001), snappedf(solo.pitch_command(), 0.001)]
	extras.queue_free()
	fx.teardown()
	fx = null
	return out


func test_whose_calibration_the_player_flies_with() -> void:
	var rows := {}
	for arm in [-12.0, -5.0, 8.0]:
		var r: Dictionary = await _run_capture(arm)
		rows["arms %+d°" % int(arm)] = r
		print("[vr-verify] arms %+.0f°: %s" % [arm, str(r)])
		check("perched" in r["modes"], "arms %+.0f°: the bird sat on the perch (the capture gate was open)" % arm)
		check(bool(r["flight_calibrated"]), "arms %+.0f°: the player got calibrated" % arm)
		check(bool(r["persisted"]), "arms %+.0f°: the calibration was persisted" % arm)
		# VR.md §2.3 / §9 #4: the shoulder height no longer depends on how
		# high the arms were held (VR's own capture: within 5 mm).
		lt(absf(float(r["flight_drop"]) - float(r["true_drop"])), 0.03,
			"arms %+.0f°: the shoulder height the player FLIES with is within 3 cm of the body's (flight %.3f, VR-solo %.3f, true %.3f)" % [
			arm, r["flight_drop"], r["vr_solo_drop"], r["true_drop"]])
	metric("r2x_whose_calibration", rows)
	var ext := []
	var pit := []
	for k in rows:
		ext.append(float(rows[k]["half_fold_flies"][0]))
		pit.append(float(rows[k]["half_fold_flies"][1]))
	print("[vr-verify] half fold as flown across capture arm heights: ext %s pitch %s" % [str(ext), str(pit)])
	lt(ext.max() - ext.min(), 0.04, "the half fold the player flies reads the same extension whatever the arm height at capture (VR.md: < 0.04)")
	lt(pit.max() - pit.min(), 0.02, "and the same pitch command (VR.md: <= 0.001 after the fix)")


## With a physiological hand tremor (flight's own bot model: 9 Hz), who wins?
func test_who_captures_with_hand_tremor() -> void:
	var rows := {}
	for tr in [0.3, 1.5]:
		var r: Dictionary = await _run_capture(8.0, tr)
		rows["tremor %.1f mm" % tr] = r
		print("[vr-verify] arms +8°, tremor %.1f mm: %s" % [tr, str(r)])
	metric("r2x_who_captures_with_tremor", rows)
	var a: Array = rows["tremor 0.3 mm"]["half_fold_flies"]
	var b: Array = rows["tremor 1.5 mm"]["half_fold_flies"]
	lt(absf(float(a[0]) - float(b[0])), 0.04, "a steady and a trembling player who hold the same pose read the same half fold (ext %.2f vs %.2f; VR captured %d vs %d times)" % [
		a[0], b[0], rows["tremor 0.3 mm"]["vr_captured"], rows["tremor 1.5 mm"]["vr_captured"]])
