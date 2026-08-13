class_name Coach
extends RefCounted

## Teaches the four gestures by watching for them, once, and then never again.
##
## The whole affordance used to be one line of HUD text saying "spread your arms
## and flap", which tells a new player what to do only if they were already
## reading it. This asks for one thing at a time, in the order that stops you
## falling out of the sky, and each prompt goes away the moment the player
## actually does the thing — so the tutorial is over in about twenty seconds for
## somebody who picks it up and never nags somebody who already knows.
##
## Pure and scene-free like the rest of the flight-adjacent code, because "does
## shaking the controllers count as a wingbeat" is a question the test suite
## already knows how to ask.

enum Step { SPREAD, FLAP, BANK, TUCK, DONE }

## Cumulative seconds of a gesture that count as having done it. Long enough
## that a wobble on the way to something else does not tick a lesson off,
## short enough that a deliberate attempt always does.
const HOLD_SPREAD: float = 0.4
const HOLD_BANK: float = 0.5
const HOLD_TUCK: float = 0.35
## Wingbeats that count as having learned to flap. Two, so that one accidental
## arm drop on the way to a comfortable posture is not a lesson.
const BEATS_WANTED: int = 2

## Shortest time a prompt stays up, so a player who happens to already be doing
## the thing still sees what they did. A cue that flashes past is worse than no
## cue: they know something appeared and not what.
const MIN_DWELL: float = 1.4
## How long one lesson is allowed to block the rest. A player who never tucks
## should still be told about banking; they will find the dive on their own.
const STEP_PATIENCE: float = 32.0
## The coach's whole lifetime. After this it is over whether or not it worked —
## permanent instructions are furniture, and this game's HUD has a budget of
## about two lines.
const LIFETIME: float = 180.0

const SPREAD_SPAN: float = 0.80
const TUCK_SPAN: float = 0.35
const BANK_ANGLE: float = 0.45
const BEAT_STROKE: float = 1.0

var step: Step = Step.SPREAD
var complete: bool = false

var _step_time: float = 0.0
var _held: float = 0.0
var _beats: int = 0
var _armed: bool = true
var _elapsed: float = 0.0


## Skips straight to the end, for a player who has flown before. Their setting
## is remembered in [PlayerSettings], so the second run of a returning player is
## clean.
func skip() -> void:
	step = Step.DONE
	complete = true


func restart() -> void:
	step = Step.SPREAD
	complete = false
	_step_time = 0.0
	_held = 0.0
	_beats = 0
	_armed = true
	_elapsed = 0.0


## Watches one frame of flying. [param command] is the same object the flight
## model was just stepped with, so the coach can only ever see what the player
## actually commanded — a shaken wrist produces no [member
## FlightCommand.stroke_speed] and therefore teaches nothing.
func observe(command: FlightCommand, perched: bool, delta: float) -> void:
	if complete or command == null:
		return
	if not is_finite(delta) or delta <= 0.0:
		return
	var dt: float = minf(delta, 0.25)
	_elapsed += dt
	_step_time += dt
	if _elapsed >= LIFETIME:
		skip()
		return
	# Perched, the only useful instruction is the one the HUD already gives, and
	# a lesson cannot be practised standing on a branch.
	if perched:
		return

	var span: float = command.span if is_finite(command.span) else 1.0
	var bank: float = command.bank if is_finite(command.bank) else 0.0
	var stroke: float = command.stroke_speed if is_finite(command.stroke_speed) else 0.0

	match step:
		Step.SPREAD:
			_hold(span > SPREAD_SPAN, dt, HOLD_SPREAD)
		Step.FLAP:
			# One beat per rising edge, matching the one-beat-per-arm-raise rule
			# the input enforces: holding the arms down is not two wingbeats.
			if stroke > BEAT_STROKE and _armed:
				_beats += 1
				_armed = false
			elif stroke <= 0.01:
				_armed = true
			if _beats >= BEATS_WANTED:
				_advance()
		Step.BANK:
			_hold(absf(bank) > BANK_ANGLE, dt, HOLD_BANK)
		Step.TUCK:
			_hold(span < TUCK_SPAN, dt, HOLD_TUCK)
		Step.DONE:
			complete = true

	if step != Step.DONE and _step_time > STEP_PATIENCE:
		_advance()


func _hold(condition: bool, dt: float, wanted: float) -> void:
	if condition:
		_held += dt
		if _held >= wanted:
			_advance()
	else:
		# Decay rather than reset: a gesture held in three bursts is still a
		# gesture, and a player fighting a crosswind should not be punished.
		_held = maxf(0.0, _held - dt * 0.5)


func _advance() -> void:
	# A lesson never disappears before it has been readable for a moment, even
	# if the player happened to satisfy it instantly.
	if _step_time < MIN_DWELL:
		return
	step = (step + 1) as Step
	_step_time = 0.0
	_held = 0.0
	_beats = 0
	_armed = true
	if step == Step.DONE:
		complete = true


## What to show right now, or "" for nothing. Two-part: the gesture, then what
## it buys you, because "why" is what makes an instruction stick.
func cue() -> String:
	match step:
		Step.SPREAD:
			return "SPREAD YOUR ARMS — that is your wingspan"
		Step.FLAP:
			return "BEAT YOUR ARMS DOWN — climb"
		Step.BANK:
			return "DROP ONE HAND — turn that way"
		Step.TUCK:
			return "HANDS TOGETHER — tuck and dive"
		_:
			return ""
