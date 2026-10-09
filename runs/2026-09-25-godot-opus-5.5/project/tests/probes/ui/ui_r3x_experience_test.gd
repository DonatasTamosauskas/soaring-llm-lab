extends TestCase
## Verifier probes (round 3, experience & requirements lens) for the ui area.
## Written by an independent verifier; does not modify any UI source.
##   tools/gd.sh ui_verify3 --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r3x_experience
## A failing check here is a finding, not a flaky test.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var _extra: Array[Node] = []


func after_each() -> void:
	for n in _extra:
		if is_instance_valid(n):
			n.queue_free()
	_extra.clear()
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	await wait_frames(2)


func _start(k: Kit, skip_lessons := true) -> void:
	k.setup(self, true)
	await k.settle(self, 3)
	if skip_lessons:
		k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 6)


func _bird(species: StringName, mass: float, pos: Vector3) -> UIStandInBird:
	var b := UIStandInBird.new(species, mass)
	add_child(b)
	b.global_position = pos
	_extra.append(b)
	return b


# --- 1. Target and threat cues must stay tellable apart ----------------------

## Angle (deg) between the two cue meshes as the eye sees them; -1 if either
## is not drawn.
func _cue_sep(k: Kit) -> float:
	var t := k.ui.indicators.cue_mesh(&"target")
	var h := k.ui.indicators.cue_mesh(&"threat")
	if not (t.visible and h.visible):
		return -1.0
	var eye := k.cam.global_position
	return rad_to_deg((t.global_position - eye).angle_to(h.global_position - eye))


func test_prey_and_pursuer_cues_stay_apart() -> void:
	# The commonest chase in the game: you chase prey off to one side while a
	# predator closes from behind. The threat cue's latched turn side then
	# points the same way as the prey cue. Chevrons are ~2.9 deg (the double
	# threat chevron ~4 deg) on the same 24-deg ring: closer than 5 deg they
	# draw on top of each other (seen in the simulator: sim_26s.png).
	var k := Kit.new()
	await _start(k)
	var eye := k.cam.global_position
	var cases := [
		["prey 90 left, hawk behind-left", Vector3(-8, 0, 0), Vector3(-2, 0.5, 9)],
		["prey 60 left, hawk behind-left", Vector3(-7, 0, -4), Vector3(-3, 1, 8)],
		["prey 90 right, hawk behind-right", Vector3(8, 0, 0), Vector3(2, 0, 9)],
		["prey 45 right and up, hawk right", Vector3(6, 3, -6), Vector3(9, 3, 1)],
		["prey left and below, hawk dead astern", Vector3(-6, -3, -2), Vector3(0.4, 0.5, 10)],
		["prey right, hawk behind-left (control)", Vector3(8, 0, 0), Vector3(-2, 0.5, 9)],
	]
	var overlapping: Array = []
	var seps := {}
	for c: Array in cases:
		var prey := _bird(&"moth", 0.004, eye + (c[1] as Vector3))
		var hawk := _bird(&"hawk", 1.3, eye + (c[2] as Vector3))
		Events.target_changed.emit(prey)
		Events.threat_changed.emit(0.9, hawk)
		var min_sep := 999.0
		var both := 0
		for i in 45:
			await wait_frames(1)
			var s := _cue_sep(k)
			if s >= 0.0:
				both += 1
				min_sep = minf(min_sep, s)
		seps[c[0]] = snappedf(min_sep, 0.1) if both > 0 else -1.0
		if both > 0 and min_sep < 5.0:
			overlapping.append("%s: %.1f deg" % [c[0], min_sep])
		Events.target_changed.emit(null)
		Events.threat_changed.emit(0.0, null)
		prey.queue_free()
		hawk.queue_free()
		await wait_frames(20)
	metric("cue_separation_deg", seps)
	print("[ui-verify] cue separation (deg) per geometry: ", seps)
	eq(overlapping.size(), 0, "target and threat cues never drawn on top of each other (< 5 deg apart): %s" % str(overlapping))
	k.teardown()
	await wait_frames(2)


# --- 2. Is the tier-up celebration actually seen? ---------------------------

## What the player sees of the celebration: its fade times its band's opacity.
func _toast_opacity(k: Kit) -> float:
	var toast := k.ui.hud.get_node_or_null("TierUp") as Control
	if toast == null or not toast.visible or not k.ui.hud_panel.is_band_visible(HUD.BAND_NOTICE):
		return 0.0
	return toast.modulate.a * k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE)


func _watch_toast(k: Kit) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var n := 0
	var readable := 0
	var peak := 0.0
	while Time.get_ticks_msec() - t0 < int(HUD.TOAST_TIME * 1000.0) + 100:
		await wait_frames(1)
		var o := _toast_opacity(k)
		n += 1
		# >= 0.6 of full opacity: plainly readable over the sky.
		if o >= 0.6:
			readable += 1
		peak = maxf(peak, o)
	return {"readable_frac": snappedf(readable / float(maxi(n, 1)), 0.01), "peak": snappedf(peak, 0.01), "frames": n}


func test_tier_up_celebration_is_seen_in_ordinary_flight() -> void:
	# A tier-up is "a celebrated moment" (DESIGN, game loop). Catching a moth
	# or a wren means flapping UP to it (swallow-style hawking): at the catch
	# the flight path is above the horizon, which is where the notice band
	# sits, so the band fades to 15 %. How much of the celebration survives?
	var k := Kit.new()
	await _start(k)
	var cruise := SizeRules.cruise_speed(0.055)
	var climb_max := rad_to_deg(atan(SizeRules.performance(0.055)["climb"] / cruise))
	metric("swallow_hard_climb_path_deg", snappedf(climb_max, 0.1))
	var cases := [
		["level", 0.0, Vector3.ZERO],
		["climb 8 deg", 8.0, Vector3.ZERO],
		["climb 14 deg", 14.0, Vector3.ZERO],
		["climb 20 deg", 20.0, Vector3.ZERO],
		["level, next prey ahead 12 deg up", 0.0, Vector3(1.0, 3.2, -15.0)],
	]
	var results := {}
	var lost: Array = []
	var tier := 2
	for c: Array in cases:
		var a := deg_to_rad(float(c[1]))
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		var off: Vector3 = c[2]
		if off != Vector3.ZERO:
			Events.target_changed.emit(_bird(&"wren", 0.012, k.cam.global_position + off))
		await wait_frames(30)
		# Grow into the next species and announce it the way GameLoop does.
		k.player.mass = float(SizeRules.SPECIES[tier + 1]["mass"]) * 1.02
		Events.player_tier_changed.emit(tier, tier + 1)
		var r := await _watch_toast(k)
		results[c[0]] = r
		if float(r["readable_frac"]) < 0.4:
			lost.append("%s: readable %d%% of the toast, peak opacity %.2f" % [c[0], int(float(r["readable_frac"]) * 100.0), float(r["peak"])])
		tier = 2 if tier >= 7 else tier + 1
		k.player.mass = float(SizeRules.SPECIES[tier]["mass"]) * 1.02
		Events.target_changed.emit(null)
		await wait_frames(40)
	metric("toast_visibility", results)
	print("[ui-verify] tier-up toast visibility: ", results)
	eq(lost.size(), 0, "a tier-up celebration is readable for at least 40%% of its %.1f s in ordinary flight: %s" % [HUD.TOAST_TIME, str(lost)])
	k.teardown()
	await wait_frames(2)


func test_apex_catch_celebration_is_seen_when_the_next_prey_is_ahead() -> void:
	# As the eagle every worthwhile catch gets a "2 of 5!" toast. Right after a
	# catch GameLoop names the next target; if it is a gull ahead and a little
	# above (the sky above the horizon is where big birds soar), the notice
	# band makes way for it for the whole celebration.
	var k := Kit.new()
	await _start(k)
	k.player.mass = 3.1
	k.player.velocity = Vector3(0, 0, -1) * SizeRules.cruise_speed(3.1)
	k.gl.stats["apex"]["reached"] = true
	await wait_frames(10)
	var gull := _bird(&"gull", 0.85, k.cam.global_position + Vector3(-2.0, 6.0, -30.0))
	Events.target_changed.emit(gull)
	await wait_frames(20)
	k.gl.fake_apex_catch()
	var r := await _watch_toast(k)
	metric("apex_toast_with_gull_ahead_up", r)
	print("[ui-verify] apex toast with the next prey 11 deg up ahead: ", r)
	gt(float(r["readable_frac"]), 0.4, "the '1 of 5!' celebration is readable for >= 40%% of its time (got %s)" % str(r))
	k.teardown()
	await wait_frames(2)


# --- 3. Transient texts are legible and fit ---------------------------------

func _cap_deg(panel: UIPanel, eye: Vector3, l: Label) -> Dictionary:
	var font := l.get_theme_font("font")
	var fs := l.get_theme_font_size("font_size")
	var cap := UITheme.cap_height_px(font, fs)
	var r := l.get_global_rect()
	var w := font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base := r.position.y + (r.size.y + font.get_ascent(fs) - font.get_descent(fs)) * 0.5
	var out := 999.0
	for x: float in [r.position.x, r.position.x + minf(w, r.size.x)]:
		var a := panel.pixel_to_world(Vector2(x, base - cap)) - eye
		var b := panel.pixel_to_world(Vector2(x, base)) - eye
		out = minf(out, rad_to_deg(a.angle_to(b)))
	return {"deg": out, "text_w": w, "rect_w": r.size.x, "fs": fs}


func test_settings_status_messages_fit_and_are_legible() -> void:
	# The only feedback for Recalibrate / Recenter / Replay tutorial is a
	# status line beside "Replay tutorial". Is each message legible (1.5 deg)
	# and does it fit its space?
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.push_screen(&"settings")
	await k.settle(self, 4)
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 2)
	var st := k.ui.get_screen(&"settings") as SettingsScreen
	var status := st.find_child("Status", true, false) as Label
	check(status != null, "settings has a status label")
	var bad: Array = []
	var seen := {}
	for action: StringName in [&"recalibrate", &"recenter", &"replay_tutorial"]:
		k.ui._on_action(action, &"settings")
		await k.settle(self, 4)
		var m := _cap_deg(k.ui.menu_panel, k.cam.global_position, status)
		seen[status.text] = {"deg": snappedf(float(m["deg"]), 0.001), "text_w": int(m["text_w"]), "rect_w": int(m["rect_w"])}
		if float(m["deg"]) < UITheme.MIN_GLYPH_DEG:
			bad.append("'%s' %.3f deg" % [status.text, float(m["deg"])])
		if float(m["text_w"]) > float(m["rect_w"]) + 1.0:
			bad.append("'%s' is %d px wide in a %d px slot" % [status.text, int(m["text_w"]), int(m["rect_w"])])
		if not status.is_visible_in_tree():
			bad.append("'%s' not visible" % status.text)
		# Content margin of every screen: 60 px each side.
		var right_edge := status.get_global_rect().position.x + float(m["text_w"])
		seen[status.text]["right_edge_px"] = int(right_edge)
		if right_edge > UITheme.MENU_SIZE.x - 60.0 + 1.0:
			bad.append("'%s' runs to x=%d, past the %d px content edge" % [status.text, int(right_edge), UITheme.MENU_SIZE.x - 60])
		# ...and the rest of the screen must not be pushed off the panel.
		var pushed: Array = []
		for c in st.find_children("*", "Control", true, false):
			var cc := c as Control
			if cc.is_visible_in_tree() and cc != status and cc.get_global_rect().end.x > UITheme.MENU_SIZE.x - 60.0 + 1.0 and (cc is Button or cc is Label):
				pushed.append("%s->%d" % [cc.name, int(cc.get_global_rect().end.x)])
		if not pushed.is_empty():
			bad.append("'%s' pushes %d controls past the content edge: %s" % [status.text, pushed.size(), str(pushed.slice(0, 5))])
	metric("settings_status", seen)
	print("[ui-verify] settings status lines: ", seen)
	eq(bad.size(), 0, "every settings status message is legible and fits: %s" % str(bad))
	k.teardown()
	await wait_frames(2)


# --- 4. The tutorial says the same thing as the food chain --------------------

func test_catch_lesson_agrees_with_the_food_chain() -> void:
	# Lesson 7 is titled "Catch a moth". The pause screen and tier-up toasts
	# tell a swallow and up to IGNORE moths (not worth chasing). How many
	# catches before the tutorial reaches lesson 7 does it take a sparrow to
	# become a swallow, and does the lesson then contradict the Hunt line?
	var title: String = Onboarding.LESSONS[Onboarding.LESSONS.size() - 1]["title"]
	var contradicted := []
	for sp in range(2, 5):
		var m: float = float(SizeRules.SPECIES[sp]["mass"]) * 1.01
		var chain := PauseScreen.food_chain(m)
		if title.to_lower().contains("moth") and not (0 in (chain["prey"] as Array)):
			contradicted.append("%s ('%s', '%s')" % [SizeRules.SPECIES[sp]["name"], chain["eat_line"], chain["ignore_line"]])
	# Wren catches a sparrow needs to become a swallow.
	var mass := float(SizeRules.SPECIES[2]["mass"])
	var wrens := 0
	while mass < float(SizeRules.SPECIES[3]["mass"]) and wrens < 50:
		mass += SizeRules.meal_gain(mass, float(SizeRules.SPECIES[1]["mass"]))
		wrens += 1
	metric("wren_catches_sparrow_to_swallow", wrens)
	metric("catch_lesson_contradicted_at", contradicted)
	print("[ui-verify] '%s' contradicts the Hunt/Ignore lines at: %s (sparrow->swallow = %d wrens)" % [title, contradicted, wrens])
	eq(contradicted.size(), 0, "the catch lesson never tells the player to catch a species the HUD calls 'Ignore' (%s)" % str(contradicted))


# --- 5. Random state walk: every invariant of U3 / U7 in every state ---------

func test_random_flow_walk_keeps_every_invariant() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	var hawk := _bird(&"hawk", 1.3, Vector3(3, 3, 8))
	var prey := _bird(&"moth", 0.004, Vector3(-6, 1.6, -3))
	var roots := {Game.State.MENU: &"main", Game.State.PLAYING: &"", Game.State.PAUSED: &"pause",
		Game.State.CAUGHT: &"caught", Game.State.ENDED: &"summary"}
	var violations: Array = []
	var visits := {}
	var tier := 2
	var max_vp := 0
	for step in 360:
		var st := Game.state
		match rng.randi_range(0, 12):
			0, 1:
				k.ui._last_menu_ms = -100000
				Events.menu_requested.emit()
			2:
				if st == Game.State.PLAYING:
					k.gl.fake_caught(hawk)
			3:
				if st == Game.State.CAUGHT:
					# GameLoop's respawn: the size penalty (a tier change, still
					# in CAUGHT), then PLAYING in the same call.
					var down := maxi(tier - 1, 0)
					if down != tier and rng.randf() < 0.5:
						k.player.mass = float(SizeRules.SPECIES[down]["mass"]) * 1.02
						Events.player_tier_changed.emit(tier, down)
						tier = down
					Game.set_state(Game.State.PLAYING)
			4:
				if st == Game.State.PLAYING or st == Game.State.CAUGHT:
					k.gl.fake_end({"score": rng.randi_range(0, 9000)})
			5:
				if st == Game.State.MENU or st == Game.State.ENDED:
					k.gl.start_run()
			6:
				# Catches (and so tier-ups) only happen in play.
				if st == Game.State.PLAYING and tier < 9:
					var nt := tier + 1
					k.player.mass = float(SizeRules.SPECIES[nt]["mass"]) * 1.02
					Events.player_tier_changed.emit(tier, nt)
					tier = nt
			7:
				Events.target_changed.emit(prey if rng.randf() < 0.7 else null)
			8:
				Events.threat_changed.emit(rng.randf(), hawk)
			9:
				if st == Game.State.PAUSED:
					k.ui.resume()
			10:
				if k.ui.current_screen_id() == &"main" or k.ui.current_screen_id() == &"pause":
					k.ui._on_action(&"settings" if rng.randf() < 0.5 else &"howto", k.ui.current_screen_id())
			11:
				k.ui.pop_screen()
			12:
				if st == Game.State.PLAYING and rng.randf() < 0.5:
					k.gl.fake_apex_catch()
		await wait_frames(2)
		st = Game.state
		visits[Game.state_name()] = int(visits.get(Game.state_name(), 0)) + 1
		var root: StringName = k.ui.stack[0] if not k.ui.stack.is_empty() else &""
		if roots.has(st) and root != roots[st]:
			violations.append("step %d %s: root screen '%s' (want '%s')" % [step, Game.state_name(), root, roots[st]])
		if k.ui.hud_panel.shown != (st == Game.State.PLAYING):
			violations.append("step %d %s: hud shown=%s" % [step, Game.state_name(), k.ui.hud_panel.shown])
		if k.ui.menu_panel.shown == k.ui.stack.is_empty():
			violations.append("step %d %s: menu shown=%s with stack %s" % [step, Game.state_name(), k.ui.menu_panel.shown, k.ui.stack])
		var s := k.ui.current_screen()
		var want_ptr := s != null and s.interactive
		if k.ui.pointer.enabled != want_ptr:
			violations.append("step %d %s: pointer enabled=%s on '%s'" % [step, Game.state_name(), k.ui.pointer.enabled, k.ui.current_screen_id()])
		if st != Game.State.PLAYING:
			if k.ui.indicators.cue_mesh(&"target").visible or k.ui.indicators.cue_mesh(&"threat").visible:
				violations.append("step %d %s: a cue is drawn outside play" % [step, Game.state_name()])
			if k.ui.hud.toast_active():
				violations.append("step %d %s: a celebration is running outside play" % [step, Game.state_name()])
		if get_tree().paused != (st == Game.State.PAUSED):
			violations.append("step %d %s: tree paused=%s" % [step, Game.state_name(), get_tree().paused])
		var visible_screens := 0
		for id in k.ui.screens:
			if (k.ui.screens[id] as UIScreen).visible:
				visible_screens += 1
		if visible_screens != (0 if k.ui.stack.is_empty() else 1):
			violations.append("step %d %s: %d screens visible" % [step, Game.state_name(), visible_screens])
		max_vp = maxi(max_vp, k.ui.active_viewport_count())
		if violations.size() > 12:
			break
	metric("walk_state_visits", visits)
	metric("walk_max_active_viewports", max_vp)
	print("[ui-verify] random walk visits: ", visits, " violations: ", violations.size())
	for v in violations:
		print("[ui-verify]   ", v)
	eq(violations.size(), 0, "no invariant broken in a 360-step random walk: %s" % str(violations.slice(0, 6)))
	check(max_vp <= 2, "at most 2 SubViewports render in any frame (max %d)" % max_vp)
	check(visits.size() >= 5, "the walk visited every state (%s)" % str(visits.keys()))
	k.teardown()
	await wait_frames(2)


# --- 6. Opening a menu with the head turned far / tilted; odd scales ---------

func test_menu_opens_in_front_of_a_turned_tilted_head_at_any_scale() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	var ref := Vector2.ZERO
	var bad: Array = []
	var sizes := {}
	for ws: float in [0.15, 0.4, 1.0, 1.3]:
		for pose: Array in [[150.0, -30.0, 1.1], [-100.0, 25.0, 1.75], [0.0, 0.0, 1.6]]:
			k.gl.start_run()
			await k.settle(self, 3)
			k.set_world_scale(ws)
			k.set_head(Vector3(0.3, float(pose[2]), -0.2), float(pose[0]), float(pose[1]))
			await k.settle(self, 3)
			k.ui._last_menu_ms = -100000
			Events.menu_requested.emit()
			await k.settle(self, 3)
			var p := k.ui.menu_panel
			var eye := k.cam.global_position
			var h := Vector2(UITheme.MENU_SIZE) * 0.5
			var c := p.pixel_to_world(h) - eye
			var yaw_c := rad_to_deg(atan2(-c.x, -c.z))
			var yaw_err := absf(wrapf(yaw_c - float(pose[0]), -180.0, 180.0))
			var w := rad_to_deg((p.pixel_to_world(Vector2(0, h.y)) - eye).angle_to(p.pixel_to_world(Vector2(UITheme.MENU_SIZE.x, h.y)) - eye))
			var hh := rad_to_deg((p.pixel_to_world(Vector2(h.x, 0)) - eye).angle_to(p.pixel_to_world(Vector2(h.x, UITheme.MENU_SIZE.y)) - eye))
			var key := "ws%.2f yaw%d pitch%d eye%.2f" % [ws, int(pose[0]), int(pose[1]), float(pose[2])]
			sizes[key] = [snappedf(w, 0.01), snappedf(hh, 0.01), snappedf(yaw_err, 0.1)]
			if ref == Vector2.ZERO:
				ref = Vector2(w, hh)
			if yaw_err > 3.0:
				bad.append("%s: menu centre %.1f deg off the head's yaw" % [key, yaw_err])
			if absf(w - ref.x) > 0.3 or absf(hh - ref.y) > 0.3:
				bad.append("%s: %.2f x %.2f deg (ref %.2f x %.2f)" % [key, w, hh, ref.x, ref.y])
			k.ui.resume()
			await k.settle(self, 2)
			k.set_world_scale(1.0)
			k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	metric("menu_open_geometry", sizes)
	print("[ui-verify] menu geometry on open: ", sizes)
	eq(bad.size(), 0, "the pause menu opens straight ahead at a constant size for any head pose and scale: %s" % str(bad))
	k.teardown()
	await wait_frames(2)


func test_lesson_card_feedback_is_seen_while_doing_the_flap_lesson() -> void:
	# Lesson 2 is "Flap to climb": doing it points the flight path above the
	# horizon, i.e. at the lesson card. Its progress bar and "Nice!" are the
	# only feedback that the gesture works. How much of it is readable?
	var k := Kit.new()
	await _start(k, false)
	k.ui.onboarding.skip()
	k.ui.onboarding.reset()
	k.ui.onboarding.start()
	await k.settle(self, 3)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	var cruise := SizeRules.cruise_speed(0.03)
	var results := {}
	for deg: float in [0.0, 6.0, 12.0, 18.0]:
		var a := deg_to_rad(deg)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		await wait_frames(20)
		var n := 0
		var readable := 0
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 1500:
			await wait_frames(1)
			n += 1
			if k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE) >= 0.6:
				readable += 1
		results["climb %d deg" % int(deg)] = snappedf(readable / float(maxi(n, 1)), 0.01)
	metric("lesson_card_readable_frac_by_climb", results)
	print("[ui-verify] lesson card readable fraction while climbing: ", results)
	gt(float(results["climb 12 deg"]), 0.4, "the lesson card stays readable while the player does 'Flap to climb' at 12 deg (%s)" % str(results))
	k.teardown()
	await wait_frames(2)


func test_respawn_size_penalty_is_shown_then_the_hud_goes_idle() -> void:
	# GameLoop's respawn: the size penalty emits player_tier_changed (down)
	# while still CAUGHT (HUD hidden), then PLAYING in the same call. The
	# "Back to a ..." notice must then be seen in flight, and once it ends the
	# HUD must stop rendering (U7: only while visible/dirty).
	var k := Kit.new()
	await _start(k)
	k.player.mass = float(SizeRules.SPECIES[4]["mass"]) * 1.02
	await k.settle(self, 10)
	k.gl.fake_caught(null)
	await k.settle(self, 20)
	k.player.mass = float(SizeRules.SPECIES[3]["mass"]) * 1.02
	k.player.velocity = Vector3.ZERO
	Events.player_tier_changed.emit(4, 3)
	Game.set_state(Game.State.PLAYING)
	var r := await _watch_toast(k)
	metric("respawn_tier_down_toast", r)
	gt(float(r["readable_frac"]), 0.4, "the size-penalty notice is readable after respawn (%s)" % str(r))
	eq(k.ui.hud.toast_text(), "Back to a Swallow", "it says what the player shrank to")
	await k.settle(self, 20)
	var renders := 0
	var n := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1000:
		await wait_frames(1)
		n += 1
		if k.ui.hud_panel.is_rendering_enabled():
			renders += 1
	metric("idle_hud_renders_after_respawn_toast", [renders, n])
	lt(float(renders), 0.1 * n, "the HUD is idle once the notice is over (%d of %d frames rendered)" % [renders, n])
	k.teardown()
	await wait_frames(2)
