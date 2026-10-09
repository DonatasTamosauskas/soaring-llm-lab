extends Node3D
## U1 visual evidence: every screen as the desktop overlay and as 3D panels
## seen from a VR-style head camera, plus the raw panel textures, the HUD
## (lesson, growth strip, peripheral cues), tier-up, pointer hover, every
## how-to card, every species icon, worst-case content (apex summary, eagle
## texts) and a world_scale comparison. Writes artifacts/ui/*.png and
## artifacts/ui/shots.json (image stats + measured rendered contrast).
##
## It also measures, from rendered pixels, that idle panels really stop
## rendering (U7), that a UI change made after a frame's draw still reaches
## the texture, that the VR colour compensation reaches the screen, and that
## the player's hands stay in front of panels; the run exits 1 (and prints
## "[ui] FAIL") if any of them regresses.
##
## HUD views: the HUD's bands sit at +8..+20 deg (the notices 8-43 deg to
## the right of the centre line) and -37..-43 deg, so vr_hud.png and the
## notice shots use a headset-sized 96 deg vertical view; the gaze shots
## (vr_hud_dive / glance) use the 60 deg camera pitched like a head. The
## HUD's centre line is where the body faces (round 6): after a Resume with
## the head on the button the card is beside it (vr_hud_after_resume); a
## flight path crabbing 30 deg off in the breeze leaves it in front of the
## player (vr_hud_crab); a torso turn takes it along (vr_hud_body_turn). In
## a climb, or with prey above, the notices stay put (vr_hud_climb,
## vr_tierup_climb); prey staying on the card sends it once to the other
## side (vr_notices_moved); a celebration appears where the player looks
## (vr_tierup_gaze_left). The run fails if they fade, move without need,
## cover the flight path or the target, or a celebration is out of view.
## vr_cues_chase shows the prey and threat cues apart, and a pixel check
## proves a cue draws over a notice plate (vr_cue_over_card).
##
##   tools/gd.sh ui --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/ui_shots.tscn -- --fresh-settings

var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var player: UIMockPlayer
var gl: UIMockGameLoop
var left: UIPointerSource
var right: UIPointerSource
var prey: Bird
var hawk: Bird
var out := ""
var report := {}
var failures: PackedStringArray = []


func _ready() -> void:
	out = Paths.artifacts("ui")
	add_child(UIBackdrop.new())
	rig = XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(rig)
	cam = XRCamera3D.new()
	# ~92 x 60 degrees: roughly one Quest Pro eye's view.
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
	prey = _bird(&"moth", 0.004)
	hawk = _bird(&"hawk", 1.6)
	ui = (load("res://scenes/ui/ui_root.tscn") as PackedScene).instantiate() as UIRoot
	ui.mode = UIRoot.Mode.DESKTOP
	# A fresh record file every run, so "Best" is this run's, not a leftover.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ui_shots_progress.cfg"))
	ui.progress_path = "user://ui_shots_progress.cfg"
	add_child(ui)
	ui.onboarding.reset()
	ui.quit_handler = func() -> void: pass
	left = UIPointerSource.new(&"left_hand")
	right = UIPointerSource.new(&"right_hand")
	ui.set_pointer_sources(left, right)
	_park_hands()
	Game.set_state(Game.State.MENU)
	await _run()
	report["failures"] = Array(failures)
	var f := FileAccess.open(out.path_join("shots.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	for msg in failures:
		print("[ui] FAIL ", msg)
	print("[ui] shots done -> %s (%d failures)" % [out, failures.size()])
	get_tree().quit(1 if not failures.is_empty() else 0)


## A stand-in bird (UIStandInBird): the shots never depend on another
## area's in-progress bird models.
func _bird(sp: StringName, m: float) -> Bird:
	var b := UIStandInBird.new(sp, m)
	add_child(b)
	b.global_position = Vector3(0, -100, 0)
	return b


func _park_hands() -> void:
	var down := Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	left.aim = Transform3D(down, Vector3(-0.25, 1.0, -0.2))
	right.aim = Transform3D(down, Vector3(0.25, 1.0, -0.2))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	# Panels fade in over 0.18 s: let them settle before capturing.
	await get_tree().create_timer(0.35).timeout
	await _frames(3)
	var path := out.path_join(name + ".png")
	await Capture.save_viewport(get_viewport(), path)
	var img := Image.load_from_file(path)
	var st := Capture.image_stats(img)
	report[name] = {"mean": (st["mean"] as Color).to_html(false), "dark_fraction": snappedf(st["dark_fraction"], 0.001)}


func _panel_texture(name: String, panel: UIPanel = null) -> void:
	if panel == null:
		panel = ui.menu_panel
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := panel.get_viewport_node().get_texture().get_image()
	img.save_png(out.path_join(name + ".png"))


## Head pitched `pitch` degrees (yaw 0), the camera `fov` degrees tall.
func _head(pitch: float, fov: float = 60.0) -> void:
	cam.fov = fov
	cam.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(pitch)), Vector3(0, 1.6, 0) * rig.world_scale)


## Screens reached through the real flow (mock game loop + events).
func _goto(id: StringName) -> void:
	match id:
		&"main":
			Game.set_state(Game.State.MENU)
			ui.show_state_screen()
		&"pause":
			if Game.state != Game.State.PLAYING:
				gl.start_run()
			player.mass = SizeRules.SPECIES[4]["mass"] * 1.3
			# A run as it would be: 7 catches in 5:12 (the round-6 verifier:
			# "0:00 · 7 caught" read like a bug).
			gl.stats["catches"] = 7
			Game.run_time = 312.0
			Game.set_state(Game.State.PAUSED)
		&"settings":
			await _goto(&"pause")
			ui.push_screen(&"settings")
		&"howto":
			Game.set_state(Game.State.MENU)
			ui.show_state_screen()
			ui.push_screen(&"howto")
		&"caught":
			if Game.state == Game.State.PAUSED:
				Game.set_state(Game.State.PLAYING)
			elif Game.state != Game.State.PLAYING:
				gl.start_run()
			gl.stats["lives"] = 2
			gl.fake_caught(hawk)
		&"summary":
			Game.set_state(Game.State.PLAYING)
			gl.fake_catch(&"moth")
			gl.fake_catch(&"moth")
			gl.fake_catch(&"wren")
			gl.fake_catch(&"sparrow")
			gl.fake_end({"score": 3450, "max_mass": SizeRules.SPECIES[5]["mass"] * 1.1, "time": 431.0})
	await _frames(3)


func _hud_scene() -> void:
	# Mid-tutorial flight: lesson 4 on the HUD, growth half way to Starling,
	# a moth off to the left (target cue) and a hawk behind-right (threat).
	Game.set_state(Game.State.MENU)
	ui.onboarding.reset()
	ui.progress.mark_lesson(&"spread")
	ui.progress.mark_lesson(&"flap")
	ui.progress.mark_lesson(&"glide")
	player.mass = sqrt(SizeRules.SPECIES[3]["mass"] * SizeRules.SPECIES[4]["mass"])
	gl.start_run()
	await _frames(2)
	ui.onboarding.progress = 0.0
	ui.hud.set_lesson_progress(0.45)
	var head := cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(-9, 1.0, -2)
	hawk.global_position = head.origin + head.basis * Vector3(8, 2, 9)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.75, hawk)
	await get_tree().create_timer(0.8).timeout


func _run() -> void:
	# ---------------- desktop overlay ----------------
	for id: StringName in [&"main", &"pause", &"settings", &"howto", &"caught", &"summary"]:
		await _goto(id)
		await _shot("desktop_%s" % id)
	await _hud_scene()
	await _shot("desktop_hud")
	player.mass = SizeRules.SPECIES[4]["mass"] * 1.05
	Events.player_tier_changed.emit(3, 4)
	await get_tree().create_timer(0.6).timeout
	await _shot("desktop_tierup")
	await get_tree().create_timer(3.0).timeout

	# ---------------- VR: 3D panels from the head camera ----------------
	print("[ui] shots: VR panels")
	ui.set_vr_mode(true)
	ui.attach_rig(rig, cam)
	ui.set_pointer_sources(left, right)
	print("[ui] shots: VR mode on")
	var hover := {&"main": &"play", &"pause": &"resume", &"settings": &"recenter", &"howto": &"tab_speed",
		&"caught": &"", &"summary": &"again"}
	for id: StringName in [&"main", &"pause", &"settings", &"howto", &"caught", &"summary"]:
		_park_hands()
		await _goto(id)
		ui.menu_panel.snap_to_head()
		print("[ui] shots: vr_%s" % id)
		var bid: StringName = hover[id]
		if bid != &"":
			var b := ui.get_screen(id).get_button(bid)
			var target := ui.menu_panel.control_to_world(b) + ui.menu_panel.global_basis.x.normalized() * 0.12
			right.aim_at(rig.global_transform * Vector3(0.22, 1.25, -0.25), target)
		await _shot("vr_%s" % id)
		await _panel_texture("panel_%s" % id)
		if id == &"settings":
			# What "Replay tutorial" says, in its slot (round 3: it pushed
			# the whole screen off the panel).
			var back_x := ui.get_screen(&"settings").get_button(&"back").get_global_rect().end.x
			ui._on_action(&"replay_tutorial", &"settings")
			await _shot("vr_settings_status")
			await _panel_texture("panel_settings_status")
			var moved := absf(ui.get_screen(&"settings").get_button(&"back").get_global_rect().end.x - back_x)
			report["settings_status_back_moved_px"] = moved
			if moved > 0.5:
				failures.append("the settings status message moved the Back button by %.0f px" % moved)
	_park_hands()
	await _vr_hud_views()
	await _vr_cue_views()
	await _vr_catch_lesson()
	await _measure_cue_over_plate()

	# Every how-to card, straight from the panel texture.
	Game.set_state(Game.State.MENU)
	ui.push_screen(&"howto")
	var h := ui.get_screen(&"howto") as HowToScreen
	var sheet := Image.create(2 * 920, 4 * 380, false, Image.FORMAT_RGBA8)
	# 8 cards: a 2 x 4 contact sheet.
	sheet.fill(Color(0.08, 0.1, 0.14))
	for i in HowToScreen.CARDS.size():
		h.show_card(i)
		await get_tree().create_timer(0.35).timeout
		await _panel_texture("howto_%s" % HowToScreen.CARDS[i]["id"])
		# Contact sheet of the card art (the card rect inside the panel).
		var img := Image.load_from_file(out.path_join("howto_%s.png" % HowToScreen.CARDS[i]["id"]))
		img.convert(Image.FORMAT_RGBA8)
		var card := h.find_child("Card", true, false) as Control
		var cr := Rect2i(card.get_global_rect())
		cr.size = Vector2i(mini(cr.size.x, 920), mini(cr.size.y, 380))
		sheet.blit_rect(img, cr, Vector2i((i % 2) * 920, (i / 2) * 380))
	sheet.save_png(out.path_join("howto_sheet.png"))

	# Same main menu at the smallest and largest player: must look identical.
	Game.set_state(Game.State.MENU)
	ui.show_state_screen()
	for ws: float in [0.15, 1.3]:
		rig.world_scale = ws
		cam.position = Vector3(0, 1.6, 0) * ws
		ui.menu_panel.snap_to_head()
		await _shot("vr_scale_%03d" % int(round(ws * 100.0)))
	rig.world_scale = 1.0
	cam.position = Vector3(0, 1.6, 0)
	await _measure_fidelity()
	await _worst_case_panels()
	await _species_sheet()
	await _measure_occluders()
	await _measure_render_budget()
	await _measure_late_change()


## The HUD in VR: where its two bands sit in a headset-sized view, and what
## a hunting bird sees looking down at prey, glancing at the strip, and
## climbing (the flight path behind the lesson card: it turns see-through).
func _vr_hud_views() -> void:
	# Flying 20 m up, so birds below the horizon are in the air, not in the ground.
	rig.position = Vector3(0, 20, 0)
	await _hud_scene()
	ui.hud_panel.snap_to_head()
	await _panel_texture("panel_hud", ui.hud_panel)
	_head(0.0, 96.0)
	await _shot("vr_hud")
	# The round-5 verifier's case: paused, the head turned 14 deg left onto
	# the Resume button, resume; then look ahead. The HUD's centre line is
	# where the body faces, not where the head was: the card sits beside
	# it, the strip under it (here the flight path is straight ahead too).
	player.velocity = Vector3(0, 0, -9.0)
	Game.set_state(Game.State.PAUSED)
	await _frames(3)
	cam.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(14.0)), Vector3(0, 1.6, 0))
	await _frames(2)
	ui.resume()
	await _frames(3)
	_head(0.0, 96.0)
	var fp0 := _marker(player.velocity, Color.WHITE)
	await get_tree().create_timer(0.6).timeout
	await _shot("vr_hud_after_resume")
	_check_clear("hud_after_resume", [player.velocity.normalized()], Vector2.ZERO)
	var strip := ui.hud_panel.control_to_world(ui.hud.band_plates(HUD.BAND_STATUS)[0]) - cam.global_position
	report["hud_after_resume_strip_az_deg"] = snappedf(rad_to_deg(atan2(strip.x, -strip.z)), 0.1)
	if absf(rad_to_deg(atan2(strip.x, -strip.z))) > 1.0:
		failures.append("after a Resume with the head turned the growth strip is %.1f deg off the flight path" % rad_to_deg(atan2(strip.x, -strip.z)))
	fp0.queue_free()
	# The round-6 verifier's case: a slow sparrow in the valley's breeze
	# crabs, its flight path 30 deg right of where it (and the player) faces,
	# a little below the horizon. The round-5 HUD turned onto the path and
	# took the card out of view; now it stays where the body faces, and the
	# card (words 9-32 deg right, above the horizon) stays readable and
	# clear of the path.
	player.velocity = Basis(Vector3.UP, deg_to_rad(-30.0)) * Vector3(0.0, -0.3, -4.0)
	var fpc := _marker(player.velocity, Color.WHITE)
	await get_tree().create_timer(0.8).timeout
	await _shot("vr_hud_crab")
	_check_clear("hud_crab", [player.velocity.normalized()], Vector2.ZERO)
	report["hud_crab_panel_yaw_deg"] = snappedf(rad_to_deg(ui.hud_panel.panel_yaw()), 0.01)
	if absf(rad_to_deg(ui.hud_panel.panel_yaw())) > 0.5:
		failures.append("crabbing 30 deg the HUD's centre line left where the body faces (%.1f deg)" % rad_to_deg(ui.hud_panel.panel_yaw()))
	fpc.queue_free()
	player.velocity = Vector3.ZERO
	# What the player sees turning their head to read the lesson: 20 deg to
	# the right and 12 deg up (the HUD does not follow the head at all, so
	# the card holds still while it is read).
	cam.fov = 60.0
	cam.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-20.0)) * Basis(Vector3.RIGHT, deg_to_rad(12.0)), Vector3(0, 1.6, 0))
	var yaw0 := ui.hud_panel.panel_yaw()
	await _shot("vr_notice_read")
	report["notice_read_hud_followed_deg"] = snappedf(rad_to_deg(absf(ui.hud_panel.panel_yaw() - yaw0)), 0.01)
	if absf(ui.hud_panel.panel_yaw() - yaw0) > deg_to_rad(0.1):
		failures.append("turning the head to read the notices moved the HUD")
	# Looking 26 deg down at prey 5 m out on the gaze line (the target).
	_head(-26.0)
	var head := cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(0, 0, -5)
	Events.target_changed.emit(prey)
	await get_tree().create_timer(0.3).timeout
	await _shot("vr_hud_dive")
	report["hud_dive_band_alpha"] = [ui.hud_panel.band_alpha(0), ui.hud_panel.band_alpha(1)]
	# Prey right behind the strip: the strip makes way.
	_head(-40.0)
	head = cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(0.6, 0, -5)
	await get_tree().create_timer(0.4).timeout
	await _shot("vr_hud_prey_behind_strip")
	report["hud_prey_behind_strip_alpha"] = ui.hud_panel.band_alpha(HUD.BAND_STATUS)
	if ui.hud_panel.band_alpha(HUD.BAND_STATUS) > 0.2:
		failures.append("the growth strip hid the target behind it (band alpha %.2f)" % ui.hud_panel.band_alpha(HUD.BAND_STATUS))
	# A deliberate glance down reads the strip (nothing to protect behind it).
	Events.target_changed.emit(null)
	prey.global_position = Vector3(0, -100, 0)
	_head(-38.0)
	await get_tree().create_timer(0.6).timeout
	await _shot("vr_hud_glance")
	# Climbing at 16 deg (the white ring is the flight path): the lesson card
	# is beside it, not in its way; nothing moves, nothing fades. (No hawk
	# now: its cue, up-right on the ring, would rightly send the card left;
	# vr_cue_over_card shows that case.)
	Events.threat_changed.emit(0.0, null)
	hawk.global_position = Vector3(0, -100, 0)
	ui.hud.hide_lesson()
	await _frames(2)
	ui.hud.show_lesson(3, Onboarding.LESSONS.size(), Onboarding.LESSONS[3])
	_head(8.0, 96.0)
	player.velocity = Vector3(0, 2.6, -9.0)
	var fp := _marker(player.velocity, Color.WHITE)
	await get_tree().create_timer(0.4).timeout
	await _shot("vr_hud_climb")
	_check_clear("hud_climb", [player.velocity.normalized()], Vector2.ZERO)
	fp.queue_free()
	# A torso turn: the player turns 30 deg to the right (body steer), the
	# bird follows, the head with it. The HUD's centre line is where the
	# body faces, so the card comes along (about 1 s) and stays beside it,
	# clear of the new path (no fade, no move).
	var turned := Basis(Vector3.UP, deg_to_rad(-30.0))
	player.velocity = turned * Vector3(0, 2.6, -9.0)
	player.global_basis = turned
	player.tel["body_yaw"] = deg_to_rad(-30.0)
	cam.transform = Transform3D(turned * Basis(Vector3.RIGHT, deg_to_rad(8.0)), Vector3(0, 1.6, 0))
	fp = _marker(player.velocity, Color.WHITE)
	await get_tree().create_timer(1.2).timeout
	await _shot("vr_hud_body_turn")
	_check_clear("hud_body_turn", [player.velocity.normalized()], Vector2.ZERO)
	report["hud_body_turn_panel_yaw_deg"] = snappedf(rad_to_deg(ui.hud_panel.panel_yaw()), 0.1)
	if absf(rad_to_deg(ui.hud_panel.panel_yaw()) + 30.0) > 1.0:
		failures.append("after a 30 deg torso turn the HUD's centre line is at %.1f deg, not where the body faces" % rad_to_deg(ui.hud_panel.panel_yaw()))
	fp.queue_free()
	player.tel["body_yaw"] = 0.0
	player.global_basis = Basis.IDENTITY
	player.velocity = Vector3(0, 0, -9.0)
	_head(8.0, 96.0)
	await get_tree().create_timer(1.2).timeout
	# Prey that stays right where the card is (15 deg up, 27 deg right): the
	# card turns see-through at once and, as the prey stays, moves once to
	# the other side of the centre line, where it is read again.
	var eye0 := cam.global_position
	var sitter := _bird(&"wren", 0.012)
	sitter.global_position = eye0 + Basis(Vector3.UP, deg_to_rad(-27.0)) * Basis(Vector3.RIGHT, deg_to_rad(15.0)) * Vector3(0, 0, -14.0)
	Events.target_changed.emit(sitter)
	fp = _marker(sitter.global_position - eye0, UITheme.PREY)
	await get_tree().create_timer(HUD.MOVE_AFTER_S + HUD.MOVE_S + HUD.SEE_THROUGH_IN_S + 0.4).timeout
	await _shot("vr_notices_moved")
	_check_clear("notices_moved", [(sitter.global_position - eye0).normalized(), player.velocity.normalized()], HUD.NOTICE_MIRROR)
	fp.queue_free()
	Events.target_changed.emit(null)
	sitter.queue_free()
	# A new card appears at home again once it is clear there.
	ui.hud.hide_lesson()
	player.velocity = Vector3.ZERO
	await _frames(2)
	ui.hud.show_lesson(3, Onboarding.LESSONS.size(), Onboarding.LESSONS[3])
	player.velocity = Vector3.ZERO
	await get_tree().create_timer(1.0).timeout
	# Tier-up: the celebration in the notice band, above the horizon.
	player.mass = SizeRules.SPECIES[4]["mass"] * 1.05
	Events.player_tier_changed.emit(3, 4)
	_head(6.0, 96.0)
	await get_tree().create_timer(0.6).timeout
	await _shot("vr_tierup")
	await _panel_texture("panel_hud_tierup", ui.hud_panel)
	await get_tree().create_timer(3.0).timeout
	# A tier-up while the player looks 30 deg to the left (at the next bird):
	# the celebration appears there, beside the centre line, all in view.
	cam.fov = 96.0
	cam.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)) * Basis(Vector3.RIGHT, deg_to_rad(6.0)), Vector3(0, 1.6, 0))
	await _frames(2)
	player.mass = SizeRules.SPECIES[5]["mass"] * 1.05
	Events.player_tier_changed.emit(4, 5)
	await get_tree().create_timer(0.6).timeout
	await _shot("vr_tierup_gaze_left")
	var va := ui.hud.toast_view_angle()
	report["tierup_gaze_left"] = {"text_from_gaze_deg": snappedf(va, 0.1), "offset_deg": str(ui.hud_panel.band_offset(HUD.BAND_NOTICE)), "alpha": snappedf(ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 0.01)}
	if not ui.hud.toast_active() or va > 45.0 or ui.hud_panel.band_alpha(HUD.BAND_NOTICE) < 0.95:
		failures.append("a tier-up while looking 30 deg left is not in view (text %.1f deg from the gaze)" % va)
	# Let it finish where it is being read.
	var waited := 0.0
	while ui.hud.toast_active() and waited < 8.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	player.mass = SizeRules.SPECIES[4]["mass"] * 1.05
	# The same moment climbing at 12 deg after the next prey, 12 deg up
	# ahead: the celebration is beside both, fully readable.
	_head(8.0, 96.0)
	var eye := cam.global_position
	var next := _bird(&"starling", 0.1)
	next.global_position = eye + Vector3(-0.5, 1.4, -6.5)
	Events.target_changed.emit(next)
	player.velocity = Vector3(0.0, sin(deg_to_rad(12.0)), -cos(deg_to_rad(12.0))) * 9.0
	await get_tree().create_timer(0.5).timeout
	player.mass = SizeRules.SPECIES[5]["mass"] * 1.05
	Events.player_tier_changed.emit(4, 5)
	var marks := [_marker(player.velocity, Color.WHITE), _marker(next.global_position - eye, UITheme.PREY)]
	await get_tree().create_timer(0.6).timeout
	await _shot("vr_tierup_climb")
	_check_clear("tierup_climb", [player.velocity.normalized(), (next.global_position - eye).normalized()], Vector2.ZERO)
	for m: Node in marks:
		m.queue_free()
	await get_tree().create_timer(3.0).timeout
	Events.target_changed.emit(null)
	next.queue_free()
	player.velocity = Vector3.ZERO
	await get_tree().create_timer(1.0).timeout
	# The eagle's toast states the apex goal; the strip counts it.
	player.mass = 3.1
	gl.stats["apex"]["catches"] = 0
	Events.player_tier_changed.emit(8, 9)
	await get_tree().create_timer(0.6).timeout
	await _panel_texture("panel_hud_eagle", ui.hud_panel)
	await get_tree().create_timer(3.0).timeout
	gl.fake_apex_catch()
	gl.fake_apex_catch()
	await get_tree().create_timer(0.6).timeout
	_head(0.0, 96.0)
	await _shot("vr_hud_apex")
	await _panel_texture("panel_hud_apex", ui.hud_panel)
	await get_tree().create_timer(3.0).timeout
	gl.stats["apex"]["catches"] = 0
	player.mass = SizeRules.SPECIES[2]["mass"]
	_head(0.0)
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	rig.position = Vector3.ZERO
	await _frames(2)


## Evidence only: a ring 1.8 deg across round a direction from the eye (the
## flight path in white, the target in teal), so a shot shows what the
## notices stepped aside from.
func _marker(dir: Vector3, col: Color) -> MeshInstance3D:
	var eye := cam.global_position
	var d := dir.normalized()
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.07
	tm.outer_radius = 0.085
	mi.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	mat.render_priority = 20
	mi.material_override = mat
	add_child(mi)
	# The torus lies in its XZ plane: turn its axis (Y) towards the eye.
	var y := -d
	var x := y.cross(Vector3.UP).normalized()
	mi.global_transform = Transform3D(Basis(x, y, x.cross(y)), eye + d * 5.0)
	return mi


## Rays within `radius_deg` of a world direction that land on a notice
## plate as drawn (0 = that much sky round it is clear).
func _notice_hits(dir: Vector3, radius_deg: float) -> int:
	var eye := cam.global_position
	var d := dir.normalized()
	var side := d.cross(Vector3.UP).normalized()
	var up := side.cross(d).normalized()
	var n := 0
	for i in 25:
		var r := d
		if i > 0:
			var a := TAU * i / 24.0
			r = (d + (side * cos(a) + up * sin(a)) * tan(deg_to_rad(radius_deg))).normalized()
		var hit := ui.hud_panel.intersect_ray(eye, r)
		if hit.is_empty():
			continue
		for p: Control in ui.hud.band_plates(HUD.BAND_NOTICE):
			if p.get_global_rect().has_point(hit["pixel"]):
				n += 1
				break
	return n


## The notices are where they should be (`at`: a band offset), fully
## opaque, with at least 2 deg of sky round each of `dirs`.
func _check_clear(tag: String, dirs: Array, at: Vector2) -> void:
	var a := ui.hud_panel.band_alpha(HUD.BAND_NOTICE)
	var off := ui.hud_panel.band_offset(HUD.BAND_NOTICE)
	var hits := 0
	for d: Vector3 in dirs:
		hits += _notice_hits(d, 2.0)
	report["%s_notices" % tag] = {"alpha": snappedf(a, 0.01), "offset_deg": str(off), "rays_on_a_plate": hits}
	if a < 0.95:
		failures.append("%s: the notices are faded (alpha %.2f)" % [tag, a])
	if off.distance_to(at) > 0.01:
		failures.append("%s: the notices are at %s, expected %s" % [tag, off, at])
	if hits > 0:
		failures.append("%s: a notice plate is within 2 deg of the flight path or target (%d rays)" % [tag, hits])


## Prey and threat cues in the commonest chase: prey 90 deg left, a hawk
## closing from behind-left. Both chevrons point left, the threat's on an
## outer ring, clearly apart.
## The catch lesson with the game's lesson prey (GameLoop's lesson-prey API,
## here UIMockGameLoop's: three stand-in moths ahead): the card names them
## and says what to do, a moth off to the left has its cue; then, after
## CATCH_HELP_S without a catch, the card says more (and the game was asked
## again: the swarm comes nearer).
func _vr_catch_lesson() -> void:
	# Flying 20 m up (as the other HUD views), clear of the backdrop's perch.
	rig.position = Vector3(0, 20, 0)
	Game.set_state(Game.State.MENU)
	ui.onboarding.reset()
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] != &"catch":
			ui.progress.mark_lesson(l["id"])
	gl.lesson_species = &"moth"
	gl.lesson_prey_calls.clear()
	player.mass = SizeRules.SPECIES[2]["mass"]
	gl.start_run()
	await _frames(2)
	_head(0.0, 96.0)
	ui.hud_panel.snap_to_head()
	var head := cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(-7, 0.5, -3)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.0, null)
	await get_tree().create_timer(0.8).timeout
	var said := [ui.hud.lesson_title(), ui.hud.lesson_labels()[2].text]
	report["catch_lesson"] = {"card": said, "calls": str(gl.lesson_prey_calls)}
	if said != ["Catch a Moth", "Fly right into one"] or not ui.hud.lesson_visible():
		failures.append("catch lesson card: %s (want Catch a Moth / Fly right into one)" % str(said))
	await _panel_texture("panel_hud_catch", ui.hud_panel)
	await _shot("vr_hud_catch")
	# CATCH_HELP_S of play without a catch.
	ui.onboarding.step(Onboarding.CATCH_HELP_S, player.telemetry())
	await get_tree().create_timer(0.3).timeout
	said = [ui.hud.lesson_title(), ui.hud.lesson_labels()[2].text]
	report["catch_lesson_help"] = {"card": said, "calls": str(gl.lesson_prey_calls)}
	if said != ["Catch a Moth", "Follow the arrow"] or not gl.lesson_prey_calls.has(["request", 2]):
		failures.append("catch lesson help: %s, calls %s" % [str(said), str(gl.lesson_prey_calls)])
	await _panel_texture("panel_hud_catch_help", ui.hud_panel)
	Events.target_changed.emit(null)
	gl.release_lesson_prey()
	gl.lesson_species = &""
	ui.onboarding.skip()
	await _frames(2)


func _vr_cue_views() -> void:
	rig.position = Vector3(0, 20, 0)
	ui.onboarding.skip()
	gl.start_run()
	await _frames(3)
	_head(0.0)
	ui.hud_panel.snap_to_head()
	var head := cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(-8, 0, 0)
	hawk.global_position = head.origin + head.basis * Vector3(-2, 0.5, 9)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.85, hawk)
	await get_tree().create_timer(0.8).timeout
	await _shot("vr_cues_chase")
	var t := ui.indicators.cue_mesh(&"target")
	var h := ui.indicators.cue_mesh(&"threat")
	var sep := rad_to_deg((t.global_position - head.origin).angle_to(h.global_position - head.origin)) if t.visible and h.visible else -1.0
	report["cues_chase_separation_deg"] = snappedf(sep, 0.1)
	if sep < 5.0:
		failures.append("prey and threat cues drawn on top of each other (%.1f deg apart)" % sep)
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	prey.global_position = Vector3(0, -100, 0)
	hawk.global_position = Vector3(0, -100, 0)
	rig.position = Vector3.ZERO
	Game.set_state(Game.State.MENU)
	await _frames(3)


## Round 4: the cue chevrons drew under the HUD panel (render priority 8 <
## 9), so a cue on a notice plate vanished. With the notices' own making
## way switched off (UIRoot not processing) so the card stays opaque, a
## hawk's cue is put on the lesson card; the pixel at the chevron must be
## the cue's coral, not the plate's ink.
func _measure_cue_over_plate() -> void:
	rig.position = Vector3(0, 20, 0)
	Game.set_state(Game.State.MENU)
	ui.onboarding.reset()
	gl.start_run()
	await _frames(3)
	# Level (the cue ring is round the view centre), narrow enough that the
	# 2.9 deg chevron covers ~58 px.
	_head(0.0, 36.0)
	ui.hud_panel.snap_to_head()
	check_lesson_up()
	ui.set_process(false)
	var head := cam.global_transform
	hawk.global_position = head.origin + Vector3(2.0, 10.0, 6.0)
	Events.threat_changed.emit(0.9, hawk)
	await get_tree().create_timer(0.8).timeout
	var cue := ui.indicators.cue_mesh(&"threat")
	# A point inside the coloured chevron (the tip's right half), where it
	# lies on the card.
	var at := cue.global_transform * Vector3(0.1, 0.25, 0.002)
	var on_plate := _notice_hits(at - head.origin, 0.0) > 0
	await _shot("vr_cue_over_card")
	var px := Vector2i(cam.unproject_position(at))
	var img := Image.load_from_file(out.path_join("vr_cue_over_card.png"))
	var with_cue := _median(img, px)
	cue.visible = false
	ui.indicators.set_process(false)
	await _frames(3)
	await RenderingServer.frame_post_draw
	var bare := get_viewport().get_texture().get_image()
	var plate := _median(bare, px)
	ui.indicators.set_process(true)
	var coral := UITheme.THREAT
	var d_cue := _max_err(with_cue, coral)
	var d_plate := _max_err(with_cue, plate)
	report["cue_over_card"] = {"on_plate": on_plate, "pixel": [px.x, px.y], "with_cue": with_cue.to_html(false),
		"plate_only": plate.to_html(false), "err_to_coral_255": snappedf(d_cue, 0.1), "diff_from_plate_255": snappedf(d_plate, 0.1)}
	if not on_plate:
		failures.append("cue-over-card check: the cue was not on the card (set-up)")
	elif d_plate < 60.0 or d_cue > 60.0:
		failures.append("a cue on a notice plate is hidden under it (pixel %s, plate %s)" % [with_cue.to_html(false), plate.to_html(false)])
	ui.set_process(true)
	Events.threat_changed.emit(0.0, null)
	hawk.global_position = Vector3(0, -100, 0)
	ui.onboarding.skip()
	rig.position = Vector3.ZERO
	Game.set_state(Game.State.MENU)
	await _frames(3)


func check_lesson_up() -> void:
	if not ui.hud.lesson_visible():
		failures.append("cue-over-card check: no lesson card up (set-up)")


## Colour fidelity in VR: render the main menu with the pointer parked and
## read back the flat fills of the Play (ACCENT) and Quit (BUTTON) buttons,
## with and without the tonemap compensation. With it, the headset should
## show the designed colours; without it, Filmic visibly dulls them.
func _measure_fidelity() -> void:
	_park_hands()
	Game.set_state(Game.State.MENU)
	ui.show_state_screen()
	ui.menu_panel.snap_to_head()
	var main := ui.get_screen(&"main")
	var samples := {"accent": [main.get_button(&"play"), UITheme.ACCENT], "button": [main.get_button(&"quit"), UITheme.BUTTON]}
	var mat := ui.menu_panel.get_material()
	for mode in ["compensated", "uncompensated"]:
		mat.set_shader_parameter(&"compensate", mode == "compensated")
		await _shot("vr_fidelity_%s" % mode)
		var img := Image.load_from_file(out.path_join("vr_fidelity_%s.png" % mode))
		for key: String in samples:
			var b: Control = samples[key][0]
			var want: Color = samples[key][1]
			# A point inside the fill, left of the label text.
			var r := b.get_global_rect()
			var px := Vector2(r.position.x + 16.0, r.get_center().y)
			var sp := cam.unproject_position(ui.menu_panel.pixel_to_world(px))
			var got := _median(img, Vector2i(sp))
			var err := maxf(maxf(absf(got.r - want.r), absf(got.g - want.g)), absf(got.b - want.b)) * 255.0
			report["fidelity_%s_%s" % [mode, key]] = {"want": want.to_html(false), "got": got.to_html(false), "max_channel_error_255": snappedf(err, 0.1)}
			print("[ui] fidelity %s %s: want %s got %s (max err %.1f/255)" % [mode, key, want.to_html(false), got.to_html(false), err])
			if mode == "compensated" and err > 2.0:
				failures.append("VR colour %s rendered %s, designed %s (%.1f/255 off)" % [key, got.to_html(false), want.to_html(false), err])
	mat.set_shader_parameter(&"compensate", true)
	ui.refresh_tonemap()
	# Contrast of the designed pairs as the headset shows them, both ways.
	var p := UITonemap.params(UITonemap.active_environment(get_viewport()))
	report["contrast_text_on_button_compensated"] = snappedf(UITheme.contrast(UITheme.TEXT, UITheme.BUTTON), 0.01)
	report["contrast_text_on_button_uncompensated"] = snappedf(UITheme.contrast(UITonemap.apply(UITheme.TEXT, p), UITonemap.apply(UITheme.BUTTON, p)), 0.01)


func _median(img: Image, at: Vector2i) -> Color:
	var rs := []
	var gs := []
	var bs := []
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var c := img.get_pixel(clampi(at.x + dx, 0, img.get_width() - 1), clampi(at.y + dy, 0, img.get_height() - 1))
			rs.append(c.r)
			gs.append(c.g)
			bs.append(c.b)
	rs.sort()
	gs.sort()
	bs.sort()
	return Color(rs[12], gs[12], bs[12])


## The content the verifiers found overflowing or misworded, as the headset
## receives it: the apex run summary with a new best, caught by an eagle,
## and the pause screen as a hawk and as the eagle.
func _worst_case_panels() -> void:
	_park_hands()
	var by := {}
	for i in SizeRules.SPECIES.size() - 1:
		by[SizeRules.SPECIES[i]["id"]] = 3 + i * 7
	Game.set_state(Game.State.MENU)
	gl.start_run()
	await _frames(2)
	gl.fake_end({"score": 98765, "max_mass": 3.2, "max_tier": 9, "time": 1834.0, "catches_by_species": by,
		"new_records": {"score": true}, "records": {"best_score": 98765}})
	ui.menu_panel.snap_to_head()
	await _panel_texture("panel_summary_apex")
	await _shot("vr_summary_apex")
	Game.set_state(Game.State.MENU)
	gl.start_run()
	await _frames(2)
	var eagle := _bird(&"eagle", 3.0)
	gl.fake_caught(eagle)
	await _panel_texture("panel_caught_eagle")
	Game.set_state(Game.State.PLAYING)
	gl.stats["apex"]["catches"] = 2
	# Plausible runs for each size: time and catches grow together.
	var runs := {5: [462.0, 12], 8: [1104.0, 31], 9: [1452.0, 44]}
	for sp: int in [5, 8, 9]:
		player.mass = float(SizeRules.SPECIES[sp]["mass"]) * 1.05
		Game.run_time = float(runs[sp][0])
		gl.stats["catches"] = int(runs[sp][1])
		Game.set_state(Game.State.PAUSED)
		await _panel_texture("panel_pause_%s" % SizeRules.SPECIES[sp]["id"])
		Game.set_state(Game.State.PLAYING)
	# Holding "Restart run": the bar half full (hold to confirm).
	Game.set_state(Game.State.PAUSED)
	await _frames(3)
	var restart := ui.get_screen(&"pause").get_button(&"restart") as HoldButton
	ui.menu_panel.snap_to_head()
	right.aim_at(rig.global_transform * Vector3(0.22, 1.25, -0.25), ui.menu_panel.control_to_world(restart))
	await get_tree().create_timer(0.3).timeout
	right.trigger_value = 1.0
	await get_tree().create_timer(HoldButton.HOLD_S * 0.5).timeout
	await _panel_texture("panel_pause_holding")
	right.trigger_value = 0.0
	await _frames(3)
	await _panel_texture("panel_pause_hold_hint")
	_park_hands()
	Game.set_state(Game.State.PLAYING)
	gl.stats["apex"]["catches"] = 0
	# A won run: the victory headline and Keep flying.
	player.mass = 3.2
	Game.run_time = 1834.0
	gl.stats["score"] = 12480
	gl.stats["catches_by_species"] = {&"hawk": 2, &"gull": 5, &"crow": 9, &"pigeon": 14, &"starling": 21}
	for i in 5:
		gl.fake_apex_catch()
	await _frames(3)
	ui.menu_panel.snap_to_head()
	await _panel_texture("panel_summary_victory")
	await _shot("vr_summary_victory")
	Game.set_state(Game.State.MENU)
	player.mass = SizeRules.SPECIES[2]["mass"]
	eagle.queue_free()


## Every species icon, large, as prey and as threat: shape must say which
## bird it is (colour says what it is to you).
func _species_sheet() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(5 * 260, 4 * 230)
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = UITheme.PANEL
	bg.size = Vector2(vp.size)
	vp.add_child(bg)
	for row in 2:
		for i in SizeRules.SPECIES.size():
			var cell := Vector2((i % 5) * 260, (i / 5 + row * 2) * 230)
			var icon := BirdIcon.new()
			icon.position = cell + Vector2(20, 10)
			icon.size = Vector2(220, 150)
			icon.setup(BirdIcon.Relation.PREY if row == 0 else BirdIcon.Relation.THREAT, 1.0, SizeRules.SPECIES[i]["id"])
			vp.add_child(icon)
			var l := UIScreen.make_label(SizeRules.SPECIES[i]["name"])
			l.position = cell + Vector2(0, 150)
			l.size = Vector2(260, 70)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.add_theme_font_override("font", UITheme.font(700))
			l.add_theme_font_size_override("font_size", 44)
			vp.add_child(l)
	await _frames(3)
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(out.path_join("icons_species.png"))
	vp.queue_free()


## U7 from pixels: a canvas shader driven by TIME changes the panel texture
## on every real render, so "the probe pixel stayed the same" = "the
## SubViewport did not render". Idle menu: 1 distinct value over 20 frames;
## keep_alive (positive control): many; after a hover settles: 1 again. The
## same for the HUD while flying with nothing changing.
func _measure_render_budget() -> void:
	ui.set_vr_mode(true)
	_park_hands()
	Game.set_state(Game.State.MENU)
	ui.show_state_screen()
	ui.menu_panel.snap_to_head()
	var menu_probe := _time_probe(ui.get_screen(&"main"), Vector2(700, 20))
	await _frames(12)
	var vp := ui.menu_panel.get_viewport_node()
	var idle := await _distinct(vp, Vector2i(720, 40), 20)
	ui.menu_panel.keep_alive(0.6)
	var live := await _distinct(vp, Vector2i(720, 40), 20)
	await get_tree().create_timer(0.8).timeout
	var b := ui.get_screen(&"main").get_button(&"settings")
	right.aim_at(rig.global_transform * Vector3(0.22, 1.25, -0.25), ui.menu_panel.control_to_world(b))
	await _frames(10)
	var after_hover := await _distinct(vp, Vector2i(720, 40), 20)
	menu_probe.queue_free()
	_park_hands()
	# HUD while flying: no lesson, no cue changes, growth steady.
	ui.onboarding.skip()
	gl.start_run()
	await _frames(4)
	var hud_probe := _time_probe(ui.hud, Vector2(20, 240))
	await _frames(12)
	var hud_idle := await _distinct(ui.hud_panel.get_viewport_node(), Vector2i(40, 260), 20)
	hud_probe.queue_free()
	Game.set_state(Game.State.MENU)
	report["render_budget"] = {"menu_idle_distinct_20f": idle, "menu_keep_alive_distinct_20f": live,
		"menu_after_hover_distinct_20f": after_hover, "hud_idle_distinct_20f": hud_idle}
	print("[ui] render budget: idle %d, keep_alive %d, after hover %d, hud idle %d distinct probe values in 20 frames" % [idle, live, after_hover, hud_idle])
	if idle != 1:
		failures.append("idle main menu re-rendered (%d distinct probe values in 20 frames)" % idle)
	if live < 6:
		failures.append("positive control failed: keep_alive did not render every frame (%d)" % live)
	if after_hover != 1:
		failures.append("menu kept rendering after the hover settled (%d)" % after_hover)
	if hud_idle != 1:
		failures.append("idle HUD re-rendered (%d)" % hud_idle)


func _time_probe(parent: Control, at: Vector2) -> ColorRect:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(fract(TIME * 7.31), fract(TIME * 3.7), 0.5, 1.0); }\n"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var r := ColorRect.new()
	r.material = mat
	r.position = at
	r.size = Vector2(40, 40)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


func _distinct(vp: SubViewport, px: Vector2i, frames: int) -> int:
	var seen := {}
	for i in frames:
		await RenderingServer.frame_post_draw
		seen[vp.get_texture().get_image().get_pixelv(px).to_html()] = true
	return seen.size()


## Depth honesty: panels ignore depth so scenery never cuts into them, but
## the player's hands and wings are nearer than any panel and must stay in
## front of it. A "hand" block marked with UIPanel.mark_occluder and a
## "branch" block that is not both sit between the eye and the menu: the
## hand must show, the branch must be painted over by the panel.
func _measure_occluders() -> void:
	_park_hands()
	Game.set_state(Game.State.MENU)
	ui.show_state_screen()
	ui.menu_panel.snap_to_head()
	await _frames(3)
	var head := cam.global_transform
	var hand_col := Color("d9a27a")
	var branch_col := Color("7a5236")
	var blocks := []
	for spec: Array in [[Vector3(-0.28, -0.05, -0.55), hand_col, true], [Vector3(0.3, 0.05, -0.9), branch_col, false]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.09, 0.09, 0.09)
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = spec[1]
		if spec[2]:
			UIPanel.mark_occluder(mat)
		mi.material_override = mat
		add_child(mi)
		mi.global_position = head * spec[0]
		blocks.append(mi)
	ui.menu_panel.mark_dirty()
	await _shot("vr_occluders")
	var img := Image.load_from_file(out.path_join("vr_occluders.png"))
	var hand_px := _median(img, Vector2i(cam.unproject_position(blocks[0].global_position)))
	var branch_px := _median(img, Vector2i(cam.unproject_position(blocks[1].global_position)))
	var hand_err := _max_err(hand_px, UITonemap.apply(hand_col, UITonemap.params(UITonemap.active_environment(get_viewport()))))
	var branch_err := _max_err(branch_px, UITonemap.apply(branch_col, UITonemap.params(UITonemap.active_environment(get_viewport()))))
	report["occluders"] = {"hand_pixel": hand_px.to_html(false), "hand_matches_hand": hand_err < 6.0,
		"branch_pixel": branch_px.to_html(false), "branch_visible": branch_err < 6.0}
	print("[ui] occluders: hand pixel %s (hand colour err %.1f), branch pixel %s (branch colour err %.1f)" % [
		hand_px.to_html(false), hand_err, branch_px.to_html(false), branch_err])
	if hand_err >= 6.0:
		failures.append("the player's hand was painted over by the panel (pixel %s)" % hand_px.to_html(false))
	if branch_err < 6.0:
		failures.append("scenery cut into the panel (branch visible, pixel %s)" % branch_px.to_html(false))
	for b: Node in blocks:
		b.queue_free()
	await _frames(2)


func _max_err(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) * 255.0


## A UI change made right after a frame was drawn (here: Skip tutorial in
## the continuation of a screenshot, which resumes from frame_post_draw)
## must still reach the HUD texture on the next frame. The verifiers saw
## the hidden lesson card stay in the texture until something else changed.
func _measure_late_change() -> void:
	ui.set_vr_mode(true)
	_park_hands()
	Game.set_state(Game.State.MENU)
	ui.onboarding.reset()
	gl.start_run()
	await _frames(8)
	var vp := ui.hud_panel.get_viewport_node()
	var px := Vector2i(UITheme.HUD_SIZE.x / 2 + 200, 150)
	await RenderingServer.frame_post_draw
	var before := vp.get_texture().get_image().get_pixelv(px).a
	await _shot("vr_late_change_before")
	# We are inside frame_post_draw now: this frame's draw is over.
	ui.onboarding.skip()
	await _frames(2)
	await RenderingServer.frame_post_draw
	var after := vp.get_texture().get_image().get_pixelv(px).a
	report["late_change"] = {"card_alpha_before": snappedf(before, 0.01), "card_alpha_2_frames_after_postdraw_skip": snappedf(after, 0.01)}
	print("[ui] late change: lesson card alpha %.2f -> %.2f after a post-draw Skip" % [before, after])
	if before < 0.5:
		failures.append("late-change check: the lesson card was not in the HUD texture to begin with (%.2f)" % before)
	if after > 0.1:
		failures.append("a change made after the draw never reached the HUD texture (card alpha %.2f)" % after)
	# A change made while draws are skipped (a window that cannot draw, a
	# headset session that is not visible: here the render loop is turned
	# off for 4 frames) must still reach the texture once drawing resumes.
	# Round 3 found the request was dropped after one frame without a draw.
	Game.set_state(Game.State.MENU)
	ui.onboarding.reset()
	gl.start_run()
	await _frames(8)
	await RenderingServer.frame_post_draw
	var before2 := vp.get_texture().get_image().get_pixelv(px).a
	RenderingServer.render_loop_enabled = false
	ui.onboarding.skip()
	await _frames(4)
	RenderingServer.render_loop_enabled = true
	await _frames(2)
	await RenderingServer.frame_post_draw
	var after2 := vp.get_texture().get_image().get_pixelv(px).a
	report["skipped_draws_change"] = {"card_alpha_before": snappedf(before2, 0.01), "card_alpha_after_4_skipped_draws": snappedf(after2, 0.01)}
	print("[ui] skipped draws: lesson card alpha %.2f -> %.2f after a Skip made while 4 draws were skipped" % [before2, after2])
	if before2 < 0.5:
		failures.append("skipped-draw check: the lesson card was not in the HUD texture to begin with (%.2f)" % before2)
	if after2 > 0.1:
		failures.append("a change made while draws were skipped never reached the HUD texture (card alpha %.2f)" % after2)
	Game.set_state(Game.State.MENU)
