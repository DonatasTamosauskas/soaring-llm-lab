extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A6/A7 as the player experiences them). The builder's
## ecosystem test counts any bird that *can* eat the player as a "threat"
## within 200 m and any worthwhile prey within 150 m. Here, per player tier
## (mass held 60 s per stage, mock player flying laps like the builder's):
##  * effective threats: can eat the player AND the player is worthwhile to
##    it AND it has a hunt drive (i.e. it would ever actually attack);
##  * visible prey: worthwhile prey close enough to be seen in the headset
##    (distance < 250 x its wingspan ~ 4 px on a Quest Pro at ~18 px/deg);
##  * how often NPCs actually start a hunt on the player, and flee from it;
##  * how many NPCs are within 50 m / 100 m.

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const STAGES := [0.03, 0.1, 0.3, 0.5, 0.85, 1.3, 3.0, 4.5]
const STAGE_S := 60.0


func _run(seed_value: int, path_r: float, speed: float, tag: String) -> Dictionary:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = STAGES[0]
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = path_r
	p.path_height = 30.0
	p.speed = speed
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_value)
	e.focus = p
	var chk := make_checker()
	var safety := Safety.new(world)
	var out := {}
	var hunting := {}
	var fleeing := {}
	for si in STAGES.size():
		var pm: float = STAGES[si]
		p.mass = pm
		var s := {"samples": 0, "eff_threat_any": 0, "nom_threat_any": 0, "vis_prey_any": 0, "prey150_ge2": 0,
			"within50": 0.0, "within100": 0.0, "eff_threat_n": 0.0, "vis_prey_n": 0.0,
			"hunts_on_player": 0, "flees_from_player": 0, "player_contacts": 0}
		var c0 := 0
		for c in chk.catches:
			if c["prey"] == p:
				c0 += 1
		for i in int(STAGE_S / DT):
			p.step(DT)
			e.step(DT)
			chk.step(DT)
			safety.step(DT, e.get_npcs())
			for n in e.get_npcs():
				var id := n.get_instance_id()
				var ht := n.target == p
				if ht and not hunting.get(id, false):
					s["hunts_on_player"] += 1
				hunting[id] = ht
				var ft := n.threat == p
				if ft and not fleeing.get(id, false):
					s["flees_from_player"] += 1
				fleeing[id] = ft
			if i % 36 == 0 and i * DT > 10.0:
				s["samples"] += 1
				var pp := p.get_body_position()
				var eff := 0
				var nom := 0
				var vis := 0
				var p150 := 0
				var w50 := 0
				var w100 := 0
				for n in e.get_npcs():
					var d := n.global_position.distance_to(pp)
					var dh := Vector2(n.global_position.x - pp.x, n.global_position.z - pp.z).length()
					if d < 50.0:
						w50 += 1
					if d < 100.0:
						w100 += 1
					if SizeRules.can_eat(n.mass, pm) and dh < 200.0:
						nom += 1
						if SizeRules.is_worthwhile(n.mass, pm) and float(SpeciesProfile.of(n.species)["hunt"]) > 0.0:
							eff += 1
					if SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass):
						if dh < 150.0:
							p150 += 1
						if d < minf(150.0, 250.0 * n.get_wingspan()):
							vis += 1
				s["eff_threat_any"] += 1 if eff > 0 else 0
				s["nom_threat_any"] += 1 if nom > 0 else 0
				s["vis_prey_any"] += 1 if vis > 0 else 0
				s["prey150_ge2"] += 1 if p150 >= 2 else 0
				s["within50"] += w50
				s["within100"] += w100
				s["eff_threat_n"] += eff
				s["vis_prey_n"] += vis
		var c1 := 0
		for c in chk.catches:
			if c["prey"] == p:
				c1 += 1
		s["player_contacts"] = c1 - c0
		var k: float = maxf(s["samples"], 1)
		var row := {
			"species": String(SizeRules.species_for_mass(pm)),
			"eff_threat_present_share": snappedf(s["eff_threat_any"] / k, 0.01),
			"nominal_threat_present_share": snappedf(s["nom_threat_any"] / k, 0.01),
			"visible_prey_present_share": snappedf(s["vis_prey_any"] / k, 0.01),
			"builder_prey150_ge2_share": snappedf(s["prey150_ge2"] / k, 0.01),
			"mean_eff_threats_200m": snappedf(s["eff_threat_n"] / k, 0.1),
			"mean_visible_prey": snappedf(s["vis_prey_n"] / k, 0.1),
			"mean_npcs_within_50m": snappedf(s["within50"] / k, 0.1),
			"mean_npcs_within_100m": snappedf(s["within100"] / k, 0.1),
			"hunts_on_player_per_min": snappedf(s["hunts_on_player"] / (STAGE_S / 60.0), 0.1),
			"flees_from_player_per_min": snappedf(s["flees_from_player"] / (STAGE_S / 60.0), 0.1),
			"player_contacts": s["player_contacts"],
		}
		out["%.2f" % pm] = row
		print("[ai-verify] %s stage %.2f kg %s: %s" % [tag, pm, row["species"], row])
	out["safety"] = safety.counts
	out["count_end"] = e.count()
	print("[ai-verify] %s safety %s" % [tag, safety.counts])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await clear_sim()
	return out


func test_player_experience_by_tier_builder_path() -> void:
	var r := await _run(5, 110.0, 12.0, "laps110")
	metric("by_tier", r)
	for k in r:
		if r[k] is Dictionary and r[k].has("eff_threat_present_share"):
			gt(r[k]["eff_threat_present_share"], 0.9, "stage %s: a bird that would actually hunt the player is within 200 m" % k)
			gt(r[k]["visible_prey_present_share"], 0.9, "stage %s: worthwhile prey close enough to see" % k)
			gt(r[k]["hunts_on_player_per_min"], 0.5, "stage %s: the player is actually hunted" % k)
	for k in r["safety"]:
		eq(r["safety"][k], 0, "safety %s" % k)


func test_player_experience_by_tier_wide_roamer() -> void:
	var r := await _run(77, 330.0, 15.0, "roam330")
	metric("by_tier", r)
	for k in r:
		if r[k] is Dictionary and r[k].has("eff_threat_present_share"):
			gt(r[k]["eff_threat_present_share"], 0.9, "stage %s: a bird that would actually hunt the player is within 200 m" % k)
			gt(r[k]["visible_prey_present_share"], 0.9, "stage %s: worthwhile prey close enough to see" % k)
	for k in r["safety"]:
		eq(r["safety"][k], 0, "safety %s" % k)
