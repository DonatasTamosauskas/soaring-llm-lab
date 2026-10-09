extends SceneTree
## Diagnostics (core loop round): what solid geometry surrounds a point of
## the shipped valley - the colliders a sphere there touches (their owners'
## paths) and how far rays reach in 16 bearings, level, up and down. Used to
## see where a real-chain run's player got pinned.
##   tools/gd.sh gl_probe --headless -s res://tests/shots/gameloop_pin_probe.gd -- --at=-38.3,11.1,39.0 --r=0.3

const WorldScene := preload("res://scenes/world/world.tscn")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var at := Vector3(-38.3, 11.1, 39.0)
	var r := 0.3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--at="):
			var p := a.substr(5).split(",")
			at = Vector3(float(p[0]), float(p[1]), float(p[2]))
		elif a.begins_with("--r="):
			r = float(a.substr(4))
	var world := WorldScene.instantiate() as World
	if &"with_environment" in world:
		world.set(&"with_environment", false)
	root.add_child(world)
	for i in 10:
		await physics_frame
	var space := world.get_world_3d().direct_space_state
	var sph := SphereShape3D.new()
	for rr: float in [r, r * 2.0, r * 4.0, 1.5]:
		sph.radius = rr
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = sph
		q.transform = Transform3D(Basis.IDENTITY, at)
		q.collision_mask = 0xFFFFFFFF
		var hits := space.intersect_shape(q, 32)
		var names: Array = []
		for h in hits:
			var c: Object = h["collider"]
			var n := c as Node
			names.append("%s (layer %d, shape %d)" % [str(n.get_path()) if n else str(c), (c as CollisionObject3D).collision_layer if c is CollisionObject3D else -1, int(h["shape"])])
		print("[gameloop] probe sphere r=%.2f at %s: %d hits %s" % [rr, at, hits.size(), names])
	print("[gameloop] ground at %.2f" % world.ground_height(at.x, at.z))
	for up: float in [-0.9, 0.0, 0.6, 0.99]:
		var line := ""
		for k in 16:
			var ang := TAU * k / 16.0
			var d := Vector3(cos(ang) * sqrt(1.0 - up * up), up, sin(ang) * sqrt(1.0 - up * up))
			var rq := PhysicsRayQueryParameters3D.create(at, at + d * 25.0, 1)
			rq.hit_from_inside = true
			var hit := space.intersect_ray(rq)
			line += " %4.1f" % (25.0 if hit.is_empty() else at.distance_to(hit["position"]))
		print("[gameloop] rays up=%.2f:%s" % [up, line])
	quit(0)
