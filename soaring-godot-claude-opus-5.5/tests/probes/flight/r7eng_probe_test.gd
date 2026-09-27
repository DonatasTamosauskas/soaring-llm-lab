extends TestCase
## Verifier probe (flight, ENGINEERING & CONTRACT lens, round 7 = the check of
## builder fix round 6). Independent of the area's own tests; reads private
## state only to check invariants the public contract implies.
##  1. A touchdown beside a wall: the rest of the touchdown tick's motion is
##     swept while already GROUNDED. Does a contact there leave Bird.perched,
##     _run_v or _ground_n inconsistent with the mode?
##  2. Random play over slopes, roofs, a flat roof, walls and a branch:
##     Bird.perched == (mode is PERCHED or GROUNDED), no run-out velocity
##     outside GROUNDED, camera = body + view_offset(), pure-yaw rig, no NaN,
##     GROUNDED only on a floor, the body never inside geometry.
##  3. telemetry altitude_agl standing on / flying over a flat roof vs the
##     stall guard's own ground ray (FlightEnv.agl).
##  4. Determinism of a slope take-off (new round-6 path).
##  5. A touchdown facing down a steep slope: does the run-out brake
##     (run_brake_min), and is that pinned anywhere?
##  6. Tick cost in the new near-ground paths.
##  7. Respawn in the middle of a leg bend: camera back on the body.
##  8. wrap_angle at the seam: the documented [-PI, PI).
## Output: artifacts/flight/verify/r7eng/probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0
const S3: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]

var fx: FX
var _lines: PackedStringArray = []


func _log(s: String) -> void:
	print("[flight-r7eng] ", s)
	_lines.append(s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var dir := Paths.artifacts("flight").path_join("verify/r7eng")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("probe.txt"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _fx(sp: StringName, world_setup: Callable = Callable()) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, world_setup)
	return fx


func _done() -> void:
	fx.teardown()
	fx = null


static func _rest_mode(p: PlayerBird) -> bool:
	return p.mode == PlayerBird.Mode.PERCHED or p.mode == PlayerBird.Mode.GROUNDED


# --- 1. touchdown beside a wall ---------------------------------------------------------
func _wall_touchdown(sp: StringName, h: float, vf: float, vs: float, k: float) -> Dictionary:
	var pr0 := FlightParams.derive(FlightParams.species_mass(sp))
	var v0 := Vector3(0, -vs, -vf) * pr0.v_min
	var r := pr0.r_body
	# The wall's +Z face is ahead of the bird (heading 0 = -Z), just beyond
	# the feet's sphere (2 r_body), plus k x one tick's travel.
	var zw := -(2.0 * r + 0.003 + k * v0.length() * DT)
	await _fx(sp, func(w: Variant) -> void:
		w.add_wall(Vector3(0, 5.0, zw - 0.5), Vector3(40.0, 10.0, 1.0)))
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, pr.r_body * (1.0 + h), 0)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, v0, 0.0)
	var st := {"td_tick": -1, "stun_tick": -1, "perched_bad": 0, "runv_bad": 0, "gn_bad": 0, "same_tick_pe_col": false,
		"events": [], "perched_ev": 0, "took_off": 0, "first_bad": ""}
	var pe0 := 0
	var co0 := 0
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var pe: int = f.events["perched"]
		var co: int = f.events["collided"]
		if pe > pe0 and co > co0:
			st["same_tick_pe_col"] = true
		pe0 = pe
		co0 = co
		if pl.mode == PlayerBird.Mode.GROUNDED and int(st["td_tick"]) < 0:
			st["td_tick"] = i
		if pl.mode == PlayerBird.Mode.STUNNED and int(st["stun_tick"]) < 0:
			st["stun_tick"] = i
		if pl.perched != _rest_mode(pl):
			st["perched_bad"] += 1
			if str(st["first_bad"]).is_empty():
				st["first_bad"] = "tick %d mode %s perched %s run_v %s" % [i, pl.mode_name(), pl.perched, pl._run_v]
		if pl.mode != PlayerBird.Mode.GROUNDED and pl._run_v != Vector3.ZERO:
			st["runv_bad"] += 1
		if pl.mode != PlayerBird.Mode.GROUNDED and not pl._ground_n.is_equal_approx(Vector3.UP):
			st["gn_bad"] += 1
	fx.run(2.5)
	st["perched_ev"] = fx.events["perched"]
	st["took_off"] = fx.events["took_off"]
	st["stuns"] = p.contacts["stun"]
	st["v_stun"] = maxf(0.35 * pr.v_c, 2.0)
	st["vmin"] = pr.v_min
	await _done()
	return st


func test_r7_touchdown_beside_a_wall_keeps_state_consistent() -> void:
	var total := 0
	var bad_cases := 0
	var by_size := {}
	var examples: PackedStringArray = []
	for sp in S3:
		by_size[sp] = 0
		for h: float in [0.3, 0.8, 1.5]:
			for vf: float in [0.6, 0.9, 1.1]:
				for vs: float in [0.0, 0.15, 0.3]:
					for k: float in [0.0, 0.25, 0.5, 0.75]:
						var r: Dictionary = await _wall_touchdown(sp, h, vf, vs, k)
						total += 1
						var bad := int(r["perched_bad"]) > 0 or int(r["runv_bad"]) > 0 or int(r["gn_bad"]) > 0
						if bad:
							bad_cases += 1
							by_size[sp] += 1
							if examples.size() < 12:
								examples.append("%s h %.1f vf %.1f vs %.2f k %.2f: td tick %d, stun tick %d, perched!=mode %d ticks, run_v outside GROUNDED %d, ground_n %d, perched events %d, took_off %d, stuns %d, perched+collided same tick %s | %s" % [
									sp, h, vf, vs, k, r["td_tick"], r["stun_tick"], r["perched_bad"], r["runv_bad"], r["gn_bad"],
									r["perched_ev"], r["took_off"], r["stuns"], r["same_tick_pe_col"], r["first_bad"]])
	_log("touchdown beside a wall: %d of %d cases leave Bird.perched / _run_v / _ground_n inconsistent with the mode (by size %s)" % [bad_cases, total, by_size])
	for e in examples:
		_log("  " + e)
	metric("bad_cases", bad_cases)
	eq(bad_cases, 0, "a touchdown beside a wall never leaves Bird.perched true (or a run-out velocity) outside PERCHED/GROUNDED (%d of %d cases)" % [bad_cases, total])


# --- 1b. the same on a ledge beside a wall (a window sill) --------------------------------
## A sparrow touching down on a 5 m high ledge right against the wall behind it:
## how long does Bird.perched stay true while it is not on anything, and what
## does a later perch take-off do with the run-out velocity left over?
func test_r7_ledge_touchdown_against_a_wall() -> void:
	var sp := &"sparrow"
	var pr0 := FlightParams.derive(FlightParams.species_mass(sp))
	var r := pr0.r_body
	var zw := -(2.0 * r + 0.003)
	await _fx(sp, func(w: Variant) -> void:
		w.add_wall(Vector3(0, 5.0, zw - 0.5), Vector3(40.0, 10.0, 1.0))
		w.add_wall(Vector3(0, 4.9, zw + 0.125), Vector3(40.0, 0.2, 0.25)))
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, 5.0 + pr.r_body * 1.3, zw + 2.0 * pr.r_body + 0.004)
	p.start_flying(start, 0.0, 0.0)
	var v0 := Vector3(0, 0.0, -1.1) * pr.v_min
	p.model.reset(start, v0, 0.0)
	var st := {"air_perched": 0, "first_mode": "", "max_h": 0.0, "stale_air": 0}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if i == 1:
			st["first_mode"] = "%s perched %s run_v %s" % [pl.mode_name(), pl.perched, pl._run_v]
		var below := _floor_below(pl)
		var on_something := not below.is_empty()
		if pl.perched and not _rest_mode(pl) and not on_something:
			st["air_perched"] += 1
		if not _rest_mode(pl) and pl._run_v != Vector3.ZERO and not on_something:
			st["stale_air"] += 1
	fx.run(1.0)
	var run_v_left := p._run_v
	var mode_1s := p.mode_name()
	var perched_1s := p.perched
	var y_1s := p.model.position.y
	# A perch capture now (the path _try_capture takes), then one flap.
	var wv: Variant = fx.world
	var perch: Perch = wv.add_virtual_perch(p.model.position + Vector3.DOWN * pr.r_body, Vector3.FORWARD, 10.0)
	p._capture(perch)
	fx.run(0.3)
	var cap_mode := p.mode_name()
	var t0 := fx.src.tick * DT
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t - t0 + 0.5, 45.0, 1.3)
	var launch_v := Vector3.ZERO
	for i in 200:
		fx.step()
		if p.mode == PlayerBird.Mode.FLYING:
			launch_v = p.model.velocity
			break
	var f := FlightMath.yaw_forward(p.model.heading())
	_log("ledge against a wall: tick 1 %s; ticks with Bird.perched true while not standing on anything %d, run-out velocity kept in the air %d ticks; at 1 s: mode %s perched %s y %.2f run_v %s" % [
		st["first_mode"], st["air_perched"], st["stale_air"], mode_1s, perched_1s, y_1s, run_v_left])
	_log("  then a perch capture (%s) and a flap: launch velocity %s (%.2f m/s; along the heading %.2f, across %.2f), a clean perch launch is 0.6 V_min = %.2f m/s along the heading plus the kick" % [
		cap_mode, launch_v, launch_v.length(), launch_v.dot(f), (launch_v - f * launch_v.dot(f) - Vector3.UP * launch_v.y).length(), 0.6 * pr.v_min])
	eq(int(st["air_perched"]), 0, "Bird.perched is never true while the bird is off everything")
	lt((launch_v - f * launch_v.dot(f) - Vector3.UP * launch_v.y).length(), 0.05, "a perch launch carries no sideways/backward run-out velocity from an earlier landing (m/s)")


# --- 2. random play over slopes and roofs ----------------------------------------------------
func _rough_world(w: World) -> void:
	# A 30 deg hillside (rising toward -Z from z = -20), a 38 deg gable roof,
	# a 6 m flat roof, a wall and a branch, on the flat ground.
	FlightGeometry.slope(w, Vector3(0, 0.0, -20.0), 30.0, Vector2(60.0, 60.0), FlightGeometry.C_GROUND, false)
	FlightGeometry.gable_roof(w, Vector3(25, 6.0 + 3.2 * tan(38.0 * DEG), 10), 38.0, 3.2, 12.0, FlightGeometry.C_FRAME, false)
	w.add_wall(Vector3(-25, 3.0, 10), Vector3(12.0, 6.0, 12.0))
	w.add_wall(Vector3(0, 4.0, 30), Vector3(30.0, 8.0, 1.0))
	w.add_perch(Vector3(8, 3.0, 5), Vector3.FORWARD, 10.0, 0.02, 2.0)


func _inside_geometry(p: PlayerBird, margin: float) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var s := SphereShape3D.new()
	s.radius = maxf(p.model.params.r_body - margin, 1e-3)
	q.shape = s
	q.transform = Transform3D(Basis.IDENTITY, p.model.position)
	q.collision_mask = 1
	return not p.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _floor_below(p: PlayerBird) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.new()
	q.from = p.model.position
	q.to = p.model.position + Vector3.DOWN * (p.model.params.r_body * 3.0 + 0.05)
	q.collision_mask = 1
	return p.get_world_3d().direct_space_state.intersect_ray(q)


func _random_play(sp: StringName, seed_v: int, seconds: float) -> Dictionary:
	await _fx(sp, _rough_world)
	var p := fx.player
	var pr := p.model.params
	var cal := p.wing_input.calibration
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var g := {"kind": 0, "until": 0.0, "amp": 45.0, "hz": 1.5, "tw": 30.0, "r": 0.0, "lost": 0.0, "lost_kind": 0}
	var clk := {"t": 0.0}
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		var t: float = clk["t"]
		b.set_airplane()
		b.head_valid = true
		b.left_valid = true
		b.right_valid = true
		match int(g["kind"]):
			1:
				b.arms[0].twist = float(g["tw"]) * DEG
				b.arms[1].twist = float(g["tw"]) * DEG
			2, 7:
				ScriptedPoseSource.flap(b, t, g["amp"], g["hz"])
			3:
				b.synth(0.0, 0.0, 0.1, cal)
			4:
				b.synth(0.3, float(g["r"]), 1.0, cal)
			5:
				b.synth(1.0, 0.0, 1.0, cal)
			6:
				b.arms[0].dihedral = -80.0 * DEG
				b.arms[1].dihedral = -80.0 * DEG
		if float(g["lost"]) > t:
			match int(g["lost_kind"]):
				0: b.head_valid = false
				1: b.left_valid = false
				_: b.right_valid = false
	var st := {"nan": 0, "basis_bad": 0, "perched_bad": 0, "runv_bad": 0, "cam_err": 0.0, "ground_bad": 0, "inside": 0,
		"td": 0, "to": 0, "stun": 0, "grounded": 0, "first": "", "max_rate": 0.0, "max_acc": 0.0}
	var spots := [Vector3(0, 12, -10), Vector3(25, 14, 14), Vector3(-25, 9, 10), Vector3(0, 4, 20), Vector3(8, 5, 12)]
	p.start_flying(spots[0] + Vector3.UP * pr.span, 0.0, 0.0)
	var prev_mode := p.mode
	var prev_rate := 0.0
	var skip := 2
	var t := 0.0
	var i := 0
	while t < seconds:
		if t >= float(g["until"]):
			g["kind"] = rng.randi_range(0, 7)
			g["until"] = t + rng.randf_range(0.8, 3.0)
			g["amp"] = rng.randf_range(30.0, 60.0)
			g["hz"] = rng.randf_range(1.0, 2.5)
			g["tw"] = rng.randf_range(-20.0, 45.0)
			g["r"] = rng.randf_range(-1.0, 1.0)
			if rng.randf() < 0.12:
				g["lost"] = t + rng.randf_range(0.1, 1.2)
				g["lost_kind"] = rng.randi_range(0, 2)
		var dt := DT
		var u := rng.randf()
		if u < 0.02:
			dt = 0.1
		elif u < 0.12:
			dt = 1.0 / 90.0
		t += dt
		clk["t"] = t
		p.tick(dt)
		i += 1
		var pos := p.model.position
		if absf(pos.x) > 60.0 or absf(pos.z) > 60.0 or pos.y > 60.0 or pos.y < -1.0:
			var s: Vector3 = spots[rng.randi_range(0, spots.size() - 1)]
			p.start_flying(s + Vector3.UP * pr.span, rng.randf_range(-PI, PI), 0.0)
			pos = p.model.position
		if not (FlightMath.vfinite(pos) and FlightMath.vfinite(p.model.velocity) and FlightMath.vfinite(p.camera.global_position)):
			st["nan"] += 1
			continue
		var b := p.global_basis
		var ob := p.origin.global_basis
		if b.y.dot(Vector3.UP) < 1.0 - 1e-6 or ob.y.dot(Vector3.UP) < 1.0 - 1e-6 or absf(b.determinant() - 1.0) > 1e-5 \
				or not p.origin.transform.basis.is_equal_approx(Basis.IDENTITY):
			st["basis_bad"] += 1
		if p.yaw_flagged:
			skip = 2
		elif skip > 0:
			skip -= 1
		else:
			st["max_rate"] = maxf(st["max_rate"], absf(p.rig_yaw_rate))
			st["max_acc"] = maxf(st["max_acc"], absf(p.rig_yaw_rate - prev_rate) / dt)
		prev_rate = p.rig_yaw_rate
		if p.perched != _rest_mode(p):
			st["perched_bad"] += 1
			if str(st["first"]).is_empty():
				st["first"] = "t=%.2f mode %s perched %s contacts %s" % [t, p.mode_name(), p.perched, p.contacts]
		if p.mode != PlayerBird.Mode.GROUNDED and p._run_v != Vector3.ZERO:
			st["runv_bad"] += 1
		var want := pos + p.view_offset()
		st["cam_err"] = maxf(st["cam_err"], p.camera.global_position.distance_to(want))
		if p.mode == PlayerBird.Mode.GROUNDED:
			st["grounded"] += 1
			var hit := _floor_below(p)
			if hit.is_empty():
				st["ground_bad"] += 1
				if not st.has("gb_first"):
					st["gb_first"] = "t=%.3f pos %s: no floor within 3 r_body below; run_v %s ground_n %s; GROUNDED ticks so far %d, next mode checked below" % [t, pos, p._run_v, p._ground_n, st["grounded"]]
					st["gb_tick"] = i
			else:
				var ng: Vector3 = hit["normal"]
				var want_y := float(hit["position"].y) + pr.r_body / maxf(ng.y, 0.1)
				if ng.y <= 0.7 or absf(pos.y - want_y) > 0.01:
					st["ground_bad"] += 1
					if not st.has("gb_first"):
						st["gb_first"] = "t=%.3f pos %s y-want %.4f n %s hit %s run_v %s ground_n %s" % [t, pos, pos.y - want_y, ng, hit["position"], p._run_v, p._ground_n]
		if p.mode != PlayerBird.Mode.PERCHED and _inside_geometry(p, 0.003):
			st["inside"] += 1
		if st.has("gb_tick") and i == int(st["gb_tick"]) + 1:
			st["gb_first"] = str(st["gb_first"]) + " -> next tick mode " + p.mode_name()
		if p.mode != prev_mode:
			if p.mode == PlayerBird.Mode.GROUNDED:
				st["td"] += 1
			if p.mode == PlayerBird.Mode.STUNNED:
				st["stun"] += 1
		prev_mode = p.mode
	st["ticks"] = i
	st["to"] = fx.events["took_off"]
	await _done()
	return st


func test_r7_random_play_over_slopes_and_roofs() -> void:
	var tot_td := 0
	for sp in S3:
		for seed_v in [71, 72]:
			var r: Dictionary = await _random_play(sp, seed_v, 40.0)
			var tag := "%s seed %d" % [sp, seed_v]
			_log("%s: ticks %d, touchdowns %d, took_off %d, stuns %d, grounded ticks %d | perched!=mode %d (%s) | run_v outside GROUNDED %d | cam err %.6f m | GROUNDED off a floor %d | inside geometry %d | rate %.1f deg/s acc %.1f deg/s^2 | NaN %d | basis %d" % [
				tag, r["ticks"], r["td"], r["to"], r["stun"], r["grounded"], r["perched_bad"], r["first"], r["runv_bad"],
				r["cam_err"], r["ground_bad"], r["inside"], rad_to_deg(r["max_rate"]), rad_to_deg(r["max_acc"]), r["nan"], r["basis_bad"]])
			tot_td += int(r["td"])
			eq(r["nan"], 0, "%s: no NaN" % tag)
			eq(r["basis_bad"], 0, "%s: rig pure yaw, unit scale" % tag)
			lt(rad_to_deg(r["max_rate"]), 240.0 + 0.01, "%s: rig yaw rate <= 240 deg/s" % tag)
			lt(rad_to_deg(r["max_acc"]), 720.0 + 0.5, "%s: rig yaw accel <= 720 deg/s^2" % tag)
			eq(r["perched_bad"], 0, "%s: Bird.perched agrees with the mode (%s)" % [tag, r["first"]])
			eq(r["runv_bad"], 0, "%s: no run-out velocity outside GROUNDED" % tag)
			lt(float(r["cam_err"]), 0.001, "%s: camera = body + view_offset() (m)" % tag)
			eq(r["ground_bad"], 0, "%s: GROUNDED only standing on a floor (%s)" % [tag, r.get("gb_first", "")])
			eq(r["inside"], 0, "%s: the body never inside geometry by more than 3 mm" % tag)
	gt(tot_td, 5, "random play touched down several times (%d)" % tot_td)


# --- 2b. running off an edge: one landing, one departure ---------------------------------------
## A touchdown that runs out off a platform's edge (straight ahead, and
## obliquely off its side): after the run-off, is the bird caught by its feet
## on the edge again (a second player_perched, a GROUNDED tick with nothing
## under the body)?
func test_r7_run_off_an_edge_is_one_landing() -> void:
	var tot_extra := 0
	for sp in S3:
		for yaw_deg: float in [0.0, 60.0, 85.0]:
			var pr0 := FlightParams.derive(FlightParams.species_mass(sp), FlightTuning.default_tuning())
			var d_exp := pr0.v_min * pr0.v_min / (2.0 * 0.6 * FlightMath.G)
			var edge := 0.4 * d_exp
			await _fx(sp, func(w: Variant) -> void:
				w.with_ground = false
				# The platform's -Z edge at z = -edge, its -X side at x = -edge.
				w.add_wall(Vector3(-edge + 10.0, 9.5, -edge + 10.0), Vector3(20.0, 1.0, 20.0)))
			var p := fx.player
			var pr := p.model.params
			var yaw := yaw_deg * DEG
			var start := Vector3(0, 10.0 + pr.r_body + 0.02, 0)
			p.start_flying(start, yaw, 0.0)
			p.model.reset(start, FlightMath.yaw_forward(yaw) * pr.v_min + Vector3.DOWN * 0.05 * pr.v_min, yaw)
			var st := {"grounded": false, "off": false, "extra_perched": 0, "pe_at_off": 0, "no_floor": 0, "flips": 0, "prev": -1}
			fx.on_tick = func(_i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if pl.mode == PlayerBird.Mode.GROUNDED:
					st["grounded"] = true
					if _floor_below(pl).is_empty():
						st["no_floor"] += 1
				elif bool(st["grounded"]) and not bool(st["off"]) and pl.mode == PlayerBird.Mode.FLYING:
					st["off"] = true
					st["pe_at_off"] = f.events["perched"]
				if bool(st["off"]) and int(st["prev"]) != int(pl.mode) and pl.mode == PlayerBird.Mode.GROUNDED:
					st["flips"] += 1
				st["prev"] = int(pl.mode)
			fx.run(1.5)
			var extra: int = int(fx.events["perched"]) - int(st["pe_at_off"]) if bool(st["off"]) else 0
			tot_extra += extra + int(st["no_floor"])
			_log("%s runs off an edge %.0f deg off its normal: off %s, player_perched in all %d (1 = the touchdown), after the run-off %d (GROUNDED again %d times), GROUNDED ticks with no floor under the body %d, final mode %s, y %.2f" % [
				sp, yaw_deg, st["off"], fx.events["perched"], extra, st["flips"], st["no_floor"], p.mode_name(), p.model.position.y])
			eq(int(fx.events["perched"]), 1, "%s %.0f deg: one player_perched for one touchdown and a run-off" % [sp, yaw_deg])
			check(bool(st["off"]), "%s %.0f deg: ran off the edge" % [sp, yaw_deg])
			eq(extra, 0, "%s %.0f deg: no second touchdown on the edge it ran off" % [sp, yaw_deg])
			eq(int(st["no_floor"]), 0, "%s %.0f deg: never GROUNDED with nothing under the body" % [sp, yaw_deg])
			await _done()
	metric("extra", tot_extra)


# --- 2c. a run-out into a wall ------------------------------------------------------------
## A touchdown on the flat that runs into a wall (head-on and
## obliquely) at 0.4 of its run-out distance. The run-out's wall handling
## removes the speed into the wall in one tick (no legs, no stun, no
## player_collided); flying into the same wall at that speed stuns.
func test_r7_run_out_into_a_wall() -> void:
	for sp in S3:
		for inc_deg: float in [90.0, 45.0]:
			var pr0 := FlightParams.derive(FlightParams.species_mass(sp), FlightTuning.default_tuning())
			var d_exp := pr0.v_min * pr0.v_min / (2.0 * 0.6 * FlightMath.G)
			var wall_z := -0.4 * d_exp * sin(inc_deg * DEG) - pr0.r_body
			await _fx(sp, func(w: Variant) -> void:
				w.add_wall(Vector3(0, 1.0, wall_z - 0.5), Vector3(60, 2.0, 1.0)))
			var p := fx.player
			var pr := p.model.params
			var yaw := (90.0 - inc_deg) * DEG
			var dir := FlightMath.yaw_forward(-yaw)
			var start := Vector3(0, pr.r_body + 0.02, 0)
			p.start_flying(start, FlightMath.yaw_of(dir), 0.0)
			var v0 := dir * pr.v_min + Vector3.DOWN * 0.05 * pr.v_min
			p.model.reset(start, v0, FlightMath.yaw_of(dir))
			var st := {"last": p.camera.global_position, "lastv": v0, "worst_dv": 0.0, "td": false, "v_td": 0.0, "v_wall": 0.0, "prevv": Vector3.ZERO}
			fx.on_tick = func(_i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				var c := pl.camera.global_position
				var v: Vector3 = (c - st["last"]) / DT
				if bool(st["td"]):
					var dv: float = (v - (st["lastv"] as Vector3)).length()
					if dv > float(st["worst_dv"]):
						st["worst_dv"] = dv
						st["v_wall"] = (st["lastv"] as Vector3).length()
				if pl.mode == PlayerBird.Mode.GROUNDED and not bool(st["td"]):
					st["td"] = true
					st["v_td"] = pl.model.velocity.length()
				st["lastv"] = v
				st["last"] = c
			fx.run(2.5)
			_log("%s run-out into a wall at %.0f deg: touchdown %.2f m/s, worst per-tick view dv after it %.2f m/s (%.2f x the touchdown speed; speed before it %.2f m/s), stuns %d, collided events %d, mode %s" % [
				sp, inc_deg, st["v_td"], st["worst_dv"], float(st["worst_dv"]) / maxf(float(st["v_td"]), 1e-3), st["v_wall"], p.contacts["stun"], fx.events["collided"], p.mode_name()])
			metric("%s_%d_ratio" % [sp, int(inc_deg)], float(st["worst_dv"]) / maxf(float(st["v_td"]), 1e-3))
			# The area's own comfort bound for touchdowns and run-outs (G1, G3e).
			lt(float(st["worst_dv"]) / maxf(float(st["v_td"]), 1e-3), 0.45, "%s %.0f deg: a run-out into a wall stops the view within G1's 0.45 x the touchdown speed per tick" % [sp, inc_deg])
			if float(st["v_wall"]) * sin(inc_deg * DEG) > 2.0:
				gt(int(fx.events["collided"]), 0, "%s %.0f deg: a %.1f m/s run into a wall is reported (player_collided)" % [sp, inc_deg, float(st["v_wall"]) * sin(inc_deg * DEG)])
			await _done()


# --- 2d. a run-out from the flat into a steep slope ----------------------------------------------
## G3e runs the flat into a 20 deg hill (0.34 of the speed into it); here a
## 38 deg roof-like slope from the ground: the legs must take ~0.6 of the
## run's speed into it (the "_legs_absorb" in _run_out), within G1's 0.45.
func test_r7_run_into_a_steep_slope() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			FlightGeometry.box(w, Vector3(0, 29.5, 50.0), Vector3(120, 1.0, 100.0), FlightGeometry.C_GROUND, false)
			FlightGeometry.slope(w, Vector3(0, 30.0, 0), 38.0, Vector2(120.0, 200.0), FlightGeometry.C_GROUND, false))
		var p := fx.player
		var pr := p.model.params
		var start := Vector3(0, 30.0 + pr.r_body + 0.02, 0.35 * pr.v_min * pr.v_min / (2.0 * 0.6 * FlightMath.G))
		p.start_flying(start, 0.0, 0.0)
		var v0 := Vector3(0, -0.05, -1.0) * pr.v_min
		p.model.reset(start, v0, 0.0)
		var st := {"last": p.camera.global_position, "lastv": v0, "worst_dv": 0.0, "hill": false}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var pl: PlayerBird = f.player
			var c := pl.camera.global_position
			var v: Vector3 = (c - st["last"]) / DT
			var dv: float = (v - (st["lastv"] as Vector3)).length()
			st["worst_dv"] = maxf(st["worst_dv"], dv)
			st["lastv"] = v
			st["last"] = c
			if pl.model.position.z < 0.0:
				st["hill"] = true
		fx.run(2.5)
		var ratio := float(st["worst_dv"]) / v0.length()
		_log("%s runs from the flat into a 38 deg slope: onto it %s, worst per-tick view dv %.3f x the touchdown speed, stuns %d, mode %s" % [
			sp, st["hill"], ratio, p.contacts["stun"], p.mode_name()])
		check(bool(st["hill"]), "%s: ran onto the slope" % sp)
		lt(ratio, 0.45, "%s: per-tick view velocity change <= 0.45 x the touchdown speed" % sp)
		await _done()


# --- 3. altitude_agl on a flat roof -------------------------------------------------------
func test_r7_altitude_agl_over_a_flat_roof() -> void:
	var roof_y := 25.0
	await _fx(&"pigeon", func(w: Variant) -> void:
		w.add_wall(Vector3(0, roof_y * 0.5, 0), Vector3(30.0, roof_y, 30.0)))
	var p := fx.player
	var pr := p.model.params
	# Flying a span above the roof, then landed on it.
	p.start_flying(Vector3(0, roof_y + pr.span, 5), 0.0, 0.0)
	fx.step()
	var tel := p.telemetry()
	var fly_tel := float(tel["altitude_agl"])
	var fly_env := p.env.agl
	var start := Vector3(0, roof_y + pr.r_body + 0.05, 5)
	p.model.reset(start, Vector3(0, -0.2, -0.6) * pr.v_min, 0.0)
	fx.run(2.0)
	tel = p.telemetry()
	var gnd_tel := float(tel["altitude_agl"])
	var gnd_env := p.env.agl
	_log("flat roof 25 m: flying 1 span up: telemetry altitude_agl %.2f m, FlightEnv.agl (the guard's ray) %.2f m | %s on the roof: altitude_agl %.2f m, env.agl %.2f m" % [
		fly_tel, fly_env, p.mode_name(), gnd_tel, gnd_env])
	eq(p.mode, PlayerBird.Mode.GROUNDED, "standing on the roof")
	lt(absf(fly_tel - (fly_env + pr.r_body)), 0.5, "telemetry altitude_agl over a flat roof agrees with the guard's ground ray (m)")
	lt(gnd_tel, 0.5, "standing on a roof, telemetry altitude_agl is ~0 (m)")


# --- 4. determinism of a slope take-off -------------------------------------------------------
func _slope_takeoff_trace(sp: StringName, deg: float, pre_flight: bool) -> PackedFloat64Array:
	await _fx(sp, func(w: Variant) -> void:
		FlightGeometry.slope(w, Vector3(0, 30.0, 0), deg, Vector2(120.0, 900.0), FlightGeometry.C_GROUND, false))
	var p := fx.player
	var pr := p.model.params
	if pre_flight:
		p.start_flying(Vector3(40, 200, 0), 1.0, 0.0)
		fx.run(1.0)
	var z0 := -2.0 * pr.span
	var start := Vector3(0, 30.0 - z0 * tan(deg * DEG) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, -0.2, -0.3) * pr.v_min, 0.0)
	fx.run(1.5)
	var t0 := fx.src.tick * DT
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t - t0 + 0.5, 45.0, 1.3)
	var out := PackedFloat64Array()
	fx.on_tick = func(_i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var q := pl.model.position
		var c := pl.camera.global_position
		out.append_array([q.x, q.y, q.z, c.x, c.y, c.z, pl.rig_yaw, float(pl.mode)])
	fx.run(4.0)
	await _done()
	return out


func test_r7_slope_takeoff_is_deterministic() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		var a: PackedFloat64Array = await _slope_takeoff_trace(sp, 38.0, false)
		var b: PackedFloat64Array = await _slope_takeoff_trace(sp, 38.0, false)
		var c: PackedFloat64Array = await _slope_takeoff_trace(sp, 38.0, true)
		var d_ab := -1
		var d_ac := -1
		for i in mini(a.size(), b.size()):
			if a[i] != b[i]:
				d_ab = i
				break
		for i in mini(a.size(), c.size()):
			if a[i] != c[i]:
				d_ac = i
				break
		_log("%s slope take-off determinism: samples %d, first difference repeat %d, after an unrelated flight %d" % [sp, a.size(), d_ab, d_ac])
		eq(d_ab, -1, "%s: bit-identical when repeated" % sp)
		eq(d_ac, -1, "%s: bit-identical after an unrelated flight" % sp)


# --- 5. steep downhill touchdown -------------------------------------------------------------
func test_r7_steep_downhill_run_out_brakes() -> void:
	var mu := FlightTuning.default_tuning().ground_friction
	var bmin := FlightTuning.default_tuning().run_brake_min
	for sp in S3:
		for deg: float in [-35.0, -44.0]:
			await _fx(sp, func(w: Variant) -> void:
				FlightGeometry.slope(w, Vector3(0, 300.0, 0), deg, Vector2(120.0, 900.0), FlightGeometry.C_GROUND, false))
			var p := fx.player
			var pr := p.model.params
			var z0 := 2.0 * pr.span
			var start := Vector3(0, 300.0 - z0 * tan(deg * DEG) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
			p.start_flying(start, 0.0, 0.0)
			var n := FlightGeometry.slope_normal(deg)
			var down := Vector3(0, sin(deg * DEG), -cos(deg * DEG))
			var v0 := down * 0.9 * pr.v_min - n * 0.1 * pr.v_min
			p.model.reset(start, v0, 0.0)
			var st := {"td": -1, "rest": -1, "grow": 0, "prev": -1.0, "v_td": 0.0, "min_dec": INF}
			fx.on_tick = func(i: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if pl.mode != PlayerBird.Mode.GROUNDED:
					st["prev"] = -1.0
					return
				var sp1 := pl.model.velocity.length()
				if int(st["td"]) < 0:
					st["td"] = i
					st["v_td"] = sp1
				elif float(st["prev"]) > 0.0:
					if sp1 > float(st["prev"]) + 1e-6:
						st["grow"] += 1
					if sp1 > 0.0:
						st["min_dec"] = minf(st["min_dec"], (float(st["prev"]) - sp1) / DT)
				if sp1 < 1e-6 and int(st["rest"]) < 0:
					st["rest"] = i
				st["prev"] = sp1
			fx.run(8.0)
			var tag := "%s touching down facing down a %.0f deg slope" % [sp, -deg]
			var rest_s := (int(st["rest"]) - int(st["td"])) * DT if int(st["rest"]) >= 0 else INF
			var a_exp := bmin * mu * FlightMath.G
			_log("%s: touchdown at %.2f m/s, rest after %.2f s (v/a_min = %.2f s), speed grew on %d ticks, min deceleration %.2f m/s^2 (floor %.2f), mode %s, stuns %d" % [
				tag, st["v_td"], rest_s, float(st["v_td"]) / a_exp, st["grow"], st["min_dec"], a_exp, p.mode_name(), p.contacts["stun"]])
			check(int(st["td"]) >= 0, "%s: touched down" % tag)
			eq(int(st["grow"]), 0, "%s: the run-out never speeds up on the feet" % tag)
			lt(rest_s, 1.05 * float(st["v_td"]) / a_exp + 0.1, "%s: at rest within v / (run_brake_min mu g) (s)" % tag)
			await _done()


# --- 6. tick cost ---------------------------------------------------------------------------
func _cost(sp: StringName, setup: Callable, secs: float) -> Dictionary:
	await _fx(sp)
	var p := fx.player
	setup.call(p)
	fx.run(0.5)
	var us := PackedFloat64Array()
	fx.on_tick = func(_i: int, f: Variant) -> void:
		us.append(f.player.tick_us)
	fx.run(secs)
	us.sort()
	var m := p.mode_name()
	await _done()
	return {"median": us[us.size() / 2], "p90": us[int(us.size() * 0.9)], "mode": m}


func test_r7_tick_cost_near_the_ground() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		var hi: Dictionary = await _cost(sp, func(p: PlayerBird) -> void:
			p.start_flying(Vector3(0, 300, 0), 0.0, 0.0), 3.0)
		var low: Dictionary = await _cost(sp, func(p: PlayerBird) -> void:
			var pr := p.model.params
			p.start_flying(Vector3(0, pr.r_body * 3.0, 0), 0.0, 0.0)
			p.model.reset(Vector3(0, pr.r_body * 3.0, 0), Vector3(0, 0.0, -1.0) * pr.v_min, 0.0), 3.0)
		_log("%s tick cost: cruise at 300 m median %.0f us (p90 %.0f); near the ground (%s at the end) median %.0f us (p90 %.0f)" % [
			sp, hi["median"], hi["p90"], low["mode"], low["median"], low["p90"]])
		lt(float(low["median"]), 1000.0, "%s: near-ground tick median under 1 ms" % sp)


# --- 7. respawn in the middle of a leg bend ------------------------------------------------
func test_r7_respawn_mid_bend_puts_the_camera_back_on_the_body() -> void:
	for sp: StringName in [&"sparrow", &"eagle"]:
		await _fx(sp, func(w: Variant) -> void:
			FlightGeometry.slope(w, Vector3(0, 30.0, 0), 38.0, Vector2(120.0, 900.0), FlightGeometry.C_GROUND, false))
		var p := fx.player
		var pr := p.model.params
		var z0 := -2.0 * pr.span
		var start := Vector3(0, 30.0 - z0 * tan(38.0 * DEG) + (pr.r_body + 0.1) / cos(38.0 * DEG), z0)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, -0.15, -1.1) * pr.v_min, 0.0)
		var guard := 0
		while p.mode != PlayerBird.Mode.GROUNDED and guard < 200:
			fx.step()
			guard += 1
		fx.step()
		var off_before := p.view_offset().length()
		p.respawn(Transform3D(Basis.IDENTITY, Vector3(50, 120, 50)))
		var err := p.camera.global_position.distance_to(p.model.position)
		var tel := p.telemetry()
		_log("%s respawn mid-bend: view offset before %.4f m, after %.6f m, camera error %.6f m, telemetry heave_offset %.6f, mode %s, perched %s" % [
			sp, off_before, p.view_offset().length(), err, float(tel["heave_offset"]), p.mode_name(), p.perched])
		gt(off_before, 1e-4, "%s: the legs were bending" % sp)
		lt(err, 0.001, "%s: after respawn the camera is on the body (m)" % sp)
		lt(p.view_offset().length(), 1e-6, "%s: no view offset after respawn" % sp)
		eq(p.perched, false, "%s: not perched after respawn in the air" % sp)
		fx.step()
		lt(p.camera.global_position.distance_to(p.model.position + p.view_offset()), 0.001, "%s: next tick camera = body + view_offset" % sp)
		lt(p.view_offset().length(), 1e-6, "%s: next tick no leftover leg bend" % sp)
		await _done()


# --- 8. wrap_angle seam -------------------------------------------------------------------
func test_r7_wrap_angle_stays_in_range() -> void:
	var worst := -INF
	var bad := 0
	var probes: Array[float] = []
	for k in range(-4, 5):
		probes.append(-PI + k * 4.440892098500626e-16)
		probes.append(PI + k * 4.440892098500626e-16)
		probes.append(-3.0 * PI + k * 1.3322676295501878e-15)
		probes.append(3.0 * PI + k * 1.3322676295501878e-15)
	for a in probes:
		var w := FlightMath.wrap_angle(a)
		worst = maxf(worst, w)
		if w >= PI or w < -PI:
			bad += 1
	_log("wrap_angle near the seam: %d of %d results outside [-PI, PI), largest %.17f (PI %.17f)" % [bad, probes.size(), worst, PI])
	eq(bad, 0, "wrap_angle stays in [-PI, PI) at the seam")
