extends Node

var enabled := true
var wind: AudioStreamPlayer
var voices: Array[AudioStreamPlayer] = []
var next_voice := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	wind = AudioStreamPlayer.new()
	wind.stream = _wind_stream()
	wind.volume_db = -34
	add_child(wind)
	wind.play()
	for i in 6:
		var voice := AudioStreamPlayer.new()
		voice.volume_db = -18
		add_child(voice)
		voices.append(voice)

func set_enabled(on: bool) -> void:
	enabled = on
	wind.volume_db = -34 if on else -80
	if not on:
		for voice in voices: voice.stop()

func update_speed(speed: float, playing: bool) -> void:
	wind.volume_db = lerpf(-36, -20, clampf(speed / 25.0, 0, 1)) if enabled and playing else -80
	wind.pitch_scale = lerpf(0.7, 1.3, clampf(speed / 25.0,0,1))

func flap(strength: float) -> void:
	_play(_tone(170, 0.14, 0.35, -100, true), -24 + strength * 4)

func catch_chime(_pos: Vector3 = Vector3.ZERO, _mass: float = 1.0) -> void:
	_play(_tone(660, 0.32, 0.35, 440), -17)

func growth_chime() -> void:
	_play(_tone(440, 0.65, 0.3, 880), -16)

func bump(speed: float) -> void:
	if speed > 3: _play(_tone(100, 0.15, 0.3, -70, true), -25)

func _play(stream: AudioStreamWAV, volume: float) -> void:
	if not enabled or voices.is_empty(): return
	var voice := voices[next_voice]
	next_voice = (next_voice + 1) % voices.size()
	voice.stream = stream
	voice.volume_db = volume
	voice.play()

func _tone(frequency: float, duration: float, amplitude: float, sweep: float, noise := false) -> AudioStreamWAV:
	var rate := 16000
	var count := int(duration * rate)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 817
	var filtered := 0.0
	for i in count:
		var t := float(i) / rate
		var envelope := sin(PI * t / duration) * exp(-3 * t / duration)
		var tone := sin(TAU * (frequency * t + 0.5 * sweep * t * t / duration))
		if noise:
			filtered = lerpf(filtered, rng.randf_range(-1,1), 0.18)
			tone = filtered
		var value := int(clampf(tone * envelope * amplitude, -1,1) * 32767)
		data.encode_s16(i * 2, value)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream

func _wind_stream() -> AudioStreamWAV:
	var rate := 12000
	var count := rate * 4
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9901
	var filtered := 0.0
	for i in count:
		filtered = lerpf(filtered, rng.randf_range(-1,1), 0.025)
		var envelope := 0.75 + sin(TAU * float(i) / count) * 0.25
		data.encode_s16(i * 2, int(filtered * envelope * 22000))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_end = count
	return stream
