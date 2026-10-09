extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): the ai_thermal.png setup (three
## gulls and a hawk put on the valley thermal nearest the player spawn),
## headless, printing each bird's state, height and effort every 2 s.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_thermal_trace [--tt_s=40] [--tt_air=1]


func test_thermal_trace() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var ths := rw.get_thermals()
	var sp0 := rw.get_player_spawn().origin
	var th: Dictionary = ths[0]
	for t in ths:
		if (t["position"] as Vector3).distance_to(sp0) < (th["position"] as Vector3).distance_to(sp0):
			th = t
	var c: Vector3 = th["position"]
	print("[ai-tt] thermal at %s radius %s" % [c, th.get("radius", "?")])
	var list := [[&"gull", 30.0], [&"gull", 42.0], [&"gull", 54.0], [&"hawk", 36.0]]
	var bs: Array[NpcBird] = []
	for i in list.size():
		var a := TAU * i / list.size()
		var b := spawn(list[i][0], c + Vector3(cos(a) * 30, list[i][1], sin(a) * 30), Vector3(-sin(a), 0, cos(a)) * 12.0, rw)
		b.can_hunt = false
		b.can_flee = false
		b.brain._perch_cool = 999.0
		b.home = Vector3(c.x, 0, c.z)
		b.home_radius = 100.0
		bs.append(b)
	var y0 := []
	for b in bs:
		y0.append(b.global_position.y)
	var dur := float(Paths.arg("tt_s", "40"))
	var use_air := Paths.arg("tt_air", "1") == "1"
	for i in int(dur / DT):
		if use_air:
			air(rw, i * DT)
		for b in bs:
			b.tick(DT)
		if i % 144 == 0:
			for k in bs.size():
				var b := bs[k]
				var hc := Vector3(b.global_position.x - c.x, 0, b.global_position.z - c.z).length()
				print("[ai-tt] t=%.0f %s st=%s dy=%+.1f agl=%.1f eff=%.2f spd=%.1f hdist=%.0f near=%s soar_cool=%.1f wind_y=%.2f" % [i * DT, b.species, b.state_name(),
					b.global_position.y - float(y0[k]), b.agl(), b.flight.effort, b.velocity.length(), hc, b.near_geometry, b.brain._soar_cool,
					rw.get_wind(b.global_position).y])
	check(true, "traced")
	for b in bs:
		despawn(b)
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
