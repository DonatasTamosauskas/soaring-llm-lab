extends Node
## VERIFIER PROBE (core-loop round 1, first-time player & UI lens). Not a suite.
## A first launch on desktop in the REAL game (main.tscn via the integration
## kit, VR-form menus with scripted pointers, flight through BotPoseSource ->
## WingInput): menu, How to fly, Settings, Play, the lessons IN THE ORDER THE
## GAME GIVES THEM (nothing skipped or reset), the catch lesson chased at the
## target cue, the first real attack, pause / settings / restart.
## Screenshots of the head view at each step (needs a window, forward_plus):
##   tools/gd.sh vux1_desk --rendering-method forward_plus --resolution 1280x720 --fixed-fps 72 \
##       res://tests/probes/coreloop/vux1_first_launch.tscn -- --fresh-settings [--seed=21] [--tag=a]
## Writes artifacts/coreloop/verify/vux1/<tag>/NN_<step>.png and report.json.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const WristPilot := preload("res://tests/shots/ui_wrist_pilot.gd")

var kit: Kit
var dir := ""
var n := 0
var rep := {"steps": [], "lessons": [], "notes": []}
var _target: Bird
var _threat: Bird
var _threat_level := 0.0
var _first_threat_t := -1.0
var _run_t := 0.0
var _playing := false
## Frames the flight path sat behind a readable notice plate, and the longest run.
var _path_hidden_frames := 0
var _path_hidden_run := 0
var _path_hidden_longest := 0
var _lesson_frames := 0
var _moves0 := -1
var _catches: Array = []


func _ready() -> void:
	var tag := Paths.arg("tag", "a")
	dir = ProjectSettings.globalize_path("res://").path_join("artifacts/coreloop/verify/vux1").path_join(tag)
	var root := OS.get_environment("SOARING_ROOT")
	if not root.is_empty():
		dir = root.path_join("artifacts/coreloop/verify/vux1").path_join(tag)
	DirAccess.make_dir_recursive_absolute(dir)
	await _run()
	if kit and kit.log:
		rep["errors"] = kit.log.errors
		rep["warnings"] = kit.log.warnings
	rep["path_hidden_frames"] = _path_hidden_frames
	rep["path_hidden_longest_s"] = _path_hidden_longest / 72.0
	rep["lesson_card_frames"] = _lesson_frames
	var f := FileAccess.open(dir.path_join("report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rep, "  "))
	f.close()
	print("[vux1] REPORT %s" % JSON.stringify(rep))
	if kit:
		await kit.teardown()
	get_tree().quit(0)


func _note(s: String) -> void:
	print("[vux1] " + s)
	(rep["notes"] as Array).append("%.1f %s" % [_run_t, s])


func _hud_state() -> Dictionary:
	var ui := kit.main.ui
	var hud := ui.hud
	var d := {"state": Game.state_name(), "screen": String(ui.current_screen_id()), "t": snappedf(_run_t, 0.1)}
	if hud.lesson_visible():
		var labels := hud.lesson_labels()
		d["card"] = [hud.lesson_title()] + labels.map(func(l: Label) -> String: return l.text)
		d["see_through"] = hud.see_through[HUD.BAND_NOTICE]
	var ob := ui.onboarding
	d["lesson"] = String(ob.current().get("id", "")) if ob.active else ""
	for which: StringName in [&"target", &"threat"]:
		var cue := ui.indicators.cue_mesh(which)
		d[String(which) + "_cue"] = cue != null and cue.visible
	d["threat_level"] = snappedf(_threat_level, 0.01) if is_instance_valid(_threat) else 0.0
	var p := kit.main.player
	if p != null:
		var pp := p.get_body_position()
		d["agl"] = snappedf(pp.y - kit.main.world.ground_height(pp.x, pp.z), 0.1)
		d["speed"] = snappedf(p.velocity.length(), 0.1)
		if is_instance_valid(_target) and _target.is_inside_tree():
			d["target"] = "%s %.0f m dy %.0f" % [_target.species, _target.get_body_position().distance_to(pp), _target.get_body_position().y - pp.y]
		var gl := kit.main.game_loop
		if gl.has_method(&"lesson_prey"):
			var near := INF
			var dy := 0.0
			for b: Bird in gl.lesson_prey():
				var dd := b.get_body_position().distance_to(pp)
				if dd < near:
					near = dd
					dy = b.get_body_position().y - pp.y
			d["lesson_prey"] = "%d, nearest %.0f m dy %.0f" % [gl.lesson_prey().size(), near, dy] if is_finite(near) else "none"
	return d


func shot(name_: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p := dir.path_join("%02d_%s.png" % [n, name_])
	n += 1
	if img:
		img.save_png(p)
	var st := _hud_state()
	st["shot"] = p.get_file()
	(rep["steps"] as Array).append(st)
	print("[vux1] SHOT %s %s" % [p.get_file(), JSON.stringify(st)])


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self):
		_note("FAIL: the game did not boot")
		return
	var ui := kit.main.ui
	var ob := ui.onboarding
	Events.target_changed.connect(func(b: Bird) -> void: _target = b)
	Events.threat_changed.connect(func(lv: float, b: Bird) -> void:
		_threat = b
		_threat_level = lv
		if _playing and _first_threat_t < 0.0 and is_instance_valid(b) and UIRoot.is_real_threat(lv):
			_first_threat_t = _run_t
			_note("first real threat %s level %.2f at %.1f s of play" % [b.species, lv, _run_t]))
	Events.bird_caught.connect(func(pred: Bird, prey: Bird) -> void:
		if is_instance_valid(pred) and pred.is_player() and is_instance_valid(prey):
			_catches.append([snappedf(_run_t, 0.1), String(prey.species)]))
	ob.lesson_completed.connect(func(i: int, id: StringName, timed_out: bool) -> void:
		(rep["lessons"] as Array).append({"i": i, "id": String(id), "timed_out": timed_out, "elapsed": snappedf(ob._elapsed, 0.1), "t": snappedf(_run_t, 0.1)})
		_note("lesson %s done (timed out %s) after %.1f s" % [id, timed_out, ob._elapsed]))
	var late := _Late.new(_every_frame)
	add_child(late)
	await kit.frames(30)
	await shot("menu")
	# How to fly and Settings from the main menu.
	if await kit.click(&"main", &"howto"):
		await kit.frames(20)
		await shot("howto")
		await kit.click(&"howto", &"back")
		await kit.frames(20)
	else:
		_note("How to fly not hovered")
	if await kit.click(&"main", &"settings"):
		await kit.frames(20)
		await shot("settings_main")
		await kit.click(&"settings", &"back")
		await kit.frames(20)
	else:
		_note("Settings not hovered")
	if not await kit.click(&"main", &"play"):
		_note("FAIL: Play not hovered")
	if not await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0):
		_note("FAIL: Play did not start a run (state %s)" % Game.state_name())
		return
	_playing = true
	rep["lesson_at_play"] = String(ob.current().get("id", "")) if ob.active else "(none)"
	await kit.frames(10)
	await shot("play_first_frame")
	kit.fly_bot(int(Paths.arg("seed", "21")), WristPilot)
	kit.pilot.set(&"agl", 35.0)
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"glide",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var last_id := &""
	var t_lesson := 0.0
	var shot_mid := false
	var shot_cele := false
	var t := 0.0
	while t < 240.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		if id != last_id:
			last_id = id
			t_lesson = 0.0
			shot_mid = false
			shot_cele = false
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"dive"] and agl < 20.0):
			mode = &"climb"
		kit.set_mode(mode)
		kit.pilot.set(&"hold_pitch", -0.6 if (id == &"speed" and mode == &"glide") else NAN)
		if not shot_mid and t_lesson >= 1.2 and ob.celebrating <= 0.0:
			shot_mid = true
			await shot("lesson_%s" % id)
		if not shot_cele and ob.celebrating > 0.3:
			shot_cele = true
			await shot("done_%s" % id)
		await kit.advance(0.25)
		t += 0.25
		t_lesson += 0.25
		if t_lesson > 75.0:
			_note("lesson %s not done after 75 s of its gesture" % id)
			break
	kit.pilot.set(&"hold_pitch", NAN)
	kit.set_mode(&"cruise")
	kit.cruise()
	kit.pilot.set(&"agl", float(Paths.arg("catch_agl", "35")))
	rep["catch_agl"] = float(Paths.arg("catch_agl", "35"))
	rep["lessons_before_catch_s"] = t
	# The catch lesson, chased at the target cue as a competent player does.
	if ob.active and ob.current().get("id") == &"catch":
		await kit.advance(1.5)
		await shot("lesson_catch_start")
		var tc := 0.0
		var shots_at := [6.0, 15.0, 30.0, 45.0, 65.0, 95.0]
		var ring_t := -1.0
		while tc < 200.0 and ob.active and ob.current().get("id") == &"catch":
			var cue_on := kit.main.ui.indicators.cue_mesh(&"target") != null and kit.main.ui.indicators.cue_mesh(&"target").visible
			rep["catch_cue_frames"] = int(rep.get("catch_cue_frames", 0)) + (1 if cue_on else 0)
			rep["catch_frames"] = int(rep.get("catch_frames", 0)) + 1
			if Paths.arg("no_chase", "") == "1":
				pass
			elif is_instance_valid(_target) and _target.alive and _target.is_inside_tree():
				if ring_t < 0.0:
					ring_t = tc
				kit.pilot.set(&"target", _target.get_body_position())
				kit.pilot.set(&"chase", true)
			elif bool(kit.pilot.get(&"chase")):
				kit.cruise()
			if ob.celebrating > 0.2 and not rep.has("catch_celebrated"):
				rep["catch_celebrated"] = true
				await shot("done_catch_celebration")
			if not shots_at.is_empty() and tc >= float(shots_at[0]):
				shots_at.pop_front()
				await shot("catch_%ds" % int(tc))
			await kit.advance(1.0 / 72.0)
			tc += 1.0 / 72.0
			if Game.state == Game.State.CAUGHT:
				await shot("caught_during_catch_lesson")
				await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 20.0)
		rep["catch_lesson_s"] = snappedf(tc, 0.1)
		rep["catch_ring_first_s"] = ring_t
		await kit.advance(0.4)
		await shot("done_catch")
	else:
		_note("catch lesson never came (lesson %s)" % str(ob.current().get("id", "")))
	rep["catches"] = _catches.duplicate()
	# After the lessons: hunt the cue until the first real attack (up to 180 s).
	var ta := 0.0
	var threat_shots := 0
	while ta < float(Paths.arg("attack_wait", "150")) and threat_shots < 3:
		if Game.state == Game.State.CAUGHT:
			await shot("caught_screen")
			_note("caught by a predator at %.1f s of play" % _run_t)
			await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 20.0)
			await kit.advance(1.0)
			await shot("respawn")
			continue
		if is_instance_valid(_threat) and _threat_level >= 0.3:
			if threat_shots == 0:
				rep["first_attack_s"] = snappedf(_run_t, 0.1)
				_note("first attack (level >= 0.3) by %s at %.1f s of play" % [_threat.species, _run_t])
			await shot("attack_%d" % threat_shots)
			threat_shots += 1
			await kit.advance(0.5)
			continue
		if is_instance_valid(_target) and _target.alive and _target.is_inside_tree():
			kit.pilot.set(&"target", _target.get_body_position())
			kit.pilot.set(&"chase", true)
		elif bool(kit.pilot.get(&"chase")):
			kit.cruise()
		await kit.advance(1.0 / 72.0)
		ta += 1.0 / 72.0
	rep["first_threat_s"] = _first_threat_t
	rep["catches"] = _catches.duplicate()
	# Pause, settings, resume, restart.
	if Game.state == Game.State.CAUGHT:
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 20.0)
	Events.menu_requested.emit()
	await kit.frames(20)
	await shot("pause")
	if await kit.click(&"pause", &"settings"):
		await kit.frames(20)
		await shot("settings_pause")
		await kit.click(&"settings", &"back")
		await kit.frames(20)
	if await kit.click(&"pause", &"resume"):
		await kit.frames(30)
		_note("resumed: state %s" % Game.state_name())
	Events.menu_requested.emit()
	await kit.frames(20)
	var held := await kit.hold(&"pause", &"restart")
	_note("restart held: %s state %s" % [held, Game.state_name()])
	await kit.frames(30)
	await shot("after_restart")
	rep["lesson_after_restart"] = String(ob.current().get("id", "")) if ob.active else "(none)"
	late.queue_free()


func _every_frame() -> void:
	if kit == null or kit.main == null:
		return
	if Game.state == Game.State.PLAYING and _playing:
		_run_t += 1.0 / 72.0
	var ui := kit.main.ui
	var hud := ui.hud
	if Game.state != Game.State.PLAYING or not hud.lesson_visible():
		_path_hidden_run = 0
		return
	_lesson_frames += 1
	var p := kit.main.player
	if hud.see_through[HUD.BAND_NOTICE] or p.velocity.length() < 1.5 * p.origin.world_scale:
		_path_hidden_run = 0
		return
	var px := ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, p.velocity.normalized())
	var hidden := false
	if px.is_finite():
		for r: Rect2 in hud.notice_rects():
			if r.has_point(px):
				hidden = true
	if hidden:
		_path_hidden_frames += 1
		_path_hidden_run += 1
		_path_hidden_longest = maxi(_path_hidden_longest, _path_hidden_run)
	else:
		_path_hidden_run = 0


class _Late:
	extends Node
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()
