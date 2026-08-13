class_name SoundState
extends RefCounted

## What the bird's own body sounds like this frame.
##
## The one channel between the game and [Soundscape], for exactly the reason
## [FlightCommand] is the one channel between input and physics: it lets the
## whole first-person soundscape be rendered in a headless test with nothing but
## numbers, so "wind gets louder with airspeed" and "a stall buffets" are
## assertions rather than opinions formed while wearing a headset.
##
## Nothing in here knows about nodes, buses or the audio server.

## Speed through the air in m/s. The primary driver of everything.
var airspeed: float = 0.0

## Wing extension, 0 tucked, 1 spread — same units as [member FlightCommand.span].
## Tucked wings make a thin, hissy noise; spread wings at speed roar.
var span: float = 1.0

## Speed of the current downstroke in m/s, 0 when not mid-flap.
var stroke_speed: float = 0.0

## Which wing did the work: −1 left only, +1 right only. Panned, because a
## one-winged beat you can hear in one ear is the clearest possible statement of
## what your arms just did.
var asymmetry: float = 0.0

## How far past the stall, 0..1 — [member FlightModel.stall_amount].
var stall: float = 0.0

## Metres above the ground directly below. The altitude cue: the land's murmur
## fades out from under you as you climb.
var altitude: float = 0.0

## Vertical air movement in m/s. Positive is lift.
var lift: float = 0.0

## The bird's size. A bigger bird moves more air: everything gets lower.
var size: float = 1.0

## Sitting on something. Wind over a stationary bird is nearly silent, but the
## world below is right there.
var perched: bool = false

## How much of the landscape below is trees rather than open ground, 0..1. Shapes
## the bed's timbre — a rustle over a forest, a broader hush over the downs.
var canopy: float = 0.5


func reset() -> void:
	airspeed = 0.0
	span = 1.0
	stroke_speed = 0.0
	asymmetry = 0.0
	stall = 0.0
	altitude = 0.0
	lift = 0.0
	size = 1.0
	perched = false
	canopy = 0.5


## Guards the synthesiser against a poisoned frame. A NaN reaching the filters
## would not merely sound wrong: a one-pole filter that takes on NaN keeps it
## forever, so a single bad frame would silence the game until it was restarted.
func sanitize() -> void:
	airspeed = clampf(_finite(airspeed, 0.0), 0.0, 200.0)
	span = clampf(_finite(span, 1.0), 0.0, 1.0)
	stroke_speed = clampf(_finite(stroke_speed, 0.0), 0.0, 20.0)
	asymmetry = clampf(_finite(asymmetry, 0.0), -1.0, 1.0)
	stall = clampf(_finite(stall, 0.0), 0.0, 1.0)
	altitude = clampf(_finite(altitude, 0.0), 0.0, 5000.0)
	lift = clampf(_finite(lift, 0.0), -30.0, 30.0)
	size = clampf(_finite(size, 1.0), 0.2, 12.0)
	canopy = clampf(_finite(canopy, 0.5), 0.0, 1.0)


static func _finite(v: float, fallback: float) -> float:
	return v if is_finite(v) else fallback
