extends TestCase
## Verifier (round 3): the round-2 stun-lock fix (C8) flies head-on only.
## Here the bird meets a wall OBLIQUELY at cruise with neutral airplane arms
## (a player who clips a building), at incidence 30-75 deg, every size, for
## 8 s. Pinned:
##  - at most one stun in 8 s (no bounce back into the same wall),
##  - after the stun the view and the bird agree: |rig yaw + torso yaw -
##    heading| < 10 deg 1 s after the stun ends (otherwise body steer reads
##    the stale view direction as the player's torso and steers the bird
##    back toward the wall),
##  - the view never rotates more than 720 deg/s^2 / 240 deg/s (fixture).
## Output: artifacts/flight/verify/r3/wall_oblique_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

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
	var path := Paths.artifacts("flight").path_join("verify/r3/wall_oblique_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func test_r3_oblique_wall_hits() -> void:
	var multi := PackedStringArray()
	var offs := PackedStringArray()
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		for inc: float in [30.0, 40.0, 50.0, 60.0, 75.0]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: Variant) -> void:
				w.with_ground = false
				w.add_wall(Vector3(0, 100, -20), Vector3(400, 80, 1.0)))
			var p := fx.player
			var pr := p.model.params
			var yaw := (90.0 - inc) * DEG
			var start := Vector3(0, 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
			start.x += pr.v_c * 0.8 * cos(inc * DEG)
			p.start_flying(start, yaw, 0.0)
			var st := {"stuns": 0, "prev": p.mode, "end_t": -1.0, "off": NAN, "off_max_after": 0.0, "first_t": -1.0}
			fx.reset_events()
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				var t := tick * DT
				if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
					if st["first_t"] < 0.0:
						st["first_t"] = t
				if pl.mode == PlayerBird.Mode.FLYING and st["prev"] == PlayerBird.Mode.STUNNED and st["end_t"] < 0.0:
					st["end_t"] = t
				st["prev"] = pl.mode
				var o := absf(FlightMath.wrap_angle(pl.rig_yaw + pl.wing_state().body_yaw - pl.model.heading()))
				if st["end_t"] >= 0.0 and is_nan(float(st["off"])) and t >= float(st["end_t"]) + 1.0:
					st["off"] = o
			fx.run(8.0)
			var off_deg := rad_to_deg(float(st["off"])) if not is_nan(float(st["off"])) else -1.0
			_log("[oblique wall] %-7s incidence %2.0f: stuns %d in 8 s (first at %.2f s), rig-vs-heading offset 1 s after the stun %.1f deg, slides %d" % [
				sp, inc, st["stuns"], st["first_t"], off_deg, p.contacts["slide"]])
			metric("oblique_%s_%d" % [sp, int(inc)], [st["stuns"], off_deg])
			if int(st["stuns"]) > 1:
				multi.append("%s %d deg: %d stuns" % [sp, int(inc), st["stuns"]])
			if off_deg > 10.0:
				offs.append("%s %d deg: %.0f deg" % [sp, int(inc), off_deg])
			fx.assert_comfort(self, "%s oblique %.0f" % [sp, inc])
			fx.teardown()
			fx = null
	_log("[oblique wall] repeated stuns: %s" % str(multi))
	_log("[oblique wall] view/heading disagreement > 10 deg after the stun: %s" % str(offs))
	eq(multi.size(), 0, "an oblique wall hit with neutral arms stuns at most once in 8 s (%s)" % str(multi))
	eq(offs.size(), 0, "after an oblique stun the view agrees with the heading within 10 deg (%s)" % str(offs))


## Root-cause control: the same hits with body steer off (the rig then
## follows the heading 1:1 and nothing reads the stale view direction).
func test_r3_oblique_control_no_body_steer() -> void:
	var res := PackedStringArray()
	var multi := 0
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		for inc: float in [30.0, 40.0, 50.0, 60.0]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: Variant) -> void:
				w.with_ground = false
				w.add_wall(Vector3(0, 100, -20), Vector3(400, 80, 1.0)))
			var p := fx.player
			p.body_steer = false
			var pr := p.model.params
			var yaw := (90.0 - inc) * DEG
			var start := Vector3(0, 100, -20 + 0.5 + pr.r_body + pr.v_c * 0.8 * sin(inc * DEG))
			start.x += pr.v_c * 0.8 * cos(inc * DEG)
			p.start_flying(start, yaw, 0.0)
			var st := {"stuns": 0, "prev": p.mode}
			fx.on_tick = func(_tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
					st["stuns"] += 1
				st["prev"] = pl.mode
			fx.run(8.0)
			res.append("%s %d: %d" % [sp, int(inc), st["stuns"]])
			if int(st["stuns"]) > 1:
				multi += 1
			fx.teardown()
			fx = null
	_log("[oblique wall, body steer OFF] stuns in 8 s: %s" % ", ".join(res))
	metric("oblique_no_body_steer_multi", multi)
	check(true, "control recorded")
