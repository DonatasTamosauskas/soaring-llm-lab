extends TestCase
## Shared helpers for AI suites: build the AI test world, an ecosystem or
## loose NPCs, and step them manually (many simulated minutes per real
## second) with the stand-in catch checker. Not a suite itself (no _test.gd).

const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const EcoScene := preload("res://scenes/ai/ecosystem.tscn")
const DT := 1.0 / 72.0

var world: AiTestWorld = null
var eco: Ecosystem = null
var checker: RefCounted = null
var loose: Array[NpcBird] = []
var _seed := 1000


## The evidence mode (--ai_full=1): the long, many-case versions of the
## statistical tests. The default suite runs shorter versions of the same
## scenarios with the same assertions, to stay quick.
static func full() -> bool:
	return Paths.arg("ai_full", "") != ""


## The AI arena. Static bodies need a couple of physics frames before ray
## queries see them.
func make_world(visuals := false, flat_seed := 1) -> AiTestWorld:
	var w := AiTestWorld.new()
	w.world_seed = flat_seed
	w.with_visuals = visuals
	w.with_environment = false
	add_child(w)
	await wait_physics(3)
	world = w
	return w


## A plain flat world without geometry (base World), for open-air duels.
func make_open_world() -> World:
	var w := World.new()
	w.bounds_radius = 1500.0
	w.ceiling = 600.0
	add_child(w)
	await wait_physics(2)
	return w


func make_eco(max_npcs := 60, seed_value := 1) -> Ecosystem:
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.max_npcs = max_npcs
	e.rng_seed = seed_value
	add_child(e)
	eco = e
	return e


func spawn(species: StringName, pos: Vector3, vel: Vector3 = Vector3.ZERO, w: World = null) -> NpcBird:
	var n := NpcBird.new()
	n.managed = true
	_seed += 17
	n.configure(species, -1.0, _seed, Habitat.for_world(w if w else world))
	n.energy = 1.0
	n.hunger = 0.0
	add_child(n)
	n.global_position = pos
	var v := vel if vel != Vector3.ZERO else Vector3(0, 0, -n.flight.cruise)
	n.flight.set_velocity(v)
	n.velocity = v
	n.global_transform = Transform3D(Basis.looking_at(v.normalized(), Vector3.UP), pos)
	loose.append(n)
	return n


## Remove a loose bird now (queue_free alone would leave it registered with
## Birds - and visible to every other bird - until the frame ends).
func despawn(b: Node) -> void:
	loose.erase(b)
	if is_instance_valid(b):
		if b.get_parent():
			b.get_parent().remove_child(b)
		b.queue_free()


func make_checker() -> RefCounted:
	checker = CatchChecker.new()
	return checker


## Drive the world's air (thermal drift and pulse, gusts) from simulated
## time. The valley (SoaringWorld) otherwise advances it on real physics
## frames, which a manually stepped simulation does not follow: the same
## seed then met different air depending on how many frames earlier tests
## took, and valley runs were not reproducible from the seed. Worlds
## without moving air ignore it.
static func air(w: World, sim_t: float) -> void:
	if w != null and w.has_method(&"set_air_time"):
		w.call(&"set_air_time", sim_t)


## Step loose NPCs (and the ecosystem, if any) for `seconds` of sim time.
## per_tick(i) runs after each tick; return true from it to stop early.
func run(seconds: float, per_tick: Callable = Callable()) -> int:
	var n := int(round(seconds / DT))
	for i in n:
		for b in loose:
			if is_instance_valid(b) and b.alive and b.is_inside_tree():
				b.tick(DT)
		if eco:
			eco.step(DT)
		if checker:
			checker.step(DT)
		if per_tick.is_valid() and per_tick.call(i):
			return i + 1
	return n


func clear_sim() -> void:
	for b in loose:
		if is_instance_valid(b):
			b.queue_free()
	loose.clear()
	if eco and is_instance_valid(eco):
		eco.queue_free()
	eco = null
	if world and is_instance_valid(world):
		world.queue_free()
	world = null
	checker = null
	Habitat.clear_cache()
	await wait_frames(2)


## Is pos inside any layer-1 convex collider (terrain is handled separately)?
func inside_geometry(pos: Vector3) -> bool:
	var s := world.get_world_3d().direct_space_state
	var q := PhysicsPointQueryParameters3D.new()
	q.position = pos
	q.collision_mask = 1
	q.collide_with_areas = false
	return not s.intersect_point(q, 1).is_empty()
