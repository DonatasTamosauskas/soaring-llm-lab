extends TestCase
## Round-2 engineering verifier: F9 anti-cheese boundary grid (probe only).
## Frantic hand shaking (the area's own "frantic" pattern: mostly vertical,
## the two hands 0.7 rad out of phase) at amplitudes and rates around the
## area's pinned set, through WingInput -> FlightModel for 10 s: net climb vs
## a still glide, and credited onsets.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r2eng_f9grid

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DT := 1.0 / 72.0


func _shake(amp_m: float, hz: float) -> WR:
	var body := HumanPoseModel.new(14)
	return WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for side in 2:
			var ph := 0.7 * side
			b.hand_offset[side] = Vector3(0.3 * sin(TAU * hz * t * 1.1 + ph), sin(TAU * hz * t + ph), 0.2 * cos(TAU * hz * t)) * amp_m, false, body)


func _glide(rig: WR, sp: StringName) -> Array:
	var m := FS.model(sp)
	rig.wi.size_x = m.params.x
	rig.run(1.0)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	var onsets := 0
	for i in 720:
		var w := rig.step()
		onsets += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
		m.step(w, env, DT)
	return [m.position.y, onsets]


func test_f9_grid() -> void:
	var table := []
	for sp: StringName in [&"sparrow", &"eagle"]:
		var base: float = _glide(WR.new(WR.airplane()), sp)[0]
		for amp in [0.03, 0.05, 0.08, 0.10]:
			for hz in [4.0, 6.0, 8.0, 10.0, 12.0]:
				var r := _glide(_shake(amp, hz), sp)
				var dh: float = r[0] - base
				table.append([String(sp), amp * 100.0, hz, snappedf(dh, 0.001), r[1]])
				if amp <= 0.05:
					lt(dh, 0.05, "%s +-%.0f cm @ %.0f Hz: no net climb vs a still glide (m)" % [sp, amp * 100.0, hz])
	metric("grid_sp_ampcm_hz_dh_onsets", table)
	for row in table:
		print("[flight-verify] F9 grid %s" % str(row))
