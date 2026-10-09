extends Node3D
## VERIFIER RENDER (round 4, experience lens, forward_plus): the shipped
## valley with the 60-NPC ecosystem round a mock player lapping the spawn
## (the r4x_accidental harness). Captures, from the player's eye:
##  * face_<n>.png: an NPC that is NOT after the player about to pass within
##    0.6 m of its head (0.25 s before closest approach), camera on the
##    bird, 100 deg FOV (what the player sees if it looks that way);
##  * perched_<n>.png: an NPC perched on a branch or wire within 30 m, seen
##    from the eye through a 12 deg lens (a player looking at it closely).
## Outputs artifacts/ai/verify/r4/eye/*.png
##   tools/gd.sh ai_r4exp --rendering-method forward_plus --resolution 1280x720 res://tests/probes/ai/r4x_eye_shots.tscn -- --r4_mass=1.3 --r4_seed=4704

const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const DT := 1.0 / 72.0

var world: World
var cam: Camera3D
var _cap: Label
var _dir := ""


func _ready() -> void:
	world = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(world)
	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = 100.0
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var cl := CanvasLayer.new()
	add_child(cl)
	_cap = Label.new()
	_cap.position = Vector2(16, 12)
	_cap.add_theme_font_size_override("font_size", 18)
	_cap.add_theme_color_override("font_color", Color("#0b0b0b"))
	_cap.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_cap.add_theme_constant_override("outline_size", 6)
	cl.add_child(_cap)
	for i in 4:
		await get_tree().physics_frame
	if not world.is_generated:
		await world.generated
	_dir = Paths.artifacts("ai").path_join(Paths.arg("r4_outdir", "verify/r4/eye"))
	if Paths.arg("r4_fulltrees", "") != "":
		# Diagnostic: force every tree chunk to full detail (hide the mid and
		# far stand-ins), to tell a LOD choice from a mesh/collider mismatch.
		var n_full := 0
		var n_hidden := 0
		for gi in world.find_children("trees_*", "GeometryInstance3D", true, false):
			var g := gi as GeometryInstance3D
			var nm := String(g.name)
			if nm.begins_with("trees_lod_") or nm.begins_with("trees_far_"):
				g.visible = false
				n_hidden += 1
			elif not nm.begins_with("trees_shadow"):
				g.visibility_parent = NodePath()
				g.visibility_range_begin = 0.0
				g.visibility_range_end = 0.0
				n_full += 1
		print("[ai-r4x] full-detail trees: %d chunks forced, %d stand-ins hidden" % [n_full, n_hidden])
	DirAccess.make_dir_recursive_absolute(_dir)
	await _run(float(Paths.arg("r4_mass", "1.3")), int(Paths.arg("r4_seed", "4704")), float(Paths.arg("r4_s", "200")))
	print("[ai-r4x] eye shots done")
	get_tree().quit()


func _run(pm: float, seed_v: int, secs: float) -> void:
	var p := MockPlayer.new()
	p.mass = pm
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	p.protect_s = 5.0
	var sp0 := world.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, world.ground_height(sp0.x + cos(a) * 90.0, sp0.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	add_child(p)
	p.step(0.0)
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var n_face := 0
	var n_perch := 0
	var shot_ids := {}
	var last_perch_t := -99.0
	var i := -1
	var n_steps := int(secs / DT)
	while i < n_steps - 1:
		i += 1
		var t := i * DT
		if world.has_method(&"set_air_time"):
			world.call(&"set_air_time", t)
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if i % 24 == 0:
			await get_tree().process_frame
		if t < 20.0:
			continue
		var eye := p.get_body_position()
		if n_face < 3:
			for n in e.get_npcs():
				if not n.alive or n.target == p or n.strike == p or shot_ids.has(n.get_instance_id()):
					continue
				var rel := n.global_position - eye
				if rel.length() > 8.0:
					continue
				var dv := n.velocity - p.velocity
				var dv2 := dv.length_squared()
				if dv2 < 1.0:
					continue
				var tca := -rel.dot(dv) / dv2
				if tca < 0.15 or tca > 0.35:
					continue
				var miss := (rel + dv * tca).length()
				if miss > 0.6:
					continue
				shot_ids[n.get_instance_id()] = true
				n_face += 1
				cam.fov = 100.0
				cam.global_position = eye
				cam.look_at(n.global_position, Vector3.UP)
				var ang := rad_to_deg(n.get_wingspan() / rel.length())
				_cap.text = "Eye of a %.2f-kg player (lapping, protected %s): a %s (%s, not after the player) %.1f m away at %.1f m/s,\nclosest approach %.2f m in %.2f s; %.0f deg across (100 deg FOV)" % [pm, str(bool(p.get_meta(&"npc_ignore", false))), n.species, n.state_name(), rel.length(), n.velocity.length(), miss, tca, ang]
				await _save("face_%d_%s.png" % [n_face, n.species])
				# And the frame at closest approach.
				var steps := int(round(tca / DT))
				for j in steps:
					if world.has_method(&"set_air_time"):
						world.call(&"set_air_time", (i + 1 + j) * DT)
					p.step(DT)
					e.step(DT)
					chk.step(DT)
				i += steps
				if is_instance_valid(n):
					var eye2 := p.get_body_position()
					cam.global_position = eye2
					var fwd := Vector3(p.velocity.x, 0.0, p.velocity.z).normalized()
					cam.look_at(eye2 + fwd * 10.0, Vector3.UP)
					_cap.text = "Same pass at closest approach, looking along the flight: %s %.2f m from the eye (camera near plane 0.02 m)" % [n.species, n.global_position.distance_to(eye2)]
					await _save("face_%d_%s_closest.png" % [n_face, n.species])
				break
		if n_perch < 4 and t - last_perch_t > 15.0:
			var space := world.get_world_3d().direct_space_state
			for n in e.get_npcs():
				if not n.perched or n.perch_spot == null or shot_ids.has(n.get_instance_id()):
					continue
				var k := n.perch_spot.kind
				if k != Perch.Kind.BRANCH and k != Perch.Kind.WIRE:
					continue
				if Paths.arg("r4_kind", "") == "branch" and k != Perch.Kind.BRANCH:
					continue
				if n.global_position.distance_to(eye) > 150.0 or n.state_time < 1.0:
					continue
				# A spot ~2.5 wingspans off the bird, level with it or a bit
				# above, with a clear line to it: in front, the sides, behind.
				var fc := n.perch_spot.facing
				var cam_at := Vector3.INF
				var dist := maxf(n.get_wingspan() * 2.5, 1.2) * float(Paths.arg("r4_dist", "1.0"))
				for a in [0.0, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, PI]:
					var dir: Vector3 = fc.rotated(Vector3.UP, a)
					var c: Vector3 = n.global_position + dir * dist + Vector3.UP * dist * 0.35
					var q := PhysicsRayQueryParameters3D.create(c, n.global_position + (c - n.global_position).normalized() * n.get_body_radius() * 1.2, 1)
					if space.intersect_ray(q).is_empty() and space.intersect_point(_pt(c)).is_empty():
						cam_at = c
						break
				if cam_at == Vector3.INF:
					continue
				shot_ids[n.get_instance_id()] = true
				n_perch += 1
				last_perch_t = t
				cam.global_position = cam_at
				cam.fov = 40.0
				cam.look_at(n.global_position, Vector3.UP)
				_cap.text = "A perched %s (NPC, in the ecosystem round a %.2f-kg player) on a %s, camera %.1f m off, 40 deg FOV, seated %.1f s" % [n.species, pm, "branch" if k == Perch.Kind.BRANCH else "wire", dist, n.state_time]
				var dbg: Array[Node] = []
				if Paths.arg("r4_shapes", "") != "":
					dbg = _show_shapes(n.global_position, 0.6, n.perch_spot.position)
				await _save("perched_%s%d_%s.png" % [Paths.arg("r4_kind", ""), n_perch, n.species])
				for d in dbg:
					d.queue_free()
				cam.fov = 100.0
				break
		if n_perch >= 4:
			break
	print("[ai-r4x] eye shots: %d face, %d perched" % [n_face, n_perch])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	for j in 3:
		await get_tree().process_frame


## Collision shapes (layers 1|2) within r of c drawn as translucent red, and
## the perch grip point as a small yellow ball: does the visible wood match
## what the bird is sitting on?
func _show_shapes(c: Vector3, r: float, grip: Vector3) -> Array[Node]:
	var out: Array[Node] = []
	var sph := SphereShape3D.new()
	sph.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sph
	q.transform = Transform3D(Basis.IDENTITY, c)
	q.collision_mask = 1 | 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for hit in world.get_world_3d().direct_space_state.intersect_shape(q, 16):
		var col: Object = hit["collider"]
		if col == null or not (col is CollisionObject3D):
			continue
		var co := col as CollisionObject3D
		var owner_id := co.shape_find_owner(hit["shape"])
		var shp := co.shape_owner_get_shape(owner_id, 0)
		if shp == null or shp is ConcavePolygonShape3D:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = shp.get_debug_mesh()
		mi.material_override = mat
		add_child(mi)
		mi.global_transform = co.global_transform * co.shape_owner_get_transform(owner_id)
		out.append(mi)
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.012
	sm.height = 0.024
	ball.mesh = sm
	var ym := StandardMaterial3D.new()
	ym.albedo_color = Color(1, 0.9, 0)
	ym.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ym.no_depth_test = true
	ball.material_override = ym
	add_child(ball)
	ball.global_position = grip
	out.append(ball)
	print("[ai-r4x] shapes near perched bird: %d" % (out.size() - 1))
	return out


func _pt(c: Vector3) -> PhysicsPointQueryParameters3D:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = c
	q.collision_mask = 1
	return q


func _save(file: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _dir.path_join(file)
	img.save_png(path)
	print("[ai-r4x] saved ", path)
