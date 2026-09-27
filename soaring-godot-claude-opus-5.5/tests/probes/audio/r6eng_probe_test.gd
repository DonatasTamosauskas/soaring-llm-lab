extends TestCase
## Round-6 engineering verifier probes for the audio area (not part of the
## audio suite; run with --dir=res://tests/probes/audio --suite=r6eng).
##
##  * Threaded synthesis is deterministic: every procedural clip rendered on
##    all the pool's threads is byte-identical to the same clip rendered on
##    one thread (AudioBank's claim that the designs share no state, which
##    the round-5 move to SYNTH_THREADS relies on; the suite compares only
##    9 clips against the cache).
##  * Rendering the whole job list twice in parallel gives the same bytes
##    (no hidden static state racing between two banks).


func _render(threads: int) -> AudioBank:
	var b := AudioBank.new()
	b.use_cache = false
	b._run_jobs(threads)
	return b


func test_threaded_synthesis_is_deterministic() -> void:
	var t0 := Time.get_ticks_msec()
	var one := _render(1)
	var t1 := Time.get_ticks_msec()
	var many := _render(-1)
	var t2 := Time.get_ticks_msec()
	var keys := one.all_streams().keys()
	keys.sort()
	var diff: Array[String] = []
	var n := 0
	for k in keys:
		var a := one.get_stream(k) as AudioStreamWAV
		var b := many.get_stream(k) as AudioStreamWAV
		if a == null or b == null:
			diff.append("%s missing" % k)
			continue
		n += 1
		if a.data != b.data or a.mix_rate != b.mix_rate or a.stereo != b.stereo or a.loop_end != b.loop_end:
			diff.append(String(k))
	metric("clips_compared", n)
	metric("one_thread_ms", t1 - t0)
	metric("all_threads_ms", t2 - t1)
	print("[audio] r6eng: %d clips, 1 thread %d ms, all threads %d ms, differing: %s" % [n, t1 - t0, t2 - t1, diff])
	eq(n, AudioBank.new().jobs().size(), "every procedural clip rendered")
	eq(diff.size(), 0, "every clip byte-identical between 1 thread and all threads (%s)" % [diff])


func test_two_banks_rendering_at_once_agree() -> void:
	# Two banks' job lists interleaved on the pool at the same time.
	var a := AudioBank.new()
	a.use_cache = false
	var b := AudioBank.new()
	b.use_cache = false
	var ta := WorkerThreadPool.add_task(a._run_jobs.bind(2), false, "probe a")
	var tb := WorkerThreadPool.add_task(b._run_jobs.bind(2), false, "probe b")
	WorkerThreadPool.wait_for_task_completion(ta)
	WorkerThreadPool.wait_for_task_completion(tb)
	var diff: Array[String] = []
	for k in a.all_streams():
		var x := a.get_stream(k) as AudioStreamWAV
		var y := b.get_stream(k) as AudioStreamWAV
		if x == null or y == null or x.data != y.data:
			diff.append(String(k))
	print("[audio] r6eng: concurrent banks differing: %s" % [diff])
	eq(diff.size(), 0, "two banks synthesizing at once produce identical clips (%s)" % [diff])
