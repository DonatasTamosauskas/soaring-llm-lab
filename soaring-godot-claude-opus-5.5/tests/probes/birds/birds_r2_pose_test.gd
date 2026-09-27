extends TestCase
## Round-2 verifier probes: the perched look (experience lens). Written by the
## verifier. Uses only the birds area's mesh + BirdPose (proven equal to the
## shader by the area's GPU check) and its own rasteriser.
##
##   tools/gd.sh birds_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/birds --suite=birds_r2_pose
##
## 1. Folded wings of a perched bird should lie on the body (a real bird's
##    folded wing covers the upper flank and back). Measured: the lateral gap
##    between the wing's inner surface and the body's widest point, slab by
##    slab along the body, in span units. A gap shows from above and from
##    behind as a detached blade (tests/probes/birds/birds_r2_render.gd,
##    artifacts/birds/verify/r2_perched.png).
## 2. The wren's field mark, its cocked tail when perched: how much of the
##    tail's side silhouette is not hidden behind the rest of the bird.

const PERCHED := Vector4(0.25, 0.0, 1.0, 1.0)


static func _groups(arr: Array) -> PackedInt32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedInt32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = int(roundf(c0[i * 4]))
	return out


static func _sides(arr: Array) -> PackedFloat32Array:
	var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
	var out := PackedFloat32Array()
	out.resize(c0.size() / 4)
	for i in out.size():
		out[i] = c0[i * 4 + 1]
	return out


## Points on a triangle (vertices, edge points, interior) for slab sampling.
static func _samples(a: Vector3, b: Vector3, c: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var n := 6
	for i in n + 1:
		for j in n + 1 - i:
			var u := float(i) / n
			var w := float(j) / n
			out.append(a * (1.0 - u - w) + b * u + c * w)
	return out


func test_r2_perched_wings_lie_on_the_body() -> void:
	var res := {}
	var worst := [0.0, ""]
	var slabs := 24
	for sp: StringName in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var tuck := _max_gap(arr, BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, 1.0, 0.0), 0.0, 0.0, true), slabs)
		res["dive_tuck_" + String(sp)] = snappedf(tuck, 0.001)
		var v := BirdPose.pose_arrays(arr, PERCHED, 0.0, 0.0, true)
		var g := _groups(arr)
		var sd := _sides(arr)
		var zmin := INF
		var zmax := -INF
		for i in v.size():
			if g[i] == BirdPose.G_BODY:
				zmin = minf(zmin, v[i].z)
				zmax = maxf(zmax, v[i].z)
		var body_half := PackedFloat32Array()
		var wing_in := PackedFloat32Array()
		body_half.resize(slabs)
		wing_in.resize(slabs)
		body_half.fill(-1.0)
		wing_in.fill(INF)
		var dz := (zmax - zmin) / slabs
		for t in range(0, v.size(), 3):
			var grp := g[t]
			var is_body := grp == BirdPose.G_BODY
			var is_right_wing := (grp == BirdPose.G_ARM or grp == BirdPose.G_HAND) and sd[t] > 0.0
			if not is_body and not is_right_wing:
				continue
			for p in _samples(v[t], v[t + 1], v[t + 2]):
				var k := int((p.z - zmin) / dz)
				if k < 0 or k >= slabs:
					continue
				if is_body:
					body_half[k] = maxf(body_half[k], absf(p.x))
				else:
					wing_in[k] = minf(wing_in[k], p.x)
		var max_gap := -INF
		var gaps := []
		for k in slabs:
			if body_half[k] < 0.0 or wing_in[k] == INF:
				continue
			var gap := wing_in[k] - body_half[k]
			gaps.append(snappedf(gap, 0.001))
			max_gap = maxf(max_gap, gap)
		var span: float = SizeRules.species_data(sp)["span"]
		# How wide the see-through gap is for this species at 12 m (a bird on
		# a branch below a player flying past), on a Quest Pro (20 px/deg).
		var px12 := rad_to_deg(max_gap * span / 12.0) * 20.0
		res[String(sp)] = {"max_gap_span": snappedf(max_gap, 0.001), "gap_px_at_12m": snappedf(px12, 0.1),
			"body_width_span": snappedf(2.0 * body_half[slabs / 2], 0.001), "gaps_along_body": gaps}
		if max_gap > worst[0]:
			worst = [max_gap, String(sp)]
	metric("perched_wing_gap", res)
	print("[birds-r2] perched wing gap from the flank (span units, px at 12 m):")
	for k in res:
		if not res[k] is Dictionary:
			print("[birds-r2]   %s max gap %.3f span" % [k, res[k]])
			continue
		print("[birds-r2]   %-9s max gap %.3f span (%.1f px at 12 m), body width %.3f" % [k, res[k]["max_gap_span"], res[k]["gap_px_at_12m"], res[k]["body_width_span"]])
	# A folded wing lies on the flank: allow the model's own 0.016 outward
	# offset (FOLD_OUT) minus a little, i.e. no see-through gap above ~1 cm
	# on a 1 m bird.
	lt(worst[0], 0.012, "no perched species shows a gap between folded wing and body (worst %s)" % worst[1])


func _max_gap(arr: Array, v: PackedVector3Array, slabs: int) -> float:
	var g := _groups(arr)
	var sd := _sides(arr)
	var zmin := INF
	var zmax := -INF
	for i in v.size():
		if g[i] == BirdPose.G_BODY:
			zmin = minf(zmin, v[i].z)
			zmax = maxf(zmax, v[i].z)
	var bh := PackedFloat32Array()
	var wi := PackedFloat32Array()
	bh.resize(slabs)
	wi.resize(slabs)
	bh.fill(-1.0)
	wi.fill(INF)
	var dz := (zmax - zmin) / slabs
	for t in range(0, v.size(), 3):
		var grp := g[t]
		var is_body := grp == BirdPose.G_BODY
		var is_rw := (grp == BirdPose.G_ARM or grp == BirdPose.G_HAND) and sd[t] > 0.0
		if not is_body and not is_rw:
			continue
		for p in _samples(v[t], v[t + 1], v[t + 2]):
			var k := int((p.z - zmin) / dz)
			if k < 0 or k >= slabs:
				continue
			if is_body:
				bh[k] = maxf(bh[k], absf(p.x))
			else:
				wi[k] = minf(wi[k], p.x)
	var mg := -INF
	for k in slabs:
		if bh[k] >= 0.0 and wi[k] != INF:
			mg = maxf(mg, wi[k] - bh[k])
	return mg


func test_r2_wren_cocked_tail_shows_when_perched() -> void:
	var res := {}
	var n := 220
	var half := 0.6
	for pose_name in ["perched", "glide (sanity)"]:
		for sp: StringName in BirdSpecies.IDS:
			_tail_row(sp, PERCHED if pose_name == "perched" else Vector4(0.25, 0.0, 0.0, 0.0), n, half, res, pose_name)
	metric("perched_tail_visibility", res)
	for k in res:
		print("[birds-r2]   tail ", k, " ", res[k])
	gt(float(res["perched wren"]["tail_visible_fraction_side"]), 0.3, "the wren's cocked tail (its perched field mark) shows from the side, 35 deg above")
	gt(float(res["glide (sanity) sparrow"]["tail_visible_fraction_side"]), 0.5, "sanity: a gliding sparrow's tail shows from the side, 35 deg above")


func _tail_row(sp: StringName, inst: Vector4, n: int, half: float, res: Dictionary, pose_name: String) -> void:
		var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
		var v := BirdPose.pose_arrays(arr, inst)
		var g := _groups(arr)
		var tail_back := -INF
		var wing_back := -INF
		var tail := PackedByteArray()
		var rest := PackedByteArray()
		tail.resize(n * n)
		rest.resize(n * n)
		var tail_tip := Vector3(0, -INF, 0)
		for t in range(0, v.size(), 3):
			var target := tail if g[t] == BirdPose.G_TAIL else rest
			var k := n / (2.0 * half)
			# Seen from the right side and 35 deg above (an exact profile shows
			# every flat tail edge-on, as a line).
			var a := Vector2((v[t].z + half) * k, (half - _up(v[t])) * k)
			var b := Vector2((v[t + 1].z + half) * k, (half - _up(v[t + 1])) * k)
			var c := Vector2((v[t + 2].z + half) * k, (half - _up(v[t + 2])) * k)
			_fill(target, n, a, b, c)
			if g[t] == BirdPose.G_TAIL:
				for q in [v[t], v[t + 1], v[t + 2]]:
					if q.y > tail_tip.y:
						tail_tip = q
					tail_back = maxf(tail_back, q.z)
			elif g[t] == BirdPose.G_ARM or g[t] == BirdPose.G_HAND:
				for q in [v[t], v[t + 1], v[t + 2]]:
					wing_back = maxf(wing_back, q.z)
		var t_n := 0
		var t_vis := 0
		for i in n * n:
			if tail[i] == 1:
				t_n += 1
				if rest[i] == 0:
					t_vis += 1
		var frac := float(t_vis) / maxf(t_n, 1)
		res["%s %s" % [pose_name, sp]] = {"tail_visible_fraction_side": snappedf(frac, 0.01), "tail_top_y": snappedf(tail_tip.y, 0.003),
			"tail_beyond_wingtips_span": snappedf(tail_back - wing_back, 0.003)}


static func _up(p: Vector3) -> float:
	return -p.x * sin(deg_to_rad(35.0)) + p.y * cos(deg_to_rad(35.0))


static func _fill(img: PackedByteArray, res: int, a: Vector2, b: Vector2, c: Vector2) -> void:
	var area := (b - a).cross(c - a)
	if absf(area) < 1e-9:
		return
	var x0 := maxi(0, int(floor(minf(a.x, minf(b.x, c.x)))))
	var x1 := mini(res - 1, int(ceil(maxf(a.x, maxf(b.x, c.x)))))
	var y0 := maxi(0, int(floor(minf(a.y, minf(b.y, c.y)))))
	var y1 := mini(res - 1, int(ceil(maxf(a.y, maxf(b.y, c.y)))))
	var sgn := 1.0 if area > 0.0 else -1.0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			if (b - a).cross(p - a) * sgn >= 0.0 and (c - b).cross(p - b) * sgn >= 0.0 and (a - c).cross(p - c) * sgn >= 0.0:
				img[y * res + x] = 1
