class_name FlightModel
extends RefCounted

## A lift/drag flight model for a bird. No scene dependencies, so the whole
## core mechanic can be exercised headless.
##
## The bird is a point mass with a velocity. Its body forward axis follows the
## velocity (with lag), it rolls about that axis by the bank angle, and its
## wings meet the air at the commanded angle of attack. Lift acts perpendicular
## to the airflow in the plane of the body's up vector, so banking tilts lift
## sideways and the bird turns: the coordinated turn falls out of the same
## force that holds it up. Drag opposes the airflow. Gravity is gravity.
##
## Size scales mass faster than wing area, so wing loading (and therefore
## cruise speed and turn radius) grows with the bird. That size/agility
## tradeoff is the chase game.

const RHO: float = 1.225          # air density, kg/m^3
const G: float = 9.81

## Reference bird (size 1.0): a hawk-sized raptor.
const BASE_MASS: float = 1.6      # kg
const BASE_AREA: float = 0.19     # m^2 of wing
const BASE_SPAN: float = 1.15     # m
const MASS_EXP: float = 2.4       # mass ~ size^2.4, area ~ size^2

const CL_ALPHA: float = 4.6       # lift slope per radian (finite wing)
const CL_MAX: float = 1.45
const ALPHA_STALL: float = deg_to_rad(16.0)
const ALPHA_ZERO_LIFT: float = deg_to_rad(-3.0)  # cambered wing lifts at alpha 0
const CD0_SPREAD: float = 0.035
const CD0_TUCKED: float = 0.16    # body-only drag coefficient, referenced to full area
const OSWALD: float = 0.85
const MIN_AREA_FRACTION: float = 0.12

## Downstroke thrust: N per unit flap command per m^2 of wing, plus lift boost.
const FLAP_THRUST: float = 34.0
const FLAP_LIFT: float = 20.0
const FLAP_YAW_TORQUE: float = 1.6  # rad/s of heading change per unit asym flap
const BANK_RATE: float = 2.6      # rad/s the bank can change
const HEADING_LAG: float = 0.08   # s, how quickly the body follows the velocity
const MAX_SPEED: float = 130.0     # hard clamp against explosions

var size: float = 1.0:
	set(v):
		size = clampf(v, 0.2, 8.0)
		_recompute_size()

var mass: float = BASE_MASS
var wing_area: float = BASE_AREA
var span: float = BASE_SPAN
var aspect_ratio: float = BASE_SPAN * BASE_SPAN / BASE_AREA

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var heading: Vector3 = Vector3.FORWARD  # body forward, unit
var bank: float = 0.0                   # current roll about the velocity, rad
var alpha: float = 0.0                  # current angle of attack, rad
var spread: float = 1.0
var stalled: bool = false
var last_lift: Vector3 = Vector3.ZERO
var last_drag: Vector3 = Vector3.ZERO
var last_thrust: Vector3 = Vector3.ZERO
var airspeed: float = 0.0
var wind: Vector3 = Vector3.ZERO         # ambient air velocity (thermals, gusts)

func _init(p_size: float = 1.0) -> void:
	size = p_size

func _recompute_size() -> void:
	mass = BASE_MASS * pow(size, MASS_EXP)
	wing_area = BASE_AREA * size * size
	span = BASE_SPAN * size
	aspect_ratio = span * span / wing_area

## Wing loading in kg/m^2 — the number that decides how fast a bird flies.
func wing_loading() -> float:
	return mass / wing_area

## Lift coefficient for an angle of attack, with a soft stall past ALPHA_STALL.
static func lift_coefficient(a: float) -> float:
	var cl: float = CL_ALPHA * (a - ALPHA_ZERO_LIFT)
	if a > ALPHA_STALL:
		# Collapse lift past the stall: ramps down over ~12 degrees to ~0.55 CLmax.
		var over: float = (a - ALPHA_STALL) / deg_to_rad(12.0)
		cl = CL_MAX * lerpf(1.0, 0.55, clampf(over, 0.0, 1.0))
	elif a < -ALPHA_STALL:
		var over: float = (-a - ALPHA_STALL) / deg_to_rad(12.0)
		cl = -CL_MAX * 0.75 * lerpf(1.0, 0.55, clampf(over, 0.0, 1.0))
	return clampf(cl, -CL_MAX * 0.75, CL_MAX)

## Total drag coefficient: parasite + induced, plus a stall penalty.
func drag_coefficient(cl: float, a: float, p_spread: float) -> float:
	var cd0: float = lerpf(CD0_TUCKED, CD0_SPREAD, p_spread)
	var ar: float = maxf(aspect_ratio * lerpf(0.35, 1.0, p_spread), 1.0)
	var cdi: float = cl * cl / (PI * OSWALD * ar)
	var stall_pen: float = 0.0
	if absf(a) > ALPHA_STALL:
		stall_pen = 0.9 * clampf((absf(a) - ALPHA_STALL) / deg_to_rad(10.0), 0.0, 1.5)
	return cd0 + cdi + stall_pen

## Speed at which level flight at the given CL needs exactly the weight.
func level_speed_for_cl(cl: float) -> float:
	return sqrt(2.0 * mass * G / (RHO * wing_area * maxf(cl, 0.05)))

## Stall speed: the slowest level flight possible.
func stall_speed() -> float:
	return level_speed_for_cl(CL_MAX)

## A comfortable cruise: best glide ratio, roughly CL where induced = parasite.
func trim_speed() -> float:
	var cl_bg: float = sqrt(CD0_SPREAD * PI * OSWALD * aspect_ratio)
	return level_speed_for_cl(clampf(cl_bg, 0.4, 1.0))

func forward() -> Vector3:
	return heading

## Body basis: -Z forward, +Y up (after bank), +X right. Suitable for a Node3D.
func body_basis() -> Basis:
	var f: Vector3 = heading
	if f.length_squared() < 1e-6:
		f = Vector3.FORWARD
	var up_ref: Vector3 = Vector3.UP
	if absf(f.dot(up_ref)) > 0.98:
		up_ref = Vector3.BACK
	var right: Vector3 = f.cross(up_ref).normalized()
	var up: Vector3 = right.cross(f).normalized()
	# Roll about the forward axis by the bank angle.
	var rolled_up: Vector3 = up.rotated(f, bank)
	var rolled_right: Vector3 = right.rotated(f, bank)
	# Pitch the body by the angle of attack so the nose leads the velocity.
	var pitched_f: Vector3 = f.rotated(rolled_right, alpha)
	var pitched_up: Vector3 = rolled_up.rotated(rolled_right, alpha)
	return Basis(rolled_right, pitched_up, -pitched_f)

## Advances the model by dt using the given command. Returns the net force so a
## body can be driven by it, though most callers just read [member velocity].
func step(cmd: FlightCommand, dt: float) -> Vector3:
	if dt <= 0.0 or not is_finite(dt):
		return Vector3.ZERO
	cmd = cmd.clamped()
	spread = cmd.spread
	alpha = cmd.alpha
	# Bank follows the command with a rate limit: rolling takes time.
	bank = move_toward(bank, cmd.bank, BANK_RATE * dt)

	var air_v: Vector3 = velocity - wind
	var v: float = air_v.length()
	airspeed = v
	var vhat: Vector3 = air_v / v if v > 0.05 else heading

	# Body up: world-up made perpendicular to the flow, rolled by the bank.
	var up_ref: Vector3 = Vector3.UP
	if absf(vhat.dot(up_ref)) > 0.98:
		up_ref = heading if absf(vhat.dot(heading)) < 0.98 else Vector3.BACK
	var right: Vector3 = vhat.cross(up_ref).normalized()
	var up: Vector3 = right.cross(vhat).normalized()
	var lift_dir: Vector3 = up.rotated(vhat, bank)

	var area: float = wing_area * lerpf(MIN_AREA_FRACTION, 1.0, spread)
	var q: float = 0.5 * RHO * v * v
	var cl: float = lift_coefficient(alpha) * lerpf(0.4, 1.0, spread)
	var cd: float = drag_coefficient(cl, alpha, spread)
	stalled = absf(alpha) > ALPHA_STALL and v > 1.0

	var lift: Vector3 = lift_dir * (q * area * cl)
	var drag: Vector3 = -vhat * (q * area * cd)
	var gravity: Vector3 = Vector3.DOWN * (mass * G)

	# Flapping: thrust along the body forward, plus extra lift, scaled by wing
	# area so a big bird's beat moves more air. Only during a downstroke.
	var thrust: Vector3 = Vector3.ZERO
	if cmd.flap > 0.0:
		var f_fwd: Vector3 = heading * (FLAP_THRUST * cmd.flap * wing_area * lerpf(0.3, 1.0, spread))
		var f_up: Vector3 = lift_dir * (FLAP_LIFT * cmd.flap * wing_area * lerpf(0.3, 1.0, spread))
		thrust = f_fwd + f_up
		if absf(cmd.flap_asym) > 0.01:
			# One wing beating harder yaws the bird away from that wing.
			var yaw: float = cmd.flap_asym * FLAP_YAW_TORQUE * cmd.flap * dt
			velocity = velocity.rotated(Vector3.UP, yaw)
			heading = heading.rotated(Vector3.UP, yaw)

	last_lift = lift
	last_drag = drag
	last_thrust = thrust
	var force: Vector3 = lift + drag + gravity + thrust
	var accel: Vector3 = force / mass
	# Semi-implicit Euler; drag is stiff at high speed so cap the step's effect.
	velocity += accel * dt
	var sp: float = velocity.length()
	if sp > MAX_SPEED:
		velocity = velocity * (MAX_SPEED / sp)
	position += velocity * dt

	# The body forward follows the velocity with a short lag.
	if sp > 0.5:
		var target: Vector3 = velocity / sp
		var k: float = 1.0 - exp(-dt / HEADING_LAG)
		heading = heading.slerp(target, k).normalized()

	if not (is_finite(velocity.x) and is_finite(velocity.y) and is_finite(velocity.z)):
		velocity = heading * trim_speed()
	if not (is_finite(position.x) and is_finite(position.y) and is_finite(position.z)):
		position = Vector3(0, 100, 0)
	return force

## Kinetic + potential energy per kg; conserved in a glide with no drag.
func specific_energy() -> float:
	return 0.5 * velocity.length_squared() + G * position.y

## Textbook coordinated-turn rate for the current bank and speed.
func ideal_turn_rate() -> float:
	var v: float = maxf(airspeed, 0.1)
	return G * tan(bank) / v

## Reset to steady cruise pointing along `dir` at `pos`.
func launch(pos: Vector3, dir: Vector3, speed: float = -1.0) -> void:
	position = pos
	heading = dir.normalized() if dir.length_squared() > 0 else Vector3.FORWARD
	velocity = heading * (speed if speed > 0.0 else trim_speed())
	bank = 0.0
	alpha = 0.0
	spread = 1.0
	stalled = false
