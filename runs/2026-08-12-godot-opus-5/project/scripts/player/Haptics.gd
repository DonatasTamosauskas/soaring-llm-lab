class_name Haptics
extends RefCounted

## The bird's sense of touch: one mixer that turns everything happening to a
## player into something their hands can feel, with enough texture that they can
## tell the events apart without looking.
##
## Scene-free on purpose, exactly like [FlightModel] and [WingInput]. It takes
## events in and hands out an amplitude and a frequency per hand each frame;
## [BirdPlayer] is the only thing that knows a controller exists. That is what
## lets "a catch does not feel like a wingbeat" and "the controllers never turn
## into a continuous buzz" be assertions in a headless suite rather than
## opinions formed while wearing a headset.
##
## Three ideas do all the work:
##
## [b]Envelopes[/b] — every cue is a short list of ramps, so a wingbeat can
## swell and fade while a collision cracks and stops. A rumble motor cannot
## reproduce a waveform, but it can reproduce a shape, and shape is what the
## hand actually reads.
##
## [b]Frequency[/b] — the second channel, and the one that separates cues an
## envelope alone would blur. Low is soft and bodily (a wingbeat, air pushing
## up under the wings); high is sharp and mechanical (a strike, a claw catching
## a branch).
##
## [b]Textures[/b] — states rather than events (riding lift, stalling) throb
## instead of buzzing: they spend most of every cycle silent. A continuous
## vibration stops being information within about ten seconds and becomes
## fatigue for the rest of the session.

const LEFT: int = 0
const RIGHT: int = 1

## Below this a pulse is not worth sending to the runtime — it is under the
## motors' own threshold and only costs an OpenXR call.
const SILENCE: float = 0.02

## Ceiling on how much of the recent past may have been spent buzzing. Textures
## are the first thing dropped when the hands have been busy: an event is
## information the player asked for, a texture is ambience.
const MAX_LOAD: float = 0.55
const LOAD_RELEASE: float = 0.40
## Seconds the load average looks back over.
const LOAD_WINDOW: float = 2.0

## Every cue, as: how loud, how long, what shape, what pitch, and how insistent.
##
## [code]envelope[/code] is a list of [duration, amplitude at the start of the
## segment, amplitude at the end]. [code]priority[/code] decides what happens
## when two cues collide — a catch interrupts a wingbeat, a wingbeat never
## interrupts being caught. [code]interval[/code] is the shortest gap between
## two of the same cue, which is what stops a fast beat, a bounce down a
## hillside or a burst of events turning the controllers into a doorbell.
const CUES: Dictionary = {
	# A soft, bodily thump with a fast rise and a long fall: the wing loading up
	# and then the air letting go of it.
	&"wingbeat": {
		"priority": 1, "frequency": 62.0, "interval": 0.22,
		"envelope": [[0.014, 0.10, 1.00], [0.085, 1.00, 0.00]],
	},
	# Two quick bites. Nothing else in the game is a double, so a catch is
	# identifiable with your eyes shut.
	&"catch": {
		"priority": 4, "frequency": 165.0, "interval": 0.12,
		"envelope": [
			[0.006, 0.55, 1.00], [0.032, 1.00, 0.15], [0.028, 0.00, 0.00],
			[0.006, 0.45, 0.95], [0.055, 0.95, 0.00],
		],
	},
	# Long, low and unpleasant, in both hands, and the only cue allowed to last
	# a third of a second: something bigger than you just took a life.
	&"caught": {
		"priority": 6, "frequency": 42.0, "interval": 0.40,
		"envelope": [[0.020, 0.60, 1.00], [0.090, 1.00, 0.70], [0.230, 0.70, 0.00]],
	},
	# A crack with no swell at all — the whole point is that it arrives before
	# you can brace, the way hitting a branch does.
	&"impact": {
		"priority": 5, "frequency": 120.0, "interval": 0.18,
		"envelope": [[0.004, 1.00, 1.00], [0.100, 0.85, 0.00]],
	},
	# High and short: claws finding bark.
	&"cling": {
		"priority": 3, "frequency": 210.0, "interval": 0.25,
		"envelope": [[0.006, 0.90, 0.90], [0.045, 0.55, 0.00]],
	},
	# The mirror of cling: a swell rather than a click, because a launch is a
	# push you make rather than a thing that arrives.
	&"launch": {
		"priority": 3, "frequency": 88.0, "interval": 0.25,
		"envelope": [[0.030, 0.20, 0.95], [0.110, 0.85, 0.00]],
	},
	# Three rising ticks. Read as "something good, and there is more of it".
	&"rank_up": {
		"priority": 4, "frequency": 150.0, "interval": 0.40,
		"envelope": [
			[0.035, 0.45, 0.45], [0.045, 0.00, 0.00],
			[0.035, 0.70, 0.70], [0.045, 0.00, 0.00],
			[0.070, 1.00, 0.00],
		],
	},
	# Two soft taps to confirm a gesture the player made deliberately. Quiet on
	# purpose: a confirmation that startles you is a punishment.
	&"recentre": {
		"priority": 3, "frequency": 240.0, "interval": 0.50,
		"envelope": [
			[0.030, 0.40, 0.40], [0.050, 0.00, 0.00], [0.030, 0.40, 0.00],
		],
	},
}

## States you are in rather than things that happen to you. Each is a throb:
## [code]rate[/code] beats a second, of which only [code]duty[/code] carries any
## amplitude at all, so the hands fall silent between pulses.
const TEXTURES: Dictionary = {
	# The air pushing up under the wings. Slow, low, and easy to ignore — it is
	# the one cue that tells a soaring pilot they are in lift while they are
	# looking somewhere else entirely.
	&"thermal": {"ceiling": 0.22, "frequency": 55.0, "rate": 1.5, "duty": 0.34},
	# Rough, quick and irritating, which is exactly what a stall is.
	&"stall": {"ceiling": 0.30, "frequency": 150.0, "rate": 8.0, "duty": 0.5},
}

## Longest any one cue may last. A haptic event that outlives the moment it
## describes stops being that moment and becomes vibration.
const MAX_CUE_SECONDS: float = 0.35

var _cue: StringName = &""
var _cue_time: float = 0.0
var _cue_strength: float = 1.0
var _cue_balance: float = 0.0
var _cue_priority: int = 0
var _last_fired: Dictionary = {}

var _texture_level: Dictionary = {}
var _texture_phase: Dictionary = {}

var _amplitude: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _frequency: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _clock: float = 0.0
var _load: float = 0.0
var _load_locked: bool = false


func _init() -> void:
	for name: StringName in TEXTURES:
		_texture_level[name] = 0.0
		_texture_phase[name] = 0.0


## Plays [param cue] at [param strength] (0..1). [param balance] biases it to one
## hand: −1 is entirely the left, +1 entirely the right, 0 is both. Asymmetry is
## not decoration — a one-armed wingbeat felt in one arm is the clearest possible
## statement of what the bird just did.
func fire(cue: StringName, strength: float = 1.0, balance: float = 0.0) -> void:
	var spec: Dictionary = CUES.get(cue, {}) as Dictionary
	if spec.is_empty():
		return
	var level: float = clampf(strength if is_finite(strength) else 0.0, 0.0, 1.0)
	if level <= SILENCE:
		return
	var since: float = _clock - float(_last_fired.get(cue, -1000.0))
	if since < float(spec["interval"]):
		return
	var priority: int = int(spec["priority"])
	# A quieter, less urgent cue never interrupts a louder one. Without this a
	# wingbeat during a death rumble would cut the death rumble short, and the
	# player would be told the smaller of the two things that just happened.
	if _cue != &"" and priority < _cue_priority:
		return
	_cue = cue
	_cue_priority = priority
	_cue_time = 0.0
	_cue_strength = level
	_cue_balance = clampf(balance if is_finite(balance) else 0.0, -1.0, 1.0)
	_last_fired[cue] = _clock


## Sets how strongly a continuous state is being felt, 0 to 1. Called every frame
## with the current value; there is no "stop", because states end by fading.
func texture(name: StringName, level: float) -> void:
	if not TEXTURES.has(name):
		return
	_texture_level[name] = clampf(level if is_finite(level) else 0.0, 0.0, 1.0)


func update(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var dt: float = minf(delta, 0.1)
	_clock += dt

	var left: float = 0.0
	var right: float = 0.0
	var frequency: float = 0.0

	if _cue != &"":
		var spec: Dictionary = CUES[_cue] as Dictionary
		_cue_time += dt
		var value: float = _envelope_at(spec["envelope"] as Array, _cue_time)
		if value < 0.0:
			_cue = &""
			_cue_priority = 0
		else:
			var amplitude: float = value * _cue_strength
			left = amplitude * clampf(1.0 - maxf(_cue_balance, 0.0), 0.0, 1.0)
			right = amplitude * clampf(1.0 + minf(_cue_balance, 0.0), 0.0, 1.0)
			frequency = float(spec["frequency"])

	# Textures sit underneath, and only where an event is not already speaking.
	# Feeling lift through a collision would be two facts competing for one
	# motor, and neither would arrive.
	var texture_amplitude: float = 0.0
	var texture_frequency: float = 0.0
	for name: StringName in TEXTURES:
		var spec: Dictionary = TEXTURES[name] as Dictionary
		var level: float = float(_texture_level[name])
		var phase: float = fposmod(
			float(_texture_phase[name]) + dt * float(spec["rate"]), 1.0
		)
		_texture_phase[name] = phase
		if level <= 0.01 or _load_locked:
			continue
		var shaped: float = _throb(phase, float(spec["duty"]))
		var amplitude: float = shaped * level * float(spec["ceiling"])
		if amplitude > texture_amplitude:
			texture_amplitude = amplitude
			texture_frequency = float(spec["frequency"])

	if texture_amplitude > 0.0:
		if left <= SILENCE and right <= SILENCE:
			frequency = texture_frequency
		left = maxf(left, texture_amplitude)
		right = maxf(right, texture_amplitude)

	_amplitude[LEFT] = clampf(left, 0.0, 1.0)
	_amplitude[RIGHT] = clampf(right, 0.0, 1.0)
	_frequency[LEFT] = frequency
	_frequency[RIGHT] = frequency
	_update_load(dt)


## Running estimate of how much of the recent past the hands spent vibrating,
## with hysteresis so the ambience does not chatter on and off at the threshold.
## This is the backstop that makes "never a continuous buzz" true even if some
## future caller holds every texture at 1.0 forever.
func _update_load(dt: float) -> void:
	var busy: float = 1.0 if maxf(_amplitude[LEFT], _amplitude[RIGHT]) > SILENCE else 0.0
	var weight: float = clampf(dt / LOAD_WINDOW, 0.0, 1.0)
	_load = lerpf(_load, busy, weight)
	if _load_locked:
		_load_locked = _load > LOAD_RELEASE
	else:
		_load_locked = _load > MAX_LOAD


## One throb: a smooth swell over the first [param duty] of the cycle, silence
## for the rest.
static func _throb(phase: float, duty: float) -> float:
	if phase > duty or duty <= 0.0:
		return 0.0
	return sin(phase / duty * PI)


## The envelope's value at [param time], or −1 once it has run out.
static func _envelope_at(envelope: Array, time: float) -> float:
	var elapsed: float = 0.0
	for segment: Array in envelope:
		var length: float = float(segment[0])
		if time < elapsed + length:
			var u: float = clampf((time - elapsed) / maxf(length, 1e-6), 0.0, 1.0)
			return lerpf(float(segment[1]), float(segment[2]), u)
		elapsed += length
	return -1.0


static func cue_seconds(cue: StringName) -> float:
	var spec: Dictionary = CUES.get(cue, {}) as Dictionary
	if spec.is_empty():
		return 0.0
	var total: float = 0.0
	for segment: Array in spec["envelope"] as Array:
		total += float(segment[0])
	return total


func amplitude(hand: int) -> float:
	return _amplitude[clampi(hand, 0, 1)]


## Hertz, or 0 for "whatever the runtime thinks is normal". Passed straight
## through to [method XRController3D.trigger_haptic_pulse].
func frequency(hand: int) -> float:
	return _frequency[clampi(hand, 0, 1)]


func is_silent() -> bool:
	return maxf(_amplitude[LEFT], _amplitude[RIGHT]) <= SILENCE


## What is playing right now, for a test or a diagnostic to name.
func playing() -> StringName:
	return _cue


func load_factor() -> float:
	return _load


func reset() -> void:
	_cue = &""
	_cue_priority = 0
	_cue_time = 0.0
	_load = 0.0
	_load_locked = false
	_last_fired.clear()
	for name: StringName in TEXTURES:
		_texture_level[name] = 0.0
		_texture_phase[name] = 0.0
	_amplitude[LEFT] = 0.0
	_amplitude[RIGHT] = 0.0
	_frequency[LEFT] = 0.0
	_frequency[RIGHT] = 0.0
