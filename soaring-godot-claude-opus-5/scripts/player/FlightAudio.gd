class_name FlightAudio
extends Node

## The player's own ears.
##
## Two jobs, and they are deliberately different in kind:
##
## [b]The air[/b] — wind, wingbeats, the buffet of a stall, the murmur of the
## land below — is synthesised sample by sample in [Soundscape], because it has
## to track the flight continuously and no clip can do that.
##
## [b]Events[/b] — a catch, being caught, a promotion — are baked once by
## [VoiceBank] and played by the engine's mixer, because they are fixed gestures
## and synthesising them per sample would be paying a per-frame cost for
## something that happens twice a minute.
##
## Everything positional lives in [AudioDirector], which this creates and owns so
## that the rest of the game has one audio object to talk to.
##
## Nothing here ships an audio file. Every sample in the game is arithmetic.

## Enough buffer to survive a frame spike without a dropout, short enough that
## the wind still tracks a dive. At 90 Hz physics a frame is 11 ms; this is ten
## of them.
const BUFFER_SECONDS: float = 0.11

## Metres above the ground past which the land is inaudible — used only to skip
## the terrain query, which is the one thing in this file that touches the world.
const BED_CEILING: float = 900.0

var player: BirdPlayer
var director: AudioDirector

var soundscape := Soundscape.new()
var state := SoundState.new()

var _stream_player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _cue_player: AudioStreamPlayer
var _body_player: AudioStreamPlayer
var _world: WorldBuilder
var _last_haptic: StringName = &""
var _canopy: float = 0.6
var _canopy_timer: float = 0.0


## [param manager] and [param world] are optional so that a probe, a diagnostic
## or a test can bring up the player's own air without a flock or a landscape.
func attach(
	player_ref: BirdPlayer, manager: GameManager = null, world_ref: WorldBuilder = null
) -> void:
	player = player_ref
	_world = world_ref
	# Before anything names a bus: a player assigned to a bus that does not exist
	# lands on Master with an error, and then the mix has no floor to duck.
	AudioDirector.ensure_buses()

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = Soundscape.SAMPLE_RATE
	generator.buffer_length = BUFFER_SECONDS

	_stream_player = AudioStreamPlayer.new()
	_stream_player.name = "Air"
	_stream_player.stream = generator
	_stream_player.bus = "Air"
	add_child(_stream_player)

	_cue_player = AudioStreamPlayer.new()
	_cue_player.name = "Cues"
	_cue_player.bus = "Events"
	add_child(_cue_player)

	# Its own voice, so that clipping a branch cannot cut off the sound of the
	# catch you were in the middle of making.
	_body_player = AudioStreamPlayer.new()
	_body_player.name = "Body"
	_body_player.bus = "Events"
	add_child(_body_player)

	if manager != null:
		director = AudioDirector.new()
		director.name = "AudioDirector"
		# Keeps running while the menu has the tree paused, so the mix fades
		# rather than cutting — see [method _process].
		director.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(director)
		director.attach(player_ref, manager, world_ref)
		director.warm_up()

	_stream_player.play()
	_playback = _stream_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _ready() -> void:
	# A menu that pauses the tree must not leave the generator starving: an
	# unfed [AudioStreamGeneratorPlayback] runs off the end of its buffer and
	# clicks. Feeding it silence lets the wind fall away instead.
	process_mode = Node.PROCESS_MODE_ALWAYS


## A short synthesised cue for a game event. Catching something has to be
## audible: at 50 m/s, with a bird ahead and a HUD you are not looking at, sound
## is the only channel guaranteed to reach the player at the instant it happens.
##
## Head-locked rather than positional, unlike everything in [AudioDirector].
## These are not events in the world, they are events that happened to you.
func cue(kind: StringName) -> void:
	if _cue_player == null:
		return
	var stream: AudioStreamWAV = VoiceBank.stream(kind)
	if stream == null or stream.data.is_empty():
		return
	_cue_player.stream = stream
	_cue_player.play()
	if director != null:
		# Loud things get the sky out of their way. A death rumble competing with
		# a dozen calling birds is a death rumble nobody hears.
		director.duck(0.6 if kind == &"catch" else 1.0)


func _process(delta: float) -> void:
	if player == null or _playback == null:
		return
	if get_tree() != null and get_tree().paused:
		# The bird is not flying, so nothing about it should be heard. The
		# envelopes still run, so this fades over about a tenth of a second.
		state.reset()
		state.perched = true
	else:
		_read_flight(delta)
	soundscape.update(state, delta)
	_mirror_haptics()
	_fill_buffer()


func _read_flight(delta: float) -> void:
	state.airspeed = player.airspeed()
	state.span = player.command.span
	state.stroke_speed = player.command.stroke_speed
	state.asymmetry = player.command.asymmetry
	state.stall = player.model.stall_amount if player.model.is_stalled else 0.0
	state.lift = player.wind.y
	state.size = player.size
	state.perched = player.perched

	var here: Vector3 = player.global_position
	state.altitude = maxf(here.y, 0.0)
	if _world != null and here.is_finite():
		state.altitude = maxf(here.y - _world.height_at(here.x, here.z), 0.0)
		# The look of the land under you is a district lookup, and it changes
		# about once a minute at flying speed. Twice a second is generous.
		_canopy_timer -= delta
		if _canopy_timer <= 0.0 and state.altitude < BED_CEILING:
			_canopy_timer = 0.5
			_canopy = director.canopy_at(here) if director != null else 0.6
	state.canopy = _canopy


## Everything the player's hands are told, their ears are told too.
##
## [Haptics] is already the one place that knows a collision, a landing or a
## launch happened — it has the event, the strength and the rate limiting. Rather
## than adding a second set of signals for the same three events, this watches
## what the mixer is playing. Two consequences worth stating: a haptic cue and
## its sound can never disagree, and a cue that is rate-limited out of the hands
## is rate-limited out of the ears as well.
##
## Only the three events with no other channel are mirrored. A catch, a
## promotion and a death arrive through [method cue] from [GameManager]'s event
## signal, and a wingbeat is synthesised in [Soundscape]; mirroring those would
## play each of them twice.
const MIRRORED: PackedStringArray = ["impact", "cling", "launch"]


func _mirror_haptics() -> void:
	if player == null or _body_player == null:
		return
	var playing: StringName = player.haptics.playing()
	if playing == _last_haptic:
		return
	_last_haptic = playing
	if playing == &"" or not MIRRORED.has(String(playing)):
		return
	_body_player.stream = VoiceBank.stream(playing)
	_body_player.play()


func _fill_buffer() -> void:
	var frames: int = _playback.get_frames_available()
	if frames <= 0:
		return
	_playback.push_buffer(soundscape.render(frames))
