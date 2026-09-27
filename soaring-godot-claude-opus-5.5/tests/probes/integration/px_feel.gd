extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## Flight feel details through the desktop keyboard chain (headless):
##  A. roll-out: bank with D for 2 s, release -> does the bird level itself?
##  B. balloon: from speed, a short S tap (0.4 s) and a medium one (0.8 s)
##  C. a thermal circled by a player who keeps the core inside the circle,
##     no flapping: climb rate vs the same circle 250 m away.
##
##   tools/gd.sh pxv_feel --headless --fixed-fps 72 res://tests/probes/integration/px_feel.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _row(t: float) -> Dictionary:
	var p := main.player
	var tel: Dictionary = p.telemetry()
	return {"t": snappedf(t, 0.01), "y": snappedf(p.global_position.y, 0.01), "as": snappedf(tel["airspeed"], 0.01),
		"vy": snappedf(p.velocity.y, 0.01), "bank": snappedf(rad_to_deg(tel["bank"]), 0.1), "hdg": snappedf(rad_to_deg(tel["heading"]), 0.1),
		"aoa": snappedf(rad_to_deg(tel["aoa"]), 0.1), "roll_in": snappedf(tel["roll_input"], 0.01), "pitch_in": snappedf(tel["pitch_input"], 0.01),
		"stalled": tel["stalled"], "upd": snappedf(tel["in_updraft"], 0.01), "flap": tel["flapping"]}


func _record(secs: float, every := 3) -> Array:
	var rows := []
	var n := int(secs * 72.0)
	for i in n:
		await get_tree().physics_frame
		if i % every == 0:
			rows.append(_row(i / 72.0))
	return rows


func _hold(code: Key, secs: float) -> void:
	_key(code, true)
	await kit.advance(secs)
	_key(code, false)


func _to_cruise() -> void:
	# Climb a little, then level glide with a touch of W to about cruise speed.
	await _hold(KEY_SPACE, 3.0)
	_key(KEY_W, true)
	for i in 400:
		await get_tree().physics_frame
		if float(main.player.telemetry()["airspeed"]) > 9.5:
			break
	_key(KEY_W, false)
	await kit.advance(0.3)


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	out["pose_source_desktop"] = main.player.pose_source is DesktopPoseSource
	main.game_loop.set_protection(main.player, 9999.0)
	var p := main.player
	p.start_flying(Vector3(335, 120, -140) + Vector3(0, 0, 300), PI, 0.0)
	main.game_loop.teleported(p)
	await kit.advance(1.0)
	# A. roll-out
	await _to_cruise()
	_key(KEY_D, true)
	var ra := await _record(2.0)
	_key(KEY_D, false)
	var rb := await _record(5.0)
	out["rollout_hold"] = ra
	out["rollout_release"] = rb
	# B. balloons
	await _to_cruise()
	_key(KEY_S, true)
	var b1 := await _record(0.4, 1)
	_key(KEY_S, false)
	b1.append_array(await _record(4.0))
	out["balloon_0_4"] = b1
	await _to_cruise()
	_key(KEY_S, true)
	var b2 := await _record(0.8, 1)
	_key(KEY_S, false)
	b2.append_array(await _record(4.0))
	out["balloon_0_8"] = b2
	# C. thermal circling (meadow), keyboard taps steering the circle round the core
	var th: Dictionary = {}
	for x in main.world.get_thermals():
		if String(x["name"]) == "meadow":
			th = x
	for which in ["thermal", "no_thermal"]:
		var c: Vector3 = th["position"]
		if which == "no_thermal":
			c += Vector3(-120, 0, 200)
			c.y = main.world.ground_height(c.x, c.z)
		p.start_flying(c + Vector3(14, 45, 0), 0.0, 0.0)
		main.game_loop.teleported(p)
		await kit.advance(0.5)
		var y0 := p.global_position.y
		var rows := []
		var dmax := 0.0
		var dsum := 0.0
		var n := 0
		for i in int(40.0 * 72.0):
			await get_tree().physics_frame
			var rel := Vector2(p.global_position.x - c.x, p.global_position.z - c.z)
			var v := Vector2(p.velocity.x, p.velocity.z)
			# Counter-clockwise circle of radius r0 round the core: bank left
			# when the core is to the left of where a tangent flight would go.
			var r0 := 14.0
			var tangent := Vector2(-rel.y, rel.x).normalized() * -1.0
			var want := (tangent + (-rel.normalized()) * clampf((rel.length() - r0) / r0, -1.0, 1.0)).normalized()
			var cross := v.x * want.y - v.y * want.x
			var left := cross < 0.0
			_key(KEY_A, left)
			_key(KEY_D, not left and v.normalized().dot(want) < 0.9)
			dmax = maxf(dmax, rel.length())
			dsum += rel.length()
			n += 1
			if i % 36 == 0:
				rows.append(_row(i / 72.0))
		_key(KEY_A, false)
		_key(KEY_D, false)
		out[which] = {"dy": snappedf(p.global_position.y - y0, 0.1), "secs": 40.0, "mean_r": snappedf(dsum / n, 0.1),
			"max_r": snappedf(dmax, 0.1), "bell_r": th["radius"], "core": th["strength"], "rows": rows}
		print("[integration] px_feel %s: dy %.1f m in 40 s, mean r %.1f, max r %.1f" % [which, p.global_position.y - y0, dsum / n, dmax])
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_feel.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_feel done %s" % kit.log.summary())
	await kit.teardown()
	get_tree().quit()
