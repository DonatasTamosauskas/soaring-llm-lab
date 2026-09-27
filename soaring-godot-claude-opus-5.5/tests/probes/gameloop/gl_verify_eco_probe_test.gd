extends TestCase
## Verifier probe (gameloop, round 1): does the real GameLoop catch rule let
## the AI area's real Ecosystem produce NPC-vs-NPC catches ("the world should
## feel alive; enemies target each other")? Same arena/seed as the AI soak,
## resolved once by GameLoop and once by the AI's own test stand-in
## (CatchChecker: body contact, no aim cone). Informational: depends on
## another area's in-progress code. Run with:
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=gl_verify_eco

const DT := 1.0 / 72.0
const SIM_S := 300.0
const REC := "user://gameloop_verify_eco_probe_records.cfg"


func _run(resolver: String) -> Dictionary:
	var w := AiTestWorld.new()
	w.world_seed = 1
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	for i in 3:
		await get_tree().physics_frame
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	e.max_npcs = 60
	e.rng_seed = 7
	add_child(e)
	var loop: GameLoop = null
	var chk: RefCounted = null
	var by_pred := {}
	var n := [0]
	var cb := func(pred: Bird, _q: Bird) -> void:
		n[0] += 1
		by_pred[pred.species] = int(by_pred.get(pred.species, 0)) + 1
	if resolver == "gameloop":
		loop = GameLoop.new()
		loop.auto_step = false
		loop.verbose = false
		loop.records_path = REC
		add_child(loop)
		Events.bird_caught.connect(cb)
	else:
		chk = (load("res://tests/unit/ai/catch_checker.gd") as GDScript).new()
	var t0 := Time.get_ticks_msec()
	for i in int(SIM_S / DT):
		e.step(DT)
		if loop:
			loop.step(DT)
		else:
			chk.call(&"step", DT)
	var out := {"catches": n[0], "by_predator": by_pred, "wall_s": (Time.get_ticks_msec() - t0) / 1000.0}
	if chk:
		var cs: Array = chk.get(&"catches")
		out["catches"] = cs.size()
		var bp := {}
		for c: Dictionary in cs:
			bp[c.get("pred_species", &"?")] = int(bp.get(c.get("pred_species", &"?"), 0)) + 1
		out["by_predator"] = bp
	if loop:
		Events.bird_caught.disconnect(cb)
		loop.queue_free()
	e.queue_free()
	w.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))
	return out


func test_npc_catches_with_real_gameloop() -> void:
	var r: Dictionary = await _run("gameloop")
	metric("result", r)
	print("[gameloop-verify] real GameLoop, %d s: %s" % [SIM_S, r])
	check(true, "measurement")


func test_npc_catches_with_ai_stand_in() -> void:
	var r: Dictionary = await _run("checker")
	metric("result", r)
	print("[gameloop-verify] AI CatchChecker, %d s: %s" % [SIM_S, r])
	check(true, "measurement")
