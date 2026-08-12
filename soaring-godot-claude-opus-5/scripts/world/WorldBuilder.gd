class_name WorldBuilder
extends Node3D

## Procedurally builds the flying grounds: rolling terrain, groves of trees with
## real branches, a town with window ledges, power lines strung between poles,
## rock arches, and the thermals that hold it all together.
##
## Everything is generated from a seed so the world is reproducible — which
## matters because flight tuning is only meaningful if the obstacle course stays
## the same between runs.
##
## Two rules shape all of it:
## [br]1. Geometry is batched per structure (see [GeometryBatch]) so a dense
##    forest stays affordable at 90 Hz per eye.
## [br]2. Anything a bird would plausibly land on gets a collider and a perch
##    point. Anything a bird would brush through — foliage, glass — does not.

const WORLD_RADIUS: float = 640.0
const TERRAIN_EXTENT: float = 1800.0
const TERRAIN_STEPS: int = 120
const HILL_HEIGHT: float = 90.0

const GROVE_COUNT: int = 38
const TREES_PER_GROVE: Vector2i = Vector2i(4, 11)
const BUILDING_COUNT: int = 26
const POWERLINE_RUNS: int = 8
const ARCH_COUNT: int = 10
const THERMAL_COUNT: int = 16

## Standalone headsets get a tighter draw distance and cheaper shadows. Both are
## invisible behind the aerial haze, and both are the difference between 45 and
## 90 frames per second on a Quest.
static var MOBILE: bool = OS.has_feature("mobile") or OS.has_feature("android")

## How far each kind of structure stays drawn. Buildings and arches are
## landmarks you navigate by, so they persist far longer than the trees and
## wires that only matter once you are close enough to hit them.
const RANGE_TREE: float = 380.0
const RANGE_BUILDING: float = 900.0
const RANGE_ARCH: float = 1100.0
const RANGE_POLE: float = 320.0
const RANGE_WIRE: float = 220.0
## Headsets cull closer in. Not as close as the frame budget alone would
## suggest — without a fade, anything too tight pops visibly as you fly at it.
const MOBILE_RANGE_SCALE: float = 0.75

@export var world_seed: int = 20260812

var rng := RandomNumberGenerator.new()
var terrain_noise := FastNoiseLite.new()
var ridge_noise := FastNoiseLite.new()

## Thermals as plain data, sampled per frame rather than modelled as Area3Ds —
## cheaper, and it lets the AI birds ride exactly the same lift the player does.
var _thermals: Array[Dictionary] = []

var _materials: Dictionary = {}
var _built: bool = false

## Places a bird can plausibly perch, published for the AI to aim at.
var perch_points: Array[Vector3] = []


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	rng.seed = world_seed
	_setup_noise()
	_make_materials()
	_build_environment()
	_build_terrain()
	_build_forest()
	_build_town()
	_build_powerlines()
	_build_arches()
	_build_thermals()
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


## Ground height at a world position. Used for terrain, for placing everything
## on it, and by the AI to avoid flying into hillsides.
func height_at(x: float, z: float) -> float:
	var base: float = terrain_noise.get_noise_2d(x, z)
	var ridge: float = 1.0 - absf(ridge_noise.get_noise_2d(x, z))
	var h: float = base * HILL_HEIGHT + ridge * ridge * 26.0 - 18.0

	# Flatten a bowl in the middle so the town and the starting area sit on
	# open, readable ground rather than halfway up a slope.
	var distance: float = Vector2(x, z).length()
	var bowl: float = smoothstep(70.0, 300.0, distance)
	return h * bowl


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
		var radial: float = 1.0 - (distance / radius)
		var vertical: float = clampf(1.0 - position.y / ceiling, 0.0, 1.0)
		lift += thermal["strength"] * radial * radial * vertical

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

## One shared material per surface type. With thousands of primitives in the
## world, per-instance materials would cost more than the geometry.
func _define(name: String, colour: Color, roughness: float = 0.92) -> void:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = roughness
	m.metallic = 0.0
	# Flat, unspecular shading throughout: cheap on a mobile-class headset GPU,
	# and the faceted look reads clearly at the speeds this game is played at.
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_materials[name] = m


func _material(name: String) -> StandardMaterial3D:
	return _materials.get(name, _materials.get("rock"))


func _make_materials() -> void:
	_define("rock", Color(0.46, 0.44, 0.42))
	_define("bark", Color(0.29, 0.21, 0.15))
	_define("leaf", Color(0.20, 0.40, 0.17))
	_define("leaf_deep", Color(0.14, 0.31, 0.14))
	_define("leaf_autumn", Color(0.62, 0.40, 0.13))
	_define("wall", Color(0.74, 0.70, 0.62))
	_define("wall_warm", Color(0.68, 0.46, 0.37))
	_define("wall_pale", Color(0.82, 0.80, 0.76))
	_define("roof", Color(0.34, 0.24, 0.22))
	_define("window", Color(0.30, 0.47, 0.60), 0.12)
	_define("ledge", Color(0.86, 0.84, 0.79))
	_define("pole", Color(0.36, 0.28, 0.22))
	_define("wire", Color(0.10, 0.10, 0.12))

	# The terrain paints itself from vertex colours instead of using a texture.
	var ground := StandardMaterial3D.new()
	ground.vertex_color_use_as_albedo = true
	ground.roughness = 0.98
	ground.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_materials["ground"] = ground


# --- environment -------------------------------------------------------------

func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.20, 0.42, 0.78)
	sky_material.sky_horizon_color = Color(0.68, 0.78, 0.88)
	sky_material.ground_bottom_color = Color(0.22, 0.28, 0.24)
	sky_material.ground_horizon_color = Color(0.68, 0.78, 0.88)
	sky_material.sun_angle_max = 10.0

	var sky := Sky.new()
	sky.sky_material = sky_material
	# The sky never changes, so there is no reason to re-render its radiance
	# every frame. On a headset that is pure waste; bake it once instead.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Low ambient, strong sun: shading is most of what tells you the shape of
	# the ground rushing past, and a flat-lit landscape reads as a blur.
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 2.2
	# Aerial perspective is the main cue for how high and how fast you are, and
	# it is what makes the world read as vast. Tuned to leave the far side of
	# the map visible but hazy — dense enough to feel like air, not like soup.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.70, 0.79, 0.90)
	env.fog_density = 0.00035
	env.fog_sky_affect = 0.12
	env.fog_depth_begin = 90.0
	env.fog_depth_end = 2600.0

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-42.0, -128.0, 0.0)
	sun.light_energy = 1.2
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	# Shadow splits are the single most expensive thing in this scene: each one
	# re-renders every tree in range into the shadow atlas, and this world is
	# mostly trees. A headset gets two shallow splits; a desktop can afford four.
	if MOBILE:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = 110.0
	else:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 260.0
	add_child(sun)


# --- terrain -----------------------------------------------------------------

func _build_terrain() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step: float = TERRAIN_EXTENT / float(TERRAIN_STEPS)
	var origin: float = -TERRAIN_EXTENT * 0.5
	for ix in TERRAIN_STEPS:
		for iz in TERRAIN_STEPS:
			var x0: float = origin + ix * step
			var z0: float = origin + iz * step
			var x1: float = x0 + step
			var z1: float = z0 + step
			var a := Vector3(x0, height_at(x0, z0), z0)
			var b := Vector3(x1, height_at(x1, z0), z0)
			var c := Vector3(x1, height_at(x1, z1), z1)
			var d := Vector3(x0, height_at(x0, z1), z1)
			_add_triangle(surface, a, b, c)
			_add_triangle(surface, a, c, d)

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


## Colours the ground by height and steepness: grass in the valleys, bare rock
## on the cliffs, pale scree on the tops. Free visual variety, and it doubles as
## an altitude cue while flying.
func _ground_colour(point: Vector3, normal_steepness: float) -> Color:
	var grass := Color(0.16, 0.33, 0.13)
	var meadow := Color(0.33, 0.44, 0.16)
	var stone := Color(0.38, 0.35, 0.32)
	var scree := Color(0.58, 0.56, 0.52)

	var altitude: float = clampf((point.y + 20.0) / 110.0, 0.0, 1.0)
	var colour: Color = grass.lerp(meadow, smoothstep(0.15, 0.55, altitude))
	colour = colour.lerp(scree, smoothstep(0.72, 1.0, altitude))
	colour = colour.lerp(stone, smoothstep(0.35, 0.85, normal_steepness))
	return colour


func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	var steepness: float = 1.0 - clampf(absf(normal.y), 0.0, 1.0)
	for vertex: Vector3 in [a, b, c]:
		surface.set_color(_ground_colour(vertex, steepness))
		surface.add_vertex(vertex)


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


func _blob(batch: GeometryBatch, centre: Vector3, radius: float, material: String) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 1.75
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
func _finish(body: StaticBody3D, batch: GeometryBatch, draw_range: float = 0.0) -> void:
	if batch.is_empty():
		return
	var visual := MeshInstance3D.new()
	visual.mesh = batch.commit(_materials)
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


func _scatter_position(min_radius: float, max_radius: float) -> Vector3:
	var angle: float = rng.randf() * TAU
	var radius: float = sqrt(rng.randf()) * (max_radius - min_radius) + min_radius
	var x: float = cos(angle) * radius
	var z: float = sin(angle) * radius
	return Vector3(x, height_at(x, z), z)


func _add_perch(body: StaticBody3D, local: Vector3) -> void:
	perch_points.append(body.global_transform * local)


# --- forest ------------------------------------------------------------------

## Trees come in groves rather than an even scatter, so the map alternates
## between dense slalom country and open air worth diving across. Each tree is
## built branch by branch, because the branches are the point: they are what you
## thread through, clip a wingtip on, and land in.
func _build_forest() -> void:
	for grove in GROVE_COUNT:
		var centre: Vector3 = _scatter_position(70.0, WORLD_RADIUS)
		var spread: float = rng.randf_range(18.0, 46.0)
		var count: int = rng.randi_range(TREES_PER_GROVE.x, TREES_PER_GROVE.y)
		for i in count:
			var angle: float = rng.randf() * TAU
			var distance: float = sqrt(rng.randf()) * spread
			var x: float = centre.x + cos(angle) * distance
			var z: float = centre.z + sin(angle) * distance
			var tree: StaticBody3D = _static_body(
				"Tree%d_%d" % [grove, i], Vector3(x, height_at(x, z), z), rng.randf() * TAU
			)
			_build_tree(tree)


func _build_tree(tree: StaticBody3D) -> void:
	var batch := GeometryBatch.new()
	var height: float = rng.randf_range(18.0, 40.0)
	var trunk_radius: float = height * rng.randf_range(0.024, 0.038)
	_cylinder(batch, tree, Vector3.ZERO, Vector3(0.0, height, 0.0), trunk_radius, "bark")

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
			var tip := Vector3(
				cos(angle) * reach,
				y + reach * rng.randf_range(0.10, 0.38),
				sin(angle) * reach
			)
			_cylinder(batch, tree, Vector3(0.0, y, 0.0), tip, trunk_radius * 0.40, "bark")
			# Foliage gets no collider — leaves should never be the thing that
			# swats a bird out of the air.
			_blob(batch, tip, reach * rng.randf_range(0.30, 0.44), leaf)
			_add_perch(tree, tip)

	_finish(tree, batch, RANGE_TREE)


# --- town --------------------------------------------------------------------

## Buildings exist for their ledges and window sills. A plain box is a wall you
## avoid; a box with a sill under every window is somewhere to thread, land and
## kick off from.
func _build_town() -> void:
	for i in BUILDING_COUNT:
		var base: Vector3 = _scatter_position(35.0, 260.0)
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


# --- power lines -------------------------------------------------------------

## The classic bird furniture: a long wire to land on in a row, with poles to
## weave between.
func _build_powerlines() -> void:
	for run in POWERLINE_RUNS:
		var start: Vector3 = _scatter_position(70.0, WORLD_RADIUS * 0.85)
		var heading: float = rng.randf() * TAU
		var direction := Vector3(cos(heading), 0.0, sin(heading))
		var spacing: float = rng.randf_range(40.0, 56.0)
		var poles: int = rng.randi_range(5, 8)
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
## reason to exist and something to aim a dive through.
func _build_arches() -> void:
	for i in ARCH_COUNT:
		var base: Vector3 = _scatter_position(220.0, WORLD_RADIUS)
		var body: StaticBody3D = _static_body("Arch%d" % i, base, rng.randf() * TAU)
		var batch := GeometryBatch.new()
		var span: float = rng.randf_range(28.0, 52.0)
		var height: float = rng.randf_range(30.0, 56.0)
		var thickness: float = rng.randf_range(4.5, 8.0)

		for side: float in [-1.0, 1.0]:
			_box(
				batch, body,
				Vector3(side * span * 0.5, height * 0.45, 0.0),
				Vector3(thickness, height * 0.9, thickness * 1.5),
				"rock"
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
				"rock",
				Basis(Vector3.FORWARD, (t - 0.5) * 0.55)
			)
		_add_perch(body, Vector3(0.0, height * 1.05, 0.0))
		_finish(body, batch, RANGE_ARCH)


# --- thermals ----------------------------------------------------------------

func _build_thermals() -> void:
	for i in THERMAL_COUNT:
		var spot: Vector3 = _scatter_position(70.0, WORLD_RADIUS)
		_thermals.append({
			"centre": Vector2(spot.x, spot.z),
			"radius": rng.randf_range(30.0, 60.0),
			"strength": rng.randf_range(3.4, 6.2),
			"ceiling": rng.randf_range(170.0, 300.0),
		})
