extends TestCase
## Round-3 engineering verifier: F1 "upstroke force much weaker than the
## downstroke", measured from the force the integrator APPLIES (not from
## params.up_gain). The area's own checks (FM-11 and flap_detector f1)
## derive the upstroke share from m.params.up_gain, so a model whose force
## ignores up_gain passes them; these probes would not.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r3eng_f1

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0


func _rig(x: float) -> WR:
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0))
	r.wi.size_x = x
	return r


## (a) Counterfactual: the same WingState stream flown twice, once with the
## upstroke commands zeroed (downstroke force only) and once with the
## downstroke commands zeroed (upstroke force only). The vertical flap
## impulse of each is the force that command produces.
## (b) Arm phase: the vertical flap impulse delivered while the arms rise vs
## while they fall (reference stroke: top at phase 0, bottom at 0.5).
func test_f1_upstroke_force_from_applied_impulse() -> void:
	for sp in FS.S3:
		var m_dn := FS.model(sp)
		var m_up := FS.model(sp)
		var m_all := FS.model(sp)
		var rig := _rig(m_all.params.x)
		rig.run(2.0)
		for m in [m_dn, m_up, m_all]:
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var env := FlightEnv.new()
		var w_dn := WingState.new()
		var w_up := WingState.new()
		var imp := {"dn": 0.0, "up": 0.0, "ph_down": 0.0, "ph_up": 0.0}
		for i in 5 * 72:
			var w := rig.step()
			var t := (rig.tick - 1) * DT + 2.0
			w_dn.copy_from(w)
			w_dn.up_l = 0.0
			w_dn.up_r = 0.0
			w_up.copy_from(w)
			w_up.flap_l = 0.0
			w_up.flap_r = 0.0
			for pair in [[m_dn, w_dn, "dn"], [m_up, w_up, "up"]]:
				var m: FlightModel = pair[0]
				var i0 := m.flap_impulse
				m.step(pair[1], env, DT)
				imp[pair[2]] += (m.flap_impulse - i0).dot(FS.frame(m)[1])
			var j0 := m_all.flap_impulse
			m_all.step(w, env, DT)
			var dy: float = (m_all.flap_impulse - j0).dot(FS.frame(m_all)[1])
			var ph: float = fposmod(t * 1.0, 1.0)
			imp["ph_down" if ph < 0.5 else "ph_up"] += dy
		var cf: float = imp["up"] / imp["dn"]
		var phase: float = imp["ph_up"] / imp["ph_down"]
		print("[flight-verify] F1 upstroke %s: counterfactual up/down %.3f, arm-phase up/down %.3f (params.up_gain %.2f)" % [sp, cf, phase, m_all.params.up_gain])
		metric("%s_upstroke" % sp, {"counterfactual": cf, "arm_phase": phase, "up_gain": m_all.params.up_gain})
		gt(imp["dn"], 0.0, "%s: the downstroke lifts" % sp)
		lt(absf(cf), 0.35, "%s: upstroke commands produce < 35%% of the downstroke's vertical impulse (applied force)" % sp)
		lt(phase, 0.35, "%s: vertical flap impulse while the arms rise < 35%% of that while they fall" % sp)
