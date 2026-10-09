extends TestCase
## VERIFIER PROBE (integration verify round 2; lens: Quest readiness). Not
## part of any suite.
##
## The Quest tier (28 NPCs) of the real main.tscn, a run started through the
## game's bridge, the chase pilot following the target cue. Every frame the
## span of ALL physics callbacks and of ALL process callbacks is measured
## with bracket nodes at the extreme priorities (wall clock on this shared
## Mac: an upper bound). Reported: mean, p50/p95/p99/max per frame, and the
## share of frames whose script time x 3 and x 4 (docs' M1 -> Quest Pro rule)
## would exceed the Quest's frame budget left for scripts at 72 Hz
## (13.9 ms minus ~2 ms of engine/render work = ~11.9 ms).
##
##   GD_TIMEOUT=900 tools/gd.sh r2vq_spk --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r2vq_spikes --fresh-settings --quality=quest
## Output: artifacts/integration/verify/r2vq/spikes_<quality>.json

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
const PLAY_S := 120.0
const BUDGET_MS := 11.9

var kit: Kit
var booted := false


class Bracket:
	extends Node
	var first := true
	var t := 0
	var spans: Array = []
	var peer: Bracket
	var physics := true

	func _init(p_first: bool, p_physics: bool) -> void:
		first = p_first
		physics = p_physics
		process_mode = Node.PROCESS_MODE_ALWAYS
		if physics:
			process_physics_priority = -100000 if first else 100000
		else:
			process_priority = -100000 if first else 100000

	func _physics_process(_dt: float) -> void:
		if not physics:
			return
		_mark()

	func _process(_dt: float) -> void:
		if physics:
			return
		_mark()

	func _mark() -> void:
		var now := Time.get_ticks_usec()
		if first:
			t = now
		elif peer != null and peer.t > 0:
			spans.append((now - peer.t) / 1000.0)


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


static func _stats(a: Array, budget: float) -> Dictionary:
	if a.is_empty():
		return {}
	var v := a.duplicate()
	v.sort()
	var s := 0.0
	for x in v:
		s += float(x)
	var n := v.size()
	var over3 := 0
	var over4 := 0
	for x in v:
		if float(x) * 3.0 > budget:
			over3 += 1
		if float(x) * 4.0 > budget:
			over4 += 1
	return {"n": n, "mean": snappedf(s / n, 0.001), "p50": snappedf(v[n / 2], 0.001), "p95": snappedf(v[int(0.95 * n)], 0.001),
		"p99": snappedf(v[int(0.99 * n)], 0.001), "p999": snappedf(v[mini(n - 1, int(0.999 * n))], 0.001), "max": snappedf(v[n - 1], 0.001),
		"share_over_budget_x3": snappedf(float(over3) / n, 0.0001), "share_over_budget_x4": snappedf(float(over4) / n, 0.0001)}


func test_script_time_per_frame() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var pf := Bracket.new(true, true)
	var pl := Bracket.new(false, true)
	pl.peer = pf
	var qf := Bracket.new(true, false)
	var ql := Bracket.new(false, false)
	ql.peer = qf
	for b in [pf, pl, qf, ql]:
		add_child(b)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(11, ChasePilot)
	var pilot := kit.pilot as ChasePilot
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 110.0
	pf.spans.clear()
	pl.spans.clear()
	ql.spans.clear()
	var totals := []
	var t := 0.0
	var cur: NpcBird = null
	var since := 0.0
	var n_phys0 := 0
	var n_proc0 := 0
	var load0 := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], load0)
	while t < PLAY_S and Game.state != Game.State.ENDED:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		# One frame = one physics tick (fixed fps): pair the spans.
		if pl.spans.size() > n_phys0 and ql.spans.size() > n_proc0:
			totals.append(float(pl.spans[pl.spans.size() - 1]) + float(ql.spans[ql.spans.size() - 1]))
			n_phys0 = pl.spans.size()
			n_proc0 = ql.spans.size()
		if Game.state != Game.State.PLAYING:
			continue
		var tgt: Variant = m.game_loop.get_run_stats().get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if cur != null:
			since += 1.0 / 72.0
			if not is_instance_valid(cur) or not cur.alive or cur.hidden or since > 20.0 or named != cur:
				cur = null
				pilot.stop_chase()
				kit.cruise()
		if cur == null and named != null:
			cur = named
			since = 0.0
			pilot.chase_prey(named)
	var load1 := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], load1)
	var out := {"quality": String(m.quality.name), "npcs": m.ecosystem.count(), "max_npcs": m.ecosystem.max_npcs,
		"play_s": t, "load_before": String(load0[0]).strip_edges() if not load0.is_empty() else "",
		"load_after": String(load1[0]).strip_edges() if not load1.is_empty() else "",
		"physics_callbacks_ms": _stats(pl.spans, BUDGET_MS), "process_callbacks_ms": _stats(ql.spans, BUDGET_MS),
		"scripts_per_frame_ms": _stats(totals, BUDGET_MS), "eco": m.ecosystem.stats().get("tick_ms_p95", -1),
		"catches": m.game_loop.get_run_stats().get("catches", -1)}
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2vq/spikes_%s.json" % m.quality.name), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	print("[integration-verify] spikes: ", JSON.stringify(out))
	check(totals.size() > 1000, "frames measured")
