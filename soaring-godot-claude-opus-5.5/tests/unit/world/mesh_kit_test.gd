extends TestCase
## The geometry kit everything is built from: outward normals (backface
## culling shows the right side), watertight walls with real holes, arches,
## capsules along their segment, and a terrain height that is exactly the
## drawn triangle.


func _outward_ratio(kit: MeshKit, centre: Vector3) -> float:
	var ok := 0
	for i in range(0, kit.verts.size(), 3):
		var c := (kit.verts[i] + kit.verts[i + 1] + kit.verts[i + 2]) / 3.0
		if kit.norms[i].dot(c - centre) > 0.0:
			ok += 1
	return float(ok) / (kit.verts.size() / 3)


func test_box_faces_point_outward_and_match_winding() -> void:
	var k := MeshKit.new("t")
	k.box(Transform3D(Basis(Vector3.UP, 0.4), Vector3(1, 2, 3)), Vector3(2, 1, 3), Color.WHITE)
	eq(k.tri_count(), 12, "12 triangles")
	near(_outward_ratio(k, Vector3(1, 2, 3)), 1.0, 1e-6, "all normals point out")
	# Godot front faces are clockwise: (v1 - v0) x (v2 - v0) points IN.
	var bad := 0
	for i in range(0, k.verts.size(), 3):
		var n := (k.verts[i + 1] - k.verts[i]).cross(k.verts[i + 2] - k.verts[i])
		if n.dot(k.norms[i]) > 0.0:
			bad += 1
	eq(bad, 0, "stored winding is clockwise seen from outside")
	eq(k.faces.size(), k.verts.size(), "every drawn triangle collides")


## Divergence theorem over the stored triangles: the enclosed volume of a
## closed mesh, positive when wound outward. Godot stores each triangle
## clockwise from outside (A, C, B), so (v0, v2, v1) is counter-clockwise.
static func signed_volume(tris: PackedVector3Array) -> float:
	var vol := 0.0
	var o := tris[0] if tris.size() > 0 else Vector3.ZERO
	for i in range(0, tris.size(), 3):
		vol += (tris[i] - o).dot((tris[i + 2] - o).cross(tris[i + 1] - o)) / 6.0
	return vol


func test_mirrored_frames_stay_outward() -> void:
	# Round 3: the cliff shelves were boxes in a left-handed frame (x = (-N.z,
	# 0, N.x), z = N), so every face was wound inward: see-through from
	# outside, a trap from inside, drawn and collided. Any frame, mirrored
	# or not, must give an outward solid of the right volume.
	var mirror := Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(1, 0, 0))
	check(mirror.determinant() < 0.0, "the test frame is mirrored")
	var flip_x := Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), Vector3(5, 0, 0))
	var cases := []
	var kb := MeshKit.new("box")
	kb.box(Transform3D(mirror, Vector3(3, 1, 2)), Vector3(3.4, 0.6, 2.2), Color.WHITE)
	cases.append(["mirrored box", kb, Vector3(3, 1, 2), 3.4 * 0.6 * 2.2])
	var kp := MeshKit.new("prism")
	var tp := Transform3D(mirror, Vector3(-2, 0, 0))
	kp.prism(tp, PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]), 2.0, Color.WHITE)
	cases.append(["mirrored prism", kp, tp * Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0), 1.0])
	var kw := MeshKit.new("wall")
	kw.wall(Transform3D(mirror, Vector3.ZERO), 2.0, 1.0, 0.2, [], Color.WHITE, Color.GRAY, Color.DIM_GRAY)
	cases.append(["mirrored wall", kw, mirror * Vector3(1.0, 0.5, 0.0), 0.4])
	var kx := MeshKit.new("xf")
	kx.xf = flip_x
	kx.box(Transform3D.IDENTITY, Vector3(1, 2, 3), Color.WHITE)
	cases.append(["box under a mirrored xf", kx, flip_x.origin, 6.0])
	var kxx := MeshKit.new("xf2")
	kxx.xf = flip_x
	kxx.box(Transform3D(mirror, Vector3.ZERO), Vector3(1, 2, 3), Color.WHITE)
	cases.append(["mirrored box under a mirrored xf", kxx, flip_x.origin, 6.0])
	for c in cases:
		var k: MeshKit = c[1]
		near(signed_volume(k.verts), float(c[3]), 1e-3, "%s: drawn solid is wound outward" % c[0])
		near(signed_volume(k.faces), float(c[3]), 1e-3, "%s: collided solid is wound outward" % c[0])
		near(_outward_ratio(k, c[2]), 1.0, 1e-6, "%s: every normal points out" % c[0])
	# The correction ends with the primitive: an ordinary box built after a
	# mirrored one is untouched.
	var ka := MeshKit.new("after")
	ka.box(Transform3D(mirror, Vector3(10, 0, 0)), Vector3.ONE, Color.WHITE)
	var n0 := ka.verts.size()
	ka.box(Transform3D(Basis.IDENTITY, Vector3(-10, 0, 0)), Vector3.ONE, Color.WHITE)
	near(signed_volume(ka.verts.slice(n0)), 1.0, 1e-4, "the next, unmirrored box is still outward")
	# And the detector would have caught round 3's shelf: the same box with
	# its winding reversed has a negative volume.
	var rev := PackedVector3Array()
	for i in range(0, kb.verts.size(), 3):
		rev.append_array([kb.verts[i], kb.verts[i + 2], kb.verts[i + 1]])
	lt(signed_volume(rev), -1.0, "an inside-out box has a negative volume")


func test_blob_and_cylinder_outward() -> void:
	var k := MeshKit.new("t")
	k.blob(Vector3(5, 0, 0), Vector3(1, 0.7, 1.2), Color.GREEN)
	near(_outward_ratio(k, Vector3(5, 0, 0)), 1.0, 1e-6, "blob normals point out")
	var c := MeshKit.new("c")
	c.cyl(Vector3(0, 0, 0), Vector3(0, 4, 0), 1.0, 0.5, 7, Color.BROWN)
	near(_outward_ratio(c, Vector3(0, 2, 0)), 1.0, 1e-6, "cylinder normals point out")
	check(k.last_blob.size() == 12, "blob exposes its vertices for hulls")


func test_wall_hole_is_open_and_frame_is_closed() -> void:
	var k := MeshKit.new("w")
	var holes := [{"rect": Rect2(1.0, 1.0, 1.0, 1.2)}, {"rect": Rect2(3.0, 0.5, 1.0, 2.0), "arch": true, "segs": 6}]
	k.wall(Transform3D.IDENTITY, 5.0, 3.0, 0.3, holes, Color.WHITE, Color.GRAY, Color.DIM_GRAY)
	# No drawn face covers the rectangular hole (reveals lie in its sides).
	var covered := false
	for i in range(0, k.verts.size(), 3):
		var tri := [k.verts[i], k.verts[i + 1], k.verts[i + 2]]
		var p := Vector2(1.5, 1.6)
		if _in_tri_xy(p, tri) and absf(tri[0].z) > 0.1:
			covered = true
	check(not covered, "nothing drawn across the rectangular hole's face")
	gt(float(k.tri_count()), 30.0, "wall has front, back and reveal faces")
	# The arch's intrados exists: some faces inside the arch point down.
	var down := 0
	for i in range(0, k.verts.size(), 3):
		var c := (k.verts[i] + k.verts[i + 1] + k.verts[i + 2]) / 3.0
		if c.x > 3.0 and c.x < 4.0 and c.y > 2.0 and k.norms[i].y < -0.3:
			down += 1
	gt(float(down), 5.0, "arch underside faces down into the opening")


func _in_tri_xy(p: Vector2, t: Array) -> bool:
	var a := Vector2(t[0].x, t[0].y)
	var b := Vector2(t[1].x, t[1].y)
	var c := Vector2(t[2].x, t[2].y)
	var d1 := (p - b).cross(a - b)
	var d2 := (p - c).cross(b - c)
	var d3 := (p - a).cross(c - a)
	var neg := d1 < 0 or d2 < 0 or d3 < 0
	var pos := d1 > 0 or d2 > 0 or d3 > 0
	return not (neg and pos)


func test_capsule_runs_along_its_segment() -> void:
	var k := MeshKit.new("r")
	var a := Vector3(1, 2, 3)
	var b := Vector3(4, 6, 3)
	k.add_capsule(a, b, 0.1)
	var sh: Array = k.shapes[0]
	var xf: Transform3D = sh[1]
	var cap: CapsuleShape3D = sh[0]
	vnear(xf.origin, (a + b) * 0.5, 1e-5, "capsule centred on the segment")
	near(absf(xf.basis.y.normalized().dot((b - a).normalized())), 1.0, 1e-5, "capsule axis along the segment")
	near(cap.height, (b - a).length() + 0.2, 1e-5, "capsule spans the segment")
	near(xf.basis.determinant(), 1.0, 1e-4, "right-handed, unscaled")


func test_terrain_height_is_the_drawn_triangle() -> void:
	var t := WorldTerrain.new(3)
	t.generate()
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var worst := 0.0
	for i in 400:
		var x := rng.randf_range(-700, 700)
		var z := rng.randf_range(-700, 700)
		var h := t.height_at(x, z)
		# Recompute from the jittered lattice directly (brute-force search).
		var n1 := t.n + 1
		var gi := int((x + WorldTerrain.HALF) / WorldTerrain.CELL)
		var gj := int((z + WorldTerrain.HALF) / WorldTerrain.CELL)
		var best := NAN
		for j in range(maxi(gj - 1, 0), mini(gj + 2, t.n)):
			for ii in range(maxi(gi - 1, 0), mini(gi + 2, t.n)):
				var k0 := j * n1 + ii
				for tri in [[k0, k0 + n1 + 1, k0 + 1], [k0, k0 + n1, k0 + n1 + 1]]:
					var p := [Vector3(t.vx[tri[0]], t.heights[tri[0]], t.vz[tri[0]]), Vector3(t.vx[tri[1]], t.heights[tri[1]], t.vz[tri[1]]), Vector3(t.vx[tri[2]], t.heights[tri[2]], t.vz[tri[2]])]
					var pl := Plane(p[0], p[1], p[2])
					if _in_tri_xz(Vector2(x, z), p):
						best = (-pl.d * -1.0 - pl.normal.x * x - pl.normal.z * z) / pl.normal.y
		if not is_nan(best):
			worst = maxf(worst, absf(best - h))
	lt(worst, 1e-3, "height_at equals the jittered triangle's plane")


func _in_tri_xz(p: Vector2, t: Array) -> bool:
	return _in_tri_xy(p, [Vector3(t[0].x, t[0].z, 0), Vector3(t[1].x, t[1].z, 0), Vector3(t[2].x, t[2].z, 0)])
