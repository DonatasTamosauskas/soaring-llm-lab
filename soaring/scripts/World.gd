extends Node3D

# Provides drift for clouds + perch generation

var _clouds: Array[Node3D] = []
var _time: float = 0

func _ready():
    add_to_group("world")
    _build_ground()
    _place_obstacles()
    _spawn_clouds()

func _build_ground():
    var ground = get_node_or_null("Ground")
    var need_build = false
    if not ground:
        ground = StaticBody3D.new()
        ground.name = "Ground"
        add_child(ground)
        need_build = true
    elif ground.get_child_count() == 0:
        need_build = true
    if need_build:
        ground.collision_layer = 1
        ground.collision_mask = 7
        var col = CollisionShape3D.new()
        var shape = BoxShape3D.new()
        shape.size = Vector3(600, 2, 600)
        col.shape = shape
        col.position.y = -1
        ground.add_child(col)
        var mesh = MeshInstance3D.new()
        var pm = PlaneMesh.new()
        pm.size = Vector2(600, 600)
        mesh.mesh = pm
        var mat = StandardMaterial3D.new()
        mat.albedo_color = Color(0.28, 0.42, 0.22, 1)
        mat.roughness = 0.92
        mesh.material_override = mat
        mesh.position.y = 0
        ground.add_child(mesh)

func _place_obstacles():
    # Trees
    var rng = RandomNumberGenerator.new()
    rng.seed = 1337
    for i in range(28):
        var x = rng.randf_range(-140, 140)
        var z = rng.randf_range(-140, 140)
        if abs(x) < 18 and abs(z) < 18: continue # clear spawn
        _spawn_tree(Vector3(x, 0, z), rng.randf_range(7, 18), rng.randf_range(0.8, 1.8))

    # Utility poles with wires (great for perching / slalom)
    for i in range(14):
        var x = rng.randf_range(-110, 110)
        var z = rng.randf_range(-110, 110)
        if abs(x)<10 and abs(z)<10: continue
        _spawn_pole(Vector3(x, 0, z), rng.randf_range(9, 16))

    # Buildings with ledges/windows
    for i in range(10):
        var x = rng.randf_range(-125, 125)
        var z = rng.randf_range(-125, 125)
        if abs(x)<22 and abs(z)<22: continue
        _spawn_building(Vector3(x, 0, z), rng.randf_range(8,16), rng.randf_range(12,28), rng.randf_range(8,16))

    # Branches in air (floating perches for air gameplay)
    for i in range(18):
        var p = Vector3(rng.randf_range(-95,95), rng.randf_range(13, 44), rng.randf_range(-95,95))
        _spawn_air_branch(p, rng.randf_range(2.2, 5.0))

func _spawn_tree(pos: Vector3, h: float, r: float):
    var tree = Node3D.new()
    tree.position = pos
    add_child(tree)
    # trunk
    var trunk_body = StaticBody3D.new()
    trunk_body.add_to_group("perch")
    trunk_body.add_to_group("obstacle")
    var trunk_col = CollisionShape3D.new()
    var cyl = CylinderShape3D.new()
    cyl.height = h
    cyl.radius = 0.45 * r
    trunk_col.shape = cyl
    trunk_col.position.y = h*0.5
    trunk_body.add_child(trunk_col)
    var trunk_mesh = MeshInstance3D.new()
    var cm = CylinderMesh.new()
    cm.height = h; cm.top_radius = 0.42*r; cm.bottom_radius=0.62*r
    trunk_mesh.mesh = cm
    var tmat = StandardMaterial3D.new()
    tmat.albedo_color = Color(0.32, 0.21, 0.13, 1)
    tmat.roughness = 0.88
    trunk_mesh.material_override = tmat
    trunk_mesh.position.y = h*0.5
    trunk_body.add_child(trunk_mesh)
    tree.add_child(trunk_body)

    # foliage
    var foliage = MeshInstance3D.new()
    var sph = SphereMesh.new()
    sph.radius = 2.4*r; sph.height = 4.2*r
    foliage.mesh = sph
    var fmat = StandardMaterial3D.new()
    fmat.albedo_color = Color(0.18, 0.52, 0.18, 1).lerp(Color(0.42,0.62,0.18,1), randf()*0.5)
    fmat.roughness = 0.9
    foliage.material_override = fmat
    foliage.position.y = h + 0.6
    tree.add_child(foliage)

    # branch perches
    for k in range(randi_range(2,4)):
        var b = StaticBody3D.new()
        b.add_to_group("perch")
        b.position.y = h* randf_range(0.55, 0.88)
        b.position.x = randf_range(-1.8, 1.8)
        b.position.z = randf_range(-1.8, 1.8)
        var bc = CollisionShape3D.new()
        var bs = BoxShape3D.new()
        bs.size = Vector3(randf_range(2.4,4.5), 0.28, 0.28)
        bc.shape = bs
        b.add_child(bc)
        var bm = MeshInstance3D.new()
        var boxm = BoxMesh.new()
        boxm.size = bs.size
        bm.mesh = boxm
        var bmat = StandardMaterial3D.new()
        bmat.albedo_color = Color(0.32,0.22,0.14,1)
        bm.material_override = bmat
        b.add_child(bm)
        # random yaw
        b.rotation.y = randf()*TAU
        tree.add_child(b)

func _spawn_pole(pos: Vector3, h: float):
    var pole = StaticBody3D.new()
    pole.position = pos
    pole.add_to_group("obstacle")
    var col = CollisionShape3D.new()
    var cyl = CylinderShape3D.new()
    cyl.height = h; cyl.radius = 0.18
    col.shape = cyl; col.position.y = h*0.5
    pole.add_child(col)
    var mesh = MeshInstance3D.new()
    var cm = CylinderMesh.new()
    cm.height = h; cm.top_radius=0.16; cm.bottom_radius=0.19
    mesh.mesh = cm
    var mat = StandardMaterial3D.new()
    mat.albedo_color = Color(0.42,0.38,0.34,1)
    mesh.material_override = mat
    mesh.position.y = h*0.5
    pole.add_child(mesh)
    add_child(pole)
    # crossbar
    var bar = StaticBody3D.new()
    bar.add_to_group("perch")
    bar.position = pos + Vector3(0, h-0.45, 0)
    var bcol = CollisionShape3D.new()
    var bs = BoxShape3D.new()
    bs.size = Vector3(3.2, 0.18, 0.18)
    bcol.shape = bs
    bar.add_child(bcol)
    var bmesh = MeshInstance3D.new()
    var bx = BoxMesh.new()
    bx.size = bs.size
    bmesh.mesh = bx
    var bmat = StandardMaterial3D.new()
    bmat.albedo_color = Color(0.32,0.28,0.24,1)
    bmesh.material_override = bmat
    bar.add_child(bmesh)
    add_child(bar)
    # insulators perching points
    for s in [-1.25, 1.25]:
        var ins = StaticBody3D.new()
        ins.add_to_group("perch")
        ins.position = pos + Vector3(s, h-0.18, 0)
        var ic = CollisionShape3D.new()
        var sp = SphereShape3D.new()
        sp.radius = 0.28
        ic.shape = sp
        ins.add_child(ic)
        var im = MeshInstance3D.new()
        var sm = SphereMesh.new()
        sm.radius=0.26; sm.height=0.52
        im.mesh = sm
        var imat = StandardMaterial3D.new()
        imat.albedo_color = Color(0.82,0.82,0.78,1)
        im.material_override = imat
        ins.add_child(im)
        add_child(ins)
    # wires (visual only) to next pole - skip physics

func _spawn_building(pos: Vector3, w: float, h: float, d: float):
    var b = StaticBody3D.new()
    b.position = pos
    b.add_to_group("obstacle")
    var col = CollisionShape3D.new()
    var box = BoxShape3D.new()
    box.size = Vector3(w,h,d)
    col.shape = box; col.position.y = h*0.5
    b.add_child(col)
    var mesh = MeshInstance3D.new()
    var bm = BoxMesh.new()
    bm.size = box.size
    mesh.mesh = bm
    var mat = StandardMaterial3D.new()
    mat.albedo_color = Color(0.72,0.70,0.66,1).lerp(Color(0.52,0.58,0.72,1), randf()*0.35)
    mat.roughness = 0.82
    mesh.material_override = mat
    mesh.position.y = h*0.5
    b.add_child(mesh)
    add_child(b)
    # ledges
    var floors = int(h/3.2)
    for f in range(1, floors):
        var y = f*3.2 + 0.9
        # front ledge
        var ledge = StaticBody3D.new()
        ledge.add_to_group("perch")
        ledge.position = pos + Vector3(0, y, d*0.5 + 0.45)
        var lc = CollisionShape3D.new()
        var lb = BoxShape3D.new()
        lb.size = Vector3(w*0.92, 0.22, 0.95)
        lc.shape = lb
        ledge.add_child(lc)
        var lm = MeshInstance3D.new()
        var lxm = BoxMesh.new()
        lxm.size = lb.size
        lm.mesh = lxm
        var lmat = StandardMaterial3D.new()
        lmat.albedo_color = Color(0.68,0.66,0.62,1)
        lm.material_override = lmat
        ledge.add_child(lm)
        add_child(ledge)
        # add small side perches
        if randf()<0.5:
            var sledge = StaticBody3D.new()
            sledge.add_to_group("perch")
            sledge.position = pos + Vector3(w*0.5+0.45, y, 0)
            var sc = CollisionShape3D.new()
            sc.shape = BoxShape3D.new()
            sc.shape.size = Vector3(0.9,0.18, d*0.68)
            sledge.add_child(sc)
            var sm = MeshInstance3D.new()
            sm.mesh = BoxMesh.new()
            sm.mesh.size = sc.shape.size
            sm.material_override = lmat
            sledge.add_child(sm)
            add_child(sledge)

func _spawn_air_branch(pos: Vector3, length: float):
    var br = StaticBody3D.new()
    br.position = pos
    br.add_to_group("perch")
    br.rotation.y = randf()*TAU
    br.rotation.z = randf_range(-0.18, 0.18)
    var col = CollisionShape3D.new()
    var box = BoxShape3D.new()
    box.size = Vector3(length, 0.28, 0.28)
    col.shape = box
    br.add_child(col)
    var mesh = MeshInstance3D.new()
    var bm = BoxMesh.new()
    bm.size = box.size
    mesh.mesh = bm
    var mat = StandardMaterial3D.new()
    mat.albedo_color = Color(0.34,0.24,0.15,1)
    mat.roughness = 0.82
    mesh.material_override = mat
    br.add_child(mesh)
    # leaves puff
    for k in range(2):
        var puff = MeshInstance3D.new()
        var sph = SphereMesh.new()
        sph.radius = 0.85; sph.height=1.3
        puff.mesh = sph
        puff.position = Vector3(randf_range(-length*0.32,length*0.32), 0.45, randf_range(-0.35,0.35))
        var lmat = StandardMaterial3D.new()
        lmat.albedo_color = Color(0.24,0.58,0.2,1)
        puff.material_override = lmat
        br.add_child(puff)
    add_child(br)

func _spawn_clouds():
    for i in range(14):
        var c = Node3D.new()
        c.position = Vector3(randf_range(-180,180), randf_range(38, 72), randf_range(-180,180))
        c.scale = Vector3.ONE * randf_range(3.5, 8.5)
        c.name = "Cloud_%d"%i
        for k in range(randi_range(3,6)):
            var puff = MeshInstance3D.new()
            var sph = SphereMesh.new()
            sph.radius = randf_range(0.9, 1.7); sph.height = sph.radius*1.9
            puff.mesh = sph
            puff.position = Vector3(randf_range(-1.8,1.8), randf_range(-0.5,0.5), randf_range(-1.8,1.8))
            var mat = StandardMaterial3D.new()
            mat.albedo_color = Color(1,1,1, randf_range(0.78,0.96))
            mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
            mat.roughness = 1.0
            puff.material_override = mat
            c.add_child(puff)
        add_child(c)
        _clouds.append(c)

func drift(delta):
    _time += delta
    for c in _clouds:
        c.position.x += sin(_time*0.06 + c.position.z*0.008)* delta * 1.8
        c.position.z += delta * 0.55
        if c.position.z > 210: c.position.z = -210
        if c.position.x > 210: c.position.x = -210
        if c.position.x < -210: c.position.x = 210
