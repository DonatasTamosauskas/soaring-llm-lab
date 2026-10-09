extends "res://tests/unit/ai/ai_sim.gd"
## A1 Aliveness (+ A5 safety, + A4 in the wild): a 10-minute headless sim of
## 60 NPCs and no player in the AI test world, with the stand-in catch rule.
##  * steady NPC-vs-NPC catches (every 2-minute window) by >= 4 predator
##    species;
##  * counted behaviours: flocking, perching, thermalling, hunting, fleeing,
##    stooping (plus jinks, refuges, give-ups);
##  * safety every tick: no NaN, never below ground, never inside geometry,
##    never out of bounds, never stuck;
##  * flight envelopes measured in free flight stay within 10% of
##    SizeRules.performance;
##  * population stays at 60 (caught birds are replaced out of sight).
##  * the engine logs no warnings or errors meanwhile (no spam).
## Evidence: artifacts/ai/soak_*.png (top-down tracks, per-species small
## multiples, side view) and soak_report.json from the 10-minute run.
##
## The suite runs 180 simulated seconds (the suite must stay quick); the A1
## evidence run is the full ten minutes (--soak_s=600, or --ai_full=1):
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --suite=unit/ai/soak --soak_s=600
## Outputs of shorter runs are named soak_<seconds>s_* so they never
## overwrite the evidence. --soak_seed=<n> picks another seed (default 7).

const EcoPlot := preload("res://tests/unit/ai/eco_plot.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WarningLog := preload("res://tests/unit/ai/warning_log.gd")


func test_soak_alive_and_safe() -> void:
	var soak_s := float(Paths.arg("soak_s", "600" if full() else "180"))
	var tag := "soak" if soak_s >= 600.0 else "soak_%ds" % int(soak_s)
	var log: Logger = WarningLog.install()
	await make_world(false, 1)
	var e := make_eco(60, int(Paths.arg("soak_seed", "7")))
	var chk := make_checker()
	# Contacts the body's safety net had to resolve (NpcBird.geo_hits etc.),
	# over every bird that lived in the soak, per bird-minute of free flight.
	var hits := {"geo": 0, "ground": 0, "bounds": 0, "free_s": 0.0}
	# Per species too, so a regression points at the birds that cause it.
	var by_sp := {}
	var tally := func(n: NpcBird) -> void:
		hits["geo"] += n.geo_hits
		hits["ground"] += n.ground_hits
		hits["bounds"] += n.bounds_hits
		var a: Array = by_sp.get(String(n.species), [0, 0, 0])
		by_sp[String(n.species)] = [a[0] + n.geo_hits, a[1] + n.ground_hits, a[2] + n.bounds_hits]
	e.npc_despawned.connect(func(n: NpcBird, _r: StringName) -> void: tally.call(n))
	# Every dive into cover from a known pursuer: into cover too small for it?
	var dives := {"known": 0, "followable": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what == &"refuge" and b.threat != null and is_instance_valid(b.threat):
				dives["known"] += 1
				if b.threat.get_wingspan() <= float(b.refuge.get("max_span", 0.0)):
					dives["followable"] += 1))
	var safety := Safety.new(world)
	var tracks := {}
	var side := {}
	var pop := {"min": 999, "max": 0}
	var windows := []
	var n_win := int(ceil(soak_s / 120.0))
	for i in n_win:
		windows.append(0)
	var t0 := Time.get_ticks_msec()
	var dbg_gr := {}
	var steps := int(round(soak_s / DT))
	for i in steps:
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if OS.get_environment("AI_DEBUG") != "":
			for n in e.get_npcs():
				var gid := n.get_instance_id()
				if n.ground_hits > int(dbg_gr.get(gid, 0)):
					print("[ai] ground t=%.2f %s %s%s agl=%.2f spd=%.1f gamma=%.2f eff=%.2f v=%s want=%s pos=%s tgt=%s" % [i * DT, n.species, n.state_name(), "/flare" if n.is_flaring() else "", n.agl(), n.flight.speed, n.flight.gamma, n.flight.effort, n.velocity.snapped(Vector3.ONE * 0.1), n.want_dir.snapped(Vector3.ONE * 0.01), n.global_position.snapped(Vector3.ONE * 0.1), n.target.species if n.target is NpcBird else str(n.target)])
				dbg_gr[gid] = n.ground_hits
		if i > 72:
			pop["min"] = mini(pop["min"], e.count())
			pop["max"] = maxi(pop["max"], e.count())
		if i % 36 == 0:
			for n in e.get_npcs():
				if not (n.perched or n.hidden):
					hits["free_s"] += 36 * DT
				var id := n.get_instance_id()
				if not tracks.has(id):
					tracks[id] = {"species": n.species, "pts": PackedVector3Array()}
				tracks[id]["pts"].append(n.global_position)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	log.uninstall()
	for n in e.get_npcs():
		tally.call(n)
	var bird_min := maxf(float(hits["free_s"]) / 60.0, 1.0)
	var contact_rates := {"geo_per_bird_min": float(hits["geo"]) / bird_min, "ground_per_bird_min": float(hits["ground"]) / bird_min,
		"bounds_per_bird_min": float(hits["bounds"]) / bird_min, "free_flight_bird_min": bird_min,
		"by_species_geo_ground_bounds": by_sp}
	for c in chk.catches:
		windows[mini(int(c["t"] / 120.0), n_win - 1)] += 1
	var st := e.stats()
	var beh: Dictionary = st["behaviour"]
	var by_pred: Dictionary = chk.count_by_predator()
	var flock_share := float(st["flock_time"]) / (soak_s * 60.0)
	# --- A1 ---
	# Behaviour floors are about half the lowest count measured on the final
	# code over eleven seeds (180 s each: perches 74-108, thermals 11-27,
	# hunts 35-53, flees 50-93, stoops 6-12, jinks 12-27, refuge dives 1-16,
	# catches 7-17 by 5-6 species), scaled to the soak's length: a
	# regression that halves a behaviour fails here (no fatigue - energy
	# never draining - leaves ~7 perch landings in 180 s). Refuge dives are
	# rare in this arena (31 refuges, most chases in open air) and fewer
	# than before fix round 2, when prey fled any hunter in sight; they are
	# pinned where there is cover: flee_test (hedge and barn) and the valley
	# soak in realworld_test (~40 dives every 2 minutes).
	var per := soak_s / 180.0
	gt(chk.catches.size(), soak_s / 30.0, "NPC-vs-NPC catches (>= 1 per 30 s)")
	for w in windows.size():
		gt(windows[w], 0, "catches in 2-minute window %d" % w)
	gt(by_pred.size(), 3, "predator species that caught something (>= 4)")
	gt(flock_share, 0.2, "share of bird-time spent flocking")
	gt(beh.get("perch", 0), 40.0 * per, "perch landings")
	gt(beh.get("thermal", 0), 6.0 * per, "thermals entered and circled")
	gt(beh.get("hunt", 0), 22.0 * per, "hunts started")
	gt(beh.get("flee", 0), 40.0 * per, "flights from predators")
	gt(beh.get("stoop", 0), 2.0 * per, "stoops")
	gt(beh.get("jink", 0), 7.0 * per, "evasive jinks")
	# Dives into cover: only into cover too small for the pursuer (the brief).
	# Their number is not floored here: round 3 made refuges obey that rule,
	# and the arena's cover (hedges 0.3 m, nest boxes 0.2 m, barn and sheds
	# 0.75 m) rarely suits the flights that happen in it - starlings and
	# pigeons from crows and gulls, far from the barn; moths from wrens, for
	# which there is no cover a wren cannot enter (0 dives in 180 s of seed 7,
	# where round 2 had ~7). Cover use is pinned where there is cover:
	# flee_test (hedges, the barn), and in the valley realworld_test's soak
	# and hunting-player runs.
	eq(dives["followable"], 0, "dives into cover the pursuer could follow into (of %d from a known pursuer)" % dives["known"])
	# The safety net is a net, not the way birds keep off things: contacts
	# it had to resolve per bird-minute of free flight (six seeds: geometry
	# 0.03-0.10, ground 0-0.02, bounds 0; ~2.5 geometry contacts with the
	# obstacle feelers removed).
	lt(contact_rates["geo_per_bird_min"], 0.3, "geometry contacts per bird-minute (avoidance working)")
	lt(contact_rates["ground_per_bird_min"], 0.05, "ground contacts per bird-minute (clearance working)")
	lt(contact_rates["bounds_per_bird_min"], 0.02, "bounds contacts per bird-minute (bounds steering working)")
	eq(log.warnings + log.errors, 0, "no engine warnings or errors during the soak %s" % str(log.samples))
	# --- population ---
	lt(pop["max"], e.max_npcs + 1, "never above the cap")
	gt(pop["min"], e.max_npcs - e.tolerance - 1, "never below target - tolerance")
	# --- A5 ---
	for k in safety.counts:
		eq(safety.counts[k], 0, "safety: %s" % k)
	if safety.total() > 0:
		print("[ai] safety examples: ", safety.examples)
	# --- A4 in the wild ---
	# Bodies move with their flight model (A4 is measured on the physics): a
	# systematic mismatch - a body moving 1.3x its model - puts every segment
	# 30% off; a stray one in a hundred thousand is a clamp or a lunge edge.
	var segs := maxf(safety.motion_segments, 1)
	gt(safety.motion_segments, 1000, "free-flight segments measured")
	lt(safety.motion_sum / segs, 0.02, "measured vs reported speed: mean mismatch (%d segments)" % safety.motion_segments)
	lt(float(safety.motion_bad) / segs, 0.002, "measured vs reported speed: share of segments off by > 10%")
	for sp in safety.envelope:
		var env: Dictionary = safety.envelope[sp]
		lt(env["turn"], 1.1, "%s turn rate near cruise within 10%% of SizeRules" % sp)
		lt(env["climb"], 1.1, "%s sustained climb within 10%% of SizeRules" % sp)
		lt(env["speed"], 1.0 + 1e-3, "%s never faster than max_speed" % sp)
	var report := {
		"sim_s": soak_s, "wall_s": wall, "catches": chk.catches.size(), "catch_windows_2min": windows,
		"catches_by_predator": by_pred, "flock_share": flock_share, "behaviour": beh,
		"entered": st["entered"], "population": pop, "safety": safety.counts,
		"safety_bird_ticks": safety.bird_ticks, "envelope_ratio_max": safety.envelope,
		"motion_mismatch_max": safety.motion_mismatch, "motion_segments": safety.motion_segments,
		"motion_mismatch_mean": safety.motion_sum / maxf(safety.motion_segments, 1), "motion_off_10pct": safety.motion_bad,
		"despawned": st["despawned"], "spawned": st["spawned"], "tick_ms_avg": st["tick_ms_avg"],
		"tick_parts_ms": st["tick_parts_ms"], "contacts": contact_rates,
	}
	report["engine_warnings"] = log.warnings
	report["engine_errors"] = log.errors
	metric("soak", report)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("%s_report.json" % tag), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("[ai] soak %.0f s sim in %.1f s wall: %d catches %s, behaviour %s, safety %s" % [soak_s, wall, chk.catches.size(), by_pred, beh, safety.counts])
	_plots(tracks, chk.catches, soak_s, by_pred, beh, tag)
	await clear_sim()


func _plots(tracks: Dictionary, catches: Array, soak_s: float, by_pred: Dictionary, beh: Dictionary, tag: String) -> void:
	var half := world.bounds_radius + 10.0
	# Overview.
	var pl := EcoPlot.map(world, 1400, Vector2.ZERO, half)
	EcoPlot.draw_tracks(pl, tracks, 0.35)
	EcoPlot.draw_catches(pl, catches)
	pl.text(Vector2(14, 12), "AI SOAK - 60 NPCS, NO PLAYER, %.0f S  (TOP VIEW, %.0f M ACROSS)" % [soak_s, half * 2.0], EcoPlot.INK, 2)
	EcoPlot.legend(pl, Vector2(14, 1400 - 190), [
		"CATCHES %d  BY %s" % [catches.size(), str(by_pred).replace("\"", "")],
		"HUNTS %d  STOOPS %d  FLEES %d  PERCHES %d  THERMALS %d" % [beh.get("hunt", 0), beh.get("stoop", 0), beh.get("flee", 0), beh.get("perch", 0), beh.get("thermal", 0)],
	])
	pl.save(Paths.artifacts("ai").path_join("%s_topdown.png" % tag))
	# Small multiples: one panel per species.
	var cols := 5
	var cell := 420
	var grid := EcoPlot.Plot.new(cols * cell, 2 * cell, EcoPlot.SURFACE)
	for i in SizeRules.SPECIES.size():
		var sp: StringName = SizeRules.SPECIES[i]["id"]
		var panel := EcoPlot.map(world, cell, Vector2.ZERO, half)
		var only := {}
		for k in tracks:
			if tracks[k]["species"] == sp:
				only[k] = tracks[k]
		EcoPlot.draw_tracks(panel, only, 0.6)
		var mine := []
		for c in catches:
			if c["pred_species"] == sp:
				mine.append(c)
		EcoPlot.draw_catches(panel, mine)
		panel.text(Vector2(8, 8), "%s  CAUGHT %d" % [String(sp).to_upper(), mine.size()], EcoPlot.INK, 2)
		grid.img.blit_rect(panel.img, Rect2i(0, 0, cell, cell), Vector2i((i % cols) * cell, (i / cols) * cell))
	grid.save(Paths.artifacts("ai").path_join("%s_species.png" % tag))
	# Side view (x, altitude) of raptors and gulls: soaring climbs and stoops.
	var sv := EcoPlot.Plot.new(1400, 500, EcoPlot.SURFACE, Vector2(-half, -world.ceiling), Vector2(half, 10.0))
	for k in tracks:
		var g := EcoPlot.group_of(tracks[k]["species"])
		var c: Color = EcoPlot.GROUP_COLORS[g]
		c.a = 0.5 if g == 2 else 0.15
		var pts := PackedVector2Array()
		for p: Vector3 in tracks[k]["pts"]:
			pts.append(sv.px(Vector2(p.x, -p.y)))
		sv.polyline(pts, c)
	sv.text(Vector2(14, 12), "SIDE VIEW (X, ALTITUDE): BIG BIRDS BOLD - THERMAL CLIMBS AND STOOPS", EcoPlot.INK, 2)
	sv.save(Paths.artifacts("ai").path_join("%s_side.png" % tag))
