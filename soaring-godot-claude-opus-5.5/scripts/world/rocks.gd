class_name RockBuilder
extends RefCounted
## Rock: the west escarpment (a stratified cliff facing the breeze, with a
## sandstone band full of swallow holes and ledges for big birds), the canyon
## the river cuts north into the mountains (with a natural arch spanning it),
## a sea-stack style arch in the lake, a roofless ruined tower, and boulders.

const STATION := 5.0


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("rocks")
	_cliff(ctx, rng)
	_canyon(ctx, rng)
	_lake_arch(ctx, rng)
	_ruin(ctx, rng)


# --- rock masses -------------------------------------------------------

## Resamples a polyline every `step` metres: [points, tangents, arc lengths].
static func _resample(pts: Array, step: float) -> Array:
	var total := 0.0
	for i in pts.size() - 1:
		total += (pts[i] as Vector2).distance_to(pts[i + 1])
	var n := maxi(2, int(ceil(total / step)) + 1)
	var P: Array[Vector2] = []
	var T: Array[Vector2] = []
	var S: PackedFloat32Array = []
	var typed: Array[Vector2] = []
	for p in pts:
		typed.append(p)
	for k in n:
		var s := total * float(k) / float(n - 1)
		var at := WorldLayout.polyline_at(typed, s)
		P.append(at[0])
		T.append(at[1])
		S.append(s)
	# Smooth tangents at corners so the offset surface does not fold.
	for k in range(1, n - 1):
		T[k] = (P[k + 1] - P[k - 1]).normalized()
	return [P, T, S, total]


static func _interp(values: Array, pts: Array, s: float) -> float:
	var acc := 0.0
	for i in pts.size() - 1:
		var l := (pts[i] as Vector2).distance_to(pts[i + 1])
		if s <= acc + l or i == pts.size() - 2:
			return lerpf(values[i], values[i + 1], clampf((s - acc) / l, 0.0, 1.0))
		acc += l
	return values[-1]


## A jagged rock mass whose FACE runs along `pts` and looks to the right of
## travel (face_right) or the left. tops: face-top height above the ground
## in front of the face, per polyline vertex. Returns the station grid for
## decorations: {"P", "T", "N", "rows": Array[PackedVector3Array] (per
## station, profile points in world space), "face_rows": int, "H", "S"}.
##
## layer (the west cliff): a softer sandstone stratum runs along the whole
## face, weathered back between two harder lips (a ledge below, a cap
## above), and the swallow colony is dug into it. {"k0", "k1": the stations
## where the colony's face is exposed, "y0", "h": its bottom and height}.
## It adds six face rows per station (see ROW_*); at the colony stations the
## stratum face (rows ROW_B2..ROW_C1) lies on the colony plane, and those
## quads are left to the colony builder, which cuts the burrows into them.
## The rows never step out over the row below except at the cap over the
## colony (which stays behind the ledge's front), so there is no overhang
## over open air for ground_height to miss.
const ROW_A := 4
const ROW_B1 := 5
const ROW_B2 := 6
const ROW_C1 := 7
const ROW_C2 := 8
const ROW_D := 9


static func rock_mass(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, pts: Array, tops: Array, face_right: bool,
		name: String, top_depth := WorldLayout.ROCK_TOP_DEPTH, back_slope := WorldLayout.ROCK_BACK_SLOPE, jag := 1.1,
		layer := {}) -> Dictionary:
	var rs := _resample(pts, STATION)
	var P: Array[Vector2] = rs[0]
	var T: Array[Vector2] = rs[1]
	var S: PackedFloat32Array = rs[2]
	var n := P.size()
	var has_layer := not layer.is_empty()
	var face_rows := 14 if has_layer else 9
	var rows: Array[PackedVector3Array] = []
	var Ns: Array[Vector2] = []
	var Hs := PackedFloat32Array()
	var ph1 := rng.randf() * TAU
	var ph2 := rng.randf() * TAU
	var ph3 := rng.randf() * TAU
	for k in n:
		Ns.append(Vector2(-T[k].y, T[k].x) if face_right else Vector2(T[k].y, -T[k].x))
	var bulge_at := func(k: int) -> float:
		var end_taper := clampf(minf(S[k], float(rs[3]) - S[k]) / 12.0, 0.0, 1.0)
		return (1.8 * sin(S[k] * 0.09 + ph1) + 0.9 * sin(S[k] * 0.23 + ph2)) * end_taper
	# The colony plane: through the colony stations' chord, at the face's
	# natural depth at mid-band (+0.35 m so the stratum is not buried), with a
	# gentle fold at every station (a faceted face, planar between stations).
	var k0 := -1
	var k1 := -1
	var y0 := 0.0
	var y1 := 0.0
	var ta := Vector2.ZERO
	var na := Vector2.ZERO
	var front := 0.0
	var d_plane := {}
	var u_at := {}
	if has_layer:
		k0 = layer["k0"]
		k1 = layer["k1"]
		y0 = layer["y0"]
		y1 = y0 + float(layer["h"])
		ta = (P[k1] - P[k0]).normalized()
		na = Vector2(-ta.y, ta.x) if face_right else Vector2(ta.y, -ta.x)
		var acc := 0.0
		for k in range(k0, k1 + 1):
			var g := ctx.ground(P[k].x + Ns[k].x * 2.0, P[k].y + Ns[k].y * 2.0)
			acc += float(bulge_at.call(k)) - 0.07 * ((y0 + y1) * 0.5 - g)
		front = acc / float(k1 - k0 + 1) + 0.35
		for k in range(k0, k1 + 1):
			var off := front + rng.randf_range(-0.12, 0.12)
			var d := (off - (P[k] - P[k0]).dot(na)) / Ns[k].dot(na)
			d_plane[k] = d
			u_at[k] = (P[k] + Ns[k] * d - P[k0]).dot(ta)
	var vb := {}
	var vt := {}
	for k in n:
		var t := T[k]
		var nrm := Ns[k]
		var p := P[k]
		# Ground in front of the face; tops are heights above it.
		var gf := ctx.ground(p.x + nrm.x * 2.0, p.y + nrm.y * 2.0)
		var H: float = gf + _interp(tops, pts, S[k])
		Hs.append(H)
		var base := gf - 3.0
		var prof := PackedVector3Array()
		var end_taper := clampf(minf(S[k], rs[3] - S[k]) / 12.0, 0.0, 1.0)
		# Buttresses and gullies: slow undulation of the whole face.
		var bulge: float = bulge_at.call(k)
		# The face leans back a little as it rises; jitter makes it crag.
		var natural := func(y: float) -> float:
			return bulge - 0.07 * (y - gf) + (rng.randf() - 0.5) * 2.0 * jag * end_taper
		# Row heights: base, the rows below the stratum, its six rows, the
		# rows above it, the face top.
		var ys := PackedFloat32Array()
		if not has_layer:
			for j in face_rows:
				var f := float(j) / float(face_rows - 1)
				if j > 0 and j < face_rows - 1:
					f += (rng.randf() - 0.5) * 0.6 / float(face_rows - 1)
				ys.append(lerpf(base, H, f))
		else:
			var colony := k >= k0 and k <= k1
			var yb := y0
			var th := y1 - y0
			if not colony:
				# Away from the colony the stratum rides at the face's mid-height
				# and thins; near it, it blends into the colony's band.
				var dist := float(k0 - k) if k < k0 else float(k - k1)
				var w := exp(-dist / 2.5)
				var tall := H - gf
				var th_nat := clampf(tall * 0.08, 0.5, 3.2) * (0.85 + 0.3 * sin(S[k] * 0.05 + ph3))
				yb = lerpf(gf + tall * 0.46, y0, w)
				th = lerpf(th_nat, y1 - y0, w)
				# Keep room for the rows below and above (low ends of the cliff).
				th = minf(th, maxf(tall * 0.25, 0.3))
				yb = clampf(yb, gf + tall * 0.2, H - th - maxf(tall * 0.2, 0.4))
			var lip := rng.randf_range(0.35, 0.65) if colony else rng.randf_range(0.2, 0.5) * clampf((H - gf) / 20.0, 0.2, 1.0)
			var o_b := rng.randf_range(0.12, 0.42) if colony else 0.0
			var o_t := rng.randf_range(0.3, 0.9) if colony else 0.0
			var cap := rng.randf_range(0.35, 0.7) if colony else rng.randf_range(0.2, 0.45) * clampf((H - gf) / 20.0, 0.2, 1.0)
			var yA := yb - lip
			var yB := yb + o_b
			var yC := yb + th - o_t
			var yD := yb + th + cap
			ys.append(base)
			for i in 3:
				ys.append(lerpf(base, yA, float(i + 1) / 4.0) + (rng.randf() - 0.5) * 0.4 * (yA - base) / 4.0)
			ys.append_array(PackedFloat32Array([yA, yB, yB, yC, yC if colony else yC + 0.25 * (cap / 0.45), yD]))
			for i in 3:
				ys.append(lerpf(yD, H, float(i + 1) / 4.0) + (rng.randf() - 0.5) * 0.4 * (H - yD) / 4.0)
			ys.append(H)
			vb[k] = yB - y0
			vt[k] = yC - y0
		var prev_d := INF
		for j in face_rows:
			var y := ys[j]
			var d: float = natural.call(y)
			if j == 0:
				d = bulge + 0.4
			var along := (rng.randf() - 0.5) * 2.4 * end_taper if j > 0 and j < face_rows - 1 else 0.0
			if has_layer and j >= ROW_A and j <= ROW_D:
				along = 0.0
				var colony := k >= k0 and k <= k1
				if colony:
					var dp: float = d_plane[k]
					var ledge := 0.45 + 0.2 * absf(sin(S[k] * 0.7 + ph3))
					match j:
						ROW_A, ROW_B1:
							d = dp + ledge
						ROW_B2, ROW_C1:
							d = dp
						ROW_C2:
							# The cap juts out over the band but less than the ledge:
							# the air under it is above the ledge, not open air.
							d = dp + ledge - 0.1 - 0.15 * absf(sin(S[k] * 0.9 + ph1))
						ROW_D:
							d = prev_d - 0.06
				else:
					match j:
						ROW_B1:
							d = prev_d
						ROW_B2:
							d = prev_d - rng.randf_range(0.25, 0.6) * clampf((H - gf) / 20.0, 0.2, 1.0)
						ROW_C1:
							d = prev_d - 0.07 * (ys[ROW_C1] - ys[ROW_B2])
						ROW_C2:
							d = prev_d - 0.02
			elif has_layer and j < ROW_A and k >= k0 and k <= k1:
				# Below the colony the face stands at least as far out as the
				# ledge, so the ledge never overhangs the rock under it.
				d = maxf(d, float(d_plane[k]) + 0.45 + 0.2 * absf(sin(S[k] * 0.7 + ph3)))
			# Crags step back as they rise, never out over the row below: an
			# overhang would put rock above flyable air, which a single
			# ground height cannot describe. The one exception is the cap over
			# the colony (C2), which stays behind the ledge's front.
			var exempt := has_layer and j == ROW_C2 and k >= k0 and k <= k1
			if not exempt:
				d = minf(d, prev_d)
			prev_d = d
			prof.append(Vector3(d, y, along))
		var lean := bulge - 0.07 * (H - gf)
		prof.append(Vector3(lean - 3.0 - rng.randf() * 2.0, H + rng.randf_range(0.2, 1.4) * end_taper, 0.0))
		prof.append(Vector3(lean - top_depth * 0.55, H + rng.randf_range(-0.6, 1.2) * end_taper, 0.0))
		prof.append(Vector3(lean - top_depth, H - 1.0, 0.0))
		var back_h := H - gf
		var run := back_h / back_slope
		prof.append(Vector3(lean - top_depth - run * 0.35, H - back_h * 0.35 + rng.randf_range(-1.0, 1.0) * end_taper, 0.0))
		prof.append(Vector3(lean - top_depth - run * 0.7, H - back_h * 0.7 + rng.randf_range(-1.0, 1.0) * end_taper, 0.0))
		prof.append(Vector3(lean - top_depth - run - 2.0, gf - 3.0, 0.0))
		var world := PackedVector3Array()
		for q in prof:
			world.append(Vector3(p.x + nrm.x * q.x + t.x * q.z, q.y, p.y + nrm.y * q.x + t.y * q.z))
		rows.append(world)
	# Strata: one band per face row. The rows run along the face at jittered
	# heights, so the bands undulate like real bedding instead of making a
	# patchwork; tones stay within a narrow warm-grey/tan range (no
	# near-black facets next to light ones). The sandstone stratum has its
	# own tones: lit ledge, shaded cap underside, harder lips in rock_light.
	var strata := [&"rock_light", &"sandstone", &"rock", &"sandstone_light", &"rock_light", &"sandstone_dark", &"rock", &"sandstone"]
	var soff := rng.randi() % strata.size()
	# The lips are simply the tops and bottoms of the beds either side (their
	# colours, the ledge a touch lighter, the cap's underside in shade), so
	# the stratum reads as one more bed of the cliff, not a framed panel.
	var below_c := Palette.c(strata[(ROW_A - 1 + soff) % strata.size()])
	var above_c := Palette.c(strata[(ROW_D + soff) % strata.size()])
	var layer_cols := {ROW_A: below_c, ROW_B1: Palette.vary(below_c, -0.04), ROW_B2: Palette.c(&"sand_bed"),
		ROW_C1: Palette.vary(above_c, -0.14), ROW_C2: above_c}
	var saved_jitter := kit.jitter
	kit.jitter = 0.025
	var m := rows[0].size()
	for k in n - 1:
		for j in m - 1:
			if has_layer and j == ROW_B2 and k >= k0 - 1 and k <= k1:
				continue
			var A := rows[k][j]
			var B := rows[k + 1][j]
			var C := rows[k + 1][j + 1]
			var D := rows[k][j + 1]
			var col: Color
			if has_layer and layer_cols.has(j):
				col = layer_cols[j]
			elif j < face_rows - 1:
				col = Palette.c(strata[(j + soff) % strata.size()])
			elif j < face_rows + 2:
				col = Palette.c(&"mountain_grass")
			else:
				col = Palette.c(&"scree") if j == m - 2 else Palette.c(&"mountain_grass")
			if face_right:
				kit.tri(A, B, C, col)
				kit.tri(A, C, D, col)
			else:
				kit.tri(A, C, B, col)
				kit.tri(A, D, C, col)
	# End caps (fans from the section centroid).
	for e in [0, n - 1]:
		var ring := rows[e]
		var cen := Vector3.ZERO
		for q in ring:
			cen += q
		cen /= ring.size()
		var outward := T[e] * (-1.0 if e == 0 else 1.0)
		for j in m:
			var a := ring[j]
			var b := ring[(j + 1) % m]
			# Orient each fan triangle to face along the polyline outward.
			var nn := (b - a).cross(cen - a)
			if Vector2(nn.x, nn.z).dot(outward) >= 0.0:
				kit.tri(a, b, cen, Palette.c(&"rock"))
			else:
				kit.tri(a, cen, b, Palette.c(&"rock"))
	kit.jitter = saved_jitter
	# Footprints: the face foot sits a few metres into the valley floor; the
	# back foot may run deep under the mountains (only floating matters).
	for k in range(0, n, 3):
		ctx.add_footprint(name + "_face", PackedVector2Array([Vector2(rows[k][0].x, rows[k][0].z)]), rows[k][0].y, 6.0, 2.5, -1.0, kit.name)
		ctx.add_footprint(name + "_back", PackedVector2Array([Vector2(rows[k][m - 1].x, rows[k][m - 1].z)]), rows[k][m - 1].y, 1000.0, -1.0, -1.0, kit.name)
		var mid := (rows[k][0] + rows[k][m - 1]) * 0.5
		ctx.block_circle(mid.x, mid.z, rows[k][0].distance_to(rows[k][m - 1]) * 0.5 + 2.5)
		ctx.add_feature(P[k].x, P[k].y, 10.0, "rock")
	return {"P": P, "T": T, "N": Ns, "rows": rows, "face_rows": face_rows, "H": Hs, "S": S,
		"ta": ta, "na": na, "u": u_at, "vb": vb, "vt": vt}


## Sweeps an irregular cross-section along a path (natural arches).
## widths: section half-width (along `side`) per path point, thick: half
## thickness (in the path's normal plane) per point.
static func sweep(kit: MeshKit, rng: RandomNumberGenerator, path: PackedVector3Array, side: Vector3, widths: PackedFloat32Array,
		thicks: PackedFloat32Array, col: Color, col2: Color) -> void:
	var sides := 7
	var rings: Array[PackedVector3Array] = []
	var n := path.size()
	for k in n:
		var tan := (path[mini(k + 1, n - 1)] - path[maxi(k - 1, 0)]).normalized()
		var sd := (side - tan * side.dot(tan)).normalized()
		var up := tan.cross(sd).normalized()
		var ring := PackedVector3Array()
		for i in sides:
			var a := TAU * float(i) / sides
			var jr := 1.0 + (rng.randf() - 0.5) * 0.4
			ring.append(path[k] + sd * cos(a) * widths[k] * jr + up * sin(a) * thicks[k] * jr)
		rings.append(ring)
	for k in n - 1:
		for i in sides:
			var j := (i + 1) % sides
			var A := rings[k][i]
			var B := rings[k][j]
			var C := rings[k + 1][j]
			var D := rings[k + 1][i]
			var c := col if int(floor((A.y + C.y) * 0.5 / 3.5)) % 2 == 0 else col2
			# Winding: outward normal = away from the path.
			var nrm := (B - A).cross(D - A)
			var mid := (A + C) * 0.5
			var pc := (path[k] + path[k + 1]) * 0.5
			if nrm.dot(mid - pc) >= 0.0:
				kit.quad(A, B, C, D, c)
			else:
				kit.quad(A, D, C, B, c)
	for e in [0, n - 1]:
		var ring := rings[e]
		var cen := path[e]
		var tan := (path[mini(e + 1, n - 1)] - path[maxi(e - 1, 0)]).normalized() * (-1.0 if e == 0 else 1.0)
		for i in sides:
			var a := ring[i]
			var b := ring[(i + 1) % sides]
			if (b - a).cross(cen - a).dot(tan) >= 0.0:
				kit.tri(a, b, cen, col2)
			else:
				kit.tri(a, cen, b, col2)


# --- west cliff --------------------------------------------------------

static func _cliff(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("cliff")
	var pts := Array(WorldLayout.CLIFF).duplicate()
	var tops := Array(WorldLayout.CLIFF_TOP).duplicate()
	# Let the escarpment dwindle into the ground at both ends.
	pts.push_front(pts[0] + (pts[0] - pts[1]).normalized() * 30.0)
	tops.push_front(1.5)
	pts.push_back(pts[-1] + (pts[-1] - pts[-2]).normalized() * 30.0)
	tops.push_back(1.5)
	# The colony sits on a straight stretch, half-way up the face, in the
	# sandstone stratum that runs along the whole escarpment.
	var pre := _resample(pts, STATION)
	var PP: Array[Vector2] = pre[0]
	var k0 := int(PP.size() * 0.42)
	var k1 := k0 + 6
	var a := PP[k0]
	var t := (PP[k1] - a).normalized()
	var nrm := Vector2(-t.y, t.x)
	var g0 := ctx.ground(a.x + nrm.x * 2.0, a.y + nrm.y * 2.0)
	var top0 := g0 + _interp(tops, pts, pre[2][k0])
	var band_h := 5.2
	var band_y0 := g0 + (top0 - g0) * 0.5
	var info := rock_mass(ctx, kit, rng, pts, tops, true, "cliff", WorldLayout.ROCK_TOP_DEPTH, WorldLayout.ROCK_BACK_SLOPE, 1.1,
		{"k0": k0, "k1": k1, "y0": band_y0, "h": band_h})
	var P: Array[Vector2] = info["P"]
	var N: Array[Vector2] = info["N"]
	var rows: Array = info["rows"]
	var H: PackedFloat32Array = info["H"]
	var fr: int = info["face_rows"]
	# Cliff-top perches along the rim, every few stations.
	for k in range(2, P.size() - 2, 3):
		var top: Vector3 = rows[k][fr]
		ctx.add_perch(top + Vector3(N[k].x, 0, N[k].y) * 0.8, Vector3(N[k].x, 0, N[k].y), Perch.Kind.ROCK, 2.1, &"cliff")
	_colony(ctx, kit, rng, info, k0, k1, band_y0, band_h)
	_shelves(ctx, rng, info, k0, k1)
	ctx.add_landmark("west_cliff", "cliff", Vector3(P[P.size() / 2].x, H[H.size() / 2] * 0.6, P[P.size() / 2].y), 160.0)


## Grassy rock shelves up the face for big birds (eagle perches), every
## fifth station away from the colony. Each is a wedge jutting from the face:
## a flat top, a lip, an underside sloping back into the rock. The face is
## jagged, so its depth across the shelf's width and height is measured on
## the face's own triangles (rays at 15 points), and the wedge's back is sunk
## 0.5 m behind the most recessed of them: attached along its whole width,
## never standing off the face. The shelves go into the boulders kit, not
## the cliff's: they overhang the air in front of the face, like the
## bridge, so they are something to perch on, not part of the rock ground
## (ground_height) whose columns must be solid from the floor up; and the
## boulders are drawn in nearly every view anyway, so the shelves cost no
## draw call of their own.
##
## (Round 3 built them as boxes in a left-handed frame: inside-out, drawn
## and collided, see-through from outside and a trap from within. MeshKit now
## corrects mirrored frames; this frame is right-handed anyway.)
static func _shelves(ctx: WorldBuild, rng: RandomNumberGenerator, info: Dictionary, k0: int, k1: int) -> void:
	var kit := ctx.kit("boulders")
	var saved_jitter := kit.jitter
	kit.jitter = 0.03
	var P: Array[Vector2] = info["P"]
	var N: Array[Vector2] = info["N"]
	var rows: Array = info["rows"]
	var H: PackedFloat32Array = info["H"]
	var fr: int = info["face_rows"]
	var width := 3.4
	for k in range(4, P.size() - 4, 5):
		if k >= k0 - 1 and k <= k1 + 1:
			continue
		var gf: float = (rows[k][0] as Vector3).y + 3.0
		var hy: float = clampf(H[k] * rng.randf_range(0.35, 0.8), gf + 4.0, H[k] - 2.5)
		if hy < gf + 4.0:
			continue
		var n3 := Vector3(N[k].x, 0.0, N[k].y)
		var lat := n3.cross(Vector3.UP)
		var root := Vector3(P[k].x, 0.0, P[k].y)
		var d_min := INF
		var d_max := -INF
		for u: float in [-1.7, -0.85, 0.0, 0.85, 1.7]:
			for dy: float in [-1.5, -0.75, 0.0]:
				var d := _face_depth(rows, fr, k, root + lat * u + Vector3.UP * (hy + dy), n3)
				if is_nan(d):
					continue
				d_min = minf(d_min, d)
				d_max = maxf(d_max, d)
		if d_min == INF:
			continue
		var db := d_min - 0.5
		var df := d_max + 1.5
		# Lofted between two end profiles (out along N, height; counter-
		# clockwise seen from +lat), each with its own lip, reach and
		# underside, so the shelf is a broken slab of rock, not a machined
		# wedge (own RNG: the rest of the rock keeps its sequence).
		var jr := RandomNumberGenerator.new()
		jr.seed = hash("shelf_%d" % k) ^ ctx.seed
		var profs: Array[PackedVector2Array] = []
		for e in 2:
			var f := df - jr.randf_range(0.0, 0.45)
			var ty := hy + jr.randf_range(-0.06, 0.06)
			profs.append(PackedVector2Array([Vector2(db, ty - jr.randf_range(1.3, 1.8)), Vector2(f - jr.randf_range(0.3, 0.6), ty - jr.randf_range(0.5, 0.75)),
				Vector2(f, ty - jr.randf_range(0.18, 0.3)), Vector2(f - jr.randf_range(0.1, 0.2), ty), Vector2(db, ty)]))
		var t := Transform3D(Basis(n3, Vector3.UP, lat), root - lat * width * 0.5)
		var rock := Palette.c(&"rock_light")
		_loft(kit, t, profs[0], profs[1], width, rock, [Palette.c(&"rock"), Palette.c(&"rock"), rock, Palette.c(&"mountain_grass"), rock])
		# Perch 0.7 m in from the nearer lip: room for an eagle, clear of the
		# face (validation snaps it onto the top).
		ctx.add_perch(t * Vector3(minf(profs[0][2].x, profs[1][2].x) - 0.7, hy, width * 0.5), n3, Perch.Kind.LEDGE, 2.1, &"cliff")
		ctx.set_meta(&"cliff_shelves", int(ctx.get_meta(&"cliff_shelves", 0)) + 1)
	kit.jitter = saved_jitter


## A solid lofted between two convex profiles in t's XY plane (both
## counter-clockwise seen from +Z, same point count): pa at z = 0, pb at
## z = depth. edge_cols colours the side of each edge i -> i + 1. t must be
## right-handed (MeshKit corrects a mirrored one anyway).
static func _loft(kit: MeshKit, t: Transform3D, pa: PackedVector2Array, pb: PackedVector2Array, depth: float, col: Color, edge_cols: Array) -> void:
	var n := pa.size()
	var a3 := PackedVector3Array()
	var b3 := PackedVector3Array()
	for i in n:
		a3.append(t * Vector3(pa[i].x, pa[i].y, 0.0))
		b3.append(t * Vector3(pb[i].x, pb[i].y, depth))
	kit.poly(b3, col)
	var back := PackedVector3Array()
	for i in range(n - 1, -1, -1):
		back.append(a3[i])
	kit.poly(back, col)
	for i in n:
		var j := (i + 1) % n
		kit.quad(a3[i], a3[j], b3[j], b3[i], edge_cols[i] if i < edge_cols.size() else col)


## How far out along n3 (from the station's root line) the cliff face is at
## `at` (a point on a vertical line through the face), measured on the face
## triangles of the stations either side of k; NAN if the line misses them.
static func _face_depth(rows: Array, fr: int, k: int, at: Vector3, n3: Vector3) -> float:
	var reach := 40.0
	var from := at + n3 * reach
	var best := NAN
	for kk in range(maxi(k - 2, 0), mini(k + 2, rows.size() - 1)):
		var ra: PackedVector3Array = rows[kk]
		var rb: PackedVector3Array = rows[kk + 1]
		for j in fr:
			var quad := [ra[j], rb[j], rb[j + 1], ra[j + 1]]
			for tri in [[0, 1, 2], [0, 2, 3]]:
				var hit: Variant = Geometry3D.ray_intersects_triangle(from, -n3, quad[tri[0]], quad[tri[1]], quad[tri[2]])
				if hit != null:
					var d := reach - from.distance_to(hit as Vector3)
					if is_nan(best) or d > best:
						best = d
	return best


## The swallow colony: the exposed face of the sandstone stratum between
## stations k0 and k1 (rock_mass left it open), cut into bedding strips
## with thirty burrows in three rows. Every burrow is an oval mouth with a
## flattened, worn sill (lit), a short throat in a shaded brown, and a
## dark chamber that widens behind it, so it reads as a hole from 60 m and
## as a burrow at 1 m. Built T-junction free: every strip shares one list of
## cuts, and the strips that meet the rock rows are fans onto them.
static func _colony(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, info: Dictionary, k0: int, k1: int, y0: float, band_h: float) -> void:
	var rows: Array = info["rows"]
	var U: Dictionary = info["u"]
	var vb: Dictionary = info["vb"]
	var vt: Dictionary = info["vt"]
	var su := PackedFloat32Array()
	var sq: Array[Vector3] = []
	for k in range(k0, k1 + 1):
		su.append(U[k])
		var q: Vector3 = rows[k][ROW_B2]
		sq.append(Vector3(q.x, 0.0, q.z))
	var ns := su.size()
	var seg_of := func(u: float) -> int:
		return clampi(su.bsearch(u) - 1, 0, ns - 2)
	# A point of the band face: u along the colony chord, v above y0. The
	# face is planar between two station folds.
	var pos := func(u: float, v: float) -> Vector3:
		var i: int = seg_of.call(u)
		var q: Vector3 = sq[i].lerp(sq[i + 1], (u - su[i]) / (su[i + 1] - su[i]))
		return Vector3(q.x, y0 + v, q.z)
	var normal_of := func(i: int) -> Vector3:
		return (sq[i + 1] - sq[i]).cross(Vector3.UP).normalized()
	# Burrows: three staggered rows of ten, each inside one facet.
	var row_v := [0.95, 2.4, 3.85]
	var hs := 0.22
	var mouths: Array[Dictionary] = []
	var u_lo := su[0] + 1.8
	var u_hi := su[ns - 1] - 1.8
	for r in 3:
		for c in 10:
			var w := rng.randf_range(0.24, 0.3)
			var half := w * 0.5 + 0.07
			var uc := lerpf(u_lo, u_hi, (float(c) + 0.25 + 0.5 * float(r % 2) + rng.randf_range(-0.2, 0.2)) / 10.5)
			for sv in su:
				if absf(uc - sv) < half + 0.05:
					uc = sv + (half + 0.06) * (1.0 if uc >= sv else -1.0)
			mouths.append({"u": uc, "v": float(row_v[r]) + rng.randf_range(-0.1, 0.1), "w": w, "half": half, "row": r,
				"top": rng.randf_range(0.0, 0.02), "side": rng.randf_range(-0.012, 0.012)})
	var cut_set := {}
	for sv in su:
		cut_set[snappedf(sv, 0.001)] = true
	for m in mouths:
		cut_set[snappedf(float(m["u"]) - float(m["half"]), 0.001)] = true
		cut_set[snappedf(float(m["u"]) + float(m["half"]), 0.001)] = true
	var cuts := PackedFloat32Array(cut_set.keys())
	cuts.sort()
	# Snap the station cuts back to their exact values (pos() and the rock
	# rows must agree to the bit on the shared edges).
	for i in cuts.size():
		for sv in su:
			if absf(cuts[i] - sv) < 0.002:
				cuts[i] = sv
	var sand := Palette.c(&"sand_bed")
	# No per-facet jitter here: the cuts make narrow cells, and jittered
	# cells read as planks. Tone changes only between bedding strips.
	var saved_jitter := kit.jitter
	kit.jitter = 0.0
	kit.sway = 0.0
	var lines := PackedFloat32Array()
	for r in 3:
		lines.append(float(row_v[r]) - hs)
		lines.append(float(row_v[r]) + hs)
	var tones := [-0.02, 0.01, 0.025, -0.01, 0.02, 0.0, -0.025]
	# Bottom strip: from the ledge's back edge (station points only) up to
	# the first line, a fan per facet.
	for i in ns - 1:
		var bl: Vector3 = rows[k0 + i][ROW_B2]
		var br: Vector3 = rows[k0 + i + 1][ROW_B2]
		var tp: Array[Vector3] = []
		for c in cuts:
			if c >= su[i] and c <= su[i + 1]:
				tp.append(pos.call(c, lines[0]))
		var col := Palette.vary(sand, tones[0])
		kit.tri(bl, br, tp[tp.size() - 1], col)
		for j in range(tp.size() - 1, 0, -1):
			kit.tri(bl, tp[j], tp[j - 1], col)
	# Inner strips: one quad per cell; a burrow tile (which other rows' cuts
	# may split into several cells) where a mouth sits.
	for li in lines.size() - 1:
		var lo := lines[li]
		var hi := lines[li + 1]
		var col := Palette.vary(sand, tones[li + 1])
		var tiles: Array[Dictionary] = []
		if li % 2 == 0:
			for m in mouths:
				if int(m["row"]) == li / 2:
					tiles.append(m)
		for ci in cuts.size() - 1:
			var ua := cuts[ci]
			var ub := cuts[ci + 1]
			var in_tile := false
			for m in tiles:
				if ua >= snappedf(float(m["u"]) - float(m["half"]), 0.001) - 1e-4 and ub <= snappedf(float(m["u"]) + float(m["half"]), 0.001) + 1e-4:
					in_tile = true
			if not in_tile:
				kit.quad(pos.call(ua, lo), pos.call(ub, lo), pos.call(ub, hi), pos.call(ua, hi), col)
		for m in tiles:
			var tl := snappedf(float(m["u"]) - float(m["half"]), 0.001)
			var tr := snappedf(float(m["u"]) + float(m["half"]), 0.001)
			# The tile's boundary, counter-clockwise, through every cut on it.
			var outer: Array[Vector2] = []
			for c in cuts:
				if c >= tl - 1e-4 and c <= tr + 1e-4:
					outer.append(Vector2(c, lo))
			for ci in range(cuts.size() - 1, -1, -1):
				if cuts[ci] >= tl - 1e-4 and cuts[ci] <= tr + 1e-4:
					outer.append(Vector2(cuts[ci], hi))
			_burrow(kit, m, outer, pos, normal_of.call(seg_of.call(float(m["u"]))), col)
	# Top strip: from the last line up to the cap's underside, a fan per facet.
	for i in ns - 1:
		var tl: Vector3 = rows[k0 + i][ROW_C1]
		var tr: Vector3 = rows[k0 + i + 1][ROW_C1]
		var bp: Array[Vector3] = []
		for c in cuts:
			if c >= su[i] and c <= su[i + 1]:
				bp.append(pos.call(c, lines[lines.size() - 1]))
		var col := Palette.vary(sand, tones[tones.size() - 1])
		for j in bp.size() - 1:
			kit.tri(tl, bp[j], bp[j + 1], col)
		kit.tri(tl, bp[bp.size() - 1], tr, col)
	# The rock quads either side of the band, fanned onto its edge vertices.
	var sand_rock := sand
	var chain_l: Array[Vector3] = [rows[k0][ROW_B2]]
	var chain_r: Array[Vector3] = [rows[k1][ROW_B2]]
	for v in lines:
		chain_l.append(pos.call(su[0], v))
		chain_r.append(pos.call(su[ns - 1], v))
	chain_l.append(rows[k0][ROW_C1])
	chain_r.append(rows[k1][ROW_C1])
	var la: Vector3 = rows[k0 - 1][ROW_B2]
	for j in chain_l.size() - 1:
		kit.tri(la, chain_l[j], chain_l[j + 1], sand_rock)
	kit.tri(la, rows[k0][ROW_C1], rows[k0 - 1][ROW_C1], sand_rock)
	var rb: Vector3 = rows[k1 + 1][ROW_B2]
	kit.tri(rb, rows[k1 + 1][ROW_C1], rows[k1][ROW_C1], sand_rock)
	for j in range(chain_r.size() - 1, 0, -1):
		kit.tri(rb, chain_r[j], chain_r[j - 1], sand_rock)
	kit.jitter = saved_jitter
	# Openings and refuges (the burrows), the ledge under the band.
	var hi_i := 0
	for m in mouths:
		var n: Vector3 = normal_of.call(seg_of.call(float(m["u"])))
		var centre: Vector3 = pos.call(float(m["u"]), float(m["v"]))
		ctx.add_opening("cliff_hole_%d" % hi_i, "cliff_hole", centre, n, float(m["w"]), 0.15, WorldBuild.span_for_gap(0.15), 0.55, 15)
		if hi_i % 3 == 0:
			ctx.add_refuge("cliff_hole_%d" % hi_i, centre - n * 0.45, 0.07, WorldBuild.span_for_gap(0.15))
		hi_i += 1
	var um := (su[0] + su[ns - 1]) * 0.5
	var n_mid: Vector3 = normal_of.call(seg_of.call(um))
	ctx.add_landmark("swallow_colony", "nest", pos.call(um, band_h * 0.5) + n_mid * 0.1, (su[ns - 1] - su[0]) * 0.5)
	for fu: float in [0.2, 0.45, 0.7, 0.9]:
		var u := lerpf(su[0], su[ns - 1], fu)
		var i: int = seg_of.call(u)
		var f := (u - su[i]) / (su[i + 1] - su[i])
		var b2: Vector3 = (rows[k0 + i][ROW_B2] as Vector3).lerp(rows[k0 + i + 1][ROW_B2], f)
		var b1: Vector3 = (rows[k0 + i][ROW_B1] as Vector3).lerp(rows[k0 + i + 1][ROW_B1], f)
		ctx.add_perch(b2.lerp(b1, 0.5) + Vector3.UP * 0.01, normal_of.call(i), Perch.Kind.LEDGE, 2.1, &"cliff")


## One burrow tile: the face cells `outer` (their boundary, counter-
## clockwise in (u, v)) with an oval mouth (flattened sill, slightly
## irregular), the throat, the chamber and the worn sill in front. pos maps
## (u, v) onto the face; n is the facet's outward normal.
static func _burrow(kit: MeshKit, m: Dictionary, outer: Array[Vector2], pos: Callable, n: Vector3, col: Color) -> void:
	var uc: float = m["u"]
	var vc: float = m["v"]
	var hw := float(m["w"]) * 0.5
	var hh := 0.075
	# Outline, counter-clockwise from the right (u right, v up, seen from
	# outside): an oval, its sill flattened, its crown a little irregular.
	var o2: Array[Vector2] = []
	for i in 12:
		var th := TAU * float(i) / 12.0
		var x := cos(th) * hw
		var y := sin(th) * hh
		if i >= 2 and i <= 4:
			y += float(m["top"]) * sin(th)
		if i == 8 or i == 10:
			y = -hh * 0.95
		if i == 0 or i == 6:
			x += float(m["side"])
		o2.append(Vector2(uc + x, vc + y))
	var outline: Array[Vector3] = []
	for q in o2:
		outline.append(pos.call(q.x, q.y))
	var ring: Array[Vector3] = []
	for q in outer:
		ring.append(pos.call(q.x, q.y))
	# The face round the mouth: both rings merged by angle about the centre
	# (both are star-shaped about it), fanned between them.
	var ev: Array = []
	for i in 12:
		ev.append([atan2(o2[i].y - vc, o2[i].x - uc), 0, i])
	for i in outer.size():
		ev.append([atan2(outer[i].y - vc, outer[i].x - uc), 1, i])
	ev.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))
	var cc := -1
	var co := -1
	for e in ev:
		if e[1] == 1:
			cc = e[2]
		else:
			co = e[2]
	for e in ev:
		if e[1] == 0:
			kit.tri(ring[cc], outline[e[2]], outline[co], col)
			co = e[2]
		else:
			kit.tri(ring[cc], ring[e[2]], outline[co], col)
			cc = e[2]
	# Throat (shaded) and chamber (dark), facing inward.
	var centre: Vector3 = pos.call(uc, vc)
	var throat := Palette.c(&"burrow_throat")
	var dark := Palette.c(&"burrow")
	var r1: Array[Vector3] = []
	var r2: Array[Vector3] = []
	for q in outline:
		r1.append(q - n * 0.22)
		r2.append(centre + (q - centre) * 1.5 - n * 0.34)
	var apex := centre - n * 1.0
	for i in 12:
		var j := (i + 1) % 12
		# Floor a little lighter (it catches the light), roof darker.
		var tone := 0.05 if i >= 7 and i <= 10 else (-0.1 if i >= 1 and i <= 4 else 0.0)
		kit.quad(outline[i], outline[j], r1[j], r1[i], Palette.vary(throat, tone))
		kit.quad(r1[i], r1[j], r2[j], r2[i], dark)
		kit.tri(r2[i], r2[j], apex, dark)
	# The worn sill: a low wedge under the whole lower arc of the mouth, its
	# top catching the light (where the birds land and scuff it).
	var sill_top := Palette.vary(col, 0.07)
	var sill_side := Palette.vary(col, -0.04)
	var back: Array[Vector3] = [outline[7], outline[8], outline[9], outline[10], outline[11]]
	var fr: Array[Vector3] = []
	var low: Array[Vector3] = []
	for q in back:
		fr.append(q + n * 0.045 - Vector3.UP * 0.02)
		low.append(q - Vector3.UP * 0.07)
	for i in back.size() - 1:
		kit.quad(fr[i], fr[i + 1], back[i + 1], back[i], sill_top)
		kit.quad(low[i], low[i + 1], fr[i + 1], fr[i], sill_side)
	kit.tri(back[0], low[0], fr[0], sill_side)
	kit.tri(back[4], fr[4], low[4], sill_side)


# --- canyon ------------------------------------------------------------

static func _canyon(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("canyon")
	var cn := WorldLayout.CANYON
	var hg := WorldLayout.CANYON_HALF_GAP
	# One U-shaped face line: up the west side, round the head, down the east.
	var west: Array = []
	var east: Array = []
	var tops_w: Array = []
	for i in cn.size():
		var dir: Vector2
		if i == 0:
			dir = (cn[1] - cn[0]).normalized()
		elif i == cn.size() - 1:
			dir = (cn[i] - cn[i - 1]).normalized()
		else:
			dir = (cn[i + 1] - cn[i - 1]).normalized()
		var right := Vector2(-dir.y, dir.x)
		west.append(cn[i] - right * hg)
		east.append(cn[i] + right * hg)
		tops_w.append(WorldLayout.CANYON_TOP[i])
	# The canyon mouth tapers down to the valley floor.
	var d0 := (cn[1] - cn[0]).normalized()
	west.push_front(west[0] - d0 * 34.0)
	east.push_front(east[0] - d0 * 34.0)
	tops_w.push_front(2.0)
	var head: Vector2 = cn[-1]
	var hd := (cn[-1] - cn[-2]).normalized()
	var hr := Vector2(-hd.y, hd.x)
	var pts: Array = west.duplicate()
	var tops: Array = tops_w.duplicate()
	for k in range(1, 5):
		var a := PI * float(k) / 5.0
		pts.append(head - hr * hg * cos(a) + hd * hg * sin(a))
		tops.append(WorldLayout.CANYON_TOP[-1])
	for i in range(east.size() - 1, -1, -1):
		pts.append(east[i])
		tops.append(tops_w[i])
	var info := rock_mass(ctx, kit, rng, pts, tops, true, "canyon", 26.0, 0.75, 1.4)
	var P: Array[Vector2] = info["P"]
	var N: Array[Vector2] = info["N"]
	var rows: Array = info["rows"]
	var fr: int = info["face_rows"]
	for k in range(2, P.size() - 2, 4):
		var top: Vector3 = rows[k][fr]
		ctx.add_perch(top + Vector3(N[k].x, 0, N[k].y) * 0.8, Vector3(N[k].x, 0, N[k].y), Perch.Kind.ROCK, 2.1, &"canyon")
	# Natural arch spanning the gorge near its top, at the third vertex.
	var ci := 2
	var cdir := (cn[ci + 1] - cn[ci - 1]).normalized()
	var cright := Vector2(-cdir.y, cdir.x)
	var ctop: float = WorldLayout.CANYON_TOP[ci] + ctx.ground(cn[ci].x + cright.x * (hg - 3.0), cn[ci].y + cright.y * (hg - 3.0))
	var path := PackedVector3Array()
	var widths := PackedFloat32Array()
	var thicks := PackedFloat32Array()
	var steps := 12
	var span := hg + 5.0
	for k in steps + 1:
		var f := float(k) / steps * 2.0 - 1.0
		var xz := cn[ci] + cright * span * f
		var y := ctop - 7.0 - 12.0 * f * f
		path.append(Vector3(xz.x, y, xz.y))
		widths.append(3.0 + 1.5 * f * f)
		thicks.append(2.2 + 1.8 * f * f)
	var ak := ctx.kit("canyon_arch")
	sweep(ak, rng, path, Vector3(cdir.x, 0, cdir.y), widths, thicks, Palette.c(&"sandstone"), Palette.c(&"rock_light"))
	var floor_y := ctx.ground(cn[ci].x, cn[ci].y)
	var under := ctop - 7.0 - 2.2
	var ac := Vector3(cn[ci].x, (maxf(floor_y, WorldLayout.WATER_Y) + under) * 0.5, cn[ci].y)
	var opening_h := under - maxf(floor_y, WorldLayout.WATER_Y)
	# Nominal size; SoaringWorld measures the real passage once it is built.
	var op := ctx.add_opening("canyon_arch_passage", "arch", ac - Vector3(cdir.x, 0, cdir.y) * 1.5, Vector3(cdir.x, 0, cdir.y) * -1.0,
		hg * 2.0 - 3.0, opening_h, WorldBuild.span_for_gap(minf(hg * 2.0 - 3.0, opening_h)), 6.0, 15)
	op["measure"] = true
	ctx.add_landmark("canyon_arch", "arch", Vector3(cn[ci].x, under + 2.0, cn[ci].y), 18.0)
	ctx.add_perch(path[steps / 2] + Vector3(0, thicks[steps / 2] * 0.85, 0), Vector3(cright.x, 0, cright.y), Perch.Kind.ROCK, 2.1, &"canyon")
	ctx.add_landmark("canyon", "canyon", Vector3(cn[2].x, 20.0, cn[2].y), 140.0)


# --- lake arch ---------------------------------------------------------

static func _lake_arch(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("lake_arch")
	var c := WorldLayout.LAKE_ARCH
	var axis := Vector2(cos(0.5), sin(0.5))
	var half_span := 13.0
	var rise := 21.0
	var bed := ctx.ground(c.x, c.y) - 1.0
	var path := PackedVector3Array()
	var widths := PackedFloat32Array()
	var thicks := PackedFloat32Array()
	var steps := 16
	for k in steps + 1:
		var a := PI * float(k) / steps
		var xz := c + axis * (-cos(a) * half_span)
		# Flat-topped and lopsided: one leg stout, the crown a slab.
		var y := bed + pow(sin(a), 0.6) * rise
		if k == 0 or k == steps:
			y = bed - 2.0
		path.append(Vector3(xz.x, y, xz.y))
		var f := sin(a)
		var lop := 1.0 + 0.35 * cos(a)
		widths.append((6.4 - 3.0 * f) * lop)
		thicks.append((5.0 - 2.2 * f) * lop)
	sweep(kit, rng, path, Vector3(-axis.y, 0, axis.x), widths, thicks, Palette.c(&"sandstone"), Palette.c(&"rock_light"))
	var wy := WorldLayout.WATER_Y
	var inner_top := bed + rise - thicks[steps / 2]
	var n3 := Vector3(-axis.y, 0, axis.x)
	var clear_w := half_span * 2.0 - 11.0
	var op := ctx.add_opening("lake_arch_passage", "arch", Vector3(c.x, (wy + inner_top) * 0.5, c.y), n3, clear_w, inner_top - wy,
		WorldBuild.span_for_gap(minf(clear_w, inner_top - wy)), 3.0, 15)
	op["measure"] = true
	ctx.add_perch(path[steps / 2] + Vector3(0, thicks[steps / 2] * 0.85, 0), n3, Perch.Kind.ROCK, 2.1, &"lake")
	ctx.add_landmark("lake_arch", "arch", Vector3(c.x, bed + rise * 0.6, c.y), 14.0)
	ctx.add_feature(c.x, c.y, 14.0, "arch")
	ctx.add_footprint("lake_arch", PackedVector2Array([Vector2(path[0].x, path[0].z), Vector2(path[steps].x, path[steps].z)]), bed - 2.0, 6.0, 2.5, widths[0] * 1.3 + 1.0, kit.name)


# --- ruined tower ------------------------------------------------------

static func _ruin(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("ruin")
	var c := WorldLayout.RUIN
	var S := 6.0
	var th := 0.7
	var foot := WorldBuild.rect_points(c, Vector2(S * 0.5, S * 0.5), 0.3)
	var g := ctx.ground_min(foot)
	var y0 := g - 0.4
	var xf := Transform3D(Basis(Vector3.UP, 0.3), Vector3(c.x, y0, c.y))
	var prev := kit.xf
	kit.xf = xf
	var stone := Palette.c(&"stone")
	var stone_d := Palette.c(&"stone_dark")
	# Roofless: daylight falls inside, so the inner faces are weathered stone.
	var dark := Palette.vary(stone_d, -0.12)
	var heights := [15.0, 12.5, 16.5, 11.0]
	var walls := [
		Transform3D(Basis.IDENTITY, Vector3(-S * 0.5, 0, S * 0.5 - th * 0.5)),
		Transform3D(Basis(Vector3.UP, PI), Vector3(S * 0.5, 0, -S * 0.5 + th * 0.5)),
		Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-S * 0.5 + th * 0.5, 0, -S * 0.5 + th)),
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(S * 0.5 - th * 0.5, 0, S * 0.5 - th)),
	]
	var outs := [Vector3.BACK, Vector3.FORWARD, Vector3.LEFT, Vector3.RIGHT]
	for i in 4:
		var w := S if i < 2 else S - 2.0 * th
		var h: float = heights[i]
		var holes := [
			{"rect": Rect2(w * 0.5 - 0.55, 5.0, 1.1, 1.9), "arch": true, "segs": 5},
			{"rect": Rect2(w * 0.5 - 0.45, 9.2, 0.9, 1.5), "arch": true, "segs": 5},
		]
		kit.wall(walls[i], w, h, th, holes, stone, dark, stone_d, (1 | 2 | 4) if i < 2 else 4)
		# Broken crown: a few stepped blocks along the top edge; the tallest
		# is the lookout big birds land on.
		var top_b := Vector3.ZERO
		for b in 3:
			var bu := w * (0.2 + 0.3 * b)
			var bh := rng.randf_range(0.4, 1.6)
			kit.box((walls[i] as Transform3D) * Transform3D(Basis.IDENTITY, Vector3(bu, h + bh * 0.5, 0)), Vector3(w * 0.22, bh, th), stone_d)
			if h + bh > top_b.y:
				top_b = Vector3(bu, h + bh, 0.0)
		for hi in holes.size():
			var r: Rect2 = holes[hi]["rect"]
			var centre := xf * ((walls[i] as Transform3D) * Vector3(r.get_center().x, r.get_center().y, th * 0.5))
			ctx.add_opening("ruin_%d_%d" % [i, hi], "window", centre, xf.basis * (outs[i] as Vector3), r.size.x, r.size.y,
				WorldBuild.span_for_gap(r.size.x), 1.5, 15)
		ctx.add_perch(xf * ((walls[i] as Transform3D) * top_b), xf.basis * (outs[i] as Vector3), Perch.Kind.LEDGE, 2.1, &"ruin")
	kit.xf = prev
	# Rubble at the foot (world space), resting on the ground all round.
	for k in 6:
		var a := rng.randf() * TAU
		var q := c + Vector2(cos(a), sin(a)) * rng.randf_range(4.5, 7.0)
		var radii := Vector3(0.9, 0.6, 0.8) * rng.randf_range(0.7, 1.4)
		var base := ctx.ground_blob(kit, q, radii, stone_d, 0.2, stone_d, -0.36, 0.1)
		ctx.add_footprint("ruin_rubble", PackedVector2Array([q]), base, 0.1 + ctx.ground_relief(q, radii.x) + 0.05, -1.0, radii.x * 1.3 + 0.3, kit.name)
	ctx.add_footprint("ruin", foot, y0, 2.0, 2.5, -1.0, kit.name)
	ctx.add_feature(c.x, c.y, 8.0, "ruin")
	ctx.add_landmark("ruin", "tower", Vector3(c.x, y0 + 8.0, c.y), 5.0)
	ctx.add_refuge("ruin_inside", Vector3(c.x, y0 + 3.0, c.y), 1.8, WorldBuild.span_for_gap(0.9))
