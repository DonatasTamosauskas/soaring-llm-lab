extends Node3D
## Procedural, collision-aware low-poly flight playground. Geometry is built once
## into vertex-colored batches; transparent water and repeated crowns use their
## own tiny draw batches. Static collisions use the same triangles as structures.

const WORLD_RADIUS := 205.0
const FLIGHT_CEILING := 120.0

var flight_bounds := AABB(Vector3(-180, 3, -180), Vector3(360, 102, 360))
const GROUND_STEP := 8.0
const PALETTE := {
	"grass": Color("73a995"), "grass_light": Color("94b7a2"),
	"soil": Color("bcaa80"), "sand": Color("dfcfaa"),
	"rock": Color("9b9a89"), "rock_light": Color("c6baa0"),
	"cream": Color("f1debd"), "ochre": Color("df9b54"),
	"coral": Color("d88670"), "blue": Color("609fba"),
	"sage": Color("88aa95"), "teal": Color("327c77"),
	"dark": Color("3b5656"), "bark": Color("89785c"),
	"leaf": Color("438c7c"), "leaf_light": Color("72b295"),
	"gold": Color("ffd996"), "white": Color("fff0d3")
}

var spawn_position: Vector3 = Vector3(0.0, 18.0, 64.0)
var thermals: Array = []
var perch_points: Array[Vector3] = []
var waypoints: Array[Vector3] = []
var zones: Array = []
var window_probes: Array = []
var route_rings: Array = []
var landing_rings: Array = []
var feature_stats: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _collision_vertices := PackedVector3Array()
var _accent_vertices := PackedVector3Array()
var _accent_normals := PackedVector3Array()
var _accent_colors := PackedColorArray()
var _water_vertices := PackedVector3Array()
var _water_normals := PackedVector3Array()
var _water_colors := PackedColorArray()
var _thermal_markers: Array[Node3D] = [] # Empty compatibility list; thermal cues are in the static marker batch.
var _built := false
var _opaque_mesh: MeshInstance3D
var _feature_counts := {"trees": 0, "branches": 0, "buildings": 0, "windows": 0,
	"utility_poles": 0, "nest_entrances": 0, "arches": 0, "thermal_columns": 0,
	"routes": 0, "perches": 0, "cloud_clusters": 0}

func _ready() -> void:
	build_world()

func build_world() -> void:
	if _built:
		return
	_built = true
	name = "AerieValley"
	_rng.seed = 406173
	_noise.seed = 8128
	_noise.frequency = 0.012
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_define_zones()
	_build_terrain()
	_build_river()
	_build_launch_aerie()
	_build_grove()
	_build_neighborhood()
	_build_utilities()
	_build_observatory()
	_build_sea_arches()
	_build_nest_cliffs()
	_build_mountains()
	_build_thermals()
	_build_routes()
	_flush_geometry()
	_build_clouds()
	feature_stats = _feature_counts.duplicate()
	feature_stats["opaque_triangles"] = _vertices.size() / 3
	feature_stats["collision_triangles"] = _collision_vertices.size() / 3
	feature_stats["draw_batches"] = 5
	feature_stats["perches"] = perch_points.size()
	# Thermal currents use stable gold spiral segments, ground arrows and
	# rings. Tiny leaf rendering is deliberately absent: it caused magenta
	# tile corruption in actual simulator Mobile/Vulkan stereo output.
	set_process(false)

func _define_zones() -> void:
	zones = [
		{"name": "Launch Aerie", "center": Vector3(0, 18, 64), "radius": 27.0},
		{"name": "Willow Canopy", "center": Vector3(68, 18, 12), "radius": 46.0},
		{"name": "Sunrise Quarter", "center": Vector3(-72, 20, -45), "radius": 59.0},
		{"name": "Windward Observatory", "center": Vector3(-124, 25, 61), "radius": 35.0},
		{"name": "The Needle Arches", "center": Vector3(100, 16, -95), "radius": 41.0},
		{"name": "Swallow Cliffs", "center": Vector3(-27, 26, -134), "radius": 38.0},
		{"name": "Silverwater", "center": Vector3(22, 8, -7), "radius": 32.0}
	]

func thermal_at(pos: Vector3) -> float:
	var lift := 0.0
	for thermal in thermals:
		var center: Vector3 = thermal["center"]
		var bottom: float = thermal["bottom"]
		var top: float = thermal["height"]
		if pos.y < bottom or pos.y > top:
			continue
		var radius: float = thermal["radius"]
		var d := Vector2(pos.x - center.x, pos.z - center.z).length()
		if d >= radius:
			continue
		# A broad easy-to-find core, smooth falloff, and no invisible lift above it.
		var edge := smoothstep(radius, radius * 0.45, d)
		var vertical := smoothstep(bottom, bottom + 2.0, pos.y) * smoothstep(top, top - 7.0, pos.y)
		lift += float(thermal["strength"]) * edge * vertical
	return minf(lift, 10.0)

func zone_at(pos: Vector3) -> String:
	var best := INF
	var result := "The Open Sky"
	for zone in zones:
		var center: Vector3 = zone["center"]
		var d := Vector2(pos.x - center.x, pos.z - center.z).length()
		if d < float(zone["radius"]) and d < best:
			best = d
			result = zone["name"]
	return result

func get_world_stats() -> Dictionary:
	var stats := feature_stats.duplicate(true)
	stats["radius"] = WORLD_RADIUS
	stats["ceiling"] = FLIGHT_CEILING
	stats["flight_bounds"] = flight_bounds
	stats["spawn_position"] = spawn_position
	stats["thermal_count"] = thermals.size()
	stats["waypoint_count"] = waypoints.size()
	stats["window_probes"] = window_probes.duplicate(true)
	stats["route_rings"] = route_rings.duplicate(true)
	stats["camera_presets"] = [
		{"name": "launch", "position": Vector3(0, 20, 68), "look_at": Vector3(-8, 22, -20)},
		{"name": "valley", "position": Vector3(104, 79, 117), "look_at": Vector3(-18, 16, -20)},
		{"name": "quarter", "position": Vector3(-5, 46, 15), "look_at": Vector3(-78, 28, -44)},
		{"name": "canopy", "position": Vector3(106, 34, 63), "look_at": Vector3(62, 20, 2)},
		{"name": "arches", "position": Vector3(154, 38, -35), "look_at": Vector3(100, 21, -96)},
		{"name": "observatory", "position": Vector3(-75, 45, 96), "look_at": Vector3(-128, 28, 53)}
	]
	return stats

func terrain_height(x: float, z: float) -> float:
	var river_x := _river_x(z)
	var river_d := absf(x - river_x)
	var h := _noise.get_noise_2d(x, z) * 4.8 + 0.4
	# River valley floor remains below the water, with gently raised banks.
	h -= 4.5 * exp(-pow(river_d / 14.0, 2.0))
	# A level neighborhood makes fly-through apertures predictable.
	var town_blend := 1.0 - smoothstep(48.0, 73.0, Vector2(x + 72, z + 45).length())
	h = lerpf(h, 1.0, town_blend)
	# Outer rim is hilly; the uncluttered valley remains a large playable volume.
	var distance := Vector2(x, z).length()
	h += smoothstep(158.0, 224.0, distance) * 13.0
	if x > 122.0:
		h = lerpf(h, -4.5, smoothstep(122.0, 164.0, x))
	return h

func _river_x(z: float) -> float:
	return 22.0 + sin(z * 0.014) * 16.0 + sin(z * 0.035) * 4.0

func _build_terrain() -> void:
	for ix in range(-28, 28):
		for iz in range(-28, 28):
			var x := ix * GROUND_STEP
			var z := iz * GROUND_STEP
			var a := Vector3(x, terrain_height(x, z), z)
			var b := Vector3(x + GROUND_STEP, terrain_height(x + GROUND_STEP, z), z)
			var c := Vector3(x + GROUND_STEP, terrain_height(x + GROUND_STEP, z + GROUND_STEP), z + GROUND_STEP)
			var d := Vector3(x, terrain_height(x, z + GROUND_STEP), z + GROUND_STEP)
			var height := (a.y + b.y + c.y + d.y) * 0.25
			var shade := _rng.randf_range(-0.025, 0.025)
			var color: Color = PALETTE["grass"]
			if absf(x - _river_x(z)) < 18.0 or x > 112.0:
				color = PALETTE["sand"]
			elif height > 7.0:
				color = PALETTE["rock"]
			elif _noise.get_noise_2d(x * 3.0, z * 3.0) > 0.15:
				color = PALETTE["grass_light"]
			color = color.lightened(shade)
			_triangle(a, d, c, color)
			_triangle(a, c, b, color.darkened(0.012))
	# Long grasses create texture around accessible landing areas without collision.
	for i in range(260):
		var p := Vector3(_rng.randf_range(-155, 121), 0, _rng.randf_range(-150, 150))
		if absf(p.x - _river_x(p.z)) < 20:
			continue
		p.y = terrain_height(p.x, p.z)
		var height := _rng.randf_range(0.35, 0.8)
		var color: Color = PALETTE["grass_light"].lightened(0.1)
		_triangle(p + Vector3(-0.22, 0, 0), p + Vector3(0, height, 0), p + Vector3(0.22, 0, 0), color, false)
		_triangle(p + Vector3(0, 0, -0.2), p + Vector3(0, height * 0.8, 0), p + Vector3(0, 0, 0.2), color, false)

func _build_river() -> void:
	var color := Color("58a8ae")
	for i in range(88):
		var z := -220.0 + i * 5.0
		var x := _river_x(z)
		var nx := _river_x(z + 5)
		var w := 6.5 + sin(z * 0.036) * 1.6
		var nw := 6.5 + sin((z + 5) * 0.036) * 1.6
		var a := Vector3(x - w, -1.0, z)
		var b := Vector3(x + w, -1.0, z)
		var c := Vector3(nx + nw, -1.0, z + 5)
		var d := Vector3(nx - nw, -1.0, z + 5)
		_water_triangle(a, d, c, color)
		_water_triangle(a, c, b, color.lightened(0.025))
	# A calm coastal water plane catches the warm sky with cheap opaque shading.
	_water_triangle(Vector3(129, -1.15, -225), Vector3(129, -1.15, 225), Vector3(390, -1.15, 225), Color("5caaad"))
	_water_triangle(Vector3(129, -1.15, -225), Vector3(390, -1.15, 225), Vector3(390, -1.15, -225), Color("5caaad"))
	# Small bright wave strokes use geometry, avoiding depth sampling on XR GPUs.
	for i in range(65):
		var p := Vector3(_rng.randf_range(138, 218), -1.08, _rng.randf_range(-190, 190))
		_box(p, Vector3(_rng.randf_range(1.5, 4.5), 0.018, 0.08), Color("90c9c2"), false)
	# Two open footbridges double as under/over flight choices.
	for bridge_z in [-23.0, 91.0]:
		var cx := _river_x(bridge_z)
		_box(Vector3(cx, 3.25, bridge_z), Vector3(21, 0.7, 4.5), PALETTE["bark"])
		for end_x in [cx - 9.5, cx + 9.5]:
			_box(Vector3(end_x, 0.6, bridge_z), Vector3(1.2, 5, 1.1), PALETTE["dark"])
		for dz in [-2.1, 2.1]:
			_box(Vector3(cx, 4.35, bridge_z + dz), Vector3(21, 0.18, 0.18), PALETTE["cream"])
			for post_x in [-9.8, -5.0, 0.0, 5.0, 9.8]:
				_box(Vector3(cx + post_x, 3.95, bridge_z + dz), Vector3(0.16, 1.4, 0.16), PALETTE["cream"])
		perch_points.append(Vector3(cx, 4.65, bridge_z + 2.1))

func _build_launch_aerie() -> void:
	# A sandstone outcrop, open crescent nest, broad launch deck and clear sightline.
	var center := Vector3(0, 0, 66)
	_cylinder(center + Vector3(0, 7.0, 0), 9.0, 7.0, 14.0, 9, PALETTE["rock_light"])
	_cylinder(center + Vector3(0, 14.8, 0), 8.0, 9.0, 2.0, 10, PALETTE["sand"])
	_box(Vector3(0, 16.2, 65), Vector3(15.0, 0.7, 12.0), PALETTE["cream"])
	_box(Vector3(0, 16.57, 65), Vector3(13.8, 0.05, 10.8), PALETTE["ochre"], false)
	# Half-ring leaves the front fully open; low rim keeps the nest visible in VR.
	for i in range(14):
		var a := deg_to_rad(5.0 + i * 12.3)
		var p := Vector3(cos(a) * 6.4, 17.1, 67.0 + sin(a) * 4.9)
		_box(p, Vector3(1.4, 1.0, 0.58), PALETTE["bark"].lightened(float(i % 3) * 0.07), true, -a)
		_box(p + Vector3(0, 0.48, 0), Vector3(1.75, 0.25, 0.45), PALETTE["gold"], false, -a)
	# Warm route marker in front: open ring is decorative, not a collider.
	_ring(Vector3(0, 16.65, 61), 2.5, 0.045, PALETTE["white"], Vector3.UP)
	landing_rings.append({"center": Vector3(0, 16.7, 64), "radius": 2.5, "name": "Home"})
	perch_points.append(Vector3(-5.5, 17.8, 68))
	perch_points.append(Vector3(5.5, 17.8, 68))
	waypoints.append(Vector3(0, 23, 43))
	# A three-feather crest provides a recognizable start landmark from the sky.
	for i in range(3):
		var p := Vector3(-5.0 + i * 0.95, 20.0, 70.8)
		_feather(p, Vector3(0.32, 0.94, -0.1), 2.7 + i * 0.5, PALETTE["gold"])
	_feature_counts["nest_entrances"] += 1

func _build_grove() -> void:
	var positions := [
		Vector3(58, 0, 5), Vector3(77, 0, 6), Vector3(53, 0, 28),
		Vector3(82, 0, 32), Vector3(63, 0, -18), Vector3(92, 0, -12),
		Vector3(48, 0, -33), Vector3(98, 0, 13), Vector3(73, 0, 51),
		Vector3(104, 0, 46), Vector3(47, 0, 55), Vector3(85, 0, -39)
	]
	var crown_transforms: Array[Transform3D] = []
	var crown_colors: Array[Color] = []
	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		p.y = maxf(terrain_height(p.x, p.z), 0.0)
		var h := 19.0 + float((i * 7) % 12)
		var trunk_radius := 1.1 + float(i % 3) * 0.25
		_cylinder(p + Vector3(0, h * 0.5, 0), trunk_radius, trunk_radius * 0.58, h, 7, PALETTE["bark"])
		_cylinder(p + Vector3(0, 0.6, 0), trunk_radius * 1.65, trunk_radius, 1.2, 7, PALETTE["bark"].darkened(0.08))
		_feature_counts["trees"] += 1
		for tier in range(3):
			var tier_y := h * (0.46 + tier * 0.18)
			for arm in range(3):
				var angle := float(arm) * TAU / 3 + float(tier) * 0.65 + i * 0.63
				var reach := 5.0 + _rng.randf() * 3.2 - tier * 0.7
				var start := p + Vector3(0, tier_y, 0)
				var end := start + Vector3(cos(angle) * reach, 1.7 + tier * 0.3, sin(angle) * reach)
				_branch(start, end, 0.42 - tier * 0.07, PALETTE["bark"])
				perch_points.append(end + Vector3(0, 0.65, 0))
				_feature_counts["branches"] += 1
				# Open gaps beneath detached crowns remain physically flyable.
				var leaf_center := end + Vector3(0, 3.0 + tier * 0.2, 0)
				var scale := Vector3(4.0 + _rng.randf(), 2.7 + _rng.randf(), 4.4 + _rng.randf())
				crown_transforms.append(Transform3D(Basis().scaled(scale), leaf_center))
				crown_colors.append(PALETTE["leaf"].lightened(float((i + tier + arm) % 4) * 0.075))
				if tier == 1 and arm == 0 and i % 3 == 0:
					_small_nest(end + Vector3(0, 0.7, 0), 1.35)
		var tip := p + Vector3(0, h + 1.0, 0)
		crown_transforms.append(Transform3D(Basis().scaled(Vector3(5.4, 4.2, 5.4)), tip))
		crown_colors.append(PALETTE["leaf_light"])
		waypoints.append(p + Vector3(0, h + 8, 0))
	_add_multimesh("CanopyCrowns", _make_faceted_sphere(8, 4), crown_transforms, crown_colors, true)
	# Smaller edge vegetation defines the grove without filling its flying lanes.
	for i in range(24):
		var a := float(i) * TAU / 24
		var p := Vector3(76 + cos(a) * 36, 0, 14 + sin(a) * 50)
		if p.x < 43:
			continue
		p.y = terrain_height(p.x, p.z)
		_cylinder(p + Vector3(0, 2.4, 0), 0.4, 0.24, 4.8, 5, PALETTE["bark"])
		_poly_bush(p + Vector3(0, 5.5, 0), Vector3(3.0, 2.2, 3.0), PALETTE["leaf_light"])

func _build_neighborhood() -> void:
	# A legible street grid with multiple elevation bands, warm roof terraces,
	# and genuinely hollow buildings. Every window has matching collision gaps.
	var buildings := [
		{"p": Vector3(-58, 1, -30), "w": 16.0, "d": 15.0, "h": 29.0, "color": "cream", "yaw": 0.0},
		{"p": Vector3(-86, 1, -24), "w": 18.0, "d": 16.0, "h": 42.0, "color": "coral", "yaw": 0.0},
		{"p": Vector3(-58, 1, -61), "w": 18.0, "d": 16.0, "h": 48.0, "color": "blue", "yaw": 0.0},
		{"p": Vector3(-89, 1, -59), "w": 19.0, "d": 18.0, "h": 34.0, "color": "ochre", "yaw": 0.0},
		{"p": Vector3(-117, 1, -44), "w": 15.0, "d": 16.0, "h": 23.0, "color": "sage", "yaw": 0.0},
		{"p": Vector3(-32, 1, -58), "w": 13.0, "d": 15.0, "h": 21.0, "color": "cream", "yaw": 0.0},
		{"p": Vector3(-78, 1, -92), "w": 18.0, "d": 15.0, "h": 55.0, "color": "cream", "yaw": 0.0},
		{"p": Vector3(-111, 1, -86), "w": 16.0, "d": 14.0, "h": 30.0, "color": "blue", "yaw": 0.0}
	]
	# Pavement has visual presence but tiny elevation so it never becomes a trap.
	_box(Vector3(-75, 1.05, -53), Vector3(110, 0.12, 100), Color("a9b6a5"))
	_box(Vector3(-74, 1.14, -44), Vector3(100, 0.07, 6), Color("c6c7b1"), false)
	_box(Vector3(-74, 1.14, -80), Vector3(100, 0.07, 5), Color("c6c7b1"), false)
	_box(Vector3(-73, 1.16, -52), Vector3(5, 0.07, 102), Color("c6c7b1"), false)
	for data in buildings:
		_hollow_building(data["p"], data["w"], data["d"], data["h"], PALETTE[data["color"]])
	# Open elevated sky bridge: its underside and sides are clear flight routes.
	_box(Vector3(-73, 21.8, -31), Vector3(16, 0.65, 3.2), PALETTE["cream"])
	for dz in [-1.52, 1.52]:
		_box(Vector3(-73, 22.7, -31 + dz), Vector3(16, 0.18, 0.14), PALETTE["dark"])
		for x in [-79.5, -73.0, -66.5]:
			_box(Vector3(x, 22.25, -31 + dz), Vector3(0.14, 0.9, 0.14), PALETTE["dark"])
	perch_points.append(Vector3(-73, 23.1, -29.5))
	# Courtyard fountain and market canopy supply human scale and low routes.
	_cylinder(Vector3(-74, 1.6, -44), 3.4, 3.4, 1.0, 12, PALETTE["cream"])
	_cylinder(Vector3(-74, 2.6, -44), 0.45, 0.45, 2.0, 8, PALETTE["dark"])
	_cylinder(Vector3(-74, 3.5, -44), 1.6, 1.8, 0.25, 12, PALETTE["blue"])
	for i in range(5):
		var p := Vector3(-41, 1.25, -23 - i * 6)
		for dx in [-2.5, 2.5]:
			_box(p + Vector3(dx, 2.2, 0), Vector3(0.16, 4.4, 0.16), PALETTE["dark"])
		_box(p + Vector3(0, 4.5, 0), Vector3(5.5, 0.22, 4), PALETTE["coral"] if i % 2 == 0 else PALETTE["cream"])
	# Trees at the quarter's edge are slender, leaving its windows easy to see.
	for p in [Vector3(-25, 1, -28), Vector3(-129, 1, -63), Vector3(-38, 1, -82)]:
		_cylinder(p + Vector3(0, 5, 0), 0.5, 0.3, 10, 6, PALETTE["bark"])
		_poly_bush(p + Vector3(0, 11, 0), Vector3(4.5, 4, 4.5), PALETTE["leaf"])
		perch_points.append(p + Vector3(0, 15.2, 0))

func _hollow_building(p: Vector3, width: float, depth: float, height: float, color: Color) -> void:
	_feature_counts["buildings"] += 1
	var thickness := 0.55
	var floor_count := maxi(2, int(height / 7.0))
	var story_height := height / floor_count
	var opening_width := minf(4.5, width * 0.29)
	var opening_height := 3.7
	var half_w := width * 0.5
	var half_d := depth * 0.5
	# Interior floor slabs have large central atrium cutouts. A bird can enter
	# a facade window, cross the atrium, climb and leave through another story.
	for story in range(floor_count):
		var floor_y := p.y + story * story_height
		var opening_y := floor_y + story_height * 0.53
		var low_h := opening_y - opening_height * 0.5 - floor_y
		var high_h := floor_y + story_height - opening_y - opening_height * 0.5
		# Front/back: two windows on every floor separated by a central pier.
		for z_side in [-half_d, half_d]:
			var wall_z: float = p.z + z_side
			_box(Vector3(p.x, floor_y + low_h * 0.5, wall_z), Vector3(width, low_h, thickness), color)
			_box(Vector3(p.x, floor_y + story_height - high_h * 0.5, wall_z), Vector3(width, high_h, thickness), color)
			var window_xs := [-width * 0.26, width * 0.26]
			var cursor := -half_w
			for wx in window_xs:
				var left: float = wx - opening_width * 0.5
				var right: float = wx + opening_width * 0.5
				if left > cursor:
					_box(Vector3(p.x + (cursor + left) * 0.5, opening_y, wall_z), Vector3(left - cursor, opening_height, thickness), color)
				_window_frame(Vector3(p.x + wx, opening_y, wall_z), opening_width, opening_height, false)
				cursor = right
				_feature_counts["windows"] += 1
				if z_side > 0.0 and story == 1:
					window_probes.append({
						"name": "Quarter window %d" % _feature_counts["buildings"],
						"outside": Vector3(p.x + wx, opening_y, wall_z + 2.0),
						"inside": Vector3(p.x + wx, opening_y, wall_z - 2.0),
						"wall_outside": Vector3(p.x, opening_y, wall_z + 2.0),
						"wall_inside": Vector3(p.x, opening_y, wall_z - 2.0),
						"clear_width": opening_width - 0.24, "clear_height": opening_height - 0.24})
					waypoints.append(Vector3(p.x + wx, opening_y, wall_z + 5.0))
			if cursor < half_w:
				_box(Vector3(p.x + (cursor + half_w) * 0.5, opening_y, wall_z), Vector3(half_w - cursor, opening_height, thickness), color)
		# Side façades: one broad open window, with colorful shutters at the edge.
		for x_side in [-half_w, half_w]:
			var wall_x: float = p.x + x_side
			_box(Vector3(wall_x, floor_y + low_h * 0.5, p.z), Vector3(thickness, low_h, depth), color)
			_box(Vector3(wall_x, floor_y + story_height - high_h * 0.5, p.z), Vector3(thickness, high_h, depth), color)
			var side_opening := 4.6
			var pier := (depth - side_opening) * 0.5
			for dz in [-side_opening * 0.5 - pier * 0.5, side_opening * 0.5 + pier * 0.5]:
				_box(Vector3(wall_x, opening_y, p.z + dz), Vector3(thickness, opening_height, pier), color)
			_window_frame(Vector3(wall_x, opening_y, p.z), side_opening, opening_height, true)
			_feature_counts["windows"] += 1
		if story > 0:
			# Walkways around the interior leave an 8m vertical atrium.
			var slab_depth := 2.3
			for dz in [-half_d + slab_depth * 0.5, half_d - slab_depth * 0.5]:
				_box(Vector3(p.x, floor_y, p.z + dz), Vector3(width, 0.3, slab_depth), color.darkened(0.13))
			for dx in [-half_w + slab_depth * 0.5, half_w - slab_depth * 0.5]:
				_box(Vector3(p.x + dx, floor_y, p.z), Vector3(slab_depth, 0.3, depth - slab_depth * 2), color.darkened(0.13))
	# Flat accessible rooftop, a striped fascia and low parapets with corner gaps.
	var roof_y := p.y + height
	_box(Vector3(p.x, roof_y, p.z), Vector3(width + 0.9, 0.8, depth + 0.9), color.lightened(0.1))
	for z_side in [-half_d - 0.4, half_d + 0.4]:
		_box(Vector3(p.x, roof_y - 0.9, p.z + z_side), Vector3(width + 1.2, 0.35, 0.25), PALETTE["cream"])
		_box(Vector3(p.x, roof_y + 1.0, p.z + z_side), Vector3(width - 3.0, 1.2, 0.3), color)
	for x_side in [-half_w - 0.4, half_w + 0.4]:
		_box(Vector3(p.x + x_side, roof_y + 1.0, p.z), Vector3(0.3, 1.2, depth - 3.0), color)
	# Roof furniture is sparse and provides both cover and perching choices.
	_box(Vector3(p.x - width * 0.25, roof_y + 1.4, p.z + 1), Vector3(2.4, 2.0, 2.3), PALETTE["teal"])
	_box(Vector3(p.x - width * 0.25, roof_y + 2.5, p.z + 1), Vector3(2.8, 0.25, 2.7), PALETTE["cream"])
	var landing := Vector3(p.x + width * 0.18, roof_y + 0.45, p.z)
	_ring(landing, 2.1, 0.055, PALETTE["gold"], Vector3.UP)
	landing_rings.append({"center": landing, "radius": 2.1, "name": "Roof terrace"})
	perch_points.append(landing + Vector3(0, 0.25, 0))
	perch_points.append(Vector3(p.x, roof_y + 1.9, p.z + half_d + 0.4))
	waypoints.append(Vector3(p.x, roof_y + 6.5, p.z))
	if height > 40:
		_branch(Vector3(p.x + 3.5, roof_y + 0.5, p.z - 3), Vector3(p.x + 3.5, roof_y + 7, p.z - 3), 0.13, PALETTE["dark"])
		_branch(Vector3(p.x + 0.5, roof_y + 5.5, p.z - 3), Vector3(p.x + 6.5, roof_y + 5.5, p.z - 3), 0.07, PALETTE["dark"])
		perch_points.append(Vector3(p.x + 3.5, roof_y + 7.2, p.z - 3))

func _window_frame(p: Vector3, width: float, height: float, sideways: bool) -> void:
	var color: Color = PALETTE["cream"]
	var inset := 0.12
	if not sideways:
		for dx in [-width * 0.5 + inset * 0.5, width * 0.5 - inset * 0.5]:
			_box(p + Vector3(dx, 0, 0), Vector3(inset, height, 0.7), color)
		for dy in [-height * 0.5 + inset * 0.5, height * 0.5 - inset * 0.5]:
			_box(p + Vector3(0, dy, 0), Vector3(width, inset, 0.7), color)
		_box(p + Vector3(0, -height * 0.5 - 0.14, 0.3), Vector3(width + 0.6, 0.16, 1.05), color)
	else:
		for dz in [-width * 0.5 + inset * 0.5, width * 0.5 - inset * 0.5]:
			_box(p + Vector3(0, 0, dz), Vector3(0.7, height, inset), color)
		for dy in [-height * 0.5 + inset * 0.5, height * 0.5 - inset * 0.5]:
			_box(p + Vector3(0, dy, 0), Vector3(0.7, inset, width), color)

func _build_utilities() -> void:
	var pole_positions := [Vector3(-13, 0, 25), Vector3(-15, 0, -4), Vector3(-17, 0, -35),
		Vector3(-21, 0, -67), Vector3(-20, 0, -99), Vector3(-46, 0, 31), Vector3(-78, 0, 37)]
	for i in range(pole_positions.size()):
		var p: Vector3 = pole_positions[i]
		p.y = terrain_height(p.x, p.z)
		var h := 14.0 + (i % 3) * 1.8
		_cylinder(p + Vector3(0, h * 0.5, 0), 0.4, 0.26, h, 6, PALETTE["bark"])
		_box(p + Vector3(0, h - 0.6, 0), Vector3(5.0, 0.24, 0.25), PALETTE["dark"])
		for dx in [-2.05, 0, 2.05]:
			_cylinder(p + Vector3(dx, h - 0.2, 0), 0.19, 0.16, 0.6, 6, PALETTE["cream"])
		perch_points.append(p + Vector3(0, h + 0.2, 0))
		_feature_counts["utility_poles"] += 1
		if i > 0 and i != 5:
			var previous: Vector3 = pole_positions[i - 1]
			previous.y = terrain_height(previous.x, previous.z)
			var ph := 14.0 + ((i - 1) % 3) * 1.8
			for dx in [-2.05, 2.05]:
				var start := previous + Vector3(dx, ph, 0)
				var end := p + Vector3(dx, h, 0)
				for segment in range(8):
					var t0 := float(segment) / 8
					var t1 := float(segment + 1) / 8
					var a := start.lerp(end, t0) + Vector3(0, -sin(t0 * PI) * 1.4, 0)
					var b := start.lerp(end, t1) + Vector3(0, -sin(t1 * PI) * 1.4, 0)
					_branch(a, b, 0.07, PALETTE["dark"], true)
				perch_points.append(start.lerp(end, 0.5) + Vector3(0, -1.25, 0))
	# Wind banners make thermal proximity and flight direction visually intuitive.
	for p in [Vector3(-11, 15, 25), Vector3(45, 13, 66), Vector3(-105, 31, 51)]:
		_branch(p - Vector3(0, 4, 0), p, 0.08, PALETTE["cream"])
		_triangle(p, p + Vector3(3.3, -0.7, 0.9), p + Vector3(0, -1.5, 0), PALETTE["ochre"], false)

func _build_observatory() -> void:
	var p := Vector3(-127, 0, 58)
	var ground := terrain_height(p.x, p.z)
	p.y = ground
	_cylinder(p + Vector3(0, 3.0, 0), 18.0, 14.0, 6.0, 10, PALETTE["rock_light"])
	_cylinder(p + Vector3(0, 7.0, 0), 11.0, 11.0, 2.0, 10, PALETTE["cream"])
	# Polygonal tower is hollow at the sky gallery: eight supports and a ring roof.
	_cylinder(p + Vector3(0, 17.0, 0), 6.6, 5.3, 20.0, 10, PALETTE["cream"])
	_cylinder(p + Vector3(0, 28.0, 0), 6.0, 6.0, 2.0, 10, PALETTE["ochre"])
	for i in range(8):
		var angle := i * TAU / 8
		var support := p + Vector3(cos(angle) * 5.7, 32.0, sin(angle) * 5.7)
		_box(support, Vector3(0.55, 6.0, 0.55), PALETTE["cream"], true, angle)
	_cylinder(p + Vector3(0, 35.4, 0), 7.2, 7.2, 0.8, 10, PALETTE["teal"])
	_cylinder(p + Vector3(0, 37.8, 0), 7.6, 0.8, 4.0, 10, PALETTE["teal"])
	_cylinder(p + Vector3(0, 41.0, 0), 0.22, 0.15, 3.0, 6, PALETTE["ochre"])
	# Bright golden telescope and wide balcony orient the player toward the valley.
	_branch(p + Vector3(0, 30.8, 0), p + Vector3(4.8, 32.0, -2), 0.62, PALETTE["gold"])
	_cylinder(p + Vector3(0, 30.2, 0), 0.23, 0.23, 2.5, 6, PALETTE["dark"])
	for i in range(10):
		var angle := i * TAU / 10
		var at := p + Vector3(cos(angle) * 7.5, 28.2, sin(angle) * 7.5)
		_box(at, Vector3(1.2, 0.5, 0.45), PALETTE["gold"], true, -angle)
		perch_points.append(at + Vector3(0, 0.55, 0))
	perch_points.append(p + Vector3(0, 42.7, 0))
	waypoints.append(p + Vector3(0, 43, 0))
	waypoints.append(p + Vector3(9, 32, 0))
	_ring(p + Vector3(0, 8.05, 0), 4.5, 0.07, PALETTE["gold"], Vector3.UP)
	# A descending switchback walk adds grounded structure under the flight paths.
	for i in range(10):
		_box(p + Vector3(15 + i * 1.5, 5.8 - i * 0.6, 6), Vector3(2.2, 0.6, 4.0), PALETTE["sand"])

func _build_sea_arches() -> void:
	# Procedural lintel arches are physically open: no bounding cube through holes.
	for i in range(3):
		var p := Vector3(93 + i * 16, 0, -94 - i * 10)
		var radius := 7.0 - i * 0.7
		var arch_height := 17.0 + i * 3.5
		var thickness := 3.0 - i * 0.2
		var ground := terrain_height(p.x, p.z)
		p.y = maxf(ground, -1.0)
		for side in [-1.0, 1.0]:
			var leg := p + Vector3(side * (radius + thickness * 0.5), arch_height * 0.4, 0)
			_box(leg, Vector3(thickness, arch_height * 0.8, 4.0), PALETTE["rock_light"], true, deg_to_rad(-7 * side))
			_cylinder(p + Vector3(side * (radius + thickness * 0.5), 1.0, 0), 4.2, 2.8, 2.0, 6, PALETTE["rock"])
		# Upper semicircular ring assembled as trapezoidal prisms with no invisible fill.
		for segment in range(10):
			var a := PI * float(segment) / 10
			var b := PI * float(segment + 1) / 10
			var origin := p + Vector3(0, arch_height * 0.72, 0)
			_arch_wedge(origin, radius, radius + thickness, a, b, 4.0, PALETTE["rock_light"].lightened(0.02 * (segment % 3)))
		perch_points.append(p + Vector3(0, arch_height * 0.72 + radius + thickness + 0.3, 0))
		waypoints.append(p + Vector3(0, arch_height * 0.72 + 1, 0))
		_feature_counts["arches"] += 1
	# Nearby rock needles add slalom choices along the coast.
	for i in range(7):
		var p := Vector3(115 + _rng.randf_range(-23, 20), 0, -54 - i * 11)
		var h := _rng.randf_range(5, 15)
		p.y = maxf(terrain_height(p.x, p.z), -1.0)
		_cylinder(p + Vector3(0, h * 0.5, 0), 3.0, 0.5, h, 5, PALETTE["rock"])

func _build_nest_cliffs() -> void:
	# A stepped wall is deliberately segmented around nesting cavities. The
	# front/back ring and its side tunnel walls create a real tight fly-in pocket.
	var p := Vector3(-23, 0, -132)
	for i in range(5):
		var x := p.x - 34 + i * 17
		var h := 28.0 + (i % 3) * 8.0
		var base := maxf(terrain_height(x, p.z), 1)
		_cylinder(Vector3(x, base + h * 0.5, p.z - 10), 11.0, 7.8, h, 6, PALETTE["rock"])
		_cylinder(Vector3(x, base + h - 2, p.z - 10), 9.5, 8.5, 4, 6, PALETTE["rock_light"])
		perch_points.append(Vector3(x, base + h + 0.3, p.z - 10))
	for i in range(4):
		var center := Vector3(p.x - 26 + i * 18, 14 + (i % 2) * 13, p.z + 0.5)
		var outer := 6.0
		var inner := 1.85 + i * 0.12
		var depth := 7.0
		# Square surrounding cliff plate: four bars, entrance remains open.
		var bar := (outer - inner * 2) * 0.5
		for dx in [-inner - bar * 0.5, inner + bar * 0.5]:
			_box(center + Vector3(dx, 0, 0), Vector3(bar, outer, depth), PALETTE["rock_light"])
		for dy in [-inner - bar * 0.5, inner + bar * 0.5]:
			_box(center + Vector3(0, dy, 0), Vector3(inner * 2, bar, depth), PALETTE["rock_light"])
		# Back wall closes the nesting chamber beyond the entrance, never at its mouth.
		_box(center + Vector3(0, 0, -depth * 0.5), Vector3(inner * 2, inner * 2, 0.35), PALETTE["dark"])
		var nest := center + Vector3(0, -inner + 0.36, -1.2)
		_small_nest(nest, 1.35)
		_box(center + Vector3(0, -inner - 0.1, 4.2), Vector3(inner * 2 + 1.6, 0.3, 2.1), PALETTE["sand"])
		_ring(center + Vector3(0, 0, depth * 0.5 + 0.1), inner - 0.15, 0.045, PALETTE["gold"], Vector3.FORWARD)
		perch_points.append(nest + Vector3(0, 0.6, 0))
		waypoints.append(center + Vector3(0, 0, 8))
		window_probes.append({"name": "Cliff nest %d" % i,
			"outside": center + Vector3(0, 0, depth * 0.5 + 2),
			"inside": center + Vector3(0, 0, 1),
			"wall_outside": center + Vector3(inner + 0.45, 0, depth * 0.5 + 2),
			"wall_inside": center + Vector3(inner + 0.45, 0, 1),
			"clear_width": inner * 2, "clear_height": inner * 2})
		_feature_counts["nest_entrances"] += 1

func _build_mountains() -> void:
	# Distant origami peaks frame the horizon outside the usable valley. Their
	# low polygon silhouette is intentionally calm, so nearby routes stay legible.
	for i in range(18):
		var angle := float(i) * TAU / 18
		if angle < 0.43 or angle > TAU - 0.6:
			continue # Ocean horizon remains open on the eastern edge.
		var radius := 232.0 + _rng.randf_range(-8, 34)
		var p := Vector3(cos(angle) * radius, -3.0, sin(angle) * radius)
		var h := _rng.randf_range(36, 91)
		var bottom_radius := _rng.randf_range(33, 58)
		_cylinder(p + Vector3(0, h * 0.5, 0), bottom_radius, 0.0, h, 5, Color("91a99b"), true, angle)
		if h > 64:
			_cylinder(p + Vector3(0, h - 8, 0), bottom_radius * 0.2, 0.0, 16, 5, Color("d7d5b8"), false, angle)
	# Low basalt offshore islands balance the town silhouette.
	for p in [Vector3(208, -2, -18), Vector3(243, -2, 48), Vector3(192, -2, 118)]:
		_cylinder(p + Vector3(0, 7, 0), 13, 5, 14, 6, Color("88a39c"))

func _build_thermals() -> void:
	thermals = [
		{"name": "Home Current", "center": Vector3(2, 0, 37), "radius": 13.0, "bottom": 1.0, "height": 76.0, "strength": 7.4},
		{"name": "Canopy Rise", "center": Vector3(66, 0, -6), "radius": 15.0, "bottom": 1.0, "height": 91.0, "strength": 7.8},
		{"name": "Courtyard Sun", "center": Vector3(-74, 0, -43), "radius": 10.0, "bottom": 3.0, "height": 86.0, "strength": 8.3},
		{"name": "Cliff Lift", "center": Vector3(-20, 0, -109), "radius": 15.0, "bottom": 1.0, "height": 107.0, "strength": 8.0},
		{"name": "Sea Breeze", "center": Vector3(110, 0, -83), "radius": 14.0, "bottom": 0.0, "height": 90.0, "strength": 7.3},
		{"name": "Windward Rise", "center": Vector3(-112, 0, 64), "radius": 12.0, "bottom": 7.0, "height": 100.0, "strength": 8.0}
	]
	for thermal in thermals:
		var center: Vector3 = thermal["center"]
		var radius: float = thermal["radius"]
		var bottom: float = thermal["bottom"]
		var height: float = thermal["height"]
		# Broad ground ring and upward arrows establish the safe-to-rest flight lane.
		var ground_y := maxf(terrain_height(center.x, center.z), -0.8) + 0.09
		_ring(Vector3(center.x, ground_y, center.z), radius * 0.7, 0.1, Color("f4d59a"), Vector3.UP)
		for arrow in range(3):
			var at := Vector3(center.x - 2 + arrow * 2.0, ground_y + 0.03, center.z)
			_triangle(at + Vector3(-0.55, 0, 0.65), at + Vector3(0, 0, -0.65), at + Vector3(0.55, 0, 0.65), PALETTE["gold"], false, true)
		# Three airy spiral ribbons are sparse meshes rather than transparent fog.
		for strand in range(3):
			for segment in range(28):
				var t0 := float(segment) / 28
				var t1 := float(segment + 1) / 28
				var a := t0 * TAU * 1.6 + strand * TAU / 3
				var b := t1 * TAU * 1.6 + strand * TAU / 3
				var rr := radius * 0.45
				var start := center + Vector3(cos(a) * rr, bottom + 3 + t0 * (height - bottom - 8), sin(a) * rr)
				var end := center + Vector3(cos(b) * rr, bottom + 3 + t1 * (height - bottom - 8), sin(b) * rr)
				if segment % 4 == strand % 4:
					_branch(start, end, 0.025, Color("bba56d"), false, true)

		waypoints.append(center + Vector3(0, minf(55, height - 10), 0))
		_feature_counts["thermal_columns"] += 1

func _build_routes() -> void:
	# Three optional, readable ring routes introduce gentle progression through
	# launch/glide, canopy slalom and urban precision flight. Larger route gates
	# stay traversable for grown birds; nest pockets add a tighter separate choice.
	var routes := [
		{"name": "First Flight", "color": Color("ffe0a3"), "radius": 4.2, "points": [Vector3(0, 21, 43), Vector3(7, 24, 18), Vector3(4, 28, -12), Vector3(-10, 31, -39)]},
		{"name": "Canopy Weave", "color": Color("abdfc4"), "radius": 3.4, "points": [Vector3(44, 22, 35), Vector3(63, 19, 18), Vector3(81, 23, -3), Vector3(71, 29, -23)]},
		{"name": "Roofline Run", "color": Color("ffb69b"), "radius": 3.3, "points": [Vector3(-37, 32, -17), Vector3(-70, 39, -12), Vector3(-92, 49, -45), Vector3(-78, 61, -88)]}
	]
	for route in routes:
		var points: Array = route["points"]
		for i in range(points.size()):
			var p: Vector3 = points[i]
			var direction: Vector3
			if i < points.size() - 1:
				direction = points[i + 1] - p
			else:
				direction = p - points[i - 1]
			direction.y *= 0.3
			direction = direction.normalized()
			var ring_radius: float = route["radius"]
			_ring(p, ring_radius, 0.095, route["color"], direction, true)
			# A small pair of feathers flanks each open ring; no collision blocks it.
			var side := direction.cross(Vector3.UP).normalized()
			_feather(p + side * (ring_radius + 0.55), Vector3.UP, 1.1, route["color"])
			route_rings.append({"center": p, "normal": direction, "radius": ring_radius, "route": route["name"], "index": i})
			waypoints.append(p)
		_feature_counts["routes"] += 1

func _build_clouds() -> void:
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in range(15):
		var angle := i * TAU / 15 + 0.3
		var p := Vector3(cos(angle) * _rng.randf_range(185, 255), _rng.randf_range(91, 130), sin(angle) * _rng.randf_range(185, 255))
		for clump in range(4):
			var offset := Vector3((clump - 1.5) * 8, _rng.randf_range(-1.5, 2), _rng.randf_range(-2.5, 2.5))
			var scale := Vector3(_rng.randf_range(9, 13), _rng.randf_range(3.5, 6), _rng.randf_range(6, 9))
			transforms.append(Transform3D(Basis().scaled(scale), p + offset))
			colors.append(Color("ece4cc").lightened(float(clump % 2) * 0.025))
		_feature_counts["cloud_clusters"] += 1
	_add_multimesh("HorizonClouds", _make_faceted_sphere(8, 4), transforms, colors, false)

func _small_nest(p: Vector3, radius: float) -> void:
	# Perchable bottom with individually visible twigs and a free open center.
	_cylinder(p, radius, radius * 0.84, 0.22, 9, PALETTE["bark"])
	for i in range(9):
		var a := i * TAU / 9
		var at := p + Vector3(cos(a) * radius, 0.23, sin(a) * radius)
		_box(at, Vector3(radius * 0.78, 0.36, 0.25), PALETTE["bark"].lightened(float(i % 3) * 0.06), true, -a)
		_box(at + Vector3(0, 0.18, 0), Vector3(radius * 0.91, 0.12, 0.18), PALETTE["sand"], false, -a)

func _poly_bush(center: Vector3, scale: Vector3, color: Color) -> void:
	var mesh := _make_faceted_sphere(7, 3)
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for i in range(0, indices.size(), 3):
		_triangle(center + vertices[indices[i]] * scale, center + vertices[indices[i + 2]] * scale, center + vertices[indices[i + 1]] * scale, color, false)

func _feather(p: Vector3, direction: Vector3, length: float, color: Color) -> void:
	var up := direction.normalized()
	var side := up.cross(Vector3.FORWARD).normalized()
	if side.length() < 0.1:
		side = Vector3.RIGHT
	var tip := p + up * length
	var mid := p + up * length * 0.6
	_triangle(p, mid - side * length * 0.2, tip, color, false, true)
	_triangle(p, tip, mid + side * length * 0.2, color.lightened(0.08), false, true)

func _ring(center: Vector3, radius: float, tube: float, color: Color, normal: Vector3, accent: bool = true) -> void:
	var forward := normal.normalized()
	var tangent := forward.cross(Vector3.UP).normalized()
	if tangent.length_squared() < 0.01:
		tangent = Vector3.RIGHT
	var bitangent := forward.cross(tangent).normalized()
	for segment in range(36):
		var a := segment * TAU / 36
		var b := (segment + 1) * TAU / 36
		var radial_a := tangent * cos(a) + bitangent * sin(a)
		var radial_b := tangent * cos(b) + bitangent * sin(b)
		# A square-section tube gives the stylized ring volume from either side.
		var a0 := center + radial_a * (radius - tube) - forward * tube
		var a1 := center + radial_a * (radius + tube) - forward * tube
		var a2 := center + radial_a * (radius + tube) + forward * tube
		var a3 := center + radial_a * (radius - tube) + forward * tube
		var b0 := center + radial_b * (radius - tube) - forward * tube
		var b1 := center + radial_b * (radius + tube) - forward * tube
		var b2 := center + radial_b * (radius + tube) + forward * tube
		var b3 := center + radial_b * (radius - tube) + forward * tube
		_quad(a0, b0, b1, a1, color, false, accent)
		_quad(a1, b1, b2, a2, color, false, accent)
		_quad(a2, b2, b3, a3, color, false, accent)
		_quad(a3, b3, b0, a0, color, false, accent)

func _arch_wedge(p: Vector3, inner: float, outer: float, a: float, b: float, depth: float, color: Color) -> void:
	var ia := Vector3(cos(a) * inner, sin(a) * inner, 0)
	var ib := Vector3(cos(b) * inner, sin(b) * inner, 0)
	var oa := Vector3(cos(a) * outer, sin(a) * outer, 0)
	var ob := Vector3(cos(b) * outer, sin(b) * outer, 0)
	var z := Vector3(0, 0, depth * 0.5)
	_quad(p + ia + z, p + ib + z, p + ob + z, p + oa + z, color)
	_quad(p + oa - z, p + ob - z, p + ib - z, p + ia - z, color.darkened(0.08))
	_quad(p + ia - z, p + ib - z, p + ib + z, p + ia + z, color.darkened(0.12))
	_quad(p + oa + z, p + ob + z, p + ob - z, p + oa - z, color.lightened(0.04))
	_quad(p + ia + z, p + oa + z, p + oa - z, p + ia - z, color)
	_quad(p + ib - z, p + ob - z, p + ob + z, p + ib + z, color)

func _box(center: Vector3, size: Vector3, color: Color, collide: bool = true, yaw: float = 0.0) -> void:
	if minf(size.x, minf(size.y, size.z)) <= 0.0:
		return
	var s := size * 0.5
	var basis := Basis(Vector3.UP, yaw)
	var corners: Array[Vector3] = []
	for point in [Vector3(-s.x, -s.y, -s.z), Vector3(s.x, -s.y, -s.z), Vector3(s.x, s.y, -s.z), Vector3(-s.x, s.y, -s.z),
		Vector3(-s.x, -s.y, s.z), Vector3(s.x, -s.y, s.z), Vector3(s.x, s.y, s.z), Vector3(-s.x, s.y, s.z)]:
		corners.append(center + basis * point)
	for face in [[4, 5, 6, 7], [1, 0, 3, 2], [0, 4, 7, 3], [5, 1, 2, 6], [3, 7, 6, 2], [0, 1, 5, 4]]:
		_quad(corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]], color, collide)

func _cylinder(center: Vector3, bottom_radius: float, top_radius: float, height: float, sides: int, color: Color, collide: bool = true, yaw: float = 0.0) -> void:
	for i in range(sides):
		var a := i * TAU / sides + yaw
		var b := (i + 1) * TAU / sides + yaw
		var v0 := center + Vector3(cos(a) * bottom_radius, -height * 0.5, sin(a) * bottom_radius)
		var v1 := center + Vector3(cos(b) * bottom_radius, -height * 0.5, sin(b) * bottom_radius)
		var v2 := center + Vector3(cos(b) * top_radius, height * 0.5, sin(b) * top_radius)
		var v3 := center + Vector3(cos(a) * top_radius, height * 0.5, sin(a) * top_radius)
		var shade := float(i % 3) * 0.025
		_quad(v0, v3, v2, v1, color.lightened(shade), collide)
		_triangle(center + Vector3(0, -height * 0.5, 0), v0, v1, color.darkened(0.08), collide)
		if top_radius > 0.0:
			_triangle(center + Vector3(0, height * 0.5, 0), v2, v3, color.lightened(0.04), collide)

func _branch(start: Vector3, end: Vector3, radius: float, color: Color, collide: bool = true, accent: bool = false) -> void:
	var axis := (end - start).normalized()
	var tangent := axis.cross(Vector3.UP).normalized()
	if tangent.length_squared() < 0.01:
		tangent = Vector3.RIGHT
	var bitangent := axis.cross(tangent).normalized()
	for i in range(5):
		var a := i * TAU / 5
		var b := (i + 1) * TAU / 5
		var va := tangent * cos(a) + bitangent * sin(a)
		var vb := tangent * cos(b) + bitangent * sin(b)
		_quad(start + va * radius, start + vb * radius, end + vb * radius * 0.7, end + va * radius * 0.7, color, collide, accent)
		_triangle(start, start + vb * radius, start + va * radius, color, collide, accent)
		_triangle(end, end + va * radius * 0.7, end + vb * radius * 0.7, color, collide, accent)

func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color, collide: bool = true, accent: bool = false) -> void:
	_triangle(a, b, c, color, collide, accent)
	_triangle(a, c, d, color, collide, accent)

func _triangle(a: Vector3, b: Vector3, c: Vector3, color: Color, collide: bool = true, accent: bool = false) -> void:
	var cross_product := (b - a).cross(c - a)
	# Pointed cylinders can collapse one half of a quad into a zero-area tip.
	# Exclude these from GPU and collision buffers rather than sending zero
	# normals through octahedral normal compression on mobile XR hardware.
	if cross_product.length_squared() < 0.0000000001:
		return
	var normal := cross_product.normalized()
	var points := PackedVector3Array([a, c, b])
	var normals := PackedVector3Array([normal, normal, normal])
	var colors := PackedColorArray([color, color, color])
	if accent:
		_accent_vertices.append_array(points)
		_accent_normals.append_array(normals)
		_accent_colors.append_array(colors)
	else:
		_vertices.append_array(points)
		_normals.append_array(normals)
		_colors.append_array(colors)
	if collide:
		_collision_vertices.append_array(points)

func _water_triangle(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	_water_vertices.append_array(PackedVector3Array([a, c, b]))
	_water_normals.append_array(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP]))
	_water_colors.append_array(PackedColorArray([color, color, color]))

func _flush_geometry() -> void:
	_opaque_mesh = MeshInstance3D.new()
	_opaque_mesh.name = "ValleyGeometry"
	_opaque_mesh.mesh = _array_mesh(_vertices, _normals, _colors)
	_opaque_mesh.material_override = _vertex_material()
	add_child(_opaque_mesh)
	var accent_mesh := MeshInstance3D.new()
	accent_mesh.name = "FlightMarkers"
	accent_mesh.mesh = _array_mesh(_accent_vertices, _accent_normals, _accent_colors)
	accent_mesh.material_override = _vertex_material(true)
	accent_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(accent_mesh)
	var water_mesh := MeshInstance3D.new()
	water_mesh.name = "Silverwater"
	water_mesh.mesh = _array_mesh(_water_vertices, _water_normals, _water_colors)
	var water_material := _vertex_material()
	water_material.roughness = 0.35
	water_material.metallic = 0.15
	water_mesh.material_override = water_material
	water_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water_mesh)
	var body := StaticBody3D.new()
	body.name = "WorldCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(_collision_vertices)
	var collider := CollisionShape3D.new()
	collider.name = "MatchedSurfaceTriangles"
	collider.shape = shape
	body.add_child(collider)
	add_child(body)

func _array_mesh(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	# Explicit indices keep every procedural surface on the same indexed draw
	# path as our repeated art. Vertex/color/normal array lengths always match.
	var indices := PackedInt32Array()
	indices.resize(vertices.size())
	for i in range(indices.size()):
		indices[i] = i
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _vertex_material(unshaded: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	if unshaded:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat

func _make_faceted_sphere(sides: int, rows: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in range(rows):
		var phi0 := -PI * 0.5 + row * PI / rows
		var phi1 := -PI * 0.5 + (row + 1) * PI / rows
		for side in range(sides):
			var a := side * TAU / sides
			var b := (side + 1) * TAU / sides
			var p0 := Vector3(cos(phi0) * cos(a), sin(phi0), cos(phi0) * sin(a))
			var p1 := Vector3(cos(phi0) * cos(b), sin(phi0), cos(phi0) * sin(b))
			var p2 := Vector3(cos(phi1) * cos(b), sin(phi1), cos(phi1) * sin(b))
			var p3 := Vector3(cos(phi1) * cos(a), sin(phi1), cos(phi1) * sin(a))
			var triangles := []
			if row > 0:
				triangles.append([p0, p2, p1])
			if row < rows - 1:
				triangles.append([p0, p3, p2])
			for tri in triangles:
				var n: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0]).normalized()
				st.set_normal(n)
				for v in [tri[0], tri[2], tri[1]]:
					st.add_vertex(v)
	st.index()
	return st.commit()

func _add_multimesh(node_name: String, mesh: Mesh, transforms: Array[Transform3D], colors: Array[Color], shadows: bool, parent_node: Node = null, unshaded: bool = false) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = mm
	instance.material_override = _vertex_material(unshaded)
	if not shadows:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if parent_node != null:
		parent_node.add_child(instance)
	else:
		add_child(instance)
