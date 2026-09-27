extends TestCase
## Diagnostic (not in the unit suite): why the threat cue's named predator
## changes in whole runs, by cause (ThreatWatch.last_change), with the level
## before and after and whether each bird was hunting the player.
##   tools/gd.sh gl_diag --headless res://tests/runner.tscn -- --dir=res://tests/shots \
##       --suite=gameloop_cue_diag --diag_sky=valley --diag_seeds=990,991 --diag_minutes=10

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


func test_cue_changes_by_cause() -> void:
	var args := Paths.user_args()
	var sky := String(args.get("diag_sky", "mirror"))
	var minutes := float(args.get("diag_minutes", "10"))
	var seeds: Array[int] = []
	for s in String(args.get("diag_seeds", "990")).split(","):
		seeds.append(int(s))
	var sim := IntegratedSim.new()
	if sky == "valley":
		sim.sky_factory = func() -> Node:
			var k: Node = LiveSky.new()
			k.set(&"world_kind", &"valley")
			return k
	add_child(sim)
	await get_tree().process_frame
	var by := {}
	var st := {"lv": 0.0, "id": 0, "prev": 0, "at": -INF, "hop": false}
	var on_threat := func(level: float, pred: Bird) -> void:
		var nid := pred.get_instance_id() if pred != null else 0
		var t := sim.loop.stats.run_time
		if int(st["id"]) != 0 and nid != 0 and nid != int(st["id"]):
			var hop := float(st["lv"]) >= IntegratedSim.CUE_VISIBLE and level >= IntegratedSim.CUE_VISIBLE
			if hop and nid == int(st["prev"]) and bool(st["hop"]) and t - float(st["at"]) < IntegratedSim.CUE_PING_PONG_S:
				var o := instance_from_id(int(st["id"])) as Bird
				print("[gameloop]   PING-PONG t=%.1f back to %s (hunting %s, own %.2f raw %.2f) from %s (hunting %s, own %.2f raw %.2f) via %s after %.2f s" % [
					t, pred.species, IntegratedSim.hunts(pred, sim.player), sim.loop.watch.level_of(pred), sim.loop.watch.raw_of(pred),
					o.species if o else "?", IntegratedSim.hunts(o, sim.player) if o else false,
					sim.loop.watch.level_of(o) if o else -1.0, sim.loop.watch.raw_of(o) if o else -1.0,
					sim.loop.watch.last_change, t - float(st["at"])])
			st["prev"] = int(st["id"])
			st["at"] = t
			st["hop"] = hop
			var old := instance_from_id(int(st["id"])) as Bird
			var key := "%s %s%s->%s lv %s->%s" % [sim.loop.watch.last_change,
				"h" if old != null and IntegratedSim.hunts(old, sim.player) else "-",
				"" if old != null and old.alive else "(dead)",
				"h" if IntegratedSim.hunts(pred, sim.player) else "-",
				_band(float(st["lv"])), _band(level)]
			by[key] = int(by.get(key, 0)) + 1
		st["id"] = nid
		st["lv"] = level
	Events.threat_changed.connect(on_threat)
	var cue_total := {}
	var played := 0.0
	for s in seeds:
		var r: Dictionary = await sim.run(&"competent", s, minutes * 60.0)
		played += float(r["ended_at"])
		for k: String in r["cue"]:
			cue_total[k] = float(cue_total.get(k, 0.0)) + float(r["cue"][k])
	Events.threat_changed.disconnect(on_threat)
	var keys := by.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return int(by[a]) > int(by[b]))
	print("[gameloop] cue diag %s, %.1f min played: %s" % [sky, played / 60.0, cue_total])
	for k: String in keys:
		print("[gameloop]   %4d  %s" % [by[k], k])
	check(played > 0.0, "played")
	sim.queue_free()
	await get_tree().process_frame


static func _band(x: float) -> String:
	if x >= GameLoop.ATTACK_LEVEL:
		return "ATTACK"
	if x >= IntegratedSim.CUE_VISIBLE:
		return "vis"
	return "low"
