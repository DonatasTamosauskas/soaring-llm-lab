class_name AudioDirector
extends Node

## Puts the sky's sounds in the sky.
##
## [FlockAudio] decides what should be heard; this owns the emitters that do the
## hearing. Everything positional in the game goes through here: bird calls,
## other birds' wingbeats, the air rush of a predator on your tail, and the two
## beds that keep the land underneath you audible.
##
## [b]Why a pool.[/b] An [AudioStreamPlayer3D] per bird would be 26 emitters,
## each with its own attenuation and doppler, almost all of them silent almost
## all of the time. Instead a fixed pool of eight is handed to whichever birds
## are worth hearing this moment, so the cost is flat whatever the flock does.
## Nothing here allocates during play: the pool, the beds and the baked clips all
## exist before the first frame.
##
## [b]Buses.[/b] Four, so a mix decision is made once rather than per emitter,
## and so a loud moment can duck the ambience under it instead of fighting it.

## The pool. Six voices plus the rush plus the beds is well inside what a mobile
## mixer will take, and [constant FlockAudio.MAX_VOICES] never asks for more.
const POOL_SIZE: int = 8

## Distances in metres. Bird calls carry; wingbeats do not. These are the
## engine's own falloff, and they are what makes a bird behind you locatable.
const CALL_DISTANCE: float = 26.0
const CALL_MAX: float = 200.0
const BEAT_DISTANCE: float = 6.0
const RUSH_DISTANCE: float = 12.0

## The land beds. Placed under the player rather than at fixed points, because
## what they say is "the ground is down there" — which is the direction cue that
## a bird flying at 400 m has almost nothing else to go on.
const BED_HEIGHT_BELOW: float = 6.0
const FOREST_DISTANCE: float = 90.0
const TOWN_DISTANCE: float = 180.0
## Where the town is. The town bed is the game's only fixed landmark you can
## navigate to by ear; [WorldBuilder] builds the town around the origin.
const TOWN_CENTRE := Vector3(0.0, 0.0, 0.0)
const TOWN_RANGE: float = 700.0

## Bus names and the level each sits at. Ambience is deliberately quiet: it is
## the floor the rest of the mix stands on, and a bed you notice is too loud.
const BUSES: Dictionary = {
	&"Air": -1.0,
	&"Wildlife": -3.0,
	&"Events": -1.5,
	&"Ambience": -9.0,
}

## How far the quiet buses drop when something loud happens, and how long the
## drop lasts. A death rumble competing with twelve birds is a death rumble
## nobody hears.
const DUCK_DB: float = -11.0
const DUCK_HOLD: float = 0.35
const DUCK_RELEASE: float = 1.1

## How often the flock is re-examined. 10 Hz: a bird moves 5 m between ticks at
## trim, which is well under the distance at which any of this changes meaning,
## and it keeps the O(n log n) sort off the frame budget.
const TICK: float = 0.1

var player: BirdPlayer
var manager: GameManager
var world: WorldBuilder
var flock_audio := FlockAudio.new()

var _pool: Array[AudioStreamPlayer3D] = []
var _next_voice: int = 0
var _rush: AudioStreamPlayer3D
var _forest: AudioStreamPlayer3D
var _town: AudioStreamPlayer3D
var _timer: float = 0.0
var _duck: float = 0.0
var _duck_hold: float = 0.0
var _birds: Array[Dictionary] = []
var _rush_playing: bool = false


func attach(
	player_ref: BirdPlayer, manager_ref: GameManager, world_ref: WorldBuilder
) -> void:
	player = player_ref
	manager = manager_ref
	world = world_ref
	ensure_buses()
	_build_pool()
	_build_beds()


## Creates the mix buses if they are not already there. Done in code rather than
## in a `.tres` for the same reason the world is built in code: one place to read
## it, and it cannot silently drift out of step with the names used here.
##
## Idempotent, and it must run before anything names a bus: assigning a player to
## a bus that does not exist puts it on Master and prints an error.
static func ensure_buses() -> void:
	for name: StringName in BUSES:
		if AudioServer.get_bus_index(String(name)) >= 0:
			continue
		var index: int = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, String(name))
		AudioServer.set_bus_send(index, "Master")
		AudioServer.set_bus_volume_db(index, float(BUSES[name]))


func _build_pool() -> void:
	for i in POOL_SIZE:
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice%d" % i
		voice.bus = "Wildlife"
		voice.unit_size = CALL_DISTANCE
		voice.max_distance = CALL_MAX
		# Inverse falloff, not the default: at these ranges the logarithmic curve
		# keeps a 150 m bird nearly as loud as a 30 m one, and then everything is
		# equally close and nothing is locatable.
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		voice.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		add_child(voice)
		_pool.append(voice)

	_rush = AudioStreamPlayer3D.new()
	_rush.name = "Rush"
	_rush.bus = "Wildlife"
	_rush.unit_size = RUSH_DISTANCE
	_rush.max_distance = FlockAudio.MENACE_RANGE
	_rush.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_rush.stream = VoiceBank.stream(&"rush", 0, true)
	add_child(_rush)


func _build_beds() -> void:
	_forest = AudioStreamPlayer3D.new()
	_forest.name = "LandBed"
	_forest.bus = "Ambience"
	_forest.unit_size = FOREST_DISTANCE
	_forest.max_distance = 900.0
	_forest.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_forest.stream = VoiceBank.stream(&"forest", 0, true)
	add_child(_forest)
	_forest.play()

	_town = AudioStreamPlayer3D.new()
	_town.name = "TownBed"
	_town.bus = "Ambience"
	_town.unit_size = TOWN_DISTANCE
	_town.max_distance = TOWN_RANGE
	_town.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_town.stream = VoiceBank.stream(&"town", 0, true)
	# Placed only once it is in the tree: global_position on an orphan node has
	# no global frame to be in, which Godot reports as an error and then
	# discards. The placement it discarded happened to be the right one anyway —
	# this director is a plain Node, so its emitters are in world space whatever
	# it is parented to — but an error printed on every launch is how a real one
	# goes unnoticed.
	add_child(_town)
	_town.global_position = TOWN_CENTRE
	_town.play()


func _process(delta: float) -> void:
	if player == null or not is_finite(delta) or delta <= 0.0:
		return
	# A paused game keeps its ambience, quietly, under the menu. Silence would be
	# cheaper and is what stopping the node would give us, but a world that
	# vanishes when you open a menu and reappears when you close it is a worse
	# lie than one that carries on at a distance.
	var paused: bool = get_tree() != null and get_tree().paused
	if paused:
		duck(0.8)
	_update_ducking(delta)
	if paused:
		return
	_update_beds()
	_timer += delta
	if _timer < TICK:
		return
	var elapsed: float = _timer
	_timer = 0.0
	_update_flock(elapsed)


## Duck everything that is not the event itself. Held briefly and then released
## slowly, so a catch punches a hole in the sky and the sky closes over it.
func _update_ducking(delta: float) -> void:
	if _duck_hold > 0.0:
		_duck_hold = maxf(0.0, _duck_hold - delta)
	else:
		_duck = maxf(0.0, _duck - delta / DUCK_RELEASE)
	var wildlife: int = AudioServer.get_bus_index("Wildlife")
	var ambience: int = AudioServer.get_bus_index("Ambience")
	if wildlife >= 0:
		AudioServer.set_bus_volume_db(
			wildlife, float(BUSES[&"Wildlife"]) + DUCK_DB * _duck
		)
	if ambience >= 0:
		AudioServer.set_bus_volume_db(
			ambience, float(BUSES[&"Ambience"]) + DUCK_DB * _duck
		)


## Something loud happened; get out of its way.
func duck(strength: float = 1.0) -> void:
	_duck = maxf(_duck, clampf(strength, 0.0, 1.0))
	_duck_hold = DUCK_HOLD


func _update_beds() -> void:
	if _forest == null or world == null:
		return
	var here: Vector3 = player.global_position
	if not here.is_finite():
		return
	# The land bed sits directly below, at ground level. Climb and it recedes;
	# dive at a hillside and it comes up to meet you. That is an altitude cue you
	# get for free from the 3D mixer, on top of the one [Soundscape] renders.
	var ground: float = world.height_at(here.x, here.z)
	_forest.global_position = Vector3(here.x, ground - BED_HEIGHT_BELOW, here.z)
	# Trees rustle, bare rock does not.
	_forest.volume_db = linear_to_db(clampf(canopy_at(here), 0.05, 1.0))


## How wooded the ground below is, 0..1. Read off the world's own districts, so
## the sound of the land and the look of it cannot disagree.
func canopy_at(position: Vector3) -> float:
	if world == null:
		return 0.5
	match world.region_at(position.x, position.z):
		WorldBuilder.Region.GREENWOOD:
			return 1.0
		WorldBuilder.Region.TOWN:
			return 0.55
		WorldBuilder.Region.DOWNS:
			return 0.40
		WorldBuilder.Region.SPIRES:
			return 0.28
		WorldBuilder.Region.GORGE:
			return 0.22
	# The rim and the massif beyond it are bare rock and snow. Nothing rustles.
	return 0.12


func _update_flock(delta: float) -> void:
	if manager == null:
		return
	_birds.clear()
	for bird: BirdNPC in manager.birds:
		if bird == null or not is_instance_valid(bird):
			continue
		_birds.append({
			"id": bird.get_instance_id() as int,
			"position": bird.at(),
			"velocity": bird.model.velocity,
			"size": bird.size,
			"state": int(bird.state),
			"species": int(BirdMesh.species_for_size(bird.size)),
			"stroke": bird.command.stroke_speed,
		})
	var ear: Vector3 = player.head_position()
	flock_audio.update(ear, player.model.velocity, player.size, _birds, delta)

	for event: Dictionary in flock_audio.events:
		_fire(event)
	_update_rush()


func _fire(event: Dictionary) -> void:
	var voice: AudioStreamPlayer3D = _claim()
	if voice == null:
		return
	var kind: StringName = event["kind"]
	voice.stream = VoiceBank.stream(kind, int(event.get("variant", 0)))
	voice.global_position = event["position"]
	voice.pitch_scale = clampf(float(event.get("pitch", 1.0)), 0.4, 2.0)
	voice.volume_db = linear_to_db(clampf(float(event.get("gain", 1.0)), 0.02, 1.0))
	# A wingbeat is near-field and a call carries. Same pool, different reach.
	var beat: bool = kind == &"beat" or kind == &"beat_big"
	voice.unit_size = BEAT_DISTANCE if beat else CALL_DISTANCE
	voice.max_distance = FlockAudio.BEAT_RANGE if beat else CALL_MAX
	voice.play()


## The oldest free voice, or the oldest voice at all. Stealing is deliberate: a
## sky that refuses to make a new sound because eight old ones are still ringing
## is a sky that goes quiet exactly when it gets busy.
func _claim() -> AudioStreamPlayer3D:
	for i in POOL_SIZE:
		var index: int = (_next_voice + i) % POOL_SIZE
		if not _pool[index].playing:
			_next_voice = (index + 1) % POOL_SIZE
			return _pool[index]
	var stolen: AudioStreamPlayer3D = _pool[_next_voice]
	_next_voice = (_next_voice + 1) % POOL_SIZE
	return stolen


func _update_rush() -> void:
	var held: Dictionary = flock_audio.rush
	if held.is_empty():
		if _rush_playing:
			_rush.stop()
			_rush_playing = false
		return
	_rush.global_position = held["position"]
	_rush.pitch_scale = clampf(float(held["pitch"]), 0.4, 2.0)
	_rush.volume_db = linear_to_db(clampf(float(held["gain"]), 0.02, 1.0))
	if not _rush_playing:
		_rush.play()
		_rush_playing = true


## Plays one baked clip at a point in the world — the seam for anything outside
## the flock that happens somewhere rather than to you.
func play_at(kind: StringName, position: Vector3, gain: float = 1.0) -> void:
	if not position.is_finite():
		return
	_fire({"kind": kind, "position": position, "gain": gain, "pitch": 1.0, "variant": 0})


## Bakes every clip the game can play, so the first catch of a session does not
## pay for its own synthesis in the middle of a frame. Costs a few tens of
## milliseconds, once, next to a world build that costs half a minute.
func warm_up() -> void:
	for name: String in VoiceBank.clip_names():
		var looping: bool = name == "rush" or name == "forest" or name == "town"
		VoiceBank.stream(StringName(name), 0, looping)
