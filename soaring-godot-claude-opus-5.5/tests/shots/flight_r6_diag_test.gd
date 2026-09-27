extends TestCase
## Fix-round-6 diagnostics (on demand, not the unit suite): slopes, roofs,
## the feet's reach, take-offs facing uphill.
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_r6_diag --test=<name>

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


## How Jolt's cast_motion reports a sphere that starts overlapping a floor.
func test_diag_cast_overlap() -> void:
	fx = FX.new(self)
	await fx.setup(&"sparrow")
	var space := fx.player.get_world_3d().direct_space_state
	var sph := SphereShape3D.new()
	sph.radius = 0.1
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sph
	q.collision_mask = 1
	for y: float in [0.2, 0.101, 0.1, 0.099, 0.09, 0.05]:
		for m: Vector3 in [Vector3(0, -0.05, 0), Vector3(0.05, 0, 0), Vector3(0, 0.05, 0), Vector3(0.05, -0.01, 0)]:
			q.transform = Transform3D(Basis.IDENTITY, Vector3(0, y, 0))
			q.motion = m
			var r := space.cast_motion(q)
			q.motion = Vector3.ZERO
			var info := space.get_rest_info(q)
			print("[flight] y %.3f motion %s -> cast %s rest %s" % [y, m, r, "{}" if info.is_empty() else str(info["point"]) + " n " + str(info["normal"])])
	check(true, "diag")


const H0 := 30.0


## A planar slab through (0, H0, 0) rising toward -Z at `deg` (the r6x
## verifier's slope).
static func slope_setup(deg: float) -> Callable:
	return func(w: Variant) -> void:
		var b := Basis(Vector3.RIGHT, deg * DEG)
		var n := b * Vector3.UP
		FlightGeometry.box(w, Vector3(0, H0, 0) - n * 0.5, Vector3(120, 1.0, 900), FlightGeometry.C_WALL, false,
			FlightGeometry.LAYER_WORLD, b, "Slope")


static func surf_y(deg: float, z: float) -> float:
	return H0 - z * tan(deg * DEG)


## A touchdown on a slope, traced tick by tick (--species, --deg, --yaw,
## --vf, --vs, --gap).
func test_diag_slope_touchdown() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var deg := float(Paths.arg("deg", "38"))
	var yaw := float(Paths.arg("yaw", "60")) * DEG
	var vf := float(Paths.arg("vf", "0.6"))
	var vs := float(Paths.arg("vs", "0.2"))
	var gap := float(Paths.arg("gap", "0.25"))
	fx = FX.new(self)
	await fx.setup(sp, slope_setup(deg))
	var p := fx.player
	var pr := p.model.params
	var z0 := -2.0 * pr.span
	var start := Vector3(0, surf_y(deg, z0) + (pr.r_body + gap) / cos(deg * DEG), z0)
	p.start_flying(start, yaw, 0.0)
	var v0 := FlightMath.yaw_forward(yaw) * vf * pr.v_min + Vector3.DOWN * vs * pr.v_min
	p.model.reset(start, v0, yaw)
	var st := {"last": p.camera.global_position, "lastv": v0}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var c := pl.camera.global_position
		var v: Vector3 = (c - st["last"]) / DT
		var dv: Vector3 = v - st["lastv"]
		st["last"] = c
		st["lastv"] = v
		if i < 60:
			print("[flight] %2d %-8s body %s vb %s cam_v %s dv %.2f (%.2f x) legs debt %.4f rate %.2f acc %.1f n %s gn %s contact %d" % [i, pl.mode_name(),
				pl.model.position.snapped(Vector3.ONE * 0.001), pl.model.velocity.snapped(Vector3.ONE * 0.01), v.snapped(Vector3.ONE * 0.01),
				dv.length(), dv.length() / v0.length(), pl._legs.debt, pl._legs.rate, pl._legs.max_acc, pl._leg_n.snapped(Vector3.ONE * 0.01),
				pl._ground_n.snapped(Vector3.ONE * 0.01), pl.last_contact])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(1.0)
	check(true, "diag")


## Grounded on a slope facing uphill (the r6x set-up), then strokes; traced
## every --every ticks (--species, --deg, --yaw, --hz, --amp, --twist, --roll).
func test_diag_slope_takeoff() -> void:
	var sp := StringName(Paths.arg("species", "eagle"))
	var deg := float(Paths.arg("deg", "38"))
	var yaw := float(Paths.arg("yaw", "0")) * DEG
	var hz := float(Paths.arg("hz", "1.3"))
	var amp := float(Paths.arg("amp", "45"))
	var tw := float(Paths.arg("twist", "0")) * DEG
	var roll := float(Paths.arg("roll", "0"))
	var secs := float(Paths.arg("secs", "6"))
	var every := int(Paths.arg("every", "9"))
	fx = FX.new(self)
	await fx.setup(sp, slope_setup(deg))
	var p := fx.player
	var pr := p.model.params
	var z0 := -2.0 * pr.span
	var start := Vector3(0, surf_y(deg, z0) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
	p.start_flying(start, yaw, 0.0)
	p.model.reset(start, FlightMath.yaw_forward(yaw) * 0.3 * pr.v_min + Vector3.DOWN * 0.2 * pr.v_min, yaw)
	fx.run(2.0)
	print("[flight] %s on %.0f deg: mode %s" % [sp, deg, p.mode_name()])
	var cal := p.wing_input.calibration
	var t0 := fx.src.tick * DT if Paths.arg("phase0", "") != "" else 0.0
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if roll != 0.0 and t > 1.0:
			b.synth(0.0, roll, 1.0, cal)
		ScriptedPoseSource.flap(b, t - t0 + 0.5, amp, hz)
		for a in b.arms:
			a.twist += tw
	fx.reset_events()
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if i % every == 0 or pl.last_contact != PlayerBird.Contact.NONE:
			var pos := pl.model.position
			var clear := (pos.y - surf_y(deg, pos.z)) * cos(deg * DEG) - pr.r_body
			print("[flight] t %.2f %-8s clear %.2f spans pos %s v %s V %.2f V_min hdg %4.0f th %5.1f al %5.1f flapping %.2f hold %.2f agl %.2f gn %.2f contact %d ev to %d pe %d" % [
				i * DT, pl.mode_name(), clear / pr.span, pos.snapped(Vector3.ONE * 0.01), pl.model.velocity.snapped(Vector3.ONE * 0.01),
				pl.model.airspeed() / pr.v_min, rad_to_deg(pl.model.heading()), rad_to_deg(pl.model.theta), rad_to_deg(pl.model.alpha),
				pl.wing_state().flapping, pl._takeoff_t, pl.env.agl, pl.env.ground_normal.y, pl.last_contact, f.events["took_off"], f.events["perched"]])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(secs)
	check(true, "diag")


## A run up a 38 deg gable roof and over its ridge (G3e), traced.
func test_diag_ridge() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var ridge := Vector3(0, 12.0, 0)
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		FlightGeometry.gable_roof(w, ridge, 38.0, 4.0, 20.0, FlightGeometry.C_FRAME, false))
	var p := fx.player
	var pr := p.model.params
	var nf := FlightGeometry.slope_normal(38.0)
	var zl := 0.6 * pr.span
	var surf := Vector3(0, ridge.y - zl * tan(38.0 * DEG), zl)
	var start := surf + nf * (pr.r_body + 0.02)
	p.start_flying(start, 0.0, 0.0)
	var v0 := Vector3(0, 0.0, -1.0) * pr.v_min
	p.model.reset(start, v0, 0.0)
	p.debug_contacts = Paths.arg("debug", "") != ""
	print("[flight] start %s r %.4f" % [start, pr.r_body])
	var st := {"last": p.camera.global_position, "lastv": v0}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var c := pl.camera.global_position
		var v: Vector3 = (c - st["last"]) / DT
		var dv: Vector3 = v - st["lastv"]
		st["last"] = c
		st["lastv"] = v
		if i < 50:
			print("[flight] %2d %-8s body %s vb %s cam_v %s dv %.2f (%.2f x) legs %.4f/%.2f gn %s contact %d" % [i, pl.mode_name(),
				pl.model.position.snapped(Vector3.ONE * 0.001), pl.model.velocity.snapped(Vector3.ONE * 0.01), v.snapped(Vector3.ONE * 0.01),
				dv.length(), dv.length() / v0.length(), pl._legs.debt, pl._legs.rate, pl._ground_n.snapped(Vector3.ONE * 0.01), pl.last_contact])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(1.0)
	check(true, "diag")


## Where a player tick's time goes (fix round 6: the suite's CPU budget).
func test_diag_tick_cost() -> void:
	var sp := StringName(Paths.arg("species", "pigeon"))
	var n := int(Paths.arg("n", "3000"))
	fx = FX.new(self)
	await fx.setup(sp)
	var p := fx.player
	p.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t, 45.0, 1.3)
	fx.run(1.0)
	var whole := INF
	for rep in 5:
		var t00 := Time.get_ticks_usec()
		for i in n / 5:
			p.tick(DT)
		whole = minf(whole, float(Time.get_ticks_usec() - t00) / (n / 5))
	var m_best := INF
	for rep in 5:
		var t01 := Time.get_ticks_usec()
		for i in n / 5:
			p.model.step(p._ws, p.env, DT)
		m_best = minf(m_best, float(Time.get_ticks_usec() - t01) / (n / 5))
	print("[flight] model.step with the tick's own ws and env: %.1f us (best of 5)" % m_best)
	var t0 := 0
	var fr := PoseFrame.new()
	t0 = Time.get_ticks_usec()
	for i in n:
		fx.src.sample(fr, DT)
	var sample := float(Time.get_ticks_usec() - t0) / n
	var body := HumanPoseModel.new(1)
	body.set_airplane()
	t0 = Time.get_ticks_usec()
	for i in n:
		body.set_airplane()
		ScriptedPoseSource.flap(body, i * DT, 45.0, 1.3)
		body.frame(fr)
	var body_frame := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p.wing_input.update(fr, DT)
	var wi := float(Time.get_ticks_usec() - t0) / n
	var ws := p.wing_input.state
	var m := FlightModel.new(p.model.params.mass, p.tuning)
	m.trim(Vector3(0, 300, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	t0 = Time.get_ticks_usec()
	for i in n:
		m.step(ws, env, DT)
	var model := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._build_env()
	var benv := float(Time.get_ticks_usec() - t0) / n
	var a := p.model.position
	t0 = Time.get_ticks_usec()
	for i in n:
		p._sweep(a, a + Vector3(0, 0, -0.1))
		p.model.position = a
	var sweep := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._apply_rig(DT)
	var rig := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._wing_brush(DT)
	var brush := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		fx._monitor()
	var mon := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._write_nodes(p.origin.world_scale)
	var wn := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._try_capture(a, a + Vector3(0, 0, -0.1))
	var cap := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._drive_world_scale(DT)
	var dws := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p._emit_events()
	var ev := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p.global_transform = Transform3D(Basis(Vector3.UP, 0.1 * i), a)
	var gxf := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for i in n:
		p.origin.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.001 * (i % 7), 0))
	var oxf := float(Time.get_ticks_usec() - t0) / n
	print("[flight] write_nodes %.1f | try_capture %.1f | drive_ws %.1f | events %.1f | player global_transform %.1f | origin transform %.1f" % [wn, cap, dws, ev, gxf, oxf])
	print("[flight] %s us per tick: whole %.1f | pose sample %.1f (body+frame %.1f) | wing_input %.1f | model %.1f | build_env %.1f | sweep %.1f | rig %.1f | brush %.1f | fixture monitor %.1f" % [
		sp, whole, sample, body_frame, wi, model, benv, sweep, rig, brush, mon])
	check(true, "diag")


## Wall and CPU cost of a fixture's setup and teardown.
func test_diag_fixture_cost() -> void:
	var n := int(Paths.arg("n", "40"))
	var t0 := Time.get_ticks_usec()
	for i in n:
		fx = FX.new(self)
		await fx.setup(&"pigeon")
		fx.teardown()
		fx = null
	var per := float(Time.get_ticks_usec() - t0) / n / 1000.0
	print("[flight] fixture setup+teardown: %.1f ms wall each; physics ticks/s %d; max_fps %d" % [per, Engine.physics_ticks_per_second, Engine.max_fps])
	t0 = Time.get_ticks_usec()
	for i in n:
		await get_tree().physics_frame
	print("[flight] one physics_frame await: %.1f ms" % (float(Time.get_ticks_usec() - t0) / n / 1000.0))
	t0 = Time.get_ticks_usec()
	for i in n:
		await get_tree().process_frame
	print("[flight] one process_frame await: %.1f ms" % (float(Time.get_ticks_usec() - t0) / n / 1000.0))
	check(true, "diag")


## Does the space see a freshly added static body without waiting a physics frame?
func test_diag_space_immediate() -> void:
	var w := preload("res://tests/unit/flight/flight_test_world.gd").new()
	w.add_wall(Vector3(0, 5, -3), Vector3(10, 10, 1))
	add_child(w)
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(0, 10, 0), Vector3(0, -10, 0))
	var hit := space.intersect_ray(q)
	var q2 := PhysicsRayQueryParameters3D.create(Vector3(0, 5, 0), Vector3(0, 5, -10))
	var hit2 := space.intersect_ray(q2)
	var sph := SphereShape3D.new()
	sph.radius = 0.1
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = sph
	sq.transform = Transform3D(Basis.IDENTITY, Vector3(0, 5, 0))
	sq.motion = Vector3(0, 0, -10)
	var cm := space.cast_motion(sq)
	print("[flight] immediately: ground ray %s | wall ray %s | wall cast %s" % [not hit.is_empty(), not hit2.is_empty(), cm])
	await get_tree().physics_frame
	hit = space.intersect_ray(q)
	cm = space.cast_motion(sq)
	print("[flight] after one physics frame: ground ray %s | wall cast %s" % [not hit.is_empty(), cm])
	remove_child(w)
	w.free()
	check(true, "diag")


## The r5x ground glide (sparrow, pitch trim --trim, wrists --tw deg):
## the camera's and the body's vertical second differences while FLYING.
func test_diag_ground_glide_jerk() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var trim := float(Paths.arg("trim", "-0.4"))
	var tw := float(Paths.arg("tw", "-22"))
	fx = FX.new(self)
	await fx.setup(sp)
	var p := fx.player
	var pr := p.model.params
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, trim)
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.arms[0].twist = tw * DEG
		b.arms[1].twist = tw * DEG
	var st := {"c": [], "b": []}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var c: Array = st["c"]
		var bb: Array = st["b"]
		c.append(pl.camera.global_position.y)
		bb.append(pl.model.position.y)
		if c.size() > 3:
			c.pop_front()
			bb.pop_front()
		if c.size() == 3 and pl.mode == PlayerBird.Mode.FLYING:
			var cj: float = absf(float(c[2]) - 2.0 * float(c[1]) + float(c[0])) * 1000.0
			var bj: float = absf(float(bb[2]) - 2.0 * float(bb[1]) + float(bb[0])) * 1000.0
			if cj > 2.0 or bj > 2.0 or pl.last_contact != PlayerBird.Contact.NONE:
				print("[flight] t %.3f %s cam d2 %.2f mm body d2 %.2f mm contact %d vy %.2f legs %.4f/%.2f acc %.1f heave %.4f bend %s slides %d" % [i * DT, pl.mode_name(), cj, bj,
					pl.last_contact, pl.model.velocity.y, pl._legs.debt, pl._legs.rate, pl._legs.max_acc, pl.heave.offset, pl._leg_bend, pl.contacts["slide"]])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(15.0)
	check(true, "diag")
