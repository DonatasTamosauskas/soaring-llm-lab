extends TestCase
## Ground landing (fix round 5; FLIGHT_SPEC §10.2, §19 R5-1...R5-4), F10:
## gliding into a meadow, flaring and touching down, the run-out on the
## feet, and the stall guard near the ground. Round 4 let a bird below stall
## speed slide along the grass "flying" for 7-15 s, stopped a touchdown in
## one tick (0.6-1.0 x the touchdown speed), and a full flare near the
## ground stunned a sparrow from every height tried.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
const S3: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


## Round-5 tuning fields and model members are read by name (with their
## round-5 defaults) so that the old-code check (tests/shots/
## flight_r5_oldcode_check.py) runs these tests on the round-4 sources and
## they fail on behaviour, not on a missing name.
static func _tun(t: FlightTuning, key: String, dflt: float) -> float:
	var v: Variant = t.get(key)
	return float(v) if v != null else dflt


## The stall guard height (FlightModel._t_guard_h in round 5).
static func _guard_h(m: FlightModel) -> float:
	var v: Variant = m.get("_t_guard_h")
	if v != null:
		return float(v)
	var tf := m.tuning.forced_recovery
	return 0.4 * FlightMath.G * tf * tf + 0.25 * m.params.v_min * m.params.v_min / FlightMath.G


## The camera's offset from the body (by name for the round-6 old-code
## check: round 5 had the vertical heave only).
static func _view_off(p: PlayerBird) -> Vector3:
	return p.call(&"view_offset") if p.has_method(&"view_offset") else Vector3.UP * p.heave_offset()


func _fx(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, world_setup)
	return fx


func _done() -> void:
	# The fixture frees its nodes at once: no frame to wait for (fix round 6:
	# ~7 ms of wall time per fixture).
	fx.teardown()
	fx = null


## Per-tick camera velocity change (m/s) over a run, and the lowest camera
## height above the ground (m). The camera, not the body: what the eye sees.
func _cam_monitor(st: Dictionary) -> Callable:
	return func(_i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var c := pl.camera.global_position
		if st.has("last"):
			var v: Vector3 = (c - st["last"]) / DT
			if st.has("lastv"):
				st["worst_dv"] = maxf(st.get("worst_dv", 0.0), (v - st["lastv"]).length())
			st["lastv"] = v
		st["last"] = c
		st["cam_min_y"] = minf(st.get("cam_min_y", INF), c.y)


# --- G1: a touchdown eases in, on the flat and on slopes ------------------------------------
## The feet meet the ground first (they reach leg_reach body radii beyond
## the body, fix round 6) and the legs take the speed into the surface along
## its normal, over the reach plus at most leg_flex body radii of bend; the
## speed along it runs out on the feet. The view's per-tick velocity change
## stays within the perch capture's P9 bound, 0.45 x the touchdown speed
## (round 4: 0.98 / 0.58 / 0.90 on the flat; round 5, flat only: 0.32 on
## the flat, 0.54-0.85 on 15-44 deg upslopes and a stun on a 38 deg roof).
## Two approaches (the verifier's): PB-11's slow sinking one (0.6 V_min
## forward, 0.2 down, 0.25 m out) and a flared one (1.1 V_min, 0.15 down,
## 0.1 m out), onto the flat, 10 / 20 / 38 / 44 deg upslopes (village roofs
## are 34-44 deg), across a 38 deg roof and down a 10 deg slope.
const H0 := 30.0


static func _slope_setup(deg: float) -> Callable:
	return func(w: Variant) -> void:
		FlightGeometry.slope(w, Vector3(0, H0, 0), deg, Vector2(120.0, 900.0), FlightGeometry.C_GROUND, false)


static func _surf_y(deg: float, z: float) -> float:
	return H0 - z * tan(deg * DEG)


## One touchdown: `deg` slope (+ = rising ahead), heading `yaw_deg` off the
## fall line, forward `vf` and sink `vs` (x V_min), from `gap` m above.
func _touchdown(sp: StringName, deg: float, yaw_deg: float, vf: float, vs: float, gap: float) -> Dictionary:
	await _fx(sp, _slope_setup(deg))
	var p := fx.player
	var pr := p.model.params
	var n := FlightGeometry.slope_normal(deg)
	var z0 := -2.0 * pr.span
	var start := Vector3(0, _surf_y(deg, z0) + (pr.r_body + gap) / cos(deg * DEG), z0)
	var yaw := yaw_deg * DEG
	p.start_flying(start, yaw, 0.0)
	var v0 := FlightMath.yaw_forward(yaw) * vf * pr.v_min + Vector3.DOWN * vs * pr.v_min
	p.model.reset(start, v0, yaw)
	var st := {"last": p.camera.global_position, "lastv": v0, "td": -1, "rest": -1, "eye": INF, "worst_dv": 0.0}
	var mon := _cam_monitor(st)
	fx.on_tick = func(i: int, f: Variant) -> void:
		mon.call(i, f)
		var pl: PlayerBird = f.player
		st["eye"] = minf(st["eye"], (pl.camera.global_position - Vector3(0, H0, 0)).dot(n))
		if int(st["td"]) < 0 and pl.mode == PlayerBird.Mode.GROUNDED:
			st["td"] = i
		if int(st["td"]) >= 0 and int(st["rest"]) < 0 and i > int(st["td"]) and _view_off(pl).length() < 1e-6:
			st["rest"] = i
	fx.run(1.5)
	var out := {"ratio": float(st["worst_dv"]) / v0.length(), "landed": int(st["td"]) >= 0, "stuns": p.contacts["stun"],
		"eye": float(st["eye"]), "r": pr.r_body, "legs_s": (int(st["rest"]) - int(st["td"])) * DT if int(st["rest"]) >= 0 else INF,
		"perceived": float(st["worst_dv"]) / maxf(p.origin.world_scale, 1e-4)}
	await _done()
	return out


func test_g1_touchdown_eases_in_on_flat_ground_and_slopes() -> void:
	var flex := _tun(FlightTuning.default_tuning(), "leg_flex", 0.75)
	# [slope deg, heading off the fall line deg]
	var cases := [[0.0, 0.0], [10.0, 0.0], [20.0, 0.0], [38.0, 0.0], [44.0, 0.0], [38.0, 60.0], [-10.0, 0.0]]
	var approaches := [[0.6, 0.2, 0.25, "PB-11"], [1.1, 0.15, 0.1, "flared"]]
	var worst := {}
	for sp in S3:
		worst[sp] = 0.0
		for c in cases:
			for a in approaches:
				var r: Dictionary = await _touchdown(sp, c[0], c[1], a[0], a[1], a[2])
				var tag := "%s %+.0f deg (%.0f deg across) %s" % [sp, c[0], c[1], a[3]]
				eq(r["stuns"], 0, "%s: a touchdown at landing speed is no stun" % tag)
				lt(float(r["ratio"]), 0.45, "%s: per-tick view velocity change <= 0.45 x the touchdown speed (P9's bound; round 5 0.54-0.85 on upslopes)" % tag)
				if float(c[0]) >= 0.0:
					check(bool(r["landed"]), "%s: lands" % tag)
				if bool(r["landed"]):
					gt(float(r["eye"]), 0.9 * (1.0 - flex) * float(r["r"]), "%s: the eye never nears the surface (m)" % tag)
					between(float(r["legs_s"]), 0.0, 0.6, "%s: the legs are at rest within 0.6 s (s)" % tag)
				worst[sp] = maxf(worst[sp], r["ratio"])
				metric(tag.replace(" ", "_"), r["ratio"])
	metric("worst_ratio", worst)


## The touchdown envelope on the flat (the round-6 engineering verifier's
## grid): forward 0.4-1.0 V_min, sinking 0.3-0.7 V_min, from just outside
## the feet's reach. Every one ends on the ground, none a stun; every
## touchdown within 0.45 (round 5: 8 of 84 over, up to 0.70 for a sparrow
## sinking at 0.7 V_min). Forward 1.0 sinking 0.7 is 1.22 V_min, above the
## touchdown speed: a skid on the belly first (a hard one stops the view
## with the body, round 5's 0.46 x; the fixture's rule that the view never
## jolts more than the body holds for it). The legs stand back up at no more
## than 2 g. Default: the sparrow's grid; at the pigeon and eagle the steepest
## touchdown and the skid; --full: the grid at three sizes.
func test_g1b_steep_touchdowns_on_the_flat() -> void:
	var reach := _tun(FlightTuning.default_tuning(), "leg_reach", 1.0)
	var full := Paths.arg("full", "") != ""
	for sp in S3:
		for down: float in ([0.3, 0.5, 0.7] if full or sp == &"sparrow" else [0.7]):
			# Pigeon and eagle by default: the steepest touchdown (0.4) and the skid
			# above the touchdown speed that the legs take, then the touchdown (1.0).
			for fwd: float in ([0.4, 0.7, 1.0] if full or sp == &"sparrow" else [0.4, 1.0]):
				await _fx(sp)
				var p := fx.player
				var pr := p.model.params
				var start := Vector3(0, pr.r_body * (1.0 + reach) + 0.2 * pr.r_body, 0)
				p.start_flying(start, 0.0, 0.0)
				var v0 := Vector3(0, -down * pr.v_min, -fwd * pr.v_min)
				p.model.reset(start, v0, 0.0)
				var st := {"last": p.camera.global_position, "lastv": v0, "up": 0.0, "off": NAN}
				var mon := _cam_monitor(st)
				fx.on_tick = func(i: int, f: Variant) -> void:
					mon.call(i, f)
					# The legs standing back up: the camera's rise over the body.
					var pl: PlayerBird = f.player
					var o := _view_off(pl).y
					if pl.mode == PlayerBird.Mode.GROUNDED and is_finite(float(st["off"])):
						st["up"] = maxf(st["up"], (o - float(st["off"])) / DT)
					st["off"] = o if pl.mode == PlayerBird.Mode.GROUNDED else NAN
				fx.run(1.0)
				var tag := "%s forward %.1f sinking %.1f V_min" % [sp, fwd, down]
				eq(p.contacts["stun"], 0, "%s: no stun" % tag)
				eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: on the ground" % tag)
				# A touchdown, or a skid the legs can spread over two ticks or more
				# (its speed into the ground x dt within their flex): <= 0.45.
				var flex0 := _tun(p.tuning, "leg_flex", 0.75)
				var landing := v0.length() <= _tun(p.tuning, "touchdown_speed", 1.2) * pr.v_min + 1e-6
				if landing or down * pr.v_min * DT <= flex0 * pr.r_body:
					lt(float(st["worst_dv"]) / v0.length(), 0.45, "%s: %s: per-tick view velocity change <= 0.45 x its speed" % [
						tag, "a touchdown" if landing else "a skid the legs take"])
				# Every case (a skid above the touchdown speed too): the view never
				# jolts more than the body (the fixture's comfort rule).
				fx.assert_comfort(self, tag)
				# The stand back up is at <= 2 g: from the deepest bend (leg_flex
				# body radii) that peaks at sqrt(2 g flex r_body) (round 5 stood up
				# at the bend's own deceleration, up to 15 g: 2 m/s for a sparrow).
				var flex := _tun(p.tuning, "leg_flex", 0.75)
				lt(float(st["up"]), 1.05 * sqrt(2.0 * FlightMath.G * flex * pr.r_body) + 0.01, "%s: the legs stand back up at <= 2 g (m/s)" % tag)
				metric(tag.replace(" ", "_"), float(st["worst_dv"]) / v0.length())
				await _done()


# --- G1c: a dive into the ground at flying speed ----------------------------------------
## A sparrow trimmed nose-down (pitch -0.4, wrists -22 deg) from 6 spans +
## 2 m dives into the meadow at flying speed: a belly skid, not a touchdown.
## The fixture's comfort rule holds through it: the view's vertical jerk
## never exceeds 1.1 x the body's (the round-5 experience verifier's ground
## glide; round 6's first skid legs broke it: a hard skid's bend, split
## unevenly across the tick boundary, read as more jerk than the body's
## own stop).
func test_g1c_dive_into_the_ground_never_jolts_the_view_more_than_the_body() -> void:
	await _fx(&"sparrow")
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, -0.4)
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].twist = -22.0 * DEG
		b.arms[1].twist = -22.0 * DEG
	fx.run(3.0)
	gt(p.contacts["slide"] + p.contacts["land"], 0, "met the ground")
	fx.assert_comfort(self, "sparrow dive into the ground")
	metric("jerk_cm", {"cam": fx.comfort["cam_jerk"], "body": fx.comfort["body_jerk"]})


# --- G2: a neutral glide into a meadow comes to rest -----------------------------------------
## Arms spread and still from 6 spans + 2 m. The cushion and ground effect
## still skim the bird along (PB-15), but a wing at or below the touchdown
## speed (1.2 V_min) with its belly on the grass has landed: never "flying"
## along the grass below V_min, no stun, at rest within 20 s (round 4: 3.3,
## 7.3 and 15.1 s below V_min on the grass; rest after 9.7, 21.8 and 45 s).
func test_g2_neutral_glide_comes_to_rest() -> void:
	for sp in S3:
		await _fx(sp)
		var p := fx.player
		var pr := p.model.params
		p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
		var st := {"skim": 0.0, "worst_skim": 0.0, "ground_t": -1.0, "rest_t": -1.0}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var belly: float = pl.model.position.y - pr.r_body
			if pl.mode == PlayerBird.Mode.FLYING and belly < 0.02 and pl.model.airspeed() < pr.v_min:
				st["skim"] += DT
				st["worst_skim"] = maxf(st["worst_skim"], st["skim"])
			else:
				st["skim"] = 0.0
			if float(st["ground_t"]) < 0.0 and pl.mode == PlayerBird.Mode.GROUNDED:
				st["ground_t"] = i * DT
			if float(st["rest_t"]) < 0.0 and pl.mode == PlayerBird.Mode.GROUNDED and pl.model.velocity.length() < 1e-4:
				st["rest_t"] = i * DT
		# Until at rest (and 0.5 s more), at most 20 s.
		var n := 0
		while n < int(20.0 / DT) and (float(st["rest_t"]) < 0.0 or n * DT < float(st["rest_t"]) + 0.5):
			fx.step()
			n += 1
		eq(p.contacts["stun"], 0, "%s: a glide into a meadow is not a stun" % sp)
		lt(float(st["worst_skim"]), 0.1, "%s: never 'flying' on the grass below V_min (s; round 4 3.3-15.1)" % sp)
		between(float(st["rest_t"]), 0.0, 20.0, "%s: at rest on the ground within 20 s (s; round 4 9.7-45)" % sp)
		metric("%s_grounded_s" % sp, st["ground_t"])
		metric("%s_rest_s" % sp, st["rest_t"])
		await _done()


# --- G3: the run-out ---------------------------------------------------------------------------
## A touchdown at 1.0 V_min runs out on the feet at mu g: the distance is
## v^2 / (2 mu g) within 3 %, and each tick's deceleration is mu g (the view
## eases to rest). Off an edge the bird flies on with the same velocity; into
## a wall at 45 deg the run turns along it (never through it, no stun); and
## a take-off during the run-out keeps its speed.
func _touch(sp: StringName, dir: Vector3, world_setup: Callable = Callable(), base := 0.0) -> Dictionary:
	await _fx(sp, world_setup)
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, base + pr.r_body + 0.02, 0)
	p.start_flying(start, FlightMath.yaw_of(dir), 0.0)
	p.model.reset(start, dir.normalized() * pr.v_min + Vector3.DOWN * 0.05 * pr.v_min, FlightMath.yaw_of(dir))
	return {"p": p, "pr": pr}


func test_g3_run_out_distance_and_smoothness() -> void:
	for sp in S3:
		var r: Dictionary = await _touch(sp, Vector3.FORWARD)
		var p: PlayerBird = r["p"]
		var pr: FlightParams = r["pr"]
		var mu := _tun(p.tuning, "ground_friction", 0.6)
		var st := {"td_pos": Vector3.INF, "v_td": 0.0, "rest_pos": Vector3.INF, "worst_dec": 0.0, "prev_v": -1.0, "t_after": 0}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			if pl.mode != PlayerBird.Mode.GROUNDED:
				return
			var hv := Vector2(pl.model.velocity.x, pl.model.velocity.z).length()
			if st["td_pos"] == Vector3.INF:
				st["td_pos"] = pl.model.position
				st["v_td"] = hv
			elif float(st["prev_v"]) > 0.0:
				st["worst_dec"] = maxf(st["worst_dec"], (float(st["prev_v"]) - hv) / DT)
			st["prev_v"] = hv
			if hv < 1e-6 and st["rest_pos"] == Vector3.INF:
				st["rest_pos"] = pl.model.position
		fx.run(3.5)
		var v_td: float = st["v_td"]
		var d := Vector2((st["rest_pos"] - st["td_pos"]).x, (st["rest_pos"] - st["td_pos"]).z).length() if st["rest_pos"] != Vector3.INF else INF
		var d_exp := v_td * v_td / (2.0 * mu * FlightMath.G)
		eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: lands" % sp)
		between(v_td / pr.v_min, 0.9, 1.2, "%s: touched down at about V_min (x V_min)" % sp)
		between(d / d_exp, 0.97, 1.03, "%s: run-out distance = v^2 / (2 mu g) within 3 %% (%.2f m)" % [sp, d_exp])
		lt(float(st["worst_dec"]), mu * FlightMath.G * 1.001 + 1e-3, "%s: the run-out decelerates at mu g, no faster (m/s^2)" % sp)
		metric("%s_run_out_m" % sp, d)
		metric("%s_run_out_spans" % sp, d / pr.span)
		await _done()


func test_g3b_run_out_off_an_edge_and_into_a_wall() -> void:
	for sp in S3:
		# Off an edge: a 10 m high platform ending half the run-out ahead.
		var pr0 := FlightParams.derive(FlightParams.species_mass(sp), FlightTuning.default_tuning())
		var d_exp := pr0.v_min * pr0.v_min / (2.0 * _tun(FlightTuning.default_tuning(), "ground_friction", 0.6) * FlightMath.G)
		var edge_z := -0.5 * d_exp
		var r: Dictionary = await _touch(sp, Vector3.FORWARD, func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 9.5, edge_z + 5.0), Vector3(20, 1.0, 10.0)), 10.0)
		var p: PlayerBird = r["p"]
		var st := {"grounded": false, "off": false, "v_off": 0.0, "v_run": 0.0, "worst_dv": 0.0, "lastv": Vector3.INF}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			if pl.mode == PlayerBird.Mode.GROUNDED:
				st["grounded"] = true
				st["v_run"] = Vector2(pl.model.velocity.x, pl.model.velocity.z).length()
			elif bool(st["grounded"]) and not bool(st["off"]) and pl.mode == PlayerBird.Mode.FLYING:
				st["off"] = true
				st["v_off"] = Vector2(pl.model.velocity.x, pl.model.velocity.z).length()
			if bool(st["grounded"]):
				var v: Vector3 = pl.model.velocity
				if st["lastv"] != Vector3.INF:
					st["worst_dv"] = maxf(st["worst_dv"], (v - st["lastv"]).length())
				st["lastv"] = v
		fx.run(1.5)
		check(bool(st["grounded"]), "%s: touched down on the platform" % sp)
		check(bool(st["off"]), "%s: ran off the edge and is flying again" % sp)
		near(float(st["v_off"]), float(st["v_run"]), 0.05 * float(st["v_run"]) + 0.02, "%s: leaves the edge at its running speed (m/s)" % sp)
		lt(float(st["worst_dv"]), 0.3 * pr0.v_min, "%s: no velocity step at the edge (m/s per tick)" % sp)
		eq(p.contacts["stun"], 0, "%s: no stun" % sp)
		await _done()
		# Into a wall at 45 deg: the run turns along it.
		var dir := Vector3(0.7071, 0, -0.7071)
		var wall_z := -0.4 * d_exp * 0.7071
		r = await _touch(sp, dir, func(w: Variant) -> void:
			w.add_wall(Vector3(0, 1.0, wall_z - 0.5), Vector3(60, 2.0, 1.0)))
		p = r["p"]
		var pr: FlightParams = r["pr"]
		var st2 := {"min_gap": INF, "x_at_wall": INF}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			st2["min_gap"] = minf(st2["min_gap"], pl.model.position.z - wall_z)
		fx.run(2.5)
		var gap: float = st2["min_gap"]
		gt(gap, pr.r_body - 0.002, "%s: never through the wall (gap %.3f m)" % [sp, gap])
		lt(gap, pr.r_body + 0.01, "%s: the run reached the wall" % sp)
		eq(p.contacts["stun"], 0, "%s: a run into a wall at 45 deg is no stun" % sp)
		gt(p.model.position.x, 0.3 * d_exp, "%s: the run carried on along the wall past where it met it (m)" % sp)
		eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: at rest on the ground by the wall" % sp)
		await _done()


func test_g3c_takeoff_during_the_run_out_keeps_its_speed() -> void:
	await _touch(&"sparrow", Vector3.FORWARD)
	var p := fx.player
	var pr := p.model.params
	var k := 0
	while p.mode != PlayerBird.Mode.GROUNDED and k < 72:
		fx.step()
		k += 1
	eq(p.mode, PlayerBird.Mode.GROUNDED, "touched down")
	var st := {"v_before": 0.0, "v_after": -1.0}
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.5, 45.0, 2.0)
	fx.on_tick = func(_i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if pl.mode == PlayerBird.Mode.GROUNDED:
			st["v_before"] = -pl.model.velocity.z
		elif float(st["v_after"]) < 0.0 and pl.mode == PlayerBird.Mode.FLYING:
			st["v_after"] = -pl.model.velocity.z
	fx.run(1.5)
	gt(float(st["v_after"]), 0.0, "took off")
	gt(float(st["v_after"]), maxf(0.6 * pr.v_min, float(st["v_before"])) - 0.2, "the launch keeps the run's forward speed (m/s)")
	metric("run_before_launch", st["v_before"])
	metric("forward_after_launch", st["v_after"])


# --- G3d: the run-out along a slope ----------------------------------------------------------
## A touchdown at 1.0 V_min on a slope runs out along the slope's plane
## (never into it or off it: the body stays at its resting distance, the
## run has no speed across the plane) and decelerates at mu g cos(slope)
## plus gravity along the run, at least run_brake_min x mu g: the distance
## is v^2 / 2a within 3 %. Round 5 ran level with a 0.3 body-radius step-up:
## facing up any slope steeper than ~11 deg (sparrow) the slope stopped the
## run in one tick.
func test_g3d_run_out_along_a_slope() -> void:
	var tu := FlightTuning.default_tuning()
	var mu := _tun(tu, "ground_friction", 0.6)
	var brake_min := _tun(tu, "run_brake_min", 0.5)
	var full := Paths.arg("full", "") != ""
	# [slope deg, heading off the fall line deg, sink x V_min]
	var cases := [[20.0, 0.0, 0.05], [38.0, 0.0, 0.05], [-20.0, 0.0, 0.5], [38.0, 60.0, 0.05]]
	for sp in (S3 if full else [&"pigeon"] as Array[StringName]):
		for c in cases:
			var deg: float = c[0]
			await _fx(sp, _slope_setup(deg))
			var p := fx.player
			var pr := p.model.params
			var n := FlightGeometry.slope_normal(deg)
			var yaw := float(c[1]) * DEG
			var z0 := 2.0 * pr.span
			var start := Vector3(0, _surf_y(deg, z0) + (pr.r_body + 0.02) / cos(deg * DEG), z0)
			p.start_flying(start, yaw, 0.0)
			p.model.reset(start, FlightMath.yaw_forward(yaw) * pr.v_min + Vector3.DOWN * float(c[2]) * pr.v_min, yaw)
			var st := {"td_pos": Vector3.INF, "v_td": Vector3.ZERO, "rest_pos": Vector3.INF, "gap_err": 0.0, "vn": 0.0, "worst_dec": 0.0, "prev": -1.0}
			fx.on_tick = func(_i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if pl.mode != PlayerBird.Mode.GROUNDED:
					return
				var v: Vector3 = pl.model.velocity
				if st["td_pos"] == Vector3.INF:
					st["td_pos"] = pl.model.position
					st["v_td"] = v
				elif float(st["prev"]) > 0.0:
					st["worst_dec"] = maxf(st["worst_dec"], (float(st["prev"]) - v.length()) / DT)
				st["prev"] = v.length()
				st["gap_err"] = maxf(st["gap_err"], absf((pl.model.position - Vector3(0, H0, 0)).dot(n) - pr.r_body))
				st["vn"] = maxf(st["vn"], absf(v.dot(n)))
				if v.length() < 1e-6 and st["rest_pos"] == Vector3.INF:
					st["rest_pos"] = pl.model.position
			fx.run(4.5)
			var tag := "%s %+.0f deg slope, %.0f deg across" % [sp, deg, c[1]]
			var vtd: Vector3 = st["v_td"]
			eq(p.contacts["stun"], 0, "%s: no stun" % tag)
			check(st["rest_pos"] != Vector3.INF, "%s: touched down and came to rest" % tag)
			if st["rest_pos"] == Vector3.INF:
				await _done()
				continue
			var dir := vtd.normalized()
			var a := maxf(mu * FlightMath.G * n.y + FlightMath.G * dir.y, brake_min * mu * FlightMath.G)
			var d_exp := vtd.length_squared() / (2.0 * a)
			var d: float = (st["rest_pos"] - st["td_pos"]).length()
			between(d / d_exp, 0.97, 1.03, "%s: run-out = v^2 / 2a within 3 %% (%.2f m at %.2f g)" % [tag, d_exp, a / FlightMath.G])
			lt(float(st["worst_dec"]), a * 1.001 + 1e-3, "%s: decelerates at a, no faster (m/s^2)" % tag)
			lt(float(st["gap_err"]), 0.001, "%s: runs on the slope's plane, never into it or off it (m)" % tag)
			lt(float(st["vn"]) / vtd.length(), 0.01, "%s: the run is along the plane (speed across it / run speed; within 0.6 deg)" % tag)
			metric(tag.replace(" ", "_"), {"d": d, "d_exp": d_exp, "a_g": a / FlightMath.G})
			await _done()


# --- G3e: the run over a change of slope ------------------------------------------------------
## (1) A run from the flat into a 20 deg hill turns up the hill: the legs
## take the speed into it (no one-tick stop), and it stops on the hill.
## (2) A run up a 38 deg roof and over its ridge leaves the ground at the
## ridge (it does not bend over a 76 deg crest in one tick) and comes down
## on the far slope or beyond. No stun; the view's per-tick velocity change
## stays within 0.45 x the touchdown speed.
func test_g3e_run_over_a_change_of_slope() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		# (1) Flat, then a 20 deg hill from z = 0 up toward -Z.
		await _fx(sp, func(w: Variant) -> void:
			FlightGeometry.box(w, Vector3(0, H0 - 0.5, 50.0), Vector3(120, 1.0, 100.0), FlightGeometry.C_GROUND, false)
			FlightGeometry.slope(w, Vector3(0, H0, 0), 20.0, Vector2(120.0, 200.0), FlightGeometry.C_GROUND, false))
		var p := fx.player
		var pr := p.model.params
		var start := Vector3(0, H0 + pr.r_body + 0.02, 0.35 * pr.v_min * pr.v_min / (2.0 * 0.6 * FlightMath.G))
		p.start_flying(start, 0.0, 0.0)
		var v0 := Vector3(0, -0.05, -1.0) * pr.v_min
		p.model.reset(start, v0, 0.0)
		var st := {"last": p.camera.global_position, "lastv": v0, "hill": false}
		var mon := _cam_monitor(st)
		fx.on_tick = func(i: int, f: Variant) -> void:
			mon.call(i, f)
			if f.player.model.position.z < 0.0:
				st["hill"] = true
		fx.run(2.5)
		var tag := "%s runs from the flat into a 20 deg hill" % sp
		eq(p.contacts["stun"], 0, "%s: no stun" % tag)
		check(bool(st["hill"]), "%s: ran onto the hill" % tag)
		eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: at rest on the ground" % tag)
		lt(float(st["worst_dv"]) / v0.length(), 0.45, "%s: per-tick view velocity change <= 0.45 x the touchdown speed" % tag)
		await _done()
		# (2) A 38 deg gable roof: touch down just below the ridge, running up.
		var ridge := Vector3(0, 12.0, 0)
		await _fx(sp, func(w: Variant) -> void:
			FlightGeometry.gable_roof(w, ridge, 38.0, 4.0, 20.0, FlightGeometry.C_FRAME, false))
		p = fx.player
		pr = p.model.params
		var nf := FlightGeometry.slope_normal(38.0)
		var zl := 0.6 * pr.span
		var surf := Vector3(0, ridge.y - zl * tan(38.0 * DEG), zl)
		start = surf + nf * (pr.r_body + 0.02)
		p.start_flying(start, 0.0, 0.0)
		v0 = Vector3(0, 0.0, -1.0) * pr.v_min
		p.model.reset(start, v0, 0.0)
		var st2 := {"last": p.camera.global_position, "lastv": v0, "grounded": false, "left": false}
		mon = _cam_monitor(st2)
		fx.on_tick = func(i: int, f: Variant) -> void:
			mon.call(i, f)
			var pl: PlayerBird = f.player
			if pl.mode == PlayerBird.Mode.GROUNDED:
				st2["grounded"] = true
			elif bool(st2["grounded"]) and pl.mode == PlayerBird.Mode.FLYING and pl.model.position.z < 0.05 * pr.span:
				st2["left"] = true
		fx.run(3.0)
		tag = "%s runs up a 38 deg roof and over its ridge" % sp
		eq(p.contacts["stun"], 0, "%s: no stun" % tag)
		check(bool(st2["left"]), "%s: leaves the ground at the ridge" % tag)
		lt(float(st2["worst_dv"]) / v0.length(), 0.45, "%s: per-tick view velocity change <= 0.45 x the touchdown speed" % tag)
		fx.assert_comfort(self, tag)
		await _done()


# --- G4: flaring near the ground lands, never stuns ---------------------------------------------
## Wrists up and held (+20 deg: a moderate flare, +40 deg: full) begun 1 span
## above the grass from the neutral glide. The flare balloons (F2), and the
## bird comes down onto its feet: the stall guard keeps a full flare near
## the ground the maximum-lift flare, and the landing configuration
## (legs and tail) sheds a big bird's energy. Round 4: the sparrow was
## stunned at every height; the pigeon and eagle floated 83-233 spans after
## moderate flares. Default: 1 span at 3 sizes; --full: 0.3 / 1 / 2 spans x
## +20 / +30 / +40 deg (the verifier's grid).
func _flare(sp: StringName, twist: float, h_spans: float) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
	var st := {"flare_t": -1.0, "flare_tick": -1, "ground_tick": -1}
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if float(st["flare_t"]) >= 0.0:
			var k := clampf((t - float(st["flare_t"])) / 0.3, 0.0, 1.0)
			b.arms[0].twist = k * twist * DEG
			b.arms[1].twist = k * twist * DEG
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if float(st["flare_t"]) < 0.0 and pl.model.position.y - pr.r_body < h_spans * pr.span:
			st["flare_t"] = fx.src.tick * DT
			st["flare_tick"] = i
		if int(st["ground_tick"]) < 0 and pl.mode == PlayerBird.Mode.GROUNDED:
			st["ground_tick"] = i
	# Until on the ground (and 0.5 s more), at most 30 s.
	var n := 0
	while n < int(30.0 / DT) and (int(st["ground_tick"]) < 0 or fx.ticks < int(st["ground_tick"]) + 36):
		fx.step()
		n += 1
	var out := {"stuns": p.contacts["stun"], "land_s": (int(st["ground_tick"]) - int(st["flare_tick"])) * DT if int(st["ground_tick"]) >= 0 else -1.0}
	await _done()
	return out


func test_g4_flares_near_the_ground_land_without_a_stun() -> void:
	var full := Paths.arg("full", "") != ""
	var cases: Array = []
	for sp in S3:
		for tw in ([20.0, 30.0, 40.0] if full else [20.0, 40.0]):
			for h in ([0.3, 1.0, 2.0] if full else [1.0]):
				# Default: the full flare at every size, the moderate one for the
				# big birds (the sparrow's lands in 0.5 s).
				if full or tw == 40.0 or sp != &"sparrow":
					cases.append([sp, tw, h])
	for c in cases:
		var r: Dictionary = await _flare(c[0], c[1], c[2])
		var tag := "%s +%d deg from %.1f spans" % [c[0], int(c[1]), c[2]]
		eq(r["stuns"], 0, "%s: no stun" % tag)
		between(float(r["land_s"]), 0.0, 20.0, "%s: on the ground within 20 s of the flare (s)" % tag)
		metric(tag.replace(" ", "_"), r["land_s"])


# --- G5: the stall guard ------------------------------------------------------------------------
## Model level: full nose-up held 3 s from the trimmed glide. Below the
## guard height (what a held stall falls before its forced recovery, plus a
## quarter of V_min^2 / g: sparrow 9.2, pigeon 9.7, eagle 10.8 m) it is the
## maximum-lift flare: no stall, alpha within the protected top. Above it the
## deliberate stall is there (F3). A stall entered above it is released
## once the bird is below it and the nose is down (not held to the forced
## recovery). The sim preset has no protection anywhere.
func _hold_full(mass: float, agl_fn: Callable, preset := 1) -> Dictionary:
	var tu := FlightTuning.default_tuning().duplicate() as FlightTuning
	tu.preset = preset
	var m := FlightModel.new(mass, tu)
	m.trim(Vector3(0, 500, 0), 0.0, 0.0)
	var ws := WingState.new()
	ws.set_neutral()
	var env := FlightEnv.new()
	var out := {"stalls": 0, "max_alpha": -INF, "unstall_t": -1.0, "stalled_at": -1.0}
	var n := int(round(3.0 / DT))
	for i in n:
		var t := i * DT
		ws.pitch = clampf(t / 0.2, 0.0, 1.0)
		env.set("agl", agl_fn.call(t, m))
		var was := m.stalled
		m.step(ws, env, DT)
		out["max_alpha"] = maxf(out["max_alpha"], m.alpha)
		if m.stalled and not was and float(out["stalled_at"]) < 0.0:
			out["stalled_at"] = t
		if was and not m.stalled and float(out["unstall_t"]) < 0.0:
			out["unstall_t"] = t
	out["stalls"] = m.stall_count
	out["guard_h"] = _guard_h(m)
	out["alpha_s"] = m.params.alpha_s
	return out


func test_g5_stall_guard_near_the_ground() -> void:
	for sp in S3:
		var mass := FlightParams.species_mass(sp)
		var low: Dictionary = _hold_full(mass, func(_t: float, m: FlightModel) -> float: return 0.5 * _guard_h(m))
		var high: Dictionary = _hold_full(mass, func(_t: float, _m: FlightModel) -> float: return INF)
		var sim_low: Dictionary = _hold_full(mass, func(_t: float, m: FlightModel) -> float: return 0.5 * _guard_h(m), 0)
		eq(low["stalls"], 0, "%s: below the guard (%.1f m) full nose-up is the max-lift flare, no stall" % [sp, low["guard_h"]])
		lt(float(low["max_alpha"]), float(low["alpha_s"]) + 0.5 * DEG, "%s: alpha stays within the protected top below the guard" % sp)
		gt(high["stalls"], 0, "%s: above the guard the deliberate stall is there (F3)" % sp)
		gt(sim_low["stalls"], 0, "%s: the sim preset stalls near the ground too" % sp)
		between(float(low["guard_h"]), 9.0, 12.0, "%s: guard height (m)" % sp)
		# A stall entered above the guard, then the ground comes close: released
		# as soon as the nose is down, well before the 1.5 s forced recovery.
		var cross: Dictionary = _hold_full(mass, func(t: float, m: FlightModel) -> float:
			return INF if not m.stalled or t < 0.0 else (INF if m._t_stall < 0.35 else 0.5 * _guard_h(m)))
		gt(float(cross["stalled_at"]), 0.0, "%s: stalled above the guard" % sp)
		between(float(cross["unstall_t"]) - float(cross["stalled_at"]), 0.3, 1.2, "%s: released below the guard before the forced recovery (s)" % sp)
		metric("%s_guard_m" % sp, low["guard_h"])


# --- G5b: the stall guard in the game --------------------------------------------------------------
## PlayerBird level (the ground it reads, fix round 6): a sparrow holding
## full nose-up (wrists +40 deg) from the trimmed glide over flat ground
## stalls from 15 and 25 m (above the 9.2 m guard; the flare zooms ~2.5 m
## up first) and never from 5 m. Over a 25 m flat roof (a tower top: the
## World's terrain height excludes buildings, and round 5's ray reached
## only 2 spans) a full flare begun a span above the roof is the
## maximum-lift flare at every size: no stall below the guard height above
## the roof (none at all for the sparrow and pigeon; an eagle's flare zooms
## 7 spans up and may stall at the top, as it does over the meadow), no
## stun, at rest on the roof (round 5: 2-3 stalls from the terrain's 25 m
## up, the sparrow stunned).
func _flare_hold(sp: StringName, world: Callable, h0: float, flare_below := INF, top := 0.0) -> Dictionary:
	await _fx(sp, world)
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, h0, 0), 0.0, 0.0)
	var st := {"flare_t": -1.0 if is_finite(flare_below) else 0.0, "rest": false, "was": false, "stall_agl": INF}
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if float(st["flare_t"]) >= 0.0:
			var k := clampf((t - float(st["flare_t"])) / 0.3, 0.0, 1.0)
			b.arms[0].twist = k * 40.0 * DEG
			b.arms[1].twist = k * 40.0 * DEG
	fx.reset_events()
	fx.on_tick = func(_i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if float(st["flare_t"]) < 0.0 and pl.model.position.y - pr.r_body - top < flare_below * pr.span:
			st["flare_t"] = fx.src.tick * DT
		if pl.mode == PlayerBird.Mode.GROUNDED and pl.model.velocity.length() < 1e-4:
			st["rest"] = true
		if pl.model.stalled and not bool(st["was"]):
			# The belly's height above the surface below (the roof or the ground).
			st["stall_agl"] = minf(st["stall_agl"], pl.model.position.y - pr.r_body - top)
		st["was"] = pl.model.stalled
	var n := 0
	while n < int(30.0 / DT) and not bool(st["rest"]):
		fx.step()
		n += 1
	var out := {"stalls": fx.events["stalled"], "stuns": p.contacts["stun"], "rest": st["rest"], "y": p.model.position.y,
		"stall_agl": st["stall_agl"], "guard": _guard_h(p.model)}
	await _done()
	return out


func test_g5b_stall_guard_in_the_game() -> void:
	for h: float in [5.0, 15.0, 25.0]:
		await _fx(&"sparrow")
		var p := fx.player
		p.start_flying(Vector3(0, h, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var k := clampf(t / 0.3, 0.0, 1.0)
			b.arms[0].twist = k * 40.0 * DEG
			b.arms[1].twist = k * 40.0 * DEG
		fx.reset_events()
		fx.run(3.0)
		if h < 9.0:
			eq(fx.events["stalled"], 0, "sparrow full nose-up from %.0f m: below the guard, no stall" % h)
		else:
			gt(fx.events["stalled"], 0, "sparrow full nose-up from %.0f m: above the guard, the deliberate stall (F3)" % h)
		metric("sparrow_from_%.0f_m_stalls" % h, fx.events["stalled"])
		await _done()
	var top := 25.0
	var roof := func(w: Variant) -> void:
		FlightGeometry.box(w, Vector3(0, 0.5 * top, -250.0), Vector3(80, top, 700), FlightGeometry.C_WALL, false)
	for sp in S3:
		var pr := FlightParams.derive(FlightParams.species_mass(sp), FlightTuning.default_tuning())
		var r: Dictionary = await _flare_hold(sp, roof, top + 6.0 * pr.span + 2.0, 1.0, top)
		var tag := "%s full flare a span above a %.0f m flat roof" % [sp, top]
		# A big bird's flare zooms above the guard height and may stall at the
		# top (as over the meadow, G5); never below it.
		gt(float(r["stall_agl"]), float(r["guard"]), "%s: no stall below the guard height above the roof (the guard reads the roof; m)" % tag)
		if sp != &"eagle":
			eq(r["stalls"], 0, "%s: no stall" % tag)
		eq(r["stuns"], 0, "%s: no stun" % tag)
		check(bool(r["rest"]) and float(r["y"]) > top, "%s: at rest on the roof" % tag)
		metric(tag.replace(" ", "_"), r)


# --- G6: the landing configuration ------------------------------------------------------------------
## The legs and tail come down only for a slow, sinking, flaring bird near
## the ground: a pull-up from a low pass (fast, climbing) zooms exactly as
## high as without it, and a trimmed skim (no flare) gets none.
func _zoom(sp: StringName, with_config: bool) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	var pr := p.model.params
	if not with_config:
		var tu := p.tuning.duplicate() as FlightTuning
		tu.set("landing_config_spans", 0.0)
		p.tuning = tu
		p.model.set_tuning(tu)
	p.start_flying(Vector3(0, pr.r_body + 1.0 * pr.span, 0), 0.0, 0.0)
	var st := {"top": -INF, "bonus_climb": 0.0, "bonus_max": 0.0}
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		var k := clampf(t / 0.3, 0.0, 1.0)
		b.arms[0].twist = k * 40.0 * DEG
		b.arms[1].twist = k * 40.0 * DEG
	fx.on_tick = func(_i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["top"] = maxf(st["top"], pl.model.position.y)
		if pl.model.velocity.y > 0.1:
			st["bonus_climb"] = maxf(st["bonus_climb"], pl.env.drag_bonus)
		st["bonus_max"] = maxf(st["bonus_max"], pl.env.drag_bonus)
	fx.run(6.0)
	var out := {"top": st["top"], "bonus_climb": st["bonus_climb"], "bonus_max": st["bonus_max"]}
	await _done()
	return out


func test_g6_landing_configuration_only_for_a_landing() -> void:
	for sp in S3:
		var on: Dictionary = await _zoom(sp, true)
		var off: Dictionary = await _zoom(sp, false)
		near(float(on["top"]), float(off["top"]), 0.005 * absf(float(off["top"])) + 0.01, "%s: a pull-up from a low pass zooms as high with the landing configuration (m)" % sp)
		eq(float(on["bonus_climb"]), 0.0, "%s: no landing configuration while climbing" % sp)
		gt(float(on["bonus_max"]), 0.2, "%s: legs and tail come down once the flaring bird sinks near the ground" % sp)
		# A neutral skim: none.
		await _fx(sp)
		var p := fx.player
		var pr := p.model.params
		p.start_flying(Vector3(0, pr.r_body + 0.5 * pr.span, 0), 0.0, 0.0)
		var mx := {"b": 0.0}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			mx["b"] = maxf(mx["b"], f.player.env.drag_bonus)
		fx.run(3.0)
		eq(float(mx["b"]), 0.0, "%s: a trimmed skim (no flare) gets no landing configuration" % sp)
		await _done()


# --- G7: a branch top is not ground ---------------------------------------------------------
## A slow bird that drops onto the top of a branch away from its grip point
## never "touches down" there (GROUNDED at 20 m): perch geometry is not ground
## to land on; the bird slides on it (the capture takes it at the grip) or
## falls off and flies on. Found while re-running the perch wind sweep with
## the round-5 touchdown speed (1.2 V_min): a sparrow "landed" on a branch
## 0.2 m from the grip, ran off it and the view owed a 49 deg heading snap.
func test_g7_a_branch_top_is_not_ground() -> void:
	for sp in S3:
		for along: float in [0.25, 0.4]:
			await _fx(sp, func(w: Variant) -> void:
				w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 10.0, 0.015, 1.0))
			var p := fx.player
			var pr := p.model.params
			var start := Vector3(along, 20.0 + 0.015 + pr.r_body + 0.03, -10.0 + 0.4 * pr.span)
			p.start_flying(start, 0.0, 0.0)
			p.model.reset(start, Vector3(0, -0.15 * pr.v_min, -0.5 * pr.v_min), 0.0)
			var st := {"grounded": 0, "air_acc": 0.0}
			fx.on_tick = func(i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if pl.mode == PlayerBird.Mode.GROUNDED and pl.model.position.y > 10.0:
					st["grounded"] += 1
				if pl.mode == PlayerBird.Mode.FLYING and not pl.yaw_flagged and i > 2:
					st["air_acc"] = maxf(st["air_acc"], absf(pl.rig_yaw_accel))
			fx.run(1.5)
			var tag := "%s %.2f m along the branch" % [sp, along]
			eq(st["grounded"], 0, "%s: never touches down on the branch top" % tag)
			eq(p.contacts["stun"], 0, "%s: no stun" % tag)
			lt(rad_to_deg(st["air_acc"]), 600.0 + 1e-3, "%s: the rig's yaw acceleration in the air stays within 360 + 240 (deg/s^2)" % tag)
			fx.assert_comfort(self, tag)
			await _done()


# --- G8: taking off facing up a slope --------------------------------------------------------
## A bird that landed facing up a slope (20-44 deg; village roofs are 34-44)
## flaps the reference stroke (1.3 Hz, 45 deg). The launch runs up along
## the slope and off it (never into it), and a bird taking off is not
## touched down again while it keeps flapping: it leaves the ground on its
## take-off stroke (the first for a sparrow, the second for a pigeon or an
## eagle), without a took_off / perched pair on every stroke (round 5: one
## per stroke, 3-12 in 6 s, stuck). A big bird that cannot out-climb the
## slope (an eagle climbs ~12 deg from a standing start) bounds up it and
## stands again when its launch is spent (its feet hold; it never slides
## back down the slope on its belly). The real village roofs (G9) and a
## banked turn away (G10) are how it leaves them.
func _grounded_facing_up(sp: StringName, deg: float, yaw_deg := 0.0, world := Callable()) -> FX:
	await _fx(sp, world if world.is_valid() else _slope_setup(deg))
	var p := fx.player
	var pr := p.model.params
	var yaw := yaw_deg * DEG
	var z0 := -2.0 * pr.span
	var start := Vector3(0, _surf_y(deg, z0) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
	p.start_flying(start, yaw, 0.0)
	p.model.reset(start, FlightMath.yaw_forward(yaw) * 0.3 * pr.v_min + Vector3.DOWN * 0.2 * pr.v_min, yaw)
	fx.run(2.0)
	return fx


## Strokes (1.3 Hz, 45 deg) from now for `secs`, optional roll `roll_fn(t)`.
## Returns the take-off timing, the events and the scramble statistics.
func _strokes_off(deg: float, secs: float, roll_fn := Callable()) -> Dictionary:
	var p := fx.player
	var pr := p.model.params
	var n := FlightGeometry.slope_normal(deg)
	var up := Vector3(0, sin(deg * DEG), -cos(deg * DEG))     # up the fall line
	var cal := p.wing_input.calibration
	var t0 := fx.src.tick * DT
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if roll_fn.is_valid():
			b.synth(0.0, float(roll_fn.call(t - t0)), 1.0, cal)
		ScriptedPoseSource.flap(b, t - t0 + 0.5, 45.0, 1.3)
	fx.reset_events()
	var st := {"first_to": -1.0, "flaps_before": 0, "backslide": 0, "min_gap_to_pe": INF, "last_to": -1.0, "i0": fx.ticks,
		"s0": (p.model.position - Vector3(0, H0, 0)).dot(up)}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var t := (i - int(st["i0"])) * DT
		if f.events["took_off"] > 0 and float(st["first_to"]) < 0.0:
			st["first_to"] = t
			st["last_to"] = t
		if float(st["first_to"]) < 0.0:
			st["flaps_before"] = f.events["flapped"]
		# A took_off followed by a perched: how soon.
		if f.events["took_off"] > 0 and int(st.get("to_seen", 0)) < f.events["took_off"]:
			st["to_seen"] = f.events["took_off"]
			st["last_to"] = t
		if int(st.get("pe_seen", 0)) < f.events["perched"]:
			st["pe_seen"] = f.events["perched"]
			if float(st["last_to"]) >= 0.0:
				st["min_gap_to_pe"] = minf(st["min_gap_to_pe"], t - float(st["last_to"]))
		# Belly-sliding back down: flying, on the slope, moving down its fall line.
		var gap := (pl.model.position - Vector3(0, H0, 0)).dot(n) - pr.r_body
		if pl.mode == PlayerBird.Mode.FLYING and gap < 0.002 and pl.model.velocity.dot(up) < -0.05 * pr.v_min:
			st["backslide"] += 1
	fx.run(secs)
	var pos := p.model.position
	st["clear"] = minf((pos - Vector3(0, H0, 0)).dot(n) - pr.r_body, pos.y - pr.r_body)
	st["climbed"] = (pos - Vector3(0, H0, 0)).dot(up) - float(st["s0"])
	st["took_off"] = fx.events["took_off"]
	st["perched"] = fx.events["perched"]
	st["mode"] = p.mode
	return st


func test_g8_take_off_facing_up_a_slope() -> void:
	var full := Paths.arg("full", "") != ""
	for sp in S3:
		for deg: float in ([20.0, 30.0, 38.0, 44.0] if full else ([38.0] if sp != &"eagle" else [20.0, 44.0])):
			await _grounded_facing_up(sp, deg)
			var p := fx.player
			var pr := p.model.params
			var tag := "%s facing up %.0f deg" % [sp, deg]
			eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: landed first" % tag)
			var r: Dictionary = _strokes_off(deg, 6.0)
			var need := 2 if pr.mass >= 0.9 * FlightParams.species_mass(&"pigeon") else 1
			var period := 1.0 / 1.3
			gt(float(r["first_to"]), 0.0, "%s: takes off" % tag)
			lt(float(r["first_to"]), (need + 0.75) * period, "%s: on its take-off stroke (stroke %d; s)" % [tag, need])
			lt(int(r["flaps_before"]), 2 * need + 1, "%s: no more wing onsets than the take-off strokes before it" % tag)
			gt(float(r["min_gap_to_pe"]), 1.0, "%s: never touched down again within 1 s of a take-off (s; round 5: every stroke)" % tag)
			lt(int(r["took_off"]), 3, "%s: at most one take-off per bound (round 5: 3-12 in 6 s)" % tag)
			eq(int(r["backslide"]), 0, "%s: never slides back down the slope on its belly (ticks)" % tag)
			gt(float(r["climbed"]), 1.0 * pr.span, "%s: made its way up the slope (m)" % tag)
			metric(tag.replace(" ", "_"), {"first_to_s": r["first_to"], "took_off": r["took_off"], "perched": r["perched"],
				"climbed_spans": float(r["climbed"]) / pr.span, "clear_spans": float(r["clear"]) / pr.span, "mode": p.mode_name()})
			await _done()


# --- G9: taking off from a village roof, facing the ridge -------------------------------------
## A gable roof like the village's (pitch 38 or 44 deg, 3.2 m from the eave
## to the ridge, eaves 6 m up): a bird that landed on it facing the ridge
## flaps the reference stroke and leaves the roof over the ridge at every
## size (FLYING with no part of the roof within a span at the end), taking
## off once and never touching down again. A pigeon or an eagle bounds up
## the roof and drops away past the ridge; a sparrow climbs straight out.
func test_g9_take_off_from_a_village_roof_facing_the_ridge() -> void:
	var full := Paths.arg("full", "") != ""
	var hd := 3.2
	var eave := 6.0
	for sp in S3:
		for pitch: float in ([38.0, 44.0] if full else [44.0]):
			var ridge := Vector3(0, eave + hd * tan(pitch * DEG), 0)
			await _fx(sp, func(w: Variant) -> void:
				FlightGeometry.gable_roof(w, ridge, pitch, hd, 12.0, FlightGeometry.C_FRAME, false))
			var p := fx.player
			var pr := p.model.params
			# Land a third of the way up the front slope, facing the ridge.
			var zl := 0.66 * hd
			var nf := FlightGeometry.slope_normal(pitch)
			var surf := Vector3(0, ridge.y - (hd - zl) * tan(pitch * DEG), zl)
			var start := surf + nf * (pr.r_body + 0.05)
			p.start_flying(start, 0.0, 0.0)
			p.model.reset(start, Vector3(0, -0.2, -0.3) * pr.v_min, 0.0)
			fx.run(2.0)
			var tag := "%s on a %.0f deg roof facing the ridge" % [sp, pitch]
			eq(p.mode, PlayerBird.Mode.GROUNDED, "%s: landed first" % tag)
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t + 0.5, 45.0, 1.3)
			fx.reset_events()
			fx.run(6.0)
			eq(p.mode, PlayerBird.Mode.FLYING, "%s: flying at the end" % tag)
			eq(_roof_within(p, pr.span), 0, "%s: no part of the roof within a span at the end" % tag)
			check(p.model.position.z < 0.0 or p.model.position.y > ridge.y + pr.span, "%s: it left over the ridge (z %.2f m, %.2f m above the ridge)" % [
				tag, p.model.position.z, p.model.position.y - ridge.y])
			eq(fx.events["took_off"], 1, "%s: took off once" % tag)
			eq(fx.events["perched"], 0, "%s: never touched down again" % tag)
			metric(tag.replace(" ", "_"), {"above_ridge_spans": (p.model.position.y - ridge.y) / pr.span,
				"took_off": fx.events["took_off"], "perched": fx.events["perched"]})
			await _done()


## Roof slabs (G9) within `d` of the body.
func _roof_within(p: PlayerBird, d: float) -> int:
	var q := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	sph.radius = p.model.params.r_body + d
	q.shape = sph
	q.transform = Transform3D(Basis.IDENTITY, p.model.position)
	q.collision_mask = FlightGeometry.LAYER_WORLD
	var n := 0
	for hit in p.get_world_3d().direct_space_state.intersect_shape(q, 8):
		if str((hit["collider"] as Node).name).begins_with("Roof"):
			n += 1
	return n


# --- G10: a long slope: bank away -------------------------------------------------------------
## Facing up a long 30 deg hillside, a pigeon or an eagle cannot out-climb
## it straight ahead (G8). Flapping with a banked turn away from it (roll
## 0.7 for 1.5 s after the take-off, then level) leaves it: flying and two
## spans clear at the end.
func test_g10_bank_away_from_a_long_slope() -> void:
	for sp: StringName in [&"pigeon", &"eagle"]:
		await _grounded_facing_up(sp, 30.0)
		var p := fx.player
		var pr := p.model.params
		var st := {"t_to": -1.0}
		var r: Dictionary = _strokes_off(30.0, 8.0, func(t: float) -> float:
			if float(st["t_to"]) < 0.0 and fx.events["took_off"] > 0:
				st["t_to"] = t
			var u := t - float(st["t_to"])
			return 0.7 if float(st["t_to"]) >= 0.0 and u < 1.5 else 0.0)
		var tag := "%s banking away from a 30 deg hillside" % sp
		eq(int(r["mode"]), PlayerBird.Mode.FLYING, "%s: flying at the end" % tag)
		gt(float(r["clear"]), 2.0 * pr.span, "%s: two spans clear at the end (m)" % tag)
		metric(tag.replace(" ", "_"), {"clear_spans": float(r["clear"]) / pr.span, "took_off": r["took_off"], "perched": r["perched"]})
		await _done()
