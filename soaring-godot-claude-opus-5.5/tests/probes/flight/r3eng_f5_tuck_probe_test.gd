extends TestCase
## Round-3 engineering verifier: F5 "tuck -> dive and speed build toward
## max" with the tuck ALONE (wrists neutral). FM-15 dives with pitch -1 and
## spread 0 together, so the tuck's own contribution is not isolated there.
##   tools/gd.sh flight_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight --suite=r3eng_f5

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")


func test_f5_tuck_alone_dives_toward_vmax() -> void:
	for sp in FS.S3:
		var m := FS.model(sp)
		var p := m.params
		m.trim(Vector3(0, 3000, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 20 * 72, FS.glide(0.0, 0.0, 0.0), null, rec)
		var t95 := -1.0
		var t90 := -1.0
		for i in rec.size():
			if t90 < 0.0 and rec.v[i] >= 0.90 * p.v_max:
				t90 = rec.t[i]
			if rec.v[i] >= 0.95 * p.v_max:
				t95 = rec.t[i]
				break
		var vmax_ratio := FS.maxv(rec.v) / p.v_max
		print("[flight-verify] F5 tuck alone %s: t90 %.2f s, t95 %.2f s, max V / V_max %.3f in 20 s" % [sp, t90, t95, vmax_ratio])
		metric("%s_tuck_alone" % sp, {"t90": t90, "t95": t95, "vmax_ratio": vmax_ratio})
		# "Speed builds toward max": >= 0.9 V_max within 15 s with the wrists neutral
		# (informational bound chosen by the verifier; FM-15 pins the pitch -1 dive).
		check(t90 > 0.0 and t90 <= 15.0, "%s: tuck alone (wrists neutral) reaches 0.9 V_max within 15 s (%.2f)" % [sp, t90])
		lt(vmax_ratio, 1.03, "%s: tuck alone never exceeds 1.03 V_max" % sp)
