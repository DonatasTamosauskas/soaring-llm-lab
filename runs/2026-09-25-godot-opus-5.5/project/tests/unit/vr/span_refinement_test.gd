extends TestCase
## V3, fix round 4 (the lead's direction; a verifier's major): the arm span
## is learnt ONLY from a genuine spread-arms pose. Round 3 set the persisted
## span to any grip-to-grip distance wider than it for 0.5 s, so a
## controller set down on a table 2 m away made the bird 23 % smaller,
## changed every extension reading and could leave a standing player
## "seated"; a spread in the pause menu did the same.
##
## Every scenario runs the real service (VRCalibration.tick with a private
## store, so the game-state gate is the production one) on a synthetic
## 1.6 m player (VRHumanPose) at the Quest's 72 Hz, and asserts on what
## is persisted and on what the game then reads: the span, the extension
## of the same half fold, the bird's size (world_scale) and the seated
## flag. Written against the service's public behaviour only, so the same
## file also shows how the round-3 code failed it.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 72.0

var _rng := RandomNumberGenerator.new()


func before_all() -> void:
	XRServer.world_scale = 1.0


func before_each() -> void:
	_rng.seed = 4242
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)


func after_all() -> void:
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)


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
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "store": store}


func free_rig(rig: Dictionary) -> void:
	(rig["node"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()


## Holds the body's pose for `seconds` (0.5 mm tracker noise). Overrides
## replace a controller's transform (lying on a table, held by someone
## else); `per_tick` (Callable(i)) may change the pose each tick.
func hold(rig: Dictionary, h: VRHumanPose, seconds: float, overrides: Dictionary = {}, per_tick: Callable = Callable()) -> void:
	for i in int(round(seconds / DT)):
		if per_tick.is_valid():
			per_tick.call(i)
		var k := 0.0005
		var hd := h.head_transform()
		(rig["camera"] as Node3D).transform = hd
		for s in 2:
			var x: Transform3D = overrides[s] if overrides.has(s) else h.hand_transform(s)
			x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			(rig["hands"][s] as Node3D).transform = x
		(rig["node"] as VRCalibration).tick(DT)


## A standing player, calibrated by holding the spread (the calibration
## step).
func calibrated_player(span: float) -> Dictionary:
	var rig := make(MemoryStore.new())
	var h := VRHumanPose.for_span(span)
	h.spread_pose()
	(rig["node"] as VRCalibration).start_manual()
	hold(rig, h, 2.0)
	# Arms relaxed down: the capture's own hold is over.
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.5)
	rig["human"] = h
	return rig


func cal_of(rig: Dictionary) -> WingCalibrator:
	return (rig["node"] as VRCalibration).calibrator


func saved_span(rig: Dictionary) -> float:
	return float((rig["store"] as Object).call("get_value", "wing_calibration", {}).get("arm_span", 0.0))


## What the game reads from the calibration: the span (persisted too), the
## same half fold's extension, a sparrow's world_scale, the seated flag.
func readings(rig: Dictionary) -> Dictionary:
	var cal := cal_of(rig)
	var h: VRHumanPose = rig["human"]
	h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
	hold(rig, h, 0.3)
	var half := 0.5 * (cal.extension[0] + cal.extension[1])
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	return {"span": cal.arm_span, "saved": saved_span(rig), "half_fold": half,
		"sparrow_ws": WorldScaleDriver.target_scale(0.03, cal.arm_span), "seated": cal.is_seated()}


func same_readings(before: Dictionary, after: Dictionary, what: String) -> void:
	near(float(after["span"]), float(before["span"]), 1e-4, "%s: the span is unchanged (%.3f -> %.3f)" % [what, before["span"], after["span"]])
	near(float(after["saved"]), float(before["saved"]), 1e-4, "%s: the persisted span is unchanged (%.3f -> %.3f)" % [what, before["saved"], after["saved"]])
	near(float(after["half_fold"]), float(before["half_fold"]), 0.01, "%s: the same half fold reads the same extension (%.3f -> %.3f)" % [what, before["half_fold"], after["half_fold"]])
	near(float(after["sparrow_ws"]), float(before["sparrow_ws"]), 1e-4, "%s: the bird keeps its size (world_scale %.4f -> %.4f)" % [what, before["sparrow_ws"], after["sparrow_ws"]])
	eq(bool(after["seated"]), bool(before["seated"]), "%s: the seated flag is unchanged" % what)


## Everyday VR moments with the grips far apart, near or together, none of
## them a spread of longer arms: the stored span must not move.
func test_everyday_moments_never_change_the_span() -> void:
	var rows := {}
	# 1. A controller set down on a table (hip height) 1.8 / 2.0 / 2.15 m
	#    from the other grip for 4 s (adjusting the strap, a drink), then a
	#    normal spread, then 6 s looking down with a 15 cm knee dip, then
	#    standing (the verifier's r4x_span_inflation scenario).
	for dist in [1.8, 2.0, 2.15]:
		var rig := calibrated_player(1.6)
		var h: VRHumanPose = rig["human"]
		var before := readings(rig)
		var lg := h.hand_transform(0).origin
		var table := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(lg.x + dist * 0.98, 0.75, lg.z - dist * 0.2))
		hold(rig, h, 4.0, {1: table})
		h.spread_pose()
		hold(rig, h, 3.0)
		h.set_arms(deg_to_rad(-80.0))
		hold(rig, h, 0.3)
		h.head_pitch = deg_to_rad(-40.0)
		h.room_offset = Vector3(0.0, -0.15, 0.0)
		hold(rig, h, 6.0)
		h.head_pitch = 0.0
		h.room_offset = Vector3.ZERO
		hold(rig, h, 1.0)
		var after := readings(rig)
		same_readings(before, after, "controller on a table %.2f m away" % dist)
		rows["table_%.2f" % dist] = after
		free_rig(rig)
	# 2. The same controller on a shelf at shoulder height 2 m from the
	#    other grip while that arm is spread (the worst case: one real
	#    spread arm and a far, still, level controller).
	var rig2 := calibrated_player(1.6)
	var h2: VRHumanPose = rig2["human"]
	var b2 := readings(rig2)
	h2.spread_pose()
	var lg2 := h2.hand_transform(0).origin
	var shelf := Transform3D(h2.hand_transform(1).basis, Vector3(lg2.x + 2.0, lg2.y, lg2.z))
	for n in 3:
		hold(rig2, h2, 2.0, {1: shelf})
		hold(rig2, h2, 0.3, {1: Transform3D(shelf.basis, shelf.origin + Vector3(0, -0.5, 0))})
	same_readings(b2, readings(rig2), "controller on a shoulder-high shelf, the other arm spread")
	free_rig(rig2)
	# 3. Handing a controller to someone standing 2 m away: the player's
	#    left arm points at them, they hold the right controller at chest
	#    height and sway slowly (5 cm/s), for 6 s.
	var rig3 := calibrated_player(1.6)
	var h3: VRHumanPose = rig3["human"]
	var b3 := readings(rig3)
	h3.spread_pose()
	var lg3 := h3.hand_transform(0).origin
	var other := func(i: int) -> Dictionary:
		var sway := 0.05 * sin(TAU * 0.25 * i * DT)
		return {1: Transform3D(Basis.IDENTITY, Vector3(lg3.x + 2.0 + sway, 1.25, lg3.z + 0.3))}
	for i in int(6.0 / DT):
		hold(rig3, h3, DT, other.call(i))
	same_readings(b3, readings(rig3), "a controller handed to someone else")
	free_rig(rig3)
	# 4. Controllers held together: in front of the chest, and both in the
	#    left hand with that arm stretched out to the side.
	var rig4 := calibrated_player(1.6)
	var h4: VRHumanPose = rig4["human"]
	var b4 := readings(rig4)
	h4.set_arms(deg_to_rad(-30.0), deg_to_rad(20.0), 0.0, deg_to_rad(165.0))
	hold(rig4, h4, 3.0)
	h4.spread_pose()
	for n in 3:
		hold(rig4, h4, 1.5, {1: h4.hand_transform(0)})
		hold(rig4, h4, 0.3, {1: h4.hand_transform(0).translated(Vector3(0, -0.4, 0))})
	same_readings(b4, readings(rig4), "controllers held together")
	free_rig(rig4)
	# 5. Turning around with the arms spread: fast (180° in 1.2 s, three
	#    times) and slowly (180° in 16 s): the body frame follows, the
	#    spread is the player's own, nothing grows.
	var rig5 := calibrated_player(1.6)
	var h5: VRHumanPose = rig5["human"]
	var b5 := readings(rig5)
	h5.spread_pose()
	for n in 3:
		var y0 := h5.torso_yaw
		hold(rig5, h5, 1.2, {}, func(i: int) -> void: h5.torso_yaw = y0 + PI * minf(1.0, (i + 1) * DT / 1.2))
		hold(rig5, h5, 0.6)
	var y1 := h5.torso_yaw
	hold(rig5, h5, 16.0, {}, func(i: int) -> void: h5.torso_yaw = y1 + PI * minf(1.0, (i + 1) * DT / 16.0))
	h5.torso_yaw = 0.0
	same_readings(b5, readings(rig5), "turning around with the arms spread")
	free_rig(rig5)
	# 6. Stretching: arms raised overhead and wide, and reaching forward to
	#    grab something, several times.
	var rig6 := calibrated_player(1.6)
	var h6: VRHumanPose = rig6["human"]
	var b6 := readings(rig6)
	for n in 3:
		h6.set_arms(deg_to_rad(60.0))
		hold(rig6, h6, 1.5)
		h6.set_arms(deg_to_rad(0.0), deg_to_rad(70.0))
		hold(rig6, h6, 1.5)
		h6.set_arms(deg_to_rad(-80.0))
		hold(rig6, h6, 0.3)
	same_readings(b6, readings(rig6), "stretching overhead and reaching forward")
	free_rig(rig6)
	metric("everyday_moments", rows)


## Tracking errors during otherwise genuine spreads of the true span: the
## right controller jumping 40 cm outward for two ticks every 0.3 s, and a
## slow drift (an occluded controller's prediction) bulging 7 cm outward
## over 1.2 s, slowly enough to pass the hand-speed gate. A spread
## is its 80th-percentile sample, never one frame's (or a short bulge's)
## maximum.
func test_tracking_glitches_do_not_count() -> void:
	var rig := calibrated_player(1.6)
	var h: VRHumanPose = rig["human"]
	var before := readings(rig)
	h.spread_pose()
	for n in 3:
		for i in int(1.5 / DT):
			var o := {}
			if i % 22 < 2:
				var x := h.hand_transform(1)
				o[1] = Transform3D(x.basis, x.origin + Vector3(0.4, 0.0, 0.0))
			hold(rig, h, DT, o)
		h.set_arms(deg_to_rad(-80.0))
		hold(rig, h, 0.3)
		h.spread_pose()
	same_readings(before, readings(rig), "tracking glitches in a real spread")
	# The slow bulge, in each of three separate 3 s spreads: it rises and
	# falls over 1.2 s (at most 0.18 m/s, under the hand-speed gate), so
	# every sample of it counts, and it is over 5 cm (the growth margin)
	# for 14 % of each spread: the maximum would grow the span, the 80th
	# percentile does not.
	for n in 3:
		for i in int(3.0 / DT):
			var t := i * DT - 0.9
			var bump := 0.07 * (0.5 - 0.5 * cos(TAU * clampf(t / 1.2, 0.0, 1.0)))
			var x := h.hand_transform(1)
			hold(rig, h, DT, {1: Transform3D(x.basis, x.origin + Vector3(bump, 0.0, 0.0))})
		h.set_arms(deg_to_rad(-80.0))
		hold(rig, h, 0.3)
		h.spread_pose()
	same_readings(before, readings(rig), "a slow 7 cm tracking drift in a real spread")
	free_rig(rig)


## Never while the game is not being played: the pause menu (tree paused),
## a paused tree while the state still says PLAYING, the main menu, and an
## unfocused / removed headset. A player 25 cm
## longer-armed than the calibration spreads twice in each (someone else
## trying the headset on in the menu, or the player stretching there).
func test_no_refinement_in_menus_or_unfocused() -> void:
	var rows := {}
	for where in ["pause menu", "tree paused while PLAYING", "main menu", "unfocused"]:
		var rig := calibrated_player(1.5)
		var h: VRHumanPose = rig["human"]
		var before := readings(rig)
		var other := VRHumanPose.for_span(1.75)
		other.eye_height = h.eye_height
		match where:
			"pause menu":
				Game.set_state(Game.State.PLAYING)
				Game.set_state(Game.State.PAUSED)
				check(get_tree().paused, "(setup) the tree is paused")
			"tree paused while PLAYING":
				# Something paused the tree without Game.PAUSED (a dialog, a
				# dev scene): paused is paused.
				Game.set_state(Game.State.PLAYING)
				get_tree().paused = true
			"main menu":
				Game.set_state(Game.State.MENU)
			"unfocused":
				VR.active = true
				VR.focused = false
		for n in 3:
			other.spread_pose()
			hold(rig, other, 1.5)
			other.set_arms(deg_to_rad(-80.0))
			hold(rig, other, 0.3)
		VR.active = false
		get_tree().paused = false
		Game.set_state(Game.State.BOOT)
		var after := readings(rig)
		same_readings(before, after, where)
		rows[where] = after["span"]
		free_rig(rig)
	metric("menus", rows)


## A real spread still refines: a player who calibrated with soft elbows
## (the capture read a span 8 cm short) spreads fully. One spread is not
## enough; two separate ones are, and the span becomes the true one
## (within 1 cm); the growth is persisted and reaches the game at once.
func test_real_spreads_refine_the_span() -> void:
	var rig := make(MemoryStore.new())
	var h := VRHumanPose.for_span(1.7)
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(35.0))
	(rig["node"] as VRCalibration).start_manual()
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.5)
	rig["human"] = h
	var cal := cal_of(rig)
	var cramped := cal.arm_span
	gt(h.arm_span - cramped, 0.05, "(setup) the capture read the span short (%.3f vs %.3f)" % [cramped, h.arm_span])
	# One full spread (1 s), then the arms down.
	h.set_arms(deg_to_rad(-3.0))
	hold(rig, h, 1.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	near(cal.arm_span, cramped, 1e-6, "one spread alone does not change it")
	# A second, separate spread (a glide, arms a little lower).
	h.set_arms(deg_to_rad(-10.0))
	hold(rig, h, 1.2)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	near(cal.arm_span, h.arm_span, 0.01, "two separate spreads: the true span (%.3f, true %.3f)" % [cal.arm_span, h.arm_span])
	near(saved_span(rig), cal.arm_span, 1e-6, "and it is persisted")
	metric("refined", {"cramped": cramped, "refined": cal.arm_span, "true": h.arm_span})
	free_rig(rig)


## One session grows the span by 10 cm at most (a capture far too cramped
## is corrected over sessions; an odd event can never run away with it); a
## reload starts a new session; a manual recalibration resets the span to
## whoever holds the spread now (a smaller second player included: the
## span never shrinks on its own).
func test_growth_is_bounded_per_session_and_recalibration_resets() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var h := VRHumanPose.for_span(1.8)
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(62.0))
	(rig["node"] as VRCalibration).start_manual()
	hold(rig, h, 2.0)
	rig["human"] = h
	var cal := cal_of(rig)
	var span0 := cal.arm_span
	gt(h.arm_span - span0, 0.15, "(setup) a very cramped capture (%.3f vs %.3f)" % [span0, h.arm_span])
	var spreads := func(r: Dictionary, n: int) -> void:
		for i in n:
			h.set_arms(deg_to_rad(-4.0))
			hold(r, h, 1.0)
			h.set_arms(deg_to_rad(-80.0))
			hold(r, h, 0.3)
	spreads.call(rig, 4)
	near(cal.arm_span, span0 + 0.10, 1e-4, "one session: at most +10 cm (%.3f -> %.3f)" % [span0, cal.arm_span])
	free_rig(rig)
	# A new session (the game restarted): the persisted span loads, and it
	# may grow another 10 cm.
	var rig2 := make(store)
	var cal2 := cal_of(rig2)
	near(cal2.arm_span, span0 + 0.10, 1e-4, "reloaded")
	spreads.call(rig2, 3)
	near(cal2.arm_span, minf(h.arm_span, span0 + 0.20), 0.01, "next session: grows on (%.3f, true %.3f)" % [cal2.arm_span, h.arm_span])
	# A smaller player recalibrates (Settings > Recalibrate wings).
	var small := VRHumanPose.for_span(1.5)
	(rig2["node"] as VRCalibration).start_manual()
	small.spread_pose()
	hold(rig2, small, 2.0)
	near(cal2.arm_span, 1.5, 0.01, "a manual recalibration resets the span to the new player (%.3f)" % cal2.arm_span)
	near(saved_span(rig2), cal2.arm_span, 1e-6, "and persists it")
	# The first player's wide spreads belong to the old session: one spread
	# of the new player's own arms must not bring them back.
	var span_small := cal2.arm_span
	small.set_arms(deg_to_rad(-80.0))
	hold(rig2, small, 0.3)
	small.set_arms(deg_to_rad(-4.0))
	hold(rig2, small, 1.0)
	small.set_arms(deg_to_rad(-80.0))
	hold(rig2, small, 0.3)
	near(cal2.arm_span, span_small, 1e-4, "the previous player's spreads no longer count (%.3f)" % cal2.arm_span)
	free_rig(rig2)


## Seated detection is bounded by the standing eyes measured at the capture
## (the verifier: "seated thresholds bounded by the measured standing eye
## height rather than a span-derived stature"). A long-armed player (span
## 1.90 m, stature 1.76 m: ape index 1.08) dipping 15 cm and looking down
## at prey for 6 s is not seated; sitting down is detected; standing up
## again is too. Round 3's thresholds came from the span alone: the dip
## read as seated and "standing again" sat above this player's own eyes,
## so the flag never cleared.
func test_seated_is_bounded_by_the_standing_eyes() -> void:
	var rig := make(MemoryStore.new())
	var h := VRHumanPose.for_span(1.9)
	h.eye_height = 0.935 * 1.76
	h.shoulder_drop = 0.15 * 1.76
	h.spread_pose()
	(rig["node"] as VRCalibration).start_manual()
	hold(rig, h, 2.0)
	rig["human"] = h
	var cal := cal_of(rig)
	check(cal.calibrated and not cal.is_seated(), "(setup) calibrated standing")
	h.set_arms(deg_to_rad(-30.0))
	h.head_pitch = deg_to_rad(-40.0)
	h.room_offset = Vector3(0.0, -0.15, 0.0)
	hold(rig, h, 6.0)
	check(not cal.is_seated(), "a 15 cm dip looking down at prey for 6 s: still standing")
	h.head_pitch = 0.0
	h.room_offset = Vector3.ZERO
	hold(rig, h, 1.0)
	# Sits on a chair (eyes 0.455 + 0.44 x stature).
	h.eye_height = 0.455 + 0.44 * 1.76
	hold(rig, h, 5.5)
	check(cal.is_seated(), "sitting down: seated after 5 s")
	h.eye_height = 0.935 * 1.76
	hold(rig, h, 5.5)
	check(not cal.is_seated(), "standing up again: standing after 5 s")
	free_rig(rig)
