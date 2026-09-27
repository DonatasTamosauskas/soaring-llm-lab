extends TestCase
## VERIFIER PROBE (integration verify round 2; lens: VR comfort). Not part of
## any suite (it lives under tests/probes/integration/).
##
## The real main.tscn, a run started through the game's bridge, a sparrow
## flown through the real chain (flight's BotPoseSource arm motion ->
## WingInput -> FlightModel) by integration's competent chase pilot that
## follows the game's target cue for PLAY_S of game time, then the same at
## hawk size. Every physics tick records what the headset would show:
##   - the rig's tilt (the view must never pitch or roll)
##   - the rig's yaw rate and yaw acceleration (ramps, caps) and any yaw
##     step on a flagged tick (respawn, recenter, forced perch)
##   - the rig's perceived translation (metres / world_scale): vertical
##     speed and acceleration (wingbeat bob), and teleports (one tick moving
##     the view more than 2 m perceived: respawns and the like - each is a
##     cut with no fade)
##   - the comfort vignette's strength vs the yaw rate
##   - collisions, perches and every haptic pulse by pattern (never a
##     constant buzz)
##
##   GD_TIMEOUT=900 tools/gd.sh r2vq_desk --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=r2vq_comfort --fresh-settings
## Output: artifacts/integration/verify/r2vq/desk_comfort.json

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
const PLAY_S := 240.0
const BIG_S := 90.0
const COMMIT_M := 12.0

var kit: Kit
var booted := false
var rec := {}
var _prev_yaw := NAN
var _prev_rate := NAN
var _prev_pos := Vector3.INF
var _prev_vy := NAN
var _haptics := {}
var _events := {"collided": 0, "collided_hard": 0, "perched": 0, "took_off": 0, "spawned": 0, "stalled": 0, "flapped": 0}
var _phase := "sparrow"
var _vy_now := 0.0


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _new_rec() -> Dictionary:
	return {"ticks": 0, "max_tilt_deg": 0.0, "yaw_hist": {}, "max_yaw_rate": 0.0, "max_yaw_acc": 0.0,
		"over_cap_rate": 0, "over_cap_acc": 0, "over_90": 0, "over_150": 0, "flagged": 0, "flagged_steps": [],
		"teleports": [], "vy_hist": {}, "ay_p": [], "vig_at_fast_turn": [], "series": [],
		"vig_max": 0.0, "yaw_rates": [], "max_ws_rate": 0.0, "near_errs": []}


func _sample(dt: float) -> void:
	var m := kit.main
	var p := m.player
	var o := p.origin
	var r: Dictionary = rec[_phase]
	r["ticks"] += 1
	var b := o.global_basis
	r["max_tilt_deg"] = maxf(r["max_tilt_deg"], rad_to_deg(b.y.normalized().angle_to(Vector3.UP)))
	var ws := o.world_scale
	var f := -b.z
	var yaw := atan2(-f.x, -f.z)
	var cam := p.camera.global_position
	var nw := WorldScaleDriver.near_for(ws)
	var ne := absf(p.camera.near - nw) / nw
	if ne > 0.01 and (r["near_errs"] as Array).size() < 10:
		r["near_errs"].append({"t": snappedf(Game.run_time, 0.01), "err": snappedf(ne, 0.001), "ws": ws, "near": p.camera.near, "state": Game.state_name()})
	var vig := m.rig_extras.vignette.strength() if m.rig_extras != null and m.rig_extras.vignette != null else 0.0
	r["vig_max"] = maxf(r["vig_max"], vig)
	if _prev_pos != Vector3.INF:
		var d := (cam - _prev_pos) / ws
		if d.length() > 2.0:
			r["teleports"].append({"t": snappedf(Game.run_time, 0.1), "m": snappedf(d.length(), 0.1), "state": Game.state_name(),
				"flagged": p.yaw_flagged, "mode": p.mode_name()})
			_prev_vy = NAN
		elif dt > 0.0:
			var vy := d.y / dt
			_vy_now = vy
			var k := str(int(absf(vy)))
			r["vy_hist"][k] = int(r["vy_hist"].get(k, 0)) + 1
			if not is_nan(_prev_vy):
				(r["ay_p"] as Array).append(absf(vy - _prev_vy) / dt)
			_prev_vy = vy
	_prev_pos = cam
	if p.yaw_flagged:
		r["flagged"] += 1
		if not is_nan(_prev_yaw):
			var st := rad_to_deg(absf(wrapf(yaw - _prev_yaw, -PI, PI)))
			if st > 0.5 and (r["flagged_steps"] as Array).size() < 30:
				r["flagged_steps"].append({"t": snappedf(Game.run_time, 0.1), "deg": snappedf(st, 0.1), "mode": p.mode_name(), "state": Game.state_name()})
		_prev_yaw = yaw
		_prev_rate = NAN
		return
	if not is_nan(_prev_yaw) and dt > 0.0:
		var rate := wrapf(yaw - _prev_yaw, -PI, PI) / dt
		var rd := rad_to_deg(absf(rate))
		(r["yaw_rates"] as Array).append(rd)
		if (r["series"] as Array).size() < 30000:
			(r["series"] as Array).append([snappedf(Game.run_time, 0.001), snappedf(rad_to_deg(rate), 0.1), snappedf(vig, 0.01), p.mode_name(), snappedf(_vy_now, 0.01), snappedf(ws, 0.0001)])
		var bucket := str(int(rd / 30.0) * 30)
		r["yaw_hist"][bucket] = int(r["yaw_hist"].get(bucket, 0)) + 1
		r["max_yaw_rate"] = maxf(r["max_yaw_rate"], rd)
		if rd > 90.0:
			r["over_90"] += 1
		if rd > 150.0:
			r["over_150"] += 1
			(r["vig_at_fast_turn"] as Array).append(vig)
		var cap_r := rad_to_deg(p.model.comfort_yaw_rate)
		var cap_a := rad_to_deg(p.model.comfort_yaw_accel)
		r["cap_rate"] = cap_r
		r["cap_acc"] = cap_a
		if cap_r > 0.0 and rd > cap_r * 1.001:
			r["over_cap_rate"] += 1
		if not is_nan(_prev_rate):
			var acc := rad_to_deg(absf(rate - _prev_rate)) / dt
			r["max_yaw_acc"] = maxf(r["max_yaw_acc"], acc)
			if cap_a > 0.0 and acc > cap_a * 1.01:
				r["over_cap_acc"] += 1
		_prev_rate = rate
	_prev_yaw = yaw


static func _pct(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var v := a.duplicate()
	v.sort()
	return snappedf(v[clampi(int(ceil(q * v.size())) - 1, 0, v.size() - 1)], 0.01)


func _fly(seconds: float, pilot: ChasePilot) -> void:
	var m := kit.main
	var cur: NpcBird = null
	var since := 0.0
	var off_cue := 0.0
	var t := 0.0
	while t < seconds and Game.state != Game.State.ENDED:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
			_sample(1.0 / 72.0)
		else:
			_prev_yaw = NAN
			_prev_rate = NAN
		if Game.state != Game.State.PLAYING:
			if cur != null:
				cur = null
				pilot.stop_chase()
				kit.cruise()
			continue
		var tgt: Variant = m.game_loop.get_run_stats().get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if cur != null:
			since += 1.0 / 72.0
			var ended := not is_instance_valid(cur) or not cur.alive or cur.hidden or since > 25.0
			if not ended:
				var gap := cur.get_body_position().distance_to(m.player.get_body_position())
				off_cue = off_cue + 1.0 / 72.0 if named != cur and gap > COMMIT_M else 0.0
				ended = off_cue > 1.0
			if ended:
				cur = null
				pilot.stop_chase()
				kit.cruise()
		if cur == null and named != null:
			cur = named
			since = 0.0
			off_cue = 0.0
			pilot.chase_prey(named)


func test_comfort_in_cue_following_play() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	VR.haptics.pulse_sent.connect(func(_h: int, _a: float, _d: float, pattern: StringName) -> void:
		_haptics[String(pattern)] = int(_haptics.get(String(pattern), 0)) + 1)
	Events.player_collided.connect(func(sp: float, _n: Vector3) -> void:
		_events["collided"] += 1
		if sp >= 0.5:
			_events["collided_hard"] += 1)
	Events.player_perched.connect(func(_p: Vector3) -> void: _events["perched"] += 1)
	Events.player_took_off.connect(func() -> void: _events["took_off"] += 1)
	Events.player_spawned.connect(func(_b: Bird) -> void: _events["spawned"] += 1)
	Events.player_stalled.connect(func() -> void: _events["stalled"] += 1)
	Events.player_flapped.connect(func(_s: int, _st: float) -> void: _events["flapped"] += 1)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(int(Paths.arg("comfort_seed", "7")), ChasePilot)
	var pilot := kit.pilot as ChasePilot
	kit.set_mode(&"climb")
	rec["sparrow"] = _new_rec()
	_phase = "sparrow"
	var t0 := Time.get_ticks_msec()
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 110.0
	await _fly(PLAY_S, pilot)
	var haptics_sparrow := _haptics.duplicate()
	var events_sparrow := _events.duplicate()
	var run_time_sparrow := Game.run_time
	# Hawk size: the game loop's own mass path.
	m.game_loop.call(&"_set_player_mass", m.player, float(SizeRules.species_data(&"hawk")["mass"]) * 1.05, &"meal")
	kit.pilot.call(&"set_params", m.player.model.params)
	rec["hawk"] = _new_rec()
	_phase = "hawk"
	_prev_yaw = NAN
	_prev_rate = NAN
	_prev_pos = Vector3.INF
	await _fly(BIG_S, pilot)
	var out := {"wall_s": (Time.get_ticks_msec() - t0) / 1000.0, "run_time": Game.run_time, "run_time_sparrow": run_time_sparrow,
		"haptics_sparrow": haptics_sparrow, "events_sparrow": events_sparrow, "haptics_total": _haptics, "events_total": _events,
		"haptic_stats": VR.haptics.stats, "catches": m.game_loop.get_run_stats().get("catches", -1),
		"deaths": m.game_loop.get_run_stats().get("deaths", -1), "state": Game.state_name()}
	for ph: String in rec:
		var r: Dictionary = rec[ph]
		var yr: Array = r["yaw_rates"]
		out[ph] = {"ticks": r["ticks"], "max_tilt_deg": r["max_tilt_deg"], "max_yaw_rate": r["max_yaw_rate"], "cap_rate": r.get("cap_rate", -1),
			"max_yaw_acc": r["max_yaw_acc"], "cap_acc": r.get("cap_acc", -1), "over_cap_rate": r["over_cap_rate"], "over_cap_acc": r["over_cap_acc"],
			"yaw_rate_p50": _pct(yr, 0.5), "yaw_rate_p90": _pct(yr, 0.9), "yaw_rate_p99": _pct(yr, 0.99),
			"share_over_90": float(r["over_90"]) / maxf(yr.size(), 1.0), "share_over_150": float(r["over_150"]) / maxf(yr.size(), 1.0),
			"yaw_hist": r["yaw_hist"], "flagged": r["flagged"], "flagged_steps": r["flagged_steps"], "teleports": r["teleports"],
			"vy_hist": r["vy_hist"], "ay_p50": _pct(r["ay_p"], 0.5), "ay_p95": _pct(r["ay_p"], 0.95), "ay_p99": _pct(r["ay_p"], 0.99),
			"vignette_max": r["vig_max"], "vignette_p50_when_over_150": _pct(r["vig_at_fast_turn"], 0.5),
			"vignette_min_when_over_150": _pct(r["vig_at_fast_turn"], 0.0), "near_errs": r["near_errs"]}
	for ph: String in rec:
		var ser: Array = rec[ph]["series"]
		var rev := 0
		var last_sign := 0
		var fast_rev := 0
		for row: Array in ser:
			var rt := float(row[1])
			if absf(rt) < 30.0:
				continue
			var sg := 1 if rt > 0.0 else -1
			if last_sign != 0 and sg != last_sign:
				rev += 1
			last_sign = sg
		# vignette strength by yaw-rate band
		var bands := {}
		for row: Array in ser:
			var b := str(int(absf(float(row[1])) / 30.0) * 30)
			if not bands.has(b):
				bands[b] = [0.0, 0]
			bands[b][0] += float(row[2])
			bands[b][1] += 1
		var vb := {}
		for b in bands:
			vb[b] = snappedf(bands[b][0] / maxf(bands[b][1], 1.0), 0.01)
		out[ph]["yaw_reversals_over_30dps"] = rev
		out[ph]["yaw_reversals_per_min"] = snappedf(rev / maxf(ser.size() / 72.0 / 60.0, 1e-3), 0.1)
		out[ph]["vignette_mean_by_yaw_band"] = vb
		var sf := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2vq/desk_yaw_series_%s.json" % ph), FileAccess.WRITE)
		sf.store_string(JSON.stringify(ser))
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2vq/desk_comfort.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	print("[integration-verify] comfort: ", JSON.stringify(out))
	for ph: String in rec:
		lt(float(out[ph]["max_tilt_deg"]), 0.01, "%s: the rig never pitches or rolls" % ph)
		eq(int(out[ph]["over_cap_rate"]), 0, "%s: yaw rate within flight's comfort cap" % ph)
		eq(int(out[ph]["over_cap_acc"]), 0, "%s: yaw acceleration within flight's comfort cap" % ph)
	eq(kit.log.errors, 0, "no errors")
