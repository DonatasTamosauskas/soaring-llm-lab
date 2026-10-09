class_name VRHaptics
extends Node
## The haptics service: turns game facts into distinct, rate-limited pulses
## in the hands (patterns in HapticPatterns).
##
## Sources:
##   Events  player_flapped -> flap (that side), bird_caught by the player ->
##           catch, player_collided -> collision (impact side stronger) or a
##           wing-brush tick, player_stalled -> buffet burst, player_caught
##           -> caught, player_perched -> perch, threat_changed -> danger
##           (held at the last reported level: GameLoop emits it only on a
##           change and always sends 0 when the threat is over).
##   PlayerBird.telemetry() (polled while playing) -> stall buffet
##           (stalled / stall_warning), updraft throb per wing (wind_l_y /
##           wind_r_y, else in_updraft).
## Rules (flight_vr.md §13): one pulse per hand per 40 ms unless a higher
## priority pattern preempts; each pattern has a minimum repeat interval;
## per-hand duty cycle <= 30 % over any 1 s (never a constant buzz); the
## Settings "haptics" value scales amplitude and 0 sends nothing at all.
## Fix round 3 (a verifier's saturation probe: with stall + updraft +
## danger filling the budget, a catch reached the hands whole 6 times in 24
## and a stalled player felt 15 flaps in 20), the budget is shared out:
##   - the continuous rhythms (stall buffet, updraft throb, danger
##     heartbeat) together use at most CONTINUOUS_DUTY. The heartbeat's
##     rate says how close the threat is, so its share is kept free for it
##     and it keeps its rhythm; the buffet and the throb share the rest and
##     slow down together when they would need more (_continuous_stretch),
##     so neither silences the other;
##   - routine pulses (flap, ticks) may fill to ROUTINE_DUTY;
##   - the important ones (catch, collision, caught: priority >=
##     SHORTEN_PRIORITY) to MAX_DUTY, so at least 90 ms of every second is
##     always theirs: a catch's double bite and a crash are felt whole;
##   - a continuous tick never cuts into or crowds another pulse (it skips
##     a beat: it repeats anyway), and a discrete pulse that meets the 40 ms
##     rule or a stronger pulse waits for its turn (at most MAX_DEFER)
##     instead of being lost.
##
## Output goes to `sink`: any object with pulse(hand: int, amplitude: float,
## duration: float). The default XR sink calls XRInterface.trigger_haptic_pulse
## on the "haptic" action (frequency 0 = runtime default; Quest ignores it and
## delay is not supported, so rhythm is scheduled here).

signal pulse_sent(hand: int, amplitude: float, duration: float, pattern: StringName)

const LEFT := 0
const RIGHT := 1
const MASK_LEFT := 1
const MASK_RIGHT := 2
const MASK_BOTH := 3
const MIN_GAP := 0.040
const DUTY_WINDOW := 1.0
const MAX_DUTY := 0.30
## Shares of the duty budget (see above), per hand, in any DUTY_WINDOW.
const CONTINUOUS_DUTY := 0.15
const ROUTINE_DUTY := 0.21
## Rare, important patterns are shortened rather than dropped by the duty cap.
const SHORTEN_PRIORITY := 70
## The most on-time the heartbeat can have in any DUTY_WINDOW (two 2 x 20 ms
## pairs at its fastest, 0.5 s apart).
const HEARTBEAT_MAX := 0.08
## The background rhythms: they repeat, so they yield.
const CONTINUOUS: Array[StringName] = [&"stall", &"updraft", &"danger"]
## How long a discrete pulse may wait for its turn (s): a flap thump 60 ms
## late still lands with the stroke.
const MAX_DEFER := 0.060
## The second beat of a heartbeat pair may wait a little longer (a pair
## 150 -> 250 ms apart still reads as one heartbeat).
const BEAT_MAX_DEFER := 0.100

## Sends pulses to the controllers through the active XR interface.
class XRSink:
	extends RefCounted
	var calls := 0
	## The interface to pulse: null = XRServer.primary_interface (when
	## initialised). Tests inject a recorder with the same method.
	var xr: Object = null

	## The OpenXR tracker of a hand index (0 left, 1 right).
	static func tracker_for(hand: int) -> StringName:
		return &"left_hand" if hand == 0 else &"right_hand"

	func pulse(hand: int, amplitude: float, duration: float) -> void:
		var target: Object = xr
		if target == null:
			var pi := XRServer.primary_interface
			if pi == null or not pi.is_initialized():
				return
			target = pi
		# QUEST.md §3.2: only amplitude and duration matter (frequency 0 =
		# the runtime's default, delay is ignored by the runtime).
		target.call(&"trigger_haptic_pulse", "haptic", tracker_for(hand), 0.0, amplitude, duration, 0.0)
		calls += 1


var sink: Object = null
## Forces the amplitude scale (>= 0), else the "haptics" value is read from
## `store`.
var intensity_override := -1.0
## Where the "haptics" setting comes from: anything with get_value (the
## Settings autoload by default; tests pass a private one and never write
## the shared settings file).
var store: Object = null
## Connect to the Events bus (off for isolated unit tests).
@export var listen_to_events := true
## Poll PlayerBird.telemetry() for stall / updraft.
@export var poll_player := true
## Advance time in _process; tests set false and call tick(dt).
@export var auto_tick := true

var rng := RandomNumberGenerator.new()
var stats := {"sent": 0, "dropped_rate": 0, "dropped_priority": 0, "dropped_duty": 0, "shortened": 0, "deferred": 0, "skipped_beats": 0}
## How much the continuous rhythms are slowed right now (1 = not at all).
var continuous_stretch := 1.0

var _now := 0.0
var _queue: Array[Dictionary] = []
var _busy_until: Array[float] = [0.0, 0.0]
var _busy_prio: Array[int] = [-1, -1]
var _last_start: Array[float] = [-10.0, -10.0]
var _pattern_last := {}
var _history: Array = [[], []]      # per hand: [[start, dur, class, pattern], ...] within DUTY_WINDOW
## Pulse classes for the duty shares.
enum Class { CONTINUOUS, ROUTINE, IMPORTANT }
var _stall_level := 0.0
var _next_stall := 0.0
var _updraft_level: Array[float] = [0.0, 0.0]
var _next_updraft: Array[float] = [0.0, 0.0]
var _danger_level := 0.0
var _danger_pred: Bird = null
var _next_danger := 0.0
var _poll_t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rng.seed = 0x5EED
	if sink == null:
		sink = XRSink.new()
	if listen_to_events:
		Events.player_flapped.connect(_on_flapped)
		Events.bird_caught.connect(_on_bird_caught)
		Events.player_collided.connect(_on_collided)
		Events.player_stalled.connect(_on_stalled)
		Events.player_caught.connect(_on_player_caught)
		Events.player_perched.connect(_on_perched)
		Events.threat_changed.connect(_on_threat_changed)
		Events.game_state_changed.connect(_on_game_state_changed)
		Events.run_ended.connect(func(_summary: Dictionary) -> void: set_danger(0.0))
		Events.player_spawned.connect(func(_p: Bird) -> void: clear_continuous())


func _process(delta: float) -> void:
	if auto_tick:
		var t0 := VRProfile.begin()
		tick(delta)
		VRProfile.add(&"haptics", t0)


## Current amplitude scale from Settings (0 = off).
func intensity() -> float:
	if intensity_override >= 0.0:
		return clampf(intensity_override, 0.0, 1.0)
	var src: Object = store if store != null else Settings
	return clampf(float(src.call("get_value", "haptics", 1.0)), 0.0, 1.0)


func now() -> float:
	return _now


# =============================================================================
# Public API
# =============================================================================

## Plays a named pattern on the hands in mask (1 left, 2 right, 3 both).
## gains: optional per-hand amplitude factors [left, right].
func play(pattern: StringName, mask: int = MASK_BOTH, strength: float = 1.0, gains: Array = [1.0, 1.0]) -> void:
	if intensity() <= 0.0:
		return
	var prio: int = HapticPatterns.PRIORITY.get(pattern, 10)
	var min_iv: float = HapticPatterns.MIN_INTERVAL.get(pattern, 0.0)
	var ps := HapticPatterns.pulses(pattern, strength)
	for hand in 2:
		if (mask & (1 << hand)) == 0 or float(gains[hand]) <= 0.0:
			continue
		var key := "%s:%d" % [pattern, hand]
		if min_iv > 0.0 and _now - float(_pattern_last.get(key, -100.0)) < min_iv:
			stats["dropped_rate"] += 1
			continue
		_pattern_last[key] = _now
		for p in ps:
			_queue.append({"at": _now + float(p["t"]), "hand": hand, "amp": float(p["amp"]) * float(gains[hand]),
				"dur": float(p["dur"]), "name": pattern, "prio": prio})


## Advances the scheduler by dt: continuous patterns, then due pulses.
func tick(dt: float) -> void:
	_now += dt
	var paused := is_inside_tree() and get_tree().paused
	if paused:
		# Gameplay feedback stops with the game; a calibration confirm may
		# still play in the menus.
		_queue = _queue.filter(func(q: Dictionary) -> bool: return q["name"] == &"confirm")
	else:
		# Telemetry at 30 Hz: the continuous patterns repeat every >= 70 ms,
		# and PlayerBird.telemetry() builds a dictionary per call.
		_poll_t -= dt
		if poll_player and _poll_t <= 0.0:
			_poll_t = 1.0 / 30.0
			_poll_telemetry()
		_run_continuous()
	_dispatch()


## Clears everything scheduled (e.g. on respawn).
func stop_all() -> void:
	_queue.clear()
	clear_continuous()


## Ends the continuous patterns (stall, updraft, danger); pulses already
## queued (a "caught" thud) still play.
func clear_continuous() -> void:
	_stall_level = 0.0
	_updraft_level = [0.0, 0.0]
	_danger_level = 0.0
	_danger_pred = null
	_drop_queued([&"stall", &"updraft", &"danger"])


func _drop_queued(patterns: Array[StringName]) -> void:
	_queue = _queue.filter(func(q: Dictionary) -> bool: return not (q["name"] in patterns))


## Sets the continuous inputs directly (tests, or a caller without a
## PlayerBird). stall 0..1, updraft per wing m/s of lift, danger 0..1.
func set_stall(level: float) -> void:
	if level > 0.0 and _stall_level <= 0.0:
		_next_stall = _now
	_stall_level = clampf(level, 0.0, 1.0)


func set_updraft(lift_left: float, lift_right: float) -> void:
	var lifts := [lift_left, lift_right]
	for i in 2:
		var lvl := clampf((float(lifts[i]) - 0.5) / 3.5, 0.0, 1.0) if float(lifts[i]) > 0.5 else 0.0
		if lvl > 0.0 and _updraft_level[i] <= 0.0:
			# Offset the right hand half a period so both wings throb in turn.
			_next_updraft[i] = _now + (0.0 if i == 0 else 0.5 * HapticPatterns.repeat_interval(&"updraft", lvl, rng))
		_updraft_level[i] = lvl


## The danger heartbeat plays while level >= 0.35 and keeps playing at that
## level until told otherwise: threat_changed is a change signal (GameLoop
## re-emits only when the level moves by 0.02, and sends 0 when the threat
## ends), so a predator holding a steady distance must keep the heart going.
## predator: the hunter, when known; the heartbeat stops if it is removed or
## dies without a final report.
func set_danger(level: float, predator: Bird = null) -> void:
	if level >= 0.35 and _danger_level < 0.35:
		_next_danger = _now
	elif level < 0.35 and _danger_level >= 0.35:
		# All clear: the second beat of a pair must not follow it.
		_drop_queued([&"danger"])
	_danger_level = clampf(level, 0.0, 1.0)
	_danger_pred = predator if level > 0.0 else null


func danger_level() -> float:
	return _danger_level


# =============================================================================
# Event handlers
# =============================================================================

func _player() -> Bird:
	return Birds.player()


func _on_flapped(side: int, strength: float) -> void:
	var mask := MASK_BOTH if side == 0 else (MASK_LEFT if side < 0 else MASK_RIGHT)
	play(&"flap", mask, strength)


func _on_bird_caught(predator: Bird, _prey: Bird) -> void:
	if predator != null and (predator == _player() or predator.is_player()):
		play(&"catch")


func _on_collided(impact_speed: float, normal: Vector3) -> void:
	# The surface is on the side the normal points away from.
	var right := Vector3.RIGHT
	var p := _player()
	if p != null and p.is_inside_tree():
		right = p.global_basis.x.normalized()
	var side := -normal.dot(right)
	var gains := [1.0, 1.0]
	if side > 0.2:
		gains = [0.5, 1.0]
	elif side < -0.2:
		gains = [1.0, 0.5]
	if impact_speed < 0.5:
		# Wing brush (impact 0): a tick on the touching side only.
		var mask := MASK_RIGHT if side > 0.0 else MASK_LEFT
		play(&"brush", mask)
	else:
		play(&"collision", MASK_BOTH, clampf(impact_speed / 8.0, 0.0, 1.0), gains)


func _on_stalled() -> void:
	set_stall(maxf(_stall_level, 1.0))


func _on_player_caught(_predator: Bird) -> void:
	stop_all()
	play(&"caught")


func _on_perched(_pos: Vector3) -> void:
	play(&"perch")


func _on_threat_changed(level: float, predator: Bird) -> void:
	set_danger(level, predator)


## Leaving play (menu, caught, run over) ends every continuous pattern; a
## pause only silences them (the tick skips them) so they resume with play.
func _on_game_state_changed(new_state: int, _old_state: int) -> void:
	if new_state != Game.State.PLAYING and new_state != Game.State.PAUSED:
		clear_continuous()


# =============================================================================
# Internals
# =============================================================================

func _poll_telemetry() -> void:
	if not (Game.state == Game.State.PLAYING or Game.state == Game.State.BOOT):
		_stall_level = 0.0
		_updraft_level = [0.0, 0.0]
		return
	var p := _player()
	if p == null or not p.alive or not p.has_method("telemetry"):
		return
	var t: Dictionary = p.call("telemetry")
	var perched := bool(t.get("perched", false))
	var stall := 0.0
	if bool(t.get("stalled", false)):
		stall = 1.0
	elif t.has("stall_warning"):
		stall = clampf((float(t["stall_warning"]) - 0.6) / 0.4, 0.0, 1.0)
	set_stall(0.0 if perched else stall)
	var lift := float(t.get("in_updraft", 0.0))
	var ll := float(t.get("wind_l_y", lift))
	var lr := float(t.get("wind_r_y", lift))
	if perched:
		ll = 0.0
		lr = 0.0
	set_updraft(ll, lr)


func _run_continuous() -> void:
	# A hunter removed without a final report (freed, or eaten itself).
	if _danger_pred != null and (not is_instance_valid(_danger_pred) or not _danger_pred.alive):
		set_danger(0.0)
	continuous_stretch = _continuous_stretch()
	var k := continuous_stretch
	# A beat that does not fit now (a pulse playing, the 40 ms rule, its
	# duty share) waits a tick or two rather than being skipped: the rhythm
	# stays whole, a little late. The heartbeat is never stretched (its rate
	# is the threat's distance) and its share is kept free for it, so the
	# quicker buffet and throb cannot starve it.
	if _stall_level > 0.0 and _now >= _next_stall and _beat_fits(MASK_BOTH, &"stall", _stall_level):
		play(&"stall", MASK_BOTH, _stall_level)
		_next_stall = _now + k * HapticPatterns.repeat_interval(&"stall", _stall_level, rng)
	for i in 2:
		if _updraft_level[i] > 0.0 and _now >= _next_updraft[i] and _beat_fits(1 << i, &"updraft", _updraft_level[i]):
			play(&"updraft", 1 << i, _updraft_level[i])
			_next_updraft[i] = _now + k * HapticPatterns.repeat_interval(&"updraft", _updraft_level[i], rng)
	if _danger_level >= 0.35 and _now >= _next_danger and _beat_fits(MASK_BOTH, &"danger", _danger_intensity()):
		var lvl := _danger_intensity()
		play(&"danger", MASK_BOTH, lvl)
		_next_danger = _now + HapticPatterns.repeat_interval(&"danger", lvl, rng)


## True when a continuous beat can start now on every hand in mask: no
## pulse playing, the 40 ms rule met, and its whole on-time inside every
## share it counts against.
func _beat_fits(mask: int, pattern: StringName, level: float) -> bool:
	var on := 0.0
	for p in HapticPatterns.pulses(pattern, level):
		on += float(p["dur"])
	for hand in 2:
		if (mask & (1 << hand)) == 0:
			continue
		if _now < _busy_until[hand] or _now - _last_start[hand] < MIN_GAP - 1e-6:
			return false
		# The buffet and the throb share what the heartbeat leaves of the
		# continuous share; the heartbeat itself only answers to the
		# routine and total caps (its own on-time is bounded by design:
		# <= HEARTBEAT_MAX in any window).
		if pattern != &"danger" and _on_time(hand, Class.CONTINUOUS, true) + on > (CONTINUOUS_DUTY - _danger_reserve()) * DUTY_WINDOW + 1e-6:
			return false
		if _on_time(hand, Class.ROUTINE) + on > ROUTINE_DUTY * DUTY_WINDOW + 1e-6:
			return false
		if _on_time(hand) + on > MAX_DUTY * DUTY_WINDOW + 1e-6:
			return false
	return true


func _danger_intensity() -> float:
	return clampf((_danger_level - 0.35) / 0.65, 0.0, 1.0)


## The heartbeat's share of CONTINUOUS_DUTY while it plays: the most it
## can have in any window (2 x 20 ms pairs every 0.5 s at the fastest: two
## pairs' worth, 8 %).
func _danger_reserve() -> float:
	return HEARTBEAT_MAX if _danger_level >= 0.35 else 0.0


## The factor (>= 1) the buffet and the throb are slowed by so that
## together they fit what the heartbeat leaves of CONTINUOUS_DUTY on the
## busier hand: each pattern's own duty is its on-time per repeat over its
## mean repeat interval.
func _continuous_stretch() -> float:
	var shared := 0.0
	if _stall_level > 0.0:
		shared += HapticPatterns.mean_duty(&"stall", _stall_level)
	var worst := shared
	for i in 2:
		if _updraft_level[i] > 0.0:
			worst = maxf(worst, shared + HapticPatterns.mean_duty(&"updraft", _updraft_level[i]))
	# Aim 10 % under the share: the jittered rhythms need some slack, or
	# every beat would wait.
	var room := maxf(0.9 * CONTINUOUS_DUTY - _danger_reserve(), 0.02)
	return maxf(1.0, worst / room)


func _dispatch() -> void:
	if _queue.is_empty():
		return
	var due: Array[Dictionary] = []
	var rest: Array[Dictionary] = []
	for q in _queue:
		if float(q["at"]) <= _now + 1e-6:
			due.append(q)
		else:
			rest.append(q)
	if due.is_empty():
		return
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["at"] < b["at"] or (a["at"] == b["at"] and a["prio"] > b["prio"]))
	for q in due:
		var retry := _try_send(q)
		if retry > 0.0:
			q["at"] = retry
			rest.append(q)
	_queue = rest



## Vibration time on this hand from DUTY_WINDOW ago until the end of what is
## already playing (so a new pulse's budget is judged on the window it ends),
## counting the pulse classes up to `upto` (Class.IMPORTANT: everything).
func _on_time(hand: int, upto: int = Class.IMPORTANT, skip_heartbeat: bool = false) -> float:
	var h: Array = _history[hand]
	var cut := _now - DUTY_WINDOW
	while not h.is_empty() and float(h[0][0]) + float(h[0][1]) < cut:
		h.pop_front()
	var total := 0.0
	for e in h:
		if int(e[2]) > upto or (skip_heartbeat and e[3] == &"danger"):
			continue
		var start := float(e[0])
		total += maxf(0.0, start + float(e[1]) - maxf(start, cut))
	return total


## Fraction of the last DUTY_WINDOW seconds this hand vibrated (tests, logs).
func duty(hand: int) -> float:
	return _on_time(hand) / DUTY_WINDOW


static func _class_of(q: Dictionary) -> int:
	if int(q["prio"]) >= SHORTEN_PRIORITY:
		return Class.IMPORTANT
	return Class.CONTINUOUS if q["name"] in CONTINUOUS else Class.ROUTINE


## Sends a due pulse, or returns the time (> 0) to try it again (a
## discrete pulse waiting for its turn); -1 when sent or dropped.
func _try_send(q: Dictionary) -> float:
	var hand: int = q["hand"]
	var prio: int = q["prio"]
	var continuous: bool = q["name"] in CONTINUOUS
	var busy := _now < _busy_until[hand]
	var too_soon := _now - _last_start[hand] < MIN_GAP - 1e-6
	# A background beat never cuts into or crowds another pulse: it waits
	# (a beat starts only when it fits, _beat_fits; this is the second half
	# of a heartbeat pair, which keeps its pair).
	var outranked := busy and (continuous or prio < _busy_prio[hand])
	var gap_blocked := too_soon and (continuous or prio <= _busy_prio[hand])
	if outranked or gap_blocked:
		# Wait for the stronger pulse to end and for the 40 ms rule, briefly.
		var free_at := maxf(_busy_until[hand] if outranked else _now, _last_start[hand] + MIN_GAP)
		var deadline := float(q.get("deadline", float(q["at"]) + (BEAT_MAX_DEFER if continuous else MAX_DEFER)))
		q["deadline"] = deadline
		if free_at <= deadline + 1e-6:
			stats["deferred"] += 1
			return free_at
		stats["skipped_beats" if continuous else ("dropped_priority" if outranked else "dropped_rate")] += 1
		return -1.0
	var dur: float = q["dur"]
	var h: Array = _history[hand]
	var cls := _class_of(q)
	# A new pulse replaces the one playing (OpenXR semantics), so the unplayed
	# rest of the current pulse does not count against the budget.
	var cut_rest := maxf(0.0, _busy_until[hand] - _now) if busy else 0.0
	var busy_cls := int(h[h.size() - 1][2]) if busy and not h.is_empty() else Class.IMPORTANT
	# Every share holds at once: the whole budget, what the continuous and
	# routine pulses may use together, and what the continuous ones may.
	var budget := MAX_DUTY * DUTY_WINDOW - (_on_time(hand) - cut_rest)
	if cls <= Class.ROUTINE:
		budget = minf(budget, ROUTINE_DUTY * DUTY_WINDOW - (_on_time(hand, Class.ROUTINE) - (cut_rest if busy_cls <= Class.ROUTINE else 0.0)))
	if cls == Class.CONTINUOUS:
		if q["name"] != &"danger":
			budget = minf(budget, (CONTINUOUS_DUTY - _danger_reserve()) * DUTY_WINDOW - _on_time(hand, Class.CONTINUOUS, true))
	if dur > budget + 1e-6:
		if prio >= SHORTEN_PRIORITY and budget >= 0.02:
			dur = budget
			stats["shortened"] += 1
		else:
			stats["dropped_duty"] += 1
			return -1.0
	var amp := clampf(float(q["amp"]) * intensity(), 0.0, 1.0)
	if amp <= 0.0:
		return -1.0
	if busy and not h.is_empty():
		h[h.size() - 1][1] = maxf(0.0, _now - float(h[h.size() - 1][0]))
	h.append([_now, dur, cls, q["name"]])
	_busy_until[hand] = _now + dur
	_busy_prio[hand] = prio
	_last_start[hand] = _now
	stats["sent"] += 1
	if sink != null:
		sink.call("pulse", hand, amp, dur)
	pulse_sent.emit(hand, amp, dur, q["name"])
	return -1.0
