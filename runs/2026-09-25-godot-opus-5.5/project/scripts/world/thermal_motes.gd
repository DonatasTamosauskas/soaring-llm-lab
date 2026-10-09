class_name ThermalMotes
extends MultiMeshInstance3D
## The visible cue for rising air: pollen/dust motes spiralling up every
## thermal column (and up the windward cliff), in ONE draw call.
##
## Every mote is a tiny billboard diamond whose position is computed in the
## vertex shader from its thermal's live centre (uniform arrays updated each
## frame from the WindField), so motes drift and lean with the column the
## flight model feels. Motes grow with distance (twice the angular size at
## 400 m as at 45 m) so a column still reads as a shimmer across the valley.

const PER_THERMAL := 240
## Motes spread over all ridge-lift zones.
const RIDGE_MOTES := 900
const MAX_THERMALS := 16

var wind: WindField
var _time := 0.0
## thermal index per instance (for tests: every thermal has motes).
var instance_thermal := PackedInt32Array()
## Ground-plane origins of the ridge motes (for tests: the headless dummy
## renderer does not keep multimesh buffers to read back).
var ridge_origins := PackedVector3Array()


## Ridge motes are seeded on the baked lift map itself (every node with
## real lift), so every lift zone - the cliff, the canyon massif, the west
## mountain slopes - shows its rising air where the flight model feels it.
func setup(p_wind: WindField, seed: int) -> void:
	wind = p_wind
	name = "thermal_motes"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 4099 + 7
	var tn := wind.thermal_count()
	# An equal share of ridge motes for every lift source that has lift.
	var sources: Array = wind.lift_nodes(1.2).filter(func(a: Array) -> bool: return not a.is_empty())
	var per_source := RIDGE_MOTES / maxi(sources.size(), 1)
	var ridge_total := per_source * sources.size()
	var total := tn * PER_THERMAL + ridge_total
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _diamond()
	mm.instance_count = total
	var k := 0
	for t in tn:
		for m in PER_THERMAL:
			mm.set_instance_transform(k, Transform3D.IDENTITY)
			# custom: thermal index, phase, radial fraction, angle
			mm.set_instance_custom_data(k, Color(float(t), rng.randf(), sqrt(rng.randf()) * 0.8, rng.randf() * TAU))
			instance_thermal.append(t)
			k += 1
	for m in ridge_total:
		var nodes: Array = sources[m / per_source]
		var nd: Vector4 = nodes[rng.randi() % nodes.size()]
		var base := Vector2(nd.x, nd.y) + Vector2(rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0))
		# Ridge motes: origin = start point, custom.x = -1 marks them;
		# y = phase, z = rise range, w = rise start (the lift band).
		mm.set_instance_transform(k, Transform3D(Basis.IDENTITY, Vector3(base.x, 0.0, base.y)))
		ridge_origins.append(Vector3(base.x, 0.0, base.y))
		mm.set_instance_custom_data(k, Color(-1.0, rng.randf(), maxf(nd.w - nd.z, 20.0), nd.z))
		instance_thermal.append(-1)
		k += 1
	multimesh = mm
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter(&"mote_color", Palette.c(&"pollen"))
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_lighting(&"day")
	# The shader moves motes anywhere in the valley.
	custom_aabb = AABB(Vector3(-800, -10, -800), Vector3(1600, 330, 1600))
	set_meta(&"soft", "motes")
	_push_uniforms()


## Motes are unshaded (a speck must not go black in shade), so their colour
## follows the lighting preset instead: pale pollen by day, a dim warm
## brown at dusk (white specks there read as snow).
func set_lighting(preset: StringName) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter(&"mote_color", Palette.LIGHT.get(preset, Palette.LIGHT[&"day"])["motes"])


func _process(delta: float) -> void:
	_time += delta
	_push_uniforms()


func _push_uniforms() -> void:
	if wind == null or material_override == null:
		return
	var mat := material_override as ShaderMaterial
	var centers := PackedVector4Array()
	var params := PackedVector4Array()
	var th := wind.thermals()
	for i in MAX_THERMALS:
		if i < th.size():
			var p: Vector3 = th[i]["position"]
			centers.append(Vector4(p.x, p.y, p.z, th[i]["radius"]))
			params.append(Vector4(th[i]["top"], th[i]["strength"], 0.0, 0.0))
		else:
			centers.append(Vector4.ZERO)
			params.append(Vector4.ZERO)
	var lean: Vector3 = th[0]["lean"] if not th.is_empty() else Vector3.ZERO
	mat.set_shader_parameter(&"centers", centers)
	mat.set_shader_parameter(&"params", params)
	mat.set_shader_parameter(&"lean", Vector2(lean.x, lean.z))
	mat.set_shader_parameter(&"wtime", _time)
	mat.set_shader_parameter(&"breeze", Vector2(wind.breeze().x, wind.breeze().z))


static func _diamond() -> ArrayMesh:
	var st := PackedVector3Array([Vector3(0, 1, 0), Vector3(-0.6, 0, 0), Vector3(0.6, 0, 0),
		Vector3(0.6, 0, 0), Vector3(-0.6, 0, 0), Vector3(0, -1, 0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = st
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, fog_disabled;

uniform vec4 centers[16];
uniform vec4 params[16];
uniform vec2 lean;
uniform vec2 breeze;
uniform float wtime;
uniform vec4 mote_color : source_color = vec4(1.0, 0.95, 0.7, 1.0);
varying float v_fade;

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;
	vec3 wp;
	float fade = 1.0;
	if (cd.x >= 0.0) {
		int t = int(cd.x + 0.5);
		vec4 c = centers[t];
		vec4 p = params[t];
		float h0 = c.y + 4.0;
		float range = max(p.x - 30.0 - h0, 10.0);
		float rise = 0.55 * p.y;
		float y = h0 + mod(cd.y * range + wtime * rise, range);
		float ang = cd.w + wtime * (0.35 + 0.2 * cd.z) + y * 0.02;
		float rad = cd.z * c.w;
		wp = vec3(c.x + lean.x * y + cos(ang) * rad, y, c.z + lean.y * y + sin(ang) * rad);
		float u = (y - h0) / range;
		fade = smoothstep(0.0, 0.08, u) * (1.0 - smoothstep(0.85, 1.0, u));
	} else {
		vec3 o = MODEL_MATRIX[3].xyz;
		float range = cd.z - cd.w;
		float s = mod(cd.y * range + wtime * 1.6, range);
		// Ridge motes ride up the face and drift back over the crest.
		wp = vec3(o.x + breeze.x * s * 0.35, cd.w + s, o.z + breeze.y * s * 0.35);
		float u = s / range;
		fade = smoothstep(0.0, 0.1, u) * (1.0 - smoothstep(0.8, 1.0, u));
	}
	vec3 vp = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;
	float dist = length(vp);
	// Constant angular size (~0.11 deg) past 45 m; thermal motes grow to
	// twice that by ~400 m so a column still reads across the valley (the
	// ridge motes, spread over whole slopes, stay small: grown, they read
	// as snowfall).
	float grow = cd.x >= 0.0 ? 1.0 + clamp((dist - 120.0) / 280.0, 0.0, 1.0) : 1.0;
	float size = 0.09 * max(1.0, dist / 45.0) * grow * fade;
	VERTEX = vp + vec3(VERTEX.xy * size, 0.0);
	v_fade = fade;
}

void fragment() {
	ALBEDO = mote_color.rgb;
}
"""
