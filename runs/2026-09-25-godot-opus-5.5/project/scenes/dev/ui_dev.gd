extends Node3D
## UI area dev scene: the whole UI on its own, with a stand-in world, rig,
## player, game loop and two NPC birds (a prey and a hawk) so every screen,
## the HUD cues and the lessons can be exercised on desktop or in the Meta
## XR Simulator.
##
## Desktop keys: 1 main menu, 2 play, 3 pause, 4 caught, 5 run end,
## 6 tier up, 7 settings, 8 how to fly, 9 shrink, 0 become the eagle,
## A apex catch (the fifth wins), Esc = menu button.
## User args (after --):
##   --demo            run a scripted tour through every state (with a tier-up
##                     during a 14 deg climb, where the notices stay beside
##                     the flight path, drawn as a white ring, and a chase
##                     with prey left and a hawk behind-left, where the two
##                     cues stay apart)
##   --ui_autoclick=s  pull the (real or mock) right trigger at these seconds
##   --shots=s,...     capture a head-mirror view to artifacts/ui/sim_<s>.png
##   --quit_after=s    quit (desktop; XR runs use the VR autoload's --autoquit)
##   --prefix=name     screenshot file prefix (default "sim")
##   --panel_pitch=deg  menu panel elevation (the simulator's controllers are
##                      fixed, so this picks which button their ray lands on)
##   --fidelity=s      at s seconds, read back the Play/Quit button fills from
##                     the head mirror and compare with the expected colours
##   --occluders=s     at s seconds, put a "hand" block (UIPanel.mark_occluder)
##                     and a plain "branch" block between the eye and the menu
##                     and check from the head mirror that the hand stays in
##                     front of the panel and the branch does not

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var prey: Bird
var hawk: Bird
var _t := 0.0
var _diag_t := 0.0
var _clicks: Array[float] = []
var _shots: Array[float] = []
var _tour: Array = []
var _quit_after := -1.0
var _fidelity_at := -1.0
var _occluders_at := -1.0
var _prefix := "sim"
var _mirror_vp: SubViewport
var _mirror_cam: Camera3D
## Demo: prey 90 deg left and a hawk closing from behind-left.
var _chase := false
## Demo: the flight path marker while climbing.
var _fp_marker: MeshInstance3D


func _ready() -> void:
	# The dev driver (tour, shots, diagnostics) must keep running while the
	# game is paused; gameplay stand-ins below check get_tree().paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := Paths.user_args()
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.name = "Rig"
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(rig)
	cam = XRCamera3D.new()
	cam.name = "XRCamera3D"
	cam.near = 0.03
	cam.far = 3000.0
	cam.position = Vector3(0, 1.6, 0)
	rig.add_child(cam)
	cam.current = true
	player = UIMockPlayer.new()
	player.name = "MockPlayer"
	player.head_offset = Vector3(0, 1.6, 0)
	add_child(player)
	gl = UIMockGameLoop.new()
	gl.name = "MockGameLoop"
	add_child(gl)
	prey = _npc(&"moth", 0.004)
	hawk = _npc(&"hawk", 1.6)
	ui = (load("res://scenes/ui/ui_root.tscn") as PackedScene).instantiate() as UIRoot
	ui.progress_path = "user://ui_dev_progress.cfg"
	add_child(ui)
	if args.has("panel_pitch"):
		ui.menu_panel.pitch_deg = float(args["panel_pitch"])
	# Fresh tutorial every dev run.
	ui.onboarding.reset()
	Game.set_state(Game.State.MENU)
	for s in str(args.get("ui_autoclick", "")).split(",", false):
		_clicks.append(float(s))
	for s in str(args.get("shots", "")).split(",", false):
		_shots.append(float(s))
	_quit_after = float(args.get("quit_after", "-1"))
	_fidelity_at = float(args.get("fidelity", "-1"))
	if _fidelity_at > 0.0 and _shots.is_empty():
		_shots.append(_fidelity_at)
	_occluders_at = float(args.get("occluders", "-1"))
	if _occluders_at > 0.0 and _shots.is_empty():
		_shots.append(_occluders_at + 0.5)
	_prefix = str(args.get("prefix", "sim"))
	if args.has("demo"):
		_tour = [[2.0, "play"], [6.0, "climb"], [7.0, "tier"], [9.5, "level"], [10.0, "pause"], [13.0, "settings"], [16.0, "howto"],
			[19.0, "resume"], [19.2, "chase"], [20.8, "unchase"], [21.0, "caught"], [25.0, "respawn"], [27.0, "eagle"], [30.5, "apex"],
			[31.0, "apex"], [34.5, "apex"], [34.7, "apex"], [34.9, "apex"], [40.0, "menu"]]
	_build_mirror()
	print("[ui] dev scene ready; vr=%s demo=%s" % [ui.vr_mode, args.has("demo")])


## NPC stand-ins (UIStandInBird: a `model` with `highlight`, like NpcBird),
## so the dev scene runs whatever state the birds area is in.
func _npc(sp: StringName, m: float) -> Bird:
	var b := UIStandInBird.new(sp, m)
	add_child(b)
	return b


func _build_mirror() -> void:
	if _shots.is_empty():
		return
	_mirror_vp = SubViewport.new()
	_mirror_vp.size = Vector2i(1280, 960)
	_mirror_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mirror_vp.world_3d = get_viewport().world_3d
	add_child(_mirror_vp)
	_mirror_cam = Camera3D.new()
	# About a Quest Pro eye's vertical field: the HUD's notices (+7..+20 deg)
	# and growth strip (-37..-43 deg) are both in view.
	_mirror_cam.fov = 96.0
	_mirror_cam.near = 0.03
	_mirror_cam.far = 3000.0
	_mirror_vp.add_child(_mirror_cam)
	_mirror_cam.current = true


func _process(delta: float) -> void:
	_t += delta
	if not get_tree().paused:
		_animate_npcs()
		_animate_player()
	if not _tour.is_empty() and _t >= _tour[0][0]:
		_do(str(_tour.pop_front()[1]))
	if not _clicks.is_empty() and _t >= _clicks[0]:
		_clicks.pop_front()
		_pulse_trigger()
	if _mirror_cam:
		_mirror_cam.global_transform = cam.global_transform
	if not _shots.is_empty() and _t >= _shots[0]:
		var at := _shots.pop_front() as float
		Capture.save_viewport(_mirror_vp, Paths.artifacts("ui").path_join("%s_%02ds.png" % [_prefix, int(at)]))
	_diag_t += delta
	if _diag_t >= 1.0:
		_diag_t = 0.0
		_diag()
	if _fidelity_at > 0.0 and _t >= _fidelity_at + 0.2:
		_fidelity_at = -1.0
		_check_fidelity()
	if _occluders_at > 0.0 and _t >= _occluders_at:
		_occluders_at = -1.0
		_check_occluders()
	if _quit_after > 0.0 and _t >= _quit_after:
		_quit_after = -1.0
		get_tree().quit()


## Rendered colour of flat button fills vs what the active renderer can show
## (UITonemap models the tonemapper and the Mobile colour ceiling).
func _check_fidelity() -> void:
	if _mirror_vp == null or ui.current_screen_id() != &"main":
		print("[ui] fidelity: skipped (needs the main menu and --shots)")
		return
	await RenderingServer.frame_post_draw
	var img := _mirror_vp.get_texture().get_image()
	var p := UITonemap.params(UITonemap.active_environment(get_viewport()))
	var main := ui.get_screen(&"main")
	for id: StringName in [&"play", &"quit"]:
		var b := main.get_button(id)
		var r := b.get_global_rect()
		var sp := _mirror_cam.unproject_position(ui.menu_panel.pixel_to_world(Vector2(r.position.x + 16.0, r.get_center().y)))
		var got := img.get_pixelv(Vector2i(sp))
		var design := UITheme.ACCENT if id == &"play" else UITheme.BUTTON
		var want := UITonemap.apply(UITonemap.compensate(design, p), p)
		var err := maxf(maxf(absf(got.r - want.r), absf(got.g - want.g)), absf(got.b - want.b)) * 255.0
		print("[ui] fidelity %s: design %s expected-on-this-renderer %s got %s (max err %.1f/255) renderer=%s" % [
			id, design.to_html(false), want.to_html(false), got.to_html(false), err, RenderingServer.get_current_rendering_method()])


## The player's hand must stay in front of a menu panel (it is nearer), the
## scenery must not cut into it: checked from the head mirror's pixels.
func _check_occluders() -> void:
	if _mirror_vp == null:
		print("[ui] occluders: skipped (needs --shots)")
		return
	var head := cam.global_transform
	var blocks := []
	var cols := [Color("d9a27a"), Color("7a5236")]
	for i in 2:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.09
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = cols[i]
		if i == 0:
			UIPanel.mark_occluder(mat)
		mi.material_override = mat
		add_child(mi)
		mi.global_position = head * (Vector3(-0.2, -0.05, -0.55) if i == 0 else Vector3(0.22, 0.05, -0.9))
		blocks.append(mi)
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := _mirror_vp.get_texture().get_image()
	var p := UITonemap.params(UITonemap.active_environment(get_viewport()))
	for i in 2:
		var got := img.get_pixelv(Vector2i(_mirror_cam.unproject_position(blocks[i].global_position)))
		var want := UITonemap.apply(cols[i], p)
		var err := maxf(maxf(absf(got.r - want.r), absf(got.g - want.g)), absf(got.b - want.b)) * 255.0
		print("[ui] occluders %s: pixel %s, block colour %s, err %.1f -> %s (renderer=%s)" % [["hand", "branch"][i], got.to_html(false),
			want.to_html(false), err, ("in front" if err < 6.0 else "behind the panel"), RenderingServer.get_current_rendering_method()])
	await get_tree().create_timer(1.0, true).timeout
	for b: Node in blocks:
		b.queue_free()


func _pulse_trigger() -> void:
	var src := ui.pointer.active_source()
	if src == null:
		print("[ui] autoclick: no pointer source")
		return
	print("[ui] autoclick on %s hovering %s" % [src.hand, ui.pointer.hovered().name if ui.pointer.hovered() else "nothing"])
	src.trigger_override = 1.0
	await get_tree().create_timer(0.15, true).timeout
	src.trigger_override = 0.0
	await get_tree().create_timer(0.15, true).timeout
	src.trigger_override = -1.0


func _diag() -> void:
	var line := "[ui] t=%.0f state=%s screen=%s" % [_t, Game.state_name(), ui.current_screen_id()]
	var src := ui.pointer.active_source()
	if ui.pointer.enabled and src:
		var a := src.aim_transform()
		line += " hand=%s tracked=%s aim=%s dir=%s" % [src.hand, src.is_tracked(), a.origin.snapped(Vector3.ONE * 0.01), (-a.basis.z).snapped(Vector3.ONE * 0.01)]
		var hit := ui.pointer.last_hit
		line += " hit=%s hover=%s" % [str(hit.get("pixel", "-")), ui.pointer.hovered().name if ui.pointer.hovered() else "-"]
	line += " vp_active=%d menu_renders=%d hud_renders=%d" % [ui.active_viewport_count(), ui.menu_panel.render_requests, ui.hud_panel.render_requests]
	print(line)


func _animate_npcs() -> void:
	var head := cam.global_position
	if _chase:
		prey.global_position = head + Vector3(-8.0, 0.0, 0.0)
		hawk.global_position = head + Vector3(-2.0, 0.5, 9.0)
		if Game.state == Game.State.PLAYING:
			if ui.indicators.target != prey:
				Events.target_changed.emit(prey)
			Events.threat_changed.emit(0.85, hawk)
		return
	# The moth flutters in a loop off to the left-front; the hawk circles
	# wide behind, closing in and backing off (threat level rises and falls).
	prey.global_position = head + Vector3(-6.0 + sin(_t * 0.7) * 3.0, sin(_t * 1.3) * 0.8, -5.0 + cos(_t * 0.5) * 2.0)
	var a := _t * 0.25
	var r := 14.0 + sin(_t * 0.4) * 6.0
	hawk.global_position = head + Vector3(sin(a) * r, 3.0, cos(a) * r)
	if Game.state == Game.State.PLAYING:
		if ui.indicators.target != prey:
			Events.target_changed.emit(prey)
		Events.threat_changed.emit(clampf(1.0 - (r - 8.0) / 12.0, 0.0, 1.0), hawk)


func _animate_player() -> void:
	# Demo telemetry: the "player" goes through the lesson gestures in turn.
	if Game.state != Game.State.PLAYING:
		return
	var t := fposmod(_t, 12.0)
	player.tel["wing_extension"] = 0.9 if t < 9.0 else 0.2
	player.tel["flapping"] = 0.8 if t > 2.0 and t < 3.5 else 0.0
	player.tel["bank"] = deg_to_rad(30.0) if t > 6.0 and t < 8.0 else 0.0
	player.tel["airspeed"] = 8.0 + t * 0.4
	if t > 2.0 and t < 3.5 and int(_t * 3.0) != int((_t - get_process_delta_time()) * 3.0):
		Events.player_flapped.emit(0, 0.8)


func _do(what: String) -> void:
	print("[ui] demo: ", what)
	match what:
		"menu":
			Game.set_state(Game.State.MENU)
			player.mass = SizeRules.SPECIES[2]["mass"]
		"play":
			gl.start_run()
		"tier":
			player.mass = SizeRules.SPECIES[3]["mass"] * 1.2
			Events.player_tier_changed.emit(2, 3)
		"climb":
			# A 14 deg flapping climb: the flight path (the white ring) rises
			# up the centre line; the notices live beside it and stay put.
			player.velocity = Vector3(0.0, sin(deg_to_rad(14.0)), -cos(deg_to_rad(14.0))) * 9.0
			_fp_marker = _ring(player.velocity)
		"level":
			player.velocity = Vector3(0.0, 0.0, -9.0)
			if _fp_marker:
				_fp_marker.queue_free()
				_fp_marker = null
		"chase":
			_chase = true
		"unchase":
			_chase = false
		"shrink":
			player.mass = SizeRules.SPECIES[2]["mass"]
			Events.player_tier_changed.emit(3, 2)
		"pause":
			Events.menu_requested.emit()
		"settings":
			ui.push_screen(&"settings")
		"howto":
			ui.push_screen(&"howto")
		"resume":
			ui.resume()
		"caught":
			if Game.state == Game.State.PAUSED:
				ui.resume()
			gl.fake_caught(hawk)
		"respawn":
			Game.set_state(Game.State.PLAYING)
		"eagle":
			player.mass = 3.1
			Events.player_tier_changed.emit(8, 9)
		"apex":
			if Game.state == Game.State.PLAYING:
				gl.fake_catch(&"crow")
				gl.fake_apex_catch()
		"end":
			gl.fake_catch(&"moth")
			gl.fake_catch(&"moth")
			gl.fake_catch(&"wren")
			gl.fake_end({"score": 2600, "max_mass": player.mass})


## A white ring 1.8 deg across, 5 m out along `dir` from the eye (evidence
## only: shows the flight path the notices keep clear of).
func _ring(dir: Vector3) -> MeshInstance3D:
	var d := dir.normalized()
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.07
	tm.outer_radius = 0.085
	mi.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 20
	mi.material_override = mat
	add_child(mi)
	var y := -d
	var x := y.cross(Vector3.UP).normalized()
	mi.global_transform = Transform3D(Basis(x, y, x.cross(y)), cam.global_position + d * 5.0)
	return mi


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var map := {KEY_1: "menu", KEY_2: "play", KEY_3: "pause", KEY_4: "caught", KEY_5: "end",
		KEY_6: "tier", KEY_7: "settings", KEY_8: "howto", KEY_9: "shrink", KEY_0: "eagle", KEY_A: "apex"}
	if map.has(event.keycode):
		_do(map[event.keycode])
