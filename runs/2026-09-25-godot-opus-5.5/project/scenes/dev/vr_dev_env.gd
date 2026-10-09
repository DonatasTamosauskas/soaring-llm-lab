extends RefCounted
## Builders for the VR area's own test rig and a small low-poly practice
## field (dev scene, screenshots, simulator harness). Depends only on core
## contracts and the VR area's scripts: the flight area's player scene is
## built in parallel, so this rig is a stand-in with the same shape
## (Bird "player" -> XROrigin3D "player_rig" -> XRCamera3D + grip
## XRController3Ds) and the VR extras attached exactly as integration will.

const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const EXTRAS := preload("res://scenes/vr/vr_rig_extras.tscn")


## Sky, sun, a meadow with posts, trees and a wall to give optic flow.
## Returns the root node (added under parent).
static func build_environment(parent: Node, seed_value: int = 7) -> Node3D:
	var root := Node3D.new()
	root.name = "Field"
	parent.add_child(root)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.30, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.90)
	sky_mat.ground_horizon_color = Color(0.62, 0.70, 0.58)
	sky_mat.ground_bottom_color = Color(0.30, 0.38, 0.26)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.80, 0.88)
	env.fog_density = 0.0025
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-48.0), deg_to_rad(-35.0), 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	root.add_child(sun)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_ground(st, rng)
	for k in 26:
		var p := Vector3(rng.randf_range(-60, 60), 0, rng.randf_range(-90, 10))
		if p.length() < 6.0:
			continue
		_tree(st, p, rng.randf_range(2.5, 5.5), rng)
	for k in 12:
		_post(st, Vector3(-4.0 + k * 0.0, 0, -6.0 - k * 5.0), 3.2, Color(0.45, 0.33, 0.22))
		_post(st, Vector3(4.0, 0, -6.0 - k * 5.0), 3.2, Color(0.45, 0.33, 0.22))
	_box(st, Vector3(10.0, 0.0, -30.0), Vector3(1.0, 9.0, 40.0), Color(0.78, 0.72, 0.62))
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "FieldMesh"
	mi.mesh = st.commit()
	mi.material_override = mat
	root.add_child(mi)
	# One static collider set so the vignette's probe rays have
	# something to hit (layer 1 = world).
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.shape = mi.mesh.create_trimesh_shape()
	body.add_child(shape)
	root.add_child(body)
	return root


static func _flat_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	st.set_color(col)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _ground(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var n := 18
	var size := 12.0
	var h := {}
	for i in n + 1:
		for j in n + 1:
			h[Vector2i(i, j)] = rng.randf_range(-0.25, 0.25)
	for i in n:
		for j in n:
			var x0 := (i - n / 2) * size
			var z0 := (j - n / 2) * size - 40.0
			var p00 := Vector3(x0, h[Vector2i(i, j)], z0)
			var p10 := Vector3(x0 + size, h[Vector2i(i + 1, j)], z0)
			var p01 := Vector3(x0, h[Vector2i(i, j + 1)], z0 + size)
			var p11 := Vector3(x0 + size, h[Vector2i(i + 1, j + 1)], z0 + size)
			var g := 0.03 * rng.randf_range(-1, 1)
			_flat_tri(st, p00, p10, p11, Color(0.42 + g, 0.62 + g, 0.30))
			_flat_tri(st, p00, p11, p01, Color(0.46 + g, 0.65 + g, 0.32))


static func _tree(st: SurfaceTool, p: Vector3, height: float, rng: RandomNumberGenerator) -> void:
	_post(st, p, height * 0.45, Color(0.40, 0.28, 0.18), 0.12)
	var leaf := Color(0.22, 0.46 + rng.randf_range(-0.05, 0.05), 0.24)
	var top := p + Vector3(0, height, 0)
	var base_y := height * 0.35
	var r := height * 0.33
	var k := 6
	for i in k:
		var a0 := TAU * i / k
		var a1 := TAU * (i + 1) / k
		var b0 := p + Vector3(cos(a0) * r, base_y, sin(a0) * r)
		var b1 := p + Vector3(cos(a1) * r, base_y, sin(a1) * r)
		_flat_tri(st, b0, top, b1, leaf.lightened(0.08 * (i % 2)))
		_flat_tri(st, b1, p + Vector3(0, base_y, 0), b0, leaf.darkened(0.2))


static func _post(st: SurfaceTool, p: Vector3, height: float, col: Color, r: float = 0.08) -> void:
	var k := 5
	for i in k:
		var a0 := TAU * i / k
		var a1 := TAU * (i + 1) / k
		var d0 := Vector3(cos(a0) * r, 0, sin(a0) * r)
		var d1 := Vector3(cos(a1) * r, 0, sin(a1) * r)
		_flat_tri(st, p + d0, p + d1 + Vector3(0, height, 0), p + d1, col.darkened(0.05 * (i % 2)))
		_flat_tri(st, p + d0, p + d0 + Vector3(0, height, 0), p + d1 + Vector3(0, height, 0), col.darkened(0.05 * (i % 2)))


static func _box(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var p := c + Vector3(0, h.y, 0)
	var v := [
		p + Vector3(-h.x, -h.y, -h.z), p + Vector3(h.x, -h.y, -h.z), p + Vector3(h.x, h.y, -h.z), p + Vector3(-h.x, h.y, -h.z),
		p + Vector3(-h.x, -h.y, h.z), p + Vector3(h.x, -h.y, h.z), p + Vector3(h.x, h.y, h.z), p + Vector3(-h.x, h.y, h.z),
	]
	var faces := [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]]
	for f in faces:
		_flat_tri(st, v[f[0]], v[f[1]], v[f[2]], col.darkened(0.04 * f[0]))
		_flat_tri(st, v[f[0]], v[f[2]], v[f[3]], col.darkened(0.04 * f[0]))


## The stand-in player rig with the VR extras attached. Returns
## {player, origin, camera, left, right, extras, puppet}.
## store: where calibration persists (null = Settings; pass a memory store
## in automated runs so the shared settings file is never written).
## origin_always false builds the origin as INHERIT (like a rig someone
## forgot to mark): the extras must fix it when they attach.
## with_extras false: a bare rig (the extras placed elsewhere find it by
## the "player_rig" group; "extras" is then null).
static func build_rig(parent: Node, at: Vector3 = Vector3.ZERO, store: Object = null, with_puppet: bool = true, persist: bool = false, origin_always: bool = true, with_extras: bool = true) -> Dictionary:
	var player: Node3D = StubPlayer.new()
	player.name = "PlayerStub"
	player.position = at
	# Like the flight area's PlayerBird: the body is pausable, the rig is not.
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	origin.add_to_group(&"player_rig")
	origin.process_mode = Node.PROCESS_MODE_ALWAYS if origin_always else Node.PROCESS_MODE_INHERIT
	player.add_child(origin)
	var cam := XRCamera3D.new()
	cam.name = "XRCamera3D"
	cam.position = Vector3(0, 1.6, 0)
	cam.far = 3000.0
	origin.add_child(cam)
	# Aim-pose controllers first, as on flight's player.tscn (LeftAim /
	# RightAim) and UI's pointers (UIAim_*): the extras must pick the grip
	# ones whatever the child order (a verifier's mutant that preferred aim
	# poses survived a stub rig without them).
	for side in [&"left_hand", &"right_hand"]:
		var a := XRController3D.new()
		a.name = "LeftAim" if side == &"left_hand" else "RightAim"
		a.tracker = side
		a.pose = &"aim"
		origin.add_child(a)
	var hands: Array[XRController3D] = []
	for side in [&"left_hand", &"right_hand"]:
		var c := XRController3D.new()
		c.name = "LeftHand" if side == &"left_hand" else "RightHand"
		c.tracker = side
		c.pose = &"grip"
		origin.add_child(c)
		hands.append(c)
	var extras: VRRigExtras = null
	if with_extras:
		extras = EXTRAS.instantiate() as VRRigExtras
		var cal := extras.get_node("Calibration") as VRCalibration
		cal.store = store
		cal.persist = persist
		origin.add_child(extras)
	parent.add_child(player)
	var puppet: VRPosePuppet = null
	if with_puppet:
		puppet = VRPosePuppet.new()
		puppet.name = "Puppet"
		puppet.origin = origin
		puppet.camera = cam
		puppet.hands = [hands[0], hands[1]]
		parent.add_child(puppet)
	return {"player": player, "origin": origin, "camera": cam, "left": hands[0], "right": hands[1],
		"extras": extras, "puppet": puppet}
