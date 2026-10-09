extends "res://tests/unit/integration/integration_pilot.gd"
## TEST-ONLY (UI evidence, tests/shots/ui_lesson_real.gd): the integration
## pilot with the wrists under the test's control. The integration pilot
## trims its wing pitch to hold a speed (its "glide" is not a neutral-wrist
## glide); here `hold_pitch` replaces its pitch command after it has decided
## everything else, so a flight can be flown with the wrists exactly
## neutral (0) or held tilted (+ = leading edges up). NAN: the pilot's own.
## The command still goes through flight's BotPoseSource (reaction delay,
## twist-rate limit, twist noise) and the real WingInput, like any other.

var hold_pitch := NAN


func update(pos: Vector3, vel_raw: Vector3, airspeed: float, dt: float) -> void:
	super.update(pos, vel_raw, airspeed, dt)
	if not is_nan(hold_pitch):
		pitch = hold_pitch
