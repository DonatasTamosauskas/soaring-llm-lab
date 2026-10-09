class_name VoiceBank
extends RefCounted

## Every sound in the game that is an event rather than a state: bird calls,
## wingbeats heard from outside, a catch, a collision, a promotion.
##
## Baked, not streamed. [Soundscape] synthesises the player's own air a sample at
## a time because it has to track the flight continuously; a bird calling forty
## metres to your left does not — it is a fixed gesture that happens and stops.
## So these are rendered once into [AudioStreamWAV]s at startup and then played
## by the engine's own mixer in C++, which means a sky with a dozen birds calling
## costs the GDScript side nothing at all. It also means they can be positional:
## an [AudioStreamPlayer3D] gives distance falloff, doppler and a direction, and
## direction is the whole point of hearing something behind you.
##
## Still no audio assets on disk. Everything here is arithmetic.
##
## [b]The model.[/b] A bird call is a whistle with a shape: a frequency contour,
## a few harmonics, some breath noise, and an envelope. Five species get five
## contours, and three moods (contact, alarm, hunting) shift pitch, speed and
## harshness — so an alarm is recognisably the same bird, frightened. Everything
## else in here is noise through a filter with an envelope on it.
##
## Assertions live in [code]AudioTests[/code], on the sample buffers themselves:
## a call has energy, does not clip, ends in silence, and is spectrally distinct
## from the other species.

## Bird calls are baked higher than [constant Soundscape.SAMPLE_RATE] because a
## swift's call genuinely lives at 7 kHz. It costs nothing per frame — this rate
## is paid once, at load, and then the engine's mixer owns it.
const RATE: float = 22050.0

## The beds and the air rush have nothing above 2 kHz in them, and they are the
## longest clips in the bank. Baking them at a third of the rate costs a third of
## the load time and sounds identical; the stream carries its own rate, so
## nothing downstream has to know.
const BED_RATE: float = 8000.0


## Sample rate of one clip. Only the long, low ones differ.
static func rate_of(kind: StringName) -> float:
	if kind == &"rush" or kind == &"forest" or kind == &"town":
		return BED_RATE
	return RATE

## Contact call, alarm, and the call of something that has decided to eat you.
enum Mood { CONTACT, ALARM, HUNT }

## Syllable budget for a call: how much time the syllables of one call may take
## between them. A bird that goes on for two seconds is a bird you stop hearing.
##
## Not a hard ceiling on the clip. Each syllable then wobbles up to twelve
## percent longer than nominal and the clip carries a short tail, so the longest
## calls the parameters can produce — the corvid and seabird alarms — come out
## around 1.24 s. [AudioTests] bounds the real length at a third over this.
const MAX_CALL_SECONDS: float = 1.15

## Peak every clip is normalised to. Uniform, so the director's per-kind volumes
## are the only thing that decides how loud anything is.
const NORMAL_PEAK: float = 0.90

## Wavetable size for the oscillators. 1024 truncated (not interpolated) entries
## puts the quantisation error about 60 dB down, which is far below the breath
## noise deliberately mixed into every call — and it turns a sine into an array
## index, which is what makes baking the whole bank take milliseconds.
const TABLE_SIZE: int = 1024

static var _table: PackedFloat32Array = PackedFloat32Array()
static var _cache: Dictionary = {}


static func _sine_table() -> PackedFloat32Array:
	if _table.size() == TABLE_SIZE:
		return _table
	_table.resize(TABLE_SIZE)
	for i in TABLE_SIZE:
		_table[i] = sin(TAU * float(i) / float(TABLE_SIZE))
	return _table


## The clip name for a species in a mood — e.g. [code]&"call_falcon_alarm"[/code].
static func call_name(species: int, mood: int) -> StringName:
	var names: PackedStringArray = ["swift", "falcon", "corvid", "seabird", "raptor"]
	var moods: PackedStringArray = ["contact", "alarm", "hunt"]
	var s: int = clampi(species, 0, names.size() - 1)
	var m: int = clampi(mood, 0, moods.size() - 1)
	return StringName("call_%s_%s" % [names[s], moods[m]])


## Every clip the game can play. Named here rather than discovered, so a missing
## sound is a test failure and not a silence nobody notices.
static func clip_names() -> PackedStringArray:
	var names := PackedStringArray()
	for species: int in 5:
		for mood: int in 3:
			names.append(String(call_name(species, mood)))
	for effect: String in [
		"beat", "beat_big", "catch", "caught", "rank_up", "rank_down", "won",
		"lost", "impact", "cling", "launch", "rush", "forest", "town",
	]:
		names.append(effect)
	return names


## Mono samples for one clip, in −1..1. [param variant] gives the same call a
## different roll of the dice, so a flock does not sound like one bird playing
## from twelve places.
static func render(kind: StringName, variant: int = 0) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	# Seeded off the name, so a clip is identical every run and every device: a
	# flock that sounds different on a headset than in a test is untestable.
	rng.seed = hash(String(kind)) * 1000003 + variant
	var text: String = String(kind)
	if text.begins_with("call_"):
		return _bird_call(text, rng)
	match kind:
		&"beat":
			return _wingbeat(1.0, rng)
		&"beat_big":
			return _wingbeat(2.6, rng)
		&"catch":
			return _catch(rng)
		&"caught":
			return _caught(rng)
		&"rank_up":
			return _arpeggio([392.0, 523.0, 659.0, 784.0], 0.17, true, rng)
		&"rank_down":
			return _arpeggio([392.0, 311.0], 0.24, false, rng)
		&"won":
			return _arpeggio([523.0, 659.0, 784.0, 1046.0], 0.22, true, rng)
		&"lost":
			return _arpeggio([294.0, 233.0, 175.0], 0.34, false, rng)
		&"impact":
			return _impact(rng)
		&"cling":
			return _cling(rng)
		&"launch":
			return _launch(rng)
		&"rush":
			return _rush(rng)
		&"forest":
			return _forest(rng)
		&"town":
			return _town(rng)
	return PackedFloat32Array()


## A playable stream for one clip. [param loop] is for the two ambience beds and
## the predator's air rush, which are states rather than events.
static func stream(kind: StringName, variant: int = 0, loop: bool = false) -> AudioStreamWAV:
	var key: String = "%s/%d/%s" % [kind, variant, "loop" if loop else "one"]
	if _cache.has(key):
		return _cache[key] as AudioStreamWAV
	var samples: PackedFloat32Array = render(kind, variant)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(rate_of(kind))
	wav.stereo = false
	wav.data = _to_bytes(samples)
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	_cache[key] = wav
	return wav


## Drops every baked clip. Only for tests that want to measure a cold bake.
static func clear_cache() -> void:
	_cache.clear()


static func _to_bytes(samples: PackedFloat32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	return bytes


# --- birds ---------------------------------------------------------------------

## Five species, five voices. The numbers are: syllable count, syllable length,
## gap, start and end pitch of the glide, vibrato, how many harmonics, and how
## much breath. They are chosen so the five are separable by ear and by
## spectrum — a swift is a thin high tick and a raptor is a harsh descending
## scream, and no two sit in the same octave.
static func _species_voice(name: String) -> Dictionary:
	match name:
		"swift":
			return {
				"syllables": 4, "length": 0.075, "gap": 0.045,
				"from": 6800.0, "to": 5200.0, "vibrato": 0.0, "vibrato_hz": 0.0,
				"harmonics": 1, "breath": 0.10, "harsh": 0.0,
			}
		"falcon":
			return {
				"syllables": 5, "length": 0.085, "gap": 0.070,
				"from": 1250.0, "to": 1050.0, "vibrato": 0.03, "vibrato_hz": 22.0,
				"harmonics": 4, "breath": 0.22, "harsh": 0.25,
			}
		"corvid":
			return {
				"syllables": 3, "length": 0.230, "gap": 0.180,
				"from": 620.0, "to": 430.0, "vibrato": 0.05, "vibrato_hz": 34.0,
				"harmonics": 7, "breath": 0.30, "harsh": 0.45,
			}
		"seabird":
			return {
				"syllables": 2, "length": 0.480, "gap": 0.150,
				"from": 900.0, "to": 1500.0, "vibrato": 0.07, "vibrato_hz": 11.0,
				"harmonics": 3, "breath": 0.16, "harsh": 0.12,
			}
		_:
			return {
				"syllables": 2, "length": 0.620, "gap": 0.200,
				"from": 1750.0, "to": 780.0, "vibrato": 0.09, "vibrato_hz": 15.0,
				"harmonics": 5, "breath": 0.34, "harsh": 0.55,
			}


static func _bird_call(text: String, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var parts: PackedStringArray = text.split("_")
	var voice: Dictionary = _species_voice(parts[1] if parts.size() > 1 else "raptor")
	var mood: String = parts[2] if parts.size() > 2 else "contact"

	var syllables: int = int(voice["syllables"])
	var length: float = float(voice["length"])
	var gap: float = float(voice["gap"])
	var from_hz: float = float(voice["from"])
	var to_hz: float = float(voice["to"])
	var breath: float = float(voice["breath"])
	var harsh: float = float(voice["harsh"])

	match mood:
		# Frightened: higher, shorter, faster, and rougher. Same bird.
		"alarm":
			from_hz *= 1.22
			to_hz *= 1.28
			length *= 0.62
			gap *= 0.45
			syllables += 2
			harsh += 0.2
			breath += 0.08
		# Committed: slower, lower, harsher. The sound of something that has
		# stopped talking to the flock and started working.
		"hunt":
			from_hz *= 0.92
			to_hz *= 0.80
			length *= 1.30
			gap *= 0.9
			syllables = maxi(1, syllables - 1)
			harsh += 0.3

	# A call is a sentence, not a speech. Capped so that an alarmed raptor — the
	# longest thing the parameters can produce — still finishes inside a second
	# and a half, which is also what keeps the whole bank's bake time in the tens
	# of milliseconds rather than the hundreds.
	syllables = clampi(int(MAX_CALL_SECONDS / (length + gap)), 1, syllables)
	var total: float = float(syllables) * (length + gap) + 0.12
	var samples := PackedFloat32Array()
	samples.resize(int(total * RATE))
	samples.fill(0.0)

	var cursor: float = 0.0
	for s in syllables:
		# Each syllable drifts a little in pitch and length. Identical repeats are
		# the single clearest tell that a sound is synthetic.
		var wobble: float = rng.randf_range(0.94, 1.07)
		var this_length: float = length * rng.randf_range(0.88, 1.12)
		_write_note(
			samples, cursor, this_length, from_hz * wobble, to_hz * wobble,
			int(voice["harmonics"]), breath, harsh,
			float(voice["vibrato"]), float(voice["vibrato_hz"]), rng
		)
		cursor += this_length + gap * rng.randf_range(0.85, 1.2)
	return _normalise(samples)


## One syllable: a pitch glide with harmonics, vibrato, breath noise and a
## percussive edge. Written into [param out] at [param start] seconds.
##
## Written flat and in fixed point rather than prettily: the oscillator is an
## integer index into a table, the envelope is inlined, and there is one call to
## the random generator per sample rather than three. Baking the bank is the only
## thing in the audio work that a player waits for, so it is worth the ugliness.
static func _write_note(
	out: PackedFloat32Array, start: float, length: float, from_hz: float,
	to_hz: float, harmonics: int, breath: float, harsh: float,
	vibrato: float, vibrato_hz: float, rng: RandomNumberGenerator
) -> void:
	var table: PackedFloat32Array = _sine_table()
	var first: int = int(start * RATE)
	var count: int = int(length * RATE)
	if first < 0 or count <= 0:
		return
	var last: int = mini(out.size(), first + count)
	var phase: float = 0.0
	var vibrato_phase: float = rng.randf() * float(TABLE_SIZE)
	var vibrato_step: float = vibrato_hz / RATE * float(TABLE_SIZE)
	var noise_state: float = 0.0
	# A rough voice is one whose pitch is unstable sample to sample. Bird calls
	# get their harshness from exactly this, not from distortion.
	var rasp: float = 0.0
	var falloff: float = lerpf(0.38, 0.72, harsh)
	var inverse: float = 1.0 / float(count)
	var wobble: float = harsh * 0.10
	var voiced: float = (1.0 - breath) * 0.6
	var breathy: float = breath * 1.6 * 0.6
	var i: int = 0
	for index in range(first, last):
		var u: float = float(i) * inverse
		i += 1
		# The envelope, inlined: on in 6 % of the syllable, off over the last 25 %.
		var env: float = 1.0
		if u < 0.06:
			env = u / 0.06
		elif u > 0.75:
			var fall: float = (1.0 - u) * 4.0
			env = fall * fall
		var noise: float = rng.randf_range(-1.0, 1.0)
		var vib: float = 1.0
		if vibrato > 0.0:
			vibrato_phase += vibrato_step
			if vibrato_phase >= float(TABLE_SIZE):
				vibrato_phase -= float(TABLE_SIZE)
			vib = 1.0 + vibrato * table[int(vibrato_phase)]
		rasp = rasp * 0.85 + noise * 0.15
		var hz: float = lerpf(from_hz, to_hz, u * u) * vib * (1.0 + wobble * rasp)
		phase += hz / RATE * float(TABLE_SIZE)
		while phase >= float(TABLE_SIZE):
			phase -= float(TABLE_SIZE)

		var step: int = int(phase)
		var value: float = table[step]
		var amplitude: float = falloff
		for h in range(1, harmonics):
			# Harsher voices keep more of their upper harmonics — that is the
			# difference between a whistle and a caw. The mask is a power of two,
			# so a harmonic is a multiply and an and.
			value += table[(step * (h + 1)) & (TABLE_SIZE - 1)] * amplitude
			amplitude *= falloff
		noise_state += (noise - noise_state) * 0.35
		out[index] += value * env * voiced + noise_state * env * breathy


# --- effects -------------------------------------------------------------------

## Another bird's wingbeat, heard from outside: a thump of moved air and a short
## feather swish. This is the sound that tells you something is behind you before
## you have any idea what it is.
static func _wingbeat(size: float, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var length: float = 0.22 * sqrt(size)
	var samples := PackedFloat32Array()
	samples.resize(int(length * RATE))
	var thump_cut: float = 190.0 / pow(size, 0.34) * TAU / RATE
	var low: float = 0.0
	var swish_low: float = 0.0
	var swish_sub: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * thump_cut
		# The swish sweeps down as the wing slows, exactly as in [Soundscape] —
		# the player's own beat and the bird's next to them are the same gesture.
		var cut: float = lerpf(0.28, 0.05, u)
		swish_low += (n - swish_low) * cut
		swish_sub += (swish_low - swish_sub) * 0.02
		var env: float = 0.0
		if u < 0.08:
			env = u / 0.08
		else:
			var fall: float = (1.0 - u) / 0.92
			env = fall * fall * fall
		samples[i] = (low * 5.0 + (swish_low - swish_sub) * 1.4) * env
	return _normalise(samples)


## A strike. Something small stops existing: a crunch of feathers, a low thud,
## and a short rising chirp so the moment reads as a win rather than a collision.
static func _catch(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(0.34 * RATE))
	var low: float = 0.0
	var crunch: float = 0.0
	var crunch_sub: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.030
		crunch += (n - crunch) * 0.55
		crunch_sub += (crunch - crunch_sub) * 0.08
		var thud: float = low * 6.0 * _decay(u, 0.0, 0.22)
		var bite: float = (crunch - crunch_sub) * _decay(u, 0.0, 0.06) * 0.9
		samples[i] = thud + bite
	_write_note(samples, 0.05, 0.16, 620.0, 1180.0, 2, 0.10, 0.0, 0.0, 0.0, rng)
	return _normalise(samples)


## Being caught. Low, long and unpleasant, with a distressed cry over the top:
## the only sound in the game allowed to last most of a second.
static func _caught(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(0.85 * RATE))
	var low: float = 0.0
	var body: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.016
		body += (n - body) * 0.20
		samples[i] = low * 9.0 * _decay(u, 0.0, 0.30) + body * 0.55 * _decay(u, 0.0, 0.10)
	_write_note(samples, 0.03, 0.55, 900.0, 340.0, 5, 0.34, 0.6, 0.10, 14.0, rng)
	return _normalise(samples)


## Rank changes. Notes rather than noise, because a promotion is the one moment
## in this game that is pure information: nothing physical just happened to you.
static func _arpeggio(
	notes: PackedFloat32Array, step: float, rising: bool, rng: RandomNumberGenerator
) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int((step * float(notes.size()) + 0.5) * RATE))
	samples.fill(0.0)
	for i in notes.size():
		var hz: float = notes[i]
		var glide: float = hz * (1.02 if rising else 0.97)
		_write_note(
			samples, float(i) * step, step * 2.0, hz, glide, 3, 0.05, 0.0, 0.01, 5.0, rng
		)
	return _normalise(samples)


## Hitting something. No swell at all — the whole point is that it arrives before
## you can brace.
static func _impact(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(0.30 * RATE))
	var low: float = 0.0
	var crack: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.022
		crack += (n - crack) * 0.70
		samples[i] = low * 8.0 * _decay(u, 0.0, 0.26) + (n - crack) * _decay(u, 0.0, 0.03)
	return _normalise(samples)


## Claws finding bark.
static func _cling(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(0.18 * RATE))
	var high: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		high += (n - high) * 0.45
		# Three scuffs rather than one scrape: a bird lands on its feet, twice.
		var grip: float = 1.0 if fmod(u * 3.0, 1.0) < 0.45 else 0.25
		samples[i] = (n - high) * _decay(u, 0.0, 0.09) * grip
	return _normalise(samples)


## Leaving a branch: a wing snap and the twig letting go.
static func _launch(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(0.30 * RATE))
	var low: float = 0.0
	var sub: float = 0.0
	for i in samples.size():
		var u: float = float(i) / float(samples.size())
		var n: float = rng.randf_range(-1.0, 1.0)
		var cut: float = lerpf(0.40, 0.06, u)
		low += (n - low) * cut
		sub += (low - sub) * 0.02
		var env: float = 0.0 if u < 0.02 else _decay(u - 0.02, 0.02, 0.14)
		samples[i] = (low - sub) * 2.4 * env
	return _normalise(samples)


## The air over something big that is very close and not slowing down. Looped,
## and the only continuous voice a bird ever gets — see [FlockAudio].
static func _rush(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(2.0 * BED_RATE))
	var low: float = 0.0
	var sub: float = 0.0
	for i in samples.size():
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.26
		sub += (low - sub) * 0.022
		samples[i] = (low - sub) * 2.0
	return _crossfade_loop(_normalise(samples), 0.15, BED_RATE)


## The land, for the two ambience emitters the director plants under the player.
## A forest is a rustle; a town is a low hum with the odd distant edge to it.
static func _forest(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(3.0 * BED_RATE))
	var low: float = 0.0
	var sub: float = 0.0
	var gust: float = 0.5
	for i in samples.size():
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.62
		sub += (low - sub) * 0.13
		# Leaves come in and out with the breeze rather than hissing evenly.
		gust += (rng.randf_range(0.2, 1.0) - gust) * 0.00011
		samples[i] = (low - sub) * gust * 1.6
	return _crossfade_loop(_normalise(samples), 0.25, BED_RATE)


static func _town(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(3.0 * BED_RATE))
	var low: float = 0.0
	var sub: float = 0.0
	for i in samples.size():
		var n: float = rng.randf_range(-1.0, 1.0)
		low += (n - low) * 0.055
		sub += (low - sub) * 0.011
		samples[i] = (low - sub) * 4.5
	return _crossfade_loop(_normalise(samples), 0.25, BED_RATE)


# --- helpers -------------------------------------------------------------------

## Exponential-ish decay without calling exp: [param tail] is the time constant
## as a fraction of the clip.
static func _decay(u: float, delay: float, tail: float) -> float:
	if u < delay:
		return 0.0
	var t: float = (u - delay) / maxf(tail, 1e-4)
	return 1.0 / (1.0 + t * t * (1.0 + t))


## Wraps the tail of a loop over its head so the seam is inaudible. Without this
## a two-second air rush ticks twice a second, which is the classic tell of a
## procedural loop.
static func _crossfade_loop(
	samples: PackedFloat32Array, seconds: float, rate: float = RATE
) -> PackedFloat32Array:
	var overlap: int = mini(int(seconds * rate), samples.size() / 3)
	if overlap <= 1:
		return samples
	var out := PackedFloat32Array()
	out.resize(samples.size() - overlap)
	for i in out.size():
		out[i] = samples[i]
	for i in overlap:
		var u: float = float(i) / float(overlap)
		out[i] = lerpf(samples[out.size() + i], samples[i], u)
	return out


## Brings every clip to the same peak, so the mix is decided in one place (the
## director's per-kind volumes) rather than accidentally by whichever synthesis
## routine happened to be loudest.
static func _normalise(samples: PackedFloat32Array) -> PackedFloat32Array:
	var loudest: float = 0.0
	for i in samples.size():
		var value: float = samples[i]
		if not is_finite(value):
			samples[i] = 0.0
			continue
		var magnitude: float = absf(value)
		if magnitude > loudest:
			loudest = magnitude
	if loudest < 1e-5:
		return samples
	var gain: float = NORMAL_PEAK / loudest
	for i in samples.size():
		samples[i] *= gain
	return samples
