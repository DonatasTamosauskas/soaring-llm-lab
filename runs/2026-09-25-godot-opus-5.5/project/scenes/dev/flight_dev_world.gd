extends World
## The flight lab's world (scenes/dev/flight_dev.tscn): flat ground, the
## FlightCourse (rings, window wall, poles and wires, perches) built by the
## lab, one bell thermal with a visible column, an optional uniform wind,
## and low-poly scenery for speed and height cues. Built only from the World
## contract and flight's own FlightGeometry (never the world area's code).
##
## Scenery is visual only (no collision) and kept clear of the course
## corridor, so nothing in it can be hit by a bird flying the course.

var course: FlightCourse
var thermal_core := 4.0
var uniform_wind := Vector3.ZERO
var scenery_seed := 7

const C_TREE := Color8(70, 120, 72)
const C_TREE2 := Color8(92, 138, 70)
const C_TRUNK := Color8(104, 76, 52)
const C_ROCK := Color8(150, 146, 136)
const C_HILL := Color8(108, 140, 96)
const C_THERMAL := Color(1.0, 0.94, 0.78, 0.05)


func _generate() -> void:
	bounds_radius = 3000.0
	ceiling = 400.0
	FlightGeometry.ground(self, 6000.0, 0.0, true)
	var rng := RandomNumberGenerator.new()
	rng.seed = scenery_seed
	_scatter(rng)
	_hills(rng)
	if course != null:
		_thermal_column()
		_course_markers()


func get_wind(pos: Vector3) -> Vector3:
	var w := uniform_wind
	if course != null and thermal_core > 0.0:
		var c := course.thermal_center
		var r2 := ((pos.x - c.x) * (pos.x - c.x) + (pos.z - c.z) * (pos.z - c.z)) / (course.thermal_radius * course.thermal_radius)
		if r2 < 1.0:
			# Bell profile (C1-smooth), fading out above 300 m.
			var fade := clampf((ceiling - 100.0 - pos.y) / 100.0, 0.0, 1.0)
			w.y += thermal_core * (1.0 - r2) * (1.0 - r2) * fade
	return w


func ground_height(_x: float, _z: float) -> float:
	return 0.0


func get_thermals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if course != null and thermal_core > 0.0:
		out.append({"position": course.thermal_center, "radius": course.thermal_radius, "strength": thermal_core})
	return out


func get_player_spawn() -> Transform3D:
	return course.start if course != null else Transform3D(Basis.IDENTITY, Vector3(0, 20, 0))


# --- scenery -------------------------------------------------------------------

## Inside the course corridor (plus a margin): no scenery there.
func _in_corridor(x: float, z: float) -> bool:
	if course == null:
		return absf(x) < 30.0 and absf(z) < 30.0
	var c := course
	var x0 := -25.0
	var x1 := c.offset + 25.0
	var z0 := -c.leg_len - c.offset - 25.0
	var z1 := c.perch_grip.z + 60.0
	# The thermal and the start area stay clear too.
	var t := c.thermal_center
	if Vector2(x - t.x, z - t.z).length() < c.thermal_radius + 10.0:
		return true
	return x > x0 and x < x1 and z > z0 and z < z1


func _scatter(rng: RandomNumberGenerator) -> void:
	var tree := _tree_mesh()
	var rock := _rock_mesh()
	var trees: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var span := 700.0
	var tries := 0
	while trees.size() < 700 and tries < 6000:
		tries += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span - 200.0, span - 200.0)
		if _in_corridor(x, z):
			continue
		var s := rng.randf_range(0.7, 1.6)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.3), s))
		trees.append(Transform3D(b, Vector3(x, 0, z)))
	tries = 0
	while rocks.size() < 160 and tries < 3000:
		tries += 1
		var x2 := rng.randf_range(-span, span)
		var z2 := rng.randf_range(-span - 200.0, span - 200.0)
		if _in_corridor(x2, z2):
			continue
		var s2 := rng.randf_range(0.4, 2.2)
		var b2 := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s2, s2 * rng.randf_range(0.5, 0.9), s2))
		rocks.append(Transform3D(b2, Vector3(x2, -0.2 * s2, z2)))
	_multimesh(tree, trees, "Trees")
	_multimesh(rock, rocks, "Rocks")


## The route painted on the ground as chevrons pointing along it (visual
## only): the overview and a desktop pilot read the route at a glance.
## Round 2: they were translucent spheres a few spans under the route, which
## floated in front of the chase camera as white blobs; on the ground they
## never enter a flying view's foreground.
func _course_markers() -> void:
	var sp := course.span
	var gap := maxf(6.0, 18.0 * sp)
	var size := maxf(1.2, 1.6 * sp)
	var xfs: Array[Transform3D] = []
	var pts: Array[Vector3] = course.path.duplicate()
	pts[pts.size() - 1] = course.perch_grip
	var carry := 0.0
	for i in range(1, pts.size()):
		var a: Vector3 = pts[i - 1]
		var b: Vector3 = pts[i]
		var seg := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var l := seg.length()
		if l < 1e-3:
			continue
		var yaw := FlightMath.yaw_of(seg)
		var d := gap - carry
		while d < l:
			var p := a + (b - a) * (d / l)
			xfs.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * size), Vector3(p.x, 0.04, p.z)))
			d += gap
		carry = l - (d - gap)
	_multimesh(_chevron_mesh(), xfs, "CourseMarkers")


## A flat chevron (unit size) pointing along -Z, flat shaded.
func _chevron_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	st.set_color(Color8(238, 228, 196))
	var tip := Vector3(0, 0, -0.6)
	var l_out := Vector3(-0.5, 0, 0.3)
	var l_in := Vector3(-0.28, 0, 0.3)
	var notch := Vector3(0, 0, -0.18)
	var r_in := Vector3(0.28, 0, 0.3)
	var r_out := Vector3(0.5, 0, 0.3)
	for tri in [[tip, l_in, l_out], [tip, notch, l_in], [tip, r_out, r_in], [tip, r_in, notch]]:
		for v in tri:
			st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	var m := _vertex_color_material()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh


func _multimesh(mesh: Mesh, xfs: Array[Transform3D], node_name: String) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	add_child(mmi)


func _hills(rng: RandomNumberGenerator) -> void:
	# A ring of low, wide hills on the horizon (visual only).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	st.set_color(C_HILL)
	for k in 26:
		var a := TAU * k / 26.0 + rng.randf_range(-0.08, 0.08)
		var d := rng.randf_range(1300.0, 1900.0)
		var c := Vector3(sin(a) * d, 0.0, cos(a) * d - 200.0)
		var r := rng.randf_range(220.0, 420.0)
		var h := rng.randf_range(60.0, 170.0)
		_cone(st, c, r, h, 7, rng)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Hills"
	mi.mesh = st.commit()
	mi.material_override = _vertex_color_material()
	add_child(mi)


func _thermal_column() -> void:
	var c := course.thermal_center
	var cyl := CylinderMesh.new()
	cyl.top_radius = course.thermal_radius * 0.7
	cyl.bottom_radius = course.thermal_radius
	cyl.height = 260.0
	cyl.radial_segments = 16
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var m := StandardMaterial3D.new()
	m.albedo_color = C_THERMAL
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	var mi := MeshInstance3D.new()
	mi.name = "ThermalColumn"
	mi.mesh = cyl
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(c.x, 130.0, c.z)
	add_child(mi)
	# Rings every 40 m make the column readable from far away.
	for k in 6:
		var y := 20.0 + 40.0 * k
		var r := lerpf(course.thermal_radius, course.thermal_radius * 0.7, y / 260.0)
		var ring := FlightGeometry.ring(self, Vector3(c.x, y, c.z), Vector3.UP, r, 0.25)
		ring.name = "ThermalRing%d" % k


# --- low-poly meshes (flat normals) ---------------------------------------------

func _vertex_color_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	return m


func _tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	st.set_color(C_TRUNK)
	_prism(st, Vector3.ZERO, 0.35, 2.2, 5)
	st.set_color(C_TREE)
	_cone(st, Vector3(0, 1.6, 0), 2.6, 4.2, 6, rng)
	st.set_color(C_TREE2)
	_cone(st, Vector3(0, 3.8, 0), 1.9, 3.6, 6, rng)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, _vertex_color_material())
	return mesh


func _rock_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	st.set_color(C_ROCK)
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 6
	sphere.rings = 3
	var arr := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var jitter := {}
	for i in idx:
		var v := verts[i]
		var key := v.snapped(Vector3.ONE * 0.01)
		if not jitter.has(key):
			jitter[key] = v * rng.randf_range(0.8, 1.15)
		st.add_vertex(jitter[key])
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, _vertex_color_material())
	return mesh


static func _cone(st: SurfaceTool, base: Vector3, r: float, h: float, sides: int, rng: RandomNumberGenerator) -> void:
	var tip := base + Vector3(rng.randf_range(-0.05, 0.05) * r, h, rng.randf_range(-0.05, 0.05) * r)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := base + Vector3(sin(a0), 0, cos(a0)) * r
		var p1 := base + Vector3(sin(a1), 0, cos(a1)) * r
		# Godot's front faces wind clockwise seen from outside.
		st.add_vertex(p1)
		st.add_vertex(p0)
		st.add_vertex(tip)


static func _prism(st: SurfaceTool, base: Vector3, r: float, h: float, sides: int) -> void:
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := base + Vector3(sin(a0), 0, cos(a0)) * r
		var p1 := base + Vector3(sin(a1), 0, cos(a1)) * r
		var q0 := p0 + Vector3.UP * h
		var q1 := p1 + Vector3.UP * h
		st.add_vertex(p1)
		st.add_vertex(p0)
		st.add_vertex(q1)
		st.add_vertex(q1)
		st.add_vertex(p0)
		st.add_vertex(q0)
