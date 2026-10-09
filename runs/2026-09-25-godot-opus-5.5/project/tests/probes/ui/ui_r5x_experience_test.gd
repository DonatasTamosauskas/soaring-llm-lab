extends TestCase
## Verifier probes (round 5, experience & requirements lens) for the ui area.
## Written by an independent verifier; modifies no UI source.
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r5x_experience
## A failing check here is a finding, not a flaky test.
##
## Round 4 put the HUD notices at a fixed home "10-52 deg right of the HUD's
## centre line", on the premise that the flight path runs along that centre
## line. But the HUD panel's centre line is the *head's* yaw at the moment
## the HUD is shown (UIPanel.show_panel -> snap_to_head), and it only follows
## the head past a 55 deg dead zone. Every round-4 test places the head at
## yaw 0, on the flight path, when the HUD appears. These probes vary that
## one thing a player varies all the time (where they look when they click
## Play / Resume, or at the moment of a tier-up), then look along the flight
## path, and measure where the lesson text actually is *in the player's
## view* (not just its opacity).

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0
## Where a Quest Pro's binocular view ends (~106 deg wide) minus a little
## for the blurry lens edge: text beyond this eccentricity is not readable
## without turning the head.
const VIEW_EDGE_DEG := 45.0

var _extra: Array[Node] = []


func after_each() -> void:
	for n in _extra:
		if is_instance_valid(n):
			n.queue_free()
	_extra.clear()
	await wait_frames(2)


## Synthetic time, like ui_hud_test: the UI's own frame work is driven by
## _frame() so seconds of flight replay in milliseconds.
func _synthetic(k: Kit) -> void:
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)


func _frame(k: Kit, dt: float = SDT) -> void:
	k.ui.hud_panel.follow(dt)
	k.ui.indicators.step(dt)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), dt)
	k.ui.hud.advance(dt)


## Azimuth (deg, + = right) of a world point from the eye, relative to the
## rig's forward (-Z) = the flight path in these probes.
func _az(k: Kit, p: Vector3) -> float:
	var d := p - k.cam.global_position
	return rad_to_deg(atan2(d.x, -d.z))


## [min, max] azimuth of the lesson card's *text* (step, title, hint: the
## glyphs, not the label boxes), relative to the flight path.
func _text_span(k: Kit) -> Vector2:
	var hud := k.ui.hud
	var mn := INF
	var mx := -INF
	for lbl: Label in [hud._step, hud._title, hud._hint]:
		if lbl == null or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var fs := lbl.get_theme_font_size(&"font_size")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			x0 = r.end.x - w
		elif lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w]:
			var a := _az(k, k.ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)))
			mn = minf(mn, a)
			mx = maxf(mx, a)
	return Vector2(mn, mx)


func _plate_az(k: Kit, c: Control) -> float:
	return _az(k, k.ui.hud_panel.control_to_world(c))


## The flight the tutorial asks for ("Flap to climb", then "Glide") on the
## real FlightModel (sparrow, wrists neutral): bursts of `strokes` strokes at
## 1 Hz, then `glide_s` gliding. [t, gamma_deg, speed] at 72 Hz. Same recipe
## as ui_hud_test._tutorial_series.
static func _tutorial_series(strokes: int, glide_s: float, seconds: float) -> Array:
	var m := FlightModel.new(FlightParams.species_mass(&"sparrow"), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var out: Array = []
	var cycle := float(strokes) + glide_s
	for i in int(seconds / SDT):
		var t := i * SDT
		var ph := fmod(t, cycle)
		if ph < float(strokes):
			ws.set_commands(0.0, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, SDT)
		var v := m.velocity
		out.append([t, rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())), v.length()])
	return out


## Is the flight path behind the readable lesson card (inside its plate on
## the notice band, or within 1 deg of it)?
func _path_hidden(k: Kit, dir: Vector3) -> bool:
	var hud := k.ui.hud
	if not hud.lesson_visible() or hud.notice_alpha() < HUD.READABLE_ALPHA:
		return false
	var px := k.ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, dir)
	if not (is_finite(px.x) and is_finite(px.y)):
		return false
	var margin := deg_to_rad(1.0) * UITheme.HUD_DISTANCE * UITheme.PX_PER_M
	return hud._card.get_global_rect().grow(margin).has_point(px)


## Enter PLAYING with lessons on while the head looks off the flight path
## (the HUD snaps to it), then look along the flight path and fly `profile`
## ([t, gamma_deg, speed]; empty = level at 8 m/s) for `seconds`.
##   how = "set":    head at `amount` deg (+ = right), then start the run;
##   how = "resume": fly, pause, point at Resume with the head turned
##                   `amount` (fraction) of the way to it, pull;
##   how = "play":   on the main menu, point at Play likewise, pull.
func _enter_playing(how: String, amount: float, seconds: float, profile: Array = []) -> Dictionary:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.reset()
	k.player.velocity = Vector3(0.0, 0.0, -8.0)
	var head_at_show := amount
	if how == "resume" or how == "play":
		var btn: Button
		if how == "resume":
			k.gl.start_run()
			await k.settle(self, 4)
			Events.menu_requested.emit()
			await k.settle(self, 6)
			btn = k.ui.get_screen(&"pause").get_button(&"resume")
		else:
			await k.settle(self, 4)
			btn = k.ui.get_screen(&"main").get_button(&"play")
		head_at_show = _az(k, k.ui.menu_panel.control_to_world(btn)) * amount
		k.set_head(Vector3(0, Kit.EYE, 0), -head_at_show)
		k.aim_at_control(k.right, btn)
		await k.click(self, k.right)
		await k.settle(self, 2)
	else:
		k.set_head(Vector3(0, Kit.EYE, 0), -amount)   # kit yaw: + = left
		k.gl.start_run()
		await k.settle(self, 4)
	var out := {"head_at_show_deg": snappedf(head_at_show, 0.1), "playing": Game.state == Game.State.PLAYING,
		"lesson": k.ui.hud.lesson_title()}
	_synthetic(k)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	var moves0 := k.ui.hud.move_count
	var faded_s := 0.0
	var fades := 0
	var was_faded := false
	var hidden_s := 0.0
	var first_move_at := -1.0
	var gam := Vector2(INF, -INF)
	var t := 0.0
	var i := 0
	while t < seconds:
		if not profile.is_empty():
			var row: Array = profile[mini(i, profile.size() - 1)]
			var a := deg_to_rad(float(row[1]))
			gam = Vector2(minf(gam.x, row[1]), maxf(gam.y, row[1]))
			k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * float(row[2])
		_frame(k)
		t += SDT
		i += 1
		var faded := k.ui.hud.notice_alpha() < HUD.READABLE_ALPHA
		if faded:
			faded_s += SDT
			if not was_faded:
				fades += 1
		was_faded = faded
		if _path_hidden(k, k.player.velocity.normalized()):
			hidden_s += SDT
		if first_move_at < 0.0 and k.ui.hud.move_count > moves0:
			first_move_at = t
	var span := _text_span(k)
	out["lesson_visible"] = k.ui.hud.lesson_visible()
	out["text_az_deg"] = [snappedf(span.x, 0.1), snappedf(span.y, 0.1)]
	out["text_max_eccentricity_deg"] = snappedf(maxf(absf(span.x), absf(span.y)), 0.1)
	out["moves"] = k.ui.hud.move_count - moves0
	out["first_move_after_s"] = snappedf(first_move_at, 0.01)
	out["fades"] = fades
	out["faded_s"] = snappedf(faded_s, 0.01)
	out["path_hidden_s"] = snappedf(hidden_s, 0.01)
	out["notice_side"] = k.ui.hud.notice_side
	out["flight_path_elev_range_deg"] = [snappedf(gam.x, 0.1), snappedf(gam.y, 0.1)] if not profile.is_empty() else [0.0, 0.0]
	out["strip_centre_az_deg"] = snappedf(_plate_az(k, k.ui.hud._strip), 0.1)
	out["hud_yaw_error_deg"] = snappedf(rad_to_deg(k.ui.hud_panel.yaw_error()), 0.1)
	k.teardown()
	await wait_frames(2)
	return out


func test_lesson_text_is_in_view_whatever_the_head_did_when_the_hud_appeared() -> void:
	# Control: head on the flight path when the HUD appears (every round-4
	# test). Then +-15..30 deg: glancing at a button, at prey, at the view.
	var results := {}
	var bad: Array = []
	for yaw: float in [0.0, 15.0, -15.0, 25.0, -30.0]:
		var r := await _enter_playing("set", yaw, 6.0)
		results["head %+.0f deg at show" % yaw] = r
		if not bool(r["lesson_visible"]):
			bad.append("head %+.0f: no lesson card" % yaw)
			continue
		if float(r["text_max_eccentricity_deg"]) > VIEW_EDGE_DEG:
			bad.append("head %+.0f at show: lesson text spans %s deg from the flight path the player is looking along (beyond %.0f deg: outside a Quest Pro's readable view)" % [yaw, str(r["text_az_deg"]), VIEW_EDGE_DEG])
		if int(r["moves"]) > 0:
			bad.append("head %+.0f at show: the card jumped sides %.2f s after the HUD appeared" % [yaw, r["first_move_after_s"]])
		if absf(float(r["strip_centre_az_deg"])) > 15.0:
			bad.append("head %+.0f at show: growth strip centred %.1f deg off the flight path" % [yaw, r["strip_centre_az_deg"]])
	metric("hud_home_vs_head_at_show", results)
	eq(bad, [], "the notices sit beside the flight path whatever the head did at show time")


func test_resume_or_play_by_pointer_then_the_tutorial_flight() -> void:
	# The commonest ways into PLAYING mid-tutorial: pause and point at Resume
	# (left column), or point at Play on the main menu (right column); pull;
	# look ahead and do what the lesson says (the tutorial's flap-and-glide on
	# the real FlightModel). Heads turn part of the way to what the eyes aim
	# at: 0.6 and 1.0 of it. Control: head on the flight path ("set" 0).
	var profile := _tutorial_series(2, 2.0, 30.0)
	var results := {}
	var bad: Array = []
	for c: Array in [["set", 0.0], ["resume", 0.6], ["resume", 1.0], ["play", 0.6], ["play", 1.0]]:
		var r := await _enter_playing(c[0], c[1], 30.0, profile)
		var key := "%s %s" % [c[0], ("head %.0f deg" % c[1]) if c[0] == "set" else ("head %.0f%% of the way" % (float(c[1]) * 100.0))]
		results[key] = r
		if not bool(r["playing"]):
			bad.append("%s: not playing" % key)
			continue
		if int(r["moves"]) > 0 or int(r["fades"]) > 0:
			bad.append("%s (head %.1f deg at show): %d fades, %d move(s), first %.2f s after the HUD appeared; the card ends on side %d with its text at %s deg" % [key, r["head_at_show_deg"], r["fades"], r["moves"], r["first_move_after_s"], r["notice_side"], str(r["text_az_deg"])])
		elif float(r["text_max_eccentricity_deg"]) > VIEW_EDGE_DEG:
			bad.append("%s: lesson text at %s deg" % [key, str(r["text_az_deg"])])
		if float(r["path_hidden_s"]) > 0.0:
			bad.append("%s: flight path behind the readable card for %.2f s" % [key, r["path_hidden_s"]])
	metric("enter_playing_by_pointer_then_tutorial_flight", results)
	eq(bad, [], "entering play by pointer keeps the notices calm (no fades/moves) and in view during the tutorial's flight, as they are with the head on the path")


func test_tier_up_celebration_is_in_view_when_it_happens() -> void:
	# A tier-up comes right after a catch; the player may be looking at the
	# next bird. HUD placed on the flight path; the head then looks g deg
	# off it (inside the 55 deg dead zone, so the HUD stays). How long is
	# the celebration plate readable (alpha >= 0.6) AND within the view?
	var results := {}
	var bad: Array = []
	for g: float in [0.0, -25.0, -40.0, 30.0]:
		var k := Kit.new()
		k.setup(self, true)
		await k.settle(self, 3)
		k.ui.onboarding.skip()
		k.player.velocity = Vector3(0.0, 0.0, -8.0)
		k.gl.start_run()
		await k.settle(self, 4)
		_synthetic(k)
		k.set_head(Vector3(0, Kit.EYE, 0), -g)
		for i in 10:
			_frame(k)
		k.player.mass = float(SizeRules.SPECIES[3]["mass"]) * 1.02
		Events.player_tier_changed.emit(2, 3)
		await wait_frames(1)
		k.ui.hud.set_process(false)
		var seen := 0.0
		var up := 0.0
		var plate_rel := 0.0
		while k.ui.hud.toast_active() and up < 10.0:
			_frame(k)
			up += SDT
			plate_rel = _plate_az(k, k.ui.hud._toast_plate) - g
			if k.ui.hud.notice_alpha() >= HUD.READABLE_ALPHA and absf(plate_rel) <= VIEW_EDGE_DEG:
				seen += SDT
		var r := {"gaze_deg": g, "toast_lasted_s": snappedf(up, 0.01), "seen_s": snappedf(seen, 0.01),
			"plate_centre_from_gaze_deg": snappedf(plate_rel, 0.1), "hud_yaw_error_deg": snappedf(rad_to_deg(k.ui.hud_panel.yaw_error()), 0.1)}
		results["gaze %+.0f" % g] = r
		if seen < 1.5:
			bad.append("gaze %+.0f deg: celebration in view for %.2f s of %.2f s (plate %.0f deg from gaze)" % [g, seen, up, plate_rel])
		k.teardown()
		await wait_frames(2)
	metric("tier_up_in_view", results)
	eq(bad, [], "a tier-up celebration is in view for >= 1.5 s wherever the player looks inside the HUD's dead zone")


# --- onboarding --------------------------------------------------------------

## Fly the real FlightModel gliding from trim with a symmetric wing pitch
## command pitch(t) and feed an Onboarding on "Tilt for speed" the keys
## PlayerBird reports (as ui_onboarding_test does).
func _fly_tilt(species: StringName, pitch_fn: Callable, seconds: float) -> Dictionary:
	var m := FlightModel.new(FlightParams.species_mass(species), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var own := "user://ui_r5x_speed_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new(own)
	add_child(o)
	o.start()
	while o.index < Onboarding.LESSONS.size() and Onboarding.LESSONS[o.index]["id"] != &"speed":
		o._begin(o.index + 1)
	var done_at := -1.0
	var v0 := m.airspeed()
	var v_max := v0
	var dt := 1.0 / 72.0
	for i in int(seconds / dt):
		var t := i * dt
		var p: float = pitch_fn.call(t)
		ws.set_commands(p, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, dt)
		var tl := m.telemetry()
		tl["flapping"] = 0.0
		tl["wing_extension"] = 1.0
		tl["tucked"] = false
		tl["perched"] = false
		tl["pitch_input"] = ws.pitch
		v_max = maxf(v_max, m.airspeed())
		o.step(dt, tl)
		if done_at < 0.0 and (o.celebrating > 0.0 or o.index > 3):
			done_at = t
			break
	var prog := o.progress
	o.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	return {"completed_after_s": snappedf(done_at, 0.01), "progress": snappedf(prog, 0.01),
		"airspeed_gain": snappedf(v_max - v0, 0.01)}


func test_speed_lesson_accepts_a_gentle_or_shaky_real_tilt() -> void:
	# A first-time player twists "a bit" and their wrists tremble. The hint
	# says "Twist both wrists down"; any honest tilt past the 0.15 dead band
	# should register within a few seconds of gliding.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var noise: Array[float] = []
	var ph := 0.0
	for i in 72 * 20:
		# band-limited tremor (a slow wander + a 4 Hz wobble)
		ph += 1.0 / 72.0
		noise.append(0.05 * sin(TAU * 4.0 * ph + 0.7) + 0.03 * sin(TAU * 0.6 * ph) + rng.randf_range(-0.02, 0.02))
	var cases := {
		"sparrow steady -0.20": func(_t: float) -> float: return -0.20,
		"sparrow steady -0.25": func(_t: float) -> float: return -0.25,
		"sparrow -0.25 with tremor +-0.1": func(t: float) -> float: return -0.25 + noise[mini(int(t * 72.0), noise.size() - 1)],
		"sparrow -0.35 with tremor +-0.1": func(t: float) -> float: return -0.35 + noise[mini(int(t * 72.0), noise.size() - 1)],
		"sparrow balloon +0.25": func(_t: float) -> float: return 0.25,
		"sparrow balloon +0.30 with tremor": func(t: float) -> float: return 0.30 + noise[mini(int(t * 72.0), noise.size() - 1)],
	}
	var results := {}
	var bad: Array = []
	for key: String in cases:
		var r := _fly_tilt(&"sparrow", cases[key], 15.0)
		results[key] = r
		if float(r["completed_after_s"]) < 0.0 or float(r["completed_after_s"]) > 6.0:
			bad.append("%s: %s" % [key, str(r)])
	metric("speed_lesson_gentle_tilts", results)
	eq(bad, [], "a gentle or trembling real tilt completes 'Tilt for speed' within 6 s")


func test_a_timed_out_lesson_is_not_recorded_as_learned() -> void:
	# "Lessons progress on doing, not reading" (DESIGN). A lesson nobody
	# did moves on after 45 s so play is never blocked; is it then stored
	# as learned, so a returning player never sees it again?
	var own := "user://ui_r5x_timeout_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new(own)
	add_child(o)
	o.start()
	# The player spreads their wings (lesson 1 done), then does nothing.
	for i in 72 * 2:
		o.step(1.0 / 72.0, {"wing_extension": 0.9})
	for i in 72 * 50:
		o.step(1.0 / 72.0, {})
	var stored: Array = UIProgress.new(own).lessons_done()
	o.queue_free()
	var o2 := Onboarding.new()
	o2.auto_step = false
	o2.progress_store = UIProgress.new(own)
	add_child(o2)
	o2.start()
	var next_id: StringName = o2.current().get("id", &"")
	o2.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	metric("timed_out_lesson", {"stored_done": stored, "next_session_starts_at": next_id})
	eq(next_id, &"flap", "a returning player is taught 'Flap to climb', which they never did (it timed out)")
