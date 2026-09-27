## VERIFIER COPY (round 2) of scripts/game/sim/integrated_sim.gd with ONE change: the
## stale chase target is checked with is_instance_valid() before it is passed
## to the typed _choose_target(), which raised "previously freed" when the
## AI freed the chased NPC (seed 202, AI code bce30a1d7cb70442). Nothing else differs.
extends Node
## Whole runs through the real GameLoop with mock birds: a SimEcosystem of
## hunting/fleeing SimBirds (a mirror of the AI area's NPCs, validated against
## the AI's own measurements) around a player SimBird flown by a SimPilot.
## Nothing is statistical here: chances to chase, chases, attacks and
## escapes all emerge from flight in a crowd and the real catch rule. This is
## the pacing and danger evidence (G4): tests/shots/gameloop_pacing.tscn runs
## it and stores the result with a fingerprint of the code it came from
## (fingerprint()); tests/unit/game/pacing_test.gd asserts on it and replays
## a run live to prove it is current. Runs are deterministic per seed.

## The NPC physics (SimFlight) and the AI's pursuit/jink timing need a
## physics-like rate; 30 Hz is within the AI's own LOD range.
const DT := 1.0 / 30.0

var loop: GameLoop
## The sky: a SimEcosystem (the default), or whatever sky_factory builds
## (duck-typed: seed_rng(seed), step(dt), ground_y, the counters read in
## run()'s result, optional prepare() coroutine and bounds_radius). The
## pacing tool's --live_ai mode plugs the AI area's real Ecosystem in here;
## nothing in scripts/game refers to the AI's code.
var eco: Node
var player: SimBird
## Print a status line every 15 simulated seconds.
var debug := false
## Replaces SimPilot skill values for every run (tools, sensitivity).
var pilot_overrides := {}
## > 0: the player starts the run at this mass (diagnostics).
var start_mass := -1.0
## Diagnostic: the player flies 80 m laps at cruise, never hunts or evades
## and cannot be caught - the AI area's mock-player setup, to compare the
## mirror's hunting pressure and energy with the real AI's (AiMirror).
var laps := false


## Called with this sim after every build (tools apply their sweep knobs to
## the fresh loop / sky / player here).
var configure: Callable = Callable()
## Builds the sky for each run instead of a SimEcosystem (see `eco`).
var sky_factory: Callable = Callable()


func _ready() -> void:
	_build()


## A fresh loop, sky and player. Every run gets its own, so a run is a pure
## function of its seed and skill: nothing (the loop's clock, the sky's LOD
## phase, bird bookkeeping) carries over from the run before.
func _build() -> void:
	for n in [loop, eco, player]:
		if n != null and is_instance_valid(n):
			remove_child(n)
			n.free()
	loop = GameLoop.new()
	loop.auto_step = false
	loop.verbose = false
	loop.apply_highlights = false
	loop.records_path = "user://gameloop_integrated_records.json"
	add_child(loop)
	eco = sky_factory.call() if sky_factory.is_valid() else SimEcosystem.new()
	add_child(eco)
	player = SimBird.new()
	player.player_mode = true
	player.name = "SimPlayer"
	player.ground_y = float(eco.get(&"ground_y"))
	add_child(player)
	if configure.is_valid():
		configure.call(self)


## One run of at most max_s simulated seconds. Awaits a frame every few
## thousand steps so a watching window stays responsive.
func run(skill: StringName, seed_: int, max_s: float) -> Dictionary:
	_build()
	if eco.has_method(&"prepare"):
		await eco.call(&"prepare")
	eco.call(&"seed_rng", seed_)
	# A sky with edges (a real world) keeps a searching player inside them,
	# as the world's bounds keep a person.
	var bounds: float = float(eco.get(&"bounds_radius")) if eco.get(&"bounds_radius") != null else INF
	var pilot := SimPilot.new(skill, seed_ * 31 + 7)
	if not pilot_overrides.is_empty():
		pilot.skill = pilot.skill.duplicate()
		pilot.skill.merge(pilot_overrides, true)
	var tier_at := {}
	var deaths := [0]
	var catches := [0]
	var victory := [-1.0]
	var t := [0.0]
	var on_tier := func(_o: int, n: int) -> void:
		if not tier_at.has(n):
			tier_at[n] = t[0]
	var chase_min_d := INF
	var progress_d := INF
	var progress_t := 0.0
	var chasing := [0.0]
	var cruising := [0.0]
	var chase_ends := {}
	var death_times: Array[float] = []
	var death_by: Array[String] = []
	var evading := [0.0]
	var on_caught := func(by: Bird) -> void:
		deaths[0] += 1
		death_times.append(snappedf(t[0], 0.1))
		death_by.append("%s/%s" % [by.species, SizeRules.species_for_mass(player.mass)])
	var on_bird := func(pred: Bird, q: Bird) -> void:
		if pred == player:
			catches[0] += 1
			if debug:
				print("[gameloop] CAUGHT %s at t=%.1f" % [q.species, t[0]])
	var on_end := func(s: Dictionary) -> void:
		if s.get("victory", false):
			victory[0] = t[0]
	Events.player_tier_changed.connect(on_tier)
	Events.player_caught.connect(on_caught)
	Events.bird_caught.connect(on_bird)
	Events.run_ended.connect(on_end)
	loop.start_run()
	if start_mass > 0.0:
		player.mass = start_mass
	tier_at[SizeRules.tier_for_mass(player.mass)] = 0.0
	var target: Bird = null
	var target_t := 0.0
	var ignore := {}
	var steps := 0
	var chases := 0
	while t[0] < max_s and loop.phase != GameLoop.Phase.ENDED:
		t[0] += DT
		steps += 1
		eco.call(&"step", DT)
		if laps:
			var off := player.global_position - Vector3(0, 25, 0)
			var tan := Vector3(-off.z, 0.0, off.x).normalized()
			var want := tan + Vector3(-off.x, 0.0, -off.z) * (Vector2(off.x, off.z).length() - 80.0) * 0.01
			want.y = clampf(-off.y * 0.05, -0.3, 0.3)
			player.fly(want, player.cruise_speed(), DT, 0.5)
		elif loop.phase == GameLoop.Phase.PLAYING and player.alive:
			if pilot.aware_of(loop.watch, player):
				# Evading pauses the chase; a person picks it up again after.
				pilot.evade(player, pilot.threat, DT)
				evading[0] += DT
			else:
				var want := _choose_target(pilot, target if is_instance_valid(target) else null, ignore, t[0])
				if want != target:
					if target != null and is_instance_valid(target):
						chase_ends["lost" if target.alive else "gone"] = int(chase_ends.get("lost" if target.alive else "gone", 0)) + 1
						if debug:
							print("[gameloop] chase end %s %s after %.1fs min_d %.1f d %.1f fleeing %s y %.1f/%.1f" % ["lost" if target.alive else "gone",
								target.species, target_t, chase_min_d, target.global_position.distance_to(player.global_position),
								SimPilot.fleeing_from(target) != null,
								player.global_position.y, target.global_position.y])
					target = want
					target_t = 0.0
					chase_min_d = INF
					progress_d = INF
					progress_t = 0.0
					if target != null:
						chases += 1
						if debug:
							print("[gameloop] chase start %s (%.0f g) at %.1f m (player %s %.0f g) prey e %.2f alert %s" % [target.species, target.mass * 1000.0,
								target.global_position.distance_to(player.global_position), player.species, player.mass * 1000.0,
								float(target.get(&"energy")), SimPilot.fleeing_from(target) != null])
				if target != null:
					# Persistence counts from when the prey is running (or from
					# the pilot's first approach, at double length).
					var running: bool = SimPilot.fleeing_from(target) == player
					target_t += DT if running else DT * 0.5
					chasing[0] += DT
					# A chase that stops closing is dropped (as the AI's hunters
					# drop one): best distance not beaten by 10% for a while.
					var dnow := target.global_position.distance_to(player.global_position)
					if dnow < progress_d * 0.9:
						progress_d = dnow
						progress_t = 0.0
					else:
						progress_t += DT
					if running and progress_t > NO_PROGRESS_S * player.time_scale():
						target_t = INF
					chase_min_d = minf(chase_min_d, target.global_position.distance_to(player.global_position))
					if debug and steps % 15 == 0:
						var rel := target.global_position - player.global_position
						var fl := SimPilot.fleeing_from(target)
						print("[gameloop]   chasing %s d %.1f flee %s(%s) e %.2f v %.1f/%.1f y %.1f/%.1f stalk %s assist %.2f angle %.0f prey-hdg-vs-rel %.0f" % [target.species,
							rel.length(), fl != null, fl.species if fl != null else "-",
							float(target.get(&"energy")),
							player.speed, target.velocity.length(), player.global_position.y, target.global_position.y,
							pilot._stalking, loop.rule.player_assist, rad_to_deg(player.heading.angle_to(rel.normalized())),
							rad_to_deg(target.velocity.normalized().angle_to(rel.normalized())) if target.velocity.length() > 0.1 else 0.0])
					if target_t > float(pilot.skill["give_up_s"]) * player.time_scale():
						ignore[target.get_instance_id()] = t[0] + 5.0
						chase_ends["gave_up"] = int(chase_ends.get("gave_up", 0)) + 1
						if debug:
							print("[gameloop] chase end gave_up %s after %.1fs min_d %.1f d %.1f fleeing %s y %.1f/%.1f" % [target.species, target_t, chase_min_d,
								target.global_position.distance_to(player.global_position),
								SimPilot.fleeing_from(target) != null,
								player.global_position.y, target.global_position.y])
						target = null
					else:
						pilot.hunt(player, target, DT)
				else:
					cruising[0] += DT
					var seen := _nearest_prey()
					var pp := player.global_position
					if Vector2(pp.x, pp.z).length() > bounds * 0.75:
						pilot.search(player, Vector3(0.0, pp.y, 0.0), DT)  # back towards the middle
					elif seen != null:
						pilot.search(player, seen.get_body_position(), DT)
					else:
						pilot.cruise(player, DT)
		loop.step(DT)
		if debug and steps % 900 == 0:
			print("[gameloop] sim t=%.0f phase=%s alive=%s mass=%.3f y=%.0f spd=%.1f target=%s want=%s threat=%.2f/%s assist=%.2f prot=%.1f catches=%d" % [
				t[0], GameLoop.Phase.keys()[loop.phase], player.alive, player.mass, player.global_position.y, player.speed,
				loop.watch.target, target, loop.watch.level, loop.watch.predator_ttc, loop.rule.player_assist,
				loop.protection_left(player), catches[0]])
		if steps % 3000 == 0:
			await get_tree().process_frame
	Events.player_tier_changed.disconnect(on_tier)
	Events.player_caught.disconnect(on_caught)
	Events.bird_caught.disconnect(on_bird)
	Events.run_ended.disconnect(on_end)
	var reason := "time"
	if victory[0] >= 0.0:
		reason = "victory"
	elif loop.phase == GameLoop.Phase.ENDED:
		reason = "caught"
	# Tiers reached by skipping (a meal crossing two tiers) count at that time.
	var peak := -1
	for k: int in tier_at:
		peak = maxi(peak, k)
	for k in range(peak):
		if not tier_at.has(k) and k >= SizeRules.tier_for_mass(GameLoop.START_MASS):
			tier_at[k] = tier_at[peak]
	return {"tier_at": tier_at, "deaths": deaths[0], "victory_at": victory[0], "ended_at": t[0],
		"end_reason": reason, "catches": catches[0], "attacks": int(eco.get(&"attacks_on_player")),
		"close_attacks": int(eco.get(&"close_attacks_on_player")), "hunt_ends": (eco.get(&"hunt_ends_on_player") as Dictionary).duplicate(),
		"chases": chases, "npc_catches": int(eco.get(&"npc_catches")), "evading_s": evading[0],
		"chasing_s": chasing[0], "cruising_s": cruising[0], "chase_ends": chase_ends,
		"escapes": loop.stats.escapes,
		"calm_energy": _quartiles(eco.get(&"calm_energy")),
		"death_times": death_times, "death_by": death_by}


## The nearest worthwhile bird the pilot can see (any distance).
func _nearest_prey() -> Bird:
	var pp := player.get_body_position()
	var best: Bird = null
	var best_d := INF
	for b in Birds.all():
		if b == player or not b.alive or not SizeRules.is_worthwhile(player.mass, b.mass) \
				or loop.is_sheltered(b, player.get_wingspan()):
			continue
		var d := b.get_body_position().distance_to(pp)
		if d < best_d and b.get_wingspan() / maxf(d, 0.01) >= VIS_ANGLE:
			best_d = d
			best = b
	return best


## The code the evidence depends on: every line (comments and blank lines
## stripped) of the rules, the loop and the simulations, hashed. Any change to
## how a run plays out changes it, and the pacing test then refuses the
## stored evidence until tests/shots/gameloop_pacing.tscn has re-run it.
const FINGERPRINT_FILES: Array[String] = [
	"res://scripts/core/size_rules.gd", "res://scripts/core/bird.gd",
	"res://scripts/game/game_loop.gd", "res://scripts/game/catch_rule.gd", "res://scripts/game/catch_sweep.gd",
	"res://scripts/game/catch_grid.gd", "res://scripts/game/threat_watch.gd", "res://scripts/game/run_stats.gd",
	"res://scripts/game/sim/integrated_sim.gd", "res://scripts/game/sim/sim_ecosystem.gd",
	"res://scripts/game/sim/ecosystem_plan.gd", "res://scripts/game/sim/sim_brains.gd",
	"res://scripts/game/sim/sim_bird.gd", "res://scripts/game/sim/sim_flight.gd",
	"res://scripts/game/sim/sim_pilot.gd", "res://scripts/game/sim/ai_mirror.gd",
]


static func fingerprint() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for path in FINGERPRINT_FILES:
		var text := FileAccess.get_file_as_string(path)
		for line in text.split("\n"):
			var t := line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue
			ctx.update(t.to_utf8_buffer())
	return ctx.finish().hex_encode().substr(0, 16)


## Summary of runs: per tier the median/quartiles of the time reached (INF
## when not reached) and the share that got there; deaths; how runs ended.
static func summarize(runs: Array) -> Dictionary:
	var tiers := {}
	for t in SizeRules.SPECIES.size():
		var xs: Array[float] = []
		for r: Dictionary in runs:
			xs.append(float(r["tier_at"].get(t, r["tier_at"].get(str(t), INF))))
		tiers[t] = _stats(xs)
	var deaths: Array[float] = []
	var vics: Array[float] = []
	var catches: Array[float] = []
	var caught_out := 0
	for r: Dictionary in runs:
		deaths.append(float(r["deaths"]))
		vics.append(float(r["victory_at"]) if float(r["victory_at"]) >= 0.0 else INF)
		catches.append(float(r["catches"]))
		if r["end_reason"] == "caught":
			caught_out += 1
	return {"n": runs.size(), "tiers": tiers, "deaths": _stats(deaths), "victory": _stats(vics),
		"catches": _stats(catches), "ended_caught": float(caught_out) / maxf(runs.size(), 1)}


static func _stats(xs: Array[float]) -> Dictionary:
	var s := xs.duplicate()
	s.sort()
	var n := s.size()
	if n == 0:
		return {"median": INF, "q25": INF, "q75": INF, "reached": 0.0}
	var reached := 0
	for x in s:
		if is_finite(x):
			reached += 1
	# Median of an even count: the mean of the middle two (INF if either is).
	var med: float = s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) * 0.5
	return {"median": med, "q25": s[n / 4], "q75": s[(3 * n) / 4], "min": s[0], "max": s[n - 1],
		"reached": float(reached) / n}


static func _quartiles(xs: Array[float]) -> Array:
	if xs.is_empty():
		return []
	var s := xs.duplicate()
	s.sort()
	var n := s.size()
	return [snappedf(s[n / 10], 0.01), snappedf(s[n / 4], 0.01), snappedf(s[n / 2], 0.01), snappedf(s[(3 * n) / 4], 0.01), snappedf(s[(9 * n) / 10], 0.01)]


## A pilot drops a chase on a running prey that has not got 10% closer for
## this long (x body time).
const NO_PROGRESS_S := 5.0

## A pilot does not start a chase on a bird further than this (wingspans,
## or seconds of flight at cruise if further); beyond it, it flies towards
## the nearest worthwhile bird it can see (searching).
const CHASE_RANGE_SPANS := 80.0
const CHASE_RANGE_S := 4.5

## The smallest angle (rad) a bird must subtend to be noticed: about 5
## pixels on a Quest Pro. Angular size does not depend on world_scale, so
## this is the same rule at every player size.
const VIS_ANGLE := 0.004


func _choose_target(pilot: SimPilot, current: Bird, ignore: Dictionary, now: float) -> Bird:
	var pp := player.get_body_position()
	var span := player.get_wingspan()
	# A person sees a bird dive into a hedge and lets it go.
	if current != null and is_instance_valid(current) and current.alive and pilot.wants(player, current) \
			and current.get_wingspan() / maxf(current.get_body_position().distance_to(pp), 0.01) >= VIS_ANGLE * 0.6 \
			and not loop.is_sheltered(current, span):
		return current
	# The loop's target cue first (the HUD shows it) ...
	var w := loop.watch.target
	if w != null and float(ignore.get(w.get_instance_id(), -1.0)) < now:
		return w
	# ... otherwise the most promising bird the pilot can actually see.
	var best: Bird = null
	var best_s := 0.0
	var chase_r := maxf(CHASE_RANGE_SPANS * span, CHASE_RANGE_S * player.cruise_speed())
	for b in Birds.all():
		if b == player or not b.alive or not pilot.wants(player, b):
			continue
		if float(ignore.get(b.get_instance_id(), -1.0)) >= now or loop.is_sheltered(b, span):
			continue
		var d := b.get_body_position().distance_to(pp)
		if b.get_wingspan() / maxf(d, 0.01) < VIS_ANGLE or d > chase_r:
			continue
		var sc := SizeRules.meal_worth(player.mass, b.mass) * ThreatWatch.chase_odds(b.mass / player.mass) \
				* ThreatWatch.height_edge(pp.y - b.get_body_position().y, span) / (1.0 + d / (20.0 * span))
		if sc > best_s:
			best_s = sc
			best = b
	return best
