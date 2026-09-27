extends TestCase
## ON-DEMAND drift report between VR's first-person wings and the birds
## area's CURRENT internal species data. Not part of the unit suite (fix
## round 4, engineering verifier): those checks read birds-internal data
## (BirdSpecies.data()['colors'], and compare FirstPersonWings.PALETTE, the
## fallback copy used only when BirdModels is missing, with today's
## BirdModels colours), so a colour retune by birds would break VR's suite.
## The unit suite keeps the contract check (the drawn colours equal
## BirdModels.wing_palette of the same species, wings_test).
##
##   tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=birds_palette
##
## A failure here means: paste the printed rows into FirstPersonWings.PALETTE
## / ACCENT_AT (the game itself already draws the birds area's colours).


func _cdist(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## The fallback copy equals the birds area's current NPC wing palette.
func test_fallback_palette_matches_the_birds_data() -> void:
	if FirstPersonWings._npc_wing_palette(&"sparrow").is_empty():
		print("[vr] BirdModels unavailable: nothing to compare")
		check(true, "skipped: no birds area")
		return
	var worst := 0.0
	var worst_sp := ""
	for sp in SizeRules.SPECIES:
		var npc := FirstPersonWings._npc_wing_palette(sp["id"])
		var fb: Array = FirstPersonWings.PALETTE[sp["id"]]
		for i in FirstPersonWings.PALETTE_KEYS.size():
			var d := _cdist(Color(fb[i]), npc[FirstPersonWings.PALETTE_KEYS[i]])
			if d > worst:
				worst = d
				worst_sp = String(sp["id"])
	metric("worst_fallback_palette_dist", [worst_sp, worst])
	lt(worst, 0.01, "fallback palette = the NPC palette (worst %.4f, %s)" % [worst, worst_sp])
	if worst >= 0.01:
		for sp in SizeRules.SPECIES:
			var npc := FirstPersonWings._npc_wing_palette(sp["id"])
			var row: Array[String] = []
			for k in FirstPersonWings.PALETTE_KEYS:
				row.append("\"%s\"" % (npc[k] as Color).to_html(false))
			print("[vr] NPC palette now: &\"%s\": [%s]," % [sp["id"], ", ".join(row)])


## Where each species wears its accent (FirstPersonWings.ACCENT_AT) agrees
## with the birds area's own species data, read the way
## BirdModels.wing_palette picks the accent: the first of bar / tip / edge /
## te / fore_band the species has.
func test_accent_placement_matches_the_npc_species() -> void:
	var scr: Script = null
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == &"BirdSpecies" and ResourceLoader.exists(c["path"]):
			scr = load(c["path"]) as Script
	if scr == null or not scr.can_instantiate():
		print("[vr] BirdSpecies unavailable: accent placement not cross-checked")
		check(true, "skipped: no birds area")
		return
	var kinds := {"bar": 1, "tip": 2, "edge": 3, "te": 3, "fore_band": 4}
	var checked := 0
	for sp in SizeRules.SPECIES:
		var id: StringName = sp["id"]
		var d: Variant = scr.call(&"data", id)
		if not (d is Dictionary and (d as Dictionary).get("colors") is Dictionary):
			continue
		var cols: Dictionary = d["colors"]
		var want := 0
		for k in ["bar", "tip", "edge", "te", "fore_band"]:
			if cols.has(k):
				want = kinds[k]
				break
		eq(int(FirstPersonWings.ACCENT_AT.get(id, -1)), want, "%s wears its accent where the NPC model does (%d)" % [id, want])
		checked += 1
	eq(checked, SizeRules.SPECIES.size(), "every species cross-checked")
