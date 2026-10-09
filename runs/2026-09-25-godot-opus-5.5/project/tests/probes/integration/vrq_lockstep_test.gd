extends TestCase
## VERIFIER PROBE (integration verify round 1, Quest-readiness lens). Not
## part of any area suite. Are the far NPCs' reduced-rate steps staggered,
## or do they all run on the same physics tick (a periodic frame-cost
## spike)? NpcBird.tick steps a far bird every 2nd/3rd tick with a private
## _skip counter that starts at the same value for every bird spawned in
## the same tick (the whole initial sky spawns in one). This reads the
## Ecosystem's own per-tick cost ring (last 600 ticks) and averages it by
## tick phase (mod 2, mod 3, mod 6), and counts which phase each far bird
## steps on.
##
##   tools/gd.sh vrq --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=vrq_lockstep --fresh-settings [--quality=quest]

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


func test_far_bird_steps_are_staggered() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot()
	kit.cruise()
	await kit.advance(12.0)
	var eco := m.ecosystem
	# Which tick phase each far bird's next full step falls on.
	var phases := {}
	var lods := {}
	for n in eco.get_children():
		if n is NpcBird:
			var b := n as NpcBird
			lods[str(b.lod)] = int(lods.get(str(b.lod), 0)) + 1
			var sk := int(b.get("_skip"))
			var key := "lod%d_skip%d" % [b.lod, sk]
			phases[key] = int(phases.get(key, 0)) + 1
	var ring: Array = eco.get("_tick_us")
	var i0: int = int(eco.get("_tick_i"))
	var seq := []
	for k in ring.size():
		seq.append(ring[(i0 + k) % ring.size()])
	var by := {}
	for mod in [2, 3, 6]:
		var sums := []
		var cnt := []
		for r in mod:
			sums.append(0.0)
			cnt.append(0)
		for k in seq.size():
			sums[k % mod] += float(seq[k])
			cnt[k % mod] += 1
		var means := []
		for r in mod:
			means.append(snappedf(sums[r] / maxf(cnt[r], 1) / 1000.0, 0.001))
		by["mod%d_ms" % mod] = means
	var sorted := seq.duplicate()
	sorted.sort()
	var out := {"quality": m.quality.name, "npcs": eco.count(), "lods": lods, "skip_phases": phases, "eco_tick_ms_by_phase": by,
		"eco_p50_ms": float(sorted[sorted.size() / 2]) / 1000.0, "eco_max_ms": float(sorted[sorted.size() - 1]) / 1000.0,
		"first_60_ticks_us": seq.slice(seq.size() - 60)}
	metric("lockstep", out)
	print("[integration-verify] lockstep ", JSON.stringify(out))
	check(true, "measured")
