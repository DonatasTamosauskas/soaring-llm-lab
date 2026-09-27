extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, experience & requirements lens). Situations the
## area's own suite does not fly, in the valley the game ships with
## (scenes/world/world.tscn), through the World contract only:
##
##  1. respawn_and_restart - what GameLoop actually does to the player:
##     * caught: a hawk-sized player that has been lapping over the lake is
##       put back at the player spawn 30% lighter (CAUGHT_MASS_LOSS), sits
##       there 5 s protected (RESPAWN_PROTECT_S), then flies laps;
##     * restart: an eagle-sized player lapping over the forest is reset to
##       a sparrow at the spawn and the Ecosystem is reset (start_run order).
##     After the event: how soon visible worthwhile prey is within 80 m /
##     two within 150 m, a would-be hunter within 200 m, how many birds are
##     noticeable in the forward view, population band, spawns/despawns in
##     view, A5 safety.
##  2. head_spin - a VR player looks around all the time (gaze sweeping
##     +-120 deg about its heading at up to 90 deg/s) while lapping as a
##     sparrow: spawns never in the view cone or near, despawns never in
##     view, the population stays in band, the prey promise holds.
##  3. long_life - a sparrow-sized player (the size every run starts at)
##     lapping over the village for --r4_long_s (default 600) on a fresh
##     seed: A1 in the valley round the start size (NPC-vs-NPC catches in
##     every 2-minute window, >= 4 predator species, each behaviour), A5
##     safety every tick plus a stricter "grinding" check (a free bird that
##     keeps hitting geometry while making < 6 m of progress in 15 s), and
##     geometry contacts per bird-minute.
## Report: artifacts/ai/verify/r4/valley_life.json
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_valley_life

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const VIEW_HALF_DEG := 75.0

var _w: World = null
var _out := {}


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated


func after_all() -> void:
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("valley_life%s.json" % Paths.arg("r4_tag", "")), FileAccess.WRITE)
	f.store_string(JSON.stringify(_out, "  "))
	f.close()
	if is_instance_valid(_w):
		_w.queue_free()
	_w = null
	Habitat.clear_cache()
	await wait_frames(2)


static func _prey(pm: float, n: NpcBird) -> bool:
	return SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)


static func _threat(pm: float, n: NpcBird) -> bool:
	return SizeRules.can_eat(n.mass, pm) and Ecosystem.would_hunt(n.species, n.mass, pm)


func _lap_height(c: Vector3, r: float) -> float:
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(c.x + cos(a) * r, c.z + sin(a) * r))
	return gmax + 22.0


func _place_laps(p: MockPlayer, c: Vector3) -> void:
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = 90.0
	p.path_height = _lap_height(c, 90.0)


## Noticeable birds ahead (r2x_forward_view's measure): not hidden, inside a
## 50 x 45 deg half-angle frustum round the gaze, >= 0.3 deg across or
## highlighted by GameLoop within its highlight range.
func _ahead(e: Ecosystem, p: MockPlayer) -> int:
	var eye := p.get_body_position()
	var f: Vector3 = p.get_view_direction()
	f = Vector3(f.x, 0.0, f.z).normalized()
	var right: Vector3 = f.cross(Vector3.UP).normalized()
	var pm := p.mass
	var hl_r := maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))
	var n_all := 0
	for n in e.get_npcs():
		if n.hidden or n.state == NpcBird.State.HIDE:
			continue
		var rel := n.global_position - eye
		var d := rel.length()
		if d < 0.5:
			continue
		var hl := _prey(pm, n) or SizeRules.can_eat(n.mass, pm)
		if rad_to_deg(n.get_wingspan() / d) < 0.3 and not (hl and d < hl_r):
			continue
		var fz := rel.dot(f)
		if fz <= 0.0:
			continue
		if rad_to_deg(atan2(absf(rel.dot(right)), fz)) > 50.0 or rad_to_deg(atan2(absf(rel.y), fz)) > 45.0:
			continue
		n_all += 1
	return n_all


## Common harness: returns a dictionary of counters the callers fill.
func _watch(e: Ecosystem, p: MockPlayer, t: Array, m: Dictionary) -> void:
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		m["spawns"] += 1
		var rel := n.global_position - p.get_body_position()
		if rel.length() < e.spawn_distance(n.get_wingspan()):
			m["spawn_near"] += 1
			if m["examples"].size() < 6:
				m["examples"].append("t=%.1f spawn near %s %.1f m" % [t[0], n.species, rel.length()])
		elif p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["spawn_view"] += 1
			if m["examples"].size() < 6:
				m["examples"].append("t=%.1f spawn in view %s %.1f m" % [t[0], n.species, rel.length()]))
	e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
		m["despawns"][String(reason)] = int(m["despawns"].get(String(reason), 0)) + 1
		if reason == &"caught" or reason == &"reset":
			return
		var rel := n.global_position - p.get_body_position()
		if rel.length() < 250.0 and p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["despawn_view"] += 1
			if m["examples"].size() < 6:
				m["examples"].append("t=%.1f despawn in view %s %s %.1f m" % [t[0], reason, n.species, rel.length()]))


func _new_counters() -> Dictionary:
	return {"spawns": 0, "spawn_near": 0, "spawn_view": 0, "despawn_view": 0, "despawns": {}, "examples": []}


# ------------------------------------------------------------------ 1

func _event_case(tag: String, pm0: float, pm1: float, from_c: Vector3, restart: bool, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm0
	p.speed = minf(SizeRules.cruise_speed(pm0), 14.0)
	p.protect_s = 5.0
	_place_laps(p, from_c)
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(_w)
	var t := [0.0]
	var m := _new_counters()
	_watch(e, p, t, m)
	var warm := 60.0
	var post := 60.0
	var sp0 := _w.get_player_spawn().origin
	var first := {"prey80": -1.0, "prey2_150": -1.0, "threat200": -1.0, "ahead1": -1.0}
	var share := {"n": 0, "prey80": 0, "prey2_150": 0, "threat200": 0, "ahead0": 0, "ahead_sum": 0}
	var pop_min := 999
	var hunts_on_player := 0
	var hunting := {}
	var i := 0
	var ev_i := int(warm / DT)
	var sit_i := int((warm + 5.0) / DT)
	while i < int((warm + post) / DT):
		t[0] = i * DT
		if i == ev_i:
			# GameLoop: mass penalty (or START_MASS), _place_player at the
			# spawn, protection; start_run also resets the ecosystem.
			p.mass = pm1
			p.speed = minf(SizeRules.cruise_speed(pm1), 14.0)
			p.moving = false
			var sxf := _w.get_player_spawn()
			p.global_transform = sxf
			p.velocity = Vector3.ZERO
			var fw := -sxf.basis.z
			p.view_dir = Vector3(fw.x, 0.0, fw.z).normalized() if Vector2(fw.x, fw.z).length() > 0.1 else Vector3.FORWARD
			p._protect_left = 5.0
			p.set_meta(&"npc_ignore", true)
			# The teleport is not a flight path (GameLoop.teleported).
			chk._prev[p.get_instance_id()] = p.get_body_position()
			if restart:
				e.reset()
		if i == sit_i:
			# Takes off and flies laps round the spawn.
			# The lap passes through the spawn (angle 0 is centre + (r, 0)),
			# so taking off is not a second jump.
			_place_laps(p, sp0 + Vector3(-90.0, 0.0, 0.0))
			p.angle = 0.0
			p.moving = true
			p.step(0.0)
			chk._prev[p.get_instance_id()] = p.get_body_position()
		air(_w, t[0])
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if i >= ev_i:
			var ts: float = t[0] - warm
			for n in e.get_npcs():
				var on := n.target == p
				if on and not hunting.get(n, false):
					hunts_on_player += 1
				hunting[n] = on
			if i % 36 == 0:
				var pp := p.get_body_position()
				var c80 := 0
				var c150 := 0
				var th := 0
				for n in e.get_npcs():
					if n.hidden or n.state == NpcBird.State.HIDE:
						continue
					var gp := n.global_position
					var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
					if _prey(p.mass, n):
						if gp.distance_to(pp) < 80.0:
							c80 += 1
						if dh < 150.0:
							c150 += 1
					elif _threat(p.mass, n) and dh < 200.0:
						th += 1
				var ah := _ahead(e, p)
				if c80 >= 1 and first["prey80"] < 0.0:
					first["prey80"] = ts
				if c150 >= 2 and first["prey2_150"] < 0.0:
					first["prey2_150"] = ts
				if th >= 1 and first["threat200"] < 0.0:
					first["threat200"] = ts
				if ah >= 1 and first["ahead1"] < 0.0:
					first["ahead1"] = ts
				if ts >= 10.0:
					share["n"] += 1
					share["prey80"] += 1 if c80 >= 1 else 0
					share["prey2_150"] += 1 if c150 >= 2 else 0
					share["threat200"] += 1 if th >= 1 else 0
					share["ahead0"] += 1 if ah == 0 else 0
					share["ahead_sum"] += ah
				if ts >= 5.0:
					pop_min = mini(pop_min, e.count())
		i += 1
	var k := maxf(share["n"], 1)
	var row := {"tag": tag, "from_mass": pm0, "to_mass": pm1, "restart": restart, "seed": seed_v,
		"first_s": first, "after_10s_share": {"prey80": share["prey80"] / k, "prey2_150": share["prey2_150"] / k,
			"threat200": share["threat200"] / k, "nothing_ahead": share["ahead0"] / k, "mean_ahead": share["ahead_sum"] / k},
		"pop_min_after_5s": pop_min, "hunts_on_player_after": hunts_on_player,
		"spawns": m["spawns"], "spawn_near": m["spawn_near"], "spawn_view": m["spawn_view"], "despawn_view": m["despawn_view"],
		"despawns": m["despawns"], "examples": m["examples"], "safety": safety.counts.duplicate(), "safety_examples": safety.examples,
		"roles_end": e.stats()["by_role"]}
	print("[ai-r4x] %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_r4x_respawn_and_restart() -> void:
	if _w == null:
		return
	var lake := Vector3(228, 0, 228)
	var forest := Vector3(-262, 0, -258)
	var rows := {}
	rows["caught_hawk"] = await _event_case("caught_hawk", 1.3, 1.3 * 0.7, lake, false, 4101)
	rows["caught_crow"] = await _event_case("caught_crow", 0.5, 0.5 * 0.7, lake, false, 4102)
	rows["restart_eagle"] = await _event_case("restart_eagle", 3.0, 0.03, forest, true, 4103)
	_out["respawn_and_restart"] = rows
	for tag in rows:
		var r: Dictionary = rows[tag]
		var f: Dictionary = r["first_s"]
		var s: Dictionary = r["after_10s_share"]
		# The Ecosystem's own promise (fix round 3): prey within 75 m in
		# 3-4 s, two within 120 m in 3-6.5 s after a respawn jump.
		between(f["prey80"], 0.0, 10.0, "%s: a visible worthwhile prey within 80 m soon after the event (s)" % tag)
		between(f["prey2_150"], 0.0, 10.0, "%s: two visible worthwhile prey within 150 m soon after (s)" % tag)
		between(f["threat200"], 0.0, 15.0, "%s: a would-be hunter within 200 m soon after (s)" % tag)
		gt(s["prey2_150"], 0.9, "%s: two visible prey within 150 m, share of the next 50 s" % tag)
		gt(s["threat200"], 0.8, "%s: a would-be hunter within 200 m, share of the next 50 s" % tag)
		gt(r["pop_min_after_5s"], 55, "%s: population in band after the event" % tag)
		eq(r["spawn_near"] + r["spawn_view"], 0, "%s: spawns in view or near %s" % [tag, r["examples"]])
		eq(r["despawn_view"], 0, "%s: non-catch despawns in view %s" % [tag, r["examples"]])
		for k in r["safety"]:
			eq(r["safety"][k], 0, "%s: safety %s %s" % [tag, k, r["safety_examples"]])


# ------------------------------------------------------------------ 2

func test_r4x_head_spin() -> void:
	if _w == null:
		return
	var p := MockPlayer.new()
	p.mass = 0.03
	p.speed = minf(SizeRules.cruise_speed(0.03), 14.0)
	var sp0 := _w.get_player_spawn().origin
	_place_laps(p, sp0)
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 4201
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(_w)
	var t := [0.0]
	var m := _new_counters()
	_watch(e, p, t, m)
	var total := 150.0
	var pop_min := 999
	var s := {"n": 0, "prey2_150": 0, "prey80": 0, "ahead0": 0}
	# Pop-ins: a bird that spawned less than 1.5 s ago coming into the view
	# cone within 120 m (spawned out of the cone, but the head turned).
	var born := {}
	var popins := [0, 0]
	e.npc_spawned.connect(func(n: NpcBird) -> void: born[n.get_instance_id()] = t[0])
	for i in int(total / DT):
		t[0] = i * DT
		# Gaze sweeps +-120 deg about the heading: a sine of period 5.3 s,
		# peak angular speed ~ 2.1 rad/s (VR players look over a shoulder).
		p.gaze_turn = deg_to_rad(120.0) * sin(t[0] * TAU / 5.3)
		air(_w, t[0])
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if t[0] < 20.0:
			continue
		pop_min = mini(pop_min, e.count())
		if i % 9 == 0:
			var eye := p.get_body_position()
			var vd := p.get_view_direction()
			for n in e.get_npcs():
				var id := n.get_instance_id()
				if not born.has(id):
					continue
				var age: float = t[0] - float(born[id])
				if age > 1.5:
					born.erase(id)
					continue
				var rel := n.global_position - eye
				if rel.length() < 120.0 and vd.dot(rel.normalized()) > cos(deg_to_rad(50.0)):
					popins[0] += 1
					if rad_to_deg(n.get_wingspan() / rel.length()) >= 0.3:
						popins[1] += 1
					born.erase(id)
		if i % 36 == 0:
			var pp := p.get_body_position()
			var c80 := 0
			var c150 := 0
			for n in e.get_npcs():
				if n.hidden or n.state == NpcBird.State.HIDE or not _prey(p.mass, n):
					continue
				var gp := n.global_position
				if gp.distance_to(pp) < 80.0:
					c80 += 1
				if Vector2(gp.x - pp.x, gp.z - pp.z).length() < 150.0:
					c150 += 1
			s["n"] += 1
			s["prey80"] += 1 if c80 >= 1 else 0
			s["prey2_150"] += 1 if c150 >= 2 else 0
			s["ahead0"] += 1 if _ahead(e, p) == 0 else 0
	var k := maxf(s["n"], 1)
	var row := {"pop_min": pop_min, "spawns": m["spawns"], "spawn_near": m["spawn_near"], "spawn_view": m["spawn_view"],
		"despawn_view": m["despawn_view"], "despawns": m["despawns"], "examples": m["examples"],
		"popins_within_120m_in_1_5s": popins[0], "popins_noticeable": popins[1],
		"prey80_share": s["prey80"] / k, "prey2_150_share": s["prey2_150"] / k, "nothing_ahead_share": s["ahead0"] / k,
		"safety": safety.counts.duplicate()}
	print("[ai-r4x] head_spin: %s" % JSON.stringify(row))
	_out["head_spin"] = row
	eq(row["spawn_near"] + row["spawn_view"], 0, "head spin: spawns in the gaze cone or near %s" % [row["examples"]])
	eq(row["despawn_view"], 0, "head spin: non-catch despawns in the gaze cone %s" % [row["examples"]])
	gt(pop_min, 55, "head spin: population in band (a sweeping gaze must not starve spawning)")
	gt(row["prey2_150_share"], 0.9, "head spin: two visible worthwhile prey within 150 m")
	for kk in row["safety"]:
		eq(row["safety"][kk], 0, "head spin: safety %s" % kk)
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)


# ------------------------------------------------------------------ 3

func test_r4x_long_life_round_a_sparrow() -> void:
	if _w == null:
		return
	var total := float(Paths.arg("r4_long_s", "600"))
	var p := MockPlayer.new()
	p.mass = 0.03
	p.speed = minf(SizeRules.cruise_speed(0.03), 14.0)
	var sp0 := _w.get_player_spawn().origin
	_place_laps(p, sp0)
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = int(Paths.arg("r4_seed", "4301"))
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(_w)
	var t := [0.0]
	var m := _new_counters()
	_watch(e, p, t, m)
	var beh := {}
	var hist := {}
	var grind := {"count": 0, "examples": [], "by": {}}
	var geo := {"hits": 0, "free_s": 0.0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(_b: NpcBird, what: StringName) -> void:
			beh[String(what)] = int(beh.get(String(what), 0)) + 1))
	e.npc_despawned.connect(func(n: NpcBird, _r: StringName) -> void:
		geo["hits"] += n.geo_hits
		hist.erase(n.get_instance_id()))
	var pop := [999, 0]
	for i in int(total / DT):
		t[0] = i * DT
		air(_w, t[0])
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if i > 72:
			pop[0] = mini(pop[0], e.count())
			pop[1] = maxi(pop[1], e.count())
		if i % 18 == 0:
			for n in e.get_npcs():
				var free := not (n.perched or n.hidden or n.is_flaring() or n.state == NpcBird.State.HIDE)
				if free:
					geo["free_s"] += 18 * DT
				var id := n.get_instance_id()
				var h: Array = hist.get(id, [])
				h.append([t[0], n.global_position, free, n.geo_hits + n.bumps])
				while not h.is_empty() and t[0] - float(h[0][0]) > 15.01:
					h.pop_front()
				hist[id] = h
				if h.size() >= 58 and t[0] - float(h[0][0]) > 14.7:
					var ok := true
					var far := 0.0
					for q in h:
						if not q[2]:
							ok = false
							break
						far = maxf(far, (q[1] as Vector3).distance_to(h[0][1]))
					if ok and far < 6.0 and int(h[-1][3]) > int(h[0][3]):
						grind["count"] += 1
						var key := "%s/%s" % [n.species, n.state_name()]
						grind["by"][key] = int(grind["by"].get(key, 0)) + 1
						if grind["examples"].size() < 6:
							grind["examples"].append("t=%.0f %s %s at %s hits+%d in 15 s, %.1f m" % [t[0], n.species, n.state_name(), n.global_position.snapped(Vector3.ONE * 0.1), int(h[-1][3]) - int(h[0][3]), far])
						h.clear()
	for n in e.get_npcs():
		geo["hits"] += n.geo_hits
	var n_win := int(ceil(total / 120.0))
	var windows := []
	for w in n_win:
		windows.append(0)
	var npc_catches := 0
	var by_pred := {}
	for c in chk.catches:
		if c["prey"] == p or c["predator"] == p:
			continue
		npc_catches += 1
		windows[mini(int(c["t"] / 120.0), n_win - 1)] += 1
		by_pred[String(c["pred_species"])] = int(by_pred.get(String(c["pred_species"]), 0)) + 1
	var row := {"seconds": total, "seed": e.rng_seed, "npc_catches": npc_catches, "windows_2min": windows, "by_predator": by_pred,
		"behaviour": beh, "population": pop, "grinding": grind,
		"geo_contacts_per_bird_min": geo["hits"] / maxf(geo["free_s"] / 60.0, 1.0),
		"spawn_near": m["spawn_near"], "spawn_view": m["spawn_view"], "despawn_view": m["despawn_view"], "despawns": m["despawns"],
		"examples": m["examples"], "safety": safety.counts.duplicate(), "safety_examples": safety.examples,
		"safety_by_situation": safety.by_situation, "player_caught": p.times_caught}
	print("[ai-r4x] long_life: %s" % JSON.stringify(row))
	_out["long_life"] = row
	for w in windows.size():
		gt(windows[w], 0, "long life: NPC-vs-NPC catches in 2-minute window %d" % w)
	gt(by_pred.size(), 3, "long life: predator species that caught (>= 4) %s" % str(by_pred))
	for b in ["hunt", "flee", "perch", "thermal", "stoop", "jink"]:
		gt(beh.get(b, 0), 0, "long life: behaviour '%s' seen" % b)
	eq(grind["count"], 0, "long life: free birds grinding against geometry (< 6 m progress in 15 s with contacts) %s" % str(grind["examples"]))
	lt(row["geo_contacts_per_bird_min"], 1.0, "long life: geometry contacts per bird-minute of free flight")
	gt(pop[0], 55, "long life: population never below band")
	eq(m["spawn_near"] + m["spawn_view"] + m["despawn_view"], 0, "long life: spawns/despawns in view %s" % str(m["examples"]))
	for kk in safety.counts:
		eq(safety.counts[kk], 0, "long life: safety %s %s" % [kk, safety.examples])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
