extends "res://tests/unit/ai/ai_sim.gd"
## COPY of the verifier probe tests/probes/ai/r3x_refuge_list_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER PROBE (round 3): what refuges the valley offers (World contract),
## by name prefix and max_span, and what Habitat.pick_refuge picks for a
## starling fleeing a crow / a crow fleeing a gull from random spots, versus
## the best choice the pursuer cannot follow into.
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_refuge_list


func test_r3_refuge_list() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var by := {}
	for r in rw.get_refuges():
		var nm := String(r.get("name", "?"))
		var key := nm.rstrip("0123456789_").split("_")[0] if nm != "?" else "?"
		var e: Dictionary = by.get(key, {"n": 0, "min": INF, "max": 0.0})
		e["n"] += 1
		e["min"] = minf(e["min"], float(r["max_span"]))
		e["max"] = maxf(e["max"], float(r["max_span"]))
		by[key] = e
	print("[ai-r3x] refuges by kind: %s" % JSON.stringify(by))
	var hab := Habitat.for_world(rw)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var out := {}
	for pr in [[&"crow", &"starling"], [&"gull", &"crow"], [&"hawk", &"pigeon"], [&"hawk", &"starling"]]:
		var pspan := SizeRules.wingspan_for_mass(SizeRules.species_data(pr[0])["mass"])
		var qspan := SizeRules.wingspan_for_mass(SizeRules.species_data(pr[1])["mass"])
		var n := 0
		var follow := 0
		var alt_exists := 0
		var names := {}
		for k in 300:
			var x := rng.randf_range(-350, 350)
			var z := rng.randf_range(-350, 350)
			var pos := Vector3(x, rw.ground_height(x, z) + rng.randf_range(4, 20), z)
			var a := rng.randf() * TAU
			var tp := pos + Vector3(cos(a) * 25.0, 5.0, sin(a) * 25.0)
			var r := hab.pick_refuge(pos, qspan, tp, 64.0)
			if r.is_empty():
				continue
			n += 1
			if pspan <= float(r["max_span"]):
				follow += 1
				var nm := String(r.get("name", "?")).rstrip("0123456789_")
				names[nm] = names.get(nm, 0) + 1
				# Was there cover in reach the pursuer could NOT enter?
				var ok := false
				for rr in hab.refuges:
					if float(rr["max_span"]) >= qspan and float(rr["max_span"]) < pspan and (rr["position"] as Vector3).distance_to(pos) < 64.0:
						ok = true
						break
				alt_exists += 1 if ok else 0
		out["%s>%s" % pr] = {"picked": n, "pursuer_can_follow": follow, "of_which_a_safe_alternative_was_within_reach": alt_exists, "names": names}
	print("[ai-r3x] pick_refuge: %s" % JSON.stringify(out))
	var dir := Paths.artifacts("ai").path_join("fix_r3/verifier_probes")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("refuge_list.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"refuges_by_kind": by, "pick_refuge": out}, "  "))
	f.close()
	check(true, "listed")
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
