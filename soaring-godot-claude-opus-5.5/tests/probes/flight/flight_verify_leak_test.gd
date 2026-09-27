extends TestCase
## Verifier probe (round 1, flight): does a PlayerBird leak objects over its
## life? Builds scenes/player/player.tscn in a stub world WITHOUT the flight
## test fixture (whose lambdas capture the fixture itself), flies it with a
## scripted source, the bot pilot and the desktop source through perching,
## collisions, respawn and growth, frees everything and compares the live
## object count with the baseline.

const PLAYER := preload("res://scenes/player/player.tscn")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const DT := 1.0 / 72.0


static func _airplane(_tick: int, t: float, b: HumanPoseModel) -> void:
	b.set_airplane()
	if fmod(t, 6.0) > 3.0:
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)


func _cycle(kind: int) -> void:
	var w := TW.new()
	w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 10.0, 0.02, 1.0)
	w.add_wall(Vector3(0, 30, -60), Vector3(40, 60, 1))
	w.add_rod(Vector3(-5, 25, -30), Vector3(5, 25, -30), 0.01)
	add_child(w)
	await get_tree().physics_frame
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.drive_world_scale = true
	p.default_source = &"none"
	add_child(p)
	match kind:
		0:
			p.set_pose_source(ScriptedPoseSource.new(HumanPoseModel.new(3), _airplane))
		1:
			var course := FlightCourse.new(p.mass)
			var pilot := FlightAutopilot.new(p.model.params, course)
			p.set_pose_source(BotPoseSource.new(pilot, func() -> Dictionary:
				return {"pos": Vector3(0, 30, 0), "vel": Vector3(0, 0, -9), "airspeed": 9.0}, 21))
		2:
			p.set_pose_source(DesktopPoseSource.new())
	p.start_flying(Vector3(0, 30, 0), 0.0)
	for i in 1500:
		if i == 300:
			p.respawn(Transform3D(Basis.IDENTITY, Vector3(0, 20.05, -10)))
		if i == 400:
			p.start_flying(Vector3(0, 30, -40), 0.0)
		if i == 700:
			p.mass = 0.3
		if i == 900:
			Events.recenter_requested.emit()
		p.tick(DT)
	p.get_parent().remove_child(p)
	p.free()
	w.get_parent().remove_child(w)
	w.free()
	await get_tree().process_frame
	await get_tree().process_frame


func test_player_bird_does_not_leak() -> void:
	# Warm up (first-use caches: reference tables, shaders, class statics).
	for k in 3:
		await _cycle(k)
	var base := Performance.get_monitor(Performance.OBJECT_COUNT)
	var base_res := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var base_nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for rep in 3:
		for k in 3:
			await _cycle(k)
	var after := Performance.get_monitor(Performance.OBJECT_COUNT)
	var after_res := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var after_nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	print("[flight_verify] objects %d -> %d, resources %d -> %d, nodes %d -> %d over 9 player lives" % [base, after, base_res, after_res, base_nodes, after_nodes])
	metric("objects_delta", after - base)
	metric("resources_delta", after_res - base_res)
	metric("nodes_delta", after_nodes - base_nodes)
	lt(after - base, 9.0, "no per-life object leak (9 PlayerBird lives)")
	lt(after_res - base_res, 1.0, "no per-life resource leak")
	lt(after_nodes - base_nodes, 1.0, "no per-life node leak")
