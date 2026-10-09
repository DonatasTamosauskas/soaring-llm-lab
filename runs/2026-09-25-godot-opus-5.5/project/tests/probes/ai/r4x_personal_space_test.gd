extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, experience lens): bodies that pass through each
## other or through the player's face. In a headset a bird that flies
## through your head (near-plane clipping, a bird's inside filling the view)
## or two birds merging into one another a few metres away reads as broken.
## Nothing in the area's suite measures either. In the real valley, a mock
## player lapping at sparrow, pigeon and hawk size (seeds 4501..):
##  * face passes: an NPC that is NOT after the player (target != player)
##    comes within max(0.35 m, 1.5 x (its radius + the player's radius)) of
##    the player's eye (the body position is the head). Counted once per
##    approach, by the NPC's state.
##  * overlaps: two free-flying NPCs (neither perched nor hidden, neither
##    chasing the other) whose bodies interpenetrate (centre distance <
##    sum of body radii), counted once per encounter, per bird-minute, and
##    those within 40 m of the player's eye and inside its 75-deg view cone
##    ("visible") per minute.
## Report: artifacts/ai/verify/r4/personal_space.json
##   tools/gd.sh ai_r4exp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_personal_space

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


func _case(tag: String, pm: float, seed_v: int, secs: float) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	var sp0 := _w.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * 90.0, sp0.z + sin(a) * 90.0))
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
	var face := {"count": 0, "by_state": {}, "examples": []}
	var in_face := {}
	var ov := {"count": 0, "visible": 0, "by_pair": {}, "examples": []}
	var in_ov := {}
	var free_s := 0.0
	var cone := cos(deg_to_rad(75.0))
	var pr := p.get_body_radius()
	# The bird that has just caught the player flies on through where it was
	# (follow-through of the catch itself): excluded, see r4x_accidental.
	var last_caught := [-999.0, null]
	for i in int((warm + secs) / DT):
		var t := i * DT
		air(_w, t)
		p.step(DT)
		e.step(DT)
		var nc0: int = chk.catches.size()
		chk.step(DT)
		for ci in range(nc0, chk.catches.size()):
			if chk.catches[ci]["prey"] == p:
				last_caught[0] = t
				last_caught[1] = chk.catches[ci]["predator"]
		if t < warm or i % 2 != 0:
			continue
		var eye := p.get_body_position()
		var vd := p.get_view_direction()
		var npcs := e.get_npcs()
		for n in npcs:
			if not n.alive:
				continue
			var id := n.get_instance_id()
			var lim := maxf(0.35, 1.5 * (n.get_body_radius() + pr))
			var d := n.global_position.distance_to(eye)
			var just_ate: bool = last_caught[1] == n and t - float(last_caught[0]) < 1.0
			var close := d < lim and n.target != p and n.strike != p and not just_ate
			if close and not in_face.get(id, false):
				face["count"] += 1
				var st := n.state_name() + ("/flock" if n.flock != null else "")
				face["by_state"][st] = int(face["by_state"].get(st, 0)) + 1
				if face["examples"].size() < 8:
					face["examples"].append("t=%.1f %s %s %.2f m (lim %.2f) v=%.1f" % [t, n.species, st, d, lim, n.velocity.length()])
			in_face[id] = d < lim
		if i % 4 != 0:
			continue
		var free: Array[NpcBird] = []
		for n in npcs:
			if n.alive and not (n.perched or n.hidden or n.state == NpcBird.State.HIDE):
				free.append(n)
		free_s += free.size() * 4 * DT
		for a_i in free.size():
			var a := free[a_i]
			var pa := a.global_position
			var ra := a.get_body_radius()
			for b_i in range(a_i + 1, free.size()):
				var b := free[b_i]
				var key := "%d:%d" % [a.get_instance_id(), b.get_instance_id()]
				var rr := ra + b.get_body_radius()
				var d2 := pa.distance_squared_to(b.global_position)
				var hit := d2 < rr * rr and a.target != b and b.target != a and a.strike != b and b.strike != a
				if hit and not in_ov.get(key, false):
					ov["count"] += 1
					var pk := "%s+%s" % [a.species, b.species] if String(a.species) <= String(b.species) else "%s+%s" % [b.species, a.species]
					ov["by_pair"][pk] = int(ov["by_pair"].get(pk, 0)) + 1
					var rel := pa - eye
					var vis := rel.length() < 40.0 and vd.dot(rel.normalized()) > cone
					if vis:
						ov["visible"] += 1
					if ov["examples"].size() < 8:
						ov["examples"].append("t=%.1f %s(%s) & %s(%s) %.2f m apart (radii %.2f) %.0f m from eye%s" % [t, a.species, a.state_name(), b.species, b.state_name(), sqrt(d2), rr, rel.length(), " VISIBLE" if vis else ""])
				if hit:
					in_ov[key] = true
				elif in_ov.has(key):
					in_ov.erase(key)
	var mins := secs / 60.0
	var row := {"tag": tag, "player_mass": pm, "seed": seed_v, "seconds": secs,
		"face_passes_per_min": face["count"] / mins, "face_by_state": face["by_state"], "face_examples": face["examples"],
		"overlaps_per_bird_min": ov["count"] / maxf(free_s / 60.0, 1.0), "overlaps_visible_per_min": ov["visible"] / mins,
		"overlaps": ov["count"], "overlap_pairs": ov["by_pair"], "overlap_examples": ov["examples"]}
	print("[ai-r4x] personal_space %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_r4x_personal_space() -> void:
	if _w == null:
		return
	var secs := float(Paths.arg("r4_ps_s", "180"))
	var rows := {}
	var k := 0
	for c in [["sparrow", 0.03], ["pigeon", 0.3], ["hawk", 1.3]]:
		k += 1
		rows[c[0]] = await _case(c[0], c[1], 4500 + k, secs)
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("personal_space.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	for tag in rows:
		var r: Dictionary = rows[tag]
		lt(r["face_passes_per_min"], 0.5, "%s: NPCs not after the player passing through its head, per minute %s" % [tag, r["face_examples"]])
		lt(r["overlaps_visible_per_min"], 0.5, "%s: visible NPC-NPC body interpenetrations within 40 m, per minute %s" % [tag, r["overlap_examples"]])
