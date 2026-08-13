class_name BirdMesh
extends RefCounted

## Every bird in the game, as geometry: five silhouettes built from the same
## faceted, unspecular language the world is built in.
##
## Two things drive every decision in this file.
##
## [b]Silhouette is a game mechanic.[/b] You have to decide "eat it or run from
## it" in about a fifth of a second, at 40 m/s, against a shape whose distance
## you cannot judge. Apparent size alone cannot carry that — a swift ten metres
## away and an eagle two hundred metres away subtend the same angle. So the
## species a bird wears is chosen by its [i]size class[/i] and the shapes are
## ordered: pointed and forked when small, broad and slotted and fan-tailed when
## large, with the count of splayed primary "fingers" going 0, 2, 3, 4, 5 up the
## classes. The number of fingers is a thing you can read off a black shape
## against the sky, and it never lies about how big the bird is.
##
## [b]Draw cost is one material and three meshes per species.[/b] Meshes are
## built once and cached, so twenty-six birds of four species share four sets of
## geometry. Colour, threat glow and wing flex are all [code]instance
## uniform[/code]s on a [b]single[/b] [ShaderMaterial] shared by the whole flock
## and by the player's own wings — the flock adds exactly one material to the
## scene no matter how many birds are in it.
##
## Bird space is Godot space: the nose points at −Z, the wings run along ±X, up
## is +Y. That is what [method Basis.looking_at] hands you, so a rig can be
## pointed down its own velocity vector with no fixup.

## The five silhouettes, ordered by the size class they belong to. The order is
## load-bearing: [method species_for_size] walks it, and [BirdTests] asserts that
## every step up it is a step up in body length and wingspan, so a growing bird
## can never appear to shrink as it crosses a class boundary.
enum Species { SWIFT, FALCON, CORVID, SEABIRD, RAPTOR }

## Upper size bound of each class but the last. A player starts at 1.0 (falcon)
## and tops out at 8.0 (raptor), so the ladder is climbed roughly evenly across a
## whole run.
const CLASS_BOUNDS: PackedFloat32Array = [0.60, 1.20, 2.40, 4.50]
## How far past a boundary a bird has to get before it changes species. Without
## it a bird hovering on a boundary rebuilds its meshes every frame; with it, the
## change happens once and stays.
const CLASS_HYSTERESIS: float = 0.08

## Which way round the loft runs: the nose sits this far forward of the body
## origin as a fraction of body length, the tail root the rest of the way back.
const NOSE_FRACTION: float = 0.60

## Cross-section of the body, as fractions of body length: how far along, half
## width, half height, and how far the section's centre sits above the spine.
## One profile for every bird — species stretch and scale it rather than
## replacing it, which is what keeps five silhouettes reading as one animal.
const BODY_STATIONS: Array = [
	[0.00, 0.020, 0.024, 0.030],
	[0.07, 0.082, 0.098, 0.036],
	[0.15, 0.098, 0.116, 0.030],
	[0.26, 0.060, 0.068, 0.006],
	[0.44, 0.148, 0.170, -0.020],
	[0.64, 0.132, 0.148, -0.030],
	[0.84, 0.082, 0.094, -0.012],
	[1.00, 0.034, 0.042, 0.004],
]
## Where the head stops and the neck begins, in station fractions. Everything
## ahead of this is scaled by the species' head size.
const HEAD_END: float = 0.20
## Six-sided sections: a vertex on top and a vertex underneath, flats at the
## sides. The keel down the middle of the breast is most of why a hexagon reads
## as a bird and a cylinder reads as a pipe.
const RING: int = 6

## Everything that makes one species that species. Lengths are in metres for a
## size-1.0 bird; a rig scales them.
const PROFILES: Dictionary = {
	Species.SWIFT: {
		"body": 0.72, "head": 0.86, "beak": 0.10, "hook": 0.10,
		"span": 1.12, "chord": 0.26, "sweep": 0.74, "wrist": 0.40,
		"wrist_chord": 0.70, "tip_chord": 0.14, "fingers": 0, "splay": 0.0,
		"coverts": false, "alula": false,
		"tail": 0.42, "feathers": 5, "fan": 0.32, "shape": -0.55,
		"beat": 3.3,
	},
	Species.FALCON: {
		"body": 0.95, "head": 1.00, "beak": 0.12, "hook": 0.35,
		"span": 1.20, "chord": 0.38, "sweep": 0.46, "wrist": 0.46,
		"wrist_chord": 0.80, "tip_chord": 0.22, "fingers": 2, "splay": 0.16,
		"coverts": true, "alula": false,
		"tail": 0.48, "feathers": 5, "fan": 0.26, "shape": -0.04,
		"beat": 2.5,
	},
	Species.CORVID: {
		"body": 1.10, "head": 1.10, "beak": 0.16, "hook": 0.15,
		"span": 1.31, "chord": 0.56, "sweep": 0.30, "wrist": 0.48,
		"wrist_chord": 0.92, "tip_chord": 0.30, "fingers": 3, "splay": 0.26,
		"coverts": true, "alula": true,
		"tail": 0.56, "feathers": 7, "fan": 0.30, "shape": 0.30,
		"beat": 2.0,
	},
	Species.SEABIRD: {
		"body": 1.26, "head": 0.94, "beak": 0.22, "hook": 0.20,
		"span": 1.62, "chord": 0.34, "sweep": 0.34, "wrist": 0.44,
		"wrist_chord": 0.88, "tip_chord": 0.26, "fingers": 4, "splay": 0.18,
		"coverts": true, "alula": true,
		"tail": 0.40, "feathers": 5, "fan": 0.24, "shape": 0.10,
		"beat": 1.5,
	},
	Species.RAPTOR: {
		"body": 1.55, "head": 1.24, "beak": 0.18, "hook": 0.60,
		"span": 1.82, "chord": 0.66, "sweep": 0.24, "wrist": 0.50,
		"wrist_chord": 0.88, "tip_chord": 0.34, "fingers": 5, "splay": 0.34,
		"coverts": true, "alula": true,
		"tail": 0.64, "feathers": 7, "fan": 0.42, "shape": 0.06,
		"beat": 1.15,
	},
}


# --- the vertex channels ------------------------------------------------------
#
# Vertex colour is not a colour on a bird: it is four masks the shared shader
# reads, which is how one material paints six plumages with pale bellies and
# dark wingtips and still bends a wing in the vertex stage.
#
#   R  pale     — countershading. 1 on the belly, 0 along the back.
#   G  dark     — beak, crown, primaries, tail band.
#   B  flex     — how much of the wing's spanwise bend this vertex takes. 0
#                 inboard of the wrist, 1 at the tip. Zero everywhere on a body.
#   A  glow     — self-illumination. A wing seen from underneath is backlit by
#                 the sky and a purely lit membrane collapses to a silhouette.

const MASK_BODY := Color(0.0, 0.0, 0.0, 0.10)
const MASK_BACK := Color(0.0, 0.22, 0.0, 0.10)
const MASK_BELLY := Color(1.0, 0.0, 0.0, 0.10)
const MASK_CROWN := Color(0.0, 0.55, 0.0, 0.10)
const MASK_BEAK := Color(0.0, 0.90, 0.0, 0.05)
const MASK_WING := Color(0.0, 0.0, 0.0, 0.50)
const MASK_COVERT := Color(0.18, 0.08, 0.0, 0.45)
const MASK_TIP := Color(0.0, 0.85, 0.0, 0.50)
const MASK_TAIL := Color(0.0, 0.10, 0.0, 0.45)


# --- the shared material ------------------------------------------------------

## One shader for every feather in the game.
##
## The three [code]instance uniform[/code]s are the whole trick. Plumage, threat
## glow and wing flex vary per [MeshInstance3D] while the material stays a single
## shared object, so a flock of twenty-six birds costs one material and one
## shader compile rather than twenty-six of each — and the same material paints
## the player's own wings, so the player is unarguably made of the same stuff as
## the things they are eating.
const BIRD_SHADER: String = """
shader_type spatial;
render_mode specular_disabled, cull_disabled;

uniform vec3 pale : source_color;
uniform vec3 dark : source_color;
uniform float glow = 0.30;

instance uniform vec4 plumage : source_color = vec4(0.5, 0.42, 0.34, 1.0);
instance uniform vec4 threat : source_color = vec4(0.0, 0.0, 0.0, 0.0);
// x: signed spanwise bend in radians at the tip, y: tip lift in metres.
instance uniform vec4 flex = vec4(0.0, 0.0, 0.0, 0.0);

void vertex() {
	float w = COLOR.b;
	if (w > 0.002) {
		// The wrist flex, done in the vertex stage instead of with a second node
		// per wing. A hinge would need the wrist position as a uniform; bending
		// about the shoulder with a weight that ramps from the wrist outward
		// costs one sin/cos and reads better anyway, because feathers curve.
		float a = flex.x * w;
		float s = sin(a);
		float c = cos(a);
		mat2 turn = mat2(vec2(c, s), vec2(-s, c));
		VERTEX.xz = turn * VERTEX.xz;
		NORMAL.xz = turn * NORMAL.xz;
		// Primaries flex upward under load. Free, and it is the difference
		// between a wing and a plank.
		VERTEX.y += flex.y * w * w;
	}
}

void fragment() {
	vec3 albedo = mix(plumage.rgb, pale, COLOR.r);
	albedo = mix(albedo, dark, COLOR.g);
	// Wings and tail are one-sided surfaces drawn from both sides, and the side
	// facing away is the underside — which on a bird is the pale one, and is
	// also the only side you ever see of a bird above you. A body never gets
	// here: its back faces are inside it.
	if (!FRONT_FACING) {
		// Spared where the feather is already dark: the black primaries and the
		// tail band are the one cue that survives being seen as a silhouette
		// from below, and washing them pale takes the whole read with it.
		albedo = mix(albedo, pale, 0.30 * (1.0 - COLOR.g));
		NORMAL = -NORMAL;
	}
	ALBEDO = albedo;
	EMISSION = albedo * COLOR.a * glow + threat.rgb * threat.a;
	ROUGHNESS = 1.0;
}
"""

## How far the countershading and the dark tips go. Both are palette colours —
## a bird's belly is the colour of the cream plumage and its primaries the
## colour of the charcoal one, so the flock stays inside the same seven colours
## it started with.
const PALE_MIX: float = 0.94
const DARK_MIX: float = 0.85
## Self-illumination on feathers, scaled by each vertex's own glow mask. Enough
## that a backlit wing is a shape rather than a hole; any more and a flock at
## dusk looks like a swarm of lanterns.
const GLOW: float = 0.22

static var _material: ShaderMaterial = null
static var _cache: Dictionary = {}


## The one material the whole flock shares. Built on first use and never rebuilt.
static func material() -> ShaderMaterial:
	if _material != null:
		return _material
	var shader := Shader.new()
	shader.code = BIRD_SHADER
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter(
		"pale", Palette.colour("plumage_cream").lerp(Palette.colour("cloud"), 1.0 - PALE_MIX)
	)
	m.set_shader_parameter(
		"dark", Palette.colour("plumage_char").darkened(1.0 - DARK_MIX)
	)
	m.set_shader_parameter("glow", GLOW)
	_material = m
	return _material


# --- size classes -------------------------------------------------------------

## Which silhouette a bird of [param size] wears. [param current] is the species
## it is wearing now, if any: a bird that has already changed keeps its shape
## until it is clearly past the boundary, so a bird sitting on 1.20 does not
## rebuild itself every frame.
static func species_for_size(size: float, current: int = -1) -> Species:
	var s: float = size if is_finite(size) else 1.0
	var index: int = 0
	while index < CLASS_BOUNDS.size() and s >= CLASS_BOUNDS[index]:
		index += 1
	if current >= 0 and current != index:
		# Hold the current species while inside the dead band around the boundary
		# it would have to cross to leave it.
		var edge: int = current if current < index else current - 1
		if edge >= 0 and edge < CLASS_BOUNDS.size():
			var bound: float = CLASS_BOUNDS[edge]
			if absf(s - bound) < bound * CLASS_HYSTERESIS:
				return current as Species
	return index as Species


static func profile(species: Species) -> Dictionary:
	return PROFILES.get(species, PROFILES[Species.FALCON])


## Tip to tip, in metres, for a size-1.0 bird. Used by the rig to place wings and
## by the tests to prove the size ladder never goes backwards.
static func wingspan(species: Species) -> float:
	return 2.0 * (shoulder(species).x + float(profile(species)["span"]))


## Where the right wing hangs off the body. The left is the mirror.
static func shoulder(species: Species) -> Vector3:
	var p: Dictionary = profile(species)
	var length: float = p["body"]
	return Vector3(
		_station_width(p, 0.44) * 0.80,
		length * 0.030,
		_station_z(length, 0.40)
	)


## Where the tail hinges.
static func tail_root(species: Species) -> Vector3:
	var p: Dictionary = profile(species)
	return Vector3(0.0, float(p["body"]) * 0.010, _station_z(float(p["body"]), 0.98))


# --- meshes -------------------------------------------------------------------

## Body, head and beak as one flat-shaded loft. [param headless] drops everything
## ahead of the neck, which is what the player's own body needs: their head is
## the camera, and a bird's skull drawn around it fills the view with the inside
## of a face.
static func body_mesh(species: Species, headless: bool = false) -> ArrayMesh:
	return _cached("body:%d:%s" % [species, headless], _build_body.bind(species, headless))


static func wing_mesh(species: Species, side: float) -> ArrayMesh:
	var sign_of: float = -1.0 if side < 0.0 else 1.0
	return _cached("wing:%d:%d" % [species, int(sign_of)], _build_wing.bind(species, sign_of))


static func tail_mesh(species: Species) -> ArrayMesh:
	return _cached("tail:%d" % species, _build_tail.bind(species))


## Meshes are immutable and identical for every bird of a species, so they are
## built once and handed out. This is what makes a twenty-six bird flock cost
## four sets of geometry rather than twenty-six.
static func _cached(key: String, builder: Callable) -> ArrayMesh:
	if _cache.has(key):
		return _cache[key]
	var mesh: ArrayMesh = builder.call()
	_cache[key] = mesh
	return mesh


# --- body ---------------------------------------------------------------------

static func _station_z(length: float, t: float) -> float:
	return lerpf(-NOSE_FRACTION * length, (1.0 - NOSE_FRACTION) * length, t)


static func _station_width(p: Dictionary, t: float) -> float:
	var best: Array = BODY_STATIONS[0]
	for station: Array in BODY_STATIONS:
		if absf(float(station[0]) - t) < absf(float(best[0]) - t):
			best = station
	return float(best[1]) * float(p["body"])


static func _build_body(species: Species, headless: bool) -> ArrayMesh:
	var p: Dictionary = profile(species)
	var length: float = p["body"]
	var head: float = p["head"]

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array = []
	var used: Array = []
	for station: Array in BODY_STATIONS:
		var t: float = station[0]
		if headless and t < HEAD_END:
			continue
		# The head is scaled about its own sections rather than modelled twice:
		# a raptor's skull is the same shape as a swift's, one and a half times
		# the size, which is exactly what the silhouette is supposed to say.
		var scale: float = head if t < HEAD_END else 1.0
		var half_width: float = float(station[1]) * length * scale
		var half_height: float = float(station[2]) * length * scale
		var lift: float = float(station[3]) * length
		var z: float = _station_z(length, t)
		var ring: Array = []
		for i in RING:
			var angle: float = TAU * float(i) / float(RING) + PI / float(RING)
			ring.append(Vector3(
				cos(angle) * half_width, sin(angle) * half_height + lift, z
			))
		rings.append(ring)
		used.append(station)

	for i in range(rings.size() - 1):
		var t0: float = float(used[i][0])
		for j in RING:
			var k: int = (j + 1) % RING
			# The face's own mid angle, not its first vertex's: a facet spanning
			# the top of the bird is a back facet, and painting it from the
			# vertex where it starts puts the spine's dark tone on the flank.
			var angle: float = TAU * (float(j) + 0.5) / float(RING) + PI / float(RING)
			var mask: Color = _body_mask(angle, t0)
			# Wound so the outside faces out. Reversed, the whole bird renders as
			# its own interior: still visible, because the shader draws both
			# sides, but lit as a back face and washed with the pale underside
			# tint — which is exactly what a player's own body looked like before
			# [method BirdTests._test_no_bird_is_inside_out] existed.
			_quad(
				tool, rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k], mask
			)

	# Caps, so the bird is a closed solid rather than a tube you can see down.
	var nose := Vector3(
		0.0, float(used[0][3]) * length, _station_z(length, float(used[0][0]))
	)
	var stern := Vector3(
		0.0, float(used[-1][3]) * length, _station_z(length, float(used[-1][0]))
	)
	for j in RING:
		var k: int = (j + 1) % RING
		_triangle(tool, nose, rings[0][j], rings[0][k], MASK_BODY)
		_triangle(tool, stern, rings[-1][k], rings[-1][j], MASK_BODY)

	if not headless:
		_build_beak(tool, p, length, head)
		_build_feet(tool, p, length)

	tool.generate_normals()
	return tool.commit()


## Pale underneath, dark over the crown. Countershading is the oldest trick in
## bird plumage and it does the same job here it does in life: it stops a solid
## shape from reading as a flat cutout when the light is behind it.
static func _body_mask(angle: float, t: float) -> Color:
	var up: float = clampf(sin(angle), 0.0, 1.0)
	var down: float = clampf(-sin(angle), 0.0, 1.0)
	# Three tones, not two: dark along the spine, plumage on the flanks, pale
	# underneath. Two tones leave a bird seen from directly above — which is what
	# the player sees of their own body — as one flat lozenge with no shape in it.
	var mask: Color = MASK_BODY.lerp(MASK_BACK, up * up)
	mask = mask.lerp(MASK_BELLY, down * down)
	if t < HEAD_END and sin(angle) > 0.0:
		mask = mask.lerp(MASK_CROWN, up)
	return mask


static func _build_beak(tool: SurfaceTool, p: Dictionary, length: float, head: float) -> void:
	var beak: float = float(p["beak"]) * length
	var root_z: float = _station_z(length, 0.04)
	var lift: float = float(BODY_STATIONS[1][3]) * length
	# Deep enough to be a bill rather than a needle: a beak drawn as a thin spike
	# reads as a beak in a diagram and as an antenna in a headset.
	var radius: float = float(BODY_STATIONS[1][1]) * length * head * 0.85
	# A hooked bill is the single cheapest predator cue there is, so it drops
	# further with the size class rather than staying a cone.
	var tip := Vector3(0.0, lift - beak * float(p["hook"]), root_z - beak)
	for i in 4:
		var a0: float = TAU * float(i) / 4.0 + PI / 4.0
		var a1: float = TAU * float(i + 1) / 4.0 + PI / 4.0
		var v0 := Vector3(cos(a0) * radius, sin(a0) * radius * 0.8 + lift, root_z)
		var v1 := Vector3(cos(a1) * radius, sin(a1) * radius * 0.8 + lift, root_z)
		_triangle(tool, tip, v0, v1, MASK_BEAK)


## Tucked feet under the rump. Two dark wedges — invisible at a hundred metres,
## and the difference between a bird and a dart when one is close enough to eat.
static func _build_feet(tool: SurfaceTool, p: Dictionary, length: float) -> void:
	var z: float = _station_z(length, 0.80)
	var drop: float = -float(BODY_STATIONS[6][2]) * length - length * 0.02
	var reach: float = length * 0.10
	for side: float in [-1.0, 1.0]:
		var hip := Vector3(side * length * 0.045, drop + length * 0.03, z)
		var toe := Vector3(side * length * 0.055, drop, z + reach)
		var heel := Vector3(side * length * 0.020, drop - length * 0.015, z + reach * 0.4)
		_triangle(tool, hip, toe, heel, MASK_BEAK)
		_triangle(tool, hip, heel, toe, MASK_BEAK)


# --- wings --------------------------------------------------------------------

static func _chord_at(p: Dictionary, u: float) -> float:
	var chord: float = p["chord"]
	var wrist: float = p["wrist"]
	if u <= wrist:
		return chord * lerpf(1.0, float(p["wrist_chord"]), u / maxf(wrist, 0.001))
	var v: float = (u - wrist) / maxf(1.0 - wrist, 0.001)
	return chord * lerpf(float(p["wrist_chord"]), float(p["tip_chord"]), v * 0.45 + v * v * 0.55)


## Quarter-chord line. Wings sweep back with span, which is what stops a wing
## from looking like a shelf bolted to a bird.
static func _sweep_at(p: Dictionary, u: float) -> float:
	return float(p["sweep"]) * float(p["span"]) * pow(u, 1.6)


static func _leading(p: Dictionary, u: float) -> float:
	return _sweep_at(p, u) - _chord_at(p, u) * 0.32


static func _trailing(p: Dictionary, u: float) -> float:
	return _sweep_at(p, u) + _chord_at(p, u) * 0.68


## Wings droop very slightly along the span so a gliding bird has a curve in it.
## Anything more belongs on the rig, where it can move.
static func _wing_height(p: Dictionary, u: float) -> float:
	return -float(p["span"]) * 0.02 * u * u


## Flex weight: nothing inboard of the wrist bends, everything outboard does,
## smoothly. See [constant BIRD_SHADER].
static func _flex_at(p: Dictionary, u: float) -> float:
	return smoothstep(float(p["wrist"]) * 0.7, 1.0, u)


static func _wing_point(p: Dictionary, side: float, u: float, z: float) -> Vector3:
	return Vector3(side * u * float(p["span"]), _wing_height(p, u), z)


## The same painted mask, carrying this vertex's own bend weight.
static func _wing_mask(base: Color, p: Dictionary, u: float) -> Color:
	var mask: Color = base
	mask.b = _flex_at(p, u)
	return mask


## Where along the chord the wing is deepest, and how deep, as fractions of the
## chord. The crease this puts down the span is doing two jobs: it is the camber
## that makes a wing look like a wing from in front, and it splits every panel
## into a leading strip and a trailing strip lit at different angles — which is
## what makes a flat-shaded wing read as layered feathers instead of as one sheet
## of card. An overlapping second surface would have done the same job and
## z-fought with itself for the privilege.
const CREST: float = 0.32
const CAMBER: float = 0.075


static func _build_wing(species: Species, side: float) -> ArrayMesh:
	var p: Dictionary = profile(species)
	var wrist: float = p["wrist"]
	var layered: bool = p["coverts"]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Arm: three cambered panels from shoulder to wrist, with a scalloped
	# trailing edge where the secondaries hang past it.
	var arm: int = 3
	for i in arm:
		var u0: float = wrist * float(i) / float(arm)
		var u1: float = wrist * float(i + 1) / float(arm)
		_panel(tool, p, side, u0, u1,
			MASK_COVERT if layered else MASK_WING, MASK_WING)
		var um: float = (u0 + u1) * 0.5
		var overhang: float = _chord_at(p, um) * 0.20
		_wing_tri(tool, p, side,
			_wing_point(p, side, u0, _trailing(p, u0)),
			_wing_point(p, side, u1, _trailing(p, u1)),
			_wing_point(p, side, um, _trailing(p, um) + overhang),
			u0, u1, um, MASK_WING.lerp(MASK_TIP, 0.20))

	if p["alula"]:
		_build_alula(tool, p, side)

	var fingers: int = p["fingers"]
	if fingers <= 0:
		# A scythe: one continuous panel drawn out to a point. Nothing to count,
		# which is exactly the read a very small bird should give.
		var steps: int = 3
		for i in steps:
			var u0: float = lerpf(wrist, 1.0, float(i) / float(steps))
			var u1: float = lerpf(wrist, 1.0, float(i + 1) / float(steps))
			var tip: Color = MASK_WING.lerp(MASK_TIP, u0)
			_panel(tool, p, side, u0, u1, tip, tip)
	else:
		_build_fingers(tool, p, side, fingers)

	tool.generate_normals()
	return tool.commit()


## One spanwise panel of wing, creased along its own crest: leading strip,
## trailing strip. [param front] paints the covert row and [param back] the
## flight feathers behind it.
static func _panel(
	tool: SurfaceTool, p: Dictionary, side: float,
	u0: float, u1: float, front: Color, back: Color
) -> void:
	var crest0: Vector3 = _wing_point(
		p, side, u0, _leading(p, u0) + _chord_at(p, u0) * CREST
	) + Vector3.UP * _chord_at(p, u0) * CAMBER
	var crest1: Vector3 = _wing_point(
		p, side, u1, _leading(p, u1) + _chord_at(p, u1) * CREST
	) + Vector3.UP * _chord_at(p, u1) * CAMBER
	_wing_quad(tool, p, side,
		_wing_point(p, side, u0, _leading(p, u0)),
		_wing_point(p, side, u1, _leading(p, u1)),
		crest1, crest0, u0, u1, front)
	_wing_quad(tool, p, side,
		crest0, crest1,
		_wing_point(p, side, u1, _trailing(p, u1)),
		_wing_point(p, side, u0, _trailing(p, u0)),
		u0, u1, back)


## The little thumb feather at the wrist. Pure silhouette, two triangles, and
## the shape every large soaring bird has at the leading edge of its wrist.
static func _build_alula(tool: SurfaceTool, p: Dictionary, side: float) -> void:
	var u: float = float(p["wrist"]) * 0.94
	var chord: float = _chord_at(p, u)
	var root := _wing_point(p, side, u, _leading(p, u))
	var tip := _wing_point(p, side, u * 0.82, _leading(p, u) - chord * 0.16)
	var back := _wing_point(p, side, u * 0.88, _leading(p, u) + chord * 0.14)
	var lift: float = chord * 0.05
	_wing_tri(tool, p, side,
		root + Vector3.UP * lift, tip + Vector3.UP * lift, back + Vector3.UP * lift,
		u, u * 0.86, u * 0.90, MASK_COVERT.lerp(MASK_TIP, 0.25))


## Splayed primaries. The count is the size class, so these are the shapes the
## whole "eat it or run" judgement rests on: a bird with five fingers spread
## like a hand is never a bird you can eat.
static func _build_fingers(
	tool: SurfaceTool, p: Dictionary, side: float, fingers: int
) -> void:
	var wrist: float = p["wrist"]
	var hand: float = lerpf(wrist, 1.0, 0.42)
	# The panel the fingers grow out of, creased like the arm ahead of it.
	_panel(tool, p, side, wrist, hand,
		MASK_COVERT if p["coverts"] else MASK_WING, MASK_WING)

	var chord: float = _chord_at(p, hand)
	var splay: float = p["splay"]
	var lead: float = _leading(p, hand)
	for k in fingers:
		var f: float = float(k) / maxf(float(fingers - 1), 1.0)
		# Each feather is shorter and swept further back than the one ahead of
		# it, and sits a hair above it, so the hand fans instead of forking.
		var reach: float = lerpf(1.0, 0.72, f * f)
		var tip_u: float = lerpf(hand, 1.0, reach)
		var tip_z: float = _sweep_at(p, 1.0) + splay * float(p["span"]) * f
		var lift: float = chord * 0.035 * float(k)
		var root0 := _wing_point(p, side, hand, lead + chord * float(k) / float(fingers))
		var root1 := _wing_point(p, side, hand, lead + chord * float(k + 1) / float(fingers))
		var half: float = _chord_at(p, 1.0) * 0.30
		var tip0 := _wing_point(p, side, tip_u, tip_z - half)
		var tip1 := _wing_point(p, side, tip_u, tip_z + half)
		_wing_quad(tool, p, side,
			root0 + Vector3.UP * lift, tip0 + Vector3.UP * lift,
			tip1 + Vector3.UP * lift, root1 + Vector3.UP * lift,
			hand, tip_u, MASK_WING.lerp(MASK_TIP, 0.55 + 0.45 * f))


# --- tail ---------------------------------------------------------------------

## A fan of separate feathers, layered outward-under-inward, cut to a shape.
## [code]shape[/code] runs from −1 (deeply forked: the outer feathers are the
## long ones) through 0 (square) to +1 (a wedge with the long feathers in the
## middle).
static func _build_tail(species: Species) -> ArrayMesh:
	var p: Dictionary = profile(species)
	var count: int = p["feathers"]
	var half: int = (count - 1) / 2
	var length: float = p["tail"]
	var fan: float = p["fan"]
	var shape: float = p["shape"]

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(-half, half + 1):
		var f: float = absf(float(i)) / maxf(float(half), 1.0)
		var angle: float = fan * float(i) / maxf(float(half), 1.0)
		var reach: float = length * (1.0 + shape * (-0.45 * f if shape > 0.0 else 0.55 * f))
		# Outer feathers tuck under inner ones, which is what a closed tail does
		# and what makes the fan read as separate feathers when it opens.
		var drop: float = -length * 0.020 * absf(float(i))
		var root_half: float = length * 0.048
		var tip_half: float = length * 0.070
		var root0 := Vector3(-root_half, drop, 0.0)
		var root1 := Vector3(root_half, drop, 0.0)
		var tip0 := Vector3(-tip_half, drop, reach)
		var tip1 := Vector3(tip_half, drop, reach)
		var turn := Basis(Vector3.UP, angle)
		var mask: Color = MASK_TAIL
		var tip_mask: Color = MASK_TAIL.lerp(MASK_TIP, 0.45)
		_quad4(tool, turn * root1, turn * tip1, turn * tip0, turn * root0, mask, tip_mask)
	tool.generate_normals()
	return tool.commit()


# --- primitives ---------------------------------------------------------------

static func _vertex(tool: SurfaceTool, position: Vector3, mask: Color) -> void:
	tool.set_color(mask)
	tool.add_vertex(position)


static func _triangle(
	tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, mask: Color
) -> void:
	_vertex(tool, a, mask)
	_vertex(tool, b, mask)
	_vertex(tool, c, mask)


static func _quad(
	tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, mask: Color
) -> void:
	_triangle(tool, a, b, c, mask)
	_triangle(tool, a, c, d, mask)


## Four corners with the far edge painted differently from the near one, so a
## feather can darken toward its own tip.
static func _quad4(
	tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
	near: Color, far: Color
) -> void:
	_vertex(tool, a, near)
	_vertex(tool, b, far)
	_vertex(tool, c, far)
	_vertex(tool, a, near)
	_vertex(tool, c, far)
	_vertex(tool, d, near)


## Wing surfaces carry a flex weight that a body never does, and both wings are
## wound so their upper surface faces the sky.
##
## The weight has to be [b]per vertex[/b]: the bend in [constant BIRD_SHADER]
## rotates each vertex by its own weight, so a panel painted with one weight for
## all four corners would rotate rigidly and tear itself off the panel inboard of
## it. [param ua] applies to a and d, [param ub] to b and c — which is the shape
## every quad in a wing has.
static func _wing_quad(
	tool: SurfaceTool, p: Dictionary, side: float,
	a: Vector3, b: Vector3, c: Vector3, d: Vector3,
	ua: float, ub: float, mask: Color
) -> void:
	var near: Color = _wing_mask(mask, p, ua)
	var far: Color = _wing_mask(mask, p, ub)
	if side > 0.0:
		_quad4(tool, a, b, c, d, near, far)
	else:
		_quad4(tool, d, c, b, a, near, far)


static func _wing_tri(
	tool: SurfaceTool, p: Dictionary, side: float,
	a: Vector3, b: Vector3, c: Vector3,
	ua: float, ub: float, uc: float, mask: Color
) -> void:
	var ma: Color = _wing_mask(mask, p, ua)
	var mb: Color = _wing_mask(mask, p, ub)
	var mc: Color = _wing_mask(mask, p, uc)
	if side > 0.0:
		_vertex(tool, a, ma)
		_vertex(tool, b, mb)
		_vertex(tool, c, mc)
	else:
		_vertex(tool, c, mc)
		_vertex(tool, b, mb)
		_vertex(tool, a, ma)
