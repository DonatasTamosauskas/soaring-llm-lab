extends TestCase
## V4, fix round 4 (a verifier's probes, major; the lead's criterion): the
## comfort vignette responds to SELF-motion only, and the one geometry
## input left (how near a surface is to see an acceleration by) is slow, so
## steady straight flight past broken surfaces (orchard crowns with gaps, a
## forest of trunks, a fence line, sparse crowns) never pulses it: std <
## 0.02 and no periodic component; with a sustained acceleration too; a
## hard turn still closes it. The same checks on the real world geometry:
## tests/sim/real_world (on demand).
##
## Written against ComfortVignette's round-3 API only (the proximity's time
## constants are read from the script, with round 4's values as defaults),
## so the same file shows how round 3 failed it (artifacts/vr/old_code_check_round4.log).

const DT := 1.0 / 90.0
var PROX_TAU := 1.0
var PROX_HOLD := 1.5


func before_all() -> void:
	XRServer.world_scale = 1.0
	var c := (load("res://scripts/vr/comfort_vignette.gd") as Script).get_script_constant_map()
	PROX_TAU = float(c.get("PROX_TAU", PROX_TAU))
	PROX_HOLD = float(c.get("PROX_HOLD", PROX_HOLD))


func after_all() -> void:
	XRServer.world_scale = 1.0


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


## A box collider (layer 1: world) under `parent`.
func box(parent: Node, size: Vector3, pos: Vector3) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	sb.add_child(cs)
	sb.position = pos
	parent.add_child(sb)


## Broken surfaces the world is full of, around a straight flight line
## along -Z from z = 0 (eyes at y = 0): {name: [builder, what]}.
## orchard: crowns `c` m long with `g` m gaps, tops 1 m below the eyes;
## forest: trunks 0.3 m thick 0.7-1.6 m to either side every 2-7 m
## (seeded), the ground out of reach; posts: a fence line, 0.15 m posts
## every 2.5 m, 1 m to the right, nothing else; sparse: a crown every 12 m.
func broken_surfaces(kind: String) -> Node3D:
	var w := Node3D.new()
	add_child(w)
	match kind:
		"continuous":
			box(w, Vector3(40.0, 2.0, 600.0), Vector3(0.0, -2.0, -290.0))
		"orchard_4_4", "orchard_3_5", "orchard_6_3", "orchard_2_2":
			var p := kind.split("_")
			var c := float(p[1])
			var g := float(p[2])
			var z := -1.0
			while z > -600.0:
				box(w, Vector3(c, 2.0, c), Vector3(0.0, -2.0, z - 0.5 * c))
				z -= c + g
		"sparse":
			var z := -1.0
			while z > -600.0:
				box(w, Vector3(4.0, 2.0, 4.0), Vector3(0.0, -2.0, z - 2.0))
				z -= 12.0
		"forest":
			var rng := RandomNumberGenerator.new()
			rng.seed = 77
			for side in [-1.0, 1.0]:
				var z := -1.0
				while z > -600.0:
					box(w, Vector3(0.3, 12.0, 0.3), Vector3(side * rng.randf_range(0.7, 1.6), 0.0, z))
					z -= rng.randf_range(2.0, 7.0)
		"posts":
			var z := -1.0
			while z > -600.0:
				box(w, Vector3(0.15, 6.0, 0.15), Vector3(1.0, 0.0, z))
				z -= 2.5
	return w


## Flies the rig straight along -Z at `speed` (+ `accel` m/s² along the
## path) at the Quest's 72 Hz, from z = 0 with the eyes at y = 0; returns
## {s: strength per tick after `settle` s, p: proximity per tick}.
func fly_line(rig: Dictionary, speed: float, accel: float, seconds: float, settle: float) -> Dictionary:
	const Q := 1.0 / 72.0
	var body := rig["body"] as Node3D
	var v := rig["vignette"] as ComfortVignette
	var cam := rig["camera"] as Node3D
	body.rotation = Vector3.ZERO
	body.position = Vector3(0.0, -cam.position.y, 0.0)
	v.reset_motion()
	var out := PackedFloat32Array()
	var prox := PackedFloat32Array()
	var spd := speed
	for i in int(round(seconds / Q)):
		spd += accel * Q
		body.position += Vector3(0.0, 0.0, -spd) * Q
		v.measure(Q)
		v.update_strength(Q)
		if i * Q >= settle:
			out.append(v.strength())
			prox.append(v.proximity)
	return {"s": out, "p": prox}


static func mean_std(x: PackedFloat32Array) -> Vector2:
	var m := 0.0
	for a in x:
		m += a
	m /= maxf(1.0, x.size())
	var q := 0.0
	for a in x:
		q += (a - m) * (a - m)
	return Vector2(m, sqrt(q / maxf(1.0, x.size())))


## The largest sinusoid in `x` (sampled every dt) between f_lo and f_hi Hz:
## {amp (half peak-to-peak of that component), hz}. A direct DFT, 0.05 Hz
## apart, after removing the mean and a linear trend (a steady ramp is not
## a pulse).
static func periodic(x: PackedFloat32Array, dt: float, f_lo: float, f_hi: float) -> Dictionary:
	var n := x.size()
	var y := PackedFloat64Array()
	y.resize(n)
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
	for i in n:
		y[i] = x[i] - (icpt + slope * i * dt)
	var best := {"amp": 0.0, "hz": 0.0}
	var f := f_lo
	while f <= f_hi + 1e-9:
		var re := 0.0
		var im := 0.0
		for i in n:
			var ph := TAU * f * i * dt
			re += y[i] * cos(ph)
			im += y[i] * sin(ph)
		var amp := 2.0 * sqrt(re * re + im * im) / n
		if amp > float(best["amp"]):
			best = {"amp": amp, "hz": f}
		f += 0.05
	return best


## Fix round 4 (a verifier's probes, major): round 3's optic-flow term and
## per-tick proximity pulsed the ring 0 <-> 0.4 about once a second in
## steady flight over orchard crowns and through the forest, and flashed it
## on each fence post. Now: steady straight flight past any of them keeps
## the full view; with a sustained acceleration (the one self-motion near
## these surfaces that narrows it) the strength is steady (std < 0.02, no
## periodic component above 0.005 between 0.3 and 6 Hz) and the same as
## over a continuous surface; a hard turn still closes it.
func test_steady_flight_past_broken_surfaces_never_pulses() -> void:
	XRServer.world_scale = 0.141
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 0.6
	var rows := {}
	var ref_mean := -1.0
	for kind in ["continuous", "orchard_4_4", "orchard_3_5", "orchard_6_3", "orchard_2_2", "sparse", "forest", "posts"]:
		var w := broken_surfaces(kind)
		await wait_physics(2)
		var row := {}
		for spd in [9.0, 8.3]:
			# Steady: constant speed and heading.
			var steady: Dictionary = fly_line(rig, spd, 0.0, 6.0, 1.0)
			var ms := mean_std(steady["s"])
			var peak := 0.0
			for x in steady["s"]:
				peak = maxf(peak, x)
			eq(peak, 0.0, "%s at %.1f m/s, steady: the full view throughout (peak %.3f)" % [kind, spd, peak])
			row["steady_%.1f_peak" % spd] = snappedf(peak, 0.0001)
		# A sustained surge of 2 m/s² (14 perceived at world_scale 0.141):
		# near a surface this narrows the view; it must not pulse.
		var surge: Dictionary = fly_line(rig, 9.0, 2.0, 6.0, 2.5)
		var ms2 := mean_std(surge["s"])
		var per := periodic(surge["s"], 1.0 / 72.0, 0.3, 6.0)
		var prate := 0.0
		var pp: PackedFloat32Array = surge["p"]
		for i in range(1, pp.size()):
			prate = maxf(prate, absf(pp[i] - pp[i - 1]) * 72.0)
		row["surge"] = {"mean": snappedf(ms2.x, 0.0001), "std": snappedf(ms2.y, 0.0001), "periodic_amp": snappedf(float(per["amp"]), 0.0001),
			"periodic_hz": per["hz"], "proximity_rate_max_per_s": snappedf(prate, 0.001)}
		lt(ms2.y, 0.02, "%s, sustained surge: strength steady (std %.4f)" % [kind, ms2.y])
		lt(float(per["amp"]), 0.005, "%s, sustained surge: no periodic component (%.4f at %.2f Hz)" % [kind, per["amp"], per["hz"]])
		lt(prate, 1.0 / PROX_TAU + 1e-3, "%s: the proximity moves by at most 1/PROX_TAU per second (%.3f)" % [kind, prate])
		if kind == "continuous":
			ref_mean = ms2.x
			gt(ms2.x, 0.1, "(reference) a surge over a continuous canopy narrows the view (%.3f)" % ms2.x)
		elif kind.begins_with("orchard") or kind == "sparse":
			near(ms2.x, ref_mean, 0.02, "%s reads like the continuous canopy (%.3f vs %.3f): a row of trees is one surface" % [kind, ms2.x, ref_mean])
		# A hard turn over the same surfaces still closes it.
		var body := rig["body"] as Node3D
		v.reset_motion()
		for i in int(1.0 / DT):
			body.rotate_y(deg_to_rad(150.0) * DT)
			body.position += -body.global_basis.z * 9.0 * DT
			v.measure(DT)
			v.update_strength(DT)
		gt(v.strength(), 0.55, "%s: a 150°/s turn closes the view (%.3f at setting 0.6)" % [kind, v.strength()])
		rows[kind] = row
		w.queue_free()
		await wait_physics(2)
	metric("broken_surfaces", rows)
	XRServer.world_scale = 1.0
	(rig["body"] as Node).queue_free()


## A single post or a lone tree passing is one slow bump of the proximity,
## never a flash; a teleport is not motion.
func test_proximity_is_slow_and_teleports_are_not_motion() -> void:
	XRServer.world_scale = 0.141
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	v.setting_override = 0.6
	var w := Node3D.new()
	add_child(w)
	box(w, Vector3(0.15, 6.0, 0.15), Vector3(0.6, 0.0, -20.0))
	await wait_physics(2)
	var body := rig["body"] as Node3D
	body.position = Vector3(0.0, -(rig["camera"] as Node3D).position.y, 0.0)
	v.reset_motion()
	var peak := 0.0
	var last := 0.0
	var worst_rate := 0.0
	for i in int(5.0 / DT):
		body.position += Vector3(0.0, 0.0, -9.0) * DT
		v.measure(DT)
		v.update_strength(DT)
		worst_rate = maxf(worst_rate, absf(v.proximity - last) / DT)
		last = v.proximity
		peak = maxf(peak, v.proximity)
	gt(peak, 0.3, "(the post was seen: proximity peak %.2f)" % peak)
	lt(peak, 1.0 - exp(-PROX_HOLD / PROX_TAU) + 0.02, "one post: at most what PROX_HOLD of it can build (%.2f)" % peak)
	lt(worst_rate, 1.0 / PROX_TAU + 1e-3, "and never faster than 1/PROX_TAU per second (%.3f)" % worst_rate)
	eq(v.strength(), 0.0, "steady flight past it: the full view")
	# A respawn jump is not motion.
	body.position += Vector3(500, 0, 0)
	v.measure(DT)
	lt(v.speed, 50.0, "a teleport is re-seeded, not measured as 45000 m/s")
	w.queue_free()
	XRServer.world_scale = 1.0
	(rig["body"] as Node).queue_free()


## Fix round 5 (the experience verifier: DESIGN asks for a comfort
## vignette "on fast turns/speed"; round 4 answered turns and accelerations
## only). The speed term is the rig's smoothed speed over the player's own
## cruise speed (SizeRules.cruise_speed of its mass):
## - steady cruise (and slower) keeps the full view, over every broken
##   surface too; a steady fast glide or dive reads one constant value
##   (std < 0.005 and no periodic component above 0.005, the steady-flight
##   bars' periodic one, even with a flap's surge ripple of +-5 % of the
##   speed at 1.25 Hz on it; without the ripple std < 0.002), the same over
##   the orchard, the forest and the fence as in open sky (no surface moves
##   it);
## - the curve: 1.3 x cruise -> 0, 1.8 x -> half, 2.3 x -> full (0.7 x the
##   setting), the same for a sparrow and an eagle (scale-free);
## - setting 0: nothing; no player (no cruise to compare with): no term.
func test_speed_term_is_steady_and_scale_free() -> void:
	const Q := 1.0 / 72.0
	var rows := {}
	for sp in [["sparrow", 0.03], ["eagle", 5.0]]:
		var bird: Bird = preload("res://scenes/dev/vr_stub_player.gd").new()
		bird.mass = sp[1]
		add_child(bird)
		check(Birds.player() == bird, "(setup) the %s stand-in is the player" % sp[0])
		var cruise := SizeRules.cruise_speed(sp[1])
		var ws := WorldScaleDriver.target_scale(sp[1], 1.5)
		XRServer.world_scale = ws
		var rig := make_rig()
		var v: ComfortVignette = rig["vignette"]
		v.setting_override = 0.6
		var body := rig["body"] as Node3D
		var row := {}
		for ratio in [0.6, 1.0, 1.25, 1.55, 1.8, 2.05, 2.3, 2.6]:
			body.position = Vector3(0.0, 500.0, 0.0)
			v.reset_motion()
			var s := PackedFloat32Array()
			for i in int(6.0 / Q):
				# A flap's surge on top: +-0.05 x cruise at 1.25 Hz.
				var spd: float = ratio * cruise * (1.0 + 0.05 * sin(TAU * 1.25 * i * Q))
				body.position += Vector3(0.0, 0.0, -spd) * Q
				v.measure(Q)
				v.update_strength(Q)
				if i * Q >= 2.5:
					s.append(v.strength())
			var ms := mean_std(s)
			var per := periodic(s, Q, 0.3, 6.0)
			var want := 0.6 * VignetteModel.SPEED_WEIGHT * VRMath.sstep(VignetteModel.SPEED_LO, VignetteModel.SPEED_HI, ratio)
			row["%.2f" % ratio] = [snappedf(ms.x, 0.0001), snappedf(ms.y, 0.0001), snappedf(float(per["amp"]), 0.0001)]
			near(ms.x, want, 0.01, "%s at %.2f x cruise: strength %.3f (curve %.3f)" % [sp[0], ratio, ms.x, want])
			lt(ms.y, 0.005, "%s at %.2f x cruise: steady (std %.4f)" % [sp[0], ratio, ms.y])
			lt(float(per["amp"]), 0.005, "%s at %.2f x cruise: no periodic component (%.4f at %.2f Hz)" % [sp[0], ratio, per["amp"], per["hz"]])
			if ratio <= 1.25:
				eq(v.strength(), 0.0, "%s at %.2f x cruise: the full view" % [sp[0], ratio])
		rows[sp[0]] = row
		# Setting 0: nothing, however fast.
		v.setting_override = 0.0
		v.reset_motion()
		for i in int(3.0 / Q):
			body.position += Vector3(0.0, 0.0, -2.6 * cruise) * Q
			v.measure(Q)
			v.update_strength(Q)
		eq(v.strength(), 0.0, "%s: setting 0, a 2.6 x cruise dive: nothing" % sp[0])
		(rig["body"] as Node).queue_free()
		remove_child(bird)
		bird.free()
		await wait_physics(1)
	# The same fast glide past every broken surface reads what it reads in
	# open sky (a sparrow at 1.8 x cruise, world_scale 0.141).
	XRServer.world_scale = 0.141
	var bird2: Bird = preload("res://scenes/dev/vr_stub_player.gd").new()
	bird2.mass = 0.03
	add_child(bird2)
	var rig2 := make_rig()
	var v2: ComfortVignette = rig2["vignette"]
	v2.setting_override = 0.6
	var fast := 1.8 * SizeRules.cruise_speed(0.03)
	var open_mean := -1.0
	for kind in ["open", "continuous", "orchard_4_4", "orchard_2_2", "sparse", "forest", "posts"]:
		var w: Node3D = null if kind == "open" else broken_surfaces(kind)
		await wait_physics(2)
		var line: Dictionary = fly_line(rig2, fast, 0.0, 6.0, 2.5)
		var ms := mean_std(line["s"])
		var per := periodic(line["s"], 1.0 / 72.0, 0.3, 6.0)
		rows["fast_%s" % kind] = [snappedf(ms.x, 0.0001), snappedf(ms.y, 0.0001), snappedf(float(per["amp"]), 0.0001)]
		lt(ms.y, 0.002, "%s at 1.8 x cruise: steady (std %.4f)" % [kind, ms.y])
		lt(float(per["amp"]), 0.005, "%s at 1.8 x cruise: no periodic component (%.4f at %.2f Hz)" % [kind, per["amp"], per["hz"]])
		if kind == "open":
			open_mean = ms.x
			gt(open_mean, 0.15, "(reference) a fast glide in open sky narrows the view (%.3f)" % open_mean)
		else:
			near(ms.x, open_mean, 0.005, "%s at 1.8 x cruise reads as in open sky (%.3f vs %.3f): no surface moves the speed term" % [kind, ms.x, open_mean])
		if w != null:
			w.queue_free()
		await wait_physics(2)
	metric("speed_term", rows)
	(rig2["body"] as Node).queue_free()
	remove_child(bird2)
	bird2.free()
	XRServer.world_scale = 1.0
