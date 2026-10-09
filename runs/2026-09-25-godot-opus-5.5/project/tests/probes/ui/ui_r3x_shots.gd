extends Node3D
## Verifier (round 3, experience lens) visual evidence. Outputs
## artifacts/ui/verify/r3x_*.png. Independent verifier; no UI source touched.
##
##   tools/gd.sh ui_verify3 --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/probes/ui/ui_r3x_shots.tscn
##
##  r3x_tierup_level.png      tier-up toast in level flight (control)
##  r3x_tierup_climb12.png    the same toast 1 s in, climbing at 12 deg
##  r3x_lesson_climb12.png    "Flap to climb" lesson card while climbing 12 deg
##  r3x_cues_overlap.png      prey 90 deg left + hawk behind-left: both cues
##  r3x_settings_status.png   Settings after "Replay tutorial" (panel texture)

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var out := ""
var _birds: Array[Node] = []


func _ready() -> void:
	out = Paths.artifacts("ui").path_join("verify")
	DirAccess.make_dir_recursive_absolute(out)
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	rig.position = Vector3(0, 18, 0)
	add_child(rig)
	cam = XRCamera3D.new()
	cam.fov = 75.0
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
	var path := "user://ui_r3x_shots_progress.cfg"
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

	# Lesson 2 while climbing 12 deg (lesson 1 marked done first).
	ui.onboarding.skip()
	ui.onboarding.reset()
	ui.progress.mark_lesson(&"spread")
	ui.onboarding.start()
	_climb(12.0, cruise)
	await _wait(0.8)
	print("[ui-verify] lesson '%s' notice alpha %.2f" % [ui.hud.lesson_title(), ui.hud_panel.band_alpha(HUD.BAND_NOTICE)])
	await _shot("r3x_lesson_climb12")
	ui.onboarding.skip()
	await _wait(0.6)

	# Tier-up: level flight (control), then climbing 12 deg.
	_climb(0.0, cruise)
	await _wait(0.6)
	player.mass = float(SizeRules.SPECIES[3]["mass"]) * 1.02
	Events.player_tier_changed.emit(2, 3)
	await _wait(1.0)
	print("[ui-verify] level tier-up notice alpha %.2f" % ui.hud_panel.band_alpha(HUD.BAND_NOTICE))
	await _shot("r3x_tierup_level")
	await _wait(3.0)
	_climb(12.0, cruise)
	await _wait(0.6)
	player.mass = float(SizeRules.SPECIES[4]["mass"]) * 1.02
	Events.player_tier_changed.emit(3, 4)
	await _wait(1.0)
	print("[ui-verify] climbing tier-up notice alpha %.2f" % ui.hud_panel.band_alpha(HUD.BAND_NOTICE))
	await _shot("r3x_tierup_climb12")
	await _wait(3.0)

	# Cues: prey 90 deg left, a hawk closing from behind-left.
	_climb(0.0, cruise)
	var eye := cam.global_position
	var prey := _bird(&"wren", 0.012, eye + Vector3(-8, 0, 0))
	var hawk := _bird(&"hawk", 1.3, eye + Vector3(-2, 0.5, 9))
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.9, hawk)
	await _wait(1.0)
	var t := ui.indicators.cue_mesh(&"target")
	var h := ui.indicators.cue_mesh(&"threat")
	print("[ui-verify] cues drawn target=%s threat=%s sep=%.2f deg" % [t.visible, h.visible, rad_to_deg((t.global_position - eye).angle_to(h.global_position - eye))])
	await _shot("r3x_cues_overlap")
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)

	# Settings status after "Replay tutorial".
	ui._last_menu_ms = -100000
	Events.menu_requested.emit()
	await _frames(4)
	ui._on_action(&"settings", &"pause")
	await _frames(4)
	ui._on_action(&"replay_tutorial", &"settings")
	await _frames(6)
	await RenderingServer.frame_post_draw
	var img := ui.menu_panel.get_viewport_node().get_texture().get_image()
	img.save_png(out.path_join("r3x_settings_status.png"))
	await _shot("r3x_settings_status_vr")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[ui-verify] r3x shots done -> ", out)
	get_tree().quit()


func _bird(sp: StringName, m: float, pos: Vector3) -> UIStandInBird:
	var b := UIStandInBird.new(sp, m)
	add_child(b)
	b.global_position = pos
	_birds.append(b)
	return b


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
