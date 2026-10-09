extends TestCase
## VERIFIER PROBE (round 6, experience lens). Not part of the UI suite.
##
## The UI area's own suites use mocks and replayed flights. This probe asks
## the player's question on the REAL game (scenes/main.tscn, booted by the
## integration area's test kit): Play by laser pointer, the first-flight
## lessons flown by the bot through the real WingInput / FlightModel /
## PlayerBird, a real tier-up through GameLoop's catch rule, a real hawk
## strike, pause during CAUGHT, the run summary, the main menu.
##
## Measured every rendered frame (--fixed-fps 72: one physics tick each):
##  - the lesson card: shown / readable (opacity >= 0.6) / in view (every
##    word within 45 deg of the gaze) / the real flight path behind it /
##    fades / moves / where its words sit relative to the flight path;
##  - the HUD centre line's error from UIRoot.flight_yaw (the real bird);
##  - the tier-up celebration: seconds read in view;
##  - the caught screen: the predator's name, lives, the countdown;
##  - the cues: target_changed rate, cuts and visibility toggles.
##
##   GD_TIMEOUT=1500 tools/gd.sh ui_verify --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r6x_real --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)
	print("[ui-verify] real game booted: %s" % booted)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


# --- measurement --------------------------------------------------------------

func _ui() -> UIRoot:
	return kit.main.ui


func _cam() -> Node3D:
	return kit.main.player.camera


## What the player sees of the notices (band opacity x a toast's own fade).
func _notice_opacity() -> float:
	var ui := _ui()
	var p := ui.hud_panel
	if not p.shown or not p.is_band_visible(HUD.BAND_NOTICE) or ui.hud.band_plates(HUD.BAND_NOTICE).is_empty():
		return 0.0
	var a := p.band_alpha(HUD.BAND_NOTICE)
	var toast := ui.hud.get_node_or_null("TierUp") as Control
	if toast and toast.visible:
		a *= toast.modulate.a
	return a


## Largest angle (deg) from the gaze to the labels' text (ends and middle).
func _ecc(labels: Array[Label], gaze := Vector3.ZERO) -> float:
	var ui := _ui()
	var g := -_cam().global_basis.z if gaze == Vector3.ZERO else gaze
	var worst := 0.0
	for lbl: Label in labels:
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
			var d := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - _cam().global_position
			worst = maxf(worst, rad_to_deg(g.angle_to(d)))
	return worst


## Azimuth span (deg, + = right) of the labels' text relative to `ref`
## (horizontal), and the smallest angle (deg) from the 3D direction `path`
## to any point of the text.
func _span(labels: Array[Label], path: Vector3) -> Vector3:
	var ui := _ui()
	var ref_az := atan2(path.x, -path.z)
	var mn := INF
	var mx := -INF
	var closest := INF
	for lbl: Label in labels:
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
			var d := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - _cam().global_position
			var a := -rad_to_deg(wrapf(atan2(d.x, -d.z) - ref_az, -PI, PI))
			mn = minf(mn, a)
			mx = maxf(mx, a)
			closest = minf(closest, rad_to_deg(path.angle_to(d)))
	return Vector3(mn, mx, closest)


## Is world direction `dir` (from the eye) behind a notice plate?
func _behind_notice(dir: Vector3) -> bool:
	var ui := _ui()
	var px := ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, dir)
	if not px.is_finite():
		return false
	for r: Rect2 in ui.hud.notice_rects():
		if r.has_point(px):
			return true
	return false


class Watch:
	## Per-frame accumulator (connected to process_frame).
	var t := 0.0
	var dt := 1.0 / 72.0
	var shown_s := 0.0
	var readable_s := 0.0
	var in_view_s := 0.0
	var hidden_s := 0.0
	var hidden_longest := 0.0
	var _hidden_run := 0.0
	var fades := 0
	var _faded := false
	var text_az := Vector2(INF, -INF)
	var closest_text_deg := INF
	var anchor_err_max := 0.0
	var anchor_err_over10_s := 0.0
	var ecc_max := 0.0
	var ecc_hist := {}
	var frames := 0
	## The first seconds after Play are skipped for the in-view numbers: in
	## a headless (non-XR) run the camera jumps from its unscaled menu
	## height to the flight's pose right after the HUD snapped (on a headset
	## the tracker scales it all along), and the HUD eases down over ~1 s.
	var skip_until := 1.5
	var counted_s := 0.0
	var in_view_path_s := 0.0
	var path_counted_s := 0.0
	## The HUD's centre line relative to the rig's forward (where the
	## torso, and a head at rest, face): the largest excursion, time spent
	## more than 45 deg out, total travel and the fastest swing.
	var hud_yaw_max := 0.0
	var hud_yaw_over45_s := 0.0
	var hud_travel := 0.0
	var hud_rate_max := 0.0
	var _prev_yaw := NAN


func _watch_notices(w: Watch, labels_fn: Callable) -> void:
	var ui := _ui()
	if Game.state != Game.State.PLAYING or not ui.hud_panel.shown:
		return
	w.frames += 1
	w.t += w.dt
	var p := kit.main.player
	var ws := p.origin.world_scale
	var op := _notice_opacity()
	var hy := rad_to_deg(ui.hud_panel.panel_yaw())
	w.hud_yaw_max = maxf(w.hud_yaw_max, absf(hy))
	if absf(hy) > 45.0:
		w.hud_yaw_over45_s += w.dt
	if is_finite(w._prev_yaw):
		var dy := absf(wrapf(hy - w._prev_yaw, -180.0, 180.0))
		w.hud_travel += dy
		w.hud_rate_max = maxf(w.hud_rate_max, dy / w.dt)
	w._prev_yaw = hy
	var err := absf(rad_to_deg(ui.hud_panel.anchor_error()))
	if is_finite(err):
		w.anchor_err_max = maxf(w.anchor_err_max, err)
		if err > 10.0:
			w.anchor_err_over10_s += w.dt
	if op <= 0.0:
		w._faded = false
		w._hidden_run = 0.0
		return
	w.shown_s += w.dt
	var faded := op < HUD.READABLE_ALPHA
	if faded and not w._faded:
		w.fades += 1
	w._faded = faded
	var labels: Array[Label] = labels_fn.call()
	var e := _ecc(labels)
	w.ecc_max = maxf(w.ecc_max, e)
	var bucket := int(e / 5.0) * 5
	w.ecc_hist[bucket] = int(w.ecc_hist.get(bucket, 0)) + 1
	var counting := w.t >= w.skip_until
	if counting:
		w.counted_s += w.dt
	if not faded:
		w.readable_s += w.dt
		if e <= 45.0 and counting:
			w.in_view_s += w.dt
	var v := p.velocity
	if counting and v.length() > 1.5 * ws:
		w.path_counted_s += w.dt
		if not faded and _ecc(labels, v.normalized()) <= 45.0:
			w.in_view_path_s += w.dt
	var hid := false
	if v.length() > 1.5 * ws:
		hid = not faded and _behind_notice(v.normalized())
		var sp := _span(labels, v)
		w.text_az = Vector2(minf(w.text_az.x, sp.x), maxf(w.text_az.y, sp.y))
		w.closest_text_deg = minf(w.closest_text_deg, sp.z)
	w._hidden_run = w._hidden_run + w.dt if hid else 0.0
	w.hidden_longest = maxf(w.hidden_longest, w._hidden_run)
	if hid:
		w.hidden_s += w.dt


func _report(w: Watch) -> Dictionary:
	return {"seconds_playing": snappedf(w.t, 0.01), "shown_s": snappedf(w.shown_s, 0.01),
		"readable_frac": snappedf(w.readable_s / maxf(w.shown_s, 1e-3), 0.001),
		"in_view_readable_frac": snappedf(w.in_view_s / maxf(w.counted_s, 1e-3), 0.001),
		"in_view_if_looking_along_path_frac": snappedf(w.in_view_path_s / maxf(w.path_counted_s, 1e-3), 0.001),
		"hud_yaw_from_rig_forward_max_deg": snappedf(w.hud_yaw_max, 0.1),
		"hud_yaw_over_45deg_s": snappedf(w.hud_yaw_over45_s, 0.01),
		"hud_yaw_travel_deg_per_min": snappedf(w.hud_travel / maxf(w.t / 60.0, 1e-3), 1.0),
		"hud_yaw_rate_max_deg_s": snappedf(w.hud_rate_max, 0.1),
		"path_hidden_s": snappedf(w.hidden_s, 0.001), "path_hidden_longest_s": snappedf(w.hidden_longest, 0.001),
		"fades": w.fades, "text_az_rel_path_deg": [snappedf(w.text_az.x, 0.1), snappedf(w.text_az.y, 0.1)],
		"closest_text_to_path_deg": snappedf(w.closest_text_deg, 0.1),
		"gaze_to_text_max_deg": snappedf(w.ecc_max, 0.1), "gaze_to_text_hist_5deg": w.ecc_hist,
		"hud_anchor_err_max_deg": snappedf(w.anchor_err_max, 0.1),
		"hud_anchor_err_over_10deg_s": snappedf(w.anchor_err_over10_s, 0.01)}


# --- the tests ------------------------------------------------------------------

func test_a_play_by_pointer_then_the_tutorial_flown_for_real() -> void:
	if not check(booted, "the real game booted"):
		return
	var m := kit.main
	var ui := _ui()
	ui.onboarding.reset()
	check(await kit.click(&"main", &"play"), "the pointer hovered Play")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "Play started a run")
	check(ui.hud_panel.shown, "the HUD is up")
	check(ui.onboarding.active, "the lessons started")
	var moves0 := ui.hud.move_count
	var w := Watch.new()
	var sampler := func() -> void: _watch_notices(w, func() -> Array[Label]: return ui.hud.lesson_labels())
	var _ls_sampler := LateSampler.new(sampler)
	add_child(_ls_sampler)
	# The cues in the real sky: how often GameLoop re-targets, and what the
	# UI's filters make of it.
	var tgt_changes := [0]
	var on_tgt := func(_b: Bird) -> void: tgt_changes[0] += 1
	Events.target_changed.connect(on_tgt)
	var tf := ui.indicators.target_filter
	var hf := ui.indicators.threat_filter
	var cuts0 := Vector2i(tf.cuts, hf.cuts)
	var tog0 := Vector2i(tf.toggles, hf.toggles)
	var vis := {"target": [false, 0], "threat": [false, 0]}
	var cue_watch := func() -> void:
		for which: String in ["target", "threat"]:
			var mi := ui.indicators.cue_mesh(StringName(which))
			var on := mi != null and mi.visible
			if on != vis[which][0]:
				vis[which][0] = on
				vis[which][1] = int(vis[which][1]) + 1
	var _ls_cue_watch := LateSampler.new(cue_watch)
	add_child(_ls_cue_watch)
	kit.fly_bot()
	var ob := ui.onboarding
	var done := {}
	ob.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void: done[id] = timed_out)
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	while t < 100.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	# The last lesson's card while cruising (the catch lesson waits for a catch).
	kit.set_mode(&"cruise")
	await kit.advance(15.0)
	_ls_sampler.queue_free()
	_ls_cue_watch.queue_free()
	Events.target_changed.disconnect(on_tgt)
	var r := _report(w)
	r["lessons_done"] = done
	r["tutorial_s"] = t
	r["moves"] = ui.hud.move_count - moves0
	r["target_changed_per_min"] = snappedf(tgt_changes[0] / maxf(w.t / 60.0, 1e-3), 0.1)
	r["target_cuts"] = tf.cuts - cuts0.x
	r["threat_cuts"] = hf.cuts - cuts0.y
	r["target_filter_toggles"] = tf.toggles - tog0.x
	r["threat_filter_toggles"] = hf.toggles - tog0.y
	r["target_cue_visibility_changes_per_min"] = snappedf(int(vis["target"][1]) / maxf(w.t / 60.0, 1e-3), 0.1)
	r["threat_cue_visibility_changes_per_min"] = snappedf(int(vis["threat"][1]) / maxf(w.t / 60.0, 1e-3), 0.1)
	metric("real_tutorial", r)
	print("[ui-verify] real tutorial: %s" % JSON.stringify(r))
	for id in [&"spread", &"flap", &"glide", &"speed", &"turn", &"dive"]:
		check(done.has(id) and not done[id], "lesson %s done by doing it in the real game" % id)
	# The builder's claims on replayed flights: 0 fades, 0 moves, path never
	# behind the card, read in view 100 %. On the real game, allow a little.
	gt(w.shown_s, 20.0, "the card was up (%.1f s)" % w.shown_s)
	lt(w.hidden_s, 0.25, "the real flight path is (almost) never behind the readable card (%.2f s)" % w.hidden_s)
	check(r["moves"] <= 1, "the card is calm: at most one move (%d)" % r["moves"])
	lt(float(w.fades), 3.0, "the card rarely fades (%d fades)" % w.fades)
	gt(float(r["in_view_readable_frac"]), 0.9, "looking where the body faces, the card is readable and in view >= 90 %% of the time (%.3f)" % r["in_view_readable_frac"])
	gt(float(r["in_view_if_looking_along_path_frac"]), 0.9, "looking along the flight path, the card is readable and in view >= 90 %% of the time (%.3f)" % r["in_view_if_looking_along_path_frac"])
	lt(float(r["hud_yaw_from_rig_forward_max_deg"]), 90.0, "the HUD never swings round behind the player (%.1f deg from the body's forward)" % r["hud_yaw_from_rig_forward_max_deg"])
	lt(float(r["hud_yaw_over_45deg_s"]), 1.0, "the HUD is rarely more than 45 deg from where the body faces (%.2f s)" % r["hud_yaw_over_45deg_s"])
	gt(w.closest_text_deg, 6.0, "the card's words never come within 6 deg of the real flight path (%.1f)" % w.closest_text_deg)
	lt(w.anchor_err_over10_s, 1.0, "the HUD sits on the real flight direction (%.2f s more than 10 deg off)" % w.anchor_err_over10_s)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


## Catch staged prey through the real catch rule (the integration suite's
## way: assisted reach, prey at the player's height).
func _catch(species: StringName, ahead := 30.0, tries := 3) -> bool:
	var m := kit.main
	var catches: int = kit.stats()["catches"]
	var assist0: float = m.game_loop.assist_override
	m.game_loop.assist_override = 1.0
	var ok := false
	for attempt in tries:
		kit.fly_straight()
		await kit.advance(1.5)
		await kit.wait_until(func() -> bool:
			return m.player.mode_name() == "flying" and absf(m.player.model.position.y - kit.pilot.h_target) < 1.0 \
				and absf(m.player.velocity.y) < 1.0, 8.0)
		var prey := kit.stage_prey(species, ahead)
		for i in 40:
			await kit.advance(0.2)
			if int(kit.stats()["catches"]) > catches:
				ok = true
				break
			if not is_instance_valid(prey):
				break
			var rel := prey.global_position - m.player.get_body_position()
			if rel.dot(m.player.velocity) < 0.0 and rel.length() > 1.5:
				break
		if is_instance_valid(prey) and not ok:
			kit.release(prey)
		kit.cruise()
		if ok:
			break
	m.game_loop.assist_override = assist0
	return ok


func test_b_a_real_tier_up_is_seen() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ui := _ui()
	var tier0 := SizeRules.tier_for_mass(m.player.mass)
	var toast := {"at": -1.0, "title": "", "in_view_s": 0.0, "shown_s": 0.0, "readable_s": 0.0, "hidden_s": 0.0,
		"view_angle_max": 0.0, "view_angle_min": INF, "life_s": 0.0}
	var clock := [0.0]
	var on_tier := func(_o: int, _n: int) -> void:
		toast["at"] = clock[0]
	Events.player_tier_changed.connect(on_tier)
	var sampler := func() -> void:
		clock[0] += 1.0 / 72.0
		if float(toast["at"]) < 0.0 or not ui.hud.toast_active():
			return
		toast["title"] = ui.hud.toast_text()
		toast["life_s"] = float(toast["life_s"]) + 1.0 / 72.0
		var op := _notice_opacity()
		if op <= 0.0:
			return
		toast["shown_s"] = float(toast["shown_s"]) + 1.0 / 72.0
		var e := _ecc(ui.hud.toast_labels())
		var vv := m.player.velocity
		var ep := _ecc(ui.hud.toast_labels(), vv.normalized()) if vv.length() > 0.5 else e
		if op >= HUD.READABLE_ALPHA and ep <= 45.0:
			toast["in_view_along_path_s"] = float(toast.get("in_view_along_path_s", 0.0)) + 1.0 / 72.0
		toast["view_angle_max"] = maxf(float(toast["view_angle_max"]), e)
		toast["view_angle_min"] = minf(float(toast["view_angle_min"]), e)
		if op >= HUD.READABLE_ALPHA:
			toast["readable_s"] = float(toast["readable_s"]) + 1.0 / 72.0
			if e <= 45.0:
				toast["in_view_s"] = float(toast["in_view_s"]) + 1.0 / 72.0
			var v := m.player.velocity
			if v.length() > 1.5 * m.player.origin.world_scale and _behind_notice(v.normalized()):
				toast["hidden_s"] = float(toast["hidden_s"]) + 1.0 / 72.0
	var _ls_sampler := LateSampler.new(sampler)
	add_child(_ls_sampler)
	var n := 0
	while SizeRules.tier_for_mass(m.player.mass) == tier0 and n < 10:
		if await _catch(&"wren"):
			n += 1
		else:
			break
	# Let the celebration play out while cruising.
	kit.set_mode(&"cruise")
	await kit.advance(8.0)
	_ls_sampler.queue_free()
	Events.player_tier_changed.disconnect(on_tier)
	for k: String in toast:
		if toast[k] is float:
			toast[k] = snappedf(float(toast[k]), 0.01)
	toast["wrens"] = n
	metric("real_tier_up", toast)
	print("[ui-verify] real tier-up: %s" % JSON.stringify(toast))
	eq(SizeRules.tier_for_mass(m.player.mass), tier0 + 1, "a real tier-up happened")
	check(String(toast["title"]).begins_with("Now a"), "the celebration named the new species (%s)" % toast["title"])
	gt(float(toast["in_view_s"]), 2.0, "the celebration was read in view for over 2 s (%.2f s)" % float(toast["in_view_s"]))
	lt(float(toast["hidden_s"]), 0.25, "the celebration never hid the flight path (%.2f s)" % float(toast["hidden_s"]))
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func _find_label_text(root: Node, needle: String) -> String:
	for n in root.find_children("*", "Label", true, false):
		var l := n as Label
		if l.is_visible_in_tree() and l.text.contains(needle):
			return l.text
	return ""


func _wait_wall(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await kit.frames(1)


func test_c_a_real_hawk_catches_you_and_you_pause_on_the_caught_screen() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ui := _ui()
	var lives0: int = kit.stats()["lives"]
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	kit.fly_straight()
	await kit.advance(1.0)
	var nc := kit.count("player_caught")
	kit.stage_strike(&"hawk", 30.0, 12.0)
	var ok := await kit.wait_until(func() -> bool: return kit.count("player_caught") > nc, 8.0)
	kit.free_staged()
	if not check(ok, "a hawk caught the player"):
		return
	await kit.frames(3)
	eq(Game.state, Game.State.CAUGHT, "CAUGHT")
	eq(ui.current_screen_id(), &"caught", "the caught screen is up")
	var cs := ui.get_screen(&"caught") as CaughtScreen
	var who := _find_label_text(cs, "by ")
	eq(who, "by a Hawk", "it names who caught you")
	var lives: int = kit.stats()["lives"]
	eq(lives, lives0 - 1, "a life lost")
	eq(cs.lives_shown(), Vector2i(lives, int(kit.stats().get("lives_max", GameLoop.MAX_LIVES))), "lives shown as pips (full, total)")
	var c0 := cs.countdown_text()
	var r0 := float(kit.stats().get("respawn_in", -1.0))
	# The countdown agrees with GameLoop's real respawn timer.
	check(c0.contains(str(int(ceil(r0)))) or c0 == "Fly!", "countdown '%s' agrees with respawn_in %.2f" % [c0, r0])
	# Pause on the caught screen: the respawn clock stops, the pause screen
	# is interactive, and Resume by pointer goes back to the caught beat.
	await _wait_wall(300)
	Events.menu_requested.emit()
	await kit.frames(3)
	eq(Game.state, Game.State.PAUSED, "the menu button pauses during CAUGHT")
	eq(ui.current_screen_id(), &"pause", "the pause screen")
	var rp := float(kit.stats().get("respawn_in", -1.0))
	await kit.frames(72)
	near(float(kit.stats().get("respawn_in", -1.0)), rp, 1e-4, "the respawn clock stands still while paused")
	check(await kit.click(&"pause", &"resume"), "the pointer hovered Resume")
	await kit.frames(3)
	check(Game.state == Game.State.CAUGHT or Game.state == Game.State.PLAYING, "resumed into the run (%s)" % Game.State.keys()[Game.state])
	if Game.state == Game.State.CAUGHT:
		eq(ui.current_screen_id(), &"caught", "the caught screen is back after Resume")
		eq(_find_label_text(cs, "by "), "by a Hawk", "still naming the hawk")
	# Countdown ticks down to the respawn, never up.
	var seen: Array[String] = []
	var prev := 999
	var monotonic := true
	var t := 0.0
	while Game.state == Game.State.CAUGHT and t < GameLoop.CAUGHT_BEAT_S + 2.0:
		var txt := cs.countdown_text()
		if seen.is_empty() or seen[-1] != txt:
			seen.append(txt)
			var digits := txt.to_int()
			if digits > 0:
				monotonic = monotonic and digits <= prev
				prev = digits
		await kit.frames(6)
		t += 6.0 / 72.0
	metric("caught_countdown_texts", seen)
	check(monotonic, "the countdown only counts down (%s)" % [seen])
	eq(Game.state, Game.State.PLAYING, "respawned")
	await kit.frames(3)
	check(ui.hud_panel.shown, "the HUD is back")
	lt(absf(rad_to_deg(ui.hud_panel.anchor_error())), 5.0, "the HUD is placed on the flight direction at the respawn (%.1f deg)" % rad_to_deg(ui.hud_panel.anchor_error()))
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_d_settings_changed_in_the_real_pause_menu_persist() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var ui := _ui()
	await _wait_wall(300)
	Events.menu_requested.emit()
	await kit.frames(3)
	eq(ui.current_screen_id(), &"pause", "paused")
	check(await kit.click(&"pause", &"settings"), "hovered Settings")
	eq(ui.current_screen_id(), &"settings", "the settings screen")
	var ss := ui.get_screen(&"settings") as SettingsScreen
	var h0 := float(Settings.get_value("haptics", 1.0))
	var bar := ss.get_bar("haptics")
	check(bar != null, "a haptics bar")
	# The bar's minus cap (its left 72 px), aimed at like any button.
	if check(bar != null, "the bar exists"):
		var r := bar.get_global_rect()
		var px := Vector2(r.position.x + SegmentBar.CAP * 0.5, r.get_center().y)
		var cam := _cam()
		var ws := kit.main.player.origin.world_scale
		var hand := cam.global_transform * (Vector3(0.22, -0.35, -0.25) * ws)
		kit.right.aim_at(hand, ui.menu_panel.pixel_to_world(px))
		await kit.frames(2)
		await _wait_wall(250)
		kit.right.trigger_value = 1.0
		await kit.frames(2)
		kit.right.trigger_value = 0.0
		await kit.frames(3)
		kit.park_hands()
	var h1 := float(Settings.get_value("haptics", 1.0))
	lt(h1, h0, "haptics lowered through the real pointer (%.2f -> %.2f)" % [h0, h1])
	var cfg := ConfigFile.new()
	cfg.load(Settings.PATH)
	near(float(cfg.get_value("settings", "haptics", -1.0)), h1, 1e-6, "persisted to disk")
	check(await kit.click(&"settings", &"back"), "Back")
	eq(ui.current_screen_id(), &"pause", "back on the pause screen")
	check(await kit.click(&"pause", &"resume"), "Resume")
	await kit.frames(3)
	eq(Game.state, Game.State.PLAYING, "playing again")
	check(ui.hud_panel.shown, "HUD back")
	eq(ui.pointer.enabled, false, "no laser while flying")
	Settings.set_value("haptics", h0)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_e_the_run_ends_and_the_summary_tells_the_truth() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ui := _ui()
	var guard := 0
	while Game.state != Game.State.ENDED and guard < 6:
		guard += 1
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		if m.game_loop.protection_left(m.player) > 0.0:
			m.game_loop.set_protection(m.player, 0.0)
		kit.fly_straight()
		await kit.advance(1.0)
		var nc := kit.count("player_caught")
		kit.stage_strike(&"hawk", 30.0, 12.0)
		var ok := await kit.wait_until(func() -> bool: return kit.count("player_caught") > nc, 8.0)
		kit.free_staged()
		if not ok:
			break
		await kit.wait_until(func() -> bool: return Game.state != Game.State.CAUGHT, GameLoop.CAUGHT_BEAT_S + 1.0)
	if not eq(Game.state, Game.State.ENDED, "the run ended"):
		return
	await kit.frames(4)
	eq(ui.current_screen_id(), &"summary", "the summary")
	var summary: Dictionary = kit.last.get("run_ended", [{}])[0]
	var ss := ui.get_screen(&"summary")
	var texts: Array[String] = []
	for n in ss.find_children("*", "Label", true, false):
		if (n as Label).is_visible_in_tree():
			texts.append((n as Label).text)
	for n in ss.find_children("*", "Button", true, false):
		if (n as Button).is_visible_in_tree():
			texts.append((n as Button).text)
	metric("summary_texts", texts)
	metric("summary_dict_keys", summary.keys())
	var joined := " | ".join(texts)
	print("[ui-verify] summary: %s" % joined)
	print("[ui-verify] summary dict: %s" % JSON.stringify(summary))
	var time_s := float(summary.get("time", summary.get("run_time", -1.0)))
	check(joined.contains(UIScreen.format_time(time_s)), "the summary shows the run's time %s" % UIScreen.format_time(time_s))
	check(joined.contains(UIScreen.format_int(int(summary.get("score", -1)))), "the summary shows the score %s" % UIScreen.format_int(int(summary.get("score", -1))))
	var by: Dictionary = summary.get("catches_by_species", {})
	for sp in by:
		var nm := UIScreen.species_name(sp)
		check(joined.contains("%s ×%d" % [nm, int(by[sp])]), "catches by species: %s ×%d" % [nm, int(by[sp])])
	check(joined.contains("Best") or joined.contains("New best"), "a best is shown")
	# Main menu from the summary by pointer, and the menu button there.
	check(await kit.click(&"summary", &"menu"), "hovered Main menu")
	await kit.frames(3)
	eq(Game.state, Game.State.MENU, "back in the menu")
	eq(ui.current_screen_id(), &"main", "the main menu")
	await _wait_wall(300)
	Events.menu_requested.emit()
	await kit.frames(3)
	eq(Game.state, Game.State.MENU, "the menu button in the menu keeps the menu")
	eq(ui.current_screen_id(), &"main", "still the main menu")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


class LateSampler:
	extends Node
	## Runs its callable at the END of every process frame (after the UI's
	## own _process has placed the panels for this frame, i.e. what is
	## rendered), unlike SceneTree.process_frame, which fires before every
	## node's _process (then the rig has moved this physics tick but the
	## panels have not, and a 7 m/s bird 0.2 m from its HUD reads 25+ deg off).
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()
