class_name SoundDesigns
extends RefCounted
## Every procedural sound in the game, rendered once into float buffers
## (AudioBank packs them as AudioStreamWAV). Deterministic: each design seeds
## its own RandomNumberGenerator.
##
## Design rules that apply throughout:
##  * Loops are seamless: either every periodic part has a whole number of
##    cycles per loop and events are written circularly, or the tail is
##    folded over the head (AudioSynth.fold_loop).
##  * Headset speakers (Quest) barely reproduce < 150 Hz, so every low sound
##    (heartbeat, thump, boom, hum) also carries harmonics above 150 Hz.
##  * Buffers are normalised here to a fixed peak; how loud a sound plays is
##    decided at runtime by the mixer (volume_db / buses), not baked in.
##  * Sample rates are as low as the content allows (32 kHz for effects,
##    22.05 kHz for the ambience beds and the updraft hum) to keep load-time
##    synthesis and memory small on Quest.

const FX_RATE := 32000
const BED_RATE := 22050
## The heartbeat clip's layout (s): the lub sounds in [0, HEART_LUB_END),
## the dub from HEART_DUB_AT to the end. The director plays the two parts
## separately, bringing the dub closer at speed (FlightSoundMap.heart_dub).
const HEART_LUB_END := 0.18
const HEART_DUB_AT := 0.26
## Crest factor the wind loops are tamed to (dB of peak over RMS): the wind
## is the loudest continuous layer, so its noise peaks set the mix headroom.
const WIND_CREST_DB := 11.0
## How much the crunch's needle peaks are softened (dB); it plays that much
## lower (AudioDirector.LEVEL), so it is as loud with that much less peak.
const CRUNCH_SOFTEN_DB := 3.0
## Silence before a feather puff (it plays with the crunch, from one event).
const PUFF_DELAY := 0.08


static func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


static func _n(seconds: float, rate: int) -> int:
	return int(round(seconds * rate))


## dst[(offset + i) mod n] += src[i] * gain: events that cross the loop end
## continue at its start, so the loop has no seam.
static func _add_circ(dst: PackedFloat32Array, src: PackedFloat32Array, offset: int, gain: float) -> void:
	var n := dst.size()
	for i in src.size():
		var j := (offset + i) % n
		if j < 0:
			j += n
		dst[j] += src[i] * gain


## A short noise grain: white noise with an exponential decay (tau seconds),
## optionally band-limited.
static func _grain(rng: RandomNumberGenerator, length: float, tau: float, rate: int, filters: Array = []) -> PackedFloat32Array:
	var n := maxi(8, _n(length, rate))
	var g := AudioSynth.white(n, rng)
	if not filters.is_empty():
		g = AudioSynth.filter(g, filters)
	for i in n:
		g[i] *= exp(-float(i) / (tau * rate))
	return g


## Periodic smooth random curve in 0..1 with whole cycles per loop:
## sum of sines at `cycles` per loop with random phases.
static func _gusts(n: int, cycles: Array, rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Evaluated every 32 samples and interpolated: gusts are slow, and a
	# sin() per sample per partial dominated the load-time cost.
	var block := 32
	var nb := n / block + 2
	var coarse := PackedFloat32Array()
	coarse.resize(nb)
	var phases := []
	var amps := []
	for c in cycles:
		phases.append(rng.randf() * TAU)
		amps.append(1.0 / sqrt(float(c)))
	var lo := INF
	var hi := -INF
	for bi in nb:
		var t := float(bi * block) / n
		var v := 0.0
		for k in cycles.size():
			v += amps[k] * sin(TAU * cycles[k] * t + phases[k])
		coarse[bi] = v
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var out := PackedFloat32Array()
	out.resize(n)
	var inv := 1.0 / maxf(1e-6, hi - lo)
	for i in n:
		var bi2 := i / block
		var fr := float(i % block) / block
		out[i] = (lerpf(coarse[bi2], coarse[bi2 + 1], fr) - lo) * inv
	return out


# ---------------------------------------------------------------- wind ---

## The body of the wind (stereo loop, 12 s): pink noise with a gentle low
## shelf, partly decorrelated between the ears, with slow gusts. At runtime
## the Wind bus low-pass opens with airspeed (dull rumble when slow, full
## roar in a dive) and its high-pass rises when tucked. Long, and 12 s
## against the edge's 7 s, so a long dive never hears the noise repeat (the
## two realign only every 84 s); the gust cycles share no common factor, so
## the gust pattern does not repeat within the loop either.
static func wind_body() -> Array[PackedFloat32Array]:
	var rate := FX_RATE
	var n := _n(12.0, rate)
	var rng := _rng(101)
	var common := AudioSynth.pink(n, rng)
	var l := AudioSynth.mix(common, AudioSynth.pink(n, rng), 0.7)
	var r := AudioSynth.mix(common, AudioSynth.pink(n, rng), 0.7)
	var shelf_l := AudioSynth.Biquad.new().lowshelf(220.0, 4.0, rate)
	var shelf_r := AudioSynth.Biquad.new().lowshelf(220.0, 4.0, rate)
	l = AudioSynth.filter(l, [shelf_l, AudioSynth.hp(30.0, 0.707, rate)], true)
	r = AudioSynth.filter(r, [shelf_r, AudioSynth.hp(30.0, 0.707, rate)], true)
	var g := _gusts(n, [2, 3, 5, 7, 10], rng)
	var g2 := _gusts(n, [2, 5, 7], rng)
	# Shallow gusts (about 1 dB): the level must keep meaning "speed".
	for i in n:
		l[i] *= 0.88 + 0.12 * g[i]
		r[i] *= 0.88 + 0.12 * g2[i]
	# Calibrated level (the curves in FlightSoundMap assume it), then the rare
	# noise peaks tamed to WIND_CREST_DB over the RMS: same loudness, about
	# 3.5 dB less peak for the rest of the mix to use.
	var cal := AudioSynth.normalize_pair(l, r, -3.0)
	return AudioSynth.tame_peaks_pair(cal[0], cal[1], WIND_CREST_DB)


## The bright, thin edge of the wind (stereo loop, 7 s): high-passed hiss
## plus three narrow wandering "whistle" bands, the sound of air tearing past
## feathers and ears. Fades in with speed above cruise and much more when
## tucked, which is what makes a tucked dive brighter and thinner.
static func wind_edge() -> Array[PackedFloat32Array]:
	var rate := FX_RATE
	var n := _n(7.0, rate)
	var rng := _rng(202)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var hiss := AudioSynth.filter(AudioSynth.white(n, rng),
			[AudioSynth.hp(2400.0, 0.707, rate), AudioSynth.hp(2400.0, 0.707, rate), AudioSynth.lp(11000.0, 0.707, rate)], true)
		hiss = AudioSynth.normalize(hiss, -6.0)
		var whistles := AudioSynth.buffer(n)
		var centres := [2900.0, 4100.0, 5600.0]
		for k in 3:
			var f0: float = centres[k] * (1.0 + 0.04 * (ch - 0.5))
			var ph := rng.randf() * TAU
			var cyc := 1 + k
			var cs := PackedFloat32Array()
			cs.resize(n / 32 + 1)
			for bi in cs.size():
				cs[bi] = f0 * (1.0 + 0.07 * sin(TAU * cyc * float(bi * 32) / n + ph))
			var band := AudioSynth.swept_bandpass(AudioSynth.white(n, rng), cs, 32, 16.0, rate, true)
			var amp := _gusts(n, [3 + k, 7 + k], rng)
			var g_k := 1.0 / (1.0 + k * 0.4)
			for i in n:
				whistles[i] += band[i] * (0.4 + 0.6 * amp[i]) * g_k
		whistles = AudioSynth.normalize(whistles, -6.0)
		out.append(AudioSynth.mix(hiss, whistles, 0.8))
	var cal := AudioSynth.normalize_pair(out[0], out[1], -3.0)
	return AudioSynth.tame_peaks_pair(cal[0], cal[1], WIND_CREST_DB)


## Stall buffet (mono loop, 2.0 s = 28 flutter pulses = 14 Hz): separated,
## turbulent flow makes the feathers flap against each other. Each pulse is
## a burst of band-passed noise with a small low "thup"; timing and strength
## jitter slightly so it sounds physical, but the period stays exact so it
## reads as a rhythm. Runtime pitch_scale sets the buffet rate by size.
static func stall_flutter() -> PackedFloat32Array:
	var rate := FX_RATE
	var pulses := 28
	var n := _n(2.0, rate)
	var rng := _rng(303)
	var out := AudioSynth.buffer(n)
	var period := float(n) / pulses
	for p in pulses:
		var start := int(p * period + rng.randf_range(-0.003, 0.003) * rate)
		var amp := rng.randf_range(0.75, 1.0)
		var burst := _grain(rng, 0.06, 0.016, rate, [AudioSynth.bp(900.0, 0.8, rate), AudioSynth.hp(320.0, 0.707, rate)])
		# Soft attack (2 ms) so the pulses flutter rather than click.
		for i in mini(burst.size(), _n(0.002, rate)):
			burst[i] *= float(i) / _n(0.002, rate)
		_add_circ(out, AudioSynth.normalize(burst, 0.0), start, amp)
		var thup := PackedFloat32Array()
		thup.resize(_n(0.05, rate))
		for i in thup.size():
			var t := float(i) / rate
			thup[i] = (sin(TAU * 85.0 * t) + 0.5 * sin(TAU * 170.0 * t) + 0.3 * sin(TAU * 255.0 * t)) * exp(-t / 0.012) * minf(1.0, t / 0.002)
		_add_circ(out, thup, start, amp * 0.35)
	# Turbulent roar underneath (kept low so the rhythm dominates).
	var under := AudioSynth.filter(AudioSynth.pink(n, rng), [AudioSynth.bp(700.0, 0.7, rate)], true)
	out = AudioSynth.mix(out, AudioSynth.normalize(under, 0.0), 0.12)
	return AudioSynth.normalize(out, -3.0)


## Updraft hum (stereo loop, 8 s): a soft chord (G2, D3, G3, D4) whose
## partials are doubled 0.25 Hz apart so it slowly beats, over an airy
## swelling noise band. Every frequency has a whole number of cycles in 8 s.
## Runtime: gain and a gentle pitch rise follow the updraft strength.
static func updraft_hum() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var seconds := 8.0
	var n := _n(seconds, rate)
	var rng := _rng(404)
	var freqs := [98.0, 147.0, 196.0, 294.0, 392.0]
	var amps := [0.55, 0.5, 0.45, 0.3, 0.12]
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var b := AudioSynth.buffer(n)
		for k in freqs.size():
			var f: float = freqs[k]
			var ph := rng.randf() * TAU
			AudioSynth.add_sine(b, f, amps[k] * 0.5, ph, rate)
			AudioSynth.add_sine(b, f + 0.25, amps[k] * 0.5, ph * (1.0 + ch), rate)
		var air := AudioSynth.filter(AudioSynth.white(n, rng), [AudioSynth.bp(900.0, 0.9, rate), AudioSynth.lp(2500.0, 0.707, rate)], true)
		air = AudioSynth.normalize(air, 0.0)
		var swell := AudioSynth.buffer(n)
		AudioSynth.add_sine(swell, 2.0 / seconds, 0.35, ch * 0.9, rate)
		var airy := AudioSynth.buffer(n)
		AudioSynth.add_sine(airy, 1.0 / seconds, 0.5, 1.3 + ch, rate)
		for i in n:
			b[i] = b[i] * (0.65 + swell[i]) + air[i] * 0.22 * (0.5 + airy[i])
		out.append(b)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


## Moth wings (mono loop, 1.0 s = 42 beats = 42 Hz): soft felted puffs with a
## faint buzz of the wingbeat harmonics. Normalised quiet on purpose: a moth
## is heard only close up and never over a bird.
static func moth_flutter() -> PackedFloat32Array:
	var rate := FX_RATE
	var beats := 42
	var n := _n(1.0, rate)
	var rng := _rng(505)
	var out := AudioSynth.buffer(n)
	var period := float(n) / beats
	for p in beats:
		var puff := _grain(rng, 0.018, 0.004, rate, [AudioSynth.bp(1500.0, 0.8, rate)])
		_add_circ(out, AudioSynth.normalize(puff, 0.0), int(p * period), rng.randf_range(0.7, 1.0))
	for i in n:
		var t := float(i) / rate
		var buzz := 0.0
		for h in range(2, 8):
			buzz += sin(TAU * 42.0 * h * t) / h
		out[i] += 0.12 * buzz
	return AudioSynth.normalize(out, -12.0)


# ----------------------------------------------------------- wingbeats ---

## Wingbeat whoosh (mono one-shot). size 0 small (wren..swallow: airy
## 2.8 -> 1.6 kHz flutter), 1 medium (starling..crow: 1.5 kHz -> 750 Hz
## whoosh), 2 large (gull..eagle: 800 -> 330 Hz whump with a pressure
## thump). A noise band sweeps down as the wing passes, feather rustle rides
## on top. Always a transient: the envelope falls below 10% of its peak
## well within 300 ms of the onset (AU3).
static func whoosh(size: int, variant: int) -> PackedFloat32Array:
	var rate := FX_RATE
	var rng := _rng(600 + size * 10 + variant)
	var P: Dictionary = [
		{"hi": 2800.0, "lo": 1600.0, "q": 1.1, "att": 0.022, "tau": 0.062, "th": 0.0, "tha": 0.0},
		{"hi": 1500.0, "lo": 750.0, "q": 1.0, "att": 0.03, "tau": 0.07, "th": 115.0, "tha": 0.3},
		{"hi": 800.0, "lo": 330.0, "q": 0.9, "att": 0.04, "tau": 0.075, "th": 78.0, "tha": 0.55},
	][size]
	var spread := 1.0 + rng.randf_range(-0.1, 0.1)
	var att: float = P["att"] * rng.randf_range(0.85, 1.15)
	var tau: float = P["tau"] * rng.randf_range(0.9, 1.1)
	var n := _n(att + tau * 5.5, rate)
	var env := AudioSynth.env_ad(n, att, tau, rate)
	var src := AudioSynth.white(n, rng)
	var bq := AudioSynth.Biquad.new()
	var body := PackedFloat32Array()
	body.resize(n)
	var f_hi: float = P["hi"] * spread
	var f_lo: float = P["lo"] * spread
	for i in n:
		if i % 16 == 0:
			var k := clampf(float(i) / (rate * (att + tau * 2.0)), 0.0, 1.0)
			bq.bandpass(f_hi * pow(f_lo / f_hi, k), P["q"], rate)
		body[i] = bq.process(src[i])
	body = AudioSynth.normalize(body, 0.0)
	var broad := AudioSynth.normalize(AudioSynth.filter(AudioSynth.white(n, rng), [AudioSynth.lp(f_hi * 1.6, 0.707, rate)]), 0.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = (body[i] + 0.3 * broad[i]) * env[i]
	# Feather rustle: tiny high grains, denser at the envelope peak.
	var i2 := 0
	while i2 < n:
		if rng.randf() < env[i2] * 0.55:
			var gr := _grain(rng, 0.004, 0.0012, rate, [AudioSynth.hp(4500.0, 0.707, rate)])
			out = AudioSynth.mix(out, AudioSynth.normalize(gr, 0.0), 0.22 * env[i2], i2)
		i2 += _n(0.003, rate)
	# Pressure thump for bigger wings (with harmonics for small speakers).
	if P["tha"] > 0.0:
		var th: float = P["th"] * spread
		for i in n:
			var t := float(i) / rate
			var e := minf(1.0, t / (att * 0.7)) * exp(-maxf(0.0, t - att * 0.7) / (tau * 0.6))
			out[i] += P["tha"] * e * (sin(TAU * th * t) + 0.45 * sin(TAU * 2.0 * th * t) + 0.25 * sin(TAU * 3.0 * th * t))
	out = AudioSynth.fade(out, 0.0005, 0.02, rate)
	return AudioSynth.normalize(out, -1.0)


# ------------------------------------------------------ catch & caught ---

## Catch crunch (mono one-shot): five crisp grains in 70 ms over a short
## pitched-down bite thump. The grains' needle peaks are softened by
## CRUNCH_SOFTEN_DB (it lands on a loud dive wind; see LEVEL["crunch"]).
static func crunch(variant: int) -> PackedFloat32Array:
	var rate := FX_RATE
	var rng := _rng(700 + variant)
	var n := _n(0.3, rate)
	var out := AudioSynth.buffer(n)
	var times := [0.0, 0.016, 0.034, 0.05, 0.072]
	var amps := [1.0, 0.8, 0.9, 0.6, 0.45]
	for k in times.size():
		var t0: float = times[k] + rng.randf_range(-0.003, 0.003)
		var gr := _grain(rng, 0.014, rng.randf_range(0.0035, 0.008), rate,
			[AudioSynth.bp(rng.randf_range(1900.0, 3200.0), 0.9, rate)])
		var gr2 := _grain(rng, 0.01, 0.003, rate, [AudioSynth.hp(4200.0, 0.707, rate)])
		out = AudioSynth.mix(out, AudioSynth.normalize(gr, 0.0), amps[k], _n(maxf(0.0, t0), rate))
		out = AudioSynth.mix(out, AudioSynth.normalize(gr2, 0.0), amps[k] * 0.5, _n(maxf(0.0, t0), rate))
	var f0 := rng.randf_range(170.0, 200.0)
	var ph := 0.0
	for i in n:
		var t := float(i) / rate
		var f := f0 * pow(70.0 / f0, minf(1.0, t / 0.07))
		ph += TAU * f / rate
		var e := minf(1.0, t / 0.001) * exp(-t / 0.03)
		out[i] += 0.7 * e * (sin(ph) + 0.4 * sin(2.0 * ph) + 0.2 * sin(3.0 * ph))
	out = AudioSynth.fade(out, 0.0003, 0.03, rate)
	return AudioSynth.normalize(AudioSynth.soften_peaks(out, CRUNCH_SOFTEN_DB), -1.0)


## Feather puff (mono one-shot, starting PUFF_DELAY after the crunch it
## plays with): an airy burst, then loose feathers fluttering away (sparse
## high grains thinning out over half a second).
static func feather_puff(variant: int) -> PackedFloat32Array:
	var rate := FX_RATE
	var rng := _rng(750 + variant)
	var n := _n(0.7, rate)
	var air := AudioSynth.filter(AudioSynth.white(n, rng),
		[AudioSynth.bp(rng.randf_range(4200.0, 5600.0), 0.6, rate), AudioSynth.hp(1500.0, 0.707, rate)])
	air = AudioSynth.normalize(air, 0.0)
	var out := AudioSynth.apply(air, AudioSynth.env_ad(n, 0.012, 0.1, rate))
	var t := 0.02
	while t < 0.6:
		var density := exp(-t / 0.18)
		if rng.randf() < density:
			var gr := _grain(rng, 0.006, rng.randf_range(0.0012, 0.003), rate, [AudioSynth.hp(3000.0, 0.707, rate)])
			out = AudioSynth.mix(out, AudioSynth.normalize(gr, 0.0), 0.35 * density * rng.randf_range(0.5, 1.0), _n(t, rate))
		t += 0.006
	out = AudioSynth.fade(out, 0.001, 0.05, rate)
	# The feathers burst just after the bite: PUFF_DELAY of silence first, so
	# the puff's onset never lands on the crunch's grains (both start from
	# one event; together they peaked 0.6 dB higher).
	var lead := AudioSynth.buffer(_n(PUFF_DELAY, rate))
	lead.append_array(out)
	return AudioSynth.normalize(lead, -1.0)


static func _tone(n: int, f: float, att: float, tau: float, ratio: float, i0: float, i1: float, itau: float, rate: int) -> PackedFloat32Array:
	var tone := AudioSynth.fm_tone(n, f, ratio, i0, i1, itau, rate)
	return AudioSynth.apply(tone, AudioSynth.env_ad(n, att, tau, rate))


## Caught stinger (mono, ~2.4 s): a low boom and a descending D-minor motif
## (A4, F4, D4 over D3) in a warm FM brass voice, with a feather burst:
## dramatic, readable, not horror.
static func caught_stinger() -> PackedFloat32Array:
	var rate := FX_RATE
	var n := _n(2.4, rate)
	var rng := _rng(800)
	var out := AudioSynth.buffer(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / rate
		var f := 95.0 * pow(42.0 / 95.0, minf(1.0, t / 0.6))
		ph += TAU * f / rate
		var e := minf(1.0, t / 0.005) * exp(-t / 0.35)
		# tanh drive adds the harmonics a headset speaker can play.
		out[i] = 0.8 * tanh(1.8 * sin(ph)) * e
	var hit := AudioSynth.filter(AudioSynth.white(_n(0.4, rate), rng), [AudioSynth.lp(600.0, 0.707, rate)])
	hit = AudioSynth.apply(AudioSynth.normalize(hit, 0.0), AudioSynth.env_ad(hit.size(), 0.002, 0.07, rate))
	out = AudioSynth.mix(out, hit, 0.45)
	var notes := [[440.0, 0.08, 0.5, 0.25], [349.23, 0.36, 0.5, 0.3], [293.66, 0.64, 1.7, 0.7], [146.83, 0.64, 1.7, 0.8]]
	for k in notes.size():
		var nd: Array = notes[k]
		var tone := _tone(_n(nd[2], rate), nd[0], 0.02, nd[3], 1.0, 1.8, 0.6, 0.4, rate)
		out = AudioSynth.mix(out, tone, 0.3 if k == 3 else 0.55, _n(nd[1], rate))
	out = AudioSynth.mix(out, feather_puff(9), 0.35, _n(0.02, rate))
	out = AudioSynth.fade(out, 0.001, 0.2, rate)
	return AudioSynth.normalize(out, -1.0)


## Tier-up fanfare (mono, ~2.6 s): a rising D-major arpeggio of glassy FM
## bells (D5 F#5 A5 D6), a shimmering final chord and sparkles.
static func tier_fanfare() -> PackedFloat32Array:
	var rate := FX_RATE
	var n := _n(2.6, rate)
	var rng := _rng(900)
	var out := AudioSynth.buffer(n)
	var arp := [587.33, 739.99, 880.0, 1174.66]
	for k in arp.size():
		var bell := _tone(_n(0.9, rate), arp[k], 0.004, 0.35, 2.0, 2.5, 0.3, 0.15, rate)
		out = AudioSynth.mix(out, bell, 0.5, _n(k * 0.1, rate))
	for f in [1174.66, 880.0, 1479.98]:
		var chord := _tone(_n(2.1, rate), f, 0.01, 1.0, 2.0, 1.6, 0.2, 0.3, rate)
		out = AudioSynth.mix(out, chord, 0.3, _n(0.42, rate))
	var pad := _tone(_n(2.1, rate), 587.33, 0.08, 1.2, 1.0, 0.4, 0.1, 0.5, rate)
	out = AudioSynth.mix(out, pad, 0.25, _n(0.42, rate))
	for s in 40:
		var t0 := 0.35 + 1.25 * pow(rng.randf(), 1.6)
		var f2 := rng.randf_range(3000.0, 7000.0)
		var sp := _tone(_n(0.03, rate), f2, 0.002, 0.008, 1.0, 0.0, 0.0, 1.0, rate)
		out = AudioSynth.mix(out, sp, 0.12 * rng.randf_range(0.4, 1.0), _n(t0, rate))
	var swell := AudioSynth.filter(AudioSynth.white(_n(1.4, rate), rng), [AudioSynth.bp(4000.0, 0.8, rate)])
	var senv := PackedFloat32Array()
	senv.resize(swell.size())
	for i in senv.size():
		var t := float(i) / rate
		senv[i] = minf(1.0, t / 0.4) * exp(-maxf(0.0, t - 0.4) / 0.5)
	out = AudioSynth.mix(out, AudioSynth.apply(AudioSynth.normalize(swell, 0.0), senv), 0.12)
	out = AudioSynth.fade(out, 0.001, 0.3, rate)
	return AudioSynth.normalize(out, -1.0)


## Collision thud (mono one-shot): a soft body hitting something solid, a
## low pitched-down thump plus a dull knock and a few loose feathers.
static func bump() -> PackedFloat32Array:
	var rate := FX_RATE
	var rng := _rng(760)
	var n := _n(0.35, rate)
	var out := AudioSynth.buffer(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / rate
		var f := 120.0 * pow(60.0 / 120.0, minf(1.0, t / 0.08))
		ph += TAU * f / rate
		out[i] = minf(1.0, t / 0.002) * exp(-t / 0.06) * (sin(ph) + 0.5 * sin(2.0 * ph) + 0.25 * sin(3.0 * ph))
	var knock := _grain(rng, 0.05, 0.015, rate, [AudioSynth.lp(1200.0, 0.707, rate)])
	out = AudioSynth.mix(out, AudioSynth.normalize(knock, 0.0), 0.5)
	for k in 6:
		var gr := _grain(rng, 0.005, 0.0015, rate, [AudioSynth.hp(3500.0, 0.707, rate)])
		out = AudioSynth.mix(out, AudioSynth.normalize(gr, 0.0), 0.15, _n(0.02 + rng.randf() * 0.2, rate))
	out = AudioSynth.fade(out, 0.0005, 0.05, rate)
	return AudioSynth.normalize(out, -1.0)


## Wing brush (mono one-shot): feathers raking through leaves and twigs, a
## dense rustle for 80 ms that thins out.
static func brush() -> PackedFloat32Array:
	var rate := FX_RATE
	var rng := _rng(770)
	var n := _n(0.3, rate)
	var out := AudioSynth.buffer(n)
	var t := 0.0
	while t < 0.26:
		var density := exp(-t / 0.08)
		if rng.randf() < 0.3 + 0.7 * density:
			var gr := _grain(rng, 0.01, rng.randf_range(0.001, 0.004), rate, [AudioSynth.bp(rng.randf_range(2000.0, 5000.0), 0.8, rate)])
			out = AudioSynth.mix(out, AudioSynth.normalize(gr, 0.0), rng.randf_range(0.3, 1.0) * density, _n(t, rate))
		t += 0.003
	out = AudioSynth.fade(out, 0.001, 0.04, rate)
	return AudioSynth.normalize(out, -1.0)


# --------------------------------------------------------------- danger ---

## One heartbeat (mono one-shot, 0.52 s): "lub" at 0, faded out by
## HEART_LUB_END, and "dub" at HEART_DUB_AT; each a low sine with 2nd-4th
## harmonics and a soft knock. The director schedules it beat by beat (60
## bpm at a faint threat, 111 at contact), lub and dub separately, so the
## tempo and the lub-dub spacing change and the pitch does not.
## Low crest factor: the 2nd and 4th partials are a quarter cycle out of
## phase and the fundamental (which headset speakers barely play) is 0.7,
## not 1. At the same A-weighted and speaker-band loudness that peaks 3 dB
## lower, which the mix needs: a loud low lub lining up with a catch crunch
## and both wingbeats otherwise reached the limiter.
static func danger_heartbeat() -> PackedFloat32Array:
	var rate := FX_RATE
	var n := _n(0.52, rate)
	var rng := _rng(1000)
	var out := AudioSynth.buffer(n)
	for beat in [[0.0, 58.0, 1.0], [HEART_DUB_AT, 70.0, 0.75]]:
		var b := PackedFloat32Array()
		b.resize(_n(0.25, rate))
		for i in b.size():
			var t := float(i) / rate
			var e := minf(1.0, t / 0.004) * exp(-t / 0.06)
			var f: float = beat[1]
			b[i] = e * (0.7 * sin(TAU * f * t) + 0.5 * cos(TAU * 2.0 * f * t) + 0.28 * sin(TAU * 3.0 * f * t) + 0.14 * cos(TAU * 4.0 * f * t))
		var knock := _grain(rng, 0.03, 0.007, rate, [AudioSynth.lp(900.0, 0.707, rate)])
		b = AudioSynth.mix(b, AudioSynth.normalize(knock, 0.0), 0.25)
		if beat[0] == 0.0:
			# The lub's tail (-22 dB by 0.13 s) fades to silence by
			# HEART_LUB_END, so the dub can be brought forward without a cut.
			b = AudioSynth.fade(b.slice(0, _n(HEART_LUB_END, rate)), 0.0, 0.05, rate)
		_add_circ(out, b, _n(beat[0], rate), beat[2])
	# The dub's tail (-36 dB by now) fades to exact silence at the end.
	out = AudioSynth.fade(out, 0.0, 0.03, rate)
	return AudioSynth.normalize(out, -1.0)


## Tension drone (mono loop, 4 s): a minor second (E3 against F3, band-limited
## saws) with a 6 Hz tremolo and a thin high E5. Whole cycles per loop.
static func danger_drone() -> PackedFloat32Array:
	var rate := FX_RATE
	var seconds := 4.0
	var n := _n(seconds, rate)
	var out := AudioSynth.buffer(n)
	for f in [164.75, 174.5]:
		for h in range(1, 7):
			AudioSynth.add_sine(out, f * h, 1.0 / h, 0.0, rate)
	var trem := AudioSynth.buffer(n)
	AudioSynth.add_sine(trem, 6.0, 0.25, 0.0, rate)
	var high := AudioSynth.buffer(n)
	AudioSynth.add_sine(high, 659.25, 0.1, 0.0, rate)
	var swell := AudioSynth.buffer(n)
	AudioSynth.add_sine(swell, 1.0 / seconds, 0.5, 0.0, rate)
	for i in n:
		out[i] = out[i] * (0.75 + trem[i]) * 0.3 + high[i] * (0.5 + swell[i])
	return AudioSynth.normalize(out, -1.0)


# ------------------------------------------------------------ ambience ---

## Breeze in the trees (stereo loop, 10 s): a leafy noise bed that swells
## with gusts, plus thousands of tiny rustle grains whose density follows
## the gusts, placed independently in each ear.
static func amb_leaves() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var n := _n(10.0, rate)
	var rng := _rng(1100)
	var g := _gusts(n, [1, 2, 3, 5, 7], rng)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var base := AudioSynth.filter(AudioSynth.pink(n, rng),
			[AudioSynth.bp(2600.0, 0.5, rate), AudioSynth.hp(500.0, 0.707, rate)], true)
		base = AudioSynth.normalize(base, 0.0)
		var b := PackedFloat32Array()
		b.resize(n)
		for i in n:
			var gi := g[(i + ch * 1500) % n]
			b[i] = base[i] * (0.18 + 0.5 * gi * gi)
		var t := 0.0
		var step := 0.0025
		var grain_src := AudioSynth.filter(AudioSynth.white(_n(0.02, rate), rng), [AudioSynth.hp(1800.0, 0.707, rate)])
		while t < 10.0:
			var gi2 := g[int(t * rate) % n]
			if rng.randf() < 0.15 + 0.85 * gi2 * gi2:
				var len_s := rng.randf_range(0.002, 0.012)
				var gr := grain_src.slice(0, _n(len_s, rate))
				for i in gr.size():
					gr[i] *= exp(-float(i) / (len_s * 0.4 * rate))
				_add_circ(b, gr, _n(t, rate), rng.randf_range(0.05, 0.3) * (0.4 + gi2))
			t += step
		out.append(b)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


## Water (stereo loop, 10 s): wavelets lapping (low noise swells with a
## sharper rise than fall) and the babble of small resonant bubbles (short
## rising sine chirps, Farnell's bubble model) bunched on the wave crests.
static func amb_water() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var seconds := 10.0
	var n := _n(seconds, rate)
	var rng := _rng(1200)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var lap := AudioSynth.normalize(AudioSynth.filter(AudioSynth.brown(n, rng),
			[AudioSynth.lp(750.0, 0.707, rate), AudioSynth.hp(90.0, 0.707, rate)], true), 0.0)
		var b := PackedFloat32Array()
		b.resize(n)
		var waves := PackedFloat32Array()
		waves.resize(n)
		var ph := rng.randf()
		for i in n:
			var t := float(i) / n
			# Saw-ish swell: fast rise, slow fall; 4 and 7 cycles per loop.
			var w1 := fposmod(4.0 * t + ph, 1.0)
			var w2 := fposmod(7.0 * t + ph * 1.7, 1.0)
			var s := pow(1.0 - w1, 3.0) * minf(1.0, w1 * 12.0) + 0.6 * pow(1.0 - w2, 3.0) * minf(1.0, w2 * 12.0)
			waves[i] = s
			b[i] = lap[i] * (0.15 + 0.5 * s)
		var t2 := 0.0
		while t2 < seconds:
			var crest := waves[int(t2 * rate) % n]
			if rng.randf() < 0.08 + 0.5 * crest:
				var d := rng.randf_range(0.008, 0.025)
				var f0 := rng.randf_range(380.0, 1500.0)
				var bub := PackedFloat32Array()
				bub.resize(_n(d * 2.5, rate))
				var pphase := 0.0
				for i in bub.size():
					var tt := float(i) / rate
					var f := f0 * (1.0 + 1.8 * tt / d)
					pphase += TAU * f / rate
					bub[i] = sin(pphase) * exp(-tt / (d * 0.5)) * minf(1.0, tt / 0.001)
				_add_circ(b, bub, _n(t2, rate), rng.randf_range(0.04, 0.16))
			t2 += 0.012
		out.append(b)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


## Village (stereo loop, 12 s): the low murmur of a lived-in place and the
## wind whistling round walls and chimneys. Bells come separately (3D).
static func amb_village() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var n := _n(12.0, rate)
	var rng := _rng(1300)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var murmur := AudioSynth.normalize(AudioSynth.filter(AudioSynth.brown(n, rng),
			[AudioSynth.lp(380.0, 0.707, rate), AudioSynth.hp(60.0, 0.707, rate)], true), 0.0)
		var mid := AudioSynth.normalize(AudioSynth.filter(AudioSynth.pink(n, rng), [AudioSynth.bp(520.0, 0.8, rate)], true), 0.0)
		var ph := rng.randf() * TAU
		var cs := PackedFloat32Array()
		cs.resize(n / 32 + 1)
		for bi in cs.size():
			cs[bi] = (540.0 + 60.0 * ch) * (1.0 + 0.12 * sin(TAU * 2.0 * float(bi * 32) / n + ph))
		var whistle := AudioSynth.swept_bandpass(AudioSynth.white(n, rng), cs, 32, 9.0, rate, true)
		whistle = AudioSynth.normalize(whistle, 0.0)
		var g := _gusts(n, [1, 2, 3], rng)
		var b := PackedFloat32Array()
		b.resize(n)
		for i in n:
			b[i] = murmur[i] * 0.55 + mid[i] * 0.12 + whistle[i] * 0.22 * g[i] * g[i]
		out.append(b)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


## Open air (stereo loop, 10 s): a soft, low breeze over open ground, rock
## and hills, with slow gusts and a faint high rustle of grass stems. The
## floor bed: it must never draw attention.
static func amb_open() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var n := _n(10.0, rate)
	var rng := _rng(1700)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var low := AudioSynth.normalize(AudioSynth.filter(AudioSynth.pink(n, rng),
			[AudioSynth.lp(700.0, 0.707, rate), AudioSynth.hp(70.0, 0.707, rate)], true), 0.0)
		var hiss := AudioSynth.normalize(AudioSynth.filter(AudioSynth.white(n, rng),
			[AudioSynth.bp(3500.0, 0.6, rate)], true), 0.0)
		var g := _gusts(n, [1, 2, 3], rng)
		var b := PackedFloat32Array()
		b.resize(n)
		for i in n:
			var gi := g[i]
			b[i] = low[i] * (0.35 + 0.5 * gi) + hiss[i] * 0.05 * gi * gi
		out.append(b)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


## A distant church bell stroke (mono one-shot, 4.5 s): additive minor-third
## bell partials (hum, prime, tierce, quint, nominal, ...) each with its own
## decay, softened by distance.
static func church_bell() -> PackedFloat32Array:
	var rate := FX_RATE
	var n := _n(4.5, rate)
	var rng := _rng(1400)
	var f := 392.0
	var ratios := [0.5, 1.0, 1.2, 1.5, 2.0, 2.52, 3.0, 4.07]
	var amps := [0.55, 0.8, 0.5, 0.3, 0.65, 0.25, 0.18, 0.1]
	var taus := [2.4, 1.6, 1.3, 1.0, 1.0, 0.6, 0.45, 0.3]
	var out := AudioSynth.buffer(n)
	for k in ratios.size():
		AudioSynth.add_sine(out, f * ratios[k], amps[k], rng.randf() * TAU, rate, 0, -1, taus[k])
	for i in mini(n, _n(0.003, rate)):
		out[i] *= float(i) / _n(0.003, rate)
	var strike := _grain(rng, 0.03, 0.005, rate, [AudioSynth.bp(2200.0, 1.0, rate)])
	out = AudioSynth.mix(out, AudioSynth.normalize(strike, 0.0), 0.3)
	out = AudioSynth.filter(out, [AudioSynth.lp(3200.0, 0.707, rate)])
	out = AudioSynth.fade(out, 0.0005, 0.5, rate)
	return AudioSynth.normalize(out, -1.0)


## Meadow (stereo loop, 10 s): grass breeze (softer and duller than leaves)
## with three crickets chirping at their own pitch and pace (4 pulses at
## 30 Hz per chirp), each placed off-centre.
static func amb_meadow() -> Array[PackedFloat32Array]:
	var rate := BED_RATE
	var seconds := 10.0
	var n := _n(seconds, rate)
	var rng := _rng(1500)
	var g := _gusts(n, [1, 2, 3, 4], rng)
	var out: Array[PackedFloat32Array] = []
	for ch in 2:
		var grass := AudioSynth.normalize(AudioSynth.filter(AudioSynth.pink(n, rng),
			[AudioSynth.bp(1300.0, 0.5, rate), AudioSynth.lp(4000.0, 0.707, rate)], true), 0.0)
		var b := PackedFloat32Array()
		b.resize(n)
		for i in n:
			var gi := g[(i + ch * 2000) % n]
			b[i] = grass[i] * (0.15 + 0.45 * gi)
		out.append(b)
	var insects := [[4300.0, 0.62, 0.8], [4900.0, 0.83, -0.6], [5500.0, 0.71, 0.2]]
	for spec in insects:
		var fc: float = spec[0]
		var period: float = spec[1]
		var pan: float = spec[2]
		var chirps := int(floor(seconds / period))
		# Whole chirps per loop: stretch the period slightly to fit.
		var p := seconds / chirps
		for c in chirps:
			var t0 := c * p + rng.randf_range(0.0, 0.02)
			for k in 4:
				var pulse := PackedFloat32Array()
				pulse.resize(_n(0.018, rate))
				for i in pulse.size():
					var tt := float(i) / pulse.size()
					pulse[i] = sin(TAU * fc * float(i) / rate) * sin(PI * tt)
				var amp := 0.06 * rng.randf_range(0.7, 1.0)
				_add_circ(out[0], pulse, _n(t0 + k / 30.0, rate), amp * (1.0 - pan) * 0.5 + amp * 0.25)
				_add_circ(out[1], pulse, _n(t0 + k / 30.0, rate), amp * (1.0 + pan) * 0.5 + amp * 0.25)
	return AudioSynth.normalize_pair(out[0], out[1], -3.0)


# -------------------------------------------------------------- starling --

## Starling calls (mono, synthesized: no usable CC0/PD starling voice was
## found; the only starling recording is a flock's wing roar). Starlings
## are famous whistlers: 0 = the "wolf whistle" (up and back down), 1 = a
## falling "wheeoo" after three soft clicks, 2 = two falling "tseee-oo"
## whistles with a fast warble. Pitched around 3.5 kHz on purpose, in the
## gap between the hawk's screech (~2.9 kHz) and the sparrow's chirps
## (~4.1 kHz), with notes longer than a chirp and far shorter than a scream,
## so no recorded species sounds like them (AU2).
static func starling(variant: int) -> PackedFloat32Array:
	# Each whistle has its own ~40 ms release (_whistle's envelope); the
	# buffer runs 0.1 s past the last one so the clip ends in silence, not
	# on a release cut by the end fade (round 5: two of them ended 8 and
	# 17 dB under their loudest 50 ms).
	var rate := FX_RATE
	var rng := _rng(1600 + variant)
	var out := PackedFloat32Array()
	match variant:
		0:
			out = AudioSynth.buffer(_n(0.62, rate))
			var w := _whistle(rng, [[0.0, 2400.0], [0.16, 4600.0], [0.48, 2800.0]], 0.48, 36.0, 0.02, rate)
			out = AudioSynth.mix(out, w, 1.0, _n(0.06, rate))
		1:
			out = AudioSynth.buffer(_n(0.72, rate))
			for k in 3:
				var click := _grain(rng, 0.01, 0.003, rate, [AudioSynth.bp(rng.randf_range(2500.0, 3500.0), 1.5, rate)])
				out = AudioSynth.mix(out, AudioSynth.normalize(click, 0.0), 0.35, _n(0.02 + k * 0.045, rate))
			var w2 := _whistle(rng, [[0.0, 4400.0], [0.38, 2400.0]], 0.38, 40.0, 0.025, rate)
			out = AudioSynth.mix(out, w2, 1.0, _n(0.2, rate))
		_:
			out = AudioSynth.buffer(_n(0.88, rate))
			for k in 2:
				var w3 := _whistle(rng, [[0.0, 4600.0], [0.3, 2600.0]], 0.3, 60.0, 0.04, rate)
				out = AudioSynth.mix(out, w3, 1.0 - 0.15 * k, _n(0.03 + k * 0.4, rate))
	out = AudioSynth.fade(out, 0.002, 0.03, rate)
	return AudioSynth.normalize(out, -3.0)


## A bird whistle: a pure tone (with a faint 2nd harmonic) following the
## breakpoints [[t, Hz], ...] (log-interpolated), with vibrato and breath.
static func _whistle(rng: RandomNumberGenerator, points: Array, dur: float, vib_hz: float, vib_depth: float, rate: int) -> PackedFloat32Array:
	var n := _n(dur, rate)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	var breath := AudioSynth.filter(AudioSynth.white(n, rng), [AudioSynth.hp(3000.0, 0.707, rate)])
	for i in n:
		var t := float(i) / rate
		var f: float = points[0][1]
		for k in range(1, points.size()):
			if t <= points[k][0]:
				var a: Array = points[k - 1]
				var b: Array = points[k]
				var u: float = (t - float(a[0])) / maxf(1e-4, float(b[0]) - float(a[0]))
				f = float(a[1]) * pow(float(b[1]) / float(a[1]), clampf(u, 0.0, 1.0))
				break
			f = points[k][1]
		f *= 1.0 + vib_depth * sin(TAU * vib_hz * t)
		ph += TAU * f / rate
		var u := clampf(t / dur, 0.0, 1.0)
		var e := sin(PI * u)
		# A crisp onset (the 0.6 power) and a release that eases out to
		# silence (1.6: its slope goes to 0). With the 0.6 power at the end
		# too, the envelope met zero at an infinite slope and each whistle
		# ended on a faint broadband click (visible in its spectrogram).
		out[i] = (sin(ph) + 0.12 * sin(2.0 * ph) + 0.04 * breath[i]) * pow(e, 0.6 if u < 0.5 else 1.6)
	return out
