class_name FlightModel
extends RefCounted

## Aerodynamics for one bird.
##
## Deliberately free of any Node/scene dependency: construct one, call
## [method step] with a [FlightCommand], read [member velocity]. That makes the
## entire core mechanic runnable — and therefore tunable and regression-tested —
## under `godot --headless`, without a headset or even a window.
##
## The model is a real (if simplified) lift/drag simulation rather than a bag of
## ad-hoc impulses. That matters for feel: because lift is generated
## perpendicular to the airflow and drag opposes it, energy exchange between
## altitude and speed falls out for free. Diving genuinely buys you speed, and
## pulling up genuinely trades it back for height. Turning is not scripted
## either — banking tilts the lift vector sideways, the sideways force curves
## the velocity, and the heading follows. A coordinated turn emerges from the
## same equations that hold the bird up.

const EPSILON: float = 1e-5

# --- Environment -------------------------------------------------------------

var gravity: float = 9.81
var air_density: float = 1.225

# --- Airframe (values are for a scale-1.0 bird; see [method _resize]) ---------

## Mass in kg at size 1.0. Roughly a large raptor carrying a human's ambitions.
var base_mass: float = 3.0
## Wing planform area in m^2 at size 1.0.
var base_wing_area: float = 0.30
## Effective drag area (Cd * A) of the body itself. This is what stops a full
## tuck from accelerating forever, so it sets terminal dive speed. Kept small
## relative to wing drag so that folding the wings makes a dramatic difference.
var base_body_drag_area: float = 0.008

## Lift-curve slope, per radian. Thin-airfoil theory says 2*PI; real finite
## wings are lower.
var cl_alpha: float = 5.0
## Angle of attack at which the wing stalls, radians (~17 degrees).
var alpha_stall: float = 0.30
## Fraction of peak lift still available once fully stalled.
var cl_post_stall: float = 0.55
## Profile drag coefficient of the wing.
var cd0: float = 0.030
## Induced drag factor, 1 / (PI * aspect_ratio * efficiency).
var induced_k: float = 0.055
## Extra drag coefficient added at full stall — the "falling leaf" penalty.
var stall_cd: float = 1.10
## Barn-door drag that grows with the square of AoA, stalled or not.
var high_alpha_cd: float = 0.35

## Angle of attack held by relaxed, level, fully-spread wings. Chosen so that
## hands-neutral is a stable glide rather than a slow crash.
var alpha_trim: float = 0.105
## How far the player can push AoA either side of trim.
var alpha_range: float = 0.42

## Minimum wing area as a fraction of full span, reached in a total tuck.
var tuck_area_fraction: float = 0.14

# --- Flapping ----------------------------------------------------------------

## Thrust coefficient for a downstroke: F = coeff * rho * area * span * v_stroke^2.
var flap_coeff: float = 14.0
## Split of flap thrust between "up" and "forward" in the banked body frame.
var flap_up_fraction: float = 0.78
var flap_forward_fraction: float = 0.62
## Ceiling on stroke speed so a violent controller spike can't launch the player
## into orbit.
var max_stroke_speed: float = 6.0

# --- Handling ----------------------------------------------------------------

## How fast commanded bank is actually reached, rad/s at size 1.0.
var roll_rate: float = 5.5
## Direct yaw authority from asymmetric wings, rad/s. Small: most turning should
## come from banking, this is just the flick.
var yaw_authority: float = 0.9
## Speed at which drag starts being artificially hardened, m/s.
var soft_speed_cap: float = 58.0
var hard_speed_cap: float = 78.0

# --- Live state --------------------------------------------------------------

var velocity: Vector3 = Vector3.ZERO
## Yaw of the bird's nose, radians. heading 0 faces -Z, matching Godot's forward.
var heading: float = 0.0
## Actual (rate-limited) roll angle, radians.
var bank: float = 0.0
var size_scale: float = 1.0

# --- Derived, refreshed whenever size changes --------------------------------

var mass: float = 3.0
var wing_area: float = 0.30
var body_drag_area: float = 0.012

# --- Read-only diagnostics, for HUD, tuning and tests ------------------------

var airspeed: float = 0.0
var angle_of_attack: float = 0.0
var flight_path_angle: float = 0.0
var lift_accel: float = 0.0
var drag_accel: float = 0.0
var thrust_accel: float = 0.0
var load_factor: float = 1.0
var stall_amount: float = 0.0
var is_stalled: bool = false


func _init(initial_scale: float = 1.0) -> void:
	set_size(initial_scale)


## Bird size drives mass, wing area and therefore every handling characteristic.
## Mass follows the cube of length and area a little under the square, so wing
## loading climbs with size: big birds cruise faster and turn in wider arcs,
## small birds are slow but nimble. That size/agility tradeoff *is* the chase
## game — it is not bolted on top of it.
func set_size(new_scale: float) -> void:
	size_scale = clampf(new_scale if is_finite(new_scale) else 1.0, 0.25, 12.0)
	_resize()


## Strict square-cube (mass ~ s^3, area ~ s^2) is real, but it makes a large
## bird a barely-flyable brick — at size 5 a flap barely dents its momentum.
## These softened exponents keep the *character* of the tradeoff (bigger is
## faster in a straight line, wider through a turn, and worse at climbing under
## its own power) while leaving a big bird fun to actually fly.
const MASS_EXPONENT: float = 2.7
const AREA_EXPONENT: float = 2.4


func _resize() -> void:
	mass = base_mass * pow(size_scale, MASS_EXPONENT)
	wing_area = base_wing_area * pow(size_scale, AREA_EXPONENT)
	body_drag_area = base_body_drag_area * pow(size_scale, 2.0)


## Unit vector the nose points along, level with the horizon.
func forward() -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


## Speed at which fully-spread wings at trim exactly carry the bird's weight.
## Below this you are sinking no matter how well you fly.
func trim_speed() -> float:
	var cl: float = cl_alpha * alpha_trim
	var denom: float = 0.5 * air_density * wing_area * cl
	if denom <= EPSILON:
		return 0.0
	return sqrt(mass * gravity / denom)


## Total mechanical energy per unit mass. The single number that tells you
## whether a manoeuvre was efficient, and the backbone of the physics tests.
func specific_energy(altitude: float) -> float:
	return gravity * altitude + 0.5 * velocity.length_squared()


## Advance the simulation by [param dt] seconds.
func step(cmd: FlightCommand, dt: float) -> void:
	if not is_finite(dt) or dt <= 0.0:
		return
	dt = minf(dt, 0.05)  # never let a frame hitch integrate a huge step
	cmd.sanitize()

	if not velocity.is_finite():
		velocity = Vector3.ZERO
	if not is_finite(heading):
		heading = 0.0
	if not is_finite(bank):
		bank = 0.0

	_update_bank(cmd, dt)

	var air_relative: Vector3 = velocity - cmd.wind
	airspeed = air_relative.length()

	var frame: Basis = _airflow_frame(air_relative)
	var vhat: Vector3 = -frame.z

	var span: float = cmd.span
	var area: float = wing_area * lerpf(tuck_area_fraction, 1.0, span)
	var q: float = 0.5 * air_density * airspeed * airspeed

	angle_of_attack = clampf(cmd.alpha, -alpha_stall * 2.5, alpha_stall * 2.5)
	var cl: float = _lift_coefficient(angle_of_attack)
	var cd: float = _drag_coefficient(angle_of_attack, cl)

	# Lift acts perpendicular to the airflow, rolled about it by the bank angle.
	# Tilting it sideways is the entire turning mechanic.
	var lift_dir: Vector3 = frame.y * cos(bank) + frame.x * sin(bank)
	lift_accel = q * area * cl / mass
	var lift: Vector3 = lift_dir * lift_accel

	# Drag opposes the airflow. Wing drag scales with the exposed area, so a
	# tuck sheds most of it; body drag does not, which is what caps a dive.
	drag_accel = q * (area * cd + body_drag_area) / mass
	var drag: Vector3 = -vhat * drag_accel

	var thrust: Vector3 = _flap_thrust(cmd, span)
	thrust_accel = thrust.length()

	var accel: Vector3 = lift + drag + thrust + Vector3(0.0, -gravity, 0.0)
	if not accel.is_finite():
		accel = Vector3(0.0, -gravity, 0.0)

	velocity += accel * dt
	_apply_speed_cap(dt)

	if not velocity.is_finite():
		velocity = Vector3.ZERO

	_update_heading(cmd, dt)

	# Diagnostics
	load_factor = lift_accel / gravity if gravity > EPSILON else 0.0
	flight_path_angle = 0.0
	var s: float = velocity.length()
	if s > EPSILON:
		flight_path_angle = asin(clampf(velocity.y / s, -1.0, 1.0))


func _update_bank(cmd: FlightCommand, dt: float) -> void:
	# Bigger wings have more rotational inertia and roll lazily.
	var rate: float = roll_rate / sqrt(size_scale)
	# Tucked wings have little roll authority; spread wings bite.
	rate *= lerpf(0.35, 1.0, cmd.span)
	var target: float = clampf(cmd.bank, -PI * 0.5, PI * 0.5)
	bank = move_toward(bank, target, rate * dt)


## Builds an orthonormal frame around the airflow: -Z along the relative wind,
## X to the aerodynamic right, Y to the aerodynamic up. Handles the degenerate
## cases (near-zero airspeed, dead-vertical dive) by falling back on the nose
## direction, so the frame is always well defined.
func _airflow_frame(air_relative: Vector3) -> Basis:
	var fwd: Vector3 = forward()
	var vhat: Vector3 = fwd
	if air_relative.length_squared() > EPSILON * EPSILON:
		vhat = air_relative.normalized()

	var right: Vector3 = vhat.cross(Vector3.UP)
	if right.length_squared() < 1e-6:
		# Straight up or straight down: use the nose to break the tie.
		right = vhat.cross(fwd)
		if right.length_squared() < 1e-6:
			right = Vector3.RIGHT
	right = right.normalized()

	var up: Vector3 = right.cross(vhat).normalized()
	return Basis(right, up, -vhat)


func _lift_coefficient(alpha: float) -> float:
	var a: float = absf(alpha)
	if a <= alpha_stall:
		stall_amount = 0.0
		is_stalled = false
		return cl_alpha * alpha

	# Past the stall the wing does not simply stop working — lift collapses
	# toward a lower plateau while drag explodes. You mush, you sink, and you
	# have to lower the nose and fly out of it.
	var over: float = (a - alpha_stall) / maxf(alpha_stall, EPSILON)
	stall_amount = clampf(over, 0.0, 1.0)
	is_stalled = true
	var cl_max: float = cl_alpha * alpha_stall
	var cl_mag: float = lerpf(cl_max, cl_max * cl_post_stall, stall_amount)
	return cl_mag * signf(alpha)


func _drag_coefficient(alpha: float, cl: float) -> float:
	var cd: float = cd0 + induced_k * cl * cl
	if stall_amount > 0.0:
		cd += stall_cd * stall_amount * stall_amount
	# Very high AoA is a barn door regardless of stall bookkeeping.
	cd += high_alpha_cd * alpha * alpha
	return cd


## The bird's own frame: nose along the heading, rolled by the bank angle.
## Unlike the airflow frame this never degenerates, because it is built from
## the heading rather than from the velocity — which matters enormously when
## you are climbing vertically and "aerodynamic up" has rotated to horizontal.
func _body_frame() -> Basis:
	var fwd: Vector3 = forward()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var up: Vector3 = right.cross(fwd)
	var rolled_up: Vector3 = up * cos(bank) + right * sin(bank)
	var rolled_right: Vector3 = right * cos(bank) - up * sin(bank)
	return Basis(rolled_right, rolled_up, -fwd)


func _flap_thrust(cmd: FlightCommand, span: float) -> Vector3:
	if cmd.stroke_speed <= EPSILON or span <= EPSILON:
		return Vector3.ZERO
	var v: float = minf(cmd.stroke_speed, max_stroke_speed)
	# Thrust from a downstroke behaves like any other aerodynamic force:
	# proportional to area and to the square of how fast you move the wing.
	# Tucked wings push almost no air, which teaches the mechanic without a
	# tutorial: you cannot flap your way out of a dive without opening up.
	var force: float = flap_coeff * air_density * wing_area * span * span * v * v
	var accel: float = force / mass

	# Flap thrust is propulsive, not aerodynamic, so it acts in the body frame:
	# up and forward relative to the horizon and the nose. Banking mid-flap
	# therefore drives you around the corner rather than straight up.
	var frame: Basis = _body_frame()
	var dir: Vector3 = frame.y * flap_up_fraction - frame.z * flap_forward_fraction
	if dir.length_squared() < EPSILON:
		return Vector3.ZERO
	dir = dir.normalized()

	# Angling the wings during the stroke aims the thrust: hands held back
	# climbs steeply, hands pushed forward converts the same effort into speed.
	var aim: float = clampf(cmd.alpha - alpha_trim, -0.7, 0.7)
	dir = dir.rotated(frame.x, aim)
	return dir * accel


## Keeps speed inside a sane envelope without a hard clamp that would feel like
## hitting a wall. Drag ramps up steeply past the soft cap; the hard cap is a
## last-resort backstop.
func _apply_speed_cap(dt: float) -> void:
	var s: float = velocity.length()
	if s <= soft_speed_cap or s <= EPSILON:
		return
	var over: float = (s - soft_speed_cap) / maxf(hard_speed_cap - soft_speed_cap, EPSILON)
	var damping: float = clampf(over * over * 8.0 * dt, 0.0, 0.9)
	velocity *= (1.0 - damping)
	if velocity.length() > hard_speed_cap:
		velocity = velocity.normalized() * hard_speed_cap


## The nose weathervanes into the direction of travel, with a lag so the bird
## reads as a body with inertia rather than an arrow glued to the velocity.
## Asymmetric wings add a direct yaw flick on top.
func _update_heading(cmd: FlightCommand, dt: float) -> void:
	if absf(cmd.asymmetry) > 0.01:
		heading += cmd.asymmetry * yaw_authority * dt / sqrt(size_scale)

	var horizontal: Vector2 = Vector2(velocity.x, velocity.z)
	if horizontal.length_squared() < 0.25:
		return  # too slow to have a meaningful direction of travel
	var target: float = atan2(-horizontal.x, -horizontal.y)
	var blend: float = clampf(dt * 6.0, 0.0, 1.0)
	heading = _lerp_angle(heading, target, blend)
	heading = wrapf(heading, -PI, PI)


static func _lerp_angle(from: float, to: float, weight: float) -> float:
	var diff: float = wrapf(to - from, -PI, PI)
	return from + diff * weight
