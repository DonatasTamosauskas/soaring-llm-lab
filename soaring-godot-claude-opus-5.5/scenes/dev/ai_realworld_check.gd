extends Node3D
## Dev check (not a suite test - it depends on the world area's in-progress
## SoaringWorld): run the ecosystem in the real valley around a player
## flying laps, with the stand-in catch rule and the A5 safety monitor, and
## print what happened: behaviour counts, safety counts by situation, the
## first unsticks, and for each "inside" sample the bird, its state and the
## collider it is in (the trail to follow when something goes wrong).
##
##   tools/gd.sh ai --headless res://scenes/dev/ai_realworld_check.tscn -- [--sim_s=180]

const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const DT := 1.0 / 72.0

var _sq: PhysicsShapeQueryParameters3D


func _ready() -> void:
	var sim_s := float(Paths.arg("sim_s", "180"))
	var w := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(w)
	for i in 3:
		await get_tree().physics_frame
	var h := Habitat.for_world(w)
	print("[ai] real world: bounds %.0f ceiling %.0f perches %d refuges %d thermals %d landmark kinds %s" % [w.bounds_radius, w.ceiling, w.get_perches().size(), h.refuges.size(), h.thermals.size(), h.landmarks.keys()])
	var p := MockPlayer.new()
	p.mass = 0.1
	var spawn := w.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	p.path_height = w.ground_height(spawn.x, spawn.z) + 25.0
	p.speed = 11.0
	add_child(p)
	p.step(0.0)
	var e := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	e.auto_step = false
	add_child(e)
	var chk: RefCounted = CatchChecker.new()
	var unstuck := {}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what == &"unstick":
				var k := "%s/%s%s refuge=%s bumps=%d" % [b.species, b.state_name(), "/flare" if b.is_flaring() else "", not b.refuge.is_empty(), b.bumps]
				unstuck[k] = unstuck.get(k, 0) + 1
				if unstuck.size() <= 6 and unstuck[k] == 1:
					print("[ai] unstick %s at %s v=%.1f hit=%s n=%s refuge=%s" % [k, b.global_position.snapped(Vector3.ONE * 0.1), b.velocity.length(), b.last_hit.snapped(Vector3.ONE * 0.1), b.last_hit_normal.snapped(Vector3.ONE * 0.01), b.refuge.get("name", "-")])))
	var safety: RefCounted = Safety.new(w)
	var log: Logger = load("res://tests/unit/ai/warning_log.gd").install()
	var t0 := Time.get_ticks_msec()
	var snap := {}
	var kinds := {}
	var inside_seen := 0
	var touches := []
	_sq = PhysicsShapeQueryParameters3D.new()
	_sq.shape = SphereShape3D.new()
	_sq.collision_mask = 1
	for i in int(sim_s / DT):
		# The world's air follows simulated time (reproducible runs).
		if w.has_method(&"set_air_time"):
			w.call(&"set_air_time", i * DT)
		p.mass = 0.1 * pow(20.0, float(i) * DT / sim_s)
		p.step(DT)
		e.step(DT)
		snap.clear()
		for n in e.get_npcs():
			snap[n] = "%s%s" % [n.state_name(), "/flare" if n.is_flaring() else ""]
		var before: int = chk.catches.size()
		chk.step(DT)
		for j in range(before, chk.catches.size()):
			var c: Dictionary = chk.catches[j]
			if c["prey"] == p:
				continue
			var pr: Bird = c["predator"]
			var k := "%s:%s(%s) ate %s:%s" % [c["pred_species"], snap.get(pr, "?"), "tgt" if (pr is NpcBird and (pr as NpcBird).target == null and snap.get(pr, "") == "hunt") or snap.get(pr, "") in ["hunt", "stoop"] else "not hunting", c["prey_species"], snap.get(c["prey"], "?")]
			kinds[k] = kinds.get(k, 0) + 1
		safety.step(DT, e.get_npcs())
		# Each new "inside" sample: which bird, which collider, doing what.
		if safety.counts["inside"] > inside_seen and touches.size() < 30:
			inside_seen = safety.counts["inside"]
			for n in e.get_npcs():
				if not safety._inside(w.get_world_3d().direct_space_state, n, n.global_position):
					continue
				var q := PhysicsPointQueryParameters3D.new()
				q.collision_mask = 1
				q.position = n.global_position
				var what := []
				for hh in w.get_world_3d().direct_space_state.intersect_point(q, 4):
					var col: CollisionObject3D = hh["collider"]
					what.append("%s:%s" % [col.name, col.shape_owner_get_shape(col.shape_find_owner(hh["shape"]), 0).get_class()])
				_sq.shape.radius = n.get_body_radius() * 0.6
				_sq.transform = Transform3D(Basis.IDENTITY, n.global_position)
				for hh in w.get_world_3d().direct_space_state.intersect_shape(_sq, 4):
					what.append("touch " + str(hh["collider"].name))
				var ps := n.perch_spot
				touches.append("t=%.2f #%d %s/%s%s at %s v=%.1f in %s perch=%s refuge=%s" % [i * DT, n.get_instance_id() % 10000, n.species, n.state_name(), "/flare" if n.is_flaring() else "", n.global_position.snapped(Vector3.ONE * 0.01), n.velocity.length(), what, ps.position.snapped(Vector3.ONE * 0.01) if ps else "-", n.refuge.get("name", "-")])

	log.uninstall()
	var st := e.stats()
	var npc_catches := 0
	var by_pred := {}
	for c in chk.catches:
		if c["prey"] == p:
			continue
		npc_catches += 1
		by_pred[String(c["pred_species"])] = by_pred.get(String(c["pred_species"]), 0) + 1
	print("[ai] real world %.0f s sim in %.1f s: NPC-vs-NPC catches %d (%.1f/min) %s; player caught %d, hunts started on it %d" % [sim_s, (Time.get_ticks_msec() - t0) / 1000.0, npc_catches, npc_catches / (sim_s / 60.0), by_pred, p.times_caught, st["hunts_on_player"]])
	print("[ai] engine warnings %d errors %d %s" % [log.warnings, log.errors, log.samples])
	var kk := kinds.keys()
	kk.sort_custom(func(a: String, b2: String) -> bool: return kinds[a] > kinds[b2])
	for k in kk.slice(0, 12):
		print("[ai] catch kind %3d  %s" % [kinds[k], k])
	print("[ai] behaviour %s" % st["behaviour"])
	print("[ai] states %s roles %s lod %s tick %.2f ms (p95 %.2f)" % [st["by_state"], st["by_role"], st["lod"], st["tick_ms_avg"], st["tick_ms_p95"]])
	print("[ai] safety %s %s" % [safety.counts, safety.examples])
	print("[ai] envelope %s" % safety.envelope)
	print("[ai] situations %s" % safety.by_situation)
	print("[ai] unstick %s" % unstuck)
	for tline in touches:
		print("[ai] touch ", tline)
	get_tree().quit()
