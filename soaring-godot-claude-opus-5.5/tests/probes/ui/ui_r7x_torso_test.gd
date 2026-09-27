extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## Round 6 anchored the HUD to where the player's body faces: PlayerBird's
## telemetry body_yaw, which is flight's WingInput torso estimate (the line
## between the hands, the head when the hands say little). Every UI test and
## the real-game recording feed a torso that never moves (the integration
## bot's torso is fixed), so nothing has measured how the HUD behaves under
## the estimate a REAL player's arms produce: uneven strokes, hands swinging
## forward and back, a head scanning for prey, tucked dives, banked turns.
##
## This probe makes those estimates with flight's own HumanPoseModel ->
## WingInput (tests/unit/flight/wing_rig.gd; the player's true torso never
## turns: torso_yaw = 0 throughout), then replays each one into the UI
## through core contracts only (the mock player's telemetry body_yaw, the
## head pose) and asks the player's question: with my body facing one way,
## does the HUD stay put, or does it swim?
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7x_torso

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const WR := preload("res://tests/unit/flight/wing_rig.gd")
const SDT := 1.0 / 72.0

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


# --- traces from the real torso estimator ---------------------------------------

## Runs a HumanPoseModel script through WingInput for `seconds` at 72 Hz.
## Returns {body: PackedFloat64Array (deg, + left), head: PackedFloat64Array
## (deg, + left, the head's yaw in the rig), tucked: fraction of ticks}.
func _trace(driver: Callable, seconds: float, seed_ := 11) -> Dictionary:
	var body := HumanPoseModel.new(seed_)
	body.tremor_mm = 3.0
	body.twist_noise_deg = 1.0
	var r = WR.new(driver, false, body)
	var n := int(round(seconds / SDT))
	var by := PackedFloat64Array()
	var hy := PackedFloat64Array()
	var tucked := 0
	for i in n:
		var ws: WingState = r.step()
		by.append(rad_to_deg(ws.body_yaw))
		hy.append(rad_to_deg(body.head_yaw + body.torso_yaw))
		if ws.tucked:
			tucked += 1
	return {"body": by, "head": hy, "tucked": float(tucked) / n}


static func _stats(a: PackedFloat64Array, skip := 72) -> Dictionary:
	var lo := INF
	var hi := -INF
	var s2 := 0.0
	var n := 0
	for i in range(skip, a.size()):
		lo = minf(lo, a[i])
		hi = maxf(hi, a[i])
		s2 += a[i] * a[i]
		n += 1
	return {"min": snappedf(lo, 0.01), "max": snappedf(hi, 0.01), "p2p": snappedf(hi - lo, 0.01), "rms": snappedf(sqrt(s2 / maxi(n, 1)), 0.01)}


## A flapping stroke with a human's unevenness: the right arm 20 % weaker
## and 50 ms late, both hands swinging forward on the downstroke (the left
## further), tremor, humanised joints.
static func _flap_human(t: float, body: HumanPoseModel, hz := 1.2) -> void:
	var ph := TAU * hz * t
	body.arms[0].dihedral = deg_to_rad(10.0) + deg_to_rad(45.0) * cos(ph)
	body.arms[1].dihedral = deg_to_rad(10.0) + deg_to_rad(36.0) * cos(ph - TAU * hz * 0.05)
	body.arms[0].sweep = deg_to_rad(14.0) * sin(ph)
	body.arms[1].sweep = deg_to_rad(8.0) * sin(ph - TAU * hz * 0.05)


func _drivers() -> Dictionary:
	return {
		# Symmetric reference strokes (the flight suite's own).
		"flap_symmetric": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			ScriptedPoseSource.flap(body, t, 45.0, 1.2)
			body.humanize(SDT),
		# A person's strokes: uneven, hands forward on the downstroke.
		"flap_human": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			_flap_human(t, body)
			body.humanize(SDT),
		# Gliding, arms out, the head scanning for prey +-50 deg.
		"glide_scan": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			body.head_yaw = deg_to_rad(50.0) * sin(TAU * t / 6.0)
			body.humanize(SDT),
		# Flapping while scanning.
		"flap_scan": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			_flap_human(t, body)
			body.head_yaw = deg_to_rad(45.0) * sin(TAU * t / 5.0)
			body.humanize(SDT),
		# Banked turns by arm dihedral (the "airplane arms" gesture), 4 s each
		# way, with the opposite wrist tilt.
		"bank_turns": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			var s := 1.0 if int(t / 4.0) % 2 == 0 else -1.0
			body.arms[0].dihedral = deg_to_rad(25.0) * s
			body.arms[1].dihedral = -deg_to_rad(25.0) * s
			body.arms[0].twist = deg_to_rad(15.0) * s
			body.arms[1].twist = -deg_to_rad(15.0) * s
			body.humanize(SDT),
		# Reaching: the right arm swept 20 deg forward for 3 s now and then
		# (a player adjusting, pointing, reaching for balance).
		"reach": func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			body.arms[1].sweep = deg_to_rad(20.0) if fmod(t, 8.0) > 4.0 and fmod(t, 8.0) < 7.0 else 0.0
			body.humanize(SDT),
	}


# --- replaying into the UI ---------------------------------------------------------

## Feeds a trace to the HUD (body_yaw and the head, frame by frame through
## UIPanel.follow) and measures what the player sees the HUD do.
func _replay(tr: Dictionary) -> Dictionary:
	var body: PackedFloat64Array = tr["body"]
	var head: PackedFloat64Array = tr["head"]
	var p := k.ui.hud_panel
	p.set_process(false)
	k.player.tel["body_yaw"] = deg_to_rad(body[0])
	k.set_head(Vector3(0, Kit.EYE, 0), head[0])
	p.snap_to_head()
	var y0 := rad_to_deg(p.panel_yaw())
	var prev := y0
	var travel := 0.0
	var lo := y0
	var hi := y0
	var vmax := 0.0
	var moving_frames := 0
	var episodes := 0
	var was_moving := false
	var max_off := 0.0
	for i in body.size():
		k.player.tel["body_yaw"] = deg_to_rad(body[i])
		k.set_head(Vector3(0, Kit.EYE, 0), head[i])
		p.follow(SDT)
		var y := rad_to_deg(p.panel_yaw())
		var d := absf(wrapf(y - prev, -180.0, 180.0))
		travel += d
		vmax = maxf(vmax, d / SDT)
		lo = minf(lo, y)
		hi = maxf(hi, y)
		max_off = maxf(max_off, absf(y))
		var moving := d > 0.002
		if moving:
			moving_frames += 1
		if moving and not was_moving:
			episodes += 1
		was_moving = moving
		prev = y
	var secs := body.size() * SDT
	p.set_process(true)
	return {"travel_deg": snappedf(travel, 0.01), "travel_deg_per_min": snappedf(travel * 60.0 / secs, 0.1),
		"p2p_deg": snappedf(hi - lo, 0.01), "max_off_true_torso_deg": snappedf(max_off, 0.01),
		"peak_deg_s": snappedf(vmax, 0.1), "moving_frac": snappedf(float(moving_frames) / body.size(), 0.001),
		"episodes": episodes, "seconds": snappedf(secs, 0.01)}


func _start_run() -> void:
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)


func test_a_the_hud_holds_still_while_a_real_torso_estimate_stays_put() -> void:
	await _start_run()
	var drivers := _drivers()
	var worst_travel := 0.0
	for name_: String in drivers:
		var tr := _trace(drivers[name_], 30.0)
		var est := _stats(tr["body"])
		var hud := _replay(tr)
		print("[ui-verify] torso %-15s estimate %s | HUD %s" % [name_, JSON.stringify(est), JSON.stringify(hud)])
		metric("torso_%s" % name_, {"estimate": est, "hud": hud})
		if name_ == "reach":
			# One arm swept 20 deg forward for 3 s: the estimate itself turns
			# ~7.7 deg (past the 6 deg dead zone), so following it is by
			# design. Characterised, not asserted.
			continue
		worst_travel = maxf(worst_travel, float(hud["travel_deg_per_min"]))
		# The player's body never turned: the HUD must not swim. A few
		# degrees of one-off settling is tolerable; a HUD that keeps moving
		# with the arms is not.
		lt(float(hud["travel_deg_per_min"]), 12.0, "%s: HUD travel %.1f deg/min with the body still" % [name_, hud["travel_deg_per_min"]])
		lt(float(hud["p2p_deg"]), 6.0, "%s: HUD range %.2f deg with the body still" % [name_, hud["p2p_deg"]])
		lt(int(hud["episodes"]), 4, "%s: HUD set off %d times in 30 s with the body still" % [name_, hud["episodes"]])
	metric("worst_travel_deg_per_min", worst_travel)


func test_b_a_tucked_dive_while_watching_prey_to_the_side() -> void:
	# Glide 3 s, tuck and dive 6 s while looking 40 deg left and 30 deg down at
	# prey, spread and glide 6 s looking ahead again. The torso never turned.
	await _start_run()
	var drv := func(_tick: int, t: float, body: HumanPoseModel) -> void:
		body.set_airplane()
		if t >= 3.0 and t < 9.0:
			for a in body.arms:
				a.fold = deg_to_rad(70.0)
				a.elbow = deg_to_rad(60.0)
			body.head_yaw = deg_to_rad(40.0)
			body.head_pitch = deg_to_rad(-30.0)
		body.humanize(SDT)
	var tr := _trace(drv, 15.0)
	var est := _stats(tr["body"])
	var hud := _replay(tr)
	print("[ui-verify] torso dive_look estimate %s tucked %.2f | HUD %s" % [JSON.stringify(est), tr["tucked"], JSON.stringify(hud)])
	metric("torso_dive_look", {"estimate": est, "tucked_frac": tr["tucked"], "hud": hud})
	# After the dive the arms are out again and the estimate is back on the
	# torso: the HUD must end where the body faces.
	var p := k.ui.hud_panel
	lt(absf(rad_to_deg(p.panel_yaw())), 2.0, "after the dive the HUD is back where the body faces (%.2f deg)" % rad_to_deg(p.panel_yaw()))
	lt(int(hud["episodes"]), 3, "one dive sets the HUD off at most twice (%d)" % hud["episodes"])


func test_c_synthetic_jitter_after_a_turn_settles() -> void:
	# The follow stops only when the smoothed AND the raw torso are both within
	# 0.5 deg of the HUD. A torso estimate that keeps jittering a few degrees
	# (hands swinging) could keep the HUD chasing it for ever after a turn.
	await _start_run()
	var p := k.ui.hud_panel
	p.set_process(false)
	# The real estimator under the modelled flapping jitters +-1.5..2.3 deg
	# (test_a, test_d: the HUD then rests). Asserted: +-2.5 deg (just above
	# that); characterised: larger jitter a sloppier player might produce.
	for c: Array in [[2.5, 1.2], [3.0, 1.5], [5.0, 1.2], [8.0, 1.0], [10.0, 0.7]]:
		var amp: float = c[0]
		var hz: float = c[1]
		k.player.tel["body_yaw"] = 0.0
		p.snap_to_head()
		# A 30 deg body turn with jitter on top, then 10 s of jitter.
		var n := int(12.0 / SDT)
		var ys := PackedFloat64Array()
		for i in n:
			var t := i * SDT
			var base := 30.0 * clampf(t / 0.7, 0.0, 1.0)
			k.player.tel["body_yaw"] = deg_to_rad(base + amp * sin(TAU * hz * t))
			p.follow(SDT)
			ys.append(rad_to_deg(p.panel_yaw()))
		var tail := 0.0
		var lo := INF
		var hi := -INF
		for i in range(int(6.0 / SDT), n):
			tail += absf(ys[i] - ys[i - 1])
			lo = minf(lo, ys[i])
			hi = maxf(hi, ys[i])
		var r := {"amp_deg": amp, "hz": hz, "last6s_travel_deg": snappedf(tail, 0.01), "last6s_p2p_deg": snappedf(hi - lo, 0.01), "final_deg": snappedf(ys[n - 1], 0.01)}
		print("[ui-verify] jitter after a 30 deg turn: %s" % JSON.stringify(r))
		metric("jitter_%d_%s" % [int(amp), str(hz)], r)
		if amp <= 2.5:
			lt(tail, 4.0, "+-%.1f deg at %.1f Hz on the torso: 6-12 s after the turn the HUD travels %.2f deg" % [amp, hz, tail])
	p.set_process(true)


func test_d_a_real_body_turn_while_flapping_then_the_hud_rests() -> void:
	# The player turns their whole body 30 deg in the room (body steer) while
	# flapping on, then keeps flapping facing the new way. The HUD should come
	# round and then REST: the arms' jitter is under the dead zone.
	await _start_run()
	for c: Array in [["flap_human", 1.2, 0.0], ["flap_scan", 1.2, 45.0], ["flap_human_fast", 1.8, 0.0]]:
		var hz: float = c[1]
		var scan: float = c[2]
		var drv := func(_tick: int, t: float, body: HumanPoseModel) -> void:
			body.set_airplane()
			_flap_human(t, body, hz)
			body.torso_yaw = deg_to_rad(-30.0) * clampf((t - 4.0) / 1.0, 0.0, 1.0)
			body.head_yaw = deg_to_rad(scan) * sin(TAU * t / 5.0)
			body.humanize(SDT)
		var tr := _trace(drv, 20.0)
		var body_d: PackedFloat64Array = tr["body"]
		var p := k.ui.hud_panel
		p.set_process(false)
		k.player.tel["body_yaw"] = deg_to_rad(body_d[0])
		k.set_head(Vector3(0, Kit.EYE, 0), (tr["head"] as PackedFloat64Array)[0])
		p.snap_to_head()
		var ys := PackedFloat64Array()
		for i in body_d.size():
			k.player.tel["body_yaw"] = deg_to_rad(body_d[i])
			k.set_head(Vector3(0, Kit.EYE, 0), (tr["head"] as PackedFloat64Array)[i])
			p.follow(SDT)
			ys.append(rad_to_deg(p.panel_yaw()))
		p.set_process(true)
		var n := ys.size()
		var tail := 0.0
		var lo := INF
		var hi := -INF
		var moving := 0
		for i in range(int(10.0 / SDT), n):
			var d := absf(ys[i] - ys[i - 1])
			tail += d
			lo = minf(lo, ys[i])
			hi = maxf(hi, ys[i])
			if d > 0.002:
				moving += 1
		var est_tail := _stats(body_d.slice(int(10.0 / SDT)), 0)
		var r := {"estimate_after_turn": est_tail, "hud_last10s_travel_deg": snappedf(tail, 0.01), "hud_last10s_p2p_deg": snappedf(hi - lo, 0.01),
			"hud_last10s_moving_frac": snappedf(float(moving) / (n - int(10.0 / SDT)), 0.001), "hud_final_deg": snappedf(ys[n - 1], 0.01)}
		print("[ui-verify] body turn -30 deg while %s: %s" % [c[0], JSON.stringify(r)])
		metric("body_turn_%s" % c[0], r)
		near(ys[n - 1], -30.0, 3.0, "%s: the HUD came round to the body (%.2f)" % [c[0], ys[n - 1]])
		lt(tail, 3.0, "%s: then it rests: %.2f deg of travel in the last 10 s (moving %.0f %% of frames)" % [c[0], tail, 100.0 * moving / (n - int(10.0 / SDT))])
