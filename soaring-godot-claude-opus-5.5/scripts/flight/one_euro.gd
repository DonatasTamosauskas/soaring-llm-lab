class_name OneEuro
extends RefCounted
## One-Euro filter (Casiez et al. 2012) for one scalar channel.
##
## Low jitter at rest (low cutoff) and low lag in fast motion (the cutoff
## rises with the signal's speed). WingInput uses one per channel with the
## cutoffs of FLIGHT_SPEC §5.13. The derivative cutoff is fixed at 1 Hz.

var min_cutoff := 1.0
var beta := 0.0
var d_cutoff := 1.0

var _x := 0.0
var _dx := 0.0
var _init_done := false


func _init(p_min_cutoff := 1.0, p_beta := 0.0) -> void:
	min_cutoff = p_min_cutoff
	beta = p_beta


func reset(value := 0.0) -> void:
	_x = value
	_dx = 0.0
	_init_done = true


func clear() -> void:
	_init_done = false
	_x = 0.0
	_dx = 0.0


func value() -> float:
	return _x


func filter(x: float, dt: float) -> float:
	if not _init_done or dt <= 0.0:
		reset(x)
		return x
	var dx := (x - _x) / dt
	_dx += (dx - _dx) * _alpha(d_cutoff, dt)
	var fc := min_cutoff + beta * absf(_dx)
	_x += (x - _x) * _alpha(fc, dt)
	return _x


static func _alpha(fc: float, dt: float) -> float:
	return 1.0 / (1.0 + 1.0 / (TAU * fc * dt))
