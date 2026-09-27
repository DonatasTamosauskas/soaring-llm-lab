class_name SimEcosystem
extends Node3D
## A stand-in for the AI area's Ecosystem, for the integrated pacing sim and
## the game-loop dev scene. Keeps EcosystemPlan's population (a mirror of the
## AI area's plan) around the player within the same metric radii, re-plans
## as the player grows, recycles eaten or distant birds, and flies them with
## SimBrains (a mirror of the AI's NpcBrain) on SimFlight (a copy of the AI's
## NPC physics) over flat ground: every species travels in its own altitude
## band (raptors high, small birds low, as in the AI's profiles), hunts what
## is worth it when hungry - the player included, with the AI's extra
## interest in it - flees what hunts it, and wanders when calm.
##
## Level of detail as in the AI's Ecosystem: birds within LOD_NEAR of the
## player think every 0.2 s, further ones every 0.35 / 0.6 s, and anything
## hunting or fleeing every 0.1 s; calm birds beyond LOD_NEAR fly every
## second or third step with the step's time (what the AI does), so a
## 60-bird sky stays affordable at the physics rate.
##
## Joins group "ecosystem" and implements reset()/stats() like the real one.

## Metric radii, as the AI area's Ecosystem (m).
@export var home_radius := 140.0
@export var spawn_min := 70.0
@export var spawn_max := 230.0
@export var despawn_radius := 380.0
## Give birds BirdModels (dev scene) or not (headless sims).
@export var with_models := false
## Height of the flat ground (m); -INF flies everything in open air around
## the player's height (the old sims' sky, kept for comparisons).
@export var ground_y := 0.0

## Re-plan the population this often (s).
const REPLAN_S := 2.0
## Half-angle of the player's view the AI keeps spawns out of.
const VIEW_HALF_DEG := 75.0
## The AI Ecosystem's LOD radii (m) and think intervals (s) per LOD.
const LOD_NEAR := 80.0
const LOD_FAR := 200.0
const THINK_S: Array[float] = [0.2, 0.35, 0.6]

var rng := RandomNumberGenerator.new()
var birds: Array[SimBird] = []
var spawned := 0
var recycled := 0
var npc_catches := 0
## Energy of calm birds, sampled every 2 s (compare with the AI's, AiMirror).
var calm_energy: Array[float] = []
var _sample_t := 0.0
## Hunts started on the player (the integrated sim's emergent attack count)...
var attacks_on_player := 0
## ...hunts that got within striking distance of it (a real attack run)...
var close_attacks_on_player := 0
## ...and how hunts on the player ended: {reason: count}.
var hunt_ends_on_player := {}
var _replan_t := 0.0
var _plan: Array[int] = []
var _apex := 0
var _steps := 0


func _enter_tree() -> void:
	add_to_group(&"ecosystem")


func _ready() -> void:
	Events.bird_caught.connect(_on_caught)


func _exit_tree() -> void:
	if Events.bird_caught.is_connected(_on_caught):
		Events.bird_caught.disconnect(_on_caught)


func _on_caught(pred: Bird, _prey: Bird) -> void:
	var sb := pred as SimBird
	if sb != null and not pred.is_player() and birds.has(sb):
		npc_catches += 1


func seed_rng(s: int) -> void:
	rng.seed = s


## New run: every bird re-drawn around the (reset) player.
func reset() -> void:
	npc_catches = 0
	calm_energy.clear()
	attacks_on_player = 0
	close_attacks_on_player = 0
	hunt_ends_on_player = {}
	_replan()
	while birds.size() < EcosystemPlan.MAX_NPCS:
		var b := SimBird.new()
		b.name = "Npc%d" % birds.size()
		add_child(b)
		birds.append(b)
	var queue := _species_queue()
	for i in birds.size():
		_respawn(birds[i], queue[i] if i < queue.size() else -1, true)


func stats() -> Dictionary:
	var by := {}
	for b in birds:
		if b.alive:
			by[b.species] = int(by.get(b.species, 0)) + 1
	return {"population": birds.size(), "by_species": by, "spawned": spawned, "recycled": recycled,
		"npc_catches": npc_catches, "attacks_on_player": attacks_on_player,
		"close_attacks_on_player": close_attacks_on_player, "hunt_ends_on_player": hunt_ends_on_player.duplicate()}


func _centre() -> Vector3:
	var p := Birds.player()
	return p.get_body_position() if p else Vector3(0, 30, 0)


func _player_mass() -> float:
	var p := Birds.player()
	return p.mass if p else GameLoop.START_MASS


func _replan() -> void:
	var pl := EcosystemPlan.plan(_player_mass())
	_plan = pl["counts"]
	_apex = pl["apex"]


## Species for each slot of the plan, in order (apex eagles as -2).
func _species_queue() -> Array[int]:
	var q: Array[int] = []
	for i in _plan.size():
		for k in _plan[i]:
			q.append(i)
	for k in _apex:
		q.append(-2)
	return q


## Species with the largest deficit against the plan (-2 = apex eagle).
func _most_needed() -> int:
	var have: Array[int] = []
	have.resize(_plan.size())
	have.fill(0)
	var apex_have := 0
	for b in birds:
		if not b.alive:
			continue
		if b.brain.get("apex", false):
			apex_have += 1
		else:
			have[SizeRules.species_index(b.species)] += 1
	var best := -1
	var best_def := 0
	for i in _plan.size():
		var d := _plan[i] - have[i]
		if d > best_def:
			best_def = d
			best = i
	if _apex - apex_have > best_def:
		return -2
	return best if best >= 0 else rng.randi_range(0, _plan.size() - 1)


func _respawn(b: SimBird, species: int = -1, anywhere: bool = false) -> void:
	var s := species if species != -1 else _most_needed()
	var apex := s == -2
	if apex:
		s = SizeRules.SPECIES.size() - 1
	var sd: Dictionary = SizeRules.SPECIES[s]
	b.species = sd["id"]
	b.mass = (_player_mass() * SizeRules.EAT_RATIO * 1.12) if apex else float(sd["mass"]) * rng.randf_range(0.92, 1.08)
	b.alive = true
	# The AI's birds, as measured: energy spread around 0.6, somewhat hungry.
	b.energy = AiMirror.spawn_energy(rng)
	b.brain = {"hunger": rng.randf_range(0.0, 0.6), "apex": apex, "think": rng.randf() * 0.2, "lod": 0,
		"flock": not apex and AiMirror.flocks(b.species)}
	b.ground_y = ground_y
	b.target = null
	if with_models:
		if b.model != null and b.model.get(&"species") != b.species:
			b.model.queue_free()
			b.model = null
		b.attach_model()
	# As the AI's Ecosystem: never nearer than spawn_min and never in the
	# player's view (at a run's start too - the sky fills in behind you).
	var c := _centre()
	var dist := rng.randf_range(spawn_min, home_radius if anywhere else spawn_max)
	var p := Birds.player()
	var look := p.get_forward() if p else Vector3.FORWARD
	look.y = 0.0
	look = look.normalized() if look.length_squared() > 1e-6 else Vector3.FORWARD
	var dir := Vector3.FORWARD.rotated(Vector3.UP, rng.randf_range(-PI, PI))
	for k in 8:
		if dir.dot(look) < cos(deg_to_rad(VIEW_HALF_DEG)):
			break
		dir = Vector3.FORWARD.rotated(Vector3.UP, rng.randf_range(-PI, PI))
	var pos := c + dir * dist
	if is_finite(ground_y):
		var band: Array = AiMirror.ALT[b.species]
		pos.y = ground_y + rng.randf_range(float(band[0]), float(band[1]))
	else:
		pos.y = c.y + rng.randf_range(-25.0, 25.0)
	b.global_position = pos
	b.speed = b.cruise_speed()
	b.set_heading(Vector3.FORWARD.rotated(Vector3.UP, rng.randf_range(-PI, PI)))
	b.velocity = b.heading * b.speed
	var loop := GameLoop.find(get_tree())
	if loop:
		loop.teleported(b)
	spawned += 1


## One simulation step for every NPC.
func step(dt: float) -> void:
	_steps += 1
	var centre := _centre()
	var home := Vector3(centre.x, ground_y if is_finite(ground_y) else centre.y, centre.z)
	var far2 := despawn_radius * despawn_radius
	_replan_t -= dt
	if _replan_t <= 0.0:
		_replan_t = REPLAN_S
		_replan()
		_rebalance(centre)
	var all := Birds.all()
	var p := Birds.player()
	_sample_t -= dt
	if _sample_t <= 0.0:
		_sample_t = 2.0
		for b in birds:
			if b.alive and b.brain.get("prey") == null and b.brain.get("threat") == null:
				calm_energy.append(b.energy)
	for bi in birds.size():
		var b := birds[bi]
		var off := b.global_position - centre
		var h2 := off.x * off.x + off.z * off.z
		if not b.alive or h2 > far2:
			if not b.alive:
				recycled += 1
			_respawn(b)
			continue
		var st := b.brain
		var engaged: bool = st.get("prey") != null or st.get("threat") != null or st.get("cand") != null
		var lod := 0 if h2 < LOD_NEAR * LOD_NEAR else (1 if h2 < LOD_FAR * LOD_FAR else 2)
		# Calm far birds fly every (lod + 1)-th step with the whole time.
		var every := 1 if engaged or lod == 0 else lod + 1
		var acc: float = float(st.get("acc", 0.0)) + dt
		# Phase by the bird's slot, never by engine ids (those depend on what
		# the process allocated before: a run must depend on its seed only).
		if (_steps + bi) % every != 0:
			st["acc"] = acc
			continue
		st["acc"] = 0.0
		var think: float = float(st.get("think", 0.0)) - acc
		var scan := think <= 0.0
		if scan:
			think = SimBrains.SCAN_S if engaged else THINK_S[lod]
		st["think"] = think
		var hunting_player: bool = p != null and st.get("prey") == p
		var why := SimBrains.step_npc(b, acc, rng, scan, all, home, home_radius)
		if p != null:
			if not hunting_player and st.get("prey") == p:
				attacks_on_player += 1
				st["close_on_player"] = false
			if st.get("prey") == p and not st.get("close_on_player", false) \
					and b.global_position.distance_to(p.get_body_position()) < AiMirror.strike_reach(b.get_wingspan()) * 2.0:
				st["close_on_player"] = true
				close_attacks_on_player += 1
			if hunting_player and why != "":
				hunt_ends_on_player[why] = int(hunt_ends_on_player.get(why, 0)) + 1


## Moves one surplus bird (far from the player) into the species most
## needed, so the population follows the player's growth.
func _rebalance(centre: Vector3) -> void:
	var need := _most_needed()
	if need == -1:
		return
	var have := {}
	for b in birds:
		if b.alive:
			have[b.species] = int(have.get(b.species, 0)) + 1
	for b in birds:
		if not b.alive or b.brain.get("apex", false):
			continue
		var i := SizeRules.species_index(b.species)
		if int(have.get(b.species, 0)) > _plan[i] and b.global_position.distance_to(centre) > spawn_min:
			_respawn(b, need)
			return
