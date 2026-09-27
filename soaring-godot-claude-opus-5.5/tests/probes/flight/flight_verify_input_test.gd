extends TestCase
## Verifier probes (round 1, flight): the input chain under adversarial arm
## motion. Poses -> WingInput -> FlightModel, exactly as a player flies.
##   F9: a grid of small / fast hand shakes, small-arc waggles, tracking
##       jitter, one-hand shakes and wrist rolls, at three sizes.
##   F1: flap impulse direction through the chain for all 8 player sizes,
##       with head look-around, torso rotation, room offset, tremor.
## Run: tools/gd.sh flight_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/flight

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0
const SP: Array[StringName] = [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
const S3: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]

var _lines := PackedStringArray()


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("input_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))
	print("[flight_verify] wrote ", path)


func _model(sp: StringName) -> FlightModel:
	var tu := FlightTuning.new()
	tu.preset = 1
	return FlightModel.new(FlightParams.species_mass(sp), tu)


## 12 s from a trimmed glide at 500 m, the WingState coming from `rig`.
## Returns {dh (absolute), net (mean net effort / p_ref), onsets}.
func _fly(rig: WR, sp: StringName, secs := 12.0) -> Dictionary:
	var m := _model(sp)
	rig.wi.size_x = m.params.x
	rig.run(1.5)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var e0 := m.position.y + m.velocity.length_squared() / (2.0 * 9.81)
	var env := FlightEnv.new()
	var net := 0.0
	var onsets := 0
	var n := int(round(secs / DT))
	for i in n:
		var w := rig.step()
		m.step(w, env, DT)
		net += 0.5 * (w.flap_l + w.flap_r + m.params.up_gain * (w.up_l + w.up_r))
		onsets += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
	return {"dh": m.position.y - 500.0, "net": net / n / maxf(m.params.p_ref, 1e-6), "onsets": onsets,
		"finite": is_finite(m.position.y), "e": m.position.y + m.velocity.length_squared() / (2.0 * 9.81),
		"de_rate": (m.position.y + m.velocity.length_squared() / (2.0 * 9.81) - e0) / secs}


func _still() -> WR:
	return WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane())


## Both hands oscillate vertically (in phase) by +-amp metres at hz.
func _vshake(amp: float, hz: float, one_hand := false) -> WR:
	return WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var y := amp * sin(TAU * hz * t)
		b.hand_offset[0] = Vector3(0, y, 0) if not one_hand else Vector3.ZERO
		b.hand_offset[1] = Vector3(0, y, 0))


## Small-arc arm-elevation waggle: +-amp_deg at hz (duty = downstroke share).
func _waggle(amp_deg: float, hz: float, duty := 0.5, twist_deg := 0.0) -> WR:
	return WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, amp_deg, hz, 0, duty)
		for a in b.arms:
			a.twist = twist_deg * DEG)


## Tracking jitter: white noise (sigma metres per axis, per tick) on both hands.
func _jitter(sigma: float, seed: int) -> WR:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for s in 2:
			b.hand_offset[s] = Vector3(rng.randfn(0.0, sigma), rng.randfn(0.0, sigma), rng.randfn(0.0, sigma)))


## Wrist roll oscillation (+-deg at hz): rotating the controller, no arm motion.
func _wrist_roll(amp_deg: float, hz: float) -> WR:
	return WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var tw := amp_deg * DEG * sin(TAU * hz * t)
		b.arms[0].twist = tw
		b.arms[1].twist = tw)


## Best (smallest) steady sink rate over the pitch range, m/s.
func _min_sink(sp: StringName) -> float:
	var m := _model(sp)
	var best := INF
	for k in 41:
		var sol := m.trim_solution(-1.0 + k * 0.05)
		best = minf(best, float(sol["v"]) * sin(-float(sol["gamma"])))
	return best


# --- F9 ---------------------------------------------------------------------------

func test_f9_shake_grid() -> void:
	_lines.append("F9 shake grid: dh = altitude after 12 s minus the still glide's (m); net = mean effort / reference")
	for sp in S3:
		var base: Dictionary = _fly(_still(), sp)
		var real: Dictionary = _fly(_waggle(45.0, 1.0, 0.5, -10.0), sp)
		var real_gain: float = real["dh"] - base["dh"]
		_lines.append("%s: glide dh %.2f m; canonical 45deg@1Hz (-10 wrist) gain %.2f m, net %.2f" % [sp, base["dh"], real_gain, real["net"]])
		metric("%s_real_gain" % sp, real_gain)
		# Hand shakes (both hands, vertical, in phase).
		for amp: float in [0.02, 0.03, 0.05, 0.08, 0.10, 0.12, 0.15]:
			for hz: float in [3.0, 4.0, 5.0, 6.0, 8.0]:
				var r: Dictionary = _fly(_vshake(amp, hz), sp)
				var d: float = r["dh"] - base["dh"]
				var acc_g := pow(TAU * hz, 2.0) * amp / 9.81
				_lines.append("  %s vshake +-%2d cm @ %.0f Hz (peak hand accel %4.1f g): dh %+7.2f m  (%.0f%% of real)  net %.2f  onsets %d" % [
					sp, int(round(amp * 100)), hz, acc_g, d, 100.0 * d / maxf(real_gain, 1e-6), r["net"], r["onsets"]])
				metric("%s_vshake_%d_%d" % [sp, int(round(amp * 100)), int(hz)], d)
				check(r["finite"], "%s shake finite" % sp)
				if amp <= 0.05:
					# Small fast shaking: no thrust at all.
					lt(d, 0.1, "%s: +-%d cm hand shake @ %.0f Hz must not climb vs the still glide (m)" % [sp, int(round(amp * 100)), hz])
				elif amp <= 0.10 and hz >= 4.0:
					# Medium waggles: at most a quarter of a real stroke's gain, never a net climb.
					lt(r["dh"], 0.0, "%s: +-%d cm hand shake @ %.0f Hz must not give a net climb (absolute m)" % [sp, int(round(amp * 100)), hz])
					lt(d, 0.25 * real_gain, "%s: +-%d cm hand shake @ %.0f Hz gains < 25%% of real strokes" % [sp, int(round(amp * 100)), hz])
		# Small-arc elevation waggles.
		for amp_deg: float in [6.0, 8.0, 10.0, 12.0, 15.0]:
			for hz: float in [2.0, 3.0, 4.0, 5.0]:
				for duty: float in [0.5, 0.3]:
					var r2: Dictionary = _fly(_waggle(amp_deg, hz, duty), sp)
					var d2: float = r2["dh"] - base["dh"]
					_lines.append("  %s waggle +-%2d deg @ %.0f Hz duty %.1f: dh %+7.2f m (%.0f%% of real) net %.2f onsets %d" % [
						sp, int(amp_deg), hz, duty, d2, 100.0 * d2 / maxf(real_gain, 1e-6), r2["net"], r2["onsets"]])
					metric("%s_waggle_%d_%d_%d" % [sp, int(amp_deg), int(hz), int(duty * 10)], d2)
					if amp_deg <= 8.0:
						lt(d2, 0.1, "%s: +-%d deg waggle @ %.0f Hz (duty %.1f) must not climb vs glide (m)" % [sp, int(amp_deg), hz, duty])
		# One hand shaking.
		for hz: float in [4.0, 8.0]:
			var r3: Dictionary = _fly(_vshake(0.05, hz, true), sp)
			var d3: float = r3["dh"] - base["dh"]
			_lines.append("  %s one-hand shake +-5 cm @ %.0f Hz: dh %+.2f" % [sp, hz, d3])
			lt(d3, 0.1, "%s one-hand +-5 cm shake @ %.0f Hz: no climb" % [sp, hz])
		# Tracking jitter.
		for sig: float in [0.005, 0.01, 0.02]:
			var r4: Dictionary = _fly(_jitter(sig, 99), sp)
			var d4: float = r4["dh"] - base["dh"]
			_lines.append("  %s jitter sigma %.1f cm: dh %+.2f net %.3f onsets %d" % [sp, sig * 100.0, d4, r4["net"], r4["onsets"]])
			metric("%s_jitter_%d_mm" % [sp, int(sig * 1000)], d4)
			lt(absf(d4), 0.3, "%s tracking jitter sigma %.1f cm: altitude within 0.3 m of the still glide" % [sp, sig * 100.0])
		# Wrist roll oscillation.
		for hz: float in [3.0, 6.0]:
			# A symmetric wrist roll IS the pitch command: it may trade speed for
			# height, so thrust is judged on energy height, not altitude.
			var r5: Dictionary = _fly(_wrist_roll(30.0, hz), sp)
			var d5: float = r5["dh"] - base["dh"]
			var de5: float = r5["e"] - base["e"]
			var ms := _min_sink(sp)
			_lines.append("  %s wrist roll +-30 deg @ %.0f Hz: dh %+.2f, energy vs still glide %+.2f m, energy rate %.3f m/s (best steady glide sink %.3f), onsets %d" % [
				sp, hz, d5, de5, r5["de_rate"], ms, r5["onsets"]])
			# Pumping the wrists may fly a better part of the polar, but never
			# beats the best steady glide: no energy from nothing.
			lt(r5["de_rate"], -0.95 * ms, "%s wrist-roll waggle @ %.0f Hz: energy loss >= 0.95 x the best steady sink (m/s)" % [sp, hz])
			eq(r5["onsets"], 0, "%s wrist-roll waggle: no flap onsets" % sp)


# --- F1 through the chain, all sizes, adversarial bodies ---------------------------

func _impulse_dir(sp: StringName, twist_deg: float, variant: String) -> Dictionary:
	var m := _model(sp)
	var body := HumanPoseModel.new(5)
	if variant == "tremor":
		body.tremor_mm = 1.5
		body.twist_noise_deg = 1.5
	var rig := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		for a in b.arms:
			a.twist = twist_deg * DEG
		match variant:
			"look":
				b.head_yaw = 60.0 * DEG * sin(TAU * 0.3 * t)
				b.head_pitch = -30.0 * DEG
				b.head_roll = 10.0 * DEG * sin(TAU * 0.5 * t)
			"turned":
				b.torso_yaw = 90.0 * DEG
				b.room_offset = Vector3(1.2, 0, -0.8)
			"fast":
				ScriptedPoseSource.flap(b, t, 35.0, 1.6)
			"slow_power":
				ScriptedPoseSource.flap(b, t, 50.0, 0.7, 0, 0.3)
		, false, body)
	rig.wi.size_x = m.params.x
	rig.run(2.0)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	var acc := Vector3.ZERO
	for i in 5 * 72:
		var w := rig.step()
		var i0 := m.flap_impulse
		m.step(w, env, DT)
		var d := m.flap_impulse - i0
		var fh := FlightMath.yaw_forward(m.chi)
		var rh := Vector3(cos(m.chi), 0.0, -sin(m.chi))
		var up_b := Vector3.UP * cos(m.phi) + rh * sin(m.phi)
		var r_b := rh * cos(m.phi) - Vector3.UP * sin(m.phi)
		acc += Vector3(d.dot(fh), d.dot(up_b), d.dot(r_b))
	return {"deg": rad_to_deg(atan2(acc.x, acc.y)), "ratio": acc.x / maxf(acc.y, 1e-9), "side_deg": rad_to_deg(atan2(acc.z, acc.y)),
		"up": acc.y}


func test_f1_direction_all_sizes_and_bodies() -> void:
	_lines.append("F1 flap impulse direction through the chain")
	for sp in SP:
		for variant: String in ["plain", "look", "turned", "tremor", "fast", "slow_power"]:
			var flat := _impulse_dir(sp, 0.0, variant)
			var fwd := _impulse_dir(sp, -20.0, variant)
			_lines.append("  %s %-10s flat: %+.1f deg (side %+.1f)  LE-down 20: fwd/up %.3f (%.1f deg)" % [sp, variant, flat["deg"], flat["side_deg"],
				fwd["ratio"], fwd["deg"]])
			lt(absf(flat["deg"]), 10.0, "%s %s: flat-wrist impulse within 10 deg of vertical" % [sp, variant])
			lt(absf(flat["side_deg"]), 10.0, "%s %s: flat-wrist impulse has no sideways lean" % [sp, variant])
			gt(fwd["ratio"], 0.25, "%s %s: wrists 20 deg LE-down -> forward >= 25%% of vertical" % [sp, variant])
			gt(flat["up"], 0.0, "%s %s: flat stroke pushes up" % [sp, variant])
			metric("%s_%s_flat_deg" % [sp, variant], flat["deg"])
			metric("%s_%s_fwd_ratio" % [sp, variant], fwd["ratio"])


func test_f1_climb_and_descend_every_size() -> void:
	_lines.append("F1 sustained flapping vs no flapping, 15 s from trim")
	for sp in SP:
		for tw: float in [0.0, -10.0]:
			var r: Dictionary = _fly(_waggle(45.0, 1.0, 0.5, tw), sp, 15.0)
			_lines.append("  %s flapping (wrist %+d): dh %+.2f m" % [sp, int(tw), r["dh"]])
			gt(r["dh"], 1.0, "%s: sustained canonical flapping (wrist %d deg) climbs over 15 s" % [sp, int(tw)])
			metric("%s_flap_%d_dh" % [sp, int(tw)], r["dh"])
		var g: Dictionary = _fly(_still(), sp, 15.0)
		_lines.append("  %s still: dh %+.2f m" % [sp, g["dh"]])
		lt(g["dh"], -1.0, "%s: no flapping descends" % sp)
		# Arms held still but wrists LE-up (slow): still descends in the long run.
		var g2: Dictionary = _fly(WR.new(func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			for a in b.arms:
				a.twist = 15.0 * DEG), sp, 30.0)
		lt(g2["dh"], 0.0, "%s: no flapping with wrists up still descends over 30 s" % sp)
		metric("%s_still_dh" % sp, g["dh"])
