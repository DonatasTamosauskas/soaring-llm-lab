class_name Habitat
extends RefCounted
## What NPC birds know about the world, cached once and shared by all of them.
##
## World queries are cheap but not free, and 60 birds asking "where are the
## thermals?" every think would multiply them. The habitat reads the World
## contract (get_landmarks, get_refuges, get_perches, get_wind, ground_height,
## bounds) once, refreshes on World.generated, and adds what the birds learn
## while flying: lift they stumbled into becomes a known thermal, the same way
## real soaring birds (and glider pilots) mark lift by watching others circle.
##
## Everything tolerates a missing or still-empty world: the base World is a
## flat windless plain with no perches, and NPCs must still fly sensibly.

const COLLISION_WORLD := 1
## Body radius per wingspan (SizeRules.body_radius_for_mass).
const SEAT_RADIUS_PER_SPAN := 0.16
## Share of the body radius that must be clear of geometry on a perch.
const SEAT_CORE := 0.7

var world: World = null
var bounds_radius := 600.0
var ceiling := 300.0
## [{position: Vector3, radius: float, turn: int, learned: bool}]
var thermals: Array[Dictionary] = []
## [{position, radius, max_span, entry?}]: copies of World.get_refuges()
## (the World's own dictionaries are never written), each linked to the
## opening it is entered through (see _link_openings).
var refuges: Array[Dictionary] = []
## kind -> [landmark dictionaries]
var landmarks := {}

var _ray: PhysicsRayQueryParameters3D
var _enclosed := {}
## The ground_fast() grid: exact samples every GROUND_GRID m, NAN until used.
const GROUND_GRID := 2.0
var _gh := PackedFloat32Array()
var _gh_n := 0
var _gh_org := Vector2.ZERO
## (perch id, radius step) -> the seat is clear (see seat_clear()).
var _seat := {}
var _shape_q: PhysicsShapeQueryParameters3D
var _sphere: SphereShape3D
var _point_q: PhysicsPointQueryParameters3D

static var _cache := {}


## One habitat per world instance, shared by every NPC in it.
static func for_world(w: World) -> Habitat:
	var key := w.get_instance_id() if w else 0
	var h: Habitat = _cache.get(key)
	if h == null or (w != null and not is_instance_valid(h.world)):
		h = Habitat.new(w)
		_cache[key] = h
	return h


static func clear_cache() -> void:
	_cache.clear()


func _init(w: World = null) -> void:
	world = w
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.collision_mask = COLLISION_WORLD
	_ray.collide_with_areas = false
	# Trimesh buildings may be single-sided shells: a bird inside a room must
	# still see the wall it is flying at.
	_ray.hit_back_faces = true
	_sphere = SphereShape3D.new()
	_shape_q = PhysicsShapeQueryParameters3D.new()
	_shape_q.shape = _sphere
	_shape_q.collision_mask = COLLISION_WORLD
	_shape_q.collide_with_areas = false
	_point_q = PhysicsPointQueryParameters3D.new()
	_point_q.collision_mask = COLLISION_WORLD
	_point_q.collide_with_areas = false
	if world:
		if not world.generated.is_connected(refresh):
			world.generated.connect(refresh)
	refresh()


## Re-read everything from the world (after it generates). Also forgets
## what birds learned (thermal circling directions, lift found by chance),
## so a new population in the same world starts from the same state.
## Perches within this of the player's spawn point are the player's.
const SPAWN_PERCH_M := 0.5
var _spawn_known := false
var _spawn_pos := Vector3.INF


func refresh() -> void:
	_spawn_known = false
	_enclosed.clear()
	_seat.clear()
	_gh_n = 0
	_gh = PackedFloat32Array()
	thermals.clear()
	refuges.clear()
	landmarks.clear()
	if world == null or not is_instance_valid(world):
		return
	bounds_radius = world.bounds_radius
	ceiling = world.ceiling
	for lm in world.get_landmarks():
		var kind := String(lm.get("kind", ""))
		if not landmarks.has(kind):
			landmarks[kind] = []
		landmarks[kind].append(lm)
	refresh_thermals()
	if thermals.is_empty():
		# Older worlds only list thermals as landmarks.
		for lm in landmarks_of("thermal"):
			thermals.append({
				"name": lm.get("name", "thermal"), "position": lm.get("position", Vector3.ZERO),
				"radius": float(lm.get("radius", 40.0)), "strength": -1.0, "top": ceiling,
				"lean": Vector3.ZERO, "turn": 0, "learned": false,
			})
	# Copies: _link_openings adds an "entry" to each, and the dictionaries
	# belong to the World (other areas read them).
	for r in world.get_refuges():
		refuges.append(r.duplicate())
	_link_openings()


## Each refuge behind an opening (hedge tunnel, window, barn door, nest-box
## hole) gets an entry: a waypoint outside the opening on its axis, so birds
## line up and fly straight through instead of clipping the frame.
func _link_openings() -> void:
	var ops := landmarks_of("opening")
	for r in refuges:
		var rp: Vector3 = r["position"]
		var best := {}
		# Rooms can be deep: search further for bigger refuges.
		var best_d := float(r.get("radius", 0.5)) * 3.0 + 6.0
		for op in ops:
			var d := rp.distance_to(op.get("position", Vector3.INF))
			if d < best_d and op.has("normal"):
				best_d = d
				best = op
		if best.is_empty():
			r.erase("entry")
			# No opening found for it: cover a bird can dive into from the
			# open, unless it is shut in - a room whose window was not linked
			# has walls and a roof all round (a pigeon steering at one flew
			# into the wall in front of it), and a hiding place inside a solid
			# tree crown has no way in for a body that collides with the crown
			# (pigeons and hawks fleeing to one ground round its crown).
			r["shut"] = roofed_in(rp + Vector3.UP * 0.3) or inside_solid(rp)
			continue
		var op_pos: Vector3 = best["position"]
		var n: Vector3 = (best["normal"] as Vector3).normalized()
		var along := (rp - op_pos).dot(n)
		# The refuge lies behind the opening (a room, box, hollow, the middle
		# of a hedge tunnel): come in from the other side. By the world's
		# contract that is the normal's side; going by where the refuge
		# actually is also copes with an opening whose normal points in.
		var side := -signf(along)
		# A refuge right in the opening's plane (a gap through a hedge) can
		# be entered from either face: the bird picks its own side.
		var two_sided := absf(along) < 0.05
		if two_sided or side == 0.0:
			side = 1.0
		var out := n * side
		r["entry"] = {"through": op_pos, "out": out, "two_sided": two_sided,
			"width": float(best.get("width", 0.5)), "height": float(best.get("height", 0.5))}


## Thermals from World.get_thermals() (live strength, top, lean). Updated in
## place so each column keeps the circling direction its first bird chose.
func refresh_thermals() -> void:
	if world == null or not is_instance_valid(world) or not world.has_method(&"get_thermals"):
		return
	var live: Array = world.get_thermals()
	for t in live:
		var name := String(t.get("name", ""))
		var known: Dictionary = {}
		for k in thermals:
			if not k["learned"] and String(k.get("name", "")) == name:
				known = k
				break
		if known.is_empty():
			known = {"turn": 0, "learned": false}
			thermals.append(known)
		known["name"] = name
		known["position"] = t.get("position", Vector3.ZERO)
		known["radius"] = float(t.get("radius", 40.0))
		known["strength"] = float(t.get("strength", -1.0))
		known["top"] = float(t.get("top", ceiling))
		var lean: Variant = t.get("lean", Vector3.ZERO)
		known["lean"] = Vector3(lean.x, 0.0, lean.y) if lean is Vector2 else (lean as Vector3)


## Centre of a thermal column at height y: columns lean downwind as they rise.
static func thermal_center(t: Dictionary, y: float) -> Vector3:
	var p: Vector3 = t["position"]
	var lean: Vector3 = t.get("lean", Vector3.ZERO)
	var h := maxf(y - p.y, 0.0)
	return Vector3(p.x + lean.x * h, y, p.z + lean.z * h)


func ground(x: float, z: float) -> float:
	return world.ground_height(x, z) if world else 0.0


## Ground height for steering (look-aheads, goals): bilinear on a GROUND_GRID
## grid of exact samples, filled in as birds fly over it. The world's lookup
## is one of the dearer calls 60 birds make at their steering rate; this is
## a few array reads. Within ~0.3 m of ground() on the valley's terrain -
## never used where the body must not dip below the ground (the body's own
## clamp samples ground() exactly).
func ground_fast(x: float, z: float) -> float:
	if world == null:
		return 0.0
	if _gh_n == 0:
		_gh_n = int(ceil(2.0 * bounds_radius / GROUND_GRID)) + 3
		_gh_org = Vector2(-bounds_radius - GROUND_GRID, -bounds_radius - GROUND_GRID)
		_gh.resize(_gh_n * _gh_n)
		_gh.fill(NAN)
	var fx := (x - _gh_org.x) / GROUND_GRID
	var fz := (z - _gh_org.y) / GROUND_GRID
	var i := int(floor(fx))
	var j := int(floor(fz))
	if i < 0 or j < 0 or i >= _gh_n - 1 or j >= _gh_n - 1:
		return ground(x, z)
	var u := fx - i
	var w := fz - j
	return lerpf(lerpf(_gh_at(i, j), _gh_at(i + 1, j), u), lerpf(_gh_at(i, j + 1), _gh_at(i + 1, j + 1), u), w)


func _gh_at(i: int, j: int) -> float:
	var k := j * _gh_n + i
	var h := _gh[k]
	if is_nan(h):
		h = ground(_gh_org.x + i * GROUND_GRID, _gh_org.y + j * GROUND_GRID)
		_gh[k] = h
	return h


## Height of the highest surface at (x, z) below `from_y`: a roof, a tree
## crown, a cliff top - or the ground where there is nothing on it. (Birds
## going somewhere fly over a village or a wood, not down its streets.)
func top(x: float, z: float, from_y: float = INF) -> float:
	var g := ground(x, z)
	var y0 := minf(from_y, ceiling)
	if y0 <= g:
		return g
	var hit := ray(Vector3(x, y0, z), Vector3(x, g - 0.5, z))
	if hit.is_empty():
		return g
	return maxf(g, (hit["position"] as Vector3).y)


func wind(pos: Vector3) -> Vector3:
	return world.get_wind(pos) if world else Vector3.ZERO


func landmarks_of(kind: String) -> Array:
	return landmarks.get(kind, [])


func space() -> PhysicsDirectSpaceState3D:
	if world == null or not world.is_inside_tree():
		return null
	return world.get_world_3d().direct_space_state


## First world-geometry hit on the segment a->b: {position, normal} or {}.
func ray(a: Vector3, b: Vector3) -> Dictionary:
	var s := space()
	if s == null:
		return {}
	_ray.from = a
	_ray.to = b
	return s.intersect_ray(_ray)


## Deepest contact of a sphere (pos, r) with world geometry: {point, normal}
## or {} (used to push a body out of a wall it slid into).
func rest_info(pos: Vector3, r: float) -> Dictionary:
	var s := space()
	if s == null:
		return {}
	_sphere.radius = r
	_shape_q.transform = Transform3D(Basis.IDENTITY, pos)
	return s.get_rest_info(_shape_q)


## True if a sphere of radius r can move from a to b without touching
## world geometry (flare paths into perches and cover).
func sweep_clear(a: Vector3, b: Vector3, r: float) -> bool:
	var s := space()
	if s == null:
		return true
	_sphere.radius = r
	_shape_q.transform = Transform3D(Basis.IDENTITY, a)
	_shape_q.motion = b - a
	var res := s.cast_motion(_shape_q)
	_shape_q.motion = Vector3.ZERO
	# cast_motion returns [1, 1] when nothing is hit; starting in contact
	# returns [0, 0].
	return res.size() < 2 or res[0] >= 0.999


## True if the contact in a rest_info() result is with a solid (convex)
## shape - capsule, box, hull - rather than a trimesh surface, which has no
## inside.
func is_solid(info: Dictionary) -> bool:
	var col := instance_from_id(int(info.get("collider_id", 0))) as CollisionObject3D
	if col == null:
		return false
	var owner := col.shape_find_owner(int(info.get("shape", 0)))
	if owner < 0 or col.shape_owner_get_shape_count(owner) == 0:
		return false
	var shp := col.shape_owner_get_shape(owner, 0)
	return not (shp is ConcavePolygonShape3D or shp is HeightMapShape3D or shp is WorldBoundaryShape3D)


## True if pos lies inside a solid (convex) collider. Point queries on
## trimeshes answer by ray parity, so those are skipped.
func inside_solid(pos: Vector3) -> bool:
	var s := space()
	if s == null:
		return false
	_point_q.position = pos
	for hit in s.intersect_point(_point_q, 4):
		var col := hit["collider"] as CollisionObject3D
		if col == null:
			continue
		var owner := col.shape_find_owner(int(hit["shape"]))
		if owner < 0 or col.shape_owner_get_shape_count(owner) == 0:
			continue
		var shp := col.shape_owner_get_shape(owner, 0)
		if not (shp is ConcavePolygonShape3D or shp is HeightMapShape3D):
			return true
	return false


## True if a sphere of radius r at pos touches world geometry.
func blocked(pos: Vector3, r: float) -> bool:
	var s := space()
	if s == null:
		return false
	_sphere.radius = r
	_shape_q.transform = Transform3D(Basis.IDENTITY, pos)
	return not s.intersect_shape(_shape_q, 1).is_empty()


## Free perches near pos that fit span and are of one of `kinds` (empty =
## any), excluding enclosed and buried ones and those where a body of this
## span would sit touching geometry. Nearest first.
func find_perches(pos: Vector3, radius: float, span: float, kinds: Array = []) -> Array[Perch]:
	var out: Array[Perch] = []
	if world == null:
		return out
	var r := span * SEAT_RADIUS_PER_SPAN
	for p in world.find_perches(pos, radius, span):
		if (kinds.is_empty() or int(p.kind) in kinds) and not is_enclosed(p) and seat_clear(p, r) and not _player_spawn(p):
			out.append(p)
	out.sort_custom(func(a: Perch, b: Perch) -> bool:
		return a.position.distance_squared_to(pos) < b.position.distance_squared_to(pos))
	return out


## The player's spawn perch is the player's (integration round 1): no NPC
## sits there, or a respawn found it taken and left the player hovering
## beside it (GameLoop respawns at World.get_player_spawn(); PlayerBird
## perches only on a free perch).
func _player_spawn(p: Perch) -> bool:
	if not _spawn_known:
		_spawn_known = true
		_spawn_pos = world.get_player_spawn().origin if world != null and is_instance_valid(world) else Vector3.INF
	return _spawn_pos != Vector3.INF and p.position.distance_squared_to(_spawn_pos) < SPAWN_PERCH_M * SPAWN_PERCH_M


## Where the body of a bird of body radius r sits on perch p: its centre
## one body radius above the grip point (the Perch/BirdModel contract: the
## feet are at the bottom of the body).
static func seat(p: Perch, r: float) -> Vector3:
	return p.position + Vector3.UP * r


## True if a body of radius r sitting on p is clear of world geometry, by
## the same measure the A5 safety check uses (centre not inside a solid
## shape; the core of the body - SEAT_CORE of its radius, a little more than
## the check's 60% - not touching a mesh surface such as a hedge or a roof).
## A perch on the top of a hedge whose leafy mesh bulges above the grip
## point would otherwise have a moth sitting a millimetre inside the leaves.
## Cached per perch and 2.5 mm radius step.
func seat_clear(p: Perch, r: float) -> bool:
	var key := p.get_instance_id() * 1024 + mini(int(r * 400.0), 1023)
	if _seat.has(key):
		return _seat[key]
	var c := seat(p, r)
	var ok := not inside_solid(c)
	if ok:
		var s := space()
		if s != null:
			_sphere.radius = r * SEAT_CORE
			_shape_q.transform = Transform3D(Basis.IDENTITY, c)
			for hit in s.intersect_shape(_shape_q, 4):
				var col := hit["collider"] as CollisionObject3D
				if col == null:
					continue
				var owner := col.shape_find_owner(int(hit["shape"]))
				var shp: Shape3D = col.shape_owner_get_shape(owner, 0) if owner >= 0 and col.shape_owner_get_shape_count(owner) > 0 else null
				# The terrain under a perch on the ground is the ground
				# clamp's business, as in the safety check.
				if (shp is ConcavePolygonShape3D or shp is HeightMapShape3D) and c.y - ground(c.x, c.z) <= r * 2.0 + 0.3:
					continue
				ok = false
				break
	_seat[key] = ok
	return ok


## A perch a bird should not pick for a rest, computed once per perch:
##  * enclosed - inside a room, loft or belfry (roof above and walls on most
##    sides): a bird flying in there could not find its way out again;
##  * buried - the seat just above the grip point is inside solid geometry
##    (a branch running through a foliage clump): landing there means
##    flying into the clump.
func is_enclosed(p: Perch) -> bool:
	var id := p.get_instance_id()
	if _enclosed.has(id):
		return _enclosed[id]
	var o := p.position + Vector3.UP * 0.3
	var closed := inside_solid(p.position + Vector3.UP * 0.08) or inside_solid(o) or roofed_in(o)
	_enclosed[id] = closed
	return closed


## True if pos is plainly inside a building: a ceiling within 7 m and walls
## within 12 m on all six sides (a room, a loft, a barn - not a street
## under the eaves, which is open along its length).
func indoors(pos: Vector3) -> bool:
	if ray(pos, pos + Vector3.UP * 7.0).is_empty():
		return false
	for i in 6:
		var a := TAU * i / 6.0
		if ray(pos, pos + Vector3(cos(a), 0.0, sin(a)) * 12.0).is_empty():
			return false
	return true


## True if pos is roofed in: a roof within 12 m above and walls within 12 m
## on at least four of six sides (a perch in a room, a loft, a barn).
func roofed_in(pos: Vector3) -> bool:
	if ray(pos, pos + Vector3.UP * 12.0).is_empty():
		return false
	var walls := 0
	for i in 6:
		var a := TAU * i / 6.0
		if not ray(pos, pos + Vector3(cos(a), 0.0, sin(a)) * 12.0).is_empty():
			walls += 1
	return walls >= 4


## Nearest opening (door, window...) within r whose way out from pos is
## clear: {through, out} or {} (escaping an enclosed space).
func exit_near(pos: Vector3, r: float) -> Dictionary:
	var best := {}
	var best_d := r
	for op in landmarks_of("opening"):
		if not op.has("normal"):
			continue
		var c: Vector3 = op["position"]
		var d := pos.distance_to(c)
		if d >= best_d:
			continue
		var n: Vector3 = (op["normal"] as Vector3).normalized()
		# Out = the side of the opening away from us.
		var out := n if (c - pos).dot(n) > 0.0 else -n
		if not ray(c + out * 0.1, c + out * 3.0).is_empty():
			continue
		var entry := {"through": c, "out": out, "width": float(op.get("width", 0.5)), "height": float(op.get("height", 0.5))}
		if not ray(pos, c - (c - pos).normalized() * 0.1).is_empty():
			# Seen at a grazing angle from inside, the line to a window runs
			# into the wall beside it: go via a point square in front of it.
			var inner := c - out * 1.5
			if not ray(pos, inner).is_empty() or not ray(inner, c - out * 0.1).is_empty():
				continue
			entry["inner"] = inner
		best_d = d
		best = entry
	return best


## Best refuge for a fleeing bird: cover it fits into and the predator
## (wingspan threat_span) does not - "too small for the pursuer": a crow
## fleeing a gull into a barn loft the gull can fly into as well has only
## trapped itself in a room with it - near, not behind the predator, not in
## `taken` (refuge positions to avoid), and in sight: the way to it (to the
## point in front of its opening, or into the cover itself) is open from
## here, not round a building - a flat-out dash round a house for a window
## on its far side grazed every corner on the way. Returns {} if there is
## none within max_dist (the bird then flees in the open). threat_span =
## INF (the default) accepts any cover the bird fits.
func pick_refuge(pos: Vector3, span: float, threat_pos: Vector3, max_dist: float, taken: Array = [], threat_span: float = INF) -> Dictionary:
	var to_threat := threat_pos - pos
	var d_threat := to_threat.length()
	var ranked: Array = []
	for r in refuges:
		var ms := float(r.get("max_span", 0.0))
		# A bird fits where its span is within max_span (the hunter's own rule
		# in NpcBrain._hunt_ok, and GameLoop's CatchRule.in_refuge).
		if span > ms or threat_span <= ms:
			continue
		if not taken.is_empty() and taken.has(r["position"]):
			continue
		if bool(r.get("shut", false)):
			continue
		var rp: Vector3 = r["position"]
		var to_r := rp - pos
		var d := to_r.length()
		if d > max_dist:
			continue
		var cost := d
		# Cover behind an opening that faces away from us (a room whose
		# window is on the far side of the house) means flying round the
		# building at full tilt, grazing its corners: much further than it
		# looks.
		var entry: Dictionary = r.get("entry", {})
		if not entry.is_empty() and not bool(entry.get("two_sided", false)):
			var side := (pos - (entry["through"] as Vector3)).dot(entry["out"] as Vector3)
			if side < 0.0:
				cost += 30.0 - side * 2.0
		# Flying towards the predator to reach cover is suicide unless the
		# cover is much closer than the predator.
		if d > 0.5 and d_threat > 0.5:
			var cos_a := to_r.dot(to_threat) / (d * d_threat)
			if cos_a > 0.5 and d > d_threat * 0.5:
				continue
			cost += maxf(cos_a, 0.0) * d * 1.5
		ranked.append([cost, r])
	ranked.sort_custom(func(a: Array, c: Array) -> bool: return a[0] < c[0])
	for i in mini(ranked.size(), 4):
		var r: Dictionary = ranked[i][1]
		if _in_sight(pos, r):
			return r
	return {}


## True if the way into refuge r is open from pos: the point in front of its
## opening, or (cover without a known opening) the cover itself - the first
## thing a ray to it meets is within a couple of metres of the hiding spot.
func _in_sight(pos: Vector3, r: Dictionary) -> bool:
	var rp: Vector3 = r["position"]
	var entry: Dictionary = r.get("entry", {})
	if not entry.is_empty():
		var door: Vector3 = entry["through"]
		var out: Vector3 = entry["out"]
		if bool(entry.get("two_sided", false)) and (pos - door).dot(out) < 0.0:
			out = -out
		return ray(pos, door + out * 3.0).is_empty()
	var hit := ray(pos, rp)
	return hit.is_empty() or (hit["position"] as Vector3).distance_to(rp) < float(r.get("radius", 0.5)) + 0.5


## Nearest usable thermal within max_dist of pos, or {} (columns that are
## weak right now - live strength under 1 m/s - are not worth the detour).
func nearest_thermal(pos: Vector3, max_dist: float) -> Dictionary:
	var best := {}
	var best_d2 := max_dist * max_dist
	for t in thermals:
		var st := float(t.get("strength", -1.0))
		if st >= 0.0 and st < 1.0:
			continue
		var tp := thermal_center(t, pos.y)
		var d2 := Vector2(tp.x - pos.x, tp.z - pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = t
	return best


## Remember lift a bird found by flying into it (merges with a known one).
func learn_thermal(pos: Vector3, radius: float) -> Dictionary:
	for t in thermals:
		var tp: Vector3 = t["position"]
		if Vector2(tp.x - pos.x, tp.z - pos.z).length() < float(t["radius"]) * 1.5:
			return t
	var t := {"name": "learned", "position": Vector3(pos.x, ground(pos.x, pos.z), pos.z), "radius": radius,
		"strength": -1.0, "top": ceiling, "lean": Vector3.ZERO, "turn": 0, "learned": true}
	thermals.append(t)
	# Learned lift is forgotten eventually; keep the list short.
	var learned := 0
	for i in range(thermals.size() - 1, -1, -1):
		if thermals[i]["learned"]:
			learned += 1
			if learned > 8:
				thermals.remove_at(i)
	return t


## Point inside the playable volume with a margin, clamped.
func clamp_inside(p: Vector3, margin: float) -> Vector3:
	var h := Vector2(p.x, p.z)
	var lim := bounds_radius - margin
	if h.length() > lim:
		h = h.normalized() * lim
	var g := ground_fast(h.x, h.y)
	return Vector3(h.x, clampf(p.y, g + 1.0, ceiling - margin * 0.25), h.y)


## A random point of the given kind of habitat (landmark), or near `fallback`.
func random_spot(kinds: Array, fallback: Vector3, spread: float, rng: RandomNumberGenerator) -> Vector3:
	var pool: Array = []
	for k in kinds:
		pool.append_array(landmarks_of(String(k)))
	if pool.is_empty():
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * spread
		return Vector3(fallback.x + cos(a) * r, 0.0, fallback.z + sin(a) * r)
	var lm: Dictionary = pool[rng.randi() % pool.size()]
	var c: Vector3 = lm.get("position", fallback)
	var rad := float(lm.get("radius", 30.0))
	var a2 := rng.randf() * TAU
	var r2 := sqrt(rng.randf()) * rad
	return Vector3(c.x + cos(a2) * r2, 0.0, c.z + sin(a2) * r2)
