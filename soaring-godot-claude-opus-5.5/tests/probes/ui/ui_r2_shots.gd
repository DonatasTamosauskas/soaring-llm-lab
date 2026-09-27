extends Node3D
## Verifier (round 2) visual evidence: what the HUD does to the player's view
## when they look down at prey (the core loop: spot smaller birds below and
## dive on them). A stand-in prey (teal wedge, 0.35 m) sits 14 m out along
## the gaze. Outputs artifacts/ui/verify/r2_*.png.
##
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/probes/ui/ui_r2_shots.tscn

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var prey: MeshInstance3D
var out := ""


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
	cam.fov = 60.0
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
	prey = MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(0.35, 0.18, 0.35)
	prey.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = UITheme.PREY
	prey.material_override = mat
	add_child(prey)
	var path := "user://ui_r2_shots_progress.cfg"
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
	# First flight: lesson card up; look 13 deg down at prey.
	await _look(-13.0, "r2_gaze_lesson_pitch-13")
	# Control: same prey, head level (you see it below the lesson card?).
	await _look(0.0, "r2_gaze_lesson_pitch0", -13.0)
	print("[ui-verify] before skip: onboarding active=%s index=%d card=%s" % [str(ui.onboarding.active), ui.onboarding.index, str(ui.hud.lesson_visible())])
	# Skip from a frame_post_draw continuation (as the line above resumes
	# from Capture.save_viewport): the HUD texture keeps the hidden card.
	ui.onboarding.skip()
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := ui.hud_panel.get_viewport_node().get_texture().get_image()
	print("[ui-verify] skip after a post-draw: onboarding active=%s card=%s texture card alpha=%.2f" % [str(ui.onboarding.active), str(ui.hud.lesson_visible()), img.get_pixel(UITheme.HUD_SIZE.x / 2 + 200, 150).a])
	await _look(-26.0, "r2_ghost_lesson_after_postdraw_skip")
	# Now any process-phase change (a growth step) forces a fresh render.
	await get_tree().process_frame
	player.mass *= 1.02
	await _frames(4)
	await RenderingServer.frame_post_draw
	img = ui.hud_panel.get_viewport_node().get_texture().get_image()
	print("[ui-verify] after a later growth step: texture card alpha=%.2f" % img.get_pixel(UITheme.HUD_SIZE.x / 2 + 200, 150).a)
	# Permanent HUD: look 26 deg down at prey (a dive).
	await _look(-26.0, "r2_gaze_strip_pitch-26")
	await _look(-40.0, "r2_gaze_strip_pitch-40")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[ui-verify] r2 shots done -> ", out)
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Head pitched `pitch` deg; prey 14 m out along `prey_pitch` (default: the gaze).
func _look(pitch: float, name: String, prey_pitch: float = NAN) -> void:
	var pp := pitch if is_nan(prey_pitch) else prey_pitch
	cam.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(pitch)), Vector3(0, 1.6, 0))
	var dir := Basis(Vector3.RIGHT, deg_to_rad(pp)) * Vector3.FORWARD
	prey.global_position = cam.global_position + dir * 14.0
	await get_tree().create_timer(0.4).timeout
	await _frames(3)
	await Capture.save_viewport(get_viewport(), out.path_join(name + ".png"))
