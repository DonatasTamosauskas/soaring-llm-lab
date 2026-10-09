extends RefCounted
## TEST-ONLY (integration hygiene, 2026-09-27): overlapping parallel faces
## in the DRAWN valley - the surfaces that z-fight in a fixed-point depth
## buffer.
##
## depth_precision_test (round 1) casts rays through the colliders; trees,
## soft decor, window glass, trims and every piece that collides with a
## simpler shape (or not at all) are invisible to it. This scan reads the
## triangles the renderer draws: every visible GeometryInstance3D under the
## world (MeshInstance3D surfaces, MultiMesh instances), skipping
## shadow-only proxies, in world space. Two triangles FIGHT when
##  * both can be drawn at once (their visibility ranges overlap; the level
##    of detail swaps never draw two levels together),
##  * they face the same way within PARALLEL_DEG (a back-to-back pair is
##    culled one way or the other; both are counted apart, for the
##    double-sided materials),
##  * their planes are within MAX_GAP of each other, and
##  * their projections onto the plane overlap by more than MIN_AREA.
## Found by hashing each triangle into (a 3D cell of its bounding box, a cell
## of its normal, a cell of its plane offset) - inserted into every cell its
## tolerance reaches, so a pair meets in at least one - and then clipping the
## pair's projections (Sutherland-Hodgman) for the overlap area.
##
## A pair at plane gap g is within two depth steps of a D24 buffer from
## z*(g) = sqrt(g * near * 2^23) on (near = 0.06 x world_scale): the fight
## starts there. Exactly coplanar pairs (g ~ 0) fight at any distance.

const PARALLEL_DEG := 3.0
## Quest Pro pixels per steradian at the centre of the view (~20 px/deg).
const PX_PER_SR := 1.2e6
## Colours within this angle in RGB (and +-12 % in value) are one palette
## colour under MeshKit's facet jitter (_same_look).
const SAME_HUE_DEG := 2.5
const MAX_GAP := 0.30
const MIN_AREA := 1e-4
## Overlaps thinner than this (m; about 2 area / perimeter x 2) are seams.
const MIN_WIDTH := 0.005
const POS_CELL := 4.0
const BIG_CELL := 64.0
const BIG_TRI := 12.0

## Triangles: flat arrays for speed.
var ta: PackedVector3Array = []
var tb: PackedVector3Array = []
var tc: PackedVector3Array = []
var tn: PackedVector3Array = []
var td: PackedFloat64Array = []
## Which drawable each triangle belongs to, and the drawables.
var owner: PackedInt32Array = []
## The first vertex's colour (MeshKit colours by palette entry: it names the part).
var tcol: PackedColorArray = []
## 1 for triangles wider than BIG_TRI (per scan).
var big: PackedByteArray = []
var drawables: Array[Dictionary] = []
var skipped := {}


static func _pattern(path: String) -> String:
	var out := ""
	var prev := false
	for ch in path:
		if "0123456789".contains(ch):
			if not prev:
				out += "#"
			prev = true
		else:
			out += ch
			prev = false
	return out


func _add_mesh(mesh: Mesh, xf: Transform3D, di: int) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := mesh.surface_get_arrays(s)
		if arr.is_empty():
			continue
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR] if arr[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if idx.size() > 0 else v.size()
		var i := 0
		while i + 2 < count:
			var a: Vector3
			var b: Vector3
			var c: Vector3
			var vi0 := idx[i] if idx.size() > 0 else i
			if idx.size() > 0:
				a = xf * v[idx[i]]
				b = xf * v[idx[i + 1]]
				c = xf * v[idx[i + 2]]
			else:
				a = xf * v[i]
				b = xf * v[i + 1]
				c = xf * v[i + 2]
			i += 3
			# Godot's front faces wind clockwise: this is the outward normal.
			var nn := (c - a).cross(b - a)
			var l := nn.length()
			if l < 2e-6:
				continue
			nn /= l
			ta.append(a)
			tb.append(b)
			tc.append(c)
			tn.append(nn)
			td.append(nn.dot(a))
			owner.append(di)
			tcol.append(cols[vi0] if vi0 < cols.size() else Color.BLACK)
			n += 1
	return n


## Collects every drawn triangle under `root`. `max_instance_tris`: a
## MultiMesh whose mesh has more triangles than this is scanned as its mesh
## alone (in its local space: its self-overlaps) instead of every instance
## (the forest's trees).
func collect(root: Node, max_instance_tris := 400) -> void:
	for gi: Node in root.find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		var path := str(root.get_path_to(g))
		if g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			skipped["shadow_only"] = int(skipped.get("shadow_only", 0)) + 1
			continue
		if not g.is_visible_in_tree():
			skipped["hidden"] = int(skipped.get("hidden", 0)) + 1
			continue
		var r0 := g.visibility_range_begin
		var r1 := g.visibility_range_end if g.visibility_range_end > 0.0 else INF
		var d := {"path": path, "pattern": _pattern(path), "class": g.get_class(), "r0": r0, "r1": r1, "tris": 0,
			"double_sided": false, "depth_steps": 0.0}
		# A material drawn nearer by a constant number of depth steps (a
		# polygon offset through the z clip scale: Palette.paving_material)
		# wins its ties.
		if g.material_override is BaseMaterial3D and (g.material_override as BaseMaterial3D).use_z_clip_scale:
			d["depth_steps"] = (1.0 - (g.material_override as BaseMaterial3D).z_clip_scale) * 16777216.0
		var di := drawables.size()
		drawables.append(d)
		if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			d["tris"] = _add_mesh((g as MeshInstance3D).mesh, g.global_transform, di)
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh != null:
			var mm := (g as MultiMeshInstance3D).multimesh
			if mm.mesh == null:
				continue
			var per := 0
			for s in mm.mesh.get_surface_count():
				per += int(mm.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3) if mm.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] == null \
					else int((mm.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3)
			var count := mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
			if per > max_instance_tris:
				d["tris"] = _add_mesh(mm.mesh, Transform3D.IDENTITY, di)
				d["local_only"] = true
				d["instances"] = count
			else:
				var tot := 0
				for k in count:
					tot += _add_mesh(mm.mesh, g.global_transform * mm.get_instance_transform(k), di)
				d["tris"] = tot
				d["instances"] = count
		else:
			skipped[g.get_class()] = int(skipped.get(g.get_class(), 0)) + 1


static func _cells(lo: float, hi: float, size: float) -> Array[int]:
	var out: Array[int] = []
	for k in range(int(floor(lo / size)), int(floor(hi / size)) + 1):
		out.append(k)
	return out


## A point of the overlap of j's projection with triangle i, on i's plane.
func _overlap_centroid(i: int, j: int) -> Vector3:
	var poly := _overlap_poly(i, j)
	if poly.is_empty():
		return (ta[i] + tb[i] + tc[i]) / 3.0
	var c := Vector2.ZERO
	for q in poly:
		c += q
	c /= poly.size()
	var u := (tb[i] - ta[i]).normalized()
	var w := tn[i].cross(u)
	return ta[i] + u * c.x + w * c.y


## Projected overlap area of triangles i and j on i's plane.
func _overlap_area(i: int, j: int) -> float:
	var poly := _overlap_poly(i, j)
	if poly.size() < 3:
		return 0.0
	var a := 0.0
	for k in poly.size():
		a += poly[k].cross(poly[(k + 1) % poly.size()])
	return absf(a) * 0.5


## The overlap polygon (in i's plane coordinates from ta[i]).
func _overlap_poly(i: int, j: int) -> Array[Vector2]:
	var n := tn[i]
	var u := (tb[i] - ta[i]).normalized()
	var w := n.cross(u)
	var o := ta[i]
	var poly: Array[Vector2] = [Vector2((ta[j] - o).dot(u), (ta[j] - o).dot(w)), Vector2((tb[j] - o).dot(u), (tb[j] - o).dot(w)),
		Vector2((tc[j] - o).dot(u), (tc[j] - o).dot(w))]
	var clip: Array[Vector2] = [Vector2.ZERO, Vector2((tb[i] - o).dot(u), (tb[i] - o).dot(w)), Vector2((tc[i] - o).dot(u), (tc[i] - o).dot(w))]
	# Counter-clockwise clip polygon.
	if (clip[1] - clip[0]).cross(clip[2] - clip[0]) < 0.0:
		clip.reverse()
	for e in 3:
		var p0 := clip[e]
		var p1 := clip[(e + 1) % 3]
		var edge := p1 - p0
		var out: Array[Vector2] = []
		if poly.is_empty():
			return poly
		var prev := poly[poly.size() - 1]
		var prev_in := edge.cross(prev - p0) >= -1e-9
		for q in poly:
			var q_in := edge.cross(q - p0) >= -1e-9
			if q_in != prev_in:
				var dd := q - prev
				var den := edge.cross(dd)
				if absf(den) > 1e-12:
					out.append(prev + dd * (edge.cross(p0 - prev) / den))
			if q_in:
				out.append(q)
			prev = q
			prev_in = q_in
		poly = out
	return poly


## Finds the fighting pairs among the triangles `subset` (all if empty).
## Returns {"pairs": [[i, j, gap, area, same_facing]], "grid_cells": n}.
## Every triangle is entered in each POS_CELL cube its bounding box touches
## (a packed, natively sorted list of cell << 24 | triangle); the pairs are
## checked cell by cell, a pair once (in the lowest cell both touch).
func scan(subset: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var cos_par := cos(deg_to_rad(PARALLEL_DEG))
	# Normals within PARALLEL_DEG differ by at most this in any component.
	var ntol := 2.0 * sin(deg_to_rad(PARALLEL_DEG) * 0.5) + 1e-6
	var nt := ta.size()
	if subset.is_empty():
		subset.resize(nt)
		for i in nt:
			subset[i] = i
	# Two levels: small triangles in POS_CELL cubes, and every triangle in
	# BIG_CELL cubes too, where only pairs with a big one (wider than
	# BIG_TRI) are compared - a lake's or a mountain's triangle would touch
	# thousands of small cells. Level 1 cells are keyed from 1 << 34 up.
	var keys := PackedInt64Array()
	big.resize(nt)
	for i in subset:
		var lo0 := ta[i].min(tb[i]).min(tc[i]) - Vector3.ONE * (MAX_GAP * 0.5)
		var hi0 := ta[i].max(tb[i]).max(tc[i]) + Vector3.ONE * (MAX_GAP * 0.5)
		var ext := hi0 - lo0
		big[i] = 1 if maxf(ext.x, maxf(ext.y, ext.z)) > BIG_TRI else 0
		for lvl in 2:
			if lvl == 0 and big[i] == 1:
				continue
			var cs := POS_CELL if lvl == 0 else BIG_CELL
			var lo := lo0 / cs
			var hi := hi0 / cs
			for a in range(int(floor(lo.x)), int(floor(hi.x)) + 1):
				for b in range(int(floor(lo.y)), int(floor(hi.y)) + 1):
					for c in range(int(floor(lo.z)), int(floor(hi.z)) + 1):
						var cell := ((a + 1024) * 2048 + (b + 1024)) * 2048 + (c + 1024) + (lvl << 34)
						keys.append((cell << 24) | i)
	keys.sort()
	_pairs = []
	_npairs = 0
	_back_to_back = 0
	var cells := 0
	var n := keys.size()
	var k0 := 0
	var mask := (1 << 24) - 1
	while k0 < n:
		var cell := keys[k0] >> 24
		var k1 := k0
		while k1 < n and (keys[k1] >> 24) == cell:
			k1 += 1
		cells += 1
		var lvl1 := (cell >> 34) == 1
		if lvl1:
			var any_big := false
			for p0 in range(k0, k1):
				if big[keys[p0] & mask] == 1:
					any_big = true
					break
			if not any_big:
				k0 = k1
				continue
		# Binned by the canonical normal (bins ntol wide in its x and y): a
		# triangle meets only those in the 3 x 3 bins round its own.
		var bins := {}
		var order: Array = []
		for p0 in range(k0, k1):
			var t := keys[p0] & mask
			var cn := _canon(tn[t])
			var bk := Vector2i(roundi(cn.x / ntol), roundi(cn.y / ntol))
			order.append([t, bk])
			if lvl1:
				var bl: Array = bins.get(bk, [])
				if bl.is_empty():
					bins[bk] = bl
				bl.append(t)
		for e: Array in order:
			var i: int = e[0]
			var bk: Vector2i = e[1]
			if lvl1 and big[i] == 0:
				continue
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					var bl: Variant = bins.get(bk + Vector2i(dx, dy))
					if bl == null:
						continue
					for j: int in bl:
						if lvl1:
							# A big triangle against every other (a big pair once).
							if j == i or (big[j] == 1 and j < i):
								continue
						_check(i, j, cell, 1 if lvl1 else 0, cos_par)
			if not lvl1:
				var own: Array = bins.get(bk, [])
				if own.is_empty():
					bins[bk] = own
				own.append(i)
		k0 = k1
	return {"pairs": _pairs, "grid_cells": cells, "count": _npairs, "back_to_back": _back_to_back}


var _pairs := []
var _npairs := 0
var _back_to_back := 0


func _check(i: int, j: int, cell: int, lvl: int, cos_par: float) -> void:
	var ni := tn[i]
	var dot := ni.dot(tn[j])
	if absf(dot) < cos_par:
		return
	# The gap: the other triangle's corners from this one's plane.
	var g1 := maxf(absf(ni.dot(ta[j]) - td[i]), maxf(absf(ni.dot(tb[j]) - td[i]), absf(ni.dot(tc[j]) - td[i])))
	if g1 > MAX_GAP:
		return
	var di: Dictionary = drawables[owner[i]]
	var dj: Dictionary = drawables[owner[j]]
	if (di.get("local_only", false) or dj.get("local_only", false)) and owner[i] != owner[j]:
		return
	if maxf(di["r0"], dj["r0"]) >= minf(di["r1"], dj["r1"]):
		return
	# Counted once: in the lowest cell both boxes touch.
	if _first_common_cell(i, j, lvl) != cell:
		return
	# Two faces that share an edge lie either side of it (a tube's pieces,
	# a folded terrain): their projections only touch along it.
	if _shared_corners(i, j) >= 2:
		return
	var poly := _overlap_poly(i, j)
	if poly.size() < 3:
		return
	var area := 0.0
	var perim := 0.0
	for k in poly.size():
		area += poly[k].cross(poly[(k + 1) % poly.size()])
		perim += poly[k].distance_to(poly[(k + 1) % poly.size()])
	area = absf(area) * 0.5
	if area < MIN_AREA:
		return
	# A hairline (two pieces meeting end to end at a slight angle overlap by
	# a sliver along their seam): it blurs a line, like any crossing, and is
	# no patch - skipped when the overlap is thinner than MIN_WIDTH.
	if 2.0 * area / maxf(perim, 1e-9) < MIN_WIDTH * 0.5:
		return
	_npairs += 1
	# Back to back (opposite normals): every world surface is drawn with
	# back faces culled (Palette's shaders; the soft decor's double-sided
	# cards are not scanned), so from any viewpoint one of the two is gone.
	if dot < 0.0:
		_back_to_back += 1
		return
	# Same facing: the one further along the normal is in front.
	var front := i
	var back := j
	if tn[i].dot(ta[j]) > td[i]:
		front = j
		back = i
	_pairs.append([front, back, g1, area, true, _overlap_centroid(front, back)])


## The palette entry nearest a vertex colour (what a part is made of).
static func colour_name(col: Color) -> String:
	var best := ""
	var bd := INF
	for k: StringName in Palette.C:
		var pc: Color = Palette.C[k]
		var d := Vector3(pc.r - col.r, pc.g - col.g, pc.b - col.b).length()
		if d < bd:
			bd = d
			best = String(k)
	return best if bd < 0.06 else "%s~" % best


## Whether a point on a face can be seen: from 2 m and from 30 m away, along
## its normal and eight directions tilted 35 and 65 deg off it, a ray cast
## back at the point (front faces only: a point inside a solid is hidden by
## the solid's outer faces) first meets the world within 2 cm of it. (A ray
## that starts inside a solid does not see its back faces and can pass.)
static func _visible(world: World, space: PhysicsDirectSpaceState3D, p: Vector3, n: Vector3) -> bool:
	var t := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var b := n.cross(t)
	var dirs: Array[Vector3] = [n]
	for k in 4:
		var a := k * PI / 2.0
		var side := t * cos(a) + b * sin(a)
		dirs.append((n * cos(deg_to_rad(35.0)) + side * sin(deg_to_rad(35.0))).normalized())
		dirs.append((n * cos(deg_to_rad(65.0)) + side * sin(deg_to_rad(65.0))).normalized())
	for r: float in [2.0, 30.0]:
		for d in dirs:
			var eye := p + d * r
			# A viewer is in the air: never under the ground.
			if eye.y < world.ground_height(eye.x, eye.z) + 0.05:
				continue
			var q := PhysicsRayQueryParameters3D.create(eye, p - d * 0.01, 1)
			var h := space.intersect_ray(q)
			if h.is_empty() or (h["position"] as Vector3).distance_to(p) < 0.02:
				return true
	return false


## Two vertex colours that are one palette colour under MeshKit's facet
## jitter (Palette.vary by up to +-5 % in value): the same hue within
## SAME_HUE and a value ratio within +-12 %.
static func _same_look(c1: Color, c2: Color) -> bool:
	var v1 := Vector3(c1.r, c1.g, c1.b)
	var v2 := Vector3(c2.r, c2.g, c2.b)
	if v1.length() < 0.02 or v2.length() < 0.02:
		return (v1 - v2).length() < 0.02
	var ratio := v1.length() / v2.length()
	return v1.normalized().dot(v2.normalized()) > cos(deg_to_rad(SAME_HUE_DEG)) and ratio > 0.88 and ratio < 1.14


## Collects, scans and judges (see the header): the fighting patches by
## owner pair at the near plane `near`, with totals. `verbose` prints them.
func analyze(world: World, near: float, verbose := true) -> Dictionary:
	collect(world)
	var t0 := Time.get_ticks_msec()
	var res := scan_all()
	print("[integration] coplanar: %d overlapping parallel pairs within %.2f m (%d back to back, culled; %d facing the same way) in %d ms (%d triangles scanned together)" % [
		res["count"], MAX_GAP, res["back_to_back"], res["pairs"].size(), Time.get_ticks_msec() - t0, res["shared_tris"]])
	# Same-facing pairs whose FRONT face can be seen (_visible; the trees',
	# hedges' and far stand-ins' drawn faces collide with simpler shapes or
	# not at all: counted as seen). Their back partner lies `gap` behind:
	# they fight where two depth steps reach the gap, from z*(gap) on. A
	# patch (the pairs of one owner pair in a 0.5 m cell) is SEEN FIGHTING
	# if at z* it still covers a pixel: area x PX_PER_SR / z*^2 >= 1 (beyond
	# z* it only shrinks). Exact overlaps (<= 1 mm) fight at any distance.
	var space := world.get_world_3d().direct_space_state
	var by := {}
	var vis_n := 0
	var same_look := 0
	var offset_settled := 0
	var few := []
	for pr: Array in res["pairs"]:
		var f: int = pr[0]
		var n: Vector3 = tn[f]
		var p: Vector3 = pr[5]
		var a: String = drawables[owner[f]]["pattern"]
		var b: String = drawables[owner[pr[1]]]["pattern"]
		var parts := "%s/%s" % [colour_name(tcol[f]), colour_name(tcol[pr[1]])]
		var stand_in := a.contains("trees_") or a.contains("_lod") or a.contains("_far")
		# Two surfaces of one colour facing the same way look the same whichever
		# wins a pixel: their fight cannot be seen (a trunk piece's end inside
		# the next piece of the same bark).
		var c1: Color = tcol[f]
		var c2: Color = tcol[pr[1]]
		if _same_look(c1, c2):
			same_look += 1
			continue
		# The front face drawn with a depth offset over another body's face:
		# the offset settles the tie at every distance.
		if float(drawables[owner[f]]["depth_steps"]) > 0.0 and owner[f] != owner[pr[1]]:
			offset_settled += 1
			continue
		var seen := stand_in or _visible(world, space, p, n)
		var k := "%s over %s" % [a, b]
		var e: Dictionary = by.get(k, {"visible": 0, "hidden": 0, "area": 0.0, "min_gap": INF, "spots": {}, "at": []})
		if not seen:
			e["hidden"] += 1
			by[k] = e
			continue
		vis_n += 1
		e["visible"] += 1
		e["area"] += pr[3]
		var g: float = pr[2]
		e["min_gap"] = minf(e["min_gap"], g)
		var cell := Vector3i((p / 0.5).floor())
		var sp: Array = e["spots"].get(cell, [0.0, INF, ""])
		sp[0] += pr[3]
		if g < sp[1]:
			sp[1] = g
			sp[2] = "(%.2f, %.2f, %.2f) n(%.2f, %.2f, %.2f) %s" % [p.x, p.y, p.z, n.x, n.y, n.z, parts]
		e["spots"][cell] = sp
		if g <= 0.005:
			var pt: Dictionary = e.get("parts5", {})
			pt[parts] = int(pt.get(parts, 0)) + 1
			e["parts5"] = pt
		by[k] = e
		if g <= 0.005 and few.size() < 4000:
			var b2: int = pr[1]
			few.append({"front": a, "back": b, "p": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
				"n": [snappedf(n.x, 0.01), snappedf(n.y, 0.01), snappedf(n.z, 0.01)], "gap": snappedf(g, 0.0001),
				"area": snappedf(float(pr[3]), 0.0001), "tri_front": [ta[f], tb[f], tc[f]].map(func(v: Vector3) -> Array: return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]),
				"tri_back": [ta[b2], tb[b2], tc[b2]].map(func(v: Vector3) -> Array: return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)])})
	var keys := by.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return float(by[x]["area"]) > float(by[y]["area"]))
	var out := {}
	var tot := {"exact_spots": 0, "mm5_spots": 0, "mm5_seen_spots": 0, "cm30_seen_spots": 0}
	var onset := {}
	for k: String in keys:
		var e: Dictionary = by[k]
		if e["visible"] == 0:
			continue
		var row := {"visible_pairs": e["visible"], "hidden_pairs": e["hidden"], "area_m2": snappedf(e["area"], 0.001),
			"spots": e["spots"].size(), "min_gap_m": snappedf(e["min_gap"], 0.0001), "exact_spots": 0, "mm5_spots": 0,
			"mm5_seen_spots": 0, "seen_spots": 0, "worst": []}
		var worst := []
		for c in e["spots"]:
			var sp: Array = e["spots"][c]
			var g: float = sp[1]
			var zf := sqrt(maxf(g, 0.0) * near * 8388608.0)
			var px := INF if g <= 1e-4 else float(sp[0]) * PX_PER_SR / (zf * zf)
			if g <= 0.001:
				row["exact_spots"] += 1
			if g <= 0.005:
				row["mm5_spots"] += 1
				if px >= 1.0:
					row["mm5_seen_spots"] += 1
			if px >= 1.0:
				row["seen_spots"] += 1
				var bk := "from <50 m" if zf < 50.0 else ("from 50-100 m" if zf < 100.0 else ("from 100-150 m" if zf < 150.0 else "from >=150 m"))
				onset[bk] = int(onset.get(bk, 0)) + 1
				worst.append([px, "%s gap %.4f m, %.4f m2, fights from %.0f m over %s px" % [sp[2], g, sp[0], zf, "all" if is_inf(px) else "%.0f" % px]])
		worst.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
		row["worst"] = worst.slice(0, 6).map(func(w: Array) -> String: return w[1])
		row["parts_within_5mm"] = e.get("parts5", {})
		for kk in ["exact_spots", "mm5_spots", "mm5_seen_spots"]:
			tot[kk] += int(row[kk])
		tot["cm30_seen_spots"] += int(row["seen_spots"])
		out[k] = row
		if verbose:
			print("[integration]   %-62s %6d seen pairs (%d hidden) %9.3f m2, %5d spots: exact %d, <=5 mm %d (%d seen fighting), all gaps seen fighting %d; least gap %.4f m  %s" % [
				k, e["visible"], e["hidden"], e["area"], e["spots"].size(), row["exact_spots"], row["mm5_spots"], row["mm5_seen_spots"],
				row["seen_spots"], e["min_gap"], row["worst"].slice(0, 2)])
	print("[integration] coplanar: %d same-facing pairs of one colour (their fight looks like nothing), %d settled by a depth offset" % [same_look, offset_settled])
	print("[integration] coplanar: %d same-facing pairs seen; spots: exact %d, within 5 mm %d (%d seen fighting at a sparrow's near plane), any gap to %.2f m seen fighting %d" % [
		vis_n, tot["exact_spots"], tot["mm5_spots"], tot["mm5_seen_spots"], MAX_GAP, tot["cm30_seen_spots"]])
	print("[integration] coplanar: seen fighting spots by where the fight starts (near %.4f m): %s" % [near, onset])
	return {"triangles": ta.size(), "drawables": drawables.size(), "near": near,
		"overlapping_parallel": res["count"], "back_to_back": res["back_to_back"], "same_facing": res["pairs"].size(),
		"same_colour": same_look, "offset_settled": offset_settled, "seen_same_facing": vis_n, "totals": tot, "seen_by_onset": onset, "by_owner": out,
		"within_5mm_samples": few}


## Pairs kept for the record (the tally counts them all).
const MAX_KEPT := 20000
## owner pair -> {pairs, area, min_gap, max_gap, at, gaps: [<=1mm, <=5mm, <=1cm, <=5cm, <=30cm]}
var tally := {}


func _tally(pr: Array) -> void:
	var a: String = drawables[owner[pr[0]]]["pattern"]
	var b: String = drawables[owner[pr[1]]]["pattern"]
	var k := "%s | %s | %s" % [a if a < b else b, b if a < b else a, "same" if pr[4] else "back-to-back"]
	var e: Dictionary = tally.get(k, {"pairs": 0, "area": 0.0, "min_gap": INF, "max_gap": 0.0, "at": "", "gaps": [0, 0, 0, 0, 0],
		"area_by_gap": [0.0, 0.0, 0.0, 0.0, 0.0]})
	e["pairs"] += 1
	e["area"] += pr[3]
	var g: float = pr[2]
	var bi := 0 if g <= 0.001 else (1 if g <= 0.005 else (2 if g <= 0.01 else (3 if g <= 0.05 else 4)))
	e["gaps"][bi] += 1
	e["area_by_gap"][bi] += pr[3]
	if g < e["min_gap"]:
		e["min_gap"] = g
		var c := (ta[pr[0]] + tb[pr[0]] + tc[pr[0]]) / 3.0
		e["at"] = "(%.1f, %.2f, %.1f)" % [c.x, c.y, c.z]
	e["max_gap"] = maxf(e["max_gap"], g)
	tally[k] = e


static func _canon(n: Vector3) -> Vector3:
	if n.y < -1e-6 or (absf(n.y) <= 1e-6 and (n.x < -1e-6 or (absf(n.x) <= 1e-6 and n.z < 0.0))):
		return -n
	return n


func _shared_corners(i: int, j: int) -> int:
	var n := 0
	for p: Vector3 in [ta[i], tb[i], tc[i]]:
		for q: Vector3 in [ta[j], tb[j], tc[j]]:
			if p.distance_squared_to(q) < 1e-8:
				n += 1
				break
	return n


func _first_common_cell(i: int, j: int, lvl: int) -> int:
	var cs := POS_CELL if lvl == 0 else BIG_CELL
	var lo := ((ta[i].min(tb[i]).min(tc[i])).max(ta[j].min(tb[j]).min(tc[j])) - Vector3.ONE * (MAX_GAP * 0.5)) / cs
	var hi := ((ta[i].max(tb[i]).max(tc[i])).min(ta[j].max(tb[j]).max(tc[j])) + Vector3.ONE * (MAX_GAP * 0.5)) / cs
	var a := int(floor(lo.x))
	var b := int(floor(lo.y))
	var c := int(floor(lo.z))
	if int(floor(hi.x)) < a or int(floor(hi.y)) < b or int(floor(hi.z)) < c:
		return -1
	return ((a + 1024) * 2048 + (b + 1024)) * 2048 + (c + 1024) + (lvl << 34)


## Triangles by drawable: the trees' chunk meshes are scanned one by one
## (only their own parts can overlap: a crown never lies flat on another
## tree's), everything else together.
func scan_all(tree_prefixes: Array = ["trees_"]) -> Dictionary:
	var shared := PackedInt32Array()
	var per := {}
	for i in ta.size():
		var d: Dictionary = drawables[owner[i]]
		# Foliage cards, reeds, clouds and motes (soft decor): alpha-cut,
		# double-sided cards that cross each other by design, not surfaces.
		if String(d["path"]).begins_with("Soft/"):
			continue
		var own: bool = d.get("local_only", false)
		for pf: String in tree_prefixes:
			if String(d["path"]).get_file().begins_with(pf):
				own = true
		if own:
			if not per.has(owner[i]):
				per[owner[i]] = []
			(per[owner[i]] as Array).append(i)
		else:
			shared.append(i)
	var t0 := Time.get_ticks_msec()
	var res := scan(shared)
	print("[integration] coplanar: shared set %d triangles, %d pairs in %d ms" % [shared.size(), res["count"], Time.get_ticks_msec() - t0])
	var cells: int = res["grid_cells"]
	for o in per:
		var r2 := scan(PackedInt32Array(per[o]))
		res["pairs"].append_array(r2["pairs"])
		res["count"] += int(r2["count"])
		res["back_to_back"] += int(r2["back_to_back"])
		cells += int(r2["grid_cells"])
	res["grid_cells"] = cells
	res["shared_tris"] = shared.size()
	return res


## Per pair of owners (path patterns): count, overlap area, gaps, and the
## view depth from which the least gap is within two D24 steps at `near`.
func summarize(_pairs: Array, near: float) -> Dictionary:
	for k in tally:
		tally[k]["fight_from_m"] = sqrt(maxf(tally[k]["min_gap"], 0.0) * near * 8388608.0)
	return tally
