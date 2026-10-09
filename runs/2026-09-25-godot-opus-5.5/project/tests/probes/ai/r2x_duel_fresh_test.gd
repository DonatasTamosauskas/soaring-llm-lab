extends "res://tests/unit/ai/hunt_duel_test.gd"
## VERIFIER PROBE (round 2, experience lens): the A2 duel matrix on a seed
## family nobody tuned against (trial numbers offset by --r2x_offset,
## default 7000; another verifier uses 1000). With --duel_trials >= 40 the
## parent's evidence assertions apply: every calm pair > 80 %, every fleeing
## pair 20-70 %, pooled 20-70 %. Plots are suppressed (they would land in
## the builder's artifacts/ai/duels).
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai \
##       --suite=r2x_duel_fresh --duel_trials=48


func _duel(pred_sp: StringName, prey_sp: StringName, fleeing: bool, trial: int) -> Dictionary:
	return super._duel(pred_sp, prey_sp, fleeing, trial + int(Paths.arg("r2x_offset", "7000")))


func _plot_duel(_tag: String, _a: PackedVector3Array, _b: PackedVector3Array, _marks: Array, _out: Dictionary) -> void:
	pass
