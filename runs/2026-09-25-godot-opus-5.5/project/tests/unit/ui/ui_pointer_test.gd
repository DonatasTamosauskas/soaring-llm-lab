extends TestCase
## U2 - VR laser pointer: synthetic controller ray -> hover -> trigger ->
## button pressed -> the right state change, on the real panels in VR mode.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _btn(screen: StringName, id: StringName) -> Button:
	return k.ui.get_screen(screen).get_button(id)


func test_main_menu_open_with_pointer_ready() -> void:
	eq(k.ui.current_screen_id(), &"main", "MENU state shows the main menu")
	check(k.ui.menu_panel.shown and k.ui.menu_panel.vr_mode, "menu panel is a VR quad")
	check(k.ui.pointer.enabled, "pointer enabled while a menu is open")
	eq(k.ui.pointer.active_index, 1, "right hand points by default (handedness=right)")


func test_hover_highlights_button_and_ticks() -> void:
	var play := _btn(&"main", &"play")
	k.aim_at_control(k.right, play)
	await k.settle(self, 3)
	eq(k.ui.pointer.hovered(), play, "pointer hovers Play")
	check(play.is_hovered(), "Play shows its hover state")
	check(k.ui.pointer.reticle_node().visible, "reticle drawn on the panel")
	check(k.ui.pointer.beam_node(1).visible and not k.ui.pointer.beam_node(0).visible, "only the active hand's beam is drawn")
	var hit: Dictionary = k.ui.pointer.last_hit
	check(not hit.is_empty(), "ray hits the panel")
	near(hit["distance"], 1.5, 0.35, "beam ends on the panel ~1.5 m away")
	gt(k.right.haptic_log.size(), 0, "hover onto a button gives a haptic tick")
	var reticle_len := k.ui.pointer.beam_node(1).global_transform.basis.z.length()
	near(reticle_len, hit["distance"], 0.01, "beam length = hit distance")
	# Moving off the button clears the hover.
	k.park_hands()
	await k.settle(self, 2)
	check(not play.is_hovered(), "hover clears when the ray leaves")


## [fill contrast hovered vs normal, ring px (hovered), ring px (normal),
## ring contrast vs the normal fill] of a button's drawn styles.
static func _hover_look(b: Button) -> Array:
	var normal := b.get_theme_stylebox(&"normal") as StyleBoxFlat
	var hover := b.get_theme_stylebox(&"hover") as StyleBoxFlat
	if normal == null or hover == null:
		return [0.0, 0.0, 0.0, 0.0]
	var ring := minf(minf(hover.border_width_left, hover.border_width_right), minf(hover.border_width_top, hover.border_width_bottom))
	var base := maxf(maxf(normal.border_width_left, normal.border_width_right), maxf(normal.border_width_top, normal.border_width_bottom))
	return [UITheme.contrast(hover.bg_color, normal.bg_color), ring, base, UITheme.contrast(hover.border_color, normal.bg_color)]


func test_the_hover_highlight_is_visible() -> void:
	# A hovered button must look hovered: a ring round it that the normal
	# style lacks, standing out from the normal fill, and a changed fill.
	# Round 5's engineering verifier made the theme's "hover" identical to
	# "normal" (mutation B1) and only the screenshots noticed.
	var rows := {}
	for id: StringName in [&"howto", &"play"]:
		var b := _btn(&"main", id)
		k.aim_at_control(k.right, b)
		await k.settle(self, 3)
		check(b.is_hovered(), "%s is hovered" % id)
		var look := _hover_look(b)
		rows[String(id)] = {"fill_contrast": snappedf(look[0], 0.01), "ring_px": look[1], "normal_ring_px": look[2], "ring_contrast": snappedf(look[3], 0.01)}
		gt(float(look[1]), 3.5, "%s: a ring round the hovered button (%d px)" % [id, int(look[1])])
		eq(float(look[2]), 0.0, "%s: that the normal style does not have" % id)
		if id == &"howto":
			# An ordinary button (dusk-blue): lighter, with a sunflower ring.
			gt(float(look[0]), 1.25, "howto: the hovered fill is visibly lighter (%.2f:1)" % look[0])
			gt(float(look[3]), 4.5, "howto: the ring stands out from the normal fill (%.2f:1)" % look[3])
		else:
			# The primary button is already sunflower: its hover is a cream ring
			# (and a lighter fill); the ring's edge against the dark panel is
			# what the eye catches.
			gt(float(look[0]), 1.05, "play: the hovered fill is lighter (%.2f:1)" % look[0])
			gt(float(look[3]), 1.35, "play: the cream ring differs from the sunflower fill (%.2f:1)" % look[3])
		# Either way the ring's outer edge meets the panel: WCAG's 3:1 for a
		# non-text cue (SC 1.4.11), literal.
		var hover := b.get_theme_stylebox(&"hover") as StyleBoxFlat
		var vs_panel := UITheme.contrast(hover.border_color, UITheme.PANEL)
		rows[String(id)]["ring_vs_panel"] = snappedf(vs_panel, 0.01)
		gt(vs_panel, 3.0, "%s: the ring stands out from the panel round the button (%.2f:1)" % [id, vs_panel])
	metric("hover_style", rows)


## Counts engine and script errors while it is added (OS.add_logger): a
## release off every panel must not index the empty hit (the verifier's P5
## mutant did, and the behaviour alone could not tell).
class _ErrorCount:
	extends Logger
	var errors := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		errors += 1


func test_press_then_slide_off_the_panel_is_no_click() -> void:
	# Pulling on Play, sliding the beam off the panel (into the sky) and
	# letting go there cancels, as on any screen: no click, no run, and Play
	# is not left held down. (Round 5's engineering verifier: nothing
	# exercised this path; its mutation P5 would index an empty hit.)
	var play := _btn(&"main", &"play")
	k.aim_at_control(k.right, play)
	await k.settle(self, 2)
	await k.wait_clickable(self)
	var clicks0 := k.ui.pointer.click_count
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	check(play.is_pressed(), "pressed on Play")
	var log := _ErrorCount.new()
	OS.add_logger(log)
	k.aim(k.right, k.cam.global_position + Vector3(0.0, 40.0, -10.0))
	await k.settle(self, 2)
	check(k.ui.pointer.last_hit.is_empty(), "the beam is off the panel")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	OS.remove_logger(log)
	eq(log.errors, 0, "sliding off and letting go raises no error")
	eq(k.gl.starts, 0, "no run started")
	eq(Game.state, Game.State.MENU, "still on the main menu")
	eq(k.ui.pointer.click_count, clicks0, "no click counted")
	check(not play.is_pressed(), "Play is not left held down")
	# Pressed, slid onto the panel's empty background, released there: no
	# click either.
	k.aim_at_control(k.right, play)
	await k.settle(self, 2)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	var r := k.ui.menu_panel.content.get_global_rect()
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(r.size.x * 0.06, r.size.y * 0.5)))
	await k.settle(self, 2)
	check(not k.ui.pointer.last_hit.is_empty(), "the beam is on the panel, off the button")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	eq(k.gl.starts, 0, "released off the button: no run")
	# And the next honest click still works.
	await k.click_control(self, play)
	eq(Game.state, Game.State.PLAYING, "a real click on Play still starts the run")


func test_trigger_on_play_starts_run() -> void:
	await k.click_control(self, _btn(&"main", &"play"))
	eq(k.gl.starts, 1, "GameLoop.start_run called once")
	eq(Game.state, Game.State.PLAYING, "Play starts a run")
	eq(k.ui.current_screen_id(), &"", "menu closed while playing")
	check(not k.ui.pointer.enabled, "pointer hidden during play")
	check(not k.ui.pointer.beam_node(1).visible, "beam hidden during play")
	eq(k.ui.pointer.click_count, 1, "exactly one click delivered")


func test_play_without_game_loop_still_starts() -> void:
	k.gl.remove_from_group(&"game_loop")
	await k.click_control(self, _btn(&"main", &"play"))
	eq(Game.state, Game.State.PLAYING, "fallback: Play sets PLAYING without a GameLoop")
	k.gl.add_to_group(&"game_loop")


func test_pause_and_resume_by_pointer() -> void:
	await k.click_control(self, _btn(&"main", &"play"))
	Events.menu_requested.emit()
	await k.settle(self, 3)
	eq(Game.state, Game.State.PAUSED, "menu button pauses")
	check(get_tree().paused, "tree paused")
	eq(k.ui.current_screen_id(), &"pause", "pause screen shown")
	check(k.ui.pointer.enabled, "pointer back while paused")
	await k.click_control(self, _btn(&"pause", &"resume"))
	eq(Game.state, Game.State.PLAYING, "Resume returns to play")
	check(not get_tree().paused, "tree running again")


func test_restart_by_pointer() -> void:
	await k.click_control(self, _btn(&"main", &"play"))
	await wait_seconds(0.4)
	var t_before := Game.run_time
	Events.menu_requested.emit()
	await k.settle(self, 3)
	# Restart throws the run away: a short pull (a mis-aimed click meant for
	# Resume, just above) does nothing but explain itself...
	var restart := _btn(&"pause", &"restart") as HoldButton
	check(restart != null, "Restart run is a hold-to-confirm button")
	await k.click_control(self, restart)
	eq(k.gl.restarts, 0, "one short pull on Restart run restarts nothing")
	eq(Game.state, Game.State.PAUSED, "still paused after a short pull")
	check(restart.hint_showing() and restart.text == "Hold to restart", "the button says how it works ('%s')" % restart.text)
	# Holding for less than HOLD_S (0.8 s, the real duration) does not...
	eq(restart.hold_seconds, 0.8, "restart needs a 0.8 s hold")
	await k.hold_control(self, restart, 0.55)
	eq(k.gl.restarts, 0, "a 0.55 s hold is not enough")
	# ...holding it through (a deliberate act) restarts, with a confirming buzz.
	var pulses := k.right.haptic_log.size()
	await k.hold_control(self, restart, 0.95)
	eq(k.gl.restarts, 1, "holding Restart run restarts (GameLoop.restart_run called once)")
	eq(Game.state, Game.State.PLAYING, "restart lands in play")
	gt(t_before, 0.0, "run time had advanced")
	lt(Game.run_time, t_before, "run time reset by the restart")
	gt(k.right.haptic_log.size(), pulses, "a confirming haptic pulse")


func test_hold_released_early_does_nothing() -> void:
	await k.click_control(self, _btn(&"main", &"play"))
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var restart := _btn(&"pause", &"restart") as HoldButton
	k.fast_holds()
	# Half the hold, then let go: the bar empties, nothing happens.
	await k.hold_control(self, restart, restart.hold_seconds * 0.5)
	eq(k.gl.restarts, 0, "a hold released at half way restarts nothing")
	near(restart.progress, 0.0, 1e-6, "the hold bar empties on release")
	# Holding with the ray sliding off the button does not complete it.
	k.aim_at_control(k.right, restart)
	await k.settle(self, 2)
	k.right.trigger_value = 1.0
	await wait_seconds(restart.hold_seconds * 0.4)
	gt(restart.progress, 0.0, "holding: the bar fills")
	k.aim_at_control(k.right, _btn(&"pause", &"settings"))
	await wait_seconds(restart.hold_seconds + 0.15)
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	eq(k.gl.restarts, 0, "sliding off the button while holding cancels")
	eq(k.ui.current_screen_id(), &"pause", "and presses nothing else")


func test_quit_to_menu_by_pointer() -> void:
	await k.click_control(self, _btn(&"main", &"play"))
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var quit := _btn(&"pause", &"quit_menu") as HoldButton
	check(quit != null, "Quit to menu is a hold-to-confirm button")
	eq(quit.hold_seconds, 0.8, "a 0.8 s hold")
	k.fast_holds()
	await k.click_control(self, quit)
	eq(k.gl.quits, 0, "one short pull on Quit to menu quits nothing")
	eq(quit.text, "Hold to quit", "and says how it works")
	await k.hold_control(self, quit)
	eq(k.gl.quits, 1, "GameLoop.quit_run called")
	eq(Game.state, Game.State.MENU, "back at the main menu")
	eq(k.ui.current_screen_id(), &"main", "main menu shown")


func test_settings_change_and_persist_by_pointer() -> void:
	await k.click_control(self, _btn(&"main", &"settings"))
	eq(k.ui.current_screen_id(), &"settings", "Settings opened from the main menu")
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	# Master volume: click the 4th of 10 segments -> 40 %.
	var bar := ss.get_bar("master_volume")
	var seg := bar.get_global_rect().position + bar.segment_center(3)
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(seg))
	await k.click(self, k.right)
	near(float(Settings.get_value("master_volume")), 0.4, 0.001, "master volume set to 40% by pointer")
	# Comfort vignette: the minus cap steps down one of 5 steps.
	var v0 := float(Settings.get_value("comfort_vignette"))
	var vb := ss.get_bar("comfort_vignette")
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(vb.get_global_rect().position + vb.cap_center(false)))
	await k.click(self, k.right)
	near(float(Settings.get_value("comfort_vignette")), maxf(0.0, snappedf(v0, 0.2) - 0.2), 0.001, "vignette stepped down by the - cap")
	# Turn speed (integration round 2): the flight's turn-rate comfort cap,
	# 4 named steps; the minus cap steps it down and it never reaches zero.
	var tb := ss.get_bar("turn_comfort")
	check(tb != null, "a Turn speed bar")
	eq(ss._values["turn_comfort"].text, "Brisk", "Turn speed starts at Brisk (180 deg/s)")
	for i in 4:
		k.aim(k.right, k.ui.menu_panel.pixel_to_world(tb.get_global_rect().position + tb.cap_center(false)))
		await k.click(self, k.right)
		await k.settle(self, 2)
	near(float(Settings.get_value("turn_comfort")), 0.25, 0.001, "stepped down to the gentlest, never to zero")
	eq(ss._values["turn_comfort"].text, "Gentle", "and says so")
	eq(FlightTuning.turn_comfort_rate(float(Settings.get_value("turn_comfort"))), 90.0, "Gentle caps the turn at 90 deg/s")
	Settings.set_value("turn_comfort", 0.75)
	# Seated mode and the left hand.
	await k.click_control(self, ss.get_stance().get_option_button("seated"))
	eq(Settings.get_value("seated"), true, "seated mode on")
	await k.click_control(self, ss.get_hand().get_option_button("left"))
	eq(Settings.get_value("handedness"), "left", "pointer hand = left")
	eq(k.ui.pointer.active_index, 0, "pointer switched to the left hand")
	# Persisted: read the file Settings wrote.
	var cfg := ConfigFile.new()
	eq(cfg.load(Settings.PATH), OK, "settings file written")
	near(float(cfg.get_value("settings", "master_volume", -1.0)), 0.4, 0.001, "volume persisted to disk")
	eq(cfg.get_value("settings", "seated", false), true, "seated persisted to disk")
	eq(cfg.get_value("settings", "handedness", ""), "left", "handedness persisted to disk")
	# Back returns to the main menu (now with the left hand).
	await k.click_control(self, ss.get_button(&"back"), k.left)
	eq(k.ui.current_screen_id(), &"main", "Back returns to the main menu")


func test_recenter_and_recalibrate_buttons() -> void:
	var got := {"recenter": 0, "recal": 0}
	var on_recenter := func() -> void: got["recenter"] += 1
	var on_recal := func() -> void: got["recal"] += 1
	Events.recenter_requested.connect(on_recenter)
	k.ui.recalibrate_requested.connect(on_recal)
	await k.click_control(self, _btn(&"main", &"settings"))
	await k.settle(self, 3)
	await k.click_control(self, _btn(&"settings", &"recenter"))
	await k.click_control(self, _btn(&"settings", &"recalibrate"))
	Events.recenter_requested.disconnect(on_recenter)
	eq(got["recenter"], 1, "Recenter emits Events.recenter_requested")
	eq(got["recal"], 1, "Recalibrate emits UIRoot.recalibrate_requested")


func test_other_hand_takes_over_on_trigger() -> void:
	var how := _btn(&"main", &"howto")
	k.aim_at_control(k.left, how)
	await k.click(self, k.left)
	eq(k.ui.pointer.active_index, 0, "left trigger hands the pointer to the left hand")
	eq(k.ui.current_screen_id(), &"howto", "and that pull clicked what it pointed at")


func test_trigger_hysteresis_single_click() -> void:
	var play := _btn(&"main", &"howto")
	k.aim_at_control(k.right, play)
	await k.settle(self, 2)
	await k.wait_clickable(self)
	for v in [0.3, 0.6, 0.64]:
		k.right.trigger_value = v
		await wait_frames(1)
	eq(k.ui.pointer.click_count, 0, "a half-pulled trigger (< 0.65) does not click")
	for v in [0.7, 0.5, 0.4, 0.6, 0.45]:
		k.right.trigger_value = v
		await wait_frames(1)
	eq(k.ui.pointer.click_count, 0, "held between thresholds: still one press, no release yet")
	k.right.trigger_value = 0.2
	await wait_frames(2)
	eq(k.ui.pointer.click_count, 1, "release below 0.35 completes exactly one click")
	eq(k.ui.current_screen_id(), &"howto", "the click landed")


func test_miss_does_nothing() -> void:
	k.aim(k.right, k.rig.global_transform * Vector3(3, 1.6, 1.0))
	await k.click(self, k.right)
	eq(Game.state, Game.State.MENU, "a click into the sky changes nothing")
	check(k.ui.pointer.last_hit.is_empty(), "no hit")
	check(not k.ui.pointer.reticle_node().visible, "no reticle without a hit")


func test_untracked_hand_draws_nothing() -> void:
	k.right.tracked = false
	await k.settle(self, 2)
	check(not k.ui.pointer.beam_node(1).visible, "lost tracking hides the beam")
	k.right.tracked = true


func test_untracked_hand_cannot_take_the_pointer_over() -> void:
	# A controller lying on the sofa (no tracking) whose trigger is squeezed
	# by the cushion must not steal the pointer, or click with a stale pose.
	k.left.tracked = false
	k.aim_at_control(k.left, _btn(&"main", &"howto"))
	await k.click(self, k.left)
	eq(k.ui.pointer.active_index, 1, "the pointer stays with the tracked right hand")
	eq(k.ui.current_screen_id(), &"main", "nothing clicked by a hand with no tracking")
	eq(k.ui.pointer.click_count, 0, "no click counted")
	# Tracked again, the same pull hands it over (control).
	k.left.tracked = true
	await k.click(self, k.left)
	eq(k.ui.pointer.active_index, 0, "tracked again: its trigger takes the pointer")


func test_how_to_tabs_by_pointer() -> void:
	await k.click_control(self, _btn(&"main", &"howto"))
	await k.settle(self, 3)
	var h := k.ui.get_screen(&"howto") as HowToScreen
	await k.click_control(self, h.get_button(&"tab_turn"))
	eq(h.current, 3, "Turn tab selected")
	await k.click_control(self, h.get_button(&"back"))
	eq(k.ui.current_screen_id(), &"main", "Back from how-to")


# --- a click needs a fresh pull on the screen it lands on --------------------

func test_trigger_held_when_pause_opens_is_not_a_click() -> void:
	# Flying with the trigger clenched, the hand happens to point where
	# "Restart run" will appear; pause, then let go: nothing may happen.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	k.fast_holds()
	var spot := k.ui.menu_panel.control_to_world(_btn(&"pause", &"restart"))
	k.ui.resume()
	await k.settle(self, 3)
	k.aim(k.right, spot)
	k.right.trigger_value = 1.0
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 4)
	eq(k.ui.current_screen_id(), &"pause", "pause open under the held trigger")
	eq(k.ui.pointer.hovered(), _btn(&"pause", &"restart"), "the ray rests on Restart run")
	# Keep squeezing well past the hold time: a press that began before the
	# menu opened is not a press on Restart, so it can never complete a hold.
	await wait_seconds(_btn(&"pause", &"restart").hold_seconds * 2.0)
	eq(k.gl.restarts, 0, "a trigger squeezed before the menu opened never counts as holding Restart")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	eq(k.gl.restarts, 0, "letting go of a trigger squeezed before the menu opened restarts nothing")
	eq(Game.state, Game.State.PAUSED, "still paused")
	eq(k.ui.pointer.click_count, 0, "no click delivered")
	# A fresh, deliberate hold on the same button does work.
	await k.hold_control(self, _btn(&"pause", &"restart"))
	eq(k.gl.restarts, 1, "a new, deliberate hold restarts")


func test_trigger_held_when_summary_appears_is_not_a_click() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	k.gl.fake_end({"score": 100, "max_mass": 0.05})
	await k.settle(self, 3)
	var spot := k.ui.menu_panel.control_to_world(_btn(&"summary", &"menu"))
	await k.click_control(self, _btn(&"summary", &"again"))
	eq(Game.state, Game.State.PLAYING, "second run")
	k.aim(k.right, spot)
	k.right.trigger_value = 1.0
	await k.settle(self, 3)
	# Last life lost mid-flap: the summary appears under the clenched trigger.
	k.gl.fake_end({"score": 120, "max_mass": 0.05})
	await k.settle(self, 4)
	eq(k.ui.current_screen_id(), &"summary", "summary open")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	eq(Game.state, Game.State.ENDED, "the summary is not dismissed by a trigger squeezed before it appeared")
	eq(k.gl.quits, 0, "and Main menu was not pressed")


func test_half_pulled_trigger_when_menu_opens_must_be_released_first() -> void:
	# At 0.5 (between release and press) when the menu appears, then pulled
	# all the way: that is the flap-clench continuing, not a new click.
	var play := _btn(&"main", &"howto")
	k.right.trigger_value = 0.5
	k.ui.stack = [&"settings"]
	k.ui._show_top()
	k.ui.stack = [&"main"]
	k.ui._show_top()
	k.aim_at_control(k.right, play)
	await wait_seconds(0.3)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"main", "a pull already under way when the screen appeared does not click")


func test_pull_in_the_first_moment_of_a_screen_is_ignored() -> void:
	await k.click_control(self, _btn(&"main", &"settings"))
	eq(k.ui.current_screen_id(), &"settings", "settings open")
	# The very next frame: a reflex pull on Back (nobody can read a new screen
	# in 0.2 s). It must not count.
	check(not k.ui.pointer.accepting_clicks(), "a new screen starts inside its grace window")
	k.aim_at_control(k.right, k.ui.get_screen(&"settings").get_button(&"back"))
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"settings", "a pull inside the grace window is not a click")
	await k.click_control(self, k.ui.get_screen(&"settings").get_button(&"back"))
	eq(k.ui.current_screen_id(), &"main", "after the grace window the same pull clicks")


func test_press_on_one_button_release_on_another_is_no_click() -> void:
	var settings := _btn(&"main", &"settings")
	var quit := _btn(&"main", &"quit")
	k.aim_at_control(k.right, settings)
	await k.wait_clickable(self)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.aim_at_control(k.right, quit)
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(k.quits, 0, "sliding off Settings onto Quit and releasing does not quit")
	eq(k.ui.current_screen_id(), &"main", "and does not open Settings either")


func test_press_in_the_sky_release_on_button_is_no_click() -> void:
	k.aim(k.right, k.rig.global_transform * Vector3(3, 1.6, 1.0))
	await k.wait_clickable(self)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.aim_at_control(k.right, _btn(&"main", &"play"))
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(Game.state, Game.State.MENU, "a press that began off the panel does not click Play")


func test_ray_from_behind_the_panel_is_ignored() -> void:
	var play := _btn(&"main", &"play")
	var target := k.ui.menu_panel.control_to_world(play)
	var normal := k.ui.menu_panel.global_transform.basis.z.normalized()
	var behind := target - normal * 0.8
	k.right.aim_at(behind, target + (target - behind))
	await k.click(self, k.right)
	eq(Game.state, Game.State.MENU, "a ray hitting the back of the panel clicks nothing")
	check(k.ui.pointer.last_hit.is_empty(), "no hit from behind")


func test_hits_land_on_the_right_pixel_across_the_curved_panel() -> void:
	# The panel is a cylinder round the eye: a ray aimed at any pixel, even
	# at the far edges, must come back as that pixel, and the reticle must
	# lie flat on the surface there.
	var p := k.ui.menu_panel
	var eye := k.cam.global_position
	var worst := 0.0
	for px: Vector2 in [Vector2(30, 450), Vector2(1330, 450), Vector2(680, 30), Vector2(40, 860), Vector2(1320, 40), Vector2(680, 450)]:
		k.aim(k.right, p.pixel_to_world(px))
		await k.settle(self, 2)
		var hit: Dictionary = k.ui.pointer.last_hit
		if not check(not hit.is_empty(), "hit at pixel %s" % px):
			continue
		worst = maxf(worst, (hit["pixel"] as Vector2).distance_to(px))
		var n: Vector3 = hit["normal"]
		var ret := k.ui.pointer.reticle_node()
		gt(ret.global_transform.basis.z.normalized().dot(n), 0.999, "reticle lies on the surface at %s" % px)
		# Every point of the panel is 1.5 m from the axis through the eye.
		var axis := p.global_transform.basis.y.normalized()
		var d: Vector3 = hit["point"] - eye
		near((d - axis * d.dot(axis)).length(), UITheme.PANEL_DISTANCE, 0.002, "hit at %s lies on the eye-centred cylinder" % px)
	metric("max_pixel_error", snappedf(worst, 0.01))
	lt(worst, 0.5, "rays land within half a pixel of where they were aimed (%.3f px)" % worst)
	# Front-facing everywhere: the normal points back at the eye.
	for px: Vector2 in [Vector2(0, 450), Vector2(1360, 450)]:
		var w := p.pixel_to_world(px)
		var hit2 := p.intersect_ray(eye, (w - eye).normalized())
		check(not hit2.is_empty(), "edge pixel %s visible from the eye" % px)
		if not hit2.is_empty():
			gt((hit2["normal"] as Vector3).dot((eye - w).normalized()), 0.99, "edge %s faces the eye squarely" % px)


func test_hand_tremor_click_and_render_rate() -> void:
	# Real hands shake ~0.3-0.5 deg. Hover must stay stable (few re-renders)
	# and a pull must land on the button aimed at.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	await k.click_control(self, _btn(&"main", &"settings"))
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	var left_btn := ss.get_hand().get_option_button("left")
	var centre := k.ui.menu_panel.control_to_world(left_btn)
	var hand := k.rig.global_transform * Vector3(0.22, 1.25, -0.25)
	var base_dir := (centre - hand).normalized()
	# Like a player: read the new screen before pulling (SCREEN_GRACE_S).
	await k.wait_clickable(self)
	var r0 := k.ui.menu_panel.render_requests
	for i in 180:
		var jitter := Basis(Vector3.UP, deg_to_rad(rng.randfn(0.0, 0.4))) * Basis(Vector3.RIGHT, deg_to_rad(rng.randfn(0.0, 0.4)))
		k.right.aim_at(hand, hand + jitter * base_dir)
		if i == 90:
			k.right.trigger_value = 1.0
		if i == 100:
			k.right.trigger_value = 0.0
		await wait_frames(1)
	var renders := k.ui.menu_panel.render_requests - r0
	metric("tremor_renders_180_frames", renders)
	eq(Settings.get_value("handedness"), "left", "a tremoring pull on 'Left' lands")
	lt(float(renders), 30.0, "tremor over a button does not stream re-renders (%d in 180 frames)" % renders)


# --- the real XR input path, driven headless ---------------------------------

## A fake OpenXR controller: an XRControllerTracker (what the OpenXR
## interface registers for each hand) fed the way OpenXR feeds it: an "aim"
## pose and the action names the UI reads.
func _tracker(tname: StringName) -> XRPositionalTracker:
	var t := XRControllerTracker.new()
	t.type = XRServer.TRACKER_CONTROLLER
	t.name = tname
	t.hand = XRPositionalTracker.TRACKER_HAND_LEFT if tname == &"left_hand" else XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(t)
	return t


## Aim pose in tracking space (rig-local, unscaled metres) at a rig-local point.
func _aim_pose(t: XRPositionalTracker, from_local: Vector3, at_local: Vector3) -> void:
	var dir := (at_local - from_local).normalized()
	var b := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD)
	t.set_pose(&"aim", Transform3D(b, from_local), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## A UIRoot in VR mode on the kit's rig with NO scripted sources: the
## pointer reads the XRController3D nodes UI adds, as in the headset.
func _real_xr_ui() -> void:
	k.ui.queue_free()
	await wait_frames(2)
	k.ui = Kit.UI_SCENE.instantiate() as UIRoot
	k.ui.mode = UIRoot.Mode.VR
	k.ui.progress_path = k.progress_path
	add_child(k.ui)
	k.ui.quit_handler = func() -> void: k.quits += 1
	await k.settle(self, 4)


func _aim_controllers() -> Array:
	return k.rig.find_children("*", "XRController3D", false, false)


func test_xr_controller_actions_drive_the_ui() -> void:
	await _real_xr_ui()
	eq(_aim_controllers().size(), 2, "exactly two UI aim controllers under the rig")
	var r := _tracker(&"right_hand")
	var l := _tracker(&"left_hand")
	var src := k.ui.pointer.sources[1] as UIXRPointerSource
	check(src != null, "the pointer reads real XR sources")
	var play := k.ui.get_screen(&"main").get_button(&"play")
	var at_local := k.rig.global_transform.affine_inverse() * k.ui.menu_panel.control_to_world(play)
	_aim_pose(r, Vector3(0.22, 1.25, -0.25), at_local)
	_aim_pose(l, Vector3(-0.25, 1.0, -0.2), Vector3(-0.25, 0.0, -0.2))
	await wait_seconds(0.3)
	check(src.is_tracked(), "tracked once the 'aim' pose has data")
	eq(k.ui.pointer.hovered(), play, "the 'aim' pose hovers Play")
	# The action names are the OpenXR action map's: trigger (analogue),
	# trigger_click, menu_button, by_button.
	r.set_input(&"trigger", 0.8)
	await wait_frames(1)
	near(src.trigger(), 0.8, 0.001, "'trigger' read as an analogue value")
	r.set_input(&"trigger", 0.0)
	r.set_input(&"trigger_click", true)
	await wait_frames(1)
	near(src.trigger(), 1.0, 0.001, "'trigger_click' counts as a full pull")
	r.set_input(&"trigger_click", false)
	await wait_frames(3)
	eq(Game.state, Game.State.PLAYING, "a real trigger pull on Play starts a run")
	await wait_seconds(0.3)
	# The UI's own reads (the VR autoload may react to the same buttons).
	var lsrc := k.ui.pointer.sources[0] as UIXRPointerSource
	l.set_input(&"menu_button", true)
	l.set_input(&"by_button", true)
	await wait_frames(1)
	check(lsrc.menu_pressed(), "'menu_button' read by the UI's source")
	check(lsrc.back_pressed(), "'by_button' read by the UI's source")
	l.set_input(&"by_button", false)
	await wait_frames(2)
	l.set_input(&"menu_button", false)
	await wait_frames(3)
	eq(Game.state, Game.State.PAUSED, "the left controller's 'menu_button' pauses")
	k.ui.push_screen(&"settings")
	await k.settle(self, 2)
	l.set_input(&"by_button", true)
	await wait_frames(3)
	l.set_input(&"by_button", false)
	await wait_frames(2)
	eq(k.ui.current_screen_id(), &"pause", "'by_button' goes back")
	await wait_seconds(0.3)
	l.set_input(&"menu_button", true)
	await wait_frames(3)
	l.set_input(&"menu_button", false)
	await wait_frames(3)
	eq(Game.state, Game.State.PLAYING, "and 'menu_button' resumes while the tree is paused")
	XRServer.remove_tracker(r)
	XRServer.remove_tracker(l)


func test_xr_hand_that_loses_its_aim_pose_stops_pointing() -> void:
	await _real_xr_ui()
	var r := _tracker(&"right_hand")
	var l := _tracker(&"left_hand")
	var src := k.ui.pointer.sources[1] as UIXRPointerSource
	var how := k.ui.get_screen(&"main").get_button(&"howto")
	var at_local := k.rig.global_transform.affine_inverse() * k.ui.menu_panel.control_to_world(how)
	_aim_pose(r, Vector3(0.22, 1.25, -0.25), at_local)
	_aim_pose(l, Vector3(-0.25, 1.0, -0.2), Vector3(-0.25, 0.0, -0.2))
	await wait_seconds(0.3)
	check(src.is_tracked(), "tracked while the 'aim' pose has data")
	check(k.ui.pointer.beam_node(1).visible, "its beam is drawn")
	# Tracking lost (hand out of the cameras' view): OpenXR invalidates the pose.
	r.invalidate_pose(&"aim")
	await wait_frames(3)
	check(not src.is_tracked(), "no aim pose: not tracked, whatever the node still holds")
	check(not k.ui.pointer.beam_node(1).visible, "and no beam from a stale pose")
	r.set_input(&"trigger", 1.0)
	await wait_frames(3)
	r.set_input(&"trigger", 0.0)
	await wait_frames(3)
	eq(k.ui.current_screen_id(), &"main", "its trigger clicks nothing")
	XRServer.remove_tracker(r)
	XRServer.remove_tracker(l)


func test_attach_rig_is_idempotent() -> void:
	await _real_xr_ui()
	var before := _aim_controllers().size()
	eq(before, 2, "two aim controllers after the UI found the rig")
	for a: XRController3D in _aim_controllers():
		check(String(a.name).begins_with("UIAim_"), "%s is one of UI's (contract name UIAim_*)" % a.name)
		eq(a.pose, &"aim", "%s uses the aim pose" % a.name)
		eq(a.process_mode, Node.PROCESS_MODE_ALWAYS, "%s runs while paused (Quest rule 6)" % a.name)
	eq(k.rig.scale, Vector3.ONE, "the rig is never scaled (Quest rule 1)")
	# Integration (or a respawn) attaching the same rig again: the same two
	# controllers stay (no churn: a re-created controller loses a frame of
	# tracking and resets the trigger state mid-click).
	var ids := _aim_controllers().map(func(c: Node) -> int: return c.get_instance_id())
	k.ui.attach_rig(k.rig, k.cam)
	k.ui.attach_rig(k.rig, k.cam)
	await wait_frames(2)
	eq(_aim_controllers().size(), 2, "attaching the same rig again adds no controllers")
	eq(_aim_controllers().map(func(c: Node) -> int: return c.get_instance_id()), ids, "and keeps the very same two")
	var old_pair := _aim_controllers()
	# A different rig: the old one's controllers go, the new one gets two.
	var rig2 := XROrigin3D.new()
	var cam2 := XRCamera3D.new()
	rig2.add_child(cam2)
	add_child(rig2)
	k.ui.attach_rig(rig2, cam2)
	await wait_frames(2)
	eq(_aim_controllers().size(), 0, "the old rig keeps no orphaned UI controllers")
	for i in old_pair.size():
		check(not is_instance_valid(old_pair[i]), "replaced controller %d is freed, not just detached" % i)
	eq(rig2.find_children("*", "XRController3D", false, false).size(), 2, "the new rig has the pair")
	# Scripted sources (tests, dev scene) release the XR pair too.
	k.ui.set_pointer_sources(k.left, k.right)
	await wait_frames(2)
	eq(rig2.find_children("*", "XRController3D", false, false).size(), 0, "switching to scripted sources frees them")
	k.ui.attach_rig(k.rig, k.cam)
	rig2.queue_free()


func test_haptics_setting_scales_pointer_pulses() -> void:
	var play := _btn(&"main", &"play")
	for level: float in [1.0, 0.5, 0.0]:
		Settings.set_value("haptics", level)
		k.park_hands()
		# Hover ticks are at least UIPointer.HOVER_TICK_GAP_S apart.
		await wait_seconds(UIPointer.HOVER_TICK_GAP_S + 0.05)
		k.right.haptic_log.clear()
		k.aim_at_control(k.right, play)
		await k.settle(self, 3)
		check(not k.right.haptic_log.is_empty(), "hover tick requested at haptics %.1f" % level)
		var amp := k.right.haptic_log[-1].x if not k.right.haptic_log.is_empty() else -1.0
		near(amp, 0.15 * level, 1e-4, "hover tick amplitude follows Settings > Haptics (%.1f)" % level)
	Settings.set_value("haptics", 1.0)


func test_resting_on_a_button_edge_with_tremor_does_not_buzz() -> void:
	# A hand holding still still trembles (~2-10 Hz, 0.05-0.2 deg at the aim
	# ray). Resting the beam on a button's edge used to flip hover 14 times
	# a second and tick the controller 7 times a second: a buzz ("distinct
	# patterns, never a constant buzz", DESIGN). Hover now has 12 px of
	# hysteresis and ticks are at least 0.35 s apart.
	k.ui.menu_panel.snap_to_head()
	await k.settle(self, 3)
	var play := _btn(&"main", &"play")
	var rect := play.get_global_rect()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var rows := {}
	for sigma_deg: float in [0.05, 0.1, 0.2]:
		var sigma_px := deg_to_rad(sigma_deg) * UITheme.PANEL_DISTANCE * UITheme.PX_PER_M
		var freqs := [2.3, 4.1, 7.7, 9.9]
		var ph := []
		for i in 8:
			ph.append(rng.randf() * TAU)
		var amp := sigma_px * sqrt(2.0 / freqs.size())
		k.right.haptic_log.clear()
		var changes := 0
		var ticks := 0
		var prev: Control = k.ui.pointer.hovered()
		var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 800:
			var t := (Time.get_ticks_msec() - start) / 1000.0
			var dx := 0.0
			var dy := 0.0
			for i in freqs.size():
				dx += amp * sin(TAU * float(freqs[i]) * t + float(ph[i]))
				dy += amp * sin(TAU * float(freqs[i]) * t + float(ph[i + 4]))
			k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(rect.get_center().x + dx, rect.end.y + dy)))
			await wait_frames(1)
			if k.ui.pointer.hovered() != prev:
				changes += 1
				prev = k.ui.pointer.hovered()
			for hp in k.right.haptic_log:
				if hp.y < 0.02:
					ticks += 1
			k.right.haptic_log.clear()
		var secs := (Time.get_ticks_msec() - start) / 1000.0
		rows["sigma %.2f deg" % sigma_deg] = {"hover_changes_per_s": snappedf(changes / secs, 0.1), "ticks_per_s": snappedf(ticks / secs, 0.1)}
		lt(ticks / secs, 3.0, "resting on Play's edge with %.2f deg of tremor: < 3 ticks a second (%.1f)" % [sigma_deg, ticks / secs])
		lt(changes / secs, 2.0, "and the highlight does not flicker (%.1f changes a second)" % (changes / secs))
	metric("edge_tremor", rows)
	# A quick sweep down the menu crosses four buttons in 0.2 s: at most
	# one tick per 0.35 s (a pattern, not a rattle).
	k.park_hands()
	await wait_seconds(UIPointer.HOVER_TICK_GAP_S + 0.05)
	k.right.haptic_log.clear()
	var swept := 0
	for id: StringName in [&"play", &"howto", &"settings", &"quit"]:
		k.aim_at_control(k.right, _btn(&"main", id))
		await wait_seconds(0.05)
		if k.ui.pointer.hovered() == _btn(&"main", id):
			swept += 1
	var sweep_ticks := 0
	for hp in k.right.haptic_log:
		if hp.y < 0.02:
			sweep_ticks += 1
	metric("sweep_ticks", {"buttons_hovered": swept, "ticks": sweep_ticks})
	eq(swept, 4, "the sweep hovered each of the four buttons")
	between(float(sweep_ticks), 1.0, 2.0, "four buttons in 0.2 s: one tick, two at most on a slow frame (%d)" % sweep_ticks)
	# Hysteresis never holds on to a button the beam has left for another:
	# neighbouring choices switch at once...
	await k.click_control(self, _btn(&"main", &"settings"))
	await k.settle(self, 3)
	var hand := (k.ui.get_screen(&"settings") as SettingsScreen).get_hand()
	var left_btn := hand.get_option_button("left")
	var right_btn := hand.get_option_button("right")
	k.aim_at_control(k.right, left_btn)
	await k.settle(self, 2)
	eq(k.ui.pointer.hovered(), left_btn, "hovering Left")
	# Just across the border onto Right (within 12 px of Left: the 10 px
	# gap plus 1).
	var rr := right_btn.get_global_rect()
	var lr := left_btn.get_global_rect()
	var gap := rr.position.x - lr.end.x
	check(gap >= 0.0 and gap + 1.0 < UIPointer.HOVER_KEEP_PX, "Left and Right are neighbours (%.0f px apart)" % gap)
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(rr.position.x + 1.0, rr.get_center().y)))
	await k.settle(self, 1)
	eq(k.ui.pointer.hovered(), right_btn, "1 px onto Right: Right, in one frame (hysteresis never holds on to a neighbour)")
	# ...it lets go well outside...
	var r2 := right_btn.get_global_rect()
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(r2.get_center().x, r2.end.y + 40.0)))
	await k.settle(self, 2)
	check(k.ui.pointer.hovered() != right_btn, "40 px below Right, it lets go")
	# ...and a pull just outside the highlighted button lands on it.
	eq(Settings.get_value("handedness"), "right", "right-handed to begin with")
	var r1 := left_btn.get_global_rect()
	k.aim_at_control(k.right, left_btn)
	await k.settle(self, 2)
	k.aim(k.right, k.ui.menu_panel.pixel_to_world(Vector2(r1.get_center().x, r1.end.y + 7.0)))
	await k.settle(self, 2)
	eq(k.ui.pointer.hovered(), left_btn, "7 px below Left it is still Left")
	await k.click(self, k.right)
	eq(Settings.get_value("handedness"), "left", "the pull lands on the highlighted Left")


func test_the_rigs_own_aim_controllers_are_used() -> void:
	# The player rig has LeftAim / RightAim (aim pose, "the UI laser
	# source"): the UI reads those instead of adding its own pair, and
	# leaves them alone when it lets go.
	var la := XRController3D.new()
	la.name = "LeftAim"
	la.tracker = &"left_hand"
	la.pose = &"aim"
	var ra := XRController3D.new()
	ra.name = "RightAim"
	ra.tracker = &"right_hand"
	ra.pose = &"aim"
	k.rig.add_child(la)
	k.rig.add_child(ra)
	await _real_xr_ui()
	eq(_aim_controllers().size(), 2, "no UIAim_* added next to LeftAim / RightAim")
	var srcs := k.ui.pointer.sources
	check((srcs[0] as UIXRPointerSource).controller == la, "left source reads LeftAim")
	check((srcs[1] as UIXRPointerSource).controller == ra, "right source reads RightAim")
	check(not (srcs[1] as UIXRPointerSource).owns_controller, "and does not own it")
	k.ui.set_pointer_sources(k.left, k.right)
	await wait_frames(2)
	check(is_instance_valid(la) and la.get_parent() == k.rig, "LeftAim stays in the rig after the UI lets go")
	check(is_instance_valid(ra) and ra.get_parent() == k.rig, "RightAim too")


func test_hold_confirm_buzz_follows_the_haptics_setting() -> void:
	k.fast_holds()
	await k.click_control(self, _btn(&"main", &"play"))
	await wait_seconds(0.2)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	Settings.set_value("haptics", 0.5)
	k.fast_holds()
	k.right.haptic_log.clear()
	await k.hold_control(self, _btn(&"pause", &"restart"))
	eq(k.gl.restarts, 1, "restarted")
	var confirm := Vector2(-1, -1)
	for hp: Vector2 in k.right.haptic_log:
		if absf(hp.y - 0.06) < 1e-4:
			confirm = hp
	near(confirm.x, 0.3, 1e-4, "the confirming buzz is 0.6 x Settings > Haptics 0.5 (%s)" % str(confirm))
	Settings.set_value("haptics", 1.0)
