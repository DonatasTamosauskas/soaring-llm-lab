extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## Does flying feel like the brief? Through the desktop keyboard chain
## (DesktopPoseSource -> the real WingInput -> FlightModel) inside the real
## main.tscn, headless, at three sizes (sparrow, pigeon, eagle):
##  1 flap lift direction: flap contribution (flap run minus the same run
##    gliding) with wrists neutral / leading edge down (W) / up (S);
##  2 balloon: S held 1 s from cruise, then released; S held 8 s (stall?);
##  3 coordinated turn: D held 5 s from cruise: bank, turn rate, sideslip,
##    turn radius, the rig's pitch/roll (must stay 0) and yaw rate;
##  4 tuck dive: Shift 3 s, then release;
##  5 plain glide: cruise speed and sink.
## Then (sparrow) a no-flap circle in the meadow thermal vs 250 m away, flown
## by the kit's pilot in glide mode.
##
##   tools/gd.sh p2feel --headless --fixed-fps 72 res://tests/probes/integration/p2_feel.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {}
var A := Vector3.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _release_all() -> void:
	for k in [KEY_W, KEY_S, KEY_A, KEY_D, KEY_SPACE, KEY_SHIFT, KEY_Q, KEY_E, KEY_CTRL, KEY_X]:
		_key(k, false)


func _fwd(p: PlayerBird) -> Vector3:
	var h: float = p.telemetry()["heading"]
	return Vector3(-sin(h), 0.0, -cos(h))


func _row(t: float) -> Dictionary:
	var p := main.player
	var tel: Dictionary = p.telemetry()
	var ob := p.origin.global_basis
	var up := ob.y.normalized()
	return {"t": snappedf(t, 0.01), "y": snappedf(p.global_position.y, 0.01), "as": snappedf(tel["airspeed"], 0.01),
		"vy": snappedf(p.velocity.y, 0.01), "bank": snappedf(rad_to_deg(tel["bank"]), 0.1), "hdg": snappedf(rad_to_deg(tel["heading"]), 0.1),
		"aoa": snappedf(rad_to_deg(tel["aoa"]), 0.1), "slip": snappedf(rad_to_deg(tel["sideslip"]), 0.1),
		"yaw_rate": snappedf(rad_to_deg(tel["yaw_rate"]), 0.1), "rig_yaw_rate": snappedf(rad_to_deg(tel["rig_yaw_rate"]), 0.1),
		"stalled": tel["stalled"], "flap": tel["flapping"], "rig_tilt": snappedf(rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1, 1))), 0.01),
		"mode": tel["mode"]}


func _start() -> void:
	_release_all()
	var p := main.player
	p.start_flying(A, 0.0, 0.0)
	main.game_loop.teleported(p)
	await kit.advance(1.0)


func _run_keys(keys: Array, secs: float, pre_keys: Array = [], pre_s := 0.0) -> Dictionary:
	await _start()
	var p := main.player
	for k in pre_keys:
		_key(k, true)
	await kit.advance(pre_s)
	var p0 := p.global_position
	var v0 := p.velocity
	var f := _fwd(p)
	for k in keys:
		_key(k, true)
	var rows := []
	for i in int(secs * 72.0):
		await get_tree().physics_frame
		if i % 6 == 0:
			rows.append(_row(i / 72.0))
	var dv := p.velocity - v0
	var dp := p.global_position - p0
	_release_all()
	return {"dv_fwd": snappedf(dv.dot(f), 0.01), "dv_up": snappedf(dv.y, 0.01), "dp_fwd": snappedf(dp.dot(f), 0.01), "dp_up": snappedf(dp.y, 0.01),
		"rows": rows}


func _size_suite(mass: float, label: String) -> Dictionary:
	var r := {}
	main.game_loop._set_player_mass(main.player, mass, &"probe")
	await kit.advance(4.0)
	var tel: Dictionary = main.player.telemetry()
	r["world_scale"] = snappedf(tel["world_scale"], 0.001)
	r["species"] = String(main.player.species)
	r["v_c"] = snappedf(main.player.model.params.v_c, 0.01)
	r["span"] = snappedf(main.player.model.params.span, 0.001)
	# 5 plain glide
	var g := await _run_keys([], 4.0)
	r["glide"] = {"as_end": g["rows"][-1]["as"], "vy_end": g["rows"][-1]["vy"]}
	# 1 flap direction
	var fl := {}
	for wr in [["neutral", []], ["forward_W", [KEY_W]], ["back_S", [KEY_S]]]:
		var name: String = wr[0]
		var pre: Array = wr[1]
		var fa := await _run_keys([KEY_SPACE], 2.0, pre, 0.4)
		var fb := await _run_keys([], 2.0, pre, 0.4)
		var df := snappedf(float(fa["dv_fwd"]) - float(fb["dv_fwd"]), 0.01)
		var du := snappedf(float(fa["dv_up"]) - float(fb["dv_up"]), 0.01)
		var pf := snappedf(float(fa["dp_fwd"]) - float(fb["dp_fwd"]), 0.01)
		var pu := snappedf(float(fa["dp_up"]) - float(fb["dp_up"]), 0.01)
		fl[name] = {"flap_dv_fwd": df, "flap_dv_up": du, "flap_dp_fwd": pf, "flap_dp_up": pu,
			"dir_deg_from_up": snappedf(rad_to_deg(atan2(pf, pu)), 0.1)}
		print("[integration] p2_feel %s flap %s: extra fwd %.2f m, extra up %.2f m (dv fwd %.2f up %.2f)" % [label, name, pf, pu, df, du])
	r["flap"] = fl
	# 2 balloon
	var b1 := await _run_keys([KEY_S], 1.0)
	_release_all()
	var after := []
	for i in int(6.0 * 72.0):
		await get_tree().physics_frame
		if i % 6 == 0:
			after.append(_row(1.0 + i / 72.0))
	r["balloon_1s"] = b1["rows"] + after
	var b8 := await _run_keys([KEY_S], 8.0)
	r["balloon_hold8"] = b8["rows"]
	var rec := []
	for i in int(4.0 * 72.0):
		await get_tree().physics_frame
		if i % 6 == 0:
			rec.append(_row(8.0 + i / 72.0))
	r["balloon_release"] = rec
	# 3 turn
	var tr := await _run_keys([KEY_D], 5.0)
	var maxbank := 0.0
	var maxslip := 0.0
	var maxrate := 0.0
	var maxtilt := 0.0
	for row: Dictionary in tr["rows"]:
		maxbank = maxf(maxbank, absf(row["bank"]))
		if float(row["t"]) > 1.0:
			maxslip = maxf(maxslip, absf(row["slip"]))
		maxrate = maxf(maxrate, absf(row["rig_yaw_rate"]))
		maxtilt = maxf(maxtilt, row["rig_tilt"])
	var last: Dictionary = tr["rows"][-1]
	var rate := deg_to_rad(absf(last["yaw_rate"]))
	r["turn"] = {"max_bank": maxbank, "max_slip_after_1s": maxslip, "max_rig_yaw_rate": maxrate, "max_rig_tilt": maxtilt,
		"end_airspeed": last["as"], "end_turn_rate": last["yaw_rate"], "radius_m": snappedf(float(last["as"]) / maxf(rate, 1e-3), 0.1),
		"radius_spans": snappedf(float(last["as"]) / maxf(rate, 1e-3) / main.player.model.params.span, 0.1), "rows": tr["rows"]}
	# roll-out after release
	var ro := []
	for i in int(4.0 * 72.0):
		await get_tree().physics_frame
		if i % 12 == 0:
			ro.append(_row(5.0 + i / 72.0))
	r["turn_release"] = ro
	# 4 dive
	var dv := await _run_keys([KEY_SHIFT], 3.0)
	r["dive"] = dv["rows"]
	var po := []
	for i in int(3.0 * 72.0):
		await get_tree().physics_frame
		if i % 6 == 0:
			po.append(_row(3.0 + i / 72.0))
	r["dive_release"] = po
	print("[integration] p2_feel %s: ws %.3f glide %s; turn bank %.0f rate %.0f dps radius %.1f m slip<=%.1f rig tilt %.2f; dive end as %s" % [
		label, r["world_scale"], r["glide"], maxbank, last["yaw_rate"], r["turn"]["radius_m"], maxslip, maxtilt, dv["rows"][-1]["as"]])
	return r


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	out["pose_source"] = main.player.pose_source.get_class() + ("/Desktop" if main.player.pose_source is DesktopPoseSource else "")
	main.game_loop.set_protection(main.player, 1e6)
	# A calm, high spot: no updraft, flat low ground.
	var w := main.world
	var best := Vector3.ZERO
	var bestv := INF
	for x in range(-300, 301, 50):
		for z in range(-300, 301, 50):
			var gh := w.ground_height(x, z)
			var q := Vector3(x, gh + 110.0, z)
			var wv := w.get_wind(q)
			var score := absf(wv.y) + 0.2 * wv.length()
			# the heading 0 flight (-Z) needs clear air ahead
			var gh2 := w.ground_height(x, z - 150.0)
			if gh2 > gh + 40.0:
				continue
			if score < bestv:
				bestv = score
				best = q
	A = best
	out["spot"] = [A.x, A.y, A.z, snappedf(bestv, 0.001)]
	print("[integration] p2_feel spot %s wind %s" % [A, w.get_wind(A)])
	for sz in [["sparrow", 0.03], ["pigeon", 0.3], ["eagle", 3.0]]:
		out[sz[0]] = await _size_suite(sz[1], sz[0])
	# Thermal (sparrow): glide circles through the kit's pilot.
	main.game_loop._set_player_mass(main.player, 0.03, &"probe")
	await kit.advance(3.0)
	var th: Dictionary = {}
	for x in main.world.get_thermals():
		if th.is_empty() or float(x["strength"]) > float(th["strength"]):
			th = x
	out["thermal_used"] = {"name": th.get("name"), "strength": th.get("strength"), "radius": th.get("radius")}
	kit.fly_bot(7)
	for which in ["thermal", "control"]:
		var c: Vector3 = th["position"]
		if which == "control":
			c += Vector3(-150, 0, 200)
		c.y = main.world.ground_height(c.x, c.z)
		var lean: Vector3 = th["lean"]
		var ya := c.y + 50.0
		c = Vector3(c.x + lean.x * ya, c.y, c.z + lean.z * ya)
		main.player.start_flying(c + Vector3(float(th["radius"]) * 0.4, 50, 0), 0.0, 0.0)
		main.game_loop.teleported(main.player)
		kit.orbit_centre = c
		kit.orbit_radius = maxf(float(th["radius"]) * 0.35, 10.0)
		kit.pilot.set(&"agl", 500.0)
		kit.set_mode(&"glide")
		await kit.advance(1.0)
		var y0 := main.player.global_position.y
		var rmean := 0.0
		var n := 0
		var flaps0 := kit.count("player_flapped")
		for i in 40 * 72:
			await get_tree().physics_frame
			var rel := main.player.global_position - c
			rmean += Vector2(rel.x, rel.z).length()
			n += 1
		out[which] = {"dy_40s": snappedf(main.player.global_position.y - y0, 0.1), "mean_r": snappedf(rmean / n, 0.1),
			"flaps": kit.count("player_flapped") - flaps0}
		print("[integration] p2_feel %s: %s" % [which, out[which]])
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_feel.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] p2_feel done %s" % kit.log.summary())
	await kit.teardown()
	get_tree().quit()
