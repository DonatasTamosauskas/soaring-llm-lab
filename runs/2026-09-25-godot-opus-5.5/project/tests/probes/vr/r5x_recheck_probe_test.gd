extends TestCase
## Verifier probe (round 5 re-verification, experience lens): the fix-round-5
## "wearer re-check" as a real player meets it.
##
## The claim: "The same player keeps everything and nothing is written.
## Anyone else gets exactly what a fresh automatic capture would give."
## The re-check is armed at app start, headset-on and EVERY session focus
## regain (e.g. the Quest system button), and fires on the next still,
## level spread at a safe moment (perched / grounded / spawning), with
## "same player" judged within 2 cm span, 1 deg wrist twist, 3 deg neutral.
##
## These probes ask what that does to ONE player (nobody else ever wears the
## headset):
##  1. flare onto a perch after a focus regain: the unprompted capture takes
##     whatever the wrists were doing as "flat";
##  2. how often a realistic re-grip (a degree or two of wrist roll between
##     holds) keeps the player's manual calibration at all.
## Uses only VR's own classes, its test mocks and the dev stub player.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0
## The brief's consistency bars as the builder's own tests use them.
const TWIST_TOL := 1.0
const PITCH_TOL := 0.02
const EXT_TOL := 0.03

var _rng := RandomNumberGenerator.new()


func before_all() -> void:
	XRServer.world_scale = 1.0


func before_each() -> void:
	_rng.seed = 90210
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.user_present = true


func after_all() -> void:
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.focused = false
	VR.user_present = true
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
	var events := {"rechecked": []}
	node.calibrator.rechecked.connect(func(replaced: bool) -> void: (events["rechecked"] as Array).append(replaced))
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "store": store, "player": p, "events": events}


func free_rig(rig: Dictionary) -> void:
	(rig["node"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()
	var p: Node = rig["player"]
	remove_child(p)
	p.free()


func cal_of(rig: Dictionary) -> WingCalibrator:
	return (rig["node"] as VRCalibration).calibrator


func hold(rig: Dictionary, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		var k := 0.0005
		var hd := h.head_transform()
		(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin + Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)))
		for s in 2:
			var x: Transform3D = h.hand_transform(s)
			x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			(rig["hands"][s] as Node3D).transform = x
		(rig["node"] as VRCalibration).tick(DT)


func manual_with_glide(rig: Dictionary, h: VRHumanPose) -> void:
	(rig["node"] as VRCalibration).start_manual()
	h.spread_pose()
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-55.0), 0.0, 0.0, deg_to_rad(20.0))
	hold(rig, h, 3.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 3.0)


## Flat wrists in a level spread and in a relaxed glide: {pitch, twist_deg, glide_ext}.
func flat_reading(rig: Dictionary, h: VRHumanPose) -> Dictionary:
	var cal := cal_of(rig)
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(10.0))
	hold(rig, h, 0.3)
	var out := {"pitch": cal.pitch_command(), "twist_deg": rad_to_deg(0.5 * (cal.twist[0] + cal.twist[1]))}
	h.set_arms(deg_to_rad(-45.0), 0.0, 0.0, deg_to_rad(40.0))
	hold(rig, h, 0.3)
	out["glide_ext"] = 0.5 * (cal.extension[0] + cal.extension[1])
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.3)
	return out


## One player, carefully calibrated with the manual flow (hands flat, glide
## step). Mid-run they tap the Quest button and come back (the runtime's
## session_focused: the re-check is armed). They fly on, then flare onto a
## perch (wrists pitched leading edge up to slow down: requirement 2's
## "tilt both wings leading edge up") and sit there a moment, arms still
## and level, before relaxing. Nobody else ever wore the headset.
## Expected of a shipped game: their own calibration is untouched, flat
## wrists still command no pitch. Contrast: without the focus regain (round
## 4 behaviour) nothing is captured at all.
func test_flare_onto_a_perch_after_a_focus_regain() -> void:
	var rows := {}
	var worst_pitch := 0.0
	var worst_twist := 0.0
	var worst_glide := 0.0
	var replaced_count := 0
	for flare in [0.0, 3.0, 6.0, 10.0, 15.0, 20.0]:
		for regain in [false, true]:
			var rig := make(MemoryStore.new())
			var cal := cal_of(rig)
			var p: Object = rig["player"]
			var a := VRHumanPose.for_span(1.72)
			manual_with_glide(rig, a)
			check(cal.calibrated, "(setup) manual calibration done")
			var ref := flat_reading(rig, a)
			var glide_reach0 := cal.glide_reach
			var writes0: int = (rig["store"] as Object).get("writes")
			p.set("mode_label", "flying")
			Game.set_state(Game.State.PLAYING)
			VR._on_session_focused()
			hold(rig, a, 0.5)
			if regain:
				# Quest button -> system menu -> back, through the VR
				# autoload's real OpenXR handlers: the game pauses with the
				# menu (never resumes by itself); the player resumes.
				VR._on_session_visible()
				check(Game.state == Game.State.PAUSED, "(setup) the system menu paused the game")
				hold(rig, a, 1.0)
				VR._on_session_focused()
				Game.set_state(Game.State.PLAYING)
				check(not get_tree().paused, "(setup) resumed from the pause menu")
			# Flying on: flaps and glides (never captured).
			a.set_arms(deg_to_rad(-10.0), 0.0, 0.0, deg_to_rad(10.0))
			hold(rig, a, 2.0)
			# The flare: level arms, both wrists leading edge up.
			a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(flare), deg_to_rad(5.0))
			hold(rig, a, 0.5)
			# Clung to the perch; the player holds the pose a moment.
			p.set("mode_label", "perched")
			hold(rig, a, 1.6)
			a.set_arms(deg_to_rad(-80.0))
			hold(rig, a, 0.5)
			p.set("mode_label", "flying")
			var now := flat_reading(rig, a)
			var d_pitch := absf(float(now["pitch"]) - float(ref["pitch"]))
			var d_twist := absf(float(now["twist_deg"]) - float(ref["twist_deg"]))
			var d_glide := absf(float(now["glide_ext"]) - float(ref["glide_ext"]))
			var rep: Array = rig["events"]["rechecked"]
			var tag := "flare %.0f° %s" % [flare, "after focus regain" if regain else "no regain (round-4 path)"]
			rows[tag] = {"flat_pitch_before": snappedf(float(ref["pitch"]), 0.0001), "flat_pitch_after": snappedf(float(now["pitch"]), 0.0001),
				"flat_twist_after_deg": snappedf(float(now["twist_deg"]), 0.01), "glide_ext_change": snappedf(d_glide, 0.0001),
				"rechecked": rep, "glide_reach": [snappedf(glide_reach0, 0.001), snappedf(cal.glide_reach, 0.001)],
				"store_writes": (rig["store"] as Object).get("writes") - writes0}
			if regain:
				worst_pitch = maxf(worst_pitch, d_pitch)
				worst_twist = maxf(worst_twist, d_twist)
				worst_glide = maxf(worst_glide, d_glide)
				if rep.size() > 0 and bool(rep[0]):
					replaced_count += 1
			print("[vr] r5x flare probe %s: %s" % [tag, str(rows[tag])])
			Game.set_state(Game.State.BOOT)
			get_tree().paused = false
			free_rig(rig)
	metric("flare_perch", rows)
	metric("flare_perch_worst", {"pitch": worst_pitch, "twist_deg": worst_twist, "glide_ext": worst_glide, "replaced": replaced_count})
	lt(worst_twist, TWIST_TOL, "the same player's flat wrists read the same after a focus regain + flare perch (worst %.2f°)" % worst_twist)
	lt(worst_pitch, PITCH_TOL, "and command the same pitch (worst change %.3f)" % worst_pitch)
	lt(worst_glide, EXT_TOL, "and their relaxed glide reads the same extension (worst change %.3f)" % worst_glide)


## The same player re-donning the headset N times, re-gripping the
## controllers each time with a small random wrist roll (sigma 1.5° per
## wrist: forearm-rotation position sense is a few degrees) and holding the
## same flat spread while perched. The builder's claim: "the same player
## keeps everything" (their test models ZERO re-grip variation).
## Measured: how often the manual calibration (and its glide step) survives.
func test_same_player_regrip_keeps_the_manual_calibration() -> void:
	var rig := make(MemoryStore.new())
	var cal := cal_of(rig)
	var a := VRHumanPose.for_span(1.72)
	manual_with_glide(rig, a)
	var glide0 := cal.glide_reach
	var kept := 0
	var replaced := 0
	var lost_glide := 0
	var n := 20
	for i in n:
		VR._on_user_presence_changed(false)
		VR._on_user_presence_changed(true)
		a.twist_offset = [deg_to_rad(_rng.randfn(0.0, 1.5)), deg_to_rad(_rng.randfn(0.0, 1.5))]
		a.spread_pose()
		hold(rig, a, 2.0)
		a.set_arms(deg_to_rad(-80.0))
		hold(rig, a, 0.4)
		var rep: Array = rig["events"]["rechecked"]
		if rep.size() > i and not bool(rep[i]):
			kept += 1
		elif rep.size() > i:
			replaced += 1
		if absf(cal.glide_reach - glide0) > 1e-6:
			lost_glide += 1
			# The glide step does not come back by itself: count it once.
			glide0 = cal.glide_reach
	a.twist_offset = [0.0, 0.0]
	metric("regrip", {"rechecks": n, "kept": kept, "replaced": replaced, "manual_glide_step_lost_after_recheck": lost_glide})
	print("[vr] r5x regrip probe: %d re-checks, kept %d, replaced %d" % [n, kept, replaced])
	gt(float(kept) / float(n), 0.8, "the same player re-gripping with ~1.5° of wrist roll keeps their calibration (kept %d of %d)" % [kept, n])
	free_rig(rig)


## No system button, no headset removal: the player just launches the game
## again the next day. A saved manual calibration is re-armed at app start
## (VRCalibration.load_saved -> rearm("app start")), so the first flare onto
## a perch of the new session (wrists 15° leading edge up, a still level
## spread for 1.6 s) becomes the player's persisted "flat".
func test_next_launch_first_flare_perch() -> void:
	var store := MemoryStore.new()
	var day1 := make(store)
	var a := VRHumanPose.for_span(1.72)
	manual_with_glide(day1, a)
	check(cal_of(day1).calibrated, "(setup) day 1: manual calibration saved")
	free_rig(day1)
	var day2 := make(store)
	var cal := cal_of(day2)
	var p: Object = day2["player"]
	check(cal.calibrated, "(setup) day 2: the saved calibration loaded")
	var armed := cal.recapture_armed
	var ref := flat_reading(day2, a)
	p.set("mode_label", "flying")
	Game.set_state(Game.State.PLAYING)
	a.set_arms(deg_to_rad(-10.0), 0.0, 0.0, deg_to_rad(10.0))
	hold(day2, a, 2.0)
	a.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(15.0), deg_to_rad(5.0))
	hold(day2, a, 0.5)
	p.set("mode_label", "perched")
	hold(day2, a, 1.6)
	a.set_arms(deg_to_rad(-80.0))
	hold(day2, a, 0.5)
	p.set("mode_label", "flying")
	var now := flat_reading(day2, a)
	var saved: Dictionary = store.get_value("wing_calibration", {})
	metric("next_launch", {"armed_at_start": armed, "flat_pitch_before": ref["pitch"], "flat_pitch_after": now["pitch"],
		"flat_twist_after_deg": now["twist_deg"], "rechecked": day2["events"]["rechecked"], "saved_glide_reach": saved.get("glide_reach", -1.0)})
	print("[vr] r5x next-launch probe: armed %s, flat pitch %.3f -> %.3f, twist %.2f°, rechecked %s" % [str(armed), float(ref["pitch"]),
		float(now["pitch"]), float(now["twist_deg"]), str(day2["events"]["rechecked"])])
	lt(absf(float(now["pitch"]) - float(ref["pitch"])), PITCH_TOL, "day 2: flat wrists still command no pitch after the first flare perch (%.3f)" % float(now["pitch"]))
	Game.set_state(Game.State.BOOT)
	free_rig(day2)
