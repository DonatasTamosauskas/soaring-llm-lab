extends World
## L3 test world (FLIGHT_SPEC §14.1): flat ground, walls, a window,
## cylinders from 1 cm to 1 m, perches, and a stub thermal. Built only from
## the World contract and flight's own FlightGeometry, so PlayerBird tests
## never depend on the world area's in-progress internals.
##   var w := preload(".../flight_test_world.gd").new()
##   w.thermal_core = 4.0; add_child(w); await w.generated (or check is_generated)

var thermal_center := Vector3(0, 0, -2000)
var thermal_core := 0.0
var thermal_radius := 44.0
var uniform_wind := Vector3.ZERO
var with_ground := true
var visual := false


func _generate() -> void:
	bounds_radius = 5000.0
	ceiling = 3000.0
	if with_ground:
		FlightGeometry.ground(self, 8000.0, 0.0, visual)


func get_wind(pos: Vector3) -> Vector3:
	var w := uniform_wind
	if thermal_core > 0.0:
		var dx := pos.x - thermal_center.x
		var dz := pos.z - thermal_center.z
		var r2 := (dx * dx + dz * dz) / (thermal_radius * thermal_radius)
		if r2 < 1.0:
			w.y += thermal_core * (1.0 - r2) * (1.0 - r2)
	return w


func ground_height(_x: float, _z: float) -> float:
	return 0.0 if with_ground else -1e6


func add_perch(grip: Vector3, facing := Vector3.FORWARD, max_span := 10.0, radius := 0.02, length := 1.0) -> Perch:
	var p := FlightGeometry.perch_branch(self, grip, facing, length, radius, max_span, visual)
	_perches.append(p)
	return p


## A perch record with no geometry (capture logic only).
func add_virtual_perch(grip: Vector3, facing := Vector3.FORWARD, max_span := 10.0) -> Perch:
	var p := Perch.new(grip, facing, Perch.Kind.BRANCH, max_span)
	_perches.append(p)
	return p


func add_wall(center: Vector3, size: Vector3) -> StaticBody3D:
	return FlightGeometry.box(self, center, size, FlightGeometry.C_WALL, visual)


func add_rod(a: Vector3, b: Vector3, radius: float) -> StaticBody3D:
	return FlightGeometry.rod(self, a, b, radius, FlightGeometry.C_WOOD, visual)


func add_window(center: Vector3, normal: Vector3, w: float, h: float, thick: float) -> Array:
	return FlightGeometry.window_wall(self, center, normal, w, h, thick, w + 20.0, h + 20.0, visual)
