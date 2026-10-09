extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (ai, round 1) - not part of the area suite.
## A6 says spawns are never inside the player's view cone or near distance.
## Ecosystem._spawn_point checks one point per group, but a flock's members
## are then scattered around it (ecosystem.gd _spawn_group). This forces many
## flock spawns with the view direction swept round and checks every member
## with the same rule the area's own ecosystem_test uses.
##
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=spawn


func test_probe_every_flock_member_spawns_out_of_view() -> void:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = 0.03
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 5)
	e.focus = p
	e.step(DT)
	var cosv := cos(deg_to_rad(e.view_half_angle_deg))
	var res := {}
	for sp: StringName in [&"starling", &"sparrow"]:
		var r := {"groups": 0, "members": 0, "view": 0, "near": 0, "examples": []}
		if not e._plan.has(sp):
			fail("plan has no %s entry to spawn from" % sp)
			continue
		var need := 22 if sp == &"starling" else 7
		for i in 400:
			p.moving = true
			p.step(0.37)
			var before := e.get_npcs().size()
			e._spawn_group(sp, need, p)
			var npcs := e.get_npcs()
			var fresh: Array = npcs.slice(before)
			if fresh.size() > 1:
				r["groups"] += 1
			var eye := p.get_body_position()
			var vd: Vector3 = p.get_view_direction()
			for npc: NpcBird in fresh:
				r["members"] += 1
				var rel := npc.global_position - eye
				var d := rel.length()
				if d < e.spawn_min:
					r["near"] += 1
					if r["examples"].size() < 4:
						r["examples"].append("near %.1f m" % d)
				elif vd.dot(rel / d) > cosv:
					r["view"] += 1
					if r["examples"].size() < 4:
						r["examples"].append("in view: %.1f deg off the view dir (cone %.0f), %.1f m" % [rad_to_deg(acos(clampf(vd.dot(rel / d), -1.0, 1.0))), e.view_half_angle_deg, d])
			for npc: NpcBird in fresh:
				e._remove(npc, &"probe")
		res[String(sp)] = r
		eq(r["view"], 0, "%s flock members spawned inside the view cone" % sp)
		eq(r["near"], 0, "%s flock members spawned nearer than spawn_min" % sp)
	metric("flock_spawns", res)
	print("[ai-verify] flock spawn members vs view cone: ", res)
	remove_child(p)
	p.queue_free()
	await clear_sim()
