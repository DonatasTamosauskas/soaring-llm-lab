extends TestCase
## Re-verification round 3, experience lens: the fix-round-6 wearer check.
##
## The builder's flare test holds the landing flare perfectly still on the
## perch, and its "same player" re-dons vary within elbows 0-6° soft and
## arms ±8°. Real people standing on a perch reading a card sway, shift
## their weight and lift drooping arms. These probes ask:
##   1. Does ONE ordinary movement while still holding the flare (a weight
##      shift, lifting drooping arms back up) count as the "break" the card
##      asks for ("Lower your arms, then ..."), so that the flare itself
##      answers the prompt and becomes "flat" (the round-5 major)?
##   2. How often does the SAME player get the card when their re-don hold
##      varies within the capture-style box the calibration suite itself
##      calls realistic (arms 12° low .. 8° high, hands up to 10° forward,
##      elbows up to 15° soft, floor ±3 cm, a glance)?
## Only core contracts, VR classes and the VR suite's own mocks are used.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0
const PITCH_TOL := 0.02

var _rng := RandomNumberGenerator.new()


func before_all() -> void:
	XRServer.world_scale = 1.0


func before_each() -> void:
	_rng.seed = 90210
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.user_present = true
	VR.presence_supported = false


func after_all() -> void:
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.focused = false
	VR.user_present = true
	VR.presence_supported = false
	VR.session_state = "none"


class _WingInputHook:
	extends RefCounted
	var calibration: Resource
	var replaced := 0

	func calibration_replaced() -> void:
		replaced += 1


func make(store: Object) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	var p := StubPlayer.new()
	p.mode_label = "perched"
	var wi := _WingInputHook.new()
	wi.calibration = CalMock.new()
	p.wing_input = wi
	add_child(p)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	var events := {"rechecked": [], "asked": []}
	node.calibrator.rechecked.connect(func(replaced: bool) -> void: (events["rechecked"] as Array).append(replaced))
	node.calibrator.check_wanted.connect(func(why: String) -> void: (events["asked"] as Array).append(why))
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "store": store, "player": p,
		"wing_input": wi, "events": events}


func free_rig(rig: Dictionary) -> void:
	(rig["node"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()
	var p: Node = rig["player"]
	remove_child(p)
	p.free()


func cal_of(rig: Dictionary) -> WingCalibrator:
	return (rig["node"] as VRCalibration).calibrator


func node_of(rig: Dictionary) -> VRCalibration:
	return rig["node"] as VRCalibration


func hold(rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		var k := 0.0005
		var hd := h.head_transform()
		(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin + Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)))
		for s in 2:
			var x := h.hand_transform(s)
			x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			(rig["hands"][s] as Node3D).transform = x
		(rig["node"] as VRCalibration).tick(DT)


func wearer(span: float, habit_deg: Array = [0.0, 0.0]) -> VRHumanPose:
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(habit_deg[0]), deg_to_rad(habit_deg[1])]
	return h


func manual_with_glide(rig: Dictionary, h: VRHumanPose) -> void:
	node_of(rig).start_manual()
	h.spread_pose()
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-55.0), 0.0, 0.0, deg_to_rad(20.0))
	hold(rig, h, 3.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 3.0)


func flat_reading(rig: Dictionary, h: VRHumanPose) -> Dictionary:
	var cal := cal_of(rig)
	var keep := h.room_offset
	h.room_offset = Vector3.ZERO
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(10.0))
	hold(rig, h, 0.3)
	var out := {"pitch": cal.pitch_command(), "twist_deg": rad_to_deg(0.5 * (cal.twist[0] + cal.twist[1]))}
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	h.room_offset = keep
	return out


## Moves the whole body (a weight shift: head and hands together) by
## `offset` over `seconds`, linearly, holding the arm pose.
func shift_body(rig: Dictionary, h: VRHumanPose, offset: Vector3, seconds: float) -> void:
	var start := h.room_offset
	var n := int(round(seconds / DT))
	for i in n:
		h.room_offset = start + offset * (float(i + 1) / float(n))
		hold(rig, h, DT)


## Raises both arms by `deg` of dihedral over `seconds` (lifting drooping
## arms back up), holding the wrists.
func lift_arms(rig: Dictionary, h: VRHumanPose, deg: float, seconds: float) -> void:
	var d0 := [h.dihedral[0], h.dihedral[1]]
	var n := int(round(seconds / DT))
	for i in n:
		var f := float(i + 1) / float(n)
		h.dihedral = [d0[0] + deg_to_rad(deg) * f, d0[1] + deg_to_rad(deg) * f]
		hold(rig, h, DT)


## 1. One ordinary movement while the flare is still held answers the card
## with the flare. The card says "Lower your arms, then spread your wings,
## hands flat"; the code (WingCalibrator.check_needs_break) takes ANY
## neutral blocker for one tick as the break, including "hold still".
## Scenario (the builder's own, from wearer_test): one player, manual flow
## with a glide step, the headset taken off and put back on, glide in,
## flare, perch, hold the flare 4 s (the card comes up). Then, still
## holding the flare, one of: nothing (control), a weight shift of 4 cm
## over 0.3 s, lifting arms that drooped 3° back up over 0.25 s. Then the
## flare is held 2 s more. Expected (the fix round's promise): the
## calibration is untouched and flat wrists read what they did.
func test_a_flare_answers_its_own_question_after_one_ordinary_movement() -> void:
	var rows := {}
	var worst_pitch := 0.0
	var replaced_by_flare := 0
	var cases := 0
	for flare in [10.0, 15.0, 20.0]:
		for move in ["none (control)", "weight shift 4 cm / 0.3 s", "drooped arms lifted 3° / 0.25 s"]:
			var store := MemoryStore.new()
			var rig := make(store)
			var a := wearer(1.72, [5.0, 5.0])
			manual_with_glide(rig, a)
			var ref := flat_reading(rig, a)
			var cal := cal_of(rig)
			var node := node_of(rig)
			var p: Object = rig["player"]
			var writes0: int = store.writes
			p.set("mode_label", "flying")
			Game.set_state(Game.State.PLAYING)
			VR._on_user_presence_changed(false)
			VR._on_user_presence_changed(true)
			Game.set_state(Game.State.PLAYING)
			check(cal.recapture_armed, "(setup) headset on arms the re-check")
			a.set_arms(deg_to_rad(-10.0), 0.0, 0.0, deg_to_rad(10.0))
			hold(rig, a, 2.0)
			a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(flare), deg_to_rad(5.0))
			hold(rig, a, 0.5)
			p.set("mode_label", "perched")
			hold(rig, a, 4.0)
			var asked := node.flow == VRCalibration.Flow.CHECK
			var text_before := node.prompt_text()
			match move:
				"weight shift 4 cm / 0.3 s":
					shift_body(rig, a, Vector3(0.04, 0.0, 0.0), 0.3)
				"drooped arms lifted 3° / 0.25 s":
					# The arms sagged 3° while reading, then are lifted back.
					a.dihedral = [deg_to_rad(-8.0), deg_to_rad(-8.0)]
					hold(rig, a, 1.0)
					lift_arms(rig, a, 3.0, 0.25)
			var text_after := node.prompt_text()
			hold(rig, a, 2.0)
			var ev: Dictionary = rig["events"]
			var replaced: bool = not (ev["rechecked"] as Array).is_empty() and (ev["rechecked"] as Array).back() == true
			# Relax, take off, and fly with flat wrists.
			a.set_arms(deg_to_rad(-80.0))
			a.room_offset = Vector3.ZERO
			hold(rig, a, 3.5)
			var now := flat_reading(rig, a)
			var dp := absf(float(now["pitch"]) - float(ref["pitch"]))
			worst_pitch = maxf(worst_pitch, dp)
			cases += 1
			if replaced:
				replaced_by_flare += 1
			var tag := "flare %.0f°, %s" % [flare, move]
			rows[tag] = {"asked": asked, "card_before": text_before.replace("\n", " "), "card_after_move": text_after.replace("\n", " "),
				"replaced": replaced, "flat_pitch_before": snappedf(float(ref["pitch"]), 0.0001),
				"flat_pitch_after": snappedf(float(now["pitch"]), 0.0001), "flat_twist_after_deg": snappedf(float(now["twist_deg"]), 0.01),
				"writes": store.writes - writes0}
			print("[vr-probe] %s: %s" % [tag, str(rows[tag])])
			check(asked, "%s: (setup) the flare raised the card" % tag)
			check(not replaced, "%s: the flare never replaces the calibration" % tag)
			lt(dp, PITCH_TOL, "%s: flat wrists command the same pitch (%.3f -> %.3f)" % [tag, float(ref["pitch"]), float(now["pitch"])])
			Game.set_state(Game.State.BOOT)
			get_tree().paused = false
			free_rig(rig)
	metric("flare_after_movement", rows)
	metric("flare_after_movement_replaced", "%d of %d" % [replaced_by_flare, cases])
	metric("flare_after_movement_worst_pitch", worst_pitch)


## 2. The same player (manual flow, glide step, a 6° habit) re-dons 60
## times with holds drawn from the calibration suite's own realistic
## capture-style box: arms 12° low .. 8° high, hands 0-10° forward, elbows
## 0-15° soft, the floor ±3 cm, a wrist roll of sigma 1.5°, a glance at a
## hand every third time. The brief is about ONE player: the card should
## be rare for them. Recorded: kept / asked, and which bound asked.
## Asserted: kept at once in >= 80 % (the builder's own bar in wearer_test
## is 95 % for a narrower box).
func test_same_player_card_rate_over_the_realistic_style_box() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var a := wearer(1.72, [6.0, 6.0])
	manual_with_glide(rig, a)
	var cal := cal_of(rig)
	var node := node_of(rig)
	var kept := 0
	var asked := 0
	var why := {}
	var worst_elbow_kept := 0.0
	var asked_rows := []
	for k in 60:
		VR._on_user_presence_changed(false)
		VR._on_user_presence_changed(true)
		Game.set_state(Game.State.BOOT)
		get_tree().paused = false
		var dih := _rng.randf_range(-12.0, 8.0)
		var sw := _rng.randf_range(0.0, 10.0)
		var el := _rng.randf_range(0.0, 15.0)
		var floor_dy := _rng.randf_range(-0.03, 0.03)
		var rl := _rng.randfn(0.0, 1.5)
		var rr := _rng.randfn(0.0, 1.5)
		var glance := deg_to_rad(_rng.randf_range(-35.0, 35.0)) if k % 3 == 0 else 0.0
		a.room_offset = Vector3(0.0, floor_dy, 0.0)
		a.twist_offset = [deg_to_rad(6.0 + rl), deg_to_rad(6.0 + rr)]
		a.head_yaw = glance
		a.set_arms(deg_to_rad(dih), deg_to_rad(sw), 0.0, deg_to_rad(el))
		var ev: Dictionary = rig["events"]
		var n_r := (ev["rechecked"] as Array).size()
		var n_a := (ev["asked"] as Array).size()
		var t := 0.0
		var got := "nothing"
		while t < 4.0:
			hold(rig, a, 0.05)
			t += 0.05
			if (ev["asked"] as Array).size() > n_a:
				got = "asked"
				break
			if (ev["rechecked"] as Array).size() > n_r:
				got = "replaced" if (ev["rechecked"] as Array).back() else "kept"
				break
		if got == "kept":
			kept += 1
			worst_elbow_kept = maxf(worst_elbow_kept, el)
		elif got == "asked":
			asked += 1
			var w: String = (ev["asked"] as Array).back()
			why[w] = int(why.get(w, 0)) + 1
			asked_rows.append({"dihedral": snappedf(dih, 0.1), "sweep": snappedf(sw, 0.1), "elbow": snappedf(el, 0.1),
				"floor_cm": snappedf(floor_dy * 100.0, 0.1), "roll": [snappedf(rl, 0.1), snappedf(rr, 0.1)], "why": w})
		# Arms down; the card (if any) is ignored and times out or is
		# dismissed by the next take-off.
		a.head_yaw = 0.0
		a.set_arms(deg_to_rad(-80.0))
		hold(rig, a, 0.3)
		node.dismiss_check("probe: next re-don")
		check(cal.calibrated, "re-don %d: still calibrated" % k)
	metric("same_player_card_rate", {"kept": kept, "asked": asked, "why": why})
	metric("same_player_asked_rows", asked_rows)
	print("[vr-probe] same player, style box: kept %d, asked %d %s" % [kept, asked, str(why)])
	for r in asked_rows:
		print("[vr-probe]   asked: %s" % str(r))
	gt(float(kept) / 60.0, 0.8 - 1e-6, "the same player is kept at once in >= 80 %% of re-dons over the style box (kept %d / 60)" % kept)
	free_rig(rig)


## 1b. How small a movement is enough: a weight shift of d cm over T s
## while the 15° flare is held on the perch with the card up (then 2 s of
## the flare). Recorded (not asserted): which ones answer the card with the
## flare. The card's own words ask for the arms to be LOWERED.
func test_movement_threshold_for_the_break() -> void:
	var table := {}
	for d_cm in [1.0, 2.0, 3.0, 4.0, 6.0]:
		for secs in [0.2, 0.4, 0.8]:
			var store := MemoryStore.new()
			var rig := make(store)
			var a := wearer(1.72, [5.0, 5.0])
			manual_with_glide(rig, a)
			var node := node_of(rig)
			var p: Object = rig["player"]
			p.set("mode_label", "flying")
			Game.set_state(Game.State.PLAYING)
			VR._on_user_presence_changed(false)
			VR._on_user_presence_changed(true)
			Game.set_state(Game.State.PLAYING)
			a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(15.0), deg_to_rad(5.0))
			hold(rig, a, 0.5)
			p.set("mode_label", "perched")
			hold(rig, a, 4.0)
			var asked := node.flow == VRCalibration.Flow.CHECK
			shift_body(rig, a, Vector3(d_cm * 0.01, 0.0, 0.0), secs)
			hold(rig, a, 2.0)
			var ev: Dictionary = rig["events"]
			var replaced: bool = not (ev["rechecked"] as Array).is_empty() and (ev["rechecked"] as Array).back() == true
			var key := "%.0f cm / %.1f s (%.2f m/s)" % [d_cm, secs, d_cm * 0.01 / secs]
			table[key] = {"asked": asked, "flare became flat": replaced}
			check(not replaced, "weight shift %s with the flare held: the flare does not answer the card" % key)
			Game.set_state(Game.State.BOOT)
			get_tree().paused = false
			free_rig(rig)
	metric("break_threshold", table)
	for k in table:
		print("[vr-probe] weight shift %s: %s" % [k, str(table[k])])


## 3. Seated play (the brief's seated mode, detected, preference off): a
## seated player who calibrated seated re-dons 20 times (wrist roll sigma
## 1.5°, elbows 0-6°, arms ±8°, chair height ±1.5 cm). They should be kept
## silently like a standing player (the builder's bar: 95 %).
func test_seated_player_redons_are_kept() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var a := VRHumanPose.for_span(1.70, true)
	a.twist_offset = [deg_to_rad(4.0), deg_to_rad(4.0)]
	# Sit for 6 s (detection), then the manual flow.
	a.set_arms(deg_to_rad(-80.0))
	hold(rig, a, 6.0)
	manual_with_glide(rig, a)
	var cal := cal_of(rig)
	check(cal.is_seated(), "(setup) detected seated")
	var kept := 0
	var asked := []
	for k in 20:
		VR._on_user_presence_changed(false)
		VR._on_user_presence_changed(true)
		Game.set_state(Game.State.BOOT)
		a.room_offset = Vector3(0.0, _rng.randf_range(-0.015, 0.015), 0.0)
		a.twist_offset = [deg_to_rad(4.0 + _rng.randfn(0.0, 1.5)), deg_to_rad(4.0 + _rng.randfn(0.0, 1.5))]
		var dih := _rng.randf_range(-13.0, 3.0)
		var el := _rng.randf_range(0.0, 6.0)
		a.set_arms(deg_to_rad(dih), 0.0, 0.0, deg_to_rad(el))
		var ev: Dictionary = rig["events"]
		var n_r := (ev["rechecked"] as Array).size()
		var n_a := (ev["asked"] as Array).size()
		var t := 0.0
		var got := "nothing"
		while t < 4.0:
			hold(rig, a, 0.05)
			t += 0.05
			if (ev["asked"] as Array).size() > n_a:
				got = "asked " + str((ev["asked"] as Array).back())
				break
			if (ev["rechecked"] as Array).size() > n_r:
				got = "replaced" if (ev["rechecked"] as Array).back() else "kept"
				break
		if got == "kept":
			kept += 1
		else:
			asked.append({"k": k, "got": got, "dihedral": snappedf(dih, 0.1), "elbow": snappedf(el, 0.1)})
		a.set_arms(deg_to_rad(-80.0))
		hold(rig, a, 0.3)
		node_of(rig).dismiss_check("probe")
	metric("seated_redons", {"kept": kept, "other": asked})
	print("[vr-probe] seated re-dons kept %d / 20, others %s, still seated %s" % [kept, str(asked), str(cal.is_seated())])
	check(cal.is_seated(), "still seated after the re-dons")
	gt(float(kept) / 20.0, 0.95 - 1e-6, "a seated player's re-dons are kept silently (%d / 20)" % kept)
	free_rig(rig)


## 1c. Two more non-answers while the 15° flare is held with the card up:
## one frame of lost controller tracking (the "tracking" blocker), and a
## head turn to read the card (no hand motion: control).
func test_flare_with_a_tracking_blip_or_a_glance() -> void:
	var rows := {}
	for what in ["one frame of lost tracking", "a 30° glance at the card (control)"]:
		var store := MemoryStore.new()
		var rig := make(store)
		var a := wearer(1.72, [5.0, 5.0])
		manual_with_glide(rig, a)
		var node := node_of(rig)
		var p: Object = rig["player"]
		p.set("mode_label", "flying")
		Game.set_state(Game.State.PLAYING)
		VR._on_user_presence_changed(false)
		VR._on_user_presence_changed(true)
		Game.set_state(Game.State.PLAYING)
		a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(15.0), deg_to_rad(5.0))
		hold(rig, a, 0.5)
		p.set("mode_label", "perched")
		hold(rig, a, 4.0)
		var asked := node.flow == VRCalibration.Flow.CHECK
		if what.begins_with("one frame"):
			node.force_valid = false
			hold(rig, a, DT)
			node.force_valid = true
		else:
			for i in 20:
				a.head_yaw = deg_to_rad(30.0) * float(i + 1) / 20.0
				hold(rig, a, DT)
		hold(rig, a, 2.0)
		var ev: Dictionary = rig["events"]
		var replaced: bool = not (ev["rechecked"] as Array).is_empty() and (ev["rechecked"] as Array).back() == true
		rows[what] = {"asked": asked, "flare became flat": replaced}
		print("[vr-probe] %s: %s" % [what, str(rows[what])])
		check(asked, "%s: (setup) card up" % what)
		check(not replaced, "%s: the held flare does not answer the card" % what)
		a.head_yaw = 0.0
		Game.set_state(Game.State.BOOT)
		get_tree().paused = false
		free_rig(rig)
	metric("flare_blips", rows)
