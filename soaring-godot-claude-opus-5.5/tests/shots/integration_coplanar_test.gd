extends TestCase
## DIAGNOSTIC (integration hygiene): the drawn valley's overlapping parallel
## faces (integration_coplanar_scan.gd), listed by owner, written to
## artifacts/integration/coplanar[_<tag>].json. The regression test is
## tests/unit/integration/coplanar_test.gd.
##
##   tools/gd.sh ih_cop --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_coplanar [--count_only=1] [--tag=before]

const Scan := preload("res://tests/shots/integration_coplanar_scan.gd")

var world: World


func before_all() -> void:
	world = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(world)
	var t0 := Time.get_ticks_msec()
	while not world.is_generated and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	await wait_frames(3)


func after_all() -> void:
	world.queue_free()
	await wait_frames(3)


func test_scan() -> void:
	var sc := Scan.new()
	var ws := WorldScaleDriver.target_scale(SizeRules.species_data(&"sparrow")["mass"], 1.5)
	var r := sc.analyze(world, WorldScaleDriver.near_for(ws))
	var tag := Paths.arg("tag", "")
	var fa := FileAccess.open(Paths.artifacts("integration").path_join("coplanar%s.json" % ("" if tag.is_empty() else "_" + tag)), FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(r, "  "))
	metric("totals", r["totals"])
	check(true, "scanned")
