extends SceneTree

## Prints what the game actually sounds like, in numbers:
##   godot --headless --xr-mode off --script res://tests/audio_report.gd
##
## Asserts nothing. This is the instrument the audio work was tuned against —
## the equivalent of `tests/flight_report.gd` for the ears. Every claim in
## docs/AUDIO.md comes from a line of this output.
##
## `--wav=/tmp/soaring` also writes the clips out as real WAV files, for
## somebody who has speakers and wants to check that the numbers are not lying.

const RATE: float = Soundscape.SAMPLE_RATE


func _initialize() -> void:
	_wind_sweep()
	_wing_shape()
	_altitude()
	_events()
	_stall()
	_bank()
	_menace()
	_cost()
	_maybe_write_wavs()
	quit(0)


## Renders [param seconds] of a held flight state and hands back the buffer.
static func fly(state: SoundState, seconds: float, scape: Soundscape = null) -> PackedVector2Array:
	var sound: Soundscape = scape if scape != null else Soundscape.new()
	var out := PackedVector2Array()
	var frames: int = int(seconds * RATE)
	out.resize(frames)
	var block: int = 256
	var written: int = 0
	while written < frames:
		var count: int = mini(block, frames - written)
		sound.update(state, float(count) / RATE)
		var rendered: PackedVector2Array = sound.render(count)
		for i in count:
			out[written + i] = rendered[i]
		written += count
	return out


static func _state(airspeed: float, span: float = 1.0) -> SoundState:
	var state := SoundState.new()
	state.airspeed = airspeed
	state.span = span
	state.altitude = 400.0
	return state


func _wind_sweep() -> void:
	print("\n=== wind against airspeed (span 1.0, 400 m up) ===")
	print("  m/s     rms    peak   centroid   low%%   mid%%   high%%")
	for speed: float in [0.0, 6.0, 12.0, 17.5, 25.0, 35.0, 45.0, 58.0, 78.0]:
		var buffer: PackedVector2Array = fly(_state(speed), 1.2)
		_print_line("%6.1f" % speed, buffer)


func _wing_shape() -> void:
	print("\n=== the same 35 m/s, wings spread against wings tucked ===")
	print("  span    rms    peak   centroid   low%%   mid%%   high%%")
	for span: float in [1.0, 0.7, 0.4, 0.15, 0.0]:
		var buffer: PackedVector2Array = fly(_state(35.0, span), 1.2)
		_print_line("%6.2f" % span, buffer)


func _altitude() -> void:
	print("\n=== the land below, against height above it (17.5 m/s trim) ===")
	print("  agl     rms    peak   centroid   low%%   mid%%   high%%")
	for altitude: float in [0.0, 20.0, 60.0, 120.0, 250.0, 500.0, 900.0]:
		var state: SoundState = _state(17.5)
		state.altitude = altitude
		var buffer: PackedVector2Array = fly(state, 1.2)
		_print_line("%6.0f" % altitude, buffer)


func _stall() -> void:
	print("\n=== stall buffet ===")
	for stall: float in [0.0, 0.3, 0.7, 1.0]:
		var state: SoundState = _state(16.0)
		state.stall = stall
		state.altitude = 400.0
		var buffer: PackedVector2Array = fly(state, 2.0)
		var mono: PackedFloat32Array = AudioAnalysis.mono(buffer)
		var shape: PackedFloat32Array = AudioAnalysis.envelope(mono, RATE, 60.0)
		print("  stall %.1f: rms %.4f, modulation at %.0f Hz %.3f, at 3 Hz %.3f" % [
			stall, AudioAnalysis.rms(mono), Soundscape.BUFFET_HZ,
			AudioAnalysis.modulation(shape, Soundscape.BUFFET_HZ),
			AudioAnalysis.modulation(shape, 3.0),
		])


func _bank() -> void:
	print("\n=== lift (a thermal, at trim) ===")
	for lift: float in [0.0, 2.0, 4.0, 6.0]:
		var state: SoundState = _state(17.5)
		state.lift = lift
		var buffer: PackedVector2Array = fly(state, 1.5)
		var mono: PackedFloat32Array = AudioAnalysis.mono(buffer)
		var power: PackedFloat32Array = AudioAnalysis.spectrum(mono, 2048)
		print("  lift %.1f m/s: rms %.4f, 40-160 Hz %.1f%%, above 2 kHz %.1f%%" % [
			lift, AudioAnalysis.rms(mono),
			100.0 * AudioAnalysis.band(power, RATE, 40.0, 160.0),
			100.0 * AudioAnalysis.band(power, RATE, 2000.0, 8000.0),
		])


func _events() -> void:
	print("\n=== the wingbeat ===")
	for stroke: float in [1.0, 2.0, 3.5, 5.0]:
		var scape := Soundscape.new()
		var quiet := SoundState.new()
		quiet.airspeed = 17.5
		quiet.altitude = 400.0
		fly(quiet, 0.3, scape)
		var beating: SoundState = _state(17.5)
		beating.altitude = 400.0
		beating.stroke_speed = stroke
		scape.update(beating, 1.0 / 90.0)
		var buffer: PackedVector2Array = scape.render(int(RATE * 0.02))
		beating.stroke_speed = 0.0
		var tail: PackedVector2Array = fly(beating, 0.6, scape)
		var whole := PackedFloat32Array()
		whole.append_array(AudioAnalysis.mono(buffer))
		whole.append_array(AudioAnalysis.mono(tail))
		var shape: PackedFloat32Array = AudioAnalysis.envelope(whole, RATE, 120.0)
		var top: Array = AudioAnalysis.envelope_peak(shape)
		print("  stroke %.1f m/s: peak %.3f at %.0f ms, rms %.4f, quiet floor %.4f" % [
			stroke, float(top[0]), float(top[1]) * 1000.0,
			AudioAnalysis.rms(whole), AudioAnalysis.rms(AudioAnalysis.mono(fly(quiet, 0.4)))
		])

	print("\n=== the flock's own voices (baked once, played by the engine) ===")
	print("  clip                       secs    peak     rms   centroid")
	var baking: int = 0
	for name: String in VoiceBank.clip_names():
		var started: int = Time.get_ticks_usec()
		var samples: PackedFloat32Array = VoiceBank.render(StringName(name))
		baking += Time.get_ticks_usec() - started
		var power: PackedFloat32Array = AudioAnalysis.spectrum(samples, 1024)
		print("  %-24s %5.2f  %6.3f  %6.4f    %6.0f Hz" % [
			name, float(samples.size()) / VoiceBank.RATE, AudioAnalysis.peak(samples),
			AudioAnalysis.rms(samples), AudioAnalysis.centroid(power, VoiceBank.RATE),
		])
	print("  whole bank rendered in %d ms (measurement excluded)" % (baking / 1000))


func _menace() -> void:
	print("\n=== how loud the thing chasing you is (you are size 1.0) ===")
	print("  distance   peer 1.0   bigger 1.6   bigger 1.6 closing   monster 4.0 closing")
	for distance: float in [5.0, 15.0, 30.0, 50.0, 70.0, 89.0, 95.0]:
		print("  %6.0f m   %8.3f   %10.3f   %18.3f   %20.3f" % [
			distance,
			FlockAudio.menace(distance, 1.0, 1.0, 20.0),
			FlockAudio.menace(distance, 1.0, 1.6, 0.0),
			FlockAudio.menace(distance, 1.0, 1.6, 20.0),
			FlockAudio.menace(distance, 1.0, 4.0, 20.0),
		])
	print("  a predator's calls come %.1f s apart calm, %.1f s apart on top of you" % [
		FlockAudio.call_interval(0.0), FlockAudio.call_interval(1.0),
	])


func _cost() -> void:
	print("\n=== cost ===")
	var seconds: float = 20.0
	for label: String in ["cruise", "everything at once"]:
		var state := SoundState.new()
		state.airspeed = 40.0
		state.altitude = 3000.0 if label == "cruise" else 20.0
		if label != "cruise":
			state.stall = 1.0
			state.lift = 5.0
			state.stroke_speed = 3.5
		var scape := Soundscape.new()
		var started: int = Time.get_ticks_usec()
		var frames: int = int(seconds * RATE)
		var written: int = 0
		while written < frames:
			var count: int = mini(180, frames - written)
			scape.update(state, float(count) / RATE)
			scape.render(count)
			written += count
		var elapsed: int = Time.get_ticks_usec() - started
		print("  %-20s %6.1f ms for %.0f s of audio  (%.2f%% of one core)" % [
			label, float(elapsed) / 1000.0, seconds,
			100.0 * float(elapsed) / (seconds * 1e6),
		])


func _print_line(label: String, buffer: PackedVector2Array) -> void:
	var mono: PackedFloat32Array = AudioAnalysis.mono(buffer)
	var power: PackedFloat32Array = AudioAnalysis.spectrum(mono, 2048)
	print("%s  %.4f  %.4f   %6.0f    %4.1f   %4.1f   %4.1f" % [
		label, AudioAnalysis.rms(mono), AudioAnalysis.peak(mono),
		AudioAnalysis.centroid(power, RATE),
		100.0 * AudioAnalysis.band(power, RATE, 0.0, 300.0),
		100.0 * AudioAnalysis.band(power, RATE, 300.0, 1500.0),
		100.0 * AudioAnalysis.band(power, RATE, 1500.0, 8000.0),
	])


## `--wav=/tmp/soaring` writes every clip plus a few flight states as real WAV
## files. The numbers above are the verification; this is for ears.
func _maybe_write_wavs() -> void:
	var prefix: String = ""
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == "wav":
			prefix = parts[1]
	if prefix.is_empty():
		return
	for name: String in VoiceBank.clip_names():
		AudioAnalysis.save_wav(
			VoiceBank.render(StringName(name)), VoiceBank.RATE,
			"%s-%s.wav" % [prefix, name]
		)
	var flights: Dictionary = {
		"glide": _state(17.5), "dive": _state(55.0, 0.15), "fast-glide": _state(45.0),
	}
	for name: String in flights:
		var state: SoundState = flights[name]
		state.altitude = 60.0
		AudioAnalysis.save_wav(
			AudioAnalysis.mono(fly(state, 3.0)), RATE, "%s-air-%s.wav" % [prefix, name]
		)
	print("\n  wavs written to %s-*.wav" % prefix)
