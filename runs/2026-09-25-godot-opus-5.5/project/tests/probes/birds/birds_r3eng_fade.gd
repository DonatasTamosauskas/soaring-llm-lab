extends "res://tests/shots/birds_highlight.gd"
## Round-3 engineering verifier probe (birds). Read-only on the area's code:
## reuses the builder's own highlight measurement (_measure, same metric and
## thresholds) but at the distances the builder's shot does not sample:
##   * "mid"  - the marker half faded: wingspan at 1.075 x the species'
##              readable angle (BirdModels.min_highlight_angle);
##   * "past" - just past the fade: 1.16 x (marker gone, the bird alone at
##              its smallest).
## Plus the marker's extent: the radius (px) of the pixels a highlighted bird
## changes vs an unhighlighted one at 0.8 x (marker full), 1.3 x (marker
## must be gone) the readable angle and at 40 m.
## Output: artifacts/birds/verify/r3eng_fade.json (+ zoom sheets).
##
##   tools/gd.sh birds_verify2 --rendering-method forward_plus --resolution 1600x900 \
##       res://tests/probes/birds/birds_r3eng_fade.tscn [-- --bg=sky,water_deep]

const OUT_DIR := "birds/verify"


func _ready() -> void:
	var args := Paths.user_args()
	var bgs: Array = ["sky", "water_deep", "roof_red", "leaf_dark", "wall_white", "meadow"]
	if args.has("bg"):
		bgs = Array(String(args["bg"]).split(","))
	var all_species: Array = BirdSpecies.IDS.duplicate()
	_stage()
	var mat := BirdModels.material()
	var report := {"thresholds": {"state": MIN_DE_STATE, "pair": MIN_DE_PAIR, "background": MIN_DE_BG}}
	var fails := []
	var worst := {}
	var passes := [] if args.has("extents_only") else [["mid", 1.075], ["past", 1.16]]
	for k in passes:
		var tag: String = k[0]
		var f: float = k[1]
		var rows := {}
		var zoom_rows := []
		worst[tag] = {"state": [INF, ""], "pair": [INF, ""], "background": [INF, ""]}
		for bg in bgs:
			var cells := []
			var per := {}
			for sp: StringName in all_species:
				species = [sp]
				var span := float(SizeRules.species_data(sp)["span"])
				var d := span / (BirdModels.min_highlight_angle(sp) * f)
				var res: Dictionary = await _measure(StringName(bg), d)
				per[String(sp)] = res["numbers"][String(sp)]
				per[String(sp)]["dist_m"] = snappedf(d, 0.01)
				cells.append_array(res["cells"])
				for x in res["fails"]:
					fails.append("%s %s (%.1f m)" % [tag, x, d])
				for w in worst[tag]:
					var ww: Array = res["worst"][w]
					if float(ww[0]) < float(worst[tag][w][0]):
						worst[tag][w] = [snappedf(float(ww[0]), 0.001), ww[1]]
			rows[bg] = per
			zoom_rows.append([bg, cells])
		report[tag] = rows
		species = all_species
		var sheet: Image = await _zoom_sheet(zoom_rows, 0.0)
		var p := Paths.artifacts(OUT_DIR).path_join("r3eng_fade_%s.png" % tag)
		sheet.save_png(p)
		print("[birds-verify] wrote ", p)
	report["worst"] = worst
	# Marker extents.
	mat.set_shader_parameter("pulse_test", 0.5)
	var ext := {}
	for sp: StringName in all_species:
		var span := float(SizeRules.species_data(sp)["span"])
		var ra := BirdModels.min_highlight_angle(sp)
		var row := {}
		for k in [["full_0.8x", span / (ra * 0.8)], ["gone_1.3x", span / (ra * 1.3)], ["40m", 40.0]]:
			row[k[0]] = await _extents(sp, float(k[1]))
		ext[String(sp)] = row
	report["marker_extent_px"] = ext
	# Marker gone past the fade (1.3 x): highlighted extent within 2 px of
	# the unhighlighted bird's; present below it (0.8 x): at least 2 px out.
	var ext_fails := []
	for sp in ext:
		var g: Dictionary = ext[sp]["gone_1.3x"]
		var fu: Dictionary = ext[sp]["full_0.8x"]
		for st in ["edible", "danger"]:
			if float(g[st]) > float(g["none"]) + 2.0:
				ext_fails.append("%s %s: marker still drawn past the fade (%.1f vs %.1f px)" % [sp, st, g[st], g["none"]])
			if float(fu[st]) < float(fu["none"]) + 2.0:
				ext_fails.append("%s %s: no marker below the readable angle" % [sp, st])
	report["extent_failures"] = ext_fails
	for x in ext_fails:
		print("[birds-verify]   extent fail ", x)
	report["failures"] = fails.size()
	report["fail_list"] = fails
	mat.set_shader_parameter("pulse_test", -1.0)
	var fa := FileAccess.open(Paths.artifacts(OUT_DIR).path_join("r3eng_fade%s.json" % ("_extents" if args.has("extents_only") else "")), FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  "))
	print("[birds-verify] fade: worst %s; %d failures" % [str(worst), fails.size()])
	for x in fails.slice(0, 40):
		print("[birds-verify]   fail ", x)
	for sp in ext:
		print("[birds-verify] extent %-9s %s" % [sp, str(ext[sp])])
	get_tree().quit(0)


## Radius (px) of the changed pixels around each of none/edible/danger at
## `dist` over the sky; and the bird's own drawn half-span in px.
func _extents(sp: StringName, dist: float) -> Dictionary:
	var pitch := _aim(&"sky")
	for j in 3:
		await get_tree().process_frame
	var bgd := (await _grab()).get_data()
	var span := float(SizeRules.species_data(sp)["span"])
	var ppr := H / deg_to_rad(FOV)
	var gap := deg_to_rad(8.0)
	var birds := []
	for st in 3:
		birds.append(_bird(sp, st, dist, (st - 1) * gap, pitch))
	for j in 3:
		await get_tree().process_frame
	var d := (await _grab()).get_data()
	var out := {"half_span_px": snappedf(span / dist * ppr * 0.5, 0.1)}
	for st in 3:
		var b: BirdModel = birds[st]
		var c := cam.unproject_position(b.global_position)
		var r := int(gap * ppr * 0.45)
		var mx := 0.0
		for y in range(maxi(int(c.y) - r, 0), mini(int(c.y) + r, H)):
			for x in range(maxi(int(c.x) - r, 0), mini(int(c.x) + r, W)):
				var i := (y * W + x) * 4
				var dd := (absi(d[i] - bgd[i]) + absi(d[i + 1] - bgd[i + 1]) + absi(d[i + 2] - bgd[i + 2])) / 255.0
				if dd > 0.06:
					mx = maxf(mx, Vector2(x + 0.5, y + 0.5).distance_to(c))
		out[STATES[st]] = snappedf(mx, 0.1)
	for b in birds:
		b.queue_free()
	await get_tree().process_frame
	return out
