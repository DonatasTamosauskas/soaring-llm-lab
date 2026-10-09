extends RefCounted
## Shared rig for the audio suites (not a suite itself): a stage with a
## listener, a mock player whose telemetry the test writes, mock NPC birds,
## a mock world, and capture taps that record what the engine's mixer really
## outputs on a bus (AudioEffectCapture; the headless Dummy driver mixes in
## real time). Depends only on core contracts (Bird, Birds, Events, Game,
## World) and the audio area's own code.

const DIRECTOR := "res://scenes/audio/audio_director.tscn"


## The player: a Bird whose telemetry() returns whatever the test puts in tel.
class MockPlayer:
	extends Bird
	var tel := {"airspeed": 0.0, "wing_extension": 1.0, "tucked": false, "stalled": false,
		"in_updraft": 0.0, "perched": false, "world_scale": 1.0}

	func is_player() -> bool:
		return true

	func telemetry() -> Dictionary:
		return tel


## An NPC: species, position, and the optional extras the voices read.
class MockNpc:
	extends Bird
	var state_str := "wander"
	var hidden := false

	func state_name() -> String:
		return state_str


## A world with hand-placed landmarks (ground at y = `ground`, which a
## test may set to anything, NaN included).
class MockWorld:
	extends World
	var marks: Array[Dictionary] = []
	var ground := 0.0

	func get_landmarks() -> Array[Dictionary]:
		return marks

	func ground_height(_x: float, _z: float) -> float:
		return ground


## Settings in memory, for the director's `settings` source: the volume
## sliders a test sets never reach user://settings.cfg (the real Settings
## autoload saves on every set_value). Like Settings, set_value emits
## Events.settings_changed, so the director reacts exactly as in the game.
class MemorySettings:
	extends RefCounted
	var values := {}

	func _init() -> void:
		values = AudioBuses.SETTING_DEFAULT.duplicate()

	func get_value(key: String, fallback: Variant = null) -> Variant:
		return values.get(key, fallback)

	func set_value(key: String, value: Variant) -> void:
		values[key] = value
		Events.settings_changed.emit(key, value)


var root: Node3D
## The volume sliders the director reads (the shipped defaults to start).
var settings := MemorySettings.new()
## The ears: a current Camera3D, as in the game (the XRCamera3D in VR). A
## bare AudioListener3D renders 3D players silent in headless runs.
var listener: Camera3D
var player: MockPlayer
var director: AudioDirector
var npcs: Array[MockNpc] = []
var world: MockWorld = null
var _caps: Array = []  # [[bus, effect]]
var _temp_buses: PackedStringArray = []


## Builds the stage under parent: listener at the origin looking down -Z,
## the player 100 m up (no ambience) flying along -Z, and a director.
func build(parent: Node, with_player: bool = true) -> void:
	root = Node3D.new()
	root.name = "AudioStage"
	parent.add_child(root)
	listener = Camera3D.new()
	root.add_child(listener)
	listener.global_position = Vector3(0, 100, 0)
	listener.make_current()
	if with_player:
		player = MockPlayer.new()
		player.name = "MockPlayer"
		player.mass = 0.03
		player.species = &"sparrow"
		root.add_child(player)
		player.global_position = Vector3(0, 100, 0)
		player.velocity = Vector3(0, 0, -9)
	director = (load(DIRECTOR) as PackedScene).instantiate() as AudioDirector
	director.async_build = false
	director.settings = settings
	root.add_child(director)


func add_world(marks: Array[Dictionary]) -> MockWorld:
	world = MockWorld.new()
	world.marks = marks
	root.add_child(world)
	return world


func add_npc(species: StringName, pos: Vector3, mass: float = -1.0) -> MockNpc:
	var b := MockNpc.new()
	b.species = species
	b.mass = mass if mass > 0.0 else float(SizeRules.species_data(species)["mass"])
	root.add_child(b)
	b.global_position = pos
	npcs.append(b)
	return b


## The sky as the Ecosystem keeps it (docs/areas/AI.md; the round-5
## verifier's layout): ~60 NPCs "over the area the player circles, 60-110
## m", spawns no nearer than 40 m, prey within 80 m, a 12-starling
## murmuration, a handful of raptors patrolling. [[species, distance m,
## bearing rad, height offset m], ...], deterministic for a seeded rng.
static func sky_layout(rng: RandomNumberGenerator) -> Array:
	var out := []
	var add := func(sp: StringName, d0: float, d1: float, n: int) -> void:
		for i in n:
			out.append([sp, rng.randf_range(d0, d1), rng.randf() * TAU, rng.randf_range(-10.0, 10.0)])
	# The murmuration: 12 starlings bunched ~85 m out.
	var ma := rng.randf() * TAU
	for i in 12:
		out.append([&"starling", 85.0 + rng.randf_range(-8.0, 8.0), ma + rng.randf_range(-0.12, 0.12), rng.randf_range(-6.0, 6.0)])
	add.call(&"wren", 40.0, 80.0, 3)  # prey for a small player
	add.call(&"moth", 40.0, 70.0, 4)  # "dust"
	add.call(&"sparrow", 50.0, 110.0, 5)  # peers
	add.call(&"swallow", 50.0, 110.0, 5)
	add.call(&"pigeon", 60.0, 140.0, 5)  # giants
	add.call(&"crow", 60.0, 140.0, 5)
	add.call(&"gull", 60.0, 140.0, 5)
	add.call(&"hawk", 60.0, 120.0, 3)  # threats patrolling (not attacking)
	add.call(&"eagle", 60.0, 120.0, 2)
	add.call(&"starling", 60.0, 110.0, 6)  # loose flocks
	add.call(&"sparrow", 60.0, 110.0, 5)
	return out


## Places sky_layout() round `at` as mock NPCs (starlings flocking, the rest
## wandering). Returns them.
func add_sky(at: Vector3, rng: RandomNumberGenerator) -> Array[MockNpc]:
	var out: Array[MockNpc] = []
	for e in sky_layout(rng):
		var b := add_npc(e[0], at + Vector3(cos(e[2]) * e[1], e[3], sin(e[2]) * e[1]))
		b.state_str = "flock" if e[0] == &"starling" else "wander"
		out.append(b)
	return out


func set_tel(values: Dictionary) -> void:
	for k in values:
		player.tel[k] = values[k]


## Appends (or inserts at `at`) a capture tap on bus. The tap sees the bus
## after the effects before it and before the bus fader. It holds `seconds`
## of audio (a tap read only at the end of a long session needs more).
func tap(bus: StringName, at: int = -1, seconds: float = 6.0) -> AudioEffectCapture:
	var cap := AudioEffectCapture.new()
	cap.buffer_length = seconds
	AudioServer.add_bus_effect(AudioServer.get_bus_index(bus), cap, at)
	_caps.append([bus, cap])
	return cap


## Records `seconds` of a tap: {l, r, mono, rate}.
func record(tree: SceneTree, cap: AudioEffectCapture, seconds: float) -> Dictionary:
	cap.clear_buffer()
	var need := int(seconds * AudioServer.get_mix_rate())
	var frames := PackedVector2Array()
	while frames.size() < need:
		await tree.process_frame
		var n := cap.get_frames_available()
		if n > 0:
			frames.append_array(cap.get_buffer(n))
	var d := AudioAnalysis.split_frames(frames.slice(0, need))
	d["rate"] = AudioServer.get_mix_rate()
	return d


## Records two taps over the same stretch of time.
func record2(tree: SceneTree, a: AudioEffectCapture, b: AudioEffectCapture, seconds: float) -> Array:
	a.clear_buffer()
	b.clear_buffer()
	var need := int(seconds * AudioServer.get_mix_rate())
	var fa := PackedVector2Array()
	var fb := PackedVector2Array()
	while fa.size() < need or fb.size() < need:
		await tree.process_frame
		var na := a.get_frames_available()
		if na > 0:
			fa.append_array(a.get_buffer(na))
		var nb := b.get_frames_available()
		if nb > 0:
			fb.append_array(b.get_buffer(nb))
	var da := AudioAnalysis.split_frames(fa.slice(0, need))
	var db := AudioAnalysis.split_frames(fb.slice(0, need))
	da["rate"] = AudioServer.get_mix_rate()
	db["rate"] = AudioServer.get_mix_rate()
	return [da, db]


## Records any number of taps over the same stretch of time.
func record_many(tree: SceneTree, caps: Array, seconds: float) -> Array[Dictionary]:
	var need := int(seconds * AudioServer.get_mix_rate())
	var got: Array[PackedVector2Array] = []
	for c: AudioEffectCapture in caps:
		c.clear_buffer()
		got.append(PackedVector2Array())
	var done := false
	while not done:
		await tree.process_frame
		done = true
		for i in caps.size():
			var c: AudioEffectCapture = caps[i]
			var n := c.get_frames_available()
			if n > 0:
				got[i].append_array(c.get_buffer(n))
			if got[i].size() < need:
				done = false
	var out: Array[Dictionary] = []
	for f in got:
		var d := AudioAnalysis.split_frames(f.slice(0, need))
		d["rate"] = AudioServer.get_mix_rate()
		out.append(d)
	return out


## Adds n temporary buses (name prefix + index) sending to `send`, each with
## a capture tap: per-voice taps, so several 3D players render at once and
## are still measured apart. Removed by teardown().
func tap_buses(prefix: String, n: int, send: StringName) -> Array[AudioEffectCapture]:
	var caps: Array[AudioEffectCapture] = []
	for i in n:
		AudioServer.add_bus()
		var bi := AudioServer.bus_count - 1
		AudioServer.set_bus_name(bi, "%s%d" % [prefix, i])
		AudioServer.set_bus_send(bi, send)
		var cap := AudioEffectCapture.new()
		cap.buffer_length = 6.0
		AudioServer.add_bus_effect(bi, cap)
		caps.append(cap)
		_temp_buses.append("%s%d" % [prefix, i])
	return caps


static func wait(tree: SceneTree, seconds: float) -> void:
	await tree.create_timer(seconds, true, false, true).timeout


## Lets the frame that follows a long stretch of analysis on the main
## thread go by before a timed wait. That frame's delta holds the whole
## stretch: the director clamps it to 0.1 s, but a SceneTree timer counts
## it in full, even one created during that frame (timers are processed
## after the nodes), so a 0.5 s wait could end 0.15 s after it began.
static func past_hitch(tree: SceneTree) -> void:
	await tree.process_frame
	await tree.process_frame


## Removes the taps, the stage and every mock; restores the game state.
func teardown() -> void:
	for c in _caps:
		var bi := AudioServer.get_bus_index(c[0])
		for i in range(AudioServer.get_bus_effect_count(bi) - 1, -1, -1):
			if AudioServer.get_bus_effect(bi, i) == c[1]:
				AudioServer.remove_bus_effect(bi, i)
	_caps.clear()
	if root and is_instance_valid(root):
		root.get_parent().remove_child(root)
		root.free()
	npcs.clear()
	# After the players that used them are gone.
	for b in _temp_buses:
		var ti := AudioServer.get_bus_index(b)
		if ti >= 0:
			AudioServer.remove_bus(ti)
	_temp_buses.clear()
	if Game.state != Game.State.BOOT:
		Game.set_state(Game.State.BOOT)


## Puts every audio key of the real Settings autoload back to its shipped
## default (it saves to user://settings.cfg). The suite no longer needs it:
## every director the fixture builds reads the in-memory `settings` above,
## so no test writes the file. Kept for the verifiers' probes in
## tests/probes/audio/, which call it.
static func restore_default_settings() -> void:
	for k in AudioBuses.SETTING_DEFAULT:
		var want: float = AudioBuses.SETTING_DEFAULT[k]
		if not is_equal_approx(float(Settings.get_value(k, want)), want):
			Settings.set_value(k, want)


## Writes a recording as a 16-bit WAV for review (artifacts/audio/renders/).
static func save_render(rec: Dictionary, name: String) -> String:
	var path := Paths.artifacts("audio/renders").path_join(name + ".wav")
	AudioSynth.make_wav(rec["l"], rec["r"], int(rec["rate"])).save_to_wav(path)
	return path


## Merges numbers into artifacts/audio/measurements.json (for the plots).
static func save_measure(key: String, value: Variant) -> void:
	var path := Paths.artifacts("audio").path_join("measurements.json")
	var data := {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			data = parsed
	data[key] = value
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", true))
