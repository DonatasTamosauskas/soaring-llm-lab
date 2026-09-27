extends TestCase
## Round-3 verifier probes (birds, experience & requirements lens). Written by
## the verifier, not the builder. Uses only the birds area's meshes and
## BirdPose (proven equal to the shader by the area's GPU check), plus the
## area's own rasteriser helpers for silhouettes.
##
##   tools/gd.sh birds_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/birds --suite=birds_r3_experience
##
## 1. B1 in the poses players see most: perched and dive-tucked silhouettes
##    (B1's own test only checks the glide pose and the beat's ends).
## 2. The folded wing's OUTER edge: round 2 pinned the gap on the inside
##    (wing to body); nothing pins fingers/primaries splaying outwards or
##    fanning when the wing is folded (visible as a comb in perched_close.png).
## 3. Colour identity of highlighted birds: GameLoop highlights every
##    worthwhile prey and every threat within 70 player spans, so in play the
##    birds that matter are seen tinted. Does B1's "distinct colouring"
##    survive the tint at the angular sizes they have in that range?
## 4. Long run: a 20-minute session at 72 Hz of 60 birds flying, perching,
##    changing highlight, LOD and species; the batch bookkeeping, buffers and
##    timing must hold to the end.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const MAX_IOU := 0.85
const MIN_DE := 0.05
const PERCHED := Vector4(0.25, 0.0, 1.0, 1.0)
const DIVE := Vector4(0.25, 0.0, 1.0, 0.0)
const GLIDE := Vector4(0.25, 0.0, 0.0, 0.0)


func test_r3_resting_silhouettes_differ() -> void:
	var poses := {"perched": PERCHED, "dive_tuck": DIVE, "half_tuck": Vector4(0.25, 0.0, 0.5, 0.0)}
	var views := {"perched": ["side", "top", "front"], "dive_tuck": ["top", "side"], "half_tuck": ["top", "side"]}
	var out := {}
	for pname: String in poses:
		var sil := {}
		for sp: StringName in BirdSpecies.IDS:
			var v := BirdPose.pose_arrays(Geo.arrays(sp), poses[pname])
			var d := {}
			for view: String in views[pname]:
				d[view] = Geo.silhouette(v, view)
			sil[sp] = d
		for view: String in views[pname]:
			var worst := [0.0, ""]
			var over := []
			var ids := BirdSpecies.IDS
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var u := Geo.iou(sil[ids[i]][view], sil[ids[j]][view])
					if u > worst[0]:
						worst = [u, "%s/%s" % [ids[i], ids[j]]]
					if u >= MAX_IOU:
						over.append("%s/%s %.3f" % [ids[i], ids[j], u])
			out["%s_%s" % [pname, view]] = {"worst": snappedf(worst[0], 0.001), "pair": worst[1], "pairs_at_or_over_0.85": over}
			print("[birds-r3] %-10s %-5s worst IoU %.3f (%s), %d pairs >= 0.85" % [pname, view, worst[0], worst[1], over.size()])
			# Front view is informative only (B1 reports it, does not gate it).
			if view != "front":
				lt(worst[0], MAX_IOU, "%s %s-view silhouettes differ pairwise (worst %s)" % [pname, view, worst[1]])
	metric("resting_iou", out)


## Points on a triangle (corners, edges, interior) for slab sampling.
static func _samples(a: Vector3, b: Vector3, c: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var n := 5
	for i in n + 1:
		for j in n + 1 - i:
			var u := float(i) / n
			var w := float(j) / n
			out.append(a * (1.0 - u - w) + b * u + c * w)
	return out


## How far a folded right wing reaches outside the bird's own outline seen
## from above/behind: per slab along z, the wing's outermost x minus the
## widest of the body and the tail in that slab; and the wing's outermost x
## beyond the body's widest point anywhere. Also how fanned the primaries
## are: the spread of the outer hand's tip vertices (rest x >= 0.46) in the
## folded pose, against the same in the glide pose.
func _outline(sp: StringName, inst: Vector4) -> Dictionary:
	var arr := Geo.arrays(sp)
	var g := Geo.groups(arr)
	var sd := Geo.sides(arr)
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var v := BirdPose.pose_arrays(arr, inst, 0.0, 0.0, true)
	var slabs := 40
	var zmin := INF
	var zmax := -INF
	for i in v.size():
		if g[i] == BirdPose.G_BODY or g[i] == BirdPose.G_TAIL or ((g[i] == BirdPose.G_ARM or g[i] == BirdPose.G_HAND) and sd[i] > 0.0):
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
		var grp := g[t]
		var is_own := grp == BirdPose.G_BODY or grp == BirdPose.G_TAIL
		var is_rw := (grp == BirdPose.G_ARM or grp == BirdPose.G_HAND) and sd[t] > 0.0
		if not is_own and not is_rw:
			continue
		for p in _samples(v[t], v[t + 1], v[t + 2]):
			var k := clampi(int((p.z - zmin) / dz), 0, slabs - 1)
			if is_own:
				own[k] = maxf(own[k], absf(p.x))
				if grp == BirdPose.G_BODY:
					body_w = maxf(body_w, absf(p.x))
					body_zmax = maxf(body_zmax, p.z)
			else:
				wing[k] = maxf(wing[k], p.x)
	var local := -INF
	var local_at := 0.0
	for k in slabs:
		if wing[k] > -INF and wing[k] - own[k] > local:
			local = wing[k] - own[k]
			local_at = (k + 0.5) / slabs
	var beyond := -INF
	var behind := -INF
	for k in slabs:
		beyond = maxf(beyond, wing[k] - body_w)
		# Behind the rump the outline is the tail's: a folded hand flaring out
		# beside it reads as whiskers from above and behind.
		if zmin + (k + 0.5) * dz > body_zmax and wing[k] > -INF:
			behind = maxf(behind, wing[k] - own[k])
	# Fingertip fan: tip vertices of the right hand, spread ACROSS the wing's
	# long axis (primaries folded in a stack may be staggered along the axis;
	# fanned ones spread across it, like a comb).
	var tips := []
	var tips_glide := []
	var wing_all := []
	var wing_all_glide := []
	var vg := BirdPose.pose_arrays(arr, GLIDE, 0.0, 0.0, true)
	for i in v.size():
		if (g[i] == BirdPose.G_ARM or g[i] == BirdPose.G_HAND) and sd[i] > 0.0:
			wing_all.append(v[i])
			wing_all_glide.append(vg[i])
			if g[i] == BirdPose.G_HAND and rest[i].x >= 0.46:
				tips.append(v[i])
				tips_glide.append(vg[i])
	return {"out_of_outline": local, "out_of_outline_at_length": local_at, "beyond_widest_body": beyond, "behind_rump": behind,
		"body_half_width": body_w, "tip_fan": _across(tips, wing_all), "tip_fan_glide": _across(tips_glide, wing_all_glide)}


static func _centroid(pts: Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / maxf(pts.size(), 1)


## Largest distance between two tip points once their component along the
## wing's axis (wing centroid -> tips centroid) is removed.
static func _across(tips: Array, wing: Array) -> float:
	if tips.size() < 2:
		return 0.0
	var tc := _centroid(tips)
	var axis := (tc - _centroid(wing)).normalized()
	var best := 0.0
	for i in tips.size():
		for j in range(i + 1, tips.size()):
			var d: Vector3 = tips[i] - tips[j]
			d -= axis * d.dot(axis)
			best = maxf(best, d.length())
	return best


func test_r3_folded_wing_stays_inside_the_outline() -> void:
	var res := {}
	var worst := [-INF, ""]
	var worst_behind := [-INF, ""]
	var worst_fan := [0.0, ""]
	for sp: StringName in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		for pname in ["perched", "dive_tuck"]:
			var r := _outline(sp, PERCHED if pname == "perched" else DIVE)
			var fan_ratio: float = r["tip_fan"] / maxf(r["tip_fan_glide"], 1e-4)
			res["%s_%s" % [sp, pname]] = {
				"beyond_widest_body": snappedf(r["beyond_widest_body"], 0.001), "behind_rump_beside_tail": snappedf(r["behind_rump"], 0.001),
				"body_half_width": snappedf(r["body_half_width"], 0.001),
				"local_outline_incl_wrist_at_shoulder": snappedf(r["out_of_outline"], 0.001),
				"tip_fan": snappedf(r["tip_fan"], 0.001), "tip_fan_glide": snappedf(r["tip_fan_glide"], 0.001), "fan_kept": snappedf(fan_ratio, 0.01)}
			print("[birds-r3] %-8s %-9s folded wing beyond widest body %.3f (half-width %.3f), beside the tail behind the rump %.3f; tip fan across the axis %.3f folded vs %.3f glide (%.0f%%)" % [
				sp, pname, r["beyond_widest_body"], r["body_half_width"], r["behind_rump"], r["tip_fan"], r["tip_fan_glide"], fan_ratio * 100.0])
			if r["beyond_widest_body"] > worst[0]:
				worst = [r["beyond_widest_body"], "%s %s" % [sp, pname]]
			if r["behind_rump"] > worst_behind[0]:
				worst_behind = [r["behind_rump"], "%s %s" % [sp, pname]]
			# Fan: only fingered wings (crow, hawk, eagle); on a rounded wing
			# the tip vertices span the tip's own chord, not a fan.
			if pname == "perched" and sp in [&"crow", &"hawk", &"eagle"] and r["tip_fan"] > worst_fan[0]:
				worst_fan = [r["tip_fan"], String(sp)]
	metric("folded_outline", res)
	metric("worst_beyond_widest_body", [snappedf(worst[0], 0.001), worst[1]])
	metric("worst_beside_tail_behind_rump", [snappedf(worst_behind[0], 0.001), worst_behind[1]])
	metric("worst_perched_finger_fan", [snappedf(worst_fan[0], 0.001), worst_fan[1]])
	# A folded wing lies on the flank: its outer surface may stand beyond the
	# body's widest point by the wing's thickness plus the model's own outward
	# offset (FOLD_OUT 0.016), not more: 0.03 span (3 cm on a 1 m bird). The
	# folded wrist at the shoulder IS the widest point of a perched bird seen
	# from above, so the local outline at the shoulder is reported, not gated.
	lt(worst[0], 0.03, "folded wings stay within 0.03 span of the body's widest point (worst %s)" % worst[1])
	lt(worst_behind[0], 0.03, "folded hands do not flare out beside the tail behind the rump (worst %s)" % worst_behind[1])
	# Folded primaries lie stacked: the fingertips of a folded crow, hawk or
	# eagle wing within 0.04 span of each other ACROSS the wing's axis (8 cm on
	# a 2.1 m eagle, a stack of primaries a few feathers thick, generously).
	# Spread wider than that they read as a comb or broom at the rump
	# (artifacts/birds/perched_close.png, eagle side and 3/4).
	lt(worst_fan[0], 0.04, "perched fingered primaries are gathered (worst %s)" % worst_fan[1])


# --- 3. colour identity under the highlight -------------------------------

const EDIBLE := Color(0.25098, 0.12549, 0.941176)
const DANGER := Color(1.0, 0.0, 0.784314)


static func _lin(c: Color) -> Vector3:
	var o := Vector3.ZERO
	for i in 3:
		var x: float = c[i]
		o[i] = x / 12.92 if x <= 0.04045 else pow((x + 0.055) / 1.055, 2.4)
	return o


## The shader's fragment for a face of sRGB colour `c` at highlight weight
## hl in state `hue`, for a bird whose wingspan covers `ang` radians of view:
## lit albedo (sun-lit face, light 1.0) plus emission, pulse at its dimmest.
## Mirrors bird.gdshader's fragment (near_tint_from 0.12, near_tint_at 0.25,
## near_tint 0.45, highlight_mix 0.9, highlight_albedo 0.25, highlight_glow
## 1.3, near_dye 0.85, dye 0.15..0.6); the rim term is left out (it only adds
## hue at edge-on faces, which makes species more alike, not less).
static func _shade(c: Color, hl: float, hue: Vector3, ang: float) -> Vector3:
	var tint := lerpf(1.0, 0.45, clampf((ang - 0.12) / (0.25 - 0.12), 0.0, 1.0))
	var plum := _lin(c)
	var lum := plum.dot(Vector3(0.2126, 0.7152, 0.0722))
	var pale := smoothstep(0.15, 0.6, lum)
	var hmax := maxf(hue.x, maxf(hue.y, hue.z))
	var dye := Vector3.ONE.lerp(hue / hmax, hl * 0.85 * pale)
	var k := hl * tint
	var albedo := (plum * dye).lerp(hue * 0.25, k * 0.9)
	var glow := clampf((tint - 0.45) / (1.0 - 0.45), 0.0, 1.0)
	var pulse := 0.6
	return albedo + hue * (hl * pulse) * glow * 1.3


## Mean colour of a bird's top view under the shader's highlight maths.
func _signature(sp: StringName, hl: float, hue: Vector3, ang: float) -> Vector3:
	var arr := Geo.arrays(sp)
	var v := BirdPose.pose_arrays(arr, GLIDE)
	var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var shaded := PackedColorArray()
	shaded.resize(cols.size())
	for i in cols.size():
		var s := _shade(cols[i], hl, hue, ang)
		# view_color linearises: hand it an sRGB colour of the shaded result.
		shaded[i] = Color(s.x, s.y, s.z).linear_to_srgb()
	return Geo.oklab(Geo.view_color(v, shaded, "top"))


func test_r3_highlighted_species_keep_their_colouring() -> void:
	var ids := BirdSpecies.IDS
	var res := {}
	var edible := _lin(EDIBLE)
	# Angular sizes (wingspan across) a highlighted bird has in GameLoop's
	# range (70 player spans): a sparrow player's pigeon at 16 m is 2.4 deg, a
	# crow 3.4 deg, a hawk 5.7 deg; 10 deg is a bird a few spans away.
	for deg in [3.0, 10.0, 20.0]:
		var ang := deg_to_rad(deg)
		var sig := {}
		for sp: StringName in ids:
			sig[sp] = _signature(sp, 1.0, edible, ang)
		var plain := {}
		for sp: StringName in ids:
			plain[sp] = _signature(sp, 0.0, edible, ang)
		var close := 0
		var worst := [INF, ""]
		var plain_worst := [INF, ""]
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var d: float = (sig[ids[i]] as Vector3).distance_to(sig[ids[j]])
				var dp: float = (plain[ids[i]] as Vector3).distance_to(plain[ids[j]])
				if d < MIN_DE:
					close += 1
				if d < worst[0]:
					worst = [d, "%s/%s" % [ids[i], ids[j]]]
				if dp < plain_worst[0]:
					plain_worst = [dp, "%s/%s" % [ids[i], ids[j]]]
		res["%d_deg" % int(deg)] = {"pairs_closer_than_0.05": close, "of": 45, "closest": snappedf(worst[0], 0.001),
			"closest_pair": worst[1], "unhighlighted_closest_top_view": snappedf(plain_worst[0], 0.001)}
		print("[birds-r3] edible at %4.1f deg: %d/45 species pairs closer than Oklab 0.05 (closest %.3f %s); unhighlighted top-view closest %.3f %s" % [
			deg, close, worst[0], worst[1], plain_worst[0], plain_worst[1]])
	metric("highlighted_colour_identity", res)
	# B1's bar (every pair > 0.05 apart), applied where the player sees the
	# birds that matter: tinted. Shape still differs (B1 IoU), colour should too.
	eq(res["3_deg"]["pairs_closer_than_0.05"], 0, "edible birds at 3 deg keep distinct colouring (pairs closer than 0.05)")
	eq(res["10_deg"]["pairs_closer_than_0.05"], 0, "edible birds at 10 deg keep distinct colouring (pairs closer than 0.05)")


# --- 4. long run -----------------------------------------------------------

func test_r3_soak_twenty_minutes_of_play() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	var ids := BirdSpecies.IDS
	var models: Array[BirdModel] = []
	var state: Array[Vector4] = []
	for i in 60:
		var m := BirdModels.create(ids[i % ids.size()])
		m.scale = Vector3.ONE * SizeRules.species_data(m.species).get("span", 0.3)
		add_child(m)
		models.append(m)
		state.append(Vector4(rng.randf_range(3, 150), rng.randf_range(0, TAU), rng.randf_range(0.1, 0.8), rng.randf_range(4, 14)))
	var dt := 1.0 / 72.0
	var frames := 72 * 60 * 20
	var times := PackedInt32Array()
	var bad_buf := 0
	var wrong_batch := 0
	var max_batches := 0
	var respawns := 0
	var t0 := Time.get_ticks_msec()
	for f in frames:
		var t := f * dt
		# The player flies a lazy figure eight through the flock.
		cam.position = Vector3(sin(t * 0.05) * 80.0, 20.0 + sin(t * 0.13) * 10.0, sin(t * 0.1) * 60.0)
		cam.look_at(Vector3.ZERO + Vector3(0, 10, 0), Vector3.UP)
		for i in models.size():
			var m := models[i]
			var s := state[i]
			var ang := s.y + t * s.z
			m.position = Vector3(cos(ang) * s.x, s.w, sin(ang) * s.x)
			m.flap_phase = fposmod(m.flap_phase + dt * (4.0 + (i % 7)), 1.0)
			m.flap_amount = 0.5 + 0.5 * sin(t * 0.7 + i)
			m.bank = 0.5 * sin(t * 0.3 + i)
			# Every few seconds some birds perch, dive, change highlight.
			var phase := int(t * 0.25 + i * 0.37) % 4
			m.perched = phase == 3
			m.wing_fold = 1.0 if phase >= 2 else 0.0
			m.highlight = (int(t * 0.5) + i) % 3
		# Now and then a bird is caught and respawned as another species (the
		# Ecosystem's pooling), or hidden and shown again.
		if f % 97 == 0:
			var k := rng.randi() % models.size()
			var old := models[k]
			var sp: StringName = ids[rng.randi() % ids.size()]
			if rng.randf() < 0.5:
				old.species = sp
				old.scale = Vector3.ONE * SizeRules.species_data(sp).get("span", 0.3)
				old.snap()
			else:
				old.queue_free()
				var m := BirdModels.create(sp)
				m.scale = Vector3.ONE * SizeRules.species_data(sp).get("span", 0.3)
				add_child(m)
				models[k] = m
			respawns += 1
		if f % 131 == 0:
			var h := models[rng.randi() % models.size()]
			h.visible = not h.visible
		var a := Time.get_ticks_usec()
		BirdBatch.sync_all(dt)
		times.append(Time.get_ticks_usec() - a)
		if f % 360 == 0:
			for b: BirdBatch in BirdBatch.all():
				for x in b.buf:
					if not is_finite(x):
						bad_buf += 1
						break
			for m in models:
				if m.is_visible_in_tree() and (m._batch == null or m._batch.mesh != BirdModels.mesh(m.species, m.get_lod())):
					wrong_batch += 1
			max_batches = maxi(max_batches, BirdBatch.count())
		if f % 2000 == 0:
			await get_tree().process_frame
	# Let queued frees land before counting what is drawn.
	await get_tree().process_frame
	BirdBatch.sync_all(dt)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	var sorted := Array(times)
	sorted.sort()
	var n := sorted.size()
	var first := Array(times.slice(0, n / 10))
	var last := Array(times.slice(n - n / 10))
	first.sort()
	last.sort()
	var drawn := 0
	for m in models:
		if m.is_visible_in_tree():
			drawn += 1
	metric("soak", {"frames": frames, "sim_minutes": 20, "wall_s": snappedf(wall, 0.1), "respawns": respawns,
		"sync_us_median": sorted[n / 2], "sync_us_p99": sorted[int(n * 0.99)], "sync_us_max": sorted[n - 1],
		"median_first_2min": first[first.size() / 2], "median_last_2min": last[last.size() / 2],
		"non_finite_buffers": bad_buf, "models_in_wrong_batch": wrong_batch, "max_batches": max_batches,
		"instances_vs_visible": [BirdBatch.instance_total(), drawn]})
	print("[birds-r3] soak: %d frames (20 min at 72 Hz) in %.1f s; sync median %d us, p99 %d, max %d; first/last 2 min median %d/%d us; batches <= %d" % [
		frames, wall, sorted[n / 2], sorted[int(n * 0.99)], sorted[n - 1], first[first.size() / 2], last[last.size() / 2], max_batches])
	eq(bad_buf, 0, "no non-finite numbers in any batch buffer over 20 minutes")
	eq(wrong_batch, 0, "every drawn bird sits in the batch of its reported species and LOD")
	eq(BirdBatch.instance_total(), drawn, "batches hold exactly the visible birds after 20 minutes")
	lt(float(last[last.size() / 2]), float(first[first.size() / 2]) * 1.5 + 50.0, "sync cost does not creep up over the session")
	lt(float(sorted[n / 2]), 1000.0, "median sync of 60 birds under 1 ms")
	for m in models:
		m.queue_free()
	cam.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	BirdBatch.sync_all(dt)
	eq(BirdBatch.count(), 0, "every batch released once the birds are gone")
