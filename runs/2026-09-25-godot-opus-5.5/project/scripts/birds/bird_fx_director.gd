class_name BirdFXDirector
extends Node
## Optional: drop into a scene to get feather bursts on every catch
## (Events.bird_caught, emitted by GameLoop) without further wiring.
## Bursts are parented to `fx_parent` (default: this node's parent).

@export var fx_parent: Node = null
## Skip bursts further than this from the player (they would be invisible).
@export var max_distance := 150.0

var bursts := 0


func _ready() -> void:
	Events.bird_caught.connect(_on_caught)


func _on_caught(_predator: Bird, prey: Bird) -> void:
	if prey == null or not is_instance_valid(prey):
		return
	var pl := Birds.player()
	if pl != null and pl != prey and pl.get_body_position().distance_to(prey.get_body_position()) > max_distance:
		return
	var parent := fx_parent if fx_parent != null else get_parent()
	if parent == null:
		return
	BirdFX.feather_burst(parent, prey.get_body_position(), Color(0, 0, 0, 0), prey.get_wingspan(), prey.species, prey.velocity)
	bursts += 1
