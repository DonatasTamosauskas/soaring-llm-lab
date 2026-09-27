extends TestCase
## VERIFIER PROBE (vr, round 4, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r4x_vignette_flicker
##
## Question: in STEADY flight (constant speed, height and heading) over the
## broken surfaces this world is full of (an orchard / forest canopy with
## gaps, a row of rooftops, a fence line or poles abeam), does the comfort
## vignette hold still, or does it pulse with every tree or post that passes
## under / beside the bird?
##
## Why it matters: round 2's major finding was a vignette that "breathed"
## with every wingbeat; the fix made the acceleration term stroke-averaged.
## The optic-flow term and the round-3 proximity factor are fed by three
## single rays (left, right, down) whose last hit is forgotten the moment a
## ray misses, with a 0.08 s attack. A peripheral ring that swings open and
## closed about once a second is itself a flicker stimulus in the
## periphery, where the eye is most sensitive to it.
##
## Measured on the real ComfortVignette (default setting 0.6) moved like
## flight moves the rig, at the Quest's 72 Hz tick. Assertions: once
## settled, in steady flight the strength swings by less than 0.10
## peak-to-trough (0.10 is the builder's own "narrowed" line and a faint
## but visible corner darkening in r2x_vignette_levels_sheet.png), and
## passing thin posts abeam never flashes it above 0.10.

const DT := 1.0 / 72.0
const SETTING := 0.6


func before_all() -> void:
	XRServer.world_scale = 1.0


func make_rig(ws: float) -> Dictionary:
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	origin.world_scale = ws
	var cam := XRCamera3D.new()
	# What the runtime writes: tracking-space eye height x world_scale.
	cam.position = Vector3(0, 1.6 * ws, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	v.setting_override = SETTING
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	add_child(body)
	v.origin = origin
	return {"body": body, "origin": origin, "camera": cam, "vignette": v}


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


## Flies the rig straight along -Z at `speed` with the camera at `eye_y`
## for `seconds`; returns the strength series after `settle` seconds.
func fly(rig: Dictionary, speed: float, eye_y: float, seconds: float, settle: float) -> PackedFloat32Array:
	var body := rig["body"] as Node3D
	var cam := rig["camera"] as Node3D
	var v := rig["vignette"] as ComfortVignette
	body.position = Vector3(0, eye_y - cam.position.y, 0)
	v.reset_motion()
	var out := PackedFloat32Array()
	for i in int(round(seconds / DT)):
		body.position += Vector3(0, 0, -speed) * DT
		v.measure(DT)
		v.update_strength(DT)
		if i * DT >= settle:
			out.append(v.strength())
	return out


static func stats_of(s: PackedFloat32Array) -> Dictionary:
	var lo := INF
	var hi := -INF
	var mean := 0.0
	var above := 0
	for x in s:
		lo = minf(lo, x)
		hi = maxf(hi, x)
		mean += x
		if x > 0.10:
			above += 1
	mean /= maxf(1.0, s.size())
	# Pulses per second: upward crossings of the mid level (only when the
	# swing itself is at least 0.05).
	var mid := 0.5 * (lo + hi)
	var ups := 0
	if hi - lo >= 0.05:
		for i in range(1, s.size()):
			if s[i - 1] < mid and s[i] >= mid:
				ups += 1
	return {"min": snappedf(lo, 0.001), "max": snappedf(hi, 0.001), "p2p": snappedf(hi - lo, 0.001),
		"mean": snappedf(mean, 0.001), "pulses_per_s": snappedf(ups / maxf(DT, s.size() * DT), 0.01),
		"frac_above_0_10": snappedf(float(above) / maxf(1.0, s.size()), 0.01)}


## Reference: over a CONTINUOUS canopy the vignette is steady (by design:
## that is real optic flow). Then the same flight over the same canopy
## with gaps (an orchard, a forest edge, a row of roofs).
func test_canopy_with_gaps_at_sparrow_scale() -> void:
	var ws := WorldScaleDriver.target_scale(0.03, 1.5) # sparrow on a 1.5 m arm span
	var rig := make_rig(ws)
	var world := Node3D.new()
	add_child(world)
	# Continuous canopy top at y = 0 from z = 0 to -400 (ground far below).
	box(world, Vector3(40, 2, 400), Vector3(0, -1, -200))
	await wait_physics(2)
	var cont := stats_of(fly(rig, 9.0, 1.0, 8.0, 3.0))
	metric("sparrow_continuous_canopy_1m", cont)
	print("[vr_verify] sparrow ws %.3f, 9 m/s, 1.0 m over a continuous canopy: %s" % [ws, str(cont)])
	lt(cont["p2p"], 0.02, "continuous canopy: steady (reference)")
	world.queue_free()
	await wait_physics(2)
	var results := {}
	for pattern: Array in [[4.0, 4.0], [3.0, 5.0], [6.0, 3.0], [2.0, 2.0]]:
		var crown: float = pattern[0]
		var gap: float = pattern[1]
		var w := Node3D.new()
		add_child(w)
		var z := 0.0
		while z > -420.0:
			box(w, Vector3(crown, 2.0, crown), Vector3(0, -1, z - crown * 0.5))
			z -= crown + gap
		await wait_physics(2)
		for eye_y in [1.0, 1.5]:
			var st := stats_of(fly(rig, 9.0, eye_y, 10.0, 3.0))
			var key := "crown_%.0f_gap_%.0f_at_%.1fm" % [crown, gap, eye_y]
			results[key] = st
			print("[vr_verify] sparrow 9 m/s %s: %s" % [key, str(st)])
			lt(st["p2p"], 0.10, "steady flight over %s: the vignette must not pulse (peak-to-trough %.3f, %.3f..%.3f)" % [key, st["p2p"], st["min"], st["max"]])
		w.queue_free()
		await wait_physics(2)
	metric("sparrow_broken_canopy", results)
	(rig["body"] as Node).queue_free()


## A fence line / row of poles 1 m abeam (posts 0.15 m thick every 2.5 m),
## nothing else within reach: thin objects whizzing past are not wide-field
## optic flow. Does the vignette flash as each post passes?
func test_posts_abeam_do_not_flash() -> void:
	var ws := WorldScaleDriver.target_scale(0.03, 1.5)
	var rig := make_rig(ws)
	var w := Node3D.new()
	add_child(w)
	var z := -1.0
	while z > -420.0:
		box(w, Vector3(0.15, 6.0, 0.15), Vector3(1.0, 0.0, z))
		z -= 2.5
	await wait_physics(2)
	var st := stats_of(fly(rig, 9.0, 0.0, 10.0, 1.0))
	metric("sparrow_posts_abeam", st)
	print("[vr_verify] sparrow 9 m/s, posts 0.15 m every 2.5 m, 1 m to the right: %s" % str(st))
	lt(st["max"], 0.10, "posts abeam: no flash above 0.10 (max %.3f, %.0f%% of the time above 0.10)" % [st["max"], 100.0 * float(st["frac_above_0_10"])])
	w.queue_free()
	(rig["body"] as Node).queue_free()


## Eagle scale: 16 m/s, 5 m over a canopy of 10 m crowns with 10 m gaps.
func test_canopy_with_gaps_at_eagle_scale() -> void:
	var ws := WorldScaleDriver.target_scale(3.0, 1.5)
	var rig := make_rig(ws)
	var w := Node3D.new()
	add_child(w)
	var z := 0.0
	while z > -900.0:
		box(w, Vector3(10.0, 2.0, 10.0), Vector3(0, -1, z - 5.0))
		z -= 20.0
	await wait_physics(2)
	var st := stats_of(fly(rig, 16.0, 4.0, 12.0, 3.0))
	metric("eagle_broken_canopy", st)
	print("[vr_verify] eagle ws %.3f, 16 m/s, 4 m over 10 m crowns / 10 m gaps: %s" % [ws, str(st)])
	lt(st["p2p"], 0.10, "eagle steady flight over a broken canopy: no pulsing (peak-to-trough %.3f)" % st["p2p"])
	w.queue_free()
	(rig["body"] as Node).queue_free()
