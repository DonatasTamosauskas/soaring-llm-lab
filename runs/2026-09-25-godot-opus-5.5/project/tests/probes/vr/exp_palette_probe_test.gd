extends TestCase
## Verifier probe (experience lens), V5 "tint by the player's species": the
## first-person wings are a size AND identity cue next to NPCs of the same
## species. The birds area publishes BirdModels.wing_palette(sp) for exactly
## this (ARCHITECTURE contract change 2026-09-26, birds); the VR area keeps
## its own table. How far apart are they? (sRGB distance, 0..1.73.)
## Informational: the birds area's colours may still change.


func test_first_person_palette_matches_npc_wings() -> void:
	if not ClassDB.class_exists(&"Node") or not ResourceLoader.exists("res://scripts/birds/bird_models.gd"):
		check(true, "birds area absent")
		return
	var worst := 0.0
	var worst_sp := ""
	var rows := {}
	for s in SizeRules.SPECIES:
		var sp: StringName = s["id"]
		var npc: Dictionary = BirdModels.wing_palette(sp)
		var vr_cov := FirstPersonWings.palette_color(sp, 2)
		var vr_sec := FirstPersonWings.palette_color(sp, 1)
		var vr_pri := FirstPersonWings.palette_color(sp, 0)
		var d_cov := _dist(vr_cov, npc["upper_coverts"])
		var d_sec := _dist(vr_sec, npc["upper_flight"])
		var d_pri := _dist(vr_pri, npc["upper_primaries"])
		var d := maxf(d_cov, maxf(d_sec, d_pri))
		rows[String(sp)] = [snappedf(d_cov, 0.01), snappedf(d_sec, 0.01), snappedf(d_pri, 0.01)]
		print("[vr-verify] palette %-9s coverts %.2f flight %.2f primaries %.2f  (VR cov %s vs NPC %s)" % [sp, d_cov, d_sec, d_pri,
			vr_cov.to_html(false), (npc["upper_coverts"] as Color).to_html(false)])
		if d > worst:
			worst = d
			worst_sp = String(sp)
	metric("palette_dist", rows)
	metric("worst", worst)
	metric("worst_species", worst_sp)
	check(true, "informational")


static func _dist(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
