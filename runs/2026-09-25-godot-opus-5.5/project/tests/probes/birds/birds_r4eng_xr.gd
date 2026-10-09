extends "res://tests/shots/birds_xr.gd"
## Round-4 engineering verifier probe (birds): the builder's XR scene
## (tests/shots/birds_xr.gd, same 60 birds and canaries), but timing the REAL
## BirdBatch.sync_all through its own frame_pre_draw hook. The builder's shot
## replaces that hook with a hand-written copy of sync_all (_timed_sync) so it
## can time each bird; a copy can drift from the code that ships. Here the
## shipped hook runs and its own BirdBatch.last_sync_usec / last_phases are
## recorded right after it.
##
##   tools/xr.sh 40 res://tests/probes/birds/birds_r4eng_xr.tscn
##   tools/gd.sh birds_verify2 --rendering-method mobile --resolution 1280x960 \
##       res://tests/probes/birds/birds_r4eng_xr.tscn -- --desktop_quit=14
##
## Writes artifacts/birds/verify/r4eng_xr_perf_<xr|desktop>.json.


func _ready() -> void:
	super._ready()
	# Undo the shot's replacement: the shipped hook, then the canary after it.
	RenderingServer.frame_pre_draw.disconnect(_timed_sync)
	RenderingServer.frame_pre_draw.disconnect(_canary_after)
	RenderingServer.frame_pre_draw.connect(Callable(BirdBatch, &"_on_frame_pre_draw"))
	RenderingServer.frame_pre_draw.connect(_canary_after)
	print("[birds] r4eng xr probe: timing the shipped BirdBatch.sync_all hook")


func _canary_after() -> void:
	if _t > WARMUP:
		_sync.append(BirdBatch.last_sync_usec)
		_ph0.append(BirdBatch.last_phases.x)
		_ph1.append(BirdBatch.last_phases.y)
		_ph2.append(BirdBatch.last_phases.z)
		# Per-bird ticks are not timed here (the shipped code has no hooks).
		_bird_med.append(0)
		_bird_max.append(0)
	super._canary_after()


func _report() -> bool:
	var med := _q(_sync, 0.5)
	var slow := 0
	var r_before := PackedFloat32Array()
	var r_after := PackedFloat32Array()
	var mb := maxf(_q(_before, 0.5), 1.0)
	var ma := maxf(_q(_after, 0.5), 1.0)
	var n := mini(_sync.size(), _before.size())
	for i in n:
		if _sync[i] > 1.8 * med:
			slow += 1
			r_before.append(_before[i] / mb)
			r_after.append(_after[i] / ma)
	var mean := func(a: PackedFloat32Array) -> float:
		var t := 0.0
		for x in a:
			t += x
		return snappedf(t / maxf(a.size(), 1), 0.01)
	var fs := Array(_fps)
	fs.sort()
	var p95 := _q(_sync, 0.95)
	var rep := {
		"probe": "r4eng: shipped BirdBatch.sync_all hook",
		"mode": "xr" if get_viewport().use_xr else "desktop",
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"seconds": snappedf(_t, 0.1), "frames_measured": _sync.size(), "birds": _models.size(),
		"fps_median": fs[fs.size() / 2] if not fs.is_empty() else -1.0,
		"draw_calls_median": _q(_draws, 0.5), "primitives_median": _q(_prims, 0.5),
		"frames_with_a_model_in_the_wrong_batch": _bad_lod, "markers": BirdBatch.marker_total(),
		"sync_us": {"median": med, "p95": p95, "p99": _q(_sync, 0.99), "max": _q(_sync, 1.0)},
		"phases_us_median_p95": {"ticks_and_writes": [_q(_ph0, 0.5), _q(_ph0, 0.95)],
			"lod_moves_and_markers": [_q(_ph1, 0.5), _q(_ph1, 0.95)], "uploads": [_q(_ph2, 0.5), _q(_ph2, 0.95)]},
		"canary_before_us": [_q(_before, 0.5), _q(_before, 0.95)], "canary_after_us": [_q(_after, 0.5), _q(_after, 0.95)],
		"slow_frames": {"count": slow, "of": n, "canary_before_x_median": mean.call(r_before),
			"canary_after_x_median": mean.call(r_after)},
		"p95_limit_us": P95_LIMIT, "pass": p95 < P95_LIMIT and _bad_lod == 0,
	}
	var f := FileAccess.open(Paths.artifacts("birds/verify").path_join("r4eng_xr_perf_%s.json" % rep["mode"]), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rep, "  "))
	print("[birds] r4eng xr probe (%s): shipped sync median %d us, p95 %d, p99 %d, max %d; slow %d/%d (before x%.2f, after x%.2f); markers %d; %s" % [
		rep["mode"], med, p95, rep["sync_us"]["p99"], rep["sync_us"]["max"], slow, n,
		rep["slow_frames"]["canary_before_x_median"], rep["slow_frames"]["canary_after_x_median"],
		rep["markers"], "PASS" if rep["pass"] else "FAIL"])
	return rep["pass"]
