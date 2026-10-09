extends TestCase
## Re-verification round 3, experience lens: a whole session of respawns
## with the rig extras placed away from the rig (fix round 6's replaced-rig
## path). The builder's rig_lifecycle_test replaces the rig twice, awake,
## with no calibration card up. A run has many respawns: some while the
## pause menu is open (a restart from the menu), one while the calibration
## card is showing. After every respawn the NEW rig must have exactly one
## pair of wings, one vignette on its camera, the card (if a flow runs) on
## the new rig, and nothing may pile up (orphans, stray wings or cards).

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")


func after_all() -> void:
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false


func _count(cls: String) -> int:
	var n := 0
	for x in get_tree().root.find_children("*", cls, true, false):
		if not (x as Node).is_queued_for_deletion():
			n += 1
	return n


func test_a_session_of_respawns_with_the_extras_elsewhere() -> void:
	var extras := EXTRAS.instantiate() as VRRigExtras
	var cal := extras.get_node("Calibration") as VRCalibration
	cal.store = MemoryStore.new()
	cal.persist = false
	var r := Env.build_rig(self, Vector3(60, 40, 0), null, false, false, true, false)
	add_child(extras)
	await wait_frames(3)
	eq(extras.origin, r["origin"], "(setup) attached to the first rig")
	var orphans0 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var rows := []
	for k in 8:
		var how := "freed" if k % 2 == 0 else "queued"
		var paused := k == 3 or k == 4
		var with_card := k == 5
		if paused:
			Game.set_state(Game.State.PAUSED)
		if with_card:
			cal.start_manual()
			await wait_frames(3)
			check(cal.prompt != null and is_instance_valid(cal.prompt) and cal.prompt.get_parent() == r["origin"],
				"respawn %d: (setup) the card is up on the old rig" % k)
		var old: Node = r["player"]
		if how == "freed":
			remove_child(old)
			old.free()
			await wait_frames(1)
		else:
			old.queue_free()
		r = Env.build_rig(self, Vector3(60, 40 + 10 * k, 0), null, false, false, true, false)
		await wait_frames(4)
		var o: XROrigin3D = r["origin"]
		var w := extras.wings
		var v := extras.vignette
		var ok_w: bool = is_instance_valid(w) and w.is_inside_tree() and w.get_parent() == o and w.visible and w.is_processing()
		var ok_v: bool = is_instance_valid(v) and v.is_inside_tree() and v.get_parent() == r["camera"] and v.is_physics_processing()
		var tag := "respawn %d (%s%s%s)" % [k, how, ", paused" if paused else "", ", card up" if with_card else ""]
		check(ok_w, "%s: the new rig has live wings" % tag)
		check(ok_v, "%s: and the vignette on its camera" % tag)
		eq(_count("FirstPersonWings"), 1, "%s: exactly one pair of first-person wings in the tree" % tag)
		eq(_count("ComfortVignette"), 1, "%s: exactly one vignette in the tree" % tag)
		check(_count("CalibrationPrompt") <= 1, "%s: at most one calibration card in the tree" % tag)
		eq(extras.world_scale_driver.origin, o, "%s: growth drives the new rig" % tag)
		if with_card:
			check(cal.is_running(), "%s: the manual flow is still running" % tag)
			var cards := get_tree().root.find_children("*", "CalibrationPrompt", true, false)
			var on_new: bool = not cards.is_empty() and (cards[0] as Node).get_parent() == o and (cards[0] as Node3D).visible
			check(on_new, "%s: the card shows on the NEW rig (the player was told to hold a pose)" % tag)
			rows.append({"respawn": k, "card_on_new_rig": on_new, "cards": cards.size()})
			cal.cancel()
			await wait_frames(2)
		if paused:
			Game.set_state(Game.State.PLAYING)
			Game.set_state(Game.State.BOOT)
		rows.append({"respawn": k, "wings": ok_w, "vignette": ok_v, "fpw": _count("FirstPersonWings"), "vig": _count("ComfortVignette")})
	await wait_frames(3)
	var orphans1 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	metric("respawns", rows)
	metric("orphans_delta", orphans1 - orphans0)
	print("[vr-probe] respawn session: %s, orphans %d -> %d" % [str(rows), orphans0, orphans1])
	lt(orphans1 - orphans0, 1.0, "no orphan nodes pile up over 8 respawns (%d -> %d)" % [orphans0, orphans1])
	extras.queue_free()
	(r["player"] as Node).queue_free()
	await wait_frames(2)
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	XRServer.world_scale = 1.0
