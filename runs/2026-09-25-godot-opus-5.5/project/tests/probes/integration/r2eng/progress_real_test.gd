extends TestCase
## PROBE (round-2 engineering verifier): progression through the REAL chain,
## nothing staged, nothing pinned - the same cue-following competent pilot
## as tests/unit/integration/game_catch_test.gd (integration_chase_pilot.gd
## through BotPoseSource -> WingInput -> FlightModel, the game's own catch
## rule and assist, the real sky and its hunters), flown for much longer and
## recording when each tier is reached (the brief's pacing: pigeon in ~5-8
## min, eagle in ~20-30 min of competent play). A bot is not a person: this
## is an indication of what the composed game yields, not a verdict on pacing.
##
##   tools/gd.sh v2e_prog --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/integration/r2eng --suite=progress_real --fresh-settings [--quality=quest] [--prog_s=1500] [--prog_seed=5]
##
## Writes artifacts/integration/verify/r2eng/progress_<quality>_<seed>.json.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
const CHASE_MAX_S := 25.0
const COMMIT_M := 12.0

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_progress_through_the_real_chain() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var play_s := float(Paths.arg("prog_s", "1500"))
	var seed_v := int(Paths.arg("prog_seed", "5"))
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(seed_v, ChasePilot)
	var pilot := kit.pilot as ChasePilot
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	var log := {"catches": [], "tiers": [], "deaths": [], "runs_ended": []}
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			log["catches"].append({"t": snappedf(Game.run_time, 0.1), "prey": String(prey.species),
				"assist": snappedf(m.game_loop.rule.player_assist, 0.001), "mass": snappedf(m.player.mass, 0.0001)})
	var on_tier := func(_o: int, n: int) -> void:
		log["tiers"].append({"t": snappedf(Game.run_time, 0.1), "tier": String(SizeRules.SPECIES[n]["id"])})
	var on_death := func(by: Bird) -> void:
		log["deaths"].append({"t": snappedf(Game.run_time, 0.1), "by": String(by.species) if is_instance_valid(by) else "?"})
	Events.bird_caught.connect(on_caught)
	Events.player_tier_changed.connect(on_tier)
	Events.player_caught.connect(on_death)
	var cur: NpcBird = null
	var since := 0.0
	var off_cue := 0.0
	var t := 0.0
	var dt := 1.0 / 72.0
	var chases := 0
	var peak := 0
	while t < play_s:
		await kit.advance(dt)
		t += dt
		peak = maxi(peak, SizeRules.tier_for_mass(m.player.mass))
		if Paths.user_args().has("prog_trace") and fmod(t, 10.0) < dt:
			var tg: Variant = m.game_loop.get_run_stats().get("target")
			print("[r2eng] prog t=%.0f state %s mode %s pos %s agl %.1f speed %.1f species %s target %s chasing %s" % [t, Game.state_name(),
				m.player.mode_name(), m.player.global_position.snapped(Vector3.ONE * 0.1), float(m.player.telemetry().get("altitude_agl", -1.0)),
				m.player.velocity.length(), m.player.species, (tg as Bird).species if tg is Bird and is_instance_valid(tg) else "-",
				cur != null])
		if Game.state == Game.State.ENDED:
			log["runs_ended"].append({"t": snappedf(t, 0.1), "summary_peak": String(SizeRules.SPECIES[peak]["id"])})
			break
		if Game.state != Game.State.PLAYING:
			if cur != null:
				cur = null
				pilot.stop_chase()
				kit.cruise()
			continue
		var tgt: Variant = m.game_loop.get_run_stats().get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if cur != null:
			since += dt
			var ended := false
			if not is_instance_valid(cur) or not cur.alive or cur.hidden or since > CHASE_MAX_S:
				ended = true
			else:
				var gap := cur.get_body_position().distance_to(m.player.get_body_position())
				off_cue = off_cue + dt if named != cur and gap > COMMIT_M else 0.0
				ended = off_cue > 1.0
			if ended:
				cur = null
				pilot.stop_chase()
				kit.cruise()
		if cur == null and named != null:
			cur = named
			since = 0.0
			off_cue = 0.0
			chases += 1
			pilot.chase_prey(named)
	Events.bird_caught.disconnect(on_caught)
	Events.player_tier_changed.disconnect(on_tier)
	Events.player_caught.disconnect(on_death)
	var unassisted := 0
	for c: Dictionary in log["catches"]:
		if float(c["assist"]) <= 0.0:
			unassisted += 1
	var res := {"quality": m.quality.name, "seed": seed_v, "played_s": snappedf(t, 0.1), "chases": chases,
		"catches": (log["catches"] as Array).size(), "unassisted": unassisted, "deaths": (log["deaths"] as Array).size(),
		"peak": String(SizeRules.SPECIES[peak]["id"]), "tiers": log["tiers"], "catch_log": log["catches"],
		"death_log": log["deaths"], "runs_ended": log["runs_ended"], "final_mass": m.player.mass,
		"npc_catches": int(m.game_loop.get_run_stats().get("npc_catches", -1))}
	print("[r2eng] progress: ", JSON.stringify(res))
	var dir := Paths.artifacts("integration").path_join("verify/r2eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("progress_%s_%d.json" % [m.quality.name, seed_v]), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
