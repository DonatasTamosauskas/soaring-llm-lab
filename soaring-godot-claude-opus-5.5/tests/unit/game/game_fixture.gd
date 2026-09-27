extends TestCase
## Shared helpers for the game-loop suites (not a suite itself: the runner
## only picks up *_test.gd). Builds a GameLoop that is stepped by hand, and
## SimBirds (core-contract-only stand-ins for PlayerBird / NpcBird).

## Per process: every sandbox shares one user:// directory (same project
## name), and concurrent runs must not read each other's records.
var test_records_path := "user://gameloop_test_records_%d.json" % OS.get_process_id()

var loop: GameLoop
var birds: Array[SimBird] = []
## Recorded Events: [[name, args...], ...]
var ev_log: Array = []


## A Node3D with the BirdModel fields the loop writes (tests need no art).
class FakeModel extends Node3D:
	var highlight := 0
	var flap_phase := 0.0
	var flap_amount := 0.0
	var wing_fold := 0.0


## `warn`: the attack warning's floor (ThreatWatch.warn_level: a bird
## hunting the player is shown at 0.35 at least within ~60 m) is on. Off by
## default in these suites: most of them pin the time-to-contact rules
## underneath it (levels rising as a hunter closes, naming, jinks), with
## hunters that all hunt the player; the tests of the warning, of the danger
## marks and a busy sky's invariants switch it on.
func make_loop(start: bool = false, warn: bool = false) -> GameLoop:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_records_path))
	loop = GameLoop.new()
	loop.auto_step = false
	loop.records_path = test_records_path
	loop.npc_spawn_grace_s = 0.0
	if not warn:
		loop.watch.warn_level = 0.0
	# Thousands of runs start and end in these suites: keep the log readable.
	loop.verbose = false
	add_child(loop)
	if start:
		loop.start_run()
	return loop


## A bird of `mass` at pos, facing `facing` (default -Z), optionally the player.
func make_bird(mass: float, pos: Vector3, facing: Vector3 = Vector3.FORWARD, player: bool = false,
		with_model: bool = false) -> SimBird:
	var b := SimBird.new()
	b.player_mode = player
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	b.name = "%s_%d" % ["Player" if player else "Bird", birds.size()]
	if with_model:
		b.model = FakeModel.new()
		b.add_child(b.model)
	add_child(b)
	b.global_position = pos
	b.set_heading(facing)
	# A predator of the player in these suites is hunting it (the threat
	# cue reads intent from `target`; tests of intent itself reset it).
	var pl := Birds.player()
	if not player and pl != null and SizeRules.can_eat(mass, pl.mass):
		b.target = pl
	birds.append(b)
	return b


func move(b: SimBird, pos: Vector3, vel: Vector3 = Vector3.INF) -> void:
	if vel != Vector3.INF:
		b.velocity = vel
	b.global_position = pos


func start_logging() -> void:
	ev_log.clear()
	Events.bird_caught.connect(_on_caught)
	Events.player_caught.connect(_on_player_caught)
	Events.player_grew.connect(_on_grew)
	Events.player_tier_changed.connect(_on_tier)
	Events.threat_changed.connect(_on_threat)
	Events.target_changed.connect(_on_target)
	Events.run_started.connect(_on_run_started)
	Events.run_ended.connect(_on_run_ended)


func stop_logging() -> void:
	for pair in [[Events.bird_caught, _on_caught], [Events.player_caught, _on_player_caught],
			[Events.player_grew, _on_grew], [Events.player_tier_changed, _on_tier],
			[Events.threat_changed, _on_threat], [Events.target_changed, _on_target],
			[Events.run_started, _on_run_started], [Events.run_ended, _on_run_ended]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func count(event: String) -> int:
	var n := 0
	for e: Array in ev_log:
		if e[0] == event:
			n += 1
	return n


func events(event: String) -> Array:
	var out := []
	for e: Array in ev_log:
		if e[0] == event:
			out.append(e)
	return out


func _on_caught(pred: Bird, prey: Bird) -> void:
	ev_log.append(["caught", pred, prey])


func _on_player_caught(pred: Bird) -> void:
	ev_log.append(["player_caught", pred])


func _on_grew(old: float, new: float, tier: int) -> void:
	ev_log.append(["grew", old, new, tier])


func _on_tier(old: int, new: int) -> void:
	ev_log.append(["tier", old, new])


func _on_threat(level: float, pred: Bird) -> void:
	ev_log.append(["threat", level, pred])


func _on_target(prey: Bird) -> void:
	ev_log.append(["target", prey])


func _on_run_started() -> void:
	ev_log.append(["run_started"])


func _on_run_ended(summary: Dictionary) -> void:
	ev_log.append(["run_ended", summary])


## Frees every bird and the loop, restores global state for the next test.
func cleanup() -> void:
	stop_logging()
	for b in birds:
		if is_instance_valid(b):
			b.queue_free()
	birds.clear()
	if loop and is_instance_valid(loop):
		loop.queue_free()
	loop = null
	get_tree().paused = false
	await get_tree().process_frame
	if Game.state != Game.State.MENU:
		Game.set_state(Game.State.MENU)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_records_path))


func after_each() -> void:
	await cleanup()


## Steps the loop n times with dt, calling mover(i) before each step.
func run_steps(n: int, dt: float, mover: Callable = Callable()) -> void:
	for i in n:
		if mover.is_valid():
			mover.call(i)
		loop.step(dt)
