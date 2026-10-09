extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## Does growth change the game? At sparrow, starling, pigeon, hawk and eagle
## size (mass set through GameLoop's own mass path): what the target cue
## names, what threatens, how many worthwhile prey / threats are around, how
## the sky's plan re-balances, and how the real bird flies (cruise speed,
## a full-input turn's rate and radius) with the bot's arms.
##
##   tools/gd.sh pxv_grow --headless --fixed-fps 72 res://tests/probes/integration/px_grow.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var out := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	var main := kit.main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	main.ui.onboarding.skip()
	kit.fly_bot(5)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	var p := main.player
	var sizes := [["sparrow", 0.03], ["starling", 0.1], ["pigeon", 0.3], ["hawk", 1.3], ["eagle", 3.0]]
	for sz: Array in sizes:
		var m := float(sz[1])
		main.game_loop._set_player_mass(p, m, &"probe")
		main.game_loop.set_protection(p, 1e6)
		kit.orbit_radius = 110.0 + 60.0 * log(m / 0.03) / log(100.0)
		kit.pilot.set(&"agl", 30.0 + 15.0 * log(m / 0.03) / log(100.0))
		kit.cruise()
		await kit.advance(25.0)
		var tgt := {}
		var thr := {}
		var n_t := 0
		var n := 0
		var as_sum := 0.0
		var worth_near := 0.0
		var threat_near := 0.0
		var edible_near := 0.0
		for i in 60:
			await kit.advance(1.0)
			var st := kit.stats()
			var t: Bird = st["target"]
			var h: Bird = st["threat"]
			if t != null and is_instance_valid(t):
				tgt[String(t.species)] = int(tgt.get(String(t.species), 0)) + 1
				n_t += 1
			if h != null and is_instance_valid(h) and float(st["threat_level"]) > 0.1:
				thr[String(h.species)] = int(thr.get(String(h.species), 0)) + 1
			as_sum += float(p.telemetry()["airspeed"])
			n += 1
			var w := 0
			var th := 0
			var ed := 0
			for b in main.ecosystem.get_npcs():
				if not is_instance_valid(b) or not b.alive:
					continue
				if b.global_position.distance_to(p.global_position) > 150.0:
					continue
				if SizeRules.can_eat(p.mass, b.mass):
					ed += 1
					if SizeRules.is_worthwhile(p.mass, b.mass):
						w += 1
				if SizeRules.can_eat(b.mass, p.mass):
					th += 1
			worth_near += w
			edible_near += ed
			threat_near += th
		# A full-input turn with the bot's arms (roll 0.8), 6 s.
		kit.fly_straight()
		kit.set_mode(&"turn")
		await kit.advance(1.5)
		var yaw_sum := 0.0
		var v_sum := 0.0
		var bank_max := 0.0
		for i in 288:
			await get_tree().physics_frame
			v_sum += Vector2(p.velocity.x, p.velocity.z).length()
			bank_max = maxf(bank_max, absf(float(p.telemetry()["bank"])))
			yaw_sum += absf(float(p.telemetry()["yaw_rate"])) / 72.0
		var rate := yaw_sum / 4.0
		kit.set_mode(&"cruise")
		kit.cruise()
		var eco: Dictionary = main.ecosystem.stats()
		out[sz[0]] = {"mass": m, "species_now": String(p.species), "world_scale": snappedf(p.origin.world_scale, 0.001),
			"span": snappedf(p.get_wingspan(), 0.01), "cruise_airspeed_mean": snappedf(as_sum / n, 0.01),
			"target_present_frac": snappedf(float(n_t) / n, 0.01), "target_species": tgt, "threat_species": thr,
			"worthwhile_within_150m_mean": snappedf(worth_near / n, 0.1), "edible_within_150m_mean": snappedf(edible_near / n, 0.1),
			"threats_within_150m_mean": snappedf(threat_near / n, 0.1),
			"turn_ground_speed_mean": snappedf(v_sum / 288.0, 0.01), "turn_bank_max_deg": snappedf(rad_to_deg(bank_max), 0.1),
			"turn_rate_deg_s": snappedf(rad_to_deg(rate), 0.1), "turn_radius_m": snappedf((v_sum / 288.0) / maxf(rate, 1e-3), 0.1),
			"worthwhile_species": kit.stats()["worthwhile_species"], "danger_species": kit.stats()["danger_species"],
			"eco_plan": eco.get("plan", {}), "eco_by_species": eco.get("by_species", {})}
		print("[integration] px_grow %s: %s" % [sz[0], out[sz[0]]])
	out["errors"] = kit.log.errors
	out["log"] = kit.log.samples
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_grow.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_grow done %s" % kit.log.summary())
	await kit.teardown()
	get_tree().quit()
