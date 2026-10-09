extends TestCase
## U3 - game flow: the menu is reachable from every state, pause freezes
## gameplay while the UI keeps working, CAUGHT/ENDED screens appear on the
## right events, tier-ups are celebrated.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


class Ticker:
	extends Node
	## A stand-in gameplay node: pausable, counts physics ticks.
	var ticks := 0

	func _physics_process(_d: float) -> void:
		ticks += 1


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _menu() -> void:
	# Past the debounce window, so each call is a separate press.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)


func _interactive_open() -> bool:
	var s := k.ui.current_screen()
	return s != null and s.interactive and s.visible and k.ui.menu_panel.shown


func test_menu_reachable_from_every_state() -> void:
	var predator := UIMockPlayer.new()
	for st: int in [Game.State.BOOT, Game.State.MENU, Game.State.PLAYING, Game.State.PAUSED, Game.State.CAUGHT, Game.State.ENDED]:
		Game.set_state(Game.State.MENU)
		await k.settle(self, 1)
		if st == Game.State.BOOT:
			# BOOT is only ever the first state; force it for the test.
			Game.state = Game.State.BOOT
		else:
			Game.set_state(st)
		await k.settle(self, 2)
		var name_s := Game.state_name(st)
		if st in [Game.State.PLAYING, Game.State.CAUGHT]:
			await _menu()
		elif st == Game.State.BOOT:
			await _menu()
		check(_interactive_open(), "an interactive menu is open from %s (screen %s)" % [name_s, k.ui.current_screen_id()])
		check(k.ui.pointer.enabled, "pointer available from %s" % name_s)
	predator.free()


func test_pause_freezes_gameplay_but_not_ui() -> void:
	var t := Ticker.new()
	# Gameplay nodes are pausable; the test runner itself may not be.
	t.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(t)
	k.gl.start_run()
	await wait_physics(5)
	gt(t.ticks, 2, "gameplay ticks while playing")
	await _menu()
	eq(Game.state, Game.State.PAUSED, "paused")
	var frozen := t.ticks
	var rt := Game.run_time
	await wait_physics(12)
	eq(t.ticks, frozen, "gameplay node frozen while paused")
	near(Game.run_time, rt, 0.0001, "run clock frozen while paused")
	# UI keeps working: hover and click Settings, then Back, then Resume.
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"settings"))
	eq(k.ui.current_screen_id(), &"settings", "pointer navigates while paused")
	await k.click_control(self, k.ui.get_screen(&"settings").get_button(&"back"))
	eq(k.ui.current_screen_id(), &"pause", "Back returns to pause, not the main menu")
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"resume"))
	await wait_physics(4)
	gt(t.ticks, frozen, "gameplay resumes after Resume")
	t.queue_free()


func test_menu_button_toggles_pause() -> void:
	k.gl.start_run()
	await _menu()
	eq(Game.state, Game.State.PAUSED, "first press pauses")
	await _menu()
	eq(Game.state, Game.State.PLAYING, "second press resumes")


func test_menu_request_debounced() -> void:
	k.gl.start_run()
	await wait_seconds(0.3)
	# The VR area and the UI may both report the same physical press.
	Events.menu_requested.emit()
	Events.menu_requested.emit()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "two reports of one press = one toggle")


func test_controller_menu_button_pauses() -> void:
	k.gl.start_run()
	await wait_seconds(0.3)
	k.left.menu_down = true
	await k.settle(self, 2)
	k.left.menu_down = false
	await k.settle(self, 1)
	eq(Game.state, Game.State.PAUSED, "left controller menu button pauses")


func test_escape_toggles_pause_on_desktop() -> void:
	k.teardown()
	await wait_frames(2)
	k = Kit.new()
	k.setup(self, false)
	await k.settle(self, 3)
	k.gl.start_run()
	await wait_seconds(0.3)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	await k.settle(self, 3)
	eq(Game.state, Game.State.PAUSED, "Escape pauses")
	eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, "mouse visible for the menu")
	check(k.ui.menu_panel.get_node("Overlay").visible, "desktop overlay shown")
	check(not k.ui.pointer.enabled, "no laser on desktop")


func test_caught_screen_on_player_caught() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"caught", "CAUGHT shows the caught screen")
	var cs := k.ui.get_screen(&"caught") as CaughtScreen
	var who := _find_label_text(cs, "by a")
	eq(who, "by a Hawk", "names the predator's species")
	check(not k.ui.pointer.enabled, "caught screen is informational (no laser)")
	check(not k.ui.hud_panel.shown, "HUD hidden while caught")
	var c0 := cs.countdown_text()
	check(c0.contains("3"), "countdown starts at the respawn delay (%s)" % c0)
	await wait_seconds(1.2)
	var c1 := cs.countdown_text()
	check(c1.contains("2") or c1.contains("1"), "countdown runs (%s)" % c1)
	# Pause while caught, resume returns to CAUGHT, not PLAYING.
	await _menu()
	eq(Game.state, Game.State.PAUSED, "menu button pauses from CAUGHT")
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"resume"))
	eq(Game.state, Game.State.CAUGHT, "resume goes back to the caught screen")
	# GameLoop respawns: back to play, screen closes.
	Game.set_state(Game.State.PLAYING)
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"", "respawn closes the caught screen")
	hawk.free()


func test_lives_shown_on_caught_screen() -> void:
	k.gl.start_run()
	k.gl.stats["lives"] = 2
	var gull := UIMockPlayer.new()
	gull.species = &"gull"
	k.gl.fake_caught(gull)
	await k.settle(self, 2)
	var cs := k.ui.get_screen(&"caught") as CaughtScreen
	var pips := cs.lives_shown()
	eq(pips.y, 3, "lives_max pips")
	eq(pips.x, 1, "one life left after being caught with 2")
	gull.free()


func test_summary_on_run_end() -> void:
	k.gl.start_run()
	k.gl.fake_catch(&"moth")
	k.gl.fake_catch(&"moth")
	k.gl.fake_catch(&"wren")
	k.gl.fake_end({"score": 4200, "max_mass": 0.4, "time": 312.0})
	await k.settle(self, 3)
	eq(k.ui.current_screen_id(), &"summary", "ENDED shows the run summary")
	var ss := k.ui.get_screen(&"summary")
	eq(_find_label_text(ss, "You reached"), "You reached Pigeon", "headline names the top size")
	check(_has_label(ss, "5:12"), "time shown")
	check(_has_label(ss, "4 200"), "score shown with grouping")
	check(_has_label(ss, "Moth ×2") and _has_label(ss, "Wren ×1"), "catches by species")
	check((ss.get_node("Margin").find_child("NewBest", true, false) as Label).visible, "first score is a new best")
	eq(k.ui.progress.best_score(), 4200, "best score persisted")
	# Fly again starts a new run.
	await k.click_control(self, ss.get_button(&"again"))
	eq(Game.state, Game.State.PLAYING, "Fly again starts a run")
	eq(k.gl.starts, 2, "second run started")


func test_menu_button_on_the_summary_goes_to_the_main_menu() -> void:
	# The run is over: the menu button (or Escape) leaves the summary for the
	# main menu, and a second press there keeps the main menu up.
	k.gl.start_run()
	await k.settle(self, 2)
	k.gl.fake_end({"score": 10})
	await k.settle(self, 3)
	eq(k.ui.current_screen_id(), &"summary", "summary up")
	await _menu()
	eq(Game.state, Game.State.MENU, "menu button on the summary -> MENU")
	eq(k.ui.current_screen_id(), &"main", "main menu shown")
	check(not get_tree().paused, "nothing left paused")
	await _menu()
	eq(k.ui.current_screen_id(), &"main", "a second press keeps the main menu")


func test_tier_up_celebration() -> void:
	# No lesson card: its animation would keep the HUD rendering on its own.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	var r0 := k.ui.hud_panel.render_requests
	Events.player_tier_changed.emit(2, 5)
	await k.settle(self, 2)
	check(k.ui.hud.toast_active(), "tier-up toast shown")
	eq(k.ui.hud.toast_text(), "Now a Pigeon!", "toast names the new species")
	var f0 := Engine.get_process_frames()
	await wait_seconds(0.5)
	var frames := Engine.get_process_frames() - f0
	gt(k.ui.hud_panel.render_requests - r0, frames - 2, "HUD animates the celebration: a render every frame (%d in %d frames)" % [k.ui.hud_panel.render_requests - r0, frames])
	# The rest of its 3.2 s in synthetic time (the HUD's own clock).
	k.ui.hud.set_process(false)
	for i in 72 * 3:
		k.ui.hud.advance(1.0 / 72.0)
	check(not k.ui.hud.toast_active(), "toast gone after its 3.2 s")
	await k.settle(self, 2)
	var r1 := k.ui.hud_panel.render_requests
	await wait_frames(30)
	eq(k.ui.hud_panel.render_requests, r1, "HUD stops rendering once the toast is gone")
	k.ui.hud.set_process(true)


## The round-7 verifier: a pause (the menu button, or the headset losing
## focus) half a second into a tier-up lost the celebration. A pause now
## keeps it: its clock waits while the HUD is hidden (nothing renders
## meanwhile), and after Resume it plays out. Being caught ends it (the
## caught screen is its own moment; it must not replay into the next
## flight).
func test_a_pause_keeps_a_celebration_for_after_resume() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	Events.player_tier_changed.emit(2, 3)
	await k.settle(self, 2)
	var hud := k.ui.hud
	hud.set_process(false)
	for i in 36:
		hud.advance(1.0 / 72.0)
	check(hud.toast_active(), "the celebration is up, 0.5 s in")
	await _menu()
	eq(Game.state, Game.State.PAUSED, "paused")
	var r0 := k.ui.hud_panel.render_requests
	for i in 72 * 10:
		hud.advance(1.0 / 72.0)
	check(hud.toast_waiting() and not hud.toast_active(), "10 s of pause later it is still waiting (not running: the HUD is hidden)")
	near(hud.toast_held(), 0.0, 1e-6, "and its hold budget was not spent on the pause")
	eq(k.ui.hud_panel.render_requests, r0, "nothing rendered for it while the HUD was hidden")
	k.ui.resume()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PLAYING, "resumed")
	check(hud.toast_active(), "after Resume the celebration is back")
	eq(hud.toast_text(), "Now a Swallow!", "the same one")
	var left := 0.0
	while hud.toast_active() and left < 10.0:
		hud.advance(1.0 / 72.0)
		left += 1.0 / 72.0
	between(left, HUD.TOAST_TIME - 0.5 - 0.05, HUD.TOAST_TIME - 0.5 + HUD.TOAST_HOLD_MAX + 0.05,
		"and plays out the rest of its time (%.2f s)" % left)
	# Caught mid-celebration: over.
	Events.player_tier_changed.emit(3, 4)
	await k.settle(self, 2)
	check(hud.toast_active(), "a second celebration")
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await k.settle(self, 2)
	check(not hud.toast_active(), "being caught ends it")
	hud.set_process(true)
	hawk.free()


func test_quit_button_calls_quit() -> void:
	var quit := k.ui.get_screen(&"main").get_button(&"quit")
	check(quit is HoldButton, "the main menu's Quit is a hold (the resting laser lies on it in the headset)")
	await k.click_control(self, quit)
	eq(k.quits, 0, "a single pull on Quit does not quit")
	eq((quit as HoldButton).text, "Hold to quit", "...it says how it works")
	await k.hold_control(self, quit)
	eq(k.quits, 1, "holding Quit quits the app")


func _find_label_text(root: Node, prefix: String) -> String:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text.begins_with(prefix):
			return (l as Label).text
	return ""


func _has_label(root: Node, text: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).visible and (l as Label).text == text:
			return true
	return false


# --- the menu keeps working while the game is paused ---------------------------

func test_ui_root_runs_while_paused() -> void:
	eq(k.ui.process_mode, Node.PROCESS_MODE_ALWAYS, "UIRoot is PROCESS_MODE_ALWAYS")
	for n: Node in [k.ui.menu_panel, k.ui.hud_panel, k.ui.pointer, k.ui.indicators]:
		eq(n.process_mode, Node.PROCESS_MODE_ALWAYS, "%s runs while paused" % n.name)
	# Onboarding is gameplay: it must freeze with the game.
	eq(k.ui.onboarding.process_mode, Node.PROCESS_MODE_PAUSABLE, "lessons freeze while paused")


func test_controller_menu_button_resumes_while_paused() -> void:
	k.gl.start_run()
	await wait_seconds(0.3)
	k.left.menu_down = true
	await k.settle(self, 2)
	k.left.menu_down = false
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "menu button pauses")
	check(get_tree().paused, "tree paused")
	await wait_seconds(0.3)
	k.left.menu_down = true
	await k.settle(self, 2)
	k.left.menu_down = false
	await k.settle(self, 2)
	eq(Game.state, Game.State.PLAYING, "the same button, pressed while paused, resumes")


func test_back_button_pops_while_paused() -> void:
	k.gl.start_run()
	await _menu()
	k.ui.push_screen(&"settings")
	await k.settle(self, 2)
	k.right.back_down = true
	await k.settle(self, 2)
	k.right.back_down = false
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"pause", "B/Y pops Settings back to Pause while the tree is paused")


func test_escape_resumes_on_desktop() -> void:
	k.teardown()
	await wait_frames(2)
	k = Kit.new()
	k.setup(self, false)
	await k.settle(self, 3)
	k.gl.start_run()
	for want: int in [Game.State.PAUSED, Game.State.PLAYING]:
		await wait_seconds(0.3)
		var ev := InputEventKey.new()
		ev.keycode = KEY_ESCAPE
		ev.pressed = true
		Input.parse_input_event(ev)
		await k.settle(self, 3)
		eq(Game.state, want, "Escape toggles to %s" % Game.state_name(want))


func test_headset_focus_loss_pauses() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	VR.session_unfocused.emit()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "taking the headset off / opening the system menu pauses the run")
	eq(k.ui.current_screen_id(), &"pause", "and the pause menu is waiting")
	Game.set_state(Game.State.MENU)
	await k.settle(self, 2)
	VR.session_unfocused.emit()
	await k.settle(self, 2)
	eq(Game.state, Game.State.MENU, "no effect outside a run")


# --- content honesty -------------------------------------------------------------

func test_summary_best_rules() -> void:
	# GameLoop's records win when present; otherwise UI's own file.
	var cases := [
		# summary, stats, prior_ui -> new_best, best
		[{"score": 3000, "new_records": {"score": false}, "records": {"best_score": 5000}}, {}, 0, false, 5000],
		[{"score": 7000, "new_records": {"score": true}, "records": {"best_score": 7000}}, {}, 9000, true, 7000],
		[{"score": 5500}, {"best_score": 6000}, 0, false, 6000],
		[{"score": 6500}, {"best_score": 6000}, 4000, true, 6500],
		[{"score": 800}, {}, 1200, false, 1200],
		[{"score": 0}, {}, 0, false, 0],
		# A tie is not a new best, against UI's file or GameLoop's stats.
		[{"score": 1200}, {}, 1200, false, 1200],
		[{"score": 6000}, {"best_score": 6000}, 0, false, 6000],
		[{"score": 6000}, {}, 0, true, 6000],
	]
	for c: Array in cases:
		var r := UIRoot.summary_best(c[0], c[1], c[2])
		eq(r["new_best"], c[3], "new best for %s / %s / ui %d" % [c[0], c[1], c[2]])
		eq(r["best"], c[4], "best shown for %s / %s / ui %d" % [c[0], c[1], c[2]])
		# The badge and the number can never disagree.
		if r["new_best"]:
			eq(r["best"], int(c[0]["score"]), "a new best is this run's score")
		else:
			check(r["best"] >= int(c[0]["score"]), "no badge: the best is at least this score")


func test_the_fallback_best_score_is_saved() -> void:
	# Without a GameLoop keeping records, UIProgress's file is the record: a
	# better score is written to disk (a new session reads it back), a worse
	# one or a tie changes nothing.
	var path := "user://ui_flow_best_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var pr := UIProgress.new(path)
	check(pr.submit_score(4200), "4200 on a fresh file is a new best")
	eq(UIProgress.new(path).best_score(), 4200, "and a new session reads it from disk")
	check(not pr.submit_score(4200), "a tie is not")
	check(not pr.submit_score(3000), "nor a lower score")
	eq(UIProgress.new(path).best_score(), 4200, "the file still holds 4200")
	check(pr.submit_score(5100), "5100 is")
	eq(UIProgress.new(path).best_score(), 5100, "and it is saved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_new_best_badge_agrees_with_game_loop_records() -> void:
	# The real GameLoop also saves bests for runs quit to the menu (no
	# summary), so its record can be ahead of UI's file.
	k.ui.bridge.stats_provider = func() -> Dictionary: return {"best_score": 6000, "lives": 0, "lives_max": 3}
	Game.set_state(Game.State.PLAYING)
	await k.settle(self, 2)
	Game.set_state(Game.State.ENDED)
	Events.run_ended.emit({"score": 5500, "time": 300.0, "max_mass": 0.3, "catches_by_species": {}})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	check(_has_label(ss, "6 000"), "Best shows GameLoop's 6 000")
	check(not (ss.find_child("NewBest", true, false) as Label).is_visible_in_tree(), "no 'New best!' for 5 500")
	# And with GameLoop's own verdict in the summary.
	Game.set_state(Game.State.PLAYING)
	await k.settle(self, 2)
	Game.set_state(Game.State.ENDED)
	Events.run_ended.emit({"score": 7000, "time": 300.0, "max_mass": 0.3, "new_records": {"score": true}, "records": {"best_score": 7000}})
	await k.settle(self, 3)
	check((ss.find_child("NewBest", true, false) as Label).is_visible_in_tree(), "GameLoop says new record: badge shown")
	check(_has_label(ss, "7 000") and not _has_label(ss, "6 000"), "and Best is the new 7 000")
	k.ui.bridge.stats_provider = Callable()


func test_articles_read_right() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var eagle := UIMockPlayer.new()
	eagle.species = &"eagle"
	k.gl.fake_caught(eagle)
	await k.settle(self, 2)
	eq(_find_label_text(k.ui.get_screen(&"caught"), "by "), "by an Eagle", "caught by an Eagle")
	var ps := k.ui.get_screen(&"pause") as PauseScreen
	var ctx := k.ui.context()
	ctx["player_mass"] = float(SizeRules.SPECIES[8]["mass"]) * 1.05
	ps.refresh(ctx)
	check(_has_label(ps, "Growing into an Eagle"), "a hawk is growing into an Eagle")
	ctx["player_mass"] = float(SizeRules.SPECIES[9]["mass"]) * 1.05
	ps.refresh(ctx)
	check(_has_label(ps, "You are an Eagle"), "You are an Eagle")
	ctx["player_mass"] = float(SizeRules.SPECIES[6]["mass"]) * 1.05
	ps.refresh(ctx)
	check(_has_label(ps, "You are a Crow"), "You are a Crow")
	eq(UIScreen.a_an("Owl"), "an Owl", "helper: vowel")
	eq(UIScreen.a_an("Hawk"), "a Hawk", "helper: consonant")
	eagle.free()


func test_pause_tip_is_stable_while_browsing_and_new_per_pause() -> void:
	k.gl.start_run()
	await _menu()
	var ps := k.ui.get_screen(&"pause") as PauseScreen
	var t1 := ps.tip_text()
	k.ui.push_screen(&"settings")
	await k.settle(self, 2)
	k.ui.pop_screen()
	await k.settle(self, 2)
	eq(ps.tip_text(), t1, "coming back from Settings shows the same tip")
	k.ui.onboarding.skip()
	await k.click_control(self, ps.get_button(&"resume"))
	await _menu()
	check(ps.tip_text() != t1, "the next pause shows a new tip")


func test_choice_toggle_shows_exactly_one_option_after_an_outside_change() -> void:
	Settings.set_value("seated", false)
	k.ui.push_screen(&"settings")
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	var standing := ss.get_stance().get_option_button("standing")
	var seated := ss.get_stance().get_option_button("seated")
	check(standing.button_pressed and not seated.button_pressed, "standing selected")
	k.ui.pop_screen()
	await k.settle(self, 2)
	# VR calibration (or anything else) flips the setting while Settings is shut.
	Settings.set_value("seated", true)
	k.ui.push_screen(&"settings")
	await k.settle(self, 3)
	check(seated.button_pressed, "seated shown as selected")
	check(not standing.button_pressed, "standing released: exactly one option lit")


func test_settings_actions_say_what_they_did() -> void:
	await k.click_control(self, k.ui.get_screen(&"main").get_button(&"settings"))
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	eq(ss.status_text(), "", "no status to begin with")
	k.ui.onboarding.skip()
	await k.click_control(self, ss.get_button(&"replay_tutorial"))
	check(ss.status_text().contains("Tutorial"), "Replay tutorial confirms (%s)" % ss.status_text())
	check(not k.ui.onboarding.is_done(), "and the lessons really are back")
	await k.click_control(self, ss.get_button(&"recalibrate"))
	check(ss.status_text().contains("Recalibration"), "Recalibrate confirms (%s)" % ss.status_text())
	await k.click_control(self, ss.get_button(&"recenter"))
	check(ss.status_text().contains("recentered"), "Recenter confirms (%s)" % ss.status_text())


func test_summary_lists_biggest_prey_first_and_counts_the_rest() -> void:
	var by := {}
	for i in 9:
		by[SizeRules.SPECIES[i]["id"]] = i + 1
	k.gl.start_run()
	k.gl.fake_end({"score": 500, "max_mass": 3.2, "max_tier": 9, "catches_by_species": by})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	check(_has_label(ss, "Hawk ×9"), "biggest prey listed")
	check(_has_label(ss, "+4 more species"), "the species that did not fit are counted, not dropped")
	check(not _has_label(ss, "Moth ×1"), "smallest prey folded into the count")
	check(_has_label(ss, "3.2 kg"), "peak size shown")
	eq((ss.find_child("PeakBird", true, false) as BirdIcon).species, &"eagle", "headline bird is the peak species")


# --- the loop as the UI tells it: worthwhile prey, and the apex goal ------------

func test_food_chain_presents_only_worthwhile_prey_at_every_size() -> void:
	# "The player starts to ignore the smallest birds": what the pause ladder
	# and the tier-up toast call prey must be exactly what GameLoop's
	# highlights, target cue and apex count call worth chasing.
	var wrong := 0
	var rows := {}
	for tier in SizeRules.SPECIES.size():
		for f: float in [1.0, 1.05, 1.2]:
			var mass: float = SizeRules.SPECIES[tier]["mass"] * f
			if SizeRules.tier_for_mass(mass) != tier:
				continue
			var chain := PauseScreen.food_chain(mass)
			var hunt: Array[int] = []
			var dust: Array[int] = []
			for i in SizeRules.SPECIES.size():
				var m: float = SizeRules.SPECIES[i]["mass"]
				var rel: int = chain["relations"][i]
				var worth := SizeRules.is_worthwhile(mass, m)
				var edible := SizeRules.can_eat(mass, m)
				if i != tier and rel == BirdIcon.Relation.PREY and not worth:
					wrong += 1
				if i != tier and worth:
					hunt.append(i)
					eq(rel, BirdIcon.Relation.PREY, "%s at %.3f kg: worthwhile %s shown as prey" % [SizeRules.SPECIES[tier]["id"], mass, SizeRules.SPECIES[i]["id"]])
				elif i != tier and edible:
					dust.append(i)
					eq(rel, BirdIcon.Relation.DUST, "%s at %.3f kg: %s is too small to bother (DUST)" % [SizeRules.SPECIES[tier]["id"], mass, SizeRules.SPECIES[i]["id"]])
			eq(chain["eat_line"], ("Hunt: %s" % PauseScreen.species_range(hunt)) if not hunt.is_empty() else "Nothing to hunt yet",
				"hunt line names exactly the worthwhile range at %.3f kg" % mass)
			eq(chain["ignore_line"], ("Ignore: %s" % PauseScreen.species_range(dust)) if not dust.is_empty() else "",
				"ignore line names exactly the too-small range at %.3f kg" % mass)
			rows["%s x%.2f" % [SizeRules.SPECIES[tier]["id"], f]] = [chain["eat_line"], chain["ignore_line"], chain["flee_line"]]
	metric("food_chain_lines", rows)
	eq(wrong, 0, "no species that is not worth chasing is ever presented as prey")
	# Spot checks against the verifier's examples.
	eq(PauseScreen.food_chain(1.3 * 1.05)["eat_line"], "Hunt: Pigeon–Gull", "a hawk hunts pigeons to gulls, not moths")
	eq(PauseScreen.food_chain(1.3 * 1.05)["ignore_line"], "Ignore: Moth–Starling", "and ignores the small fry")
	eq(PauseScreen.food_chain(0.03)["ignore_line"], "", "a sparrow ignores nothing it can eat")


func test_tier_up_toast_names_the_worthwhile_range_and_what_dropped_off() -> void:
	var texts := {}
	for tier in range(1, SizeRules.SPECIES.size()):
		var mass: float = SizeRules.SPECIES[tier]["mass"] * 1.01
		var t := HUD.tier_up_text(tier - 1, tier, mass, {"catches": 0, "needed": 5, "won": false})
		texts[String(SizeRules.SPECIES[tier]["id"])] = [t["title"], t["sub"], t["note"]]
		var chain := PauseScreen.food_chain(mass)
		var lines := "%s %s" % [t["sub"], t["note"]]
		# Never tells a bird to hunt something not worth chasing.
		for i: int in chain["dust"]:
			check(not String(t["sub"]).contains(SizeRules.SPECIES[i]["name"]) or String(t["sub"]).begins_with("Catch"),
				"tier %d toast does not send you after %s ('%s')" % [tier, SizeRules.SPECIES[i]["id"], t["sub"]])
		if tier < SizeRules.SPECIES.size() - 1:
			eq(t["sub"], chain["eat_line"], "tier %d toast: the worthwhile range" % tier)
			# What was worth it at the old size and is not any more.
			var before := PauseScreen.food_chain(SizeRules.SPECIES[tier - 1]["mass"])
			var dropped: Array[int] = []
			for i: int in before["prey"]:
				if i in chain["dust"]:
					dropped.append(i)
			eq(t["note"], ("Ignore: %s" % PauseScreen.species_range(dropped)) if not dropped.is_empty() else "",
				"tier %d toast names what dropped off the menu" % tier)
		metric("toast_%d" % tier, lines)
	metric("tier_up_texts", texts)
	var hawk := HUD.tier_up_text(7, 8, 1.3 * 1.01)
	eq(hawk["sub"], "Hunt: Pigeon–Gull", "becoming a hawk: hunt pigeons to gulls (not 'Gull & smaller')")
	eq(hawk["note"], "Ignore: Starling", "and starlings just dropped off the menu")
	var eagle := HUD.tier_up_text(8, 9, 3.0 * 1.01, {"catches": 0, "needed": 5, "won": false})
	eq(eagle["title"], "Eagle!", "apex title")
	eq(eagle["sub"], "Catch 5 big birds to win", "the eagle toast states the real goal (GameLoop's apex count)")
	eq(eagle["note"], "Hunt: Crow–Hawk", "and what counts toward it")
	check(not str(eagle).contains("Stay there"), "not the old 'Top of the sky. Stay there.'")
	var down := HUD.tier_up_text(5, 4, 0.1)
	eq(down["title"], "Back to a Starling", "shrinking says so")


func test_apex_goal_on_hud_and_pause() -> void:
	k.ui.onboarding.skip()
	k.player.mass = 3.1
	k.gl.start_run()
	await k.settle(self, 3)
	eq(k.ui.hud.next_text(), "0 of 5 to win", "at the eagle the strip shows the apex goal, not a full 'Apex' bar")
	near(k.ui.hud.growth_value(), 0.0, 1e-4, "goal bar empty")
	k.gl.fake_apex_catch()
	k.gl.fake_apex_catch()
	await k.settle(self, 3)
	eq(k.ui.hud.next_text(), "2 of 5 to win", "apex_progress updates the strip")
	near(k.ui.hud.growth_value(), 0.4, 1e-4, "goal bar 2/5")
	check(k.ui.hud.toast_active(), "a big catch at the top is celebrated")
	eq(k.ui.hud.toast_text(), "2 of 5!", "the toast counts toward the goal")
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var ps := k.ui.get_screen(&"pause")
	check(_has_label(ps, "Apex hunt: 2 of 5"), "the pause screen shows the apex goal")
	check(_has_label(ps, "Hunt: Crow–Hawk"), "and which birds count")
	check(_has_label(ps, "Ignore: Moth–Pigeon"), "and which to ignore")
	k.ui.resume()
	await k.settle(self, 2)
	# The goal also shows without the signal (GameLoop's stats alone).
	k.ui.hud.set_apex({})
	k.ui._refresh_apex()
	eq(k.ui.hud.next_text(), "2 of 5 to win", "read back from get_run_stats()['apex']")


func test_victory_is_a_victory_and_keep_flying_continues_the_run() -> void:
	k.ui.onboarding.skip()
	k.player.mass = 3.1
	k.gl.start_run()
	await k.settle(self, 3)
	await wait_seconds(0.3)
	var t_run := Game.run_time
	for i in 5:
		k.gl.fake_apex_catch()
	await k.settle(self, 3)
	eq(Game.state, Game.State.ENDED, "the fifth big catch ends the run")
	eq(k.ui.current_screen_id(), &"summary", "summary shown")
	var ss := k.ui.get_screen(&"summary") as SummaryScreen
	check(ss.victory_shown(), "the summary knows it is a victory")
	check(_has_label(ss, "Victory! You rule the sky"), "and says so")
	var shown := []
	for id in ss.button_ids():
		if ss.get_button(id).is_visible_in_tree():
			shown.append(ss.get_button(id).text)
	metric("victory_buttons", shown)
	eq(shown, ["Keep flying", "Fly again", "Main menu"], "a victory offers the victory lap first")
	# Keep flying = GameLoop.continue_after_victory(): same run, same clock.
	await k.click_control(self, ss.get_button(&"keep_flying"))
	eq(k.gl.continues, 1, "GameLoop.continue_after_victory called")
	eq(Game.state, Game.State.PLAYING, "back in the air")
	gt(Game.run_time, t_run * 0.99, "same run: the clock was not reset")
	check(k.ui.hud_panel.shown, "HUD back")
	eq(k.ui.hud.next_text(), "You won!", "the strip shows the run was won")
	# An ordinary apex run (no victory) has no Keep flying.
	k.gl.fake_end({"score": 900, "max_mass": 3.2, "max_tier": 9})
	await k.settle(self, 3)
	check(not ss.victory_shown(), "a run end without victory is not a victory")
	check(not ss.get_button(&"keep_flying").is_visible_in_tree(), "no Keep flying without a victory")
	check(_has_label(ss, "Apex! You became the Eagle"), "apex headline")


func test_keep_flying_without_a_game_loop_keeps_the_clock() -> void:
	k.gl.remove_from_group(&"game_loop")
	Game.set_state(Game.State.PLAYING)
	await wait_seconds(0.15)
	Game.set_state(Game.State.ENDED)
	var t := Game.run_time
	k.ui.bridge.continue_after_victory()
	eq(Game.state, Game.State.PLAYING, "fallback: back to PLAYING")
	near(Game.run_time, t, 1e-4, "fallback keeps the run clock")
	k.gl.add_to_group(&"game_loop")


func test_new_best_replaces_the_best_column() -> void:
	# A new record: Score's caption becomes "New best!" and the Best column,
	# which would only repeat the same number, is dropped.
	k.gl.start_run()
	k.gl.fake_end({"score": 98765, "max_mass": 3.2, "max_tier": 9, "new_records": {"score": true}, "records": {"best_score": 98765}})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	var badge := ss.find_child("NewBest", true, false) as Label
	check(badge.is_visible_in_tree(), "badge shown")
	var count := 0
	for l in ss.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree() and (l as Label).text == "98 765":
			count += 1
	eq(count, 1, "the score is shown once, not twice side by side")
	# Not a record: Score and Best columns, separated by a rule.
	Game.set_state(Game.State.MENU)
	k.gl.start_run()
	k.gl.fake_end({"score": 98765, "max_mass": 0.3, "new_records": {"score": false}, "records": {"best_score": 123456}})
	await k.settle(self, 3)
	check(not badge.is_visible_in_tree(), "no badge")
	check(_has_label(ss, "98 765") and _has_label(ss, "123 456"), "score and best both shown")
	var stats := ss.find_child("Stats", true, false) as Control
	var rules := 0
	for c in stats.get_children():
		if c is ColorRect and (c as ColorRect).is_visible_in_tree():
			rules += 1
	eq(rules, 3, "a rule between each of the four stat columns")
	# Neighbouring values never run together: >= 70 px between them.
	var vals: Array[Label] = []
	for l in ss.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree() and (l as Label).text in ["98 765", "123 456"]:
			vals.append(l)
	vals.sort_custom(func(a: Label, b: Label) -> bool: return a.get_global_rect().position.x < b.get_global_rect().position.x)
	var f := vals[0].get_theme_font("font")
	var fs := vals[0].get_theme_font_size("font_size")
	var gap := vals[1].get_global_rect().position.x - (vals[0].get_global_rect().position.x + f.get_string_size(vals[0].text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	metric("score_best_gap_px", gap)
	# Two full gaps and a rule at least (the verifier measured ~40 px, no rule).
	gt(gap, 2.0 * SummaryScreen.STAT_GAP + SummaryScreen.DIVIDER_W - 1.0, "Score and Best values are clearly apart (%.0f px)" % gap)
	var rule := stats.get_child(stats.get_children().find(vals[1].get_parent()) - 1) as ColorRect
	check(rule != null and rule.is_visible_in_tree(), "with a rule between them")


# --- behaviours that must not silently break ------------------------------------

func test_lesson_card_goes_when_the_tutorial_ends() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	check(k.ui.hud.lesson_visible(), "lesson card up during the first flight")
	check(k.ui.hud_panel.is_band_visible(HUD.BAND_NOTICE), "notice band drawn")
	k.ui.onboarding.skip()
	await k.settle(self, 3)
	check(not k.ui.hud.lesson_visible(), "Skip tutorial takes the lesson card down")
	check(not k.ui.hud_panel.is_band_visible(HUD.BAND_NOTICE), "and the empty notice band is not drawn at all")
	var r0 := k.ui.hud_panel.render_requests
	await wait_seconds(0.3)
	eq(k.ui.hud_panel.render_requests, r0, "no lesson animation keeps the HUD rendering afterwards")
	# Finishing the last lesson does the same.
	k.ui.onboarding.reset()
	k.ui.onboarding.start()
	await k.settle(self, 2)
	check(k.ui.hud.lesson_visible(), "lessons replayed")
	k.ui.onboarding.index = Onboarding.LESSONS.size() - 1
	k.ui.onboarding._begin(Onboarding.LESSONS.size())
	await k.settle(self, 2)
	check(not k.ui.hud.lesson_visible(), "the card goes after the last lesson")


func test_cues_are_off_while_any_menu_is_up() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	var head := k.cam.global_transform
	prey.global_position = head.origin + head.basis * Vector3(-8, 0, -1)
	Events.target_changed.emit(prey)
	await wait_seconds(0.5)
	check(k.ui.indicators.active and k.ui.indicators.cue_mesh(&"target").visible, "target cue up in flight")
	for st: int in [Game.State.PAUSED, Game.State.CAUGHT, Game.State.ENDED, Game.State.MENU]:
		Game.set_state(Game.State.PLAYING)
		await k.settle(self, 2)
		Game.set_state(st)
		await k.settle(self, 3)
		check(not k.ui.indicators.active, "cues inactive in %s" % Game.state_name(st))
		check(not k.ui.indicators.cue_mesh(&"target").visible, "no chevron drawn around the %s screen" % Game.state_name(st))
	Events.target_changed.emit(null)
	prey.queue_free()


func test_headset_focus_loss_pauses_while_caught() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await k.settle(self, 2)
	VR.session_unfocused.emit()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "focus loss pauses the caught beat too")
	k.ui.resume()
	await k.settle(self, 2)
	eq(Game.state, Game.State.CAUGHT, "and resumes into it")
	hawk.free()


func test_caught_countdown_survives_a_pause() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await wait_seconds(0.5)
	var left := k.ui._caught_left
	lt(left, 2.7, "countdown ran (%.2f s left)" % left)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	await wait_seconds(0.5)
	k.ui.resume()
	await k.settle(self, 2)
	eq(Game.state, Game.State.CAUGHT, "back to the caught screen")
	lt(k.ui._caught_left, left + 0.05, "pausing does not restart the respawn countdown (%.2f s left)" % k.ui._caught_left)
	gt(k.ui._caught_left, left - 0.3, "and it did not run on while paused")
	hawk.free()


class FakeModel:
	extends Node3D
	var highlight := 0


class ModelBird:
	extends Bird
	var model := FakeModel.new()


func test_target_and_threat_are_highlighted_on_the_bird() -> void:
	# Duck-typed: any bird with a `model` that has `highlight` (BirdModel).
	var prey := ModelBird.new()
	var hawk := ModelBird.new()
	add_child(prey)
	add_child(hawk)
	Events.target_changed.emit(prey)
	eq(prey.model.highlight, 1, "the target is tinted as prey")
	Events.threat_changed.emit(0.5, hawk)
	eq(hawk.model.highlight, 2, "a real threat is tinted as danger")
	Events.threat_changed.emit(0.05, hawk)
	eq(hawk.model.highlight, 0, "a distant one is not")
	# One threshold for "real" everywhere: the tint and the HUD making way
	# agree at the boundary (0.1 counts, just under it does not).
	Events.threat_changed.emit(0.1, hawk)
	eq(hawk.model.highlight, 2, "a threat at exactly 0.1 is tinted")
	check(UIRoot.is_real_threat(0.1) and not UIRoot.is_real_threat(0.0999), "and is what the HUD makes way for")
	Events.threat_changed.emit(0.0999, hawk)
	eq(hawk.model.highlight, 0, "just under it is not")
	Events.target_changed.emit(null)
	eq(prey.model.highlight, 0, "a dropped target loses its tint")
	Events.threat_changed.emit(0.0, null)
	prey.model.free()
	hawk.model.free()
	prey.queue_free()
	hawk.queue_free()


func test_a_freed_target_or_threat_never_stops_the_cues() -> void:
	# A target or threat bird freed before the next *_changed event (a
	# despawn, a pooled NPC): round 4 raised a script error in the typed
	# highlight call on every later event, so UIRoot kept the dead bird and
	# the next targets and threats got no cue and no tint for the session.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	var eye := k.cam.global_position
	var prey := ModelBird.new()
	var hawk := ModelBird.new()
	add_child(prey)
	add_child(hawk)
	prey.global_position = eye + Vector3(-6, 2, -8)
	hawk.global_position = eye + Vector3(4, 1, 9)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.9, hawk)
	await k.settle(self, 2)
	prey.model.free()
	hawk.model.free()
	prey.free()
	hawk.free()
	await k.settle(self, 2)
	var dirs := k.ui.hud_protected_directions()
	check(dirs.size() <= 3, "freed birds are no longer protected directions (%d: path and fading cues at most)" % dirs.size())
	var b := ModelBird.new()
	var h := ModelBird.new()
	add_child(b)
	add_child(h)
	b.global_position = eye + Vector3(8, 0.5, -3)
	h.global_position = eye + Vector3(-5, 1, 8)
	Events.target_changed.emit(b)
	Events.threat_changed.emit(0.9, h)
	await wait_seconds(0.4)
	check(k.ui.get(&"_target") == b, "the next target is taken")
	check(k.ui.get(&"_threat") == h, "the next threat is taken")
	eq(b.model.highlight, 1, "and tinted as prey")
	eq(h.model.highlight, 2, "and as danger")
	check(k.ui.indicators.cue_mesh(&"target").visible, "the next target gets a cue")
	check(k.ui.indicators.cue_mesh(&"threat").visible, "the next threat gets a cue")
	# And the one after that.
	var c := ModelBird.new()
	add_child(c)
	c.global_position = eye + Vector3(-8, 0.5, -3)
	Events.target_changed.emit(c)
	eq(b.model.highlight, 0, "the old target loses its tint")
	eq(c.model.highlight, 1, "the new one gets it")
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	for n: ModelBird in [b, h, c]:
		n.model.free()
		n.queue_free()


func test_out_of_lives_on_the_caught_screen() -> void:
	k.gl.start_run()
	k.gl.stats["lives"] = 1
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await k.settle(self, 2)
	var cs := k.ui.get_screen(&"caught") as CaughtScreen
	eq(cs.lives_shown(), Vector2i(0, 3), "no life left: three hollow pips")
	eq(cs.countdown_text(), "Out of lives", "and it says so instead of a respawn countdown")
	hawk.free()


func test_menu_button_on_a_menu_sub_screen_goes_back_to_the_main_menu() -> void:
	eq(k.ui.current_screen_id(), &"main", "main menu")
	k.ui.push_screen(&"settings")
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"settings", "settings open from the main menu")
	await _menu()
	eq(k.ui.current_screen_id(), &"main", "the menu button returns to the main menu")
	eq(k.ui.stack.size(), 1, "with nothing left underneath")
	eq(Game.state, Game.State.MENU, "still in the menu")


func test_settings_status_line_clears_after_its_time() -> void:
	await k.click_control(self, k.ui.get_screen(&"main").get_button(&"settings"))
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	ss.set_process(false)
	await k.click_control(self, ss.get_button(&"recenter"))
	ss.set_process(false)
	check(ss.status_text() != "", "Recenter says what it did")
	ss.advance(SettingsScreen.STATUS_TIME - 0.2)
	check(ss.status_text() != "", "still there just before %.0f s" % SettingsScreen.STATUS_TIME)
	ss.advance(0.3)
	eq(ss.status_text(), "", "gone after %.0f s" % SettingsScreen.STATUS_TIME)
