extends TestCase
## The brief's pacing, danger and core loop through the real game - the
## evidence for the brief (core loop round; integration round 2 first
## measured it; the game loop's modelled valley evidence is retired: it
## disagreed 3-4x with this).
##
## Stored evidence, not a live run: tests/unit/integration/data/real_pacing.json,
## whole 30-minute runs of scenes/main.tscn played by the person of
## integration_person.gd (the game loop's own modelled player - SimPilot's
## cues, evasion and chase rules, at three skills - flying the real
## PlayerBird through BotPoseSource arms, the real WingInput and
## FlightModel), in the real sky at the full (60 NPCs) and the Quest (28)
## tier, nothing staged or pinned (tests/shots/integration_pacing.sh; the
## merge: tests/shots/integration_pacing_merge.py).
##
## Honest seeds: the tuning looked at a declared set of tuning batches
## ("tuning": their batches and seeds); the evidence's runs are a HELD-OUT
## batch of fresh seeds, run once after the tuning was final. The file
## carries the log of every real-chain pacing run ever made ("seed_log": the
## batch script logs each run before it starts; every stored part file is
## added): no held-out seed may appear in any other batch.
##
## Pinned, on the held-out runs (the lead's direction for the core loop):
##  * pacing, per tier (competent): the median time to the pigeon within
##    5-8 minutes, to the eagle within 20-30 (a run that never got there
##    counts as later than every run that did); a novice's first tier-up
##    within ~3 minutes and still growing; an expert no slower than a
##    competent player;
##  * danger, per tier: caught at least once in >= 40% of the runs, fewer
##    than 20% lost; the first tier-up never punished within 30 s; the
##    first attack 60-150 s in and about one every one to two minutes in the
##    first ten minutes after it; the danger marks only on birds hunting the
##    player (or named, or within 3 s of hunting it) - never on the
##    murmuration; the threat cue's level always the named bird's own, an
##    attack never handed to a bystander or masked;
##  * the core loop's shape: early growth mostly from pellets (swarm moths);
##    the sky's own predation seen in view a few times a run;
##  * no errors in any run; the evidence played the tree's code and growth
##    tuning (warns; fails with -- --strict_evidence).

const Pacing := preload("res://tests/shots/integration_pacing.gd")
const EVIDENCE := "res://tests/unit/integration/data/real_pacing.json"
const PIGEON := 5
const EAGLE := 9
const BRIEF := {PIGEON: [300.0, 480.0], EAGLE: [1200.0, 1800.0]}
## Held-out runs per tier (the lead's evidence economy for the core loop
## round: "final real-chain evidence = 6 fresh held-out seeds per tier").
const MIN_RUNS := 6
const MIN_SKILL_RUNS := 4
## A novice's or an expert's run is judged on its first tier-up and its
## pigeon (the brief's 5-8 minutes): this long at least (min).
const SKILL_RUN_MIN := 12.0
const MIN_CAUGHT_SHARE := 0.4
const MAX_LOST_SHARE := 0.2
## A novice's first tier-up (the lead's direction: "within ~3 min").
const NOVICE_FIRST_TIER_S := 180.0
## The danger director: the sky picks the player once the first flight is
## over (60-90 s, 15 s after the first catch) - the first bird to set off
## after it (median) - and "about one telegraphed attack every 1-2 minutes at
## the start": attacks (a hunter at attack strength) a minute over the ten
## minutes from the first.
const FIRST_HUNT_S := [60.0, 150.0]
const EARLY_ATTACKS_PER_MIN := [0.5, 1.2]
## "Early growth comes mostly from them": of the catches a sparrow-sized
## player makes, the share that are pellets.
const EARLY_PELLET_SHARE := 0.5
## "Predation is witnessed a few times per session": NPC catches within 40 m
## in the player's view, median per 30-minute run.
const SEEN_NPC_CATCHES := 3.0
## The target ring through the real chain (core loop fix round 1: the same
## bars mechanics_test holds the modelled runs to; the held-out runs of the
## core loop round left a still-valid bird 4-13 times a minute): per tier,
## pooled over the held-out runs, changes a minute away from a still-valid
## bird, away from one the player was gaining on, and the median hold before
## such a change.
const RING_VOLUNTARY_PER_MIN := 3.0
const RING_CLOSING_PER_MIN := 0.5
const RING_HOLD_MEDIAN_S := 5.0

var ev := {}


func before_all() -> void:
	var txt := FileAccess.get_file_as_string(EVIDENCE)
	var d: Variant = JSON.parse_string(txt) if not txt.is_empty() else null
	ev = d if d is Dictionary else {}


func _row(key: String) -> Dictionary:
	return (ev.get("summary", {}) as Dictionary).get(key, {})


func test_evidence_is_current() -> void:
	if not check(not ev.is_empty(), "the real-chain pacing evidence exists (%s)" % EVIDENCE):
		return
	var runs: Array = ev.get("runs", [])
	for key in ["full", "quest"]:
		gt(float(_row(key).get("runs", 0)), MIN_RUNS - 0.5, "%s tier: at least %d held-out competent runs (%d)" % [key, MIN_RUNS, int(_row(key).get("runs", 0))])
	for key in ["full:novice", "full:expert"]:
		gt(float(_row(key).get("runs", 0)), MIN_SKILL_RUNS - 0.5, "%s: at least %d held-out runs" % [key, MIN_SKILL_RUNS])
	var codes := {}
	var short := []
	for r: Dictionary in runs:
		codes[String(r.get("code", ""))] = true
		# As long as its metric needs (the lead's evidence economy for the
		# core loop: "stop a run once eagle is reached or at 35 min"): a
		# competent run long enough to judge the eagle's 20-30 minutes, a
		# novice's or an expert's the pigeon's 5-8 and the first tier-up.
		var need := 30.0 if String(r.get("skill", "competent")) == "competent" else SKILL_RUN_MIN
		if float(r.get("minutes", 0.0)) < need - 1e-6:
			short.append("%s %s %s: %.0f min" % [r.get("tier"), r.get("skill"), r.get("seed"), float(r.get("minutes", 0.0))])
	eq(codes.size(), 1, "every run played the same code (%s)" % [codes.keys()])
	eq(short, [], "every competent run is 30 minutes or more, every novice or expert run %.0f or more" % SKILL_RUN_MIN)
	var here := Pacing.code_fingerprint()
	metric("evidence_code", codes.keys())
	metric("tree_code", here)
	if not codes.has(here):
		print("[integration] WARNING: the real-chain pacing evidence played code %s; the tree is %s - re-run tests/shots/integration_pacing.sh" % [codes.keys(), here])
		if Paths.arg("strict_evidence", "") != "":
			fail("the evidence played other code (%s, tree %s)" % [codes.keys(), here])
	var growth := {}
	for r: Dictionary in runs:
		growth[str(r.get("growth", []))] = true
		check(not r.has("start_mass"), "no run started at another size (seed %s)" % r.get("seed"))
	eq(growth.keys(), [str([SizeRules.GROWTH_GAIN, SizeRules.GROWTH_SIZE_EXP])], "the runs played the shipped growth tuning")


func test_the_held_out_seeds_were_never_tuned_on() -> void:
	# The held-out claim, as a check against the log of every real-chain run
	# ever made: no held-out seed was run in any batch but the held-out ones
	# (whatever the tier or skill), every held-out run is on the log (logged
	# as it started), and the tuning batches' seeds are on it too.
	var hold: Dictionary = ev.get("holdout", {})
	var tune: Dictionary = ev.get("tuning", {})
	var log: Array = ev.get("seed_log", [])
	check(not log.is_empty(), "(setup) the seed log is in the evidence")
	check(not (hold.get("batches", []) as Array).is_empty(), "(setup) the held-out batches are named")
	check(not (tune.get("batches", []) as Array).is_empty(), "(setup) the tuning batches are named")
	var hb := {}
	for b in hold.get("batches", []):
		hb[String(b)] = true
	var elsewhere := {}
	var in_hold := {}
	for row: Array in log:
		var batch := String(row[1])
		var key := "%s/%s/%d" % [batch, row[2], int(row[3])]
		if hb.has(batch):
			in_hold[key] = true
		else:
			elsewhere[int(row[3])] = true
	var reused: Array[int] = []
	for s in hold.get("seeds", []):
		if elsewhere.has(int(s)):
			reused.append(int(s))
	eq(reused, [] as Array[int], "no held-out seed was run in any other batch (the tuning log)")
	var unlogged: Array = []
	for r: Dictionary in ev.get("runs", []):
		var key := "%s/%s/%d" % [String(r.get("batch", "")), String(r.get("tier", "")), int(r.get("seed", -1))]
		if not in_hold.has(key):
			unlogged.append(key)
	eq(unlogged, [], "every held-out run is on the log")
	var tuned := {}
	for row: Array in log:
		if (tune.get("batches", []) as Array).has(String(row[1])):
			tuned[int(row[3])] = true
	var missing: Array = []
	for s in tune.get("seeds", []):
		if not tuned.has(int(s)):
			missing.append(int(s))
	eq(missing, [], "every tuning seed is on the log")
	metric("seeds", {"held_out": hold.get("seeds", []), "tuning": tune.get("seeds", []), "logged_runs": log.size()})


func test_competent_pacing_meets_the_brief_at_both_tiers() -> void:
	for tier: String in ["full", "quest"]:
		var row := _row(tier)
		if not check(not row.is_empty(), "%s tier in the evidence" % tier):
			continue
		for idx: int in [PIGEON, EAGLE]:
			var sp: String = String(SizeRules.SPECIES[idx]["id"])
			var st: Dictionary = row.get(sp, {})
			var med: Variant = st.get("median_s")
			var reached := int(st.get("reached", 0))
			var lo: float = BRIEF[idx][0]
			var hi: float = BRIEF[idx][1]
			metric("%s_%s" % [tier, sp], {"median_s": med, "reached": reached, "times_s": st.get("times_s", [])})
			if med == null:
				fail("%s tier: the median run never reached the %s (%d of %d runs did; the brief: %.0f-%.0f min)" % [
					tier, sp, reached, int(row.get("runs", 0)), lo / 60.0, hi / 60.0])
				continue
			between(float(med), lo, hi, "%s tier: median time to the %s %.1f min (%d of %d runs got there; the brief: %.0f-%.0f min)" % [
				tier, sp, float(med) / 60.0, reached, int(row.get("runs", 0)), lo / 60.0, hi / 60.0])


func test_novices_grow_and_experts_grow_faster() -> void:
	var nov := _row("full:novice")
	var com := _row("full")
	var exp := _row("full:expert")
	if not check(not nov.is_empty() and not exp.is_empty(), "(setup) novice and expert runs at the full tier"):
		return
	var first: Variant = nov.get("first_tier_up_median_s")
	check(first != null, "a novice's median run grows out of the sparrow")
	if first != null:
		lt(float(first), NOVICE_FIRST_TIER_S, "a novice's first tier-up (median) within 3 minutes (%.1f min)" % [float(first) / 60.0])
	var np: Variant = (nov.get("pigeon", {}) as Dictionary).get("median_s")
	var cp: Variant = (com.get("pigeon", {}) as Dictionary).get("median_s")
	var xp: Variant = (exp.get("pigeon", {}) as Dictionary).get("median_s")
	metric("pigeon_by_skill_s", {"novice": np, "competent": cp, "expert": xp})
	check(xp != null and cp != null and float(xp) <= float(cp), "an expert reaches the pigeon no later than a competent player (medians %s vs %s s)" % [xp, cp])
	check(np == null or cp == null or float(np) >= float(cp), "a novice no sooner than a competent player (medians %s vs %s s)" % [np, cp])
	gt(float(nov.get("catches_per_min", 0.0)), 0.0, "novices catch (%.2f a minute)" % float(nov.get("catches_per_min", 0.0)))


func test_being_eaten_happens_but_is_avoidable() -> void:
	for tier: String in ["full", "quest"]:
		var row := _row(tier)
		if not check(not row.is_empty(), "%s tier in the evidence" % tier):
			continue
		var n := maxf(float(row.get("runs", 0)), 1.0)
		gt(float(row.get("caught_at_least_once", 0)) / n, MIN_CAUGHT_SHARE - 1e-6, "%s tier: caught at least once in %d of %d runs" % [
			tier, int(row.get("caught_at_least_once", 0)), int(n)])
		lt(float(row.get("lost", 0)) / n, MAX_LOST_SHARE, "%s tier: %d of %d runs lost (all lives)" % [tier, int(row.get("lost", 0)), int(n)])
		eq(int(row.get("deaths_within_30s_of_first_tier_up", -1)), 0, "%s tier: the first tier-up is never punished within 30 s (%d first tier-ups)" % [
			tier, int(row.get("first_tier_ups", 0))])
		eq(int(row.get("errors", 0)), 0, "%s tier: no errors in any run" % tier)
		eq(int(row.get("tier_ups_within_30s", -1)), 0, "%s tier: never two tier-ups within 30 s (a feast never skips the ladder)" % tier)
		metric("danger_%s" % tier, {"deaths_median": row.get("deaths_median"), "deaths_mean": row.get("deaths_mean"),
			"killers": row.get("killers"), "evading_share": row.get("evading_share"), "attacks_per_run": row.get("attacks_per_run_median")})


func test_the_danger_comes_in_telegraphed_episodes() -> void:
	# The danger director (GameLoop._direct_danger): the first attack once the
	# first flight is over, then about one every one to two minutes; the
	# attacker named and shown from the moment it sets off (ThreatWatch's
	# warning), the level always its own, an attack never handed to a
	# bystander or masked behind another bird (CueTrack, as the modelled runs
	# record it).
	for tier: String in ["full", "quest"]:
		var row := _row(tier)
		if not check(not row.is_empty(), "%s tier in the evidence" % tier):
			continue
		var fh: Variant = row.get("first_hunt_median_s")
		check(fh != null, "%s tier: the sky hunts the player" % tier)
		if fh != null:
			between(float(fh), FIRST_HUNT_S[0], FIRST_HUNT_S[1], "%s tier: the first bird sets off after the player %.0f s into the run (median)" % [tier, float(fh)])
		check(row.get("first_attack_median_s") != null, "%s tier: attacks come (the first at %s s, median)" % [tier, row.get("first_attack_median_s")])
		between(float(row.get("attacks_per_min_first_10", 0.0)), EARLY_ATTACKS_PER_MIN[0], EARLY_ATTACKS_PER_MIN[1],
			"%s tier: about one attack every 1-2 minutes over the first ten (median %.2f a minute)" % [tier, float(row.get("attacks_per_min_first_10", 0.0))])
		var ct: Dictionary = row.get("cue_track", {})
		check(ct.has("not_own"), "(setup) %s tier: the runs record the cues (CueTrack)" % tier)
		eq(int(ct.get("not_own", -1)), 0, "%s tier: the level shown is always the named bird's own" % tier)
		eq(int(ct.get("attack_to_bystander", -1)), 0, "%s tier: an attack is never handed to a bird not hunting the player" % tier)
		eq(float(ct.get("masked_live_s", -1.0)), 0.0, "%s tier: a live attack on the player is never masked" % tier)
		metric("cues_%s" % tier, {"cue_track": ct, "target_cue": row.get("target_cue", {}), "cue_changes_per_min": row.get("cue_changes_per_min")})


func test_danger_marks_are_only_on_hunters() -> void:
	# The lead's direction: "danger marks only on birds actually hunting the
	# player (or named as the threat, or within 3 s of hunting it) - never on
	# the harmless murmuration or every bigger bird". Sampled at 4 Hz in every
	# run: every danger mark the player saw within its highlight range.
	for tier: String in ["full", "quest"]:
		var m: Dictionary = _row(tier).get("danger_marks", {})
		check(int(m.get("samples", 0)) > 1000, "(setup) %s tier: the marks were sampled (%d samples)" % [tier, int(m.get("samples", 0))])
		gt(float(m.get("marked", 0)), 0.0, "(setup) %s tier: danger marks were shown (%d)" % [tier, int(m.get("marked", 0))])
		eq(int(m.get("not_hunting", -1)), 0, "%s tier: never a danger mark on a bird not hunting the player, named or just after hunting it" % tier)
		eq(int(m.get("on_murmuration", -1)), 0, "%s tier: never on the murmuration" % tier)


func test_the_core_loop_has_its_shape() -> void:
	# Agar.io in the sky: early growth mostly from pellets (swarm moths), and
	# the sky's own predation seen in view a few times a run.
	for tier: String in ["full", "quest"]:
		var row := _row(tier)
		if not check(not row.is_empty(), "%s tier in the evidence" % tier):
			continue
		gt(float(row.get("early_catches", 0)), 0.0, "(setup) %s tier: catches as a sparrow" % tier)
		gt(float(row.get("early_pellet_share", 0.0)), EARLY_PELLET_SHARE, "%s tier: most of a sparrow's catches are pellets (%.0f%% of %d)" % [
			tier, float(row.get("early_pellet_share", 0.0)) * 100.0, int(row.get("early_catches", 0))])
		gt(float(row.get("npc_catches_seen_median", 0.0)), SEEN_NPC_CATCHES - 1e-6, "%s tier: the sky's predation seen in view (median %.1f NPC catches within 40 m a run)" % [
			tier, float(row.get("npc_catches_seen_median", 0.0))])
		metric("loop_%s" % tier, {"catches_per_min": row.get("catches_per_min"), "unassisted_share": row.get("unassisted_share"),
			"chase_ends": row.get("chase_ends"), "evading_share": row.get("evading_share")})


func test_the_target_ring_follows_the_chase() -> void:
	# CueTrack's target cue in the held-out runs, as mechanics_test checks
	# the modelled ones: the ring stays on the bird being chased.
	for tier: String in ["full", "quest"]:
		var tc: Dictionary = _row(tier).get("target_cue", {})
		if not check(tc.has("voluntary_per_min"), "(setup) %s tier: the evidence pools the ring's changes" % tier):
			continue
		lt(float(tc["voluntary_closing_per_min"]), RING_CLOSING_PER_MIN, "%s tier: under %.1f a minute away from a valid bird the player was gaining on (%.2f)" % [
			tier, RING_CLOSING_PER_MIN, float(tc["voluntary_closing_per_min"])])
		lt(float(tc["voluntary_per_min"]), RING_VOLUNTARY_PER_MIN, "%s tier: under %.0f a minute away from a still-valid bird (%.2f)" % [
			tier, RING_VOLUNTARY_PER_MIN, float(tc["voluntary_per_min"])])
		var hm: Variant = tc.get("hold_median_s")
		check(hm == null or float(hm) >= RING_HOLD_MEDIAN_S - 1e-6, "%s tier: a target held a median %.0f s or more before such a change (%s s)" % [
			tier, RING_HOLD_MEDIAN_S, hm])
		metric("ring_%s" % tier, tc)

