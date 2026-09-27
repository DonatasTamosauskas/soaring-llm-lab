extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): replays one hunting-player case
## of realworld_test (valley, seeker_player, air synced to sim time) and,
## for every hard hit (>= 3 m/s into a surface) within 60 m of the player,
## prints the bird's last ~2 s tick by tick (every 3rd tick).
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_grind_trace --gt_mass=0.5 --gt_seed=874 [--gt_s=180] [--gt_max=6] [--gt_collide=0] [--gt_lap=1]
## (--gt_lap=1: the r3x_contacts probe's lapping mock player instead of the hunting one.)

const Seeker := preload("res://tests/unit/ai/seeker_player.gd")


func _line(n: NpcBird, t: float) -> String:
	var br := n.brain
	return "t=%.2f p=%s v=%s spd=%.1f st=%s want=%s ws=%.1f brake=%.0f slots=%d ob_n=%s ahead=%.1f near=%s flare=%s agl=%.1f thr=%s ref=%s jink=%.2f flee_dir=%s perch=%s phase=%d appr=%s" % [t,
		n.global_position.snapped(Vector3.ONE * 0.01), n.velocity.snapped(Vector3.ONE * 0.1), n.velocity.length(), n.state_name(),
		n.want_dir.snapped(Vector3.ONE * 0.01), n.want_speed, n.want_brake, br._ob_p.size(), str(br._ob_n), br._ahead_d if br._age - br._ahead_t < 0.35 else -1.0,
		n.near_geometry, n.is_flaring(), n.agl(), (n.threat.species if n.threat != null and is_instance_valid(n.threat) else "-"),
		str((n.refuge.get("position", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)) if not n.refuge.is_empty() else "-", br._jink_t,
		str(br._flee_dir.snapped(Vector3.ONE * 0.01)),
		str(n.perch_spot.position.snapped(Vector3.ONE * 0.01)) + " kind %d facing %s" % [n.perch_spot.kind, n.perch_spot.facing.snapped(Vector3.ONE * 0.01)] if n.perch_spot != null else "-",
		br._perch_phase, str(br._approach.snapped(Vector3.ONE * 0.01))]


func test_grind_trace() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var pm := float(Paths.arg("gt_mass", "0.5"))
	var seed_v := int(Paths.arg("gt_seed", "874"))
	var dur := float(Paths.arg("gt_s", "200"))
	var max_n := int(Paths.arg("gt_max", "6"))
	var lap := Paths.arg("gt_lap", "0") == "1"
	var s: Bird = null
	if lap:
		# The r3x_contacts probe's lapping player: 90-m laps 22 m above the
		# highest ground under them.
		var c := rw.get_player_spawn().origin
		var mp := MockPlayer.new()
		mp.mass = pm
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 90.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, rw.ground_height(c.x + cos(a) * 90.0, c.z + sin(a) * 90.0))
		mp.path_height = gmax + 22.0
		mp.speed = minf(SizeRules.cruise_speed(pm), 14.0)
		add_child(mp)
		mp.step(0.0)
		s = mp
	else:
		var sk := Seeker.new()
		add_child(sk)
		sk.setup(rw, pm, rw.get_player_spawn().origin)
		sk.collide = Paths.arg("gt_collide", "1") == "1"
		s = sk
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = s
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var hist := {}
	var prev := {}
	var shown := 0
	for i in int(dur / DT):
		var t := i * DT
		air(rw, t)
		if lap:
			s.step(DT)
		else:
			s.active = t >= 20.0
			s.step(DT, e.get_npcs())
		e.step(DT)
		chk.step(DT)
		var eye := s.get_body_position()
		for n in e.get_npcs():
			var id := n.get_instance_id()
			var h: Array = hist.get(id, [])
			if i % 3 == 0:
				h.append(_line(n, t))
				if h.size() > 50:
					h.pop_front()
				hist[id] = h
			var pv: Dictionary = prev.get(id, {})
			if t >= 20.0 and not pv.is_empty() and n.geo_hits > int(pv["hits"]) and shown < max_n:
				var nrm: Vector3 = n.last_hit_normal
				var vin := maxf(-(pv["v"] as Vector3).dot(nrm), 0.0)
				if vin >= 3.0 and n.global_position.distance_to(eye) < 60.0:
					shown += 1
					print("[ai-gt] HIT #%d %s (%s) vin %.1f at %s normal %s, player %.0f m" % [shown, n.name, n.species, vin, n.last_hit.snapped(Vector3.ONE * 0.01), nrm.snapped(Vector3.ONE * 0.01), n.global_position.distance_to(eye)])
					for line in h:
						print("[ai-gt]   ", line)
			prev[id] = {"hits": n.geo_hits, "v": n.velocity}
	check(true, "traced")
	e.queue_free()
	remove_child(s)
	s.queue_free()
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
