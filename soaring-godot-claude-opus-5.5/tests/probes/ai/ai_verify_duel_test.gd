extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A2): the builder's duel test uses 5 pairs and one fixed
## seed family. Here: the same 5 pairs with fresh seeds (trial offset 1000),
## plus 8 predator>prey pairs the builder never tried, 16 trials each.
## Criterion: > 80% vs non-fleeing prey, 20-70% vs fleeing prey.

const PAIRS_NEW := [
	[&"wren", &"moth"], [&"swallow", &"wren"], [&"starling", &"swallow"],
	[&"pigeon", &"swallow"], [&"crow", &"pigeon"], [&"gull", &"crow"],
	[&"hawk", &"crow"], [&"eagle", &"hawk"],
]
const PAIRS_OLD := [
	[&"sparrow", &"moth"], [&"starling", &"sparrow"], [&"crow", &"starling"],
	[&"hawk", &"pigeon"], [&"eagle", &"gull"],
]
const TRIALS := 16
const MAX_S := 30.0

var _open: World


func before_all() -> void:
	_open = await make_open_world()


func after_all() -> void:
	await clear_sim()
	if is_instance_valid(_open):
		_open.queue_free()


func _duel(pred_sp: StringName, prey_sp: StringName, fleeing: bool, trial: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([String(pred_sp), String(prey_sp), fleeing, trial, "verify"])
	_seed = rng.seed % 100000
	var prey_pos := Vector3(rng.randf_range(-20, 20), 40.0, rng.randf_range(-20, 20))
	var a := rng.randf() * TAU
	var prey_dir := Vector3(cos(a), 0, sin(a))
	var prey := spawn(prey_sp, prey_pos, prey_dir * SizeRules.performance(SizeRules.species_data(prey_sp)["mass"])["cruise"], _open)
	prey.can_hunt = false
	prey.can_flee = fleeing
	prey.home = Vector3(prey_pos.x, 0, prey_pos.z)
	var bearing := rng.randf() * TAU
	var pred_prof := SpeciesProfile.of(pred_sp)
	var dist := rng.randf_range(0.55, 0.9) * float(pred_prof["hunt_range_m"])
	var height := rng.randf_range(-5.0, 10.0)
	if pred_prof["stoop"] and trial % 2 == 0:
		height = rng.randf_range(25.0, 45.0)
	var pred_pos := prey_pos + Vector3(cos(bearing) * dist, height, sin(bearing) * dist)
	var to := prey_pos - pred_pos
	to.y = 0.0
	var pred := spawn(pred_sp, pred_pos, to.normalized() * SizeRules.performance(SizeRules.species_data(pred_sp)["mass"])["cruise"], _open)
	pred.can_flee = false
	pred.hunger = 1.0
	pred.brain._pending_prey = prey
	pred.brain._enter(NpcBird.State.HUNT)
	var started := pred.state == NpcBird.State.HUNT or pred.state == NpcBird.State.STOOP
	make_checker()
	var out := {"caught": false, "reason": "timeout", "started": started}
	run(MAX_S, func(i: int) -> bool:
		if not prey.alive:
			out["caught"] = true
			out["reason"] = "caught"
			return true
		if pred.state != NpcBird.State.HUNT and pred.state != NpcBird.State.STOOP:
			out["reason"] = pred.brain.give_up_reason
			return true
		return false)
	for b in [prey, pred]:
		despawn(b)
	checker = null
	return out


func _series(pairs: Array, fleeing: bool, offset: int) -> Dictionary:
	var table := {}
	for pair in pairs:
		var n := 0
		var reasons := {}
		var not_started := 0
		for t in TRIALS:
			var r := _duel(pair[0], pair[1], fleeing, t + offset)
			if not r["started"]:
				not_started += 1
			if r["caught"]:
				n += 1
			reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
		await wait_frames(1)
		var key := "%s>%s" % [pair[0], pair[1]]
		table[key] = {"rate": float(n) / TRIALS, "reasons": reasons, "not_started": not_started}
		print("[ai-verify] duel %s fleeing=%s: %d/%d %s not_started=%d" % [key, fleeing, n, TRIALS, reasons, not_started])
	return table


func test_new_pairs_calm() -> void:
	var t := await _series(PAIRS_NEW, false, 0)
	metric("rates", t)
	for k in t:
		gt(t[k]["rate"], 0.8, "%s vs non-fleeing prey" % k)


func test_new_pairs_fleeing() -> void:
	var t := await _series(PAIRS_NEW, true, 0)
	metric("rates", t)
	for k in t:
		between(t[k]["rate"], 0.2, 0.7, "%s vs fleeing prey" % k)


func test_old_pairs_new_seeds_calm() -> void:
	var t := await _series(PAIRS_OLD, false, 1000)
	metric("rates", t)
	for k in t:
		gt(t[k]["rate"], 0.8, "%s vs non-fleeing prey (new seeds)" % k)


func test_old_pairs_new_seeds_fleeing() -> void:
	var t := await _series(PAIRS_OLD, true, 1000)
	metric("rates", t)
	for k in t:
		between(t[k]["rate"], 0.2, 0.7, "%s vs fleeing prey (new seeds)" % k)


## Borderline pairs re-run with 40 fresh trials each (offset 5000) to tell
## noise from a real miss.
func test_borderline_pairs_40_trials() -> void:
	var calm := {}
	for pair in [[&"wren", &"moth"], [&"swallow", &"wren"]]:
		var n := 0
		var reasons := {}
		for t in 40:
			var r := _duel(pair[0], pair[1], false, 5000 + t)
			n += 1 if r["caught"] else 0
			reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
		calm["%s>%s" % pair] = [n, reasons]
		print("[ai-verify] 40-trial calm %s>%s: %d/40 %s" % [pair[0], pair[1], n, reasons])
		gt(n / 40.0, 0.8, "%s>%s vs non-fleeing prey (40 trials)" % pair)
	for pair in [[&"starling", &"swallow"], [&"pigeon", &"swallow"], [&"crow", &"pigeon"]]:
		var n := 0
		var reasons := {}
		for t in 40:
			var r := _duel(pair[0], pair[1], true, 5000 + t)
			n += 1 if r["caught"] else 0
			reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
		print("[ai-verify] 40-trial flee %s>%s: %d/40 %s" % [pair[0], pair[1], n, reasons])
		between(n / 40.0, 0.2, 0.7, "%s>%s vs fleeing prey (40 trials)" % pair)
