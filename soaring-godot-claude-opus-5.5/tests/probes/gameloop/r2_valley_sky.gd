extends Node
## Verifier round 2 helper (not a suite): the AI's real Ecosystem in the
## WORLD AREA's shipped valley (scenes/world/world.tscn, SoaringWorld) instead
## of the AI's own AiTestWorld - the same duck-typed sky interface as
## tests/shots/gameloop_live_sky.gd, so IntegratedSim can run whole runs in
## the world the game actually ships with.

const EcoScene := preload("res://scenes/ai/ecosystem.tscn")
const WorldScene := preload("res://scenes/world/world.tscn")
const SAMPLE_S := 2.0

var ground_y := 0.0
var bounds_radius := INF
var attacks_on_player := 0
var close_attacks_on_player := 0
var hunt_ends_on_player := {}
var npc_catches := 0
var calm_energy: Array[float] = []

var world: World
var eco: Ecosystem
var _sample_t := 0.0
var _close := {}


func _ready() -> void:
	world = WorldScene.instantiate() as World
	if "with_environment" in world:
		world.set(&"with_environment", false)
	if "with_decoration" in world:
		world.set(&"with_decoration", false)
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


func prepare() -> void:
	for i in 3:
		await get_tree().physics_frame


func seed_rng(s: int) -> void:
	eco.reset(s)
	attacks_on_player = 0
	close_attacks_on_player = 0
	hunt_ends_on_player = {}
	npc_catches = 0
	calm_energy.clear()
	_close.clear()
	_sample_t = 0.0


func step(dt: float) -> void:
	var p := Birds.player()
	if p is SimBird:
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


func _on_bird_caught(pred: Bird, _prey: Bird) -> void:
	if pred != null and not pred.is_player():
		npc_catches += 1
