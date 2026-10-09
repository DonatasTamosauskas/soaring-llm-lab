extends TestCase
## Verifier probe (birds, round 1): is B1's silhouette distinctness robust,
## or tuned to one raster? Pairwise IoU (top and side, equal span) for:
##  * the builder's setup (LOD0, glide, 160 px) as a reproduction,
##  * coarser rasters (64 px, 32 px: what a bird covers at gameplay range),
##  * LOD1 and LOD2 (the meshes actually drawn beyond ~3 deg / ~0.9 deg),
##  * flapping poses (mid-downstroke, mid-upstroke) instead of the glide.
## Threshold 0.85 as in the brief. Records the worst pair per setting.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const MAX_IOU := 0.85


func _worst(lod: int, inst: Vector4, res: int) -> Dictionary:
	var sil := {}
	for sp in BirdSpecies.IDS:
		var v := Geo.posed(Geo.arrays(sp, lod), inst)
		sil[sp] = {"top": Geo.silhouette(v, "top", res), "side": Geo.silhouette(v, "side", res)}
	var ids := BirdSpecies.IDS
	var out := {"top": [0.0, ""], "side": [0.0, ""], "over": []}
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			for view in ["top", "side"]:
				var u := Geo.iou(sil[ids[i]][view], sil[ids[j]][view])
				if u > out[view][0]:
					out[view] = [snappedf(u, 0.001), "%s/%s" % [ids[i], ids[j]]]
				if u >= MAX_IOU:
					out["over"].append("%s/%s %s %.3f" % [ids[i], ids[j], view, u])
	return out


func test_silhouettes_across_lods_rasters_and_poses() -> void:
	var glide := Vector4(0.25, 0.0, 0.0, 0.0)
	var settings := {
		"lod0_glide_160": [0, glide, 160],
		"lod0_glide_64": [0, glide, 64],
		"lod0_glide_32": [0, glide, 32],
		"lod1_glide_160": [1, glide, 160],
		"lod1_glide_64": [1, glide, 64],
		"lod2_glide_64": [2, glide, 64],
		"lod2_glide_32": [2, glide, 32],
		"lod0_down_160": [0, Vector4(0.2, 1.0, 0.0, 0.0), 160],
		"lod0_up_160": [0, Vector4(0.7, 1.0, 0.0, 0.0), 160],
	}
	var report := {}
	for k in settings:
		var s: Array = settings[k]
		var w := _worst(s[0], s[1], s[2])
		report[k] = w
		print("[birds-verify] %-16s top %s  side %s  over %d" % [k, str(w["top"]), str(w["side"]), w["over"].size()])
	metric("worst_iou", report)
	# The builder's own claim must reproduce exactly.
	lt(report["lod0_glide_160"]["top"][0], MAX_IOU, "LOD0 glide 160 px top (builder's setup)")
	lt(report["lod0_glide_160"]["side"][0], MAX_IOU, "LOD0 glide 160 px side (builder's setup)")
	# Robustness: same criterion on coarser rasters and at LOD1 (drawn from
	# ~3 deg down to ~0.9 deg, i.e. most gameplay distances).
	for k in ["lod0_glide_64", "lod1_glide_160", "lod1_glide_64", "lod0_down_160", "lod0_up_160"]:
		eq(report[k]["over"].size(), 0, "%s: no pair at IoU >= 0.85 (%s)" % [k, str(report[k]["over"])])
