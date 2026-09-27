extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): replays avoidance_test's house
## run for one house/species and prints the bird tick by tick around its
## first geometry contact.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_wall_trace [--wt_house=2] [--wt_sp=pigeon]


func test_wall_trace() -> void:
	await make_world(false, 1)
	var i := int(Paths.arg("wt_house", "2"))
	var sp := StringName(Paths.arg("wt_sp", "pigeon"))
	var xf: Transform3D = world.houses[i][0]
	var c := xf.origin
	var a := TAU * i / world.houses.size()
	var dir := Vector3(cos(a), 0.0, sin(a))
	var start := c - dir * 40.0
	start.y = world.ground_height(start.x, start.z) + 3.0
	var goal := c + dir * 60.0
	goal.y = world.ground_height(goal.x, goal.z) + 3.0
	_seed = 1000 + 17 * int(Paths.arg("wt_n", "14"))
	var b := spawn(sp, start, dir.normalized() * SizeRules.performance(SizeRules.species_data(sp)["mass"])["cruise"])
	b.can_hunt = false
	b.can_flee = false
	b.energy = 1.0
	b.home = Vector3(goal.x, 0.0, goal.z)
	b.home_radius = 400.0
	b.brain._perch_cool = 999.0
	b.brain._soar_cool = 999.0
	b.brain._goal = goal
	b.brain._goal_t = 0.0
	b.brain._goal_life = 999.0
	b.brain._goal_free = true
	var hist: Array[String] = []
	var hit_at := -1
	run(9.0, func(k: int) -> bool:
		var br := b.brain
		hist.append("t=%.3f p=%s v=%s spd=%.1f want=%s ws=%.1f brake=%.1f st=%s slots=%d ob_n=%s ahead=%.1f near=%s geo=%d" % [k * DT,
			b.global_position.snapped(Vector3.ONE * 0.01), b.velocity.snapped(Vector3.ONE * 0.1), b.velocity.length(),
			b.want_dir.snapped(Vector3.ONE * 0.01), b.want_speed, b.want_brake, b.state_name(), br._ob_p.size(), str(br._ob_n),
			br._ahead_d if br._age - br._ahead_t < 0.35 else -1.0, b.near_geometry, b.geo_hits])
		if b.geo_hits > 0 and hit_at < 0:
			hit_at = hist.size() - 1
		return hit_at >= 0 and hist.size() > hit_at + 10)
	if hit_at >= 0:
		print("[ai-wt] first contact at %s normal %s" % [b.last_hit, b.last_hit_normal])
		for j in range(maxi(0, hit_at - 90), hist.size()):
			print("[ai-wt] ", hist[j])
	else:
		print("[ai-wt] no contact")
	check(true, "traced")
	despawn(b)
	await clear_sim()
