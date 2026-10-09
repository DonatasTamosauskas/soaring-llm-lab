extends TestCase
## Round-2 engineering verifier: does flap thrust depend on the physics tick
## rate? The same reference stroke (45 deg, 1 Hz, wrists -10 deg) through
## poses -> WingInput -> FlightModel for 15 s at 72, 90 and 120 Hz (VR sets
## the physics rate to the display rate). FM-24 covers the model with fixed
## commands only.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r2eng_rate

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")


func _climb(sp: StringName, hz: float, amp: float) -> Dictionary:
	var m := FS.model(sp)
	var body := HumanPoseModel.new(7)
	var src := ScriptedPoseSource.new(body, func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, amp, 1.0)
		for a in b.arms:
			a.twist = -10.0 * PI / 180.0)
	var wi := WingInput.new()
	wi.auto_calibrate = false
	wi.size_x = m.params.x
	var frame := PoseFrame.new()
	var dt := 1.0 / hz
	for i in int(round(2.0 * hz)):
		src.sample(frame, dt)
		wi.update(frame, dt)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	var flap_int := 0.0
	var onsets := 0
	for i in int(round(15.0 * hz)):
		src.sample(frame, dt)
		var w := wi.update(frame, dt)
		flap_int += 0.5 * (w.flap_l + w.flap_r) * dt
		onsets += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
		m.step(w, env, dt)
	return {"dh": m.position.y - 500.0, "dist": Vector2(m.position.x, m.position.z).length(), "flap_int": flap_int,
		"onsets": onsets, "v": m.airspeed()}


func test_flap_thrust_vs_tick_rate() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for amp in [45.0, 25.0]:
			var r72 := _climb(sp, 72.0, amp)
			for hz in [90.0, 120.0]:
				var r := _climb(sp, hz, amp)
				var tag := "%s %d deg %d Hz" % [sp, int(amp), int(hz)]
				metric(tag, {"dh": r["dh"], "dh72": r72["dh"], "flap_int": r["flap_int"], "flap_int72": r72["flap_int"],
					"onsets": r["onsets"], "onsets72": r72["onsets"], "dist": r["dist"], "dist72": r72["dist"]})
				print("[flight-verify] %s: dh %.2f vs %.2f (72 Hz), flap integral %.3f vs %.3f, onsets %d vs %d, dist %.1f vs %.1f" % [
					tag, r["dh"], r72["dh"], r["flap_int"], r72["flap_int"], r["onsets"], r72["onsets"], r["dist"], r72["dist"]])
				near(float(r["flap_int"]) / float(r72["flap_int"]), 1.0, 0.05, "%s: flap effort integral within 5%% of 72 Hz" % tag)
				near(float(r["dh"]) - float(r72["dh"]), 0.0, 0.05 * absf(float(r72["dh"])) + 0.5, "%s: altitude change within 5%% of 72 Hz" % tag)
