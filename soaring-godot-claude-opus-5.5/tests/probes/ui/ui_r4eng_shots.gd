extends Node3D
## Round-4 engineering verifier: visual evidence that a prey cue chevron is
## drawn under a lesson card that stepped up in a climb. Independent; no UI
## source touched. Outputs artifacts/ui/verify/r4eng/*.png.
##
##   tools/gd.sh ui_verify2 --rendering-method forward_plus --resolution 1280x720 \
##       --always-on-top res://tests/probes/ui/ui_r4eng_shots.tscn
##
##  r4eng_cue_level.png    level flight, prey 34 deg up ahead-left: the teal
##                         cue sits above the lesson card (control)
##  r4eng_cue_climb12.png  the same prey while climbing 12 deg: the card steps
##                         up 7 deg and its plate covers the cue

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var out := ""


func _ready() -> void:
	out = Paths.artifacts("ui").path_join("verify/r4eng")
	DirAccess.make_dir_recursive_absolute(out)
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	rig.position = Vector3(0, 18, 0)
	add_child(rig)
	cam = XRCamera3D.new()
	cam.fov = 90.0
	cam.near = 0.03
	cam.far = 3000.0
	cam.position = Vector3(0, 1.6, 0)
	rig.add_child(cam)
	cam.current = true
	player = UIMockPlayer.new()
	player.head_offset = Vector3(0, 1.6, 0)
	add_child(player)
	player.global_position = rig.global_position
	gl = UIMockGameLoop.new()
	add_child(gl)
	var path := "user://ui_r4eng_shots_progress.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	ui = (load("res://scenes/ui/ui_root.tscn") as PackedScene).instantiate() as UIRoot
	ui.mode = UIRoot.Mode.VR
	ui.progress_path = path
	add_child(ui)
	ui.quit_handler = func() -> void: pass
	var l := UIPointerSource.new(&"left_hand")
	var r := UIPointerSource.new(&"right_hand")
	var down := Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	l.aim = Transform3D(down, Vector3(-0.25, 1.0, -0.2))
	r.aim = Transform3D(down, Vector3(0.25, 1.0, -0.2))
	ui.set_pointer_sources(l, r)
	ui.attach_rig(rig, cam)
	Game.set_state(Game.State.MENU)
	await _frames(5)
	gl.start_run()
	await _frames(5)
	var cruise := SizeRules.cruise_speed(0.03)
	var eye := cam.global_position
	var prey := UIStandInBird.new(&"moth", 0.004)
	add_child(prey)
	prey.global_position = eye + Basis(Vector3.UP, deg_to_rad(12.0)) * Basis(Vector3.RIGHT, deg_to_rad(34.0)) * Vector3.FORWARD * 12.0
	Events.target_changed.emit(prey)
	_climb(0.0, cruise)
	await _wait(1.0)
	print("[ui-verify] level: lesson '%s' offset %s cue visible %s" % [ui.hud.lesson_title(), str(ui.hud_panel.band_offset(HUD.BAND_NOTICE)), ui.indicators.cue_mesh(&"target").visible])
	await _shot("r4eng_cue_level")
	_climb(12.0, cruise)
	await _wait(1.0)
	print("[ui-verify] climb 12: offset %s alpha %.2f cue visible %s" % [str(ui.hud_panel.band_offset(HUD.BAND_NOTICE)), ui.hud_panel.band_alpha(HUD.BAND_NOTICE), ui.indicators.cue_mesh(&"target").visible])
	await _shot("r4eng_cue_climb12")
	Game.set_state(Game.State.MENU)
	await _frames(3)
	get_tree().quit()


func _climb(deg: float, speed: float) -> void:
	var a := deg_to_rad(deg)
	player.velocity = Vector3(0.0, sin(a), -cos(a)) * speed


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(s: float) -> void:
	await get_tree().create_timer(s, true).timeout


func _shot(name: String) -> void:
	await _frames(2)
	await Capture.save_viewport(get_viewport(), out.path_join(name + ".png"))
