extends TestCase
## Verifier probes (round 2, engineering / contract lens). Not part of any
## suite (tests/probes). Self-contained: own records file, own helpers, no
## dependency on the area's fixture.
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=v3_contract
##
## 1. The whole loop WITH A PLAYER vs an independent brute-force reference
##    (documented rules re-implemented from docs/areas/GAMELOOP.md, swept
##    contact by fine time sampling, not by CatchRule.contact_time): the
##    area's own reference excludes the player and reuses CatchRule.
## 2. How often the 3-point swept narrow phase (entry / closest / exit)
##    disagrees with the exact "any time in the frame" rule.
## 3. Worst-case per-frame cost (catch + watch) with 60 birds, all modelled.
## 4. Restart hygiene the suite does not pin (danger assist, respite, catch
##    assist carried into a new run).

const DT := 1.0 / 72.0
const REC := "user://gameloop_v3_probe_records.json"
const K := 4000  # time samples per frame for the reference sweep

var loop: GameLoop
var made: Array[Node] = []


class _FakeModel extends Node3D:
	var highlight := 0


func _mk_loop() -> GameLoop:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))
	loop = GameLoop.new()
	loop.auto_step = false
	loop.records_path = REC
	loop.npc_spawn_grace_s = 0.0
	loop.verbose = false
	add_child(loop)
	made.append(loop)
	return loop


func _bird(mass: float, pos: Vector3, facing: Vector3 = Vector3.FORWARD, player: bool = false,
		with_model: bool = false) -> SimBird:
	var b := SimBird.new()
	b.player_mode = player
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	if with_model:
		var m := _FakeModel.new()
		b.model = m
		b.add_child(m)
	add_child(b)
	b.global_position = pos
	b.set_heading(facing)
	made.append(b)
	return b


func after_each() -> void:
	for n in made:
		if is_instance_valid(n):
			n.queue_free()
	made.clear()
	loop = null
	get_tree().paused = false
	await get_tree().process_frame
	if Game.state != Game.State.MENU:
		Game.set_state(Game.State.MENU)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))


# --- 1 + 2: reference with a player ---------------------------------------

## Documented rule, independent of CatchRule: returns the earliest sampled
## fraction of the frame with contact + aim (or allowed overlap), or -1.
static func _ref_time(p0i: Vector3, p1i: Vector3, p0j: Vector3, p1j: Vector3, mi: float, mj: float,
		fwd: Vector3, vdir: Vector3, i_player: bool, j_player: bool, samples: PackedFloat64Array) -> float:
	var si := SizeRules.wingspan_for_mass(mi)
	var sj := SizeRules.wingspan_for_mass(mj)
	var ri := 0.16 * si
	var rj := 0.16 * sj
	var reach := 0.0
	var cone := 0.0
	var overlap := 0.0
	if i_player:
		var ts := clampf(SizeRules.time_scale(mi), 1.0, 4.0)
		reach = si * 2.0 / ts
		cone = deg_to_rad(80.0)
		overlap = 0.6 * (ri + rj)
	elif j_player:
		reach = 0.15 * si
		cone = deg_to_rad(40.0)
		overlap = -1.0
	else:
		reach = 0.25 * si
		cone = deg_to_rad(55.0)
		overlap = 0.6 * (ri + rj)
	var contact := ri + rj + reach
	var cc := cos(cone)
	# Cheap exact reject: closest approach over the frame beyond contact.
	var d0 := p0j - p0i
	var dv := (p1j - p0j) - (p1i - p0i)
	var a := dv.length_squared()
	var tc := clampf(-d0.dot(dv) / a, 0.0, 1.0) if a > 1e-12 else 0.0
	if (d0 + dv * tc).length() > contact:
		return -1.0
	for t in samples:
		var d := (p0j.lerp(p1j, t)) - (p0i.lerp(p1i, t))
		var dist := d.length()
		if dist > contact:
			continue
		if dist <= overlap:
			return t
		var dir := d / maxf(dist, 1e-9)
		if fwd.dot(dir) >= cc:
			return t
		if i_player and vdir != Vector3.ZERO and vdir.dot(dir) >= cc:
			return t
	return -1.0


func _resolve(cands: Array, n: int) -> Array[bool]:
	cands.sort_custom(func(a: Array, b: Array) -> bool:
		for k in 7:
			if a[k] != b[k]:
				return a[k] < b[k]
		return a[7] < b[7])
	var dead: Array[bool] = []
	dead.resize(n)
	dead.fill(false)
	var ate := {}
	for c: Array in cands:
		if dead[c[7]] or dead[c[8]] or ate.has(c[7]):
			continue
		dead[c[8]] = true
		ate[c[7]] = true
	return dead


func test_loop_with_player_matches_independent_reference() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	var samples := PackedFloat64Array()
	for k in K + 1:
		samples.append(float(k) / K)
	var trials := 120
	var mism := 0
	var mism_player := 0
	var catches := 0
	var player_catches := 0
	var player_caught := 0
	var three_point_misses := 0
	var details := []
	for trial in trials:
		_mk_loop()
		var n := 30
		var pm := exp(rng.randf_range(log(0.03), log(4.5)))
		var ps := SizeRules.wingspan_for_mass(pm)
		var box := ps * 2.5
		var p0: Array[Vector3] = []
		var p1: Array[Vector3] = []
		var ms: Array[float] = []
		var hs: Array[Vector3] = []
		var bs: Array[SimBird] = []
		for i in n:
			var is_p := i == 0
			var m := pm if is_p else exp(rng.randf_range(log(pm / 6.0), log(minf(pm * 6.0, 4.5))))
			var h := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized()
			var a := Vector3(rng.randf_range(-box, box), 30.0 + rng.randf_range(-box * 0.5, box * 0.5), rng.randf_range(-box, box))
			# Half the player's predators are attacking it (aimed at it, +-50 deg).
			if not is_p and m >= pm * SizeRules.EAT_RATIO and rng.randf() < 0.5 and not p0.is_empty():
				var to_p := (p0[0] - a)
				if to_p.length_squared() > 1e-6:
					h = to_p.normalized().rotated(Vector3.UP, rng.randf_range(-0.9, 0.9))
			# Up to ~1.6x cruise, the frame's displacement at 72 Hz; some birds
			# drift off their heading (the player's flight path wobbles).
			var v := h * SizeRules.cruise_speed(m) * rng.randf_range(0.0, 1.6)
			if rng.randf() < 0.3:
				v = v.rotated(Vector3.UP, rng.randf_range(-1.2, 1.2))
			p0.append(a)
			p1.append(a + v * DT)
			ms.append(m)
			hs.append(h)
			var b := _bird(m, a, h, is_p)
			b.velocity = v
			bs.append(b)
		loop.start_run()
		# start_run respawned the player at the fallback spawn: put it back.
		bs[0].global_position = p0[0]
		bs[0].set_heading(hs[0])
		bs[0].velocity = (p1[0] - p0[0]) / DT
		bs[0].mass = pm
		# Seed start positions with everyone protected (no resolution).
		for b in bs:
			loop.set_protection(b, 100.0)
		loop.teleported(bs[0])
		loop.step(DT)
		for b in bs:
			loop.set_protection(b, 0.0)
		for i in n:
			bs[i].global_position = p1[i]
			bs[i].velocity = (p1[i] - p0[i]) / DT
		loop.step(DT)
		# Reference.
		var cands := []
		var cands3 := []
		var r := CatchRule.new()
		for i in n:
			for j in n:
				if i == j or ms[i] < ms[j] * SizeRules.EAT_RATIO:
					continue
				var v := p1[i] - p0[i]
				var vd := v.normalized() if v.length_squared() > 1e-12 else Vector3.ZERO
				var t := _ref_time(p0[i], p1[i], p0[j], p1[j], ms[i], ms[j], hs[i], vd, i == 0, j == 0, samples)
				if t >= 0.0:
					cands.append([t, -ms[i], -ms[j], p1[i].x, p1[i].z, p1[j].x, p1[j].z, i, j])
				# The loop's own narrow phase on the same geometry, for triage.
				r.player_time_scale = SizeRules.time_scale(ms[0])
				var ri := SizeRules.body_radius_for_mass(ms[i])
				var rj := SizeRules.body_radius_for_mass(ms[j])
				var c := r.contact_distance(ri, SizeRules.wingspan_for_mass(ms[i]), i == 0, rj, j == 0)
				var t3 := r.contact_time(p0[i], p1[i], p0[j], p1[j], c, (ri + rj) * r.overlap_fraction, hs[i], vd, i == 0, j == 0)
				if t3 >= 0.0:
					cands3.append([t3, -ms[i], -ms[j], p1[i].x, p1[i].z, p1[j].x, p1[j].z, i, j])
				if (t >= 0.0) != (t3 >= 0.0):
					three_point_misses += 1
					details.append({"trial": trial, "pair": [i, j], "ref_t": t, "rule_t": t3, "player": i == 0 or j == 0})
		var dead := _resolve(cands, n)
		var dead3 := _resolve(cands3, n)
		for i in n:
			var got := not bs[i].alive
			if got != dead[i]:
				mism += 1
				details.append({"trial": trial, "bird": i, "loop_dead": got, "ref_dead": dead[i], "rule3_dead": dead3[i]})
				if i == 0:
					mism_player += 1
			if dead[i]:
				catches += 1
				if i == 0:
					player_caught += 1
			if got != dead3[i]:
				details.append({"trial": trial, "bird": i, "loop_vs_rule_resolution": [got, dead3[i]]})
		for c: Array in cands:
			if int(c[7]) == 0 and dead[c[8]]:
				player_catches += 1
		await after_each()
	metric("catches_ref", catches)
	metric("player_catches_ref", player_catches)
	metric("player_caught_ref", player_caught)
	metric("outcome_mismatches", mism)
	metric("outcome_mismatches_player", mism_player)
	metric("pair_disagreements_3pt_vs_exact", three_point_misses)
	metric("details", details.slice(0, 20))
	gt(float(catches), 50.0, "(setup) plenty of catches")
	gt(float(player_catches), 5.0, "(setup) the player catches in these scenes")
	gt(float(player_caught), 3.0, "(setup) the player is caught in these scenes")
	eq(mism, 0, "loop outcome (player included) == independent reference")


# --- 3: worst-case frame cost -----------------------------------------------

func test_worst_case_frame_cost_60_modelled_birds() -> void:
	_mk_loop()
	var p := _bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.3
	loop.set_protection(p, 1e6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var bs: Array[SimBird] = []
	for i in 59:
		# Half predators closing in, half prey: all inside highlight/target range.
		var m := exp(rng.randf_range(log(0.4), log(4.5))) if i % 2 == 0 else exp(rng.randf_range(log(0.03), log(0.24)))
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized()
		var pos := Vector3(0, 30, 0) + dir * rng.randf_range(4.0, 25.0)
		var b := _bird(m, pos, -dir, false, true)
		b.velocity = -dir * 10.0
		b.set(&"target", p if i % 2 == 0 else null)
		loop.set_protection(b, 1e6)  # nobody dies: the cost stays worst-case
		bs.append(b)
	var catch_t: Array[float] = []
	var watch_t: Array[float] = []
	var total_t: Array[float] = []
	for s in 300:
		for b in bs:
			b.global_position += b.velocity * DT * 0.02  # creep, never arrive
		loop.step(DT)
		catch_t.append(float(loop.perf["catch"]))
		watch_t.append(float(loop.perf["watch"]))
		total_t.append(float(loop.perf["total"]))
	catch_t.sort()
	watch_t.sort()
	total_t.sort()
	metric("catch_us", {"median": catch_t[150], "p95": catch_t[285]})
	metric("watch_us", {"median": watch_t[150], "p95": watch_t[285]})
	metric("total_us", {"median": total_t[150], "p95": total_t[285]})
	print("[gameloop] v3 worst case: catch %.0f/%.0f watch %.0f/%.0f total %.0f/%.0f us (median/p95)" % [
		catch_t[150], catch_t[285], watch_t[150], watch_t[285], total_t[150], total_t[285]])
	lt(watch_t[150], 300.0, "watch < 0.3 ms median, worst case")


# --- 4: restart hygiene ------------------------------------------------------

func test_restart_clears_assists_and_respite() -> void:
	_mk_loop()
	var p := _bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	# Two deaths: danger assist, respite; then a long dry spell: catch assist.
	for i in 2:
		var h := _bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3))
		loop.set_protection(p, 0.0)
		loop.step(DT)
		h.alive = false
		h.global_position = Vector3(0, -900, 0)
		for k in int((GameLoop.CAUGHT_BEAT_S + 0.2) / DT):
			loop.step(DT)
	for k in 200:
		loop.step(0.5)
	gt(loop.danger_assist, 0.1, "(setup) danger assist built up")
	gt(loop.catch_assist(), 0.5, "(setup) catch assist built up")
	loop._start_respite(p)
	gt(loop.respite_left(), 1.0, "(setup) respite running")
	loop.restart_run()
	eq(loop.danger_assist, 0.0, "restart: danger assist 0")
	eq(loop.catch_assist(), 0.0, "restart: catch assist 0")
	eq(loop.respite_left(), 0.0, "restart: no respite carried over")
	eq(loop.lives, GameLoop.MAX_LIVES, "restart: lives")
	eq(loop.get_run_stats()["escapes"], 0, "restart: escapes")


## The loop's per-bird bookkeeping must not grow without bound when birds
## come and go (the AI frees and respawns NPCs all the time).
func test_bookkeeping_does_not_leak_with_churn() -> void:
	_mk_loop()
	var p := _bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for round_ in 50:
		var bs: Array[SimBird] = []
		for i in 20:
			var b := _bird(exp(rng.randf_range(log(0.03), log(3.0))), Vector3(rng.randf_range(-20, 20), 30, rng.randf_range(-20, 20)),
					Vector3.FORWARD, false, true)
			bs.append(b)
		for k in 3:
			loop.step(DT)
		for b in bs:
			made.erase(b)
			b.queue_free()
		await get_tree().process_frame
	loop.step(DT)
	lt(float(loop._tracks.size()), 5.0, "loop tracks only live birds (got %d)" % loop._tracks.size())
	lt(float(loop.watch.highlights.size()), 5.0, "watch highlights only live birds")
	lt(float(loop.watch._geom.size()), 5.0, "watch geometry cache only live birds (got %d)" % loop.watch._geom.size())


## threat_test.test_predator_identity_is_sticky places its hawks 20 m away
## closing at 2 m/s: TTC ~10 s (horizon 3.5 s) and beyond the proximity
## floor, so both raw levels are 0 and "no switches" holds trivially. Here
## both hawks are real threats (TTC ~1.3 s) trading the lead by 0.3 m.
func test_predator_identity_sticky_with_real_threats() -> void:
	_mk_loop()
	var p := _bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	var a := _bird(1.3, Vector3(-2, 30, -9), Vector3.BACK)
	var b := _bird(1.3, Vector3(2, 30, -9), Vector3.BACK)
	a.set(&"target", p)
	b.set(&"target", p)
	var raws_a: Array[float] = []
	var switches := 0
	var last: Bird = null
	var named := 0
	for i in int(3.0 / DT):
		var wob := 0.3 * (1.0 if (i / 7) % 2 == 0 else -1.0)
		a.global_position = Vector3(-2, 30, -9 + wob)
		b.global_position = Vector3(2, 30, -9 - wob)
		a.velocity = Vector3(0, 0, 6.0)
		b.velocity = Vector3(0, 0, 6.0)
		loop.step(DT)
		raws_a.append(loop.watch.threat_of(p, a, loop.rule))
		if loop.watch.predator != null:
			named += 1
		if loop.watch.predator != last:
			if last != null:
				switches += 1
			last = loop.watch.predator
	raws_a.sort()
	metric("raw_a_median", raws_a[raws_a.size() / 2])
	metric("switches", switches)
	gt(raws_a[raws_a.size() / 2], 0.3, "(setup) both hawks are real threats")
	gt(float(named), 3.0 / DT * 0.9, "(setup) a predator is named nearly all the time")
	eq(switches, 0, "near-equal real threats never steal the cue from each other")


class _ManyRefugesWorld extends World:
	var refuges: Array[Dictionary] = []

	func get_refuges() -> Array[Dictionary]:
		return refuges


## G6 cost with the real world's refuge count (SoaringWorld reports 296
## refuges, 259 of them hedgerow hollows a starling fits): the area's cost
## test runs with no World, so no refuges. CatchRule.in_refuge scans every
## refuge for every worthwhile prey inside target range, every frame.
func test_watch_cost_with_296_refuges() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 296
	var out := {}
	for with_refuges in [false, true]:
		var w := _ManyRefugesWorld.new()
		if with_refuges:
			for i in 296:
				var a := rng.randf() * TAU
				var r := sqrt(rng.randf()) * 600.0
				var span := 0.40 if i < 259 else rng.randf_range(0.2, 2.5)
				w.refuges.append({"name": "r%d" % i, "position": Vector3(cos(a) * r, 1.0, sin(a) * r),
					"radius": 0.4, "max_span": span})
		add_child(w)
		made.append(w)
		_mk_loop()
		await get_tree().process_frame  # the loop finds the world (deferred)
		var p := _bird(0.35, Vector3(0, 30, 0), Vector3.FORWARD, true)
		loop.start_run()
		p.global_position = Vector3(0, 30, 0)
		p.mass = 0.35
		loop.set_protection(p, 1e6)
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = 7
		for i in 59:
			# The ecosystem's mix around a pigeon: ~24 worthwhile prey, ~12
			# threats, the rest dust/peers, within ~60 m.
			var m := 0.0
			if i < 24:
				m = rng2.randf_range(0.04, 0.25)
			elif i < 36:
				m = rng2.randf_range(0.5, 3.0)
			else:
				m = rng2.randf_range(0.004, 0.4)
			var dir := Vector3(rng2.randf_range(-1, 1), rng2.randf_range(-0.2, 0.2), rng2.randf_range(-1, 1)).normalized()
			var b := _bird(m, Vector3(0, 30, 0) + dir * rng2.randf_range(6.0, 60.0), -dir, false, true)
			b.velocity = -dir * 3.0
			loop.set_protection(b, 1e6)
		var ws: Array[float] = []
		for s in 300:
			loop.step(DT)
			ws.append(float(loop.perf["watch"]))
		ws.sort()
		out["refuges" if with_refuges else "none"] = {"n_refuges": loop._refuges.size(), "median": ws[150], "p95": ws[285]}
		await after_each()
	metric("watch_us", out)
	print("[gameloop] v3 watch cost with/without 296 refuges: %s" % str(out))
	lt(float(out["refuges"]["median"]), 300.0, "G6: watch < 0.3 ms median with the world's refuge count")
