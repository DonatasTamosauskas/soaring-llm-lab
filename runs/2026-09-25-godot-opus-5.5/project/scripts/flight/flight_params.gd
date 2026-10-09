class_name FlightParams
extends RefCounted
## Constants derived for one body mass (FLIGHT_SPEC §7.1).
##
## Everything comes from SizeRules.performance(mass) plus the per-size
## anchors in FlightTuning, so the flight envelope follows the game loop's
## ladder automatically. derive() is cheap (a few dozen flops plus one cached
## detector lookup) and runs whenever the mass changes; FlightModel keeps its
## state across it, so growth is continuous.

const G := FlightMath.G

var mass := 0.03
## Size scalar: 0 = smallest species (moth), 1 = largest (eagle), log-mass.
var x := 0.0
## 0 = sparrow (player start), 1 = eagle: the detector's effort scaling.
var xn := 0.0
var span := 0.24
var r_body := 0.038

var v_c := 9.0
var v_min := 4.05
var v_max := 23.4
var turn_rate := 3.84
var climb := 4.0
var agility := 1.0

var cl_n := 0.30
var cl_max := 1.48
var s := 0.02
var ar := 5.36
var k_i := 0.07
var ld := 8.9
var cd0 := 0.045
var a := 4.6
var alpha_n := 0.065
var alpha_s := 0.322
var phi_max := 1.29
var n_max := 4.5
var t_ph := 4.08

var tau_alpha := 0.112
var q_max := 5.6
var tau_bank := 0.186
var p_max := 6.0
var k_flap := 1.5
var k_hover := 1.2
var up_gain := 0.3
var tau_f := 0.3
var p_spec := 4.72
## Mean net effort (flap + up_gain * up) of the reference stroke through the
## detector at this size (§6.4): the model divides flap effort by it.
var p_ref := 0.445
## Same with max(0, up_gain): the power and endurance caps' reference.
var p_ref_pos := 0.445
var e_cap := 1.15
var tau_wc := 0.35
var tau_sf := 0.21


static func derive(p_mass: float, tuning: FlightTuning = null) -> FlightParams:
	var p := FlightParams.new()
	p.set_mass(p_mass, tuning)
	return p


func set_mass(p_mass: float, tuning: FlightTuning = null) -> void:
	var tu := tuning if tuning != null else FlightTuning.default_tuning()
	mass = maxf(p_mass, 0.001)
	x = size_x_for_mass(mass)
	var xs := size_x_for_species(&"sparrow")
	xn = clampf((x - xs) / maxf(1.0 - xs, 1e-6), 0.0, 1.0)
	span = SizeRules.wingspan_for_mass(mass)
	r_body = SizeRules.body_radius_for_mass(mass)
	var perf := SizeRules.performance(mass)
	v_c = perf["cruise"]
	v_min = perf["min_speed"]
	v_max = perf["max_speed"] * tu.dive_speed
	turn_rate = perf["turn_rate"]
	climb = perf["climb"]
	agility = perf["agility"]

	cl_n = tu.cl_n
	a = tu.lift_slope
	# 1-g stall exactly at V_min.
	cl_max = cl_n * pow(v_c / v_min, 2.0)
	# Effective area: trims at cruise with the neutral-wrist CL.
	s = 2.0 * mass * G / (tu.rho * v_c * v_c * cl_n)
	ar = tu.anchor("aspect", x)
	k_i = 1.0 / (PI * tu.oswald * ar)
	ld = tu.anchor("ld_max", x) * tu.glide_efficiency
	cd0 = 1.0 / (4.0 * k_i * ld * ld)
	alpha_n = cl_n / a
	alpha_s = cl_max / a
	# The bank that gives SizeRules.turn_rate at cruise.
	phi_max = clampf(atan(turn_rate * v_c / G), deg_to_rad(55.0), deg_to_rad(78.0))
	n_max = maxf(1.05 / cos(phi_max), 3.0 + 1.5 * agility)
	t_ph = PI * sqrt(2.0) * v_c / G

	tau_alpha = tu.anchor("tau_alpha", x)
	q_max = deg_to_rad(tu.anchor("pitch_rate_deg", x))
	tau_bank = tu.anchor("tau_bank", x)
	p_max = deg_to_rad(tu.anchor("roll_rate_deg", x)) * tu.roll_rate_scale
	k_flap = tu.anchor("flap_force", x) * tu.flap_power
	k_hover = tu.anchor("hover_force", x) * tu.flap_power
	up_gain = tu.anchor("up_gain", x)
	tau_f = tu.anchor("flap_tau", x)
	p_spec = (tu.p_spec_gain * climb + tu.p_spec_offset) * tu.flap_power
	var means := FlapDetector.reference_means(x)
	p_ref = means.x + up_gain * means.y
	p_ref_pos = means.x + maxf(0.0, up_gain) * means.y
	e_cap = tu.e_cap
	tau_wc = 0.35 + 0.35 * (1.0 - agility)
	tau_sf = 0.6 * tau_wc


## Size scalar for a mass: log position between the ladder's smallest and
## largest species (moth 0 ... eagle 1), clamped.
static func size_x_for_mass(m: float) -> float:
	var lo: float = SizeRules.SPECIES[0]["mass"]
	var hi: float = SizeRules.SPECIES[SizeRules.SPECIES.size() - 1]["mass"]
	return clampf(log(maxf(m, 1e-6) / lo) / log(hi / lo), 0.0, 1.0)


static func size_x_for_species(id: StringName) -> float:
	var d := SizeRules.species_data(id)
	if d.is_empty():
		return 0.0
	return size_x_for_mass(float(d["mass"]))


static func species_mass(id: StringName) -> float:
	var d := SizeRules.species_data(id)
	return float(d["mass"]) if not d.is_empty() else 0.03


## Mass-specific wing loading (N/m^2) for reporting.
func wing_loading() -> float:
	return mass * G / s


func to_dict() -> Dictionary:
	return {
		"mass": mass, "x": x, "span": span, "v_c": v_c, "v_min": v_min, "v_max": v_max,
		"turn_rate_deg": rad_to_deg(turn_rate), "climb": climb, "agility": agility,
		"S": s, "W/S": wing_loading(), "AR": ar, "CD0": cd0, "LD": ld,
		"phi_max_deg": rad_to_deg(phi_max), "n_max": n_max, "T_ph": t_ph,
		"tau_alpha": tau_alpha, "tau_bank": tau_bank, "K_F": k_flap, "K_H": k_hover,
		"up_gain": up_gain, "tau_f": tau_f, "P_spec": p_spec, "p_ref": p_ref,
		"alpha_s_deg": rad_to_deg(alpha_s), "alpha_n_deg": rad_to_deg(alpha_n),
	}
