extends Node3D
## A low-poly stand-in bird for the flight lab's chase view (the birds area
## owns the real models; the lab must not depend on its in-progress code).
## It shows what the flight model does: the body follows heading, pitch and
## bank; each wing follows its WingState dihedral, twist and extension, so
## strokes, tucks and one-wing flaps are visible from outside.

const C_BODY := Color8(118, 92, 70)
const C_WING := Color8(150, 122, 92)
const C_BELLY := Color8(214, 196, 160)
const C_BEAK := Color8(236, 170, 60)

var player: PlayerBird
var _wings: Array[Node3D] = []
## Legs, shown when perched or grounded: the body centre sits one collision
## radius (0.16 span) above the grip, the slim visual body does not reach it.
var _legs: Node3D
var _span := 0.24


func _ready() -> void:
	_build()


func _build() -> void:
	for c in get_children():
		c.queue_free()
	_wings.clear()
	var body := MeshInstance3D.new()
	body.mesh = _body_mesh()
	add_child(body)
	for side in [-1, 1]:
		var pivot := Node3D.new()
		pivot.position = Vector3(0.09 * side, 0.03, -0.02)
		add_child(pivot)
		var w := MeshInstance3D.new()
		w.mesh = _wing_mesh(side)
		pivot.add_child(w)
		_wings.append(pivot)
	_legs = Node3D.new()
	add_child(_legs)
	for side in [-1, 1]:
		var leg := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.012, 0.11, 0.012)
		leg.mesh = bm
		leg.material_override = _mat(C_BEAK)
		leg.position = Vector3(0.025 * side, -0.105, 0.0)
		_legs.add_child(leg)


func _process(_delta: float) -> void:
	if player == null or player.model == null:
		return
	var m := player.model
	# The meshes are built for a 1 m span; growth rescales them.
	_span = m.params.span
	# Body: heading, then pitch (nose up +), then bank (right wing down +).
	var b := Basis(Vector3.UP, m.heading()) * Basis(Vector3.RIGHT, m.theta) * Basis(Vector3.BACK, -m.phi)
	global_transform = Transform3D(b.scaled(Vector3.ONE * _span), m.position)
	var w := player.wing_state()
	var perched := player.mode == PlayerBird.Mode.PERCHED or player.mode == PlayerBird.Mode.GROUNDED
	_legs.visible = perched
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var ext := w.ext_l if i == 0 else w.ext_r
		var dih := w.dihedral_l if i == 0 else w.dihedral_r
		var tw := w.twist_l if i == 0 else w.twist_r
		if perched:
			# Folded along the back, tips a little down: a perched bird holds
			# its wings closed (round 3: the stroke's dihedral and twist left
			# them raised in a V).
			ext = 0.0
			dih = -0.12
			tw = 0.0
		# Dihedral raises the tip (about the forward axis), twist pitches the
		# wing about its own span axis, extension folds it back along the body
		# (rotating +X by -90 deg about UP points it at +Z, the tail; round 2's
		# sign folded both wings forward past the beak).
		var fold := lerpf(PI * 0.5, 0.0, clampf(ext, 0.0, 1.0))
		var basis := Basis(Vector3.BACK, side * clampf(dih, -1.2, 1.2)) \
			* Basis(Vector3.UP, -side * fold) \
			* Basis(Vector3.RIGHT, clampf(tw, -0.8, 0.8))
		_wings[i].basis = basis


func _mat(c: Color) -> StandardMaterial3D:
	return FlightGeometry.material(c)


## Body for a 1 m span bird: a faceted spindle with a beak and a tail fan.
func _body_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	# Spindle: 6 sides, rings at z (forward is -Z).
	var ring_z := [-0.20, -0.12, 0.02, 0.16, 0.26]
	var ring_r := [0.0, 0.055, 0.07, 0.05, 0.02]
	var sides := 6
	var pts: Array = []
	for k in ring_z.size():
		var ring: Array[Vector3] = []
		for s in sides:
			var a := TAU * s / sides + PI / sides
			ring.append(Vector3(cos(a) * float(ring_r[k]) * 1.2, sin(a) * float(ring_r[k]), float(ring_z[k])))
		pts.append(ring)
	for k in range(ring_z.size() - 1):
		for s in sides:
			var a0: Vector3 = pts[k][s]
			var a1: Vector3 = pts[k][(s + 1) % sides]
			var b0: Vector3 = pts[k + 1][s]
			var b1: Vector3 = pts[k + 1][(s + 1) % sides]
			st.set_color(C_BELLY if a0.y < 0.0 and a1.y < 0.0 else C_BODY)
			st.add_vertex(a0)
			st.add_vertex(b0)
			st.add_vertex(a1)
			st.add_vertex(a1)
			st.add_vertex(b0)
			st.add_vertex(b1)
	# Beak.
	st.set_color(C_BEAK)
	var tip := Vector3(0, 0.0, -0.27)
	var bb: Array[Vector3] = [Vector3(-0.012, 0.01, -0.2), Vector3(0.012, 0.01, -0.2), Vector3(0, -0.012, -0.2)]
	for i in 3:
		st.add_vertex(bb[i])
		st.add_vertex(tip)
		st.add_vertex(bb[(i + 1) % 3])
	# Tail fan (two-sided).
	st.set_color(C_WING)
	var t0 := Vector3(0, 0.01, 0.22)
	var tl := Vector3(-0.09, 0.0, 0.42)
	var tr := Vector3(0.09, 0.0, 0.42)
	# Single-sided with culling off: the material lights both faces.
	for v in [t0, tr, tl]:
		st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh


## One wing (side -1 left, +1 right) from its root at the pivot: a tapered,
## slightly swept planform, span 0.42 per wing (culling off: both faces lit).
func _wing_mesh(side: int) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	st.set_color(C_WING)
	var s := float(side)
	var root_le := Vector3(0, 0, -0.07)
	var root_te := Vector3(0, 0, 0.09)
	var mid_le := Vector3(0.22 * s, 0.0, -0.06)
	var mid_te := Vector3(0.22 * s, 0.0, 0.12)
	var tip := Vector3(0.42 * s, 0.0, 0.10)
	var quads := [[root_le, mid_le, mid_te, root_te]]
	for q in quads:
		for tri in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]:
			for v in tri:
				st.add_vertex(v)
	for v in [mid_le, tip, mid_te]:
		st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh
