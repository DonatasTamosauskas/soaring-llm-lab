class_name Bird
extends Node3D
## Anything that flies, eats and can be eaten: the player and every NPC.
##
## This is the contract between flight, AI, the game loop, UI and audio.
## Subclasses: PlayerBird (scripts/flight/) and NpcBird (scripts/ai/).
## Everything here is in world units (metres, seconds, kilograms).

## Body mass in kg. The progression currency: who may eat whom is decided
## by mass ratio (SizeRules.can_eat), and growth adds mass.
@export var mass: float = 0.03:
	set(value):
		mass = maxf(value, 0.001)
		_on_mass_changed()

## Species id from SizeRules.SPECIES (drives the look; NPCs keep theirs,
## the player's follows its mass).
@export var species: StringName = &"sparrow"

## World-space velocity, m/s. Maintained by whatever moves the bird.
var velocity := Vector3.ZERO
var alive := true
## True while clinging to a branch, wire or ledge.
var perched := false


func _enter_tree() -> void:
	add_to_group(&"birds")
	Birds.register(self)


func _exit_tree() -> void:
	Birds.unregister(self)


func is_player() -> bool:
	return false


## Where the bird's body is. For the player this is the head, not the rig
## origin; everything that measures distance to a bird must use this.
func get_body_position() -> Vector3:
	return global_position


## Unit vector the bird is facing (beak direction).
func get_forward() -> Vector3:
	return -global_basis.z


func get_wingspan() -> float:
	return SizeRules.wingspan_for_mass(mass)


## Radius of the body for collisions and catching, metres.
func get_body_radius() -> float:
	return SizeRules.body_radius_for_mass(mass)


func can_eat(other: Bird) -> bool:
	return other != self and alive and other.alive and SizeRules.can_eat(mass, other.mass)


## Called by GameLoop when this bird is eaten. Default: disappear.
func on_caught(_by: Bird) -> void:
	alive = false


## Called by GameLoop when this bird eats prey.
func on_ate(_prey: Bird, _mass_gained: float) -> void:
	pass


func _on_mass_changed() -> void:
	pass
