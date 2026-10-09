class_name BirdModels
extends RefCounted
## Factory for bird visuals, and the shared resources behind them. Owned by
## the birds (art) area.
##
## Every species is a procedural low-poly mesh (BirdMeshBuilder, data in
## BirdSpecies) at three levels of detail, all drawn with ONE ShaderMaterial
## (scripts/birds/bird.gdshader: vertex colours, flat shading, wing
## animation in the vertex shader). Meshes are built on first use of a
## species (all three levels at once, about 8 ms) and cached; prewarm()
## builds all 30 up front (about 80 ms on an M1 Pro, measured by the budget
## suite) for a loading screen.
##
##   var m := BirdModels.create(&"hawk")   # a BirdModel (Node3D)
##   m.scale = Vector3.ONE * wingspan      # authored at wingspan 1.0
##   add_child(m); m.flap_phase = ...      # see BirdModel

const LOD_COUNT := 3
const SHADER := preload("res://scripts/birds/bird.gdshader")
## The animation envelope around the rest mesh (wings up/down/folded, tail
## cocked, legs down), so culling never clips a flapping wing.
const ANIM_AABB := AABB(Vector3(-0.56, -0.5, -0.62), Vector3(1.12, 1.0, 1.24))
## Wingspan class boundary for the triangle budget: LOD0 <= 300 triangles
## below it (moth .. starling), <= 600 from it (pigeon .. eagle).
const LARGE_SPAN := 0.5

## Highlight hues (sRGB) the shader tints edible / dangerous birds with, for
## UI cues that should match: blue-violet #4020f0 = worth eating, magenta
## #ff00c8 = can eat you. Both are far (Oklab) from every colour of the
## world's palette, so a highlighted bird stands out over sky, fields,
## forest, water and the village's red roofs alike (the orange-red used
## before vanished against the roofs); they also differ in lightness, and
## edible pulses slowly, danger quickly, for colour-blind players.
const HIGHLIGHT_EDIBLE := Color("4020f0")
const HIGHLIGHT_DANGER := Color("ff00c8")
## A highlighted bird reads by itself once the thinner side of its body
## covers this angle too (radians; 0.126 deg, 2.5 px on a Quest Pro):
## slim-bodied species (moth, swallow, gull...) need a wider span than
## BirdModel.MIN_HIGHLIGHT_ANGLE. Below it the bird is tinted in the hue (its
## plumage cannot be told apart at that size anyway); above it the tint
## eases out and the bird wears its own colours, with the marker around it.
const MIN_HIGHLIGHT_BODY := 0.0022
## The readable angle travels to the shader in the vertex colours' alpha, as
## a share of this (radians; the moth's 1.6 deg is the widest).
const READABLE_MAX := 0.032

static var _material: ShaderMaterial
static var _meshes := {}
static var _info := {}
static var _cam_frame := -1
static var _cam_cache := {}


## A new model of `species` (an id from SizeRules.SPECIES); unknown ids draw
## a sparrow (with a warning).
static func create(species: StringName) -> BirdModel:
	var m := BirdModel.new()
	m.name = "BirdModel"
	m.species = species
	return m


## The one material every bird is drawn with.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		_material.resource_name = "BirdMaterial"
	return _material


## The mesh of a species at a level of detail (0 = full), cached. The first
## call for a species builds all its levels at once (about 8 ms on an M1), so
## a bird crossing a LOD threshold mid-flight never builds a mesh inside the
## frame's sync (that was a 17 ms hitch the first time a species went far).
static func mesh(species: StringName, lod: int = 0) -> ArrayMesh:
	var sp := species if BirdSpecies.has(species) else &"sparrow"
	var l := clampi(lod, 0, LOD_COUNT - 1)
	var m: ArrayMesh = _meshes.get("%s:%d" % [sp, l])
	if m != null:
		return m
	for k in LOD_COUNT:
		_build_mesh(sp, k)
	return _meshes["%s:%d" % [sp, l]]


static func _build_mesh(sp: StringName, l: int) -> void:
	var key := "%s:%d" % [sp, l]
	if _meshes.has(key):
		return
	var norm := {}
	if l > 0:
		_build_mesh(sp, 0)
		norm = _info[sp]["norm"]
	var res := BirdMeshBuilder.build(sp, l, norm)
	var m := ArrayMesh.new()
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, res["arrays"], [], {}, fmt)
	m.surface_set_material(0, material())
	m.custom_aabb = ANIM_AABB
	m.resource_name = "bird_%s_lod%d" % [sp, l]
	_meshes[key] = m
	if l == 0:
		_info[sp] = {"norm": res["norm"], "tip": res["tip"], "body_aabb": res["body_aabb"], "tris": [0, 0, 0]}
	_info[sp]["tris"][l] = res["tris"]


## Drops the cached meshes (tests: to see what a first use builds). Only
## while no bird is drawn.
static func _forget_meshes() -> void:
	if BirdBatch.count() > 0 or BirdBatch.markers().size() > 0:
		push_warning("[birds] meshes still in use; not forgotten")
		return
	_meshes.clear()
	_info.clear()


static var _marker: ArrayMesh


## The highlight marker's mesh (a ring and a triangle, drawn around
## highlighted birds by one MultiMesh per world: BirdBatch), with the one
## bird material.
static func marker_mesh() -> ArrayMesh:
	if _marker == null:
		_marker = ArrayMesh.new()
		var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
		_marker.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BirdMeshBuilder.build_marker(), [], {}, fmt)
		_marker.surface_set_material(0, material())
		# The shader places it (a far marker reaches well beyond the bird);
		# its batch is never culled anyway (BirdBatch).
		_marker.custom_aabb = ANIM_AABB
		_marker.resource_name = "bird_marker"
	return _marker


## Builds every mesh now (e.g. behind a loading screen).
static func prewarm(ids: Array = BirdSpecies.IDS) -> void:
	for sp in ids:
		for l in LOD_COUNT:
			mesh(sp, l)


static func triangle_count(species: StringName, lod: int = 0) -> int:
	mesh(species, lod)
	return _info[species if BirdSpecies.has(species) else &"sparrow"]["tris"][clampi(lod, 0, LOD_COUNT - 1)]


## Triangle budget of LOD0 for a species (300 small / 600 large).
static func triangle_budget(species: StringName) -> int:
	var span: float = SizeRules.species_data(species).get("span", 0.24)
	return 600 if span >= LARGE_SPAN else 300


## The wingspan angle (radians) from which a highlighted bird of this
## species reads by itself: BirdModel.MIN_HIGHLIGHT_ANGLE, or wider for a
## slim body. Below it the shader tints the bird in the state's hue; from
## bird.gdshader's tint_end (1.8) x it the bird is drawn in its own plumage.
## The meshes carry exactly this value (8 bits of COLOR.a).
static func min_highlight_angle(species: StringName) -> float:
	var sp := species if BirdSpecies.has(species) else &"sparrow"
	mesh(sp, 0)
	return float(_info[sp]["norm"]["readable"])


## The readable angle for a body of this size (span 1.0 units), quantised as
## the meshes store it.
static func readable_angle_for_body(size: Vector3) -> float:
	var a := maxf(BirdModel.MIN_HIGHLIGHT_ANGLE, MIN_HIGHLIGHT_BODY / maxf(minf(size.x, size.y), 0.01))
	return roundf(clampf(a / READABLE_MAX, 0.0, 1.0) * 255.0) / 255.0 * READABLE_MAX


## The body loft's bounds in model space (span 1.0).
static func body_aabb(species: StringName) -> AABB:
	mesh(species, 0)
	return _info[species if BirdSpecies.has(species) else &"sparrow"]["body_aabb"]


## {scale, centre}: how the builder mapped authoring units to model space.
static func normalisation(species: StringName) -> Dictionary:
	mesh(species, 0)
	return _info[species if BirdSpecies.has(species) else &"sparrow"]["norm"]


## Right wingtip vertex [pos, normal, c0, c1, c2, c3, uv, uv2] (see BirdPose).
## Called per frame by wingtip trails: a direct lookup once built.
static func tip_record(species: StringName) -> Array:
	var info: Variant = _info.get(species)
	if info == null:
		mesh(species, 0)
		info = _info[species if BirdSpecies.has(species) else &"sparrow"]
	return info["tip"]


## A species' main colours (sRGB): for FX, UI swatches, audio-visual cues.
static func palette(species: StringName) -> Dictionary:
	var out := {}
	for slot in ["back", "belly", "breast", "crown", "cov", "flight", "prim", "under_cov", "under_flight", "tail", "beak", "leg"]:
		out[slot] = BirdSpecies.color(species, slot)
	if species == &"moth":
		out["cov"] = BirdSpecies.color(species, "fore")
		out["flight"] = BirdSpecies.color(species, "fore_band")
		out["prim"] = BirdSpecies.color(species, "fore")
		out["under_cov"] = BirdSpecies.color(species, "fore_under")
		out["under_flight"] = BirdSpecies.color(species, "hind_under")
	return out


## Colours for the player's own first-person wings (VR area), sRGB:
## upper surface (coverts, flight feathers, primaries/tip), underside
## (coverts, flight feathers) and a pattern accent (wing bar, black tips...).
static func wing_palette(species: StringName) -> Dictionary:
	var p := palette(species)
	var d := BirdSpecies.data(species)
	var accent: Color = p["flight"]
	var cols: Dictionary = d["colors"]
	for k in ["bar", "tip", "edge", "te", "fore_band"]:
		if cols.has(k):
			accent = BirdSpecies.color(species, k)
			break
	return {
		"upper_coverts": p["cov"], "upper_flight": p["flight"], "upper_primaries": p["prim"],
		"under_coverts": p["under_cov"], "under_flight": p["under_flight"], "accent": accent,
	}


## The position of the camera drawing `vp` this frame (INF when none), cached
## per frame for LOD selection.
static func camera_position(vp: Viewport) -> Vector3:
	if vp == null:
		return Vector3.INF
	# Refreshed once per BirdBatch sync (once per drawn frame in the game;
	# tests sync many times per engine frame and move cameras in between).
	var f := BirdBatch.syncs
	if f != _cam_frame:
		_cam_frame = f
		_cam_cache.clear()
	var id := vp.get_instance_id()
	var c: Variant = _cam_cache.get(id)
	if c != null:
		return c
	var cam := vp.get_camera_3d()
	var p := cam.global_position if cam != null else Vector3.INF
	_cam_cache[id] = p
	return p
