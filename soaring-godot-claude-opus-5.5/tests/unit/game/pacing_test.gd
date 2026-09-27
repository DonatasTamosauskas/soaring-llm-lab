extends "res://tests/unit/game/game_fixture.gd"
## G4's modelled half: whole simulated runs through the real GameLoop in the
## AI MIRROR (scripts/game/sim/: a snapshot of the AI's NPCs, needing no
## other area's code), a modelled competent player (IntegratedSim,
## SimPilot) flying NPC physics. The isolated, replayable regression of the
## loop + pilot + sims (scripts/game/data/integrated_evidence.json): a run is
## a pure function of its seed, so the start of a stored run is replayed
## live and must match bit for bit; and the cues' behaviour in whole runs
## (the threat cue steady, attacks named at once).
##
## The brief's pacing and danger are NOT asserted here any more (core loop
## round, the lead's direction: "fix and use the real-chain harness"). The
## modelled valley evidence of rounds 3-5 (live_ai_evidence.json - SimPilot
## flying NPC physics in the valley) disagreed 3-4x with a person flying the
## real chain (integration round 2: ~0.8 catches a minute modelled against
## ~0.25 real; the modelled pigeon at ~6 min, the real one never reached in
## most full-tier runs), and it is retired. The brief is asserted on whole
## runs of the real game played through the real flight chain:
## tests/unit/integration/real_pacing_test.gd (both tiers, tuning and
## held-out seeds, the same thresholds: pigeon 5-8 min, eagle 20-30 min,
## caught in >= 40% of runs, < 20% lost), with the same cue measures
## (CueTrack) this test applies to the mirror.

const EVIDENCE := "res://scripts/game/data/integrated_evidence.json"
const MIN_RUNS := 10
## The replay test runs this much of a stored mirror run (the whole run took
## two minutes of the suite's time; every checkpoint up to here must match).
const REPLAY_S := 360.0
const REGENERATE := "tests/shots/gameloop_pacing.tscn -- --integrated=10 --minutes=50 --skills=competent (docs/areas/GAMELOOP.md, \"Regenerating the evidence\")"
## What the mirror evidence records of the tuning it ran (the growth and
## danger constants are left out of the code fingerprint and checked here
## against the shipped values instead: IntegratedSim.FINGERPRINT_SKIP_LINES).
const SHIPPED_KNOBS := ["bold_decay", "bold_floor", "cone_on_player", "grace", "growth_exp", "growth_gain", "reach_on_player",
	"respite", "sky_growth_exp", "sky_growth_floor"]
## The threat cue in whole runs: A -> B -> A hops of a shown cue through a
## bird that was not attacking, per minute of attack (fix round 4 review:
## ~38 a minute, the name hopping hunter -> bystander -> hunter).
const CUE_PING_PONG_PER_ATTACK_MIN := 1.0
## Attacks named at once (fix round 5): the review's "masked" time - any
## hunter shown 0.15 under its own level, including one flying off after its
## pass - as a share of attack time.
const MASKED_SHARE_MAX := 0.02

var ev := {}


func before_all() -> void:
	ev = _load(EVIDENCE)


static func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


## A stored number; null (how the tool stores INF: a tier never reached) is INF.
static func num(v: Variant) -> float:
	return INF if v == null else float(v)


func _mirror_runs(s: String) -> Array:
	return ev.get("skills", {}).get(s, {}).get("runs", [])


func test_evidence_is_current() -> void:
	check(not ev.is_empty(), "mirror evidence present at %s (run %s)" % [EVIDENCE, REGENERATE])
	var fp := IntegratedSim.fingerprint()
	eq(ev.get("fingerprint", ""), fp, "mirror evidence made by the current rules and simulation (else re-run %s)" % REGENERATE)
	gt(float(_mirror_runs("competent").size()), MIN_RUNS - 0.5, "mirror competent: at least %d runs" % MIN_RUNS)
	gt(float(ev.get("minutes", 0.0)), 44.9, "mirror runs of at least 45 simulated minutes")
	var tuning: Dictionary = ev.get("tuning", {})
	near(float(tuning.get("growth_gain", -1.0)), SizeRules.GROWTH_GAIN, 1e-9, "evidence ran the shipped GROWTH_GAIN")
	near(float(tuning.get("growth_exp", -1.0)), SizeRules.GROWTH_SIZE_EXP, 1e-9, "evidence ran the shipped GROWTH_SIZE_EXP")
	near(float(tuning.get("respite", -1.0)), GameLoop.ATTACK_RESPITE_S, 1e-9, "evidence ran the shipped ATTACK_RESPITE_S")
	near(float(tuning.get("sky_growth_exp", -1.0)), GameLoop.SKY_GROWTH_EXP, 1e-9, "evidence ran the shipped SKY_GROWTH_EXP")
	near(float(tuning.get("sky_growth_floor", -1.0)), GameLoop.SKY_GROWTH_FLOOR, 1e-9, "evidence ran the shipped SKY_GROWTH_FLOOR")
	near(float(tuning.get("bold_decay", -1.0)), GameLoop.BOLD_DECAY, 1e-9, "evidence ran the shipped BOLD_DECAY")
	near(float(tuning.get("bold_floor", -1.0)), GameLoop.BOLD_FLOOR, 1e-9, "evidence ran the shipped BOLD_FLOOR")
	var cr := CatchRule.new()
	near(float(tuning.get("grace", -1.0)), GameLoop.ESCAPE_GRACE_S, 1e-9, "evidence ran the shipped ESCAPE_GRACE_S")
	near(float(tuning.get("reach_on_player", -1.0)), cr.npc_reach_on_player, 1e-9, "evidence ran the shipped strike reach on the player")
	near(float(tuning.get("cone_on_player", -1.0)), cr.npc_cone_on_player_deg, 1e-9, "evidence ran the shipped strike cone on the player")
	# ...and nothing else: the pacing tool records every sweep knob it sets
	# (tests/shots/gameloop_pacing.gd, _overrides).
	var knobs: Array = tuning.keys()
	knobs.sort()
	eq(knobs, SHIPPED_KNOBS, "the evidence ran with no sweep knob set")
	metric("fingerprint", fp)


func test_evidence_replays_live() -> void:
	# The start of the second competent mirror run, again, from scratch:
	# same seed, same code, so the same run to the millimetre - although it
	# ran after another run in the evidence process and first here (a run
	# depends on nothing but its seed).
	var stored: Dictionary = _mirror_runs("competent")[1] if _mirror_runs("competent").size() > 1 else {}
	check(not stored.is_empty() and not (stored.get("checkpoints", []) as Array).is_empty(), "(setup) a stored competent run with checkpoints")
	if stored.is_empty() or (stored.get("checkpoints", []) as Array).is_empty():
		return
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = await sim.run(&"competent", int(stored["seed"]), REPLAY_S)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	var want: Array = []
	for c: Array in stored["checkpoints"]:
		if float(c[0]) <= REPLAY_S + 1e-6:
			want.append(c)
	gt(float(want.size()), REPLAY_S / IntegratedSim.CHECKPOINT_S - 0.5, "(setup) stored checkpoints cover the replay")
	# (Numbers compared as numbers: JSON reads every stored one as a float.)
	var same := (r["checkpoints"] as Array).size() == want.size()
	if same:
		for i in want.size():
			var a: Array = r["checkpoints"][i]
			var b: Array = want[i]
			for k in b.size():
				same = same and absf(float(a[k]) - float(b[k])) <= 1e-6
	check(same, "every checkpoint (catches, deaths, mass, position) matches: %s vs stored %s" % [r["checkpoints"], want])
	var tiers_ok := true
	for k: String in stored["tier_at"]:
		var at := num(stored["tier_at"][k])
		if at <= REPLAY_S:
			tiers_ok = tiers_ok and absf(float(r["tier_at"].get(int(k), INF)) - at) <= 0.002
	check(tiers_ok, "same time to every tier reached in the replayed part")
	var deaths_before := 0
	for d in stored["death_times"]:
		if float(d) <= REPLAY_S:
			deaths_before += 1
	eq(int(r["deaths"]), deaths_before, "same deaths in the replayed part")
	metric("replay", {"seed": stored["seed"], "wall_s": wall, "checkpoints": want.size(), "catches": r["catches"]})
	sim.queue_free()
	await get_tree().process_frame


func test_the_threat_cue_is_steady_in_the_sky() -> void:
	# G6 in whole runs (fix round 4 review: in the valley the named predator
	# hopped hunter -> bystander -> hunter every ~0.6 s during attacks - 239
	# changes in 4.8 attack-minutes, 42 carrying an attack-level threat onto
	# birds whose own threat was under 0.1). Every mirror run counts, at
	# every threat_changed (CueTrack's "cue"): the level shown is always the
	# named bird's own; an attack on the player is never handed to a bird not
	# hunting it while the attacker is still in play; no name moves by
	# preference to a bird shown at attack strength that is no threat right
	# now; a shown cue rarely hops back to the bird it just left through one
	# that was not attacking. (The same measures on the real game's runs:
	# tests/unit/integration/real_pacing_test.gd.)
	var mirror := {}
	var returns := {"total": 0, "between_attackers": 0, "flicker": 0}
	var returns_match := true
	for r: Dictionary in _mirror_runs("competent"):
		for k: String in r.get("cue", {}):
			mirror[k] = float(mirror.get(k, 0.0)) + float(r["cue"][k])
		var cr: Dictionary = r.get("cue_returns", {})
		for k: String in returns:
			returns[k] = int(returns[k]) + int(cr.get(k, -1000))
		returns_match = returns_match and int(cr.get("total", -1)) == int((r.get("cue", {}) as Dictionary).get("ping_pong", -2))
	metric("cue_mirror", mirror)
	metric("cue_mirror_returns", returns)
	check(mirror.has("attack_s"), "(setup) every run records the cue")
	var attack_min := float(mirror.get("attack_s", 0.0)) / 60.0
	gt(attack_min, 5.0, "(setup) minutes of attacks on the player to judge by: %.1f" % attack_min)
	eq(int(mirror.get("not_own", -1)), 0, "the level shown is always the named bird's own")
	eq(int(mirror.get("attack_to_bystander", -1)), 0, "an attack is never handed to a bird that is not hunting the player")
	eq(int(mirror.get("attack_to_harmless", -1)), 0, "no attack-strength name moved to a bird that is no threat now")
	# (The mirror, an AI snapshot, sends two or three hunters at once: a
	# return where both birds were attacking when they took the name - two
	# hunters diving in turn - is the cue following the diver, not flicker.)
	check(returns_match, "(setup) the returns split adds up to the runs' own count")
	lt(float(returns["flicker"]) / maxf(attack_min, 1e-6), CUE_PING_PONG_PER_ATTACK_MIN,
			"A -> B -> A hops through a bird that was not attacking, under %.0f per attack-minute (%d in %.1f; %d more between two attackers)" % [
				CUE_PING_PONG_PER_ATTACK_MIN, int(returns["flicker"]), attack_min, int(returns["between_attackers"])])


func test_attacks_are_named_at_once_in_the_sky() -> void:
	# G6 in whole runs (fix round 5 review: in the game's sky a bird hunting
	# the player at attack strength went unnamed behind a faintly shown bird
	# - 516 masked episodes in 58 attack-minutes, 441 of 525 attacks that
	# began behind another name named more than 0.25 s late, 29 never).
	# CueTrack, frame by frame in every mirror run: no LIVE attack is ever
	# masked (a hunter at attack strength whose raw threat is live, unnamed
	# while the cue reports 0.15 less), and every attack is named at once
	# unless the named bird was itself a live attack on the player striking
	# first ("held": two hunters at once).
	var t := {"attack_s": 0.0, "masked_s": 0.0, "masked_episodes": 0.0, "masked_live_s": 0.0, "masked_live_episodes": 0.0,
		"onsets": 0.0, "onsets_late": 0.0, "onsets_never": 0.0, "onsets_held": 0.0}
	var worst := 0.0
	for r: Dictionary in _mirror_runs("competent"):
		var c: Dictionary = r.get("cue", {})
		for k: String in t:
			t[k] = float(t[k]) + float(c.get(k, NAN))
		worst = maxf(worst, float(c.get("masked_worst_gap", 0.0)))
	var attack_min := float(t["attack_s"]) / 60.0
	metric("attack_naming_mirror", t)
	metric("attack_naming_mirror_worst_masked_gap", worst)
	check(not is_nan(float(t["onsets"])), "(setup) every run records the attack tracker")
	gt(float(t["onsets"]), 50.0, "(setup) attacks to judge by: %.0f in %.1f attack-minutes" % [t["onsets"], attack_min])
	eq(float(t["masked_live_s"]), 0.0, "a live attack on the player is never masked (%.0f episodes)" % t["masked_live_episodes"])
	var unheld := float(t["onsets_late"]) + float(t["onsets_never"]) - float(t["onsets_held"])
	eq(unheld, 0.0, "every attack is named at once unless a live attack striking first holds the name (%.0f late, %.0f never, %.0f of them held, of %.0f)" % [
			t["onsets_late"], t["onsets_never"], t["onsets_held"], t["onsets"]])
	lt(float(t["masked_s"]) / maxf(float(t["attack_s"]), 1e-6), MASKED_SHARE_MAX,
			"under %.0f%% of attack time with any hunter shown 0.15 under its own level (%.1f s of %.0f s)" % [
				MASKED_SHARE_MAX * 100.0, t["masked_s"], t["attack_s"]])
