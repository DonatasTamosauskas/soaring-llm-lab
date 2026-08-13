extends SceneTree

## Photographs birds.
##
##   godot --xr-mode off --script res://tests/aviary.gd -- --out=/tmp/aviary
##   godot --xr-mode off --script res://tests/aviary.gd -- --shot=cycle
##
## `--capture` photographs the running game from the player's own eyes, which is
## the one place a bird is never still, never close and never at a chosen angle.
## Judging a silhouette needs the opposite: the same bird, at a known distance,
## at a known point in its wingbeat, against the sky. Every art decision in
## [BirdMesh] and [BirdPose] was made by reading these back.
##
## Shots (`--shot=` takes any one of them, default is all):
##   species   all five silhouettes at one size, broadside
##   sizes     the size ladder as the player meets it — smallest to biggest
##   cycle     one wingbeat, six frames
##   angles    one bird from the front, the side, above and below
##   distance  the same bird at 15, 40, 100 and 220 m
##   threat    prey, neutral and predator tints on one shape
##   player    the view down the player's own body, wings spread and tucked
##   colour    a bird beside a palette swatch of the same colour
##   wild      the size ladder in the real world, at real distances
##   flock     real BirdNPCs, flown by their own AI for three seconds first

const SETTLE_FRAMES: int = 6
## Mirrors [BirdPlayer]'s own body offsets. Duplicated rather than imported
## because a `--script` SceneTree run has no autoloads, so touching [BirdPlayer]
## from here drags in [Tuning] and fails to compile.
const BODY_DROP: float = 0.40
const BODY_BEHIND: float = 0.62
const SHOTS: Array = [
	["species", "_shot_species"],
	["sizes", "_shot_sizes"],
	["cycle", "_shot_cycle"],
	["angles", "_shot_angles"],
	["distance", "_shot_distance"],
	["threat", "_shot_threat"],
	["threat-far", "_shot_threat_far"],
	["player", "_shot_player"],
	["colour", "_shot_colour"],
	["wild", "_shot_wild"],
	["flock", "_shot_flock"],
]

var _stage: Node3D
var _camera: Camera3D
var _index: int = -1
var _wait: int = 0
var _out: String = "/tmp/aviary"
var _only: String = ""
var _hour: Palette.Hour = Palette.Hour.MORNING
var _queue: Array = []
var _world: WorldBuilder


func _process(_delta: float) -> bool:
	if _stage == null:
		_setup()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _index >= 0:
		var image: Image = get_root().get_texture().get_image()
		image.save_png("%s-%s.png" % [_out, _queue[_index][0]])
		print("[aviary] %s-%s.png" % [_out, _queue[_index][0]])
	_index += 1
	if _index >= _queue.size():
		return true
	_clear()
	_camera.fov = 70.0
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
			"sky":
				_hour = Palette.hour_named(parts[1])

	var environment := WorldEnvironment.new()
	environment.environment = Palette.environment(_hour)
	get_root().add_child(environment)
	get_root().add_child(Palette.sun(_hour))

	_stage = Node3D.new()
	get_root().add_child(_stage)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.near = 0.02
	_camera.far = 4000.0
	get_root().add_child(_camera)
	_camera.current = true

	for shot: Array in SHOTS:
		if _only.is_empty() or _only == shot[0]:
			_queue.append(shot)


func _clear() -> void:
	for child: Node in _stage.get_children():
		_stage.remove_child(child)
		child.queue_free()


# --- the shots ----------------------------------------------------------------

## Every silhouette at the same absolute size, so the shapes can be compared
## rather than the scales.
func _shot_species() -> void:
	var x: float = -7.0
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var rig: BirdRig = _bird(species, 1.0, Vector3(x, 0.0, 0.0))
		_glide(rig, 1.0)
		x += 3.5
	_look(Vector3(0.0, 2.6, 6.0), Vector3(0.0, -0.2, 0.0))


## The ladder the player actually climbs: what a bird of each size class looks
## like from one fixed viewpoint, all at the same distance.
func _shot_sizes() -> void:
	var sizes: PackedFloat32Array = [0.45, 0.9, 1.8, 3.4, 6.5]
	# On an arc, not a line: spread along x they sit at different distances from
	# the camera and the sheet compares perspective instead of birds.
	var eye := Vector3(0.0, 1.0, 0.0)
	for i in sizes.size():
		var size: float = sizes[i]
		var angle: float = lerpf(-0.42, 0.42, float(i) / 4.0)
		var rig: BirdRig = _bird(
			BirdMesh.species_for_size(size), size,
			eye + Vector3(sin(angle) * 46.0, -1.0, -cos(angle) * 46.0)
		)
		_glide(rig, 1.0)
	_look(eye, eye + Vector3(0.0, -1.0, -46.0))


## One wingbeat, sampled six times. The downstroke is the first third of the
## cycle, so the first two frames should be visibly further apart than the last.
func _shot_cycle() -> void:
	var x: float = -7.5
	for i in 6:
		var rig: BirdRig = _bird(BirdMesh.Species.CORVID, 1.0, Vector3(x, 0.0, 0.0))
		_beat_to(rig, float(i) / 6.0)
		x += 3.0
	_look(Vector3(0.0, 1.2, 9.0), Vector3(0.0, 0.0, 0.0))


func _shot_angles() -> void:
	var rig: BirdRig = _bird(BirdMesh.Species.RAPTOR, 1.0, Vector3.ZERO)
	_beat_to(rig, 0.55)
	_look(Vector3(0.0, 0.5, 4.2), Vector3.ZERO)
	_extra_views(rig)


## The whole point of a silhouette: does it still say "eagle" at two hundred
## metres, where it is twelve pixels tall?
func _shot_distance() -> void:
	var distances: PackedFloat32Array = [15.0, 40.0, 100.0, 220.0]
	for i in distances.size():
		# Fanned across the frame, or they line up one behind the other and the
		# sheet shows a single bird.
		var angle: float = lerpf(-0.30, 0.30, float(i) / 3.0)
		var rig: BirdRig = _bird(BirdMesh.Species.SEABIRD, 2.5, Vector3(
			sin(angle) * distances[i], 0.0, -cos(angle) * distances[i]
		))
		_beat_to(rig, 0.10 + 0.2 * float(i))
	_look(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -100.0))


func _shot_threat() -> void:
	var tints: Array = [
		[Palette.colour("threat_prey"), 0.55],
		[Palette.colour("threat_prey"), 0.0],
		[Palette.colour("threat_predator"), 0.8],
	]
	var x: float = -3.6
	for tint: Array in tints:
		var rig: BirdRig = _bird(BirdMesh.Species.FALCON, 1.0, Vector3(x, 0.0, 0.0))
		_glide(rig, 1.0)
		rig.set_threat(tint[0], tint[1])
		x += 3.6
	_look(Vector3(0.0, 1.6, 6.0), Vector3(0.0, 0.0, 0.0))


## The same three tints where the question is actually asked: forty metres away,
## over real ground, in real haze.
##
## Six metres tells you nothing about a signal colour. A tint has to survive a
## bird four pixels across against whatever happens to be behind it, and the
## thing behind it is usually a green hillside — which is why the prey tint was
## originally invisible and the predator tint was not.
func _shot_threat_far() -> void:
	if _world == null:
		_world = WorldBuilder.new()
		get_root().add_child(_world)
		_world.build()
	var tints: Array = [
		[Palette.colour("threat_prey"), BirdNPC_PREY_ENERGY],
		[Palette.colour("threat_prey"), 0.0],
		[Palette.colour("threat_predator"), BirdNPC_PREDATOR_ENERGY],
	]
	# Two rows: against the sky, and against the ground. A signal that only works
	# against one of them is half a signal.
	var eye := Vector3(0.0, 120.0, 90.0)
	var index: int = 0
	for tint: Array in tints:
		var angle: float = lerpf(-0.26, 0.26, float(index) / 2.0)
		for row in 2:
			var drop: float = -0.22 * 40.0 if row == 1 else 0.10 * 40.0
			var at: Vector3 = eye + Vector3(sin(angle) * 40.0, drop, -cos(angle) * 40.0)
			var rig: BirdRig = _bird(BirdMesh.Species.FALCON, 1.0, at)
			_glide(rig, 1.0)
			rig.set_threat(tint[0], tint[1])
		index += 1
	_look(eye, eye + Vector3(0.0, -4.0, -40.0))


## The energies [BirdNPC.show_threat] actually uses, duplicated for the same
## reason the body offsets above are: this file cannot touch [BirdNPC] at parse
## time.
const BirdNPC_PREY_ENERGY: float = 0.95
const BirdNPC_PREDATOR_ENERGY: float = 0.8


## What the player sees when they look down at themselves: their own body, their
## own tail, and a wing off each hand — spread on the left, tucked on the right.
func _shot_player() -> void:
	var body := BirdRig.new()
	_stage.add_child(body)
	body.build(BirdMesh.Species.FALCON, Palette.colour("plumage_player"), false, true)
	body.position = Vector3(0.0, -BODY_DROP, BODY_BEHIND)
	body.animate(0.0, 1.0, 0.2, 0.105, 0.105, 0.016)

	for side: float in [-1.0, 1.0]:
		var hand := Node3D.new()
		_stage.add_child(hand)
		# Roughly where a spread pair of arms puts a pair of controllers.
		hand.position = Vector3(side * 0.42, -0.18, 0.05)
		var wing := WingVisual.new()
		hand.add_child(wing)
		wing.build(side, Palette.colour("plumage_player"), BirdMesh.Species.FALCON)
		wing.set_span(1.0 if side < 0.0 else 0.0, 1.0, 0.0)

	# Looking down and a little back, which is where a player checks whether they
	# have a body: straight ahead is all sky and the body is behind the head. A
	# headset's field of view is far wider than a monitor's, so the camera is
	# widened to match or the frame lies about how much of the view this fills.
	_camera.fov = 100.0
	_look(Vector3(0.0, 0.0, 0.0), Vector3(0.0, -1.0, 0.55))


## Instance uniforms are a different path into the shader than a material
## parameter is, and the whole terrain was once four times too bright because a
## colour took the wrong one. Bird on the left, a plain palette material of the
## same colour on the right: if the two do not match, the birds are lying.
func _shot_colour() -> void:
	var rig: BirdRig = _bird(BirdMesh.Species.CORVID, 1.0, Vector3(-1.6, 0.0, 0.0))
	_glide(rig, 1.0)
	rig.set_plumage(Palette.colour("plumage_rust"))

	var swatch := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.4, 1.4, 1.4)
	swatch.mesh = box
	swatch.material_override = Palette.surface_material("plumage_rust")
	swatch.position = Vector3(1.8, 0.0, 0.0)
	_stage.add_child(swatch)
	_look(Vector3(0.0, 0.8, 5.0), Vector3(0.0, 0.0, 0.0))


## Against the sky a bird is a black shape and everything reads. The harder
## question is whether it still reads against a green hillside 90 m away, which
## is where most of this game's birds actually are. Real world, real haze, real
## distances, a bird from every size class.
func _shot_wild() -> void:
	if _world == null:
		_world = WorldBuilder.new()
		get_root().add_child(_world)
		_world.build()
	var sizes: PackedFloat32Array = [0.5, 1.0, 2.0, 4.0, 7.0]
	var distances: PackedFloat32Array = [22.0, 38.0, 60.0, 95.0, 150.0]
	# Fanned across the view so every one of them is in frame at its own range,
	# with the camera where a bird flying over the town actually is.
	var eye := Vector3(0.0, 108.0, 60.0)
	for i in sizes.size():
		var d: float = distances[i]
		var angle: float = lerpf(-0.32, 0.30, float(i) / 4.0)
		var at: Vector3 = eye + Vector3(sin(angle) * d, -0.06 * d, -cos(angle) * d)
		var rig: BirdRig = _bird(BirdMesh.species_for_size(sizes[i]), sizes[i], at)
		_beat_to(rig, 0.15 + 0.12 * float(i))
	_look(eye, eye + Vector3(0.0, -6.0, -60.0))


## The only shot nobody staged. Real [BirdNPC]s, configured the way
## [GameManager] configures them, then flown by their own [FlightModel] for three
## seconds before the shutter opens — so every wing angle in the frame is one the
## AI actually asked for, at whatever point in its own beat it happened to be.
func _shot_flock() -> void:
	if _world == null:
		_world = WorldBuilder.new()
		get_root().add_child(_world)
		_world.build()
	var eye := Vector3(40.0, 120.0, 120.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# Loaded at run time rather than named directly: [BirdNPC] reaches
	# [BirdPlayer], which reads the [Tuning] autoload, and a `--script` main loop
	# is compiled before autoloads exist. By the time this runs, they do.
	var script: GDScript = load("res://scripts/ai/BirdNPC.gd")
	var birds: Array[Node3D] = []
	for i in 14:
		var bird: Node3D = script.new()
		_stage.add_child(bird)
		if bird.get_child_count() == 0:
			bird._ready()
		var angle: float = rng.randf() * TAU
		var distance: float = rng.randf_range(14.0, 46.0)
		var size: float = rng.randf_range(0.4, 3.2)
		bird.configure(
			size,
			eye + Vector3(sin(angle) * distance, rng.randf_range(-12.0, 18.0), -distance),
			_world, 100 + i
		)
		birds.append(bird)
	# Their own AI, their own physics, no staging.
	for step in 130:
		for bird: Node3D in birds:
			bird._physics_process(1.0 / 90.0)
	# They go where they like, so the camera follows them rather than the other
	# way round.
	var centre := Vector3.ZERO
	for bird: Node3D in birds:
		centre += bird.position
	centre /= float(birds.size())
	_look(centre + Vector3(6.0, 6.0, 46.0), centre)


# --- staging ------------------------------------------------------------------

func _bird(species: BirdMesh.Species, size: float, at: Vector3) -> BirdRig:
	var scaler := Node3D.new()
	scaler.position = at
	scaler.scale = Vector3.ONE * size
	_stage.add_child(scaler)
	var rig := BirdRig.new()
	scaler.add_child(rig)
	rig.build(species, Palette.plumage(float(species) * 0.19))
	return rig


## Settle a rig into a steady glide at a given wing extension.
func _glide(rig: BirdRig, span: float) -> void:
	for i in 40:
		rig.animate(0.0, span, 0.0, 0.105, 0.105, 1.0 / 90.0)


## Run a rig up to a given point in its wingbeat and stop there. Effort has to
## reach full first or the frames are sampled out of a beat that is still
## growing, which is what made the first cycle sheet look shuffled.
func _beat_to(rig: BirdRig, phase: float) -> void:
	var step: float = 1.0 / 240.0
	for i in 900:
		rig.animate(3.2, 1.0, 0.0, 0.105, 0.105, step)
		if rig.pose.effort > 0.999:
			break
	var last: float = rig.pose.phase
	for i in 900:
		rig.animate(3.2, 1.0, 0.0, 0.105, 0.105, step)
		var now: float = rig.pose.phase
		# Stop the first time the phase passes the mark, wrap included.
		if (now >= phase and last < phase) or (now < last and phase <= now):
			return
		last = now


func _look(from: Vector3, at: Vector3) -> void:
	_camera.global_position = from
	_camera.look_at(at, Vector3.UP)


## Saves three more angles of the same subject alongside the main frame.
func _extra_views(rig: BirdRig) -> void:
	var views: Array = [
		["front", Vector3(0.0, 0.2, -4.0)],
		["above", Vector3(0.0, 4.0, 0.6)],
		["below", Vector3(0.0, -3.4, 1.4)],
	]
	for view: Array in views:
		_camera.global_position = view[1]
		_camera.look_at(Vector3.ZERO, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image: Image = get_root().get_texture().get_image()
		image.save_png("%s-angles-%s.png" % [_out, view[0]])
		print("[aviary] %s-angles-%s.png" % [_out, view[0]])
	_look(Vector3(0.0, 0.5, 4.2), Vector3.ZERO)
