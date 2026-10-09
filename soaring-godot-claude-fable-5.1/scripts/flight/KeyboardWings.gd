class_name KeyboardWings
extends RefCounted

## Desktop stand-in for the controllers, so the game can be flown and tested
## without a headset. W/S pitch, A/D bank, Space flap, Shift tuck, Q/E yaw flick.

const ALPHA_TRIM: float = deg_to_rad(6.0)
var alpha: float = ALPHA_TRIM
var bank: float = 0.0
var _flap_phase: float = 0.0

func update(dt: float) -> FlightCommand:
	var cmd := FlightCommand.new()
	var pitch_in: float = Input.get_axis("pitch_down", "pitch_up")
	var bank_in: float = Input.get_axis("bank_left", "bank_right")
	var a_target: float = ALPHA_TRIM + pitch_in * deg_to_rad(22.0)
	alpha = move_toward(alpha, a_target, deg_to_rad(60.0) * dt)
	bank = move_toward(bank, bank_in * deg_to_rad(60.0), deg_to_rad(120.0) * dt)
	cmd.alpha = alpha
	cmd.bank = bank
	cmd.spread = 0.0 if Input.is_action_pressed("tuck") else 1.0
	if Input.is_action_pressed("flap"):
		# Holding space beats the wings at ~2.5 Hz; the downstroke half gives thrust.
		_flap_phase = fmod(_flap_phase + dt * 2.5, 1.0)
		cmd.flap = 1.0 if _flap_phase < 0.45 else 0.0
	else:
		_flap_phase = 0.0
	cmd.flap_asym = Input.get_axis("yaw_left", "yaw_right") * 0.8
	cmd.grip = Input.is_action_pressed("grip")
	return cmd.clamped()
