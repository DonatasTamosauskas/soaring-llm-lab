class_name Perch
extends RefCounted
## A spot a bird can land on and cling to: branch, wire, ledge, roof ridge,
## nest rim. Produced by World.get_perches(); claimed by one bird at a time.
##
## position is the grip point ON the surface (top of the branch/wire/ledge);
## a perched bird's body centre sits about one body radius above it.

enum Kind { BRANCH, WIRE, LEDGE, ROOF, NEST, POLE_TOP, ROCK }

var position := Vector3.ZERO
## Horizontal direction a bird sitting here faces (unit, y = 0).
var facing := Vector3.FORWARD
var kind: Kind = Kind.BRANCH
## Largest wingspan (m) that can sit here: twigs hold wrens, not eagles.
var max_span := 10.0
## The bird currently sitting here, or null.
var occupant: Bird = null
## Which part of the world this perch belongs to ("village", "forest",
## "powerline", "cliff", ...), for AI roosting choices and coverage tests.
var district: StringName = &""


func _init(p_position := Vector3.ZERO, p_facing := Vector3.FORWARD, p_kind: Kind = Kind.BRANCH, p_max_span := 10.0) -> void:
	position = p_position
	facing = p_facing
	kind = p_kind
	max_span = p_max_span


func is_free() -> bool:
	return occupant == null or not is_instance_valid(occupant) or not occupant.alive


func fits(span: float) -> bool:
	return span <= max_span
