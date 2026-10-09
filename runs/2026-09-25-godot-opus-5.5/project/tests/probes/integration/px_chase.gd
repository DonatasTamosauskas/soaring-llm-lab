extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## Can the REAL player bird (flight's BotPoseSource arm motion through the
## real WingInput and FlightModel) catch REAL NPC prey in the shipped game,
## with nothing staged, no pinned assist, no cooperative prey? Each chase is
## logged with its closest approach split into horizontal / vertical parts
## and the contact distance the catch rule needed at that moment.
##
##   tools/gd.sh pxv_chase --headless --fixed-fps 72 res://tests/probes/integration/px_chase.tscn -- --fresh-settings --strategy=cue|cue_glide|moth [--secs=300] [--tag=x] [--protect=1]
##
## Strategies: cue = follow the game's target cue with the stock pilot;
## cue_glide = the same, but stop flapping for the final approach (as birds
## and people do) when the prey is close and level; moth = only the nearest
## free moth (the slowest food in the sky).

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var out := {}
var chases: Array = []
var cur: NpcBird = null
var rec := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _pick(strategy: String) -> NpcBird:
	var p := kit.main.player
	if strategy == "moth":
		var best: NpcBird = null
		var bd := 90.0
		for n in kit.main.ecosystem.get_npcs():
			if is_instance_valid(n) and n.alive and not n.hidden and n.species == &"moth":
				var d := n.global_position.distance_to(p.get_body_position())
				if d < bd:
					bd = d
					best = n
		return best
	var t: Bird = kit.stats()["target"]
	return t as NpcBird if t != null and is_instance_valid(t) and t is NpcBird else null


func _contact(prey: Bird) -> float:
	var p := kit.main.player
	return kit.main.game_loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, prey.get_body_radius())


func _run() -> void:
	var strategy := _arg("strategy", "cue")
	var secs := float(_arg("secs", "300"))
	var tag := _arg("tag", strategy)
	var protect := _arg("protect", "0") == "1"
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	kit.main.ui.onboarding.skip()
	kit.fly_bot(int(_arg("seed", "21")))
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 110.0
	var p := kit.main.player
	out["sparrow"] = {"span": p.get_wingspan(), "radius": p.get_body_radius(), "perf": SizeRules.performance(p.mass)}
	out["prey_perf"] = {"moth": SizeRules.performance(0.004), "wren": SizeRules.performance(0.012)}
	var t := 0.0
	var catches0 := int(kit.stats()["catches"])
	var bob := []  # body vertical oscillation in steady chase flapping
	while t < secs:
		await get_tree().physics_frame
		t += 1.0 / 72.0
		if Game.state == Game.State.ENDED:
			out["ended_at"] = t
			break
		if Game.state != Game.State.PLAYING:
			_end("player_not_playing", t)
			continue
		if protect and kit.main.game_loop.protection_left(p) < 1.0:
			kit.main.game_loop.set_protection(p, 30.0)
		var pp := p.get_body_position()
		if cur != null:
			var alive := is_instance_valid(cur) and cur.alive
			if not alive:
				_end("caught" if int(kit.stats()["catches"]) > catches0 else "gone", t)
				catches0 = int(kit.stats()["catches"])
			else:
				var rel := cur.get_body_position() - pp
				var d := rel.length()
				if d < float(rec["closest"]):
					rec["closest"] = snappedf(d, 0.01)
					rec["closest_h"] = snappedf(Vector2(rel.x, rel.z).length(), 0.01)
					rec["closest_v"] = snappedf(rel.y, 0.01)
					rec["contact_needed"] = snappedf(_contact(cur), 0.01)
					rec["prey_state_at_closest"] = cur.state_name()
					rec["prey_speed_at_closest"] = snappedf(cur.velocity.length(), 0.1)
					rec["player_speed_at_closest"] = snappedf(p.velocity.length(), 0.1)
					var fwd := p.velocity.normalized()
					rec["angle_at_closest"] = snappedf(rad_to_deg(fwd.angle_to(rel)), 1.0)
				if d < 12.0:
					rec["ticks_within_12m"] = int(rec["ticks_within_12m"]) + 1
				if cur.hidden:
					_end("hid", t)
				elif t - float(rec["t0"]) > 30.0:
					_end("timeout", t)
				elif strategy != "moth" and kit.stats()["target"] != cur and t - float(rec["t0"]) > 1.0:
					_end("cue_moved_on", t)
				elif strategy == "cue_glide":
					var h := Vector2(rel.x, rel.z).length()
					kit.set_mode(&"glide" if h < 10.0 and rel.y > -2.5 and rel.y < 0.6 else &"cruise")
				elif strategy == "sprint_lead":
					# Lead pursuit at sprint speed, gliding the last metres.
					var h2 := Vector2(rel.x, rel.z).length()
					var t_lead := clampf(d / maxf(p.velocity.length(), 1.0) * 0.7, 0.0, 1.0)
					kit.pilot.set(&"target", cur.get_body_position() + cur.velocity * t_lead)
					kit.pilot.set(&"chase", true)
					kit.set_mode(&"glide" if h2 < 6.0 and rel.y > -2.0 and rel.y < 0.5 else &"cruise")
		if cur == null:
			var n := _pick(strategy)
			if n != null:
				cur = n
				rec = {"prey": String(n.species), "t0": t, "d0": snappedf(n.global_position.distance_to(pp), 0.1),
					"closest": INF, "ticks_within_12m": 0, "player": String(p.species), "assist0": snappedf(kit.main.game_loop.catch_assist(), 2)}
				if strategy == "sprint_lead":
					kit.pilot.set(&"k_vc", 1.35)
					kit.pilot.set(&"k_l1", 0.8)
					kit.pilot.set(&"target", n.get_body_position())
					kit.pilot.set(&"chase", true)
				else:
					kit.chase_bird(n)
		if int(t * 72.0) % 7 == 0:
			bob.append(p.velocity.y)
	out["strategy"] = strategy
	out["chases"] = chases
	var ends := {}
	for c: Dictionary in chases:
		ends[c["end"]] = int(ends.get(c["end"], 0)) + 1
	out["ends"] = ends
	out["run_stats"] = {"catches": kit.stats()["catches"], "times_caught": kit.stats()["times_caught"],
		"species": String(kit.stats()["species"]), "mass": kit.stats()["mass"], "lives": kit.stats()["lives"],
		"catch_assist": kit.stats()["catch_assist"], "run_time": kit.stats()["run_time"]}
	out["errors"] = kit.log.errors
	out["log"] = kit.log.samples
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_chase_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_chase %s: %d chases, ends %s, catches %s, caught %s, errors %d" % [tag, chases.size(), ends,
		kit.stats()["catches"], kit.stats()["times_caught"], kit.log.errors])
	await kit.teardown()
	get_tree().quit()


func _end(why: String, t: float) -> void:
	if cur == null:
		return
	rec["end"] = why
	rec["dur"] = snappedf(t - float(rec["t0"]), 0.1)
	if rec["closest"] == INF:
		rec["closest"] = -1
	chases.append(rec)
	cur = null
	rec = {}
	kit.cruise()
	kit.set_mode(&"cruise")
	kit.pilot.set(&"k_vc", 1.0)
	kit.pilot.set(&"k_l1", 1.3)
