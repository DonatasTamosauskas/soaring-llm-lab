class_name PaletteTests
extends RefCounted

## Holds the art direction to its own rules.
##
## Art is judged by looking at it, and most of this area's work was done with a
## camera and a pair of eyes. These assertions exist for the parts of "looks
## right" that survive as numbers: that the palette is one palette, that shapes
## are still legible when the air has eaten their colour, that the land is
## published in the colour space the engine consumes, and — the one that caught a
## real bug — that the atmosphere the code claims to build is thick enough to
## actually appear on screen.
##
## The load-bearing one is [method _test_the_world_invents_no_colours]: it reads
## the source of every file that draws something and fails on a [Color] literal
## outside [Palette]. Without it, "one palette" is a convention, and conventions
## decay one prop at a time.


static func run(t: TestCase) -> void:
	_test_the_palette_is_disciplined(t)
	_test_shapes_read_by_brightness_alone(t)
	_test_the_world_invents_no_colours(t)
	_test_every_material_is_flat_and_cheap(t)
	_test_the_ground_is_published_in_linear(t)
	_test_the_ground_reads_its_own_height(t)
	_test_facets_are_stable_and_varied(t)
	_test_the_air_is_thick_enough_to_see(t)
	_test_altitude_changes_what_the_air_does(t)
	_test_every_hour_is_a_complete_day(t)
	_test_the_sun_and_the_clouds_agree(t)


# --- the palette itself ------------------------------------------------------

## Every colour is in gamut, none of them is a screaming saturated primary, and
## nothing anywhere is magenta. Magenta is Godot's missing-material colour and
## the renderer's own failure mode on this machine; a magenta in the palette
## would make a real defect unreadable.
static func _test_the_palette_is_disciplined(t: TestCase) -> void:
	t.begin("the palette is disciplined")
	t.greater(float(Palette.SURFACES.size()), 15.0, "the palette is the whole world")
	for name: String in Palette.SURFACES:
		var c: Color = Palette.SURFACES[name]
		t.ok(
			is_finite(c.r) and is_finite(c.g) and is_finite(c.b),
			"%s is a real colour" % name
		)
		t.ok(
			c.r >= 0.0 and c.r <= 1.0 and c.g >= 0.0 and c.g <= 1.0
				and c.b >= 0.0 and c.b <= 1.0,
			"%s is in gamut" % name
		)
		t.ok(c.a == 1.0, "%s is opaque — nothing in this world sorts" % name)
		var hue: float = c.h * 360.0
		var is_signal: bool = Palette.SIGNAL_SURFACES.has(name)
		if not is_signal:
			t.less(c.s, 0.76, "%s is not a screaming primary" % name)
			t.ok(
				not (hue > 270.0 and hue < 345.0 and c.s > 0.25),
				"%s is not magenta (hue %.0f, sat %.2f)" % [name, hue, c.s]
			)
			# Nothing is authored near white but the things that are white.
			# Signal colours are exempt: they are emission tints rather than
			# albedos, so the sun never lands on them and they cannot clip.
			if name != "cloud":
				t.less(c.v, 0.86, "%s leaves the tonemapper somewhere to go" % name)

	# Plumage has to be a set of distinguishable birds, not six shades of one.
	for i in Palette.PLUMAGE.size():
		for j in range(i + 1, Palette.PLUMAGE.size()):
			var a: Color = Palette.colour(Palette.PLUMAGE[i])
			var b: Color = Palette.colour(Palette.PLUMAGE[j])
			t.greater(
				_difference(a, b), 0.10,
				"%s and %s are different birds" % [Palette.PLUMAGE[i], Palette.PLUMAGE[j]]
			)
	# And the whole set has to come out of the palette, whatever it is handed.
	for pick: float in [0.0, 0.17, 0.5, 0.83, 0.999, 1.0, 1.7, -0.4]:
		t.ok(
			Palette.SURFACES.values().has(Palette.plumage(pick)),
			"plumage(%.3f) is a palette colour" % pick
		)


## Aerial perspective eats hue long before it eats brightness: at 600 m a green
## tree and a brown trunk are the same blue-grey unless they were different
## brightnesses to begin with. So every pair of surfaces that touch in the world
## has to differ in luminance, not merely in colour.
static func _test_shapes_read_by_brightness_alone(t: TestCase) -> void:
	t.begin("shapes read by brightness alone")
	for pair: Array in Palette.CONTRAST_PAIRS:
		var a: String = pair[0]
		var b: String = pair[1]
		var difference: float = absf(
			_luminance(Palette.colour(a)) - _luminance(Palette.colour(b))
		)
		t.greater(difference, 0.05, "%s reads against %s in grey (%.3f)" % [a, b, difference])


## No file that draws anything is allowed to invent a colour. This is what keeps
## "one palette" true a year from now: add a prop with a hand-picked green and
## the suite tells you where the green belongs instead.
static func _test_the_world_invents_no_colours(t: TestCase) -> void:
	t.begin("the world invents no colours")
	# The HUD is deliberately absent: its white-on-black-outline text is a
	# legibility decision owned by the UI work, not a palette entry.
	var painted: PackedStringArray = [
		"res://scripts/world/WorldBuilder.gd",
		"res://scripts/world/GeometryBatch.gd",
		"res://scripts/ai/BirdNPC.gd",
		"res://scripts/player/WingVisual.gd",
		"res://scripts/player/BirdPlayer.gd",
	]
	for path: String in painted:
		var source: String = FileAccess.get_file_as_string(path)
		t.ok(not source.is_empty(), "%s is readable" % path)
		# One assertion per file, naming every offending line: a check per source
		# line would bury the rest of the suite under two thousand assertions.
		var offences: PackedStringArray = []
		var line_number: int = 0
		for line: String in source.split("\n"):
			line_number += 1
			var code: String = line.strip_edges()
			if code.begins_with("#"):
				continue
			if code.contains("Color(") or code.contains("Color.from_hsv"):
				offences.append("%d: %s" % [line_number, code])
		t.ok(
			offences.is_empty(),
			"%s invents a colour; put it in Palette instead [%s]" % [
				path, ", ".join(offences)
			]
		)


## Flat, unspecular, opaque, matte and shared. Specular alone is a real per-pixel
## cost on a headset, and this world is faceted enough not to need a highlight.
static func _test_every_material_is_flat_and_cheap(t: TestCase) -> void:
	t.begin("every material is flat and cheap")
	var materials: Dictionary = Palette.materials()
	for name: String in Palette.SURFACES:
		t.ok(materials.has(name), "%s has a material" % name)
	t.ok(materials.has("ground"), "the terrain has a material")

	for name: String in materials:
		var material: Material = materials[name]
		if material is ShaderMaterial:
			# Cloud paints its own gradient — see Palette.CLOUD_SHADER.
			t.ok(name == "cloud", "%s is the only shaded surface" % name)
			continue
		var m: StandardMaterial3D = material
		t.ok(
			m.specular_mode == BaseMaterial3D.SPECULAR_DISABLED,
			"%s has no specular highlight" % name
		)
		t.near(m.metallic, 0.0, 0.001, "%s is not metal" % name)
		t.greater(m.roughness, 0.3, "%s is matte" % name)
		t.ok(
			m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
			"%s is opaque" % name
		)

	# The world's material count is its draw-call floor: one material can be one
	# surface per structure, and 570 structures multiply anything that grows here.
	t.less(float(materials.size()), 32.0, "the whole world fits in a handful of materials")

	# And they are genuinely shared — the same instance every lookup, per world.
	var world := WorldBuilder.new()
	world.build()
	var seen: Dictionary = {}
	var instances: int = 0
	for child: Node in world.get_children():
		for grandchild: Node in child.get_children():
			if not (grandchild is MeshInstance3D):
				continue
			var mesh_instance: MeshInstance3D = grandchild
			if mesh_instance.material_override != null:
				seen[mesh_instance.material_override.get_instance_id()] = true
				instances += 1
			var mesh: Mesh = mesh_instance.mesh
			if mesh == null:
				continue
			for surface in mesh.get_surface_count():
				var material: Material = mesh.surface_get_material(surface)
				if material == null:
					continue
				seen[material.get_instance_id()] = true
				instances += 1
	t.greater(float(instances), 100.0, "the world really did paint hundreds of surfaces")
	t.less(float(seen.size()), 32.0, "with no more materials than the palette has")
	world.free()


# --- the ground --------------------------------------------------------------

## Vertex colours are handed to the GPU as linear while `albedo_color` is
## converted from sRGB for you. Publishing the terrain in sRGB made the ground
## roughly four times brighter than everything standing on it, and no amount of
## darkening the palette fixed it because the palette was not the problem.
static func _test_the_ground_is_published_in_linear(t: TestCase) -> void:
	t.begin("the ground is published in linear")
	var valley: Color = Palette.ground_colour(0.0, 0.0, 0.0, 0.0)
	var authored: Color = Palette.GROUND_BANDS["grass"]
	t.near(valley.r, authored.srgb_to_linear().r, 0.01, "valley red is linear")
	t.near(valley.g, authored.srgb_to_linear().g, 0.01, "valley green is linear")
	t.near(valley.b, authored.srgb_to_linear().b, 0.01, "valley blue is linear")
	t.less(
		valley.g, authored.g - 0.02,
		"and is therefore darker than the sRGB number it was authored as"
	)


## The ground is an altitude instrument: green in the bowl, rock on the walls,
## snow on the rim, and a pale patch of baked earth wherever a thermal stands.
static func _test_the_ground_reads_its_own_height(t: TestCase) -> void:
	t.begin("the ground reads its own height")
	var valley: Color = Palette.ground_colour(20.0, 0.0, 0.0, 0.0)
	var hillside: Color = Palette.ground_colour(150.0, 0.2, 0.0, 0.0)
	var wall: Color = Palette.ground_colour(330.0, 0.6, 0.0, 0.0)
	var crest: Color = Palette.ground_colour(640.0, 0.1, 0.0, 0.0)

	t.greater(_greenness(valley), 0.02, "the bowl is green")
	t.less(_greenness(wall), _greenness(valley), "the wall is not")
	t.greater(
		_luminance(crest), _luminance(wall) * 1.6,
		"the crest is snow and the wall is rock"
	)
	t.less(_luminance(valley), _luminance(crest), "and the bowl is darker than the snow")

	# A cliff still shows which band it is standing in. Taken all the way to bare
	# stone, the rim became one flat lavender curtain 900 m wide.
	var steep_high: Color = Palette.ground_colour(520.0, 0.9, 0.0, 0.0)
	var steep_low: Color = Palette.ground_colour(120.0, 0.9, 0.0, 0.0)
	t.greater(
		_difference(steep_high, steep_low), 0.04,
		"a cliff face still shows its height (%.3f)" % _difference(steep_high, steep_low)
	)

	# The thermal tell, which the world's own suite reads off the built mesh.
	var bare: Color = Palette.ground_colour(20.0, 0.0, 1.0, 0.0)
	t.greater(bare.r - valley.r, 0.05, "the ground under a thermal is visibly bleached")
	t.less(bare.r - valley.r, 0.5, "but the bowl is not a desert")


## The facet shade has to be stable — the world is rebuilt from a seed and must
## come out identical — and it has to vary more on rock than on turf.
static func _test_facets_are_stable_and_varied(t: TestCase) -> void:
	t.begin("facets are stable and varied")
	var low: float = INF
	var high: float = -INF
	var same: bool = true
	for i in 400:
		var x: float = float(i) * 7.3 - 900.0
		var z: float = float(i) * -11.7 + 400.0
		var shade: float = Palette.facet_shade(x, z)
		same = same and is_equal_approx(shade, Palette.facet_shade(x, z))
		low = minf(low, shade)
		high = maxf(high, shade)
	t.ok(same, "the same patch always shades the same way")
	t.in_range(low, -1.0, -0.7, "facets go darker")
	t.in_range(high, 0.7, 1.0, "and lighter")

	# Neighbouring triangles inside one patch share a shade, or the rim wall
	# combs itself into fur.
	t.near(
		Palette.facet_shade(70.0, 70.0), Palette.facet_shade(95.0, 95.0), 0.0001,
		"triangles inside one patch agree"
	)
	t.ok(
		not is_equal_approx(
			Palette.facet_shade(70.0, 70.0), Palette.facet_shade(140.0, 70.0)
		),
		"and neighbouring patches do not"
	)

	var turf_a: Color = Palette.ground_colour(30.0, 0.05, 0.0, 1.0)
	var turf_b: Color = Palette.ground_colour(30.0, 0.05, 0.0, -1.0)
	var rock_a: Color = Palette.ground_colour(300.0, 0.85, 0.0, 1.0)
	var rock_b: Color = Palette.ground_colour(300.0, 0.85, 0.0, -1.0)
	t.greater(_difference(turf_a, turf_b), 0.005, "turf has grain")
	t.greater(
		_difference(rock_a, rock_b), _difference(turf_a, turf_b),
		"and broken rock has more of it"
	)
	# Brighter facets are warmer ones — the sun-and-sky split, at facet scale.
	t.greater(turf_a.r / maxf(turf_a.b, 0.0001), turf_b.r / maxf(turf_b.b, 0.0001),
		"a lit facet is a warm facet")


# --- light and air -----------------------------------------------------------

## The one that caught a real bug. The air was configured in
## [constant Environment.FOG_MODE_DEPTH], where density is a fraction of the way
## to `fog_depth_end` rather than a density per metre: 0.00021 over 3200 m is
## 0.02 % opacity. Aerial perspective was documented as the game's main altitude
## and speed cue and was rendering nothing whatsoever. This asserts on the
## atmosphere the [Environment] is actually built with, in the units the shader
## actually uses.
static func _test_the_air_is_thick_enough_to_see(t: TestCase) -> void:
	t.begin("the air is thick enough to see")
	for hour: Palette.Hour in [Palette.Hour.MORNING, Palette.Hour.NOON, Palette.Hour.EVENING]:
		var name: String = Palette.hour_name(hour)
		var env: Environment = Palette.environment(hour)
		t.ok(env.fog_enabled, "%s: there is air" % name)
		t.ok(
			env.fog_mode == Environment.FOG_MODE_EXPONENTIAL,
			"%s: air is measured per metre, not as a fraction of a far plane" % name
		)
		t.near(
			env.fog_density, Palette.atmosphere(hour)["fog_density"], 1e-9,
			"%s: the environment carries the atmosphere's own density" % name
		)

		# The shape of aerial perspective, at the distances this world is played
		# at. A bird you are chasing stays crisp; the rim reads as mass at 900 m;
		# the massif beyond it is air.
		var near_bird: float = Palette.haze(40.0, 200.0, hour)
		var mid: float = Palette.haze(300.0, 200.0, hour)
		var rim: float = Palette.haze(900.0, 200.0, hour)
		var beyond: float = Palette.haze(1600.0, 200.0, hour)
		t.less(near_bird, 0.06, "%s: a bird 40 m away is not hazy" % name)
		t.in_range(mid, 0.06, 0.30, "%s: the middle distance is softened" % name)
		t.in_range(rim, 0.25, 0.60, "%s: the rim is a mass, not a ghost" % name)
		t.greater(beyond, rim, "%s: and the massif beyond it is further away" % name)
		t.less(beyond, 0.85, "%s: nothing ever disappears completely" % name)

		# Monotone, so distance is always readable as distance.
		var previous: float = -1.0
		for metres in range(0, 2000, 50):
			var here: float = Palette.haze(float(metres), 200.0, hour)
			t.ok(here >= previous - 1e-6, "%s: haze only grows with distance" % name)
			previous = here

		# The haze is the colour of the sky it stands in front of, or the world
		# ends in a band of the wrong colour.
		var sky_material: ProceduralSkyMaterial = env.sky.sky_material
		var horizon: Color = sky_material.sky_horizon_color
		t.less(
			_difference(env.fog_light_color, horizon), 0.22,
			"%s: the air matches the sky at the horizon" % name
		)


## Height is a thing you can see. Down in the valley the air is thicker; climb
## out of it and the world sharpens.
static func _test_altitude_changes_what_the_air_does(t: TestCase) -> void:
	t.begin("altitude changes what the air does")
	for hour: Palette.Hour in [Palette.Hour.MORNING, Palette.Hour.NOON, Palette.Hour.EVENING]:
		var name: String = Palette.hour_name(hour)
		var down: float = Palette.haze(30.0, 0.0, hour)
		var up: float = Palette.haze(30.0, 400.0, hour)
		t.greater(down, up + 0.01, "%s: the valley floor holds haze" % name)
		# But never so much that low flight goes soft — this is the trap in
		# Godot's height fog, which takes no account of distance at all.
		t.less(down, 0.22, "%s: and low flight stays crisp" % name)
		var env: Environment = Palette.environment(hour)
		t.near(
			env.fog_height, Palette.atmosphere(hour)["haze_top"], 1e-6,
			"%s: the environment carries the same haze layer" % name
		)


## Each hour is a complete, usable lighting state: sun above the horizon, warm
## light against cool fill, and a sky that is darker at the top than at the
## bottom. A half-defined preset is a black world one command-line flag away.
static func _test_every_hour_is_a_complete_day(t: TestCase) -> void:
	t.begin("every hour is a complete day")
	var keys: PackedStringArray = PackedStringArray(
		Palette.atmosphere(Palette.Hour.MORNING).keys()
	)
	for hour: Palette.Hour in [Palette.Hour.MORNING, Palette.Hour.NOON, Palette.Hour.EVENING]:
		var name: String = Palette.hour_name(hour)
		var air: Dictionary = Palette.atmosphere(hour)
		for key: String in keys:
			t.ok(air.has(key), "%s defines %s" % [name, key])

		var sun: DirectionalLight3D = Palette.sun(hour)
		var angles: Vector3 = air["sun_angles"]
		t.in_range(angles.x, -75.0, -8.0, "%s: the sun is above the horizon" % name)
		t.in_range(sun.light_energy, 0.8, 2.0, "%s: the sun is a sun" % name)
		t.ok(sun.shadow_enabled, "%s: and it casts shadows" % name)
		var sun_colour: Color = air["sun_colour"]
		var fill: Color = air["ambient_colour"]
		t.greater(
			sun_colour.r - sun_colour.b, 0.02, "%s: sunlight is warm" % name
		)
		t.greater(fill.b - fill.r, 0.02, "%s: and the fill it fights is cool" % name)
		t.greater(_luminance(fill), 0.1, "%s: shadows are not holes" % name)
		sun.free()

		var env: Environment = Palette.environment(hour)
		t.ok(
			env.tonemap_mode == Environment.TONE_MAPPER_ACES,
			"%s: one tonemapper for the whole game" % name
		)
		t.ok(
			env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY,
			"%s: ambient comes from the sky" % name
		)
		var sky_material: ProceduralSkyMaterial = env.sky.sky_material
		t.less(
			_luminance(sky_material.sky_top_color),
			_luminance(sky_material.sky_horizon_color),
			"%s: the sky is deepest overhead" % name
		)
		t.ok(
			env.sky.process_mode == Sky.PROCESS_MODE_QUALITY,
			"%s: the sky is baked once, not re-rendered per frame" % name
		)

	# The flag that selects them, including the shapes it must survive.
	t.ok(Palette.hour_named("evening") == Palette.Hour.EVENING, "--sky=evening")
	t.ok(Palette.hour_named("NOON") == Palette.Hour.NOON, "--sky is case-insensitive")
	t.ok(
		Palette.hour_named("banana", Palette.Hour.NOON) == Palette.Hour.NOON,
		"nonsense falls back instead of building a black world"
	)


## Cloud is unlit and paints its own gradient, so nothing in the engine keeps it
## pointing at the sun. This does.
static func _test_the_sun_and_the_clouds_agree(t: TestCase) -> void:
	t.begin("the sun and the clouds agree")
	for hour: Palette.Hour in [Palette.Hour.MORNING, Palette.Hour.NOON, Palette.Hour.EVENING]:
		var name: String = Palette.hour_name(hour)
		var sun: DirectionalLight3D = Palette.sun(hour)
		var direction: Vector3 = Palette.sun_direction(hour)
		var expected: Vector3 = -sun.transform.basis.z.normalized()
		t.less(
			direction.distance_to(expected), 0.001,
			"%s: the cloud shader is lit by the same sun as the world" % name
		)
		t.less(direction.y, -0.1, "%s: and the sun is above the clouds" % name)

		var material: ShaderMaterial = Palette.cloud_material(hour)
		var crown: Color = material.get_shader_parameter("crown")
		var base: Color = material.get_shader_parameter("base")
		t.greater(
			_luminance(crown) - _luminance(base), 0.20,
			"%s: a cumulus has a lit top and a shaded base" % name
		)
		t.greater(base.b, base.r, "%s: the shaded base is sky-lit, not muddy" % name)
		t.ok(
			material.get_shader_parameter("sun_direction") == direction,
			"%s: the shader is handed that sun" % name
		)
		var code: String = material.shader.code
		t.ok(code.contains("unshaded"), "%s: cloud costs no light loop" % name)
		t.ok(code.contains("shadows_disabled"), "%s: and no shadow lookup" % name)
		sun.free()


# --- helpers -----------------------------------------------------------------

## Perceived brightness. The number that decides whether two shapes are still
## distinguishable once the air has taken their hue away.
static func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


static func _difference(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


static func _greenness(c: Color) -> float:
	return c.g - maxf(c.r, c.b)
