extends "res://tests/unit/ai/ai_sim.gd"
## Flight diagnostic (integration: the ceiling fix), NPC side: do NPC birds
## (scripts/ai) bump the arena's lid in the real world (scenes/world/
## world.tscn, 300 m)? "Bump" = the body reaches the lid (its top at or
## above World.ceiling), the NpcBird ceiling clamp (ceiling - 0.5 m) fires,
## or a geometry contact happens up there.
##   tools/gd.sh flnpc --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_ceiling_npc_diag
## Output: artifacts/flight/ceiling/npc_diag_<tag>.txt

var _w: World = null
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight] ", s)


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated
	world = null


func after_all() -> void:
	for b in loose.duplicate():
		despawn(b)
	if is_instance_valid(_w):
		_w.queue_free()
	_w = null
	Habitat.clear_cache()
	await wait_frames(2)
	var tag: String = Paths.arg("tag", "now")
	var path := Paths.artifacts("flight").path_join("ceiling/npc_diag_%s.txt" % tag)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	await wait_frames(1)


## Per-bird lid watch: counts clamp events (entering the clamp band) and the
## closest the body's top came to the lid.
class Watch:
	var ceil_y := 300.0
	var clamps := 0
	var touch := 0
	var min_gap := INF
	var top := {}
	var _in := {}

	func step(birds: Array) -> void:
		for n in birds:
			if not is_instance_valid(n):
				continue
			var b := n as NpcBird
			var y := b.global_position.y
			var gap := ceil_y - (y + b.get_body_radius())
			min_gap = minf(min_gap, gap)
			var k := b.get_instance_id()
			top[k] = maxf(float(top.get(k, -INF)), y)
			var inside := y >= ceil_y - 0.5 - 1e-3
			if inside and not _in.get(k, false):
				clamps += 1
			_in[k] = inside
			if gap <= 0.0:
				touch += 1


func _flier(sp: StringName, start: Vector3, dir: Vector3, goal: Vector3) -> NpcBird:
	var b := spawn(sp, start, dir.normalized() * SizeRules.performance(SizeRules.species_data(sp)["mass"])["cruise"], _w)
	b.can_hunt = false
	b.can_flee = false
	b.energy = 1.0
	b.home = Vector3(goal.x, 0.0, goal.z)
	b.home_radius = 400.0
	b.brain._perch_cool = 999.0
	b.brain._soar_cool = 999.0
	b.brain._goal = goal
	b.brain._goal_t = 0.0
	b.brain._goal_life = 999.0
	b.brain._goal_free = true
	return b


## The air near the lid: the strongest updraft over the arena at each height.
func test_updrafts_near_the_lid() -> void:
	for y: float in [240.0, 260.0, 280.0, 290.0, 295.0, 299.5]:
		var best := -INF
		var at := Vector3.ZERO
		var R := _w.bounds_radius
		var x := -R
		while x <= R:
			var z := -R
			while z <= R:
				if x * x + z * z <= R * R:
					var wv := _w.get_wind(Vector3(x, y, z))
					if wv.y > best:
						best = wv.y
						at = Vector3(x, y, z)
				z += 8.0
			x += 8.0
		_log("[air] strongest updraft at %.1f m: %.2f m/s at (%.0f, %.0f)" % [y, best, at.x, at.z])
		finite(best, "updraft sampled at %.1f m" % y)


## Where the ground and the perches reach into the thin air (the top of the
## body above ceiling - 45 m = 255 m).
func test_ground_and_perches_near_the_lid() -> void:
	var R := _w.bounds_radius
	var gmax := -INF
	var at := Vector2.ZERO
	var n255 := 0
	var n := 0
	var x := -R
	while x <= R:
		var z := -R
		while z <= R:
			if x * x + z * z <= R * R:
				var g := _w.ground_height(x, z)
				n += 1
				if g > 250.0:
					n255 += 1
				if g > gmax:
					gmax = g
					at = Vector2(x, z)
			z += 4.0
		x += 4.0
	var pmax := -INF
	var p_hi := 0
	for pc in _w.get_perches():
		pmax = maxf(pmax, pc.position.y)
		if pc.position.y > 250.0:
			p_hi += 1
	_log("[terrain] highest ground inside the arena %.1f m at (%.0f, %.0f) (r %.0f m); ground above 250 m on %d of %d samples (%.2f %%); highest perch %.1f m, perches above 250 m: %d" % [
		gmax, at.x, at.y, at.length(), n255, n, 100.0 * n255 / maxf(n, 1), pmax, p_hi])
	finite(gmax, "ground sampled")


## Every size climbing for a goal 60 m above the lid, from 22 m under it.
func test_climb_for_a_goal_above_the_lid() -> void:
	var ceil_y := _w.ceiling
	var total := 0
	for sp: StringName in [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]:
		for start_below: float in [22.0, 8.0]:
			var start := Vector3(-60, ceil_y - start_below, -60)
			var b := _flier(sp, start, Vector3(1, 0.3, 0), Vector3(200, ceil_y + 60.0, -60))
			var w := Watch.new()
			w.ceil_y = ceil_y
			var g0 := b.geo_hits
			var bo0 := b.bounds_hits
			run(20.0, func(_i: int) -> bool:
				w.step([b])
				return false)
			_log("[climb] %s from %.0f m under the lid: clamp events %d, bounds hits %d, geo %d, closest top %.2f m under the lid, highest y %.2f" % [
				sp, start_below, w.clamps, b.bounds_hits - bo0, b.geo_hits - g0, w.min_gap, float(w.top.values()[0])])
			total += w.clamps + (b.geo_hits - g0)
			despawn(b)
	eq(total, 0, "no NPC climbing for the sky reaches the lid's clamp")


## A hunter below prey near the top of the sky (the player's thin-air top,
## 265-285 m, or an NPC there).
func test_hunt_toward_the_lid() -> void:
	var ceil_y := _w.ceiling
	var total := 0
	for c: Array in [[&"hawk", &"pigeon", 285.0], [&"eagle", &"gull", 288.0], [&"hawk", &"starling", 292.0], [&"crow", &"sparrow", 290.0]]:
		var prey := _flier(c[1], Vector3(0, c[2], 0), Vector3(1, 0.1, 0), Vector3(300, ceil_y + 40.0, 0))
		var hunter := spawn(c[0], Vector3(-40, c[2] - 40.0, 0), Vector3(1, 0.3, 0) * 10.0, _w)
		hunter.can_hunt = true
		hunter.energy = 1.0
		hunter.hunger = 1.0
		var w := Watch.new()
		w.ceil_y = ceil_y
		var hg0 := hunter.geo_hits
		var pg0 := prey.geo_hits
		var st := {"engaged": 0}
		run(25.0, func(_i: int) -> bool:
			if is_instance_valid(hunter) and hunter.target == prey:
				st["engaged"] += 1
			w.step([hunter, prey])
			return false)
		_log("[hunt] %s after a %s at %.0f m: engaged %.1f s, clamp events %d, closest top %.2f m under the lid, geo %d/%d" % [
			c[0], c[1], c[2], st["engaged"] * DT, w.clamps, w.min_gap, hunter.geo_hits - hg0, prey.geo_hits - pg0])
		total += w.clamps
		despawn(hunter)
		despawn(prey)
	eq(total, 0, "hunting near the top of the sky never reaches the lid's clamp")


## The ecosystem round a (mock) player lapping at the flapping top of the
## sky, 275 m, for two minutes.
func test_ecosystem_round_a_high_player() -> void:
	var ceil_y := _w.ceiling
	var p := MockPlayer.new()
	p.mass = float(Paths.arg("pm", "0.3"))
	var sp0 := _w.get_player_spawn().origin
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = 90.0
	p.path_height = float(Paths.arg("ph", "275"))
	p.speed = minf(SizeRules.cruise_speed(p.mass), 14.0)
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 7
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var w := Watch.new()
	w.ceil_y = ceil_y
	var hi := {"n": 0, "above250": 0.0}
	var secs := float(Paths.arg("eco_s", "120"))
	for i in int(secs / DT):
		air(_w, i * DT)
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		var ns := e.get_npcs()
		w.step(ns)
		if i % 72 == 0:
			for n in ns:
				hi["n"] += 1
				if n.global_position.y > 250.0:
					hi["above250"] += 1
	_log("[ecosystem] player %.2f kg lapping at %.0f m for %.0f s: NPC clamp events %d, touches %d, closest top %.2f m under the lid, NPC-seconds above 250 m %d of %d" % [
		p.mass, p.path_height, secs, w.clamps, w.touch, w.min_gap, hi["above250"], hi["n"]])
	eq(w.clamps, 0, "no NPC reaches the lid's clamp round a high player")
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)


## A 4 m/s thermal column (no top) through the lid of a flat test world
## (the verifier's flight case): NPCs level, climbing or diving across it.
func test_thermal_through_the_lid() -> void:
	var tw: World = preload("res://tests/unit/flight/flight_test_world.gd").new()
	tw.set("thermal_core", 4.0)
	tw.set("thermal_center", Vector3.ZERO)
	tw.set("thermal_radius", 60.0)
	add_child(tw)
	tw.ceiling = 300.0
	tw.bounds_radius = 1500.0
	FlightGeometry.box(tw, Vector3(0, 305.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false)
	await wait_physics(2)
	var total := 0
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"gull", &"eagle"]:
		for c: Array in [["level", 285.0, Vector3(1, 0, 0.3), 285.0], ["up", 280.0, Vector3(1, 0.3, 0.3), 380.0], ["circle", 290.0, Vector3(0, 0, 1), 290.0]]:
			var start := Vector3(-30, c[1], 0)
			var goal := Vector3(0, c[3], 0) if c[0] == "circle" else Vector3(400, c[3], 120)
			var b := spawn(sp, start, (c[2] as Vector3).normalized() * SizeRules.performance(SizeRules.species_data(sp)["mass"])["cruise"], tw)
			b.can_hunt = false
			b.can_flee = false
			b.energy = 1.0
			b.home = Vector3(goal.x, 0.0, goal.z)
			b.home_radius = 400.0
			b.brain._perch_cool = 999.0
			b.brain._goal = goal
			b.brain._goal_t = 0.0
			b.brain._goal_life = 999.0
			b.brain._goal_free = true
			var w := Watch.new()
			w.ceil_y = tw.ceiling
			var g0 := b.geo_hits
			var bo0 := b.bounds_hits
			run(30.0, func(_i: int) -> bool:
				w.step([b])
				return false)
			_log("[thermal] %s %s from %.0f m: clamp events %d, bounds hits %d, geo %d, closest top %.2f m under the lid, highest y %.2f, end y %.1f" % [
				sp, c[0], c[1], w.clamps, b.bounds_hits - bo0, b.geo_hits - g0, w.min_gap, float(w.top.values()[0]), b.global_position.y])
			total += w.clamps + (b.geo_hits - g0)
			despawn(b)
	tw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
	eq(total, 0, "no NPC is carried into the lid by a thermal")
