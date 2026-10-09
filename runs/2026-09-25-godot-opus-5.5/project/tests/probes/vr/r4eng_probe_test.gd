extends TestCase
## Round-4 engineering verifier probes for the VR area (not the builder's
## suite). Each test pins a claim from docs/areas/VR.md or the builder's
## report that the unit suite does not exercise.
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r4eng

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const Env := preload("res://scenes/dev/vr_dev_env.gd")


static func _basis_finite(b: Basis) -> bool:
	for v in [b.x, b.y, b.z]:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			return false
	return true


static func _vec_finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


## VR.md §2.3 / report: "A corrupt saved value (NaN, INF) keeps the
## default" and "a NaN or infinite ... span can no longer reach the rig".
## The scalar fields are guarded; are the saved neutral bases and axes?
func test_corrupt_saved_basis_never_reaches_flight() -> void:
	var nan_b := Basis(Vector3(NAN, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	var d := {"version": 1, "calibrated": true, "arm_span": 1.7,
		"neutral_left": nan_b, "forearm_axis_right": Vector3(NAN, 0, 0), "chord_axis_left": [INF, 0.0, 0.0]}
	var store := MemoryStore.new()
	store.set_value("wing_calibration", d)
	var p: Bird = StubPlayer.new()
	p.set("mode_label", "perched")
	p.set("calibration", CalMock.new())
	add_child(p)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	add_child(node)
	var c := node.calibrator
	# Finite is not enough: a rotation (det 1) and unit axes.
	check(absf(c.neutral[0].determinant() - 1.0) < 1e-3, "neutral_left is still a rotation after a corrupt load (det %.3f)" % c.neutral[0].determinant())
	near(c.forearm_axis[1].length(), 1.0, 1e-3, "forearm_axis_right is still a unit axis after a corrupt load")
	near(c.chord_axis[0].length(), 1.0, 1e-3, "chord_axis_left is still a unit axis after a corrupt load")
	check(c.calibrated, "(the corrupt dict still says calibrated: no automatic capture will repair it)")
	var fin := _basis_finite(c.neutral[0]) and _vec_finite(c.forearm_axis[1]) and _vec_finite(c.chord_axis[0])
	metric("calibrator_neutral_left", str(c.neutral[0]))
	metric("calibrator_forearm_axis_right", str(c.forearm_axis[1]))
	metric("calibrator_chord_axis_left", str(c.chord_axis[0]))
	check(fin, "corrupt saved neutral / axes keep the defaults (neutral_left %s, forearm_axis_right %s, chord_axis_left %s)" % [c.neutral[0], c.forearm_axis[1], c.chord_axis[0]])
	var res: Resource = p.get("calibration")
	var pushed_ok := _basis_finite(res.get("neutral_left")) and _vec_finite(res.get("forearm_axis_right")) and _vec_finite(res.get("chord_axis_left"))
	check(pushed_ok, "nothing non-finite pushed into flight's WingCalibration (neutral_left %s)" % str(res.get("neutral_left")))
	# What the wrist twist then reads (flight reads the same fields).
	# A 20° leading-edge-up roll on both wrists: does each side still read it?
	var h := VRHumanPose.for_span(1.7)
	h.spread_pose()
	h.twist = [deg_to_rad(20.0), deg_to_rad(20.0)]
	for i in 12:
		c.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, 1.0 / 90.0)
	metric("twist_deg_for_20deg_roll_after_corrupt_load", [rad_to_deg(c.twist[0]), rad_to_deg(c.twist[1])])
	check(is_finite(c.twist[0]) and is_finite(c.twist[1]), "twist stays finite after a corrupt load (%s)" % str(c.twist))
	near(rad_to_deg(c.twist[1]), 20.0, 5.0, "the right wrist (corrupt forearm axis) still reads a 20° roll")
	# Control: the same probe on a calibrator loaded from a clean dict reads it.
	var clean := WingCalibrator.new()
	clean.from_dict({"version": 1, "calibrated": true, "arm_span": 1.7})
	for i in 12:
		clean.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, 1.0 / 90.0)
	metric("control_twist_deg_clean_dict", [rad_to_deg(clean.twist[0]), rad_to_deg(clean.twist[1])])
	near(rad_to_deg(clean.twist[1]), 20.0, 5.0, "(control) a clean dict reads the 20° roll")
	node.queue_free()
	remove_child(p)
	p.free()


## VR.md §2.2 / V8 (pause_test docstring): "a pausable node already under
## it" is corrected by the attach alone. The builder's test builds no such
## node; build one before the deferred attach runs.
func test_pausable_node_present_at_attach_is_corrected() -> void:
	var r := Env.build_rig(self, Vector3(80, 3, 0), MemoryStore.new(), false, false, false)
	var origin: XROrigin3D = r["origin"]
	var bad := Node3D.new()
	bad.name = "PreexistingPausable"
	bad.process_mode = Node.PROCESS_MODE_PAUSABLE
	(r["camera"] as Node).add_child(bad)
	await wait_frames(3)
	eq(bad.process_mode, Node.PROCESS_MODE_ALWAYS, "a PAUSABLE node under the rig before the attach is set to ALWAYS")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.PAUSED)
	check(bad.can_process(), "and processes while paused")
	check(origin.can_process(), "the origin processes while paused")
	Game.set_state(Game.State.PLAYING)
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	(r["player"] as Node).queue_free()
	await wait_frames(1)
	XRServer.world_scale = 1.0


## Haptics: telemetry stall_warning below the documented 0.6 must not
## buffet; above it must (VR.md §2.7: "stalled / stall_warning > 0.6").
func test_stall_warning_threshold() -> void:
	var p: Bird = StubPlayer.new()
	add_child(p)
	var h := VRHaptics.new()
	h.listen_to_events = false
	h.auto_tick = false
	h.intensity_override = 1.0
	var sent := [0]
	h.sink = null
	h.pulse_sent.connect(func(_hand: int, _a: float, _d: float, pat: StringName) -> void:
		if pat == &"stall":
			sent[0] += 1)
	add_child(h)
	var old := Game.state
	Game.state = Game.State.PLAYING
	var rows := {}
	for w in [0.3, 0.55, 0.8, 1.0]:
		sent[0] = 0
		h.clear_continuous()
		p.set("telemetry_data", {"stall_warning": w})
		for i in 90:
			h.tick(1.0 / 90.0)
		rows[str(w)] = sent[0]
	metric("stall_pulses_per_s_by_warning", rows)
	eq(int(rows["0.3"]), 0, "stall_warning 0.3: no buffet")
	eq(int(rows["0.55"]), 0, "stall_warning 0.55: no buffet")
	gt(float(rows["0.8"]), 2.0, "stall_warning 0.8: buffet")
	Game.state = old
	p.set("telemetry_data", {})
	h.queue_free()
	remove_child(p)
	p.free()


## The VR autoload's `focused` after the headset comes off (user presence
## false while the session still reports FOCUSED): the contract field is
## read by the harness; record what it says.
func test_focused_flag_after_headset_removed() -> void:
	var old := VR.pause_on_focus_loss
	VR.pause_on_focus_loss = false
	VR._on_session_focused()
	VR._on_user_presence_changed(false)
	metric("focused_after_presence_false", VR.focused)
	metric("user_present", VR.user_present)
	check(not VR.user_present, "user absent recorded")
	VR._on_user_presence_changed(true)
	VR.focused = false
	VR.session_state = "none"
	VR.pause_on_focus_loss = old
