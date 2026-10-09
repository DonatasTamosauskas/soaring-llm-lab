extends TestCase
## Round-6 engineering re-verification probes for the VR area (not the
## builder's suite). Each test pins a claim of fix round 6 that the unit
## suite does not exercise the way a person would.
##   tools/gd.sh vr_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r6eng

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = 6606
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


## Moves the arms smoothly from dihedral a0 to a1 (degrees) over `seconds`,
## keeping twist (degrees) and elbow.
func glide_arms(rig: Dictionary, h: VRHumanPose, a0: float, a1: float, twist_deg: float, elbow_deg: float, seconds: float) -> void:
	var n := int(round(seconds / DT))
	for i in n:
		var t := float(i + 1) / float(n)
		h.set_arms(deg_to_rad(lerpf(a0, a1, t)), 0.0, deg_to_rad(twist_deg), deg_to_rad(elbow_deg))
		hold(rig, h, DT)


func flat_pitch(rig: Dictionary, h: VRHumanPose) -> float:
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(10.0))
	hold(rig, h, 0.3)
	var p := (rig["node"] as VRCalibration).calibrator.pitch_command()
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	return p


func manual_with_glide(rig: Dictionary, h: VRHumanPose) -> void:
	(rig["node"] as VRCalibration).start_manual()
	h.spread_pose()
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-55.0), 0.0, 0.0, deg_to_rad(20.0))
	hold(rig, h, 3.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 3.0)


# -----------------------------------------------------------------------------
# 1. The round-6 claim: "Only a fresh spread after a break can recalibrate,
# so a flare still being held cannot answer its own question." The break
# (WingCalibrator.check_needs_break) is cleared by ANY neutral_blocker,
# including "hold still". A player still holding the landing flare who
# merely shifts the arms 3 cm (or adjusts the flare a few degrees) and holds
# again has "answered" with the same flare. Same setup as the builder's
# wearer_test.test_a_flare_held_on_a_perch_never_becomes_flat (manual
# calibration with a glide step, re-check armed by the headset going back
# on, fly, flare onto a perch, hold), plus one small fidget during the hold.

func test_flare_with_a_small_fidget_never_becomes_flat() -> void:
	var rows := {}
	for fidget in ["arms 3 deg up and back (0.5 s)", "flare adjusted +7 deg (0.15 s)", "none (the builder's case)"]:
		for flare in [10.0, 15.0]:
			var store := MemoryStore.new()
			var rig := make(store)
			var node: VRCalibration = rig["node"]
			var cal := node.calibrator
			var p: Object = rig["player"]
			var a := VRHumanPose.for_span(1.72)
			a.twist_offset = [deg_to_rad(5.0), deg_to_rad(5.0)]
			manual_with_glide(rig, a)
			node.cancel()
			var pitch0 := flat_pitch(rig, a)
			var dict0 := cal.to_dict()
			var writes0 := store.writes
			# The headset goes off and back on mid-session; the game resumes in flight.
			p.set("mode_label", "flying")
			Game.set_state(Game.State.PLAYING)
			VR._on_user_presence_changed(false)
			VR._on_user_presence_changed(true)
			Game.set_state(Game.State.PLAYING)
			check(cal.recapture_armed, "(setup) re-check armed")
			a.set_arms(deg_to_rad(-10.0), 0.0, 0.0, deg_to_rad(10.0))
			hold(rig, a, 2.0)
			# Flare onto the perch and keep holding it.
			a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(flare), deg_to_rad(5.0))
			hold(rig, a, 0.5)
			p.set("mode_label", "perched")
			hold(rig, a, 3.6)
			var asked := node.flow == VRCalibration.Flow.CHECK
			# One small fidget while still flaring, then hold the flare again.
			match fidget:
				"arms 3 deg up and back (0.5 s)":
					glide_arms(rig, a, -5.0, -2.0, flare, 5.0, 0.25)
					glide_arms(rig, a, -2.0, -5.0, flare, 5.0, 0.25)
				"flare adjusted +7 deg (0.15 s)":
					var n := int(round(0.15 / DT))
					for i in n:
						a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(flare + 7.0 * float(i + 1) / float(n)), deg_to_rad(5.0))
						hold(rig, a, DT)
			hold(rig, a, 1.6)
			var replaced: bool = (rig["events"]["rechecked"] as Array).has(true)
			# Relax and fly on.
			a.set_arms(deg_to_rad(-80.0))
			hold(rig, a, 0.5)
			node.cancel()
			p.set("mode_label", "flying")
			var pitch1 := flat_pitch(rig, a)
			var tag := "flare %.0f deg, fidget: %s" % [flare, fidget]
			rows[tag] = {"asked": asked, "rechecked": rig["events"]["rechecked"], "flat_pitch_before": snappedf(pitch0, 0.0001),
				"flat_pitch_after": snappedf(pitch1, 0.0001), "writes": store.writes - writes0}
			print("[vr] r6eng %s: asked %s, rechecked %s, flat pitch %.4f -> %.4f, writes +%d" % [tag, str(asked),
				str(rig["events"]["rechecked"]), pitch0, pitch1, store.writes - writes0])
			check(asked, "%s: (setup) the flare raised the prompt" % tag)
			check(not replaced, "%s: the flare still held never answers the prompt (rechecked %s)" % [tag, str(rig["events"]["rechecked"])])
			lt(absf(pitch1 - pitch0), 0.02, "%s: flat wrists read the same pitch afterwards (%.4f -> %.4f)" % [tag, pitch0, pitch1])
			eq(store.writes, writes0, "%s: nothing written" % tag)
			Game.set_state(Game.State.BOOT)
			free_rig(rig)
	metric("flare_fidget", rows)


# -----------------------------------------------------------------------------
# 2. VR.presence_supported relies on OpenXRInterface.is_user_presence_supported()
# (duck-typed has_method, so a missing method would silently leave it false
# and every system-menu visit would arm the re-check). Pin the engine API.

func test_presence_api_exists_on_the_real_openxr_class() -> void:
	check(ClassDB.class_has_method(&"OpenXRInterface", &"is_user_presence_supported"),
		"OpenXRInterface.is_user_presence_supported() exists in this engine")
	check(ClassDB.class_has_signal(&"OpenXRInterface", &"user_presence_changed"),
		"OpenXRInterface.user_presence_changed exists in this engine")


# -----------------------------------------------------------------------------
# 3. presence_supported is also asked when the session begins (the runtime's
# system properties are known only then): a runtime that says "no" at
# connect and "yes" at session_begun must end up supported.

class _LateRuntime:
	extends Object
	signal session_begun()
	var supported := false
	var rate := 72.0

	func is_user_presence_supported() -> bool:
		return supported

	func get_available_display_refresh_rates() -> Array:
		return [72.0, 90.0]

	func set_cpu_level(_l: int) -> bool:
		return true

	func set_gpu_level(_l: int) -> bool:
		return true

	var display_refresh_rate: float:
		get:
			return rate
		set(v):
			rate = v


func test_presence_support_is_asked_again_at_session_begin() -> void:
	var rt := _LateRuntime.new()
	var ticks0 := Engine.physics_ticks_per_second
	VR.presence_supported = false
	VR.connect_interface(rt)
	check(not VR.presence_supported, "(setup) not supported at connect")
	rt.supported = true
	rt.session_begun.emit()
	check(VR.presence_supported, "asked again at session begin")
	VR.disconnect_interface()
	VR.presence_supported = false
	VR.session_state = "none"
	VR.refresh_rate = 0.0
	Engine.physics_ticks_per_second = ticks0
	rt.free()


# -----------------------------------------------------------------------------
# 4. The result card after a prompted check that kept the calibration says the
# wings were kept, not "calibrated" (VRCalibration._kept).

func test_kept_check_card_says_kept() -> void:
	var rig := make(MemoryStore.new())
	var node: VRCalibration = rig["node"]
	var a := VRHumanPose.for_span(1.7)
	a.spread_pose()
	hold(rig, a, 2.0)
	a.set_arms(deg_to_rad(-80.0))
	hold(rig, a, 0.5)
	check(node.calibrator.calibrated, "(setup) calibrated")
	node.start_check("probe")
	eq(node.flow, VRCalibration.Flow.CHECK, "(setup) check up")
	a.spread_pose()
	hold(rig, a, 2.0)
	eq((rig["events"]["rechecked"] as Array), [false], "the same player: kept")
	eq(node.flow, VRCalibration.Flow.DONE, "result shown")
	eq(node.prompt_text(), "Your wings are set", "the card says kept")
	free_rig(rig)
