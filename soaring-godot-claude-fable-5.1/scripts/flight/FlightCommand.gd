class_name FlightCommand
extends RefCounted

## What the wings are being told to do this tick. Produced by [WingInput] from
## controller poses, or by keyboard / autopilot code. Everything is unitless
## and already clamped, so [FlightModel] never has to trust its caller.

## Angle-of-attack command in radians (wing chord relative to the airflow).
var alpha: float = 0.0
## Commanded bank angle in radians; positive rolls right (turns right).
var bank: float = 0.0
## Wing spread 0..1 (1 = fully extended, 0 = tucked to the body).
var spread: float = 1.0
## Flap impulse strength for this tick, 0..1. Nonzero only during a downstroke.
var flap: float = 0.0
## Asymmetric flap: +1 means the right wing beat harder (yaws left).
var flap_asym: float = 0.0
## Grip held: the bird wants to cling to whatever it touches.
var grip: bool = false

func clamped() -> FlightCommand:
	alpha = clampf(alpha, -0.35, 0.6)
	bank = clampf(bank, -1.4, 1.4)
	spread = clampf(spread, 0.0, 1.0)
	flap = clampf(flap, 0.0, 1.0)
	flap_asym = clampf(flap_asym, -1.0, 1.0)
	for v in [alpha, bank, spread, flap, flap_asym]:
		if not is_finite(v):
			alpha = 0.0; bank = 0.0; spread = 1.0; flap = 0.0; flap_asym = 0.0
			break
	return self

func copy() -> FlightCommand:
	var c := FlightCommand.new()
	c.alpha = alpha; c.bank = bank; c.spread = spread
	c.flap = flap; c.flap_asym = flap_asym; c.grip = grip
	return c
