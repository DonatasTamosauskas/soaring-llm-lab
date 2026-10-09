class_name FirstPersonWings
extends MultiMeshInstance3D
## The player's own wings, seen in first person: low-poly feathers attached
## to the hands and forearms, fanning open and folding with arm extension,
## tilting with the wrists and coloured like the player's species.
##
## One MultiMesh of one feather mesh = ONE draw call for both wings (the
## budget is <= 2). Add as a child of the XROrigin3D with an identity
## transform: every feather transform is computed in origin-local space
## from tracking-space poses x world_scale, so nothing is ever node-scaled
## (ARCHITECTURE §7.1) and the wings stay exact at any world_scale.
##
## Geometry per wing (tracking metres at world_scale 1), layered like a
## real wing and like the NPC models (a covert band, a flight-feather panel
## with a notched trailing edge, a fan of long primaries at the hand):
##   primaries        7 long pointed feathers rooted along the forearm
##                    (a bird's hand wing), fanning out and back; the
##                    leading one reaches 10 cm past the grip at full spread
##                    (FLIGHT_SPEC §11.4: wingtips 10 cm past each grip make
##                    the drawn span = arm_span + 0.20 = the bird's real span
##                    / world_scale)
##   primary coverts  5 plates over the primaries' roots
##   secondaries      8 blunt feathers along the inner arm
##   greater coverts  5 plates over the secondaries' roots
##   lesser coverts   5 wide plates forming a smooth leading edge
## One feather mesh; each instance picks its outline in the vertex shader
## (pointed / blunt / plate), so shape variety costs no extra draw call.
## Folding: every feather rotates in the wing plane from its spread angle to
## lie back along the forearm (extension 1 -> 0), like a real wing closing.
##
## Colours: the NPC palette of the player's species (BirdModels.wing_palette,
## the birds area's contract for exactly this: upper coverts / flight
## feathers / primaries, the underside, and an accent), so your wings next
## to theirs are a species cue as well as a size cue. The accent goes where
## that species wears it (ACCENT_AT). Upper surface on top, the underside
## when a wing is seen from below.
##
## Poses come from a WingCalibrator (VRCalibration feeds it every frame):
## its hands, shoulders, hand frames and extension. When the PlayerBird
## exposes wing_state() (FLIGHT_SPEC §10.1), its ext_l/ext_r are used
## instead, so the soar lock and the novice floor show on the wings.

const SIDE_SIGN := [-1.0, 1.0]
## Tip overhang past the grip at full spread, m (FLIGHT_SPEC §11.4).
const TIP_OVERHANG := 0.10
## How far a fully folded wing's plane turns from the hand's towards level.
const FOLD_LEVEL := 0.8
## The level turn fades out smoothly where "level" stops being defined
## (fold_level_turn): with the forearm within LEVEL_FADE_LO (as the sine of
## its angle from vertical: 8.6°) of vertical it is off, from LEVEL_FADE_HI
## (37°) it is whole; and for a turn beyond TURN_FADE_FROM it fades to 0 at
## 180° (a palm-up hand: turning either way round would be a coin toss).
const LEVEL_FADE_LO := 0.15
const LEVEL_FADE_HI := 0.6
const TURN_FADE_FROM := deg_to_rad(100.0)
## How far a fully folded wing's hand frame swings from the controller's
## forearm axis to the arm's line (fold_align_turn), and where that fades.
const FOLD_ALIGN := 1.0
const ALIGN_FADE_FROM := deg_to_rad(120.0)
## The arm feathers lie along the arm (shoulder -> grip) and hand over to
## the forearm as the grip comes in to the shoulder (m): with the hand at
## the shoulder that line has no direction, and in a tuck (grip ~15 cm from
## the shoulder) the arm feathers then fold in along the forearm with the
## primaries, one closed wing instead of two groups.
const ARM_DIR_MIN := 0.10
const ARM_DIR_FULL := 0.30
## Folded, the covert plates (square-ish, to make a smooth leading edge on
## the spread wing) narrow to COVERT_FOLD_WIDTH of their width and lengthen
## by COVERT_FOLD_LENGTH (smoothly with the fold, fix round 4): a verifier's
## look-at-your-hands shots found a folded wing read as 2-3 rounded
## wing-coloured plates per hand. Narrow and long they overlap like the
## covert rows of a perched bird's wing, each tip a scallop over the next.
const COVERT_FOLD_WIDTH := 0.55
const COVERT_FOLD_LENGTH := 1.45

## Feather groups (instance custom .x) and outlines (instance custom .y).
enum Group { PRIMARY, SECONDARY, GREATER_COVERT, LESSER_COVERT, PRIMARY_COVERT }
enum Shape { POINTED, BLUNT, PLATE }

## Hand feathers: [a along the hand's outward axis, c towards the trailing
## edge, spread angle deg, folded angle deg, length, width, lift along the
## wing normal]. Angles are from the outward axis towards the trailing edge,
## in the wing plane. PRIMARIES[0] (a, c = 0, lift 0) is the leading edge:
## a + length x cos(spread) = +0.10 m exactly.
const PRIMARIES := [
	[-0.140, 0.000, 3.0, 156.0, 0.240329, 0.052, 0.000],
	[-0.170, 0.010, 11.0, 160.0, 0.265, 0.058, -0.002],
	[-0.200, 0.020, 20.0, 164.0, 0.280, 0.062, -0.004],
	[-0.230, 0.030, 30.0, 167.0, 0.285, 0.064, -0.006],
	[-0.260, 0.040, 42.0, 170.0, 0.285, 0.066, -0.008],
	[-0.290, 0.048, 55.0, 173.0, 0.280, 0.068, -0.010],
	[-0.320, 0.055, 75.0, 176.0, 0.270, 0.070, -0.012],
]
const HAND_COVERTS := [
	[-0.160, 0.004, 14.0, 160.0, 0.120, 0.080, 0.012],
	[-0.200, 0.018, 30.0, 164.0, 0.120, 0.085, 0.012],
	[-0.240, 0.030, 46.0, 168.0, 0.120, 0.090, 0.012],
	[-0.280, 0.040, 62.0, 172.0, 0.120, 0.090, 0.012],
	[-0.320, 0.048, 80.0, 175.0, 0.115, 0.090, 0.012],
]
## Arm feathers: [fraction along shoulder -> hand, spread angle, folded
## angle, length, width, lift, offset towards the trailing edge]. The
## secondaries cover the inner arm; the primaries (rooted along the forearm,
## on the hand frame) take over from about the elbow outwards, as a bird's
## hand wing does.
const SECONDARIES := [
	[0.08, 98.0, 172.0, 0.270, 0.082, -0.004, 0.030],
	[0.15, 97.0, 172.0, 0.280, 0.082, -0.005, 0.030],
	[0.22, 96.0, 171.0, 0.288, 0.082, -0.006, 0.030],
	[0.29, 95.0, 171.0, 0.294, 0.082, -0.007, 0.030],
	[0.36, 93.0, 170.0, 0.298, 0.082, -0.008, 0.030],
	[0.43, 91.0, 170.0, 0.300, 0.081, -0.009, 0.030],
	[0.50, 89.0, 169.0, 0.300, 0.080, -0.010, 0.030],
	[0.57, 87.0, 169.0, 0.298, 0.078, -0.011, 0.030],
]
const GREATER_COVERTS := [
	[0.10, 98.0, 170.0, 0.140, 0.120, 0.006, 0.020],
	[0.22, 96.0, 170.0, 0.140, 0.120, 0.006, 0.020],
	[0.34, 94.0, 169.0, 0.140, 0.118, 0.006, 0.020],
	[0.46, 91.0, 169.0, 0.138, 0.114, 0.006, 0.020],
	[0.58, 88.0, 168.0, 0.134, 0.108, 0.006, 0.020],
]
const LESSER_COVERTS := [
	[0.14, 100.0, 168.0, 0.100, 0.175, 0.013, -0.036],
	[0.33, 98.0, 168.0, 0.100, 0.175, 0.013, -0.036],
	[0.52, 96.0, 168.0, 0.098, 0.170, 0.013, -0.036],
	[0.71, 93.0, 168.0, 0.094, 0.160, 0.013, -0.036],
	[0.88, 90.0, 168.0, 0.088, 0.150, 0.013, -0.036],
]
const PER_WING := 30
## Outline half-widths (fraction of the feather width) at the stations
## along the feather (STATIONS): pointed primary, blunt secondary, covert
## plate with a straight root edge.
const STATIONS := [0.0, 0.2, 0.55, 0.85, 1.0]
const PROFILES := [
	[0.18, 0.42, 0.50, 0.34, 0.0],
	[0.22, 0.44, 0.50, 0.48, 0.30],
	[0.42, 0.50, 0.50, 0.46, 0.28],
]
## Rachis ridge height along the feather (fraction of the width).
const RIDGE := [0.0, 0.035, 0.045, 0.03, 0.0]
## Triangles in one feather (build_feather_mesh).
const FEATHER_TRIS := 16

const SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;
// The UI draws menus over everything except the player's own body: stencil
// 64 marks wing pixels (UIPanel.OCCLUDER_STENCIL, ARCHITECTURE contract).
stencil_mode write, compare_always, 64;

// Species palette: one row per species (SizeRules order); columns: upper
// coverts, upper flight feathers, upper primaries, under coverts, under
// flight feathers, accent (alpha = where it goes / 4: 1 wing bar on the
// greater coverts, 2 primary tips, 3 trailing edge, 4 leading band).
uniform sampler2D palette : source_color, filter_nearest;
uniform int species_a = 2;
uniform int species_b = 2;
// Per feather group (FirstPersonWings.Group): the palette column of its
// upper surface and of its underside, and a shade (GROUP_COLUMNS).
uniform int group_top[5];
uniform int group_under[5];
uniform float group_shade[5];
uniform float blend = 1.0;
uniform float glow = 0.0;
uniform vec3 glow_color : source_color = vec3(1.0, 0.86, 0.45);
// How folded each wing is, (1 - extension)^2: x left (instances 0-29),
// y right (FirstPersonWings.fold_shape).
uniform vec2 fold_lr = vec2(0.0);
varying flat int v_group;
varying float v_jitter;
varying float v_fold;

vec4 pal(int col) {
	return mix(texelFetch(palette, ivec2(col, species_a), 0), texelFetch(palette, ivec2(col, species_b), 0), blend);
}

void vertex() {
	// INSTANCE_CUSTOM: x feather group, y outline, z brightness jitter.
	v_group = int(INSTANCE_CUSTOM.x + 0.5);
	v_jitter = INSTANCE_CUSTOM.z;
	v_fold = INSTANCE_ID < 30 ? fold_lr.x : fold_lr.y;
	// COLOR.rgb: this vertex's half-width for each outline; COLOR.a: side.
	int shape = int(INSTANCE_CUSTOM.y + 0.5);
	float w = shape == 0 ? COLOR.r : (shape == 1 ? COLOR.g : COLOR.b);
	if (shape == 2) {
		// The covert plates' square roots make the spread wing's smooth
		// leading edge. Folded, those roots are the wrist end of the wing
		// seen from the eyes, and read as sawn-off planks (fix round 5, a
		// verifier's look-at-your-hands sheet): they taper to a feather's
		// end as the wing folds, so the staggered plates make a scalloped
		// edge towards the hand. Spread (v_fold 0): unchanged.
		w *= mix(1.0, mix(0.3, 1.0, smoothstep(0.0, 0.32, VERTEX.x)), v_fold);
		// A full-height rachis ridge made them read as pillows up close. A
		// low one keeps them flat-faceted.
		VERTEX.y *= 0.3;
	}
	VERTEX.z = (COLOR.a * 2.0 - 1.0) * w;
}

void fragment() {
	// Flat shading from the reshaped geometry itself (one normal per facet),
	// facing the viewer on both sides of the vane.
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = dot(n, VIEW) < 0.0 ? -n : n;
	bool top = FRONT_FACING;
	vec3 base = pal(top ? group_top[v_group] : group_under[v_group]).rgb * group_shade[v_group];
	vec4 acc = pal(5);
	int at = int(acc.a * 4.0 + 0.5);
	if (top) {
		float a = 0.0;
		if (at == 1 && v_group == 2) a = step(0.66, UV.x);
		else if (at == 2 && v_group == 0) a = step(0.58, UV.x);
		else if (at == 3 && v_group <= 1) a = step(0.84, UV.x);
		else if (at == 4 && v_group == 3) a = step(0.5, UV.x);
		base = mix(base, acc.rgb, a);
	}
	// UV.x root (0) .. tip (1); UV.y rachis (0) .. vane edge (1): a dark
	// vane edge outlines each feather and a darker shaft runs down its
	// middle, so overlapping feathers read as feathers even edge-on (a
	// folded wing seen from between the hands). The root third lies in the
	// shade of the row above it (fix round 3: folded, the plates of one row
	// read as one flat paddle); shaded roots and lit tips scallop every row
	// into separate feathers at a glance.
	float overlap = mix(0.70, 1.0, smoothstep(0.0, 0.45, UV.x));
	// Dark plumage (crow, starling, swallow): a darkened vane edge vanished
	// into the vane and a folded crow wing read as one navy blob (fix round
	// 4); there the edge is a lighter sheen instead, as on a real crow.
	float lum = dot(base, vec3(0.299, 0.587, 0.114));
	// (Fix round 5: the dark sheen was too faint to see at headset
	// resolution; brighter now.)
	vec3 rim = mix(base * 0.55, base * 2.4 + vec3(0.05), 1.0 - smoothstep(0.03, 0.12, lum));
	// Folded, the outline widens (the feathers are narrower and seen
	// end-on) and runs round each feather's exposed end too, so every
	// covert of a folded wing is drawn, not a plank of one colour.
	float edge = smoothstep(mix(0.72, 0.58, v_fold), 1.0, UV.y);
	float end_rim = (1.0 - smoothstep(0.0, 0.07, UV.x)) * v_fold;
	base = mix(base, rim, max(edge, end_rim));
	base *= mix(0.72, 1.0, smoothstep(0.015, 0.06, UV.y)) * overlap * v_jitter;
	ALBEDO = base;
	ROUGHNESS = 1.0;
	EMISSION = glow_color * glow * (0.35 + 0.65 * UV.x);
}
"""

## Which palette column (PALETTE_KEYS) each feather group shows on its
## upper surface and its underside, and a shade that sets the covert rows a
## little apart so the layers read. Uniforms of the shader: the mapping is
## data the tests can read, not code in the fragment shader.
const GROUP_COLUMNS := {
	Group.PRIMARY: ["upper_primaries", "under_flight", 1.0],
	Group.SECONDARY: ["upper_flight", "under_flight", 1.0],
	Group.GREATER_COVERT: ["upper_coverts", "under_coverts", 0.93],
	Group.LESSER_COVERT: ["upper_coverts", "under_coverts", 1.0],
	Group.PRIMARY_COVERT: ["upper_coverts", "under_coverts", 0.96],
}

## Where each species wears its accent colour (BirdModels.wing_palette's
## "accent"), matching the NPC models: 1 a wing bar on the greater coverts,
## 2 dark primary tips, 3 a trailing edge, 4 a band; 0 none. (Compared
## with the birds area's species bands by the on-demand drift report
## tests/sim/birds_palette, not the unit suite: birds' internal data is not
## a contract.)
const ACCENT_AT := {
	&"moth": 4, &"wren": 1, &"sparrow": 1, &"swallow": 0, &"starling": 3,
	&"pigeon": 1, &"crow": 0, &"gull": 2, &"hawk": 3, &"eagle": 0,
}

## Fallback palette when the birds area's BirdModels is unavailable:
## upper coverts, upper flight, upper primaries, under coverts, under
## flight, accent (sRGB, the NPC colours as of 2026-09-26, fix round 3:
## the birds area retuned the starling; the on-demand drift report
## tests/sim/birds_palette prints new rows when they drift).
const PALETTE := {
	&"moth": ["d8c8a2", "8e7254", "d8c8a2", "cdbd9a", "d9c9a4", "8e7254"],
	&"wren": ["965830", "754323", "683b1c", "b98b5c", "936a48", "4c2a15"],
	&"sparrow": ["9d5b2f", "5c4129", "4b3625", "d6cebf", "a79b89", "f0ebe0"],
	&"swallow": ["213171", "18214a", "141b3a", "eadabd", "9c978a", "18214a"],
	&"starling": ["233b2d", "262430", "1f1d22", "5f594d", "4b463e", "a3875c"],
	&"pigeon": ["9aa3b3", "7e8797", "3e4351", "e8ebef", "bcc2cc", "22252b"],
	&"crow": ["22252f", "181a20", "131418", "2a2b31", "33343a", "181a20"],
	&"gull": ["abb5be", "a1acb5", "a1acb5", "f1f2ef", "d9dee2", "18191b"],
	&"hawk": ["664528", "553d28", "3c2c21", "f2ebdb", "e8e1d2", "3f2e22"],
	&"eagle": ["7d5a36", "443022", "2e231a", "4a3526", "5b4938", "443022"],
}
const PALETTE_KEYS := ["upper_coverts", "upper_flight", "upper_primaries", "under_coverts", "under_flight", "accent"]

## Feeds hands, shoulders and extension (VRCalibration.calibrator).
var calibrator: WingCalibrator
## The XROrigin3D (for world_scale).
var origin: XROrigin3D
## Species the colours follow (null player: this override or sparrow).
var species_override: StringName = &""
## Use PlayerBird.wing_state() extensions when available.
@export var use_flight_extension := true
## Tests set false and call update_wings(dt).
@export var auto_update := true
## Calibration feedback glow 0..1 (VRCalibration animates it).
var glow := 0.0:
	set(v):
		if v == glow:
			return
		glow = v
		if _mat:
			_mat.set_shader_parameter("glow", v)

var extension_shown: Array[float] = [1.0, 1.0]
var species_shown: StringName = &""
var _mat: ShaderMaterial
var _blend := 1.0
## Per-feather constants (see _build_tables).
var _t_p0 := PackedFloat32Array()
var _t_p1 := PackedFloat32Array()
var _t_spread := PackedFloat32Array()
var _t_fold := PackedFloat32Array()
var _t_len := PackedFloat32Array()
var _t_wid := PackedFloat32Array()
var _t_lift := PackedFloat32Array()
## The factors a feather's length / width reach when fully folded.
var _t_lfold := PackedFloat32Array()
var _t_wfold := PackedFloat32Array()
## Each feather's transform in its frame (hand or arm: x outward, y the
## wing normal, z the trailing edge), valid for the extension _local_e of
## its side: the fan angle, the folded covert shape and its root offsets.
## A feather in origin space is then ONE native product, frame x local
## (fix round 5: the per-feather vector sums and the 12 scalar writes per
## feather into an upload buffer were 45 of the area's ~100 us a frame).
var _local: Array[Transform3D] = []
## (64-bit: the key held as 32-bit floats never equalled the extension it
## was made from, so round 4 rebuilt every fan every frame.)
var _local_e: Array[float] = [-1.0, -1.0]
## _build_local calls (tests: a held extension rebuilds nothing).
var local_builds := 0
## What each instance was last given (origin space), and its custom data:
## the headless renderer keeps no copy to read back (tests, wingtip()).
var _xf: Array[Transform3D] = []
var _custom := PackedColorArray()
## The shader's fold_lr (fold_shape per side) as last set.
var _fold_shown := Vector2(-1.0, -1.0)
## What the last layout was computed from: a still pose costs nothing.
var _last_key := PackedFloat32Array()
var _key_buf := _new_key_buf()
## Frames where the pose changed / was unchanged (profiling, tests).
var updates := 0
var skipped := 0


static func _new_key_buf() -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(2 * 16 + 2)
	return b


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After the XR nodes and the rig have moved this frame.
	process_priority = 100
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = true
	mm.mesh = build_feather_mesh()
	mm.instance_count = PER_WING * 2
	multimesh = mm
	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The wings are always around the head, so culling them never pays: a
	# fixed box over the play space (origin units) spares the renderer the
	# AABB recomputation after every buffer upload. No shadows, no cost.
	custom_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	_mat.set_shader_parameter("palette", palette_texture())
	var tops := PackedInt32Array()
	var unders := PackedInt32Array()
	var shades := PackedFloat32Array()
	for g in Group.size():
		var m: Array = GROUP_COLUMNS[g]
		tops.append(PALETTE_KEYS.find(m[0]))
		unders.append(PALETTE_KEYS.find(m[1]))
		shades.append(float(m[2]))
	_mat.set_shader_parameter("group_top", tops)
	_mat.set_shader_parameter("group_under", unders)
	_mat.set_shader_parameter("group_shade", shades)
	_build_tables()
	_local.resize(PER_WING * 2)
	_xf.resize(PER_WING * 2)
	_custom.resize(PER_WING * 2)
	for i in PER_WING * 2:
		# Custom data: group, outline, brightness jitter (+-7 %, fixed per
		# feather, so overlapping feathers read apart).
		var kind := feather_kind(i % PER_WING)
		_custom[i] = Color(float(kind.x), float(kind.y), 1.0 + 0.07 * sin(float(i % PER_WING) * 12.9898), 0.0)
		mm.set_instance_custom_data(i, _custom[i])
		_set_instance(i, Transform3D(Basis.from_scale(Vector3.ONE * 1e-5), Vector3.ZERO))
	_set_species(_current_species(), true)


## One feather: a vane with a raised rachis along +X (root 0 .. tip 1), 5
## stations, 16 flat triangles. The mesh carries every outline at once:
## COLOR.r/g/b hold each vertex's half-width for the pointed / blunt /
## plate outline (PROFILES) and COLOR.a its side; the shader picks one per
## instance. Local axes: +X root -> tip (length 1), +Y up (normal), +Z
## across the vane (width 1, symmetric, so mirrored wings need no mirrored
## transforms). Triangles wind so the upper surface is the front face.
static func build_feather_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var n_st := STATIONS.size()
	for side in [-1.0, 1.0]:
		var rach: Array[Vector3] = []
		var edge: Array[Vector3] = []
		var rc: Array[Color] = []
		var ec: Array[Color] = []
		for i in n_st:
			var u: float = STATIONS[i]
			rach.append(Vector3(u, RIDGE[i], 0.0))
			edge.append(Vector3(u, 0.0, side * float(PROFILES[2][i])))
			rc.append(Color(0.0, 0.0, 0.0, 0.5 + 0.5 * side))
			ec.append(Color(PROFILES[0][i], PROFILES[1][i], PROFILES[2][i], 0.5 + 0.5 * side))
		for i in n_st - 1:
			var quads := [[rach[i], rc[i], 0.0], [edge[i], ec[i], 1.0], [edge[i + 1], ec[i + 1], 1.0], [rach[i + 1], rc[i + 1], 0.0]]
			for t in [[0, 1, 2], [0, 2, 3]]:
				var a: Array = quads[t[0]]
				var b: Array = quads[t[1]]
				var c: Array = quads[t[2]]
				var nn := ((b[0] as Vector3) - (a[0] as Vector3)).cross((c[0] as Vector3) - (a[0] as Vector3))
				if nn.y > 0.0:
					var tmp := b
					b = c
					c = tmp
				for v in [a, b, c]:
					var pos: Vector3 = v[0]
					verts.append(pos)
					norms.append(Vector3.UP)
					uvs.append(Vector2(pos.x, float(v[2])))
					cols.append(v[1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func world_scale() -> float:
	return origin.world_scale if origin != null and is_instance_valid(origin) else 1.0


func _process(dt: float) -> void:
	if auto_update:
		update_wings(dt)


func _current_species() -> StringName:
	if species_override != &"":
		return species_override
	var p := Birds.player()
	if p != null:
		return p.species if p.species != &"" else SizeRules.species_for_mass(p.mass)
	return &"sparrow"


func _flight_extension(i: int) -> float:
	if not use_flight_extension:
		return -1.0
	var p := Birds.player()
	if p == null or not p.has_method("wing_state"):
		return -1.0
	var ws: Variant = p.call("wing_state")
	if ws == null or not (ws is Object):
		return -1.0
	var v: Variant = (ws as Object).get("ext_l" if i == 0 else "ext_r")
	return float(v) if v != null else -1.0


## Recomputes all feather transforms from the calibrator's latest poses.
func update_wings(dt: float) -> void:
	if calibrator == null or multimesh == null:
		return
	var t0 := VRProfile.begin()
	var sp := _current_species()
	if sp != species_shown:
		_set_species(sp, false)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + dt / 0.8)
		_mat.set_shader_parameter("blend", _blend)
	var ws := world_scale()
	for i in 2:
		var want := _flight_extension(i)
		if want < 0.0:
			want = calibrator.extension[i]
		# Light smoothing: tracker jitter must not make the fan shimmer.
		want = clampf(want, 0.0, 1.0)
		extension_shown[i] = lerpf(extension_shown[i], want, VRMath.lp(dt, 0.06)) if dt > 0.0 else want
		# Arrived (a millionth of a fold is nothing to see): exactly there,
		# so a held extension reuses its fan (_local) frame after frame.
		if absf(extension_shown[i] - want) < 1e-6:
			extension_shown[i] = want
	var key := _pose_key(ws)
	if key == _last_key:
		skipped += 1
	else:
		_last_key = key.duplicate()
		updates += 1
		for i in 2:
			_place_wing(i, ws, calibrator.valid[i])
		var f := Vector2(fold_shape(extension_shown[0]), fold_shape(extension_shown[1]))
		if f != _fold_shown:
			_fold_shown = f
			_mat.set_shader_parameter("fold_lr", f)
	VRProfile.add(&"wings", t0)


## How far a wing at extension e shows its folded shape, 0 spread .. 1
## folded: (1 - e)^2, the same law as the covert plates' narrowing (the
## shader tapers their roots and outlines their ends by it).
static func fold_shape(e: float) -> float:
	var f := 1.0 - clampf(e, 0.0, 1.0)
	return f * f


## Everything the feather layout depends on, complete (exact values: a
## still pose, puppet or paused, repeats them bit for bit; any change in any
## component re-lays the wings): both grips (origin + full basis), both
## shoulders, both shown extensions, world_scale and tracking validity.
func _pose_key(ws: float) -> PackedFloat32Array:
	var k := _key_buf
	var n := 0
	for i in 2:
		var h: Transform3D = calibrator.hands[i]
		var sh: Vector3 = calibrator.shoulders[i]
		k[n] = h.origin.x
		k[n + 1] = h.origin.y
		k[n + 2] = h.origin.z
		k[n + 3] = h.basis.x.x
		k[n + 4] = h.basis.x.y
		k[n + 5] = h.basis.x.z
		k[n + 6] = h.basis.y.x
		k[n + 7] = h.basis.y.y
		k[n + 8] = h.basis.y.z
		k[n + 9] = h.basis.z.x
		k[n + 10] = h.basis.z.y
		k[n + 11] = h.basis.z.z
		k[n + 12] = sh.x
		k[n + 13] = sh.y
		k[n + 14] = sh.z
		k[n + 15] = extension_shown[i]
		n += 16
	k[n] = ws
	k[n + 1] = (1.0 if calibrator.valid[0] else 0.0) + (2.0 if calibrator.valid[1] else 0.0)
	return k


## Lays out one wing's feathers in origin space. The hand frame (o_h, n_h)
## and the arm frame (o_a, n_a) are orthonormal and every feather lies in
## its frame's wing plane, so a feather is its frame (scaled by
## world_scale) times its local transform (_local): no per-feather
## normalisation or vector sums.
func _place_wing(side: int, ws: float, show: bool) -> void:
	var base := side * PER_WING
	if not show:
		var collapsed := Transform3D(Basis.from_scale(Vector3.ONE * 1e-5), calibrator.hands[side].origin * ws)
		for j in PER_WING:
			_set_instance(base + j, collapsed)
		return
	var e := extension_shown[side]
	var s: float = SIDE_SIGN[side]
	var hand: Vector3 = calibrator.hands[side].origin
	var hf := calibrator.hand_frame(side)
	var o_h := hf.x
	var n_h := hf.y
	var sh: Vector3 = calibrator.shoulders[side]
	var arm := hand - sh
	# The arm feathers run along shoulder -> grip; with the hand at the
	# shoulder that line is undefined, so it hands over to the forearm
	# smoothly (a hard switch at some length made the arm feathers jump).
	var arm_len := arm.length()
	var o_a := o_h
	if arm_len > 1e-4:
		var mixed := o_h.lerp(arm / arm_len, VRMath.sstep(ARM_DIR_MIN, ARM_DIR_FULL, arm_len))
		if mixed.length() > 1e-3:
			o_a = mixed.normalized()
	# A folding wing closes along the arm and settles upper side up, as a
	# perched bird's does: the hand frame swings towards the arm's line
	# (fold_align_turn: the primaries fold back over the secondaries, one
	# closed wing even when the wrist is bent, e.g. the simulator's fixed
	# controllers pointing straight ahead), then turns about it towards
	# level (fold_level_turn: relaxed hands hold the controllers palms-in,
	# and a folded wing in the hand's plane was seen edge-on as a sliver).
	# Both are 0 for a spread wing: it follows the controller exactly.
	var fold := 1.0 - e
	if fold > 0.0:
		var ax := o_h.cross(o_a)
		var turn := fold_align_turn(o_h, o_a, e)
		if turn != 0.0 and ax.length() > 1e-6:
			ax = ax.normalized()
			o_h = o_h.rotated(ax, turn)
			n_h = n_h.rotated(ax, turn)
		n_h = n_h.rotated(o_h, fold_level_turn(o_h, n_h, e))
	var b_h := o_h.cross(n_h) * s              # trailing-edge direction
	var n_a := n_h - o_a * n_h.dot(o_a)
	n_a = n_a.normalized() if n_a.length() > 1e-3 else Vector3.UP
	var b_a := o_a.cross(n_a) * s
	var n_hand := PRIMARIES.size() + HAND_COVERTS.size()
	# The local transforms depend on the extension only: kept until it
	# changes (while flapping the arms move every frame but the extension
	# mostly holds).
	if e != _local_e[side]:
		_local_e[side] = e
		_build_local(side, e)
	# Hand feathers ride the hand frame from the grip; arm feathers the arm
	# frame from the shoulder, and sit a fraction along shoulder -> grip
	# (the tables are in that order). Frames are scaled by world_scale once
	# here, not per feather.
	# (The hot loops: no GDScript calls, one native product and one native
	# upload per feather.)
	var mm := multimesh
	var fh := Transform3D(Basis(o_h * ws, n_h * ws, b_h * ws), hand * ws)
	for k in range(base, base + n_hand):
		var t := fh * _local[k]
		_xf[k] = t
		mm.set_instance_transform(k, t)
	var fa := Transform3D(Basis(o_a * ws, n_a * ws, b_a * ws), sh * ws)
	var along := arm * ws
	for j in range(n_hand, PER_WING):
		var k := base + j
		var t := fa * _local[k]
		t.origin += along * _t_p0[j]
		_xf[k] = t
		mm.set_instance_transform(k, t)


## The local transforms of one side's feathers at extension e (see
## _local): in the frame (x outward, y the normal, z the trailing edge for
## this side), a feather at fan angle a has its length along
## (cos a, 0, sin a), its width along (-sin a, 0, cos a) x the side sign and
## its normal along y. Folding, the covert plates narrow and lengthen
## (unchanged when spread: the spread layout and its wingtip are exact).
## Hand feathers are rooted at (a, lift, c) of the hand frame; arm feathers
## at (0, lift, offset) plus their fraction along the arm (_place_wing).
func _build_local(side: int, e: float) -> void:
	local_builds += 1
	var base := side * PER_WING
	var s: float = SIDE_SIGN[side]
	var f2 := (1.0 - e) * (1.0 - e)
	var n_hand := PRIMARIES.size() + HAND_COVERTS.size()
	for j in PER_WING:
		var ang := _t_fold[j] + (_t_spread[j] - _t_fold[j]) * e
		var ca := cos(ang)
		var sa := sin(ang)
		var ln := _t_len[j] * (1.0 + (_t_lfold[j] - 1.0) * f2)
		var wd := _t_wid[j] * (1.0 + (_t_wfold[j] - 1.0) * f2)
		var p0 := _t_p0[j] if j < n_hand else 0.0
		_local[base + j] = Transform3D(Vector3(ca * ln, 0.0, sa * ln), Vector3(0.0, wd, 0.0),
			Vector3(-sa * s * wd, 0.0, ca * s * wd), Vector3(p0, _t_lift[j], _t_p1[j]))


## How far (rad, about the forearm axis o) a wing at extension e turns from
## the hand's plane (normal n, perpendicular to o) towards lying level,
## upper side up. At most FOLD_LEVEL of the way at extension 0 and
## quadratically less above it (a fifth of the way at 0.5; a spread wing
## follows the wrist exactly).
## Continuous in every input (fix round 3): round 2 switched the turn on
## and off with a hard gate (forearm near vertical, turn > ~100°), so a
## folded wing flipped 50-80° when a wrist or elbow moved 1° across it and
## flickered under tracker noise. Both limits are singular ("level" has no
## direction about a vertical forearm; at 180° either way round is as
## good), so the turn's weight goes smoothly to 0 towards each of them
## instead: a 1° change of any input turns the feathers by at most a few
## degrees (wings_test.test_folded_wing_turns_continuously).
static func fold_level_turn(o: Vector3, n: Vector3, e: float) -> float:
	var fold := 1.0 - clampf(e, 0.0, 1.0)
	if fold <= 0.0:
		return 0.0
	var level := Vector3.UP - o * o.dot(Vector3.UP)
	var ll := level.length()
	var w_level := VRMath.sstep(LEVEL_FADE_LO, LEVEL_FADE_HI, ll)
	if w_level <= 0.0:
		return 0.0
	level /= ll
	# Signed angle from n to level about o (both perpendicular to o).
	var ang := atan2(o.dot(n.cross(level)), n.dot(level))
	var w_turn := 1.0 - VRMath.sstep(TURN_FADE_FROM, PI, absf(ang))
	return ang * FOLD_LEVEL * fold * fold * w_level * w_turn


## How far (rad) a wing at extension e swings its hand frame from the
## controller's forearm axis o towards the arm's line a (both unit), about
## o x a: FOLD_ALIGN of the way at extension 0, quadratically less above,
## 0 when spread. Fades to 0 as the two approach opposite (a wrist bent
## back on itself), where the swing's axis is undefined.
static func fold_align_turn(o: Vector3, a: Vector3, e: float) -> float:
	var fold := 1.0 - clampf(e, 0.0, 1.0)
	if fold <= 0.0:
		return 0.0
	var ang := o.angle_to(a)
	return ang * FOLD_ALIGN * fold * fold * (1.0 - VRMath.sstep(ALIGN_FADE_FROM, PI, ang))


## One instance: the renderer's copy (a native call) and ours.
func _set_instance(k: int, t: Transform3D) -> void:
	_xf[k] = t
	multimesh.set_instance_transform(k, t)


## Instance transform k (origin space), as last given to the renderer.
func feather_transform(k: int) -> Transform3D:
	return _xf[k]


## Instance k's custom data as given to the renderer: (group, outline,
## brightness jitter, 0).
func feather_custom(k: int) -> Color:
	return _custom[k]


## (group, outline) of feather k within a wing, in instance order:
## primaries, primary coverts, secondaries, greater coverts, lesser coverts.
static func feather_kind(k: int) -> Vector2i:
	var n := PRIMARIES.size()
	if k < n:
		return Vector2i(Group.PRIMARY, Shape.POINTED)
	n += HAND_COVERTS.size()
	if k < n:
		return Vector2i(Group.PRIMARY_COVERT, Shape.PLATE)
	n += SECONDARIES.size()
	if k < n:
		return Vector2i(Group.SECONDARY, Shape.BLUNT)
	n += GREATER_COVERTS.size()
	if k < n:
		return Vector2i(Group.GREATER_COVERT, Shape.PLATE)
	return Vector2i(Group.LESSER_COVERT, Shape.PLATE)


## Flattens the feather tables into packed arrays (typed access in the
## per-frame loop), in instance order: primaries, primary coverts,
## secondaries, greater coverts, lesser coverts.
func _build_tables() -> void:
	for f in PRIMARIES + HAND_COVERTS:
		_t_p0.append(f[0])
		_t_p1.append(f[1])
		_t_spread.append(deg_to_rad(f[2]))
		_t_fold.append(deg_to_rad(f[3]))
		_t_len.append(f[4])
		_t_wid.append(f[5])
		_t_lift.append(f[6])
	for f in SECONDARIES + GREATER_COVERTS + LESSER_COVERTS:
		_t_p0.append(f[0])
		_t_p1.append(f[6])
		_t_spread.append(deg_to_rad(f[1]))
		_t_fold.append(deg_to_rad(f[2]))
		_t_len.append(f[3])
		_t_wid.append(f[4])
		_t_lift.append(f[5])
	for j in PER_WING:
		var plate := feather_kind(j).y == Shape.PLATE
		_t_lfold.append(COVERT_FOLD_LENGTH if plate else 1.0)
		_t_wfold.append(COVERT_FOLD_WIDTH if plate else 1.0)


## Where the outermost primary's tip is, origin-local (tests: wingtip =
## grip + 10 cm outward at full spread).
func wingtip(side: int) -> Vector3:
	var t := feather_transform(side * PER_WING)
	return t.origin + t.basis.x


func _set_species(sp: StringName, instant: bool) -> void:
	var row := maxi(SizeRules.species_index(sp), 0)
	var prev := maxi(SizeRules.species_index(species_shown), 0) if species_shown != &"" else row
	species_shown = sp
	if _mat == null:
		return
	if instant:
		_mat.set_shader_parameter("species_a", row)
		_blend = 1.0
	else:
		# Cross-fade over 0.8 s from what is on screen now.
		_mat.set_shader_parameter("species_a", prev if _blend >= 1.0 else int(_mat.get_shader_parameter("species_b")))
		_blend = 0.0
	_mat.set_shader_parameter("species_b", row)
	_mat.set_shader_parameter("blend", _blend)


## The birds area's NPC wing colours for a species (BirdModels.wing_palette,
## sRGB), duck-typed so a missing or mid-edit birds area falls back to the
## copy in PALETTE. Returns PALETTE_KEYS -> Color.
static func wing_colors(sp: StringName) -> Dictionary:
	var out := {}
	var npc := _npc_wing_palette(sp)
	var fallback: Array = PALETTE.get(sp, PALETTE[&"sparrow"])
	for i in PALETTE_KEYS.size():
		var k: String = PALETTE_KEYS[i]
		out[k] = npc[k] if npc.get(k) is Color else Color(fallback[i])
	return out


static var _npc_script: Script = null
static var _npc_looked := false


static func _npc_wing_palette(sp: StringName) -> Dictionary:
	if not _npc_looked:
		_npc_looked = true
		for c in ProjectSettings.get_global_class_list():
			if c["class"] == &"BirdModels" and ResourceLoader.exists(c["path"]):
				var scr := load(c["path"]) as Script
				if scr != null and scr.can_instantiate():
					_npc_script = scr
				break
	if _npc_script == null:
		return {}
	var d: Variant = _npc_script.call(&"wing_palette", sp)
	return d if d is Dictionary else {}


## The palette as a texture: rows = SizeRules.SPECIES order, 6 columns
## (PALETTE_KEYS); the accent's alpha says where it goes (ACCENT_AT / 4).
static func palette_texture() -> ImageTexture:
	var n := SizeRules.SPECIES.size()
	var img := Image.create(PALETTE_KEYS.size(), n, false, Image.FORMAT_RGBA8)
	for row in n:
		var sp: StringName = SizeRules.SPECIES[row]["id"]
		var cols := wing_colors(sp)
		for col in PALETTE_KEYS.size():
			var c: Color = cols[PALETTE_KEYS[col]]
			c.a = 1.0 if col < 5 else float(ACCENT_AT.get(sp, 0)) / 4.0
			img.set_pixel(col, row, c)
	return ImageTexture.create_from_image(img)


## 1 once a species change has fully faded in.
func species_blend() -> float:
	return _blend
