extends TestCase
## Verifier probes, round 2 (engineering & contract lens) for the world area.
## Independent of the builder's suite: physical fly-outs with real rigid
## bodies (continuous collision), a rain of small bodies onto the ground
## (chunk seams included), a replay of the round-1 long-cast "escapes", the
## seed-17 arena finding, contract/API shape checks, ground_height clearance
## and latent seed-dependent checks.
##
##   tools/gd.sh world_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=world_verify2
##
## Prints "[world-verify2] ..." lines; numbers land in the report metrics.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.queue_free()


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	return space.intersect_ray(q)


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


func _overlaps(c: Vector3, r: float, only_names: Array = []) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	var hits := space.intersect_shape(q, 8)
	if only_names.is_empty():
		return not hits.is_empty()
	for h in hits:
		var nm := String((h["collider"] as Node).name)
		for pre in only_names:
			if nm.begins_with(String(pre)):
				return true
	return false


## March a sphere of radius r from p along unit d in short casts (a bird
## flying), up to max_len. Returns the distance flown before it was stopped
## (or max_len).
func _march(p: Vector3, d: Vector3, r: float, max_len: float, step := 4.0) -> float:
	var flown := 0.0
	var at := p
	while flown < max_len:
		var f := _cast(at, at + d * step, r)
		if f < 1.0:
			return flown + f * step
		at += d * step
		flown += step
	return flown


# --- contract ---------------------------------------------------------------

func test_contract_api_shapes() -> void:
	check(world.is_in_group(&"world"), "world in group 'world'")
	check(World.find(get_tree()) == world, "World.find")
	eq(world.process_mode, Node.PROCESS_MODE_INHERIT, "world is pausable (gameplay)")
	eq(world.scale, Vector3.ONE, "world root unscaled")
	# Perches: typed, sane.
	var bad := 0
	for p in world.get_perches():
		if not (p is Perch) or absf(p.facing.y) > 1e-4 or absf(p.facing.length() - 1.0) > 1e-3 \
				or p.max_span <= 0.0 or p.district == &"" or not world.is_inside(p.position + Vector3.UP * 0.05):
			bad += 1
	eq(bad, 0, "every perch: unit horizontal facing, span > 0, district, inside")
	# Landmarks: required keys; openings carry the contract keys.
	var miss := 0
	var op_miss := 0
	for l in world.get_landmarks():
		for key in ["name", "kind", "position", "radius"]:
			if not l.has(key) and not (l.get("kind", "") == "opening" and key == "radius"):
				miss += 1
		if l.get("kind", "") == "opening":
			for key in ["name", "kind", "position", "normal", "width", "height", "max_span", "type", "depth", "up"]:
				if not l.has(key):
					op_miss += 1
	eq(miss, 0, "landmarks carry name/kind/position/radius")
	eq(op_miss, 0, "openings carry the contract keys")
	var ref_miss := 0
	for r in world.get_refuges():
		for key in ["position", "radius", "max_span", "name"]:
			if not r.has(key):
				ref_miss += 1
	eq(ref_miss, 0, "refuges carry position/radius/max_span/name")
	for th in world.get_thermals():
		for key in ["name", "position", "radius", "strength", "base_strength", "top", "lean"]:
			check(th.has(key), "thermal has %s" % key)
	# find_perches respects occupants.
	var p0: Perch = world.get_perches()[0]
	var n_before := world.find_perches(p0.position, 0.5, 0.1).size()
	var fake := Bird.new()
	add_child(fake)
	p0.occupant = fake
	var n_after := world.find_perches(p0.position, 0.5, 0.1).size()
	p0.occupant = null
	fake.queue_free()
	eq(n_after, n_before - 1, "an occupied perch is not offered")
	# Queries far outside stay finite and sane.
	for q: Vector3 in [Vector3(5000, 50, 5000), Vector3(-2000, -100, 0), Vector3(0, 900, 0), Vector3(760, 10, 0), Vector3(-704, 20, -704)]:
		var w := world.get_wind(q)
		check(is_finite(w.x) and is_finite(w.y) and is_finite(w.z), "wind finite at %s" % q)
		check(is_finite(world.ground_height(q.x, q.z)), "ground finite at %s" % q)
		check(not world.is_inside(q), "outside at %s" % q)
	# Physics: all static bodies on layer 1, none on bird layers, no Area3D.
	var stack: Array[Node] = [world]
	var bodies := 0
	var off_layer := 0
	var bird_layers := 0
	var areas := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			bodies += 1
			var sb := n as StaticBody3D
			if (sb.collision_layer & 1) == 0:
				off_layer += 1
			if (sb.collision_layer & (4 | 8)) != 0:
				bird_layers += 1
		if n is Area3D:
			areas += 1
		for c in n.get_children():
			stack.append(c)
	eq(off_layer, 0, "every static body on layer 1")
	eq(bird_layers, 0, "no static body on the bird layers")
	eq(areas, 0, "no Area3D")
	print("[world-verify2] contract: %d static bodies" % bodies)


# --- W1 with real bodies -------------------------------------------------------

## Real rigid spheres (wren-sized, continuous collision) fired at 60 m/s
## outward on 120 bearings x 4 altitudes, 45 deg up-and-out, and straight up
## into the lid. After 2.5 s none may be outside the arena.
func test_w1_physical_flyout() -> void:
	var R := world.bounds_radius
	var holder := Node3D.new()
	add_child(holder)
	var bodies: Array[RigidBody3D] = []
	var sp := SphereShape3D.new()
	sp.radius = 0.025
	var mk := func(p: Vector3, v: Vector3) -> void:
		var b := RigidBody3D.new()
		b.collision_layer = 8
		b.collision_mask = 1
		b.gravity_scale = 0.0
		b.continuous_cd = true
		b.can_sleep = false
		var cs := CollisionShape3D.new()
		cs.shape = sp
		b.add_child(cs)
		b.position = p
		holder.add_child(b)
		b.linear_velocity = v
		bodies.append(b)
	for k in 120:
		var a := TAU * (k + 0.37) / 120.0
		var dir := Vector3(cos(a), 0, sin(a))
		for y0: float in [2.0, 90.0, 200.0, 297.0]:
			var rs := R - 15.0
			while rs > 0.0 and world.ground_height(dir.x * rs, dir.z * rs) > y0 - 2.0:
				rs -= 5.0
			var y := y0
			if y0 == 2.0:
				y = world.ground_height(dir.x * rs, dir.z * rs) + 2.0
			var p := dir * rs + Vector3(0, y, 0)
			if _overlaps(p, 0.03):
				continue
			mk.call(p, dir * 60.0)
			if y0 == 200.0:
				mk.call(p, (dir + Vector3.UP).normalized() * 60.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in 60:
		var q := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (R - 10.0)
		var g := world.ground_height(q.x, q.y)
		if g > 260.0:
			continue
		var p := Vector3(q.x, 280.0, q.y)
		if not _overlaps(p, 0.03):
			mk.call(p, Vector3.UP * 60.0)
	var n := bodies.size()
	await wait_seconds(2.5)
	var out := 0
	var tunnelled := 0
	var where: PackedStringArray = []
	for b in bodies:
		var p := b.global_position
		var r := Vector2(p.x, p.z).length()
		if r > R / cos(PI / 96.0) + 0.3 or p.y > world.ceiling + 0.3:
			out += 1
			where.append("%s" % p.snappedf(0.1))
		elif p.y < world.ground_height(p.x, p.z) - 0.5:
			tunnelled += 1
	holder.queue_free()
	print("[world-verify2] W1 physical fly-out: %d bodies, %d outside, %d ended below ground_height: %s" % [n, out, tunnelled, ", ".join(where.slice(0, 6))])
	gt(float(n), 400.0, "enough fly-out bodies")
	eq(out, 0, "no rigid wren-sized body leaves the arena")
	metric("flyout", {"bodies": n, "outside": out, "below_ground": tunnelled})


## Small bodies rained onto the ground (random points plus every terrain
## chunk seam): none may fall through it.
func test_w1_rain_on_ground_and_seams() -> void:
	var R := world.bounds_radius
	var holder := Node3D.new()
	add_child(holder)
	var sp := SphereShape3D.new()
	sp.radius = 0.02
	var bodies: Array[RigidBody3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var pts := PackedVector2Array()
	for i in 700:
		pts.append(Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (R - 5.0))
	# Chunk seams (5 chunks over 1520 m -> seams at -456, -152, 152, 456).
	var seam := -760.0 + 304.0
	while seam < 760.0:
		for i in 40:
			var t := rng.randf_range(-R, R)
			pts.append(Vector2(seam, t))
			pts.append(Vector2(t, seam))
		seam += 304.0
	for q in pts:
		if q.length() > R - 2.0:
			continue
		var g := world.ground_height(q.x, q.y)
		if g > 290.0:
			continue
		var p := Vector3(q.x, minf(g + 25.0, 295.0), q.y)
		if _overlaps(p, 0.03):
			continue
		var b := RigidBody3D.new()
		b.collision_layer = 8
		b.collision_mask = 1
		b.gravity_scale = 0.0
		b.continuous_cd = true
		b.can_sleep = false
		var cs := CollisionShape3D.new()
		cs.shape = sp
		b.add_child(cs)
		b.position = p
		holder.add_child(b)
		b.linear_velocity = Vector3(rng.randf_range(-3, 3), -40.0, rng.randf_range(-3, 3))
		bodies.append(b)
	await wait_seconds(2.0)
	var fell := 0
	var where: PackedStringArray = []
	for b in bodies:
		var p := b.global_position
		# Below the lowest possible ground here (terrain floor, not rock).
		var floor_y := minf(world.terrain.height_at(p.x, p.z), world.ground_height(p.x, p.z))
		if p.y < floor_y - 0.3:
			fell += 1
			where.append("%s (floor %.1f)" % [p.snappedf(0.1), floor_y])
	holder.queue_free()
	print("[world-verify2] rain: %d bodies, %d fell through the ground: %s" % [bodies.size(), fell, ", ".join(where.slice(0, 6))])
	gt(float(bodies.size()), 600.0, "enough rain bodies")
	eq(fell, 0, "no small body falls through the ground or a chunk seam")
	metric("rain", {"bodies": bodies.size(), "fell": fell})


## The round-1 probe's 2.5 km sphere casts that report no hit: is each one a
## real gap? March a 2 cm sphere in 4 m casts along the same line.
func test_w1_long_cast_escapes_replayed() -> void:
	var R := world.bounds_radius
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var n := 0
	var long_esc := 0
	var march_esc := 0
	var start_overlap := 0
	var big_esc := 0
	var detail: PackedStringArray = []
	while n < 4000:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * (R - 3.0)
		var x := cos(a) * rr
		var z := sin(a) * rr
		var g := world.ground_height(x, z)
		if g > world.ceiling - 4.0:
			continue
		var y := rng.randf_range(g + 1.0, world.ceiling - 1.0)
		var p := Vector3(x, y, z)
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1.0), rng.randf_range(-1, 1)).normalized()
		n += 1
		if _cast(p, p + d * 2500.0, 0.02) < 1.0:
			continue
		long_esc += 1
		if _overlaps(p, 0.02):
			start_overlap += 1
		var hit := _ray(p, p + d * 2500.0)
		var flown := _march(p, d, 0.02, 1100.0)
		var endp := p + d * flown
		var escaped := Vector2(endp.x, endp.z).length() > R / cos(PI / 96.0) + 0.3 or endp.y > world.ceiling + 0.3
		if escaped:
			march_esc += 1
		# A bigger body on the same long line.
		if _cast(p, p + d * 2500.0, 0.5) >= 1.0 and not _overlaps(p, 0.5):
			big_esc += 1
		if detail.size() < 8:
			detail.append("%s d%s ray-hit %s marched %.0f m%s" % [p.snappedf(0.1), d.snappedf(0.01),
				(String((hit["collider"] as Node).name) + "@" + str((hit["position"] as Vector3).snappedf(0.1))) if not hit.is_empty() else "none",
				flown, " ESCAPED" if escaped else ""])
	print("[world-verify2] long casts: %d rays, %d 2.5 km casts report no hit (%d start overlapping); marching them in 4 m casts: %d escape; 0.5 m sphere long cast escapes: %d" % [n, long_esc, start_overlap, march_esc, big_esc])
	for s in detail:
		print("[world-verify2]   ", s)
	eq(march_esc, 0, "no long-cast 'escape' survives a marched flight")
	metric("long_casts", {"no_hit": long_esc, "start_overlap": start_overlap, "march_escape": march_esc, "big_long_escape": big_esc})


## Round-1's seeds probe reports 1 arena escape on seed 17: find it and
## decide whether it is real (marched flight + a rigid body on that line).
func test_w1_seed17_escape() -> void:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(8, 8)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var w: SoaringWorld = load("res://scenes/world/world.tscn").instantiate()
	w.world_seed = 17
	w.with_decoration = false
	vp.add_child(w)
	await wait_physics(2)
	var main_space := space
	space = w.get_world_3d().direct_space_state
	var R := w.bounds_radius
	var found: Array = []
	for k in 120:
		var a := TAU * k / 120.0
		var dir := Vector3(cos(a), 0, sin(a))
		for y0: float in [2.0, 90.0, 200.0, 297.0]:
			var rs := R - 15.0
			while rs > 0.0 and w.ground_height(dir.x * rs, dir.z * rs) > y0 - 2.0:
				rs -= 15.0
			var y := y0
			if y0 == 2.0:
				y = w.ground_height(dir.x * rs, dir.z * rs) + 2.0
			var p0 := dir * rs + Vector3(0, y, 0)
			var far := dir * (R + 150.0) + Vector3(0, y, 0)
			var hit := _ray(p0, far)
			var why := ""
			if hit.is_empty():
				why = "ray no hit"
			elif Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z).length() > R + 0.6:
				why = "ray hit beyond R at %s" % (hit["position"] as Vector3).snappedf(0.1)
			elif _cast(p0, far, 0.02) >= 1.0:
				why = "sphere cast no hit (ray hit %s at %s, start overlap %s)" % [(hit["collider"] as Node).name, (hit["position"] as Vector3).snappedf(0.1), _overlaps(p0, 0.02)]
			if why != "":
				var flown := _march(p0, dir, 0.02, p0.distance_to(far))
				var endp := p0 + dir * flown
				found.append([p0, dir, why, flown, Vector2(endp.x, endp.z).length()])
	# Rigid-body check on each found line.
	var holder := Node3D.new()
	w.add_child(holder)
	var bodies: Array[RigidBody3D] = []
	var sp := SphereShape3D.new()
	sp.radius = 0.025
	for f in found:
		var b := RigidBody3D.new()
		b.collision_layer = 8
		b.collision_mask = 1
		b.gravity_scale = 0.0
		b.continuous_cd = true
		var cs := CollisionShape3D.new()
		cs.shape = sp
		b.add_child(cs)
		b.position = f[0]
		holder.add_child(b)
		b.linear_velocity = (f[1] as Vector3) * 60.0
		bodies.append(b)
	await wait_seconds(2.0)
	var real := 0
	for i in found.size():
		var f: Array = found[i]
		var bp := bodies[i].global_position
		var br := Vector2(bp.x, bp.z).length()
		var escaped: bool = float(f[4]) > R / cos(PI / 96.0) + 0.3 or br > R / cos(PI / 96.0) + 0.3
		if escaped:
			real += 1
		print("[world-verify2] seed17 finding: from %s dir %s: %s; marched %.1f m (ends r=%.2f); rigid body ends r=%.2f%s" % [
			(f[0] as Vector3).snappedf(0.1), (f[1] as Vector3).snappedf(0.001), f[2], f[3], f[4], br, " REAL ESCAPE" if escaped else ""])
	space = main_space
	vp.queue_free()
	await wait_frames(2)
	metric("seed17", {"findings": found.size(), "real": real})
	eq(real, 0, "seed 17: the probe's finding is not a real way out")


# --- ground_height ------------------------------------------------------------

## A bird placed just above ground_height is in the air (not inside the
## terrain, water, cliff or canyon), sampled densely over the rock masses.
func test_ground_height_gives_air_above() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var n := 0
	var inside_ground := 0
	var steep := 0
	var gentle_n := 0
	var where: PackedStringArray = []
	var pts := PackedVector2Array()
	for i in 3000:
		pts.append(Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * (world.bounds_radius - 2.0))
	for poly in [WorldLayout.CLIFF, WorldLayout.CANYON]:
		for i in 1500:
			var a: Vector2 = poly[rng.randi() % poly.size()]
			pts.append(a + Vector2(rng.randf_range(-70, 70), rng.randf_range(-70, 70)))
	for q in pts:
		var g := world.ground_height(q.x, q.y)
		if g > world.ceiling - 3.0:
			continue
		n += 1
		# Steep ground (mountain slopes, rock faces): a sphere 0.6 m above a
		# steep face touches it sideways; count those separately. The
		# local slope comes from ground_height itself (0.5 m differences).
		var e := 0.5
		var gx := world.ground_height(q.x + e, q.y) - world.ground_height(q.x - e, q.y)
		var gz := world.ground_height(q.x, q.y + e) - world.ground_height(q.x, q.y - e)
		var ny := Vector3(-gx, 2.0 * e, -gz).normalized().y
		var gentle := ny > 0.85
		if gentle:
			gentle_n += 1
		# A pigeon-sized body just above the ground.
		var c := Vector3(q.x, g + 0.6, q.y)
		if _overlaps(c, 0.25, ["terrain_", "water_body", "cliff_body", "canyon_body"]):
			if gentle:
				inside_ground += 1
				if where.size() < 6:
					where.append(str(c.snappedf(0.1)))
			else:
				steep += 1
	print("[world-verify2] ground_height + 0.6 m: %d samples (%d on gentle ground): %d gentle-ground samples overlap ground bodies (r 0.25): %s; %d steep ones touch the slope" % [n, gentle_n, inside_ground, ", ".join(where), steep])
	metric("gh_air_above", {"samples": n, "gentle": gentle_n, "inside_ground_gentle": inside_ground, "steep_touch": steep})
	lt(float(inside_ground) / gentle_n, 0.005, "on gentle ground a body at ground_height + 0.6 m is in the air")


# --- latent test flakiness --------------------------------------------------------

## W10's soft check requires every cloud's AABB above the ceiling; only seed
## 1 is checked with decoration. How many seeds would fail it?
func test_clouds_on_other_seeds() -> void:
	var fails: PackedInt32Array = []
	var inside_arena := 0
	for sd in range(1, 41):
		var holder := Node3D.new()
		var mi := WorldSky.build_clouds(holder, sd, &"day")
		var ab := mi.get_aabb()
		if ab.position.y < world.ceiling:
			fails.append(sd)
		# Any cloud vertex inside the arena and below the ceiling?
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in verts:
			if v.y < world.ceiling and Vector2(v.x, v.z).length() < world.bounds_radius:
				inside_arena += 1
				break
		holder.free()
	print("[world-verify2] clouds: seeds 1-40 whose cloud AABB dips below the ceiling: %s; seeds with a cloud vertex below the ceiling INSIDE the arena: %d" % [fails, inside_arena])
	metric("cloud_seed_fails", Array(fails))
	eq(inside_arena, 0, "no cloud dips into the playable air on any seed")


## Thermal usability for big birds: lift at the radius an eagle / gull must
## circle at (informational; the brief asks cores 3-5 m/s).
func test_thermal_circling_radii() -> void:
	world.set_air_time(0.0)
	var out := {}
	for i in world.get_thermals().size():
		var th: Dictionary = world.get_thermals()[i]
		var c := world.wind.thermal_center(i, 120.0)
		var row := {}
		for r: float in [8.0, 15.0, 22.0, 30.0]:
			var acc := 0.0
			for k in 16:
				var a := TAU * k / 16.0
				acc += world.get_wind(c + Vector3(cos(a) * r, 0, sin(a) * r)).y
			row[str(r)] = snappedf(acc / 16.0, 0.01)
		out[th["name"]] = row
	print("[world-verify2] thermal mean lift on circles at 120 m: ", out)
	metric("circling", out)
	check(true, "informational")


# --- W6: does the builder's own grounding test catch every kind? -----------

## Lift each owner-less structure's body by 1 m at runtime (as the builder's
## own detector does for houses and trees) and run the builder's exact
## _floating_footprints() from tests/unit/world/world_test.gd on it.
func test_w6_builder_detector_on_every_kind() -> void:
	var wt: Node = (load("res://tests/unit/world/world_test.gd") as Script).new()
	wt.set("world", world)
	wt.set("space", space)
	var bodies: Node = world.get_node("Bodies")
	var cases := [["water_tower_body", "water_tower"], ["farm_body", "barn"], ["church_body", "church"],
		["bridge_body", "bridge"], ["mast_body", "mast"], ["powerline_body", "pole"], ["ruin_body", "ruin"],
		["hollow_trees_body", "hollow_tree"], ["lake_arch_body", "lake_arch"], ["farm_bales_body", "bale"],
		["farm_body", "fence_post"]]
	var hedge_bodies: Array[Node3D] = []
	for b in bodies.get_children():
		if String(b.name).begins_with("hedges_") and not String(b.name).begins_with("hedges_lod") and b is StaticBody3D:
			hedge_bodies.append(b)
	var report := {}
	var missed: PackedStringArray = []
	for c in cases:
		var b := bodies.get_node_or_null(String(c[0])) as Node3D
		if b == null:
			report[c[1]] = "no body %s" % c[0]
			continue
		var before: int = (wt.call("_floating_footprints", String(c[1]))[0] as PackedStringArray).size()
		var total := 0
		for fp in world.build.footprints:
			if String(fp["name"]).begins_with(String(c[1])) and not String(fp["name"]).ends_with("_back"):
				total += 1
		b.global_position += Vector3.UP
		await wait_physics(2)
		var after: PackedStringArray = wt.call("_floating_footprints", String(c[1]))[0]
		b.global_position -= Vector3.UP
		await wait_physics(2)
		report[c[1]] = "%d of %d flagged when lifted 1 m (%d before)" % [after.size(), total, before]
		if after.size() < maxi(1, total / 2):
			missed.append("%s (%s)" % [c[1], report[c[1]]])
	# Hedges: lift every hedge body.
	for b in hedge_bodies:
		b.global_position += Vector3.UP
	await wait_physics(2)
	var hf: PackedStringArray = wt.call("_floating_footprints", "hedge")[0]
	for b in hedge_bodies:
		b.global_position -= Vector3.UP
	await wait_physics(2)
	report["hedge"] = "%d flagged when all hedge bodies lifted 1 m" % hf.size()
	if hf.size() < 200:
		missed.append("hedge (%s)" % report["hedge"])
	wt.free()
	print("[world-verify2] W6 detector per kind: ", report)
	metric("w6_detector_per_kind", report)
	eq(missed.size(), 0, "the builder's grounding test flags every lifted kind: %s" % ", ".join(missed))


## Which colliders ground the water tower once its body is lifted 1 m?
## (The builder's footprint rays accept any collider for owner-less
## footprints.) Also: a lift of 1.5 m for the poles (embedded 1.2 m).
func test_w6_diag_owner_less_footprints() -> void:
	var bodies: Node = world.get_node("Bodies")
	var ex: Array[RID] = []
	for b in bodies.get_children():
		var nm := String(b.name)
		if nm.begins_with("terrain_") or nm == "water_body":
			ex.append((b as CollisionObject3D).get_rid())
	var wtb := bodies.get_node("water_tower_body") as Node3D
	wtb.global_position += Vector3.UP
	await wait_physics(2)
	var seen := {}
	for fp in world.build.footprints:
		if String(fp["name"]) != "water_tower":
			continue
		for q in (fp["points"] as PackedVector2Array):
			var c := Vector3(q.x, world.terrain.height_at(q.x, q.y) + 0.1, q.y)
			for k in 8:
				var d := Vector3(cos(TAU * k / 8.0), 0, sin(TAU * k / 8.0)) * 3.0
				var rq := PhysicsRayQueryParameters3D.create(c + d, c - d)
				rq.collision_mask = 1
				rq.exclude = ex
				var h := space.intersect_ray(rq)
				if not h.is_empty():
					var key := "%s@%s" % [(h["collider"] as Node).name, (h["position"] as Vector3).snappedf(0.1)]
					seen[key] = seen.get(key, 0) + 1
	wtb.global_position -= Vector3.UP
	await wait_physics(2)
	print("[world-verify2] water tower lifted 1 m: footprint rays hit ", seen)
	# Poles lifted 1.5 m (their base is 1.2 m deep).
	var wt: Node = (load("res://tests/unit/world/world_test.gd") as Script).new()
	wt.set("world", world)
	wt.set("space", space)
	var pl := bodies.get_node("powerline_body") as Node3D
	pl.global_position += Vector3.UP * 1.5
	await wait_physics(2)
	var pf: PackedStringArray = wt.call("_floating_footprints", "pole")[0]
	pl.global_position -= Vector3.UP * 1.5
	await wait_physics(2)
	wt.free()
	print("[world-verify2] poles lifted 1.5 m: %d of 15 flagged" % pf.size())
	metric("water_tower_lifted_hits", seen)
	check(seen.is_empty(), "a lifted water tower is not grounded by other objects' colliders")
