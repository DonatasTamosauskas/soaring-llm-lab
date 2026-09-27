extends "res://tests/unit/ai/ai_sim.gd"
## The ecosystem in the valley the game ships with - the world area's
## scenes/world/world.tscn, used only through the World contract (perches,
## refuges, landmarks, thermals, wind, ground) - not just the AI arena:
## ~300 refuges, ~1200 perches, a village, hedgerows, cliffs. What a player
## meets there, at several sizes, flying laps round the player spawn:
##  * life in sight: visible (not hidden) worthwhile prey within 80 m and
##    two within 150 m, a bird that would hunt it within 200 m;
##  * hiding is an event, not a place to live: the mean share of the
##    population hidden in cover stays small;
##  * perching happens: attempts that end on a perch, birds on perches;
##  * the population persists (no churn round a lapping player), spawns
##    stay out of view and beyond the near distance;
##  * A5 safety every tick (perched small birds on hedgerows included),
##    geometry contacts per bird-minute, AI-caused engine warnings.
##
## The suite runs three sizes for 60 s each. The evidence run,
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --suite=unit/ai/realworld --rw_full=1
## runs five sizes and a sparrow crossing the valley for 120 s each, plus a
## 10-minute soak of the valley round a pigeon-sized player (A1 there:
## catches in every 2-minute window, >= 4 predator species, every
## behaviour), and writes artifacts/ai/realworld_report.json.
## --rw_no_player=1 runs the soak with no player at all (the population
## then spreads over its whole home range in the big valley; see AI.md).

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WarningLog := preload("res://tests/unit/ai/warning_log.gd")
const Seeker := preload("res://tests/unit/ai/seeker_player.gd")
const VIEW_HALF_DEG := 75.0

var _w: World = null


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	check(ps != null, "the world scene (scenes/world/world.tscn) loads")
	if ps == null:
		return
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


func _full() -> bool:
	return Paths.arg("rw_full", "") != "" or full()


static func _prey(pm: float, n: NpcBird) -> bool:
	return SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)


## One scenario: a mock player of mass pm lapping (or crossing the valley)
## round the player spawn for warm + meas seconds.
func _scenario(tag: String, pm: float, travel: bool, seed_v: int, warm: float, meas: float) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	var sp0 := _w.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * 90.0, sp0.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	if travel:
		p.travel = true
		p.speed = 12.0
		var y := 0.0
		for k in 61:
			y = maxf(y, _w.ground_height(-300.0 + k * 10.0, sp0.z))
		p.line_a = Vector3(-300, y + 22.0, sp0.z)
		p.line_b = Vector3(300, y + 22.0, sp0.z)
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
	var m := {"n": 0, "vp80": 0, "vp150": 0, "vt200": 0, "hidden": 0.0, "perched": 0.0, "spawns": 0,
		"spawn_bad": 0, "recycled": 0, "perch_go": 0, "perch_ok": 0, "geo": 0, "free_s": 0.0, "hunts_p": 0}
	var hunting := {}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		if t[0] < warm:
			return
		m["spawns"] += 1
		var rel := n.global_position - p.get_body_position()
		if rel.length() < e.spawn_distance(n.get_wingspan()) or p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["spawn_bad"] += 1)
	e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
		if t[0] >= warm:
			m["geo"] += n.geo_hits
			if reason != &"caught":
				m["recycled"] += 1)
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(_b: NpcBird, what: StringName) -> void:
			if t[0] < warm:
				return
			if what == &"perch_go":
				m["perch_go"] += 1
			elif what == &"perch":
				m["perch_ok"] += 1))
	var c0 := 0
	var geo0 := 0
	for i in int((warm + meas) / DT):
		t[0] = i * DT
		air(_w, t[0])
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if t[0] < warm:
			continue
		if i == int(warm / DT):
			c0 = chk.catches.size()
			for n in e.get_npcs():
				geo0 += n.geo_hits
		safety.step(DT, e.get_npcs())
		for n in e.get_npcs():
			var on := n.target == p
			if on and not hunting.get(n, false):
				m["hunts_p"] += 1
			hunting[n] = on
		if i % 72 == 0:
			var pp := p.get_body_position()
			var r := {"vp80": 0, "vp150": 0, "vt": 0, "hid": 0, "per": 0}
			for n in e.get_npcs():
				var gp := n.global_position
				var hid := n.hidden or n.state == NpcBird.State.HIDE
				if hid:
					r["hid"] += 1
				if n.perched:
					r["per"] += 1
				if not (n.perched or n.hidden):
					m["free_s"] += 1.0
				if hid:
					continue
				var d3 := gp.distance_to(pp)
				var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
				if _prey(pm, n):
					if d3 < 80.0:
						r["vp80"] += 1
					if dh < 150.0:
						r["vp150"] += 1
				elif SizeRules.can_eat(n.mass, pm) and Ecosystem.would_hunt(n.species, n.mass, pm) and dh < 200.0:
					r["vt"] += 1
			var cnt := maxf(e.count(), 1)
			if OS.get_environment("AI_DEBUG") != "" and r["vp80"] == 0:
				var ds := []
				for n in e.get_npcs():
					if _prey(pm, n):
						var gp := n.global_position
						ds.append("%s %.0f/%.0f %s%s age %.0f" % [n.species, Vector2(gp.x - pp.x, gp.z - pp.z).length(), gp.distance_to(pp), n.state_name(), " H" if n.hidden else "", t[0] - float(e._born.get(n.get_instance_id(), 0.0))])
				print("[ai] t=%.0f no prey within 80 m; player y %.0f agl %.0f; prey (h/3d): %s" % [t[0], pp.y, pp.y - _w.ground_height(pp.x, pp.z), ", ".join(ds)])
			m["n"] += 1
			m["vp80"] += 1 if r["vp80"] >= 1 else 0
			m["vp150"] += 1 if r["vp150"] >= 2 else 0
			m["vt200"] += 1 if r["vt"] >= 1 else 0
			m["hidden"] += r["hid"] / cnt
			m["perched"] += r["per"] / cnt
	for n in e.get_npcs():
		m["geo"] += n.geo_hits
	m["geo"] -= geo0
	var npc_c := 0
	for j in range(c0, chk.catches.size()):
		if chk.catches[j]["prey"] != p:
			npc_c += 1
	var k: float = maxf(m["n"], 1)
	var mins := meas / 60.0
	var row := {"tag": tag, "player_mass": pm, "travel": travel, "seed": seed_v, "seconds": meas,
		"visible_prey_within_80m": snappedf(m["vp80"] / k, 0.001), "visible_prey_2_within_150m": snappedf(m["vp150"] / k, 0.001),
		"visible_threat_within_200m": snappedf(m["vt200"] / k, 0.001),
		"hidden_share": snappedf(m["hidden"] / k, 0.001), "perched_share": snappedf(m["perched"] / k, 0.001),
		"perch_attempts": m["perch_go"], "perch_landings": m["perch_ok"],
		"perch_success": snappedf(float(m["perch_ok"]) / maxf(m["perch_go"], 1), 0.001),
		"spawns_per_min": snappedf(m["spawns"] / mins, 0.1), "turnover_per_min": snappedf(m["spawns"] / mins / e.max_npcs, 0.001),
		"recycled_per_min": snappedf(m["recycled"] / mins, 0.1), "spawns_in_view_or_near": m["spawn_bad"],
		"geo_contacts_per_bird_min": snappedf(m["geo"] / maxf(m["free_s"] * 1.0 / 60.0, 1.0), 0.001),
		"hunts_on_player_per_min": snappedf(m["hunts_p"] / mins, 0.1), "npc_catches_per_min": snappedf(npc_c / mins, 0.1),
		"player_caught": p.times_caught, "safety": safety.counts.duplicate(), "safety_examples": safety.examples,
		"roles_end": e.stats()["by_role"], "states_end": e.stats()["by_state"]}
	print("[ai] realworld %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_life_round_the_player_in_the_real_valley() -> void:
	if _w == null:
		return
	var log: Logger = WarningLog.install()
	var cases := [["gull", 0.85, false]]
	var meas := 60.0
	if _full():
		cases = [["sparrow", 0.03, false], ["starling", 0.1, false], ["pigeon", 0.3, false],
			["gull", 0.85, false], ["eagle", 3.0, false], ["sparrow_travel", 0.03, true]]
		meas = 120.0
	# --rw_cases=sparrow,gull picks scenarios (from the full list) and
	# --rw_seed=N shifts their seeds, to look at one case over many seeds.
	if Paths.arg("rw_cases", "") != "":
		var only: PackedStringArray = String(Paths.arg("rw_cases", "")).split(",")
		cases = [["sparrow", 0.03, false], ["starling", 0.1, false], ["pigeon", 0.3, false],
			["gull", 0.85, false], ["eagle", 3.0, false], ["sparrow_travel", 0.03, true]].filter(
				func(c: Array) -> bool: return only.has(c[0]))
	var seed0 := 40 + int(Paths.arg("rw_seed", "0"))
	var rows := {}
	var k := 0
	for c in cases:
		k += 1
		var r: Dictionary = await _scenario(c[0], c[1], c[2], seed0 + k, 20.0, meas)
		rows[c[0]] = r
	log.uninstall()
	var hunted := [0.0, 0.0]
	var p80 := 0.0
	for tag in rows:
		var r: Dictionary = rows[tag]
		# One visible worthwhile prey within 80 m (3D): a single 120-s run of
		# it is noisy at starling size, whose prey (wrens, sparrows,
		# swallows) are what every threat round the player hunts too and
		# flee far from them. Nine starling runs, seeds 41-45 on the round-3
		# code and 41, 42, 44 on the round-2 code: 0.708-0.95, median 0.825
		# (round 2 measured 0.717 on seed 42: the old 0.75 floor, set from
		# three seeds, sat inside the spread). Pinned: a floor per size and
		# the mean over the sizes. The A6 promise itself, two worthwhile
		# prey within 150 m, holds 100%.
		gt(r["visible_prey_within_80m"], 0.65 if rows.size() > 1 else 0.75, "%s: a visible worthwhile prey within 80 m" % tag)
		p80 += float(r["visible_prey_within_80m"]) / rows.size()
		gt(r["visible_prey_2_within_150m"], 0.95, "%s: two visible worthwhile prey within 150 m" % tag)
		if r["player_mass"] < 2.0:
			gt(r["visible_threat_within_200m"], 0.9, "%s: a visible bird that would hunt it within 200 m" % tag)
			hunted[0] += float(r["hunts_on_player_per_min"]) * float(r["seconds"]) / 60.0
			hunted[1] += float(r["seconds"]) / 60.0
		lt(r["hidden_share"], 0.2, "%s: mean share of the population hidden in cover" % tag)
		gt(r["perched_share"], 0.015, "%s: mean share of the population on perches" % tag)
		if int(r["perch_attempts"]) >= 10:
			gt(r["perch_success"], 0.25, "%s: perch attempts that end on a perch (%d/%d)" % [tag, r["perch_landings"], r["perch_attempts"]])
		if not r["travel"]:
			lt(r["turnover_per_min"], 0.5, "%s: population turnover per minute round a lapping player" % tag)
		eq(r["spawns_in_view_or_near"], 0, "%s: spawns in view or within the near distance" % tag)
		# (0.3-3.4 over six sizes and many runs - the big-bird sky round an
		# eagle, crows and hawks fleeing into the village, is the worst; 9-12
		# with the obstacle feelers removed.)
		lt(r["geo_contacts_per_bird_min"], 4.0, "%s: geometry contacts per bird-minute (village streets are tight; 9-12 with no avoidance)" % tag)
		for s in r["safety"]:
			eq(r["safety"][s], 0, "%s: safety %s %s" % [tag, s, r["safety_examples"]])
	# Hunts on the player come ~0.5-3 a minute per size here: over one or two
	# minutes a single size can see none by chance, so the rate is pooled
	# over the sizes that can be hunted (per-size rates are pinned over
	# minutes of flight in ecosystem_test).
	if hunted[1] > 0.0:
		gt(hunted[0] / hunted[1], 0.5, "hunts started on the player, a minute, pooled over sizes %s" % str(rows.keys()))
	if rows.size() > 1:
		gt(p80, 0.85, "a visible worthwhile prey within 80 m, mean over the sizes %s" % str(rows.keys()))
	eq(log.warnings + log.errors, 0, "no AI-caused engine warnings or errors in the valley %s" % str(log.samples))
	metric("realworld", rows)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("realworld_report%s.json" % ("" if _full() else "_suite")), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()


## Every perch the valley offers a small bird seats its body clear of the
## geometry, by the A5 monitor's own measure, where NpcBird.land_on puts it
## (Habitat.seat: one body radius above the grip point). Hedgerow branches
## whose leafy mesh bulges over the grip are not offered to birds whose body
## would sit in the leaves.
func test_every_offered_perch_seats_the_body_clear_in_the_valley() -> void:
	if _w == null:
		return
	var h := Habitat.for_world(_w)
	var space := _w.get_world_3d().direct_space_state
	var mon: RefCounted = Safety.new(_w)
	for sp in [&"moth", &"wren", &"sparrow", &"starling", &"crow"]:
		var mass: float = SizeRules.species_data(sp)["mass"]
		var span := SizeRules.wingspan_for_mass(mass)
		var probe_bird := NpcBird.new()
		probe_bird.configure(sp, mass, 1, h)
		var r := probe_bird.get_body_radius()
		var offered := h.find_perches(Vector3.ZERO, 5000.0, span, SpeciesProfile.of(sp)["perch_kinds"])
		var bad := []
		for p in offered:
			if mon._inside(space, probe_bird, Habitat.seat(p, r)):
				bad.append(p.position.snapped(Vector3.ONE * 0.01))
		probe_bird.free()
		gt(offered.size(), 50, "(setup) %s is offered perches in the valley" % sp)
		eq(bad.size(), 0, "%s: offered perches whose seated body the A5 check would flag %s" % [sp, str(bad.slice(0, 4))])


## A5 regression (the round-3 verifier's r3x_contacts probe): a tired hawk
## that came into a pocket among three overlapping tree crowns in the
## valley's woods, 2.7 m above the ground, ground there for 160 s - its
## clearance kept pressing it up into the crown overhead and every way an
## unstick probe tried was blocked within a metre - and the Ecosystem never
## recycled it. Put back there, tired, a hawk now gets out: holding height
## under the canopy and flying out from under it, or backing out along the
## way it came (NpcBird.escape) - with and without a trail to back out on.
func test_a_tired_hawk_in_a_crown_pocket_gets_out() -> void:
	if _w == null:
		return
	var pocket := Vector3(-325.6, 7.5, -274.9)
	var h := Habitat.for_world(_w)
	check(not h.ray(pocket, pocket + Vector3.UP * 3.0).is_empty(), "(setup) a crown overhead at the pocket")
	# The way in: the most open level direction round the pocket.
	var best := Vector3.ZERO
	var best_free := -1.0
	for k in 24:
		var d := Vector3(cos(TAU * k / 24.0), 0.0, sin(TAU * k / 24.0))
		var hit := h.ray(pocket, pocket + d * 15.0)
		var free := 15.0 if hit.is_empty() else pocket.distance_to(hit["position"])
		if free > best_free:
			best_free = free
			best = d
	var table := {}
	for with_trail in [true, false]:
		var hawk := spawn(&"hawk", pocket, -best * 3.0, _w)
		hawk.can_hunt = false
		hawk.can_flee = false
		hawk.energy = 0.15
		if with_trail:
			for k in 10:
				hawk._trail.append(pocket + best * minf(best_free - 1.0, 9.0) * (1.0 - k / 10.0))
		var safety: RefCounted = Safety.new(_w)
		var m := {"out_t": -1.0}
		run(40.0, func(i: int) -> bool:
			air(_w, i * DT)
			safety.step(DT, [hawk])
			if m["out_t"] < 0.0 and hawk.global_position.distance_to(pocket) > 10.0:
				m["out_t"] = i * DT
			return false)
		var tag := "with_trail" if with_trail else "no_trail"
		table[tag] = {"out_s": snappedf(m["out_t"], 0.01), "geo_hits": hawk.geo_hits, "escapes": hawk.escapes,
			"safety": safety.counts.duplicate()}
		between(m["out_t"], 0.0, 15.0, "%s: out of the pocket, 10 m clear (s) %s" % [tag, table[tag]])
		for k in safety.counts:
			eq(safety.counts[k], 0, "%s: safety %s %s" % [tag, k, safety.examples])
		despawn(hawk)
	metric("crown_pocket", table)


## A1 in the valley, round a player as in the game (A1 proper - no player -
## is soak_test in the AI arena): a 10-minute soak in the evidence run, two
## minutes in the suite. The player is a pigeon-sized mock flying laps; it
## does not evade, and a catch of it only starts its 5-s protection.
func test_soak_in_the_real_valley() -> void:
	if _w == null:
		return
	# (240 s in the suite since integration round 1: in 90 s one seed's sky
	# made 3 catches by a single species once the Ecosystem's show moved a
	# few birds - noise, not a change: the 10-minute soak made 42 catches by
	# 8 species with the show and 42 by 7 without, and 240 s gives two whole
	# 2-minute windows.)
	var soak_s := float(Paths.arg("rw_soak_s", "600" if _full() else "240"))
	var p: MockPlayer = null
	if Paths.arg("rw_no_player", "") == "":
		p = MockPlayer.new()
		p.mass = 0.3
		var sp0 := _w.get_player_spawn().origin
		p.path_center = Vector3(sp0.x, 0, sp0.z)
		p.path_radius = 90.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * 90.0, sp0.z + sin(a) * 90.0))
		p.path_height = gmax + 22.0
		p.speed = minf(SizeRules.cruise_speed(p.mass), 14.0)
		add_child(p)
		p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 7
	add_child(e)
	if p != null:
		e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(_w)
	var dives_f := [0, 0]
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what == &"refuge" and b.threat != null and is_instance_valid(b.threat):
				dives_f[0] += 1
				if b.threat.get_wingspan() <= float(b.refuge.get("max_span", 0.0)):
					dives_f[1] += 1))
	var n_win := int(ceil(soak_s / 120.0))
	var windows := []
	for i in n_win:
		windows.append(0)
	var pop := {"min": 999, "max": 0}
	# A 2-minute timeline (behaviour counts and how the birds are doing), so
	# a sky that runs down over the soak shows where.
	var timeline := []
	var last_beh := {}
	var win_steps := int(round(120.0 / DT))
	for i in int(soak_s / DT):
		air(_w, i * DT)
		if p != null:
			p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if i > 72:
			pop["min"] = mini(pop["min"], e.count())
			pop["max"] = maxi(pop["max"], e.count())
		if (i + 1) % win_steps == 0:
			var bh: Dictionary = e.stats()["behaviour"]
			var row := {}
			for what in ["hunt", "flee", "refuge", "perch", "give_up_timeout", "give_up_home", "unstick"]:
				row[what] = int(bh.get(what, 0)) - int(last_beh.get(what, 0))
			last_beh = bh.duplicate()
			var states := {}
			var hungry := 0
			var en := 0.0
			for n in e.get_npcs():
				states[n.state_name()] = states.get(n.state_name(), 0) + 1
				hungry += 1 if n.hunger > 0.5 else 0
				en += n.energy
			row["states"] = states
			row["hungry"] = hungry
			row["energy_mean"] = snappedf(en / maxf(e.count(), 1), 0.01)
			timeline.append(row)
			if OS.get_environment("AI_DEBUG") != "":
				var hs := {}
				var npcs := e.get_npcs()
				for n in npcs:
					if float(n.profile["hunt"]) <= 0.0:
						continue
					var a: Array = hs.get(String(n.species), [0, 0, 0, 0, 0.0])
					a[0] += 1
					a[1] += 1 if n.brain._age < n.brain._hunt_rest_until else 0
					a[2] += 1 if n.digest > 0.0 else 0
					var best := INF
					for o in npcs:
						if o != n and not o.hidden and SizeRules.can_eat(n.mass, o.mass) and SizeRules.is_worthwhile(n.mass, o.mass):
							best = minf(best, o.global_position.distance_to(n.global_position))
					a[3] += 1 if best < float(n.profile["hunt_range_m"]) else 0
					a[4] += minf(best, 999.0)
					hs[String(n.species)] = a
				for k2 in hs:
					hs[k2][4] = int(hs[k2][4] / hs[k2][0])
				var spread := 0.0
				var c := Vector3.ZERO
				for n in npcs:
					c += n.global_position
				c /= maxf(npcs.size(), 1)
				for n in npcs:
					spread += Vector2(n.global_position.x - c.x, n.global_position.z - c.z).length()
				var fh := {}
				for n in npcs:
					var kk := n.state_name() + ("/fl" if n.flock != null else "")
					var a2: Array = fh.get(kk, [0, 0.0])
					a2[0] += 1
					a2[1] += Vector2(n.global_position.x - n.home.x, n.global_position.z - n.home.z).length() / maxf(n.home_radius, 1.0)
					fh[kk] = a2
				for k3 in fh:
					fh[k3] = [fh[k3][0], snappedf(fh[k3][1] / fh[k3][0], 0.1)]
				var hc := Vector3.ZERO
				for n in npcs:
					hc += n.home
				print("[ai] valley t=%d from home (home radii) by state %s; homes centre %s, home_radius %.0f" % [int((i + 1) * DT), fh, (hc / maxf(npcs.size(), 1)).snapped(Vector3.ONE), npcs[0].home_radius])
				print("[ai] valley t=%d hunters [n, resting, digesting, prey in range, mean nearest prey m] %s; spread %.0f m round %s" % [int((i + 1) * DT), hs, spread / maxf(npcs.size(), 1), c.snapped(Vector3.ONE)])
	# NPC-vs-NPC catches only (the mock player is fair game but not A1).
	var by_pred := {}
	var npc_catches := 0
	for c in chk.catches:
		if c["prey"] == p:
			continue
		npc_catches += 1
		windows[mini(int(float(c["t"]) / 120.0), n_win - 1)] += 1
		by_pred[String(c["pred_species"])] = by_pred.get(String(c["pred_species"]), 0) + 1
	var st := e.stats()
	var beh: Dictionary = st["behaviour"]
	var flock_share := float(st["flock_time"]) / (soak_s * 60.0)
	for w in windows.size():
		gt(windows[w], 0, "valley: catches in 2-minute window %d" % w)
	gt(by_pred.size(), 3 if soak_s >= 600.0 else 1, "valley: predator species that caught something")
	for what in ["perch", "thermal", "hunt", "flee", "stoop", "refuge", "jink"]:
		gt(beh.get(what, 0), 0, "valley: %s counted" % what)
	if p != null:
		# Round a player the valley's cover is used. Since round 3 only cover
		# too small for the pursuer counts (the brief) and only cover in
		# sight: ~8 dives every two minutes round this pigeon-sized player
		# (was 20-45 when any cover the bird fitted would do, rooms and lofts
		# its pursuer could enter included). Floor: 3 every two minutes.
		gt(beh.get("refuge", 0), 3.0 * soak_s / 120.0, "valley: dives into refuges")
	eq(dives_f[1], 0, "valley: dives into cover the pursuer could follow into (of %d from a known pursuer)" % dives_f[0])
	gt(flock_share, 0.1, "valley: share of bird-time flocking")
	lt(pop["max"], e.max_npcs + 1, "valley: never above the cap")
	gt(pop["min"], e.max_npcs - e.tolerance - 1, "valley: never below target - tolerance")
	for s in safety.counts:
		eq(safety.counts[s], 0, "valley soak: safety %s %s" % [s, safety.examples])
	var report := {"sim_s": soak_s, "player": "none" if p == null else "pigeon-sized, laps", "catches": npc_catches,
		"player_caught": 0 if p == null else p.times_caught, "catch_windows_2min": windows, "catches_by_predator": by_pred,
		"behaviour": beh, "flock_share": flock_share, "population": pop, "safety": safety.counts, "despawned": st["despawned"],
		"timeline_2min": timeline}
	print("[ai] valley soak: %s" % JSON.stringify(report))
	metric("valley_soak", report)
	# Named by length like soak_test's outputs: a suite run never overwrites
	# the 10-minute evidence (realworld_soak_report.json).
	var name := "realworld_soak%s%s_report.json" % ["_no_player" if p == null else "", "" if soak_s >= 600.0 else "_%ds" % int(soak_s)]
	var f := FileAccess.open(Paths.artifacts("ai").path_join(name), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	e.queue_free()
	if p != null:
		remove_child(p)
		p.queue_free()
	await wait_frames(2)


## A player who HUNTS (tests/unit/ai/seeker_player.gd: the NPCs' own flight
## physics at its mass, searching low where its prey lives, chasing the
## nearest worthwhile prey the game would highlight; its body collides)
## meets birds that fly like skilled flyers where it looks:
##  * visible hard hits - a bird striking a wall, roof or tree at >= 3 m/s
##    into the surface, inside the player's 100 x 90 deg view and at least
##    0.5 deg across (~10 px on a Quest Pro) - fewer than one a minute
##    (the round-3 verifier's r3x_bonk measure: 1-21 a minute before, with
##    fleeing prey crashing into the village walls in front of the player);
##  * prey dive only into cover too small for the bird they flee (the
##    brief: "refuges too small for the pursuer") - pooled over every dive
##    from a known threat, none into cover it could follow into;
##  * prey the player comes within awareness of flee it, a worthwhile prey
##    is in highlight range, spawns stay out of view, A5 safety 0.
## Suite: a starling-sized hunter (the size whose prey use cover most), 90 s.
## Evidence (--rw_full=1 or --ai_full=1): sparrow, starling, pigeon and crow
## sizes, 180 s, two seed sets.
func _seeker_case(tag: String, pm: float, seed_v: int, warm: float, meas: float) -> Dictionary:
	var s := Seeker.new()
	add_child(s)
	s.setup(_w, pm, _w.get_player_spawn().origin)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = s
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var safety: RefCounted = Safety.new(_w)
	var tt := [0.0]
	var m := {"visible_hard": 0, "hard60": 0, "contacts": 0, "bird_s": 0.0, "dives": 0, "dives_known": 0,
		"dives_followable": 0, "spawns": 0, "spawn_bad": 0, "samples": 0, "in_range": 0, "examples": [],
		"followable_pairs": {}, "visible_by_state": {}, "visible_where": [], "visible_head_on": 0, "visible_graze": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		if tt[0] >= warm:
			m["spawns"] += 1
			var rel := n.global_position - s.get_body_position()
			if rel.length() < e.spawn_distance(n.get_wingspan()) or s.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
				m["spawn_bad"] += 1
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what != &"refuge" or tt[0] < warm:
				return
			m["dives"] += 1
			var th: Bird = b.threat
			if th == null or not is_instance_valid(th):
				return
			m["dives_known"] += 1
			if th.get_wingspan() <= float(b.refuge.get("max_span", 0.0)):
				m["dives_followable"] += 1
				var k := "%s>%s" % [th.species, b.species]
				m["followable_pairs"][k] = m["followable_pairs"].get(k, 0) + 1))
	var prev_hits := {}
	var prev_vel := {}
	var cos_h := cos(deg_to_rad(50.0))
	for i in int((warm + meas) / DT):
		var t := i * DT
		tt[0] = t
		air(_w, t)
		s.active = t >= warm
		s.step(DT, e.get_npcs())
		e.step(DT)
		chk.step(DT)
		if t < warm:
			for n in e.get_npcs():
				prev_hits[n.get_instance_id()] = n.geo_hits
				prev_vel[n.get_instance_id()] = n.velocity
			continue
		safety.step(DT, e.get_npcs())
		m["bird_s"] += DT * e.count()
		var eye := s.get_body_position()
		var f: Vector3 = s.get_view_direction()
		f = Vector3(f.x, 0.0, f.z).normalized()
		var right := f.cross(Vector3.UP).normalized()
		for n in e.get_npcs():
			var id := n.get_instance_id()
			if prev_hits.has(id) and n.geo_hits > int(prev_hits[id]):
				m["contacts"] += 1
				var nrm: Vector3 = n.last_hit_normal
				var vin := maxf(-(prev_vel.get(id, n.velocity) as Vector3).dot(nrm), 0.0)
				if vin >= 3.0:
					var rel := n.global_position - eye
					var d := rel.length()
					if d < 60.0:
						m["hard60"] += 1
					var fz := rel.dot(f)
					if fz > 0.0 and atan2(absf(rel.dot(right)), fz) < deg_to_rad(50.0) and atan2(absf(rel.y), fz) < deg_to_rad(45.0) \
							and rad_to_deg(n.get_wingspan() / maxf(d, 0.1)) >= 0.5:
						m["visible_hard"] += 1
						# Head-on (>= 30 deg into the surface) or a graze along it.
						var v0l := maxf((prev_vel.get(id, n.velocity) as Vector3).length(), 0.1)
						m["visible_head_on" if vin >= 0.5 * v0l else "visible_graze"] += 1
						m["visible_by_state"][n.state_name()] = m["visible_by_state"].get(n.state_name(), 0) + 1
						if m["visible_where"].size() < 40:
							m["visible_where"].append("%s %s %.1f %s" % [n.species, n.state_name(), vin, str(n.last_hit.snapped(Vector3.ONE))])
						if m["examples"].size() < 6:
							m["examples"].append("%s %s %.1f m/s at %.0f m, %s" % [n.species, n.state_name(), vin, d, str(n.last_hit.snapped(Vector3.ONE * 0.1))])
			prev_hits[id] = n.geo_hits
			prev_vel[id] = n.velocity
		if i % 36 == 0:
			m["samples"] += 1
			for n in e.get_npcs():
				if s.eligible(n) and n.global_position.distance_to(eye) <= s.sense_r:
					m["in_range"] += 1
					break
	var fled := 0
	var aware := 0
	var reasons := {}
	for pu in s.pursuits:
		reasons[pu["reason"]] = reasons.get(pu["reason"], 0) + 1
		if pu["in_awareness"]:
			aware += 1
			fled += 1 if pu["fled"] else 0
	var mins := meas / 60.0
	var row := {"tag": tag, "player_mass": pm, "seed": seed_v, "seconds": meas,
		"visible_hard_per_min": snappedf(m["visible_hard"] / mins, 0.01), "hard_within_60m_per_min": snappedf(m["hard60"] / mins, 0.01),
		"visible_head_on_per_min": snappedf(m["visible_head_on"] / mins, 0.01), "visible_graze_per_min": snappedf(m["visible_graze"] / mins, 0.01),
		"contacts_per_bird_min": snappedf(m["contacts"] / maxf(m["bird_s"] / 60.0, 1e-3), 0.001),
		"refuge_dives": m["dives"], "dives_from_known_threat": m["dives_known"], "dives_threat_could_follow": m["dives_followable"],
		"followable_pairs": m["followable_pairs"],
		"chased_prey_that_fled": [fled, aware], "chase_ends": reasons, "player_catches": s.catches.size(),
		"player_caught": s.times_caught, "worthwhile_prey_in_highlight_range": snappedf(float(m["in_range"]) / maxf(m["samples"], 1), 0.001),
		"spawns": m["spawns"], "spawns_in_view_or_near": m["spawn_bad"], "player_wall_hits": s.wall_hits,
		"safety": safety.counts.duplicate(), "safety_examples": safety.examples, "examples": m["examples"],
		"visible_hard_by_state": m["visible_by_state"], "visible_hard_where": m["visible_where"]}
	print("[ai] pursuit %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	remove_child(s)
	s.queue_free()
	await wait_frames(2)
	return row


func test_a_hunting_player_meets_skilled_flyers() -> void:
	if _w == null:
		return
	var log: Logger = WarningLog.install()
	var cases := [["starling_hunting", 0.1, 872]]
	var meas := 90.0
	if _full():
		cases = [["sparrow_hunting", 0.03, 871], ["starling_hunting", 0.1, 872], ["pigeon_hunting", 0.3, 873], ["crow_hunting", 0.5, 874],
			["sparrow_hunting_b", 0.03, 921], ["starling_hunting_b", 0.1, 922], ["pigeon_hunting_b", 0.3, 923], ["crow_hunting_b", 0.5, 924]]
		meas = 180.0
	if Paths.arg("rw_hunt_cases", "") != "":
		var only: PackedStringArray = String(Paths.arg("rw_hunt_cases", "")).split(",")
		cases = cases.filter(func(c: Array) -> bool: return only.has(c[0]))
	var rows := {}
	var dives := [0, 0]
	var hits := [0.0, 0.0]
	var fled := [0, 0]
	for c in cases:
		var r: Dictionary = await _seeker_case(c[0], c[1], c[2] + int(Paths.arg("rw_seed", "0")), 20.0, meas)
		rows[c[0]] = r
		dives[0] += int(r["dives_from_known_threat"])
		dives[1] += int(r["dives_threat_could_follow"])
		hits[0] += float(r["visible_hard_per_min"]) * meas / 60.0
		hits[1] += meas / 60.0
		fled[0] += int(r["chased_prey_that_fled"][0])
		fled[1] += int(r["chased_prey_that_fled"][1])
	log.uninstall()
	for tag in rows:
		var r: Dictionary = rows[tag]
		# Per case (3 minutes in the evidence run): a count of a few, so only
		# a case that is plainly bad fails - 3 a minute, three times the
		# pooled bound below (Poisson: under a true 1 a minute a 3-minute
		# case reaches 9 hits one time in 900).
		lt(r["visible_hard_per_min"], 3.0, "%s: birds hitting walls or trees hard in the player's view, a minute %s" % [tag, r["examples"]])
		gt(r["worthwhile_prey_in_highlight_range"], 0.9, "%s: a worthwhile prey inside the game's highlight range" % tag)
		var cf: Array = r["chased_prey_that_fled"]
		if int(cf[1]) >= 5:
			gt(float(cf[0]) / float(cf[1]), 0.6, "%s: chased prey the player came within awareness of fled it (%d/%d)" % [tag, cf[0], cf[1]])
		eq(r["spawns_in_view_or_near"], 0, "%s: spawns in view or near" % tag)
		for k in r["safety"]:
			eq(r["safety"][k], 0, "%s: safety %s %s" % [tag, k, r["safety_examples"]])
	# Pooled over every case and minute: the rate a player sees. The evidence
	# run (24 minutes) is held to the round-3 verifier's bar, under one hard
	# hit a minute in view. The suite's single 90-s case cannot measure a
	# rate that low (a count of 0-3): it fails only when the count is
	# improbable under that bar (Poisson, p < 0.03: 5 or more in 90 s).
	if _full():
		lt(hits[0] / maxf(hits[1], 1e-3), 1.0, "birds hitting walls or trees hard in the player's view, a minute, pooled over %.0f minutes" % hits[1])
	else:
		lt(hits[0], 5.0, "birds hitting walls or trees hard in the player's view in %.1f minutes (improbable at 1 a minute from 5)" % hits[1])
	if fled[1] >= 5:
		gt(float(fled[0]) / float(fled[1]), 0.85, "chased prey the player came within awareness of fled it, pooled (%d/%d)" % [fled[0], fled[1]])
	gt(dives[0], 5 if _full() else 1, "(setup) refuge dives from a known pursuer happened")
	lt(float(dives[1]) / maxf(dives[0], 1), 0.05, "refuge dives into cover the pursuer could follow into (brief: too small for the pursuer)")
	eq(log.warnings + log.errors, 0, "no AI-caused engine warnings or errors %s" % str(log.samples))
	metric("pursuit", rows)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("pursuit_report%s.json" % ("" if _full() else "_suite")), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
