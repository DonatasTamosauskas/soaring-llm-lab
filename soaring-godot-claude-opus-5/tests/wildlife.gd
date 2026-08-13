extends SceneTree

## Photographs the sky doing its own thing.
##
##   godot --xr-mode off --script res://tests/wildlife.gd -- --out=/tmp/wild
##   godot --xr-mode off --script res://tests/wildlife.gd -- --shot=roost --warmup=240
##
## `tests/ecosystem.gd` counts what the flock does; this is how it was actually
## checked. It runs the real [EcosystemSim] over the real world for a few
## simulated minutes, then finds the interesting bird — the one on a branch with
## the most neighbours, the one circling in the strongest lift, the one closing
## on something — and points a camera at it.
##
## Shots (`--shot=` takes any one of them, default is all):
##   roost     a perched bird, from a bird's distance
##   roost-air the same roost seen from the air, where a player would see it
##   thermal   a bird circling in lift, with the cloud that marks it
##   chase     a hunter and its quarry, from behind the hunter
##   flock     the whole flock from above, spread over the arena

const SETTLE_FRAMES: int = 6
const SHOTS: Array = [
	["roost", "_shot_roost"],
	["roost-air", "_shot_roost_air"],
	["thermal", "_shot_thermal"],
	["chase", "_shot_chase"],
	["flock", "_shot_flock"],
]

var _camera: Camera3D
var _world: WorldBuilder
var _sim: EcosystemSim
var _queue: Array = []
var _index: int = -1
var _wait: int = 0
var _out: String = "/tmp/wildlife"
var _only: String = ""
var _warmup: float = 200.0
var _hour: Palette.Hour = Palette.Hour.MORNING


func _process(_delta: float) -> bool:
	if _camera == null:
		_setup()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _index >= 0:
		var image: Image = get_root().get_texture().get_image()
		image.save_png("%s-%s.png" % [_out, _queue[_index][0]])
		print("[wildlife] %s-%s.png" % [_out, _queue[_index][0]])
	_index += 1
	if _index >= _queue.size():
		return true
	call(_queue[_index][1])
	_wait = SETTLE_FRAMES
	return false


func _setup() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() != 2:
			continue
		match parts[0]:
			"out":
				_out = parts[1]
			"shot":
				_only = parts[1]
			"warmup":
				_warmup = parts[1].to_float()
			"sky":
				_hour = Palette.hour_named(parts[1])

	var environment := WorldEnvironment.new()
	environment.environment = Palette.environment(_hour)
	get_root().add_child(environment)
	get_root().add_child(Palette.sun(_hour))

	_world = WorldBuilder.new()
	_world.hour = _hour
	get_root().add_child(_world)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.near = 0.05
	_camera.far = 4000.0
	get_root().add_child(_camera)
	_camera.current = true

	# The birds are in the tree so their rigs exist and their positions are real,
	# but they are stepped by hand: this is a photograph of a simulation, not of
	# whatever the renderer's frame rate happened to produce.
	_sim = EcosystemSim.new()
	_sim.setup(_world, 26, 20260813)
	_sim.hurry_rest()
	_sim.run(_warmup)
	print("[wildlife] %.0f s simulated: %d down, %d landings, %d catches" % [
		_warmup, _sim.flock.roosting(), _sim.flock.landings, _sim.flock.catches
	])

	for shot: Array in SHOTS:
		if _only.is_empty() or _only == shot[0]:
			_queue.append(shot)


# --- finding the interesting bird -------------------------------------------------

## The perched bird with the most company. A roost is a place, and the shot
## should be of the place rather than of whichever bird happens to be first in
## the array.
func _busiest_roost() -> BirdNPC:
	var best: BirdNPC = null
	var best_company: int = -1
	for bird: BirdNPC in _sim.birds:
		if not bird.is_perched():
			continue
		var company: int = 0
		for other: BirdNPC in _sim.birds:
			if other != bird and other.is_perched() \
					and other.at().distance_to(bird.at()) < 70.0:
				company += 1
		if company > best_company:
			best_company = company
			best = bird
	return best


func _in_state(which: BirdNPC.State) -> BirdNPC:
	var best: BirdNPC = null
	var best_score: float = -INF
	for bird: BirdNPC in _sim.birds:
		if bird.state != which:
			continue
		# For a thermal, the strongest lift; for anything else, the biggest bird,
		# which is the one worth looking at.
		var score: float = _world.wind_at(bird.at()).y if which == BirdNPC.State.SOAR else bird.size
		if score > best_score:
			best_score = score
			best = bird
	return best


func _closest_chase() -> Array[BirdNPC]:
	var pair: Array[BirdNPC] = []
	var best: float = 120.0
	for bird: BirdNPC in _sim.birds:
		if bird.state != BirdNPC.State.HUNT and bird.state != BirdNPC.State.STALK:
			continue
		if bird._focus == null or not is_instance_valid(bird._focus):
			continue
		var quarry: BirdNPC = bird._focus as BirdNPC
		if quarry == null:
			continue
		var distance: float = bird.at().distance_to(quarry.at())
		if distance < best:
			best = distance
			pair = [bird, quarry]
	return pair


# --- the shots ---------------------------------------------------------------------

func _shot_roost() -> void:
	var bird: BirdNPC = _busiest_roost()
	if bird == null:
		print("[wildlife] nothing is perched — skipping the roost shot")
		return
	_camera.fov = 55.0
	# Outward from the middle of the world, because a bird on a window sill is
	# against a wall and a camera placed at a fixed diagonal ends up inside it.
	var out := Vector3(bird.at().x, 0.0, bird.at().z).normalized()
	if out.length_squared() < 0.5:
		out = Vector3(1.0, 0.0, 0.0)
	var reach: float = 4.5 * maxf(bird.size, 0.8)
	_look(bird.at() + out * reach + Vector3.UP * reach * 0.35, bird.at())


func _shot_roost_air() -> void:
	var bird: BirdNPC = _busiest_roost()
	if bird == null:
		return
	_camera.fov = 70.0
	var out := Vector3(bird.at().x, 0.0, bird.at().z).normalized()
	if out.length_squared() < 0.5:
		out = Vector3(1.0, 0.0, 0.0)
	_look(bird.at() + out * 17.0 + Vector3.UP * 11.0, bird.at())


func _shot_thermal() -> void:
	var bird: BirdNPC = _in_state(BirdNPC.State.SOAR)
	if bird == null:
		print("[wildlife] nothing is circling — skipping the thermal shot")
		return
	_camera.fov = 62.0
	# Level with the bird and a little below, so the cloud capping the core is in
	# the frame above it: that pairing is the whole reason both exist.
	_look(bird.at() + Vector3(15.0, -3.0, 15.0), bird.at() + Vector3.UP * 8.0)


func _shot_chase() -> void:
	var pair: Array[BirdNPC] = _closest_chase()
	if pair.is_empty():
		print("[wildlife] nobody is hunting — skipping the chase shot")
		return
	_camera.fov = 60.0
	var hunter: BirdNPC = pair[0]
	var quarry: BirdNPC = pair[1]
	var behind: Vector3 = -hunter.model.velocity.normalized() * 16.0 + Vector3.UP * 4.0
	_look(hunter.at() + behind, quarry.at())


## The tightest group in the sky, not the average of every bird in the arena:
## the flock spreads over six hundred metres, so the centroid is usually a patch
## of empty grass — and, the first time this was rendered, the inside of a cloud.
func _shot_flock() -> void:
	var best: BirdNPC = null
	var best_company: int = -1
	var centre := Vector3.ZERO
	for bird: BirdNPC in _sim.birds:
		var company: int = 0
		var sum: Vector3 = bird.at()
		for other: BirdNPC in _sim.birds:
			if other != bird and other.at().distance_to(bird.at()) < 130.0:
				company += 1
				sum += other.at()
		if company > best_company:
			best_company = company
			best = bird
			centre = sum / float(company + 1)
	if best == null:
		return
	_camera.fov = 72.0
	print("[wildlife] tightest group: %d birds within 130 m" % (best_company + 1))
	_look(centre + Vector3(60.0, 46.0, 60.0), centre)


func _look(from: Vector3, at: Vector3) -> void:
	_camera.global_position = from
	_camera.look_at(at, Vector3.UP)
