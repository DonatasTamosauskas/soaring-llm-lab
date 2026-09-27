class_name BirdMeshBuilder
extends RefCounted
## Builds one species' low-poly mesh at one level of detail from the data in
## BirdSpecies: flat-shaded (every triangle has its own vertices and face
## normal), coloured per face with vertex colours, and rig-tagged per vertex
## so the shared vertex shader can flap, fold, tuck and perch it (the tag
## layout is documented in BirdPose).
##
## Conventions (docs/ARCHITECTURE.md, birds): wingspan exactly 1.0 (the
## glide pose is the rest mesh, so the rest mesh's X extent is the span),
## beak towards -Z, origin at the body centre (centre of the body loft's
## bounds). A perched bird's feet reach y = -FOOT_DEPTH, i.e. one
## SizeRules body radius (0.16 x span) below the body centre, which is where
## the perch grip point is (scripts/world/perch.gd).

const FOOT_DEPTH := 0.16

## Per-LOD detail. LOD0 is the close-up model (<= 300 triangles for small
## birds), LOD1 about half, LOD2 a flapping silhouette for far away.
const LODS := [
	{"body_sides": 8, "body_t": [0.0, 0.14, 0.38, 0.64, 0.86], "head_rings": [[0.95, 0.52, 0.0], [0.42, 0.97, 0.0], [-0.28, 0.9, -0.03], [-0.8, 0.52, -0.1]],
		"head_sides": 6, "wing_stations": "all", "fingers": "all", "bands": true, "legs": 2, "eyes": true, "beak_mid": true},
	{"body_sides": 6, "body_t": [0.0, 0.3, 0.7], "head_rings": [[0.85, 0.62, 0.0], [0.05, 1.0, 0.0], [-0.8, 0.52, -0.1]],
		"head_sides": 6, "wing_stations": "mid", "fingers": 3, "bands": false, "legs": 1, "eyes": false, "beak_mid": false},
	{"body_sides": 4, "body_t": [0.0, 0.45], "head_rings": [[0.6, 0.85, 0.0], [-0.8, 0.52, -0.1]],
		"head_sides": 4, "wing_stations": "low", "fingers": 0, "bands": false, "legs": 0, "eyes": false, "beak_mid": false},
]

## Body profile along its length (t = 0 neck .. 1 vent): half-width and
## half-height as fractions of W/2, H/2, and the centre-line height (x H).
## A bird's body ends in a blunt rump (a short horizontal edge the tail
## comes out from) at least 0.3 x W wide and as wide as the tail's base
## (_rump_w), not in a point: the folded wings converge onto it, and from
## above the tail no longer sticks out from under a pointed vent.
const PROF_T := [0.0, 0.14, 0.38, 0.64, 0.86, 1.0]
const PROF_W := [0.58, 0.93, 1.0, 0.86, 0.56, 0.3]
const PROF_H := [0.62, 0.96, 1.0, 0.84, 0.54, 0.12]
const PROF_Y := [0.16, 0.05, 0.0, -0.01, 0.04, 0.1]
const MOTH_PROF_W := [0.7, 0.95, 0.9, 0.88, 0.62, 0.15]
const MOTH_PROF_H := [0.72, 0.95, 0.9, 0.88, 0.62, 0.15]

## Wing thickness: height of the upper-surface ridge (x chord). Large birds
## (600-triangle budget) carry it on along the hand too, and their slotted
## primaries have a raised spine, so a wing seen edge-on (head-on, or in
## profile) still shows as a continuous thin line out to the fingertips.
const ARM_THICK := 0.07
const HAND_THICK := 0.045
const RIDGE_U := 0.25
## Finger spine height at the root (x the finger's width).
const FINGER_SPINE := 0.4

var species: StringName
var lod := 0
var spec: Dictionary
var cfg: Dictionary

# Output (authoring units until _normalize()).
var verts := PackedVector3Array()
var norms := PackedVector3Array()
var cols := PackedColorArray()
var cu0 := PackedFloat32Array()
var cu1 := PackedFloat32Array()
var cu2 := PackedFloat32Array()
var cu3 := PackedFloat32Array()
var uvs := PackedVector2Array()
## Fold hug per vertex (BirdPose UV2), set by _fold_hug.
var uv2s := PackedVector2Array()

# Current part: default group, side, pivots and params.
var _group := 0
var _side := 0.0
var _pa := Vector3.ZERO
var _pa_w := 0.0
var _pb := Vector3.ZERO
var _pb_w := 1.0
var _c3 := Vector4(1, 1, 1, 0)
var _uv := Vector2.ZERO

# Frame (authoring units).
var _L := 0.3
var _W := 0.1
var _H := 0.1
var _body_min := Vector3(INF, INF, INF)
var _body_max := Vector3(-INF, -INF, -INF)
var _in_body := false
## The wingtip vertex record (right side): [pos, normal, c0, c1, c2, c3].
var tip_record: Array = []


## Builds the mesh arrays. `norm` = {"scale", "centre"} from LOD0 so every LOD
## lines up exactly; empty for LOD0 (computed here). Returns
## {"arrays", "norm", "tris", "tip", "body_aabb"}.
static func build(p_species: StringName, p_lod: int, norm: Dictionary = {}) -> Dictionary:
	var b := BirdMeshBuilder.new()
	b.species = p_species
	b.lod = clampi(p_lod, 0, LODS.size() - 1)
	b.spec = BirdSpecies.data(p_species)
	b.cfg = LODS[b.lod]
	return b._build(norm)


## The body loft's cross-section at model-space z (span 1.0 units):
## Vector3(half width, half height, centre y); ZERO outside the body. The
## loft's vertices lie on this ellipse and its faces inside it.
static func body_section(p_species: StringName, z: float) -> Vector3:
	var b := BirdMeshBuilder.new()
	b.species = p_species
	b.spec = BirdSpecies.data(p_species)
	var body: Array = b.spec["body"]
	b._L = body[0]
	b._W = body[1]
	b._H = body[2]
	BirdModels.mesh(p_species, 0)
	var norm := BirdModels.normalisation(p_species)
	var s: float = norm["scale"]
	var c: Vector3 = norm["centre"]
	var za := z / s + c.z
	var t := (za + b._L * 0.5) / b._L
	if t < 0.0 or t > 1.0:
		return Vector3.ZERO
	return Vector3(b.body_hw(t) * s, b.body_hh(t) * s, (b.body_yc(t) - c.y) * s)


func _build(norm: Dictionary) -> Dictionary:
	var body: Array = spec["body"]
	_L = body[0]
	_W = body[1]
	_H = body[2]
	var anim: Array = spec["anim"]
	_c3 = Vector4(anim[0], anim[1], anim[2], deg_to_rad(anim[3]))
	if lod > 0:
		_match_lod0_extents()
	_build_body()
	_build_head()
	if spec["kind"] == "moth":
		_build_moth_wings()
	else:
		_build_wings()
	_build_tail()
	var n := norm
	if n.is_empty():
		var tip_x := 0.0
		for v in verts:
			tip_x = maxf(tip_x, v.x)
		n = {"scale": 0.5 / tip_x, "centre": (_body_min + _body_max) * 0.5}
		n["centre"].x = 0.0
	_normalize(n["scale"], n["centre"])
	_build_legs()
	if spec["kind"] != "moth":
		if not n.has("hug"):
			n["hug"] = _fold_hug_table()
		_apply_fold_hug(n["hug"])
	# Every vertex carries the species' readable angle (from LOD0's body, so
	# all LODs agree) in COLOR.a: the shader tints a highlighted bird fully
	# below it and not at all from bird.gdshader's tint_end x it.
	if not n.has("readable"):
		n["readable"] = BirdModels.readable_angle_for_body((_body_max - _body_min))
	var ca := float(n["readable"]) / BirdModels.READABLE_MAX
	for i in cols.size():
		cols[i].a = ca
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_CUSTOM0] = cu0
	arrays[Mesh.ARRAY_CUSTOM1] = cu1
	arrays[Mesh.ARRAY_CUSTOM2] = cu2
	arrays[Mesh.ARRAY_CUSTOM3] = cu3
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	return {"arrays": arrays, "norm": n, "tris": verts.size() / 3, "tip": tip_record,
		"body_aabb": AABB(_body_min, _body_max - _body_min)}


# --- Emission -------------------------------------------------------------

func _part(group: int, side: float, pa := Vector3.ZERO, pa_w := 0.0, pb := Vector3.ZERO, pb_w := 1.0) -> void:
	_group = group
	_side = side
	_pa = pa
	_pa_w = pa_w
	_pb = pb
	_pb_w = pb_w


## One flat triangle facing `out` (a rough outward direction). meta = per-
## vertex [group, weight, chord_te] x 3, or empty for the part defaults.
func _tri(a: Vector3, b: Vector3, c: Vector3, col: Color, out: Vector3, meta: PackedFloat32Array = PackedFloat32Array()) -> void:
	var cr := (b - a).cross(c - a)
	if cr.length_squared() < 1e-14:
		return
	var ma := 0
	var mb := 3
	var mc := 6
	# Godot draws clockwise-from-the-viewer triangles as front faces, i.e.
	# cross(b - a, c - a) must point away from the outside.
	if cr.dot(out) > 0.0:
		var t := b
		b = c
		c = t
		mb = 6
		mc = 3
		cr = -cr
	var nrm := -cr.normalized()
	# Vertex colours are stored as sRGB bytes (8-bit linear would crush
	# the dark plumage); the shader converts to linear.
	_vert(a, nrm, col, meta, ma)
	_vert(b, nrm, col, meta, mb)
	_vert(c, nrm, col, meta, mc)


func _vert(p: Vector3, nrm: Vector3, col: Color, meta: PackedFloat32Array, k: int) -> void:
	verts.append(p)
	norms.append(nrm)
	cols.append(col)
	var g := float(_group)
	var w := 0.0
	var cte := 0.0
	if meta.size() >= k + 3:
		g = meta[k]
		w = meta[k + 1]
		cte = meta[k + 2]
	cu0.append_array([g, _side, w, cte])
	cu1.append_array([_pa.x, _pa.y, _pa.z, _pa_w])
	cu2.append_array([_pb.x, _pb.y, _pb.z, _pb_w])
	cu3.append_array([_c3.x, _c3.y, _c3.z, _c3.w])
	uvs.append(_uv)
	uv2s.append(Vector2.ZERO)
	if _in_body:
		_body_min = _body_min.min(p)
		_body_max = _body_max.max(p)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, out: Vector3, meta: PackedFloat32Array = PackedFloat32Array()) -> void:
	# meta for a quad: 4 vertices x [group, weight, chord_te].
	if meta.is_empty():
		_tri(a, b, c, col, out)
		_tri(a, c, d, col, out)
	else:
		var m1 := PackedFloat32Array()
		m1.append_array(meta.slice(0, 3))
		m1.append_array(meta.slice(3, 6))
		m1.append_array(meta.slice(6, 9))
		var m2 := PackedFloat32Array()
		m2.append_array(meta.slice(0, 3))
		m2.append_array(meta.slice(6, 9))
		m2.append_array(meta.slice(9, 12))
		_tri(a, b, c, col, out, m1)
		_tri(a, c, d, col, out, m2)


func _col(slot: String) -> Color:
	return BirdSpecies.color(species, slot)


func _normalize(scale: float, centre: Vector3) -> void:
	_scale = scale
	_centre = centre
	for i in verts.size():
		verts[i] = (verts[i] - centre) * scale
	for i in verts.size():
		var j := i * 4
		# Pivots are positions (right-wing coordinates for wings); chord_te
		# is a length.
		cu1[j] = (cu1[j] - centre.x) * scale
		cu1[j + 1] = (cu1[j + 1] - centre.y) * scale
		cu1[j + 2] = (cu1[j + 2] - centre.z) * scale
		cu2[j] = (cu2[j] - centre.x) * scale
		cu2[j + 1] = (cu2[j + 1] - centre.y) * scale
		cu2[j + 2] = (cu2[j + 2] - centre.z) * scale
		cu0[j + 3] *= scale  # fold gather (a length)
	if not tip_record.is_empty():
		var p: Vector3 = tip_record[0]
		tip_record[0] = (p - centre) * scale
		var c0: Vector4 = tip_record[2]
		c0.w *= scale
		tip_record[2] = c0
		var c1: Vector4 = tip_record[3]
		tip_record[3] = Vector4((c1.x - centre.x) * scale, (c1.y - centre.y) * scale, (c1.z - centre.z) * scale, c1.w)
		var c2: Vector4 = tip_record[4]
		tip_record[4] = Vector4((c2.x - centre.x) * scale, (c2.y - centre.y) * scale, (c2.z - centre.z) * scale, c2.w)
	_body_min = (_body_min - centre) * scale
	_body_max = (_body_max - centre) * scale


# --- Body -----------------------------------------------------------------

static func _interp(ts: Array, vs: Array, t: float) -> float:
	for i in range(1, ts.size()):
		if t <= ts[i]:
			var k: float = (t - ts[i - 1]) / (ts[i] - ts[i - 1])
			return lerpf(vs[i - 1], vs[i], k)
	return vs[vs.size() - 1]


func _plump(t: float) -> float:
	var p: float = spec.get("plump", 1.0)
	return lerpf(p, 1.0, clampf(t / 0.55, 0.0, 1.0))


func body_hw(t: float) -> float:
	if spec["kind"] == "moth":
		return _W * 0.5 * _interp(PROF_T, MOTH_PROF_W, t) * _plump(t)
	var w := _interp(PROF_T, PROF_W, t)
	if t > PROF_T[4]:
		w = lerpf(PROF_W[4], _rump_w(), clampf((t - PROF_T[4]) / (1.0 - PROF_T[4]), 0.0, 1.0))
	return _W * 0.5 * w * _plump(t)


## The rump's half-width (x W/2): 0.9 of the tail base's, at least PROF_W's.
func _rump_w() -> float:
	var td: Array = spec["tail"]
	return maxf(PROF_W[PROF_W.size() - 1], 0.9 * float(td[1]) / _W)


func body_hh(t: float) -> float:
	var prof: Array = MOTH_PROF_H if spec["kind"] == "moth" else PROF_H
	return _H * 0.5 * _interp(PROF_T, prof, t) * _plump(t)


func body_yc(t: float) -> float:
	return _H * _interp(PROF_T, PROF_Y, t)


func body_z(t: float) -> float:
	return -_L * 0.5 + t * _L


func _ring(t: float, sides: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var hw := body_hw(t) * _ring_k.x
	var hh := body_hh(t) * _ring_k.y
	var yc := body_yc(t)
	var z := body_z(t)
	for i in sides:
		# Vertices straddle the top so there is a flat back face (and belly).
		var a := PI * 0.5 + PI / sides + TAU * i / sides
		out.append(Vector3(hw * cos(a), yc + hh * sin(a), z))
	return out


## How far a regular ring of `sides` vertices (placed as _ring places them,
## straddling the top) reaches sideways (x) and up (y), x its radius.
static func _ring_reach(sides: int) -> Vector2:
	var rx := 0.0
	var ry := 0.0
	for i in sides:
		var a := PI * 0.5 + PI / sides + TAU * i / sides
		rx = maxf(rx, absf(cos(a)))
		ry = maxf(ry, absf(sin(a)))
	return Vector2(rx, ry)


## Silhouette areas (from above, from the side) of a loft through rings at
## `ts` with `sides` sides, split into [part that scales with the rings, the
## rump's fixed part], per axis: [Vector2(ring x, rump x), Vector2(ring y, rump y)].
func _loft_areas(ts: Array, sides: int) -> Array:
	var reach := _ring_reach(sides)
	var ax := Vector2.ZERO
	var ay := Vector2.ZERO
	for k in ts.size() - 1:
		var t0: float = ts[k]
		var t1: float = ts[k + 1]
		ax.x += (t1 - t0) * reach.x * (body_hw(t0) + body_hw(t1))
		ay.x += (t1 - t0) * reach.y * (body_hh(t0) + body_hh(t1))
	# Last ring to the rump's edge (full width, no height).
	var tl: float = ts[ts.size() - 1]
	ax.x += (1.0 - tl) * reach.x * body_hw(tl)
	ax.y += (1.0 - tl) * body_hw(1.0)
	ay.x += (1.0 - tl) * reach.y * body_hh(tl)
	return [ax, ay]


## Head silhouette areas (from above, from the side) through its rings.
func _head_areas(rings: Array, sides: int) -> Vector2:
	var reach := _ring_reach(sides)
	var a := Vector2.ZERO
	# From the back apex (u 1.05, a point) through the rings to the front.
	var prev_u := 1.05
	var prev := Vector2.ZERO
	for rr: Array in rings:
		var u: float = rr[0]
		var sc: float = rr[1]
		var cur := Vector2(0.9 * sc * reach.x, sc * reach.y)
		a += absf(prev_u - u) * (prev + cur)
		prev_u = u
		prev = cur
	return a


## Scales this LOD's body rings and head so their silhouettes from above and
## from the side cover the same area as LOD0's.
func _match_lod0_extents() -> void:
	var l0: Dictionary = LODS[0]
	var a0 := _loft_areas(l0["body_t"], l0["body_sides"])
	var a1 := _loft_areas(cfg["body_t"], cfg["body_sides"])
	var x0: Vector2 = a0[0]
	var y0: Vector2 = a0[1]
	var x1: Vector2 = a1[0]
	var y1: Vector2 = a1[1]
	_ring_k = Vector2((x0.x + x0.y - x1.y) / x1.x, (y0.x + y0.y - y1.y) / y1.x)
	var h0 := _head_areas(l0["head_rings"], l0["head_sides"])
	var h1 := _head_areas(cfg["head_rings"], cfg["head_sides"])
	_head_k = Vector2(h0.x / h1.x, h0.y / h1.y)


func _build_body() -> void:
	_part(BirdPose.G_BODY, 0.0)
	_in_body = true
	var sides: int = cfg["body_sides"]
	var ts: Array = cfg["body_t"]
	var rings: Array[PackedVector3Array] = []
	for t in ts:
		rings.append(_ring(t, sides))
	for k in ts.size() - 1:
		var r0 := rings[k]
		var r1 := rings[k + 1]
		var tm: float = (ts[k] + ts[k + 1]) * 0.5
		var axis := Vector3(0, body_yc(tm), body_z(tm))
		for i in sides:
			var j := (i + 1) % sides
			var ang := rad_to_deg(PI * 0.5 + TAU * (i + 0.5) / sides + PI / sides)
			var col := _body_color(tm, _wrap_deg(ang), i, k)
			var c := (r0[i] + r0[j] + r1[i] + r1[j]) * 0.25
			_quad(r0[i], r0[j], r1[j], r1[i], col, c - axis)
	# Neck cap (mostly inside the head) and the rump: a moth's abdomen ends
	# in a point, a bird's body in a short horizontal edge (the rump, where
	# the tail comes out). Each side of the last ring closes onto the end of
	# the edge on its side; the back and belly faces, which cross the
	# midline, become quads onto both ends.
	var front := rings[0]
	for i in range(1, sides - 1):
		_tri(front[0], front[i], front[i + 1], _col("breast"), Vector3.FORWARD)
	var last := rings[rings.size() - 1]
	var tl: float = ts[ts.size() - 1]
	var rump := 0.0 if spec["kind"] == "moth" else body_hw(1.0)
	var end_r := Vector3(rump, body_yc(1.0), body_z(1.0))
	var end_l := Vector3(-rump, body_yc(1.0), body_z(1.0))
	var axis2 := Vector3(0, body_yc(tl), body_z(tl))
	for i in sides:
		var j := (i + 1) % sides
		var ang := rad_to_deg(PI * 0.5 + TAU * (i + 0.5) / sides + PI / sides)
		var col := _body_color((tl + 1.0) * 0.5, _wrap_deg(ang), i, ts.size())
		var a := last[i]
		var b := last[j]
		var ea := end_r if a.x > 0.0 else end_l
		var eb := end_r if b.x > 0.0 else end_l
		var c := (a + b + ea + eb) * 0.25
		var out := c - axis2 + Vector3(0, 0, 0.3 * (c - axis2).length())
		if rump == 0.0 or ea == eb:
			_tri(a, b, ea, col, out)
		else:
			_quad(a, b, eb, ea, col, out)
	_in_body = false
	var pat: Dictionary = spec.get("patterns", {})
	if pat.get("speckle", false) and lod == 0:
		_speckles(rings, ts, sides)


## Small pale spots on the body's faces (starling): a spot triangle sits a
## hair proud of a face, at a golden-ratio scatter so it looks random but
## never changes.
static func _wrap_deg(a: float) -> float:
	return wrapf(a, -180.0, 180.0)


## Face colour on the body from where the face is: t along the body, `ang`
## the face's direction around it (90 = back, -90 = belly, 0/180 = sides).
func _body_color(t: float, ang: float, i: int, k: int) -> Color:
	var up := 90.0 - absf(absf(ang) - 90.0) if ang >= 0.0 else -(90.0 - absf(absf(ang) - 90.0))
	# up: 90 top, 0 side, -90 bottom (left/right folded together).
	var pat: Dictionary = spec.get("patterns", {})
	var slot := "back"
	if spec["kind"] == "moth":
		if up < -30.0:
			slot = "belly"
		elif k % 2 == 1 and t > 0.5:
			slot = "band"
		else:
			slot = "back"
		return _col(slot)
	if up > 50.0:
		slot = "nape" if t < 0.2 else ("rump" if t > 0.74 else "back")
	elif up > 12.0:
		slot = "nape" if t < 0.2 else ("rump" if t > 0.8 else "back")
	elif up > -30.0:
		slot = "breast" if t < 0.22 else "flank"
		if pat.get("neck_sheen", false) and t < 0.2:
			slot = "nape"
	else:
		if t < 0.1:
			slot = "throat"
		elif t < 0.36:
			slot = "breast"
		elif t > 0.82:
			slot = "vent"
		elif pat.get("belly_band", false) and t > 0.42 and t < 0.66:
			slot = "band"
		else:
			slot = "belly"
	# Streaked mantle: dark "braces" down both sides of the back.
	if pat.get("back_streak", false) and up > 12.0 and up <= 50.0 and t > 0.15 and t < 0.75:
		slot = "streak"
	return _col(slot)


## Small pale spots on the body's faces (starling): a spot triangle sits a
## hair proud of a face, at a golden-ratio scatter so it looks random but
## never changes; placed on the right half and mirrored.
func _speckles(rings: Array[PackedVector3Array], ts: Array, sides: int) -> void:
	var col := _col("spot")
	var r := _W * 0.07
	var placed := 0
	var j := 0
	while placed < 9 and j < 60:
		j += 1
		var k := j % (ts.size() - 1)
		var i := int(fposmod(j * 0.618034 * sides + 0.3, float(sides)))
		var ang := PI * 0.5 + TAU * (i + 0.5) / sides + PI / sides
		# Right half only (mirrored below), upper and side faces.
		if cos(ang) < 0.1 or sin(ang) < -0.6:
			continue
		var jn := (i + 1) % sides
		var a: Vector3 = rings[k][i]
		var b: Vector3 = rings[k][jn]
		var c: Vector3 = rings[k + 1][jn]
		var d: Vector3 = rings[k + 1][i]
		var u := 0.25 + 0.5 * fposmod(j * 0.381966, 1.0)
		var v := 0.25 + 0.5 * fposmod(j * 0.7548777, 1.0)
		var p := a.lerp(b, u).lerp(d.lerp(c, u), v)
		var nrm := (b - a).cross(d - a).normalized()
		if nrm.dot(p - Vector3(0, p.y, p.z)) < 0.0 and nrm.x < 0.0:
			nrm = -nrm
		if nrm.x < 0.0:
			nrm = -nrm
		var t1 := (b - a).normalized()
		var t2 := nrm.cross(t1).normalized()
		p += nrm * 0.0015
		var pa := p + t1 * r
		var pb := p - t1 * r * 0.5 + t2 * r * 0.8
		var pc := p - t1 * r * 0.5 - t2 * r * 0.8
		_tri(pa, pb, pc, col, nrm)
		var mx := Vector3(-1, 1, 1)
		_tri(pa * mx, pb * mx, pc * mx, col, nrm * mx)
		placed += 1


# --- Head -----------------------------------------------------------------

func head_centre() -> Vector3:
	var hd: Array = spec["head"]
	var r: float = hd[0]
	return Vector3(0, body_yc(0.0) + float(hd[1]) * _H, body_z(0.0) - float(hd[2]) * r)


func _build_head() -> void:
	var hd: Array = spec["head"]
	var r: float = hd[0]
	var hc := head_centre()
	var neck := Vector3(0, hc.y - r * 0.3, hc.z + r * 0.6)
	_part(BirdPose.G_HEAD, 0.0, neck)
	var sides: int = cfg["head_sides"]
	var rd: Array = cfg["head_rings"]
	var rings: Array[PackedVector3Array] = []
	var us: Array[float] = []
	for rr in rd:
		var u: float = rr[0]
		var sc: float = rr[1]
		var yo: float = rr[2]
		var ring := PackedVector3Array()
		for i in sides:
			var a := PI * 0.5 + PI / sides + TAU * i / sides
			ring.append(hc + Vector3(r * sc * 0.9 * cos(a) * _head_k.x, r * (yo + sc * sin(a) * _head_k.y), r * u))
		rings.append(ring)
		us.append(u)
	# Back of the head: a low apex behind the last ring.
	var back := hc + Vector3(0, r * 0.05, r * 1.05)
	for i in sides:
		var j := (i + 1) % sides
		var ang := rad_to_deg(PI * 0.5 + TAU * (i + 0.5) / sides + PI / sides)
		var c := (rings[0][i] + rings[0][j] + back) / 3.0
		_tri(rings[0][i], rings[0][j], back, _head_color(1.0, _wrap_deg(ang)), c - hc)
	for k in rings.size() - 1:
		var um := (us[k] + us[k + 1]) * 0.5
		for i in sides:
			var j := (i + 1) % sides
			var ang := rad_to_deg(PI * 0.5 + TAU * (i + 0.5) / sides + PI / sides)
			var col := _head_color(um, _wrap_deg(ang))
			var c := (rings[k][i] + rings[k][j] + rings[k + 1][i] + rings[k + 1][j]) * 0.25
			_quad(rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i], col, c - hc)
	var front := rings[rings.size() - 1]
	var fc := Vector3.ZERO
	for p in front:
		fc += p
	fc /= float(sides)
	for i in range(1, sides - 1):
		_tri(front[0], front[i], front[i + 1], _head_color(-1.0, 90.0), Vector3.FORWARD)
	if cfg["eyes"]:
		_build_eyes(hc, r)
	var bk: Array = spec["beak"]
	if float(bk[0]) > 0.0:
		_build_beak(fc, bk)
	if spec["kind"] == "moth":
		_build_antennae(hc, r)


func _head_color(u: float, ang: float) -> Color:
	var up := 90.0 - absf(absf(ang) - 90.0) if ang >= 0.0 else -(90.0 - absf(absf(ang) - 90.0))
	var cols: Dictionary = spec["colors"]
	if up > 48.0:
		return _col("forehead" if u < -0.3 and cols.has("forehead") else "crown")
	if up > 8.0:
		if u > 0.3 and cols.has("nape_head"):
			return _col("nape_head")
		if cols.has("brow") and u < 0.5 and u > -0.5:
			return _col("brow")
		return _col("face")
	if up > -35.0:
		if u < -0.3 and cols.has("forehead"):
			return _col("forehead")
		return _col("cheek")
	return _col("throat_head")


func _build_eyes(hc: Vector3, r: float) -> void:
	# On the head's surface (the LOD0 ring ellipse, pulled in to sit just
	# proud of the flat faces), forward of centre and a little high.
	var u := -0.34
	var rd: Array = LODS[0]["head_rings"]
	var sc := 1.0
	var yo := 0.0
	for i in range(1, rd.size()):
		if u >= float(rd[i][0]):
			var k := (u - float(rd[i - 1][0])) / (float(rd[i][0]) - float(rd[i - 1][0]))
			sc = lerpf(rd[i - 1][1], rd[i][1], k)
			yo = lerpf(rd[i - 1][2], rd[i][2], k)
			break
	for sd in [1.0, -1.0]:
		var a := deg_to_rad(22.0)
		var c := hc + Vector3(sd * r * sc * 0.9 * cos(a) * 0.93, r * (yo + sc * sin(a) * 0.93), r * u)
		var nrm := Vector3(sd * cos(a), sin(a), -0.35).normalized()
		var t1 := Vector3(0, 0, 1).cross(nrm).normalized()
		if t1.length_squared() < 0.5:
			t1 = Vector3.UP
		var t2 := nrm.cross(t1).normalized()
		var e := r * 0.2
		var pa := c + t2 * e * 1.2
		var pb := c + t1 * e
		var pc := c - t2 * e * 1.2
		var pd := c - t1 * e
		_tri(pa, pb, pc, _col("eye"), nrm)
		_tri(pa, pc, pd, _col("eye"), nrm)


func _build_beak(base_c: Vector3, bk: Array) -> void:
	var blen: float = bk[0]
	var depth: float = bk[1]
	var width: float = bk[2]
	var hook: float = bk[3]
	var b0 := base_c + Vector3(0, -depth * 0.1, depth * 0.15)
	var base := PackedVector3Array([b0 + Vector3(0, depth * 0.5, 0), b0 + Vector3(width * 0.5, 0, 0),
		b0 + Vector3(0, -depth * 0.5, 0), b0 + Vector3(-width * 0.5, 0, 0)])
	var tip := b0 + Vector3(0, -hook, -blen)
	var cols: Dictionary = spec["colors"]
	if cfg["beak_mid"]:
		var m0 := b0.lerp(tip, 0.55) + Vector3(0, hook * 0.5 + depth * 0.06, 0)
		var sc := 0.52
		var mid := PackedVector3Array([m0 + Vector3(0, depth * 0.5 * sc, 0), m0 + Vector3(width * 0.5 * sc, 0, 0),
			m0 + Vector3(0, -depth * 0.5 * sc, 0), m0 + Vector3(-width * 0.5 * sc, 0, 0)])
		var base_col := _col("cere") if cols.has("cere") else _col("beak")
		for i in 4:
			var j := (i + 1) % 4
			var c := (base[i] + base[j] + mid[i] + mid[j]) * 0.25
			var col := base_col if i == 0 or i == 3 else _col("beak")
			if not cols.has("cere"):
				col = _col("beak")
			_quad(base[i], base[j], mid[j], mid[i], col, c - (b0 + m0) * 0.5)
		for i in 4:
			var j := (i + 1) % 4
			var c := (mid[i] + mid[j] + tip) / 3.0
			var col := _col("beak_tip")
			if cols.has("beak_spot") and (i == 1 or i == 2):
				col = _col("beak_spot")
			_tri(mid[i], mid[j], tip, col, c - m0.lerp(tip, 0.3))
	else:
		for i in 4:
			var j := (i + 1) % 4
			var c := (base[i] + base[j] + tip) / 3.0
			_tri(base[i], base[j], tip, _col("beak"), c - b0.lerp(tip, 0.3))


func _build_antennae(hc: Vector3, r: float) -> void:
	var root := hc + Vector3(r * 0.35, r * 0.7, -r * 0.6)
	var tip := hc + Vector3(r * 2.3, r * 1.9, -r * 3.2)
	var side := Vector3(0.0, 1.0, 0.0).cross(tip - root).normalized() * r * 0.35
	var mid := root.lerp(tip, 0.45)
	var mx := Vector3(-1, 1, 1)
	# A thin feathery leaf, both faces, mirrored to the left.
	for up in [1.0, -1.0]:
		var out := Vector3(0, up, 0.3 * up)
		for sd in [Vector3.ONE, mx]:
			_tri(root * sd, (mid + side * 1.2) * sd, tip * sd, _col("antenna"), out)
			_tri(root * sd, tip * sd, (mid - side * 0.4) * sd, _col("antenna"), out)


# --- Wings ----------------------------------------------------------------

## The wing's anchor: leading edge z of the root and root height (upper
## flank, so folded wings cover the flank and back like a real bird's).
func _wing_root() -> Vector3:
	var t := 0.2
	return Vector3(0, body_yc(t) + body_hh(t) * 0.4, body_z(0.16))


## How much of the chord survives folding (the feathers stack up): nearly
## nothing at the root (it would otherwise swing into the body), enough
## outboard to cover the flank up to the spine.
const FOLD_KEEP_ROOT := 0.15
## Root chord limit, x the body half-width at the shoulder.
const ROOT_CHORD_K := 1.4


## Beyond the wrist the folded hand narrows to its tip (the primaries slide
## under one another): at the plate's end it keeps this share of the wrist's
## kept chord. Kept whole, a folded hand behind the rump stood out beside the
## tail by its own width (0.031-0.037 span; round-3 verifier). It narrows
## from its leading edge (the outer side of a folded wing): the trailing
## edge, which lies along the back, stays where the wrist's share puts it,
## so the folded wing still meets the body (_hand_shift).
const HAND_KEEP_TIP := 0.55


## How far the hand's leading edge slides back along the chord when folded
## (so the narrowing comes off the outer side): 0 up to the wrist.
func _hand_shift(x: float, wrist_x: float, keep_out: float, tip_x: float, chord: float) -> float:
	if x <= wrist_x:
		return 0.0
	return (keep_out - _fold_keep(x, 0.0, wrist_x, keep_out, tip_x)) * chord


func _fold_keep(x: float, sx_side: float, wrist_x: float, keep_out: float, tip_x: float) -> float:
	if x > wrist_x:
		return lerpf(keep_out, keep_out * HAND_KEEP_TIP, clampf((x - wrist_x) / maxf(tip_x - wrist_x, 1e-4), 0.0, 1.0))
	var k := clampf((x - sx_side) / maxf(wrist_x - sx_side, 1e-4), 0.0, 1.0)
	return lerpf(FOLD_KEEP_ROOT, keep_out, k)


func _build_wings() -> void:
	var w: Dictionary = spec["wing"]
	var st_all: Array = w["stations"]
	var wrist: int = w["wrist"]
	var dih: Array = w["dihedral"]
	var arm_d := deg_to_rad(dih[0])
	var hand_d := deg_to_rad(float(dih[0]) + float(dih[1]))
	var root := _wing_root()
	# Station subset for this LOD (always root, wrist and the last station,
	# which holds the wingtip, so the span is identical at every LOD).
	var idx: Array[int] = []
	var mode: String = cfg["wing_stations"]
	for i in st_all.size():
		var keep := true
		if mode == "mid":
			keep = i == 0 or i == wrist or i == st_all.size() - 1 or i == wrist + (st_all.size() - wrist) / 2
		elif mode == "low":
			keep = i == 0 or i == wrist or i == st_all.size() - 1
		if keep:
			idx.append(i)
	var fingers: Dictionary = w.get("fingers", {})
	var has_fingers := not fingers.is_empty()
	# Large birds keep the ridge along the hand (see ARM_THICK).
	var big := float(SizeRules.species_data(species).get("span", 0.24)) >= BirdModels.LARGE_SPAN
	# Leading edge / trailing edge points and local "up" of every station.
	var le := PackedVector3Array()
	var te := PackedVector3Array()
	var ups := PackedVector3Array()
	var xs := PackedFloat32Array()
	var sx_side := body_hw(0.3) * 0.92
	var wrist_x: float = st_all[wrist][0]
	for i in st_all.size():
		var s: Array = st_all[i]
		# The root station sits just inside the body side (anchored there).
		var x: float = sx_side * 0.82 if i == 0 else float(s[0])
		var y := root.y
		if x > sx_side:
			y += (minf(x, wrist_x) - sx_side) * tan(arm_d)
		if x > wrist_x:
			y += (x - wrist_x) * tan(hand_d)
		var d := arm_d if x <= wrist_x else hand_d
		if x <= sx_side:
			d = 0.0
		var p := Vector3(x, y, root.z + float(s[1]))
		# The root chord is hidden inside the body anyway; kept short (about
		# the body's half-width) it cannot swing across the midline when the
		# wing sweeps back.
		var ch: float = minf(float(s[2]), ROOT_CHORD_K * sx_side) if i == 0 else float(s[2])
		le.append(p)
		te.append(p + Vector3(0, 0, ch))
		ups.append(Vector3(-sin(d), cos(d), 0))
		xs.append(x)
	# A far LOD keeps fewer stations, so its chords run straight past the
	# dropped ones and the wing loses area (up to 18% from above): stretch
	# its chords so the plate covers as much as LOD0's (each strip between
	# two stations is dx x mean chord, whatever the leading edge does).
	# The root (inside the body) and the plate's end (where the fingers or
	# the wingtip sit, so the span stays exactly 1.0) keep their chords.
	if idx.size() < st_all.size():
		var last_i := st_all.size() - 1
		var full := 0.0
		for i in last_i:
			full += (xs[i + 1] - xs[i]) * ((te[i] - le[i]).z + (te[i + 1] - le[i + 1]).z)
		var scaled := 0.0
		var fixed := 0.0
		for k in idx.size() - 1:
			var a := idx[k]
			var b := idx[k + 1]
			var dx := xs[b] - xs[a]
			for j in [a, b]:
				var c := (te[j] - le[j]).z * dx
				if j == 0 or j == last_i:
					fixed += c
				else:
					scaled += c
		var kc := (full - fixed) / maxf(scaled, 1e-6)
		for i in idx:
			if i > 0 and i < last_i:
				te[i] = le[i] + (te[i] - le[i]) * kc
	# The shoulder pivot is the wing root's leading edge on the body side.
	var shoulder := Vector3(sx_side, root.y, root.z + float(st_all[0][1]))
	# The hand turns about the wrist's trailing edge: sweeping back it then
	# pushes the wrist's leading edge forward (the bend of the wing) instead
	# of dragging the hand's trailing edge inboard over the arm.
	var wrist_p := te[wrist]
	var keep_out := clampf(body_hh(0.3) * 0.85 / float(st_all[wrist][2]), 0.3, 0.85)
	var tip_x: float = st_all[st_all.size() - 1][0]
	_plate_end_x = tip_x
	# Hand (and fingers) are posed about the wrist; the wrist station itself
	# follows the arm so the surface never cracks at the joint.
	_part(BirdPose.G_ARM, 1.0, shoulder, arm_d, wrist_p, 1.0)
	# UV = (hand dihedral, perched droop): see BirdPose.
	_uv = Vector2(deg_to_rad(float(dih[1])), deg_to_rad(float(spec["anim"][4])))
	var arm_bands: Array = w["arm_bands"]
	var hand_bands: Array = w["hand_bands"]
	var under_bands: Array = w["under_bands"]
	var tip_from: float = w.get("tip_from", 2.0)
	var under_tip_from: float = w.get("under_tip", tip_from)
	var tris := []  # [a, b, c, d|null, col, out, meta] right wing; mirrored after
	var last := idx[idx.size() - 1]
	for k in idx.size() - 1:
		var i0 := idx[k]
		var i1 := idx[k + 1]
		var is_hand := i0 >= wrist
		# Thickness: a ridge on the arm only (primaries are thin); it tapers
		# to nothing at the wrist so arm and hand surfaces meet exactly.
		var hand_t := 0.0
		if is_hand:
			hand_t = ((xs[i0] + xs[i1]) * 0.5 - wrist_x) / maxf(tip_x - wrist_x, 1e-4)
		var top_cuts := _cuts(hand_bands if is_hand else arm_bands, not is_hand or big)
		var bot_cuts := _cuts(under_bands, false)
		if is_hand:
			# The hand bends (its rotation grows from wrist to tip), so both
			# surfaces are cut alike: they then bend alike and can never pass
			# through each other where they meet at the edges. Underside
			# band edges close to an upper one snap to it (colours stay
			# coverage-averaged) to spare triangles.
			var both := top_cuts.duplicate()
			for u in bot_cuts:
				var near_one := false
				for t in top_cuts:
					if absf(float(t) - float(u)) < 0.3:
						near_one = true
				if not near_one:
					both.append(u)
			both.sort()
			top_cuts = both
			bot_cuts = both.duplicate()
		for pass_i in 2:
			var top := pass_i == 0
			var cuts: Array = top_cuts if top else bot_cuts
			for b in cuts.size() - 1:
				var u0: float = cuts[b]
				var u1: float = cuts[b + 1]
				var col: Color
				if top:
					col = _band_color(hand_bands if is_hand else arm_bands, u0, u1)
					if is_hand and hand_t >= tip_from:
						col = _col("tip")
				else:
					col = _band_color(under_bands, u0, u1)
					if is_hand and hand_t >= under_tip_from:
						col = _col("under_tip")
					elif is_hand and k > 0 and idx[k - 1] < wrist and w.has("under_wrist") and u1 <= 0.35:
						col = _col(w["under_wrist"])
				var p00 := _wpt(le[i0], te[i0], ups[i0], u0, top, _ridge_at(i0, wrist, last, big))
				var p01 := _wpt(le[i0], te[i0], ups[i0], u1, top, _ridge_at(i0, wrist, last, big))
				var p10 := _wpt(le[i1], te[i1], ups[i1], u0, top, _ridge_at(i1, wrist, last, big))
				var p11 := _wpt(le[i1], te[i1], ups[i1], u1, top, _ridge_at(i1, wrist, last, big))
				var out := ups[i0] if top else -ups[i0]
				var g0 := BirdPose.G_ARM if i0 <= wrist else BirdPose.G_HAND
				var g1 := BirdPose.G_ARM if i1 <= wrist else BirdPose.G_HAND
				var meta := PackedFloat32Array()
				for q in [[p00, g0, i0], [p01, g0, i0], [p11, g1, i1], [p10, g1, i1]]:
					var pp: Vector3 = q[0]
					var si: int = q[2]
					# Folding stacks the feathers towards the leading edge, and a
					# leading edge ahead of the shoulder (the gull's crooked
					# wrist) comes back to the shoulder line, so the folded
					# wing lies along the body instead of bulging out.
					var gather := maxf(pp.z - le[si].z, 0.0) * (1.0 - _fold_keep(xs[si], sx_side, wrist_x, keep_out, tip_x)) \
						+ minf(le[si].z - shoulder.z, 0.0) - _hand_shift(xs[si], wrist_x, keep_out, tip_x, (te[si] - le[si]).z)
					meta.append_array([float(q[1]), _hand_w(xs[si], wrist_x, tip_x), gather])
				tris.append([p00, p01, p11, p10, col, out, meta])
	if has_fingers:
		_finger_tris(tris, fingers, le[last], te[last], ups[last], wrist_x, tip_x, keep_out, tip_from, under_tip_from)
	_emit_wing(tris)
	_uv = Vector2.ZERO


# Folded, the slotted primaries close up: each finger turns (about its own
# root, as a shear along the chord) until it lies along the span like the
# rest of the folded hand, so a folded crow, hawk or eagle wing ends in a
# stack of parallel primaries instead of a fanned comb (round-3 verifier).
# A shear keeps every finger's triangles the right way round, and fingers
# whose roots just touch stay side by side (a fan closed about the leading
# edge instead turned the swept-back ones inside out).
var _fg_le_z := 0.0
var _fg_keep := 0.5
var _fg_shift := 0.0


## A finger vertex's fold gather: the plate end's (its chordwise offset from
## the leading edge, keep_out x HAND_KEEP_TIP of it kept, the narrowing off
## the leading side) plus the turn of its finger (angle a,
## root at rx) to the span direction, both as a slide along -z.
func _finger_gather(c: Vector3, rx: float, a: float) -> float:
	return (c.z - _fg_le_z) * (1.0 - _fg_keep) - _fg_shift + _fg_keep * (c.x - rx) * tan(a)


## Slotted primaries ("fingers"): LOD0 draws every finger with a rounded
## tip, LOD1 three (always keeping the outermost), LOD2 none (the plate ends
## at the outermost finger's tip corner, so every LOD spans exactly 1.0).
## Roots touch and are stacked a hair apart so they never z-fight.
func _finger_tris(tris: Array, f: Dictionary, le_s: Vector3, te_s: Vector3, up_s: Vector3, wrist_x: float, plate_x: float, keep_out: float, tip_from: float, under_tip_from: float) -> void:
	var n: int = f["n"]
	var flen: float = f["length"]
	_fg_le_z = le_s.z
	_fg_keep = keep_out * HAND_KEEP_TIP
	# The plate's end narrows from its leading edge (_hand_shift): so do the
	# fingers on it.
	_fg_shift = (keep_out - _fg_keep) * (te_s.z - le_s.z)
	var spread: Array = f["spread"]
	var prof: Array = f["profile"]
	var wfrac: float = f["width"]
	var upturn := deg_to_rad(float(f.get("upturn", 0.0)))
	var chord := te_s.z - le_s.z
	var recs := []
	for i in n:
		var u := (1.0 - wfrac) * 0.5 + wfrac * (i + 0.5) / n
		var lift := up_s * (n - i) * 0.0012
		var rc := le_s.lerp(te_s, u) + lift
		var a := deg_to_rad(lerpf(spread[0], spread[1], float(i) / maxf(n - 1, 1)))
		var dir := Vector3(cos(a), 0, sin(a))
		var l: float = flen * float(prof[i])
		# Roots just touch: at LOD0 each finger has a raised spine, which must
		# not pierce its neighbour (LOD1 widens its three fingers anyway).
		# The same at every LOD, so the outermost tip - the span - is too.
		var hw := chord * wfrac / n * 0.5
		var r0 := rc
		var tipc := rc + dir * l * cos(upturn) + up_s * l * sin(upturn)
		var perp := Vector3(-dir.z, 0, dir.x)
		# Roots lie on the plate's end edge (the finger slots open from there).
		var uw := hw / maxf(chord, 1e-5)
		var ra := le_s.lerp(te_s, clampf(u - uw, 0.0, 1.0)) + lift
		var rb := le_s.lerp(te_s, clampf(u + uw, 0.0, 1.0)) + lift
		var corners := [ra, rb, tipc + perp * hw * 0.62, tipc + dir * hw * 0.55, tipc - perp * hw * 0.62]
		recs.append({"corners": corners, "hw": hw, "rc": r0, "tipc": tipc, "dir": dir, "u": u, "lift": lift, "a": a})
	# The outermost finger (its outermost corner sets the span).
	var mx := -INF
	var outer := 0
	for i in n:
		for c in recs[i]["corners"]:
			if c.x > mx:
				mx = c.x
				outer = i
	var keep: Array[int] = []
	var mode: Variant = cfg["fingers"]
	if typeof(mode) == TYPE_STRING:
		for i in n:
			keep.append(i)
	elif int(mode) > 0:
		for i in [0, outer, n - 1]:
			if not keep.has(i):
				keep.append(i)
	var tip_pt := Vector3.ZERO
	for c in recs[outer]["corners"]:
		if c.x >= mx - 1e-9:
			tip_pt = c
	if keep.is_empty():
		# LOD2: close the plate with a triangle to the outermost corner.
		for top in [true, false]:
			var col := _col("prim") if top else _col("under_flight")
			if not top and 1.0 >= under_tip_from:
				col = _col("under_tip")
			var meta := PackedFloat32Array([BirdPose.G_HAND, 1.0, -_fg_shift,
				BirdPose.G_HAND, 1.0, chord * (1.0 - _fg_keep) - _fg_shift, BirdPose.G_HAND, 1.0, _finger_gather(tip_pt, recs[outer]["rc"].x, recs[outer]["a"])])
			tris.append([le_s, te_s, tip_pt, null, col, up_s if top else -up_s, meta])
		_set_tip(tip_pt)
		return
	# Fewer, wider fingers at LOD1 cover about as much as all of them (they
	# overlap a little at the root).
	var scale_w := float(n) / keep.size() * 0.95 if keep.size() < n else 1.0
	var rounded := lod == 0
	for i in keep:
		var rec: Dictionary = recs[i]
		var hw: float = rec["hw"] * scale_w
		var dir: Vector3 = rec["dir"]
		var perp := Vector3(-dir.z, 0, dir.x)
		var tipc: Vector3 = rec["tipc"]
		var uw := hw / maxf(chord, 1e-5)
		var u: float = rec["u"]
		var lift: Vector3 = rec["lift"]
		var pts: Array = [le_s.lerp(te_s, clampf(u - uw, 0.0, 1.0)) + lift, le_s.lerp(te_s, clampf(u + uw, 0.0, 1.0)) + lift,
			tipc + perp * hw * 0.62, tipc + dir * hw * 0.55, tipc - perp * hw * 0.62]
		if i == outer:
			# Keep the exact outermost tip so every LOD spans 1.0.
			var orig: Array = rec["corners"]
			pts[2] = orig[2]
			pts[3] = orig[3]
			pts[4] = orig[4]
		if not rounded:
			# LOD1: a quad ending at the outermost corner of the rounded tip.
			var far: Vector3 = pts[2] if pts[2].x > pts[4].x else pts[4]
			if pts[3].x > far.x:
				far = pts[3]
			pts = [pts[0], pts[1], far if far == pts[2] or far == pts[3] else pts[2], far if far == pts[4] else pts[4]]
		for top in [true, false]:
			var col := _col("prim") if top else _col("under_flight")
			if top and 0.9 >= tip_from:
				col = _col("tip")
			elif not top and 0.9 >= under_tip_from:
				col = _col("under_tip")
			var meta := PackedFloat32Array()
			for c in pts:
				meta.append_array([BirdPose.G_HAND, _hand_w(c.x, wrist_x, plate_x), _finger_gather(c, rec["rc"].x, rec["a"])])
			var out := up_s if top else -up_s
			if pts.size() == 5 and top and rounded:
				# A raised spine from the root's middle to the tip point: the
				# finger is a thin pyramid, visible edge-on. A small cap closes
				# its root against the plate's (flat) end edge. pts: 0 root
				# (leading), 1 root (trailing), 2 tip side (trailing), 3 tip
				# point, 4 tip side (leading).
				var rm: Vector3 = (pts[0] + pts[1]) * 0.5 + up_s * (FINGER_SPINE * 2.0 * hw)
				var mm := PackedFloat32Array([BirdPose.G_HAND, _hand_w(rm.x, wrist_x, plate_x), _finger_gather(rm, rec["rc"].x, rec["a"])])
				var q := [meta.slice(0, 3), meta.slice(3, 6), meta.slice(6, 9), meta.slice(9, 12), meta.slice(12, 15)]
				tris.append([pts[0], rm, pts[3], null, col, out, _cat([q[0], mm, q[3]])])
				tris.append([pts[0], pts[3], pts[4], null, col, out, _cat([q[0], q[3], q[4]])])
				tris.append([rm, pts[1], pts[2], null, col, out, _cat([mm, q[1], q[2]])])
				tris.append([rm, pts[2], pts[3], null, col, out, _cat([mm, q[2], q[3]])])
				tris.append([pts[0], pts[1], rm, null, col, -dir, _cat([q[0], q[1], mm])])
			elif pts.size() == 5:
				var m1 := PackedFloat32Array()
				m1.append_array(meta.slice(0, 9))
				var m2 := PackedFloat32Array()
				m2.append_array(meta.slice(0, 3))
				m2.append_array(meta.slice(6, 9))
				m2.append_array(meta.slice(12, 15))
				var m3 := PackedFloat32Array()
				m3.append_array(meta.slice(6, 15))
				tris.append([pts[0], pts[1], pts[2], null, col, out, m1])
				tris.append([pts[0], pts[2], pts[4], null, col, out, m2])
				tris.append([pts[2], pts[3], pts[4], null, col, out, m3])
			else:
				tris.append([pts[0], pts[1], pts[2], pts[3], col, out, meta])
	_set_tip(tip_pt)


func _set_tip(p: Vector3) -> void:
	tip_record = [p]


## Ridge height (x chord) at wing station i: the arm's everywhere but at the
## wrist, and on large birds the hand's too; nothing at the last station, so
## the plate closes (fingers, if any, continue from its end edge).
static func _ridge_at(i: int, wrist: int, last: int, big: bool) -> float:
	if i == last:
		return 0.0
	if i < wrist:
		return ARM_THICK
	return HAND_THICK if big else 0.0


static func _cat(parts: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for p in parts:
		out.append_array(p)
	return out


static func _hand_w(x: float, wrist_x: float, tip_x: float) -> float:
	return clampf((x - wrist_x) / maxf(tip_x - wrist_x, 1e-4), 0.0, 1.0)


## A point across the chord (u = 0 leading edge .. 1 trailing edge); the
## upper surface is raised into a ridge so the wing has some thickness.
static func _wpt(le_p: Vector3, te_p: Vector3, up: Vector3, u: float, top: bool, thick: float) -> Vector3:
	var p := le_p.lerp(te_p, u)
	if top and thick > 0.0:
		var h := u / RIDGE_U if u < RIDGE_U else (1.0 - u) / (1.0 - RIDGE_U)
		p += up * h * thick * (te_p.z - le_p.z)
	return p


## Chord cuts for this LOD: every band edge at LOD0 (plus the ridge; band
## edges within 0.07 of the ridge snap to it), just the ridge (top) at LOD1,
## nothing at LOD2.
func _cuts(bands: Array, top: bool) -> Array:
	var cuts := [0.0]
	if cfg["bands"]:
		if top:
			cuts.append(RIDGE_U)
		for b in bands:
			var u: float = b[0]
			if top and absf(u - RIDGE_U) < 0.07:
				continue
			if u > 0.001 and u < 0.999 and not cuts.has(u):
				cuts.append(u)
		cuts.sort()
	elif top and lod == 1:
		cuts.append(RIDGE_U)
	cuts.append(1.0)
	return cuts


## Colour of the chord interval [u0, u1]: the coverage-weighted average of
## the bands it spans (exactly the band's colour at LOD0; far LODs keep the
## wing's mean colour).
func _band_color(bands: Array, u0: float, u1: float) -> Color:
	var acc := Color(0, 0, 0, 0)
	var start := 0.0
	var tot := 0.0
	for b in bands:
		var e: float = b[0]
		var lo := maxf(start, u0)
		var hi := minf(e, u1)
		if hi > lo:
			var c := _col(b[1]).srgb_to_linear()
			acc += c * (hi - lo)
			tot += hi - lo
		start = e
	if tot <= 0.0:
		return _col(bands[bands.size() - 1][1])
	return (acc / tot).linear_to_srgb()


func _emit_wing(tris: Array) -> void:
	for sd in [1.0, -1.0]:
		_side = sd
		for t in tris:
			var a: Vector3 = t[0]
			var b: Vector3 = t[1]
			var c: Vector3 = t[2]
			var d: Variant = t[3]
			var col: Color = t[4]
			var out: Vector3 = t[5]
			var meta: PackedFloat32Array = t[6]
			if sd < 0.0:
				a.x = -a.x
				b.x = -b.x
				c.x = -c.x
				out.x = -out.x
				if d != null:
					var dd: Vector3 = d
					dd.x = -dd.x
					d = dd
			if d == null:
				_tri(a, b, c, col, out, meta)
			else:
				_quad(a, b, c, d, col, out, meta)
	_side = 0.0
	# Wingtip record (right wing): the emitted vertex at the tip, else the
	# outermost right-wing vertex.
	var best := -1
	var want: Vector3 = tip_record[0] if not tip_record.is_empty() else Vector3.INF
	for i in verts.size():
		var g := int(cu0[i * 4])
		if (g == BirdPose.G_ARM or g == BirdPose.G_HAND) and cu0[i * 4 + 1] > 0.0:
			if want != Vector3.INF:
				if verts[i].is_equal_approx(want):
					best = i
			elif best < 0 or verts[i].x > verts[best].x:
				best = i
	if best >= 0:
		_record_tip(best)


func _record_tip(i: int) -> void:
	var j := i * 4
	_tip_index = i
	# [pos, normal, c0, c1, c2, c3, uv, uv2]; uv2 (the fold hug) is filled in
	# by _apply_fold_hug.
	tip_record = [verts[i], norms[i], Vector4(cu0[j], cu0[j + 1], cu0[j + 2], cu0[j + 3]),
		Vector4(cu1[j], cu1[j + 1], cu1[j + 2], cu1[j + 3]), Vector4(cu2[j], cu2[j + 1], cu2[j + 2], cu2[j + 3]),
		Vector4(cu3[j], cu3[j + 1], cu3[j + 2], cu3[j + 3]), uvs[i], Vector2.ZERO]


## Moth: forewings and hindwings, flapped together from the thorax. At rest
## they sweep back into a low delta roof over the abdomen (fold sweep x 0.7,
## roll x 0.25 from BirdSpecies anim).
func _build_moth_wings() -> void:
	# Moth wings hinge on top of the thorax, so at rest they lie over the
	# abdomen like a roof.
	var root := Vector3(0, body_yc(0.2) + body_hh(0.2) * 0.9, body_z(0.12))
	var sx := body_hw(0.25) * 0.9
	var fore := [[0.02, 0.0, 0.1], [0.2, 0.004, 0.13], [0.38, 0.02, 0.135], [0.47, 0.035, 0.1], [0.5, 0.05, 0.05]]
	var hind := [[0.02, 0.085, 0.07], [0.14, 0.095, 0.13], [0.27, 0.12, 0.125], [0.34, 0.155, 0.075], [0.365, 0.19, 0.025]]
	var shoulder := Vector3(sx, root.y, root.z)
	_part(BirdPose.G_ARM, 1.0, shoulder, 0.0, shoulder, 0.7)
	var tris := []
	var sets := [[fore, 0.0, "fore", "fore_under"], [hind, -0.004, "hind", "hind_under"]]
	var mode: String = cfg["wing_stations"]
	for s in sets:
		var st: Array = s[0]
		var idx: Array[int] = []
		for i in st.size():
			if mode == "all" or i == 0 or i == st.size() - 1 or (mode == "mid" and i == 2):
				idx.append(i)
		var dy: float = s[1]
		for k in idx.size() - 1:
			var a: Array = st[idx[k]]
			var b: Array = st[idx[k + 1]]
			var ax: float = sx if idx[k] == 0 else float(a[0])
			var le0 := Vector3(ax, root.y + dy, root.z + float(a[1]))
			var te0 := le0 + Vector3(0, 0, minf(float(a[2]), ROOT_CHORD_K * sx) if idx[k] == 0 else float(a[2]))
			var le1 := Vector3(b[0], root.y + dy, root.z + float(b[1]))
			var te1 := le1 + Vector3(0, 0, b[2])
			for top in [true, false]:
				var cuts := [0.0, 0.35, 0.62, 1.0] if cfg["bands"] and top else [0.0, 1.0]
				for c in cuts.size() - 1:
					var u0: float = cuts[c]
					var u1: float = cuts[c + 1]
					var col := _moth_color(String(s[2]) if top else String(s[3]), k, idx.size() - 1, u0, u1, top)
					var p00 := le0.lerp(te0, u0)
					var p01 := le0.lerp(te0, u1)
					var p10 := le1.lerp(te1, u0)
					var p11 := le1.lerp(te1, u1)
					var meta := PackedFloat32Array()
					for q in [[p00, le0, idx[k]], [p01, le0, idx[k]], [p11, le1, idx[k + 1]], [p10, le1, idx[k + 1]]]:
						var pp: Vector3 = q[0]
						var lp: Vector3 = q[1]
						# Folding also slides the hindwing forward under the
						# forewing (onto the hinge line), so sweeping back never
						# swings it across the body.
						var keep := lerpf(0.05, 0.55, clampf((pp.x - sx) / 0.3, 0.0, 1.0))
						meta.append_array([BirdPose.G_ARM, 0.0, maxf(pp.z - lp.z, 0.0) * (1.0 - keep) + maxf(lp.z - shoulder.z, 0.0)])
					tris.append([p00, p01, p11, p10, col, Vector3.UP if top else Vector3.DOWN, meta])
	_emit_wing(tris)


func _moth_color(base: String, k: int, n: int, u0: float, u1: float, top: bool) -> Color:
	if not top or not cfg["bands"]:
		if not cfg["bands"] and top:
			# Far away: the wing's average (lighter hind, banded fore).
			return _col(base).lerp(_col(base + "_band") if base == "fore" else _col("hind_ring"), 0.25)
		return _col(base)
	if base == "fore":
		if u0 >= 0.34 and u1 <= 0.63:
			return _col("fore_band")
		if k == n - 1 and u0 < 0.1:
			return _col("fore_spot")
		return _col("fore")
	# Hindwing: an eyespot on the middle panel.
	if k == 1 and u0 >= 0.34 and u1 <= 0.63:
		return _col("hind_spot")
	if k == 1 or (k == 2 and u0 >= 0.34 and u1 <= 0.63):
		return _col("hind_ring")
	return _col("hind")


# --- Tail -----------------------------------------------------------------

func tail_base() -> Vector3:
	var t := 0.84
	return Vector3(0, body_yc(t) + body_hh(t) * 0.25, body_z(t))


## Height of the tail's central ridge, x its half-width there.
const TAIL_RIDGE := 0.3


## Tail: a flat underside and an upper surface with a low central ridge,
## banded on top at LOD0. Its outline
## carries the silhouette cue: notch, deep fork with streamers, fan, wedge.
func _build_tail() -> void:
	if spec["kind"] == "moth":
		return
	var td: Array = spec["tail"]
	var tlen: float = td[0]
	var hwb: float = float(td[1]) * 0.5
	var hwe: float = float(td[2]) * 0.5
	var shape: String = td[3]
	var depth: float = td[4]
	var cock := deg_to_rad(td[5])
	var bands: Array = td[6]
	var pitch := deg_to_rad(float(td[7]) if td.size() > 7 else 0.0)
	var tb := tail_base()
	# CUSTOM2.w = share of the tail's width that closes when folded (a
	# swallow closes its fork into one spike).
	_part(BirdPose.G_TAIL, 0.0, tb, cock, Vector3.ZERO, float(spec.get("tail_close", 0.45)))
	# Outline of the right half, centre -> outer corner: (x, z behind base).
	var ol: Array[Vector2] = []
	match shape:
		"square":
			ol = [Vector2(0, tlen), Vector2(hwe, tlen)]
		"notch":
			ol = [Vector2(0, tlen - depth), Vector2(hwe * 0.5, tlen - depth * 0.35), Vector2(hwe, tlen)]
		"fork":
			ol = [Vector2(0, tlen - depth), Vector2(hwe * 0.7, tlen * 0.76), Vector2(hwe, tlen)]
		"wedge":
			ol = [Vector2(0, tlen), Vector2(hwe * 0.55, tlen * 0.92), Vector2(hwe, tlen * 0.78)]
		_:  # fan / round
			ol = [Vector2(0, tlen), Vector2(hwe * 0.6, tlen * 0.95), Vector2(hwe, tlen * 0.8)]
	if lod >= 2 and ol.size() > 2:
		ol = [ol[0], ol[ol.size() - 1]]
	var n := ol.size()
	var base: Array[Vector2] = []
	for j in n:
		base.append(Vector2(hwb * float(j) / (n - 1), 0.0))
	var cuts := [0.0]
	var slots := []
	if cfg["bands"]:
		for b in bands:
			cuts.append(float(b[0]))
			slots.append(b[1])
	else:
		cuts.append(1.0)
		slots.append("")
	var up := BirdPose.rx(Vector3.UP, -pitch)
	for sd in [1.0, -1.0]:
		for top in [true, false]:
			var tcuts: Array = cuts if top else [0.0, 1.0]
			for bi in tcuts.size() - 1:
				var t0: float = tcuts[bi]
				var t1: float = tcuts[bi + 1]
				var col := _col("tail_under")
				if top:
					col = _col(slots[bi]) if slots[bi] != "" else _avg_tail(bands)
				for j in n - 1:
					var pts := []
					for q in [[j, t0], [j + 1, t0], [j + 1, t1], [j, t1]]:
						var jj: int = q[0]
						var tt: float = q[1]
						var v2 := base[jj].lerp(ol[jj], tt)
						var p3 := tb + BirdPose.rx(Vector3(v2.x * sd, 0.0, v2.y), -pitch)
						if top and jj == 0:
							# The upper surface rises to a low ridge along the
							# middle (the central feathers lie on top of the
							# outer ones): seen exactly side-on, a tail is then
							# a thin wedge rather than an invisible line.
							p3 += up * TAIL_RIDGE * base[n - 1].lerp(ol[n - 1], tt).x
						pts.append(p3)
					var meta := PackedFloat32Array()
					for q in [t0, t0, t1, t1]:
						meta.append_array([BirdPose.G_TAIL, q, 0.0])
					_quad(pts[0], pts[1], pts[2], pts[3], col, up if top else -up, meta)
		# Close the ridge at the tail's end (the flat underside and the raised
		# upper surface meet everywhere else).
		var e0 := tb + BirdPose.rx(Vector3(0.0, 0.0, ol[0].y), -pitch)
		var e1 := tb + BirdPose.rx(Vector3(ol[1].x * sd, 0.0, ol[1].y), -pitch)
		var back := BirdPose.rx(Vector3.BACK, -pitch)
		var last_slot: String = slots[slots.size() - 1]
		_tri(e0 + up * TAIL_RIDGE * ol[n - 1].x, e0, e1, _col(last_slot) if last_slot != "" else _avg_tail(bands), back,
			PackedFloat32Array([BirdPose.G_TAIL, 1.0, 0.0, BirdPose.G_TAIL, 1.0, 0.0, BirdPose.G_TAIL, 1.0, 0.0]))


func _avg_tail(bands: Array) -> Color:
	var acc := Color(0, 0, 0, 0)
	var start := 0.0
	for b in bands:
		acc += _col(b[1]).srgb_to_linear() * (float(b[0]) - start)
		start = b[0]
	return (acc / maxf(start, 1e-4)).linear_to_srgb()


# --- Legs (built after normalisation, in final units) --------------------

func _build_legs() -> void:
	var legs: int = cfg["legs"]
	if legs <= 0:
		return
	var s: float = spec["anim"][3]
	var pitch := deg_to_rad(s)
	for sd in [1.0, -1.0]:
		# Hip under the belly, a little behind the body centre.
		var hip := _to_final(Vector3(sd * body_hw(0.5) * 0.35, body_yc(0.5) - body_hh(0.5) * 0.55, body_z(0.52)))
		var hp := BirdPose.rx(hip, pitch)
		var length := maxf(hp.y + FOOT_DEPTH, 0.012)
		_part(BirdPose.G_LEG, sd, hip, deg_to_rad(-95.0))
		var col := _col("leg")
		var foot := hip + Vector3(0, -length, 0)
		# In the rest mesh the leg hangs straight down from the hip in body
		# space; the shader tilts it to hang vertically when perched.
		var r0 := 0.011
		var r1 := 0.007
		if legs >= 2:
			var top := PackedVector3Array()
			var bot := PackedVector3Array()
			for i in 3:
				var a := TAU * i / 3.0 + PI * 0.5
				top.append(hip + Vector3(cos(a) * r0, 0, sin(a) * r0))
				bot.append(foot + Vector3(cos(a) * r1, 0.004, sin(a) * r1))
			for i in 3:
				var j := (i + 1) % 3
				var c := (top[i] + top[j] + bot[i] + bot[j]) * 0.25
				var axis := Vector3(hip.x, c.y, hip.z)
				_quad(top[i], top[j], bot[j], bot[i], col, c - axis)
			# Toes: a flat three-pointed foot gripping forwards.
			var toe_f := foot + Vector3(0, 0, -0.045)
			var toe_b := foot + Vector3(0, 0, 0.022)
			var toe_l := foot + Vector3(-0.012, 0, -0.03)
			var toe_r := foot + Vector3(0.012, 0, -0.03)
			_tri(toe_l, toe_f, toe_r, col, Vector3.UP)
			_tri(toe_l, toe_r, toe_b, col, Vector3.UP)
			_tri(toe_l, toe_f, toe_r, col, Vector3.DOWN)
			_tri(toe_l, toe_r, toe_b, col, Vector3.DOWN)
		else:
			var a := hip + Vector3(0, 0, -r0)
			var b := hip + Vector3(0, 0, r0)
			var c := foot + Vector3(0, 0, -0.035)
			var d := foot + Vector3(0, 0, r1)
			_quad(a, b, d, c, col, Vector3(sd, 0, 0))
			_quad(a, b, d, c, col, Vector3(-sd, 0, 0))


var _scale := 1.0
var _centre := Vector3.ZERO
## The x (authoring units) where the wing plate ends (the tip, or where the
## slotted primaries start).
var _plate_end_x := 0.5
var _tip_index := -1
## A far LOD's scale of its body rings' width and height, and of its head's,
## so its silhouette from above and from the side covers as much as LOD0's
## (fewer rings and sides cut the curves inwards; a LOD switch would then
## shrink the bird by 10-15% in one frame). 1 at LOD0.
var _ring_k := Vector2.ONE
var _head_k := Vector2.ONE


# --- Highlight marker -------------------------------------------------------
# A highlighted bird carries a marker that says "prey" or "danger" at every
# distance without recolouring the bird (its plumage must still say which
# species it is) or drawing it larger than it is (which would lie about its
# size and stop it looming as the player closes in): a thin ring for edible,
# a warning triangle for danger, the colour-blind cue being the shape. It is
# its own small mesh, drawn by one MultiMesh per world holding only the
# highlighted birds (BirdBatch), with the bird material. The shader places
# it around the bird, facing the viewer, at a fixed angular size far away
# and just outside the wingtips close up. Every vertex rests at the origin:
# the state not shown is nothing at all.
# CUSTOM1 = (unit direction x, y in the view plane, shape 0 ring / 1
# triangle, 1 = outer edge).

## Sides of the ring: round even around a near bird (the marker is drawn
## only for highlighted birds, so its 70 triangles cost next to nothing).
const MARK_RING_SIDES := 32


## The marker mesh's arrays (see above).
static func build_marker() -> Array:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var cu0 := PackedFloat32Array()
	var cu1 := PackedFloat32Array()
	var zero4 := PackedFloat32Array()
	var shapes := [[0.0, MARK_RING_SIDES, PI / MARK_RING_SIDES], [1.0, 3, PI * 0.5]]
	for sh: Array in shapes:
		var shape: float = sh[0]
		var nsides: int = sh[1]
		var a0: float = sh[2]
		for i in nsides:
			var d0 := Vector2(cos(a0 + TAU * i / nsides), sin(a0 + TAU * i / nsides))
			var d1 := Vector2(cos(a0 + TAU * (i + 1) / nsides), sin(a0 + TAU * (i + 1) / nsides))
			# Clockwise as seen from the camera (the shader's view plane: x
			# right, y up), Godot's front faces.
			for q in [[d0, 1.0], [d0, 0.0], [d1, 1.0], [d0, 0.0], [d1, 0.0], [d1, 1.0]]:
				var d: Vector2 = q[0]
				verts.append(Vector3.ZERO)
				norms.append(Vector3.BACK)
				cols.append(Color(1, 1, 1, 1))
				cu0.append_array([BirdPose.G_MARK, 0.0, 0.0, 0.0])
				cu1.append_array([d.x, d.y, shape, float(q[1])])
				zero4.append_array([0.0, 0.0, 0.0, 0.0])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_CUSTOM0] = cu0
	arrays[Mesh.ARRAY_CUSTOM1] = cu1
	arrays[Mesh.ARRAY_CUSTOM2] = zero4
	arrays[Mesh.ARRAY_CUSTOM3] = zero4.duplicate()
	var uv := PackedVector2Array()
	uv.resize(verts.size())
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv.duplicate()
	return arrays


## Triangles of the highlight marker mesh (ring + triangle).
static func marker_triangles() -> int:
	return (MARK_RING_SIDES + 3) * 2


# --- Fold hug -------------------------------------------------------------
# Folding rotates the wing about the shoulder, which lays it along the body
# as a flat plate standing on the upper flank: straight, while the body
# narrows behind its widest point, so the back half of the folded wing (and
# a perched bird's wingtips) stood off the body by up to 0.09 span, a blade
# floating beside the bird from above and from behind. The hug moves each
# wing station (a spanwise position: every vertex across the chord and both
# surfaces together, so the plate keeps its shape and thickness) in towards
# the midline, and up where it must clear the tail, so the folded wing lies
# on the upper flank and back and follows the taper onto the rump. It is
# baked once per species from LOD0 (every LOD uses the same table, by
# spanwise position) and applied by the shader as fold^3 (BirdPose, UV2).

## The inner edge of the folded wing tucks this far inside the body's
## outline seen from above (model units, span 1).
const HUG_TUCK := 0.004
## ...but never nearer the midline than this: the other wing is its mirror.
const HUG_X_MIN := 0.005
## Wing vertices stay outside the body's ellipse scaled by 1 + this.
const HUG_BODY_MARGIN := 0.03
## Clearance kept from the tail (sideways, or above it when lifted over it).
const HUG_TAIL_EPS := 0.004
## Lifts tried per station to get further in over the back or the tail.
const HUG_LIFTS := [0.0, 0.004, 0.008, 0.012, 0.016, 0.02]
## Neighbouring stations' hugs differ by at most this x their distance
## along the folded wing, so the plate bends smoothly, never through itself.
const HUG_SLOPE := 0.4
## The folded wing's inner edge where it passes the rump must be within this
## of the body's outline (the chord to the next station runs past the rump).
const HUG_RUMP_GAP := 0.006
## Perch blends the hug is checked at (with full fold): the tail cocks and
## the wing droops differently in each.
const HUG_PERCH := [1.0, 0.0, 0.5, 0.25, 0.75]


## The body loft's widest |x| at model-space z (the mesh as drawn at LOD0:
## the ring vertices nearest the sides sit at cos(pi / 8) of the ellipse's
## half-width, the rump edge's ends at the full width).
func _loft_half_n(z: float) -> float:
	var t := (z / _scale + _centre.z + _L * 0.5) / _L
	var rt: Array = LODS[0]["body_t"]
	var k := cos(PI / float(LODS[0]["body_sides"]))
	if t < 0.0 or t > 1.0:
		return 0.0
	for i in rt.size() - 1:
		if t <= float(rt[i + 1]):
			var u := (t - float(rt[i])) / (float(rt[i + 1]) - float(rt[i]))
			return k * lerpf(body_hw(rt[i]), body_hw(rt[i + 1]), u) * _scale
	var t4: float = rt[rt.size() - 1]
	return lerpf(k * body_hw(t4), body_hw(1.0), (t - t4) / (1.0 - t4)) * _scale


const HUG_TAIL_BIN := 0.004
const HUG_TAIL_REACH := 0.012


## The tail's top and half-width near each z (within HUG_TAIL_REACH), from
## its sample points, in bins of HUG_TAIL_BIN: [(z0, 0, 0), (_, top, half)...].
static func _tail_bins(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	if pts.is_empty():
		out.append(Vector3(INF, 0.0, 0.0))
		return out
	var z0 := INF
	var z1 := -INF
	for p in pts:
		z0 = minf(z0, p.z)
		z1 = maxf(z1, p.z)
	z0 -= HUG_TAIL_REACH
	var nb := int(ceilf((z1 + HUG_TAIL_REACH - z0) / HUG_TAIL_BIN)) + 1
	out.resize(nb + 1)
	out[0] = Vector3(z0, 0.0, 0.0)
	for b in nb:
		out[b + 1] = Vector3(0.0, -INF, 0.0)
	var reach := int(ceilf(HUG_TAIL_REACH / HUG_TAIL_BIN))
	for p in pts:
		var c := int(floorf((p.z - z0) / HUG_TAIL_BIN))
		for b in range(maxi(c - reach, 0), mini(c + reach + 1, nb)):
			var e := out[b + 1]
			out[b + 1] = Vector3(0.0, maxf(e.y, p.y), maxf(e.z, absf(p.x)))
	return out


## Triangle sample points (vertices, edges and inside), for the tail.
static func _tri_samples(a: Vector3, b: Vector3, c: Vector3, n: int, out: PackedVector3Array) -> void:
	for i in n + 1:
		for j in n + 1 - i:
			var u := float(i) / n
			var w := float(j) / n
			out.append(a * (1.0 - u - w) + b * u + c * w)


## Computes the hug of every wing station from this (LOD0) mesh: returns
## {"xs": station spanwise x, "d": (dx, dy) per station, "plate_end": x}.
func _fold_hug_table() -> Dictionary:
	var nv := verts.size()
	var z_end := -INF
	for i in nv:
		if int(cu0[i * 4]) == BirdPose.G_BODY:
			z_end = maxf(z_end, verts[i].z)
	# The right wing and the tail are all the hug looks at, each distinct
	# point once (flat shading repeats every position in 3-6 triangles).
	var rep := PackedInt32Array()
	var of := PackedInt32Array()
	of.resize(nv)
	of.fill(-1)
	var seen := {}
	for i in nv:
		var g := int(cu0[i * 4])
		var right_wing := (g == BirdPose.G_ARM or g == BirdPose.G_HAND) and cu0[i * 4 + 1] > 0.0
		if not right_wing and g != BirdPose.G_TAIL:
			continue
		var key := Vector4(verts[i].x, verts[i].y, verts[i].z, float(g) + 10.0 * cu0[i * 4 + 1])
		var u: int = seen.get(key, -1)
		if u < 0:
			u = rep.size()
			seen[key] = u
			rep.append(i)
		of[i] = u
	var poses: Array[PackedVector3Array] = []
	var tails: Array[PackedVector3Array] = []
	for q in HUG_PERCH:
		var inst := Vector4(0.25, 0.0, 1.0, q)
		var v := PackedVector3Array()
		v.resize(rep.size())
		for u in rep.size():
			var i := rep[u]
			var j := i * 4
			v[u] = BirdPose.pose(verts[i], norms[i], Vector4(cu0[j], cu0[j + 1], cu0[j + 2], cu0[j + 3]),
				Vector4(cu1[j], cu1[j + 1], cu1[j + 2], cu1[j + 3]), Vector4(cu2[j], cu2[j + 1], cu2[j + 2], cu2[j + 3]),
				Vector4(cu3[j], cu3[j + 1], cu3[j + 2], cu3[j + 3]), inst, 0.0, 0.0, true, uvs[i])[0]
		poses.append(v)
		var ts := PackedVector3Array()
		for t in range(0, nv, 3):
			if int(cu0[t * 4]) == BirdPose.G_TAIL:
				_tri_samples(v[of[t]], v[of[t + 1]], v[of[t + 2]], 3, ts)
		tails.append(_tail_bins(ts))
	# What each point meets in each pose, where it is along the body (a lift
	# moves it up, never along): the body's ellipse there, scaled by 1 +
	# margin (half-width, half-height, centre y; 0 outside the body), and the
	# tail's top and half-width near it (top -INF where there is no tail).
	var ctx: Array[PackedFloat32Array] = []
	for pi in poses.size():
		var v := poses[pi]
		var tb := tails[pi]
		var c := PackedFloat32Array()
		c.resize(rep.size() * 5)
		for u in rep.size():
			var z := v[u].z
			var t := (z / _scale + _centre.z + _L * 0.5) / _L
			if t >= 0.0 and t <= 1.0:
				c[u * 5] = body_hw(t) * _scale * (1.0 + HUG_BODY_MARGIN)
				c[u * 5 + 1] = body_hh(t) * _scale * (1.0 + HUG_BODY_MARGIN)
				c[u * 5 + 2] = (body_yc(t) - _centre.y) * _scale
			var bi := int(floorf((z - tb[0].x) / HUG_TAIL_BIN)) if tb.size() > 1 else -1
			c[u * 5 + 3] = tb[bi + 1].y if bi >= 0 and bi < tb.size() - 1 else -INF
			c[u * 5 + 4] = tb[bi + 1].z if bi >= 0 and bi < tb.size() - 1 else 0.0
		ctx.append(c)
	# Stations: right-wing points by spanwise position (a ridge shifts the
	# upper surface by a hair); every slotted primary goes with the plate's
	# end, so the fingers move as one (their roots sit a hair inboard of it,
	# lifted along the hand's dihedral).
	var plate_end := _plate_end_x * _scale
	var raw := []
	for u in rep.size():
		var i := rep[u]
		if int(cu0[i * 4]) != BirdPose.G_TAIL:
			raw.append([_hug_x(verts[i].x, plate_end), u])
	raw.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var xs := PackedFloat32Array()
	var ids: Array = []
	for e in raw:
		if xs.is_empty() or float(e[0]) - xs[xs.size() - 1] > 0.004:
			xs.append(e[0])
			ids.append([])
		ids[ids.size() - 1].append(e[1])
	var n := xs.size()
	var zc := PackedFloat32Array()
	var xin := PackedFloat32Array()
	for k in n:
		var zs := 0.0
		var xi := INF
		for i in ids[k]:
			zs += poses[0][i].z
			xi = minf(xi, poses[0][i].x)
		zc.append(zs / (ids[k] as Array).size())
		xin.append(xi)
	# Where each station's inner edge should go: just inside the body's
	# outline, or next to the midline behind the rump.
	var target := PackedFloat32Array()
	for k in n:
		target.append(HUG_X_MIN if zc[k] > z_end else maxf(_loft_half_n(zc[k]) - HUG_TUCK, HUG_X_MIN))
	var d := PackedVector2Array()
	for k in n:
		d.append(_hug_station(ids[k], xin[k], target[k], poses, ctx))
	# The station before the rump: its chord to the next one passes the rump,
	# so it must come in far enough that the edge there is next to the body.
	for k in n - 1:
		if zc[k] <= z_end and zc[k + 1] > z_end:
			var z_r := z_end - (z_end - zc[0]) * 0.05
			var u := clampf((z_r - zc[k]) / (zc[k + 1] - zc[k]), 0.0, 0.9)
			var x_next := xin[k + 1] - d[k + 1].x
			var lim := (_loft_half_n(z_r) + HUG_RUMP_GAP - u * x_next) / (1.0 - u)
			if lim < target[k]:
				target[k] = maxf(lim, HUG_X_MIN)
				d[k] = _hug_station(ids[k], xin[k], target[k], poses, ctx)
	# Smooth along the folded wing: the inward shift only ever shrinks (always
	# safe: further out), the lift only ever grows (up and away from the back).
	var sm := PackedVector2Array()
	for k in n:
		var m := Vector2(INF, -INF)
		for j in n:
			var dz := absf(zc[k] - zc[j])
			m.x = minf(m.x, d[j].x + HUG_SLOPE * dz)
			m.y = maxf(m.y, d[j].y - HUG_SLOPE * dz)
		sm.append(m)
	return {"xs": xs, "d": sm, "plate_end": plate_end}


## The (dx, dy) of one station: for each lift, how far in it may go (outside
## the body, off the midline, beside or above the tail in every perch
## blend); the lift that gets it furthest towards its target (the smallest
## lift on a tie).
func _hug_station(ids: Array, x_in: float, target: float, poses: Array[PackedVector3Array], ctx: Array[PackedFloat32Array]) -> Vector2:
	var best := Vector2.ZERO
	var best_x := INF
	for dy: float in HUG_LIFTS:
		var room := INF
		for pi in poses.size():
			var v := poses[pi]
			var c := ctx[pi]
			for u: int in ids:
				var y := v[u].y + dy
				var lim := HUG_X_MIN
				var hh := c[u * 5 + 1]
				if hh > 0.0:
					var e := (y - c[u * 5 + 2]) / hh
					if absf(e) < 1.0:
						lim = maxf(lim, c[u * 5] * sqrt(1.0 - e * e))
				# The tail near this z blocks sideways unless we are above it.
				if y < c[u * 5 + 3] + HUG_TAIL_EPS:
					lim = maxf(lim, c[u * 5 + 4] + HUG_TAIL_EPS)
				room = minf(room, v[u].x - lim)
		var dx := clampf(x_in - target, 0.0, maxf(room, 0.0))
		if x_in - dx < best_x - 0.001:
			best_x = x_in - dx
			best = Vector2(dx, dy)
	return best


## A wing vertex's spanwise position for the hug: the plate's end for every
## slotted primary (their roots sit up to ~0.005 inboard of it).
static func _hug_x(x: float, plate_end: float) -> float:
	return plate_end if x >= plate_end - 0.012 else x


## Writes the hug table into every wing vertex (by spanwise position).
func _apply_fold_hug(tab: Dictionary) -> void:
	var xs: PackedFloat32Array = tab["xs"]
	var d: PackedVector2Array = tab["d"]
	var plate_end: float = tab["plate_end"]
	var n := xs.size()
	for i in verts.size():
		var g := int(cu0[i * 4])
		if g != BirdPose.G_ARM and g != BirdPose.G_HAND:
			continue
		# Every wing vertex lies on a station (or is a finger, which goes with
		# the plate's end): take its station's hug whole, so the plate between
		# two stations bends but never shears across its chord.
		var x := _hug_x(absf(verts[i].x), plate_end)
		var k := 0
		for j in n:
			if absf(xs[j] - x) < absf(xs[k] - x):
				k = j
		var val := d[k]
		if absf(xs[k] - x) > 0.006:
			# (Not on a station: between the two around it.)
			var j := k if xs[k] < x else maxi(k - 1, 0)
			var j2 := mini(j + 1, n - 1)
			val = d[j].lerp(d[j2], clampf((x - xs[j]) / maxf(xs[j2] - xs[j], 1e-6), 0.0, 1.0))
		uv2s[i] = val
	if _tip_index >= 0 and tip_record.size() > 7:
		tip_record[7] = uv2s[_tip_index]


func _to_final(p: Vector3) -> Vector3:
	return (p - _centre) * _scale
