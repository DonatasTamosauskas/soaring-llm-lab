extends TestCase
## Verifier probes (round 2, experience & requirements lens) for the ui area.
## Written by an independent verifier; does not modify any UI source.
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r2_experience
## A failing check here is a finding, not a flaky test.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const DT := 1.0 / 90.0


# --- HUD vs the player's gaze ------------------------------------------------

## Is the gaze ray from the camera covered by one of the HUD's opaque plates?
## Returns "" (clear), "lesson", "growth" or "toast".
func _plate_under(k: Kit, dir_local: Vector3) -> String:
	var cam := k.cam.global_transform
	var d := (cam.basis * dir_local).normalized()
	var hit := k.ui.hud_panel.intersect_ray(cam.origin, d)
	if hit.is_empty():
		return ""
	var px: Vector2 = hit["pixel"]
	for n in ["Lesson", "Growth"]:
		var c := k.ui.hud.get_node_or_null(n) as Control
		if c and c.is_visible_in_tree() and c.get_global_rect().has_point(px):
			return String(n).to_lower()
	return ""


func _gaze_sweep(k: Kit) -> Dictionary:
	# Head yaw 0, gaze pitch from level to 50 deg down. The HUD follows yaw
	# only, so after each head pose we give it time to settle as it would.
	var covered_centre: Array = []
	var cone_cover := {}
	for i in 21:
		var pitch := -2.5 * i
		k.set_head(Vector3(0, Kit.EYE, 0), 0.0, pitch)
		await wait_frames(3)
		var centre := _plate_under(k, Vector3.FORWARD)
		if centre != "":
			covered_centre.append(pitch)
		# Central 10-degree cone (where you look at prey): fraction covered.
		var n := 0
		var hitn := 0
		for ax in range(-5, 6):
			for ay in range(-5, 6):
				if ax * ax + ay * ay > 25:
					continue
				n += 1
				var dl := (Basis(Vector3.UP, deg_to_rad(ax)) * Basis(Vector3.RIGHT, deg_to_rad(ay))) * Vector3.FORWARD
				if _plate_under(k, dl) != "":
					hitn += 1
		cone_cover[pitch] = snappedf(hitn / float(n), 0.01)
	return {"centre_covered_at_pitch": covered_centre, "cone10_cover_by_pitch": cone_cover}


func test_hud_plates_cover_the_gaze_when_looking_down() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 6)
	# 1) First flight: lesson card + growth strip.
	check(k.ui.hud.lesson_visible(), "lesson card is up during the first flight")
	var with_lesson := await _gaze_sweep(k)
	metric("gaze_with_lesson", with_lesson)
	# 2) After onboarding: growth strip only (the permanent HUD).
	k.ui.onboarding.skip()
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0, 0.0)
	await k.settle(self, 4)
	var strip_only := await _gaze_sweep(k)
	metric("gaze_strip_only", strip_only)
	print("[ui-verify] gaze with lesson: ", with_lesson)
	print("[ui-verify] gaze strip only: ", strip_only)
	# A hunting bird looks 10-30 deg down at the ground ahead and at prey
	# below; "never in the way of the flight path" should hold there too.
	var bad: Array = []
	for p: float in strip_only["centre_covered_at_pitch"]:
		if p <= -10.0 and p >= -30.0:
			bad.append(p)
	eq(bad.size(), 0, "permanent HUD strip never covers the gaze centre when looking 10-30 deg down (covered at %s)" % str(bad))
	var bad_l: Array = []
	for p: float in with_lesson["centre_covered_at_pitch"]:
		if p <= -5.0 and p >= -30.0:
			bad_l.append(p)
	eq(bad_l.size(), 0, "lesson card + strip never cover the gaze centre when looking 5-30 deg down (covered at %s)" % str(bad_l))
	k.teardown()
	await wait_frames(2)


func test_hud_stays_on_the_gaze_while_you_keep_looking_down() -> void:
	# Diving on prey 25 deg below: hold the gaze there for 3 s. A HUD that
	# follows head pitch lazily would move out of the way; this one?
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 6)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0, -26.0)
	var covered := 0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await wait_frames(1)
		frames += 1
		if _plate_under(k, Vector3.FORWARD) != "":
			covered += 1
	var frac := covered / float(maxi(frames, 1))
	metric("dive_gaze_minus26_covered_frac", snappedf(frac, 0.01))
	print("[ui-verify] gaze at -26 deg covered by the growth strip in %.0f%% of %d frames" % [frac * 100.0, frames])
	lt(frac, 0.5, "HUD gets out of a held downward gaze (covered %.0f%% of 3 s)" % (frac * 100.0))
	k.teardown()
	await wait_frames(2)


# --- Threat cue: a hawk above and behind ------------------------------------

func _run_filter(seconds: float, pos_fn: Callable, strength: float) -> Dictionary:
	var f := IndicatorFilter.new()
	var cam := Transform3D.IDENTITY
	var n := int(seconds / DT)
	var blinks := 0
	var was_drawn := false
	var prev_alpha := 0.0
	var drawn := 0
	for i in n:
		var p: Vector3 = pos_fn.call(i * DT)
		f.update(DT, HudMath.view_polar(cam, p), strength)
		var d := f.is_drawn()
		if d:
			drawn += 1
		# A cut hides the cue and it restarts from ~0 alpha in one frame.
		if f.alpha < prev_alpha - 0.3:
			blinks += 1
		prev_alpha = f.alpha
		was_drawn = d
	return {"cuts": f.cuts, "blinks": blinks, "drawn_frac": snappedf(drawn / float(n), 0.01)}


func test_hawk_high_above_and_behind_with_small_wobble() -> void:
	# A hawk 15 m up and 3 m behind (setting up a stoop), drifting +-1.2 m
	# sideways: under 5 deg of real movement. The cue should hold steady.
	var r := _run_filter(6.0, func(t: float) -> Vector3:
		return Vector3(1.2 * sin(TAU * 0.8 * t), 15.0, 3.0), 0.9)
	metric("hawk_above_behind", r)
	print("[ui-verify] hawk above/behind wobble: ", r)
	lt(r["cuts"], 2, "cue does not cut/blink for a 5-degree drift of a hawk overhead-behind (%d cuts in 6 s)" % r["cuts"])


func test_hawk_circling_overhead() -> void:
	# A hawk circling a thermal 3 m radius, 15 m above the player, one lap
	# every 6 s. The bird never leaves a 12-degree cone round the zenith.
	var r := _run_filter(12.0, func(t: float) -> Vector3:
		var a := TAU * t / 6.0
		return Vector3(3.0 * cos(a), 15.0, 3.0 * sin(a)), 0.9)
	metric("hawk_circling_overhead", r)
	print("[ui-verify] hawk circling overhead: ", r)
	lt(r["cuts"], 5, "at most two cuts per lap for a hawk circling overhead (%d in 2 laps)" % r["cuts"])


func test_side_latch_sweep_scale_free() -> void:
	# A bird behind the eye plane whose TRUE direction wobbles by only +-4
	# degrees (sideways, 0.8 Hz) should never make the cue cut/blink. Sweep
	# height above and distance behind; report where it does.
	var bad := {}
	var total := 0
	for up in [0.0, 5.0, 10.0, 15.0, 20.0]:
		for behind in [2.0, 3.0, 5.0, 8.0, 12.0]:
			var base := Vector3(0.0, up, behind)
			var amp: float = base.length() * tan(deg_to_rad(4.0))
			var r := _run_filter(6.0, func(t: float) -> Vector3:
				return base + Vector3(amp * sin(TAU * 0.8 * t), 0.0, 0.0), 0.9)
			total += 1
			if r["cuts"] > 1:
				bad["up%d_behind%d" % [int(up), int(behind)]] = r["cuts"]
	metric("side_latch_sweep_cuts_for_4deg_wobble", bad)
	print("[ui-verify] +-4 deg wobble, cases with >1 cut in 6 s: %d/%d %s" % [bad.size(), total, str(bad)])
	eq(bad.size(), 0, "a +-4 deg wobble behind you never flips the cue (%d of %d geometries do)" % [bad.size(), total])


func test_stoop_from_above_behind() -> void:
	# The classic hawk attack: from 25 m up and 12 m behind, stooping at the
	# player over 2.5 s along a straight line, weaving +-0.6 m sideways at
	# 1.5 Hz (a real stoop corrects its line). Count cue cuts on the way in.
	var r := _run_filter(2.5, func(t: float) -> Vector3:
		var k := t / 2.5
		var p := Vector3(0.0, 25.0, 12.0).lerp(Vector3(0.0, 1.0, 1.5), k)
		return p + Vector3(0.6 * sin(TAU * 1.5 * t), 0.0, 0.0), 0.9)
	metric("stoop_from_above_behind", r)
	print("[ui-verify] stoop from above-behind with +-0.6 m weave: ", r)
	lt(r["cuts"], 2, "a stooping hawk gives a steady threat cue (%d cuts in 2.5 s)" % r["cuts"])


func test_side_latch_elevation_threshold() -> void:
	# Bird 15 m away behind the eye plane, +-3 deg true sideways wobble:
	# the lowest elevation at which the cue starts to cut.
	var first_bad := -1.0
	var table := {}
	for e in range(0, 90, 5):
		var el := deg_to_rad(float(e))
		# 15 m out, 30 deg behind the eye plane in the vertical plane of symmetry
		var base := Vector3(0.0, 15.0 * sin(el), 15.0 * cos(el))
		var amp: float = 15.0 * tan(deg_to_rad(3.0))
		var r := _run_filter(6.0, func(t: float) -> Vector3:
			return base + Vector3(amp * sin(TAU * 0.8 * t), 0.0, 0.0), 0.9)
		table[e] = r["cuts"]
		if r["cuts"] > 1 and first_bad < 0.0:
			first_bad = e
	metric("side_latch_elevation_table_3deg", table)
	print("[ui-verify] +-3 deg wobble, cuts by elevation behind you: ", table)
	check(true, "recorded")


# --- The food chain as the UI tells it vs the loop's "worth chasing" ---------

func test_food_chain_matches_worthwhile_prey() -> void:
	var rows := {}
	var dust_total := 0
	for tier in SizeRules.SPECIES.size():
		var mass: float = SizeRules.SPECIES[tier]["mass"] * 1.05
		var chain := PauseScreen.food_chain(mass)
		var dust_as_prey: Array = []
		for i in SizeRules.SPECIES.size():
			if chain["relations"][i] == BirdIcon.Relation.PREY and not SizeRules.is_worthwhile(mass, SizeRules.SPECIES[i]["mass"]):
				dust_as_prey.append(String(SizeRules.SPECIES[i]["id"]))
		dust_total += dust_as_prey.size()
		rows[String(SizeRules.SPECIES[tier]["id"])] = {"eat_line": chain["eat_line"], "toast": "Hunt: %s" % chain["eat_text"],
			"shown_as_prey_but_not_worth_chasing": dust_as_prey}
	metric("food_chain_vs_worthwhile", rows)
	print("[ui-verify] food chain vs worthwhile: ", JSON.stringify(rows))
	eq(dust_total, 0, "pause ladder / tier-up toast never present 'not worth chasing' birds as prey (%d species-tier cases do)" % dust_total)


# --- Onboarding with no flight telemetry at all -------------------------------

func test_onboarding_without_telemetry_times_out_and_never_blocks() -> void:
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new("user://ui_r2_probe_progress.cfg")
	o.progress_store.reset_onboarding()
	add_child(o)
	o.start()
	var t := 0.0
	# (Lambdas capture locals by value: poll the node's own state instead.)
	while o.active and t < 600.0:
		o.step(0.1, {})
		t += 0.1
	var done := not o.active and o.is_done()
	metric("no_telemetry_tutorial_seconds", snappedf(t, 0.1))
	print("[ui-verify] onboarding with empty telemetry finishes after %.0f s" % t)
	check(done, "tutorial finishes by itself with no telemetry")
	lt(t, 7 * (Onboarding.TIMEOUT + Onboarding.CELEBRATE) + 1.0, "bounded by the per-lesson timeout")
	o.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ui_r2_probe_progress.cfg"))


# --- Destructive actions next to Resume --------------------------------------

func test_restart_needs_more_than_one_pull() -> void:
	# Restart run and Quit to menu throw away a run that may be 20-30 min
	# long (DESIGN pacing). Measure the spacing to Resume and whether a
	# single pull on Restart destroys the run with no confirmation.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 3)
	Events.menu_requested.emit()
	await k.settle(self, 6)
	var ps := k.ui.get_screen(&"pause")
	var resume := ps.get_button(&"resume")
	var restart := ps.get_button(&"restart")
	var gap_px := restart.get_global_rect().position.y - resume.get_global_rect().end.y
	var gap_deg := rad_to_deg(gap_px / UITheme.PX_PER_M / UITheme.PANEL_DISTANCE)
	var restarts0 := k.gl.restarts
	await k.click_control(self, restart)
	await k.settle(self, 3)
	var one_pull := k.gl.restarts - restarts0
	metric("restart_confirm", {"resume_restart_gap_deg": snappedf(gap_deg, 0.01), "restarts_after_one_pull": one_pull,
		"state_after": Game.state})
	print("[ui-verify] resume/restart gap %.2f deg; one pull on Restart -> %d restart(s), state %d" % [gap_deg, one_pull, Game.state])
	eq(one_pull, 0, "a single pull on Restart run asks for confirmation before discarding the run")
	k.teardown()
	await wait_frames(2)
