extends TestCase
## Verifier probe (gameloop, round 1): the stored integrated-sim evidence
## (artifacts/gameloop/integrated.json, competent run 0 = seed 100, 60 min)
## must be reproducible from the current code. Run with:
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=gl_verify_repro


func test_competent_run0_reproduces_artifact() -> void:
	var f := FileAccess.open(OS.get_environment("SOARING_ARTIFACTS").path_join("gameloop/integrated.json"), FileAccess.READ)
	if not check(f != null, "integrated.json readable"):
		return
	var stored: Dictionary = (JSON.parse_string(f.get_as_text()) as Dictionary)["competent"]["raw"][0]
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var r: Dictionary = await sim.run(&"competent", 100, 3600.0)
	sim.queue_free()
	await get_tree().process_frame
	var got := {}
	for k in r["tier_at"]:
		got[str(k)] = snappedf(float(r["tier_at"][k]), 0.01)
	var want := {}
	for k in stored["tier_at"]:
		want[str(k)] = snappedf(float(stored["tier_at"][k]), 0.01)
	metric("got", got)
	metric("want", want)
	metric("got_catches", r["catches"])
	metric("want_catches", stored["catches"])
	print("[gameloop-verify] repro got %s catches %d | stored %s catches %d" % [got, r["catches"], want, stored["catches"]])
	eq(str(got), str(want), "tier times identical to the stored artifact")
	eq(int(r["catches"]), int(stored["catches"]), "catch count identical")
