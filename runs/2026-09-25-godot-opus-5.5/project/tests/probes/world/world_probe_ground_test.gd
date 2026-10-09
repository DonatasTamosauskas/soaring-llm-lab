extends TestCase
## Verifier probe (round 1): ground_height() vs the solid surface birds hit.
## The contract says "terrain height, ignoring buildings and trees". The
## valley's cliff, canyon walls and rock stacks are separate rock meshes on
## top of the terrain, so ground_height() under them reports the valley floor.
## AI uses ground_height() for spawn heights and altitude floors; this probe
## measures how much of the arena has rock standing far above it.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D


func before_all() -> void:
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


func test_rock_above_ground_height() -> void:
	var by := {}
	var cells := 0
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var x := -676.0
	while x <= 676.0:
		var z := -676.0
		while z <= 676.0:
			if Vector2(x, z).length() < 676.0:
				var q := PhysicsRayQueryParameters3D.create(Vector3(x, 299.0, z), Vector3(x, -60.0, z))
				q.collision_mask = 1
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					var nm := String((hit["collider"] as Node).name)
					var hy: float = (hit["position"] as Vector3).y
					var d := hy - world.ground_height(x, z)
					# Rock only (buildings/trees are allowed by the contract).
					if (nm.begins_with("cliff") or nm.begins_with("canyon") or nm.begins_with("rock") or nm.contains("arch") \
							or nm.begins_with("boulder") or nm.begins_with("escarp")) and d > 5.0:
						cells += 1
						var key := nm.trim_suffix("_body")
						var e: Array = by.get(key, [0, 0.0])
						e[0] += 1
						e[1] = maxf(e[1], d)
						by[key] = e
						if d > worst:
							worst = d
							worst_at = Vector3(x, hy, z)
			z += 4.0
		x += 4.0
	var out := {}
	for k in by:
		out[k] = {"area_m2": by[k][0] * 16, "max_above_m": snappedf(by[k][1], 0.1)}
	print("[world-verify] rock surfaces > 5 m above ground_height: %d m2; worst %.1f m at %s; by body %s" % [cells * 16, worst, worst_at, out])
	metric("rock_above_ground_height", out)
	metric("worst", [worst, [worst_at.x, worst_at.y, worst_at.z]])
	# Report-only: this documents a contract hazard for AI/flight (AGL, spawn).
	check(true, "reported")
	# Spawn-height hazard: a bird placed at ground_height + 10 m over the
	# cliff/canyon is inside rock.
	var inside := 0
	var tried := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 3000:
		var p := Vector3(rng.randf_range(-600, 600), 0, rng.randf_range(-600, 600))
		if Vector2(p.x, p.z).length() > 600.0:
			continue
		tried += 1
		p.y = world.ground_height(p.x, p.z) + 10.0
		# Under a rock top that is higher than the point = inside the rock
		# mass (masses are solid down to the terrain).
		var dn := PhysicsRayQueryParameters3D.create(Vector3(p.x, 299.0, p.z), Vector3(p.x, p.y, p.z))
		dn.collision_mask = 1
		var h := space.intersect_ray(dn)
		if not h.is_empty():
			var nm := String((h["collider"] as Node).name)
			if nm.begins_with("cliff") or nm.begins_with("canyon") or nm.contains("arch"):
				inside += 1
	print("[world-verify] random points at ground_height+10 m that are inside solid: %d / %d" % [inside, tried])
	metric("spawn10_inside_solid", [inside, tried])


func test_invisible_wall_gap_to_visible_mountain() -> void:
	# Where the invisible boundary stops a bird first, how much open air is
	# there between the wall and the visible mountain behind it? A large gap
	# means hitting "nothing" in mid-air in front of a distant slope.
	var R := world.bounds_radius
	var gaps := PackedFloat32Array()
	var by_alt := {}
	for deg in range(0, 360, 2):
		var a := deg_to_rad(float(deg))
		var dir := Vector3(cos(a), 0, sin(a))
		for y: float in [60.0, 120.0, 180.0, 240.0, 290.0]:
			var p0 := dir * (R - 30.0) + Vector3(0, y, 0)
			if world.ground_height(p0.x, p0.z) > y - 2.0:
				continue
			var q := PhysicsRayQueryParameters3D.create(p0, dir * (R + 400.0) + Vector3(0, y, 0))
			q.collision_mask = 1
			var hit := space.intersect_ray(q)
			if hit.is_empty() or String((hit["collider"] as Node).name) != "Boundary":
				continue
			# Distance from the wall to the terrain along the same line.
			var s := R
			while s < R + 400.0 and world.terrain.height_at(dir.x * s, dir.z * s) < y:
				s += 2.0
			var g := s - R
			gaps.append(g)
			var arr: Array = by_alt.get(int(y), [])
			arr.append(g)
			by_alt[int(y)] = arr
	var sorted := Array(gaps)
	sorted.sort()
	var med: float = sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var p90: float = sorted[int(sorted.size() * 0.9)] if not sorted.is_empty() else 0.0
	var mx: float = sorted[-1] if not sorted.is_empty() else 0.0
	var alt_med := {}
	for k in by_alt:
		var arr: Array = by_alt[k]
		arr.sort()
		alt_med[k] = [arr.size(), snappedf(arr[arr.size() / 2], 1.0), snappedf(arr[-1], 1.0)]
	print("[world-verify] invisible-wall stops: %d; open air between wall and mountain: median %.0f m, p90 %.0f m, max %.0f m; by altitude [n, median, max] %s" % [gaps.size(), med, p90, mx, alt_med])
	metric("wall_gap", {"n": gaps.size(), "median": med, "p90": p90, "max": mx, "by_alt": alt_med})
	check(true, "reported")
