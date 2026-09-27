extends RefCounted
## Camera heave measurements (PB-08, PB-08b): what the eye perceives, i.e.
## world metres divided by the world_scale of that tick, in cm.
##   var hm := HM.new()
##   fx.on_tick = func(_t, f): hm.push(f.player)
##   hm.max_cam_d2(), hm.band_bob(i0, i1), ...

const DT := 1.0 / 72.0

var cam := PackedFloat64Array()
var body := PackedFloat64Array()
var off := PackedFloat64Array()
var ws := PackedFloat64Array()
var flying := PackedByteArray()
var clamp_hits := 0
var gain_min := 1.0
## Largest |offset| / its limit over the run.
var max_off_fraction := 0.0
## The last onset-to-onset interval on each tick (s): the repetition
## period the wingbeat metric fits at (independent of the smoother).
var period := PackedFloat64Array()
var _since := 100.0
var _rep := 1.0


func push(p: PlayerBird) -> void:
	cam.append(p.camera.global_position.y)
	body.append(p.model.position.y)
	off.append(p.heave_offset())
	ws.append(maxf(p.origin.world_scale, 1e-4))
	flying.append(1 if p.mode == PlayerBird.Mode.FLYING else 0)
	gain_min = minf(gain_min, p.heave.gain)
	var ws_: WingState = p.wing_state()
	_since += DT
	if (ws_.onset_l or ws_.onset_r) and _since >= 0.25:
		if _since <= 2.2:
			_rep = _since
		_since = 0.0
	period.append(_rep)
	var lim := p.model.params.span * p.tuning.heave_clamp_spans
	max_off_fraction = maxf(max_off_fraction, absf(p.heave_offset()) / lim)
	if absf(absf(p.heave_offset()) - lim) < 1e-6 * maxf(lim, 1.0):
		clamp_hits += 1


func size() -> int:
	return cam.size()


## Largest per-tick change of the camera's vertical velocity (|second
## difference| of camera y), perceived cm. A smooth view changes it by a
## fraction of a cm per tick; a one-frame hitch shows up as the hitch size.
func max_d2(ys: PackedFloat64Array, i0 := 1, i1 := -1) -> float:
	var hi := ys.size() - 1 if i1 < 0 else mini(i1, ys.size() - 1)
	var m := 0.0
	for i in range(maxi(i0, 1), hi):
		if flying[i - 1] == 0 or flying[i] == 0 or flying[i + 1] == 0:
			continue
		m = maxf(m, absf(ys[i + 1] - 2.0 * ys[i] + ys[i - 1]) / ws[i] * 100.0)
	return m


func max_cam_d2(i0 := 1, i1 := -1) -> float:
	return max_d2(cam, i0, i1)


func max_body_d2(i0 := 1, i1 := -1) -> float:
	return max_d2(body, i0, i1)


## Where the camera's largest second difference is: [tick, cm].
func worst_cam_d2_at() -> Array:
	var m := 0.0
	var at := -1
	for i in range(1, cam.size() - 1):
		if flying[i - 1] == 0 or flying[i] == 0 or flying[i + 1] == 0:
			continue
		var d := absf(cam[i + 1] - 2.0 * cam[i] + cam[i - 1]) / ws[i] * 100.0
		if d > m:
			m = d
			at = i
	return [at, m]


## Largest per-tick change of the heave offset itself, perceived cm.
func max_off_step(i0 := 1) -> float:
	var m := 0.0
	for i in range(maxi(i0, 1), off.size()):
		if flying[i] == 0 or flying[i - 1] == 0:
			continue
		m = maxf(m, absf(off[i] - off[i - 1]) / ws[i] * 100.0)
	return m


## Wingbeat bob: half peak-to-peak of y minus its centred 1 s moving
## average over [i0, i1), perceived cm (the flight path is removed).
func ripple(ys: PackedFloat64Array, i0: int, i1: int) -> float:
	var n := 36
	var lo := INF
	var hi := -INF
	for i in range(maxi(i0, n), mini(i1, ys.size() - n)):
		var m := 0.0
		for k in range(-n, n + 1):
			m += ys[i + k]
		m /= 2 * n + 1
		var r := (ys[i] - m) / ws[i]
		lo = minf(lo, r)
		hi = maxf(hi, r)
	return 0.5 * (hi - lo) * 100.0 if hi > lo else 0.0


## RMS of the wingbeat-band vertical acceleration (second difference minus
## its centred 1 s mean), perceived m/s^2, over [i0, i1).
func band_acc(ys: PackedFloat64Array, i0: int, i1: int) -> float:
	var acc := PackedFloat64Array()
	acc.resize(ys.size())
	for i in range(1, ys.size() - 1):
		acc[i] = (ys[i + 1] - 2.0 * ys[i] + ys[i - 1]) / (DT * DT) / ws[i]
	var n := 36
	var s := 0.0
	var c := 0
	for i in range(maxi(i0, n + 1), mini(i1, ys.size() - n - 1)):
		var m := 0.0
		for k in range(-n, n + 1):
			m += acc[i + k]
		m /= 2 * n + 1
		s += (acc[i] - m) * (acc[i] - m)
		c += 1
	return sqrt(s / maxf(c, 1))


## Wingbeat-band vertical acceleration over sliding windows (the round-2
## verifier's measure): per window the RMS of (second difference of y minus
## its centred 1 s mean), perceived m/s^2, for the camera and the body;
## windows must be flying and the body's band RMS above min_body.
## Returns {worst: largest camera / body ratio, over_11: share of windows
## above 1.1 x, over_15: share above 1.5 x, cam: mean camera RMS, body: mean
## body RMS, n: windows}. Prefix sums: O(n) per signal.
func band_windows(win := 3.0, step := 0.5, min_body := 0.3) -> Dictionary:
	var pc := _band_prefix(cam)
	var pb := _band_prefix(body)
	var n := int(win / DT)
	var st := int(step / DT)
	var out := {"worst": 0.0, "over_11": 0.0, "over_15": 0.0, "cam": 0.0, "body": 0.0, "n": 0}
	var cnt := 0
	var o11 := 0
	var o15 := 0
	var i := 72
	while i + n < cam.size() - 72:
		var ok := true
		for j in range(i, i + n, 6):
			if flying[j] == 0:
				ok = false
				break
		if ok:
			var c := _band_rms(pc, i, i + n)
			var b := _band_rms(pb, i, i + n)
			if b > min_body:
				cnt += 1
				out["cam"] += c
				out["body"] += b
				out["worst"] = maxf(out["worst"], c / b)
				if c > 1.1 * b:
					o11 += 1
				if c > 1.5 * b:
					o15 += 1
		i += st
	var d := maxf(cnt, 1)
	out["cam"] /= d
	out["body"] /= d
	out["over_11"] = o11 / d
	out["over_15"] = o15 / d
	out["n"] = cnt
	return out


## The same windows as a series for plots: [window centres (s), camera /
## body band-RMS ratios].
func band_window_series(win := 3.0, step := 0.5, min_body := 0.3) -> Array:
	var pc := _band_prefix(cam)
	var pb := _band_prefix(body)
	var n := int(win / DT)
	var st := int(step / DT)
	var ts := PackedFloat64Array()
	var rs := PackedFloat64Array()
	var i := 72
	while i + n < cam.size() - 72:
		var ok := true
		for j in range(i, i + n, 6):
			if flying[j] == 0:
				ok = false
				break
		if ok:
			var b := _band_rms(pb, i, i + n)
			if b > min_body:
				ts.append((i + 0.5 * n) * DT)
				rs.append(_band_rms(pc, i, i + n) / b)
		i += st
	return [ts, rs]


## Prefix sums of the squared band acceleration (acc minus its centred
## 73-tick mean), perceived.
func _band_prefix(ys: PackedFloat64Array) -> PackedFloat64Array:
	var m := ys.size()
	var acc := PackedFloat64Array()
	acc.resize(m)
	for i in range(1, m - 1):
		acc[i] = (ys[i + 1] - 2.0 * ys[i] + ys[i - 1]) / (DT * DT) / ws[i]
	var pre := PackedFloat64Array()
	pre.resize(m + 1)
	for i in m:
		pre[i + 1] = pre[i] + acc[i]
	var p2 := PackedFloat64Array()
	p2.resize(m + 1)
	for i in m:
		var d2 := 0.0
		if i >= 37 and i < m - 37:
			var mean := (pre[i + 37] - pre[i - 36]) / 73.0
			d2 = (acc[i] - mean) * (acc[i] - mean)
		p2[i + 1] = p2[i] + d2
	return p2


func _band_rms(p2: PackedFloat64Array, i0: int, i1: int) -> float:
	var m := p2.size() - 1
	var a := maxi(i0, 37)
	var b := mini(i1, m - 37)
	if b <= a:
		return 0.0
	return sqrt((p2[b] - p2[a]) / (b - a))


## Fraction of the flying ticks the offset sat at its clamp.
func clamp_fraction() -> float:
	var n := 0
	for f in flying:
		n += f
	return float(clamp_hits) / maxf(n, 1)


## Wingbeat content of ys over [i0, i1), perceived cm: least-squares fit of
## a cubic flight path plus the stroke harmonics k = 1..3 (period T); the
## result is the largest |harmonic part| over the window. The cubic takes
## the flight path (glide, climb, a burst's S-curve), the harmonics take
## the wingbeat, so this separates the two where a moving average cannot.
func wingbeat(ys: PackedFloat64Array, i0: int, i1: int, period: float) -> float:
	var a := maxi(i0, 0)
	var b := mini(i1, ys.size())
	var n := b - a
	var m := 10
	if n < 2 * m:
		return 0.0
	# Normal equations (m x m).
	var ata := PackedFloat64Array()
	ata.resize(m * m)
	var aty := PackedFloat64Array()
	aty.resize(m)
	var row := PackedFloat64Array()
	row.resize(m)
	var t0 := a * DT
	var span := (n - 1) * DT
	for i in range(a, b):
		_row(row, i * DT, t0, span, period)
		var y := ys[i] / ws[i]
		for r in m:
			aty[r] += row[r] * y
			for c in m:
				ata[r * m + c] += row[r] * row[c]
	var x := _solve(ata, aty, m)
	var hi := 0.0
	for i in range(a, b):
		_row(row, i * DT, t0, span, period)
		var h := 0.0
		for r in range(4, m):
			h += row[r] * x[r]
		hi = maxf(hi, absf(h))
	return hi * 100.0


static func _row(row: PackedFloat64Array, t: float, t0: float, span: float, period: float) -> void:
	var u := 2.0 * (t - t0) / maxf(span, 1e-6) - 1.0
	row[0] = 1.0
	row[1] = u
	row[2] = u * u
	row[3] = u * u * u
	var om := TAU / period
	for k in range(1, 4):
		row[2 + 2 * k] = cos(k * om * t)
		row[3 + 2 * k] = sin(k * om * t)


## Gaussian elimination with partial pivoting (small dense systems).
static func _solve(a: PackedFloat64Array, y: PackedFloat64Array, m: int) -> PackedFloat64Array:
	var mat := a.duplicate()
	var v := y.duplicate()
	for c in m:
		var p := c
		for r in range(c + 1, m):
			if absf(mat[r * m + c]) > absf(mat[p * m + c]):
				p = r
		if p != c:
			for k in m:
				var tmp := mat[c * m + k]
				mat[c * m + k] = mat[p * m + k]
				mat[p * m + k] = tmp
			var tv := v[c]
			v[c] = v[p]
			v[p] = tv
		var d := mat[c * m + c]
		if absf(d) < 1e-12:
			continue
		for r in range(c + 1, m):
			var f := mat[r * m + c] / d
			for k in range(c, m):
				mat[r * m + k] -= f * mat[c * m + k]
			v[r] -= f * v[c]
	var x := PackedFloat64Array()
	x.resize(m)
	for c in range(m - 1, -1, -1):
		var s := v[c]
		for k in range(c + 1, m):
			s -= mat[c * m + k] * x[k]
		var d := mat[c * m + c]
		x[c] = s / d if absf(d) > 1e-12 else 0.0
	return x


## Wingbeat over sliding windows (win s, step s) at the reference period of
## each window's centre, flying ticks only: [mean cam, mean raw, worst
## cam / raw ratio over windows whose raw wingbeat is at least min_cm].
func wingbeat_sweep(win: float, step: float, min_cm := 5.0) -> Array:
	var n := int(round(win / DT))
	var st := int(round(step / DT))
	var sc := 0.0
	var sr := 0.0
	var cnt := 0
	var worst := 0.0
	var i := 0
	while i + n <= cam.size():
		var ok := true
		for j in range(i, i + n, 6):
			if flying[j] == 0:
				ok = false
				break
		if ok:
			var per := period[i + n / 2]
			var c := wingbeat(cam, i, i + n, per)
			var r := wingbeat(body, i, i + n, per)
			sc += c
			sr += r
			cnt += 1
			if r >= min_cm:
				worst = maxf(worst, c / r)
		i += st
	return [sc / maxf(cnt, 1), sr / maxf(cnt, 1), worst, cnt]


## Amplitude (perceived cm) of the tone at `freq` Hz in ys over [i0, i1):
## least squares with a cubic path, the stroke harmonics k = 1..3 of
## `stroke_period` as nuisance terms, and cos / sin at `freq`.
func tone(ys: PackedFloat64Array, i0: int, i1: int, freq: float, stroke_period: float) -> float:
	var a := maxi(i0, 0)
	var b := mini(i1, ys.size())
	var m := 12
	var ata := PackedFloat64Array()
	ata.resize(m * m)
	var aty := PackedFloat64Array()
	aty.resize(m)
	var row := PackedFloat64Array()
	row.resize(m)
	var t0 := a * DT
	var span := (b - a - 1) * DT
	for i in range(a, b):
		var t := i * DT
		_row(row, t, t0, span, stroke_period)
		row[10] = cos(TAU * freq * t)
		row[11] = sin(TAU * freq * t)
		var y := ys[i] / ws[i]
		for r in m:
			aty[r] += row[r] * y
			for c in m:
				ata[r * m + c] += row[r] * row[c]
	var x := _solve(ata, aty, m)
	return sqrt(x[10] * x[10] + x[11] * x[11]) * 100.0
