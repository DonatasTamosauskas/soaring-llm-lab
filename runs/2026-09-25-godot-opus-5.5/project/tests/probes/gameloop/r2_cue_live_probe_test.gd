extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 2 probe (experience): are the danger and target cues true,
## early and steady in a LIVE sky - the AI's real Ecosystem in the shipped
## valley (or the AI's test world with --r2_sky=ai) - with modelled players?
## G6 asks for threat by time-to-contact, stable (no flicker); the brief asks
## for "being eaten happens but is avoidable", which in VR means: no death
## without a warning a person can act on.
##
##   GD_TIMEOUT=3000 tools/gd.sh gl_r2cue --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r2_cue_live \
##       [--r2_seeds=100,101,102] [--r2_skill=novice] [--r2_minutes=15] [--r2_sky=ai]
##
## Measures, from Events only (threat_changed, target_changed, player_caught):
##  * every death: the cue's level 1.0 s and 0.5 s before the catch, and
##    whether it named the bird that caught the player;
##  * false alarms: time with level >= 0.3 while no NPC is hunting the player;
##  * target churn: switches between two different live targets < 1 s apart.

const ValleySky := preload("res://tests/probes/gameloop/r2_valley_sky.gd")
const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const FixedSim := preload("res://tests/probes/gameloop/r2_integrated_sim_fixed.gd")

var sim
var _hist: Array = []  # [clock, level, predator, hunted]
var _deaths: Array = []
var _targets: Array = []  # [clock, target]
var _alarm := {"t_high": 0.0, "t_high_unhunted": 0.0}
var _last_t := -1.0
var _last_level := 0.0
var _last_hunted := false


func _clock() -> float:
	return sim.loop._clock if sim and sim.loop else 0.0


func _hunted() -> bool:
	var p := Birds.player()
	if p == null:
		return false
	for b in Birds.all():
		if b != p and b.alive and b.get(&"target") == p and SizeRules.can_eat(b.mass, p.mass):
			return true
	return false


func _level_at(t: float) -> Array:
	var lv := 0.0
	var pr: Variant = null
	for h: Array in _hist:
		if h[0] > t:
			break
		lv = h[1]
		pr = h[2]
	return [lv, pr]


func _r2_on_threat(level: float, pred: Bird) -> void:
	var now := _clock()
	if _last_t >= 0.0 and _last_level >= 0.3:
		_alarm["t_high"] += now - _last_t
		if not _last_hunted:
			_alarm["t_high_unhunted"] += now - _last_t
	_last_t = now
	_last_level = level
	_last_hunted = _hunted()
	_hist.append([now, level, pred])


func _r2_on_caught(pred: Bird) -> void:
	var now := _clock()
	var a := _level_at(now - 1.0)
	var b := _level_at(now - 0.5)
	var c := _level_at(now - 0.1)
	_deaths.append({"t": snappedf(now, 0.1), "by": pred.species, "player": Birds.player().species if Birds.player() else &"",
		"level_1s": snappedf(a[0], 0.01), "level_0.5s": snappedf(b[0], 0.01), "level_0.1s": snappedf(c[0], 0.01),
		"named_catcher_0.5s": b[1] == pred})


func _r2_on_target(t: Bird) -> void:
	_targets.append([_clock(), t])


func test_cues_in_a_live_sky() -> void:
	var args := Paths.user_args()
	var seeds: Array[int] = []
	for s in String(args.get("r2_seeds", "100,101")).split(",", false):
		seeds.append(int(s))
	var minutes := float(args.get("r2_minutes", "12"))
	var skill := StringName(args.get("r2_skill", "novice"))
	var sky := String(args.get("r2_sky", "valley"))
	sim = FixedSim.new()
	sim.sky_factory = (func() -> Node: return LiveSky.new()) if sky == "ai" else (func() -> Node: return ValleySky.new())
	add_child(sim)
	await get_tree().process_frame
	Events.threat_changed.connect(_r2_on_threat)
	Events.player_caught.connect(_r2_on_caught)
	Events.target_changed.connect(_r2_on_target)
	var per_run := []
	var total_min := 0.0
	var all_deaths := []
	var churn := 0
	var switches := 0
	var high := 0.0
	var high_unhunted := 0.0
	var total_blinks := 0
	var total_drops := 0
	for s in seeds:
		_hist.clear()
		_deaths.clear()
		_targets.clear()
		_alarm = {"t_high": 0.0, "t_high_unhunted": 0.0}
		_last_t = -1.0
		_last_level = 0.0
		var r: Dictionary = await sim.run(skill, s, minutes * 60.0)
		var mins := float(r["ended_at"]) / 60.0
		total_min += mins
		# Target churn: a switch from one live target straight to another,
		# less than 1 s after the previous switch.
		var last_switch := -10.0
		var prev: Variant = null
		var run_churn := 0
		var run_switches := 0
		for e: Array in _targets:
			if e[1] != null and prev != null and e[1] != prev:
				run_switches += 1
				if e[0] - last_switch < 1.0:
					run_churn += 1
				last_switch = e[0]
			elif e[1] != null and prev == null:
				last_switch = e[0]
			prev = e[1]
		churn += run_churn
		switches += run_switches
		# Blinks: the cue drops a live bird and names the SAME bird again
		# within 1 s (a flicker a player sees as the marker blinking).
		var blinks := 0
		var drops := 0
		var last_t := {}  # instance id -> time it was dropped
		var cur: Variant = null
		for e: Array in _targets:
			if cur != null and is_instance_valid(cur) and e[1] != cur:
				last_t[(cur as Object).get_instance_id()] = e[0]
				drops += 1
			if e[1] != null and is_instance_valid(e[1]):
				var id: int = (e[1] as Object).get_instance_id()
				if last_t.has(id) and e[0] - float(last_t[id]) < 1.0:
					blinks += 1
			cur = e[1]
		total_blinks += blinks
		total_drops += drops
		high += _alarm["t_high"]
		high_unhunted += _alarm["t_high_unhunted"]
		all_deaths.append_array(_deaths)
		per_run.append({"seed": s, "minutes": snappedf(mins, 0.1), "deaths": _deaths.duplicate(true),
			"target_events": _targets.size(), "target_switches": run_switches, "fast_switches": run_churn,
			"target_blinks": blinks, "target_drops": drops, "catches": r["catches"],
			"threat_events": _hist.size(), "alarm_s": snappedf(_alarm["t_high"], 0.1),
			"alarm_unhunted_s": snappedf(_alarm["t_high_unhunted"], 0.1), "attacks": r["attacks"], "escapes": r["escapes"]})
		print("[gameloop-verify] cue %s %s seed %d: %s" % [sky, skill, s, JSON.stringify(per_run[-1])])
	Events.threat_changed.disconnect(_r2_on_threat)
	Events.player_caught.disconnect(_r2_on_caught)
	Events.target_changed.disconnect(_r2_on_target)
	var warned := 0
	for d: Dictionary in all_deaths:
		if float(d["level_0.5s"]) >= 0.3:
			warned += 1
	var summary := {"sky": sky, "skill": skill, "minutes": total_min, "deaths": all_deaths.size(),
		"deaths_warned_0.5s_before_at_0.3": warned, "alarm_s": snappedf(high, 0.1),
		"alarm_unhunted_share": snappedf(high_unhunted / maxf(high, 1e-6), 0.01),
		"target_switches": switches, "fast_target_switches": churn,
		"target_switches_per_min": snappedf(switches / maxf(total_min, 1e-6), 0.01),
		"target_blinks": total_blinks, "target_drops": total_drops,
		"target_blinks_per_min": snappedf(total_blinks / maxf(total_min, 1e-6), 0.01)}
	metric("cue_summary", summary)
	metric("cue_runs", per_run)
	print("[gameloop-verify] cue summary: ", JSON.stringify(summary))
	var f := FileAccess.open(Paths.artifacts("gameloop/verify").path_join("r2_cue_%s_%s.json" % [sky, skill]), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"summary": summary, "runs": per_run}, "  "))
		f.close()
	if all_deaths.size() > 0:
		gt(float(warned) / all_deaths.size(), 0.79, "at least 80% of deaths had the danger cue at >= 0.3 half a second before")
	lt(float(churn), maxf(1.0, switches * 0.1), "under 10% of target switches come < 1 s after the last one")
	lt(float(total_blinks), maxf(1.0, total_drops * 0.1), "under 10% of target drops are the same bird named again within 1 s (blinking)")
	sim.queue_free()
	await get_tree().process_frame
