extends TestCase
## Verifier probes (round 1, flight): F10 perching as a player would do it.
## Slow final approaches (1.0-1.4 V_min) from 8-12 spans with the perch off
## to the side / above / below, wrists flared, at sparrow, pigeon, gull and
## eagle size (the builder's P7 flies sparrow and pigeon only), with and
## without the grip held. Also measures what the camera does at the capture:
## the speed stopped in one tick and the ease-in slide to the grip point.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 20, -10)

var fx: FX
var _lines := PackedStringArray()


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("perch_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


func test_f10_player_like_perch_approaches() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 555
	for sp: StringName in [&"sparrow", &"pigeon", &"gull", &"eagle"]:
		for grip: bool in [false, true]:
			var ok := 0
			var n := 12
			var worst_snap := 0.0
			var worst_stop := 0.0
			var worst_step := 0.0
			for i in n:
				fx = FX.new(self)
				await fx.setup(sp, func(w: Variant) -> void:
					w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.02, 1.0))
				var p := fx.player
				var pr := p.model.params
				var off_x := rng.randf_range(-1.0, 1.0)
				var off_y := rng.randf_range(-0.5, 0.5)
				var back := rng.randf_range(8.0, 12.0)
				var v := rng.randf_range(1.0, 1.4) * pr.v_min
				var cal := p.wing_input.calibration
				fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					b.synth(0.8, 0.0, 1.0, cal)
					b.grip = Vector2(1, 1) if grip else Vector2.ZERO
				var target := PERCH + Vector3.UP * pr.r_body
				var start := target + Vector3(off_x * pr.span, (0.3 + off_y) * pr.span, back * pr.span)
				p.start_flying(start, 0.0, 0.0)
				p.model.reset(start, Vector3(0, 0, -v), 0.0)
				var st := {"perched": false, "v_before": 0.0, "cap_pos": Vector3.ZERO, "cam_prev": p.camera.global_position,
					"max_step": 0.0, "was_flying": true, "snap": 0.0}
				fx.on_tick = func(_tick: int, f: Variant) -> void:
					var pl: PlayerBird = f.player
					var cam: Vector3 = pl.camera.global_position
					var stp: float = cam.distance_to(st["cam_prev"])
					if pl.mode == PlayerBird.Mode.PERCHED and not st["perched"]:
						st["perched"] = true
						st["snap"] = pl._ease_from.distance_to(pl._perch_point(pl.perch))
					if st["perched"]:
						st["max_step"] = maxf(st["max_step"], stp)
					elif pl.mode == PlayerBird.Mode.FLYING:
						st["v_before"] = pl.model.velocity.length()
					st["cam_prev"] = cam
				fx.run(4.0)
				var ws := p.origin.world_scale
				if st["perched"]:
					ok += 1
					worst_snap = maxf(worst_snap, st["snap"] / ws)
					worst_stop = maxf(worst_stop, st["v_before"] / ws)
					worst_step = maxf(worst_step, st["max_step"] / ws / DT)
				fx.assert_comfort(self, "%s perch approach %d" % [sp, i])
				fx.teardown()
				fx = null
			var rate := float(ok) / n
			_lines.append("%s grip %s: perched %d / %d; worst perceived (world / world_scale): capture speed stopped in one tick %.2f m/s, ease-in slide %.2f m in 0.15 s (peak %.2f m/s)" % [
				sp, str(grip), ok, n, worst_stop, worst_snap, worst_step])
			metric("%s_grip_%s_rate" % [sp, str(grip)], rate)
			if grip:
				gt(rate, 0.9 - 1e-6, "%s: slow flared approaches with the grip held perch >= 90%%" % sp)
			else:
				gt(rate, 0.75 - 1e-6, "%s: slow flared approaches (no grip) perch >= 75%%" % sp)


func test_f10_perched_bird_launches_with_a_flap_every_size() -> void:
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.02, 1.0))
		var p := fx.player
		p.perch_on(fx.world.get_perches()[0])
		fx.run(1.0)
		eq(p.mode, PlayerBird.Mode.PERCHED, "%s: clings to the perch" % sp)
		var pos0 := p.model.position
		fx.run(3.0)
		lt(p.model.position.distance_to(pos0), 0.001, "%s: stays clinging while still (3 s)" % sp)
		var ts := fx.src.tick * DT
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			var tt := t - ts
			if tt < 1.2:
				ScriptedPoseSource.flap(b, tt + 0.5, 45.0, 1.0)
		var t0 := fx.ticks
		var st := {"t_fly": -1.0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			if st["t_fly"] < 0.0 and f.player.mode == PlayerBird.Mode.FLYING:
				st["t_fly"] = (tick - t0) * DT
		fx.run(3.0)
		check(st["t_fly"] >= 0.0 and st["t_fly"] < 1.5, "%s: one real stroke launches off the perch (%.2f s)" % [sp, st["t_fly"]])
		check(p.mode == PlayerBird.Mode.FLYING or p.mode == PlayerBird.Mode.PERCHED, "%s: flying after the launch (mode %s)" % [sp, p.mode_name()])
		_lines.append("%s launch at %.2f s, mode after 3 s %s, height change %.2f m" % [sp, st["t_fly"], p.mode_name(), p.model.position.y - pos0.y])
		fx.teardown()
		fx = null
