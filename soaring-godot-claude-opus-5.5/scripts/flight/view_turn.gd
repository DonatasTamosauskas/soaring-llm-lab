class_name ViewTurn
extends RefCounted
## The part of a heading change the view could not follow in one tick, owed
## to the rig and paid out smoothly.
##
## A contact re-seats the bird's heading on its new path in one tick (a slide
## along a wall, the small turn a stun gives). The rig pays that step to the
## view here instead of dropping it: a view left facing the old heading is
## what body steer used to read as "the torso wants to turn back" (the round-3
## stun-lock). rig yaw + debt is always the yaw the view is heading for.
##
## Fix round 4: a time-optimal ("bang-bang") follower with explicit caps
## replaces round 3's re-planned quintic, whose duration search could run out
## and leave coefficients solved for another duration (the view then spun at
## the 240 deg/s rig cap for tens of seconds after a stun that ended on the
## floor). Each tick the payout rate moves by at most max_acc * dt toward the
## fastest rate that can still stop on the target with that same deceleration
## (the discrete stopping curve below), never above max_rate. There is no
## search and no failure branch; the three properties hold by construction:
##  - |rate| <= max_rate and |rate change| <= max_acc * dt on every tick
##    (a rate above max_rate, left by a lowered cap, only brakes at max_acc);
##  - never past the target: a tick that would reach it lands on it exactly,
##    and the rate it left with is below max_acc * dt, so the stop that
##    follows is inside the acceleration cap too. The one exception is a
##    debt cut short mid-payout (a new owe the other way while paying fast):
##    no payout inside the caps can stop on that target, so it runs past by
##    the unavoidable braking distance (rate^2 / 2 max_acc) and comes back;
##  - converges in finite time: from rest, |d|/max_rate + max_rate/max_acc
##    plus a tick or two (the time-optimal profile, discretised).
## "Never past the target" and the convergence time are exact for a constant
## tick (Godot's physics tick; the stopping curve assumes the next ticks are
## as long as this one). With the tick length changing every tick (fix round
## 5, VT-5: 72 / 90 / 120 Hz mixed) the caps and conservation still hold by
## construction, the overshoot from rest stays within 0.25 deg (0.21 measured
## over 5 000 sequences) and the payout settles within 1 s of the constant-tick
## bound. Arbitrary tick lengths (random 4-100 ms ticks mixed in: the round-5
## engineering verifier's probe) keep the caps and conservation but can run
## past the target by a few degrees (4.7 deg there). The game never feeds
## those: PlayerBird ticks from _physics_process at Godot's fixed step (the
## headset's refresh rate, set by VRManager), and a frame hitch runs more
## fixed steps, not longer ones.
## Pinned by ViewTurn property tests (flight/view_turn_test.gd).

## Radians still owed to the view (target minus paid).
var debt := 0.0
## Payout rate (rad/s) paid on the last tick, and its change per second on
## that tick (rad/s^2; telemetry and tests).
var rate := 0.0
var acc := 0.0
var max_rate := deg_to_rad(120.0)
var max_acc := deg_to_rad(240.0)


func reset() -> void:
	debt = 0.0
	rate = 0.0
	acc = 0.0


func active() -> bool:
	return debt != 0.0 or rate != 0.0


## Owe the view `delta` rad more (any sign, any time, also mid-payout).
func owe(delta: float) -> void:
	if not is_finite(delta) or delta == 0.0:
		return
	# The view can turn either way round: a debt past 180 deg is paid the
	# short way (the same final orientation), so |debt| <= PI always. An
	# exact wrap (fix round 6): Godot's wrapf returns the lower bound for any
	# result within its is_equal_approx tolerance of the upper one, so a debt
	# 2.5e-5 rad short of +PI became -PI and that much turn was lost (VT-1's
	# conservation check over the 20 000 --full sequences).
	debt = FlightMath.wrap_angle(debt + delta)


## Advances the payout by dt; returns the rotation (rad) paid this tick.
func step(dt: float) -> float:
	if not (dt > 0.0) or not is_finite(dt):
		return 0.0
	var a_dt := max_acc * dt
	var e := debt
	if not (a_dt > 0.0) or not (max_rate > 0.0) or not is_finite(e) or not is_finite(rate):
		# Limits switched off (or a corrupt state): nothing to smooth with.
		debt = 0.0
		rate = 0.0
		acc = 0.0
		return e if is_finite(e) else 0.0
	# The fastest rate toward the target that can still stop EXACTLY on it
	# braking by a_dt per tick. From rate v, with n = floor(v / a_dt), this
	# tick and the ones after pay (v + (v - a_dt) + ... + (v - n a_dt)) dt
	# = dt ((n + 1) v - a_dt n (n + 1) / 2). Setting that to |e| gives
	# v = |e| / (dt (n + 1)) + a_dt n / 2, with n from the integer-point
	# solution m = sqrt(1/4 + 2 |e| / (a_dt dt)) - 1/2. (The continuous
	# sqrt(2 a |e|) overshoots by up to a_dt dt / 2, and m used as the rate
	# directly by up to a_dt dt / 8; this one lands on the target.)
	var ae := absf(e)
	var m := sqrt(0.25 + 2.0 * ae / (a_dt * dt)) - 0.5
	var n := floorf(maxf(m, 0.0))
	var v_stop := ae / (dt * (n + 1.0)) + a_dt * n * 0.5
	var v_want := signf(e) * minf(max_rate, v_stop)
	var v := clampf(v_want, rate - a_dt, rate + a_dt)
	# A rate above the cap (the cap was lowered mid-turn) only brakes.
	var lim := maxf(max_rate, absf(rate) - a_dt)
	v = clampf(v, -lim, lim)
	var paid := v * dt
	if e != 0.0 and signf(paid) == signf(e) and absf(paid) >= ae and absf(e / dt - rate) <= a_dt:
		# This tick reaches the target and can stop on it inside the cap:
		# land on it exactly. On the stopping curve that is always the case
		# (the rate left is below a_dt, so the stop that follows is inside
		# the cap too). Only a debt cut short under a fast payout (a new
		# owe the other way) cannot stop in time: that rotation runs on past
		# the new target and comes back, still inside both caps.
		paid = e
	debt = e - paid
	var v_eff := paid / dt
	acc = (v_eff - rate) / dt
	rate = v_eff
	return paid
