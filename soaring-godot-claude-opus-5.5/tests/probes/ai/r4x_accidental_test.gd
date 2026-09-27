extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, experience lens), follow-up to
## r4x_personal_space: NPCs that are not after the player flew through its
## head (swallows landing, round a sparrow-sized player; an eagle landing,
## round a hawk-sized one). By the game's rule any contact of an eater with
## a bird it can eat is a catch, so such a pass can be a death the player
## was never warned of: nobody was hunting it. The AI claims "only a hunt
## aims at contact" (NpcBrain._avoid_bump).
## Measured in the real valley, a mock player lapping at several sizes and
## seeds, with the strict stand-in catch rule:
##  * accidental catches of the player: the eater's target was not the
##    player (and it was not striking at it) on the tick before contact;
##  * accidental NPC-vs-NPC catches, the same way;
##  * face passes as in r4x_personal_space, with what the passing bird was
##    doing: state, speed, distance to its perch, whether its brain had the
##    player as its _bump (steer-round) bird.
## Report: artifacts/ai/verify/r4/accidental.json
##   tools/gd.sh ai_r4exp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_accidental

var _w: World = null


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated


func after_all() -> void:
	if is_instance_valid(_w):
		_w.queue_free()
	_w = null
	Habitat.clear_cache()
	await wait_frames(2)


func _case(tag: String, pm: float, seed_v: int, secs: float, radius: float) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	p.protect_s = 5.0
	var sp0 := _w.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = radius
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * radius, sp0.z + sin(a) * radius))
	p.path_height = gmax + 22.0
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var warm := 20.0
	var intent := {}
	var res := {"player_catches": 0, "player_accidental": 0, "player_acc_examples": [],
		"npc_catches": 0, "npc_accidental": 0, "npc_acc_by_state": {}, "npc_acc_examples": [],
		"face": 0, "face_unprotected": 0, "follow_through": 0, "face_examples": [], "face_by_state": {}, "face_bump_seen": 0}
	var last_caught := [-999.0, null]
	var in_face := {}
	var pr := p.get_body_radius()
	var nc := 0
	for i in int((warm + secs) / DT):
		var t := i * DT
		air(_w, t)
		p.step(DT)
		e.step(DT)
		# Intent on the tick before the catch rule runs.
		intent.clear()
		for n in e.get_npcs():
			intent[n.get_instance_id()] = [n.target, n.strike, n.state_name(), n.velocity.length(), n.perch_spot.position if n.perch_spot else Vector3.INF]
		chk.step(DT)
		while nc < chk.catches.size():
			var c: Dictionary = chk.catches[nc]
			nc += 1
			if t < warm:
				continue
			var pred: Bird = c["predator"]
			var prey: Bird = c["prey"]
			if pred == p:
				continue
			var it: Array = intent.get(pred.get_instance_id(), [null, null, "?", 0.0, Vector3.INF])
			var meant: bool = it[0] == prey or it[1] == prey
			if prey == p:
				last_caught[0] = t
				last_caught[1] = pred
				res["player_catches"] += 1
				if not meant:
					res["player_accidental"] += 1
					if res["player_acc_examples"].size() < 8:
						var pd: float = (it[4] as Vector3).distance_to(c["position"]) if it[4] != Vector3.INF else -1.0
						res["player_acc_examples"].append("t=%.1f %s %s v=%.1f perch %.1f m away" % [t, pred.species, it[2], it[3], pd])
			else:
				res["npc_catches"] += 1
				if not meant:
					res["npc_accidental"] += 1
					res["npc_acc_by_state"][it[2]] = int(res["npc_acc_by_state"].get(it[2], 0)) + 1
					if res["npc_acc_examples"].size() < 8:
						res["npc_acc_examples"].append("t=%.1f %s(%s v=%.1f) ate %s" % [t, pred.species, it[2], it[3], prey.species])
		if t < warm:
			continue
		var eye := p.get_body_position()
		for n in e.get_npcs():
			if not n.alive:
				continue
			var id := n.get_instance_id()
			var lim := maxf(0.35, 1.5 * (n.get_body_radius() + pr))
			var d := n.global_position.distance_to(eye)
			# The bird that has just caught the player carries on through
			# where it was (the strike's follow-through, 0.1 s after the
			# catch): that is the catch itself, not a stray pass. In the game
			# the player is gone then (CAUGHT beat, respawn).
			var just_ate: bool = last_caught[1] == n and t - float(last_caught[0]) < 1.0
			var close := d < lim and n.target != p and n.strike != p and not just_ate
			if just_ate and d < lim and not in_face.get(id, false):
				res["follow_through"] += 1
			if close and not in_face.get(id, false):
				var prot := bool(p.get_meta(&"npc_ignore", false))
				if not prot:
					res["face_unprotected"] += 1
				res["face"] += 1
				var st := n.state_name()
				res["face_by_state"][st] = int(res["face_by_state"].get(st, 0)) + 1
				var bumped: bool = n.brain != null and n.brain._bump == p
				if bumped:
					res["face_bump_seen"] += 1
				if res["face_examples"].size() < 8:
					var pd := n.perch_spot.position.distance_to(n.global_position) if n.perch_spot else -1.0
					res["face_examples"].append("t=%.1f %s %s %.2f m v=%.1f perch %.1f m away, can eat player %s, brain bump=player %s, flaring %s, player protected %s, %.1f s after the player was last caught, this bird ate it %s" % [t, n.species, st, d, n.velocity.length(), pd, SizeRules.can_eat(n.mass, pm), bumped, n.is_flaring(), prot, t - last_caught[0], last_caught[1] == n])
			in_face[id] = d < lim
	var mins := secs / 60.0
	res["tag"] = tag
	res["player_mass"] = pm
	res["seed"] = seed_v
	res["seconds"] = secs
	res["face_per_min"] = res["face"] / mins
	res["face_unprotected_per_min"] = res["face_unprotected"] / mins
	res["player_accidental_per_min"] = res["player_accidental"] / mins
	res["npc_accidental_share"] = float(res["npc_accidental"]) / maxf(res["npc_catches"], 1)
	print("[ai-r4x] accidental %s: %s" % [tag, JSON.stringify(res)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return res


func test_r4x_accidental_contacts() -> void:
	if _w == null:
		return
	var secs := float(Paths.arg("r4_acc_s", "180"))
	var rows := {}
	var cases := [["sparrow", 0.03, 90.0], ["starling", 0.1, 90.0], ["crow", 0.5, 90.0], ["hawk", 1.3, 90.0],
		["sparrow_r150", 0.03, 150.0], ["hawk_r150", 1.3, 150.0]]
	var k := 0
	for c in cases:
		k += 1
		rows[c[0]] = await _case(c[0], c[1], 4700 + k, secs, c[2])
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("accidental.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	var tot := [0, 0, 0.0, 0, 0, 0]
	for tag in rows:
		var r: Dictionary = rows[tag]
		tot[0] += r["player_accidental"]
		tot[1] += r["face"]
		tot[2] += r["seconds"] / 60.0
		tot[3] += r["npc_accidental"]
		tot[4] += r["npc_catches"]
		tot[5] += r["face_unprotected"]
	var summary := {"player_accidental_per_min": tot[0] / tot[2], "face_per_min": tot[1] / tot[2], "face_unprotected_per_min": tot[5] / tot[2], "npc_accidental_share": float(tot[3]) / maxf(tot[4], 1), "minutes": tot[2]}
	print("[ai-r4x] accidental pooled: %s" % JSON.stringify(summary))
	lt(summary["player_accidental_per_min"], 0.05, "pooled: the player caught by a bird that was not after it, per minute")
	lt(summary["face_unprotected_per_min"], 0.25, "pooled: NPCs not after an unprotected player passing through its head, per minute")
	lt(summary["face_per_min"], 0.5, "pooled: NPCs not after the player passing through its head (protected or not: a body through the camera), per minute")
	lt(summary["npc_accidental_share"], 0.1, "pooled: share of NPC-vs-NPC catches that were not hunts")
