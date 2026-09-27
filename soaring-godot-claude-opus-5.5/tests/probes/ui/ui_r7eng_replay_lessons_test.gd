extends TestCase
## ENGINEERING VERIFIER PROBE (r7eng). Not part of the UI suite.
##
## The builder's test_notices_under_the_real_games_flight replays the recorded
## tutorial with ONE static lesson card ("Spread your wings") for all 34.8 s,
## so the lesson changes the real tutorial makes are never replayed. The live
## UI on the same flight (the recorder's own live_ui, and the r7eng rerun on
## the final code) fades 3 times and moves the card twice; the replay says 1
## fade, 0 moves. This probe replays the same recording the same way (the
## builder's kit, apply_game_row, the same synthetic frame order), once as the
## builder does and once with the lessons advancing when they advanced in the
## recorded game (column 12), with UIRoot's live processing order (make_way
## before the cues are re-placed), and with the rig travelling through the
## world at the recorded velocity as PlayerBird moves it (the kit never
## translates the rig); counts see-through onsets and moves each way.
##
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7eng_replay_lessons

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0


func _frame(k: Kit) -> void:
	k.ui.hud_panel.follow(SDT)
	k.ui.indicators.step(SDT)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
	k.ui.hud.advance(SDT)


## live-order: UIRoot's own _process order (make_way before the cues move,
## as UIRoot is the cues' parent and processes first).
func _frame_live_order(k: Kit) -> void:
	k.ui.hud_panel.follow(SDT)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
	k.ui.indicators.step(SDT)
	k.ui.hud.advance(SDT)


func _replay(rows: Array, lessons: bool, live_order: bool, translate := false) -> Dictionary:
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
	var ob := k.ui.onboarding
	ob.auto_step = false
	var hud := k.ui.hud
	var moves0 := hud.move_count
	var onsets: Array = []
	var moves: Array = []
	var was := false
	var mc := hud.move_count
	var t := float(r0[0])
	var t_end := float(rows[rows.size() - 1][0])
	var state := {}
	var ri := 0
	var st_frames := 0
	var frames := 0
	var last_v := Vector3.ZERO
	while t < t_end:
		if translate:
			# The rig travels with the bird, as PlayerBird moves it (the kit only yaws it).
			k.rig_parent.global_position += last_v * SDT
		var fr := k.apply_game_row(rows, t, 0.0, state)
		last_v = fr["velocity"]
		if lessons:
			# The recorded lesson index CELEBRATE s from now: complete the
			# current lesson so the next one starts when it did in the game.
			while ri < rows.size() - 1 and float(rows[ri + 1][0]) <= t + Onboarding.CELEBRATE:
				ri += 1
			var want := int(rows[ri][12])
			if ob.active and ob.celebrating <= 0.0 and want > ob.index and ob.index >= 0:
				ob.call(&"_complete", false)
			var before := ob.index
			ob.step(SDT, {})
			if ob.index != before:
				await wait_frames(1)
		if live_order:
			_frame_live_order(k)
		else:
			_frame(k)
		frames += 1
		var s: bool = hud.see_through[HUD.BAND_NOTICE] and hud.lesson_visible()
		if s:
			st_frames += 1
		if s and not was:
			onsets.append(snappedf(t, 0.01))
		was = s
		if hud.move_count != mc:
			mc = hud.move_count
			moves.append(snappedf(t, 0.01))
		t += SDT
	var out := {"lessons_replayed": lessons, "live_order": live_order, "translate": translate, "see_through_onsets": onsets,
		"moves": moves, "move_count": hud.move_count - moves0, "see_through_frac": snappedf(float(st_frames) / maxf(frames, 1), 0.001),
		"final_lesson": ob.index}
	k.end_game_replay(state)
	k.teardown()
	await wait_frames(2)
	return out


func test_tutorial_replay_static_card_vs_real_lessons() -> void:
	var rows := Kit.game_flight("tutorial")
	check(rows.size() > 500, "recorded tutorial loaded")
	var res := {}
	for v: Array in [[false, false, false], [true, true, false], [false, false, true], [false, true, true], [true, true, true]]:
		var r := await _replay(rows, v[0], v[1], v[2])
		res["lessons=%s live_order=%s translate=%s" % v] = r
		print("[ui-verify] %s" % JSON.stringify(r))
	metric("r7eng_replay_lessons", res)
	# The recorded live UI on this very flight (tests/unit/ui/ui_game_flights.json live_ui):
	# tutorial fades at 5.69 / 6.25 / 12.69, moves at 6.33 / 14.18.
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_game_flights.json"))
	var live: Dictionary = ((d as Dictionary).get("live_ui", {}) as Dictionary).get("tutorial", {})
	print("[ui-verify] recorded live_ui tutorial: %s" % JSON.stringify(live))
	var faithful := false
	for key: String in res:
		if int(res[key]["move_count"]) == (live.get("moves", []) as Array).size():
			faithful = true
	check(faithful, "some replay variant reproduces the live UI's %d moves on the same flight" % (live.get("moves", []) as Array).size())
	# The finding: the builder's replay (static rig position, cues re-placed
	# before make_way) and the live game (the rig travels; UIRoot._process
	# runs make_way before its child HudIndicators re-places the chevrons, so
	# hud_protected_directions() reads last frame's cue positions against
	# this frame's eye: at world_scale 0.14 the cue ring is 0.14 m from the
	# eye and a 6 m/s sparrow travels 0.08 m a frame, ~30 deg of error). The
	# same flight, the same sky: the extra make-way events are phantoms. This
	# fails on the round-6 code and passes once cue directions are taken in
	# the current frame.
	var base: Dictionary = res["lessons=false live_order=false translate=false"]
	var real: Dictionary = res["lessons=true live_order=true translate=true"]
	eq(int(real["move_count"]), int(base["move_count"]), "live order + travelling rig: no extra moves (phantom covers from stale cue positions)")
	eq((real["see_through_onsets"] as Array).size(), (base["see_through_onsets"] as Array).size(), "live order + travelling rig: no extra see-through onsets")
