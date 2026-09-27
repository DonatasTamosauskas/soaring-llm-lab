extends Node
## Game flow state machine (autoload "Game").
##
## Owns only *which state we are in* and pausing. The rules of play (catching,
## growth, respawn) live in scripts/game/, which drives this via set_state().

enum State { BOOT, MENU, PLAYING, PAUSED, CAUGHT, ENDED }

var state: State = State.BOOT
## Seconds of unpaused play in the current run.
var run_time := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if state == State.PLAYING:
		run_time += delta


func set_state(new_state: State) -> void:
	if new_state == state:
		return
	var old := state
	state = new_state
	# Pausing freezes gameplay nodes only. The XR rig, UI and audio set
	# PROCESS_MODE_ALWAYS so head tracking and menus keep working.
	get_tree().paused = new_state == State.PAUSED
	if new_state == State.PLAYING and old in [State.MENU, State.ENDED, State.BOOT]:
		run_time = 0.0
	Events.game_state_changed.emit(new_state, old)


func is_playing() -> bool:
	return state == State.PLAYING


func state_name(s: int = -1) -> String:
	return State.keys()[state if s < 0 else s]
