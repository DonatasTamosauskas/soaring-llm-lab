extends "res://tests/unit/flight/flight_test_world.gd"
## Verifier (round 3) mock world: the flight test world plus a horizontal
## breeze shaped like the real world's (scripts/world/wind.gd: 2.64 m/s from
## WorldLayout.BREEZE, direction wobble +-0.08 rad at 0.21 rad/s, magnitude
## +-15 %, 40 % near the ground rising to 100 % by 30 m). The formula is
## copied here so the probe never depends on the world area's internals.
## `clock` is advanced by the probe; `breeze_on` switches it; `step_wind`
## replaces it with a fixed vector ramped in over `step_ramp` seconds from
## `step_t0` (a gust front).

var clock := 0.0
var breeze_on := false
var breeze_base := Vector3(-2.6, 0.0, 0.45)
var step_wind := Vector3.ZERO
var step_t0 := -1.0
var step_ramp := 0.5


func breeze_at(pos: Vector3) -> Vector3:
	if not breeze_on:
		return Vector3.ZERO
	var t := clock
	var g := 1.0 + 0.1 * sin(t * 0.57) + 0.05 * sin(t * 1.46 + 1.3)
	var yaw := 0.08 * sin(t * 0.21)
	var b := Vector3(
		(breeze_base.x * cos(yaw) - breeze_base.z * sin(yaw)) * g, 0.0,
		(breeze_base.x * sin(yaw) + breeze_base.z * cos(yaw)) * g)
	return b * clampf(0.4 + pos.y * 0.02, 0.4, 1.0)


func get_wind(pos: Vector3) -> Vector3:
	var w := super.get_wind(pos) + breeze_at(pos)
	if step_t0 >= 0.0 and clock >= step_t0:
		w += step_wind * clampf((clock - step_t0) / maxf(step_ramp, 1e-3), 0.0, 1.0)
	return w
