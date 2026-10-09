extends Node3D
## Round-5 experience verifier: what the player sees of the HUD notices when
## the head was not on the flight path at the moment the HUD appeared.
## Independent; no UI source touched. Outputs artifacts/ui/verify/r5x/*.png.
##
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 1280x1072 \
##       res://tests/probes/ui/ui_r5x_shots.tscn
##
## The camera is a Quest Pro eye box: 96 deg tall, 106 deg wide (the whole
## binocular view; a single eye sees less on its nasal side). A small white
## ball 25 m out marks the flight path. In every shot the player looks
## straight along it.
##
##  r5x_control.png         head on the flight path when Play was pulled:
##                          the lesson card at home, 11-39 deg right
##  r5x_after_play.png      head turned to the Play button (13 deg right) when
##                          pulled, then looking ahead: card text 24-52 deg
##  r5x_after_resume.png    head turned to Resume (14 deg left) when pulled,
##                          then 8 s of the tutorial's flap-and-glide: the card
##                          faded, jumped to the far left (text 37-65 deg)
##  r5x_tierup_gaze0.png    tier-up, looking along the flight path (control)
##  r5x_tierup_gaze-25.png  tier-up while looking 25 deg left (at prey): the
##                          celebration is off-screen for its whole life

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var out := ""
var _profile: Array = []
var _fly_t := -1.0


func _ready() -> void:
	out = Paths.artifacts("ui").path_join("verify/r5x")
	DirAccess.make_dir_recursive_absolute(out)
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	rig.position = Vector3(0, 18, 0)
	add_child(rig)
	cam = XRCamera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = 96.0
	cam.near = 0.03
	cam.far = 3000.0
	rig.add_child(cam)
	_head(0.0)
	cam.current = true
	player = UIMockPlayer.new()
	player.head_offset = Vector3(0, 1.6, 0)
	add_child(player)
	player.global_position = rig.global_position
	player.velocity = Vector3(0, 0, -8)
	# Flight-path marker.
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	ball.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	ball.material_override = mat
	add_child(ball)
	_ball = ball
	gl = UIMockGameLoop.new()
	add_child(gl)
	_profile = _tutorial_series(2, 2.0, 12.0)
	var path := "user://ui_r5x_shots_progress.cfg"
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

	# 1. Control: Play pulled with the head on the flight path.
	await _enter(0.0, false)
	await _shot("r5x_control")
	# 2. Play pulled with the head on the Play button.
	await _enter(1.0, false)
	await _shot("r5x_after_play")
	# 3. Paused mid-tutorial, Resume pulled with the head on it, then the
	#    tutorial's flap-and-glide.
	await _enter(1.0, true)
	_fly_t = 0.0
	await _wait(8.0)
	_fly_t = -1.0
	player.velocity = Vector3(0, 0, -8)
	await _wait(0.6)
	print("[ui-verify] after resume: moves %d side %d alpha %.2f offset %s" % [ui.hud.move_count, ui.hud.notice_side, ui.hud.notice_alpha(), str(ui.hud_panel.band_offset(HUD.BAND_NOTICE))])
	await _shot("r5x_after_resume")
	# 4/5. Tier-ups: HUD placed on the flight path, head at 0 / 25 deg left.
	for g: float in [0.0, -25.0]:
		Game.set_state(Game.State.MENU)
		await _frames(4)
		ui.onboarding.skip()
		_head(0.0)
		gl.start_run()
		await _wait(0.5)
		_head(g)
		await _wait(0.3)
		player.mass = float(SizeRules.SPECIES[3]["mass"]) * 1.02
		Events.player_tier_changed.emit(2, 3)
		await _wait(0.9)
		print("[ui-verify] tier-up gaze %.0f: toast %s alpha %.2f" % [g, ui.hud.toast_active(), ui.hud.notice_alpha()])
		await _shot("r5x_tierup_gaze%d" % int(g))
	Game.set_state(Game.State.MENU)
	await _frames(3)
	get_tree().quit()


var _ball: MeshInstance3D


func _process(_delta: float) -> void:
	if _ball and cam:
		_ball.global_position = cam.global_position + player.velocity.normalized() * 25.0
	if _fly_t >= 0.0 and not _profile.is_empty():
		_fly_t += _delta
		var row: Array = _profile[mini(int(_fly_t * 72.0), _profile.size() - 1)]
		var a := deg_to_rad(float(row[1]))
		player.velocity = Vector3(0.0, sin(a), -cos(a)) * float(row[2])


## Head yaw in degrees, + = right (looking level).
func _head(yaw_right: float) -> void:
	cam.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-yaw_right)), Vector3(0, 1.6, 0))


## Enter PLAYING (lessons on) with the head turned `frac` of the way to the
## Play button (main menu) or the Resume button (pause), then look ahead.
func _enter(frac: float, via_resume: bool) -> void:
	Game.set_state(Game.State.MENU)
	_head(0.0)
	ui.onboarding.reset()
	await _frames(6)
	var btn: Button
	if via_resume:
		gl.start_run()
		await _wait(0.3)
		Game.set_state(Game.State.PAUSED)
		await _frames(6)
		btn = ui.get_screen(&"pause").get_button(&"resume")
	else:
		btn = ui.get_screen(&"main").get_button(&"play")
	var p := ui.menu_panel.control_to_world(btn) - cam.global_position
	var az := rad_to_deg(atan2(p.x, -p.z))
	_head(az * frac)
	await _frames(3)
	if via_resume:
		ui.resume()
	else:
		gl.start_run()
	await _frames(4)
	_head(0.0)
	await _wait(1.0)
	print("[ui-verify] entered (%s, head %.1f deg): lesson '%s' yaw err %.1f" % ["resume" if via_resume else "play", az * frac, ui.hud.lesson_title(), rad_to_deg(ui.hud_panel.yaw_error())])


static func _tutorial_series(strokes: int, glide_s: float, seconds: float) -> Array:
	var m := FlightModel.new(FlightParams.species_mass(&"sparrow"), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var out_a: Array = []
	var cycle := float(strokes) + glide_s
	var dt := 1.0 / 72.0
	for i in int(seconds / dt):
		var t := i * dt
		var ph := fmod(t, cycle)
		if ph < float(strokes):
			ws.set_commands(0.0, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, dt)
		var v := m.velocity
		out_a.append([t, rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())), v.length()])
	return out_a


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(s: float) -> void:
	await get_tree().create_timer(s, true).timeout


func _shot(name: String) -> void:
	await _frames(2)
	await Capture.save_viewport(get_viewport(), out.path_join(name + ".png"))
