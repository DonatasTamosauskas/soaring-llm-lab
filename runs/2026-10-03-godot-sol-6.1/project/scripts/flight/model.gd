extends RefCounted
## Arcade aerodynamics in metres and seconds. The lift polar, transient angle
## of attack response, stall and bank coupling remain recognizable, but trim
## assistance and powerful downstrokes keep flying playful and sustainable.

const GRAVITY := 9.2
const MAX_STEP := 1.0 / 90.0
var velocity := Vector3(0.0, 0.0, -13.8)
var heading := 0.0
var pitch := 0.0
var bank := 0.0
var lift := 0.0
var drag := 0.0
var stalled := false
var wing_spread := 0.82
var last_flap := 0.0

func reset(new_heading: float = 0.0, initial_speed: float = 13.8) -> void:
	heading = new_heading
	velocity = Vector3(0.0, 0.0, -initial_speed).rotated(Vector3.UP, heading)
	pitch = 0.0
	bank = 0.0
	last_flap = 0.0
	stalled = false

func update(delta: float, controls: Dictionary, body_mass: float = 1.0, thermal_lift: float = 0.0) -> Dictionary:
	var dt := clampf(delta, 0.0, 0.25)
	var mass := clampf(body_mass, 0.4, 64.0)
	var flap_strength := clampf(float(controls.get("flap", 0.0)), 0.0, 1.6)
	if flap_strength > 0.0:
		velocity.y += 7.7 * flap_strength / pow(mass, 0.14)
		velocity += Vector3(0.0, 0.0, -2.6 * flap_strength / pow(mass, 0.12)).rotated(Vector3.UP, heading)
		last_flap = flap_strength
	var count := maxi(1, int(ceil(dt / MAX_STEP)))
	for step in range(count):
		_integrate(dt / float(count), controls, mass, clampf(thermal_lift, 0.0, 18.0))
	return {"speed": Vector2(velocity.x, velocity.z).length(), "vertical_speed": velocity.y, "lift": lift, "drag": drag, "stall": stalled, "bank": bank, "pitch": pitch, "spread": wing_spread, "heading": heading}

func _integrate(dt: float, controls: Dictionary, mass: float, thermal_lift: float) -> void:
	if dt <= 0.0:
		return
	var target_pitch := clampf(float(controls.get("pitch", 0.0)), -1.0, 1.0)
	var old_pitch := pitch
	pitch = lerpf(pitch, target_pitch, 1.0 - exp(-7.5 * dt))
	bank = lerpf(bank, clampf(float(controls.get("bank", 0.0)), -1.0, 1.0), 1.0 - exp(-4.5 * dt))
	var tuck := clampf(float(controls.get("tuck", 0.0)), 0.0, 1.0)
	var brake := clampf(float(controls.get("brake", 0.0)), 0.0, 1.0)
	wing_spread = lerpf(clampf(float(controls.get("spread", 0.82)), 0.08, 1.0), 0.10, tuck)
	var speed := Vector2(velocity.x, velocity.z).length()
	var stall_speed := 6.4 * pow(mass, 0.065)
	var speed_lift := smoothstep(stall_speed * 0.62, stall_speed * 1.28, speed)
	var alpha_lift := clampf(1.0 - maxf(0.0, pitch - 0.64) * 1.5, 0.44, 1.0)
	stalled = speed < stall_speed or pitch > 0.82
	lift = minf(18.0, speed * speed * 0.060 * wing_spread * (1.0 + pitch * 0.58) * speed_lift * alpha_lift * cos(bank * 0.72) / pow(mass, 0.035))
	# A quick increase in incidence balloons briefly, then induced drag slows us.
	var balloon := clampf((pitch - old_pitch) / dt * 1.1, -3.0, 4.2)
	var vertical_drag := (0.60 + wing_spread * 0.65 + brake * 1.2) * velocity.y
	velocity.y += (lift - GRAVITY + balloon + thermal_lift - vertical_drag) * dt
	velocity.y = clampf(velocity.y, -16.0, 13.0)
	var trim_speed := (17.0 - wing_spread * 4.0 + tuck * 9.0 - brake * 3.8 - maxf(0.0, pitch) * 4.2 + maxf(0.0, -pitch) * 3.0 - absf(bank) * 1.8) * pow(mass, 0.045)
	var response := (0.58 + wing_spread * 0.58 + brake * 0.8) / pow(mass, 0.14)
	drag = response * (speed - trim_speed)
	var acceleration := -drag - velocity.y * 0.20
	speed = clampf(speed + acceleration * dt, 2.0, 34.0)
	var turn_rate := bank * clampf(speed / 12.0, 0.45, 1.25) * 1.08 / pow(mass, 0.19)
	heading = wrapf(heading - turn_rate * dt, -PI, PI)
	var forward := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, heading)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal.length_squared() < 0.001:
		horizontal = forward
	var direction := horizontal.normalized().lerp(forward, 1.0 - exp(-3.2 / pow(mass, 0.12) * dt)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
