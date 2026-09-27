extends TestCase
## PROBE (round-2 engineering verifier, not a unit suite): the TAIL of the
## composed game's per-frame CPU work, not its mean. The builders' Quest
## estimate (docs/INTEGRATION.md §4) is a mean (1.50-1.54 ms on the M1 at the
## Quest tier, x3-4 = 4.5-6.1 ms); a headset drops a frame on the worst
## frames, not the mean one.
##
##   tools/gd.sh v2e_tail --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/integration/r2eng --suite=frame_tail --fresh-settings --quality=quest [--tail_s=180]
##
## Every frame: wall time from the first physics callback (priority -1e6) to
## the end of the last process callback (priority +1e6): every script, the
## physics server step and the message queue (headless: no rendering). The
## game: main.tscn, a run started through the bridge, the lessons skipped,
## the chase pilot following the target cue through the real WingInput
## (as game_catch_test), the real sky and its hunters. Writes
## artifacts/integration/verify/r2eng/frame_tail_<quality>.json.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")

var kit: Kit
var booted := false


class _First:
	extends Node
	var t0 := 0

	func _init() -> void:
		name = "R2TailFirst"
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = -1000000
		process_priority = -1000000

	func _physics_process(_dt: float) -> void:
		if t0 == 0:
			t0 = Time.get_ticks_usec()


class _Last:
	extends Node
	var first: _First
	var samples: PackedInt32Array = PackedInt32Array()
	var npcs: PackedInt32Array = PackedInt32Array()
	var eco: Node
	var on := false

	func _init() -> void:
		name = "R2TailLast"
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = 1000000
		process_priority = 1000000

	func _process(_dt: float) -> void:
		if first.t0 > 0:
			if on:
				samples.append(Time.get_ticks_usec() - first.t0)
				npcs.append(eco.call(&"count") if eco != null else -1)
			first.t0 = 0


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


static func _pct(sorted: Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return float(sorted[mini(sorted.size() - 1, int(floor(q * sorted.size())))])


func test_frame_tail() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var secs := float(Paths.arg("tail_s", "180"))
	var first := _First.new()
	var last := _Last.new()
	last.first = first
	last.eco = m.ecosystem
	get_tree().root.add_child(first)
	get_tree().root.add_child(last)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(int(Paths.arg("tail_seed", "5")), ChasePilot)
	var pilot := kit.pilot as ChasePilot
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	await kit.advance(5.0)
	var out0: Array = []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out0)
	last.on = true
	var cur: NpcBird = null
	var since := 0.0
	var t := 0.0
	var catches := [0]
	var on_caught := func(pred: Bird, _prey: Bird) -> void:
		if pred == m.player:
			catches[0] += 1
	Events.bird_caught.connect(on_caught)
	while t < secs:
		await kit.advance(0.25)
		t += 0.25
		if Game.state == Game.State.ENDED:
			m.game_loop.restart_run()
			continue
		if Game.state != Game.State.PLAYING:
			continue
		var tgt: Variant = m.game_loop.get_run_stats().get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if cur != null:
			since += 0.25
			if not is_instance_valid(cur) or not cur.alive or cur.hidden or since > 20.0 or (named != cur and since > 2.0):
				cur = null
				pilot.stop_chase()
				kit.cruise()
		if cur == null and named != null:
			cur = named
			since = 0.0
			pilot.chase_prey(named)
	last.on = false
	Events.bird_caught.disconnect(on_caught)
	var out1: Array = []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out1)
	var ms: Array = []
	for us in last.samples:
		ms.append(us / 1000.0)
	var sorted := ms.duplicate()
	sorted.sort()
	var mean := 0.0
	for v in ms:
		mean += v
	mean /= maxf(ms.size(), 1.0)
	var over := {}
	for thr in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 8.0]:
		var n := 0
		for v in ms:
			if v > thr:
				n += 1
		over[str(thr)] = n
	var npc_mean := 0.0
	for n in last.npcs:
		npc_mean += n
	npc_mean /= maxf(last.npcs.size(), 1.0)
	# Longest run of consecutive frames over 2.3 ms (a burst of drops).
	var run := 0
	var worst_run := 0
	for v in ms:
		run = run + 1 if v > 2.3 else 0
		worst_run = maxi(worst_run, run)
	var res := {"quality": m.quality.describe(), "frames": ms.size(), "game_s": secs, "catches": catches[0],
		"npcs_mean": snappedf(npc_mean, 0.1), "mean_ms": snappedf(mean, 0.001),
		"p50_ms": _pct(sorted, 0.5), "p90_ms": _pct(sorted, 0.9), "p95_ms": _pct(sorted, 0.95),
		"p99_ms": _pct(sorted, 0.99), "p999_ms": _pct(sorted, 0.999), "max_ms": sorted.back() if not sorted.is_empty() else 0.0,
		"frames_over_ms": over, "worst_run_over_2_3ms": worst_run,
		"loadavg_start": String(out0[0]).strip_edges() if out0.size() > 0 else "", "loadavg_end": String(out1[0]).strip_edges() if out1.size() > 0 else ""}
	print("[r2eng] frame tail: ", JSON.stringify(res))
	var dir := ProjectSettings.globalize_path(Paths.artifacts("integration")).path_join("verify/r2eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("frame_tail_%s.json" % m.quality.name), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
		var f2 := FileAccess.open(dir.path_join("frame_tail_%s_samples.json" % m.quality.name), FileAccess.WRITE)
		f2.store_string(JSON.stringify(ms))
	first.queue_free()
	last.queue_free()
	check(ms.size() > secs * 60.0, "frames measured (%d)" % ms.size())
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
