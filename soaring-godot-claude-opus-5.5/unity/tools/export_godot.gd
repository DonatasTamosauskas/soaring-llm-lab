extends Node
# Read-only bridge: freezes the original generated valley and articulated bird data.
var target := ""
var meshes := []
var nodes := []
var cache := {}
func _ready() -> void:
	target = OS.get_environment("SOARING_UNITY_EXPORT")
	call_deferred("run")
func v(p: Vector3) -> Array:
	return [p.x, p.y, -p.z]
func xf(t: Transform3D) -> Array:
	return [t.basis.x.x,t.basis.x.y,-t.basis.x.z,0,t.basis.y.x,t.basis.y.y,-t.basis.y.z,0,-t.basis.z.x,-t.basis.z.y,t.basis.z.z,0,t.origin.x,t.origin.y,-t.origin.z,1]
func vec_field(a: Variant, i: int, n: int) -> Array:
	var out := []
	if a == null:
		for j in n: out.append(0.0)
	elif a is PackedByteArray:
		for j in n: out.append(a.decode_float((i * n + j) * 4))
	elif a is PackedFloat32Array:
		for j in n: out.append(a[i * n + j])
	else:
		for j in n: out.append(a[i][j])
	return out
func save_mesh(m: Mesh, surface: int) -> int:
	var key := str(m.get_instance_id()) + ":" + str(surface)
	if cache.has(key): return cache[key]
	var id := meshes.size()
	cache[key] = id
	var arrays := m.surface_get_arrays(surface)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var name := "mesh_%04d.bytes" % id
	var f := FileAccess.open(target.path_join(name), FileAccess.WRITE)
	f.store_32(0x534f4152)
	f.store_32(vertices.size())
	f.store_32(indices.size() if not indices.is_empty() else vertices.size())
	for i in vertices.size():
		var n := Vector3.UP
		if arrays[Mesh.ARRAY_NORMAL] != null: n = arrays[Mesh.ARRAY_NORMAL][i]
		var col := Color.WHITE
		if arrays[Mesh.ARRAY_COLOR] != null: col = arrays[Mesh.ARRAY_COLOR][i]
		for x in v(vertices[i]) + v(n) + [col.r,col.g,col.b,col.a]: f.store_float(x)
		for k in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
			for x in vec_field(arrays[k], i, 2): f.store_float(x)
		for k in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			for x in vec_field(arrays[k], i, 4): f.store_float(x)
	for i in (indices if not indices.is_empty() else range(vertices.size())): f.store_32(i)
	f.close()
	meshes.append({"file":name,"vertices":vertices.size(),"triangles":(indices.size() if not indices.is_empty() else vertices.size())/3})
	return id
func traverse(n: Node) -> void:
	if n is MeshInstance3D and n.mesh:
		for s in n.mesh.get_surface_count():
			nodes.append({"name":str(n.name),"mesh":save_mesh(n.mesh,s),"matrix":xf(n.global_transform),"near":n.visibility_range_begin,"far":n.visibility_range_end,"water":"water" in str(n.name).to_lower(),"foliage":"foliage" in str(n.material_override),"soft":"Soft" in str(n.get_path()),"shadowOnly":n.get_meta("shadow_only",false),"castsShadow":n.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF})
	if n is MultiMeshInstance3D and n.multimesh:
		var mm: MultiMesh = n.multimesh
		if mm.mesh:
			var instances := []
			var count := mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
			for i in count:
				var col := mm.get_instance_color(i) if mm.use_colors else Color.WHITE
				instances.append({"matrix":xf(n.global_transform * mm.get_instance_transform(i)),"color":[col.r,col.g,col.b,col.a]})
			nodes.append({"name":str(n.name),"mesh":save_mesh(mm.mesh,0),"matrix":xf(Transform3D.IDENTITY),"instances":instances,"near":n.visibility_range_begin,"far":n.visibility_range_end,"soft":true,"castsShadow":n.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF})
	if n is CollisionObject3D and n.name != "Boundary":
		for owner in n.get_shape_owners():
			if n.is_shape_owner_disabled(owner): continue
			for index in n.shape_owner_get_shape_count(owner):
				capture_shape(n.shape_owner_get_shape(owner,index), n.global_transform * n.shape_owner_get_transform(owner),str(n.name))
	for child in n.get_children(): traverse(child)
func capture_shape(sh: Shape3D, transform: Transform3D, shape_name: String) -> void:
	var rec := {"name":shape_name,"matrix":xf(transform),"type":"","data":[]}
	if sh is ConcavePolygonShape3D:
		var mesh := ArrayMesh.new()
		var arr := []; arr.resize(Mesh.ARRAY_MAX); arr[Mesh.ARRAY_VERTEX] = sh.get_faces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr)
		rec.type = "mesh"; rec.mesh = save_mesh(mesh,0)
	elif sh is BoxShape3D: rec.type = "box"; rec.data = [sh.size.x,sh.size.y,sh.size.z]
	elif sh is SphereShape3D: rec.type = "sphere"; rec.data = [sh.radius]
	elif sh is CapsuleShape3D: rec.type = "capsule"; rec.data = [sh.radius,sh.height]
	elif sh is CylinderShape3D: rec.type = "capsule"; rec.data = [sh.radius,sh.height]
	elif sh is ConvexPolygonShape3D:
		var points: PackedVector3Array = sh.get_points()
		var mesh := ArrayMesh.new(); var arr := []; arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = points
		var indices := PackedInt32Array()
		for i in range(1,points.size()-1): indices.append_array(PackedInt32Array([0,i,i+1]))
		arr[Mesh.ARRAY_INDEX] = indices; mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr)
		rec.type = "convex"; rec.mesh = save_mesh(mesh,0)
	if rec.type != "": colliders.append(rec)
var colliders := []
func run() -> void:
	var w := SoaringWorld.new()
	w.with_environment = false
	get_tree().root.add_child(w)
	await get_tree().physics_frame
	traverse(w)
	var perches := []
	for p in w.get_perches(): perches.append({"position":v(p.position),"facing":v(p.facing),"kind":p.kind,"maxSpan":p.max_span,"district":str(p.district)})
	var landmarks := []
	for l in w.get_landmarks(): landmarks.append({"name":l.name,"kind":l.kind,"position":v(l.position),"radius":l.radius})
	var refuges := []
	for r in w.get_refuges(): refuges.append({"position":v(r.position),"radius":r.radius,"maxSpan":r.max_span})
	var thermals := []
	for t in w.get_thermals(): thermals.append({"name":t.name,"position":v(t.position),"radius":t.radius,"strength":t.strength,"top":t.top,"lean":v(t.lean)})
	var birds := []
	for sp in SizeRules.SPECIES:
		var lods := []
		for lod in 3: lods.append(save_mesh(BirdModels.mesh(sp.id,lod),0))
		birds.append({"id":str(sp.id),"name":sp.name,"mass":sp.mass,"span":sp.span,"meshes":lods})
	var heights := FileAccess.open(target.path_join("heightmap.bytes"),FileAccess.WRITE)
	heights.store_32(0x534f4847); heights.store_32(381)
	for z in 381:
		for x in 381: heights.store_float(w.ground_height(-760.0+x*4.0,760.0-z*4.0))
	heights.close()
	var spawn := w.get_player_spawn()
	var doc := {"version":2,"seed":w.world_seed,"bounds":w.bounds_radius,"ceiling":w.ceiling,"spawn":v(spawn.origin),"facing":v(-spawn.basis.z),"meshes":meshes,"nodes":nodes,"colliders":colliders,"perches":perches,"landmarks":landmarks,"refuges":refuges,"thermals":thermals,"birds":birds}
	var f := FileAccess.open(target.path_join("world.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(doc)); f.close()
	print("UNITY_EXPORT_OK meshes=",meshes.size()," nodes=",nodes.size()," colliders=",colliders.size()," perches=",perches.size())
	get_tree().quit()
