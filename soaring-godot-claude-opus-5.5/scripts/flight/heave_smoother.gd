class_name HeaveSmoother
extends RefCounted
## Camera vertical smoothing (FLIGHT_SPEC §11.3, §19 H-1 / H-3). Flapping at
## ~1 Hz moves a small bird's body by up to a span per stroke, and the
## perceived bob scales with 1 / world_scale. The camera removes the
## WINGBEAT of STEADY flapping from the body's motion and nothing else:
##
##   camera y = body y + offset,   offset = sum_k A_k(t) / (k w)^2
##
## A_k is the k-th harmonic (k = 1..3) of the body's vertical acceleration
## at the stroke frequency w, fitted on line by an adaptive Fourier linear
## combiner (LMS on cos / sin references plus a DC weight that absorbs the
## flight's own acceleration). A steady harmonic's displacement is minus its
## acceleration over (k w)^2, so subtracting it leaves the flight path; the
## path itself (glides, climbs, dives, a burst's S-curve) passes 1:1 and
## nothing is ever extrapolated.
##
## Do no harm (fix round 2). A fitted template predicts the NEXT stroke from
## the last ones. When the rhythm breaks (a pause, a tempo change, a stroke
## that stops half way, irregular human flapping) the template is wrong and
## the camera gains motion the body never had: round 1 bobbed a pigeon's view
## 138 cm where the body bobbed 60 cm. So the correction is applied only
## where it is known to help, and every gate that can close without warning
## closes at the earliest moment the break is observable:
## - rhythm: it opens after three regular onset intervals (within 30 %) on
##   an onset that lands within 12 % of the rhythm, and closes when the
##   rhythm breaks or the next onset is overdue (1.2 periods). Flap-glide
##   bursts, isolated strokes and irregular flapping are left untouched: a
##   causal filter cannot know a burst's first stroke, and guessing costs
##   more than it saves (measured, FLIGHT.md §2);
## - phase: at every onset the template's phase is compared with where
##   onsets usually fall; a template off by e removes only cos(e) of the
##   wingbeat and adds the rest, so that stroke's gain follows cos(e)
##   (zero beyond 50 deg), before the stroke has done any harm;
## - arms: when the arms stop (the glide after the last upstroke) the
##   wingbeat stops with them, and a stroke that stops half way carries only
##   part of one: the correction follows the arms' stroke amplitude (radius
##   of their rate / angle phase portrait), and as they come to rest the
##   template's phase stops advancing, so the view keeps a still offset that
##   then fades slowly (fading an oscillating template fast in a quiet glide
##   was itself the largest motion left: a novice eagle's window at 1.5 x).
##   Fix round 4: the amplitude gain closes at the rest rate too, and the
##   phase stops outright once the arms rest (their amplitude radius keeps
##   an arm-angle term that stays up while an arm is held at an extreme);
## - benefit: the least-squares gain of the template against the body's
##   high-passed acceleration over the last period (how much of the removed
##   motion was really there), faded in between 0.3 and 0.9. On the recorded
##   flights the gates above already cover every misfit and removing this one
##   changes nothing (FLIGHT.md §2); it stays as the layer for a steady arm
##   rhythm whose body motion is not wingbeat;
## - every gain moves through jerk-limited critically damped eases (a gate
##   switch never steps the view's acceleration), slow to open and fast to
##   close; the template is held below its limit by a smooth gain instead of
##   a clamp knee; smoothing turns off (perched, grounded) through an ease.
## Measured against the round-2 verifier's human-flapping probe and PB-08b
## / PB-08c; the design study is in FLIGHT.md §2.
##
## Input is the model's vertical velocity: physical head motion never
## touches it, so the player's own head moves the view 1:1.

const K := 3                   # harmonics fitted
## Reference period range (s): onset to onset. An interval longer than
## T_MAX is a pause, not a stroke.
const T_MIN := 0.3
const T_MAX := 1.6
## A second onset sooner than this is the other wing of the same stroke
## (WingInput pairs them within 60 ms).
const DEBOUNCE := 0.25
## Rhythm: intervals within RHYTHM_TOL of the previous one (or of the
## rhythm) count as regular; RHYTHM_NEED of them in a row, and an onset
## within RHYTHM_OPEN of the rhythm, open the correction.
const RHYTHM_TOL := 0.3
const RHYTHM_OPEN := 0.12
const RHYTHM_NEED := 3
## The next onset is overdue after this many periods: strokes stopped.
const ACTIVE_FOR := 1.2
## Phase gate: the onset phase is a running circular mean (weight per
## onset); the per-stroke gain is (cos e - cos PH_ZERO) / (1 - cos PH_ZERO).
const PH_WEIGHT := 0.3
const PH_ZERO := deg_to_rad(50.0)
## The reference period follows the rhythm through a critically damped
## ease (rad/s): its RATE must be continuous too, since the offset scales
## with 1 / w^2 (a rate step is a velocity step in the view).
const W_PERIOD := 3.0
## LMS time constants (s): harmonics 2 / mu, DC 1 / mu_dc.
const TAU_H := 1.0
const TAU_DC := 0.5
## Weight low-pass (rad/s, critically damped).
const W_SMOOTH := 6.28
## Strokes stopped: the harmonic weights leak away (a later rhythm starts
## at an unrelated phase).
const TAU_LEAK := 0.5
## Benefit: least-squares gain of the template's acceleration against the
## body's acceleration high-passed at HP_W (rad/s), averaged over one
## period; the correction fades in between these.
const HP_W := 2.0
const G_LO := 0.3
const G_HI := 0.9
## Arms: stroke-rate activity (rad/s, low-passed over ARM_TAU) below
## ARM_REST of its running level means the arms rest; the stroke amplitude
## (phase-portrait radius over AMP_TAU) ramps the correction between
## AMP_LO and AMP_HI of its level. ARM_MIN: below this the arms are not
## stroking at all (the levels are not learned from it).
const ARM_TAU := 0.15
const ARM_REST := 0.5
const AMP_TAU := 0.1
const AMP_LO := 0.3
const AMP_HI := 0.9
## The template's phase rate follows the stroke amplitude between these
## shares of its level (a real stroke is well above PF_HI; resting arms
## freeze the phase), and the correction then closes at W_REST.
const PF_LO := 0.05
const PF_HI := 0.4
const W_REST := 3.0
const ARM_MIN := 1.0
const LEVEL_TAU := 2.0
## Gain eases (rad/s, critically damped): the rhythm gate opens slowly and
## closes fast; switching a correction of amplitude A within tau costs about
## A / tau^2 + 2 A w / tau of view acceleration. The gate's target passes a
## first-order filter first (JERK_K x the ease rate) so a switch never steps
## the offset's acceleration.
const W_OPEN := 2.5
const W_CLOSE := 10.0
const JERK_K := 1.5
const W_BENEFIT := 3.0
const W_AMP := 12.0
## An acceleration residual this large is a contact or a respawn, not a
## wingbeat (m/s^2): that tick does not train the fit.
const ACC_JUMP := 60.0
## Smoothing on / off ease (rad/s, critically damped).
const W_ONOFF := 12.0
## The template's peak is held below this share of the limit (smooth
## gain); the soft clamp is only a last-resort bound.
const GAIN_AT := 0.85
const GAIN_P := 6.0
const KNEE := 0.95

var offset := 0.0
var enabled := true
## Reference stroke period (s); continuous.
var period := 1.0
## Peak of the fitted wingbeat displacement (m), and the gains applied.
var amplitude := 0.0
var gain := 1.0
## Least-squares benefit of the template (1 = everything it removes was in
## the body's motion), and the combined gate (0..1) on the template.
var quality := 0.0
var gate := 0.0
## True while the rhythm gate is open.
var rhythm_open := false
## Fitted weights [dc, a1, b1, a2, b2, a3, b3] (m/s^2); smoothed copies and
## their rates (the offset is built from ws).
var w := PackedFloat64Array()
var ws := PackedFloat64Array()
var wv := PackedFloat64Array()
var _theta := 0.0
var _period_v := 0.0
var _period_t := 1.0
var _vy_prev := 0.0
var _have_prev := false
var _since := 100.0
var _last_iv := -1.0           # last onset interval inside the rhythm (-1: none)
var _regular := 0
var _ph_c := 1.0               # running onset phase (cos, sin)
var _ph_s := 0.0
var _ph_n := 0
var _ph_gain := 0.0
var _on := 1.0
var _on_v := 0.0
var _hp := 0.0                 # low-passed body acceleration (for the high-pass)
var _e_bp := 0.0               # mean body x template acceleration
var _e_pp := 0.0               # mean template acceleration squared
var _q := 0.0                  # eased benefit gain
var _q_v := 0.0
var _act_f := 0.0              # rhythm gate: filtered target, eased value, rate
var _act := 0.0
var _act_v := 0.0
var _arm_act := 0.0            # arm stroke-rate activity and its level
var _arm_lvl := 0.0
var _arm_int := 0.0            # leaky integral of the stroke rate (arm angle)
var _amp_r := 0.0              # arm stroke amplitude and its level
var _amp_lvl := 0.0
var _amp := 0.0                # eased amplitude gain
var _amp_v := 0.0
var _pf := 1.0                 # eased phase-rate factor (arms at rest: 0)
var _pf_v := 0.0


func _init() -> void:
	w.resize(1 + 2 * K)
	ws.resize(1 + 2 * K)
	wv.resize(1 + 2 * K)


## Forget everything (respawn, start_flying): the next flight fits afresh.
## The reference period is kept (the player's rhythm).
func reset() -> void:
	w.fill(0.0)
	ws.fill(0.0)
	wv.fill(0.0)
	offset = 0.0
	amplitude = 0.0
	quality = 0.0
	gate = 0.0
	rhythm_open = false
	_have_prev = false
	_since = 100.0
	_last_iv = -1.0
	_regular = 0
	_ph_c = 1.0
	_ph_s = 0.0
	_ph_n = 0
	_ph_gain = 0.0
	_on = 1.0 if enabled else 0.0
	_on_v = 0.0
	_hp = 0.0
	_e_bp = 0.0
	_e_pp = 0.0
	_q = 0.0
	_q_v = 0.0
	_act_f = 0.0
	_act = 0.0
	_act_v = 0.0
	_arm_act = 0.0
	_arm_int = 0.0
	_amp_r = 0.0
	_amp = 0.0
	_amp_v = 0.0
	_pf = 1.0
	_pf_v = 0.0


## Push this tick's vertical flight speed; returns the camera offset
## (camera y minus body y). `p_period`: the detector's stroke period (seeds
## a new rhythm); `onset`: a credited stroke started this tick; `limit`: the
## offset bound; `arm_rate`: the arms' mean stroke rate (rad/s, + = down;
## WingState.omega_l / omega_r). NAN: no arm information (synthetic input),
## the arm gates stay open.
func update(vy: float, dt: float, p_period: float, onset: bool, limit: float, arm_rate := NAN) -> float:
	if not is_finite(vy) or not is_finite(dt) or dt <= 0.0:
		return offset
	# A frame hitch never counts for more than 0.1 s here.
	dt = minf(dt, 0.1)
	_since += dt
	if onset and _since >= DEBOUNCE:
		_on_onset(_since, p_period)
		_since = 0.0
	_period_v += (W_PERIOD * W_PERIOD * (_period_t - period) - 2.0 * W_PERIOD * _period_v) * dt
	period = clampf(period + _period_v * dt, T_MIN, T_MAX)
	var om := TAU / period
	_on_v = _ease_rate(_on, _on_v, 1.0 if enabled else 0.0, W_ONOFF, dt)
	_on = clampf(_on + _on_v * dt, 0.0, 1.0)
	var acc := 0.0
	var acc_ok := false
	if _have_prev:
		acc = (vy - _vy_prev) / dt
		acc_ok = is_finite(acc)
	_vy_prev = vy
	_have_prev = true
	var arm_ok := true
	var amp_t := 1.0
	var pf_t := 1.0
	if is_finite(arm_rate):
		arm_ok = _arms(arm_rate, om, dt)
		var ratio := _amp_r / maxf(_amp_lvl, 1e-3)
		amp_t = _smooth01((ratio - AMP_LO) / (AMP_HI - AMP_LO))
		# Arms at rest: the template's phase stops (fix round 4). The
		# amplitude radius keeps an arm-angle term, which stays high while
		# an arm is held at the top of its last upstroke (the leaky angle
		# decays over a second): the phase ran on through the next predicted
		# bob and moved a novice eagle's view 2 x its body in a quiet glide.
		pf_t = _smooth01((ratio - PF_LO) / (PF_HI - PF_LO)) if arm_ok else 0.0
	_pf_v = _ease_rate(_pf, _pf_v, pf_t, W_AMP, dt)
	_pf = clampf(_pf + _pf_v * dt, 0.0, 1.0)
	var overdue := _since > ACTIVE_FOR * period
	if overdue:
		rhythm_open = false
	var active := rhythm_open and arm_ok and _ph_gain > 0.0
	var w_act := W_OPEN if active else W_CLOSE
	if not active and not arm_ok:
		# Arms at rest: the template is frozen (its phase stopped with the
		# arms), so it can fade slowly without moving the view.
		w_act = W_REST
	var target := _ph_gain if active else 0.0
	_act_f += (target - _act_f) * (1.0 - exp(-dt * JERK_K * w_act))
	_act_v += (w_act * w_act * (_act_f - _act) - 2.0 * w_act * _act_v) * dt
	_act = clampf(_act + _act_v * dt, 0.0, 1.0)
	if enabled:
		# The phase runs only while fitting (a paused fit keeps its shape)
		# and only as fast as the arms still stroke.
		_theta = fposmod(_theta + om * dt * _pf, TAU)
		if acc_ok:
			_fit(acc, dt)
		if overdue:
			var lk := exp(-dt / TAU_LEAK)
			for i in range(1, w.size()):
				w[i] *= lk
	else:
		# Not flying: the fit decays with the ease (a new flight starts over).
		var d := exp(-dt * W_ONOFF * 0.5)
		for i in w.size():
			w[i] *= d
	quality = _e_bp / _e_pp if _e_pp > 1e-4 else 0.0
	_q_v = _ease_rate(_q, _q_v, _smooth01((quality - G_LO) / (G_HI - G_LO)), W_BENEFIT, dt)
	_q = clampf(_q + _q_v * dt, 0.0, 1.0)
	# The amplitude gain opens fast but closes at the rest rate (fix round
	# 4): as the arm amplitude collapses the template's phase stops (pf, and
	# at rest outright), so what is left is a STILL offset, and fading that
	# slowly moves the view below the wingbeat band. Closed at W_AMP it faded
	# a 14 cm offset within 0.4 s after a novice eagle's last stroke ended at
	# level: a 3 s window at 2.1 x the body's motion (limit 1.5).
	_amp_v = _ease_rate(_amp, _amp_v, amp_t, W_AMP if amp_t > _amp else W_REST, dt)
	_amp = clampf(_amp + _amp_v * dt, 0.0, 1.0)
	for i in w.size():
		wv[i] += (W_SMOOTH * W_SMOOTH * (w[i] - ws[i]) - 2.0 * W_SMOOTH * wv[i]) * dt
		ws[i] += wv[i] * dt
	var off := 0.0
	amplitude = 0.0
	for k in range(1, K + 1):
		var kom2 := float(k * k) * om * om
		var a := ws[2 * k - 1]
		var b := ws[2 * k]
		off += (a * cos(k * _theta) + b * sin(k * _theta)) / kom2
		amplitude += sqrt(a * a + b * b) / kom2
	# A wingbeat bigger than the limit is cancelled only in part, by scaling
	# the whole template with a smooth gain: bending a fast-moving offset in
	# a clamp knee is itself a jolt (f'' x'^2), a scaled template is not.
	var lim := maxf(limit, 1e-4)
	gain = 1.0 / pow(1.0 + pow(amplitude / (GAIN_AT * lim), GAIN_P), 1.0 / GAIN_P)
	gate = _q * _act * _amp * _on
	offset = soft_clamp(off * gain * gate, lim)
	return offset


## A credited stroke onset `iv` seconds after the previous one: the rhythm
## (regular count, reference period, open / closed) and this stroke's phase
## gain.
func _on_onset(iv: float, p_period: float) -> void:
	var ref := _period_t
	var in_rhythm := iv <= T_MAX and ((_last_iv > 0.0 and absf(iv / _last_iv - 1.0) <= RHYTHM_TOL) \
		or (_last_iv > 0.0 and absf(iv / ref - 1.0) <= RHYTHM_TOL))
	_regular = _regular + 1 if in_rhythm else 0
	if iv <= T_MAX:
		if _regular >= 1:
			_period_t += (iv - _period_t) * 0.5
		elif _last_iv <= 0.0:
			_period_t = p_period if is_finite(p_period) else _period_t
		_last_iv = iv
	else:
		# A pause: the next interval starts a new rhythm.
		_last_iv = -1.0
		_period_t = p_period if is_finite(p_period) else _period_t
	_period_t = clampf(_period_t, T_MIN, T_MAX)
	# Phase: where the template stands at this onset against where onsets
	# usually fall (a running circular mean).
	var e := absf(wrapf(_theta - atan2(_ph_s, _ph_c), -PI, PI))
	_ph_gain = maxf(0.0, (cos(e) - cos(PH_ZERO)) / (1.0 - cos(PH_ZERO))) if _ph_n >= 2 else 0.0
	_ph_c += (cos(_theta) - _ph_c) * PH_WEIGHT
	_ph_s += (sin(_theta) - _ph_s) * PH_WEIGHT
	_ph_n += 1
	if _regular >= RHYTHM_NEED and absf(iv / ref - 1.0) <= RHYTHM_OPEN:
		rhythm_open = true
	if _regular < RHYTHM_NEED:
		rhythm_open = false


## LMS step on the harmonic references, and the benefit statistics of the
## template the view uses (the smoothed weights) against the body.
func _fit(acc: float, dt: float) -> void:
	var pred := w[0]
	var pred_s := 0.0
	for k in range(1, K + 1):
		var c := cos(k * _theta)
		var s := sin(k * _theta)
		pred += w[2 * k - 1] * c + w[2 * k] * s
		pred_s += ws[2 * k - 1] * c + ws[2 * k] * s
	var e := acc - pred
	if absf(e) >= ACC_JUMP:
		return
	var mu := 2.0 / TAU_H
	w[0] += e * dt / TAU_DC
	for k in range(1, K + 1):
		w[2 * k - 1] += mu * e * cos(k * _theta) * dt
		w[2 * k] += mu * e * sin(k * _theta) * dt
	var kq := 1.0 - exp(-dt / period)
	_hp += (acc - _hp) * (1.0 - exp(-dt * HP_W))
	var hb := acc - _hp
	_e_bp += (hb * pred_s - _e_bp) * kq
	_e_pp += (pred_s * pred_s - _e_pp) * kq


## The arms' stroke activity (rest detection) and stroke amplitude, from the
## mean stroke rate. Returns false while the arms rest.
func _arms(rate: float, om: float, dt: float) -> bool:
	var a := absf(rate)
	_arm_act += (a - _arm_act) * (1.0 - exp(-dt / ARM_TAU))
	if _arm_act > ARM_MIN:
		_arm_lvl += (_arm_act - _arm_lvl) * (1.0 - exp(-dt / LEVEL_TAU))
	# Amplitude: radius of the (rate, om x angle) phase portrait, which does
	# not dip at the stroke's turning points the way |rate| does.
	_arm_int += (rate - _arm_int) * dt
	var r := sqrt(rate * rate + om * om * _arm_int * _arm_int)
	_amp_r += (r - _amp_r) * (1.0 - exp(-dt / AMP_TAU))
	if _amp_r > ARM_MIN:
		_amp_lvl += (_amp_r - _amp_lvl) * (1.0 - exp(-dt / LEVEL_TAU))
	return _arm_act > ARM_REST * _arm_lvl


## Critically damped ease of `x` toward `target` at `wn` rad/s: the new
## rate (the caller integrates x with it and clamps x to 0..1).
static func _ease_rate(x: float, v: float, target: float, wn: float, dt: float) -> float:
	return v + (wn * wn * (target - x) - 2.0 * wn * v) * dt


## Quintic smoothstep on [0, 1] (zero slope and curvature at both ends).
static func _smooth01(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * t * (t * (6.0 * t - 15.0) + 10.0)


## Identity up to KNEE * lim, then a tanh knee that approaches lim with a
## continuous slope (a hard clamp would be a velocity kink in the view).
static func soft_clamp(x: float, lim: float) -> float:
	var k := KNEE * lim
	var ax := absf(x)
	if ax <= k:
		return x
	var r := lim - k
	return signf(x) * (k + r * tanh((ax - k) / r))
