class_name GameBridge
extends RefCounted
## The UI's only door into run control and run data. GameLoop is built by
## another area, so every call is duck-typed and has a fallback that keeps
## the UI (and its tests) working without it:
##
##   start_run()    GameLoop.start_run()            else Game.set_state(PLAYING)
##   restart_run()  GameLoop.restart_run()/start_run() else MENU -> PLAYING
##   quit_to_menu() GameLoop.quit_run() (optional),  then Game.set_state(MENU)
##   continue_after_victory()  GameLoop.continue_after_victory()
##                  else ENDED -> PLAYING keeping the run clock
##   run_stats()    GameLoop.get_run_stats()         else {}
##
## After a GameLoop call the bridge makes sure the state the player asked for
## was reached, so a GameLoop that forgets to set it cannot strand the UI.
## Tests replace `stats_provider` / `game_loop` with mocks.

## GameLoop's lesson-prey calls (see lesson_prey_start):
## request_lesson_prey(near = INF) -> Array[Bird] puts (or puts again) a
## slow moth swarm ahead of the player's path and keeps it there until one
## is caught; an optional release call lets it go early.
const LESSON_PREY_REQUEST := &"request_lesson_prey"
const LESSON_PREY_RELEASE := &"release_lesson_prey"
const LESSON_PREY_LIST := &"lesson_prey"

var tree: SceneTree
## Optional override: Callable() -> Dictionary.
var stats_provider: Callable
## Optional explicit GameLoop (else the node in group "game_loop").
var game_loop: Node


func _init(p_tree: SceneTree) -> void:
	tree = p_tree


func _gl() -> Node:
	if is_instance_valid(game_loop):
		return game_loop
	return tree.get_first_node_in_group(&"game_loop") if tree else null


## The GameLoop node, if any (UIRoot connects its apex signals).
func game_loop_node() -> Node:
	return _gl()


func start_run() -> void:
	var gl := _gl()
	if gl and gl.has_method(&"start_run"):
		gl.call(&"start_run")
	if Game.state != Game.State.PLAYING:
		if Game.state == Game.State.PAUSED or Game.state == Game.State.CAUGHT:
			# Game only resets run_time when entering PLAYING from MENU/ENDED.
			Game.set_state(Game.State.MENU)
		Game.set_state(Game.State.PLAYING)


func restart_run() -> void:
	var gl := _gl()
	if gl and gl.has_method(&"restart_run"):
		gl.call(&"restart_run")
	elif gl and gl.has_method(&"start_run"):
		if Game.state == Game.State.PAUSED:
			Game.set_state(Game.State.MENU)
		gl.call(&"start_run")
	else:
		Game.set_state(Game.State.MENU)
	if Game.state != Game.State.PLAYING:
		if Game.state != Game.State.MENU and Game.state != Game.State.ENDED:
			Game.set_state(Game.State.MENU)
		Game.set_state(Game.State.PLAYING)


func quit_to_menu() -> void:
	var gl := _gl()
	if gl and gl.has_method(&"quit_run"):
		gl.call(&"quit_run")
	Game.set_state(Game.State.MENU)


## After a victory: keep flying in the same run (GameLoop's victory lap).
func continue_after_victory() -> void:
	var gl := _gl()
	if gl and gl.has_method(&"continue_after_victory"):
		gl.call(&"continue_after_victory")
	if Game.state != Game.State.PLAYING:
		# Game restarts run_time on ENDED -> PLAYING; a lap is the same run.
		var t := Game.run_time
		Game.set_state(Game.State.PLAYING)
		Game.run_time = t


## The first-flight catch lesson's prey: GameLoop's lesson-prey API
## (docs/areas/GAMELOOP.md, "Lesson prey"), duck-typed and optional.
## Without it the lesson still runs (the sky's own prey and GameLoop's catch
## assist) and says so in its words (Onboarding.catch_copy).
##   lesson_prey_start()  -> what the game put up for the lesson:
##                           {"species", "glow", "count"} ({} = nothing)
##   lesson_prey_help(n)  the player has gone n x CATCH_HELP_S without a
##                        catch: the prey are put ahead of the player again
##   lesson_prey_birds()  the lesson's birds still in play
##   lesson_prey_stop()   the lesson is over: the prey go
func lesson_prey_start() -> Dictionary:
	var gl := _gl()
	if gl == null or not gl.has_method(LESSON_PREY_REQUEST):
		return {}
	return lesson_prey_info(gl.call(LESSON_PREY_REQUEST))


func lesson_prey_help(_level: int) -> void:
	var gl := _gl()
	if gl and gl.has_method(LESSON_PREY_REQUEST):
		gl.call(LESSON_PREY_REQUEST)


## The lesson's birds still in play (GameLoop.lesson_prey; [] without it).
func lesson_prey_birds() -> Array:
	var gl := _gl()
	if gl == null or not gl.has_method(LESSON_PREY_LIST):
		return []
	var r: Variant = gl.call(LESSON_PREY_LIST)
	return r if r is Array else []


func lesson_prey_stop() -> void:
	var gl := _gl()
	if gl and gl.has_method(LESSON_PREY_RELEASE):
		gl.call(LESSON_PREY_RELEASE)


## What a request returned (the birds), as the lesson's words need it:
## {"species": the first live one's, "glow": true if its model shines
## (a `glow` on its model, duck-typed: none has one yet, so the words say
## what GameLoop's ring shows), "count"}; {} for none.
static func lesson_prey_info(r: Variant) -> Dictionary:
	if not (r is Array):
		return {}
	var n := 0
	var first: Object = null
	for b: Variant in r:
		if b is Object and is_instance_valid(b) and (b as Object).get(&"alive") == true:
			n += 1
			if first == null:
				first = b
	if first == null:
		return {}
	var m: Variant = first.get(&"model")
	var glow: bool = m is Object and is_instance_valid(m) and (m as Object).get(&"glow") == true
	return {"species": StringName(str(first.get(&"species"))), "glow": glow, "count": n}


func run_stats() -> Dictionary:
	if stats_provider.is_valid():
		return stats_provider.call()
	var gl := _gl()
	if gl and gl.has_method(&"get_run_stats"):
		var s: Variant = gl.call(&"get_run_stats")
		if s is Dictionary:
			return s
	return {}
