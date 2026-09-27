extends TestCase
## Verifier probe (verification round 3 of the flight area, EXPERIENCE &
## REQUIREMENTS lens). Earlier probes (r3x..r6x) covered the ladder from
## sparrow to eagle, slopes, roofs, resume and perching in wind. This one
## targets what a player reaches or does that nothing pins yet:
##  1. The APEX: GameLoop.MAX_PLAYER_MASS is 4.5 kg (1.5 x the 3.0 kg eagle,
##     "the apex is a goal"). Every flight test stops at the eagle. At 4.5 kg:
##     the F7 envelope vs SizeRules.performance, F6 updrafts, ground take-off,
##     the low-perch launch, landing on the meadow, and the bot course (F12).
##  2. Growing while grounded or perched (a catch while on the ground or a
##     branch steps the mass at once: GameLoop._player_ate).
##  3. The arena's lid: the real world closes the sky with an invisible slab
##     at World.ceiling (soaring_world._build_boundary). Flight fades lift
##     over the last 20 m. Does a flapping or thermalling bird bump the lid?
##  4. Seated-feasible ways off a hillside a pigeon / eagle landed on facing
##     uphill (a seated player cannot turn round; Settings.snap_turn is
##     reserved/false): banking away, or a 45 deg torso twist.
## Output: artifacts/flight/verify/r7x/experience_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const BC := preload("res://tests/unit/flight/bot_course.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
## GameLoop.MAX_PLAYER_MASS (scripts/game/game_loop.gd), copied (the probe
## must not depend on another area's script).
const APEX := 4.5
const H0 := 30.0

var fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r7x/experience_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _done() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


## A fixture flying a bird of any mass (the eagle's scene, then the mass).
func _new_fx_mass(mass: float, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(&"eagle" if mass >= 2.0 else &"sparrow", world_setup)
	fx.player.mass = mass
	fx.player.tick(DT)   # applies the mass (params, world scale)
	return fx


func _model(mass: float) -> FlightModel:
	return FlightModel.new(mass, FS.tuning(1))


# --- 1a. The apex envelope (model level, F7 / F6 method) ----------------------------------

func test_r7x_apex_envelope_matches_size_rules() -> void:
	var prev := {}
	for mass: float in [3.0, APEX]:
		var perf := SizeRules.performance(mass)
		var m := _model(mass)
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 40 * 72, FS.glide(0.0), null, rec)
		var cruise := FS.mean(rec.v, rec.at(30.0))
		var m2 := _model(mass)
		m2.trim(Vector3(0, 800, 0), 0.0, 0.88)
		var rec2 := FS.Rec.new()
		FS.run(m2, 20 * 72, FS.glide(0.88), null, rec2)
		var vmin := FS.mean(rec2.v, rec2.at(10.0))
		var m3 := _model(mass)
		m3.trim(Vector3(0, 3000, 0), 0.0, 0.0)
		var rec3 := FS.Rec.new()
		FS.run(m3, 20 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec3)
		var vmax := FS.maxv(rec3.v)
		var m4 := _model(mass)
		m4.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec4 := FS.Rec.new()
		FS.run(m4, int(2.5 * 72), FS.glide(0.0, 1.0), null, rec4)
		var i0 := rec4.at(1.0)
		var rate := absf(FS.mean(rec4.yaw_rate, i0))
		var radius := FS.mean(rec4.v, i0) / maxf(rate, 1e-3)
		var best := -INF
		for p in [0.0, 0.2, 0.4]:
			for tilt in [0.0, 10.0, 20.0, 30.0]:
				var mc := _model(mass)
				mc.trim(Vector3(0, 300, 0), 0.0, 0.0)
				FS.run(mc, 12 * 72, FS.flap(mc, p, 0.0, 1.0, tilt))
				var e0 := FS.energy_height(mc)
				FS.run(mc, 8 * 72, FS.flap(mc, p, 0.0, 1.0, tilt))
				best = maxf(best, (FS.energy_height(mc) - e0) / 8.0)
		var rows := [["cruise", cruise, perf["cruise"]], ["min_speed", vmin, perf["min_speed"]],
			["max_speed", vmax, perf["max_speed"]], ["turn_rate", rate, perf["turn_rate"]], ["climb", best, perf["climb"]]]
		var txt := PackedStringArray()
		for r in rows:
			txt.append("%s %.2f / %.2f = %.3f" % [r[0], r[1], r[2], float(r[1]) / float(r[2])])
			near(float(r[1]) / float(r[2]), 1.0, 0.15, "%.1f kg emergent %s / SizeRules.performance within 15 %% (F7 at the apex)" % [mass, r[0]])
			metric("m%.1f_%s_ratio" % [mass, r[0]], float(r[1]) / float(r[2]))
		_log("[apex envelope] %.1f kg (span %.2f m): %s; full-input radius %.1f m" % [mass, m.params.span, ", ".join(txt), radius])
		if not prev.is_empty():
			gt(cruise, float(prev["cruise"]), "apex cruises faster than the eagle")
			gt(vmax, float(prev["vmax"]), "apex dives faster than the eagle")
			gt(radius, float(prev["radius"]), "apex turns wider than the eagle")
		prev = {"cruise": cruise, "vmax": vmax, "radius": radius}
		# F6 at the apex (FM-19 / FM-20's method).
		var env := FlightEnv.uniform(Vector3(0, 3, 0))
		var mu := _model(mass)
		mu.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var recu := FS.Rec.new()
		FS.run(mu, 30 * 72, FS.glide(0.0), env, recu)
		var climb_u := FS.mean(recu.vy, recu.at(15.0))
		var mt := _model(mass)
		var envt := FlightEnv.new()
		envt.wind_fn = func(pos: Vector3) -> Vector3:
			var r2 := (pos.x * pos.x + pos.z * pos.z) / (44.0 * 44.0)
			return Vector3.ZERO if r2 >= 1.0 else Vector3(0.0, 4.0 * pow(1.0 - r2, 2.0), 0.0)
		var tr := mt.trim_solution(0.6)
		var vt: float = tr["v"]
		var rad := vt * vt / (FS.G * tan(30.0 * DEG))
		mt.trim(Vector3(-rad, 300, 0), 0.0, 0.6)
		var rect := FS.Rec.new()
		FS.run(mt, 60 * 72, FS.glide(0.6, 30.0 * DEG / mt.params.phi_max), envt, rect)
		var climb_t := (rect.y[rect.size() - 1] - rect.y[rect.at(10.0)]) / 50.0
		_log("[apex updraft] %.1f kg: neutral glide in a 3 m/s updraft %+.2f m/s; circling a 4 m/s 44 m bell thermal at 30 deg bank %+.2f m/s (circle radius %.1f m)" % [
			mass, climb_u, climb_t, rad])
		gt(climb_u, 1.0, "%.1f kg: a 3 m/s updraft lifts a neutral glide (FM-19's bound)" % mass)
		gt(climb_t, 0.6, "%.1f kg: circling the 4 m/s bell thermal nets > 0.6 m/s (FM-20's bound)" % mass)


# --- 1b. Apex: ground take-off, landing, low-perch launch --------------------------------

func _land_on_meadow(mass: float) -> FX:
	await _new_fx_mass(mass)
	var p := fx.player
	var vmin := p.model.params.v_min
	var start := Vector3(0, p.model.params.r_body + 0.25, 0)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, -0.2 * vmin, -0.6 * vmin), 0.0)
	fx.run(1.5)
	return fx


func test_r7x_apex_ground_takeoff() -> void:
	var strategies := [[1.0, 45.0, 0.0, "1.0 Hz 45 flat"], [1.3, 45.0, -15.0, "1.3 Hz 45 pitched fwd 15"], [2.0, 60.0, 0.0, "frantic 2 Hz 60"]]
	for mass: float in [3.0, APEX]:
		var best := -INF
		var res := PackedStringArray()
		for s in strategies:
			await _land_on_meadow(mass)
			var p := fx.player
			var span := p.model.params.span
			var landed := p.mode == PlayerBird.Mode.GROUNDED
			var hz: float = s[0]
			var amp: float = s[1]
			var tw: float = float(s[2]) * DEG
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
				for a in b.arms:
					a.twist = tw
			var st := {"t_fly": -1.0, "regr": 0, "prev": p.mode, "max_agl": 0.0}
			var t0 := fx.ticks
			fx.reset_events()
			fx.on_tick = func(i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if float(st["t_fly"]) < 0.0 and pl.mode == PlayerBird.Mode.FLYING:
					st["t_fly"] = (i - t0) * DT
				if pl.mode == PlayerBird.Mode.GROUNDED and st["prev"] != PlayerBird.Mode.GROUNDED:
					st["regr"] = int(st["regr"]) + 1
				st["prev"] = pl.mode
				st["max_agl"] = maxf(float(st["max_agl"]), pl.model.position.y - pl.model.params.r_body)
			fx.run(12.0)
			var agl := p.model.position.y - p.model.params.r_body
			var ok := p.mode == PlayerBird.Mode.FLYING and agl > 2.0 * span
			best = maxf(best, agl / span if p.mode == PlayerBird.Mode.FLYING else -1.0)
			res.append("%s: landed %s, t_fly %.2f s, took_off %d, re-grounded %d, stuns %d, max AGL %.1f spans, end AGL %.1f spans, %s, V %.1f -> %s" % [
				s[3], landed, st["t_fly"], fx.events["took_off"], st["regr"], p.contacts["stun"], float(st["max_agl"]) / span, agl / span,
				p.mode_name(), p.model.airspeed(), "OK" if ok else "STUCK"])
			fx.assert_comfort(self, "%.1f kg ground take-off %s" % [mass, s[3]])
			await _done()
		_log("[ground take-off] %.1f kg | %s" % [mass, " | ".join(res)])
		metric("ground_takeoff_best_end_spans_m%.1f" % mass, best)
		gt(best, 2.0, "%.1f kg: a grounded player who flaps (any of 3 strategies, 12 s) is FLYING >= 2 spans up" % mass)


func test_r7x_apex_low_perch_launch() -> void:
	for mass: float in [3.0, APEX]:
		var span := SizeRules.wingspan_for_mass(mass)
		var hp := 1.5 * span
		await _new_fx_mass(mass, func(w: Variant) -> void:
			w.add_perch(Vector3(0, hp, 0), Vector3.FORWARD, 10.0, 0.05, 2.0))
		var p := fx.player
		p.perch_on(fx.world.get_perches()[0])
		fx.run(0.8)
		var st := {"min_agl": INF, "grounded": false, "t_fly": -1.0}
		var t0 := fx.ticks
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.3)
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			if float(st["t_fly"]) < 0.0 and pl.mode == PlayerBird.Mode.FLYING:
				st["t_fly"] = (i - t0) * DT
			if float(st["t_fly"]) >= 0.0:
				st["min_agl"] = minf(float(st["min_agl"]), pl.model.position.y - pl.model.params.r_body)
			if pl.mode == PlayerBird.Mode.GROUNDED:
				st["grounded"] = true
		fx.run(10.0)
		var end_agl := p.model.position.y - p.model.params.r_body
		_log("[low perch launch] %.1f kg perch %.2f m (1.5 spans): launched at %.2f s, min AGL %.2f m (%.2f spans), grounded %s, stuns %d, end AGL %.1f m (%.1f spans), %s, V %.1f m/s, world_scale %.3f, camera near %.4f" % [
			mass, hp, st["t_fly"], st["min_agl"], float(st["min_agl"]) / span, st["grounded"], p.contacts["stun"], end_agl, end_agl / span,
			p.mode_name(), p.model.airspeed(), p.origin.world_scale, p.camera.near])
		gt(float(st["t_fly"]), -0.5, "%.1f kg: strokes launch from the low perch" % mass)
		check(not st["grounded"], "%.1f kg: a stroke launch from 1.5 spans never lands the bird on the ground" % mass)
		eq(p.contacts["stun"], 0, "%.1f kg: no stun on the low-perch launch" % mass)
		gt(end_agl, hp, "%.1f kg: 10 s of steady strokes end above the perch" % mass)
		# ARCHITECTURE §7.5 allows 0.02-0.05 x world_scale (flight and the VR
		# driver use 0.03; the research note's 0.05 is inside the range).
		between(p.camera.near / p.origin.world_scale, 0.02, 0.05, "%.1f kg: camera near / world_scale in ARCHITECTURE's 0.02-0.05" % mass)
		fx.assert_comfort(self, "%.1f kg low perch launch" % mass)
		await _done()


func test_r7x_apex_meadow_landing() -> void:
	for mass: float in [3.0, APEX]:
		for twist in [0.0, 40.0]:
			await _new_fx_mass(mass)
			var p := fx.player
			var pr := p.model.params
			p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
			var st := {"flare_t": -1.0, "ground_t": -1.0, "rest_t": -1.0, "vmin_air": INF}
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				if twist > 0.0 and float(st["flare_t"]) >= 0.0:
					var k := clampf((t - float(st["flare_t"])) / 0.3, 0.0, 1.0)
					b.arms[0].twist = k * twist * DEG
					b.arms[1].twist = k * twist * DEG
			fx.reset_events()
			fx.on_tick = func(i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if float(st["flare_t"]) < 0.0 and pl.model.position.y - pr.r_body < pr.span:
					st["flare_t"] = fx.src.tick * DT
				if float(st["ground_t"]) < 0.0 and pl.mode == PlayerBird.Mode.GROUNDED:
					st["ground_t"] = i * DT
				if float(st["rest_t"]) < 0.0 and pl.mode == PlayerBird.Mode.GROUNDED and pl.model.velocity.length() < 1e-4:
					st["rest_t"] = i * DT
			var n := 0
			while n < int(40.0 / DT) and (float(st["rest_t"]) < 0.0 or n * DT < float(st["rest_t"]) + 0.5):
				fx.step()
				n += 1
			_log("[meadow landing] %.1f kg %s: stalls %d, stuns %d, grounded %.2f s, at rest %.2f s, end %s" % [
				mass, "neutral glide from 6 spans + 2 m" if twist == 0.0 else "full flare (+40 deg) from 1 span",
				fx.events["stalled"], p.contacts["stun"], st["ground_t"], st["rest_t"], p.mode_name()])
			metric("meadow_rest_s_m%.1f_%s" % [mass, "neutral" if twist == 0.0 else "flare"], st["rest_t"])
			eq(p.contacts["stun"], 0, "%.1f kg %s: landing on the meadow is no stun" % [mass, twist])
			between(float(st["rest_t"]), 0.0, 25.0, "%.1f kg %s: at rest within 25 s" % [mass, twist])
			fx.assert_comfort(self, "%.1f kg meadow landing %s" % [mass, twist])
			await _done()


func test_r7x_apex_bot_course() -> void:
	# BotCourse.setup at a mass (it only takes a species): the same set-up.
	for mass: float in [APEX]:
		fx = FX.new(self)
		var b := BC.new(fx, &"eagle")
		b.course = FlightCourse.new(mass)
		var c := b.course
		await fx.setup(&"eagle", func(w: Variant) -> void:
			c.build(w, false, false))
		var p := fx.player
		p.mass = mass
		p.tick(DT)
		b.pilot = FlightAutopilot.new(p.model.params, c)
		var pl := p
		b.bot = BotPoseSource.new(b.pilot, func() -> Dictionary:
			return {"pos": pl.model.position, "vel": pl.model.velocity, "airspeed": pl.model.airspeed()}, 21)
		b.bot.calibration = p.wing_input.calibration
		b.bot.body.set_seed(21)
		b.bot.rng.seed = 21
		b.bot.set_novice(false)
		p.set_pose_source(b.bot)
		p.start_flying(c.start.origin, 0.0, 0.0)
		b.limit_s = 1.6 * c.length_to_perch() / c.v_c + 10.0
		b.fly()
		var tol := Vector2(c.span - c.r_body, 0.75 * c.span - c.r_body)
		var worst := maxf(absf(b.window_err.x) / tol.x, absf(b.window_err.y) / tol.y) if b.window_crossed else INF
		_log("[apex bot course] %.1f kg (span %.2f m): window crossed %s, error (%.2f, %.2f) m = %.2f of tolerance, stuns %d, slides %d, perched on target %s at %.1f s (limit %.1f s)" % [
			mass, c.span, b.window_crossed, b.window_err.x, b.window_err.y, worst, p.contacts["stun"], p.contacts["slide"],
			b.perched_on_target, b.perched_t, b.limit_s])
		check(b.window_crossed, "%.1f kg: flew through the window" % mass)
		lt(worst, 1.0, "%.1f kg: through the window opening" % mass)
		eq(p.contacts["stun"], 0, "%.1f kg: 0 stuns on the course" % mass)
		check(b.perched_on_target, "%.1f kg: perched on the target branch" % mass)
		check(b.perched_t >= 0.0 and b.perched_t <= b.limit_s, "%.1f kg: perched in time" % mass)
		fx.assert_comfort(self, "%.1f kg bot course" % mass)
		b.plot(Paths.artifacts("flight").path_join("verify/r7x/apex_course.png"))
		b.bot.state_fn = Callable()
		await _done()


# --- 2. Growing on the ground and on a branch ------------------------------------------------

func _meal(old: float) -> float:
	# The biggest prey the bird may eat (EAT_RATIO), its whole meal gain.
	return old + SizeRules.meal_gain(old, old / SizeRules.EAT_RATIO)


func test_r7x_growth_while_grounded_or_perched() -> void:
	for sp: StringName in [&"sparrow", &"pigeon"]:
		var m0 := FlightParams.species_mass(sp)
		for step: Array in [["meal", _meal(m0)], ["x2", 2.0 * m0]]:
			for where in ["ground", "perch"]:
				fx = FX.new(self)
				var span0 := SizeRules.wingspan_for_mass(m0)
				var grip := Vector3(0, 3.0 * span0 + 1.0, 0)
				await fx.setup(sp, func(w: Variant) -> void:
					if where == "perch":
						w.add_perch(grip, Vector3.FORWARD, 10.0, 0.02, 2.0))
				var p := fx.player
				var pr := p.model.params
				if where == "ground":
					var start := Vector3(0, pr.r_body + 0.25 * pr.span, 0)
					p.start_flying(start, 0.0, 0.0)
					p.model.reset(start, Vector3(0, -0.2 * pr.v_min, -0.6 * pr.v_min), 0.0)
					fx.run(3.0)
				else:
					p.perch_on(fx.world.get_perches()[0])
					fx.run(1.0)
				var mode0 := p.mode_name()
				var cam0 := p.camera.global_position
				var ws0 := p.origin.world_scale
				fx.reset_events()
				p.mass = float(step[1])
				var st := {"worst_pen": 0.0, "cam_jump": 0.0, "last": cam0, "ticks": 0}
				fx.on_tick = func(_i: int, f: Variant) -> void:
					var pl: PlayerBird = f.player
					var q := pl.model.params
					st["ticks"] = int(st["ticks"]) + 1
					if int(st["ticks"]) <= 36:
						var c: Vector3 = pl.camera.global_position
						st["cam_jump"] = maxf(float(st["cam_jump"]), (c - (st["last"] as Vector3)).length() / maxf(pl.origin.world_scale, 1e-4))
						st["last"] = c
						var pen := 0.0
						if where == "ground":
							pen = q.r_body - pl.model.position.y
						else:
							# The branch's axis runs along x through grip - 0.02 up.
							var d := Vector2(pl.model.position.y - (grip.y - 0.02), pl.model.position.z - grip.z).length()
							pen = (q.r_body + 0.02) - d
						st["worst_pen"] = maxf(float(st["worst_pen"]), pen)
					if where == "ground":
						st["pen_end"] = q.r_body - pl.model.position.y
				fx.run(3.0)
				var mode1 := p.mode_name()
				var coll: int = fx.events["collided"]
				var pen_mm := float(st["worst_pen"]) * 1000.0
				# Then leave: strokes for 6 s.
				fx.on_tick = Callable()
				fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.3)
				fx.run(6.0)
				var q2 := p.model.params
				var agl := p.model.position.y - q2.r_body
				var left := p.mode == PlayerBird.Mode.FLYING and agl > (grip.y if where == "perch" else 0.0) + q2.span
				var tag := "%s %s growth %.3f -> %.3f kg on the %s" % [sp, step[0], m0, float(step[1]), where]
				_log("[growth] %s: mode %s -> %s, world_scale %.3f -> %.3f, body r %.4f m; worst penetration %.2f mm (3 s later %.2f mm), camera jump %.1f cm perceived (worst tick), collided events %d, stuns %d; after 6 s of strokes %s AGL %.2f m -> %s" % [
					tag, mode0, mode1, ws0, p.origin.world_scale, q2.r_body, pen_mm, float(st.get("pen_end", 0.0)) * 1000.0, float(st["cam_jump"]) * 100.0, coll,
					p.contacts["stun"], p.mode_name(), agl, "LEFT" if left else "STUCK"])
				eq(mode1, mode0, "%s: growing does not change the mode" % tag)
				eq(coll, 0, "%s: growing is no collision" % tag)
				lt(pen_mm, 1.0, "%s: the bigger body is not inside the ground / branch (mm)" % tag)
				check(left, "%s: strokes then leave the %s" % [tag, where])
				fx.assert_comfort(self, tag)
				await _done()


# --- 3. The arena's lid ----------------------------------------------------------------------

func test_r7x_ceiling_lid() -> void:
	var ceil_y := 80.0
	# [species, frantic flapping, circling roll, pitch]
	var cases := [[&"sparrow", true, 0.3, 0.2], [&"sparrow", false, 0.0, 0.6], [&"pigeon", true, 0.3, 0.2], [&"eagle", false, 0.0, 0.6]]
	for c in cases:
		var sp: StringName = c[0]
		var flap: bool = c[1]
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.thermal_core = 4.0
			w.thermal_center = Vector3.ZERO
			w.thermal_radius = 60.0
			# The world's lid: a 10 m slab whose underside is the ceiling.
			FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
		fx.world.ceiling = ceil_y
		var p := fx.player
		var pr := p.model.params
		var cal := p.wing_input.calibration
		var roll: float = c[2]
		var pitch: float = c[3]
		# Circling at 30 deg bank inside the thermal (radius from the trim).
		var tr := p.model.trim_solution(pitch)
		var v: float = tr["v"]
		var rad := minf(v * v / (9.81 * tan(30.0 * DEG)), 40.0)
		p.start_flying(Vector3(-rad, ceil_y - 30.0, 0), 0.0, 0.0)
		var roll_cmd := roll if flap else 30.0 * DEG / pr.phi_max
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.synth(pitch, roll_cmd, 1.0, cal)
			if flap:
				ScriptedPoseSource.flap(b, t + 0.5, 60.0, 2.0)
		var st := {"top": -INF, "t_top": 0.0}
		fx.reset_events()
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var top := pl.model.position.y + pl.model.params.r_body
			if top > float(st["top"]):
				st["top"] = top
				st["t_top"] = i * DT
		fx.run(60.0)
		var gap := ceil_y - float(st["top"])
		var nc: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"] + p.contacts["brush"]
		var tag := "%s %s" % [sp, "frantic 2 Hz 60 strokes, circling in a 4 m/s thermal" if flap else "circling a 4 m/s thermal at 30 deg, no flapping"]
		_log("[ceiling] %s: highest point %.2f m below the %.0f m lid (at %.1f s), lid contacts %d (slide %d, stun %d), collided events %d, end y %.1f, mode %s" % [
			tag, gap, ceil_y, st["t_top"], nc, p.contacts["slide"], p.contacts["stun"], fx.events["collided"], p.model.position.y, p.mode_name()])
		metric("ceiling_gap_%s_%s" % [sp, "flap" if flap else "soar"], gap)
		eq(p.contacts["stun"], 0, "%s: the invisible lid never stuns" % tag)
		eq(nc, 0, "%s: the thin-air fade keeps the bird off the invisible lid (no contact)" % tag)
		await _done()


# --- 4. Seated-feasible ways off a hillside ---------------------------------------------------

func _slope_setup(deg: float) -> Callable:
	return func(w: Variant) -> void:
		var th := deg * DEG
		var bb := Basis(Vector3.RIGHT, th)
		var n := bb * Vector3.UP
		FlightGeometry.box(w, Vector3(0, H0, 0) - n * 0.5, Vector3(400, 1.0, 900), FlightGeometry.C_WALL, false,
			FlightGeometry.LAYER_WORLD, bb, "Slope")


static func _surf_y(deg: float, z: float) -> float:
	return H0 - z * tan(deg * DEG)


func _clearance(p: PlayerBird, deg: float) -> float:
	var pos := p.model.position
	return minf((pos.y - _surf_y(deg, pos.z)) * cos(deg * DEG) - p.model.params.r_body, pos.y - p.model.params.r_body)


func test_r7x_hillside_seated_escapes() -> void:
	# [label, roll during the first 2.5 s of strokes, torso twist deg]
	var strategies := [["straight", 0.0, 0.0], ["bank away 0.7", 0.7, 0.0], ["torso 45 then strokes", 0.0, 45.0], ["torso 45 + bank 0.7", 0.7, 45.0]]
	for sp: StringName in [&"pigeon", &"eagle"]:
		for deg: float in [15.0, 20.0, 30.0]:
			var res := PackedStringArray()
			var seated_ok := false
			for s in strategies:
				fx = FX.new(self)
				await fx.setup(sp, _slope_setup(deg))
				var p := fx.player
				var pr := p.model.params
				var z0 := -2.0 * pr.span
				var start := Vector3(0, _surf_y(deg, z0) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
				p.start_flying(start, 0.0, 0.0)
				p.model.reset(start, Vector3(0, -0.2, -0.3) * pr.v_min, 0.0)
				fx.run(2.0)
				var landed := p.mode == PlayerBird.Mode.GROUNDED
				var cal := p.wing_input.calibration
				var roll: float = s[1]
				var tw: float = float(s[2]) * DEG
				var t0 := fx.src.tick * DT
				fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
					var u := t - t0
					b.set_airplane()
					b.torso_yaw = clampf(u / 1.0, 0.0, 1.0) * tw
					var su := u - (1.2 if tw > 0.0 else 0.0)
					if roll > 0.0:
						b.synth(0.0, roll if su < 2.5 else 0.0, 1.0, cal)
					if su >= 0.0:
						ScriptedPoseSource.flap(b, su + 0.5, 45.0, 1.3)
				var st := {"t_clear": -1.0}
				var i0 := fx.ticks
				fx.reset_events()
				fx.on_tick = func(i: int, f: Variant) -> void:
					var pl: PlayerBird = f.player
					if float(st["t_clear"]) < 0.0 and pl.mode == PlayerBird.Mode.FLYING and _clearance(pl, deg) > 2.0 * pr.span:
						st["t_clear"] = (i - i0) * DT
				fx.run(10.0)
				var ok := p.mode == PlayerBird.Mode.FLYING and _clearance(p, deg) > 2.0 * pr.span
				if s[0] != "straight" and ok:
					seated_ok = true
				res.append("%s: landed %s, took_off %d, perched %d, stuns %d, 2 spans clear at %.1f s, end %s %.1f spans -> %s" % [
					s[0], landed, fx.events["took_off"], fx.events["perched"], p.contacts["stun"], st["t_clear"], p.mode_name(),
					_clearance(p, deg) / pr.span, "OK" if ok else "STUCK"])
				await _done()
			_log("[hillside] %s facing up %.0f deg | %s" % [sp, deg, " | ".join(res)])
			check(seated_ok, "%s facing up a %.0f deg hillside: a seated-feasible escape (banking away or a 45 deg torso twist) leaves it within 10 s" % [sp, deg])


## Diagnostic: plain sustained climbing (no thermal) under the lid, and every
## lid contact's impact speed. Reported, and the stun asserted.
func test_r7x_ceiling_lid_climb_diag() -> void:
	var ceil_y := 80.0
	for c in [[&"sparrow", 1.3, 45.0, 0.0], [&"sparrow", 1.0, 40.0, 0.0], [&"sparrow", 2.0, 60.0, 0.0], [&"starling", 1.3, 45.0, 0.0],
			[&"sparrow", 1.3, 45.0, 0.5], [&"pigeon", 1.3, 45.0, 0.0], [&"eagle", 1.3, 45.0, 0.0]]:
		var sp: StringName = c[0]
		var hz: float = c[1]
		var amp: float = c[2]
		var roll: float = c[3]
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
		fx.world.ceiling = ceil_y
		var p := fx.player
		var cal := p.wing_input.calibration
		p.start_flying(Vector3(0, ceil_y - 40.0, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if roll != 0.0:
				b.synth(0.0, roll, 1.0, cal)
			ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
		var st := {"top": -INF, "t_reach": -1.0, "at_lid": 0, "vy_max": 0.0}
		fx.reset_events()
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var top := pl.model.position.y + pl.model.params.r_body
			st["top"] = maxf(float(st["top"]), top)
			st["vy_max"] = maxf(float(st["vy_max"]), pl.model.velocity.y)
			if top > ceil_y - 0.02:
				st["at_lid"] = int(st["at_lid"]) + 1
				if float(st["t_reach"]) < 0.0:
					st["t_reach"] = i * DT
		fx.run(40.0)
		var imps := PackedStringArray()
		for k in mini(fx.collide_impacts.size(), 6):
			imps.append("%.2f" % fx.collide_impacts[k])
		var tag := "%s %.1f Hz %.0f deg strokes%s, no thermal" % [sp, hz, amp, (", roll %.1f" % roll) if roll != 0.0 else ""]
		_log("[ceiling diag] %s: reached the lid at %.1f s, %.1f s pressed against it, lid contacts slide %d / silent %d / stun %d, collided events %d (impacts %s m/s), max climb %.2f m/s, v_stun %.2f m/s" % [
			tag, st["t_reach"], int(st["at_lid"]) * DT, p.contacts["slide"], p.contacts["silent"], p.contacts["stun"], fx.events["collided"],
			", ".join(imps), st["vy_max"], maxf(0.35 * p.model.params.v_c, 2.0)])
		eq(p.contacts["stun"], 0, "%s: climbing under the invisible lid never stuns" % tag)
		await _done()


## Evidence plot: height under the lid and vertical speed for reference
## strokes (1.3 Hz, 45 deg), with every stun marked.
func test_r7x_zz_ceiling_plot() -> void:
	var ceil_y := 80.0
	var pl := FlightPlot.new(1600, 900, "Verifier r7x: flapping under the arena's invisible lid (World.ceiling)")
	pl.note("Reference strokes (1.3 Hz, 45 deg) from 40 m below a lid slab whose underside is World.ceiling (as soaring_world._build_boundary builds it). FlightEnv.lift_scale fades lift and drag over the last 20 m, but not the flap force, so the fade never stops a flapping bird: every size reaches the lid about 9 s after starting to climb, bounces off it again and again (collided events), and the sparrow and pigeon are stunned (dots) on most hits.")
	var W := 720
	var H := 320
	var p1 := pl.panel(Rect2i(60, 180, W, H), "Top of the body - ceiling (m)", "t (s)", "m")
	var p2 := pl.panel(Rect2i(60 + W + 80, 180, W, H), "Vertical speed (m/s)", "t (s)", "m/s")
	var slot := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
		fx.world.ceiling = ceil_y
		var p := fx.player
		p.start_flying(Vector3(0, ceil_y - 40.0, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.3)
		var ts := PackedFloat64Array()
		var ys := PackedFloat64Array()
		var vs := PackedFloat64Array()
		var sx := PackedFloat64Array()
		var sy := PackedFloat64Array()
		var st := {"prev": p.mode}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var q: PlayerBird = f.player
			ts.append(i * DT)
			ys.append(q.model.position.y + q.model.params.r_body - ceil_y)
			vs.append(q.model.velocity.y)
			if q.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
				sx.append(i * DT)
				sy.append(q.model.position.y + q.model.params.r_body - ceil_y)
			st["prev"] = q.mode
		fx.run(40.0)
		p1.line(ts, ys, slot, "%s (stuns %d, collided %d)" % [sp, p.contacts["stun"], fx.events["collided"]])
		if sx.size() > 0:
			p1.points(sx, sy, slot)
		p2.line(ts, vs, slot, sp)
		slot += 1
		await _done()
	p1.hline(0.0, FlightPlot.AXIS, "lid (World.ceiling)")
	p1.hline(-20.0, FlightPlot.AXIS, "fade starts (ceiling - 20 m)")
	var path := Paths.artifacts("flight").path_join("verify/r7x/r7x_ceiling_lid.png")
	eq(pl.save(path), OK, "plot saved")
	_log("plot: " + path)
