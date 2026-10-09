extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A6 for a player who travels). A flying player does not
## orbit a fixed spot: it crosses the valley. The Ecosystem homes follow a
## 20 s moving average of the player's position, which lags a travelling
## player by ~speed x 20 s (240 m at 12 m/s). This flies a mock player
## back and forth across the AI test world (straight legs, 12 m/s, 30 m up)
## as a sparrow, a pigeon and a hawk, and measures what is actually around
## it: NPCs within 50/100 m, worthwhile prey within 60 m, birds that would
## hunt it within 100 m, and the builder's own metrics (>= 2 worthwhile prey
## within 150 m horizontally, >= 1 threat within 200 m).

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")


class Traveller extends Bird:
	var a := Vector3(-330, 30, 0)
	var b := Vector3(330, 30, 0)
	var speed := 12.0
	var s := 0.0
	var dir := 1.0
	func is_player() -> bool:
		return true
	func get_view_direction() -> Vector3:
		return velocity.normalized() if velocity.length() > 0.1 else Vector3.FORWARD
	func step(dt: float) -> void:
		var L := a.distance_to(b)
		s += dir * speed * dt
		if s > L:
			s = L
			dir = -1.0
		elif s < 0.0:
			s = 0.0
			dir = 1.0
		var d := (b - a).normalized() * dir
		velocity = d * speed
		global_transform = Transform3D(Basis.looking_at(d, Vector3.UP), a.lerp(b, s / L))


func _stage(pm: float, seconds: float, seed_value: int) -> Dictionary:
	await make_world(false, 1)
	var p := Traveller.new()
	p.mass = pm
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_value)
	e.focus = p
	var safety := Safety.new(world)
	var s := {"n": 0, "any50": 0, "n50": 0.0, "n100": 0.0, "prey60": 0, "hunter100": 0, "b_prey": 0, "b_threat": 0, "far_despawns": 0}
	e.npc_despawned.connect(func(_n: NpcBird, reason: StringName) -> void:
		if reason == &"far":
			s["far_despawns"] += 1)
	for i in int(seconds / DT):
		p.step(DT)
		e.step(DT)
		safety.step(DT, e.get_npcs())
		if i % 36 == 0 and i * DT > 30.0:
			s["n"] += 1
			var pp := p.get_body_position()
			var n50 := 0
			var n100 := 0
			var prey60 := 0
			var hunter := 0
			var bprey := 0
			var bthreat := 0
			for n in e.get_npcs():
				var d := n.global_position.distance_to(pp)
				var dh := Vector2(n.global_position.x - pp.x, n.global_position.z - pp.z).length()
				n50 += 1 if d < 50.0 else 0
				n100 += 1 if d < 100.0 else 0
				var edible := SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)
				if edible and d < 60.0:
					prey60 += 1
				if edible and dh < 150.0:
					bprey += 1
				if SizeRules.can_eat(n.mass, pm):
					if dh < 200.0:
						bthreat += 1
					if d < 100.0 and SizeRules.is_worthwhile(n.mass, pm) and float(SpeciesProfile.of(n.species)["hunt"]) > 0.0:
						hunter += 1
			s["any50"] += 1 if n50 > 0 else 0
			s["n50"] += n50
			s["n100"] += n100
			s["prey60"] += 1 if prey60 > 0 else 0
			s["hunter100"] += 1 if hunter > 0 else 0
			s["b_prey"] += 1 if bprey >= 2 else 0
			s["b_threat"] += 1 if bthreat >= 1 else 0
	var k: float = maxf(s["n"], 1)
	var out := {
		"species": String(SizeRules.species_for_mass(pm)),
		"share_any_npc_within_50m": snappedf(s["any50"] / k, 0.01),
		"mean_npcs_within_50m": snappedf(s["n50"] / k, 0.1),
		"mean_npcs_within_100m": snappedf(s["n100"] / k, 0.1),
		"share_worthwhile_prey_within_60m": snappedf(s["prey60"] / k, 0.01),
		"share_would_be_hunter_within_100m": snappedf(s["hunter100"] / k, 0.01),
		"builder_metric_prey150_ge2": snappedf(s["b_prey"] / k, 0.01),
		"builder_metric_threat200_ge1": snappedf(s["b_threat"] / k, 0.01),
		"far_despawns": s["far_despawns"], "count_end": e.count(), "safety": safety.counts,
	}
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await clear_sim()
	return out


func test_travelling_player_has_life_around_it() -> void:
	var table := {}
	for pm in [0.03, 0.3, 1.3]:
		var r := await _stage(pm, 150.0, 11)
		table["%.2f" % pm] = r
		print("[ai-verify] traveller %.2f kg: %s" % [pm, r])
		gt(r["share_worthwhile_prey_within_60m"], 0.8, "%.2f kg: worthwhile prey within 60 m most of the time" % pm)
		gt(r["mean_npcs_within_100m"], 5.0, "%.2f kg: a living sky around a travelling player (>5 birds within 100 m)" % pm)
	metric("traveller", table)
