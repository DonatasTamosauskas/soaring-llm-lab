extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## The UI suite's evidence for a calm lesson card in the real game is a
## REPLAY of one recording (tests/unit/ui/ui_game_flights.json: 1 fade and
## 0 moves in the tutorial). The round-6 verifier's live probe measured 4
## fades and 2 moves; the builder answered that "the live ecosystem varies
## from run to run". This probe flies the builder's own recording schedule
## (tests/shots/ui_game_record.gd: each lesson with its gesture, then 15 s
## of cruising with the catch lesson up) in the LIVE game on the final code,
## with several bot seeds, and logs every fade and move of the lesson card
## with what caused it (the same cause test the recorder uses), how long the
## card stayed see-through, and how much of the time a resting gaze (the
## camera) could read it.
##
##   GD_TIMEOUT=1500 tools/gd.sh ui_verify --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r7x_live --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var results := {}


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)
	print("[ui-verify] real game booted: %s" % booted)


func after_all() -> void:
	print("[ui-verify] live summary: %s" % JSON.stringify(results))
	var f := FileAccess.open(Paths.artifacts("ui").path_join("verify/r7/live_tutorial.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(results, "  "))
	if kit:
		await kit.teardown()
	await wait_frames(5)


class Watch:
	var clock := 0.0
	var frames := 0
	var card_frames := 0
	var readable_in_view := 0
	var fades: Array = []
	var moves: Array = []
	var fade_lengths: Array = []
	var _st := false
	var _st_t := 0.0
	var _moves_seen := -1
	var last_entries := PackedFloat64Array()
	var max_active_vp := 0


func _causes() -> String:
	var ui := kit.main.ui
	var p := kit.main.player
	var eye := p.camera.global_position
	var out: Array[String] = []
	var dirs := {}
	if p.velocity.length() > 1.5 * p.origin.world_scale:
		dirs["path"] = p.velocity
	var tgt: Variant = ui.get(&"_target")
	var thr: Variant = ui.get(&"_threat")
	if is_instance_valid(tgt) and (tgt as Bird).is_inside_tree():
		dirs["target"] = (tgt as Bird).get_body_position() - eye
	if is_instance_valid(thr) and (thr as Bird).is_inside_tree() and UIRoot.is_real_threat(float(ui.get(&"_threat_level"))):
		dirs["threat"] = (thr as Bird).get_body_position() - eye
	for which: StringName in [&"target", &"threat"]:
		var cue := ui.indicators.cue_mesh(which)
		if cue and cue.visible:
			dirs["%s cue" % which] = cue.global_position - eye
	var m := deg_to_rad(HUD.FADE_MARGIN_DEG) * UITheme.HUD_DISTANCE * UITheme.PX_PER_M
	for key: String in dirs:
		var px := ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, (dirs[key] as Vector3).normalized())
		if not px.is_finite():
			continue
		for r: Rect2 in ui.hud.notice_rects():
			if r.grow(m).has_point(px):
				out.append(key)
				break
	return ",".join(out)


## Largest angle (deg) from the camera's gaze to the card's words.
func _ecc() -> float:
	var ui := kit.main.ui
	var cam := kit.main.player.camera
	var g := -cam.global_basis.z
	var worst := 0.0
	for lbl: Label in ui.hud.lesson_labels():
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			x0 = r.end.x - w
		elif lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w * 0.5, x0 + w]:
			var d := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - cam.global_position
			worst = maxf(worst, rad_to_deg(g.angle_to(d)))
	return worst


func _watch(w: Watch) -> void:
	var ui := kit.main.ui
	if Game.state != Game.State.PLAYING or not ui.hud_panel.shown:
		return
	w.frames += 1
	w.clock += 1.0 / 72.0
	w.max_active_vp = maxi(w.max_active_vp, ui.active_viewport_count())
	var hud := ui.hud
	if not hud.lesson_visible() or hud.toast_active():
		w._st = false
		return
	w.card_frames += 1
	var st: bool = hud.see_through[HUD.BAND_NOTICE]
	if w._moves_seen < 0:
		w._moves_seen = hud.move_count
	var moved := hud.move_count != w._moves_seen
	w._moves_seen = hud.move_count
	# The crossings HUD counts towards a move (MOVE_AFTER_ENTRIES in
	# ENTRY_WINDOW_S), as HUD clock times; a move clears them.
	var ent: PackedFloat64Array = hud.get(&"_entries")
	if ent.size() > 0:
		w.last_entries = ent.duplicate()
	if moved:
		var hc := float(hud.get(&"_clock"))
		var rel: Array = []
		for e in w.last_entries:
			rel.append(snappedf(e - hc, 0.01))
		w.moves.append([snappedf(w.clock, 0.01), _causes(), hud.lesson_title(), {"crossings_counted_s_before": rel}])
	elif st and not w._st:
		w.fades.append([snappedf(w.clock, 0.01), _causes(), hud.lesson_title()])
	if st and not w._st:
		w._st_t = w.clock
	if not st and w._st:
		w.fade_lengths.append(snappedf(w.clock - w._st_t, 0.01))
	w._st = st
	var a := ui.hud_panel.band_alpha(HUD.BAND_NOTICE)
	if a >= HUD.READABLE_ALPHA and _ecc() <= 45.0:
		w.readable_in_view += 1


func _fly_tutorial(seed_value: int) -> Dictionary:
	var ui := kit.main.ui
	if Game.state != Game.State.MENU:
		ui.bridge.quit_to_menu()
		await kit.frames(3)
	ui.onboarding.reset()
	await kit.frames(2)
	var clicked := await kit.click(&"main", &"play")
	if not await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0):
		return {"error": "Play did not start a run", "clicked": clicked}
	var w := Watch.new()
	# Sampled at the END of each process frame (after the UI placed the
	# panels for it): SceneTree.process_frame fires before, when the rig has
	# moved but the HUD has not (the round-6 verifier's LateSampler note).
	var sampler := _Late.new(func() -> void: _watch(w))
	add_child(sampler)
	kit.fly_bot(seed_value)
	var rr0 := [ui.hud_panel.render_requests, ui.menu_panel.render_requests]
	var ob := ui.onboarding
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	var done := {}
	var on_done := func(_i: int, id: StringName, timed_out: bool) -> void: done[String(id)] = "timed out" if timed_out else "done"
	ob.lesson_completed.connect(on_done)
	while t < 100.0 and ob.active and ob.current().get("id") != &"catch" and Game.state == Game.State.PLAYING:
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	kit.set_mode(&"cruise")
	await kit.advance(15.0)
	sampler.queue_free()
	ob.lesson_completed.disconnect(on_done)
	var hud_renders: int = ui.hud_panel.render_requests - int(rr0[0])
	var menu_renders: int = ui.menu_panel.render_requests - int(rr0[1])
	var r := {"seed": seed_value, "lessons_s": t, "card_s": snappedf(w.card_frames / 72.0, 0.01),
		"readable_in_view_frac": snappedf(float(w.readable_in_view) / maxi(w.card_frames, 1), 0.001),
		"fades": w.fades, "moves": w.moves, "fade_lengths_s": w.fade_lengths, "lessons": done,
		"state_at_end": Game.State.keys()[Game.state],
		"hud_renders_per_s": snappedf(hud_renders / maxf(w.frames / 72.0, 0.01), 0.01), "menu_renders_in_play": menu_renders,
		"max_active_viewports": w.max_active_vp}
	return r


func _judge(r: Dictionary) -> void:
	if r.has("error"):
		check(false, "seed %s: %s" % [r.get("seed"), r["error"]])
		return
	var nf := (r["fades"] as Array).size()
	var nm := (r["moves"] as Array).size()
	print("[ui-verify] live tutorial seed %d: fades %d moves %d readable-in-view %.3f over %.1f s | %s" % [r["seed"], nf, nm, r["readable_in_view_frac"], r["card_s"], JSON.stringify(r)])
	# The builder's own bars for the tutorial (ui_hud_test, replayed): read
	# in view >= 95 %, fewer than 3 fades, at most 1 move.
	gt(float(r["readable_in_view_frac"]), 0.95, "seed %d: the card read in view %.1f %% of the live tutorial (the suite's bar 95 %%)" % [r["seed"], 100.0 * float(r["readable_in_view_frac"])])
	lt(nf, 3, "seed %d: %d fades in the live tutorial (the suite's bar: < 3)" % [r["seed"], nf])
	lt(nm, 2, "seed %d: %d moves in the live tutorial (the suite's bar: <= 1)" % [r["seed"], nm])


func test_a_live_tutorial_seed_21() -> void:
	check(booted, "the real game booted")
	if not booted:
		return
	var r := await _fly_tutorial(21)
	results["seed_21"] = r
	_judge(r)


func test_b_live_tutorial_seed_5() -> void:
	if not booted:
		return
	var r := await _fly_tutorial(5)
	results["seed_5"] = r
	_judge(r)


func test_c_live_tutorial_seed_77() -> void:
	if not booted:
		return
	var r := await _fly_tutorial(77)
	results["seed_77"] = r
	_judge(r)


class _Late:
	extends Node
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()
