extends Node3D
## VERIFIER render (forward_plus): what the AI looks like up close and from
## the player's eye.
##  landing_a/b/c.png  a sparrow landing on a hedge-top branch, camera 2.5 m
##                     away: during the approach, mid final (vertical) leg,
##                     and the frame after it settles.
##  eye_sparrow.png    the view ahead of a sparrow-sized player that has been
##                     flying straight across the valley for 60 s, with a
##                     60-NPC ecosystem (camera at the player, 90 deg FOV).
##
##   tools/gd.sh ai_verify --rendering-method forward_plus --resolution 1280x720 res://tests/probes/ai/ai_verify_shots.tscn

const DT := 1.0 / 72.0

var world: AiTestWorld
var cam: Camera3D
var _cap: Label


func _ready() -> void:
	world = AiTestWorld.new()
	world.with_visuals = true
	world.with_environment = true
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var cl := CanvasLayer.new()
	add_child(cl)
	_cap = Label.new()
	_cap.position = Vector2(16, 12)
	_cap.add_theme_font_size_override("font_size", 22)
	_cap.add_theme_color_override("font_color", Color("#0b0b0b"))
	_cap.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.85))
	_cap.add_theme_constant_override("outline_size", 6)
	cl.add_child(_cap)
	for i in 3:
		await get_tree().physics_frame
	await _landing()
	await _eye()
	print("[ai-verify] shots done")
	get_tree().quit()


func _save(name: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("ai").path_join("verify/" + name)
	img.save_png(path)
	print("[ai-verify] saved ", path)


func _landing() -> void:
	var h := Habitat.for_world(world)
	var list := h.find_perches(Vector3(-40, 0, -90), 60.0, 0.24, [0])
	var p: Perch = list[0]
	var b := NpcBird.new()
	b.managed = true
	b.configure(&"sparrow", -1.0, 99, h)
	add_child(b)
	var start := p.position + Vector3(10.0, 3.0, 6.0)
	var v := (p.position - start).normalized() * 8.0
	b.global_transform = Transform3D(Basis.looking_at(v.normalized(), Vector3.UP), start)
	b.flight.set_velocity(v)
	b.energy = 0.05
	b.can_flee = false
	b.can_hunt = false
	b.brain.habitat = h
	b.brain._p = start
	# Claim this exact perch (the brain's own PERCH state then flies it).
	b.perch_spot = p
	p.occupant = b
	b.set_contact_target(p.position, 1.2)
	b.brain._perch_phase = 0
	b.set_state(NpcBird.State.PERCH)
	cam.fov = 30.0
	var side := p.facing.cross(Vector3.UP).normalized()
	cam.global_position = p.position + side * 3.0 + Vector3.UP * 0.25
	cam.look_at(p.position + Vector3.UP * 0.15, Vector3.UP)
	var tp := p.position + Vector3.UP * b.get_body_radius() * 0.8
	var shot := {"a": false, "b": false}
	var legs := 0
	var was_flaring := false
	for i in int(40.0 / DT):
		b.tick(DT)
		if b.is_flaring() and not was_flaring:
			legs += 1
		was_flaring = b.is_flaring()
		var d := b.global_position.distance_to(p.position)
		if not shot["a"] and d < 3.0 and not b.perched:
			shot["a"] = true
			_cap.text = "Sparrow approaching the hedge-top perch (beak y %.2f)" % b.get_forward().y
			await _save("landing_a.png")
		if not shot["b"] and b.is_flaring() and b._flare_to.distance_to(tp) < 0.02:
			if b._flare_t > b._flare_T * 0.45:
				shot["b"] = true
				_cap.text = "Final flare leg (straight down onto the perch): beak y %.2f, body up.y %.2f" % [b.get_forward().y, b.global_basis.y.normalized().y]
				await _save("landing_b.png")
		if b.perched:
			_cap.text = "One tick later: perched (beak y %.2f) - rotated in one frame" % b.get_forward().y
			await _save("landing_c.png")
			break
		if i % 4 == 0 and not b.is_flaring():
			await get_tree().process_frame
	b.queue_free()
	await get_tree().process_frame


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


func _eye() -> void:
	var p := Traveller.new()
	p.mass = 0.03
	add_child(p)
	p.step(0.0)
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 11
	add_child(e)
	e.focus = p
	for i in int(50.0 / DT):
		p.step(DT)
		e.step(DT)
		if i % 36 == 0:
			await get_tree().process_frame
	await _eye_shot(p, e, "eye_sparrow.png", 50.0)
	for i in int(35.0 / DT):
		p.step(DT)
		e.step(DT)
		if i % 36 == 0:
			await get_tree().process_frame
	await _eye_shot(p, e, "eye_sparrow_midmap.png", 85.0)
	e.queue_free()
	p.queue_free()


func _eye_shot(p: Bird, e: Ecosystem, file: String, t: float) -> void:
	cam.fov = 90.0
	var eye := p.get_body_position()
	cam.global_position = eye
	cam.look_at(eye + p.velocity.normalized() * 10.0 + Vector3.DOWN * 1.5, Vector3.UP)
	var in_frustum := 0
	var within50 := 0
	var prey60 := 0
	for n in e.get_npcs():
		var d := n.global_position.distance_to(eye)
		if d < 50.0:
			within50 += 1
		if SizeRules.is_worthwhile(p.mass, n.mass) and SizeRules.can_eat(p.mass, n.mass) and d < 60.0:
			prey60 += 1
		if cam.is_position_in_frustum(n.global_position) and d < 250.0:
			in_frustum += 1
	_cap.text = "Sparrow player's view, t=%.0f s at 12 m/s, x=%.0f: %d NPCs in view <250 m\n%d within 50 m, %d worthwhile prey <60 m (of %d NPCs)" % [t, eye.x, in_frustum, within50, prey60, e.count()]
	await _save(file)
