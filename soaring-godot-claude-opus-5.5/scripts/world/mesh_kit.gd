class_name MeshKit
extends RefCounted
## Accumulates flat-shaded, vertex-coloured triangles and the collision that
## matches them, for one merged chunk of the world (one draw call).
##
## Conventions: every primitive takes points counter-clockwise as seen from
## OUTSIDE (the usual maths convention); the kit flips them to Godot's
## clockwise front faces. `xf` is applied to everything emitted, so builders
## can work in local space. Solid triangles go into `faces` (a trimesh
## collider built from exactly what is drawn); thin things (wires, twigs,
## poles) add capsules instead via `collide = false` + add_capsule().
##
## Mirrored transforms (negative determinant: a left-handed basis passed to
## box/prism/wall, or a mirrored `xf`) turn "counter-clockwise from outside"
## into clockwise, i.e. a solid drawn and collided inside-out: see-through
## from outside, a trap from inside (round 3's cliff shelves). The kit
## detects them and flips the winding back, so every primitive stays
## outward-facing whatever frame it is built in.

var name := ""
var verts := PackedVector3Array()
var norms := PackedVector3Array()
var cols := PackedColorArray()
## Trimesh collision triangles (already in Godot winding).
var faces := PackedVector3Array()
## Primitive colliders: [[Shape3D, Transform3D]] in kit space.
var shapes: Array = []
## Local-to-kit transform applied to everything emitted.
var xf := Transform3D.IDENTITY:
	set(value):
		xf = value
		_xf_mirrored = value.basis.determinant() < 0.0
		_flip = _xf_mirrored != _t_mirrored
## Emitted triangles also collide (trimesh) while true.
var collide := true
## Per-facet value jitter amplitude (0 = uniform colour).
var jitter := 0.05
## Written into vertex alpha: the foliage shader's sway weight.
var sway := 0.0

var rng := RandomNumberGenerator.new()
## Vertices of the last blob() (for convex-hull colliders).
var last_blob := PackedVector3Array()

# Winding correction for mirrored frames: xf's, the current primitive's t's,
# and whether exactly one of them mirrors (then _emit swaps two corners).
var _xf_mirrored := false
var _t_mirrored := false
var _flip := false


func _init(p_name: String = "", p_seed: int = 1) -> void:
	name = p_name
	rng.seed = hash(p_name) ^ p_seed


func tri_count() -> int:
	return verts.size() / 3


func is_empty() -> bool:
	return verts.is_empty()


# --- core emission -----------------------------------------------------

func _facet_color(col: Color) -> Color:
	var c := col
	if jitter > 0.0:
		c = Palette.vary(col, (rng.randf() - 0.5) * 2.0 * jitter)
	c.a = sway
	return c


## Emits one world-space triangle (CCW from outside) with a final colour.
func _emit(A: Vector3, B: Vector3, C: Vector3, c: Color) -> void:
	if _flip:
		var s := B
		B = C
		C = s
	var n := (B - A).cross(C - A)
	var l := n.length()
	if l < 1e-10:
		return
	n /= l
	verts.append(A)
	verts.append(C)
	verts.append(B)
	norms.append(n)
	norms.append(n)
	norms.append(n)
	cols.append(c)
	cols.append(c)
	cols.append(c)
	if collide:
		faces.append(A)
		faces.append(C)
		faces.append(B)


func tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	_emit(xf * a, xf * b, xf * c, _facet_color(col))


## Quad a-b-c-d, CCW from outside. Both halves share one facet colour.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var fc := _facet_color(col)
	var A := xf * a
	var B := xf * b
	var C := xf * c
	var D := xf * d
	_emit(A, B, C, fc)
	_emit(A, C, D, fc)


## Convex polygon (CCW from outside) as a fan.
func poly(pts: PackedVector3Array, col: Color) -> void:
	var fc := _facet_color(col)
	var p0 := xf * pts[0]
	for i in range(1, pts.size() - 1):
		_emit(p0, xf * pts[i], xf * pts[i + 1], fc)


# --- solids ------------------------------------------------------------

## Primitives built in a frame t (box, prism, wall) call this first: a
## mirrored t flips their winding back. Returns the previous state for
## _end_frame (frames do not compose: each primitive transforms its own
## points).
func _begin_frame(t: Transform3D) -> bool:
	var was := _t_mirrored
	_t_mirrored = t.basis.determinant() < 0.0
	_flip = _xf_mirrored != _t_mirrored
	return was


func _end_frame(was: bool) -> void:
	_t_mirrored = was
	_flip = _xf_mirrored != _t_mirrored


## Axis-aligned (in t's frame) box of `size` centred at t.origin.
## `top` overrides the top face colour when its alpha > 0. skip: bitmask of
## faces to omit (1 +X, 2 -X, 4 +Y, 8 -Y, 16 +Z, 32 -Z) where they are known
## to be buried.
func box(t: Transform3D, size: Vector3, col: Color, top := Color(0, 0, 0, 0), skip := 0) -> void:
	var frame := _begin_frame(t)
	var h := size * 0.5
	var p := [
		t * Vector3(-h.x, -h.y, -h.z), t * Vector3(h.x, -h.y, -h.z),
		t * Vector3(h.x, h.y, -h.z), t * Vector3(-h.x, h.y, -h.z),
		t * Vector3(-h.x, -h.y, h.z), t * Vector3(h.x, -h.y, h.z),
		t * Vector3(h.x, h.y, h.z), t * Vector3(-h.x, h.y, h.z),
	]
	var tc := top if top.a > 0.0 else col
	if not skip & 1:
		quad(p[1], p[2], p[6], p[5], col)  # +X
	if not skip & 2:
		quad(p[4], p[7], p[3], p[0], col)  # -X
	if not skip & 4:
		quad(p[3], p[7], p[6], p[2], tc)  # +Y
	if not skip & 8:
		quad(p[0], p[1], p[5], p[4], col)  # -Y
	if not skip & 16:
		quad(p[4], p[5], p[6], p[7], col)  # +Z
	if not skip & 32:
		quad(p[0], p[3], p[2], p[1], col)  # -Z
	_end_frame(frame)


## Box between two corner points, axis-aligned in kit-local space.
func box_between(lo: Vector3, hi: Vector3, col: Color, top := Color(0, 0, 0, 0), skip := 0) -> void:
	box(Transform3D(Basis.IDENTITY, (lo + hi) * 0.5), hi - lo, col, top, skip)


## A beam of square-ish section from a to b (thin boxes: rafters, bracing).
func beam(a: Vector3, b: Vector3, w: float, h: float, col: Color, up_hint := Vector3.UP) -> void:
	var d := b - a
	var l := d.length()
	if l < 1e-5:
		return
	var z := d / l
	var upv := up_hint if absf(z.dot(up_hint)) < 0.95 else Vector3.RIGHT
	var x := upv.cross(z).normalized()
	var y := z.cross(x)
	box(Transform3D(Basis(x, y, z), (a + b) * 0.5), Vector3(w, h, l), col)


static func _perp_basis(axis: Vector3) -> Array:
	var z := axis.normalized()
	var ref := Vector3.UP if absf(z.y) < 0.9 else Vector3.RIGHT
	var x := ref.cross(z).normalized()
	var y := z.cross(x)
	return [x, y]


## Tapered cylinder (frustum) from a (radius r0) to b (radius r1).
func cyl(a: Vector3, b: Vector3, r0: float, r1: float, sides: int, col: Color, cap_a := true, cap_b := true, rot := 0.0, col_b := Color(0, 0, 0, 0)) -> void:
	var ax := b - a
	if ax.length() < 1e-6:
		return
	var pb := _perp_basis(ax)
	var ux: Vector3 = pb[0]
	var uy: Vector3 = pb[1]
	var ra := PackedVector3Array()
	var rb := PackedVector3Array()
	for i in sides:
		var th := rot + TAU * float(i) / float(sides)
		var dir := ux * cos(th) + uy * sin(th)
		ra.append(a + dir * r0)
		rb.append(b + dir * r1)
	var cb := col_b if col_b.a > 0.0 else col
	for i in sides:
		var j := (i + 1) % sides
		if r1 <= 1e-5:
			tri(ra[i], ra[j], b, col)
		elif r0 <= 1e-5:
			tri(a, rb[j], rb[i], col)
		else:
			quad(ra[i], ra[j], rb[j], rb[i], col)
	if cap_a and r0 > 1e-5:
		var rev := PackedVector3Array()
		for i in range(sides - 1, -1, -1):
			rev.append(ra[i])
		poly(rev, col)
	if cap_b and r1 > 1e-5:
		poly(rb, cb)


## Extrudes a polygon given in the XY plane of t (CCW seen from +Z) along
## t's +Z by depth. Front cap at z = depth faces +Z. edge_cols (optional)
## colours the side face of each edge pts2[i] -> pts2[i + 1] (e.g. a grassy
## top on a rock ledge); otherwise side_col, or col.
func prism(t: Transform3D, pts2: PackedVector2Array, depth: float, col: Color, side_col := Color(0, 0, 0, 0),
		edge_cols := PackedColorArray()) -> void:
	var frame := _begin_frame(t)
	var n := pts2.size()
	var front := PackedVector3Array()
	var back := PackedVector3Array()
	for p in pts2:
		front.append(t * Vector3(p.x, p.y, depth))
	for i in range(n - 1, -1, -1):
		back.append(t * Vector3(pts2[i].x, pts2[i].y, 0.0))
	poly(front, col)
	poly(back, col)
	var sc := side_col if side_col.a > 0.0 else col
	for i in n:
		var j := (i + 1) % n
		var a0 := t * Vector3(pts2[i].x, pts2[i].y, 0.0)
		var b0 := t * Vector3(pts2[j].x, pts2[j].y, 0.0)
		quad(a0, b0, b0 + t.basis.z * depth, a0 + t.basis.z * depth, edge_cols[i] if i < edge_cols.size() else sc)
	_end_frame(frame)


const _ICO_T := 1.618034

static var _ico_verts: PackedVector3Array
static var _ico_faces: PackedInt32Array


static func _ico() -> void:
	if not _ico_verts.is_empty():
		return
	var t := _ICO_T
	var vs := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for v in vs:
		_ico_verts.append((v as Vector3).normalized())
	_ico_faces = PackedInt32Array([0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1])


## Lumpy low-poly blob (jittered icosahedron): leaf clumps, bushes, rocks,
## clouds. radii scales per axis; bumps = radial jitter fraction.
## Returns the smallest radial distance used (for conservative colliders).
func blob(center: Vector3, radii: Vector3, col: Color, bumps := 0.18, col2 := Color(0, 0, 0, 0), flat_bottom := -2.0) -> float:
	_ico()
	var pts := PackedVector3Array()
	var min_k := 10.0
	for v in _ico_verts:
		var k := 1.0 + (rng.randf() - 0.5) * 2.0 * bumps
		min_k = minf(min_k, k)
		var p := v * k
		if p.y < flat_bottom:
			p.y = flat_bottom
		pts.append(center + Vector3(p.x * radii.x, p.y * radii.y, p.z * radii.z))
	last_blob = pts
	var c2 := col2 if col2.a > 0.0 else col
	for f in range(0, _ico_faces.size(), 3):
		var a := pts[_ico_faces[f]]
		var b := pts[_ico_faces[f + 1]]
		var c := pts[_ico_faces[f + 2]]
		# Shade lower facets with the second colour: fake occlusion.
		var fy := (a.y + b.y + c.y) / 3.0 - center.y
		tri(a, b, c, c2 if fy < -radii.y * 0.25 else col)
	# Icosahedron face centres sit at ~0.79 of the vertex radius.
	return min_k * 0.79


# --- walls with openings ------------------------------------------------

## A wall slab with rectangular (optionally arched) openings.
## Panel space: u along +X (0..w), v along +Y (0..h), thickness along Z
## centred on 0; the OUTER face is +Z. t maps panel space into kit space.
## holes: [{"rect": Rect2(u0, v0, du, dv), "arch": bool, "segs": int,
## "round": bool}]; round = arched top AND bottom (a circle in a square
## rect, a lens in a wide one): nest-box and burrow mouths.
## u_splits: extra vertical cuts (board stripes); stripe colours alternate
## between col_out and col_stripe when col_stripe.a > 0.
## edges: which outer boundary sides get end faces (1 left, 2 right, 4 top,
## 8 bottom) — omit the ones buried in neighbouring walls.
## col_edge: colour of the panel's own end faces (default: col_reveal), so
## a burrow can be dark inside while the panel's edges match its face.
func wall(t: Transform3D, w: float, h: float, thick: float, holes: Array, col_out: Color, col_in: Color,
		col_reveal: Color, edges := 15, u_splits := PackedFloat32Array(), col_stripe := Color(0, 0, 0, 0), col_edge := Color(0, 0, 0, 0)) -> void:
	var frame := _begin_frame(t)
	# Walls are cut into many cells; per-facet jitter would show as banding.
	var saved_jitter := jitter
	jitter = 0.0
	var xs := [0.0, w]
	var ys := [0.0, h]
	for hd in holes:
		var r: Rect2 = hd["rect"]
		xs.append(clampf(r.position.x, 0.0, w))
		xs.append(clampf(r.end.x, 0.0, w))
		ys.append(clampf(r.position.y, 0.0, h))
		ys.append(clampf(r.end.y, 0.0, h))
	for s in u_splits:
		if s > 0.0 and s < w:
			xs.append(s)
	xs = _uniq(xs)
	ys = _uniq(ys)
	var nx := xs.size() - 1
	var ny := ys.size() - 1
	var solid := PackedByteArray()
	solid.resize(nx * ny)
	solid.fill(1)
	# Each hole clears exactly the cells between its own edges (the cut
	# lists contain them): index ranges by binary search, not a hole test
	# per cell (walls with dozens of holes have thousands of cells).
	var pxs := PackedFloat32Array(xs)
	var pys := PackedFloat32Array(ys)
	for hd in holes:
		var r: Rect2 = hd["rect"]
		var i0 := pxs.bsearch(clampf(r.position.x, 0.0, w) - 1e-4)
		var i1 := pxs.bsearch(clampf(r.end.x, 0.0, w) - 1e-4)
		var j0 := pys.bsearch(clampf(r.position.y, 0.0, h) - 1e-4)
		var j1 := pys.bsearch(clampf(r.end.y, 0.0, h) - 1e-4)
		for j in range(j0, mini(j1, ny)):
			for i in range(i0, mini(i1, nx)):
				solid[j * nx + i] = 0
	var zo := thick * 0.5
	var zi := -thick * 0.5
	var striped := col_stripe.a > 0.0 and not u_splits.is_empty()
	# Front and back faces: merge runs of solid cells in a row (same stripe).
	for j in ny:
		var i := 0
		while i < nx:
			if solid[j * nx + i] == 0:
				i += 1
				continue
			var i0 := i
			var stripe := _stripe_of(xs[i], u_splits) if striped else 0
			while i + 1 < nx and solid[j * nx + i + 1] == 1 and (not striped or _stripe_of(xs[i + 1], u_splits) == stripe):
				i += 1
			var u0: float = xs[i0]
			var u1: float = xs[i + 1]
			var v0: float = ys[j]
			var v1: float = ys[j + 1]
			var co := col_out if stripe % 2 == 0 else col_stripe
			quad(t * Vector3(u0, v0, zo), t * Vector3(u1, v0, zo), t * Vector3(u1, v1, zo), t * Vector3(u0, v1, zo), co)
			quad(t * Vector3(u1, v0, zi), t * Vector3(u0, v0, zi), t * Vector3(u0, v1, zi), t * Vector3(u1, v1, zi), col_in)
			i += 1
	# Side faces wherever a solid cell meets a hole or the panel edge.
	for j in ny:
		for i in nx:
			if solid[j * nx + i] == 0:
				continue
			var u0: float = xs[i]
			var u1: float = xs[i + 1]
			var v0: float = ys[j]
			var v1: float = ys[j + 1]
			var left_open := (i == 0 and edges & 1) or (i > 0 and solid[j * nx + i - 1] == 0)
			var right_open := (i == nx - 1 and edges & 2) or (i < nx - 1 and solid[j * nx + i + 1] == 0)
			var top_open := (j == ny - 1 and edges & 4) or (j < ny - 1 and solid[(j + 1) * nx + i] == 0)
			var bot_open := (j == 0 and edges & 8) or (j > 0 and solid[(j - 1) * nx + i] == 0)
			var ce := col_edge if col_edge.a > 0.0 else col_reveal
			if left_open:
				quad(t * Vector3(u0, v0, zi), t * Vector3(u0, v0, zo), t * Vector3(u0, v1, zo), t * Vector3(u0, v1, zi), ce if i == 0 else col_reveal)
			if right_open:
				quad(t * Vector3(u1, v0, zo), t * Vector3(u1, v0, zi), t * Vector3(u1, v1, zi), t * Vector3(u1, v1, zo), ce if i == nx - 1 else col_reveal)
			if top_open:
				quad(t * Vector3(u0, v1, zo), t * Vector3(u1, v1, zo), t * Vector3(u1, v1, zi), t * Vector3(u0, v1, zi), ce if j == ny - 1 else col_reveal)
			if bot_open:
				quad(t * Vector3(u0, v0, zi), t * Vector3(u1, v0, zi), t * Vector3(u1, v0, zo), t * Vector3(u0, v0, zo), ce if j == 0 else col_reveal)
	# Arched tops: fill the two upper corners of the hole with spandrels.
	# "rise" < half width gives a flatter segmental arch (bridges).
	for hd in holes:
		var round: bool = hd.get("round", false)
		if not hd.get("arch", false) and not round:
			continue
		var r: Rect2 = hd["rect"]
		var segs: int = hd.get("segs", 6)
		var half := r.size.x * 0.5
		var rise: float = minf(hd.get("rise", half), half)
		if round:
			rise = minf(half, r.size.y * 0.5)
		var rad := (half * half + rise * rise) / (2.0 * rise)
		var phi_max := asin(clampf(half / rad, -1.0, 1.0))
		var cx := r.position.x + half
		var top := r.end.y
		var yc := top - rad
		for k in segs:
			var ph0 := phi_max - 2.0 * phi_max * float(k) / float(segs)
			var ph1 := phi_max - 2.0 * phi_max * float(k + 1) / float(segs)
			# p0 is right of p1 (the arc runs right to left).
			var p0 := Vector2(cx + rad * sin(ph0), yc + rad * cos(ph0))
			var p1 := Vector2(cx + rad * sin(ph1), yc + rad * cos(ph1))
			var q0 := Vector2(p0.x, top)
			var q1 := Vector2(p1.x, top)
			quad(t * Vector3(p1.x, p1.y, zo), t * Vector3(p0.x, p0.y, zo), t * Vector3(q0.x, q0.y, zo), t * Vector3(q1.x, q1.y, zo), col_out)
			quad(t * Vector3(p0.x, p0.y, zi), t * Vector3(p1.x, p1.y, zi), t * Vector3(q1.x, q1.y, zi), t * Vector3(q0.x, q0.y, zi), col_in)
			# Intrados (the arch's underside), facing into the opening.
			quad(t * Vector3(p0.x, p0.y, zo), t * Vector3(p1.x, p1.y, zo), t * Vector3(p1.x, p1.y, zi), t * Vector3(p0.x, p0.y, zi), col_reveal)
			if round:
				# The mirror image at the bottom (winding mirrored too).
				var bot := r.position.y
				var b0 := Vector2(p0.x, bot + (top - p0.y))
				var b1 := Vector2(p1.x, bot + (top - p1.y))
				var c0 := Vector2(b0.x, bot)
				var c1 := Vector2(b1.x, bot)
				quad(t * Vector3(c1.x, c1.y, zo), t * Vector3(c0.x, c0.y, zo), t * Vector3(b0.x, b0.y, zo), t * Vector3(b1.x, b1.y, zo), col_out)
				quad(t * Vector3(c0.x, c0.y, zi), t * Vector3(c1.x, c1.y, zi), t * Vector3(b1.x, b1.y, zi), t * Vector3(b0.x, b0.y, zi), col_in)
				quad(t * Vector3(b1.x, b1.y, zo), t * Vector3(b0.x, b0.y, zo), t * Vector3(b0.x, b0.y, zi), t * Vector3(b1.x, b1.y, zi), col_reveal)
	jitter = saved_jitter
	_end_frame(frame)


static func _uniq(a: Array) -> Array:
	a.sort()
	var out := []
	for v in a:
		if out.is_empty() or absf(float(v) - float(out[-1])) > 1e-4:
			out.append(v)
	return out


static func _stripe_of(u: float, splits: PackedFloat32Array) -> int:
	var k := 0
	for s in splits:
		if u >= s - 1e-4:
			k += 1
	return k


# --- primitive colliders -----------------------------------------------

## Capsule collider from a to b (kit space). For thin things the visual is
## a tube built with collide = false.
func add_capsule(a: Vector3, b: Vector3, r: float) -> void:
	var A := xf * a
	var B := xf * b
	var d := B - A
	var l := d.length()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = l + 2.0 * r
	# CapsuleShape3D runs along local Y: build a right-handed basis around d.
	var yv := d / l if l > 1e-6 else Vector3.UP
	var ref := Vector3.RIGHT if absf(yv.x) < 0.9 else Vector3.FORWARD
	var xv := yv.cross(ref).normalized()
	var zv := xv.cross(yv)
	shapes.append([cap, Transform3D(Basis(xv, yv, zv), (A + B) * 0.5)])


## A thin tube that collides as a chain of capsules (wires, twigs, poles).
func rod(a: Vector3, b: Vector3, r_vis: float, r_col: float, sides: int, col: Color, caps := true) -> void:
	var was := collide
	collide = false
	cyl(a, b, r_vis, r_vis, sides, col, caps, caps)
	collide = was
	add_capsule(a, b, r_col)


# --- output ------------------------------------------------------------

func to_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Creates the MeshInstance3D (one draw call) and a StaticBody3D holding the
## trimesh + primitive colliders. Returns {"mesh": MeshInstance3D, "body": StaticBody3D}.
func commit(visual_parent: Node3D, body_parent: Node3D, material: Material, layers := 1, shadows := true, recenter := false) -> Dictionary:
	var out := {}
	if not verts.is_empty():
		var mi := MeshInstance3D.new()
		mi.name = name
		if recenter:
			# Node origin = AABB centre (visibility ranges measure from it).
			var box := AABB(verts[0], Vector3.ZERO)
			for v in verts:
				box = box.expand(v)
			var c := box.get_center()
			var shifted := PackedVector3Array()
			shifted.resize(verts.size())
			for i in verts.size():
				shifted[i] = verts[i] - c
			var saved := verts
			verts = shifted
			mi.mesh = to_mesh()
			verts = saved
			mi.position = c
		else:
			mi.mesh = to_mesh()
		mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual_parent.add_child(mi)
		out["mesh"] = mi
	if not faces.is_empty() or not shapes.is_empty():
		var body := StaticBody3D.new()
		body.name = name + "_body"
		body.collision_layer = layers
		body.collision_mask = 0
		if not faces.is_empty():
			var sh := ConcavePolygonShape3D.new()
			sh.set_faces(faces)
			var o := body.create_shape_owner(body)
			body.shape_owner_add_shape(o, sh)
		for s in shapes:
			var o := body.create_shape_owner(body)
			body.shape_owner_add_shape(o, s[0])
			body.shape_owner_set_transform(o, s[1])
		# Enter the tree last: a body already in the physics space rebuilds
		# its compound shape on every added shape (quadratic in shapes).
		body_parent.add_child(body)
		out["body"] = body
		if out.has("mesh"):
			(out["mesh"] as Node).set_meta(&"collider", body)
	return out
