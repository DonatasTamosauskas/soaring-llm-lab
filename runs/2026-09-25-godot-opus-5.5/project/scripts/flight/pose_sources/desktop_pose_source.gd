class_name DesktopPoseSource
extends PoseSource
## Keyboard, mouse and gamepad animate VIRTUAL ARMS (FLIGHT_SPEC §13); the
## poses go through the same WingInput as a headset. It never writes
## WingState, so desktop play exercises the real input chain.
##
##   W / S        both wrists leading edge down / up (pitch - / +, flap tilt)
##   A / D        airplane arms: opposite wrist twist plus arm tilt (roll)
##   Space        flap (hold; a tap is one stroke)     wheel: stroke size
##   Q / E        left-only / right-only stroke
##   Shift        hands to the chest (tuck, dive)      Ctrl: arms swept back
##   X            arms swept forward (flare)           [ / ]: turn your torso
##   V            relaxed glide pose (toggle)          F / G: left / right grip
##   Mouse        look around (never steers)
## Gamepad: left stick = roll / pitch, RT = flap, LT = tuck, LB/RB = one-wing
## strokes, right stick = look.

const DEG := PI / 180.0

var body := HumanPoseModel.new(3)
## Stroke amplitude (deg, half of the arc), set by the mouse wheel.
var amplitude := 45.0
var hz := 1.0
var mouse_sensitivity := 0.003
var relaxed := false

# Joint state (rate-limited toward targets like a human arm).
var _twist := 0.0          # symmetric wrist twist
var _twist_a := 0.0        # opposite twist (roll)
var _tilt := 0.0           # arm tilt (roll)
var _elbow := 0.0
var _sweep := 0.0
var _phase := [0.0, 0.0]
var _stroking := [false, false]
var _stop_at := [-1.0, -1.0]
var _dih := [0.0, 0.0]
var _head_yaw := 0.0
var _head_pitch := 0.0
var _v_prev := false
var _t := 0.0


func sample(out: PoseFrame, dt: float) -> void:
	_t += dt
	body.t = _t
	var k := func(code: Key) -> bool: return Input.is_physical_key_pressed(code)
	var pad_x := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var pad_y := Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	var pad_rt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT)
	var pad_lt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT)
	# --- wrist pitch (W / S, stick Y): ramp 120 deg/s, spring back tau 0.15 s
	var tw_target := 0.0
	if k.call(KEY_W):
		tw_target = -30.0 * DEG
	elif k.call(KEY_S):
		tw_target = 40.0 * DEG
	elif absf(pad_y) > 0.15:
		# Stick forward (y < 0) = leading edges down = nose down, like a yoke.
		tw_target = pad_y * (30.0 if pad_y < 0.0 else 40.0) * DEG
	_twist = _ramp(_twist, tw_target, 120.0 * DEG, dt)
	# --- roll (A / D, stick X): opposite twist 25 deg plus arm tilt 15 deg
	var roll_in := 0.0
	if k.call(KEY_A):
		roll_in = -1.0
	elif k.call(KEY_D):
		roll_in = 1.0
	elif absf(pad_x) > 0.15:
		roll_in = pad_x
	_twist_a = _ramp(_twist_a, roll_in * 25.0 * DEG, 120.0 * DEG, dt)
	_tilt = _ramp(_tilt, roll_in * 15.0 * DEG, 90.0 * DEG, dt)
	# --- tuck / sweep
	var tuck: bool = k.call(KEY_SHIFT) or pad_lt > 0.5
	_elbow = _ramp(_elbow, 150.0 * DEG if tuck else (40.0 * DEG if relaxed else 0.0), 400.0 * DEG, dt)
	var sw_target := 0.0
	if k.call(KEY_CTRL):
		sw_target = -45.0 * DEG
	elif k.call(KEY_X):
		sw_target = 30.0 * DEG
	_sweep = _ramp(_sweep, sw_target, 180.0 * DEG, dt)
	# --- relaxed glide toggle
	var v_now: bool = k.call(KEY_V)
	if v_now and not _v_prev:
		relaxed = not relaxed
	_v_prev = v_now
	# --- torso turn
	if k.call(KEY_BRACKETLEFT):
		body.torso_yaw += 90.0 * DEG * dt
	if k.call(KEY_BRACKETRIGHT):
		body.torso_yaw -= 90.0 * DEG * dt
	# --- strokes
	var both: bool = k.call(KEY_SPACE) or pad_rt > 0.3
	var amp := amplitude if pad_rt <= 0.3 else lerpf(20.0, 60.0, clampf((pad_rt - 0.3) / 0.7, 0.0, 1.0))
	var hold_l: bool = both or k.call(KEY_Q) or Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER)
	var hold_r: bool = both or k.call(KEY_E) or Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER)
	var base := (-45.0 if relaxed else 0.0) * DEG
	for i in 2:
		var hold := hold_l if i == 0 else hold_r
		if hold and not _stroking[i]:
			# Start moving down from where the arm is: the first down is free,
			# the up earns the arc, the second down is the credited stroke.
			_stroking[i] = true
			_phase[i] = 0.25
			_stop_at[i] = -1.0
		if _stroking[i]:
			_phase[i] += hz * dt
			if not hold and _stop_at[i] < 0.0:
				# Finish the current credited downstroke (bottom at x.5).
				var nxt := floorf(_phase[i] - 0.5) + 1.5
				_stop_at[i] = maxf(nxt, 1.5)
			if _stop_at[i] > 0.0 and _phase[i] >= _stop_at[i]:
				_stroking[i] = false
				_dih[i] = base - amp * DEG
			else:
				_dih[i] = base + amp * DEG * cos(TAU * _phase[i])
		else:
			# Recover to the base pose slowly (a slow upstroke never flaps).
			_dih[i] = _ramp(_dih[i], base, 90.0 * DEG, dt)
	# --- look (right stick; mouse in handle_input)
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(rx) > 0.15:
		_head_yaw -= rx * 2.0 * dt
	if absf(ry) > 0.15:
		_head_pitch = clampf(_head_pitch - ry * 2.0 * dt, -1.2, 1.2)
	# --- compose the arms
	for i in 2:
		var a := body.arms[i]
		a.twist = _twist + (_twist_a if i == 0 else -_twist_a)
		# Rolling left (_tilt < 0) lowers the left hand and raises the right.
		a.dihedral = _dih[i] + (_tilt if i == 0 else -_tilt)
		a.elbow = _elbow
		a.sweep = _sweep
		a.fold = 0.0
	body.head_yaw = _head_yaw
	body.head_pitch = _head_pitch
	body.grip = Vector2(1.0 if k.call(KEY_F) else 0.0, 1.0 if k.call(KEY_G) else 0.0)
	body.frame(out)


static func _ramp(x: float, target: float, rate: float, dt: float) -> float:
	# Toward a held target at a human rate; back to rest with tau 0.15 s.
	if absf(target) > 1e-6:
		return move_toward(x, target, rate * dt)
	return x + (target - x) * (1.0 - exp(-dt / 0.15))


func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_head_yaw -= mm.relative.x * mouse_sensitivity
		_head_pitch = clampf(_head_pitch - mm.relative.y * mouse_sensitivity, -1.2, 1.2)
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			amplitude = clampf(amplitude + 5.0, 20.0, 60.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			amplitude = clampf(amplitude - 5.0, 20.0, 60.0)


## Mouse look for tests (same path as captured mouse motion).
func look(d_yaw: float, d_pitch: float) -> void:
	_head_yaw += d_yaw
	_head_pitch = clampf(_head_pitch + d_pitch, -1.2, 1.2)


func drives_nodes() -> bool:
	return true


func reset() -> void:
	_t = 0.0
	_stroking = [false, false]
