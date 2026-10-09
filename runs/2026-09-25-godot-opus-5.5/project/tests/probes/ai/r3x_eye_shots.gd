extends Node3D
## VERIFIER RENDER (round 3, experience lens, forward_plus): the shipped valley
## with the 60-NPC ecosystem, seen through the eyes of a player who HUNTS
## (tests/probes/ai/r3x_seeker_player.gd flying the NPC physics at its mass).
## For a sparrow, a pigeon and a hawk: hunt until a chase is on with the prey
## 5-25 m away, then frame the eye view on the prey (100 deg horizontal FOV,
## about a Quest Pro eye; 12.8 px/deg here vs ~20 on the headset), and one
## frame looking along the flight path at 30 s (the ambient sky).
## Outputs artifacts/ai/verify/r3/eye_chase_<size>.png, eye_ahead_<size>.png.
##   tools/gd.sh ai_verify --rendering-method forward_plus --resolution 1280x720 res://tests/probes/ai/r3x_eye_shots.tscn

const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
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
	_cap.add_theme_font_size_override("font_size", 18)
	_cap.add_theme_color_override("font_color", Color("#0b0b0b"))
	_cap.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_cap.add_theme_constant_override("outline_size", 6)
	cl.add_child(_cap)
	for i in 4:
		await get_tree().physics_frame
	if not world.is_generated:
		await world.generated
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r3"))
	for c in [["sparrow", 0.03, 901], ["pigeon", 0.3, 902], ["hawk", 1.3, 903]]:
		await _size(c[0], c[1], c[2])
	print("[ai-r3x] eye shots done")
	get_tree().quit()


func _size(tag: String, pm: float, seed_v: int) -> void:
	var s := Seeker.new()
	add_child(s)
	s.setup(world, pm, world.get_player_spawn().origin)
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = s
	s.active = false
	var shot_ahead := false
	var shot_chase := false
	for i in int(120.0 / DT):
		var tt := i * DT
		s.active = tt > 15.0
		s.step(DT, e.get_npcs())
		e.step(DT)
		if i % 24 == 0:
			await get_tree().process_frame
		if not shot_ahead and tt >= 30.0:
			shot_ahead = true
			var eye := s.get_body_position()
			var fwd := Vector3(s.velocity.x, 0.0, s.velocity.z).normalized()
			cam.global_position = eye
			cam.look_at(eye + fwd * 10.0 + Vector3.DOWN * 1.5, Vector3.UP)
			var inf := _frame_info(e, s, pm)
			_cap.text = "Valley, hunting %s-sized player (%.2f kg), 30 s in: eye view along its flight, 100 deg FOV\n%s" % [tag, pm, inf]
			await _save("eye_ahead_%s.png" % tag)
		if not shot_chase and tt > 20.0 and s.target != null and is_instance_valid(s.target):
			var d := s.global_position.distance_to(s.target.global_position)
			if d > 5.0 and d < 25.0 and s._chase_t > 1.0:
				shot_chase = true
				var eye := s.get_body_position()
				cam.global_position = eye
				cam.look_at(s.target.global_position, Vector3.UP)
				var ang := rad_to_deg(s.target.get_wingspan() / d)
				var inf := _frame_info(e, s, pm)
				_cap.text = "Valley, %s-sized player chasing a %s (%s) at %.1f m: %.2f deg across (~%.0f px on Quest Pro)\n%s" % [tag, s.target.species, s.target.state_name(), d, ang, ang * 20.0, inf]
				await _save("eye_chase_%s.png" % tag)
		if shot_ahead and shot_chase:
			break
	e.queue_free()
	remove_child(s)
	s.queue_free()
	for i in 3:
		await get_tree().process_frame


func _frame_info(e: Ecosystem, s: Node3D, pm: float) -> String:
	var eye: Vector3 = s.get_body_position()
	var vis := 0
	var vis_prey := 0
	var big := 0
	for n in e.get_npcs():
		if n.hidden:
			continue
		var d := n.global_position.distance_to(eye)
		if cam.is_position_in_frustum(n.global_position) and d < 250.0:
			vis += 1
			if SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass):
				vis_prey += 1
			if rad_to_deg(n.get_wingspan() / d) >= 0.3:
				big += 1
	return "%d NPCs in frame < 250 m, %d of them >= 0.3 deg across, %d worthwhile prey; states %s" % [vis, big, vis_prey, e.stats()["by_state"]]


func _save(file: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("ai").path_join("verify/r3/" + file)
	img.save_png(path)
	print("[ai-r3x] saved ", path)
