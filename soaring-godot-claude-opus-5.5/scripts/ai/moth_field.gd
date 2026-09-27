class_name MothField
extends Node3D
## The sky's pellets (core loop round, the lead's direction: "agar.io in the
## sky: abundant easy food - moths are the pellets, plentiful, slow, drifting
## in OPEN AIR in loose swarms along the player's likely paths (over
## meadows, around thermals, the village), barely fleeing. Early growth
## comes mostly from them"). The Ecosystem's child; it keeps a few
## MothSwarms about the player:
##  * placed in open air (a sphere SWARM_CLEAR_M wider than the cloud clear
##    of the world's geometry, not indoors, inside the valley), at a height
##    a small bird cruises at (HEIGHT above the highest surface - ground,
##    roof or crown - and near the player's own height), mostly ahead of its
##    flight (within AHEAD_DEG of it) or over the open places moths gather
##    (meadows, fields, the village, thermals, the lake shore, glades), never
##    nearer than PLACE_MIN_M (a moth that far is a speck: no one sees one
##    appear);
##  * a swarm the player has left behind (further than BEHIND_M and behind
##    its flight, or further than FAR_M) or that has been eaten out is placed
##    again ahead, at most one every REPLACE_S;
##  * the number of swarms follows how much a moth is worth to the player:
##    swarms_for(budget) while moths are worth chasing (SizeRules), AMBIENT
##    once the player has outgrown them (life, and food for the sky's wrens
##    and sparrows).
## Moths are Birds outside the Ecosystem's NPC budget: a moth costs a
## transform and a wingbeat a tick (MothSwarm), not an NpcBird's brain.
##
## The catch lesson's prey (request_lesson): a lesson swarm - unaware, it
## never darts - placed LESSON_AHEAD_M ahead of the player's flight at its
## height in open air (inside the target cue's range, so the ring the
## lesson asks the player to chase is on it at once: a lesson's prey may
## appear where the player looks), kept ahead of it (placed again when the
## player has flown LESSON_LOST_M past or away from it) until the lesson
## ends (stop_lesson), and each new request (the UI's help) LESSON_HELP_M
## nearer.

## Swarms and moths per swarm at the full budget (60 NPCs), fewer at a
## smaller one (swarms_for); swarms once the player has outgrown moths.
const SWARMS := 5
const SWARM_SIZE := 8
const AMBIENT := 1
## A swarm is placed this far from the player (m): ahead of it only beyond
## the distance its moths would show (their edible marks: ThreatWatch's
## highlight range, 6 s of flight - 54 m for a sparrow - and never nearer
## than PLACE_MIN_M), out of the view cone from PLACE_MIN_M on (the
## Ecosystem's rule for any bird: nothing appears where the player looks).
const PLACE_MIN_M := 40.0
const PLACE_MAX_M := 95.0
const PLACE_BEYOND_MARKS_M := 4.0
## Mostly ahead of its flight (within this of it), else over an open place.
const AHEAD_DEG := 60.0
const AHEAD_SHARE := 0.7
## Height above the highest surface under the swarm (m), and how near the
## player's own height it keeps (m).
const HEIGHT := Vector2(5.0, 13.0)
const NEAR_PLAYER_H := 5.0
## Clearance round the cloud (m) that the swarm's anchor needs.
const SWARM_CLEAR_M := 3.0
## Left behind / far / how often one is placed again (s).
const BEHIND_M := 90.0
const FAR_M := 170.0
const REPLACE_S := 1.0
## An eaten-out swarm waits this long before it is placed again (s).
const REFILL_S := 4.0
## A swarm moth's mass (kg): a fat moth, half as heavy again as the ladder's
## moth (SizeRules: 4 g). Core loop round (the lead's direction: "early
## growth comes mostly from them [the pellets] plus the occasional careless
## small bird"): with 4 g pellets a sparrow outgrew them at 40 g, half-way to
## the swallow, and the target cue rang the wrens instead (a wren is worth 7
## moths) - on the tree of 09:14 5 of 17 catches a sparrow made through the
## real chain were pellets (cl3_it8). At 6 g a moth grows a sparrow ~20%,
## outweighs a wren for the cue at equal distance until ~40 g, and is dust
## (SizeRules.is_worthwhile) from 60 g: about one swarm to the swallow.
const PELLET_MASS := 0.006
## The lesson swarm: ahead of the player (m), placed again when this far
## away (m) or behind; on help it comes this much nearer (m, per level).
const LESSON_AHEAD_M := 45.0
const LESSON_LOST_M := 90.0
const LESSON_HELP_M := 12.0
const LESSON_SIZE := 5
## ...at the player's height, but at most this far above the ground (m): a
## player that has climbed high in the first lessons still has the lesson's
## moths within the target cue's reach (ThreatWatch.LESSON_RANGE_M; core
## loop fix round 1 - at 13-19 m a player cruising 80 m up never saw a ring
## or an arrow, and the lesson could only time out).
const LESSON_MAX_AGL := 40.0
## Open places moths gather over (World landmark kinds).
const OPEN_KINDS: Array[String] = ["meadow", "field", "town", "thermal", "lake", "glade", "orchard", "ride"]

var eco: Node = null
var habitat: Habitat = null
var swarms: Array[MothSwarm] = []
var lesson_swarm: MothSwarm = null
var lesson_help := 0
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _replace_t := 0.0
var _empty_since := {}
var _stats := {"placed": 0, "replaced_behind": 0, "replaced_eaten": 0, "lesson_placed": 0, "no_spot": 0}


func _init(seed_value: int = 1) -> void:
	name = "MothField"
	_rng.seed = seed_value


## Swarms while moths are worth the player's while, at an NPC budget (the
## fourth root: a sparser sky keeps most of its pellets - they are cheap,
## and a small player's growth there leans on them more).
static func swarms_for(max_npcs: int) -> int:
	return clampi(int(round(SWARMS * pow(float(max_npcs) / 60.0, 0.25))), 2, SWARMS)


func reset(seed_value: int) -> void:
	_rng.seed = seed_value * 7 + 3
	_t = 0.0
	_replace_t = 0.0
	_empty_since.clear()
	# (Out of the tree at once: a moth leaves the Birds registry as it exits,
	# and a new run's first ticks must not meet the last run's moths - the
	# same seed must give the same sky.)
	for s in swarms:
		_drop(s)
	swarms.clear()
	if lesson_swarm != null:
		_drop(lesson_swarm)
		lesson_swarm = null
	lesson_help = 0
	_stats = {"placed": 0, "replaced_behind": 0, "replaced_eaten": 0, "lesson_placed": 0, "no_spot": 0}


func stats() -> Dictionary:
	var out := _stats.duplicate()
	out["swarms"] = swarms.size()
	out["moths"] = moth_count()
	out["lesson"] = lesson_swarm != null
	return out


## Live moths (every swarm, the lesson's included).
func moth_count() -> int:
	var n := 0
	for s in swarms:
		n += s.alive_count()
	if lesson_swarm != null:
		n += lesson_swarm.alive_count()
	return n


## One tick: move every swarm; about once a second, keep them where the
## player is going.
func step(dt: float, fb: Bird, max_npcs: int) -> void:
	_t += dt
	for s in swarms:
		s.step(dt)
	if lesson_swarm != null:
		lesson_swarm.step(dt)
	_replace_t += dt
	if _replace_t < REPLACE_S or fb == null or habitat == null:
		return
	_replace_t = 0.0
	var pp := fb.get_body_position()
	var fwd := _flight_dir(fb)
	# The lesson swarm stays ahead of the player.
	if lesson_swarm != null:
		var rel2 := lesson_swarm.centre - pp
		var d2 := rel2.length()
		if lesson_swarm.alive_count() == 0 or d2 > LESSON_LOST_M or (d2 > 15.0 and rel2.dot(fwd) < -0.3 * d2):
			_place_lesson(fb)
	var want := swarms_for(max_npcs) if SizeRules.is_worthwhile(fb.mass, _moth_mass()) else AMBIENT
	while swarms.size() > want:
		_drop(swarms.pop_back())
	if swarms.size() < want:
		var at := _spot(fb, false)
		if at != Vector3.INF:
			var s := MothSwarm.new(_rng.randi())
			add_child(s)
			s.place(at, SWARM_SIZE, _moth_mass())
			swarms.append(s)
			_stats["placed"] += 1
		else:
			_stats["no_spot"] += 1
		return
	# At most one swarm moves a second: the first left behind, or eaten out.
	for s in swarms:
		var id := s.get_instance_id()
		if s.alive_count() == 0:
			if not _empty_since.has(id):
				_empty_since[id] = _t
			if _t - float(_empty_since[id]) < REFILL_S:
				continue
		else:
			_empty_since.erase(id)
			var rel := s.centre - pp
			var d := rel.length()
			var behind := d > BEHIND_M and rel.dot(fwd) < 0.0
			if not (behind or d > FAR_M):
				continue
			if _in_view(s.centre, fb):
				continue
		var at := _spot(fb, false)
		if at == Vector3.INF:
			_stats["no_spot"] += 1
			return
		_stats["replaced_eaten" if s.alive_count() == 0 else "replaced_behind"] += 1
		_empty_since.erase(id)
		s.place(at, SWARM_SIZE, _moth_mass())
		_stats["placed"] += 1
		return


## The catch lesson's prey: a lesson swarm ahead of `near` along `dir` (the
## player's flight), in open air, `help` steps nearer (LESSON_HELP_M each).
## Returns its moths.
func request_lesson(fb: Bird, near: Vector3, dir: Vector3, help: int = 0) -> Array:
	lesson_help = maxi(help, 0)
	return _place_lesson(fb, near, dir)


func stop_lesson() -> void:
	if lesson_swarm != null:
		_drop(lesson_swarm)
		lesson_swarm = null
	lesson_help = 0


func _drop(s: MothSwarm) -> void:
	# (Dead before they leave: a hunter ticking later in this frame must not
	# strike at a moth already out of the tree - a Quest-tier real-chain run
	# logged get_global_transform on one, cl3_it11 quest 105, when the player
	# outgrew the pellets and the swarms were dropped.)
	for mo in s.moths:
		if is_instance_valid(mo):
			mo.alive = false
	if s.get_parent() == self:
		remove_child(s)
	s.queue_free()


func _place_lesson(fb: Bird, near: Vector3 = Vector3.INF, dir: Vector3 = Vector3.ZERO) -> Array:
	if fb == null and near == Vector3.INF:
		return []
	var pp := near if near != Vector3.INF else fb.get_body_position()
	var fwd := dir if dir.length() > 0.1 else (_flight_dir(fb) if fb != null else Vector3.FORWARD)
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-3 else Vector3.FORWARD
	var ahead := maxf(LESSON_AHEAD_M - LESSON_HELP_M * lesson_help, 20.0)
	var at := Vector3.INF
	# Straight ahead first, then swung to either side, nearer and further.
	for k in 14:
		var ang: float = [0.0, 0.3, -0.3, 0.6, -0.6, 0.9, -0.9][k % 7]
		var dd: float = ahead * (1.0 if k < 7 else 0.7)
		var h := fwd.rotated(Vector3.UP, ang)
		var x := pp + h * dd
		var top := habitat.top(x.x, x.z) if habitat != null else 0.0
		x.y = clampf(pp.y, top + HEIGHT.x, top + LESSON_MAX_AGL)
		if _open(x):
			at = x
			break
	if at == Vector3.INF:
		return []
	if lesson_swarm == null:
		lesson_swarm = MothSwarm.new(_rng.randi())
		lesson_swarm.lesson = true
		lesson_swarm.name = "LessonSwarm"
		add_child(lesson_swarm)
	lesson_swarm.place(at, LESSON_SIZE, _moth_mass())
	_stats["lesson_placed"] += 1
	var out: Array = []
	for mo in lesson_swarm.moths:
		out.append(mo)
	return out


## How far a moth's edible mark shows for a player of mass pm (ThreatWatch's
## highlight range: 70 of its wingspans, or 6 s of its flight).
static func marks_range(pm: float) -> float:
	return maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))


func _moth_mass() -> float:
	return PELLET_MASS


## Where the player is flying (horizontal; its facing when it is slow).
static func _flight_dir(fb: Bird) -> Vector3:
	var v := Vector3(fb.velocity.x, 0.0, fb.velocity.z)
	if v.length() < 1.0:
		v = fb.get_forward()
		v.y = 0.0
	return v.normalized() if v.length() > 1e-3 else Vector3.FORWARD


func _in_view(pos: Vector3, fb: Bird) -> bool:
	return eco != null and eco.has_method(&"in_view") and bool(eco.call(&"in_view", pos, fb))


## A spot for a swarm: ahead of the player's flight (AHEAD_SHARE of the
## tries) or over an open place near it, at a small bird's height, in open
## air. INF if none was found in a few tries.
func _spot(fb: Bird, _lesson: bool) -> Vector3:
	var pp := fb.get_body_position()
	var fwd := _flight_dir(fb)
	var open_places: Array = []
	if habitat != null:
		for kind in OPEN_KINDS:
			for lm: Dictionary in habitat.landmarks_of(kind):
				var lp: Vector3 = lm.get("position", Vector3.INF)
				var dd := Vector2(lp.x - pp.x, lp.z - pp.z).length()
				if dd < PLACE_MAX_M + float(lm.get("radius", 0.0)):
					open_places.append(lm)
	var marks := marks_range(fb.mass) + PLACE_BEYOND_MARKS_M
	for k in 16:
		var x := Vector3.INF
		if open_places.is_empty() or _rng.randf() < AHEAD_SHARE:
			var ang := deg_to_rad(_rng.randf_range(-AHEAD_DEG, AHEAD_DEG))
			x = pp + fwd.rotated(Vector3.UP, ang) * _rng.randf_range(maxf(PLACE_MIN_M, marks), maxf(PLACE_MAX_M, marks + 30.0))
		else:
			var lm: Dictionary = open_places[_rng.randi() % open_places.size()]
			var lp: Vector3 = lm["position"]
			var r := minf(float(lm.get("radius", 20.0)), 60.0)
			x = lp + Vector3(_rng.randf_range(-r, r), 0.0, _rng.randf_range(-r, r))
		var d := Vector2(x.x - pp.x, x.z - pp.z).length()
		if d < PLACE_MIN_M or d > maxf(PLACE_MAX_M, marks + 30.0) * 1.3:
			continue
		# Where the player looks, only beyond where its moths would show.
		if d < marks and _in_view(x, fb):
			continue
		var top := habitat.top(x.x, x.z)
		var y := top + _rng.randf_range(HEIGHT.x, HEIGHT.y)
		# Near the height the player flies at, if that is a small bird's.
		y = clampf(y, minf(pp.y - NEAR_PLAYER_H, top + HEIGHT.y), maxf(pp.y + NEAR_PLAYER_H, top + HEIGHT.x))
		y = clampf(y, top + HEIGHT.x, top + HEIGHT.y + 8.0)
		x.y = y
		if _open(x):
			return x
	return Vector3.INF


## Open air for a swarm at x: inside the valley, not indoors, and nothing
## solid within the disc the cloud can wander over (its radius, its drift
## and SWARM_CLEAR_M round the anchor; spheres at the anchor and on a ring
## round it, each as tall as the height above the highest surface allows -
## the ground under a swarm is not in its way).
func _open(x: Vector3) -> bool:
	if habitat == null:
		return true
	var w := habitat.world
	if w != null and is_instance_valid(w) and not w.is_inside(x):
		return false
	var h := x.y - habitat.top(x.x, x.z)
	if h < HEIGHT.x - 0.5:
		return false
	var reach := MothSwarm.RADIUS + MothSwarm.ANCHOR_R + SWARM_CLEAR_M
	var r := clampf(h - 1.0, 1.5, 4.5)
	if habitat.blocked(x, r):
		return false
	var ring := maxf(reach - r, 0.0)
	for i in 6:
		var a := TAU * i / 6.0
		if habitat.blocked(x + Vector3(cos(a), 0.0, sin(a)) * ring, r):
			return false
	return not habitat.indoors(x)
