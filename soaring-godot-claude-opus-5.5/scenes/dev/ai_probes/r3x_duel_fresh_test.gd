extends "res://tests/unit/ai/hunt_duel_test.gd"
## COPY of the verifier probe tests/probes/ai/r3x_duel_fresh_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER PROBE (round 3): A2 on seed families nobody tuned on. The builder
## pooled families 0-3 (trial numbers t + 1000 f, f = 0..3) and the round-2
## verifier's "families 1000 and 2000" were the builder's families 1 and 2.
## This probe uses trial numbers 7000.. and 8000.. (fleeing, 2 x N per pair)
## and 9000.. (calm, N per pair), with the builder's own _duel (same harness,
## same stand-in checker, two birds alone). Plots go to verify/r3/duels/.
## Criterion A2: calm > 80% per pair; fleeing 20-70% per pair and overall.
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_duel_fresh --test=test_r3 [--r3_duel_n=48]


func _plot_duel(tag: String, a: PackedVector3Array, b: PackedVector3Array, marks: Array, out: Dictionary) -> void:
	# Never write into the builder's artifacts/ai/duels/.
	pass


func _fresh(fleeing: bool, bases: Array, per: int) -> Dictionary:
	var table := {}
	var tot := 0
	var cau := 0
	for pair in _pairs():
		var n := 0
		var trials := 0
		var reasons := {}
		var stoops := [0, 0]
		for base in bases:
			for t in per:
				var r := _duel(pair[0], pair[1], fleeing, int(base) + t)
				trials += 1
				if r["caught"]:
					n += 1
				reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
				if r["stooped"]:
					stoops[0] += 1
					stoops[1] += 1 if r["caught"] else 0
		await wait_frames(1)
		var key := "%s>%s" % [pair[0], pair[1]]
		table[key] = {"rate": snappedf(float(n) / trials, 0.001), "trials": trials, "reasons": reasons, "stoops": stoops}
		print("[ai-r3x] fresh duel %s fleeing=%s: %d/%d %s stoops %d/%d" % [key, fleeing, n, trials, reasons, stoops[1], stoops[0]])
		tot += trials
		cau += n
	table["overall"] = float(cau) / maxf(tot, 1)
	return table


func test_r3_fresh_families() -> void:
	var per := int(Paths.arg("r3_duel_n", "48"))
	var calm := await _fresh(false, [9000], per)
	var flee := await _fresh(true, [7000, 8000], per)
	var dir := Paths.artifacts("ai").path_join("fix_r3/verifier_probes")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("duel_fresh.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"calm": calm, "flee": flee, "per_family": per}, "  "))
	f.close()
	for k in calm:
		if k != "overall":
			gt(calm[k]["rate"], 0.8, "fresh calm %s" % k)
	for k in flee:
		if k != "overall":
			between(flee[k]["rate"], 0.2, 0.7, "fresh fleeing %s (%d duels)" % [k, flee[k]["trials"]])
	between(flee["overall"], 0.2, 0.7, "fresh fleeing overall")
	eq(_crowded, 0, "every duel was the two birds alone")
