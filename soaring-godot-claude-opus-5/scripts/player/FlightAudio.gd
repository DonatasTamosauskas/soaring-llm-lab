class_name FlightAudio
extends Node

## Procedural wind and wingbeats.
##
## Generated rather than sampled, because the sound has to track the flight
## continuously: wind that rises with airspeed and opens up as you dive is a
## speed cue your ears read faster than any HUD, and in a headset it is a large
## part of why flying feels like flying. A looped clip cannot do that; a filter
## driven by the actual airspeed can.
##
## The synthesis is deliberately cheap — filtered noise with a couple of
## envelopes — so it costs nothing on a mobile-class headset CPU.

const SAMPLE_RATE: float = 22050.0
## Airspeed at which wind reaches full volume.
const FULL_WIND_SPEED: float = 55.0
const WIND_GAIN: float = 0.30
const FLAP_GAIN: float = 0.55
## Seconds for one wingbeat whoosh to decay.
const FLAP_DECAY: float = 3.2

var player: BirdPlayer

var _stream_player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _rng := RandomNumberGenerator.new()

# Filter state.
var _low: float = 0.0
var _band: float = 0.0
var _flap_low: float = 0.0

# Envelopes, updated per frame from the flight state and interpolated per sample.
var _wind_level: float = 0.0
var _wind_cutoff: float = 0.08
var _flap_envelope: float = 0.0
var _was_stroking: bool = false


func attach(player_ref: BirdPlayer) -> void:
	player = player_ref
	_rng.randomize()

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = 0.12

	_stream_player = AudioStreamPlayer.new()
	_stream_player.stream = generator
	_stream_player.volume_db = 0.0
	add_child(_stream_player)
	_stream_player.play()
	_playback = _stream_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _process(delta: float) -> void:
	if player == null or _playback == null:
		return
	_update_envelopes(delta)
	_fill_buffer()


func _update_envelopes(delta: float) -> void:
	var speed: float = player.airspeed()
	if not is_finite(speed):
		speed = 0.0
	var intensity: float = clampf(speed / FULL_WIND_SPEED, 0.0, 1.0)

	# Volume rises faster than linearly with speed, the way real wind noise does.
	var target_level: float = intensity * intensity * WIND_GAIN
	# Tucking pulls the wings in and the airflow gets thin and hissy; spread
	# wings at speed roar. Driving the filter from span as well as speed makes
	# a dive audibly different from a fast glide.
	var openness: float = lerpf(0.55, 1.0, player.command.span)
	var target_cutoff: float = lerpf(0.03, 0.42, intensity) * openness

	var blend: float = clampf(delta * 6.0, 0.0, 1.0)
	_wind_level = lerpf(_wind_level, target_level, blend)
	_wind_cutoff = lerpf(_wind_cutoff, target_cutoff, blend)

	# Trigger a whoosh on the leading edge of each downstroke.
	var stroking: bool = player.command.stroke_speed > 0.4
	if stroking and not _was_stroking:
		var strength: float = clampf(player.command.stroke_speed / 3.5, 0.25, 1.0)
		_flap_envelope = maxf(_flap_envelope, strength)
	_was_stroking = stroking
	_flap_envelope = maxf(0.0, _flap_envelope - delta * FLAP_DECAY)


func _fill_buffer() -> void:
	var frames: int = _playback.get_frames_available()
	if frames <= 0:
		return
	var decay: float = exp(-1.0 / (FLAP_DECAY * SAMPLE_RATE))
	var flap: float = _flap_envelope

	for i in frames:
		var noise: float = _rng.randf_range(-1.0, 1.0)

		# One-pole lowpass for the body of the wind, plus a resonant band that
		# rises with speed to give it an edge instead of a flat hiss.
		_low += (noise - _low) * _wind_cutoff
		_band += (_low - _band) * clampf(_wind_cutoff * 2.4, 0.0, 0.95)
		var wind: float = (_low * 0.75 + (_low - _band) * 0.9) * _wind_level

		# The wingbeat is a darker, slower whoosh layered on top.
		_flap_low += (noise - _flap_low) * 0.06
		var beat: float = _flap_low * flap * flap * FLAP_GAIN
		flap *= decay

		var sample: float = clampf(wind + beat, -1.0, 1.0)
		_playback.push_frame(Vector2(sample, sample))
