extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## A whole run of the real game as a competent player plays it: Play through
## the real laser pointer, the real sky (Ecosystem, the tier's NPC budget),
## the real chain (BotPoseSource arms -> WingInput -> FlightModel) flown by
## integration's competent chase pilot, nothing staged, nothing pinned.
## Strategies:
##   cue   - follow the HUD's target cue (as game_catch_test does);
##   stick - take the cue's bird and stay on it until caught/hidden/gone or
##           25 s (a determined person who ignores the cue switching).
## Records: tier times (the brief: pigeon 5-8 min, eagle 20-30 min), catches,
## deaths and by whom, chase outcomes, lives, the run's end.
##
##   tools/gd.sh p2loop_a --headless --fixed-fps 72 res://tests/probes/integration/p2_loop.tscn -- --fresh-settings --strategy=stick --seed=5 --minutes=25 --tag=stick5 [--quality=quest]

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
const CHASE_MAX_S := 25.0
const COMMIT_M := 12.0

var kit: Kit
var main: GameMain
var tag := "loop"
var strategy := "stick"
var seed_v := 5
var minutes := 25.0
var out := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			tag = a.substr(6)
		elif a.begins_with("--strategy="):
			strategy = a.substr(11)
		elif a.begins_with("--seed="):
			seed_v = int(a.substr(7))
		elif a.begins_with("--minutes="):
			minutes = float(a.substr(10))
	_run.call_deferred()


func _save() -> void:
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_loop_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		print("[integration] p2_loop: boot failed")
		get_tree().quit()
		return
	main = kit.main
	var m := main
	out["npcs_budget"] = m.ecosystem.max_npcs
	var hovered := await kit.click(&"main", &"play")
	out["play_hovered"] = hovered
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	out["state_after_play"] = Game.State.keys()[Game.state]
	if Game.state != Game.State.PLAYING:
		# Desktop: no first-flight gate expected; report and bail.
		print("[integration] p2_loop: Play did not start the run: %s screen %s" % [Game.State.keys()[Game.state], kit.screen()])
		_save()
		await kit.teardown()
		get_tree().quit()
		return
	m.ui.onboarding.skip()
	kit.fly_bot(seed_v, ChasePilot)
	var pilot := kit.pilot as ChasePilot
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 110.0
	var catches: Array = []
	var deaths: Array = []
	var tiers: Array = []
	var chases: Array = []
	var minute_rows: Array = []
	var cue_changes := [0]
	var threat_named := [0]
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			catches.append({"t": snappedf(Game.run_time, 0.1), "prey": String(prey.species),
				"assist": snappedf(m.game_loop.rule.player_assist, 0.01), "mass_after": snappedf(m.player.mass, 0.0001)})
	var hist: Array = []
	var on_death := func(by: Bird) -> void:
		var h2 := []
		for r in hist:
			if float(r[0]) >= Game.run_time - 15.0:
				h2.append(r)
		deaths.append({"t": snappedf(Game.run_time, 0.1), "by": String(by.species) if by else "?", "mass": snappedf(m.player.mass, 0.0001),
			"threat_hist": h2, "respite_left": snappedf(m.game_loop.respite_left(), 0.1)})
	var on_tier := func(a: Variant = null, b: Variant = null) -> void:
		tiers.append({"t": snappedf(Game.run_time, 0.1), "species": String(m.game_loop.get_run_stats()["species"])})
	var on_target := func(_a: Variant = null) -> void:
		cue_changes[0] += 1
	var on_threat := func(_lvl: Variant = null, b: Variant = null) -> void:
		if b != null:
			threat_named[0] += 1
	Events.bird_caught.connect(on_caught)
	Events.player_caught.connect(on_death)
	Events.player_tier_changed.connect(on_tier)
	Events.target_changed.connect(on_target)
	Events.threat_changed.connect(on_threat)
	var cur: NpcBird = null
	var since := 0.0
	var off_cue := 0.0
	var rec := {}
	var catches0 := 0
	var next_row := 60.0
	var t := 0.0
	var play_s := minutes * 60.0
	var no_target_s := 0.0
	var min_gap := INF
	var evading := false
	var evasions := 0
	var tick_i := 0
	while t < play_s and Game.state != Game.State.ENDED:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		if Game.run_time >= next_row:
			next_row += 60.0
			var st: Dictionary = m.game_loop.get_run_stats()
			minute_rows.append({"t": snappedf(Game.run_time, 1), "species": String(st["species"]), "mass": snappedf(st["mass"], 0.0001),
				"lives": st["lives"], "catches": st["catches"], "cue_changes": cue_changes[0], "threat_named": threat_named[0],
				"npcs": m.ecosystem.count(), "no_target_s": snappedf(no_target_s, 1), "mode": m.player.mode_name(),
				"pos": [snappedf(m.player.global_position.x, 0.1), snappedf(m.player.global_position.y, 0.1), snappedf(m.player.global_position.z, 0.1)],
				"agl": snappedf(float(m.player.telemetry()["altitude_agl"]), 0.1), "as": snappedf(float(m.player.telemetry()["airspeed"]), 0.1),
				"chasing": String(cur.species) if cur != null and is_instance_valid(cur) else "",
				"gap": snappedf(cur.get_body_position().distance_to(m.player.get_body_position()), 0.1) if cur != null and is_instance_valid(cur) else -1.0,
				"prey_state": NpcBird.State.keys()[cur.state] if cur != null and is_instance_valid(cur) else "",
				"prey_pos": [snappedf(cur.global_position.x, 0.1), snappedf(cur.global_position.y, 0.1), snappedf(cur.global_position.z, 0.1)] if cur != null and is_instance_valid(cur) else []})
			print("[integration] p2_loop %s %s" % [tag, minute_rows[-1]])
		tick_i += 1
		if tick_i % 36 == 0:
			var st3: Dictionary = m.game_loop.get_run_stats()
			var thr: Variant = st3.get("threat")
			var thb: Bird = thr as Bird if thr is Bird and is_instance_valid(thr) else null
			hist.append([snappedf(Game.run_time, 0.1), snappedf(float(st3.get("threat_level", 0.0)), 0.01), String(thb.species) if thb else "",
				snappedf(thb.get_body_position().distance_to(m.player.get_body_position()), 0.1) if thb else -1.0,
				snappedf(m.game_loop.respite_left(), 0.1), evading])
			if hist.size() > 60:
				hist.pop_front()
		if Game.state != Game.State.PLAYING:
			if cur != null:
				rec["end"] = "player caught"
				chases.append(rec)
				cur = null
				pilot.stop_chase()
				kit.cruise()
			continue
		var st4: Dictionary = m.game_loop.get_run_stats()
		if strategy.ends_with("evade"):
			var thr4: Variant = st4.get("threat")
			var lvl := float(st4.get("threat_level", 0.0))
			if thr4 is Bird and is_instance_valid(thr4) and lvl >= 0.3:
				if not evading:
					evading = true
					evasions += 1
					if cur != null:
						rec["end"] = "evaded a threat"
						chases.append(rec)
						cur = null
						pilot.stop_chase()
				var away: Vector3 = m.player.get_body_position() - (thr4 as Bird).get_body_position()
				away.y = 0.0
				var tgt4: Vector3 = m.player.get_body_position() + away.normalized() * 80.0
				pilot.set(&"target", Vector3(tgt4.x, INF, tgt4.z))
				pilot.set(&"chase", false)
				kit.nav = &"heading"
				continue
			elif evading and lvl < 0.1:
				evading = false
				kit.cruise()
			elif evading:
				continue
		var tgt: Variant = st4.get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if named == null:
			no_target_s += 1.0 / 72.0
		if cur != null:
			since += 1.0 / 72.0
			var ended := ""
			var gap := INF
			if is_instance_valid(cur):
				gap = cur.get_body_position().distance_to(m.player.get_body_position())
				min_gap = minf(min_gap, gap)
			if catches.size() > catches0:
				ended = "caught"
			elif not is_instance_valid(cur) or not cur.alive:
				ended = "gone"
			elif cur.hidden:
				ended = "hid"
			elif since > CHASE_MAX_S:
				ended = "gave up"
			elif strategy.begins_with("cue"):
				off_cue = off_cue + 1.0 / 72.0 if named != cur and gap > COMMIT_M else 0.0
				if off_cue > 1.0:
					ended = "cue moved on"
			if ended != "":
				rec["end"] = ended
				rec["s"] = snappedf(since, 0.1)
				rec["min_gap"] = snappedf(min_gap, 0.1)
				chases.append(rec)
				cur = null
				pilot.stop_chase()
				kit.cruise()
				catches0 = catches.size()
		if cur == null and named != null:
			cur = named
			since = 0.0
			off_cue = 0.0
			min_gap = INF
			catches0 = catches.size()
			rec = {"prey": String(named.species), "d0": snappedf(named.global_position.distance_to(m.player.get_body_position()), 0.1),
				"t0": snappedf(Game.run_time, 0.1), "state0": NpcBird.State.keys()[named.state]}
			pilot.chase_prey(named)
	Events.bird_caught.disconnect(on_caught)
	Events.player_caught.disconnect(on_death)
	Events.player_tier_changed.disconnect(on_tier)
	Events.target_changed.disconnect(on_target)
	Events.threat_changed.disconnect(on_threat)
	var ends := {}
	for c: Dictionary in chases:
		ends[c["end"]] = int(ends.get(c["end"], 0)) + 1
	var st2: Dictionary = m.game_loop.get_run_stats()
	out.merge({"tag": tag, "strategy": strategy, "seed": seed_v, "played_s": snappedf(t, 1), "run_time": snappedf(Game.run_time, 1),
		"state_end": Game.State.keys()[Game.state], "final_species": String(st2["species"]), "final_mass": st2["mass"],
		"peak_species": st2.get("peak_tier"), "lives": st2["lives"], "catches": catches, "deaths": deaths, "tiers": tiers,
		"chase_ends": ends, "chases_n": chases.size(), "chases": chases, "minutes": minute_rows, "cue_changes": cue_changes[0],
		"no_target_s": snappedf(no_target_s, 1), "evasions": evasions, "errors": kit.log.errors, "log": kit.log.summary()})
	print("[integration] p2_loop %s DONE: %.0f s, %s (peak tier %s), %d catches, %d deaths, tiers %s, chase ends %s, %s" % [
		tag, t, st2["species"], st2.get("peak_tier"), catches.size(), deaths.size(), tiers, ends, kit.log.summary()])
	_save()
	await kit.teardown()
	get_tree().quit()
