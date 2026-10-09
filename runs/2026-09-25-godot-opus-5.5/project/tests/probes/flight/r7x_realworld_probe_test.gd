extends TestCase
## Verifier probe (verification round 3, flight, EXPERIENCE lens): the
## ceiling finding of r7x_experience_probe in the REAL world scene
## (scenes/world/world.tscn: its own 300 m lid, its own wind). Informative
## only: it depends on the world area's current build, so the flight suite
## must not; this checks that the synthetic lid reproduces the game.
## Output: artifacts/flight/verify/r7x/realworld_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0

var fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r7x/realworld_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func test_r7x_real_world_lid() -> void:
	var t0 := Time.get_ticks_msec()
	var ws := load("res://scenes/world/world.tscn") as PackedScene
	if ws == null:
		check(false, "world scene loads")
		return
	var world := ws.instantiate() as World
	add_child(world)
	var n := 0
	while not world.is_generated and n < 600:
		await get_tree().process_frame
		n += 1
	_log("[real world] generated %s in %d ms, ceiling %.0f m, bounds %.0f m" % [world.is_generated, Time.get_ticks_msec() - t0, world.ceiling, world.bounds_radius])
	check(world.is_generated, "the real world generates")
	for sp: StringName in [&"sparrow", &"pigeon"]:
		fx = FX.new(self)
		await fx.setup(sp)
		# The fixture's flat test world out, the real one in.
		var tw := fx.world
		tw.get_parent().remove_child(tw)
		tw.free()
		fx.world = world
		var p := fx.player
		var spawn := world.get_player_spawn().origin
		var start := Vector3(spawn.x, world.ceiling - 40.0, spawn.z)
		p.start_flying(start, 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.3)
		fx.reset_events()
		var st := {"top": -INF}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var q: PlayerBird = f.player
			st["top"] = maxf(float(st["top"]), q.model.position.y + q.model.params.r_body)
		fx.run(30.0)
		_log("[real world lid] %s, reference strokes from %.0f m (spawn x/z): top %.2f m (ceiling %.0f), stuns %d, slides %d, collided events %d, impacts %s, end y %.1f, %s" % [
			sp, start.y, st["top"], world.ceiling, p.contacts["stun"], p.contacts["slide"], fx.events["collided"], str(fx.collide_impacts.slice(0, 5)),
			p.model.position.y, p.mode_name()])
		eq(p.contacts["stun"], 0, "%s: the real world's lid never stuns a flapping bird" % sp)
		# Keep the real world for the next size: detach it from the fixture.
		fx.world = null
		fx.teardown()
		fx = null
		await get_tree().process_frame
	world.get_parent().remove_child(world)
	world.queue_free()
	await get_tree().process_frame
