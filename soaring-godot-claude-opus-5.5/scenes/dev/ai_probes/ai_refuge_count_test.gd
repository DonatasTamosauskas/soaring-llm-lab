extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): in the AI arena soak, for every
## flight from a predator, what refuge choice was made (none / chosen) and
## why none: nothing the bird fits and the pursuer does not, nothing in
## reach, nothing in sight.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_refuge_count


func test_refuge_count() -> void:
	await make_world(false, 1)
	var e := make_eco(60, 7)
	make_checker()
	var h := Habitat.for_world(world)
	var r := {"flee": 0, "chosen": 0, "none": 0, "why": {}, "pairs_none": {}, "dives": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what == &"refuge":
				r["dives"] += 1
			if what != &"flee" or b.threat == null or not is_instance_valid(b.threat):
				return
			r["flee"] += 1
			var span := b.get_wingspan()
			var ts := b.threat.get_wingspan()
			var reach := clampf(float(b.profile["awareness_m"]) * 2.0, 25.0, 90.0)
			var fit := 0
			var fit_near := 0
			for rf in h.refuges:
				var ms := float(rf["max_span"])
				if span <= ms and ts > ms:
					fit += 1
					if (rf["position"] as Vector3).distance_to(b.global_position) <= reach:
						fit_near += 1
			var why := "chosen" if not b.refuge.is_empty() else ("no_fit" if fit == 0 else ("none_in_reach" if fit_near == 0 else "not_in_sight_or_behind"))
			r["why"][why] = r["why"].get(why, 0) + 1
			if why != "chosen":
				var k := "%s>%s" % [b.threat.species, b.species]
				r["pairs_none"][k + ":" + why] = r["pairs_none"].get(k + ":" + why, 0) + 1))
	run(180.0)
	print("[ai-rc] %s" % JSON.stringify(r))
	check(true, "counted")
	await clear_sim()
