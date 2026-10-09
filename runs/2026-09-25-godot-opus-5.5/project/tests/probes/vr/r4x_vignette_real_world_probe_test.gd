extends TestCase
## VERIFIER PROBE (vr, round 4, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r4x_vignette_real_world
##
## The same question as r4x_vignette_flicker, on the REAL world geometry
## (scenes/world/world.tscn, as the simulator harness loads it): a sparrow
## flying straight and level at cruise (9 m/s) along and across the
## orchard rows, at a constant height just above the tallest thing
## under its path. Does the comfort vignette hold still, or pulse as each
## tree crown / roof passes under it?
##
## Supplementary evidence only (depends on the world area's current build).

const DT := 1.0 / 72.0
const SETTING := 0.6


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
	return {"body": body, "origin": origin, "camera": cam, "vignette": v}


## Highest collider top (layers 1|2) under the straight path a -> b, below
## 60 m above the ground (the arena's invisible ceiling is a collider too).
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


func fly_line(rig: Dictionary, a: Vector3, b: Vector3, speed: float, eye_y: float) -> PackedFloat32Array:
	var body := rig["body"] as Node3D
	var cam := rig["camera"] as Node3D
	var v := rig["vignette"] as ComfortVignette
	var dir := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
	body.basis = Basis.looking_at(dir, Vector3.UP)
	body.position = Vector3(a.x, eye_y - cam.position.y, a.z)
	v.reset_motion()
	var out := PackedFloat32Array()
	var n := int(Vector2(b.x - a.x, b.z - a.z).length() / (speed * DT))
	for i in n:
		body.position += dir * speed * DT
		v.measure(DT)
		v.update_strength(DT)
		out.append(v.strength())
	return out


static func stats_of(s: PackedFloat32Array, skip: int) -> Dictionary:
	var lo := INF
	var hi := -INF
	var above := 0
	var n := 0
	var ups := 0
	for i in range(skip, s.size()):
		lo = minf(lo, s[i])
		hi = maxf(hi, s[i])
		n += 1
	var mid := 0.5 * (lo + hi)
	var biggest_drop_rise := 0.0
	var trough := INF
	for i in range(skip, s.size()):
		if s[i] > 0.10:
			above += 1
		if i > skip and s[i - 1] < mid and s[i] >= mid and hi - lo >= 0.05:
			ups += 1
		trough = minf(trough, s[i])
		biggest_drop_rise = maxf(biggest_drop_rise, s[i] - trough)
		if s[i] > trough + 0.001 and i + 1 < s.size() and s[i + 1] < s[i]:
			trough = INF
	return {"min": snappedf(lo, 0.001), "max": snappedf(hi, 0.001), "p2p": snappedf(hi - lo, 0.001),
		"pulses_per_s": snappedf(ups / maxf(DT, n * DT), 0.01), "frac_above_0_10": snappedf(float(above) / maxf(1, n), 0.01),
		"largest_rise_after_a_fall": snappedf(biggest_drop_rise, 0.001), "seconds": snappedf(n * DT, 0.1)}


func test_sparrow_over_the_orchard() -> void:
	if not ResourceLoader.exists("res://scenes/world/world.tscn"):
		print("[vr_verify] no world scene: skipped")
		return
	var world := (load("res://scenes/world/world.tscn") as PackedScene).instantiate()
	add_child(world)
	var w := world as World
	if w != null and not w.is_generated:
		await w.generated
	await wait_physics(3)
	var ws := WorldScaleDriver.target_scale(0.03, 1.5)
	var rig := make_rig(ws)
	var results := {}
	# Orchard rows: trees at x = -110 + (i - 3.5) * 9.5, rows z = 205 + (j - 2) * 10.
	var lines := {}
	for j in [1, 2, 3]:
		var z: float = 205.0 + (j - 2) * 10.0
		lines["orchard_row_%d" % j] = [Vector3(-160.0, 0, z), Vector3(-60.0, 0, z)]
	# Across the rows (north-south through a column of trees).
	lines["orchard_column"] = [Vector3(-110.0 + 0.5 * 9.5, 0, 170.0), Vector3(-110.0 + 0.5 * 9.5, 0, 240.0)]
	for key: String in lines:
		var a: Vector3 = lines[key][0]
		var b: Vector3 = lines[key][1]
		var top := path_top(w, a, b)
		for above_top in [1.0, 1.5]:
			var s := fly_line(rig, a, b, 9.0, top + above_top)
			var st := stats_of(s, int(1.0 / DT))
			var k := "%s_%.1fm_over_top" % [key, above_top]
			if key == "orchard_row_2" and above_top == 1.0:
				# The raw trace (every 3rd tick, 24 Hz) for plotting.
				var trace := []
				for i in range(0, s.size(), 3):
					trace.append(snappedf(s[i], 0.001))
				metric("trace_orchard_row_2_1m_24hz", trace)
			results[k] = st
			print("[vr_verify] sparrow ws %.3f 9 m/s %s (path top %.1f m): %s" % [ws, k, top, str(st)])
			if above_top == 1.0:
				lt(st["p2p"], 0.10, "real orchard, %s: steady flight should not pulse the vignette (%.3f..%.3f, %.2f pulses/s)" % [k, st["min"], st["max"], st["pulses_per_s"]])
	metric("sparrow_real_orchard", results)
	# Forest interior (metric only): straight lines through the wood at
	# 2.5 m above the highest ground under the path (among the trunks,
	# under most crowns). The ground below gives steady flow; trunks and
	# low crowns abeam come and go.
	var fc := Vector3(-262.0, 0, -258.0)
	var forest := {}
	for ang in [0.0, 60.0, 120.0]:
		var d := Vector3(cos(deg_to_rad(ang)), 0, sin(deg_to_rad(ang)))
		var a := fc - d * 80.0
		var b := fc + d * 80.0
		var g := -INF
		for i in 161:
			var p := a.lerp(b, i / 160.0)
			g = maxf(g, w.ground_height(p.x, p.z))
		var s := fly_line(rig, a, b, 9.0, g + 2.5)
		var st := stats_of(s, int(1.0 / DT))
		forest["forest_line_%d_deg" % int(ang)] = st
		print("[vr_verify] sparrow 9 m/s through the forest, line %d deg, 2.5 m over the highest ground: %s" % [int(ang), str(st)])
	metric("sparrow_real_forest", forest)
	(rig["body"] as Node).queue_free()
	world.queue_free()
	await wait_frames(2)
