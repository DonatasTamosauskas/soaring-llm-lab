extends "res://tests/unit/ai/ai_sim.gd"

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
## VERIFIER DIAGNOSTIC (round 2): the real-valley perches where perched
## moths were flagged "inside" by the AI's own A5 monitor (z ~ 248). For every
## perch Habitat offers to a moth (find_perches), place a moth body where
## NpcBird.land_on puts it (perch + UP x 0.8 body radius) and measure how far
## the body sphere penetrates layer-1 geometry (collide_shape). Reports the
## count and the worst depth, by perch kind and district.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r2x_hedge_perch


func test_r2x_perched_bodies_clear_of_geometry() -> void:
	var w := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(w)
	await wait_physics(3)
	var h := Habitat.for_world(w)
	var space := w.get_world_3d().direct_space_state
	var out := {}
	var worst := []
	for sp in [&"moth", &"wren", &"sparrow"]:
		var mass: float = SizeRules.species_data(sp)["mass"]
		var r := SizeRules.body_radius_for_mass(mass)
		var span := SizeRules.wingspan_for_mass(mass)
		var kinds: Array = SpeciesProfile.of(sp)["perch_kinds"]
		var offered := h.find_perches(Vector3.ZERO, 5000.0, span, kinds)
		var sph := SphereShape3D.new()
		sph.radius = r * 0.6
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sph
		q.collision_mask = 1
		var bad := 0
		var mon := Safety.new(w)
		var probe_bird := NpcBird.new()
		probe_bird.configure(sp, mass, 1, h)
		var by := {}
		for p in offered:
			var c := p.position + Vector3.UP * r * 0.8
			q.transform = Transform3D(Basis.IDENTITY, c)
			var pts := space.collide_shape(q, 8)
			if pts.is_empty():
				continue
			# Deepest penetration: pairs of (point on our sphere, point on the other shape).
			var depth := 0.0
			for i in range(0, pts.size(), 2):
				depth = maxf(depth, (pts[i] as Vector3).distance_to(pts[i + 1]))
			if absf(c.y - w.ground_height(c.x, c.z)) <= r * 2.0 + 0.3:
				continue
			# Only what the AI's own A5 monitor would flag.
			if not mon._inside(space, probe_bird, c):
				continue
			bad += 1
			var k := "%s/%s" % [Perch.Kind.keys()[p.kind], p.district]
			by[k] = by.get(k, 0) + 1
			if worst.size() < 12:
				worst.append("%s at %s kind %s district %s max_span %.2f depth %.4f m (body r %.4f)" % [sp, p.position.snapped(Vector3.ONE * 0.01), Perch.Kind.keys()[p.kind], p.district, p.max_span, depth, r])
		probe_bird.free()
		out[String(sp)] = {"offered": offered.size(), "body_touching_geometry": bad, "by_kind_district": by}
	print("[ai-r2x] perched bodies vs geometry: %s" % JSON.stringify(out))
	for l in worst:
		print("[ai-r2x]   ", l)
	for sp in out:
		eq(out[sp]["body_touching_geometry"], 0, "%s: offered perches whose perched body (60%% radius) touches geometry" % sp)
	w.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
