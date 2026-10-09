extends Node3D
## Original low-poly bird, made of inexpensive shared meshes. No imported art.
const Species = preload("res://scripts/ecology/species.gd")

var left_wing: Node3D
var right_wing: Node3D
var tail: MeshInstance3D
var body: MeshInstance3D
var head: MeshInstance3D
var marker: MeshInstance3D
var phase := 0.0
var body_material: StandardMaterial3D
var accent_material: StandardMaterial3D
var marker_material: StandardMaterial3D
var current_mass := 1.0
static var _models: Array[ArrayMesh] = []
static var _accent_materials: Array[StandardMaterial3D] = []
static var _model_material: StandardMaterial3D
static var _body_mesh: SphereMesh
static var _head_mesh: SphereMesh
static var _wing_mesh: ArrayMesh
static var _tail_mesh: ArrayMesh
static var _beak_mesh: PrismMesh
static var _eye_mesh: SphereMesh
static var _marker_mesh: TorusMesh
static var _white_material: StandardMaterial3D
static var _black_material: StandardMaterial3D
static var _beak_material: StandardMaterial3D

func _init() -> void:
	_make_shared_assets()
	body_material = _model_material
	accent_material = _accent_materials[1]
	marker_material = _material(Color.WHITE)
	# Relation markers use one stable unshaded pipeline. Changing only the
	# color avoids enabling a fresh emissive shader variant during a chase.
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Static anatomy is merged into a single vertex-colored mesh: three draw
	# surfaces per animated bird, with meshes/materials shared by tier.
	body = _instance(_models[1], body_material, Vector3.ZERO)
	left_wing = Node3D.new()
	right_wing = Node3D.new()
	add_child(left_wing)
	add_child(right_wing)
	left_wing.position = Vector3(-0.12, 0.04, 0.0)
	right_wing.position = Vector3(0.12, 0.04, 0.0)
	var left := MeshInstance3D.new()
	left.mesh = _wing_mesh
	left.material_override = accent_material
	left.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	left.scale.x = -1.0
	left_wing.add_child(left)
	var right := MeshInstance3D.new()
	right.mesh = _wing_mesh
	right.material_override = accent_material
	right.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	right_wing.add_child(right)
	marker = _instance(_marker_mesh, marker_material, Vector3(0, 0.8, 0))
	marker.rotation.x = PI / 2.0
	marker.visible = false

func set_mass(mass: float) -> void:
	current_mass = mass
	var tier := Species.tier_index(mass)
	body.mesh = _models[tier]
	accent_material = _accent_materials[tier]
	left_wing.get_child(0).material_override = accent_material
	right_wing.get_child(0).material_override = accent_material
	var size := pow(maxf(mass, 0.1), 1.0 / 3.0)
	scale = Vector3.ONE * size
	# Small swifts have narrow wings; large birds read as broad soaring raptors.
	left_wing.scale.z = 0.82 + Species.tier_index(mass) * 0.14
	right_wing.scale.z = left_wing.scale.z

func animate(delta: float, speed: float, state: String, bank: float) -> void:
	phase += delta * (7.0 if state == "Flee" else 5.8)
	var flap := sin(phase) * (0.48 if state == "Hunt" or state == "Flee" else 0.22)
	if state == "Perch":
		flap = 1.05
	elif state == "Soar":
		flap = sin(phase * 0.35) * 0.035
	left_wing.rotation.z = -flap
	right_wing.rotation.z = flap
	rotation.z = lerpf(rotation.z, bank, minf(delta * 7.0, 1.0))

func set_relation(player_mass: float, distance: float) -> void:
	# Only nearby actionable birds have markers. Color and scale stay legible
	# throughout the flock without filling the sky with text.
	marker.visible = distance < 28.0 and (Species.can_catch(current_mass, player_mass) or Species.reward(player_mass, current_mass) > 0.015)
	if not marker.visible:
		return
	marker_material.albedo_color = Color("fa6871") if Species.can_catch(current_mass, player_mass) else Color("8ae6c0")

func _instance(mesh: Mesh, material: Material, offset: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = offset
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance

static func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material

static func _flat_mesh(vertices: PackedVector3Array, indices: PackedInt32Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	for index in indices:
		surface.add_vertex(vertices[index])
	surface.generate_normals()
	# Index only after normals are baked: vertices at hard edges or opposite
	# wing faces retain distinct normals, colors and winding.
	surface.index()
	return surface.commit()

static func _make_shared_assets() -> void:
	if _body_mesh != null:
		return
	_body_mesh = SphereMesh.new()
	_body_mesh.radius = 0.32
	_body_mesh.height = 0.64
	_body_mesh.radial_segments = 8
	_body_mesh.rings = 3
	_head_mesh = SphereMesh.new()
	_head_mesh.radius = 0.2
	_head_mesh.height = 0.4
	_head_mesh.radial_segments = 8
	_head_mesh.rings = 3
	_eye_mesh = SphereMesh.new()
	_eye_mesh.radius = 0.037
	_eye_mesh.height = 0.074
	_eye_mesh.radial_segments = 6
	_eye_mesh.rings = 2
	_beak_mesh = PrismMesh.new()
	_beak_mesh.size = Vector3(0.11, 0.22, 0.10)
	_wing_mesh = _flat_mesh(PackedVector3Array([
		Vector3(0, 0, -0.2), Vector3(0.98, 0.02, -0.16), Vector3(1.3, -0.015, 0.03),
		Vector3(0.85, 0, 0.32), Vector3(0.26, 0, 0.23), Vector3(0.56, 0.065, 0.02)
	]), PackedInt32Array([0, 1, 5, 1, 2, 5, 2, 3, 5, 3, 4, 5, 4, 0, 5, 5, 1, 0, 5, 2, 1, 5, 3, 2, 5, 4, 3, 5, 0, 4]))
	_tail_mesh = _flat_mesh(PackedVector3Array([
		Vector3(-0.10, 0, 0), Vector3(0.10, 0, 0), Vector3(0.27, 0.02, 0.5), Vector3(-0.27, 0.02, 0.5)
	]), PackedInt32Array([0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0]))
	_marker_mesh = TorusMesh.new()
	_marker_mesh.inner_radius = 0.16
	_marker_mesh.outer_radius = 0.21
	_marker_mesh.rings = 8
	_marker_mesh.ring_segments = 6
	_white_material = _material(Color("f6efdc"))
	_black_material = _material(Color("1d2330"))
	_beak_material = _material(Color("efc768"))
	_model_material = _material(Color.WHITE)
	_model_material.vertex_color_use_as_albedo = true
	# Palette values are authored as sRGB hex colors, matching the separate
	# wing albedo materials after the mobile renderer converts them to linear.
	_model_material.vertex_color_is_srgb = true
	for tier in Species.TIERS:
		_accent_materials.append(_material(tier["accent"]))
		_models.append(_make_model(tier["color"], tier["accent"]))

static func _make_model(color: Color, accent: Color) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	_append_mesh(surface, _body_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(0.64, 0.52, 1.0)), Vector3.ZERO), color)
	_append_mesh(surface, _head_mesh, Transform3D(Basis.IDENTITY, Vector3(0, 0.16, -0.43)), color)
	_append_mesh(surface, _head_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(0.62, 0.72, 0.7)), Vector3(0, 0.08, -0.52)), Color("f6efdc"))
	_append_mesh(surface, _beak_mesh, Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.12, -0.72)), Color("efc768"))
	for side in [-1.0, 1.0]:
		_append_mesh(surface, _eye_mesh, Transform3D(Basis.IDENTITY, Vector3(side * 0.12, 0.22, -0.56)), Color("1d2330"))
	_append_mesh(surface, _tail_mesh, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.35)), accent)
	surface.generate_normals()
	surface.index()
	return surface.commit()

static func _append_mesh(surface: SurfaceTool, mesh: Mesh, transform: Transform3D, color: Color) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	surface.set_color(color)
	if indices.is_empty():
		for vertex in vertices:
			surface.add_vertex(transform * vertex)
	else:
		for index in indices:
			surface.add_vertex(transform * vertices[index])
