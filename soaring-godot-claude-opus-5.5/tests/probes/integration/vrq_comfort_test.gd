extends TestCase
## VERIFIER PROBE (integration verify round 1, VR comfort lens). Not part of
## any area suite. The shipped main.tscn, headless, the bot flying through
## the real WingInput (integration's game kit): cruise orbits, hard turns
## after targets, a ground strike, a predator's catch and the respawn,
## growth to eagle. Every physics tick, after PlayerBird's tick, the rig
## (XROrigin3D) is sampled: it must never pitch/roll, its yaw rate and yaw
## acceleration must stay within flight's comfort caps (deliberate,
## flagged teleports excepted), the near plane must follow world_scale.
##
##   tools/gd.sh vrq --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=vrq_comfort --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var sampler: Node


class Sampler:
	extends Node
	var main: GameMain
	var m := {"ticks": 0, "max_tilt_deg": 0.0, "max_rate_dps": 0.0, "max_acc_dps2": 0.0, "rate_over": 0, "acc_over": 0,
		"flagged": 0, "near_err": 0.0, "worst": {}, "acc_hist": {}, "max_cam_vacc": 0.0, "ws_steps": 0, "max_ws_jump": 0.0}
	var _yaw := NAN
	var _rate := NAN
	var _ws := NAN
	var _cy := NAN
	var _cv := NAN
	var label := ""

	func _init() -> void:
		process_physics_priority = 1000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _physics_process(dt: float) -> void:
		if main == null or main.player == null:
			return
		var p := main.player
		var o := p.origin
		var b := o.global_basis
		m["ticks"] += 1
		m["max_tilt_deg"] = maxf(m["max_tilt_deg"], rad_to_deg(b.y.normalized().angle_to(Vector3.UP)))
		var ws := o.world_scale
		m["near_err"] = maxf(m["near_err"], absf(p.camera.near - WorldScaleDriver.near_for(ws)) / WorldScaleDriver.near_for(ws))
		if not is_nan(_ws) and absf(log(ws / _ws)) > 1e-6:
			m["ws_steps"] += 1
			m["max_ws_jump"] = maxf(m["max_ws_jump"], absf(log(ws / _ws)))
		_ws = ws
		var f := -b.z
		var yaw := atan2(-f.x, -f.z)
		if p.yaw_flagged or get_tree().paused or not p.auto_process:
			if p.yaw_flagged:
				m["flagged"] += 1
			_yaw = yaw
			_rate = NAN
			_cy = NAN
			_cv = NAN
			return
		# Vertical acceleration of the eye in the world (heave smoothing).
		var cy := p.camera.global_position.y
		if not is_nan(_cy):
			var cv := (cy - _cy) / dt
			if not is_nan(_cv):
				m["max_cam_vacc"] = maxf(m["max_cam_vacc"], absf(cv - _cv) / dt)
			_cv = cv
		_cy = cy
		if not is_nan(_yaw):
			var rate := wrapf(yaw - _yaw, -PI, PI) / dt
			var cap_r := p.model.comfort_yaw_rate
			var cap_a := p.model.comfort_yaw_accel
			m["cap_rate_dps"] = rad_to_deg(cap_r)
			m["cap_acc_dps2"] = rad_to_deg(cap_a)
			m["max_rate_dps"] = maxf(m["max_rate_dps"], rad_to_deg(absf(rate)))
			if cap_r > 0.0 and absf(rate) > cap_r * 1.001:
				m["rate_over"] += 1
			if not is_nan(_rate):
				var acc := absf(rate - _rate) / dt
				var bucket := str(int(rad_to_deg(acc) / 100.0) * 100)
				m["acc_hist"][bucket] = int(m["acc_hist"].get(bucket, 0)) + 1
				if rad_to_deg(acc) > m["max_acc_dps2"]:
					m["max_acc_dps2"] = rad_to_deg(acc)
					m["worst"] = {"label": label, "mode": p.mode_name(), "rate_dps": rad_to_deg(rate), "species": String(p.species)}
				if cap_a > 0.0 and acc > cap_a * 1.01:
					m["acc_over"] += 1
			_rate = rate
		_yaw = yaw


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)
	sampler = Sampler.new()
	sampler.main = kit.main
	add_child(sampler)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_fly_the_game_and_watch_the_rig() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play hovered")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0), "PLAYING")
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot()
	kit.cruise()
	sampler.label = "cruise"
	await kit.advance(40.0)
	# Hard turns: targets 90-180 deg off the heading, one after another.
	sampler.label = "hard turns"
	for k in 6:
		var p := m.player
		var yaw := p.rig_yaw + (PI * 0.5 if k % 2 == 0 else -PI * 0.9)
		var at := p.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 60.0
		kit.chase(at)
		await kit.advance(5.0)
	# Into the ground ahead (touchdowns / contacts).
	sampler.label = "ground"
	var p2 := m.player
	var ahead := p2.global_position - p2.global_basis.z * 30.0
	ahead.y = m.world.ground_height(ahead.x, ahead.z) - 3.0
	kit.chase(ahead)
	await kit.advance(8.0)
	kit.cruise()
	await kit.advance(8.0)
	# Caught by a staged hawk strike, then the respawn.
	sampler.label = "caught"
	m.game_loop.set_protection(m.player, 0.0)
	kit.stage_strike(&"hawk", 25.0, 14.0)
	var caught := await kit.wait_until(func() -> bool: return Game.state == Game.State.CAUGHT, 15.0)
	check(caught, "caught by the staged strike")
	sampler.label = "respawn"
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 10.0)
	kit.free_staged()
	m.game_loop.set_protection(m.player, 1e6)
	await kit.advance(4.0)
	kit.fly_bot()
	kit.cruise()
	await kit.advance(10.0)
	# Growth to eagle while flying.
	sampler.label = "growth"
	for i in range(SizeRules.species_index(&"swallow"), SizeRules.SPECIES.size()):
		m.game_loop.call(&"_set_player_mass", m.player, float(SizeRules.SPECIES[i]["mass"]) * 1.02, &"meal")
		await kit.advance(3.0)
	sampler.label = "eagle turns"
	for k in 4:
		var p := m.player
		var yaw := p.rig_yaw + (PI * 0.5 if k % 2 == 0 else -PI * 0.9)
		kit.chase(p.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 120.0)
		await kit.advance(6.0)
	var r: Dictionary = sampler.m
	metric("comfort", r)
	print("[integration-verify] comfort ", JSON.stringify(r))
	check(r["max_tilt_deg"] < 0.01, "the rig never pitched or rolled (max %.5f deg)" % r["max_tilt_deg"])
	eq(r["rate_over"], 0, "ticks with a rig yaw rate over the cap (%.0f deg/s; max %.1f)" % [r.get("cap_rate_dps", 0.0), r["max_rate_dps"]])
	eq(r["acc_over"], 0, "ticks with a rig yaw acceleration over the cap (%.0f deg/s^2; max %.1f at %s; histogram %s)" % [
		r.get("cap_acc_dps2", 0.0), r["max_acc_dps2"], r["worst"], r["acc_hist"]])
	lt(r["near_err"], 0.01, "near plane follows world_scale")
	eq(kit.log.errors + kit.log.warnings, 0, "no errors/warnings: %s" % kit.log.summary())
