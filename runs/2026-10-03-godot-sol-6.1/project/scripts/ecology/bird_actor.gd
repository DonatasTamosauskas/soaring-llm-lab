extends Node3D
const Species = preload("res://scripts/ecology/species.gd")
const BirdVisual = preload("res://scripts/ecology/bird_visual.gd")

var mass := 1.0
var radius := 0.38
var sweep_travel := 0.0
var slot_mass := 1.0
var velocity := Vector3.ZERO
var previous_position := Vector3.ZERO
var desired_direction := Vector3.FORWARD
var state := "Cruise"
var alive := true
var target: Node3D
var waypoint := Vector3.ZERO
var perch_point := Vector3.ZERO
var state_remaining := 0.0
var sense_remaining := 0.0
var obstacle_remaining := 0.0
var obstacle_steer := Vector3.ZERO
var respawn_remaining := 0.0
var catch_cooldown := 0.0
var protection_remaining := 1.0
var visual: Node3D
var last_heading := Vector3.FORWARD
var index := 0

func _init() -> void:
	visual = BirdVisual.new()
	add_child(visual)

func set_mass(value: float) -> void:
	mass = value
	radius = Species.radius(value)
	visual.set_mass(mass)

func update_visual(delta: float, player_mass: float, player_position: Vector3) -> void:
	if not alive:
		return
	var heading := velocity.normalized() if velocity.length_squared() > 0.02 else last_heading
	if heading.length_squared() > 0.01:
		var up := Vector3.FORWARD if absf(heading.dot(Vector3.UP)) > 0.96 else Vector3.UP
		var target_basis := Basis.looking_at(heading, up)
		quaternion = quaternion.slerp(target_basis.get_rotation_quaternion(), minf(delta * 7.0, 1.0))
	var bank := clampf(last_heading.cross(heading).y * -8.0, -0.6, 0.6)
	visual.animate(delta, velocity.length(), state, bank)
	visual.set_relation(player_mass, global_position.distance_to(player_position))
	last_heading = heading
