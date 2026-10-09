class_name WorldBuilder
extends Node3D

## Procedurally builds the flying grounds: a bowl of terrain ringed by a wall of
## snow-capped mountains, four districts you can navigate by, and the thermals
## and ridge lift that hold a bird up.
##
## Everything is generated from a seed so the world is reproducible — which
## matters because flight tuning is only meaningful if the obstacle course stays
## the same between runs.
##
## Four rules shape all of it:
## [br]1. Geometry is batched per structure (see [GeometryBatch]) so a dense
##    forest stays affordable at 90 Hz per eye.
## [br]2. Anything a bird would plausibly land on gets a collider and a perch
##    point. Anything a bird would brush through — foliage, glass, cloud — does
##    not.
## [br]3. The world does not run out. Structures are placed on a jittered grid
##    (see [method _build_plots]) rather than scattered at random, so no point
##    inside the arena is ever far from something worth looking at. Random
##    scatter left holes hundreds of metres across; a bird that glided into one
##    was left staring at an empty field, which is the defect this replaces.
## [br]4. The arena is closed by terrain, not by a rule. The rim is a real
##    mountain wall you can ridge-soar along, and beyond it the ground only ever
##    climbs. Nothing turns the player around; there is simply nowhere to go.

# --- arena shape -------------------------------------------------------------

## The populated interior — everything the player is expected to fly in.
const ARENA_RADIUS: float = 620.0
## Where the ground starts climbing into the rim wall.
const RIM_INNER: float = 700.0
## Where the rim tops out. Between here and [constant ARENA_RADIUS] is alpine
## country: thin, high, and the best ridge lift in the world.
const RIM_CREST: float = 880.0
## Height of the rim above the bowl floor, before angular variation.
const RIM_HEIGHT: float = 340.0
## Beyond the crest the massif keeps rising to here, so climbing over the rim
## only buys you a view of more mountain.
const MASSIF_RADIUS: float = 1150.0
const MASSIF_HEIGHT: float = 150.0

## How far out the ground is built. A disc, not a square: the terrain is drawn
## on rings and spokes (see [method _build_terrain]), so this is a radius. It
## reaches further on every bearing than the square grid it replaced did on its
## axes, and the skyline past the massif is what fills the far distance.
const TERRAIN_RADIUS: float = 1650.0
## Spokes around the outside of the disc. At the rim wall this puts 16 m between
## neighbours, which is the resolution the square grid had everywhere.
const TERRAIN_SPOKES: int = 320
## Closest two neighbours on a ring are allowed to get before the ring inside
## them drops to half as many spokes. Without this the triangles under the town
## are 15 m long and 30 cm wide and the bowl reads as a pinwheel from above.
const MIN_TANGENT_STEP: float = 8.0
## Fewest spokes any ring may have, so the very middle stays a disc rather than
## a triangle.
const MIN_SPOKES: int = 8
## Radial resolution, band by band: [to this radius, metres per ring]. The wall
## between [constant RIM_INNER] and the crest gets 6 m rings because that is the
## only direction in which it climbs; the bowl keeps the 15 m the old world had;
## the massif beyond the crest is skyline and can be coarse.
const RING_STEPS: Array[Vector2] = [
	Vector2(620.0, 15.0),
	Vector2(950.0, 6.0),
	Vector2(1200.0, 12.0),
	Vector2(1650.0, 26.0),
]
const HILL_HEIGHT: float = 90.0

## The town sits in a deliberately flattened bowl in the middle.
const TOWN_RADIUS: float = 250.0

# --- content density ---------------------------------------------------------

## Side of the coverage grid. Every cell gets a structure, so the worst-case
## distance from anywhere to the nearest landmark is bounded by the cell
## diagonal plus the jitter — about 160 m — instead of by luck.
const PLOT_SIZE: float = 150.0
const PLOT_JITTER: float = 40.0

const BUILDING_COUNT: int = 26
const POWERLINE_RUNS: int = 11
const ARCH_COUNT: int = 12

## Standalone headsets get a tighter draw distance and cheaper shadows. Both are
## invisible behind the aerial haze, and both are the difference between 45 and
## 90 frames per second on a Quest.
static var MOBILE: bool = OS.has_feature("mobile") or OS.has_feature("android")

## How far each kind of structure stays drawn. Things you navigate by — spires,
## towers, arches, cloud — persist far longer than the trees and wires that only
## matter once you are close enough to hit them.
const RANGE_TREE: float = 620.0
const RANGE_BUILDING: float = 900.0
const RANGE_ARCH: float = 1100.0
const RANGE_POLE: float = 320.0
const RANGE_WIRE: float = 220.0
const RANGE_STONE: float = 520.0
const RANGE_RUIN: float = 700.0
const RANGE_SPIRE: float = 1400.0
const RANGE_TOWER: float = 1800.0
## Cloud is the navigation aid for soaring. It has to be visible from anywhere
## in the bowl or it teaches nothing.
const RANGE_CLOUD: float = 2600.0
## Headsets cull closer in. Not as close as the frame budget alone would
## suggest — without a fade, anything too tight pops visibly as you fly at it.
const MOBILE_RANGE_SCALE: float = 0.75

## Districts. Four quadrants of open country around a central town, each with
## its own silhouette, so "I am east of the town, over the spires" is a thing a
## player can know at a glance from 400 m up.
enum Region { TOWN, GREENWOOD, SPIRES, GORGE, DOWNS, RIM, BEYOND }

## The gorge runs out along −X, which is the middle of the [constant
## Region.GORGE] quadrant.
const GORGE_ANGLE: float = PI
const GORGE_FLOOR: float = 62.0   # half-width of the flat bottom
const GORGE_RIM: float = 136.0    # half-width at the top of the walls
const GORGE_DEPTH: float = 78.0

@export var world_seed: int = 20260812

## Which hour of the day to light the world at. The land is the same at every
## hour — only the light, the sky and the air change — so this is purely an art
## setting, and [method build] takes it from [code]--sky=[/code] unless something
## has already set it. See [Palette].
var hour: Palette.Hour = Palette.Hour.MORNING

var rng := RandomNumberGenerator.new()
var terrain_noise := FastNoiseLite.new()
var ridge_noise := FastNoiseLite.new()
var rim_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()
var peak_noise := FastNoiseLite.new()

## Thermals as plain data, sampled per frame rather than modelled as Area3Ds —
## cheaper, and it lets the AI birds ride exactly the same lift the player does.
var _thermals: Array[Dictionary] = []

## Centre line of the gorge, as a polyline in XZ, plus its bounding box so
## [method height_at] can reject the 90 % of the world that is nowhere near it
## without doing any segment maths.
var _gorge_path: PackedVector2Array = PackedVector2Array()
var _gorge_bounds := Rect2()

## Where the town's buildings ended up, so the coverage grid can plant a park in
## a gap instead of a tree through someone's roof.
var _building_spots: PackedVector2Array = PackedVector2Array()

var _materials: Dictionary = {}
var _built: bool = false
## Where the builder itself sits, captured once. Everything published in world
## space goes through it. Reading [member Node3D.global_transform] per perch
## instead would tie the whole build to being inside a running scene tree, and
## the world tests build the world from a `SceneTree._initialize()`, where it is
## not — which silently produced thousands of perch points at the origin.
var _origin: Transform3D = Transform3D.IDENTITY

## Places a bird can plausibly perch, published for the AI to aim at.
var perch_points: Array[Vector3] = []


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	_origin = global_transform if is_inside_tree() else transform
	hour = Palette.hour_from_args(hour)
	rng.seed = world_seed
	_setup_noise()
	_plan_gorge()
	_make_materials()
	_build_environment()
	# Thermals first: the ground under them is bleached, and the terrain mesh
	# has to know that before it paints itself.
	_build_thermals()
	_build_terrain()
	# The town before the grid, so park groves can dodge the buildings.
	_build_town()
	_build_plots()
	_build_landmarks()
	_build_powerlines()
	_build_arches()
	_build_clouds()
	print("[Soaring] world built: %d perches, %d thermals" % [
		perch_points.size(), _thermals.size()
	])


func _setup_noise() -> void:
	terrain_noise.seed = world_seed
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.frequency = 0.0011
	terrain_noise.fractal_octaves = 4

	# A second, ridged layer gives the hills spines and gullies to fly along
	# instead of the featureless dunes plain fractal noise produces.
	ridge_noise.seed = world_seed + 7717
	ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge_noise.frequency = 0.0034
	ridge_noise.fractal_octaves = 3

	# Varies the height of the rim wall around the ring. At this frequency the
	# crest gets a peak roughly every 250 m of circumference, which is what
	# turns a cone into a mountain range.
	rim_noise.seed = world_seed + 331
	rim_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	rim_noise.frequency = 0.0040
	rim_noise.fractal_octaves = 2

	# Hillocks. Without a mid-frequency layer the bowl is two broad swells and
	# 900 m of nothing: nothing to ridge-soar, nothing to read speed against, and
	# nothing for a shadow to fall across. This is the scale a bird notices.
	detail_noise.seed = world_seed + 1201
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.frequency = 0.0074
	detail_noise.fractal_octaves = 2

	peak_noise.seed = world_seed + 9091
	peak_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	peak_noise.frequency = 0.0021
	peak_noise.fractal_octaves = 3


## Which district a point is in. Used to decide what to build where, and it is
## what makes the four quadrants legible from the air.
func region_at(x: float, z: float) -> Region:
	var radius: float = Vector2(x, z).length()
	if radius < TOWN_RADIUS:
		return Region.TOWN
	if radius > RIM_CREST:
		return Region.BEYOND
	if radius > ARENA_RADIUS:
		return Region.RIM
	var angle: float = atan2(z, x)
	if angle >= -PI * 0.25 and angle < PI * 0.25:
		return Region.GREENWOOD
	if angle >= PI * 0.25 and angle < PI * 0.75:
		return Region.DOWNS
	if angle >= -PI * 0.75 and angle < -PI * 0.25:
		return Region.SPIRES
	return Region.GORGE


# --- terrain height ----------------------------------------------------------

## Ground height at a world position. Used for terrain, for placing everything
## on it, and by the AI to avoid flying into hillsides. Single source of truth:
## if it is not in here, it is not the shape of the ground.
func height_at(x: float, z: float) -> float:
	var radius: float = Vector2(x, z).length()
	var base: float = terrain_noise.get_noise_2d(x, z)
	var ridge: float = 1.0 - absf(ridge_noise.get_noise_2d(x, z))
	var detail: float = detail_noise.get_noise_2d(x, z)
	var h: float = base * HILL_HEIGHT + ridge * ridge * 26.0 + detail * 13.0 - 18.0

	# Flatten a bowl in the middle so the town and the starting area sit on
	# open, readable ground rather than halfway up a slope.
	h *= smoothstep(70.0, 300.0, radius)
	h += _gorge_at(x, z)
	return _rim_at(x, z, radius, h)


## The wall. Between [constant RIM_INNER] and [constant RIM_CREST] the ground
## lifts into a ridge; past the crest it keeps climbing into the massif.
##
## The rim is blended in rather than added, so a low patch of base noise can
## never open a gully through it. That guarantee is what the arena is made of —
## a single gap would be a door out of the world.
func _rim_at(x: float, z: float, radius: float, h: float) -> float:
	# The foot of the wall wanders in and out by up to 90 m. A wall at a
	# constant radius is a crater lip, and from the air it reads as one — this
	# breaks it into spurs and bays you can soar into, and it is why the arena
	# looks like a valley in a mountain range rather than a bowl someone drew a
	# circle around.
	var wobble: float = rim_noise.get_noise_2d(x * 0.35, z * 0.35)
	var inner: float = RIM_INNER - 55.0 * wobble
	var crest_radius: float = RIM_CREST - 30.0 * wobble
	if radius < inner:
		return h
	var wall: float = smoothstep(inner, crest_radius, radius)
	var jag: float = 0.86 + 0.40 * (0.5 + 0.5 * rim_noise.get_noise_2d(x, z))
	var crest: float = RIM_HEIGHT * jag
	# Spurs and gullies at the scale a bird flies through, roughly every 150 m.
	# Without them a 340 m wall is a smooth curtain, and a smooth curtain from
	# 300 m away is the most boring thing in a flying game.
	crest += 58.0 * (1.0 - absf(ridge_noise.get_noise_2d(x * 1.9, z * 1.9)))
	# And crags at four grid quads across, so the faces catch the sun at
	# different angles instead of presenting one enormous flat ramp.
	crest += 26.0 * (1.0 - absf(ridge_noise.get_noise_2d(x * 5.4, z * 5.4)))
	# Beyond the crest: more mountain, higher, forever. Nothing here is meant to
	# be reachable — it is the skyline, and it is why the rim is a boundary
	# instead of a hurdle.
	var beyond: float = smoothstep(RIM_CREST, MASSIF_RADIUS, radius)
	crest += beyond * MASSIF_HEIGHT * (0.8 + 1.0 * (0.5 + 0.5 * peak_noise.get_noise_2d(x, z)))
	# Keep most of the local relief so the wall has spines and gullies. At 35 %
	# it came out as smooth white domes; mountains need their own texture or the
	# snow line turns them into meringue.
	return lerpf(h, crest + h * 0.75, wall)


## Lays out the gorge before anything else needs to know about it. A polyline
## rather than a formula because a straight trench is a corridor and a bent one
## is a place: the bends are what make carving through it a skill.
func _plan_gorge() -> void:
	var points := PackedVector2Array()
	var steps: int = 12
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		var radius: float = lerpf(265.0, 610.0, t)
		var angle: float = GORGE_ANGLE + sin(t * 3.6 + 0.7) * 0.30
		points.append(Vector2(cos(angle) * radius, sin(angle) * radius))
	_gorge_path = points

	var bounds := Rect2(points[0], Vector2.ZERO)
	for p: Vector2 in points:
		bounds = bounds.expand(p)
	_gorge_bounds = bounds.grow(GORGE_RIM + 90.0)


## How much the gorge cuts (or heaps up, at its shoulders) at a point.
func _gorge_at(x: float, z: float) -> float:
	if _gorge_path.is_empty():
		return 0.0
	var here := Vector2(x, z)
	if not _gorge_bounds.has_point(here):
		return 0.0

	var best: float = INF
	var best_t: float = 0.0
	var segments: int = _gorge_path.size() - 1
	for i in segments:
		var a: Vector2 = _gorge_path[i]
		var b: Vector2 = _gorge_path[i + 1]
		var ab: Vector2 = b - a
		var t: float = clampf((here - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
		var distance: float = here.distance_to(a + ab * t)
		if distance < best:
			best = distance
			best_t = (float(i) + t) / float(segments)

	# Fade the trench out at both ends: it must not slice the town open at one
	# end or breach the rim wall at the other.
	var taper: float = smoothstep(0.0, 0.14, best_t) * smoothstep(1.0, 0.84, best_t)
	if taper <= 0.0:
		return 0.0
	var cut: float = GORGE_DEPTH * (1.0 - smoothstep(GORGE_FLOOR, GORGE_RIM, best))
	# Heaped shoulders just outside the lip. They read from the air as a scar in
	# the landscape long before you can see down into it.
	var shoulder: float = best - (GORGE_RIM + 24.0)
	var lip: float = 26.0 * exp(-(shoulder * shoulder) / 3200.0)
	return (lip - cut) * taper


## Total air movement at a point: thermal cores plus a gentle push up the face
## of steep ground. This is what makes staying up without flapping a skill.
func wind_at(position: Vector3) -> Vector3:
	var lift: float = 0.0
	for thermal: Dictionary in _thermals:
		var centre: Vector2 = thermal["centre"]
		var radius: float = thermal["radius"]
		var offset: Vector2 = Vector2(position.x, position.z) - centre
		var distance: float = offset.length()
		if distance > radius:
			continue
		var ceiling: float = thermal["ceiling"]
		if position.y > ceiling:
			continue
		# Strongest in the core, fading to nothing at the edge and at the top.
		# Flat-topped, not a spike. The profile used to be (1 - d/r) squared, which
		# gave a bird circling thirty metres from the middle of a fifty-metre core
		# eighteen percent of the strength — less than its own sink rate at every
		# bank angle the flight model affords, so nothing in this world, player or
		# bird, could actually climb in a thermal. Measured with a sweep over bank
		# and angle of attack in `tests/_soar_probe`; see docs and AITests.
		var radial: float = clampf((1.0 - distance / radius) * 1.45, 0.0, 1.0)
		var vertical: float = clampf(1.0 - position.y / ceiling, 0.0, 1.0)
		lift += thermal["strength"] * radial * vertical

	lift += _ridge_lift(position)
	return Vector3(0.0, lift, 0.0)


## Ridge lift: air shoved upward where it meets rising ground. Only close to the
## slope, so hugging a hillside becomes a genuine (and risky) way to stay up.
func _ridge_lift(position: Vector3) -> float:
	var ground: float = height_at(position.x, position.z)
	var above: float = position.y - ground
	if above < 0.0 or above > 55.0:
		return 0.0
	var step: float = 12.0
	var slope := Vector2(
		height_at(position.x + step, position.z) - height_at(position.x - step, position.z),
		height_at(position.x, position.z + step) - height_at(position.x, position.z - step)
	) / (2.0 * step)
	var steepness: float = clampf(slope.length() * 2.0, 0.0, 1.0)
	var proximity: float = 1.0 - (above / 55.0)
	return steepness * proximity * 3.4


# --- materials ---------------------------------------------------------------

## Every colour, material, light and atmosphere value in this world comes from
## [Palette]. Nothing here invents one — see [code]docs/ART-DIRECTION.md[/code].
func _material(name: String) -> StandardMaterial3D:
	return _materials.get(name, _materials.get("rock"))


func _make_materials() -> void:
	_materials = Palette.materials(hour)


# --- environment -------------------------------------------------------------

func _build_environment() -> void:
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = Palette.environment(hour)
	add_child(world_env)
	add_child(Palette.sun(hour, MOBILE))


# --- terrain -----------------------------------------------------------------

## Builds the ground as one faceted mesh, on rings and spokes rather than on a
## square grid.
##
## [b]Why polar.[/b] This world is a bowl inside a ring wall, and the wall climbs
## 340 m across 180 m of ground — 60 to 70 degrees. On a uniform 15 m square
## grid that is one quad wide and up to 45 m long measured along the slope, and
## on the diagonals half again worse: the whole horizon rendered as a comb of
## vertical needles, which is what the biggest object in nearly every frame
## actually looked like. Faceted shading makes it worse rather than better,
## because each needle is one flat colour.
##
## Rings fix it because the wall is a radial feature: the direction that needs
## resolution is the one the ground is climbing in. [constant RING_STEPS] spends
## 6 m rings on the wall and 15 m rings on the bowl, which on a 65-degree face
## comes to about 14 m measured along the slope against 16 m between spokes —
## triangles you can read as facets instead of streaks.
##
## [b]And why the spokes drop as they come in.[/b] A fixed spoke count is the
## same mistake at the other end of the disc: at 320 spokes the triangles under
## the town were fifteen metres long and thirty centimetres wide, and from above
## the bowl showed a faint pinwheel radiating out of the spawn point. Halving the
## count whenever the gap between neighbours falls under
## [constant MIN_TANGENT_STEP] holds it between 8 and 16 m from the town to the
## massif — and rings of different counts are stitched with a three-triangle fan
## rather than left to crack open.
##
## Heights are sampled once per grid point and shared by the quads that meet
## there; [method height_at] is the most-called function in the build.
func _terrain_rings() -> PackedFloat32Array:
	var radii := PackedFloat32Array()
	radii.append(0.0)
	var radius: float = 0.0
	for band: Vector2 in RING_STEPS:
		while radius < band.x - 0.001:
			radius = minf(radius + band.y, band.x)
			radii.append(radius)
	return radii


## How many samples each ring gets, worked out from the outside in so that a ring
## is always either the same as the one outside it or exactly half — which is the
## only case [method _build_terrain]'s stitch knows how to close.
func _terrain_spokes(radii: PackedFloat32Array) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(radii.size())
	var count: int = TERRAIN_SPOKES
	counts[radii.size() - 1] = count
	for i in range(radii.size() - 2, 0, -1):
		if TAU * radii[i] / float(count) < MIN_TANGENT_STEP and count > MIN_SPOKES:
			count /= 2
		counts[i] = count
	# The centre is one point, so the disc closes with a fan instead of a hole.
	counts[0] = 1
	return counts


func _build_terrain() -> void:
	var radii: PackedFloat32Array = _terrain_rings()
	var counts: PackedInt32Array = _terrain_spokes(radii)
	var rings: int = radii.size()

	var points: Array[PackedVector3Array] = []
	var dust: Array[PackedFloat32Array] = []
	for ir in rings:
		var radius: float = radii[ir]
		var count: int = counts[ir]
		var ring := PackedVector3Array()
		ring.resize(count)
		var bleach := PackedFloat32Array()
		bleach.resize(count)
		for js in count:
			var angle: float = TAU * float(js) / float(count)
			var x: float = cos(angle) * radius
			var z: float = sin(angle) * radius
			ring[js] = Vector3(x, height_at(x, z), z)
			bleach[js] = _thermal_dust(x, z)
		points.append(ring)
		dust.append(bleach)

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Outward is +radius and around is +angle, which has the same handedness in
	# the ground plane as the +x/+z pair this used to walk, so the winding — and
	# therefore which side the normals end up on — is unchanged.
	for ir in rings - 1:
		var inner: PackedVector3Array = points[ir]
		var outer: PackedVector3Array = points[ir + 1]
		var inner_dust: PackedFloat32Array = dust[ir]
		var outer_dust: PackedFloat32Array = dust[ir + 1]
		var n_in: int = counts[ir]
		var n_out: int = counts[ir + 1]
		if n_in == 1:
			for j in n_out:
				var k: int = (j + 1) % n_out
				_add_triangle(
					surface, inner[0], outer[j], outer[k],
					inner_dust[0], outer_dust[j], outer_dust[k]
				)
			continue
		if n_in == n_out:
			for j in n_in:
				var k: int = (j + 1) % n_in
				_add_triangle(
					surface, inner[j], outer[j], outer[k],
					inner_dust[j], outer_dust[j], outer_dust[k]
				)
				_add_triangle(
					surface, inner[j], outer[k], inner[k],
					inner_dust[j], outer_dust[k], inner_dust[k]
				)
			continue
		# The outer ring has twice the samples: three triangles per inner segment,
		# sharing the outer vertex in the middle. Watertight, no T-junction.
		for j in n_in:
			var k: int = (j + 1) % n_in
			var a: int = j * 2
			var b: int = (a + 1) % n_out
			var c: int = (a + 2) % n_out
			_add_triangle(
				surface, inner[j], outer[a], outer[b],
				inner_dust[j], outer_dust[a], outer_dust[b]
			)
			_add_triangle(
				surface, inner[j], outer[b], inner[k],
				inner_dust[j], outer_dust[b], inner_dust[k]
			)
			_add_triangle(
				surface, inner[k], outer[b], outer[c],
				inner_dust[k], outer_dust[b], outer_dust[c]
			)

	surface.generate_normals()
	var mesh: ArrayMesh = surface.commit()

	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _material("ground")
	body.add_child(visual)

	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


## How bleached the ground is by a thermal overhead. Sun-baked bare earth is
## what actually generates a thermal, and painting it on the ground gives a
## pilot something to read from 200 m up — the cloud says where the lift tops
## out, the pale patch says where it starts.
func _thermal_dust(x: float, z: float) -> float:
	var here := Vector2(x, z)
	var strongest: float = 0.0
	for thermal: Dictionary in _thermals:
		var centre: Vector2 = thermal["centre"]
		var radius: float = thermal["radius"]
		var distance: float = here.distance_to(centre)
		if distance > radius:
			continue
		# The pale patch is the size of the core, and the core is now flat-topped
		# out to nearly half its radius (see [method wind_at]). Widening this to
		# match keeps the ground tell honest: what is bleached is what lifts.
		strongest = maxf(strongest, 1.0 - smoothstep(0.45, 1.0, distance / radius))
	return strongest


## Adds one ground triangle, flat-shaded and flat-coloured.
##
## One colour for the whole facet, taken at its centre, is the entire low-poly
## read of the terrain: colouring per vertex instead smears every band across the
## triangles that touch it, and 600 000 vertices of smooth gradient is exactly
## what made the old ground look like painted felt rather than land. The colour
## comes from [method Palette.ground_colour]; the small per-facet shade offset it
## takes is hashed from the position, so the mesh is identical however it is
## walked and the world's determinism test still holds.
func _add_triangle(
	surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
	da: float, db: float, dc: float
) -> void:
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	var steepness: float = 1.0 - clampf(absf(normal.y), 0.0, 1.0)
	var centre: Vector3 = (a + b + c) / 3.0
	var colour: Color = Palette.ground_colour(
		centre.y, steepness, (da + db + dc) / 3.0,
		Palette.facet_shade(centre.x, centre.z)
	)
	surface.set_color(colour)
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)


# --- batched primitives ------------------------------------------------------

## Adds a box to [param batch] and, unless [param collide] is false, a matching
## collider on [param body].
func _box(
	batch: GeometryBatch,
	body: StaticBody3D,
	centre: Vector3,
	size: Vector3,
	material: String,
	basis: Basis = Basis.IDENTITY,
	collide: bool = true
) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	batch.add(mesh, Transform3D(basis, centre), material)
	if not collide or body == null:
		return
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.transform = Transform3D(basis, centre)
	body.add_child(shape)


func _cylinder(
	batch: GeometryBatch,
	body: StaticBody3D,
	from: Vector3,
	to: Vector3,
	radius: float,
	material: String,
	collide: bool = true
) -> void:
	var axis: Vector3 = to - from
	var length: float = axis.length()
	if length < 0.01:
		return
	var transform := Transform3D(_basis_aligned_to(axis), (from + to) * 0.5)

	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 6  # faceted on purpose
	mesh.rings = 0
	batch.add(mesh, transform, material)

	if not collide or body == null:
		return
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = maxf(radius, 0.05)
	cylinder.height = length
	shape.shape = cylinder
	shape.transform = transform
	body.add_child(shape)


func _blob(
	batch: GeometryBatch, centre: Vector3, radius: float, material: String,
	flatten: float = 1.75
) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * flatten
	mesh.radial_segments = 6
	mesh.rings = 4
	batch.add(mesh, Transform3D(Basis.IDENTITY, centre), material)


## A basis whose local +Y runs along [param axis], which is how Godot's cylinder
## and capsule primitives are oriented.
static func _basis_aligned_to(axis: Vector3) -> Basis:
	var up: Vector3 = axis.normalized()
	var reference: Vector3 = Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var right: Vector3 = reference.cross(up).normalized()
	var forward: Vector3 = up.cross(right).normalized()
	return Basis(right, up, forward)


## Commits a structure's batched geometry and gives it a draw distance.
##
## Colliders deliberately keep working past the visual range: a bird should
## never fly through a tree just because it stopped being drawn, and the
## distances are set well beyond anything you could reach before it reappears.
##
## The dithered fade is desktop-only. Its shader variant is broken on Godot
## 4.7's Forward Mobile renderer — it corrupts on desktop-mobile and renders
## nothing at all on Quest hardware, which silently deleted every tree,
## building, pole and arch from the headset build while leaving the terrain
## (the one thing with no range set) behind. A hard cull needs no shader
## variant, and at these distances the aerial haze hides the pop.
func _finish(
	body: Node3D, batch: GeometryBatch, draw_range: float = 0.0,
	casts_shadow: bool = true
) -> void:
	if batch.is_empty():
		return
	var visual := MeshInstance3D.new()
	visual.mesh = batch.commit(_materials)
	if not casts_shadow:
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if draw_range > 0.0:
		visual.visibility_range_end = draw_range * (MOBILE_RANGE_SCALE if MOBILE else 1.0)
		visual.visibility_range_end_margin = visual.visibility_range_end * 0.15
		visual.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	body.add_child(visual)


func _static_body(name: String, at: Vector3, yaw: float = 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = name
	body.collision_layer = 1
	body.position = at
	body.rotation.y = yaw
	add_child(body)
	return body


func _ground_point(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


## Turns a point in a structure's own frame into world space.
func _to_world(body: Node3D, local: Vector3) -> Vector3:
	return _origin * (body.transform * local)


## Ground height at a point given in a structure's own frame. A ring of stones
## or a run of piers laid out on a slope looks glued on unless every piece finds
## its own footing, and half of this world is now slope.
func _local_ground(body: Node3D, local: Vector3) -> float:
	var world: Vector3 = _to_world(body, local)
	return height_at(world.x, world.z) - _to_world(body, Vector3.ZERO).y


func _scatter_position(min_radius: float, max_radius: float) -> Vector3:
	var angle: float = rng.randf() * TAU
	var radius: float = sqrt(rng.randf()) * (max_radius - min_radius) + min_radius
	return _ground_point(cos(angle) * radius, sin(angle) * radius)


## A ground point at a chosen bearing and distance from the middle. Used for
## everything that has to land in a particular district.
func _district_position(angle: float, radius: float) -> Vector3:
	return _ground_point(cos(angle) * radius, sin(angle) * radius)


func _add_perch(body: StaticBody3D, local: Vector3) -> void:
	perch_points.append(_to_world(body, local))


# --- the coverage grid -------------------------------------------------------

## Places one structure per grid cell across the whole arena, jittered so the
## layout never looks like a chessboard.
##
## This replaces the random grove scatter that used to populate the world, where
## a bird that glided into a gap spent the rest of the session over an empty
## field with the nearest landmark 316 m away. A jittered grid bounds that
## distance by construction — worst case is the half-diagonal of a cell plus the
## jitter, about 160 m — instead of leaving it to the seed.
##
## Honest measurement, though: with the district landmarks, the eleven
## bearing-spread powerline runs and the twelve spread arches also in place, a
## plain random scatter of the same density now measures about as well
## (173 m worst against this grid's 180 m). The grid is not what rescues the
## number today; it is what stops the number from depending on luck the next
## time somebody changes a count. `WorldTests` walks three extra seeds for
## exactly that reason.
##
## What goes in a cell is chosen by district, which is what gives each quadrant
## its own skyline — and that part the scatter cannot do at all.
## Beyond this the ground is the rim wall itself. Structures placed on a 60
## degree slope either float or bury themselves, and nothing up there is worth
## flying to anyway.
const PLOT_LIMIT: float = 720.0
## Steepest ground a structure will be planted on, as a gradient.
const PLOT_MAX_SLOPE: float = 0.85


func _build_plots() -> void:
	var cells: int = int(ceil(PLOT_LIMIT / PLOT_SIZE))
	var index: int = 0
	for ix in range(-cells, cells + 1):
		for iz in range(-cells, cells + 1):
			var x: float = ix * PLOT_SIZE + rng.randf_range(-PLOT_JITTER, PLOT_JITTER)
			var z: float = iz * PLOT_SIZE + rng.randf_range(-PLOT_JITTER, PLOT_JITTER)
			if Vector2(x, z).length() > PLOT_LIMIT:
				continue
			if _slope_at(x, z) > PLOT_MAX_SLOPE:
				continue
			index += 1
			_build_plot(index, x, z)


## Local ground gradient, sampled the same way [method _ridge_lift] samples it.
func _slope_at(x: float, z: float) -> float:
	var step: float = 12.0
	return Vector2(
		height_at(x + step, z) - height_at(x - step, z),
		height_at(x, z + step) - height_at(x, z - step)
	).length() / (2.0 * step)


func _build_plot(index: int, x: float, z: float) -> void:
	var region: Region = region_at(x, z)
	var roll: float = rng.randf()
	match region:
		Region.TOWN:
			# A park, but only where there is room for one. Buildings are
			# landmarks in their own right, so a cell that already has one
			# beside it is covered and does not need a tree through its roof.
			if _distance_to_nearest_building(Vector2(x, z)) > 58.0:
				_plant_grove(index, x, z, 3, 5, "broadleaf")
		Region.GREENWOOD:
			if roll < 0.86:
				_plant_grove(index, x, z, 7, 14, "broadleaf")
			else:
				_plant_grove(index, x, z, 1, 2, "giant")
		Region.SPIRES:
			if roll < 0.62:
				_build_spire_cluster(index, x, z)
			elif roll < 0.80:
				_build_ruin(index, x, z, "rock_cold")
			else:
				_plant_grove(index, x, z, 4, 9, "conifer")
		Region.GORGE:
			# Inside the trench: bare rock teeth on the floor and the shoulders.
			if _distance_to_gorge(Vector2(x, z)) < GORGE_RIM + 60.0:
				_build_gorge_teeth(index, x, z)
			elif roll < 0.45:
				_build_standing_stones(index, x, z, "rock_warm")
			elif roll < 0.72:
				_build_ruin(index, x, z, "rock_warm")
			else:
				_plant_grove(index, x, z, 4, 9, "broadleaf")
		Region.DOWNS:
			if roll < 0.42:
				_build_standing_stones(index, x, z, "rock_moss")
			elif roll < 0.70:
				_build_ruin(index, x, z, "rock_moss")
			else:
				_plant_grove(index, x, z, 4, 9, "broadleaf")
		Region.RIM:
			if roll < 0.55:
				_build_cairn(index, x, z)
			else:
				_plant_grove(index, x, z, 4, 10, "conifer")


func _distance_to_nearest_building(here: Vector2) -> float:
	var best: float = INF
	for spot: Vector2 in _building_spots:
		best = minf(best, here.distance_to(spot))
	return best


func _distance_to_gorge(here: Vector2) -> float:
	var best: float = INF
	for i in _gorge_path.size() - 1:
		var a: Vector2 = _gorge_path[i]
		var b: Vector2 = _gorge_path[i + 1]
		var ab: Vector2 = b - a
		var t: float = clampf((here - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
		best = minf(best, here.distance_to(a + ab * t))
	return best


# --- forest ------------------------------------------------------------------

## Trees come in groves rather than an even scatter, so the map alternates
## between dense slalom country and open air worth diving across. Each tree is
## built branch by branch, because the branches are the point: they are what you
## thread through, clip a wingtip on, and land in.
## A grove is one structure, not one per tree. Eleven trees as eleven mesh
## instances is twenty-two draw calls for one clump of scenery, which is what
## forced the old 380 m tree cull — and a world whose forests vanish the moment
## you climb above them is a world that looks empty from the air. Batched, a
## grove costs two draw calls and can be drawn from twice as far away.
func _plant_grove(
	index: int, x: float, z: float, low: int, high: int, style: String
) -> void:
	var grove: StaticBody3D = _static_body("Grove%d" % index, _ground_point(x, z))
	var batch := GeometryBatch.new()
	var spread: float = rng.randf_range(18.0, 46.0)
	var count: int = rng.randi_range(low, high)
	for i in count:
		var angle: float = rng.randf() * TAU
		var distance: float = sqrt(rng.randf()) * spread
		var offset := Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		offset.y = _local_ground(grove, offset)
		match style:
			"conifer":
				_build_conifer(grove, batch, offset, rng.randf_range(14.0, 26.0))
			"giant":
				_build_tree(grove, batch, offset, rng.randf_range(52.0, 74.0))
			_:
				_build_tree(grove, batch, offset, rng.randf_range(18.0, 40.0))
	_finish(grove, batch, RANGE_TREE)


func _build_tree(
	tree: StaticBody3D, batch: GeometryBatch, base: Vector3, height: float
) -> void:
	var trunk_radius: float = height * rng.randf_range(0.024, 0.038)
	_cylinder(batch, tree, base, base + Vector3(0.0, height, 0.0), trunk_radius, "bark")

	var leaf: String = "leaf"
	var roll: float = rng.randf()
	if roll > 0.80:
		leaf = "leaf_autumn"
	elif roll > 0.45:
		leaf = "leaf_deep"

	var tiers: int = rng.randi_range(4, 6)
	for tier in tiers:
		var t: float = 0.38 + 0.62 * (float(tier) / float(maxi(tiers - 1, 1)))
		var y: float = height * t
		var branches: int = rng.randi_range(3, 5)
		# Branches are longest low on the trunk and shorten toward the crown,
		# which is what gives a tree its silhouette. Keeping the coefficient
		# small matters: an over-long reach turns every tree into a single
		# enormous ball of foliage with no gaps worth threading.
		var reach: float = (1.15 - t) * height * rng.randf_range(0.16, 0.26) + 1.6
		var phase: float = rng.randf() * TAU
		for b in branches:
			var angle: float = phase + TAU * float(b) / float(branches)
			var tip: Vector3 = base + Vector3(
				cos(angle) * reach,
				y + reach * rng.randf_range(0.10, 0.38),
				sin(angle) * reach
			)
			_cylinder(batch, tree, base + Vector3(0.0, y, 0.0), tip,
				trunk_radius * 0.40, "bark")
			# Foliage gets no collider — leaves should never be the thing that
			# swats a bird out of the air.
			_blob(batch, tip, reach * rng.randf_range(0.30, 0.44), leaf)
			_add_perch(tree, tip)


## A narrow alpine conifer: a spike of stacked skirts. Cheaper than a branching
## tree — the rim band needs a hundred of them and none of them are worth twenty
## colliders — and the pointed silhouette is what separates the high ground from
## the greenwood at a glance.
func _build_conifer(
	tree: StaticBody3D, batch: GeometryBatch, base: Vector3, height: float
) -> void:
	var trunk_radius: float = height * 0.030
	_cylinder(batch, tree, base, base + Vector3(0.0, height, 0.0), trunk_radius, "bark")
	var skirts: int = rng.randi_range(4, 6)
	for i in skirts:
		var t: float = float(i) / float(skirts)
		var y: float = height * (0.24 + 0.72 * t)
		var radius: float = height * 0.24 * (1.0 - t * 0.78)
		_blob(batch, base + Vector3(0.0, y, 0.0), radius, "leaf_alpine", 2.4)
		if i % 2 == 0:
			_add_perch(tree, base + Vector3(radius * 0.6, y, 0.0))
	_add_perch(tree, base + Vector3(0.0, height, 0.0))


# --- town --------------------------------------------------------------------

## Buildings exist for their ledges and window sills. A plain box is a wall you
## avoid; a box with a sill under every window is somewhere to thread, land and
## kick off from.
func _build_town() -> void:
	for i in BUILDING_COUNT:
		var base: Vector3 = _scatter_position(35.0, TOWN_RADIUS - 10.0)
		_building_spots.append(Vector2(base.x, base.z))
		var body: StaticBody3D = _static_body("Building%d" % i, base, rng.randf() * TAU)
		_build_building(body)


func _build_building(body: StaticBody3D) -> void:
	var batch := GeometryBatch.new()
	var width: float = rng.randf_range(11.0, 22.0)
	var depth: float = rng.randf_range(11.0, 22.0)
	var floors: int = rng.randi_range(4, 12)
	var floor_height: float = 3.6
	var height: float = floors * floor_height

	var walls: Array[String] = ["wall", "wall_warm", "wall_pale"]
	var wall: String = walls[rng.randi() % walls.size()]
	_box(batch, body, Vector3(0.0, height * 0.5, 0.0), Vector3(width, height, depth), wall)
	_box(batch, body, Vector3(0.0, height + 0.35, 0.0),
		Vector3(width + 1.8, 0.7, depth + 1.8), "roof")
	_add_perch(body, Vector3(0.0, height + 0.8, 0.0))

	# Window bands with a protruding sill on each face.
	for level in range(1, floors):
		var y: float = level * floor_height
		for face in 4:
			var angle: float = face * PI * 0.5
			var outward := Vector3(sin(angle), 0.0, cos(angle))
			var half: float = (depth if face % 2 == 0 else width) * 0.5
			var span: float = (width if face % 2 == 0 else depth) - 2.6
			if span < 3.0:
				continue
			var basis := Basis(Vector3.UP, angle)

			# Glass gets no collider: threading an open window band is a trick
			# worth rewarding, not a wall to bounce off.
			_box(batch, body, outward * (half + 0.05) + Vector3(0.0, y + 1.15, 0.0),
				Vector3(span, 1.6, 0.12), "window", basis, false)

			var sill: Vector3 = outward * (half + 0.22) + Vector3(0.0, y + 0.28, 0.0)
			_box(batch, body, sill, Vector3(span + 0.8, 0.24, 0.62), "ledge", basis)
			_add_perch(body, sill + Vector3(0.0, 0.25, 0.0))

	_finish(body, batch, RANGE_BUILDING)


# --- rock --------------------------------------------------------------------

## A cluster of rock pinnacles. Two or three of them close together give you
## something to spiral inside rather than merely around, which is the flight
## verb the old world had no answer for.
func _build_spire_cluster(index: int, x: float, z: float) -> void:
	var body: StaticBody3D = _static_body("Spires%d" % index, _ground_point(x, z))
	var batch := GeometryBatch.new()
	var count: int = rng.randi_range(2, 4)
	for i in count:
		var angle: float = rng.randf() * TAU
		var distance: float = sqrt(rng.randf()) * 42.0
		var sx: float = x + cos(angle) * distance
		var sz: float = z + sin(angle) * distance
		var base := Vector3(sx - x, 0.0, sz - z)
		base.y = _local_ground(body, base)
		# Spires grow with distance from town. Partly silhouette — the district
		# should build toward the rim rather than start at full height — and
		# partly mercy: the spawn faces this quadrant, and a 130 m rock 250 m
		# ahead is something a player flies into at seventeen seconds while they
		# are still working out which way their arms go.
		var out: float = smoothstep(240.0, 480.0, Vector2(sx, sz).length())
		_build_spire(
			body, batch, base,
			lerpf(rng.randf_range(32.0, 58.0), rng.randf_range(72.0, 138.0), out),
			"rock_cold"
		)
	_finish(body, batch, RANGE_SPIRE)


func _build_spire(
	body: StaticBody3D, batch: GeometryBatch, base: Vector3, height: float,
	material: String
) -> void:
	var segments: int = maxi(4, int(height / 13.0))
	var base_radius: float = height * rng.randf_range(0.11, 0.17)
	# A slight, consistent lean per spire. A vertical stack of boxes reads as a
	# chimney; a leaning one reads as rock.
	var lean := Vector2(rng.randf_range(-0.09, 0.09), rng.randf_range(-0.09, 0.09))
	var y: float = 0.0
	for i in segments:
		var t: float = float(i) / float(segments)
		var segment_height: float = height / float(segments) * rng.randf_range(0.88, 1.14)
		var radius: float = base_radius * (1.0 - t * 0.74) * rng.randf_range(0.86, 1.14)
		var centre: Vector3 = base + Vector3(
			lean.x * y, y + segment_height * 0.5, lean.y * y
		)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		_box(batch, body, centre,
			Vector3(radius * 2.0, segment_height, radius * 1.7), material, basis)
		# A gallery every few segments: somewhere to land halfway up, and it
		# breaks the taper so the spire does not read as a traffic cone.
		if i > 0 and i % 3 == 0:
			var gallery: Vector3 = base + Vector3(
				lean.x * y, y + segment_height * 0.15, lean.y * y
			)
			_box(batch, body, gallery,
				Vector3(radius * 3.1, 1.1, radius * 2.7), material, basis)
			_add_perch(body, gallery + Vector3(radius * 1.3, 0.9, 0.0))
		y += segment_height
	_add_perch(body, base + Vector3(lean.x * y, y + 0.8, lean.y * y))


## Standing stones: a ring of tilted slabs around a tall menhir. Cheap, reads
## from a long way off, and the ring is exactly wide enough to fly through at
## speed if you commit to it.
func _build_standing_stones(index: int, x: float, z: float, material: String) -> void:
	var body: StaticBody3D = _static_body(
		"Stones%d" % index, _ground_point(x, z), rng.randf() * TAU
	)
	var batch := GeometryBatch.new()
	var ring: float = rng.randf_range(11.0, 22.0)
	var count: int = rng.randi_range(5, 9)
	for i in count:
		var angle: float = TAU * float(i) / float(count) + rng.randf_range(-0.2, 0.2)
		var height: float = rng.randf_range(7.0, 17.0)
		var tilt: float = rng.randf_range(-0.16, 0.16)
		var basis := Basis(Vector3.UP, angle) * Basis(Vector3.FORWARD, tilt)
		var foot := Vector3(cos(angle) * ring, 0.0, sin(angle) * ring)
		# Sunk a couple of metres so a slab on a slope is buried, not floating.
		var centre: Vector3 = foot + Vector3(
			0.0, _local_ground(body, foot) + height * 0.5 - 2.0, 0.0
		)
		_box(batch, body, centre,
			Vector3(rng.randf_range(2.0, 3.6), height, rng.randf_range(1.0, 1.8)),
			material, basis)
		_add_perch(body, centre + Vector3(0.0, height * 0.5 + 0.4, 0.0))
	var menhir: float = rng.randf_range(19.0, 30.0)
	_box(batch, body, Vector3(0.0, menhir * 0.5, 0.0),
		Vector3(3.4, menhir, 2.6), material, Basis(Vector3.UP, rng.randf() * TAU))
	_add_perch(body, Vector3(0.0, menhir + 0.4, 0.0))
	_finish(body, batch, RANGE_STONE)


## A ruined wall: piers with lintels over some of the gaps. The gaps are the
## point — a row of holes at wingtip height is the cheapest threading challenge
## in the game and the one that scales with how brave you feel.
func _build_ruin(index: int, x: float, z: float, material: String) -> void:
	var body: StaticBody3D = _static_body(
		"Ruin%d" % index, _ground_point(x, z), rng.randf() * TAU
	)
	var batch := GeometryBatch.new()
	var bays: int = rng.randi_range(3, 6)
	var bay: float = rng.randf_range(9.0, 14.0)
	var height: float = rng.randf_range(11.0, 21.0)
	var thickness: float = rng.randf_range(1.3, 2.2)
	var length: float = bays * bay
	# The lintels have to sit at one height or the wall stops reading as a wall,
	# so the deck line follows the highest pier and the low ones grow to meet it.
	var deck: float = -INF
	var feet := PackedFloat32Array()
	for i in bays + 1:
		var px: float = -length * 0.5 + i * bay
		var base: float = _local_ground(body, Vector3(px, 0.0, 0.0)) - 1.5
		feet.append(base)
		deck = maxf(deck, base + height)
	for i in bays + 1:
		var px: float = -length * 0.5 + i * bay
		# Ruined, so some piers are snapped off short of the lintel line.
		var top: float = deck - rng.randf_range(0.0, height * 0.28)
		var pier: float = maxf(top - feet[i], 4.0)
		_box(batch, body, Vector3(px, feet[i] + pier * 0.5, 0.0),
			Vector3(thickness * 1.6, pier, thickness), material)
		_add_perch(body, Vector3(px, feet[i] + pier + 0.4, 0.0))
		# Two thirds of the bays keep their lintel; the rest are open sky.
		if i < bays and rng.randf() < 0.66:
			_box(batch, body, Vector3(px + bay * 0.5, deck, 0.0),
				Vector3(bay, thickness * 1.4, thickness), material)
			_add_perch(body, Vector3(px + bay * 0.5, deck + 0.9, 0.0))
	_finish(body, batch, RANGE_RUIN)


## Teeth of rock on the gorge floor and shoulders. Narrows the flyable slot
## without narrowing the terrain, which at 15 m per quad the terrain cannot do.
func _build_gorge_teeth(index: int, x: float, z: float) -> void:
	var body: StaticBody3D = _static_body("Teeth%d" % index, _ground_point(x, z))
	var batch := GeometryBatch.new()
	var count: int = rng.randi_range(3, 5)
	for i in count:
		var angle: float = rng.randf() * TAU
		var distance: float = sqrt(rng.randf()) * 32.0
		var base := Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		base.y = _local_ground(body, base)
		# Short spires rather than boxes: an upright rectangle at this scale
		# reads as a chocolate bar, and the trench was full of them.
		_build_spire(body, batch, base, rng.randf_range(20.0, 58.0), "rock_warm")
	_finish(body, batch, RANGE_STONE)


## A rim cairn with a banner pole. Man-made, small, and unmistakably a marker:
## it is the only thing up on the snow line, so seeing one means you have
## reached the wall.
func _build_cairn(index: int, x: float, z: float) -> void:
	var body: StaticBody3D = _static_body(
		"Cairn%d" % index, _ground_point(x, z), rng.randf() * TAU
	)
	var batch := GeometryBatch.new()
	var stones: int = rng.randi_range(4, 6)
	var y: float = 0.0
	for i in stones:
		var size: float = lerpf(4.4, 1.5, float(i) / float(stones))
		_box(batch, body, Vector3(0.0, y + size * 0.4, 0.0),
			Vector3(size, size * 0.8, size * 0.9), "rock_pale",
			Basis(Vector3.UP, rng.randf() * TAU))
		y += size * 0.8
	var mast: float = rng.randf_range(9.0, 14.0)
	_cylinder(batch, body, Vector3(0.0, y, 0.0), Vector3(0.0, y + mast, 0.0), 0.22, "pole")
	_box(batch, body, Vector3(1.6, y + mast - 1.6, 0.0), Vector3(3.2, 2.2, 0.10),
		"banner", Basis.IDENTITY, false)
	_add_perch(body, Vector3(0.0, y + mast + 0.3, 0.0))
	_finish(body, batch, RANGE_SPIRE)


# --- landmarks ---------------------------------------------------------------

## One unmissable thing per district, plus a tower in the middle of town.
##
## These exist so that "where am I" has an answer from anywhere in the bowl. The
## town tower is the tallest structure in the world and sits at the centre, so
## it doubles as a compass: if you can see it, you know the way home.
func _build_landmarks() -> void:
	var tower: StaticBody3D = _static_body(
		"TownTower", _district_position(-PI * 0.15, 150.0), rng.randf() * TAU
	)
	_build_tower(tower, 108.0, "wall_pale")

	# Greenwood: a single tree twice the height of the canopy around it.
	var giant: StaticBody3D = _static_body(
		"GreatTree", _district_position(0.0, 455.0), rng.randf() * TAU
	)
	var giant_batch := GeometryBatch.new()
	_build_tree(giant, giant_batch, Vector3.ZERO, 92.0)
	_finish(giant, giant_batch, RANGE_TOWER)

	# Spires: the tallest pinnacle in the world, dead ahead of the spawn.
	var pinnacle: StaticBody3D = _static_body(
		"GreatSpire", _district_position(-PI * 0.5, 440.0), rng.randf() * TAU
	)
	var pinnacle_batch := GeometryBatch.new()
	_build_spire(pinnacle, pinnacle_batch, Vector3.ZERO, 176.0, "rock_cold")
	_finish(pinnacle, pinnacle_batch, RANGE_TOWER)

	# Downs: a lone watchtower on open ground, visible across the whole quadrant.
	var watch: StaticBody3D = _static_body(
		"Watchtower", _district_position(PI * 0.5, 470.0), rng.randf() * TAU
	)
	_build_tower(watch, 74.0, "rock_moss")

	# Gorge: a natural bridge thrown across the trench at its widest. The one
	# gap in the world that genuinely rewards a committed dive.
	_build_gorge_bridge()


## A tapered stone tower with gallery rings. Somewhere to spiral, and every
## gallery is a landing.
func _build_tower(body: StaticBody3D, height: float, material: String) -> void:
	var batch := GeometryBatch.new()
	var levels: int = maxi(4, int(height / 15.0))
	var base_radius: float = height * 0.085
	var y: float = 0.0
	for i in levels:
		var t: float = float(i) / float(levels)
		var level_height: float = height / float(levels)
		var radius: float = base_radius * (1.0 - t * 0.38)
		_cylinder(batch, body, Vector3(0.0, y, 0.0),
			Vector3(0.0, y + level_height, 0.0), radius, material)
		var gallery: float = y + level_height * 0.94
		_box(batch, body, Vector3(0.0, gallery, 0.0),
			Vector3(radius * 2.9, 0.8, radius * 2.9), "ledge",
			Basis(Vector3.UP, PI * 0.25 * i))
		for side in 4:
			var angle: float = TAU * float(side) / 4.0 + PI * 0.25 * i
			_add_perch(body, Vector3(cos(angle) * radius * 1.3, gallery + 0.6,
				sin(angle) * radius * 1.3))
		y += level_height
	# A spike on top so the silhouette ends in a point rather than a stub.
	_cylinder(batch, body, Vector3(0.0, y, 0.0), Vector3(0.0, y + height * 0.16, 0.0),
		base_radius * 0.22, material)
	_add_perch(body, Vector3(0.0, y + height * 0.16 + 0.4, 0.0))
	_finish(body, batch, RANGE_TOWER)


## Spans the gorge with a rock bridge, deck level with the shoulders and a hole
## underneath big enough to fly through at fifty metres a second.
func _build_gorge_bridge() -> void:
	var mid: Vector2 = _gorge_path[_gorge_path.size() / 2]
	var ahead: Vector2 = _gorge_path[_gorge_path.size() / 2 + 1]
	var along: Vector2 = (ahead - mid).normalized()
	var across := Vector2(-along.y, along.x)

	var deck: float = height_at(mid.x, mid.y) + GORGE_DEPTH + 26.0
	var body: StaticBody3D = _static_body("GorgeBridge", Vector3(mid.x, 0.0, mid.y),
		-atan2(across.y, across.x))
	var batch := GeometryBatch.new()
	var span: float = GORGE_RIM * 2.0
	var pieces: int = 9
	var thickness: float = 9.0
	for p in pieces:
		var t: float = (float(p) + 0.5) / float(pieces)
		var x: float = lerpf(-span * 0.5, span * 0.5, t)
		var arch: float = sin(t * PI) * 22.0
		_box(batch, body, Vector3(x, deck + arch * 0.35, 0.0),
			Vector3(span / pieces + 1.6, thickness, 30.0), "rock_warm",
			Basis(Vector3.FORWARD, (t - 0.5) * 0.5))
	# Abutments, so the deck lands on rock instead of hanging in the air.
	for side: float in [-1.0, 1.0]:
		var foot := Vector3(side * (span * 0.5 + 8.0), 0.0, 0.0)
		var ground: float = _local_ground(body, foot) - 6.0
		var pier: float = maxf(deck - ground, 8.0)
		_box(batch, body, foot + Vector3(0.0, ground + pier * 0.5, 0.0),
			Vector3(20.0, pier, 34.0), "rock_warm")
	_add_perch(body, Vector3(0.0, deck + 12.0, 0.0))
	_finish(body, batch, RANGE_ARCH)


# --- power lines -------------------------------------------------------------

## The classic bird furniture: a long wire to land on in a row, with poles to
## weave between. Runs are aimed roughly at the middle of the map so they read
## as infrastructure going somewhere rather than as random litter.
func _build_powerlines() -> void:
	for run in POWERLINE_RUNS:
		var bearing: float = TAU * float(run) / float(POWERLINE_RUNS) + rng.randf_range(-0.2, 0.2)
		var radius: float = rng.randf_range(160.0, ARENA_RADIUS - 80.0)
		var start: Vector3 = _district_position(bearing, radius)
		var heading: float = bearing + PI * 0.5 + rng.randf_range(-0.5, 0.5)
		var direction := Vector3(cos(heading), 0.0, sin(heading))
		var spacing: float = rng.randf_range(40.0, 56.0)
		var poles: int = rng.randi_range(6, 10)
		var height: float = rng.randf_range(12.0, 17.0)

		var previous_tops: Array[Vector3] = []
		for i in poles:
			var foot: Vector3 = start + direction * spacing * i
			foot.y = height_at(foot.x, foot.z)
			var body: StaticBody3D = _static_body("Pole%d_%d" % [run, i], foot)
			var tops: Array[Vector3] = _build_pole(body, height, direction)
			if not previous_tops.is_empty():
				for w in mini(tops.size(), previous_tops.size()):
					_wire(previous_tops[w], tops[w])
			previous_tops = tops


func _build_pole(body: StaticBody3D, height: float, direction: Vector3) -> Array[Vector3]:
	var batch := GeometryBatch.new()
	_cylinder(batch, body, Vector3.ZERO, Vector3(0.0, height, 0.0), 0.26, "pole")
	var across: Vector3 = Vector3.UP.cross(direction).normalized()
	var tops: Array[Vector3] = []
	for arm in 2:
		var y: float = height - 0.9 - arm * 2.0
		var reach: float = 2.5 - arm * 0.6
		_cylinder(batch, body, -across * reach + Vector3(0.0, y, 0.0),
			across * reach + Vector3(0.0, y, 0.0), 0.14, "pole")
		for side: float in [-1.0, 1.0]:
			var attach: Vector3 = across * reach * side + Vector3(0.0, y + 0.22, 0.0)
			tops.append(body.position + attach)
			_add_perch(body, attach)
	_finish(body, batch, RANGE_POLE)
	return tops


## Approximates a catenary with a handful of straight segments — enough sag to
## read at a distance, and every segment is something you can land on.
func _wire(from: Vector3, to: Vector3) -> void:
	var midpoint: Vector3 = (from + to) * 0.5
	var body: StaticBody3D = _static_body("Wire", midpoint)
	var batch := GeometryBatch.new()
	var segments: int = 6
	var sag: float = from.distance_to(to) * 0.045
	var previous: Vector3 = from - midpoint
	for i in range(1, segments + 1):
		var t: float = float(i) / float(segments)
		var point: Vector3 = from.lerp(to, t) - midpoint
		point.y -= sag * sin(t * PI)
		_cylinder(batch, body, previous, point, 0.07, "wire")
		previous = point
	_finish(body, batch, RANGE_WIRE)
	_add_perch(body, Vector3(0.0, -sag, 0.0))


# --- rock arches -------------------------------------------------------------

## Big, unmissable holes in the landscape. They give the open half of the map a
## reason to exist and something to aim a dive through. Spread evenly around the
## bowl rather than scattered, so every district owns a few.
func _build_arches() -> void:
	for i in ARCH_COUNT:
		var bearing: float = TAU * float(i) / float(ARCH_COUNT) + rng.randf_range(-0.18, 0.18)
		var radius: float = rng.randf_range(300.0, ARENA_RADIUS - 30.0)
		var base: Vector3 = _district_position(bearing, radius)
		var stone: String = "rock"
		match region_at(base.x, base.z):
			Region.SPIRES:
				stone = "rock_cold"
			Region.GORGE:
				stone = "rock_warm"
			Region.DOWNS:
				stone = "rock_moss"
			_:
				stone = "rock_pale"
		var body: StaticBody3D = _static_body("Arch%d" % i, base, rng.randf() * TAU)
		var batch := GeometryBatch.new()
		var span: float = rng.randf_range(30.0, 58.0)
		var height: float = rng.randf_range(32.0, 62.0)
		var thickness: float = rng.randf_range(4.5, 8.0)

		for side: float in [-1.0, 1.0]:
			_box(
				batch, body,
				Vector3(side * span * 0.5, height * 0.45, 0.0),
				Vector3(thickness, height * 0.9, thickness * 1.5),
				stone
			)
		var pieces: int = 6
		for p in pieces:
			var t: float = (float(p) + 0.5) / float(pieces)
			var x: float = lerpf(-span * 0.5, span * 0.5, t)
			var lift: float = sin(t * PI) * height * 0.14
			_box(
				batch, body,
				Vector3(x, height * 0.9 + lift, 0.0),
				Vector3(span / pieces + 1.2, thickness * 0.85, thickness * 1.5),
				stone,
				Basis(Vector3.FORWARD, (t - 0.5) * 0.55)
			)
		_add_perch(body, Vector3(0.0, height * 1.05, 0.0))
		_finish(body, batch, RANGE_ARCH)


# --- thermals and their tells ------------------------------------------------

## Thermals sit on three rings rather than at random. Soaring is only learnable
## if lift is somewhere you can go back to, and a ring you can follow round the
## bowl is a lesson: leave one core, glide the same radius, find the next.
func _build_thermals() -> void:
	# Spaced so the gap between neighbouring cores stays inside one glide. At the
	# trim glide ratio of about eight, 240 m of crossing costs 30 m of height,
	# which a bird leaving the top of a core can always afford. That is the
	# difference between "thermals exist" and "you can cross the map on lift".
	var rings: Array[Dictionary] = [
		{"radius": 175.0, "count": 6, "ceiling": Vector2(165.0, 215.0)},
		{"radius": 325.0, "count": 10, "ceiling": Vector2(195.0, 250.0)},
		{"radius": 455.0, "count": 13, "ceiling": Vector2(215.0, 275.0)},
		{"radius": 565.0, "count": 15, "ceiling": Vector2(230.0, 300.0)},
	]
	for ring: Dictionary in rings:
		var count: int = ring["count"]
		var radius: float = ring["radius"]
		var ceiling: Vector2 = ring["ceiling"]
		for i in count:
			var angle: float = TAU * float(i) / float(count) + rng.randf_range(-0.22, 0.22)
			var distance: float = radius + rng.randf_range(-45.0, 45.0)
			_thermals.append({
				"centre": Vector2(cos(angle) * distance, sin(angle) * distance),
				"radius": rng.randf_range(38.0, 66.0),
				"strength": rng.randf_range(4.6, 7.8),
				"ceiling": rng.randf_range(ceiling.x, ceiling.y),
			})


## Cloud is the world's only long-range instrument. A flat-bottomed cumulus caps
## every thermal at exactly the height the lift dies, and a ribbon of orographic
## cloud hangs along the rim where the ridge lift is — so a player can see where
## the air goes up before they have any idea what a thermal is.
##
## All of it is batched into eight angular sectors instead of one structure per
## cloud. Cloud is drawn from anywhere in the world, so it can never be frustum
## culled per-puff; eight big meshes cost eight draw calls and cull by sector.
func _build_clouds() -> void:
	var sectors: int = 8
	var bodies: Array[Node3D] = []
	var batches: Array[GeometryBatch] = []
	for i in sectors:
		# Plain nodes, not bodies: cloud is the one thing in this world a bird
		# is meant to fly straight through.
		var body := Node3D.new()
		body.name = "Cloud%d" % i
		add_child(body)
		bodies.append(body)
		batches.append(GeometryBatch.new())

	for thermal: Dictionary in _thermals:
		var centre: Vector2 = thermal["centre"]
		var top: float = thermal["ceiling"]
		var spread: float = thermal["radius"] * 0.85
		var sector: int = _cloud_sector(centre, sectors)
		# A cumulus is one lump with a couple of shoulders, not a swarm. Six
		# small puffs per thermal turned the sky into polka dots.
		var base: float = top + 26.0
		var puffs: int = rng.randi_range(2, 4)
		batches[sector].add(
			_puff_mesh(rng.randf_range(28.0, 44.0)),
			Transform3D(Basis.IDENTITY, Vector3(centre.x, base, centre.y)),
			"cloud"
		)
		for p in puffs:
			var angle: float = rng.randf() * TAU
			var distance: float = spread * rng.randf_range(0.5, 1.0)
			var radius: float = rng.randf_range(14.0, 26.0)
			batches[sector].add(
				_puff_mesh(radius),
				Transform3D(Basis.IDENTITY, Vector3(
					centre.x + cos(angle) * distance,
					base + rng.randf_range(-2.0, 10.0),
					centre.y + sin(angle) * distance
				)),
				"cloud"
			)

	# The rim ribbon: cloud torn along the crest where the air is forced up it.
	# Broken into banks with gaps between, because an unbroken ring reads as a
	# wall of polystyrene and hides the mountains it is supposed to point at.
	var banks: int = 14
	for i in banks:
		var bearing: float = TAU * float(i) / float(banks) + rng.randf_range(-0.10, 0.10)
		var radius: float = RIM_INNER + (RIM_CREST - RIM_INNER) * rng.randf_range(0.35, 0.7)
		var x: float = cos(bearing) * radius
		var z: float = sin(bearing) * radius
		var y: float = height_at(x, z) + rng.randf_range(50.0, 100.0)
		var sector: int = _cloud_sector(Vector2(x, z), sectors)
		var tangent := Vector3(-sin(bearing), 0.0, cos(bearing))
		var puffs: int = rng.randi_range(3, 5)
		for p in puffs:
			var offset: float = rng.randf_range(-70.0, 70.0)
			var radius_puff: float = rng.randf_range(24.0, 44.0)
			batches[sector].add(
				_puff_mesh(radius_puff),
				Transform3D(Basis.IDENTITY, Vector3(x, y, z)
					+ tangent * offset
					+ Vector3(0.0, rng.randf_range(-10.0, 10.0), 0.0)),
				"cloud"
			)

	for i in sectors:
		_finish(bodies[i], batches[i], RANGE_CLOUD, false)


## Flat-bottomed puff. Cumulus has a hard base at the condensation level and a
## lumpy top, and getting that one silhouette right is most of what makes a
## white blob read as weather.
func _puff_mesh(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 1.05
	mesh.radial_segments = 6
	mesh.rings = 3
	mesh.is_hemisphere = true
	return mesh


func _cloud_sector(at: Vector2, sectors: int) -> int:
	var angle: float = fposmod(atan2(at.y, at.x), TAU)
	return clampi(int(angle / TAU * float(sectors)), 0, sectors - 1)
