extends TestCase
## B1: every species reads as itself. Silhouettes at equal span (glide pose,
## orthographic, 160 px grids) must differ pairwise: IoU < 0.85 from above
## and from the side (front view reported); the same at LOD1, at both ends
## of the wingbeat, and perched, dive-tucked and half-tucked. Colour: the visible colour of
## each view (depth-buffered, area mean, Oklab) must differ pairwise by at
## least MIN_DE in one view. Plus the field-guide cues the brief names:
## forked swallow tail, fingered crow/hawk/eagle wingtips (5/5/7), crooked
## gull wing, triangular starling wing, cocked wren tail (animation test),
## pigeon wing bars, gull black wingtips, rufous hawk tail.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const MAX_IOU := 0.85
## Oklab distance: ~0.02 is a just-noticeable difference; 0.05 is clearly
## different at a glance.
const MIN_DE := 0.05

var _sil := {}


func before_all() -> void:
	for sp in BirdSpecies.IDS:
		var v := Geo.posed(Geo.arrays(sp), Vector4(0.25, 0.0, 0.0, 0.0))
		_sil[sp] = {"top": Geo.silhouette(v, "top"), "side": Geo.silhouette(v, "side"), "front": Geo.silhouette(v, "front")}


func test_pairwise_silhouettes_differ() -> void:
	var ids := BirdSpecies.IDS
	var worst := {"top": [0.0, ""], "side": [0.0, ""], "front": [0.0, ""]}
	var matrix := {}
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var pair := "%s/%s" % [ids[i], ids[j]]
			var row := {}
			for view in ["top", "side", "front"]:
				var u := Geo.iou(_sil[ids[i]][view], _sil[ids[j]][view])
				row[view] = snappedf(u, 0.001)
				if u > worst[view][0]:
					worst[view] = [u, pair]
				if view != "front":
					lt(u, MAX_IOU, "%s %s-view IoU" % [pair, view])
			matrix[pair] = row
	metric("iou", matrix)
	# The same holds at LOD1 and at both ends of the wingbeat (what is drawn
	# at middle distance, and a flapping bird).
	var more := {}
	for variant in [["lod1_glide", 1, Vector4(0.25, 0.0, 0.0, 0.0)], ["lod0_down", 0, Vector4(0.42, 1.0, 0.0, 0.0)], ["lod0_up", 0, Vector4(0.0, 1.0, 0.0, 0.0)]]:
		var sil := {}
		for sp in ids:
			var v := Geo.posed(Geo.arrays(sp, variant[1]), variant[2])
			sil[sp] = {"top": Geo.silhouette(v, "top"), "side": Geo.silhouette(v, "side")}
		var w := [0.0, ""]
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				for view in ["top", "side"]:
					var u := Geo.iou(sil[ids[i]][view], sil[ids[j]][view])
					if u > w[0]:
						w = [u, "%s/%s %s" % [ids[i], ids[j], view]]
		lt(w[0], MAX_IOU, "%s: worst pairwise IoU %.3f (%s)" % [variant[0], w[0], w[1]])
		more[variant[0]] = [snappedf(w[0], 0.001), w[1]]
	metric("max_iou_lod1_and_beat", more)
	# ...and in the resting poses players see most (round-3 verifier):
	# perched (side, top), a dive tuck (top, side), a half tuck (top, side).
	# The perched front view is reported only: head-on, every perched bird is
	# an upright oval (as with the glide pose's front view).
	var rest := {}
	for variant in [["perched", Vector4(0.25, 0.0, 1.0, 1.0), ["side", "top"]], ["dive_tuck", Vector4(0.25, 0.0, 1.0, 0.0), ["top", "side"]],
			["half_tuck", Vector4(0.25, 0.0, 0.5, 0.0), ["top", "side"]]]:
		var sil := {}
		for sp in ids:
			var v := Geo.posed(Geo.arrays(sp), variant[1])
			var d := {}
			for view: String in variant[2]:
				d[view] = Geo.silhouette(v, view)
			sil[sp] = d
		for view: String in variant[2]:
			var w := [0.0, ""]
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var u := Geo.iou(sil[ids[i]][view], sil[ids[j]][view])
					if u > w[0]:
						w = [u, "%s/%s" % [ids[i], ids[j]]]
			lt(w[0], MAX_IOU, "%s %s: worst pairwise IoU %.3f (%s)" % [variant[0], view, w[0], w[1]])
			rest["%s_%s" % [variant[0], view]] = [snappedf(w[0], 0.001), w[1]]
	metric("max_iou_resting_poses", rest)
	metric("max_iou_top", [snappedf(worst["top"][0], 0.001), worst["top"][1]])
	metric("max_iou_side", [snappedf(worst["side"][0], 0.001), worst["side"][1]])
	metric("max_iou_front", [snappedf(worst["front"][0], 0.001), worst["front"][1]])


func test_colour_signatures_differ() -> void:
	var ids := BirdSpecies.IDS
	var sig := {}
	for sp in ids:
		var arr := Geo.arrays(sp)
		var v := Geo.posed(arr, Vector4(0.25, 0.0, 0.0, 0.0))
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		var s := {}
		for view in ["top", "bottom", "side"]:
			s[view] = Geo.oklab(Geo.view_color(v, cols, view))
		sig[sp] = s
	var worst := [INF, ""]
	var table := {}
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var d := 0.0
			for view in ["top", "bottom", "side"]:
				d = maxf(d, (sig[ids[i]][view] as Vector3).distance_to(sig[ids[j]][view]))
			var pair := "%s/%s" % [ids[i], ids[j]]
			gt(d, MIN_DE, "%s colour signature distance (Oklab, best view)" % pair)
			table[pair] = snappedf(d, 0.001)
			if d < worst[0]:
				worst = [d, pair]
	metric("colour_distance", table)
	metric("closest_colours", [snappedf(worst[0], 0.001), worst[1]])
	var means := {}
	for sp in ids:
		var t: Vector3 = sig[sp]["top"]
		means[String(sp)] = [snappedf(t.x, 0.01), snappedf(t.y, 0.01), snappedf(t.z, 0.01)]
	metric("top_oklab", means)


## The bird shader's float uniform defaults, read from its source (so the
## CPU mirror below cannot drift from what the GPU is given).
static func shader_defaults() -> Dictionary:
	var out := {}
	var re := RegEx.create_from_string("uniform float (\\w+)\\s*=\\s*([-0-9.]+)\\s*;")
	for m in re.search_all(BirdModels.SHADER.code):
		out[m.get_string(1)] = float(m.get_string(2))
	return out


## The shader's highlight fragment for one face (bird.gdshader, mirrored):
## sRGB plumage `c` of a bird whose wingspan covers `ang` radians and whose
## species reads from `readable`, highlight `hue` (linear), sun-lit (light
## 1.0) plus emission, pulse at its dimmest. Returns an sRGB colour.
static func highlighted_face(c: Color, hue: Color, ang: float, readable: float, u: Dictionary) -> Color:
	var tint := 1.0 - smoothstep(readable, readable * float(u["tint_end"]), ang)
	var plum := c.srgb_to_linear()
	var k := tint * float(u["highlight_mix"])
	var alb := plum.lerp(hue * float(u["highlight_albedo"]), k)
	var em := hue * (tint * 0.6 * float(u["highlight_glow"]))
	return Color(alb.r + em.r, alb.g + em.g, alb.b + em.b).linear_to_srgb()


func test_highlighted_birds_keep_their_colouring() -> void:
	# The brief: "shape and colour say what a bird is from a distance". A
	# highlighted bird big enough to show its plumage (from tint_end x its
	# readable angle: 1.2-2.9 deg by species) must keep B1's colour
	# distinctness exactly as unhighlighted (round-3 verifier: at 3 deg the
	# old tint left all 45 pairs under 0.05, at 10 deg 29). Measured with
	# B1's own signature (best of top, bottom and side views), edible and
	# danger, at 3, 10 and 20 deg across; the rendered check is the identity
	# pass of tests/shots/birds_highlight.gd.
	var u := shader_defaults()
	for key in ["tint_end", "highlight_mix", "highlight_albedo", "highlight_glow"]:
		check(u.has(key), "the shader declares %s" % key)
	var ids := BirdSpecies.IDS
	var hues := {"edible": BirdModels.HIGHLIGHT_EDIBLE.srgb_to_linear(), "danger": BirdModels.HIGHLIGHT_DANGER.srgb_to_linear()}
	var posed := {}
	var plain := {}
	for sp in ids:
		var arr := Geo.arrays(sp)
		posed[sp] = Geo.posed(arr, Vector4(0.25, 0.0, 0.0, 0.0))
		var s := {}
		for view in ["top", "bottom", "side"]:
			s[view] = Geo.oklab(Geo.view_color(posed[sp], arr[Mesh.ARRAY_COLOR], view))
		plain[sp] = s
	var table := {}
	var widest_tint := 0.0
	for sp in ids:
		widest_tint = maxf(widest_tint, BirdModels.min_highlight_angle(sp) * float(u["tint_end"]))
	lt(widest_tint, deg_to_rad(3.0), "every species wears its own plumage from 3 deg (widest tint end %.2f deg)" % rad_to_deg(widest_tint))
	for deg in [3.0, 10.0, 20.0]:
		for state in hues:
			var sig := {}
			var own := 0.0
			for sp in ids:
				var cols: PackedColorArray = Geo.arrays(sp)[Mesh.ARRAY_COLOR]
				var shaded := PackedColorArray()
				shaded.resize(cols.size())
				for i in cols.size():
					shaded[i] = highlighted_face(cols[i], hues[state], deg_to_rad(deg), BirdModels.min_highlight_angle(sp), u)
				var s := {}
				for view in ["top", "bottom", "side"]:
					s[view] = Geo.oklab(Geo.view_color(posed[sp], shaded, view))
					own = maxf(own, (s[view] as Vector3).distance_to(plain[sp][view]))
				sig[sp] = s
			var close := 0
			var worst := [INF, ""]
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var d := 0.0
					for view in ["top", "bottom", "side"]:
						d = maxf(d, (sig[ids[i]][view] as Vector3).distance_to(sig[ids[j]][view]))
					if d <= MIN_DE:
						close += 1
					if d < worst[0]:
						worst = [d, "%s/%s" % [ids[i], ids[j]]]
			eq(close, 0, "%s at %d deg: every species pair still > %.2f apart (closest %.3f %s)" % [state, deg, MIN_DE, worst[0], worst[1]])
			lt(own, 0.005, "%s at %d deg: each bird's colours are its own (largest change %.4f)" % [state, deg, own])
			table["%s_%ddeg" % [state, deg]] = {"pairs_within_0.05": close, "closest": [snappedf(worst[0], 0.001), worst[1]], "largest_change": snappedf(own, 0.0001)}
	metric("highlighted_colour_identity", table)
	metric("widest_tint_end_deg", snappedf(rad_to_deg(widest_tint), 0.01))


## Runs of filled pixels along a line x = const (top view, pixels).
func _runs_along(img: PackedByteArray, res: int, col: int) -> int:
	var runs := 0
	var inside := false
	for y in res:
		var f := img[y * res + col] != 0
		if f and not inside:
			runs += 1
		inside = f
	return runs


func test_fingered_wingtips() -> void:
	var res := 160
	var half := 0.62
	var want := {&"crow": 5, &"hawk": 5, &"eagle": 7}
	var found := {}
	for sp in BirdSpecies.IDS:
		var top: PackedByteArray = _sil[sp]["top"]
		# Most separate feathers crossed by a chordwise line near the tip.
		var best := 0
		for xs in range(0, 12):
			var x := 0.395 + xs * 0.008
			best = maxi(best, _runs_along(top, res, int((x + half) * res / (2.0 * half))))
		found[String(sp)] = best
		if want.has(sp):
			eq(best, want[sp], "%s: %d separate fingers at the wingtip" % [sp, want[sp]])
		else:
			lt(best, 3, "%s: closed wingtip (no fingers)" % sp)
	metric("tip_feathers_crossed", found)


func test_swallow_tail_is_deeply_forked() -> void:
	var arr := Geo.arrays(&"swallow")
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var g := Geo.groups(arr)
	var tip := -INF
	var centre := -INF
	for t in range(0, v.size(), 3):
		if g[t] != BirdPose.G_TAIL:
			continue
		for k in 3:
			var p := v[t + k]
			tip = maxf(tip, p.z)
			if absf(p.x) < 1e-4:
				centre = maxf(centre, p.z)
	gt(tip - centre, 0.15, "swallow: fork depth > 0.15 span (streamers)")
	metric("swallow_fork_depth", snappedf(tip - centre, 0.001))
	# No other species has a deep fork.
	for sp in BirdSpecies.IDS:
		if sp == &"swallow" or sp == &"moth":
			continue
		var a := Geo.arrays(sp)
		var vv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var gg := Geo.groups(a)
		var tp := -INF
		var ce := -INF
		for i in vv.size():
			if gg[i] != BirdPose.G_TAIL:
				continue
			tp = maxf(tp, vv[i].z)
			if absf(vv[i].x) < 1e-4:
				ce = maxf(ce, vv[i].z)
		lt(tp - ce, 0.06, "%s: no deep tail fork" % sp)


func test_species_marks() -> void:
	# Gull: crooked wing (wrist ahead of the root), black wingtips.
	var gw: Array = BirdSpecies.data(&"gull")["wing"]["stations"]
	lt(float(gw[2][1]), float(gw[0][1]) - 0.02, "gull wrist pushed forward")
	var gd: Array = BirdSpecies.data(&"gull")["wing"]["dihedral"]
	check(float(gd[0]) > 8.0 and float(gd[1]) < -8.0, "gull: arm raised, hand lowered (M shape)")
	# The marks are judged by what they look like (dark, rufous), not by
	# which colour slot painted them.
	var dark := func(c: Color) -> bool: return c.get_luminance() < 0.2
	check(_share_on_top(&"gull", dark, 0.4, -1, 0.44), "gull: black wingtips on top (outer hand)")
	check(not _share_on_top(&"gull", dark, 0.05, -1, 0.0, 0.3), "gull: the rest of the upper wing is pale")
	# Pigeon: two dark bars across the inner wing.
	var bars := 0
	for b in BirdSpecies.data(&"pigeon")["wing"]["arm_bands"]:
		if b[1] == "bar":
			bars += 1
	eq(bars, 2, "pigeon: two wing bars")
	check(_share_on_top(&"pigeon", dark, 0.15, -1, 0.08, 0.22), "pigeon: dark bars cover >= 15% of the upper arm")
	# Hawk: rufous tail from above (orange-brown: red over green over blue,
	# clearly saturated).
	var rufous := func(c: Color) -> bool: return c.r > c.g * 1.3 and c.g > c.b * 1.2 and c.s > 0.5
	check(_share_on_top(&"hawk", rufous, 0.6, BirdPose.G_TAIL), "hawk: rufous tail")
	for sp in [&"crow", &"eagle", &"gull"]:
		check(not _share_on_top(sp, rufous, 0.05, BirdPose.G_TAIL), "%s: no rufous tail" % sp)
	# Starling: triangular wing (trailing edge straight to a point: chord
	# shrinks linearly from wrist to tip).
	var st: Array = BirdSpecies.data(&"starling")["wing"]["stations"]
	var n := st.size()
	near(float(st[n - 1][2]), 0.0, 1e-6, "starling: pointed tip")
	# Swallow: longest hand relative to its arm.
	var sw: Array = BirdSpecies.data(&"swallow")["wing"]["stations"]
	var ratio := (0.5 - float(sw[2][0])) / float(sw[2][0])
	gt(ratio, 2.5, "swallow: long hand, short arm")


## True when upper-surface faces whose colour passes `test` cover at least
## `min_share` of the upper-surface wing area with x_min <= |x| <= x_max (or
## of `group` when given).
func _share_on_top(sp: StringName, test: Callable, min_share: float, group: int = -1, x_min: float = 0.25, x_max: float = 1.0) -> bool:
	var arr := Geo.arrays(sp)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var g := Geo.groups(arr)
	var tot := 0.0
	var hit := 0.0
	for t in range(0, v.size(), 3):
		if nn[t].y < 0.3:
			continue
		if group >= 0:
			if g[t] != group:
				continue
		elif g[t] != g[t + 1] or g[t] != g[t + 2] or not Geo.is_wing(g[t]):
			continue
		else:
			var cx := (absf(v[t].x) + absf(v[t + 1].x) + absf(v[t + 2].x)) / 3.0
			if cx < x_min or cx > x_max:
				continue
		var a := (v[t + 1] - v[t]).cross(v[t + 2] - v[t]).length()
		tot += a
		if test.call(cols[t]):
			hit += a
	return tot > 0.0 and hit / tot >= min_share


func test_tails_have_a_ridge_seen_side_on() -> void:
	# A flat tail seen exactly side-on is an invisible line (round 2: the
	# wren's cocked tail vanished in profile): every tail's upper surface
	# rises to a central ridge at least 0.2 x its half-width above the flat
	# underside (BirdMeshBuilder.TAIL_RIDGE), at every LOD; and the perched
	# wren's cocked tail covers pixels in a side view.
	var table := {}
	for sp: StringName in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var td: Array = BirdSpecies.data(sp)["tail"]
		var up := BirdPose.rx(Vector3.UP, -deg_to_rad(float(td[7]) if td.size() > 7 else 0.0))
		for lod in BirdModels.LOD_COUNT:
			var arr := Geo.arrays(sp, lod)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
			var g := Geo.groups(arr)
			var hmax := 0.0
			var hmin := INF
			var wmax := 0.0
			for i in v.size():
				if g[i] != BirdPose.G_TAIL:
					continue
				var pivot := Vector3(c1[i * 4], c1[i * 4 + 1], c1[i * 4 + 2])
				var h := (v[i] - pivot).dot(up)
				hmax = maxf(hmax, h)
				hmin = minf(hmin, h)
				wmax = maxf(wmax, absf(v[i].x))
			var ratio := (hmax - hmin) / maxf(wmax, 1e-6)
			gt(ratio, 0.2, "%s LOD%d: tail ridge %.2f x its half-width" % [sp, lod, ratio])
			if lod == 0:
				table[String(sp)] = snappedf(ratio, 0.01)
	var arr := Geo.arrays(&"wren")
	var posed := BirdPose.pose_arrays(arr, Vector4(0.25, 0.0, 1.0, 1.0))
	var g := Geo.groups(arr)
	var tail_only := PackedVector3Array()
	for t in range(0, posed.size(), 3):
		if g[t] == BirdPose.G_TAIL:
			tail_only.append_array([posed[t], posed[t + 1], posed[t + 2]])
	var px := Geo.area(Geo.silhouette(tail_only, "side"))
	# (Flat, TAIL_RIDGE = 0: 0 px.)
	gt(px, 15, "the perched wren's cocked tail covers %d px side-on (160 px grid)" % px)
	metric("tail_ridge_over_half_width", table)
	metric("wren_perched_tail_side_px", px)

