class_name WorldTests
extends RefCounted

## Pins down the shape of the arena.
##
## The defect these exist for: the old world scattered 38 groves at random over
## a 640 m circle and hoped. A bird with no input glides dead straight, and a
## straight line through a random scatter finds holes — the nearest landmark
## reached 316 m and the player spent the rest of the session over an empty
## field. "It looked fine when I flew it" is exactly the evidence that failed.
##
## So the arena is measured instead: sampled on a grid, ray-marched in every
## direction, and its wall checked for gaps at every bearing. All of it runs
## against a real, fully built [WorldBuilder] — same seed, same geometry, same
## perch points the AI navigates by.

## The threshold [HandsRepro] fails a flight at: beyond this there is nothing
## worth looking at. The arena must never contain a point this bare.
const MAX_LANDMARK: float = 260.0
## What the layout is actually designed for. The grid guarantees roughly the
## half-diagonal of a cell plus the jitter; this is that number with headroom.
const TARGET_LANDMARK: float = 200.0

## Budget guards. The world is allowed to be dense, but not at the cost of the
## frame: these are the counts the 72 Hz target was measured against.
const MAX_BODIES: int = 950
const MAX_SHAPES: int = 9500
const MAX_VERTICES: int = 800000
## Total surfaces across every structure: the world's draw-call ceiling before
## any frustum or range culling.
const MAX_SURFACES: int = 750


static func run(t: TestCase) -> void:
	var world := WorldBuilder.new()
	world.build()

	_test_the_arena_is_never_empty(t, world)
	_test_a_straight_glide_never_runs_out_of_world(t, world)
	_test_the_rim_wall_has_no_gaps(t, world)
	_test_past_the_rim_the_ground_only_climbs(t, world)
	_test_the_gorge_is_a_gorge(t, world)
	_test_the_town_bowl_is_flat(t, world)
	_test_the_ground_has_no_holes_in_it(t, world)
	_test_lift_is_reachable_and_visible(t, world)
	_test_the_world_fits_its_budget(t, world)

	_test_the_world_is_reproducible(t)
	_test_coverage_holds_at_any_seed(t)

	world.free()


# --- coverage ----------------------------------------------------------------

## Every point a player can fly to has something to look at.
static func _test_the_arena_is_never_empty(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the arena is never empty")
	var index := _PerchIndex.new(world.perch_points)
	t.greater(float(world.perch_points.size()), 2000.0, "the world publishes perch points")

	var worst: float = 0.0
	var worst_at := Vector2.ZERO
	var total: float = 0.0
	var samples: int = 0
	var step: float = 25.0
	var reach: float = WorldBuilder.ARENA_RADIUS
	var x: float = -reach
	while x <= reach:
		var z: float = -reach
		while z <= reach:
			if Vector2(x, z).length() <= reach:
				var here := Vector3(x, world.height_at(x, z) + 60.0, z)
				var distance: float = index.nearest(here)
				total += distance
				samples += 1
				if distance > worst:
					worst = distance
					worst_at = Vector2(x, z)
			z += step
		x += step

	t.greater(float(samples), 1000.0, "the sweep actually covered the arena")
	t.less(
		worst, MAX_LANDMARK,
		"nowhere in the arena is barren (worst %.0f m at %.0f,%.0f)" % [
			worst, worst_at.x, worst_at.y
		]
	)
	t.less(worst, TARGET_LANDMARK, "the grid keeps its designed spacing")
	t.less(total / maxf(float(samples), 1.0), 90.0, "typical scenery is close, not just present")


## The failure mode that started this: no input, so no bank, so a dead-straight
## line out of the middle. Walk every bearing and check the whole line.
static func _test_a_straight_glide_never_runs_out_of_world(
	t: TestCase, world: WorldBuilder
) -> void:
	t.begin("a straight glide never runs out of world")
	var index := _PerchIndex.new(world.perch_points)
	var worst: float = 0.0
	var worst_bearing: float = 0.0
	for b in 96:
		var bearing: float = TAU * float(b) / 96.0
		var direction := Vector2(cos(bearing), sin(bearing))
		var travelled: float = 0.0
		while travelled <= WorldBuilder.ARENA_RADIUS:
			var at: Vector2 = direction * travelled
			var here := Vector3(at.x, world.height_at(at.x, at.y) + 60.0, at.y)
			var distance: float = index.nearest(here)
			if distance > worst:
				worst = distance
				worst_bearing = bearing
			travelled += 20.0

	t.less(
		worst, MAX_LANDMARK,
		"every bearing stays populated (worst %.0f m on bearing %.0f deg)" % [
			worst, rad_to_deg(worst_bearing)
		]
	)
	t.less(worst, TARGET_LANDMARK, "and with the designed margin")


## The point of placing structures on a jittered grid rather than scattering
## them is that coverage stops depending on the seed. A scatter that happens to
## be fine today opens a 300 m hole the first time someone changes a number, and
## nothing would tell them. So: build other worlds and walk them too.
static func _test_coverage_holds_at_any_seed(t: TestCase) -> void:
	t.begin("coverage holds at any seed")
	for seed_value: int in [7, 991, 20260101]:
		var world := WorldBuilder.new()
		world.world_seed = seed_value
		world.build()
		var index := _PerchIndex.new(world.perch_points)
		var worst: float = 0.0
		for b in 64:
			var bearing: float = TAU * float(b) / 64.0
			var direction := Vector2(cos(bearing), sin(bearing))
			var travelled: float = 0.0
			while travelled <= WorldBuilder.ARENA_RADIUS:
				var at: Vector2 = direction * travelled
				var here := Vector3(at.x, world.height_at(at.x, at.y) + 60.0, at.y)
				worst = maxf(worst, index.nearest(here))
				travelled += 25.0
		t.less(worst, MAX_LANDMARK, "seed %d stays populated everywhere" % seed_value)
		t.less(worst, TARGET_LANDMARK, "seed %d keeps the designed margin" % seed_value)
		world.free()


# --- the wall ----------------------------------------------------------------

## The arena closes itself with terrain. Not with a rule, not with a nudge — the
## ground rises and keeps rising. If a single bearing had a low saddle it would
## be a door, and a bird flying a straight line finds every door there is.
static func _test_the_rim_wall_has_no_gaps(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the rim wall has no gaps")
	var lowest_crest: float = INF
	var lowest_bearing: float = 0.0
	for b in 720:
		var bearing: float = TAU * float(b) / 720.0
		var direction := Vector2(cos(bearing), sin(bearing))
		# Highest ground anywhere in the rim band on this bearing: the wall only
		# has to be crossed once, so its lowest point is what matters.
		var crest: float = -INF
		var radius: float = WorldBuilder.RIM_INNER
		while radius <= WorldBuilder.RIM_CREST + 60.0:
			var at: Vector2 = direction * radius
			crest = maxf(crest, world.height_at(at.x, at.y))
			radius += 10.0
		if crest < lowest_crest:
			lowest_crest = crest
			lowest_bearing = bearing

	# The bowl floor is at about zero and the player spawns 95 m above it, so a
	# wall this high is several hundred metres of climbing from anywhere inside.
	t.greater(
		lowest_crest, 230.0,
		"the lowest point of the wall is still a wall (%.0f m on bearing %.0f deg)" % [
			lowest_crest, rad_to_deg(lowest_bearing)
		]
	)
	# And it is a wall on every side, not a horseshoe.
	t.greater(lowest_crest, 230.0, "on all 720 bearings")


## Climbing over the rim must never be worth it. Sample outward: the ground past
## the crest is higher than the crest, everywhere.
static func _test_past_the_rim_the_ground_only_climbs(
	t: TestCase, world: WorldBuilder
) -> void:
	t.begin("past the rim the ground only climbs")
	var worst_drop: float = -INF
	for b in 180:
		var bearing: float = TAU * float(b) / 180.0
		var direction := Vector2(cos(bearing), sin(bearing))
		var crest: Vector2 = direction * WorldBuilder.RIM_CREST
		var crest_height: float = world.height_at(crest.x, crest.y)
		var far: Vector2 = direction * WorldBuilder.MASSIF_RADIUS
		var far_height: float = world.height_at(far.x, far.y)
		worst_drop = maxf(worst_drop, crest_height - far_height)

	t.less(worst_drop, 0.0, "the massif beyond the crest is always higher")


static func _test_the_gorge_is_a_gorge(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the gorge is a gorge")
	# Measured against the opposite quadrant rather than against zero: rolling
	# terrain alone already puts 60 m between a hollow and the hill beside it, so
	# an absolute threshold would pass on a world with no gorge in it at all.
	var deepest: float = 0.0
	var control_deepest: float = 0.0
	var beats_control: int = 0
	for i in 9:
		var radius: float = lerpf(320.0, 560.0, float(i) / 8.0)
		var here: float = _deepest_trench(world, WorldBuilder.GORGE_ANGLE, radius)
		var control: float = _deepest_trench(world, WorldBuilder.GORGE_ANGLE + PI, radius)
		if here > control + 25.0:
			beats_control += 1
		deepest = maxf(deepest, here)
		control_deepest = maxf(control_deepest, control)

	t.greater(
		float(beats_control), 6.0,
		"the trench runs most of the way out (%d of 9 sections)" % beats_control
	)
	t.greater(
		deepest - control_deepest, 45.0,
		"and it is a cut, not just a valley (%.0f m against %.0f m of ordinary relief)" % [
			deepest, control_deepest
		]
	)
	t.greater(deepest, 100.0, "deep enough to fly down inside")


## Biggest drop from a shoulder to the floor found in a fan around [param
## bearing] at [param radius]. The trench wanders, so this sweeps rather than
## assuming it runs radially.
static func _deepest_trench(world: WorldBuilder, bearing: float, radius: float) -> float:
	var best: float = 0.0
	for j in 41:
		var angle: float = bearing + lerpf(-0.45, 0.45, float(j) / 40.0)
		var at := Vector2(cos(angle) * radius, sin(angle) * radius)
		var across := Vector2(-sin(angle), cos(angle))
		var floor_height: float = world.height_at(at.x, at.y)
		var left: Vector2 = at + across * 190.0
		var right: Vector2 = at - across * 190.0
		var shoulder: float = maxf(
			world.height_at(left.x, left.y), world.height_at(right.x, right.y)
		)
		best = maxf(best, shoulder - floor_height)
	return best


static func _test_the_town_bowl_is_flat(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the town bowl is flat")
	# The player spawns at the origin at a fixed altitude, so the middle has to
	# stay level or the first three seconds are a hillside.
	var low: float = INF
	var high: float = -INF
	for b in 32:
		var bearing: float = TAU * float(b) / 32.0
		for r: float in [0.0, 20.0, 40.0, 60.0]:
			var h: float = world.height_at(cos(bearing) * r, sin(bearing) * r)
			low = minf(low, h)
			high = maxf(high, h)
	t.less(high - low, 6.0, "the spawn bowl is level")
	t.near(world.height_at(0.0, 0.0), 0.0, 2.0, "and sits at datum")


# --- lift --------------------------------------------------------------------

## Soaring has to be learnable, which means the lift has to be findable without
## instruments: a bleached patch of ground under it, a flat-bottomed cloud over
## it. This walks the world with nothing but the public API, finds the strongest
## column of rising air, and checks that both tells are actually there.
static func _test_lift_is_reachable_and_visible(t: TestCase, world: WorldBuilder) -> void:
	t.begin("lift is reachable and visible")
	var cores: Array[Vector3] = _find_lift_cores(world)
	t.greater(float(cores.size()), 12.0, "there are plenty of thermals to find")

	var strongest := Vector3.ZERO
	var best: float = 0.0
	for core: Vector3 in cores:
		var lift: float = world.wind_at(core).y
		if lift > best:
			best = lift
			strongest = core
	t.greater(best, 3.0, "the strongest core lifts a bird meaningfully")

	# Never more than a glide away from the next one. At the trim glide ratio of
	# about 8, 260 m of separation costs 33 m of height — affordable from a
	# thermal top, which is what makes crossing the bowl on lift alone possible.
	var worst_gap: float = 0.0
	for a: Vector3 in cores:
		var nearest: float = INF
		for b: Vector3 in cores:
			if a.is_equal_approx(b):
				continue
			nearest = minf(nearest, Vector2(a.x - b.x, a.z - b.z).length())
		worst_gap = maxf(worst_gap, nearest)
	t.less(worst_gap, 300.0, "thermals chain: the next one is always within a glide")

	# The ground tell: bare, sun-baked earth under the core.
	var terrain: MeshInstance3D = _find_terrain(world)
	t.ok(terrain != null, "the terrain mesh exists")
	if terrain != null:
		var under: Color = _average_ground_colour(terrain, Vector2(strongest.x, strongest.z), 40.0)
		var around: Color = _average_ground_colour(
			terrain, Vector2(strongest.x, strongest.z) + Vector2(230.0, 0.0), 60.0
		)
		t.greater(
			under.r - around.r, 0.04,
			"the ground under a thermal is visibly bleached (%.3f vs %.3f)" % [
				under.r, around.r
			]
		)

	# The sky tell: a cloud, above the core, near the top of the lift.
	var ceiling: float = _lift_ceiling(world, strongest)
	t.greater(ceiling, 120.0, "the core carries a bird a long way up")
	var puffs: int = _cloud_vertices_over(world, Vector2(strongest.x, strongest.z), 70.0, ceiling)
	t.greater(float(puffs), 20.0, "a cloud caps the strongest thermal")
	# And along the rim, where the ridge lift is. Counted over the whole ring
	# rather than at one bearing: the banks are deliberately broken up, so
	# sampling a fixed spot tests the seed, not the feature.
	var banks: int = _cloud_vertices_in_ring(
		world, WorldBuilder.RIM_INNER - 40.0, WorldBuilder.RIM_CREST
	)
	t.greater(float(banks), 200.0, "cloud hangs along the rim where the ridge lift is")


# --- determinism and budget --------------------------------------------------

static func _test_the_world_is_reproducible(t: TestCase) -> void:
	t.begin("the world is reproducible")
	var a := WorldBuilder.new()
	a.build()
	var b := WorldBuilder.new()
	b.build()
	t.ok(a.perch_points.size() == b.perch_points.size(), "same seed, same perch count")
	var identical: bool = true
	for i in range(0, a.perch_points.size(), 37):
		if not a.perch_points[i].is_equal_approx(b.perch_points[i]):
			identical = false
			break
	t.ok(identical, "same seed, same perches in the same places")

	var c := WorldBuilder.new()
	c.world_seed = 424242
	c.build()
	var moved: bool = c.perch_points.size() != a.perch_points.size()
	if not moved:
		for i in range(0, a.perch_points.size(), 37):
			if not c.perch_points[i].is_equal_approx(a.perch_points[i]):
				moved = true
				break
	t.ok(moved, "a different seed builds a different world")
	t.ok(
		absf(c.height_at(320.0, -180.0) - a.height_at(320.0, -180.0)) > 0.5,
		"and different ground under it"
	)

	a.free()
	b.free()
	c.free()


## Density is only worth having if it still runs. These are the counts the frame
## budget was measured against; blowing past them is how a beautiful world ships
## at 45 fps.
static func _test_the_world_fits_its_budget(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the world fits its budget")
	var bodies: int = 0
	var shapes: int = 0
	var meshes: int = 0
	var surfaces: int = 0
	var vertices: int = 0
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is StaticBody3D:
			bodies += 1
		if node is CollisionShape3D:
			shapes += 1
		if node is MeshInstance3D:
			meshes += 1
			var mesh: Mesh = (node as MeshInstance3D).mesh
			if mesh != null:
				surfaces += mesh.get_surface_count()
				for s in mesh.get_surface_count():
					vertices += mesh.surface_get_array_len(s)
		for child: Node in node.get_children():
			stack.append(child)

	t.less(float(bodies), float(MAX_BODIES), "structure count stays in budget")
	t.less(float(shapes), float(MAX_SHAPES), "collision shape count stays in budget")
	t.less(float(vertices), float(MAX_VERTICES), "vertex count stays in budget")
	# Surfaces, not instances, are what the GPU counts. This is the ceiling on
	# the world's draw calls with nothing culled, and it is the number that
	# decides whether a headset holds 72 Hz.
	t.less(float(surfaces), float(MAX_SURFACES), "the draw-call ceiling stays in budget")
	# One mesh instance per structure is the batching rule (see GeometryBatch).
	# More instances than bodies means something started drawing per primitive.
	t.less(float(meshes), float(bodies) + 16.0, "geometry is still batched per structure")


# --- helpers -----------------------------------------------------------------

## Coarse sweep for local maxima of vertical wind, at a height where thermals
## dominate and ridge lift does not. Uses only [method WorldBuilder.wind_at], so
## it tests what a bird actually feels rather than the data behind it.
static func _find_lift_cores(world: WorldBuilder) -> Array[Vector3]:
	var cores: Array[Vector3] = []
	var step: float = 20.0
	var reach: float = WorldBuilder.ARENA_RADIUS
	var x: float = -reach
	while x <= reach:
		var z: float = -reach
		while z <= reach:
			var here := Vector3(x, world.height_at(x, z) + 90.0, z)
			var lift: float = world.wind_at(here).y
			if lift > 2.0:
				var merged: bool = false
				for i in cores.size():
					if Vector2(cores[i].x - x, cores[i].z - z).length() < 90.0:
						merged = true
						if world.wind_at(here).y > world.wind_at(cores[i]).y:
							cores[i] = here
						break
				if not merged:
					cores.append(here)
			z += step
		x += step
	return cores


## How high the lift at [param core] can carry a bird: the highest altitude that
## still has rising air over that spot.
static func _lift_ceiling(world: WorldBuilder, core: Vector3) -> float:
	var ground: float = world.height_at(core.x, core.z)
	var top: float = ground
	var y: float = ground
	while y < ground + 600.0:
		if world.wind_at(Vector3(core.x, y, core.z)).y > 0.2:
			top = y
		y += 10.0
	return top - ground


## The ground is drawn on rings whose spoke count halves as they come inward, so
## rings of different resolutions have to be stitched rather than simply
## quadded. Get that wrong and the world has slots in it that a bird falls
## through and a collider cannot catch — a defect that would be invisible from
## almost every camera angle and fatal from one.
##
## The test is the definition: count how many triangles use each edge. Every
## edge should be shared by exactly two, except the outermost ring, which is
## where the disc ends and there are exactly [constant
## WorldBuilder.TERRAIN_SPOKES] of them.
static func _test_the_ground_has_no_holes_in_it(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the ground has no holes in it")
	var terrain: MeshInstance3D = _find_terrain(world)
	t.ok(terrain != null, "there is a terrain mesh")
	if terrain == null:
		return
	var points: PackedVector3Array = terrain.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var triangles: int = points.size() / 3
	t.greater(float(triangles), 20000.0, "and it is made of triangles")

	var edges: Dictionary = {}
	for triangle in triangles:
		for e in 3:
			var a: Vector3 = points[triangle * 3 + e]
			var b: Vector3 = points[triangle * 3 + (e + 1) % 3]
			# Keyed on the ground plane and ordered, so the same edge walked from
			# either of its two triangles produces the same key.
			var key: String = (
				"%.2f,%.2f|%.2f,%.2f" % [a.x, a.z, b.x, b.z]
				if a.x < b.x or (a.x == b.x and a.z < b.z)
				else "%.2f,%.2f|%.2f,%.2f" % [b.x, b.z, a.x, a.z]
			)
			edges[key] = int(edges.get(key, 0)) + 1

	var open_edges: int = 0
	var over_shared: int = 0
	for key: String in edges:
		var shared: int = edges[key]
		if shared == 1:
			open_edges += 1
		elif shared > 2:
			over_shared += 1
	t.ok(
		over_shared == 0,
		"no edge is shared by more than two triangles (%d are)" % over_shared
	)
	t.ok(
		open_edges == WorldBuilder.TERRAIN_SPOKES,
		"the only open edges are the rim of the disc (%d, expected %d)" % [
			open_edges, WorldBuilder.TERRAIN_SPOKES
		]
	)


static func _find_terrain(world: WorldBuilder) -> MeshInstance3D:
	var terrain: Node = world.get_node_or_null("Terrain")
	if terrain == null:
		return null
	for child: Node in terrain.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
	return null


static func _average_ground_colour(
	terrain: MeshInstance3D, at: Vector2, radius: float
) -> Color:
	var arrays: Array = terrain.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var total := Color(0.0, 0.0, 0.0, 0.0)
	var count: int = 0
	for i in points.size():
		var p: Vector3 = points[i]
		if Vector2(p.x - at.x, p.z - at.y).length() > radius:
			continue
		total += colours[i]
		count += 1
	if count == 0:
		return Color.BLACK
	return total / float(count)


## Counts cloud vertices standing over [param at], above [param above]. Cloud is
## batched into sector nodes named Cloud0..7 with no colliders, so this is how
## you ask "is there weather over this spot" without an API that exists only for
## the test to call.
static func _cloud_vertices_over(
	world: WorldBuilder, at: Vector2, radius: float, above: float
) -> int:
	var count: int = 0
	for child: Node in world.get_children():
		if not child.name.begins_with("Cloud"):
			continue
		for grandchild: Node in child.get_children():
			if not (grandchild is MeshInstance3D):
				continue
			var mesh: Mesh = (grandchild as MeshInstance3D).mesh
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				var points: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
				for p: Vector3 in points:
					if p.y < above:
						continue
					if Vector2(p.x - at.x, p.z - at.y).length() <= radius:
						count += 1
	return count


## Counts cloud vertices standing over the annulus between [param inner] and
## [param outer].
static func _cloud_vertices_in_ring(
	world: WorldBuilder, inner: float, outer: float
) -> int:
	var count: int = 0
	for child: Node in world.get_children():
		if not child.name.begins_with("Cloud"):
			continue
		for grandchild: Node in child.get_children():
			if not (grandchild is MeshInstance3D):
				continue
			var mesh: Mesh = (grandchild as MeshInstance3D).mesh
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				var points: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
				for p: Vector3 in points:
					var radius: float = Vector2(p.x, p.z).length()
					if radius >= inner and radius <= outer:
						count += 1
	return count


## Grid hash over the world's perch points. A linear scan of several thousand
## points for each of tens of thousands of samples is a minute of test time;
## bucketing it is a fraction of a second.
class _PerchIndex extends RefCounted:
	const CELL: float = 120.0

	var _points: Array[Vector3]
	var _cells: Dictionary = {}

	func _init(points: Array[Vector3]) -> void:
		_points = points
		for i in points.size():
			var key: Vector2i = _key(points[i].x, points[i].z)
			if not _cells.has(key):
				_cells[key] = PackedInt32Array()
			var bucket: PackedInt32Array = _cells[key]
			bucket.append(i)
			_cells[key] = bucket

	func _key(x: float, z: float) -> Vector2i:
		return Vector2i(int(floor(x / CELL)), int(floor(z / CELL)))

	## Distance to the nearest perch point, or INF if the world has none.
	func nearest(from: Vector3) -> float:
		var centre: Vector2i = _key(from.x, from.z)
		var best: float = INF
		var ring: int = 0
		while ring < 12:
			for dx in range(-ring, ring + 1):
				for dz in range(-ring, ring + 1):
					# Only the newly added shell each time round.
					if ring > 0 and absi(dx) != ring and absi(dz) != ring:
						continue
					var bucket: PackedInt32Array = _cells.get(
						centre + Vector2i(dx, dz), PackedInt32Array()
					)
					for i: int in bucket:
						best = minf(best, from.distance_to(_points[i]))
			# One extra ring past the first hit, since a nearer point can sit
			# just over a cell boundary.
			if best < INF and float(ring) * CELL > best:
				break
			ring += 1
		return best
