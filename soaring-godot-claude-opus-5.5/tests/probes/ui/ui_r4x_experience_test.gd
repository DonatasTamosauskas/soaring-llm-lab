extends TestCase
## Verifier probes (round 4, experience & requirements lens) for the ui area.
## Written by an independent verifier; modifies no UI source.
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r4x_experience
## A failing check here is a finding, not a flaky test.
##
## What is new versus rounds 1-3: the HUD notices and the lessons are driven
## by *realistic* flight rather than hand-made constant climbs:
##  - ui_r4x_flightpath.json holds the flight-path angle and speed of the
##    flight area's own B1 bot course (artifacts/flight/b1_course_*.csv,
##    sparrow / pigeon / eagle) at ~20 Hz;
##  - the onboarding probe flies the real FlightModel (flight area) with
##    neutral wrists, i.e. the player only does what lesson 2 taught.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const FP_PATH := "res://tests/probes/ui/ui_r4x_flightpath.json"

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
	else:
		k.ui.onboarding.reset()
	k.gl.start_run()
	await k.settle(self, 6)


func _bird(species: StringName, mass: float, pos: Vector3) -> UIStandInBird:
	var b := UIStandInBird.new(species, mass)
	add_child(b)
	b.global_position = pos
	_extra.append(b)
	return b


func _series(species: String) -> Array:
	var f := FileAccess.open(FP_PATH, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary):
		return []
	return ((d as Dictionary)["series"] as Dictionary).get(species, [])


## [gamma_deg, speed] at time t (linear interpolation over the series).
static func _sample(s: Array, t: float) -> Vector2:
	if s.is_empty():
		return Vector2(0.0, 8.0)
	if t <= float(s[0][0]):
		return Vector2(float(s[0][1]), float(s[0][2]))
	for i in range(1, s.size()):
		if float(s[i][0]) >= t:
			var a: Array = s[i - 1]
			var b: Array = s[i]
			var k := (t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4)
			return Vector2(lerpf(float(a[1]), float(b[1]), k), lerpf(float(a[2]), float(b[2]), k))
	var e: Array = s[s.size() - 1]
	return Vector2(float(e[1]), float(e[2]))


## Is `dir` (world, from the eye) behind a notice plate, or within margin_deg
## of one? Checked independently of the HUD's own make-way maths: rays from
## the eye through the real band surface (the pointer's ray test), the hit
## pixel tested against the plate rects in the HUD texture.
func _behind_notice(k: Kit, dir: Vector3, margin_deg: float) -> bool:
	var p := k.ui.hud_panel
	var eye := k.cam.global_position
	var plates := k.ui.hud.band_plates(HUD.BAND_NOTICE)
	if plates.is_empty() or not p.is_band_visible(HUD.BAND_NOTICE):
		return false
	var probes: Array[Vector3] = [dir.normalized()]
	if margin_deg > 0.0:
		var side := dir.cross(Vector3.UP)
		if side.length() < 1e-4:
			side = Vector3.RIGHT
		side = side.normalized()
		var up := side.cross(dir).normalized()
		for i in 12:
			var a := TAU * i / 12.0
			var axis := (side * cos(a) + up * sin(a)).normalized()
			probes.append(dir.normalized().rotated(axis, deg_to_rad(margin_deg)))
	for d in probes:
		var h := p.intersect_ray(eye, d)
		if h.is_empty():
			continue
		var px: Vector2 = h["pixel"]
		if int(p.band_of_row(px.y)) != HUD.BAND_NOTICE:
			continue
		for pl in plates:
			if pl.get_global_rect().has_point(px):
				return true
	return false


## What the player sees of the notices: band opacity x (toast fade if a toast).
func _notice_opacity(k: Kit) -> float:
	var p := k.ui.hud_panel
	if not p.is_band_visible(HUD.BAND_NOTICE):
		return 0.0
	var a := p.band_alpha(HUD.BAND_NOTICE)
	var toast := k.ui.hud.get_node_or_null("TierUp") as Control
	if toast and toast.visible:
		a *= toast.modulate.a
	return a


# --- 1. Notices under the flight area's real flight-path profile ------------

## Replays `seconds` of a species' B1 flight-path profile in real time, from
## t0, while notices are shown; optionally fires tier-ups at the given
## offsets. Returns per-frame statistics.
func _replay(k: Kit, s: Array, t0: float, seconds: float, tierups: Array = []) -> Dictionary:
	var hud := k.ui.hud
	var p := k.ui.hud_panel
	var n := 0
	var readable := 0
	var hidden := 0
	var hugging := 0
	var faded := 0
	var travel := 0.0
	var replacements := 0
	var far_side := 0
	var max_off := Vector2.ZERO
	var prev_off := p.band_offset(HUD.BAND_NOTICE)
	var prev_target := hud.dodge_target
	var gam_lo := 999.0
	var gam_hi := -999.0
	var pending := tierups.duplicate()
	var tier := 2
	var toasts: Array = []
	var cur_toast := {}
	# Time-weighted (headless frame rates vary): seconds hidden, in motion.
	var hidden_s := 0.0
	var hidden_run := 0.0
	var hidden_longest := 0.0
	var moving_s := 0.0
	var episodes := 0
	var was_moving := false
	var shown_s := 0.0
	var prev_ms := Time.get_ticks_msec()
	var start := Time.get_ticks_msec()
	while true:
		var el := (Time.get_ticks_msec() - start) / 1000.0
		if el >= seconds:
			break
		var g := _sample(s, t0 + el)
		gam_lo = minf(gam_lo, g.x)
		gam_hi = maxf(gam_hi, g.x)
		var a := deg_to_rad(g.x)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * g.y
		if not pending.is_empty() and el >= float(pending[0]):
			pending.pop_front()
			if not cur_toast.is_empty():
				toasts.append(cur_toast)
			k.player.mass = float(SizeRules.SPECIES[tier + 1]["mass"]) * 1.02
			Events.player_tier_changed.emit(tier, tier + 1)
			tier = 2 if tier >= 7 else tier + 1
			cur_toast = {"at": snappedf(el, 0.01), "n": 0, "readable": 0, "hidden": 0}
		await wait_frames(1)
		n += 1
		var now_ms := Time.get_ticks_msec()
		var fdt := (now_ms - prev_ms) / 1000.0
		prev_ms = now_ms
		var dir := k.player.velocity.normalized()
		var o := _notice_opacity(k)
		var shown := p.is_band_visible(HUD.BAND_NOTICE) and not hud.band_plates(HUD.BAND_NOTICE).is_empty()
		var hid_now := false
		if shown:
			shown_s += fdt
			if o >= HUD.READABLE_ALPHA:
				readable += 1
				if _behind_notice(k, dir, 0.0):
					hidden += 1
					hid_now = true
				elif _behind_notice(k, dir, 1.0):
					hugging += 1
			if p.band_alpha(HUD.BAND_NOTICE) < 0.95:
				faded += 1
		if hid_now:
			hidden_s += fdt
			hidden_run += fdt
			hidden_longest = maxf(hidden_longest, hidden_run)
		else:
			hidden_run = 0.0
		var off := p.band_offset(HUD.BAND_NOTICE)
		var step_deg := off.distance_to(prev_off)
		travel += step_deg
		prev_off = off
		# "In motion": moving faster than 5 deg/s this frame.
		var mv := shown and fdt > 0.0 and step_deg / fdt > 5.0
		if mv:
			moving_s += fdt
			if not was_moving:
				episodes += 1
		was_moving = mv
		if hud.dodge_target != prev_target:
			replacements += 1
			prev_target = hud.dodge_target
		if absf(off.x) >= 15.0:
			far_side += 1
		if off.length() > max_off.length():
			max_off = off
		if not cur_toast.is_empty() and hud.toast_active():
			cur_toast["n"] = int(cur_toast["n"]) + 1
			if o >= HUD.READABLE_ALPHA:
				cur_toast["readable"] = int(cur_toast["readable"]) + 1
				if _behind_notice(k, dir, 0.0):
					cur_toast["hidden"] = int(cur_toast["hidden"]) + 1
	if not cur_toast.is_empty():
		toasts.append(cur_toast)
	for t: Dictionary in toasts:
		t["readable_frac"] = snappedf(float(t["readable"]) / maxf(float(t["n"]), 1.0), 0.01)
	var el_s := (Time.get_ticks_msec() - start) / 1000.0
	return {
		"frames": n, "seconds": snappedf(el_s, 0.1),
		"gamma_range_deg": [snappedf(gam_lo, 0.1), snappedf(gam_hi, 0.1)],
		"readable_frac": snappedf(readable / float(maxi(n, 1)), 0.01),
		"faded_frac": snappedf(faded / float(maxi(n, 1)), 0.01),
		"path_hidden_frames": hidden, "path_within_1deg_frames": hugging,
		"replacements": replacements, "replacements_per_s": snappedf(replacements / maxf(el_s, 0.01), 0.01),
		"travel_deg": snappedf(travel, 0.1), "travel_deg_per_s": snappedf(travel / maxf(el_s, 0.01), 0.1),
		"far_side_frac": snappedf(far_side / float(maxi(n, 1)), 0.01),
		"max_offset_deg": [snappedf(max_off.x, 0.1), snappedf(max_off.y, 0.1)],
		"peak_move_speed_deg_s": snappedf(hud.peak_move_speed, 0.1),
		"shown_s": snappedf(shown_s, 0.1),
		"path_hidden_s": snappedf(hidden_s, 0.01), "path_hidden_longest_s": snappedf(hidden_longest, 0.01),
		"moving_frac": snappedf(moving_s / maxf(shown_s, 0.01), 0.01), "move_episodes": episodes,
		"move_episodes_per_s": snappedf(episodes / maxf(shown_s, 0.01), 0.01),
		"toasts": toasts,
	}


## The flight a tutorial asks for ("Flap to climb", then "Glide"): the real
## FlightModel (sparrow), neutral wrists, bursts of `strokes` strokes at 1 Hz
## then `glide_s` of gliding. Returns a [t, gamma_deg, speed] series at 20 Hz.
static func _tutorial_series(strokes: int, glide_s: float, seconds: float) -> Array:
	var m := FlightModel.new(FlightParams.species_mass(&"sparrow"), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var dt := 1.0 / 72.0
	var out: Array = []
	var cycle := float(strokes) + glide_s
	var next := 0.0
	for i in int(seconds / dt):
		var t := i * dt
		var ph := fmod(t, cycle)
		if ph < float(strokes):
			ws.set_commands(0.0, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, dt)
		if t >= next:
			var v := m.velocity
			out.append([t, rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())), v.length()])
			next += 0.05
	return out


func _judge_notice_run(label: String, r: Dictionary, bad: Array) -> void:
	# The builder's claim: the flight path is never within 2 deg of a notice.
	if float(r["path_hidden_s"]) > 0.0:
		bad.append("%s: the readable notice hid the flight path for %.2f s of %.1f s (longest %.2f s)" % [
			label, float(r["path_hidden_s"]), float(r["shown_s"]), float(r["path_hidden_longest_s"])])
	if float(r["readable_frac"]) < 0.9:
		bad.append("%s: readable only %d%% of the time" % [label, int(float(r["readable_frac"]) * 100.0)])
	# Calm: a peripheral card that is still >= 80 % of the time and starts a
	# move at most every 2 s on average.
	if float(r["moving_frac"]) > 0.2:
		bad.append("%s: in motion %d%% of the time" % [label, int(float(r["moving_frac"]) * 100.0)])
	if float(r["move_episodes_per_s"]) > 0.5:
		bad.append("%s: %.2f separate moves a second (%.0f deg travelled in %.0f s)" % [
			label, float(r["move_episodes_per_s"]), float(r["travel_deg"]), float(r["seconds"])])


func test_lesson_card_under_real_flight_profiles() -> void:
	# The tutorial's lesson card is up for the whole first flight. Fly (a) the
	# tutorial's own gestures through the real FlightModel and (b) the flight
	# area's bot course (flapping climbs, zooms, dives), and watch the card:
	# is it readable, does it hide the flight path, how much does it move
	# (peripheral motion draws the eye)?
	var profiles := {
		"tutorial flap3+glide3 (FlightModel)": _tutorial_series(3, 3.0, 14.0),
		"tutorial flap2+glide2 (FlightModel)": _tutorial_series(2, 2.0, 14.0),
		"B1 sparrow": _series("sparrow"),
		"B1 pigeon": _series("pigeon"),
		"B1 eagle": _series("eagle"),
	}
	var results := {}
	var bad: Array = []
	for key: String in profiles:
		var s: Array = profiles[key]
		check(not s.is_empty(), "profile %s loaded" % key)
		var k := Kit.new()
		await _start(k, false)
		check(k.ui.hud.lesson_visible(), "a lesson card is up (%s)" % key)
		var r := await _replay(k, s, 0.0, 12.0)
		r.erase("toasts")
		results[key] = r
		print("[ui-verify] lesson card, %s 0-12 s: %s" % [key, r])
		_judge_notice_run(key, r, bad)
		k.teardown()
		await wait_frames(3)
	metric("lesson_card_real_profiles", results)
	for b in bad:
		print("[ui-verify]   ", b)
	eq(bad.size(), 0, "lesson card stays readable, never hides the path, and stays calm under real flight: %s" % str(bad))


func test_tier_up_celebrations_under_real_flight_profiles() -> void:
	# Tier-ups happen mid-hunt, i.e. in real flight. Fire three of them during
	# each profile's replay (lessons skipped).
	var profiles := {
		"tutorial flap3+glide3 (FlightModel)": _tutorial_series(3, 3.0, 16.0),
		"B1 sparrow": _series("sparrow"),
		"B1 pigeon": _series("pigeon"),
		"B1 eagle": _series("eagle"),
	}
	var results := {}
	var bad: Array = []
	for key: String in profiles:
		var k := Kit.new()
		await _start(k, true)
		var r := await _replay(k, profiles[key], 0.0, 14.0, [0.5, 5.0, 9.5])
		results[key] = r
		print("[ui-verify] tier-ups, %s 0-14 s: %s" % [key, r])
		for t: Dictionary in r["toasts"]:
			if float(t["readable_frac"]) < 0.7:
				bad.append("%s toast at %.1f s: readable %d%%" % [key, float(t["at"]), int(float(t["readable_frac"]) * 100.0)])
			if int(t["hidden"]) > 0:
				bad.append("%s toast at %.1f s: hid the flight path in %d of %d frames" % [key, float(t["at"]), int(t["hidden"]), int(t["n"])])
		k.teardown()
		await wait_frames(3)
	metric("tierup_real_profiles", results)
	for b in bad:
		print("[ui-verify]   ", b)
	eq(bad.size(), 0, "every tier-up celebration is readable >= 70%% of its time and never hides the flight path under real flight: %s" % str(bad))


# --- 2. A fluttering target near the notice band ----------------------------

func test_notices_stay_calm_around_a_fluttering_target() -> void:
	# Prey rarely sits still: a moth / wren jinks about. Put the current
	# target 15 m ahead, wandering +-8 deg in azimuth and +-5 deg in elevation
	# round 12 deg up (right where the notices live), 0.4 rev/s, in level
	# flight with the lesson card up.
	var k := Kit.new()
	await _start(k, false)
	var cruise := SizeRules.cruise_speed(0.03)
	k.player.velocity = Vector3(0, 0, -1) * cruise
	var prey := _bird(&"moth", 0.004, k.cam.global_position + Vector3(0, 3, -15))
	Events.target_changed.emit(prey)
	await wait_frames(10)
	var hud := k.ui.hud
	var p := k.ui.hud_panel
	var n := 0
	var readable := 0
	var hidden := 0
	var travel := 0.0
	var reps := 0
	var prev_off := p.band_offset(HUD.BAND_NOTICE)
	var prev_t := hud.dodge_target
	var moving_s := 0.0
	var episodes := 0
	var was_moving := false
	var prev_ms := Time.get_ticks_msec()
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 8000:
		var t := (Time.get_ticks_msec() - start) / 1000.0
		var az := deg_to_rad(8.0 * cos(TAU * 0.4 * t))
		var el := deg_to_rad(12.0 + 5.0 * sin(TAU * 0.4 * t * 1.3))
		var d := Vector3(-sin(az) * cos(el), sin(el), -cos(az) * cos(el))
		prey.global_position = k.cam.global_position + d * 15.0
		await wait_frames(1)
		n += 1
		var dir := (prey.get_body_position() - k.cam.global_position).normalized()
		if _notice_opacity(k) >= HUD.READABLE_ALPHA:
			readable += 1
			if _behind_notice(k, dir, 0.0):
				hidden += 1
		var off := p.band_offset(HUD.BAND_NOTICE)
		var now_ms := Time.get_ticks_msec()
		var fdt := (now_ms - prev_ms) / 1000.0
		prev_ms = now_ms
		var step_deg := off.distance_to(prev_off)
		travel += step_deg
		prev_off = off
		var mv := fdt > 0.0 and step_deg / fdt > 5.0
		if mv:
			moving_s += fdt
			if not was_moving:
				episodes += 1
		was_moving = mv
		if hud.dodge_target != prev_t:
			reps += 1
			prev_t = hud.dodge_target
	var secs := (Time.get_ticks_msec() - start) / 1000.0
	var r := {"frames": n, "readable_frac": snappedf(readable / float(maxi(n, 1)), 0.01), "target_hidden_frames": hidden,
		"replacements_per_s": snappedf(reps / secs, 0.01), "travel_deg_per_s": snappedf(travel / secs, 0.1),
		"moving_frac": snappedf(moving_s / secs, 0.01), "move_episodes_per_s": snappedf(episodes / secs, 0.01)}
	metric("fluttering_target", r)
	print("[ui-verify] lesson card with a fluttering target 12 deg up: ", r)
	eq(hidden, 0, "the fluttering target is never behind a readable notice (%s)" % str(r))
	gt(float(r["readable_frac"]), 0.9, "the lesson card stays readable (%s)" % str(r))
	lt(float(r["moving_frac"]), 0.2, "the lesson card is still >= 80%% of the time (%s)" % str(r))
	lt(float(r["move_episodes_per_s"]), 0.5, "the lesson card starts a move at most every 2 s on average (%s)" % str(r))
	k.teardown()
	await wait_frames(2)


# --- 3. Onboarding: does "Tilt for speed" need a tilt? ----------------------

## Flies the real FlightModel (sparrow) for `seconds` with symmetric pitch
## command `pitch` (wrist twist; 0 = neutral), flapping in bursts of
## `strokes` strokes at 1 Hz followed by `glide_s` of gliding, arms spread.
## Feeds an Onboarding sitting on the "speed" lesson with the telemetry a
## PlayerBird reports (flapping = 0.3 s low-pass of the stroke, as
## WingInput computes it). Returns what happened.
func _fly_speed_lesson(pitch: float, strokes: int, glide_s: float, seconds: float) -> Dictionary:
	var tu := FlightTuning.new()
	var m := FlightModel.new(FlightParams.species_mass(&"sparrow"), tu)
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var o := Onboarding.new()
	o.auto_step = false
	o.start()
	o._begin(3)
	var dt := 1.0 / 72.0
	var lp := 0.0
	var k_lp := 1.0 - exp(-dt / 0.3)
	var cycle := float(strokes) + glide_s
	var done_at := -1.0
	var v_lo := INF
	var v_hi := 0.0
	var vs_hi_glide := -INF
	var max_prog := 0.0
	var steps := int(seconds / dt)
	for i in steps:
		var t := i * dt
		var ph := fmod(t, cycle) if strokes > 0 else cycle
		if strokes > 0 and ph < float(strokes):
			ws.set_commands(pitch, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(pitch, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, dt)
		lp += (maxf(ws.flap_l, ws.flap_r) - lp) * k_lp
		var tel := m.telemetry()
		tel["flapping"] = clampf(lp, 0.0, 1.0)
		tel["wing_extension"] = 1.0
		tel["tucked"] = false
		tel["perched"] = false
		v_lo = minf(v_lo, float(tel["airspeed"]))
		v_hi = maxf(v_hi, float(tel["airspeed"]))
		if lp < 0.15:
			vs_hi_glide = maxf(vs_hi_glide, float(tel["vertical_speed"]))
		o.step(dt, tel)
		max_prog = maxf(max_prog, o.progress)
		if done_at < 0.0 and (o.celebrating > 0.0 or o.index != 3):
			done_at = t
	var r := {"completed_at_s": snappedf(done_at, 0.01), "max_progress": snappedf(max_prog, 0.01),
		"airspeed_range": [snappedf(v_lo, 0.1), snappedf(v_hi, 0.1)], "max_vs_while_not_flapping": snappedf(vs_hi_glide, 0.1),
		"alt_change_m": snappedf(m.position.y - 80.0, 0.1)}
	o.free()
	return r


func test_speed_lesson_is_not_completed_by_flapping_and_gliding() -> void:
	# Lesson 4 teaches the brief's requirement 2: speed via angle of attack
	# ("Twist both wrists down"; the balloon counts too). A player who has just
	# learnt "Flap to climb" and "Glide" keeps doing exactly that: a burst of
	# strokes, then a glide, wrists neutral. That must not tick off the lesson
	# on the AoA mechanic they never tried.
	var runs := {}
	runs["flap 3 + glide 3 s, wrists neutral"] = _fly_speed_lesson(0.0, 3, 3.0, 24.0)
	runs["flap 2 + glide 2 s, wrists neutral"] = _fly_speed_lesson(0.0, 2, 2.0, 24.0)
	runs["flap 1 + glide 3 s, wrists neutral"] = _fly_speed_lesson(0.0, 1, 3.0, 24.0)
	# Controls: a steady glide does nothing; the taught gestures complete it.
	runs["steady glide, wrists neutral (control)"] = _fly_speed_lesson(0.0, 0, 0.0, 24.0)
	runs["glide, wrists twisted down (pitch -0.6)"] = _fly_speed_lesson(-0.6, 0, 0.0, 10.0)
	runs["glide, wrists twisted up (pitch +0.6)"] = _fly_speed_lesson(0.6, 0, 0.0, 10.0)
	metric("speed_lesson_runs", runs)
	for key: String in runs:
		print("[ui-verify] speed lesson, %s: %s" % [key, runs[key]])
	var false_pos: Array = []
	for key: String in runs:
		if key.contains("wrists neutral") and float(runs[key]["completed_at_s"]) >= 0.0:
			false_pos.append("%s -> completed at %.1f s" % [key, float(runs[key]["completed_at_s"])])
	eq(false_pos.size(), 0, "'Tilt for speed' is not completed without tilting the wrists: %s" % str(false_pos))
	var taught := float(runs["glide, wrists twisted down (pitch -0.6)"]["completed_at_s"]) >= 0.0 \
		or float(runs["glide, wrists twisted up (pitch +0.6)"]["completed_at_s"]) >= 0.0
	check(taught, "control: a real wrist tilt completes the lesson (%s / %s)" % [
		str(runs["glide, wrists twisted down (pitch -0.6)"]), str(runs["glide, wrists twisted up (pitch +0.6)"])])


# --- 4. Back-to-back celebrations ------------------------------------------

func test_back_to_back_celebrations_do_not_flash() -> void:
	# Two apex catches 0.6 s apart (an eagle taking two birds from a flock).
	# The second toast replaces the first; does the notice blink out and back?
	var k := Kit.new()
	await _start(k)
	k.player.mass = 3.1
	k.player.velocity = Vector3(0, 0, -1) * SizeRules.cruise_speed(3.1)
	k.gl.stats["apex"]["reached"] = true
	await wait_frames(10)
	k.gl.fake_apex_catch()
	var start := Time.get_ticks_msec()
	var second := false
	var min_after_first_full := 1.0
	var saw_full := false
	var n2 := 0
	var r2 := 0
	while Time.get_ticks_msec() - start < 4200:
		var el := (Time.get_ticks_msec() - start) / 1000.0
		if not second and el >= 0.6:
			second = true
			k.gl.fake_apex_catch()
		await wait_frames(1)
		var o := _notice_opacity(k)
		if o >= 0.95:
			saw_full = true
		if saw_full and el < 1.2:
			min_after_first_full = minf(min_after_first_full, o)
		if second and k.ui.hud.toast_active():
			n2 += 1
			if o >= HUD.READABLE_ALPHA:
				r2 += 1
	var r := {"min_opacity_between": snappedf(min_after_first_full, 0.01), "second_readable_frac": snappedf(r2 / float(maxi(n2, 1)), 0.01),
		"text": k.ui.hud.toast_text()}
	metric("back_to_back_apex_toasts", r)
	print("[ui-verify] two apex catches 0.6 s apart: ", r)
	gt(float(r["second_readable_frac"]), 0.7, "the second celebration is readable >= 70%% of its time (%s)" % str(r))
	gt(float(r["min_opacity_between"]), 0.3, "the notice does not blink out when a celebration replaces another (%s)" % str(r))
	k.teardown()
	await wait_frames(2)


# --- 5. Robustness: freed birds, degenerate directions -----------------------

func test_freed_target_and_threat_and_degenerate_directions() -> void:
	var k := Kit.new()
	await _start(k, false)
	var eye := k.cam.global_position
	var prey := _bird(&"wren", 0.012, eye + Vector3(-6, 2, -8))
	var hawk := _bird(&"hawk", 1.3, eye + Vector3(4, 1, 9))
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.9, hawk)
	await wait_frames(20)
	check(k.ui.indicators.cue_mesh(&"target").visible, "target cue up")
	# Birds freed without the "changed" events first (a despawn or a pooled
	# NPC freed before the next target/threat event).
	prey.free()
	hawk.free()
	await wait_seconds(1.2)
	var dirs := k.ui.hud_protected_directions()
	check(dirs.size() <= 1, "freed birds are no longer protected directions (%d)" % dirs.size())
	check(not k.ui.indicators.cue_mesh(&"target").visible, "no cue for a freed target (after its 0.8 s fade)")
	check(not k.ui.indicators.cue_mesh(&"threat").visible, "no cue for a freed threat (after its fade)")
	# The next target / threat must be picked up normally.
	var b := _bird(&"wren", 0.012, eye + Vector3(8, 0.5, -3))
	Events.target_changed.emit(b)
	var h2 := _bird(&"hawk", 1.3, eye + Vector3(-5, 1, 8))
	Events.threat_changed.emit(0.9, h2)
	await wait_frames(30)
	var tb: Variant = k.ui.get(&"_target")
	var th: Variant = k.ui.get(&"_threat")
	check(is_instance_valid(tb) and tb == b, "after a freed target, the next target is taken (UIRoot._target is the new bird)")
	check(is_instance_valid(th) and th == h2, "after a freed threat, the next threat is taken (UIRoot._threat is the new bird)")
	check(k.ui.indicators.cue_mesh(&"target").visible, "after a freed target, the next target gets a cue")
	check(k.ui.indicators.cue_mesh(&"threat").visible, "after a freed threat, the next threat gets a cue")
	var c := _bird(&"wren", 0.012, eye + Vector3(-8, 0.5, -3))
	Events.target_changed.emit(c)
	await wait_frames(20)
	tb = k.ui.get(&"_target")
	check(is_instance_valid(tb) and tb == c, "and the one after that (UIRoot._target follows target_changed)")
	# Degenerate: straight up, straight down, a target exactly at the eye.
	var at_eye := _bird(&"wren", 0.012, k.cam.global_position)
	Events.target_changed.emit(at_eye)
	for v: Vector3 in [Vector3(0, 9, 0), Vector3(0, -9, 0), Vector3(0, 0.0001, 0)]:
		k.player.velocity = v
		await wait_frames(15)
		var off := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
		var a := k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE)
		check(is_finite(off.x) and is_finite(off.y) and is_finite(a), "notice placement finite for velocity %s (%s, %.2f)" % [v, off, a])
		var t := k.ui.indicators.cue_mesh(&"target")
		var o := t.global_transform.origin
		check(is_finite(o.x) and is_finite(o.y) and is_finite(o.z), "target cue transform finite for a target at the eye")
	k.teardown()
	await wait_frames(2)


# --- 6. Pointer: resting on a button edge with a real hand's tremor ----------

func test_pointer_resting_on_a_button_edge_does_not_buzz() -> void:
	# A hand holding still still trembles (physiological tremor, ~2-10 Hz,
	# ~0.05-0.2 deg at the aim ray). Resting the beam near the edge of a
	# button (a common place to rest it while reading the rest of the screen)
	# must not turn every edge crossing into a haptic tick: "distinct
	# patterns, never a constant buzz" (DESIGN, haptics).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 3)
	var play := k.ui.get_screen(&"main").find_child("Btn_play", true, false) as Control
	check(play != null, "found the Play button")
	var rect := play.get_global_rect()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var results := {}
	for sigma_deg: float in [0.05, 0.1, 0.2]:
		var sigma_px := deg_to_rad(sigma_deg) * UITheme.PANEL_DISTANCE * UITheme.PX_PER_M
		# Band-limited tremor: four sinusoids per axis (2.3-9.9 Hz), random
		# phases, RMS = sigma.
		var freqs := [2.3, 4.1, 7.7, 9.9]
		var ph := []
		for i in 8:
			ph.append(rng.randf() * TAU)
		var amp := sigma_px * sqrt(2.0 / freqs.size())
		k.right.haptic_log.clear()
		var hover_changes := 0
		var ticks := 0
		var prev: Control = k.ui.pointer.hovered()
		var start := Time.get_ticks_msec()
		var frames := 0
		while Time.get_ticks_msec() - start < 3000:
			var t := (Time.get_ticks_msec() - start) / 1000.0
			var dx := 0.0
			var dy := 0.0
			for i in freqs.size():
				dx += amp * sin(TAU * float(freqs[i]) * t + float(ph[i]))
				dy += amp * sin(TAU * float(freqs[i]) * t + float(ph[i + 4]))
			# Resting on the button's bottom edge, centred horizontally.
			var px := Vector2(rect.get_center().x + dx, rect.end.y + dy)
			k.aim(k.right, k.ui.menu_panel.pixel_to_world(px))
			await wait_frames(1)
			frames += 1
			if k.ui.pointer.hovered() != prev:
				hover_changes += 1
				prev = k.ui.pointer.hovered()
			# Count this frame's hover ticks (12 ms pulses) and clear: the log
			# is capped at 64 entries.
			for hp in k.right.haptic_log:
				if hp.y < 0.02:
					ticks += 1
			k.right.haptic_log.clear()
		var secs := (Time.get_ticks_msec() - start) / 1000.0
		results["sigma %.2f deg" % sigma_deg] = {"sigma_px": snappedf(sigma_px, 0.1), "frames": frames,
			"hover_changes_per_s": snappedf(hover_changes / secs, 0.1), "haptic_ticks_per_s": snappedf(ticks / secs, 0.1)}
	metric("pointer_edge_tremor", results)
	print("[ui-verify] pointer resting on a button edge with band-limited tremor: ", results)
	for key: String in results:
		lt(float(results[key]["haptic_ticks_per_s"]), 4.0, "resting on a button edge (%s) gives < 4 haptic ticks a second (%s)" % [key, str(results[key])])
	k.teardown()
	await wait_frames(2)


func test_press_then_drag_off_does_not_click() -> void:
	# Standard button contract: a pull that starts on Play and is released
	# after the beam slid off it (the player changed their mind) must not
	# start a run; nor may a pull that starts off a button and ends on one.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 3)
	var play := k.ui.get_screen(&"main").find_child("Btn_play", true, false) as Control
	k.aim_at_control(k.right, play)
	await k.wait_clickable(self)
	await wait_frames(2)
	k.right.trigger_value = 1.0
	await wait_frames(3)
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(40, 40)))
	await wait_frames(3)
	k.right.trigger_value = 0.0
	await wait_frames(4)
	eq(Game.state, Game.State.MENU, "press on Play, release off it: no run started")
	eq(k.gl.starts, 0, "no start_run call")
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(40, 40)))
	await wait_frames(2)
	k.right.trigger_value = 1.0
	await wait_frames(3)
	k.aim_at_control(k.right, play)
	await wait_frames(3)
	k.right.trigger_value = 0.0
	await wait_frames(4)
	eq(k.gl.starts, 0, "press off Play, release on it: no run started")
	# Control: a clean click still works.
	await k.click_control(self, play)
	await wait_frames(4)
	eq(k.gl.starts, 1, "control: a clean click on Play starts a run")
	k.teardown()
	await wait_frames(2)


# --- 7. A long session: no leaks, no drift ---------------------------------

func _node_count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _node_count(ch)
	return c


func test_long_session_does_not_leak() -> void:
	var k := Kit.new()
	await _start(k)
	k.fast_holds()
	var hawk := _bird(&"hawk", 1.3, Vector3(3, 3, 8))
	var snap := func() -> Dictionary:
		return {"ui_nodes": _node_count(k.ui), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))}
	var before := {}
	var tier := 2
	for i in 26:
		if i == 2:
			before = snap.call()
		# Play: a target that later despawns, a threat, a tier-up, an apex toast.
		var prey := UIStandInBird.new(&"moth", 0.004)
		add_child(prey)
		prey.global_position = Vector3(-4, 2, -6)
		Events.target_changed.emit(prey)
		Events.threat_changed.emit(0.8, hawk)
		var nt := 3 if tier == 2 else 2
		k.player.mass = float(SizeRules.SPECIES[nt]["mass"]) * 1.02
		Events.player_tier_changed.emit(tier, nt)
		tier = nt
		await wait_frames(4)
		Events.target_changed.emit(null)
		prey.queue_free()
		# Pause -> settings -> back -> how to fly -> back -> resume.
		k.ui._last_menu_ms = -100000
		Events.menu_requested.emit()
		await wait_frames(3)
		k.ui._on_action(&"settings", &"pause")
		await wait_frames(2)
		k.ui.pop_screen()
		k.ui._on_action(&"howto", &"pause")
		await wait_frames(2)
		k.ui.pop_screen()
		k.ui.resume()
		await wait_frames(3)
		# Caught -> respawn; every 5th cycle the run ends and restarts.
		k.gl.fake_caught(hawk)
		await wait_frames(3)
		Game.set_state(Game.State.PLAYING)
		await wait_frames(3)
		if i % 5 == 4:
			k.gl.fake_end({"score": 100 * i})
			await wait_frames(3)
			k.gl.start_run()
			await wait_frames(3)
	await wait_frames(10)
	var after: Dictionary = snap.call()
	var growth := {}
	for key: String in after:
		growth[key] = int(after[key]) - int(before[key])
	metric("long_session_growth", {"before": before, "after": after, "growth": growth})
	print("[ui-verify] 24 play/pause/caught cycles: before %s after %s growth %s" % [before, after, growth])
	lt(float(growth["ui_nodes"]), 5.0, "UI node count does not grow over a long session (%s)" % str(growth))
	lt(float(growth["orphans"]), 5.0, "no orphan nodes pile up (%s)" % str(growth))
	lt(float(growth["objects"]), 200.0, "object count stays flat (%s)" % str(growth))
	k.teardown()
	await wait_frames(2)


# --- 8. Evidence plot: the lesson card during the tutorial's own flight ------

## Draws a polyline of (x = time, y = value) into img within `r` (value
## range lo..hi). Pure Image drawing, so it works headless.
static func _plot(img: Image, r: Rect2i, xs: Array, ys: Array, lo: float, hi: float, t_max: float, col: Color) -> void:
	var prev := Vector2i(-1, -1)
	for i in xs.size():
		var px := r.position.x + int(float(xs[i]) / t_max * (r.size.x - 1))
		var v := clampf((float(ys[i]) - lo) / (hi - lo), 0.0, 1.0)
		var py := r.position.y + r.size.y - 1 - int(v * (r.size.y - 1))
		var p := Vector2i(px, py)
		if prev.x >= 0:
			var n := maxi(absi(p.x - prev.x), absi(p.y - prev.y))
			for j in n + 1:
				var q := Vector2(prev).lerp(Vector2(p), float(j) / maxf(n, 1))
				for dy in range(-1, 2):
					var qx := int(q.x)
					var qy := int(q.y) + dy
					if qx >= 0 and qx < img.get_width() and qy >= 0 and qy < img.get_height():
						img.set_pixel(qx, qy, col)
		prev = p


func test_zz_plot_lesson_card_motion_during_the_tutorial_flight() -> void:
	# The flight "Flap to climb" asks for (FlightModel, sparrow, neutral wrists,
	# 2 strokes then 2 s glide): flight-path angle (white), the lesson card's
	# offset up (sunflower) and sideways (teal), and red ticks where the
	# readable card hides the flight path. 10 s.
	var s := _tutorial_series(2, 2.0, 12.0)
	var k := Kit.new()
	await _start(k, false)
	var p := k.ui.hud_panel
	var ts: Array = []
	var gam: Array = []
	var up: Array = []
	var side: Array = []
	var hid: Array = []
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 10000:
		var el := (Time.get_ticks_msec() - start) / 1000.0
		var g := _sample(s, el)
		var a := deg_to_rad(g.x)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * g.y
		await wait_frames(1)
		var off := p.band_offset(HUD.BAND_NOTICE)
		ts.append(el)
		gam.append(g.x)
		up.append(off.y)
		side.append(absf(off.x))
		hid.append(_notice_opacity(k) >= HUD.READABLE_ALPHA and _behind_notice(k, k.player.velocity.normalized(), 0.0))
	k.teardown()
	await wait_frames(2)
	var w := 1400
	var h := 700
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.11, 0.14, 0.2))
	var r := Rect2i(60, 40, w - 100, h - 110)
	# Grid: every 10 deg from -60 to +90, every second.
	for d in range(-60, 91, 10):
		var y := r.position.y + r.size.y - 1 - int((d + 60.0) / 150.0 * (r.size.y - 1))
		var gc := Color(0.35, 0.4, 0.5) if d == 0 else Color(0.2, 0.24, 0.32)
		img.fill_rect(Rect2i(r.position.x, y, r.size.x, 1), gc)
	for sec in 11:
		img.fill_rect(Rect2i(r.position.x + int(sec / 10.0 * (r.size.x - 1)), r.position.y, 1, r.size.y), Color(0.2, 0.24, 0.32))
	# The notice band's home (+7..+20 deg) as a shaded strip.
	var y20 := r.position.y + r.size.y - 1 - int((20.0 + 60.0) / 150.0 * (r.size.y - 1))
	var y7 := r.position.y + r.size.y - 1 - int((7.0 + 60.0) / 150.0 * (r.size.y - 1))
	img.fill_rect(Rect2i(r.position.x, y20, r.size.x, y7 - y20), Color(0.25, 0.22, 0.12))
	_plot(img, r, ts, gam, -60.0, 90.0, 10.0, Color(0.95, 0.95, 0.95))
	_plot(img, r, ts, up, -60.0, 90.0, 10.0, Color(1.0, 0.78, 0.3))
	_plot(img, r, ts, side, -60.0, 90.0, 10.0, Color(0.37, 0.88, 0.66))
	for i in ts.size():
		if hid[i]:
			var x := r.position.x + int(float(ts[i]) / 10.0 * (r.size.x - 1))
			img.fill_rect(Rect2i(x, r.position.y + r.size.y + 8, 2, 30), Color(1.0, 0.42, 0.37))
	var dir := Paths.artifacts("ui").path_join("verify")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("r4x_lesson_card_motion_tutorial_flight.png")
	var err := img.save_png(path)
	print("[ui-verify] wrote %s (%d samples, err %d)" % [path, ts.size(), err])
	eq(err, OK, "motion plot saved")
