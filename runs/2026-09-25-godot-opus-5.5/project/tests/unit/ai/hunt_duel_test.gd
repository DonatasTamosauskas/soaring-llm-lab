extends "res://tests/unit/ai/ai_sim.gd"
## A2 Hunting: isolated duels in open air (no cover), many seeded trials, for
## EVERY predator>prey pair the ecosystem can produce: the predator is a
## hunting species and the prey is edible and worth it to it at their book
## masses (SizeRules.can_eat + is_worthwhile, the rule NpcBrain picks prey
## by) - 22 pairs from wren>moth to eagle>hawk.
##  * vs a prey that does not flee (it just goes about its business), a
##    hunter must catch it > 80% of the time;
##  * vs a prey that flees (awareness, reaction time, jinks, fatigue), the
##    chase must be a contest: 20-70% caught, per pair and overall.
## Catches use the stand-in checker (swept contact within body radii), the
## strict reading of the GameLoop contract (GameLoop's own rule adds a reach
## margin; see docs/areas/AI.md).
##
## A catch rate is a probability; a sample of n duels only estimates it
## (16 trials: +-12% standard error). So:
##  * evidence run, 40 or more trials per pair: every pair's measured rate
##    must lie in 20-70% - the criterion itself. One seed family can flatter
##    an edge pair (a verifier found hawk>gull at 17% on families the
##    tuning never saw), so the evidence pools --duel_families=F independent
##    families (trial numbers t + 1000 f) of --duel_trials=N each:
##      tools/gd.sh ai --headless res://tests/runner.tscn -- --suite=unit/ai/hunt_duel --duel_trials=48 --duel_families=4
##  * the default suite run (16 trials, a fast regression guard): no pair
##    may be *demonstrably* outside the band - its 80% Wilson interval must
##    overlap 20-70% (<= 1/16 or >= 14/16 fails) - and the
##    overall rate, 350 chases, must lie in 30-60%.
## Calm duels (true rates 90-100%) are pinned per pair at > 80% in both.
## --duel_pairs=wren>moth,hawk>crow runs only some pairs.

## Long enough for a full chase between near-equals (a hawk after a gull
## closes at ~1.3 m/s; NpcBrain allows up to 52 s from when the prey
## notices, plus the approach before that).
const MAX_S := 62.0
const Plot := preload("res://tests/unit/ai/ai_plot.gd")
## Trials per pair and mode that also get a trajectory plot.
const PLOT_TRIALS := 1

var _open: World
## Duels that started with other birds still registered (must stay 0).
var _crowded := 0


## Every pair the ecosystem can produce (see the header).
static func all_pairs() -> Array:
	var out := []
	for a in SizeRules.SPECIES:
		if float(SpeciesProfile.of(a["id"])["hunt"]) <= 0.0:
			continue
		for b in SizeRules.SPECIES:
			if SizeRules.can_eat(a["mass"], b["mass"]) and SizeRules.is_worthwhile(a["mass"], b["mass"]):
				out.append([a["id"], b["id"]])
	return out


func _pairs() -> Array:
	var only := String(Paths.arg("duel_pairs", ""))
	var out := []
	for pr in all_pairs():
		if only.is_empty() or only.split(",").has("%s>%s" % pr):
			out.append(pr)
	return out


func _trials() -> int:
	return int(Paths.arg("duel_trials", "16"))


## Independent seed families pooled per pair (see the header).
func _families() -> int:
	return maxi(int(Paths.arg("duel_families", "1")), 1)


func before_all() -> void:
	_open = await make_open_world()


func after_all() -> void:
	await clear_sim()
	if is_instance_valid(_open):
		_open.queue_free()


## One duel. Returns {caught, time, reason, min_dist}.
func _duel(pred_sp: StringName, prey_sp: StringName, fleeing: bool, trial: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([String(pred_sp), String(prey_sp), fleeing, trial])
	_seed = rng.seed % 100000
	var prey_pos := Vector3(rng.randf_range(-20, 20), 40.0, rng.randf_range(-20, 20))
	var a := rng.randf() * TAU
	var prey_dir := Vector3(cos(a), 0, sin(a))
	var prey := spawn(prey_sp, prey_pos, prey_dir * SizeRules.performance(SizeRules.species_data(prey_sp)["mass"])["cruise"], _open)
	prey.can_hunt = false
	prey.can_flee = fleeing
	prey.home = Vector3(prey_pos.x, 0, prey_pos.z)
	var bearing := rng.randf() * TAU
	var pred_prof := SpeciesProfile.of(pred_sp)
	# Start inside the hunter's range (it only picks prey it can see).
	var dist := rng.randf_range(0.55, 0.9) * float(pred_prof["hunt_range_m"])
	var height := rng.randf_range(-5.0, 10.0)
	if pred_prof["stoop"] and trial % 2 == 0:
		height = rng.randf_range(25.0, 45.0)  # raptors often attack from above
	var pred_pos := prey_pos + Vector3(cos(bearing) * dist, height, sin(bearing) * dist)
	var to := (prey_pos - pred_pos)
	to.y = 0.0
	var pred := spawn(pred_sp, pred_pos, to.normalized() * SizeRules.performance(SizeRules.species_data(pred_sp)["mass"])["cruise"], _open)
	# A duel is the two of them alone (see the cleanup below).
	if Birds.count() != 2:
		_crowded += 1
	pred.can_flee = false
	pred.hunger = 1.0
	pred.brain._pending_prey = prey
	pred.brain._enter(NpcBird.State.HUNT)
	make_checker()
	var out := {"caught": false, "time": MAX_S, "reason": "timeout", "min_dist": INF, "fled": false, "stooped": false}
	var tr_pred := PackedVector3Array()
	var tr_prey := PackedVector3Array()
	var marks := []
	var jinks := [0]
	prey.behaviour.connect(func(_b: NpcBird, what: StringName) -> void:
		if what == &"jink":
			jinks[0] += 1)
	run(MAX_S, func(i: int) -> bool:
		if i % 2 == 0:
			tr_pred.append(pred.global_position)
			tr_prey.append(prey.global_position)
		if prey.state == NpcBird.State.FLEE and not out["fled"]:
			marks.append(["flee", prey.global_position])
		if prey.state == NpcBird.State.FLEE:
			out["fled"] = true
		if pred.state == NpcBird.State.STOOP:
			out["stooped"] = true
		if prey.alive:
			out["min_dist"] = minf(out["min_dist"], pred.global_position.distance_to(prey.global_position))
		if not prey.alive:
			out["caught"] = true
			out["time"] = (i + 1) * DT
			out["reason"] = "caught"
			return true
		if pred.state != NpcBird.State.HUNT and pred.state != NpcBird.State.STOOP:
			out["time"] = (i + 1) * DT
			out["reason"] = pred.brain.give_up_reason
			if OS.get_environment("AI_DEBUG") != "":
				print("[ai] gave up %s st=%s budget=%.1f hunt_t=%.1f chase0=%.1f passes=%d e=%.2f" % [pred.brain.give_up_reason, pred.state_name(), pred.brain._approach_budget, pred.brain._hunt_t, pred.brain._chase_t0, pred.brain._passes, pred.energy])
			return true
		return false)
	out["passes"] = pred.brain._passes + (1 if out["caught"] else 0)
	out["jinks"] = jinks[0]
	if OS.get_environment("AI_DEBUG") != "":
		print("[ai]   trial %d %s>%s flee=%s caught=%s t=%.1f jinks=%d passes=%d stooped=%s prey_e=%.2f pred_e=%.2f reason=%s" % [trial, pred_sp, prey_sp, fleeing, out["caught"], out["time"], jinks[0], pred.brain._passes, out["stooped"], prey.energy, pred.energy, out["reason"]])
	if trial < PLOT_TRIALS or (not fleeing and not out["caught"]):
		_plot_duel("%s_%s_%s_%d" % [pred_sp, prey_sp, "flee" if fleeing else "calm", trial], tr_pred, tr_prey, marks, out)
	for b in [prey, pred]:
		loose.erase(b)
		# Out of the tree - and so out of the Birds registry - now, not at the
		# end of the frame: the next trial of this pair starts before a frame
		# passes, and a queued bird would still be sensed, fled from, hunted
		# and caught (up to 2 x trials frozen birds hung about the duel area;
		# 48- and 192-trial runs slowed quadratically).
		if b.is_inside_tree():
			b.get_parent().remove_child(b)
		b.queue_free()
	checker = null
	return out


## Top-down and side views of one duel: hunter red, prey blue.
func _plot_duel(tag: String, a: PackedVector3Array, b: PackedVector3Array, marks: Array, out: Dictionary) -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for p in a + b:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := maxf(maxf(hi.x - lo.x, hi.z - lo.z), 20.0) * 0.55
	var c := (lo + hi) * 0.5
	var pl := Plot.new(900, 460, Color(0.97, 0.97, 0.95), Vector2(c.x - span, c.z - span), Vector2(c.x + span, c.z + span))
	pl.w = 440
	var side := Plot.new(1, 1, Color.WHITE)
	var hs := maxf(maxf(hi.x - lo.x, hi.y - lo.y), 20.0) * 0.55
	var cy := (lo.y + hi.y) * 0.5
	var map_side := func(p: Vector3) -> Vector2:
		return Vector2(460 + (p.x - (c.x - hs)) / (2.0 * hs) * 440, 460 - (p.y - (cy - hs)) / (2.0 * hs) * 440)
	var ta := PackedVector2Array()
	var tb := PackedVector2Array()
	var sa := PackedVector2Array()
	var sb := PackedVector2Array()
	for p in a:
		ta.append(pl.top(p))
		sa.append(map_side.call(p))
	for p in b:
		tb.append(pl.top(p))
		sb.append(map_side.call(p))
	pl.line(Vector2(450, 0), Vector2(450, 460), Color(0.6, 0.6, 0.6))
	pl.w = 900
	pl.polyline(tb, Color(0.2, 0.35, 0.85), 1)
	pl.polyline(ta, Color(0.85, 0.2, 0.15), 1)
	pl.polyline(sb, Color(0.2, 0.35, 0.85), 1)
	pl.polyline(sa, Color(0.85, 0.2, 0.15), 1)
	if not ta.is_empty():
		pl.dot(ta[0], Color(0.85, 0.2, 0.15), 4)
		pl.dot(tb[0], Color(0.2, 0.35, 0.85), 4)
		pl.dot(sa[0], Color(0.85, 0.2, 0.15), 4)
		pl.dot(sb[0], Color(0.2, 0.35, 0.85), 4)
		if out["caught"]:
			pl.cross(tb[-1], Color.BLACK, 7)
			pl.cross(sb[-1], Color.BLACK, 7)
	for m in marks:
		pl.circle(pl.top(m[1]), 6, Color(0.1, 0.6, 0.2))
	pl.text(Vector2(8, 8), tag.replace("_", " "), Color.BLACK, 2)
	pl.text(Vector2(8, 28), "%s  T %.1fS  MIN %.2fM" % [out["reason"], out["time"], out["min_dist"]], Color.BLACK, 2)
	pl.text(Vector2(8, 440), "TOP (X,Z)  %.0fM ACROSS" % (span * 2.0), Color(0.3, 0.3, 0.3), 1)
	pl.text(Vector2(468, 8), "SIDE (X,Y)", Color(0.3, 0.3, 0.3), 2)
	pl.save(Paths.artifacts("ai").path_join("duels/%s.png" % tag))


func _series(fleeing: bool) -> Dictionary:
	var table := {}
	var total := 0
	var caught := 0
	var per := _trials()
	var trials := per * _families()
	for pair in _pairs():
		var n := 0
		var reasons := {}
		var times := []
		var fled := 0
		var passes := 0
		var jk := 0
		var st := [0, 0]
		for t in trials:
			# Family f re-runs trial numbers 0..per-1 shifted by 1000 f, so
			# trial parity (raptors attack from above on even trials) holds.
			var r := _duel(pair[0], pair[1], fleeing, t % per + floori(float(t) / per) * 1000)
			passes += r["passes"]
			jk += r["jinks"]
			if r["stooped"]:
				st[0] += 1
				st[1] += 1 if r["caught"] else 0
			if r["caught"]:
				n += 1
				times.append(snappedf(r["time"], 0.1))
			reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
			if r["fled"]:
				fled += 1
		await wait_frames(1)
		var key := "%s>%s" % [pair[0], pair[1]]
		table[key] = {"rate": float(n) / trials, "trials": trials, "reasons": reasons, "fled": fled, "times": times,
			"passes": passes, "jinks": jk, "stoops": st[0], "stoop_catches": st[1]}
		print("[ai] duel %s fleeing=%s: %d/%d caught %s fled=%d passes=%d jinks=%d stoops=%d/%d" % [key, fleeing, n, trials, reasons, fled, passes, jk, st[1], st[0]])
		total += trials
		caught += n
	table["overall"] = float(caught) / total
	return table


## Wilson score interval (lo, hi) of a binomial proportion c/n at z.
static func wilson(c: int, n: int, z: float) -> Vector2:
	if n <= 0:
		return Vector2(0.0, 1.0)
	var p := float(c) / n
	var z2 := z * z
	var den := 1.0 + z2 / n
	var mid := (p + z2 / (2.0 * n)) / den
	var half := z * sqrt(p * (1.0 - p) / n + z2 / (4.0 * n * n)) / den
	return Vector2(maxf(mid - half, 0.0), minf(mid + half, 1.0))


func test_every_pair_the_ecosystem_produces_is_tested() -> void:
	var pairs := all_pairs()
	metric("pairs", pairs.map(func(pr: Array) -> String: return "%s>%s" % pr))
	gt(pairs.size(), 15, "the ladder yields many hunter>prey pairs (%d)" % pairs.size())
	for must in [[&"wren", &"moth"], [&"starling", &"swallow"], [&"pigeon", &"swallow"], [&"eagle", &"hawk"]]:
		check(pairs.has(must), "%s>%s is among them" % must)


func test_hunters_catch_non_fleeing_prey() -> void:
	var table := await _series(false)
	metric("catch_rates", table)
	for k in table:
		if k == "overall":
			continue
		gt(table[k]["rate"], 0.8, "%s catch rate vs non-fleeing prey" % k)
	gt(table["overall"], 0.8, "overall catch rate vs non-fleeing prey")
	eq(_crowded, 0, "every duel was the two birds alone")


func test_chases_against_fleeing_prey_are_contests() -> void:
	var table := await _series(true)
	metric("catch_rates", table)
	var evidence := _trials() * _families() >= 40
	for k in table:
		if k == "overall":
			continue
		var r: Dictionary = table[k]
		var n: int = r["trials"]
		var c := int(round(float(r["rate"]) * n))
		if evidence:
			between(r["rate"], 0.2, 0.7, "%s catch rate vs fleeing prey (%d trials)" % [k, n])
		else:
			var ci := wilson(c, n, 1.28)
			check(ci.y >= 0.2 and ci.x <= 0.7, "%s catch rate vs fleeing prey %d/%d: 80%% interval [%.2f, %.2f] overlaps 20-70%%" % [k, c, n, ci.x, ci.y])
		gt(r["fled"], n * 0.8, "%s prey noticed the hunter and fled" % k)
	eq(_crowded, 0, "every duel was the two birds alone")
	if evidence:
		between(table["overall"], 0.2, 0.7, "overall catch rate vs fleeing prey")
	elif _pairs().size() == all_pairs().size():
		between(table["overall"], 0.3, 0.6, "overall catch rate vs fleeing prey (all pairs pooled)")
