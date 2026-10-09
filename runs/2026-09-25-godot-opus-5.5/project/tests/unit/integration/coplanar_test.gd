extends TestCase
## The drawn valley has no coplanar surfaces of different colours that fight
## in the Quest's 24-bit depth buffer (integration hygiene, 2026-09-27; the
## Quest verifier's predicted z-fighting). depth_precision_test casts rays
## through the colliders from ten viewpoints; this reads every triangle the
## renderer draws (tests/shots/integration_coplanar_scan.gd: overlapping
## faces within 3 deg and 0.3 m of each other, facing the same way, of
## different colours, the front one seen from somewhere) and judges them at
## a sparrow's near plane (the smallest the game uses: its depth steps are
## the coarsest).
##
## Pinned:
##  * no exact overlap (planes within 1 mm: they fight at every distance, at
##    every size) - round 0-2's valley had 307 spots (the belfry floor under
##    the belt course, window crosses, a lake quad);
##  * no overlap within 5 mm that a sparrow sees fighting (a pixel or more
##    at the distance it starts: 6-19 m) - 3,289 spots before (a birch's
##    dark bands and the two-tone boles over their hidden piece starts);
##  * the paving (the street and the square, 0.2 m over the grass) settles
##    its depth ties with a polygon offset (Palette.paving_material): before,
##    the grass fought through it from ~120 m for a sparrow, ~350 m for an
##    eagle.
## Printed for the record: every pair class left, with where its fight
## starts (the gaps of 5 mm to 0.3 m that the near plane can only push out,
## docs/INTEGRATION.md "Depth precision").

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


func test_no_coplanar_faces_fight() -> void:
	if not check(world.is_generated, "the valley generated"):
		return
	var sc := Scan.new()
	var ws := WorldScaleDriver.target_scale(SizeRules.species_data(&"sparrow")["mass"], 1.5)
	var near := WorldScaleDriver.near_for(ws)
	var r := sc.analyze(world, near, Paths.arg("coplanar_verbose", "") != "")
	var tot: Dictionary = r["totals"]
	var worst := []
	for k: String in r["by_owner"]:
		var row: Dictionary = r["by_owner"][k]
		if int(row["exact_spots"]) > 0 or int(row["mm5_seen_spots"]) > 0:
			worst.append("%s: %s" % [k, row["worst"].slice(0, 2)])
	eq(int(tot["exact_spots"]), 0, "no exactly coplanar faces of different colours overlap where they can be seen: %s" % [worst])
	eq(int(tot["mm5_seen_spots"]), 0, "no faces of different colours within 5 mm that a sparrow sees fight: %s" % [worst])
	gt(int(r["offset_settled"]), 100, "the paving settles its ties with the ground under it by its depth offset (%d pairs)" % r["offset_settled"])
	var street_rows := 0
	for k: String in r["by_owner"]:
		if k.begins_with("Visual/street over Visual/terrain"):
			street_rows += int(r["by_owner"][k]["seen_spots"])
	eq(street_rows, 0, "no paving over the grass left to fight")
	print("[integration] coplanar: %d triangles; same-facing pairs within %.2f m: %d (of one colour %d, settled by the offset %d, seen %d); spots seen fighting %d, by onset %s" % [
		r["triangles"], Scan.MAX_GAP, r["same_facing"], r["same_colour"], r["offset_settled"], r["seen_same_facing"],
		tot["cm30_seen_spots"], r["seen_by_onset"]])
	metric("coplanar_totals", tot)
	metric("coplanar_seen_by_onset", r["seen_by_onset"])
	metric("coplanar_offset_settled", r["offset_settled"])
