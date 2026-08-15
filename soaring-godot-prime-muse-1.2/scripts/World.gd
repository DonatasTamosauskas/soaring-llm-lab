extends Node3D

var _clouds: Array[Node3D] = []
var _time: float = 0.0

func _ready():
    if has_meta("_built"):
        return
    set_meta("_built", true)
    add_to_group("world")
    _build_ground()
    _place_hills()
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
        col.position.y = -1.0
        ground.add_child(col)
        # low-poly ground with vertex color variation via textured plane
        var pm = PlaneMesh.new()
        pm.size = Vector2(600, 600)
        pm.subdivide_width = 16
        pm.subdivide_depth = 16
        var mi = MeshInstance3D.new()
        mi.mesh = pm
        var m = StandardMaterial3D.new()
        m.albedo_color = Color(0.34, 0.48, 0.24, 1)
        m.roughness = 0.94
        mi.material_override = m
        ground.add_child(mi)
        # add low-poly scrub patches as particles (optional)

func _place_hills():
    var rng = RandomNumberGenerator.new()
    rng.seed = 2025
    for i in range(14):
        var x = rng.randf_range(-240, 240)
        var z = rng.randf_range(-240, 240)
        var d = Vector2(x,z).length()
        if d < 36: continue
        if d > 190: continue
        var r = rng.randf_range(18, 42)
        var h = rng.randf_range(4.5, 12)
        var col = Color(0.32, 0.45, 0.22, 1).lerp(Color(0.48, 0.42, 0.28, 1), rng.randf()*0.22)
        var hill = LowPolyFactory.create_hill(Vector3(x, -0.4, z), r, h, col)
        add_child(hill)
        # collision for hilltop
        var hcol = StaticBody3D.new()
        hcol.position = Vector3(x, 0, z)
        hcol.collision_layer = 1
        var cs = CollisionShape3D.new()
        var sph = SphereShape3D.new()
        sph.radius = r * 0.62
        cs.shape = sph
        cs.position.y = 1.2
        hcol.add_child(cs)
        hcol.add_to_group("perch")
        add_child(hcol)

func _place_obstacles():
    var rng = RandomNumberGenerator.new()
    rng.seed = 1337
    for i in range(28):
        var x = rng.randf_range(-148, 148)
        var z = rng.randf_range(-148, 148)
        if abs(x) < 18 and abs(z) < 18: continue
        _spawn_tree(Vector3(x, 0, z), rng.randf_range(7, 19), rng.randf_range(0.82, 1.95))
    for i in range(14):
        var x = rng.randf_range(-115, 115)
        var z = rng.randf_range(-115, 115)
        if abs(x) < 10 and abs(z) < 10: continue
        _spawn_pole(Vector3(x, 0, z), rng.randf_range(9, 16))
    for i in range(11):
        var x = rng.randf_range(-132, 132)
        var z = rng.randf_range(-132, 132)
        if abs(x) < 22 and abs(z) < 22: continue
        _spawn_building(Vector3(x, 0, z), rng.randf_range(8, 17), rng.randf_range(12, 29), rng.randf_range(8, 17))
    for i in range(18):
        var p = Vector3(rng.randf_range(-96,96), rng.randf_range(13, 44), rng.randf_range(-96,96))
        _spawn_air_branch(p, rng.randf_range(2.2, 5.4))
    # also scatter wind-ring markers (hoops to fly through) for acrobatic flow
    var hoop_rng = RandomNumberGenerator.new()
    hoop_rng.seed = 7777
    for i in range(14):
        var a = Vector3(hoop_rng.randf_range(-110,110), hoop_rng.randf_range(9, 36), hoop_rng.randf_range(-110,110))
        var b = a + Vector3(hoop_rng.randf_range(-18,18), hoop_rng.randf_range(-4,4), hoop_rng.randf_range(-18,18))
        _spawn_hoop(a, b)

func _spawn_tree(pos: Vector3, h: float, r: float):
    var tree_root = Node3D.new()
    tree_root.position = pos
    add_child(tree_root)
    var mesh = LowPolyFactory.create_lowpoly_tree(h, r)
    tree_root.add_child(mesh)
    # collision trunk + perches
    var trunk_body = StaticBody3D.new()
    trunk_body.add_to_group("perch")
    trunk_body.add_to_group("obstacle")
    var cyl = CylinderShape3D.new()
    cyl.height = h
    cyl.radius = 0.45 * r
    var col = CollisionShape3D.new()
    col.shape = cyl
    col.position.y = h*0.5
    trunk_body.add_child(col)
    tree_root.add_child(trunk_body)
    # invisible branch perches
    for k in range(randi_range(2,4)):
        var b = StaticBody3D.new()
        b.add_to_group("perch")
        b.position = Vector3(randf_range(-1.8,1.8), h*randf_range(0.52,0.88), randf_range(-1.8,1.8))
        b.rotation.y = randf()*TAU
        var bc = CollisionShape3D.new()
        var bs = BoxShape3D.new()
        bs.size = Vector3(randf_range(2.4,4.6), 0.20, 0.20)
        bc.shape = bs
        b.add_child(bc)
        tree_root.add_child(b)

func _spawn_pole(pos: Vector3, h: float):
    var root = Node3D.new()
    root.position = pos
    add_child(root)
    # low-poly pole = 6-sided prism as cylinder
    var pole_mesh = LowPolyFactory.cylinder(h, 0.14, 0.18, 6, Color(0.42, 0.38, 0.33, 1))
    pole_mesh.position.y = h * 0.5
    root.add_child(pole_mesh)
    var pole_col = StaticBody3D.new()
    pole_col.collision_layer = 1
    var cyl = CylinderShape3D.new()
    cyl.height = h; cyl.radius = 0.18
    var cs = CollisionShape3D.new()
    cs.shape = cyl; cs.position.y = h*0.5
    pole_col.add_child(cs)
    root.add_child(pole_col)
    # crossbar perch
    var bar = StaticBody3D.new()
    bar.add_to_group("perch")
    bar.position = Vector3(0, h-0.45, 0)
    var bcol = CollisionShape3D.new()
    var bs = BoxShape3D.new()
    bs.size = Vector3(3.2, 0.14, 0.14)
    bcol.shape = bs
    bar.add_child(bcol)
    root.add_child(bar)
    var bar_mesh = LowPolyFactory.box(bs.size, Color(0.32, 0.30, 0.26, 1))
    bar.add_child(bar_mesh)
    # insulators
    for s in [-1.25, 1.25]:
        var ins = StaticBody3D.new()
        ins.add_to_group("perch")
        ins.position = Vector3(s, h-0.18, 0)
        var sp = SphereShape3D.new()
        sp.radius = 0.24
        var ic = CollisionShape3D.new()
        ic.shape = sp
        ins.add_child(ic)
        var im = MeshInstance3D.new()
        var sm = SphereMesh.new()
        sm.radius = 0.22; sm.height = 0.44; sm.radial_segments = 6; sm.rings = 4
        im.mesh = sm
        im.material_override = StandardMaterial3D.new()
        im.material_override.albedo_color = Color(0.82, 0.82, 0.80, 1)
        ins.add_child(im)
        root.add_child(ins)
    # wire visual = thin box
    # (skipped; could add line mesh between poles by storing)

func _spawn_building(pos: Vector3, w: float, h: float, d: float):
    var root = LowPolyFactory.create_building(w, h, d)
    root.position = pos
    add_child(root)
    # collision
    var body = StaticBody3D.new()
    body.position = pos
    body.collision_layer = 1
    var col = CollisionShape3D.new()
    var box = BoxShape3D.new()
    box.size = Vector3(w,h,d)
    col.shape = box; col.position.y = h*0.5
    body.add_child(col)
    body.add_to_group("obstacle")
    add_child(body)
    # perches: ledges
    var floors = int(h/3.2)
    for f in range(1, floors):
        var y = f*3.2 + 0.9
        var ledge = StaticBody3D.new()
        ledge.add_to_group("perch")
        ledge.position = pos + Vector3(0, y, d*0.5 + 0.42)
        var lc = CollisionShape3D.new()
        var lb = BoxShape3D.new()
        lb.size = Vector3(w*0.90, 0.16, 0.82)
        lc.shape = lb
        ledge.add_child(lc)
        add_child(ledge)
        if randf()<0.42:
            var sledge = StaticBody3D.new()
            sledge.add_to_group("perch")
            sledge.position = pos + Vector3(w*0.5+0.42, y, 0)
            var sc = CollisionShape3D.new()
            var sbox = BoxShape3D.new()
            sbox.size = Vector3(0.82,0.14, d*0.62)
            sc.shape = sbox
            sledge.add_child(sc)
            add_child(sledge)

func _spawn_air_branch(pos: Vector3, length: float):
    var root = LowPolyFactory.create_perch_branch(length)
    root.position = pos
    root.rotation.y = randf()*TAU
    root.rotation.z = randf_range(-0.18, 0.18)
    add_child(root)
    var body = StaticBody3D.new()
    body.position = pos
    body.rotation.y = root.rotation.y
    body.rotation.z = root.rotation.z
    body.add_to_group("perch")
    var col = CollisionShape3D.new()
    var box = BoxShape3D.new()
    box.size = Vector3(length, 0.20, 0.20)
    col.shape = box
    body.add_child(col)
    add_child(body)

func _spawn_hoop(a: Vector3, b: Vector3):
    var dir = (b - a)
    if dir.length_squared() < 0.001:
        return
    var mid = (a + b) * 0.5
    var hoop = Node3D.new()
    hoop.position = mid
    if dir.length_squared() > 0.001:
        hoop.basis = Basis.looking_at(dir.normalized(), Vector3.UP)
    # visual torus approximated as thin box ring (low poly)
    for k in range(10):
        var seg = LowPolyFactory.box(Vector3(0.10, 0.10, 3.2), Color(0.92, 0.42, 0.28, 1).lerp(Color(0.92,0.82,0.18,1), float(k)/9.0))
        seg.position = Vector3(cos(k/10.0*TAU)*1.35, sin(k/10.0*TAU)*1.35, 0)
        hoop.add_child(seg)
    add_child(hoop)
    # invisible trigger for flow boost
    var area = Area3D.new()
    area.monitorable = true
    area.monitoring = true
    hoop.add_child(area)
    var cs = CollisionShape3D.new()
    var cyl = CylinderShape3D.new()
    cyl.height = 0.42; cyl.radius = 1.35
    cs.shape = cyl
    area.add_child(cs)
    area.body_entered.connect(func(body): 
        if body.is_in_group("player") and body.has_method("_do_flap"):
            # speed ring boost
            body.velocity += body.velocity.normalized() * 4.2 + Vector3.UP * 1.2
    )

func _spawn_clouds():
    for i in range(14):
        var c = LowPolyFactory.create_cloud(Vector3(randf_range(-182,182), randf_range(40, 74), randf_range(-182,182)), randf_range(3.2, 7.8))
        c.name = "Cloud_%d"%i
        add_child(c)
        _clouds.append(c)

func drift(delta: float):
    if not is_finite(delta) or delta <= 0.0:
        return
    delta = clamp(delta, 0.0, 0.05)
    _time += delta
    for c in _clouds:
        if c == null or not is_instance_valid(c):
            continue
        if not c.global_position.is_finite():
            continue
        c.position.x += sin(_time * 0.06 + c.position.z * 0.008) * delta * 1.8
        c.position.z += delta * 0.55
        if c.position.z > 210.0: c.position.z = -210.0
        if c.position.x > 210.0: c.position.x = -210.0
        if c.position.x < -210.0: c.position.x = 210.0

func is_finite(v: float) -> bool:
    return not is_nan(v) and not is_inf(v)
