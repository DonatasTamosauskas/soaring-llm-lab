class_name VRCalibration
extends Node
## The calibration service on the rig: feeds a WingCalibrator with the
## tracked poses every frame, runs the ONE calibration step, persists the
## result through Settings, and writes it into the flight area's
## WingCalibration.
##
## The calibration step (the lead's redesign after fix round 6; VR.md §2.3).
## Wrist neutral and arm span are captured only here, only when the player
## is asked:
##   - on the first launch (no saved calibration) before the first flight.
##     In the game (main.tscn) Play is the gate (integration round 1,
##     FirstFlightGate): the menu closes, the card comes up, and the run
##     starts after the capture or an explicit skip (B or Y). Scenes without
##     a gate (first_launch_prompt, the default) start it by themselves once
##     the headset is on and focused, outside play;
##   - whenever the player chooses Recalibrate: Settings > Recalibrate wings
##     and the pause menu's "New player? Recalibrate wings" (both
##     UIRoot.recalibrate_requested), the Y-hold (VR.recalibrate_requested),
##     or start_manual().
## The card says "Stand tall. Spread your wings, hands flat. Hold still.";
## the capture fires when that pose is plausible (both hands tracked, arms
## spread level at shoulder height, evenly, the head up) and still for
## WingCalibrator.NEUTRAL_HOLD (1 s, unbroken); a short confirmation
## follows. B or Y cancels (the calibration held, or the defaults, stay), so
## does the game going back into play, the headset coming off, or (a
## requested step) STEP_TIMEOUT. A step asked for during play pauses the
## game first: a capture never happens while the bird flies.
##
## Nothing else ever touches the wrist neutral: no automatic capture, no
## re-check, no card answered by a pose (every one of those eventually took
## a pose the player did not mean, a landing flare held on a perch the last
## one, as their "flat"). The headset coming off and back on, or a long loss
## of focus, only raise VR.recalibration_suggested: the pause menu then
## offers "New player? Recalibrate wings". A completed step clears it. (An
## app start with a saved calibration no longer raises it, integration
## round 1: a relaunch is nearly always the same player, who then saw the
## suggestion every session.)
## The arm span alone may still grow from genuine spreads while the game is
## played (WingCalibrator.spread_span_sample: the strict fix-round-4 rules),
## which never changes the neutral.
##
## One calibration, and it is VR's (fix round 2). Flight's WingInput has an
## automatic capture of its own; while this node runs it switches the
## PlayerBird's auto_calibrate off (restored when it leaves). A capture
## flight makes anyway through its own explicit begin_calibration (or one
## taken before the extras attached) is adopted and refined to VR's maths
## (WingCalibrator.adopt), written back to flight and persisted
## (foreign_capture). A VR calibration always reaches the PlayerBird,
## including a new one (respawn) or one whose resource was reset, and so do
## its refinements (span, seated). After a new neutral flight is told its
## old trim is void (notify_calibration_replaced).
##
## Poses are read from the rig's nodes (XRCamera3D, grip XRController3Ds),
## local to the XROrigin3D with the origin divided by world_scale: that is
## tracking space whether a real tracker or a synthetic pose source (flight's
## scripted / desktop sources write the nodes) moved them.

signal calibration_changed()
signal flow_changed(step: StringName, prompt: String, progress: float)
signal flow_finished(ok: bool, reason: String)

## CAPTURE: the card is up, waiting for the pose; DONE / FAILED: the short
## result card (FAILED also for a cancel: the calibration is unchanged).
enum Flow { IDLE, CAPTURE, DONE, FAILED }

## What the card asks, exactly (the lead's wording)...
const PROMPT := "Stand tall. Spread your wings,\nhands flat. Hold still."
## ...and seated (Settings "seated"; integration round 2: the card said
## "Stand tall" to a seated player although seated capture is supported).
const PROMPT_SEATED := "Sit tall. Spread your wings,\nhands flat. Hold still."
const CANCEL_HINT := "B or Y: cancel"
## The first-launch step's hint: there is nothing to cancel back to, the
## run starts with the default wings.
const SKIP_HINT := "B or Y: skip (default wings)"
## A step the player asked for goes away after this long without the pose
## (the first-launch step waits: it is the game's first screen).
const STEP_TIMEOUT := 45.0
## How long the confirmation / the "not changed" card stays.
const RESULT_SHOW := 2.0
const CANCEL_SHOW := 1.5
## Focus lost at least this long (the headset asleep on a runtime without
## presence events, or put down) counts as a possible new player.
const LONG_ABSENCE := 60.0
## The card's hint says what is wrong with the pose once the step has run
## this long (a moment to get into it first), and keeps saying it this long
## after the pose was last wrong (no flicker while the hold starts again).
const HINT_AFTER := 1.0
const HINT_LINGER := 0.4
const SETTINGS_KEY := "wing_calibration"

var calibrator := WingCalibrator.new()
var origin: XROrigin3D
var camera: Node3D
var hands: Array[Node3D] = [null, null]
## Where calibration is persisted: anything with get_value/set_value (the
## Settings autoload by default). Tests pass a private store so they never
## write the shared user://settings.cfg.
var store: Object = null
## Wings to glow on success (optional).
var wings: FirstPersonWings
## Validity override for tests/desktop: null = decide from the nodes.
var force_valid: Variant = null
## Tests: override the span-refinement gate (null = decide from the game).
var force_refine_allowed: Variant = null
## Take the calibration over from the PlayerBird (see above).
@export var own_auto_capture := true
@export var persist := true
@export var show_prompt := true
## Tests set false and call tick(dt).
@export var auto_tick := true
## With no saved calibration, start the step by itself in VR (first launch).
@export var first_launch_prompt := true

var flow: Flow = Flow.IDLE
## Why the running step was started: &"first_launch" or &"manual".
var flow_reason: StringName = &""
var flow_time := 0.0
var last_reason := ""
## Uncalibrated at load (first launch, or a corrupt save): the step starts
## by itself at the first moment the headset is on and focused outside play,
## until it completes or the player cancels it or starts playing instead.
var first_launch_pending := false
## The instruction card (created on the first flow, under the origin).
var prompt: CalibrationPrompt
var _result_t := 0.0
var _glow_t := 0.0
## What the hint says is wrong with the pose ("" = nothing: the cancel
## hint), and for how much longer.
var _hint := ""
var _hint_t := 0.0
var _ui: Node = null
var _ui_retry := 0.0
## The PlayerBird whose automatic capture this node switched off, and the
## value to restore.
var _claimed: Object = null
var _claimed_prev := true
## player_calibration() cache.
const RES_REFRESH := 30
var _res_owner: Object = null
var _res_cache: Object = null
var _res_age := 0
## A flight resource whose capture was rejected as corrupt, and its
## neutral then (so it is not retried every tick).
var _rejected_res: Object = null
var _rejected_sig := ""
## Seconds without focus (VR only), for LONG_ABSENCE.
var _absent_t := 0.0
## The result card's lines.
var _result_text := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Before the wings read the calibrator this frame.
	process_priority = 50
	calibrator.captured.connect(_on_captured)
	calibrator.rejected.connect(_on_rejected)
	calibrator.refined.connect(_on_refined)
	load_saved()
	VR.recalibrate_requested.connect(start_manual)
	VR.user_presence_changed.connect(_on_presence_changed)
	VR.controls.button_changed.connect(_on_button)
	Events.settings_changed.connect(_on_settings_changed)
	# A new PlayerBird (respawn, new run) gets the current calibration.
	Events.player_spawned.connect(func(_p: Bird) -> void: apply_to_player())
	_connect_ui.call_deferred()


func _exit_tree() -> void:
	# The card lives under the rig's origin: take it along.
	if prompt != null and is_instance_valid(prompt):
		prompt.queue_free()
	prompt = null
	# Without VR's calibration, flight captures by itself again.
	_release_claim()


func _store() -> Object:
	return store if store != null else Settings


## Loads the persisted calibration and pushes it to the player. Without one
## (or with a corrupt one) the defaults apply and the first-launch step is
## due; with one, nothing is asked or suggested (never a capture).
func load_saved() -> void:
	var s := _store()
	var d: Variant = s.call("get_value", SETTINGS_KEY, {})
	if d is Dictionary and not (d as Dictionary).is_empty():
		calibrator.from_dict(d)
		print("[vr] calibration loaded: span %.2f m, drop %.2f m, seated %s" % [calibrator.arm_span, calibrator.shoulder_drop, str(calibrator.is_seated())])
	calibrator.seated_setting = bool(s.call("get_value", "seated", false))
	apply_to_player()
	first_launch_pending = not calibrator.calibrated


## Settings > Recalibrate in the UI. The UI may appear after the rig (or be
## rebuilt), so this is retried once a second until connected.
func _connect_ui() -> void:
	var ui := get_tree().get_first_node_in_group(&"ui_root") if is_inside_tree() else null
	if ui != null and ui.has_signal(&"recalibrate_requested"):
		if not ui.is_connected(&"recalibrate_requested", start_manual):
			ui.connect(&"recalibrate_requested", start_manual)
		_ui = ui


func _on_settings_changed(key: String, value: Variant) -> void:
	if key == "seated":
		calibrator.seated_setting = bool(value)
		apply_to_player()


## Headset off: a step in progress is abandoned (nothing is captured from a
## headset on the table). Back on: maybe someone else, so the pause menu
## suggests recalibrating; nothing is recalibrated.
func _on_presence_changed(present: bool) -> void:
	if present:
		_suggest("headset put back on")
	elif flow == Flow.CAPTURE:
		_abandon("headset off")


## B or Y pressed (either controller) while the card waits: cancel. Only a
## press that starts while the step runs (the Y-hold that started it is
## still down, and its release is no press).
func _on_button(_hand: StringName, action: StringName, pressed: bool) -> void:
	if pressed and action == &"by_button" and flow == Flow.CAPTURE:
		cancel()


## Raises the pause menu's "New player? Recalibrate wings" (VR only: on the
## desktop there is nothing to calibrate). Never recalibrates.
func _suggest(why: String) -> void:
	if not VR.active:
		return
	if not VR.recalibration_suggested:
		print("[vr] recalibration suggested (%s): the pause menu offers it; the calibration is unchanged" % why)
	VR.suggest_recalibration(true)


func _process(dt: float) -> void:
	if _ui == null or not is_instance_valid(_ui):
		_ui_retry -= dt
		if _ui_retry <= 0.0:
			_ui_retry = 1.0
			_connect_ui()
	if auto_tick:
		tick(dt)


func tick(dt: float) -> void:
	var t0 := VRProfile.begin()
	claim_auto_capture()
	_track_absence(dt)
	# Before the poses are fed: a step that must not capture any more (the
	# game is being played, the headset is off) ends first, so no capture
	# can complete on this tick.
	_guard_flow()
	_maybe_start_first_launch()
	calibrator.refine_allowed = refine_safe() if calibrator.calibrated else false
	sample(dt)
	_sync_with_player()
	_update_flow(dt)
	_update_feedback(dt)
	VRProfile.add(&"calibration", t0)


## A long loss of focus may be a hand-over (a runtime without presence
## events shows a removal only as lost focus): suggest, never recalibrate.
func _track_absence(dt: float) -> void:
	if VR.active and not VR.focused:
		_absent_t += dt
		if _absent_t >= LONG_ABSENCE and _absent_t - dt < LONG_ABSENCE:
			_suggest("no focus for %.0f s" % LONG_ABSENCE)
	else:
		_absent_t = 0.0


## True while the game is being played (the bird can fly): PLAYING or the
## caught moment, and the tree not paused.
func game_in_play() -> bool:
	if is_inside_tree() and get_tree().paused:
		return false
	return Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT


## The step only runs outside play and with the headset on (in VR).
func _guard_flow() -> void:
	if flow != Flow.CAPTURE:
		return
	if game_in_play():
		# The player went back to flying (Resume, Play): their choice.
		if flow_reason == &"first_launch":
			first_launch_pending = false
		cancel("the game resumed")
	elif VR.active and not VR.focused:
		_abandon("headset off or the system menu")


func _maybe_start_first_launch() -> void:
	if not first_launch_pending or not first_launch_prompt or flow != Flow.IDLE:
		return
	if calibrator.calibrated:
		first_launch_pending = false
		return
	if not (VR.active and VR.focused):
		return
	if origin == null or not is_instance_valid(origin) or camera == null:
		return
	# (A run already under way, e.g. a scene that starts flying at once, is
	# paused for it by start(): the step comes before the first flight.)
	print("[vr] first launch: no saved calibration, asking for one")
	start(&"first_launch")


## Switches the current PlayerBird's own automatic capture off (duck-typed:
## anything with an auto_calibrate property), restoring the previous one's.
## A calibration VR already holds is pushed to a newly claimed player.
## Runs every tick (a respawned PlayerBird is claimed within a frame; its
## own capture needs a 1.2 s hold) and when the rig extras attach.
func claim_auto_capture() -> void:
	var p: Object = Birds.player() if own_auto_capture else null
	if _claimed != null and (not is_instance_valid(_claimed) or _claimed != p):
		_release_claim()
	if p == null or p == _claimed or not ("auto_calibrate" in p):
		return
	_claimed = p
	_claimed_prev = bool(p.get("auto_calibrate"))
	p.set("auto_calibrate", false)
	print("[vr] wing calibration is VR's: %s's own automatic capture switched off" % str((p as Node).name))
	if calibrator.calibrated:
		apply_to_player()


func _release_claim() -> void:
	if _claimed != null and is_instance_valid(_claimed):
		_claimed.set("auto_calibrate", _claimed_prev)
	_claimed = null


## One calibration between VR and flight: VR's goes to a PlayerBird whose
## resource is uncalibrated (new or reset); a capture flight made (its own
## begin_calibration, or one taken before the extras attached) is adopted
## and refined (and then written back).
func _sync_with_player() -> void:
	var res := player_calibration()
	if res == null:
		return
	var c: Variant = res.get("calibrated")
	var theirs: bool = c is bool and c
	if calibrator.calibrated and not theirs:
		apply_to_player()
	elif theirs and (not calibrator.calibrated or foreign_capture(res)):
		_adopt_player_capture(res)
	elif calibrator.calibrated and span_drifted(res):
		# Flight's WingInput may refine the span by its own rule; VR's span is
		# the one the player flies, so it is put back at once (fix round 4).
		apply_to_player()


## True when flight's resource flies another arm span / shoulder width than
## VR's (its own continuous refinement changed them).
func span_drifted(res: Object) -> bool:
	if not ("arm_span" in res):
		return false
	var a: Variant = res.get("arm_span")
	var w: Variant = res.get("shoulder_width") if "shoulder_width" in res else calibrator.shoulder_width
	return (a is float and absf(float(a) - calibrator.arm_span) > 1e-4) or (w is float and absf(float(w) - calibrator.shoulder_width) > 1e-4)


## How far flight's neutrals may be from VR's before they count as another
## capture: far above a float or ConfigFile round trip (~1e-7 rad), far
## below any real re-capture (a held pose differs by degrees).
const FOREIGN_TOL := 1e-3


## True when flight's resource holds neutrals VR did not write: flight
## captured (its begin_calibration), or a resource that arrived with
## another capture. False for a resource without the §5.11 neutrals.
func foreign_capture(res: Object) -> bool:
	for i in 2:
		var key := "neutral_left" if i == 0 else "neutral_right"
		if not (key in res):
			return false
		var b: Variant = res.get(key)
		if not (b is Basis):
			return false
		# Exactly what VR wrote (the every-tick case): no rotation maths.
		if b == calibrator.neutral[i]:
			continue
		if VRMath.basis_angle((b as Basis).orthonormalized(), calibrator.neutral[i]) > FOREIGN_TOL:
			return true
	return false


## True when a spread may refine the arm span (fix round 4): the game is
## being played (PLAYING, or BOOT in scenes without a game loop), the tree
## is not paused and the headset has focus and is worn. Never in the menus.
## The pose itself is checked by WingCalibrator.spread_span_sample.
func refine_safe() -> bool:
	if force_refine_allowed != null:
		return bool(force_refine_allowed)
	if is_inside_tree() and get_tree().paused:
		return false
	if VR.active and not VR.focused:
		return false
	return Game.state == Game.State.PLAYING or Game.state == Game.State.BOOT


## Flight holds a capture VR did not make: adopt it, refined to VR's maths
## (anthropometric shoulder height, full-spread span, re-aimed axes,
## canonical neutrals), write it back to flight and persist it, so the
## wings, the persisted settings and flight agree.
func _adopt_player_capture(res: Object) -> void:
	if res == _rejected_res and str(res.get("neutral_left")) == _rejected_sig:
		return
	var before := [float(res.get("arm_span")), float(res.get("shoulder_drop"))]
	if not calibrator.adopt(res):
		# Corrupt neutrals or axes: not adopted (and not retried every tick
		# while the resource holds the same ones). VR's own calibration, if
		# it has one, replaces them in flight.
		_rejected_res = res
		_rejected_sig = str(res.get("neutral_left"))
		apply_to_player()
		return
	print("[vr] adopted flight's calibration (span %.3f m, drop %.3f m) refined to span %.3f m, drop %.3f m" % [before[0], before[1],
		calibrator.arm_span, calibrator.shoulder_drop])
	first_launch_pending = false
	apply_to_player()
	_save()
	calibration_changed.emit()


## Reads the rig nodes and feeds one measurement.
func sample(dt: float) -> void:
	if origin == null or not is_instance_valid(origin) or camera == null:
		return
	var ws := maxf(origin.world_scale, 1e-4)
	var h := _local(camera, ws)
	var l := _local(hands[0], ws)
	var r := _local(hands[1], ws)
	var mask := 1
	if _valid(hands[0]):
		mask |= 2
	if _valid(hands[1]):
		mask |= 4
	calibrator.measure(h, l, r, mask, dt)


func _local(n: Node3D, ws: float) -> Transform3D:
	if n == null or not is_instance_valid(n) or not n.is_inside_tree():
		return Transform3D.IDENTITY
	# XR nodes are normally the origin's children: their own transform is
	# already origin-local (no global transforms to compose). Relative to
	# the origin even if a node is nested deeper.
	var t := n.transform if n.get_parent() == origin else origin.global_transform.affine_inverse() * n.global_transform
	return Transform3D(t.basis.orthonormalized(), t.origin / ws)


func _valid(n: Node3D) -> bool:
	if force_valid != null:
		return bool(force_valid)
	if n == null or not is_instance_valid(n) or not n.is_inside_tree():
		return false
	if VR.active and n is XRNode3D:
		return (n as XRNode3D).get_has_tracking_data()
	return true


# =============================================================================
# The calibration step
# =============================================================================

## Recalibrate (Settings, the pause menu, the Y-hold).
func start_manual() -> void:
	start(&"manual")


## True while the first flight should wait for the first-launch step: in
## the headset, nothing calibrated, and the player has not skipped it this
## session. The game's Play gate (FirstFlightGate) asks this.
func first_launch_due() -> bool:
	return VR.active and first_launch_pending and not calibrator.calibrated


## The first-launch step, started by the game's Play gate (the menu is
## closed first: the card never overlaps a panel).
func start_first_launch() -> void:
	start(&"first_launch")


## Shows the card and waits for the pose. During play the game is paused
## first (the menu comes up): the capture never happens while flying. A
## step already waiting keeps waiting (its hold starts again).
func start(reason: StringName = &"manual") -> void:
	if game_in_play():
		_pause_game()
	print("[vr] calibration step started (%s)" % reason)
	flow_reason = reason
	_hint = ""
	_hint_t = 0.0
	calibrator.request_capture()
	_set_flow(Flow.CAPTURE)


## Pauses a running game the way the menu button does (the UI shows the
## pause menu); directly when nothing handled the request (dev scenes).
func _pause_game() -> void:
	Events.menu_requested.emit()
	if game_in_play():
		Game.set_state(Game.State.PAUSED)


## Cancels the step (B / Y, the game resumed, cancel()): the calibration
## held (or the defaults) stays exactly as it was; a short card says so.
## A first-launch step cancelled by the player is not asked again this
## session (Recalibrate is always there).
func cancel(why: String = "cancelled") -> void:
	if flow != Flow.CAPTURE:
		if flow != Flow.IDLE:
			_set_flow(Flow.IDLE)
		return
	calibrator.cancel_capture()
	if flow_reason == &"first_launch" and why == "cancelled":
		first_launch_pending = false
	print("[vr] calibration step cancelled (%s): calibration unchanged" % why)
	last_reason = why
	var skipped := flow_reason == &"first_launch" and not calibrator.calibrated
	_result_text = "%s\n%s" % ["Calibration skipped" if skipped else "Calibration cancelled", _unchanged_line()]
	_set_flow(Flow.FAILED, CANCEL_SHOW)
	flow_finished.emit(false, why)


## Ends a running step without a result card (the game's Play gate when the
## menu button brings the menu back). Nothing changes; a first-launch step
## stays due.
func abandon(why: String) -> void:
	if flow == Flow.CAPTURE:
		_abandon(why)


## Ends a step nobody can see (headset off, system menu): no result card.
## A first-launch step is asked again once the headset is back on.
func _abandon(why: String) -> void:
	calibrator.cancel_capture()
	print("[vr] calibration step abandoned (%s): calibration unchanged" % why)
	last_reason = why
	_set_flow(Flow.IDLE)
	flow_finished.emit(false, why)


func _unchanged_line() -> String:
	return "Your wings are unchanged" if calibrator.calibrated else "Using default wings"


func is_running() -> bool:
	return flow == Flow.CAPTURE


## {step, prompt, progress, calibrated, reason, blocker}
func status() -> Dictionary:
	var cs := calibrator.capture_status()
	return {"step": _step_name(flow), "prompt": prompt_text(), "progress": cs["progress"],
		"calibrated": calibrator.calibrated, "reason": last_reason,
		"blocker": calibrator.neutral_blocker() if flow == Flow.CAPTURE else ""}


func prompt_text() -> String:
	match flow:
		Flow.CAPTURE:
			return PROMPT_SEATED if calibrator.seated_setting else PROMPT
		Flow.DONE, Flow.FAILED:
			return _result_text
	return ""


## The card's dimmer lines: how to skip or cancel, always, and above it what
## is wrong with the pose (see HINT_AFTER / HINT_LINGER). Integration round
## 2 (the Quest verifier): the pose's problem replaced the skip line after
## 1 s, so a player who could not meet the pose never learned that B or Y
## skips.
func hint_text() -> String:
	if flow != Flow.CAPTURE:
		return ""
	var way_out := SKIP_HINT if flow_reason == &"first_launch" else CANCEL_HINT
	if _hint == "":
		return way_out
	var why := "keep both controllers in view" if _hint == "tracking" else _hint
	return "%s\n%s" % [why.substr(0, 1).to_upper() + why.substr(1), way_out]


func _step_name(f: Flow) -> StringName:
	return [&"idle", &"capture", &"done", &"failed"][f]


func _set_flow(f: Flow, show_for: float = RESULT_SHOW) -> void:
	flow = f
	flow_time = 0.0
	if f == Flow.DONE or f == Flow.FAILED:
		_result_t = show_for
	flow_changed.emit(_step_name(f), prompt_text(), 0.0)


func _update_flow(dt: float) -> void:
	if flow == Flow.IDLE:
		return
	flow_time += dt
	match flow:
		Flow.CAPTURE:
			var progress := float(calibrator.capture_status()["progress"])
			var why := calibrator.neutral_blocker()
			if why != "" and flow_time >= HINT_AFTER:
				_hint = why
				_hint_t = HINT_LINGER
			elif _hint_t > 0.0:
				_hint_t -= dt
				if _hint_t <= 0.0:
					_hint = ""
			if flow_reason != &"first_launch" and flow_time > STEP_TIMEOUT:
				calibrator.cancel_capture()
				last_reason = "timed out"
				print("[vr] calibration step timed out: calibration unchanged")
				_result_text = "Calibration not changed\n(no spread held in %.0f s)" % STEP_TIMEOUT
				_set_flow(Flow.FAILED)
				flow_finished.emit(false, last_reason)
			else:
				flow_changed.emit(_step_name(flow), prompt_text(), progress)
		Flow.DONE, Flow.FAILED:
			_result_t -= dt
			if _result_t <= 0.0:
				flow = Flow.IDLE


func _on_captured(_kind: StringName) -> void:
	print("[vr] calibration captured: span %.3f m, width %.3f m, drop %.3f m, seated %s" % [
		calibrator.arm_span, calibrator.shoulder_width, calibrator.shoulder_drop, str(calibrator.is_seated())])
	_save()
	apply_to_player()
	notify_calibration_replaced()
	VR.haptics.play(&"confirm")
	_glow_t = 0.6
	first_launch_pending = false
	VR.suggest_recalibration(false)
	calibration_changed.emit()
	last_reason = ""
	_result_text = "Wings calibrated\nArm span %.2f m" % calibrator.arm_span
	_set_flow(Flow.DONE)
	flow_finished.emit(true, "")


## The span grew or the seating changed: persist it, and let flight fly it
## now (fix round 3). A capture flight made meanwhile is adopted first, so
## it is never overwritten. Never the wrist neutral.
func _on_refined(_span: float) -> void:
	_sync_with_player()
	_save()
	apply_to_player()


## Flight's WingInput keeps state relative to the old neutral that only
## its own capture clears: the neutral-twist auto-trim (up to ±10°, τ 60 s,
## FLIGHT_SPEC §5.10). After VR replaces the neutrals VR calls flight's
## WingInput.calibration_replaced() (requested in ARCHITECTURE, "vr (fix
## round 3)", and added by flight), duck-typed.
func notify_calibration_replaced() -> void:
	var p := Birds.player()
	if p == null:
		return
	var wi: Variant = p.get("wing_input")
	if wi is Object and (wi as Object).has_method(&"calibration_replaced"):
		(wi as Object).call(&"calibration_replaced")


func _on_rejected(_kind: StringName, reason: String) -> void:
	print("[vr] calibration rejected: %s (calibration unchanged)" % reason)
	last_reason = reason
	if flow == Flow.CAPTURE:
		_result_text = "Calibration not changed\n(%s)" % reason
		_set_flow(Flow.FAILED)
		flow_finished.emit(false, reason)


func _save() -> void:
	if not persist:
		return
	var s := _store()
	s.call("set_value", SETTINGS_KEY, calibrator.to_dict())
	# Deprecated mirror (FLIGHT_SPEC §15.2): older readers use "arm_span".
	s.call("set_value", "arm_span", calibrator.arm_span)


## The flight area's WingCalibration in use (PlayerBird.wing_input.calibration),
## or null when there is no PlayerBird yet.
func player_calibration() -> Object:
	var p := Birds.player()
	if p == null:
		return null
	# Looked up by name through two objects: cached per PlayerBird and
	# refreshed every RES_REFRESH calls (a new WingInput or resource is
	# picked up within a few frames).
	if p == _res_owner and _res_cache != null and is_instance_valid(_res_cache) and _res_age < RES_REFRESH:
		_res_age += 1
		return _res_cache
	var found: Object = null
	var wi: Variant = p.get("wing_input")
	if wi is Object and (wi as Object).get("calibration") is Resource:
		found = (wi as Object).get("calibration")
	else:
		var c: Variant = p.get("calibration")
		if c is Resource:
			found = c
	_res_owner = p
	_res_cache = found
	_res_age = 0
	return found


## Pushes the calibration into flight's resource. Uncalibrated, it never
## overwrites what flight holds (its defaults, or what it loaded): only a
## seated preference is passed on (never clearing flight's own detection).
func apply_to_player() -> void:
	var res := player_calibration()
	if res == null:
		return
	if calibrator.calibrated:
		calibrator.apply_to(res)
	elif calibrator.is_seated() and "seated" in res:
		res.set("seated", true)


# =============================================================================
# Feedback: the card and the wing glow
# =============================================================================

func _update_feedback(dt: float) -> void:
	if wings != null and is_instance_valid(wings):
		var pulse := 0.0
		if is_running():
			# Breathing glow that brightens as the hold progresses.
			var p := float(calibrator.capture_status()["progress"])
			pulse = 0.15 + 0.35 * p + 0.1 * sin(flow_time * TAU * 1.5)
		if _glow_t > 0.0:
			_glow_t -= dt
			pulse = maxf(pulse, clampf(_glow_t / 0.6, 0.0, 1.0))
		wings.glow = pulse
	if show_prompt:
		_update_card(dt)


func _update_card(dt: float = 0.0) -> void:
	var want := flow != Flow.IDLE and camera != null and origin != null and is_instance_valid(origin)
	if not want:
		if prompt != null:
			prompt.hide_prompt()
		return
	if prompt == null:
		prompt = CalibrationPrompt.new()
		prompt.name = "CalibrationPrompt"
		origin.add_child(prompt)
	var ws := origin.world_scale
	var head := origin.global_transform.affine_inverse() * camera.global_transform
	var st := CalibrationPrompt.Step.POSE
	var p := float(calibrator.capture_status()["progress"])
	match flow:
		Flow.DONE:
			st = CalibrationPrompt.Step.DONE
			p = 1.0
		Flow.FAILED:
			st = CalibrationPrompt.Step.FAILED
			p = 0.0
	prompt.show_step(st, p, prompt_text(), hint_text(), Transform3D(head.basis.orthonormalized(), head.origin), ws, dt)
