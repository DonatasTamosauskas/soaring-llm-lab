extends "res://tests/unit/ai/hunt_duel_test.gd"
## VERIFIER PROBE (round 2, engineering lens): the builder's A2 duel matrix
## re-run on an independent seed family (trial numbers offset by
## --duel_seed_offset, default 1000), so the evidence does not rest on the
## one seed family the builder tuned against. Same pairs, same assertions
## (with --duel_trials >= 40 every pair's rate must lie in 20-70% and every
## calm pair above 80%).
##   run from a private scratch copy with --dir=res://tests/probes/ai
##   --suite=ai_v2r_duel_seeds --duel_trials=48


func _duel(pred_sp: StringName, prey_sp: StringName, fleeing: bool, trial: int) -> Dictionary:
	var off := int(Paths.arg("duel_seed_offset", "1000"))
	return super._duel(pred_sp, prey_sp, fleeing, trial + off)
