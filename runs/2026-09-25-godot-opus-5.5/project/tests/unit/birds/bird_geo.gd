extends RefCounted
## Geometry helpers for the birds suite: mesh arrays, CPU posing (BirdPose,
## the shader's maths), silhouettes, colour views and triangle intersection.
## Preload: const Geo := preload("res://tests/unit/birds/bird_geo.gd").

const VIEW_UV := {"top": [0, 2], "bottom": [0, 2], "side": [2, 1], "front": [0, 1]}


static func arrays(species: StringName, lod: int = 0) -> Array:
	return BirdModels.mesh(species, lod).surface_get_arrays(0)


static func posed(arr: Array, inst: Vector4, body_frame: bool = false) -> PackedVector3Array:
	return BirdPose.pose_arrays(arr, inst, 0.0, 0.0, body_frame)


static var _rigs := {}


## A species/LOD mesh unpacked once for fast partial posing:
## {arr, v, n, c0, c1, c2, c3, uv, wing_idx, outer_idx, wing_tail_idx}.
static func rig(sp: StringName, lod: int = 0) -> Dictionary:
	var key := "%s:%d" % [sp, lod]
	if _rigs.has(key):
		return _rigs[key]
	var arr := arrays(sp, lod)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var c: Array = []
	for a in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
		var f: PackedFloat32Array = arr[a]
		var out: Array[Vector4] = []
		for i in v.size():
			out.append(Vector4(f[i * 4], f[i * 4 + 1], f[i * 4 + 2], f[i * 4 + 3]))
		c.append(out)
	var g := groups(arr)
	var wing_idx := PackedInt32Array()
	var outer_idx := PackedInt32Array()
	var wt_idx := PackedInt32Array()
	for i in v.size():
		if is_wing(g[i]):
			wing_idx.append(i)
			wt_idx.append(i)
			var sx: float = c[1][i].x
			var wx: float = c[2][i].x
			# Outer wing: the hand, and the arm beyond 60% of the way to the
			# wrist (the root is attached to the body and may sit in it).
			if g[i] == BirdPose.G_HAND or absf(v[i].x) > sx + 0.6 * (wx - sx) + 1e-4:
				outer_idx.append(i)
		elif g[i] == BirdPose.G_TAIL:
			wt_idx.append(i)
	var r := {"arr": arr, "v": v, "n": arr[Mesh.ARRAY_NORMAL], "c0": c[0], "c1": c[1], "c2": c[2], "c3": c[3],
		"uv": arr[Mesh.ARRAY_TEX_UV], "uv2": BirdPose.uv2_of(arr), "wing_idx": wing_idx, "outer_idx": outer_idx,
		"wing_tail_idx": wt_idx}
	_rigs[key] = r
	return r


## Poses only the vertices in `idx` (the rest keep their rest position).
static func posed_subset(r: Dictionary, inst: Vector4, idx: PackedInt32Array, body_frame: bool = false) -> PackedVector3Array:
	var out: PackedVector3Array = (r["v"] as PackedVector3Array).duplicate()
	var v: PackedVector3Array = r["v"]
	var n: PackedVector3Array = r["n"]
	var c0: Array[Vector4] = r["c0"]
	var c1: Array[Vector4] = r["c1"]
	var c2: Array[Vector4] = r["c2"]
	var c3: Array[Vector4] = r["c3"]
	var uv: PackedVector2Array = r["uv"]
	var uv2: PackedVector2Array = r["uv2"]
	for i in idx:
		out[i] = BirdPose.pose(v[i], n[i], c0[i], c1[i], c2[i], c3[i], inst, 0.0, 0.0, body_frame, uv[i], uv2[i])[0]
	return out


static func groups(arr: Array) -> PackedInt32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedInt32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = int(roundf(c0[i * 4]))
	return out


static func sides(arr: Array) -> PackedFloat32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedFloat32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = c0[i * 4 + 1]
	return out


static func is_wing(g: int) -> bool:
	return g == BirdPose.G_ARM or g == BirdPose.G_HAND


## Binary silhouette (res x res) of the triangles projected orthographically
## for a view ("top": x/z, "side": z/y, "front": x/y), covering [-half, half].
static func silhouette(v: PackedVector3Array, view: String, res: int = 160, half: float = 0.62) -> PackedByteArray:
	var img := PackedByteArray()
	img.resize(res * res)
	var ax: Array = VIEW_UV[view]
	var ia: int = ax[0]
	var ib: int = ax[1]
	var k := res / (2.0 * half)
	for t in range(0, v.size(), 3):
		var a := Vector2((v[t][ia] + half) * k, (v[t][ib] + half) * k)
		var b := Vector2((v[t + 1][ia] + half) * k, (v[t + 1][ib] + half) * k)
		var c := Vector2((v[t + 2][ia] + half) * k, (v[t + 2][ib] + half) * k)
		_fill(img, res, a, b, c)
	return img


static func _fill(img: PackedByteArray, res: int, a: Vector2, b: Vector2, c: Vector2) -> void:
	var area := (b - a).cross(c - a)
	if absf(area) < 1e-9:
		return
	var x0 := maxi(0, int(floor(minf(a.x, minf(b.x, c.x)))))
	var x1 := mini(res - 1, int(ceil(maxf(a.x, maxf(b.x, c.x)))))
	var y0 := maxi(0, int(floor(minf(a.y, minf(b.y, c.y)))))
	var y1 := mini(res - 1, int(ceil(maxf(a.y, maxf(b.y, c.y)))))
	var sgn := 1.0 if area > 0.0 else -1.0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			if (b - a).cross(p - a) * sgn >= 0.0 and (c - b).cross(p - b) * sgn >= 0.0 and (a - c).cross(p - c) * sgn >= 0.0:
				img[y * res + x] = 1


static func iou(a: PackedByteArray, b: PackedByteArray) -> float:
	var inter := 0
	var uni := 0
	for i in a.size():
		var x := a[i]
		var y := b[i]
		if x != 0 and y != 0:
			inter += 1
		if x != 0 or y != 0:
			uni += 1
	return float(inter) / maxf(uni, 1.0)


static func area(a: PackedByteArray) -> int:
	var n := 0
	for x in a:
		n += x
	return n


## Mean visible colour (linear) of a view, with a depth buffer: "top" sees
## the highest face, "bottom" the lowest, "side" the one nearest -X.
static func view_color(v: PackedVector3Array, cols: PackedColorArray, view: String, res: int = 96, half: float = 0.62) -> Color:
	var depth := PackedFloat32Array()
	depth.resize(res * res)
	depth.fill(-INF)
	var colr := PackedColorArray()
	colr.resize(res * res)
	var ax: Array = VIEW_UV[view]
	var ia: int = ax[0]
	var ib: int = ax[1]
	var k := res / (2.0 * half)
	for t in range(0, v.size(), 3):
		var pts := [v[t], v[t + 1], v[t + 2]]
		var d := 0.0
		for p in pts:
			var pv: Vector3 = p
			match view:
				"top":
					d += pv.y
				"bottom":
					d -= pv.y
				"side":
					d -= pv.x
				"front":
					d -= pv.z
		d /= 3.0
		var a := Vector2((pts[0][ia] + half) * k, (pts[0][ib] + half) * k)
		var b := Vector2((pts[1][ia] + half) * k, (pts[1][ib] + half) * k)
		var c := Vector2((pts[2][ia] + half) * k, (pts[2][ib] + half) * k)
		var ar := (b - a).cross(c - a)
		if absf(ar) < 1e-9:
			continue
		var sgn := 1.0 if ar > 0.0 else -1.0
		var x0 := maxi(0, int(floor(minf(a.x, minf(b.x, c.x)))))
		var x1 := mini(res - 1, int(ceil(maxf(a.x, maxf(b.x, c.x)))))
		var y0 := maxi(0, int(floor(minf(a.y, minf(b.y, c.y)))))
		var y1 := mini(res - 1, int(ceil(maxf(a.y, maxf(b.y, c.y)))))
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var p := Vector2(x + 0.5, y + 0.5)
				if (b - a).cross(p - a) * sgn >= 0.0 and (c - b).cross(p - b) * sgn >= 0.0 and (a - c).cross(p - c) * sgn >= 0.0:
					var i := y * res + x
					if d > depth[i]:
						depth[i] = d
						# Mesh colours are sRGB; average in linear light.
						colr[i] = cols[t].srgb_to_linear()
	var sum := Color(0, 0, 0, 0)
	var n := 0
	for i in depth.size():
		if depth[i] > -INF:
			sum += colr[i]
			n += 1
	return sum / maxf(n, 1)


## Oklab of a linear colour.
static func oklab(c: Color) -> Vector3:
	var l := 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
	var m := 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
	var s := 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
	l = pow(maxf(l, 0.0), 1.0 / 3.0)
	m = pow(maxf(m, 0.0), 1.0 / 3.0)
	s = pow(maxf(s, 0.0), 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


## True when two triangles cross: an edge of one passes through the other's
## interior. Touching (a shared edge line, a T-junction, a vertex resting on
## a face) is not crossing: those are seams, not interpenetration.
static func tris_intersect(a0: Vector3, a1: Vector3, a2: Vector3, b0: Vector3, b1: Vector3, b2: Vector3) -> bool:
	for e in [[a0, a1], [a1, a2], [a2, a0]]:
		if _pierces(e[0], e[1], b0, b1, b2):
			return true
	for e in [[b0, b1], [b1, b2], [b2, b0]]:
		if _pierces(e[0], e[1], a0, a1, a2):
			return true
	return false


static func _pierces(p: Vector3, q: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var hit: Variant = Geometry3D.segment_intersects_triangle(p, q, a, b, c)
	if hit == null:
		return false
	var h: Vector3 = hit
	var len := p.distance_to(q)
	var eps := 1e-4 * maxf(len, 1e-6) + 2e-6
	if h.distance_to(p) < eps or h.distance_to(q) < eps:
		return false
	# Barycentric: strictly inside the triangle, not on its rim.
	var v0 := b - a
	var v1 := c - a
	var v2 := h - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-20:
		return false
	var bv := (d11 * d20 - d01 * d21) / den
	var bw := (d00 * d21 - d01 * d20) / den
	var bu := 1.0 - bv - bw
	var m := 1e-3
	return bu > m and bv > m and bw > m


## Triangle indices of a wing side (+1 / -1) at LOD `arr`.
static func wing_tris(arr: Array, side: float) -> PackedInt32Array:
	var g := groups(arr)
	var sd := sides(arr)
	var out := PackedInt32Array()
	for t in range(0, g.size(), 3):
		if is_wing(g[t]) and sd[t] == side:
			out.append(t)
	return out


## Triangle indices of the tail.
static func tail_tris(arr: Array) -> PackedInt32Array:
	var g := groups(arr)
	var out := PackedInt32Array()
	for t in range(0, g.size(), 3):
		if g[t] == BirdPose.G_TAIL:
			out.append(t)
	return out


## Pairs of intersecting triangles among the given triangle start indices of
## `v` (posed). Triangles that share a rest vertex position are neighbours
## and skipped. Returns the number of crossing pairs (stops at `limit`).
static func count_crossings(v: PackedVector3Array, rest: PackedVector3Array, ta: PackedInt32Array, tb: PackedInt32Array, same_set: bool, limit: int = 1) -> int:
	var boxes_a: Array[AABB] = []
	var boxes_b: Array[AABB] = []
	var all_b := AABB()
	for t in tb:
		var bb := _box(v, t)
		all_b = bb if boxes_b.is_empty() else all_b.merge(bb)
		boxes_b.append(bb)
	for t in ta:
		boxes_a.append(_box(v, t))
	var n := 0
	for i in ta.size():
		# Most of set a is nowhere near set b (a wing against the tail).
		if not boxes_a[i].intersects(all_b):
			continue
		var j0 := i + 1 if same_set else 0
		for j in range(j0, tb.size()):
			if not boxes_a[i].intersects(boxes_b[j]):
				continue
			var t1 := ta[i]
			var t2 := tb[j]
			if _share(rest, t1, t2):
				continue
			if tris_intersect(v[t1], v[t1 + 1], v[t1 + 2], v[t2], v[t2 + 1], v[t2 + 2]):
				n += 1
				if n >= limit:
					return n
	return n


static func _box(v: PackedVector3Array, t: int) -> AABB:
	var b := AABB(v[t], Vector3.ZERO)
	b = b.expand(v[t + 1])
	b = b.expand(v[t + 2])
	return b.grow(1e-5)


static func _share(rest: PackedVector3Array, t1: int, t2: int) -> bool:
	for i in 3:
		for j in 3:
			if rest[t1 + i].distance_squared_to(rest[t2 + j]) < 1e-12:
				return true
	return false


## The poses every animation test sweeps: (phase, amount, fold, perch).
static func pose_set() -> Array[Vector4]:
	var out: Array[Vector4] = []
	for i in 20:
		out.append(Vector4(i / 20.0, 1.0, 0.0, 0.0))
	for i in 5:
		out.append(Vector4(i / 5.0 + 0.05, 0.5, 0.0, 0.0))
	for f in [0.25, 0.5, 0.75, 1.0]:
		out.append(Vector4(0.25, 0.0, f, 0.0))
	for f in [0.5, 1.0]:
		out.append(Vector4(0.6, 1.0, f, 0.0))
	for q in [0.25, 0.5, 0.75, 1.0]:
		out.append(Vector4(0.25, 0.0, 1.0, q))
	out.append(Vector4(0.25, 0.0, 0.5, 0.5))
	return out


## How close the outer wing comes to the inside of the body in a pose
## (inst), as the smallest ellipse value over outer wing vertices (hand, and
## arm beyond 60% of the way to the wrist): 1 = on the body's surface, below
## 1 = inside it. The wing root is attached to the body and may sit in it.
static func body_clearance(sp: StringName, _arr: Array, inst: Vector4) -> float:
	var r := rig(sp, 0)
	var idx: PackedInt32Array = r["outer_idx"]
	var v := posed_subset(r, inst, idx, true)
	var worst := INF
	for i in idx:
		var sec := body_section_fast(sp, v[i].z)
		if sec == Vector3.ZERO:
			continue
		worst = minf(worst, pow(v[i].x / sec.x, 2.0) + pow((v[i].y - sec.z) / sec.y, 2.0))
	return worst


static var _sections := {}
const SECTION_STEPS := 512


## BirdMeshBuilder.body_section from a cached table (linear between 512
## samples along the body: within 1e-5 of the exact value), so sweeping a
## few hundred poses stays fast.
static func body_section_fast(sp: StringName, z: float) -> Vector3:
	var tab: Array = _sections.get(sp, [])
	if tab.is_empty():
		var b := BirdModels.body_aabb(sp)
		var z0 := b.position.z - 0.01
		var z1 := b.end.z + 0.01
		var pts := PackedVector3Array()
		for i in SECTION_STEPS + 1:
			pts.append(BirdMeshBuilder.body_section(sp, lerpf(z0, z1, float(i) / SECTION_STEPS)))
		tab = [z0, z1, pts]
		_sections[sp] = tab
	var z0: float = tab[0]
	var z1: float = tab[1]
	if z < z0 or z > z1:
		return Vector3.ZERO
	var pts: PackedVector3Array = tab[2]
	var u := (z - z0) / (z1 - z0) * SECTION_STEPS
	var i := mini(int(u), SECTION_STEPS - 1)
	var a := pts[i]
	var b2 := pts[i + 1]
	if a == Vector3.ZERO or b2 == Vector3.ZERO:
		# At the ends of the body: exact.
		return BirdMeshBuilder.body_section(sp, z)
	return a.lerp(b2, u - i)


## Wing and tail triangles turned against their own normal in a pose (a
## face squeezed to zero area is invisible, not inverted).
static func inverted_count(arr: Array, inst: Vector4) -> int:
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var g := groups(arr)
	var res := BirdPose.pose_arrays_with_normals(arr, inst)
	var v: PackedVector3Array = res[0]
	var nn: PackedVector3Array = res[1]
	var bad := 0
	for t in range(0, v.size(), 3):
		if not is_wing(g[t]) and g[t] != BirdPose.G_TAIL:
			continue
		var cr := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
		var cr0 := (rest[t + 1] - rest[t]).cross(rest[t + 2] - rest[t])
		var nsum := nn[t] + nn[t + 1] + nn[t + 2]
		if cr.dot(nsum) > 1e-4 * cr0.length() * nsum.length():
			bad += 1
	return bad
