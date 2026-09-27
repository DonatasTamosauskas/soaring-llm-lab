extends TestCase
## L2 flapping: credited-stroke detection and the flap direction through the
## real input chain (FLIGHT_SPEC WI-12...WI-15, WI-27, PB-16) plus F1 and F9
## end to end: arm poses -> WingInput -> FlightModel.
##   F1: flat-wing downstroke impulse within 10 deg of vertical; wrists
##       pitched forward ~20 deg -> forward >= 25% of vertical; sustained
##       flapping climbs; upstroke much weaker; no flapping descends.
##   F9: shaking / jitter never climbs; only real strokes produce thrust.

const WR := preload("res://tests/unit/flight/wing_rig.gd")
const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0


func _stroke_rig(amp_deg: float, hz: float, twist_deg := 0.0, duty := 0.5, side := 0, x := -1.0) -> WR:
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, amp_deg, hz, side, duty)
		for a in b.arms:
			a.twist = twist_deg * DEG)
	if x >= 0.0:
		r.wi.size_x = x
	return r


## Mean of flap^2 and of the net effort over [t0, t0 + secs], per wing mean.
func _effort(r: WR, t0: float, secs: float, up_gain: float) -> Dictionary:
	r.run(t0)
	var acc := {"f2": 0.0, "net": 0.0, "n": 0, "onsets": 0, "peak": 0.0, "events": []}
	r.on_tick = func(_i: int, w: WingState, rig: Variant) -> void:
		acc["f2"] += 0.5 * (w.flap_l * w.flap_l + w.flap_r * w.flap_r)
		acc["net"] += 0.5 * (w.flap_l + w.flap_r + up_gain * (w.up_l + w.up_r))
		acc["n"] += 1
		acc["onsets"] += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
		acc["peak"] = maxf(acc["peak"], maxf(w.flap_l, w.flap_r))
		for e in rig.wi.flapped_events():
			acc["events"].append(e)
	r.run(secs)
	r.on_tick = Callable()
	return {"f2": acc["f2"] / acc["n"], "net": acc["net"] / acc["n"], "onsets": acc["onsets"],
		"peak": acc["peak"], "events": acc["events"], "n": acc["n"]}


# --- WI-12: the flap normal follows the wrist (F1 direction) -----------------------
func test_wi12_flap_normal_follows_the_wrist() -> void:
	var cases := [[0.0, -3.0, 3.0], [-20.0, 14.0, 20.0], [-30.0, 32.0, 36.0], [40.0, -21.0, -17.0]]
	for c in cases:
		var r := _stroke_rig(45.0, 1.0, c[0])
		r.run(2.0)
		# The spec's reference angles are for the wing at shoulder level; the
		# stroke-weighted direction (what the physics integrates) is larger
		# because a raised arm tilts the normal inward (cos(elevation)).
		var acc := {"d": Vector3.ZERO, "lvl": Vector3.ZERO, "peak": 0.0, "n": 0}
		r.on_tick = func(_i: int, w: WingState, rig: Variant) -> void:
			acc["d"] += (w.flap_dir_l * w.flap_l + w.flap_dir_r * w.flap_r)
			acc["peak"] = maxf(acc["peak"], maxf(w.flap_l, w.flap_r))
			if absf(rig.wi.elevation[0]) < 3.0 * DEG and w.flap_l > 0.1:
				acc["lvl"] += w.flap_dir_l + w.flap_dir_r
				acc["n"] += 1
		r.run(3.0)
		var lv: Vector3 = acc["lvl"]
		var d: Vector3 = acc["d"]
		var fwd := rad_to_deg(atan2(-lv.z, lv.y))
		gt(acc["n"], 2, "wrist %d deg: sampled the level crossing" % c[0])
		between(fwd, c[1], c[2], "wrist %d deg: flap normal tilt toward the heading at shoulder level (deg)" % c[0])
		lt(absf(rad_to_deg(atan2(lv.x, lv.y))), 1.0, "wrist %d deg: symmetric strokes cancel sideways" % c[0])
		if c[0] == 0.0:
			between(acc["peak"], 0.9, 1.3, "canonical stroke peak flap effort")
		metric("tilt_%d" % c[0], fwd)
		metric("tilt_%d_stroke_weighted" % c[0], rad_to_deg(atan2(-d.z, d.y)))


# --- WI-13: the reference stroke through the chain equals the cached p_ref ---------
func test_wi13_reference_effort_through_the_chain() -> void:
	for sp in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		var p := FlightParams.derive(FlightParams.species_mass(sp))
		var r := _stroke_rig(45.0, 1.0, 0.0, 0.5, 0, p.x)
		var e := _effort(r, 4.0, 5.0, p.up_gain)
		near(e["net"] / p.p_ref, 1.0, 0.05, "%s: chain mean net effort / FlapDetector.reference_effort" % sp)
		metric("%s_ratio" % sp, e["net"] / p.p_ref)


# --- WI-14 / F9: shaking and tremor never flap -------------------------------------
func _shake_rig(kind: String, amp_m: float, hz: float) -> WR:
	var rng := RandomNumberGenerator.new()
	rng.seed = 14
	var body := HumanPoseModel.new(14)
	return WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for side in 2:
			if kind == "noise":
				b.hand_offset[side] = Vector3(rng.randfn(0, amp_m), rng.randfn(0, amp_m), rng.randfn(0, amp_m))
			else:
				var ph := 0.7 * side
				b.hand_offset[side] = Vector3(0.3 * sin(TAU * hz * t * 1.1 + ph), sin(TAU * hz * t + ph), 0.2 * cos(TAU * hz * t)) * amp_m, false, body)


## Amplitude is the hand's excursion (m, +-). The boundary is +-10 cm at 4 Hz
## and faster (round-1 verifier's grid: +-15 cm at 3-4 Hz is a quick short
## stroke and earns most of a real stroke for a sparrow, by design, WI-15).
const REJECTION := [["noise", 0.0007, 0.0], ["tremor", 0.01, 10.0], ["shake", 0.03, 8.0], ["shake", 0.03, 12.0],
	["frantic", 0.06, 5.0], ["frantic", 0.08, 4.0], ["frantic", 0.10, 4.0], ["frantic", 0.10, 6.0]]

func test_wi14_rejection_set() -> void:
	var canon := _effort(_stroke_rig(45.0, 1.0), 2.0, 10.0, 0.0)
	for c in REJECTION:
		var e := _effort(_shake_rig(c[0], c[1], c[2]), 1.0, 10.0, 0.0)
		var lim := 0.05 if c[1] >= 0.08 else 0.01
		lt(e["f2"] / canon["f2"], lim + 1e-9, "%s %.1f cm @ %d Hz: integral flap^2 vs canonical" % [c[0], c[1] * 100.0, c[2]])
		eq(e["onsets"], 0, "%s %.1f cm @ %d Hz: zero flap onsets" % [c[0], c[1] * 100.0, c[2]])
		metric("%s_%d_%d_ratio" % [c[0], int(c[1] * 1000), int(c[2])], e["f2"] / canon["f2"])


## 10 s trimmed glide driven by the WingInput output of a pose rig.
func _glide_with(rig: WR, sp: StringName) -> float:
	var m := FS.model(sp)
	rig.wi.size_x = m.params.x
	rig.run(1.0)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	for i in 720:
		var w := rig.step()
		m.step(w, env, DT)
	return m.position.y


func test_f9_shaking_yields_no_climb() -> void:
	for sp in ([&"sparrow", &"eagle"] if Paths.arg("full", "") != "" else [&"sparrow"]):
		var base := _glide_with(WR.new(WR.airplane()), sp)
		for c in REJECTION:
			var h := _glide_with(_shake_rig(c[0], c[1], c[2]), sp)
			lt(absf(h - base), 0.05, "%s %s %.1f cm @ %d Hz: altitude vs a still glide after 10 s (m)" % [sp, c[0], c[1] * 100.0, c[2]])
		# A real stroke does climb relative to the same baseline.
		var hs := _glide_with(_stroke_rig(45.0, 1.0, -10.0), sp)
		gt(hs - base, 2.0, "%s real strokes gain height vs gliding (m)" % sp)
		metric("%s_stroke_gain_m" % sp, hs - base)


## The arc bank (FLIGHT_SPEC §6.2): a downstroke earns force only for the
## upstroke arc that preceded it at real speed. A 60 deg raise slower than
## W_UP banks nothing; a quick 35 deg flick then banks ~30 deg (the
## velocity filter trims the ends); the long 105 deg downstroke that follows
## is credited with the banked arc, not its own 105 (round 2: removing the
## bank passed the whole flap_detector suite). Control: the same downstroke
## after a real upstroke earns its arc.
func test_f9_arc_bank_limits_the_downstroke() -> void:
	var dt := 1.0 / 72.0
	var res := {}
	for kind in ["flick", "full"]:
		var det := FlapDetector.new()
		det.size_x = FlightParams.derive(FlightParams.species_mass(&"sparrow")).x
		var l_arm := 0.6
		var segs: Array = []
		if kind == "flick":
			segs = [[-45.0, 15.0, 0.1], [15.0, 50.0, 3.0], [50.0, -55.0, 3.0]]
		else:
			segs = [[-55.0, 50.0, 3.0], [50.0, -55.0, 3.0]]
		var a := deg_to_rad(float(segs[0][0]))
		var used := 0.0
		var banked := 0.0
		for i in 30:
			det.step(Vector3(l_arm * cos(a), l_arm * sin(a), 0.0), Vector3.UP, l_arm, 1.0, true, dt)
		for k in segs.size():
			var sg: Array = segs[k]
			var a1 := deg_to_rad(float(sg[1]))
			var rate := float(sg[2])
			var down := a1 < a
			while absf(a1 - a) > 1e-6:
				a = move_toward(a, a1, rate * dt)
				det.step(Vector3(l_arm * cos(a), l_arm * sin(a), 0.0), Vector3.UP, l_arm, 1.0, true, dt)
				if not down:
					banked = det.bank
				elif det.flap > 0.0 and det.credit > 1e-6:
					used += det.flap * det.omega_full_x() * dt / det.credit
		# Let the filtered velocity finish the stroke.
		for i in 30:
			det.step(Vector3(l_arm * cos(a), l_arm * sin(a), 0.0), Vector3.UP, l_arm, 1.0, true, dt)
			if det.flap > 0.0 and det.credit > 1e-6:
				used += det.flap * det.omega_full_x() * dt / det.credit
		res[kind] = [rad_to_deg(used), rad_to_deg(banked)]
	var fl: Array = res["flick"]
	var fu: Array = res["full"]
	between(fl[1], 25.0, 36.0, "a slow 60 deg raise banks nothing, the 35 deg flick banks its arc (%.1f deg)" % fl[1])
	lt(fl[0], 1.05 * fl[1], "the 105 deg downstroke after the flick is credited <= the banked arc (deg)")
	gt(fl[0], 0.7 * fl[1], "and it does earn the flick's arc (deg)")
	gt(fu[0], 0.9 * fu[1], "control: after a real upstroke the downstroke earns the banked arc (deg)")
	gt(fu[1], 2.5 * fl[1], "control: the real upstroke banked far more (deg)")
	metric("flick_used_banked_deg", fl)
	metric("full_used_banked_deg", fu)


## Wrist-twist jitter (round 2): twisting both wrists +-35 deg at 4-10 Hz
## with the arms still is not a pitch command. Round 1 rectified it into a
## trim through the asymmetric pitch shaping and the model's asymmetric
## pitch map: mean pitch -0.10, mean alpha +1.7 deg, 6 m of energy height
## above a still glide in 12 s at every size. The jitter must average out:
## |mean pitch command| < 0.01 and energy height within 1 m of the still
## glide after 10 s. A pilot's own pitch pumping (+-25 deg at 1.5 Hz) still
## reaches the model in full, and a pitch step keeps its latency.
func test_f9_wrist_twist_jitter_is_not_a_trim() -> void:
	for sp in [&"sparrow", &"eagle"]:
		var base := _energy_with(WR.new(WR.airplane()), sp)
		for hz in [4.0, 6.0, 10.0]:
			var rig := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				for a in b.arms:
					a.twist = 35.0 * DEG * sin(TAU * hz * t))
			var acc := {"p": 0.0, "n": 0}
			rig.on_tick = func(tick: int, w: WingState, _r: Variant) -> void:
				if tick > 144:
					acc["p"] += w.pitch
					acc["n"] += 1
			var e := _energy_with(rig, sp)
			lt(absf(e - base), 1.0, "%s wrist twist +-35 deg @ %d Hz: energy height vs a still glide after 10 s (m)" % [sp, int(hz)])
			lt(absf(acc["p"] / maxf(acc["n"], 1)), 0.01, "%s wrist twist +-35 deg @ %d Hz: mean pitch command" % [sp, int(hz)])
			metric("%s_twist_%dhz_de" % [sp, int(hz)], e - base)
	# A pilot's pitch pumping passes in full: +-25 deg at 1.5 Hz.
	var pump := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		for a in b.arms:
			a.twist = 25.0 * DEG * sin(TAU * 1.5 * t))
	var pk := {"max": 0.0, "min": 0.0}
	pump.on_tick = func(tick: int, w: WingState, _r: Variant) -> void:
		if tick > 144:
			pk["max"] = maxf(pk["max"], w.pitch)
			pk["min"] = minf(pk["min"], w.pitch)
	pump.run(4.0)
	eq(pump.wi.pitch_jitter, 0.0, "pitch pumping at 1.5 Hz is not jitter")
	var want_up := FlightMath.shape(23.0 * DEG, 5.0 * DEG, 40.0 * DEG, 30.0 * DEG, 1.4)
	gt(pk["max"], want_up, "pitch pumping reaches nose-up commands of a 23 deg twist (%.2f)" % pk["max"])
	lt(pk["min"], -FlightMath.shape(23.0 * DEG, 5.0 * DEG, 30.0 * DEG, 30.0 * DEG, 1.4), "and nose-down (%.2f)" % pk["min"])


func _energy_with(rig: WR, sp: StringName) -> float:
	var m := FS.model(sp)
	rig.wi.size_x = m.params.x
	rig.run(1.0)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	for i in 720:
		var w := rig.step()
		m.step(w, env, DT)
	return m.position.y + m.velocity.length_squared() / (2.0 * 9.81)


# --- WI-15: real strokes are accepted ------------------------------------------------
func test_wi15_accepted_strokes() -> void:
	var p_sp := FlightParams.derive(FlightParams.species_mass(&"sparrow"))
	var canon := _effort(_stroke_rig(45.0, 1.0, 0.0, 0.5, 0, p_sp.x), 2.0, 9.0, p_sp.up_gain)
	# Slow 1.2 s recovery, fast 0.3 s power stroke, 90 deg arc.
	var slow := _effort(_stroke_rig(45.0, 1.0 / 1.5, 0.0, 0.2, 0, p_sp.x), 3.0, 9.0, p_sp.up_gain)
	gt(slow["net"] / canon["net"], 0.5, "slow recovery + fast power stroke: effort vs canonical")
	metric("slow_recovery_ratio", slow["net"] / canon["net"])
	# Quick short strokes: rewarded for small birds, not for big ones.
	for sp in [&"sparrow", &"eagle"]:
		var p := FlightParams.derive(FlightParams.species_mass(sp))
		var q := _effort(_stroke_rig(15.0, 2.0, 0.0, 0.5, 0, p.x), 2.0, 8.0, p.up_gain)
		var ratio: float = q["net"] / p.p_ref
		if sp == &"sparrow":
			gt(ratio, 0.55, "sparrow: quick +-15 deg @ 2 Hz earns >= 0.55 of the reference effort")
		else:
			lt(ratio, 0.45, "eagle: quick +-15 deg @ 2 Hz earns <= 0.45 of the reference effort")
		metric("%s_quick_ratio" % sp, ratio)


# --- WI-27: events -------------------------------------------------------------------
func test_wi27_one_onset_per_stroke() -> void:
	var r := _stroke_rig(45.0, 1.0)
	var e := _effort(r, 2.0, 10.0, 0.0)
	eq(e["onsets"], 20, "10 s of 1 Hz strokes: exactly one onset per wing per stroke")
	var paired := 0
	var credits_ok := true
	for ev in e["events"]:
		if ev[0] == 0:
			paired += 1
		if float(ev[1]) < 0.25:
			credits_ok = false
	eq(paired, 10, "one player_flapped(side 0) per symmetric stroke")
	eq(e["events"].size(), 10, "no extra single-wing events")
	check(credits_ok, "event strength = credit >= 0.25 (onboarding counts them)")
	# A one-wing stroke emits side -1 / +1.
	var r2 := _stroke_rig(45.0, 1.0, 0.0, 0.5, -1)
	var e2 := _effort(r2, 2.0, 3.0, 0.0)
	var sides := {}
	for ev in e2["events"]:
		sides[ev[0]] = true
	check(sides.has(-1) and not sides.has(0) and not sides.has(1), "left-only strokes emit side -1 (got %s)" % str(sides.keys()))


# --- PB-16: seated strokes -------------------------------------------------------------
func test_pb16_seated_strokes() -> void:
	var p := FlightParams.derive(FlightParams.species_mass(&"sparrow"))
	var cal := WingCalibration.new()
	cal.seated = true
	var body := HumanPoseModel.new(16)
	body.set_body(1.5, 1.20)
	var amp := asin(0.25 / body.arm_length())
	var r := WR.new(func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, rad_to_deg(amp), 1.3), false, body, cal)
	r.wi.size_x = p.x
	var e := _effort(r, 3.0, 8.0, p.up_gain)
	gt(e["net"] / p.p_ref, 0.85, "seated +-0.25 m strokes at 1.3 Hz: effort vs the standing reference")
	metric("seated_ratio", e["net"] / p.p_ref)


# --- F1 end to end: poses -> WingInput -> FlightModel --------------------------------
func test_f1_flap_lift_direction_end_to_end() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		var res := {}
		for tw in [0.0, -20.0]:
			var m := FS.model(sp)
			var rig := _stroke_rig(45.0, 1.0, tw, 0.5, 0, m.params.x)
			rig.run(2.0)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var env := FlightEnv.new()
			var acc := Vector3.ZERO
			var ws_log: Array[WingState] = []
			for i in 5 * 72:
				var w := rig.step()
				var wc := WingState.new()
				wc.copy_from(w)
				ws_log.append(wc)
				var i0 := m.flap_impulse
				m.step(w, env, DT)
				var d := m.flap_impulse - i0
				var fr := FS.frame(m)
				acc += Vector3(d.dot(fr[0]), d.dot(fr[1]), d.dot(fr[2]))
			# The upstroke's share from the force the model applies to the same
			# WingState stream (FS.upstroke_split; round 2 split the impulse in
			# the ratio of the commands, a tautology). Arms fall on phase < 0.5
			# of the 1 Hz reference stroke that started 2 s before the log.
			var split := FS.upstroke_split(sp, func(i: int) -> WingState: return ws_log[i], ws_log.size(),
				func(i: int) -> bool: return fposmod(2.0 + i * DT, 1.0) < 0.5)
			res[tw] = [rad_to_deg(atan2(acc.x, acc.y)), acc.x / acc.y, split["up_over_down"], split["rise_over_fall"], split["up_gain"]]
		lt(absf(res[0.0][0]), 10.0, "%s flat wrists: flap impulse within 10 deg of vertical" % sp)
		gt(res[-20.0][1], 0.25, "%s wrists pitched 20 deg forward: forward >= 25%% of vertical" % sp)
		if float(res[0.0][4]) > 0.0:
			between(float(res[0.0][2]), 0.0, 0.35, "%s upstroke force much weaker than the downstroke (applied impulse, poses through WingInput)" % sp)
		else:
			between(float(res[0.0][2]), -0.15, 0.0, "%s big bird: the upstroke opposes slightly (applied impulse, poses through WingInput)" % sp)
		lt(float(res[0.0][3]), 1.0, "%s: more flap impulse while the arms fall than while they rise" % sp)
		metric("%s_flat_deg" % sp, res[0.0][0])
		metric("%s_fwd_ratio" % sp, res[-20.0][1])
		metric("%s_up_over_down" % sp, res[0.0][2])
		metric("%s_rise_over_fall" % sp, res[0.0][3])


func test_f1_sustained_flapping_climbs_and_gliding_descends() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		# Flapping hard with a slight forward wrist climbs; with the arms held
		# still, the same bird glides down.
		for flap in [true, false]:
			var m := FS.model(sp)
			var rig := _stroke_rig(45.0 if flap else 0.0, 1.0, -10.0 if flap else 0.0, 0.5, 0, m.params.x)
			rig.run(2.0)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var env := FlightEnv.new()
			for i in 15 * 72:
				m.step(rig.step(), env, DT)
			var dh := m.position.y - 500.0
			if flap:
				gt(dh, 5.0, "%s sustained reference flapping climbs over 15 s (m)" % sp)
			else:
				lt(dh, -5.0, "%s no flapping: descends over 15 s (m)" % sp)
			metric("%s_%s_dh" % [sp, "flap" if flap else "glide"], dh)
