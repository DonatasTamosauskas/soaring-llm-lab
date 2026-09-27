class_name AudioAnalysis
extends RefCounted
## Offline measurements of rendered audio: levels, envelopes, spectra,
## syllables, pitch tracks and periodicity.
##
## The audio area cannot listen to its own output, so every claim about a
## sound (the wind gets louder with speed, a tuck is brighter, a wingbeat is
## a transient, a crow is not a gull) is checked numerically with these
## functions: in tests/unit/audio/, in the call-preparation tool that picked
## the recordings, and in the review renders under artifacts/audio/.
##
## Buffers are mono PackedFloat32Array in [-1, 1] plus a sample rate. All
## functions are static and allocation-light; the FFT tables are cached per
## size. None of this runs in the game loop.

## FFT tables per size: n -> [bit-reverse (PackedInt32Array), cos, sin, hann].
static var _tables := {}
## Guards _tables: the tests analyse clips on several worker threads.
static var _tables_mutex := Mutex.new()


static func db(x: float) -> float:
	return 20.0 * log(maxf(x, 1e-10)) / log(10.0)


static func from_db(d: float) -> float:
	return pow(10.0, d / 20.0)


## Decodes a 16-bit (or 8-bit) PCM AudioStreamWAV: {rate, l, r, mono}.
## r == l for mono streams; mono is (l + r) / 2.
static func decode_wav(w: AudioStreamWAV) -> Dictionary:
	var data := w.data
	var ch := 2 if w.stereo else 1
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	if w.format == AudioStreamWAV.FORMAT_16_BITS:
		var frames := data.size() / (2 * ch)
		l.resize(frames)
		r.resize(frames)
		for i in frames:
			var a := data.decode_s16(i * 2 * ch) / 32768.0
			l[i] = a
			r[i] = data.decode_s16(i * 2 * ch + 2) / 32768.0 if ch == 2 else a
	elif w.format == AudioStreamWAV.FORMAT_8_BITS:
		var frames8 := data.size() / ch
		l.resize(frames8)
		r.resize(frames8)
		for i in frames8:
			var a8 := data.decode_s8(i * ch) / 128.0
			l[i] = a8
			r[i] = data.decode_s8(i * ch + 1) / 128.0 if ch == 2 else a8
	else:
		push_error("[audio] decode_wav: compressed WAV formats are not supported")
	var mono := l
	if ch == 2:
		mono = PackedFloat32Array()
		mono.resize(l.size())
		for i in l.size():
			mono[i] = 0.5 * (l[i] + r[i])
	return {"rate": w.mix_rate, "l": l, "r": r, "mono": mono}


## PCM of any clip the bank holds: {mono, l, r, rate}. Synthesized clips are
## 16-bit PCM already; imported WAVs are compressed (QOA) in the import
## cache, so their source file is read instead (dev/test only: exported
## builds do not ship the source files).
static func clip_pcm(st: AudioStream) -> Dictionary:
	var w := st as AudioStreamWAV
	if w and (w.format == AudioStreamWAV.FORMAT_16_BITS or w.format == AudioStreamWAV.FORMAT_8_BITS):
		return decode_wav(w)
	var path := st.resource_path
	if path.begins_with("res://") and path.ends_with(".wav"):
		var src := AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
		if src:
			return decode_wav(src)
	return {}


## Splits captured stereo frames (PackedVector2Array) into {l, r, mono}.
static func split_frames(frames: PackedVector2Array) -> Dictionary:
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	var m := PackedFloat32Array()
	var n := frames.size()
	l.resize(n)
	r.resize(n)
	m.resize(n)
	for i in n:
		var f := frames[i]
		l[i] = f.x
		r[i] = f.y
		m[i] = 0.5 * (f.x + f.y)
	return {"l": l, "r": r, "mono": m}


static func rms(buf: PackedFloat32Array, from: int = 0, to: int = -1) -> float:
	if to < 0 or to > buf.size():
		to = buf.size()
	if to <= from:
		return 0.0
	var s := 0.0
	for i in range(from, to):
		s += buf[i] * buf[i]
	return sqrt(s / float(to - from))


static func peak(buf: PackedFloat32Array) -> float:
	var p := 0.0
	for v in buf:
		p = maxf(p, absf(v))
	return p


## RMS per window of win seconds (envelope sampled at 1 / win Hz).
static func envelope(buf: PackedFloat32Array, rate: float, win: float = 0.005) -> PackedFloat32Array:
	var w := maxi(1, int(round(rate * win)))
	var n := buf.size() / w
	var out := PackedFloat32Array()
	out.resize(n)
	for k in n:
		var s := 0.0
		var o := k * w
		for i in w:
			var v := buf[o + i]
			s += v * v
		out[k] = sqrt(s / w)
	return out


static func _get_tables(n: int) -> Array:
	_tables_mutex.lock()
	var cached: Array = _tables.get(n, [])
	_tables_mutex.unlock()
	if not cached.is_empty():
		return cached
	var bits := 0
	while (1 << bits) < n:
		bits += 1
	var rev := PackedInt32Array()
	rev.resize(n)
	for i in n:
		var r := 0
		var x := i
		for b in bits:
			r = (r << 1) | (x & 1)
			x >>= 1
		rev[i] = r
	var cs := PackedFloat32Array()
	var sn := PackedFloat32Array()
	cs.resize(n / 2)
	sn.resize(n / 2)
	for i in n / 2:
		cs[i] = cos(-TAU * i / n)
		sn[i] = sin(-TAU * i / n)
	var hann := PackedFloat32Array()
	hann.resize(n)
	for i in n:
		hann[i] = 0.5 - 0.5 * cos(TAU * i / n)
	var t := [rev, cs, sn, hann]
	_tables_mutex.lock()
	_tables[n] = t
	_tables_mutex.unlock()
	return t


## Magnitude spectrum (n/2 + 1 bins) of buf[start .. start + n), Hann
## windowed, scaled so a full-scale sine reads 1.0 in its bin. n must be a
## power of two; samples past the end count as silence.
static func magnitude(buf: PackedFloat32Array, start: int, n: int) -> PackedFloat32Array:
	var t := _get_tables(n)
	var rev: PackedInt32Array = t[0]
	var cs: PackedFloat32Array = t[1]
	var sn: PackedFloat32Array = t[2]
	var hann: PackedFloat32Array = t[3]
	var re := PackedFloat32Array()
	var im := PackedFloat32Array()
	re.resize(n)
	im.resize(n)
	var size := buf.size()
	for i in n:
		var j := start + i
		re[rev[i]] = buf[j] * hann[i] if j < size and j >= 0 else 0.0
	var half := 1
	while half < n:
		var step := n / (half * 2)
		var k := 0
		while k < n:
			for j in half:
				var wr := cs[j * step]
				var wi := sn[j * step]
				var a := k + j
				var b := a + half
				var br := re[b]
				var bi := im[b]
				var tr := br * wr - bi * wi
				var ti := br * wi + bi * wr
				var ar := re[a]
				var ai := im[a]
				re[b] = ar - tr
				im[b] = ai - ti
				re[a] = ar + tr
				im[a] = ai + ti
			k += half * 2
		half *= 2
	var out := PackedFloat32Array()
	out.resize(n / 2 + 1)
	# Hann coherent gain is 0.5: a sine of amplitude A gives |X| = A n / 4.
	var scale := 4.0 / n
	for i in n / 2 + 1:
		out[i] = sqrt(re[i] * re[i] + im[i] * im[i]) * scale
	return out


## Short-time magnitude spectra: Array of PackedFloat32Array (n/2 + 1 each).
static func stft(buf: PackedFloat32Array, n: int = 1024, hop: int = 512) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	var start := 0
	while start + n / 2 < buf.size():
		out.append(magnitude(buf, start, n))
		start += hop
	return out


## Mean power spectrum over frames whose level is within gate_db of the
## loudest frame (so silences do not dilute it). Power, not magnitude.
static func mean_power(buf: PackedFloat32Array, n: int = 1024, hop: int = 512, gate_db: float = -40.0,
		frames: Array[PackedFloat32Array] = []) -> PackedFloat32Array:
	if frames.is_empty():
		frames = stft(buf, n, hop)
	var energies := PackedFloat32Array()
	var best := 0.0
	for f in frames:
		var e := 0.0
		for v in f:
			e += v * v
		energies.append(e)
		best = maxf(best, e)
	var acc := PackedFloat32Array()
	acc.resize(n / 2 + 1)
	acc.fill(0.0)
	var used := 0
	var gate := best * pow(10.0, gate_db / 10.0)
	for fi in frames.size():
		if energies[fi] < gate or energies[fi] <= 0.0:
			continue
		used += 1
		var f := frames[fi]
		for i in f.size():
			acc[i] += f[i] * f[i]
	if used > 0:
		for i in acc.size():
			acc[i] /= used
	return acc


static func bin_hz(i: int, n: int, rate: float) -> float:
	return i * rate / n


## Power-weighted mean frequency between lo and hi Hz.
static func centroid(power: PackedFloat32Array, rate: float, lo: float = 20.0, hi: float = 1e9) -> float:
	var n := (power.size() - 1) * 2
	var s := 0.0
	var w := 0.0
	for i in power.size():
		var f := bin_hz(i, n, rate)
		if f < lo or f > hi:
			continue
		s += f * power[i]
		w += power[i]
	return s / w if w > 0.0 else 0.0


## Fraction of power between lo and hi Hz (of everything above 20 Hz).
static func band_fraction(power: PackedFloat32Array, rate: float, lo: float, hi: float) -> float:
	var n := (power.size() - 1) * 2
	var inside := 0.0
	var total := 0.0
	for i in power.size():
		var f := bin_hz(i, n, rate)
		if f < 20.0:
			continue
		total += power[i]
		if f >= lo and f < hi:
			inside += power[i]
	return inside / total if total > 0.0 else 0.0


## Relative loudness of a power spectrum as the ear weighs it: total power
## after the IEC 61672 A-weighting curve, in dB (compare two spectra made
## the same way; the absolute value depends on the spectrum's scaling).
## Plain RMS counts a rumble the ear hardly hears as much as a hiss.
static func a_weighted_db(power: PackedFloat32Array, rate: float) -> float:
	var n := (power.size() - 1) * 2
	var total := 0.0
	for i in range(1, power.size()):
		var f2 := pow(bin_hz(i, n, rate), 2.0)
		var ra := 148693636.0 * f2 * f2 / ((f2 + 424.36) * sqrt((f2 + 11599.29) * (f2 + 544496.41)) * (f2 + 148693636.0))
		total += power[i] * ra * ra * 1.5849
	return 10.0 * log(maxf(total, 1e-30)) / log(10.0)


## Hann-windowed spectra (magnitude()) sum to 3x the mean square of the
## signal over the bins: a sine of amplitude A reads A^2 in its bin and
## A^2 / 4 in each neighbour; noise obeys Parseval with the window's 3/8
## energy. Dividing by this turns a bin-power sum into an RMS-referenced
## level (dBFS RMS), so band and A-weighted levels compare with plain RMS.
const BIN_POWER_PER_MS := 3.0

## A-weighting (IEC 61672) power factor per bin of an n-point spectrum.
## Cached per (n, rate).
static var _aw_cache := {}


static func a_weights(n: int, rate: float) -> PackedFloat32Array:
	var key := "%d@%d" % [n, int(rate)]
	_tables_mutex.lock()
	var cached: PackedFloat32Array = _aw_cache.get(key, PackedFloat32Array())
	_tables_mutex.unlock()
	if not cached.is_empty():
		return cached
	var w := PackedFloat32Array()
	w.resize(n / 2 + 1)
	for i in w.size():
		var f := bin_hz(i, n, rate)
		if f < 10.0:
			w[i] = 0.0
			continue
		var f2 := f * f
		var ra := 148693636.0 * f2 * f2 / ((f2 + 424.36) * sqrt((f2 + 11599.29) * (f2 + 544496.41)) * (f2 + 148693636.0))
		w[i] = ra * ra * 1.5849
	_tables_mutex.lock()
	_aw_cache[key] = w
	_tables_mutex.unlock()
	return w


## ITU-R BS.1770 K-weighting power factor per bin of an n-point spectrum:
## the head's pre-filter shelf (+4 dB above ~2 kHz) and the RLB high-pass
## (-3 dB near 40 Hz), their 48 kHz biquads evaluated at each bin's
## frequency (exact at 48 kHz, within 0.1 dB below 16 kHz at 44.1 kHz).
## Cached per (n, rate).
static var _kw_cache := {}


static func k_weights(n: int, rate: float) -> PackedFloat32Array:
	var key := "%d@%d" % [n, int(rate)]
	_tables_mutex.lock()
	var cached: PackedFloat32Array = _kw_cache.get(key, PackedFloat32Array())
	_tables_mutex.unlock()
	if not cached.is_empty():
		return cached
	var w := PackedFloat32Array()
	w.resize(n / 2 + 1)
	for i in w.size():
		var om := TAU * bin_hz(i, n, rate) / 48000.0
		w[i] = _biquad_mag2([1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585], om) \
			* _biquad_mag2([1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621], om)
	_tables_mutex.lock()
	_kw_cache[key] = w
	_tables_mutex.unlock()
	return w


## |H(e^jw)|^2 of a biquad [b0, b1, b2, a1, a2].
static func _biquad_mag2(c: Array, om: float) -> float:
	var nr: float = c[0] + c[1] * cos(om) + c[2] * cos(2.0 * om)
	var ni: float = -(c[1] * sin(om) + c[2] * sin(2.0 * om))
	var dr: float = 1.0 + c[3] * cos(om) + c[4] * cos(2.0 * om)
	var di: float = -(c[3] * sin(om) + c[4] * sin(2.0 * om))
	return (nr * nr + ni * ni) / maxf(dr * dr + di * di, 1e-30)


## Ungated programme loudness (LUFS, ITU-R BS.1770) of a stereo recording:
## -0.691 + 10 log10 of the sum of both channels' K-weighted mean squares.
## (Ungated: a few seconds of one game state, where gating changes little.)
## fader_db is added (a tap sits before its bus fader).
static func lufs(l: PackedFloat32Array, r: PackedFloat32Array, rate: float, fader_db: float = 0.0) -> float:
	var w := k_weights(1024, rate)
	var ms := 0.0
	for ch in [l, r]:
		var frames := stft(ch, 1024, 512)
		if frames.is_empty():
			continue
		var acc := 0.0
		for fr in frames:
			var s := 0.0
			for i in fr.size():
				s += fr[i] * fr[i] * w[i]
			acc += s / BIN_POWER_PER_MS
		ms += acc / frames.size()
	return -0.691 + 10.0 * log(maxf(ms, 1e-30)) / log(10.0) + fader_db


## Short-term A-weighted loudness of a buffer, dB RMS-referenced (a 1 kHz
## tone reads its RMS in dBFS): {max: the loudest `win` seconds (the level a
## listener remembers a call or a click by), mean: the whole buffer,
## max_at: the centre of that loudest window, s}. STFT of 1024 points,
## hop 512.
static func loudness_aw(buf: PackedFloat32Array, rate: float, win: float = 0.4,
		frames: Array[PackedFloat32Array] = []) -> Dictionary:
	if frames.is_empty():
		frames = stft(buf, 1024, 512)
	var w := a_weights(1024, rate)
	var fp := PackedFloat32Array()
	for fr in frames:
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		fp.append(s / BIN_POWER_PER_MS)
	if fp.is_empty():
		return {"max": -INF, "mean": -INF, "max_at": 0.0}
	# Every window spans `win` seconds: the frames before the buffer's start
	# count as silence (a click at a buffer's first frame is not taken for
	# a 0.1 s sound as loud as its first 23 ms).
	var per := maxi(1, int(round(win * rate / 512.0)))
	var total := 0.0
	var best := 0.0
	var best_k := 0
	var acc := 0.0
	for k in fp.size():
		total += fp[k]
		acc += fp[k]
		if k >= per:
			acc -= fp[k - per]
		if acc / per > best:
			best = acc / per
			best_k = k
	# Frames k-per+1 .. k span samples (k-per+1)*512 .. k*512+1024.
	var centre := (float(best_k - per + 1) * 512.0 + float(best_k) * 512.0 + 1024.0) * 0.5 / rate
	return {"max": 10.0 * log(maxf(best, 1e-30)) / log(10.0),
		"mean": 10.0 * log(maxf(total / fp.size(), 1e-30)) / log(10.0), "max_at": maxf(centre, 0.0)}


## Level of a mean power spectrum (mean_power()) between lo and hi Hz, dB
## RMS-referenced (the octave-band level of the signal).
static func band_db(power: PackedFloat32Array, rate: float, lo: float, hi: float) -> float:
	var n := (power.size() - 1) * 2
	var s := 0.0
	for i in power.size():
		var f := bin_hz(i, n, rate)
		if f >= lo and f < hi:
			s += power[i]
	return 10.0 * log(maxf(s / BIN_POWER_PER_MS, 1e-30)) / log(10.0)


## A-weighted level of a mean power spectrum, dB RMS-referenced.
static func a_level_db(power: PackedFloat32Array, rate: float) -> float:
	return a_weighted_db(power, rate) - 10.0 * log(BIN_POWER_PER_MS) / log(10.0)


## Frequency below which `frac` of the power lies (spectral roll-off).
static func rolloff(power: PackedFloat32Array, rate: float, frac: float = 0.85) -> float:
	var n := (power.size() - 1) * 2
	var total := 0.0
	for i in range(1, power.size()):
		total += power[i]
	var acc := 0.0
	for i in range(1, power.size()):
		acc += power[i]
		if acc >= frac * total:
			return bin_hz(i, n, rate)
	return rate * 0.5


## Wiener entropy (geometric / arithmetic mean power) between lo and hi Hz:
## ~0 for a pure tone, ~0.56 for white noise (a periodogram's own spread).
## Bins are floored 60 dB under the strongest so empty bins outside a
## band-limited call cannot drag the geometric mean to zero.
static func flatness(power: PackedFloat32Array, rate: float, lo: float = 200.0, hi: float = 12000.0) -> float:
	var n := (power.size() - 1) * 2
	var i_lo := maxi(1, int(ceil(lo * n / rate)))
	var i_hi := mini(power.size() - 1, int(floor(hi * n / rate)))
	var top := 0.0
	for i in range(i_lo, i_hi + 1):
		top = maxf(top, power[i])
	if top <= 0.0:
		return 0.0
	var fl := top * 1e-6
	var logsum := 0.0
	var sum := 0.0
	var k := 0
	for i in range(i_lo, i_hi + 1):
		var p := maxf(power[i], fl)
		logsum += log(p)
		sum += p
		k += 1
	return exp(logsum / k) / (sum / k) if k > 0 else 0.0


## Loudest frequency per frame between lo and hi Hz, for frames within
## gate_db of the loudest frame: {t: [s], hz: [Hz], db: [dBFS]}. Parabolic
## interpolation refines the peak between bins.
static func peak_track(buf: PackedFloat32Array, rate: float, lo: float = 150.0, hi: float = 12000.0,
		n: int = 1024, hop: int = 256, gate_db: float = -20.0, frames: Array[PackedFloat32Array] = []) -> Dictionary:
	if frames.is_empty():
		frames = stft(buf, n, hop)
	var i_lo := maxi(1, int(ceil(lo * n / rate)))
	var i_hi := mini(n / 2 - 1, int(floor(hi * n / rate)))
	var peaks := PackedFloat32Array()
	var freqs := PackedFloat32Array()
	var best := 0.0
	for f in frames:
		var pk := 0.0
		var pi := i_lo
		for i in range(i_lo, i_hi + 1):
			if f[i] > pk:
				pk = f[i]
				pi = i
		var a := f[pi - 1]
		var b := f[pi]
		var c := f[pi + 1]
		var den := a - 2.0 * b + c
		var off := 0.5 * (a - c) / den if absf(den) > 1e-12 else 0.0
		freqs.append((pi + clampf(off, -0.5, 0.5)) * rate / n)
		peaks.append(pk)
		best = maxf(best, pk)
	var t := PackedFloat32Array()
	var hz := PackedFloat32Array()
	var lv := PackedFloat32Array()
	var gate := best * from_db(gate_db)
	for k in frames.size():
		if peaks[k] >= gate and peaks[k] > 0.0:
			t.append((k * hop + n * 0.5) / rate)
			hz.append(freqs[k])
			lv.append(db(peaks[k]))
	return {"t": t, "hz": hz, "db": lv}


static func median(v: PackedFloat32Array) -> float:
	if v.is_empty():
		return 0.0
	var s := v.duplicate()
	s.sort()
	var m := s.size() / 2
	return s[m] if s.size() % 2 == 1 else 0.5 * (s[m - 1] + s[m])


static func percentile(v: PackedFloat32Array, q: float) -> float:
	if v.is_empty():
		return 0.0
	var s := v.duplicate()
	s.sort()
	return s[clampi(int(round(q * (s.size() - 1))), 0, s.size() - 1)]


## Syllables: stretches where the 5 ms envelope rises above on_db (relative
## to its peak) until it falls below off_db; gaps shorter than min_gap merge,
## blips shorter than min_len are dropped. Returns [Vector2(start_s, end_s)].
static func syllables(buf: PackedFloat32Array, rate: float, on_db: float = -20.0, off_db: float = -26.0,
		min_len: float = 0.012, min_gap: float = 0.02) -> Array[Vector2]:
	var win := 0.005
	var env := envelope(buf, rate, win)
	var pk := 0.0
	for v in env:
		pk = maxf(pk, v)
	var out: Array[Vector2] = []
	if pk <= 0.0:
		return out
	var on_t := pk * from_db(on_db)
	var off_t := pk * from_db(off_db)
	var inside := false
	var s0 := 0
	var raw: Array[Vector2] = []
	for k in env.size():
		if not inside and env[k] >= on_t:
			inside = true
			s0 = k
		elif inside and env[k] < off_t:
			inside = false
			raw.append(Vector2(s0 * win, k * win))
	if inside:
		raw.append(Vector2(s0 * win, env.size() * win))
	for s in raw:
		if not out.is_empty() and s.x - out[-1].y < min_gap:
			out[-1].y = s.y
		else:
			out.append(s)
	var kept: Array[Vector2] = []
	for s in out:
		if s.y - s.x >= min_len:
			kept.append(s)
	return kept


## Periodicity of an envelope: the strongest normalised autocorrelation peak
## for lags between 1/hi_hz and 1/lo_hz. {hz, strength (0..1)}. A strictly
## periodic flutter scores near 1; noise near 0.
static func periodicity(env: PackedFloat32Array, env_rate: float, lo_hz: float, hi_hz: float) -> Dictionary:
	var n := env.size()
	var mean := 0.0
	for v in env:
		mean += v
	mean /= maxf(1.0, n)
	var x := PackedFloat32Array()
	x.resize(n)
	var e0 := 0.0
	for i in n:
		x[i] = env[i] - mean
		e0 += x[i] * x[i]
	var best := {"hz": 0.0, "strength": 0.0}
	if e0 <= 0.0:
		return best
	var lag_lo := maxi(1, int(floor(env_rate / hi_hz)))
	var lag_hi := mini(n / 2, int(ceil(env_rate / lo_hz)))
	var ac := PackedFloat32Array()
	ac.resize(lag_hi + 2)
	for lag in range(lag_lo - 1, lag_hi + 2):
		if lag < 1 or lag >= n:
			continue
		var s := 0.0
		for i in n - lag:
			s += x[i] * x[i + lag]
		# Unbiased: normalise by the overlap so long lags are not penalised.
		ac[lag] = (s / (n - lag)) / (e0 / n)
	var peaks: Array[int] = []
	var top := 0.0
	for lag in range(lag_lo, lag_hi + 1):
		# Local maxima only: the zero-lag lobe's shoulder is not a period.
		if ac[lag] >= ac[lag - 1] and ac[lag] >= ac[lag + 1] and ac[lag] > 0.0:
			peaks.append(lag)
			top = maxf(top, ac[lag])
	# The period is the SHORTEST lag that is (nearly) as strong as the best:
	# multiples of the period (sub-harmonics) correlate just as well.
	for lag in peaks:
		if ac[lag] >= 0.85 * top:
			# Parabolic refinement of the lag.
			var a := ac[lag - 1]
			var b := ac[lag]
			var c := ac[lag + 1]
			var den := a - 2.0 * b + c
			var off := clampf(0.5 * (a - c) / den, -0.5, 0.5) if absf(den) > 1e-9 else 0.0
			return {"hz": env_rate / (lag + off), "strength": b}
	return best


## Notes per second: peaks of the 5 ms envelope (smoothed over 15 ms) that
## stand at least prominence_db above the lowest point on either side back
## to a higher peak, within floor_db of the loudest, at least min_sep apart.
## Unlike syllables(), this separates the notes of a trill or a twitter
## whose gaps never fall silent.
static func notes(buf: PackedFloat32Array, rate: float, prominence_db: float = 6.0, floor_db: float = -30.0,
		min_sep: float = 0.03) -> Array[float]:
	var env := envelope(buf, rate, 0.005)
	var n := env.size()
	var sm := PackedFloat32Array()
	sm.resize(n)
	for i in n:
		var s := 0.0
		var c := 0
		for k in range(maxi(0, i - 1), mini(n, i + 2)):
			s += env[k]
			c += 1
		sm[i] = db(s / c)
	var top := -INF
	for v in sm:
		top = maxf(top, v)
	var out: Array[float] = []
	var last := -INF
	for i in range(1, n - 1):
		if sm[i] < top + floor_db or sm[i] < sm[i - 1] or sm[i] < sm[i + 1]:
			continue
		# Prominence: descend on each side until a higher point or the end.
		var lmin := sm[i]
		var j := i - 1
		while j >= 0 and sm[j] <= sm[i]:
			lmin = minf(lmin, sm[j])
			j -= 1
		var rmin := sm[i]
		j = i + 1
		while j < n and sm[j] <= sm[i]:
			rmin = minf(rmin, sm[j])
			j += 1
		if sm[i] - maxf(lmin, rmin) < prominence_db:
			continue
		var t := i * 0.005
		if t - last < min_sep:
			continue
		out.append(t)
		last = t
	return out


## How tonal a sound is: over frames within 20 dB of the loudest, the median
## share of each frame's power (150 Hz - 12 kHz) held by its strongest bin
## and its two neighbours on each side. Whistles and coos score high (0.4+),
## caws, rasps and noise low (< 0.2).
static func tonality(buf: PackedFloat32Array, rate: float, n: int = 1024, frames: Array[PackedFloat32Array] = []) -> float:
	if frames.is_empty():
		frames = stft(buf, n, n / 2)
	var i_lo := maxi(1, int(ceil(150.0 * n / rate)))
	var i_hi := mini(n / 2 - 2, int(floor(minf(12000.0, rate * 0.45) * n / rate)))
	var energies := PackedFloat32Array()
	var best := 0.0
	for f in frames:
		var e := 0.0
		for i in range(i_lo, i_hi + 1):
			e += f[i] * f[i]
		energies.append(e)
		best = maxf(best, e)
	var shares := PackedFloat32Array()
	for fi in frames.size():
		if energies[fi] < best * 0.01 or energies[fi] <= 0.0:
			continue
		var f2: PackedFloat32Array = frames[fi]
		var pk := i_lo
		for i in range(i_lo, i_hi + 1):
			if f2[i] > f2[pk]:
				pk = i
		var s := 0.0
		for i in range(maxi(i_lo, pk - 2), mini(i_hi, pk + 2) + 1):
			s += f2[i] * f2[i]
		shares.append(s / energies[fi])
	return median(shares)


## Least-squares slope of y over x.
static func slope(x: PackedFloat32Array, y: PackedFloat32Array) -> float:
	var n := mini(x.size(), y.size())
	if n < 2:
		return 0.0
	var mx := 0.0
	var my := 0.0
	for i in n:
		mx += x[i]
		my += y[i]
	mx /= n
	my /= n
	var sxy := 0.0
	var sxx := 0.0
	for i in n:
		sxy += (x[i] - mx) * (y[i] - my)
		sxx += (x[i] - mx) * (x[i] - mx)
	return sxy / sxx if sxx > 0.0 else 0.0


## Trims leading/trailing stretches quieter than floor_db below the peak
## (start_db, if given, for the lead-in). Returns {start, end} in samples.
static func active_range(buf: PackedFloat32Array, rate: float, floor_db: float = -40.0, start_db: float = NAN) -> Dictionary:
	var env := envelope(buf, rate, 0.005)
	var pk := 0.0
	for v in env:
		pk = maxf(pk, v)
	var th := pk * from_db(floor_db)
	var th_a := pk * from_db(floor_db if is_nan(start_db) else start_db)
	var a := 0
	while a < env.size() and env[a] < th_a:
		a += 1
	var b := env.size() - 1
	while b > a and env[b] < th:
		b -= 1
	var w := int(round(rate * 0.005))
	return {"start": a * w, "end": mini(buf.size(), (b + 1) * w)}


## Everything the call tests and the prep tool compare between species.
##   duration        s, whole buffer
##   active          s, from first to last sound above -40 dB of the peak
##   rms_db/peak_db  dBFS (rms over the active part)
##   centroid        Hz, mean power spectrum of the loud frames
##   dominant        Hz, median loudest frequency of the loud frames
##   dominant_lo/hi  Hz, 10th/90th percentile of that track
##   flatness        0 tone .. 1 noise (200 Hz - 12 kHz)
##   syllables       count;  syl_rate  per second of active sound
##   syl_len         s, median syllable length;  longest  s
##   slope_oct       octaves/s pitch drift inside the longest syllable
##   low_frac        power fraction below 1 kHz
##   rolloff         Hz below which 85% of the power lies (bandwidth)
##   rolloff95       the same for 95% (harmonic richness vs the pitch)
##   note_rate       notes per second (envelope peaks, see notes())
##   tonality        0 noisy .. 1 pure tone (see tonality())
##   loud_aw         A-weighted short-term loudness, dB: the loudest 0.4 s
##                   (loudness_aw; the active range holds it)
static func features(buf: PackedFloat32Array, rate: float) -> Dictionary:
	var ar := active_range(buf, rate)
	var a: int = ar["start"]
	var b: int = ar["end"]
	var act := buf.slice(a, b)
	# One STFT shared by the spectrum, pitch track and tonality (GDScript
	# FFTs dominate the cost of analysing a clip).
	var frames := stft(act, 1024, 512)
	var power := mean_power(act, 1024, 512, -30.0, frames)
	var track := peak_track(act, rate, 150.0, minf(12000.0, rate * 0.45), 1024, 512, -20.0, frames)
	var syl := syllables(act, rate)
	var lens := PackedFloat32Array()
	var longest := Vector2.ZERO
	for s in syl:
		lens.append(s.y - s.x)
		if s.y - s.x > longest.y - longest.x:
			longest = s
	# Pitch drift within the longest syllable (hawk "kee-eeer" falls).
	var tx := PackedFloat32Array()
	var ty := PackedFloat32Array()
	var th: PackedFloat32Array = track["t"]
	var hz: PackedFloat32Array = track["hz"]
	for i in th.size():
		if th[i] >= longest.x and th[i] <= longest.y:
			tx.append(th[i])
			ty.append(log(maxf(hz[i], 1.0)) / log(2.0))
	var active_s := float(b - a) / rate
	var la := loudness_aw(act, rate, 0.4, frames)
	return {
		"duration": buf.size() / rate,
		"active": active_s,
		"rms_db": db(rms(act)),
		"peak_db": db(peak(buf)),
		"centroid": centroid(power, rate, 100.0),
		"dominant": median(hz),
		"dominant_lo": percentile(hz, 0.1),
		"dominant_hi": percentile(hz, 0.9),
		"flatness": flatness(power, rate, 200.0, minf(12000.0, rate * 0.45)),
		"syllables": syl.size(),
		"syl_rate": syl.size() / maxf(active_s, 0.05),
		"syl_len": median(lens),
		"longest": longest.y - longest.x,
		"slope_oct": slope(tx, ty),
		"low_frac": band_fraction(power, rate, 20.0, 1000.0),
		"rolloff": rolloff(power, rate, 0.85),
		"rolloff95": rolloff(power, rate, 0.95),
		"note_rate": notes(act, rate).size() / maxf(active_s, 0.05),
		"tonality": tonality(act, rate, 1024, frames),
		"loud_aw": la["max"],
		# Where the loudest 0.4 s is centred in the whole buffer, s.
		"loud_at": a / rate + float(la["max_at"]),
		# Share of the A-weighted power above 5 kHz (what air absorption and
		# a 5 kHz shelf act on).
		"hf_aw": a_share_above(power, rate, 5000.0),
	}


## Share (0..1) of a power spectrum's A-weighted power above `hz`.
static func a_share_above(power: PackedFloat32Array, rate: float, hz: float) -> float:
	var n := (power.size() - 1) * 2
	var w := a_weights(n, rate)
	var hi := 0.0
	var total := 0.0
	for i in power.size():
		var p := power[i] * w[i]
		total += p
		if bin_hz(i, n, rate) >= hz:
			hi += p
	return hi / total if total > 0.0 else 0.0


## In-place complex FFT on (re, im) (radix 2, n = power of two). inverse
## includes the 1/n scale. Returns [re, im] (the same arrays).
static func fft_complex(re: PackedFloat32Array, im: PackedFloat32Array, inverse: bool = false) -> Array:
	var n := re.size()
	var t := _get_tables(n)
	var rev: PackedInt32Array = t[0]
	var cs: PackedFloat32Array = t[1]
	var sn: PackedFloat32Array = t[2]
	for i in n:
		var j := rev[i]
		if j > i:
			var tr0 := re[i]
			re[i] = re[j]
			re[j] = tr0
			var ti0 := im[i]
			im[i] = im[j]
			im[j] = ti0
	var sgn := -1.0 if inverse else 1.0
	var half := 1
	while half < n:
		var step := n / (half * 2)
		var k := 0
		while k < n:
			for j in half:
				var wr := cs[j * step]
				var wi := sn[j * step] * sgn
				var a := k + j
				var b := a + half
				var br := re[b]
				var bi := im[b]
				var tr := br * wr - bi * wi
				var ti := br * wi + bi * wr
				var ar := re[a]
				var ai := im[a]
				re[b] = ar - tr
				im[b] = ai - ti
				re[a] = ar + tr
				im[a] = ai + ti
			k += half * 2
		half *= 2
	if inverse:
		for i in n:
			re[i] /= n
			im[i] /= n
	return [re, im]
