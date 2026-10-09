extends TestCase
## DIAGNOSTIC (integration round 2, not in the unit suites): what holds a
## bird that the soak found frozen at a point for minutes (--wedge=x,y,z):
## the geometry round it (rays in 16 bearings, level, up and down; which
## bodies), and whether a starling-sized player put there flies out with the
## person pilot.
##
##   tools/gd.sh fx_wedge --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_wedge --fresh-settings --wedge=-53.9,6.4,35.8

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const PersonPilot := preload("res://tests/unit/integration/integration_person_pilot.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_wedge() -> void:
	var m := kit.main
	var w := Paths.arg("wedge", "-53.9,6.4,35.8").split(",")
	var p := Vector3(float(w[0]), float(w[1]), float(w[2]))
	var space := m.player.get_world_3d().direct_space_state
	print("[integration] wedge at %s: ground %.2f" % [p, m.world.ground_height(p.x, p.z)])
	for up: float in [-0.7, 0.0, 0.7]:
		var row := []
		for k in 16:
			var a := TAU * k / 16.0
			var d := Vector3(cos(a), up, sin(a)).normalized()
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p, p + d * 10.0, 1))
			row.append("%.1f%s" % [10.0 if hit.is_empty() else p.distance_to(hit["position"]),
				"" if hit.is_empty() else "(%s)" % String((hit["collider"] as Node).name).left(14)])
		print("[integration] wedge rays up %.1f: %s" % [up, row])
	var pq := PhysicsPointQueryParameters3D.new()
	pq.position = p
	pq.collision_mask = 1
	var inside := space.intersect_point(pq)
	print("[integration] wedge: point inside %d bodies %s" % [inside.size(), inside.map(func(h: Dictionary) -> String: return String((h["collider"] as Node).get_path()))])
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop._set_player_mass(m.player, 0.1, &"diag")
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(3, PersonPilot)
	kit.nav = &"heading"
	m.player.start_flying(p, 0.0)
	var path := []
	for i in 20:
		await kit.advance(0.5)
		path.append([snappedf(m.player.global_position.x, 0.1), snappedf(m.player.global_position.y, 0.1), snappedf(m.player.global_position.z, 0.1), m.player.mode_name()])
	print("[integration] wedge: flown out? %s; unsticks %d" % [path, int(kit.pilot.get(&"unsticks"))])
