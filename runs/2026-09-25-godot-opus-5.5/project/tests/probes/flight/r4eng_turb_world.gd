extends "res://tests/unit/flight/flight_test_world.gd"
## Verifier (round 4, engineering) mock world: the flight test world plus a
## spatially varying horizontal wind (a turbulent breeze: the air a bird
## crosses changes every few metres) of amplitude `amp` m/s. Deterministic.

var amp := 2.0
var vert := 0.5


func get_wind(pos: Vector3) -> Vector3:
	var w := super.get_wind(pos)
	w.x += amp * sin(pos.x / 15.0 + pos.z / 23.0)
	w.z += amp * cos(pos.z / 17.0 - pos.x / 29.0)
	w.y += vert * sin(pos.x / 11.0 + pos.z / 13.0)
	return w
