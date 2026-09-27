class_name UIMockGameLoop
extends Node
## Stand-in for GameLoop in UI tests and the UI dev scene: implements the
## calls GameBridge makes (and GameLoop's apex signals) and fakes run
## stats, catches, the apex goal and endings, including a victory.

## Same signatures as GameLoop's (docs/areas/GAMELOOP.md).
signal apex_reached()
signal apex_progress(catches: int, needed: int)
signal victory(summary: Dictionary)

const APEX_CATCHES := 5

var stats := {
	"time": 0.0, "score": 0, "best_score": 0, "catches": 0, "catches_by_species": {},
	"max_mass": 0.03, "lives": 3, "lives_max": 3,
	"apex": {"reached": false, "catches": 0, "needed": APEX_CATCHES, "victory": false},
	"endless": false,
}
var starts := 0
var restarts := 0
var quits := 0
var continues := 0
## GameLoop's lesson-prey API (docs/areas/GAMELOOP.md, "Lesson prey"):
## the species of the swarm a request puts up (&"" = none: an empty
## answer), whether their models glow, and every call seen:
## ["request", n] (the n-th of this lesson), ["release"].
var lesson_species := &""
var lesson_glow := false
var lesson_prey_calls: Array = []
var _lesson_birds: Array[Bird] = []
var _lesson_asks := 0


func _enter_tree() -> void:
	add_to_group(&"game_loop")


func start_run() -> void:
	starts += 1
	stats["lives"] = stats["lives_max"]
	stats["catches"] = 0
	stats["catches_by_species"] = {}
	stats["apex"] = {"reached": false, "catches": 0, "needed": APEX_CATCHES, "victory": false}
	stats["endless"] = false
	if Game.state == Game.State.PAUSED or Game.state == Game.State.CAUGHT:
		Game.set_state(Game.State.MENU)
	Game.set_state(Game.State.PLAYING)
	Events.run_started.emit()


func restart_run() -> void:
	restarts += 1
	start_run()


func quit_run() -> void:
	quits += 1


func get_run_stats() -> Dictionary:
	stats["time"] = Game.run_time
	return stats


func fake_catch(species_id: StringName) -> void:
	stats["catches"] = int(stats["catches"]) + 1
	var by: Dictionary = stats["catches_by_species"]
	by[species_id] = int(by.get(species_id, 0)) + 1
	stats["score"] = int(stats["score"]) + 100 * (SizeRules.species_index(species_id) + 1)


## The player gets eaten: event, CAUGHT, a life gone.
func fake_caught(predator: Bird) -> void:
	stats["lives"] = maxi(0, int(stats["lives"]) - 1)
	Events.player_caught.emit(predator)
	Game.set_state(Game.State.CAUGHT)


func fake_end(summary: Dictionary = {}) -> void:
	var s := stats.duplicate(true)
	s.merge(summary, true)
	Events.run_ended.emit(s)
	Game.set_state(Game.State.ENDED)


## A worthwhile catch as the eagle; the APEX_CATCHES-th wins the run.
func fake_apex_catch() -> void:
	var a: Dictionary = stats["apex"]
	a["reached"] = true
	a["catches"] = int(a["catches"]) + 1
	apex_progress.emit(a["catches"], APEX_CATCHES)
	if int(a["catches"]) >= APEX_CATCHES and not bool(stats["endless"]):
		a["victory"] = true
		var s := stats.duplicate(true)
		s.merge({"reason": &"victory", "victory": true, "max_tier": SizeRules.SPECIES.size() - 1,
			"max_mass": SizeRules.SPECIES[-1]["mass"] * 1.1}, true)
		victory.emit(s)
		Events.run_ended.emit(s)
		Game.set_state(Game.State.ENDED)


## GameLoop.continue_after_victory(): same run, endless, back to PLAYING.
func continue_after_victory() -> void:
	if Game.state != Game.State.ENDED or not bool(stats["apex"]["victory"]):
		return
	continues += 1
	stats["endless"] = true
	var t := Game.run_time
	Game.set_state(Game.State.PLAYING)
	Game.run_time = t


## GameLoop.request_lesson_prey: a swarm of stand-in birds ahead of the
## player (the same birds on every request of a lesson, as GameLoop moves
## its swarm ahead again), recorded.
func request_lesson_prey(_near := Vector3.INF) -> Array[Bird]:
	_lesson_asks += 1
	lesson_prey_calls.append(["request", _lesson_asks])
	var out: Array[Bird] = []
	if lesson_species == &"":
		return out
	if _lesson_birds.is_empty():
		for i in 3:
			var b := UIStandInBird.new(lesson_species, float(SizeRules.species_data(lesson_species)["mass"]))
			b.model.glow = lesson_glow
			add_child(b)
			_lesson_birds.append(b)
	var p := Birds.player()
	for i in _lesson_birds.size():
		var b := _lesson_birds[i]
		if p and p.is_inside_tree():
			b.global_position = p.global_position + Vector3(-1.5 + 1.5 * i, 0.5 * i, -14.0 + 2.0 * (_lesson_asks - 1))
	out.assign(_lesson_birds)
	return out


## GameLoop.release_lesson_prey, recorded: the swarm goes.
func release_lesson_prey() -> void:
	lesson_prey_calls.append(["release"])
	_lesson_asks = 0
	for b in _lesson_birds:
		if is_instance_valid(b):
			b.queue_free()
	_lesson_birds.clear()


## GameLoop.lesson_prey: the lesson's birds still in play.
func lesson_prey() -> Array[Bird]:
	var out: Array[Bird] = []
	for b in _lesson_birds:
		if is_instance_valid(b) and b.alive:
			out.append(b)
	return out
