extends SceneTree

## Prints the flight envelope as numbers:
##   godot --headless --xr-mode off --script res://tests/flight_report.gd
##
## The test suite answers "is it correct?". This answers "is it fun?" — cruise
## speed, how long a lap takes, how tight you can turn around a tree, how much
## height one flap buys. Those are the numbers that get tuned by hand.


func _initialize() -> void:
	print("")
	print("=== Soaring flight envelope ===")
	_envelope()
	_turning()
	_flap_value()
	_dive_and_zoom()
	_size_progression()
	quit(0)


func _envelope() -> void:
	var m := FlightModel.new()
	print("\n-- Glide polar (spread wings, steady state) --")
	print("  AoA(deg)  speed(m/s)  sink(m/s)   L/D")
	for i in 9:
		var alpha: float = 0.04 + 0.035 * i
		var h := FlightHarness.new(FlightModel.new())
		h.launch(h.model.trim_speed(), 0.0, 8000.0)
		var cmd := FlightCommand.new()
		cmd.alpha = alpha
		h.fly(cmd, 30.0)
		var start: Vector3 = h.position
		h.fly(cmd, 20.0)
		var sink: float = (start.y - h.position.y) / 20.0
		var ratio: float = h.glide_ratio(start)
		var stall_tag: String = "  <- stalled" if h.model.is_stalled else ""
		print("  %6.1f    %7.1f     %6.2f   %5.2f%s" % [
			rad_to_deg(alpha), h.speed(), sink, ratio, stall_tag
		])
	print("  trim speed: %.1f m/s   (hands neutral, wings level)" % m.trim_speed())


func _turning() -> void:
	print("\n-- Turning (level, coordinated) --")
	print("  bank(deg)  rate(deg/s)  radius(m)  time for 180(s)")
	for bank_deg: float in [15.0, 30.0, 45.0, 60.0, 75.0]:
		var bank: float = deg_to_rad(bank_deg)
		var m := FlightModel.new()
		var h := FlightHarness.new(m)
		h.launch(m.trim_speed() * 1.2, 0.0, 8000.0)
		var cmd := FlightCommand.new()
		cmd.bank = bank
		cmd.alpha = minf(m.alpha_trim / cos(bank), m.alpha_stall * 0.98)
		h.fly(cmd, 1.5)
		var heading_before: float = m.heading
		var speed_before: float = h.speed()
		h.fly(cmd, 2.0)
		var rate: float = absf(wrapf(m.heading - heading_before, -PI, PI)) / 2.0
		var radius: float = speed_before / maxf(rate, 1e-3)
		print("  %6.0f     %8.1f    %7.1f   %8.2f" % [
			bank_deg, rad_to_deg(rate), radius, PI / maxf(rate, 1e-3)
		])


func _flap_value() -> void:
	print("\n-- What one flap buys --")
	print("  stroke(m/s)  delta-v(m/s)  climb per flap(m)")
	for stroke: float in [1.5, 2.5, 3.5, 5.0]:
		var h := FlightHarness.new(FlightModel.new())
		h.launch(h.model.trim_speed(), 0.0, 1000.0)
		var cmd := FlightCommand.new()
		cmd.alpha = h.model.alpha_trim
		var before: float = h.specific_energy()
		var speed_before: float = h.speed()
		cmd.stroke_speed = stroke
		h.fly(cmd, 0.25)  # one downstroke
		cmd.stroke_speed = 0.0
		var gained_energy: float = h.specific_energy() - before
		print("  %8.1f     %9.2f     %14.2f" % [
			stroke, h.speed() - speed_before, gained_energy / 9.81
		])


func _dive_and_zoom() -> void:
	print("\n-- Dive and zoom (the core rhythm) --")
	var h := FlightHarness.new(FlightModel.new())
	h.launch(h.model.trim_speed(), 0.0, 400.0)
	var cmd := FlightCommand.new()
	cmd.span = 0.15
	cmd.alpha = -0.05
	var e0: float = h.specific_energy()
	h.fly(cmd, 6.0)
	print("  6s tuck dive:  %.1f m/s, lost %.0f m, kept %.0f%% of energy" % [
		h.speed(), 400.0 - h.altitude, 100.0 * h.specific_energy() / e0
	])

	var low: float = h.altitude
	var fast: float = h.speed()
	cmd.span = 1.0
	cmd.alpha = h.model.alpha_stall * 0.8
	h.fly(cmd, 4.5)
	print("  then zoom up:  %.1f m/s, regained %.0f m of the %.0f m lost" % [
		h.speed(), h.peak_altitude - low, 400.0 - low
	])
	print("  round trip kept %.0f%% of the starting energy" % [
		100.0 * h.specific_energy() / e0
	])


func _size_progression() -> void:
	print("\n-- How growth changes the bird (agar.io progression) --")
	print("  size   mass(kg)  trim(m/s)  45deg radius(m)  flap delta-v(m/s)")
	for s: float in [0.6, 1.0, 1.8, 3.0, 5.0, 8.0]:
		var m := FlightModel.new(s)
		var h := FlightHarness.new(m)
		h.launch(m.trim_speed() * 1.2, 0.0, 20000.0)
		var cmd := FlightCommand.new()
		cmd.bank = deg_to_rad(45.0)
		cmd.alpha = m.alpha_trim / cos(deg_to_rad(45.0))
		h.fly(cmd, 1.5)
		var heading_before: float = m.heading
		var speed_before: float = h.speed()
		h.fly(cmd, 2.0)
		var rate: float = absf(wrapf(m.heading - heading_before, -PI, PI)) / 2.0
		var radius: float = speed_before / maxf(rate, 1e-3)

		var f := FlightHarness.new(FlightModel.new(s))
		f.launch(f.model.trim_speed(), 0.0, 1000.0)
		var fc := FlightCommand.new()
		fc.alpha = f.model.alpha_trim
		fc.stroke_speed = 3.0
		var v0: float = f.speed()
		f.fly(fc, 0.25)
		print("  %4.1f   %7.1f   %8.1f   %13.1f   %14.2f" % [
			s, m.mass, m.trim_speed(), radius, f.speed() - v0
		])
