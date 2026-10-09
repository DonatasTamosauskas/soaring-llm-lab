extends TestCase
## L3 collisions (FLIGHT_SPEC PB-12 C1...C7) and F10: continuous collision at
## max dive speed against a 2 cm twig and a wire, no tunnelling; glancing
## hits slide; head-on hits stun briefly; wings never stop the bird.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func _fx(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, world_setup)
	return fx


## Distance from point p to the infinite line through a along unit u.
static func _line_dist(p: Vector3, a: Vector3, u: Vector3) -> float:
	var d := p - a
	return (d - u * d.dot(u)).length()


## First fraction t in [0,1] where a sphere moving from p0 by m touches a
## cylinder of radius R_sum (= r_body + r_rod) around the line (a, u); -1 if none.
static func _analytic_hit(p0: Vector3, m: Vector3, a: Vector3, u: Vector3, r_sum: float) -> float:
	var d0 := p0 - a
	var w0 := d0 - u * d0.dot(u)
	var mw := m - u * m.dot(u)
	var qa := mw.dot(mw)
	var qb := 2.0 * w0.dot(mw)
	var qc := w0.dot(w0) - r_sum * r_sum
	if qc <= 0.0:
		return 0.0
	if qa < 1e-12:
		return -1.0
	var disc := qb * qb - 4.0 * qa * qc
	if disc < 0.0:
		return -1.0
	var t := (-qb - sqrt(disc)) / (2.0 * qa)
	return t if t >= 0.0 and t <= 1.0 else -1.0


# --- C1: Jolt's cast_motion vs thin cylinders, analytically -----------------------
func test_c1_cast_motion_never_tunnels_thin_cylinders() -> void:
	var rod_r := 0.01
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.with_ground = false
		w.add_rod(Vector3(-1.5, 100, 0), Vector3(1.5, 100, 0), rod_r))
	var p := fx.player
	var r_body := p.model.params.r_body
	var v_max := p.model.params.v_max
	var space := p.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	sph.radius = r_body
	q.shape = sph
	q.collision_mask = 1
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000
	var a := Vector3(0, 100, 0)
	var u := Vector3(1, 0, 0)
	var tunnels := 0
	var worst_gap := 0.0
	var false_hits := 0
	var hits := 0
	var worst_err := 0.0
	for i in 1000:
		var speed := rng.randf_range(2.0, 1.2 * v_max)
		# Start within one tick of travel of the rod, aimed near it.
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(r_body + rod_r + 0.002, r_body + rod_r + speed * DT * 1.2)
		var start := a + Vector3(rng.randf_range(-1.0, 1.0), sin(ang) * dist, cos(ang) * dist)
		var aim := a + Vector3(start.x + rng.randf_range(-0.05, 0.05), rng.randf_range(-1.5, 1.5) * (r_body + rod_r), rng.randf_range(-1.5, 1.5) * (r_body + rod_r))
		aim.x = start.x
		var m := (aim - start).normalized() * speed * DT
		q.transform = Transform3D(Basis.IDENTITY, start)
		q.motion = m
		var res := space.cast_motion(q)
		var t_an := _analytic_hit(start, m, a, u, r_body + rod_r)
		var t_safe := res[0] if res.size() > 0 else 1.0
		var t_unsafe := res[1] if res.size() > 1 else 1.0
		if t_an >= 0.0:
			hits += 1
			if t_safe >= 1.0:
				tunnels += 1
			else:
				# The true contact lies between Jolt's conservative "safe" and
				# first-overlap "unsafe" fractions (within 1 mm).
				var ml := m.length()
				var err := 0.0
				if t_an < t_safe:
					err = (t_safe - t_an) * ml
				elif t_an > t_unsafe:
					err = (t_an - t_unsafe) * ml
				worst_err = maxf(worst_err, err)
				worst_gap = maxf(worst_gap, (t_an - t_safe) * ml)
		elif t_safe < 1.0:
			# A stop where the analytic path clears: allowed only within 1 mm.
			var p_stop := start + m * t_safe
			if _line_dist(p_stop, a, u) > r_body + rod_r + 0.001:
				false_hits += 1
	gt(hits, 300, "the random set contains many true hits")
	eq(tunnels, 0, "0 tunnels in 1000 shots (2 m/s ... 1.2 V_max) at a 1 cm rod")
	eq(false_hits, 0, "0 false hits beyond 1 mm")
	lt(worst_err, 0.001, "analytic contact lies within Jolt's [safe, unsafe] bracket (m)")
	lt(worst_gap, 0.005, "the safe stop is at most 5 mm short of contact (m)")
	metric("hits", hits)
	metric("worst_contact_err_m", worst_err)
	metric("worst_safe_gap_m", worst_gap)


# --- C1b: the same through PlayerBird's own sweep --------------------------------
## C1 checks Jolt's cast_motion itself; this fires the real PlayerBird at the
## rod: random directions and speeds up to 1.2 V_max, 72 Hz ticks and 0.1 s
## frame hitches, sparrow and eagle. On every tick the body's centre is
## outside the rod's (r_body + r_rod - 1 mm) cylinder (no penetration), and
## no tick's straight path passes through the rod itself (no tunnel; a body
## that slides round the rod within a tick has a chord that dips below
## r_body + r_rod, never into the rod).
func test_c1b_playerbird_sweep_never_tunnels() -> void:
	var rod_r := 0.01
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_rod(Vector3(-3.0, 100, 0), Vector3(3.0, 100, 0), rod_r))
		var p := fx.player
		var pr := p.model.params
		var r_sum := pr.r_body + rod_r
		var a := Vector3(0, 100, 0)
		var u := Vector3(1, 0, 0)
		var rng := RandomNumberGenerator.new()
		rng.seed = 77
		var st := {"contacts": 0, "tunnels": 0, "inside": 0, "worst": INF}
		for i in 300:
			var dt := 0.1 if i % 3 == 0 else DT
			var speed := rng.randf_range(2.0, 1.2 * pr.v_max)
			var ang := rng.randf() * TAU
			var dist := r_sum + rng.randf_range(0.01, 2.0 * speed * dt)
			var start := a + Vector3(rng.randf_range(-1.0, 1.0), sin(ang) * dist, cos(ang) * dist)
			var aim := a + Vector3(start.x, rng.randf_range(-1.2, 1.2) * r_sum, rng.randf_range(-1.2, 1.2) * r_sum)
			var v := (aim - start).normalized() * speed
			p.start_flying(start, FlightMath.yaw_of(Vector3(v.x, 0, v.z)) if Vector2(v.x, v.z).length() > 0.1 else 0.0, 0.0)
			p.model.reset(start, v, NAN)
			var c0: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"]
			var prev := p.model.position
			for k in 3:
				p.tick(dt)
				var cur := p.model.position
				if _analytic_hit(prev, cur - prev, a, u, rod_r + 0.002) >= 0.0:
					st["tunnels"] += 1
				var d := _line_dist(cur, a, u)
				if d < r_sum - 0.001:
					st["inside"] += 1
				st["worst"] = minf(st["worst"], d)
				prev = cur
			st["contacts"] += 1 if p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"] > c0 else 0
		gt(st["contacts"], 60, "%s: the shots really hit the rod (%d contacts)" % [sp, st["contacts"]])
		eq(st["tunnels"], 0, "%s: 300 shots (to 1.2 V_max, 1/72 and 0.1 s ticks): no tick's path passes through the rod" % sp)
		eq(st["inside"], 0, "%s: the centre is never inside r_body + r_rod (-1 mm) on any tick" % sp)
		gt(st["worst"], r_sum - 0.001, "%s: closest centre-to-axis distance (m)" % sp)
		metric("%s_contacts" % sp, st["contacts"])
		metric("%s_closest_m" % sp, [st["worst"], r_sum])
		fx.teardown()
		fx = null


# --- F10: a V_max dive into a 2 cm twig and into a wire ----------------------------
func _dive_at(rod_r: float, lateral: float) -> Dictionary:
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.with_ground = false
		w.add_rod(Vector3(-2.0, 100, 0), Vector3(2.0, 100, 0), rod_r))
	var p := fx.player
	var pr := p.model.params
	# Terminal tucked dive, straight down at the rod (offset `lateral` in z).
	p.start_flying(Vector3(0, 106, lateral), 0.0, 0.0)
	# A real terminal tuck dive: body along the path (alpha ~ 0, no lift).
	p.model.reset(Vector3(0, 106, lateral), Vector3(0, -pr.v_max, 0), 0.0)
	p.model.theta = -PI / 2
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(-1.0, 0.0, 0.0, p.wing_input.calibration)
	var out := {"min_axis": INF, "passed": false, "stunned": false, "slid": false, "v0": p.model.velocity.length()}
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		var pos: Vector3 = f.player.model.position
		out["min_axis"] = minf(out["min_axis"], Vector2(pos.y - 100.0, pos.z).length())
		if pos.y < 100.0 - 0.3 and absf(pos.z) < pr.r_body + rod_r:
			out["passed"] = true
		if f.player.mode == PlayerBird.Mode.STUNNED:
			out["stunned"] = true
		if f.player.last_contact == PlayerBird.Contact.SLIDE:
			out["slid"] = true
	fx.run(1.0)
	out["r_sum"] = pr.r_body + rod_r
	out["v_end"] = p.model.velocity.length()
	fx.teardown()
	fx = null
	return out


func test_f10_vmax_dive_into_twig_and_wire() -> void:
	for rod in [["twig 2 cm", 0.01], ["wire 1.2 cm", 0.006]]:
		var head: Dictionary = await _dive_at(rod[1], 0.0)
		check(not head["passed"], "%s head-on at V_max: no tunnelling" % rod[0])
		gt(head["min_axis"], head["r_sum"] - 0.001, "%s: body never inside the rod (m from axis)" % rod[0])
		check(head["stunned"], "%s head-on at V_max: stunned (not killed)" % rod[0])
		metric("%s_min_axis" % rod[0], head["min_axis"])
		# Grazing: the centre passes 0.97 x (r_body + r_rod) off the axis, a 14 deg
		# incidence with v_n = 0.24 V_max < 0.7 V_c: the spec's glancing slide.
		var graze: Dictionary = await _dive_at(rod[1], 0.97 * (SizeRules.body_radius_for_mass(0.03) + rod[1]))
		gt(graze["min_axis"], graze["r_sum"] - 0.001, "%s grazing at V_max: never inside the rod" % rod[0])
		check(not graze["stunned"], "%s grazing at V_max: slides, no stun" % rod[0])


# --- C2 / C3: glancing slides, head-on stuns ------------------------------------
func test_c2_c3_glancing_slides_head_on_stuns() -> void:
	for sp in [&"sparrow", &"pigeon"]:
		# C2: 15 deg into a wall at cruise.
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -6.0), Vector3(200, 40, 1)))
		var p := fx.player
		var vc := p.model.params.v_c
		# Flying along the wall (mostly -x) and closing on it at 15 deg.
		var ang := 15.0 * DEG
		var v0 := Vector3(-cos(ang), 0, -sin(ang)) * vc
		p.start_flying(Vector3(0, 100, -4.0), FlightMath.yaw_of(v0), 0.0)
		p.model.reset(Vector3(0, 100, -4.0), v0, FlightMath.yaw_of(v0))
		fx.reset_events()
		fx.run(1.5)
		eq(fx.player.contacts["stun"], 0, "%s C2: 15 deg glancing at V_c: no stun" % sp)
		gt(fx.player.contacts["slide"] + fx.player.contacts["silent"], 0, "%s C2: it did touch the wall" % sp)
		gt(p.model.airspeed() / vc, 0.85, "%s C2: speed kept after a glancing slide" % sp)
		gt(p.model.position.z, -6.0 + 0.5 + p.model.params.r_body - 0.002, "%s C2: stays on the near side of the wall" % sp)
		fx.assert_comfort(self, "%s glancing slide" % sp)
		fx.teardown()
		fx = null
		# C3: head-on at cruise.
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -4.0), Vector3(200, 40, 1)))
		p = fx.player
		p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
		p.model.reset(Vector3(0, 100, 0), Vector3(0, 0, -vc), 0.0)
		# Hard flapping all along: inputs must be ignored while stunned.
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		var st := {"t_hit": -1.0, "t_end": -1.0, "bounce": 0.0, "bounce_h": 0.0, "stun_input": 0.0, "force_rises": 0, "f_prev": INF,
			"was": false}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var m: PlayerBird.Mode = f.player.mode
			var entering: bool = m == PlayerBird.Mode.STUNNED and not st["was"]
			st["was"] = m == PlayerBird.Mode.STUNNED
			if m == PlayerBird.Mode.STUNNED:
				if st["t_hit"] < 0.0:
					st["t_hit"] = tick * DT
					st["bounce"] = f.player.model.velocity.z
					st["bounce_h"] = Vector2(f.player.model.velocity.x, f.player.model.velocity.z).length()
				if entering:
					st["f_prev"] = INF
				# From the first full stunned tick of each stun (the impact
				# tick's input was built before the collision happened).
				if not entering:
					st["stun_input"] = maxf(st["stun_input"], f.player._ws.flap_l + f.player._ws.flap_r)
					var fp: float = f.player.model._p_l + f.player.model._p_r
					if fp > st["f_prev"] + 1e-9:
						st["force_rises"] += 1
					st["f_prev"] = fp
			elif st["t_hit"] >= 0.0 and st["t_end"] < 0.0:
				st["t_end"] = tick * DT
				st["mode_after"] = m
				st["z_after"] = f.player.model.position.z
			if entering and st["t_end"] >= 0.0 and not st.has("t_second"):
				st["t_second"] = tick * DT
		fx.run(3.0)
		print("[flight] C3 %s: hit %.2f end %.2f second %s z_after %s" % [sp, st["t_hit"], st["t_end"], str(st.get("t_second", -1)), str(st.get("z_after", 0))])
		check(st["t_hit"] >= 0.0, "%s C3: head-on at V_c stuns" % sp)
		between(st["t_end"] - st["t_hit"], 0.6 - DT, 1.4 + DT, "%s C3: stun lasts 0.6-1.4 s" % sp)
		# Head-on the wall stops the bird dead and it drops (fix round 4: a
		# backward bounce is a path the bird does not face, which the model
		# would snap the heading onto; round 3 swung the view 110 deg).
		gt(st["bounce"], -1e-6, "%s C3: never moves into the wall after the hit (v.n >= 0)" % sp)
		lt(absf(st["bounce_h"]), 0.3 * p.model.params.v_c, "%s C3: stopped by the wall (horizontal speed < 0.3 V_c)" % sp)
		eq(st["stun_input"], 0.0, "%s C3: the model gets a limp WingState while stunned (inputs ignored)" % sp)
		check(st["force_rises"] == 0, "%s C3: no new flap force while stunned (only the old stroke decays)" % sp)
		# The stun ends in normal flight. (The pilot keeps flapping hard at the
		# wall throughout, so a later second impact is the right outcome and
		# depends only on how far the bounce carried: not asserted.)
		eq(int(st.get("mode_after", -1)), PlayerBird.Mode.FLYING, "%s C3: flying again when the stun ends" % sp)
		gt(fx.events["collided"], 0, "%s C3: player_collided emitted" % sp)
		fx.teardown()
		fx = null


# --- C5: a slot 1.2 body diameters wide: flap out, no contact storm ---------------
func test_c5_escape_a_tight_slot() -> void:
	var r := SizeRules.body_radius_for_mass(0.03)
	var gap := 1.2 * 2.0 * r
	# A crevice: two walls 1.2 body diameters apart, 1.5 m tall, 4 m long,
	# with a floor; open at the top and at both ends.
	await _fx(&"sparrow", func(w: Variant) -> void:
		w.with_ground = false
		w.add_wall(Vector3(-0.5 * gap - 0.5, 100.0, 0), Vector3(1.0, 1.5, 4.0))
		w.add_wall(Vector3(0.5 * gap + 0.5, 100.0, 0), Vector3(1.0, 1.5, 4.0))
		w.add_wall(Vector3(0, 99.25 - 0.05, 0), Vector3(1.0, 0.1, 4.0)))
	var p := fx.player
	p.start_flying(Vector3(0, 99.35, 0), 0.0, 0.5)
	p.model.velocity = Vector3.ZERO
	# Strokes begin with the arms low (an upstroke first earns the first
	# downstroke its credit), wrists slightly up (hover).
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.0)
		for a in b.arms:
			a.twist = 20.0 * DEG
	var st := {"t_out": -1.0, "c1": 0}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pos: Vector3 = f.player.model.position
		if st["t_out"] < 0.0 and (pos.y > 100.75 + r or absf(pos.z) > 2.0 + r):
			st["t_out"] = tick * DT
		if tick == 72:
			st["c1"] = f.player.contacts["slide"] + f.player.contacts["stun"] + f.player.contacts["silent"]
	fx.run(3.0)
	var c_late: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"] - int(st["c1"])
	check(st["t_out"] >= 0.0 and st["t_out"] <= 2.0, "flapping escapes a crevice 1.2 body diameters wide within 2 s (%.2f)" % st["t_out"])
	lt(float(c_late) / 2.0, 3.0 + 1e-6, "no contact storm: <= 3 contacts/s after 1 s")
	metric("escape_s", st["t_out"])
	metric("late_contacts", c_late)


# --- C7: a 2 x 1.5 span window flown centred ---------------------------------------
func test_c7_window_centred_zero_collisions() -> void:
	for sp in [&"sparrow", &"eagle"]:
		var span := SizeRules.wingspan_for_mass(FlightParams.species_mass(sp))
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_window(Vector3(0, 100, -3.0 * span - 1.0), Vector3(0, 0, 1), 2.0 * span, 1.5 * span, 0.5 * span))
		var p := fx.player
		p.start_flying(Vector3(0, 100, 0), 0.0, 0.0)
		p.model.reset(Vector3(0, 100, 0), Vector3(0, 0, -p.model.params.v_c), 0.0)
		fx.reset_events()
		fx.run(1.0 + 6.0 * span / p.model.params.v_c)
		lt(p.model.position.z, -3.0 * span - 1.0 - 0.25 * span, "%s: through the window" % sp)
		eq(p.contacts["slide"] + p.contacts["stun"], 0, "%s: 0 frame collisions (brushes allowed)" % sp)
		metric("%s_brushes" % sp, p.contacts["brush"])
		fx.teardown()
		fx = null


# --- C8: a head-on wall with neutral arms is one stun, not a stun lock ------------
## The round-2 verifier flew head-on into a wall at cruise with the arms
## held still (airplane pose): pigeon 3 stuns in 8 s, eagle 4-5, sliding
## down the wall to the ground. After a head-on stun the heading still
## pointed at the wall, so the bird flew straight back in as soon as the
## controls returned. Fix round 4: the stun turns the bird at most 40 deg
## (the short way toward leaving), a wall within the post-stun grace only
## slides it, and the bird flies on along the wall until the player turns.
func test_c8_head_on_wall_neutral_arms_no_stun_lock() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for wall_d in [1.0, 0.2]:
			await _fx(sp, func(w: Variant) -> void:
				w.add_wall(Vector3(0, 40, -40), Vector3(60, 80, wall_d)))
			var p := fx.player
			p.start_flying(Vector3(0, 40, -40 + 6.0 * p.model.params.span + 3.0), 0.0, 0.0)
			var st := {"stuns": 0, "prev": p.mode, "stunned_s": 0.0, "first": -1.0, "forced": 0.0, "hp": p.model.heading()}
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var m: int = f.player.mode
				# The heading's largest change in one tick: a flown turn moves it
				# at most 240 deg/s x 1/72 s = 3.3 deg; anything more is a contact.
				st["forced"] = maxf(st["forced"], absf(FlightMath.wrap_angle(f.player.model.heading() - float(st["hp"]))))
				st["hp"] = f.player.model.heading()
				if m == PlayerBird.Mode.STUNNED:
					st["stunned_s"] += DT
					if st["prev"] != PlayerBird.Mode.STUNNED:
						st["stuns"] += 1
						if st["first"] < 0.0:
							st["first"] = tick * DT
				st["prev"] = m
			fx.run(8.0)
			var tag := "%s wall %.1f m" % [sp, wall_d]
			print("[flight] C8 %s: first stun %.2f s, %d stun(s), %.2f s stunned, mode %s, alt %.1f, %.1f m from the wall" % [
				tag, st["first"], st["stuns"], st["stunned_s"], p.mode_name(), p.model.position.y, p.model.position.z + 40.0 - 0.5 * wall_d])
			eq(st["stuns"], 1, "%s: one head-on stun, then the bird flies on (8 s, arms still)" % tag)
			eq(p.mode, PlayerBird.Mode.FLYING, "%s: flying at the end" % tag)
			lt(rad_to_deg(st["forced"]), 40.0 + 3.4, "%s: no tick turns the bird more than a contact's 40 deg + a flown tick (deg)" % tag)
			fx.assert_comfort(self, "%s stun" % tag)
			metric(tag.replace(" ", "_"), [st["stuns"], st["stunned_s"]])
			fx.teardown()
			fx = null


# --- C8b: oblique wall hits: one stun, a small forced turn (fix rounds 3, 4) ----
## Round 3 verifier: a cruise-speed hit at 30-60 deg incidence with the arms
## still stunned 2-4 times in 8 s (the view was left on the wall and body
## steer flew the bird back in). Round 3 then turned every stun to leave the
## wall at 20 deg: incidence + 20, 110 deg head-on, with no input from the
## player. Round-4 lead: the stun deflects the velocity and turns the bird as
## little as possible, at most 40 deg; the player turns the rest. Pinned at
## three sizes and 30-90 deg:
##  - one stun in 8 s, arms still;
##  - the stun's own turn: the short way toward leaving at 20 deg, capped:
##    min(incidence + 20, 40) deg; no contact ever turns the bird more;
##  - the view: in the 3 s after the hit it turns at most as far as the wall
##    line lies from the old heading (the bird then flies along the wall)
##    plus the sideslip settling (12 deg), and at least 40 deg less than
##    round 3's head-on turn; the forced turn is paid inside 120 deg/s and
##    240 deg/s^2 by ViewTurn; 1 s after the stun the view faces the
##    heading; the rig's safety net never acts.
func test_c8b_oblique_wall_hits_one_stun_small_forced_turn() -> void:
	var worst := {"forced": 0.0, "rot": 0.0, "vt_rate": 0.0, "vt_acc": 0.0, "off": 0.0}
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		# One fixture per size: start_flying starts each flight fresh.
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -20), Vector3(400, 200, 1.0)))
		var incs: Array = [30.0, 45.0, 60.0, 75.0, 90.0] if Paths.arg("full", "") != "" else [30.0, 60.0, 90.0]
		for inc: float in incs:
			var p := fx.player
			var pr := p.model.params
			p.rig_limited_ticks = 0
			fx.reset_comfort()
			var yaw := (90.0 - inc) * DEG
			var start := Vector3(pr.v_c * 0.8 * cos(inc * DEG), 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
			p.start_flying(start, yaw, 0.0)
			var st := {"stuns": 0, "prev": p.mode, "hit": -1.0, "end": -1.0, "off": -1.0, "stun_turn": 0.0, "forced": 0.0,
				"rot": 0.0, "yp": p.rig_yaw, "vt_rate": 0.0, "vt_acc": 0.0, "hp": p.model.heading(), "forced_sum": 0.0}
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				var t := tick * DT
				# The heading's change this tick (a flown turn: <= 3.3 deg).
				var dh := FlightMath.wrap_angle(pl.model.heading() - float(st["hp"]))
				st["hp"] = pl.model.heading()
				if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
					if st["hit"] < 0.0:
						st["hit"] = t
						st["stun_turn"] = dh
				if pl.mode == PlayerBird.Mode.FLYING and st["prev"] == PlayerBird.Mode.STUNNED and st["end"] < 0.0:
					st["end"] = t
				st["prev"] = pl.mode
				st["forced"] = maxf(st["forced"], absf(dh))
				st["vt_rate"] = maxf(st["vt_rate"], absf(pl.view_turn.rate))
				st["vt_acc"] = maxf(st["vt_acc"], absf(pl.view_turn.acc))
				var dy := absf(FlightMath.wrap_angle(pl.rig_yaw - float(st["yp"])))
				st["yp"] = pl.rig_yaw
				if st["hit"] >= 0.0 and t - float(st["hit"]) <= 3.0:
					st["rot"] += dy
					# Every heading jump the model reports (owed to the view):
					# the contact's turn and a stopped bird's path snapping.
					st["forced_sum"] += absf(pl.forced_turn)
				if st["end"] >= 0.0 and st["off"] < 0.0 and t >= float(st["end"]) + 1.0:
					st["off"] = absf(FlightMath.wrap_angle(pl.rig_yaw + pl.wing_state().body_yaw - pl.model.heading()))
			fx.run(8.0)
			var tag := "%s %d deg" % [sp, int(inc)]
			eq(st["stuns"], 1, "%s: one stun in 8 s, arms still" % tag)
			near(absf(rad_to_deg(st["stun_turn"])), minf(inc + 20.0, 40.0), 1.0, "%s: the stun turns the bird min(incidence + 20, 40) deg (deg)" % tag)
			lt(rad_to_deg(st["forced"]), 40.0 + 3.4, "%s: no tick turns the bird more than a contact's 40 deg + a flown tick (deg)" % tag)
			lt(rad_to_deg(st["rot"]), maxf(inc, 40.0) + 12.0, "%s: in the 3 s after the hit the view turns at most to the wall line + 12 (deg)" % tag)
			# The total forced (not flown) heading change in those 3 s (round-5
			# engineering verifier): the contact's turn, min(incidence + 20, 40),
			# plus the stopped bird's path heading snapping to its new path as it
			# falls away along the wall (the heading of a stalled, falling bird
			# follows its air path once that is faster than 0.25 V_min): 22-34
			# deg head-on, 5 deg at 60 deg. That snap is bounded here by the
			# contact cap itself (40 deg); the rest of the 3 s rotation is flown.
			lt(rad_to_deg(st["forced_sum"]), minf(inc + 20.0, 40.0) + 40.0, "%s: forced (not flown) heading change in the 3 s after the hit (deg)" % tag)
			lt(rad_to_deg(st["vt_rate"]), 120.0 + 1e-3, "%s: the forced turn is paid inside 120 deg/s" % tag)
			lt(rad_to_deg(st["vt_acc"]), 240.0 + 1e-3, "%s: the forced turn is paid inside 240 deg/s^2" % tag)
			between(rad_to_deg(st["off"]), 0.0, 10.0, "%s: 1 s after the stun the view faces the heading (deg)" % tag)
			eq(p.rig_limited_ticks, 0, "%s: the rig's comfort safety net never had to act" % tag)
			fx.assert_comfort(self, tag)
			worst["forced"] = maxf(worst["forced"], rad_to_deg(st["forced"]))
			worst["rot"] = maxf(worst["rot"], rad_to_deg(st["rot"]))
			worst["vt_rate"] = maxf(worst["vt_rate"], rad_to_deg(st["vt_rate"]))
			worst["vt_acc"] = maxf(worst["vt_acc"], rad_to_deg(st["vt_acc"]))
			worst["off"] = maxf(worst["off"], rad_to_deg(st["off"]))
			metric(tag.replace(" ", "_"), {"stuns": st["stuns"], "stun_turn_deg": rad_to_deg(st["stun_turn"]), "max_forced_deg": rad_to_deg(st["forced"]),
				"view_rotation_3s_deg": rad_to_deg(st["rot"]), "vt_peak_rate": rad_to_deg(st["vt_rate"]), "vt_peak_acc": rad_to_deg(st["vt_acc"]),
				"forced_total_3s_deg": rad_to_deg(st["forced_sum"]),
				"off_deg": rad_to_deg(st["off"])})
			fx.on_tick = Callable()
		fx.teardown()
		fx = null
	print("[flight] C8b worst: %s" % str(worst))


# --- C10: stuns that end on the floor or bounce round a room never spin the view ---
## Round-4 engineering verifier: round 3's view-turn re-plan had no feasible
## fallback, and landing on the floor braked the rig through it from up to
## 240 deg/s: in a 4 x 2.5 x 4 m room 15 of 96 fast entries spun the view at
## the 240 deg/s cap for seconds while the bird stood on the floor (one
## turned 10 271 deg in 55 s). Now ViewTurn is a time-optimal follower that
## cannot run away, and on the floor or a perch nothing is owed and the rig
## brakes to rest at the acceleration cap. Pinned: the verifier's worst room
## flight and a set of entries at two sizes, and low hits on a house wall
## that drop the bird to the ground: the view-turn payout stays inside
## 120 deg/s; the view never turns faster than 150 deg/s for more than 0.3 s
## in all; standing on the floor (or perched) the rig is at rest from 0.35 s
## after touching down; the comfort monitor holds. (--full: the verifier's
## whole sweep: 96 room entries, 162 wall hits.)
func _no_spin_flight(tag: String, dur: float, st_all: Dictionary) -> void:
	fx.reset_comfort()
	var st := {"vt": 0.0, "fast": 0.0, "down_t": -1.0, "down_spin": 0}
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["vt"] = maxf(st["vt"], absf(pl.view_turn.rate))
		if absf(pl.rig_yaw_rate) > deg_to_rad(150.0):
			st["fast"] += DT
		if pl.mode == PlayerBird.Mode.GROUNDED or pl.mode == PlayerBird.Mode.PERCHED:
			if st["down_t"] < 0.0:
				st["down_t"] = 0.0
			else:
				st["down_t"] += DT
			if st["down_t"] > 0.35 and pl.rig_yaw_rate != 0.0:
				st["down_spin"] += 1
		else:
			st["down_t"] = -1.0
	fx.run(dur)
	fx.on_tick = Callable()
	lt(rad_to_deg(st["vt"]), 120.0 + 1e-3, "%s: the view-turn payout inside 120 deg/s" % tag)
	lt(st["fast"], 0.3, "%s: the view never turns faster than 150 deg/s for long (s in all)" % tag)
	eq(st["down_spin"], 0, "%s: on the floor the rig is at rest 0.35 s after touching down (ticks turning)" % tag)
	fx.assert_comfort(self, tag)
	st_all["flights"] += 1
	st_all["vt"] = maxf(st_all["vt"], rad_to_deg(st["vt"]))
	st_all["fast"] = maxf(st_all["fast"], st["fast"])


func test_c10_room_and_floor_stuns_never_spin_the_view() -> void:
	var full := Paths.arg("full", "") != ""
	var st_all := {"flights": 0, "vt": 0.0, "fast": 0.0}
	for sp: StringName in [&"sparrow", &"pigeon"]:
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -2.1), Vector3(4.4, 2.9, 0.2))
			w.add_wall(Vector3(0, 100, 2.1), Vector3(4.4, 2.9, 0.2))
			w.add_wall(Vector3(-2.1, 100, 0), Vector3(0.2, 2.9, 4.4))
			w.add_wall(Vector3(2.1, 100, 0), Vector3(0.2, 2.9, 4.4))
			w.add_wall(Vector3(0, 98.65, 0), Vector3(4.4, 0.2, 4.4))
			w.add_wall(Vector3(0, 101.35, 0), Vector3(4.4, 0.2, 4.4)))
		var p := fx.player
		var pr := p.model.params
		# The verifier's worst (sparrow, yaw 255, from (0.8, 0.4)) and a spread.
		var cases: Array = [[255.0, 0.8, 0.4]] if sp == &"sparrow" else []
		var yaws: Array = range(0, 360, 15) if full else ([0, 150, 300] if sp == &"sparrow" else [75, 225])
		for y in yaws:
			for sx in ([-0.8, 0.8] if full else [0.8]):
				cases.append([float(y), sx, 0.5 * sx])
		for c in cases:
			var yaw := float(c[0]) * DEG
			var start := Vector3(float(c[1]), 100.0, float(c[2]))
			p.start_flying(start, yaw, 0.0)
			p.model.reset(start, FlightMath.yaw_forward(yaw) * pr.v_c * 1.2, yaw)
			_no_spin_flight("%s room yaw %d from %.1f" % [sp, int(c[0]), c[1]], 6.0, st_all)
		fx.teardown()
		fx = null
	# Low hits on a house wall standing on the ground: the stunned bird drops
	# to the ground by the wall.
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			w.add_wall(Vector3(0, 5, -10.1), Vector3(60, 10, 0.2)))
		var p := fx.player
		var pr := p.model.params
		var incs: Array = [20.0, 35.0, 50.0, 65.0, 80.0, 90.0] if full else [50.0, 90.0]
		var hs: Array = [0.3, 0.8, 1.5] if full else [0.3]
		for inc: float in incs:
			for h: float in hs:
				var yaw := (90.0 - inc) * DEG
				var start := Vector3(-1.5 * cos(inc * DEG), h, -10.0 + pr.r_body + 1.5 * sin(inc * DEG))
				p.start_flying(start, yaw, 0.0)
				p.model.reset(start, FlightMath.yaw_forward(yaw) * pr.v_c, yaw)
				_no_spin_flight("%s wall %d deg at %.1f m" % [sp, int(inc), h], 5.0, st_all)
		fx.teardown()
		fx = null
	metric("summary", st_all)
	print("[flight] C10 %s" % str(st_all))


# --- C9: a V_max dive into the ground stuns once ----------------------------------
## Round 3 verifier: a tucked dive at 0.97 V_max straight down bounced the
## pigeon and eagle a metre up (0.25 of the impact speed), the stun ended in
## the air and the still-tucked bird dived in again: two stuns. Floors bounce
## floor_restitution (0.05). Pinned at 90 and 60 deg: never through the
## ground, one stun, then at rest on the ground (GROUNDED) with the tuck held.
func test_c9_vmax_dive_into_the_ground_stuns_once() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for ang: float in [90.0, 60.0]:
			await _fx(sp)
			var p := fx.player
			var pr := p.model.params
			p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
			fx.run(0.5)
			fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				for a in b.arms:
					a.elbow = 150.0 * DEG
			fx.run(0.4)
			var v := 0.97 * pr.v_max
			var dir := Vector3(0, -sin(ang * DEG), -cos(ang * DEG))
			var start := Vector3(0, pr.r_body + v * 0.5 * sin(ang * DEG) + 0.01, 0)
			p.model.reset(start, dir * v, 0.0)
			var st := {"clear": INF, "stuns": 0, "prev": p.mode, "hop": 0.0, "stunned": false}
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				st["clear"] = minf(st["clear"], pl.model.position.y - pr.r_body)
				if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
					st["stunned"] = true
				if st["stunned"]:
					st["hop"] = maxf(st["hop"], pl.model.position.y - pr.r_body)
				st["prev"] = pl.mode
			fx.run(4.0)
			var tag := "%s %d deg" % [sp, int(ang)]
			check(p.wing_state().tucked, "%s: the dive is tucked" % tag)
			gt(st["clear"], -0.002, "%s: never through the ground (m)" % tag)
			eq(st["stuns"], 1, "%s: one stun" % tag)
			# Round 2 bounced ~1 m (1.5 pigeon spans, 4 sparrow spans); what is left is
			# a few centimetres of lift while the stunned bird slides on.
			lt(st["hop"] / pr.span, 0.5, "%s: the bounce hops under half a span" % tag)
			eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: at rest on the ground after the stun" % tag)
			metric(tag.replace(" ", "_"), {"stuns": st["stuns"], "hop_spans": st["hop"] / pr.span, "clear_mm": st["clear"] * 1000.0})
			fx.teardown()
			fx = null


# --- C11: falling along a wall face is not a floor hit (fix round 4) ---------
## A bird dropping along a wall grazes it: the sweep's cast can report a hit
## that the rest query at its unsafe point cannot find. Round 3 guessed that
## contact's normal as minus the motion, so a fall along a wall read as a
## floor hit at the full fall speed (while developing round 4, a head-on
## eagle was stunned five more times on the way down). Now the query is
## repeated with a 2 mm margin, and with still nothing the sweep stops at the
## safe point with no response.
func test_c11_falling_along_a_wall_is_not_a_floor_hit() -> void:
	var full := Paths.arg("full", "") != ""
	for sp: StringName in ([&"sparrow", &"pigeon", &"eagle"] if full else [&"eagle"]):
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 50, -10.5), Vector3(40, 60, 1.0)))
		var p := fx.player
		var pr := p.model.params
		var bad := PackedStringArray()
		var n := 0
		for gap: float in [0.0, 0.0002, 0.0005, 0.001, 0.002, 0.004]:
			for vz: float in [0.0, -0.02, -0.1, -0.4]:
				for fall: float in [0.3, 0.8]:
					var start := Vector3(0, 70, -10.0 + pr.r_body + gap)
					p.start_flying(start, 90.0 * DEG, 0.0)
					p.model.reset(start, Vector3(0, -fall * pr.v_max, vz), 90.0 * DEG)
					var c0: Dictionary = p.contacts.duplicate()
					fx.run(0.4)
					n += 1
					if p.contacts["stun"] > c0["stun"] or p.contacts["land"] > c0["land"]:
						bad.append("gap %.4f vz %.2f fall %.1f: stuns %d lands %d" % [gap, vz, fall,
							p.contacts["stun"] - c0["stun"], p.contacts["land"] - c0["land"]])
		eq(bad.size(), 0, "%s: %d falls along a wall face, none stunned or landed by it (%s)" % [sp, n, ", ".join(bad)])
		metric("%s_falls" % sp, n)
		fx.teardown()
		fx = null



# --- C12: a bird pressed against a wall slides along it ---------------------------
## A gentle bank toward a wall the bird flies along keeps turning it into the
## wall. Every tick's motion then starts touching the wall and runs into it
## at once: the sweep slides
## the rest of the motion along it (up to 3 casts a tick). A single cast
## stops at the contact every tick and the bird sticks to the wall (round-5
## engineering verifier: that mutant passed the whole suite). Along-wall
## distance in 2 s >= 90 % of the airspeed's, never through the wall, no stun.
func test_c12_pressed_against_a_wall_the_bird_slides_along_it() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(-0.5, 100, -150), Vector3(1.0, 200, 400)))
		var p := fx.player
		var pr := p.model.params
		p.start_flying(Vector3(pr.r_body + 0.001, 100, 0), 0.0, 0.0)
		fx.driver = fx.synth(0.0, -0.15)
		var st := {"min_x": INF, "touch": 0, "v_sum": 0.0, "n": 0}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			st["min_x"] = minf(st["min_x"], pl.model.position.x)
			if pl.model.position.x < pr.r_body + 0.002:
				st["touch"] += 1
			st["v_sum"] += pl.model.airspeed()
			st["n"] += 1
		var z0 := p.model.position.z
		fx.run(2.0)
		var along := z0 - p.model.position.z
		var v_mean := float(st["v_sum"]) / float(st["n"])
		gt(int(st["touch"]), 100, "%s: pressed against the wall most of the run (ticks)" % sp)
		gt(along, 0.9 * v_mean * 2.0, "%s: slides along the wall at its speed (m in 2 s; airspeed %.1f m/s)" % [sp, v_mean])
		gt(float(st["min_x"]), pr.r_body - 0.002, "%s: never into the wall (m)" % sp)
		eq(p.contacts["stun"], 0, "%s: no stun" % sp)
		fx.assert_comfort(self, "%s wall slide" % sp)
		metric(String(sp), {"along_m": along, "touch_ticks": st["touch"]})
		fx.teardown()
		fx = null
