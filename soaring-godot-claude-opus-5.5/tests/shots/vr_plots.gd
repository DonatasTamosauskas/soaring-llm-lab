extends Node
## Evidence plots for the VR area, computed from the real classes and drawn
## by Godot (tests/shots/vr_plot.gd):
##
##   tools/gd.sh vr --rendering-method forward_plus --resolution 640x360 res://tests/shots/vr_plots.tscn
##
##   vr_plot_vignette.png      strength vs turn rate and acceleration; response to a hard
##                             turn; a flapping sparrow: the wingbeat vs a sustained surge;
##                             steady flight over orchard crowns: round 3 vs now
##   vr_plot_world_scale.png   growth ramp sparrow -> eagle -> pigeon; camera near plane
##   vr_plot_haptics.png       every haptic pattern's rhythm
##   vr_plot_calibration.png   16 synthetic players before / after calibration;
##                             capture-pose independence (now vs the previous build)
##   vr_plot_comfort_r1.png    world_scale exponent 1.0 vs 0.8: perceived speed,
##                             own-wing size error, angular optic flow

const Plot := preload("res://tests/shots/vr_plot.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 90.0


## PlayerBird.wing_state() look-alike (stroke period for the vignette).
class FakeWingState:
	extends RefCounted
	var stroke_period := 1.0
	var ext_l := 1.0
	var ext_r := 1.0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _render(await _vignette(), Vector2i(3600, 560), "vr_plot_vignette")
	await _render(_world_scale(), Vector2i(1500, 560), "vr_plot_world_scale")
	await _render(_haptics(), Vector2i(1500, 620), "vr_plot_haptics")
	await _render(_calibration(), Vector2i(2400, 560), "vr_plot_calibration")
	await _render(_comfort(), Vector2i(1800, 580), "vr_plot_comfort_r1")
	print("[vr] plots done")
	get_tree().quit()


func _render(panels: Array, sz: Vector2i, name: String) -> void:
	var vp := SubViewport.new()
	vp.size = sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var hb := HBoxContainer.new()
	hb.size = sz
	hb.add_theme_constant_override("separation", 0)
	for p in panels:
		(p as Control).custom_minimum_size = Vector2(float(sz.x) / panels.size(), sz.y)
		hb.add_child(p)
	vp.add_child(hb)
	add_child(vp)
	for i in 3:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var path := Paths.artifacts("vr").path_join(name + ".png")
	img.save_png(path)
	print("[vr] plot -> ", path)
	vp.queue_free()


func _plot(title: String, subtitle: String) -> Control:
	var p: Control = Plot.new()
	p.set("title", title)
	p.set("subtitle", subtitle)
	return p


func _line(name: String, pts: PackedVector2Array, ci: int, label_end := false) -> Dictionary:
	return {"name": name, "points": pts, "kind": "line", "color_index": ci, "label_end": label_end}


# --- vignette --------------------------------------------------------------------

func _vignette() -> Array:
	var a := _plot("Vignette vs turn rate", "target strength; no acceleration")
	var sa := []
	var ci := 0
	for setting in [1.0, 0.6, 0.3]:
		var pts := PackedVector2Array()
		for d in range(0, 201, 2):
			pts.append(Vector2(d, VignetteModel.target_for(setting, deg_to_rad(d), 0.0, 1.0)))
		sa.append(_line("setting %.1f" % setting, pts, ci))
		ci += 1
	a.set("series", sa)
	_axes(a, 0, 200, [0, 50, 100, 150, 200], 0, 1.05, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "rig yaw rate (deg/s)", "strength")
	a.set("vlines", [{"x": 35, "text": "35°/s"}, {"x": 150, "text": "150°/s"}])
	a.set("legend_at", Vector2(0.03, 0.08))
	var b := _plot("Vignette vs acceleration", "perceived m/s² (a / world_scale), setting 1; x proximity of a surface")
	var sb := []
	ci = 0
	for prox in [1.0, 0.5, 0.0]:
		var pts := PackedVector2Array()
		for i in 121:
			var acc := i * 0.25
			pts.append(Vector2(acc, VignetteModel.target_for(1.0, 0.0, acc, 1.0, prox)))
		sb.append(_line("proximity %.1f%s" % [prox, " (open sky)" if prox == 0.0 else ""], pts, ci))
		ci += 1
	b.set("series", sb)
	_axes(b, 0, 30, [0, 6, 10, 20, 30], 0, 1.05, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "perceived acceleration (m/s²)", "strength")
	b.set("x_fmt", "%.0f")
	b.set("vlines", [{"x": 6.0, "text": "6"}, {"x": 20.0, "text": "20 (x0.5)"}])
	b.set("legend_at", Vector2(0.03, 0.08))
	# Fix round 5: the speed term (DESIGN's "fast turns/speed").
	var sp := _plot("Vignette vs speed", "smoothed rig speed / the bird's own cruise speed (any species); no turn")
	var ss := []
	ci = 0
	for setting in [1.0, 0.6, 0.3]:
		var pts := PackedVector2Array()
		for i in 121:
			var r := 0.5 + i * 0.02
			pts.append(Vector2(r, VignetteModel.target_for(setting, 0.0, 0.0, 1.0, 0.0, r)))
		ss.append(_line("setting %.1f" % setting, pts, ci))
		ci += 1
	sp.set("series", ss)
	_axes(sp, 0.5, 2.9, [0.5, 1.0, 1.5, 2.0, 2.5], 0, 1.05, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "speed / cruise", "strength")
	sp.set("x_fmt", "%.1f")
	sp.set("vlines", [{"x": 1.0, "text": "cruise"}, {"x": 1.3, "text": "1.3"}, {"x": 2.3, "text": "2.3 (x0.7)"}, {"x": 2.6, "text": "dive limit"}])
	sp.set("legend_at", Vector2(0.03, 0.08))
	var c := _plot("Response to a hard turn", "200°/s for 0.8 s, then level; attack 0.08 s, release 0.5 s")
	var m := VignetteModel.new()
	var st := PackedVector2Array()
	var tg := PackedVector2Array()
	var t := 0.0
	while t < 2.5:
		var yaw := deg_to_rad(200.0) if t >= 0.2 and t < 1.0 else 0.0
		m.update(1.0, yaw, 0.0, 1.0, DT)
		st.append(Vector2(t, m.strength))
		tg.append(Vector2(t, m.target))
		t += DT
	c.set("series", [_line("target", tg, 1), _line("strength", st, 0)])
	_axes(c, 0, 2.5, [0, 0.5, 1.0, 1.5, 2.0, 2.5], 0, 1.05, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "time (s)", "strength")
	c.set("x_fmt", "%.1f")
	c.set("legend_at", Vector2(0.62, 0.3))
	return [a, sp, b, c, await _vignette_wingbeat(), await _vignette_orchard()]


## Steady, straight, level flight at a sparrow's 9 m/s (world_scale 0.141,
## setting 0.6, 72 Hz ticks) 1 m above orchard crowns 4 m long with 4 m
## gaps, then a sustained +2 m/s² surge from t = 5 s. Round 3's vignette
## (optic flow from 3 single rays, one per tick, forgotten on a miss, and a
## per-tick proximity; emulated here from its formula) against now.
func _vignette_orchard() -> Control:
	const Q := 1.0 / 72.0
	XRServer.world_scale = 0.141
	var ws := 0.141
	var w := Node3D.new()
	add_child(w)
	var z := -1.0
	while z > -300.0:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(4.0, 2.0, 4.0)
		cs.shape = bs
		sb.add_child(cs)
		sb.position = Vector3(0.0, -2.0, z - 2.0)
		w.add_child(sb)
		z -= 8.0
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, 1.6, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	v.setting_override = 0.6
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	body.position = Vector3(0, -1.6, 0)
	add_child(body)
	for i in 3:
		await get_tree().physics_frame
	v.origin = origin
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = 1 | 2
	var old := VignetteModel.new()
	var old_d := [INF, INF, INF]
	var now := PackedVector2Array()
	var prox := PackedVector2Array()
	var before := PackedVector2Array()
	var spd := 9.0
	var t := 0.0
	var k := 0
	while t < 9.0:
		t += Q
		if t >= 5.0:
			spd += 2.0 * Q
		body.position += Vector3(0, 0, -spd) * Q
		v.measure(Q)
		now.append(Vector2(t, v.update_strength(Q)))
		prox.append(Vector2(t, v.proximity))
		# Round 3: one of right / left / down per tick, a miss forgets it.
		var dirs := [Vector3.RIGHT, Vector3.LEFT, Vector3.DOWN]
		var from := cam.global_position
		var reach := maxf(8.0 * 1.7 * ws, spd / 2.5 * 1.2)
		q.from = from
		q.to = from + (dirs[k] as Vector3) * reach
		var hit := space.intersect_ray(q)
		old_d[k] = INF if hit.is_empty() else maxf(from.distance_to(hit["position"]), 0.1 * ws)
		k = (k + 1) % 3
		var flow := 0.0
		var near := INF
		for j in 3:
			if old_d[j] < INF:
				var dj: Vector3 = dirs[j]
				var vel := Vector3(0, 0, -spd)
				flow = maxf(flow, (vel - dj * vel.dot(dj)).length() / old_d[j])
				near = minf(near, old_d[j])
		var p3 := ComfortVignette.accel_proximity(near, ws)
		var tgt := 0.6 * maxf(0.7 * VRMath.sstep(2.5, 9.0, flow), 0.5 * VRMath.sstep(6.0, 20.0, v.accel / ws) * p3)
		old.strength += (tgt - old.strength) * VRMath.lp(Q, 0.08 if tgt > old.strength else 0.5)
		before.append(Vector2(t, old.strength))
	body.queue_free()
	w.queue_free()
	XRServer.world_scale = 1.0
	var d := _plot("Steady flight over orchard crowns", "sparrow 9 m/s, 1 m above 4 m crowns / 4 m gaps, setting 0.6; +2 m/s² from 5 s")
	d.set("series", [_line("round 3 (flow on 3 single rays)", before, 1), _line("now: strength", now, 0),
		_line("now: proximity (slow)", prox, 2)])
	_axes(d, 0, 9, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 0, 1.05, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "time (s)", "strength / proximity")
	d.set("vlines", [{"x": 5.0, "text": "surge"}])
	d.set("legend_at", Vector2(0.03, 0.04))
	return d


## A sparrow (world_scale 0.141) flapping straight in open sky at 1 Hz
## (surge 0.45 m/s and heave 0.55 m/s at the stroke frequency, plus a
## second harmonic: flight's real PlayerBird's amplitudes), then driving
## hard (+2.5 m/s² for 2 s) from t = 5 s. The round-1 acceleration (a 0.1 s
## low-pass) against the stroke average of fix round 2, at setting 0.6.
func _vignette_wingbeat() -> Control:
	XRServer.world_scale = 0.141
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var v := ComfortVignette.new()
	v.auto_update = false
	v.setting_override = 0.6
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	body.position = Vector3(0, 5000, 0)
	add_child(body)
	var p: Bird = StubPlayer.new()
	p.set(&"wing_state_obj", FakeWingState.new())
	add_child(p)
	await get_tree().process_frame
	v.origin = origin
	var old := VignetteModel.new()
	var near_model := VignetteModel.new()
	var old_acc := Vector3.ZERO
	var prev_vel := Vector3.ZERO
	var now := PackedVector2Array()
	var now_near := PackedVector2Array()
	var before := PackedVector2Array()
	var base := 8.0
	var t := 0.0
	while t < 8.0:
		t += DT
		if t >= 5.0 and t < 7.0:
			base += 2.5 * DT
		var ph := TAU * t
		var vel := Vector3(0.0, 0.55 * sin(ph) + 0.2 * sin(2.0 * ph + 0.7), -(base + 0.45 * sin(ph + 1.1) + 0.15 * sin(2.0 * ph)))
		body.position += vel * DT
		v.measure(DT)
		now.append(Vector2(t, v.update_strength(DT)))
		# The same measured acceleration with a surface within 3 body spans
		# (proximity 1): where the acceleration term counts (fix round 3).
		now_near.append(Vector2(t, near_model.update(0.6, v.yaw_rate, v.accel, 0.141, DT, 1.0)))
		# Round 1: instantaneous acceleration through a 0.1 s low-pass.
		if t > DT * 1.5:
			old_acc = old_acc.lerp((vel - prev_vel) / DT, VRMath.lp(DT, 0.10))
		prev_vel = vel
		var felt := ComfortVignette._felt_vec(old_acc, vel).length()
		before.append(Vector2(t, old.update(0.6, 0.0, felt, 0.141, DT, 1.0)))
	p.queue_free()
	body.queue_free()
	XRServer.world_scale = 1.0
	var d := _plot("A flapping sparrow (1 Hz strokes), then a real surge", "straight flight, setting 0.6; +2.5 m/s² from 5 s to 7 s")
	d.set("series", [_line("round 1 (0.1 s low-pass, any sky)", before, 1), _line("now, a surface within 3 spans", now_near, 0),
		_line("now, open sky (nothing within 8 spans)", now, 2)])
	_axes(d, 0, 8, [0, 1, 2, 3, 4, 5, 6, 7, 8], 0, 0.4, [0.0, 0.1, 0.2, 0.3, 0.4], "time (s)", "strength")
	d.set("vlines", [{"x": 5.0, "text": "surge"}, {"x": 7.0, "text": ""}])
	d.set("legend_at", Vector2(0.03, 0.04))
	return d


func _axes(p: Control, x0: float, x1: float, xt: Array, y0: float, y1: float, yt: Array, xl: String, yl: String) -> void:
	p.set("x_min", x0)
	p.set("x_max", x1)
	p.set("x_ticks", xt)
	p.set("y_min", y0)
	p.set("y_max", y1)
	p.set("y_ticks", yt)
	p.set("x_label", xl)
	p.set("y_label", yl)


# --- world scale -------------------------------------------------------------------

func _world_scale() -> Array:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	add_child(origin)
	var d := WorldScaleDriver.new()
	d.auto_step = false
	d.origin = origin
	d.camera = cam
	d.arm_span_override = 1.5
	d.exponent_override = 1.0
	add_child(d)
	d.mass_override = 0.03
	d.snap()
	var ws := PackedVector2Array()
	var tgt := PackedVector2Array()
	var near := PackedVector2Array()
	var t := 0.0
	var respawned := false
	while t < 20.0:
		if t < 1.0:
			d.mass_override = 0.03
		elif t < 12.0:
			# Growth in play (the plot compresses a run's growth into one
			# step to show the ramp): sparrow -> eagle.
			d.mass_override = 3.0
		elif t >= 12.0 and t < 15.0:
			# Caught at 12 s: the player respawns as a pigeon behind the fade.
			# The game snaps on Events.player_spawned (the driver's own
			# handler, called here as the signal would).
			d.mass_override = 0.3
			if not respawned:
				respawned = true
				d.snap()
		else:
			# Growth in play again: pigeon -> crow.
			d.mass_override = 0.5
		d.step(DT)
		ws.append(Vector2(t, d.world_scale))
		tgt.append(Vector2(t, d.target))
		near.append(Vector2(t, cam.near * 100.0))
		t += DT
	origin.queue_free()
	d.queue_free()
	XRServer.world_scale = 1.0
	var a := _plot("world_scale: growth ramps, a respawn snaps", "growth ramps <= 0.25 ln/s (eagle at 1 s, crow at 15 s); caught at 12 s: respawn as pigeon snaps")
	a.set("series", [_line("target", tgt, 1), _line("world_scale", ws, 0)])
	_axes(a, 0, 20, [0, 4, 8, 12, 16, 20], 0, 1.4, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4], "time (s)", "world_scale")
	a.set("legend_at", Vector2(0.12, 0.2))
	a.set("hlines", [{"y": 0.24 / 1.7, "text": "sparrow 0.141"}, {"y": 2.1 / 1.7, "text": "eagle 1.235"}, {"y": 0.66 / 1.7, "text": "pigeon 0.388"},
		{"y": 0.95 / 1.7, "text": "crow 0.559"}])
	var b := _plot("Camera near plane", "0.03 x world_scale (>= 1 mm): no clipping of near hands")
	b.set("series", [_line("near", near, 0)])
	_axes(b, 0, 20, [0, 4, 8, 12, 16, 20], 0, 4.0, [0.0, 1.0, 2.0, 3.0, 4.0], "time (s)", "near plane (cm)")
	return [a, b]


# --- haptics -----------------------------------------------------------------------

class Rec:
	extends RefCounted
	var h: VRHaptics
	var calls: Array = []

	func pulse(hand: int, amp: float, dur: float) -> void:
		if hand == 0:
			calls.append([h.now(), amp, dur])


func _haptics() -> Array:
	var names := HapticPatterns.names()
	var starts := PackedVector2Array()
	var widths := PackedFloat32Array()
	var amps := PackedFloat32Array()
	var row := 0
	for name in names:
		var h := VRHaptics.new()
		h.listen_to_events = false
		h.poll_player = false
		h.auto_tick = false
		h.intensity_override = 1.0
		var rec := Rec.new()
		rec.h = h
		h.sink = rec
		add_child(h)
		match name:
			&"stall":
				h.set_stall(0.7)
			&"updraft":
				h.set_updraft(3.0, 3.0)
			&"danger":
				h.set_danger(0.9)
			_:
				h.play(name, VRHaptics.MASK_BOTH, 0.7)
		for i in int(1.2 / DT):
			if name == &"danger":
				h.set_danger(0.9)
			h.tick(DT)
		for c in rec.calls:
			starts.append(Vector2(float(c[0]) - DT, row))
			widths.append(c[2])
			amps.append(c[1])
		h.queue_free()
		row += 1
	var p := _plot("Haptic patterns: rhythm per game fact (left hand, first 1.2 s)",
		"bar = one pulse (width = duration, height = amplitude); rate limits and duty shares applied (all 30 %, rhythms 15 %, routine 21 %); Quest ignores frequency")
	p.set("rows", names.map(func(n: StringName) -> String: return String(n)))
	p.set("series", [{"name": "pulse", "points": starts, "widths": widths, "amps": amps, "kind": "pulses", "color_index": 0}])
	_axes(p, 0, 1.2, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2], 0, 1, [], "time since the event (s)", "")
	p.set("x_fmt", "%.1f")
	return [p]


# --- calibration --------------------------------------------------------------------

func _feed(cal: WingCalibrator, h: VRHumanPose, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		cal.measure(h.head_transform(), h.hand_transform(0), h.hand_transform(1), 7, DT)


func _calibrated(h: VRHumanPose) -> WingCalibrator:
	var cal := WingCalibrator.new()
	# The calibration step: the player was asked for the pose.
	cal.request_capture()
	h.spread_pose()
	_feed(cal, h, 2.0)
	return cal


func _calibration() -> Array:
	# A: flat wrists vs the player's habitual wrist roll.
	var unc := PackedVector2Array()
	var cald := PackedVector2Array()
	for off in range(-25, 26, 5):
		var h := VRHumanPose.for_span(1.6)
		h.twist_offset = [deg_to_rad(off), deg_to_rad(off)]
		var c0 := WingCalibrator.new()
		h.set_arms(0.0)
		_feed(c0, h, 0.1)
		unc.append(Vector2(off, rad_to_deg(c0.twist[1])))
		var c1 := _calibrated(h)
		h.set_arms(0.0)
		_feed(c1, h, 0.1)
		cald.append(Vector2(off, rad_to_deg(c1.twist[1])))
	var a := _plot("Flat wrists read as", "players holding 'flat' with a wrist roll of -25..+25° (span 1.6 m)")
	a.set("series", [_line("uncalibrated", unc, 1), _line("calibrated", cald, 0)])
	_axes(a, -25, 25, [-25, -15, -5, 5, 15, 25], -30, 30, [-30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 30.0], "player's wrist habit (deg)", "twist read (deg)")
	a.set("y_fmt", "%.0f")
	a.set("legend_at", Vector2(0.03, 0.04))
	# B: half-folded wing extension vs arm span.
	var ue := PackedVector2Array()
	var ce := PackedVector2Array()
	for i in 13:
		var span := 1.4 + i * 0.05
		var h := VRHumanPose.for_span(span)
		var c0 := WingCalibrator.new()
		h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
		_feed(c0, h, 0.1)
		ue.append(Vector2(span, c0.extension[1]))
		var c1 := _calibrated(h)
		h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
		_feed(c1, h, 0.1)
		ce.append(Vector2(span, c1.extension[1]))
	var b := _plot("Half-folded wing reads as", "elbows bent 105°, arms 20° low; grip-to-grip span 1.4..2.0 m")
	b.set("series", [_line("uncalibrated (1.5 m assumed)", ue, 1), _line("calibrated", ce, 0)])
	_axes(b, 1.4, 2.0, [1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0], 0, 1.0, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], "player's arm span (m)", "extension")
	b.set("x_fmt", "%.1f")
	b.set("legend_at", Vector2(0.03, 0.04))
	# C: both wrists LE up 20° -> pitch command, 16 players.
	var up := PackedVector2Array()
	var cp := PackedVector2Array()
	var k := 1
	for span in [1.4, 1.6, 1.8, 2.0]:
		for off in [[-25.0, -25.0], [0.0, 0.0], [25.0, 25.0], [25.0, -25.0]]:
			var h := VRHumanPose.for_span(span)
			h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
			var c0 := WingCalibrator.new()
			h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(20.0), deg_to_rad(10.0))
			_feed(c0, h, 0.1)
			up.append(Vector2(k, c0.pitch_command()))
			var c1 := _calibrated(h)
			h.set_arms(deg_to_rad(-5.0), 0.0, deg_to_rad(20.0), deg_to_rad(10.0))
			_feed(c1, h, 0.1)
			cp.append(Vector2(k, c1.pitch_command()))
			k += 1
	var c := _plot("'Both wrists up 20°' -> pitch command", "16 players: spans 1.4/1.6/1.8/2.0 m x wrist habits -25/0/+25/±25°")
	c.set("series", [{"name": "uncalibrated", "points": up, "kind": "dots", "color_index": 1}, {"name": "calibrated", "points": cp, "kind": "dots", "color_index": 0}])
	_axes(c, 0, 17, [1, 4, 8, 12, 16], -1.1, 1.1, [-1.0, -0.5, 0.0, 0.5, 1.0], "player", "pitch command")
	c.set("hlines", [{"y": 0.305, "text": "spec 0.31"}])
	c.set("legend_at", Vector2(0.03, 0.72))
	# D: how the arms were held at capture no longer changes the readings,
	# whoever captured: VR itself, or flight (FLIGHT_SPEC §5.10 as written:
	# arms-5°-low drop, neutral as held) refined on adoption. Flight's
	# capture read as is was what the player flew until fix round 2.
	var ne := PackedVector2Array()
	var np := PackedVector2Array()
	var fe := PackedVector2Array()
	var fp := PackedVector2Array()
	var re := PackedVector2Array()
	var rp := PackedVector2Array()
	for el in range(-12, 9, 2):
		var h := VRHumanPose.for_span(1.6)
		h.set_arms(deg_to_rad(el))
		var c1 := WingCalibrator.new()
		c1.request_capture()
		_feed(c1, h, 2.2)
		var fl := _flight_like_capture(h)
		var rf := _flight_like_capture(h)
		_feed(rf, h, 0.05)
		rf.adopt(_Fields.new(rf))
		h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
		for cal in [c1, fl, rf]:
			_feed(cal, h, 0.15)
		ne.append(Vector2(el, c1.extension[1]))
		np.append(Vector2(el, c1.pitch_command()))
		fe.append(Vector2(el, fl.extension[1]))
		fp.append(Vector2(el, fl.pitch_command()))
		re.append(Vector2(el, rf.extension[1]))
		rp.append(Vector2(el, rf.pitch_command()))
	var d := _plot("Half fold read after capturing with arms at...", "same player and gesture; only the arm height during the capture changes")
	d.set("series", [_line("VR's capture: extension", ne, 0), _line("VR's capture: pitch", np, 2),
		{"name": "flight's, refined on adoption: ext.", "points": re, "kind": "dots", "color_index": 0},
		{"name": "flight's, refined on adoption: pitch", "points": rp, "kind": "dots", "color_index": 2},
		{"name": "flight's as is (round 1): extension", "points": fe, "kind": "dots", "color_index": 1},
		{"name": "flight's as is (round 1): pitch", "points": fp, "kind": "dots", "color_index": 3}])
	_axes(d, -12, 8, [-12, -8, -4, 0, 4, 8], 0.0, 0.7, [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7], "arm elevation at capture (deg)", "reading")
	d.set("legend_at", Vector2(0.03, 0.04))
	return [a, b, c, d]


## FLIGHT_SPEC §5.10 as flight's WingInput implements it (this plot's own
## copy, as in calibration_test): span = grip-to-grip, drop assuming the
## arms 5° low, neutral as held. Returns a calibrator holding those fields
## (nothing capturing), fed nothing yet.
func _flight_like_capture(h: VRHumanPose) -> WingCalibrator:
	var hd := h.head_transform()
	var l := h.hand_transform(0)
	var r := h.hand_transform(1)
	var cal := WingCalibrator.new()
	var span := clampf((r.origin - l.origin).length(), 1.0, 2.2)
	var sw := 0.23 * span
	var l_arm := (span - sw) * 0.5
	var drop := clampf(hd.origin.y - 0.5 * (l.origin.y + r.origin.y) - l_arm * sin(deg_to_rad(5.0)), 0.15, 0.35)
	var f := Vector3.UP.cross(VRMath.horiz(r.origin - l.origin)).normalized()
	var b := Basis(Vector3.UP, VRMath.yaw_of(f))
	var rt := f.cross(Vector3.UP)
	var neck := hd.origin + hd.basis * Vector3(0.0, -0.08, 0.09)
	var centre := neck + Vector3(0.0, -(drop - 0.08), 0.0) - f * 0.02
	var sh := [centre - rt * sw * 0.5, centre + rt * sw * 0.5]
	var hands := [l, r]
	for i in 2:
		var hb: Basis = (hands[i] as Transform3D).basis
		var a := (hb.transposed() * ((hands[i] as Transform3D).origin - (sh[i] as Vector3)).normalized()).normalized()
		var c := hb.transposed() * f
		cal.neutral[i] = b.transposed() * hb
		cal.forearm_axis[i] = a
		cal.chord_axis[i] = (c - a * c.dot(a)).normalized()
	cal.arm_span = span
	cal.shoulder_width = sw
	cal.shoulder_drop = drop
	cal.calibrated = true
	return cal


## The fields of a calibrator as a WingCalibration look-alike (for adopt()).
class _Fields:
	extends RefCounted
	var d: Dictionary

	func _init(c: WingCalibrator) -> void:
		d = c.to_dict()

	func to_dict() -> Dictionary:
		return d


# --- comfort R1: world_scale exponent -----------------------------------------------

func _comfort() -> Array:
	var labels := []
	var ticks := []
	var v1 := PackedVector2Array()
	var v8 := PackedVector2Array()
	var e1 := PackedVector2Array()
	var e8 := PackedVector2Array()
	var flow := PackedVector2Array()
	var i := 0
	for s in SizeRules.SPECIES:
		if s["id"] == &"moth":
			continue
		var mass: float = s["mass"]
		var cruise: float = SizeRules.performance(mass)["cruise"]
		var span := SizeRules.wingspan_for_mass(mass)
		var ws1 := WorldScaleDriver.target_scale(mass, 1.5, 1.0)
		var ws8 := WorldScaleDriver.target_scale(mass, 1.5, 0.8)
		v1.append(Vector2(i, cruise / ws1))
		v8.append(Vector2(i, cruise / ws8))
		e1.append(Vector2(i, 1.0))
		e8.append(Vector2(i, ws8 / ws1))
		# Flying at 3 wingspans from a wall / the ground: the angular flow.
		flow.append(Vector2(i, cruise / (3.0 * span)))
		ticks.append(i)
		labels.append(String(s["name"]))
		i += 1
	var a := _plot("Perceived cruise speed", "cruise / world_scale: how fast the world rushes by in 'human' metres")
	a.set("series", [{"name": "exponent 1.0 (exact)", "points": v1, "kind": "bars", "color_index": 0, "offset": -0.5},
		{"name": "exponent 0.8", "points": v8, "kind": "bars", "color_index": 1, "offset": 0.5}])
	_axes(a, -0.7, i - 0.3, ticks, 0, 80, [0.0, 20.0, 40.0, 60.0, 80.0], "species", "m/s")
	a.set("x_tick_labels", labels)
	a.set("y_fmt", "%.0f")
	a.set("legend_at", Vector2(0.55, 0.04))
	var b := _plot("Own wings vs a same-size NPC", "drawn span / true span: the eat-or-flee size cue")
	b.set("series", [_line("exponent 1.0", e1, 0), _line("exponent 0.8", e8, 1)])
	_axes(b, -0.7, i - 0.3, ticks, 0.8, 1.7, [0.8, 1.0, 1.2, 1.4, 1.6], "species", "ratio")
	b.set("x_tick_labels", labels)
	b.set("legend_at", Vector2(0.55, 0.04))
	var c := _plot("Angular optic flow at cruise", "3 wingspans from a surface: identical for every exponent (scale-free)")
	c.set("series", [{"name": "flow", "points": flow, "kind": "bars", "color_index": 2}])
	_axes(c, -0.7, i - 0.3, ticks, 0, 18, [0.0, 3.0, 6.0, 9.0, 12.0, 15.0, 18.0], "species", "rad/s")
	c.set("x_tick_labels", labels)
	c.set("y_fmt", "%.0f")
	return [a, b, c]
