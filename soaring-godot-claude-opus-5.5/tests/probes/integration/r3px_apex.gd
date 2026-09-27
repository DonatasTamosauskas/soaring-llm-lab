extends Node
## VERIFIER PROBE (integration verify round 3, player-experience lens).
## As an eagle (the apex, 3.0 kg - the tier's own mass) the threat cue and
## danger marks: does anything in the sky read as a danger to the apex?
## Records every threat_changed with its predator's species and mass, and
## the danger-marked birds, while the kit's bot cruises an orbit for 90 s.
##
##   tools/gd.sh r3pxh --headless --fixed-fps 72 res://tests/probes/integration/r3px_apex.tscn -- --fresh-settings
## Output: artifacts/integration/verify/r3px/apex.json

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {"threats": [], "marked": {}}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit(1)
		return
	main = kit.main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	main.game_loop._set_player_mass(main.player, float(Paths.arg("mass", "3.0")), &"probe")
	kit.fly_bot(3)
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	var p := main.player
	out["species"] = String(p.species)
	out["mass"] = p.mass
	Events.threat_changed.connect(func(level: float, pred: Bird) -> void:
		if is_instance_valid(pred):
			out["threats"].append({"level": snappedf(level, 0.01), "species": String(pred.species), "mass": snappedf(pred.mass, 0.001),
				"can_eat": SizeRules.can_eat(pred.mass, p.mass)}))
	var marked := {}
	for i in 90 * 72:
		await get_tree().physics_frame
		if i % 36 == 0:
			for b in main.ecosystem.get_npcs():
				if is_instance_valid(b) and int(ThreatWatch._get_highlight(b)) == 2:
					var k := "%s %.3f" % [b.species, b.mass]
					marked[k] = int(marked.get(k, 0)) + 1
	out["marked"] = marked
	out["run_stats_danger"] = main.game_loop.get_run_stats().get("danger_species")
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r3px/apex_%s.json" % Paths.arg("mass", "3.0")), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("[integration] r3px apex: %d threat events, marked %s, danger species %s" % [out["threats"].size(), marked, out["run_stats_danger"]])
	await kit.teardown()
	get_tree().quit()
