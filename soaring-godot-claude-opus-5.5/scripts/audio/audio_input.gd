class_name AudioInput
extends RefCounted
## The audio area's boundary: every number it takes from outside (flight
## telemetry, the threat level, event payloads, positions of birds, hands,
## the camera and landmarks, the world's ground, Settings volumes) goes
## through here before it reaches a gain, a filter or a smoothed state.
##
## Why: one NaN in a smoothed gain never leaves it (lerp(NaN, x) is NaN),
## and Godot's clampf, minf and maxf pass a NaN straight through or turn it
## into one of their bounds depending on argument order. Round 4 found a
## single NaN wing_extension from a glitching tracker silencing the wind,
## the main speed cue, for the rest of the session. So every input is
## replaced by a safe default when it is not a finite number and clamped to
## a sane range when it is; every smoothed state in the director, the voices
## and the ambience is also reset to its target should it ever become
## non-finite (a second line of defence, see audio_input_test.gd).

## Largest coordinate (m) taken as a real position: the arena is about
## 1.5 km across. Anything beyond is a glitch (and squared, in float32
## engine math, it overflows to INF).
const MAX_COORD := 1.0e5


## A finite number in [lo, hi]: ints and floats are clamped, bools read as
## 0/1, anything else (NaN, INF, null, a string) is `fallback`.
static func num(v: Variant, fallback: float, lo: float = -INF, hi: float = INF) -> float:
	var t := typeof(v)
	var f := fallback
	if t == TYPE_FLOAT or t == TYPE_INT:
		f = float(v)
	elif t == TYPE_BOOL:
		f = 1.0 if v else 0.0
	if not is_finite(f):
		return fallback
	return clampf(f, lo, hi)


## A flag: bools as they are, numbers true when finite and non-zero,
## anything else `fallback`. (bool(NAN) is true in GDScript.)
static func flag(v: Variant, fallback: bool = false) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT:
			return v != 0
		TYPE_FLOAT:
			return fallback if not is_finite(v) else v != 0.0
	return fallback


## True for a position audio may use: finite and inside MAX_COORD.
static func position_ok(p: Vector3) -> bool:
	return p.is_finite() and absf(p.x) < MAX_COORD and absf(p.y) < MAX_COORD and absf(p.z) < MAX_COORD


## True for a listener or rig transform audio may use.
static func transform_ok(t: Transform3D) -> bool:
	return t.basis.is_finite() and position_ok(t.origin)
