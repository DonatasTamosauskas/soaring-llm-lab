class_name FirstContact
extends Node

## The first sixty seconds of somebody's first session, flown headlessly.
##
## A player puts the headset on, holds the controllers the way anybody holds two
## controllers, reads whatever the game says, and tries it. This drives the real
## [BirdPlayer] through the real [WingInput], in the real world, watching the
## real [Coach] on the real HUD — and performs each gesture the way a person who
## has never done it performs it: late, small, and clumsy.
##
##   godot --headless --xr-mode off --fixed-fps 90 -- --firstcontact=1
##
## It is a companion to [HandsRepro] rather than a replacement. That one asks
## what happens to a player who does nothing at all; this one asks whether the
## instructions the game gives are true — whether beating your arms really does
## climb, whether dropping a hand really does turn — and whether following them
## leaves you flying. The two failures are different and both matter: one is
## "the game let me fall", the other is "the game told me something that does
## not work".

signal finished(passed: bool)

const HEAD_HEIGHT: float = 1.62
## Where a person's hands are when they are not doing anything: a little below
## the chest, a little in front, and not far apart.
const REST_SEPARATION: float = 0.30
const HAND_HEIGHT: float = HEAD_HEIGHT - 0.30
const HAND_FORWARD: float = -0.25

## How long they sit there before touching anything. Putting a headset on, then
## looking at the sky, then noticing there is text.
const SETTLE: float = 3.0
## How long it takes to read a line and start doing it.
const REACTION: float = 2.0
## How wide a first spread actually is. Not a full arm-span — a person who has
## been told "spread your arms" while holding two objects opens them about this
## far, which is exactly the case [constant WingInput.FULL_SPAN_AT] exists for.
const SPREAD: float = 0.62
## And how fast they get there.
const SPREAD_RATE: float = 0.9

## A clumsy wingbeat: 45 cm of travel in a quarter of a second, which is 1.8 m/s
## against the 0.9 m/s the sensor demands. Half the speed of the deliberate
## 3.5 m/s beat [FlightTests] uses, because nobody's first wingbeat is a good
## one, and the question is whether a bad one still flies.
const BEAT_PERIOD: float = 0.95
const BEAT_RISE: float = 0.45
const BEAT_DROP: float = 0.25
const BEAT_TRAVEL: float = 0.45
## Beats before they stop and see what happened.
const BEATS: float = 6.0

## How far one hand drops when somebody tries banking for the first time.
const BANK_DROP: float = 0.20
## And how close together the hands come on a first tuck.
const TUCK_SEPARATION: float = 0.16

## Everything has to have happened by here. The v1 bar asks for a player flying
## and understanding why within about thirty seconds; this allows for a slow
## reader on every one of the four lessons and still calls it a failure if the
## tutorial has not finished.
const LESSON_LIMIT: float = 55.0
const DURATION: float = 62.0

var player: BirdPlayer
var world: WorldBuilder
var hud: HUD

## The four gestures, in the order the coach asks for them, plus what a player
## does once they have been taught: fly, and beat their wings when they get low.
enum Act { SPREAD, FLAP, BANK, TUCK, FLYING }

## Shortest time the player keeps doing a gesture. The coach stops asking the
## moment it is satisfied, but a person does not stop banking because the text
## changed — and a gesture measured only over the coach's own window measures
## the coach, not the control.
const HOLD: Dictionary = {
	Act.SPREAD: 3.0, Act.FLAP: 6.0, Act.BANK: 3.0, Act.TUCK: 3.5,
}

var _elapsed: float = 0.0
var _act: Act = Act.SPREAD
var _act_time: float = 0.0
var _doing: float = 0.0
var _beat_clock: float = 0.0
var _separation: float = REST_SEPARATION
var _left_y: float = HAND_HEIGHT
var _right_y: float = HAND_HEIGHT
var _done: bool = false

var _min_span_settling: float = INF
var _worst_clearance: float = INF
var _nonfinite: bool = false
var _stunned: bool = false
var _grounded: float = 0.0
var _taught_at: float = -1.0
var _mark: Dictionary = {}
var _results: Dictionary = {}
var _turned: float = 0.0
var _last_heading: float = 0.0
var _flying_seconds: float = 0.0
var _flying_climb: float = 0.0


func start(player_ref: BirdPlayer, world_ref: WorldBuilder, hud_ref: HUD) -> void:
	player = player_ref
	world = world_ref
	hud = hud_ref
	# This machine may well have flown before — the saved settings remember it,
	# and the coach is skipped for anyone who has. The whole point of this probe
	# is the session where nobody has.
	hud.teach_again()
	player.pose_source = _poses
	_open_window()
	print("")
	print("=== First contact: somebody who has never flown, doing as they are told ===")
	print("  t     doing                 on screen                 alt   speed  span   bank")


func _poses() -> Array:
	var head := Transform3D(Basis.IDENTITY, Vector3(0.0, HEAD_HEIGHT, 0.0))
	var half: float = _separation * 0.5
	var left := Transform3D(Basis.IDENTITY, Vector3(-half, _left_y, HAND_FORWARD))
	var right := Transform3D(Basis.IDENTITY, Vector3(half, _right_y, HAND_FORWARD))
	return [head, left, right]


func _physics_process(delta: float) -> void:
	if player == null or _done:
		return
	_elapsed += delta
	_act_time += delta

	_perform(delta)
	_track_turn()
	_maybe_advance()
	_watch(delta)

	if fmod(_elapsed, 5.0) < delta:
		print("  %4.1f  %-20s  %-22s %6.1f  %5.1f  %.2f  %5.2f" % [
			_elapsed, _act_name(_act), _lesson_name(hud.coach.step as int),
			player.altitude(), player.airspeed(), player.command.span,
			player.command.bank,
		])

	if _elapsed >= DURATION:
		_done = true
		_report()


## The hands. [member _doing] counts only the time actually spent performing the
## gesture, so the reaction pause does not dilute the measurement of what the
## gesture did.
func _perform(delta: float) -> void:
	var wait: float = SETTLE if _act == Act.SPREAD else REACTION
	if _act_time < wait:
		_level()
		if _act != Act.SPREAD:
			_separation = move_toward(_separation, SPREAD, SPREAD_RATE * delta)
		return
	if _doing <= 0.0:
		_open_window()
	_doing += delta

	match _act:
		Act.SPREAD:
			_separation = move_toward(_separation, SPREAD, SPREAD_RATE * delta)
			_level()
		Act.FLAP:
			_separation = move_toward(_separation, SPREAD, SPREAD_RATE * delta)
			_beat(delta)
		Act.BANK:
			_separation = move_toward(_separation, SPREAD, SPREAD_RATE * delta)
			_left_y = move_toward(_left_y, HAND_HEIGHT, delta)
			_right_y = move_toward(_right_y, HAND_HEIGHT - BANK_DROP, delta)
		Act.TUCK:
			_separation = move_toward(_separation, TUCK_SEPARATION, SPREAD_RATE * delta)
			_level()
		Act.FLYING:
			# What somebody does with what they have just been taught: wings out,
			# and beat them when the ground starts coming up.
			_separation = move_toward(_separation, SPREAD, SPREAD_RATE * delta)
			_beat(delta)


func _maybe_advance() -> void:
	if _act == Act.FLYING:
		return
	var taught_past: bool = (hud.coach.step as int) > (_act as int) or hud.coach.complete
	if taught_past and _doing >= float(HOLD[_act]):
		_close_window()
		_act = ((_act as int) + 1) as Act
		_act_time = 0.0
		_doing = 0.0
		_beat_clock = 0.0


func _open_window() -> void:
	_mark = {
		"altitude": player.altitude(),
		"speed": player.airspeed(),
	}
	_turned = 0.0
	_last_heading = player.model.heading


## Turning is accumulated frame by frame rather than measured end to end. A
## banked bird goes round and round: comparing the heading at the two ends of a
## five second turn reported 31 degrees for a bird that had gone round more than
## once, which reads as "banking barely works".
func _track_turn() -> void:
	var heading: float = player.model.heading
	_turned += absf(wrapf(heading - _last_heading, -PI, PI))
	_last_heading = heading


func _close_window() -> void:
	if _mark.is_empty():
		return
	_results[_act as int] = {
		"climb": player.altitude() - float(_mark["altitude"]),
		"turn": _turned,
		"speed_gain": player.airspeed() - float(_mark["speed"]),
		"seconds": _doing,
	}


func _level() -> void:
	_left_y = HAND_HEIGHT
	_right_y = HAND_HEIGHT


## One clumsy wingbeat cycle: arms up slowly, down quickly, then a pause while
## they work out whether anything happened.
func _beat(delta: float) -> void:
	_beat_clock += delta
	var phase: float = fmod(_beat_clock, BEAT_PERIOD)
	var low: float = HAND_HEIGHT - BEAT_TRAVEL * 0.35
	var high: float = low + BEAT_TRAVEL
	var height: float = low
	if phase < BEAT_RISE:
		height = lerpf(low, high, phase / BEAT_RISE)
	elif phase < BEAT_RISE + BEAT_DROP:
		height = lerpf(high, low, (phase - BEAT_RISE) / BEAT_DROP)
	_left_y = height
	_right_y = height


static func _act_name(act: Act) -> String:
	match act:
		Act.SPREAD:
			return "spreading"
		Act.FLAP:
			return "beating"
		Act.BANK:
			return "dropping a hand"
		Act.TUCK:
			return "hands together"
		_:
			return "flying"


# --- watching ----------------------------------------------------------------

func _watch(delta: float) -> void:
	var ground: float = world.height_at(player.global_position.x, player.global_position.z)
	_worst_clearance = minf(_worst_clearance, player.global_position.y - ground)
	if _elapsed < SETTLE:
		_min_span_settling = minf(_min_span_settling, player.command.span)
	if player.stun_timer > 0.0:
		_stunned = true
	if player.perched:
		_grounded += delta
	if not player.global_position.is_finite() or not player.model.velocity.is_finite():
		_nonfinite = true
	if hud.coach.complete and _taught_at < 0.0:
		_taught_at = _elapsed
	if _act == Act.FLYING:
		_flying_seconds += delta
		_flying_climb = player.altitude() - float(_mark.get("altitude", player.altitude()))


static func _lesson_name(step: int) -> String:
	match step:
		Coach.Step.SPREAD:
			return "SPREAD YOUR ARMS"
		Coach.Step.FLAP:
			return "BEAT YOUR ARMS DOWN"
		Coach.Step.BANK:
			return "DROP ONE HAND"
		Coach.Step.TUCK:
			return "HANDS TOGETHER"
		_:
			return "(taught)"


func _result(act: Act, key: String) -> float:
	if not _results.has(act as int):
		return 0.0
	return float((_results[act as int] as Dictionary).get(key, 0.0))


func _report() -> void:
	player.pose_source = Callable()
	_close_window()
	var problems: PackedStringArray = []

	if _taught_at < 0.0:
		problems.append(
			"never finished the tutorial — still asking for '%s' after %.0fs"
			% [_lesson_name(hud.coach.step as int), DURATION]
		)
	elif _taught_at > LESSON_LIMIT:
		problems.append("took %.0fs to teach four gestures" % _taught_at)
	if _min_span_settling < 0.5:
		problems.append(
			"wings folded to %.2f while the player was still holding the "
			% _min_span_settling + "controllers still — a resting pose is not a dive"
		)
	if player.perched:
		problems.append("ended the session on the ground")
	var grounded: float = _grounded / maxf(_elapsed, 0.001)
	if grounded > 0.15:
		problems.append("spent %.0f%% of the session on the ground" % (grounded * 100.0))
	# Clearance is measured against the terrain rather than against the trees,
	# so it is not a crash test — a novice who follows a dive lesson to the
	# bottom and pulls out at three metres has had the intended experience. The
	# failure is only the impossible one: being inside the hill.
	if _worst_clearance < -2.5:
		problems.append("went %.1f m into the ground" % -_worst_clearance)
	if _nonfinite:
		problems.append("the bird's state went non-finite")

	# The lessons have to be true. A game that says "beat your arms down —
	# climb" to somebody who then sinks has taught them that the controls do not
	# work, which is worse than not having said anything.
	var flap_seconds: float = maxf(_result(Act.FLAP, "seconds"), 0.001)
	var flap_sink: float = -_result(Act.FLAP, "climb") / flap_seconds
	var glide_sink: float = -_result(Act.SPREAD, "climb") \
		/ maxf(_result(Act.SPREAD, "seconds"), 0.001)
	var turn: float = _result(Act.BANK, "turn")
	var dive: float = _result(Act.TUCK, "speed_gain")
	if flap_sink > glide_sink * 0.5:
		problems.append(
			"beating the wings barely changed the sink (%.1f m/s against %.1f m/s gliding)"
			% [flap_sink, glide_sink]
		)
	if turn < 0.7:
		problems.append(
			"dropping a hand turned the bird only %.0f degrees in %.0fs"
			% [rad_to_deg(turn), _result(Act.BANK, "seconds")]
		)
	if dive < 3.0:
		problems.append("hands together gained only %.1f m/s" % dive)
	if _flying_seconds > 5.0 and _flying_climb < -0.6 * _flying_seconds:
		problems.append(
			"a taught player beating their wings still sank %.0f m in %.0fs"
			% [-_flying_climb, _flying_seconds]
		)

	print("")
	print("  taught in       %.1f s" % _taught_at)
	print("  gliding         %.2f m/s down" % glide_sink)
	print("  beating         %.2f m/s down over %.1fs" % [flap_sink, flap_seconds])
	print("  one hand down   %.0f degrees in %.0fs" % [
		rad_to_deg(turn), _result(Act.BANK, "seconds")
	])
	print("  hands together  %+.1f m/s" % dive)
	print("  then flying     %+.0f m over %.0fs" % [_flying_climb, _flying_seconds])
	print("  lowest wings    %.2f while resting" % _min_span_settling)
	print("  clearance       %.0f m at worst" % _worst_clearance)
	print("  on the ground   %.0f%% of the session%s" % [
		100.0 * _grounded / maxf(_elapsed, 0.001),
		",  and clipped something hard" if _stunned else "",
	])
	if problems.is_empty():
		print("FIRST CONTACT PASS — flying, taught, and never on the floor")
	else:
		print("FIRST CONTACT FAILED:")
		for p: String in problems:
			print("  - %s" % p)
	finished.emit(problems.is_empty())
