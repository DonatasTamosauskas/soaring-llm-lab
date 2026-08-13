class_name AudioTests
extends RefCounted

## What the game sounds like, asserted on the samples it actually generates.
##
## Audio shipped with no suite at all: five classes and about eighteen hundred
## lines wired into [BirdPlayer] through [FlightAudio], running on every launch,
## with nothing in [code]tests/run_tests.gd[/code] looking at any of it. The
## measuring instruments already existed ([AudioAnalysis]) and so did the
## instrument panel ([code]tests/audio_report.gd[/code]); what was missing was
## anything that fails. [Soundscape] and [VoiceBank] both name this file in
## their own doc comments, so this is the suite they were written expecting.
##
## Everything here is scene-free, like the rest of the suite, with one exception
## that is called out where it happens: [AudioDirector] owns real emitters, and
## the one defect worth pinning in it is where a node ends up.
##
## Numbers come from `tests/audio_report.gd`, run against this build. Where a
## bound is loose it is loose on purpose — the claim is the shape of the sound,
## not the third decimal place of a tuning constant.

const RATE: float = Soundscape.SAMPLE_RATE


static func run(t: TestCase) -> void:
	_test_wind_is_the_speedometer(t)
	_test_a_tuck_sounds_thinner_than_a_glide(t)
	_test_the_land_below_fades_as_you_climb(t)
	_test_a_wingbeat_is_an_event_not_a_level(t)
	_test_a_one_winged_beat_is_heard_in_that_ear(t)
	_test_a_stall_buffets(t)
	_test_lift_is_a_swell_not_a_hiss(t)
	_test_the_mix_never_clips(t)
	_test_the_synthesiser_survives_a_poisoned_frame(t)
	_test_synthesis_is_cheap(t)
	_test_every_clip_the_game_can_play_exists(t)
	_test_species_do_not_sound_alike(t)
	_test_you_can_hear_what_is_about_to_eat_you(t)
	_test_the_sky_never_shouts_all_at_once(t)
	_test_the_flock_does_not_leak_its_bookkeeping(t)
	_test_the_town_is_where_the_town_is(t)


# --- the air ------------------------------------------------------------------


## Renders [param seconds] of a held state, the way [FlightAudio] would.
static func fly(state: SoundState, seconds: float, scape: Soundscape = null) -> PackedVector2Array:
	var sound: Soundscape = scape if scape != null else Soundscape.new()
	var out := PackedVector2Array()
	var frames: int = int(seconds * RATE)
	out.resize(frames)
	var written: int = 0
	while written < frames:
		var count: int = mini(256, frames - written)
		sound.update(state, float(count) / RATE)
		var rendered: PackedVector2Array = sound.render(count)
		for i in count:
			out[written + i] = rendered[i]
		written += count
	return out


static func _state(airspeed: float, span: float = 1.0, altitude: float = 400.0) -> SoundState:
	var state := SoundState.new()
	state.airspeed = airspeed
	state.span = span
	state.altitude = altitude
	return state


static func _mono(state: SoundState, seconds: float) -> PackedFloat32Array:
	return AudioAnalysis.mono(fly(state, seconds))


## The claim [Soundscape] exists to make: how fast you are going is something you
## can hear without looking at anything.
static func _test_wind_is_the_speedometer(t: TestCase) -> void:
	t.begin("wind is the speedometer")
	var previous: float = 0.0
	var levels: Dictionary = {}
	for speed: float in [0.0, 6.0, 12.0, 17.5, 25.0, 35.0, 45.0, 58.0, 78.0]:
		var samples: PackedFloat32Array = _mono(_state(speed), 1.2)
		var level: float = AudioAnalysis.rms(samples)
		t.greater(level, previous, "%.1f m/s is louder than the speed below it" % speed)
		previous = level
		levels[speed] = level
	# Trim to a full dive is the range the ear has to work with. Measured 10.4x,
	# about 20 dB; anything under 6x and the cue stops carrying over a headset.
	t.greater(
		float(levels[78.0]) / maxf(float(levels[17.5]), 1e-6), 6.0,
		"a dive is many times the volume of a glide"
	)
	t.less(float(levels[0.0]), 0.01, "and a bird going nowhere makes almost no noise")

	# Brightness carries the same information independently of volume, which is
	# what keeps the cue alive when somebody turns the game down.
	var slow: PackedFloat32Array = AudioAnalysis.spectrum(_mono(_state(12.0), 1.2), 2048)
	var fast: PackedFloat32Array = AudioAnalysis.spectrum(_mono(_state(58.0), 1.2), 2048)
	t.greater(
		AudioAnalysis.centroid(fast, RATE), AudioAnalysis.centroid(slow, RATE) + 300.0,
		"and fast air is brighter air, not merely louder"
	)

	# Two ears, not one point between them. Air you are inside of is decorrelated.
	t.greater(
		AudioAnalysis.decorrelation(fly(_state(35.0), 1.0)), 0.25,
		"the airstream is around you rather than in front of you"
	)


static func _test_a_tuck_sounds_thinner_than_a_glide(t: TestCase) -> void:
	t.begin("a tuck sounds thinner than a glide")
	var previous_level: float = 1e9
	var previous_centroid: float = 0.0
	for span: float in [1.0, 0.7, 0.4, 0.15, 0.0]:
		var samples: PackedFloat32Array = _mono(_state(35.0, span), 1.2)
		var level: float = AudioAnalysis.rms(samples)
		var bright: float = AudioAnalysis.centroid(
			AudioAnalysis.spectrum(samples, 2048), RATE
		)
		t.less(level, previous_level, "span %.2f is quieter than the span above it" % span)
		t.greater(bright, previous_centroid, "and thinner (span %.2f)" % span)
		previous_level = level
		previous_centroid = bright
	# The whole point: at one airspeed, wings alone change the sound enough to
	# hear. Measured 2245 Hz spread against 3378 Hz tucked.
	var spread: float = AudioAnalysis.centroid(
		AudioAnalysis.spectrum(_mono(_state(35.0, 1.0), 1.2), 2048), RATE
	)
	var tucked: float = AudioAnalysis.centroid(
		AudioAnalysis.spectrum(_mono(_state(35.0, 0.0), 1.2), 2048), RATE
	)
	t.greater(tucked - spread, 700.0, "tucking is an audible gesture at one speed")


static func _test_the_land_below_fades_as_you_climb(t: TestCase) -> void:
	t.begin("the land below fades as you climb")
	var previous: float = 1e9
	for altitude: float in [0.0, 20.0, 60.0, 120.0, 250.0, 500.0]:
		var state: SoundState = _state(17.5, 1.0, altitude)
		var samples: PackedFloat32Array = _mono(state, 1.2)
		var low: float = AudioAnalysis.band(
			AudioAnalysis.spectrum(samples, 2048), RATE, 0.0, 300.0
		)
		t.less(low, previous, "the ground is quieter at %.0f m than below it" % altitude)
		previous = low
	var ground: float = AudioAnalysis.rms(_mono(_state(17.5, 1.0, 0.0), 1.2))
	var high: float = AudioAnalysis.rms(_mono(_state(17.5, 1.0, 900.0), 1.2))
	t.greater(ground, high * 2.0, "skimming the trees is much louder than being up in it")
	t.greater(
		AudioAnalysis.rms(_mono(_state(17.5, 1.0, 900.0), 1.2)), 0.005,
		"but the air itself never goes silent"
	)

	# Canopy is timbre, not level: a forest rustles where open ground hushes.
	var forest: SoundState = _state(14.0, 1.0, 25.0)
	forest.canopy = 1.0
	var downs: SoundState = _state(14.0, 1.0, 25.0)
	downs.canopy = 0.0
	t.ok(
		AudioAnalysis.centroid(AudioAnalysis.spectrum(_mono(forest, 1.2), 2048), RATE)
			!= AudioAnalysis.centroid(AudioAnalysis.spectrum(_mono(downs, 1.2), 2048), RATE),
		"trees and open ground do not sound the same"
	)


static func _test_a_wingbeat_is_an_event_not_a_level(t: TestCase) -> void:
	t.begin("a wingbeat is an event, not a level")
	var previous_peak: float = 0.0
	for stroke: float in [1.0, 2.0, 3.5]:
		var result: Array = _one_beat(stroke)
		var peak: float = float(result[0])
		var when: float = float(result[1])
		var floor_level: float = float(result[2])
		t.greater(peak, previous_peak, "a harder stroke is a louder beat (%.1f m/s)" % stroke)
		t.greater(peak, floor_level * 2.0, "and it stands out of the wind behind it")
		t.less(when, 0.060, "it arrives at once rather than swelling (%.1f m/s)" % stroke)
		previous_peak = peak
	# It has to end, or a flapping bird is a bird playing a drone.
	var tail: Array = _one_beat(3.5)
	t.less(float(tail[3]), float(tail[2]) * 1.6, "half a second later the air is back to itself")
	# Bigger bird, lower beat. This is where the player hears themselves grow.
	# Measured in the thump's own band rather than as overall brightness: the
	# air over the wings is far louder than the thump and would drown the cue in
	# a whole-spectrum centroid, which is what the first version of this test
	# did — and it read backwards.
	var previous_balance: float = 0.0
	for size: float in [0.5, 1.0, 2.0, 6.0]:
		var balance: float = _thump_balance(size)
		t.greater(balance, previous_balance, "a size %.1f beat is lower than the one below" % size)
		previous_balance = balance
	t.greater(
		_thump_balance(6.0), _thump_balance(0.5) * 1.12,
		"and an eagle's beat is audibly deeper than a swift's"
	)


## Where the weight of one beat sits: power below 70 Hz against power from 70 to
## 200 Hz, for a bird of [param size].
##
## A ratio rather than a level because a bigger bird's thump is not louder — the
## filter that lowers it also takes a little off it, and the wind over the wings
## is far louder than either. What changes, and what a listener actually hears,
## is that the weight moves downward. Measured 0.67 at size 0.5 against 0.79 at
## size 6.
static func _thump_balance(size: float) -> float:
	var scape := Soundscape.new()
	var quiet: SoundState = _state(17.5)
	quiet.size = size
	fly(quiet, 0.3, scape)
	var beating: SoundState = _state(17.5)
	beating.size = size
	beating.stroke_speed = 3.5
	scape.update(beating, 1.0 / 90.0)
	var buffer: PackedVector2Array = scape.render(int(RATE * 0.25))
	var power: PackedFloat32Array = AudioAnalysis.spectrum(AudioAnalysis.mono(buffer), 2048)
	return (
		AudioAnalysis.band(power, RATE, 20.0, 70.0)
		/ maxf(AudioAnalysis.band(power, RATE, 70.0, 200.0), 1e-6)
	)


## Fires one downstroke into settled air and reports
## [peak, seconds to peak, the floor before it, the floor after it].
static func _one_beat(stroke: float) -> Array:
	var scape := Soundscape.new()
	var quiet: SoundState = _state(17.5)
	var before: PackedFloat32Array = AudioAnalysis.mono(fly(quiet, 0.4, scape))
	var beating: SoundState = _state(17.5)
	beating.stroke_speed = stroke
	scape.update(beating, 1.0 / 90.0)
	var attack: PackedVector2Array = scape.render(int(RATE * 0.02))
	beating.stroke_speed = 0.0
	var after: PackedVector2Array = fly(beating, 0.8, scape)
	var whole := PackedFloat32Array()
	whole.append_array(AudioAnalysis.mono(attack))
	whole.append_array(AudioAnalysis.mono(after))
	var shape: PackedFloat32Array = AudioAnalysis.envelope(whole, RATE, 120.0)
	var top: Array = AudioAnalysis.envelope_peak(shape)
	var settled: float = AudioAnalysis.rms(
		AudioAnalysis.mono(after), int(RATE * 0.55), int(RATE * 0.75)
	)
	return [float(top[0]), float(top[1]), AudioAnalysis.rms(before), settled]


static func _test_a_one_winged_beat_is_heard_in_that_ear(t: TestCase) -> void:
	t.begin("a one-winged beat is heard in that ear")
	for side: float in [-1.0, 1.0]:
		var scape := Soundscape.new()
		var quiet: SoundState = _state(17.5)
		fly(quiet, 0.3, scape)
		var beating: SoundState = _state(17.5)
		beating.stroke_speed = 3.5
		beating.asymmetry = side
		scape.update(beating, 1.0 / 90.0)
		var buffer: PackedVector2Array = scape.render(int(RATE * 0.12))
		var left: float = AudioAnalysis.rms(AudioAnalysis.left(buffer))
		var right: float = AudioAnalysis.rms(AudioAnalysis.right(buffer))
		if side < 0.0:
			t.greater(left, right * 1.15, "a left-wing beat is louder on the left")
		else:
			t.greater(right, left * 1.15, "a right-wing beat is louder on the right")

	var scape := Soundscape.new()
	fly(_state(17.5), 0.3, scape)
	var even: SoundState = _state(17.5)
	even.stroke_speed = 3.5
	scape.update(even, 1.0 / 90.0)
	var buffer: PackedVector2Array = scape.render(int(RATE * 0.12))
	var l: float = AudioAnalysis.rms(AudioAnalysis.left(buffer))
	var r: float = AudioAnalysis.rms(AudioAnalysis.right(buffer))
	t.near(l / maxf(r, 1e-6), 1.0, 0.25, "an even beat arrives evenly")


static func _test_a_stall_buffets(t: TestCase) -> void:
	t.begin("a stall buffets, and does it before the HUD can say so")
	var previous_level: float = 0.0
	var previous_pulse: float = 0.0
	for stall: float in [0.0, 0.3, 0.7, 1.0]:
		var state: SoundState = _state(16.0)
		state.stall = stall
		var samples: PackedFloat32Array = _mono(state, 2.0)
		var shape: PackedFloat32Array = AudioAnalysis.envelope(samples, RATE, 60.0)
		var level: float = AudioAnalysis.rms(samples)
		var pulse: float = AudioAnalysis.modulation(shape, Soundscape.BUFFET_HZ)
		t.greater(level, previous_level, "a deeper stall is louder (%.1f)" % stall)
		t.greater(pulse, previous_pulse, "and shakes harder (%.1f)" % stall)
		if stall > 0.0:
			t.greater(
				pulse, AudioAnalysis.modulation(shape, 3.0) * 2.0,
				"and it is the buffet rate that is shaking, not a slow swell (%.1f)" % stall
			)
		previous_level = level
		previous_pulse = pulse
	var clean: SoundState = _state(16.0)
	var shape: PackedFloat32Array = AudioAnalysis.envelope(_mono(clean, 2.0), RATE, 60.0)
	t.less(
		AudioAnalysis.modulation(shape, Soundscape.BUFFET_HZ), 0.06,
		"unstalled air does not shake at all"
	)
	t.in_range(Soundscape.BUFFET_HZ, 8.0, 20.0, "a buffet is a buffet, not a tremolo")


static func _test_lift_is_a_swell_not_a_hiss(t: TestCase) -> void:
	t.begin("lift is a swell, not a hiss")
	var previous_low: float = 0.0
	var previous_high: float = 1.0
	for lift: float in [0.0, 2.0, 4.0, 6.0]:
		var state: SoundState = _state(17.5)
		state.lift = lift
		var power: PackedFloat32Array = AudioAnalysis.spectrum(_mono(state, 1.5), 2048)
		var low: float = AudioAnalysis.band(power, RATE, 40.0, 160.0)
		var high: float = AudioAnalysis.band(power, RATE, 2000.0, 8000.0)
		t.greater(low, previous_low, "stronger lift swells lower (%.1f m/s)" % lift)
		t.less(high, previous_high, "and hushes the hiss with it (%.1f m/s)" % lift)
		previous_low = low
		previous_high = high
	var sink: SoundState = _state(17.5)
	sink.lift = -6.0
	var still: SoundState = _state(17.5)
	t.near(
		AudioAnalysis.rms(_mono(sink, 1.0)), AudioAnalysis.rms(_mono(still, 1.0)), 0.008,
		"sinking air is not a sound — only lift is worth telling you about"
	)


static func _test_the_mix_never_clips(t: TestCase) -> void:
	t.begin("the mix never clips")
	# Everything at once, at the top of every range, is the worst case the player
	# can construct: a stalled dive through a thermal at treetop height, flapping.
	var worst: SoundState = _state(78.0, 1.0, 0.0)
	worst.stall = 1.0
	worst.lift = 12.0
	worst.stroke_speed = 8.0
	worst.size = 8.0
	worst.canopy = 1.0
	var buffer: PackedVector2Array = fly(worst, 2.0)
	var samples: PackedFloat32Array = AudioAnalysis.mono(buffer)
	t.ok(AudioAnalysis.clipped(samples) == 0, "the loudest thing possible does not clip")
	t.less(AudioAnalysis.peak(samples), 1.0, "and stays inside full scale")
	t.greater(AudioAnalysis.peak(samples), 0.3, "while still being loud enough to mean it")
	for speed: float in [0.0, 17.5, 40.0, 78.0]:
		t.ok(
			AudioAnalysis.clipped(AudioAnalysis.mono(fly(_state(speed), 1.0))) == 0,
			"ordinary flight at %.0f m/s does not clip either" % speed
		)


static func _test_the_synthesiser_survives_a_poisoned_frame(t: TestCase) -> void:
	t.begin("the synthesiser survives a poisoned frame")
	# A one-pole filter that takes on NaN keeps it forever: one bad frame would
	# silence the game until it was restarted. This is the reason SoundState has
	# a sanitize() at all, so it is the reason this test exists.
	var scape := Soundscape.new()
	var good: SoundState = _state(30.0)
	fly(good, 0.2, scape)
	var poison := SoundState.new()
	poison.airspeed = NAN
	poison.span = INF
	poison.stroke_speed = NAN
	poison.asymmetry = NAN
	poison.stall = INF
	poison.altitude = -INF
	poison.lift = NAN
	poison.size = NAN
	poison.canopy = NAN
	for dt: float in [1.0 / 90.0, 0.0, -1.0, NAN, 1e9]:
		scape.update(poison, dt)
		var frame: PackedVector2Array = scape.render(64)
		for sample: Vector2 in frame:
			t.ok(is_finite(sample.x) and is_finite(sample.y), "nothing infinite came out")
			t.in_range(sample.x, -1.0, 1.0, "and nothing out of range")
	# And it comes back: the game is still audible after the bad frame.
	var after: PackedFloat32Array = AudioAnalysis.mono(fly(good, 0.5, scape))
	t.greater(AudioAnalysis.rms(after), 0.02, "and the air is back afterwards")
	t.ok(AudioAnalysis.clipped(after) == 0, "without ringing itself into clipping")

	# Hostile block sizes, which is what a stuttering frame hands the generator.
	for frames: int in [0, 1, 4096]:
		var block: PackedVector2Array = scape.render(frames)
		t.ok(block.size() == frames, "a %d-frame request gives %d frames" % [frames, frames])


## The budget [Soundscape] documents itself against, measured rather than
## claimed. This is the one number here that is about the machine it runs on:
## on this desktop the whole soundscape is under 2 % of one core, and the bound
## below leaves room for a headset being several times slower.
static func _test_synthesis_is_cheap(t: TestCase) -> void:
	t.begin("synthesis is cheap")
	var seconds: float = 8.0
	var everything: SoundState = _state(40.0, 1.0, 20.0)
	everything.stall = 1.0
	everything.lift = 5.0
	everything.stroke_speed = 3.5
	var scape := Soundscape.new()
	var started: int = Time.get_ticks_usec()
	var frames: int = int(seconds * RATE)
	var written: int = 0
	while written < frames:
		var count: int = mini(180, frames - written)
		scape.update(everything, float(count) / RATE)
		scape.render(count)
		written += count
	var elapsed: float = float(Time.get_ticks_usec() - started) / 1e6
	var load: float = elapsed / seconds
	t.less(load, 0.12, "every layer at once costs a small fraction of one core")
	t.greater(load, 0.0, "and the measurement is a measurement")

	# Baking the whole voice bank is a load-time cost paid once. Measured 255 ms.
	var baking: int = Time.get_ticks_usec()
	for name: String in VoiceBank.clip_names():
		VoiceBank.render(StringName(name))
	t.less(
		float(Time.get_ticks_usec() - baking) / 1e6, 3.0,
		"and the whole voice bank bakes in a moment at load"
	)


# --- the flock ----------------------------------------------------------------


static func _test_every_clip_the_game_can_play_exists(t: TestCase) -> void:
	t.begin("every clip the game can play exists")
	var names: PackedStringArray = VoiceBank.clip_names()
	t.greater(float(names.size()), 20.0, "the bank is a bank")
	# Every sound any other file asks for by name has to be in it, or the game
	# plays silence at exactly the moment it most wants to say something.
	for required: String in [
		"catch", "caught", "rank_up", "rank_down", "won", "lost",
		"impact", "cling", "launch", "rush", "forest", "town", "beat", "beat_big",
	]:
		t.ok(names.has(required), "the bank has '%s'" % required)
	for species in 5:
		for mood in [VoiceBank.Mood.CONTACT, VoiceBank.Mood.ALARM, VoiceBank.Mood.HUNT]:
			t.ok(
				names.has(String(VoiceBank.call_name(species, mood))),
				"species %d has a %d call" % [species, mood]
			)

	# The beds are looped continuously by AudioDirector; everything else is a
	# gesture that happens and stops.
	var loops: PackedStringArray = ["forest", "town", "rush"]
	for name: String in names:
		var samples: PackedFloat32Array = VoiceBank.render(StringName(name))
		var rate: float = VoiceBank.rate_of(StringName(name))
		var seconds: float = float(samples.size()) / rate
		t.greater(seconds, 0.05, "'%s' is long enough to be heard" % name)
		if not loops.has(name):
			t.less(seconds, 2.0, "'%s' is short enough to be an event" % name)
		t.ok(AudioAnalysis.clipped(samples) == 0, "'%s' does not clip" % name)
		t.near(
			AudioAnalysis.peak(samples), VoiceBank.NORMAL_PEAK, 0.02,
			"'%s' is normalised like everything else" % name
		)
		t.greater(AudioAnalysis.rms(samples), 0.02, "'%s' has something in it" % name)
		if name.begins_with("call_"):
			# MAX_CALL_SECONDS is the syllable budget, not a hard ceiling: each
			# syllable wobbles up to 12 % longer and the clip carries a 0.12 s
			# tail, so the longest calls land about a third over it. Measured
			# worst case is the corvid alarm at 1.24 s.
			t.less(
				seconds, VoiceBank.MAX_CALL_SECONDS * 1.35,
				"'%s' does not drone" % name
			)
			# A call that does not end leaves a bird hanging in the mix.
			var tail: float = AudioAnalysis.rms(
				samples, samples.size() - int(rate * 0.02), samples.size()
			)
			t.less(tail, 0.12, "'%s' ends rather than stopping" % name)
		# Three variants, so a flock is not one bird played thirteen times.
		var other: PackedFloat32Array = VoiceBank.render(StringName(name), 2)
		t.ok(other.size() > 0, "'%s' has a second variant" % name)


static func _test_species_do_not_sound_alike(t: TestCase) -> void:
	t.begin("species do not sound alike")
	var centroids: Array[float] = []
	for species in 5:
		var samples: PackedFloat32Array = VoiceBank.render(
			VoiceBank.call_name(species, VoiceBank.Mood.CONTACT)
		)
		centroids.append(
			AudioAnalysis.centroid(AudioAnalysis.spectrum(samples, 1024), VoiceBank.RATE)
		)
	for i in centroids.size():
		for j in range(i + 1, centroids.size()):
			t.greater(
				absf(centroids[i] - centroids[j]), 120.0,
				"species %d and %d are different birds to the ear" % [i, j]
			)
	# The swift is the one that has to be obviously not a raven: it is the bird
	# you are eating for the first ten minutes.
	t.greater(centroids[0], centroids[2] * 2.0, "a swift is far brighter than a corvid")

	# And a frightened bird is recognisably the same bird, frightened.
	for species in 5:
		var calm: PackedFloat32Array = VoiceBank.render(
			VoiceBank.call_name(species, VoiceBank.Mood.CONTACT)
		)
		var alarmed: PackedFloat32Array = VoiceBank.render(
			VoiceBank.call_name(species, VoiceBank.Mood.ALARM)
		)
		var calm_hz: float = AudioAnalysis.centroid(
			AudioAnalysis.spectrum(calm, 1024), VoiceBank.RATE
		)
		var alarm_hz: float = AudioAnalysis.centroid(
			AudioAnalysis.spectrum(alarmed, 1024), VoiceBank.RATE
		)
		t.greater(alarm_hz, calm_hz, "species %d sounds higher when frightened" % species)
		t.less(alarm_hz, calm_hz * 2.4, "but is still the same species (%d)" % species)


## The one claim the flock's audio has to earn.
static func _test_you_can_hear_what_is_about_to_eat_you(t: TestCase) -> void:
	t.begin("you can hear what is about to eat you")
	# Closer is louder, all else equal.
	var previous: float = 1.0
	for distance: float in [5.0, 15.0, 30.0, 50.0, 70.0] as Array[float]:
		var level: float = FlockAudio.menace(distance, 1.0, 1.6, 20.0)
		t.less(level, previous, "a predator at %.0f m is quieter than a nearer one" % distance)
		t.greater(level, 0.0, "but still audible")
		previous = level
	t.ok(
		is_equal_approx(FlockAudio.menace(FlockAudio.MENACE_RANGE + 1.0, 1.0, 4.0, 30.0), 0.0),
		"beyond ninety metres nothing menaces you"
	)

	# Closing is the difference between scenery and a problem.
	t.greater(
		FlockAudio.menace(30.0, 1.0, 1.6, 20.0), FlockAudio.menace(30.0, 1.0, 1.6, 0.0) * 2.0,
		"a bird coming at you is far louder than the same bird drifting"
	)
	# Bigger is worse, and only what can eat you registers at all.
	t.greater(
		FlockAudio.menace(30.0, 1.0, 4.0, 20.0), FlockAudio.menace(30.0, 1.0, 1.3, 20.0),
		"a monster is louder than something barely bigger than you"
	)
	t.ok(
		is_equal_approx(FlockAudio.menace(10.0, 1.0, 1.0, 20.0), 0.0),
		"a peer that cannot eat you is not frightening, however close"
	)
	t.ok(
		is_equal_approx(FlockAudio.menace(10.0, 4.0, 1.0, 20.0), 0.0),
		"and neither is something you are hunting"
	)
	t.ok(
		is_equal_approx(FlockAudio.menace(NAN, 1.0, 4.0, NAN), 0.0),
		"nonsense is not frightening"
	)

	# A hunter on your tail talks faster as it closes. Same information as the
	# HUD's chevron, without having to look at anything.
	t.greater(
		FlockAudio.call_interval(0.0), FlockAudio.call_interval(1.0) * 3.0,
		"a calm bird speaks far less often than one on top of you"
	)
	t.less(FlockAudio.call_interval(1.0), 2.0, "and an urgent one is nearly continuous")


static func _test_the_sky_never_shouts_all_at_once(t: TestCase) -> void:
	t.begin("the sky never shouts all at once")
	var flock := FlockAudio.new()
	var birds: Array[Dictionary] = []
	# Twenty-six birds, all close, all flapping, all fleeing: the worst the
	# game can produce, which is a roost scattering around you.
	for i in 26:
		var angle: float = TAU * float(i) / 26.0
		birds.append({
			"id": i + 1,
			"position": Vector3(cos(angle), 0.2, sin(angle)) * 20.0,
			"velocity": Vector3(0.0, 0.0, -14.0),
			"size": 0.5,
			"state": FlockAudio.STATE_FLEE,
			"species": i % 5,
			"stroke": 0.0,
		})
	var events: int = 0
	var seconds: float = 6.0
	var step: float = 1.0 / 30.0
	var ticks: int = int(seconds / step)
	for tick in ticks:
		# Flap every other tick, so every bird offers a wingbeat continuously.
		for bird: Dictionary in birds:
			bird["stroke"] = 3.5 if tick % 2 == 0 else 0.0
		flock.update(Vector3.ZERO, Vector3.ZERO, 1.0, birds, step)
		t.ok(flock.events.size() <= FlockAudio.MAX_VOICES, "no tick asks for more voices")
		events += flock.events.size()
	# The allowance is a bucket that starts full, so a burst of one second's
	# worth is permitted on top of the steady rate. What must hold is the rate.
	t.less(
		(float(events) - FlockAudio.MAX_EVENTS_PER_SECOND) / seconds,
		FlockAudio.MAX_EVENTS_PER_SECOND + 0.1,
		"and the second's allowance holds across a whole scatter"
	)
	t.greater(float(events), 10.0, "while the sky is still saying something")

	# Priority: with a predator in that crowd, the rush is the predator's.
	var hunter: Dictionary = {
		"id": 999, "position": Vector3(0.0, 6.0, 18.0), "velocity": Vector3(0.0, -2.0, -22.0),
		"size": 2.0, "state": FlockAudio.STATE_HUNT, "species": 4, "stroke": 0.0,
	}
	birds.append(hunter)
	for tick in 60:
		flock.update(Vector3.ZERO, Vector3(0.0, 0.0, -17.0), 1.0, birds, step)
	t.ok(not flock.rush.is_empty(), "the thing hunting you gets the held voice")
	t.ok(int(flock.rush.get("id", 0)) == 999, "and it is that bird, not the crowd")
	t.greater(flock.rush_level(), 0.05, "loud enough to notice")
	t.in_range(float(flock.rush.get("pitch", 0.0)), 0.55, 1.5, "at a pitch that says its size")

	# It fades rather than vanishing when the predator leaves.
	var loud: float = flock.rush_level()
	birds.pop_back()
	for tick in 3:
		flock.update(Vector3.ZERO, Vector3(0.0, 0.0, -17.0), 1.0, birds, step)
	t.less(flock.rush_level(), loud, "a predator breaking off starts to fade")
	t.greater(flock.rush_level(), 0.0, "rather than snapping off the moment it turns")
	for tick in 300:
		flock.update(Vector3.ZERO, Vector3(0.0, 0.0, -17.0), 1.0, birds, step)
	t.ok(flock.rush.is_empty(), "and is eventually gone")

	# Hostile input, the same rule the rest of the game follows.
	flock.update(Vector3(NAN, 0.0, 0.0), Vector3.ZERO, NAN, birds, NAN)
	flock.update(Vector3.ZERO, Vector3.ZERO, 1.0, [{"position": Vector3(INF, 0, 0)}], 0.01)
	t.ok(true, "a nonsense frame does not bring the sky down")


static func _test_the_flock_does_not_leak_its_bookkeeping(t: TestCase) -> void:
	t.begin("the flock does not leak its bookkeeping")
	# Birds are recycled constantly — eaten, respawned, reseeded after a death.
	# A ledger keyed by instance id that never forgets is a session-length leak.
	var flock := FlockAudio.new()
	for round in 40:
		var birds: Array[Dictionary] = []
		for i in 26:
			birds.append({
				"id": round * 100 + i,
				"position": Vector3(float(i), 0.0, -30.0),
				"velocity": Vector3.ZERO, "size": 0.6,
				"state": 0, "species": i % 5, "stroke": 0.0,
			})
		for tick in 20:
			flock.update(Vector3.ZERO, Vector3.ZERO, 1.0, birds, 1.0 / 30.0)
	# 1040 distinct birds have come and gone; the ledger prunes at 128.
	t.less(
		float(flock._next_call.size()), 260.0,
		"a thousand birds later the ledger is still small"
	)
	flock.reset()
	t.ok(flock._next_call.is_empty() and flock.rush.is_empty(), "and a reset clears it")


## The one test here that touches the scene tree, because what it pins is where
## a node ends up.
##
## It came out of a real defect — the town bed was positioned before it was
## added to the tree, so Godot reported an error and discarded the placement on
## every single launch — but be honest about what this test does and does not
## catch. It does not catch that ordering, and cannot: [AudioDirector] is a plain
## [Node], which breaks the transform chain, so its [Node3D] children are in
## world space however they are parented and the discarded placement happened to
## be the placement anyway. Reverting the fix leaves this test green; the fix is
## worth having because an error printed on every launch is how real errors get
## missed, not because the town moved.
##
## What this does pin is the property that made the bed worth placing: the town
## is a fixed landmark you can steer towards by ear, unlike the land bed, which
## follows you. A refactor that makes the town follow the player too — an easy
## mistake, since it sits next to the bed that does — fails here.
static func _test_the_town_is_where_the_town_is(t: TestCase) -> void:
	t.begin("the town is where the town is")
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		t.ok(false, "no scene tree to place an emitter in")
		return
	# Hung under something that is not at the origin, which is what makes this an
	# assertion rather than a coincidence: the director is a plain Node, so with
	# it parented straight to the root its children inherit the world frame and
	# a discarded placement looks exactly like a correct one.
	var rig := Node3D.new()
	rig.name = "AudioRigUnderTest"
	tree.root.add_child(rig)
	rig.global_position = Vector3(120.0, 60.0, -80.0)
	var director := AudioDirector.new()
	director.name = "AudioDirectorUnderTest"
	rig.add_child(director)
	# Nothing to listen to and nothing to listen with: the emitters, the buses
	# and the beds are all this test is about, and _process bails out without a
	# player anyway.
	director.attach(null, null, null)
	var bed: Node3D = director.find_child("TownBed", false, false) as Node3D
	t.ok(bed != null, "there is a town bed")
	if bed != null:
		t.less(
			bed.global_position.distance_to(AudioDirector.TOWN_CENTRE), 0.01,
			"and it is over the town rather than over the player"
		)
	var forest: Node3D = director.find_child("LandBed", false, false) as Node3D
	t.ok(forest != null, "there is a land bed")
	t.ok(
		director.find_child("Voice0", false, false) != null,
		"and the voice pool was built"
	)
	rig.free()
