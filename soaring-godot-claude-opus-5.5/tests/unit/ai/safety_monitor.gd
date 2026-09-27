extends RefCounted
## A5 safety checks, run every tick of long simulations:
##  * nan:        position or velocity not finite
##  * below:      body centre below the terrain (World.ground_height)
##  * inside:     inside world geometry, every 6 ticks: the body centre
##                inside a convex collider (point query), or the body (60%
##                of its radius) touching a concave/trimesh surface. A point
##                query alone is wrong for trimeshes: Jolt answers it by ray
##                parity, so a bird flying inside a house's room (a refuge,
##                a fly-through window) would count as "inside the house".
##  * bounds:     outside World.is_inside (arena radius, ceiling, ground)
##  * stuck:      moved < 1 m from where it was 20 s ago, having been free
##                (not perched, hidden or landing) for all of those 20 s.
## Also measures flight envelopes in the wild (A4 cross-check) from the
## body's actual motion (position deltas, air-relative): over 0.5 s windows
## of free flight (no collision, landing flare or strike lunge in the window)
## near cruise speed, horizontal turn rate and climb rate vs
## SizeRules.performance, and top speed vs max_speed.

var world: World
var counts := {"nan": 0, "below": 0, "inside": 0, "bounds": 0, "stuck": 0}
var examples: Array[String] = []
## "kind/state/flaring" -> count, to tell situations apart.
var by_situation := {}
var ticks := 0
var bird_ticks := 0
## species -> {turn_ratio_max, climb_ratio_max, speed_ratio_max, windows}
var envelope := {}
## Largest relative difference between how fast a body actually moved and
## the speed its flight model reported, over clean free-flight segments
## (bodies must move with their physics; A4 is measured on the physics).
var motion_mismatch := 0.0
var motion_segments := 0
## Segments off by more than 10%, and the summed relative mismatch.
var motion_bad := 0
var motion_sum := 0.0

var _t := 0.0
var _hist := {}
var _win := {}
var _q: PhysicsPointQueryParameters3D
var _sq: PhysicsShapeQueryParameters3D
var _sphere: SphereShape3D


func _init(w: World) -> void:
	world = w
	_q = PhysicsPointQueryParameters3D.new()
	_q.collision_mask = 1
	_q.collide_with_areas = false
	_sphere = SphereShape3D.new()
	_sq = PhysicsShapeQueryParameters3D.new()
	_sq.shape = _sphere
	_sq.collision_mask = 1
	_sq.collide_with_areas = false


static func _shape_of(hit: Dictionary) -> Shape3D:
	var col: Object = hit["collider"]
	if col == null or not col.has_method(&"shape_find_owner"):
		return null
	var owner_id: int = col.shape_find_owner(hit["shape"])
	return col.shape_owner_get_shape(owner_id, 0)


func _inside(space: PhysicsDirectSpaceState3D, n: NpcBird, p: Vector3) -> bool:
	_q.position = p
	for hit in space.intersect_point(_q, 4):
		if not (_shape_of(hit) is ConcavePolygonShape3D):
			return true
	_sphere.radius = n.get_body_radius() * 0.6
	_sq.transform = Transform3D(Basis.IDENTITY, p)
	for hit in space.intersect_shape(_sq, 4):
		var shp := _shape_of(hit)
		if shp is ConcavePolygonShape3D:
			# Touching the terrain mesh is the ground check's business.
			if absf(p.y - world.ground_height(p.x, p.z)) > n.get_body_radius() * 2.0 + 0.3:
				return true
	return false


func _flag(kind: String, n: NpcBird, msg: String) -> void:
	counts[kind] += 1
	var sit := "%s/%s/%s%s" % [kind, n.species, n.state_name(), "/flare" if n.is_flaring() else ""]
	by_situation[sit] = by_situation.get(sit, 0) + 1
	if counts[kind] <= 3:
		examples.append("%s t=%.1f %s %s %s" % [kind, _t, n.species, n.state_name(), msg])


static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func step(dt: float, npcs: Array) -> void:
	_t += dt
	ticks += 1
	var space := world.get_world_3d().direct_space_state
	var sample := ticks % 18 == 0
	for n: NpcBird in npcs:
		if not is_instance_valid(n) or not n.alive or not n.is_inside_tree():
			continue
		bird_ticks += 1
		var p := n.global_position
		if not _finite(p) or not _finite(n.velocity):
			_flag("nan", n, str(p))
			continue
		var g := world.ground_height(p.x, p.z)
		if p.y < g - 0.02:
			_flag("below", n, "%.2f m under" % (g - p.y))
		if not world.is_inside(p):
			_flag("bounds", n, str(p))
		if ticks % 6 == 0 and _inside(space, n, p):
			# Enough to find the case again: what it is in and how it got there.
			var what := ""
			_q.position = p
			for hit in space.intersect_point(_q, 2):
				what += " in:" + (String(hit["collider"].name) if hit["collider"] else "?")
			_sq.transform = Transform3D(Basis.IDENTITY, p)
			for hit in space.intersect_shape(_sq, 2):
				what += " touching:" + (String(hit["collider"].name) if hit["collider"] else "?")
			var tgt := ""
			if n.target != null and is_instance_valid(n.target):
				var tn := n.target as NpcBird
				tgt = " target=%s%s at %s" % [tn.species if tn else "player", (" perched" if tn.perched else "") + (" hidden" if tn.hidden else "") if tn else "", n.target.get_body_position().snapped(Vector3.ONE * 0.01)]
			_flag("inside", n, "%s v=%s%s%s%s last_hit=%s%s%s" % [p.snapped(Vector3.ONE * 0.01), n.velocity.snapped(Vector3.ONE * 0.1),
				" perched" if n.perched else "", " hidden" if n.hidden else "", " flaring" if n.is_flaring() else "",
				n.last_hit.snapped(Vector3.ONE * 0.01), what, tgt])
		if sample:
			_track(n, p)


## Every 0.25 s: stuck detection and envelope windows.
func _track(n: NpcBird, p: Vector3) -> void:
	var id := n.get_instance_id()
	var free := not (n.perched or n.hidden or n.is_flaring())
	var h: Array = _hist.get(id, [])
	h.append([_t, p, free])
	# Keep 20 s of history.
	while not h.is_empty() and _t - float(h[0][0]) > 20.01:
		h.pop_front()
	_hist[id] = h
	if h.size() >= 80 and _t - float(h[0][0]) > 19.7:
		var all_free := true
		for e in h:
			if not e[2]:
				all_free = false
				break
		if all_free and (h[0][1] as Vector3).distance_to(p) < 1.0:
			var worst := 0.0
			for e in h:
				worst = maxf(worst, (e[1] as Vector3).distance_to(h[0][1]))
			if worst < 1.0:
				_flag("stuck", n, "at %s" % p.snapped(Vector3.ONE * 0.1))
				h.clear()
	# Envelope windows of free flight, measured from the body's motion (what
	# a viewer sees), not the bird's own velocity: four samples 0.25 s apart
	# give three position-derived velocities spanning 0.5 s. Windows with a
	# collision, a landing flare or a strike lunge are skipped.
	var w: Array = _win.get(id, [])
	var wind := n.habitat.wind(p)
	w.append([_t, p, free, n.bumps + n.flares * 100000 + n.lunges * 1000, wind, n.velocity])
	if w.size() > 4:
		w.pop_front()
	_win[id] = w
	if w.size() < 4:
		return
	for e in w:
		if not e[2]:
			return
	if w[0][3] != w[3][3]:
		return
	var perf := SizeRules.performance(n.mass)
	var vs: Array[Vector3] = []
	for i in 3:
		var dt := float(w[i + 1][0]) - float(w[i][0])
		if dt <= 1e-4:
			return
		# Air-relative: turn and climb limits are about the bird, not the
		# breeze carrying it.
		var air: Vector3 = ((w[i][4] as Vector3) + (w[i + 1][4] as Vector3)) * 0.5
		vs.append(((w[i + 1][1] as Vector3) - (w[i][1] as Vector3)) / dt - air)
	var span_t := (float(w[3][0]) + float(w[2][0])) * 0.5 - (float(w[1][0]) + float(w[0][0])) * 0.5
	for i in 3:
		var rep: Vector3 = ((w[i][5] as Vector3) + (w[i + 1][5] as Vector3)) * 0.5
		var air: Vector3 = ((w[i][4] as Vector3) + (w[i + 1][4] as Vector3)) * 0.5
		var ground_v := vs[i] + air
		if rep.length() > 2.0 and ((w[i][5] as Vector3) - (w[i + 1][5] as Vector3)).length() < rep.length() * 0.25:
			var mm := absf(ground_v.length() / rep.length() - 1.0)
			motion_mismatch = maxf(motion_mismatch, mm)
			motion_segments += 1
			motion_sum += mm
			if mm > 0.1:
				motion_bad += 1
	var e: Dictionary = envelope.get(String(n.species), {"turn": 0.0, "climb": 0.0, "speed": 0.0, "windows": 0})
	e["windows"] += 1
	for v: Vector3 in vs:
		e["speed"] = maxf(e["speed"], v.length() / float(perf["max_speed"]))
	# At cruise throughout the window (every velocity within +-5%): turn rate
	# rises as 1/v below cruise, so an average near cruise with a slow middle
	# would not be a turn "at cruise".
	var cr := float(perf["cruise"])
	var at_cruise := true
	for v: Vector3 in vs:
		if absf(v.length() - cr) > cr * 0.05:
			at_cruise = false
	if at_cruise:
		var h0 := Vector2(vs[0].x, vs[0].z)
		var h2 := Vector2(vs[2].x, vs[2].z)
		if h0.length() > 1.0 and h2.length() > 1.0:
			var rate := absf(h0.angle_to(h2)) / span_t
			var ratio := rate / float(perf["turn_rate"])
			if ratio > e["turn"]:
				e["turn_at"] = "%s lod %d engaged %s" % [n.state_name(), n.lod, n.is_engaged()]
			e["turn"] = maxf(e["turn"], ratio)
		# Sustained climb = rate of gain of specific energy (height plus
		# v^2/2g) through the air: a zoom that trades speed for height does
		# not count, lift from the air mass is excluded.
		var vy_air := (vs[0].y + vs[1].y + vs[2].y) / 3.0
		var climb := vy_air + (vs[2].length_squared() - vs[0].length_squared()) / (2.0 * 9.81 * span_t)
		e["climb"] = maxf(e["climb"], climb / float(perf["climb"]))
	envelope[String(n.species)] = e


func total() -> int:
	var s := 0
	for k in counts:
		s += counts[k]
	return s
