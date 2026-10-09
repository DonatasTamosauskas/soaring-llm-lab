class_name AudioSynth
extends RefCounted
## DSP building blocks for the procedural sounds: noise, biquad filters,
## envelopes, oscillators, loop seams and 16-bit AudioStreamWAV packing.
##
## Everything here runs ONCE, when the AudioBank is built at load time. At
## runtime the game only changes volume, pitch and bus-filter parameters of
## the finished buffers (per-sample GDScript synthesis every frame would be
## far too slow on a Quest).

const RATE := 44100


## RBJ-cookbook biquad (transposed direct form II). Coefficients can be
## changed between samples for swept filters.
class Biquad:
	extends RefCounted
	var b0 := 1.0
	var b1 := 0.0
	var b2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var z1 := 0.0
	var z2 := 0.0

	func _coef(nb0: float, nb1: float, nb2: float, a0: float, na1: float, na2: float) -> Biquad:
		b0 = nb0 / a0
		b1 = nb1 / a0
		b2 = nb2 / a0
		a1 = na1 / a0
		a2 = na2 / a0
		return self

	func lowpass(f: float, q: float, rate: float = RATE) -> Biquad:
		var w := TAU * clampf(f, 5.0, rate * 0.49) / rate
		var al := sin(w) / (2.0 * q)
		var c := cos(w)
		return _coef((1.0 - c) * 0.5, 1.0 - c, (1.0 - c) * 0.5, 1.0 + al, -2.0 * c, 1.0 - al)

	func highpass(f: float, q: float, rate: float = RATE) -> Biquad:
		var w := TAU * clampf(f, 5.0, rate * 0.49) / rate
		var al := sin(w) / (2.0 * q)
		var c := cos(w)
		return _coef((1.0 + c) * 0.5, -(1.0 + c), (1.0 + c) * 0.5, 1.0 + al, -2.0 * c, 1.0 - al)

	## Band-pass with 0 dB peak gain.
	func bandpass(f: float, q: float, rate: float = RATE) -> Biquad:
		var w := TAU * clampf(f, 5.0, rate * 0.49) / rate
		var al := sin(w) / (2.0 * q)
		var c := cos(w)
		return _coef(al, 0.0, -al, 1.0 + al, -2.0 * c, 1.0 - al)

	func peaking(f: float, q: float, gain_db: float, rate: float = RATE) -> Biquad:
		var A := pow(10.0, gain_db / 40.0)
		var w := TAU * clampf(f, 5.0, rate * 0.49) / rate
		var al := sin(w) / (2.0 * q)
		var c := cos(w)
		return _coef(1.0 + al * A, -2.0 * c, 1.0 - al * A, 1.0 + al / A, -2.0 * c, 1.0 - al / A)

	func lowshelf(f: float, gain_db: float, rate: float = RATE) -> Biquad:
		var A := pow(10.0, gain_db / 40.0)
		var w := TAU * clampf(f, 5.0, rate * 0.49) / rate
		var c := cos(w)
		var al := sin(w) / 2.0 * sqrt(2.0)
		var sa := 2.0 * sqrt(A) * al
		return _coef(A * ((A + 1.0) - (A - 1.0) * c + sa), 2.0 * A * ((A - 1.0) - (A + 1.0) * c),
			A * ((A + 1.0) - (A - 1.0) * c - sa), (A + 1.0) + (A - 1.0) * c + sa,
			-2.0 * ((A - 1.0) + (A + 1.0) * c), (A + 1.0) + (A - 1.0) * c - sa)

	func process(x: float) -> float:
		var y := b0 * x + z1
		z1 = b1 * x - a1 * y + z2
		z2 = b2 * x - a2 * y
		return y

	func reset() -> void:
		z1 = 0.0
		z2 = 0.0


static func lp(f: float, q: float = 0.707, rate: float = RATE) -> Biquad:
	return Biquad.new().lowpass(f, q, rate)


static func hp(f: float, q: float = 0.707, rate: float = RATE) -> Biquad:
	return Biquad.new().highpass(f, q, rate)


static func bp(f: float, q: float = 1.0, rate: float = RATE) -> Biquad:
	return Biquad.new().bandpass(f, q, rate)


static func buffer(n: int) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	b.fill(0.0)
	return b


static func samples(seconds: float, rate: float = RATE) -> int:
	return int(round(seconds * rate))


static func white(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	for i in n:
		b[i] = rng.randf() * 2.0 - 1.0
	return b


## Pink noise (-3 dB/octave), Paul Kellet's economy filter. Unit-ish RMS.
static func pink(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	for i in n:
		var w := rng.randf() * 2.0 - 1.0
		b0 = 0.99765 * b0 + w * 0.0990460
		b1 = 0.96300 * b1 + w * 0.2965164
		b2 = 0.57000 * b2 + w * 1.0526913
		b[i] = (b0 + b1 + b2 + w * 0.1848) * 0.25
	return b


## Brown(ish) noise: leaky integrated white noise (-6 dB/octave above ~8 Hz).
static func brown(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	var y := 0.0
	for i in n:
		y = y * 0.9988 + (rng.randf() * 2.0 - 1.0) * 0.05
		b[i] = y
	return b


## Runs filters in series over buf. circular = true runs the chain twice and
## keeps the second pass, so the filter state at the start of the output
## matches its end: a loop of filtered noise has no seam. The biquad maths
## is inlined (a method call per sample would triple the load-time cost).
static func filter(buf: PackedFloat32Array, filters: Array, circular: bool = false) -> PackedFloat32Array:
	var out := buf.duplicate()
	var n := out.size()
	for f: Biquad in filters:
		var b0 := f.b0
		var b1 := f.b1
		var b2 := f.b2
		var a1 := f.a1
		var a2 := f.a2
		var z1 := 0.0
		var z2 := 0.0
		if circular:
			for i in n:
				var x0 := out[i]
				var y0 := b0 * x0 + z1
				z1 = b1 * x0 - a1 * y0 + z2
				z2 = b2 * x0 - a2 * y0
		for i in n:
			var x := out[i]
			var y := b0 * x + z1
			z1 = b1 * x - a1 * y + z2
			z2 = b2 * x - a2 * y
			out[i] = y
	return out


## buf[from ..] += amp * sin(TAU f t + phase), in place, by the rotation
## recurrence y[n] = 2 cos(w) y[n-1] - y[n-2]: one multiply-add per sample
## instead of a sin() call (64-bit floats keep it exact over seconds).
static func add_sine(buf: PackedFloat32Array, f: float, amp: float, phase: float = 0.0,
		rate: float = RATE, from: int = 0, count: int = -1, decay_tau: float = 0.0) -> void:
	var end := buf.size() if count < 0 else mini(buf.size(), from + count)
	var w := TAU * f / rate
	var c2 := 2.0 * cos(w)
	var y1 := sin(phase - w)
	var y2 := sin(phase - 2.0 * w)
	var a := amp
	var k := exp(-1.0 / (decay_tau * rate)) if decay_tau > 0.0 else 1.0
	for i in range(from, end):
		var y := c2 * y1 - y2
		buf[i] += a * y
		y2 = y1
		y1 = y
		a *= k


## Band-pass whose centre changes every `block` samples (centres[i / block],
## Hz), with the biquad maths inlined. circular = two passes so the state is
## continuous across a loop seam.
static func swept_bandpass(src: PackedFloat32Array, centres: PackedFloat32Array, block: int, q: float,
		rate: float = RATE, circular: bool = false) -> PackedFloat32Array:
	var n := src.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var z1 := 0.0
	var z2 := 0.0
	var b0 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	for pass_i in (2 if circular else 1):
		for i in n:
			if i % block == 0:
				var w := TAU * clampf(centres[mini(i / block, centres.size() - 1)], 5.0, rate * 0.49) / rate
				var al := sin(w) / (2.0 * q)
				var a0 := 1.0 + al
				b0 = al / a0
				a1 = -2.0 * cos(w) / a0
				a2 = (1.0 - al) / a0
			var x := src[i]
			var y := b0 * x + z1
			z1 = -a1 * y + z2
			z2 = -b0 * x - a2 * y
			out[i] = y
	return out


## a + b * gain, in place on a copy (lengths may differ; the shorter wins).
static func mix(a: PackedFloat32Array, b: PackedFloat32Array, gain: float = 1.0, offset: int = 0) -> PackedFloat32Array:
	var out := a.duplicate()
	for i in b.size():
		var j := i + offset
		if j >= 0 and j < out.size():
			out[j] += b[i] * gain
	return out


static func scale(buf: PackedFloat32Array, gain: float) -> PackedFloat32Array:
	var out := buf.duplicate()
	for i in out.size():
		out[i] *= gain
	return out


## Multiplies buf by env (same length or shorter; the rest is silenced).
static func apply(buf: PackedFloat32Array, env: PackedFloat32Array) -> PackedFloat32Array:
	var out := buf.duplicate()
	for i in out.size():
		out[i] *= env[i] if i < env.size() else 0.0
	return out


## Attack (raised cosine) then exponential decay with time constant tau.
static func env_ad(n: int, attack: float, tau: float, rate: float = RATE) -> PackedFloat32Array:
	var e := PackedFloat32Array()
	e.resize(n)
	var na := maxi(1, int(attack * rate))
	for i in n:
		if i < na:
			e[i] = 0.5 - 0.5 * cos(PI * i / na)
		else:
			e[i] = exp(-(i - na) / (tau * rate))
	return e


## Short fades at both ends so one-shots never click.
static func fade(buf: PackedFloat32Array, fade_in: float, fade_out: float, rate: float = RATE) -> PackedFloat32Array:
	var out := buf.duplicate()
	var n := out.size()
	var a := mini(n, int(fade_in * rate))
	var b := mini(n, int(fade_out * rate))
	for i in a:
		out[i] *= 0.5 - 0.5 * cos(PI * i / maxf(1.0, a))
	for i in b:
		out[n - 1 - i] *= 0.5 - 0.5 * cos(PI * i / maxf(1.0, b))
	return out


## Loops: generate n + xfade samples, then this folds the tail over the head
## with an equal-power crossfade and returns n samples that loop seamlessly.
static func fold_loop(buf: PackedFloat32Array, n: int) -> PackedFloat32Array:
	var x := buf.size() - n
	var out := buf.slice(0, n)
	for i in x:
		var t := float(i) / x
		out[i] = buf[n + i] * cos(t * PI * 0.5) + out[i] * sin(t * PI * 0.5)
	return out


## Two-operator FM tone: carrier f, modulator f * ratio, index decaying from
## i0 to i1 with time constant itau. Bells use inharmonic ratios, brass ~1.
static func fm_tone(n: int, f: float, ratio: float, i0: float, i1: float, itau: float, rate: float = RATE) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n)
	var pc := 0.0
	var pm := 0.0
	var dc := TAU * f / rate
	var dm := TAU * f * ratio / rate
	for i in n:
		var t := i / rate
		var idx := i1 + (i0 - i1) * exp(-t / itau)
		b[i] = sin(pc + idx * sin(pm))
		pc += dc
		pm += dm
	return b


static func peak(buf: PackedFloat32Array) -> float:
	var p := 0.0
	for v in buf:
		p = maxf(p, absf(v))
	return p


## Scales so the peak sits at peak_db dBFS.
static func normalize(buf: PackedFloat32Array, peak_db: float = -1.0) -> PackedFloat32Array:
	var p := peak(buf)
	if p <= 0.0:
		return buf.duplicate()
	return scale(buf, pow(10.0, peak_db / 20.0) / p)


## Scales a stereo pair together so the louder channel peaks at peak_db.
static func normalize_pair(l: PackedFloat32Array, r: PackedFloat32Array, peak_db: float) -> Array[PackedFloat32Array]:
	var p := maxf(peak(l), peak(r))
	var g := pow(10.0, peak_db / 20.0) / maxf(p, 1e-9)
	return [scale(l, g), scale(r, g)]


## Tames the rare peaks of a noise pair: every sample above a soft knee is
## bent (tanh) towards a ceiling crest_db over the pair's RMS, then the pair
## is scaled back to that same RMS. Memoryless, so loops stay seamless. Peak-
## normalised Gaussian noise keeps peaks 14-15 dB over its RMS that nobody
## hears but that eat mix headroom; above ~3.5 sigma they are 0.05% of the
## samples, and bending them is inaudible in broadband noise.
static func tame_peaks_pair(l: PackedFloat32Array, r: PackedFloat32Array, crest_db: float) -> Array[PackedFloat32Array]:
	var rms := sqrt((_power(l) + _power(r)) * 0.5)
	var ceiling := rms * pow(10.0, crest_db / 20.0)
	var knee := 0.7 * ceiling
	var span := ceiling - knee
	var out: Array[PackedFloat32Array] = []
	for ch in [l, r]:
		var o := (ch as PackedFloat32Array).duplicate()
		for i in o.size():
			var a := absf(o[i])
			if a > knee:
				o[i] = signf(o[i]) * (knee + span * tanh((a - knee) / span))
		out.append(o)
	var g := rms / maxf(1e-9, sqrt((_power(out[0]) + _power(out[1])) * 0.5))
	return [scale(out[0], g), scale(out[1], g)]


## Softens a transient's topmost peaks by about reduce_db: samples above a
## knee at half the new ceiling bend (tanh) towards it. Memoryless. Needle
## peaks of 1-2 ms grains cost headroom but not loudness (the ear sums
## loudness over ~10 ms), so a sound can then play louder per dB of peak.
static func soften_peaks(buf: PackedFloat32Array, reduce_db: float) -> PackedFloat32Array:
	var ceiling := peak(buf) * pow(10.0, -reduce_db / 20.0)
	var knee := 0.7 * ceiling
	var span := ceiling - knee
	var o := buf.duplicate()
	for i in o.size():
		var a := absf(o[i])
		if a > knee:
			o[i] = signf(o[i]) * (knee + span * tanh((a - knee) / span))
	return o


static func _power(buf: PackedFloat32Array) -> float:
	var s := 0.0
	for v in buf:
		s += v * v
	return s / maxf(1.0, buf.size())


## Packs float samples as a 16-bit PCM AudioStreamWAV (stereo when r is
## given). loop = forward loop over the whole buffer.
static func make_wav(l: PackedFloat32Array, r: PackedFloat32Array = PackedFloat32Array(), rate: int = RATE, loop: bool = false) -> AudioStreamWAV:
	var stereo := not r.is_empty()
	var n := l.size()
	var ch := 2 if stereo else 1
	var bytes := PackedByteArray()
	bytes.resize(n * 2 * ch)
	for i in n:
		bytes.encode_s16(i * 2 * ch, int(clampf(l[i], -1.0, 1.0) * 32767.0))
		if stereo:
			bytes.encode_s16(i * 4 + 2, int(clampf(r[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = stereo
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w
