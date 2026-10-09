extends TestCase
## Verifier probes (round 3, engineering / contract lens). Not part of any
## suite (tests/probes). Self-contained: own records file, own helpers; uses
## only the core contracts and the area's own SimBird stand-in.
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=r3_eng
##
## 1. Victory and a strike on the player in the same frame: the run must end
##    as a victory, the later strike must not kill the player after the run
##    ended (GameLoop._commit_catch's phase guard; mutant X01 survives the
##    area suite).
## 2. NPC spawn grace (npc_spawn_grace_s, 1 s by default): the area's fixture
##    sets it to 0, so the suite never exercises it.
## 3. The penalty floor: a sparrow caught never drops below START_MASS.
## 4. Whole-loop determinism: the same random crowd, created in two different
##    registration orders, gives the same catches in the same frames.
## 5. The evidence fingerprint (IntegratedSim.code_hash) strips indentation,
##    which is semantic in GDScript: a behavioural edit that only moves a line
##    in or out of a block is invisible to it.

const DT := 1.0 / 72.0
const Y := 40.0
const REC := "user://gameloop_r3_probe_records.json"

var loop: GameLoop
var made: Array[Node] = []
var caught_log: Array = []
var player_caught_n := 0


func _mk_loop(grace: float = 0.0) -> GameLoop:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))
	loop = GameLoop.new()
	loop.auto_step = false
	loop.records_path = REC
	loop.npc_spawn_grace_s = grace
	loop.verbose = false
	add_child(loop)
	made.append(loop)
	return loop


func _bird(mass: float, pos: Vector3, facing: Vector3 = Vector3.FORWARD, player: bool = false, tag: String = "") -> SimBird:
	var b := SimBird.new()
	b.player_mode = player
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	b.name = tag if not tag.is_empty() else ("P" if player else "B%d" % made.size())
	add_child(b)
	b.global_position = pos
	b.set_heading(facing)
	made.append(b)
	return b


func _on_caught(pred: Bird, prey: Bird) -> void:
	caught_log.append([pred, prey])


func _on_player_caught(_pred: Bird) -> void:
	player_caught_n += 1


func before_each() -> void:
	caught_log.clear()
	player_caught_n = 0
	Events.bird_caught.connect(_on_caught)
	Events.player_caught.connect(_on_player_caught)


func after_each() -> void:
	if Events.bird_caught.is_connected(_on_caught):
		Events.bird_caught.disconnect(_on_caught)
	if Events.player_caught.is_connected(_on_player_caught):
		Events.player_caught.disconnect(_on_player_caught)
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


func test_victory_then_strike_in_the_same_frame() -> void:
	_mk_loop()
	var p := _bird(3.0, Vector3(0, Y, 0), Vector3.FORWARD, true, "Player")
	loop.start_run()
	p.global_position = Vector3(0, Y, 0)
	p.mass = 3.0
	loop.set_protection(p, 0.0)
	# An NPC far heavier than the eagle, behind it and pointed at it.
	var big := _bird(5.0, Vector3(0, Y, 0), Vector3.FORWARD, false, "Giant")
	var c_np := loop.rule.contact_distance(big.get_body_radius(), big.get_wingspan(), false, p.get_body_radius(), true)
	big.global_position = Vector3(0, Y, c_np + 0.3)
	loop.step(DT)  # positions remembered: next frame's segments start here
	check(p.alive and Game.state == Game.State.PLAYING, "(setup) nothing happened yet")
	loop.stats.apex_catches = GameLoop.APEX_CATCHES - 1
	# Worthwhile prey already inside the player's reach (contact at t = 0);
	# the giant closes in during the frame (contact at t ~ 0.5, 43 m/s).
	var prey := _bird(0.8, Vector3(0, Y, -0.3), Vector3.FORWARD, false, "Prey")
	big.global_position = Vector3(0, Y, c_np - 0.3)
	loop.step(DT)
	check(not prey.alive, "the player's meal happened")
	eq(loop.stats.victory, true, "the meal completed the apex goal")
	eq(player_caught_n, 0, "no strike on the player after the run ended")
	check(p.alive, "the player is alive")
	eq(loop.lives, GameLoop.MAX_LIVES, "no life lost")
	eq(Game.state, Game.State.ENDED, "Game ENDED (victory), not CAUGHT")
	eq(loop.phase, GameLoop.Phase.ENDED, "phase ENDED")


func test_npc_spawn_grace() -> void:
	_mk_loop(1.0)
	loop.start_run()
	var hunter := _bird(1.0, Vector3(0, Y, 0), Vector3.FORWARD, false, "Hunter")
	var fresh := _bird(0.2, Vector3(0, Y, -0.3), Vector3.FORWARD, false, "Fresh")
	var alive_at := -1.0
	var frames := 0
	while fresh.alive and frames < 200:
		loop.step(DT)
		frames += 1
	alive_at = frames * DT
	check(hunter.alive, "(setup) hunter alive")
	between(alive_at, 0.95, 1.1, "a newly spawned NPC is uncatchable for npc_spawn_grace_s (1 s), then caught")


func test_penalty_floor() -> void:
	_mk_loop()
	var p := _bird(GameLoop.START_MASS, Vector3(0, Y, 0), Vector3.FORWARD, true, "Player")
	loop.start_run()
	p.global_position = Vector3(0, Y, 0)
	loop.set_protection(p, 0.0)
	var hawk := _bird(1.3, Vector3(0, Y, 0.3), Vector3.FORWARD, false, "Hawk")
	loop.step(DT)
	eq(Game.state, Game.State.CAUGHT, "(setup) caught")
	hawk.global_position = Vector3(0, -900, 0)
	for i in int(GameLoop.CAUGHT_BEAT_S / DT) + 3:
		loop.step(DT)
	eq(Game.state, Game.State.PLAYING, "(setup) respawned")
	near(p.mass, GameLoop.START_MASS, 1e-9, "a caught sparrow keeps START_MASS (the penalty's floor)")


## One random crowd (seeded), created in `order`, flown in straight lines
## that bounce in a box for `frames` frames. Returns the catches as
## "frame:pred>prey" strings with the birds' creation tags.
func _crowd(order: Array, frames: int) -> PackedStringArray:
	_mk_loop()
	loop.start_run()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var spec: Array = []
	for i in order.size():
		spec.append({"m": exp(rng.randf_range(log(0.004), log(3.0))),
			"p": Vector3(rng.randf_range(-6, 6), Y + rng.randf_range(-3, 3), rng.randf_range(-6, 6)),
			"v": Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized() * rng.randf_range(2.0, 9.0)})
	var by_tag := {}
	for i: int in order:
		var s: Dictionary = spec[i]
		var b := _bird(s["m"], s["p"], (s["v"] as Vector3).normalized(), false, "T%02d" % i)
		b.velocity = s["v"]
		by_tag[i] = b
	var out := PackedStringArray()
	var seen := {}
	for f in frames:
		for i in spec.size():
			var b: SimBird = by_tag[i]
			if not b.alive:
				continue
			var q := b.global_position + b.velocity * DT
			var v := b.velocity
			if absf(q.x) > 6.0:
				v.x = -v.x
			if absf(q.z) > 6.0:
				v.z = -v.z
			if absf(q.y - Y) > 3.0:
				v.y = -v.y
			b.velocity = v
			b.set_heading(v.normalized())
			b.global_position = b.global_position + v * DT
		caught_log.clear()
		loop.step(DT)
		for c: Array in caught_log:
			var key := "%d:%s>%s" % [f, (c[0] as Node).name, (c[1] as Node).name]
			if not seen.has(key):
				seen[key] = true
				out.append(key)
	for n in made:
		if is_instance_valid(n):
			n.queue_free()
	made.clear()
	await get_tree().process_frame
	return out


func test_whole_loop_is_deterministic_across_registration_orders() -> void:
	var n := 40
	var fwd: Array = range(n)
	var rev: Array = range(n)
	rev.reverse()
	var mix: Array = range(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: int = mix[i]
		mix[i] = mix[j]
		mix[j] = t
	var a: PackedStringArray = await _crowd(fwd, 720)
	var b: PackedStringArray = await _crowd(rev, 720)
	var c: PackedStringArray = await _crowd(mix, 720)
	var a2: PackedStringArray = await _crowd(fwd, 720)
	gt(float(a.size()), 5.0, "(setup) the crowd produces catches (%d)" % a.size())
	eq(a, a2, "same order twice: identical catches")
	eq(b, a, "reversed registration order: identical catches, same frames")
	eq(c, a, "shuffled registration order: identical catches, same frames")
	metric("crowd_catches", a.size())


## Documented contact rule, independent of CatchRule (fine time sampling):
## earliest sampled fraction of the frame with contact + aim (or allowed
## overlap), or -1. (Same geometry as round 2's v3_contract probe.)
static func _ref_time(p0i: Vector3, p1i: Vector3, p0j: Vector3, p1j: Vector3, mi: float, mj: float,
		fwd: Vector3, vdir: Vector3, i_player: bool, j_player: bool, k: int) -> float:
	var si := SizeRules.wingspan_for_mass(mi)
	var sj := SizeRules.wingspan_for_mass(mj)
	var ri := 0.16 * si
	var rj := 0.16 * sj
	var reach := 0.25 * si
	var cone := deg_to_rad(55.0)
	var overlap := 0.6 * (ri + rj)
	if i_player:
		reach = si * 2.0 / clampf(SizeRules.time_scale(mi), 1.0, 4.0)
		cone = deg_to_rad(80.0)
	elif j_player:
		reach = 0.15 * si
		cone = deg_to_rad(40.0)
		overlap = -1.0
	var contact := ri + rj + reach
	var cc := cos(cone)
	var d0 := p0j - p0i
	var dv := (p1j - p0j) - (p1i - p0i)
	var a := dv.length_squared()
	var tc := clampf(-d0.dot(dv) / a, 0.0, 1.0) if a > 1e-12 else 0.0
	if (d0 + dv * tc).length() > contact:
		return -1.0
	for s in k + 1:
		var t := float(s) / k
		var d := d0 + dv * t
		var dist := d.length()
		if dist > contact:
			continue
		if dist <= overlap:
			return t
		var dir := d / maxf(dist, 1e-9)
		if fwd.dot(dir) >= cc or (i_player and vdir != Vector3.ZERO and vdir.dot(dir) >= cc):
			return t
	return -1.0


func test_loop_matches_reference_with_live_masses() -> void:
	# Round 2's independent reference resolved a frame with the start-of-frame
	# masses; round 2's fix re-checks EAT_RATIO at each catch with the masses
	# of that moment (docs/areas/GAMELOOP.md). This reference applies the
	# documented growth (player: meal_gain, cap 4.5 kg; NPC: half of it,
	# capped at +15% of its first-seen mass) while resolving, so it states the
	# new rule independently. Same scenes as the v3_contract probe (seed).
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	var mism := 0
	var catches := 0
	var rechecks := 0
	var details := []
	for trial in 120:
		_mk_loop()
		var n := 30
		var pm := exp(rng.randf_range(log(0.03), log(4.5)))
		var box := SizeRules.wingspan_for_mass(pm) * 2.5
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
			if not is_p and m >= pm * SizeRules.EAT_RATIO and rng.randf() < 0.5 and not p0.is_empty():
				var to_p := (p0[0] - a)
				if to_p.length_squared() > 1e-6:
					h = to_p.normalized().rotated(Vector3.UP, rng.randf_range(-0.9, 0.9))
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
		bs[0].global_position = p0[0]
		bs[0].set_heading(hs[0])
		bs[0].velocity = (p1[0] - p0[0]) / DT
		bs[0].mass = pm
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
		var cands := []
		for i in n:
			for j in n:
				if i == j or ms[i] < ms[j] * SizeRules.EAT_RATIO:
					continue
				var v := p1[i] - p0[i]
				var vd := v.normalized() if v.length_squared() > 1e-12 else Vector3.ZERO
				var t := _ref_time(p0[i], p1[i], p0[j], p1[j], ms[i], ms[j], hs[i], vd, i == 0, j == 0, 4000)
				if t >= 0.0:
					cands.append([t, -ms[i], -ms[j], p1[i].x, p1[i].z, p1[j].x, p1[j].z, i, j])
		cands.sort_custom(func(x: Array, y: Array) -> bool:
			for q in 7:
				if x[q] != y[q]:
					return x[q] < y[q]
			return x[7] < y[7])
		var live := ms.duplicate()
		var dead: Array[bool] = []
		dead.resize(n)
		dead.fill(false)
		var ate := {}
		var player_dead := false
		for c: Array in cands:
			var i: int = c[7]
			var j: int = c[8]
			if dead[i] or dead[j] or ate.has(i):
				continue
			if (i == 0 or j == 0) and player_dead:
				continue
			if live[i] < live[j] * SizeRules.EAT_RATIO:
				rechecks += 1
				continue
			dead[j] = true
			ate[i] = true
			if j == 0:
				player_dead = true
			if i == 0:
				live[0] = minf(live[0] + SizeRules.meal_gain(live[0], live[j]), GameLoop.MAX_PLAYER_MASS)
			else:
				var cap := maxf(ms[i] * (1.0 + GameLoop.NPC_GROWTH_CAP), live[i])
				live[i] = minf(live[i] + SizeRules.meal_gain(live[i], live[j]) * GameLoop.NPC_GROWTH_SHARE, cap)
		for i in n:
			if dead[i]:
				catches += 1
			if (not bs[i].alive) != dead[i]:
				mism += 1
				details.append({"trial": trial, "bird": i, "loop_dead": not bs[i].alive, "ref_dead": dead[i]})
		await after_each()
		before_each()
	metric("live_ref_catches", catches)
	metric("live_ref_ratio_rechecks_that_blocked", rechecks)
	metric("live_ref_mismatches", mism)
	metric("live_ref_details", details.slice(0, 20))
	gt(float(catches), 50.0, "(setup) plenty of catches")
	eq(mism, 0, "loop outcome == independent reference that re-checks the ratio with live masses")


func test_fingerprint_is_blind_to_indentation() -> void:
	# Two versions of a function that behave differently (the second call is
	# inside the if in one, after it in the other), same lines otherwise.
	var one := "func f(x: int) -> int:\n\tvar y := 0\n\tif x > 0:\n\t\ty += 1\n\t\ty += 2\n\treturn y\n"
	var two := "func f(x: int) -> int:\n\tvar y := 0\n\tif x > 0:\n\t\ty += 1\n\ty += 2\n\treturn y\n"
	for d in ["user://r3_hash_a", "user://r3_hash_b"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	var fa := FileAccess.open("user://r3_hash_a/x.gd", FileAccess.WRITE)
	fa.store_string(one)
	fa.close()
	var fb := FileAccess.open("user://r3_hash_b/x.gd", FileAccess.WRITE)
	fb.store_string(two)
	fb.close()
	var ha := IntegratedSim.code_hash(["user://r3_hash_a/x.gd"])
	var hb := IntegratedSim.code_hash(["user://r3_hash_b/x.gd"])
	metric("hash_one", ha)
	metric("hash_two", hb)
	check(ha != hb, "a behavioural change made only by indentation changes the evidence fingerprint (got %s for both)" % ha)
