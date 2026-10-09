extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## ui_hud_test.test_notices_under_the_real_games_flight replays the real
## game's recorded tutorial (ui_game_flights.json) and pins "1 fade, 0
## moves, read in view 99.1 %". The same flight flown live (bot seed 21, the
## recorder's own schedule; ui_r7x_live_test, and the recorder's own
## live_ui log) makes the card fade 3 times and move twice.
##
## The replay applies every recorded column except one: the lesson index
## (column 12). Its synthetic frames never step the Onboarding either, so
## the replayed card shows lesson 1 for the whole tutorial, while the live
## tutorial changes lessons six times in 20 s (each change runs UIRoot's
## zero-time make_way). This probe replays the same rows twice through the
## suite's own frame step (panel follow, cues, make_way, advance): once as
## the suite does, once with the recorded lesson changes delivered the way
## the game delivers them (Onboarding.lesson_completed, then
## lesson_started), and compares.
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7x_replay

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0


func _frame(k: Kit) -> void:
	k.ui.hud_panel.follow(SDT)
	k.ui.indicators.step(SDT)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
	k.ui.hud.advance(SDT)


func _replay(with_lessons: bool) -> Dictionary:
	var rows := Kit.game_flight("tutorial")
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.parent_rig_like_player_bird()
	k.ui.onboarding.reset()
	var r0: Array = rows[0]
	k.set_rig_heading(float(r0[1]))
	k.player.tel["body_yaw"] = deg_to_rad(float(r0[8]))
	k.set_world_scale(float(r0[11]))
	k.set_head(Vector3(0, Kit.EYE, 0), float(r0[9]))
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)
	# The replay drives the lessons itself (or not at all), never the
	# mock telemetry.
	k.ui.onboarding.auto_step = false
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	var moves0 := hud.move_count
	var fades: Array = []
	var moves: Array = []
	var lesson := int(r0[12])
	var changes := 0
	var was := false
	var seen_moves := moves0
	var st := {}
	var n := rows.size()
	var t := float(rows[0][0])
	var t_end := float(rows[n - 1][0])
	var card_frames := 0
	var readable := 0
	while t < t_end:
		k.apply_game_row(rows, t, 0.0, st)
		var ri := int(st.get("ri", 0))
		var li := int(rows[ri][12])
		if with_lessons and li != lesson:
			# The game: the old lesson's "done" beat, then the next card
			# (UIRoot places it at once with a zero-time make_way).
			if lesson >= 0:
				k.ui.onboarding.lesson_completed.emit(lesson, Onboarding.LESSONS[lesson]["id"], false)
			if li >= 0 and li < Onboarding.LESSONS.size():
				k.ui.onboarding.lesson_started.emit(li, Onboarding.LESSONS[li])
			lesson = li
			changes += 1
		_frame(k)
		t += SDT
		if hud.lesson_visible() and not hud.toast_active():
			card_frames += 1
			var a := panel.band_alpha(HUD.BAND_NOTICE)
			var faded := a < HUD.READABLE_ALPHA
			if hud.move_count != seen_moves:
				moves.append([snappedf(t, 0.01), hud.lesson_title()])
			elif faded and not was:
				fades.append([snappedf(t, 0.01), hud.lesson_title()])
			seen_moves = hud.move_count
			was = faded
			if not faded:
				readable += 1
	var r := {"lesson_changes": changes, "fades": fades, "moves": moves, "moves_total": hud.move_count - moves0,
		"readable_frac": snappedf(float(readable) / maxi(card_frames, 1), 0.001), "last_title": hud.lesson_title()}
	k.end_game_replay(st)
	k.teardown()
	await wait_frames(2)
	return r


func test_the_suites_replay_with_and_without_the_recorded_lesson_changes() -> void:
	var a := await _replay(false)
	var b := await _replay(true)
	print("[ui-verify] replay as the suite does it (no lesson changes): %s" % JSON.stringify(a))
	print("[ui-verify] replay with the recorded lesson changes: %s" % JSON.stringify(b))
	metric("replay_as_suite", a)
	metric("replay_with_lessons", b)
	eq(int(a["lesson_changes"]), 0, "the suite's replay shows one lesson throughout (%s)" % a["last_title"])
	gt(int(b["lesson_changes"]), 4, "the recording holds the tutorial's lesson changes (%d)" % b["lesson_changes"])
	# The live game (bot seed 21, ui_r7x_live_test): 3 fades, 2 moves. If the
	# lesson changes are what the suite's replay misses, the replay with them
	# lands near the live numbers; the suite's pinned "0 moves" does not
	# describe the real tutorial.
	lt((b["moves"] as Array).size(), 2, "with the lesson changes the recorded tutorial still moves the card at most once (%d)" % (b["moves"] as Array).size())
	lt((b["fades"] as Array).size(), 3, "with the lesson changes the recorded tutorial fades the card fewer than 3 times (%d)" % (b["fades"] as Array).size())
