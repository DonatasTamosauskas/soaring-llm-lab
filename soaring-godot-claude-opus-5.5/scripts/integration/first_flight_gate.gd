class_name FirstFlightGate
extends GameBridge
## Play is the gate to the first flight (integration round 1).
##
## On a first launch in the headset (no saved wing calibration) the VR
## area's calibration step used to start by itself while the game was still
## loading, sat straight ahead over the main menu (hiding How to fly,
## Settings and Quit), and pressing Play cancelled it silently: a new
## player's first flight flew uncalibrated. The game now asks at Play:
##
##   Play -> the menu closes, the card asks for the spread
##        -> captured ("Wings calibrated") or skipped with B/Y ("Calibration
##           skipped / Using default wings") -> that card's moment -> the run
##           starts (GameBridge.start_run, as without the gate)
##        -> a pose the calibrator refused ("Calibration not changed /
##           the controllers were held in an unusual way"): after that card,
##           the step asks again
##        -> abandoned (the headset came off, the menu button): back to the
##           main menu; the next Play asks again.
##
## The body stays still on the spawn perch throughout (the game is in MENU),
## so the spread cannot fly the bird. UIRoot's own bridge is replaced by this
## one (main.gd); every other call is GameBridge's. On the desktop, or once
## calibrated or skipped, Play starts the run at once.
##
## A step the player asks for (Settings > Recalibrate wings, "New player?
## Recalibrate wings", the Y-hold) runs over the pause menu: the menu hides
## while the card is up and comes back as it was once the result card has
## gone (integration round 2, the Quest verifier: the card, 1.25 m away, sat
## straight over the pause panel at 1.5 m - it covered Settings, cut off
## "How to fly" and "Skip tutorial", and the laser still hit buttons behind
## it). If the game resumed meanwhile, the screen for the new state shows.

signal gate_started()
## started: the run began (captured or skipped); false: back to the menu.
signal gate_finished(started: bool, reason: String)

## Longest the result card may hold the run back (it shows for 1.5-2 s).
const RESULT_WAIT_S := 3.0

var calibration: VRCalibration
var ui: UIRoot
## True while Play waits for the calibration step.
var gating := false
## How the last gate ended: "captured", "skipped", "abandoned: <why>".
var last_outcome := ""
## True while a step the player asked for hides the menus (see above), and
## the screens it hid.
var hiding_for_step := false
var _hidden_stack: Array[StringName] = []


func _init(p_tree: SceneTree, p_ui: UIRoot, p_calibration: VRCalibration) -> void:
	super(p_tree)
	ui = p_ui
	calibration = p_calibration
	if calibration != null:
		calibration.flow_changed.connect(_on_flow_changed)


## A manual step's card is up: the menus make way until it has gone.
func _on_flow_changed(step: StringName, _prompt: String, _progress: float) -> void:
	if gating or hiding_for_step or step != &"capture" or ui == null or not is_instance_valid(ui):
		return
	hiding_for_step = true
	_hidden_stack = ui.stack.duplicate()
	ui._set_root(&"")
	_restore_after_step()


func _restore_after_step() -> void:
	while is_instance_valid(calibration) and calibration.flow != VRCalibration.Flow.IDLE:
		await tree.process_frame
	hiding_for_step = false
	if not is_instance_valid(ui) or not ui.stack.is_empty():
		return  # something else opened a screen meanwhile
	if Game.state == Game.State.PAUSED and not _hidden_stack.is_empty():
		ui.stack.assign(_hidden_stack)
		ui._show_top()
		ui.refresh_current()
	else:
		ui.show_state_screen()


func start_run() -> void:
	if gating:
		return
	if Game.state == Game.State.MENU and calibration != null and is_instance_valid(calibration) \
			and calibration.first_launch_due():
		_gate()
		return
	super.start_run()


func _gate() -> void:
	gating = true
	print("[integration] Play: the first flight waits for the wing calibration")
	# The menu goes first: the card never sits over a panel.
	ui._set_root(&"")
	Events.menu_requested.connect(_on_menu_requested)
	calibration.flow_finished.connect(_on_flow_finished, CONNECT_ONE_SHOT)
	calibration.start_first_launch()
	gate_started.emit()


## The menu button while the card waits: the player wants the menu back.
func _on_menu_requested() -> void:
	if gating and calibration != null and is_instance_valid(calibration) and calibration.is_running():
		calibration.abandon("the menu button")


func _on_flow_finished(ok: bool, reason: String) -> void:
	if Events.menu_requested.is_connected(_on_menu_requested):
		Events.menu_requested.disconnect(_on_menu_requested)
	var skipped := not ok and not calibration.first_launch_pending
	if not ok and not skipped and calibration.flow == VRCalibration.Flow.FAILED:
		# The pose was refused (its card says why): ask again after it.
		print("[integration] first-flight gate: pose refused (%s), asking again" % reason)
		await _result_card()
		if Game.state == Game.State.MENU and is_instance_valid(calibration) and calibration.first_launch_due():
			Events.menu_requested.connect(_on_menu_requested)
			calibration.flow_finished.connect(_on_flow_finished, CONNECT_ONE_SHOT)
			calibration.start_first_launch()
		else:
			gating = false
			gate_finished.emit(false, "state changed")
		return
	if not ok and not skipped:
		# Abandoned (headset off, the menu button): nothing decided. Back to
		# the menu; the next Play asks again.
		last_outcome = "abandoned: %s" % reason
		print("[integration] first-flight gate: %s, back to the menu" % last_outcome)
		gating = false
		if Game.state == Game.State.MENU:
			ui.show_state_screen()
		gate_finished.emit(false, last_outcome)
		return
	last_outcome = "captured" if ok else "skipped"
	# Let the result card have its moment ("Wings calibrated", "Calibration
	# skipped") before the HUD and the first lesson come up.
	await _result_card()
	gating = false
	if Game.state != Game.State.MENU:
		# Something else moved the game on meanwhile (tests, a quit).
		gate_finished.emit(false, "state changed")
		return
	print("[integration] first-flight gate: %s, the run starts" % last_outcome)
	super.start_run()
	gate_finished.emit(true, last_outcome)


func _result_card() -> void:
	var t0 := Time.get_ticks_msec()
	while is_instance_valid(calibration) and calibration.flow != VRCalibration.Flow.IDLE \
			and Time.get_ticks_msec() - t0 < int(RESULT_WAIT_S * 1000.0):
		await tree.process_frame
