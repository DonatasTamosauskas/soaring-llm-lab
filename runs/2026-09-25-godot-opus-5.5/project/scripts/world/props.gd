class_name PropsBuilder
extends RefCounted
## Small things with big roles: nest boxes (tiny round-ish holes only wrens
## and sparrows fit), the guyed radio mast on the east hill (the tallest
## thing in the valley, a playground for hawks and eagles), a jetty with a
## rowing boat on the lake, and boulders along shores and field edges.


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("props")
	_mast(ctx, rng)
	_jetty(ctx, rng)
	_boulders(ctx, rng)


## Things hung on other built things, placed once every kit is committed
## (SoaringWorld calls this after the commit): a nest box's approach and its
## own volume are checked against every collider in the valley (houses,
## hedges, fences, wires), not just the trees committed during the build.
static func build_mounted(ctx: WorldBuild) -> void:
	_nest_boxes(ctx, ctx.sub_rng("nest_boxes"))


# --- nest boxes --------------------------------------------------------

## A nest box whose back board's outer face is at xf's origin - 0.1 along
## its +Z (out). batten: the depth of the mounting batten behind the board
## (to reach into the drawn wood it is nailed to); 0 for none.
static func nest_box(ctx: WorldBuild, kit: MeshKit, xf: Transform3D, hole: float, name: String, district: StringName, batten := 0.0) -> void:
	var prev := kit.xf
	kit.xf = xf
	kit.sway = 0.0
	var wood := Palette.c(&"wood_light")
	var wood_d := Palette.c(&"wood")
	# Inside is burrow-dark so the round hole reads as a hole, not a decal.
	var dark := Palette.c(&"burrow")
	var W := 0.22
	var H := 0.3
	var D := 0.2
	var th := 0.02
	# Back, sides, floor; the front carries the entrance hole. Thin dark
	# liners 2 mm inside the back and side boards darken what shows through.
	kit.box_between(Vector3(-W * 0.5, -H * 0.5, -D * 0.5), Vector3(W * 0.5, H * 0.5 + 0.02, -D * 0.5 + th), wood_d)
	kit.box_between(Vector3(-W * 0.5, -H * 0.5, -D * 0.5 + th), Vector3(-W * 0.5 + th, H * 0.5, D * 0.5 - th), wood, Color(0, 0, 0, 0))
	kit.box_between(Vector3(W * 0.5 - th, -H * 0.5, -D * 0.5 + th), Vector3(W * 0.5, H * 0.5, D * 0.5 - th), wood)
	kit.box_between(Vector3(-W * 0.5 + th, -H * 0.5, -D * 0.5 + th), Vector3(W * 0.5 - th, -H * 0.5 + th, D * 0.5 - th), dark)
	kit.box_between(Vector3(-W * 0.5 + th, -H * 0.5 + th, -D * 0.5 + th + 0.002), Vector3(W * 0.5 - th, H * 0.5 - th, -D * 0.5 + th + 0.006), dark)
	for sx: float in [-1.0, 1.0]:
		var x0 := sx * (W * 0.5 - th - 0.002)
		kit.box_between(Vector3(minf(x0, x0 - sx * 0.004), -H * 0.5 + th, -D * 0.5 + th + 0.006), Vector3(maxf(x0, x0 - sx * 0.004), H * 0.5 - th, D * 0.5 - th - 0.002), dark)
	var hv := 0.19
	var ft := Transform3D(Basis.IDENTITY, Vector3(-W * 0.5, -H * 0.5, D * 0.5 - th * 0.5))
	kit.wall(ft, W, H, th, [{"rect": Rect2(W * 0.5 - hole * 0.5, hv - hole * 0.5, hole, hole), "round": true, "segs": 4}], wood, dark, dark, 15)
	# Ceiling inside, then the sloping lid overhanging the front.
	kit.box_between(Vector3(-W * 0.5 + th, H * 0.5 - th, -D * 0.5 + th), Vector3(W * 0.5 - th, H * 0.5, D * 0.5 - th), dark)
	kit.box(Transform3D(Basis(Vector3.RIGHT, 0.26), Vector3(0, H * 0.5 + 0.035, 0.03)), Vector3(W + 0.06, 0.025, D + 0.12), Palette.c(&"roof_moss"))
	# Perch peg under the hole.
	kit.rod(Vector3(0, hv - H * 0.5 - hole * 0.5 - 0.035, D * 0.5), Vector3(0, hv - H * 0.5 - hole * 0.5 - 0.035, D * 0.5 + 0.07), 0.008, 0.008, 4, wood_d)
	# The batten it hangs by: a strip behind the back board, longer than the
	# box, sunk into the trunk or pole (the post's collider is a capsule a few
	# cm proud of its drawn faces, and the box's inside must stay clear of it).
	if batten > 0.0:
		kit.box_between(Vector3(-0.03, -H * 0.5 - 0.09, -D * 0.5 - batten), Vector3(0.03, H * 0.5 + 0.1, -D * 0.5), wood_d)
	kit.xf = prev
	var centre := xf * Vector3(0, hv - H * 0.5, D * 0.5)
	var out := xf.basis * Vector3.BACK
	var span := WorldBuild.span_for_gap(hole)
	ctx.add_opening(name, "nest_box", centre, out, hole, hole, span, 0.13, 15)
	ctx.add_refuge(name, xf * Vector3(0, -0.02, 0), 0.06, span)
	ctx.add_landmark(name + "_nest", "nest", centre, 0.2)
	ctx.add_perch(xf * Vector3(0, H * 0.5 + 0.06, -0.02), out, Perch.Kind.NEST, 0.45, district)


static func _nest_boxes(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("nest_boxes")
	var lib: TreeLib = ctx.get_meta(&"tree_lib", null)
	var space := ctx.visual_root.get_world_3d().direct_space_state
	var made := 0
	if lib:
		# Mount boxes on trunks: forest edge, orchard, village gardens, river.
		var wanted := {&"forest": 4, &"orchard": 3, &"village": 2, &"river": 2, &"lake": 1}
		for inst in lib.instances:
			var d: StringName = inst["district"]
			if wanted.get(d, 0) <= 0 or inst["mounted"]:
				continue
			var v: Dictionary = lib.variants[inst["v"]]
			if v["mounts"].is_empty() or v["species"] == TreeLib.Species.SPRUCE:
				continue
			var m: Array = v["mounts"][0]
			var stem := _stem_at(v, m[0])
			if stem.is_empty():
				continue
			var xf := lib.instance_xform(inst)
			var y_box: float = (xf * (m[0] as Vector3)).y
			# Face the box where a small bird can actually fly in: the first
			# of the trunk's flat faces whose approach (1.3 m out) and the
			# box's own volume are physically clear.
			var sides: int = stem[4]
			var face0 := int(rng.randf() * sides)
			for tries in sides:
				var mount := _post_face(xf, stem, (face0 + tries) % sides, y_box)
				if mount.is_empty():
					continue
				var dir: Vector3 = mount["dir"]
				var at: Vector3 = mount["axis"]
				# The trunk's collider (a capsule, a little fatter than the drawn
				# wood) measured behind the board: the box sits just outside it.
				var d_col := _collider_depth(space, at, dir)
				var vis: float = mount["vis"]
				if d_col == -INF or d_col - vis > 0.25:
					continue  # a limb or a neighbour in the way
				var box_xf := _box_xform(at, dir, maxf(d_col + 0.012, vis + 0.015))
				var hole_c := box_xf * Vector3(0, 0.04, 0.1)
				if _clear(space, hole_c + dir * 1.3, hole_c - dir * 0.15, 0.06) and _clear(space, box_xf.origin + dir * 0.01, box_xf.origin + dir * 0.02, 0.1):
					var back := (box_xf.origin - at).dot(dir) - 0.1
					nest_box(ctx, kit, box_xf, 0.085 if made % 2 == 0 else 0.1, "nest_box_%d" % made, d, back - vis + 0.02)
					wanted[d] = wanted[d] - 1
					made += 1
					break
	# Two on power poles: the first pole and the one by the village lane.
	var poles: Array = ctx.get_meta(&"poles", [])
	if not poles.is_empty():
		var pick: Array[Dictionary] = [poles[0]]
		var best: Dictionary = poles[1]
		for pl: Dictionary in poles:
			if (pl["pos"] as Vector2).distance_to(Vector2(-20, -60)) < (best["pos"] as Vector2).distance_to(Vector2(-20, -60)):
				best = pl
		pick.append(best)
		for pl in pick:
			var stem := [pl["base"], pl["top"], pl["r0"], pl["r1"], pl["sides"]]
			var y_box: float = (pl["base"] as Vector3).y + 1.2 + 3.4
			# The face looking most nearly south (+Z), as the round-1 boxes did.
			var mount := {}
			for fi in int(pl["sides"]):
				var cand := _post_face(Transform3D.IDENTITY, stem, fi, y_box)
				if not cand.is_empty() and (mount.is_empty() or (cand["dir"] as Vector3).z > (mount["dir"] as Vector3).z):
					mount = cand
			var dir: Vector3 = mount["dir"]
			var at: Vector3 = mount["axis"]
			var vis: float = mount["vis"]
			# The pole collides as a vertical capsule of radius r_col.
			var box_xf := _box_xform(at, dir, maxf(float(pl["r_col"]) + 0.012, vis + 0.015))
			var back := (box_xf.origin - at).dot(dir) - 0.1
			nest_box(ctx, kit, box_xf, 0.1, "nest_box_%d" % made, &"powerline", back - vis + 0.02)
			made += 1
	ctx.set_meta(&"nest_boxes", made)


## The drawn stem segment of a tree variant at a mount point: the wood piece
## (from TreeLib's record [a, b, r0, r1, sides]) spanning the mount's height
## whose axis passes nearest to it.
static func _stem_at(v: Dictionary, p: Vector3) -> Array:
	var best := []
	var best_d := INF
	for w: Array in v["wood"]:
		var a: Vector3 = w[0]
		var b: Vector3 = w[1]
		if b.y - a.y < 0.3 or p.y < a.y or p.y > b.y:
			continue
		var q := a.lerp(b, (p.y - a.y) / (b.y - a.y))
		var dd := Vector2(q.x - p.x, q.z - p.z).length()
		if dd < best_d:
			best_d = dd
			best = w
	return best if best_d < 0.25 else []


## One flat face of a drawn post (a tapered, possibly leaning n-gon from
## MeshKit.cyl, placed by xf) at world height y: the face's horizontal
## outward direction, the axis point at y, and how far along that direction
## the drawn face is from the axis at the most recessed end of a batten
## (y - 0.25 .. y + 0.25): a batten reaching that far touches it everywhere.
static func _post_face(xf: Transform3D, stem: Array, fi: int, y: float) -> Dictionary:
	var a: Vector3 = stem[0]
	var b: Vector3 = stem[1]
	var r0: float = stem[2]
	var r1: float = stem[3]
	var sides: int = stem[4]
	var pb := MeshKit._perp_basis(b - a)
	var ux: Vector3 = pb[0]
	var uy: Vector3 = pb[1]
	var th0 := TAU * float(fi) / float(sides)
	var th1 := TAU * float(fi + 1) / float(sides)
	var A0 := xf * (a + (ux * cos(th0) + uy * sin(th0)) * r0)
	var A1 := xf * (a + (ux * cos(th1) + uy * sin(th1)) * r0)
	var B0 := xf * (b + (ux * cos(th0) + uy * sin(th0)) * r1)
	var wa := xf * a
	var wb := xf * b
	var nf := (A1 - A0).cross(B0 - A0).normalized()
	if nf.dot((A0 + A1) * 0.5 - wa) < 0.0:
		nf = -nf
	var dir := Vector3(nf.x, 0.0, nf.z)
	if dir.length() < 0.5:
		return {}
	dir = dir.normalized()
	var vis := INF
	for yy: float in [y - 0.25, y + 0.25]:
		var c := wa.lerp(wb, (yy - wa.y) / (wb.y - wa.y))
		vis = minf(vis, nf.dot(A0 - c) / nf.dot(dir))
	return {"dir": dir, "axis": wa.lerp(wb, (y - wa.y) / (wb.y - wa.y)), "vis": vis}


## How far out along dir, from the axis point `at`, the colliders behind a
## box's back board reach (rays over the board's 22 x 30 cm); -INF if none.
static func _collider_depth(space: PhysicsDirectSpaceState3D, at: Vector3, dir: Vector3) -> float:
	var lat := Vector3.UP.cross(dir).normalized()
	var best := -INF
	for u: float in [-0.09, 0.0, 0.09]:
		for v: float in [-0.13, 0.0, 0.15]:
			var p := at + lat * u + Vector3.UP * v
			var rq := PhysicsRayQueryParameters3D.create(p + dir * 1.5, p - dir * 0.3)
			rq.collision_mask = 1
			var h := space.intersect_ray(rq)
			if not h.is_empty():
				best = maxf(best, ((h["position"] as Vector3) - p).dot(dir))
	return best


## The nest box's transform: facing dir, its back board's outer face `back`
## m out from the axis point `at` (the box's origin is 0.1 m in front of it).
static func _box_xform(at: Vector3, dir: Vector3, back: float) -> Transform3D:
	return Transform3D(Basis.looking_at(-dir, Vector3.UP), at + dir * (back + 0.1))


## A sphere of radius r flies from a to b untouched. It must start clear:
## a cast ignores shapes it begins inside (a leaf clump in front of a box).
static func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, r: float) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, a)
	if not space.intersect_shape(q, 1).is_empty():
		return false
	q.motion = b - a
	var res := space.cast_motion(q)
	return res.size() > 0 and res[0] >= 1.0


# --- radio mast --------------------------------------------------------

static func _mast(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("mast")
	kit.jitter = 0.02
	var c := WorldLayout.MAST
	var g := ctx.ground(c.x, c.y)
	var H := 92.0
	var R := 0.95
	var legs: Array[Vector3] = []
	for k in 3:
		var a := PI * 0.5 + TAU * k / 3.0
		legs.append(Vector3(cos(a) * R, 0, sin(a) * R))
	var base := Vector3(c.x, g, c.y)
	kit.box(Transform3D(Basis.IDENTITY, base + Vector3(0, 0.2, 0)), Vector3(3.2, 1.2, 3.2), Palette.c(&"stone"))
	var white := Palette.c(&"mast_white")
	var red := Palette.c(&"mast_red")
	# The lattice runs from the plinth top (0.8 m) exactly to H, where the
	# top plate sits (round 3 stopped it at 90.8 m, leaving the plate and
	# beacon hovering 1.6 m above it on invisible leg capsules).
	var levels := ceili((H - 0.8) / 3.0)
	var seg := (H - 0.8) / float(levels)
	var was := kit.collide
	kit.collide = false
	for l in levels:
		var y0 := 0.8 + l * seg
		var y1 := y0 + seg
		var col := red if int(y0 / 13.0) % 2 == 0 else white
		for k in 3:
			var a := base + legs[k] + Vector3(0, y0, 0)
			var b := base + legs[k] + Vector3(0, y1, 0)
			kit.cyl(a, b, 0.07, 0.07, 4, col, false, false)
			var n := base + legs[(k + 1) % 3] + Vector3(0, y1, 0)
			kit.cyl(a, n, 0.03, 0.03, 4, col, false, false)
			kit.cyl(b, n, 0.03, 0.03, 4, col, false, false)
			kit.add_capsule(a, n, 0.03)
			kit.add_capsule(b, n, 0.03)
	kit.collide = was
	for k in 3:
		kit.add_capsule(base + legs[k], base + legs[k] + Vector3(0, H, 0), 0.08)
		kit.add_capsule(base + legs[k] + Vector3(0, H, 0), base + legs[(k + 1) % 3] + Vector3(0, H, 0), 0.03)
	# Platforms (triangular grating decks) and the beacon.
	for py in [32.0, 62.0]:
		var tri := PackedVector2Array()
		for k in 3:
			var a := PI * 0.5 + TAU * k / 3.0
			tri.append(Vector2(cos(a), -sin(a)) * 2.6)
		kit.prism(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), base + Vector3(0, py, 0)), VillageBuilder._ccw(tri), 0.15, Palette.c(&"metal_dark"))
		for k in 3:
			var a := PI * 0.5 + TAU * k / 3.0 + PI / 3.0
			ctx.add_perch(base + Vector3(cos(a) * 1.1, py + 0.15, sin(a) * 1.1), Vector3(cos(a), 0, sin(a)), Perch.Kind.LEDGE, 2.1, &"mast")
	# Top plate resting on the leg tops, the beacon rod standing on it.
	kit.box(Transform3D(Basis.IDENTITY, base + Vector3(0, H + 0.1, 0)), Vector3(2.4, 0.2, 2.4), Palette.c(&"metal_dark"))
	kit.rod(base + Vector3(0, H + 0.2, 0), base + Vector3(0, H + 2.8, 0), 0.08, 0.08, 6, red)
	kit.blob(base + Vector3(0, H + 3.0, 0), Vector3.ONE * 0.25, Palette.c(&"beacon"), 0.05)
	ctx.add_perch(base + Vector3(0.6, H + 0.2, 0.6), Vector3.FORWARD, Perch.Kind.POLE_TOP, 2.1, &"mast")
	# Guy wires from three heights to three anchors.
	var wire := Palette.c(&"wire")
	for k in 3:
		var a := PI * 0.5 + TAU * k / 3.0 + PI / 3.0
		var dir := Vector3(cos(a), 0, sin(a))
		var anchor := Vector3(c.x + dir.x * 44.0, 0, c.y + dir.z * 44.0)
		anchor.y = ctx.ground(anchor.x, anchor.z) + 0.6
		kit.box(Transform3D(Basis.IDENTITY, anchor), Vector3(1.4, 1.6, 1.4), Palette.c(&"stone"))
		for hy in [30.0, 60.0, 88.0]:
			var top := base + dir * R * 0.5 + Vector3(0, hy, 0)
			var n := 6
			kit.collide = false
			for s in n:
				var p0 := anchor.lerp(top, float(s) / n) + Vector3(0, 0.8, 0) * (1.0 - float(s) / n)
				var p1 := anchor.lerp(top, float(s + 1) / n) + Vector3(0, 0.8, 0) * (1.0 - float(s + 1) / n)
				kit.cyl(p0, p1, 0.028, 0.028, 4, wire, false, false)
				kit.add_capsule(p0, p1, 0.025)
			kit.collide = was
			if hy < 35.0:
				var q := anchor.lerp(top, 0.3) + Vector3(0, 0.8 * 0.7 + 0.025, 0)
				ctx.add_perch(q, dir.cross(Vector3.UP), Perch.Kind.WIRE, 0.95, &"mast")
		ctx.add_footprint("mast_anchor_%d" % k, PackedVector2Array([Vector2(anchor.x, anchor.z)]), anchor.y - 0.8, 1.5, 3.0, -1.0, kit.name)
		ctx.add_feature(anchor.x, anchor.z, 2.0, "anchor")
	ctx.add_footprint("mast", PackedVector2Array([c]), g - 0.4, 1.0, 4.0, -1.0, kit.name)
	ctx.add_feature(c.x, c.y, 45.0, "mast")
	ctx.add_landmark("radio_mast", "tower", base + Vector3(0, H, 0), 3.0)


# --- lake jetty ---------------------------------------------------------

static func _jetty(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("jetty")
	# From the north-west shore straight out into the lake.
	var dir2 := (WorldLayout.LAKE - Vector2(150, 150)).normalized()
	var start := WorldLayout.LAKE - dir2 * 150.0
	# Walk until the shoreline.
	for i in 80:
		if ctx.ground(start.x, start.y) < WorldLayout.WATER_Y + 0.8:
			break
		start += dir2 * 2.0
	start -= dir2 * 6.0
	var L := 20.0
	var deck := WorldLayout.WATER_Y + 1.2
	var dir := Vector3(dir2.x, 0, dir2.y)
	var side := dir.cross(Vector3.UP)
	var s0 := Vector3(start.x, deck, start.y)
	var basis := Basis(side, Vector3.UP, -dir)
	kit.box(Transform3D(basis.orthonormalized(), s0 + dir * L * 0.5), Vector3(2.2, 0.16, L), Palette.c(&"wood_light"))
	for k in 5:
		for sd: float in [-1.0, 1.0]:
			var pp := s0 + dir * (2.0 + k * (L - 3.0) / 4.0) + side * 1.2 * sd
			var gy := ctx.ground(pp.x, pp.z)
			kit.cyl(Vector3(pp.x, gy - 0.5, pp.z), Vector3(pp.x, deck + 0.55, pp.z), 0.1, 0.1, 6, Palette.c(&"wood_dark"), false, true)
			if k % 2 == 0:
				ctx.add_perch(Vector3(pp.x, deck + 0.55, pp.z), side * sd, Perch.Kind.POLE_TOP, 0.95, &"lake")
	# A rowing boat moored beside the jetty end.
	var bc := s0 + dir * (L - 4.0) + side * 2.6 + Vector3(0, -1.2 - 0.12, 0)
	var hull := PackedVector2Array([Vector2(-0.75, 0.55), Vector2(-0.55, 0.0), Vector2(0.55, 0.0), Vector2(0.75, 0.55)])
	var bb := Basis(-side, Vector3.UP, dir)
	kit.prism(Transform3D(bb, bc - dir * 1.6), hull, 3.2, Palette.c(&"shutter_blue"), Palette.c(&"wood"))
	kit.box(Transform3D(bb, bc + Vector3(0, 0.45, 0)), Vector3(1.3, 0.06, 0.3), Palette.c(&"wood"))
	ctx.add_perch(bc + bb.z * 1.5 + Vector3(0, 0.55, 0), side, Perch.Kind.LEDGE, 0.8, &"lake")
	var mid := s0 + dir * L * 0.5
	ctx.add_feature(mid.x, mid.z, L * 0.5, "jetty")
	ctx.add_landmark("jetty", "jetty", s0 + dir * L * 0.5, 10.0)


# --- boulders -----------------------------------------------------------

static func _boulders(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("boulders")
	var placed := 0
	# Lake shore and river banks.
	for i in 90:
		var a := rng.randf() * TAU
		var q := WorldLayout.LAKE + Vector2(cos(a) * WorldLayout.LAKE_R.x, sin(a) * WorldLayout.LAKE_R.y).rotated(WorldLayout.LAKE_ROT) * rng.randf_range(1.05, 1.25)
		if ctx.ground(q.x, q.y) > WorldLayout.WATER_Y + 0.3 and ctx.is_free(q.x, q.y, 1.5):
			FloraBuilder.boulder(ctx, kit, rng, q, rng.randf_range(0.8, 2.0), &"lake")
			placed += 1
			if placed >= 14:
				break
	# Around the meadow's rim (never inside its open space), the ruin hill,
	# the canyon mouth and field corners.
	var spots := []
	for i in 22:
		var a := rng.randf() * TAU
		spots.append(WorldLayout.MEADOW + Vector2.from_angle(a) * rng.randf_range(WorldLayout.MEADOW_CLEAR + 5.0, WorldLayout.MEADOW_CLEAR + 40.0))
	for i in 8:
		spots.append(WorldLayout.RUIN + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(12.0, 50.0))
	for i in 8:
		spots.append(WorldLayout.CANYON[0] + Vector2(rng.randf_range(-60, 60), rng.randf_range(0, 60)))
	for p in spots:
		if (p as Vector2).length() < WorldLayout.BOUNDS - 30.0 and ctx.is_free(p.x, p.y, 2.0) and ctx.ground(p.x, p.y) > WorldLayout.WATER_Y + 0.5 \
				and ctx.terrain.normal_at(p.x, p.y).y > 0.8:
			FloraBuilder.boulder(ctx, kit, rng, p, rng.randf_range(1.0, 2.6), &"rocks")
			placed += 1
	ctx.set_meta(&"boulders", placed)
