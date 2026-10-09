extends TestCase
## Fix-round-5 diagnostics (on demand, not the unit suite): ground landings,
## flares, hitches and resumes, traced tick by tick.
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_r5_diag --test=<name> [--species=sparrow] [--twist=40] [--h=1.0]

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func _contact_name(c: int) -> String:
	return ["none", "silent", "slide", "land", "stun"][c]


## A glide into flat ground from 6 spans + 2 m, optionally flaring (wrists
## +twist deg over 0.3 s) once the belly is below h spans. Prints a trace.
func test_diag_flare() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var tw := float(Paths.arg("twist", "40"))
	var fh := float(Paths.arg("h", "1.0"))
	var secs := float(Paths.arg("secs", "12"))
	var every := int(Paths.arg("every", "5"))
	fx = FX.new(self)
	await fx.setup(sp)
	var p := fx.player
	if Paths.arg("nodelib", "") != "":
		var tu := p.tuning.duplicate() as FlightTuning
		tu.deliberate_pitch = 5.0
		p.tuning = tu
		p.model.set_tuning(tu)
	if Paths.arg("preset", "") != "":
		var tu2 := p.tuning.duplicate() as FlightTuning
		tu2.preset = int(Paths.arg("preset", "1"))
		p.tuning = tu2
		p.model.set_tuning(tu2)
	var pr := p.model.params
	print("[flight] %s span %.3f r_body %.4f v_min %.2f v_c %.2f ws %.3f" % [sp, pr.span, pr.r_body, pr.v_min, pr.v_c, p.origin.world_scale])
	p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
	var st := {"flare_t": -1.0, "t_f": -1.0, "lastc": p.camera.global_position, "lastv": Vector3.ZERO, "worst": 0.0}
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if float(st["flare_t"]) >= 0.0:
			var k := clampf((t - float(st["flare_t"])) / 0.3, 0.0, 1.0)
			b.arms[0].twist = k * tw * DEG
			b.arms[1].twist = k * tw * DEG
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var belly: float = pl.model.position.y - pr.r_body
		if tw > 0.0 and float(st["flare_t"]) < 0.0 and belly < fh * pr.span:
			st["flare_t"] = fx.src.tick * DT
			st["t_f"] = i * DT
		var c := pl.camera.global_position
		var cv: Vector3 = (c - st["lastc"]) / DT
		var dvc: float = (cv - st["lastv"]).length() if i > 2 else 0.0
		st["worst"] = maxf(st["worst"], dvc)
		st["lastc"] = c
		st["lastv"] = cv
		if i % every == 0 or pl.last_contact != PlayerBird.Contact.NONE:
			print("[flight] t %.2f belly %.3f V %.2f V_min vy %+.2f vh %.2f alpha %5.1f th %5.1f stalled %s mode %s pitch_in %+.2f contact %s dv_cam %.2f heave %.3f" % [
				i * DT, belly, pl.model.airspeed() / pr.v_min, pl.model.velocity.y, Vector2(pl.model.velocity.x, pl.model.velocity.z).length(),
				rad_to_deg(pl.model.alpha), rad_to_deg(pl.model.theta), str(pl.model.stalled), pl.mode_name(), pl.wing_state().pitch,
				_contact_name(pl.last_contact), dvc, pl.heave_offset()])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(secs)
	print("[flight] %s twist %.0f h %.1f: stuns %d slides %d lands %d mode %s worst cam dv/tick %.2f m/s (%.1f perceived)" % [
		sp, tw, fh, p.contacts["stun"], p.contacts["slide"], p.contacts["land"], p.mode_name(), st["worst"], float(st["worst"]) / p.origin.world_scale])
	check(true, "diag")


## PB-11's slow shallow touchdown (0.6 V_min forward, 0.2 V_min down from
## 0.25 m), traced: the camera's per-tick velocity change.
func test_diag_touchdown() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	fx = FX.new(self)
	await fx.setup(sp)
	var p := fx.player
	var pr := p.model.params
	var start := Vector3(0, pr.r_body + 0.25, 0)
	p.start_flying(start, 0.0, 0.0)
	var v0 := Vector3(0, -0.2 * pr.v_min, -0.6 * pr.v_min)
	p.model.reset(start, v0, 0.0)
	var st := {"last": p.camera.global_position, "lastv": v0, "n": 0}
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		var c := pl.camera.global_position
		var v: Vector3 = (c - st["last"]) / DT
		var dv: Vector3 = v - st["lastv"] if int(st["n"]) > 0 else Vector3.ZERO
		st["n"] += 1
		st["last"] = c
		st["lastv"] = v
		print("[flight] t %.3f mode %s body_y %.4f cam_y %.4f v_cam (%.2f %.2f %.2f) dv %.2f (x %.2f) heave %.4f model_v (%.2f %.2f %.2f) contact %s" % [
			i * DT, pl.mode_name(), pl.model.position.y, c.y, v.x, v.y, v.z, dv.length(), dv.length() / v0.length(), pl.heave_offset(),
			pl.model.velocity.x, pl.model.velocity.y, pl.model.velocity.z, _contact_name(pl.last_contact)])
		pl.last_contact = PlayerBird.Contact.NONE
	fx.run(float(Paths.arg("secs", "1.0")))
	check(true, "diag")


## The round-3 verifier's perch-in-breeze approach (tests/probes/flight/
## r3_experience_probe_test.gd): a sparrow at 1.2 V_cap through the air,
## 6 spans out and 0.3 span above the grip, wrists slightly up, in a uniform
## 2.64 m/s wind (--wind=head|cross|tail).
func test_diag_breeze_perch() -> void:
	var sp := StringName(Paths.arg("species", "sparrow"))
	var wk := Paths.arg("wind", "head")
	var ws := float(Paths.arg("ws", "2.64"))
	var wind := Vector3(0, 0, ws) if wk == "head" else (Vector3(ws, 0, 0) if wk == "cross" else Vector3(0, 0, -ws))
	var perch_at := Vector3(0, 20, -10)
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.add_perch(perch_at, Vector3.FORWARD, 10.0, 0.015, 1.0)
		w.uniform_wind = wind)
	var p := fx.player
	var pr := p.model.params
	var vcap := 0.8 * pr.v_min
	var target := perch_at + Vector3.UP * pr.r_body
	var start := target + Vector3(0, 0.3 * pr.span, 6.0 * pr.span)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, 0, -1.2 * vcap) + wind, 0.0)
	fx.driver = fx.synth(float(Paths.arg("pitch", "0.3")), 0.0, 1.0)
	fx.on_tick = func(i: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		if i % int(Paths.arg("every", "3")) == 0 or pl.mode != PlayerBird.Mode.FLYING:
			var to := target - pl.model.position
			print("[flight] t %.3f mode %s to_perch (%.3f %.3f %.3f) |%.3f| air %.2f gnd %.2f land %.2f vcap %.2f vy %.2f accel (%.2f %.2f %.2f) bias %.3f drag %.2f cand %.2f heading %.1f contacts %s nocap %.2f" % [
				i * DT, pl.mode_name(), to.x, to.y, to.z, to.length(), pl.model.airspeed(), pl.model.velocity.length(), pl._landing_speed(), pl._v_cap(),
				pl.model.velocity.y, pl.env.accel.x, pl.env.accel.y, pl.env.accel.z, pl.env.alpha_bias, pl.env.drag_bonus, pl.perch_candidate_dist, rad_to_deg(pl.model.heading()),
				str(pl.contacts), pl._no_capture_t])
		if pl.mode == PlayerBird.Mode.PERCHED and i % 3 == 0:
			return
	fx.run(float(Paths.arg("secs", "4.0")))
	print("[flight] %s %s %.2f m/s: mode %s" % [sp, wk, ws, p.mode_name()])
	check(true, "diag")


## The round-3 verifier's perch set in one wind (--wind=cross|head|tail
## --ws=2.1): each approach's worst in-air rig yaw acceleration; the first
## above 600 deg/s^2 is replayed with a per-tick trace.
func test_diag_air_accel() -> void:
	const PW := preload("res://tests/unit/flight/perch_wind.gd")
	var sp := StringName(Paths.arg("species", "sparrow"))
	var wk := Paths.arg("wind", "cross")
	var ws := float(Paths.arg("ws", "2.1"))
	var wind := Vector3(0, 0, ws) if wk == "head" else (Vector3(ws, 0, 0) if wk == "cross" else Vector3(0, 0, -ws))
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.add_perch(PW.PERCH, Vector3.FORWARD, 10.0, 0.015, 1.0)
		w.uniform_wind = wind)
	var bad: Dictionary = {}
	for c: Dictionary in PW.verifier_set():
		var cc := c.duplicate()
		cc["air"] = float(c["air_vmin"]) * fx.player.model.params.v_min
		var r: Dictionary = PW.approach(fx, cc)
		if float(r["air_acc"]) > deg_to_rad(610.0):
			print("[flight] case %s: air accel %.0f deg/s^2, t %.2f" % [str(c), rad_to_deg(r["air_acc"]), r["t"]])
			if bad.is_empty():
				bad = cc
	if bad.is_empty():
		check(true, "none")
		return
	# Replay with a trace.
	var p := fx.player
	fx.on_tick = Callable()
	var pr := p.model.params
	var target := PW.PERCH + Vector3.UP * pr.r_body
	p.respawn(Transform3D(Basis.IDENTITY, PW.PERCH + Vector3(0, 200, 400)))
	var start := target + Vector3(0, float(bad["up"]) * pr.span, float(bad["back"]) * pr.span)
	p.start_flying(start, 0.0, 0.0)
	p.model.reset(start, Vector3(0, 0, -float(bad["air"])) + wind, 0.0)
	fx.driver = fx.synth(float(bad["pitch"]), 0.0, 1.0)
	for i in 200:
		var c0 := p.contacts.duplicate()
		fx.step()
		print("[flight] k %d mode %s rate %.1f acc %.0f ff %.1f vt %.1f debt %.2f forced %.2f limited %d slide %d silent %d accel (%.2f %.2f %.2f) head %.1f to %.3f" % [
			i, p.mode_name(), rad_to_deg(p.rig_yaw_rate), rad_to_deg(p.rig_yaw_accel), rad_to_deg(p._ff_rate), rad_to_deg(p.view_turn.rate),
			rad_to_deg(p.view_turn.debt), rad_to_deg(p.forced_turn), p.rig_limited_ticks, p.contacts["slide"] - int(c0["slide"]), p.contacts["silent"] - int(c0["silent"]),
			p.env.accel.x, p.env.accel.y, p.env.accel.z, rad_to_deg(p.model.heading()), p.model.position.distance_to(target)])
		if p.mode == PlayerBird.Mode.PERCHED:
			break
	check(true, "diag")
