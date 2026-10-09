class_name FloraBuilder
extends RefCounted
## Where the trees and hedges go: the north-west forest (with a glade under
## its thermal and hollow old oaks), the orchard, village gardens, river and
## lake trees, hedgerows along the field edges (with tunnels only small birds
## fit through), conifers on the mountain foothills, and copses that fill any
## stretch of the inner valley left featureless.


static func build(ctx: WorldBuild) -> void:
	var t0 := Time.get_ticks_usec()
	var rng := ctx.sub_rng("flora")
	_block_zones(ctx)
	var lib := TreeLib.new(ctx.sub_rng("treelib"))
	lib.make_variants()
	ctx.timings["flora_variants"] = (Time.get_ticks_usec() - t0) / 1000.0
	var tl := Time.get_ticks_usec()
	for step in [["hollow", _hollow_trees], ["forest", _forest], ["orchard", _orchard], ["village_trees", _village_trees],
			["water_trees", _water_trees], ["hedgerows", _hedgerows], ["foothills", _foothills], ["fill_gaps", _fill_gaps]]:
		(step[1] as Callable).call(ctx, lib, rng)
		var now := Time.get_ticks_usec()
		ctx.timings["flora_" + String(step[0])] = (now - tl) / 1000.0
		tl = now
	var t1 := Time.get_ticks_usec()
	lib.commit(ctx, rng)
	ctx.timings["flora_commit"] = (Time.get_ticks_usec() - t1) / 1000.0
	ctx.set_meta(&"tree_lib", lib)
	ctx.set_meta(&"tree_count", lib.instances.size())


## No-planting zones: water, roads, fields, the meadow's open space, the
## power-line corridor, the canyon floor.
static func _block_zones(ctx: WorldBuild) -> void:
	var sz := WorldLayout.STREET_Z
	ctx.block_segment(Vector2(WorldLayout.STREET_X0, sz), Vector2(70, sz), 6.5)
	for i in range(0, 13):
		ctx.block_segment(Vector2(-115, 11 + i * 3.0), Vector2(-65, 11 + i * 3.0), 3.0)
	var r := WorldLayout.RIVER
	for i in r.size() - 1:
		ctx.block_segment(r[i], r[i + 1], 12.0)
	var pl := WorldLayout.POWER_LINE
	for i in pl.size() - 1:
		ctx.block_segment(pl[i], pl[i + 1], 7.0)
	var cn := WorldLayout.CANYON
	for i in cn.size() - 1:
		ctx.block_segment(cn[i], cn[i + 1], WorldLayout.CANYON_HALF_GAP + 2.0)
	ctx.block_circle(WorldLayout.MEADOW.x, WorldLayout.MEADOW.y, WorldLayout.MEADOW_CLEAR)
	# Crop fields (hedgerows are placed explicitly on their edges).
	var terrain := ctx.terrain
	for c in terrain.south_crops:
		var nx := int(ceil(WorldLayout.FIELDS_SIZE.x / WorldLayout.FIELDS_CELL.x))
		var o := WorldLayout.FIELDS_ORIGIN + Vector2((c % nx) * WorldLayout.FIELDS_CELL.x, (c / nx) * WorldLayout.FIELDS_CELL.y)
		_block_rect(ctx, o + Vector2(3, 3), o + WorldLayout.FIELDS_CELL - Vector2(3, 3))
	for c in terrain.east_crops:
		var ex := int(ceil(WorldLayout.EAST_FIELDS_SIZE.x / WorldLayout.EAST_FIELDS_CELL.x))
		var o := WorldLayout.EAST_FIELDS_ORIGIN + Vector2((c % ex) * WorldLayout.EAST_FIELDS_CELL.x, (c / ex) * WorldLayout.EAST_FIELDS_CELL.y)
		_block_rect(ctx, o + Vector2(3, 3), o + WorldLayout.EAST_FIELDS_CELL - Vector2(3, 3))


static func _block_rect(ctx: WorldBuild, lo: Vector2, hi: Vector2) -> void:
	var z := lo.y
	while z <= hi.y:
		ctx.block_segment(Vector2(lo.x, z), Vector2(hi.x, z), 2.2)
		z += 4.0


## True if a tree can stand at p: free cell, dry ground, gentle slope.
static func _can_plant(ctx: WorldBuild, p: Vector2, r: float) -> bool:
	if not ctx.is_free(p.x, p.y, r):
		return false
	var g := ctx.ground(p.x, p.y)
	if g < WorldLayout.WATER_Y + 0.9:
		return false
	if WorldLayout.lake_q(p.x, p.y) < 1.12:
		return false
	return ctx.terrain.normal_at(p.x, p.y).y > 0.8


## block: occupancy radius reserved around the trunk (< 0: none; the
## forest reserves its sites itself once the whole wood is planted).
static func _plant(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator, species: int, p: Vector2, chunk: String, district: StringName,
		scale_lo := 0.85, scale_hi := 1.2, perch_budget := 2, simple := false, block := 3.5) -> Dictionary:
	var g := ctx.ground(p.x, p.y)
	var inst := lib.place(lib.pick(species, rng), Vector3(p.x, g, p.y), rng.randf() * TAU, rng.randf_range(scale_lo, scale_hi), chunk, district, perch_budget, simple)
	if block >= 0.0:
		ctx.block_circle(p.x, p.y, block)
	return inst


# --- forest ------------------------------------------------------------

## Old wood: the lattice spacing of trunks in the core (jittered, so
## neighbours stand ~4-8 m apart and the crowns interlock).
const CORE_SPACING := 6.6
## Small chunks and a short LOD distance keep the dense wood inside the
## Quest budget; far stand-ins merge 2 x 2 chunks. FOREST_FAR must exceed
## FOREST_LOD + LOD_MARGIN + the chunk-to-group-centre offset (34 m), so no
## chunk can be at full detail while its group is at far detail.
const FOREST_CHUNK := 48.0
const FOREST_LOD := 72.0
const FOREST_FAR := 130.0
## About this many branch perches come from the forest (so branches do not
## swamp every other perch kind).
const FOREST_PERCHES := 320


static var _rides: Array = []


## Distance from p to the nearest forest ride (terrain colouring calls this
## for every forest triangle, so the typed polylines are built once).
static func ride_distance(p: Vector2) -> float:
	if _rides.is_empty():
		for r in WorldLayout.FOREST_RIDES:
			var typed: Array[Vector2] = []
			typed.assign(r)
			_rides.append(typed)
	var best := INF
	for r in _rides:
		best = minf(best, WorldLayout.polyline_distance(p, r))
	return best


static func _forest(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var c := WorldLayout.FOREST
	var R := WorldLayout.FOREST_R
	var core := WorldLayout.FOREST_CORE_R
	var glade: Vector2 = WorldLayout.THERMALS[7]["pos"]
	# 1. Trunk sites: a jittered triangular lattice (even cover, no two
	# trunks closer than ~2.5 m), thinned outside the core so the wood opens
	# up toward its edge. Sites are tested against what was there before the
	# forest (zones, hollow oaks), not against each other.
	var s := CORE_SPACING
	var row := s * sqrt(3.0) * 0.5
	var sites: Array[Vector2] = []
	var nj := int(ceil(2.0 * R / row))
	var ni := int(ceil(2.0 * R / s))
	for j in nj + 1:
		for i in ni + 1:
			var p := c + Vector2(-R + (float(i) + 0.5 * float(j % 2)) * s, -R + float(j) * row)
			p += Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3)) * s
			var keep_roll := rng.randf()
			var r := p.distance_to(c)
			if r > R:
				continue
			# Density relative to the core: 1 inside, 0.55 in the outer wood,
			# 0.28 at the rim.
			var keep := 1.0
			if r > core:
				keep = lerpf(0.55, 0.28, clampf((r - core) / (R - core), 0.0, 1.0))
			if keep_roll >= keep:
				continue
			if p.distance_to(glade) < 24.0 or ride_distance(p) < WorldLayout.RIDE_HALF + 1.2:
				continue
			if not _can_plant(ctx, p, 1.2):
				continue
			sites.append(p)
	# 2. Trees. Broadleaf groves in the south of the wood, conifers
	# thickening toward the mountains in the north-west; the core is old
	# forest-grown broadleaf and spruce.
	var perch_p := clampf(float(FOREST_PERCHES) / maxf(sites.size(), 1.0), 0.0, 1.0)
	var trunks := {}
	var n := 0
	for p in sites:
		var r := p.distance_to(c)
		var conifer_bias := clampf(((c - p).dot(Vector2(0.7, 0.7)) / R) * 0.5 + 0.35, 0.1, 0.75)
		var roll := rng.randf()
		var sp: int
		if roll < conifer_bias:
			sp = TreeLib.Species.SPRUCE if rng.randf() < 0.8 else TreeLib.Species.PINE
		elif roll < conifer_bias + (1.0 - conifer_bias) * 0.62:
			# Forest-grown oaks throughout; the broad field oak only on the
			# open rim (it costs half as much again, and the wood holds many).
			sp = TreeLib.Species.OAK_TALL if r < R - 30.0 or rng.randf() < 0.5 else TreeLib.Species.OAK
		elif roll < conifer_bias + (1.0 - conifer_bias) * 0.92:
			sp = TreeLib.Species.BIRCH
		else:
			sp = TreeLib.Species.SNAG
		var key := _forest_chunk(p)
		var budget := 1 if rng.randf() < perch_p else 0
		_plant(ctx, lib, rng, sp, p, key, &"forest", 0.85, 1.2, budget, false, -1.0)
		_trunk_add(trunks, p)
		n += 1
	# 3. Understory: saplings and bushes in the gaps (low obstacles, small-
	# bird cover), densest in the core.
	var fk := ctx.kit("forest_floor", true)
	var under := 0
	for p in sites:
		var r := p.distance_to(c)
		if rng.randf() > (0.68 if r < core else 0.22):
			continue
		var q := p + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(2.6, 3.6)
		if _trunk_near(trunks, q, 2.2) or ride_distance(q) < WorldLayout.RIDE_HALF or q.distance_to(glade) < 20.0:
			continue
		if not _can_plant(ctx, q, 0.0):
			continue
		if rng.randf() < 0.6:
			_plant(ctx, lib, rng, TreeLib.Species.SAPLING, q, _forest_chunk(q), &"forest", 0.8, 1.2, 0, false, -1.0)
		else:
			_bush(ctx, fk, rng, q, rng.randf_range(0.8, 1.25), true)
		_trunk_add(trunks, q)
		under += 1
	# 4. Fallen trunks across the floor: low obstacles and perches.
	var logs := 0
	for i in 60:
		if logs >= 26:
			break
		var p := c + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * R * 0.9
		var d := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(2.8, 4.5)
		var clear := true
		for f in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var q: Vector2 = p + d * f
			if _trunk_near(trunks, q, 1.4) or ride_distance(q) < WorldLayout.RIDE_HALF or not _can_plant(ctx, q, 0.0):
				clear = false
				break
		if not clear:
			continue
		_fallen_log(ctx, fk, p - d, p + d, rng.randf_range(0.3, 0.42))
		_trunk_add(trunks, p)
		logs += 1
	# Nothing else is scattered into the wood.
	for p in sites:
		ctx.block_circle(p.x, p.y, 1.5)
	# Chunk LODs and far groups (2 x 2 chunks).
	for inst in lib.instances:
		var key: String = inst["chunk"]
		if key.begins_with("forest_c"):
			lib.chunk_lod[key] = FOREST_LOD
			lib.coarse_shadow[key] = true
			var parts := key.split("_")
			var g := "forest_g%d_%d" % [int(parts[2]) / 2, int(parts[3]) / 2]
			lib.far_group[key] = g
			lib.group_far[g] = FOREST_FAR
	ctx.add_landmark("forest", "forest", Vector3(c.x, ctx.ground(c.x, c.y), c.y), R)
	ctx.add_landmark("old_wood", "forest", Vector3(c.x, ctx.ground(c.x, c.y), c.y), core)
	ctx.add_landmark("forest_glade", "glade", Vector3(glade.x, ctx.ground(glade.x, glade.y), glade.y), 24.0)
	for ri in WorldLayout.FOREST_RIDES.size():
		var rp: Array = WorldLayout.FOREST_RIDES[ri]
		var mid: Vector2 = rp[rp.size() / 2]
		ctx.add_landmark("forest_ride_%d" % ri, "ride", Vector3(mid.x, ctx.ground(mid.x, mid.y), mid.y), WorldLayout.RIDE_HALF)
	ctx.timings["forest_trees"] = n
	ctx.timings["forest_understory"] = under
	ctx.timings["forest_logs"] = logs


static func _forest_chunk(p: Vector2) -> String:
	var c := WorldLayout.FOREST
	var R := WorldLayout.FOREST_R
	return "forest_c_%d_%d" % [floori((p.x - c.x + R) / FOREST_CHUNK), floori((p.y - c.y + R) / FOREST_CHUNK)]


## Trunk index for spacing checks inside the wood (4 m cells).
static func _trunk_add(trunks: Dictionary, p: Vector2) -> void:
	var key := Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))
	var arr: PackedVector2Array = trunks.get(key, PackedVector2Array())
	arr.append(p)
	trunks[key] = arr


static func _trunk_near(trunks: Dictionary, p: Vector2, r: float) -> bool:
	var k := Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var arr: Variant = trunks.get(k + Vector2i(di, dj))
			if arr == null:
				continue
			for q in (arr as PackedVector2Array):
				if q.distance_to(p) < r:
					return true
	return false


## A fallen trunk lying on the floor from a to b: its underside is sunk into
## the lowest ground along it, so it rests on the ground all the way.
static func _fallen_log(ctx: WorldBuild, kit: MeshKit, a2: Vector2, b2: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	for k in 7:
		pts.append(a2.lerp(b2, float(k) / 6.0))
	var gmin := ctx.ground_min(pts)
	var y := gmin + r * 0.55
	var a := Vector3(a2.x, y, a2.y)
	var b := Vector3(b2.x, y, b2.y)
	kit.sway = 0.0
	kit.cyl(a, b, r, r * 0.8, 6, Palette.c(&"bark"), true, true)
	var d := b2 - a2
	ctx.add_perch((a + b) * 0.5 + Vector3(0, r * 0.9, 0), Vector3(-d.y, 0, d.x), Perch.Kind.BRANCH, 1.3, &"forest")
	var mid := (a2 + b2) * 0.5
	ctx.add_feature(mid.x, mid.y, d.length() * 0.5, "log")
	# The log's lowest line is r below its axis; the ground is at most
	# (ground_max - gmin) above that.
	ctx.add_footprint("log", pts, y - r, r + (ctx.ground_max(pts) - gmin) + 0.1, -1.0, -1.0, kit.name)


## Hollow old oaks: a thick hollow trunk (8 wall panels, one with an
## entrance hole) under an ordinary oak crown.
static func _hollow_trees(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("hollow_trees", true)
	var spots := [Vector2(-205, -205), Vector2(-318, -300), Vector2(-240, -350), Vector2(-150, 170)]
	for hi in spots.size():
		var c: Vector2 = spots[hi]
		if not _can_plant(ctx, c, 2.0):
			continue
		var g := ctx.ground(c.x, c.y)
		var apo := 1.0
		var th := 0.3
		var h := 4.6
		var side := 2.0 * apo * tan(PI / 8.0)
		var hole := Rect2(side * 0.5 - 0.16, 1.9, 0.32, 0.46)
		var face := rng.randi() % 8
		var bark := Palette.c(&"bark")
		kit.sway = 0.0
		for k in 8:
			var ang := k * PI / 4.0
			var out := Vector3(cos(ang), 0, sin(ang))
			var basis := Basis.looking_at(-out, Vector3.UP)
			var origin := Vector3(c.x, g - 0.8, c.y) + out * (apo - th * 0.5) - basis.x * side * 0.5
			var t := Transform3D(basis, origin)
			# An oval knot-hole (arched top and bottom), not a door-like slot.
			var holes := [{"rect": Rect2(hole.position + Vector2(0, 0.8), hole.size), "round": true, "segs": 5}] if k == face else []
			kit.wall(t, side, h, th, holes, Palette.vary(bark, 0.05 * float(k % 3) - 0.05), Palette.vary(Palette.c(&"hollow_inside"), 0.05 * float(k % 2)), Palette.c(&"bark_dark"), 8)
			if k == face:
				var centre := t * Vector3(hole.get_center().x, hole.get_center().y + 0.8, th * 0.5)
				ctx.add_opening("tree_hollow_%d" % hi, "tree_hollow", centre, out, hole.size.x, hole.size.y, WorldBuild.span_for_gap(hole.size.x), 0.9, 15)
				ctx.add_refuge("tree_hollow_%d" % hi, Vector3(c.x, centre.y, c.y), 0.5, WorldBuild.span_for_gap(hole.size.x))
		# Cavity floor and roof, then a solid upper trunk carrying the crown.
		kit.prism(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(c.x, g + 0.35, c.y)), FarmBuilder._octagon(apo - th + 0.05), 0.2, Palette.c(&"leaf_litter"))
		kit.prism(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(c.x, g + h - 1.1, c.y)), FarmBuilder._octagon(apo + 0.02), 0.3, bark)
		kit.cyl(Vector3(c.x, g + h - 0.8, c.y), Vector3(c.x, g + h + 1.4, c.y), apo * 1.02, apo * 0.62, 8, Palette.c(&"bark_dark"), false, true, PI / 8.0)
		lib.place(lib.pick(TreeLib.Species.OAK, rng), Vector3(c.x, g + h + 0.6, c.y), rng.randf() * TAU, 1.25, "forest_hollow", &"forest", 2, false, true)
		ctx.add_footprint("hollow_tree_%d" % hi, PackedVector2Array([c]), g - 0.8, 1.5, 3.0, -1.0, kit.name)
		ctx.add_feature(c.x, c.y, 6.0, "tree")
		ctx.add_landmark("hollow_tree_%d" % hi, "nest", Vector3(c.x, g + 2.5, c.y), 1.2)


# --- orchard, village, water ---------------------------------------------

static func _orchard(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var o := WorldLayout.ORCHARD
	var n := 0
	for j in 5:
		for i in 8:
			var p := o + Vector2((i - 3.5) * 9.5, (j - 2.0) * 10.0) + Vector2(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6))
			if not ctx.is_free(p.x, p.y):
				continue
			var sp := TreeLib.Species.BLOSSOM if (i + j * 3) % 4 == 0 else TreeLib.Species.FRUIT
			_plant(ctx, lib, rng, sp, p, "orchard", &"orchard", 0.9, 1.1, 1)
			n += 1
	ctx.add_landmark("orchard", "orchard", Vector3(o.x, ctx.ground(o.x, o.y), o.y), 45.0)


static func _village_trees(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	for p in [Vector2(-108, 21), Vector2(-71, 39), Vector2(-122, 58), Vector2(-60, 60)]:
		if _can_plant(ctx, p, 0.0):
			_plant(ctx, lib, rng, TreeLib.Species.OAK, p, "village_trees", &"village", 1.0, 1.25, 2)
	# Garden trees behind the houses.
	for slot in WorldLayout.HOUSES:
		if rng.randf() < 0.35:
			continue
		var x: float = slot[0] + rng.randf_range(-4, 4)
		var z: float = WorldLayout.STREET_Z + float(slot[1]) * rng.randf_range(23.0, 30.0)
		var p := Vector2(x, z)
		if _can_plant(ctx, p, 1.0):
			var sp: int = [TreeLib.Species.FRUIT, TreeLib.Species.BIRCH, TreeLib.Species.OAK, TreeLib.Species.BLOSSOM][rng.randi() % 4]
			_plant(ctx, lib, rng, sp, p, "village_trees", &"village", 0.85, 1.1, 1)


static func _water_trees(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var r := WorldLayout.RIVER
	var total := WorldLayout.polyline_length(r)
	var s := 60.0
	while s < total - 20.0:
		var at := WorldLayout.polyline_at(r, s)
		var p: Vector2 = at[0]
		var d: Vector2 = at[1]
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var q := p + Vector2(-d.y, d.x) * side * rng.randf_range(15.0, 19.0)
		if p.distance_to(WorldLayout.BRIDGE) > 30.0 and _can_plant(ctx, q, 1.0):
			_plant(ctx, lib, rng, TreeLib.Species.OAK if rng.randf() < 0.6 else TreeLib.Species.BIRCH, q, "river_trees", &"river", 0.8, 1.1, 2)
		s += rng.randf_range(34.0, 52.0)
	# Birches on the lake's north and west shore.
	for i in 12:
		var a := rng.randf_range(PI * 0.9, PI * 1.9)
		var q := WorldLayout.LAKE + Vector2(cos(a) * WorldLayout.LAKE_R.x, sin(a) * WorldLayout.LAKE_R.y).rotated(WorldLayout.LAKE_ROT) * rng.randf_range(1.2, 1.35)
		if _can_plant(ctx, q, 1.0):
			_plant(ctx, lib, rng, TreeLib.Species.BIRCH if i % 3 else TreeLib.Species.OAK, q, "lake_trees", &"lake", 0.85, 1.1, 2)


# --- hedgerows -----------------------------------------------------------

## A clipped hedge between a and b: a boxy body with tunnels (only small
## birds fit) and lumpy blobs along the top. Long runs are split into short
## segments that each follow the ground, so hedges step with the slope.
static func hedge(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, a: Vector2, b: Vector2, name: String) -> void:
	var L := a.distance_to(b)
	if L < 4.0:
		return
	var n := int(ceil(L / 11.0))
	for i in n:
		_hedge_segment(ctx, kit, rng, a.lerp(b, float(i) / n), a.lerp(b, float(i + 1) / n), "%s_%d" % [name, i])


## One ground-following length of hedge. Every length has a small-bird
## tunnel (a mouth on each face into a hollow: the refuge).
static func _hedge_segment(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, a: Vector2, b: Vector2, name: String) -> void:
	var L := a.distance_to(b)
	var dir := (b - a) / L
	var th := 1.4
	var h := rng.randf_range(1.75, 2.0)
	var pts := PackedVector2Array([a, b, a.lerp(b, 0.5), a.lerp(b, 0.25), a.lerp(b, 0.75)])
	var gmin := ctx.ground_min(pts)
	var gmax := ctx.ground_max(pts)
	var base := gmin - 0.4
	var basis := Basis(Vector3(dir.x, 0, dir.y), Vector3.UP, Vector3(-dir.y, 0, dir.x))
	var t := Transform3D(basis, Vector3(a.x, base, a.y))
	var hs := 0.22
	var u := L * 0.5 + rng.randf_range(-1.5, 1.5)
	# The mouth clears the ground a bird crosses to reach it, on both faces
	# (up to 2.5 m out), not just the ground along the hedge's centre line:
	# on a cross-slope the approach can be higher (seed 4242 put the ground
	# 8 cm under a mouth's approach). The hedge grows to keep it enclosed.
	var side := Vector2(-dir.y, dir.x)
	var mp := a + dir * u
	var g_mouth := gmax
	for off: float in [0.8, 1.5, 2.5]:
		g_mouth = maxf(g_mouth, maxf(ctx.ground(mp.x + side.x * off, mp.y + side.y * off), ctx.ground(mp.x - side.x * off, mp.y - side.y * off)))
	var holes := [{"rect": Rect2(u - hs * 0.5, (g_mouth - base) + 0.42, hs, hs)}]
	kit.sway = 0.0
	var hc := Palette.c(&"hedge")
	var hd := Palette.c(&"hedge_dark")
	var top := maxf(gmax + h, g_mouth + 1.45)
	# Irregular vertical bands of two greens read as clipped foliage.
	var splits := PackedFloat32Array()
	var su := rng.randf_range(0.6, 1.4)
	while su < L - 0.3:
		splits.append(su)
		su += rng.randf_range(0.7, 1.6)
	var out := basis.z
	# The body is three pieces: plain lengths either side (one quad per
	# colour band a face, no cells) and a 0.9 m tunnel section. The tunnel
	# is a mouth on each face (30 cm deep) opening into a hollow in the
	# middle of the hedge: a small bird only has to thread the short mouth,
	# not a straight 1.4 m pipe, and the hollow is its refuge. (Cutting the
	# mouth through the whole length, as round 2 did, cut every colour band
	# into cells: twice the triangles.)
	var hgt := top - base
	var sec0 := u - 0.45
	var sec1 := u + 0.45
	var stripe := Palette.vary(hc, -0.07)
	var left := PackedFloat32Array()
	var right := PackedFloat32Array()
	for sp in splits:
		if sp < sec0 - 0.1:
			left.append(sp)
		elif sp > sec1 + 0.1:
			right.append(sp - sec1)
	kit.wall(t, sec0, hgt, th, [], hc, hd, hd, 1 | 4, left, stripe)
	kit.wall(t * Transform3D(Basis.IDENTITY, Vector3(sec1, 0, 0)), L - sec1, hgt, th, [], hc, hd, hd, 2 | 4, right, stripe)
	var ts := t * Transform3D(Basis.IDENTITY, Vector3(sec0, 0, 0))
	var mh := [{"rect": Rect2(0.45 - hs * 0.5, holes[0]["rect"].position.y, hs, hs)}]
	var hollow := [{"rect": Rect2(0.15, (mh[0]["rect"] as Rect2).get_center().y - 0.25, 0.6, 0.5)}]
	var mouth := 0.3
	kit.wall(ts * Transform3D(Basis.IDENTITY, Vector3(0, 0, th * 0.5 - mouth * 0.5)), 0.9, hgt, mouth, mh, hc, hd, hd, 4)
	kit.wall(ts, 0.9, hgt, th - 2.0 * mouth, hollow, hc, hd, hd, 4)
	kit.wall(ts * Transform3D(Basis.IDENTITY, Vector3(0, 0, -th * 0.5 + mouth * 0.5)), 0.9, hgt, mouth, mh, hd, hd, hd, 4)
	for k in holes.size():
		var r: Rect2 = holes[k]["rect"]
		var centre := t * Vector3(r.get_center().x, r.get_center().y, th * 0.5)
		var span := WorldBuild.span_for_gap(hs)
		ctx.add_opening("%s_tunnel" % name, "hedge_gap", centre, out, hs, hs, span, th, 15)
		ctx.add_refuge("%s_tunnel" % name, centre - out * th * 0.5, hs * 0.5, span)
	kit.sway = 0.25
	var u2 := rng.randf_range(0.8, 1.8)
	while u2 < L - 0.8:
		var R := rng.randf_range(0.7, 1.0)
		var c := t * Vector3(u2, top - base - 0.12, rng.randf_range(-0.15, 0.15))
		kit.blob(c, Vector3(R, R * 0.55, R * 0.95), hc if rng.randf() < 0.6 else Palette.c(&"leaf_dark"), 0.22, hd)
		u2 += rng.randf_range(3.2, 4.4)
	# Leafy bulges half sunk into both faces, so a hedge seen from a bird's
	# height is not a flat green board. Built in the hedge's frame (a blob's
	# radii are along the frame's axes), kept a metre clear of the tunnel
	# mouths, with their own RNG (the rest of the valley is unchanged).
	var brng := RandomNumberGenerator.new()
	brng.seed = hash(name) ^ ctx.seed
	var prev_xf := kit.xf
	kit.xf = t
	kit.sway = 0.2
	for sd: float in [-1.0, 1.0]:
		var ub := brng.randf_range(0.7, 2.4)
		while ub < L - 0.7:
			if absf(ub - u) > 1.2:
				var R := brng.randf_range(0.45, 0.7)
				var vv := brng.randf_range(0.6, maxf(0.65, top - base - 0.7))
				kit.blob(Vector3(ub, vv, sd * th * 0.5), Vector3(R, R * 0.75, 0.26), hc if brng.randf() < 0.55 else Palette.c(&"leaf_dark"), 0.2, hd)
			ub += brng.randf_range(2.8, 4.4)
	kit.xf = prev_xf
	# Far stand-in: the body alone, inset 1 cm (inside the real collider).
	var lod: MeshKit = ctx.kits[kit.name.replace("hedges_", "hedges_lod_")]
	lod.sway = 0.0
	lod.box(Transform3D(basis, t * Vector3(L * 0.5, (top - base) * 0.5, 0.0)), Vector3(L - 0.02, top - base - 0.02, th - 0.02), hc, hd, 8)
	if rng.randf() < 0.8:
		ctx.add_perch(t * Vector3(rng.randf_range(1.0, L - 1.0), top - base + 0.3, 0.0), out, Perch.Kind.BRANCH, 0.66, &"fields")
	var mid := a.lerp(b, 0.5)
	ctx.add_feature(mid.x, mid.y, L * 0.5, "hedge")
	ctx.add_footprint(name, pts, base, (gmax - base) + 0.05, 1.5, -1.0, kit.name)


static func _hedgerows(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var kit: MeshKit = null
	var o := WorldLayout.FIELDS_ORIGIN
	var cs := WorldLayout.FIELDS_CELL
	var nx := int(ceil(WorldLayout.FIELDS_SIZE.x / cs.x))
	var ny := int(ceil(WorldLayout.FIELDS_SIZE.y / cs.y))
	var crops: Dictionary = ctx.terrain.south_crops
	var hi := 0
	# Every field edge that borders at least one field gets a hedge, broken
	# by gateways; an oak stands at some hedge corners.
	for j in ny + 1:
		for i in nx:
			var up := (j - 1) * nx + i
			var dn := j * nx + i
			if not ((j > 0 and crops.has(up)) or (j < ny and crops.has(dn))):
				continue
			var a := o + Vector2(i * cs.x, j * cs.y)
			var b := a + Vector2(cs.x, 0)
			_hedge_run(ctx, _hedge_kit(ctx, i), rng, a, b, "hedge_%d" % hi)
			hi += 1
	for i in nx + 1:
		for j in ny:
			var lf := j * nx + i - 1
			var rt := j * nx + i
			if not ((i > 0 and crops.has(lf)) or (i < nx and crops.has(rt))):
				continue
			var a := o + Vector2(i * cs.x, j * cs.y)
			var b := a + Vector2(0, cs.y)
			_hedge_run(ctx, _hedge_kit(ctx, mini(i, nx - 1)), rng, a, b, "hedge_%d" % hi)
			hi += 1
			if rng.randf() < 0.5:
				var p := a + Vector2(rng.randf_range(-3, 3), rng.randf_range(4, cs.y - 4))
				if _can_plant(ctx, p + Vector2(4.5, 0), 0.0):
					_plant(ctx, lib, rng, TreeLib.Species.OAK, p + Vector2(4.5, 0), "hedge_trees", &"fields", 1.0, 1.3, 2)
	ctx.add_landmark("hedgerows", "hedgerow", Vector3(o.x + WorldLayout.FIELDS_SIZE.x * 0.5, 2.0, o.y + WorldLayout.FIELDS_SIZE.y * 0.5), 200.0)


## One kit (draw call, cull unit) per field column, with a far stand-in.
static func _hedge_kit(ctx: WorldBuild, col: int) -> MeshKit:
	var nm := "hedges_%d" % col
	var k := ctx.kit(nm, true)
	ctx.lod_kit("hedges_lod_%d" % col, nm, 160.0, true)
	# Shadows from the stand-in boxes (a hedge's shadow is its outline; the
	# full kit's tunnels and tufts cost as much again in the shadow pass).
	ctx.shadow_proxy[nm] = "hedges_lod_%d" % col
	return k


## A hedge along an edge, split into lengths with a gateway gap.
static func _hedge_run(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, a: Vector2, b: Vector2, name: String) -> void:
	var L := a.distance_to(b)
	var gate := rng.randf_range(0.3, 0.7) * L
	var gw := 5.0
	hedge(ctx, kit, rng, a, a.lerp(b, (gate - gw * 0.5) / L), name + "a")
	hedge(ctx, kit, rng, a.lerp(b, (gate + gw * 0.5) / L), b, name + "b")


static func _bush(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, p: Vector2, s: float, checked := false) -> void:
	if not checked and not _can_plant(ctx, p, 0.5):
		return
	kit.sway = 0.4
	var radii := Vector3(1.0, 0.7, 0.9) * s
	var base := ctx.ground_blob(kit, p, radii, Palette.c(&"hedge"), 0.25, Palette.c(&"hedge_dark"), -0.3)
	ctx.add_footprint("bush", PackedVector2Array([p]), base, 1.0 + ctx.ground_relief(p, radii.x), -1.0, radii.x * 1.3 + 0.3, kit.name)
	ctx.add_feature(p.x, p.y, s, "bush")


# --- foothills and gap filling -------------------------------------------

static func _foothills(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = ctx.seed + 77
	noise.frequency = 0.012
	var placed := 0
	for i in 2600:
		var a := rng.randf() * TAU
		var r0 := ctx.terrain.ring_start(a)
		var r := rng.randf_range(r0 - 10.0, r0 + 150.0)
		var p := Vector2(cos(a), sin(a)) * r
		if r > WorldLayout.BOUNDS - 25.0:
			continue
		if noise.get_noise_2d(p.x, p.y) < 0.05:
			continue
		var g := ctx.ground(p.x, p.y)
		if g > 125.0 or ctx.terrain.normal_at(p.x, p.y).y < 0.72:
			continue
		if not ctx.is_free(p.x, p.y, 2.0):
			continue
		var sector := int(fposmod(a, TAU) / TAU * 8.0)
		_plant(ctx, lib, rng, TreeLib.Species.SPRUCE if rng.randf() < 0.85 else TreeLib.Species.PINE, p, "foothills_%d" % sector, &"foothills",
			0.8, 1.2, 1 if rng.randf() < 0.3 else 0, true)
		ctx.block_circle(p.x, p.y, 6.0)
		placed += 1
		if placed >= 170:
			break
	ctx.timings["foothill_trees"] = placed


## Coverage raster (10 m) of everything within 110 m of a feature; each
## uncovered stretch of the inner valley (outside the meadow's deliberate
## open space and the water) gets a copse with a boulder or two.
static func _fill_gaps(ctx: WorldBuild, lib: TreeLib, rng: RandomNumberGenerator) -> void:
	var cell := 10.0
	var half := WorldLayout.INNER_R
	var n := int(half * 2.0 / cell)
	# Untyped Array: shared by reference with the lambda below.
	var cov := []
	cov.resize(n * n)
	cov.fill(0)
	var reach := 105.0
	var mark := func(x: float, z: float, rad: float) -> void:
		var rr := reach + rad
		var i0 := maxi(0, int((x - rr + half) / cell))
		var i1 := mini(n - 1, int((x + rr + half) / cell))
		var j0 := maxi(0, int((z - rr + half) / cell))
		var j1 := mini(n - 1, int((z + rr + half) / cell))
		for j in range(j0, j1 + 1):
			var cz := -half + (j + 0.5) * cell
			for i in range(i0, i1 + 1):
				var cx := -half + (i + 0.5) * cell
				if (cx - x) * (cx - x) + (cz - z) * (cz - z) <= rr * rr:
					cov[j * n + i] = 1
	# Thousands of features (every tree of the wood) cover the same few
	# cells: mark one per 20 m bucket, with the bucket's reach (a feature's
	# radius plus its offset from the bucket centre).
	var buckets := {}
	var add := func(x: float, z: float, rad: float) -> void:
		var key := Vector2i(floori(x / 20.0), floori(z / 20.0))
		var bc := Vector2((key.x + 0.5) * 20.0, (key.y + 0.5) * 20.0)
		var rr: float = rad - bc.distance_to(Vector2(x, z))
		buckets[key] = maxf(float(buckets.get(key, -INF)), rr)
	for f in ctx.features:
		add.call(f.x, f.y, f.z)
	for inst in lib.instances:
		var p: Vector3 = inst["pos"]
		add.call(p.x, p.z, 3.0)
	for key in buckets:
		mark.call((key.x + 0.5) * 20.0, (key.y + 0.5) * 20.0, float(buckets[key]))
	var copses := 0
	var rocks_kit := ctx.kit("boulders")
	for j in n:
		for i in n:
			if cov[j * n + i] != 0:
				continue
			var cx := -half + (i + 0.5) * cell
			var cz := -half + (j + 0.5) * cell
			var cpos := Vector2(cx, cz)
			if cpos.length() > half:
				continue
			if cpos.distance_to(WorldLayout.MEADOW) < WorldLayout.MEADOW_CLEAR + 15.0:
				continue
			# Find a plantable spot near the gap's centre.
			var placed_any := false
			for attempt in 24:
				var p := cpos + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 45.0)
				if not _can_plant(ctx, p, 2.0):
					continue
				var count := rng.randi_range(3, 6)
				for k in count:
					var q := p + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 13.0)
					if _can_plant(ctx, q, 1.5):
						var sp: int = [TreeLib.Species.OAK, TreeLib.Species.OAK, TreeLib.Species.BIRCH, TreeLib.Species.SPRUCE, TreeLib.Species.SNAG][rng.randi() % 5]
						_plant(ctx, lib, rng, sp, q, "copse_%d_%d" % [floori(p.x / 240.0), floori(p.y / 240.0)], &"copse", 0.85, 1.2, 1)
				boulder(ctx, rocks_kit, rng, p + Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)), rng.randf_range(1.0, 2.2), &"copse")
				mark.call(p.x, p.y, 8.0)
				copses += 1
				placed_any = true
				break
			if not placed_any:
				# Nothing plantable (water, fields): mark it so we move on.
				cov[j * n + i] = 2
	ctx.timings["copses"] = copses


## A lumpy boulder half-sunk in the ground; its top is a perch.
static func boulder(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, p: Vector2, size: float, district: StringName) -> void:
	if not ctx.is_free(p.x, p.y, size * 0.5):
		return
	var radii := Vector3(size * rng.randf_range(0.9, 1.4), size * rng.randf_range(0.55, 0.9), size * rng.randf_range(0.8, 1.2))
	kit.sway = 0.0
	var col: Color = [Palette.c(&"rock"), Palette.c(&"rock_light"), Palette.c(&"sandstone")][rng.randi() % 3]
	# Sunk a fifth of its height below the lowest ground under it.
	var base := ctx.ground_blob(kit, p, radii, col, 0.22, Palette.c(&"rock"), -0.38, radii.y * 0.2)
	# Centre = bottom + 0.38 ry; the top is ~0.85-1.2 ry above the centre
	# (perch validation snaps the perch onto the surface).
	var centre_y := base + radii.y * 0.38
	ctx.add_perch(Vector3(p.x, centre_y + radii.y * 0.95, p.y), Vector3.FORWARD, Perch.Kind.ROCK, 2.1, district)
	ctx.add_feature(p.x, p.y, size, "boulder")
	ctx.add_footprint("boulder", PackedVector2Array([p]), base, radii.y * 0.2 + ctx.ground_relief(p, radii.x) + 0.05, 1.0, radii.x * 1.3 + 0.5, kit.name)
