extends TestCase
## Verifier probe, round 4 (experience & requirements lens) for the world.
##
##   tools/gd.sh world_r4exp --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=r4exp
##
## Angles no earlier round (builder suite, r1-r3 probes) covered:
## - W8 "no z-fighting" is only checked by eye: a structural detector over
##   every drawn full-detail triangle (coplanar, same-facing, overlapping,
##   differently coloured pairs), self-checked on synthetic triangles;
## - the rooms were furnished after the last verification: every window line
##   (rated body, and a sparrow anywhere in the aperture) must cross the room;
## - thermals used from low down: the lowest height at which a sparrow's,
##   a crow's and an eagle's 30-degree circle is both clear and lifting;
## - ridge soaring along the whole cliff (the builder plotted one slice);
## - where a perched bird takes off: AI turns perched birds to face
##   `facing` and leaves along it, so the way out in front must be open;
## - physics query cost per district (AI avoidance rays/casts on Quest);
## - fresh seeds never tested by anyone (incl. a negative and a 2^53 seed).
## Prints "[world-r4] ..." lines; numbers land in report metrics.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	world.with_decoration = false
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


# --- physics helpers -----------------------------------------------------------

func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	q.hit_back_faces = true
	return space.intersect_ray(q)


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


func _overlap_names(c: Vector3, r: float) -> PackedStringArray:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	var out: PackedStringArray = []
	for h in space.intersect_shape(q, 4):
		out.append(str((h["collider"] as Node).name))
	return out


func _fits(from: Vector3, to: Vector3, r: float) -> bool:
	return _overlap_names(from, r).is_empty() and _cast(from, to, r) >= 1.0


## Marches a sphere from a to b in short casts (a bird moves < 1 m a tick).
func _march(a: Vector3, b: Vector3, r: float, step := 2.0) -> float:
	var L := a.distance_to(b)
	if L < 1e-4:
		return 1.0
	var d := (b - a) / L
	var flown := 0.0
	while flown < L:
		var s := minf(step, L - flown)
		var f := _cast(a + d * flown, a + d * (flown + s), r)
		if f < 1.0:
			return (flown + s * f) / L
		flown += s
	return 1.0


# --- 1. z-fighting: coplanar overlapping faces of different colour -------------

const ZF_NQ := 60.0          # normal bins: 1/60 per component (~1 deg)
const ZF_DQ := 100.0         # plane-offset bins: 1 cm
const ZF_HARD := 0.001       # |plane offset| <= 1 mm: z-fights on any depth buffer
const ZF_SOFT := 0.01        # 1 mm .. 1 cm: an overlay that shimmers at range on 24-bit depth
const ZF_MIN_AREA := 0.0004  # 4 cm^2 of overlap (ignores slivers along shared edges)
const ZF_COL := 0.03         # colour difference that shows


## Triangle soup: world-space vertices, unit normal, plane offset, colour, owner.
## (A class, not a Dictionary: packed arrays read out of a Dictionary are
## copies, so appending to them would be lost.)
class Soup:
	var a := PackedVector3Array()
	var b := PackedVector3Array()
	var c := PackedVector3Array()
	var n := PackedVector3Array()
	var d := PackedFloat32Array()
	var col := PackedColorArray()
	var src := PackedInt32Array()
	var names: Array = []
	var skipped: PackedStringArray = []

	func add(pa: Vector3, pb: Vector3, pc: Vector3, colour: Color, owner: int) -> void:
		var nn := (pb - pa).cross(pc - pa)
		var l := nn.length()
		if l < 1e-7:
			return
		nn /= l
		a.append(pa)
		b.append(pb)
		c.append(pc)
		n.append(nn)
		d.append(nn.dot(pa))
		col.append(colour)
		src.append(owner)


## Every drawn full-detail triangle (no stand-ins, no shadow-only proxies,
## no hidden far terrain). Soft decoration is off in this world.
func _collect_drawn(trees_only: bool) -> Soup:
	var soup := Soup.new()
	var visual := world.get_node("Visual")
	var stack: Array[Node] = [visual]
	var skipped: PackedStringArray = []
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for ch in nd.get_children():
			stack.append(ch)
		var mi := nd as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if not mi.visible or mi.has_meta(&"shadow_only") \
				or mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
				or mi.visibility_range_begin > 0.0:
			continue
		var nm := str(mi.name)
		if nm.begins_with("trees") != trees_only:
			skipped.append(nm)
			continue
		var src: int = soup.names.size()
		soup.names.append(nm)
		var xf := mi.global_transform
		var m := mi.mesh
		for s in m.get_surface_count():
			var arr := m.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR] if arr[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var wv := PackedVector3Array()
			wv.resize(v.size())
			for i in v.size():
				wv[i] = xf * v[i]
			var nt := (idx.size() if not idx.is_empty() else v.size()) / 3
			for t in nt:
				var i0 := idx[t * 3] if not idx.is_empty() else t * 3
				var i1 := idx[t * 3 + 1] if not idx.is_empty() else t * 3 + 1
				var i2 := idx[t * 3 + 2] if not idx.is_empty() else t * 3 + 2
				var col := cols[i0] if not cols.is_empty() else Color.WHITE
				# Godot's front faces are clockwise seen from the front: the
				# outward normal is (c - a) x (b - a); the bins only need a
				# consistent sign, so the order here is irrelevant.
				soup.add(wv[i0], wv[i1], wv[i2], col, src)
	soup.skipped = skipped
	return soup


static func _poly_area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		var a := p[i]
		var b := p[(i + 1) % p.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


## Area of the overlap of two convex CCW polygons (Sutherland-Hodgman).
static func _clip_area(subject: PackedVector2Array, clip: PackedVector2Array) -> float:
	var poly := _clip_poly(subject, clip)
	return absf(_poly_area(poly)) if poly.size() >= 3 else 0.0


## The overlap polygon itself.
static func _clip_poly(subject: PackedVector2Array, clip: PackedVector2Array) -> PackedVector2Array:
	var out := subject
	for i in clip.size():
		if out.is_empty():
			return out
		var e0 := clip[i]
		var e1 := clip[(i + 1) % clip.size()]
		var inp := out
		out = PackedVector2Array()
		for j in inp.size():
			var cur := inp[j]
			var prv := inp[(j + inp.size() - 1) % inp.size()]
			var cin := (e1 - e0).cross(cur - e0) >= 0.0
			var pin := (e1 - e0).cross(prv - e0) >= 0.0
			if cin:
				if not pin:
					out.append(_seg_x(prv, cur, e0, e1))
				out.append(cur)
			elif pin:
				out.append(_seg_x(prv, cur, e0, e1))
	return out


static func _seg_x(p: Vector2, q: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var r := q - p
	var s := b - a
	var den := r.cross(s)
	if absf(den) < 1e-12:
		return p
	var t := (a - p).cross(s) / den
	return p + r * t


func _tri2(soup: Soup, i: int, u: Vector3, v: Vector3) -> PackedVector2Array:
	var a: Vector3 = soup.a[i]
	var b: Vector3 = soup.b[i]
	var c: Vector3 = soup.c[i]
	var p := PackedVector2Array([Vector2(a.dot(u), a.dot(v)), Vector2(b.dot(u), b.dot(v)), Vector2(c.dot(u), c.dot(v))])
	if _poly_area(p) < 0.0:
		p.reverse()
	return p


## Finds coplanar (|offset| <= ZF_SOFT), same-facing, overlapping triangle
## pairs of different colour. Returns {hard, soft, hard_area, soft_area,
## examples_hard, examples_soft, pairs_tested}.
func _zfight_scan(soup: Soup) -> Dictionary:
	var ns: PackedVector3Array = soup.n
	var ds: PackedFloat32Array = soup.d
	var cs: PackedColorArray = soup.col
	var srcs: PackedInt32Array = soup.src
	var names: Array = soup.names
	var bins := {}
	for i in ns.size():
		var n := ns[i]
		var key := Vector4i(roundi(n.x * ZF_NQ), roundi(n.y * ZF_NQ), roundi(n.z * ZF_NQ), floori(ds[i] * ZF_DQ))
		if not bins.has(key):
			bins[key] = []
		(bins[key] as Array).append(i)
	var res := {"hard": 0, "soft": 0, "hard_area": 0.0, "soft_area": 0.0, "exact": 0, "exact_area": 0.0, "pressed": 0, "cross_hard": 0,
		"examples_hard": [], "examples_soft": [], "pairs_tested": 0, "by_pair_hard": {}, "by_pair_soft": {},
		"clusters_exact": {}, "clusters_hard": {}, "exact_list": {}}
	for key: Vector4i in bins:
		var own: Array = bins[key]
		var nb: Array = bins.get(Vector4i(key.x, key.y, key.z, key.w + 1), [])
		if own.size() + nb.size() < 2:
			continue
		var n0: Vector3 = ns[own[0]]
		var u := n0.cross(Vector3.UP if absf(n0.y) < 0.9 else Vector3.RIGHT).normalized()
		var v := n0.cross(u)
		# Candidates: own x own (i < j) and own x next bin.
		var all: Array = own.duplicate()
		all.append_array(nb)
		var n_own := own.size()
		# 2D boxes for a sweep over u.
		var boxes := []
		for li in all.size():
			var t: int = all[li]
			var p := _tri2(soup, t, u, v)
			var mn := Vector2(minf(p[0].x, minf(p[1].x, p[2].x)), minf(p[0].y, minf(p[1].y, p[2].y)))
			var mx := Vector2(maxf(p[0].x, maxf(p[1].x, p[2].x)), maxf(p[0].y, maxf(p[1].y, p[2].y)))
			boxes.append([mn.x, mx.x, mn.y, mx.y, li, p])
		boxes.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
		var active := []
		for bx: Array in boxes:
			var keep := []
			for ac: Array in active:
				if ac[1] > bx[0]:
					keep.append(ac)
			active = keep
			for ac: Array in active:
				var la: int = ac[4]
				var lb: int = bx[4]
				# Pairs inside the next bin are that bin's business.
				if la >= n_own and lb >= n_own:
					continue
				if ac[3] <= bx[2] or bx[3] <= ac[2]:
					continue
				var ti: int = all[la]
				var tj: int = all[lb]
				var ci := cs[ti]
				var cj := cs[tj]
				var dc := maxf(absf(ci.r - cj.r), maxf(absf(ci.g - cj.g), absf(ci.b - cj.b)))
				if dc < ZF_COL:
					continue
				if ns[ti].dot(ns[tj]) < 0.9998:
					continue
				var off := absf(ds[ti] - ds[tj])
				if off > ZF_SOFT:
					continue
				res["pairs_tested"] = int(res["pairs_tested"]) + 1
				var ov := _clip_poly(ac[5], bx[5])
				var area := absf(_poly_area(ov)) if ov.size() >= 3 else 0.0
				if area < ZF_MIN_AREA:
					continue
				# Pressed against an opposite-facing coplanar face (a box
				# standing on a floor, legs on a rug): both point into a
				# solid and are never seen.
				if _pressed(bins, soup, key, ds[ti], ov, area, u, v):
					res["pressed"] = int(res["pressed"]) + 1
					continue
				var hard := off <= ZF_HARD
				var cls := "hard" if hard else "soft"
				# Two draw calls: their order is not fixed, so these flicker.
				if hard and srcs[ti] != srcs[tj]:
					res["cross_hard"] = int(res["cross_hard"]) + 1
				var ctr2 := Vector2.ZERO
				for q2 in ov:
					ctr2 += q2 / ov.size()
				var ctr := n0 * ds[ti] + u * ctr2.x + v * ctr2.y
				var ck := "%s @ %s" % [names[srcs[ti]], str(ctr.snapped(Vector3.ONE * 0.5))]
				if off <= 0.00005:
					res["exact"] = int(res["exact"]) + 1
					res["exact_area"] = float(res["exact_area"]) + area
					var ce: Dictionary = res["clusters_exact"]
					ce[ck] = snappedf(float(ce.get(ck, 0.0)) + area, 0.0001)
					# Outward normal: MeshKit stores clockwise front faces, so
					# it is minus (b - a) x (c - a).
					var el: Dictionary = res["exact_list"]
					if not el.has(ck) or float(el[ck]["area"]) < area:
						el[ck] = {"mesh": names[srcs[ti]], "centre": [ctr.x, ctr.y, ctr.z], "normal": [-ns[ti].x, -ns[ti].y, -ns[ti].z],
							"area": area, "cols": [cs[ti].to_html(false), cs[tj].to_html(false)]}
				if hard:
					var chd: Dictionary = res["clusters_hard"]
					chd[ck] = snappedf(float(chd.get(ck, 0.0)) + area, 0.0001)
				res[cls] = int(res[cls]) + 1
				res[cls + "_area"] = float(res[cls + "_area"]) + area
				var pk := "%s|%s" % [names[srcs[ti]], names[srcs[tj]]]
				var bp: Dictionary = res["by_pair_" + cls]
				bp[pk] = int(bp.get(pk, 0)) + 1
				var ex: Array = res["examples_" + cls]
				if ex.size() < 12:
					var a: Vector3 = soup.a[ti]
					ex.append("%s vs %s at (%.2f, %.2f, %.2f) n=(%.2f,%.2f,%.2f) off %.4f m area %.4f m2 cols %s/%s" % [
						names[srcs[ti]], names[srcs[tj]], a.x, a.y, a.z, ns[ti].x, ns[ti].y, ns[ti].z, off, area,
						ci.to_html(false), cj.to_html(false)])
			active.append(bx)
	return res


## True when an opposite-facing face in the same plane covers at least half
## of the overlap polygon ov (2D in the u, v basis of the plane n0 . x = d).
func _pressed(bins: Dictionary, soup: Soup, key: Vector4i, d: float, ov: PackedVector2Array, area: float, u: Vector3, v: Vector3) -> bool:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for q in ov:
		mn = mn.min(q)
		mx = mx.max(q)
	var od := -d
	for dd in [-1, 0, 1]:
		var ok := Vector4i(-key.x, -key.y, -key.z, floori(od * ZF_DQ) + dd)
		if not bins.has(ok):
			continue
		for t: int in bins[ok]:
			if absf(soup.d[t] - od) > ZF_HARD:
				continue
			var p := _tri2(soup, t, u, v)
			var tmn := p[0].min(p[1]).min(p[2])
			var tmx := p[0].max(p[1]).max(p[2])
			if tmx.x <= mn.x or tmn.x >= mx.x or tmx.y <= mn.y or tmn.y >= mx.y:
				continue
			if _clip_area(ov, p) >= area * 0.5:
				return true
	return false


func _save_exact(file: String, lst: Dictionary) -> void:
	var out := Paths.artifacts("world").path_join("verify").path_join("r4exp")
	DirAccess.make_dir_recursive_absolute(out)
	var f := FileAccess.open(out.path_join(file), FileAccess.WRITE)
	f.store_string(JSON.stringify(lst.values(), "  "))
	f.close()


func test_zfight_detector_self_check() -> void:
	# Two overlapping squares in one plane (different colours) must be found;
	# the same pair 5 cm apart must not; an adjacent (edge-sharing) pair of
	# different colours must not; a same-colour overlap must not.
	var soup := Soup.new()
	soup.names = ["probe_a", "probe_b"]
	var red := Color(0.8, 0.2, 0.2)
	var blue := Color(0.2, 0.2, 0.8)
	var q := func(o: Vector3, s: float, col: Color, src: int) -> void:
		soup.add(o, o + Vector3(s, 0, 0), o + Vector3(s, 0, s), col, src)
		soup.add(o, o + Vector3(s, 0, s), o + Vector3(0, 0, s), col, src)
	q.call(Vector3(0, 1.0, 0), 1.0, red, 0)
	q.call(Vector3(0.5, 1.0, 0.5), 1.0, blue, 1)          # coplanar overlap: hard
	q.call(Vector3(10, 2.0, 0), 1.0, red, 0)
	q.call(Vector3(10.2, 2.05, 0.2), 1.0, blue, 1)        # 5 cm apart: neither
	q.call(Vector3(20, 3.0, 0), 1.0, red, 0)
	q.call(Vector3(21, 3.0, 0), 1.0, blue, 1)             # edge-sharing: neither
	q.call(Vector3(30, 4.0, 0), 1.0, red, 0)
	q.call(Vector3(30.3, 4.004, 0.3), 1.0, blue, 1)       # 4 mm overlay: soft
	q.call(Vector3(40, 5.0, 0), 1.0, red, 0)
	q.call(Vector3(40.3, 5.0, 0.3), 1.0, red, 1)          # same colour: neither
	# Pressed: two down-facing bottoms on an up-facing floor top: hidden.
	q.call(Vector3(50, 6.0, 0), 1.0, red, 0)
	q.call(Vector3(50.3, 6.0, 0.3), 1.0, blue, 1)
	var fo := Vector3(49, 6.0, -1)
	soup.add(fo, fo + Vector3(0, 0, 4), fo + Vector3(4, 0, 4), Color(0.5, 0.5, 0.5), 0)
	soup.add(fo, fo + Vector3(4, 0, 4), fo + Vector3(4, 0, 0), Color(0.5, 0.5, 0.5), 0)
	var res := _zfight_scan(soup)
	gt(float(res["pressed"]), 0.0, "detector recognises faces pressed against a floor")
	gt(float(res["hard"]), 0.0, "detector finds a coplanar overlap of two colours")
	gt(float(res["soft"]), 0.0, "detector finds a 4 mm overlay")
	near(float(res["hard_area"]), 0.25, 0.01, "overlap area of the coplanar squares is 0.5 x 0.5 m")
	near(float(res["soft_area"]), 0.49, 0.01, "overlap area of the 4 mm overlay is 0.7 x 0.7 m")
	var found_far := false
	for e: String in res["examples_hard"] + res["examples_soft"]:
		if e.contains("(10.") or e.contains("(20.") or e.contains("(21.") or e.contains("(40.") or e.contains("(50."):
			found_far = true
	check(not found_far, "detector ignores offset, edge-sharing and same-colour pairs")


func test_no_zfighting_in_drawn_geometry() -> void:
	var t0 := Time.get_ticks_msec()
	var soup := _collect_drawn(false)
	var t1 := Time.get_ticks_msec()
	var res := _zfight_scan(soup)
	var t2 := Time.get_ticks_msec()
	var ntri := soup.n.size()
	print("[world-r4] z-fight scan (kits+terrain+water, no trees): %d triangles from %d meshes, collect %d ms, scan %d ms" % [
		ntri, soup.names.size(), t1 - t0, t2 - t1])
	print("[world-r4]   hard (<= 1 mm) pairs %d, area %.3f m2; soft (1 mm-1 cm) pairs %d, area %.3f m2" % [
		res["hard"], res["hard_area"], res["soft"], res["soft_area"]])
	print("[world-r4]   exact (<= 0.05 mm) visible pairs %d area %.3f m2; pressed (hidden) pairs skipped %d" % [res["exact"], res["exact_area"], res["pressed"]])
	print("[world-r4]   exact clusters: ", res["clusters_exact"])
	print("[world-r4]   hard clusters: ", res["clusters_hard"])
	print("[world-r4]   hard by mesh pair: ", res["by_pair_hard"])
	print("[world-r4]   soft by mesh pair: ", res["by_pair_soft"])
	for e: String in res["examples_hard"]:
		print("[world-r4]   HARD ", e)
	for e: String in res["examples_soft"]:
		print("[world-r4]   soft ", e)
	metric("triangles", ntri)
	metric("hard_pairs", res["hard"])
	metric("hard_area_m2", res["hard_area"])
	metric("soft_pairs", res["soft"])
	metric("soft_area_m2", res["soft_area"])
	metric("hard_by_mesh_pair", res["by_pair_hard"])
	metric("exact_pairs", res["exact"])
	metric("exact_area_m2", res["exact_area"])
	metric("pressed_skipped", res["pressed"])
	metric("clusters_exact", res["clusters_exact"])
	metric("clusters_hard", res["clusters_hard"])
	metric("soft_by_mesh_pair", res["by_pair_soft"])
	metric("examples_hard", res["examples_hard"])
	metric("examples_soft", res["examples_soft"])
	_save_exact("zfight_exact_kits.json", res["exact_list"])
	gt(float(ntri), 50000.0, "the scan saw the world (sanity)")
	metric("cross_mesh_hard_pairs", res["cross_hard"])
	# Same-mesh pairs are drawn in one call in a fixed order: the close-ups
	# (world_r4exp_shot.tscn -> verify/r4exp/r4exp_*.png) show no flicker.
	# Pairs in different draw calls have no fixed order: those z-fight.
	eq(int(res["cross_hard"]), 0, "no coplanar overlapping faces of different colour across draw calls")


func test_no_zfighting_in_trees() -> void:
	var t0 := Time.get_ticks_msec()
	var only := _collect_drawn(true)
	var t1 := Time.get_ticks_msec()
	var res := _zfight_scan(only)
	print("[world-r4] z-fight scan (trees): %d triangles from %d meshes, collect %d ms, scan %d ms; hard %d (%.3f m2), soft %d (%.3f m2)" % [
		only.n.size(), only.names.size(), t1 - t0, Time.get_ticks_msec() - t1,
		res["hard"], res["hard_area"], res["soft"], res["soft_area"]])
	print("[world-r4]   trees exact pairs %d (%.3f m2), pressed skipped %d" % [res["exact"], res["exact_area"], res["pressed"]])
	print("[world-r4]   trees exact clusters: ", res["clusters_exact"])
	print("[world-r4]   trees hard by mesh pair: ", res["by_pair_hard"])
	for e: String in res["examples_hard"]:
		print("[world-r4]   HARD ", e)
	_save_exact("zfight_exact_trees.json", res["exact_list"])
	metric("tree_triangles", only.n.size())
	metric("hard_pairs", res["hard"])
	metric("hard_area_m2", res["hard_area"])
	metric("soft_pairs", res["soft"])
	metric("examples_hard", res["examples_hard"])
	metric("exact_pairs", res["exact"])
	metric("clusters_exact", res["clusters_exact"])
	metric("clusters_hard", res["clusters_hard"])
	metric("cross_mesh_hard_pairs", res["cross_hard"])
	eq(int(res["cross_hard"]), 0, "no coplanar overlapping tree faces of different colour across draw calls")


# --- 2. the furnished rooms: every window line crosses the room ----------------

func test_window_lines_cross_the_furnished_rooms() -> void:
	var by_name := {}
	for o in world.get_openings():
		by_name[str(o["name"])] = o
	var houses := 0
	var rated_blocked: PackedStringArray = []
	var sparrow_blocked: PackedStringArray = []
	var misaligned: PackedStringArray = []
	var lines := 0
	var rs := k_body * 0.24
	for nm: String in by_name:
		if not nm.ends_with("_front_window"):
			continue
		var base := nm.trim_suffix("_front_window")
		if not by_name.has(base + "_back_window"):
			continue
		houses += 1
		var f: Dictionary = by_name[nm]
		var b: Dictionary = by_name[base + "_back_window"]
		var n: Vector3 = f["normal"]
		var up: Vector3 = f["up"]
		var right := up.cross(n).normalized()
		var p0: Vector3 = f["position"]
		var p1: Vector3 = b["position"]
		var lateral := (p1 - p0) - n * (p1 - p0).dot(n)
		if lateral.length() > 0.02:
			misaligned.append("%s %.3f m" % [base, lateral.length()])
		var r := k_body * float(f["max_span"])
		var s0 := p0 + n * (r + 1.0)
		var s1 := p1 - n * (r + 1.0)
		if not _fits(s0, s1, r):
			rated_blocked.append("%s (%.2f m bird): %s" % [base, f["max_span"], _overlap_names(s0 + (s1 - s0) * _cast(s0, s1, r), r)])
		var hw := float(f["width"]) * 0.5 - rs - 0.01
		var hh := float(f["height"]) * 0.5 - rs - 0.01
		for iu in 5:
			for iv in 5:
				var off := right * lerpf(-hw, hw, iu / 4.0) + up * lerpf(-hh, hh, iv / 4.0)
				lines += 1
				var fr := _cast(s0 + off, s1 + off, rs)
				if fr < 1.0 or not _overlap_names(s0 + off, rs).is_empty():
					var hitp := s0 + off + (s1 - s0) * fr
					sparrow_blocked.append("%s off(%.2f,%.2f) at %.0f%%: %s" % [base, lerpf(-hw, hw, iu / 4.0), lerpf(-hh, hh, iv / 4.0),
						fr * 100.0, _overlap_names(hitp, rs + 0.01)])
	print("[world-r4] window lines: %d houses, %d sparrow lines; rated blocked %d %s; sparrow blocked %d %s; misaligned %s" % [
		houses, lines, rated_blocked.size(), rated_blocked, sparrow_blocked.size(), sparrow_blocked.slice(0, 8), misaligned])
	metric("houses", houses)
	metric("sparrow_lines", lines)
	metric("rated_blocked", Array(rated_blocked))
	metric("sparrow_blocked", Array(sparrow_blocked.slice(0, 20)))
	gt(float(houses), 7.0, ">= 8 fly-through houses")
	eq(misaligned.size(), 0, "front and back windows line up")
	eq(rated_blocked.size(), 0, "the rated bird crosses every room window to window")
	eq(sparrow_blocked.size(), 0, "a sparrow anywhere in the aperture crosses the room untouched")


# --- 3. thermals from low down ------------------------------------------------

## Circle radius of a 30-degree-bank thermalling circle at 1.2 x min speed.
static func _circle_r(mass: float) -> float:
	var v := float(SizeRules.performance(mass)["min_speed"]) * 1.2
	return v * v / (9.81 * tan(deg_to_rad(30.0)))


func test_thermals_usable_from_low_down() -> void:
	var sp := [["sparrow", 0.03, 20.0], ["crow", 0.5, 30.0], ["eagle", 3.0, 45.0]]
	var out := {}
	var worst := {}
	var fails: PackedStringArray = []
	var ths := world.get_thermals()
	for i in ths.size():
		var th: Dictionary = ths[i]
		var row := {}
		for s: Array in sp:
			var mass: float = s[1]
			var rc := _circle_r(mass)
			var rb := SizeRules.body_radius_for_mass(mass)
			var lowest := -1.0
			var why := ""
			for h in range(4, 121, 2):
				var c0 := world.wind.thermal_center(i, 0.0)
				var g := world.ground_height(c0.x, c0.z)
				var y := g + float(h)
				var c := world.wind.thermal_center(i, y)
				var lift := 0.0
				var clear := true
				var pts: Array[Vector3] = []
				for k in 24:
					var a := TAU * k / 24.0
					var p := c + Vector3(cos(a), 0.0, sin(a)) * rc
					pts.append(p)
					lift += world.get_wind(p).y / 24.0
				if lift < 1.0:
					why = "lift %.2f" % lift
					continue
				if not _overlap_names(pts[0], rb).is_empty():
					clear = false
				else:
					for k in 24:
						if _cast(pts[k], pts[(k + 1) % 24], rb) < 1.0:
							clear = false
							break
				if not clear:
					why = "blocked"
					continue
				lowest = float(h)
				break
			row[s[0]] = {"lowest_agl": lowest, "circle_r": snappedf(rc, 0.1), "why_not_lower": why}
			worst[s[0]] = maxf(float(worst.get(s[0], 0.0)), lowest if lowest >= 0.0 else 999.0)
			if lowest < 0.0 or lowest > float(s[2]):
				fails.append("%s: %s lowest usable %.0f m AGL (limit %.0f)" % [th["name"], s[0], lowest, s[2]])
		out[str(th["name"])] = row
	print("[world-r4] thermals from low down: ", out)
	print("[world-r4]   worst lowest usable AGL per species: ", worst, " fails: ", fails)
	metric("per_thermal", out)
	metric("worst_lowest_agl", worst)
	eq(fails.size(), 0, "every thermal can be joined low down (sparrow <= 20 m, crow <= 30 m, eagle <= 45 m AGL): %s" % ", ".join(fails))


# --- 4. ridge soaring along the whole cliff -----------------------------------

func test_ridge_soaring_along_the_cliff() -> void:
	var pts: Array = WorldLayout.CLIFF
	var tops: Array = WorldLayout.CLIFF_TOP
	var total := 0.0
	for i in pts.size() - 1:
		total += (pts[i] as Vector2).distance_to(pts[i + 1])
	var stations := []
	var s := 45.0
	while s <= total - 45.0:
		stations.append(s)
		s += 5.0
	var gaps: PackedStringArray = []
	var min_band_lift := INF
	var band_sum := 0.0
	var blocked_segments: PackedStringArray = []
	var prev_p := Vector3.INF
	var crow_r := SizeRules.body_radius_for_mass(0.5)
	for t in [0.0, 23.0, 61.0]:
		world.set_air_time(t)
		for st: float in stations:
			# Point on the polyline at arc length st, its right-hand normal (+ = in front of the face).
			var acc := 0.0
			var c2 := Vector2.ZERO
			var nrm := Vector2.ZERO
			var top := 0.0
			for i in pts.size() - 1:
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				var l := a.distance_to(b)
				if st <= acc + l or i == pts.size() - 2:
					var tt := clampf((st - acc) / l, 0.0, 1.0)
					c2 = a.lerp(b, tt)
					var dir := (b - a) / l
					nrm = Vector2(-dir.y, dir.x)
					top = lerpf(tops[i], tops[i + 1], tt)
					break
				acc += l
			# Best lift over a band of heights 20 m in front of the face.
			var q := c2 + nrm * 20.0
			var g := world.ground_height(q.x, q.y)
			var best := -INF
			var best_y := 0.0
			for f in [0.4, 0.6, 0.8, 1.0, 1.2, 1.5]:
				var y := g + maxf(top, 10.0) * float(f)
				var w := world.get_wind(Vector3(q.x, y, q.y)).y
				if w > best:
					best = w
					best_y = y
			min_band_lift = minf(min_band_lift, best)
			band_sum += best
			if best < 1.5:
				gaps.append("s=%.0f t=%.0f: best %.2f m/s (top %.0f m)" % [st, t, best, top])
			# Fly a crow along the face at 0.8 x top, 20 m out.
			if t == 0.0:
				var p := Vector3(q.x, g + maxf(top, 10.0) * 0.8, q.y)
				if prev_p != Vector3.INF and _cast(prev_p, p, crow_r) < 1.0:
					blocked_segments.append("s=%.0f %s" % [st, _overlap_names(prev_p + (p - prev_p) * _cast(prev_p, p, crow_r), crow_r + 0.02)])
				prev_p = p
	world.set_air_time(0.0)
	var mean := band_sum / (stations.size() * 3)
	print("[world-r4] ridge along the cliff (%.0f m, %d stations x 3 times): min best-band lift %.2f, mean %.2f, gaps %d %s; crow path blocked %d %s" % [
		total, stations.size(), min_band_lift, mean, gaps.size(), gaps.slice(0, 6), blocked_segments.size(), blocked_segments.slice(0, 6)])
	metric("cliff_length", total)
	metric("min_best_band_lift", min_band_lift)
	metric("mean_best_band_lift", mean)
	metric("gaps", Array(gaps.slice(0, 20)))
	metric("crow_path_blocked", Array(blocked_segments))
	eq(gaps.size(), 0, "ridge lift >= 1.5 m/s somewhere in the band at every station along the cliff (no gaps to fall through)")
	eq(blocked_segments.size(), 0, "a crow can fly the ridge line 20 m out along the whole face")


# --- 5. where perched birds take off --------------------------------------------

func test_perched_birds_can_take_off_forward() -> void:
	# NpcBird.take_off (scripts/ai/npc_bird.gd) sends a resting bird off
	# along its facing (the perch's). A way out that way must be open for
	# the rated bird: 2 m forward dropping 0.6 m, or 2 m forward rising
	# 0.3 m, from its validated body position. (Not a brief criterion:
	# information, with a loose bound.)
	var by_kind := {}
	var blocked_by := {}
	var examples: PackedStringArray = []
	var blocked := 0
	for p in world.get_perches():
		var kn: String = Perch.Kind.keys()[p.kind]
		by_kind[kn] = int(by_kind.get(kn, 0)) + 1
		var r := k_body * p.max_span
		var c := p.position + Vector3.UP * (r + 0.02)
		var f := Vector3(p.facing.x, 0.0, p.facing.z).normalized()
		var e := c + f * 2.0 + Vector3.DOWN * 0.6
		var fr := _cast(c, e, r)
		if fr < 1.0 and _cast(c, c + f * 2.0 + Vector3.UP * 0.3, r) < 1.0:
			blocked += 1
			var key := "%s/%s" % [kn, p.district]
			blocked_by[key] = int(blocked_by.get(key, 0)) + 1
			if examples.size() < 15:
				examples.append("%s/%s at %s span %.2f facing %s: blocked after %.2f m by %s" % [kn, p.district, str(p.position.snapped(Vector3.ONE * 0.1)),
					p.max_span, str(f.snapped(Vector3.ONE * 0.01)), 2.0 * fr, _overlap_names(c + (e - c) * fr, r + 0.02)])
	var n := world.get_perches().size()
	print("[world-r4] take-off along facing: %d of %d blocked (%.1f%%) %s" % [blocked, n, 100.0 * blocked / n, blocked_by])
	for e in examples:
		print("[world-r4]   ", e)
	metric("blocked", blocked)
	metric("blocked_fraction", float(blocked) / n)
	metric("blocked_by_kind_district", blocked_by)
	metric("perches_by_kind", by_kind)
	metric("examples", Array(examples))
	lt(float(blocked) / n, 0.10, "< 10% of perches face straight into an obstacle")


# --- 6. physics query cost per district -----------------------------------------

func test_physics_query_cost_by_district() -> void:
	var districts := {
		"forest_core": WorldLayout.FOREST, "village": WorldLayout.VILLAGE, "meadow": WorldLayout.MEADOW,
		"orchard": WorldLayout.ORCHARD, "farm": WorldLayout.FARM,
		"cliff_front": (WorldLayout.CLIFF[2] as Vector2) + Vector2(25, 0),
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var out := {}
	var worst_ray := 0.0
	var worst_cast := 0.0
	var sp := SphereShape3D.new()
	sp.radius = 0.12
	for dn: String in districts:
		var c: Vector2 = districts[dn]
		var starts: Array[Vector3] = []
		var dirs: Array[Vector3] = []
		for i in 400:
			var q := c + Vector2(rng.randf_range(-50, 50), rng.randf_range(-50, 50))
			var y := world.ground_height(q.x, q.y) + rng.randf_range(1.5, 20.0)
			starts.append(Vector3(q.x, y, q.y))
			dirs.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 0.4), rng.randf_range(-1, 1)).normalized())
		var t0 := Time.get_ticks_usec()
		for i in 400:
			var qr := PhysicsRayQueryParameters3D.create(starts[i], starts[i] + dirs[i] * 30.0)
			qr.collision_mask = 1
			space.intersect_ray(qr)
		var ray_us := (Time.get_ticks_usec() - t0) / 400.0
		t0 = Time.get_ticks_usec()
		for i in 400:
			var qs := PhysicsShapeQueryParameters3D.new()
			qs.shape = sp
			qs.collision_mask = 1
			qs.transform = Transform3D(Basis.IDENTITY, starts[i])
			qs.motion = dirs[i] * 12.0
			space.cast_motion(qs)
		var cast_us := (Time.get_ticks_usec() - t0) / 400.0
		out[dn] = {"ray_30m_us": snappedf(ray_us, 0.1), "sphere_cast_12m_us": snappedf(cast_us, 0.1)}
		worst_ray = maxf(worst_ray, ray_us)
		worst_cast = maxf(worst_cast, cast_us)
	print("[world-r4] physics query cost: ", out)
	metric("by_district", out)
	metric("worst_ray_us", worst_ray)
	metric("worst_cast_us", worst_cast)
	# 60 NPCs x ~5 queries a tick at 72 Hz on a Quest (~3-4x slower than
	# this M1) must stay a small slice of a 13.9 ms frame.
	lt(worst_ray, 40.0, "a 30 m ray costs < 40 us in the worst district")
	lt(worst_cast, 150.0, "a 12 m sphere cast costs < 150 us in the worst district")


# --- 7. fresh seeds ---------------------------------------------------------------

func _isolated_world(seed: int) -> Array:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = seed
	w.with_decoration = false
	vp.add_child(w)
	return [vp, w]


func test_fresh_seeds_hold_up() -> void:
	var main_space := space
	var out := {}
	for sd: int in [7, 555, 31337, -1, 9007199254740991]:
		var pair := _isolated_world(sd)
		var w: SoaringWorld = pair[1]
		await wait_physics(2)
		space = w.get_world_3d().direct_space_state
		# Openings: rated body starts clear and flies in to depth.
		var ops := w.get_openings()
		var kinds := {}
		var op_fail: PackedStringArray = []
		for o in ops:
			kinds[str(o["type"])] = true
			var r := k_body * float(o["max_span"])
			var n: Vector3 = o["normal"]
			var p: Vector3 = o["position"]
			if not _fits(p + n * (r + 1.0), p - n * float(o["depth"]), r):
				op_fail.append(str(o["name"]))
		# Perches: supported within 3 cm, body fits.
		var no_support := 0
		var no_room := 0
		for pc in w.get_perches():
			var hit := _ray(pc.position + Vector3.UP * 0.1, pc.position + Vector3.DOWN * 0.15)
			if hit.is_empty() or absf((hit["position"] as Vector3).y - pc.position.y) > 0.03:
				no_support += 1
			var rr := k_body * pc.max_span
			if not _overlap_names(pc.position + Vector3.UP * (rr + 0.02), rr).is_empty():
				no_room += 1
		# Arena: 72 bearings x 3 heights, a 2 cm sphere marched out in 2 m steps.
		var esc := 0
		var R := w.bounds_radius
		for deg in range(0, 360, 5):
			var a := deg_to_rad(float(deg))
			var dir := Vector3(cos(a), 0, sin(a))
			for yy: float in [30.0, 150.0, 295.0]:
				var rs := R - 15.0
				while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > yy - 2.0:
					rs -= 15.0
				if _march(dir * rs + Vector3(0, yy, 0), dir * (R + 60.0) + Vector3(0, yy, 0), 0.02, 2.0) >= 1.0:
					esc += 1
		# Spawn: the rated sparrow fits there.
		var spn := w.get_player_spawn().origin
		var spawn_ok := _overlap_names(spn + Vector3.UP * 0.05, k_body * 0.24).is_empty()
		out[sd] = {"generation_ms": snappedf(w.generation_ms, 1.0), "openings": ops.size(), "opening_kinds": kinds.size(),
			"openings_failed": Array(op_fail.slice(0, 6)), "perches": w.get_perches().size(), "perch_no_support": no_support,
			"perch_no_room": no_room, "arena_escapes": esc, "spawn_clear": spawn_ok}
		lt(w.generation_ms, 2000.0, "seed %d: generation < 2 s" % sd)
		gt(float(ops.size()), 19.0, "seed %d: >= 20 openings" % sd)
		gt(float(kinds.size()), 3.0, "seed %d: >= 4 opening kinds" % sd)
		eq(op_fail.size(), 0, "seed %d: every opening flyable by its rated bird (%s)" % [sd, ", ".join(op_fail.slice(0, 5))])
		gt(float(w.get_perches().size()), 399.0, "seed %d: >= 400 perches" % sd)
		eq(no_support, 0, "seed %d: every perch supported" % sd)
		eq(no_room, 0, "seed %d: every perch has room" % sd)
		eq(esc, 0, "seed %d: arena closed" % sd)
		check(spawn_ok, "seed %d: spawn clear" % sd)
		space = main_space
		pair[0].queue_free()
		await wait_frames(2)
	print("[world-r4] fresh seeds: ", out)
	metric("seeds", out)
