class_name FlightCourse
extends RefCounted
## The bot / lab course, scaled by bird size (FLIGHT_SPEC §14.4):
##   1. start 20 m AGL at trimmed cruise, heading -Z
##   2. climb to 35 m along leg 1 of length L = max(120 m, 14 V_c)
##   3. a 180 deg right turn at ~0.6 phi_max onto a return leg offset 2.6 R,
##      R = V_c^2 / (g tan(0.6 phi_max))
##   4. a WINDOW at 0.35 L along the return leg: an opening 2 spans wide x
##      1.5 spans tall in a 0.5-span-thick wall
##   5. a branch PERCH 60 spans after the window, 6 spans below the cruise
##      line (max_span 1.5 spans)
## The lab adds rings along the legs, poles and wires, and a thermal.

const START_ALT := 20.0
const CRUISE_ALT := 35.0

var mass := 0.03
var span := 0.24
var r_body := 0.038
var v_c := 9.0
var leg_len := 120.0
var turn_r := 10.0
var offset := 26.0
var start := Transform3D.IDENTITY
## Centre-line polyline the bot follows (x, alt, z).
var path: Array[Vector3] = []
var window_center := Vector3.ZERO
var window_normal := Vector3.BACK     # the return leg flies +Z through it
var window_w := 0.48
var window_h := 0.36
var wall_thick := 0.12
var perch_grip := Vector3.ZERO
var perch: Perch
var total_len := 0.0
var thermal_center := Vector3.ZERO
var thermal_radius := 40.0
## Lab ring gates along leg 1 (centres; they face +Z), radius ring_r.
var rings: Array[Vector3] = []
var ring_r := 1.5


func _init(p_mass := 0.03) -> void:
	setup(p_mass)


func setup(p_mass: float) -> void:
	mass = p_mass
	var p := FlightParams.derive(mass)
	span = p.span
	r_body = p.r_body
	v_c = p.v_c
	leg_len = maxf(120.0, 14.0 * v_c)
	turn_r = v_c * v_c / (FlightMath.G * tan(0.6 * p.phi_max))
	offset = 2.6 * turn_r
	start = Transform3D(Basis.IDENTITY, Vector3(0, START_ALT, 0))
	window_w = 2.0 * span
	window_h = 1.5 * span
	wall_thick = 0.5 * span
	# Path: leg 1 (-Z), a half circle to the right, the return leg (+Z).
	path.clear()
	path.append(Vector3(0, CRUISE_ALT, 0))
	path.append(Vector3(0, CRUISE_ALT, -leg_len))
	var rc := 0.5 * offset
	var cx := rc
	for i in range(1, 24):
		var th := PI * i / 24.0
		path.append(Vector3(cx - rc * cos(th), CRUISE_ALT, -leg_len - rc * sin(th)))
	path.append(Vector3(offset, CRUISE_ALT, -leg_len))
	var z_win := -leg_len + 0.35 * leg_len
	window_center = Vector3(offset, CRUISE_ALT, z_win)
	perch_grip = Vector3(offset, CRUISE_ALT - 6.0 * span, z_win + 60.0 * span)
	path.append(Vector3(offset, CRUISE_ALT, perch_grip.z + 40.0 * span))
	total_len = 0.0
	for i in range(1, path.size()):
		total_len += Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z).length()
	thermal_center = Vector3(-0.5 * offset - 30.0, 0, -0.5 * leg_len)
	# Rings climb with the leg-1 climb (20 m -> 35 m) at 1/4, 1/2 and 3/4 L.
	rings.clear()
	ring_r = maxf(3.0 * span, 1.5)
	for k in 3:
		var f := 0.25 + 0.25 * k
		rings.append(Vector3(0, lerpf(START_ALT, CRUISE_ALT, clampf(f * 1.4, 0.0, 1.0)), -leg_len * f))


## Distance flown along the course to the perch (for the time limit).
func length_to_perch() -> float:
	return leg_len + PI * 0.5 * offset + (perch_grip.z - (-leg_len))


## Adds the course geometry to a World: window wall, perch branch (and the
## perch record), optionally the lab extras. Returns the perch.
func build(world: World, visual := true, lab_extras := false) -> Perch:
	# The wall reaches the ground (no flying under it) and well above the
	# line, and is a facade wide enough (60 spans, at least 40 m) that the
	# window, not a way round, is the route; round 2 widened it from 24
	# spans, which read as a narrow tower in the lab's overview.
	var wall_h := 2.0 * window_center.y
	FlightGeometry.window_wall(world, window_center, window_normal, window_w, window_h, wall_thick,
		window_w + maxf(60.0 * span, 40.0), wall_h, visual)
	var post_top := perch_grip - Vector3.UP * 0.02
	FlightGeometry.rod(world, Vector3(perch_grip.x + 0.8 * span, 0.0, perch_grip.z), post_top + Vector3(0.8 * span, 0, 0),
		maxf(0.02, 0.06 * span), FlightGeometry.C_WOOD, visual, FlightGeometry.LAYER_WORLD, "Post")
	perch = FlightGeometry.perch_branch(world, perch_grip, Vector3.BACK, maxf(1.6 * span, 0.3), maxf(0.012, 0.03 * span),
		1.5 * span, visual)
	world._perches.append(perch)
	if lab_extras:
		_lab_extras(world, visual)
	return perch


func _lab_extras(world: World, visual: bool) -> void:
	# Rings along leg 1 (visual gates, no collision).
	for c in rings:
		FlightGeometry.ring(world, c, Vector3(0, 0, 1), ring_r, maxf(0.08 * span, 0.05))
	# A row of poles with sagging wires across the return leg, after the perch.
	var z0 := perch_grip.z + 25.0 * span
	for k in 4:
		var x := offset - 30.0 + 20.0 * k
		FlightGeometry.rod(world, Vector3(x, 0, z0), Vector3(x, 12.0, z0), 0.15, FlightGeometry.C_WOOD, visual)
		if k > 0:
			var xa := x - 20.0
			for seg in 8:
				var t0 := float(seg) / 8.0
				var t1 := float(seg + 1) / 8.0
				var sag := func(t: float) -> float: return 11.5 - 1.2 * 4.0 * t * (1.0 - t)
				FlightGeometry.rod(world, Vector3(lerpf(xa, x, t0), sag.call(t0), z0), Vector3(lerpf(xa, x, t1), sag.call(t1), z0),
					0.012, FlightGeometry.C_WIRE, visual)
			var mid := Perch.new(Vector3(x - 10.0, 11.5 - 1.2 + 0.012, z0), Vector3.BACK, Perch.Kind.WIRE, 1.0)
			world._perches.append(mid)
	# A second, fixed branch perch on a tree-like post near the start.
	var tp := Vector3(8.0, 6.0, -12.0)
	FlightGeometry.rod(world, Vector3(tp.x + 0.3, 0.0, tp.z), Vector3(tp.x + 0.3, tp.y - 0.02, tp.z), 0.12, FlightGeometry.C_WOOD, visual)
	world._perches.append(FlightGeometry.perch_branch(world, tp, Vector3.FORWARD, 1.2, 0.03, 2.5, visual))
