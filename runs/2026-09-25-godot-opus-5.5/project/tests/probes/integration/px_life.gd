extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## The real main.tscn, nothing staged: is the sky alive, and can a player who
## follows the game's own target cue catch real (fleeing) NPCs without any
## test help (no staged prey, no pinned assist, no released references)?
##
##   tools/gd.sh pxv_life --headless --fixed-fps 72 res://tests/probes/integration/px_life.tscn -- --fresh-settings [--cruise_s=180] [--chase_s=360] [--seed=21] [--tag=a]
##
## Writes artifacts/integration/verify/px_life_<tag>.json.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var out := {}
var npc_catches: Array = []
var player_catches: Array = []
var player_deaths: Array = []
var target_changes := 0
var threat_events := 0
var threat_max := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return d


func _on_caught(pred: Bird, prey: Bird) -> void:
	var rec := {"t": snappedf(Game.run_time, 0.1), "pred": String(pred.species) if pred else "?",
		"prey": String(prey.species) if prey else "?", "pred_player": pred != null and pred.is_player(),
		"prey_player": prey != null and prey.is_player()}
	if kit and kit.main and kit.main.player and is_instance_valid(kit.main.player) and prey:
		rec["dist_to_player"] = snappedf(prey.global_position.distance_to(kit.main.player.global_position), 0.1)
	if rec["pred_player"]:
		player_catches.append(rec)
	elif rec["prey_player"]:
		player_deaths.append(rec)
	else:
		npc_catches.append(rec)


func _on_target(_a: Variant = null, _b: Variant = null) -> void:
	target_changes += 1


func _on_threat(level: float, _pred: Variant = null) -> void:
	threat_events += 1
	threat_max = maxf(threat_max, level)


func _sample(t: float) -> Dictionary:
	var eco := kit.main.ecosystem
	var p := kit.main.player
	var pp := p.get_body_position()
	var by_state := {}
	var near := [0, 0, 0]
	var nearest := INF
	var in_front := 0
	var flock_sizes := []
	var fwd := -p.camera.global_basis.z
	for n in eco.get_npcs():
		if not is_instance_valid(n) or not n.alive:
			continue
		var s := n.state_name()
		if n.hidden:
			s = "hidden"
		by_state[s] = int(by_state.get(s, 0)) + 1
		var d := n.global_position.distance_to(pp)
		nearest = minf(nearest, d)
		if d < 30.0:
			near[0] += 1
		if d < 60.0:
			near[1] += 1
		if d < 120.0:
			near[2] += 1
		if d < 150.0 and fwd.angle_to(n.global_position - p.camera.global_position) < deg_to_rad(45.0):
			in_front += 1
	for f in eco.get_flocks():
		flock_sizes.append(f.size())
	var st := kit.stats()
	var tgt: Bird = st["target"]
	var thr: Bird = st["threat"]
	var tel := p.telemetry()
	return {"t": snappedf(t, 0.1), "npcs": eco.count(), "by_state": by_state, "near30_60_120": near,
		"nearest": snappedf(nearest, 0.1), "in_front_150m_45deg": in_front, "flocks": flock_sizes,
		"target": String(tgt.species) if tgt != null and is_instance_valid(tgt) else "",
		"target_d": snappedf(tgt.global_position.distance_to(pp), 0.1) if tgt != null and is_instance_valid(tgt) else -1.0,
		"threat": String(thr.species) if thr != null and is_instance_valid(thr) else "",
		"threat_level": snappedf(float(st["threat_level"]), 0.01),
		"species": String(st["species"]), "mass": snappedf(float(st["mass"]), 0.1), "lives": st["lives"],
		"assist": snappedf(float(st["catch_assist"]), 0.01), "alt_agl": snappedf(float(tel["altitude_agl"]), 0.1),
		"airspeed": snappedf(float(tel["airspeed"]), 0.1), "mode": tel["mode"], "state": Game.state_name()}


func _run() -> void:
	var cruise_s := float(_arg("cruise_s", "180"))
	var chase_s := float(_arg("chase_s", "360"))
	var tag := _arg("tag", "a")
	var seed_v := int(_arg("seed", "21"))
	kit = Kit.new()
	var ok := await kit.boot(self, true)
	out["booted"] = ok
	if not ok:
		_finish(tag)
		return
	out["load"] = kit.main.load_report.duplicate(true)
	Events.bird_caught.connect(_on_caught)
	Events.target_changed.connect(_on_target)
	Events.threat_changed.connect(_on_threat)
	kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	out["playing"] = Game.state == Game.State.PLAYING
	kit.fly_bot(seed_v)
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 110.0
	var samples := []
	var t := 0.0
	# Phase A: cruise an orbit, just watch the sky.
	var eco0: Dictionary = kit.main.ecosystem.stats()
	while t < cruise_s:
		await kit.advance(1.0)
		t += 1.0
		if int(t) % 2 == 0:
			samples.append(_sample(t))
	out["eco_after_cruise"] = _eco_digest(kit.main.ecosystem.stats(), eco0)
	# Phase B: follow the game's own target cue, as a player who trusts the HUD.
	var chases := 0
	var chase_log := []
	var cur: NpcBird = null
	var cur_t0 := 0.0
	var cur_d0 := 0.0
	var cur_min := INF
	var catches0 := int(kit.stats()["catches"])
	var tb := 0.0
	var eco1: Dictionary = kit.main.ecosystem.stats()
	while tb < chase_s:
		await kit.advance(0.25)
		tb += 0.25
		t += 0.25
		if Game.state != Game.State.PLAYING:
			if cur != null:
				chase_log.append({"prey": "?", "end": "player_not_playing", "dur": snappedf(tb - cur_t0, 0.1)})
				cur = null
			kit.cruise()
			if Game.state == Game.State.ENDED:
				out["run_ended_at"] = t
				break
			continue
		var st := kit.stats()
		var tgt: Bird = st["target"]
		if cur != null:
			var alive := is_instance_valid(cur) and cur.alive
			if alive:
				cur_min = minf(cur_min, cur.get_body_position().distance_to(kit.main.player.get_body_position()))
			var end := ""
			if not alive:
				end = "caught_by_player" if int(kit.stats()["catches"]) > catches0 + _caught_count(chase_log) else "gone"
			elif cur.hidden:
				end = "hid"
			elif tgt != cur and tb - cur_t0 > 1.0:
				end = "cue_moved_on"
			elif tb - cur_t0 > 25.0:
				end = "timeout"
			if not end.is_empty():
				chase_log.append({"prey": String(cur.species) if is_instance_valid(cur) else "?", "end": end,
					"dur": snappedf(tb - cur_t0, 0.1), "d0": snappedf(cur_d0, 0.1), "closest": snappedf(cur_min, 0.2),
					"player": String(st["species"])})
				cur = null
				kit.cruise()
		if cur == null and tgt != null and is_instance_valid(tgt) and tgt is NpcBird:
			cur = tgt as NpcBird
			cur_t0 = tb
			cur_d0 = cur.get_body_position().distance_to(kit.main.player.get_body_position())
			cur_min = cur_d0
			chases += 1
			kit.chase_bird(cur)
		if int(tb * 4) % 8 == 0:
			samples.append(_sample(t))
	out["eco_after_chase"] = _eco_digest(kit.main.ecosystem.stats(), eco1)
	out["chases"] = chases
	out["chase_log"] = chase_log
	out["run_stats_end"] = _clean(kit.stats())
	out["samples"] = samples
	_finish(tag)


func _caught_count(log: Array) -> int:
	var n := 0
	for c: Dictionary in log:
		if c["end"] == "caught_by_player":
			n += 1
	return n


func _eco_digest(s: Dictionary, s0: Dictionary) -> Dictionary:
	return {"npcs": s["npcs"], "target": s["target"], "by_species": s["by_species"], "by_state": s["by_state"],
		"flocks": s["flocks"], "catches_total": s["catches"], "catches_since": int(s["catches"]) - int(s0.get("catches", 0)),
		"catches_by_species": s["catches_by_species"], "caught_by_species": s["caught_by_species"],
		"entered": s["entered"], "hunts_on_player": s["hunts_on_player"], "despawned": s["despawned"],
		"spawned": s["spawned"], "behaviour": s.get("behaviour", {}), "plan": s.get("plan", {})}


func _clean(d: Dictionary) -> Dictionary:
	var o := {}
	for k in d:
		var v: Variant = d[k]
		if v is Object:
			o[k] = String((v as Bird).species) if is_instance_valid(v) and v is Bird else null
		else:
			o[k] = v
	return o


func _finish(tag: String) -> void:
	out["npc_catches"] = npc_catches
	out["player_catches"] = player_catches
	out["player_deaths"] = player_deaths
	out["target_changes"] = target_changes
	out["threat_events"] = threat_events
	out["threat_max"] = threat_max
	if kit and kit.log:
		out["errors"] = kit.log.errors
		out["warnings"] = kit.log.warnings
		out["log_samples"] = kit.log.samples
	var path := Paths.artifacts("integration").path_join("verify/px_life_%s.json" % tag)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_life %s: npc catches %d, player catches %d, deaths %d, chases %s, errors %s" % [
		tag, npc_catches.size(), player_catches.size(), player_deaths.size(), out.get("chases", -1), out.get("errors", -1)])
	if kit:
		await kit.teardown()
	get_tree().quit()
