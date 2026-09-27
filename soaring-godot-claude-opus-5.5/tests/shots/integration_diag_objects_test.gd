extends TestCase
## DIAGNOSTIC (integration round 2): do the static caches that grow over
## whole runs (FlapDetector._ref_cache: a reference stroke per player size,
## NpcFlight._table_cache: a level-speed table per NPC mass bucket) hold
## Objects? Fills each with new keys and counts Performance.OBJECT_COUNT.
##
##   tools/gd.sh fx_objs --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_objects


func _objs() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))


func test_static_caches_hold_no_objects() -> void:
	await wait_frames(2)
	FlapDetector.reference_table(0.2)
	await wait_frames(2)
	var o0 := _objs()
	for i in 400:
		FlapDetector.reference_table(0.3 + i * 0.0013)
	await wait_frames(2)
	var o1 := _objs()
	for i in 40:
		var f := NpcFlight.new(0.05 + i * 0.0007, 7.0)
		f = null
	await wait_frames(2)
	var o2 := _objs()
	print("[integration] objects: start %d, after 400 new reference strokes %d (%+d), after 40 new NPC mass buckets %d (%+d)" % [o0, o1, o1 - o0, o2, o2 - o1])
	eq(o1 - o0, 0, "reference strokes hold no objects")
	eq(o2 - o1, 0, "NPC flight tables hold no objects")
