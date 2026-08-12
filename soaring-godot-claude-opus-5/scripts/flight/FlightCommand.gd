class_name FlightCommand
extends RefCounted

## What the player's arms are asking the wings to do this frame.
##
## This is the single, narrow contract between input (VR controllers, keyboard,
## or an AI/test driver) and the aerodynamics in [FlightModel]. Nothing in here
## knows about controllers, scenes or nodes, which is what lets the whole flight
## model run under `godot --headless`.

## Commanded roll angle in radians. Positive banks (and therefore turns) right.
var bank: float = 0.0

## Commanded angle of attack in radians, measured against the oncoming air —
## this is literally "how much are the wings tilted into the wind". Positive
## pitches the nose up relative to the flight path, generating lift and drag.
var alpha: float = 0.0

## Wing extension, 0 = fully tucked against the body, 1 = fully spread.
var span: float = 1.0

## Speed of the current downstroke in m/s. Zero when not mid-flap.
var stroke_speed: float = 0.0

## Asymmetry of the wings, -1 = only the left wing works, +1 = only the right.
## Produces a yawing/rolling nudge, which is how you flick around a branch.
var asymmetry: float = 0.0

## Local air movement (thermals, ridge lift, gusts) in m/s, world space.
var wind: Vector3 = Vector3.ZERO


func reset() -> void:
	bank = 0.0
	alpha = 0.0
	span = 1.0
	stroke_speed = 0.0
	asymmetry = 0.0
	wind = Vector3.ZERO


## Guards against NaN/INF leaking in from tracking hiccups. Input from a
## dropped controller pose is the most likely source of a poisoned physics
## state, so everything is sanitised at the boundary rather than deep inside
## the integrator.
func sanitize() -> void:
	bank = _finite(bank, 0.0)
	alpha = _finite(alpha, 0.0)
	span = clampf(_finite(span, 1.0), 0.0, 1.0)
	stroke_speed = maxf(0.0, _finite(stroke_speed, 0.0))
	asymmetry = clampf(_finite(asymmetry, 0.0), -1.0, 1.0)
	if not wind.is_finite():
		wind = Vector3.ZERO


static func _finite(v: float, fallback: float) -> float:
	return v if is_finite(v) else fallback
