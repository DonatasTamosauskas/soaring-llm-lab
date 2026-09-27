extends Node3D
## A9 visual evidence (forward_plus screenshots) of AI behaviours, staged in
## the valley the game ships with (the world area's scenes/world/world.tscn,
## used through the World contract) with the real NpcBird/NpcBrain code:
##   ai_flock.png           a starling murmuration of the in-game size over
##                          its roost, seen from its edge
##   ai_perched.png         small birds on the power-line wires, close up
##   ai_perched_branch.png  wrens and sparrows on a tree's branches
##   ai_stoop.png           a hawk folded into a stoop on a pigeon
##   ai_thermal.png         gulls and a hawk circling up a thermal, seen from
##                          inside the column
##   ai_chase.png           a crow chasing a jinking starling
##   ai_overview.png        the ecosystem (60 NPCs) round the player spawn
## Every caption gives the on-screen size of the nearest bird (a still is
## only evidence if the birds in it can be seen: >= 40 px).
##
##   tools/gd.sh ai --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/ai_shots.tscn -- [--shot=stoop] [--world=test]
##
## Trails are camera-facing ribbons of the recorded path (unshaded), so a
## single still frame shows the motion that led to it.

const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const DT := 1.0 / 72.0
const TRAIL_COLORS := {
	&"starling": Color(0.15, 0.2, 0.15), &"sparrow": Color(0.55, 0.35, 0.15),
	&"hawk": Color(0.85, 0.35, 0.1), &"pigeon": Color(0.3, 0.45, 0.85),
	&"gull": Color(0.95, 0.95, 0.95), &"crow": Color(0.05, 0.05, 0.05),
	&"eagle": Color(0.6, 0.3, 0.1),
}

var world: World
var cam: Camera3D
var birds: Array[NpcBird] = []
var trails := {}
var _trail_nodes: Array[Node] = []
var _seed := 500
var _caption: Label
## The air's clock: every shot starts its air (thermal drift and pulse,
## gusts) at 0 and _sim advances it in sim time, so a still is reproducible
## from its setup (the valley otherwise advances its air on real frames).
var _air_t := 0.0


func _ready() -> void:
	if Paths.arg("world", "real") == "test":
		var tw := AiTestWorld.new()
		tw.with_visuals = true
		tw.with_environment = true
		world = tw
	else:
		world = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(world)
	if not world.is_generated:
		await world.generated
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.03
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var cl := CanvasLayer.new()
	add_child(cl)
	_caption = Label.new()
	_caption.position = Vector2(16, 12)
	_caption.add_theme_font_size_override("font_size", 20)
	_caption.add_theme_color_override("font_color", Color("#0b0b0b"))
	_caption.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_caption.add_theme_constant_override("outline_size", 6)
	cl.add_child(_caption)
	for i in 3:
		await get_tree().physics_frame
	var only := Paths.arg("shot", "")
	var shots := ["flock", "perched", "branch", "stoop", "thermal", "chase", "overview"]
	for s in shots:
		if only == "" or only == s:
			_air_t = 0.0
			_air()
			await call("_shot_" + s)
			_clear()
			await get_tree().process_frame
	print("[ai] shots done")
	get_tree().quit()


func _hab() -> Habitat:
	return Habitat.for_world(world)


func _air() -> void:
	if world.has_method(&"set_air_time"):
		world.call(&"set_air_time", _air_t)


func _spawn(sp: StringName, pos: Vector3, vel: Vector3) -> NpcBird:
	var n := NpcBird.new()
	n.managed = true
	_seed += 13
	n.configure(sp, -1.0, _seed, _hab())
	n.energy = 1.0
	n.hunger = 0.0
	add_child(n)
	n.global_position = pos
	n.flight.set_velocity(vel)
	n.velocity = vel
	n.global_transform = Transform3D(Basis.looking_at(vel.normalized(), Vector3.UP), pos)
	n.home = Vector3(pos.x, 0, pos.z)
	n.home_radius = 80.0
	birds.append(n)
	return n


func _sim(seconds: float, per_tick: Callable = Callable(), record: Array = []) -> void:
	var chk: RefCounted = CatchChecker.new()
	for i in int(seconds / DT):
		_air_t += DT
		_air()
		for b in birds:
			if is_instance_valid(b) and b.alive:
				b.tick(DT)
		chk.step(DT)
		if i % 3 == 0:
			for b in record:
				if is_instance_valid(b):
					if not trails.has(b):
						trails[b] = PackedVector3Array()
					trails[b].append(b.global_position)
		if per_tick.is_valid() and per_tick.call(i):
			break


## On-screen size (px) of a bird of span `span` at distance d with the
## current camera (vertical field of view, 720-px frame height).
func _px(span: float, d: float) -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	return span * h / (2.0 * maxf(d, 0.01) * tan(deg_to_rad(cam.fov) * 0.5))


## Nearest bird to the camera and its on-screen size: the wingspan in
## flight, the folded body (~45% of the span) on a perch.
func _nearest_px(list: Array) -> Array:
	var best: NpcBird = null
	var bd := INF
	for b in list:
		if not is_instance_valid(b):
			continue
		var d: float = (b as NpcBird).global_position.distance_to(cam.global_position)
		if d < bd:
			bd = d
			best = b
	if best == null:
		return [null, INF, 0.0]
	return [best, bd, _px(best.get_wingspan() * (0.45 if best.perched else 1.0), bd)]


func _draw_trails(max_pts: int = 400, alpha := 0.9, px := 3.0, group_colors := false) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cp := cam.global_position
	var k := 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / float(get_viewport().get_visible_rect().size.y)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	var any := false
	for b in trails:
		var pts: PackedVector3Array = trails[b]
		if pts.size() < 2:
			continue
		var sp: StringName = b.species if is_instance_valid(b) else &""
		var c: Color = TRAIL_COLORS.get(sp, Color(1, 0.5, 0))
		if group_colors:
			c = [Color("#2a78d6"), Color("#1baf7a"), Color("#eb6834")][0 if SizeRules.species_index(sp) <= 3 else (1 if SizeRules.species_index(sp) <= 6 else 2)]
		var start := maxi(0, pts.size() - max_pts)
		var n := pts.size() - start
		for i in range(start, pts.size() - 1):
			var a := pts[i]
			var e := pts[i + 1]
			var seg := e - a
			if seg.length_squared() < 1e-8:
				continue
			var side_a := seg.cross(cp - a).normalized() * (cp.distance_to(a) * k * px * 0.5)
			var side_e := seg.cross(cp - e).normalized() * (cp.distance_to(e) * k * px * 0.5)
			var ca := Color(c.r, c.g, c.b, alpha * float(i - start) / n)
			var ce := Color(c.r, c.g, c.b, alpha * float(i + 1 - start) / n)
			for v in [[a - side_a, ca], [a + side_a, ca], [e + side_e, ce], [a - side_a, ca], [e + side_e, ce], [e - side_e, ce]]:
				im.surface_set_color(v[1])
				im.surface_add_vertex(v[0])
			any = true
	if not any:
		for i in 3:
			im.surface_add_vertex(Vector3.ZERO)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_trail_nodes.append(mi)


func _capture(name: String, caption: String = "") -> void:
	_caption.text = caption
	# Two frames so models update their pose (BirdModel animates in _process).
	await get_tree().process_frame
	await get_tree().process_frame
	await Capture.save_viewport(get_viewport(), Paths.artifacts("ai").path_join(name))


func _clear() -> void:
	for b in birds:
		if is_instance_valid(b):
			remove_child(b)
			b.queue_free()
	birds.clear()
	trails.clear()
	for n in _trail_nodes:
		n.queue_free()
	_trail_nodes.clear()


func _look(from: Vector3, at: Vector3, fov: float = 60.0) -> void:
	cam.fov = fov
	cam.global_position = from
	cam.look_at(at, Vector3.UP)


## A camera spot `dist` from the birds with a clear line to each of them,
## trying directions round `pref` (and a little above or below it).
func _telephoto_spot(list: Array, pref: Vector3, dist: float) -> Vector3:
	var c := Vector3.ZERO
	for b in list:
		c += (b as NpcBird).global_position
	c /= float(list.size())
	var h := _hab()
	for el in [0.25, 0.0, 0.5, -0.15]:
		for k in 16:
			var d := pref.rotated(Vector3.UP, 0.4 * float((k + 1) / 2) * (1.0 if k % 2 == 1 else -1.0))
			d = (d + Vector3.UP * el).normalized()
			var p := c + d * dist
			var ok := not h.blocked(p, 0.3)
			for b in list:
				# The bird and a margin round it in clear view (not peering
				# through a gap in the leaves).
				var bp: Vector3 = (b as NpcBird).global_position
				for off in [Vector3.ZERO, Vector3(0, 0.25, 0), d.cross(Vector3.UP).normalized() * 0.3, -d.cross(Vector3.UP).normalized() * 0.3]:
					if ok and not h.ray(p, bp + off).is_empty():
						ok = false
			if ok:
				return p
	return Vector3.INF


## A camera spot near `at` with a clear line to it, preferring `pref`.
func _clear_spot(at: Vector3, pref: Vector3, dist: float) -> Vector3:
	var h := _hab()
	for k in 16:
		var d := pref.rotated(Vector3.UP, 0.4 * float((k + 1) / 2) * (1.0 if k % 2 == 1 else -1.0))
		var p := at + d * dist
		if h.ray(at, p).is_empty() and not h.blocked(p, 0.3):
			return p
	return at + pref * dist


func _landmark(kinds: Array) -> Dictionary:
	for k in kinds:
		var l: Array = _hab().landmarks_of(k)
		if not l.is_empty():
			return l[0]
	return {"position": world.get_player_spawn().origin}


func _shot_flock() -> void:
	var roost := _landmark(["roost", "field", "meadow"])
	var home: Vector3 = roost["position"]
	var fl := FlockGroup.new(1, &"starling", "murmuration", Vector3(home.x, 0, home.z), _hab(), 21)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	# The ecosystem's murmuration: 12 starlings, up to ~16 with joiners.
	for i in 16:
		var b := _spawn(&"starling", fl.anchor + Vector3(rng.randf_range(-8, 8), rng.randf_range(-3, 3), rng.randf_range(-8, 8)), Vector3(0, 0, -10))
		b.flock = fl
		b.can_hunt = false
		b.can_flee = false
		fl.members.append(b)
		b.set_state(NpcBird.State.FLOCK)
	_sim(25.0, func(_i: int) -> bool:
		fl.update(DT)
		return false, birds)
	# Then a moment when the body is packed (a murmuration breathes: it
	# spreads and bunches as it wheels), up to 15 s more.
	# (Lambdas capture locals by value: the measurements live in a dictionary.)
	var m := {"c": fl.centroid(), "rad": INF}
	_sim(15.0, func(i: int) -> bool:
		fl.update(DT)
		if i % 18 != 0:
			return false
		var cc := fl.centroid()
		var ds: Array[float] = []
		for b in birds:
			ds.append(b.global_position.distance_to(cc))
		ds.sort()
		m["c"] = cc
		m["rad"] = ds[int(ds.size() * 0.9)]
		return m["rad"] < 6.5, birds)
	var c: Vector3 = m["c"]
	var rad: float = m["rad"]
	var v := Vector3.ZERO
	for b in birds:
		v += b.velocity
	v = Vector3(v.x, 0.0, v.z).normalized()
	var side := v.cross(Vector3.UP).normalized()
	# From the side and below, looking up ~25 deg: the whole body in frame
	# against the sky (not scattered over a cliff face), wide enough that
	# each bird is still a starling. The flock spans ~half the frame.
	var dist := maxf(rad * 2.0 / (2.0 * tan(deg_to_rad(34.0) * 0.5)) * 1.1, 14.0)
	# Of the spots round the flock, low and looking up, the first with the
	# flock in clear view and open sky behind it (not a cliff or the spire).
	var h := _hab()
	var spot := c + (side + Vector3.DOWN * 0.47).normalized() * dist
	var found := false
	for down: float in [0.7, 0.47, 0.9]:
		for k in 12:
			var dir := (side.rotated(Vector3.UP, TAU * k / 12.0) + Vector3.DOWN * down).normalized()
			var p := c + dir * dist
			if p.y < world.ground_height(p.x, p.z) + 2.0:
				continue
			if h.ray(p, c).is_empty() and h.ray(c, c - dir * 400.0).is_empty():
				spot = p
				found = true
				break
		if found:
			break
	var g := world.ground_height(spot.x, spot.z) + 2.0
	if spot.y < g:
		spot.y = g
	_look(spot, c, 34.0)
	_draw_trails(18, 0.5, 2.0)
	var near := _nearest_px(birds)
	await _capture("ai_flock.png", "Starling murmuration (%d, the in-game size) wheeling over its roost, seen from below\n90%% within %.1f m of its centre; nearest bird %.0f m, %.0f px across" % [birds.size(), rad, near[1], near[2]])


func _shot_perched() -> void:
	var span := SizeRules.wingspan_for_mass(0.03)
	var wire: Perch = null
	var sp0 := world.get_player_spawn().origin
	var best_d := INF
	for p in world.get_perches():
		if p.kind == Perch.Kind.WIRE and p.is_free() and not _hab().is_enclosed(p):
			# Some free neighbours along the same span.
			var n := 0
			for q in world.find_perches(p.position, 8.0, span):
				if q.kind == Perch.Kind.WIRE:
					n += 1
			var d := p.position.distance_to(sp0)
			if n >= 3 and d < best_d:
				best_d = d
				wire = p
	if wire == null:
		print("[ai] no wire span found")
		return
	var sp_list := [&"sparrow", &"swallow", &"sparrow", &"starling", &"sparrow", &"swallow"]
	for i in sp_list.size():
		var b := _spawn(sp_list[i], wire.position + Vector3(6 + (i % 3) * 0.8, 2.5 + (i / 3) * 0.6, 5 + (i % 2) * 0.8), Vector3(-5, -1, -4))
		b.energy = 0.05
		b.can_hunt = false
		b.can_flee = false
		b.home = Vector3(wire.position.x, 0, wire.position.z)
		b.home_radius = 12.0
	_sim(45.0, func(_i: int) -> bool:
		var n := 0
		for b in birds:
			if b.perched:
				n += 1
			b.energy = minf(b.energy, 0.3)
		return n == birds.size())
	_sim(1.5, func(_i: int) -> bool:
		for b in birds:
			b.energy = minf(b.energy, 0.3)
		return false)
	var perched: Array[NpcBird] = []
	for b in birds:
		if b.perched and b.perch_spot.kind == Perch.Kind.WIRE:
			perched.append(b)
	if perched.is_empty():
		print("[ai] nobody perched on the wire")
		return
	# Close up along the wire from its side: the nearest birds ~2 m off.
	perched.sort_custom(func(a: NpcBird, b2: NpcBird) -> bool: return a.global_position.x < b2.global_position.x)
	var a0: NpcBird = perched[0]
	var c := Vector3.ZERO
	for b in perched:
		c += b.global_position
	c /= float(perched.size())
	var along := (perched[-1].global_position - a0.global_position)
	along.y = 0.0
	along = along.normalized() if along.length_squared() > 0.01 else Vector3.RIGHT
	var across := along.cross(Vector3.UP).normalized()
	var spot := _clear_spot(a0.global_position, (across - along * 0.6).normalized(), 2.2) + Vector3(0, 0.4, 0)
	_look(spot, c.lerp(a0.global_position, 0.5), 50.0)
	var near := _nearest_px(perched)
	var kinds := {}
	for o in perched:
		kinds[String(o.species)] = kinds.get(String(o.species), 0) + 1
	print("[ai] perched %d/%d on the wire" % [perched.size(), sp_list.size()])
	await _capture("ai_perched.png", "Small birds on a power-line wire in the valley, one per perch %s; nearest %.1f m, %.0f px across" % [str(kinds).replace("\"", ""), near[1], near[2]])


func _shot_branch() -> void:
	var span := SizeRules.wingspan_for_mass(0.03)
	var sp0 := world.get_player_spawn().origin
	# A branch perch in a tree with a few more on the same tree.
	var branch: Perch = null
	var best_d := INF
	for p in world.get_perches():
		if p.kind != Perch.Kind.BRANCH or not p.fits(span) or not p.is_free() or _hab().is_enclosed(p) or not _hab().seat_clear(p, span * 0.16):
			continue
		if p.position.y - world.ground_height(p.position.x, p.position.z) < 2.5:
			continue  # hedge tops: we want a tree
		var n := 0
		for q in world.find_perches(p.position, 5.0, span):
			if q.kind == Perch.Kind.BRANCH:
				n += 1
		var d := p.position.distance_to(sp0)
		if n >= 2 and d < best_d:
			best_d = d
			branch = p
	if branch == null:
		print("[ai] no tree branch found")
		return
	var sp_list := [&"wren", &"sparrow", &"wren", &"sparrow"]
	for i in sp_list.size():
		var b := _spawn(sp_list[i], branch.position + Vector3(-8 + i * 1.2, 4.0, 6), Vector3(4, -1, -4))
		b.energy = 0.05
		b.can_hunt = false
		b.can_flee = false
		b.home = Vector3(branch.position.x, 0, branch.position.z)
		b.home_radius = 6.0
	_sim(45.0, func(_i: int) -> bool:
		var n := 0
		for b in birds:
			if b.perched:
				n += 1
			b.energy = minf(b.energy, 0.3)
		return n == birds.size())
	var perched: Array[NpcBird] = []
	for b in birds:
		if b.perched and b.perch_spot.kind == Perch.Kind.BRANCH:
			perched.append(b)
	if perched.is_empty():
		print("[ai] nobody perched on branches")
		return
	# The pair of perched birds closest together, framed ~1.2 m off.
	var a: NpcBird = perched[0]
	var bb: NpcBird = perched[0]
	var best := INF
	for i in perched.size():
		for j in range(i + 1, perched.size()):
			var dd := perched[i].global_position.distance_to(perched[j].global_position)
			if dd < best:
				best = dd
				a = perched[i]
				bb = perched[j]
	var c := (a.global_position + bb.global_position) * 0.5 if best < 3.0 else a.global_position
	# From outside the crown, a long lens: the tree's branch perches ring its
	# trunk, so away from their middle is out through the gap the bird sits
	# in; the first spot 7 m off with nothing between it and the birds.
	var mid := Vector3.ZERO
	var nb := 0
	for q in world.find_perches(a.perch_spot.position, 5.0, 0.1):
		if q.kind == Perch.Kind.BRANCH:
			mid += q.position
			nb += 1
	mid /= float(maxi(nb, 1))
	var out := a.perch_spot.position - mid
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 0.01 else a.perch_spot.facing
	# The two perched birds together if some spot sees both clearly (a
	# wider lens for a pair a couple of metres apart), else one of them.
	var spot := Vector3.INF
	var framed: Array = []
	var fov := 24.0
	for pass_i in 2:
		for i in perched.size():
			for j in range(i + 1 if pass_i == 0 else i, perched.size() if pass_i == 0 else i + 1):
				var grp: Array = [perched[i]] if pass_i == 1 else [perched[i], perched[j]]
				var gc := Vector3.ZERO
				for gb in grp:
					gc += (gb as NpcBird).perch_spot.position
				gc /= float(grp.size())
				var o2 := gc - mid
				o2.y = 0.0
				o2 = o2.normalized() if o2.length_squared() > 0.01 else (grp[0] as NpcBird).perch_spot.facing
				var sep := (grp[0] as NpcBird).global_position.distance_to((grp[-1] as NpcBird).global_position)
				var f2 := 24.0 if grp.size() == 1 else 40.0
				var dist := 2.6 if grp.size() == 1 else maxf(3.0, sep * 1.6 / (2.0 * tan(deg_to_rad(f2) * 0.5)))
				var sp2 := _telephoto_spot(grp, o2, dist)
				if sp2 != Vector3.INF:
					spot = sp2
					framed = grp
					fov = f2
					break
			if not framed.is_empty():
				break
		if not framed.is_empty():
			break
	if spot == Vector3.INF:
		framed = [a]
		spot = a.global_position + out * 4.0 + Vector3.UP
	var fc := Vector3.ZERO
	for gb in framed:
		fc += (gb as NpcBird).global_position
	fc /= float(framed.size())
	_look(spot, fc + Vector3(0, 0.05, 0), fov)
	var near := _nearest_px(framed)
	var names := []
	for gb in framed:
		names.append(String((gb as NpcBird).species))
	print("[ai] branch: %d of %d perched on branches, %d framed" % [perched.size(), sp_list.size(), framed.size()])
	var who := "A " + " and a ".join(names)
	await _capture("ai_perched_branch.png", "%s perched on a tree's branches in the valley (%d in frame; %d of the %d birds sent there perched); nearest %.1f m, %.0f px across" % [who, framed.size(), perched.size(), sp_list.size(), near[1], near[2]])


func _shot_stoop() -> void:
	var f := _landmark(["field", "meadow"])
	var base: Vector3 = f["position"]
	base.y = world.ground_height(base.x, base.z)
	var prey := _spawn(&"pigeon", base + Vector3(0, 22, 0), Vector3(-12, 0, 2))
	prey.can_flee = false
	prey.can_hunt = false
	var hawk := _spawn(&"hawk", base + Vector3(40, 95, 35), Vector3(-10, 0, -10))
	hawk.hunger = 1.0
	hawk.can_flee = false
	hawk.brain._pending_prey = prey
	hawk.brain._enter(NpcBird.State.HUNT)
	hawk.brain._maybe_stoop()
	_sim(8.0, func(_i: int) -> bool:
		return hawk.state == NpcBird.State.STOOP and hawk.flight.fold > 0.9 and hawk.flight.speed > hawk.flight.cruise * 1.7 \
			and hawk.global_position.distance_to(prey.global_position) < 30.0, [hawk, prey])
	var hp := hawk.global_position
	var v := hawk.velocity.normalized()
	var side := v.cross(Vector3.UP).normalized()
	_look(hp + side * 5.0 - v * 1.5, hp + v * 2.0, 62.0)
	_draw_trails(120, 0.9, 4.0)
	var near := _nearest_px([hawk])
	await _capture("ai_stoop.png", "Hawk stoop over a valley field: wings %d%% tucked, %.1f m/s (cruise %.1f, limit %.1f), %.0f m above its pigeon; hawk %.0f px across" % [int(hawk.flight.fold * 100), hawk.flight.speed, hawk.flight.cruise, hawk.flight.max_speed, hp.y - prey.global_position.y, near[2]])


func _shot_thermal() -> void:
	var ths := world.get_thermals()
	if ths.is_empty():
		print("[ai] no thermals")
		return
	var sp0 := world.get_player_spawn().origin
	var th: Dictionary = ths[0]
	for t in ths:
		if (t["position"] as Vector3).distance_to(sp0) < (th["position"] as Vector3).distance_to(sp0):
			th = t
	var c: Vector3 = th["position"]
	var list := [[&"gull", 30.0], [&"gull", 42.0], [&"gull", 54.0], [&"hawk", 36.0]]
	for i in list.size():
		var a := TAU * i / list.size()
		var b := _spawn(list[i][0], c + Vector3(cos(a) * 30, list[i][1], sin(a) * 30), Vector3(-sin(a), 0, cos(a)) * 12.0)
		b.can_hunt = false
		b.can_flee = false
		b.brain._perch_cool = 999.0
		b.home = Vector3(c.x, 0, c.z)
		b.home_radius = 100.0
	var climb0 := {}
	for b in birds:
		climb0[b] = b.global_position.y
	# Per bird: seconds circling (SOAR) and the most effort while circling
	# (a dict: lambdas capture locals by value).
	var soar := {}
	for b in birds:
		soar[b] = {"s": 0.0, "eff": 0.0}
	_sim(40.0, func(_i: int) -> bool:
		for b in birds:
			if b.state == NpcBird.State.SOAR and b.brain._circling:
				soar[b]["s"] += DT
				soar[b]["eff"] = maxf(soar[b]["eff"], b.flight.effort)
				soar[b]["esum"] = soar[b].get("esum", 0.0) + b.flight.effort * DT
		return false, birds)
	# From inside the column at the height of the lowest gull, a gull ~12 m
	# off and the others circling above and across.
	var low: NpcBird = birds[0]
	for b in birds:
		if b.species == &"gull" and b.global_position.y < low.global_position.y:
			low = b
	var ctr := Habitat.thermal_center(th, low.global_position.y)
	var to_low := low.global_position - ctr
	to_low.y = 0.0
	# Just outside the circles, on the side of the lowest gull: it is ~8 m
	# off, the others circling above it, the helix of trails rising.
	var spot := low.global_position + to_low.normalized() * 8.0 + Vector3(0, -3.0, 0)
	_look(spot, ctr + Vector3(0, 8.0, 0), 62.0)
	_draw_trails(200, 0.85, 3.0)
	# The caption says what each bird did: its climb, how long it circled
	# and its mean flapping effort while circling (the highest of the gulls).
	var gulls := []
	var hawk := ""
	var eff := 0.0
	for b in birds:
		var dy := b.global_position.y - float(climb0[b])
		if b.species == &"gull":
			gulls.append("%+.0f" % dy)
			eff = maxf(eff, soar[b].get("esum", 0.0) / maxf(soar[b]["s"], 0.01))
		else:
			hawk = "hawk %+.0f m, circled %.0f s%s" % [dy, soar[b]["s"],
				"" if b.state == NpcBird.State.SOAR else ", then left the thermal"]
	print("[ai] thermal: gulls %s m, %s, mean effort circling %.3f; %s" % ["/".join(gulls), hawk, eff, str(soar.values())])
	var near := _nearest_px(birds)
	await _capture("ai_thermal.png", "Three gulls (white trails) and a hawk (orange) put on a valley thermal, 40 s: gulls %s m gliding\n(mean flapping effort while circling %.3f); %s; nearest %.0f m, %.0f px across" % ["/".join(gulls), eff, hawk, near[1], near[2]])


func _shot_chase() -> void:
	var f := _landmark(["meadow", "field"])
	var base: Vector3 = f["position"]
	base.y = world.ground_height(base.x, base.z)
	var prey := _spawn(&"starling", base + Vector3(0, 30, 0), Vector3(-10, 0, 3))
	prey.can_hunt = false
	var crow := _spawn(&"crow", base + Vector3(22, 31, 6), Vector3(-15, 0, 0))
	crow.hunger = 1.0
	crow.can_flee = false
	crow.brain._pending_prey = prey
	crow.brain._enter(NpcBird.State.HUNT)
	prey.brain._perch_cool = 999.0
	var m := {"jinks": 0}
	prey.behaviour.connect(func(_b: NpcBird, what: StringName) -> void:
		if what == &"jink":
			m["jinks"] += 1)
	_sim(14.0, func(_i: int) -> bool:
		var d := crow.global_position.distance_to(prey.global_position)
		return not prey.alive or (d < 2.0 and prey.state == NpcBird.State.FLEE), [crow, prey])
	# Behind and above the crow, looking down the pursuit line at its
	# quarry: the starling ahead, the crow's trail running up the
	# starling's, the gap between them readable.
	var line := prey.global_position - crow.global_position
	var fwd := line.normalized() if line.length() > 0.3 else crow.velocity.normalized()
	var side := fwd.cross(Vector3.UP).normalized()
	var spot := crow.global_position - fwd * 3.0 + Vector3.UP * 1.0 + side * 0.8
	_look(spot, prey.global_position.lerp(crow.global_position, 0.25), 30.0)
	_draw_trails(160, 0.9, 3.0)
	var near := _nearest_px([crow, prey])
	await _capture("ai_chase.png", "Crow (black trail) closing on a fleeing starling (grey) over a valley meadow, from behind the crow\ngap %.1f m, crow %.1f m/s vs starling %.1f m/s, jinks so far: %d; starling %.0f px across" % [crow.global_position.distance_to(prey.global_position), crow.velocity.length(), prey.velocity.length(), m["jinks"], _px(prey.get_wingspan(), prey.global_position.distance_to(cam.global_position))])


func _shot_overview() -> void:
	var e := preload("res://scenes/ai/ecosystem.tscn").instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 11
	add_child(e)
	var chk: RefCounted = CatchChecker.new()
	var total := int(50.0 / DT)
	for i in total:
		e.step(DT)
		chk.step(DT)
		if i > total - int(12.0 / DT) and i % 3 == 0:
			for n in e.get_npcs():
				if not trails.has(n):
					trails[n] = PackedVector3Array()
				trails[n].append(n.global_position)
	var c := Vector3.ZERO
	for n in e.get_npcs():
		c += n.global_position
	c /= float(maxi(e.count(), 1))
	_look(c + Vector3(60, 170, 240), c, 65.0)
	_draw_trails(96, 1.0, 4.0, true)
	var st := e.stats()
	await _capture("ai_overview.png", "Ecosystem in the valley, 60 NPCs, last 12 s of flight: small birds blue, starling/pigeon/crow green, gull/hawk/eagle orange\n%s" % str(st["by_state"]).replace("\"", ""))
	trails.clear()
	remove_child(e)
	e.queue_free()
