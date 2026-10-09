extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER DIAGNOSTIC (round 2): where, relative to a sparrow-sized
## player's flight direction, is its worthwhile prey? (The forward-view
## probe found none ahead of a lapping sparrow.) Histograms of bearing
## (front <= 50 deg / side / behind) and distance, plus prey states.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r2x_prey_bearing


func test_r2x_prey_bearing() -> void:
	await make_world(false, 1)
	for travel in [false, true]:
		var p := MockPlayer.new()
		p.mass = 0.03
		p.path_center = Vector3(-20, 0, 10)
		p.path_radius = 90.0
		p.path_height = 22.0
		p.speed = 9.0
		if travel:
			p.travel = true
			p.speed = 12.0
			p.line_a = Vector3(-300, 22, 10)
			p.line_b = Vector3(300, 22, 10)
		add_child(p)
		p.step(0.0)
		var e := make_eco(60, 61)
		e.focus = p
		var chk := make_checker()
		var hist := {}
		var states := {}
		var dist := {"<20": 0, "20-54": 0, "54-100": 0, "100-150": 0, ">150": 0}
		var alt := {"below_player": 0, "above_player": 0}
		var n_s := 0
		for i in int(115.0 / DT):
			p.step(DT)
			e.step(DT)
			chk.step(DT)
			if i * DT > 25.0 and i % 72 == 0:
				n_s += 1
				var pp := p.get_body_position()
				var f := p.get_view_direction()
				for n in e.get_npcs():
					if not (SizeRules.can_eat(0.03, n.mass) and SizeRules.is_worthwhile(0.03, n.mass)):
						continue
					var rel := n.global_position - pp
					var d := rel.length()
					var hd := Vector2(rel.x, rel.z)
					var ang := rad_to_deg(Vector2(f.x, f.z).angle_to(hd)) if hd.length() > 0.1 else 0.0
					var b := "front" if absf(ang) <= 50.0 else ("side" if absf(ang) <= 110.0 else "behind")
					var db := "<20" if d < 20.0 else ("20-54" if d < 54.0 else ("54-100" if d < 100.0 else ("100-150" if d < 150.0 else ">150")))
					dist[db] += 1
					if d < 54.0:
						hist[b] = hist.get(b, 0) + 1
					var sk := "%s:%s" % [n.species, n.state_name()]
					states[sk] = states.get(sk, 0) + 1
					alt["below_player" if rel.y < 0 else "above_player"] += 1
		print("[ai-r2x] prey bearing travel=%s samples=%d within54 by bearing %s; distance %s; states %s; alt %s; focus-player %.1f m" % [travel, n_s, hist, dist, states, alt, Vector2(e.focus_point().x - p.global_position.x, e.focus_point().z - p.global_position.z).length()])
		e.queue_free()
		eco = null
		remove_child(p)
		p.queue_free()
		await wait_frames(2)
	check(true, "diagnostic")
	await clear_sim()
