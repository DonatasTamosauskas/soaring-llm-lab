extends Node3D
## VERIFIER RENDER (round 2, experience lens, forward_plus): the REAL valley
## (SoaringWorld) with the 60-NPC ecosystem, seen from the player's eye -
## what the sky looks like in the shipped world, not the AI test arena.
## A mock player laps round the player spawn at its size's cruise speed for
## 45 s of sim, then the camera sits at its eye looking along its path
## (100 deg horizontal FOV, about a Quest Pro eye; 12.8 px/deg here vs
## ~20 on the headset). A second frame per size looks at the nearest NPC
## that is hunting or fleeing (the action the player might witness).
## Outputs artifacts/ai/verify/r2/eye_<size>.png and action_<size>.png.
##   tools/gd.sh aiexp --rendering-method forward_plus --resolution 1280x720 res://tests/probes/ai/r2x_eye_shots.tscn

const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const DT := 1.0 / 72.0

var world: World
var cam: Camera3D
var _cap: Label


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
	_cap.add_theme_font_size_override("font_size", 20)
	_cap.add_theme_color_override("font_color", Color("#0b0b0b"))
	_cap.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_cap.add_theme_constant_override("outline_size", 6)
	cl.add_child(_cap)
	for i in 4:
		await get_tree().physics_frame
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r2"))
	for c in [["sparrow", 0.03, 11], ["pigeon", 0.3, 12], ["eagle", 3.0, 13]]:
		await _size(c[0], c[1], c[2])
	print("[ai-r2x] eye shots done")
	get_tree().quit()


func _size(tag: String, pm: float, seed_v: int) -> void:
	var p := MockPlayer.new()
	p.mass = pm
	var spawn := world.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, world.ground_height(spawn.x + cos(a) * 90.0, spawn.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	add_child(p)
	p.step(0.0)
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	for i in int(45.0 / DT):
		p.step(DT)
		e.step(DT)
		if i % 24 == 0:
			await get_tree().process_frame
	# Eye view along the path.
	var eye := p.get_body_position()
	var fwd := p.velocity.normalized()
	cam.global_position = eye
	cam.look_at(eye + fwd * 10.0 + Vector3.DOWN * 1.0, Vector3.UP)
	await get_tree().process_frame
	var vis := 0
	var vis_prey := 0
	var hidden := 0
	var near := 0
	for n in e.get_npcs():
		if n.hidden:
			hidden += 1
			continue
		var d := n.global_position.distance_to(eye)
		if d < 60.0:
			near += 1
		if cam.is_position_in_frustum(n.global_position) and d < 200.0:
			vis += 1
			if SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass):
				vis_prey += 1
	_cap.text = "Real valley, %s-sized player (%.2f kg) after 45 s of laps: eye view along its path, 100 deg FOV\n%d NPCs in frame < 200 m (%d worthwhile prey), %d within 60 m, %d of %d hidden in refuges\nstates %s" % [tag, pm, vis, vis_prey, near, hidden, e.count(), e.stats()["by_state"]]
	await _save("eye_%s.png" % tag)
	# The nearest action: a hunter or a fleeing bird, framed from the eye.
	var best: NpcBird = null
	var best_d := INF
	for n in e.get_npcs():
		if n.state == NpcBird.State.HUNT or n.state == NpcBird.State.STOOP or n.state == NpcBird.State.FLEE:
			var d := n.global_position.distance_to(eye)
			if d < best_d:
				best_d = d
				best = n
	if best != null:
		cam.look_at(best.global_position, Vector3.UP)
		await get_tree().process_frame
		var other := best.target if best.target != null else best.threat
		_cap.text = "Same moment, looking at the nearest action: %s %s %s at %.0f m (%s)" % [best.species, best.state_name(), (other.species if other != null else "-"), best_d, "the player" if other != null and other.is_player() else "NPC vs NPC"]
		await _save("action_%s.png" % tag)
	e.queue_free()
	p.queue_free()
	for i in 3:
		await get_tree().process_frame


func _save(file: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("ai").path_join("verify/r2/" + file)
	img.save_png(path)
	print("[ai-r2x] saved ", path)
