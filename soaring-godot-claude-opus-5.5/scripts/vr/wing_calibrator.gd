class_name WingCalibrator
extends RefCounted
## Fits the player's body onto a bird's wings: arm span, shoulder height,
## the wrist angle they hold as "flat", the forearm and chord axes in the
## controller's frame, whether they sit. Pure logic (no scene), so tests can
## feed it synthetic players (VRHumanPose).
##
## Everything is in TRACKING space, real metres (never world_scale'd), and
## follows docs/areas/FLIGHT_SPEC.md §5 exactly, so the numbers written into
## the flight area's WingCalibration mean what WingInput expects:
##   §5.2 torso yaw from the hand line, §5.3 neck-pivot shoulders,
##   §5.4-5.5 reach / elevation / sweep -> extension,
##   §5.7 wrist twist by swing-twist about the calibrated forearm axis,
##   §5.10 the neutral capture (here an explicit, prompted step), seated,
##   span refinement,
##   §5.11 the persisted fields.
##
## Per tick call measure(head, left, right, valid_mask, dt). Measurements
## (extension, twist, shoulders, body yaw) are always available, calibrated
## or not. The wrist neutral and the body are captured ONLY when the owner
## asks (request_capture: the player was shown "Stand tall. Spread your
## wings, hands flat. Hold still."), from a plausible, still spread held
## NEUTRAL_HOLD (neutral_blocker). Nothing here ever captures by itself
## (the redesign after fix round 6: every automatic capture or re-check, and
## every card answered by a pose, eventually took a pose the player did not
## mean, e.g. a landing flare held on a perch, as their "flat").
## The only thing learnt in play is the arm span, from genuine spreads
## (spread_span_sample); it never touches the wrist neutral or the axes.
##
## One deliberate refinement of §5.10: the shoulder drop comes from body
## proportions (stature from the standing eye height and the arm span),
## bounded by the hand line, instead of assuming the arms were held exactly
## 5° low (1.1 cm of shoulder error per degree the player held them
## otherwise, which moved a half-folded wing's extension by up to 0.4).

## A requested capture succeeded (kind is always &"neutral").
signal captured(kind: StringName)
## A requested capture was refused (a controller held in an unusual way:
## its forearm axis far from any real grip): the calibration held is
## unchanged.
signal rejected(kind: StringName, reason: String)
## The arm span grew during play (the first capture was cramped), or the
## seating changed. Never the wrist neutral.
signal refined(arm_span: float)

const DEFAULT_FOREARM := Vector3(0.0, -0.866025, -0.5)
const DEFAULT_CHORD := Vector3(0.0, 0.5, -0.866025)
const SIDE_SIGN := [-1.0, 1.0]
const NECK_OFFSET := Vector3(0.0, -0.08, 0.09)

# --- the prompted capture (FLIGHT_SPEC §5.10, as an explicit step) ---
## The pose must be held this long, unbroken (a one-frame tracking loss, a
## hand moving or a wrist turning starts the hold again).
const NEUTRAL_HOLD := 1.0
## Plausible "spread your wings" (neutral_blocker, one reason per gate):
## grips 0.9-2.3 m apart (closer is not a spread; wider than any wingspan
## is a controller lying somewhere), each out to its own side (within
## NEUTRAL_MAX_SWEEP of straight out), at shoulder height (each arm within
## NEUTRAL_MAX_ELEV of level, the hands within NEUTRAL_MAX_DY of each
## other), the two the same distance from their shoulders within
## NEUTRAL_MAX_ASYM (a body, not one arm spread and a controller on a
## shelf), each controller held the way a hand on a spread arm holds it
## (its forearm axis within AXIS_LIVE of the grip convention: a controller
## held upright like a torch, or turned in the hand, is not), the head
## upright (SPREAD_HEAD_TILT: "stand tall"), and still.
const NEUTRAL_MIN_SPREAD := 0.9
const NEUTRAL_MAX_SPREAD := 2.3
const NEUTRAL_MAX_ELEV := deg_to_rad(25.0)
const NEUTRAL_MAX_DY := 0.12
const NEUTRAL_MAX_SWEEP := deg_to_rad(40.0)
const NEUTRAL_MAX_ASYM := 0.12
const CALM_SPEED := 0.08            ## m/s, hand linear speed
const CALM_ANG_SPEED := deg_to_rad(25.0)
## The capture refuses a forearm axis further than AXIS_REJECT from the grip
## convention (measured from the fitted shoulders); the live check uses the
## shoulders known before the capture and is 5° stricter, so a grip that
## would be refused is asked about on the card instead of failing the step.
const AXIS_REJECT := deg_to_rad(45.0)
const AXIS_LIVE := deg_to_rad(40.0)
const SEATED_HEAD_Y := 1.30
## Tall players sit with their eyes above 1.30 m (a 2.0 m span: ~1.40 m on
## a chair), so once the span is known the threshold is also relative to
## the stature it implies: seated below 0.75 of it (standing eyes are at
## ~0.935, seated ones at ~0.455 m + 0.44 of it), standing again above
## 0.80 (fix round 3: a verifier's seated grid found spans >= 1.8 m never
## detected).
const SEATED_EYE_FRACTION := 0.75
const STANDING_EYE_FRACTION := 0.80
## Once the standing eye height has been measured (at a standing capture)
## it bounds both thresholds: seated means eyes this far below it, standing
## again within this of it (fix round 4). A span-derived stature alone
## overshoots for long-armed players (ape index 1.08, span 1.90 m, stature
## 1.76 m: "standing again" at 1.648 m sat above their own 1.646 m eyes,
## and a 15 cm dip read as seated), and any error in the span moved it.
## Seated eyes are 0.29-0.62 m below standing ones for statures
## 1.5-2.16 m.
const SEATED_BELOW_STANDING := 0.20
const STANDING_BELOW_STANDING := 0.10
const SEATED_HOLD := 5.0
# --- continuous span refinement (fix round 4) ---
## The span may only be learnt from a genuine spread-arms pose. Round 3's
## rule took ANY grip-to-grip distance wider than the span for 0.5 s, so a
## controller set down on a table 2 m away persisted a 2 m span (the bird
## shrank 23 %, the extension readings changed, a standing player became
## "seated"), and so did a spread in the pause menu. A sample now counts
## only when both grips are within SPREAD_DY of their shoulder's height,
## each out to its own side (sweep within SPREAD_SWEEP), each 0.85-1.3 arm
## lengths from its own shoulder, the two reaches within SPREAD_ASYM (so
## the grips are symmetric about the neck pivot), the hands slow, the head
## upright (the neck-pivot shoulder model assumes an upright torso; a
## turned head is fine, the pivot follows it), and the owner says the game
## is focused and running (refine_allowed).
const SPREAD_DY := 0.25
const SPREAD_SWEEP := deg_to_rad(30.0)
const SPREAD_REACH_MIN := 0.85
const SPREAD_REACH_MAX := 1.30
const SPREAD_ASYM := 0.08
const SPREAD_CALM := 0.25
const SPREAD_HEAD_TILT := deg_to_rad(30.0)
const SPREAD_HEAD_UP := 0.8660254   ## cos(SPREAD_HEAD_TILT)
## One spread: qualifying samples for at least this long without a break;
## its value is a high percentile of its samples (never one frame's max).
const SPAN_GROW_HOLD := 0.5
const SPAN_PERCENTILE := 0.8
const SPREAD_MAX_SAMPLES := 512
## Growth needs this many separate spreads that agree (the value used is
## the lowest of the best SPAN_SPREADS), and at least SPAN_GROW_MARGIN over
## the current span (3 cm is posture and tracker noise).
const SPAN_SPREADS := 2
const SPAN_GROW_MARGIN := 0.05
## The most one session (from a load or a capture) may grow the span: a
## capture a lot too cramped is corrected over sessions, an odd event can
## never run away with it. A manual recalibration starts a new session.
const SPAN_SESSION_MAX := 0.10
# --- body proportions for the shoulder estimate (stature H) ---
## Eyes-to-shoulder-joint drop per unit stature, and standing eye height per
## unit stature (adult anthropometry: acromion ~0.82 H, joint centres ~4 cm
## lower, eyes ~0.935 H).
const DROP_PER_STATURE := 0.15
const EYE_PER_STATURE := 0.935
## Stature ~ grip-to-grip span + fingertip allowance (ape index ~1).
const SPAN_TO_STATURE := 0.16
## Weight of the eye-height estimate when standing (the arm span carries
## the ape-index spread, sd ~5 cm; eye height ~2 cm incl. floor error).
const EYE_WEIGHT := 0.8
## The eye and span estimates must agree within this, else the floor or the
## posture is off (seated, crouching, bad guardian floor): span only.
const STATURE_AGREE := 0.25
## Arm elevations people use when told "spread your wings": the drop is
## kept consistent with the hand line under this range.
const CAPTURE_ELEV_MIN := deg_to_rad(-20.0)
const CAPTURE_ELEV_MAX := deg_to_rad(12.0)
## Velocity estimate smoothing: raw finite differences of 0.7 mm tracker
## noise at 90 Hz read ~0.06 m/s, too close to CALM_SPEED.
const VEL_TAU := 0.15
## A fresh capture's glide reach and fold elevation (FLIGHT_SPEC §5.11
## defaults; the optional glide step that personalised them went with the
## redesign: the calibration is one explicit step).
const DEFAULT_GLIDE_REACH := 0.62
const DEFAULT_FOLD_ELEVATION := deg_to_rad(-62.0)

# --- calibration (the WingCalibration fields, FLIGHT_SPEC §5.11) ---
var arm_span := 1.50
var shoulder_width := 0.345
var shoulder_drop := 0.24
var neutral: Array[Basis] = [VRHumanPose.airplane_basis(0), VRHumanPose.airplane_basis(1)]
var forearm_axis: Array[Vector3] = [DEFAULT_FOREARM, DEFAULT_FOREARM]
var chord_axis: Array[Vector3] = [DEFAULT_CHORD, DEFAULT_CHORD]
var glide_reach := DEFAULT_GLIDE_REACH
var fold_elevation := DEFAULT_FOLD_ELEVATION
var stroke_full_rate := 4.5
var stroke_full_arc := deg_to_rad(35.0)
var seated := false
var calibrated := false
## Settings.seated forces seated mode regardless of detection.
var seated_setting := false
## Eye height (head level) measured at a standing capture, m; -1 unknown
## (calibrated seated, or saved before fix round 4). Persisted.
var standing_eye := -1.0
## A requested capture is running (request_capture .. captured / rejected
## / cancel_capture). Nothing else ever captures.
var capturing := false
## Set by the owner every tick: the span may be refined from a spread now
## (the game is focused, not paused, not in a menu). Off by default: a new
## caller cannot fall into refining from menu poses silently.
var refine_allowed := false

# --- span refinement state ---
## The span this session started from (load or capture): growth is
## bounded relative to it.
var span_session_base := 1.50
## Why this tick's sample did not count ("" when it did), for tests/logs.
var spread_blocker := "not calibrated"
var _spread_t := 0.0
var _spread_samples := PackedFloat32Array()
## Values of the best completed spreads this session, highest first.
var _spread_best: Array[float] = []

# --- measurements (updated by measure()) ---
var body_yaw := 0.0
var body_basis := Basis.IDENTITY
var shoulders: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var hands: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var head := Transform3D.IDENTITY
var reach: Array[float] = [0.0, 0.0]          ## r_c, fraction of arm length
var elevation: Array[float] = [0.0, 0.0]      ## δ, rad
var sweep: Array[float] = [0.0, 0.0]          ## s, rad
var extension: Array[float] = [1.0, 1.0]      ## 0 tucked .. 1 spread (unfiltered)
var twist: Array[float] = [0.0, 0.0]          ## rad from calibrated neutral, + = LE up
var twist_conf: Array[float] = [1.0, 1.0]
var hand_speed: Array[float] = [0.0, 0.0]
var hand_ang_speed: Array[float] = [0.0, 0.0]
var valid: Array[bool] = [false, false]
var head_valid := false

# --- capture state ---
var capture_hold := 0.0
var last_reject := ""
var _samples: Array[Dictionary] = []
var _samples_t := 0.0
var _prev: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _vel: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _angvel: Array[float] = [0.0, 0.0]
var _have_prev := false
var _yaw_init := false
var _seated_timer := 0.0
var _standing_timer := 0.0


func arm_length() -> float:
	return (arm_span - shoulder_width) * 0.5


## R_HI: the reach that counts as fully spread (seated players reach less).
func full_reach() -> float:
	return minf(glide_reach, 0.58) if is_seated() else glide_reach


func is_seated() -> bool:
	return seated or seated_setting


# =============================================================================
# Measurement
# =============================================================================

## One tick. Poses are tracking-space transforms (grip pose for the hands).
## valid_mask: bit 0 head, bit 1 left, bit 2 right.
func measure(p_head: Transform3D, left: Transform3D, right: Transform3D, valid_mask: int, dt: float) -> void:
	dt = clampf(dt, 1e-4, 1.0 / 30.0)
	head_valid = (valid_mask & 1) != 0 and VRMath.pose_sane(p_head)
	valid[0] = (valid_mask & 2) != 0 and VRMath.pose_sane(left)
	valid[1] = (valid_mask & 4) != 0 and VRMath.pose_sane(right)
	if head_valid:
		head = p_head
	if valid[0]:
		hands[0] = left
	if valid[1]:
		hands[1] = right
	_update_velocities(dt)
	_update_body_yaw(dt)
	_update_shoulders()
	for i in 2:
		_measure_wing(i)
	_update_seated(dt)
	_update_capture(dt)
	_update_refinement(dt)


func _update_velocities(dt: float) -> void:
	var k := VRMath.lp(dt, VEL_TAU)
	# Angular speed only matters to the capture's "hold still" test.
	var need_ang := capturing
	for i in 2:
		if _have_prev and valid[i]:
			var v := (hands[i].origin - _prev[i].origin) / dt
			_vel[i] = _vel[i].lerp(v, k)
			if need_ang:
				_angvel[i] = lerpf(_angvel[i], VRMath.basis_angle(_prev[i].basis, hands[i].basis) / dt, k)
		hand_speed[i] = _vel[i].length()
		hand_ang_speed[i] = _angvel[i]
		_prev[i] = hands[i]
	_have_prev = true


## Torso yaw (FLIGHT_SPEC §5.2): follow the hand line when the arms are
## apart, otherwise hold and drift towards the gaze; never > 70° from it.
func _update_body_yaw(dt: float) -> void:
	var phi_head := VRMath.yaw_of(VRMath.head_forward(head.basis))
	var w := VRMath.horiz(hands[1].origin - hands[0].origin)
	var c := 0.0
	var phi_w := body_yaw
	if valid[0] and valid[1] and w.length() > 1e-3:
		phi_w = VRMath.yaw_of(Vector3.UP.cross(w).normalized())
		c = VRMath.sstep(0.35, 0.75, w.length() / arm_span)
		# Crossed arms flip the hand line by ~180°: only accept a big jump if
		# the head agrees (a real turn made while tucked).
		if _yaw_init and absf(VRMath.wrap_angle(phi_w - body_yaw)) > deg_to_rad(75.0) \
				and absf(VRMath.wrap_angle(phi_w - phi_head)) > deg_to_rad(40.0):
			c = 0.0
	if not _yaw_init:
		body_yaw = phi_w if c > 0.5 else phi_head
		_yaw_init = true
	else:
		body_yaw += VRMath.wrap_angle(phi_w - body_yaw) * (1.0 - exp(-dt * c / 0.10))
		var e := VRMath.wrap_angle(phi_head - body_yaw)
		var lim := deg_to_rad(70.0)
		if absf(e) > lim:
			body_yaw += signf(e) * (absf(e) - lim) * VRMath.lp(dt, 0.5 if c > 0.5 else 2.0)
		body_yaw += VRMath.wrap_angle(phi_head - body_yaw) * (1.0 - c) * VRMath.lp(dt, 4.0)
	body_yaw = VRMath.wrap_angle(body_yaw)
	body_basis = Basis(Vector3.UP, body_yaw)


func _update_shoulders() -> void:
	var f := body_basis * Vector3.FORWARD
	var rt := body_basis * Vector3.RIGHT
	var neck := head.origin + head.basis * NECK_OFFSET
	var centre := neck + Vector3(0.0, -(shoulder_drop + NECK_OFFSET.y), 0.0) - f * 0.02
	shoulders[0] = centre - rt * (shoulder_width * 0.5)
	shoulders[1] = centre + rt * (shoulder_width * 0.5)


func _measure_wing(i: int) -> void:
	var s: float = SIDE_SIGN[i]
	var f := body_basis * Vector3.FORWARD
	var rt := body_basis * Vector3.RIGHT
	var a := hands[i].origin - shoulders[i]
	var x_out := s * a.dot(rt)
	var y := a.y
	var z := a.dot(f)
	var xo := maxf(x_out, 0.05)
	reach[i] = sqrt(maxf(x_out, 0.0) ** 2 + y * y) / maxf(arm_length(), 0.1)
	elevation[i] = atan2(y, xo)
	sweep[i] = atan2(z, xo)
	extension[i] = extension_for(reach[i], elevation[i], sweep[i])
	# Wrist twist: rotation since the calibrated neutral, in the controller's
	# own frame, decomposed about the calibrated forearm axis.
	var r := body_basis.inverse() * hands[i].basis
	var q := (neutral[i].transposed() * r).get_rotation_quaternion()
	var tw := VRMath.twist_about(q, forearm_axis[i])
	if tw.y >= 0.25:
		twist[i] = side_twist_sign(i) * tw.x
	twist_conf[i] = tw.y


## Extension (FLIGHT_SPEC §5.5): reach, arms hanging down, hands behind.
func extension_for(r_c: float, delta: float, s: float) -> float:
	var e_reach := VRMath.sstep(0.30, full_reach(), r_c)
	var e_low: float
	if is_seated():
		e_low = VRMath.sstep(deg_to_rad(-75.0), deg_to_rad(-55.0), delta)
	else:
		e_low = VRMath.sstep(fold_elevation - deg_to_rad(20.0), fold_elevation, delta)
	var e_back := 1.0 - VRMath.sstep(deg_to_rad(-35.0), deg_to_rad(-70.0), s)
	return e_reach * e_low * e_back


## + twist means leading edge up on both hands: the sign of the neutral arm
## direction along body-right.
func side_twist_sign(i: int) -> float:
	var outward := neutral[i] * forearm_axis[i]
	return 1.0 if outward.x >= 0.0 else -1.0


## Symmetric pitch command from both wrists (FLIGHT_SPEC §5.9).
func pitch_command() -> float:
	return shape(0.5 * (twist[0] + twist[1]), deg_to_rad(5.0), deg_to_rad(40.0), deg_to_rad(30.0), 1.4)


static func shape(x: float, dz: float, full_pos: float, full_neg: float, expo: float) -> float:
	var a := absf(x) - dz
	if a <= 0.0:
		return 0.0
	var full := full_pos if x > 0.0 else full_neg
	return signf(x) * pow(clampf(a / (full - dz), 0.0, 1.0), expo)


## The hand frame the wings are drawn in: outward along the forearm, up
## normal of the wing, back = trailing edge. Proper rotation for both sides
## (x = outward, y = up, z = x × y).
func hand_frame(i: int) -> Basis:
	var b := hands[i].basis
	var o := (b * forearm_axis[i]).normalized()
	var c := b * chord_axis[i]
	c = (c - o * c.dot(o)).normalized()
	var up := (o.cross(c) * float(SIDE_SIGN[i])).normalized()
	return Basis(o, up, o.cross(up)).orthonormalized()


# =============================================================================
# The prompted capture
# =============================================================================

## Starts the one calibration capture: the player has been shown "Stand
## tall. Spread your wings, hands flat. Hold still." The next plausible,
## still spread held NEUTRAL_HOLD becomes the calibration (captured), or a
## grip that cannot be a real one is refused (rejected). Until then, and
## after cancel_capture(), the calibration held is untouched.
func request_capture() -> void:
	capturing = true
	capture_hold = 0.0
	last_reject = ""
	_clear_samples()


func _clear_samples() -> void:
	_samples.clear()
	_samples_t = 0.0


## Stops a requested capture; the calibration held is kept as it is.
func cancel_capture() -> void:
	capturing = false
	capture_hold = 0.0
	_clear_samples()


## {kind, progress 0..1, active, calibrated, rejected_reason}
func capture_status() -> Dictionary:
	return {"kind": &"neutral" if capturing else &"none", "progress": clampf(capture_hold / NEUTRAL_HOLD, 0.0, 1.0),
		"active": capturing, "calibrated": calibrated, "rejected_reason": last_reject}


## Why this tick's pose is not (yet) the plausible, still "spread your
## wings, hands flat" the capture needs, or "" when it is (the reason is
## the card's hint, so it says what to do).
func neutral_blocker() -> String:
	if not (valid[0] and valid[1] and head_valid):
		return "tracking"
	var gap := (hands[1].origin - hands[0].origin).length()
	if gap <= NEUTRAL_MIN_SPREAD:
		return "spread your arms wider"
	if gap >= NEUTRAL_MAX_SPREAD:
		return "hold a controller in each hand"
	# Each grip out to its own side of the head (the player looks ahead; the
	# torso frame follows the hand line, so it cannot tell swapped
	# controllers from a spread): both on the wrong side is the left
	# controller in the right hand and vice versa.
	var hr := VRMath.horiz(VRMath.head_forward(head.basis)).normalized().cross(Vector3.UP)
	var neck := head.origin + head.basis * NECK_OFFSET
	var out_l := -(hands[0].origin - neck).dot(hr)
	var out_r := (hands[1].origin - neck).dot(hr)
	if out_l < 0.0 and out_r < 0.0:
		return "controllers in the wrong hands?"
	if out_l <= 0.0 or out_r <= 0.0 or absf(sweep[0]) > NEUTRAL_MAX_SWEEP or absf(sweep[1]) > NEUTRAL_MAX_SWEEP:
		return "spread your arms out to the sides"
	if absf(elevation[0]) >= NEUTRAL_MAX_ELEV or absf(elevation[1]) >= NEUTRAL_MAX_ELEV:
		return "hold your arms level"
	if absf(hands[0].origin.y - hands[1].origin.y) >= NEUTRAL_MAX_DY:
		return "hold both hands at the same height"
	if absf((hands[0].origin - shoulders[0]).length() - (hands[1].origin - shoulders[1]).length()) > NEUTRAL_MAX_ASYM:
		return "spread both arms evenly"
	for i in 2:
		if grip_axis_error(i) > AXIS_LIVE:
			return "hold the controllers as usual"
	if head.basis.y.y < SPREAD_HEAD_UP * head.basis.y.length():
		return "stand tall, look ahead"
	if maxf(hand_speed[0], hand_speed[1]) >= CALM_SPEED or maxf(hand_ang_speed[0], hand_ang_speed[1]) >= CALM_ANG_SPEED:
		return "hold still"
	return ""


## How far (rad) the forearm axis this grip shows now (the arm's line from
## its shoulder, in the controller's frame) is from the grip convention.
func grip_axis_error(i: int) -> float:
	var arm := hands[i].origin - shoulders[i]
	if arm.length() < 1e-3:
		return PI
	return (hands[i].basis.transposed() * arm.normalized()).angle_to(DEFAULT_FOREARM)


func _update_capture(dt: float) -> void:
	if not capturing:
		return
	if neutral_blocker() != "":
		capture_hold = 0.0
		_clear_samples()
		return
	capture_hold += dt
	_samples.append({"h": head, "l": hands[0], "r": hands[1], "dt": dt})
	_samples_t += dt
	# Keep only the hold window (the capture averages over it): a running
	# total, oldest out first.
	while _samples.size() > 1 and _samples_t > NEUTRAL_HOLD + 0.05:
		_samples_t -= float(_samples[0]["dt"])
		_samples.pop_front()
	if capture_hold >= NEUTRAL_HOLD:
		_finish_neutral()


## The hold is complete: the body and the wrist neutral from its average.
## A fresh calibration of whoever holds the controllers now: the seating is
## judged by this capture alone (the timers ran against the previous
## calibration's thresholds, possibly someone else's), and the glide reach
## and fold elevation go back to their defaults.
func _finish_neutral() -> void:
	var n := float(_samples.size())
	var pl := Vector3.ZERO
	var pr := Vector3.ZERO
	var hp := Vector3.ZERO
	var bl: Array[Basis] = []
	var br: Array[Basis] = []
	var bh: Array[Basis] = []
	for smp in _samples:
		pl += (smp["l"] as Transform3D).origin
		pr += (smp["r"] as Transform3D).origin
		hp += (smp["h"] as Transform3D).origin
		bl.append((smp["l"] as Transform3D).basis)
		br.append((smp["r"] as Transform3D).basis)
		bh.append((smp["h"] as Transform3D).basis)
	pl /= n
	pr /= n
	hp /= n
	var rl := VRMath.mean_basis(bl)
	var rr := VRMath.mean_basis(br)
	var hb := VRMath.mean_basis(bh)
	_clear_samples()
	capture_hold = 0.0

	var fw := Vector3.UP.cross(VRMath.horiz(pr - pl)).normalized()
	var b := Basis(Vector3.UP, VRMath.yaw_of(fw))
	var neck := hp + hb * NECK_OFFSET
	var fit := fit_body(pl, pr, neck, b, seated_setting)
	# Eyes lower than 0.75 of the stature this span implies, while holding a
	# still spread: the player is sitting (a tall player on a chair keeps
	# the eyes above the absolute 1.30 m; a child standing is well above
	# 0.75 of their own stature).
	var eye_level := neck.y - NECK_OFFSET.y
	var seated_now := eye_level < SEATED_EYE_FRACTION * (float(fit["span"]) + SPAN_TO_STATURE)
	if seated_now and not seated_setting:
		fit = fit_body(pl, pr, neck, b, true)
	var geom := _capture_geometry(fit, pl, pr, (b.inverse() * rl).orthonormalized(), (b.inverse() * rr).orthonormalized(), b)
	if geom.is_empty():
		_reject(&"neutral", "the controllers were held in an unusual way")
		return
	_commit_geometry(geom)
	glide_reach = DEFAULT_GLIDE_REACH
	fold_elevation = DEFAULT_FOLD_ELEVATION
	# Detected seated play (at the capture; later the 5 s timers); the
	# Settings preference is applied on top by is_seated().
	seated = seated_now
	_seated_timer = SEATED_HOLD if seated_now else 0.0
	_standing_timer = 0.0
	# The standing eyes (head level) bound the seated thresholds from now on;
	# a seated capture (detected, or with the seated preference on: the
	# player may well be sitting) cannot know them.
	standing_eye = -1.0 if seated_now or seated_setting else eye_level
	calibrated = true
	capturing = false
	captured.emit(&"neutral")


## The body behind a still "spread your wings" pose: shoulder height (the
## anthropometric drop, estimate_drop), shoulder width (0.23 x span) and the
## arm span, where the span is the true full spread (width + 2 x the
## shoulder-to-grip distance) rather than the grip-to-grip distance as held:
## arms held 12° low or hands 10° forward bring the grips 1-2 cm closer
## together than a full spread, which made a half fold read up to 0.03 more
## extension for those capture styles. Width and span depend on each other
## (the shoulders sit at +-width/2), so this iterates; it converges in two.
## pl, pr: grip positions; neck: the neck pivot; b: body basis (yaw).
## Returns {span, width, drop, s_l, s_r}.
static func fit_body(pl: Vector3, pr: Vector3, neck: Vector3, b: Basis, seated_now: bool) -> Dictionary:
	var fw := b * Vector3.FORWARD
	var rt := b * Vector3.RIGHT
	# Eye height with the head level (the neck pivot does not move when the
	# player looks at a hand; the eyes do).
	var eye_level := neck.y - NECK_OFFSET.y
	var hands_y := 0.5 * (pl.y + pr.y)
	var span := clampf((pr - pl).length(), 1.0, 2.2)
	var out := {}
	for it in 3:
		var width := 0.23 * span
		var l_arm := (span - width) * 0.5
		var drop := estimate_drop(eye_level, hands_y, span, l_arm, seated_now)
		var centre := neck + Vector3(0.0, -(drop + NECK_OFFSET.y), 0.0) - fw * 0.02
		var s_l := centre - rt * (width * 0.5)
		var s_r := centre + rt * (width * 0.5)
		out = {"span": span, "width": width, "drop": drop, "s_l": s_l, "s_r": s_r}
		var reach := 0.5 * ((pl - s_l).length() + (pr - s_r).length())
		# span = width + 2 reach with width = 0.23 span.
		span = clampf(2.0 * reach / (1.0 - 0.23), 1.0, 2.2)
	return out


## Writes a fitted body and the forearm / chord axes and canonical neutrals
## derived from it. rl_body / rr_body: the controller bases in the body
## frame; b: the body basis (positions are in the same space as the fit).
## False (nothing written) if a forearm axis is > 45° from the grip
## convention (swapped controllers, an odd grip).
func _take_capture(fit: Dictionary, pl: Vector3, pr: Vector3, rl_body: Basis, rr_body: Basis, b: Basis) -> bool:
	var geom := _capture_geometry(fit, pl, pr, rl_body, rr_body, b)
	if geom.is_empty():
		return false
	_commit_geometry(geom)
	return true


## What a capture would write, without writing it: {span, width, drop,
## axis, chord, neutral (Arrays, left then right)}. Empty if a forearm axis
## is > 45° from the grip convention.
func _capture_geometry(fit: Dictionary, pl: Vector3, pr: Vector3, rl_body: Basis, rr_body: Basis, b: Basis) -> Dictionary:
	var new_axis: Array[Vector3] = []
	var new_chord: Array[Vector3] = []
	var new_neutral: Array[Basis] = []
	var sides := [[rl_body, pl, fit["s_l"]], [rr_body, pr, fit["s_r"]]]
	for i in 2:
		var r: Basis = sides[i][0]
		var arm_body := b.inverse() * ((sides[i][1] as Vector3) - (sides[i][2] as Vector3))
		var a_local: Vector3 = (r.transposed() * arm_body.normalized()).normalized()
		if a_local.angle_to(DEFAULT_FOREARM) > AXIS_REJECT:
			return {}
		var c_local: Vector3 = r.transposed() * Vector3.FORWARD
		c_local = (c_local - a_local * c_local.dot(a_local)).normalized()
		new_axis.append(a_local)
		new_chord.append(c_local)
		new_neutral.append(canonical_neutral(i, r, a_local))
	return {"span": float(fit["span"]), "width": float(fit["width"]), "drop": float(fit["drop"]),
		"axis": new_axis, "chord": new_chord, "neutral": new_neutral}


func _commit_geometry(geom: Dictionary) -> void:
	arm_span = geom["span"]
	shoulder_width = geom["width"]
	shoulder_drop = geom["drop"]
	var a: Array[Vector3] = []
	a.assign(geom["axis"])
	var c: Array[Vector3] = []
	c.assign(geom["chord"])
	var n: Array[Basis] = []
	n.assign(geom["neutral"])
	forearm_axis = a
	chord_axis = c
	neutral = n
	begin_refinement_session()


## The arm direction every neutral is expressed at: straight out, 5° low
## (the pose FLIGHT_SPEC §5.10 assumes people hold), in the body frame.
static func canonical_arm(i: int) -> Vector3:
	return Vector3(float(SIDE_SIGN[i]) * cos(deg_to_rad(5.0)), -sin(deg_to_rad(5.0)), 0.0)


## The captured neutral moved to the canonical arm direction by a pure
## swing (a rotation perpendicular to the forearm), so it keeps exactly the
## player's wrist habit but forgets how high or far forward the arms were
## held at capture. Without this, swing-twist (§5.7) of a later gesture
## depends on the capture pose: a half fold read a pitch command of 0.29
## after a textbook capture and 0.01-0.56 after captures 12° low to 8° high.
## n_body: controller basis in the body frame; a_local: forearm axis in the
## controller frame.
static func canonical_neutral(i: int, n_body: Basis, a_local: Vector3) -> Basis:
	var d := (n_body * a_local).normalized()
	var swing := Basis(Quaternion(d, canonical_arm(i)))
	return (swing * n_body).orthonormalized()


## Eyes-to-shoulder drop at capture (refines FLIGHT_SPEC §5.10, which
## assumes the arms 5° low): from stature (eye height when standing, blended
## with the arm span; span alone when seated or when the two disagree),
## then kept consistent with the hand line: the arms must have been held
## between CAPTURE_ELEV_MIN and CAPTURE_ELEV_MAX of level.
## eye_level: eye height with a level head; hands_y: mean grip height.
static func estimate_drop(eye_level: float, hands_y: float, span: float, l_arm: float, seated: bool) -> float:
	var h_span := span + SPAN_TO_STATURE
	var stature := h_span
	if not seated and eye_level >= SEATED_HEAD_Y:
		var h_eye := eye_level / EYE_PER_STATURE
		if absf(h_eye - h_span) < STATURE_AGREE:
			stature = EYE_WEIGHT * h_eye + (1.0 - EYE_WEIGHT) * h_span
	var drop := DROP_PER_STATURE * stature
	# Hand line: hands at elevation θ put the shoulders at hands_y - L sin θ.
	var rel := eye_level - hands_y
	drop = clampf(drop, rel + l_arm * sin(CAPTURE_ELEV_MIN), rel + l_arm * sin(CAPTURE_ELEV_MAX))
	return clampf(drop, 0.15, 0.35)


func _reject(kind: StringName, reason: String) -> void:
	last_reject = reason
	capture_hold = 0.0
	_clear_samples()
	capturing = false
	rejected.emit(kind, reason)


## Eye height with the head level (the neck pivot does not move when the
## player looks down at prey or at a hand; the eyes do).
func level_eye_height() -> float:
	return (head.origin + head.basis * NECK_OFFSET).y - NECK_OFFSET.y


## Eye heights (level head) below which the player counts as seated (x) and
## above which as standing again (y): 1.30 / 1.40 m, raised for tall
## players to 0.75 / 0.80 of the stature the span implies (fix round 3),
## and once the standing eyes were measured, never above 20 / 10 cm under
## them (fix round 4: the span alone could put "standing again" above a
## long-armed player's own eyes, who then stayed "seated" for good).
func seat_thresholds() -> Vector2:
	var sit := SEATED_HEAD_Y
	var stand := SEATED_HEAD_Y + 0.10
	if calibrated:
		var stature := arm_span + SPAN_TO_STATURE
		sit = maxf(sit, SEATED_EYE_FRACTION * stature)
		stand = maxf(stand, STANDING_EYE_FRACTION * stature)
	if standing_eye > 0.0:
		sit = minf(sit, standing_eye - SEATED_BELOW_STANDING)
		stand = minf(stand, standing_eye - STANDING_BELOW_STANDING)
	return Vector2(sit, stand)


## Seated detection with hysteresis (seat_thresholds): below the seated
## height for 5 s means seated, above the standing one for 5 s standing
## again. Only a calibrated player's flag changes (the capture itself also
## samples it), so a player who sat down right after calibrating is still
## picked up.
func _update_seated(dt: float) -> void:
	if not head_valid:
		return
	var eye := level_eye_height()
	var th := seat_thresholds()
	if eye < th.x:
		_seated_timer += dt
		_standing_timer = 0.0
	elif eye > th.y:
		_standing_timer += dt
		_seated_timer = 0.0
	if calibrated:
		if not seated and _seated_timer >= SEATED_HOLD:
			seated = true
			refined.emit(arm_span)
		elif seated and _standing_timer >= SEATED_HOLD:
			seated = false
			refined.emit(arm_span)


## Starts a refinement session: growth is bounded relative to the span now,
## and earlier spreads no longer count (a load, a capture, an adoption).
func begin_refinement_session() -> void:
	span_session_base = arm_span
	_spread_best.clear()
	_spread_t = 0.0
	_spread_samples.clear()


## The full spread (m) this tick's pose shows, or -1 with spread_blocker
## set when it is not a genuine spread-arms pose (see SPREAD_*). With the
## shoulders at the current width w, a straight arm's grip is at reach r
## from its shoulder, so the full spread is w + r_left + r_right: exactly
## the captured span for the captured pose (fit_body's relation, width
## 0.23 x span), whatever width is assumed.
func spread_span_sample() -> float:
	# Cheapest and most often failing first (a flapping player: every tick).
	spread_blocker = ""
	if not calibrated:
		spread_blocker = "not calibrated"
	elif not refine_allowed:
		spread_blocker = "not now (paused, menu, unfocused)"
	elif not (valid[0] and valid[1] and head_valid):
		spread_blocker = "tracking"
	elif hand_speed[0] >= SPREAD_CALM or hand_speed[1] >= SPREAD_CALM:
		spread_blocker = "hands moving"
	elif head.basis.y.y < SPREAD_HEAD_UP * head.basis.y.length():
		# Bent over or reclining: the torso is no longer upright under the
		# neck pivot, so the shoulder estimate is off.
		spread_blocker = "head tilted"
	if spread_blocker != "":
		return -1.0
	var rt := body_basis * Vector3.RIGHT
	var l := arm_length()
	var r: Array[float] = [0.0, 0.0]
	for i in 2:
		var a := hands[i].origin - shoulders[i]
		r[i] = a.length()
		if absf(a.y) > SPREAD_DY:
			spread_blocker = "not at shoulder height"
		elif float(SIDE_SIGN[i]) * a.dot(rt) <= 0.0 or absf(sweep[i]) > SPREAD_SWEEP:
			spread_blocker = "not out to the side"
		elif r[i] < SPREAD_REACH_MIN * l or r[i] > SPREAD_REACH_MAX * l:
			spread_blocker = "out of arm's reach"
		if spread_blocker != "":
			return -1.0
	# Symmetric about the body: the shoulders sit either side of the neck
	# pivot, so equal reaches also centre the grips on the head.
	if absf(r[0] - r[1]) > SPREAD_ASYM:
		spread_blocker = "uneven"
		return -1.0
	return shoulder_width + r[0] + r[1]


## Continuous refinement (refines FLIGHT_SPEC §5.10's "span grows, never
## shrinks"; fix round 4): only genuine spreads count (spread_span_sample),
## each spread is summarised by a high percentile of its samples, growth
## needs SPAN_SPREADS separate spreads above the span + margin, and a
## session grows it by SPAN_SESSION_MAX at most. It never shrinks: a
## smaller player recalibrates (Settings > Recalibrate wings, Y-hold).
func _update_refinement(dt: float) -> void:
	var s := spread_span_sample()
	if s > 0.0:
		_spread_t += dt
		if _spread_samples.size() < SPREAD_MAX_SAMPLES:
			_spread_samples.append(s)
		return
	if _spread_t >= SPAN_GROW_HOLD and not _spread_samples.is_empty():
		_close_spread()
	_spread_t = 0.0
	_spread_samples.clear()


func _close_spread() -> void:
	var v := _spread_samples.duplicate()
	v.sort()
	var value := v[clampi(int(floor(SPAN_PERCENTILE * (v.size() - 1))), 0, v.size() - 1)]
	_spread_best.append(value)
	_spread_best.sort()
	_spread_best.reverse()
	if _spread_best.size() > SPAN_SPREADS:
		_spread_best.resize(SPAN_SPREADS)
	if _spread_best.size() < SPAN_SPREADS:
		return
	var agreed: float = _spread_best[SPAN_SPREADS - 1]
	if agreed <= arm_span + SPAN_GROW_MARGIN:
		return
	var grown := minf(minf(agreed, span_session_base + SPAN_SESSION_MAX), 2.2)
	if grown <= arm_span + 1e-4:
		return
	arm_span = grown
	shoulder_width = 0.23 * grown
	refined.emit(arm_span)


# =============================================================================
# Persistence and the flight area's WingCalibration resource
# =============================================================================

const FIELDS := ["arm_span", "shoulder_width", "shoulder_drop", "glide_reach", "fold_elevation",
	"stroke_full_rate", "stroke_full_arc", "seated", "calibrated"]


## The WingCalibration fields by name (FLIGHT_SPEC §5.11), Basis/Vector3
## as native values: Settings persists through ConfigFile, which stores
## them, and a Resource-field from_dict can assign them directly.
## from_dict also accepts flat arrays (JSON-safe) for the same keys.
func to_dict() -> Dictionary:
	var d := {"version": 1}
	for f in FIELDS:
		d[f] = get(f)
	d["neutral_left"] = neutral[0]
	d["neutral_right"] = neutral[1]
	d["forearm_axis_left"] = forearm_axis[0]
	d["forearm_axis_right"] = forearm_axis[1]
	d["chord_axis_left"] = chord_axis[0]
	d["chord_axis_right"] = chord_axis[1]
	# VR's own (not a WingCalibration field): bounds the seated thresholds.
	d["standing_eye"] = standing_eye
	return d


## The rotations and axes of the saved dict, by key.
const BASIS_KEYS := {"neutral_left": 0, "neutral_right": 1}
const AXIS_KEYS := {"forearm_axis_left": [0, true], "forearm_axis_right": [1, true],
	"chord_axis_left": [0, false], "chord_axis_right": [1, false]}


## A saved rotation as a Basis, or null when it cannot be one: not 9
## finite numbers, or not close to a rotation (determinant outside
## 0.5..2: singular, mirrored or garbage).
static func sane_basis(v: Variant) -> Variant:
	var b := VRMath.array_to_basis(v, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO))
	var d := b.determinant()
	if not is_finite(d) or d < 0.5 or d > 2.0:
		return null
	b = b.orthonormalized()
	return b if is_finite(b.determinant()) and absf(b.determinant() - 1.0) < 1e-3 else null


## A saved axis as a unit Vector3, or null when it cannot be one (not 3
## finite numbers, or far from unit length).
static func sane_axis(v: Variant) -> Variant:
	var a := VRMath.array_to_vec(v, Vector3.ZERO)
	var n := a.length()
	if not is_finite(n) or n < 0.5 or n > 2.0:
		return null
	return a / n


func from_dict(d: Dictionary) -> bool:
	if d.is_empty():
		return false
	for f in FIELDS:
		if d.has(f):
			var v: Variant = d[f]
			if typeof(get(f)) == TYPE_BOOL:
				set(f, bool(v))
			elif is_finite(float(v)):
				# A corrupt value (NaN, INF) keeps the default.
				set(f, float(v))
	var eye := float(d.get("standing_eye", -1.0))
	standing_eye = eye if is_finite(eye) and eye > 1.0 and eye < 2.3 else -1.0
	# (A "capture_span" key saved by fix round 6's wearer re-check is
	# ignored.) The wrist neutrals and axes: all or nothing. A corrupt one (NaN, a
	# singular basis, a zero axis) used to be loaded as is and written into
	# flight's WingCalibration: a 20° wrist roll then read 0° with the
	# calibration still "calibrated", so nothing ever repaired it (fix round
	# 4). Now any corrupt one drops them all back to the defaults and marks
	# the calibration uncalibrated: the defaults apply until the player's
	# prompted calibration (VRCalibration asks, as on a first launch), and
	# VR never pushes defaults into flight.
	var nb: Array[Basis] = neutral.duplicate()
	var fa: Array[Vector3] = forearm_axis.duplicate()
	var ca: Array[Vector3] = chord_axis.duplicate()
	var bad: Array[String] = []
	for key: String in BASIS_KEYS:
		if d.has(key):
			var b: Variant = sane_basis(d[key])
			if b == null:
				bad.append(key)
			else:
				nb[BASIS_KEYS[key]] = b
	for key: String in AXIS_KEYS:
		if d.has(key):
			var a: Variant = sane_axis(d[key])
			if a == null:
				bad.append(key)
			elif AXIS_KEYS[key][1]:
				fa[AXIS_KEYS[key][0]] = a
			else:
				ca[AXIS_KEYS[key][0]] = a
	if bad.is_empty():
		neutral = nb
		forearm_axis = fa
		chord_axis = ca
	else:
		print("[vr] saved wing calibration rejected: corrupt %s; using the default wrist neutral and axes until the next capture" % ", ".join(bad))
		neutral = [VRHumanPose.airplane_basis(0), VRHumanPose.airplane_basis(1)]
		forearm_axis = [DEFAULT_FOREARM, DEFAULT_FOREARM]
		chord_axis = [DEFAULT_CHORD, DEFAULT_CHORD]
		calibrated = false
	arm_span = clampf(arm_span, 1.0, 2.2)
	shoulder_width = clampf(shoulder_width, 0.15, 0.55)
	shoulder_drop = clampf(shoulder_drop, 0.15, 0.35)
	begin_refinement_session()
	return true


## Writes every FLIGHT_SPEC §5.11 field the given WingCalibration (or any
## Resource) has; duck-typed: whichever fields exist are filled.
func apply_to(res: Object) -> void:
	if res == null:
		return
	var d := to_dict()
	for f in FIELDS:
		if f in res:
			res.set(f, d[f])
	# Live, seated means detected OR the Settings preference (flight's own
	# loader combines them the same way); the persisted dict keeps only
	# what was detected.
	if "seated" in res:
		res.set("seated", is_seated())
	var natives := {
		"neutral_left": neutral[0], "neutral_right": neutral[1],
		"forearm_axis_left": forearm_axis[0], "forearm_axis_right": forearm_axis[1],
		"chord_axis_left": chord_axis[0], "chord_axis_right": chord_axis[1],
	}
	for f in natives:
		if f in res:
			res.set(f, natives[f])


## Takes over a calibration another capturer made: flight's WingInput
## capturing by FLIGHT_SPEC §5.10 as written (the drop assumes the arms were
## held 5° low; the neutral is the controller basis as held), before VR's
## rig extras claimed the automatic capture or through its own
## begin_calibration. Read as is, a half fold then read an extension of
## 0.09-0.47 and a pitch command of 0 to -0.19 for captures 12° low to 8°
## high (fix round 2, both verifiers). So the stored fields are brought to
## this class's maths (refine_foreign) and are then what VR persists and
## writes back to flight.
## Flight's loader ORs the Settings "seated" preference into its flag, so
## with the preference on that flag says nothing about detection: the
## detected flag is then this calibrator's own (head below 1.30 m for 5 s),
## and the persisted dict never turns a preference into "detected".
## Returns false (nothing changed) when the resource's neutrals or axes are
## corrupt (from_dict rejects them).
func adopt(res: Object) -> bool:
	var detected := seated
	var before := to_dict()
	var was_calibrated := calibrated
	read_from(res)
	if not calibrated:
		from_dict(before)
		calibrated = was_calibrated
		return false
	if seated_setting:
		seated = detected or _seated_timer >= SEATED_HOLD
	var eye := -1.0
	if head_valid:
		eye = level_eye_height()
	refine_foreign(eye)
	# The eyes now bound the seated thresholds (flight's dict has none).
	standing_eye = eye if eye > 1.0 and not is_seated() else -1.0
	calibrated = true
	begin_refinement_session()
	return true


## Brings stored calibration fields to this class's maths using only the
## fields and the standing eye height now (the hold that produced them may
## be long gone). The shoulder model is shared with FLIGHT_SPEC §5.3 (neck
## pivot, width 0.23 x span), so the fields fix where the grips were
## relative to the shoulders the capturer assumed:
##   hand_i = shoulder_i + (neutral_i * forearm_axis_i) scaled to the arm's
##            lateral reach
## From those grips and the eye height, fit_body gives the anthropometric
## drop and the full-spread span, the axes are re-aimed from the new
## shoulders, the chord re-orthogonalised and the neutrals canonicalised:
## exactly what _finish_neutral would have made of that hold. Fields this
## class made itself (every neutral canonical to float precision, ~1e-7
## rad) are left alone; flight's capture never is (with a level head its
## arm sits atan(sin 5°) = 4.981° low, 3.3e-4 rad off, and more for any
## other pose).
## eye_level < 0: unknown (no head tracking): the stored drop is kept, the
## neutrals are still canonicalised about the stored axes.
func refine_foreign(eye_level: float) -> void:
	var ours := true
	for i in 2:
		ours = ours and (neutral[i] * forearm_axis[i]).angle_to(canonical_arm(i)) < 1e-4
	if ours:
		return
	var l_arm := arm_length()
	if eye_level < 0.0:
		for i in 2:
			neutral[i] = canonical_neutral(i, neutral[i], forearm_axis[i])
		return
	# The capture in the body frame (x right, y up, -z forward), neck pivot
	# at the eye height now.
	var neck := Vector3(0.0, eye_level + NECK_OFFSET.y, 0.0)
	var centre := neck + Vector3(0.0, -(shoulder_drop + NECK_OFFSET.y), 0.0) + Vector3(0.0, 0.0, 0.02)
	var grips: Array[Vector3] = []
	for i in 2:
		var d := (neutral[i] * forearm_axis[i]).normalized()
		var s := centre + Vector3(float(SIDE_SIGN[i]) * shoulder_width * 0.5, 0.0, 0.0)
		grips.append(s + d * (l_arm / maxf(absf(d.x), 0.2)))
	var fit := fit_body(grips[0], grips[1], neck, Basis.IDENTITY, is_seated() or _seated_timer >= SEATED_HOLD)
	var old_n := neutral.duplicate()
	if not _take_capture(fit, grips[0], grips[1], old_n[0], old_n[1], Basis.IDENTITY):
		# Axes this far off were never a valid capture: keep them, only
		# canonicalise.
		for i in 2:
			neutral[i] = canonical_neutral(i, old_n[i], forearm_axis[i])


## Reads a WingCalibration back (e.g. one flight loaded or captured itself).
## Its own to_dict() if it has one, else field by field; either way through
## from_dict, so the same sanity checks apply.
func read_from(res: Object) -> void:
	if res == null:
		return
	var d := {}
	if res.has_method("to_dict"):
		var v: Variant = res.call("to_dict")
		if v is Dictionary:
			d = v
	if d.is_empty():
		for f in FIELDS + BASIS_KEYS.keys() + AXIS_KEYS.keys():
			if f in res:
				d[f] = res.get(f)
	from_dict(d)

