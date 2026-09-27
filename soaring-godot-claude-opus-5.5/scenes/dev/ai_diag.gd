extends Node3D
## Dev measurement harness (not a suite test): runs the ecosystem around a
## mock player in the AI test world or the world area's real valley and
## prints what a player would meet, as one JSON line per scenario:
##  * what is in its forward view (the verifier's "noticeable" rule: >= 0.3
##    deg across, or highlighted by GameLoop - worthwhile prey or a bird that
##    can eat it - within its highlight range; 50 x 45 deg half-angles);
##  * visible (not hidden) worthwhile prey within 60/80 m, birds within 100 m;
##  * hidden / perched / fleeing shares, perch attempts and landings;
##  * spawns per minute, despawn reasons, life of recycled birds;
##  * hunts started on the player, NPC catches, A5 safety.
##
##   tools/gd.sh ai --headless res://scenes/dev/ai_diag.tscn -- \
##       --world=test|real --mass=0.03,0.3,3.0 --mode=lap|travel \
##       --seed=61 --warm=25 --meas=90 [--radius=90] [--out=name]

const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const EcoScene := preload("res://scenes/ai/ecosystem.tscn")
const DT := 1.0 / 72.0


func _ready() -> void:
	if Paths.arg("sprints", "") != "":
		for sd in SizeRules.SPECIES:
			var sp: StringName = sd["id"]
			var f := NpcFlight.new(float(sd["mass"]), float(SpeciesProfile.of(sp)["glide_ratio"]))
			print("[ai-diag] %-8s mass %.3f cruise %.2f sprint %.2f max %.2f v_md %.2f p_max %.1f endurance %.2f" % [sp, float(sd["mass"]), f.cruise, f.sprint, f.max_speed, f.v_md, f.p_max, pow(float(sd["mass"]) / 0.03, 0.25)])
		get_tree().quit()
		return
	if Paths.arg("avoid", "") != "":
		await _avoid_trace()
		get_tree().quit()
		return
	if Paths.arg("soak", "") != "":
		await _soak_refuges()
		get_tree().quit()
		return
	var real := Paths.arg("world", "test") == "real"
	var w: World
	if real:
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	else:
		var tw := AiTestWorld.new()
		tw.with_visuals = false
		tw.with_environment = false
		w = tw
	add_child(w)
	for i in 3:
		await get_tree().physics_frame
	var rows := []
	var seed0 := int(Paths.arg("seed", "61"))
	var k := 0
	for ms in String(Paths.arg("mass", "0.03,0.3,3.0")).split(","):
		for mode in String(Paths.arg("mode", "lap")).split(","):
			rows.append(await _scenario(w, float(ms), mode, seed0 + k))
			k += 1
	var out := String(Paths.arg("out", ""))
	if out != "":
		DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("diag"))
		var f := FileAccess.open(Paths.artifacts("ai").path_join("diag/%s.json" % out), FileAccess.WRITE)
		f.store_string(JSON.stringify(rows, "  "))
		f.close()
	get_tree().quit()


static func _hl_range(pm: float) -> float:
	return maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))


func _scenario(w: World, pm: float, mode: String, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	var c := Vector3(-20, 0, 10) if w is AiTestWorld else w.get_player_spawn().origin
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = float(Paths.arg("radius", "90"))
	var gmax := 0.0
	for j in 36:
		var a := TAU * j / 36.0
		gmax = maxf(gmax, w.ground_height(c.x + cos(a) * p.path_radius, c.z + sin(a) * p.path_radius))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	if mode == "travel":
		p.travel = true
		p.speed = 12.0
		var y := 0.0
		for j in 61:
			y = maxf(y, w.ground_height(-300.0 + j * 10.0, c.z))
		p.line_a = Vector3(-300, y + 22.0, c.z)
		p.line_b = Vector3(300, y + 22.0, c.z)
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(w)
	var warm := float(Paths.arg("warm", "25"))
	var meas := float(Paths.arg("meas", "90"))
	var t := [0.0]
	var born := {}
	var sp := {"spawns": 0, "despawns": {}, "life": []}
	var hunt_end := {}
	var perch_end := {}
	var hist := {}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		born[n.get_instance_id()] = t[0]
		n.state_changed.connect(func(bb: NpcBird, old: int, ns: int) -> void:
			var hh: Array = hist.get(bb.get_instance_id(), [])
			hh.append("%.1f:%s" % [t[0], NpcBird.STATE_NAMES[ns]])
			hist[bb.get_instance_id()] = hh.slice(-6)
			if t[0] < warm:
				return
			if (old == NpcBird.State.HUNT or old == NpcBird.State.STOOP) and ns != NpcBird.State.HUNT and ns != NpcBird.State.STOOP:
				var why: String = bb.brain.give_up_reason
				if why == "" and bb.digest > 0.0:
					why = "caught"
				hunt_end[why] = hunt_end.get(why, 0) + 1
			if old == NpcBird.State.PERCH:
				var w2 := "landed" if ns == NpcBird.State.PERCHED else ("fled:" + (("player" if bb.threat.is_player() else String(bb.threat.species)) if bb.threat != null else "?") if ns == NpcBird.State.FLEE else NpcBird.STATE_NAMES[ns])
				perch_end[w2] = perch_end.get(w2, 0) + 1)
		if t[0] >= warm:
			sp["spawns"] += 1)
	e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
		if t[0] < warm or reason == &"caught":
			return
		sp["despawns"][String(reason)] = sp["despawns"].get(String(reason), 0) + 1
		sp["life"].append(t[0] - float(born.get(n.get_instance_id(), 0.0))))
	var roles_near := {}
	var m := {"n": 0, "zero": 0, "vis": 0, "prey_ahead": 0, "no_prey_ahead": 0, "vp60": 0, "vp80": 0,
		"n100": 0, "hidden": 0.0, "perched": 0.0, "flee": 0.0, "prey_d": []}
	var h0 := 0
	var beh0 := {}
	var c0 := 0
	var hr := _hl_range(pm)
	var last_geo := {}
	var geo_by := {}
	for i in int((warm + meas) / DT):
		t[0] = i * DT
		if w.has_method(&"set_air_time"):
			w.call(&"set_air_time", t[0])
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if t[0] >= warm:
			safety.step(DT, e.get_npcs())
			for n in e.get_npcs():
				var gid := n.get_instance_id()
				if last_geo.has(gid) and n.geo_hits > last_geo[gid]:
					var ray2 := PhysicsRayQueryParameters3D.create(n.last_hit + n.last_hit_normal * 0.2, n.last_hit - n.last_hit_normal * 0.2, 1)
					var hh: Dictionary = w.get_world_3d().direct_space_state.intersect_ray(ray2)
					var col := String(hh["collider"].name).left(12) if not hh.is_empty() else "?"
					var refi := "-"
					if not n.refuge.is_empty():
						var en: Dictionary = n.refuge.get("entry", {})
						refi = "ref(door %.0fm side %.1f)" % [n.global_position.distance_to(en["through"]), (n.global_position - en["through"]).dot(en["out"])] if not en.is_empty() else "ref(no entry)"
					var k := "%s/%s%s/%s/%s" % [n.species, n.state_name(), "/flare" if n.is_flaring() else "", col, refi if Paths.arg("refi", "") != "" else ("ref" if refi != "-" else "-")]
					geo_by[k] = geo_by.get(k, 0) + n.geo_hits - last_geo[gid]
					if Paths.arg("contacts", "") != "" and geo_by.size() < 400:
						print("[ai-diag] contact t=%.1f #%d %s %s at %s n %s v %s agl %.1f obs_d %.1f slots %.0f near %s want %s roofed %s exit %s last_ref %s hist %s" % [t[0], n.get_instance_id() % 10000, n.species, n.state_name(), n.last_hit.snapped(Vector3.ONE * 0.1), n.last_hit_normal.snapped(Vector3.ONE * 0.01), n.velocity.snapped(Vector3.ONE * 0.1), n.agl(), n.brain.obs_plane_d(), float(n.brain._ob_p.size()), n.near_geometry, n.want_dir.snapped(Vector3.ONE * 0.01), e.habitat.indoors(n.global_position), not e.habitat.exit_near(n.global_position, 20.0).is_empty(), n.brain._last_refuge.get("position", "-"), hist.get(n.get_instance_id(), [])])
				last_geo[gid] = n.geo_hits
		if i == int(warm / DT):
			h0 = e.stats()["hunts_on_player"]
			beh0 = e.stats()["behaviour"].duplicate()
			c0 = chk.catches.size()
		if Paths.arg("trace", "") != "" and t[0] > warm and i % 360 == 0:
			var eye0 := p.get_body_position()
			var agg := {}
			for n0 in e.get_npcs():
				var role0 := String(e._role_of(e._npc_key.get(n0.get_instance_id(), &"")))
				var k0 := "%s/%s" % [role0, n0.state_name()]
				var a0: Array = agg.get(k0, [0, 0.0, 0.0, 0.0])
				a0[0] += 1
				a0[1] += n0.global_position.distance_to(eye0)
				a0[2] += Vector2(n0.global_position.x - n0.home.x, n0.global_position.z - n0.home.z).length() / maxf(n0.home_radius, 1.0)
				a0[3] += t[0] - float(born.get(n0.get_instance_id(), 0.0))
				agg[k0] = a0
			var line := "t=%.0f sky %.0f area_r %.0f focus->p %.0f |" % [t[0], e._sky, e._area_r, Vector2(e.focus_point().x - eye0.x, e.focus_point().z - eye0.z).length()]
			var ks := agg.keys()
			ks.sort()
			for k0 in ks:
				var a1: Array = agg[k0]
				line += " %s:%d d%.0f h%.1f age%.0f" % [k0, a1[0], a1[1] / a1[0], a1[2] / a1[0], a1[3] / a1[0]]
			print("[ai-diag] ", line)
		if t[0] > warm and i % 36 == 0:
			var eye := p.get_body_position()
			var fwd: Vector3 = p.get_view_direction()
			fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
			var right := fwd.cross(Vector3.UP).normalized()
			var vis := 0
			var prey_ahead := 0
			var vp60 := false
			var vp80 := false
			var n100 := 0
			var hid := 0
			var per := 0
			var fl := 0
			var nearest_prey := INF
			for n in e.get_npcs():
				var rel := n.global_position - eye
				var d := rel.length()
				var hidden := n.hidden or n.state == NpcBird.State.HIDE
				if hidden:
					hid += 1
				if n.perched:
					per += 1
				if n.state == NpcBird.State.FLEE:
					fl += 1
				if d < 100.0:
					n100 += 1
				var prey := SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)
				if prey and not hidden:
					nearest_prey = minf(nearest_prey, d)
					if d < 60.0:
						vp60 = true
					if d < 80.0:
						vp80 = true
				var role := "prey" if prey else ("dust" if SizeRules.can_eat(pm, n.mass) else ("threat" if SizeRules.can_eat(n.mass, pm) and Ecosystem.would_hunt(n.species, n.mass, pm) else ("giant" if SizeRules.can_eat(n.mass, pm) else "peer")))
				var rn: Dictionary = roles_near.get(role, {"r50": 0, "r100": 0, "cone50": 0, "cone_elev_fail": 0, "dh_sum": 0.0, "cnt": 0, "dy_sum": 0.0})
				var dh := Vector2(rel.x, rel.z).length()
				rn["cnt"] += 1
				rn["dh_sum"] += dh
				rn["dy_sum"] += rel.y
				if d < hr:
					rn["r50"] += 1
				if d < 100.0:
					rn["r100"] += 1
				var fz0 := rel.dot(fwd)
				if fz0 > 0.0 and d < hr and rad_to_deg(atan2(absf(rel.dot(right)), fz0)) <= 50.0:
					if rad_to_deg(atan2(absf(rel.y), fz0)) > 45.0:
						rn["cone_elev_fail"] += 1
					else:
						rn["cone50"] += 1
				roles_near[role] = rn
				if hidden or d < 0.5:
					continue
				var hl := prey or SizeRules.can_eat(n.mass, pm)
				if rad_to_deg(n.get_wingspan() / d) < 0.3 and not (hl and d < hr):
					continue
				var fz := rel.dot(fwd)
				if fz <= 0.0:
					continue
				if rad_to_deg(atan2(absf(rel.dot(right)), fz)) > 50.0 or rad_to_deg(atan2(absf(rel.y), fz)) > 45.0:
					continue
				vis += 1
				if prey:
					prey_ahead += 1
			var cnt := maxf(e.count(), 1)
			m["n"] += 1
			m["vis"] += vis
			m["zero"] += 1 if vis == 0 else 0
			m["prey_ahead"] += prey_ahead
			m["no_prey_ahead"] += 1 if prey_ahead == 0 else 0
			m["vp60"] += 1 if vp60 else 0
			m["vp80"] += 1 if vp80 else 0
			m["n100"] += n100
			m["hidden"] += hid / cnt
			m["perched"] += per / cnt
			m["flee"] += fl / cnt
			m["prey_d"].append(nearest_prey)
	if Paths.arg("dump", "") != "":
		var eye2 := p.get_body_position()
		print("[ai-diag] focus %s player %s travelling %s drift %s" % [e.focus_point().snapped(Vector3.ONE), eye2.snapped(Vector3.ONE), e.travelling(), e.drift().snapped(Vector3.ONE * 0.1)])
		for nb in e.get_npcs():
			print("[ai-diag]   %-8s %-7s role %-8s d %6.1f home->p %6.1f d->home %6.1f hr %5.1f goal_free %s y %5.1f e %.2f h %.2f" % [nb.species, nb.state_name(), e._role_of(e._npc_key.get(nb.get_instance_id(), &"")), nb.global_position.distance_to(eye2), Vector2(nb.home.x - eye2.x, nb.home.z - eye2.z).length(), Vector2(nb.home.x - nb.global_position.x, nb.home.z - nb.global_position.z).length(), nb.home_radius, nb.brain._goal_free, nb.global_position.y, nb.energy, nb.hunger])
	var st := e.stats()
	var beh: Dictionary = st["behaviour"]
	var n: float = maxf(m["n"], 1)
	var life: Array = sp["life"]
	life.sort()
	var pd: Array = m["prey_d"]
	pd.sort()
	var npc_c := 0
	for j in range(c0, chk.catches.size()):
		if chk.catches[j]["prey"] != p:
			npc_c += 1
	var pg: int = beh.get("perch_go", 0) - beh0.get("perch_go", 0)
	var pl: int = beh.get("perch", 0) - beh0.get("perch", 0)
	var row := {"world": "real" if not (w is AiTestWorld) else "test", "mass": pm, "mode": mode, "seed": seed_v,
		"nothing_ahead": snappedf(m["zero"] / n, 0.01), "mean_vis_ahead": snappedf(m["vis"] / n, 0.01),
		"no_prey_ahead": snappedf(m["no_prey_ahead"] / n, 0.01), "mean_prey_ahead": snappedf(m["prey_ahead"] / n, 0.01),
		"vis_prey60": snappedf(m["vp60"] / n, 0.01), "vis_prey80": snappedf(m["vp80"] / n, 0.01),
		"nearest_prey_median_m": snappedf(pd[pd.size() / 2], 0.1) if not pd.is_empty() else -1.0,
		"n100": snappedf(m["n100"] / n, 0.1), "hidden": snappedf(m["hidden"] / n, 0.001), "perched": snappedf(m["perched"] / n, 0.001),
		"flee": snappedf(m["flee"] / n, 0.001), "perch_ok": "%d/%d" % [pl, pg],
		"spawns_per_min": snappedf(sp["spawns"] / (meas / 60.0), 0.1), "despawns": sp["despawns"],
		"recycled_life_median": snappedf(life[life.size() / 2], 0.1) if not life.is_empty() else -1.0,
		"hunts_on_player_pm": snappedf((st["hunts_on_player"] - h0) / (meas / 60.0), 0.1),
		"npc_catches_pm": snappedf(npc_c / (meas / 60.0), 0.1), "player_caught": p.times_caught,
		"safety": safety.counts, "safety_examples": safety.examples, "roles_near": _norm(roles_near, n), "hunt_end": hunt_end, "perch_end": perch_end, "geo_by": geo_by, "geo_total": geo_by.values().reduce(func(a, x): return a + x, 0), "states": st["by_state"], "roles": st["by_role"]}
	print("[ai-diag] ", JSON.stringify(row))
	e.queue_free()
	remove_child(p)
	p.queue_free()
	for j in 2:
		await get_tree().physics_frame
	return row


static func _norm(rn: Dictionary, n: float) -> Dictionary:
	var out := {}
	for k in rn:
		var r: Dictionary = rn[k]
		out[k] = {"in_reach": snappedf(r["r50"] / n, 0.01), "in_100m": snappedf(r["r100"] / n, 0.01),
			"cone_reach": snappedf(r["cone50"] / n, 0.01), "cone_too_steep": snappedf(r["cone_elev_fail"] / n, 0.01),
			"mean_dh": snappedf(r["dh_sum"] / maxf(r["cnt"], 1), 0.1), "mean_dy": snappedf(r["dy_sum"] / maxf(r["cnt"], 1), 0.1)}
	return out


## Refuge use in a no-player soak: fleeing birds, with a refuge chosen, how
## near they got to it, dives.
func _soak_refuges() -> void:
	var tw: World
	if Paths.arg("world", "test") == "real":
		tw = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	else:
		var aw := AiTestWorld.new()
		aw.with_visuals = false
		aw.with_environment = false
		tw = aw
	add_child(tw)
	for i in 3:
		await get_tree().physics_frame
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = int(Paths.arg("seed", "7"))
	add_child(e)
	var last_geo := {}
	var last_gr := {}
	var gr_by := {}
	var gr_where := []
	var geo_by := {}
	var geo_where := []
	var fleeing := {}
	var with_ref := {}
	var best := {}
	var fits := {}
	for i in int(float(Paths.arg("soak_s", "120")) / DT):
		e.step(DT)
		for n in e.get_npcs():
			var gid := n.get_instance_id()
			if last_geo.has(gid) and n.geo_hits > last_geo[gid]:
				var col := ""
				var hitq := PhysicsPointQueryParameters3D.new()
				var sp2 := tw.get_world_3d().direct_space_state
				var ray2 := PhysicsRayQueryParameters3D.create(n.last_hit + n.last_hit_normal * 0.2, n.last_hit - n.last_hit_normal * 0.2, 1)
				var hh: Dictionary = sp2.intersect_ray(ray2)
				if not hh.is_empty():
					col = String(hh["collider"].name).left(14)
				var k := "%s/%s/%s" % [n.species, n.state_name(), col]
				geo_by[k] = geo_by.get(k, 0) + n.geo_hits - last_geo[gid]
				if geo_where.size() < 60:
					geo_where.append("%s %s %s at %s n %s" % [n.species, n.state_name(), col, n.last_hit.snapped(Vector3.ONE * 0.1), n.last_hit_normal.snapped(Vector3.ONE * 0.01)])
			last_geo[gid] = n.geo_hits
			if last_gr.has(gid) and n.ground_hits > last_gr[gid]:
				var kg := "%s/%s%s%s" % [n.species, n.state_name(), "/flare" if n.is_flaring() else "", "/perched" if n.perched != null else ""]
				gr_by[kg] = gr_by.get(kg, 0) + n.ground_hits - last_gr[gid]
				if gr_where.size() < 40:
					gr_where.append("t=%.1f %s %s v=%s spd=%.1f gamma=%.2f eff=%.2f want=%s" % [i * DT, n.species, kg, n.velocity.snapped(Vector3.ONE * 0.1), n.flight.speed, n.flight.gamma, n.flight.effort, n.want_dir.snapped(Vector3.ONE * 0.01)])
			last_gr[gid] = n.ground_hits
			if n.state == NpcBird.State.FLEE:
				var id := n.get_instance_id()
				fleeing[id] = n.species
				var ok := 0
				for r in e.habitat.refuges:
					if n.get_wingspan() <= float(r.get("max_span", 0.0)):
						ok += 1
				fits[id] = ok
				if not n.refuge.is_empty():
					with_ref[id] = true
					var dd: float = n.global_position.distance_to(n.refuge["position"])
					best[id] = minf(best.get(id, INF), dd)
	var by_sp := {}
	for id in fleeing:
		var k := String(fleeing[id])
		var a: Array = by_sp.get(k, [0, 0, 0, INF])
		a[0] += 1
		a[1] += 1 if with_ref.has(id) else 0
		a[2] = maxi(a[2], fits[id])
		a[3] = minf(a[3], best.get(id, INF))
		by_sp[k] = a
	print("[ai-diag] ground contacts by situation %s" % gr_by)
	for l in gr_where:
		print("[ai-diag]   ", l)
	print("[ai-diag] geometry contacts by situation %s" % geo_by)
	for l in geo_where:
		print("[ai-diag]   ", l)
	print("[ai-diag] refuges in habitat %d; fleeing birds by species [n, with refuge, refuges that fit, closest m]: %s; behaviour %s" % [e.habitat.refuges.size(), by_sp, e.stats()["behaviour"]])


## Trace one bird flown at the cliff face with its goal behind it.
func _avoid_trace() -> void:
	var tw := AiTestWorld.new()
	tw.with_visuals = false
	tw.with_environment = false
	add_child(tw)
	for i in 3:
		await get_tree().physics_frame
	var sp := StringName(Paths.arg("sp", "gull"))
	var x := float(Paths.arg("x", "-60"))
	var start := Vector3(x, tw.ground_height(x, 270.0) + 18.0, 270.0)
	var goal := Vector3(x, start.y, 400.0)
	if Paths.arg("tree", "") != "":
		var t: Array = tw.trees[int(Paths.arg("tree", "0"))]
		var base: Vector3 = t[0]
		var y := base.y + minf(float(t[1]) * 0.3, 2.2)
		start = Vector3(base.x - 30.0, y, base.z)
		goal = Vector3(base.x + 40.0, y, base.z)
		print("[ai-diag] tree base %s h %.1f ground %.2f" % [base, t[1], tw.ground_height(base.x, base.z)])
	var b := NpcBird.new()
	b.managed = true
	b.configure(sp, -1.0, 5, Habitat.for_world(tw))
	add_child(b)
	b.global_position = start
	b.flight.set_velocity((goal - start).normalized() * b.flight.cruise)
	b.can_hunt = false
	b.can_flee = false
	b.energy = 1.0
	b.home = Vector3(goal.x, 0, goal.z)
	b.home_radius = 400.0
	b.brain._perch_cool = 999.0
	b.brain._soar_cool = 999.0
	b.brain._goal = goal
	b.brain._goal_t = 0.0
	b.brain._goal_life = 999.0
	b.brain._goal_free = true
	for i in int(float(Paths.arg("secs", "10")) / DT):
		b.tick(DT)
		if i % int(Paths.arg("every", "7")) == 0:
			var p := b.global_position
			print("[ai-diag] t=%.2f p=%s agl=%.2f v=%s obs_d=%.1f slots=%.0f obs_n=%s want=%s geo=%d gr=%d near=%s" % [i * DT, p.snapped(Vector3.ONE * 0.01), p.y - tw.ground_height(p.x, p.z), b.velocity.snapped(Vector3.ONE * 0.1), b.brain.obs_plane_d(), float(b.brain._ob_p.size()), str(b.brain._ob_n), b.want_dir.snapped(Vector3.ONE * 0.01), b.geo_hits, b.ground_hits, b.near_geometry])
