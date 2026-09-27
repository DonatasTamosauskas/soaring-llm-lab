extends TestCase
## L3 perching and ground (FLIGHT_SPEC PB-10 P1...P8, PB-11, PB-15) and F10:
## a slow approach to a perch lands and clings; a flap launches.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 20, -10)

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func _fx(sp: StringName, max_span := 10.0, extra: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.add_perch(PERCH, Vector3.FORWARD, max_span, 0.015, 1.0)
		if extra.is_valid():
			extra.call(w))
	return fx


## Level ("aligned") approach from `back` spans behind the perch body point,
## `up` spans above it and `side` spans to the right, flying -Z at speed v.
func _approach(back: float, up: float, side: float, v: float) -> void:
	var p := fx.player
	var pr := p.model.params
	var target := PERCH + Vector3.UP * pr.r_body
	var start := target + Vector3(side * pr.span, up * pr.span, back * pr.span)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, 0, -v), 0.0)


func _run_until_perched(seconds: float) -> float:
	var st := {"t": -1.0}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		if st["t"] < 0.0 and f.player.mode == PlayerBird.Mode.PERCHED:
			st["t"] = tick * DT
	var t0 := fx.ticks
	fx.on_tick = func(tick: int, f: Variant) -> void:
		if st["t"] < 0.0 and f.player.mode == PlayerBird.Mode.PERCHED:
			st["t"] = (tick - t0) * DT
	fx.run(seconds)
	fx.on_tick = Callable()
	return st["t"]


func _v_cap(p: PlayerBird) -> float:
	return 0.8 * p.model.params.v_min


# --- P1 / P3 / P2: slow approaches cling, fast ones do not ------------------------
func test_p1_p2_p3_capture_speeds() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		await _fx(sp)
		var p := fx.player
		var vcap := _v_cap(p)
		_approach(2.0, 0.1, 0.0, 0.9 * vcap)
		fx.reset_events()
		var t := _run_until_perched(1.5)
		check(t >= 0.0 and t <= 1.0, "%s P1: aligned approach at 0.9 V_cap perches within 1 s (%.2f)" % [sp, t])
		lt(p.model.position.distance_to(PERCH + Vector3.UP * p.model.params.r_body), 0.1 * p.model.params.span, "%s P1: body on the grip point (within 0.1 span)" % sp)
		eq(fx.events["perched"], 1, "%s P1: player_perched once" % sp)
		check(fx.world.get_perches()[0].occupant == p, "%s P1: perch occupant is the player" % sp)
		check(bool(p.telemetry()["perched"]), "%s P1: telemetry perched" % sp)
		fx.assert_comfort(self, "%s perching" % sp)
		fx.teardown()
		fx = null
		# P2: 1.5 V_cap without grip does not cling.
		await _fx(sp)
		p = fx.player
		_approach(2.0, 0.1, 0.0, 1.5 * _v_cap(p))
		# The fly-by itself (a later, slower second approach may well perch).
		t = _run_until_perched(0.5)
		lt(t, 0.0, "%s P2: 1.5 V_cap without grip: the approach does not perch" % sp)
		fx.teardown()
		fx = null
		# P3: 1.2 V_cap with the grip held clings.
		await _fx(sp)
		p = fx.player
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.grip = Vector2(1, 1)
		_approach(2.0, 0.1, 0.0, 1.2 * _v_cap(p))
		t = _run_until_perched(1.5)
		check(t >= 0.0, "%s P3: 1.2 V_cap with grip: perched" % sp)
		fx.teardown()
		fx = null


# --- P4 / P8: too small or occupied perches never capture ---------------------------
func test_p4_p8_small_or_occupied() -> void:
	var span := SizeRules.wingspan_for_mass(FlightParams.species_mass(&"pigeon"))
	await _fx(&"pigeon", 0.8 * span)
	var p := fx.player
	_approach(2.0, 0.1, 0.0, 0.9 * _v_cap(p))
	lt(_run_until_perched(1.5), 0.0, "P4: a perch smaller than the bird never captures")
	fx.teardown()
	fx = null
	await _fx(&"sparrow")
	p = fx.player
	var other := Bird.new()
	add_child(other)
	fx.world.get_perches()[0].occupant = other
	_approach(2.0, 0.1, 0.0, 0.9 * _v_cap(p))
	lt(_run_until_perched(1.5), 0.0, "P8: an occupied perch never captures")
	other.queue_free()


# --- P5: a completed flap launches ---------------------------------------------
## Fix round 4: off a perch only a COMPLETED flap launches (FLIGHT_SPEC §10.2):
## a credited downstroke that ends with the wing still out, or a deep stroke
## that ends low and rises back out within 0.8 s. The bird leaves at the
## bottom of the stroke (or at the deep stroke's recovery), not at the onset:
## the onset alone cannot tell a flap from arms dropped to the sides.
func test_p5_a_completed_flap_launches() -> void:
	for sp in [&"sparrow", &"eagle"]:
		for kind in ["reference", "deep"]:
			await _fx(sp)
			var p := fx.player
			p.perch_on(fx.world.get_perches()[0])
			fx.run(0.5)
			eq(p.mode, PlayerBird.Mode.PERCHED, "%s: perched" % sp)
			fx.reset_events()
			# One stroke, starting low so the upstroke earns the credit. The
			# deep stroke sweeps +50 ... -90 deg (ends below the fold line).
			var deep: bool = kind == "deep"
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				if t < 1.5:
					ScriptedPoseSource.flap(b, t + 0.5, 70.0 if deep else 45.0, 1.0, 0, 0.5, -20.0 if deep else 0.0)
			var st := {"t_onset": -1.0, "t_end": -1.0, "t_fly": -1.0, "v05": -1.0, "reperch": false}
			var t0 := fx.ticks
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var tt := (tick - t0) * DT
				var pl: PlayerBird = f.player
				var d0: FlapDetector = pl.wing_input.detectors[0]
				if st["t_onset"] < 0.0 and d0.onset:
					st["t_onset"] = tt
				if st["t_onset"] >= 0.0 and st["t_end"] < 0.0 and d0.omega < FlapDetector.W_DN:
					st["t_end"] = tt
				if st["t_fly"] < 0.0 and pl.mode == PlayerBird.Mode.FLYING:
					st["t_fly"] = tt
				if st["t_fly"] >= 0.0 and st["v05"] < 0.0 and tt >= st["t_fly"] + 0.5:
					st["v05"] = pl.model.airspeed()
				if st["t_fly"] >= 0.0 and tt < st["t_fly"] + 0.4 and pl.mode == PlayerBird.Mode.PERCHED:
					st["reperch"] = true
			fx.run(2.5)
			var tag := "%s %s stroke" % [sp, kind]
			check(st["t_fly"] >= 0.0, "%s P5: launches" % tag)
			if not deep:
				between(st["t_fly"] - st["t_end"], -1e-6, 0.1 + 1e-6, "%s P5: at the bottom of the stroke (s after the downstroke ends)" % tag)
			else:
				between(st["t_fly"] - st["t_end"], 0.0, 0.8 + 1e-6, "%s P5: at the deep stroke's recovery (s after the downstroke ends)" % tag)
			lt(st["t_fly"] - st["t_onset"], 1.0, "%s P5: within 1 s of the onset" % tag)
			gt(st["v05"], 0.5 * p.model.params.v_min, "%s P5: V >= 0.5 V_min 0.5 s after launch" % tag)
			check(not st["reperch"], "%s P5: no re-perch in the first 0.4 s" % tag)
			eq(fx.events["took_off"], 1, "%s P5: player_took_off once" % tag)
			check(fx.world.get_perches()[0].occupant == null, "%s P5: perch released" % tag)
			metric(tag.replace(" ", "_"), {"onset_to_fly": st["t_fly"] - st["t_onset"], "end_to_fly": st["t_fly"] - st["t_end"]})
			fx.teardown()
			fx = null


# --- P6: resting on a perch is safe (fix round 4) ----------------------------------
## Round-4 experience verifier: after any landing, letting the arms hang at
## the sides read as the tuck and dropped the bird off the branch (pigeon
## and eagle fell 20 m to the ground; 10 of 20 relaxed postures ejected it).
## Arms at the sides, folded or crossed are the REST pose on a perch: the
## tuck-drop is gone, and only a completed flap launches (P5). Pinned at
## three sizes: arms lowered to the sides and held for 60 s; relaxed
## postures from 60 to 90 deg below the shoulder with the elbows 0-90 deg;
## natural fidgeting for 20 s (small swings, looking round, hands to the
## chest, raising the arms to look at the wings and letting them drop back
## briskly); the bird stays PERCHED throughout, never reports a tuck, and a
## real flap from the rest pose then launches.
func _rest_pose(b: HumanPoseModel, k: float, dih_deg: float, elbow_deg: float) -> void:
	for a in b.arms:
		a.dihedral = dih_deg * DEG * k
		a.elbow = elbow_deg * DEG * k


func test_p6_resting_on_a_perch_never_launches() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		await _fx(sp)
		var p := fx.player
		p.perch_on(fx.world.get_perches()[0])
		fx.run(0.5)
		fx.reset_events()
		var st := {"left": -1.0, "tucked": false, "credited": 0}
		var t0 := fx.ticks
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			if st["left"] < 0.0 and pl.mode != PlayerBird.Mode.PERCHED:
				st["left"] = (tick - t0) * DT
			if bool(pl.telemetry()["tucked"]):
				st["tucked"] = true
			for d: FlapDetector in pl.wing_input.detectors:
				if d.onset and d.onset_strength >= 0.35:
					st["credited"] += 1
		# 1) Arms lowered to the sides over 0.8 s, held for 60 s. (The driver
		# gets the pose source's own time: each step keeps its start.) The
		# held pose is still, so no size's detectors see any motion in it:
		# by default the sparrow (the lowest stroke thresholds) holds it the
		# full 60 s and the others 10 s; --full holds all three for 60 s
		# (fix round 6, the suite's time budget).
		var hold := 60.0 if sp == &"sparrow" or Paths.arg("full", "") != "" else 10.0
		var s1 := fx.src.tick * DT
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var k := clampf((t - s1) / 0.8, 0.0, 1.0)
			_rest_pose(b, k * k * (3.0 - 2.0 * k), -85.0, 20.0)
		fx.run(0.8 + hold)
		eq(st["left"], -1.0, "%s: %.0f s with the arms relaxed at the sides: still perched (left at %.2f s)" % [sp, hold, st["left"]])
		# 2) Natural fidgeting for 20 s (see _fidget).
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			_fidget(b, t)
		fx.run(20.0)
		eq(st["left"], -1.0, "%s: 20 s of fidgeting on the perch: still perched (left at %.2f s)" % [sp, st["left"]])
		eq(fx.events["took_off"], 0, "%s: no take-off event while resting" % sp)
		# The brisk drop after raising the arms IS a credited downstroke (an
		# onset-based launch would have fired on it): it ends folded.
		gt(st["credited"], 0, "%s: the fidgeting included credited downstrokes (%d)" % [sp, st["credited"]])
		metric("%s_fidget_credited_onsets" % sp, st["credited"])
		check(not st["tucked"], "%s: perched telemetry never reports a tuck (a dive)" % sp)
		# 3) A real flap from the rest pose: raise the wings, stroke down.
		var launched := {"t": -1.0}
		var t1 := fx.ticks
		fx.on_tick = func(tick: int, f: Variant) -> void:
			if launched["t"] < 0.0 and f.player.mode == PlayerBird.Mode.FLYING:
				launched["t"] = (tick - t1) * DT
		var s3 := fx.src.tick * DT
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var tt := t - s3
			if tt < 0.5:
				_rest_pose(b, 1.0 - tt / 0.5, -85.0, 20.0)
			else:
				# Level moving down at 0.5 s (continuous with the raised arms).
				ScriptedPoseSource.flap(b, tt - 0.5 + 0.25, 45.0, 1.0)
		fx.run(2.5)
		gt(launched["t"], 0.0, "%s: a flap from the rest pose launches (%.2f s)" % [sp, launched["t"]])
		# Raise 0.5 s, then the first downstroke (0.25 s to its bottom): the
		# first stroke launches, at its bottom.
		lt(launched["t"], 0.9, "%s: ... on the first stroke, at its bottom (s from starting to raise the wings)" % sp)
		metric("%s_flap_launch_s" % sp, launched["t"])
		fx.teardown()
		fx = null


## 20 s of what a player does on a branch between flights (all from and to
## the rest pose): hanging arms swinging a little, bent elbows, looking
## round, hands to the chest and back, raising the arms to look at the wings
## (1.2 s up, 1 s held) and letting them drop back briskly (0.5 s), a
## half-raise and drop, wrist twists, a shrug. Smoothed like human joints.
func _fidget(b: HumanPoseModel, t: float) -> void:
	b.set_airplane()
	var ph := fposmod(t, 20.0)
	var dih := -85.0
	var elbow := 20.0
	if ph < 3.0:
		dih = -85.0 + 10.0 * sin(TAU * 0.7 * ph)
		elbow = 20.0 + 25.0 * (0.5 + 0.5 * sin(TAU * 0.4 * ph))
		b.head_yaw = 70.0 * DEG * sin(TAU * 0.25 * ph)
	elif ph < 5.0:
		elbow = lerpf(20.0, 140.0, FlightMath.sstep(3.0, 3.6, ph)) - lerpf(0.0, 120.0, FlightMath.sstep(4.4, 5.0, ph))
		dih = -80.0
	elif ph < 8.7:
		# Raise to airplane arms over 1.2 s, hold 1 s, let them drop in 0.5 s.
		var up := FlightMath.sstep(5.0, 6.2, ph)
		var down := FlightMath.sstep(7.2, 7.7, ph)
		dih = -85.0 + 85.0 * up - 85.0 * down
		elbow = 20.0 * (1.0 - up) + 20.0 * down
	elif ph < 11.0:
		# Half-raise (to 40 deg below the shoulder) and drop.
		var up := FlightMath.sstep(8.7, 9.4, ph)
		var down := FlightMath.sstep(9.9, 10.3, ph)
		dih = -85.0 + 45.0 * up - 45.0 * down
	elif ph < 14.0:
		dih = -85.0 + 15.0 * sin(TAU * 1.0 * ph)
		for a in b.arms:
			a.twist = 30.0 * DEG * sin(TAU * 1.3 * ph)
		b.head_pitch = -40.0 * DEG * FlightMath.sstep(11.0, 12.0, ph)
	elif ph < 16.0:
		b.crouch = 0.05 * sin(TAU * 1.5 * ph)
		dih = -88.0
	else:
		dih = -85.0 + 6.0 * sin(TAU * 2.0 * ph)
		elbow = 20.0 + 10.0 * sin(TAU * 0.9 * ph)
		b.head_yaw = -60.0 * DEG * FlightMath.sstep(16.0, 17.0, ph)
	for i in 2:
		var a := b.arms[i]
		# The two arms never quite together.
		a.dihedral = (dih + (4.0 if i == 0 else -3.0)) * DEG
		a.elbow = (elbow + (8.0 if i == 0 else 0.0)) * DEG
	b.humanize(DT, 0.08)


## The verifier's grid (round 4) of relaxed arms-down postures on a perch:
## upper arm 60-90 deg below the shoulder, elbows 0-90 deg. --full flies all
## 20 at three sizes; the suite the corners and the middle at the pigeon.
func test_p6b_relaxed_postures_grid() -> void:
	var full := Paths.arg("full", "") != ""
	var dihs := [-60.0, -70.0, -80.0, -90.0] if full else [-60.0, -80.0, -90.0]
	var elbows := [0.0, 15.0, 30.0, 45.0, 90.0] if full else [0.0, 90.0]
	var sizes := [&"sparrow", &"pigeon", &"eagle"] if full else [&"pigeon"]
	for sp: StringName in sizes:
		var ejected := 0
		var total := 0
		for dih: float in dihs:
			for elb: float in elbows:
				await _fx(sp)
				var p := fx.player
				p.perch_on(fx.world.get_perches()[0])
				fx.run(0.5)
				var s0 := fx.src.tick * DT
				fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					var k := clampf((t - s0) / 1.0, 0.0, 1.0)
					_rest_pose(b, k * k * (3.0 - 2.0 * k), dih, elb)
				fx.run(4.0)
				total += 1
				if p.mode != PlayerBird.Mode.PERCHED:
					ejected += 1
				fx.teardown()
				fx = null
		eq(ejected, 0, "%s: none of %d relaxed arms-down postures drops the bird off its perch" % [sp, total])
		metric("%s_postures" % sp, total)


# --- P7: the assist makes imperfect approaches land -------------------------------
## Slow final approaches (1.0-1.3 V_min, what the bot and a player fly; the
## spec's 0.9-1.3 V_cap is below flying speed for the whole approach) from
## 8 spans, with the perch up to a span to the side and half a span up or
## down, flaring (wrists up, pitch 0.8) all the way in.
func test_p7_assist_rate() -> void:
	var rates := {}
	for assist in [true, false]:
		var ok := 0
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in 20:
			var sp: StringName = [&"sparrow", &"pigeon"][i % 2]
			await _fx(sp)
			var p := fx.player
			p.perch_assist = assist
			var pr := p.model.params
			var off_x := rng.randf_range(-1.0, 1.0)
			var off_y := rng.randf_range(-0.5, 0.5)
			var v := rng.randf_range(1.0, 1.3) * pr.v_min
			fx.driver = fx.synth(0.8, 0.0)
			var target := PERCH + Vector3.UP * pr.r_body
			var start := target + Vector3(off_x * pr.span, (0.3 + off_y) * pr.span, 8.0 * pr.span)
			p.start_flying(start, 0.0, 0.0)
			p.model.reset(start, Vector3(0, 0, -v), 0.0)
			var tp := _run_until_perched(3.0)
			if tp >= 0.0:
				ok += 1
			elif assist:
				print("[flight] P7 miss: %s off_x=%.2f off_y=%.2f v/vmin=%.2f end=%s mode=%s" % [sp, off_x, off_y, v / pr.v_min,
					(p.model.position - target).snapped(Vector3.ONE * 0.01), p.mode_name()])
			fx.teardown()
			fx = null
		rates[assist] = ok / 20.0
	gt(rates[true], 0.9 - 1e-6, "P7: with the perch assist >= 90% of imperfect approaches perch")
	lt(rates[false], 0.6 + 1e-6, "P7: without it <= 60% (the assist is what makes it work)")
	metric("assist_on", rates[true])
	metric("assist_off", rates[false])


# --- PB-11: ground landing and take-off ----------------------------------------
func test_pb11_ground_landing_and_takeoff() -> void:
	for sp in [&"sparrow", &"pigeon"]:
		await _fx(sp)
		var p := fx.player
		var vmin := p.model.params.v_min
		var start := Vector3(0, p.model.params.r_body + 0.25, 0)
		p.start_flying(start, 0.0, 0.0)
		var v0 := Vector3(0, -0.2 * vmin, -0.6 * vmin)
		p.model.reset(start, v0, 0.0)
		fx.run(1.5)
		eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: a slow shallow touchdown lands (GROUNDED)" % sp)
		fx.reset_events()
		# Strokes (upstroke first): sparrow needs 1, pigeon and up 2 within 1.2 s.
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if t < 4.0:
				ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.4)
		var st := {"onsets": 0, "t_fly": -1.0, "onsets_at_fly": 0}
		var t0 := fx.ticks
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var w: WingState = f.player.wing_state()
			if w.onset_l:
				st["onsets"] += 1
			if st["t_fly"] < 0.0 and f.player.mode == PlayerBird.Mode.FLYING:
				st["t_fly"] = (tick - t0) * DT
				st["onsets_at_fly"] = st["onsets"]
		fx.run(4.0)
		check(st["t_fly"] >= 0.0, "%s: takes off from the ground" % sp)
		eq(st["onsets_at_fly"], 1 if sp == &"sparrow" else 2, "%s: strokes needed to take off" % sp)
		fx.teardown()
		fx = null


# --- PB-15: ground cushion -------------------------------------------------------
func _skim(cushion: bool, glide_deg: float) -> Dictionary:
	await _fx(&"pigeon")
	var p := fx.player
	var pr := p.model.params
	if not cushion:
		var tu := p.tuning.duplicate() as FlightTuning
		p.tuning = tu
		p.model.assists[&"ground_cushion"] = false
	var h0 := 2.0 * pr.span
	var start := Vector3(0, h0, 0)
	var g := deg_to_rad(glide_deg)
	p.start_flying(start, 0.0, 0.0)
	if glide_deg >= 10.0:
		p.model.reset(start, Vector3(0, -sin(g), -cos(g)) * 2.0 * pr.v_c, 0.0)
	else:
		# The bird's own trimmed glide (the flattest unpowered path it has).
		g = -p.model.gam
	var st := {"z_contact": INF, "stun": false}
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		if st["z_contact"] == INF and (f.player.contacts["slide"] + f.player.contacts["silent"] + f.player.contacts["land"] + f.player.contacts["stun"]) > 0:
			st["z_contact"] = -f.player.model.position.z
		if f.player.mode == PlayerBird.Mode.STUNNED:
			st["stun"] = true
	fx.run(6.0)
	var out := {"contact_dist": st["z_contact"], "intercept": (h0 - pr.r_body) / tan(g), "span": pr.span, "stun": st["stun"]}
	fx.teardown()
	fx = null
	return out


func test_pb15_ground_cushion() -> void:
	var on: Dictionary = await _skim(true, 0.0)
	var off: Dictionary = await _skim(false, 0.0)
	gt((on["contact_dist"] - on["intercept"]) / on["span"], 40.0, "cushion on: a trimmed glide skims >= 40 spans past the intercept")
	lt(absf(off["contact_dist"] - off["intercept"]) / off["span"], 5.0, "cushion off: contact within 5 spans of the geometric intercept")
	var dive: Dictionary = await _skim(true, 40.0)
	check(dive["contact_dist"] < INF and dive["stun"], "a 40 deg dive still hits the ground and stuns")
	metric("skim_spans_on", (on["contact_dist"] - on["intercept"]) / on["span"])
	metric("skim_spans_off", (off["contact_dist"] - off["intercept"]) / off["span"])


# --- P9: the capture is a smooth deceleration, not a stop -------------------------
## Round 1 stopped the body in one tick at capture (the whole approach speed:
## 30 m/s perceived for a sparrow) and then slid it linearly to the grip.
## Now the body leaves the capture tick with its approach velocity and
## decelerates to the grip point, never passing it; perched telemetry
## reports a still bird (no flare aerodynamics left over).
func test_p9_capture_is_smooth_and_telemetry_rests() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		for case in [[2.0, 0.1, 0.0, 0.9], [3.0, 0.3, 0.3, 0.6], [2.0, -0.1, -0.2, 0.95]]:
			await _fx(sp)
			var p := fx.player
			var v := float(case[3]) * _v_cap(p)
			_approach(case[0], case[1], case[2], v)
			var tgt := PERCH + Vector3.UP * p.model.params.r_body
			var st := {"pos": [], "mode": []}
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				st["pos"].append(f.player.model.position)
				st["mode"].append(f.player.mode)
			fx.run(2.0)
			var pos: Array = st["pos"]
			var modes: Array = st["mode"]
			var i_cap := modes.find(PlayerBird.Mode.PERCHED)
			check(i_cap > 1, "%s %s: perched" % [sp, str(case)])
			if i_cap <= 1:
				fx.teardown()
				fx = null
				continue
			var worst_dv := 0.0
			var grows := 0
			var prev_d := INF
			for i in range(i_cap - 1, mini(i_cap + 50, pos.size() - 1)):
				var v_a: Vector3 = (pos[i] - pos[i - 1]) / DT
				var v_b: Vector3 = (pos[i + 1] - pos[i]) / DT
				worst_dv = maxf(worst_dv, (v_b - v_a).length())
				var d: float = (pos[i] as Vector3).distance_to(tgt)
				if i >= i_cap and d > prev_d + 1e-6:
					grows += 1
				prev_d = d
			lt(worst_dv / v, 0.45, "%s %s: per-tick velocity change through the capture <= 0.45 x the approach speed (round 1: 1.0)" % [sp, str(case)])
			eq(grows, 0, "%s %s: the body never moves away from the grip point after capture" % [sp, str(case)])
			lt((pos[pos.size() - 1] as Vector3).distance_to(tgt), 1e-4, "%s %s: rests on the grip point" % [sp, str(case)])
			metric("%s_%.2f_capture_dv_over_v" % [sp, case[3]], worst_dv / v)
			var t := p.telemetry()
			eq(float(t["aoa"]), 0.0, "%s perched telemetry: aoa 0" % sp)
			eq(float(t["g_load"]), 1.0, "%s perched telemetry: g_load 1" % sp)
			eq(float(t["lift"]), 0.0, "%s perched telemetry: lift 0" % sp)
			eq(float(t["stall_warning"]), 0.0, "%s perched telemetry: no stall warning" % sp)
			eq(float(t["airspeed"]), 0.0, "%s perched telemetry: airspeed 0" % sp)
			fx.teardown()
			fx = null


# --- P10: perching in the world's breeze (fix round 3) -----------------------------
## Round 3 verifier: every perch test flew still air while the world blows
## 1.3-2.1 m/s at perch height; a sparrow lost most landings into or across
## the wind (the assist's cone used the ground path, dropped the perch under
## a slow bird and let go, and the capture judged the airspeed only). Pinned
## at three sizes on slow glide-ins aimed at the branch through the air, the
## arms still (perch_wind.gd; the full set is the --full sweep):
##  - head and cross wind (2.1 m/s, the top of the range) and (with --full)
##    a 1.5 m/s tailwind keep >= 80 % of the still-air success;
##  - a 2.1 m/s tailwind keeps >= 70 %: downwind the branch arrives sooner (a
##    sparrow at 1.14 V_min covers the last spans 31 % faster) with the same
##    speed to lose, which is why real birds land into the wind; holding grip
##    (capture at 1.4 V_cap) is the player's remedy;
##  - no stuns, and the landing never saturates the rig's comfort caps.
func test_p10_perching_in_the_breeze() -> void:
	const PW := preload("res://tests/unit/flight/perch_wind.gd")
	var full := Paths.arg("full", "") != ""
	var set_: Array = PW.glide_set() if full else PW.glide_set_small()
	var winds := [["still", Vector3.ZERO, 0.0], ["head 2.1", Vector3(0, 0, 2.1), 0.8], ["cross 2.1", Vector3(2.1, 0, 0), 0.8],
		["tail 2.1", Vector3(0, 0, -2.1), 0.7]]
	if full:
		winds.append(["tail 1.5", Vector3(0, 0, -1.5), 0.8])
	# Default: the sparrow, the hardest case (the 60 s budget); --full flies
	# the pigeon and the eagle and the whole glide set too (the wind sweep in
	# tests/shots flies all three on the whole set).
	for sp: StringName in ([&"sparrow", &"pigeon", &"eagle"] if full else [&"sparrow"]):
		var still := 0.0
		var row := {}
		for wd in winds:
			var r: Dictionary = await PW.share(self, sp, wd[1], set_)
			row[wd[0]] = {"share": r["share"], "median_t": r["median_t"], "stuns": r["stuns"],
				"max_rate": r["max_rate_deg"], "max_accel": r["max_accel_deg"], "air_accel": r["air_accel_deg"],
				"after_touchdown_deg": r["after_deg"], "rest_s": r["rest_s"]}
			if wd[0] == "still":
				still = r["share"]
				gt(still, 0.9, "%s: slow glide-ins perch in still air (%d of %d)" % [sp, int(round(still * set_.size())), set_.size()])
			else:
				gt(float(r["share"]), float(wd[2]) * still - 1e-9, "%s %s: >= %d %% of still-air success (%.2f vs %.2f)" % [
					sp, wd[0], int(100.0 * float(wd[2])), r["share"], still])
			eq(r["stuns"], 0, "%s %s: no stuns" % [sp, wd[0]])
			# In the air (the assist's crab turns): never near the cap. At the
			# touchdown the rig's own turn brakes at the cap (fix round 4:
			# the quickest stop the comfort contract allows, the least
			# rotation after a landing; round 3 braked at 240 deg/s^2 and
			# spun when the rig turned faster than 120 deg/s).
			lt(float(r["air_accel_deg"]), 0.75 * 720.0, "%s %s: the approach never nears the rig's yaw-acceleration cap (deg/s^2)" % [sp, wd[0]])
			lt(float(r["max_accel_deg"]), 720.0 + 1e-3, "%s %s: touchdown inside the cap (deg/s^2)" % [sp, wd[0]])
			lt(float(r["max_rate_deg"]), 240.0, "%s %s: rig yaw rate inside the cap" % [sp, wd[0]])
			lt(float(r["after_deg"]), 5.0, "%s %s: the view turns < 5 deg after the touchdown" % [sp, wd[0]])
			lt(float(r["rest_s"]), 0.35, "%s %s: the rig at rest within 0.35 s of the touchdown (s)" % [sp, wd[0]])
		metric(String(sp), row)


# --- P11: the brake downwind (fix round 3) ------------------------------------------
## Downwind the branch arrives sooner, and a glide-in from above the glide
## path dives onto it. The assist's brake now plans with the ground speed
## (the landing speed must drop by dv while the bird covers the distance at
## its ground speed) and cancels the dive's own acceleration along the path.
## Round 2 used the still-air formula on the airspeed and no dive term: the
## pigeon lost the 6-span glide-ins from a span above in a 1.5 m/s tailwind
## and the eagle 6-7 of these 9 (mutation runs, FLIGHT.md §4). Pinned: from a
## span above the glide path, 6-12 spans out, in a 1.5 and a 2.1 m/s
## tailwind, the pigeon and the eagle perch on at least 7 of 9, no stuns.
func test_p11_tailwind_brake_from_above_the_glide_path() -> void:
	const PW := preload("res://tests/unit/flight/perch_wind.gd")
	var set_ := []
	for b in [6.0, 9.0, 12.0]:
		for pt in [0.6, 0.75, 0.9]:
			set_.append({"back": b, "off": 1.0, "pitch": pt, "trim": true})
	for sp: StringName in [&"pigeon", &"eagle"]:
		for tw in ([1.5, 2.1] if Paths.arg("full", "") != "" else [2.1]):
			var r: Dictionary = await PW.share(self, sp, Vector3(0, 0, -tw), set_)
			var n := int(round(float(r["share"]) * set_.size()))
			gt(n, 6, "%s tail %.1f m/s, from a span above the glide path: perched %d of 9" % [sp, tw, n])
			# The brake plans on the ground speed so the bird arrives slow enough
			# to grab the branch without bumping it first. Since round 5 a slow
			# brush no longer locks the capture out, so a bumped landing still
			# perches: round 2's airspeed-planned brake now costs at most one
			# clean approach here (eagle 8 -> 7 of 9), because the brake
			# re-plans every tick and arrives within 0.01 V_cap of this one
			# either way (v_in in the metrics; FLIGHT.md §8, mutation runs).
			gt(int(r["clean"]), 6, "%s tail %.1f: perched without touching the branch first, %d of 9" % [sp, tw, int(r["clean"])])
			eq(r["stuns"], 0, "%s tail %.1f: no stuns" % [sp, tw])
			metric("%s_tail_%.1f" % [sp, tw], {"perched": n, "clean": r["clean"], "median_t": r["median_t"],
				"v_in_med": r["v_in_med"], "v_in_max": r["v_in_max"]})


# --- P12: a tucked bird is diving, not landing ---------------------------------------
## The capture refuses a bird with its wings tucked (a dive past a branch is
## not a landing), and takes the same bird at the same place and speed with
## its wings out (round-5 engineering verifier: removing the guard passed the
## whole suite).
func test_p12_no_capture_while_tucked() -> void:
	for tucked: bool in [true, false]:
		await _fx(&"pigeon")
		var p := fx.player
		var pr := p.model.params
		p.start_flying(Vector3(0, 60, 0), 0.0, 0.0)
		# Spread first (a player's wings are out before they can tuck), then
		# fold them (or keep them out).
		fx.run(0.5)
		fx.driver = fx.synth(0.0, 0.0, 0.0 if tucked else 1.0)
		fx.run(0.4)
		eq(p.wing_state().tucked, tucked, "wings %s" % ("tucked" if tucked else "out"))
		# 0.3 span behind the grip point, slow, level: in reach next tick.
		var tgt := PERCH + Vector3.UP * pr.r_body
		p.model.reset(tgt + Vector3(0, 0, 0.3 * pr.span), Vector3(0, 0, -0.5 * _v_cap(p)), 0.0)
		fx.run(0.1)
		if tucked:
			check(p.mode != PlayerBird.Mode.PERCHED, "a tucked bird in reach of the grip, slow: no capture")
		else:
			eq(p.mode, PlayerBird.Mode.PERCHED, "the same bird with its wings out perches")
		fx.teardown()
		fx = null


# --- P14: a scrape too fast to perch locks the capture out for 0.5 s ---------------------------
## FLIGHT_SPEC §12 (round 5, R5-6): a slide contact arms the 0.5 s capture
## lockout only when the bird was too fast to perch (landing speed > V_cap):
## a bird skidding off a branch does not grab it a moment later, while a
## slow brush of the branch it is landing on keeps the capture (P13's
## crosswind). The same glancing contact (0.6 m/s into the surface) at 1.5
## and 0.7 V_cap, then the bird slow and in reach of the grip: after the fast
## scrape no capture for 0.5 s, then the capture; after the slow brush the
## capture at once (the round-6 engineering verifier: no test pinned it).
func test_p14_a_scrape_too_fast_to_perch_locks_the_capture_out() -> void:
	for fast: bool in [true, false]:
		await _fx(&"pigeon")
		var p := fx.player
		var pr := p.model.params
		var away := Vector3(0, 60, 40)
		p.start_flying(away, 0.0, 0.0)
		fx.run(0.2)
		var v := (1.5 if fast else 0.7) * _v_cap(p)
		p.model.reset(p.model.position, Vector3(-0.6, 0.0, -v), 0.0)
		var kind: int = p._classify(Vector3.RIGHT)
		eq(kind, PlayerBird.Contact.SLIDE, "%s: a glancing scrape is a slide" % ("fast" if fast else "slow"))
		var tgt := PERCH + Vector3.UP * pr.r_body
		var in_reach := func() -> void:
			p.model.reset(tgt + Vector3(0, 0, 0.3 * pr.span), Vector3(0, 0, -0.5 * _v_cap(p)), 0.0)
		in_reach.call()
		fx.run(0.1)
		if fast:
			check(p.mode != PlayerBird.Mode.PERCHED, "after a scrape at 1.5 V_cap: no capture within 0.5 s")
			# Away from the perch until 0.45 s after the scrape (a model reset,
			# not a teleport: start_flying clears the lockout with the flight).
			p.model.reset(away, Vector3(0, 0, -pr.v_c), 0.0)
			fx.run(0.35)
			in_reach.call()
			fx.run(0.1)
			eq(p.mode, PlayerBird.Mode.PERCHED, "0.5 s after the scrape: the capture again")
		else:
			eq(p.mode, PlayerBird.Mode.PERCHED, "after a slow brush (0.7 V_cap): the capture at once")
		fx.teardown()
		fx = null


# --- P13: perching in the world's full breeze (fix round 5) ----------------------------
## The round-3 verifier's approach (a slow bird 6 spans out and 0.3 span
## above the grip, 1.2 V_cap through the air straight at it, wrists slightly
## up, arms still) in the world's 2.64 m/s breeze at 30 m and above. Round 4:
## the sparrow never perched into the wind or across it. Headwind: the slow
## bird lost airspeed until the air carried it backwards 0.6 m short (now
## the assist holds its closing speed, from the headwind's own budget).
## Crosswind: the crabbing bird brushed the branch from below and hung in
## reach of the grip, locked out of the capture by the contact (now only a
## scrape too fast to perch locks it). Perched within 8 s, no stun, comfort
## held. --full adds the pigeon and eagle.
func test_p13_perching_in_the_full_breeze() -> void:
	var sizes: Array = [&"sparrow", &"pigeon", &"eagle"] if Paths.arg("full", "") != "" else [&"sparrow"]
	var winds := [["headwind", Vector3(0, 0, 2.64)], ["crosswind", Vector3(2.64, 0, 0)], ["tailwind", Vector3(0, 0, -2.64)]]
	for sp: StringName in sizes:
		for wd in winds:
			await _fx(sp, 10.0, func(w: Variant) -> void:
				w.uniform_wind = wd[1])
			var p := fx.player
			var pr := p.model.params
			var vcap := 0.8 * pr.v_min
			var start := PERCH + Vector3.UP * pr.r_body + Vector3(0, 0.3 * pr.span, 6.0 * pr.span)
			p.start_flying(start, 0.0, 0.0)
			p.model.reset(start, Vector3(0, 0, -1.2 * vcap) + (wd[1] as Vector3), 0.0)
			fx.driver = fx.synth(0.3, 0.0, 1.0)
			fx.reset_comfort()
			var t := _run_until_perched(8.0)
			var tag := "%s %s 2.64 m/s" % [sp, wd[0]]
			between(t, 0.0, 8.0, "%s: perched within 8 s (s)" % tag)
			eq(p.contacts["stun"], 0, "%s: no stun" % tag)
			fx.assert_comfort(self, tag)
			metric(tag.replace(" ", "_"), t)
			fx.teardown()
			fx = null
