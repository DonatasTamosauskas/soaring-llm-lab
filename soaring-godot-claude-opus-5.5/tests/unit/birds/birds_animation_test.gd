extends TestCase
## B2: the wing animation, on the maths the vertex shader runs (BirdPose;
## tests/shots/birds_gpu_check proves the two draw the same silhouettes):
## downstroke quicker than upstroke, no inverted, degenerate or crossing
## wing triangles anywhere in the flap cycle, tuck, dive and perch, correct
## fold/tuck/perch poses, bank rolls the right way, body bob, and no pops
## when an owner changes flap_amount, wing_fold, perched, bank, highlight or
## flap_phase abruptly.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const DT := 1.0 / 72.0


func _tip_y(sp: StringName, ph: float, amount: float = 1.0) -> float:
	var r := BirdModels.tip_record(sp)
	var out := BirdPose.pose(r[0], r[1], r[2], r[3], r[4], r[5], Vector4(ph, amount, 0.0, 0.0), 0.0, 0.0, false, r[6], r[7])
	return (out[0] as Vector3).y


func test_downstroke_is_quicker_than_upstroke() -> void:
	var table := {}
	for sp in BirdSpecies.IDS:
		var n := 400
		var ys := PackedFloat32Array()
		for i in n:
			ys.append(_tip_y(sp, float(i) / n))
		var hi := 0
		var lo := 0
		for i in n:
			if ys[i] > ys[hi]:
				hi = i
			if ys[i] < ys[lo]:
				lo = i
		var down := float(posmod(lo - hi, n)) / n
		var up := 1.0 - down
		lt(down, up, "%s: downstroke (%.2f) shorter than upstroke (%.2f)" % [sp, down, up])
		between(down, 0.35, 0.48, "%s: downstroke share of the beat" % sp)
		var amp := ys[hi] - ys[lo]
		gt(amp, 0.3, "%s: wingtip travels > 0.3 span per beat" % sp)
		# Glide: no motion at all.
		near(_tip_y(sp, 0.1, 0.0), _tip_y(sp, 0.7, 0.0), 1e-6, "%s: wings still at flap_amount 0" % sp)
		table[String(sp)] = {"down": snappedf(down, 0.001), "up": snappedf(up, 0.001), "tip_amp": snappedf(amp, 0.001)}
	metric("stroke", table)


func test_flap_amount_scales_the_beat_smoothly() -> void:
	for sp in [&"sparrow", &"gull", &"eagle"]:
		var prev := 0.0
		for k in 5:
			var a := k / 4.0
			var hi := -INF
			var lo := INF
			for i in 100:
				var y := _tip_y(sp, i / 100.0, a)
				hi = maxf(hi, y)
				lo = minf(lo, y)
			if k > 0:
				gt(hi - lo, prev, "%s: amplitude grows with flap_amount %.2f" % [sp, a])
			prev = hi - lo


func test_glide_pose_is_the_rest_mesh() -> void:
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var grp := Geo.groups(arr)
		var g := Geo.posed(arr, Vector4(0.37, 0.0, 0.0, 0.0))
		var worst := 0.0
		for i in v.size():
			# Legs are modelled hanging (the perched pose) and tuck in flight.
			if grp[i] != BirdPose.G_LEG:
				worst = maxf(worst, v[i].distance_to(g[i]))
		lt(worst, 1e-5, "%s: glide pose == rest mesh (all but the tucked legs)" % sp)


func test_no_inverted_or_collapsed_triangles() -> void:
	var worst_ratio := 1.0
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var arr := Geo.arrays(sp, lod)
			var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var g := Geo.groups(arr)
			var bad := 0
			var small := 0
			for inst in Geo.pose_set():
				var res := BirdPose.pose_arrays_with_normals(arr, inst)
				var v: PackedVector3Array = res[0]
				var nn: PackedVector3Array = res[1]
				for t in range(0, v.size(), 3):
					if not Geo.is_wing(g[t]) and g[t] != BirdPose.G_TAIL:
						continue
					var cr := (v[t + 1] - v[t]).cross(v[t + 2] - v[t])
					var cr0 := (rest[t + 1] - rest[t]).cross(rest[t + 2] - rest[t])
					var nsum := nn[t] + nn[t + 1] + nn[t + 2]
					# Inverted: the posed face turned against its own normal
					# (by more than a sliver: a face squeezed to zero area
					# is invisible, not inverted).
					if cr.dot(nsum) > 1e-4 * cr0.length() * nsum.length():
						bad += 1
					# Collapse is only a defect in flight: folding stacks the
					# arm under the hand on purpose (checked for inversion).
					if inst.z > 0.5:
						continue
					var ratio := cr.length() / maxf(cr0.length(), 1e-12)
					worst_ratio = minf(worst_ratio, ratio)
					if ratio < 0.15:
						small += 1
			eq(bad, 0, "%s LOD%d: no inverted wing/tail triangles over %d poses" % [sp, lod, Geo.pose_set().size()])
			eq(small, 0, "%s LOD%d: no wing/tail triangle collapses below 15%% of its area" % [sp, lod])
	metric("smallest_area_ratio", snappedf(worst_ratio, 0.001))


func test_upper_surface_never_flips_in_flight() -> void:
	# While flying (not perched, not tucked) the upper wing surface keeps
	# facing up-ish: a wing turned upside down reads as broken.
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var g := Geo.groups(arr)
		var n0: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var worst := 1.0
		for i in 20:
			var res := BirdPose.pose_arrays_with_normals(arr, Vector4(i / 20.0, 1.0, 0.0, 0.0))
			var nn: PackedVector3Array = res[1]
			for t in range(0, nn.size(), 3):
				if Geo.is_wing(g[t]) and n0[t].y > 0.5:
					worst = minf(worst, nn[t].y)
		gt(worst, 0.0, "%s: upper wing surfaces face up through the whole beat" % sp)


func test_wings_never_cross() -> void:
	# Left vs right wing, and each wing against itself (arm vs hand, fingers),
	# over the flap cycle, half and full tuck, perching and the blends.
	var report := {}
	for sp in BirdSpecies.IDS:
		for lod in BirdModels.LOD_COUNT:
			var arr := Geo.arrays(sp, lod)
			var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var right := Geo.wing_tris(arr, 1.0)
			var left := Geo.wing_tris(arr, -1.0)
			var lr := 0
			var self_x := 0
			var first := ""
			for inst in Geo.pose_set():
				var v := Geo.posed(arr, inst)
				var a := Geo.count_crossings(v, rest, right, left, false)
				var b := Geo.count_crossings(v, rest, right, right, true)
				if (a > 0 or b > 0) and first == "":
					first = str(inst)
				lr += a
				self_x += b
			eq(lr, 0, "%s LOD%d: left and right wings never cross (first at %s)" % [sp, lod, first])
			eq(self_x, 0, "%s LOD%d: a wing never passes through itself (first at %s)" % [sp, lod, first])
			report["%s_lod%d" % [sp, lod]] = [lr, self_x]
	metric("crossings_lr_self", report)


## The whole pose space an owner and the smoothing can reach: fold and
## perch on a grid (the smoothing blends them at different rates, so every
## combination is drawn at some point), gliding and at five beat phases.
static func _space() -> Array[Vector4]:
	var out: Array[Vector4] = []
	for f in [0.0, 0.2, 0.35, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0]:
		for q in [0.0, 0.25, 0.5, 0.75, 0.85, 0.95, 1.0]:
			out.append(Vector4(0.25, 0.0, f, q))
			for ph in [0.1, 0.3, 0.5, 0.7, 0.85]:
				out.append(Vector4(ph, 1.0, f, q))
	return out


func test_wings_stay_outside_the_body() -> void:
	# Outer wing vertices (hand, and arm beyond 60% of the way to the wrist)
	# stay outside the body's ellipse cross-section anywhere in the pose
	# space; the wing root is meant to sit inside the body.
	var report := {}
	var space := _space()
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var worst := INF
		var at := ""
		for inst in space:
			var e := Geo.body_clearance(sp, arr, inst)
			if e < worst:
				worst = e
				at = str(inst)
		gt(worst, 0.98, "%s: outer wing never inside the body over %d poses (closest %.3f at %s)" % [sp, space.size(), worst, at])
		report[String(sp)] = snappedf(worst, 0.001)
	metric("closest_wing_to_body_ellipse", report)


func test_folded_wings_never_pass_through_the_tail() -> void:
	# Folding lays the wings along the back and, perched, their tips on top
	# of the tail: at no fold/perch blend may a wing pass through the tail
	# (the swallow's long wings over its streamers are the tight case).
	var report := {}
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := Geo.arrays(sp)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var wings := Geo.wing_tris(arr, 1.0)
		wings.append_array(Geo.wing_tris(arr, -1.0))
		var tail := Geo.tail_tris(arr)
		var r := Geo.rig(sp)
		var n := 0
		var first := ""
		for inst in _space():
			if inst.z < 0.35:
				continue
			var c := Geo.count_crossings(Geo.posed_subset(r, inst, r["wing_tail_idx"]), rest, wings, tail, false, 999)
			if c > 0 and first == "":
				first = str(inst)
			n += c
		eq(n, 0, "%s: wings never pass through the tail (first at %s)" % [sp, first])
		report[String(sp)] = n
	metric("wing_tail_crossings", report)


func test_perched_wingtips_rest_on_the_tail() -> void:
	# Perched, the folded wing lies along the back with its tips just above
	# the tail's upper edge in profile (not hanging under it, where the wing
	# would have to pass through the tail on the way down, and not raised off
	# it). The wren cocks its tail up above its wings.
	var report := {}
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := Geo.arrays(sp)
		var g := Geo.groups(arr)
		var sd := Geo.sides(arr)
		var v := Geo.posed(arr, Vector4(0.25, 0.0, 1.0, 1.0), true)
		var tip := -1
		var tz0 := INF
		var tz1 := -INF
		for i in v.size():
			if Geo.is_wing(g[i]) and sd[i] > 0.0 and (tip < 0 or v[i].z > v[tip].z):
				tip = i
			if g[i] == BirdPose.G_TAIL:
				tz0 = minf(tz0, v[i].z)
				tz1 = maxf(tz1, v[i].z)
		# The tail's upper edge in profile under the wingtip (or at its end).
		var z := clampf(v[tip].z, tz0 + 0.01, tz1 - 0.03)
		var top := -INF
		for t in Geo.tail_tris(arr):
			for k in 121:
				var hit: Variant = Geometry3D.ray_intersects_triangle(Vector3(-0.12 + k * 0.002, 10.0, z), Vector3.DOWN, v[t], v[t + 1], v[t + 2])
				if hit != null:
					top = maxf(top, (hit as Vector3).y)
		var above := v[tip].y - top
		report[String(sp)] = snappedf(above, 0.001)
		if sp == &"wren":
			var tail_top := -INF
			for i in v.size():
				if g[i] == BirdPose.G_TAIL:
					tail_top = maxf(tail_top, v[i].y)
			gt(tail_top - v[tip].y, 0.02, "wren: cocked tail stands above the folded wingtips")
		else:
			# 0.013-0.026 for most; the swallow's long hand lies highest over
			# its closed streamers (0.059): any more droop carries the
			# half-folded hand through them (see docs/areas/BIRDS.md).
			between(above, 0.0, 0.065, "%s: perched wingtips just above the tail's edge (%.3f span)" % [sp, above])
	metric("perched_wingtip_above_tail", report)


## Samples of a triangle (vertices, edges and inside) for the slab test.
static func _tri_pts(a: Vector3, b: Vector3, c: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 7:
		for j in 7 - i:
			var u := i / 6.0
			var w := j / 6.0
			out.append(a * (1.0 - u - w) + b * u + c * w)
	return out


## Largest sideways gap (span units) between a folded right wing's inner
## surface and the body's widest point, slab by slab along the body (24
## slabs; the round-2 verifier's measure): positive = a see-through gap
## from above or behind.
static func folded_wing_gap(arr: Array, inst: Vector4) -> float:
	var v := Geo.posed(arr, inst, true)
	var g := Geo.groups(arr)
	var sd := Geo.sides(arr)
	var z0 := INF
	var z1 := -INF
	for i in v.size():
		if g[i] == BirdPose.G_BODY:
			z0 = minf(z0, v[i].z)
			z1 = maxf(z1, v[i].z)
	var n := 24
	var dz := (z1 - z0) / n
	var body := PackedFloat32Array()
	var wing := PackedFloat32Array()
	body.resize(n)
	wing.resize(n)
	body.fill(-1.0)
	wing.fill(INF)
	for t in range(0, v.size(), 3):
		var is_body := g[t] == BirdPose.G_BODY
		if not is_body and not (Geo.is_wing(g[t]) and sd[t] > 0.0):
			continue
		for p in _tri_pts(v[t], v[t + 1], v[t + 2]):
			var k := int((p.z - z0) / dz)
			if k < 0 or k >= n:
				continue
			if is_body:
				body[k] = maxf(body[k], absf(p.x))
			else:
				wing[k] = minf(wing[k], p.x)
	var worst := -INF
	for k in n:
		if body[k] >= 0.0 and wing[k] < INF:
			worst = maxf(worst, wing[k] - body[k])
	return worst


func test_folded_wings_lie_on_the_body() -> void:
	# A folded wing lies on the upper flank and back and follows the body's
	# taper onto the rump (the fold hug): nowhere along the body may it stand
	# off sideways by more than 0.012 span, perched or in a dive tuck (LOD0,
	# the close-up model). (Before the hug: up to 0.088 perched, a blade
	# floating beside the body from above and from behind.) LOD1 has fewer
	# wing stations and is only drawn while the whole wingspan is under
	# LOD0_ANGLE x (1 + hysteresis) = 3.2 deg, 64 px on a Quest Pro: there
	# the gap must stay under 1.5 px.
	var lod1_limit := 1.5 / (rad_to_deg(BirdModel.LOD0_ANGLE * (1.0 + BirdModel.LOD_HYSTERESIS)) * 20.0)
	var report := {}
	var worst := [-INF, ""]
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var row := {}
		for lod in [0, 1]:
			var arr := Geo.arrays(sp, lod)
			var limit := 0.012 if lod == 0 else lod1_limit
			for k in [["perched", Vector4(0.25, 0.0, 1.0, 1.0)], ["dive", Vector4(0.25, 0.0, 1.0, 0.0)]]:
				var gap := folded_wing_gap(arr, k[1])
				lt(gap, limit, "%s LOD%d %s: folded wing on the body (largest gap %.3f span, limit %.3f)" % [sp, lod, k[0], gap, limit])
				row["%s_lod%d" % [k[0], lod]] = snappedf(gap, 0.001)
				if gap > worst[0]:
					worst = [gap, "%s %s LOD%d" % [sp, k[0], lod]]
		report[String(sp)] = row
	metric("folded_wing_gap_span", report)
	metric("folded_wing_gap_lod1_limit_span", snappedf(lod1_limit, 0.0001))
	metric("folded_wing_gap_worst", [snappedf(worst[0], 0.001), worst[1]])


## The folded right wing's outer outline, seen from above and behind (the
## round-3 verifier's measures, adopted): {beyond: how far it stands out past
## the body's widest point anywhere; behind: how far it flares out beside
## the tail behind the rump (per slab, past the tail's own half-width);
## fan: how far the hand's tip vertices (rest x >= 0.46) spread ACROSS the
## wing's axis (primaries stacked may be staggered along it, fanned ones
## spread across it, like a comb); fan_glide: the same spread wings}.
static func folded_outline(arr: Array, inst: Vector4) -> Dictionary:
	var g := Geo.groups(arr)
	var sd := Geo.sides(arr)
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var v := BirdPose.pose_arrays(arr, inst, 0.0, 0.0, true)
	var slabs := 40
	var zmin := INF
	var zmax := -INF
	for i in v.size():
		if g[i] == BirdPose.G_BODY or g[i] == BirdPose.G_TAIL or (Geo.is_wing(g[i]) and sd[i] > 0.0):
			zmin = minf(zmin, v[i].z)
			zmax = maxf(zmax, v[i].z)
	var dz := (zmax - zmin) / slabs
	var own := PackedFloat32Array()
	var wing := PackedFloat32Array()
	own.resize(slabs)
	wing.resize(slabs)
	own.fill(0.0)
	wing.fill(-INF)
	var body_w := 0.0
	var body_zmax := -INF
	for t in range(0, v.size(), 3):
		var own_part := g[t] == BirdPose.G_BODY or g[t] == BirdPose.G_TAIL
		var rw := Geo.is_wing(g[t]) and sd[t] > 0.0
		if not own_part and not rw:
			continue
		for p in _tri_pts(v[t], v[t + 1], v[t + 2]):
			var k := clampi(int((p.z - zmin) / dz), 0, slabs - 1)
			if own_part:
				own[k] = maxf(own[k], absf(p.x))
				if g[t] == BirdPose.G_BODY:
					body_w = maxf(body_w, absf(p.x))
					body_zmax = maxf(body_zmax, p.z)
			else:
				wing[k] = maxf(wing[k], p.x)
	var beyond := -INF
	var behind := -INF
	for k in slabs:
		beyond = maxf(beyond, wing[k] - body_w)
		if zmin + (k + 0.5) * dz > body_zmax and wing[k] > -INF:
			behind = maxf(behind, wing[k] - own[k])
	var vg := BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, 0.0, 0.0), 0.0, 0.0, true)
	var tips := []
	var tips_g := []
	var all := []
	var all_g := []
	for i in v.size():
		if Geo.is_wing(g[i]) and sd[i] > 0.0:
			all.append(v[i])
			all_g.append(vg[i])
			if g[i] == BirdPose.G_HAND and rest[i].x >= 0.46:
				tips.append(v[i])
				tips_g.append(vg[i])
	return {"beyond": beyond, "behind": behind, "fan": _across(tips, all), "fan_glide": _across(tips_g, all_g)}


static func _mean(pts: Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / maxf(pts.size(), 1)


## Largest distance between two tip points once their component along the
## wing's axis (wing centroid -> tips centroid) is removed.
static func _across(tips: Array, wing: Array) -> float:
	if tips.size() < 2:
		return 0.0
	var axis := (_mean(tips) - _mean(wing)).normalized()
	var best := 0.0
	for i in tips.size():
		for j in range(i + 1, tips.size()):
			var d: Vector3 = tips[i] - tips[j]
			d -= axis * d.dot(axis)
			best = maxf(best, d.length())
	return best


func test_folded_wings_keep_inside_the_outline() -> void:
	# Folded, a wing lies on the flank: its outer surface stands beyond the
	# body's widest point by at most its thickness plus the fold's outward
	# offset (0.03 span); behind the rump the folded hand runs along the
	# tail, not flared out beside it (0.03 span; the wren's tail is cocked up
	# out of that plane, so its wingtips are measured against its body's
	# width instead); and the slotted primaries of a crow, hawk or eagle lie
	# stacked, spread at most 0.04 span across the wing (8 cm on a 2.1 m
	# eagle) - fanned wider they read as a comb at the rump (round-3
	# verifier: 0.059-0.079, a third of the spread wing's fan).
	var report := {}
	var worst := {"beyond": [-INF, ""], "behind": [-INF, ""], "fan": [0.0, ""]}
	for sp: StringName in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := Geo.arrays(sp)
		for k in [["perched", Vector4(0.25, 0.0, 1.0, 1.0)], ["dive", Vector4(0.25, 0.0, 1.0, 0.0)]]:
			var r := folded_outline(arr, k[1])
			var where := "%s %s" % [sp, k[0]]
			report[where] = {"beyond": snappedf(r["beyond"], 0.001), "behind": snappedf(r["behind"], 0.001),
				"fan": snappedf(r["fan"], 0.001), "fan_glide": snappedf(r["fan_glide"], 0.001)}
			lt(r["beyond"], 0.03, "%s: folded wing within 0.03 span of the body's widest point (%.3f)" % [where, r["beyond"]])
			if sp != &"wren":
				lt(r["behind"], 0.03, "%s: folded hand not flared beside the tail (%.3f)" % [where, r["behind"]])
			if sp in [&"crow", &"hawk", &"eagle"]:
				lt(r["fan"], 0.04, "%s: folded primaries stacked (spread %.3f across, glide %.3f)" % [where, r["fan"], r["fan_glide"]])
			for key in worst:
				if float(r[key]) > float(worst[key][0]) and (key != "fan" or sp in [&"crow", &"hawk", &"eagle"]) and (key != "behind" or sp != &"wren"):
					worst[key] = [snappedf(r[key], 0.001), where]
	metric("folded_outline", report)
	metric("folded_outline_worst", worst)


## Owner field settings before (step 0) and after (step 1) a transition.
static func _transition(m: BirdModel, kind: String, step: int) -> void:
	match kind + str(step):
		"land0", "dive0", "half_tuck0":
			m.flap_amount = 1.0
		"land1":
			m.perched = true
			m.wing_fold = 1.0
			m.flap_amount = 0.0
		"takeoff0":
			m.perched = true
			m.wing_fold = 1.0
		"takeoff1":
			m.perched = false
			m.wing_fold = 0.0
			m.flap_amount = 1.0
		"dive1":
			m.wing_fold = 1.0
			m.flap_amount = 0.0
		"pullout0":
			m.wing_fold = 1.0
		"pullout1":
			m.wing_fold = 0.0
			m.flap_amount = 1.0
		"half_tuck1":
			m.wing_fold = 0.5
		"perch_flap0":
			m.perched = true
			m.wing_fold = 1.0
		"perch_flap1":
			# A perched bird flapping to keep its balance.
			m.wing_fold = 0.4
			m.flap_amount = 1.0


func test_drawn_transitions_are_clean() -> void:
	# What is actually drawn between two owner states is a blend with a
	# different time constant per field. Drive real models through landing,
	# take-off, dive, pull-out, a half tuck and a perched balance flap (a
	# 9 Hz beat, 72 Hz frames) and check every other drawn frame: no wing
	# crossing (left/right or itself), no wing through the tail or the body,
	# no inverted face.
	var kinds := ["land", "takeoff", "dive", "pullout", "half_tuck", "perch_flap"]
	var report := {}
	var total := 0
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var right := Geo.wing_tris(arr, 1.0)
		var left := Geo.wing_tris(arr, -1.0)
		var wings := right.duplicate()
		wings.append_array(left)
		var tail := Geo.tail_tris(arr)
		var r := Geo.rig(sp)
		var row := {}
		for kind in kinds:
			var m := BirdModels.create(sp)
			add_child(m)
			_transition(m, kind, 0)
			m.snap()
			BirdBatch.sync_all(DT)
			_transition(m, kind, 1)
			var bad := 0
			var worst_e := INF
			var first := ""
			for f in 36:
				m.flap_phase = fposmod(m.flap_phase + DT * 9.0, 1.0)
				BirdBatch.sync_all(DT)
				if f % 2 == 1:
					continue
				var inst := m.displayed_pose()
				var v := Geo.posed_subset(r, inst, r["wing_tail_idx"])
				var n := Geo.count_crossings(v, rest, right, left, false) + Geo.count_crossings(v, rest, right, right, true)
				if not tail.is_empty():
					n += Geo.count_crossings(v, rest, wings, tail, false)
				n += Geo.inverted_count(arr, inst)
				var e := Geo.body_clearance(sp, arr, inst)
				worst_e = minf(worst_e, e)
				if e < 0.98:
					n += 1
				if n > 0 and first == "":
					first = "frame %d %s" % [f, str(inst)]
				bad += n
			m.free()
			eq(bad, 0, "%s %s: every drawn frame clean (first bad %s)" % [sp, kind, first])
			row[kind] = snappedf(worst_e, 0.001)
			total += bad
		report[String(sp)] = row
	metric("drawn_transitions_closest_body", report)
	metric("drawn_transition_defects", total)


func _extent(v: PackedVector3Array, g: PackedInt32Array) -> AABB:
	var b := AABB()
	var first := true
	for i in v.size():
		if not Geo.is_wing(g[i]):
			continue
		if first:
			b = AABB(v[i], Vector3.ZERO)
			first = false
		else:
			b = b.expand(v[i])
	return b


func test_tuck_and_perch_poses() -> void:
	var report := {}
	var heads := {}
	for sp in BirdSpecies.IDS:
		var arr := Geo.arrays(sp)
		var g := Geo.groups(arr)
		var body := BirdModels.body_aabb(sp)
		var glide := _extent(Geo.posed(arr, Vector4(0.25, 0.0, 0.0, 0.0)), g)
		var half := _extent(Geo.posed(arr, Vector4(0.25, 0.0, 0.5, 0.0)), g)
		var tuck := _extent(Geo.posed(arr, Vector4(0.25, 0.0, 1.0, 0.0)), g)
		var perch := _extent(Geo.posed(arr, Vector4(0.25, 0.0, 1.0, 1.0)), g)
		near(glide.size.x, 1.0, 0.001, "%s glide spans 1" % sp)
		if sp == &"moth":
			# A moth rests with its wings in a low delta roof over its body,
			# 40-55% of its span wide (noctuid moths), not tucked.
			between(half.size.x, 0.6, 0.92, "moth half fold: swept back")
			between(perch.size.x, 0.4, 0.6, "moth at rest: delta 40-60% of span")
		else:
			between(half.size.x, 0.35, 0.85, "%s half tuck: swept, narrower" % sp)
			lt(tuck.size.x, body.size.x * 2.6, "%s full tuck: wings within ~body width" % sp)
			# Folded wings sit on the flanks: body + two wing layers + the
			# outward offset. 2.3x admits the slimmest body (gull, 0.089
			# span) with its long folded hand (see docs/areas/BIRDS.md).
			lt(perch.size.x, body.size.x * 2.3, "%s perched: wings folded on the body" % sp)
		gt(tuck.end.z, glide.end.z, "%s tuck: wingtips swept behind" % sp)
		gt(perch.end.z, 0.1, "%s perched: wingtips reach back over the tail" % sp)
		report[String(sp)] = {"half_x": snappedf(half.size.x, 0.001), "tuck_x": snappedf(tuck.size.x, 0.001),
			"perch_x": snappedf(perch.size.x, 0.001), "body_x": snappedf(body.size.x, 0.001)}
		if sp == &"moth":
			continue
		# Perched: body nose-up, head kept level (the head counter-pitches by
		# the body's pitch, so the bill points as it does in flight: its
		# elevation is the glide pose's, within 3 deg; without the counter-
		# pitch it would tilt up by the 10-22 deg body pitch), tail below the
		# back. Idle glances (a turn about the vertical) are held still here;
		# they would not change the elevation anyway.
		BirdPose.head_look_amount = 0.0
		var v := Geo.posed(arr, Vector4(0.25, 0.0, 1.0, 1.0))
		var v0 := Geo.posed(arr, Vector4(0.25, 0.0, 0.0, 0.0))
		BirdPose.head_look_amount = 1.0
		var beak := 0
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			if rest[i].z < rest[beak].z:
				beak = i
		var head_c := Vector3.ZERO
		var head_c0 := Vector3.ZERO
		var hn := 0
		for i in v.size():
			if g[i] == BirdPose.G_HEAD:
				head_c += v[i]
				head_c0 += v0[i]
				hn += 1
		head_c /= hn
		head_c0 /= hn
		var d := v[beak] - head_c
		var d0 := v0[beak] - head_c0
		var elev := rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length()))
		var elev0 := rad_to_deg(atan2(d0.y, Vector2(d0.x, d0.z).length()))
		near(elev, elev0, 3.0, "%s perched: bill points as in flight (elevation %.1f deg, glide %.1f deg)" % [sp, elev, elev0])
		gt(head_c.y, 0.02, "%s perched: head up (body pitched nose-up)" % sp)
		heads[String(sp)] = [snappedf(elev, 0.1), snappedf(elev0, 0.1)]
	metric("fold_extents", report)
	metric("perched_bill_elevation_deg_vs_glide", heads)
	# Perched tails: the wren cocks its tail up, everyone else lets it hang.
	var angles := {}
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var wa := Geo.arrays(sp)
		var wg := Geo.groups(wa)
		var c1: PackedFloat32Array = wa[Mesh.ARRAY_CUSTOM1]
		var wv := Geo.posed(wa, Vector4(0.25, 0.0, 1.0, 1.0))
		var far := -1
		var base := Vector3.ZERO
		for i in wv.size():
			if wg[i] == BirdPose.G_TAIL:
				base = BirdPose.rx(Vector3(c1[i * 4], c1[i * 4 + 1], c1[i * 4 + 2]), BirdSpecies.data(sp)["anim"][3] * BirdPose.DEG)
				if far < 0 or wv[i].distance_to(base) > wv[far].distance_to(base):
					far = i
		var dv := wv[far] - base
		var ang := rad_to_deg(atan2(dv.y, dv.z))
		angles[String(sp)] = snappedf(ang, 0.1)
		if sp == &"wren":
			gt(ang, 40.0, "wren perched: tail cocked up (deg above horizontal)")
		else:
			lt(ang, 5.0, "%s perched: tail hangs level or down" % sp)
	metric("perched_tail_angle_deg", angles)


func test_body_bobs_subtly_with_the_beat() -> void:
	for sp in [&"sparrow", &"eagle"]:
		var arr := Geo.arrays(sp)
		var g := Geo.groups(arr)
		var hi := -INF
		var lo := INF
		for i in 24:
			var v := Geo.posed(arr, Vector4(i / 24.0, 1.0, 0.0, 0.0))
			var y := 0.0
			var n := 0
			for k in v.size():
				if g[k] == BirdPose.G_BODY:
					y += v[k].y
					n += 1
			y /= n
			hi = maxf(hi, y)
			lo = minf(lo, y)
		between(hi - lo, 0.01, 0.04, "%s: body bob is visible but subtle (span units)" % sp)


## A model in the tree, driven like an owner would, synced at 72 Hz.
func _model(sp: StringName) -> BirdModel:
	var m := BirdModels.create(sp)
	add_child(m)
	BirdBatch.sync_all(DT)
	return m


## Tip positions per frame: 3 frames settled, then `change`, then `frames`.
func _tip_path(m: BirdModel, frames: int, change: Callable) -> PackedVector3Array:
	var out := PackedVector3Array()
	for f in 3:
		BirdBatch.sync_all(DT)
	out.append(m.get_wingtip(1))
	change.call()
	for f in frames:
		BirdBatch.sync_all(DT)
		out.append(m.get_wingtip(1))
	return out


func test_bank_rolls_right_wing_down() -> void:
	var m := _model(&"hawk")
	m.bank = 0.5
	for f in 60:
		BirdBatch.sync_all(DT)
	near(m.displayed_bank(), 0.5, 1e-3, "bank settles")
	var r := m.get_wingtip(1)
	var l := m.get_wingtip(-1)
	lt(r.y, l.y, "positive bank: right wing down")
	near(atan2(l.y - r.y, r.x - l.x), 0.5, 0.03, "roll angle equals bank")
	m.bank = -0.5
	for f in 60:
		BirdBatch.sync_all(DT)
	gt(m.get_wingtip(1).y, m.get_wingtip(-1).y, "negative bank: left wing down")
	m.free()


func test_no_pops_when_fields_change() -> void:
	# A pop is a transition that happens in one frame. Unsmoothed, each of
	# these switches would move the wingtip its whole way at once; the model
	# must spread it over several frames: no frame may cover more than 25% of
	# the way, and the tip must arrive (within 2%) in under 0.6 s.
	var report := {}
	var m := _model(&"eagle")
	# NpcBird folds the wings as it perches, so the two switch together.
	var perch_on := func() -> void:
		m.perched = true
		m.wing_fold = 1.0
	var perch_off := func() -> void:
		m.perched = false
		m.wing_fold = 0.0
	var cases := {
		"flap_amount 0->1": [func() -> void: m.flap_amount = 0.0, func() -> void: m.flap_amount = 1.0],
		"flap_amount 1->0": [func() -> void: m.flap_amount = 1.0, func() -> void: m.flap_amount = 0.0],
		"wing_fold 0->1": [func() -> void: m.wing_fold = 0.0, func() -> void: m.wing_fold = 1.0],
		"wing_fold 1->0": [func() -> void: m.wing_fold = 1.0, func() -> void: m.wing_fold = 0.0],
		"perched on": [func() -> void: m.perched = false, perch_on],
		"perched off": [perch_on, perch_off],
		"bank 0->0.8": [func() -> void: m.bank = 0.0, func() -> void: m.bank = 0.8],
		"phase jump +0.45": [func() -> void: m.flap_amount = 1.0, func() -> void: m.flap_phase = 0.65],
	}
	for k in cases:
		m.flap_amount = 0.0
		m.wing_fold = 0.0
		m.perched = false
		m.bank = 0.0
		m.flap_phase = 0.2
		cases[k][0].call()
		m.snap()
		var path := _tip_path(m, 45, cases[k][1])
		var total := path[0].distance_to(path[path.size() - 1])
		var worst := 0.0
		var arrive := -1
		for i in range(1, path.size()):
			worst = maxf(worst, path[i].distance_to(path[i - 1]))
			if arrive < 0 and path[i].distance_to(path[path.size() - 1]) <= 0.02 * total:
				arrive = i
		gt(total, 0.05, "%s: the switch moves the tip (%.3f)" % [k, total])
		lt(worst, 0.25 * total, "%s: largest frame step %.1f%% of the way" % [k, 100.0 * worst / maxf(total, 1e-6)])
		between(arrive, 4, 43, "%s: arrives in 4..43 frames (%d)" % [k, arrive])
		report[k] = {"way": snappedf(total, 0.001), "max_step_pct": snappedf(100.0 * worst / maxf(total, 1e-6), 0.1), "frames": arrive}
	metric("transitions", report)
	# A steady beat is shown exactly (no smoothing lag on the phase).
	m.flap_amount = 1.0
	m.snap()
	var lag := 0.0
	for f in 72:
		m.flap_phase = fposmod(f * DT * 4.0, 1.0)
		BirdBatch.sync_all(DT)
		if f > 10:
			lag = maxf(lag, absf(wrapf(m.displayed_pose().x - m.flap_phase, -0.5, 0.5)))
	lt(lag, 1e-4, "steady 4 Hz beat drawn without phase lag")
	# Highlight fades rather than switching.
	m.highlight = 0
	m.snap()
	BirdBatch.sync_all(DT)
	m.highlight = 2
	BirdBatch.sync_all(DT)
	var d1 := m.displayed_highlight().y
	between(d1, 0.05, 0.25, "danger highlight fades in (first frame)")
	for f in 30:
		BirdBatch.sync_all(DT)
	gt(m.displayed_highlight().y, 0.98, "danger highlight fully on after ~0.4 s")
	m.free()


func test_drawn_phase_never_runs_backwards() -> void:
	# Owners advance flap_phase forwards. A fast beat starting from rest, or
	# a long frame (a 50 ms hitch at 16 Hz is 0.8 of a beat, which looks like
	# -0.2), must never play the wings backwards: the hitch frame follows the
	# owner's real step, and every other frame steps forwards by less than
	# half a beat (a bigger step reads as backwards to the eye). The drawn
	# beat must also catch up with the owner's quickly.
	var m := _model(&"wren")
	var report := {}
	for fps: float in [72.0, 90.0, 120.0]:
		for hz: float in [4.0, 8.0, 12.0, 16.1]:
			m.flap_amount = 1.0
			m.flap_phase = 0.3
			m.snap()
			var dt := 1.0 / fps
			BirdBatch.sync_all(dt)
			var back := 0
			var hitch_err := 0.0
			var worst_lag := 0.0
			var phase := 0.3
			var prev := m.displayed_pose().x
			var frames := int(fps * 1.2)
			var hitch := int(fps * 0.6)
			for f in frames:
				var step: float = 0.05 if f == hitch else dt
				phase = fposmod(phase + hz * step, 1.0)
				m.flap_phase = phase
				BirdBatch.sync_all(step)
				var shown := m.displayed_pose().x
				var d := fposmod(shown - prev, 1.0)
				if f == hitch:
					# The display moved by the owner's own step this frame.
					hitch_err = absf(wrapf(d - fposmod(hz * step, 1.0), -0.5, 0.5))
				elif d > 0.5:
					back += 1
				prev = shown
				# Caught up: 0.15 s after the start and after the hitch.
				var settled := (f > int(fps * 0.15) and f < hitch) or f > hitch + int(fps * 0.15)
				if settled:
					worst_lag = maxf(worst_lag, absf(wrapf(shown - phase, -0.5, 0.5)))
			eq(back, 0, "%d fps, %.1f Hz: the drawn beat never steps backwards" % [fps, hz])
			lt(hitch_err, 0.01, "%d fps, %.1f Hz: a 50 ms hitch is drawn as the owner's step (off %.3f)" % [fps, hz, hitch_err])
			lt(worst_lag, 0.01, "%d fps, %.1f Hz: drawn beat caught up within 0.15 s (lag %.3f)" % [fps, hz, worst_lag])
			report["%d_fps_%.1f_hz" % [fps, hz]] = snappedf(worst_lag, 0.0001)
	metric("phase_lag_after_start_and_hitch", report)
	m.free()
