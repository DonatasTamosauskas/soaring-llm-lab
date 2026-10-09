extends RefCounted
## A deterministic wing gesture recognizer. All input poses are in tracking space,
## never world space: moving the bird cannot manufacture a flap.

const MIN_STROKE := 0.095
const REARM_STROKE := 0.075
const MIN_DOWN_SPEED := 0.46
const DEBOUNCE := 0.22
const FILTER_RATE := 22.0

var _hands: Array[Dictionary] = []
var _initialized := false
var _pitch_zero := 0.0
var _span_zero := 0.55
var _bank_zero := 0.0
var strokes := 0

func reset() -> void:
	_hands.clear()
	_initialized = false
	strokes = 0

func calibrate(left: Transform3D, right: Transform3D, head: Transform3D) -> void:
	_pitch_zero = (_pose_pitch(left) + _pose_pitch(right)) * 0.5
	_span_zero = clampf(Vector2(left.origin.x - right.origin.x, left.origin.z - right.origin.z).length(), 0.35, 0.90)
	_bank_zero = left.origin.y - right.origin.y
	reset()
	_initialize(left.origin, right.origin, head.origin)

func sample(delta: float, left: Transform3D, right: Transform3D, head: Transform3D, squeeze: float = 0.0, trigger: float = 0.0) -> Dictionary:
	var dt := clampf(delta, 0.001, 0.25)
	if not _initialized:
		_initialize(left.origin, right.origin, head.origin)
	var positions: Array[Vector3] = [left.origin, right.origin]
	var strength := 0.0
	for index in range(2):
		var state := _hands[index]
		var relative := positions[index] - head.origin
		var hand_delta: Vector3 = positions[index] - state.raw
		var arm_delta: Vector3 = relative - state.relative
		state.cooldown = maxf(0.0, state.cooldown - dt)
		# Tracking discontinuities, recentering and dropped tracking are not strokes.
		if hand_delta.length() > 0.65 or arm_delta.length() > 0.65:
			state.peak = relative.y
			state.trough = relative.y
			state.speed = 0.0
			state.armed = false
		else:
			var speed := -arm_delta.y / dt
			state.speed = lerpf(state.speed, speed, 1.0 - exp(-FILTER_RATE * dt))
			if state.armed:
				state.peak = maxf(state.peak, relative.y)
				var stroke: float = state.peak - relative.y
				# Raw downward movement rejects a head-only bob. Head-relative movement
				# rejects crouching or room-scale walking with both arms held still.
				var raw_down_speed := -hand_delta.y / dt
				if stroke >= MIN_STROKE and state.speed >= MIN_DOWN_SPEED and raw_down_speed >= 0.25 and state.cooldown <= 0.0:
					strength += clampf(0.55 + state.speed * 0.23 + stroke * 0.65, 0.6, 1.6) * 0.5
					state.armed = false
					state.trough = relative.y
					state.cooldown = DEBOUNCE
					strokes += 1
			else:
				state.trough = minf(state.trough, relative.y)
				if relative.y - state.trough >= REARM_STROKE and speed < -0.18 and state.cooldown <= 0.0:
					state.armed = true
					state.peak = relative.y
		state.raw = positions[index]
		state.relative = relative
		_hands[index] = state
	var span := Vector2(left.origin.x - right.origin.x, left.origin.z - right.origin.z).length()
	var comfortable_span := clampf(_span_zero * 2.2, 0.85, 1.4)
	var spread := clampf((span - 0.22) / (comfortable_span - 0.22), 0.08, 1.0)
	# Holding both squeezes lets the player lower bent arms for a sustained glide.
	spread = maxf(spread, smoothstep(0.12, 0.65, squeeze) * 0.82)
	var pitch := clampf(((_pose_pitch(left) + _pose_pitch(right)) * 0.5 - _pitch_zero) / 0.62, -1.0, 1.0)
	var bank := clampf((left.origin.y - right.origin.y - _bank_zero) / 0.40, -1.0, 1.0)
	var tuck := maxf(clampf((0.36 - span) / 0.20, 0.0, 1.0), clampf(trigger, 0.0, 1.0))
	return {"flap": strength, "spread": spread, "pitch": pitch, "bank": bank, "tuck": tuck, "brake": maxf(0.0, (spread - 0.88) / 0.12), "span": span}

func _initialize(left: Vector3, right: Vector3, head: Vector3) -> void:
	_hands.clear()
	for hand in [left, right]:
		var relative: Vector3 = hand - head
		_hands.append({"raw": hand, "relative": relative, "speed": 0.0, "peak": relative.y, "trough": relative.y, "armed": true, "cooldown": 0.0})
	_initialized = true

func _pose_pitch(pose: Transform3D) -> float:
	return asin(clampf((-pose.basis.z.normalized()).y, -1.0, 1.0))
