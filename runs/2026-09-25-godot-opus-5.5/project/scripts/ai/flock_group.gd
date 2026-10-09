class_name FlockGroup
extends RefCounted
## A group of same-species birds that travel, wheel and rest together.
##
## The group owns only a shared goal ("anchor") and a shared mood (flying or
## roosting). Each member steers itself with boids rules against its nearest
## flock-mates; the anchor just gives the swarm somewhere to go:
##  * "murmuration" (starlings): the anchor loops a slow 3-D Lissajous figure
##    over a roost. Members fly much faster than it, so they overshoot and
##    wheel around it in waves - the murmuration look comes from that
##    mismatch plus topological neighbours (real starlings track ~7).
##  * "loose" (sparrows, swallows, pigeons...): the anchor hops between
##    waypoints in the flock's home range at a little under cruise speed.
## When most members are tired the flock roosts together near one spot.

enum Mood { FLY, ROOST }

var id := 0
var species: StringName = &"sparrow"
var kind := "loose"
var members: Array = []
var home := Vector3.ZERO
var home_radius := 80.0
var alt_min := 5.0
var alt_max := 30.0
var anchor := Vector3.ZERO
var mood: Mood = Mood.FLY
## Where the flock roosts while mood == ROOST.
var roost_point := Vector3.ZERO
var mood_time := 0.0
var cruise := 9.0
## When the Ecosystem puts a loose flock in its show (ahead of the player):
## the height it wheels at, about the player's own (NAN: its own range).
var show_alt := NAN
## ...and where its home is going: it moves there at SHOW_HOME_SPEED x
## cruise (a home that jumped ahead made the whole flock sprint after it,
## and a tired flock roosts). INF: no such goal.
var home_goal := Vector3.INF
const SHOW_HOME_SPEED := 1.1

var _t := 0.0
var _phase := Vector3.ZERO
var _waypoint := Vector3.ZERO
var _habitat: Habitat
var _rng: RandomNumberGenerator


func _init(p_id: int, p_species: StringName, p_kind: String, p_home: Vector3, habitat: Habitat, seed_value: int) -> void:
	id = p_id
	species = p_species
	kind = p_kind
	home = p_home
	_habitat = habitat
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_value
	var prof := SpeciesProfile.of(species)
	alt_min = prof["alt"][0]
	alt_max = minf(prof["alt"][1], habitat.ceiling * 0.6)
	cruise = SizeRules.performance(SizeRules.species_data(species).get("mass", 0.03))["cruise"]
	_phase = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
	anchor = _anchor_at(0.0) if kind == "murmuration" else _pick_waypoint()
	_waypoint = _pick_waypoint()
	if kind == "murmuration":
		home_radius = 70.0


func remove(m: Object) -> void:
	members.erase(m)


func size() -> int:
	return members.size()


func centroid() -> Vector3:
	var c := Vector3.ZERO
	var n := 0
	for m in members:
		if is_instance_valid(m) and m.alive:
			c += m.global_position
			n += 1
	return c / float(n) if n > 0 else anchor


func update(dt: float) -> void:
	_t += dt
	mood_time += dt
	if home_goal != Vector3.INF:
		home = home.move_toward(home_goal, cruise * SHOW_HOME_SPEED * dt)
	if kind == "murmuration":
		anchor = _anchor_at(_t)
	else:
		var to := _waypoint - anchor
		var d := to.length()
		# A new waypoint on arrival, or when the home has moved on (it rides
		# with the player) and left this one behind.
		if d < 8.0 or Vector2(_waypoint.x - home.x, _waypoint.z - home.z).length() > home_radius * 1.5:
			_waypoint = _pick_waypoint()
		else:
			# A leisurely 0.8 x cruise within the home range; up to 1.2 x
			# (members sprint to hold their places) when the home - riding
			# with the player - has moved far from the flock, so it catches
			# up instead of trailing behind.
			var lag := Vector2(anchor.x - home.x, anchor.z - home.z).length() / maxf(home_radius, 1.0)
			anchor += to / d * minf(cruise * lerpf(0.8, 1.2, clampf((lag - 0.5) / 1.5, 0.0, 1.0)) * dt, d)
	# Roost when the flock is tired; leave again once rested.
	var tired := 0
	var rested := 0
	var n := 0
	for m in members:
		if not is_instance_valid(m) or not m.alive:
			continue
		n += 1
		if m.energy < 0.45:
			tired += 1
		if m.energy > 0.92:
			rested += 1
	# (A flock in the Ecosystem's show keeps flying longer before it roosts:
	# only when most are tired and after a minute and a half.)
	var roost_after := 20.0 if is_nan(show_alt) else 90.0
	if mood == Mood.FLY and n > 0 and tired * 2 > n and mood_time > roost_after:
		mood = Mood.ROOST
		mood_time = 0.0
		roost_point = _pick_roost()
	elif mood == Mood.ROOST and n > 0 and (rested * 3 >= n * 2 and mood_time > 15.0 or mood_time > 70.0):
		mood = Mood.FLY
		mood_time = 0.0


## Move the whole flock's range (the ecosystem keeps life near the player).
func set_home(p: Vector3) -> void:
	home = p


func _anchor_at(t: float) -> Vector3:
	var g := _habitat.ground_fast(home.x, home.z)
	var mid := (alt_min + alt_max) * 0.5
	var amp_y := (alt_max - alt_min) * 0.35
	# The figure fits the home range (70 m over a roost; tighter when the
	# Ecosystem shows the murmuration ahead of the player).
	var k := clampf(home_radius / 70.0, 0.3, 1.0)
	if not is_nan(show_alt):
		mid = maxf(alt_min, show_alt - g)
		amp_y = minf(amp_y, 6.0)
	return Vector3(
		home.x + 48.0 * k * sin(0.11 * t + _phase.x),
		g + mid + amp_y * sin(0.07 * t + _phase.y),
		home.z + 36.0 * k * sin(0.17 * t + _phase.z))


func _pick_waypoint() -> Vector3:
	var a := _rng.randf() * TAU
	var r := sqrt(_rng.randf()) * home_radius
	var x := home.x + cos(a) * r
	var z := home.z + sin(a) * r
	var g := _habitat.ground_fast(x, z)
	var y := g + _rng.randf_range(alt_min, alt_max)
	if not is_nan(show_alt):
		# In the show: near the player's height (never under its own floor).
		y = maxf(g + alt_min, show_alt + _rng.randf_range(-5.0, 5.0))
	# Over the roofs and crowns there, not among them.
	y = maxf(y, _habitat.top(x, z, y + 40.0) + maxf(alt_min * 0.5, 2.0))
	return _habitat.clamp_inside(Vector3(x, y, z), 30.0)


## A spot with free perches for the flock (densest perch cluster nearby):
## in its home range (a loose flock's home rides with the player, so it
## roosts where the player is going), else around the flock.
func _pick_roost() -> Vector3:
	var c := centroid()
	if kind != "murmuration":
		var h := Vector3(home.x, c.y, home.z)
		if Vector2(h.x - c.x, h.z - c.z).length() < 160.0:
			c = h
	var span := SizeRules.wingspan_for_mass(SizeRules.species_data(species).get("mass", 0.03))
	var kinds: Array = SpeciesProfile.of(species)["perch_kinds"]
	# In the home range first (it rides with the player: roost where the
	# player is, not on the far side of the valley), else anywhere near.
	var perches := _habitat.find_perches(c, maxf(home_radius, 40.0), span, kinds)
	if perches.size() < 3:
		perches = _habitat.find_perches(c, 160.0, span, kinds)
	if perches.is_empty():
		return c
	# Pick the perch with the most free neighbours within 12 m.
	var best: Perch = perches[0]
	var best_n := -1
	for i in mini(perches.size(), 24):
		var p: Perch = perches[i]
		var nn := 0
		for q in perches:
			if q.position.distance_squared_to(p.position) < 144.0:
				nn += 1
		if nn > best_n:
			best_n = nn
			best = p
	return best.position
