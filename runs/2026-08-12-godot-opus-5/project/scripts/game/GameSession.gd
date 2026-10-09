class_name GameSession
extends RefCounted

## One run, from the first flap to the summary.
##
## This is the thing the game was missing: a session with a beginning, an
## escalation, and an end you can reach in both directions. It owns the run's
## state — rank, lives, streak, score, and the clock — and nothing else. It has
## no scene, no nodes and no timers of its own, so [SessionSim] can play ten
## minutes of it in a millisecond and [GameManager] can play it at 90 Hz through
## the identical code path. The balance numbers in [ProgressionTests] are
## therefore measured on the object that ships, not on a model of it.

signal rank_changed(index: int, rank_name: String, promoted: bool)
signal lives_changed(lives: int)
signal score_changed(score: int)
signal ended(won: bool)

enum State { FLYING, WON, LOST }

var state: State = State.FLYING
var lives: int = Progression.LIVES
var score: int = 0
var streak: int = 0
var best_streak: int = 0
var catches: int = 0
var deaths: int = 0
## Seconds of flying time in this run. Stops at the moment the run ends.
var elapsed: float = 0.0
var rank: int = 0
var peak_size: float = Progression.START_SIZE
var last_prey_size: float = 0.0
var last_predator_size: float = 0.0

## Elapsed time at which each rank was first reached, or -1 for ranks never
## reached. This array is the difficulty curve: everything [SessionSim] reports
## about pacing is read straight out of it.
var rank_times: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	begin(Progression.START_SIZE)


func begin(size: float) -> void:
	var start: float = size if is_finite(size) else Progression.START_SIZE
	state = State.FLYING
	lives = Progression.LIVES
	score = 0
	streak = 0
	best_streak = 0
	catches = 0
	deaths = 0
	elapsed = 0.0
	peak_size = start
	last_prey_size = 0.0
	last_predator_size = 0.0
	rank_times = PackedFloat32Array()
	rank_times.resize(Progression.RANKS.size())
	rank_times.fill(-1.0)
	rank = Progression.rank_index(start)
	rank_times[rank] = 0.0


func is_over() -> bool:
	return state != State.FLYING


## Advances the run clock and notices anything the player's size implies. Safe
## to call with a garbage delta — a run that ended because a frame hiccuped and
## handed us a NaN would be an unforgettably bad bug.
func tick(delta: float, size: float) -> void:
	if state != State.FLYING:
		return
	if is_finite(delta) and delta > 0.0:
		elapsed += minf(delta, 0.5)
	_observe(size)


## Returns the score the catch was worth, so the caller can show it.
func record_catch(prey_size: float, size_after: float) -> int:
	if state != State.FLYING:
		return 0
	catches += 1
	streak += 1
	best_streak = maxi(best_streak, streak)
	last_prey_size = prey_size if is_finite(prey_size) else 0.0
	var gained: int = Progression.score_for_catch(last_prey_size, streak)
	score += gained
	score_changed.emit(score)
	_observe(size_after)
	return gained


## Returns true if that was the last life.
func record_death(by_size: float) -> bool:
	if state != State.FLYING:
		return false
	deaths += 1
	streak = 0
	last_predator_size = by_size if is_finite(by_size) else 0.0
	lives = maxi(lives - 1, 0)
	lives_changed.emit(lives)
	if lives <= 0:
		_finish(false)
		return true
	return false


## Rank is recomputed from size rather than remembered, so demotion after being
## caught is as visible as promotion after a catch — the ladder runs both ways
## and the HUD reads the same number either way.
func _observe(size: float) -> void:
	if not is_finite(size):
		return
	peak_size = maxf(peak_size, size)
	var index: int = Progression.rank_index(size)
	if index != rank:
		var promoted: bool = index > rank
		rank = index
		if rank_times[index] < 0.0:
			rank_times[index] = elapsed
		rank_changed.emit(index, Progression.name_of_rank(index), promoted)
	if Progression.is_apex(size):
		_finish(true)


func _finish(won: bool) -> void:
	if state != State.FLYING:
		return
	state = State.WON if won else State.LOST
	ended.emit(won)


func outcome_title() -> String:
	match state:
		State.WON:
			return "SOVEREIGN OF THE SKY"
		State.LOST:
			return "BROUGHT DOWN"
		_:
			return Progression.name_of_rank(rank)


## Everything worth printing at the end of a run, or worth logging from a
## simulated one.
func summary() -> Dictionary:
	return {
		"state": state,
		"won": state == State.WON,
		"elapsed": elapsed,
		"catches": catches,
		"deaths": deaths,
		"score": score,
		"best_streak": best_streak,
		"peak_size": peak_size,
		"rank": rank,
		"rank_times": rank_times,
	}


static func clock(seconds: float) -> String:
	if not is_finite(seconds) or seconds < 0.0:
		return "--:--"
	var whole: int = int(seconds)
	return "%d:%02d" % [whole / 60, whole % 60]
