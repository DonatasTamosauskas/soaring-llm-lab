class_name UIBackdrop
extends Node3D
## A small low-poly stand-in world for UI dev scenes and screenshots: sky,
## sun, faceted hills, a few trees and a perch branch, lit and tonemapped
## like the real world (Filmic, white 6) so panel colours are judged under
## the same conditions. Built in code; no dependency on the world area.

const SKY_TOP := Color("4f86c6")
const SKY_HORIZON := Color("b9d6ec")
const GRASS := Color("6b9e4f")
const GRASS_DARK := Color("58884a")
const HILL := Color("7fa35e")
const TRUNK := Color("7a5236")
const LEAF := Color("4f8a45")
const LEAF_LIGHT := Color("66a152")
const ROCK := Color("9b958a")

var environment: Environment


func _ready() -> void:
	var we := WorldEnvironment.new()
	environment = Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_horizon_color = SKY_HORIZON.darkened(0.1)
	sky_mat.ground_bottom_color = GRASS_DARK
	var sky := Sky.new()
	sky.sky_material = sky_mat
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_white = 6.0
	environment.fog_enabled = true
	environment.fog_light_color = SKY_HORIZON
	environment.fog_density = 0.002
	we.environment = environment
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)
	_build_ground()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 9:
		var a := TAU * i / 9.0 + rng.randf_range(-0.2, 0.2)
		var r := rng.randf_range(160.0, 260.0)
		_hill(Vector3(cos(a) * r, 0, sin(a) * r), rng.randf_range(50, 90), rng.randf_range(25, 60), rng)
	for i in 26:
		var a := rng.randf_range(0, TAU)
		var r := rng.randf_range(12.0, 90.0)
		_tree(Vector3(cos(a) * r, 0, sin(a) * r), rng.randf_range(4.0, 9.0), rng)
	# A branch just in front of the viewer: panels must stay readable when
	# the bird perches next to geometry (they ignore depth).
	_box(Vector3(0.9, 1.2, -1.1), Vector3(1.6, 0.07, 0.07), TRUNK, Vector3(0, 25, 8))


func _flat_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


func _build_ground() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1200, 1200)
	mi.mesh = pm
	mi.material_override = _flat_material(GRASS)
	add_child(mi)


func _hill(pos: Vector3, radius: float, height: float, rng: RandomNumberGenerator) -> void:
	# A faceted cone with jittered rim: flat-shaded low-poly hill.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 9
	var top := Vector3(rng.randf_range(-0.2, 0.2) * radius, height, rng.randf_range(-0.2, 0.2) * radius)
	var rim: Array[Vector3] = []
	for i in n:
		var a := TAU * i / n
		var rr := radius * rng.randf_range(0.8, 1.15)
		rim.append(Vector3(cos(a) * rr, 0, sin(a) * rr))
	for i in n:
		var a := rim[i]
		var b := rim[(i + 1) % n]
		st.set_color(HILL.darkened(rng.randf_range(0.0, 0.18)))
		st.add_vertex(top)
		st.add_vertex(b)
		st.add_vertex(a)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := _flat_material(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


func _tree(pos: Vector3, h: float, rng: RandomNumberGenerator) -> void:
	var trunk := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = h * 0.04
	cm.bottom_radius = h * 0.06
	cm.height = h * 0.45
	cm.radial_segments = 5
	cm.rings = 1
	trunk.mesh = cm
	trunk.material_override = _flat_material(TRUNK)
	trunk.position = pos + Vector3(0, h * 0.22, 0)
	add_child(trunk)
	for k in 2:
		var crown := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = h * (0.34 - k * 0.08)
		cone.height = h * (0.55 - k * 0.1)
		cone.radial_segments = 6
		cone.rings = 1
		crown.mesh = cone
		crown.material_override = _flat_material(LEAF if k == 0 else LEAF_LIGHT)
		crown.position = pos + Vector3(0, h * (0.62 + k * 0.25), 0)
		crown.rotation.y = rng.randf_range(0, TAU)
		add_child(crown)


func _box(pos: Vector3, size: Vector3, c: Color, rot_deg: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _flat_material(c)
	mi.position = pos
	mi.rotation_degrees = rot_deg
	add_child(mi)
