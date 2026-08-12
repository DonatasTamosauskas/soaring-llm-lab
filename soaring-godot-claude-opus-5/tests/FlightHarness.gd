class_name FlightHarness
extends RefCounted

## Flies a [FlightModel] through a scripted manoeuvre and records what happened.
## This is what makes "is the flight good?" a question with a numeric answer
## instead of a matter of taste.

var model: FlightModel
var altitude: float = 0.0
var position: Vector3 = Vector3.ZERO
var elapsed: float = 0.0

var peak_speed: float = 0.0
var min_speed: float = INF
var peak_altitude: float = -INF
var min_altitude: float = INF
var ever_nonfinite: bool = false


func _init(m: FlightModel = null) -> void:
	model = m if m != null else FlightModel.new()


func launch(speed: float, climb_angle: float = 0.0, start_altitude: float = 100.0) -> void:
	model.velocity = Vector3(0.0, sin(climb_angle), -cos(climb_angle)) * speed
	model.heading = 0.0
	model.bank = 0.0
	altitude = start_altitude
	position = Vector3(0.0, start_altitude, 0.0)
	elapsed = 0.0
	peak_speed = speed
	min_speed = speed
	peak_altitude = start_altitude
	min_altitude = start_altitude


## Runs [param seconds] of simulation at a fixed 90 Hz — the same rate the game
## physics ticks at — optionally calling [param driver] each step to adjust the
## command (that is how manoeuvres like "pull up once you're fast" are scripted).
func fly(cmd: FlightCommand, seconds: float, driver: Callable = Callable()) -> void:
	var dt: float = 1.0 / 90.0
	var steps: int = int(round(seconds / dt))
	for i in steps:
		if driver.is_valid():
			driver.call(self, cmd, elapsed)
		model.step(cmd, dt)
		position += model.velocity * dt
		altitude = position.y
		elapsed += dt
		_record()


func _record() -> void:
	var s: float = model.velocity.length()
	if not is_finite(s) or not model.velocity.is_finite() or not is_finite(altitude):
		ever_nonfinite = true
		return
	peak_speed = maxf(peak_speed, s)
	min_speed = minf(min_speed, s)
	peak_altitude = maxf(peak_altitude, altitude)
	min_altitude = minf(min_altitude, altitude)


func speed() -> float:
	return model.velocity.length()


func specific_energy() -> float:
	return model.specific_energy(altitude)


## Lift-to-drag ratio achieved over the run, measured the honest way: horizontal
## distance travelled divided by altitude lost.
func glide_ratio(from_position: Vector3) -> float:
	var drop: float = from_position.y - position.y
	if drop <= 0.001:
		return INF
	var run: float = Vector2(position.x - from_position.x, position.z - from_position.z).length()
	return run / drop
