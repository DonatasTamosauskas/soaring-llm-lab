extends MeshInstance3D
## First-person wings for the flight lab's eye view and head mirror (the VR
## area's wings are its own; the lab draws simple ones). Each wing is built
## every frame on the pose frame PlayerBird used this tick (tracking space,
## scaled into the world by world_scale), low-poly and flat-shaded, so
## strokes, tilts and tucks show exactly as the rig's hand poses move:
## a slim leading edge, two rows of scalloped coverts, six overlapping
## secondaries along the arm's trailing edge and six slotted primaries
## fanned beyond the hand, in the species' colours. The inner third of the
## arm is left out: it lies under the chin, at the eye (round 3: a single
## brown panel from the shoulder filled 40 % of a pigeon's view).

# Palettes (leading edge, covert, covert 2, secondary, primary, tip). The
# lab's sky and ground light tint everything green, so browns lean red.
const PALETTES := {
	&"brown": [Color8(120, 70, 40), Color8(186, 118, 70), Color8(160, 96, 56), Color8(112, 70, 46), Color8(70, 44, 34), Color8(228, 212, 186)],
	&"grey": [Color8(92, 96, 110), Color8(168, 172, 182), Color8(146, 150, 162), Color8(70, 72, 82), Color8(46, 46, 52), Color8(120, 124, 134)],
	&"dark": [Color8(70, 46, 34), Color8(130, 92, 62), Color8(108, 74, 52), Color8(78, 54, 40), Color8(46, 34, 28), Color8(196, 178, 150)],
}

var player: PlayerBird
var _mesh := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()


func _ready() -> void:
	mesh = _mesh
	_mat.vertex_color_use_as_albedo = true
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.roughness = 0.95
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true


func _palette() -> Array:
	var sp := player.species
	if sp in [&"pigeon", &"gull", &"crow"]:
		return PALETTES[&"grey"]
	if sp in [&"hawk", &"eagle"]:
		return PALETTES[&"dark"]
	return PALETTES[&"brown"]


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	if player == null or player.origin == null or not visible:
		return
	var f := player.frame
	if not f.head_valid or not (f.left_valid or f.right_valid):
		return
	var o := player.origin.global_transform
	var ws := player.origin.world_scale
	var pal := _palette()
	var yaw := Basis(Vector3.UP, f.head.basis.get_euler().y)
	var fwd := yaw * Vector3.FORWARD
	var right := yaw * Vector3.RIGHT
	var neck := f.head.origin + f.head.basis * Vector3(0.0, -0.08, 0.09)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _mat)
	for i in 2:
		var ok := f.left_valid if i == 0 else f.right_valid
		if not ok:
			continue
		var side := -1.0 if i == 0 else 1.0
		var hand: Vector3 = (f.left if i == 0 else f.right).origin
		var shoulder := neck + right * (0.17 * side) + Vector3.DOWN * 0.16
		var arm := hand - shoulder
		var reach := arm.length()
		if reach < 0.05:
			continue
		var out := arm / reach
		# The wing's "back" direction: forward removed from the arm line.
		var back := -(fwd - out * fwd.dot(out)).normalized()
		var s := reach / 0.62      # feather lengths scale with the arm
		var root := shoulder + arm * 0.33
		var le0 := root - back * 0.05 * s
		var le2 := hand - back * 0.04 * s
		var te0 := root + back * 0.11 * s
		var te2 := hand + back * 0.07 * s
		# Leading edge: a slim darker strip (the bird's forearm).
		var lm0 := le0.lerp(te0, 0.28)
		var lm2 := le2.lerp(te2, 0.28)
		_tri(o, ws, le0, le2, lm2, pal[0])
		_tri(o, ws, le0, lm2, lm0, pal[0])
		# Coverts: two rows of scallops, alternating tones.
		for row in 2:
			var a0 := 0.28 + 0.36 * row
			var a1 := a0 + 0.36
			for k in 5:
				var u0 := float(k) / 5.0
				var u1 := float(k + 1) / 5.0
				var p0 := le0.lerp(te0, a0).lerp(le2.lerp(te2, a0), u0)
				var p1 := le0.lerp(te0, a0).lerp(le2.lerp(te2, a0), u1)
				var q := le0.lerp(te0, a1).lerp(le2.lerp(te2, a1), 0.5 * (u0 + u1))
				_tri(o, ws, p0, p1, q, pal[1] if (k + row) % 2 == 0 else pal[2])
				if k < 4:
					var q2 := le0.lerp(te0, a1).lerp(le2.lerp(te2, a1), u1 + 0.1)
					_tri(o, ws, p1, q2, q, pal[2] if (k + row) % 2 == 0 else pal[1])
		# Secondaries: six feathers hanging back from the arm, overlapping.
		for k in 6:
			var u := (float(k) + 0.5) / 6.0
			var base := te0.lerp(te2, u)
			var half := (te2 - te0) * (0.6 / 6.0)
			var tip := base + back * (0.13 - 0.02 * u) * s + out * 0.02 * s
			var mid_l := base - half * 0.9 + back * 0.08 * s
			var mid_r := base + half * 0.9 + back * 0.08 * s
			_tri(o, ws, base - half, base + half, mid_r, pal[3])
			_tri(o, ws, base - half, mid_r, mid_l, pal[3])
			_tri(o, ws, mid_l, mid_r, tip, pal[4])
		# Primaries: six long feathers fanned from the hand, slotted tips.
		for k in 6:
			var t := float(k) / 5.0
			var base := le2.lerp(te2, 0.15 + 0.8 * t)
			var dir := (out * (1.0 - 0.5 * t) + back * (0.1 + 0.62 * t)).normalized()
			var length := (0.32 - 0.06 * t) * s
			var wdt := 0.03 * s
			var side_v := dir.cross(back.cross(out)).normalized() * wdt
			if side_v.dot(back) < 0.0:
				side_v = -side_v
			var mid := base + dir * (0.72 * length)
			var end := base + dir * length
			_tri(o, ws, base - side_v, base + side_v, mid + side_v * 0.7, pal[4])
			_tri(o, ws, base - side_v, mid + side_v * 0.7, mid - side_v * 0.5, pal[4])
			_tri(o, ws, mid - side_v * 0.5, mid + side_v * 0.7, end, pal[5] if k % 2 == 0 else pal[4])
	_mesh.surface_end()


## One flat-shaded triangle in tracking space, transformed into the world;
## its normal faces up so both wings (and both faces) shade alike.
func _tri(o: Transform3D, ws: float, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var wa := o * (a * ws)
	var wb := o * (b * ws)
	var wc := o * (c * ws)
	var n := (wb - wa).cross(wc - wa)
	if n.length_squared() < 1e-14:
		return
	n = n.normalized()
	if n.y < 0.0:
		n = -n
		var tmp := wb
		wb = wc
		wc = tmp
	for v in [wa, wb, wc]:
		_mesh.surface_set_color(col)
		_mesh.surface_set_normal(n)
		_mesh.surface_add_vertex(v)
