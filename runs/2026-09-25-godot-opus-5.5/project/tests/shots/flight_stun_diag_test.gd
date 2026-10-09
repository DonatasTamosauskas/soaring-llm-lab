extends TestCase
## Diagnostic: per-tick heading / rig / debt around an oblique stun.
const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0

func test_stun() -> void:
	var fx := FX.new(self)
	var inc := float(Paths.arg("inc", "30"))
	await fx.setup(StringName(Paths.arg("species", "sparrow")), func(w: Variant) -> void:
		w.with_ground = false
		w.add_wall(Vector3(0, 100, -20), Vector3(400, 80, 1.0)))
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(pr.v_c * 0.8 * cos(inc * DEG), 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
	p.start_flying(start, (90.0 - inc) * DEG, 0.0)
	var seen := -1
	for i in int(4.0 / DT):
		fx.step()
		if seen < 0 and p.mode == PlayerBird.Mode.STUNNED:
			seen = i
		if seen >= 0 and (i - seen < 4 or (i - seen) % 9 == 0):
			print("[flight] t=%.3f mode %s hdg %.2f rig %.2f debt %.2f vt_rate %.1f rate %.1f acc %.0f" % [i * DT, p.mode_name(),
				rad_to_deg(p.model.heading()), rad_to_deg(p.rig_yaw), rad_to_deg(p.view_turn.debt), rad_to_deg(p.view_turn.rate),
				rad_to_deg(p.rig_yaw_rate), rad_to_deg(p.rig_yaw_accel)])
	fx.teardown()
	check(true, "traced")
