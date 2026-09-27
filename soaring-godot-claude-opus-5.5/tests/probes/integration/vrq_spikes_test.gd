extends TestCase
## VERIFIER PROBE (integration verify round 1, Quest-readiness lens). Not
## part of any area suite. The Quest estimate in docs/INTEGRATION.md is a
## MEAN (game logic per frame x 3-4). A headset drops a frame whenever ONE
## frame misses 13.9 ms, so the tail matters: this measures the whole
## main-thread cost of every frame of the shipped main.tscn, headless with
## --fixed-fps 72 (one physics tick per frame, frames back to back, so the
## wall time between frames is the engine's full CPU cost of a frame minus
## rendering), the bot flying (integration's kit), and reports the tail
## (p99, p99.9, max, frames over the M1-equivalent of the Quest budget) plus
## the Ecosystem's own per-tick max. Run once per quality tier:
##
##   tools/gd.sh vrq --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=vrq_spikes --fresh-settings [--quality=quest]

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _window(label: String, seconds: float, out: Dictionary) -> void:
	var m := kit.main
	var iv := PackedFloat32Array()
	var prev := Time.get_ticks_usec()
	var worst := []
	var t0 := Time.get_ticks_msec()
	var n := int(seconds * 72.0)
	for i in n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - prev) / 1000.0
		prev = now
		iv.append(ms)
		if ms > 3.0:
			worst.append([snappedf(ms, 0.01), i, String(m.player.mode_name()), m.ui.hud_panel.is_rendering_enabled()])
		if i % 144 == 0 and i > 0:
			# The pilot's target moves round (turns, chases).
			var p := m.player
			var yaw := p.rig_yaw + (PI * 0.5 if (i / 144) % 2 == 0 else -PI * 0.7)
			kit.chase(p.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 80.0)
	var v := iv.duplicate()
	v.sort()
	var pct := func(q: float) -> float: return snappedf(v[clampi(int(ceil(q * v.size())) - 1, 0, v.size() - 1)], 0.001)
	var over := {"2.5ms": 0, "3.0ms": 0, "4.0ms": 0, "5.0ms": 0}
	for x in v:
		for k in over:
			if x > float(String(k).trim_suffix("ms")):
				over[k] += 1
	var st: Dictionary = m.ecosystem.stats()
	worst.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	out[label] = {"frames": v.size(), "mean": snappedf(Array(v).reduce(func(a, b): return a + b, 0.0) / v.size(), 0.001),
		"p50": pct.call(0.5), "p95": pct.call(0.95), "p99": pct.call(0.99), "p999": pct.call(0.999), "max": snappedf(v[v.size() - 1], 0.01),
		"frames_over": over, "eco_tick_ms": [st.get("tick_ms_avg"), st.get("tick_ms_p95"), st.get("tick_ms_max")],
		"npcs": m.ecosystem.count(), "worst10": worst.slice(0, 10), "wall_s": (Time.get_ticks_msec() - t0) / 1000.0}


func test_frame_tail() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot()
	kit.cruise()
	await kit.advance(5.0)
	var out := {"quality": m.quality.describe()}
	await _window("sparrow", 60.0, out)
	for sp: StringName in [&"pigeon", &"eagle"]:
		m.game_loop.call(&"_set_player_mass", m.player, float(SizeRules.species_data(sp)["mass"]) * 1.02, &"meal")
		await kit.advance(6.0)
		await _window(String(sp), 30.0, out)
	var la: Array = []
	OS.execute("sysctl", ["-n", "vm.loadavg"], la)
	out["load"] = String(la[0]).strip_edges() if not la.is_empty() else ""
	metric("tail", out)
	print("[integration-verify] tail ", JSON.stringify(out))
	check(true, "measured")
