extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): the player's "npc_chasers" meta (at most one NPC
## chases the player at a time) is decremented only through NpcBrain's
## _drop_target. If the Ecosystem node is freed (scene swap, integration
## re-instancing it) while an NPC is chasing the player, is the count left
## stuck at 1 - so no NPC will ever hunt the player again?


func test_chasers_meta_after_freeing_the_ecosystem() -> void:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = 0.3
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 60.0
	p.path_height = 30.0
	p.speed = 9.0
	p.protect_s = 0.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 5)
	e.focus = p
	var chasing := false
	for i in int(120.0 / DT):
		p.step(DT)
		e.step(DT)
		for n in e.get_npcs():
			if n.target == p:
				chasing = true
		if chasing:
			break
	var before := int(p.get_meta(&"npc_chasers", 0))
	e.queue_free()
	eco = null
	await wait_frames(3)
	var after := int(p.get_meta(&"npc_chasers", 0))
	print("[ai] v2r chasers: an NPC was chasing=%s, npc_chasers before free=%d, after free=%d" % [chasing, before, after])
	check(chasing, "an NPC started chasing the player")
	eq(after, 0, "npc_chasers back to 0 once the chasing NPC is gone")
	remove_child(p)
	p.queue_free()
	await clear_sim()
