class_name BotPoseSource
extends PoseSource
## The bot pilot's body (FLIGHT_SPEC §14.4): FlightAutopilot commands become
## ARM motion of a HumanPoseModel under human limits, and the poses go
## through the same WingInput as a player's. Nothing here writes WingState:
## the flap tilt is whatever the wrist twist makes (no cheating), flap effort
## is realised by real strokes that the detector must credit.
##
## Human limits: reaction delay 120 ms, twist rate <= 360 deg/s, arm angular
## speed <= 8 rad/s, tremor 1.5 mm at 9 Hz, twist noise 1.5 deg.
## Size-aware strokes: small birds quick and short, big birds slow and deep
## (hz = lerp(2.0, 1.0, xn), amplitude = lerp(25, 45, xn) deg).

const DEG := PI / 180.0

var body := HumanPoseModel.new(21)
var pilot: FlightAutopilot
## () -> Dictionary {pos, vel, airspeed, perched}: the kinematic state the
## pilot is allowed to see.
var state_fn: Callable
var calibration: WingCalibration
var delay := 0.12
var twist_rate := 360.0 * DEG
var dz_scale := 1.0
# Novice noise (B2): extra delay, twist tremor, roll over-rotation, stroke
# amplitude jitter and occasional one-sided strokes.
var novice := false
var rng := RandomNumberGenerator.new()

var _queue: Array = []          # [t, pitch, roll, effort, flapping]
var _t := 0.0
var _phase := 0.0
var _stroking := false
var _amp := 0.0
var _hz := 1.0
var _debt := 0.0
var _was_on := false
var _one_side := 0
var _twist := [0.0, 0.0]
var _dih := [0.0, 0.0]
var _cmd := [0.0, 0.0, 0.0, false]


func _init(p_pilot: FlightAutopilot = null, p_state: Callable = Callable(), seed := 21) -> void:
	pilot = p_pilot
	state_fn = p_state
	body.set_seed(seed)
	rng.seed = seed
	body.tremor_mm = 1.5
	body.tremor_hz = 9.0
	body.twist_noise_deg = 1.5


func set_novice(on: bool) -> void:
	novice = on
	delay = 0.15 if on else 0.12
	body.twist_noise_deg = 4.0 if on else 1.5


func sample(out: PoseFrame, dt: float) -> void:
	_t += dt
	body.t = _t
	# --- the pilot decides from what it can see, acted on after the delay
	if pilot != null and state_fn.is_valid():
		var st: Dictionary = state_fn.call()
		pilot.update(st["pos"], st["vel"], st["airspeed"], dt)
		var r := pilot.roll * (1.2 if novice else 1.0)
		_queue.append([_t, pilot.pitch, r, pilot.effort, pilot.flapping])
	while _queue.size() > 1 and _t - float(_queue[1][0]) >= delay:
		_queue.pop_front()
	if not _queue.is_empty() and _t - float(_queue[0][0]) >= delay:
		_cmd = [_queue[0][1], _queue[0][2], _queue[0][3], _queue[0][4]]
	var pitch: float = _cmd[0]
	var roll: float = _cmd[1]
	var effort: float = _cmd[2]
	var flap_on: bool = _cmd[3] and effort > 0.12
	var p := pilot.params
	var xn := clampf((p.x - FlightParams.size_x_for_species(&"sparrow")) / (1.0 - FlightParams.size_x_for_species(&"sparrow")), 0.0, 1.0)
	var hz := lerpf(2.0, 1.0, xn)
	var amp_nom := lerpf(25.0, 45.0, xn) * DEG
	# --- wrists: symmetric twist = pitch, antisymmetric = roll (rate-limited)
	var ts := FlightMath.unshape(clampf(pitch, -1.0, 1.0), 5.0 * DEG * dz_scale, 40.0 * DEG, 30.0 * DEG, 1.4)
	var ta := FlightMath.unshape(clampf(roll, -1.0, 1.0), 4.0 * DEG * dz_scale, 25.0 * DEG, 25.0 * DEG, 1.3)
	var want := [ts + ta, ts - ta]
	for i in 2:
		_twist[i] = move_toward(_twist[i], want[i], twist_rate * dt)
		if novice:
			_twist[i] += 4.0 * DEG * sin(TAU * 8.0 * _t + 1.3 * i) * dt * 8.0
	# --- strokes: whole cycles from level to level (phase x.75: level,
	# moving up; the up earns the arc, the down at x.5 is credited). Effort
	# below the reference is realised the way birds do it, by flap-gliding:
	# full strokes with pauses (an accumulator owes effort x rate strokes);
	# above it the rate rises (<= 1.3x). Slow strokes would be credited
	# little and, once started, block a change of mind for seconds.
	if flap_on:
		if not _was_on:
			_debt = maxf(_debt, 1.0)     # the first stroke starts at once
		_debt = minf(_debt + clampf(effort, 0.0, 1.0) * hz * dt, 1.5)
	else:
		_debt = 0.0
	_was_on = flap_on
	if not _stroking and flap_on and _debt >= 1.0:
		_stroking = true
		_phase = 0.75
		_debt -= 1.0
		_plan_stroke(effort, amp_nom, hz)
	if _stroking:
		_hz = hz * clampf(effort, 1.0, 1.3)
		var prev := _phase
		_phase += _hz * dt
		if floorf(_phase - 0.75) != floorf(prev - 0.75):
			# Back at level, moving up: another cycle, or rest here.
			if flap_on and _debt >= 1.0:
				_debt -= 1.0
				_plan_stroke(effort, amp_nom, hz)
			else:
				_stroking = false
	for i in 2:
		var side := -1 if i == 0 else 1
		if _stroking and (_one_side == 0 or _one_side == side):
			_dih[i] = _amp * cos(TAU * _phase)
		else:
			# Back to level slowly (below the detector's downstroke threshold).
			_dih[i] = move_toward(_dih[i], 0.0, 0.4 * dt)
	for i in 2:
		var a := body.arms[i]
		a.twist = _twist[i]
		a.dihedral = _dih[i]
		a.sweep = 0.0
		a.elbow = 0.0
		a.fold = 0.0
	body.grip = Vector2(1, 1) if pilot != null and pilot.grip else Vector2.ZERO
	body.frame(out)


func _plan_stroke(effort: float, amp_nom: float, hz_nom: float) -> void:
	var k := clampf(0.9 + 0.2 * effort, 0.9, 1.1)
	if novice:
		k *= rng.randf_range(0.7, 1.3)
	_amp = amp_nom * k
	_hz = hz_nom * clampf(effort, 1.0, 1.3)
	_one_side = 0
	if novice and rng.randf() < 0.1:
		_one_side = -1 if rng.randf() < 0.5 else 1


func drives_nodes() -> bool:
	return true


func reset() -> void:
	_queue.clear()
	_stroking = false
	_t = 0.0
