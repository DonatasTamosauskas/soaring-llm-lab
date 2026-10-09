extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, engineering lens): is Ecosystem.reset(seed)
## reproducible in the shipped valley, where thermals drift with the air
## clock? The contract promises "deterministic with a seed, reset()".
## Ecosystem.reset() re-seeds the RNG and clears its timers, but not
## _thermal_t (the 10-s habitat.refresh_thermals cadence), so after a reset
## the birds re-read the moving thermals at different moments than a fresh
## run does.
## Scenario: a fresh ecosystem (seed 5) round a lapping pigeon-sized mock
## player, air on the sim clock from 0, RUN_S simulated seconds; then
## reset(5) on the same ecosystem, air and player rewound, RUN_S again;
## then a brand-new ecosystem, same seed, RUN_S again. With RUN_S not a
## multiple of 10 s the reset run starts mid-cadence.
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4eng_reset_determinism

const RUN_S := 27.0


func _fp(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func _run(w: World, e: Ecosystem, p: MockPlayer) -> String:
	p.angle = 0.0
	p.step(0.0)
	var n := int(RUN_S / DT)
	for i in n:
		air(w, i * DT)
		p.step(DT)
		e.step(DT)
	return _fp(e)


func _make(w: World, p: MockPlayer) -> Ecosystem:
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 5
	e.max_npcs = 60
	add_child(e)
	e.focus = p
	e.world = w
	e.habitat = Habitat.for_world(w)
	e.habitat.refresh()
	return e


func test_r4_reset_is_reproducible_in_the_valley() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	check(ps != null, "(setup) the valley loads")
	if ps == null:
		return
	var w := ps.instantiate() as World
	add_child(w)
	await wait_physics(3)
	if not w.is_generated:
		await w.generated
	var p := MockPlayer.new()
	p.mass = 0.3
	var c := w.get_player_spawn().origin
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = 60.0
	p.path_height = c.y + 25.0
	p.speed = 10.0
	add_child(p)
	var e := _make(w, p)
	var fp_fresh := _run(w, e, p)
	var th_after_first: float = e._thermal_t
	e.reset(5)
	var fp_reset := _run(w, e, p)
	e.queue_free()
	await wait_frames(2)
	var e2 := _make(w, p)
	var fp_fresh2 := _run(w, e2, p)
	e2.queue_free()
	var out := {"fresh": fp_fresh, "after_reset": fp_reset, "fresh_again": fp_fresh2, "thermal_t_at_reset": th_after_first, "run_s": RUN_S}
	print("[ai-r4eng] reset determinism: ", JSON.stringify(out))
	var dir := Paths.artifacts("ai").path_join("verify/r4eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("reset_determinism.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	eq(fp_fresh2, fp_fresh, "control: two fresh ecosystems with the same seed give the same sky")
	eq(fp_reset, fp_fresh, "reset(seed) gives the same sky as a fresh ecosystem with that seed")
	remove_child(p)
	p.queue_free()
	w.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
