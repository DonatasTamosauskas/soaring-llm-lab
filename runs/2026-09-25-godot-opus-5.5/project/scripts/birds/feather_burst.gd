class_name FeatherBurst
extends Node3D
## A puff of feathers where a bird was caught: a dozen contour feathers in
## the prey's colours tumble out and flutter down, a few pale down tufts
## scatter and shrink first. One MultiMesh (one draw call), simulated on the
## CPU (24 particles), and the node frees itself when the last feather is
## gone. Create with BirdFX.feather_burst().

## Feather length and down size as fractions of the prey's wingspan.
const FEATHER_LEN := 0.24
const DOWN_LEN := 0.1
const FEATHERS := 14
const DOWN := 14
## Feathers are mostly drag: they stop within ~0.3 s and sink slowly,
## swinging side to side like falling leaves.
const DRAG := 6.5
const GRAVITY := 3.2
const SINK := 0.55

static var _mesh: ArrayMesh
static var _material: ShaderMaterial

var span := 0.3
var colors: Array[Color] = []
var inherit_velocity := Vector3.ZERO
var rng_seed := 1
## Seconds since the burst started.
var age := 0.0
## Longest particle lifetime; the node frees itself after it.
var lifetime := 0.0

var _mmi: MultiMeshInstance3D
var _mm: MultiMesh
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _axis := PackedVector3Array()
var _spin := PackedFloat32Array()
var _angle := PackedFloat32Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _sway := PackedFloat32Array()
var _basis: Array[Basis] = []


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var n := FEATHERS + DOWN
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = _feather_mesh()
	_mm.instance_count = n
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = _feather_material()
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles fly a couple of metres at most; a generous box avoids culling.
	_mmi.custom_aabb = AABB(Vector3.ONE * -3.0 * maxf(span, 0.3), Vector3.ONE * 6.0 * maxf(span, 0.3))
	add_child(_mmi)
	if colors.is_empty():
		colors = [Color(0.55, 0.45, 0.35)]
	# A tight puff first (down barely leaves the catch point), then contour
	# feathers drift out: about a wingspan across after half a second. The
	# speed scales with the prey (a sparrow's 2.3 m/s, x span^0.85), so a moth
	# and an eagle burst alike relative to their size.
	var speed := 2.3 * pow(span / 0.24, 0.85)
	for i in n:
		var down := i >= FEATHERS
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1.0), rng.randf_range(-1, 1))
		if dir.length_squared() < 1e-4:
			dir = Vector3.UP
		dir = dir.normalized()
		_pos.append(dir * span * 0.08)
		_vel.append(dir * speed * rng.randf_range(0.5, 1.1) * (0.6 if down else 1.0) + inherit_velocity * 0.3)
		_axis.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized())
		_spin.append(rng.randf_range(6.0, 16.0) * (1.0 if rng.randf() < 0.5 else -1.0))
		_angle.append(rng.randf() * TAU)
		var life := rng.randf_range(0.7, 1.1) if down else rng.randf_range(1.5, 2.3)
		_life.append(life)
		lifetime = maxf(lifetime, life)
		_size.append(span * (DOWN_LEN if down else FEATHER_LEN) * rng.randf_range(0.75, 1.2))
		_sway.append(rng.randf() * TAU)
		_basis.append(Basis(_axis[i], _angle[i]))
		var c: Color = colors[rng.randi() % colors.size()]
		if down:
			c = c.lerp(Color(0.95, 0.93, 0.88), 0.65)
		else:
			c = c.darkened(rng.randf_range(-0.1, 0.15))
		_mm.set_instance_color(i, c)
	_write()


func _process(delta: float) -> void:
	step(delta)


## Advances the simulation (tests call it directly).
func step(delta: float) -> void:
	age += delta
	var drag := exp(-DRAG * delta)
	# Small feathers and a moth's scales hang in the air; big ones fall
	# faster, though not in proportion (capped).
	var sink := SINK * clampf(pow(span / 0.3, 0.7), 0.3, 1.8)
	for i in _pos.size():
		var v := _vel[i]
		v *= drag
		# Settle towards a slow sink, swinging sideways as feathers do.
		v.y -= GRAVITY * delta
		v.y = maxf(v.y, -sink)
		var sw := sin(age * 5.0 + _sway[i]) * sink * 0.9
		v.x += sw * cos(_sway[i]) * delta * 6.0
		v.z += sw * sin(_sway[i]) * delta * 6.0
		_vel[i] = v
		_pos[i] += v * delta
		_spin[i] *= exp(-1.2 * delta)
		_angle[i] += _spin[i] * delta
	_write()
	if age >= lifetime:
		queue_free()


func _write() -> void:
	for i in _pos.size():
		var remain := _life[i] - age
		var s := _size[i] * clampf(remain / 0.35, 0.0, 1.0) * clampf(age / 0.05 + 0.4, 0.0, 1.0)
		var b := Basis(_axis[i], _angle[i]).scaled(Vector3.ONE * maxf(s, 0.0))
		_mm.set_instance_transform(i, Transform3D(b, _pos[i]))


## Live particle count (not yet shrunk away).
func alive_count() -> int:
	var n := 0
	for l in _life:
		if l > age:
			n += 1
	return n


## Mean distance of the particles from the burst centre.
func spread() -> float:
	var s := 0.0
	for p in _pos:
		s += p.length()
	return s / maxf(_pos.size(), 1)


func centroid() -> Vector3:
	var s := Vector3.ZERO
	for p in _pos:
		s += p
	return s / maxf(_pos.size(), 1)


## A contour feather, length 1 along -Z: a vane folded along the rachis
## (low-poly facets catch the light as it tumbles), double-sided.
static func _feather_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tip := Vector3(0, 0, -0.5)
	var base := Vector3(0, 0, 0.5)
	var l := Vector3(-0.16, 0.035, -0.02)
	var r := Vector3(0.12, 0.035, 0.08)
	var quill := Vector3(0, -0.01, 0.62)
	for t in [[tip, l, base], [tip, base, r], [base, l, quill], [base, quill, r]]:
		var n: Vector3 = (t[2] - t[0]).cross(t[1] - t[0]).normalized()
		for v in t:
			st.set_normal(n)
			st.set_color(Color(1, 1, 1) if v != quill else Color(0.85, 0.82, 0.75))
			st.add_vertex(v)
	_mesh = st.commit()
	return _mesh


static func _feather_material() -> ShaderMaterial:
	if _material != null:
		return _material
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;
void fragment() {
	// Instance colours are the prey's sRGB palette.
	vec3 c = COLOR.rgb;
	vec3 lin = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	ALBEDO = lin;
	// Feathers are thin and let light through: both faces are lit alike,
	// with a little translucent glow so tumbling ones never go black.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	BACKLIGHT = lin * 0.6;
	EMISSION = lin * 0.12;
	ROUGHNESS = 0.9;
}
"""
	_material = ShaderMaterial.new()
	_material.shader = sh
	_material.resource_name = "FeatherMaterial"
	return _material
