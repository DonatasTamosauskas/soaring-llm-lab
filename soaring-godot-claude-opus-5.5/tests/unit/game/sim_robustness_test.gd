extends "res://tests/unit/game/game_fixture.gd"
## IntegratedSim survives a sky that frees birds under it. The AI's
## Ecosystem frees NPCs (eaten, recycled) whenever it likes; a chase target
## freed between steps crashed a round-1 run ("previously freed" on the
## typed call), and round 2's first guard (`target != null and not
## is_instance_valid(target)`) did not work - a freed object compares equal
## to null here - so two held-out valley runs were lost to it before the
## chase was tracked by id. This sky keeps a few still, worthwhile birds
## round the player and frees the nearest (the one it is chasing) every
## 1.5 s, spawning a new one further off.


func test_fingerprint_sees_indentation_not_comments() -> void:
	# The evidence fingerprint (IntegratedSim.code_hash) must change when
	# code changes how it runs - including a line moved into or out of a
	# block, which in GDScript is only its indentation (round 2 stripped
	# indentation: such an edit left stale evidence marked current) - and
	# not when only comments, blank lines or trailing spaces change.
	var base := "func f(x: int) -> void:\n\tif x > 0:\n\t\tprint(1)\n\tprint(2)\n"
	var moved := "func f(x: int) -> void:\n\tif x > 0:\n\t\tprint(1)\n\t\tprint(2)\n"
	var commented := "# a header\nfunc f(x: int) -> void:   \n\n\tif x > 0:\n\t\t# why\n\t\tprint(1)\n\tprint(2)  \n"
	var hashes := []
	for i in 3:
		var dir := "user://fp_%d_%d" % [OS.get_process_id(), i]
		DirAccess.make_dir_recursive_absolute(dir)
		var path := dir.path_join("same_name.gd")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string([base, moved, commented][i])
		f.close()
		var paths: Array[String] = [path]
		hashes.append(IntegratedSim.code_hash(paths))
		DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(dir)
	check(hashes[0] != hashes[1], "a line moved into the if block changes the fingerprint")
	eq(hashes[2], hashes[0], "comments, blank lines and trailing spaces do not")
	# The growth tuning is left out (the evidence records and checks it on
	# its own); any other constant is not.
	var dir2 := "user://fp_%d_g" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(dir2)
	var p2 := dir2.path_join("same_name.gd")
	var hs := []
	for body in ["const GROWTH_GAIN := 1.0\nconst OTHER := 1.0\n", "const GROWTH_GAIN := 2.0\nconst OTHER := 1.0\n",
			"const GROWTH_GAIN := 1.0\nconst OTHER := 2.0\n"]:
		var f2 := FileAccess.open(p2, FileAccess.WRITE)
		f2.store_string(body)
		f2.close()
		var ps: Array[String] = [p2]
		hs.append(IntegratedSim.code_hash(ps, [], IntegratedSim.FINGERPRINT_SKIP_LINES))
	DirAccess.remove_absolute(p2)
	DirAccess.remove_absolute(dir2)
	# A directory is hashed with its subdirectories (core loop fix round 1:
	# scripts/flight/pose_sources and scripts/game/sim were left out of the
	# real-chain fingerprint).
	var root := "user://fp_%d_r" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(root.path_join("sub"))
	var deep := root.path_join("sub").path_join("deep.gd")
	var hd := []
	for body in ["const A := 1\n", "const A := 2\n"]:
		var f3 := FileAccess.open(deep, FileAccess.WRITE)
		f3.store_string(body)
		f3.close()
		var pr: Array[String] = [root]
		hd.append(IntegratedSim.code_hash(pr))
	DirAccess.remove_absolute(deep)
	DirAccess.remove_absolute(root.path_join("sub"))
	DirAccess.remove_absolute(root)
	check(hd[1] != hd[0], "an edit in a subdirectory of a hashed directory changes the fingerprint")
	check(IntegratedSim.FINGERPRINT_FILES.has("res://scripts/game/sim/cue_track.gd"),
			"the mirror's fingerprint covers CueTrack, which measures its cue evidence")
	eq(hs[1], hs[0], "the growth gain is left to the evidence's tuning record")
	check(hs[2] != hs[0], "any other constant changes the fingerprint")
	# Exactly the tuning every evidence file records and pacing_test checks
	# against the shipped values (growth, and since fix round 5 the Quest
	# growth exponent and the danger constants) - no rule constant.
	eq(IntegratedSim.FINGERPRINT_SKIP_LINES, ["const GROWTH_GAIN :=", "const GROWTH_SIZE_EXP :=", "const SKY_GROWTH_EXP :=",
		"const ATTACK_RESPITE_S :=", "const BOLD_DECAY :=", "const BOLD_FLOOR :=", "const ESCAPE_GRACE_S :=",
		"var npc_reach_on_player :=", "var npc_cone_on_player_deg :=", "const SKY_GROWTH_FLOOR :="] as Array[String],
		"only the recorded tuning is left out of the fingerprint")


## The duck-typed sky IntegratedSim runs on (see IntegratedSim.eco).
class FreeingSky extends Node:
	var ground_y := -INF
	var bounds_radius := INF
	var attacks_on_player := 0
	var close_attacks_on_player := 0
	var hunt_ends_on_player := {}
	var npc_catches := 0
	var calm_energy: Array[float] = []
	var freed := 0
	var _birds: Array[SimBird] = []
	var _t := 0.0
	var _rng := RandomNumberGenerator.new()

	func seed_rng(s: int) -> void:
		_rng.seed = s

	func step(dt: float) -> void:
		var p := Birds.player()
		if p == null:
			return
		while _birds.size() < 4:
			var b := SimBird.new()
			b.mass = p.mass * 0.35
			b.species = SizeRules.species_for_mass(b.mass)
			add_child(b)
			var a := _rng.randf() * TAU
			b.global_position = p.global_position + Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(15.0, 25.0)
			_birds.append(b)
		_t += dt
		if _t < 1.5:
			return
		_t = 0.0
		var victim: SimBird = null
		var best := INF
		for b in _birds:
			var d := b.global_position.distance_to(p.global_position)
			if b.alive and d < best:
				best = d
				victim = b
		if victim != null:
			_birds.erase(victim)
			victim.free()
			freed += 1


func test_a_freed_chase_target_ends_the_chase() -> void:
	var sim := IntegratedSim.new()
	var skies: Array = []
	sim.sky_factory = func() -> Node:
		var s := FreeingSky.new()
		skies.append(s)
		return s
	add_child(sim)
	await get_tree().process_frame
	# A run whose coroutine dies on a script error never returns: wait with
	# a deadline instead of awaiting it.
	var out := [null]
	var go := func() -> void: out[0] = await sim.run(&"competent", 7, 45.0)
	go.call()
	var t0 := Time.get_ticks_msec()
	while out[0] == null and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	var r: Variant = out[0]
	check(r is Dictionary and (r as Dictionary).has("tier_at"), "the run finished and reported")
	var sky: FreeingSky = skies[-1]
	gt(float(sky.freed), 10.0, "(setup) the sky freed the bird nearest the player again and again")
	if r is Dictionary:
		gt(float(r["chases"]), 3.0, "(setup) the pilot chased")
		gt(float((r["chase_ends"] as Dictionary).get("gone", 0)), 2.5, "freed targets ended their chases")
		metric("freeing_sky", {"freed": sky.freed, "chases": r["chases"], "chase_ends": r["chase_ends"], "catches": r["catches"]})
	sim.queue_free()
	await get_tree().process_frame
