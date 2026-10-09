class_name WorldBuild
extends RefCounted
## Shared state while the world generates: every district builder adds its
## geometry to named MeshKits and registers what it made (perches, openings,
## refuges, landmarks, footprints, features) here, so tests can verify each
## claim against the physics that was actually built.

var seed := 1
var rng := RandomNumberGenerator.new()
var terrain: WorldTerrain
var wind: WindField
var visual_root: Node3D
var body_root: Node3D
var soft_root: Node3D

var kits := {}
var kit_order: Array[String] = []
## Kits drawn with the foliage (sway) material instead of the solid one.
var foliage_kits := {}
var no_shadow_kits := {}
## Distance LOD between kits: lod kit name -> {"full": name, "dist": m}.
var lod_kits := {}
var lod_of := {}
## full kit name -> lod kit name whose mesh casts the full kit's shadows
## (the full kit then casts none).
var shadow_proxy := {}

var perches: Array[Perch] = []
var landmarks: Array[Dictionary] = []
var refuges: Array[Dictionary] = []
## 2D feature points for the density criterion: [Vector3(x, z, radius)].
var features := PackedVector3Array()
var feature_kinds: PackedStringArray = []
## Footprints for the grounding criterion:
## [{name, points: PackedVector2Array, base_y, max_embed}]
var footprints: Array[Dictionary] = []
## Extra per-district timing (ms) for the report.
var timings := {}
## Occupancy (4 m cells over the terrain square): 1 = something solid or a
## no-planting zone is here. Builders block what they build so later
## scatter (trees, rocks, props) never intersects it.
const OCC_CELL := 4.0
const OCC_HALF := 760.0
var occ_n := int(OCC_HALF * 2.0 / OCC_CELL)
var occ := PackedByteArray()


func _init(p_seed: int, p_terrain: WorldTerrain, p_wind: WindField) -> void:
	seed = p_seed
	rng.seed = p_seed * 2654435761 % 2147483647 + 11
	terrain = p_terrain
	wind = p_wind
	occ.resize(occ_n * occ_n)
	occ.fill(0)


func block_circle(x: float, z: float, r: float) -> void:
	var i0 := maxi(0, int((x - r + OCC_HALF) / OCC_CELL))
	var i1 := mini(occ_n - 1, int((x + r + OCC_HALF) / OCC_CELL))
	var j0 := maxi(0, int((z - r + OCC_HALF) / OCC_CELL))
	var j1 := mini(occ_n - 1, int((z + r + OCC_HALF) / OCC_CELL))
	var r2 := (r + OCC_CELL * 0.5) * (r + OCC_CELL * 0.5)
	for j in range(j0, j1 + 1):
		var cz := -OCC_HALF + (j + 0.5) * OCC_CELL
		for i in range(i0, i1 + 1):
			var cx := -OCC_HALF + (i + 0.5) * OCC_CELL
			if (cx - x) * (cx - x) + (cz - z) * (cz - z) <= r2:
				occ[j * occ_n + i] = 1


## Blocks a footprint polygon's bounding circle plus a margin.
func block_points(pts: PackedVector2Array, margin: float) -> void:
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	var r := 0.0
	for p in pts:
		r = maxf(r, p.distance_to(c))
	block_circle(c.x, c.y, r + margin)


func block_segment(a: Vector2, b: Vector2, half_width: float) -> void:
	var l := a.distance_to(b)
	var n := maxi(1, int(ceil(l / (OCC_CELL * 0.75))))
	for k in n + 1:
		var p := a.lerp(b, float(k) / n)
		block_circle(p.x, p.y, half_width)


func is_free(x: float, z: float, r := 0.0) -> bool:
	var steps := [Vector2.ZERO] if r <= 0.0 else [Vector2.ZERO, Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]
	for o in steps:
		var i := int((x + o.x + OCC_HALF) / OCC_CELL)
		var j := int((z + o.y + OCC_HALF) / OCC_CELL)
		if i < 0 or j < 0 or i >= occ_n or j >= occ_n or occ[j * occ_n + i] != 0:
			return false
	return true


## A named merged mesh; everything added to it becomes one draw call.
func kit(kit_name: String, foliage := false, shadows := true) -> MeshKit:
	if not kits.has(kit_name):
		var k := MeshKit.new(kit_name, seed)
		kits[kit_name] = k
		kit_order.append(kit_name)
		if foliage:
			foliage_kits[kit_name] = true
		if not shadows:
			no_shadow_kits[kit_name] = true
	return kits[kit_name]


## A visual-only far stand-in for `full_name`, shown beyond `dist` m (the
## full kit hides there). Its triangles must lie inside the full kit's
## colliders (it borrows them).
func lod_kit(lod_name: String, full_name: String, dist: float, foliage := false) -> MeshKit:
	var k := kit(lod_name, foliage, false)
	k.collide = false
	lod_kits[lod_name] = {"full": full_name, "dist": dist}
	lod_of[full_name] = dist
	return k


## A sub-RNG for one district, so adding content to one district does not
## reshuffle every other district's random details.
func sub_rng(key: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash(key) ^ (seed * 7919)
	return r


func ground(x: float, z: float) -> float:
	return terrain.height_at(x, z)


## Lowest terrain point under a set of XZ points (for foundations).
func ground_min(pts: PackedVector2Array) -> float:
	var m := INF
	for p in pts:
		m = minf(m, terrain.height_at(p.x, p.y))
	return m


## Lowest terrain under the footprint of a blob of `radii` at p (centre and
## eight points round its widest ring).
func ground_under(p: Vector2, rx: float, rz: float) -> float:
	var pts := PackedVector2Array([p])
	for k in 8:
		var a := TAU * float(k) / 8.0
		pts.append(p + Vector2(cos(a) * rx, sin(a) * rz))
	return ground_min(pts)


## Height difference of the terrain under a footprint of radius r at p.
func ground_relief(p: Vector2, r: float) -> float:
	var pts := PackedVector2Array([p])
	for k in 8:
		var a := TAU * float(k) / 8.0
		pts.append(p + Vector2(cos(a), sin(a)) * r)
	return ground_max(pts) - ground_min(pts)


## A blob (bush, boulder, rubble) resting on the terrain. Its flat bottom is
## sunk `sink` below the LOWEST ground under its widest ring, so on a slope
## it still meets the ground all round (no daylight under the downhill
## side). flat must stay above -0.526 * (1 - bumps) so the bottom really is
## flat (icosahedron vertex heights). Returns the bottom's height.
func ground_blob(k: MeshKit, p: Vector2, radii: Vector3, col: Color, bumps: float, col2: Color, flat := -0.3, sink := 0.08) -> float:
	assert(flat > -0.526 * (1.0 - bumps), "blob bottom would not be flat")
	var bottom := ground_under(p, radii.x * 1.05, radii.z * 1.05) - sink
	k.blob(Vector3(p.x, bottom - flat * radii.y, p.y), radii, col, bumps, col2, flat)
	return bottom


func ground_max(pts: PackedVector2Array) -> float:
	var m := -INF
	for p in pts:
		m = maxf(m, terrain.height_at(p.x, p.y))
	return m


func add_perch(pos: Vector3, facing: Vector3, kind: Perch.Kind, max_span: float, district: StringName) -> Perch:
	var f := Vector3(facing.x, 0.0, facing.z)
	f = f.normalized() if f.length() > 1e-4 else Vector3.FORWARD
	var p := Perch.new(pos, f, kind, max_span)
	p.district = district
	perches.append(p)
	return p


func add_landmark(lm_name: String, kind: String, pos: Vector3, radius: float, extra := {}) -> Dictionary:
	var d := {"name": lm_name, "kind": kind, "position": pos, "radius": radius}
	d.merge(extra)
	landmarks.append(d)
	return d


## A flyable hole. position = centre of the opening in its outer plane;
## normal points outward (the side you approach from); depth = clear
## distance behind the plane (room, tunnel, cavity); frame: which sides are
## solid (bitmask 1 left, 2 right, 4 top, 8 bottom) for the "real hole" test.
func add_opening(o_name: String, type: String, pos: Vector3, normal: Vector3, width: float, height: float,
		max_span: float, depth: float, frame := 15, up := Vector3.UP) -> Dictionary:
	return add_landmark(o_name, "opening", pos, maxf(width, height) * 0.5, {
		"type": type, "normal": normal.normalized(), "width": width, "height": height,
		"max_span": max_span, "depth": depth, "frame": frame, "up": up.normalized(),
	})


func add_refuge(r_name: String, pos: Vector3, radius: float, max_span: float) -> void:
	refuges.append({"name": r_name, "position": pos, "radius": radius, "max_span": max_span})


func add_feature(x: float, z: float, radius: float, kind: String) -> void:
	features.append(Vector3(x, z, radius))
	feature_kinds.append(kind)


## reach: how far outside a footprint point the grounding test starts its
## rays (it must start outside the object: trimesh faces are one-sided);
## < 0 lets the test pick by kind. owner: the kit (name) or body (node)
## that holds the object, so only its own geometry counts as grounding it.
func add_footprint(f_name: String, pts: PackedVector2Array, base_y: float, max_embed := 3.0, block_margin := 2.5, reach := -1.0, owner: Variant = "") -> Dictionary:
	var fp := {"name": f_name, "points": pts, "base_y": base_y, "max_embed": max_embed, "reach": reach, "owner": owner}
	footprints.append(fp)
	if block_margin >= 0.0:
		block_points(pts, block_margin)
	return fp


## Footprint corners of an oriented rectangle (centre, half extents, yaw).
static func rect_points(c: Vector2, half: Vector2, yaw: float) -> PackedVector2Array:
	var cs := cos(yaw)
	var sn := sin(yaw)
	var out := PackedVector2Array()
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(0, 0)]:
		var l := Vector2(s.x * half.x, s.y * half.y)
		# Same rotation convention as Basis(Vector3.UP, yaw) acting on (x, z).
		out.append(c + Vector2(l.x * cs + l.y * sn, -l.x * sn + l.y * cs))
	return out


static func span_for_gap(gap: float) -> float:
	## Largest wingspan whose body (radius = span * k) passes a gap with a
	## 20% margin. k comes from SizeRules so retuning the ladder follows.
	return gap / (2.0 * body_k() * 1.2)


static func body_k() -> float:
	var m := 1.0
	return SizeRules.body_radius_for_mass(m) / SizeRules.wingspan_for_mass(m)
