extends TestCase
## Diagnostic (not part of the suite): traces slow perch approaches in a
## uniform wind, 0.1 s per line. Run:
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_perchwind_diag

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 20, -10)

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func _trace(sp: StringName, wind: Vector3, c: Dictionary) -> void:
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.015, 1.0)
		w.uniform_wind = wind)
	var p := fx.player
	var pr := p.model.params
	var vcap := 0.8 * pr.v_min
	var target := PERCH + Vector3.UP * pr.r_body
	var sol := p.model.trim_solution(c["pitch"])
	var g0: float = sol["gamma"]
	var back: float = float(c["back"]) * pr.span
	var start := target + Vector3(0, -back * tan(g0) + float(c["off"]) * pr.span, back)
	p.start_flying(start, 0.0, c["pitch"])
	p.model.velocity += wind
	fx.driver = fx.synth(c["pitch"], 0.0, 1.0)
	print("[flight] == %s wind %s %s trim V %.2f (%.2f V_min) gamma %.1f deg (V_cap %.2f, span %.3f)" % [
		sp, wind, str(c), sol["v"], float(sol["v"]) / pr.v_min, rad_to_deg(g0), vcap, pr.span])
	var res := -1.0
	for i in int(4.0 / DT):
		fx.step()
		var rel := (p.model.position - target) / pr.span
		if i % int(Paths.arg("every", "4")) == 0 or p.mode == PlayerBird.Mode.PERCHED or absf(p.rig_yaw_accel) > 5.0:
			print("[flight]   t=%.2f rel=(%.2f,%.2f,%.2f) air %.2f gnd %.2f vz %.2f mode %s cand %s acc %s ab %.1f db %.2f rig %.0f/%.0f" % [
				i * DT, rel.x, rel.y, rel.z, p.model.airspeed(), p.model.velocity.length(), p.model.velocity.y, p.mode_name(),
				str(p.perch_candidate != null), p.env.accel.snapped(Vector3.ONE * 0.01), rad_to_deg(p.env.alpha_bias), p.env.drag_bonus,
				rad_to_deg(p.rig_yaw_rate), rad_to_deg(p.rig_yaw_accel)])
		var t_now := i * DT
		if t_now >= float(Paths.arg("t0", "99")) and t_now <= float(Paths.arg("t1", "-1")):
			print("[flight]     tick t=%.3f hdg %.2f rig %.2f debt %.2f vt_rate %.1f chi %.2f dpsi %.2f air %.2f contacts %s acc %s mode %s" % [
				t_now, rad_to_deg(p.model.heading()), rad_to_deg(p.rig_yaw), rad_to_deg(p.view_turn.debt), rad_to_deg(p.view_turn.rate),
				rad_to_deg(p.model.chi), rad_to_deg(p.model.dpsi), p.model.airspeed(), str(p.contacts), p.env.accel.snapped(Vector3.ONE * 0.01), p.mode_name()])
		if p.mode == PlayerBird.Mode.PERCHED or rel.z < -3.0:
			res = i * DT if p.mode == PlayerBird.Mode.PERCHED else -1.0
			break
	print("[flight]   -> perched at %.2f" % res)
	fx.teardown()
	fx = null


func test_trace() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var w := Vector3(float(Paths.arg("wx", "0")), 0, float(Paths.arg("wz", "0")))
	await _trace(sp, w, {"back": float(Paths.arg("back", "9")), "off": float(Paths.arg("off", "0")), "pitch": float(Paths.arg("pitch", "0.8"))})
	check(true, "traced")
