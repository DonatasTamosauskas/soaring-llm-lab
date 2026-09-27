extends TestCase
## Verifier probes (round 1) for U3: every state transition maps to the
## right screen, pointer, HUD and pause; countdown honesty; summary honesty
## against the real GameLoop's event order and records. Independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const STATES := [Game.State.MENU, Game.State.PLAYING, Game.State.PAUSED, Game.State.CAUGHT, Game.State.ENDED]
const EXPECT := {
	Game.State.MENU: &"main", Game.State.PLAYING: &"", Game.State.PAUSED: &"pause",
	Game.State.CAUGHT: &"caught", Game.State.ENDED: &"summary",
}

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)
	k.ui.onboarding.skip()


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func test_every_state_pair_is_consistent() -> void:
	var bad := 0
	for a: int in STATES:
		for b: int in STATES:
			if a == b:
				continue
			Game.set_state(a as Game.State)
			await k.settle(self, 1)
			Game.set_state(b as Game.State)
			await k.settle(self, 2)
			var tag := "%s->%s" % [Game.state_name(a), Game.state_name(b)]
			var sid := k.ui.current_screen_id()
			var ok := true
			ok = eq(sid, EXPECT[b], "%s screen" % tag) and ok
			var s := k.ui.current_screen()
			var want_ptr := s != null and s.interactive
			ok = eq(k.ui.pointer.enabled, want_ptr, "%s pointer enabled iff interactive screen" % tag) and ok
			ok = eq(k.ui.hud_panel.shown, b == Game.State.PLAYING, "%s HUD only while playing" % tag) and ok
			ok = eq(get_tree().paused, b == Game.State.PAUSED, "%s tree paused iff PAUSED" % tag) and ok
			ok = check(k.ui.active_viewport_count() <= 2, "%s <= 2 active viewports" % tag) and ok
			ok = eq(k.ui.menu_panel.shown, EXPECT[b] != &"", "%s menu panel shown iff a screen" % tag) and ok
			if not ok:
				bad += 1
	metric("inconsistent_transitions", bad)


func test_caught_countdown_freezes_while_paused() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await wait_seconds(0.5)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PAUSED, "paused from CAUGHT")
	await wait_seconds(2.5)
	k.ui.resume()
	await k.settle(self, 2)
	eq(Game.state, Game.State.CAUGHT, "back to CAUGHT")
	var cs := k.ui.get_screen(&"caught") as CaughtScreen
	var txt := cs.countdown_text()
	metric("countdown_after_pause", txt)
	check(txt.contains("2") or txt.contains("3"), "countdown did not run while paused (%s)" % txt)
	hawk.free()


func test_real_gameloop_event_order_summary() -> void:
	# The real GameLoop sets ENDED first, then emits run_ended(summary).
	k.gl.start_run()
	await k.settle(self, 2)
	Game.set_state(Game.State.ENDED)
	await k.settle(self, 1)
	Events.run_ended.emit({"score": 900, "time": 125.0, "max_mass": 0.55, "max_tier": 6,
		"catches_by_species": {&"sparrow": 2}, "lives": 0, "lives_max": 3})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	var labels := []
	for l in ss.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree():
			labels.append((l as Label).text)
	metric("summary_labels", labels)
	check("You reached Crow" in labels, "headline uses the run's peak tier")
	check("900" in labels, "score shown")
	check("2:05" in labels, "time shown")


func test_new_best_badge_agrees_with_best_shown() -> void:
	# GameLoop keeps its own records (it also saves bests for runs quit to
	# the menu, which never emit run_ended). Its best is 6000; UI's own file
	# has never seen that. A 5500 run must not be announced as a new best
	# while the same screen says Best 6 000.
	k.ui.bridge.stats_provider = func() -> Dictionary:
		return {"best_score": 6000, "lives": 0, "lives_max": 3}
	Game.set_state(Game.State.PLAYING)
	await k.settle(self, 2)
	Game.set_state(Game.State.ENDED)
	Events.run_ended.emit({"score": 5500, "time": 300.0, "max_mass": 0.3, "catches_by_species": {}})
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"summary")
	var badge := ss.find_child("NewBest", true, false) as Label
	var shown_best := ""
	var labels := []
	for l in ss.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree():
			labels.append((l as Label).text)
	metric("labels", labels)
	check("6 000" in labels, "Best shows the GameLoop record 6 000")
	check(not badge.is_visible_in_tree(), "no 'New best!' for 5 500 when the best shown is 6 000")


func test_menu_button_spam_stays_consistent() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	for i in 9:
		await wait_seconds(0.27)
		Events.menu_requested.emit()
		await k.settle(self, 1)
		var paused := Game.state == Game.State.PAUSED
		eq(get_tree().paused, paused, "press %d: tree pause matches state" % i)
		eq(k.ui.current_screen_id(), &"pause" if paused else &"", "press %d: screen matches state" % i)
	eq(Game.state, Game.State.PAUSED, "odd number of presses ends paused")


func test_quit_to_menu_from_pause_while_caught() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var gull := UIMockPlayer.new()
	gull.species = &"gull"
	k.gl.fake_caught(gull)
	await k.settle(self, 2)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	await k.click_control(self, k.ui.get_screen(&"pause").get_button(&"quit_menu"))
	eq(Game.state, Game.State.MENU, "quit to menu from a caught pause")
	eq(k.ui.current_screen_id(), &"main", "main menu shown")
	check(not get_tree().paused, "tree unpaused at the main menu")
	gull.free()
