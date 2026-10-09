extends TestCase
## Verifier probe (birds, round 1): animation claims (B2/B6) outside the
## builder's 36-pose sweep.
##  * Real takeoff and landing transitions, driven through BirdModel's own
##    smoothing at 72 Hz while the phase beats at 10 Hz: every displayed
##    frame is checked for left/right and self wing crossings, inverted wing
##    or tail triangles, outer wing vertices inside the body, and wing
##    triangles passing through the tail (not covered by the builder).
##  * Wing vs tail crossings in the canonical perched and dive-tuck poses.
##  * Downstroke shorter than upstroke at partial flap_amount and while
##    half folded (the builder only checks amount 1, fold 0).
##  * Wingspan through the public API: get_wingtip() at scale 2.1.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _tris_of(arr: Array, want: Callable) -> PackedInt32Array:
	var g := Geo.groups(arr)
	var out := PackedInt32Array()
	for t in range(0, g.size(), 3):
		if want.call(g[t]):
			out.append(t)
	return out


## Crossings of every kind for one pose. Returns {lr, self_r, wing_tail,
## inverted, inside, worst_e}.
func _check_pose(sp: StringName, arr: Array, inst: Vector4) -> Dictionary:
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var right := Geo.wing_tris(arr, 1.0)
	var left := Geo.wing_tris(arr, -1.0)
	var tail := _tris_of(arr, func(g: int) -> bool: return g == BirdPose.G_TAIL)
	var res := BirdPose.pose_arrays_with_normals(arr, inst)
	var v: PackedVector3Array = res[0]
	var nn: PackedVector3Array = res[1]
	var out := {}
	out["lr"] = Geo.count_crossings(v, rest, right, left, false)
	out["self_r"] = Geo.count_crossings(v, rest, right, right, true)
	out["wing_tail"] = Geo.count_crossings(v, rest, right, tail, false, 1000) + Geo.count_crossings(v, rest, left, tail, false, 1000)
	# Inverted wing/tail triangles (same criterion as the builder's test).
	var g := Geo.groups(arr)
	var bad := 0
	for t in range(0, v.size(), 3):
		if not Geo.is_wing(g[t]) and g[t] != BirdPose.G_TAIL:
			continue
		var cr := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
		var cr0 := (rest[t + 1] - rest[t]).cross(rest[t + 2] - rest[t])
		var nsum := nn[t] + nn[t + 1] + nn[t + 2]
		if cr.dot(nsum) > 1e-4 * cr0.length() * nsum.length():
			bad += 1
	out["inverted"] = bad
	# Outer wing vertices inside the body ellipse (builder's criterion).
	var vb := Geo.posed(arr, inst, true)
	var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM2]
	var inside := 0
	var worst := INF
	for i in vb.size():
		if not Geo.is_wing(g[i]):
			continue
		var sx := c1[i * 4]
		var wx := c2[i * 4]
		if g[i] == BirdPose.G_ARM and absf(rest[i].x) <= sx + 0.6 * (wx - sx) + 1e-4:
			continue
		var sec := BirdMeshBuilder.body_section(sp, vb[i].z)
		if sec == Vector3.ZERO:
			continue
		var e := pow(vb[i].x / sec.x, 2.0) + pow((vb[i].y - sec.z) / sec.y, 2.0)
		worst = minf(worst, e)
		if e < 0.98:
			inside += 1
	out["inside"] = inside
	out["worst_e"] = worst
	return out


## Displayed poses of a model through a takeoff (perched -> flapping) and a
## landing (flapping -> perched), as NpcBird drives them.
func _transition_poses(sp: StringName) -> Array[Vector4]:
	var m := BirdModels.create(sp)
	add_child(m)
	m.perched = true
	m.wing_fold = 1.0
	m.flap_amount = 0.0
	m.snap()
	BirdBatch.sync_all(DT)
	var out: Array[Vector4] = []
	var ph := 0.0
	var amt := 0.0
	# Takeoff: perched off, wings open, beats ramp (NpcBird: 6/s).
	m.perched = false
	m.wing_fold = 0.0
	for f in 40:
		ph = fposmod(ph + 10.0 * DT, 1.0)
		amt = move_toward(amt, 1.0, 6.0 * DT)
		m.flap_phase = ph
		m.flap_amount = amt
		BirdBatch.sync_all(DT)
		out.append(m.displayed_pose())
	# Landing: NpcBird sets perched, fold 1, amount 0 in one frame.
	m.perched = true
	m.wing_fold = 1.0
	m.flap_amount = 0.0
	for f in 40:
		ph = fposmod(ph + 10.0 * DT, 1.0)
		m.flap_phase = ph
		BirdBatch.sync_all(DT)
		out.append(m.displayed_pose())
	m.free()
	return out


func test_takeoff_and_landing_blends_stay_clean() -> void:
	var report := {}
	var total := {"lr": 0, "self_r": 0, "wing_tail": 0, "inverted": 0, "inside": 0}
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp, 0)
		var poses := _transition_poses(sp)
		var agg := {"lr": 0, "self_r": 0, "wing_tail": 0, "inverted": 0, "inside": 0, "worst_e": INF, "first": ""}
		for i in range(0, poses.size(), 2):
			var r := _check_pose(sp, arr, poses[i])
			for k in ["lr", "self_r", "wing_tail", "inverted", "inside"]:
				if int(r[k]) > 0 and agg["first"] == "":
					agg["first"] = "%s@%s" % [k, str(poses[i])]
				agg[k] += int(r[k])
				total[k] += int(r[k])
			agg["worst_e"] = minf(agg["worst_e"], r["worst_e"])
		agg["worst_e"] = snappedf(agg["worst_e"], 0.001)
		report[String(sp)] = agg
		eq(agg["lr"], 0, "%s takeoff/landing: left/right wings never cross (%s)" % [sp, agg["first"]])
		eq(agg["self_r"], 0, "%s takeoff/landing: a wing never crosses itself (%s)" % [sp, agg["first"]])
		eq(agg["inverted"], 0, "%s takeoff/landing: no inverted wing/tail triangles (%s)" % [sp, agg["first"]])
		eq(agg["inside"], 0, "%s takeoff/landing: outer wing vertices stay outside the body (worst %.3f, %s)" % [sp, agg["worst_e"], agg["first"]])
	metric("transitions", report)
	metric("transition_totals", total)


func test_wing_does_not_pass_through_tail() -> void:
	# Not in the builder's suite: folded primaries lie over the tail when
	# perched / tucked; they may touch it but should not pierce it.
	var report := {}
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp, 0)
		var row := {}
		for name in ["glide", "flap_bottom", "dive_tuck", "perched", "half_tuck"]:
			var inst: Vector4 = {"glide": Vector4(0.25, 0, 0, 0), "flap_bottom": Vector4(0.45, 1, 0, 0),
				"dive_tuck": Vector4(0.25, 0, 1, 0), "perched": Vector4(0.25, 0, 1, 1), "half_tuck": Vector4(0.25, 0, 0.5, 0)}[name]
			var r := _check_pose(sp, arr, inst)
			row[name] = r["wing_tail"]
		report[String(sp)] = row
		var n := 0
		for k in row:
			n += int(row[k])
		eq(n, 0, "%s: no wing triangle passes through the tail (%s)" % [sp, str(row)])
	metric("wing_tail_crossings", report)


func _tip(sp: StringName, inst: Vector4) -> Vector3:
	var r := BirdModels.tip_record(sp)
	var out := BirdPose.pose(r[0], r[1], r[2], r[3], r[4], r[5], inst, 0.0, 0.0, false, r[6])
	return out[0]


func test_downstroke_share_at_partial_amounts_and_folds() -> void:
	var report := {}
	for sp in BirdSpecies.IDS:
		var row := {}
		for cfg in [[0.25, 0.0], [0.5, 0.0], [1.0, 0.0], [1.0, 0.3], [0.6, 0.5]]:
			var n := 400
			var ys := PackedFloat32Array()
			for i in n:
				ys.append(_tip(sp, Vector4(float(i) / n, cfg[0], cfg[1], 0.0)).y)
			var hi := 0
			var lo := 0
			for i in n:
				if ys[i] > ys[hi]:
					hi = i
				if ys[i] < ys[lo]:
					lo = i
			var down := float(posmod(lo - hi, n)) / n
			var amp := ys[hi] - ys[lo]
			row["a%.2f_f%.1f" % cfg] = [snappedf(down, 0.001), snappedf(amp, 0.001)]
			if amp > 0.01:
				lt(down, 0.5, "%s amount %.2f fold %.1f: downstroke %.2f shorter than upstroke" % [sp, cfg[0], cfg[1], down])
		report[String(sp)] = row
	metric("down_share_amp", report)


func test_wingspan_through_public_api() -> void:
	# get_wingtip at scale 2.1 in the glide pose: tips 2.1 m apart, level.
	var report := {}
	for sp in BirdSpecies.IDS:
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * 2.1
		m.position = Vector3(3, 5, -7)
		add_child(m)
		m.snap()
		BirdBatch.sync_all(DT)
		var r := m.get_wingtip(1)
		var l := m.get_wingtip(-1)
		near(absf(r.x - l.x), 2.1, 2.1e-3, "%s: tips 2.1 m apart across (x) at scale 2.1" % sp)
		report[String(sp)] = snappedf(absf(r.x - l.x) / 2.1, 0.0001)
		m.free()
	metric("span_over_scale", report)
