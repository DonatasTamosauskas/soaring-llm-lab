extends TestCase
## V3: the calibration step (the lead's redesign after fix round 6).
##
## Wrist neutral and arm span are captured ONLY in an explicit, prompted
## step: on the first launch (no saved calibration) before the first flight,
## and whenever the player chooses Recalibrate (Settings, the pause menu,
## the Y-hold). The card says "Stand tall. Spread your wings, hands flat.
## Hold still."; the capture fires when the pose is plausible (both hands
## tracked, arms spread level at shoulder height, evenly, the head up) and
## still for about a second; a short confirmation follows; B or Y cancels
## (skips, on the first launch; so do going back into play and the headset
## coming off). Nothing else ever changes the wrist neutral: the headset
## coming off and on or a long absence only raise
## VR.recalibration_suggested (the pause menu's "New player? Recalibrate
## wings"); a relaunch with a saved calibration raises nothing (integration
## round 1). In the game itself Play gates the first flight on the
## first-launch step (FirstFlightGate, tests/unit/integration/
## game_first_launch_test.gd); these tests run the service's own automatic
## first-launch start (first_launch_prompt), as a scene without a gate does.
##
## Replaces wearer_test (the automatic wearer re-check, deleted with its
## machinery: its last open defect was a landing flare held on a perch
## answering its own card after a one-frame tracking blip and being
## persisted as "flat").
##
## Every scenario runs the real service (VRCalibration.tick, a private
## store, a stand-in PlayerBird with a WingInput look-alike and a
## WingCalibration look-alike) at the Quest's 72 Hz.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const CalMock := preload("res://tests/unit/vr/vr_wing_calibration_mock.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0

var _rng := RandomNumberGenerator.new()
## Applied to both controllers in hold(): how the hands sit on the
## controllers (a re-grip), as a swing relative to the grip.
var _grip_tilt := Basis.IDENTITY
## Fake controller buttons for VR.controls ({"hand:action": bool}).
var _buttons := {}
var _suggested: Array = []
var _on_suggest: Callable


class _WingInputHook:
	extends RefCounted
	var calibration: Resource
	var replaced := 0

	func calibration_replaced() -> void:
		replaced += 1


func before_all() -> void:
	XRServer.world_scale = 1.0
	_on_suggest = func(on: bool) -> void: _suggested.append(on)
	VR.recalibration_suggested_changed.connect(_on_suggest)


func after_all() -> void:
	VR.recalibration_suggested_changed.disconnect(_on_suggest)
	_reset_world()


func before_each() -> void:
	_rng.seed = 2610
	_grip_tilt = Basis.IDENTITY
	_reset_world()


func after_each() -> void:
	_reset_world()


func _reset_world() -> void:
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.active = false
	VR.focused = false
	VR.user_present = true
	VR.presence_supported = false
	VR.session_state = "none"
	VR.recalibration_suggested = false
	VR.controls.reader = Callable()
	_buttons.clear()
	_suggested.clear()


# -----------------------------------------------------------------------------
# Helpers

## The service on its own rig with a stand-in PlayerBird in `mode`.
## (Created after the caller set VR.active / the Game state: the service
## loads the saved calibration in _ready.)
func make(store: Object, mode: String = "perched", show: bool = false) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	var p := StubPlayer.new()
	p.mode_label = mode
	var wi := _WingInputHook.new()
	wi.calibration = CalMock.new()
	p.wing_input = wi
	add_child(p)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = show
	node.force_valid = true
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	var ev := {"captured": 0, "rejected": 0, "finished": [], "max_flow": VRCalibration.Flow.IDLE, "capturing_seen": false}
	node.calibrator.captured.connect(func(_k: StringName) -> void: ev["captured"] += 1)
	node.calibrator.rejected.connect(func(_k: StringName, _w: String) -> void: ev["rejected"] += 1)
	node.flow_finished.connect(func(ok: bool, why: String) -> void: (ev["finished"] as Array).append([ok, why]))
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "store": store, "player": p,
		"wing_input": wi, "res": wi.calibration, "events": ev}


func free_rig(rig: Dictionary) -> void:
	var node: Node = rig["node"]
	remove_child(node)
	node.free()
	(rig["origin"] as Node).queue_free()
	var p: Node = rig["player"]
	remove_child(p)
	p.free()


func cal_of(rig: Dictionary) -> WingCalibrator:
	return (rig["node"] as VRCalibration).calibrator


func node_of(rig: Dictionary) -> VRCalibration:
	return rig["node"] as VRCalibration


## One tick of the pose (0.5 mm tracker noise): the rig's nodes are
## written as a headset would, then the service ticks. `overrides` replace
## a controller's transform.
func tick_pose(rig: Dictionary, h: VRHumanPose, overrides: Dictionary = {}) -> void:
	var k := 0.0005
	var hd := h.head_transform()
	(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin + Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)))
	for s in 2:
		var x: Transform3D = overrides[s] if overrides.has(s) else h.hand_transform(s)
		x.basis = x.basis * _grip_tilt
		x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
		(rig["hands"][s] as Node3D).transform = x
	var node := node_of(rig)
	node.tick(DT)
	var ev: Dictionary = rig["events"]
	if node.flow == VRCalibration.Flow.CAPTURE:
		ev["max_flow"] = VRCalibration.Flow.CAPTURE
	if node.calibrator.capturing:
		ev["capturing_seen"] = true


## Holds the body's pose for `seconds`; `per_tick` (Callable(i)) may change
## the pose or the rig each tick.
func hold(rig: Dictionary, h: VRHumanPose, seconds: float, overrides: Dictionary = {}, per_tick: Callable = Callable()) -> void:
	for i in int(round(seconds / DT)):
		if per_tick.is_valid():
			per_tick.call(i)
		tick_pose(rig, h, overrides)


## Moves the arms smoothly (per tick) from the pose they are in to the one
## `set_target` sets, over `seconds`: real arms never teleport, and the
## hand-speed estimate (τ 0.15 s) sees the movement end as it would.
func move_to(rig: Dictionary, h: VRHumanPose, set_target: Callable, seconds: float) -> void:
	var from := [h.dihedral.duplicate(), h.sweep.duplicate(), h.twist.duplicate(), h.elbow.duplicate()]
	set_target.call()
	var to := [h.dihedral.duplicate(), h.sweep.duplicate(), h.twist.duplicate(), h.elbow.duplicate()]
	var n := maxi(1, int(round(seconds / DT)))
	for i in n:
		var k := smoothstep(0.0, 1.0, float(i + 1) / n)
		for side in 2:
			h.dihedral[side] = lerpf(from[0][side], to[0][side], k)
			h.sweep[side] = lerpf(from[1][side], to[1][side], k)
			h.twist[side] = lerpf(from[2][side], to[2][side], k)
			h.elbow[side] = lerpf(from[3][side], to[3][side], k)
		tick_pose(rig, h)


## Ticks until the capture (at most `limit` s); returns [seconds, seconds
## from the first tick of the hold to the capture].
func until_captured(rig: Dictionary, h: VRHumanPose, limit: float = 4.0) -> Array:
	var cal := cal_of(rig)
	var n0 := int(rig["events"]["captured"])
	var t := 0.0
	var start := -1.0
	while int(rig["events"]["captured"]) == n0 and t < limit:
		tick_pose(rig, h)
		t += DT
		if start < 0.0 and float(cal.capture_status()["progress"]) > 0.0:
			start = t - DT
	return [t, t - start if start >= 0.0 else -1.0]


## A one-frame loss of tracking of both controllers (the service reads
## them as untracked for one tick).
func blip(rig: Dictionary, h: VRHumanPose) -> void:
	var node := node_of(rig)
	var was: Variant = node.force_valid
	node.force_valid = false
	tick_pose(rig, h)
	node.force_valid = was


func wearer(span: float, habit_deg: Array = [0.0, 0.0]) -> VRHumanPose:
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(habit_deg[0]), deg_to_rad(habit_deg[1])]
	return h


## The calibration step from the menu: the card, the spread held until the
## capture, arms down, the confirmation gone.
func calibrate(rig: Dictionary, h: VRHumanPose) -> void:
	node_of(rig).start_manual()
	h.spread_pose()
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, VRCalibration.RESULT_SHOW + 0.2)


## Flat wrists in a level spread and in a relaxed glide: {pitch, twist_deg,
## glide_ext}.
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


## The wrist neutral and the axes, as the calibrator holds them.
func geometry(cal: WingCalibrator) -> Array:
	return [cal.neutral[0], cal.neutral[1], cal.forearm_axis[0], cal.forearm_axis[1], cal.chord_axis[0], cal.chord_axis[1]]


## The same, as flight's resource holds them.
func res_geometry(res: Object) -> Array:
	var out := []
	for k in ["neutral_left", "neutral_right", "forearm_axis_left", "forearm_axis_right", "chord_axis_left", "chord_axis_right"]:
		out.append(res.get(k))
	return out


func saved(rig: Dictionary) -> Dictionary:
	return (rig["store"] as Object).call("get_value", "wing_calibration", {})


func saved_geometry(rig: Dictionary) -> Array:
	var d := saved(rig)
	var out := []
	for k in ["neutral_left", "neutral_right", "forearm_axis_left", "forearm_axis_right", "chord_axis_left", "chord_axis_right"]:
		out.append(d.get(k))
	return out


## A still spread with both wrists pitched `deg` leading edge up (a landing
## flare) or down (a dive trim), arms level.
func pitched_spread(h: VRHumanPose, deg: float) -> void:
	h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(deg), deg_to_rad(5.0))


func _read_button(hand: StringName, action: StringName) -> Variant:
	return bool(_buttons.get("%s:%s" % [hand, action], false))


## Presses / releases a controller button through VR.controls (its real
## input path, with the reader injected), for `seconds`.
func buttons(rig: Dictionary, h: VRHumanPose, state: Dictionary, seconds: float) -> void:
	VR.controls.reader = _read_button
	_buttons = state.duplicate()
	for i in int(round(seconds / DT)):
		VR.controls.tick(DT)
		tick_pose(rig, h)


# -----------------------------------------------------------------------------

## First launch (no saved calibration), in the headset: the card comes up
## by itself before the first flight, with the exact instruction and how to
## cancel; it waits (the game's first screen: no timeout) and nothing is
## captured from arms down; the still spread is captured about a second
## later, confirmed, persisted, written into flight's calibration (flight's
## trim told), and the card goes. On the desktop (no headset), unfocused,
## or with a saved calibration, no card comes up by itself; a first launch
## found in play pauses the game first.
func test_first_launch_asks_before_the_first_flight() -> void:
	VR.active = true
	VR.focused = true
	Game.set_state(Game.State.MENU)
	var store := MemoryStore.new()
	var rig := make(store, "spawning", true)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var res: Resource = rig["res"]
	check(node.first_launch_pending, "no saved calibration: the step is due")
	check(not VR.recalibration_suggested, "(nothing to suggest: the step itself comes)")
	var h := wearer(1.7, [12.0, -8.0])
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.2)
	eq(node.flow, VRCalibration.Flow.CAPTURE, "the card comes up by itself")
	eq(node.flow_reason, &"first_launch", "as the first-launch step")
	check(node.prompt != null and node.prompt.visible, "the card is shown")
	if node.prompt != null:
		eq(node.prompt.text.text, "Stand tall. Spread your wings,\nhands flat. Hold still.", "it says 'Stand tall. Spread your wings, hands flat. Hold still.'")
		eq(node.prompt.hint.text, "B or Y: skip (default wings)", "and how to skip it")
		eq(node.prompt.step, CalibrationPrompt.Step.POSE, "with the pose to hold drawn")
	# Nothing from arms down, relaxed arms, or flapping (arms sweeping up to
	# 10° under level and down again), for longer than a requested step's
	# timeout.
	var t := VRCalibration.STEP_TIMEOUT + 5.0
	hold(rig, h, t, {}, func(i: int) -> void: h.set_arms(deg_to_rad(-80.0 + 70.0 * absf(sin(i * DT * 1.3)))))
	eq(node.flow, VRCalibration.Flow.CAPTURE, "still asking after %.0f s (no timeout on the first launch)" % t)
	check(not cal.calibrated and not bool(res.get("calibrated")), "nothing captured: flight flies its defaults")
	check((saved(rig)).is_empty(), "nothing persisted")
	# The arms come up into the spread (0.5 s) and stay still.
	move_to(rig, h, func() -> void: h.spread_pose(), 0.5)
	var took := until_captured(rig, h)
	check(cal.calibrated, "the still spread is captured")
	between(float(took[0]), WingCalibrator.NEUTRAL_HOLD, WingCalibrator.NEUTRAL_HOLD + 0.5, "about a second after the arms stop (%.2f s)" % took[0])
	near(float(took[1]), WingCalibrator.NEUTRAL_HOLD, DT * 1.5, "the hold itself is NEUTRAL_HOLD (%.3f s)" % took[1])
	metric("first_launch_capture_s", {"after_the_arms_stop": snappedf(took[0], 0.001), "hold": snappedf(took[1], 0.001)})
	eq(node.flow, VRCalibration.Flow.DONE, "a short confirmation follows")
	check(node.prompt_text().begins_with("Wings calibrated"), "'%s'" % node.prompt_text().replace("\n", " / "))
	if node.prompt != null:
		eq(node.prompt.step, CalibrationPrompt.Step.DONE, "with a tick")
	check(not node.first_launch_pending, "the first-launch step is done")
	check(bool(res.get("calibrated")), "flight's calibration is written")
	near(float(res.get("arm_span")), cal.arm_span, 1e-6, "with VR's span")
	eq((res.get("neutral_left") as Basis), cal.neutral[0], "and VR's wrist neutral")
	eq(int((rig["wing_input"] as _WingInputHook).replaced), 1, "flight is told its old trim is void")
	near(float(saved(rig).get("arm_span", 0.0)), cal.arm_span, 1e-6, "persisted")
	var flat := flat_reading(rig, h)
	lt(absf(float(flat["pitch"])), 1e-6, "this player's own flat wrists (12° / -8° habit) command no pitch")
	hold(rig, h, VRCalibration.RESULT_SHOW)
	eq(node.flow, VRCalibration.Flow.IDLE, "the confirmation goes away")
	check(node.prompt == null or not node.prompt.visible, "and the card with it")
	free_rig(rig)
	# Contrasts: no card by itself on the desktop, unfocused, or with a
	# saved calibration.
	for where in ["desktop", "headset off", "saved calibration"]:
		VR.active = where != "desktop"
		VR.focused = where == "saved calibration"
		var st := store if where == "saved calibration" else MemoryStore.new()
		var r2 := make(st, "perched")
		var h2 := wearer(1.6)
		h2.spread_pose()
		hold(r2, h2, 3.0)
		eq(node_of(r2).flow, VRCalibration.Flow.IDLE, "%s: no card by itself" % where)
		eq(int(r2["events"]["captured"]), 0, "%s: nothing captured" % where)
		if where == "headset off":
			VR.focused = true
			hold(r2, h2, 0.1)
			eq(node_of(r2).flow, VRCalibration.Flow.CAPTURE, "headset on: now the card comes up")
		free_rig(r2)
	# A first launch whose headset focus comes while a run already plays
	# (a scene that starts flying at once): the game pauses for the step.
	VR.active = true
	VR.focused = true
	Game.set_state(Game.State.PLAYING)
	var r3 := make(MemoryStore.new(), "flying")
	var h3 := wearer(1.6)
	h3.set_arms(deg_to_rad(-40.0))
	hold(r3, h3, 0.1)
	eq(node_of(r3).flow, VRCalibration.Flow.CAPTURE, "in play: the card comes up")
	eq(Game.state, Game.State.PAUSED, "and the game is paused first (before the first flight)")
	free_rig(r3)


## The game's Play gate (FirstFlightGate, integration round 1) drives the
## first-launch step through first_launch_due / start_first_launch /
## abandon, with the service's own automatic start off: no card by itself;
## due only in the headset while nothing is calibrated; the gate's abandon
## leaves no result card and keeps it due; a capture ends it.
func test_the_play_gate_api() -> void:
	_reset_world()
	VR.active = true
	VR.focused = true
	VR.session_state = "focused"
	Game.set_state(Game.State.MENU)
	var rig := make(MemoryStore.new(), "perched")
	var node := node_of(rig)
	node.first_launch_prompt = false
	var h := wearer(1.7)
	h.set_arms(deg_to_rad(-70.0))
	hold(rig, h, 2.0)
	eq(node.flow, VRCalibration.Flow.IDLE, "gated: no card by itself in the menu")
	check(node.first_launch_due(), "due: in the headset, nothing calibrated")
	VR.active = false
	check(not node.first_launch_due(), "desktop: never due")
	VR.active = true
	node.start_first_launch()
	hold(rig, h, 0.1)
	eq(node.flow, VRCalibration.Flow.CAPTURE, "the gate starts the step")
	eq(node.flow_reason, &"first_launch", "as the first-launch step")
	eq(node.hint_text(), VRCalibration.SKIP_HINT, "with the skip hint")
	node.abandon("the menu button")
	eq(node.flow, VRCalibration.Flow.IDLE, "abandoned: no result card")
	check(node.first_launch_due(), "still due")
	var fin: Array = rig["events"]["finished"]
	eq(fin.back() if not fin.is_empty() else [], [false, "the menu button"], "flow_finished says why")
	node.abandon("again")
	eq(fin.size(), 1, "abandon() outside a step does nothing")
	node.start_first_launch()
	move_to(rig, h, func() -> void: h.spread_pose(), 0.5)
	until_captured(rig, h)
	check(cal_of(rig).calibrated, "the held spread is captured")
	check(not node.first_launch_due(), "captured: no longer due")
	eq(fin.back() if not fin.is_empty() else [], [true, ""], "flow_finished(true)")
	free_rig(rig)


## The first-launch card ends with the player's choice: pressing Play
## (the game goes into play) or cancelling (B / Y) keeps the defaults and
## does not ask again this session; the headset coming off abandons it
## quietly and it comes back when the headset is on again.
func test_first_launch_step_ends_with_the_players_choice() -> void:
	for how in ["Play", "B", "headset off and on"]:
		_reset_world()
		VR.active = true
		VR.focused = true
		VR.session_state = "focused"
		Game.set_state(Game.State.MENU)
		var rig := make(MemoryStore.new(), "spawning")
		var node := node_of(rig)
		var h := wearer(1.75, [10.0, 10.0])
		h.set_arms(deg_to_rad(-70.0))
		hold(rig, h, 0.3)
		eq(node.flow, VRCalibration.Flow.CAPTURE, "%s: (setup) the first-launch card" % how)
		if how == "headset off and on":
			VR._on_user_presence_changed(false)
			hold(rig, h, 0.1)
			eq(node.flow, VRCalibration.Flow.IDLE, "headset off: the card is gone, no result shown")
			h.spread_pose()
			hold(rig, h, 3.0)
			eq(int(rig["events"]["captured"]), 0, "headset off: nothing captured from a headset on the table")
			VR._on_user_presence_changed(true)
			h.set_arms(deg_to_rad(-70.0))
			hold(rig, h, 0.1)
			eq(node.flow, VRCalibration.Flow.CAPTURE, "headset on again: the first-launch card is back")
			check(node.first_launch_pending, "(still due)")
			free_rig(rig)
			continue
		if how == "Play":
			Game.set_state(Game.State.PLAYING)
			(rig["player"] as Object).set("mode_label", "flying")
			hold(rig, h, 0.1)
			eq(node.flow, VRCalibration.Flow.FAILED, "Play: the card ends")
			check(node.prompt_text().ends_with("Using default wings"), "Play: it says the defaults apply ('%s')" % node.prompt_text().replace("\n", " / "))
		else:
			buttons(rig, h, {"right_hand:by_button": true}, 0.1)
			buttons(rig, h, {}, 0.1)
			eq(node.flow, VRCalibration.Flow.FAILED, "B: cancelled")
			check(node.prompt_text().begins_with("Calibration skipped"), "B: '%s'" % node.prompt_text().replace("\n", " / "))
			check(node.prompt_text().ends_with("Using default wings"), "B: the defaults fly")
		check(not node.first_launch_pending, "%s: not asked again this session" % how)
		# Held spreads afterwards, in play and back in the menu: nothing.
		h.spread_pose()
		hold(rig, h, 3.0)
		Game.set_state(Game.State.MENU)
		(rig["player"] as Object).set("mode_label", "perched")
		hold(rig, h, 3.0)
		eq(node.flow, VRCalibration.Flow.IDLE, "%s: no card again" % how)
		eq(int(rig["events"]["captured"]), 0, "%s: nothing captured" % how)
		check(not bool((rig["res"] as Resource).get("calibrated")), "%s: flight keeps its defaults" % how)
		free_rig(rig)


## A still, plausible spread is captured about a second after it becomes
## still (the hand-velocity estimate settles first), the ring filling
## steadily; a one-frame tracking loss restarts the hold (the old design's
## open defect: a one-frame blip let a held flare answer its own card).
func test_a_stable_spread_is_captured_in_about_a_second() -> void:
	var rig := make(MemoryStore.new())
	var node := node_of(rig)
	var cal := cal_of(rig)
	var h := wearer(1.65)
	node.start_manual()
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, 0.5)
	move_to(rig, h, func() -> void: h.spread_pose(), 0.5)
	var t := 0.0
	var last := 0.0
	var steady := true
	while not cal.calibrated and t < 4.0:
		tick_pose(rig, h)
		t += DT
		var p := float(cal.capture_status()["progress"])
		if not cal.calibrated:
			steady = steady and p >= last
			last = p
	check(cal.calibrated, "captured")
	between(t, WingCalibrator.NEUTRAL_HOLD, WingCalibrator.NEUTRAL_HOLD + 0.5, "about a second after the arms stop (%.2f s)" % t)
	check(steady, "the ring fills steadily while the pose is held")
	var clean := t
	# The same with one lost frame 0.8 s into the hold.
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, VRCalibration.RESULT_SHOW + 0.2)
	var d0 := cal.to_dict()
	node.start_manual()
	move_to(rig, h, func() -> void: h.spread_pose(), 0.5)
	t = 0.0
	var blipped := false
	var hold_start := -1.0
	while t < 5.0 and int(rig["events"]["captured"]) < 2:
		if hold_start < 0.0 and float(cal.capture_status()["progress"]) > 0.0:
			hold_start = t
		if not blipped and hold_start >= 0.0 and t - hold_start >= 0.8:
			blip(rig, h)
			blipped = true
			check(float(cal.capture_status()["progress"]) == 0.0, "the lost frame restarts the hold")
		else:
			tick_pose(rig, h)
		t += DT
	check(blipped and int(rig["events"]["captured"]) == 2, "captured after the blip")
	gt(t, hold_start + 0.8 + WingCalibrator.NEUTRAL_HOLD - 0.02, "a full second after the lost frame (%.2f s, hold began %.2f s)" % [t, hold_start])
	metric("capture_s", {"clean": snappedf(clean, 0.001), "with_blip": snappedf(t, 0.001)})
	near(cal.arm_span, float(d0["arm_span"]), 0.005, "(the same body measured again)")
	free_rig(rig)


## Poses that are not a still "spread your wings, hands flat" at shoulder
## height, each held 4 s while the card waits: never captured, and the
## card's hint says what to change. Afterwards the plausible spread is
## captured (the step was waiting all along). Nothing is written.
func test_unstable_or_implausible_poses_are_never_captured() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var h := wearer(1.7)
	var right: XRController3D = rig["hands"][1]
	var origin: XROrigin3D = rig["origin"]
	var eye := h.eye_height
	var level := func() -> void: h.set_arms(deg_to_rad(-5.0))
	# [name, setup, overrides builder (or null), per-tick (or null), expected blocker ("" = any)]
	var cases := [
		["hands moving", level, null, func(i: int) -> void: h.set_arms(deg_to_rad(-5.0), deg_to_rad(4.0 * sin(i * DT * TAU * 0.5))), "hold still"],
		["a wrist rolling", level, null, func(i: int) -> void: h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(10.0 * sin(i * DT * TAU))), "hold still"],
		["a tracking blip every 0.5 s", level, null, null, ""],
		["one controller untracked", level, null, null, "tracking"],
		["hands 0.6 m apart in front (the simulator's resting controllers)", level,
			func() -> Dictionary: return {0: Transform3D(VRHumanPose.airplane_basis(0), Vector3(-0.3, eye - 0.3, -0.46)),
				1: Transform3D(VRHumanPose.airplane_basis(1), Vector3(0.3, eye - 0.3, -0.46))}, null, "spread your arms wider"],
		["arms 45° low (at the hips)", func() -> void: h.set_arms(deg_to_rad(-45.0)), null, null, "hold your arms level"],
		["arms 40° raised", func() -> void: h.set_arms(deg_to_rad(40.0)), null, null, "hold your arms level"],
		["one hand 20 cm higher", func() -> void:
			h.set_arms(deg_to_rad(-5.0))
			h.dihedral = [deg_to_rad(-15.0), deg_to_rad(5.0)], null, null, "hold both hands at the same height"],
		["hands 55° forward", func() -> void: h.set_arms(deg_to_rad(-5.0), deg_to_rad(55.0)), null, null, "spread your arms out to the sides"],
		["one arm spread, the other controller on a shoulder-high shelf 2.1 m away", level,
			func() -> Dictionary:
				var lg := h.hand_transform(0)
				return {1: Transform3D(h.hand_transform(1).basis, lg.origin + Vector3(2.1, 0.0, 0.0))}, null, "spread both arms evenly"],
		["the controllers swapped between the hands", level,
			func() -> Dictionary:
				var flip := Basis(Vector3.BACK, PI)
				return {0: Transform3D(h.hand_transform(1).basis * flip, h.hand_transform(1).origin),
					1: Transform3D(h.hand_transform(0).basis * flip, h.hand_transform(0).origin)}, null, "controllers in the wrong hands?"],
		["the controllers held upright like torches", level,
			func() -> Dictionary:
				var torch := Basis(Vector3.RIGHT, PI * 0.5)
				return {0: Transform3D(h.hand_transform(0).basis * torch, h.hand_transform(0).origin),
					1: Transform3D(h.hand_transform(1).basis * torch, h.hand_transform(1).origin)}, null, "hold the controllers as usual"],
		["the other controller 2.6 m away", level,
			func() -> Dictionary:
				var lg := h.hand_transform(0)
				return {1: Transform3D(h.hand_transform(1).basis, lg.origin + Vector3(2.6, 0.0, 0.0))}, null, "hold a controller in each hand"],
		["head bent down 45° (not standing tall)", func() -> void:
			h.set_arms(deg_to_rad(-5.0))
			h.head_pitch = deg_to_rad(-45.0), null, null, "stand tall, look ahead"],
	]
	var writes0 := (store as Object).get("writes") as int
	var rows := {}
	for c in cases:
		var name: String = c[0]
		h.head_pitch = 0.0
		h.dihedral = [0.0, 0.0]
		node.start_manual()
		h.set_arms(deg_to_rad(-80.0))
		hold(rig, h, 0.3)
		(c[1] as Callable).call()
		var ov := {}
		if c[2] != null:
			ov = (c[2] as Callable).call()
		var per: Callable = c[3] if c[3] != null else Callable()
		var worst_progress := 0.0
		for i in int(4.0 / DT):
			if per.is_valid():
				per.call(i)
			if name.begins_with("a tracking blip") and i % 36 == 35:
				blip(rig, h)
			elif name == "one controller untracked":
				node.force_valid = null
				if right.get_parent() == origin:
					origin.remove_child(right)
				tick_pose(rig, h, ov)
			else:
				tick_pose(rig, h, ov)
			worst_progress = maxf(worst_progress, float(cal.capture_status()["progress"]))
		if right.get_parent() != origin:
			origin.add_child(right)
		node.force_valid = true
		var blocker := cal.neutral_blocker()
		rows[name] = {"blocker": blocker, "max_progress": snappedf(worst_progress, 0.01)}
		check(not cal.calibrated and int(rig["events"]["captured"]) == 0, "%s: never captured" % name)
		eq(node.flow, VRCalibration.Flow.CAPTURE, "%s: the card still waits" % name)
		if c[4] != "":
			eq(blocker, c[4], "%s: the blocker is '%s'" % [name, c[4]])
			var shown: String = "keep both controllers in view" if c[4] == "tracking" else c[4]
			eq(node.hint_text(), "%s\n%s" % [shown.substr(0, 1).to_upper() + shown.substr(1), VRCalibration.CANCEL_HINT],
				"%s: the card's hint says so, and still how to cancel" % name)
		lt(worst_progress, 1.0, "%s: the hold never completed (max %.2f)" % [name, worst_progress])
	metric("implausible", rows)
	eq((store as Object).get("writes"), writes0, "nothing written")
	check(not bool((rig["res"] as Resource).get("calibrated")), "flight untouched")
	# The plausible spread, still: captured.
	h.head_pitch = 0.0
	h.spread_pose()
	hold(rig, h, 1.6)
	check(cal.calibrated, "the plausible, still spread is captured")
	free_rig(rig)


## Cancelling keeps the calibration held, bit for bit, whoever was holding a
## spread at the time: B or Y pressed while the card waits (either
## controller), cancel(), the game resumed, the headset coming off, the
## step timing out, and a grip the calibrator refuses (swapped
## controllers). Nothing is written, flight's calibration and its trim are
## untouched, and the first player's flat wrists read exactly as before.
## The Y-hold that starts a step is not a cancel when released.
func test_cancel_keeps_the_old_calibration() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var res: Resource = rig["res"]
	var wi: _WingInputHook = rig["wing_input"]
	var a := wearer(1.65, [8.0, 8.0])
	calibrate(rig, a)
	check(cal.calibrated, "(setup) player A calibrated")
	var d0 := cal.to_dict()
	var g0 := geometry(cal)
	var rg0 := res_geometry(res)
	var writes0 := store.writes
	var replaced0 := wi.replaced
	var ref := flat_reading(rig, a)
	var rows := {}
	for how in ["B (right)", "Y (left)", "cancel()", "the game resumed", "the headset came off", "timed out", "a grip refused by the capture"]:
		# In the menu, as in the game (no span refinement from B's spreads).
		Game.set_state(Game.State.MENU)
		if how == "the game resumed":
			Game.set_state(Game.State.PLAYING)
			Game.set_state(Game.State.PAUSED)
		if how == "the headset came off":
			VR.active = true
			VR.focused = true
			VR.session_state = "focused"
		var b := wearer(1.9, [-20.0, 20.0])
		node.start_manual()
		eq(node.flow, VRCalibration.Flow.CAPTURE, "%s: (setup) the card" % how)
		var ov := {}
		if how == "timed out":
			b.set_arms(deg_to_rad(-80.0))
			hold(rig, b, VRCalibration.STEP_TIMEOUT + 0.5)
		else:
			move_to(rig, b, func() -> void: b.spread_pose(), 0.3)
			hold(rig, b, 0.75, ov)
			gt(float(cal.capture_status()["progress"]), 0.3, "%s: (setup) B's hold was under way" % how)
		match how:
			"B (right)":
				buttons(rig, b, {"right_hand:by_button": true}, 0.05)
				buttons(rig, b, {}, 0.05)
			"Y (left)":
				buttons(rig, b, {"left_hand:by_button": true}, 0.05)
				buttons(rig, b, {}, 0.05)
			"cancel()":
				node.cancel()
			"the game resumed":
				Game.set_state(Game.State.PLAYING)
				(rig["player"] as Object).set("mode_label", "flying")
			"the headset came off":
				VR._on_user_presence_changed(false)
			"a grip refused by the capture":
				# The capture's safety net (the live check asks first; a grip
				# can still read > 45° off from the fitted shoulders): the
				# refusal ends the step as "not changed".
				cal.cancel_capture()
				cal.rejected.emit(&"neutral", "the controllers were held in an unusual way")
		hold(rig, b, 0.05, ov)
		var flow_now := node.flow
		var text_now := node.prompt_text()
		if how == "the headset came off":
			eq(flow_now, VRCalibration.Flow.IDLE, "%s: the card is gone (no result shown to nobody)" % how)
		else:
			eq(flow_now, VRCalibration.Flow.FAILED, "%s: a short 'unchanged' card" % how)
			check(node.prompt_text().contains("unchanged") or node.prompt_text().begins_with("Calibration not changed"), "%s: '%s'" % [how, node.prompt_text().replace("\n", " / ")])
		# B keeps holding the spread: nothing is capturing any more.
		b.spread_pose()
		hold(rig, b, 3.0, ov)
		var fin: Array = rig["events"]["finished"]
		check(not fin.is_empty() and not fin.back()[0], "%s: reported as not changed" % how)
		check(cal.to_dict() == d0, "%s: the calibration is unchanged, bit for bit" % how)
		check(geometry(cal) == g0 and res_geometry(res) == rg0, "%s: the wrist neutral and axes, VR's and flight's, unchanged" % how)
		eq(store.writes, writes0, "%s: nothing written" % how)
		eq(wi.replaced, replaced0, "%s: flight's trim untouched" % how)
		rows[how] = {"flow": VRCalibration.Flow.keys()[flow_now], "text": text_now, "reason": node.last_reason}
		VR.active = false
		VR.focused = false
		VR.user_present = true
		(rig["player"] as Object).set("mode_label", "perched")
		b.set_arms(deg_to_rad(-80.0))
		hold(rig, b, VRCalibration.RESULT_SHOW + 0.1)
	metric("cancel", rows)
	Game.set_state(Game.State.BOOT)
	var now := flat_reading(rig, a)
	eq(float(now["pitch"]), float(ref["pitch"]), "A's flat wrists command exactly the same pitch")
	near(float(now["twist_deg"]), float(ref["twist_deg"]), 0.05, "and read the same twist")
	# The Y-hold (1.5 s) starts a step; letting go of Y is not a cancel; a
	# new press is.
	a.set_arms(deg_to_rad(-80.0))
	buttons(rig, a, {"left_hand:by_button": true}, VRControls.HOLD_RECALIBRATE + 0.3)
	eq(node.flow, VRCalibration.Flow.CAPTURE, "the Y-hold starts the step")
	buttons(rig, a, {}, 0.3)
	eq(node.flow, VRCalibration.Flow.CAPTURE, "releasing Y does not cancel it")
	buttons(rig, a, {"left_hand:by_button": true}, 0.05)
	eq(node.flow, VRCalibration.Flow.FAILED, "a new press of Y does")
	buttons(rig, a, {}, 0.05)
	check(cal.to_dict() == d0, "(still unchanged)")
	free_rig(rig)


## Captured, persisted, and reloaded at the next launch (through a real
## ConfigFile): the same calibration, flat wrists read flat for its owner,
## flight gets it; the relaunch asks for nothing and captures nothing, it
## only raises the pause menu's suggestion (whoever launched may be someone
## else).
func test_persisted_and_reloaded() -> void:
	VR.active = true
	VR.focused = true
	Game.set_state(Game.State.MENU)
	var store := MemoryStore.new()
	var rig := make(store)
	var h := wearer(1.85, [15.0, -10.0])
	h.spread_pose()
	hold(rig, h, 2.0)
	var cal := cal_of(rig)
	check(cal.calibrated, "(setup) captured by the first-launch step")
	var d := cal.to_dict()
	free_rig(rig)
	var path := "user://vr_flow_test_%d/settings.cfg" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	eq(store.save_to(path), OK, "saved to a ConfigFile")
	var reloaded := MemoryStore.new()
	eq(reloaded.load_from(path), OK, "and read back")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	check(not VR.recalibration_suggested, "(setup) nothing suggested yet")
	var rig2 := make(reloaded, "spawning")
	var cal2 := cal_of(rig2)
	check(cal2.calibrated, "reloaded at the next launch")
	var d2 := cal2.to_dict()
	for k in d:
		var x: Variant = d[k]
		var y: Variant = d2[k]
		if x is Basis:
			lt(VRMath.basis_angle(x, y), 1e-6, "%s reloaded" % k)
		elif x is float:
			near(float(y), float(x), 1e-9, "%s reloaded" % k)
		elif x is Vector3:
			check((x as Vector3).is_equal_approx(y), "%s reloaded" % k)
		else:
			eq(y, x, "%s reloaded" % k)
	var res2: Resource = rig2["res"]
	check(bool(res2.get("calibrated")), "flight gets the reloaded calibration")
	lt(VRMath.basis_angle(res2.get("neutral_right"), cal2.neutral[1]), 1e-6, "(its wrist neutral)")
	check(not node_of(rig2).first_launch_pending, "a saved calibration: no first-launch step")
	check(not VR.recalibration_suggested, "a relaunch with a saved calibration suggests nothing (the same player, nearly always)")
	h.spread_pose()
	hold(rig2, h, 3.0)
	pitched_spread(h, 15.0)
	hold(rig2, h, 3.0)
	eq(node_of(rig2).flow, VRCalibration.Flow.IDLE, "no card")
	eq(int(rig2["events"]["captured"]), 0, "nothing captured")
	var flat := flat_reading(rig2, h)
	lt(absf(float(flat["pitch"])), 1e-6, "the owner's flat wrists (15° / -10° habit) command no pitch after the reload")
	lt(absf(float(flat["twist_deg"])), 0.5, "and read flat (%.2f°)" % float(flat["twist_deg"]))
	free_rig(rig2)
	# On the desktop a relaunch suggests nothing (nothing to calibrate).
	VR.active = false
	VR.recalibration_suggested = false
	var rig3 := make(reloaded)
	check(cal_of(rig3).calibrated and not VR.recalibration_suggested, "desktop: loaded, nothing suggested")
	free_rig(rig3)


## Nothing that happens around a flight changes the wrist neutral: a still
## glide with the wrists pitched, a landing flare held on the perch (15°
## and 20°, 5 s each, with a one-frame tracking blip in the middle and a
## small movement after it), the headset off and on with the flare held in
## the pause menu, the system menu, a long absence, a re-grip, the Y
## button tapped (not held): the neutral and axes (VR's, flight's, the
## persisted ones) are identical bit for bit, flight's trim is never
## voided, no card ever comes up and nothing ever captures. Only the pause
## menu's suggestion is raised.
func test_nothing_in_flight_changes_the_wrist_neutral() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var res: Resource = rig["res"]
	var wi: _WingInputHook = rig["wing_input"]
	var p: Object = rig["player"]
	var a := wearer(1.72, [5.0, 5.0])
	calibrate(rig, a)
	check(cal.calibrated, "(setup) calibrated")
	var ref := flat_reading(rig, a)
	var g0 := geometry(cal)
	var rg0 := res_geometry(res)
	var sg0 := saved_geometry(rig)
	var replaced0 := wi.replaced
	var caps0 := int(rig["events"]["captured"])
	rig["events"]["max_flow"] = VRCalibration.Flow.IDLE
	rig["events"]["capturing_seen"] = false
	VR.active = true
	VR.focused = true
	VR.session_state = "focused"
	Game.set_state(Game.State.PLAYING)
	# A still glide, wrists 15° leading edge down (a dive trim), 5 s.
	p.set("mode_label", "flying")
	pitched_spread(a, -15.0)
	hold(rig, a, 5.0)
	# Landing flares held on the perch, a blip and a small move in each.
	for flare in [15.0, 20.0]:
		p.set("mode_label", "flying")
		pitched_spread(a, flare)
		hold(rig, a, 0.5)
		p.set("mode_label", "perched")
		hold(rig, a, 2.5)
		blip(rig, a)
		hold(rig, a, 2.5)
		a.set_arms(deg_to_rad(-2.0), 0.0, deg_to_rad(flare), deg_to_rad(5.0))
		hold(rig, a, 0.3)
		pitched_spread(a, flare)
		hold(rig, a, 3.0)
	# The headset off and on with the flare held (the game pauses: the pause
	# menu), then played on.
	VR._on_user_presence_changed(false)
	eq(Game.state, Game.State.PAUSED, "(setup) headset off: paused")
	hold(rig, a, 3.0)
	VR._on_user_presence_changed(true)
	hold(rig, a, 3.0)
	a.spread_pose()
	hold(rig, a, 3.0)
	Game.set_state(Game.State.PLAYING)
	pitched_spread(a, 15.0)
	hold(rig, a, 3.0)
	# The system menu (focus lost and regained), and a long absence.
	VR._on_session_visible()
	hold(rig, a, 2.0)
	VR._on_session_focused()
	Game.set_state(Game.State.PLAYING)
	hold(rig, a, 2.0)
	VR.focused = false
	hold(rig, a, VRCalibration.LONG_ABSENCE + 1.0)
	VR.focused = true
	hold(rig, a, 3.0)
	# A re-grip (the controllers sit 6° differently), perched and still.
	_grip_tilt = Basis(Vector3.RIGHT, deg_to_rad(6.0))
	a.spread_pose()
	hold(rig, a, 4.0)
	_grip_tilt = Basis.IDENTITY
	# Y tapped (not held): nothing.
	buttons(rig, a, {"left_hand:by_button": true}, 0.3)
	buttons(rig, a, {}, 0.3)
	eq(rig["events"]["max_flow"], VRCalibration.Flow.IDLE, "no card ever came up")
	check(not bool(rig["events"]["capturing_seen"]), "nothing was ever capturing")
	eq(int(rig["events"]["captured"]), caps0, "nothing captured")
	check(geometry(cal) == g0, "VR's wrist neutral and axes: identical")
	check(res_geometry(res) == rg0, "flight's: identical")
	check(saved_geometry(rig) == sg0, "the persisted ones: identical")
	eq(wi.replaced, replaced0, "flight's trim never voided")
	check(VR.recalibration_suggested, "the pause menu's suggestion is raised (headset off/on, long absence)")
	Game.set_state(Game.State.BOOT)
	var now := flat_reading(rig, a)
	eq(float(now["pitch"]), float(ref["pitch"]), "flat wrists command exactly the pitch they did (%.4f)" % float(now["pitch"]))
	near(float(now["twist_deg"]), float(ref["twist_deg"]), 0.05, "and read the same twist")
	free_rig(rig)


## The arm span may still grow from genuine spreads in play (fix round 4's
## strict rules: calibration_test, span_refinement_test), and that never
## touches the wrist neutral: a cramped capture (soft elbows) grown by two
## full spreads keeps VR's, flight's and the persisted neutral and axes bit
## for bit, and never voids flight's trim.
func test_span_refinement_never_touches_the_neutral() -> void:
	var store := MemoryStore.new()
	var rig := make(store, "flying")
	var node := node_of(rig)
	var cal := cal_of(rig)
	var res: Resource = rig["res"]
	var wi: _WingInputHook = rig["wing_input"]
	var h := wearer(1.75, [-6.0, 9.0])
	node.start_manual()
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(35.0))
	hold(rig, h, 2.0)
	h.set_arms(deg_to_rad(-80.0))
	hold(rig, h, VRCalibration.RESULT_SHOW + 0.2)
	check(cal.calibrated, "(setup) a cramped capture")
	var span0 := cal.arm_span
	var g0 := geometry(cal)
	var rg0 := res_geometry(res)
	var sg0 := saved_geometry(rig)
	var replaced0 := wi.replaced
	Game.set_state(Game.State.PLAYING)
	for i in 3:
		h.set_arms(deg_to_rad(-3.0))
		hold(rig, h, 1.2)
		h.set_arms(deg_to_rad(-80.0))
		hold(rig, h, 0.3)
	gt(cal.arm_span, span0 + 0.05, "(setup) the span grew (%.3f -> %.3f)" % [span0, cal.arm_span])
	near(float(res.get("arm_span")), cal.arm_span, 1e-6, "flight flies the grown span")
	near(float(saved(rig).get("arm_span", 0.0)), cal.arm_span, 1e-6, "and it is persisted")
	check(geometry(cal) == g0, "VR's wrist neutral and axes: identical")
	check(res_geometry(res) == rg0, "flight's: identical")
	check(saved_geometry(rig) == sg0, "the persisted ones: identical")
	eq(wi.replaced, replaced0, "flight's trim not voided")
	free_rig(rig)


## A step asked for during play (the Y-hold in flight) pauses the game
## first, through the menu request (a UI toggles pause on it: one request,
## paused once), so the capture happens in the pause menu, never in
## flight; the game resumed mid-step cancels it with nothing captured.
func test_recalibrate_during_play_pauses_first() -> void:
	var store := MemoryStore.new()
	var rig := make(store)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var a := wearer(1.6)
	calibrate(rig, a)
	var d0 := cal.to_dict()
	var requests := [0]
	var ui_like := func() -> void:
		requests[0] += 1
		if Game.state == Game.State.PLAYING:
			Game.set_state(Game.State.PAUSED)
	Events.menu_requested.connect(ui_like)
	Game.set_state(Game.State.PLAYING)
	(rig["player"] as Object).set("mode_label", "flying")
	VR.recalibrate_requested.emit()
	eq(Game.state, Game.State.PAUSED, "the game is paused before the card comes up")
	check(get_tree().paused, "(the tree too)")
	eq(requests[0], 1, "through one menu request (the UI shows the pause menu)")
	eq(node.flow, VRCalibration.Flow.CAPTURE, "the card is up")
	var b := wearer(1.9, [20.0, 20.0])
	b.spread_pose()
	hold(rig, b, 2.0)
	check(cal.calibrated and cal.arm_span > 1.8, "captured in the pause menu: player B")
	eq(node.flow, VRCalibration.Flow.DONE, "confirmed")
	var d1 := cal.to_dict()
	check(d1 != d0, "(the calibration is B's now)")
	hold(rig, b, VRCalibration.RESULT_SHOW + 0.1)
	# Resumed mid-step: cancelled, nothing captured in flight.
	node.start_manual()
	a.spread_pose()
	hold(rig, a, 0.6)
	Game.set_state(Game.State.PLAYING)
	hold(rig, a, 3.0)
	eq(node.flow, VRCalibration.Flow.IDLE, "resumed: the step ended (its short card is gone)")
	check(cal.to_dict() == d1, "nothing captured in flight")
	eq(requests[0], 1, "(no further pause requests)")
	Events.menu_requested.disconnect(ui_like)
	free_rig(rig)


## The headset coming off and back on only raises the pause menu's
## suggestion (VR.recalibration_suggested, with its signal): no card, no
## capture, nothing written, the calibration unchanged. So does a loss of
## focus of at least LONG_ABSENCE; a short one (the system menu) does not.
## A completed step clears it. On the desktop nothing is suggested.
func test_presence_change_only_raises_the_flag() -> void:
	VR.active = true
	VR.focused = true
	VR.session_state = "focused"
	Game.set_state(Game.State.MENU)
	var store := MemoryStore.new()
	var rig := make(store)
	var node := node_of(rig)
	var cal := cal_of(rig)
	var a := wearer(1.7, [6.0, 6.0])
	a.spread_pose()
	hold(rig, a, 2.0)
	a.set_arms(deg_to_rad(-80.0))
	hold(rig, a, VRCalibration.RESULT_SHOW + 0.2)
	check(cal.calibrated, "(setup) calibrated at the first launch")
	check(not VR.recalibration_suggested, "(setup) nothing suggested")
	_suggested.clear()
	var d0 := cal.to_dict()
	var writes0 := store.writes
	var caps0 := int(rig["events"]["captured"])
	rig["events"]["max_flow"] = VRCalibration.Flow.IDLE
	Game.set_state(Game.State.PLAYING)
	VR._on_user_presence_changed(false)
	pitched_spread(a, 18.0)
	hold(rig, a, 3.0)
	check(not VR.recalibration_suggested, "headset off: nothing yet")
	VR._on_user_presence_changed(true)
	check(VR.recalibration_suggested, "headset back on: the pause menu suggests recalibrating")
	eq(_suggested, [true], "(signalled once)")
	hold(rig, a, 3.0)
	Game.set_state(Game.State.PLAYING)
	hold(rig, a, 3.0)
	eq(rig["events"]["max_flow"], VRCalibration.Flow.IDLE, "no card")
	eq(int(rig["events"]["captured"]), caps0, "no capture")
	eq(store.writes, writes0, "nothing written")
	check(cal.to_dict() == d0, "the calibration unchanged")
	# A completed step clears it.
	Game.set_state(Game.State.PAUSED)
	node.start_manual()
	a.spread_pose()
	hold(rig, a, 2.0)
	check(not VR.recalibration_suggested, "a completed step clears the suggestion")
	eq(_suggested, [true, false], "(signalled)")
	hold(rig, a, VRCalibration.RESULT_SHOW + 0.1)
	# Focus lost for a short while (the system menu), then a long absence.
	VR.focused = false
	hold(rig, a, 10.0)
	VR.focused = true
	hold(rig, a, 0.5)
	check(not VR.recalibration_suggested, "10 s without focus: nothing")
	VR.focused = false
	hold(rig, a, VRCalibration.LONG_ABSENCE - 1.0)
	check(not VR.recalibration_suggested, "%.0f s: not yet" % (VRCalibration.LONG_ABSENCE - 1.0))
	hold(rig, a, 1.5)
	check(VR.recalibration_suggested, "%.0f s without focus: suggested" % VRCalibration.LONG_ABSENCE)
	VR.focused = true
	free_rig(rig)
	# Desktop: never.
	_reset_world()
	var r2 := make(MemoryStore.new())
	VR._on_user_presence_changed(false)
	VR._on_user_presence_changed(true)
	hold(r2, a, 0.1)
	check(not VR.recalibration_suggested, "desktop: nothing suggested")
	free_rig(r2)


## The card: the exact instruction, a cancel hint, the pose's problem as the
## hint once the pose has been missing a second, the ring filling during
## the hold, the confirmation with a tick and the span, a cancel with a
## cross; wide enough for its text and legible (>= 1.5° per line); gone
## when idle.
func test_the_card() -> void:
	var rig := make(MemoryStore.new(), "perched", true)
	var node := node_of(rig)
	var h := wearer(1.7)
	h.set_arms(deg_to_rad(-45.0))
	node.start_manual()
	hold(rig, h, 0.3)
	var card := node.prompt
	check(card != null and card.visible, "shown")
	eq(card.text.text, VRCalibration.PROMPT, "the instruction")
	eq(card.hint.text, VRCalibration.CANCEL_HINT, "at first the hint says how to cancel")
	hold(rig, h, 1.0)
	# What to change, and (integration round 2) still how to cancel under it.
	eq(card.hint.text, "Hold your arms level\n" + VRCalibration.CANCEL_HINT, "after a second without the pose: what to change, and how to cancel")
	var left := card.height + 0.02
	var tw := maxf(CalibrationPrompt.text_size(card.text.text, CalibrationPrompt.FONT_SIZE).x,
		CalibrationPrompt.text_size(card.hint.text, CalibrationPrompt.HINT_FONT_SIZE).x)
	check(left + tw <= card.width + 1e-6, "the card is wide enough for its text (%.3f m text, %.3f m card)" % [tw, card.width])
	# The brief's legibility bar the UI's way (capital height >= 1.5°, in the
	# card's own font: round 2 measured the hint at ~1.0° in the mirror).
	gt(CalibrationPrompt.cap_deg(CalibrationPrompt.HINT_FONT_SIZE), 1.5, "the hint's capitals are >= 1.5° tall (%.2f°)" % CalibrationPrompt.cap_deg(CalibrationPrompt.HINT_FONT_SIZE))
	gt(CalibrationPrompt.cap_deg(CalibrationPrompt.FONT_SIZE), 1.5, "the instruction's capitals are >= 1.5° tall (%.2f°)" % CalibrationPrompt.cap_deg(CalibrationPrompt.FONT_SIZE))
	eq(card.text.font, CalibrationPrompt.card_font(), "in the UI's font")
	var th := CalibrationPrompt.text_size(card.text.text, CalibrationPrompt.FONT_SIZE).y + CalibrationPrompt.GAP + CalibrationPrompt.text_size(card.hint.text, CalibrationPrompt.HINT_FONT_SIZE).y
	lt(th, card.height - 0.02, "both text blocks fit the card's height (%.3f m text, %.3f m card)" % [th, card.height])
	metric("card_m", {"width": snappedf(card.width, 0.001), "height": snappedf(card.height, 0.001),
		"cap_deg": [snappedf(CalibrationPrompt.cap_deg(CalibrationPrompt.FONT_SIZE), 0.01), snappedf(CalibrationPrompt.cap_deg(CalibrationPrompt.HINT_FONT_SIZE), 0.01)]})
	move_to(rig, h, func() -> void: h.spread_pose(), 0.4)
	hold(rig, h, 1.0)
	gt(card.progress, 0.3, "the ring fills during the hold (%.2f)" % card.progress)
	eq(card.step, CalibrationPrompt.Step.POSE, "(not captured yet)")
	eq(card.hint.text, VRCalibration.CANCEL_HINT, "a good pose: back to the cancel hint")
	hold(rig, h, 0.8)
	eq(card.step, CalibrationPrompt.Step.DONE, "the confirmation: a tick")
	check(card.text.text.begins_with("Wings calibrated\nArm span "), "'%s'" % card.text.text.replace("\n", " / "))
	eq(card.hint.text, "", "no hint on the confirmation")
	hold(rig, h, VRCalibration.RESULT_SHOW + 0.1)
	check(not card.visible, "gone when idle")
	node.start_manual()
	hold(rig, h, 0.1)
	node.cancel()
	hold(rig, h, 0.1)
	check(card.visible and card.step == CalibrationPrompt.Step.FAILED, "cancelled: a cross")
	eq(card.text.text, "Calibration cancelled\nYour wings are unchanged", "and what happened")
	hold(rig, h, VRCalibration.CANCEL_SHOW)
	check(not card.visible, "gone when idle")
	# Seated play (integration round 2): the card does not say "Stand".
	Settings.set_value("seated", true)
	node.start_manual()
	hold(rig, h, 0.1)
	eq(card.text.text, VRCalibration.PROMPT_SEATED, "seated: 'Sit tall ...'")
	check(not card.text.text.contains("Stand"), "no 'Stand' to a seated player")
	node.cancel()
	hold(rig, h, VRCalibration.CANCEL_SHOW + 0.1)
	Settings.set_value("seated", false)
	free_rig(rig)
