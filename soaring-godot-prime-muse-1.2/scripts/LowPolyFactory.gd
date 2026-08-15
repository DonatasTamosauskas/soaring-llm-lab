extends RefCounted
class_name LowPolyFactory

static func mat(color: Color, roughness: float = 0.85) -> StandardMaterial3D:
    var m = StandardMaterial3D.new()
    m.albedo_color = color
    m.roughness = roughness
    m.metallic = 0.0
    return m

static func prism(size: Vector3, color: Color) -> MeshInstance3D:
    var pm = PrismMesh.new()
    pm.size = size
    var mi = MeshInstance3D.new()
    mi.mesh = pm
    mi.material_override = mat(color)
    return mi

static func box(size: Vector3, color: Color) -> MeshInstance3D:
    var bm = BoxMesh.new()
    bm.size = size
    var mi = MeshInstance3D.new()
    mi.mesh = bm
    mi.material_override = mat(color)
    return mi

static func cylinder(height: float, top_r: float, bot_r: float, segs: int, color: Color) -> MeshInstance3D:
    var cm = CylinderMesh.new()
    cm.height = height
    cm.top_radius = top_r
    cm.bottom_radius = bot_r
    cm.radial_segments = segs
    cm.rings = 1
    var mi = MeshInstance3D.new()
    mi.mesh = cm
    mi.material_override = mat(color)
    return mi

static func create_lowpoly_tree(h: float, r: float) -> Node3D:
    var root = Node3D.new()
    var trunk = cylinder(h, 0.32*r, 0.56*r, 6, Color(0.31, 0.21, 0.12, 1))
    trunk.position.y = h * 0.5
    trunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(trunk)
    var palette = [
        Color(0.18, 0.46, 0.16), Color(0.21, 0.52, 0.20), Color(0.28, 0.58, 0.18),
        Color(0.42, 0.56, 0.14), Color(0.18, 0.42, 0.22)
    ]
    var col = palette[randi() % palette.size()].lerp(Color(0.38, 0.46, 0.18, 1), randf()*0.22)
    var cone1 = cylinder(3.8*r, 0.08, 2.18*r, 6, col)
    cone1.position.y = h + 1.1*r
    cone1.rotation.y = randf()*TAU
    root.add_child(cone1)
    var cone2 = cylinder(2.9*r, 0.04, 1.35*r, 6, col.lerp(Color(0.18, 0.52, 0.20, 1), 0.18))
    cone2.position.y = h + 3.2*r
    cone2.rotation.y = randf()*TAU
    root.add_child(cone2)
    var needle = prism(Vector3(0.45*r, 0.9*r, 0.45*r), col.lerp(Color.WHITE, 0.12))
    needle.position.y = h + 4.6*r
    root.add_child(needle)
    return root

static func create_building(w: float, h: float, d: float) -> Node3D:
    var root = Node3D.new()
    var base_col = Color(0.71, 0.69, 0.64, 1).lerp(Color(0.54, 0.60, 0.74, 1), randf()*0.38)
    var box_mesh = box(Vector3(w, h, d), base_col)
    box_mesh.position.y = h * 0.5
    box_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(box_mesh)
    var roof_h = min(3.2, h * 0.22)
    var roof_col = base_col.lerp(Color(0.82,0.34,0.28,1), 0.24) if randf()<0.34 else base_col.lerp(Color(0.44,0.46,0.50,1), 0.22)
    var roof = prism(Vector3(w + 0.4, roof_h, d + 0.4), roof_col)
    roof.position.y = h + roof_h*0.5
    roof.rotation.y = PI
    root.add_child(roof)
    var floors = int(h / 3.0)
    for f in range(1, floors):
        for wi in range(int(w/3.2)):
            if randf() < 0.42:
                var lit = randf() < 0.16
                var win_col = Color(0.10, 0.11, 0.16, 1).lerp(Color(0.48, 0.64, 0.96, 1), 1.0 if lit else 0.0)
                var win = box(Vector3(0.9, 1.1, 0.08), win_col)
                win.position = Vector3((wi - w/6.4)*0.78, f*3.0, d*0.5 + 0.06)
                root.add_child(win)
                var ledge = box(Vector3(1.05, 0.10, 0.18), Color(0.62, 0.60, 0.56, 1))
                ledge.position = Vector3((wi - w/6.4)*0.78, f*3.0 - 0.55, d*0.5 + 0.12)
                root.add_child(ledge)
    return root

static func create_cloud(pos: Vector3, scale_mult: float) -> Node3D:
    var c = Node3D.new()
    c.position = pos
    c.scale = Vector3.ONE * scale_mult
    for k in range(randi_range(4, 6)):
        var sm = SphereMesh.new()
        sm.radius = randf_range(0.82, 1.55)
        sm.height = sm.radius * 2.0
        sm.radial_segments = 5
        sm.rings = 3
        var mi = MeshInstance3D.new()
        mi.mesh = sm
        var m = StandardMaterial3D.new()
        m.albedo_color = Color(1,1,1,1)
        m.roughness = 1.0
        mi.material_override = m
        mi.position = Vector3(randf_range(-1.4,1.4), randf_range(-0.35,0.45), randf_range(-1.4,1.4)) * 0.9
        c.add_child(mi)
    return c

static func create_perch_branch(length: float) -> Node3D:
    var root = Node3D.new()
    var wood = box(Vector3(length, 0.20, 0.20), Color(0.33, 0.23, 0.14, 1))
    root.add_child(wood)
    var leaf_col = Color(0.23, 0.54, 0.19, 1).lerp(Color(0.46, 0.62, 0.16, 1), randf()*0.38)
    for s in [-length*0.44, length*0.44]:
        var cap = cylinder(0.85, 0.04, 0.78, 5, leaf_col)
        cap.position = Vector3(s, 0.22, 0)
        cap.rotation.z = PI/2.0
        root.add_child(cap)
    return root

static func create_hill(pos: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
    var sm = SphereMesh.new()
    sm.radius = radius
    sm.height = height
    sm.radial_segments = 7
    sm.rings = 4
    var mi = MeshInstance3D.new()
    mi.mesh = sm
    mi.material_override = mat(color, 0.92)
    mi.position = pos
    mi.scale = Vector3(1, 0.42, 1)
    mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return mi

static func create_bird_mesh(size: float, color: Color, out_wings: Array) -> Node3D:
    var bird = Node3D.new()
    var body = prism(Vector3(0.62*size, 0.42*size, 1.05*size), color)
    body.rotation.z = PI
    bird.add_child(body)
    var beak = prism(Vector3(0.20*size, 0.20*size, 0.52*size), Color(1.0, 0.79, 0.18, 1))
    beak.position.z = -0.78*size
    beak.position.y = 0.02*size
    bird.add_child(beak)
    var tail = prism(Vector3(0.38*size, 0.10*size, 0.62*size), color.lerp(Color.BLACK, 0.18))
    tail.position.z = 0.72*size
    bird.add_child(tail)
    var wing_l = prism(Vector3(0.92*size, 0.05*size, 0.58*size), color.lerp(Color.WHITE, 0.34))
    wing_l.position = Vector3(0.54*size, 0.02*size, 0.02*size)
    wing_l.rotation.y = deg_to_rad(10)
    bird.add_child(wing_l)
    var wing_r = prism(Vector3(0.92*size, 0.05*size, 0.58*size), color.lerp(Color.WHITE, 0.34))
    wing_r.position = Vector3(-0.54*size, 0.02*size, 0.02*size)
    wing_r.rotation.y = deg_to_rad(-10)
    wing_r.scale.x = -1
    bird.add_child(wing_r)
    out_wings.append(wing_l)
    out_wings.append(wing_r)
    return bird
