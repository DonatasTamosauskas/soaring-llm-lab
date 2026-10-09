class_name FlockAudio
extends RefCounted

## Decides what the sky says and who says it: which birds are worth hearing,
## when they call, and how loud the thing chasing you is.
##
## Scene-free, like everything else that makes a decision in this game. It takes
## a list of plain descriptions of birds and hands back a list of sounds to
## start — [AudioDirector] owns the emitters and knows nothing about why. That is
## what lets the one claim this area has to earn — [i]you can hear a bigger bird
## closing on you from behind[/i] — be an assertion over numbers rather than a
## story about a headset.
##
## [b]Two channels.[/b] Events (calls, wingbeats) are one-shots fired from the
## bird's real position, so direction comes free from the engine's panning.
## Menace is continuous: the single most dangerous bird near you gets a held air
## rush whose level is a function of how close it is, how much bigger it is, and
## how fast it is closing. Nothing else in the game is allowed a continuous
## voice, because a sky where everything drones is a sky where nothing is heard.
##
## [b]Budget.[/b] At most [constant MAX_EVENTS_PER_SECOND] one-shots a second and
## one rush, whatever the flock is doing. A dozen birds in a squabble must not
## be able to empty the voice pool and mask the predator behind you.

## Beyond this a bird is not worth a voice. Chosen against the flock's own
## sight ranges: [constant Flock.PREY_SIGHT] is 62 m and the manager notices a
## threat at 40 m, so 140 m means you can hear birds you have not yet seen —
## which is the point of having ears.
const HEARING: float = 140.0
## Wingbeats are near-field. A wingbeat at 60 m is not audible in life and would
## turn the flock into applause here.
const BEAT_RANGE: float = 42.0
## Where menace starts registering at all.
const MENACE_RANGE: float = 90.0

## How much bigger something has to be before it is frightening rather than
## merely large. Above this the menace term is saturated.
const MENACE_SIZE_SPAN: float = 0.60
## Closing speed at which the approach term saturates, m/s. Two birds at trim
## closing head-on make about 35; a stoop from behind makes 20–30.
const MENACE_CLOSING: float = 24.0

## Voice budget. Six is enough for a hunt, a squabble and a roost at once.
const MAX_VOICES: int = 6
const MAX_EVENTS_PER_SECOND: float = 7.0

## Seconds between one bird's calls, in the calm case and when it is right on top
## of you. A hunter that calls faster as it closes is the audible half of the
## chase — the same information the HUD's chevron gives, without looking.
const CALL_INTERVAL_CALM: float = 9.0
const CALL_INTERVAL_URGENT: float = 1.4
## A roost natters. It is the sound of somewhere worth being.
const ROOST_INTERVAL: float = 5.0
## Shortest gap between two wingbeats from the same bird.
const BEAT_INTERVAL: float = 0.24

## Fastest a held rush may change level. Without it a bird crossing behind a
## ridge would snap on and off.
const RUSH_ATTACK: float = 2.5
const RUSH_RELEASE: float = 1.2

## Mirrors [enum BirdNPC.State] without depending on it — this object is handed
## plain numbers and never sees a bird. The first four ordinals are load-bearing
## there and are load-bearing here for the same reason.
const STATE_FLEE: int = 2
const STATE_PERCH: int = 3
const STATE_HUNT: int = 1
const STATE_STALK: int = 4

## Sounds to start this tick. Each is
## [code]{kind, position, gain, pitch, variant}[/code].
var events: Array[Dictionary] = []
## The held voice, or an empty dictionary. [code]{id, position, gain, pitch}[/code].
var rush: Dictionary = {}

var _next_call: Dictionary = {}
var _next_beat: Dictionary = {}
var _was_stroking: Dictionary = {}
var _rush_level: float = 0.0
var _rush_id: int = 0
var _clock: float = 0.0
var _budget: float = MAX_EVENTS_PER_SECOND
var _rng := RandomNumberGenerator.new()


func _init(voice_seed: int = 424242) -> void:
	_rng.seed = voice_seed


## How frightening a bird is, 0..1 — the whole of the "something is behind you"
## claim, in one pure function.
##
## Three terms, all of which must be true for a bird to be alarming: it is close,
## it is bigger than you, and it is getting closer. [param closing] is positive
## when the gap is shrinking. A big bird sitting still at 30 m is scenery; the
## same bird at the same distance coming at you is the loudest thing in the game.
static func menace(
	distance: float, listener_size: float, bird_size: float, closing: float
) -> float:
	if not (is_finite(distance) and is_finite(closing)):
		return 0.0
	if distance >= MENACE_RANGE or distance < 0.0:
		return 0.0
	var mine: float = maxf(listener_size if is_finite(listener_size) else 1.0, 0.05)
	var theirs: float = maxf(bird_size if is_finite(bird_size) else 1.0, 0.05)
	if not GameRules.can_catch(theirs, mine):
		# Something that cannot eat you is not menacing, however large. This keeps
		# the sound honest about the rules: if you can hear the rush, you are prey.
		return 0.0
	var near: float = 1.0 - distance / MENACE_RANGE
	near *= near
	var bigger: float = clampf(
		(theirs / mine - GameRules.CATCH_MARGIN) / MENACE_SIZE_SPAN, 0.0, 1.0
	)
	var approach: float = clampf(closing / MENACE_CLOSING, 0.0, 1.0)
	return near * (0.40 + 0.60 * bigger) * (0.30 + 0.70 * approach)


## Seconds until this bird speaks again. Urgency shortens it; a calm bird a long
## way off barely bothers.
static func call_interval(urgency: float) -> float:
	var u: float = clampf(urgency if is_finite(urgency) else 0.0, 0.0, 1.0)
	return lerpf(CALL_INTERVAL_CALM, CALL_INTERVAL_URGENT, u)


## One tick of the sky.
##
## [param birds] is a list of
## [code]{id, position, velocity, size, state, species, stroke}[/code]. Nothing
## in it is a node, which is why this runs in a test with no scene at all.
func update(
	listener: Vector3, listener_velocity: Vector3, listener_size: float,
	birds: Array[Dictionary], delta: float
) -> void:
	events.clear()
	if not is_finite(delta) or delta <= 0.0:
		return
	var dt: float = minf(delta, 0.5)
	_clock += dt
	_budget = minf(_budget + dt * MAX_EVENTS_PER_SECOND, MAX_EVENTS_PER_SECOND)
	if not (listener.is_finite() and listener_velocity.is_finite()):
		return
	var mine: float = listener_size if is_finite(listener_size) else 1.0

	# Rank the flock by how much it matters that you hear it. Sorting 26 small
	# dictionaries at 10 Hz is nothing; it is what stops a distant squabble from
	# spending the voices that the bird behind you needs.
	var ranked: Array[Dictionary] = []
	var best_menace: float = 0.0
	var best: Dictionary = {}
	for bird: Dictionary in birds:
		var position: Vector3 = bird.get("position", Vector3.ZERO)
		if not position.is_finite():
			continue
		var offset: Vector3 = position - listener
		var distance: float = offset.length()
		if distance > HEARING:
			continue
		var velocity: Vector3 = bird.get("velocity", Vector3.ZERO)
		if not velocity.is_finite():
			velocity = Vector3.ZERO
		var closing: float = 0.0
		if distance > 0.01:
			closing = (listener_velocity - velocity).dot(offset / distance)
		var size: float = float(bird.get("size", 1.0))
		var threat: float = menace(distance, mine, size, closing)
		var entry: Dictionary = {
			"id": int(bird.get("id", 0)),
			"position": position,
			"distance": distance,
			"closing": closing,
			"size": size,
			"species": int(bird.get("species", 1)),
			"state": int(bird.get("state", 0)),
			"stroke": float(bird.get("stroke", 0.0)),
			"menace": threat,
			# What decides who gets a voice. Menace dominates; after that it is
			# simply who is nearest, so the sky around you is the sky you hear.
			"weight": threat * 4.0 + (1.0 - distance / HEARING),
		}
		ranked.append(entry)
		if threat > best_menace:
			best_menace = threat
			best = entry

	ranked.sort_custom(_louder_first)
	_update_rush(best, best_menace, dt)

	var voices: int = 0
	for entry: Dictionary in ranked:
		if voices >= MAX_VOICES:
			break
		if _speak(entry, mine, dt):
			voices += 1
	_forget(birds)


static func _louder_first(a: Dictionary, b: Dictionary) -> bool:
	return float(a["weight"]) > float(b["weight"])


## The held voice: the air over the one bird that is actually a problem.
func _update_rush(best: Dictionary, level: float, dt: float) -> void:
	# Attack fast, release slow. A predator that breaks off should fade, not
	# vanish — vanishing reads as "it is gone" and it very often is not.
	var rate: float = RUSH_ATTACK if level > _rush_level else RUSH_RELEASE
	_rush_level = move_toward(_rush_level, level, rate * dt)
	if best.is_empty() or _rush_level <= 0.01:
		if _rush_level <= 0.01:
			rush = {}
		return
	_rush_id = int(best["id"])
	rush = {
		"id": _rush_id,
		"position": best["position"],
		"gain": _rush_level,
		# Bigger wings, lower rush. The pitch is the size cue: how much trouble,
		# not just how near.
		"pitch": clampf(1.25 / pow(maxf(float(best["size"]), 0.2), 0.30), 0.55, 1.5),
	}


## Whether this bird made a sound this tick. Wingbeats first — they are the
## near-field cue and they are what a bird behind you actually sounds like.
func _speak(entry: Dictionary, listener_size: float, dt: float) -> bool:
	var id: int = int(entry["id"])
	var distance: float = float(entry["distance"])
	var spoke: bool = false

	var stroking: bool = float(entry["stroke"]) > 0.4
	var was: bool = bool(_was_stroking.get(id, false))
	_was_stroking[id] = stroking
	if stroking and not was and distance < BEAT_RANGE:
		var next: float = float(_next_beat.get(id, 0.0))
		if _clock >= next and _spend():
			_next_beat[id] = _clock + BEAT_INTERVAL
			var size: float = float(entry["size"])
			events.append({
				"kind": &"beat_big" if size > 2.0 else &"beat",
				"position": entry["position"],
				# Near-field: a beat at 5 m is a different event from one at 40 m.
				"gain": clampf(1.0 - distance / BEAT_RANGE, 0.05, 1.0),
				"pitch": clampf(1.3 / pow(maxf(size, 0.2), 0.28), 0.6, 1.6),
				"variant": id % 3,
			})
			spoke = true

	var state: int = int(entry["state"])
	var urgency: float = maxf(
		float(entry["menace"]), clampf(1.0 - distance / HEARING, 0.0, 1.0) * 0.35
	)
	var mood: int = VoiceBank.Mood.CONTACT
	if state == STATE_FLEE:
		mood = VoiceBank.Mood.ALARM
		urgency = maxf(urgency, 0.75)
	elif state == STATE_HUNT or state == STATE_STALK:
		mood = VoiceBank.Mood.HUNT
		# A hunter is only urgent to the ears if it is hunting near you. It may
		# well be after somebody else, and that is worth hearing too, quietly.
		urgency = maxf(urgency, 0.45 * clampf(1.0 - distance / HEARING, 0.0, 1.0))

	var due: float = float(_next_call.get(id, -1.0))
	if due < 0.0:
		# Stagger first calls, or every bird spawned in the same frame speaks in
		# the same frame.
		_next_call[id] = _clock + _rng.randf_range(0.5, CALL_INTERVAL_CALM)
		return spoke
	if _clock < due:
		return spoke
	var interval: float = call_interval(urgency)
	if state == STATE_PERCH:
		interval = minf(interval, ROOST_INTERVAL)
	_next_call[id] = _clock + interval * _rng.randf_range(0.7, 1.4)
	if not _spend():
		return spoke
	events.append({
		"kind": VoiceBank.call_name(int(entry["species"]), mood),
		"position": entry["position"],
		"gain": clampf(0.35 + 0.65 * urgency, 0.2, 1.0),
		"pitch": _rng.randf_range(0.94, 1.07),
		"variant": id % 3,
	})
	return true


## One event out of the second's allowance, or false if the sky has said enough.
func _spend() -> bool:
	if _budget < 1.0:
		return false
	_budget -= 1.0
	return true


## Drops the bookkeeping for birds that are no longer in the flock, so a long
## session cannot grow a dictionary entry per bird ever spawned.
func _forget(birds: Array[Dictionary]) -> void:
	if _next_call.size() < 128:
		return
	var live: Dictionary = {}
	for bird: Dictionary in birds:
		live[int(bird.get("id", 0))] = true
	for id: int in _next_call.keys():
		if not live.has(id):
			_next_call.erase(id)
			_next_beat.erase(id)
			_was_stroking.erase(id)


## What the held voice is currently doing, for a test or a diagnostic.
func rush_level() -> float:
	return _rush_level


func reset() -> void:
	events.clear()
	rush = {}
	_next_call.clear()
	_next_beat.clear()
	_was_stroking.clear()
	_rush_level = 0.0
	_budget = MAX_EVENTS_PER_SECOND
	_clock = 0.0
