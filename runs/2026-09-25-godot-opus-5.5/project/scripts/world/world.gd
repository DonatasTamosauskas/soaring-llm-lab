class_name World
extends Node3D
## The playable world: terrain, structures, perches and moving air.
##
## Owned by the world area. Every other area talks to the world only through
## the methods below (find it with World.find()). This base version is a flat,
## windless plain so other areas can test before the real world exists; the
## world area fills these in without changing their signatures.
##
## The real valley is SoaringWorld (scripts/world/soaring_world.gd), root of
## scenes/world/world.tscn. This base stays flat and windless on purpose so
## other areas' tests can use World.new() cheaply.

## Emitted once the world has finished generating (also see is_generated).
signal generated()

## Deterministic layout: same seed, same world.
@export var world_seed := 1
## Horizontal radius of the playable area, m, centred on the origin.
@export var bounds_radius := 600.0
## Top of the playable air, m above y = 0.
@export var ceiling := 300.0

var _perches: Array[Perch] = []
## True once generation finished (`generated` may have fired before you
## connected: check this first).
var is_generated := false


static func find(tree: SceneTree) -> World:
	return tree.get_first_node_in_group(&"world") as World


func _enter_tree() -> void:
	add_to_group(&"world")


func _ready() -> void:
	_generate()
	is_generated = true
	generated.emit()


## Subclasses build their world here (synchronously, during _ready).
func _generate() -> void:
	pass


## Air velocity at pos, m/s: thermals, ridge lift, breeze. Flight integrates
## airspeed = velocity - get_wind(pos), so an updraft lifts a gliding bird.
## Must be cheap: every bird calls it every physics frame.
func get_wind(_pos: Vector3) -> Vector3:
	return Vector3.ZERO


## Height of the solid ground at (x, z): terrain, water surfaces and rock
## masses standing on the floor (cliffs, canyon walls); ignoring buildings,
## trees and free-standing structures you can fly under (bridges, arches).
func ground_height(_x: float, _z: float) -> float:
	return 0.0


## Every perch in the world. Do not mutate the array; claim a perch by
## setting its occupant.
func get_perches() -> Array[Perch]:
	return _perches


## Free perches within radius of pos that fit a bird of wingspan span.
func find_perches(pos: Vector3, radius: float, span: float) -> Array[Perch]:
	var out: Array[Perch] = []
	var r2 := radius * radius
	for p in _perches:
		if p.is_free() and p.fits(span) and p.position.distance_squared_to(pos) <= r2:
			out.append(p)
	return out


## Where the player starts and respawns (a perch high enough to launch from).
func get_player_spawn() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, 30, 0))


## Named places: [{name, kind, position, radius}]. Kinds include "thermal",
## "nest", "roost", "window", "town", "forest", "cliff". Used by AI (where to
## roost and soar), the tutorial, and tests/screenshots.
func get_landmarks() -> Array[Dictionary]:
	return []


## Hiding places for small birds: [{position, radius, max_span}]. A bird whose
## wingspan exceeds max_span cannot follow inside.
func get_refuges() -> Array[Dictionary]:
	return []


## Live thermal columns: [{name, position (centre at ground level), radius,
## strength (core updraft m/s now), top (m), lean (horizontal offset per m of
## height)}]. The flat base has none.
func get_thermals() -> Array[Dictionary]:
	return []


## True if pos is at a water surface (the lake, the river): water is not
## ground to stand on (integration round 1: flight splashes off it). The
## base world has no water.
func is_water(_pos: Vector3) -> bool:
	return false


## True if pos is inside the playable volume.
func is_inside(pos: Vector3) -> bool:
	return Vector2(pos.x, pos.z).length() <= bounds_radius and pos.y <= ceiling \
		and pos.y >= ground_height(pos.x, pos.z) - 1.0
