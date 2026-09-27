extends TestCase
## The comfort vignette over the REAL world geometry (scenes/world/world.tscn,
## as the game and the simulator harness load it): a sparrow (world_scale
## 0.141, 72 Hz ticks, default setting 0.6) flying straight and level at
## cruise (9 m/s) through the orchard, the forest and along the power line,
## found through the World contract (get_landmarks(): kinds "orchard",
## "forest", "powerline"), on lines through each at six headings.
##
##   tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=real_world
##
## Not in the unit suite: it depends on the world area's current build (the
## unit suite's vignette_test flies the same checks over its own orchard,
## forest and fence geometry). Report: artifacts/tests/report_real_world.json.
##
## Fix round 4 (the lead's criterion for the verifier's major "the vignette
## pulses in steady flight over broken surfaces"): in steady straight
## flight the strength's std < 0.02 and no periodic component (largest
## sinusoid between 0.3 and 6 Hz below 0.005); a hard turn over the same
## places still closes it. Fix round 5 (the speed term, DESIGN's "speed"):
## a sparrow player is in the scene, so the speed term is live: steady
## cruise still reads exactly 0 everywhere, and a steady fast glide at
## 1.8 x cruise (16.2 m/s) reads one constant value along every line, the
## open-sky value (std < 0.02, periodic < 0.005, mean within 0.01 of it).
## Also bounded: a sustained 2 m/s² surge along the same lines, where the
## strength follows the slow proximity (the real distance to the canopy
## changes along a line: one slow transition per gap or edge, never a
## pulse; see the assertions) and the speed it reaches.

const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const Q := 1.0 / 72.0
const SETTING := 0.6
const HEADINGS := [0.0, 30.0, 60.0, 90.0, 120.0, 150.0]

var _world: Node = null


func before_all() -> void:
	XRServer.world_scale = 1.0
	if not ResourceLoader.exists("res://scenes/world/world.tscn"):
		return
	_world = (load("res://scenes/world/world.tscn") as PackedScene).instantiate()
	add_child(_world)
	var w := _world as World
	if w != null and not w.is_generated:
		await w.generated
	await wait_physics(3)


func after_all() -> void:
	if _world != null:
		_world.queue_free()
	XRServer.world_scale = 1.0
	await wait_frames(2)


func make_rig(ws: float) -> Dictionary:
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	origin.world_scale = ws
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, 1.6 * ws, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	v.setting_override = SETTING
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	add_child(body)
	v.origin = origin
	return {"body": body, "camera": cam, "vignette": v}


## Highest collider top (layers 1|2) under the straight path a -> b, within
## 60 m above the ground (the arena's ceiling is a collider too).
func path_top(w: World, a: Vector3, b: Vector3) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = 1 | 2
	var top := -INF
	var n := int(a.distance_to(b) / 0.25)
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		q.from = Vector3(p.x, w.ground_height(p.x, p.z) + 60.0, p.z)
		q.to = Vector3(p.x, -200.0, p.z)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			top = maxf(top, (hit["position"] as Vector3).y)
	return top


func ground_top(w: World, a: Vector3, b: Vector3) -> float:
	var g := -INF
	for i in 161:
		var p := a.lerp(b, i / 160.0)
		g = maxf(g, w.ground_height(p.x, p.z))
	return g


## Straight flight a -> b at `eye_y`, `speed` (+ `accel` along the path);
## {s: strength, p: proximity} per tick after `settle` seconds.
func fly(rig: Dictionary, a: Vector3, b: Vector3, eye_y: float, speed: float, accel: float, settle: float = 1.0) -> Dictionary:
	var body := rig["body"] as Node3D
	var cam := rig["camera"] as Node3D
	var v := rig["vignette"] as ComfortVignette
	var dir := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
	body.basis = Basis.looking_at(dir, Vector3.UP)
	body.position = Vector3(a.x, eye_y - cam.position.y, a.z)
	v.reset_motion()
	var out := PackedFloat32Array()
	var prox := PackedFloat32Array()
	var spd := speed
	var dist := Vector2(b.x - a.x, b.z - a.z).length()
	var gone := 0.0
	var i := 0
	while gone < dist:
		spd += accel * Q
		body.position += dir * spd * Q
		gone += spd * Q
		v.measure(Q)
		v.update_strength(Q)
		if i * Q >= settle:
			out.append(v.strength())
			prox.append(v.proximity)
		i += 1
	return {"s": out, "p": prox}


## Direction changes of `x` by at least `hyst` from the last extremum.
static func reversals(x: PackedFloat32Array, hyst: float) -> int:
	if x.size() < 2:
		return 0
	var n := 0
	var dir := 0
	var ext := x[0]
	for v in x:
		if dir >= 0:
			if v > ext:
				ext = v
			elif ext - v >= hyst:
				if dir > 0:
					n += 1
				dir = -1
				ext = v
		if dir < 0:
			if v < ext:
				ext = v
			elif v - ext >= hyst:
				n += 1
				dir = 1
				ext = v
	return n


static func mean_std(x: PackedFloat32Array) -> Vector2:
	var m := 0.0
	for a in x:
		m += a
	m /= maxf(1.0, x.size())
	var q := 0.0
	for a in x:
		q += (a - m) * (a - m)
	return Vector2(m, sqrt(q / maxf(1.0, x.size())))


## Largest sinusoid (half peak-to-peak) between f_lo and f_hi Hz after
## removing a linear trend: {amp, hz}.
static func periodic(x: PackedFloat32Array, dt: float, f_lo: float, f_hi: float) -> Dictionary:
	var n := x.size()
	if n < 8:
		return {"amp": 0.0, "hz": 0.0}
	var st := 0.0
	var sx := 0.0
	var stt := 0.0
	var stx := 0.0
	for i in n:
		var t := i * dt
		st += t
		sx += x[i]
		stt += t * t
		stx += t * x[i]
	var slope := (n * stx - st * sx) / maxf(n * stt - st * st, 1e-12)
	var icpt := (sx - slope * st) / n
	var best := {"amp": 0.0, "hz": 0.0}
	var f := f_lo
	while f <= f_hi + 1e-9:
		var re := 0.0
		var im := 0.0
		for i in n:
			var y := x[i] - (icpt + slope * i * dt)
			var ph := TAU * f * i * dt
			re += y * cos(ph)
			im += y * sin(ph)
		var amp := 2.0 * sqrt(re * re + im * im) / n
		if amp > float(best["amp"]):
			best = {"amp": amp, "hz": f}
		f += 0.05
	return best


func test_steady_flight_over_the_real_world() -> void:
	var w := _world as World
	if w == null:
		print("[vr] no world scene: skipped")
		check(true, "skipped: no world")
		return
	var places := {}
	for lm in w.get_landmarks():
		var k := String(lm.get("kind", ""))
		var nm := String(lm.get("name", ""))
		if (k == "orchard" or k == "powerline" or (k == "forest" and nm == "forest")) and not places.has(k):
			places[k] = lm
	for k in ["orchard", "forest", "powerline"]:
		check(places.has(k), "the world has a %s landmark" % k)
	var ws := WorldScaleDriver.target_scale(0.03, 1.5)
	var rig := make_rig(ws)
	# The player: a sparrow (cruise 9 m/s), so the speed term is live.
	var player: Bird = StubPlayer.new()
	player.mass = 0.03
	add_child(player)
	check(Birds.player() == player, "(setup) a sparrow player")
	var rows := {}
	var worst_std := 0.0
	var worst_amp := 0.0
	var worst_fast_std := 0.0
	var worst_fast_amp := 0.0
	var fast := 1.8 * SizeRules.cruise_speed(0.03)
	var open_fast := 0.6 * VignetteModel.SPEED_WEIGHT * VRMath.sstep(VignetteModel.SPEED_LO, VignetteModel.SPEED_HI, 1.8)
	for k: String in places:
		var lm: Dictionary = places[k]
		var c: Vector3 = lm["position"]
		var half := minf(float(lm["radius"]), 80.0)
		for hdg in HEADINGS:
			var d := Vector3(cos(deg_to_rad(hdg)), 0.0, sin(deg_to_rad(hdg)))
			var a := c - d * half
			var b := c + d * half
			# Heights: just over the tallest thing under the path (canopy,
			# pole tops), and low among the trunks / under the wires.
			var top := path_top(w, a, b)
			var g := ground_top(w, a, b)
			var heights := {"1m_over_top": top + 1.0, "2.5m_over_ground": g + 2.5}
			for hk: String in heights:
				var eye: float = heights[hk]
				var tag := "%s_%03d_%s" % [k, int(hdg), hk]
				var s: PackedFloat32Array = fly(rig, a, b, eye, 9.0, 0.0)["s"]
				var ms := mean_std(s)
				var per := periodic(s, Q, 0.3, 6.0)
				var peak := 0.0
				for x in s:
					peak = maxf(peak, x)
				# Steady and fast (1.8 x cruise): one constant value, the
				# open-sky one (the two low-passes settle within 3 s).
				var sfast: PackedFloat32Array = fly(rig, a, b, eye, fast, 0.0, 3.0)["s"]
				var msf := mean_std(sfast)
				var perf := periodic(sfast, Q, 0.3, 6.0)
				worst_fast_std = maxf(worst_fast_std, msf.y)
				worst_fast_amp = maxf(worst_fast_amp, float(perf["amp"]))
				lt(msf.y, 0.02, "%s: steady fast glide (1.8 x cruise), strength std %.4f" % [tag, msf.y])
				lt(float(perf["amp"]), 0.005, "%s: steady fast glide, no periodic component (%.4f at %.2f Hz)" % [tag, perf["amp"], perf["hz"]])
				near(msf.x, open_fast, 0.01, "%s: steady fast glide reads the open-sky value (%.3f vs %.3f)" % [tag, msf.x, open_fast])
				eq(peak, 0.0, "%s: steady cruise with the speed term live: the full view" % tag)
				# The surge from 3.5 s on: the acceleration windows (1.3 s) and
				# the proximity (2 x PROX_TAU) have settled on the line.
				var sf := fly(rig, a, b, eye, 9.0, 2.0, 3.5)
				var surge: PackedFloat32Array = sf["s"]
				var ms2 := mean_std(surge)
				var per2 := periodic(surge, Q, 0.3, 6.0)
				var rev := reversals(surge, 0.01)
				var secs := surge.size() * Q
				var lo := INF
				var hi := -INF
				var rate := 0.0
				for j in surge.size():
					lo = minf(lo, surge[j])
					hi = maxf(hi, surge[j])
					if j > 0:
						rate = maxf(rate, absf(surge[j] - surge[j - 1]) / Q)
				rows[tag] = {"steady": {"mean": snappedf(ms.x, 0.0001), "std": snappedf(ms.y, 0.0001), "peak": snappedf(peak, 0.0001),
					"periodic_amp": snappedf(float(per["amp"]), 0.0001), "periodic_hz": per["hz"]},
					"fast": {"mean": snappedf(msf.x, 0.0001), "std": snappedf(msf.y, 0.0001), "periodic_amp": snappedf(float(perf["amp"]), 0.0001)},
					"surge": {"mean": snappedf(ms2.x, 0.0001), "std": snappedf(ms2.y, 0.0001), "p2p": snappedf(hi - lo, 0.0001),
					"max_rate_per_s": snappedf(rate, 0.001), "largest_0.3_6hz": [snappedf(float(per2["amp"]), 0.0001), per2["hz"]],
					"reversals": rev, "seconds": snappedf(secs, 0.01)}}
				if tag == "orchard_150_1m_over_top" or tag == "forest_090_2.5m_over_ground":
					var tr := []
					for j in range(0, surge.size(), 3):
						tr.append([snappedf(surge[j], 0.001), snappedf((sf["p"] as PackedFloat32Array)[j], 0.001)])
					metric("trace_surge_" + tag, tr)
				worst_std = maxf(worst_std, ms.y)
				worst_amp = maxf(worst_amp, float(per["amp"]))
				lt(ms.y, 0.02, "%s: steady flight, strength std %.4f" % [tag, ms.y])
				lt(float(per["amp"]), 0.005, "%s: steady flight, no periodic component (%.4f at %.2f Hz)" % [tag, per["amp"], per["hz"]])
				# With a sustained acceleration the strength follows the
				# real distance to the canopy / trunks / wires (a line 1 m
				# over the TALLEST crown is 2-5 m over most of the rest),
				# through the slow proximity: a gap or an edge is one slow
				# transition, never a pulse. Bars: it swings back at most
				# once per 2 s (reversals of >= 0.01; round 3's steady
				# flight pulsed 0.3-0.9 times a second, two reversals each)
				# and never moves faster than the proximity allows
				# (setting x 0.5 / PROX_TAU = 0.3 per s).
				lt(float(rev), secs / 2.0 + 1.0, "%s: surge, %d reversals in %.1f s" % [tag, rev, secs])
				lt(rate, SETTING * 0.5 / ComfortVignette.PROX_TAU + 0.02, "%s: surge, strength moves at most %.2f/s (%.3f)" % [tag, SETTING * 0.5 / ComfortVignette.PROX_TAU, rate])
		# A hard turn over the same place still closes the view.
		var body := rig["body"] as Node3D
		var v := rig["vignette"] as ComfortVignette
		body.position = Vector3(c.x, path_top(w, c - Vector3(5, 0, 0), c + Vector3(5, 0, 0)) + 1.0 - (rig["camera"] as Node3D).position.y, c.z)
		v.reset_motion()
		for i in int(1.0 / Q):
			body.rotate_y(deg_to_rad(150.0) * Q)
			body.position += -body.global_basis.z * 9.0 * Q
			v.measure(Q)
			v.update_strength(Q)
		gt(v.strength(), 0.55, "%s: a 150°/s turn closes the view (%.3f at setting 0.6)" % [k, v.strength()])
		rows["%s_hard_turn" % k] = snappedf(v.strength(), 0.001)
	metric("worst_steady_std", worst_std)
	metric("worst_steady_periodic_amp", worst_amp)
	metric("worst_fast_std", worst_fast_std)
	metric("worst_fast_periodic_amp", worst_fast_amp)
	metric("lines", rows)
	var n_lines := 0
	for k in rows:
		n_lines += 1 if rows[k] is Dictionary else 0
	metric("lines_flown", n_lines)
	print("[vr] real-world vignette: worst steady std %.4f, worst periodic %.4f over %d lines; fast glide worst std %.4f, periodic %.4f" % [worst_std, worst_amp, n_lines,
		worst_fast_std, worst_fast_amp])
	(rig["body"] as Node).queue_free()
	remove_child(player)
	player.free()
