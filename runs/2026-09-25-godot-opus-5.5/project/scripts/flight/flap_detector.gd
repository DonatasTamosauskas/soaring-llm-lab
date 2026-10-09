class_name FlapDetector
extends RefCounted
## Credited-stroke flap detection for one wing (FLIGHT_SPEC §6).
##
## Turns hand motion into flap effort only for REAL strokes: a downstroke is
## paid for by the arc of the upstroke before it ("arc bank"), and small arcs
## earn little credit. Shakes, tremor and waggles therefore produce nothing
## (the anti-cheese requirement), while a slow recovery followed by a hard
## power stroke still counts. Velocity is measured relative to the neck, so
## crouching, jumping and walking cancel.

const W_UP := 0.15          # rad/s: slower than this is not an upstroke
const W_DN := 0.9           # rad/s: faster than this is a downstroke (~0.5 m/s hand)
const BANK_MAX := 2.618     # 150 deg of stored arc
const BANK_LEAK_TAU := 8.0  # s, hygiene leak while idle
const ONSET_LEVEL := 0.25
const EFFORT_CAP := 1.3
const VEL_HZ := 8.0         # 2-pole velocity low-pass

## Calibrated per-player stroke scale (WingCalibration).
var omega_full := 4.5
var arc_full := 0.611
var seated := false
## Size scalar (FlightParams.x): small birds reward quick short strokes.
var size_x := 0.3

# --- outputs (valid after step) ---
var flap := 0.0            # 0..1.3 credited downstroke effort
var up := 0.0              # 0..1 gated upstroke effort
var omega := 0.0           # rad/s along the wing normal, + = downstroke
var onset := false         # a credited downstroke started this tick
var onset_strength := 0.0
var credit := 0.0
var up_arc := 0.0
var bank := 0.0
var period := 1.0          # s between onsets (EMA), 0.3..1.5
var phase := 0.0           # 0 top of stroke, 0.5 bottom
var peak_omega := 0.0      # peak omega of the last downstroke (calibration)
var last_up_arc := 0.0     # arc of the last completed upstroke (calibration)

enum { IDLE, UP, DOWN }
var state := IDLE

var _v1 := Vector3.ZERO
var _v2 := Vector3.ZERO
var _rel_prev := Vector3.ZERO
var _has_prev := false
var _t := 0.0
var _last_onset_t := -100.0
var _gate_t := -100.0       # time of the last downstroke with credit >= 0.5
var _onset_done := false
var _half_t := 0.0          # time since the current half-stroke began
var _peak := 0.0
var _up_start_t := -100.0
var _last_up_dur := 0.5


func reset() -> void:
	flap = 0.0
	up = 0.0
	omega = 0.0
	onset = false
	onset_strength = 0.0
	credit = 0.0
	up_arc = 0.0
	bank = 0.0
	period = 1.0
	phase = 0.0
	state = IDLE
	_v1 = Vector3.ZERO
	_v2 = Vector3.ZERO
	_has_prev = false
	_t = 0.0
	_last_onset_t = -100.0
	_gate_t = -100.0
	_onset_done = false
	_half_t = 0.0
	_peak = 0.0
	_up_start_t = -100.0
	_last_up_dur = 0.5


func xn() -> float:
	var xs := FlightParams.size_x_for_species(&"sparrow")
	return clampf((size_x - xs) / maxf(1.0 - xs, 1e-6), 0.0, 1.0)


func omega_full_x() -> float:
	return omega_full * lerpf(1.10, 0.85, xn()) * (0.75 if seated else 1.0)


## Minimum credited up-arc. 16 deg at every size (spec: lerp(10, 15)): an
## 8 cm hand waggle at 4 Hz is a 15.9 deg arc and must earn nothing (F9),
## while the sparrow's quick +-15 deg strokes (30 deg arc) keep full credit.
func arc_min_x() -> float:
	return deg_to_rad(16.0) * (0.75 if seated else 1.0)


func arc_full_x() -> float:
	return arc_full * lerpf(0.8, 1.2, xn()) * (0.75 if seated else 1.0)


## Forget the previous position (tracking loss, respawn, recenter): the next
## sample starts a fresh velocity estimate instead of a huge jump.
func drop_history() -> void:
	_has_prev = false
	_v1 = Vector3.ZERO
	_v2 = Vector3.ZERO


## One tick. rel = hand - neck (tracking space, m); n0 = the wing's up-normal
## with incidence clamped to +-20 deg; ext = extension; valid = hand tracked;
## sample_dt = the seconds the pose advanced since the last sample when the
## source knows it (PoseFrame.pose_dt: 0 = the same pose again, -1 = dt).
## Velocity, arcs and the arc bank use the pose's own interval (fix round
## 5): an engine frame hitch shows a pose jump by the whole hitch and then
## repeats it; round 4 divided the jump by one tick and a slow arm sweep read
## as a 7x faster downstroke (4 spurious flaps in 20 s with a 56 ms+ hitch
## every 0.5 s).
func step(rel: Vector3, n0: Vector3, l_arm: float, ext: float, valid: bool, dt: float, sample_dt := -1.0) -> void:
	_t += dt
	onset = false
	if dt <= 0.0:
		return
	if not valid:
		# Hold: velocity 0, so no flap; the banked arc is forfeited.
		_v1 = Vector3.ZERO
		_v2 = Vector3.ZERO
		_has_prev = false
		omega = 0.0
		flap = 0.0
		up = 0.0
		bank = 0.0
		_advance_phase(dt)
		return
	if sample_dt == 0.0 and _has_prev:
		# The same pose as the last tick (a hitch's repeat): no new motion to
		# measure. The stroke carries on as measured when the pose arrived
		# (its arc covered the whole interval then); the phase clock runs.
		_advance_phase(dt)
		return
	# vdt: the time this sample's motion took.
	var vdt := sample_dt if sample_dt > 0.0 else dt
	var v_raw := Vector3.ZERO
	if _has_prev:
		v_raw = (rel - _rel_prev) / vdt
	_rel_prev = rel
	_has_prev = true
	var k8 := 1.0 - exp(-TAU * VEL_HZ * vdt)
	_v1 += (v_raw - _v1) * k8
	_v2 += (_v1 - _v2) * k8
	omega = -_v2.dot(n0) / maxf(l_arm, 0.1)

	var wf := omega_full_x()
	flap = 0.0
	up = 0.0
	if omega < -W_UP:
		if state != UP:
			if state == DOWN:
				peak_omega = _peak
			state = UP
			up_arc = 0.0
			_onset_done = false
			_half_t = 0.0
			_up_start_t = _t
		up_arc += -omega * vdt
		bank = minf(bank + (-omega * vdt), BANK_MAX)
		# Upstroke force only as the continuation of a credited rhythm.
		if _t - _gate_t <= 1.5:
			up = clampf(-omega / wf, 0.0, 1.0)
	elif omega > W_DN:
		if state == UP:
			last_up_arc = up_arc
			_last_up_dur = _t - _up_start_t
			state = DOWN
			credit = FlightMath.sstep(arc_min_x(), arc_full_x(), up_arc)
			_half_t = 0.0
			_peak = 0.0
		if state == DOWN:
			var d := omega * vdt
			var use := minf(d, bank)
			bank -= use
			flap = minf(omega * (use / d) * credit / wf, EFFORT_CAP)
			_peak = maxf(_peak, omega)
			if credit >= 0.5:
				_gate_t = _t
			if not _onset_done and flap > ONSET_LEVEL:
				_onset_done = true
				onset = true
				onset_strength = credit
				var since := _t - _last_onset_t
				if since <= 3.0:
					period += (clampf(since, 0.3, 1.5) - period) * 0.5
				else:
					# First stroke after a pause: the upstroke took about half a
					# cycle, a far better seed than the decayed idle value.
					period = clampf(2.0 * _last_up_dur, 0.3, 1.5)
				_last_onset_t = _t
	else:
		bank *= exp(-dt / BANK_LEAK_TAU)
	if ext < 0.3:
		bank = 0.0
	if _t - _last_onset_t > 1.5:
		period += (0.3 - period) * FlightMath.lp_k(dt, 0.5)
	period = clampf(period, 0.3, 1.5)
	_advance_phase(dt)


func _advance_phase(dt: float) -> void:
	_half_t += dt
	var half := 0.5 * period
	var f := clampf(_half_t / maxf(half, 1e-3), 0.0, 1.0)
	match state:
		DOWN:
			phase = 0.5 * f
		UP:
			phase = 0.5 + 0.5 * minf(f, 0.999)
		_:
			phase = 0.0


# ---------------------------------------------------------------------------
# Reference stroke (§6.4): arm elevation 45 deg * cos(2 pi 1 Hz t), flat
# wrists, straight arm, through this detector at size x. Cached per x.

static var _ref_cache := {}


## Vector2(mean flap, mean up) of the reference stroke at size x (standing,
## default calibration: the normalisation must not undo personalisation).
static func reference_means(x: float) -> Vector2:
	var t := reference_table(x)
	return t["means"]


## Mean net effort of the reference stroke for a given up_gain.
static func reference_effort(x: float, up_gain: float) -> float:
	var m := reference_means(x)
	return m.x + up_gain * m.y


## One steady-state cycle of the reference stroke through the detector,
## sampled at 72 Hz: {"flap": PackedFloat32Array, "up": ..., "means": Vector2}.
## WingState.set_commands samples it so NPC and test flapping produce exactly
## the reference forces.
static func reference_table(x: float) -> Dictionary:
	var key := snappedf(x, 0.001)
	if _ref_cache.has(key):
		return _ref_cache[key]
	var tab := stroke_table(x, deg_to_rad(45.0), 1.0, 0.5, false, 72.0)
	_ref_cache[key] = tab
	return tab


## Runs a synthetic stroke (arm elevation amp*cos, duty = downstroke share of
## the cycle) through a fresh detector at `rate` Hz and returns the last
## whole cycle plus its means (averaged over 4 cycles after 4 s of warm-up).
static func stroke_table(x: float, amp: float, hz: float, duty: float, p_seated: bool, rate: float) -> Dictionary:
	var det := FlapDetector.new()
	det.size_x = x
	det.seated = p_seated
	var dt := 1.0 / rate
	var l_arm := 0.5775
	var warm := int(ceil(4.0 * rate))
	var cyc := 1.0 / hz
	var n_meas := int(round(4.0 * cyc * rate))
	var n_cycle := int(round(cyc * rate))
	var sum := Vector2.ZERO
	var fl := PackedFloat32Array()
	var ups := PackedFloat32Array()
	for i in warm + n_meas:
		var t := i * dt
		var d := stroke_elevation(t, amp, hz, duty)
		var rel := Vector3(l_arm * cos(d), l_arm * sin(d), 0.0)
		var n0 := Vector3(-sin(d), cos(d), 0.0)
		det.step(rel, n0, l_arm, 1.0, true, dt)
		if i >= warm:
			sum += Vector2(det.flap, det.up)
			if i >= warm + n_meas - n_cycle:
				fl.append(det.flap)
				ups.append(det.up)
	return {"flap": fl, "up": ups, "means": sum / float(maxi(n_meas, 1))}


## Arm elevation of a stroke: top at phase 0, bottom at phase `duty`.
static func stroke_elevation(t: float, amp: float, hz: float, duty: float) -> float:
	var ph := fposmod(t * hz, 1.0)
	var d := clampf(duty, 0.05, 0.95)
	if ph < d:
		return amp * cos(PI * ph / d)
	return amp * cos(PI * (1.0 + (ph - d) / (1.0 - d)))
