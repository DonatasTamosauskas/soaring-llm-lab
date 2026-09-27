extends TestCase
## V4: comfort vignette. The strength curve (yaw rate, speed over the
## bird's cruise (fix round 5) and perceived acceleration near a surface;
## attack 0.08 s, release 0.5 s) is pinned numerically; the setting scales it and 0 turns it off completely (no
## pixels, no draw call); the rig's own motion is measured correctly (yaw
## rate, a teleport is not motion); steady flight past broken surfaces
## (orchard crowns, forest trunks, a fence line) never pulses it (fix round
## 4); the aperture is angular, so it is the same at every world_scale.
## Screenshots at rest vs a hard turn: tests/shots/vr_shots.gd
## (artifacts/vr/vignette_*.png).

const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 90.0


## PlayerBird.wing_state() look-alike: what the vignette reads of it.
class FakeWingState:
	extends RefCounted
	var stroke_period := 1.0
	var flapping := 1.0
	var ext_l := 1.0
	var ext_r := 1.0


func before_all() -> void:
	# world_scale is global XRServer state; these rigs assume 1.
	XRServer.world_scale = 1.0


func test_strength_curve() -> void:
	var t := VignetteModel.target_for
	near(t.call(1.0, 0.0, 0.0, 1.0), 0.0, 1e-6, "at rest: nothing")
	near(t.call(1.0, deg_to_rad(35.0), 0.0, 1.0), 0.0, 1e-6, "35°/s turn: still nothing (threshold)")
	near(t.call(1.0, deg_to_rad(92.5), 0.0, 1.0), 0.5, 1e-3, "92.5°/s: half")
	near(t.call(1.0, deg_to_rad(150.0), 0.0, 1.0), 1.0, 1e-6, "150°/s: full")
	near(t.call(1.0, deg_to_rad(-150.0), 0.0, 1.0), 1.0, 1e-6, "left and right turns alike")
	near(t.call(1.0, 0.0, 20.0, 1.0), 0.5, 1e-6, "20 m/s² at world_scale 1: 0.5")
	near(t.call(1.0, 0.0, 3.0, 0.15), 0.5, 1e-6, "3 m/s² at world_scale 0.15 = 20 perceived: 0.5")
	near(t.call(1.0, 0.0, 13.0, 1.0), 0.25, 1e-6, "13 m/s² perceived (mid-range): 0.25")
	near(t.call(1.0, 0.0, 6.0, 1.0), 0.0, 1e-6, "6 m/s² perceived: nothing")
	# Fix round 3: the acceleration term counts only with a surface near
	# enough to judge the motion by (proximity 1 within 3 body spans).
	near(t.call(1.0, 0.0, 20.0, 1.0, 1.0), 0.5, 1e-6, "20 m/s² with a surface near: 0.5")
	near(t.call(1.0, 0.0, 20.0, 1.0, 0.5), 0.25, 1e-6, "half proximity: half the term")
	near(t.call(1.0, 0.0, 50.0, 0.15, 0.0), 0.0, 1e-6, "nothing near (open sky): an acceleration alone never narrows")
	near(t.call(1.0, deg_to_rad(150.0), 50.0, 0.15, 0.0), 1.0, 1e-6, "open sky: a hard turn still closes it")
	near(t.call(1.0, deg_to_rad(150.0), 20.0, 1.0), 1.0, 1e-6, "terms combine by max, capped at 1")
	near(t.call(1.0, deg_to_rad(100.0), 20.0, 1.0), maxf(VRMath.sstep(deg_to_rad(35.0), deg_to_rad(150.0), deg_to_rad(100.0)), 0.5), 1e-6, "by max, not by sum")
	near(t.call(0.6, deg_to_rad(150.0), 0.0, 1.0), 0.6, 1e-6, "the setting scales it")
	# Fix round 5: speed, as the rig's speed over the bird's own cruise.
	near(t.call(1.0, 0.0, 0.0, 1.0, 0.0, 1.0), 0.0, 1e-6, "cruise: nothing")
	near(t.call(1.0, 0.0, 0.0, 0.141, 1.0, 1.3), 0.0, 1e-6, "1.3 x cruise: still nothing (threshold), near a surface or not")
	near(t.call(1.0, 0.0, 0.0, 1.0, 0.0, 1.8), 0.35, 1e-6, "1.8 x cruise: half of the speed weight 0.7")
	near(t.call(1.0, 0.0, 0.0, 1.0, 0.0, 2.3), 0.7, 1e-6, "2.3 x cruise: the full speed weight 0.7")
	near(t.call(1.0, 0.0, 0.0, 1.0, 0.0, 2.6), 0.7, 1e-6, "a 2.6 x cruise dive (flight's limit): 0.7")
	near(t.call(0.6, 0.0, 0.0, 1.0, 0.0, 2.3), 0.42, 1e-6, "the default setting 0.6: 0.42")
	near(t.call(1.0, deg_to_rad(150.0), 0.0, 1.0, 0.0, 2.3), 1.0, 1e-6, "a hard turn in a dive: closed (max)")
	near(t.call(1.0, deg_to_rad(92.5), 0.0, 1.0, 0.0, 2.3), 0.7, 1e-3, "by max, not by sum (0.5 turn, 0.7 speed)")
	near(t.call(1.0, 0.0, 20.0, 1.0, 1.0, 1.8), 0.5, 1e-6, "by max with the acceleration term (0.5 vs 0.35)")
	for yaw in [0.0, 100.0, 150.0, 400.0]:
		for acc in [0.0, 20.0, 50.0]:
			eq(t.call(0.0, deg_to_rad(yaw), acc, 0.1), 0.0, "setting 0: zero at yaw %.0f accel %.0f" % [yaw, acc])
			eq(t.call(0.0, deg_to_rad(yaw), acc, 0.1, 1.0, 2.6), 0.0, "setting 0: zero at yaw %.0f accel %.0f in a 2.6 x dive" % [yaw, acc])
	var prev_s := -1.0
	for i in 41:
		var r := 0.065 * i
		var sv: float = t.call(1.0, 0.0, 0.0, 1.0, 0.0, r)
		check(sv >= prev_s - 1e-9, "monotonic in speed (%.2f x cruise)" % r)
		prev_s = sv
	var prev := -1.0
	var samples: Array = []
	for i in 41:
		var yaw := deg_to_rad(5.0 * i)
		var v: float = t.call(1.0, yaw, 0.0, 1.0)
		check(v >= prev - 1e-9, "monotonic in yaw rate (%.0f°/s)" % (5.0 * i))
		prev = v
		samples.append([5.0 * i, snappedf(v, 0.001)])
	metric("yaw_curve", samples)


func test_attack_and_release() -> void:
	var m := VignetteModel.new()
	var hard := deg_to_rad(200.0)
	for i in int(round(0.08 / DT)):
		m.update(1.0, hard, 0.0, 1.0, DT)
	near(m.strength, 1.0 - exp(-1.0), 0.03, "attack: 63% of the step within 0.08 s")
	for i in int(1.0 / DT):
		m.update(1.0, hard, 0.0, 1.0, DT)
	gt(m.strength, 0.99, "fully closed in a sustained hard turn")
	for i in int(round(0.5 / DT)):
		m.update(1.0, 0.0, 0.0, 1.0, DT)
	near(m.strength, exp(-1.0), 0.03, "release: back to 37% after 0.5 s")
	for i in int(4.0 / DT):
		m.update(1.0, 0.0, 0.0, 1.0, DT)
	eq(m.strength, 0.0, "fully open again at rest")
	for i in 10:
		m.update(1.0, hard, 0.0, 1.0, DT)
	m.update(0.0, hard, 0.0, 1.0, DT)
	eq(m.strength, 0.0, "turning the setting off clears it at once")


## Rig: a yaw-only mover (the flight area's PlayerBird role) -> XROrigin3D
## -> XRCamera3D -> ComfortVignette.
func make_rig() -> Dictionary:
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, 1.6, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	add_child(body)
	v.origin = origin
	return {"body": body, "origin": origin, "camera": cam, "vignette": v}


func step(rig: Dictionary, velocity: Vector3, yaw_rate: float) -> void:
	var body := rig["body"] as Node3D
	body.rotate_y(yaw_rate * DT)
	body.position += velocity * DT
	(rig["vignette"] as ComfortVignette).measure(DT)
	(rig["vignette"] as ComfortVignette).update_strength(DT)


func test_measures_the_rig_turn_and_closes() -> void:
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 1.0
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(120.0))
	near(rad_to_deg(v.yaw_rate), 120.0, 1.0, "yaw rate measured on the rig")
	near(v.strength(), VignetteModel.target_for(1.0, deg_to_rad(120.0), 0.0, 1.0), 0.01, "settles on the curve")
	check(v.visible, "visible while turning")
	v.setting_override = 0.0
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(200.0))
		if i % 30 == 0:
			check(v.strength() == 0.0 and not v.visible, "setting 0: never drawn (tick %d)" % i)
	eq(v.strength(), 0.0, "setting 0: strength 0 in a 200°/s turn")
	check(not v.visible, "setting 0: hidden (zero draw calls)")
	(rig["body"] as Node).queue_free()


func test_turns_count_once_speed_changes_count() -> void:
	XRServer.world_scale = 0.141
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 1.0
	# A sparrow circling at 30 m radius, 9 m/s: yaw 17°/s, centripetal
	# 2.7 m/s² (19 perceived) - a gentle turn keeps the full view.
	var body := rig["body"] as Node3D
	var worst := 0.0
	var ang := 0.0
	# (The first tick is a real 0 -> 9 m/s surge; judge the steady circle
	# after 2 s, once the filters have settled.)
	for i in int(6.0 / DT):
		ang += 0.3 * DT
		body.rotation.y = ang
		body.position = Vector3(30.0 * cos(ang) - 30.0, 0.0, -30.0 * sin(ang))
		v.measure(DT)
		v.update_strength(DT)
		if i * DT > 2.0:
			worst = maxf(worst, v.model.target)
	lt(v.accel, 0.3, "centripetal acceleration of a steady turn not counted (%.2f m/s²)" % v.accel)
	eq(worst, 0.0, "gentle small-bird circle: target 0 throughout")
	eq(v.strength(), 0.0, "gentle small-bird circle: full view")
	# Braking hard (a flare): 3 m/s² along the path = 21 perceived, for 1.6 s
	# (longer than the stroke-average and smoothing windows, 0.8 + 0.5 s).
	var speed := 9.0
	for i in int(1.6 / DT):
		speed = maxf(0.0, speed - 3.0 * DT)
		body.position += -body.global_basis.z * speed * DT
		v.measure(DT)
		v.update_strength(DT)
	near(v.accel, 3.0, 0.3, "a speed change is measured in full")
	# In open sky there is nothing near to see it by (fix round 3).
	eq(v.proximity, 0.0, "open sky: nothing within 8 body spans")
	eq(v.model.accel_term, 0.0, "open sky: the flare's acceleration term is 0")
	eq(v.strength(), 0.0, "open sky: a flare keeps the full view")
	# The same flare 0.5 m above a floor (3.5 perceived m, within 3 body
	# spans): the acceleration term counts in full.
	var floor := StaticBody3D.new()
	floor.collision_layer = 1
	var fs := CollisionShape3D.new()
	var fb := BoxShape3D.new()
	fb.size = Vector3(400.0, 0.2, 400.0)
	fs.shape = fb
	floor.add_child(fs)
	add_child(floor)
	body.position = Vector3(0.0, 0.0, 0.0)
	floor.position = Vector3(0.0, 1.6 - 0.5 - 0.1, 0.0)
	await wait_physics(2)
	v.reset_motion()
	speed = 9.0
	var term := 0.0
	var prox_at_2s := 0.0
	var steady_peak := 0.0
	# 2 s of steady flight over the floor (the proximity is slow: it rises
	# with PROX_TAU = 1 s), then the flare.
	for i in int(3.6 / DT):
		speed = maxf(0.0, speed - 3.0 * DT) if i * DT > 2.0 else speed
		body.position += -body.global_basis.z * speed * DT
		v.measure(DT)
		v.update_strength(DT)
		term = maxf(term, v.model.accel_term)
		if absf(i * DT - 2.0) < 0.5 * DT:
			prox_at_2s = v.proximity
		if i * DT <= 2.0:
			steady_peak = maxf(steady_peak, v.strength())
	eq(steady_peak, 0.0, "steady flight 0.5 m above the floor: the full view")
	near(v.nearest, 0.5, 0.02, "the floor is found 0.5 m below the eyes")
	near(prox_at_2s, 1.0 - exp(-2.0 / ComfortVignette.PROX_TAU), 0.03, "the proximity rises slowly (%.3f after 2 s, time constant %.1f s)" % [prox_at_2s, ComfortVignette.PROX_TAU])
	gt(v.proximity, 0.95, "0.5 m at world_scale 0.141 = 3.5 perceived m: within 3 body spans")
	gt(term, 0.9, "near a surface the flare's acceleration term counts in full (%.2f)" % term)
	floor.queue_free()
	XRServer.world_scale = 1.0
	(rig["body"] as Node).queue_free()


## Proximity: 1 with a surface within 3 body spans (1.7 m x world_scale
## each), 0 beyond 8 or with none, smooth and monotonic between, at every
## world_scale.
func test_accel_proximity() -> void:
	var rows := {}
	for ws in [0.141, 0.388, 1.235]:
		var span: float = 1.7 * ws
		eq(ComfortVignette.accel_proximity(INF, ws), 0.0, "ws %.3f: no surface in reach = 0" % ws)
		eq(ComfortVignette.accel_proximity(0.5 * span, ws), 1.0, "ws %.3f: half a span = 1" % ws)
		eq(ComfortVignette.accel_proximity(3.0 * span, ws), 1.0, "ws %.3f: 3 spans = 1" % ws)
		eq(ComfortVignette.accel_proximity(8.0 * span, ws), 0.0, "ws %.3f: 8 spans = 0" % ws)
		near(ComfortVignette.accel_proximity(5.5 * span, ws), 0.5, 1e-6, "ws %.3f: 5.5 spans = 0.5" % ws)
		var prev := 2.0
		for i in 101:
			var p := ComfortVignette.accel_proximity(0.1 * i * span, ws)
			check(p <= prev + 1e-9, "ws %.3f: monotonic (%.1f spans)" % [ws, 0.1 * i])
			prev = p
		rows["ws %.3f: 1 within, 0 beyond (m)" % ws] = [snappedf(3.0 * span, 0.01), snappedf(8.0 * span, 0.01)]
	# The probe rays reach exactly the far edge (8 spans), so the term fades
	# out before a surface leaves their reach instead of dropping.
	metric("accel_proximity_edges_m", rows)


## Flight's only yaw steps are deliberate one-tick re-aims (respawn,
## recenter: PlayerBird.yaw_flagged); real turns are capped at 240°/s in its
## physics. A step must never flash the vignette, while the fastest real
## turn (240°/s) still closes it.
func test_yaw_steps_are_not_turns() -> void:
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 0.6
	var body := rig["body"] as Node3D
	# Open sky, far above anything other tests left in the tree.
	body.position = Vector3(0, 5000, 0)
	var peak := 0.0
	for angle in [15.0, 45.0, 90.0, 120.0, 180.0]:
		v.reset_motion()
		for i in 30:
			step(rig, -body.global_basis.z * 8.0, 0.0)
		body.rotate_y(deg_to_rad(angle))
		for i in int(1.5 / DT):
			step(rig, -body.global_basis.z * 8.0, 0.0)
			peak = maxf(peak, v.strength())
	eq(peak, 0.0, "one-tick yaw steps of 15-180° while gliding: no vignette at all (peak %.3f)" % peak)
	# A small step on a flagged tick (below the rate test) is skipped too.
	var p: Bird = StubPlayer.new()
	add_child(p)
	v.reset_motion()
	for i in 30:
		step(rig, Vector3.ZERO, 0.0)
	var jumps := v.jumps
	p.set(&"yaw_flagged", true)
	body.rotate_y(deg_to_rad(5.0))
	v.measure(DT)
	p.set(&"yaw_flagged", false)
	eq(v.jumps, jumps + 1, "PlayerBird.yaw_flagged tick re-seeded, not measured")
	# VR.recentered re-seeds the next tick whatever its size.
	VR.recentered.emit()
	body.rotate_y(deg_to_rad(4.0))
	v.measure(DT)
	eq(v.jumps, jumps + 2, "the tick after VR.recentered is re-seeded")
	near(v.yaw_rate, 0.0, 1e-9, "no yaw rate from either step")
	remove_child(p)
	p.free()
	# The fastest real turn (flight's cap) still narrows the view.
	v.reset_motion()
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(240.0))
	near(rad_to_deg(v.yaw_rate), 240.0, 1.0, "a 240°/s turn is measured")
	gt(v.strength(), 0.5, "and closes the vignette (%.2f at setting 0.6)" % v.strength())
	body.queue_free()


func test_aperture_is_angular_and_one_draw_call() -> void:
	near(ComfortVignette.clear_radius_deg(0.0), 55.0, 1e-6, "barely there at low strength: clear to 55°")
	near(ComfortVignette.clear_radius_deg(1.0), 24.0, 1e-6, "full strength: clear 24° cone")
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	var cam: XRCamera3D = rig["camera"]
	eq(v.mesh.get_surface_count(), 1, "one surface")
	check(v.material_override is ShaderMaterial, "one material")
	eq(v.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadow pass")
	for ws in [0.15, 1.3]:
		cam.near = WorldScaleDriver.near_for(ws)
		v.apply_strength(0.5)
		var m := v.material_override as ShaderMaterial
		near(float(m.get_shader_parameter("depth")), 2.0 * cam.near, 1e-7, "ring sits beyond the near plane at ws %.2f" % ws)
		near(float(m.get_shader_parameter("closed_inner")), deg_to_rad(ComfortVignette.CLOSED_DEG), 1e-6, "aperture in degrees, independent of ws")
	check((v.material_override as ShaderMaterial).shader.code.contains("skip_vertex_transform"), "drawn in view space (per-eye centred)")
	check((v.material_override as ShaderMaterial).shader.code.contains("depth_test_disabled"), "never hidden by near geometry")
	v.apply_strength(0.0)
	check(not v.visible, "strength 0: hidden")
	(rig["body"] as Node).queue_free()


## The rig of a small bird flapping straight and level in open sky: surge
## along the path and heave, both at the stroke frequency with a second
## harmonic (the downstroke is quicker than the upstroke). Amplitudes as
## flight's real PlayerBird at sparrow scale (a verifier's probe measured
## 28-41 m/s² perceived peaks at world_scale 0.141, heave smoothing on):
## 0.45 m/s of surge and 0.55 m/s of heave (4.3 m/s² real at 1.25 Hz).
## Returns {peak (the strength in this open sky), peak_near and
## frac_over_0.05 (the target with a surface within 3 body spans, where
## the acceleration term counts in full), accel_peak_perceived}.
func flap_flight(v: ComfortVignette, rig: Dictionary, period: float, seconds: float, surge_accel: float = 0.0) -> Dictionary:
	var body := rig["body"] as Node3D
	var w := TAU / period
	var t := 0.0
	var peak := 0.0
	var over := 0
	var n := 0
	var a_peak := 0.0
	var near_peak := 0.0
	var accel_term_peak := 0.0
	var speed_only_peak := 0.0
	var base := 8.0
	for i in int(seconds / DT):
		t += DT
		base += surge_accel * DT
		var ph := w * t
		var vel := Vector3(0.0, 0.55 * sin(ph) + 0.2 * sin(2.0 * ph + 0.7), -(base + 0.45 * sin(ph + 1.1) + 0.15 * sin(2.0 * ph)))
		body.position += vel * DT
		v.measure(DT)
		var s := v.update_strength(DT)
		var s_near := VignetteModel.target_for(v.setting(), v.yaw_rate, v.accel, XRServer.world_scale, 1.0)
		if t > 2.0:
			peak = maxf(peak, s)
			near_peak = maxf(near_peak, s_near)
			over += 1 if s_near > 0.05 else 0
			n += 1
			a_peak = maxf(a_peak, v.accel / XRServer.world_scale)
			accel_term_peak = maxf(accel_term_peak, v.model.accel_term)
			speed_only_peak = maxf(speed_only_peak, VignetteModel.target_for(v.setting(), 0.0, 0.0, XRServer.world_scale, 0.0, v.speed_ratio))
	return {"peak": peak, "peak_near": near_peak, "frac_over_0.05": float(over) / maxi(n, 1), "accel_peak_perceived": a_peak,
		"accel_term_peak": accel_term_peak, "speed_only_peak": speed_only_peak}


## Fix round 2 (verifier): with a 0.1 s low-pass on the acceleration, a
## sparrow's ordinary flapping climb held the view at 0.22-0.29 and hovering
## pulsed it on every beat. The acceleration is now the mean over one
## stroke, so the beat cancels; a sustained surge still counts in full.
func test_wingbeat_does_not_breathe() -> void:
	XRServer.world_scale = 0.141
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 0.6
	(rig["body"] as Node3D).position = Vector3(0, 5000, 0)
	var p: Bird = StubPlayer.new()
	var ws := FakeWingState.new()
	p.set(&"wing_state_obj", ws)
	add_child(p)
	var rows := {}
	for period in [1.0, 0.8, 0.625]:
		ws.stroke_period = period
		v.reset_motion()
		var r := flap_flight(v, rig, period, 8.0)
		rows["stroke %.3f s" % period] = r
		near(v.accel_window, period, 1e-6, "the window is flight's stroke period (%.3f s)" % period)
		lt(float(r["peak_near"]), 0.005, "flapping at %.2f Hz, even with a surface near: the beat cancels (peak %.3f)" % [1.0 / period, r["peak_near"]])
		eq(float(r["frac_over_0.05"]), 0.0, "and never visibly narrows (%.2f Hz)" % (1.0 / period))
		eq(float(r["peak"]), 0.0, "in open sky nothing at all (%.2f Hz)" % (1.0 / period))
	# No PlayerBird stroke period (no flight in the scene): a fixed 0.8 s
	# window. It cannot cancel every beat, but keeps a typical 1 Hz stroke
	# open and a quick 1.6 Hz one at a barely visible edge (the game always
	# has flight's stroke period).
	remove_child(p)
	p.free()
	for period in [1.0, 0.625]:
		v.reset_motion()
		var r := flap_flight(v, rig, period, 8.0)
		rows["no stroke period, stroke %.3f s" % period] = r
		near(v.accel_window, ComfortVignette.ACCEL_WINDOW, 1e-6, "fallback window")
		lt(float(r["peak_near"]), 0.10, "fallback window at %.2f Hz: peak %.3f <= 0.10" % [1.0 / period, r["peak_near"]])
		if period == 1.0:
			lt(float(r["frac_over_0.05"]), 0.10, "fallback window at 1 Hz: narrowed < 10%% of the time")
	# A sustained surge while flapping (a sparrow driving hard from 8 m/s:
	# 2.5 m/s² for 3 s = 18 perceived) still narrows the view.
	var p2: Bird = StubPlayer.new()
	var ws2 := FakeWingState.new()
	p2.set(&"wing_state_obj", ws2)
	add_child(p2)
	v.reset_motion()
	var surge := flap_flight(v, rig, 1.0, 3.0, 2.5)
	rows["sustained surge"] = surge
	gt(float(surge["peak_near"]), 0.2, "a sustained surge near a surface narrows the view (peak %.3f)" % surge["peak_near"])
	# In open sky the acceleration counts for nothing; what narrows the
	# view there is the speed the surge reaches (8 -> 15.5 m/s, 1.7 x a
	# sparrow's cruise: DESIGN's speed vignette, fix round 5).
	eq(float(surge["accel_term_peak"]), 0.0, "the same surge in open sky: the acceleration term is 0")
	lt(float(surge["peak"]), float(surge["speed_only_peak"]) + 1e-4, "and the view narrows by its speed alone (peak %.3f, speed term %.3f)" % [surge["peak"], surge["speed_only_peak"]])
	near(float(surge["accel_peak_perceived"]), 2.5 / 0.141, 1.5, "measured as its mean acceleration (%.1f perceived)" % surge["accel_peak_perceived"])
	# The second box (SMOOTH_WINDOW) is what catches the beat while flight's
	# stroke period is still converging (after a pause it starts from its
	# idle 0.3 s): a 1.25 Hz beat with the period reported 30 % short
	# leaves a residue the second box must cut at least 2x (to under a visible
	# edge: without it a surface nearby would show 0.28).
	ws2.stroke_period = 0.8 * 0.7
	var res := {}
	for sw in [ComfortVignette.SMOOTH_WINDOW, DT]:
		v.smooth_window = sw
		v.reset_motion()
		var r := flap_flight(v, rig, 0.8, 6.0)
		res["second box %.3f s" % sw] = r
	v.smooth_window = ComfortVignette.SMOOTH_WINDOW
	var with_box := float(res["second box %.3f s" % ComfortVignette.SMOOTH_WINDOW]["accel_peak_perceived"])
	var without := float(res["second box %.3f s" % DT]["accel_peak_perceived"])
	gt(without / maxf(with_box, 1e-6), 2.0, "the second box cuts a mistimed beat's residue %.1fx (%.1f -> %.1f perceived)" % [without / maxf(with_box, 1e-6), without, with_box])
	lt(float(res["second box %.3f s" % ComfortVignette.SMOOTH_WINDOW]["peak_near"]), 0.05, "a mistimed beat stays under a visible edge even near a surface")
	rows["mistimed period"] = res
	metric("wingbeat", rows)
	remove_child(p2)
	p2.free()
	XRServer.world_scale = 1.0
	(rig["body"] as Node).queue_free()


## The player's "comfort_vignette" setting (not an override) scales it, and
## 0 turns it off: read through the settings source production uses.
func test_setting_is_read_from_settings() -> void:
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	var store := MemoryStore.new()
	v.store = store
	v.setting_override = -1.0
	store.set_value("comfort_vignette", 0.0)
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(200.0))
	eq(v.strength(), 0.0, "Settings comfort_vignette 0: strength 0 in a 200°/s turn")
	check(not v.visible, "and hidden")
	store.set_value("comfort_vignette", 0.35)
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(200.0))
	near(v.strength(), 0.35, 0.01, "Settings comfort_vignette 0.35: a full turn gives 0.35")
	store.set_value("comfort_vignette", 1.0)
	for i in int(1.0 / DT):
		step(rig, Vector3.ZERO, deg_to_rad(200.0))
	near(v.strength(), 1.0, 0.01, "Settings comfort_vignette 1: fully closed")
	(rig["body"] as Node).queue_free()
