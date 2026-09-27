class_name ChaseLab
extends Node
## One-on-one trials through a real GameLoop (catch rule, reach, aim cones,
## player forgiveness and all), with SimBirds flying the AI's measured
## envelope (AiMirror) and SimBrains mirroring the AI's hunting and fleeing:
##  * duels between two NPCs in the AI area's own duel setup - the check
##    that the mirror behaves like the real AI (AiMirror.DUEL_*),
##  * the player (a SimPilot at some skill) chasing a fleeing prey,
##  * an NPC hunter attacking the player.
## The duels check the mirror (tests/unit/game/danger_test.gd); the single
## chases and attacks measure what one encounter is worth at a given size and
## skill (danger_test's "danger is real and avoidable", and the tuning
## diagnostics in tests/shots/gameloop_pacing.tscn). Whole runs are
## IntegratedSim's. Everything is deterministic for a given seed.
##
## Add as a child of anything in the tree (it needs the Birds/Game autoloads);
## it owns its GameLoop and four birds and frees them when done.

const DT := 1.0 / 30.0
## Duels run at a finer step (the AI's duel test runs at 72 Hz).
const DUEL_DT := 1.0 / 60.0

## Multiplies the pilots' give-up time (sensitivity analysis).
var persistence := 1.0
## Duels also return their flight paths (for plots).
var record_paths := false
## Print every step of escape trials (diagnostics).
var trace := false
## Escape trials fly the player's bird with the AI's flee rules instead of
## the SimPilot (diagnostics: how would an NPC fare in the player's place).
var npc_player := false
## Escape trials with a player who never reacts (the control: is the danger
## real?).
var unaware := false
## Replaces SimPilot skill values in every trial (tools, sensitivity).
var pilot_overrides := {}
## Hunt trials over flat ground with the prey in its species' altitude band
## (else in open air, 200 m up).
var near_ground := false
## The player's final-approach magnet (GameLoop.magnet) in hunt trials: off
## by default - single chases measure the catch rule and the flying itself
## (the magnet is forgiveness on top, measured with it on).
var magnet := false
var loop: GameLoop
var player: SimBird
var other: SimBird
var duel_hunter: SimBird
var duel_prey: SimBird
var trials := 0
var _caught_player := false
var _caught_prey := false
var _parked := Vector3(0, -5000, 0)


func _ready() -> void:
	loop = GameLoop.new()
	loop.auto_step = false
	loop.apply_highlights = false
	loop.npc_spawn_grace_s = 0.0
	# Single encounters: no first-flight respite at the start of each trial.
	loop.opening_respite_s = 0.0
	loop.verbose = false
	loop.records_path = "user://gameloop_chase_lab_records.json"
	add_child(loop)
	player = _bird("LabPlayer", true)
	other = _bird("LabOther", false)
	duel_hunter = _bird("LabHunter", false)
	duel_prey = _bird("LabPrey", false)
	for b in [other, duel_hunter, duel_prey]:
		_park(b)
	Events.bird_caught.connect(_on_caught)


func _bird(n: String, is_player: bool) -> SimBird:
	var b := SimBird.new()
	b.player_mode = is_player
	b.name = n
	add_child(b)
	return b


func _exit_tree() -> void:
	if Events.bird_caught.is_connected(_on_caught):
		Events.bird_caught.disconnect(_on_caught)


func _on_caught(pred: Bird, prey: Bird) -> void:
	if pred == player and prey == other:
		_caught_prey = true
	elif prey == player:
		_caught_player = true


func _pilot(skill: StringName, seed_: int) -> SimPilot:
	var pilot := SimPilot.new(skill, seed_)
	if not pilot_overrides.is_empty():
		pilot.skill = pilot.skill.duplicate()
		pilot.skill.merge(pilot_overrides, true)
	return pilot


## Takes a bird out of play (the loop ignores dead birds).
func _park(b: SimBird) -> void:
	b.alive = false
	b.global_position = _parked
	b.velocity = Vector3.ZERO
	loop.teleported(b)


## Fresh NPC state for a trial: species by mass, rested, not hungry.
func _setup_npc(b: SimBird, mass: float, rng: RandomNumberGenerator, energy_lo: float = 0.6) -> void:
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	b.alive = true
	b.target = null
	# Duels use rested birds (as the AI's duel test); otherwise the AI's
	# measured energy distribution (AiMirror.spawn_energy).
	b.energy = 1.0 if energy_lo >= 1.0 else AiMirror.spawn_energy(rng)
	b.brain = {"hunger": 0.0}


func _place(b: SimBird, pos: Vector3, heading: Vector3, speed: float) -> void:
	b.global_position = pos
	b.set_heading(heading)
	b.speed = speed
	b.velocity = b.heading * speed
	loop.teleported(b)
	loop.set_protection(b, 0.0)


func _begin(pm: float) -> void:
	for b in [duel_hunter, duel_prey]:
		_park(b)
	loop.magnet = magnet
	loop.direct_danger = false
	loop.start_run()
	player.mass = pm
	player.species = SizeRules.species_for_mass(pm)
	player.alive = true
	loop.set_protection(player, 0.0)
	other.alive = true
	_caught_player = false
	_caught_prey = false
	trials += 1


# =====================================================================
# The AI's duels (validation of the mirror)
# =====================================================================

## One duel of the AI area's hunt_duel_test with SimBrains on both sides and
## the real GameLoop deciding the catch. `strict` applies the AI test's
## stand-in rule (bodies touching: no reach margin, no aim cone) for a
## like-for-like comparison; otherwise the game's own rule.
## Returns {caught, t, reason, stooped}.
func duel_trial(pred_sp: StringName, prey_sp: StringName, fleeing: bool, trial: int, strict: bool) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([String(pred_sp), String(prey_sp), fleeing, trial, 31])
	_park(player)
	_park(other)
	var hunter := duel_hunter
	var prey := duel_prey
	_setup_npc(prey, SizeRules.species_data(prey_sp)["mass"], rng, 1.0)
	_setup_npc(hunter, SizeRules.species_data(pred_sp)["mass"], rng, 1.0)
	var prey_pos := Vector3(rng.randf_range(-20, 20), 40.0, rng.randf_range(-20, 20))
	var a := rng.randf() * TAU
	_place(prey, prey_pos, Vector3(cos(a), 0, sin(a)), prey.cruise_speed())
	var bearing := rng.randf() * TAU
	var dist := rng.randf_range(0.55, 0.9) * AiMirror.hunt_range_m(pred_sp)
	var height := rng.randf_range(-5.0, 10.0)
	if AiMirror.stoops(pred_sp) and trial % 2 == 0:
		height = rng.randf_range(25.0, 45.0)  # raptors often attack from above
	var hp := prey_pos + Vector3(cos(bearing) * dist, height, sin(bearing) * dist)
	var to := prey_pos - hp
	to.y = 0.0
	_place(hunter, hp, to.normalized(), hunter.cruise_speed())
	hunter.brain["hunger"] = 1.0
	# The AI's duel world has flat ground at 0 (the prey starts 40 m up).
	hunter.ground_y = 0.0
	prey.ground_y = 0.0
	SimBrains.start_hunt(hunter, prey)
	var keep_reach := loop.rule.npc_reach
	var keep_cone := loop.rule.npc_cone_deg
	if strict:
		loop.rule.npc_reach = 0.0
		loop.rule.npc_cone_deg = 180.0
	var birds: Array[Bird] = [hunter, prey]
	var t := 0.0
	var scan_t := 0.0
	var out := {"caught": false, "t": AiMirror.DUEL_MAX_S, "reason": "timeout", "stooped": false,
		"min_d": INF, "jinks": 0, "fled_at": -1.0}
	var path_h := PackedVector3Array()
	var path_q := PackedVector3Array()
	var step_i := 0
	while t < AiMirror.DUEL_MAX_S:
		t += DUEL_DT
		scan_t -= DUEL_DT
		var scan := scan_t <= 0.0
		if scan:
			scan_t = SimBrains.SCAN_S
		var why := SimBrains.step_npc(hunter, DUEL_DT, rng, false, birds, hp, 1000.0, false, false)
		if hunter.brain.get("stoop", false):
			out["stooped"] = true
		var jt0: float = prey.brain.get("jink_t", 0.0)
		SimBrains.step_npc(prey, DUEL_DT, rng, scan, birds, prey_pos, 40.0, false, fleeing)
		if float(prey.brain.get("jink_t", 0.0)) > jt0 + 0.1:
			out["jinks"] += 1
		if float(out["fled_at"]) < 0.0 and prey.brain.get("threat") != null:
			out["fled_at"] = t
		out["min_d"] = minf(out["min_d"], hunter.global_position.distance_to(prey.global_position))
		if record_paths and step_i % 4 == 0:
			path_h.append(hunter.global_position)
			path_q.append(prey.global_position)
		step_i += 1
		loop.step(DUEL_DT)
		if not prey.alive:
			out["caught"] = true
			out["t"] = t
			out["reason"] = "caught"
			break
		if why != "":
			out["t"] = t
			out["reason"] = why
			break
	out["end_y"] = [hunter.global_position.y, prey.global_position.y]
	out["end_e"] = [hunter.energy, prey.energy]
	loop.rule.npc_reach = keep_reach
	loop.rule.npc_cone_deg = keep_cone
	hunter.ground_y = -INF
	prey.ground_y = -INF
	if record_paths:
		out["path_hunter"] = path_h
		out["path_prey"] = path_q
	_park(hunter)
	_park(prey)
	return out


## Every pair of AiMirror.DUEL_PAIRS, `n` trials each, prey fleeing or not.
## Returns {pairs: {"hawk>pigeon": {rate, stoops, stoop_catches, reasons}},
## overall}.
func measure_duels(fleeing: bool, strict: bool, n: int = AiMirror.DUEL_TRIALS) -> Dictionary:
	var pairs := {}
	var total := 0
	var caught := 0
	for pr: Array in AiMirror.DUEL_PAIRS:
		var k := 0
		var reasons := {}
		var stoops := [0, 0]
		for i in n:
			var r := duel_trial(pr[0], pr[1], fleeing, i, strict)
			reasons[r["reason"]] = int(reasons.get(r["reason"], 0)) + 1
			if r["caught"]:
				k += 1
			if r["stooped"]:
				stoops[0] += 1
				if r["caught"]:
					stoops[1] += 1
		pairs["%s>%s" % [pr[0], pr[1]]] = {"rate": float(k) / n, "reasons": reasons,
			"stoops": stoops[0], "stoop_catches": stoops[1]}
		total += n
		caught += k
		trials += n
	return {"pairs": pairs, "overall": float(caught) / maxf(total, 1)}


# =====================================================================
# The player hunting / being hunted (single chases and attacks: danger_test
# and the pacing tool's --hunt_detail / --escape_detail diagnostics)
# =====================================================================

## The player (skill) chases a prey of mass pm * r. The prey starts just
## beyond its awareness radius (the AI's per-species value); with the
## skill's `stalk` probability the player has worked round behind and above
## it (a stoop, noticed late), otherwise the prey's heading is random. The
## prey notices, reacts and flees by the AI's rules (SimBrains).
## Returns {caught, t}.
func hunt_trial(pm: float, r: float, skill: StringName, seed_: int, assist: float = 0.0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var pilot := _pilot(skill, seed_ * 7 + 1)
	_begin(pm)
	loop.assist_override = assist
	_setup_npc(other, pm * r, rng)
	var origin := Vector3(0, 200, 0)
	var gy := -INF
	if near_ground:
		var band: Array = AiMirror.ALT[other.species]
		gy = 0.0
		origin = Vector3(0, rng.randf_range(float(band[0]), float(band[1])) + 3.0, 0)
	player.ground_y = gy
	other.ground_y = gy
	player.set_heading(Vector3.FORWARD)
	_place(player, origin, Vector3.FORWARD, player.cruise_speed())
	# The pilot spots it ahead, beyond its awareness; the prey is flying any
	# which way. Whether the pilot stalks it first is the pilot's call.
	var aware := AiMirror.awareness_m(other.species)
	var d0 := aware * rng.randf_range(1.05, 1.5)
	var ang := deg_to_rad(rng.randf_range(-20.0, 20.0))
	var dir := Vector3(sin(ang), rng.randf_range(-0.1, 0.1) if not near_ground else rng.randf_range(-0.1, 0.0), -cos(ang)).normalized()
	var qh := Vector3.FORWARD.rotated(Vector3.UP, rng.randf_range(-PI, PI))
	var qpos := origin + dir * d0
	_place(other, qpos, qh, other.cruise_speed())
	loop.step(DT)
	var birds: Array[Bird] = [player, other]
	var t := 0.0
	var scan_t := 0.0
	var give_up: float = float(pilot.skill["give_up_s"]) * player.time_scale() * persistence
	while t < give_up:
		t += DT
		scan_t -= DT
		var scan := scan_t <= 0.0
		if scan:
			scan_t = SimBrains.SCAN_S
		pilot.hunt(player, other, DT)
		SimBrains.step_npc(other, DT, rng, scan, birds, qpos, 1000.0, false, true)
		loop.step(DT)
		if _caught_prey:
			player.ground_y = -INF
			other.ground_y = -INF
			return {"caught": true, "t": t}
		if other.global_position.distance_to(player.global_position) > d0 * 3.0:
			break
	player.ground_y = -INF
	other.ground_y = -INF
	return {"caught": false, "t": t}


## An NPC hunter of mass pm * big_r attacks the player as the AI's hunters
## do (the duel geometry: 55-90% of its hunting range away, raptors from
## 25-45 m above in half the trials) with SimBrains' pursuit, stoop, lunge
## and give-up rules; the player cruises until the danger cue reaches the
## skill's awareness threshold, then evades. Returns {escaped, t}.
func escape_trial(pm: float, big_r: float, skill: StringName, seed_: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var pilot := _pilot(skill, seed_ * 13 + 5)
	_begin(pm)
	loop.assist_override = 0.0
	player.brain = {}
	_setup_npc(other, pm * big_r, rng)
	other.brain["hunger"] = 1.0
	var origin := Vector3(0, 200, 0)
	_place(player, origin, Vector3.FORWARD.rotated(Vector3.UP, rng.randf_range(-PI, PI)), player.cruise_speed())
	var d0 := maxf(AiMirror.hunt_range_m(other.species), 10.0 * other.get_wingspan()) * rng.randf_range(0.55, 0.9)
	var bearing := rng.randf() * TAU
	var height := rng.randf_range(-5.0, 10.0)
	if AiMirror.stoops(other.species) and rng.randf() < 0.5:
		height = rng.randf_range(25.0, 45.0)
	var hp := origin + Vector3(cos(bearing) * d0, height, sin(bearing) * d0)
	var to := origin - hp
	to.y = 0.0
	_place(other, hp, to.normalized(), other.cruise_speed())
	loop.step(DT)
	SimBrains.start_hunt(other, player)
	var birds: Array[Bird] = [player, other]
	var t := 0.0
	while t < 60.0:
		t += DT
		var why := SimBrains.step_npc(other, DT, rng, false, birds, hp, 1000.0, false, false)
		if why != "":
			return {"escaped": true, "t": t, "why": why}
		var aware := false
		if npc_player:
			# Diagnostic: the player's bird flees as an AI bird would.
			aware = SimBrains.threat_level(player, other, other.global_position - player.global_position, false) >= AiMirror.FLEE_LEVEL \
					or player.brain.get("fleeing", false)
			if aware:
				player.brain["fleeing"] = true
				player.brain["t"] = float(player.brain.get("t", 0.0)) + DT
				SimBrains.flee(player, other, DT, rng)
			else:
				pilot.cruise(player, DT)
		else:
			aware = not unaware and pilot.aware_of(loop.watch, player)
			if aware:
				pilot.evade(player, other, DT)
			else:
				pilot.cruise(player, DT)
		loop.step(DT)
		if trace:
			var dd := other.global_position.distance_to(player.global_position)
			print("[gameloop] t=%.2f d=%.2f aware=%s ttc=%.2f brk=%.2f v_p=%.1f v_h=%.1f e_h=%.2f stoop=%s y=%.1f/%.1f hd=%s | p: cr %.1f osp %.1f eff %.2f fold %.2f gam %.2f m %.3f sp %s | h: cr %.1f osp %.1f eff %.2f oeff %.2f m %.3f sp %s" % [t, dd, aware,
				loop.watch.predator_ttc, pilot._break_left, player.speed, other.speed, other.energy, other.brain.get("stoop", false),
				player.global_position.y, other.global_position.y, player.heading.snappedf(0.01),
				player.cruise_speed(), player.o_speed, player.flight.effort, player.flight.fold, player.flight.gamma, player.mass, player.species,
				other.cruise_speed(), other.o_speed, other.flight.effort, other.o_eff, other.mass, other.species])
		if _caught_player:
			return {"escaped": false, "t": t, "passes": int(other.brain.get("passes", 0))}
	return {"escaped": true, "t": t}


## n hunt trials -> {p, t_catch (mean s of successful chases), t_all (mean s)}.
func measure_hunt(pm: float, r: float, skill: StringName, n: int, seed_: int, assist: float = 0.0) -> Dictionary:
	var ok := 0
	var tc := 0.0
	var ta := 0.0
	for i in n:
		var res := hunt_trial(pm, r, skill, seed_ + i * 101, assist)
		ta += res["t"]
		if res["caught"]:
			ok += 1
			tc += res["t"]
	return {"p": float(ok) / n, "t_catch": tc / maxf(ok, 1), "t_all": ta / n}


func measure_escape(pm: float, big_r: float, skill: StringName, n: int, seed_: int) -> Dictionary:
	var ok := 0
	var ta := 0.0
	for i in n:
		var res := escape_trial(pm, big_r, skill, seed_ + i * 103)
		ta += res["t"]
		if res["escaped"]:
			ok += 1
	return {"p": float(ok) / n, "t_all": ta / n}
