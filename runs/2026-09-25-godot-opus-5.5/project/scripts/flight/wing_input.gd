class_name WingInput
extends RefCounted
## Poses -> WingState (FLIGHT_SPEC §5 and §6). Scale-free: every pose is in
## tracking space, real metres; world_scale never reaches this class.
##
## The body frame comes from the WINGS, not the head: forward is
## perpendicular to the left->right hand line (§5.2), so the player can look
## around freely while flying straight. Shoulders hang from a neck pivot
## below and behind the eyes (§5.3). Per wing: extension from reach, arm
## elevation and sweep (§5.5); dihedral (§5.6); wrist twist about the
## calibrated forearm axis by swing-twist decomposition, so raising, sweeping
## or bending the arm never reads as twist (§5.7); the wing's up-normal
## tilted by the twist is the flap force direction (§5.8, requirement 1);
## credited-stroke flap detection (§6). Symmetric twist is pitch (speed,
## balloon); antisymmetric twist and arm tilt are roll (§5.9).

const SIDE := [-1.0, 1.0]
const DEG := PI / 180.0

var calibration: WingCalibration
## Size scalar of the bird (FlightParams.x): the detector's effort scaling.
var size_x := 0.3044
## Dead-zone multiplier (novice x1.4, sim x0.8).
var deadzone_scale := 1.0
var wrist_sensitivity := 1.0
var invert_pitch := false
## Turn input shaping (playtest build #1): dead zone and full-deflection
## angles for the two turn gestures (one hand lower = arm, opposite wrist
## tilt = tilt), the curve exponent (>1: gentle near neutral, strong far
## out), and switches. PlayerBird sets them from Settings (developer menu);
## these defaults are the tested originals.
var turn_deadzone_deg := 4.0
var arm_full_deg := 30.0
var tilt_full_deg := 25.0
var arm_expo := 1.2
var tilt_expo := 1.3
var arm_turn := true
var tilt_turn := true
var tilt_invert := false
## Playtest #1 relaxed glide pose (upper arms down, forearms out): caps on
## the calibration's full-extension reach and fold elevation. Defaults = no
## change; PlayerBird sets 0.48 and -68 deg from Settings.
var glide_reach_cap := 10.0
var fold_elevation_cap := 0.0
var sweep_pitch := true
var sweep_gain := 0.30
var soar_lock_enabled := true
var auto_trim := true
## Neutral capture runs automatically while the calibration is uncalibrated.
var auto_calibrate := true
## Continuous arm-span refinement (the span grows, never shrinks). Off while
## another owner calibrates (PlayerBird.auto_calibrate false: the VR area's
## calibration is running; fix round 4, VR's request): a controller put down
## on a table otherwise inflated the span until VR wrote its own back.
var refine_span := true

var state := WingState.new()

# ---- diagnostics (tracking space; visualisers and tests) ----
var head := Transform3D.IDENTITY
var neck := Vector3.ZERO
var body_basis := Basis.IDENTITY
var shoulders: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var hands: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var reach: Array[float] = [1.0, 1.0]
var elevation: Array[float] = [0.0, 0.0]
var sweep_raw: Array[float] = [0.0, 0.0]
var ext_raw: Array[float] = [1.0, 1.0]
var normals: Array[Vector3] = [Vector3.UP, Vector3.UP]     ## tracking space
var twist_raw: Array[float] = [0.0, 0.0]
var twist_conf: Array[float] = [1.0, 1.0]
var has_spread := false
var calib_events := PackedStringArray()                     ## "neutral", "strokes", "glide", "rejected:..."
var head_lost_time := 0.0
var pause_requested := false

var detectors: Array[FlapDetector] = [FlapDetector.new(), FlapDetector.new()]

# ---- private state ----
var _phi_est := 0.0
var _phi_init := false
var _gate_agree_t := 0.0
var _centre_f: Array[OneEuro] = [OneEuro.new(2.0, 0.5), OneEuro.new(2.0, 0.5), OneEuro.new(2.0, 0.5)]
var _ext_f: Array[OneEuro] = [OneEuro.new(1.5, 0.2), OneEuro.new(1.5, 0.2)]
var _dih_f: Array[OneEuro] = [OneEuro.new(1.0, 0.8), OneEuro.new(1.0, 0.8)]
var _tw_f: Array[OneEuro] = [OneEuro.new(1.2, 1.0), OneEuro.new(1.2, 1.0)]
var _last_hand: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _have_hand: Array[bool] = [false, false]
## Pose sanity per tracker (head, left, right): see TrackerGate.
## Motion allowance while untracked: head 3 m/s, hands 5 m/s (a hard
## stroke peaks near 3 m/s at the hand).
var _gates: Array[TrackerGate] = [TrackerGate.new(3.0), TrackerGate.new(5.0), TrackerGate.new(5.0)]
var _lost_t: Array[float] = [10.0, 10.0]
var _reacq_t: Array[float] = [10.0, 10.0]
var _spread_t := 0.0
var _tuck_t := 0.0
var _flap_lp := 0.0
var _dih_ring: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _dih_idx := 0
var _dih_n := 0
const DIH_RING := 135
## Running sums of each ring (fix round 6): _dih_cum[i][q % (DIH_RING + 1)]
## is the sum of the samples 0..q written since the reset, so a window's
## mean is two reads instead of a loop over up to 135 samples a wing a
## tick. _dih_seq: the index of the sample being written this tick.
var _dih_cum: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
var _dih_seq := 0
## Per-tick scratch (fix round 6: reused, not allocated every tick).
var _hand_ok: Array[bool] = [false, false]
var _seen: Array[bool] = [false, false]
var _twists: Array[float] = [0.0, 0.0]
var _dihs: Array[float] = [0.0, 0.0]
var _exts: Array[float] = [1.0, 1.0]
var _sweeps: Array[float] = [0.0, 0.0]
var _dfs: Array[float] = [0.0, 0.0]
var _n0s: Array[Vector3] = [Vector3.UP, Vector3.UP]
var _c0s: Array[Vector3] = [Vector3.FORWARD, Vector3.FORWARD]
## A hand glitch or dropout up to this long is bridged (s), extrapolating
## with a velocity that fades over BRIDGE_TAU.
const BRIDGE_S := 0.1
const BRIDGE_TAU := 0.05
var _twist_hold: Array[float] = [0.0, 0.0]
var _stroke_t: Array[float] = [10.0, 10.0]   ## time since |omega| > 1 rad/s
var _trim: Array[float] = [0.0, 0.0]
var _no_onset_t := 10.0
var _both_lost_t := 0.0
var _neutral_blend := 0.0
var _mirror_w: Array[float] = [0.0, 0.0]
var _soar_prev := false
var _soar_ext := 1.0
var _soar_release_t := 10.0
var _ext_prev_out: Array[float] = [1.0, 1.0]
var _twist_prev: Array[float] = [0.0, 0.0]
var _pending_onset_t := -1.0
var _pending_side := 0
var _pending_strength := 0.0
var _t := 0.0
var _events_flapped: Array = []     ## [side, strength] emitted this tick
# Pitch jitter (round 2): wrist twist reversing faster than a pilot pitches.
## Reversal hysteresis (rad) and the fastest half-cycle a pitch command has
## (s); the jitter blend decays over JIT_TAU once the reversals stop. Only
## swings of 10 deg and more count: tracker noise and tremor (a few degrees)
## barely leave the dead zone and are not rectified, and treating them as
## jitter would lag a pilot's real pitch control (the novice bot's 4 deg
## twist noise lost 17 % of its window passes with a 3 deg hysteresis).
const JIT_HYST := 10.0 * DEG
const JIT_HALF := 0.15
const JIT_TAU := 0.4
## The jittering twist is replaced by its critically damped mean (rad/s):
## 4 Hz passes at 2.5 %, inside the pitch dead zone.
const JIT_W := 4.0
var pitch_jitter := 0.0             ## 0..1, diagnostics
var _jit_lp := 0.0
var _jit_v := 0.0
var _jit_ext := 0.0
var _jit_dir := 0
var _jit_last := -10.0
# calibration capture
var _cal_hold_t := 0.0
var _cal_prev: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _cal_prev_ok := false
var _cal_kind := &""
var _cal_t := 0.0
var _cal_samples: Array = []
var _span_grow_t := 0.0


func _init(p_calibration: WingCalibration = null) -> void:
	calibration = p_calibration if p_calibration != null else WingCalibration.new()
	for i in 2:
		_dih_ring[i].resize(DIH_RING)
		_dih_cum[i].resize(DIH_RING + 1)
	reset()


## Clears transient state (respawn); the calibration is kept.
func reset() -> void:
	state = WingState.new() if state == null else state
	state.set_neutral()
	state.tracking = 1.0
	_phi_init = false
	for f in _centre_f:
		f.clear()
	for i in 2:
		_ext_f[i].clear()
		_dih_f[i].clear()
		_tw_f[i].clear()
		_have_hand[i] = false
		_lost_t[i] = 10.0
		_reacq_t[i] = 10.0
		_twist_hold[i] = 0.0
		_mirror_w[i] = 0.0
		_stroke_t[i] = 10.0
		_ext_prev_out[i] = 1.0
		detectors[i].reset()
	has_spread = false
	_spread_t = 0.0
	_tuck_t = 0.0
	_flap_lp = 0.0
	_dih_idx = 0
	_dih_n = 0
	_dih_seq = 0
	_both_lost_t = 0.0
	_neutral_blend = 0.0
	_soar_prev = false
	_soar_release_t = 10.0
	_pending_onset_t = -1.0
	head_lost_time = 0.0
	pause_requested = false
	_reset_jitter()
	for g in _gates:
		g.reset()


func _reset_jitter() -> void:
	pitch_jitter = 0.0
	_jit_lp = 0.0
	_jit_v = 0.0
	_jit_ext = 0.0
	_jit_dir = 0
	_jit_last = -10.0


## Re-seed the torso estimate from the hand line (or the head when tucked),
## e.g. after a system recenter. No neutral recapture.
func recenter() -> void:
	_phi_init = false
	# Tracking space moved under every tracker: the next poses are trusted.
	for g in _gates:
		g.reset()
	for i in 2:
		detectors[i].drop_history()


func begin_calibration(kind: StringName) -> void:
	_cal_kind = kind
	_cal_t = 0.0
	_cal_samples.clear()
	if kind == &"neutral":
		_cal_hold_t = 0.0


func calibration_status() -> Dictionary:
	return {
		"calibrated": calibration.calibrated, "kind": _cal_kind, "progress": clampf(_cal_hold_t / 1.2, 0.0, 1.0),
		"arm_span": calibration.arm_span, "shoulder_drop": calibration.shoulder_drop,
		"stroke_full_rate": calibration.stroke_full_rate, "glide_reach": calibration.glide_reach,
	}


func flapped_events() -> Array:
	return _events_flapped


func update(frame: PoseFrame, dt_in: float) -> WingState:
	var dt := clampf(dt_in, 1e-4, 1.0 / 30.0)
	# Hand velocity is measured over the time the poses really advanced (fix
	# round 5): the whole tick (not the filters' 1/30 s clamp: a 0.1 s tick
	# read 3x the hand speed), or the source's pose interval (an engine frame
	# hitch: several ticks on one XR pose, then a jump by the whole hitch;
	# round 4 read that jump as a 7x faster hand and slow arm sweeps flapped).
	var dt_real := clampf(dt_in, 1e-4, 0.25)
	var pose_dt := frame.pose_dt if is_finite(frame.pose_dt) else -1.0
	var dt_gate := maxf(dt, minf(pose_dt, 0.25))
	_t += dt
	calib_events.clear()
	_events_flapped = []
	var ws := state
	ws.t = frame.t
	var cal := calibration
	var l_arm := cal.arm_length()
	var dzs := deadzone_scale

	# ---- head (sanity, loss) ------------------------------------------------
	if frame.discontinuity:
		# Recenter / respawn: every pose may jump consistently; trust it.
		trust_next()
	elif _whole_body_moved(frame):
		# Head and both hands moved by the same vector (the player walked
		# while paused, the runtime re-localized): a translation of the
		# body, not a glitch. Accept it; the stroke detectors restart.
		trust_next()
		for d in detectors:
			d.drop_history()
	var head_ok := _gates[0].accept(frame.head, frame.head_valid, dt_gate)
	if head_ok:
		head = frame.head
		head_lost_time = 0.0
		pause_requested = false
		if _gates[0].jumped:
			# The neck jumped with a re-localized head: no hand velocity from it.
			for d in detectors:
				d.drop_history()
	else:
		head_lost_time += dt
		pause_requested = head_lost_time > 1.0
		head = _gates[0].pose
	# ---- hands (sanity, bridge, hold) -------------------------------------
	# hand_ok: usable this tick (accepted, or bridged over a short gap) for
	# the geometry and the stroke detector. seen: a real accepted sample;
	# the loss clock (_lost_t, the mirror, both-lost) runs from the first
	# missing one, so bridging never delays the §5.12 timings.
	var hand_ok := _hand_ok
	var seen := _seen
	hand_ok[0] = false
	hand_ok[1] = false
	seen[0] = false
	seen[1] = false
	for i in 2:
		var g := _gates[1 + i]
		var tr := frame.left if i == 0 else frame.right
		var valid := frame.left_valid if i == 0 else frame.right_valid
		var ok := g.accept(tr, valid, dt_gate)
		if ok:
			if _lost_t[i] > 0.0 and _have_hand[i] and _lost_t[i] < 9.0:
				_reacq_t[i] = 0.0
			_last_hand[i] = tr
			_have_hand[i] = true
			_lost_t[i] = 0.0
			if g.jumped:
				detectors[i].drop_history()
			seen[i] = true
		elif g.have and g.age <= BRIDGE_S:
			# A glitch or a dropout of up to BRIDGE_S: the hand carries on
			# with its own motion, fading (tau BRIDGE_TAU) so it never flies
			# past where a decelerating stroke ends. One bad frame must not
			# forfeit the stroke in progress (a lost hand forfeits its arc).
			var ext := g.vel * BRIDGE_TAU * (1.0 - exp(-g.age / BRIDGE_TAU))
			_last_hand[i] = Transform3D(g.pose.basis, g.pose.origin + ext)
			ok = true
			_lost_t[i] += dt
		else:
			_lost_t[i] += dt
		_reacq_t[i] += dt
		hand_ok[i] = ok
		hands[i] = _last_hand[i]
	var both_ok := hand_ok[0] and hand_ok[1]

	# ---- §5.1 head forward --------------------------------------------------
	var zf := -head.basis.z
	var hy := head.basis.y
	var f_head := Vector3(zf.x, 0.0, zf.z) - Vector3(hy.x, 0.0, hy.z) * zf.y
	var phi_head := atan2(-f_head.x, -f_head.z) if f_head.length() > 1e-4 else _phi_est

	# ---- §5.2 torso yaw ----------------------------------------------------
	var w := hands[1].origin - hands[0].origin
	var w_h := Vector3(w.x, 0.0, w.z)
	var phi_prev := _phi_est
	if not _phi_init:
		if both_ok and w_h.length() > 0.35 * cal.arm_span:
			_phi_est = FlightMath.yaw_of(Vector3.UP.cross(w_h).normalized())
		else:
			_phi_est = phi_head
		_phi_init = true
	elif head_ok:
		var c := 0.0
		var phi_w := _phi_est
		if both_ok and w_h.length() > 1e-3:
			phi_w = FlightMath.yaw_of(Vector3.UP.cross(w_h).normalized())
			var c_span := FlightMath.sstep(0.35, 0.75, w_h.length() / cal.arm_span)
			var om := maxf(absf(detectors[0].omega), absf(detectors[1].omega))
			var c_calm := 1.0 - 0.6 * clampf(om / 4.0, 0.0, 1.0)
			var jump := absf(FlightMath.wrap_angle(phi_w - _phi_est))
			var c_gate := 1.0
			if jump > 75.0 * DEG:
				if absf(FlightMath.wrap_angle(phi_w - phi_head)) < 40.0 * DEG:
					_gate_agree_t += dt
				else:
					_gate_agree_t = 0.0
				c_gate = 1.0 if _gate_agree_t >= 0.3 else 0.0
			else:
				_gate_agree_t = 0.0
			c = c_span * c_calm * c_gate
			# tau 0.08 s (spec: 0.10): a first-order follow lags rate x tau, and
			# the spec's own target (180 deg in 2 s, lag <= 8 deg) needs < 0.089.
			_phi_est += FlightMath.wrap_angle(phi_w - _phi_est) * (1.0 - exp(-dt * c / 0.08))
		var e := FlightMath.wrap_angle(phi_head - _phi_est)
		if absf(e) > 70.0 * DEG:
			# The neck leash only matters when the hands say little (tucked,
			# crossed): with trusted spread arms the head is ignored (WI-04),
			# so its pull fades with the hand confidence c.
			_phi_est += signf(e) * (absf(e) - 70.0 * DEG) * (1.0 - exp(-dt / (0.5 if c > 0.5 else 2.0))) * (1.0 - c)
		_phi_est += FlightMath.wrap_angle(phi_head - _phi_est) * (1.0 - c) * (1.0 - exp(-dt / 4.0))
		var d_phi := FlightMath.wrap_angle(_phi_est - phi_prev)
		var lim := 400.0 * DEG * dt
		_phi_est = FlightMath.wrap_angle(phi_prev + clampf(d_phi, -lim, lim))
	ws.body_yaw_rate = FlightMath.wrap_angle(_phi_est - phi_prev) / dt
	ws.body_yaw = _phi_est
	body_basis = Basis(Vector3.UP, _phi_est)
	var bf := body_basis * Vector3.FORWARD
	var bu := Vector3.UP
	var br := bf.cross(bu)
	var b_inv := body_basis.transposed()

	# ---- §5.3 shoulders (neck pivot) -----------------------------------------
	neck = head.origin + head.basis * Vector3(0.0, -0.08, 0.09)
	var centre_raw := neck + Vector3(0.0, -(cal.shoulder_drop - 0.08), 0.0) - bf * 0.02
	var centre := Vector3(_centre_f[0].filter(centre_raw.x, dt), _centre_f[1].filter(centre_raw.y, dt),
		_centre_f[2].filter(centre_raw.z, dt))
	shoulders[0] = centre - br * cal.shoulder_width * 0.5
	shoulders[1] = centre + br * cal.shoulder_width * 0.5

	# ---- per wing ------------------------------------------------------------
	var r_hi := minf(0.58 if cal.seated else cal.glide_reach, glide_reach_cap)
	var fold_hi := minf(-55.0 * DEG if cal.seated else cal.fold_elevation, fold_elevation_cap)
	var fold_lo := -75.0 * DEG if cal.seated else cal.fold_elevation - 20.0 * DEG
	var twists := _twists
	var dihs := _dihs
	var exts := _exts
	var sweeps := _sweeps
	var dfs := _dfs
	var n0s := _n0s
	var c0s := _c0s
	for i in 2:
		twists[i] = 0.0
		dihs[i] = 0.0
		exts[i] = 1.0
		sweeps[i] = 0.0
		dfs[i] = 0.0
		n0s[i] = Vector3.UP
		c0s[i] = bf
	for i in 2:
		var sig: float = SIDE[i]
		var p := hands[i].origin
		var a := p - shoulders[i]
		var x_out := sig * a.dot(br)
		var y := a.dot(bu)
		var z := a.dot(bf)
		var xo := maxf(x_out, 0.05)
		reach[i] = sqrt(maxf(x_out, 0.0) * maxf(x_out, 0.0) + y * y) / maxf(l_arm, 0.1)
		elevation[i] = atan2(y, xo)
		sweep_raw[i] = atan2(z, xo)
		sweeps[i] = sweep_raw[i]
		# §5.5 extension
		var e_reach := FlightMath.sstep(0.30, r_hi, reach[i])
		var e_low := FlightMath.sstep(fold_lo, fold_hi, elevation[i])
		var e_back := 1.0 - FlightMath.sstep(-35.0 * DEG, -70.0 * DEG, sweep_raw[i])
		ext_raw[i] = e_reach * e_low * e_back
		exts[i] = _ext_f[i].filter(ext_raw[i], dt)
		# §5.6 dihedral: cycle mean while stroking, else One-Euro (below).
		_dih_ring[i][_dih_idx] = elevation[i]
		_cum_write(i, _dih_seq)
		# One-Euro in DEGREES: the spec's beta values and latency targets
		# (twist 90% in <= 90 ms) are in degree units.
		dfs[i] = _dih_f[i].filter(elevation[i] / DEG, dt) * DEG
		# "Stroking" is latched for 0.5 s: omega passes through zero at every
		# stroke reversal, and switching to the instantaneous elevation there
		# would kick the roll by the full +-45 deg swing twice per beat.
		var was := _stroke_t[i] < 0.5
		_stroke_t[i] = 0.0 if absf(detectors[i].omega) > 1.0 else _stroke_t[i] + dt
		if not was and _stroke_t[i] < 0.5:
			# A stroking episode starts: the ring's history from before it (a
			# bank gesture just before flapping) is replaced by the smoothed
			# dihedral at the start, so the cycle mean continues from exactly
			# what was shown (no kick) and never lingers on the old gesture.
			var n_hist := mini(_dih_n, DIH_RING)
			for k in range(1, n_hist):
				_dih_ring[i][posmod(_dih_idx - k, DIH_RING)] = dfs[i]
			for k in range(n_hist - 1, -1, -1):
				_cum_write(i, _dih_seq - k)
		# §5.7 wrist twist: swing-twist about the calibrated forearm axis.
		var r_body := b_inv * hands[i].basis
		var qq := (cal.neutral(i).transposed() * r_body).get_rotation_quaternion()
		var al := cal.forearm_axis(i)
		var proj := qq.x * al.x + qq.y * al.y + qq.z * al.z
		twist_conf[i] = sqrt(qq.w * qq.w + proj * proj)
		var k_side := signf((cal.neutral(i) * al).dot(Vector3(1, 0, 0)))
		if k_side == 0.0:
			k_side = sig
		if twist_conf[i] >= 0.25:
			_twist_hold[i] = k_side * FlightMath.wrap_angle(2.0 * atan2(proj, qq.w))
		twist_raw[i] = _twist_hold[i]
		twists[i] = _tw_f[i].filter(twist_raw[i] / DEG, dt) * DEG - _trim[i]
		# §5.8 wing normal at zero incidence
		var o := a.normalized() if a.length() > 1e-4 else br * sig
		var c0 := bf - o * bf.dot(o)
		c0 = c0.normalized() if c0.length() > 1e-4 else bu
		c0s[i] = c0
		n0s[i] = (o.cross(c0) * sig).normalized()
	# Cycle-mean dihedral. While BOTH wings stroke they share one window: each
	# detector's period estimate has its own history (a roll gesture just
	# before the strokes seeds them differently), and two different windows
	# over the same symmetric beat give different means - a phantom roll of
	# up to 0.35 for the first beats. A common window cancels exactly. A
	# one-wing stroke keeps its own period (the idle wing's is stale).
	var both := hand_ok[0] and hand_ok[1] and _stroke_t[0] < 0.5 and _stroke_t[1] < 0.5
	var win_common := clampf(0.5 * (detectors[0].period + detectors[1].period), 0.3, 1.5)
	for i in 2:
		if _stroke_t[i] < 0.5:
			var win := win_common if both else clampf(detectors[i].period, 0.3, 1.5)
			dihs[i] = _ring_mean(i, win, dt)
			_dih_f[i].reset(dihs[i] / DEG)
		else:
			dihs[i] = dfs[i]
	_dih_idx = (_dih_idx + 1) % DIH_RING
	_dih_n = mini(_dih_n + 1, DIH_RING)
	_dih_seq += 1

	# ---- §5.12 tracking loss: mirror the lost wing ------------------------------
	for i in 2:
		var j := 1 - i
		var target_w := 0.0
		if not seen[i] and seen[j]:
			target_w = clampf((_lost_t[i] - 0.25) / 0.6, 0.0, 1.0)
		elif seen[i] and _mirror_w[i] > 0.0:
			# Reacquired: fade the mirror out over 0.4 s (no jump).
			target_w = maxf(0.0, _mirror_w[i] - dt / 0.4)
		_mirror_w[i] = target_w
	for i in 2:
		var j := 1 - i
		var mw := _mirror_w[i]
		if mw > 0.0:
			exts[i] = lerpf(exts[i], exts[j], mw)
			dihs[i] = lerpf(dihs[i], dihs[j], mw)
			twists[i] = lerpf(twists[i], twists[j], mw)

	# ---- novice floor, tuck, soar lock (§5.5) -------------------------------
	if exts[0] > 0.8 and exts[1] > 0.8:
		_spread_t += dt
		if _spread_t >= 0.3:
			has_spread = true
	else:
		_spread_t = 0.0
	if not has_spread:
		exts[0] = maxf(exts[0], 0.85)
		exts[1] = maxf(exts[1], 0.85)
	var grip_l := clampf(frame.grip.x, 0.0, 1.0)
	var grip_r := clampf(frame.grip.y, 0.0, 1.0)
	ws.grip_l = grip_l
	ws.grip_r = grip_r
	var soar_on := soar_lock_enabled and grip_l > 0.6 and grip_r > 0.6
	ws.soar_lock_changed = false
	if soar_on and not _soar_prev:
		if minf(exts[0], exts[1]) >= 0.5:
			_soar_ext = minf(exts[0], exts[1])
			ws.soar_lock = true
			ws.soar_lock_changed = true
	elif not soar_on and _soar_prev and ws.soar_lock:
		ws.soar_lock = false
		ws.soar_lock_changed = true
		_soar_release_t = 0.0
	_soar_prev = soar_on
	_soar_release_t += dt
	if ws.soar_lock:
		exts[0] = maxf(exts[0], _soar_ext)
		exts[1] = maxf(exts[1], _soar_ext)
	elif _soar_release_t < 0.4:
		var kk := _soar_release_t / 0.4
		exts[0] = lerpf(maxf(exts[0], _soar_ext), exts[0], kk)
		exts[1] = lerpf(maxf(exts[1], _soar_ext), exts[1], kk)
	if exts[0] < 0.25 and exts[1] < 0.25:
		_tuck_t += dt
	elif exts[0] > 0.35 or exts[1] > 0.35:
		_tuck_t = 0.0
	ws.tucked = _tuck_t > 0.1 or (ws.tucked and not (exts[0] > 0.35 or exts[1] > 0.35))

	# ---- §5.8 flap direction and §6 detection --------------------------------
	for i in 2:
		var u := _shape(twists[i], 5.0, 40.0, 30.0, 1.4, true)
		var th := u * (20.0 if u > 0.0 else 35.0) * DEG
		var nrm := n0s[i] * cos(th) - c0s[i] * sin(th)
		normals[i] = nrm
		var dir := b_inv * nrm
		if i == 0:
			ws.flap_dir_l = dir
		else:
			ws.flap_dir_r = dir
		# Detector normal: incidence clamped to +-20 deg.
		var thc := clampf(th, -20.0 * DEG, 20.0 * DEG)
		var n_det := n0s[i] * cos(thc) - c0s[i] * sin(thc)
		var det := detectors[i]
		det.size_x = size_x
		det.seated = cal.seated
		det.omega_full = cal.stroke_full_rate
		det.arc_full = cal.stroke_full_arc
		det.step(hands[i].origin - neck, n_det, l_arm, exts[i], hand_ok[i], dt_real, pose_dt)

	# ---- aggregates (§5.9) -----------------------------------------------------
	var t_s := _dejitter(0.5 * (twists[0] + twists[1]), dt)
	var t_a := 0.5 * (twists[0] - twists[1])
	var pitch := _shape(t_s, 5.0, 40.0, 30.0, 1.4, true)
	if sweep_pitch:
		var sw := 0.5 * (sweeps[0] + sweeps[1])
		pitch += sweep_gain * FlightMath.shape(sw, 12.0 * DEG * dzs, 35.0 * DEG, 35.0 * DEG, 1.0) * minf(exts[0], exts[1])
	pitch = clampf(pitch, -1.0, 1.0)
	var d_a := 0.0
	if reach[0] > 0.3 and reach[1] > 0.3:
		d_a = 0.5 * (dihs[0] - dihs[1])
	var roll_arm := FlightMath.shape(d_a, turn_deadzone_deg * DEG * dzs, arm_full_deg * DEG, arm_full_deg * DEG, arm_expo) if arm_turn else 0.0
	var roll_tilt := _shape(t_a, turn_deadzone_deg, tilt_full_deg, tilt_full_deg, tilt_expo, true) if tilt_turn else 0.0
	if tilt_invert:
		roll_tilt = -roll_tilt
	var roll := clampf(roll_arm + roll_tilt, -1.0, 1.0)
	# Arms fully stretched (beyond the relaxed glide pose): a power stroke.
	ws.stretch = FlightMath.sstep(0.82, 0.97, minf(reach[0], reach[1])) if (hand_ok[0] and hand_ok[1]) else 0.0
	if invert_pitch:
		pitch = -pitch

	# ---- both hands lost: neutral glide ---------------------------------------
	if not seen[0] and not seen[1]:
		_both_lost_t += dt
	else:
		_both_lost_t = 0.0
	var want_neutral := 1.0 if _both_lost_t > 0.25 else 0.0
	_neutral_blend = move_toward(_neutral_blend, want_neutral, dt / 0.8)
	var nb := _neutral_blend
	ws.tracking = 1.0 - nb
	if nb > 0.0:
		pitch = lerpf(pitch, 0.0, nb)
		roll = lerpf(roll, 0.0, nb)
		exts[0] = lerpf(exts[0], 1.0, nb)
		exts[1] = lerpf(exts[1], 1.0, nb)
		ws.flap_dir_l = ws.flap_dir_l.lerp(Vector3.UP, nb).normalized()
		ws.flap_dir_r = ws.flap_dir_r.lerp(Vector3.UP, nb).normalized()

	# ---- write the state -------------------------------------------------------
	ws.pitch = pitch
	ws.roll = roll
	ws.ext_l = clampf(exts[0], 0.0, 1.0)
	ws.ext_r = clampf(exts[1], 0.0, 1.0)
	ws.flap_l = detectors[0].flap
	ws.flap_r = detectors[1].flap
	ws.up_l = detectors[0].up
	ws.up_r = detectors[1].up
	ws.omega_l = detectors[0].omega
	ws.omega_r = detectors[1].omega
	ws.twist_l = twists[0]
	ws.twist_r = twists[1]
	ws.dihedral_l = dihs[0]
	ws.dihedral_r = dihs[1]
	ws.sweep_l = sweeps[0]
	ws.sweep_r = sweeps[1]
	ws.stroke_phase_l = detectors[0].phase
	ws.stroke_phase_r = detectors[1].phase
	var flapping_l := detectors[0].flap > 0.0 or detectors[0].state != FlapDetector.IDLE
	var flapping_r := detectors[1].flap > 0.0 or detectors[1].state != FlapDetector.IDLE
	if flapping_l and flapping_r:
		ws.stroke_period = 0.5 * (detectors[0].period + detectors[1].period)
	elif flapping_r:
		ws.stroke_period = detectors[1].period
	else:
		ws.stroke_period = detectors[0].period
	ws.calibrated = cal.calibrated
	_flap_lp += (maxf(ws.flap_l, ws.flap_r) - _flap_lp) * FlightMath.lp_k(dt, 0.3)
	ws.flapping = clampf(_flap_lp, 0.0, 1.0)
	# Detents / range crossings (haptic "clicks" at the dead-zone and full scale).
	for i in 2:
		var tw := twists[i]
		var prev := _twist_prev[i]
		var dz := 5.0 * DEG * dzs
		var det_x := (absf(tw) > dz) != (absf(prev) > dz)
		var full_up := 40.0 * DEG / wrist_sensitivity
		var full_dn := 30.0 * DEG / wrist_sensitivity
		var rng_x := (tw > full_up) != (prev > full_up) or (tw < -full_dn) != (prev < -full_dn)
		if i == 0:
			ws.detent_l = det_x
			ws.range_l = rng_x
		else:
			ws.detent_r = det_x
			ws.range_r = rng_x
		_twist_prev[i] = tw
	# Onsets and the flapped event (paired within 60 ms).
	ws.onset_l = detectors[0].onset
	ws.onset_r = detectors[1].onset
	if ws.onset_l or ws.onset_r:
		ws.onset_strength = detectors[0].onset_strength if ws.onset_l else detectors[1].onset_strength
		_no_onset_t = 0.0
	else:
		_no_onset_t += dt
	_pair_onsets(ws)

	# ---- calibration ------------------------------------------------------------
	_calibration_step(frame, seen, dt)
	_auto_trim(ws, twists, dt)
	return ws


func _pair_onsets(ws: WingState) -> void:
	var side_now := 0
	if ws.onset_l and ws.onset_r:
		_events_flapped.append([0, ws.onset_strength])
		_pending_onset_t = -1.0
		return
	if ws.onset_l:
		side_now = -1
	elif ws.onset_r:
		side_now = 1
	if side_now != 0:
		if _pending_onset_t >= 0.0 and _pending_side == -side_now and _t - _pending_onset_t <= 0.0601:
			_events_flapped.append([0, maxf(_pending_strength, ws.onset_strength)])
			_pending_onset_t = -1.0
			return
		if _pending_onset_t >= 0.0:
			_events_flapped.append([_pending_side, _pending_strength])
		_pending_onset_t = _t
		_pending_side = side_now
		_pending_strength = ws.onset_strength
	elif _pending_onset_t >= 0.0 and _t - _pending_onset_t > 0.0601:
		_events_flapped.append([_pending_side, _pending_strength])
		_pending_onset_t = -1.0


## Symmetric wrist twist -> the twist the pitch shaping sees. Shaking the
## wrists (reversals faster than JIT_HALF per half-cycle, i.e. above ~3 Hz)
## is not a pitch command: through the asymmetric shaping and the model's
## asymmetric pitch map it was rectified into a trim (round 2: +-35 deg at
## 4-10 Hz held the bird 6 m of energy height above a still glide in 12 s).
## While the twist reverses that fast it is replaced by its mean (a
## critically damped low-pass), so the jitter averages to zero; a single
## step (no reversal) or a pilot's pitch pumping (half-cycles of 0.25 s and
## more) passes untouched, within the 90 ms twist latency (WI-20).
func _dejitter(x: float, dt: float) -> float:
	_jit_v += (JIT_W * JIT_W * (x - _jit_lp) - 2.0 * JIT_W * _jit_v) * dt
	_jit_lp += _jit_v * dt
	var reversed := false
	if _jit_dir >= 0 and x < _jit_ext - JIT_HYST:
		reversed = _jit_dir > 0
		_jit_dir = -1
		_jit_ext = x
	elif _jit_dir <= 0 and x > _jit_ext + JIT_HYST:
		reversed = _jit_dir < 0
		_jit_dir = 1
		_jit_ext = x
	elif (_jit_dir > 0 and x > _jit_ext) or (_jit_dir < 0 and x < _jit_ext):
		_jit_ext = x
	if reversed:
		if _t - _jit_last < JIT_HALF:
			# Each fast reversal moves the blend 60 % of the way (no step).
			pitch_jitter = 1.0 - (1.0 - pitch_jitter) * 0.4
		_jit_last = _t
	else:
		pitch_jitter *= exp(-dt / JIT_TAU)
	return lerpf(x, _jit_lp, pitch_jitter)


func _shape(x: float, dz_deg: float, full_pos_deg: float, full_neg_deg: float, expo: float, wrist: bool) -> float:
	var sens := wrist_sensitivity if wrist else 1.0
	return FlightMath.shape(x, dz_deg * DEG * deadzone_scale, full_pos_deg * DEG / sens, full_neg_deg * DEG / sens, expo)


func _ring_mean(i: int, window: float, dt: float) -> float:
	var n := clampi(int(round(window / maxf(dt, 1e-4))), 1, mini(_dih_n + 1, DIH_RING))
	var c := _dih_cum[i]
	var m := DIH_RING + 1
	var q := _dih_seq
	var older := c[(q - n) % m] if q - n >= 0 else 0.0
	return (c[q % m] - older) / n


## The running sum through sample q (this tick's is q = _dih_seq, stored at
## ring slot _dih_idx; sample q - k at slot _dih_idx - k).
func _cum_write(i: int, q: int) -> void:
	if q < 0:
		return
	var m := DIH_RING + 1
	var prev := _dih_cum[i][(q - 1) % m] if q > 0 else 0.0
	_dih_cum[i][q % m] = prev + _dih_ring[i][posmod(_dih_idx - (_dih_seq - q), DIH_RING)]


## The calibration's neutral was replaced from outside (VR's automatic
## capture or a manual recalibration writes the resource directly): forget
## everything learnt against the old neutral. The auto-trim (up to +-10 deg,
## tau 60 s) would otherwise read flat wrists as ~6 deg of twist for a
## minute; the twist filters and held twists restart from the new neutral.
## VR calls this (duck-typed) right after writing a new neutral.
func calibration_replaced() -> void:
	for i in 2:
		_trim[i] = 0.0
		_twist_hold[i] = 0.0
		_tw_f[i].clear()


## The next poses are trusted as they come (after a pause, a recenter, a
## respawn): the continuity gates restart.
func trust_next() -> void:
	for g in _gates:
		g.reset()


## After the pause menu (fix round 5): the arms and the body may be anywhere
## (a menu pose, a few steps walked). Every pose is trusted, and no stroke
## from before or during the pause carries over: the detectors restart
## (arc bank, stroke state, velocity), so bringing the arms back from the
## menu is never a wingbeat. Round 4 only trusted the poses: the jump from
## the airplane pose to a raised pointing arm banked as an upstroke, and the
## arm coming back down 0.3-0.4 s after resume was a credited downstroke (a
## player_flapped event and 0.36 of the weight in flap force).
func resume() -> void:
	trust_next()
	for i in 2:
		detectors[i].reset()
		_stroke_t[i] = 10.0
	_pending_onset_t = -1.0


func _whole_body_moved(frame: PoseFrame) -> bool:
	if not (frame.head_valid and frame.left_valid and frame.right_valid):
		return false
	if not (_gates[0].have and _gates[1].have and _gates[2].have):
		return false
	if not (pose_sane(frame.head) and pose_sane(frame.left) and pose_sane(frame.right)):
		return false
	var dh := frame.head.origin - _gates[0].pose.origin
	if dh.length() <= TrackerGate.JUMP:
		return false
	var tol := 0.05 + 1.0 * maxf(_gates[1].age, _gates[2].age)
	return (frame.left.origin - _gates[1].pose.origin).distance_to(dh) < tol \
		and (frame.right.origin - _gates[2].pose.origin).distance_to(dh) < tol


## A sample is usable at all (§3.1): finite, a proper basis, within 20 m
## of the tracking origin.
static func pose_sane(tr: Transform3D) -> bool:
	if not FlightMath.vfinite(tr.origin) or not FlightMath.bfinite(tr.basis):
		return false
	return tr.basis.determinant() >= 0.5 and tr.origin.length() <= 20.0


## Pose sanity for one tracker (§3.1, pinned by WI-30). A sample is accepted
## when it is sane and continuous with the last ACCEPTED pose (0.15 m plus
## v_lim of motion since then: a hand moves ~8 cm per 72 Hz tick at most, so
## the spec's flat 0.5 m let a 0.6 m teleport through). Round 1 compared with the previous RAW
## sample, so a glitch lasting two ticks was accepted from its second tick
## (a head offset of 0.6 m then read as a full stroke). A jump that stays
## consistent for RELOC_S is a re-localization of tracking space: accepted,
## flagged `jumped` so velocity estimators restart.
class TrackerGate:
	const JUMP := 0.15
	const RELOC_S := 0.25
	var v_lim := 8.0
	var pose := Transform3D.IDENTITY   ## last accepted
	var have := false
	var age := 0.0                     ## s since the last accepted sample
	var vel := Vector3.ZERO            ## of accepted samples (bridging)
	var jumped := false                ## this tick accepted a re-localization
	var _cand := Transform3D.IDENTITY
	var _cand_t := -1.0

	func _init(p_v_lim := 8.0) -> void:
		v_lim = p_v_lim

	func reset() -> void:
		have = false
		age = 0.0
		vel = Vector3.ZERO
		jumped = false
		_cand_t = -1.0

	func accept(tr: Transform3D, valid: bool, dt: float) -> bool:
		jumped = false
		age += dt
		if not valid or not WingInput.pose_sane(tr):
			_cand_t = -1.0
			return false
		if have and tr.origin.distance_to(pose.origin) > JUMP + v_lim * age:
			if _cand_t >= 0.0 and tr.origin.distance_to(_cand.origin) <= 0.1 + v_lim * dt:
				_cand_t += dt
			else:
				_cand_t = 0.0
			_cand = tr
			if _cand_t < RELOC_S:
				return false
			jumped = true
		if have and not jumped and age > 1e-6:
			var v := (tr.origin - pose.origin) / age
			vel = vel.lerp(v, 0.5) if v.length() < v_lim else Vector3.ZERO
		else:
			vel = Vector3.ZERO
		pose = tr
		have = true
		age = 0.0
		_cand_t = -1.0
		return true


# ---- calibration (§5.10) ---------------------------------------------------------

func _calibration_step(frame: PoseFrame, hand_ok: Array[bool], dt: float) -> void:
	var cal := calibration
	var both := hand_ok[0] and hand_ok[1] and frame.head_valid
	# Neutral capture: automatic while uncalibrated, or on request.
	var want_neutral := (auto_calibrate and not cal.calibrated) or _cal_kind == &"neutral"
	if want_neutral and both:
		var l := hands[0]
		var r := hands[1]
		var w := r.origin - l.origin
		var calm := true
		if _cal_prev_ok:
			for i in 2:
				var v := (hands[i].origin - _cal_prev[i].origin).length() / dt
				var ang := (_cal_prev[i].basis.transposed() * hands[i].basis).get_rotation_quaternion().get_angle() / dt
				if v > 0.08 or ang > 25.0 * DEG:
					calm = false
		var ok := w.length() > 0.9 and absf(elevation[0]) < 25.0 * DEG and absf(elevation[1]) < 25.0 * DEG \
			and absf(l.origin.y - r.origin.y) < 0.12 and calm
		_cal_hold_t = _cal_hold_t + dt if ok else 0.0
		if _cal_hold_t >= 1.2:
			_capture_neutral(frame)
			_cal_hold_t = 0.0
	else:
		_cal_hold_t = 0.0
	_cal_prev[0] = hands[0]
	_cal_prev[1] = hands[1]
	_cal_prev_ok = both
	# Stroke capture: three credited strokes.
	if _cal_kind == &"strokes":
		for i in 2:
			if detectors[i].onset:
				_cal_samples.append([detectors[i].peak_omega, detectors[i].last_up_arc])
		if _cal_samples.size() >= 6:
			var peaks := []
			var arcs := []
			for sm in _cal_samples:
				peaks.append(sm[0])
				arcs.append(sm[1])
			peaks.sort()
			arcs.sort()
			cal.stroke_full_rate = clampf(0.85 * float(peaks[peaks.size() / 2]), 3.0, 6.0)
			cal.stroke_full_arc = clampf(0.5 * float(arcs[arcs.size() / 2]), 25.0 * DEG, 40.0 * DEG)
			calib_events.append("strokes")
			_cal_kind = &""
	# Glide-pose capture: hold a comfortable glide for 2 s.
	if _cal_kind == &"glide" and both:
		_cal_t += dt
		_cal_samples.append([0.5 * (reach[0] + reach[1]), 0.5 * (elevation[0] + elevation[1])])
		if _cal_t >= 2.0:
			var rc := 0.0
			var de := 0.0
			for sm in _cal_samples:
				rc += sm[0]
				de += sm[1]
			rc /= _cal_samples.size()
			de /= _cal_samples.size()
			cal.glide_reach = clampf(0.95 * rc, 0.50, 0.75)
			cal.fold_elevation = minf(-62.0 * DEG, de - 12.0 * DEG)
			calib_events.append("glide")
			_cal_kind = &""
	# Continuous refinement: the span grows, never shrinks.
	if cal.calibrated and both and refine_span:
		var span_now := (hands[1].origin - hands[0].origin).length()
		if span_now > cal.arm_span + 0.05 and span_now <= 2.2:
			_span_grow_t += dt
			if _span_grow_t >= 0.5:
				cal.arm_span = span_now
				cal.shoulder_width = 0.23 * span_now
				_span_grow_t = 0.0
		else:
			_span_grow_t = 0.0


func _capture_neutral(frame: PoseFrame) -> void:
	var cal := calibration
	var l := hands[0]
	var r := hands[1]
	var span := clampf((r.origin - l.origin).length(), 1.0, 2.2)
	var sw := 0.23 * span
	var l_arm := (span - sw) * 0.5
	var drop := clampf(head.origin.y - 0.5 * (l.origin.y + r.origin.y) - l_arm * sin(5.0 * DEG), 0.15, 0.35)
	var w_h := Vector3(r.origin.x - l.origin.x, 0.0, r.origin.z - l.origin.z)
	var f := Vector3.UP.cross(w_h).normalized()
	var phi := FlightMath.yaw_of(f)
	var b := Basis(Vector3.UP, phi)
	var rt := f.cross(Vector3.UP)
	var nk := head.origin + head.basis * Vector3(0.0, -0.08, 0.09)
	var centre := nk + Vector3(0.0, -(drop - 0.08), 0.0) - f * 0.02
	var s_l := centre - rt * sw * 0.5
	var s_r := centre + rt * sw * 0.5
	var new_n: Array[Basis] = [b.transposed() * l.basis, b.transposed() * r.basis]
	var new_a: Array[Vector3] = [l.basis.transposed() * (l.origin - s_l).normalized(), r.basis.transposed() * (r.origin - s_r).normalized()]
	var new_c: Array[Vector3] = []
	for i in 2:
		var hb := l.basis if i == 0 else r.basis
		var c := hb.transposed() * f
		c = (c - new_a[i] * c.dot(new_a[i])).normalized()
		new_c.append(c)
		if new_a[i].angle_to(WingCalibration.DEFAULT_FOREARM) > 45.0 * DEG:
			calib_events.append("rejected:axis")
			return
	cal.arm_span = span
	cal.shoulder_width = sw
	cal.shoulder_drop = drop
	cal.neutral_left = new_n[0]
	cal.neutral_right = new_n[1]
	cal.forearm_axis_left = new_a[0]
	cal.forearm_axis_right = new_a[1]
	cal.chord_axis_left = new_c[0]
	cal.chord_axis_right = new_c[1]
	cal.seated = cal.seated or head.origin.y < 1.30
	cal.calibrated = true
	has_spread = false
	_spread_t = 0.0
	_trim[0] = 0.0
	_trim[1] = 0.0
	for i in 2:
		_tw_f[i].clear()
	if _cal_kind == &"neutral":
		_cal_kind = &""
	calib_events.append("neutral")


## Neutral-twist auto-trim (§5.10): slow drift of a tired forearm's "flat"
## is absorbed while gliding; deliberate inputs (>= 12 deg) never are.
func _auto_trim(ws: WingState, twists: Array[float], dt: float) -> void:
	if not auto_trim:
		return
	if _no_onset_t < 5.0 or ws.ext_l < 0.8 or ws.ext_r < 0.8 or absf(ws.roll) >= 0.2:
		return
	var k := 1.0 - exp(-dt / 60.0)
	for i in 2:
		var raw := twists[i] + _trim[i]
		if absf(twists[i]) < 12.0 * DEG:
			_trim[i] = clampf(_trim[i] + (raw - _trim[i]) * k, -10.0 * DEG, 10.0 * DEG)
