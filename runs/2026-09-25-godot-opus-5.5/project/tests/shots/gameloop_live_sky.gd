extends Node
## The AI area's real sky, for IntegratedSim (the pacing tool's --live_ai):
## its Ecosystem populating a world around the player, behind the duck-typed
## sky interface IntegratedSim runs on (see IntegratedSim.eco).
##
## world_kind:
##  * &"valley" (the evidence): the world area's shipped valley
##    (scenes/world/world.tscn, SoaringWorld) - its refuges, perches,
##    thermals, bounds and colliders. The modelled player collides with the
##    valley's static geometry and steers round it (SimBird.collide_world).
##  * &"ai_test": the AI area's own AiTestWorld (the sky of fix round 1's
##    evidence; kept for comparison).
## A tool, not a test dependency: it runs the AI's and the world's
## in-progress code at the time of the run, and the evidence it writes
## records a hash of that code (tests/shots/gameloop_pacing.gd).

const EcoScene := preload("res://scenes/ai/ecosystem.tscn")
const WorldScene := preload("res://scenes/world/world.tscn")
## Calm-energy samples every this many seconds (as SimEcosystem).
const SAMPLE_S := 2.0

## Set before adding to the tree.
var world_kind: StringName = &"valley"

# --- Read by IntegratedSim ---------------------------------------------------
var ground_y := 0.0
var bounds_radius := INF
## The world has solid geometry the modelled player must fly round.
var solid_world := false
var attacks_on_player := 0
var close_attacks_on_player := 0
var hunt_ends_on_player := {}
var npc_catches := 0
var calm_energy: Array[float] = []
## Catches of birds that were hiding (none can happen: CatchRule.is_hidden).
var hidden_catches := 0

var world: World
var eco: Ecosystem
var _sample_t := 0.0
## Hunter instance id -> whether its current hunt on the player got close.
var _close := {}


func _ready() -> void:
	if world_kind == &"ai_test":
		var w := AiTestWorld.new()
		w.world_seed = 1
		w.with_visuals = false
		w.with_environment = false
		world = w
	else:
		world = WorldScene.instantiate() as World
		# Simulation only: no sky/sun, no grass, flowers, clouds or motes
		# (colliders, refuges, perches and thermals are all still built).
		if &"with_environment" in world:
			world.set(&"with_environment", false)
		if &"with_decoration" in world:
			world.set(&"with_decoration", false)
		solid_world = true
	add_child(world)
	bounds_radius = world.bounds_radius
	var sp := world.get_player_spawn().origin
	ground_y = world.ground_height(sp.x, sp.z)
	eco = EcoScene.instantiate() as Ecosystem
	eco.auto_step = false
	eco.max_npcs = 60
	eco.npc_spawned.connect(_on_spawned)
	add_child(eco)
	Events.bird_caught.connect(_on_bird_caught)


func _exit_tree() -> void:
	if Events.bird_caught.is_connected(_on_bird_caught):
		Events.bird_caught.disconnect(_on_bird_caught)


## The world's colliders and the ecosystem settle over a few physics frames
## (as in the AI's own tests).
func prepare() -> void:
	for i in 3:
		await get_tree().physics_frame


func seed_rng(s: int) -> void:
	eco.reset(s)
	attacks_on_player = 0
	close_attacks_on_player = 0
	hunt_ends_on_player = {}
	npc_catches = 0
	hidden_catches = 0
	calm_energy.clear()
	_close.clear()
	_sample_t = 0.0


func step(dt: float) -> void:
	var p := Birds.player()
	if p is SimBird:
		# The world has hills: the modelled player keeps its height above the
		# ground under it, as a person does.
		var pp := p.global_position
		(p as SimBird).ground_y = world.ground_height(pp.x, pp.z)
	eco.step(dt)
	_sample_t -= dt
	var sample := _sample_t <= 0.0
	if sample:
		_sample_t = SAMPLE_S
	for npc in eco.get_npcs():
		if not npc.alive:
			continue
		if sample and not npc.is_engaged():
			calm_energy.append(npc.energy)
		if p != null and npc.target == p and (npc.state == NpcBird.State.HUNT or npc.state == NpcBird.State.STOOP):
			var id := npc.get_instance_id()
			if not bool(_close.get(id, false)) \
					and npc.global_position.distance_to(p.get_body_position()) < AiMirror.strike_reach(npc.get_wingspan()) * 2.0:
				_close[id] = true
				close_attacks_on_player += 1


func _on_spawned(npc: NpcBird) -> void:
	if not npc.behaviour.is_connected(_on_behaviour):
		npc.behaviour.connect(_on_behaviour)


func _on_behaviour(b: NpcBird, what: StringName) -> void:
	var p := Birds.player()
	if what == &"hunt" and p != null and b.target == p:
		attacks_on_player += 1
		_close[b.get_instance_id()] = false


func _on_bird_caught(pred: Bird, prey: Bird) -> void:
	if pred != null and not pred.is_player():
		npc_catches += 1
	if prey is NpcBird and (prey as NpcBird).hidden:
		hidden_catches += 1
