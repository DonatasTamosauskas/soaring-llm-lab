extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## A seeded random session: menu button presses, laser clicks on whatever
## the current screen offers, getting caught, respawning, runs ending,
## tier-ups, apex catches, headset focus loss, targets and threats named and
## freed. After every event the player-visible state must agree with the
## game state (U3): the right screen for the state, gameplay paused exactly
## in PAUSED, the laser only on interactive menus, the HUD and cues only in
## play, never more than two SubViewports rendering (U7), no script errors.
## Also: what happens to a tier-up celebration when the player pauses
## during it, and whether a long session leaks nodes.
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7x_flow

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


class _ErrorCount:
	extends Logger
	var errors := 0
	var first := ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		# The mock rig has no XR interface: the engine's own tracker noise
		# is not the UI's.
		if code.contains("p_tracker") or rationale.contains("p_tracker"):
			return
		errors += 1
		if first == "":
			first = "%s %s:%d %s %s" % [function, file, line, code, rationale]


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	k.fast_holds()
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


const MENU_SCREENS: Array[StringName] = [&"main", &"settings", &"howto"]
const PAUSE_SCREENS: Array[StringName] = [&"pause", &"settings", &"howto"]


## What the player sees must match the game state. Returns the first
## violation, or "".
func _violation() -> String:
	var ui := k.ui
	var st := Game.state
	var top := ui.current_screen_id()
	var s := ui.current_screen()
	var interactive := s != null and s.interactive
	if ui.menu_panel.shown != (top != &""):
		return "menu panel shown=%s with top screen '%s'" % [ui.menu_panel.shown, top]
	if ui.pointer.enabled != interactive:
		return "pointer enabled=%s on screen '%s' (interactive=%s)" % [ui.pointer.enabled, top, interactive]
	for i in 2:
		if ui.pointer.beam_node(i).visible and not ui.pointer.enabled:
			return "a laser beam is drawn with no interactive menu (screen '%s')" % top
	if ui.active_viewport_count() > 2:
		return "%d SubViewports active" % ui.active_viewport_count()
	match st:
		Game.State.PLAYING:
			if top != &"":
				return "PLAYING with screen '%s' open" % top
			if not ui.hud_panel.shown:
				return "PLAYING without the HUD"
			if not ui.indicators.active:
				return "PLAYING without the cues"
			if get_tree().paused:
				return "PLAYING with the tree paused"
		Game.State.PAUSED:
			if not (top in PAUSE_SCREENS):
				return "PAUSED showing '%s'" % top
			if not get_tree().paused:
				return "PAUSED but gameplay runs"
		Game.State.MENU, Game.State.BOOT:
			if not (top in MENU_SCREENS):
				return "MENU showing '%s'" % top
		Game.State.CAUGHT:
			if top != &"caught":
				return "CAUGHT showing '%s'" % top
		Game.State.ENDED:
			if top != &"summary":
				return "ENDED showing '%s'" % top
	if st != Game.State.PLAYING:
		if ui.hud_panel.shown:
			return "HUD shown in %s" % Game.State.keys()[st]
		if ui.indicators.active:
			return "cues active in %s" % Game.State.keys()[st]
	if st != Game.State.PAUSED and get_tree().paused:
		return "tree paused in %s" % Game.State.keys()[st]
	return ""


func _visible_buttons() -> Array[Button]:
	var out: Array[Button] = []
	var s := k.ui.current_screen()
	if s == null or not s.interactive:
		return out
	for b in s.find_children("*", "Button", true, false):
		var bt := b as Button
		if bt.is_visible_in_tree() and not bt.disabled:
			out.append(bt)
	return out


func _press(rng: RandomNumberGenerator) -> String:
	var bs := _visible_buttons()
	if bs.is_empty():
		return "no buttons"
	var b: Button = bs[rng.randi_range(0, bs.size() - 1)]
	var nm := "%s/%s" % [k.ui.current_screen_id(), b.name]
	if b is HoldButton:
		await k.hold_control(self, b)
	else:
		await k.click_control(self, b)
	k.park_hands()
	return "click " + nm


func _menu_button() -> void:
	k.ui.set(&"_last_menu_ms", -100000)
	Events.menu_requested.emit()


func _session(seed_: int, steps: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var birds: Array[Bird] = []
	var log := _ErrorCount.new()
	OS.add_logger(log)
	var bad := ""
	var hist: Array[String] = []
	var counts := {}
	for i in steps:
		var st := Game.state
		var ev := ""
		var r := rng.randf()
		match st:
			Game.State.PLAYING:
				if r < 0.18:
					_menu_button()
					ev = "menu button"
				elif r < 0.30:
					k.gl.fake_caught(birds[0] if not birds.is_empty() and is_instance_valid(birds[0]) else null)
					ev = "caught"
				elif r < 0.36:
					k.gl.fake_end({"score": rng.randi_range(0, 900)})
					ev = "run ended"
				elif r < 0.50:
					var a := rng.randi_range(2, 8)
					Events.player_tier_changed.emit(a, a + (1 if rng.randf() < 0.8 else -1))
					ev = "tier change"
				elif r < 0.56:
					k.gl.fake_apex_catch()
					ev = "apex catch"
				elif r < 0.62:
					VR.session_unfocused.emit()
					ev = "focus lost"
				elif r < 0.80:
					var b := UIStandInBird.new() if ClassDB.class_exists("UIStandInBird") else Bird.new()
					add_child(b)
					b.global_position = k.cam.global_position + Vector3(rng.randf_range(-30, 30), rng.randf_range(-10, 10), rng.randf_range(-30, 30))
					birds.append(b)
					if rng.randf() < 0.5:
						Events.target_changed.emit(b)
					else:
						Events.threat_changed.emit(rng.randf(), b)
					ev = "bird named"
				else:
					if not birds.is_empty():
						var b2: Bird = birds.pop_at(rng.randi_range(0, birds.size() - 1))
						if is_instance_valid(b2):
							b2.queue_free()
					ev = "bird freed"
				# play on for a moment
				for f in rng.randi_range(1, 20):
					await get_tree().process_frame
			Game.State.CAUGHT:
				if r < 0.5:
					Game.set_state(Game.State.PLAYING)
					ev = "respawn"
				elif r < 0.7:
					k.gl.fake_end({"score": rng.randi_range(0, 900)})
					ev = "run ended (out of lives)"
				else:
					_menu_button()
					ev = "menu button while caught"
			_:
				if r < 0.15:
					_menu_button()
					ev = "menu button"
				elif r < 0.2:
					VR.session_unfocused.emit()
					ev = "focus lost"
				else:
					ev = await _press(rng)
		await k.settle(self, 2)
		counts[ev.split(" ")[0]] = int(counts.get(ev.split(" ")[0], 0)) + 1
		hist.append("%s -> %s/%s" % [ev, Game.State.keys()[Game.state], k.ui.current_screen_id()])
		var v := _violation()
		if v != "":
			bad = "step %d after '%s': %s (last: %s)" % [i, ev, v, " | ".join(hist.slice(maxi(0, hist.size() - 6)))]
			break
	OS.remove_logger(log)
	for b in birds:
		if is_instance_valid(b):
			b.queue_free()
	return {"violation": bad, "errors": log.errors, "first_error": log.first, "events": counts}


func test_a_random_sessions_keep_what_you_see_consistent() -> void:
	for seed_: int in [3, 17]:
		# Each session starts from the main menu.
		if Game.state != Game.State.MENU:
			Game.set_state(Game.State.MENU)
		await k.settle(self, 3)
		var r := await _session(seed_, 110)
		print("[ui-verify] random session seed %d: %s" % [seed_, JSON.stringify(r)])
		metric("session_%d" % seed_, r)
		eq(r["violation"], "", "seed %d: what the player sees matches the game state" % seed_)
		eq(int(r["errors"]), 0, "seed %d: no engine or script errors (%s)" % [seed_, r["first_error"]])


func test_b_a_pause_during_a_tier_up_celebration() -> void:
	# A tier-up is "a celebrated moment". The player catches, grows, and the
	# headset loses focus (or they press the menu button) half a second in.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	Events.player_tier_changed.emit(3, 4)
	await k.settle(self, 2)
	check(k.ui.hud.toast_active(), "the celebration is up")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 500:
		await get_tree().process_frame
	_menu_button()
	await k.settle(self, 4)
	eq(Game.state, Game.State.PAUSED, "paused")
	k.ui.resume()
	await k.settle(self, 4)
	eq(Game.state, Game.State.PLAYING, "resumed")
	var back := k.ui.hud.toast_active()
	print("[ui-verify] tier-up celebration after a pause 0.5 s in: %s" % ("shown again" if back else "gone"))
	metric("celebration_survives_pause", back)
	check(back, "the celebration interrupted by a pause is still there after Resume (it was up 0.5 s of 3.2)")


func test_c_a_long_session_does_not_grow() -> void:
	# 300 celebrations, 120 lesson cards, 600 target/threat birds named and
	# freed: the UI's node count and the orphan count must not creep.
	k.gl.start_run()
	await k.settle(self, 4)
	var count_nodes := func() -> int: return k.ui.find_children("*", "", true, false).size()
	var n0: int = count_nodes.call()
	var o0 := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in 300:
		Events.player_tier_changed.emit(2 + i % 7, 3 + i % 7)
		if i % 5 == 0:
			k.gl.fake_apex_catch() if Game.state == Game.State.PLAYING else null
		if Game.state != Game.State.PLAYING:
			Game.set_state(Game.State.MENU)
			k.gl.start_run()
		var b := Bird.new()
		add_child(b)
		b.global_position = k.cam.global_position + Vector3(rng.randf_range(-20, 20), 0, -20)
		Events.target_changed.emit(b)
		var b2 := Bird.new()
		add_child(b2)
		b2.global_position = k.cam.global_position + Vector3(rng.randf_range(-20, 20), 0, 15)
		Events.threat_changed.emit(0.7, b2)
		await get_tree().process_frame
		b.queue_free()
		b2.queue_free()
		if i % 3 == 0:
			k.ui.hud.show_lesson(i % 7, 7, Onboarding.LESSONS[i % 7])
		await get_tree().process_frame
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	await k.settle(self, 10)
	var n1: int = count_nodes.call()
	var o1 := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var r := {"ui_nodes_before": n0, "ui_nodes_after": n1, "orphans_before": o0, "orphans_after": o1}
	print("[ui-verify] long session: %s" % JSON.stringify(r))
	metric("long_session", r)
	lt(n1 - n0, 5, "the UI's node count does not creep (%d -> %d)" % [n0, n1])
	lt(o1 - o0, 5, "no orphan nodes left behind (%d -> %d)" % [o0, o1])
