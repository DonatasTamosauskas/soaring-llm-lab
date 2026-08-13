class_name Soundscape
extends RefCounted

## Everything the bird hears from inside its own body: the air over the wings,
## each wingbeat, the buffet of a stall, the murmur of the land under you, and
## the low swell of a thermal lifting you.
##
## Scene-free on purpose, exactly like [FlightModel], [WingInput] and [Haptics].
## It takes a [SoundState] in and hands out stereo samples; [FlightAudio] is the
## only thing here that knows an [AudioStreamPlayer] exists. That is what lets
## "wind gets louder with airspeed", "a tuck is thinner than a glide" and "a
## stall buffets at about thirteen hertz" be assertions in a headless suite
## instead of things somebody thought they heard.
##
## [b]Why synthesised rather than sampled.[/b] The sound has to track the flight
## continuously. Wind that rises with airspeed and thins as you tuck is a speed
## cue the ear reads faster than any HUD, and in a headset it is a large part of
## why flying feels like flying. A looped clip cannot do that; filters driven by
## the actual airspeed can. It also ships no audio assets at all.
##
## [b]How it stays cheap.[/b] Four ideas:
## [br]• No [code]sin[/code], no [code]exp[/code], no table lookups and no
##   function calls inside the sample loop — every layer is one-pole filters on
##   noise, which is three operations each.
## [br]• Noise comes from an inline xorshift rather than
##   [RandomNumberGenerator], so a sample costs arithmetic instead of a call
##   into the engine.
## [br]• Every layer is gated: a bird that is not stalling, not flapping, not in
##   lift and not near the ground pays for the wind and nothing else.
## [br]• Samples are pushed a buffer at a time, not a frame at a time.
## [br]Measured with [code]tests/audio_report.gd[/code]; the budget is asserted
## in [code]AudioTests._test_synthesis_is_cheap[/code].

## 16 kHz, not 22 kHz. This layer is wind, rumble and whoosh — there is nothing
## above 8 kHz in it that a headset speaker reproduces, and the rate is a
## straight 27 % of the CPU cost. The bird calls in [VoiceBank] are baked at a
## higher rate and cost nothing at playback, because the engine mixes them in C++.
const SAMPLE_RATE: float = 16000.0

## Airspeed at which wind reaches full volume. Well above trim (17.5 m/s) and
## just under the dive cap (78.5 m/s), so a stoop keeps getting louder nearly all
## the way down instead of topping out halfway. Trim to a full dive is a twelvefold
## change in level — about 21 dB, which is a speed cue you could fly on alone.
const FULL_WIND_SPEED: float = 66.0
const WIND_GAIN: float = 0.46
## How much of the wind is the low roar of air over spread wings, versus the
## hiss over a tucked body. Both scale with speed; only the balance moves.
const BODY_TRIM: float = 0.62
const HISS_TRIM: float = 0.30

## Wingbeat. The swish sweeps down in pitch as the wing slows through the
## stroke, which is what makes it read as one gesture rather than a burst.
const BEAT_GAIN: float = 0.85
const BEAT_ATTACK: float = 0.012
const BEAT_DECAY: float = 0.26
const BEAT_TOP_HZ: float = 1500.0
const BEAT_BOTTOM_HZ: float = 240.0
## The thump of displaced air. Lower for a bigger bird — a heron does not sound
## like a swift, and this is where the player hears themselves grow.
const THUMP_HZ: float = 105.0
const THUMP_GAIN: float = 0.55

## Stall. A buffet is separated air banging on the wing: broadband noise chopped
## at a low, irregular rate. It is the one sound in the game that is meant to be
## unpleasant, and it arrives before the HUD can say STALL.
const BUFFET_HZ: float = 13.0
const BUFFET_GAIN: float = 0.42
const BUFFET_DEPTH: float = 0.85

## The land below, and how fast it fades as you climb. This is the altitude cue:
## by 300 m the world under you has gone quiet and there is nothing but air.
const BED_GAIN: float = 0.11
const BED_FADE: float = 110.0

## Lift. A thermal is smooth air, so it arrives as a low swell and a slight
## easing of the hiss rather than as more noise.
const LIFT_GAIN: float = 0.30
const LIFT_FULL: float = 6.0
const LIFT_HUSH: float = 0.18

## Above this the mix bends instead of clipping. A hard clamp on a wind bed is
## audible as a crackle the moment two loud things land in the same frame.
const SOFT_KNEE: float = 0.80

## Seconds for the slow envelopes to follow the flight. Fast enough that a dive
## is heard as it happens, slow enough that a frame of jitter is not.
const FOLLOW_TAU: float = 0.09

# xorshift32. Two independent streams, so the left and right ears hear
# decorrelated air — mono noise duplicated to both channels collapses into a
# point between the eyes, which is precisely the wrong image for being inside a
# moving airstream.
const _MASK: int = 0xFFFFFFFF
const _NOISE_SCALE: float = 2.0 / 4294967295.0

var _left_seed: int = 0x9E3779B9
var _right_seed: int = 0x85EBCA6B
var _gust_rng := RandomNumberGenerator.new()

# Filter state. All of it is one-pole memory, and all of it is repaired rather
# than reset if it ever goes non-finite: a NaN in a one-pole filter is permanent.
var _low_l: float = 0.0
var _sub_l: float = 0.0
var _low_r: float = 0.0
var _sub_r: float = 0.0
var _bed_a: float = 0.0
var _bed_b: float = 0.0
var _lift_a: float = 0.0
var _lift_b: float = 0.0
var _buffet_a: float = 0.0
var _buffet_b: float = 0.0
var _beat_a: float = 0.0
var _beat_b: float = 0.0
var _thump: float = 0.0
var _buffet_phase: float = 0.0
var _buffet_jitter: float = 1.0

# Targets, set once per frame by [method update] and ramped across the buffer by
# [method render] so nothing steps at the buffer boundary.
var _body_gain: float = 0.0
var _hiss_gain: float = 0.0
var _cross: float = 0.2
var _bed_level: float = 0.0
var _bed_cut: float = 0.05
var _lift_level: float = 0.0
var _buffet_level: float = 0.0
var _beat_level: float = 0.0
var _beat_cut: float = 0.2
var _thump_level: float = 0.0
var _thump_cut: float = 0.045
var _pan_l: float = 1.0
var _pan_r: float = 1.0

# Rendered values, i.e. where the last buffer left each ramp.
var _r_body: float = 0.0
var _r_hiss: float = 0.0
var _r_cross: float = 0.2
var _r_bed: float = 0.0
var _r_lift: float = 0.0
var _r_buffet: float = 0.0
var _r_beat: float = 0.0
var _r_beat_cut: float = 0.2
var _r_thump: float = 0.0

var _beat_time: float = 1000.0
var _beat_strength: float = 0.0
var _was_stroking: bool = false
var _gust: float = 1.0
var _gust_target: float = 1.0
var _clock: float = 0.0

var _buffer := PackedVector2Array()
## Peak of the last rendered buffer, for a meter or a test.
var peak: float = 0.0


func _init(noise_seed: int = 20260813) -> void:
	_gust_rng.seed = noise_seed
	# A zero xorshift state is a fixed point that emits silence forever.
	_left_seed = (noise_seed | 1) & _MASK
	_right_seed = ((noise_seed * 2654435761) | 1) & _MASK


## Reads the flight and moves every envelope towards where it should be. Called
## once a frame; [method render] then fills however many samples the audio
## hardware asked for.
func update(state: SoundState, delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var dt: float = minf(delta, 0.1)
	state.sanitize()
	_clock += dt

	var intensity: float = clampf(state.airspeed / FULL_WIND_SPEED, 0.0, 1.0)
	if state.perched:
		# A bird on a branch still hears the breeze, but it is not flying through
		# anything. Without this a perched player sits in a roaring wind.
		intensity *= 0.12

	# Gusts. A dead-steady hiss reads as a machine; real air breathes. Slow
	# enough (about 1.5 s) that it can never be mistaken for a speed change.
	if _clock >= 1.0:
		_clock = 0.0
		_gust_target = _gust_rng.randf_range(0.90, 1.10)
	_gust = lerpf(_gust, _gust_target, clampf(dt * 1.4, 0.0, 1.0))

	# Spread wings at speed roar; a tuck is quieter and thinner, and the
	# crossover between the two bands is what carries the difference. Volume
	# alone would only say "slower", which is a lie — a tuck is faster.
	# Level goes as speed to the power of one and a half, not two. Real wind noise
	# is nearer a square, but a square puts 26 dB between trim and a full stoop:
	# set loud enough that a dive is not painful, a cruise is then inaudible.
	# This keeps 20 dB, which is still a speed cue you could fly on blind.
	var loudness: float = intensity * sqrt(intensity) * WIND_GAIN * _gust
	var hush: float = 1.0 - LIFT_HUSH * clampf(state.lift / LIFT_FULL, 0.0, 1.0)
	var body: float = loudness * lerpf(0.30, 1.0, state.span) * BODY_TRIM
	var hiss: float = loudness * lerpf(1.0, 0.72, state.span) * HISS_TRIM * hush
	# Crossover: 350 Hz spread and slow, up past 2 kHz tucked and fast. Moving it
	# up moves energy out of the body band and into the hiss band, which is
	# exactly what a small fast shape in the air does.
	var cross_hz: float = lerpf(340.0, 1900.0, intensity) * lerpf(1.6, 0.75, state.span)

	var blend: float = clampf(dt / FOLLOW_TAU, 0.0, 1.0)
	_body_gain = lerpf(_body_gain, body, blend)
	_hiss_gain = lerpf(_hiss_gain, hiss, blend)
	_cross = lerpf(_cross, _coefficient(cross_hz), blend)

	# The land below. Falls away with height and is the game's altitude cue; a
	# forest rustles brighter than open ground does.
	var closeness: float = 1.0 / (1.0 + state.altitude / BED_FADE)
	closeness *= closeness
	_bed_level = lerpf(_bed_level, closeness * BED_GAIN, blend)
	_bed_cut = lerpf(_bed_cut, _coefficient(lerpf(300.0, 900.0, state.canopy)), blend)

	_lift_level = lerpf(
		_lift_level, clampf(state.lift / LIFT_FULL, 0.0, 1.0) * LIFT_GAIN, blend
	)
	_buffet_level = lerpf(_buffet_level, state.stall * BUFFET_GAIN, blend)

	_update_beat(state, dt)


## The wingbeat, triggered on the leading edge of a downstroke and then left to
## run on its own clock. Retriggering mid-beat would clip the previous one, and
## a wingbeat that is cut short sounds like a fault rather than like effort.
func _update_beat(state: SoundState, dt: float) -> void:
	var stroking: bool = state.stroke_speed > 0.4
	if stroking and not _was_stroking:
		var strength: float = clampf(state.stroke_speed / 3.5, 0.25, 1.0)
		# Folded wings move very little air. This is also the audible half of the
		# WINGS FOLDED failure: flapping a tucked wing does not sound like flying.
		strength *= lerpf(0.25, 1.0, state.span)
		if _beat_time > BEAT_ATTACK * 2.0 or strength > _beat_strength:
			_beat_time = 0.0
			_beat_strength = strength
			var side: float = clampf(state.asymmetry, -1.0, 1.0)
			_pan_l = clampf(1.0 - maxf(side, 0.0) * 0.85, 0.0, 1.0)
			_pan_r = clampf(1.0 + minf(side, 0.0) * 0.85, 0.0, 1.0)
	_was_stroking = stroking

	_beat_time += dt
	var shape: float = _beat_envelope(_beat_time)
	_beat_level = shape * _beat_strength * BEAT_GAIN
	_thump_level = shape * _beat_strength * THUMP_GAIN
	# The swish sweeps down as the wing slows: bright at the top of the stroke,
	# dark by the end of it.
	var progress: float = clampf(_beat_time / BEAT_DECAY, 0.0, 1.0)
	_beat_cut = _coefficient(lerpf(BEAT_TOP_HZ, BEAT_BOTTOM_HZ, progress))
	# A bigger wing moves more air more slowly. This is where a player hears
	# themselves grow: the same gesture, an octave down by the top of the ladder.
	_thump_cut = _coefficient(THUMP_HZ / pow(maxf(state.size, 0.2), 0.34))


## Fast in, slow out — the shape of air being pushed and then letting go.
static func _beat_envelope(time: float) -> float:
	if time < 0.0:
		return 0.0
	if time < BEAT_ATTACK:
		return time / BEAT_ATTACK
	var fall: float = (time - BEAT_ATTACK) / BEAT_DECAY
	if fall >= 1.0:
		return 0.0
	# Cubic falloff: quicker than linear at the start, with a long tail.
	var remaining: float = 1.0 - fall
	return remaining * remaining * remaining


## One-pole coefficient for a corner frequency. The exact form, not the
## small-angle approximation, because a crossover at 3 kHz against a 16 kHz rate
## is nowhere near small — and this is called once a frame, not once a sample.
static func _coefficient(hz: float) -> float:
	return clampf(1.0 - exp(-TAU * maxf(hz, 1.0) / SAMPLE_RATE), 0.0005, 0.98)


## Fills [param frames] stereo samples.
##
## Returns a buffer this object owns and reuses, the same way
## [method WingInput.update] returns the same [FlightCommand] every frame.
## Consume it or copy it before the next call.
func render(frames: int) -> PackedVector2Array:
	if frames <= 0:
		return PackedVector2Array()
	if _buffer.size() != frames:
		_buffer.resize(frames)
	_repair()

	var inverse: float = 1.0 / float(frames)
	# Every slow parameter is ramped across the buffer rather than stepped at its
	# edge. At 16 kHz a buffer is a few milliseconds; a step in a noise gain that
	# size is an audible tick.
	var body: float = _r_body
	var body_step: float = (_body_gain - _r_body) * inverse
	var hiss: float = _r_hiss
	var hiss_step: float = (_hiss_gain - _r_hiss) * inverse
	var cross: float = _r_cross
	var cross_step: float = (_cross - _r_cross) * inverse
	var bed: float = _r_bed
	var bed_step: float = (_bed_level - _r_bed) * inverse
	var lift: float = _r_lift
	var lift_step: float = (_lift_level - _r_lift) * inverse
	var buffet: float = _r_buffet
	var buffet_step: float = (_buffet_level - _r_buffet) * inverse
	var beat: float = _r_beat
	var beat_step: float = (_beat_level - _r_beat) * inverse
	var beat_cut: float = _r_beat_cut
	var beat_cut_step: float = (_beat_cut - _r_beat_cut) * inverse
	var thump: float = _r_thump
	var thump_step: float = (_thump_level - _r_thump) * inverse

	# Locals for everything the loop touches: a member read in GDScript is a
	# dictionary lookup and this loop runs sixteen thousand times a second.
	var seed_l: int = _left_seed
	var seed_r: int = _right_seed
	var low_l: float = _low_l
	var sub_l: float = _sub_l
	var low_r: float = _low_r
	var sub_r: float = _sub_r
	var bed_a: float = _bed_a
	var bed_b: float = _bed_b
	var bed_cut: float = _bed_cut
	var lift_a: float = _lift_a
	var lift_b: float = _lift_b
	var buffet_a: float = _buffet_a
	var buffet_b: float = _buffet_b
	var beat_a: float = _beat_a
	var beat_b: float = _beat_b
	var thump_state: float = _thump
	var thump_cut: float = _thump_cut
	var phase: float = _buffet_phase
	var jitter: float = _buffet_jitter
	var pan_l: float = _pan_l
	var pan_r: float = _pan_r

	# Sub-bass corner for the body band, and the gains that make each band's
	# level mean the same thing regardless of where the crossover sits.
	var sub_cut: float = 0.010
	var phase_step: float = BUFFET_HZ / SAMPLE_RATE
	var quiet: bool = (
		bed < 1e-4 and _bed_level < 1e-4
		and lift < 1e-4 and _lift_level < 1e-4
		and buffet < 1e-4 and _buffet_level < 1e-4
		and beat < 1e-4 and _beat_level < 1e-4
	)
	var loudest: float = 0.0

	for i in frames:
		seed_l ^= (seed_l << 13) & _MASK
		seed_l ^= seed_l >> 17
		seed_l ^= (seed_l << 5) & _MASK
		var n: float = float(seed_l) * _NOISE_SCALE - 1.0
		seed_r ^= (seed_r << 13) & _MASK
		seed_r ^= seed_r >> 17
		seed_r ^= (seed_r << 5) & _MASK
		var m: float = float(seed_r) * _NOISE_SCALE - 1.0

		body += body_step
		hiss += hiss_step
		cross += cross_step

		# Two one-poles per ear split the noise into a roar and a hiss at the
		# crossover. Three operations each, and the difference of two poles is a
		# band without a biquad.
		low_l += (n - low_l) * cross
		sub_l += (low_l - sub_l) * sub_cut
		var left: float = (low_l - sub_l) * body * 3.2 + (n - low_l) * hiss
		low_r += (m - low_r) * cross
		sub_r += (low_r - sub_r) * sub_cut
		var right: float = (low_r - sub_r) * body * 3.2 + (m - low_r) * hiss

		if not quiet:
			bed += bed_step
			lift += lift_step
			buffet += buffet_step
			beat += beat_step
			beat_cut += beat_cut_step
			thump += thump_step

			# The land: noise dragged down to a murmur by two poles.
			bed_a += (n - bed_a) * bed_cut
			bed_b += (bed_a - bed_b) * bed_cut
			var ground: float = bed_b * bed * 4.4

			# Lift: a slow swell under everything, felt more than heard.
			lift_a += (m - lift_a) * 0.030
			lift_b += (lift_a - lift_b) * 0.030
			var swell: float = lift_b * lift * 2.6

			# Stall: mid noise chopped at about 13 Hz, with the chop wandering so
			# it never turns into a tone.
			var chopped: float = 0.0
			if buffet > 1e-4:
				phase += phase_step * jitter
				if phase >= 1.0:
					phase -= 1.0
					jitter = 0.82 + 0.36 * (n * 0.5 + 0.5)
				var tri: float = phase + phase if phase < 0.5 else 2.0 - phase - phase
				buffet_a += (n - buffet_a) * 0.28
				buffet_b += (buffet_a - buffet_b) * 0.045
				chopped = (buffet_a - buffet_b) * buffet * (
					1.0 - BUFFET_DEPTH + BUFFET_DEPTH * tri
				) * 2.6

			# The wingbeat: a swish sweeping down, and the thump of moved air.
			var stroke: float = 0.0
			if beat > 1e-5:
				beat_a += (n - beat_a) * beat_cut
				beat_b += (beat_a - beat_b) * 0.020
				thump_state += (m - thump_state) * thump_cut
				stroke = (beat_a - beat_b) * beat * 2.4 + thump_state * thump * 6.0

			var shared: float = ground + swell + chopped
			left += shared + stroke * pan_l
			right += shared + stroke * pan_r

		# Soft knee rather than a clamp: two loud things landing in the same
		# sample should bend the mix, not crackle.
		if left > SOFT_KNEE:
			left = SOFT_KNEE + (left - SOFT_KNEE) / (1.0 + (left - SOFT_KNEE) * 5.0)
		elif left < -SOFT_KNEE:
			left = -SOFT_KNEE + (left + SOFT_KNEE) / (1.0 - (left + SOFT_KNEE) * 5.0)
		if right > SOFT_KNEE:
			right = SOFT_KNEE + (right - SOFT_KNEE) / (1.0 + (right - SOFT_KNEE) * 5.0)
		elif right < -SOFT_KNEE:
			right = -SOFT_KNEE + (right + SOFT_KNEE) / (1.0 - (right + SOFT_KNEE) * 5.0)

		if left > loudest:
			loudest = left
		elif -left > loudest:
			loudest = -left
		if right > loudest:
			loudest = right
		elif -right > loudest:
			loudest = -right
		_buffer[i] = Vector2(left, right)

	_left_seed = seed_l
	_right_seed = seed_r
	_low_l = low_l
	_sub_l = sub_l
	_low_r = low_r
	_sub_r = sub_r
	_bed_a = bed_a
	_bed_b = bed_b
	_lift_a = lift_a
	_lift_b = lift_b
	_buffet_a = buffet_a
	_buffet_b = buffet_b
	_beat_a = beat_a
	_beat_b = beat_b
	_thump = thump_state
	_buffet_phase = phase
	_buffet_jitter = jitter

	_r_body = _body_gain
	_r_hiss = _hiss_gain
	_r_cross = _cross
	_r_bed = _bed_level
	_r_lift = _lift_level
	_r_buffet = _buffet_level
	_r_beat = _beat_level
	_r_beat_cut = _beat_cut
	_r_thump = _thump_level
	peak = loudest
	return _buffer


## A NaN reaching a one-pole filter never leaves it — the state feeds itself, so
## the game would be silent from that frame until it was restarted. Cheap
## insurance, once per buffer rather than once per sample.
func _repair() -> void:
	if is_finite(_low_l + _sub_l + _low_r + _sub_r + _bed_a + _bed_b) \
			and is_finite(_lift_a + _lift_b + _buffet_a + _buffet_b) \
			and is_finite(_beat_a + _beat_b + _thump + _buffet_phase):
		return
	_low_l = 0.0
	_sub_l = 0.0
	_low_r = 0.0
	_sub_r = 0.0
	_bed_a = 0.0
	_bed_b = 0.0
	_lift_a = 0.0
	_lift_b = 0.0
	_buffet_a = 0.0
	_buffet_b = 0.0
	_beat_a = 0.0
	_beat_b = 0.0
	_thump = 0.0
	_buffet_phase = 0.0
	_buffet_jitter = 1.0


## Where the beat envelope currently is, 0..1 — for a test or a meter.
func beat_envelope() -> float:
	return _beat_envelope(_beat_time) * _beat_strength
