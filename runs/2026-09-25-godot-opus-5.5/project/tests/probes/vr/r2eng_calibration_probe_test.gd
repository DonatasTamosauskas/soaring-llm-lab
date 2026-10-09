extends TestCase
## VERIFIER PROBE (vr, round 2, engineering/contract lens). Not part of the
## area suite; run with
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2eng_
## Checks fix-round-1 calibration claims against the flight area's real
## PlayerBird (scenes/player/player.tscn), in the frame order the game
## runs: flight's physics tick, then VR's _process tick. Persistence goes
## to a private memory store (never user://settings.cfg). Outputs of the
## verifier's runs: artifacts/vr/verify/r2eng/.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const DT := 1.0 / 72.0


## Flight's real rig with the VR extras attached as VR.md tells integration.
func make_flight_rig(store: Object) -> Dictionary:
	var ps := load("res://scenes/player/player.tscn") as PackedScene
	var player := ps.instantiate() as Node3D
	player.set("use_settings", false)
	player.set("default_source", &"none")
	player.set("auto_process", false)
	player.position = Vector3(0, 20, 0)
	add_child(player)
	var origin := player.get_node("XROrigin3D") as XROrigin3D
	var extras := EXTRAS.instantiate() as VRRigExtras
	var cal := extras.get_node("Calibration") as VRCalibration
	cal.store = store
	cal.auto_tick = false
	cal.show_prompt = false
	origin.add_child(extras)
	await wait_frames(3)
	# XR poses read from the rig's nodes, as in the headset.
	var src := XRPoseSource.new(origin, origin.get_node("XRCamera3D"), origin.get_node("LeftHand"), origin.get_node("RightHand"))
	src.assume_tracked = true
	player.call("set_pose_source", src)
	player.set("mode", 3)   # GROUNDED: both flight's and VR's capture gates are open
	return {"player": player, "origin": origin, "extras": extras, "cal": cal}


func drive_nodes(rig: Dictionary, h: VRHumanPose) -> void:
	var origin: XROrigin3D = rig["origin"]
	var ws := origin.world_scale
	var hd := h.head_transform()
	(origin.get_node("XRCamera3D") as Node3D).transform = Transform3D(hd.basis, hd.origin * ws)
	for side in 2:
		var x := h.hand_transform(side)
		(origin.get_node("LeftHand" if side == 0 else "RightHand") as Node3D).transform = Transform3D(x.basis, x.origin * ws)


## Who captures the first automatic neutral in the game, and is that the
## capture the fix round made pose-independent? A 1.75 m player holds the
## "spread your wings" pose 8 deg high (one of VR.md's natural capture
## styles). Flight's WingInput and VR's VRCalibration both auto-capture in
## GROUNDED/PERCHED/SPAWNING; if flight wins, VR adopts flight's §5.10
## capture (arms-5-deg-low drop, raw neutral) and the canonical-neutral and
## anthropometric-drop refinements never reach the game.
func test_first_capture_race_on_the_flight_rig() -> void:
	# Tracker jitter 0.05 mm (a steady hand; the simulator's controllers
	# are perfectly still). Control: the textbook capture (arms 5 deg low)
	# must agree, so the probe measures only the capture-style dependence.
	var ctl: Dictionary = await race(-5.0, 0.05)
	lt(absf(float(ctl["game"][0]) - float(ctl["vr"][0])), 0.02, "(control) textbook capture: game and VR maths agree on extension")
	lt(absf(float(ctl["game"][1]) - float(ctl["vr"][1])), 0.02, "(control) textbook capture: game and VR maths agree on pitch")
	var worst_ext := 0.0
	var worst_pitch := 0.0
	for elev in [-12.0, 0.0, 8.0]:
		var r: Dictionary = await race(elev, 0.05)
		worst_ext = maxf(worst_ext, absf(float(r["game"][0]) - float(ctl["vr"][0])))
		worst_pitch = maxf(worst_pitch, absf(float(r["game"][1]) - float(ctl["vr"][1])))
	metric("style_worst_game_ext_vs_textbook", worst_ext)
	metric("style_worst_game_pitch_vs_textbook", worst_pitch)
	lt(worst_ext, 0.04, "VR.md claim 'capture style alone moves extension < 0.04' holds for the calibration the game uses (%.3f)" % worst_ext)
	lt(worst_pitch, 0.08, "VR.md claim 'capture style alone moves pitch < 0.08' holds for the calibration the game uses (%.3f)" % worst_pitch)


## One first-launch automatic capture on flight's real rig with the arms
## held elev_deg from level; returns the half-fold readings of the game's
## resulting calibration and of VR's own maths for the same hold.
func race(elev_deg: float, noise_mm: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var store := MemoryStore.new()
	var rig := await make_flight_rig(store)
	var cal: VRCalibration = rig["cal"]
	var player: Node3D = rig["player"]
	var res: Object = (player.get("wing_input") as Object).get("calibration")
	check(res != null and not bool(res.get("calibrated")), "(setup) flight uncalibrated")
	check(not cal.calibrator.calibrated, "(setup) VR uncalibrated")
	var vr_own := [false]
	cal.calibrator.captured.connect(func(k: StringName) -> void:
		if k == &"neutral":
			vr_own[0] = true)
	var h := VRHumanPose.for_span(1.75)
	h.set_arms(deg_to_rad(elev_deg))
	var t_flight := -1.0
	var t_vr := -1.0
	var t := 0.0
	# Tracker jitter in TRACKING metres (the rig's nodes are x world_scale).
	var noisy := func(x: Transform3D, ws: float) -> Transform3D:
		var k := noise_mm * 0.001 * ws
		return Transform3D(x.basis, x.origin + Vector3(rng.randfn(0, k), rng.randfn(0, k), rng.randfn(0, k)))
	for i in int(3.0 / DT):
		drive_nodes(rig, h)
		for n in ["XRCamera3D", "LeftHand", "RightHand"]:
			var nd := (rig["origin"] as Node).get_node(n) as Node3D
			nd.transform = noisy.call(nd.transform, (rig["origin"] as XROrigin3D).world_scale)
		player.call("tick", DT)            # physics: flight first
		player.set("mode", 3)
		cal.tick(DT)                       # then VR's _process
		t += DT
		if t_flight < 0.0 and bool(res.get("calibrated")) and not vr_own[0]:
			t_flight = t
		if t_vr < 0.0 and cal.calibrator.calibrated:
			t_vr = t
	print("[vr-probe] elev %+.0f noise %.2f: VR blocker '%s' speed %.3f/%.3f ang %.1f/%.1f deg/s, flight status %s, mode %s" % [elev_deg, noise_mm,
		cal.calibrator.neutral_blocker(), cal.calibrator.hand_speed[0], cal.calibrator.hand_speed[1],
		rad_to_deg(cal.calibrator.hand_ang_speed[0]), rad_to_deg(cal.calibrator.hand_ang_speed[1]),
		str(player.call("calibration_status")), str(player.call("mode_name"))])
	var tag := "elev%+.0f" % elev_deg
	metric(tag + "_flight_captured_at_s", t_flight)
	metric(tag + "_vr_calibrated_at_s", t_vr)
	metric(tag + "_vr_captured_itself", vr_own[0])
	check(cal.calibrator.calibrated, "%s: VR ended calibrated" % tag)
	# The same hold captured by VR's own maths (what the fix round claims).
	var ref := WingCalibrator.new()
	ref.auto_capture_allowed = true
	for i in int(2.5 / DT):
		ref.measure(noisy.call(h.head_transform(), 1.0), noisy.call(h.hand_transform(0), 1.0), noisy.call(h.hand_transform(1), 1.0), 7, DT)
	check(ref.calibrated, "(reference) VR's own maths capture the same hold")
	var true_drop := h.shoulder_drop
	var game_drop := float(res.get("shoulder_drop"))
	metric(tag + "_true_drop", true_drop)
	metric(tag + "_vr_maths_drop", ref.shoulder_drop)
	metric(tag + "_game_drop", game_drop)
	# Half fold read by a calibrator carrying the game's calibration vs VR's own.
	var game_cal := WingCalibrator.new()
	game_cal.read_from(res)
	var fold := func(c: WingCalibrator) -> Array:
		h.dihedral = [deg_to_rad(-20.0), deg_to_rad(-20.0)]
		h.sweep = [0.0, 0.0]
		h.twist = [0.0, 0.0]
		h.elbow = [deg_to_rad(105.0), deg_to_rad(105.0)]
		for i in 10:
			c.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)
		return [c.extension[0], c.pitch_command()]
	var g: Array = fold.call(game_cal)
	var r: Array = fold.call(ref)
	metric(tag + "_half_fold_game_ext_pitch", g)
	metric(tag + "_half_fold_vr_maths_ext_pitch", r)
	# What flight's own WingInput reads for that half fold (the flight input).
	for i in int(1.0 / DT):
		drive_nodes(rig, h)
		player.call("tick", DT)
		player.set("mode", 3)
	var ws_state: Object = player.call("wing_state")
	var fl := [float(ws_state.get("ext_l")), rad_to_deg(float(ws_state.get("twist_l"))), float(ws_state.get("pitch"))]
	metric(tag + "_half_fold_flight_ext_twistdeg_pitch", fl)
	player.queue_free()
	await wait_frames(2)
	XRServer.world_scale = 1.0
	return {"game": g, "vr": r, "vr_own": vr_own[0], "game_drop": game_drop, "vr_drop": ref.shoulder_drop, "flight": fl}


## Contract note (ARCHITECTURE 2026-09-26 vr fix round 1): "Live seated
## written into flight's resource is detected OR the Settings preference
## (the persisted dict keeps only the detected flag)." Flight's loader ORs
## the preference into its resource (player_bird.gd _load_calibration), so
## when VR adopts flight's capture it reads the preference back as
## "detected", persists it, and the player can no longer switch seated off.
func test_adoption_keeps_the_seated_preference_out_of_the_saved_dict() -> void:
	var store := MemoryStore.new()
	store.set_value("seated", true)          # the player prefers seated play
	var p := StubPlayer.new()
	p.mode_label = "perched"
	var res := CalMock.new()
	# Flight captured a standing player; its loader ORed Settings.seated in.
	res.set("arm_span", 1.7)
	res.set("seated", true)
	res.set("calibrated", true)
	p.calibration = res
	add_child(p)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	add_child(node)
	node.tick(DT)
	check(node.calibrator.calibrated, "(setup) VR adopted flight's capture")
	var saved: Dictionary = store.get_value("wing_calibration", {})
	metric("saved_seated", saved.get("seated", null))
	check(not bool(saved.get("seated", false)), "the persisted dict keeps only the detected flag (standing player): seated=%s" % str(saved.get("seated")))
	# The player turns seated play off.
	store.set_value("seated", false)
	Events.settings_changed.emit("seated", false)
	check(not node.calibrator.is_seated(), "switching the preference off leaves seated mode (is_seated=%s)" % str(node.calibrator.is_seated()))
	node.queue_free()
	remove_child(p)
	p.free()
	await wait_frames(2)


## B (right) held 0.8 s is documented as a pause "only while PLAYING/CAUGHT"
## (VR.md §2.2, ARCHITECTURE); the code also includes BOOT.
func test_b_hold_is_a_pause_only_in_play() -> void:
	var c := VRControls.new()
	c.auto_tick = false
	var inputs := {}
	c.reader = func(hand: StringName, action: StringName) -> Variant: return inputs.get("%s/%s" % [hand, action], null)
	add_child(c)
	var n := [0]
	var cb := func() -> void: n[0] += 1
	Events.menu_requested.connect(cb)
	var old := Game.state
	Game.state = Game.State.BOOT
	inputs["right_hand/by_button"] = true
	for i in 90:
		c.tick(1.0 / 90.0)
	metric("menu_requests_in_boot", n[0])
	eq(n[0], 0, "BOOT is not play: a long B press requests no menu")
	Game.state = old
	Events.menu_requested.disconnect(cb)
	c.queue_free()


## Who wins the first-capture race depends on tracker jitter (flight's
## calm test differentiates raw positions; VR's smooths them, tau 0.15 s).
## Metrics only: which calibration the game ends up with at each jitter.
func test_race_noise_sweep() -> void:
	for n in [0.0, 0.02, 0.05, 0.1, 0.2, 0.5, 0.7]:
		var r: Dictionary = await race(8.0, n)
		metric("noise_%.2fmm_vr_captured_itself" % n, r["vr_own"])
		metric("noise_%.2fmm_game_half_fold_ext_pitch" % n, r["game"])
	check(true, "sweep ran")
