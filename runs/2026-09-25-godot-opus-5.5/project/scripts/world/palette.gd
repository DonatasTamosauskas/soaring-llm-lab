class_name Palette
extends RefCounted
## The world's colours and shared materials: one limited, warm-afternoon
## palette so every district reads as one place.
##
## Owned by the world area; other areas may read it (UI tints, bird accents,
## VFX) but should not add colours here. Colours are authored in sRGB; the
## shared materials treat vertex colours as sRGB.
##
## Rules the palette follows (checked by tests/unit/world/palette_test.gd):
## - Nothing but snow and cloud is authored brighter than ~0.9 luminance, so
##   sunlit facets never clip to white and keep their shape.
## - Surfaces that meet (bark/leaf, roof/wall, wire/sky) differ in value, not
##   only hue: at a distance haze eats hue first.

const C := {
	# --- ground ---
	&"grass": Color("7fa65a"),
	&"grass_light": Color("98b865"),
	&"grass_dark": Color("5f8a4b"),
	&"forest_floor": Color("5a7642"),
	&"leaf_litter": Color("76703f"),
	&"meadow": Color("9fbb62"),
	&"meadow_flower": Color("b9c46a"),
	&"wheat": Color("d6b865"),
	&"wheat_dark": Color("c49f52"),
	&"field_green": Color("86ad50"),
	&"ploughed": Color("8b6a4c"),
	&"ploughed_dark": Color("75573e"),
	&"path": Color("c4ae84"),
	&"cobble": Color("a79d8f"),
	&"sand": Color("dccb97"),
	&"mud": Color("8f7d62"),
	# --- rock and mountain ---
	&"rock": Color("9a9086"),
	&"rock_light": Color("b5ab9c"),
	&"rock_dark": Color("625b55"),
	&"sandstone": Color("c39a72"),
	&"sandstone_dark": Color("a57e5c"),
	&"sandstone_light": Color("d2b08a"),
	# The soft, pale bed the swallows dig into (between sandstone and its
	# light tone, a little yellower: it reads as sand, not rock).
	&"sand_bed": Color("d6a87a"),
	&"scree": Color("9d9486"),
	&"mountain_grass": Color("6f9255"),
	&"mountain_rock": Color("7a7773"),
	&"snow": Color("f3f4f1"),
	&"far_mountain": Color("8195ad"),
	# --- water ---
	&"water_shallow": Color("63aebb"),
	&"water": Color("41849c"),
	&"water_deep": Color("2e6682"),
	&"foam": Color("e4eef0"),
	# --- wood and bark ---
	&"bark": Color("6b4f3b"),
	&"bark_dark": Color("4f3a2b"),
	&"bark_birch": Color("dcd6c8"),
	&"bark_birch_dark": Color("3f3a36"),
	&"bark_pine": Color("8a5a3c"),
	&"wood": Color("8e6948"),
	&"wood_light": Color("b38c60"),
	&"wood_dark": Color("5a4331"),
	&"barn_red": Color("a4473b"),
	&"barn_red_dark": Color("843a31"),
	&"hay": Color("dcc070"),
	# --- foliage ---
	&"leaf": Color("6c9f48"),
	&"leaf_light": Color("8cba56"),
	&"leaf_dark": Color("4d7e3b"),
	&"leaf_autumn": Color("d38b3c"),
	&"leaf_gold": Color("d2b24a"),
	&"conifer": Color("3f6c47"),
	&"conifer_dark": Color("305739"),
	&"hedge": Color("567f3f"),
	&"hedge_dark": Color("466c34"),
	&"blossom": Color("f0c6cf"),
	&"fruit": Color("c5453a"),
	&"reed": Color("a4a55c"),
	&"flower_red": Color("d4574a"),
	&"flower_white": Color("ece8dc"),
	&"flower_blue": Color("7d8fd0"),
	&"flower_yellow": Color("e8c64a"),
	# --- buildings ---
	&"wall_white": Color("eae3d3"),
	&"wall_cream": Color("e6d3a9"),
	&"wall_ochre": Color("d8a961"),
	&"wall_pink": Color("e0b3a1"),
	&"wall_blue": Color("b7c7cc"),
	&"wall_sage": Color("bfc9a2"),
	&"stone": Color("b8ae9f"),
	&"stone_dark": Color("8f8579"),
	&"plinth": Color("9b9184"),
	&"roof_red": Color("b1543f"),
	&"roof_terracotta": Color("c46b45"),
	&"roof_slate": Color("5f6774"),
	&"roof_brown": Color("7b5341"),
	&"roof_moss": Color("6e7a4f"),
	&"trim": Color("f1ece1"),
	&"shutter_green": Color("5d7f5a"),
	&"shutter_blue": Color("587690"),
	&"window_dark": Color("2f3642"),
	&"interior_wall": Color("e6d5b3"),
	&"rug": Color("a8473f"),
	&"interior_floor": Color("946f4e"),
	# Enclosed interiors get sky ambient only: authored lighter than they
	# should look so they read as surfaces, not voids, in VR.
	&"interior_dark": Color("63574b"),
	&"tank_inside": Color("8e897f"),
	&"hollow_inside": Color("80634a"),
	# Burrow and nest-hole mouths: meant to read as dark holes from metres
	# away (they are the only near-black in the palette).
	&"burrow": Color("2d2620"),
	# A burrow's throat: shaded, between the sunlit sill and the dark chamber.
	&"burrow_throat": Color("5e4a38"),
	&"door": Color("6d4a35"),
	&"metal": Color("8c9399"),
	&"metal_dark": Color("596066"),
	&"rust": Color("9b5b3b"),
	&"tank": Color("a8b0b0"),
	&"wire": Color("3b3935"),
	&"insulator": Color("d8d2c3"),
	&"pole": Color("6f5642"),
	&"bell": Color("b08d4a"),
	&"beacon": Color("d8473a"),
	&"mast_white": Color("e4e1da"),
	&"mast_red": Color("c9483b"),
	# --- sky, light, effects ---
	&"sky_top": Color("5a95d4"),
	&"sky_horizon": Color("bcd6e6"),
	&"sky_ground": Color("9fb2a0"),
	&"fog": Color("c4d8e3"),
	&"sun": Color("fff0d4"),
	&"ambient": Color("b6c8dc"),
	&"cloud": Color("fbfbf8"),
	&"cloud_shade": Color("d9e0e8"),
	&"pollen": Color("fff2b0"),
	&"dust": Color("f2e6cc"),
}

## Lighting presets. "day" is the default warm afternoon; "dusk" is the
## alternate light used for screenshots and possibly a later time-of-day.
const LIGHT := {
	&"day": {
		"sky_top": Color("5a95d4"), "sky_horizon": Color("bcd6e6"),
		"ground_horizon": Color("a9b8a6"), "ground_bottom": Color("6f7f6c"),
		"fog": Color("c4d8e3"), "fog_density": 0.00042, "fog_sky_affect": 0.2,
		"sun": Color("fff0d4"), "sun_energy": 1.25, "sun_elev": 47.0, "sun_azim": -38.0,
		"ambient": Color("b6c8dc"), "ambient_energy": 0.65, "sky_energy": 1.0,
		"cloud": Color("fbfbf8"), "cloud_shade": Color("d6dee8"),
		# Thermal motes are unshaded: their colour is set per light.
		"motes": Color("fff2b0"),
	},
	&"dusk": {
		"sky_top": Color("3f5a9c"), "sky_horizon": Color("f4a86c"),
		"ground_horizon": Color("c08a6a"), "ground_bottom": Color("4f4452"),
		"fog": Color("d9a489"), "fog_density": 0.00036, "fog_sky_affect": 0.18,
		"sun": Color("ffae62"), "sun_energy": 1.45, "sun_elev": 11.0, "sun_azim": -70.0,
		"ambient": Color("8f86b4"), "ambient_energy": 0.5, "sky_energy": 1.0,
		"cloud": Color("f8c09a"), "cloud_shade": Color("8f7fa6"),
		"motes": Color("c99873"),
	},
}

static var _solid: StandardMaterial3D
static var _paving: StandardMaterial3D
static var _foliage: ShaderMaterial
static var _water: ShaderMaterial
static var _cloud: StandardMaterial3D


## A palette colour by name. Unknown names are loud (magenta) on purpose.
static func c(key: StringName) -> Color:
	if C.has(key):
		return C[key]
	push_warning("[world] Palette: unknown colour %s" % key)
	return Color.MAGENTA


## Colour nudged in value by v (-1..1, small), warmer when brighter: the
## per-facet variation that makes flat shading read as carved rather than
## plastic.
static func vary(col: Color, v: float) -> Color:
	return Color(
		clampf(col.r * (1.0 + v * 1.1), 0.0, 1.0),
		clampf(col.g * (1.0 + v), 0.0, 1.0),
		clampf(col.b * (1.0 + v * 0.8), 0.0, 1.0),
		col.a)


## The one opaque material shared by all static world geometry: flat
## vertex-coloured facets, no textures, rough and barely specular.
static func solid_material() -> StandardMaterial3D:
	if _solid == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = 0.92
		m.metallic_specular = 0.25
		m.resource_name = "world_solid"
		_solid = m
	return _solid


## The solid material for paving laid over the ground (the street and the
## square: their top is PAVING_TOP 0.2 m over the grass under them), drawn
## PAVING_DEPTH_STEPS steps of a 24-bit depth buffer nearer than it is.
## Integration hygiene (2026-09-27): on the Quest (Mobile renderer, D24
## depth) a 0.2 m gap is within two depth steps from ~120 m for a sparrow
## (near plane 8.5 mm) and ~350 m for an eagle, where the grass flickered
## through the cobbles. BaseMaterial3D's z clip scale (Godot 4.5+: clip z =
## mix(w, z, scale), never in the shadow pass) with scale = 1 - k 2^-24
## adds k steps of reverse-Z depth to everything well past the near plane:
## a constant polygon offset that settles the tie at every distance and
## moves nothing really in front of the paving by more than a hair's
## breadth (3 steps: 2 mm at 10 m for a sparrow). The look is solid's own
## (the same generated shader). docs/INTEGRATION.md, "Depth precision".
const PAVING_DEPTH_STEPS := 3


static func paving_material() -> StandardMaterial3D:
	if _paving == null:
		var m := solid_material().duplicate() as StandardMaterial3D
		m.use_z_clip_scale = true
		m.z_clip_scale = 1.0 - float(PAVING_DEPTH_STEPS) / 16777216.0
		m.resource_name = "world_paving"
		_paving = m
	return _paving


## Vegetation: same look as solid, plus a gentle wind sway weighted by vertex
## alpha (trunks 0, leaf tips 1). Amplitude is a few centimetres so the
## static colliders stay honest.
static func foliage_material() -> ShaderMaterial:
	if _foliage == null:
		var sh := Shader.new()
		sh.code = FOLIAGE_SHADER
		var m := ShaderMaterial.new()
		m.shader = sh
		m.resource_name = "world_foliage"
		_foliage = m
	return _foliage


static func water_material() -> ShaderMaterial:
	if _water == null:
		var sh := Shader.new()
		sh.code = WATER_SHADER
		var m := ShaderMaterial.new()
		m.shader = sh
		m.resource_name = "world_water"
		_water = m
	return _water


## Clouds: lit but never shadowed, with a high ambient floor so their
## undersides stay soft.
static func cloud_material() -> StandardMaterial3D:
	if _cloud == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = 1.0
		m.metallic_specular = 0.0
		m.disable_receive_shadows = true
		m.emission_enabled = true
		m.emission = Color(0.32, 0.34, 0.38)
		m.resource_name = "world_cloud"
		_cloud = m
	return _cloud


const FOLIAGE_SHADER := """
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

// Wind sway for trees and hedges. COLOR.a is the sway weight (0 at the
// trunk, 1 at leaf tips). World position feeds the phase so neighbouring
// trees don't move in lockstep.
uniform float sway = 0.06;
varying vec3 v_col;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = COLOR.a;
	float ph = wp.x * 0.11 + wp.z * 0.07;
	VERTEX.x += sin(TIME * 1.3 + ph) * sway * w;
	VERTEX.z += cos(TIME * 1.1 + ph * 1.3) * sway * 0.7 * w;
	VERTEX.y += sin(TIME * 1.7 + ph * 0.8) * sway * 0.3 * w;
	// Vertex colours are authored in sRGB.
	v_col = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
"""

const WATER_SHADER := """
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

// Flat-shaded low-poly water: vertices bob, the fragment derives a faceted
// normal from screen-space derivatives so every triangle glints on its own.
uniform float amp = 0.07;
varying vec3 v_col;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += (sin(TIME * 0.9 + wp.x * 0.35 + wp.z * 0.21) + sin(TIME * 1.3 - wp.z * 0.29 + wp.x * 0.13)) * amp;
	v_col = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
}

void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = v_col;
	ROUGHNESS = 0.18;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
"""
