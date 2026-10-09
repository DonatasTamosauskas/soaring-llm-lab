class_name Palette
extends RefCounted

## Soaring's art direction, expressed as data: every colour, every material, the
## light, the sky and the air. Nothing else in the game is allowed to invent a
## colour — [PaletteTests] enforces that by reading the source of the files that
## draw things and failing on a stray [Color] literal.
##
## The direction, in one line: [b]warm stone, cold air[/b]. A single warm sun;
## everything it cannot reach falls toward sky blue; everything far away
## falls toward the haze. Faceted, unspecular, high contrast, no texture
## anywhere. See [code]docs/ART-DIRECTION.md[/code] for the reasoning; this file
## is the implementation and the two are meant to be read together.
##
## Three rules hold it together:
## [br]1. [b]Value carries the silhouette, hue carries the identity.[/b] Adjacent
##    materials differ in luminance first (bark under leaf, roof over wall) so a
##    shape still reads as a shape at 600 m through fog, where hue has already
##    been eaten by the air.
## [br]2. [b]Nothing is authored above 0.80 albedo[/b] except snow and cloud. The
##    sun is strong and the tonemapper is ACES: a 0.9 grey lit head-on clips to
##    white and the surface loses its shape. This is the mistake that first made
##    the rim look like a meringue.
## [br]3. [b]Warm light, cool shadow.[/b] Sun and ambient are pushed apart in hue,
##    which is what makes flat-shaded facets read as facets instead of as one
##    grey mass.
##
## Authoring space is sRGB — these are numbers picked by eye. Godot converts
## [member BaseMaterial3D.albedo_color] for you; it does [b]not[/b] convert
## vertex colours, so [method ground_colour] converts them itself. Getting that
## backwards is what once made the terrain four times brighter than everything
## standing on it.

## Time of day. The land keeps its colours at every hour — rock does not change
## because the sun moved — so an hour is purely a lighting and atmosphere state.
enum Hour { MORNING, NOON, EVENING }


# --- the palette -------------------------------------------------------------

## Every surface colour in the world, in sRGB. Grouped by the family it belongs
## to; a new prop should reach for one of these before inventing anything.
const SURFACES: Dictionary = {
	# Stone. One neutral base plus a tint per district, so a spire never reads as
	# a ruin and "I am over the gorge" is a thing you can see from the colour of
	# the ground.
	"rock": Color(0.44, 0.41, 0.37),
	"rock_warm": Color(0.55, 0.37, 0.25),   # gorge: iron-stained sandstone
	"rock_pale": Color(0.62, 0.59, 0.53),   # town stone, cairns, arches
	"rock_cold": Color(0.40, 0.44, 0.52),   # spires: blue-grey teeth
	"rock_moss": Color(0.38, 0.42, 0.30),   # downs: lichened boulders
	# Wood and leaf. Greens are olive-leaning and dark; a saturated grass green
	# at this scale reads as a golf course from the air.
	"bark": Color(0.25, 0.18, 0.13),
	"leaf": Color(0.20, 0.34, 0.16),
	"leaf_deep": Color(0.13, 0.25, 0.14),
	"leaf_autumn": Color(0.58, 0.36, 0.17),
	"leaf_alpine": Color(0.12, 0.24, 0.20),
	# The town. Warm plaster walls under cold slate roofs: the widest value gap
	# in the palette, because a town seen from 400 m is nothing but roofs.
	"wall": Color(0.70, 0.62, 0.50),
	"wall_warm": Color(0.62, 0.39, 0.30),
	"wall_pale": Color(0.78, 0.73, 0.63),
	"roof": Color(0.23, 0.21, 0.25),
	"window": Color(0.15, 0.14, 0.16),
	"ledge": Color(0.68, 0.64, 0.56),
	"pole": Color(0.30, 0.24, 0.18),
	"wire": Color(0.09, 0.09, 0.10),
	# Signal colours. The only saturated things in the world, reserved for things
	# that are meant to catch the eye from a long way off.
	"banner": Color(0.72, 0.20, 0.16),
	# Cloud is the brightest thing in the game and the only pure white-ish value;
	# it is also the one surface a player navigates by from anywhere in the bowl.
	"cloud": Color(0.86, 0.87, 0.91),
	# Feathers. Six plausible bird colours — see [method plumage].
	"plumage_player": Color(0.68, 0.47, 0.30),
	"plumage_slate": Color(0.34, 0.38, 0.46),
	"plumage_rust": Color(0.56, 0.30, 0.18),
	"plumage_cream": Color(0.74, 0.68, 0.55),
	"plumage_char": Color(0.22, 0.21, 0.23),
	"plumage_olive": Color(0.40, 0.42, 0.26),
	"plumage_sand": Color(0.66, 0.55, 0.36),
	# Threat tints, painted as emission over a bird's own colour. They mean "eat"
	# and "flee", and they are the only cue that survives past about fifteen
	# metres, where silhouette and finger count are already sub-pixel.
	#
	# Prey is cyan rather than the green it started as. Green is the one hue this
	# world is full of: photographed at forty metres over the bowl, a green bird
	# against a green hillside was simply not there, while the red one was
	# obvious against everything — half a signal. Cyan appears nowhere in the
	# land, it is brighter than the sky it is seen against, and it is the one
	# choice that also separates from red for a red-green colourblind player,
	# which "green means eat, red means flee" never did.
	"threat_prey": Color(0.25, 1.0, 0.90),
	"threat_predator": Color(1.0, 0.24, 0.16),
}

## Names allowed to break the saturation ceiling: they exist to be shouted.
const SIGNAL_SURFACES: PackedStringArray = [
	"banner", "threat_prey", "threat_predator"
]

## Pairs that appear against each other in the world and therefore have to be
## told apart by brightness alone, at distance, through haze. Checked by
## [PaletteTests]; extend it when you add a prop that sits on another one.
const CONTRAST_PAIRS: Array = [
	["bark", "leaf"], ["leaf", "leaf_autumn"], ["wall", "roof"],
	["wall_pale", "roof"], ["wall", "window"], ["ledge", "window"],
	["rock_cold", "leaf_deep"], ["rock_warm", "rock_pale"], ["pole", "wire"],
	["cloud", "rock_cold"],
]

## Roughness per surface. Everything is matte unless there is a reason: only
## glass has any gloss to it, and even that is mostly a slight darkening.
const ROUGHNESS: Dictionary = {
	"window": 0.35,
	"wire": 0.60,
}
const DEFAULT_ROUGHNESS: float = 0.92

## Bird colours, in the order [method plumage] hands them out.
const PLUMAGE: PackedStringArray = [
	"plumage_slate", "plumage_rust", "plumage_cream",
	"plumage_char", "plumage_olive", "plumage_sand",
]


static func colour(name: String) -> Color:
	return SURFACES.get(name, SURFACES["rock"])


## A bird's feather colour, chosen from the palette rather than from the whole
## hue circle. A random hue put teal and magenta birds in an otherwise earthy
## world, and — worse — made size the only thing distinguishing two birds, since
## colour carried no meaning at all.
static func plumage(pick: float) -> Color:
	var index: int = clampi(int(absf(pick) * PLUMAGE.size()), 0, PLUMAGE.size() - 1)
	return colour(PLUMAGE[index])


# --- materials ---------------------------------------------------------------

## Every shared material in the world, by name. One material per surface, made
## once: with tens of thousands of primitives out there, per-instance materials
## would cost more than the geometry does.
static func materials(hour: Hour = Hour.MORNING) -> Dictionary:
	var air: Dictionary = atmosphere(hour)
	var out: Dictionary = {}
	for name: String in SURFACES:
		out[name] = surface_material(name)

	# Cloud is the one surface that is not lit at all — see [method cloud_material].
	out["cloud"] = cloud_material(hour)

	# Lit windows. A dark pane with a warm coal in it is the cheapest way to make
	# a box read as a building at 400 m, and it is the one warm thing left in the
	# town once the sun is off the walls.
	var window: StandardMaterial3D = out["window"]
	window.emission_enabled = true
	window.emission = air["window_glow"]
	window.emission_energy_multiplier = air["window_glow_energy"]

	# The terrain paints itself from vertex colours instead of a texture.
	var ground := StandardMaterial3D.new()
	ground.vertex_color_use_as_albedo = true
	ground.roughness = 0.98
	ground.metallic = 0.0
	ground.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	out["ground"] = ground
	return out


## Cloud shades itself from the world-space normal instead of being lit.
##
## A cumulus is seen from underneath for the whole game, and its underside faces
## nothing but the sky's ground colour — which is dirt. Lit normally it reads as
## a grey-green disc; lit with emission until the base looks right, the sunlit
## top blows out. Painting the gradient directly gives a bright warm crown, a
## cool blue base and a hard shadow line between them, which is the silhouette
## that makes a white blob read as weather.
##
## It is also the cheapest material in the game: unshaded means no light loop, no
## shadow lookup and no ambient probe for the largest surfaces on screen.
const CLOUD_SHADER: String = """
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

uniform vec3 crown : source_color;
uniform vec3 base : source_color;
uniform vec3 sun_tint : source_color;
uniform vec3 sun_direction;

void fragment() {
	vec3 world_normal = normalize(mat3(INV_VIEW_MATRIX) * NORMAL);
	// Hard-ish transition rather than a smooth ramp: cumulus has a flat, shaded
	// base and a lumpy lit top, and the line between them is the whole read.
	float up = smoothstep(-0.15, 0.45, world_normal.y);
	vec3 colour = mix(base, crown, up);
	// The face turned toward the sun catches its colour, so the light direction
	// is legible from the clouds alone at any hour.
	float facing = clamp(dot(world_normal, -sun_direction), 0.0, 1.0);
	ALBEDO = mix(colour, sun_tint, facing * 0.30);
}
"""


static func cloud_material(hour: Hour = Hour.MORNING) -> ShaderMaterial:
	var air: Dictionary = atmosphere(hour)
	var shader := Shader.new()
	shader.code = CLOUD_SHADER
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("crown", air["cloud_colour"])
	m.set_shader_parameter("base", air["cloud_base"])
	m.set_shader_parameter("sun_tint", air["cloud_glow"])
	m.set_shader_parameter("sun_direction", sun_direction(hour))
	return m


## The direction sunlight travels, as a unit vector. Derived from the same angles
## the [DirectionalLight3D] gets, so a shader that needs the sun cannot drift out
## of step with the sun.
static func sun_direction(hour: Hour = Hour.MORNING) -> Vector3:
	var air: Dictionary = atmosphere(hour)
	var angles: Vector3 = air["sun_angles"]
	var basis := Basis.from_euler(Vector3(
		deg_to_rad(angles.x), deg_to_rad(angles.y), deg_to_rad(angles.z)
	))
	return (basis * Vector3.FORWARD).normalized()


## One flat, unspecular, opaque material. Specular is disabled everywhere in this
## game: it is a real cost per pixel on a headset, and a faceted world lit by one
## sun does not need a highlight to read — the facet angles already do that job.
static func surface_material(name: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour(name)
	m.roughness = ROUGHNESS.get(name, DEFAULT_ROUGHNESS)
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m


# --- the ground --------------------------------------------------------------

## Terrain band colours, in sRGB, low to high. The ground is painted by height
## and steepness rather than textured, which costs nothing and doubles as an
## altitude instrument: you can see how high you are from the colour beneath you.
const GROUND_BANDS: Dictionary = {
	"grass": Color(0.26, 0.40, 0.18),
	"meadow": Color(0.40, 0.47, 0.22),
	"heath": Color(0.46, 0.40, 0.25),
	"crag": Color(0.42, 0.36, 0.30),
	"stone": Color(0.28, 0.28, 0.31),
	"scree": Color(0.58, 0.55, 0.48),
	"snow": Color(0.85, 0.87, 0.92),
	"baked": Color(0.66, 0.57, 0.34),
}

## Heights, in real metres, at which one band gives way to the next. The world
## spans 900 m of relief, so a normalised 0..1 ramp puts alpine scree on 90 m
## hills — which is exactly what it did.
const BAND_MEADOW := Vector2(10.0, 70.0)
const BAND_HEATH := Vector2(100.0, 230.0)
const BAND_CRAG := Vector2(240.0, 400.0)
const BAND_SCREE := Vector2(430.0, 570.0)
const BAND_SNOW := Vector2(500.0, 650.0)

## How much a facet's own shade may vary from its neighbours. This is the whole
## low-poly read of the terrain: every triangle is one flat colour, and a few per
## cent of variation between them turns a smooth green hillside into a surface
## made of visible planes. Too much and the ground looks like static.
const FACET_VARIATION: float = 0.10
## Side of one shade patch, in metres — a little over two terrain quads.
const FACET_PATCH: float = 34.0
## How far a cliff face is allowed to go toward bare stone. See
## [method ground_colour].
const STEEP_ROCK: float = 0.38
## How far the ground under a thermal goes toward bare, sun-baked earth. It has
## to be obvious enough to fly to and faint enough that forty-four of them do not
## turn the whole bowl into sand.
const DUST_STRENGTH: float = 0.5


## The colour of one patch of ground, in [b]linear[/b] space, ready to be written
## straight into a vertex colour.
##
## [param facet] is a per-triangle shade offset in −1..1 — see
## [method facet_shade]. [param dust] is how bleached this ground is by a thermal
## standing over it.
static func ground_colour(
	height: float, steepness: float, dust: float, facet: float = 0.0
) -> Color:
	var colour: Color = (GROUND_BANDS["grass"] as Color).lerp(
		GROUND_BANDS["meadow"], smoothstep(BAND_MEADOW.x, BAND_MEADOW.y, height)
	)
	colour = colour.lerp(
		GROUND_BANDS["heath"], smoothstep(BAND_HEATH.x, BAND_HEATH.y, height)
	)
	# Dark rock through the whole middle of the wall, pale scree only at the very
	# top. A pale mid-band is what made the rim read as a bright grey curtain: at
	# 0.48 albedo in full sun it is nearly as bright as the snow above it, so the
	# mountain lost its shape entirely.
	colour = colour.lerp(
		GROUND_BANDS["crag"], smoothstep(BAND_CRAG.x, BAND_CRAG.y, height)
	)
	colour = colour.lerp(
		GROUND_BANDS["scree"], smoothstep(BAND_SCREE.x, BAND_SCREE.y, height)
	)
	# Steep ground shows bare rock — but only ever partly. Taken to the full
	# stone colour, the rim wall, which is steep from top to bottom, became one
	# flat lavender curtain 900 m wide with no height bands left in it at all.
	# Capping the mix keeps the warm crag → pale scree → snow gradient running up
	# the wall, which is the only thing that gives a cliff a top and a bottom.
	colour = colour.lerp(
		GROUND_BANDS["stone"], smoothstep(0.30, 0.75, steepness) * STEEP_ROCK
	)
	# The snow line sits high enough that only the rim crest and the peaks behind
	# it ever reach it. A white ring right round the horizon is the cheapest way
	# to show a player where the world ends — but drop it too low and the whole
	# map reads as a glacier, which is what a 215 m snow line did.
	var snowline: float = smoothstep(BAND_SNOW.x, BAND_SNOW.y, height)
	colour = colour.lerp(
		GROUND_BANDS["snow"], snowline * (1.0 - smoothstep(0.40, 0.80, steepness))
	)
	colour = colour.lerp(GROUND_BANDS["baked"], clampf(dust, 0.0, 1.0) * DUST_STRENGTH)
	# Facet shading last, so it survives every band above it. The offset is
	# applied hardest to red and softest to blue, so a brighter facet is also a
	# warmer one — the same warm-light/cool-shadow split the sun and the sky
	# make, at the scale of a single triangle. A flat multiplier gave the rim
	# wall the texture of grey felt; this gives it grain.
	# Broken rock varies far more than turf does, so the steeper it is the more
	# each patch drifts from its neighbours.
	# Bounded deliberately: a patch boundary crossing a near, smooth cliff face
	# is a straight vertical seam rather than a facet, and past about a fifth it
	# stops reading as rock and starts reading as a mistake.
	var shade: float = clampf(facet, -1.0, 1.0) * FACET_VARIATION * (
		1.0 + steepness * 0.7
	)
	colour = Color(
		clampf(colour.r * (1.0 + shade), 0.0, 1.0),
		clampf(colour.g * (1.0 + shade * 0.8), 0.0, 1.0),
		clampf(colour.b * (1.0 + shade * 0.6), 0.0, 1.0)
	)
	# Vertex colours are consumed as linear while every `albedo_color` in the
	# world is authored in sRGB and converted by the engine. Handing the terrain
	# raw sRGB numbers made it roughly four times brighter than everything
	# standing on it — which is why the mountains read as a pale grey curtain no
	# matter how dark the palette got. Blend in sRGB, publish in linear.
	return colour.srgb_to_linear()


## A stable −1..1 shade offset for the facet at [param x],[param z]. Hashed from
## the position rather than drawn from an RNG so the terrain is identical however
## the mesh is walked, which the world's determinism test depends on.
static func facet_shade(x: float, z: float) -> float:
	# Quantised to patches a couple of terrain quads across rather than to single
	# triangles. Per-triangle noise reads as static — and on the rim wall, where
	# the quads stretch into long vertical slivers, it combed the whole mountain
	# into fur. A patch a few quads wide reads as rock and grass instead.
	var xi: int = int(floor(x / FACET_PATCH)) & 0xffff
	var zi: int = int(floor(z / FACET_PATCH)) & 0xffff
	var h: int = (xi * 73856093) ^ (zi * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h >> 8) & 0xffff) / 32767.5 - 1.0


# --- light and air -----------------------------------------------------------

## Everything about the light and the air at one hour of the day. The numbers the
## [Environment] is built from and the numbers [method haze] predicts come from
## this one dictionary, so a test can assert on how thick the air actually looks
## rather than on what the code claims.
static func atmosphere(hour: Hour) -> Dictionary:
	match hour:
		Hour.NOON:
			return {
				"sun_angles": Vector3(-58.0, -138.0, 0.0),
				"sun_colour": Color(1.0, 0.97, 0.92),
				"sun_energy": 1.25,
				"ambient_colour": Color(0.56, 0.65, 0.82),
				"ambient_energy": 0.78,
				"sky_contribution": 0.6,
				"zenith": Color(0.13, 0.31, 0.70),
				"horizon": Color(0.64, 0.76, 0.89),
				"ground_horizon": Color(0.64, 0.76, 0.89),
				"ground_bottom": Color(0.36, 0.37, 0.35),
				"fog_colour": Color(0.64, 0.75, 0.88),
				# The clearest air of the three: high summer, and you can pick out
				# the far side of the massif from the middle of the bowl.
				"fog_density": 0.00036,
				"fog_sun_scatter": 0.15,
				"haze_top": 130.0,
				"haze_density": 0.0009,
				"tonemap_white": 2.8,
				"cloud_colour": Color(0.94, 0.95, 0.97),
				"cloud_base": Color(0.55, 0.62, 0.76),
				"cloud_glow": Color(1.0, 0.98, 0.92),
				"window_glow": Color(1.0, 0.80, 0.48),
				"window_glow_energy": 0.10,
			}
		Hour.EVENING:
			return {
				# A sun this low rakes the whole bowl: every ridge throws a
				# shadow the length of itself, which is the most shape the
				# terrain ever shows.
				"sun_angles": Vector3(-14.0, -104.0, 0.0),
				"sun_colour": Color(1.0, 0.74, 0.45),
				# Not brighter than noon. A sun this low has come through a great
				# deal more air than a sun overhead, and at 1.30 it was lighting
				# the near ground hard enough that the tonemapper had nothing left
				# for the distance.
				"sun_energy": 1.15,
				# Warmer and stronger than the hour would suggest. A 14° sun
				# leaves the entire inward face of the rim unlit, and on the
				# darker fill this scene originally had, the near cliffs came out
				# as black holes in the frame rather than as silhouettes.
				"ambient_colour": Color(0.46, 0.48, 0.66),
				"ambient_energy": 0.95,
				"sky_contribution": 0.45,
				"zenith": Color(0.10, 0.17, 0.44),
				"horizon": Color(0.88, 0.60, 0.38),
				"ground_horizon": Color(0.72, 0.50, 0.36),
				"ground_bottom": Color(0.26, 0.24, 0.28),
				# Dusty mauve, well under the horizon it sits against. The first
				# version of this hour used a bright warm haze at the sky's own
				# colour and nearly twice this density, and the result was the
				# fault the morning preset has a comment warning about, only
				# worse: from 360 m the rim, the districts and the gorge were one
				# flat amber wash with no depth in it at all. Warm air is a
				# colour cast on the distance, not a curtain in front of it.
				"fog_colour": Color(0.55, 0.44, 0.46),
				# Heavier than noon, because evening haze is the reason the light
				# looks like this — but only by a third, not by double.
				"fog_density": 0.00048,
				"fog_sun_scatter": 0.26,
				"haze_top": 130.0,
				"haze_density": 0.0006,
				"tonemap_white": 2.4,
				"cloud_colour": Color(0.92, 0.80, 0.74),
				"cloud_base": Color(0.44, 0.42, 0.58),
				"cloud_glow": Color(1.0, 0.72, 0.44),
				"window_glow": Color(1.0, 0.72, 0.36),
				"window_glow_energy": 0.55,
			}
		_:
			# Morning is the default because it is the most legible: the sun is
			# high enough that nothing important sits in shadow, and low enough
			# that every facet still has a lit and an unlit face.
			return {
				"sun_angles": Vector3(-46.0, -122.0, 0.0),
				"sun_colour": Color(1.0, 0.94, 0.84),
				"sun_energy": 1.15,
				# Half the rim is backlit from any point in the bowl — that is what
				# a ring of mountains is — so the fill has to carry the shadow side
				# on its own. It is bright, blue, and mostly flat rather than sky:
				# a sky-dominated fill leaves anything facing sideways in the dark,
				# and a wall you cannot see the shape of is not a landmark.
				"ambient_colour": Color(0.66, 0.74, 0.88),
				"ambient_energy": 0.90,
				"sky_contribution": 0.4,
				"zenith": Color(0.16, 0.35, 0.68),
				"horizon": Color(0.63, 0.75, 0.88),
				"ground_horizon": Color(0.60, 0.70, 0.80),
				"ground_bottom": Color(0.34, 0.35, 0.34),
				# Deliberately darker and less blue than the sky behind it. Haze
				# the colour of the sky turns distant land into milk; haze a
				# shade under it keeps a mountain reading as mass.
				"fog_colour": Color(0.52, 0.67, 0.90),
				"fog_density": 0.00040,
				"fog_sun_scatter": 0.22,
				"haze_top": 120.0,
				"haze_density": 0.0006,
				"tonemap_white": 2.7,
				"cloud_colour": Color(0.92, 0.93, 0.96),
				# The base is a long way under the crown: a cumulus with a pale
				# underside is a cotton ball, and the shadow is what gives it volume.
				"cloud_base": Color(0.52, 0.60, 0.76),
				"cloud_glow": Color(1.0, 0.94, 0.86),
				"window_glow": Color(1.0, 0.78, 0.42),
				"window_glow_energy": 0.10,
			}


## How much of the air stands between the eye and a surface [param distance]
## metres away at [param altitude] metres up: 0 is perfectly clear, 1 is solid
## haze. This mirrors what Godot's exponential fog and height fog actually do to
## the frame, so a test can hold the aerial perspective to a shape.
##
## The whole reason this function exists: fog was previously configured in
## [constant Environment.FOG_MODE_DEPTH], where [member Environment.fog_density]
## is a fraction of the way to [member Environment.fog_depth_end] rather than a
## density per metre. At 0.00021 over 3200 m that is 0.02 % opacity — the air was
## documented as "the main altitude and speed cue" and was rendering nothing at
## all. Exponential fog takes a real per-metre density, which is a number you can
## reason about and assert on.
static func haze(distance: float, altitude: float, hour: Hour = Hour.MORNING) -> float:
	var air: Dictionary = atmosphere(hour)
	var depth: float = 1.0 - exp(-maxf(distance, 0.0) * float(air["fog_density"]))
	# Height fog in Godot is a max() against the depth fog and takes no account
	# of distance, so it can only ever be a gentle wash: enough that climbing out
	# of the valley visibly clears the air, never enough to fog a bird you are
	# chasing thirty metres away.
	var above: float = altitude - float(air["haze_top"])
	var layer: float = 1.0 - exp(minf(0.0, above * float(air["haze_density"])))
	return maxf(depth, layer)


## The sky. Baked once — it never changes within an hour, and re-rendering its
## radiance every frame on a headset is pure waste.
static func sky(hour: Hour = Hour.MORNING) -> Sky:
	var air: Dictionary = atmosphere(hour)
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = air["zenith"]
	material.sky_horizon_color = air["horizon"]
	material.ground_horizon_color = air["ground_horizon"]
	material.ground_bottom_color = air["ground_bottom"]
	# A tight, definite sun disc. The sun is the only fixed point in a world with
	# no compass, and a soft 10° smear of one is not a landmark.
	material.sun_angle_max = 4.0
	material.sun_curve = 0.08
	var result := Sky.new()
	result.sky_material = material
	result.process_mode = Sky.PROCESS_MODE_QUALITY
	result.radiance_size = Sky.RADIANCE_SIZE_128
	return result


## The whole atmosphere as an [Environment], sky included.
static func environment(hour: Hour = Hour.MORNING) -> Environment:
	var air: Dictionary = atmosphere(hour)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky(hour)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Part sky, part flat fill. Pure sky ambient makes anything the sun cannot
	# reach — the shadow side of the rim, the floor of the gorge — read as
	# near-black blue, and a canyon whose walls you cannot see is a canyon you
	# cannot fly down. The fill lifts the shadows without flattening the lit
	# faces, which are still carrying the shape of the ground.
	env.ambient_light_sky_contribution = air["sky_contribution"]
	env.ambient_light_color = air["ambient_colour"]
	env.ambient_light_energy = air["ambient_energy"]
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = air["tonemap_white"]

	# Aerial perspective. This is the main cue for how high and how fast you are,
	# and the only thing that makes a 2.4 km world read as 2.4 km rather than as
	# a diorama. Exponential, because haze is exponential and because the number
	# is then a real density per metre — see [method haze].
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = air["fog_colour"]
	env.fog_density = air["fog_density"]
	# Warm the haze toward the sun. Free, and it means the direction you are
	# facing is legible from the colour of the air alone.
	env.fog_sun_scatter = air["fog_sun_scatter"]
	# The sky is already the colour of the far air; fogging it as well only mutes
	# the one gradient the horizon has.
	env.fog_sky_affect = 0.12
	env.fog_height = air["haze_top"]
	env.fog_height_density = air["haze_density"]
	return env


## The sun. One directional light, warm, with shadows: shading is most of what
## tells you the shape of the ground rushing past, and a flat-lit landscape reads
## as a blur at 50 m/s.
static func sun(hour: Hour = Hour.MORNING, mobile: bool = false) -> DirectionalLight3D:
	var air: Dictionary = atmosphere(hour)
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = air["sun_angles"]
	light.light_color = air["sun_colour"]
	light.light_energy = air["sun_energy"]
	light.shadow_enabled = true
	# Shadow splits are the single most expensive thing in this scene: each one
	# re-renders every tree in range into the shadow atlas, and this world is
	# mostly trees. A headset gets two shallow splits; a desktop can afford four.
	if mobile:
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		light.directional_shadow_max_distance = 110.0
	else:
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		light.directional_shadow_max_distance = 260.0
	# A low sun grazes the terrain, and a grazing angle is where shadow acne
	# lives. Biased for the shallowest hour rather than per-hour, so switching
	# the time of day can never introduce a stripe across the ground.
	light.shadow_normal_bias = 2.0
	light.shadow_blur = 1.2
	return light


## Which hour to build. Chosen with [code]--sky=morning|noon|evening[/code] so a
## screenshot pass can walk the whole day without editing anything.
static func hour_from_args(fallback: Hour = Hour.MORNING) -> Hour:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() != 2 or parts[0] != "sky":
			continue
		return hour_named(parts[1], fallback)
	return fallback


static func hour_named(name: String, fallback: Hour = Hour.MORNING) -> Hour:
	match name.to_lower():
		"morning":
			return Hour.MORNING
		"noon":
			return Hour.NOON
		"evening":
			return Hour.EVENING
	return fallback


static func hour_name(hour: Hour) -> String:
	match hour:
		Hour.NOON:
			return "noon"
		Hour.EVENING:
			return "evening"
		_:
			return "morning"
