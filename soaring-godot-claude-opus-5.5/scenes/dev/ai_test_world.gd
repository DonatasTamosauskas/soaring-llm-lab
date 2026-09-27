class_name AiTestWorld
extends World
## A self-contained arena for AI tests, the AI dev scene and AI screenshots.
##
## The real world is built in parallel by the world area; AI must not depend
## on its internals, so this subclass implements the same World contract with
## everything the NPC brains care about, deterministic from world_seed:
##  * gentle hills (ground_height is the exact piecewise-linear surface of the
##    collision mesh, so "below ground" means the same thing to both);
##  * a town (houses, pitched roofs, a church tower), a barn with an open door
##    (refuge for birds up to 0.75 m span), a copse of trees with real
##    branches to perch on, a power line with sagging wires, hedges with gaps
##    (refuges for wren/sparrow/moth), a nest box (refuge for span <= 0.2),
##    a cliff with rock perches and ridge lift on its windward face;
##  * three thermals (Gaussian columns) and a light breeze;
##  * landmarks: thermal, roost, forest, town, field, hedge, cliff, lake.
## All static geometry is on physics layer 1 and merged into one vertex-
## coloured, flat-shaded mesh (low-poly look, one material).

@export var with_visuals := true
@export var with_environment := true
@export var breeze := Vector3(-1.2, 0.0, 0.6)

const CELL := 6.0
const HALF := 460.0
const COL_GRASS := Color(0.47, 0.63, 0.33)
const COL_GRASS2 := Color(0.54, 0.68, 0.36)
const COL_FIELD := Color(0.78, 0.72, 0.42)
const COL_WALL := Color(0.9, 0.85, 0.74)
const COL_ROOF := Color(0.72, 0.36, 0.27)
const COL_WOOD := Color(0.45, 0.32, 0.22)
const COL_BARN := Color(0.62, 0.22, 0.18)
const COL_LEAF := Color(0.29, 0.5, 0.24)
const COL_LEAF2 := Color(0.37, 0.58, 0.28)
const COL_HEDGE := Color(0.24, 0.42, 0.2)
const COL_ROCK := Color(0.58, 0.55, 0.5)
const COL_WIRE := Color(0.12, 0.12, 0.13)
const COL_WATER := Color(0.33, 0.56, 0.72)

var thermals: Array[Dictionary] = []
## [base: Vector3, height: float] of every tree (tests aim birds at trunks).
var trees: Array = []
## Transform and size (w, h, d) of every house body (tests aim at walls).
var houses: Array = []
var cliff_face_z := 330.0
var cliff_top := 55.0
var wires: Array = []

var _n := 0
var _h := PackedFloat32Array()
var _refuges: Array[Dictionary] = []
var _landmarks: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _st: SurfaceTool
var _body: StaticBody3D


func _generate() -> void:
	bounds_radius = 420.0
	ceiling = 220.0
	_build()


func _build() -> void:
	_rng.seed = world_seed
	_perches.clear()
	_refuges.clear()
	_landmarks.clear()
	thermals.clear()
	wires.clear()
	trees.clear()
	houses.clear()
	_build_heights()
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_body = StaticBody3D.new()
	_body.name = "Static"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)
	_terrain()
	_town(Vector3(40, 0, 110))
	_barn(Vector3(-60, 0, 40))
	_copse(Vector3(-140, 0, -40))
	_power_line(Vector3(-40, 0, -150), Vector3(170, 0, -110), 8)
	_hedges()
	_nest_box(Vector3(-110, 0, -5))
	_cliff()
	_lake(Vector3(160, 0, 170), 55.0)
	_thermals()
	# Built last so the perches and refuges above keep their order (tests
	# pick perches by index).
	_more_cover()
	if with_visuals:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		_st.index()
		mi.mesh = _st.commit()
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		# The palette above is authored in sRGB.
		mat.vertex_color_is_srgb = true
		mat.roughness = 1.0
		mat.metallic_specular = 0.2
		mi.material_override = mat
		add_child(mi)
	if with_environment:
		_environment()


# ---------------------------------------------------------------- contract

func get_wind(pos: Vector3) -> Vector3:
	var w := breeze
	var up := 0.0
	for t in thermals:
		var c: Vector3 = t["position"]
		var dx := pos.x - c.x
		var dz := pos.z - c.z
		var r: float = t["radius"]
		var d2 := (dx * dx + dz * dz) / (r * r)
		if d2 < 6.0:
			var hag := pos.y - c.y
			var prof := clampf(hag / 15.0, 0.0, 1.0) * clampf((float(t["top"]) - hag) / 30.0, 0.0, 1.0)
			up += float(t["strength"]) * exp(-d2) * prof
	# Ridge lift: the breeze blowing onto the cliff face (-Z side) goes up.
	var dz2 := cliff_face_z - pos.z
	if dz2 > -5.0 and dz2 < 60.0 and absf(pos.x) < 150.0 and pos.y < cliff_top * 1.8:
		up += 2.2 * clampf(1.0 - dz2 / 60.0, 0.0, 1.0) * clampf(1.0 - (pos.y - cliff_top) / (cliff_top * 0.8), 0.0, 1.0)
	w.y += up
	return w


func ground_height(x: float, z: float) -> float:
	var fx := (x + HALF) / CELL
	var fz := (z + HALF) / CELL
	var ix := clampi(int(floor(fx)), 0, _n - 2)
	var iz := clampi(int(floor(fz)), 0, _n - 2)
	var u := clampf(fx - ix, 0.0, 1.0)
	var v := clampf(fz - iz, 0.0, 1.0)
	var h00 := _h[iz * _n + ix]
	var h10 := _h[iz * _n + ix + 1]
	var h01 := _h[(iz + 1) * _n + ix]
	var h11 := _h[(iz + 1) * _n + ix + 1]
	# Same diagonal split as the mesh: (00,10,11) and (00,11,01).
	if u >= v:
		return h00 + (h10 - h00) * u + (h11 - h10) * v
	return h00 + (h11 - h01) * u + (h01 - h00) * v


func get_landmarks() -> Array[Dictionary]:
	return _landmarks


func get_refuges() -> Array[Dictionary]:
	return _refuges


func get_thermals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in thermals.size():
		var t: Dictionary = thermals[i]
		out.append({"name": "thermal_%d" % i, "position": t["position"], "radius": t["radius"],
			"strength": t["strength"], "base_strength": t["strength"], "top": t["top"], "lean": Vector3.ZERO})
	return out


func get_player_spawn() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0, ground_height(0, 0) + 25.0, 0))


# ---------------------------------------------------------------- terrain

func _height_fn(x: float, z: float) -> float:
	var h := 5.0 * sin(x / 70.0) * cos(z / 95.0) + 3.0 * sin((x + z) / 43.0) + 2.0 * cos(x / 31.0 - z / 57.0)
	# Flatten the town/barn/field areas a little so buildings sit well.
	var flat := exp(-(pow((x - 20.0) / 150.0, 2.0) + pow((z - 60.0) / 150.0, 2.0)))
	h *= 1.0 - 0.7 * flat
	# Rise towards the arena rim (hills ring the arena).
	var r := Vector2(x, z).length()
	h += clampf((r - 380.0) / 60.0, 0.0, 1.5) * 40.0
	return h


func _build_heights() -> void:
	_n = int(HALF * 2.0 / CELL) + 1
	_h.resize(_n * _n)
	for iz in _n:
		for ix in _n:
			_h[iz * _n + ix] = _height_fn(-HALF + ix * CELL, -HALF + iz * CELL)


func _terrain() -> void:
	var faces := PackedVector3Array()
	for iz in _n - 1:
		for ix in _n - 1:
			var x0 := -HALF + ix * CELL
			var z0 := -HALF + iz * CELL
			var a := Vector3(x0, _h[iz * _n + ix], z0)
			var b := Vector3(x0 + CELL, _h[iz * _n + ix + 1], z0)
			var c := Vector3(x0 + CELL, _h[(iz + 1) * _n + ix + 1], z0 + CELL)
			var d := Vector3(x0, _h[(iz + 1) * _n + ix], z0 + CELL)
			# Triangles (a,b,c) and (a,c,d) seen from above.
			faces.append_array([a, b, c, a, c, d])
			if with_visuals:
				var col := COL_GRASS if (hash(ix * 7 + iz * 13) % 3) != 0 else COL_GRASS2
				var cx := x0 - 120.0
				var cz := z0 + 60.0
				if cx > -60.0 and cx < 60.0 and cz > -30.0 and cz < 40.0:
					col = COL_FIELD
				_tri(a, c, b, col)
				_tri(a, d, c, col.darkened(0.04))
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_body.add_child(cs)


# ---------------------------------------------------------------- mesh kit

## Triangle with outward normal (a,b,c counter-clockwise seen from outside).
func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	_st.set_color(col)
	_st.set_normal(n)
	# Godot's front faces are clockwise.
	_st.add_vertex(a)
	_st.add_vertex(c)
	_st.add_vertex(b)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(a, b, c, col)
	_tri(a, c, d, col)


func _box_mesh(xf: Transform3D, size: Vector3, col: Color) -> void:
	if not with_visuals:
		return
	var h := size * 0.5
	var p := func(x: float, y: float, z: float) -> Vector3: return xf * Vector3(x * h.x, y * h.y, z * h.z)
	var c := [p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(-1, 1, -1),
		p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1)]
	_quad(c[4], c[5], c[6], c[7], col)          # +z
	_quad(c[1], c[0], c[3], c[2], col)          # -z
	_quad(c[5], c[1], c[2], c[6], col.darkened(0.06))  # +x
	_quad(c[0], c[4], c[7], c[3], col.darkened(0.06))  # -x
	_quad(c[7], c[6], c[2], c[3], col.lightened(0.05)) # +y
	_quad(c[0], c[1], c[5], c[4], col.darkened(0.2))   # -y


func _box(xf: Transform3D, size: Vector3, col: Color, collide := true) -> void:
	_box_mesh(xf, size, col)
	if collide:
		var s := BoxShape3D.new()
		s.size = size
		var cs := CollisionShape3D.new()
		cs.shape = s
		cs.transform = xf
		_body.add_child(cs)


func _cyl(base: Vector3, height: float, radius: float, sides: int, col: Color, collide := true) -> void:
	if with_visuals:
		for i in sides:
			var a0 := TAU * i / sides
			var a1 := TAU * (i + 1) / sides
			var p0 := base + Vector3(cos(a0), 0, sin(a0)) * radius
			var p1 := base + Vector3(cos(a1), 0, sin(a1)) * radius
			var up := Vector3.UP * height
			_quad(p0, p0 + up, p1 + up, p1, col.darkened(0.08 * float(i % 2)))
			_tri(base + up, p1 + up, p0 + up, col.lightened(0.05))
	if collide:
		var s := CylinderShape3D.new()
		s.height = height
		s.radius = radius
		var cs := CollisionShape3D.new()
		cs.shape = s
		cs.position = base + Vector3.UP * height * 0.5
		_body.add_child(cs)


## Low-poly blob (jittered octahedron, subdivided once) for canopies/rocks.
func _blob(center: Vector3, radius: Vector3, col: Color, collide := true) -> void:
	if with_visuals:
		var v := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
		var faces := [[0, 3, 4], [0, 4, 2], [0, 2, 5], [0, 5, 3], [1, 4, 3], [1, 2, 4], [1, 5, 2], [1, 3, 5]]
		var jit := {}
		var vert := func(d: Vector3) -> Vector3:
			var key := d.snapped(Vector3.ONE * 0.01)
			if not jit.has(key):
				jit[key] = 1.0 + _rng.randf_range(-0.12, 0.12)
			return center + d.normalized() * radius * jit[key]
		for fc in faces:
			var a: Vector3 = v[fc[0]]
			var b: Vector3 = v[fc[1]]
			var c: Vector3 = v[fc[2]]
			var ab := (a + b) * 0.5
			var bc := (b + c) * 0.5
			var ca := (c + a) * 0.5
			var shade := col.darkened(_rng.randf_range(0.0, 0.12))
			# Every face above is listed counter-clockwise seen from outside.
			_tri(vert.call(a), vert.call(ab), vert.call(ca), shade)
			_tri(vert.call(ab), vert.call(b), vert.call(bc), shade.lightened(0.04))
			_tri(vert.call(ca), vert.call(bc), vert.call(c), shade.darkened(0.04))
			_tri(vert.call(ab), vert.call(bc), vert.call(ca), shade)
	if collide:
		var s := SphereShape3D.new()
		s.radius = minf(radius.x, minf(radius.y, radius.z)) * 0.9
		var cs := CollisionShape3D.new()
		cs.shape = s
		cs.position = center
		_body.add_child(cs)


func _perch(p: Vector3, facing: Vector3, kind: Perch.Kind, max_span: float) -> void:
	var f := Vector3(facing.x, 0.0, facing.z)
	f = f.normalized() if f.length_squared() > 1e-4 else Vector3.FORWARD
	_perches.append(Perch.new(p, f, kind, max_span))


func _lm(n: String, kind: String, pos: Vector3, radius: float) -> void:
	_landmarks.append({"name": n, "kind": kind, "position": pos, "radius": radius})


# ---------------------------------------------------------------- features

func _town(c: Vector3) -> void:
	_lm("town", "town", c, 70.0)
	var spots := [Vector3(-30, 0, -20), Vector3(-5, 0, -28), Vector3(22, 0, -18), Vector3(-26, 0, 14),
		Vector3(26, 0, 16), Vector3(0, 0, 30)]
	for i in spots.size():
		var p: Vector3 = c + spots[i]
		p.y = ground_height(p.x, p.z) - 0.3
		var w := _rng.randf_range(7.0, 10.0)
		var d := _rng.randf_range(8.0, 11.0)
		var h := _rng.randf_range(5.0, 8.0)
		var rot := Basis(Vector3.UP, _rng.randf_range(-0.3, 0.3))
		_box(Transform3D(rot, p + Vector3.UP * h * 0.5), Vector3(w, h, d), COL_WALL)
		houses.append([Transform3D(rot, p + Vector3.UP * h * 0.5), Vector3(w, h, d)])
		# Pitched roof: ridge along local z.
		var rh := w * 0.35
		var top := p + Vector3.UP * (h + rh)
		var e := w * 0.5 + 0.4
		var dz := d * 0.5 + 0.4
		var r0 := rot * Vector3(-e, 0, -dz) + p + Vector3.UP * h
		var r1 := rot * Vector3(e, 0, -dz) + p + Vector3.UP * h
		var r2 := rot * Vector3(e, 0, dz) + p + Vector3.UP * h
		var r3 := rot * Vector3(-e, 0, dz) + p + Vector3.UP * h
		var k0 := rot * Vector3(0, rh, -dz) + p + Vector3.UP * h
		var k1 := rot * Vector3(0, rh, dz) + p + Vector3.UP * h
		if with_visuals:
			_quad(r0, r3, k1, k0, COL_ROOF)
			_quad(r2, r1, k0, k1, COL_ROOF.darkened(0.08))
			_tri(r0, k0, r1, COL_WALL.darkened(0.05))
			_tri(r2, k1, r3, COL_WALL.darkened(0.05))
		var roof_col := BoxShape3D.new()
		roof_col.size = Vector3(w * 0.72, rh * 0.9, d + 0.8)
		var cs := CollisionShape3D.new()
		cs.shape = roof_col
		cs.transform = Transform3D(rot, p + Vector3.UP * (h + rh * 0.45))
		_body.add_child(cs)
		# Ridge perches (roofs) and a gutter ledge.
		for j in 4:
			var t := (j + 0.5) / 4.0
			_perch(k0.lerp(k1, t) + Vector3.UP * 0.05, rot * Vector3.RIGHT, Perch.Kind.ROOF, 1.4)
		_perch(r0.lerp(r3, 0.5) + rot * Vector3(-0.1, 0.0, 0.0), rot * Vector3.LEFT, Perch.Kind.LEDGE, 1.0)
	# Church tower.
	var tp := c + Vector3(45, 0, -40)
	tp.y = ground_height(tp.x, tp.z) - 0.3
	_box(Transform3D(Basis.IDENTITY, tp + Vector3.UP * 14.0), Vector3(6, 28, 6), COL_WALL.darkened(0.08))
	_box(Transform3D(Basis.IDENTITY, tp + Vector3.UP * 29.0), Vector3(7, 2, 7), COL_ROCK)
	for s in [Vector3(3.2, 30.1, 0), Vector3(-3.2, 30.1, 0), Vector3(0, 30.1, 3.2), Vector3(0, 30.1, -3.2)]:
		_perch(tp + s, s.normalized(), Perch.Kind.LEDGE, 2.5)
	_lm("tower", "landmark", tp + Vector3.UP * 30.0, 10.0)


func _barn(c: Vector3) -> void:
	var g := ground_height(c.x, c.z) - 0.2
	var p := Vector3(c.x, g, c.z)
	var W := 16.0
	var D := 22.0
	var H := 8.0
	var t := 0.4
	# Walls with a 4 m wide, 5 m high door gap in the -Z wall.
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, H * 0.5, D * 0.5)), Vector3(W, H, t), COL_BARN)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(W * 0.5, H * 0.5, 0)), Vector3(t, H, D), COL_BARN.darkened(0.05))
	_box(Transform3D(Basis.IDENTITY, p + Vector3(-W * 0.5, H * 0.5, 0)), Vector3(t, H, D), COL_BARN.darkened(0.05))
	var side := (W - 4.0) * 0.5
	_box(Transform3D(Basis.IDENTITY, p + Vector3(-(2.0 + side * 0.5), H * 0.5, -D * 0.5)), Vector3(side, H, t), COL_BARN)
	_box(Transform3D(Basis.IDENTITY, p + Vector3((2.0 + side * 0.5), H * 0.5, -D * 0.5)), Vector3(side, H, t), COL_BARN)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, 5.0 + (H - 5.0) * 0.5, -D * 0.5)), Vector3(4.0, H - 5.0, t), COL_BARN)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, H + 0.3, 0)), Vector3(W + 1.0, 0.6, D + 1.0), COL_ROOF.darkened(0.2))
	# Inside: a hay loft beam to perch on and the refuge in the middle.
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, 5.5, 4)), Vector3(W - 1.0, 0.3, 0.3), COL_WOOD)
	for i in 5:
		_perch(p + Vector3(-5 + i * 2.5, 5.7, 4), Vector3.FORWARD, Perch.Kind.BRANCH, 0.8)
	_refuges.append({"position": p + Vector3(0, 3.0, 0), "radius": 3.0, "max_span": 0.75})
	_landmarks.append({"name": "barn_door", "kind": "opening", "type": "barn_door", "position": p + Vector3(0, 2.5, -D * 0.5),
		"radius": 2.5, "normal": Vector3.FORWARD, "width": 4.0, "height": 5.0, "depth": t, "max_span": 0.75})
	for i in 4:
		_perch(p + Vector3(-6 + i * 4.0, H + 0.65, 0), Vector3.RIGHT, Perch.Kind.ROOF, 2.0)
	_lm("barn", "nest", p + Vector3(0, 3, 0), 12.0)


func _tree(base: Vector3, h: float) -> void:
	trees.append([base, h])
	_cyl(base, h, 0.28, 6, COL_WOOD)
	var n := 3 + _rng.randi() % 2
	for i in n:
		var a := TAU * i / n + _rng.randf_range(-0.4, 0.4)
		var y := _rng.randf_range(h * 0.42, h * 0.62)
		var L := _rng.randf_range(2.4, 3.2)
		var dir := Vector3(cos(a), 0.12, sin(a)).normalized()
		var mid := base + Vector3.UP * y + dir * L * 0.5
		var basis := Basis.looking_at(dir, Vector3.UP)
		_box(Transform3D(basis, mid), Vector3(0.14, 0.14, L), COL_WOOD.darkened(0.1))
		var tip := base + Vector3.UP * y + dir * (L - 0.25)
		_perch(tip + Vector3.UP * 0.08, Vector3(-dir.z, 0, dir.x), Perch.Kind.BRANCH, 0.7)
		_perch(base + Vector3.UP * y + dir * (L * 0.55) + Vector3.UP * 0.08, Vector3(dir.z, 0, -dir.x), Perch.Kind.BRANCH, 1.0)
	_blob(base + Vector3.UP * (h + 1.2), Vector3(3.0, 2.6, 3.0), COL_LEAF if _rng.randf() < 0.5 else COL_LEAF2)
	_perch(base + Vector3.UP * (h + 3.7), Vector3(1, 0, 0), Perch.Kind.BRANCH, 2.2)


func _copse(c: Vector3) -> void:
	_lm("copse", "forest", c, 45.0)
	_lm("roost", "roost", c + Vector3(0, 0, 10), 40.0)
	for i in 11:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * 38.0
		var p := c + Vector3(cos(a) * r, 0, sin(a) * r)
		p.y = ground_height(p.x, p.z) - 0.2
		_tree(p, _rng.randf_range(6.5, 9.5))


func _power_line(a: Vector3, b: Vector3, poles: int) -> void:
	var pts: Array[Vector3] = []
	for i in poles:
		var p := a.lerp(b, float(i) / float(poles - 1))
		p.y = ground_height(p.x, p.z)
		pts.append(p)
	var H := 9.0
	var along := (b - a)
	along.y = 0.0
	along = along.normalized()
	var across := Vector3(-along.z, 0, along.x)
	for p in pts:
		_cyl(p, H, 0.16, 6, COL_WOOD)
		_box(Transform3D(Basis.looking_at(across, Vector3.UP), p + Vector3.UP * (H - 0.4)), Vector3(0.14, 0.14, 2.2), COL_WOOD)
		_perch(p + Vector3.UP * (H + 0.02), along, Perch.Kind.POLE_TOP, 3.0)
	for side in [-0.9, 0.9]:
		for i in poles - 1:
			var p0: Vector3 = pts[i] + Vector3.UP * (H - 0.35) + across * side
			var p1: Vector3 = pts[i + 1] + Vector3.UP * (H - 0.35) + across * side
			var sag := 1.1
			var segs := 6
			var prev := p0
			for s in range(1, segs + 1):
				var t := float(s) / segs
				var q := p0.lerp(p1, t) + Vector3.DOWN * sag * 4.0 * t * (1.0 - t)
				var mid := (prev + q) * 0.5
				var seg := q - prev
				_box(Transform3D(Basis.looking_at(seg.normalized(), Vector3.UP), mid), Vector3(0.05, 0.05, seg.length()), COL_WIRE)
				prev = q
			wires.append([p0, p1, sag])
			var span_len := p0.distance_to(p1)
			var count := int(span_len / 1.6)
			for k in range(1, count):
				var t := float(k) / count
				var q := p0.lerp(p1, t) + Vector3.DOWN * sag * 4.0 * t * (1.0 - t)
				_perch(q + Vector3.UP * 0.04, across * (1.0 if _rng.randf() < 0.5 else -1.0), Perch.Kind.WIRE, 0.7)
	_lm("wires", "field", a.lerp(b, 0.5), 60.0)


func _hedges() -> void:
	_hedge_rows([[Vector3(-90, 0, -95), Vector3(10, 0, -85)], [Vector3(60, 0, -20), Vector3(90, 0, 50)],
		[Vector3(-170, 0, 60), Vector3(-120, 0, 110)]])


func _hedge_rows(rows: Array) -> void:
	for row in rows:
		var a: Vector3 = row[0]
		var b: Vector3 = row[1]
		var dir := (b - a)
		dir.y = 0.0
		var L := dir.length()
		dir /= L
		var basis := Basis.looking_at(dir, Vector3.UP)
		var gaps := int(L / 25.0)
		var seg_len := L / (gaps + 1)
		var gap := 1.4
		for s in gaps + 1:
			var s0 := s * seg_len + (gap * 0.5 if s > 0 else 0.0)
			var s1 := (s + 1) * seg_len - (gap * 0.5 if s < gaps else 0.0)
			var mid := a + dir * (s0 + s1) * 0.5
			mid.y = ground_height(mid.x, mid.z) + 0.9
			_box(Transform3D(basis, mid), Vector3(1.4, 2.0, s1 - s0), COL_HEDGE)
			# Small birds sit on top of each hedge segment (its own top, which
			# follows its own ground height).
			_perch(mid + Vector3.UP * 1.05, Vector3(-dir.z, 0, dir.x), Perch.Kind.BRANCH, 0.35)
			if s < gaps:
				var gp := a + dir * (s + 1) * seg_len
				gp.y = ground_height(gp.x, gp.z) + 0.9
				_refuges.append({"position": gp, "radius": 0.6, "max_span": 0.3})
				# The gap is open across the hedge (and from above).
				_landmarks.append({"name": "hedge_gap", "kind": "opening", "type": "hedge_gap", "position": gp,
					"radius": 0.7, "normal": Vector3(-dir.z, 0, dir.x), "width": gap, "height": 2.0, "depth": 1.4, "max_span": 0.3})
		_lm("hedge", "hedge", a.lerp(b, 0.5), L * 0.5)


## Cover like the real valley's, where birds of every size hide: more
## hedgerows with gaps (small birds), a field shed with an open door
## (birds up to a pigeon) and nest boxes on posts (the smallest). The first
## arena had eleven refuges; birds fleeing across it rarely had one near.
func _more_cover() -> void:
	_hedge_rows([[Vector3(-40, 0, -122), Vector3(60, 0, -128)], [Vector3(20, 0, 175), Vector3(100, 0, 205)],
		[Vector3(-205, 0, -70), Vector3(-180, 0, 20)], [Vector3(120, 0, 40), Vector3(170, 0, 95)],
		[Vector3(-60, 0, -20), Vector3(0, 0, -45)]])
	_shed(Vector3(110, 0, -70))
	_shed(Vector3(-20, 0, 250))
	for p in [Vector3(30, 0, -60), Vector3(-160, 0, 110), Vector3(140, 0, 110), Vector3(-80, 0, 150)]:
		_nest_box(p)


## A small open-fronted shed (a refuge for birds up to 0.75 m span), door
## facing -Z, with a roof-ridge perch.
func _shed(c: Vector3) -> void:
	var g := ground_height(c.x, c.z) - 0.2
	var p := Vector3(c.x, g, c.z)
	var W := 8.0
	var D := 9.0
	var H := 4.5
	var t := 0.3
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, H * 0.5, D * 0.5)), Vector3(W, H, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(W * 0.5, H * 0.5, 0)), Vector3(t, H, D), COL_WOOD.darkened(0.05))
	_box(Transform3D(Basis.IDENTITY, p + Vector3(-W * 0.5, H * 0.5, 0)), Vector3(t, H, D), COL_WOOD.darkened(0.05))
	var side := (W - 3.0) * 0.5
	_box(Transform3D(Basis.IDENTITY, p + Vector3(-(1.5 + side * 0.5), H * 0.5, -D * 0.5)), Vector3(side, H, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, p + Vector3((1.5 + side * 0.5), H * 0.5, -D * 0.5)), Vector3(side, H, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, 3.0 + (H - 3.0) * 0.5, -D * 0.5)), Vector3(3.0, H - 3.0, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, p + Vector3(0, H + 0.2, 0)), Vector3(W + 0.8, 0.4, D + 0.8), COL_ROOF.darkened(0.1))
	_refuges.append({"position": p + Vector3(0, 1.8, 0.5), "radius": 1.8, "max_span": 0.75})
	_landmarks.append({"name": "shed_door", "kind": "opening", "type": "barn_door", "position": p + Vector3(0, 1.5, -D * 0.5),
		"radius": 1.5, "normal": Vector3.FORWARD, "width": 3.0, "height": 3.0, "depth": t, "max_span": 0.75})
	for i in 3:
		_perch(p + Vector3(-2.5 + i * 2.5, H + 0.42, 0), Vector3.RIGHT, Perch.Kind.ROOF, 2.0)
	_lm("shed", "farm", p + Vector3(0, 2, 0), 10.0)


func _nest_box(p0: Vector3) -> void:
	var p := p0
	p.y = ground_height(p.x, p.z)
	_cyl(p, 3.0, 0.08, 5, COL_WOOD)
	var c := p + Vector3.UP * 3.25
	var s := 0.36
	var t := 0.03
	# Hollow box with a small round-ish hole on +Z (sides, back, roof, floor,
	# and a front split around the hole).
	_box(Transform3D(Basis.IDENTITY, c + Vector3(0, 0, -s * 0.5)), Vector3(s, s, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(s * 0.5, 0, 0)), Vector3(t, s, s), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(-s * 0.5, 0, 0)), Vector3(t, s, s), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(0, s * 0.5 + t, 0)), Vector3(s + 0.08, t * 2.0, s + 0.08), COL_ROOF)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(0, -s * 0.5, 0)), Vector3(s, t, s), COL_WOOD)
	var hole := 0.1
	_box(Transform3D(Basis.IDENTITY, c + Vector3(0, (s * 0.5 + hole * 0.5) * 0.5, s * 0.5)), Vector3(s, s * 0.5 - hole * 0.5, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(0, -(s * 0.5 + hole * 0.5) * 0.5, s * 0.5)), Vector3(s, s * 0.5 - hole * 0.5, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3((s * 0.5 + hole * 0.5) * 0.5, 0, s * 0.5)), Vector3(s * 0.5 - hole * 0.5, hole, t), COL_WOOD)
	_box(Transform3D(Basis.IDENTITY, c + Vector3(-(s * 0.5 + hole * 0.5) * 0.5, 0, s * 0.5)), Vector3(s * 0.5 - hole * 0.5, hole, t), COL_WOOD)
	_refuges.append({"position": c, "radius": 0.25, "max_span": 0.2})
	_landmarks.append({"name": "nest_box_hole", "kind": "opening", "type": "nest_box", "position": c + Vector3(0, 0, s * 0.5),
		"radius": 0.1, "normal": Vector3.BACK, "width": hole, "height": hole, "depth": t, "max_span": 0.2})
	_perch(c + Vector3(0, s * 0.5 + 0.09, 0), Vector3.BACK, Perch.Kind.NEST, 0.4)
	_lm("nest box", "nest", c, 2.0)


func _cliff() -> void:
	var z := cliff_face_z
	var w := 260.0
	var depth := 40.0
	for i in 8:
		var x := -w * 0.5 + (i + 0.5) * w / 8.0
		var hh := cliff_top + _rng.randf_range(-6.0, 8.0)
		var gz := ground_height(x, z + depth * 0.5)
		var center := Vector3(x, gz + (hh - gz) * 0.5 - 2.0, z + depth * 0.5 + _rng.randf_range(0.0, 2.0))
		# Axis-aligned, overlapping blocks: no accidental crevices at the seams.
		_box(Transform3D(Basis.IDENTITY, center), Vector3(w / 8.0 + 1.0, hh - gz + 4.0, depth), COL_ROCK.darkened(_rng.randf_range(0.0, 0.1)))
		var top := Vector3(x, hh + 0.05, z + 4.0)
		_perch(top, Vector3.FORWARD, Perch.Kind.ROCK, 3.0)
		_perch(Vector3(x + 6.0, hh * 0.6 + 0.05, z - 0.8), Vector3.FORWARD, Perch.Kind.LEDGE, 2.5)
		_box(Transform3D(Basis.IDENTITY, Vector3(x + 6.0, hh * 0.6 - 0.25, z - 0.6)), Vector3(4.0, 0.5, 1.4), COL_ROCK)
	_lm("cliff", "cliff", Vector3(0, cliff_top, z - 20.0), 120.0)


func _lake(c: Vector3, r: float) -> void:
	_lm("lake", "lake", Vector3(c.x, ground_height(c.x, c.z), c.z), r)
	if not with_visuals:
		return
	var y := ground_height(c.x, c.z) + 0.35
	var sides := 12
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		_tri(Vector3(c.x, y, c.z), Vector3(c.x + cos(a1) * r, y, c.z + sin(a1) * r), Vector3(c.x + cos(a0) * r, y, c.z + sin(a0) * r), COL_WATER)


func _thermals() -> void:
	var spots := [[Vector3(-110, 0, 70), 45.0, 3.0], [Vector3(150, 0, -30), 40.0, 2.6], [Vector3(-40, 0, 230), 38.0, 2.4]]
	for s in spots:
		var p: Vector3 = s[0]
		p.y = ground_height(p.x, p.z)
		thermals.append({"position": p, "radius": s[1], "strength": s[2], "top": 190.0})
		_lm("thermal", "thermal", p, s[1])


func _environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.3, 0.52, 0.85)
	sm.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sm.ground_horizon_color = Color(0.62, 0.7, 0.6)
	sm.ground_bottom_color = Color(0.35, 0.42, 0.3)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.9)
	env.fog_density = 0.0007
	env.fog_sky_affect = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(35.0), 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)
