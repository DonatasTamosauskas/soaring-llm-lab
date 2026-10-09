class_name AudioAnalysis
extends RefCounted

## Measuring instruments for the sound the game actually generates.
##
## The whole of the audio area's claim to being verified rests on this file: you
## cannot hear a headless test run, so every statement about the soundscape is
## made about numbers taken off the rendered buffers — how loud, how bright, how
## fast it arrives, how deeply it pulses. [AudioTests] asserts on these; nothing
## in the game imports them.
##
## Deliberately plain: a Hann-windowed Welch periodogram and a few envelope
## measures. No cleverness, because a bug in the instrument reads as a bug in
## the thing being measured, and that is the most expensive kind of mistake
## available here.


## The louder ear, sample by sample. Everything in this file works on mono, and
## taking the maximum rather than the mean keeps a hard-panned wingbeat from
## being halved on its way into the measurement.
static func mono(buffer: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(buffer.size())
	for i in buffer.size():
		var frame: Vector2 = buffer[i]
		out[i] = frame.x if absf(frame.x) >= absf(frame.y) else frame.y
	return out


static func left(buffer: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(buffer.size())
	for i in buffer.size():
		out[i] = buffer[i].x
	return out


static func right(buffer: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(buffer.size())
	for i in buffer.size():
		out[i] = buffer[i].y
	return out


static func rms(samples: PackedFloat32Array, from: int = 0, to: int = -1) -> float:
	var last: int = samples.size() if to < 0 else mini(to, samples.size())
	var first: int = maxi(0, from)
	if last <= first:
		return 0.0
	var total: float = 0.0
	for i in range(first, last):
		var value: float = samples[i]
		if not is_finite(value):
			return NAN
		total += value * value
	return sqrt(total / float(last - first))


static func peak(samples: PackedFloat32Array) -> float:
	var loudest: float = 0.0
	for i in samples.size():
		var value: float = absf(samples[i])
		if not is_finite(value):
			return NAN
		if value > loudest:
			loudest = value
	return loudest


## How many samples sit at or beyond full scale. Any at all means the mix is
## clipping, which is the one audio fault that cannot be mistaken for taste.
static func clipped(samples: PackedFloat32Array) -> int:
	var count: int = 0
	for i in samples.size():
		if absf(samples[i]) >= 0.999:
			count += 1
	return count


## How different the two ears are, 0 identical, 1 unrelated. Wind that is the
## same in both ears collapses to a point between them, which is the wrong image
## for being inside an airstream.
static func decorrelation(buffer: PackedVector2Array) -> float:
	var a: PackedFloat32Array = left(buffer)
	var b: PackedFloat32Array = right(buffer)
	var sum_ab: float = 0.0
	var sum_aa: float = 0.0
	var sum_bb: float = 0.0
	for i in a.size():
		sum_ab += a[i] * b[i]
		sum_aa += a[i] * a[i]
		sum_bb += b[i] * b[i]
	if sum_aa <= 1e-12 or sum_bb <= 1e-12:
		return 0.0
	return 1.0 - absf(sum_ab) / sqrt(sum_aa * sum_bb)


# --- spectrum ------------------------------------------------------------------

## Average power spectrum: a Hann-windowed periodogram averaged over as many
## half-overlapping blocks as the signal allows. Returns [param size]/2 bins,
## bin [code]i[/code] centred on [code]i * rate / size[/code] Hz.
static func spectrum(
	samples: PackedFloat32Array, size: int = 1024
) -> PackedFloat32Array:
	var bins: int = size / 2
	var out := PackedFloat32Array()
	out.resize(bins)
	out.fill(0.0)
	if samples.size() < size:
		return out

	var window := PackedFloat32Array()
	window.resize(size)
	for i in size:
		window[i] = 0.5 - 0.5 * cos(TAU * float(i) / float(size))

	var blocks: int = 0
	var step: int = size / 2
	var start: int = 0
	while start + size <= samples.size():
		var real := PackedFloat32Array()
		var imaginary := PackedFloat32Array()
		real.resize(size)
		imaginary.resize(size)
		for i in size:
			real[i] = samples[start + i] * window[i]
			imaginary[i] = 0.0
		_fft(real, imaginary)
		for i in bins:
			out[i] += real[i] * real[i] + imaginary[i] * imaginary[i]
		blocks += 1
		start += step
	if blocks > 0:
		for i in bins:
			out[i] /= float(blocks)
	return out


## Power in a frequency band, as a fraction of the whole spectrum's power. A
## ratio rather than an absolute, so it says something about timbre and nothing
## about volume.
static func band(
	power: PackedFloat32Array, rate: float, low_hz: float, high_hz: float
) -> float:
	var total: float = 0.0
	var inside: float = 0.0
	var bin_hz: float = rate / float(power.size() * 2)
	for i in power.size():
		var hz: float = float(i) * bin_hz
		total += power[i]
		if hz >= low_hz and hz < high_hz:
			inside += power[i]
	if total <= 1e-20:
		return 0.0
	return inside / total


## Spectral centroid in Hz — the "brightness" of a sound, and the number that
## separates a thin hiss from a roar without either of them changing volume.
static func centroid(power: PackedFloat32Array, rate: float) -> float:
	var weighted: float = 0.0
	var total: float = 0.0
	var bin_hz: float = rate / float(power.size() * 2)
	for i in power.size():
		weighted += float(i) * bin_hz * power[i]
		total += power[i]
	if total <= 1e-20:
		return 0.0
	return weighted / total


## In-place radix-2 FFT. [param real] and [param imaginary] must be a power of
## two long.
static func _fft(real: PackedFloat32Array, imaginary: PackedFloat32Array) -> void:
	var n: int = real.size()
	var shift: int = 1
	while (1 << shift) < n:
		shift += 1
	# Bit reversal.
	for i in n:
		var j: int = 0
		var value: int = i
		for bit in shift:
			j = (j << 1) | (value & 1)
			value >>= 1
		if j > i:
			var tr: float = real[i]
			real[i] = real[j]
			real[j] = tr
			var ti: float = imaginary[i]
			imaginary[i] = imaginary[j]
			imaginary[j] = ti
	var length: int = 2
	while length <= n:
		var angle: float = -TAU / float(length)
		var step_real: float = cos(angle)
		var step_imaginary: float = sin(angle)
		var start: int = 0
		while start < n:
			var wr: float = 1.0
			var wi: float = 0.0
			for k in length / 2:
				var a: int = start + k
				var b: int = a + length / 2
				var tr: float = real[b] * wr - imaginary[b] * wi
				var ti: float = real[b] * wi + imaginary[b] * wr
				real[b] = real[a] - tr
				imaginary[b] = imaginary[a] - ti
				real[a] += tr
				imaginary[a] += ti
				var next: float = wr * step_real - wi * step_imaginary
				wi = wr * step_imaginary + wi * step_real
				wr = next
			start += length
		length <<= 1


# --- envelopes -----------------------------------------------------------------

## The shape of a sound over time: rectified and smoothed to [param hz], then
## thinned to one value per millisecond. This is what a listener's ear does
## before it decides whether something thumped, swelled or buffeted.
static func envelope(
	samples: PackedFloat32Array, rate: float, hz: float = 60.0
) -> PackedFloat32Array:
	var coefficient: float = clampf(TAU * hz / rate, 0.0005, 0.9)
	var stride: int = maxi(1, int(rate / 1000.0))
	var out := PackedFloat32Array()
	out.resize(samples.size() / stride)
	var level: float = 0.0
	var index: int = 0
	for i in samples.size():
		level += (absf(samples[i]) - level) * coefficient
		if i % stride == 0 and index < out.size():
			out[index] = level
			index += 1
	return out


## How deeply an envelope pulses at [param hz], relative to its own mean. A
## steady sound scores near zero; a buffet chopping at 13 Hz scores high. The
## envelope is sampled at 1 kHz by [method envelope].
static func modulation(shape: PackedFloat32Array, hz: float) -> float:
	if shape.size() < 64:
		return 0.0
	var mean: float = 0.0
	for i in shape.size():
		mean += shape[i]
	mean /= float(shape.size())
	if mean <= 1e-9:
		return 0.0
	# Goertzel at hz against a 1 kHz envelope rate.
	var real: float = 0.0
	var imaginary: float = 0.0
	for i in shape.size():
		var angle: float = TAU * hz * float(i) / 1000.0
		var value: float = shape[i] - mean
		real += value * cos(angle)
		imaginary += value * sin(angle)
	return 2.0 * sqrt(real * real + imaginary * imaginary) / (float(shape.size()) * mean)


## Where a sound starts, in seconds: the first moment its short-term level
## crosses [param factor] times the level it had at the very beginning. Used to
## prove that a transient is a transient and not a swell.
static func onset(
	samples: PackedFloat32Array, rate: float, factor: float = 3.0
) -> float:
	var shape: PackedFloat32Array = envelope(samples, rate, 200.0)
	if shape.size() < 8:
		return -1.0
	var floor_level: float = maxf(shape[0], 1e-5)
	for i in shape.size():
		if shape[i] > floor_level * factor:
			return float(i) / 1000.0
	return -1.0


## Highest value of the envelope, and where it happened, as [peak, seconds].
static func envelope_peak(shape: PackedFloat32Array) -> Array:
	var best: float = 0.0
	var when: int = 0
	for i in shape.size():
		if shape[i] > best:
			best = shape[i]
			when = i
	return [best, float(when) / 1000.0]


## Writes a buffer out as a real WAV file. Nothing in the suite calls this; it is
## for a human who wants to put the game's sounds on a pair of speakers.
static func save_wav(
	samples: PackedFloat32Array, rate: float, path: String
) -> void:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(rate)
	wav.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	wav.save_to_wav(path)
