extends Node3D
## Verifier (round 1) visual evidence for the ui area. Renders the cases the
## builder's shot script does not reach into artifacts/ui/verify/:
##   panel_summary_apex.png / vr_summary_apex.png  apex run with a new best
##   panel_caught_eagle.png                       caught by an eagle
##   panel_pause_hawk.png                         pause as a hawk
##   vr_tail_threat_{0..5}.png                    hawk on your tail, wobbling
##
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/probes/ui/ui_verify_shots.tscn -- --fresh-settings

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var out := ""
var report := {}


func _ready() -> void:
	out = Paths.artifacts("ui").path_join("verify")
	DirAccess.make_dir_recursive_absolute(out)
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
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
	gl = UIMockGameLoop.new()
	add_child(gl)
	var path := "user://ui_verify_shots_progress.cfg"
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
	ui.onboarding.skip()
	Game.set_state(Game.State.MENU)
	await _frames(5)
	await _run()
	var f := FileAccess.open(out.path_join("verify_shots.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[ui-verify] shots done -> ", out)
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await get_tree().create_timer(0.35).timeout
	await _frames(3)
	await Capture.save_viewport(get_viewport(), out.path_join(name + ".png"))


func _panel(name: String) -> void:
	await _frames(4)
	await RenderingServer.frame_post_draw
	ui.menu_panel.get_viewport_node().get_texture().get_image().save_png(out.path_join(name + ".png"))


func _run() -> void:
	# 1. Apex run with a new best.
	gl.start_run()
	await _frames(3)
	gl.fake_end({"score": 98765, "time": 1834.0, "max_mass": 3.2, "max_tier": 9,
		"catches_by_species": {&"hawk": 2, &"gull": 5, &"crow": 9, &"pigeon": 14, &"starling": 22, &"swallow": 3}})
	await _frames(3)
	ui.menu_panel.snap_to_head()
	await _panel("panel_summary_apex")
	await _shot("vr_summary_apex")
	var ss := ui.get_screen(&"summary")
	var head := ss.find_child("Headline", true, false) as Label
	var badge := ss.find_child("NewBest", true, false) as Label
	report["summary_apex"] = {"headline": head.text, "headline_rect": str(head.get_global_rect()),
		"badge_visible": badge.is_visible_in_tree(), "badge_rect": str(badge.get_global_rect()),
		"panel_px": str(UITheme.MENU_SIZE)}
	# 2. Caught by an eagle.
	Game.set_state(Game.State.MENU)
	gl.start_run()
	await _frames(3)
	var eagle := Bird.new()
	eagle.species = &"eagle"
	eagle.mass = 3.0
	add_child(eagle)
	eagle.global_position = Vector3(0, -100, 0)
	gl.stats["lives"] = 2
	gl.fake_caught(eagle)
	await _frames(3)
	ui.menu_panel.snap_to_head()
	await _panel("panel_caught_eagle")
	# 3. Pause as a hawk.
	Game.set_state(Game.State.PLAYING)
	player.mass = SizeRules.SPECIES[8]["mass"] * 1.05
	await _frames(2)
	Game.set_state(Game.State.PAUSED)
	await _frames(3)
	ui.menu_panel.snap_to_head()
	await _panel("panel_pause_hawk")
	# 4. A hawk on your tail, wobbling +-0.4 m at 10 m behind.
	Game.set_state(Game.State.PLAYING)
	player.mass = 0.05
	await _frames(3)
	var hawk := Bird.new()
	hawk.species = &"hawk"
	hawk.mass = 1.4
	add_child(hawk)
	var eye := cam.global_transform
	Events.threat_changed.emit(0.9, hawk)
	var t0 := Time.get_ticks_msec()
	var shot_i := 0
	var sides := []
	while shot_i < 6:
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		hawk.global_position = eye.origin + eye.basis * Vector3(0.4 * sin(TAU * 1.2 * t), 0.0, 10.0)
		await get_tree().process_frame
		if t >= 0.6 + shot_i * 0.21:
			var cue := ui.indicators.cue_mesh(&"threat")
			var local := eye.affine_inverse() * cue.global_position
			sides.append([snappedf(t, 0.01), cue.visible, snappedf(local.x, 0.001), snappedf(local.y, 0.001)])
			await Capture.save_viewport(get_viewport(), out.path_join("vr_tail_threat_%d.png" % shot_i))
			shot_i += 1
	report["tail_threat_cue_local_xy"] = sides
	Events.threat_changed.emit(0.0, null)
