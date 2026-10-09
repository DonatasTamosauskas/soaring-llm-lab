extends TestCase
## V5/V7/V8 lifecycle: the rig extras placed AWAY from the rig (found by the
## "player_rig" group) outlive the rig itself. Its own file: the group
## lookup and Birds.player() must see exactly one rig and one player at a
## time, which pause_test's shared rig would break.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")


func after_all() -> void:
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false


## The extras placed away from the rig (the group lookup; e.g. a sibling in
## main.tscn, the easy editor path since player.tscn is an instanced scene)
## and the rig REPLACED: a respawn or new run deletes the player and adds a
## new one. The wings and the vignette were moved onto the old rig and die
## with it; the new rig gets new ones, the calibration draws its glow on
## them, and the world-scale driver drives the new rig (growth). Fix round
## 6 (engineering verifier): try_attach assigned the freed wings, stopped
## with a SCRIPT ERROR before wiring the world-scale driver, and never
## retried: no wings, no vignette, no growth for the rest of the session.
## Both deletions: freed at once, and queued (the new rig added in the
## same frame, while the old one is still in the "player_rig" group).
func test_rig_replaced_while_the_extras_live_elsewhere() -> void:
	var extras := EXTRAS.instantiate() as VRRigExtras
	(extras.get_node("Calibration") as VRCalibration).store = MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).persist = false
	var r := Env.build_rig(self, Vector3(60, 40, 0), null, false, false, true, false)
	add_child(extras)
	await wait_frames(3)
	eq(extras.origin, r["origin"], "(setup) the extras found the first rig by its group")
	check(extras.wings.get_parent() == r["origin"], "(setup) the wings moved onto it")
	var rows := {}
	for how in ["freed", "queued, new rig in the same frame"]:
		var old_wings := extras.wings
		var old_vignette := extras.vignette
		var old: Node = r["player"]
		if how == "freed":
			remove_child(old)
			old.free()
			await wait_frames(2)
			check(extras.origin == null, "%s: (setup) no rig in between" % how)
		else:
			old.queue_free()
		r = Env.build_rig(self, Vector3(60, 60, 0), null, false, false, true, false)
		var o: XROrigin3D = r["origin"]
		# Re-attached within a couple of frames (a respawn must not leave the
		# player wingless until the 0.5 s retry): the new rig entering the
		# tree ("freed"), or the old one going ("queued").
		await wait_frames(3)
		# Freed with the old rig, or (an attach while the old rig was only
		# queued) carried over to the new one: never a stray pair.
		check((not is_instance_valid(old_wings) or old_wings == extras.wings) and (not is_instance_valid(old_vignette) or old_vignette == extras.vignette),
			"%s: the old parts went with the old rig or moved to the new one" % how)
		eq(extras.origin, o, "%s: the extras attach to the new rig" % how)
		var w := extras.wings
		var v := extras.vignette
		check(is_instance_valid(w) and w.is_inside_tree() and w.get_parent() == o, "%s: the new rig has first-person wings" % how)
		if not (is_instance_valid(w) and is_instance_valid(v)):
			return
		check(w.visible and w.is_processing(), "%s: shown and laid out" % how)
		check(w.origin == o and w.calibrator == extras.calibration.calibrator, "%s: wired to the rig and the calibrator" % how)
		check(v.is_inside_tree() and v.get_parent() == r["camera"], "%s: and the comfort vignette on its camera" % how)
		check(v.origin == o and v.is_physics_processing(), "%s: measuring the new rig's motion" % how)
		eq(extras.calibration.wings, w, "%s: the calibration glow goes to the new wings" % how)
		eq(extras.calibration.origin, o, "%s: the calibration reads the new rig" % how)
		eq(extras.world_scale_driver.origin, o, "%s: the world-scale driver drives the new rig" % how)
		# Growth on the new rig: an eagle's mass moves its world_scale target.
		var t0 := extras.world_scale_driver.target
		(r["player"] as Bird).mass = 3.0
		await wait_physics(3)
		var t1 := extras.world_scale_driver.target
		gt(t1, t0 * 3.0, "%s: growth reaches the new rig (target %.3f -> %.3f)" % [how, t0, t1])
		rows[how] = {"target": [snappedf(t0, 0.001), snappedf(t1, 0.001)]}
	metric("replaced_rig", rows)
	# An attach in the very frame of a respawn: the old rig is still in the
	# "player_rig" group, queued for deletion (its player was queue_free'd,
	# not the origin under it); the live one is taken.
	(r["player"] as Node).queue_free()
	var r3 := Env.build_rig(self, Vector3(60, 80, 0), null, false, false, true, false)
	check(extras.try_attach(), "same frame as a respawn: an attach finds a rig")
	eq(extras.origin, r3["origin"], "the live one, not the one being deleted")
	await wait_frames(3)
	check(is_instance_valid(extras.wings) and extras.wings.get_parent() == r3["origin"], "and its wings are there")
	r = r3
	extras.queue_free()
	(r["player"] as Node).queue_free()
	await wait_frames(2)
	XRServer.world_scale = 1.0
