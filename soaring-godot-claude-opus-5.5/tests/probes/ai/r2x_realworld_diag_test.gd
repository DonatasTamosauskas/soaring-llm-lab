extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER DIAGNOSTIC (round 2): in the real valley, (1) where and in what
## situation NPC bodies end up inside geometry (A5), and (2) why perch
## attempts end without a landing. One scenario per run:
##   --r2x_mass=0.03 --r2x_seed=41 --r2x_s=140
## Prints [ai-r2x-diag] lines; asserts safety == 0 (A5) and records the
## perch-attempt outcomes.

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")


func test_r2x_diag() -> void:
	var pm := float(Paths.arg("r2x_mass", "0.03"))
	var seed_v := int(Paths.arg("r2x_seed", "41"))
	var sim_s := float(Paths.arg("r2x_s", "140"))
	var w := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(w)
	await wait_physics(3)
	var p := MockPlayer.new()
	p.mass = pm
	var spawn := w.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, w.ground_height(spawn.x + cos(a) * 90.0, spawn.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_v)
	e.focus = p
	var chk := make_checker()
	var safety := Safety.new(w)
	var outcomes := {}
	var by_species := {}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.state_changed.connect(func(b: NpcBird, old: int, ns: int) -> void:
			if old != NpcBird.State.PERCH:
				return
			var why := NpcBird.STATE_NAMES[ns]
			if ns == NpcBird.State.PERCHED:
				why = "landed"
			elif b.threat != null:
				why = "fled:" + ("player" if b.threat.is_player() else String(b.threat.species))
			elif b.brain._perch_fail >= 4:
				why = "gave_up_approach(%s)" % NpcBird.STATE_NAMES[ns]
			elif b.state_time > 29.0:
				why = "timeout30s"
			elif ns == NpcBird.State.HUNT:
				why = "hunt"
			else:
				why = "other:" + NpcBird.STATE_NAMES[ns]
			outcomes[why] = outcomes.get(why, 0) + 1
			var k := "%s:%s" % [b.species, why]
			by_species[k] = by_species.get(k, 0) + 1))
	var inside_seen := 0
	var inside_lines := []
	var space := w.get_world_3d().direct_space_state
	for i in int(sim_s / DT):
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if safety.counts["inside"] > inside_seen and inside_lines.size() < 12:
			inside_seen = safety.counts["inside"]
			for n in e.get_npcs():
				if not safety._inside(space, n, n.global_position):
					continue
				var q := PhysicsPointQueryParameters3D.new()
				q.collision_mask = 1
				q.position = n.global_position
				var what := []
				for hh in space.intersect_point(q, 4):
					what.append(str(hh["collider"].name))
				var sq := PhysicsShapeQueryParameters3D.new()
				var sph := SphereShape3D.new()
				sph.radius = n.get_body_radius() * 0.6
				sq.shape = sph
				sq.collision_mask = 1
				sq.transform = Transform3D(Basis.IDENTITY, n.global_position)
				for hh in space.intersect_shape(sq, 4):
					what.append("touch:" + str(hh["collider"].name))
				inside_lines.append("t=%.2f %s/%s%s at %s v=%.1f agl=%.2f in %s perch=%s refuge=%s last_hit=%s n=%s bumps=%d" % [i * DT, n.species, n.state_name(), "/flare" if n.is_flaring() else "", n.global_position.snapped(Vector3.ONE * 0.01), n.velocity.length(), n.agl(), what, n.perch_spot.position.snapped(Vector3.ONE * 0.01) if n.perch_spot else "-", n.refuge.get("name", "-"), n.last_hit.snapped(Vector3.ONE * 0.01), n.last_hit_normal.snapped(Vector3.ONE * 0.01), n.bumps])
	print("[ai-r2x-diag] mass %.2f seed %d: safety %s situations %s" % [pm, seed_v, safety.counts, safety.by_situation])
	for l in inside_lines:
		print("[ai-r2x-diag] inside ", l)
	print("[ai-r2x-diag] perch outcomes %s" % outcomes)
	print("[ai-r2x-diag] perch outcomes by species %s" % by_species)
	print("[ai-r2x-diag] behaviour %s" % e.stats()["behaviour"])
	metric("safety", safety.counts)
	metric("perch_outcomes", outcomes)
	for k in safety.counts:
		eq(safety.counts[k], 0, "safety %s" % k)
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	w.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
