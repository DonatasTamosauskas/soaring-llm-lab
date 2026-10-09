extends Node3D
## VR area evidence for the calibration redesign's UI hook (the one change
## in scripts/ui/): the pause screen's "New player? Recalibrate wings"
## button, shown while VR.recalibration_suggested is up, and the
## calibration card in front of the VR pause panel once it is clicked.
##
##   tools/gd.sh vr --rendering-method forward_plus --resolution 1280x960 res://tests/shots/vr_pause_suggestion.tscn
##
## Writes artifacts/vr/pause_plain.png, pause_new_player.png (the menu
## panel's own texture, 1360 x 900) and pause_card_vr.png (the head view:
## the VR pause panel with the calibration card over it), and
## pause_suggestion.json. It checks from the layout that the button fits
## the panel and overlaps nothing, that the run-so-far line is still shown,
## and that a click starts the calibration step; exits 1 on a failure.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")

var ui: UIRoot
var gl: UIMockGameLoop
var rig: Dictionary
var failures: PackedStringArray = []
var report := {}
var out := ""


func _ready() -> void:
	out = Paths.artifacts("vr")
	add_child(UIBackdrop.new())
	Env.build_environment(self)
	# The stand-in player rig with the VR extras (the calibration card).
	rig = Env.build_rig(self, Vector3.ZERO, MemoryStore.new(), false, false)
	var extras: VRRigExtras = rig["extras"]
	extras.calibration.first_launch_prompt = false
	extras.world_scale_driver.enabled = false
	(rig["origin"] as XROrigin3D).world_scale = 1.0
	var cam: XRCamera3D = rig["camera"]
	cam.fov = 75.0
	cam.current = true
	gl = UIMockGameLoop.new()
	add_child(gl)
	ui = (load("res://scenes/ui/ui_root.tscn") as PackedScene).instantiate() as UIRoot
	ui.mode = UIRoot.Mode.VR
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://vr_pause_progress.cfg"))
	ui.progress_path = "user://vr_pause_progress.cfg"
	add_child(ui)
	ui.quit_handler = func() -> void: pass
	# Parked hands (no pointer hovering the panel).
	var down := Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	ui.set_pointer_sources(UIPointerSource.new(&"left_hand"), UIPointerSource.new(&"right_hand"))
	(ui.pointer.sources[0] as UIPointerSource).aim = Transform3D(down, Vector3(-0.25, 1.0, -0.2))
	(ui.pointer.sources[1] as UIPointerSource).aim = Transform3D(down, Vector3(0.25, 1.0, -0.2))
	ui.attach_rig(rig["origin"], cam)
	Game.set_state(Game.State.MENU)
	await _run()
	report["failures"] = Array(failures)
	var f := FileAccess.open(out.path_join("pause_suggestion.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	for msg in failures:
		print("[vr] FAIL ", msg)
	print("[vr] pause suggestion shots done (%d failures)" % failures.size())
	get_tree().quit(1 if not failures.is_empty() else 0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _check(ok: bool, what: String) -> void:
	print("[vr] %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _panel_texture(name: String) -> void:
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := ui.menu_panel.get_viewport_node().get_texture().get_image()
	img.save_png(out.path_join(name + ".png"))


func _shot(name: String) -> void:
	await get_tree().create_timer(0.4).timeout
	await _frames(3)
	await Capture.save_viewport(get_viewport(), out.path_join(name + ".png"))


## Every visible control of the pause screen's top row and columns, in the
## panel's pixels.
func _layout(screen: UIScreen) -> Dictionary:
	var rects := {}
	for c in screen.find_children("*", "Control", true, false):
		var ctl := c as Control
		if not ctl.is_visible_in_tree() or ctl.size.x < 1.0 or ctl is Container:
			continue
		if ctl is Button or ctl is Label:
			rects[str(screen.get_path_to(ctl))] = ctl.get_global_rect()
	return rects


func _run() -> void:
	await _frames(5)
	gl.start_run()
	var p := Birds.player()
	if p != null:
		p.mass = SizeRules.SPECIES[4]["mass"] * 1.3
	gl.stats["catches"] = 7
	Game.set_state(Game.State.PAUSED)
	await _frames(3)
	var pause := ui.get_screen(&"pause") as PauseScreen
	var btn := pause.get_button(&"recalibrate")
	_check(ui.current_screen_id() == &"pause", "the pause screen is up")
	_check(btn != null and not btn.visible, "no suggestion: the button is hidden")
	await _panel_texture("pause_plain")
	# VR suggests it (the headset came off and on).
	VR.active = true
	VR.focused = true
	VR.suggest_recalibration(true)
	await _frames(3)
	_check(btn.visible, "suggested: 'New player? Recalibrate wings' shown at once (the screen refreshed on the signal)")
	_check(btn.text == "New player? Recalibrate wings", "its text: '%s'" % btn.text)
	await _panel_texture("pause_new_player")
	# Layout: inside the panel's content, overlapping nothing, text not
	# clipped, the run-so-far text still on screen (in the tip's place).
	var panel := Rect2(Vector2.ZERO, Vector2(UITheme.MENU_SIZE))
	var br := btn.get_global_rect()
	var rects := _layout(pause)
	_check(panel.grow(-30.0).encloses(br), "the button lies inside the panel (%s)" % str(br))
	# The content keeps the screen's 60 px side margins (nothing got wider).
	var content := Rect2(60.0, 0.0, UITheme.MENU_SIZE.x - 120.0, UITheme.MENU_SIZE.y)
	for k in _layout(pause):
		var r: Rect2 = _layout(pause)[k]
		if r.end.x > content.end.x + 0.5 or r.position.x < content.position.x - 0.5:
			_check(false, "%s keeps the 60 px side margins (%s)" % [k, str(r)])
	var font := btn.get_theme_font(&"font")
	var fs := btn.get_theme_font_size(&"font_size")
	var tw := font.get_string_size(btn.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_check(br.size.x >= tw + 40.0, "the whole text fits the button (%.0f px text, %.0f px button)" % [tw, br.size.x])
	var overlaps: Array[String] = []
	for k in rects:
		var r: Rect2 = rects[k]
		if r.is_equal_approx(br) or (k as String).contains("Btn_recalibrate"):
			continue
		if r.intersects(br.grow(-2.0)):
			overlaps.append(k)
	_check(overlaps.is_empty(), "the button overlaps nothing (%s)" % str(overlaps))
	var tip := pause.find_child("Tip", true, false) as Label
	_check(tip != null and tip.text.contains("caught"), "the run so far moved to the tip's line ('%s')" % (tip.text if tip else ""))
	for k in rects:
		var r: Rect2 = rects[k]
		if not panel.grow(-20.0).encloses(r):
			_check(false, "%s stays inside the panel (%s)" % [k, str(r)])
	report["button_rect"] = str(br)
	report["text_width_px"] = tw
	# A click starts the calibration step (UIRoot.recalibrate_requested ->
	# VRCalibration), the card in front of the VR pause panel.
	var cal: VRCalibration = (rig["extras"] as VRRigExtras).calibration
	var got := [0]
	ui.recalibrate_requested.connect(func() -> void: got[0] += 1)
	btn.pressed.emit()
	await _frames(2)
	_check(got[0] == 1, "the click emits UIRoot.recalibrate_requested")
	_check(cal.flow == VRCalibration.Flow.CAPTURE, "and the calibration step shows its card (flow %s)" % VRCalibration.Flow.keys()[cal.flow])
	_check(Game.state == Game.State.PAUSED, "still paused (the step runs in the pause menu)")
	await _shot("pause_card_vr")
	cal.cancel()
	VR.suggest_recalibration(false)
	VR.active = false
	VR.focused = false
	await _frames(3)
	_check(not btn.visible, "suggestion cleared: hidden again, the run line back in the top row")
	_check(tip.text != "" and not tip.text.contains("caught"), "and the tip back in its place")
