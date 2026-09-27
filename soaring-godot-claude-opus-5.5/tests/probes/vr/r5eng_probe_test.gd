extends TestCase
## Round-5 engineering re-verification probes for the VR area (not the
## builder's suite). Each test pins a contract / robustness claim of fix
## round 5 that the unit suite does not exercise.
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r5eng

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")
const DT := 1.0 / 72.0

var _rng := RandomNumberGenerator.new()


func after_all() -> void:
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.active = false
	VR.focused = false
	VR.user_present = true
	VR.session_state = "none"


# -----------------------------------------------------------------------------
# 1. The session wiring and the policies against the REAL engine classes.
# vr_session_test drives a hand-written stand-in (FakeRuntime) whose signal
# names and arities the builder chose; connect_interface() silently skips a
# signal the source does not have, so a misspelt name would pass that test
# and never fire in the game. Check the names and arities on OpenXRInterface.

func test_session_wiring_matches_the_real_openxr_class() -> void:
	var wiring: Array = VR._session_wiring()
	eq(wiring.size(), 12, "(setup) twelve session signals wired")
	var rows := {}
	for w in wiring:
		var sig: StringName = w[0]
		var cb: Callable = w[1]
		if not check(ClassDB.class_has_signal(&"OpenXRInterface", sig), "OpenXRInterface has signal '%s'" % sig):
			continue
		var n_args := (ClassDB.class_get_signal(&"OpenXRInterface", sig)["args"] as Array).size()
		eq(cb.get_argument_count(), n_args, "'%s': the handler takes the signal's %d argument(s)" % [sig, n_args])
		rows[str(sig)] = n_args
	metric("wiring_signal_args", rows)
	for m in ["get_available_display_refresh_rates", "set_cpu_level", "set_gpu_level", "is_foveation_supported"]:
		check(ClassDB.class_has_method(&"OpenXRInterface", m), "OpenXRInterface.%s() exists" % m)
	var props := {}
	for p in ClassDB.class_get_property_list(&"OpenXRInterface"):
		props[p["name"]] = true
	for p in ["display_refresh_rate", "foveation_level", "foveation_dynamic", "foveation_with_subsampled_images"]:
		check(props.has(p), "OpenXRInterface.%s exists" % p)


## XRSink calls trigger_haptic_pulse(action, tracker, frequency, amplitude,
## duration, delay) positionally; the unit tests use a recorder with the
## same hand-written signature. The real method's argument order decides
## whether amplitude and duration land where the sink thinks.
func test_haptic_call_matches_the_real_xr_interface() -> void:
	var found := {}
	for m in ClassDB.class_get_method_list(&"XRInterface"):
		if m["name"] == "trigger_haptic_pulse":
			found = m
	if not check(not found.is_empty(), "XRInterface.trigger_haptic_pulse exists"):
		return
	var names: Array = []
	for a in found["args"]:
		names.append(a["name"])
	metric("trigger_haptic_pulse_args", names)
	eq(names.size(), 6, "six arguments")
	if names.size() == 6:
		check(String(names[0]).contains("action"), "arg 1 is the action name (%s)" % names[0])
		check(String(names[1]).contains("tracker"), "arg 2 is the tracker (%s)" % names[1])
		check(String(names[2]).contains("freq"), "arg 3 is the frequency (%s)" % names[2])
		check(String(names[3]).contains("amplitude"), "arg 4 is the amplitude (%s)" % names[3])
		check(String(names[4]).contains("duration"), "arg 5 is the duration (%s)" % names[4])
		check(String(names[5]).contains("delay"), "arg 6 is the delay (%s)" % names[5])


## Every input VRControls / XRSink / the grip controllers read is an action
## in the project's action map and is bound on the Touch controller profile
## (the Quest Pro controllers report it; the simulator emulates it). The
## right controller has no menu click on Quest (QUEST.md §3).
func test_action_map_binds_every_input_vr_reads() -> void:
	var am := load("res://openxr_action_map.tres") as OpenXRActionMap
	if not check(am != null, "the project's action map loads"):
		return
	var defined := {}
	for aset in am.action_sets:
		for a in (aset as OpenXRActionSet).actions:
			defined[(a as OpenXRAction).resource_name] = true
	var wanted: Array[String] = ["trigger", "trigger_click", "grip", "grip_click", "haptic", "grip_pose", "aim_pose"]
	for b in VRControls.BUTTONS:
		wanted.append(String(b))
	for n in wanted:
		check(defined.has(n), "action '%s' is defined" % n)
	var touch: OpenXRInteractionProfile = null
	for ip in am.interaction_profiles:
		if (ip as OpenXRInteractionProfile).interaction_profile_path == "/interaction_profiles/oculus/touch_controller":
			touch = ip
	if not check(touch != null, "the Touch controller profile exists"):
		return
	var bound := {}
	for i in touch.get_binding_count():
		var b := touch.get_binding(i)
		var an: String = b.action.resource_name
		if not bound.has(an):
			bound[an] = []
		(bound[an] as Array).append(b.binding_path)
	metric("touch_bindings", bound)
	for n in ["menu_button", "ax_button", "by_button", "trigger", "grip", "haptic", "grip_pose"]:
		check(bound.has(n), "'%s' is bound on the Touch controller" % n)
	var menu_left := false
	for p in bound.get("menu_button", []):
		menu_left = menu_left or String(p).begins_with("/user/hand/left/")
	check(menu_left, "the left menu button is bound (the pause button)")


# -----------------------------------------------------------------------------
# 2. Rig lifecycle: the rig REPLACED (not moved) while the extras live
# elsewhere. ARCHITECTURE "vr — additive": the extras find group player_rig
# "if placed elsewhere", and VRCalibration expects "a new PlayerBird
# (respawn, new run)". The wings and vignette are moved onto the rig, so a
# freed rig frees them; the extras must then re-attach to the new rig
# cleanly (new parts or none), never call into freed objects.

func _bare_rig(at: Vector3) -> Dictionary:
	var p: Node3D = StubPlayer.new()
	p.name = "R5Rig"
	p.position = at
	var o := XROrigin3D.new()
	o.name = "XROrigin3D"
	o.add_to_group(&"player_rig")
	o.process_mode = Node.PROCESS_MODE_ALWAYS
	p.add_child(o)
	var cam := XRCamera3D.new()
	cam.name = "XRCamera3D"
	cam.position = Vector3(0, 1.6, 0)
	o.add_child(cam)
	var hands: Array[XRController3D] = []
	for side in [&"left_hand", &"right_hand"]:
		var c := XRController3D.new()
		c.name = "L" if side == &"left_hand" else "R"
		c.tracker = side
		c.pose = &"grip"
		o.add_child(c)
		hands.append(c)
	return {"player": p, "origin": o, "camera": cam, "left": hands[0], "right": hands[1]}


func test_rig_replaced_while_the_extras_live_elsewhere() -> void:
	var extras := EXTRAS.instantiate() as VRRigExtras
	(extras.get_node("Calibration") as VRCalibration).store = MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).persist = false
	add_child(extras)
	var r1 := _bare_rig(Vector3(0, 120, 0))
	add_child(r1["player"])
	await wait_seconds(0.8)
	eq(extras.origin, r1["origin"], "(setup) attached to the first rig")
	check(extras.wings.get_parent() == r1["origin"], "(setup) wings on the first rig")
	# A new run / respawn that re-instances the player: the old one is freed.
	var old: Node = r1["player"]
	remove_child(old)
	old.free()
	await wait_frames(2)
	var r2 := _bare_rig(Vector3(0, 140, 0))
	add_child(r2["player"])
	await wait_seconds(1.2)
	var attached: bool = extras.origin == r2["origin"]
	check(attached, "the extras attach to the new rig")
	var wings_ok: bool = is_instance_valid(extras.wings) and extras.wings.is_inside_tree() and extras.wings.get_parent() == r2["origin"]
	var vig_ok: bool = is_instance_valid(extras.vignette) and extras.vignette.is_inside_tree() and extras.vignette.get_parent() == r2["camera"]
	# Growth: the world-scale driver must drive the new rig (a sparrow ->
	# eagle change must move ITS world_scale target).
	var ws_ok: bool = extras.world_scale_driver.origin == r2["origin"]
	(r2["player"] as Bird).mass = 3.0
	await wait_physics(3)
	var row := {"attached": attached, "wings_on_new_rig": wings_ok, "vignette_on_new_rig": vig_ok,
		"wings_valid": is_instance_valid(extras.wings), "vignette_valid": is_instance_valid(extras.vignette),
		"world_scale_driver_on_new_rig": ws_ok, "world_scale_target_after_eagle": extras.world_scale_driver.target}
	metric("replaced_rig", row)
	print("[vr] r5eng replaced rig: %s" % str(row))
	check(wings_ok, "the new rig has first-person wings")
	check(vig_ok, "the new rig has the comfort vignette")
	check(ws_ok, "the world-scale driver (growth, near plane) drives the new rig")
	extras.queue_free()
	(r2["player"] as Node).queue_free()
	await wait_frames(2)


## The extras removed alone (parked) and then deleted while OUT of the tree
## (a scene rebuild that frees what it detached): the parts on the rig go
## with them, as they do when the extras are deleted in the tree.
func test_extras_deleted_while_parked_take_their_parts() -> void:
	var r := _bare_rig(Vector3(40, 120, 0))
	var extras := EXTRAS.instantiate() as VRRigExtras
	(extras.get_node("Calibration") as VRCalibration).store = MemoryStore.new()
	(extras.get_node("Calibration") as VRCalibration).persist = false
	(r["origin"] as Node).add_child(extras)
	add_child(r["player"])
	await wait_frames(4)
	var wings := extras.wings
	var vignette := extras.vignette
	check(wings.get_parent() == r["origin"], "(setup) wings moved onto the rig")
	(r["origin"] as Node).remove_child(extras)
	await wait_frames(2)
	extras.free()
	await wait_frames(2)
	check(not is_instance_valid(wings), "wings freed with the parked extras")
	check(not is_instance_valid(vignette), "vignette freed with the parked extras")
	(r["player"] as Node).queue_free()
	await wait_frames(2)


# -----------------------------------------------------------------------------
# 3. The wearer re-check (fix round 5) and V3's "persisted and reloaded".
# wearer_test.test_same_player_recheck_changes_nothing varies only what the
# capture maths cancels exactly (arm height, a glance, floor drift) and
# re-holds the wrists bit for bit. People do not: forearm-rotation
# repositioning errors are several degrees and a "straight" arm is not the
# same straight twice. Here the same body that did the manual flow (glide
# step included) relaunches the app and spreads its wings on the first
# perch, with small, realistic differences.

class _WingInputHook:
	extends RefCounted
	var calibration: Resource
	var replaced := 0

	func calibration_replaced() -> void:
		replaced += 1


func _make(store: Object) -> Dictionary:
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
	var events := {"rechecked": []}
	node.calibrator.rechecked.connect(func(replaced: bool) -> void: (events["rechecked"] as Array).append(replaced))
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "player": p, "events": events}


func _free(rig: Dictionary) -> void:
	(rig["node"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()
	var p: Node = rig["player"]
	remove_child(p)
	p.free()


func _hold(rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		var k := 0.0005
		var hd := h.head_transform()
		(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin + Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)))
		for s in 2:
			var x: Transform3D = h.hand_transform(s)
			x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			(rig["hands"][s] as Node3D).transform = x
		(rig["node"] as VRCalibration).tick(DT)


func _manual_with_glide(rig: Dictionary, h: VRHumanPose) -> void:
	(rig["node"] as VRCalibration).start_manual()
	h.spread_pose()
	_hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-55.0), 0.0, 0.0, deg_to_rad(20.0))
	_hold(rig, h, 3.0)
	h.set_arms(deg_to_rad(-80.0))
	_hold(rig, h, 3.0)


## Mean extension of [a half fold (arms 20° low, elbows 105°: wearer_test's
## "half_fold"), a partly bent glide (arms 30° low, elbows 80°)], held 0.4 s:
## the poses whose reading the glide step (glide_reach, fold_elevation)
## decides.
func _glide_readings(rig: Dictionary, h: VRHumanPose) -> Array:
	var cal := (rig["node"] as VRCalibration).calibrator
	var out: Array = []
	for g in [[-20.0, 105.0], [-30.0, 80.0]]:
		h.set_arms(deg_to_rad(g[0]), 0.0, 0.0, deg_to_rad(g[1]))
		_hold(rig, h, 0.4)
		out.append(snappedf(0.5 * (cal.extension[0] + cal.extension[1]), 0.0001))
	h.set_arms(deg_to_rad(-80.0))
	_hold(rig, h, 0.4)
	return out


func test_manual_calibration_survives_a_relaunch_by_the_same_player() -> void:
	_rng.seed = 424242
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.user_present = true
	# world_scale is global XRServer state: the extras of the tests above
	# left their stand-in's scale behind (poses are read divided by it).
	XRServer.world_scale = 1.0
	await wait_frames(1)
	# [wrist roll L/R deg, elbow deg] of the relaunch hold vs the manual one.
	var variants := {
		"identical hold (control)": [0.0, 0.0, 0.0],
		"wrists 1.5° apart": [1.5, -1.0, 0.0],
		"wrists 2.5° apart": [2.5, 2.0, 0.0],
		"elbows 6° soft": [0.0, 0.0, 6.0],
		"wrists 1.5°, elbows 4°": [-1.5, 1.0, 4.0],
	}
	var rows := {}
	var kept := 0
	var worst_ext := 0.0
	for name in variants:
		var v: Array = variants[name]
		var store := MemoryStore.new()
		var a := VRHumanPose.for_span(1.72)
		a.twist_offset = [deg_to_rad(6.0), deg_to_rad(6.0)]
		var rig := _make(store)
		_manual_with_glide(rig, a)
		var cal := (rig["node"] as VRCalibration).calibrator
		var reach0 := cal.glide_reach
		var fold0 := cal.fold_elevation
		check(absf(reach0 - WingCalibrator.DEFAULT_GLIDE_REACH) > 0.02, "%s: (setup) the manual glide step set the player's own reach (%.3f)" % [name, reach0])
		# The player's relaxed glide (the pose the glide step captured) and a
		# half fold, read under the manual calibration.
		var ext_before := _glide_readings(rig, a)
		_free(rig)
		# Relaunch: a new service loads the persisted dict (armed at app start).
		var rig2 := _make(store)
		var cal2 := (rig2["node"] as VRCalibration).calibrator
		near(cal2.glide_reach, reach0, 1e-6, "%s: (setup) the glide step was persisted and reloaded" % name)
		check(cal2.recapture_armed, "%s: (setup) the relaunch armed a re-check" % name)
		# The first perch: the same player spreads their wings, still and level.
		a.twist_offset = [deg_to_rad(6.0 + float(v[0])), deg_to_rad(6.0 + float(v[1]))]
		a.spread_pose()
		a.elbow = [deg_to_rad(float(v[2])), deg_to_rad(float(v[2]))]
		_hold(rig2, a, 2.0)
		a.set_arms(deg_to_rad(-80.0))
		_hold(rig2, a, 0.4)
		var ext_after := _glide_readings(rig2, a)
		var saved: Dictionary = store.get_value("wing_calibration", {})
		var ok := absf(cal2.glide_reach - reach0) < 1e-6 and absf(cal2.fold_elevation - fold0) < 1e-6 \
			and absf(float(saved.get("glide_reach", -1.0)) - reach0) < 1e-6
		rows[name] = {"rechecked_replaced": rig2["events"]["rechecked"], "glide_reach": [reach0, cal2.glide_reach],
			"saved_glide_reach": saved.get("glide_reach", -1.0), "span": cal2.arm_span, "kept": ok,
			"half_fold_ext": [ext_before[0], ext_after[0]], "bent_glide_ext": [ext_before[1], ext_after[1]]}
		worst_ext = maxf(worst_ext, maxf(absf(ext_after[0] - ext_before[0]), absf(ext_after[1] - ext_before[1])))
		if ok:
			kept += 1
		elif name == "identical hold (control)":
			fail("control: an identical hold must keep the manual calibration")
		_free(rig2)
	metric("relaunch_rows", rows)
	print("[vr] r5eng relaunch probe: %s" % JSON.stringify(rows))
	# V3 "persisted and reloaded" + "manual recalibrate works": the manual
	# glide step must survive a relaunch by the same player. Every variant
	# here is well inside how precisely people repeat a pose.
	metric("relaunch_worst_extension_change", worst_ext)
	lt(worst_ext, 0.03, "the same poses read the same extension after the relaunch (brief bar 0.03; worst %.3f)" % worst_ext)
	eq(kept, variants.size(), "the manual glide step survives the same player's first perch after a relaunch (kept %d of %d)" % [kept, variants.size()])
