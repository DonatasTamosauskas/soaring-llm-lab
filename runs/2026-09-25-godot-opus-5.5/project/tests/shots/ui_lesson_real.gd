extends Node
## UI evidence: the first-flight lessons in the REAL game, flown through the
## real chain (scenes/main.tscn through the integration area's test kit:
## flight's BotPoseSource arm motion -> the real WingInput -> PlayerBird and
## its FlightModel in the valley's wind; GameLoop; the UI's own Onboarding
## reading PlayerBird.telemetry()). The UI suites replay recordings instead
## (they may run no other area's code); this is the end-to-end check of what
## they replay.
##
##   tools/gd.sh ui_lesson --headless --fixed-fps 72 res://tests/shots/ui_lesson_real.tscn
##
## "Tilt for speed" (the brief's requirement 2):
##  - 60 s of neutral-wrist flap-and-glide (wing-pitch command exactly 0,
##    through the bot's twist noise), 2+2, 1+3 and 3+3 s cycles, and 2+2 with
##    a novice's noise (4 deg of twist noise, 0.15 s reaction): the lesson
##    must never complete;
##  - a held tilt in a glide, leading edges down (-0.6, -0.35) and up
##    (+0.6, +0.35): the lesson must complete within 3 s of the tilt at
##    +-0.6.
## "Catch prey" with GameLoop's lesson prey (request_lesson_prey: a slow
## moth swarm kept ahead of the player, nearer at each of the lesson's help
## steps), in a fresh run, airborne, per bot seed:
##  - a competent player (steers at GameLoop's target cue, as the brief's
##    cue-following person does): the lesson done by a catch, within 120 s
##    (the lead's "a competent new player completes the catch lesson within
##    1-2 minutes");
##  - a struggling player (a novice's arms - 4 deg of twist noise, 0.15 s
##    reaction - that looks for the cue's bird only every 1.5 s and flies at
##    where it was): done by a catch before the lesson's timeout (no dead
##    end: the help brings the prey back ahead of it);
##  - a passive player (cruises its orbit, never steers at prey): reported,
##    not a bar (whether the help's prey reach a player who never steers is
##    GameLoop's placement).
## --part=speed|catch|all (default all); --seeds=21,5,77 (the catch part's
## bot seeds); --who=competent,struggling,passive (the catch part's players,
## default all three); --tag=x (writes lesson_real_<part>_x.json, so runs in
## parallel keep their own; the Quest tier: add --quality=quest). Writes
## artifacts/ui/lesson_real[_<part>][_<tag>].json; exits 1 if a bar fails.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const WristPilot := preload("res://tests/shots/ui_wrist_pilot.gd")

## The lead's bars.
const NEUTRAL_S := 60.0
const TILT_BAR_S := 3.0
const CATCH_BAR_S := 120.0

var kit: Kit
var ob: Onboarding
var out := {"about": "tests/shots/ui_lesson_real.gd: the first-flight lessons flown in the real game (see the script)."}
var part := "all"
var failures: Array[String] = []
var _completed: Array = []
## GameLoop's target cue (Events.target_changed) and the player's catches.
var _target: Bird
var _player_catches: Array = []


func _ready() -> void:
	var ok := await _run()
	if kit != null:
		out["game_errors"] = kit.log.errors
		out["game_warnings"] = kit.log.warnings
		if kit.log.errors > 0:
			failures.append("the game logged %d errors" % kit.log.errors)
	out["failures"] = failures
	var tag := Paths.arg("tag", "")
	out["quality"] = Paths.arg("quality", "")
	var path := Paths.artifacts("ui").path_join("lesson_real%s%s.json" % ["" if part == "all" else "_" + part, "" if tag == "" else "_" + tag])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[ui] lesson_real: %s -> %s" % ["PASS" if ok and failures.is_empty() else "FAIL %s" % str(failures), path])
	if kit != null:
		await kit.teardown()
	get_tree().quit(0 if ok and failures.is_empty() else 1)


func _run() -> bool:
	part = Paths.arg("part", "all")
	kit = Kit.new()
	if not await kit.boot(self):
		failures.append("the real game did not boot")
		return false
	var ui := kit.main.ui
	ob = ui.onboarding
	ob.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void:
		_completed.append([id, timed_out, ob._elapsed]))
	Events.target_changed.connect(func(b: Bird) -> void: _target = b)
	Events.bird_caught.connect(func(pred: Bird, prey: Bird) -> void:
		if is_instance_valid(pred) and pred.is_player() and is_instance_valid(prey):
			_player_catches.append([String(prey.species), prey.get_instance_id()]))
	_start_at(&"speed")
	if not await kit.click(&"main", &"play"):
		failures.append("Play was not hovered")
		return false
	if not await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0):
		failures.append("Play did not start a run")
		return false
	kit.fly_bot(21, WristPilot)
	kit.pilot.set(&"agl", 40.0)
	if ob.current().get("id") != &"speed":
		failures.append("the lessons did not start at 'Tilt for speed' (%s)" % str(ob.current().get("id")))
		return false
	if part in ["speed", "all"]:
		await _speed_part()
	if part in ["catch", "all"]:
		await _catch_part()
	return true


func _speed_part() -> void:
	out["speed"] = {}
	var speed: Dictionary = out["speed"]
	# 1. Neutral wrists: flap and glide, never the lesson.
	var neutral := {}
	for cfg: Array in [[2.0, 2.0, false], [1.0, 3.0, false], [3.0, 3.0, false], [2.0, 2.0, true]]:
		kit.bot.set_novice(bool(cfg[2]))
		var key := "flap %d s + glide %d s%s" % [int(cfg[0]), int(cfg[1]), ", novice" if cfg[2] else ""]
		var r := await _neutral(float(cfg[0]), float(cfg[1]))
		neutral[key] = r
		print("[ui] neutral wrists, %s: %s" % [key, JSON.stringify(r)])
		if bool(r["completed"]):
			failures.append("'Tilt for speed' completed in neutral-wrist flight (%s at %.2f s)" % [key, float(r["completed_at_s"])])
		# Start the lesson afresh for the next run (it may have completed).
		_start_at(&"speed")
	kit.bot.set_novice(false)
	speed["neutral_wrists_flap_and_glide"] = neutral
	# 2. A real tilt, held in a glide.
	var tilts := {}
	for novice: bool in [false, true]:
		kit.bot.set_novice(novice)
		for pitch: float in [-0.6, 0.6, -0.35, 0.35]:
			var key := "tilt %+.2f%s" % [pitch, ", novice" if novice else ""]
			var r := await _tilt(pitch)
			tilts[key] = r
			print("[ui] %s: %s" % [key, JSON.stringify(r)])
			if absf(pitch) >= 0.6 and not novice and (not bool(r["completed"]) or float(r["completed_after_s"]) > TILT_BAR_S):
				failures.append("a %+.1f tilt did not complete the lesson within %.0f s (%s)" % [pitch, TILT_BAR_S, JSON.stringify(r)])
			_start_at(&"speed")
	kit.bot.set_novice(false)
	speed["held_tilt"] = tilts


## The lessons from `id` on (the ones before it marked learned), fresh.
func _start_at(id: StringName) -> void:
	ob.reset()
	for l: Dictionary in Onboarding.LESSONS:
		if l["id"] == id:
			break
		ob.progress_store.mark_lesson(l["id"])
	_completed.clear()
	ob.start()


## Seconds of play (physics ticks while PLAYING; a catch or a death waits).
func _tick() -> void:
	await get_tree().physics_frame
	var guard := 0
	while Game.state != Game.State.PLAYING and guard < 72 * 30:
		await get_tree().physics_frame
		guard += 1


func _pilot() -> FlightAutopilot:
	return kit.pilot


## NEUTRAL_S of flap `flap_s` / glide `glide_s` cycles, wrists at 0.
func _neutral(flap_s: float, glide_s: float) -> Dictionary:
	var pl := _pilot()
	pl.set(&"hold_pitch", 0.0)
	var p := kit.main.player
	var t := 0.0
	var dt := 1.0 / 72.0
	var st := {"completed": false, "completed_at_s": -1.0, "progress_max": 0.0, "glide_s": 0.0,
		"pitch_input_abs_max_gliding": 0.0, "pitch_input_abs_max": 0.0, "vs_max": -INF, "speed_range": [INF, -INF], "agl_min": INF}
	while t < NEUTRAL_S:
		var ph := fmod(t, flap_s + glide_s)
		kit.set_mode(&"flap" if ph < flap_s else &"glide")
		await _tick()
		t += dt
		var tel: Dictionary = p.telemetry()
		var pin := absf(float(tel.get("pitch_input", 0.0)))
		st["pitch_input_abs_max"] = maxf(float(st["pitch_input_abs_max"]), pin)
		if float(tel.get("flapping", 1.0)) < Onboarding.GLIDE_MAX_FLAP and not bool(tel.get("perched", false)):
			st["glide_s"] = float(st["glide_s"]) + dt
			st["pitch_input_abs_max_gliding"] = maxf(float(st["pitch_input_abs_max_gliding"]), pin)
		st["vs_max"] = maxf(float(st["vs_max"]), float(tel.get("vertical_speed", 0.0)))
		var sr: Array = st["speed_range"]
		sr[0] = minf(float(sr[0]), float(tel.get("airspeed", 0.0)))
		sr[1] = maxf(float(sr[1]), float(tel.get("airspeed", 0.0)))
		st["agl_min"] = minf(float(st["agl_min"]), float(pl.get(&"last_agl")))
		if ob.current().get("id") == &"speed" and ob.celebrating <= 0.0:
			st["progress_max"] = maxf(float(st["progress_max"]), ob.progress)
		if not bool(st["completed"]) and _done(&"speed"):
			st["completed"] = true
			st["completed_at_s"] = snappedf(t, 0.01)
	for k: String in ["progress_max", "glide_s", "pitch_input_abs_max_gliding", "pitch_input_abs_max", "vs_max", "agl_min"]:
		st[k] = snappedf(float(st[k]), 0.001)
	st["speed_range"] = [snappedf(float(st["speed_range"][0]), 0.01), snappedf(float(st["speed_range"][1]), 0.01)]
	return st


## Cruise with neutral wrists for a while, then glide with the wrists held at
## `pitch`: seconds from the tilt command to the lesson's completion.
func _tilt(pitch: float) -> Dictionary:
	var pl := _pilot()
	pl.set(&"hold_pitch", 0.0)
	kit.set_mode(&"climb")
	var t := 0.0
	while t < 3.0 or float(pl.get(&"last_agl")) < 30.0 and t < 12.0:
		await _tick()
		t += 1.0 / 72.0
	kit.set_mode(&"cruise")
	for i in 72 * 2:
		await _tick()
	var p := kit.main.player
	var tel0: Dictionary = p.telemetry()
	var st := {"completed": false, "completed_after_s": -1.0, "speed_at_tilt": snappedf(float(tel0.get("airspeed", 0.0)), 0.01)}
	kit.set_mode(&"glide")
	pl.set(&"hold_pitch", pitch)
	t = 0.0
	var dt := 1.0 / 72.0
	var pin_max := 0.0
	var v_min := INF
	var v_max := -INF
	var vs_max := -INF
	while t < 8.0:
		await _tick()
		t += dt
		var tel: Dictionary = p.telemetry()
		pin_max = maxf(pin_max, float(tel.get("pitch_input", 0.0)) * signf(pitch))
		v_min = minf(v_min, float(tel.get("airspeed", 0.0)))
		v_max = maxf(v_max, float(tel.get("airspeed", 0.0)))
		vs_max = maxf(vs_max, float(tel.get("vertical_speed", 0.0)))
		if _done(&"speed"):
			st["completed"] = true
			st["completed_after_s"] = snappedf(t, 0.01)
			break
	st["pitch_input_reached"] = snappedf(pin_max * signf(pitch), 0.001)
	st["airspeed_range"] = [snappedf(v_min, 0.01), snappedf(v_max, 0.01)]
	st["vertical_speed_max"] = snappedf(vs_max, 0.01)
	pl.set(&"hold_pitch", 0.0)
	kit.set_mode(&"cruise")
	return st


## True if lesson `id` was completed by doing it (not by its timeout).
func _done(id: StringName) -> bool:
	for c: Array in _completed:
		if c[0] == id and not bool(c[1]):
			return true
	return false


# --- "Catch prey" -------------------------------------------------------------

func _catch_part() -> void:
	out["catch"] = {}
	var seeds: Array = []
	for v: String in Paths.arg("seeds", "21,5,77").split(","):
		seeds.append(int(v))
	var names := {&"competent": "competent (steers at the target cue)", &"struggling": "struggling (novice arms, looks every 1.5 s)",
		&"passive": "passive (never steers at prey)"}
	var players: Array[StringName] = []
	for v: String in Paths.arg("who", "competent,struggling,passive").split(","):
		players.append(StringName(v))
	for who: StringName in players:
		for sd: int in seeds:
			var key := "%s, bot seed %d" % [names[who], sd]
			var r := await _catch_lesson(who, sd)
			(out["catch"] as Dictionary)[key] = r
			print("[ui] catch lesson, %s: %s" % [key, JSON.stringify(r)])
			if who == &"passive":
				continue
			if not bool(r["done_by_a_catch"]):
				failures.append("catch lesson, %s: not done by a catch (%s)" % [key, JSON.stringify(r)])
			elif who == &"competent" and float(r["done_after_s"]) > CATCH_BAR_S:
				failures.append("catch lesson, %s: took %.0f s (bar %.0f s)" % [key, float(r["done_after_s"]), CATCH_BAR_S])


## A fresh run (GameLoop's restart: a sparrow in a new sky), airborne for a
## few seconds, then the catch lesson, flown by `who` (see the header).
func _catch_lesson(who: StringName, sd: int) -> Dictionary:
	var chase := who != &"passive"
	kit.main.ui.bridge.restart_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	kit.fly_bot(sd, WristPilot)
	kit.bot.set_novice(who == &"struggling")
	kit.pilot.set(&"agl", 30.0)
	kit.cruise()
	kit.set_mode(&"cruise")
	# No lesson while the bird takes off: the catch lesson begins in the air,
	# as it does after "Tuck to dive".
	ob.skip()
	for i in 72 * 8:
		await _tick()
	_player_catches.clear()
	var helps: Array = []
	var help_cb := func(level: int) -> void: helps.append([level, snappedf(ob._elapsed, 0.1), ob.current_view().get("hint", "")])
	ob.catch_help.connect(help_cb)
	_start_at(&"catch")
	var gl := kit.main.game_loop
	var prey0: Array = gl.call(&"lesson_prey") if gl.has_method(&"lesson_prey") else []
	var prey0_ids := prey0.map(func(b: Bird) -> int: return b.get_instance_id())
	var st := {"lesson_prey_at_start": prey0.size(), "card_at_start": [kit.main.ui.hud.lesson_title(), kit.main.ui.hud.lesson_labels()[2].text],
		"done_by_a_catch": false, "done_after_s": -1.0, "timed_out": false, "first_catch": "", "first_catch_was_lesson_prey": false,
		"nearest_lesson_moth_m_by_10s": [], "deaths": 0}
	var t := 0.0
	var dt := 1.0 / 72.0
	var near_min := INF
	var deaths0 := kit.count("player_caught")
	var look_t := 0.0
	while t < Onboarding.CATCH_TIMEOUT + 5.0:
		look_t -= dt
		if chase and look_t <= 0.0:
			# The competent player looks every tick; the struggling one every
			# 1.5 s, and flies at where the bird was then.
			look_t = 1.5 if who == &"struggling" else 0.0
			if is_instance_valid(_target) and _target.alive and _target.is_inside_tree():
				kit.pilot.set(&"target", _target.get_body_position())
				kit.pilot.set(&"chase", true)
			elif bool(kit.pilot.get(&"chase")):
				kit.cruise()
		await _tick()
		t += dt
		var pp := kit.main.player.get_body_position()
		for b: Variant in (gl.call(&"lesson_prey") if gl.has_method(&"lesson_prey") else []):
			near_min = minf(near_min, (b as Bird).get_body_position().distance_to(pp))
		if fmod(t, 10.0) < dt:
			(st["nearest_lesson_moth_m_by_10s"] as Array).append(snappedf(near_min, 0.1) if is_finite(near_min) else -1.0)
			near_min = INF
		for c: Array in _completed:
			if c[0] == &"catch":
				st["done_by_a_catch"] = not bool(c[1])
				st["timed_out"] = bool(c[1])
				st["done_after_s"] = snappedf(float(c[2]), 0.01)
		if not _completed.is_empty() and _completed.any(func(c: Array) -> bool: return c[0] == &"catch"):
			break
	ob.catch_help.disconnect(help_cb)
	kit.bot.set_novice(false)
	if not _player_catches.is_empty():
		st["first_catch"] = _player_catches[0][0]
		st["first_catch_was_lesson_prey"] = prey0_ids.has(_player_catches[0][1])
	st["helps [level, s, hint]"] = helps
	st["deaths"] = kit.count("player_caught") - deaths0
	for i in 3:
		await _tick()
	st["lesson_prey_after"] = (gl.call(&"lesson_prey") as Array).size() if gl.has_method(&"lesson_prey") else -1
	kit.cruise()
	return st
