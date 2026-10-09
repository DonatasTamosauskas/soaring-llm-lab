class_name FlightGeometry
extends RefCounted
## Static collision geometry (plus optional flat-shaded visuals) for flight
## test worlds and the flight lab course. Layer 1 = world, layer 2 = perch
## (ARCHITECTURE §3). Thin things are real cylinders/capsules (>= 1 cm),
## exactly what the continuous sweep must not tunnel through.

const LAYER_WORLD := 1
const LAYER_PERCH := 2

## Low-poly palette for the lab (flat shading, no textures).
const C_GROUND := Color8(122, 158, 92)
const C_WALL := Color8(230, 196, 156)
const C_WALL_COURSE := Color8(172, 150, 118)
const C_FRAME := Color8(150, 104, 72)
const C_WOOD := Color8(120, 86, 58)
const C_WIRE := Color8(40, 40, 44)
const C_RING := Color8(236, 170, 60)
const C_PERCH := Color8(96, 70, 44)
const C_GLASS := Color8(62, 80, 98)
const C_TRIM := Color8(240, 234, 220)
const C_SHUTTER := Color8(84, 126, 96)
const C_PLINTH := Color8(150, 126, 102)

static var _mats := {}


static func material(c: Color, unshaded := false) -> StandardMaterial3D:
	var key := "%s_%s" % [c.to_html(), unshaded]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if unshaded else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_mats[key] = m
	return m


static func _body(parent: Node, xf: Transform3D, layer: int, node_name: String) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = node_name
	b.collision_layer = layer
	b.collision_mask = 0
	b.transform = xf
	parent.add_child(b)
	return b


static func box(parent: Node, center: Vector3, size: Vector3, color := C_WALL, visual := true, layer := LAYER_WORLD,
		basis := Basis.IDENTITY, node_name := "Box") -> StaticBody3D:
	var b := _body(parent, Transform3D(basis, center), layer, node_name)
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	if visual:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.material_override = material(color)
		b.add_child(mi)
	return b


## A cylinder from a to b (twigs, wires, poles, branches).
static func rod(parent: Node, a: Vector3, b: Vector3, radius: float, color := C_WOOD, visual := true,
		layer := LAYER_WORLD, node_name := "Rod", sides := 6) -> StaticBody3D:
	var mid := 0.5 * (a + b)
	var axis := (b - a)
	var length := axis.length()
	var y := axis / maxf(length, 1e-6)
	var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y).normalized()
	var body := _body(parent, Transform3D(Basis(x, y, z), mid), layer, node_name)
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = radius
	sh.height = length
	cs.shape = sh
	body.add_child(cs)
	if visual:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = radius
		cm.bottom_radius = radius
		cm.height = length
		cm.radial_segments = sides
		cm.rings = 1
		mi.mesh = cm
		mi.material_override = material(color)
		body.add_child(mi)
	return body


## Flat ground (a big thin box with its top at y = height).
static func ground(parent: Node, size := 4000.0, height := 0.0, visual := true) -> StaticBody3D:
	return box(parent, Vector3(0, height - 0.5, 0), Vector3(size, 1.0, size), C_GROUND, visual, LAYER_WORLD, Basis.IDENTITY, "Ground")


## A planar slope (fix round 6): a slab 1 m thick whose top face passes
## through `through` and rises toward -Z at `deg` (negative: falls toward
## -Z), `size` = (width along X, length along the slope).
static func slope(parent: Node, through: Vector3, deg: float, size := Vector2(120.0, 900.0), color := C_GROUND,
		visual := true) -> StaticBody3D:
	var b := Basis(Vector3.RIGHT, deg_to_rad(deg))
	var n := b * Vector3.UP
	return box(parent, through - n * 0.5, Vector3(size.x, 1.0, size.y), color, visual, LAYER_WORLD, b, "Slope")


## Unit normal of slope(deg)'s top face.
static func slope_normal(deg: float) -> Vector3:
	return Basis(Vector3.RIGHT, deg_to_rad(deg)) * Vector3.UP


## A gable roof (fix round 6; a village house's is pitched 34-44 deg): two
## slabs meeting at the ridge, which runs along X through `ridge`; each
## falls `half_depth` (horizontal) to its eave at `pitch_deg`, over `width`.
## The front slope faces +Z. Returns [front, back].
static func gable_roof(parent: Node, ridge: Vector3, pitch_deg: float, half_depth: float, width: float,
		color := C_FRAME, visual := true, thick := 0.2) -> Array:
	var out := []
	var th := deg_to_rad(pitch_deg)
	var run := half_depth / cos(th)
	for side in [1.0, -1.0]:
		# Front (+Z) rises toward -Z at +pitch; the back mirrors it.
		var b := Basis(Vector3.RIGHT, side * th)
		var n := b * Vector3.UP
		var down := Vector3(0.0, -sin(th), side * cos(th))
		var mid := ridge + down * (0.5 * run)
		# The top face ends exactly at the ridge: a slab carried past it
		# would stand proud of the other slope as a lip.
		out.append(box(parent, mid - n * (0.5 * thick), Vector3(width, thick, run), color, visual,
			LAYER_WORLD, b, "RoofFront" if side > 0.0 else "RoofBack"))
	return out


## A wall of thickness `thick` with a rectangular opening (w x h) centred at
## `center`, facing `normal` (horizontal). Returns the 4 frame bodies.
static func window_wall(parent: Node, center: Vector3, normal: Vector3, w: float, h: float, thick: float,
		wall_w: float, wall_h: float, visual := true) -> Array:
	var n := Vector3(normal.x, 0, normal.z).normalized()
	var right := Vector3.UP.cross(n).normalized()
	var basis := Basis(right, Vector3.UP, n)
	var out := []
	var side_w := 0.5 * (wall_w - w)
	var top_h := 0.5 * (wall_h - h)
	# left / right pillars, lintel, sill
	out.append(box(parent, center - right * (0.5 * w + 0.5 * side_w), Vector3(side_w, wall_h, thick), C_WALL, visual, LAYER_WORLD, basis, "WallL"))
	out.append(box(parent, center + right * (0.5 * w + 0.5 * side_w), Vector3(side_w, wall_h, thick), C_WALL, visual, LAYER_WORLD, basis, "WallR"))
	out.append(box(parent, center + Vector3.UP * (0.5 * h + 0.5 * top_h), Vector3(w, top_h, thick), C_WALL, visual, LAYER_WORLD, basis, "Lintel"))
	out.append(box(parent, center - Vector3.UP * (0.5 * h + 0.5 * top_h), Vector3(w, top_h, thick), C_WALL, visual, LAYER_WORLD, basis, "Sill"))
	if visual:
		# A wooden frame around the opening (visual only, just outside it and
		# a little proud of the wall, so the opening itself is unchanged).
		var fw := maxf(0.12 * minf(w, h), 0.01)
		var ft := thick * 1.15
		var frame := Node3D.new()
		frame.name = "WindowFrame"
		parent.add_child(frame)
		var parts := [
			[center + Vector3.UP * (0.5 * h + 0.5 * fw), Vector3(w + 2.0 * fw, fw, ft)],
			[center - Vector3.UP * (0.5 * h + 0.5 * fw), Vector3(w + 2.0 * fw, fw, ft)],
			[center - right * (0.5 * w + 0.5 * fw), Vector3(fw, h, ft)],
			[center + right * (0.5 * w + 0.5 * fw), Vector3(fw, h, ft)],
		]
		for pt in parts:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = pt[1]
			mi.mesh = bm
			mi.material_override = material(C_FRAME)
			mi.transform = Transform3D(basis, pt[0])
			frame.add_child(mi)
		_facade(parent, center, basis, w, h, thick, wall_w, wall_h)
	return out


## The window wall dressed as a building (visual only, a few MultiMeshes;
## round 3: the verifier read the striped slab as programmer art). The
## building has human-scale windows (at least 1.4 x 1.6 m, or the opening's
## size for a bird whose opening is bigger), 2.2 window heights per floor,
## one band per floor on both faces, a plinth and a cornice, over the whole
## facade. The bird-sized opening sits among them with its own wooden frame
## and, on the approach face (-normal), its shutters folded flat against the
## wall: it reads as the one small window that is open. Fix round 5: round
## 4 sized every window like the opening and kept them to 12 floors and 12
## columns round it: a sparrow's 0.48 m windows were 3 px wide from flight
## distance, a dense dotted patch on a blank slab that shimmered in the
## headset (experience verifier). Now fewer, larger windows cover the facade
## (a sparrow's 40 x 70 m wall: 13 x 20).
const ROWS_MAX := 24
const COLS_MAX := 16
const HUMAN_WIN := Vector2(1.4, 1.6)


static func _facade(parent: Node, center: Vector3, basis: Basis, w: float, h: float, thick: float,
		wall_w: float, wall_h: float) -> void:
	var proud := maxf(0.03 * thick, 0.004)
	var wf := maxf(w, HUMAN_WIN.x)
	var hf := maxf(h, HUMAN_WIN.y)
	var floor_h := 2.2 * hf
	var pitch := 2.0 * wf
	var fw := maxf(0.1 * minf(wf, hf), 0.006)
	var fo := maxf(0.1 * minf(w, h), 0.006)   # the opening's own proportions
	var y_bot := center.y - 0.5 * wall_h
	var y_top := center.y + 0.5 * wall_h
	var lists := {C_WALL_COURSE: [], C_PLINTH: [], C_GLASS: [], C_TRIM: [], C_SHUTTER: []}
	var face_z := func(face: float, depth: float) -> Vector3:
		return basis.z * (face * (0.5 * thick + 0.5 * depth))
	var add := func(col: Color, off_x: float, y: float, sx: float, sy: float, face: float, depth: float) -> void:
		var pos: Vector3 = center + basis.x * off_x + Vector3.UP * (y - center.y) + face_z.call(face, depth)
		(lists[col] as Array).append(Transform3D(basis.scaled(Vector3(sx, sy, depth)), pos))
	# Floor bands between the window rows (0.35 floors below each sill), and a
	# plinth and a cornice.
	var band := 0.18 * hf
	var y_lo := y_bot + 0.6 * floor_h
	var y_hi := y_top - 0.5 * floor_h
	var k0 := int(ceil((y_lo - (center.y - 0.5 * hf - 0.35 * floor_h)) / floor_h))
	for face: float in [-1.0, 1.0]:
		add.call(C_PLINTH, 0.0, y_bot + 0.3 * floor_h, wall_w, 0.6 * floor_h, face, 2.0 * proud)
		add.call(C_PLINTH, 0.0, y_top - 0.12 * floor_h, wall_w * 1.004, 0.24 * floor_h, face, 3.0 * proud)
		var k := k0
		while true:
			var y := center.y - 0.5 * hf - 0.35 * floor_h + k * floor_h
			if y > y_hi:
				break
			if y >= y_lo:
				add.call(C_WALL_COURSE, 0.0, y, wall_w, band, face, proud)
			k += 1
	# The window grid on both faces: a trim plate, the glass proud of it (the
	# trim shows as the frame) and a sill, three boxes per window.
	var cols := mini(COLS_MAX, int(floor((0.5 * wall_w - wf) / pitch)))
	var rows_dn := mini(ROWS_MAX, int(floor((center.y - y_bot - 0.6 * floor_h - 0.5 * hf) / floor_h)))
	var rows_up := mini(ROWS_MAX, int(floor((y_top - 0.3 * floor_h - center.y - 0.5 * hf) / floor_h)))
	for face: float in [-1.0, 1.0]:
		for r in range(-rows_dn, rows_up + 1):
			for c in range(-cols, cols + 1):
				var x := c * pitch
				var y := center.y + r * floor_h
				if r == 0 and c == 0:
					# The open window has its own wooden frame: only its sill.
					add.call(C_TRIM, x, y - 0.5 * h - 1.4 * fo, w + 3.0 * fo, 1.2 * fo, face, 5.0 * proud)
					continue
				add.call(C_TRIM, x, y, wf + 2.0 * fw, hf + 2.0 * fw, face, 2.0 * proud)
				add.call(C_GLASS, x, y, wf, hf, face, 3.0 * proud)
				add.call(C_TRIM, x, y - 0.5 * hf - 1.4 * fw, wf + 3.0 * fw, 1.2 * fw, face, 5.0 * proud)
	# The open window's shutters, folded back flat against the facade.
	for side: float in [-1.0, 1.0]:
		add.call(C_SHUTTER, side * (0.5 * w + 1.2 * fo + 0.25 * w), center.y, 0.5 * w, h + fo, -1.0, 3.0 * proud)
	for col: Color in lists:
		var xfs: Array = lists[col]
		if xfs.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		mm.mesh = bm
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Facade_%s" % col.to_html(false)
		mmi.multimesh = mm
		mmi.material_override = material(col)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)


## A torus-like ring of short rods (visual gate; no collision by default).
static func ring(parent: Node, center: Vector3, normal: Vector3, radius: float, tube: float, collide := false) -> Node3D:
	var n := Vector3(normal.x, normal.y, normal.z).normalized()
	var u := n.cross(Vector3.UP)
	u = u.normalized() if u.length() > 1e-3 else Vector3.RIGHT
	var v := n.cross(u).normalized()
	var root := Node3D.new()
	root.name = "Ring"
	parent.add_child(root)
	var segs := 16
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var p0 := center + (u * cos(a0) + v * sin(a0)) * radius
		var p1 := center + (u * cos(a1) + v * sin(a1)) * radius
		if collide:
			rod(root, p0, p1, tube, C_RING, true)
		else:
			var mi := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = tube
			cm.bottom_radius = tube
			cm.height = (p1 - p0).length()
			cm.radial_segments = 5
			cm.rings = 1
			mi.mesh = cm
			mi.material_override = material(C_RING)
			var y := (p1 - p0).normalized()
			var x := y.cross(n).normalized()
			mi.transform = Transform3D(Basis(x, y, x.cross(y)), 0.5 * (p0 + p1))
			root.add_child(mi)
	return root


## A branch perch: a horizontal rod on layers 1 + 2 plus its Perch record
## (grip point on top of the branch, facing `facing`).
static func perch_branch(parent: Node, grip: Vector3, facing: Vector3, length: float, radius: float,
		max_span: float, visual := true) -> Perch:
	var f := Vector3(facing.x, 0, facing.z).normalized()
	var along := Vector3.UP.cross(f).normalized()
	var c := grip - Vector3.UP * radius
	rod(parent, c - along * 0.5 * length, c + along * 0.5 * length, radius, C_PERCH, visual, LAYER_WORLD | LAYER_PERCH, "Branch")
	return Perch.new(grip, f, Perch.Kind.BRANCH, max_span)
