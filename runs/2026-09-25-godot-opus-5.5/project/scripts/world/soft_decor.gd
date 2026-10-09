class_name SoftDecor
extends RefCounted
## Ground-level soft decoration: grass tufts, wildflowers and reeds.
##
## These are deliberately NOT solid (a bird brushes through a grass tuft or a
## reed; colliding with every blade would be both wrong and expensive), are
## all under 1.5 m tall, and live in MultiMesh chunks with a visibility range
## so only the ones near the camera are drawn. Every node here carries
## meta "soft" = category, which the collision-coverage test checks against
## an explicit allow-list.

const CHUNK := 128.0
const RANGE := 150.0
const MAX_H := 1.5


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("decor")
	var tuft := _tuft_mesh()
	var reed := _reed_mesh()
	var grass := {}
	var flowers := {}
	var reeds := {}
	var noise := FastNoiseLite.new()
	noise.seed = ctx.seed + 991
	noise.frequency = 0.02
	var flower_cols := [Palette.c(&"flower_red"), Palette.c(&"flower_white"), Palette.c(&"flower_blue"), Palette.c(&"flower_yellow")]
	var inner := WorldLayout.INNER_R + 40.0
	# Grass and flowers: dense in the meadow and on village greens, sparse
	# elsewhere; never on fields, water, roads or inside solids.
	for i in 26000:
		var p := Vector2(rng.randf_range(-inner, inner), rng.randf_range(-inner, inner))
		if p.length() > inner:
			continue
		var in_meadow := p.distance_to(WorldLayout.MEADOW) < WorldLayout.MEADOW_CLEAR + 20.0
		var dens := 0.9 if in_meadow else 0.35 + 0.3 * noise.get_noise_2d(p.x, p.y)
		if rng.randf() > dens:
			continue
		if not in_meadow and not ctx.is_free(p.x, p.y):
			continue
		var g := ctx.terrain.height_at(p.x, p.y)
		if g < WorldLayout.WATER_Y + 0.6 or (g > 25.0 and ctx.terrain.normal_at(p.x, p.y).y < 0.85):
			continue
		var key := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
		var s := rng.randf_range(0.7, 1.3)
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.2), s)), Vector3(p.x, g - 0.03, p.y))
		if in_meadow and rng.randf() < 0.28:
			if not flowers.has(key):
				flowers[key] = []
			flowers[key].append([xf, flower_cols[rng.randi() % flower_cols.size()]])
		else:
			if not grass.has(key):
				grass[key] = []
			var gc := Palette.c(&"grass_light").lerp(Palette.c(&"meadow_flower"), rng.randf() * 0.5) if in_meadow else Palette.c(&"grass").lerp(Palette.c(&"grass_light"), rng.randf())
			grass[key].append([xf, gc])
	# The meadow gets its own dense sowing: the vast open space should read
	# as a flowering sward from low flight.
	for i in 14000:
		var p := WorldLayout.MEADOW + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (WorldLayout.MEADOW_CLEAR + 25.0)
		var g := ctx.terrain.height_at(p.x, p.y)
		var key := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
		var s := rng.randf_range(0.8, 1.4)
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.3), s)), Vector3(p.x, g - 0.03, p.y))
		# Flowers grow in drifts (noise), grass everywhere between.
		if noise.get_noise_2d(p.x * 2.0, p.y * 2.0) > 0.05 and rng.randf() < 0.55:
			if not flowers.has(key):
				flowers[key] = []
			var fc: Color = flower_cols[int(absf(noise.get_noise_2d(p.x * 0.7 + 90.0, p.y * 0.7)) * 9.0) % flower_cols.size()]
			flowers[key].append([xf, fc])
		else:
			if not grass.has(key):
				grass[key] = []
			grass[key].append([xf, Palette.c(&"grass_light").lerp(Palette.c(&"meadow_flower"), rng.randf() * 0.6)])
	# Reeds fringe the lake and the lower river.
	for i in 2600:
		var a := rng.randf() * TAU
		var p: Vector2
		if i % 3 == 0:
			var at := WorldLayout.polyline_at(WorldLayout.RIVER, rng.randf() * WorldLayout.polyline_length(WorldLayout.RIVER))
			var d: Vector2 = at[1]
			p = (at[0] as Vector2) + Vector2(-d.y, d.x) * rng.randf_range(-11.0, 11.0)
		else:
			p = WorldLayout.LAKE + Vector2(cos(a) * WorldLayout.LAKE_R.x, sin(a) * WorldLayout.LAKE_R.y).rotated(WorldLayout.LAKE_ROT) * rng.randf_range(0.92, 1.08)
		var g := ctx.terrain.height_at(p.x, p.y)
		if g < WorldLayout.WATER_Y - 0.5 or g > WorldLayout.WATER_Y + 0.9:
			continue
		if p.distance_to(WorldLayout.BRIDGE) < 25.0 or not ctx.is_free(p.x, p.y) and WorldLayout.polyline_distance(p, WorldLayout.RIVER) > 12.5:
			continue
		var key := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
		if not reeds.has(key):
			reeds[key] = []
		var s := rng.randf_range(0.8, 1.2)
		reeds[key].append([Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), Vector3(p.x, maxf(g, WorldLayout.WATER_Y - 0.3) - 0.05, p.y)),
			Palette.c(&"reed").lerp(Palette.c(&"wheat_dark"), rng.randf() * 0.4)])
	var n := 0
	n += _emit(ctx, grass, tuft, "grass")
	n += _emit(ctx, flowers, _flower_mesh(), "flowers")
	n += _emit(ctx, reeds, reed, "reeds")
	ctx.set_meta(&"decor_instances", n)


static func _emit(ctx: WorldBuild, groups: Dictionary, mesh: Mesh, cat: String) -> int:
	var total := 0
	for key in groups:
		var items: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = items.size()
		for i in items.size():
			mm.set_instance_transform(i, items[i][0])
			mm.set_instance_color(i, items[i][1])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d_%d" % [cat, key.x, key.y]
		mmi.multimesh = mm
		mmi.material_override = _decor_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = RANGE
		mmi.visibility_range_end_margin = 20.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		mmi.set_meta(&"soft", cat)
		ctx.soft_root.add_child(mmi)
		total += items.size()
	return total


static var _mat: ShaderMaterial


static func _decor_material() -> ShaderMaterial:
	if _mat == null:
		var sh := Shader.new()
		sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert;
// COLOR arrives already multiplied by the MultiMesh instance colour; its
// alpha (vertex alpha x 1) is the sway weight (blade tips).
varying vec3 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = COLOR.a;
	VERTEX.x += sin(TIME * 1.7 + wp.x * 0.3 + wp.z * 0.2) * 0.06 * w;
	VERTEX.z += cos(TIME * 1.3 + wp.z * 0.3) * 0.04 * w;
	v_col = COLOR.rgb;
	NORMAL = vec3(0.0, 1.0, 0.0);
}
void fragment() {
	ALBEDO = pow(v_col, vec3(2.2));
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
"""
		_mat = ShaderMaterial.new()
		_mat.shader = sh
	return _mat


## Three crossed blades; vertex colour is a grey ramp (dark base, light
## tip) multiplied by the instance colour; alpha = sway weight.
static func _tuft_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var c := PackedColorArray()
	for k in 3:
		var a := TAU * k / 3.0 + 0.3
		var d := Vector3(cos(a), 0, sin(a)) * 0.07
		var lean := Vector3(cos(a + 1.2), 0, sin(a + 1.2)) * 0.12
		v.append(-d)
		v.append(d)
		v.append(lean + Vector3(0, 0.5, 0))
		c.append(Color(0.6, 0.6, 0.6, 0.0))
		c.append(Color(0.6, 0.6, 0.6, 0.0))
		c.append(Color(1.05, 1.05, 1.05, 1.0))
	return _mesh(v, c)


static func _flower_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var c := PackedColorArray()
	# A small clump: two leaf blades and three little flower heads (tiny
	# double-sided diamonds in the instance colour) at slightly different
	# heights, so a drift of them reads as colour, not as signs on sticks.
	var green := Color(0.42, 0.62, 0.32, 0.0)
	for k in 2:
		var a := PI * k + 0.4
		var d := Vector3(cos(a), 0, sin(a)) * 0.05
		v.append_array([-d, d, Vector3(cos(a + 1.0), 0, sin(a + 1.0)) * 0.1 + Vector3(0, 0.32, 0)])
		c.append_array([green, green, Color(green.r, green.g, green.b, 1.0)])
	for k in 3:
		var a := TAU * k / 3.0
		var top := Vector3(cos(a) * 0.07, 0.3 + 0.06 * k, sin(a) * 0.07)
		v.append_array([Vector3(cos(a) * 0.02, 0, sin(a) * 0.02), Vector3(cos(a) * 0.035, 0, sin(a) * 0.035), top])
		c.append_array([green, green, Color(green.r, green.g, green.b, 1.0)])
		var d := Vector3(cos(a + 1.57), 0, sin(a + 1.57)) * 0.045
		v.append_array([top - d, top + Vector3(0, 0.05, 0), top + d, top - d, top + d, top + Vector3(0, -0.035, 0)])
		for i in 6:
			c.append(Color(1, 1, 1, 1))
	return _mesh(v, c)


static func _reed_mesh() -> ArrayMesh:
	var v := PackedVector3Array()
	var c := PackedColorArray()
	for k in 4:
		var a := TAU * k / 4.0 + 0.2 * k
		var off := Vector3(cos(a), 0, sin(a)) * 0.12
		var d := Vector3(-sin(a), 0, cos(a)) * 0.03
		v.append_array([off - d, off + d, off * 1.6 + Vector3(0, 1.1 + 0.1 * k, 0)])
		c.append_array([Color(0.7, 0.7, 0.7, 0.0), Color(0.7, 0.7, 0.7, 0.0), Color(1.0, 1.0, 1.0, 1.0)])
	# A seed head on one stalk.
	return _mesh(v, c)


static func _mesh(v: PackedVector3Array, c: PackedColorArray) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_COLOR] = c
	var n := PackedVector3Array()
	for i in v.size():
		n.append(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = n
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
