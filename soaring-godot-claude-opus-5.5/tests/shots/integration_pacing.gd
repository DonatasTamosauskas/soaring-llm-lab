extends Node
## The brief's pacing through the real game (integration round 2): one whole
## run of scenes/main.tscn per process, played by the competent person of
## tests/unit/integration/integration_person.gd (the game loop's modelled
## competent player - SimPilot's cues, evasion and chase rules - flying the
## real PlayerBird through BotPoseSource arms, the real WingInput and
## FlightModel), in the real sky at the chosen quality tier. Nothing is
## staged or pinned. Writes one part file:
##   artifacts/integration/pacing/<batch>/part_<tier>_<seed>.json
## tests/shots/integration_pacing.sh runs a batch and merges it into
## tests/unit/integration/data/real_pacing.json, which
## tests/unit/integration/real_pacing_test.gd asserts on.
##
##   tools/gd.sh ip0 --headless --fixed-fps 72 res://tests/shots/integration_pacing.tscn -- --fresh-settings \
##       --seed=5 --minutes=40 --batch=b1 [--quality=quest] [--npcs=20] [--skill=novice|competent|expert]
## (Core loop round: the person's skill is a run argument, and every part
## records the danger director's attacks, the sky's pellets and the NPC
## catches the player saw - within 40 m inside its view along the flight.)

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const Person := preload("res://tests/unit/integration/integration_person.gd")

## The code a real-chain run executes, hashed into every part file: the
## rules, the sky, the valley, the flight and the input chain, the
## composition, and the person (comments and blank lines left out:
## IntegratedSim.code_hash). UI, audio, birds' looks and VR presence do not
## change a headless run.
const CODE: Array[String] = ["res://scripts/core", "res://scripts/flight", "res://scripts/ai", "res://scripts/game",
	"res://scripts/integration", "res://scripts/main.gd", "res://scenes/main.tscn", "res://scenes/player/player.tscn",
	"res://scenes/ai/ecosystem.tscn", "res://scenes/world/world.tscn", "res://scripts/world",
	"res://scripts/game/sim/sim_pilot.gd", "res://scripts/game/sim/integrated_sim.gd", "res://scripts/game/sim/ai_mirror.gd",
	"res://tests/unit/integration/integration_pilot.gd", "res://tests/unit/integration/integration_chase_pilot.gd",
	"res://tests/unit/integration/integration_person_pilot.gd", "res://tests/unit/integration/integration_person.gd",
	"res://tests/unit/integration/integration_bot.gd", "res://tests/unit/integration/game_kit.gd",
	"res://tests/shots/integration_pacing.gd"]


static func code_fingerprint() -> String:
	return IntegratedSim.code_hash(CODE, IntegratedSim.WORLD_CODE_SKIP)


var kit: Kit
var out := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	var seed_v := int(Paths.arg("seed", "5"))
	var minutes := float(Paths.arg("minutes", "40"))
	var batch := Paths.arg("batch", "adhoc")
	var npcs := int(Paths.arg("npcs", "0"))
	var skill := Paths.arg("skill", "competent")
	var trace_from := float(Paths.arg("trace_from", "-1"))
	# A tuning sweep's growth (the game loop's pacing tool varies the same two
	# statics); the part file records what ran.
	var growth := Paths.arg("growth", "")
	if not growth.is_empty():
		var g := growth.split(",")
		SizeRules.growth_gain = float(g[0])
		if g.size() > 1:
			SizeRules.growth_size_exp = float(g[1])
	var t_wall0 := Time.get_ticks_msec()
	kit = Kit.new()
	if not await kit.boot(self, true):
		print("[integration] pacing: boot failed")
		get_tree().quit(1)
		return
	var m := kit.main
	if npcs > 0:
		m.ecosystem.max_npcs = npcs
	var tier := m.quality.name
	var tag := "%s_%d" % [tier if npcs <= 0 else "%s%d" % [tier, npcs], seed_v]
	if skill != "competent":
		tag = "%s_%s" % [skill, tag]
	out = {"seed": seed_v, "tier": tier, "npcs": m.ecosystem.max_npcs, "minutes": minutes, "batch": batch, "skill": skill,
		"code": code_fingerprint(), "growth": [SizeRules.growth_gain, SizeRules.growth_size_exp],
		"load_start": _load(), "date": Time.get_datetime_string_from_system()}
	# Play through the game's own bridge (game_catch_test: the pointer's
	# wall-clock grace would make the run's start, and so the run, differ).
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	var start_mass := float(Paths.arg("start_mass", "-1"))
	if start_mass > 0.0:
		# Diagnostics (--start_mass=kg): a run from another size (the loop
		# adopts the mass; never evidence - the part records it).
		m.player.mass = start_mass
		out["start_mass"] = start_mass
	var person := Person.new(kit, seed_v, StringName(skill))
	var tier_at := {}
	var start_tier := SizeRules.tier_for_mass(GameLoop.START_MASS)
	tier_at[str(start_tier)] = 0.0
	var t := [0.0]
	var catches: Array = []
	var deaths: Array = []
	var victory := [-1.0]
	var apex := [-1.0]
	var on_tier := func(_o: int, n: int) -> void:
		for k in range(n, start_tier - 1, -1):
			if not tier_at.has(str(k)):
				tier_at[str(k)] = snappedf(t[0], 0.1)
	var seen_npc := []
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			catches.append({"t": snappedf(t[0], 0.1), "prey": String(prey.species), "prey_g": snappedf(prey.mass * 1000.0, 0.1),
				"g": snappedf(m.player.mass * 1000.0, 0.1), "assist": snappedf(m.game_loop.rule.player_assist, 0.001),
				"d": snappedf(prey.get_body_position().distance_to(m.player.get_body_position()), 0.01),
				"swarm": prey is SwarmMoth})
		elif prey != m.player and Game.state == Game.State.PLAYING and _in_view(m, prey.get_body_position(), SEEN_M):
		# An NPC catch the player could see (the sky alive in view).
			seen_npc.append({"t": snappedf(t[0], 0.1), "pred": String(pred.species), "prey": String(prey.species),
				"d": snappedf(prey.get_body_position().distance_to(m.player.get_body_position()), 0.1)})
	# The last seconds before a death (4 Hz): the threat cue's level and the
	# bird it names, what the person was doing, the killer's distance,
	# bearing from the player's heading (deg; 180 = from behind) and whether
	# it was hunting the player.
	var hist: Array = []
	var killer_ref: Array = [null]
	var on_death := func(by: Bird) -> void:
		var tail: Array = []
		for r in hist:
			if float(r[0]) >= t[0] - 6.0:
				tail.append(r)
		var kb := by as NpcBird
		deaths.append({"t": snappedf(t[0], 0.1), "by": String(by.species) if by != null else "?",
			"as": String(m.player.species), "g": snappedf(m.player.mass * 1000.0, 0.1),
			"killer_hunting_player": kb != null and kb.target == m.player,
			"killer_state": NpcBird.STATE_NAMES[kb.state] if kb != null else "?",
			"respite_left": snappedf(m.game_loop.respite_left(), 0.1), "tail": tail})
		killer_ref[0] = null
	var on_victory := func(_s: Variant = null) -> void:
		if victory[0] < 0.0:
			victory[0] = t[0]
	var on_apex := func() -> void:
		if apex[0] < 0.0:
			apex[0] = t[0]
	# The target cue's changes, by why the bird it named stopped being named:
	# gone (eaten, despawned), hidden / sheltered, out of range or sight
	# (the loop drops a target it cannot see for a second), or preference (a
	# rival scored better while the named bird was still a valid target).
	var cue := {"changes": 0, "to_none": 0, "gone": 0, "hidden": 0, "range_or_sight": 0, "preference": 0}
	var cue_prev: Array = [null]
	var on_target := func(b: Variant) -> void:
		var old: Variant = cue_prev[0]
		cue_prev[0] = b
		if old == null or Game.state != Game.State.PLAYING:
			return
		cue["changes"] += 1
		if b == null:
			cue["to_none"] += 1
		if not is_instance_valid(old) or not (old as Bird).alive or not (old as Bird).is_inside_tree():
			cue["gone"] += 1
		elif m.game_loop.is_sheltered(old as Bird, m.player.get_wingspan()):
			cue["hidden"] += 1
		elif (old as Bird).get_body_position().distance_to(m.player.get_body_position()) \
				> m.game_loop.watch.target_range(m.player.mass) * m.game_loop.watch.range_hysteresis * 0.98 \
				or not person.call(&"_sees", m.player.get_body_position(), (old as Bird).get_body_position()):
			cue["range_or_sight"] += 1
		else:
			cue["preference"] += 1
	# The cues as the person met them (CueTrack, as the game loop's modelled
	# runs record them: the threat cue at every change, both frame by frame).
	var track := CueTrack.new(m.game_loop, m.player)
	Events.target_changed.connect(on_target)
	Events.player_tier_changed.connect(on_tier)
	Events.bird_caught.connect(on_caught)
	Events.player_caught.connect(on_death)
	m.game_loop.victory.connect(on_victory)
	m.game_loop.apex_reached.connect(on_apex)
	var play_s := minutes * 60.0
	var dt := 1.0 / 72.0
	var next_row := 60.0
	var rows: Array = []
	# When each attack on the player began: a bird HUNTING the player at
	# attack strength (its own threat level; onsets within ATTACK_MERGE_S of
	# the last one's end are the same attack, a jink), and the danger marks
	# the player saw (4 Hz: birds marked 2 within its highlight range - how
	# many, and how many of them neither hunting it, nor named, nor within
	# ThreatWatch.DANGER_MARK_HOLD_S of hunting it).
	var attack_times: Array = []
	var attack_last := [-INF]
	var attack_on := [false]
	# The first time anything set off after the player (a bird hunting it).
	var first_hunt := [-1.0]
	var marks := {"samples": 0, "marked": 0, "not_hunting": 0, "on_murmuration": 0}
	var loop_catch_us: Array[float] = []
	var loop_watch_us: Array[float] = []
	var loop_birds: Array[float] = []
	while t[0] < play_s and Game.state != Game.State.ENDED:
		t[0] += dt
		track.t = t[0]
		await kit.advance(dt)
		track.step(dt)
		person.step(dt)
		if Game.state == Game.State.PLAYING:
			var hunted := false
			for q in Birds.all():
				if q != m.player and q.alive and IntegratedSim.hunts(q, m.player):
					if first_hunt[0] < 0.0:
						first_hunt[0] = t[0]
					if m.game_loop.watch.level_of(q) >= GameLoop.ATTACK_LEVEL:
						hunted = true
						break
			if hunted:
				if not attack_on[0] and t[0] - float(attack_last[0]) > ATTACK_MERGE_S:
					attack_times.append(snappedf(t[0], 0.1))
				attack_on[0] = true
				attack_last[0] = t[0]
			else:
				attack_on[0] = false
		if Game.state == Game.State.PLAYING and int(t[0] * 72.0 + 0.5) % 6 == 0:
			# The loop's own cost per frame (its perf timers), every 6th tick.
			loop_catch_us.append(float(m.game_loop.perf.get("catch", 0)))
			loop_watch_us.append(float(m.game_loop.perf.get("watch", 0)))
			loop_birds.append(float(Birds.count()))
		if int(t[0] * 72.0 + 0.5) % 18 == 9 and Game.state == Game.State.PLAYING:
			marks["samples"] += 1
			var w2 := m.game_loop.watch
			for id: int in w2.highlights:
				if int(w2.highlights[id]) != 2:
					continue
				var q := instance_from_id(id) as Bird
				if q == null or not q.alive:
					continue
				marks["marked"] += 1
				if not (IntegratedSim.hunts(q, m.player) or q == w2.predator or w2.hunted_recently(q)):
					marks["not_hunting"] += 1
				var qn := q as NpcBird
				if qn != null and qn.flock != null and qn.flock.kind == "murmuration":
					marks["on_murmuration"] += 1
		if int(t[0] * 72.0 + 0.5) % 18 == 0 and Game.state == Game.State.PLAYING:
			var w := m.game_loop.watch
			var pr: Bird = w.predator if w.predator != null and is_instance_valid(w.predator) and w.predator.is_inside_tree() else null
			var row := [snappedf(t[0], 0.01), snappedf(w.level, 0.01), String(pr.species) if pr else "", String(person.mode)]
			if pr:
				var rel := pr.get_body_position() - m.player.get_body_position()
				var hv := Vector3(m.player.velocity.x, 0.0, m.player.velocity.z)
				var brg := rad_to_deg(hv.normalized().angle_to(Vector3(rel.x, 0.0, rel.z).normalized())) if hv.length() > 0.3 else -1.0
				row.append_array([snappedf(rel.length(), 0.1), snappedf(brg, 1.0), IntegratedSim.hunts(pr, m.player)])
			hist.append(row)
			if hist.size() > 40:
				hist.pop_front()
		if trace_from >= 0.0 and t[0] >= trace_from and int(t[0] * 72.0 + 0.5) % 72 == 0:
			# Diagnostics (--trace_from=S): the player's flight each second.
			var tl: Dictionary = m.player.telemetry()
			var pv := m.player.velocity
			var pq: Bird = person.prey if person.prey != null and is_instance_valid(person.prey) else null
			print("[integration] trace %.0f %s pos %s vel %s air %.1f agl %.1f stalled %s person %s pilot_target %s prey %s d %.1f prey_v %.1f prey_state %s seen %s" % [t[0],
				tl.get("mode", ""), m.player.global_position.snappedf(0.1), pv.snappedf(0.1), float(tl.get("airspeed", 0.0)),
				float(tl.get("altitude_agl", 0.0)), tl.get("stalled", false), person.mode, person.pilot.target,
				pq.species if pq else "-", pq.get_body_position().distance_to(m.player.get_body_position()) if pq else -1.0,
				pq.velocity.length() if pq else -1.0, (pq as NpcBird).state_name() if pq is NpcBird else "-",
				person.call(&"_sees", m.player.get_body_position(), pq.get_body_position()) if pq else false])
		if t[0] >= next_row:
			next_row += 60.0
			var st: Dictionary = m.game_loop.get_run_stats()
			var pp := m.player.global_position
			var tel: Dictionary = m.player.telemetry()
			rows.append([snappedf(t[0], 1.0), String(st["species"]), snappedf(float(st["mass"]) * 1000.0, 0.1), int(st["lives"]),
				int(st["catches"]), String(person.mode), [snappedf(pp.x, 0.1), snappedf(pp.y, 0.1), snappedf(pp.z, 0.1)],
				m.ecosystem.count(), String(tel.get("mode", "")), snappedf(float(tel.get("airspeed", 0.0)), 0.1),
				snappedf(float(tel.get("altitude_agl", 0.0)), 0.1)])
			print("[integration] pacing %s t=%.0f %s %.0f g lives %d catches %d deaths %d mode %s" % [tag, t[0], st["species"],
				float(st["mass"]) * 1000.0, int(st["lives"]), catches.size(), deaths.size(), person.mode])
	var st2: Dictionary = m.game_loop.get_run_stats()
	var eco_st: Dictionary = m.ecosystem.stats()
	var tracked := track.finish()
	var reason := "time"
	if victory[0] >= 0.0:
		reason = "victory"
	elif Game.state == Game.State.ENDED:
		reason = "lost"
	person.release()
	Events.target_changed.disconnect(on_target)
	Events.player_tier_changed.disconnect(on_tier)
	Events.bird_caught.disconnect(on_caught)
	Events.player_caught.disconnect(on_death)
	out.merge({"tier_at": tier_at, "ended_at": snappedf(t[0], 0.1), "end_reason": reason, "victory_at": snappedf(victory[0], 0.1),
		"apex_at": snappedf(apex[0], 0.1), "catches": catches, "deaths": deaths, "peak_species": String(SizeRules.SPECIES[int(st2.get("peak_tier", start_tier))]["id"]) if st2.has("peak_tier") else "",
		"final_species": String(st2["species"]), "lives": st2["lives"], "npc_catches": int(st2.get("npc_catches", 0)),
		"person": person.summary(), "chases": person.chase_log, "cue": cue, "rows": rows, "errors": kit.log.errors, "warnings": kit.log.warnings,
		"attacks": int(st2.get("attacks", 0)), "attacks_sent": int(st2.get("attacks_sent", 0)), "escapes": int(st2.get("escapes", 0)),
		"attack_times": attack_times, "danger_marks": marks, "first_hunt_t": snappedf(first_hunt[0], 0.1),
		"loop_us": {"catch": _pct(loop_catch_us, 0.5), "watch": _pct(loop_watch_us, 0.5), "catch_p95": _pct(loop_catch_us, 0.95),
			"watch_p95": _pct(loop_watch_us, 0.95), "birds": _pct(loop_birds, 0.5)},
		"npc_catches_seen": seen_npc, "cue_track": tracked[0], "target_cue": tracked[1], "moths": eco_st.get("moths", {}), "show_hunts": int(eco_st.get("show_hunts", 0)),
		"show_hunt_catches": int(eco_st.get("show_hunt_catches", 0)), "hunts_on_player": int(eco_st.get("hunts_on_player", 0)),
		"log": kit.log.summary(), "wall_s": snappedf((Time.get_ticks_msec() - t_wall0) / 1000.0, 0.1), "load_end": _load()})
	var dir := Paths.artifacts("integration/pacing/%s" % batch)
	var f := FileAccess.open(dir.path_join("part_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, " "))
		f.close()
	print("[integration] pacing %s DONE: %s at %.0f s, tiers %s, %d catches, %d deaths, person %s, %s, wall %.0f s" % [tag, reason, t[0],
		tier_at, catches.size(), deaths.size(), person.summary(), kit.log.summary(), out["wall_s"]])
	await kit.teardown()
	get_tree().quit()


## Attack onsets this close to the last one's end are the same attack.
const ATTACK_MERGE_S := 5.0

## An NPC catch counts as seen within this of the player's eye, inside its
## view along the flight (106 x 90 deg, as integration's sky tests judge it).
const SEEN_M := 40.0


static func _in_view(m: GameMain, p: Vector3, max_m: float) -> bool:
	var eye := m.player.get_body_position()
	var rel := p - eye
	var d := rel.length()
	if d > max_m or d < 1e-3:
		return false
	var v := m.player.velocity
	var f := Vector3(v.x, 0.0, v.z)
	if f.length() < 0.5:
		f = -m.player.global_basis.z
		f.y = 0.0
	f = f.normalized()
	var hz := Vector2(rel.dot(f), rel.dot(f.cross(Vector3.UP)))
	if hz.x <= 0.0:
		return false
	var yaw := absf(atan2(hz.y, hz.x))
	var pitch := absf(atan2(rel.y + 0.087 * d, Vector2(hz.x, hz.y).length()))
	return yaw <= deg_to_rad(53.0) and pitch <= deg_to_rad(45.0)


static func _pct(xs: Array[float], q: float) -> float:
	if xs.is_empty():
		return -1.0
	var s := xs.duplicate()
	s.sort()
	return snappedf(s[clampi(int(q * (s.size() - 1)), 0, s.size() - 1)], 0.1)


static func _load() -> float:
	var o := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], o)
	if o.is_empty():
		return -1.0
	var parts := String(o[0]).replace("{", "").replace("}", "").strip_edges().split(" ", false)
	return float(parts[0]) if parts.size() > 0 else -1.0
