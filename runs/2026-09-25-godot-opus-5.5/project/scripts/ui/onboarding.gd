class_name Onboarding
extends Node
## First-flight lessons that advance on *doing*, not reading.
##
## Each lesson watches PlayerBird.telemetry() (and a couple of Events) for the
## gesture it teaches, fills a progress bar while the player does it, shows a
## short "nice!" beat, then moves on. It never pauses, never disables
## controls and never waits on a button: a lesson nobody completes moves on
## by itself after TIMEOUT seconds, and the whole thing can be skipped from
## the pause menu. Each lesson the player actually *did* is persisted
## (UIProgress), so returning players are not taught it again; a lesson that
## timed out was not learned, so it is not recorded, and the next session
## (not the next resume or respawn of this one) offers it again. The whole
## tutorial counts as done once every lesson was done, or it was skipped;
## Settings > Replay tutorial brings it back.
##
## The detection thresholds are the contract with flight's telemetry keys:
## wing_extension, flapping, airspeed, vertical_speed, bank, tucked, perched,
## pitch_input (PlayerBird: WingState.pitch, the symmetric wing-pitch
## command, + = leading edges up).

signal lesson_started(index: int, lesson: Dictionary)
signal lesson_progress(index: int, progress: float)
signal lesson_completed(index: int, lesson_id: StringName, timed_out: bool)
signal finished(skipped: bool)
## The words of the lesson on show changed (the catch lesson: the game's
## lesson prey arrived, or the player needs more help). `lesson` is what
## current_view() returns.
signal lesson_changed(index: int, lesson: Dictionary)
## The catch lesson has gone another CATCH_HELP_S without a catch: help
## `level` (1, 2, ...). UIRoot asks the game to put its lesson prey ahead
## of the player again, nearer.
signal catch_help(level: int)
## The catch lesson began or ended (by a catch, its timeout, a skip or a
## reset): UIRoot starts and stops the game's lesson prey.
signal catch_lesson(on: bool)

## Short enough for the lesson card's text column (HUD.CARD_TEXT_W, 548 px:
## the card's words then end within 35 deg of a level gaze), pinned by
## ui_hud_test and ui_legibility_test. The hints name the gesture.
## "keys": the same step on the desktop (DesktopPoseSource's keys; the HUD
## shows it instead of "hint" outside VR - integration round 2: no desktop
## screen named a key).
const LESSONS: Array[Dictionary] = [
	{"id": &"spread", "art": &"spread", "title": "Spread your wings", "hint": "Arms out, relaxed", "keys": "No key: wings open"},
	{"id": &"flap", "art": &"flap", "title": "Flap to climb", "hint": "Sweep down hard", "keys": "Hold Space to flap"},
	{"id": &"glide", "art": &"glide", "title": "Glide", "hint": "Arms out, hold still", "keys": "Let go of all keys"},
	{"id": &"speed", "art": &"speed", "title": "Tilt for speed", "hint": "Twist wrists down", "keys": "W faster, S balloon"},
	{"id": &"turn", "art": &"turn", "title": "Bank to turn", "hint": "Tip one arm down", "keys": "A or D to bank"},
	{"id": &"dive", "art": &"dive", "title": "Tuck to dive", "hint": "Pull both arms in", "keys": "Hold Shift to dive"},
	# The words shown are catch_copy()'s: they name the game's lesson prey
	# (GameLoop's lesson-prey API, when there is one) and what to do with
	# them, and change as the player needs more help. Without lesson prey
	# they name no species: what is worth chasing changes as you grow (the
	# pause screen soon says "Ignore: Moth"), and a lesson must not
	# contradict it ("Prey" is the pause screen's word); the hint names the
	# cue that says which birds are prey: the ring round them.
	# Waits CATCH_TIMEOUT, not TIMEOUT (integration round 2: in real play the
	# first catch came 39-390 s after the lessons, median ~110 s), and never
	# as a dead end: every CATCH_HELP_S without a catch it asks for help
	# (catch_help: the game brings its prey closer) and says more.
	{"id": &"catch", "art": &"hunt", "title": "Catch prey", "hint": "Chase a ringed bird", "keys": "Chase a ringed bird",
		"timeout": CATCH_TIMEOUT},
]

## Seconds a lesson waits before moving on by itself (a lesson's own
## "timeout" wins)...
const TIMEOUT := 45.0
## ...the catch lesson's: it stays until the first catch, or five minutes
## (by then it has asked for help every CATCH_HELP_S, 9 times).
const CATCH_TIMEOUT := 300.0
## The catch lesson asks for help (catch_help) after this long without a
## catch, and again every time as long passes, until the lesson ends: the
## game puts its lesson prey ahead of the player again, nearer each time.
## Not while the player is closing on one of them (help_ok: UIRoot), which
## would take the moth from under its beak. A sparrow's first catch took
## 39-390 s in real play (integration round 2), and GameLoop's own catch
## assist starts after 30 s without one.
const CATCH_HELP_S := 30.0
## The hint says more at each of the first this many steps of help (the
## words of catch_copy), then stays.
const CATCH_HINT_LEVELS := 2
## Seconds the "done" beat shows before the next lesson.
const CELEBRATE := 1.3

# Detection thresholds (see docs/areas/UI.md, U5).
const SPREAD_EXT := 0.75
const SPREAD_HOLD := 1.0
const FLAP_COUNT := 3
const FLAP_MIN_STRENGTH := 0.25
const FLAP_TELEMETRY_HOLD := 1.5
const GLIDE_MAX_FLAP := 0.15
const GLIDE_MIN_EXT := 0.6
const GLIDE_MIN_SPEED := 2.0
const GLIDE_HOLD := 3.0
# "Tilt for speed" (the brief's requirement 2: speed via angle of attack)
# needs the input it teaches AND the effect of that input, in one window:
# the window opens while the bird glides (not flapping) with both wings
# pitched past TILT_INPUT, and starts again from scratch whenever the tilt
# is let go or reversed, or the bird flaps, tucks or lands. The effect is
# measured from the window's opening. So ordinary flap-and-glide flight
# (the post-flap zoom, the speed coming back after it) can never pass it:
# with the wrists neutral no window ever opens. (A zoom's fading climb can
# only count against a balloon measured from where it began.) Round 3
# counted any climb without flapping and any speed above the lesson's
# slowest moment, and flapping and gliding completed it in 1.5-3 s.
## |pitch_input| that counts as a deliberate tilt (about a 12-14 deg wrist
## twist through WingInput's shaping)...
const TILT_INPUT := 0.15
## ...held for at least this long, in one window.
const TILT_HOLD := 1.0
## Leading edges down: the airspeed rises by this much since the window
## opened (m/s, or TILT_SPEED_FRAC of the speed then, whichever is more).
## Leading edges up: the bird balloons: its vertical speed rises by
## BALLOON_LIFT (m/s) while the airspeed falls by the same amount as above.
const TILT_SPEED_GAIN := 0.5
const TILT_SPEED_FRAC := 0.05
const BALLOON_LIFT := 1.0
const TURN_BANK := deg_to_rad(20.0)
const TURN_HOLD := 1.2
const DIVE_VS := -3.0
const DIVE_HOLD := 0.8

var progress_store: UIProgress
## False when a test drives step() by hand.
var auto_step := true
## -> Dictionary; defaults to Birds.player().telemetry().
var telemetry_provider: Callable
var index := -1
var progress := 0.0
var active := false
## Seconds left in the "done" beat (> 0 while celebrating).
var celebrating := 0.0

var _elapsed := 0.0
## The lessons ran to the end in this session (some may have timed out: they
## come back next session, not at every resume of this one).
var _ran := false
var _hold := 0.0
var _count := 0
## The tilt window (see TILT_*): its sign (0 = closed), seconds held, the
## airspeed and vertical speed when it opened, and the best effect so far
## (0..1).
var _tilt_sign := 0
var _tilt_t := 0.0
var _tilt_v0 := 0.0
var _tilt_vs0 := 0.0
var _tilt_effect := 0.0
## What the game offers for the catch lesson (UIRoot sets it from GameLoop's
## lesson-prey API, set_catch_prey; {} = nothing special): "species"
## (StringName) the lesson prey are, "glow" (bool) whether they shine.
var catch_prey := {}
## The catch lesson's help so far (0: none yet; see CATCH_HELP_S), and the
## seconds of play since the last step of it.
var help_level := 0
var _help_t := 0.0
## catch_lesson was last emitted with true.
var _catch_on := false
## -> float: the player's mass (kg), for catch_copy (a species is named only
## while it is worth chasing). Defaults to Birds.player().mass.
var mass_provider: Callable
## -> bool: whether help may come now (UIRoot: not while the player is
## closing on a lesson moth). Unset: always.
var help_ok: Callable


func _init() -> void:
	# Lessons advance on gameplay; freezing with the tree is correct.
	process_mode = Node.PROCESS_MODE_PAUSABLE


func is_done() -> bool:
	return progress_store != null and progress_store.onboarding_done()


func current() -> Dictionary:
	return LESSONS[index] if index >= 0 and index < LESSONS.size() else {}


## The current lesson as shown: current(), with the catch lesson's words
## from catch_copy (the lesson prey, the help so far).
func current_view() -> Dictionary:
	var l := current()
	if l.get("id") != &"catch":
		return l
	var v := l.duplicate()
	v.merge(catch_copy(catch_prey, help_level, _player_mass()), true)
	return v


## True while the catch lesson is being taught (up, not in its done beat).
func teaching_catch() -> bool:
	return active and current().get("id") == &"catch" and celebrating <= 0.0


## The game's lesson prey for the catch lesson ({} = none): see catch_prey.
## The card's words follow at once.
func set_catch_prey(info: Dictionary) -> void:
	if info == catch_prey:
		return
	catch_prey = info.duplicate()
	if teaching_catch():
		lesson_changed.emit(index, current_view())


## The catch lesson's words (title, VR hint, desktop keys) for the game's
## lesson prey `prey` (see catch_prey; {} = none), after `level` steps of
## help, for a player of `mass` kg. Pure, so every case is pinned by tests
##   no lesson prey:  "Catch prey"   / "Chase a ringed bird" (the cue's ring)
##   lesson moths:    "Catch a Moth" / "Fly right into one"
##                    ("It glows: fly into it" if their model glows)
##   more help:       "Follow the arrow" (the target cue), then (level 2
##                    and on) "Fly straight into it"
## A species is named only while the pause screen lists it under "Hunt" at
## `mass` (worth chasing, SizeRules.is_worthwhile, and not the player's own
## kind): the pause screen and the celebrations tell a grown player to
## ignore the smallest birds, and a lesson must not contradict them. Every line fits the lesson card's text column (548 px;
## pinned by ui_legibility_test for every species and level).
static func catch_copy(prey: Dictionary, level: int, mass: float) -> Dictionary:
	var sp := StringName(str(prey.get("species", "")))
	var d := SizeRules.species_data(sp) if sp != &"" else {}
	# (The pause screen's "Hunt" line: worth chasing, and not your own kind.)
	var named := not d.is_empty() and mass > 0.0 and SizeRules.is_worthwhile(mass, float(d["mass"])) \
		and SizeRules.tier_for_mass(mass) != SizeRules.species_index(sp)
	var glow := bool(prey.get("glow", false))
	var out := {"title": ("Catch %s" % UIScreen.a_an(str(d["name"]))) if named else "Catch prey"}
	if level <= 0:
		if glow:
			out["hint"] = "It glows: fly into it"
			out["keys"] = "It glows: steer at it"
		elif named:
			# (GameLoop rings every worthwhile bird: the lesson's too.)
			out["hint"] = "Fly right into one"
			out["keys"] = "Fly into one: A or D"
		else:
			out["hint"] = "Chase a ringed bird"
			out["keys"] = "Chase a ringed bird"
	elif level == 1:
		out["hint"] = "Follow the arrow"
		out["keys"] = "Follow the arrow"
	else:
		out["hint"] = "Fly straight into it"
		out["keys"] = "Steer into it: A or D"
	return out


func _player_mass() -> float:
	if mass_provider.is_valid():
		return float(mass_provider.call())
	var p := Birds.player()
	return p.mass if p else -1.0


## Start (or resume) the lessons unless already completed.
func start() -> void:
	if is_done() or active or _ran:
		return
	active = true
	var done_ids: Array = progress_store.lessons_done() if progress_store else []
	var i := 0
	while i < LESSONS.size() and LESSONS[i]["id"] in done_ids:
		i += 1
	_begin(i)


func skip() -> void:
	if progress_store:
		progress_store.set_onboarding_done(true)
	var was := active
	_set_catch_on(false)
	active = false
	index = LESSONS.size()
	if was:
		finished.emit(true)


## Forget completion so the lessons run again on the next flight.
func reset() -> void:
	if progress_store:
		progress_store.reset_onboarding()
	_set_catch_on(false)
	active = false
	_ran = false
	index = -1


func _begin(i: int) -> void:
	index = i
	progress = 0.0
	celebrating = 0.0
	_elapsed = 0.0
	_hold = 0.0
	_count = 0
	_tilt_sign = 0
	help_level = 0
	_help_t = 0.0
	if index >= LESSONS.size():
		_set_catch_on(false)
		active = false
		_ran = true
		if progress_store and _all_learned():
			progress_store.set_onboarding_done(true)
		finished.emit(false)
		return
	# Lessons already learned (an earlier session) are not taught again.
	if progress_store and LESSONS[index]["id"] in progress_store.lessons_done():
		_begin(index + 1)
		return
	# The game's lesson prey are asked for before the card first shows, so
	# its words can name them.
	_set_catch_on(LESSONS[index]["id"] == &"catch")
	lesson_started.emit(index, current_view())


## The catch lesson is (not) being taught: tell UIRoot once per change.
func _set_catch_on(on: bool) -> void:
	if on != _catch_on:
		_catch_on = on
		catch_lesson.emit(on)


func _telemetry() -> Dictionary:
	if telemetry_provider.is_valid():
		return telemetry_provider.call()
	var p := Birds.player()
	if p and p.has_method(&"telemetry"):
		return p.call(&"telemetry")
	return {}


func _physics_process(delta: float) -> void:
	if auto_step and active and _live_ok():
		step(delta, _telemetry())


## Advance by delta with this frame's telemetry. Public so tests can drive
## minutes of play in a few milliseconds.
func step(delta: float, tel: Dictionary) -> void:
	if not active or index < 0 or index >= LESSONS.size():
		return
	if celebrating > 0.0:
		celebrating -= delta
		if celebrating <= 0.0:
			_begin(index + 1)
		return
	_elapsed += delta
	var id: StringName = LESSONS[index]["id"]
	var p := _measure(id, delta, tel)
	_set_progress(maxf(progress, p))
	if progress >= 1.0:
		_complete(false)
	elif _elapsed >= float(LESSONS[index].get("timeout", TIMEOUT)):
		_complete(true)
	elif id == &"catch":
		# Struggling: every CATCH_HELP_S of play without a catch, more help
		# (the game brings its lesson prey closer; the hint says more).
		_help_t += delta
		if _help_t >= CATCH_HELP_S and (not help_ok.is_valid() or bool(help_ok.call())):
			_help_t = 0.0
			help_level += 1
			catch_help.emit(help_level)
			if help_level <= CATCH_HINT_LEVELS:
				lesson_changed.emit(index, current_view())


func _measure(id: StringName, dt: float, t: Dictionary) -> float:
	var ext := float(t.get("wing_extension", 0.0))
	var flap := float(t.get("flapping", 0.0))
	var speed := float(t.get("airspeed", 0.0))
	var vs := float(t.get("vertical_speed", 0.0))
	var perched := bool(t.get("perched", false))
	var tucked := bool(t.get("tucked", false))
	match id:
		&"spread":
			if ext >= SPREAD_EXT and not tucked:
				_hold += dt
			return _hold / SPREAD_HOLD
		&"flap":
			if flap >= 0.5:
				_hold += dt
			return maxf(_count / float(FLAP_COUNT), _hold / FLAP_TELEMETRY_HOLD)
		&"glide":
			if flap < GLIDE_MAX_FLAP and ext >= GLIDE_MIN_EXT and not perched and not tucked and speed >= GLIDE_MIN_SPEED:
				_hold += dt
			return _hold / GLIDE_HOLD
		&"speed":
			return _measure_tilt(dt, float(t.get("pitch_input", 0.0)), speed, vs,
				flap < GLIDE_MAX_FLAP and not perched and not tucked and speed >= GLIDE_MIN_SPEED)
		&"turn":
			if absf(float(t.get("bank", 0.0))) >= TURN_BANK and not perched:
				_hold += dt
			return _hold / TURN_HOLD
		&"dive":
			if (tucked or ext <= 0.35) and vs <= DIVE_VS:
				_hold += dt
			return _hold / DIVE_HOLD
		&"catch":
			return float(_count > 0)
	return 0.0


## One frame of "Tilt for speed": progress 0..1 of the current window (the
## lesser of how long the tilt has been held and how much of its effect has
## shown). See the TILT_* constants.
func _measure_tilt(dt: float, pitch: float, speed: float, vs: float, gliding: bool) -> float:
	var way := 0
	if gliding and absf(pitch) >= TILT_INPUT:
		way = 1 if pitch > 0.0 else -1
	if way != _tilt_sign:
		# Let go, reversed, flapped: the window starts again.
		_tilt_sign = way
		_tilt_t = 0.0
		_tilt_v0 = speed
		_tilt_vs0 = vs
		_tilt_effect = 0.0
	if way == 0:
		return 0.0
	_tilt_t += dt
	var need := maxf(TILT_SPEED_GAIN, _tilt_v0 * TILT_SPEED_FRAC)
	var e := 0.0
	if way < 0:
		# Leading edges down: less lift, the nose drops, speed builds.
		e = (speed - _tilt_v0) / need
	else:
		# Leading edges up: lift jumps and the bird balloons, bleeding speed.
		e = minf((vs - _tilt_vs0) / BALLOON_LIFT, (_tilt_v0 - speed) / need)
	_tilt_effect = maxf(_tilt_effect, clampf(e, 0.0, 1.0))
	return minf(_tilt_t / TILT_HOLD, _tilt_effect)


func _set_progress(p: float) -> void:
	p = clampf(p, 0.0, 1.0)
	if p != progress:
		progress = p
		lesson_progress.emit(index, progress)


func _complete(timed_out: bool) -> void:
	_set_progress(1.0)
	var id: StringName = LESSONS[index]["id"]
	# Only what the player did is learned; a lesson that timed out moves on
	# (play is never blocked) but is offered again next session.
	if progress_store and not timed_out:
		progress_store.mark_lesson(id)
	if id == &"catch":
		_set_catch_on(false)
	lesson_completed.emit(index, id, timed_out)
	celebrating = CELEBRATE


## True if every lesson has been done (in this session or an earlier one).
func _all_learned() -> bool:
	var done: Array = progress_store.lessons_done()
	for l: Dictionary in LESSONS:
		if not (l["id"] in done):
			return false
	return true


## Live lessons only count what happens in play (not while CAUGHT, in a
## menu, or on the run summary); tests that drive step() by hand decide.
func _live_ok() -> bool:
	return not auto_step or Game.state == Game.State.PLAYING


## Events.player_flapped → counts wingbeats for the flap lesson.
func notify_flap(_side: int, strength: float) -> void:
	if active and _live_ok() and current().get("id") == &"flap" and strength >= FLAP_MIN_STRENGTH and celebrating <= 0.0:
		_count += 1


## Events.bird_caught → the catch lesson.
func notify_catch(predator: Bird, _prey: Bird) -> void:
	if active and _live_ok() and current().get("id") == &"catch" and is_instance_valid(predator) and predator.is_player():
		_count += 1
