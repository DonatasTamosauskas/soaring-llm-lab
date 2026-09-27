extends TestCase
## The clip bank and its disk cache. The other audio suites measure the
## bank's clips, and on a warm machine those come from the cache, so the
## cache must never hand back a clip the current sources would not make:
##  * the cache key is a hash of every design source (a changed design
##    misses the cache), and every class the designs use is one of them;
##  * cached clips are bit-identical to a fresh synthesis (determinism);
##  * a first launch synthesizes and writes the cache on a worker thread,
##    with next to nothing on the main thread (a Quest drops frames
##    otherwise);
##  * a truncated cache file is detected and rebuilt; old cache folders are
##    pruned.
## Uses a scratch cache folder: the game's own cache is only read.

const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
## Clips synthesized afresh here: one of each design family the other
## suites measure (wingbeat, buffet, heartbeat, moth, starling, crunch) and
## the wind edge; about 0.6 s of synthesis on the dev Mac.
const SUBSET: Array[StringName] = [&"whoosh_2_1", &"wind_edge", &"stall_flutter", &"heartbeat", &"moth_flutter",
	&"starling_1", &"crunch_0", &"puff_2", &"bump"]

var _scratch := ""


func before_all() -> void:
	_scratch = "user://audio_cache_test_%d" % OS.get_process_id()
	_rmdir(_scratch)


func after_all() -> void:
	_rmdir(_scratch)


static func _rmdir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_rmdir(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func test_cache_key_follows_every_design_source() -> void:
	var hashes := PackedStringArray()
	for p in AudioBank.DESIGN_SOURCES:
		check(FileAccess.file_exists(p), "design source %s exists (a renamed file would drop out of the key)" % p)
		hashes.append(AudioBank.source_hash(p))
	eq(AudioBank.cache_key(), AudioBank.key_from(hashes), "the cache key is the hash of the design sources")
	for i in hashes.size():
		var changed := hashes.duplicate()
		changed[i] = "0".repeat(32)
		check(AudioBank.key_from(changed) != AudioBank.cache_key(), "changing %s changes the cache key" % AudioBank.DESIGN_SOURCES[i].get_file())
	# The designs may only depend on hashed sources: every project class the
	# design code names must be one of them.
	var classes := {}
	for c in ProjectSettings.get_global_class_list():
		classes[String(c["class"])] = String(c["path"])
	var unhashed: Array[String] = []
	for p in AudioBank.DESIGN_SOURCES:
		var code := ""
		for line in FileAccess.get_file_as_string(p).split("\n"):
			code += line.get_slice("#", 0) + "\n"  # comments do not count
		var rx := RegEx.create_from_string("\\b([A-Z][A-Za-z0-9_]+)\\b")
		for m in rx.search_all(code):
			var cls := m.get_string(1)
			if classes.has(cls) and not (classes[cls] in AudioBank.DESIGN_SOURCES) and not (cls in unhashed):
				unhashed.append(cls)
	metric("unhashed_classes", unhashed)
	eq(unhashed.size(), 0, "the design code uses no project class outside the hashed sources (%s)" % [unhashed])


func test_first_launch_is_off_the_main_thread_and_matches_the_cache() -> void:
	var log := ErrorLog.install()
	# A first launch into an empty cache, driven like the director drives it.
	var cold := AudioBank.new()
	cold.cache_root = _scratch
	cold.only = SUBSET
	var t0 := Time.get_ticks_usec()
	cold.start_async()
	var start_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var worst_ms := 0.0
	var frames := 0
	var costs := PackedFloat32Array()
	while not cold.is_ready():
		await get_tree().process_frame
		frames += 1
		var t := Time.get_ticks_usec()
		cold.poll()
		for k in SUBSET:
			cold.has(k)
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		costs.append(ms)
		worst_ms = maxf(worst_ms, ms)
	cold.poll()
	var slow := 0
	for ms in costs:
		if ms >= 0.5:
			slow += 1
	metric("start_async_ms", start_ms)
	metric("worst_poll_ms", worst_ms)
	metric("median_poll_ms", AudioAnalysis.median(costs))
	metric("frames_over_0.5ms", slow)
	metric("frames_while_synthesizing", frames)
	metric("synth_ms", cold.synth_ms_total)
	gt(frames, 2.0, "frames keep coming while the worker synthesizes (%.0f ms of synthesis)" % cold.synth_ms_total)
	# Cache writes on the main thread would cost a slow frame per clip (9
	# here). On a machine shared by a dozen processes the OS preempts the
	# main thread now and then: one run under load 10 read 0.69 ms on a
	# single frame (the median was 0.03). So: at most 2 frames of 170 over
	# 0.5 ms, and a median well under it.
	lt(float(slow), 3.0, "the main thread's per-frame bank work stays under 0.5 ms, bar at most 2 preempted frames (cache writes are on the worker; %d over, worst %.2f ms)" % [slow, worst_ms])
	lt(AudioAnalysis.median(costs), 0.1, "the main thread's median per-frame bank work is under 0.1 ms (%.3f)" % AudioAnalysis.median(costs))
	lt(start_ms, 50.0, "starting the build (imported files only) takes under 50 ms")
	# Fresh synthesis == what the other suites measure (the shared bank,
	# from the game's cache when it is warm).
	var shared := AudioBank.acquire(false)
	var same := 0
	for k in SUBSET:
		var a := cold.get_stream(k) as AudioStreamWAV
		var b := shared.get_stream(k) as AudioStreamWAV
		if a != null and b != null and a.data == b.data and a.mix_rate == b.mix_rate and a.stereo == b.stereo \
				and a.loop_mode == b.loop_mode and a.loop_end == b.loop_end:
			same += 1
		else:
			fail("%s: the shared bank's clip differs from a fresh synthesis" % k)
		check(FileAccess.file_exists(cold.clip_path(k)), "%s written to the cache" % k)
	eq(same, SUBSET.size(), "every checked clip is bit-identical to a fresh synthesis")
	check(not cold.frames(&"heartbeat").is_empty(), "the heartbeat's generator frames are ready with its clip")
	# A second launch reads everything back.
	var warm := AudioBank.new()
	warm.cache_root = _scratch
	warm.only = SUBSET
	warm.build_sync()
	eq(warm.cached, SUBSET.size(), "a second launch reads every clip from the cache")
	for k in SUBSET:
		check((warm.get_stream(k) as AudioStreamWAV).data == (cold.get_stream(k) as AudioStreamWAV).data, "%s round-trips the cache" % k)
	# A truncated file (a crash mid-write elsewhere, a full disk) is rebuilt.
	var f := FileAccess.open(cold.clip_path(&"bump"), FileAccess.WRITE)
	f.store_string("SAC1 truncated")
	f.close()
	var healed := AudioBank.new()
	healed.cache_root = _scratch
	healed.only = SUBSET
	healed.build_sync()
	eq(healed.cached, SUBSET.size() - 1, "a truncated clip is not trusted")
	check((healed.get_stream(&"bump") as AudioStreamWAV).data == (cold.get_stream(&"bump") as AudioStreamWAV).data, "and is synthesized again")
	# Old cache folders are pruned: leftovers of the old format (no stamp)
	# always, stamped ones down to the CACHE_KEEP most recently used.
	for i in 4:
		var d := _scratch.path_join("v5_old%d" % i)
		DirAccess.make_dir_recursive_absolute(d)
		FileAccess.open(d.path_join("x.clip"), FileAccess.WRITE).store_string("old")
		FileAccess.open(d.path_join("used.stamp"), FileAccess.WRITE).store_string("0")
	var legacy := _scratch.path_join("v4")
	DirAccess.make_dir_recursive_absolute(legacy)
	FileAccess.open(legacy.path_join("wind_body.res"), FileAccess.WRITE).store_string("old")
	var pruner := AudioBank.new()
	pruner.cache_root = _scratch
	pruner.only = [&"bump"]
	pruner.build_sync()
	eq(DirAccess.get_directories_at(_scratch).size(), AudioBank.CACHE_KEEP, "old cache folders are pruned to %d" % AudioBank.CACHE_KEEP)
	check(DirAccess.dir_exists_absolute(_scratch.path_join(AudioBank.cache_key())), "this build's folder is kept")
	check(not DirAccess.dir_exists_absolute(legacy), "a leftover of the old cache format is removed")
	shared = null
	AudioBank.release()
	log.uninstall()
	eq(log.errors, 0, "no engine or script errors (%s)" % [log.samples])
