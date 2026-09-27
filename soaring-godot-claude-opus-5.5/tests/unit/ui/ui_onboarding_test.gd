extends TestCase
## U5 - first-flight lessons advance on simulated telemetry (the flight
## contract's keys), never block play, time out instead of stalling, and
## persist completion.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const DT := 1.0 / 72.0

var path := ""


func before_each() -> void:
	path = "user://ui_onboarding_test_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func after_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# (A test that ran its clock fast never leaves it so.)
	Engine.time_scale = 1.0


func _make() -> Onboarding:
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new(path)
	add_child(o)
	return o


static func tel(over: Dictionary = {}) -> Dictionary:
	var t := {"airspeed": 8.0, "vertical_speed": 0.0, "wing_extension": 0.2, "flapping": 0.0,
		"bank": 0.0, "tucked": false, "perched": false, "aoa": 0.1, "pitch_input": 0.0}
	t.merge(over, true)
	return t


## Run `seconds` of telemetry produced by f(t_sec) -> Dictionary.
func _run(o: Onboarding, seconds: float, f: Callable) -> void:
	var n := int(ceil(seconds / DT))
	for i in n:
		o.step(DT, f.call(i * DT))


func _finish_celebration(o: Onboarding) -> void:
	_run(o, Onboarding.CELEBRATE + 0.1, func(_t: float) -> Dictionary: return tel())


func test_idle_player_does_not_advance() -> void:
	var o := _make()
	o.start()
	eq(o.index, 0, "starts at lesson 1")
	_run(o, 20.0, func(_t: float) -> Dictionary: return tel())
	eq(o.index, 0, "doing nothing does not complete 'spread'")
	near(o.progress, 0.0, 1e-6, "no progress without the gesture")
	o.queue_free()


func test_all_lessons_advance_on_telemetry() -> void:
	var o := _make()
	var started := []
	var completions := []
	o.lesson_started.connect(func(_i: int, l: Dictionary) -> void: started.append(l["id"]))
	o.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void: completions.append([id, timed_out]))
	var finished := [false]
	o.finished.connect(func(skipped: bool) -> void: finished[0] = not skipped)
	o.start()
	# 1. Spread: arms out for > 1 s. Half a second is not enough.
	_run(o, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	eq(o.index, 0, "0.5 s of spread is not yet enough")
	between(o.progress, 0.4, 0.6, "progress bar half full")
	_run(o, 0.6, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	eq(o.celebrating > 0.0, true, "spread completed -> 'nice' beat")
	_finish_celebration(o)
	eq(o.current()["id"], &"flap", "2. flap")
	# 2. Flap: three real wingbeats via Events (weak twitches don't count).
	o.notify_flap(0, 0.1)
	o.notify_flap(0, 0.1)
	o.step(DT, tel())
	near(o.progress, 0.0, 1e-6, "weak twitches are not wingbeats")
	for i in 3:
		o.notify_flap(0, 0.8)
		o.step(DT, tel({"flapping": 0.3, "vertical_speed": 1.0, "wing_extension": 0.8}))
	check(o.celebrating > 0.0, "three wingbeats complete 'flap'")
	_finish_celebration(o)
	# 3. Glide: 3 s wings out, not flapping, flying.
	_run(o, 1.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0}))
	eq(o.current()["id"], &"glide", "halfway through the glide")
	_run(o, 1.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0, "flapping": 0.8}))
	lt(o.progress, 0.55, "flapping doesn't count as gliding")
	_run(o, 1.6, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0}))
	check(o.celebrating > 0.0, "3 s of gliding completes 'glide'")
	_finish_celebration(o)
	# 4. Speed: both wrists twisted leading edge down (pitch_input -0.4) while
	# gliding, and the airspeed builds from 7 m/s.
	_run(o, 2.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.4, "airspeed": 7.0 + t * 1.6, "aoa": 0.02}))
	check(o.celebrating > 0.0, "a held tilt that builds speed completes 'speed'")
	_finish_celebration(o)
	# 5. Turn: bank beyond 20 deg for 1.2 s.
	_run(o, 1.3, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "bank": deg_to_rad(-30.0)}))
	check(o.celebrating > 0.0, "sustained bank completes 'turn'")
	_finish_celebration(o)
	# 6. Dive: tucked and dropping fast.
	_run(o, 0.9, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.1, "tucked": true, "vertical_speed": -6.0}))
	check(o.celebrating > 0.0, "tucked dive completes 'dive'")
	_finish_celebration(o)
	# 7. Catch: the player eats something.
	eq(o.current()["id"], &"catch", "7. catch a moth")
	var me := UIMockPlayer.new()
	var moth := Bird.new()
	var other := Bird.new()
	o.notify_catch(other, moth)
	o.step(DT, tel())
	near(o.progress, 0.0, 1e-6, "an NPC's catch doesn't count")
	o.notify_catch(me, moth)
	o.step(DT, tel())
	check(o.celebrating > 0.0, "player's catch completes the last lesson")
	_finish_celebration(o)
	check(finished[0], "finished (not skipped)")
	check(not o.active, "onboarding inactive after the last lesson")
	eq(started.size(), 7, "all seven lessons shown in order")
	var done := []
	for c: Array in completions:
		check(not c[1], "%s completed by doing it, not by timeout" % c[0])
		done.append(String(c[0]))
	eq(", ".join(done), "spread, flap, glide, speed, turn, dive, catch", "lessons completed in order")
	check(UIProgress.new(path).onboarding_done(), "completion persisted to disk")
	me.free()
	moth.free()
	other.free()
	o.queue_free()


func test_balloon_also_counts_for_speed() -> void:
	var o := _make()
	o.start()
	o.skip()
	o.reset()
	o.progress_store.mark_lesson(&"spread")
	o.progress_store.mark_lesson(&"flap")
	o.progress_store.mark_lesson(&"glide")
	o.start()
	eq(o.current()["id"], &"speed", "resumes at the first unfinished lesson")
	# Leading edges up (pitch_input +0.4): the bird balloons (sink turns into
	# a climb) and bleeds speed.
	_run(o, 2.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": 0.4,
		"vertical_speed": -1.5 + minf(t, 1.0) * 3.0, "airspeed": 9.0 - t * 1.5, "aoa": 0.3}))
	check(o.celebrating > 0.0, "a held nose-up tilt that balloons completes 'speed'")
	o.queue_free()


func test_stuck_lesson_times_out() -> void:
	var o := _make()
	var timed := [false]
	o.lesson_completed.connect(func(_i: int, _id: StringName, t: bool) -> void: timed[0] = t)
	o.start()
	_run(o, Onboarding.TIMEOUT - 1.0, func(_t: float) -> Dictionary: return tel())
	eq(o.index, 0, "still waiting before the timeout")
	_run(o, 1.5, func(_t: float) -> Dictionary: return tel())
	check(timed[0], "lesson moved on by itself after %d s" % int(Onboarding.TIMEOUT))
	_finish_celebration(o)
	eq(o.index, 1, "next lesson started")
	o.queue_free()


## The catch lesson waits for the first catch (integration round 2: in real
## play the first catch came 39-390 s after the lessons, median ~110 s, and
## the lesson expired after 45 s while the player was still hunting, so it
## was never learned and came back every session).
func test_the_catch_lesson_waits_for_the_first_catch() -> void:
	var o := _make()
	_at(o, &"catch")
	var done := _completions(o)
	_run(o, 200.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0}))
	eq(done, [], "no catch in 200 s of hunting: the lesson is still up")
	check(o.active and o.current()["id"] == &"catch", "still the catch lesson")
	eq(o.current_view()["hint"], "Fly straight into it", "without lesson prey its words still say more as time goes by")
	var me := UIMockPlayer.new()
	var moth := Bird.new()
	o.notify_catch(me, moth)
	o.step(DT, tel())
	eq(done, [&"catch"], "the first catch completes it (learned)")
	check(UIProgress.new(path).lessons_done().has("catch"), "and it is recorded as learned")
	me.free()
	moth.free()
	o.queue_free()
	# Never caught anything: it still moves on after CATCH_TIMEOUT (play is
	# never blocked), not learned. (A fresh player: the first one has now
	# learned every lesson.)
	path = path + "_2"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var o2 := _make()
	_at(o2, &"catch")
	var timed := []
	o2.lesson_completed.connect(func(_i: int, id: StringName, t: bool) -> void:
		if t:
			timed.append(id))
	_run(o2, Onboarding.CATCH_TIMEOUT - 1.0, func(_t: float) -> Dictionary: return tel())
	eq(timed, [], "still up a second before CATCH_TIMEOUT")
	_run(o2, 2.0, func(_t: float) -> Dictionary: return tel())
	eq(timed, [&"catch"], "moves on after %d s" % int(Onboarding.CATCH_TIMEOUT))
	o2.queue_free()


## Desktop play names its keys (integration round 2, both verifiers: the
## desktop lesson cards showed arm gestures and the Buttons tab said
## "Flying needs no buttons" - no screen named Space, W, S, A/D or Shift).
func test_desktop_names_the_keys() -> void:
	var keys := {&"flap": "Space", &"speed": "W", &"turn": "A or D", &"dive": "Shift"}
	for l: Dictionary in Onboarding.LESSONS:
		check(l.has("keys"), "lesson %s has a desktop hint" % l["id"])
		if keys.has(l["id"]):
			check(String(l.get("keys", "")).contains(keys[l["id"]]), "lesson %s names %s: '%s'" % [l["id"], keys[l["id"]], l.get("keys", "")])
	var buttons: Dictionary = {}
	for c: Dictionary in HowToScreen.CARDS:
		if c["id"] == &"controls":
			buttons = c
	for key in ["Space", "W/S", "A/D", "Shift", "Esc"]:
		check(String(buttons.get("keys", "")).contains(key), "the desktop Buttons card names %s" % key)
	var speed: Dictionary = HowToScreen.CARDS[2]
	check(String(speed.get("keys", "")).contains("stalls"), "the desktop Speed card says a held S stalls")


func test_half_spread_or_one_or_two_beats_are_not_the_lessons() -> void:
	# "Spread your wings" is arms out wide (extension 0.75+): arms half out,
	# held far longer than the lesson needs, is not it. "Flap to climb" is
	# three real wingbeats: one or two are not (the round-5 engineering
	# verifier's mutations O2/O3 lowered both and nothing noticed).
	var o := _make()
	o.start()
	var done := _completions(o)
	_run(o, 5.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.5}))
	near(o.progress, 0.0, 1e-6, "arms half out (0.5) for 5 s: no progress")
	_run(o, 5.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.7}))
	near(o.progress, 0.0, 1e-6, "0.7 for 5 s: still not spread wide")
	eq(done, [], "no lesson completed")
	_run(o, 1.1, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.8}))
	eq(done, [&"spread"], "control: 0.8 held 1.1 s spreads the wings")
	o.queue_free()
	var o2 := _make()
	_at(o2, &"flap")
	var done2 := _completions(o2)
	# Two strong strokes (the flapping telemetry up for each downstroke).
	for b in 2:
		o2.notify_flap(0, 0.9)
		_run(o2, 0.4, func(_t: float) -> Dictionary: return tel({"flapping": 0.8, "wing_extension": 0.8, "vertical_speed": 1.0}))
		_run(o2, 0.6, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.8}))
	check(o2.celebrating <= 0.0, "two strong wingbeats are not yet 'Flap to climb' (progress %.2f)" % o2.progress)
	lt(o2.progress, 0.7, "two of three beats: the bar two-thirds full at most (%.2f)" % o2.progress)
	eq(done2, [], "no lesson completed")
	o2.notify_flap(0, 0.9)
	o2.step(DT, tel())
	eq(done2, [&"flap"], "control: the third beat completes it")
	o2.queue_free()


func test_a_timed_out_lesson_is_offered_again_next_session() -> void:
	# Lessons advance on doing, not reading (DESIGN). A lesson nobody did
	# moves on after its timeout, so play is never blocked, but it was not
	# learned: round 4 stored it as done, and an idle player's whole tutorial
	# as complete for good (the round-5 experience verifier's probe).
	var o := _make()
	var timed := []
	o.lesson_completed.connect(func(_i: int, id: StringName, t: bool) -> void:
		if t:
			timed.append(id))
	o.start()
	_run(o, 1.2, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	_finish_celebration(o)
	eq(o.current()["id"], &"flap", "spread done by doing it")
	_run(o, Onboarding.TIMEOUT + 0.5, func(_t: float) -> Dictionary: return tel())
	eq(timed, [&"flap"], "'Flap to climb' timed out")
	_finish_celebration(o)
	eq(o.current()["id"], &"glide", "and play moved on (never blocked)")
	var stored: Array = UIProgress.new(path).lessons_done()
	check(stored.has("spread"), "'spread' (done) is recorded")
	check(not stored.has("flap"), "'flap' (timed out) is not recorded as learned (%s)" % str(stored))
	# 'Glide' done by doing it; the rest time out (the player stops).
	_run(o, 3.2, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0}))
	_finish_celebration(o)
	eq(o.current()["id"], &"speed", "'glide' done")
	while o.active:
		_run(o, Onboarding.TIMEOUT + 0.5, func(_t: float) -> Dictionary: return tel())
		_finish_celebration(o)
	eq(timed, [&"flap", &"speed", &"turn", &"dive", &"catch"], "the lessons not done timed out")
	check(not UIProgress.new(path).onboarding_done(), "an idle player's tutorial is not recorded as complete")
	# Not again in this session (UIRoot calls start() on every resume and
	# respawn: the missed lessons must not restart then)...
	o.start()
	check(not o.active, "the same session does not restart the missed lessons")
	o.queue_free()
	# ...but the next session starts at the first one not learned, and skips
	# what was.
	var o2 := _make()
	var shown := []
	o2.lesson_started.connect(func(_i: int, l: Dictionary) -> void: shown.append(l["id"]))
	o2.start()
	eq(o2.current()["id"], &"flap", "next session: 'Flap to climb' again")
	for i in 3:
		o2.notify_flap(0, 0.9)
	o2.step(DT, tel())
	_finish_celebration(o2)
	eq(o2.current()["id"], &"speed", "then 'Tilt for speed' ('Glide' was learned last time)")
	eq(shown, [&"flap", &"speed"], "'spread' and 'glide' are not taught again")
	check(not UIProgress.new(path).onboarding_done(), "not complete until every lesson was done (or skipped)")
	o2.queue_free()


func test_skip_persists() -> void:
	var o := _make()
	o.start()
	o.skip()
	check(not o.active, "skip stops the lessons")
	var o2 := _make()
	o2.start()
	check(not o2.active, "a new session does not re-teach after skip")
	o2.reset()
	o2.start()
	check(o2.active and o2.index == 0, "Replay tutorial starts again from lesson 1")
	o.queue_free()
	o2.queue_free()


func test_replay_tutorial_in_the_same_session() -> void:
	# The lessons ran to their end this session (an idle player: every one
	# timed out). A resume or respawn does not start them again (they come
	# back next session); Settings > Replay tutorial (reset) does, at once,
	# on the next flight of this session (the round-6 engineering verifier's
	# mutant V17: reset() not clearing the session latch made it a no-op).
	var o := _make()
	o.start()
	var t := 0.0
	while o.active and t < 600.0:
		o.step(0.1, tel())
		t += 0.1
	check(not o.active, "the lessons ran to their end (%.0f s)" % t)
	o.start()
	check(not o.active, "a resume in the same session does not restart them")
	o.reset()
	o.start()
	check(o.active and o.index == 0, "Replay tutorial: lesson 1 again in this session")
	o.queue_free()


func test_partial_progress_resumes() -> void:
	var o := _make()
	o.start()
	_run(o, 1.2, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	_finish_celebration(o)
	eq(o.index, 1, "one lesson done")
	o.queue_free()
	var o2 := _make()
	o2.start()
	eq(o2.index, 1, "next session resumes at lesson 2")
	o2.queue_free()


func test_never_blocks_play_end_to_end() -> void:
	# The real UIRoot with a mock player whose telemetry we script: lessons
	# run from _physics_process while the game stays fully playable.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 3)
	check(k.ui.onboarding.active, "lessons start with the first run")
	check(k.ui.hud.lesson_visible(), "lesson card on the HUD")
	eq(k.ui.hud.lesson_title(), "Spread your wings", "first lesson shown")
	# The live path (Onboarding._physics_process on the player's telemetry),
	# on a clock run 4x fast (Engine.time_scale scales every physics tick's
	# delta and the waits alike; the suite's 60 s budget).
	Engine.time_scale = 4.0
	k.player.tel["wing_extension"] = 0.95
	await wait_seconds(1.3)
	k.player.tel["wing_extension"] = 0.3
	await wait_seconds(Onboarding.CELEBRATE + 0.3)
	eq(k.ui.hud.lesson_title(), "Flap to climb", "advanced on (mock) telemetry, live")
	Events.player_flapped.emit(0, 0.9)
	Events.player_flapped.emit(0, 0.9)
	Events.player_flapped.emit(0, 0.9)
	await wait_physics(3)
	Engine.time_scale = 1.0
	check(k.ui.onboarding.celebrating > 0.0, "wingbeat events complete 'flap'")
	eq(Game.state, Game.State.PLAYING, "never left PLAYING")
	check(not get_tree().paused, "never paused the tree")
	eq(k.player.controls_calls.size(), 0, "never touched the player's controls")
	eq(k.ui.current_screen_id(), &"", "never opened a menu")
	# Skippable from the pause menu.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var skip := k.ui.get_screen(&"pause").get_button(&"skip_tutorial")
	check(skip.visible, "pause menu offers Skip tutorial during lessons")
	await k.click_control(self, skip)
	check(not k.ui.onboarding.active, "skipped")
	check(not skip.visible, "button hides once skipped")
	check(UIProgress.new(k.progress_path).onboarding_done(), "skip persisted")
	k.teardown()
	await wait_frames(2)


## Start at lesson `id` (earlier ones marked done).
func _at(o: Onboarding, id: StringName) -> void:
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] == id:
			break
		o.progress_store.mark_lesson(l["id"])
	o.start()
	eq(o.current()["id"], id, "at lesson %s" % id)


## Lessons completed on `o` from now on (a lesson that completes moves on,
## so progress alone could read 0 again on the next lesson).
func _completions(o: Onboarding) -> Array:
	var done := []
	o.lesson_completed.connect(func(_i: int, id: StringName, _t: bool) -> void: done.append(id))
	return done


func test_weak_or_wrong_gestures_do_not_pass_speed_turn_or_dive() -> void:
	# Each lesson's detector rejects the nearly-right thing a player does
	# by accident, for much longer than the real gesture needs.
	var o := _make()
	_at(o, &"speed")
	var done := _completions(o)
	# Speed and height changing without any tilt (a gust, a zoom after
	# flapping, the speed coming back after it) are not "tilting for speed".
	_run(o, 5.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 8.0 + 3.0 * sin(t * 2.0), "vertical_speed": 3.0 * cos(t * 2.0)}))
	near(o.progress, 0.0, 1e-6, "speed and height swinging with the wrists neutral: nothing")
	# Speed gained by flapping is not tilting either, wrists or not.
	_run(o, 3.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.5, "airspeed": 8.0 + t * 2.0, "flapping": 0.6}))
	near(o.progress, 0.0, 1e-6, "a tilt while flapping does not count")
	# A tilt that does nothing (held 5 s, speed flat) is not the lesson.
	_run(o, 5.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.5, "airspeed": 8.0}))
	lt(o.progress, 0.01, "a tilt with no effect: no progress (%.2f)" % o.progress)
	# Nor one while the speed only drifts up 0.3 m/s (3.75 %) in 5 s: under
	# the effect the lesson asks for (0.5 m/s or 5 %), a gust's worth. And
	# a nose-up tilt rising only 0.6 m/s (a balloon is 1 m/s) while losing
	# 0.6 m/s of speed: no balloon.
	_run(o, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	_run(o, 5.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.5, "airspeed": 8.0 + 0.06 * t}))
	check(o.celebrating <= 0.0, "a tilt with a 0.3 m/s drift is not the lesson (progress %.2f)" % o.progress)
	_run(o, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	_run(o, 5.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": 0.5, "airspeed": 8.0 - 0.12 * t, "vertical_speed": 0.12 * t}))
	check(o.celebrating <= 0.0, "a nose-up tilt rising 0.6 m/s is not a balloon (progress %.2f)" % o.progress)
	_run(o, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	_run(o, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	# A tilt let go every 0.6 s never adds up: the window starts again.
	_run(o, 6.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.5 if fmod(t, 1.2) < 0.6 else 0.0,
		"airspeed": 8.0 + fmod(t, 1.2) * 3.0}))
	check(o.celebrating <= 0.0, "0.6 s tilts, let go in between, never complete it (progress %.2f)" % o.progress)
	# Too small a twist (|pitch_input| 0.1: inside the wrists' natural wobble).
	_run(o, 5.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "pitch_input": -0.1, "airspeed": 8.0 + t}))
	check(o.celebrating <= 0.0, "a 0.1 twist is not a tilt")
	eq(done, [], "no lesson completed")
	eq(o.current()["id"], &"speed", "still on 'speed'")
	o.queue_free()
	var o2 := _make()
	_at(o2, &"turn")
	var done2 := _completions(o2)
	# Rocking the wings +-10 deg (steadying, not turning): never 20 deg.
	_run(o2, 6.0, func(t: float) -> Dictionary: return tel({"wing_extension": 0.9, "bank": deg_to_rad(10.0) * sin(t * 3.0)}))
	near(o2.progress, 0.0, 1e-6, "a +-10 deg wobble is not a banked turn")
	# A proper bank that is held too briefly (0.5 s) does not complete it.
	_run(o2, 0.5, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "bank": deg_to_rad(30.0)}))
	check(o2.celebrating <= 0.0, "half a second of bank is not yet a turn")
	eq(done2, [], "no lesson completed by the wobble")
	eq(o2.current()["id"], &"turn", "still on 'turn'")
	o2.queue_free()
	var o3 := _make()
	_at(o3, &"dive")
	var done3 := _completions(o3)
	# Tucked but only sinking gently (-1 m/s): not a dive.
	_run(o3, 5.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.1, "tucked": true, "vertical_speed": -1.0}))
	near(o3.progress, 0.0, 1e-6, "a gentle -1 m/s sink is not a dive")
	# Dropping fast with wings spread (a stall) is not a tucked dive.
	_run(o3, 3.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "vertical_speed": -6.0}))
	near(o3.progress, 0.0, 1e-6, "falling with wings out is not a tucked dive")
	eq(done3, [], "no lesson completed")
	eq(o3.current()["id"], &"dive", "still on 'dive'")
	o3.queue_free()


func test_gliding_at_rest_or_a_dip_is_not_a_lesson() -> void:
	# "Glide" means gliding through the air: arms out and still while
	# hovering at a standstill (the simulator's fixed controllers, a player
	# standing on a branch with arms out) must not pass it.
	var o := _make()
	_at(o, &"glide")
	var done := _completions(o)
	_run(o, 6.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.95, "airspeed": 0.0}))
	near(o.progress, 0.0, 1e-6, "arms out at 0 m/s is not a glide")
	_run(o, 6.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.95, "airspeed": 1.0}))
	near(o.progress, 0.0, 1e-6, "nor drifting at 1 m/s")
	eq(done, [], "no lesson completed")
	# Control: the same pose at flying speed is a glide (3 s).
	_run(o, 3.2, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.95, "airspeed": 6.0}))
	eq(done, [&"glide"], "arms out and still at 6 m/s completes 'glide'")
	o.queue_free()
	# A dive is held, not a dip: 0.3 s tucked at -5 m/s (a stumble off a
	# branch) must not complete it. (Hold time adds up across tries, as in
	# every lesson: a learner who dives in two goes has still dived.)
	var o2 := _make()
	_at(o2, &"dive")
	var done2 := _completions(o2)
	_run(o2, 0.3, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.1, "tucked": true, "vertical_speed": -5.0}))
	_run(o2, 2.0, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9}))
	check(o2.celebrating <= 0.0, "a 0.3 s dip does not complete 'dive' (progress %.2f)" % o2.progress)
	eq(done2, [], "no lesson completed by a dip")
	between(o2.progress, 0.3, 0.45, "it counts as a start (0.3 of 0.8 s: %.2f)" % o2.progress)
	# Control: a real 0.9 s tucked dive completes it.
	_run(o2, 0.9, func(_t: float) -> Dictionary: return tel({"wing_extension": 0.1, "tucked": true, "vertical_speed": -5.0}))
	eq(done2, [&"dive"], "a held tucked dive completes 'dive'")
	o2.queue_free()


func test_catch_lesson_never_names_a_bird_the_hud_says_to_ignore() -> void:
	# The pause screen and tier-ups tell a swallow and up to IGNORE moths;
	# a sparrow becomes a swallow after 3 wren catches, which can happen
	# during the lessons. So the catch lesson names a species only while the
	# pause screen lists it under "Hunt" at the player's size (round 3 said
	# "Catch a moth" to everyone); without lesson prey it names none.
	var lesson: Dictionary = Onboarding.LESSONS[Onboarding.LESSONS.size() - 1]
	eq(lesson["id"], &"catch", "the last lesson is the catch")
	var bad: Array = []
	var named := 0
	var n := 0
	for tier in SizeRules.SPECIES.size():
		for f: float in [0.99, 1.01, 1.4]:
			var mass := float(SizeRules.SPECIES[tier]["mass"]) * f
			var chain := PauseScreen.food_chain(mass)
			var texts: Array[String] = []
			for level in Onboarding.CATCH_HINT_LEVELS + 2:
				for glow: bool in [false, true]:
					texts.append(_copy_text(Onboarding.catch_copy({}, level, mass)))
					for sp: Dictionary in SizeRules.SPECIES:
						var c := Onboarding.catch_copy({"species": sp["id"], "glow": glow}, level, mass)
						var t := _copy_text(c)
						texts.append(t)
						var i := SizeRules.species_index(sp["id"])
						if t.contains(String(sp["name"]).to_lower()):
							named += 1
							if not (i in chain["prey"]):
								bad.append("%.3f kg: '%s' names %s (not under Hunt)" % [mass, c["title"], sp["name"]])
						elif i in chain["prey"] and c["title"] != "Catch %s" % UIScreen.a_an(String(sp["name"])):
							bad.append("%.3f kg: lesson %s not named ('%s')" % [mass, sp["name"], c["title"]])
			for t in texts:
				n += 1
				for i: int in chain["dust"]:
					if t.contains(String(SizeRules.SPECIES[i]["name"]).to_lower()):
						bad.append("%.3f kg: '%s' names %s, which the HUD says to ignore" % [mass, t, SizeRules.SPECIES[i]["name"]])
	eq(bad, [], "the catch lesson names only the lesson prey the HUD says to hunt")
	gt(named, 100, "it does name the lesson prey when they are worth it (%d of %d cases)" % [named, n])
	# Without lesson prey the words are the ring's, as before.
	var plain := Onboarding.catch_copy({}, 0, 0.03)
	eq([plain["title"], plain["hint"], plain["keys"]], ["Catch prey", "Chase a ringed bird", "Chase a ringed bird"], "no lesson prey: the ring")
	var lit := Onboarding.catch_copy({"species": &"moth", "glow": true}, 0, 0.03)
	eq([lit["title"], lit["hint"]], ["Catch a Moth", "It glows: fly into it"], "glowing lesson moths for a sparrow: named, and what to do")
	var unlit := Onboarding.catch_copy({"species": &"moth"}, 0, 0.03)
	eq([unlit["title"], unlit["hint"], unlit["keys"]], ["Catch a Moth", "Fly right into one", "Fly into one: A or D"],
		"lesson moths that do not glow are not said to (GameLoop rings them)")
	var grown := Onboarding.catch_copy({"species": &"moth"}, 0, 0.08)
	eq([grown["title"], grown["hint"]], ["Catch prey", "Chase a ringed bird"], "moths a swallow is told to ignore: not named")


static func _copy_text(c: Dictionary) -> String:
	return ("%s %s %s" % [c["title"], c["hint"], c["keys"]]).to_lower()


## Integration round 2 made the catch lesson wait 300 s for the first catch;
## the lead (core-loop round): no dead end, and when the player struggles,
## bring the prey closer rather than timing out silently. Every
## CATCH_HELP_S of play without a catch the lesson asks for help (the game
## brings its lesson prey closer) and says more; the prey are asked for
## before the card first shows (its words name them) and let go when the
## lesson ends, however it ends.
func test_the_catch_lesson_helps_a_struggling_player() -> void:
	var o := _make()
	o.mass_provider = func() -> float: return 0.03
	var seen: Array = []
	o.catch_lesson.connect(func(on: bool) -> void:
		seen.append("prey %s" % ("on" if on else "off"))
		# (What UIRoot does: the game's answer.)
		if on:
			o.set_catch_prey({"species": &"moth", "glow": true}))
	o.lesson_started.connect(func(_i: int, l: Dictionary) -> void: seen.append("card: %s / %s" % [l["title"], l["hint"]]))
	o.lesson_changed.connect(func(_i: int, l: Dictionary) -> void: seen.append("words: %s / %s" % [l["title"], l["hint"]]))
	o.catch_help.connect(func(level: int) -> void: seen.append("help %d" % level))
	var helps := func() -> int: return seen.filter(func(e: String) -> bool: return e.begins_with("help")).size()
	_at(o, &"catch")
	eq(seen.slice(0, 3), ["prey on", "words: Catch a Moth / It glows: fly into it", "card: Catch a Moth / It glows: fly into it"],
		"the lesson prey are asked for before the card shows, and the card names them")
	var flying := func(_t: float) -> Dictionary: return tel({"wing_extension": 0.9, "airspeed": 9.0})
	_run(o, Onboarding.CATCH_HELP_S - 0.5, flying)
	eq(helps.call(), 0, "no help in the first %d s" % int(Onboarding.CATCH_HELP_S))
	_run(o, 1.0, flying)
	eq(helps.call(), 1, "help after %d s without a catch" % int(Onboarding.CATCH_HELP_S))
	eq(seen[-1], "words: Catch a Moth / Follow the arrow", "and the hint says more: the cue points at it")
	_run(o, Onboarding.CATCH_HELP_S, flying)
	eq(helps.call(), 2, "more help after another %d s" % int(Onboarding.CATCH_HELP_S))
	eq(seen[-1], "words: Catch a Moth / Fly straight into it", "then: fly straight into it")
	var words0 := seen.filter(func(e: String) -> bool: return e.begins_with("words")).size()
	_run(o, Onboarding.CATCH_HELP_S * 4.0, flying)
	eq(helps.call(), 6, "help keeps coming every %d s (6 by %d s)" % [int(Onboarding.CATCH_HELP_S), int(o._elapsed)])
	var help_levels := seen.filter(func(e: String) -> bool: return e.begins_with("help")).map(func(e: String) -> int: return int(e.get_slice(" ", 1)))
	eq(help_levels, range(1, 7), "levels 1, 2, ... in order")
	eq(seen.filter(func(e: String) -> bool: return e.begins_with("words")).size(), words0, "the words stay after level %d" % Onboarding.CATCH_HINT_LEVELS)
	check(o.teaching_catch(), "still the catch lesson (%d s)" % int(o._elapsed))
	# While the player closes on a lesson bird (UIRoot's help_ok) the help
	# waits: it would put the swarm ahead again, from under the beak.
	var closing := [true]
	o.help_ok = func() -> bool: return not closing[0]
	var n := helps.call() as int
	_run(o, Onboarding.CATCH_HELP_S * 2.0, flying)
	eq(helps.call(), n, "no help while the player closes on one (%d s)" % int(Onboarding.CATCH_HELP_S * 2.0))
	closing[0] = false
	o.step(DT, tel({"wing_extension": 0.9, "airspeed": 9.0}))
	eq(helps.call(), n + 1, "and at once when it stops closing")
	o.help_ok = Callable()
	# A catch ends it: learned, and the prey let go, once.
	var done := _completions(o)
	var me := UIMockPlayer.new()
	var moth := Bird.new()
	o.notify_catch(me, moth)
	o.step(DT, tel())
	eq(done, [&"catch"], "the catch completes it")
	eq(seen.filter(func(e: String) -> bool: return e == "prey off").size(), 1, "the lesson prey are let go once")
	var n_done := helps.call() as int
	_run(o, Onboarding.CELEBRATE + Onboarding.CATCH_HELP_S + 1.0, flying)
	eq(helps.call(), n_done, "no help after the lesson")
	me.free()
	moth.free()
	o.queue_free()
	# The help clock counts play only (step), restarts with the lesson, and
	# a skip or a reset also lets the prey go.
	for how: String in ["skip", "reset", "timeout"]:
		path = path + "_" + how
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var o2 := _make()
		var offs := [0]
		var levels := []
		o2.catch_lesson.connect(func(on: bool) -> void:
			if not on:
				offs[0] += 1)
		o2.catch_help.connect(func(level: int) -> void: levels.append(level))
		_at(o2, &"catch")
		_run(o2, Onboarding.CATCH_HELP_S + 1.0, flying)
		eq(levels, [1], "%s: one help step before it" % how)
		match how:
			"skip":
				o2.skip()
			"reset":
				o2.reset()
			"timeout":
				_run(o2, Onboarding.CATCH_TIMEOUT, flying)
		eq(offs[0], 1, "%s: the lesson prey are let go once" % how)
		check(not o2.teaching_catch(), "%s: the catch lesson is over" % how)
		o2.queue_free()


## The catch lesson through UIRoot and GameBridge with a GameLoop that has
## the lesson-prey API (UIMockGameLoop records the calls): the prey are
## asked for when the lesson begins and the card names them; help steps ask
## for the prey to come closer; a catch, a run ending mid-lesson or a skip
## lets them go, and a new run asks again. A GameLoop without the API: the
## ring's words, and the lesson still helps with words.
func test_the_catch_lesson_uses_the_games_lesson_prey() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] != &"catch":
			k.ui.progress.mark_lesson(l["id"])
	k.gl.lesson_species = &"moth"
	var o := k.ui.onboarding
	o.auto_step = false
	var hint := func() -> String: return k.ui.hud.lesson_labels()[2].text
	k.gl.start_run()
	await k.settle(self, 3)
	check(o.teaching_catch(), "the catch lesson is up")
	eq(k.gl.lesson_prey_calls, [["request", 1]], "GameLoop was asked for the lesson prey once")
	eq(k.gl.lesson_prey().size(), 3, "(the mock's swarm is up)")
	eq([k.ui.hud.lesson_title(), hint.call()], ["Catch a Moth", "Fly right into one"], "the card names them and says what to do")
	for i in int((Onboarding.CATCH_HELP_S + 0.5) / DT):
		o.step(DT, tel({"wing_extension": 0.9, "airspeed": 9.0}))
	eq(k.gl.lesson_prey_calls, [["request", 1], ["request", 2]], "struggling for %d s: asked again (the swarm comes nearer)" % int(Onboarding.CATCH_HELP_S))
	eq(hint.call(), "Follow the arrow", "and the card says more")
	# A run that ends mid-lesson lets them go; the next run asks again.
	k.gl.fake_end()
	await k.settle(self, 2)
	eq(k.gl.lesson_prey_calls.back(), ["release"], "the run ended: the prey are released")
	k.gl.start_run()
	await k.settle(self, 3)
	eq(k.gl.lesson_prey_calls.back(), ["request", 1], "a new run with the lesson still up asks again")
	eq([k.ui.hud.lesson_title(), hint.call()], ["Catch a Moth", "Follow the arrow"], "(the help so far stands)")
	# The catch: one of the lesson's moths.
	var moth: Bird = k.gl.lesson_prey()[0]
	Events.bird_caught.emit(k.player, moth)
	o.step(DT, tel())
	eq(k.gl.lesson_prey_calls.back(), ["release"], "the first catch ends the lesson and releases the prey")
	eq(hint.call(), "Nice!", "and says so")
	var calls := k.gl.lesson_prey_calls.size()
	for i in int(Onboarding.CATCH_HELP_S * 2.0 / DT):
		o.step(DT, tel())
	eq(k.gl.lesson_prey_calls.size(), calls, "nothing more is asked after the lesson")
	check(not o.active, "the tutorial is over")
	k.teardown()
	await wait_frames(2)
	# What the words read from the birds: the species of the first live one,
	# and a glow only if its model says so.
	var lit := UIStandInBird.new(&"moth", 0.004)
	lit.model.glow = true
	var dead := UIStandInBird.new(&"wren", 0.012)
	dead.alive = false
	eq(GameBridge.lesson_prey_info([dead, lit]), {"species": &"moth", "glow": true, "count": 1}, "a glowing moth (the dead wren skipped)")
	eq(GameBridge.lesson_prey_info([]), {}, "no birds: nothing")
	eq(GameBridge.lesson_prey_info(null), {}, "no answer: nothing")
	lit.free()
	dead.free()
	# Without the API (a GameLoop that has none: the mock's calls hidden by
	# an empty answer and a plain node): the ring's words, help in words.
	var k2 := Kit.new()
	k2.setup(self, true)
	await k2.settle(self, 3)
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] != &"catch":
			k2.ui.progress.mark_lesson(l["id"])
	var plain := Node.new()
	add_child(plain)
	k2.ui.bridge.game_loop = plain
	var o2 := k2.ui.onboarding
	o2.auto_step = false
	Game.set_state(Game.State.PLAYING)
	await k2.settle(self, 3)
	check(o2.teaching_catch(), "the catch lesson is up without the API")
	eq([k2.ui.hud.lesson_title(), k2.ui.hud.lesson_labels()[2].text], ["Catch prey", "Chase a ringed bird"], "the ring's words")
	for i in int((Onboarding.CATCH_HELP_S + 0.5) / DT):
		o2.step(DT, tel({"wing_extension": 0.9, "airspeed": 9.0}))
	eq(k2.ui.hud.lesson_labels()[2].text, "Follow the arrow", "help in words")
	o2.skip()
	check(not o2.teaching_catch(), "skipped")
	plain.queue_free()
	k2.teardown()
	await wait_frames(2)


## Help puts the lesson swarm ahead of the player again: UIRoot holds it
## back while the player is closing on one of the lesson's birds (within 60
## of its wingspans, gaining 4 wingspans a second), or it would take the
## moth from under the beak.
func test_help_waits_while_the_player_closes_on_a_lesson_bird() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] != &"catch":
			k.ui.progress.mark_lesson(l["id"])
	k.gl.lesson_species = &"moth"
	var o := k.ui.onboarding
	o.auto_step = false
	k.gl.start_run()
	await k.settle(self, 3)
	k.ui.set_process(false)
	check(o.teaching_catch(), "the catch lesson is up")
	var moth: Bird = k.gl.lesson_prey()[1]
	var frame := func(v: Vector3) -> void:
		k.player.global_position += v * DT
		k.ui.call(&"_track_lesson_prey", k.player, DT)
		o.step(DT, tel({"wing_extension": 0.9, "airspeed": 9.0}))
	# 29 s holding station 14 m from the swarm, then flying at a moth.
	for i in int(29.0 / DT):
		frame.call(Vector3.ZERO)
	eq(k.gl.lesson_prey_calls, [["request", 1]], "no help yet")
	var t := 0.0
	var d0 := moth.global_position.distance_to(k.player.get_body_position())
	while t < 1.5:
		var to := (moth.global_position - k.player.global_position).normalized()
		frame.call(to * 8.0)
		t += DT
	eq(k.gl.lesson_prey_calls, [["request", 1]], "31 s in, closing on a moth (%.1f -> %.1f m): help waits" % [d0, moth.global_position.distance_to(k.player.get_body_position())])
	# It veers away: help comes at once.
	for i in 30:
		frame.call(Vector3(8.0, 0.0, 8.0))
	eq(k.gl.lesson_prey_calls, [["request", 1], ["request", 2]], "veering away: help comes")
	k.ui.set_process(true)
	k.teardown()
	await wait_frames(2)


func test_lessons_only_count_while_playing() -> void:
	# Live lessons advance only in PLAYING: not on the caught screen (the
	# game is not paused there), a menu or the run summary.
	var o := Onboarding.new()
	o.progress_store = UIProgress.new(path)
	var me := UIMockPlayer.new()
	me.tel["wing_extension"] = 0.95
	o.telemetry_provider = func() -> Dictionary: return me.tel
	add_child(o)
	# The live path (auto_step), driven tick by tick instead of in real time.
	o.set_physics_process(false)
	var tick := func(seconds: float) -> void:
		for i in int(seconds * 60.0):
			o._physics_process(1.0 / 60.0)
	Game.set_state(Game.State.PLAYING)
	o.start()
	Game.set_state(Game.State.CAUGHT)
	tick.call(2.0)
	near(o.progress, 0.0, 1e-6, "arms out on the caught screen do not teach 'spread'")
	Game.set_state(Game.State.ENDED)
	tick.call(2.0)
	near(o.progress, 0.0, 1e-6, "nor on the run summary")
	Game.set_state(Game.State.PLAYING)
	tick.call(1.2)
	check(o.celebrating > 0.0, "the same gesture in play completes 'spread'")
	tick.call(Onboarding.CELEBRATE + 0.1)
	eq(o.current()["id"], &"flap", "on to 'flap'")
	Game.set_state(Game.State.CAUGHT)
	for i in 3:
		o.notify_flap(0, 0.9)
	Game.set_state(Game.State.PLAYING)
	tick.call(0.1)
	near(o.progress, 0.0, 1e-6, "wingbeats while caught do not count")
	Game.set_state(Game.State.MENU)
	o.queue_free()
	me.free()


# --- "Tilt for speed" on the real flight model ---------------------------------

## The recorded "Tilt for speed" flights (tests/shots/ui_flight_record.gd
## flew them on the real FlightModel: a sparrow or an eagle from trim, a
## symmetric wing-pitch command from `tilt_at` on, flapping bursts or not),
## replayed here so this suite never calls flight's internals.
static func _tilt_runs() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_flight_runs.json"))
	return (d as Dictionary).get("tilt", {}) if d is Dictionary else {}


## Replay recorded flight `run` into an Onboarding on "Tilt for speed", with
## the telemetry PlayerBird reports: airspeed, vertical_speed, `flapping` as
## WingInput's 0.3 s low-pass of the stroke, `pitch_input` = WingState.pitch;
## wings spread, not tucked or perched.
func _replay_speed_lesson(run: Dictionary) -> Dictionary:
	var own := "user://ui_onboarding_speed_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	var o := Onboarding.new()
	o.auto_step = false
	o.progress_store = UIProgress.new(own)
	add_child(o)
	_at(o, &"speed")
	var result := {"done_at": -1.0, "timed_out": false}
	o.lesson_completed.connect(func(_i: int, id: StringName, timed: bool) -> void:
		if id == &"speed" and float(result["done_at"]) < 0.0:
			result["timed_out"] = timed
			result["done_at"] = -2.0 if timed else 0.0)
	var dt := float(run["dt"])
	var tilt_at := float(run["tilt_at"])
	var cols: Dictionary = run["columns"]
	var done_at := -1.0
	var max_prog := 0.0
	for i in int(run["frames"]):
		var t := i * dt
		o.step(dt, {"airspeed": float(cols["airspeed"][i]), "vertical_speed": float(cols["vertical_speed"][i]),
			"flapping": float(cols["flapping"][i]), "pitch_input": float(cols["pitch_input"][i]),
			"wing_extension": 1.0, "tucked": false, "perched": false})
		if float(result["done_at"]) == 0.0 and done_at < 0.0:
			done_at = t - tilt_at
		if float(result["done_at"]) == -1.0:
			# Progress while still on the lesson (a timeout fills the bar).
			max_prog = maxf(max_prog, o.progress)
	o.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(own))
	return {"completed_after_s": snappedf(done_at, 0.01), "max_progress": snappedf(max_prog, 0.01), "timed_out": result["timed_out"]}


func test_speed_lesson_needs_the_tilt_on_the_real_flight_model() -> void:
	# Round 4: flapping and gliding with the wrists neutral (what lessons 2
	# and 3 just taught) completed "Tilt for speed" in 1.5-3 s on the real
	# FlightModel: a post-flap zoom counted as a balloon, the speed coming
	# back after it as "speed gained". Now the lesson needs the tilt itself.
	var recorded := _tilt_runs()
	var runs := {}
	var bad: Array = []
	var neutral := 0
	var tilts := 0
	for key: String in recorded:
		var run: Dictionary = recorded[key]
		var r := _replay_speed_lesson(run)
		runs[key] = r
		if key.contains("neutral"):
			neutral += 1
			if float(r["completed_after_s"]) >= 0.0 or float(r["max_progress"]) > 0.0:
				bad.append("%s: %s" % [key, str(r)])
		else:
			# A tilt of +-0.35 or +-0.6 while gliding, and flap-then-tilt at
			# once (the tilt counts from when the wingbeats die away).
			tilts += 1
			if float(r["completed_after_s"]) < 0.0 or float(r["completed_after_s"]) > 3.0:
				bad.append("%s: not within 3 s (%s)" % [key, str(r)])
	metric("speed_lesson_flight_model", runs)
	eq(neutral, 8, "8 neutral-wrist flights (1+3, 2+2, 3+3, glide; sparrow and eagle; 60 s each) recorded")
	eq(tilts, 9, "9 tilt flights recorded")
	eq(bad, [], "neutral wrists never complete 'Tilt for speed' in 60 s; a real tilt does within 3 s")
