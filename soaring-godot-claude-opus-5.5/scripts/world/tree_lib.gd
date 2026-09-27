class_name TreeLib
extends RefCounted
## Procedural low-poly trees with real branch structure.
##
## A handful of variants per species are built once (mesh + collider specs
## + perch candidates + the drawn wood pieces, all in local space);
## placements then reuse them with a yaw and a quantised scale. Instances
## are merged per chunk into single meshes by transforming each variant's
## packed arrays in bulk (C++), and every tree gets its own StaticBody3D:
## capsules for trunk, limbs and twigs (thin things must not be tunnelled
## through), convex hulls of the very vertices drawn for leaf clumps and
## conifer tiers.

## OAK_TALL: forest-grown broadleaf of the old wood (tall clean bole, high
## crown, dead stubs low on the trunk). SAPLING: understory growth.
enum Species { OAK, BIRCH, SPRUCE, PINE, SNAG, FRUIT, BLOSSOM, OAK_TALL, SAPLING }

## Three levels of detail, handed over exactly by visibility parents (HLOD):
## a chunk's full trees show while the camera is within its mid stand-in's
## begin distance, the mid stand-in shows until its far group takes over,
## the group's far stand-in beyond that. Each switch is measured from one
## node's centre, so exactly one level of every tree is drawn (the round-2
## setup overlapped mid and far for 40 m and drew both there).
##
## Stand-ins match the full tree's SILHOUETTE (projected area from four
## sides and from above within 15 % for the mid level and 22 % for the far
## one, pinned by the world suite's test_tree_stand_ins_keep_the_silhouette),
## not the colliders: the round-2 stand-ins were inscribed in the colliders,
## which made a wood seen from 60 m look like sparse parasols and made
## crowns jump in size as a bird flew in. Their vertices may therefore stand
## a little outside the colliders; the suite bounds that by the distance
## they are seen from (under 1 degree).
##
## Mid stand-in (per chunk, from its begin distance): the main stem as one
## 4-sided tube, a hexagonal bipyramid (12 triangles) through each leaf
## clump's own extreme points (the smallest tufts dropped), and the
## spruce's own 7-sided tiers. Chunks can override the distance
## (chunk_lod): the dense wood uses small chunks and a short distance so
## hundreds of trees stay within the Quest budget.
const LOD_DIST := 150.0
## Far stand-in (per group of chunks): a 3-sided stem and one faceted crown
## (a hexagonal "lozenge" through the crown's own extents; one 5-sided cone
## for a spruce; an octahedron per bigger tuft for the sparse birch and
## pine crowns), about 18-30 triangles a tree.
const FAR_DIST := 300.0
## Hysteresis at every switch (m): a bird hovering at a switch distance
## does not make trees flicker between levels.
const LOD_MARGIN := 6.0
## Silhouette calibration (measured with silhouette_area: world_diag.tscn
## -- --silhouettes, and pinned by the suite): [radial, vertical] scale of a
## clump's bipyramid about its centre. A bipyramid through a clump's own
## extremes is pointed where the clump is round, so it is pushed out a
## little to cover as much; a bit less than alone because clumps overlap.
const MID_CLUMP_SCALE := [1.1, 1.22]
const MID_POLE_MAX := 0.38
## Far crown [radial, vertical] scale by species: the rings through the
## crown's extents already cover the gaps between clumps seen from above,
## so they are drawn in a little; sparse crowns (pine, birch) more so.
const FAR_CROWN := {
	Species.OAK: [0.97, 1.32], Species.OAK_TALL: [1.0, 1.28], Species.FRUIT: [1.0, 1.35],
	Species.BLOSSOM: [1.0, 1.3],
}
## Sparse crowns (a birch's tufts up a tall stem, a pine's flat plates) are
## no lozenge: far away they keep an octahedron per bigger clump.
const FAR_SPARSE := [Species.BIRCH, Species.PINE]
const FAR_SPARSE_SCALE := 1.16
const FAR_CONE_SCALE := 1.0
## Snags have no crown: their far stand-in thickens the limbs instead.
const FAR_SNAG_LIMB := 2.2
## Mid stand-ins drop clumps smaller than this fraction of the biggest (twig
## tufts inside the crown's outline) and cover for them with MID_CLUMP_SCALE.
const MID_MIN_CLUMP := 0.5

## chunk key -> mid stand-in begin distance (m) where it differs from LOD_DIST.
var chunk_lod := {}
## chunk key -> far group key: the far stand-ins of several small chunks
## are merged into one mesh (one draw call per group for distant woods).
## Shadow casters stay per chunk (the shadow frustum culls them tighter).
var far_group := {}
## far group key -> far begin distance (m) where it differs from FAR_DIST.
var group_far := {}
## Chunks whose shadows switch to one crown silhouette per tree beyond
## SHADOW_NEAR (the dense wood: its dappled casters were ~1/6 of the frame).
var coarse_shadow := {}
const SHADOW_NEAR := 45.0
## Chunk size (m) for trees outside the wood (see commit).
const GROVE_CELL := 100.0

var variants: Array[Dictionary] = []
## Variant indices by species.
var by_species := {}
var instances: Array[Dictionary] = []
var _shape_cache := {}
var _rng: RandomNumberGenerator


func _init(rng: RandomNumberGenerator) -> void:
	_rng = rng


func make_variants() -> void:
	for sp in [[Species.OAK, 4], [Species.BIRCH, 2], [Species.SPRUCE, 3], [Species.PINE, 2], [Species.SNAG, 2], [Species.FRUIT, 2], [Species.BLOSSOM, 1],
			[Species.OAK_TALL, 4], [Species.SAPLING, 3]]:
		for i in sp[1]:
			var v := _make(sp[0])
			v["species"] = sp[0]
			variants.append(v)
			if not by_species.has(sp[0]):
				by_species[sp[0]] = []
			by_species[sp[0]].append(variants.size() - 1)


func pick(species: int, rng: RandomNumberGenerator) -> int:
	var arr: Array = by_species[species]
	return arr[rng.randi() % arr.size()]


## Registers a tree. scale is quantised (shapes are cached per step).
## perch_budget: how many of the variant's perch candidates to publish.
func place(variant: int, pos: Vector3, yaw: float, scale: float, chunk: String, district: StringName, perch_budget := 2, simple_collision := false, mounted := false) -> Dictionary:
	var sq := snappedf(clampf(scale, 0.45, 1.6), 0.05)
	# mounted: stands on a structure (a hollow trunk), not on the ground.
	var inst := {"v": variant, "pos": pos, "yaw": yaw, "s": sq, "chunk": chunk, "district": district,
		"perches": perch_budget, "simple": simple_collision, "mounted": mounted}
	instances.append(inst)
	return inst


func instance_xform(inst: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, inst["yaw"]).scaled(Vector3.ONE * float(inst["s"])), inst["pos"])


## Appends src (a variant's [verts, normals, colours]) transformed by xf.
## Packed arrays are copy-on-write: each is taken out of its slot first so
## the append grows it in place instead of copying it.
static func _append(dst: Array, src: Array, xf: Transform3D, rot: Transform3D) -> void:
	var v: PackedVector3Array = dst[0]
	var n: PackedVector3Array = dst[1]
	var c: PackedColorArray = dst[2]
	dst[0] = null
	dst[1] = null
	dst[2] = null
	v.append_array(xf * (src[0] as PackedVector3Array))
	n.append_array(rot * (src[1] as PackedVector3Array))
	c.append_array(src[2])
	dst[0] = v
	dst[1] = n
	dst[2] = c


static func _array_mesh(arr: Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = arr[0]
	arrays[Mesh.ARRAY_NORMAL] = arr[1]
	arrays[Mesh.ARRAY_COLOR] = arr[2]
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Builds all chunk meshes and tree bodies; publishes perches, features and
## footprints into ctx.
func commit(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	# Trees outside the wood (groves: orchard, gardens, riverside, copses,
	# foothills) are chunked on a GROVE_CELL grid whatever district placed
	# them, with far groups of 2 x 2 cells: a chunk must be small for its
	# switch distance to mean something (the round-2 foothill "chunks" were
	# 45-degree sectors of the ring, so a tree beside the camera could be
	# drawn as a far stand-in because its sector's centre was 200 m away).
	for inst in instances:
		var key: String = inst["chunk"]
		if chunk_lod.has(key):
			continue
		var p: Vector3 = inst["pos"]
		var ci := floori(p.x / GROVE_CELL)
		var cj := floori(p.z / GROVE_CELL)
		inst["chunk"] = "grove_%d_%d" % [ci, cj]
		far_group[inst["chunk"]] = "grove_g%d_%d" % [floori(ci / 2.0), floori(cj / 2.0)]
	# Chunk meshes are concatenated from each variant's packed arrays with
	# bulk (C++) transforms: far cheaper than SurfaceTool.append_from, which
	# re-reads the source mesh for every instance.
	var chunks := {}
	var lods := {}
	var shadows := {}
	var coarse := {}
	var fars := {}
	var centres := {}
	var gcentres := {}
	for inst in instances:
		var key: String = inst["chunk"]
		var gkey: String = far_group.get(key, key)
		if not centres.has(key):
			centres[key] = AABB(inst["pos"], Vector3.ZERO)
		centres[key] = (centres[key] as AABB).expand(inst["pos"])
		if not gcentres.has(gkey):
			gcentres[gkey] = AABB(inst["pos"], Vector3.ZERO)
		gcentres[gkey] = (gcentres[gkey] as AABB).expand(inst["pos"])
	for inst in instances:
		var key: String = inst["chunk"]
		var gkey: String = far_group.get(key, key)
		if not chunks.has(key):
			for d in [chunks, lods, shadows]:
				d[key] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray()]
		if not fars.has(gkey):
			fars[gkey] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray()]
			coarse[gkey] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray()]
		var v: Dictionary = variants[inst["v"]]
		# Meshes are built around their chunk's centre so the node origin and
		# the AABB centre coincide (visibility ranges measure from there).
		var xf := instance_xform(inst)
		var rot := Transform3D(Basis(Vector3.UP, inst["yaw"]), Vector3.ZERO)
		var local := Transform3D(Basis.IDENTITY, -(centres[key] as AABB).get_center()) * xf
		_append(chunks[key], v["full"], local, rot)
		# Understory saplings stand under the canopy: past the full-detail
		# distance they are hidden anyway, so they get no stand-ins.
		if v["species"] == Species.SAPLING:
			continue
		_append(lods[key], v["lod_arr"], local, rot)
		# Near shadows come from the mid stand-in (dappled light under the
		# canopy), farther ones from one crown silhouette per tree.
		_append(shadows[key], v["lod_arr"], local, rot)
		var glocal := Transform3D(Basis.IDENTITY, -(gcentres[gkey] as AABB).get_center()) * xf
		if coarse_shadow.has(key):
			_append(coarse[gkey], v["crude_arr"], glocal, rot)
		_append(fars[gkey], v["far_arr"], glocal, rot)
	# Build every mesh first: the switch distances depend on where the
	# meshes' bounds put their centres (visibility ranges measure from there).
	var far_nodes := {}
	for gkey in fars:
		if not (fars[gkey][0] as PackedVector3Array).is_empty():
			far_nodes[gkey] = _tree_mesh(ctx, "trees_far_" + gkey, fars[gkey], (gcentres[gkey] as AABB).get_center(), "trees_" + gkey)
	var full_nodes := {}
	var lod_nodes := {}
	for key in chunks:
		var centre := (centres[key] as AABB).get_center()
		full_nodes[key] = _tree_mesh(ctx, "trees_" + key, chunks[key], centre, "trees_" + key)
		if not (lods[key][0] as PackedVector3Array).is_empty():
			lod_nodes[key] = _tree_mesh(ctx, "trees_lod_" + key, lods[key], centre, "trees_" + key)
		if not (shadows[key][0] as PackedVector3Array).is_empty():
			var sh := _tree_mesh(ctx, "trees_shadow_" + key, shadows[key], centre, "trees_" + key, true)
			if coarse_shadow.has(key):
				sh.visibility_range_end = SHADOW_NEAR
				sh.visibility_range_end_margin = 5.0
	# Farther shadows: one crown silhouette per tree, merged per far group
	# (one shadow draw for four chunks). A group's casters start where its
	# nearest chunk's own near casters may already have stopped (its begin
	# is pulled in by the chunk-to-group offset), so no tree ever loses its
	# shadow; near a group both may cast (harmless: shadows do not add up).
	for gkey in coarse:
		if (coarse[gkey][0] as PackedVector3Array).is_empty():
			continue
		var gc := (gcentres[gkey] as AABB).get_center()
		var sf := _tree_mesh(ctx, "trees_shadowfar_" + gkey, coarse[gkey], gc, "trees_" + gkey, true)
		var off := 0.0
		for key in chunks:
			if far_group.get(key, key) == gkey and coarse_shadow.has(key):
				off = maxf(off, _mesh_centre(full_nodes[key]).distance_to(_mesh_centre(sf)))
		sf.visibility_range_begin = maxf(0.0, SHADOW_NEAR - off - 5.0)
		sf.visibility_range_begin_margin = 5.0
	# A group's far stand-in may only take over once none of its chunks can
	# still be at full detail: its begin distance covers the farthest chunk
	# centre (else a tree could show at full detail and as a far stand-in).
	var far_begin := {}
	for gkey in far_nodes:
		far_begin[gkey] = float(group_far.get(gkey, FAR_DIST))
	for key in lod_nodes:
		var gkey: String = far_group.get(key, key)
		if far_nodes.has(gkey):
			var off := _mesh_centre(lod_nodes[key]).distance_to(_mesh_centre(far_nodes[gkey]))
			far_begin[gkey] = maxf(far_begin[gkey], float(chunk_lod.get(key, LOD_DIST)) + 2.0 * LOD_MARGIN + off + 1.0)
	for gkey in far_nodes:
		var fm: MeshInstance3D = far_nodes[gkey]
		fm.visibility_range_begin = far_begin[gkey]
		fm.visibility_range_begin_margin = LOD_MARGIN
		# The nearest a far stand-in is ever seen from (W10 bounds how far it
		# may stray from the colliders by this).
		fm.set_meta(&"stand_in_min_dist", far_begin[gkey] - LOD_MARGIN - fm.mesh.get_aabb().size.length() * 0.5)
	for key in chunks:
		var full: MeshInstance3D = full_nodes[key]
		var dist: float = chunk_lod.get(key, LOD_DIST)
		if lod_nodes.has(key):
			var lod: MeshInstance3D = lod_nodes[key]
			lod.visibility_range_begin = dist
			lod.visibility_range_begin_margin = LOD_MARGIN
			lod.set_meta(&"stand_in_min_dist", dist - LOD_MARGIN - lod.mesh.get_aabb().size.length() * 0.5)
			var gkey: String = far_group.get(key, key)
			if far_nodes.has(gkey):
				# Shown only while its far group is not (see the header).
				lod.visibility_parent = lod.get_path_to(far_nodes[gkey])
			# Full detail shows exactly while the mid stand-in is too close.
			full.visibility_parent = full.get_path_to(lod)
		else:
			# Understory only (no stand-ins): hidden past the switch.
			full.visibility_range_end = dist
			full.visibility_range_end_margin = LOD_MARGIN
	var bodies := Node3D.new()
	bodies.name = "tree_bodies"
	ctx.body_root.add_child(bodies)
	for idx in instances.size():
		var inst: Dictionary = instances[idx]
		var v: Dictionary = variants[inst["v"]]
		var s: float = inst["s"]
		var rot := Transform3D(Basis(Vector3.UP, inst["yaw"]), inst["pos"])
		var body := StaticBody3D.new()
		body.name = "tree_%d" % idx
		body.collision_layer = 1 | 2
		body.collision_mask = 0
		body.set_meta(&"collider_group", "trees_" + String(inst["chunk"]))
		# Shapes first, then enter the tree: a body already in the physics
		# space rebuilds its compound shape on every added shape.
		for sh in _shapes_for(inst["v"], s, inst["simple"]):
			var o := body.create_shape_owner(body)
			body.shape_owner_add_shape(o, sh[0])
			body.shape_owner_set_transform(o, rot * (sh[1] as Transform3D))
		bodies.add_child(body)
		# Perches: a random subset of the variant's candidates.
		var cands: Array = v["perches"]
		var budget: int = inst["perches"]
		if budget > 0 and not cands.is_empty():
			var order := range(cands.size())
			for i in range(order.size() - 1, 0, -1):
				var j := rng.randi() % (i + 1)
				var tmp: int = order[i]
				order[i] = order[j]
				order[j] = tmp
			for k in mini(budget, cands.size()):
				var c: Array = cands[order[k]]
				var xf := instance_xform(inst)
				ctx.add_perch(xf * (c[0] as Vector3), xf.basis * (c[1] as Vector3), c[3], minf(float(c[2]) * s, 2.1), inst["district"])
		var p: Vector3 = inst["pos"]
		ctx.add_feature(p.x, p.z, float(v["crown"]) * s, "tree")
		if not inst["mounted"]:
			ctx.add_footprint("tree", PackedVector2Array([Vector2(p.x, p.z)]), p.y - 0.5 * s, 1.5, -1.0, -1.0, body)


## Where a visibility range measures from: the mesh bounds' centre.
static func _mesh_centre(mi: MeshInstance3D) -> Vector3:
	return mi.position + mi.mesh.get_aabb().get_center()


## One merged tree mesh under Visual. shadow_only: a caster that is never
## drawn (it need not match anything visible).
func _tree_mesh(ctx: WorldBuild, nm: String, arr: Array, centre: Vector3, group: String, shadow_only := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = _array_mesh(arr)
	mi.material_override = Palette.foliage_material()
	mi.position = centre
	if shadow_only:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.set_meta(&"shadow_only", true)
	else:
		# Shadows come from the cheap shadow-only casters instead.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ctx.visual_root.add_child(mi)
	mi.set_meta(&"collider_group", group)
	return mi


func _shapes_for(vi: int, s: float, simple: bool) -> Array:
	var key := "%d_%.2f_%s" % [vi, s, simple]
	if _shape_cache.has(key):
		return _shape_cache[key]
	var out := []
	var v: Dictionary = variants[vi]
	var specs: Array = v["simple_colliders"] if simple and v.has("simple_colliders") else v["colliders"]
	for c in specs:
		if c[0] == "cap":
			var a: Vector3 = c[1] * s
			var b: Vector3 = c[2] * s
			var r: float = c[3] * s
			var d := b - a
			var l := d.length()
			var cap := CapsuleShape3D.new()
			cap.radius = r
			cap.height = l + 2.0 * r
			var yv := d / l if l > 1e-5 else Vector3.UP
			var ref := Vector3.RIGHT if absf(yv.x) < 0.9 else Vector3.FORWARD
			var xv := yv.cross(ref).normalized()
			out.append([cap, Transform3D(Basis(xv, yv, xv.cross(yv)), (a + b) * 0.5)])
		else:
			var hull := ConvexPolygonShape3D.new()
			var pts := PackedVector3Array()
			for q in (c[1] as PackedVector3Array):
				pts.append(q * s)
			hull.points = pts
			out.append([hull, Transform3D.IDENTITY])
	_shape_cache[key] = out
	return out


# --- variant construction ----------------------------------------------

func _make(sp: int) -> Dictionary:
	var kit := MeshKit.new("tree", _rng.randi())
	kit.collide = false
	kit.jitter = 0.06
	var v := {"species": sp, "colliders": [], "perches": [], "crown": 4.0, "mounts": [], "clumps": [], "trunks": [], "tiers": [],
		"wood": []}
	match sp:
		Species.OAK:
			_broadleaf(kit, v, 1.0, [&"leaf", &"leaf_light", &"leaf_dark", &"leaf"])
		Species.BIRCH:
			_birch(kit, v)
		Species.SPRUCE:
			_spruce(kit, v)
		Species.PINE:
			_pine(kit, v)
		Species.SNAG:
			_snag(kit, v)
		Species.FRUIT:
			_fruit(kit, v, false)
		Species.BLOSSOM:
			_fruit(kit, v, true)
		Species.OAK_TALL:
			_forest_broadleaf(kit, v)
		Species.SAPLING:
			_sapling(kit, v)
	v["full"] = [kit.verts, kit.norms, kit.cols]
	v["tris"] = kit.tri_count()
	# The lowest drawn point (the trunk's foot), for the grounding test.
	var foot := INF
	for q in kit.verts:
		foot = minf(foot, q.y)
	v["foot_y"] = foot
	if sp == Species.SNAG:
		# A snag is all limbs: few in the valley, so the mid level is the
		# tree itself (a stand-in of thin tubes would lose the silhouette).
		v["lod_arr"] = v["full"]
	else:
		var lk := _lod(v)
		v["lod_arr"] = [lk.verts, lk.norms, lk.cols]
	var fk := _far(v)
	v["far_arr"] = [fk.verts, fk.norms, fk.cols]
	var ck := _crude(v)
	v["crude_arr"] = [ck.verts, ck.norms, ck.cols]
	return v


## The stem as one straight piece: from the first trunk segment's foot
## along the chain of segments that continue it (a birch's banded pieces,
## an oak's bole) to the last one's top. [a, b, r] or [] for none.
static func _stem(v: Dictionary) -> Array:
	var tr: Array = v["trunks"]
	if tr.is_empty():
		return []
	var a: Vector3 = tr[0][0]
	var b: Vector3 = tr[0][1]
	var r: float = tr[0][2]
	for i in range(1, tr.size()):
		if (tr[i][0] as Vector3).distance_to(b) < 1e-3:
			b = tr[i][1]
		else:
			break
	return [a, b, r, tr[0][4]]


## An octahedron with vertices at c +- radii along a frame turned by yaw.
## Upper faces lit, lower ones shaded (the blob's fake occlusion).
static func _octa(k: MeshKit, c: Vector3, rd: Vector3, yaw: float, col: Color, top_only := false) -> void:
	var ax := Vector3(cos(yaw), 0.0, sin(yaw))
	var az := Vector3(-sin(yaw), 0.0, cos(yaw))
	var ring := [c + ax * rd.x, c + az * rd.z, c - ax * rd.x, c - az * rd.z]
	var py := c + Vector3(0, rd.y, 0)
	var ny := c - Vector3(0, rd.y, 0)
	var dark := Palette.vary(col, -0.25)
	for i in 4:
		var p: Vector3 = ring[i]
		var q: Vector3 = ring[(i + 1) % 4]
		# ring runs +x -> +z (clockwise seen from above): (py, q, p) is CCW
		# from outside.
		k.tri(py, q, p, Palette.vary(col, [0.0, 0.06, 0.0, -0.06][i]))
		if not top_only:
			k.tri(ny, p, q, dark)


## A leaf clump's stand-in: a hexagonal bipyramid through the clump's own
## points (six horizontal extents, its top and bottom), scaled about the
## clump's centre by s = [radial, vertical]: 12 triangles for the
## icosahedron's 20, standing at most (s - 1) of the clump's reach proud
## of it (its poles are pushed further: a bipyramid seen from the side is
## pointed where the clump is round).
static func _clump_standin(k: MeshKit, c: Vector3, pts: PackedVector3Array, yaw: float, s: Array, col: Color, col2: Color) -> void:
	var top := c
	var bot := c
	for p in pts:
		if p.y > top.y:
			top = p
		if p.y < bot.y:
			bot = p
	# The ring runs through the clump's own farthest point six ways round,
	# each at that point's height (an icosahedron's extremes are not all on
	# its equator), pushed out by s[0].
	var ring: Array[Vector3] = []
	for i in 6:
		var d := Vector3(cos(yaw + TAU * i / 6.0), 0.0, sin(yaw + TAU * i / 6.0))
		var e := -INF
		var ep := c
		for p in pts:
			var reach := (p - c).dot(d)
			if reach > e:
				e = reach
				ep = p
		ring.append(Vector3(c.x + (ep.x - c.x) * float(s[0]), clampf(ep.y, bot.y + 0.05, top.y - 0.05), c.z + (ep.z - c.z) * float(s[0])))
	# Poles over the clump's own highest and lowest points, pushed out by
	# at most MID_POLE_MAX (a big clump's pole would otherwise stand most
	# of a metre proud of it).
	var t := Vector3(top.x, top.y + minf((top.y - c.y) * (float(s[1]) - 1.0), MID_POLE_MAX), top.z)
	var b := Vector3(bot.x, bot.y - minf((c.y - bot.y) * (float(s[1]) - 1.0), MID_POLE_MAX), bot.z)
	for i in 6:
		var p := ring[i]
		var q := ring[(i + 1) % 6]
		k.tri(t, q, p, Palette.vary(col, [0.0, 0.05, 0.0, -0.05, 0.03, -0.03][i]))
		k.tri(b, p, q, col2)


## Mid stand-in (see the header): one 4-sided stem, a bipyramid per leaf
## clump (the smallest tufts dropped), the spruce's own 7-sided tiers.
func _lod(v: Dictionary) -> MeshKit:
	var k := MeshKit.new("lod", 7)
	k.collide = false
	k.jitter = 0.04
	k.sway = 0.0
	var st := _stem(v)
	if not st.is_empty():
		k.cyl(st[0], st[1], st[2] * 0.95, st[2] * 0.8, 4, st[3], false, false, 0.4)
	var biggest := 0.0
	for c in v["clumps"]:
		biggest = maxf(biggest, (c[1] as Vector3).x)
	var i := 0
	for c in v["clumps"]:
		i += 1
		var rd: Vector3 = c[1]
		if rd.x < biggest * MID_MIN_CLUMP:
			continue
		k.sway = 1.0
		_clump_standin(k, c[0], c[3], 0.7 * i, MID_CLUMP_SCALE, c[2], c[4])
	var lowest := true
	for t in v["tiers"]:
		# The full tree's own seven-sided tiers (exact), only the lowest
		# capped: the stubs, the leader and the hidden tier bases go.
		k.sway = 0.5
		k.cyl(t[0], t[1], t[2], 0.0, 7, t[3], lowest, false, t[4])
		lowest = false
	return k


## Crown frame shared by the far stand-in and the far shadow caster:
## {"c": centre, "top", "bottom", "ext": 6 radial extents, "col"} of the
## leaf clumps; empty for conifers and snags.
static func _crown(v: Dictionary) -> Dictionary:
	var cl: Array = v["clumps"]
	if cl.is_empty() or not (v["tiers"] as Array).is_empty():
		return {}
	# Measured on the clumps' own points (an icosahedron reaches only ~0.85
	# of its nominal radius along most axes), so the stand-in's points sit
	# on the crown, not beyond it.
	var c := Vector3.ZERO
	var wsum := 0.0
	var top := -INF
	var top_at := Vector3.ZERO
	var bottom := INF
	var col: Color = cl[0][2]
	var biggest := 0.0
	for q in cl:
		var rd: Vector3 = q[1]
		var w := rd.x * rd.y * rd.z
		c += (q[0] as Vector3) * w
		wsum += w
		for p in (q[3] as PackedVector3Array):
			if p.y > top:
				top = p.y
				top_at = p
			bottom = minf(bottom, p.y)
		if rd.x > biggest:
			biggest = rd.x
			col = q[2]
	c /= wsum
	var ext := PackedFloat32Array()
	var ext_y := PackedFloat32Array()
	var ext_hi := PackedFloat32Array()
	var ext_hi_y := PackedFloat32Array()
	var ext_at: Array[Vector3] = []
	var ext_hi_at: Array[Vector3] = []
	for i in 6:
		var d := Vector3(cos(TAU * i / 6.0), 0.0, sin(TAU * i / 6.0))
		var e := 0.5
		var ey := c.y
		var ep := d * 0.5
		for q in cl:
			for p in (q[3] as PackedVector3Array):
				var reach := Vector3(p.x - c.x, 0.0, p.z - c.z).dot(d)
				if reach > e:
					e = reach
					ey = p.y
					ep = Vector3(p.x - c.x, 0.0, p.z - c.z)
		ext.append(e)
		ext_y.append(ey)
		ext_at.append(ep)
		# The upper crown's own reach that way (usually narrower), and at
		# what height.
		var eh := 0.3
		var ehy := (c.y + top) * 0.5
		var ehp := d * 0.3
		for q in cl:
			for p in (q[3] as PackedVector3Array):
				if p.y >= (c.y + top) * 0.5:
					var reach := Vector3(p.x - c.x, 0.0, p.z - c.z).dot(d)
					if reach > eh:
						eh = reach
						ehy = p.y
						ehp = Vector3(p.x - c.x, 0.0, p.z - c.z)
		ext_hi.append(eh)
		ext_hi_y.append(ehy)
		ext_hi_at.append(ehp)
	var out := {"c": c, "top": top, "top_at": top_at, "bottom": bottom, "ext": ext, "ext_y": ext_y, "ext_hi": ext_hi,
		"ext_hi_y": ext_hi_y, "ext_at": ext_at, "ext_hi_at": ext_hi_at, "col": col}
	var st := _stem(v)
	if not st.is_empty():
		out["stem"] = st[1]
	return out


## The far stand-in (see the header). Also its conifer cone and snag limbs.
func _far(v: Dictionary) -> MeshKit:
	var k := MeshKit.new("far", 11)
	k.collide = false
	k.jitter = 0.0
	k.sway = 0.0
	var st := _stem(v)
	var cr := _crown(v)
	var tiers: Array = v["tiers"]
	if not st.is_empty():
		var top: Vector3 = st[1]
		if not cr.is_empty():
			# Only up into the crown's underside (the rest is hidden in it).
			var cy: float = lerpf(float(cr["bottom"]), (cr["c"] as Vector3).y, 0.5)
			if top.y > cy:
				top = (st[0] as Vector3).lerp(top, (cy - (st[0] as Vector3).y) / maxf(top.y - (st[0] as Vector3).y, 1e-3))
		elif not tiers.is_empty():
			top = Vector3(top.x, (tiers[0][0] as Vector3).y + 0.5, top.z)
		k.cyl(st[0], top, st[2] * 0.95, st[2] * 0.85, 3, st[3], false, false, 0.4)
	if not tiers.is_empty():
		# One cone over the whole tier stack.
		var base: Vector3 = tiers[0][0]
		var apex: Vector3 = tiers[tiers.size() - 1][1]
		var r0 := 0.0
		for t in tiers:
			r0 = maxf(r0, float(t[2]))
		k.sway = 0.5
		k.cyl(base, apex, r0 * FAR_CONE_SCALE, 0.0, 5, tiers[0][3], false, false, 0.3)
	elif v["species"] in FAR_SPARSE:
		k.sway = 1.0
		var biggest := 0.0
		for c in v["clumps"]:
			biggest = maxf(biggest, (c[1] as Vector3).x)
		var i := 0
		for c in v["clumps"]:
			i += 1
			if (c[1] as Vector3).x >= biggest * 0.6:
				_octa(k, c[0], (c[1] as Vector3) * FAR_SPARSE_SCALE, 0.7 * i, c[2])
	elif not cr.is_empty():
		k.sway = 1.0
		_bipyramid(k, cr, FAR_CROWN.get(v["species"], [1.0, 1.28]), false)
	else:
		for t in (v["trunks"] as Array).slice(1):
			k.cyl(t[0], t[1], t[2] * FAR_SNAG_LIMB, t[3] * FAR_SNAG_LIMB, 3, t[4], false, false, 0.4)
	return k


## The far crown: a faceted hexagonal "lozenge" through the crown's own
## extents: its top at the crown's top, two rings of six points round the
## crown's girth (the upper one drawn in, the lower one at the full
## extents), and its underside closing onto the stem, so its outline from
## the side has shoulders like the clumps' (a plain bipyramid is a diamond
## that had to be stretched far past the crown to cover as much). Scaled
## by sc = [radial, vertical]. top_only: the upper part (a shadow caster
## seen from the sun).
static func _bipyramid(k: MeshKit, cr: Dictionary, sc: Array, top_only: bool) -> void:
	var c: Vector3 = cr["c"]
	var col: Color = cr["col"]
	var sr: float = sc[0]
	var sv: float = sc[1]
	var top := float(cr["top"])
	var bottom := float(cr["bottom"])
	var ta: Vector3 = cr.get("top_at", c)
	var t := Vector3(ta.x, c.y + (top - c.y) * sv, ta.z)
	var stem: Vector3 = cr.get("stem", Vector3(c.x, bottom, c.z))
	var b := Vector3(stem.x, lerpf(c.y, bottom, sv), stem.z)
	var hi: Array[Vector3] = []
	var lo: Array[Vector3] = []
	var ext_y: PackedFloat32Array = cr["ext_y"]
	var ext_hi_y: PackedFloat32Array = cr["ext_hi_y"]
	var ext_at: Array = cr["ext_at"]
	var ext_hi_at: Array = cr["ext_hi_at"]
	for i in 6:
		# Two rings through the crown's own extreme points (the farthest
		# point six ways round), each at its point's height: the upper
		# crown's, then the widest girth.
		var yh := clampf(ext_hi_y[i], (c.y + top) * 0.5, top - 0.3)
		hi.append(Vector3(c.x, yh, c.z) + (ext_hi_at[i] as Vector3) * sr)
		lo.append(Vector3(c.x, clampf(ext_y[i], c.y - (c.y - bottom) * 0.5, yh - 0.3), c.z) + (ext_at[i] as Vector3) * sr)
	for i in 6:
		var j := (i + 1) % 6
		var shade := 0.04 * float(i % 3) - 0.04
		k.tri(t, hi[j], hi[i], Palette.vary(col, shade + 0.03))
		k.quad(hi[i], hi[j], lo[j], lo[i], Palette.vary(col, shade - 0.04))
		if not top_only:
			k.tri(b, lo[i], lo[j], Palette.vary(col, -0.25))


## A distant shadow caster: the far crown's upper half (its outline from
## the sun is the crown's), or the cone of a conifer; 4-6 triangles a tree.
func _crude(v: Dictionary) -> MeshKit:
	var k := MeshKit.new("crude", 13)
	k.collide = false
	k.jitter = 0.0
	var cr := _crown(v)
	var tiers: Array = v["tiers"]
	if not tiers.is_empty():
		var r0 := 0.0
		for t in tiers:
			r0 = maxf(r0, float(t[2]))
		k.cyl(tiers[0][0], tiers[tiers.size() - 1][1], r0 * FAR_CONE_SCALE, 0.0, 5, tiers[0][3], false, false, 0.3)
	elif not cr.is_empty():
		_bipyramid(k, cr, FAR_CROWN.get(v["species"], [1.0, 1.28]), true)
	else:
		# Snags: the stem alone.
		var st := _stem(v)
		if not st.is_empty():
			k.cyl(st[0], st[1], st[2] * 0.85, st[2] * 0.85, 3, st[3], false, false, 0.4)
	return k


## Projected area (m^2) of a triangle soup seen along `dir` (orthographic),
## rasterised on a `cell` grid: what a stand-in must match of the full tree
## (tests and diagnostics only; too slow for generation).
static func silhouette_area(verts: PackedVector3Array, dir: Vector3, cell := 0.1) -> float:
	var d := dir.normalized()
	var ref := Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT
	var u := ref.cross(d).normalized()
	var w := d.cross(u)
	var pts := PackedVector2Array()
	pts.resize(verts.size())
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in verts.size():
		var p := Vector2(verts[i].dot(u), verts[i].dot(w))
		pts[i] = p
		lo = lo.min(p)
		hi = hi.max(p)
	var nx := int(ceil((hi.x - lo.x) / cell)) + 1
	var ny := int(ceil((hi.y - lo.y) / cell)) + 1
	var grid := PackedByteArray()
	grid.resize(nx * ny)
	for t in range(0, pts.size(), 3):
		var a := pts[t]
		var b := pts[t + 1]
		var c := pts[t + 2]
		var area := (b - a).cross(c - a)
		if absf(area) < 1e-9:
			continue
		var i0 := maxi(0, int((minf(a.x, minf(b.x, c.x)) - lo.x) / cell))
		var i1 := mini(nx - 1, int((maxf(a.x, maxf(b.x, c.x)) - lo.x) / cell))
		var j0 := maxi(0, int((minf(a.y, minf(b.y, c.y)) - lo.y) / cell))
		var j1 := mini(ny - 1, int((maxf(a.y, maxf(b.y, c.y)) - lo.y) / cell))
		var sg := signf(area)
		for j in range(j0, j1 + 1):
			var py := lo.y + (j + 0.5) * cell
			for i in range(i0, i1 + 1):
				var p := Vector2(lo.x + (i + 0.5) * cell, py)
				if (b - a).cross(p - a) * sg >= 0.0 and (c - b).cross(p - b) * sg >= 0.0 and (a - c).cross(p - c) * sg >= 0.0:
					grid[j * nx + i] = 1
	return float(grid.count(1)) * cell * cell


## One piece of wood. cap_end: draw the end cap (skip it where the end is
## buried in the next piece or a leaf clump: invisible triangles cost the
## same as visible ones).
func _seg(kit: MeshKit, v: Dictionary, a: Vector3, b: Vector3, r0: float, r1: float, sides: int, col: Color, sway: float, perch_kind := Perch.Kind.BRANCH, perch := true, cap_end := true, parent_col := Color(0, 0, 0, 0)) -> void:
	kit.sway = sway
	# The tube starts a little back along its own axis, inside the piece it
	# grows from: where two pieces meet at an angle (a leaning bole, a
	# kinked pine) their end rings lie in different planes, and the open
	# wedge between them showed the sky through the trunk. Not below the
	# ground: a buried foot ends exactly where the grounding test expects.
	var ad := a
	if a.y >= 0.0:
		ad = a - (b - a).normalized() * minf(r0 * 0.6, (b - a).length() * 0.2)
	if parent_col.a > 0.0 and ad != a:
		# That hidden start lies 1-4 mm under the parent piece's surface
		# (both taper): in the Quest's 24-bit depth buffer the two fight from
		# ~6-19 m for a sparrow, ~40 m for an eagle. Drawn in the parent's
		# colour, whichever wins a pixel looks the same (integration
		# hygiene, 2026-09-27: a birch's dark bands flickered through its
		# white bark; tests/shots/integration_coplanar_test.gd). The same
		# cone, cut in two at a.
		# (The hidden part takes no facet jitter: the kit's random stream,
		# which also shapes the leaf clumps and so the stand-ins, stays
		# exactly as it was.)
		var ra := lerpf(r0, r1, ad.distance_to(a) / ad.distance_to(b))
		var jit := kit.jitter
		kit.jitter = 0.0
		kit.cyl(ad, a, r0, ra, sides, parent_col, false, false)
		kit.jitter = jit
		kit.cyl(a, b, ra, r1, sides, col, false, cap_end and r1 > 0.05)
	else:
		kit.cyl(ad, b, r0, r1, sides, col, false, cap_end and r1 > 0.05)
	# Exactly what was drawn (the nest boxes are hung on a flat face of it).
	v["wood"].append([ad, b, r0, r1, sides])
	if sway <= 0.12 and r0 >= 0.12:
		v["trunks"].append([a, b, minf(r0, r1), minf(r0, r1), col])
	var rc := maxf(r0, r1)
	if a.y < 0.0 and (b - a).length() > rc:
		# A capsule reaches rc past its end points. At a buried trunk foot
		# that would put collision below the drawn wood; start it rc up the
		# axis so collider and trunk end together (grounding is measured
		# on the colliders).
		v["colliders"].append(["cap", a + (b - a).normalized() * rc, b, rc])
	else:
		v["colliders"].append(["cap", a, b, rc])
	if not perch:
		return
	var d := b - a
	var h := Vector3(d.x, 0, d.z)
	# Only roughly horizontal wood makes a perch.
	if h.length() < 1e-3 or absf(d.normalized().y) > 0.62:
		return
	for f: float in [0.45, 0.8]:
		var r := lerpf(r0, r1, f)
		var q := a.lerp(b, f) + Vector3(0, r, 0)
		var facing := Vector3(-h.z, 0, h.x).normalized()
		v["perches"].append([q, facing, clampf(r * 17.0, 0.3, 2.1), perch_kind])


func _clump(kit: MeshKit, v: Dictionary, c: Vector3, radii: Vector3, col: Color, col2: Color) -> void:
	kit.sway = 1.0
	kit.blob(c, radii, col, 0.2, col2)
	v["clumps"].append([c, radii, col, kit.last_blob.duplicate(), col2])
	v["colliders"].append(["hull", kit.last_blob.duplicate()])


func _dir(az: float, el: float) -> Vector3:
	return Vector3(cos(az) * cos(el), sin(el), sin(az) * cos(el))


func _broadleaf(kit: MeshKit, v: Dictionary, size: float, leaf_cols: Array) -> void:
	var rng := _rng
	var bark := Palette.c(&"bark")
	var bark_d := Palette.c(&"bark_dark")
	var ht := rng.randf_range(2.9, 4.2) * size
	var r0 := rng.randf_range(0.3, 0.42) * size
	var lean := Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3))
	var t0 := Vector3(0, -0.6, 0)
	var t1 := Vector3(0, ht * 0.5, 0) + lean * 0.4
	var t2 := Vector3(0, ht, 0) + lean
	_seg(kit, v, t0, t1, r0 * 1.15, r0 * 0.9, 7, bark_d, 0.0, Perch.Kind.BRANCH, false, false)
	_seg(kit, v, t1, t2, r0 * 0.9, r0 * 0.72, 7, bark, 0.0, Perch.Kind.BRANCH, false, true, bark_d)
	# Mount radius = the trunk collider's radius there (boxes sit outside it).
	v["mounts"].append([Vector3(0, 1.75, 0) + lean * (1.75 + 0.6) / (ht * 0.5 + 0.6) * 0.4, r0 * 1.15])
	var limbs := rng.randi_range(4, 6)
	var az0 := rng.randf() * TAU
	var crown := 0.0
	var clump_n := 0
	for i in limbs:
		var az := az0 + TAU * float(i) / limbs + rng.randf_range(-0.35, 0.35)
		var el := deg_to_rad(rng.randf_range(24.0, 52.0))
		var L := rng.randf_range(2.8, 4.4) * size
		var start := t2.lerp(t1, rng.randf_range(0.0, 0.35))
		var d1 := _dir(az, el)
		var p1 := start + d1 * L * 0.55
		var d2 := _dir(az + rng.randf_range(-0.3, 0.3), el + deg_to_rad(14.0))
		var p2 := p1 + d2 * L * 0.45
		var rl := r0 * 0.55
		_seg(kit, v, start, p1, rl, rl * 0.68, 5, bark, 0.15, Perch.Kind.BRANCH, true, false)
		_seg(kit, v, p1, p2, rl * 0.68, rl * 0.38, 5, bark, 0.3, Perch.Kind.BRANCH, true, false)
		for tw in (1 if rng.randf() < 0.7 else 2):
			var from := p1.lerp(p2, rng.randf_range(0.2, 0.9))
			var dt := _dir(az + rng.randf_range(-0.9, 0.9), el + deg_to_rad(rng.randf_range(5.0, 35.0)))
			var te := from + dt * rng.randf_range(1.1, 2.0) * size
			_seg(kit, v, from, te, 0.055 * size, 0.032 * size, 4, bark, 0.6)
			var R := rng.randf_range(0.95, 1.4) * size
			_clump(kit, v, te + Vector3(0, R * 0.3, 0), Vector3(R, R * 0.8, R), Palette.c(leaf_cols[rng.randi() % leaf_cols.size()]), Palette.c(&"leaf_dark"))
			clump_n += 1
		var R2 := rng.randf_range(1.2, 1.7) * size
		_clump(kit, v, p2 + Vector3(0, R2 * 0.35, 0), Vector3(R2, R2 * 0.78, R2), Palette.c(leaf_cols[rng.randi() % leaf_cols.size()]), Palette.c(&"leaf_dark"))
		crown = maxf(crown, Vector2(p2.x, p2.z).length() + R2)
	var Rt := rng.randf_range(1.6, 2.1) * size
	_clump(kit, v, t2 + Vector3(0, Rt * 1.05, 0), Vector3(Rt, Rt * 0.85, Rt), Palette.c(leaf_cols[0]), Palette.c(&"leaf_dark"))
	v["crown"] = crown


func _birch(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var H := rng.randf_range(8.5, 11.0)
	var r0 := rng.randf_range(0.15, 0.2)
	var pts := [Vector3(0, -0.5, 0)]
	var bend := Vector3(rng.randf_range(-0.5, 0.5), 0, rng.randf_range(-0.5, 0.5))
	for k in range(1, 5):
		var f := float(k) / 4.0
		pts.append(Vector3(0, H * f, 0) + bend * f * f)
	for k in 4:
		var f0 := float(k) / 4.0
		var f1 := float(k + 1) / 4.0
		var a: Vector3 = pts[k]
		var b: Vector3 = pts[k + 1]
		var mid := a.lerp(b, 0.82)
		# White bark with a dark band near each segment's top (5-sided, and
		# only the very top capped: the pieces abut, their caps are hidden).
		# (Each piece's hidden start takes the colour of the piece it starts
		# in: see _seg.)
		_seg(kit, v, a, mid, lerpf(r0, r0 * 0.35, f0), lerpf(r0, r0 * 0.35, lerpf(f0, f1, 0.82)), 5, Palette.c(&"bark_birch"), 0.1 * f0, Perch.Kind.BRANCH, false, false,
			Palette.c(&"bark_birch_dark"))
		_seg(kit, v, mid, b, lerpf(r0, r0 * 0.35, lerpf(f0, f1, 0.82)), lerpf(r0, r0 * 0.35, f1), 5, Palette.c(&"bark_birch_dark"), 0.1 * f1, Perch.Kind.BRANCH, false, k == 3,
			Palette.c(&"bark_birch"))
	v["mounts"].append([pts[1], r0])
	# Five to seven tufts (each an icosahedron): enough for the airy birch
	# crown, and the wood holds two hundred birches.
	var n := rng.randi_range(4, 6)
	var crown := 0.0
	for i in n:
		var f := rng.randf_range(0.42, 0.92)
		var from: Vector3 = (pts[int(f * 4.0)] as Vector3).lerp(pts[mini(int(f * 4.0) + 1, 4)], fmod(f * 4.0, 1.0))
		var d := _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(20.0, 50.0)))
		var e := from + d * rng.randf_range(1.2, 2.3)
		_seg(kit, v, from, e, 0.05, 0.03, 4, Palette.c(&"bark_birch"), 0.5)
		var R := rng.randf_range(0.8, 1.15)
		_clump(kit, v, e + Vector3(0, R * 0.3, 0), Vector3(R, R * 1.1, R), Palette.c([&"leaf_light", &"leaf_gold", &"leaf_light"][i % 3]), Palette.c(&"leaf"))
		crown = maxf(crown, Vector2(e.x, e.z).length() + R)
	_clump(kit, v, pts[4] + Vector3(0, 0.6, 0), Vector3(1.0, 1.3, 1.0), Palette.c(&"leaf_light"), Palette.c(&"leaf"))
	v["perches"].append([pts[4] + Vector3(0, 1.9, 0), Vector3.FORWARD, 0.4, Perch.Kind.BRANCH])
	v["crown"] = crown


func _spruce(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var H := rng.randf_range(12.0, 16.5)
	var R0 := rng.randf_range(3.0, 3.9)
	var tiers := rng.randi_range(6, 7)
	_seg(kit, v, Vector3(0, -0.6, 0), Vector3(0, H * 0.9, 0), 0.32, 0.08, 6, Palette.c(&"bark_dark"), 0.0, Perch.Kind.BRANCH, false)
	v["mounts"].append([Vector3(0, 1.6, 0), 0.27])
	var y0 := 1.9
	var all_pts := PackedVector3Array()
	for i in tiers:
		var f := float(i) / tiers
		var yb := y0 + f * (H - y0 - 1.5)
		var th := (H - y0) / tiers * 1.75
		var r := R0 * (1.0 - f * 0.86)
		var apex := Vector3(0, minf(yb + th, H), 0)
		var base := Vector3(0, yb, 0)
		var rot := rng.randf() * TAU
		kit.sway = 0.35 + 0.5 * f
		var col := Palette.c(&"conifer") if i % 2 == 0 else Palette.c(&"conifer_dark")
		kit.cyl(base, apex, r, 0.0, 7, col, true, false, rot, Color(0, 0, 0, 0))
		v["tiers"].append([base, apex, r, col, rot])
		var hull := PackedVector3Array()
		var pb := MeshKit._perp_basis(Vector3.UP)
		for k in 7:
			var a := rot + TAU * k / 7.0
			var q: Vector3 = base + ((pb[0] as Vector3) * cos(a) + (pb[1] as Vector3) * sin(a)) * r
			hull.append(q)
			all_pts.append(q)
		hull.append(apex)
		all_pts.append(apex)
		v["colliders"].append(["hull", hull])
		if i == 1 or i == tiers - 3:
			var q := hull[rng.randi() % 7].lerp(apex, 0.2)
			v["perches"].append([q + Vector3(0, 0.02, 0), Vector3(q.x, 0, q.z).normalized(), 1.0, Perch.Kind.BRANCH])
	# Dead stubs under the skirt: weaving obstacles and small-bird perches.
	for i in rng.randi_range(3, 5):
		var y := rng.randf_range(0.9, 1.7)
		var d := _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(-8.0, 12.0)))
		var a := Vector3(0, y, 0) + d * 0.2
		_seg(kit, v, a, a + d * rng.randf_range(0.8, 1.5), 0.045, 0.025, 4, Palette.c(&"bark_dark"), 0.0)
	# The leader: a stiff spike above the top tier, the lookout perch.
	var tip := all_pts[all_pts.size() - 1]
	_seg(kit, v, tip - Vector3(0, 0.3, 0), tip + Vector3(0, 0.45, 0), 0.04, 0.03, 4, Palette.c(&"conifer_dark"), 0.3, Perch.Kind.BRANCH, false)
	var leader: Array = v["colliders"][-1]
	v["perches"].append([tip + Vector3(0, 0.45 + 0.03, 0), Vector3.FORWARD, 1.3, Perch.Kind.BRANCH])
	v["crown"] = R0
	# Distant/foothill copies collide as every capsule (trunk, stubs,
	# leader) plus one hull of all tiers.
	var simple := [["hull", all_pts]]
	for c in v["colliders"]:
		if c[0] == "cap":
			simple.append(c)
	v["simple_colliders"] = simple


func _pine(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var H := rng.randf_range(10.0, 13.0)
	var kink := Vector3(rng.randf_range(-0.8, 0.8), 0, rng.randf_range(-0.8, 0.8))
	var a := Vector3(0, -0.6, 0)
	var m := Vector3(0, H * 0.55, 0) + kink * 0.4
	var t := Vector3(0, H, 0) + kink
	var bark := Palette.c(&"bark_pine")
	_seg(kit, v, a, m, 0.3, 0.22, 6, bark, 0.0, Perch.Kind.BRANCH, false)
	_seg(kit, v, m, t, 0.22, 0.14, 6, bark, 0.05, Perch.Kind.BRANCH, false)
	v["mounts"].append([Vector3(0, 2.5, 0) + kink * 0.1, 0.3])
	var crown := 0.0
	for i in rng.randi_range(3, 4):
		var from := m.lerp(t, rng.randf_range(0.45, 0.95))
		var d := _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(5.0, 25.0)))
		var e := from + d * rng.randf_range(1.8, 2.9)
		_seg(kit, v, from, e, 0.11, 0.06, 5, bark, 0.3)
		var R := rng.randf_range(1.4, 2.0)
		_clump(kit, v, e + Vector3(0, 0.45, 0), Vector3(R, R * 0.45, R * 0.9), Palette.c(&"conifer"), Palette.c(&"conifer_dark"))
		crown = maxf(crown, Vector2(e.x, e.z).length() + R)
	_clump(kit, v, t + Vector3(0, 0.6, 0), Vector3(1.7, 0.8, 1.6), Palette.c(&"conifer"), Palette.c(&"conifer_dark"))
	v["crown"] = crown


func _snag(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var H := rng.randf_range(7.0, 9.5)
	var grey := Palette.c(&"scree")
	var dark := Palette.c(&"bark_dark")
	var a := Vector3(0, -0.6, 0)
	var m := Vector3(rng.randf_range(-0.4, 0.4), H * 0.55, rng.randf_range(-0.4, 0.4))
	var t := m + Vector3(rng.randf_range(-0.5, 0.5), H * 0.45, rng.randf_range(-0.5, 0.5))
	_seg(kit, v, a, m, 0.34, 0.24, 6, dark, 0.0, Perch.Kind.BRANCH, false)
	_seg(kit, v, m, t, 0.24, 0.13, 6, grey, 0.0, Perch.Kind.BRANCH, false, true, dark)
	v["mounts"].append([Vector3(0, 2.0, 0), 0.34])
	v["perches"].append([t + Vector3(0, 0.0, 0), Vector3.FORWARD, 2.1, Perch.Kind.POLE_TOP])
	for i in rng.randi_range(4, 6):
		var from := a.lerp(t, rng.randf_range(0.4, 0.92))
		var d := _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(0.0, 35.0)))
		var p1 := from + d * rng.randf_range(1.2, 2.0)
		var d2 := _dir(atan2(d.z, d.x) + rng.randf_range(-0.6, 0.6), deg_to_rad(rng.randf_range(10.0, 45.0)))
		var p2 := p1 + d2 * rng.randf_range(0.8, 1.5)
		_seg(kit, v, from, p1, 0.12, 0.08, 5, grey, 0.0)
		_seg(kit, v, p1, p2, 0.08, 0.04, 4, grey, 0.0)
	v["crown"] = 2.5


func _fruit(kit: MeshKit, v: Dictionary, blossom: bool) -> void:
	var rng := _rng
	var ht := rng.randf_range(1.4, 1.8)
	var r0 := rng.randf_range(0.15, 0.19)
	var bark := Palette.c(&"bark")
	var top := Vector3(rng.randf_range(-0.15, 0.15), ht, rng.randf_range(-0.15, 0.15))
	_seg(kit, v, Vector3(0, -0.4, 0), top, r0, r0 * 0.8, 6, bark, 0.0, Perch.Kind.BRANCH, false)
	v["mounts"].append([Vector3(0, 1.0, 0), r0])
	var leaf := &"blossom" if blossom else &"leaf"
	var crown := 0.0
	var n := rng.randi_range(3, 4)
	var az0 := rng.randf() * TAU
	for i in n:
		var d := _dir(az0 + TAU * i / n + rng.randf_range(-0.3, 0.3), deg_to_rad(rng.randf_range(30.0, 48.0)))
		var e := top + d * rng.randf_range(1.5, 2.1)
		_seg(kit, v, top, e, r0 * 0.6, r0 * 0.32, 5, bark, 0.2)
		var R := rng.randf_range(0.95, 1.25)
		var cc := e + Vector3(0, R * 0.4, 0)
		_clump(kit, v, cc, Vector3(R, R * 0.85, R), Palette.c(leaf if i % 2 == 0 else (&"blossom" if blossom else &"leaf_light")), Palette.c(&"leaf_dark"))
		crown = maxf(crown, Vector2(e.x, e.z).length() + R)
		if not blossom:
			kit.sway = 1.0
			var hull: PackedVector3Array = v["colliders"][-1][1]
			for f in 2:
				var fd := _dir(rng.randf() * TAU, rng.randf_range(-0.3, 0.6))
				kit.blob(cc + fd * R * 0.97, Vector3.ONE * 0.09, Palette.c(&"fruit"), 0.1)
				# Fruit hangs on the clump's surface: grow its hull to cover it.
				hull.append_array(kit.last_blob)
			v["colliders"][-1][1] = hull
	_clump(kit, v, top + Vector3(0, 2.2, 0), Vector3(1.3, 1.0, 1.3), Palette.c(leaf), Palette.c(&"leaf_dark"))
	v["crown"] = crown


## Forest-grown broadleaf of the old wood: a tall clean bole with a few dead
## stubs (obstacles and perches at flying height), a high crown of upswept
## limbs whose clumps interlock with the neighbours'. Leaner than the field
## oak (fewer clumps, 4-sided outer limbs) because the wood holds hundreds.
func _forest_broadleaf(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var bark := Palette.c(&"bark")
	var bark_d := Palette.c(&"bark_dark")
	var ht := rng.randf_range(5.0, 7.0)
	var r0 := rng.randf_range(0.26, 0.34)
	var lean := Vector3(rng.randf_range(-0.35, 0.35), 0, rng.randf_range(-0.35, 0.35))
	var t0 := Vector3(0, -0.6, 0)
	var t1 := Vector3(0, ht * 0.55, 0) + lean * 0.4
	var t2 := Vector3(0, ht, 0) + lean
	_seg(kit, v, t0, t1, r0 * 1.15, r0 * 0.9, 6, bark_d, 0.0, Perch.Kind.BRANCH, false, false)
	_seg(kit, v, t1, t2, r0 * 0.9, r0 * 0.7, 6, bark, 0.0, Perch.Kind.BRANCH, false, true, bark_d)
	v["mounts"].append([Vector3(0, 1.75, 0) + lean * 0.4 * (1.75 + 0.6) / (ht * 0.55 + 0.6), r0 * 1.15])
	# Dead stubs low on the bole.
	for i in rng.randi_range(1, 3):
		var y := rng.randf_range(2.2, ht * 0.8)
		var d := _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(-10.0, 20.0)))
		var a := Vector3(0, y, 0) + lean * (y / ht) + d * r0 * 0.6
		_seg(kit, v, a, a + d * rng.randf_range(0.9, 1.7), 0.06, 0.03, 4, bark_d, 0.0)
	var limbs := rng.randi_range(3, 5)
	var az0 := rng.randf() * TAU
	var crown := 0.0
	for i in limbs:
		var az := az0 + TAU * float(i) / limbs + rng.randf_range(-0.4, 0.4)
		var el := deg_to_rad(rng.randf_range(24.0, 48.0))
		var L := rng.randf_range(3.0, 4.4)
		var start := t2.lerp(t1, rng.randf_range(0.0, 0.3))
		var p1 := start + _dir(az, el) * L * 0.55
		var p2 := p1 + _dir(az + rng.randf_range(-0.3, 0.3), el + deg_to_rad(10.0)) * L * 0.45
		var rl := r0 * 0.5
		_seg(kit, v, start, p1, rl, rl * 0.68, 4, bark, 0.15, Perch.Kind.BRANCH, true, false)
		_seg(kit, v, p1, p2, rl * 0.68, rl * 0.4, 3, bark, 0.3, Perch.Kind.BRANCH, true, false)
		# Broad, flattish clumps: the canopy of the old wood closes over.
		var R := rng.randf_range(1.4, 1.95)
		_clump(kit, v, p2 + Vector3(0, R * 0.25, 0), Vector3(R * 1.1, R * 0.68, R * 1.1), Palette.c([&"leaf", &"leaf_light", &"leaf_dark", &"leaf"][rng.randi() % 4]), Palette.c(&"leaf_dark"))
		crown = maxf(crown, Vector2(p2.x, p2.z).length() + R * 1.1)
		if rng.randf() < 0.6:
			var from := p1.lerp(p2, rng.randf_range(0.3, 0.8))
			var te := from + _dir(az + rng.randf_range(-1.0, 1.0), el + deg_to_rad(rng.randf_range(0.0, 25.0))) * rng.randf_range(0.9, 1.5)
			_seg(kit, v, from, te, 0.05, 0.03, 3, bark, 0.6, Perch.Kind.BRANCH, true, false)
			var Rt := rng.randf_range(0.95, 1.3)
			_clump(kit, v, te + Vector3(0, Rt * 0.3, 0), Vector3(Rt * 1.1, Rt * 0.75, Rt * 1.1), Palette.c(&"leaf_light"), Palette.c(&"leaf_dark"))
	var Rc := rng.randf_range(1.8, 2.3)
	_clump(kit, v, t2 + Vector3(0, Rc * 0.9, 0), Vector3(Rc * 1.1, Rc * 0.75, Rc * 1.1), Palette.c(&"leaf"), Palette.c(&"leaf_dark"))
	v["crown"] = crown


## Understory / mid-storey growth: a young tree, a thin stem with a few
## small leaf clumps between ~1.5 and 5 m (the band under the canopy that
## trunks alone leave open).
func _sapling(kit: MeshKit, v: Dictionary) -> void:
	var rng := _rng
	var H := rng.randf_range(2.6, 4.4)
	var top := Vector3(rng.randf_range(-0.3, 0.3), H, rng.randf_range(-0.3, 0.3))
	_seg(kit, v, Vector3(0, -0.3, 0), top, 0.07, 0.04, 4, Palette.c(&"bark"), 0.2, Perch.Kind.BRANCH, false, false)
	v["mounts"].append([Vector3(0, 1.0, 0), 0.07])
	var crown := 0.0
	var cols := [&"leaf_light", &"leaf", &"leaf_gold"]
	for i in rng.randi_range(2, 3):
		var f := rng.randf_range(0.45, 0.85)
		var from := Vector3(0, -0.3, 0).lerp(top, f)
		var e := from + _dir(rng.randf() * TAU, deg_to_rad(rng.randf_range(15.0, 40.0))) * rng.randf_range(0.6, 1.1)
		_seg(kit, v, from, e, 0.035, 0.025, 3, Palette.c(&"bark"), 0.5, Perch.Kind.BRANCH, true, false)
		var R := rng.randf_range(0.55, 0.85)
		_clump(kit, v, e + Vector3(0, R * 0.2, 0), Vector3(R, R * 0.85, R), Palette.c(cols[i % 3]), Palette.c(&"leaf_dark"))
		crown = maxf(crown, Vector2(e.x, e.z).length() + R)
	var Rt := rng.randf_range(0.65, 0.9)
	_clump(kit, v, top + Vector3(0, Rt * 0.5, 0), Vector3(Rt, Rt, Rt), Palette.c(&"leaf_light"), Palette.c(&"leaf_dark"))
	v["crown"] = maxf(crown, 1.0)
