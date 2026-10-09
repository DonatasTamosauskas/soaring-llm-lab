extends TestCase
## Verifier trace (round 1, flight): per-tick attitude around FM-05(a)'s
## stall release (the alpha step visible in f3_stall.png) and around the
## F11 composite's flare (the +90 -> -90 deg body-pitch flip in f11_comfort.png).

const DT := 1.0 / 72.0
const DEG := PI / 180.0


func test_trace_unstall_attitude() -> void:
	var worst := {}
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var tu := FlightTuning.new()
		tu.preset = 1
		var m := FlightModel.new(FlightParams.species_mass(sp), tu)
		m.trim(Vector3(0, 3000, 0), 0.0, 0.8)
		var ws := WingState.new()
		var prev_theta := m.theta
		var prev_alpha := m.alpha
		var max_dtheta := 0.0
		var max_dalpha := 0.0
		for i in int(8.0 / DT):
			var p := 1.0 if i < int(2.0 / DT) else 0.0
			ws.set_commands(p, 0.0, 1.0, 0.0, 0.0)
			var was := m.stalled
			m.step(ws, null, DT)
			var dth := absf(m.theta - prev_theta)
			var dal := absf(m.alpha - prev_alpha)
			if dth > max_dtheta:
				max_dtheta = dth
			if dal > max_dalpha:
				max_dalpha = dal
			if (was != m.stalled) or (i >= int(1.9 / DT) and i <= int(2.2 / DT)) or dal > 2.0 * DEG:
				print("[flight_verify] %s t %.3f pitch %.1f stalled %s theta %.2f gamma %.2f alpha %.2f dtheta %.2f dalpha %.2f V %.2f" % [sp, (i + 1) * DT, p,
					str(m.stalled), rad_to_deg(m.theta), rad_to_deg(m.gam), rad_to_deg(m.alpha), rad_to_deg(m.theta - prev_theta), rad_to_deg(m.alpha - prev_alpha), m.airspeed()])
			prev_theta = m.theta
			prev_alpha = m.alpha
		worst[sp] = [rad_to_deg(max_dtheta), rad_to_deg(max_dalpha)]
	print("[flight_verify] worst per-tick |dtheta|, |dalpha| (deg): ", worst)
	check(true, "trace")


func test_trace_zoom_flip() -> void:
	# A vertical zoom from a fast dive with full nose-up until the bird tail-slides.
	var tu := FlightTuning.new()
	tu.preset = 1
	var m := FlightModel.new(0.03, tu)
	m.trim(Vector3(0, 3000, 0), 0.0, 0.0)
	var ws := WingState.new()
	for i in int(3.0 / DT):
		ws.set_commands(-1.0, 0.0, 0.0, 0.0, 0.0)
		m.step(ws, null, DT)
	var prev := m.theta
	var worst := 0.0
	for i in int(6.0 / DT):
		ws.set_commands(0.9, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, null, DT)
		var d := absf(m.theta - prev)
		if d > 5.0 * DEG:
			print("[flight_verify] zoom t %.3f theta %.1f (step %.1f deg) gamma %.1f V %.2f v %s" % [(i + 1) * DT, rad_to_deg(m.theta), rad_to_deg(m.theta - prev), rad_to_deg(m.gam), m.airspeed(), str(m.velocity)])
		worst = maxf(worst, d)
		prev = m.theta
	print("[flight_verify] zoom worst per-tick |dtheta| %.1f deg" % rad_to_deg(worst))
	check(true, "trace")
