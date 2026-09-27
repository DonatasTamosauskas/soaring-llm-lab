extends "res://tests/unit/ai/ai_sim.gd"
## COPY of the verifier probe tests/probes/ai/r3e_cooldown_meal_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER PROBE (round 3, engineering lens): the documented fairness rule
## "after a failed chase a hunter leaves the player alone for 40 s"
## (NpcBrain.PLAYER_COOLDOWN_S; AI.md, ARCHITECTURE ai fix round 1) when the
## hunter catches something else in between. NpcBrain.on_ate() clears the
## whole _cooldown dictionary, the player's 40-s entry included, so the only
## thing left between the failed chase and the next attack is digestion
## (12 s x SizeRules.time_scale) and the hunt rest. The builder's own test
## (player_test.test_a_failed_hunter_leaves_the_player_alone_for_a_while)
## has no meal in between.
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3e_cooldown
## Report: artifacts/ai/verify/r3e/cooldown_meal.json

var _open: World


func before_all() -> void:
	_open = await make_open_world()


func after_all() -> void:
	await clear_sim()
	if is_instance_valid(_open):
		_open.queue_free()
	Game.state = Game.State.BOOT


func _case(hunter_sp: StringName, pm: float, meal: bool) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3.ZERO
	p.path_radius = 80.0
	p.path_height = 40.0
	p.speed = minf(SizeRules.cruise_speed(pm), 12.0)
	p.protect_s = 0.0
	add_child(p)
	p.step(0.0)
	Game.state = Game.State.PLAYING
	var hunter := spawn(hunter_sp, p.global_position + Vector3(30, 8, 0), Vector3(-10, 0, 0), _open)
	hunter.can_flee = false
	# Something it ate meanwhile (GameLoop calls on_ate after a catch).
	var snack := spawn(&"moth", Vector3(400, 60, 400), Vector3(0, 0, -3), _open)
	snack.can_flee = false
	snack.can_hunt = false
	var m := {"first": -1.0, "gave_up_at": -1.0, "again": -1.0}
	run(90.0, func(i: int) -> bool:
		var t := i * DT
		p.step(DT)
		hunter.hunger = 1.0
		hunter.energy = 1.0
		if hunter.global_position.distance_to(p.global_position) > 60.0:
			hunter.global_position = p.global_position + Vector3(30, 8, 0)
		if hunter.target == p:
			if m["first"] < 0.0:
				m["first"] = t
			elif m["gave_up_at"] >= 0.0 and m["again"] < 0.0:
				m["again"] = t
				return true
			if m["gave_up_at"] < 0.0 and t > m["first"] + 1.0:
				hunter.brain.give_up_reason = "timeout"
				hunter.brain._give_up_hunt()
				m["gave_up_at"] = t
				if meal:
					hunter.on_ate(snack, 0.0)
		return false)
	var row := {"hunter": String(hunter_sp), "player_mass": pm, "meal_in_between": meal,
		"first_s": snappedf(m["first"], 0.01), "gave_up_s": snappedf(m["gave_up_at"], 0.01),
		"retry_gap_s": snappedf(float(m["again"]) - float(m["gave_up_at"]), 0.1) if m["again"] >= 0.0 else -1.0,
		"digest_s": snappedf(NpcBird.DIGEST_S * SizeRules.time_scale(hunter.mass), 0.1)}
	print("[ai] r3e cooldown %s" % JSON.stringify(row))
	despawn(hunter)
	despawn(snack)
	remove_child(p)
	p.queue_free()
	Game.state = Game.State.BOOT
	await wait_frames(1)
	return row


func test_player_cooldown_survives_a_meal() -> void:
	var rows := []
	for c in [[&"swallow", 0.03, false], [&"swallow", 0.03, true], [&"hawk", 0.35, true]]:
		var r: Dictionary = await _case(c[0], c[1], c[2])
		rows.append(r)
		check(r["gave_up_s"] >= 0.0, "(setup) %s went for the player and gave up" % r["hunter"])
		if r["retry_gap_s"] >= 0.0:
			gt(r["retry_gap_s"], 39.5, "%s (meal in between: %s) leaves the player alone for the 40-s cool-down" % [r["hunter"], r["meal_in_between"]])
	metric("cooldown_meal", rows)
	var f := FileAccess.open(Paths.artifacts("ai/fix_r3/verifier_probes").path_join("cooldown_meal.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
